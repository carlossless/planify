/*
 * Copyright © 2026 Alain M. (https://github.com/alainm23/planify)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301 USA
 */

/*
 * Durable, deduplicating write queue for the Things Cloud backend.
 *
 * Every user-initiated change is recorded as a single-entity commit fragment
 * ({"t":op,"e":kind,"p":{...}}) in the shared Queue table, keyed by the entity
 * UUID. Because Things is an append-only log keyed by entity, multiple pending
 * changes to the same entity are MERGED into one fragment, so a burst of edits
 * (or a stray echo) collapses to at most one write per entity.
 *
 * A single serialized committer flushes the queue: it batches everything into
 * one commit, applies exponential backoff on transient failures, rebases on
 * optimistic-concurrency conflicts, detects a server-side history reset, and
 * trips a circuit breaker after repeated failures so a bad state can never turn
 * into a write storm. Nothing leaves the device except through here.
 */
public class Services.ThingsQueue : GLib.Object {
    public const string OP_UPSERT = "things_upsert"; // create/update/complete/move
    public const string OP_DELETE = "things_delete";

    // Operation-type codes carried inside each fragment's "t" member.
    public const int T_CREATE = 0;
    public const int T_UPDATE = 1;
    public const int T_DELETE = 2;

    private const int MAX_BACKOFF_SECONDS = 300;
    private const int CIRCUIT_BREAKER_THRESHOLD = 5;
    private const int MAX_ENTITIES_PER_COMMIT = 500;

    private Soup.Session session;
    private weak Services.Things things;

    private bool flushing = false;
    private int consecutive_failures = 0;
    private int64 circuit_open_until = 0; // monotonic seconds; 0 = closed

    public signal void flush_failed (int error_code, string message);

    public ThingsQueue (Soup.Session session, Services.Things things) {
        this.session = session;
        this.things = things;
    }

    /*
     * Records one entity change. `fragment` is the JSON object
     * {"t":..,"e":..,"p":{...}} for a single entity. If a change for the same
     * entity is already queued, the two are merged (see merge_fragment).
     */
    public void enqueue (Objects.Source source, string entity_id, string fragment) {
        Objects.Queue ? existing = find_queued (source, entity_id);
        string merged = fragment;
        string query = OP_UPSERT;

        if (existing != null) {
            if (!merge_fragments (existing.args, fragment, out merged)) {
                // A local create followed by a local delete: the server never
                // heard of this entity, so drop it entirely.
                Services.Database.get_default ().remove_queue (existing.uuid);
                return;
            }
            Services.Database.get_default ().remove_queue (existing.uuid);
        }

        if (Utils.JsonUtils.get_int (merged, "t") == T_DELETE) {
            query = OP_DELETE;
        }

        var q = new Objects.Queue ();
        q.uuid = Util.get_default ().generate_id ();
        q.object_id = entity_id;
        q.query = query;
        q.args = merged;
        q.source_id = source.id;
        Services.Database.get_default ().insert_queue (q);
    }

    private Objects.Queue ? find_queued (Objects.Source source, string entity_id) {
        foreach (var q in Services.Database.get_default ().get_all_queue (source.id)) {
            if (q.object_id == entity_id) {
                return q;
            }
        }
        return null;
    }

    public bool has_pending (Objects.Source source) {
        return Services.Database.get_default ().get_all_queue (source.id).size > 0;
    }

    /*
     * Merges a newer single-entity fragment onto an older one.
     *   - a delete supersedes everything (but create+delete => cancel, false);
     *   - a create beats an update for the op code (t = min);
     *   - payload fields are unioned, newer values winning.
     */
    public static bool merge_fragments (string older, string newer, out string result) {
        int old_t = (int) Utils.JsonUtils.get_int (older, "t");
        int new_t = (int) Utils.JsonUtils.get_int (newer, "t");
        string kind = Utils.JsonUtils.get_string (newer, "e");
        if (kind == "") {
            kind = Utils.JsonUtils.get_string (older, "e");
        }

        if (new_t == T_DELETE) {
            if (old_t == T_CREATE) {
                result = "";
                return false; // create then delete cancels out
            }
            result = build_fragment (T_DELETE, kind, new Json.Object ());
            return true;
        }

        int result_t = int.min (old_t, new_t); // create (0) wins over update (1)

        var merged = new Json.Object ();
        copy_payload (older, merged);
        copy_payload (newer, merged); // newer overrides

        result = build_fragment (result_t, kind, merged);
        return true;
    }

    private static void copy_payload (string fragment, Json.Object into) {
        if (!Utils.JsonUtils.has_member (fragment, "p")) {
            return;
        }
        Json.Object p = Utils.JsonUtils.get_object_member (fragment, "p");
        foreach (string member in p.get_members ()) {
            into.set_member (member, p.get_member (member).copy ());
        }
    }

