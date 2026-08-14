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
 * Helpers for the reverse-engineered Things Cloud sync protocol.
 *
 * Things Cloud identifies every entity with a 22-character Base58 string
 * (Bitcoin alphabet, 16 underlying bytes) and encodes dates either as
 * fractional Unix epochs (creation/modification/completion) or as integer
 * epochs pinned to UTC day midnight (scheduled/deadline day markers).
 */
public class Services.ThingsUtil : GLib.Object {
    private const string B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    /*
     * Task6 "st" (start) values. Combined with the scheduled date these
     * decide which list a task shows up in (Inbox/Today/Anytime/...).
     */
    public const int START_INBOX = 0;
    public const int START_ANYTIME = 1;
    public const int START_SOMEDAY = 2;

    /*
     * Task6 "tp" (type) values.
     */
    public const int TYPE_TASK = 0;
    public const int TYPE_PROJECT = 1;
    public const int TYPE_HEADING = 2;

    /*
     * Task6 "ss" (status) values.
     */
    public const int STATUS_OPEN = 0;
    public const int STATUS_CANCELED = 2;
    public const int STATUS_COMPLETED = 3;

    /*
     * Task6 "sb" (start bucket): which half of the day the task sits in.
     */
    public const int BUCKET_DAY = 0;
    public const int BUCKET_EVENING = 1;

    /*
     * Recurrence rule "fu" (frequency unit) values. Things reuses Apple's
     * NSCalendarUnit bit flags rather than an enum of its own.
     */
    public const int FREQ_YEAR = 4;
    public const int FREQ_MONTH = 8;
    public const int FREQ_DAY = 16;
    public const int FREQ_WEEKDAY = 256;

    // "ed" on a rule that never ends: 4001-01-01, not a real user date.
    public const int64 RECURRENCE_NEVER_ENDS = 64092211200;

    /*
     * Reminder times ("ato") are seconds after local midnight on the task's
     * scheduled day. Planify models a reminder as an absolute datetime, so the
     * two only combine once the scheduled date is known.
     */
    public static string reminder_datetime_string (string date, int64 seconds_after_midnight) {
        if (date.length < 10) {
            return "";
        }

        string[] parts = date.substring (0, 10).split ("-");
        if (parts.length != 3) {
            return "";
        }

        var midnight = new GLib.DateTime.local (
            int.parse (parts[0]), int.parse (parts[1]), int.parse (parts[2]), 0, 0, 0
        );
        if (midnight == null) {
            return "";
        }

        return midnight.add_seconds ((double) seconds_after_midnight).format_iso8601 ();
    }

    public static int64 seconds_after_midnight (GLib.DateTime datetime) {
        return datetime.get_hour () * 3600 + datetime.get_minute () * 60 + datetime.get_second ();
    }

    /*
     * Things weekdays follow Apple's 1=Sunday…7=Saturday; Planify's
     * recurrency_weeks is a comma-separated 1=Monday…7=Sunday list.
     */
    private static int weekday_to_planify (int things_weekday) {
        return ((things_weekday + 5) % 7) + 1;
    }

    private static int weekday_from_planify (int planify_weekday) {
        return (planify_weekday % 7) + 1;
    }

