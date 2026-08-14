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
 * Things Cloud sync backend.
 *
 * Cultured Code has no official API; this implements the reverse-engineered
 * protocol used by Things.app: an append-only history of entity diffs at
 * https://cloud.culturedcode.com/version/1. Every entity is keyed by a
 * 22-char Base58 UUID and carries a compressed payload (see ThingsUtil).
 *
 * Mapping into Planify:
 *   Area3                → Objects.Project (sync_id "things-area")
 *   Task6 tp=1 (project) → Objects.Project (sync_id "things-project")
 *   Task6 tp=2 (heading) → Objects.Section
 *   Task6 tp=0 (task)    → Objects.Item
 *   ChecklistItem3       → Objects.Item with parent_id (subtask)
 *   Tag4                 → Objects.Label
 *   Inbox                → synthetic local project "<source-id>-inbox"
 */
public class Services.Things : GLib.Object {
    private Soup.Session session;

    private const string BASE_URL = "https://cloud.culturedcode.com/version/1";
    private const string USER_AGENT = "ThingsMac/32209501";
    private const string APP_ID = "com.culturedcode.ThingsMac";
    private const string SCHEMA = "301";

    private const string SYNC_ID_AREA = "things-area";
    private const string SYNC_ID_PROJECT = "things-project";
    private const string SYNC_ID_INBOX = "things-inbox";
    private const string KIND_TASK = "Task6";
    private const string KIND_CHECKLIST = "ChecklistItem3";
    private const string KIND_AREA = "Area3";
    private const string KIND_TAG = "Tag4";

    public signal void sync_progress (int64 current, int64 total, string message);

    private bool commit_running = false;

    // True while a sync is folding remote state into the local store. Any write
    // triggered during that window is an echo of the data we just applied (the
    // UI reacts to the changed model and calls back into us), so pushing it
    // would loop remote changes straight back to the server. All commits are
    // hard-blocked while this is set.
    private bool applying_sync = false;

    private static Things ? _instance;
    public static Things get_default () {
        if (_instance == null) {
            _instance = new Things ();
        }
        return _instance;
    }

    private ThingsQueue queue;

    public Things () {
        session = new Soup.Session ();

        // A sync that hangs mid-history never stores its cursor, so the next
        // launch starts over from the beginning. Bound the wait instead and
        // let the sync report failure and retry.
        session.timeout = 60;
        session.idle_timeout = 60;

        queue = new ThingsQueue (session, this);
    }

    public ThingsQueue write_queue {
        get { return queue; }
    }

    public bool is_syncing {
        get { return applying_sync; }
    }

    private void set_common_headers (Soup.Message message) {
        message.request_headers.replace ("User-Agent", USER_AGENT);
        message.request_headers.append ("Accept", "application/json");
        message.request_headers.append ("Accept-Charset", "UTF-8");
        message.request_headers.append ("App-Id", APP_ID);
        message.request_headers.append ("App-Instance-Id", "-" + APP_ID);
        message.request_headers.append ("Schema", SCHEMA);
    }

    /*
     * Auth
     */

    public async HttpResponse login (string email, string password) {
        var response = new HttpResponse ();

        string url = "%s/account/%s".printf (BASE_URL, GLib.Uri.escape_string (email, null, false));
        var message = new Soup.Message ("GET", url);
        set_common_headers (message);
        message.request_headers.append (
            "Authorization", "Password %s".printf (GLib.Uri.escape_string (password, null, false))
        );

        try {
            GLib.Bytes stream = yield session.send_and_read_async (message, GLib.Priority.HIGH, null);

            if (message.status_code == 401) {
                response.error_code = 401;
                response.error = _("Invalid email or password. Note: accounts with two-factor authentication are not supported.");
                return response;
            }

            if (message.status_code != 200) {
                response.error_code = (int) message.status_code;
                response.error = get_things_error (message.status_code);
                return response;
            }

            var parser = new Json.Parser ();
            parser.load_from_data ((string) stream.get_data ());
            var root = parser.get_root ().get_object ();

            if (!root.has_member ("history-key")) {
                response.error_code = 0;
                response.error = _("Unexpected response from Things Cloud");
                return response;
            }

            var source = new Objects.Source ();
            source.id = Util.get_default ().generate_id ();
            source.source_type = SourceType.THINGS;
            source.display_name = email;

            var things_data = new Objects.SourceThingsData ();
            things_data.email = email;
            things_data.password = password;
            things_data.history_key = root.get_string_member ("history-key");
            things_data.server_index = 0;
            source.data = things_data;
            source.sync_server = true;

            GLib.Value data_object = Value (typeof (Objects.Source));
            data_object.set_object (source);
            response.data_object = data_object;
            response.status = true;

            Services.LogService.get_default ().info ("Things", "Login successful for %s".printf (email));
        } catch (Error e) {
            response.error_code = e.code;
            response.error = e.message;
            Services.LogService.get_default ().error ("Things", "Login failed: %s".printf (e.message));
        }

        return response;
    }

    public async HttpResponse add_things_account (Objects.Source source) {
        var response = new HttpResponse ();

        if (Services.Store.instance ().source_things_exists (source.things_data.email)) {
            response.error_code = 409;
            response.error = _("Source already exists");
            return response;
        }

        Services.Store.instance ().insert_source (source);

        var inbox_project = new Objects.Project ();
        inbox_project.id = source.id + "-inbox";
        inbox_project.source_id = source.id;
        inbox_project.name = _("Inbox");
        inbox_project.inbox_project = true;
        inbox_project.sync_id = SYNC_ID_INBOX;
        inbox_project.color = "blue";
        Services.Store.instance ().insert_project (inbox_project);

        yield sync (source);

        if (source.last_sync == "") {
            response.error_code = 0;
            response.error = _("Failed to download your Things data");
            yield source.delete_source ();
            return response;
        }

        source.save ();
        response.status = true;
        return response;
    }

    /*
     * Sync — walks the history stream forward from the stored cursor and
     * folds every entity diff into the local store.
     */

    public async void sync (Objects.Source source) {
        if (source.things_data == null || source.things_data.history_key == "") {
            return;
        }

        source.sync_started ();
        source.sync_status = null;

        // A full history replay applies every completion that ever happened;
        // muting the sound avoids spawning hundreds of audio pipelines at once.
        Util.get_default ().suppress_completion_sound = true;

        // Block any write the UI tries to echo back while we apply remote state.
        applying_sync = true;

        foreach (var project in Services.Store.instance ().get_projects_by_source (source.id)) {
            project.freeze_update = true;
        }

        bool had_error = false;
        int64 index = source.things_data.server_index;

        while (true) {
            string url = "%s/history/%s/items?start-index=%s".printf (
                BASE_URL, source.things_data.history_key, index.to_string ()
            );

            var message = new Soup.Message ("GET", url);
            set_common_headers (message);

            try {
                // Not Priority.LOW. GLib dispatches only the highest priority
                // among the sources that are ready, so a LOW (300) request
                // never starts while any DEFAULT-priority timer is ready on
                // every iteration — the page after the first would hang, the
                // cursor would never be stored, and the next launch would
                // replay the entire history again.
                GLib.Bytes stream = yield session.send_and_read_async (message, GLib.Priority.DEFAULT, null);

                if (message.status_code != 200) {
                    Services.LogService.get_default ().error (
                        "Things", "Sync failed: HTTP %u".printf (message.status_code)
                    );
                    had_error = true;
                    break;
                }

                var parser = new Json.Parser ();
                parser.load_from_data ((string) stream.get_data ());
                var root = parser.get_root ().get_object ();

                unowned Json.Array items = root.get_array_member ("items");
                foreach (unowned Json.Node server_item in items.get_elements ()) {
                    if (server_item.get_node_type () != Json.NodeType.OBJECT) {
                        continue;
                    }

                    foreach (string uuid in server_item.get_object ().get_members ()) {
                        unowned Json.Node entity = server_item.get_object ().get_member (uuid);
                        if (entity.get_node_type () == Json.NodeType.OBJECT) {
                            apply_entity (source, uuid, entity.get_object ());
                        }
                    }
                }

                // The server caps each page (≈2500 entries) but reports
                // "current-item-index" as the history head, NOT the next
                // cursor. The cursor therefore advances by the number of
                // entries actually consumed; we stop once we reach the head
                // (or a page comes back empty).
                uint page_count = items.get_length ();
                int64 head = ThingsUtil.get_int_or (root, "current-item-index", index);
                index += page_count;

                Services.LogService.get_default ().info (
                    "Things", "Applied %u history entries, cursor %s of %s".printf (
                        page_count, index.to_string (), head.to_string ()
                    )
                );

                int64 end_size = ThingsUtil.get_int_or (root, "end-total-content-size", 0);
                int64 latest_size = ThingsUtil.get_int_or (root, "latest-total-content-size", 0);
                sync_progress (end_size, latest_size, _("Downloading tasks…"));

                if (page_count == 0 || index >= head) {
                    index = head;
                    break;
                }
            } catch (Error e) {
                Services.LogService.get_default ().error ("Things", "Sync failed: %s".printf (e.message));
                had_error = true;
                break;
            }
        }

        if (!had_error) {
            source.things_data.server_index = index;
            source.last_sync = new GLib.DateTime.now_local ().to_string ();
        }

        Util.get_default ().suppress_completion_sound = false;
        applying_sync = false;

        foreach (var project in Services.Store.instance ().get_projects_by_source (source.id)) {
            project.freeze_update = false;
            project.count_update ();
            Services.Store.instance ().update_project (project);
        }

        source.save ();

        Services.LogService.get_default ().info (
            "Things", "Sync %s at cursor %s".printf (had_error ? "failed" : "finished", index.to_string ())
        );

        if (had_error) {
            source.sync_failed ();
        } else {
            source.sync_finished ();

            // Now that the local state is up to date, flush any writes that
            // were queued (and deferred) while the sync was applying.
            if (queue.has_pending (source)) {
                queue.flush.begin (source);
            }
        }
    }

