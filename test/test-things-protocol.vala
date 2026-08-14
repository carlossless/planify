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

    // Things does not force the top bit, so a 16-byte id whose value falls
    // below 58^21 encodes to 21 characters. These are real ids from a live
    // account and must be accepted — rejecting them made every task, tag and
    // project carrying one permanently unwritable.
    assert (Services.ThingsUtil.is_things_uuid ("a6VHEpBBN3b3YMH4bMut2"));
    assert (Services.ThingsUtil.is_things_uuid ("exg6mri1A4pu5LX8vgyB2"));
    assert (Services.ThingsUtil.is_things_uuid ("1ZWiCikadpvZZf9Uf1dfL"));

    // Legacy hyphenated UUIDs and other shapes must be rejected.
    assert (!Services.ThingsUtil.is_things_uuid ("not-a-things-id"));
    assert (!Services.ThingsUtil.is_things_uuid ("0OIl00000000000000000O")); // 22 chars, illegal alphabet
    assert (!Services.ThingsUtil.is_things_uuid (""));

    // 22 legal characters that decode past 16 bytes are not ids either.
    assert (!Services.ThingsUtil.is_things_uuid ("zzzzzzzzzzzzzzzzzzzzzz"));

    // Too short to be a 16-byte value, so not mistaken for one.
    assert (!Services.ThingsUtil.is_things_uuid ("abc"));

    // Regression: the exact legacy (Task4) UUIDs that crashed Things when the
    // backend wrote a Base58-decoded Task6 for them MUST read as non-Base58,
    // so the write guards refuse to emit a modern entity kind for them.
    assert (!Services.ThingsUtil.is_things_uuid ("71CC74DF-3703-4269-AA1A-D5CB341AAE71"));
    assert (!Services.ThingsUtil.is_things_uuid ("81A8379D-A243-4744-98BF-FA22DDB87723"));
}

private Json.Object parse_object (string json) {
    var parser = new Json.Parser ();
    try {
        parser.load_from_data (json, -1);
    } catch (Error e) {
        assert_not_reached ();
    }
    return parser.get_root ().get_object ();
}

/*
 * The rules below are real "rr" payloads taken from a live Things Cloud
 * history, so they pin the mapping to what the server actually sends rather
 * than to our reading of it.
 */
private void test_recurrence_parse () {
    // Every 2 weeks on Sunday (Things weekday 1 == Sunday).
    var weekly = new Objects.DueDate ();
    assert (Services.ThingsUtil.apply_recurrence (weekly, parse_object (
        """{"ia":1691366400,"of":[{"wd":1}],"tp":0,"ts":0,"fu":256,"rrv":4,
            "sr":1691366400,"rc":0,"fa":2,"ed":64092211200}"""
    )));
    assert (weekly.is_recurring);
    assert (weekly.recurrency_type == RecurrencyType.EVERY_WEEK);
    assert (weekly.recurrency_interval == 2);
    assert (weekly.recurrency_weeks == "7");
    // "ed" is Things' 4001-01-01 "never ends" sentinel, not a real end date.
    assert (weekly.recurrency_end == "");

    // Monthly on the first day. NSCalendarUnit month == 8.
    var monthly = new Objects.DueDate ();
    assert (Services.ThingsUtil.apply_recurrence (monthly, parse_object (
        """{"ia":1690848000,"of":[{"dy":0}],"tp":0,"ts":0,"rrv":4,"fu":8,
            "fa":1,"rc":0,"sr":1690848000,"ed":64092211200}"""
    )));
    assert (monthly.recurrency_type == RecurrencyType.EVERY_MONTH);
    assert (monthly.recurrency_interval == 1);
    assert (monthly.recurrency_weeks == "");

    // Weekly on Thursday: Things weekday 5 maps to Planify's 4.
    var thursday = new Objects.DueDate ();
    assert (Services.ThingsUtil.apply_recurrence (thursday, parse_object (
        """{"of":[{"wd":5}],"fu":256,"fa":1,"rc":0,"ed":64092211200}"""
    )));
    assert (thursday.recurrency_weeks == "4");

    // A real end date and a repeat count both come through.
    var bounded = new Objects.DueDate ();
    assert (Services.ThingsUtil.apply_recurrence (bounded, parse_object (
        """{"fu":16,"fa":3,"rc":5,"ed":1770681600}"""
    )));
    assert (bounded.recurrency_type == RecurrencyType.EVERY_DAY);
    assert (bounded.recurrency_interval == 3);
    assert (bounded.recurrency_count == 5);
    assert (bounded.recurrency_end == "2026-02-10");

    // An unknown frequency unit must not be guessed at.
    var unknown = new Objects.DueDate ();
    assert (!Services.ThingsUtil.apply_recurrence (unknown, parse_object ("""{"fu":2048,"fa":1}""")));
    assert (!unknown.is_recurring);
}

private void test_recurrence_roundtrip () {
    var due = new Objects.DueDate ();
    due.is_recurring = true;
    due.recurrency_type = RecurrencyType.EVERY_WEEK;
    due.recurrency_interval = 2;
    due.recurrency_weeks = "1,4";

    var builder = new Json.Builder ();
    builder.begin_object ();
    Services.ThingsUtil.add_recurrence (builder, due, 1691366400);
    builder.end_object ();

    var generator = new Json.Generator ();
    generator.set_root (builder.get_root ());

    var back = new Objects.DueDate ();
    assert (Services.ThingsUtil.apply_recurrence (
        back, parse_object (generator.to_data (null)).get_object_member ("rr")
    ));
    assert (back.recurrency_type == RecurrencyType.EVERY_WEEK);
    assert (back.recurrency_interval == 2);
    assert (back.recurrency_weeks == "1,4");

    // A non-recurring due date writes an explicit null, which is how Things
    // distinguishes "no repeat" from "field absent".
    var plain_builder = new Json.Builder ();
    plain_builder.begin_object ();
    Services.ThingsUtil.add_recurrence (plain_builder, new Objects.DueDate (), 0);
    plain_builder.end_object ();

    var plain_generator = new Json.Generator ();
    plain_generator.set_root (plain_builder.get_root ());
    assert (parse_object (plain_generator.to_data (null)).get_null_member ("rr"));
}

private void test_reminder_time () {
    // 43200 is the only reminder offset the sample account uses: 12:00 local.
    string at_noon = Services.ThingsUtil.reminder_datetime_string ("2026-02-10", 43200);
    var parsed = new GLib.DateTime.from_iso8601 (at_noon, new GLib.TimeZone.local ());
    assert (parsed != null);
    assert (parsed.get_year () == 2026 && parsed.get_month () == 2 && parsed.get_day_of_month () == 10);
    assert (parsed.get_hour () == 12 && parsed.get_minute () == 0);

    assert (Services.ThingsUtil.seconds_after_midnight (parsed) == 43200);
    assert (Services.ThingsUtil.reminder_datetime_string ("", 43200) == "");
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

    Test.add_func ("/things/recurrence-parse", test_recurrence_parse);
    Test.add_func ("/things/recurrence-roundtrip", test_recurrence_roundtrip);
    Test.add_func ("/things/reminder-time", test_reminder_time);
    Test.add_func ("/things/uuid-shape", test_uuid_shape);
    Test.add_func ("/things/crc32", test_crc32);
    Test.add_func ("/things/day-epoch", test_day_epoch);
    Test.add_func ("/things/note-roundtrip", test_note_roundtrip);
    Test.add_func ("/things/queue-merge", test_queue_merge);

    return Test.run ();
}