    /*
     * Folds a Things "rr" recurrence rule into a Planify DueDate. Things
     * expresses the schedule as an NSCalendarUnit frequency plus a list of
     * offsets ("of"): weekday entries for weekly rules, day-of-month entries
     * for monthly ones. Returns false when the rule uses a shape Planify has
     * no way to express, so the caller can leave the task non-recurring
     * rather than silently describing the wrong schedule.
     */
    public static bool apply_recurrence (Objects.DueDate due, Json.Object rule) {
        int unit = (int) get_int_or (rule, "fu", 0);
        int amount = (int) get_int_or (rule, "fa", 1);

        switch (unit) {
            case FREQ_DAY:
                due.recurrency_type = RecurrencyType.EVERY_DAY;
                break;
            case FREQ_WEEKDAY:
                due.recurrency_type = RecurrencyType.EVERY_WEEK;
                break;
            case FREQ_MONTH:
                due.recurrency_type = RecurrencyType.EVERY_MONTH;
                break;
            case FREQ_YEAR:
                due.recurrency_type = RecurrencyType.EVERY_YEAR;
                break;
            default:
                return false;
        }

        due.is_recurring = true;
        due.recurrency_interval = amount > 0 ? amount : 1;
        due.recurrency_weeks = "";
        due.recurrency_count = 0;
        due.recurrency_end = "";

        if (unit == FREQ_WEEKDAY && rule.has_member ("of")) {
            var weeks = new StringBuilder ();
            foreach (unowned Json.Node offset_node in rule.get_array_member ("of").get_elements ()) {
                if (offset_node.get_node_type () != Json.NodeType.OBJECT) {
                    continue;
                }

                var offset = offset_node.get_object ();
                if (!offset.has_member ("wd")) {
                    continue;
                }

                if (weeks.len > 0) {
                    weeks.append (",");
                }
                weeks.append (weekday_to_planify ((int) get_int_or (offset, "wd", 1)).to_string ());
            }
            due.recurrency_weeks = weeks.str;
        }

        int64 count = get_int_or (rule, "rc", 0);
        if (count > 0) {
            due.recurrency_count = (int) count;
        }

        int64 end = get_int_or (rule, "ed", RECURRENCE_NEVER_ENDS);
        if (end > 0 && end < RECURRENCE_NEVER_ENDS) {
            due.recurrency_end = day_epoch_to_date_string (end);
        }

        return true;
    }

    /*
     * Builds the "rr" rule for a Planify DueDate. Mirrors apply_recurrence;
     * "tp" 0 means the next instance is scheduled from the due date (Planify's
     * only model), and "rrv" 4 is the rule version Things 3 writes.
     */
    public static void add_recurrence (Json.Builder builder, Objects.DueDate due, int64 series_start) {
        builder.set_member_name ("rr");

        if (!due.is_recurring || due.recurrency_type == RecurrencyType.NONE) {
            builder.add_null_value ();
            return;
        }

        int unit;
        switch (due.recurrency_type) {
            case RecurrencyType.EVERY_DAY:
                unit = FREQ_DAY;
                break;
            case RecurrencyType.EVERY_WEEK:
                unit = FREQ_WEEKDAY;
                break;
            case RecurrencyType.EVERY_MONTH:
                unit = FREQ_MONTH;
                break;
            case RecurrencyType.EVERY_YEAR:
                unit = FREQ_YEAR;
                break;
            default:
                builder.add_null_value ();
                return;
        }

        builder.begin_object ();

        builder.set_member_name ("fu");
        builder.add_int_value (unit);
        builder.set_member_name ("fa");
        builder.add_int_value (due.recurrency_interval > 0 ? due.recurrency_interval : 1);

        builder.set_member_name ("of");
        builder.begin_array ();
        if (unit == FREQ_WEEKDAY && due.recurrency_weeks != "") {
            foreach (string week in due.recurrency_weeks.split (",")) {
                if (week.strip () == "") {
                    continue;
                }
                builder.begin_object ();
                builder.set_member_name ("wd");
                builder.add_int_value (weekday_from_planify (int.parse (week.strip ())));
                builder.end_object ();
            }
        }
        builder.end_array ();

        builder.set_member_name ("rc");
        builder.add_int_value (due.recurrency_count);

        builder.set_member_name ("ed");
        int64 end = date_string_to_day_epoch (due.recurrency_end);
        builder.add_int_value (end >= 0 ? end : RECURRENCE_NEVER_ENDS);

        builder.set_member_name ("sr");
        builder.add_int_value (series_start);
        builder.set_member_name ("ia");
        builder.add_int_value (series_start);

        builder.set_member_name ("tp");
        builder.add_int_value (0);
        builder.set_member_name ("ts");
        builder.add_int_value (0);
        builder.set_member_name ("rrv");
        builder.add_int_value (4);

        builder.end_object ();
    }