    /*
     * Queues one single-entity commit body ({"uuid": {t,e,p}}) and asks the
     * durable committer to flush. Writes are never sent to the network from
     * here — the ThingsQueue owns conflict handling, backoff, dedup and the
     * circuit breaker. Returns success as soon as the change is durably
     * recorded; the flush proceeds in the background (and again after sync).
     */
    private async HttpResponse enqueue_and_flush (Objects.Source source, string single_entity_body) {
        var obj = Utils.JsonUtils.get_object (single_entity_body);
        foreach (string uuid in obj.get_members ()) {
            var generator = new Json.Generator ();
            generator.set_root (obj.get_member (uuid));
            queue.enqueue (source, uuid, generator.to_data (null));
        }

        // Defer the network flush while a sync is folding remote state in, so a
        // change can never be pushed mid-pull. It stays durably queued and is
        // flushed when the sync finishes.
        if (applying_sync) {
            var deferred = new HttpResponse ();
            deferred.status = true;
            return deferred;
        }

        return yield queue.flush (source);
    }

    /*
     * Raw commit primitive used only by ThingsQueue. Serialized, sets the
     * server cursor on success, and reports the HTTP code so the queue can
     * decide how to react (conflict/backoff/reset).
     */
    public async HttpResponse send_commit (Objects.Source source, string body) {
        var response = new HttpResponse ();

        while (commit_running) {
            Timeout.add (50, send_commit.callback);
            yield;
        }
        commit_running = true;

        string url = "%s/history/%s/commit?ancestor-index=%s&_cnt=1".printf (
            BASE_URL, source.things_data.history_key, source.things_data.server_index.to_string ()
        );

        var message = new Soup.Message ("POST", url);
        set_common_headers (message);
        message.request_headers.append ("Push-Priority", "10");
        message.set_request_body_from_bytes ("application/json; charset=UTF-8", new GLib.Bytes (body.data));

        Services.LogService.get_default ().debug ("Things", "Commit: %s".printf (body));

        try {
            GLib.Bytes stream = yield session.send_and_read_async (message, GLib.Priority.HIGH, null);
            response.http_code = (int) message.status_code;

            if (message.status_code == 200) {
                var parser = new Json.Parser ();
                parser.load_from_data ((string) stream.get_data ());
                var root = parser.get_root ().get_object ();

                source.things_data.server_index = ThingsUtil.get_int_or (
                    root, "server-head-index", source.things_data.server_index + 1
                );
                source.last_sync = new GLib.DateTime.now_local ().to_string ();
                source.save ();
                response.status = true;
            } else {
                response.error_code = (int) message.status_code;
                response.error = get_things_error (message.status_code);
            }
        } catch (Error e) {
            response.http_code = 0;
            response.error_code = e.code;
            response.error = e.message;
        }

        commit_running = false;
        return response;
    }

    /*
     * Recovers from a server-side history reset: the cached history key stops
     * working (401/404), so re-fetch the account's current key. If it changed,
     * adopt it and schedule a full re-sync. Returns true if a usable key is in
     * place afterward.
     */
    public async bool recover_history_key (Objects.Source source) {
        string url = "%s/account/%s/own-history-key".printf (
            BASE_URL, GLib.Uri.escape_string (source.things_data.email, null, false)
        );
        var message = new Soup.Message ("GET", url);
        set_common_headers (message);
        message.request_headers.append (
            "Authorization", "Password %s".printf (GLib.Uri.escape_string (source.things_data.password, null, false))
        );

        try {
            GLib.Bytes stream = yield session.send_and_read_async (message, GLib.Priority.HIGH, null);
            if (message.status_code != 200) {
                return false;
            }

            var parser = new Json.Parser ();
            parser.load_from_data ((string) stream.get_data ());
            var root = parser.get_root ().get_object ();
            if (!root.has_member ("history-key")) {
                return false;
            }

            string current_key = root.get_string_member ("history-key");
            if (current_key != source.things_data.history_key) {
                Services.LogService.get_default ().warn (
                    "Things", "History was reset server-side; adopting new key and re-syncing"
                );
                source.things_data.history_key = current_key;
                source.things_data.server_index = 0;
                source.save ();
                yield sync (source);
            }
            return true;
        } catch (Error e) {
            Services.LogService.get_default ().error ("Things", "History-key recovery failed: %s".printf (e.message));
            return false;
        }
    }

    /*
     * Write operations, mirroring the Services.Todoist surface.
     */

    public async HttpResponse add (Objects.BaseObject object) {
        if (object is Objects.Item) {
            return yield add_item ((Objects.Item) object);
        }

        if (object is Objects.Section) {
            return yield add_section ((Objects.Section) object);
        }

        if (object is Objects.Project) {
            return yield add_project ((Objects.Project) object);
        }

        if (object is Objects.Label) {
            return yield add_label ((Objects.Label) object);
        }

        return not_supported ();
    }

    public async HttpResponse update (Objects.BaseObject object) {
        if (object is Objects.Item) {
            return yield update_item ((Objects.Item) object);
        }

        if (object is Objects.Section) {
            return yield update_section ((Objects.Section) object);
        }

        if (object is Objects.Project) {
            return yield update_project ((Objects.Project) object);
        }

        if (object is Objects.Label) {
            return yield update_label ((Objects.Label) object);
        }

        return not_supported ();
    }

    public async HttpResponse delete (Objects.BaseObject object) {
        var source = object.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        if (object is Objects.Item) {
            HttpResponse ? blocked = ensure_item_writable ((Objects.Item) object);
            if (blocked != null) {
                return blocked;
            }
        } else if (!ThingsUtil.is_things_uuid (object.id)) {
            // Legacy project/heading/tag whose entity kind we can't reproduce.
            return not_supported (_("This item uses an older Things format that Planify can’t safely delete."));
        }

        var builder = new Json.Builder ();
        builder.begin_object ();

        if (object is Objects.Label) {
            ThingsUtil.begin_entity (builder, object.id, 2, KIND_TAG);
            ThingsUtil.end_entity (builder);
        } else if (object is Objects.Item && is_checklist_item ((Objects.Item) object)) {
            ThingsUtil.begin_entity (builder, object.id, 2, write_kind ((Objects.Item) object));
            ThingsUtil.end_entity (builder);
        } else if (object is Objects.Project && ((Objects.Project) object).sync_id == SYNC_ID_AREA) {
            ThingsUtil.begin_entity (builder, object.id, 2, KIND_AREA);
            ThingsUtil.end_entity (builder);
        } else if (object is Objects.Project && ((Objects.Project) object).sync_id == SYNC_ID_INBOX) {
            return not_supported ();
        } else {
            // Tasks, projects and headings are trashed like Things.app does.
            string kind = (object is Objects.Item) ? write_kind ((Objects.Item) object) : KIND_TASK;
            ThingsUtil.begin_entity (builder, object.id, 1, kind);
            builder.set_member_name ("tr");
            builder.add_boolean_value (true);
            add_md (builder);
            ThingsUtil.end_entity (builder);
        }

        builder.end_object ();
        return yield enqueue_and_flush (source, generate (builder));
    }

