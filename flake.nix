{
  description = "Planify development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        nativeBuildInputs = with pkgs; [
          meson
          ninja
          pkg-config
          vala
          git
          gettext
          desktop-file-utils
          appstream
          wrapGAppsHook4
          blueprint-compiler
          gobject-introspection
        ];

        buildInputs = with pkgs; [
          glib
          gtk4
          libgee
          libsoup_3
          sqlite
          libadwaita
          json-glib
          libical
          gxml
          libsecret
          libspelling
          gtksourceview5
          icu
          libportal
          libportal-gtk4
          evolution-data-server
          glib-networking

          # GTK4's Gtk.MediaFile (task-completion sound) plays through
          # GStreamer; without these plugins playbin3 is missing and the app
          # aborts on the first sound. gst-plugins-base provides playbin3 and
          # ogg/vorbis decoding for the bundled success.ogg.
          gst_all_1.gstreamer
          gst_all_1.gst-plugins-base
          gst_all_1.gst-plugins-good
        ];

        gstPluginPath = pkgs.lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" (with pkgs.gst_all_1; [
          gstreamer
          gst-plugins-base
          gst-plugins-good
        ]);
      in
      {
        devShells.default = pkgs.mkShell {
          inherit nativeBuildInputs buildInputs;

          shellHook = ''
            export XDG_DATA_DIRS=$GSETTINGS_SCHEMAS_PATH:$XDG_DATA_DIRS
            # glib-networking provides the GIO TLS backend; without it on the
            # module path every HTTPS request fails with "TLS support is not
            # available" (breaks Things/Todoist/CalDAV sync).
            export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"
            export GST_PLUGIN_SYSTEM_PATH_1_0="${gstPluginPath}''${GST_PLUGIN_SYSTEM_PATH_1_0:+:$GST_PLUGIN_SYSTEM_PATH_1_0}"
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "planify";
          version = "4.19.4";
          src = self;

          inherit nativeBuildInputs buildInputs;

          mesonFlags = [
            "-Dprofile=development"
            "-Dportal=true"
            "-Devolution=true"
          ];

          # wrapGAppsHook4 injects these into the launched binary so TLS
          # (glib-networking) and the task-completion sound (GStreamer) work
          # at runtime without the caller setting any env vars.
          preFixup = ''
            gappsWrapperArgs+=(
              --prefix GIO_EXTRA_MODULES : "${pkgs.glib-networking}/lib/gio/modules"
              --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${gstPluginPath}"
            )
          '';
        };

        # `nix run` builds the wrapped app and launches it with all runtime
        # env (schemas, GIO TLS backend, GStreamer plugins) already wired.
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/io.github.alainm23.planify.Devel";
        };
      });
}
