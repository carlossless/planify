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