    public async HttpResponse complete_item (Objects.Item item) {
        var source = item.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        HttpResponse ? blocked = ensure_item_writable (item);
        if (blocked != null) {
            return blocked;
        }

        var builder = new Json.Builder ();
        builder.begin_object ();
        ThingsUtil.begin_entity (builder, item.id, 1, write_kind (item));

        builder.set_member_name ("ss");
        builder.add_int_value (item.checked ? ThingsUtil.STATUS_COMPLETED : ThingsUtil.STATUS_OPEN);

        builder.set_member_name ("sp");
        if (item.checked) {
            builder.add_double_value (ThingsUtil.now_epoch ());
        } else {
            builder.add_null_value ();
        }

        // Things.app pairs every completion with st=1. Instances of repeating
        // tasks sit in Someday (st=2) until their day arrives, and a completed
        // task left there stays invisible in every list; moving it back to
        // Anytime is what makes it show up in the Logbook.
        if (item.checked) {
            builder.set_member_name ("st");
            builder.add_int_value (ThingsUtil.START_ANYTIME);
        }

        add_md (builder);
        ThingsUtil.end_entity (builder);
        builder.end_object ();

        return yield enqueue_and_flush (source, generate (builder));
    }

    public async HttpResponse close_item (Objects.Item item) {
        return yield complete_item (item);
    }

    public async HttpResponse move_item (Objects.Item item, string type, string id) {
        var source = item.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        HttpResponse ? blocked = ensure_item_writable (item);
        if (blocked != null) {
            return blocked;
        }

        if (is_checklist_item (item)) {
            if (type == "parent_id" && id != "") {
                Objects.Item ? parent = Services.Store.instance ().get_item (id);
                if (parent == null || is_checklist_item (parent)) {
                    return not_supported (_("Things only supports one level of subtasks"));
                }

                var builder = new Json.Builder ();
                builder.begin_object ();
                ThingsUtil.begin_entity (builder, item.id, 1, write_kind (item));
                ThingsUtil.add_string_array (builder, "ts", { id });
                add_md (builder);
                ThingsUtil.end_entity (builder);
                builder.end_object ();

                return yield enqueue_and_flush (source, generate (builder));
            }

            return not_supported (_("Subtasks can’t be converted to tasks in Things"));
        }

        if (type == "parent_id") {
            return not_supported (_("Tasks can’t be converted to subtasks in Things"));
        }

        string project_id = "";
        string section_id = "";

        if (type == "section_id") {
            section_id = id;
            Objects.Section ? section = Services.Store.instance ().get_section (id);
            if (section != null) {
                project_id = section.project_id;
            }
        } else {
            project_id = id;
        }

        var builder = new Json.Builder ();
        builder.begin_object ();
        ThingsUtil.begin_entity (builder, item.id, 1, write_kind (item));
        add_task_placement (
            builder, source, project_id, section_id,
            item.due.date, item.deadline_date, is_recurring_due (item.due)
        );
        add_md (builder);
        ThingsUtil.end_entity (builder);
        builder.end_object ();

        return yield enqueue_and_flush (source, generate (builder));
    }

    public async void update_items (Gee.ArrayList<Objects.Item> objects) {
        foreach (Objects.Item item in objects) {
            yield update_item (item);
        }
    }

    /*
     * Items
     */

    private async HttpResponse add_item (Objects.Item item) {
        var source = item.project.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        string uuid = ThingsUtil.generate_uuid ();
        var builder = new Json.Builder ();
        builder.begin_object ();

        if (item.parent_id != "") {
            Objects.Item ? parent = Services.Store.instance ().get_item (item.parent_id);
            if (parent == null || is_checklist_item (parent)) {
                return not_supported (_("Things only supports one level of subtasks"));
            }

            ThingsUtil.begin_entity (builder, uuid, 0, KIND_CHECKLIST);
            add_checklist_fields (builder, item, true);
            ThingsUtil.end_entity (builder);
            item.extra_data = build_extra_data (KIND_CHECKLIST, false, false, false);
        } else {
            ThingsUtil.begin_entity (builder, uuid, 0, KIND_TASK);
            add_task_fields (builder, source, item, true);
            ThingsUtil.end_entity (builder);
            item.extra_data = build_extra_data (KIND_TASK, is_recurring_due (item.due), false, false);
        }

        builder.end_object ();

        HttpResponse response = yield enqueue_and_flush (source, generate (builder));
        if (response.status) {
            response.data = uuid;
        }

        return response;
    }

    private async HttpResponse update_item (Objects.Item item) {
        var source = item.project.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        HttpResponse ? blocked = ensure_item_writable (item);
        if (blocked != null) {
            return blocked;
        }

        var builder = new Json.Builder ();
        builder.begin_object ();

        if (is_checklist_item (item)) {
            ThingsUtil.begin_entity (builder, item.id, 1, write_kind (item));
            add_checklist_fields (builder, item, false);
        } else {
            ThingsUtil.begin_entity (builder, item.id, 1, write_kind (item));
            add_task_fields (builder, source, item, false);
        }

        ThingsUtil.end_entity (builder);
        builder.end_object ();

        return yield enqueue_and_flush (source, generate (builder));
    }

    private void add_task_fields (Json.Builder builder, Objects.Source source, Objects.Item item, bool create) {
        builder.set_member_name ("tt");
        builder.add_string_value (item.content);

        ThingsUtil.add_note (builder, item.description);

        builder.set_member_name ("ss");
        builder.add_int_value (item.checked ? ThingsUtil.STATUS_COMPLETED : ThingsUtil.STATUS_OPEN);

        builder.set_member_name ("sp");
        if (item.checked && item.completed_at != "") {
            var completed = new GLib.DateTime.from_iso8601 (item.completed_at, new GLib.TimeZone.local ());
            builder.add_double_value (completed != null ? ThingsUtil.datetime_to_epoch (completed) : ThingsUtil.now_epoch ());
        } else {
            builder.add_null_value ();
        }

        add_task_placement (
            builder, source, item.project_id, item.section_id,
            item.due.date, item.deadline_date, is_recurring_due (item.due)
        );

        string[] tags = {};
        foreach (Objects.Label label in item.labels) {
            tags += label.id;
        }
        ThingsUtil.add_string_array (builder, "tg", tags);

        builder.set_member_name ("ix");
        builder.add_int_value (item.child_order);

        // Write back the Today hand-ordering so reorders round-trip to Things.
        builder.set_member_name ("ti");
        builder.add_int_value (item.day_order);

        // Things has no evening flag in Planify's model, so it survives a round
        // trip only by being echoed back from what the last sync recorded.
        builder.set_member_name ("sb");
        builder.add_int_value (is_evening_item (item) ? ThingsUtil.BUCKET_EVENING : ThingsUtil.BUCKET_DAY);

        add_reminder_field (builder, item);
        add_recurrence_fields (builder, item, create);

        if (create) {
            builder.set_member_name ("tp");
            builder.add_int_value (ThingsUtil.TYPE_TASK);

            add_create_defaults (builder, false, false);
        } else {
            add_md (builder);
        }
    }

