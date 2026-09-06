{ config, lib, pkgs, osConfig, inputs, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "hakuspace"; };
  cfg = osConfig.my.hakuspace;
  enabled = cfg.enable && inScope;

  bin = name: "${config.home.homeDirectory}/.local/bin/${name}";

  /*
    One shape per component, because they all want the same lifecycle: tied to
    graphical-session.target, started after it, stopped with it.

    SYSTEMD RATHER THAN THE COMPOSITOR'S AUTOSTART, which is how upstream does
    it (src/wm/hyprland/config/autostart.lua runs eleven hl.exec_cmd calls on
    hyprland.start). That file is not installed here -- features/hyprland owns
    the Hyprland config -- and features/hyprland states the rule directly:
    nothing is spawned from the compositor, least of all a shell, because a
    config reload re-executes the whole Lua script and an exec-once copy
    becomes a second unmanaged instance. Units also restart on failure, which
    an exec_cmd cannot.
  */
  service = description: exec: {
    Unit = {
      Description = description;
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = exec;
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  oneshot = description: exec: {
    Unit = {
      Description = description;
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = exec;
    };
  };

  /*
    Order a drawing unit after the theme seed (hakuspace-theme-init below).
    recursiveUpdate REPLACES lists rather than merging them, so After is
    rebuilt by hand from the unit's own value. Wants, not Requires: if the
    seed fails the component should still try, fail visibly, and be
    restartable on its own.
  */
  themed = unit: lib.recursiveUpdate unit {
    Unit = {
      Wants = [ "hakuspace-theme-init.service" ];
      After = unit.Unit.After ++ [ "hakuspace-theme-init.service" ];
    };
  };

  # The same emoji-enabled rofi the compositor binds build in compositor.nix
  # (identical override, deduped by the store): home.packages puts it on the
  # profile, and networkmanager-dmenu's config names it absolutely.
  rofiEmoji = pkgs.rofi.override { plugins = [ pkgs.rofi-emoji ]; };
in
{
  imports = [
    inputs.feat-hakuspace.homeModule
    ./compositor.nix
  ];

  config = lib.mkIf enabled {
    programs.hakuspace = {
      enable = true;
      inherit (cfg) configNames;

      /*
        Built from HOST pkgs, overriding the flake module's default.

        The homeModule defaults `package` to self.packages.<system>.hakuspace,
        which is callPackage'd from the hakuspace flake's OWN nixpkgs input --
        after the follows chain, the tuned fork's plain legacyPackages. That is
        the wrong package set on every host, in opposite directions:

          - dell-latitude (tuning.enable = false) runs on upstream nixpkgs
            precisely so everything substitutes from cache.nixos.org. The
            fork's cc-wrapper patch moves stdenv's hash, so the default drags
            a SECOND, fork-built copy of the wrapper's whole dependency
            surface -- python + colorthief, waybar, rofi, imagemagick,
            hyprland, kitty -- through a from-scratch bootstrap that no cache
            has. Measured: 2482 of this host's 2982 cache.nixos.org misses
            were inside that one package's build closure.

          - tuned hosts get the fork, but PLAIN: legacyPackages carries none
            of my.tuning's overlays or the march platform split, so the shell
            the user stares at all day is the one thing built untuned.

        callPackage from `pkgs` gives each host its own answer -- upstream
        and fully substitutable here, fork-with-overlays there -- and the
        scripts wrap the SAME rofi/waybar/etc. the rest of the system runs,
        instead of a byte-different duplicate closure.

        The input's `follows = "nixpkgs"` stays: nothing consumes its
        packages output anymore, but the follows keeps the lock from pinning
        (and evaluation from fetching) the second nixpkgs the upstream flake
        declares for standalone use.
      */
      package =
        (pkgs.callPackage "${inputs.feat-hakuspace.inputs.hakuspace}/nix/package.nix" {
          /*
            The menus' file manager. Upstream's scripts hardcode `thunar`, and
            callPackage would happily satisfy that with the real Thunar -- a
            second file manager riding in to satisfy a string. This host's file
            manager is Dolphin (features/desktop-apps), so the name resolves to
            it instead.
          */
          thunar = pkgs.writeShellScriptBin "thunar" ''exec ${pkgs.kdePackages.dolphin}/bin/dolphin "$@"'';

          /*
            VIDEO WALLPAPER PERSISTENCE, by shimming the two launch paths.

            awww caches what it displays and `awww restore` (run by the
            wallpaper unit below) brings images back after a reboot -- but
            mpvpaper has no cache and upstream saves nothing, so a video
            wallpaper died with the session. The scripts stay byte-identical
            to upstream's; the state-keeping rides on the binaries they call:

              mpvpaper  records its argv (newline-separated -- paths with
                        spaces survive, newlines in filenames do not, which
                        is the least insane tradeoff) before exec'ing the
                        real one. pkill still works: exec keeps the real
                        process name.
              awww      an `awww img ...` means an image REPLACED the video
                        (wallpaper_set.sh pkills mpvpaper on that path), so
                        the record is cleared or a reboot would resurrect
                        the dead video on top of the restored image.
          */
          mpvpaper = pkgs.writeShellScriptBin "mpvpaper" ''
            mkdir -p "$HOME/.local/state/haku_theme"
            printf '%s\n' "$@" > "$HOME/.local/state/haku_theme/video_wallpaper"
            exec ${pkgs.mpvpaper}/bin/mpvpaper "$@"
          '';
          awww = pkgs.runCommand "awww-video-state-shim" { } ''
            mkdir -p $out/bin
            ln -s ${pkgs.awww}/bin/awww-daemon $out/bin/awww-daemon
            cat > $out/bin/awww <<EOF
            #!${pkgs.runtimeShell}
            if [ "\$1" = img ]; then
              rm -f "\$HOME/.local/state/haku_theme/video_wallpaper"
            fi
            exec ${pkgs.awww}/bin/awww "\$@"
            EOF
            chmod +x $out/bin/awww
          '';
        }).overrideAttrs
          (old: {
            /*
              GI_TYPELIB_PATH onto every wrapped script. dockbar_geticon.sh
              (and desktop_icons.py) resolve app icons through an inline
              pygobject Gtk lookup; the package's python env carries the gi
              BINDINGS, but typelibs are runtime search-path data that Arch
              gets from its system-wide GTK and Nix does not have a global
              location for. Without the path every lookup dies with
              "Namespace Gtk not available" -- rc 0, empty stdout -- and the
              dock renders blank tiles. Wrapping the wrapper is fine: the
              entries in $out/bin are already makeWrapper scripts.
            */
            postFixup =
              (old.postFixup or "")
              + ''
                for f in $out/bin/*; do
                  wrapProgram "$f" --prefix GI_TYPELIB_PATH : "${
                    lib.makeSearchPath "lib/girepository-1.0" (
                      with pkgs;
                      [
                        gtk3
                        gobject-introspection
                        pango.out
                        gdk-pixbuf
                        harfbuzz.out
                        atk
                      ]
                    )
                  }"
                done

                # exit.sh: log out to the greeter, not just kill the shell.
                # The script is spawned by the bar (hakuspace-bar.service), so
                # its `systemctl --user stop graphical-session.target` tore down
                # its OWN cgroup -- killing exit.sh before the compositor-quit
                # line after it. Result: shell dead, Hyprland alive, no way back
                # to the greeter. Drop that stop (quitting the compositor closes
                # every client and ends the greetd session -> greeter), and use
                # the canonical `hyprctl dispatch exit` over the eval form.
                substituteInPlace $out/share/hakuspace/scripts/exit.sh \
                  --replace-fail 'systemctl --user stop graphical-session.target 2>/dev/null' 'true  # nix: removed -- this stop killed exit.sh (in the bar cgroup) before the compositor exit' \
                  --replace-fail "hyprctl eval 'hl.dispatch(hl.dsp.exit())'" 'hyprctl dispatch exit'

                # Workspace numbers in the bar: the ext/workspaces module (what
                # group/hworkspaces uses on every layout) showed dot icons, so
                # there was no telling which workspace SUPER+<n> lands on. Show
                # the workspace NAME instead, which Hyprland sets to the number.
                # JSON-surgical so only ext/workspaces changes, not the niri /
                # hyprland / mango definitions that share "format": "{icon}".
                ${pkgs.python3}/bin/python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["ext/workspaces"]["format"]="{name}"; json.dump(c,open(p,"w"),ensure_ascii=False,indent=4)' \
                  $out/share/hakuspace/config/waybar/module/workspace_module
              '';
          });

      /*
        NULL, deliberately: this is what keeps the two halves separable.

        hakuspace ships a COMPLETE Hyprland config -- monitors, input, layout,
        animations, rules, autostart, keybinds. Installing it would put a
        second full config at ~/.config/hypr, which features/hyprland already
        owns, and undo the separation between compositor and shell. Only the
        shell half is taken; the keybinds it needs are contributed to whichever
        compositor is selected from ./compositor.nix.
      */
      compositor = null;

      /*
        playerctl for the music module: upstream assumes a system-wide
        install, and the wrapper in the package cannot know about it.

        brightnessctl for hypridle: its dim/restore listeners call it BARE,
        from the daemon's own environment rather than through any wrapped
        script, so it has to be on the user profile's PATH. extraScriptPath
        lands in home.packages (the flake module puts it there), which is
        exactly that -- and the scripts get it on their wrapped PATH too.

        file(1) for wallpaper_set.sh: it detects image vs video by
        `file -b --mime-type`, and without it EVERY wallpaper fails with
        "Unsupported file format ()" -- the daemon just shows black.
        Belongs in package.nix's runtimeDeps upstream; carried here until
        the PR.
      */
      extraScriptPath = [
        pkgs.playerctl
        pkgs.brightnessctl
        pkgs.file
      ];
    };

    /*
      The components upstream's autostart.lua launches, minus everything this
      configuration already owns.

      DROPPED, and each for a reason rather than as a trim:
        polkit_start.sh    features/session-services runs an agent already
        nm-applet          features/network owns NetworkManager and its tray
        blueman-applet     likewise for bluetooth
        fcitx5 -d          features/fcitx starts it as its own user service
        welcome.sh         a first-run greeting popup, not a session component
        desktop_icons      upstream marks it experimental and buggy
    */
    systemd.user.services = {
      /*
        Seed ~/.local/state/haku_theme before anything draws.

        Every visual component IMPORTS that directory -- waybar's style.css
        and swaync's both @import colors.css, every rofi layout imports
        rofi-style.rasi -- and the directory is generated, not shipped:
        install.sh runs gen_style.sh once at install time ("Gen style first
        time"), after which theme switches rewrite it. The declarative route
        never ran it, so on a fresh machine waybar exited on the missing
        import before drawing a single pixel. Guarded on colors.css because
        the theme state is the user's own (their accent, their fonts); a
        rebuild must never reset it.
      */
      hakuspace-theme-init = oneshot "Haku Space theme state (first-run seed)"
        "${pkgs.bash}/bin/bash -c '[ -e \"$HOME/.local/state/haku_theme/colors.css\" ] || exec ${bin "gen_style.sh"}'";

      /*
        STORE PATHS for the daemons, not bare names. A bare name resolves
        only if something ELSE happens to put the binary on the user
        manager's PATH -- the hakuspace package wraps these onto its
        SCRIPTS' PATH, which units never see. On a host where no other
        feature installs swaync/hypridle/awww (this one), all three units
        died at EXEC. Same idiom as the clipboard watchers below, which
        always did it right.
      */
      hakuspace-wallpaper = lib.recursiveUpdate (service "Haku Space wallpaper daemon" "${pkgs.awww}/bin/awww-daemon") {
        /*
          Restore the previous wallpaper after the daemon is up. The daemon
          caches what it displays (~/.cache/awww/<version>/<output>) but does
          NOT reload it on start -- that is the `awww restore` CLIENT
          command, and neither upstream's autostart.lua nor anything else
          ever ran it, so every reboot came up black. Verified live: cache
          held the wallpaper, query showed color:000000, restore brought it
          back.

          Retry loop because ExecStartPost fires as soon as the daemon
          process spawns, racing its socket creation; `exit 0` regardless,
          because a first boot has no cache to restore and that must not
          fail the unit.

          The video half reads the record the mpvpaper shim (see the package
          override above) keeps: if a video was the active wallpaper, replay
          the exact launch, backgrounded into this unit's cgroup -- so it
          dies with the session and is relaunched if the daemon unit
          restarts, the same lifecycle the image gets. The real mpvpaper,
          not the shim: replaying must not re-record.
        */
        Service.ExecStartPost = pkgs.writeShellScript "hakuspace-wallpaper-restore" ''
          for i in $(seq 20); do
            ${pkgs.awww}/bin/awww restore 2>/dev/null && break
            sleep 0.5
          done
          state="$HOME/.local/state/haku_theme/video_wallpaper"
          if [ -s "$state" ]; then
            readarray -t args < "$state"
            (${pkgs.mpvpaper}/bin/mpvpaper "''${args[@]}" >/dev/null 2>&1 &)
          fi
          exit 0
        '';
      };
      hakuspace-notifications = themed (
        service "Haku Space notification centre" "${pkgs.swaynotificationcenter}/bin/swaync"
      );
      hakuspace-idle = service "Haku Space idle daemon" "${pkgs.hypridle}/bin/hypridle";

      # Two watchers, not one: cliphist stores text and images through separate
      # wl-paste subscriptions and a single --watch handles one MIME class.
      hakuspace-clipboard-text = service "Haku Space clipboard history (text)"
        "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store";
      hakuspace-clipboard-image = service "Haku Space clipboard history (images)"
        "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store";

      /*
        waybar_manager.sh, not waybar, and oneshot rather than a supervised
        service. The script is what decides WHICH layout is live: it symlinks
        the selected layout's config and style.css into ~/.config/waybar and
        only then starts waybar (`if ! pgrep -x waybar; then waybar &`).
        Supervising waybar directly would start it before any layout had been
        chosen -- and on a first login there is no config to read at all.
      */
      hakuspace-bar = themed (oneshot "Haku Space bar" (bin "waybar_manager.sh"));
      hakuspace-dockbar = themed (oneshot "Haku Space dockbar" "${bin "dockbar_manager.sh"} --startup");
    };

    /*
      MUTABLE COPIES for the places hakuspace's own scripts EDIT IN PLACE,
      overriding the homeModule's store symlinks for exactly those entries:

        dockbar_manager.sh --exclusive/--icon-size  sed -i  waybar/dockbar/config
        rofi_theme_switcher.sh                      sed -i  rofi/config.rasi

      A store symlink breaks each one, in a different way. dockbar is a
      whole-directory link, so sed cannot even create its temp file and the
      toggles silently do nothing. config.rasi is a file link in a writable
      parent, so sed SUCCEEDS -- by replacing the symlink with a real file,
      which the next activation clobbers back to the store default (leaving
      a .hm-backup); the chosen theme survives until the next rebuild and
      then vanishes.

      So both entries are unlinked and seeded ONCE as writable copies --
      the same contract as ~/hakuspace-control: an existing real file is
      the user's and is never touched again. (waybar/config + style.css
      need nothing here: the tree ships no top-level defaults, so they were
      never home-manager entries -- waybar_manager.sh creates and re-points
      those links itself on every session start.) entryAfter linkGeneration,
      because that is the phase that removes the previous generation's
      symlinks; seeding before it would race the cleanup.
    */
    xdg.configFile =
      let
        share = "${config.programs.hakuspace.package}/share/hakuspace/config";

        /*
          Custom modules injected into EVERY layout, JSON-aware (all seven
          configs parse as clean JSON, so placement is structural, not
          textual; json.dump reformats, which waybar ignores):

            custom/easyeffects  EasyEffects 8.x dropped its tray icon (no
                                StatusNotifier code in the binary), so it can
                                never appear in waybar's tray; run hidden, it
                                had no way to reopen. An equalizer glyph next
                                to the volume module opens the GUI on click.

          (An input-method KO/EN module lived here too; removed on request --
          fcitx5's own tray icon is kept instead.)

          place() inserts once at the first anchor that exists, so a layout
          missing one anchor (minimal has no custom/notification) falls through
          to the next.
        */
        /*
          Output-device picker on the volume module's right-click: a rofi list
          of sinks (earphones, speakers, HDMI, ...), setting the chosen one as
          default AND moving every already-playing stream onto it -- otherwise
          audio started before the switch stays on the old device. pavucontrol
          (the full mixer) moves to middle-click; it also stays in the
          hakumenu's Audio Control entry. pactl talks to pipewire-pulse.
        */
        audioSinkMenu = pkgs.writeShellScript "waybar-audio-sink" ''
          PACTL=${pkgs.pulseaudio}/bin/pactl
          AWK=${pkgs.gawk}/bin/awk

          # Enumerate PORTS, not sinks. Built-in speakers and the headphone jack
          # are two ports of ONE sink, so a sink list only ever showed "Analog
          # Stereo"; a port list shows "Speakers" and "Headphones" separately.
          # Bluetooth devices are their own sink (each with a port) and appear
          # when connected. "not available" ports (e.g. the jack with nothing
          # plugged) are hidden; the easyeffects virtual sink has no ports so it
          # drops out on its own. Line = "PortDesc (SinkDesc)<TAB>sink<TAB>port".
          sel=$("$PACTL" list sinks | "$AWK" '
            /^Sink #/         { name=""; desc=""; inports=0 }
            /^\tName:/        { name=$2 }
            /^\tDescription:/ { d=$0; sub(/^\tDescription: /,"",d); desc=d }
            /^\tPorts:/       { inports=1; next }
            /^\t[^\t]/        { if ($0 !~ /^\tPorts:/) inports=0 }
            inports && /^\t\t[A-Za-z0-9_.-]+: / {
                l=$0; sub(/^\t\t/,"",l)
                pid=l; sub(/: .*/,"",pid)
                pd=l;  sub(/^[^:]+: /,"",pd); sub(/ \(.*/,"",pd)
                if (l !~ /not available/)
                    printf "%s (%s)\t%s\t%s\n", pd, desc, name, pid
            }
          ' | ${rofiEmoji}/bin/rofi -dmenu -i -p "Output device" -display-columns 1)
          [ -z "$sel" ] && exit 0
          target=$(printf '%s' "$sel" | ${pkgs.coreutils}/bin/cut -f2)
          port=$(printf '%s'  "$sel" | ${pkgs.coreutils}/bin/cut -f3)

          # Point that sink at the chosen port (this alone is the speaker<->jack
          # switch, and it is safe with EasyEffects: EE keeps outputting to this
          # sink, now via the new port).
          "$PACTL" set-sink-port "$target" "$port"

          def=$("$PACTL" get-default-sink)
          ee=$("$PACTL" list short sinks | "$AWK" '$2=="easyeffects_sink"{print $1}')
          if [ "$def" = easyeffects_sink ]; then
            # Apps stay routed through EasyEffects (default); only redirect what
            # EE (and any direct stream) sends to hardware -- i.e. every
            # sink-input NOT already on the EE sink -- to the chosen device. So
            # switching to Bluetooth carries EE's processed output along.
            "$PACTL" list short sink-inputs | while read -r id s _; do
              [ "$s" != "$ee" ] && "$PACTL" move-sink-input "$id" "$target"
            done
          else
            # No EasyEffects in the path: make the device default and drag every
            # stream onto it.
            "$PACTL" set-default-sink "$target"
            "$PACTL" list short sink-inputs | "$AWK" '{print $1}' | while read -r id; do
              "$PACTL" move-sink-input "$id" "$target" 2>/dev/null || true
            done
          fi
        '';
        modulesPatch = pkgs.writeText "waybar-custom-modules.py" ''
          import json, sys
          path, sink_menu, pavu = sys.argv[1:4]
          c = json.load(open(path))
          # Output-device switch on the volume module: right-click picks a sink,
          # middle-click opens the full mixer. Left-click (mute) is left as-is.
          # (The Wi-Fi/Bluetooth modules that used to live here are gone -- the
          # native nm-applet and blueman-applet tray icons cover those now.)
          if isinstance(c.get("pulseaudio"), dict):
              c["pulseaudio"]["on-click-right"] = sink_menu
              c["pulseaudio"]["on-click-middle"] = pavu
          json.dump(c, open(path, "w"), ensure_ascii=False, indent=4)
        '';
        addModules = ''
          ${pkgs.python3}/bin/python3 ${modulesPatch} $out/config \
            ${audioSinkMenu} ${pkgs.pavucontrol}/bin/pavucontrol
        '';

        # Layouts that only need the EasyEffects module (island/coredge/full/left
        # already show the date inline and have no custom/settings drawer).
        patchEE =
          mode:
          pkgs.runCommand "hakuspace-waybar-${mode}-ee" { } ''
            cp -r ${share}/waybar/${mode} $out
            chmod -R u+w $out
            ${addModules}
          '';

        patchMode =
          mode:
          pkgs.runCommand "hakuspace-waybar-${mode}-patched" { } ''
            cp -r ${share}/waybar/${mode} $out
            chmod -R u+w $out

            # Clock: date inline, not behind a click.
            substituteInPlace $out/config \
              --replace-fail '"format": " {:%H:%M} "' '"format": " {:%H:%M · %a %d %b} "'

            ${addModules}
          '';
      in
      {
        "waybar/dockbar".enable = false;
        "rofi/config.rasi".enable = false;

        /*
          Clock with the date visible, not a click away. top/neon/minimal
          ship a bare " {:%H:%M} " and hide the date behind format-alt (a
          click) -- the other four layouts already show it inline, so this
          only brings the three stragglers in line with upstream's own idiom
          (compact date, no year; the hover calendar is untouched).
          substituteInPlace --replace-fail so an upstream format change
          breaks the build instead of silently reverting the tweak.
        */
        "waybar/top".source = lib.mkForce (patchMode "top");
        "waybar/neon".source = lib.mkForce (patchMode "neon");
        "waybar/minimal".source = lib.mkForce (patchMode "minimal");

        # The other four layouts get the EasyEffects module too, so it is
        # present whichever layout is live.
        "waybar/island".source = lib.mkForce (patchEE "island");
        "waybar/coredge".source = lib.mkForce (patchEE "coredge");
        "waybar/full".source = lib.mkForce (patchEE "full");
        "waybar/left".source = lib.mkForce (patchEE "left");

        # networkmanager_dmenu speaks dmenu by default; point it at rofi so
        # the network picker matches every other menu on this desktop. The
        # gui editor escape hatch is nm-connection-editor, installed below.
        "networkmanager-dmenu/config.ini".text = ''
          [dmenu]
          dmenu_command = ${rofiEmoji}/bin/rofi -dmenu -i
          [editor]
          gui_if_available = true
        '';

        /*
          swaync, still a whole-dir link -- but to a patched copy, so
          style.css can carry a fix. Same shape as the waybar overrides
          above, and deliberately NOT per-file relinking: converting an
          existing whole-dir symlink into a real directory is a transition
          home-manager's activation cannot make (its cleanup leaves the old
          dir link standing, then tries to create the children INSIDE the
          store -- EROFS, failed switch). Retargeting a dir link is just a
          relink.

          The fix itself: upstream styles the menubar's two menu buttons
          (power, power-profile) through
          `.widget-menubar > box > .menu-button-bar` -- the GTK3-era widget
          tree. swaync 0.12 is GTK4 and appends .menu-button-bar DIRECTLY
          to .widget-menubar (menubar.vala:57), so every rule with that
          extra `box` hop matches nothing and the two buttons render bare;
          only the padding rule survives, being written without the hop.
          Corrected selectors are APPENDED to a byte-identical copy of
          upstream's file, so upstream changes still flow through and the
          diff to offer upstream is exactly the appendix.
        */
        "swaync".source = lib.mkForce (
          pkgs.runCommand "hakuspace-swaync-gtk4-fixed" { } ''
            cp -r ${share}/swaync $out
            chmod -R u+w $out
            cat >> $out/style.css <<'EOF'

            /* Appended by features/hakuspace (nix): GTK4 selector fix for the
               menubar menu buttons -- see the note in home.nix. */
            .widget-menubar > .menu-button-bar > .widget-menubar-container button {
                min-width: 100px;
                background: @accent_color;
                border: 1px solid @accent_color;
                border-radius: 8px;
                color: #000000;
            }

            .widget-menubar > .menu-button-bar > .widget-menubar-container button:hover {
                background: shade(@accent_color, 1.08);
                border: 1px solid shade(@accent_color, 1.08);
            }

            .widget-menubar > .menu-button-bar > .widget-menubar-container button label {
                color: #000000;
            }
            EOF
          ''
        );
      };

    home.activation.hakuspaceMutableSeeds =
      let
        share = "${config.programs.hakuspace.package}/share/hakuspace/config";
      in
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        if [ -L "$HOME/.config/waybar/dockbar" ] || [ ! -e "$HOME/.config/waybar/dockbar" ]; then
          run rm -f "$HOME/.config/waybar/dockbar"
          run mkdir -p "$HOME/.config/waybar"
          run cp -r ${share}/waybar/dockbar "$HOME/.config/waybar/dockbar"
          run chmod -R u+w "$HOME/.config/waybar/dockbar"
        fi
        if [ -L "$HOME/.config/rofi/config.rasi" ] || [ ! -e "$HOME/.config/rofi/config.rasi" ]; then
          run rm -f "$HOME/.config/rofi/config.rasi"
          run mkdir -p "$HOME/.config/rofi"
          run install -m644 ${share}/rofi/config.rasi "$HOME/.config/rofi/config.rasi"
        fi
      '';

    /*
      What the hakumenu spawns but nothing installs. Upstream's install.sh
      puts these on the system with pacman; the Setting/General tabs then
      shell out to them by name, and on this host half the entries were
      dead air.

      Two of the names need shims, not just packages:

        localsend  the nixpkgs package's binary is `localsend_app`; the
                   menu (and upstream's Arch package) call `localsend`.
        code       upstream means VS Code, which this machine does not
                   run. The entries just want "open this file in the
                   editor", and the editor here is Emacs -- `-a ""`
                   starts the daemon if it is not up yet. Swap the shim
                   for pkgs.vscode if a real VS Code ever lands here.
    */
    home.packages = [
      pkgs.pavucontrol # "Audio Control"
      pkgs.networkmanagerapplet # "Wifi" -> nm-connection-editor
      pkgs.blueman # "Bluetooth" -> blueman-manager
      pkgs.gparted # "Disk Manager"
      pkgs.localsend # desktop entry + icon; the menu-visible name is the shim:
      (pkgs.writeShellScriptBin "localsend" ''exec ${pkgs.localsend}/bin/localsend_app "$@"'')
      (pkgs.writeShellScriptBin "code" ''exec emacsclient -c -a "" "$@"'')

      /*
        The waybar connectivity icons' click targets (see patchMode): rofi
        pickers for Wi-Fi and Bluetooth, the closest waybar gets to a
        dropdown. Both shell out to `rofi` by bare name, so rofi joins the
        profile too -- the same emoji-enabled build the compositor binds use,
        which the store dedupes into one copy.
      */
      pkgs.networkmanager_dmenu
      pkgs.rofi-bluetooth
      (pkgs.rofi.override { plugins = [ pkgs.rofi-emoji ]; })
    ];

    /*
      App icons for the dockbar and rofi's drun mode. dockbar_geticon.sh
      resolves icons through GTK's icon theme; with nothing configured the
      lookup falls back to hicolor/Adwaita, which carries almost no
      third-party app icons -- so most of the dock rendered as the
      image-missing glyph. Papirus is the usual pairing for this kind of
      shell and covers effectively everything.
    */
    gtk = {
      enable = true;
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };
    };

    # Both routes, for the reason features/cursor-theme documents on its
    # cursor keys: settings.ini serves apps that read GtkSettings directly,
    # but GTK under Wayland resolves themes from the gsettings keys -- one
    # without the other leaves pygobject lookups (dockbar_geticon.sh) on
    # Adwaita. cursor-theme sets other keys on this same dconf path;
    # attrsets merge.
    dconf.settings."org/gnome/desktop/interface".icon-theme = "Papirus-Dark";

    # Default apps in ~/.config/mimeapps.list -- the user-level list, which
    # wins over any system default (e.g. features/hop's mkDefault claims):
    #   directories -> Dolphin, the host's file manager (matches the thunar
    #     shim above), for every xdg-open consumer (localsend's "open folder",
    #     browsers' "show in folder").
    #   PDFs -> Okular.
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "inode/directory" = [ "org.kde.dolphin.desktop" ];
        "application/pdf" = [ "org.kde.okular.desktop" ];
        # Default browser -> Firefox: the web schemes and HTML.
        "x-scheme-handler/http" = [ "firefox.desktop" ];
        "x-scheme-handler/https" = [ "firefox.desktop" ];
        "text/html" = [ "firefox.desktop" ];
        "x-scheme-handler/about" = [ "firefox.desktop" ];
      };
    };

    /*
      The idle/lock configs, linked as INDIVIDUAL files into ~/.config/hypr.

      They live under src/common/config/hypr in the tree, but "hypr" must not
      join configNames: features/hyprland owns that directory, and linking it
      whole would fight over it. These three, though, belong to the SHELL --
      hypridle hard-exits without its config (the unit above would crash-loop),
      and lock.sh invokes hyprlock against both conf variants by literal path.
      They call only the module's own ~/.local/bin scripts plus
      loginctl/systemctl/brightnessctl, so they are compositor-config-free and
      ride along with the services rather than through configNames.

      hypridle.conf is a PATCHED copy; the two hyprlock files are direct.
      Two brightness bugs across a lid-suspend cycle, both fixed here:

        1. The idle listener dims with `brightnessctl -s set 10` -- `-s`
           saves the CURRENT level as the restore point, then sets 10. If it
           ever fires while already dim (a second idle tick, or a spurious
           re-fire on resume), it saves 10 as the restore point, and every
           later `-r` restores 10 forever. Guarded to only dim, and only
           save, when currently above 15%.

        2. Nothing captured brightness around suspend itself. Lid close
           always suspends here (logind HandleLidSwitch), and hypridle's
           on-resume restore raced the compositor coming back. before_sleep
           now saves the real current level and after_sleep restores it --
           authoritative on every wake, independent of the idle listener's
           state.
    */
    home.file =
      let
        pkgHypr = "${config.programs.hakuspace.package}/share/hakuspace/config/hypr";
        # Dim to 10% ONLY when currently above 15% -- so a re-fire while
        # already dim never saves 10 as the restore point. brightnessctl -m
        # prints name,type,current,percent,max; field 4 is the percent.
        dimGuard = pkgs.writeShellScript "hakuspace-idle-dim" ''
          pct=$(brightnessctl -m | ${pkgs.gnused}/bin/sed -E 's/([^,]*,){3}([0-9]+)%.*/\2/')
          [ "''${pct:-0}" -gt 15 ] && exec brightnessctl -s set 10
          exit 0
        '';

        /*
          The idle-suspend gate, replacing upstream's idle_inhibit.sh on the
          suspend listener only. hypridle runs on-timeout when condition_cmd
          exits 0 and blocks (+retries) when it is non-zero. So: exit 0 to
          ALLOW the suspend, non-zero to BLOCK it.

          idle_inhibit.sh was unreliable here: it opens with a `hypridle -V`
          version check that misbehaves in the daemon's own PATH, and it never
          considered AC power -- so "keeps sleeping when I walk away" happened
          even with the notification-centre nosleep toggle on. This reads the
          two things that actually matter, directly:

            - plugged in  -> never idle-suspend (the leave-it-to-build case).
            - nosleep on  -> never (the toggle now genuinely works, no version
                             check to trip over). Same state file the toggle
                             writes: ~/.local/state/haku_theme/idle_inhibit.

          Everything else on battery still suspends, but at a saner 15 min
          (below), not 5.
        */
        suspendGate = pkgs.writeShellScript "hakuspace-idle-suspend-gate" ''
          for f in /sys/class/power_supply/A*/online; do
            [ -r "$f" ] && [ "$(cat "$f")" = 1 ] && exit 1
          done
          [ "$(cat "$HOME/.local/state/haku_theme/idle_inhibit" 2>/dev/null)" = 1 ] && exit 1
          exit 0
        '';

        hypridleFixed = pkgs.runCommand "hakuspace-hypridle-fixed" { } ''
          cp ${pkgHypr}/hypridle.conf $out
          chmod u+w $out

          # (1) never dim -- and never save a restore point -- when already dim.
          substituteInPlace $out \
            --replace-fail 'on-timeout = brightnessctl -s set 10' \
              'on-timeout = ${dimGuard}'

          # (2) save around the suspend the lid triggers, restore on wake.
          substituteInPlace $out \
            --replace-fail 'before_sleep_cmd = loginctl lock-session && ~/.local/bin/dpms_handler.sh off' \
              'before_sleep_cmd = brightnessctl -s && loginctl lock-session && ~/.local/bin/dpms_handler.sh off'
          substituteInPlace $out \
            --replace-fail 'after_sleep_cmd = ~/.local/bin/dpms_handler.sh on' \
              'after_sleep_cmd = ~/.local/bin/dpms_handler.sh on && brightnessctl -r'

          # (3) idle-suspend: AC-aware + a reliable nosleep gate, 5 min -> 15 min.
          #     timeout=300 is unique to the suspend listener; the condition_cmd
          #     line is shared, so it is rewritten only inside the suspend block
          #     (the sed range anchored on `systemctl suspend`), leaving the
          #     dim/lock/dpms listeners' own conditions untouched.
          ${pkgs.gnused}/bin/sed -i \
            -e 's|timeout = 300|timeout = 900|' \
            -e '/on-timeout = systemctl suspend/,/condition_retry/ {
                  s|condition_cmd = .*|condition_cmd = ${suspendGate}|
                  s|condition_retry = .*|condition_retry = 30|
                }' \
            $out
        '';
      in
      {
        ".config/hypr/hypridle.conf".source = hypridleFixed;
        ".config/hypr/hyprlock.conf".source = "${pkgHypr}/hyprlock.conf";
        ".config/hypr/hyprlock_tiny.conf".source = "${pkgHypr}/hyprlock_tiny.conf";
      };
  };
}