    /*
     * Generates a Things-style 22-character Base58 id from 16 random bytes.
     * The top bit is forced so the value always encodes to exactly 22
     * characters; Things.app crashes on ids it cannot Base58-decode.
     */
    public static string generate_uuid () {
        uint8[] bytes = new uint8[16];
        for (int i = 0; i < 16; i++) {
            bytes[i] = (uint8) GLib.Random.int_range (0, 256);
        }
        bytes[0] |= 0x80;

        var digits = new Gee.ArrayList<int> ();
        digits.add (0);

        for (int i = 0; i < 16; i++) {
            int carry = bytes[i];
            for (int j = 0; j < digits.size; j++) {
                int val = digits[j] * 256 + carry;
                digits[j] = val % 58;
                carry = val / 58;
            }

            while (carry > 0) {
                digits.add (carry % 58);
                carry = carry / 58;
            }
        }

        var builder = new StringBuilder ();
        for (int i = digits.size - 1; i >= 0; i--) {
            builder.append_c (B58_ALPHABET[digits[i]]);
        }

        return builder.str;
    }

    public static bool is_things_uuid (string id) {
        if (id.length != 22) {
            return false;
        }

        for (int i = 0; i < id.length; i++) {
            if (B58_ALPHABET.index_of_char (id[i]) < 0) {
                return false;
            }
        }

        return true;
    }

    /*
     * CRC32 (zlib polynomial) used as the checksum of note bodies.
     */
    public static uint32 crc32 (string data) {
        uint32 crc = (uint32) 0xFFFFFFFF;

        foreach (uint8 b in data.data) {
            crc ^= b;
            for (int i = 0; i < 8; i++) {
                uint32 mask = (crc & 1) == 1 ? (uint32) 0xFFFFFFFF : 0;
                crc = (crc >> 1) ^ ((uint32) 0xEDB88320 & mask);
            }
        }

        return ~crc;
    }

    /*
     * Fractional Unix epoch for cd/md/sp fields.
     */
    public static double now_epoch () {
        return (double) GLib.get_real_time () / 1000000.0;
    }

    public static double datetime_to_epoch (GLib.DateTime datetime) {
        return (double) datetime.to_unix ();
    }

    /*
     * Converts a Planify date string (ISO 8601 or plain YYYY-MM-DD) into a
     * Things day marker: the Unix epoch of that date at UTC midnight.
     * Returns -1 when the string holds no usable date.
     */
    public static int64 date_string_to_day_epoch (string date) {
        if (date == null || date.length < 10) {
            return -1;
        }

        string[] parts = date.substring (0, 10).split ("-");
        if (parts.length != 3) {
            return -1;
        }

        int year = int.parse (parts[0]);
        int month = int.parse (parts[1]);
        int day = int.parse (parts[2]);
        if (year <= 0 || month <= 0 || day <= 0) {
            return -1;
        }

        var datetime = new GLib.DateTime.utc (year, month, day, 0, 0, 0);
        return datetime.to_unix ();
    }

    public static string day_epoch_to_date_string (int64 epoch) {
        var datetime = new GLib.DateTime.from_unix_utc (epoch);
        return datetime.format ("%Y-%m-%d");
    }

    public static string epoch_to_datetime_string (double epoch) {
        var datetime = new GLib.DateTime.from_unix_local ((int64) epoch);
        return datetime.to_string ();
    }

    public static int64 today_day_epoch () {
        var now = new GLib.DateTime.now_local ();
        var today = new GLib.DateTime.utc (now.get_year (), now.get_month (), now.get_day_of_month (), 0, 0, 0);
        return today.to_unix ();
    }

    /*
     * Entity envelope: { "<uuid>": { "t": <op>, "e": "<kind>", "p": { ... } } }
     */
    public static void begin_entity (Json.Builder builder, string uuid, int operation, string kind) {
        builder.set_member_name (uuid);
        builder.begin_object ();
        builder.set_member_name ("t");
        builder.add_int_value (operation);
        builder.set_member_name ("e");
        builder.add_string_value (kind);
        builder.set_member_name ("p");
        builder.begin_object ();
    }

    public static void end_entity (Json.Builder builder) {
        builder.end_object ();
        builder.end_object ();
    }

    public static void add_string_array (Json.Builder builder, string member, string[] values) {
        builder.set_member_name (member);
        builder.begin_array ();
        foreach (string value in values) {
            builder.add_string_value (value);
        }
        builder.end_array ();
    }