    /*
     * "ato" is the reminder as seconds after midnight on the scheduled day.
     * Planify allows several reminders and relative ones; Things has room for
     * a single absolute time, so the earliest absolute reminder wins and the
     * rest stay Planify-only.
     */
    private void add_reminder_field (Json.Builder builder, Objects.Item item) {
        int64 earliest = -1;

        foreach (Objects.Reminder reminder in item.reminders) {
            if (reminder.reminder_type != ReminderType.ABSOLUTE) {
                continue;
            }

            GLib.DateTime ? datetime = reminder.due.datetime;
            if (datetime == null) {
                continue;
            }

            int64 seconds = ThingsUtil.seconds_after_midnight (datetime);
            if (earliest < 0 || seconds < earliest) {
                earliest = seconds;
            }
        }

        builder.set_member_name ("ato");
        if (earliest >= 0 && item.due.date != "") {
            builder.add_int_value (earliest);
        } else {
            builder.add_null_value ();
        }
    }

    /*
     * A Things task that carries a repeat rule is a template: Things hides it
     * and expands it into dated instances. "icsd" is the date the expander
     * should start generating from, and "icc" counts what it has produced —
     * a fresh series starts at zero from the first scheduled day.
     */
    private void add_recurrence_fields (Json.Builder builder, Objects.Item item, bool create) {
        int64 series_start = ThingsUtil.date_string_to_day_epoch (item.due.date);
        if (series_start < 0) {
            series_start = ThingsUtil.today_day_epoch ();
        }

        ThingsUtil.add_recurrence (builder, item.due, series_start);

        // The expander's counters belong to Things. Touch them only when this
        // write actually defines a series — resending icc on an unrelated edit
        // would rewind the count of instances Things has already produced.
        bool recurring = is_recurring_due (item.due);
        if (!create && !recurring) {
            return;
        }

        builder.set_member_name ("icc");
        builder.add_int_value (0);

        builder.set_member_name ("icsd");
        if (recurring) {
            builder.add_int_value (series_start);
        } else {
            builder.add_null_value ();
        }
    }

    private void add_checklist_fields (Json.Builder builder, Objects.Item item, bool create) {
        builder.set_member_name ("tt");
        builder.add_string_value (item.content);

        builder.set_member_name ("ss");
        builder.add_int_value (item.checked ? ThingsUtil.STATUS_COMPLETED : ThingsUtil.STATUS_OPEN);

        builder.set_member_name ("sp");
        if (item.checked) {
            builder.add_double_value (ThingsUtil.now_epoch ());
        } else {
            builder.add_null_value ();
        }

        builder.set_member_name ("ix");
        builder.add_int_value (item.child_order);

        if (create) {
            ThingsUtil.add_string_array (builder, "ts", { item.parent_id });

            builder.set_member_name ("lt");
            builder.add_boolean_value (false);

            add_xx (builder);
            add_cd (builder);

            builder.set_member_name ("md");
            builder.add_null_value ();
        } else {
            add_md (builder);
        }
    }

    /*
     * Computes pr/ar/agr/st/sr/tir/dd for a task from its Planify placement.
     * Things demands consistent combinations: scheduled tasks must not stay
     * in the Inbox (st=0) and tasks inside projects/headings default to
     * Anytime (st=1).
     */
    private void add_task_placement (Json.Builder builder, Objects.Source source,
                                     string project_id, string section_id,
                                     string due_date, string deadline_date,
                                     bool recurring = false) {
        string[] pr = {};
        string[] ar = {};
        string[] agr = {};
        bool in_inbox = true;

        if (section_id != "") {
            agr = { section_id };
            in_inbox = false;
        } else if (project_id != "") {
            Objects.Project ? project = Services.Store.instance ().get_project (project_id);
            if (project != null && !project.inbox_project) {
                in_inbox = false;
                if (project.sync_id == SYNC_ID_AREA) {
                    ar = { project.id };
                } else {
                    pr = { project.id };
                }
            }
        }

        int64 scheduled = ThingsUtil.date_string_to_day_epoch (due_date);
        int start;
        if (recurring) {
            // A repeat rule makes this the series template, which Things keeps
            // out of every dated list: st=2 with no scheduled date of its own.
            start = ThingsUtil.START_SOMEDAY;
        } else if (scheduled >= 0) {
            start = scheduled > ThingsUtil.today_day_epoch () ? ThingsUtil.START_SOMEDAY : ThingsUtil.START_ANYTIME;
        } else if (in_inbox) {
            start = ThingsUtil.START_INBOX;
        } else {
            start = ThingsUtil.START_ANYTIME;
        }

        ThingsUtil.add_string_array (builder, "pr", pr);
        ThingsUtil.add_string_array (builder, "ar", ar);
        ThingsUtil.add_string_array (builder, "agr", agr);

        builder.set_member_name ("st");
        builder.add_int_value (start);

        builder.set_member_name ("sr");
        if (scheduled >= 0 && !recurring) {
            builder.add_int_value (scheduled);
        } else {
            builder.add_null_value ();
        }

        builder.set_member_name ("tir");
        if (scheduled >= 0) {
            builder.add_int_value (scheduled);
        } else {
            builder.add_null_value ();
        }

        builder.set_member_name ("dd");
        int64 deadline = ThingsUtil.date_string_to_day_epoch (deadline_date);
        if (deadline >= 0) {
            builder.add_int_value (deadline);
        } else {
            builder.add_null_value ();
        }
    }

    /*
     * Projects — Planify projects become Things projects; projects created
     * under an area-project join that area.
     */

    private async HttpResponse add_project (Objects.Project project) {
        var source = project.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        string uuid = ThingsUtil.generate_uuid ();
        var builder = new Json.Builder ();
        builder.begin_object ();
        ThingsUtil.begin_entity (builder, uuid, 0, KIND_TASK);
        add_project_fields (builder, project, true);
        ThingsUtil.end_entity (builder);
        builder.end_object ();

        HttpResponse response = yield enqueue_and_flush (source, generate (builder));
        if (response.status) {
            response.data = uuid;
            project.sync_id = SYNC_ID_PROJECT;
            project.backend_type = SourceType.THINGS;
        }

        return response;
    }

    private async HttpResponse update_project (Objects.Project project) {
        var source = project.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        if (project.sync_id == SYNC_ID_INBOX) {
            return not_supported ();
        }

        // Never write a modern Task6/Area3 for a legacy hyphenated-UUID entity.
        if (!ThingsUtil.is_things_uuid (project.id)) {
            return not_supported (_("This uses an older Things format that Planify can’t safely modify."));
        }

        var builder = new Json.Builder ();
        builder.begin_object ();

        if (project.sync_id == SYNC_ID_AREA) {
            ThingsUtil.begin_entity (builder, project.id, 1, KIND_AREA);
            builder.set_member_name ("tt");
            builder.add_string_value (project.name);
            builder.set_member_name ("ix");
            builder.add_int_value (project.child_order);
        } else {
            ThingsUtil.begin_entity (builder, project.id, 1, KIND_TASK);
            add_project_fields (builder, project, false);
        }

        ThingsUtil.end_entity (builder);
        builder.end_object ();

        return yield enqueue_and_flush (source, generate (builder));
    }

    private void add_project_fields (Json.Builder builder, Objects.Project project, bool create) {
        builder.set_member_name ("tt");
        builder.add_string_value (project.name);

        ThingsUtil.add_note (builder, project.description);

        string[] ar = {};
        if (project.parent_id != "") {
            Objects.Project ? parent = Services.Store.instance ().get_project (project.parent_id);
            if (parent != null && parent.sync_id == SYNC_ID_AREA) {
                ar = { parent.id };
            }
        }
        ThingsUtil.add_string_array (builder, "ar", ar);

        builder.set_member_name ("ix");
        builder.add_int_value (project.child_order);

        if (!create) {
            // Things has no archive flag; a finished project is one whose
            // status is completed, which is what takes it out of the sidebar.
            builder.set_member_name ("ss");
            builder.add_int_value (project.is_archived ? ThingsUtil.STATUS_COMPLETED : ThingsUtil.STATUS_OPEN);

            builder.set_member_name ("sp");
            if (project.is_archived) {
                builder.add_double_value (ThingsUtil.now_epoch ());
            } else {
                builder.add_null_value ();
            }
        }

        if (create) {
            builder.set_member_name ("tp");
            builder.add_int_value (ThingsUtil.TYPE_PROJECT);

            ThingsUtil.add_string_array (builder, "pr", {});
            ThingsUtil.add_string_array (builder, "agr", {});
            ThingsUtil.add_string_array (builder, "tg", {});

            builder.set_member_name ("ss");
            builder.add_int_value (ThingsUtil.STATUS_OPEN);
            builder.set_member_name ("sp");
            builder.add_null_value ();
            builder.set_member_name ("st");
            builder.add_int_value (ThingsUtil.START_ANYTIME);
            builder.set_member_name ("sr");
            builder.add_null_value ();
            builder.set_member_name ("tir");
            builder.add_null_value ();
            builder.set_member_name ("dd");
            builder.add_null_value ();

            add_create_defaults (builder, true);
        } else {
            add_md (builder);
        }
    }

