/*
 * Unit tests for the Things Cloud protocol helpers (Services.ThingsUtil).
 * These cover the parts most likely to corrupt a real history if wrong:
 * Base58 id shape, note CRC32, and the date encodings.
 */

private void test_uuid_shape () {
    for (int i = 0; i < 200; i++) {
        string id = Services.ThingsUtil.generate_uuid ();
        assert (id.length == 22);
        assert (Services.ThingsUtil.is_things_uuid (id));
    }

    // Legacy hyphenated UUIDs and other shapes must be rejected.
    assert (!Services.ThingsUtil.is_things_uuid ("not-a-things-id"));
    assert (!Services.ThingsUtil.is_things_uuid ("0OIl00000000000000000O")); // 22 chars, illegal alphabet
    assert (!Services.ThingsUtil.is_things_uuid (""));

    // Regression: the exact legacy (Task4) UUIDs that crashed Things when the
    // backend wrote a Base58-decoded Task6 for them MUST read as non-Base58,
    // so the write guards refuse to emit a modern entity kind for them.
    assert (!Services.ThingsUtil.is_things_uuid ("71CC74DF-3703-4269-AA1A-D5CB341AAE71"));
    assert (!Services.ThingsUtil.is_things_uuid ("81A8379D-A243-4744-98BF-FA22DDB87723"));
}

private void test_crc32 () {
    // Known zlib CRC32 vectors.
    assert (Services.ThingsUtil.crc32 ("") == 0);
    assert (Services.ThingsUtil.crc32 ("123456789") == 0xCBF43926);
    assert (Services.ThingsUtil.crc32 ("The quick brown fox jumps over the lazy dog") == 0x414FA339);
}

private void test_day_epoch () {
    // 2026-02-10 00:00:00 UTC == 1770681600.
    int64 epoch = Services.ThingsUtil.date_string_to_day_epoch ("2026-02-10");
    assert (epoch == 1770681600);

    // ISO 8601 with a time component still resolves to that day's midnight.
    int64 iso = Services.ThingsUtil.date_string_to_day_epoch ("2026-02-10T15:30:00");
    assert (iso == 1770681600);

    assert (Services.ThingsUtil.day_epoch_to_date_string (1770681600) == "2026-02-10");

    // Empty / malformed input yields the -1 sentinel.
    assert (Services.ThingsUtil.date_string_to_day_epoch ("") == -1);
    assert (Services.ThingsUtil.date_string_to_day_epoch ("nope") == -1);
}

private void test_note_roundtrip () {
    var builder = new Json.Builder ();
    builder.begin_object ();
    Services.ThingsUtil.add_note (builder, "hello world");
    builder.end_object ();

    var generator = new Json.Generator ();
    generator.set_root (builder.get_root ());
    string json = generator.to_data (null);

    var parser = new Json.Parser ();
    try {
        parser.load_from_data (json);
    } catch (Error e) {
        assert_not_reached ();
    }

    var root = parser.get_root ().get_object ();
    string parsed = Services.ThingsUtil.parse_note (root.get_member ("nt"), "");
    assert (parsed == "hello world");

    // A full-text (t=1) object replaces prior content; a null note is empty.
    var null_node = new Json.Node (Json.NodeType.NULL);
    assert (Services.ThingsUtil.parse_note (null_node, "keep") == "");
}

private string frag (int t, string kind, string payload_json) {
    var p = Utils.JsonUtils.get_object ("{\"p\":" + payload_json + "}").get_object_member ("p");
    return Services.ThingsQueue.build_fragment (t, kind, p);
}

private void test_queue_merge () {
    string merged;

    // Two updates to the same entity: fields union, newer wins on conflicts.
    bool ok = Services.ThingsQueue.merge_fragments (
        frag (1, "Task6", "{\"tt\":\"a\",\"ix\":1}"),
        frag (1, "Task6", "{\"ss\":3,\"ix\":2}"),
        out merged);
    assert (ok);
    assert (Utils.JsonUtils.get_int (merged, "t") == 1);
    var mp = Utils.JsonUtils.get_object_member (merged, "p");
    assert (mp.get_string_member ("tt") == "a");   // preserved from older
    assert (mp.get_int_member ("ss") == 3);        // added by newer
    assert (mp.get_int_member ("ix") == 2);        // newer wins

    // Create followed by update stays a create (t=0) with merged payload —
    // so a new item edited before it ever syncs is still one create.
    ok = Services.ThingsQueue.merge_fragments (
        frag (0, "Task6", "{\"tt\":\"new\"}"),
        frag (1, "Task6", "{\"ss\":3}"),
        out merged);
    assert (ok);
    assert (Utils.JsonUtils.get_int (merged, "t") == 0);

    // Create then delete cancels out entirely (server never heard of it).
    ok = Services.ThingsQueue.merge_fragments (
        frag (0, "Task6", "{\"tt\":\"x\"}"),
        frag (2, "Task6", "{}"),
        out merged);
    assert (!ok);

    // Update then delete becomes a delete.
    ok = Services.ThingsQueue.merge_fragments (
        frag (1, "Task6", "{\"tt\":\"x\"}"),
        frag (2, "Task6", "{}"),
        out merged);
    assert (ok);
    assert (Utils.JsonUtils.get_int (merged, "t") == 2);
}

public static int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/things/uuid-shape", test_uuid_shape);
    Test.add_func ("/things/crc32", test_crc32);
    Test.add_func ("/things/day-epoch", test_day_epoch);
    Test.add_func ("/things/note-roundtrip", test_note_roundtrip);
    Test.add_func ("/things/queue-merge", test_queue_merge);

    return Test.run ();
}