    public static string build_fragment (int op, string kind, Json.Object payload) {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("t");
        builder.add_int_value (op);
        builder.set_member_name ("e");
        builder.add_string_value (kind);
        builder.set_member_name ("p");
        builder.add_value (new Json.Node.alloc ().init_object (payload));
        builder.end_object ();

        var generator = new Json.Generator ();
        generator.set_root (builder.get_root ());
        return generator.to_data (null);
    }

    /*
     * Flushes all queued changes for a source in a single serialized pass.
     */
    public async HttpResponse flush (Objects.Source source) {
        var response = new HttpResponse ();
        response.status = true;

        if (flushing) {
            return response; // another flush is running; it will pick these up
        }

        if (circuit_is_open ()) {
            response.status = false;
            response.error = _("Syncing is paused after repeated failures. It will resume automatically.");
            return response;
        }

        flushing = true;

        try {
            while (true) {
                var queued = Services.Database.get_default ().get_all_queue (source.id);
                if (queued.size == 0) {
                    consecutive_failures = 0;
                    break;
                }

                var batch = new Gee.ArrayList<Objects.Queue> ();
                for (int i = 0; i < queued.size && i < MAX_ENTITIES_PER_COMMIT; i++) {
                    batch.add (queued[i]);
                }

                HttpResponse commit_response = yield commit_batch (source, batch);

                if (commit_response.status) {
                    foreach (var q in batch) {
                        Services.Database.get_default ().remove_queue (q.uuid);
                    }
                    consecutive_failures = 0;
                    continue;
                }

                // Retryable failure: keep the queue, back off, trip the breaker.
                consecutive_failures++;
                if (consecutive_failures >= CIRCUIT_BREAKER_THRESHOLD) {
                    open_circuit ();
                }
                response.status = false;
                response.error_code = commit_response.error_code;
                response.error = commit_response.error;
                flush_failed (commit_response.error_code, commit_response.error);
                break;
            }
        } finally {
            flushing = false;
        }

        return response;
    }

    /*
     * Commits one batch, handling conflict/backoff/reset. Returns status=true
     * only when the batch is durably accepted.
     */
    private async HttpResponse commit_batch (Objects.Source source, Gee.ArrayList<Objects.Queue> batch) {
        var response = new HttpResponse ();

        string body = assemble_body (batch);

        int attempt = 0;
        while (true) {
            attempt++;

            HttpResponse raw = yield things.send_commit (source, body);

            if (raw.http_code == 200) {
                response.status = true;
                return response;
            }

            // History reset / auth lost — try to recover the current history key.
            if (raw.http_code == 401 || raw.http_code == 404) {
                bool recovered = yield things.recover_history_key (source);
                if (recovered && attempt <= 2) {
                    continue;
                }
                response.error_code = raw.http_code;
                response.error = raw.error;
                return response;
            }

            // Optimistic-concurrency conflict — rebase on latest and retry.
            if (raw.http_code == 409 || raw.http_code == 412) {
                yield things.sync (source);
                if (attempt <= 3) {
                    continue;
                }
                response.error_code = raw.http_code;
                response.error = things.get_things_error (raw.http_code);
                return response;
            }

            // Rate limited / server error — exponential backoff then retry.
            if (raw.http_code == 429 || raw.http_code >= 500) {
                if (attempt <= 4) {
                    yield backoff (attempt);
                    continue;
                }
            }

            response.error_code = raw.http_code;
            response.error = raw.error != "" ? raw.error : things.get_things_error (raw.http_code);
            return response;
        }
    }

    private string assemble_body (Gee.ArrayList<Objects.Queue> batch) {
        var builder = new Json.Builder ();
        builder.begin_object ();
        foreach (var q in batch) {
            builder.set_member_name (q.object_id);
            builder.add_value (new Json.Node.alloc ().init_object (Utils.JsonUtils.get_object (q.args)));
        }
        builder.end_object ();

        var generator = new Json.Generator ();
        generator.set_root (builder.get_root ());
        return generator.to_data (null);
    }

    private async void backoff (int attempt) {
        int seconds = int.min (MAX_BACKOFF_SECONDS, (1 << attempt));
        Timeout.add_seconds (seconds, backoff.callback);
        yield;
    }

    private bool circuit_is_open () {
        if (circuit_open_until == 0) {
            return false;
        }
        if (GLib.get_monotonic_time () / 1000000 >= circuit_open_until) {
            circuit_open_until = 0;
            consecutive_failures = 0;
            return false;
        }
        return true;
    }

    private void open_circuit () {
        circuit_open_until = (GLib.get_monotonic_time () / 1000000) + MAX_BACKOFF_SECONDS;
        Services.LogService.get_default ().warn (
            "ThingsQueue", "Circuit breaker tripped after %d consecutive failures; pausing writes".printf (consecutive_failures)
        );
    }
}