    /*
     * Sections — Things headings.
     */

    private async HttpResponse add_section (Objects.Section section) {
        var source = section.project.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        string uuid = ThingsUtil.generate_uuid ();
        var builder = new Json.Builder ();
        builder.begin_object ();
        ThingsUtil.begin_entity (builder, uuid, 0, KIND_TASK);

        builder.set_member_name ("tt");
        builder.add_string_value (section.name);
        builder.set_member_name ("tp");
        builder.add_int_value (ThingsUtil.TYPE_HEADING);

        ThingsUtil.add_string_array (builder, "pr", { section.project_id });
        ThingsUtil.add_string_array (builder, "ar", {});
        ThingsUtil.add_string_array (builder, "agr", {});
        ThingsUtil.add_string_array (builder, "tg", {});

        builder.set_member_name ("ss");
        builder.add_int_value (ThingsUtil.STATUS_OPEN);
        builder.set_member_name ("sp");
        builder.add_null_value ();
        builder.set_member_name ("st");
        builder.add_int_value (ThingsUtil.START_ANYTIME);
        builder.set_member_name ("sr");
        builder.add_null_value ();
        builder.set_member_name ("tir");
        builder.add_null_value ();
        builder.set_member_name ("dd");
        builder.add_null_value ();

        builder.set_member_name ("ix");
        builder.add_int_value (section.section_order);

        add_create_defaults (builder);
        ThingsUtil.end_entity (builder);
        builder.end_object ();

        HttpResponse response = yield enqueue_and_flush (source, generate (builder));
        if (response.status) {
            response.data = uuid;
        }

        return response;
    }

    private async HttpResponse update_section (Objects.Section section) {
        var source = section.project.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        if (!ThingsUtil.is_things_uuid (section.id)) {
            return not_supported (_("This heading uses an older Things format that Planify can’t safely modify."));
        }

        var builder = new Json.Builder ();
        builder.begin_object ();
        ThingsUtil.begin_entity (builder, section.id, 1, KIND_TASK);

        builder.set_member_name ("tt");
        builder.add_string_value (section.name);
        builder.set_member_name ("ix");
        builder.add_int_value (section.section_order);
        add_md (builder);

        ThingsUtil.end_entity (builder);
        builder.end_object ();

        return yield enqueue_and_flush (source, generate (builder));
    }

    /*
     * Labels — Things tags.
     */

    private async HttpResponse add_label (Objects.Label label) {
        var source = label.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        string uuid = ThingsUtil.generate_uuid ();
        var builder = new Json.Builder ();
        builder.begin_object ();
        ThingsUtil.begin_entity (builder, uuid, 0, KIND_TAG);

        builder.set_member_name ("tt");
        builder.add_string_value (label.name);
        builder.set_member_name ("sh");
        builder.add_null_value ();
        ThingsUtil.add_string_array (builder, "pn", {});
        builder.set_member_name ("ix");
        builder.add_int_value (label.item_order);
        add_xx (builder);

        ThingsUtil.end_entity (builder);
        builder.end_object ();

        HttpResponse response = yield enqueue_and_flush (source, generate (builder));
        if (response.status) {
            response.data = uuid;
        }

        return response;
    }

    private async HttpResponse update_label (Objects.Label label) {
        var source = label.source;
        if (source == null || source.things_data == null) {
            return not_supported ();
        }

        if (!ThingsUtil.is_things_uuid (label.id)) {
            return not_supported (_("This tag uses an older Things format that Planify can’t safely modify."));
        }

        var builder = new Json.Builder ();
        builder.begin_object ();
        ThingsUtil.begin_entity (builder, label.id, 1, KIND_TAG);

        builder.set_member_name ("tt");
        builder.add_string_value (label.name);
        builder.set_member_name ("ix");
        builder.add_int_value (label.item_order);

        ThingsUtil.end_entity (builder);
        builder.end_object ();

        return yield enqueue_and_flush (source, generate (builder));
    }

    /*
     * Shared payload fragments
     */

    /*
     * The fields every newly created Task6 carries. "schedule_fields" covers
     * the ones add_task_fields writes from the item itself (repeat rule,
     * reminder, evening bucket, Today index); sections and projects have no
     * such state, so they take the neutral values from here instead. Writing
     * a member twice would emit it twice and let the server keep whichever
     * copy it parsed last, so exactly one side must own each.
     */
    private void add_create_defaults (Json.Builder builder, bool is_project = false,
                                      bool schedule_fields = true) {
        ThingsUtil.add_string_array (builder, "rt", {});
        ThingsUtil.add_string_array (builder, "dl", {});

        if (schedule_fields) {
            builder.set_member_name ("ti");
            builder.add_int_value (0);
            builder.set_member_name ("sb");
            builder.add_int_value (ThingsUtil.BUCKET_DAY);
            builder.set_member_name ("rr");
            builder.add_null_value ();
            builder.set_member_name ("ato");
            builder.add_null_value ();
            builder.set_member_name ("icc");
            builder.add_int_value (0);
            builder.set_member_name ("icsd");
            builder.add_null_value ();
        }

        builder.set_member_name ("do");
        builder.add_int_value (0);
        builder.set_member_name ("icp");
        builder.add_boolean_value (is_project);
        builder.set_member_name ("lt");
        builder.add_boolean_value (false);
        builder.set_member_name ("tr");
        builder.add_boolean_value (false);
        builder.set_member_name ("rmd");
        builder.add_null_value ();
        builder.set_member_name ("rp");
        builder.add_null_value ();
        builder.set_member_name ("lai");
        builder.add_null_value ();
        builder.set_member_name ("dds");
        builder.add_null_value ();
        builder.set_member_name ("acrd");
        builder.add_null_value ();

        add_xx (builder);
        add_cd (builder);

        builder.set_member_name ("md");
        builder.add_null_value ();
    }

    private void add_xx (Json.Builder builder) {
        builder.set_member_name ("xx");
        builder.begin_object ();
        builder.set_member_name ("_t");
        builder.add_string_value ("oo");
        builder.set_member_name ("sn");
        builder.begin_object ();
        builder.end_object ();
        builder.end_object ();
    }

    private void add_cd (Json.Builder builder) {
        builder.set_member_name ("cd");
        builder.add_double_value (ThingsUtil.now_epoch ());
    }

    private void add_md (Json.Builder builder) {
        builder.set_member_name ("md");
        builder.add_double_value (ThingsUtil.now_epoch ());
    }

    private string generate (Json.Builder builder) {
        var generator = new Json.Generator ();
        generator.set_root (builder.get_root ());
        return generator.to_data (null);
    }

    private HttpResponse not_supported (string message = "") {
        var response = new HttpResponse ();
        response.status = false;
        response.error = message != "" ? message : _("This operation is not supported by Things Cloud");
        return response;
    }

    /*
     * Per-item Things metadata, persisted in Objects.Item.extra_data.
     *
     * things_kind: the exact entity kind Things assigned to this item.
     * Preserving it is critical: older items are stored as Task3/Task4 with
     * hyphenated UUIDs, and their read path does NOT Base58-decode the key.
     * Writing a newer Task6 for such a UUID makes Things Base58-decode a
     * hyphenated string and crash. So we always write back the kind we
     * received, never an upgraded one.
     *
     * things_template: this item carries a recurrence rule ("rr"), i.e. it is
     * the hidden series definition that Things expands into instances.
     * things_instance: this item was generated from a template ("rt").
     * things_evening: Things' evening bucket ("sb"), which Planify's model has
     * no field for but must not silently drop on a round trip.
     */