    /*
     * Modern structured note value: { "_t": "tx", "t": 1, "ch": crc32, "v": text, "ps": [] }
     */
    public static void add_note (Json.Builder builder, string text) {
        builder.set_member_name ("nt");
        builder.begin_object ();
        builder.set_member_name ("_t");
        builder.add_string_value ("tx");
        builder.set_member_name ("t");
        builder.add_int_value (1);
        builder.set_member_name ("ch");
        builder.add_int_value ((int64) crc32 (text));
        builder.set_member_name ("v");
        builder.add_string_value (text);
        builder.set_member_name ("ps");
        builder.begin_array ();
        builder.end_array ();
        builder.end_object ();
    }

    /*
     * Reads a note field coming from the history stream. Notes are either a
     * legacy plain string (possibly wrapped in <note> XML), a full-text
     * object (t=1) or a delta object (t=2) whose patches are spliced into
     * the current local text.
     */
    public static string parse_note (Json.Node node, string current) {
        if (node.get_node_type () == Json.NodeType.NULL) {
            return "";
        }

        if (node.get_node_type () == Json.NodeType.VALUE) {
            return clean_legacy_note (node.get_string ());
        }

        if (node.get_node_type () != Json.NodeType.OBJECT) {
            return current;
        }

        var object = node.get_object ();
        int64 note_type = object.has_member ("t") ? object.get_int_member ("t") : 1;

        if (note_type == 1) {
            return object.has_member ("v") ? object.get_string_member ("v") : "";
        }

        if (note_type == 2 && object.has_member ("ps")) {
            string result = current;
            foreach (unowned Json.Node patch_node in object.get_array_member ("ps").get_elements ()) {
                var patch = patch_node.get_object ();
                int position = patch.has_member ("p") ? (int) patch.get_int_member ("p") : 0;
                int length = patch.has_member ("l") ? (int) patch.get_int_member ("l") : 0;
                string replacement = patch.has_member ("r") ? patch.get_string_member ("r") : "";

                int start = int.min (position, result.length);
                int end = int.min (position + length, result.length);
                result = result.substring (0, start) + replacement + result.substring (end);
            }
            return result;
        }

        return current;
    }

    private static string clean_legacy_note (string? note) {
        if (note == null) {
            return "";
        }

        string result = note;
        if (result.has_prefix ("<note")) {
            int start = result.index_of (">");
            int end = result.last_index_of ("</note>");
            if (start >= 0 && end > start) {
                result = result.substring (start + 1, end - start - 1);
            }
        }

        return result.replace ("\xe2\x80\xa8", "\n").replace ("\xe2\x80\xa9", "\n\n");
    }

    public static string[] parse_string_array (Json.Object object, string member) {
        string[] return_value = {};

        if (!object.has_member (member)) {
            return return_value;
        }

        unowned Json.Node node = object.get_member (member);
        if (node.get_node_type () == Json.NodeType.VALUE) {
            return_value += node.get_string ();
            return return_value;
        }

        if (node.get_node_type () != Json.NodeType.ARRAY) {
            return return_value;
        }

        foreach (unowned Json.Node element in node.get_array ().get_elements ()) {
            if (element.get_node_type () == Json.NodeType.VALUE) {
                return_value += element.get_string ();
            }
        }

        return return_value;
    }

    public static int64 get_int_or (Json.Object object, string member, int64 fallback) {
        if (!object.has_member (member)) {
            return fallback;
        }

        unowned Json.Node node = object.get_member (member);
        if (node.get_node_type () != Json.NodeType.VALUE) {
            return fallback;
        }

        // History payloads mix integer and fractional epochs.
        if (node.get_value_type () == typeof (int64)) {
            return node.get_int ();
        }

        if (node.get_value_type () == typeof (double)) {
            return (int64) node.get_double ();
        }

        return fallback;
    }

    public static double get_double_or (Json.Object object, string member, double fallback) {
        if (!object.has_member (member)) {
            return fallback;
        }

        unowned Json.Node node = object.get_member (member);
        if (node.get_node_type () != Json.NodeType.VALUE) {
            return fallback;
        }

        if (node.get_value_type () == typeof (double)) {
            return node.get_double ();
        }

        if (node.get_value_type () == typeof (int64)) {
            return (double) node.get_int ();
        }

        return fallback;
    }

    public static bool is_null_member (Json.Object object, string member) {
        return object.has_member (member) &&
               object.get_member (member).get_node_type () == Json.NodeType.NULL;
    }
}
