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

public class Dialogs.Preferences.Pages.ThingsSetup : Dialogs.Preferences.Pages.BasePage {
    public Accounts accounts_page { get; construct; }

    private Adw.EntryRow email_entry;
    private Adw.PasswordEntryRow password_entry;
    private Widgets.LoadingButton login_button;
    private Gtk.Stack main_stack;

    public ThingsSetup (Adw.PreferencesDialog preferences_dialog, Accounts accounts_page) {
        Object (
            preferences_dialog: preferences_dialog,
            accounts_page: accounts_page,
            title: _("Things")
        );
    }

    ~ThingsSetup () {
        debug ("Destroying Dialogs.Preferences.Pages.ThingsSetup\n");
    }

    construct {
        var icon = new Gtk.Image.from_icon_name ("check-round-outline-symbolic") {
            pixel_size = 48,
            css_classes = { "dimmed" }
        };

        var title_label = new Gtk.Label (_("Connect to Things Cloud")) {
            css_classes = { "font-bold", "title-3" },
            margin_top = 12
        };

        var description_label = new Gtk.Label (
            _("Sign in with your Things Cloud account to sync your areas, projects and tasks")
        ) {
            css_classes = { "dimmed", "caption" },
            wrap = true,
            justify = CENTER,
            max_width_chars = 40
        };

        var header_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            halign = CENTER,
            margin_bottom = 18
        };
        header_box.append (icon);
        header_box.append (title_label);
        header_box.append (description_label);

        email_entry = new Adw.EntryRow ();
        email_entry.title = _("Email");
        email_entry.input_purpose = Gtk.InputPurpose.EMAIL;

        password_entry = new Adw.PasswordEntryRow ();
        password_entry.title = _("Password");
        password_entry.input_purpose = Gtk.InputPurpose.PASSWORD;
        password_entry.enable_emoji_completion = false;

        var entries_group = new Adw.PreferencesGroup ();
        entries_group.add (email_entry);
        entries_group.add (password_entry);

        var note_label = new Gtk.Label (
            _("Two-factor authentication and Sign in with Apple are not supported. Cultured Code has no official API, so this is an unofficial integration and may break at any time.")
        ) {
            css_classes = { "dimmed", "caption" },
            wrap = true,
            justify = CENTER,
            max_width_chars = 44,
            margin_top = 12
        };

        login_button = new Widgets.LoadingButton.with_label (_("Log In")) {
            margin_top = 24,
            sensitive = false,
            css_classes = { "suggested-action", "pill" },
            halign = CENTER
        };

        var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            vexpand = true,
            hexpand = true,
            margin_start = 12,
            margin_end = 12,
            margin_top = 24,
            margin_bottom = 24
        };
        content_box.append (header_box);
        content_box.append (entries_group);
        content_box.append (note_label);
        content_box.append (login_button);

        var loading_page = new Dialogs.Preferences.Pages.Accounts.LoadingPage () {
            show_progress = true
        };

        var scrolled_window = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = content_box
        };

        main_stack = new Gtk.Stack () {
            vexpand = true,
            hexpand = true,
            transition_type = Gtk.StackTransitionType.CROSSFADE
        };
        main_stack.add_named (scrolled_window, "main-page");
        main_stack.add_named (loading_page, "loading-page");

        var toolbar_view = new Adw.ToolbarView ();
        toolbar_view.add_top_bar (new Adw.HeaderBar ());
        toolbar_view.content = main_stack;

        child = toolbar_view;

        signal_map[email_entry.changed.connect (validate_entries)] = email_entry;
        signal_map[password_entry.changed.connect (validate_entries)] = password_entry;

        signal_map[password_entry.entry_activated.connect (() => {
            if (login_button.sensitive) {
                on_login_button_clicked ();
            }
        })] = password_entry;

        signal_map[login_button.clicked.connect (on_login_button_clicked)] = login_button;

        signal_map[Services.Things.get_default ().sync_progress.connect ((current, total, message) => {
            loading_page.sync_label = message;
            loading_page.progress = total > 0 ? (double) current / (double) total : 0.0;
        })] = Services.Things.get_default ();

        destroy.connect (clean_up);
    }

    private void validate_entries () {
        bool valid = email_entry.text != null && email_entry.text.contains ("@") &&
                     password_entry.text != null && password_entry.text != "";
        login_button.sensitive = valid;
    }

    private void on_login_button_clicked () {
        login_button.is_loading = true;
        do_login.begin ();
    }

    private async void do_login () {
        HttpResponse response = yield Services.Things.get_default ().login (
            email_entry.text.strip (), password_entry.text
        );

        if (!response.status) {
            login_button.is_loading = false;
            accounts_page.show_message_error (response.error_code, response.error.strip ());
            return;
        }

        Objects.Source source = (Objects.Source) response.data_object.get_object ();
        main_stack.visible_child_name = "loading-page";

        response = yield Services.Things.get_default ().add_things_account (source);

        if (response.status) {
            preferences_dialog.pop_subpage ();
        } else {
            main_stack.visible_child_name = "main-page";
            login_button.is_loading = false;

            if (response.error_code == 409) {
                var toast = new Adw.Toast (response.error.strip ());
                toast.timeout = 3;
                preferences_dialog.add_toast (toast);
            } else {
                accounts_page.show_message_error (response.error_code, response.error.strip ());
            }
        }
    }
}