    private string build_extra_data (string kind, bool template, bool instance, bool evening) {
        return "{\"things_kind\": \"%s\", \"things_template\": %s, \"things_instance\": %s, \"things_evening\": %s}".printf (
            kind,
            template ? "true" : "false",
            instance ? "true" : "false",
            evening ? "true" : "false"
        );
    }

    private string stored_kind (Objects.Item item) {
        if (item.extra_data != "") {
            return Utils.JsonUtils.get_string (item.extra_data, "things_kind");
        }
        return "";
    }

    private bool stored_flag (Objects.Item item, string member) {
        return item.extra_data != "" && Utils.JsonUtils.get_bool (item.extra_data, member);
    }

    // The hidden series definition. Editing one means regenerating every
    // instance Things derived from it, which only Things.app knows how to do.
    private bool is_recurrence_template (Objects.Item item) {
        return stored_flag (item, "things_template");
    }

    private bool is_evening_item (Objects.Item item) {
        return stored_flag (item, "things_evening");
    }

    private bool is_recurring_due (Objects.DueDate due) {
        return due.is_recurring && due.recurrency_type != RecurrencyType.NONE;
    }

    private bool is_checklist_item (Objects.Item item) {
        string kind = stored_kind (item);
        if (kind != "") {
            return kind.has_prefix ("Checklist");
        }

        return item.parent_id != "";
    }

    // The entity kind to use when writing this item: the exact kind Things gave
    // us, or a safe default for items Planify created itself (Base58 UUIDs).
    private string write_kind (Objects.Item item) {
        string kind = stored_kind (item);
        if (kind != "") {
            return kind;
        }
        return item.parent_id != "" ? KIND_CHECKLIST : KIND_TASK;
    }

    /*
     * Gate every write to an item. Refuses operations that would corrupt the
     * Things account: recurrence templates (changing the rule means Things has
     * to regenerate the whole instance chain) and legacy items whose kind we
     * never captured (writing Task6 for a non-Base58 UUID crashes Things).
     *
     * Instances of repeating tasks are deliberately NOT blocked. Things.app
     * completes one with a plain {st, sp, ss, md} status commit, exactly like
     * any other task; the template's own bookkeeping (icc/icsd) is advanced
     * separately by whichever client next expands the series. Refusing them
     * would make every repeating task read-only in Planify for no gain.
     */
    private HttpResponse ? ensure_item_writable (Objects.Item item) {
        if (is_recurrence_template (item)) {
            return not_supported (
                _("This is a repeating task’s schedule — change how it repeats in Things.")
            );
        }

        if (stored_kind (item) == "" && !ThingsUtil.is_things_uuid (item.id)) {
            return not_supported (
                _("This task uses an older Things format that Planify can’t safely modify.")
            );
        }

        return null;
    }

    /*
     * History entity folding
     */

    private void apply_entity (Objects.Source source, string uuid, Json.Object entity) {
        string kind = entity.has_member ("e") ? entity.get_string_member ("e") : "";
        int operation = (int) ThingsUtil.get_int_or (entity, "t", 1);

        Json.Object payload = new Json.Object ();
        if (entity.has_member ("p") && entity.get_member ("p").get_node_type () == Json.NodeType.OBJECT) {
            payload = entity.get_object_member ("p");
        }

        if (kind.has_prefix ("Task")) {
            apply_task (source, uuid, operation, payload, kind);
        } else if (kind.has_prefix ("ChecklistItem")) {
            apply_checklist (source, uuid, operation, payload, kind);
        } else if (kind.has_prefix ("Area")) {
            apply_area (source, uuid, operation, payload);
        } else if (kind.has_prefix ("Tag")) {
            apply_tag (source, uuid, operation, payload);
        } else if (kind.has_prefix ("Tombstone")) {
            if (payload.has_member ("dloid")) {
                delete_any (payload.get_string_member ("dloid"));
            }
        }
    }

    private void apply_task (Objects.Source source, string uuid, int operation, Json.Object payload, string kind) {
        if (operation == 2) {
            forget_template (source, uuid);
            delete_any (uuid);
            return;
        }

        // A task that carries a repeat rule is the series template. Things
        // never shows it — the dated instances it spawns are the real tasks —
        // so record the rule and keep the template out of Planify entirely.
        if (payload.has_member ("rr") && !ThingsUtil.is_null_member (payload, "rr")) {
            remember_template (source, uuid, payload.get_object_member ("rr"));
            delete_any (uuid);
            return;
        }

        if (is_known_template (source, uuid)) {
            // Bookkeeping updates (icc/icsd) keep arriving for templates. If
            // the rule was cleared the series is over and it becomes an
            // ordinary task again; otherwise there is nothing to show.
            if (payload.has_member ("rr")) {
                forget_template (source, uuid);
            } else {
                return;
            }
        }

        Objects.Item ? item = Services.Store.instance ().get_item (uuid);
        if (item != null) {
            patch_item (source, item, payload, kind);
            return;
        }

        Objects.Section ? section = Services.Store.instance ().get_section (uuid);
        if (section != null) {
            patch_section (section, payload);
            return;
        }

        Objects.Project ? project = Services.Store.instance ().get_project (uuid);
        if (project != null) {
            patch_project (source, project, payload);
            return;
        }

        int type = (int) ThingsUtil.get_int_or (payload, "tp", ThingsUtil.TYPE_TASK);
        if (type == ThingsUtil.TYPE_PROJECT) {
            create_project (source, uuid, payload);
        } else if (type == ThingsUtil.TYPE_HEADING) {
            create_section (source, uuid, payload);
        } else {
            create_item (source, uuid, payload, kind);
        }
    }

    private void create_item (Objects.Source source, string uuid, Json.Object payload, string kind) {
        if (payload.has_member ("tr") && payload.get_boolean_member ("tr")) {
            return;
        }

        var item = new Objects.Item ();
        item.id = uuid;
        apply_item_fields (source, item, payload, kind);

        insert_item (source, item);
        apply_reminder (item, payload);
    }

    private void patch_item (Objects.Source source, Objects.Item item, Json.Object payload, string kind) {
        if (payload.has_member ("tr") && payload.get_boolean_member ("tr")) {
            Services.Store.instance ().delete_item (item);
            return;
        }

        string old_project_id = item.project_id;
        string old_section_id = item.section_id;
        string old_parent_id = item.parent_id;
        bool old_checked = item.checked;

        apply_item_fields (source, item, payload, kind);
        Services.Store.instance ().update_item (item);
        apply_reminder (item, payload);

        if (old_project_id != item.project_id || old_section_id != item.section_id ||
            old_parent_id != item.parent_id) {
            Services.EventBus.get_default ().item_moved (item, old_project_id, old_section_id, old_parent_id);
        }

        if (old_checked != item.checked) {
            Services.Store.instance ().complete_item (item, old_checked);
        }
    }

    private void apply_item_fields (Objects.Source source, Objects.Item item, Json.Object payload, string kind) {
        // Remember the exact entity kind Things uses for this item, plus the
        // flags writes have to respect. History entries are partial diffs, so
        // a field the payload omits keeps whatever we already knew.
        bool template = is_recurrence_template (item);
        bool instance = stored_flag (item, "things_instance");
        bool evening = is_evening_item (item);

        if (payload.has_member ("rr")) {
            template = !ThingsUtil.is_null_member (payload, "rr");
        }
        if (payload.has_member ("rt")) {
            instance = ThingsUtil.parse_string_array (payload, "rt").length > 0;
        }
        if (payload.has_member ("sb")) {
            evening = ThingsUtil.get_int_or (payload, "sb", ThingsUtil.BUCKET_DAY) == ThingsUtil.BUCKET_EVENING;
        }

        item.extra_data = build_extra_data (kind, template, instance, evening);

        if (payload.has_member ("rt")) {
            apply_instance_recurrence (source, item, ThingsUtil.parse_string_array (payload, "rt"));
        }

        if (payload.has_member ("tt")) {
            item.content = payload.get_string_member ("tt");
        }

        if (payload.has_member ("nt")) {
            item.description = ThingsUtil.parse_note (payload.get_member ("nt"), item.description);
        }

        if (payload.has_member ("ss")) {
            item.checked = ThingsUtil.get_int_or (payload, "ss", ThingsUtil.STATUS_OPEN) != ThingsUtil.STATUS_OPEN;
            if (!item.checked) {
                item.completed_at = "";
            }
        }

        if (payload.has_member ("sp") && !ThingsUtil.is_null_member (payload, "sp")) {
            item.completed_at = ThingsUtil.epoch_to_datetime_string (
                ThingsUtil.get_double_or (payload, "sp", 0)
            );
        }

        if (payload.has_member ("sr")) {
            if (ThingsUtil.is_null_member (payload, "sr")) {
                item.due.date = "";
            } else {
                item.due.date = ThingsUtil.day_epoch_to_date_string (
                    ThingsUtil.get_int_or (payload, "sr", 0)
                );
            }
        }

        if (payload.has_member ("dd")) {
            if (ThingsUtil.is_null_member (payload, "dd")) {
                item.deadline_date = "";
            } else {
                item.deadline_date = ThingsUtil.day_epoch_to_date_string (
                    ThingsUtil.get_int_or (payload, "dd", 0)
                );
            }
        }

        if (payload.has_member ("cd") && !ThingsUtil.is_null_member (payload, "cd")) {
            item.added_at = ThingsUtil.epoch_to_datetime_string (
                ThingsUtil.get_double_or (payload, "cd", 0)
            );
        }

        if (payload.has_member ("ix")) {
            item.child_order = (int) ThingsUtil.get_int_or (payload, "ix", 0);
        }

        // Things keeps a separate hand-ordered index for the Today view ("ti");
        // map it to Planify's day_order so the Today list can mirror it.
        if (payload.has_member ("ti")) {
            item.day_order = (int) ThingsUtil.get_int_or (payload, "ti", 0);
        }

        if (payload.has_member ("pr") || payload.has_member ("ar") || payload.has_member ("agr")) {
            string[] pr = ThingsUtil.parse_string_array (payload, "pr");
            string[] ar = ThingsUtil.parse_string_array (payload, "ar");
            string[] agr = ThingsUtil.parse_string_array (payload, "agr");

            item.section_id = agr.length > 0 ? agr[0] : "";

            if (agr.length > 0) {
                Objects.Section ? section = Services.Store.instance ().get_section (agr[0]);
                if (section != null) {
                    item.project_id = section.project_id;
                } else if (pr.length > 0) {
                    item.project_id = pr[0];
                }
            } else if (pr.length > 0) {
                item.project_id = pr[0];
            } else if (ar.length > 0) {
                item.project_id = ar[0];
            } else {
                item.project_id = inbox_project_id (source);
            }
        }

        if (item.project_id == "") {
            item.project_id = inbox_project_id (source);
        }

        if (payload.has_member ("tg")) {
            item.labels.clear ();
            foreach (string tag_id in ThingsUtil.parse_string_array (payload, "tg")) {
                Objects.Label ? label = Services.Store.instance ().get_label (tag_id);
                if (label != null) {
                    item.labels.add (label);
                }
            }
        }
    }

    /*
     * Things stores a reminder as "ato": seconds after midnight on the task's
     * scheduled day, so it only becomes an absolute time once "sr" is known.
     * Planify keeps reminders as separate rows, hence this runs after the item
     * itself is in the store.
     */
    private void apply_reminder (Objects.Item item, Json.Object payload) {
        if (!payload.has_member ("ato")) {
            return;
        }

        foreach (Objects.Reminder existing in item.reminders) {
            if (existing.reminder_type == ReminderType.ABSOLUTE) {
                Services.Store.instance ().delete_reminder (existing);
            }
        }

        if (ThingsUtil.is_null_member (payload, "ato") || item.due.date == "" || item.checked) {
            return;
        }

        string datetime = ThingsUtil.reminder_datetime_string (
            item.due.date, ThingsUtil.get_int_or (payload, "ato", 0)
        );
        if (datetime == "") {
            return;
        }

        // Only reminders that have yet to fire. A history replay walks over
        // years of already-past reminders, and Planify notifies immediately
        // for any reminder whose time has gone — which would mean a burst of
        // urgent notifications for tasks finished long ago.
        var parsed = new GLib.DateTime.from_iso8601 (datetime, new GLib.TimeZone.local ());
        if (parsed == null || parsed.compare (new GLib.DateTime.now_local ()) <= 0) {
            return;
        }

        var reminder = new Objects.Reminder ();
        reminder.item_id = item.id;
        reminder.reminder_type = ReminderType.ABSOLUTE;
        reminder.due.date = datetime;
        reminder.id = Util.get_default ().generate_id (reminder);

        item.add_reminder_if_not_exists (reminder);
    }

    private void apply_checklist (Objects.Source source, string uuid, int operation, Json.Object payload, string kind) {
        if (operation == 2) {
            delete_any (uuid);
            return;
        }

        Objects.Item ? item = Services.Store.instance ().get_item (uuid);

        if (item == null) {
            item = new Objects.Item ();
            item.id = uuid;
            item.extra_data = build_extra_data (kind, false, false, false);
            apply_checklist_item_fields (item, payload);

            Objects.Item ? parent = Services.Store.instance ().get_item (item.parent_id);
            if (parent == null) {
                return;
            }

            item.project_id = parent.project_id;
            parent.add_item_if_not_exists (item);
            return;
        }

        item.extra_data = build_extra_data (kind, false, false, false);
        bool old_checked = item.checked;
        apply_checklist_item_fields (item, payload);
        Services.Store.instance ().update_item (item);

        if (old_checked != item.checked) {
            Services.Store.instance ().complete_item (item, old_checked);
        }
    }

    private void apply_checklist_item_fields (Objects.Item item, Json.Object payload) {
        if (payload.has_member ("tt")) {
            item.content = payload.get_string_member ("tt");
        }

        if (payload.has_member ("ss")) {
            item.checked = ThingsUtil.get_int_or (payload, "ss", ThingsUtil.STATUS_OPEN) != ThingsUtil.STATUS_OPEN;
            if (!item.checked) {
                item.completed_at = "";
            }
        }

        if (payload.has_member ("sp") && !ThingsUtil.is_null_member (payload, "sp")) {
            item.completed_at = ThingsUtil.epoch_to_datetime_string (
                ThingsUtil.get_double_or (payload, "sp", 0)
            );
        }

        if (payload.has_member ("ix")) {
            item.child_order = (int) ThingsUtil.get_int_or (payload, "ix", 0);
        }

        if (payload.has_member ("cd") && !ThingsUtil.is_null_member (payload, "cd")) {
            item.added_at = ThingsUtil.epoch_to_datetime_string (
                ThingsUtil.get_double_or (payload, "cd", 0)
            );
        }

        string[] ts = ThingsUtil.parse_string_array (payload, "ts");
        if (ts.length > 0) {
            item.parent_id = ts[0];
        }
    }

    private void create_project (Objects.Source source, string uuid, Json.Object payload) {
        if (payload.has_member ("tr") && payload.get_boolean_member ("tr")) {
            return;
        }

        var project = new Objects.Project ();
        project.id = uuid;
        project.source_id = source.id;
        project.backend_type = SourceType.THINGS;
        project.sync_id = SYNC_ID_PROJECT;
        project.color = "blue";
        apply_project_fields (project, payload);

        if (project.parent_id != "") {
            Objects.Project ? parent = Services.Store.instance ().get_project (project.parent_id);
            if (parent != null) {
                parent.add_subproject_if_not_exists (project);
                return;
            }

            project.parent_id = "";
        }

        Services.Store.instance ().insert_project (project);
    }

    private void patch_project (Objects.Source source, Objects.Project project, Json.Object payload) {
        if (payload.has_member ("tr") && payload.get_boolean_member ("tr")) {
            Services.Store.instance ().delete_project.begin (project);
            return;
        }

        string old_parent_id = project.parent_id;
        apply_project_fields (project, payload);
        Services.Store.instance ().update_project (project);

        if (project.parent_id != old_parent_id) {
            Services.EventBus.get_default ().project_parent_changed (project, old_parent_id);
        }
    }

    private void apply_project_fields (Objects.Project project, Json.Object payload) {
        if (payload.has_member ("tt")) {
            project.name = payload.get_string_member ("tt");
        }

        if (payload.has_member ("nt")) {
            project.description = ThingsUtil.parse_note (payload.get_member ("nt"), project.description);
        }

        if (payload.has_member ("ix")) {
            project.child_order = (int) ThingsUtil.get_int_or (payload, "ix", 0);
        }

        if (payload.has_member ("ar")) {
            string[] ar = ThingsUtil.parse_string_array (payload, "ar");
            project.parent_id = ar.length > 0 ? ar[0] : "";
        }

        if (payload.has_member ("ss")) {
            project.is_archived = ThingsUtil.get_int_or (payload, "ss", ThingsUtil.STATUS_OPEN) != ThingsUtil.STATUS_OPEN;
        }
    }

    private void create_section (Objects.Source source, string uuid, Json.Object payload) {
        if (payload.has_member ("tr") && payload.get_boolean_member ("tr")) {
            return;
        }

        string[] pr = ThingsUtil.parse_string_array (payload, "pr");
        if (pr.length == 0) {
            return;
        }

        Objects.Project ? project = Services.Store.instance ().get_project (pr[0]);
        if (project == null) {
            return;
        }

        var section = new Objects.Section ();
        section.id = uuid;
        section.project_id = project.id;

        if (payload.has_member ("tt")) {
            section.name = payload.get_string_member ("tt");
        }

        if (payload.has_member ("ix")) {
            section.section_order = (int) ThingsUtil.get_int_or (payload, "ix", 0);
        }

        project.add_section_if_not_exists (section);
    }

    private void patch_section (Objects.Section section, Json.Object payload) {
        if (payload.has_member ("tr") && payload.get_boolean_member ("tr")) {
            Services.Store.instance ().delete_section (section);
            return;
        }

        if (payload.has_member ("tt")) {
            section.name = payload.get_string_member ("tt");
        }

        if (payload.has_member ("ix")) {
            section.section_order = (int) ThingsUtil.get_int_or (payload, "ix", 0);
        }

        Services.Store.instance ().update_section (section);
    }

    private void apply_area (Objects.Source source, string uuid, int operation, Json.Object payload) {
        if (operation == 2) {
            delete_any (uuid);
            return;
        }

        Objects.Project ? project = Services.Store.instance ().get_project (uuid);

        if (project == null) {
            project = new Objects.Project ();
            project.id = uuid;
            project.source_id = source.id;
            project.backend_type = SourceType.THINGS;
            project.sync_id = SYNC_ID_AREA;
            project.color = "teal";

            if (payload.has_member ("tt")) {
                project.name = payload.get_string_member ("tt");
            }

            if (payload.has_member ("ix")) {
                project.child_order = (int) ThingsUtil.get_int_or (payload, "ix", 0);
            }

            Services.Store.instance ().insert_project (project);
            return;
        }

        if (payload.has_member ("tt")) {
            project.name = payload.get_string_member ("tt");
        }

        if (payload.has_member ("ix")) {
            project.child_order = (int) ThingsUtil.get_int_or (payload, "ix", 0);
        }

        Services.Store.instance ().update_project (project);
    }

    private void apply_tag (Objects.Source source, string uuid, int operation, Json.Object payload) {
        if (operation == 2) {
            delete_any (uuid);
            return;
        }

        Objects.Label ? label = Services.Store.instance ().get_label (uuid);

        if (label == null) {
            label = new Objects.Label ();
            label.id = uuid;
            label.source_id = source.id;
            label.backend_type = SourceType.THINGS;
            label.color = "blue";

            if (payload.has_member ("tt")) {
                label.name = payload.get_string_member ("tt");
            }

            Services.Store.instance ().insert_label (label);
            return;
        }

        if (payload.has_member ("tt")) {
            label.name = payload.get_string_member ("tt");
        }

        Services.Store.instance ().update_label (label);
    }

    private void delete_any (string uuid) {
        Objects.Item ? item = Services.Store.instance ().get_item (uuid);
        if (item != null) {
            Services.Store.instance ().delete_item (item);
            return;
        }

        Objects.Section ? section = Services.Store.instance ().get_section (uuid);
        if (section != null) {
            Services.Store.instance ().delete_section (section);
            return;
        }

        Objects.Project ? project = Services.Store.instance ().get_project (uuid);
        if (project != null) {
            Services.Store.instance ().delete_project.begin (project);
            return;
        }

        Objects.Label ? label = Services.Store.instance ().get_label (uuid);
        if (label != null) {
            Services.Store.instance ().delete_label (label);
        }
    }

    private string inbox_project_id (Objects.Source source) {
        return source.id + "-inbox";
    }

    /*
     * Recurrence templates, kept on the source as id -> rule so they survive
     * restarts (see Objects.SourceThingsData.recurrence_templates).
     */

    private Json.Object templates (Objects.Source source) {
        string data = source.things_data.recurrence_templates;
        if (data == null || !data.has_prefix ("{")) {
            return new Json.Object ();
        }

        var parser = new Json.Parser ();
        try {
            parser.load_from_data (data, -1);
        } catch (Error e) {
            return new Json.Object ();
        }

        unowned Json.Node ? root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            return new Json.Object ();
        }

        return root.get_object ();
    }

    private void store_templates (Objects.Source source, Json.Object object) {
        var generator = new Json.Generator ();
        var node = new Json.Node (Json.NodeType.OBJECT);
        node.set_object (object);
        generator.set_root (node);

        source.things_data.recurrence_templates = generator.to_data (null);
        source.save ();
    }

    private bool is_known_template (Objects.Source source, string uuid) {
        return templates (source).has_member (uuid);
    }

    private void remember_template (Objects.Source source, string uuid, Json.Object rule) {
        var object = templates (source);
        var node = new Json.Node (Json.NodeType.OBJECT);
        node.set_object (rule);
        object.set_member (uuid, node);
        store_templates (source, object);
    }

    private void forget_template (Objects.Source source, string uuid) {
        var object = templates (source);
        if (!object.has_member (uuid)) {
            return;
        }

        object.remove_member (uuid);
        store_templates (source, object);
    }

    /*
     * Instances carry no rule of their own, so the badge Planify shows comes
     * from the template listed in "rt".
     */
    private void apply_instance_recurrence (Objects.Source source, Objects.Item item, string[] rt) {
        if (rt.length == 0) {
            return;
        }

        var object = templates (source);
        if (!object.has_member (rt[0])) {
            return;
        }

        unowned Json.Node node = object.get_member (rt[0]);
        if (node.get_node_type () == Json.NodeType.OBJECT) {
            ThingsUtil.apply_recurrence (item.due, node.get_object ());
        }
    }

    /*
     * Helpers
     */

    public void insert_item (Objects.Source source, Objects.Item item) {
        if (item.parent_id != "") {
            Objects.Item ? parent = Services.Store.instance ().get_item (item.parent_id);
            if (parent != null) {
                parent.add_item_if_not_exists (item);
                return;
            }

            item.parent_id = "";
        }

        if (item.section_id != "") {
            Objects.Section ? section = Services.Store.instance ().get_section (item.section_id);
            if (section != null) {
                section.add_item_if_not_exists (item);
                return;
            }

            item.section_id = "";
        }

        Objects.Project ? project = Services.Store.instance ().get_project (item.project_id);
        if (project == null) {
            item.project_id = inbox_project_id (source);
            project = Services.Store.instance ().get_project (item.project_id);
        }

        if (project != null) {
            project.add_item_if_not_exists (item);
        }
    }

    public string get_things_error (uint code) {
        switch (code) {
            case 400: return _("The request was incorrect.");
            case 401: return _("Authentication failed. Check your Things Cloud email and password.");
            case 403: return _("The request was valid, but for something that is forbidden.");
            case 404: return _("The requested resource could not be found.");
            case 409: return _("The change conflicted with another device. Try again.");
            case 429: return _("Too many requests in a given amount of time.");
            case 500: return _("The request failed due to a server error.");
            case 503: return _("The server is currently unable to handle the request.");
            default: return _("Unknown error");
        }
    }
}
