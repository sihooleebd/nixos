{ config, lib, pkgs, osConfig, inputs, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "hakuspace"; };
  cfg = osConfig.my.hakuspace;
  enabled = cfg.enable && inScope;

  bin = name: "${config.home.homeDirectory}/.local/bin/${name}";

  /*
    Keep the PREVIOUS Hyprland session's log across a reboot. Hyprland writes to
    $XDG_RUNTIME_DIR/hypr/<instance>/hyprland.log -- tmpfs, wiped on reboot -- so
    a freeze that forces a hard power-off destroys the very log that would
    explain it. This mirrors the live log to disk as it is written and, on each
    session start, rotates the last capture to `previous.log`. After a
    freeze+reboot, previous.log holds the frozen session up to the instant it
    locked. Line-buffered (stdbuf) so the final lines actually reach the platter;
    `tail -F --retry` waits for the log to appear as the session comes up, and a
    short poll finds the newest instance dir.
  */
  hyprlandLogKeeper = pkgs.writeShellScript "hakuspace-hyprland-log-keep" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
    state="$HOME/.local/state/hyprland"
    mkdir -p "$state"
    [ -f "$state/current.log" ] && mv -f "$state/current.log" "$state/previous.log"
    : > "$state/current.log"
    rt="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr"
    live=""
    for _ in $(seq 50); do
      live=$(ls -1t "$rt"/*/hyprland.log 2>/dev/null | head -1)
      [ -n "$live" ] && break
      sleep 0.2
    done
    [ -z "$live" ] && exit 0
    exec stdbuf -oL tail -n +1 -F --retry "$live" >> "$state/current.log"
  '';

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

  # hyprlock background: a fixed PNG that always mirrors the CURRENT wallpaper, so the
  # lock screen shows the (blurred, dimmed) wallpaper -- NOT a screenshot of the live
  # desktop (upstream's `path = screenshot`, which leaks whatever windows were open; see
  # hyprlockNoText). awww caches the active image PATH per output in a small BINARY file
  # ~/.cache/awww/<ver>/<output> (NUL-separated fields; the last is the absolute image
  # path). hyprlockBgGen resolves that and re-encodes to a fixed JPEG (hyprlock loads by
  # extension and the source may be jpg/png/...; the bg is blurred+dimmed anyway, so JPEG
  # is smaller/faster than a lossless PNG). It runs at session start (appended to the
  # wallpaper-restore ExecStartPost) and on every wallpaper change (the systemd .path
  # watcher below), so hyprlock loads the file INSTANTLY at lock time -- no per-lock
  # conversion, no window of a bright/unlocked screen while it works.
  hyprlockBg = "${config.home.homeDirectory}/.cache/hyprlock-bg.jpg";
  hyprlockBgGen = pkgs.writeShellScript "hakuspace-hyprlock-bg-gen" ''
    export PATH=${lib.makeBinPath [ pkgs.imagemagick pkgs.coreutils pkgs.gnugrep ]}:$PATH
    cache="$HOME/.cache/awww/${pkgs.awww.version}/eDP-1"
    [ -s "$cache" ] || cache=$(ls "$HOME/.cache/awww/${pkgs.awww.version}/"* 2>/dev/null | head -1)
    [ -s "$cache" ] || exit 0
    # Binary cache: \0crop:<pos>\0<filter>\0<ABS IMAGE PATH>. Pull the path as the LAST
    # run of non-control bytes starting with '/' (robust to NUL separators AND spaces in
    # the path). A video wallpaper caches a color, not a path -> no match -> keep the
    # previous file rather than clobbering it.
    src=$(grep -aoE '/[^[:cntrl:]]+' "$cache" | tail -1)
    [ -n "$src" ] && [ -f "$src" ] || exit 0
    out="${hyprlockBg}"
    tmp="$out.tmp.$$"
    # Shrink only if huge (cap the long edge ~2560) to keep hyprlock's load light; do NOT
    # pre-blur/dim -- hyprlock applies its own blur + brightness. The `jpg:` coder prefix
    # FORCES JPEG output: without it magick picks the format from the tmp file's extension
    # (here ".tmp.$$", unknown) and silently falls back to the INPUT format -- a .jpg named
    # file holding the wrong bytes. Atomic via tmp + mv.
    if magick "$src" -resize '2560x2560>' -quality 88 jpg:"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$out"
    else
      rm -f "$tmp"
    fi
  '';
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
                        # dockbar_geticon.sh / desktop_icons.py (app icon lookup)
                        gtk3
                        gobject-introspection
                        pango.out
                        gdk-pixbuf
                        harfbuzz.out
                        atk
                        # cava_layer.py (the bar underbar): a GtkLayerShell
                        # layer-surface hosting a Vte terminal that runs cava.
                        # Without these two typelibs cava_manager.sh's dep check
                        # fails on GtkLayerShell/Vte and the toggle exits silently.
                        gtk-layer-shell
                        vte
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

                # Notification bell: upstream wires it to swaync-client, but this host replaced swaync
                # with the quickshell notif centre (features/notifcenter) -- swaync-client is GONE, so
                # exec-if failed (no count) and the click was a no-op. Point the click at the haku-notif
                # IPC toggle (same thing SUPER+N runs) and drop the swaync count subscription -> a plain
                # bell that actually opens the centre. (A live count would need a haku-notif IPC; later.)
                ${pkgs.python3}/bin/python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["custom/notification"]={"tooltip":False,"format":"󰂚","on-click":"quickshell -c haku-notif ipc call panel toggle","on-click-right":"quickshell -c haku-notif ipc call panel toggle","escape":True}; json.dump(c,open(p,"w"),ensure_ascii=False,indent=4)' \
                  $out/share/hakuspace/config/waybar/module/notification_module

                # Launch the pygobject layers (cava underbar, desktop icons) via
                # their OWN wrapper, not `python3 <wrapper>`. Upstream runs
                # `python3 $SCRIPT`, assuming $SCRIPT is the raw .py. Here it is
                # the makeWrapper SHELL wrapper (it carries GI_TYPELIB_PATH), so
                # `python3` on it dies with a SyntaxError on line 2 and the layer
                # never starts -- the toggles silently did nothing. Running the
                # wrapper directly execs the real script with the typelibs set.
                substituteInPlace $out/share/hakuspace/scripts/cava_manager.sh \
                  --replace-fail 'nohup python3 "$SCRIPT_PATH" "$@"' 'nohup "$SCRIPT_PATH" "$@"'
                substituteInPlace $out/share/hakuspace/scripts/desktop_icons_manager.sh \
                  --replace-fail 'python3 "$DESKTOP_MANAGER_BIN" &' '"$DESKTOP_MANAGER_BIN" &'

                # The manager kills/detects the daemon by its LAUNCH path,
                # $DESKTOP_MANAGER_BIN = ~/.local/bin/desktop_icons.py -- but that
                # is a makeWrapper shell wrapper that execs the store script, so
                # the running process's cmdline is `python3 .../desktop_icons.py`
                # and never contains the ~/.local/bin path. So `pkill -f
                # "$DESKTOP_MANAGER_BIN"` matched nothing (toggle-OFF left the
                # daemon running) and `pgrep -f "$DESKTOP_MANAGER_BIN"` reported
                # "not running" even when it was (toggle-ON / --startup spawned
                # duplicates). Match the basename, which IS in the real cmdline
                # and does not collide with desktop_icons_manager.sh.
                substituteInPlace $out/share/hakuspace/scripts/desktop_icons_manager.sh \
                  --replace-fail '-f "$DESKTOP_MANAGER_BIN"' '-f "desktop_icons.py"'

                # Replace the experimental, buggy upstream desktop_icons.py
                # WHOLESALE with our reimplementation (features/hakuspace/
                # desktop-icons.py). Upstream showed a generic document glyph for
                # every file, never launched .desktop files, and kept a tiny
                # window that expanded to fullscreen only during a drag -- each
                # resize replayed the layer animation, so icons/labels wobbled
                # (the "jelly"). Ours resolves real icons, launches via `gio
                # launch`, and is a STATIC full-monitor layer that never resizes.
                # The ~/.local/bin/desktop_icons.py wrapper still supplies
                # GI_TYPELIB_PATH and execs this same path, so only the body
                # changes.
                cp ${./desktop-icons.py} $out/share/hakuspace/scripts/desktop_icons.py
                chmod +x $out/share/hakuspace/scripts/desktop_icons.py

                # Route the FILE PICKER to the KDE portal (Dolphin-style, dark)
                # in the config that ACTUALLY wins. The shell ships its own
                # ~/.config/xdg-desktop-portal/hyprland-portals.conf, and for
                # XDG_CURRENT_DESKTOP=Hyprland xdg-desktop-portal uses the first
                # <desktop>-portals.conf it finds ENTIRELY (no merge with the
                # system portals.conf). So features/session-services' system-
                # level FileChooser=kde was silently shadowed -- Firefox's open/
                # save dialog fell through to gtk. Add the route to this file so
                # it takes effect; `default` (hyprland;gtk) is kept for
                # screenshot/screencast.
                cp ${
                  pkgs.writeText "hyprland-portals.conf" ''
                    [preferred]
                    default = hyprland;gtk;
                    org.freedesktop.impl.portal.FileChooser=kde
                  ''
                } $out/share/hakuspace/config/xdg-desktop-portal/hyprland-portals.conf

                # fastfetch: NixOS banner greeting instead of the boxed Haku
                # Space panel -- the medium builtin NixOS2 logo on top, an identity
                # line beneath (❄ user@host · kernel · uptime). LEFT-ALIGNED here
                # (padding 0, bare ❄ key); fastfetch has no horizontal centering,
                # so features/fish's greeting pipes this through a wrapper that
                # block-centers the logo, appends a second ❄ system-status line,
                # centers both info lines, and adds top/bottom banner padding --
                # all to the live terminal width.
                cp ${
                  pkgs.writeText "fastfetch-config.jsonc" ''
                    {
                        "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
                        "logo": {
                            "type": "builtin",
                            "source": "NixOS2",
                            "position": "top",
                            "padding": { "top": 0, "left": 0 }
                        },
                        "display": { "separator": " " },
                        "modules": [
                            {
                                "type": "command",
                                "key": "❄",
                                "text": "printf '%s@%s · %s · up %s' \"$USER\" \"$(uname -n)\" \"$(uname -r)\" \"$(uptime -p | sed 's/^up //')\""
                            }
                        ]
                    }
                  ''
                } $out/share/hakuspace/config/fastfetch/config.jsonc

                # Cava underbar color follows the theme accent, not a hardcoded
                # black. Two problems: the config's `foreground = black`, and its
                # default path ~/.config/cava/cava-layer is a READ-ONLY store
                # symlink -- so cava_layer.py could never rewrite it (and once
                # the if-missing guard is dropped, writing it crashes on the
                # read-only FS). Redirect the default to a WRITABLE path in the
                # theme-state dir, drop the guard, and set foreground = the live
                # @accent_color from haku_theme/colors.css -- regenerated every
                # start, so it tracks the theme.
                ${pkgs.python3}/bin/python3 ${
                  pkgs.writeText "cava-accent.py" ''
                    import os, sys
                    p = sys.argv[1]
                    s = open(p).read()
                    s = s.replace("default='~/.config/cava/cava-layer'",
                                  "default='~/.local/state/haku_theme/cava-layer'")
                    s = s.replace("foreground = black", "foreground = '{fg}'")
                    s = s.replace("    if os.path.exists(config_path):\n        return\n", "")
                    s = s.replace("        f.write(DEFAULT_CONFIG_TEMPLATE)",
                                  "        f.write(DEFAULT_CONFIG_TEMPLATE.format(fg=_cava_accent()))")
                    helper = ("def _cava_accent():\n"
                              "    import re\n"
                              "    try:\n"
                              "        t = open(os.path.expanduser('~/.local/state/haku_theme/colors.css')).read()\n"
                              "        m = re.search(r'accent_color +(#[0-9a-fA-F]{6})', t)\n"
                              "        return m.group(1) if m else '#ffffff'\n"
                              "    except Exception:\n"
                              "        return '#ffffff'\n\n")
                    s = s.replace("def ensure_config_exists(config_path):", helper + "def ensure_config_exists(config_path):", 1)
                    open(p, "w").write(s)
                  ''
                } $out/share/hakuspace/scripts/cava_layer.py
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
          # Seed the hyprlock lock-screen background from the just-restored wallpaper;
          # the .path watcher keeps it current afterwards. || true so a first boot with
          # no wallpaper doesn't fail the unit.
          ${hyprlockBgGen} || true
          exit 0
        '';
      };
      # Regenerate the hyprlock background when the wallpaper changes. NOT the `oneshot`
      # helper: it sets RemainAfterExit=true, which would make a SECOND .path trigger a
      # no-op (unit already "active") -- so a wallpaper change wouldn't refresh the lock
      # bg. Plain re-runnable oneshot, no Install (only the .path below starts it; startup
      # generation is the wallpaper-restore ExecStartPost just above).
      hakuspace-hyprlock-bg = {
        Unit = {
          Description = "Haku Space hyprlock background (mirror current wallpaper)";
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${hyprlockBgGen}";
        };
      };
      # swaync is REPLACED by the quickshell notif centre (features/notifcenter) when that's on --
      # two daemons can't both own org.freedesktop.Notifications. Gated so my.notifcenter.enable=false
      # brings swaync straight back (the fallback if the quickshell centre misbehaves).
      hakuspace-notifications = lib.mkIf (!osConfig.my.notifcenter.enable) (themed (
        service "Haku Space notification centre" "${pkgs.swaynotificationcenter}/bin/swaync"
      ));
      hakuspace-idle = service "Haku Space idle daemon" "${pkgs.hypridle}/bin/hypridle";
      # Gamma + kbd-backlight RESET on every session start -- the safety net for the gamma
      # idle dim (features/hakuspace dim path). The user has no gamma control, so if a crash
      # or freeze ever left a hyprsunset daemon alive (holding the dim ramp) or the keyboard
      # backlight dimmed, there would be no way to recover. Resetting at login guarantees a
      # clean slate: kill any stray hyprsunset (its ramp reverts to full) + kbd backlight up.
      # Needs no compositor (pkill + sysfs), so it runs regardless of startup ordering.
      hakuspace-gamma-reset = oneshot "Haku Space gamma reset" (pkgs.writeShellScript "hakuspace-gamma-reset-startup" ''
        ${pkgs.procps}/bin/pkill -x hyprsunset 2>/dev/null
        for l in /sys/class/leds/*kbd_backlight; do
          [ -e "$l" ] && ${pkgs.brightnessctl}/bin/brightnessctl -d "''${l##*/}" set 100% >/dev/null 2>&1
        done
        exit 0
      '');
      # Keeps ~/.cache/hyprlock/* warm so the lock-screen info labels (lockRead) show
      # instantly + together on an AOD wake, and spawn no playerctl/wpctl on hyprlock's
      # own path (less password stutter). The loop self-gates on `pgrep hyprlock`, so it's
      # idle (a 20s check) whenever the screen isn't locked. Exec'd by installed path.
      hakuspace-hyprlock-cache = service "Haku Space hyprlock value cache" (bin "hyprlock-cache-loop");

      # Two watchers, not one: cliphist stores text and images through separate
      # wl-paste subscriptions and a single --watch handles one MIME class.
      hakuspace-clipboard-text = service "Haku Space clipboard history (text)"
        "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store";
      hakuspace-clipboard-image = service "Haku Space clipboard history (images)"
        "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store";

      # Mirror Hyprland's (tmpfs, reboot-wiped) log to disk, keeping the previous
      # session's copy so a freeze-forced hard power-off leaves a trace to read.
      hakuspace-hyprland-log = service "Haku Space Hyprland log keeper" hyprlandLogKeeper;

      /*
        waybar_manager.sh, not waybar, and oneshot rather than a supervised
        service. The script is what decides WHICH layout is live: it symlinks
        the selected layout's config and style.css into ~/.config/waybar and
        only then starts waybar (`if ! pgrep -x waybar; then waybar &`).
        Supervising waybar directly would start it before any layout had been
        chosen -- and on a first login there is no config to read at all.
      */
      # waybar stays the PRIMARY bar -- it has the rich modules the HUD doesn't replicate (battery
      # mode, right-click network config, per-module scroll, tray, etc.). The statushub is an
      # experimental left text HUD running ALONGSIDE it, NOT a replacement, so waybar is not gated.
      # (Re-add `lib.mkIf (!osConfig.my.statushub.enable)` only once the HUD reaches real parity.)
      hakuspace-bar = themed (oneshot "Haku Space bar" (bin "waybar_manager.sh"));
      hakuspace-dockbar = themed (oneshot "Haku Space dockbar" "${bin "dockbar_manager.sh"} --startup");
    };

    # Watch the awww wallpaper cache and refresh the hyprlock background on change, so
    # the lock screen's wallpaper stays current without any per-lock work. awww rewrites
    # this per-output cache file whenever the wallpaper changes; PathChanged (fires on
    # close-after-write) starts hakuspace-hyprlock-bg.service. The version segment comes
    # from pkgs.awww.version so it tracks a flake bump; the output is this host's panel.
    systemd.user.paths.hakuspace-hyprlock-bg = {
      Unit = {
        Description = "Watch the wallpaper cache and refresh the hyprlock background";
        PartOf = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Path = {
        PathChanged = "${config.home.homeDirectory}/.cache/awww/${pkgs.awww.version}/eDP-1";
        Unit = "hakuspace-hyprlock-bg.service";
      };
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
          # plugged) are hidden.
          #
          # HYBRID enumeration, because cards differ: a classic ALSA sink (the
          # Intel Latitude's analog output) is ONE sink with several ports, so we
          # want one entry per available port (Speakers, Headphones). An AMD/UCM
          # card (the HP Victus) instead splits each output into its OWN sink
          # with an EMPTY Ports: list -- there a port list showed nothing, so we
          # fall back to the sink itself. Bluetooth sinks are portless too and
          # ride the same fallback. flush() emits that sink-level entry at each
          # sink boundary when no port was printed, skipping the portless
          # easyeffects virtual sink so it never appears.
          # Line = "PortDesc (SinkDesc)<TAB>sink<TAB>port", or for the fallback
          # "SinkDesc<TAB>sink<TAB>" (empty port).
          sel=$("$PACTL" list sinks | "$AWK" '
            function flush() {
                if (name != "" && had_port == 0 && name !~ /easyeffects/)
                    printf "%s\t%s\t\n", desc, name
            }
            /^Sink #/         { flush(); name=""; desc=""; inports=0; had_port=0 }
            /^\tName:/        { name=$2 }
            /^\tDescription:/ { d=$0; sub(/^\tDescription: /,"",d); desc=d }
            /^\tPorts:/       { inports=1; next }
            /^\t[^\t]/        { if ($0 !~ /^\tPorts:/) inports=0 }
            inports && /^\t\t[A-Za-z0-9_.-]+: / {
                l=$0; sub(/^\t\t/,"",l)
                pid=l; sub(/: .*/,"",pid)
                pd=l;  sub(/^[^:]+: /,"",pd); sub(/ \(.*/,"",pd)
                if (l !~ /not available/) {
                    printf "%s (%s)\t%s\t%s\n", pd, desc, name, pid
                    had_port=1
                }
            }
            END { flush() }
          ' | ${rofiEmoji}/bin/rofi -dmenu -i -p "Output device" -display-columns 1)
          [ -z "$sel" ] && exit 0
          target=$(printf '%s' "$sel" | ${pkgs.coreutils}/bin/cut -f2)
          port=$(printf '%s'  "$sel" | ${pkgs.coreutils}/bin/cut -f3)

          # Point that sink at the chosen port (speaker<->jack switch on a ported
          # sink; safe with EasyEffects -- EE keeps outputting to this sink, now
          # via the new port). Portless UCM/Bluetooth entries carry no port, so
          # skip this and let the default-switch below do the routing.
          [ -n "$port" ] && "$PACTL" set-sink-port "$target" "$port"

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
          import json, sys, shlex
          path, sink_menu, pavu = sys.argv[1:4]
          c = json.load(open(path))
          # Output-device switch on the volume module: right-click picks a sink,
          # middle-click opens the full mixer. Left-click (mute) is left as-is.
          # (The Wi-Fi/Bluetooth modules that used to live here are gone -- the
          # native nm-applet and blueman-applet tray icons cover those now.)
          if isinstance(c.get("pulseaudio"), dict):
              c["pulseaudio"]["on-click-right"] = sink_menu
              c["pulseaudio"]["on-click-middle"] = pavu
          # Recording button: reflect the actual state. The PERSISTENT recorder
          # button (island/top/... -- the one with no "exec", always shown)
          # hardcoded "tooltip-format": "Stop recording", so it lied while idle.
          # Make it emit JSON each poll so the tooltip (and a CSS-able class)
          # follow whether /tmp/recording_pid exists. The other variant --
          # custom/recorder-as-timer (has its own "exec"/if-file-exists, only
          # shown WHILE recording) -- is left alone; its "Stop recording" is
          # already correct because it only appears mid-recording.
          rec = c.get("custom/recorder")
          if isinstance(rec, dict) and "exec" not in rec:
              icon = rec.get("format", "")
              on = json.dumps({"text": icon, "tooltip": "Stop recording", "class": "recording"})
              off = json.dumps({"text": icon, "tooltip": "Start recording", "class": "idle"})
              rec["exec"] = "test -f /tmp/recording_pid && echo " + shlex.quote(on) + " || echo " + shlex.quote(off)
              rec["return-type"] = "json"
              rec["interval"] = 2
              rec["format"] = "{text}"
              rec["tooltip"] = True
              rec["tooltip-format"] = "{tooltip}"
          json.dump(c, open(path, "w"), ensure_ascii=False, indent=4)
        '';
        addModules = ''
          ${pkgs.python3}/bin/python3 ${modulesPatch} $out/config \
            ${audioSinkMenu} ${pkgs.pavucontrol}/bin/pavucontrol
        '';

        # Workspace button TEXT colour for the per-monitor/chess-notation scheme (features/hyprland,
        # features/sidedock): hardwired black on every button state, independent of the
        # haku_theme accent. Appended to style.css so it wins the cascade -- no upstream
        # anchor to drift, unlike substituteInPlace. (ext/workspaces renders as
        # #workspaces button in every layout.)
        addWsColors = ''
          printf '\n/* per-monitor workspaces: text hardwired black in all states */\n#workspaces button, #workspaces button.active, #workspaces button.empty, #workspaces button.overview { color: #000000; }\n' >> $out/style.css
        '';

        # Drop waybar's inline "cava" module from the bar: it SEGV's in getIcon on a style reload
        # (use-after-free -- a stray cava callback fires after the module is torn down; the theme
        # rewrites style.css on accent changes, so reload_style_on_change kept re-triggering it). The
        # full visualizer is the pygobject underbar (custom/cavaunderbar), which stays. Only island/
        # full/top list it; the grep guard keeps --replace-fail meaningful (fails loudly if the token
        # ever moves) while no-opping on layouts without it.
        dropCava = ''
          if grep -qE '^[[:space:]]*"cava",' $out/config; then
            substituteInPlace $out/config --replace-fail '"cava",' ""
          fi
        '';

        # Layouts that only need the EasyEffects module (island/coredge/full/left
        # already show the date inline and have no custom/settings drawer).
        patchEE =
          mode:
          pkgs.runCommand "hakuspace-waybar-${mode}-ee" { } ''
            cp -r ${share}/waybar/${mode} $out
            chmod -R u+w $out
            ${addModules}
            ${addWsColors}
            ${dropCava}
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
            ${addWsColors}
            ${dropCava}
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
            ${lib.optionalString osConfig.my.hyprland.keystone.enable ''
              # Dock-SHAPE the control centre: size/place it to a sidedock card's footprint so the
              # compositor keystone (extended to the "swaync-control-center" LAYER in
              # features/hyprland/trapezoid.patch) warps it into the SAME trapezoid, and it occupies
              # the dock's slot -- the two are toggled mutually exclusive (SUPER+N parks the dock;
              # showing the dock closes this). Values match features/sidedock's live geom on the dell
              # (2400x1350 logical: DW 800, right HGAP 40, top barH+VGAP 104, bottom VGAP 48,
              # DOCK_H 1198); gated on keystone.enable so only the dell (where the dock lives) gets
              # them. A very different monitor would want these redone (they're static, unlike the
              # dock's live recompute).
              ${pkgs.jq}/bin/jq '.positionX="right" | .positionY="top"
                | .["control-center-width"]=800 | .["control-center-height"]=1198
                | .["control-center-margin-top"]=104 | .["control-center-margin-bottom"]=48
                | .["control-center-margin-right"]=40 | .["control-center-margin-left"]=0' \
                $out/config.json > $out/config.json.tmp && mv $out/config.json.tmp $out/config.json
            ''}
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
        # Fullscreen frosted + DIMMED backdrop for BOTH the launcher and hakumenu
        # (both read this config.rasi). The shipped layout themes make `window` a small
        # opaque box, so Hyprland's blur has nothing to show through. Override window to
        # fullscreen (the visible box moves to the centered `mainbox`), so the rofi
        # LAYER spans the screen and the blur rule in compositor.nix frosts the whole
        # desktop behind it. The window fill is a translucent BLACK (not transparent):
        # over a light wallpaper a purely-transparent+blurred backdrop stayed near-white
        # and the menu read as white-on-white -- the dim guarantees contrast regardless
        # of what's behind. Appended AFTER the theme's `@theme` line so it wins.
        #
        # Re-applied on EVERY activation (strip any previous block, then re-append) so
        # edits here -- the dim, the padding/box size, the radius -- actually propagate
        # to an already-written config.rasi. The theme switcher only seds the `@theme`
        # line, well above this trailing block, so rewriting the block never fights it.
        if [ -e "$HOME/.config/rofi/config.rasi" ]; then
          # Self-heal an unclean-shutdown NUL corruption. config.rasi is MUTABLE (the theme
          # switcher seds it in place), so nothing restores it; a hard power-off (the
          # dell-latitude freeze) can leave a NUL-filled block mid-write, and NUL bytes are
          # not valid rasi -> rofi "syntax error ... expecting end of file" and a dead
          # launcher. Strip NULs (the @theme choice + settings survive; stray blank lines are
          # harmless to rasi) before the block rewrite below, which only touches marker..EOF.
          if ! tr -d '\0' < "$HOME/.config/rofi/config.rasi" | cmp -s - "$HOME/.config/rofi/config.rasi"; then
            tr -d '\0' < "$HOME/.config/rofi/config.rasi" > "$HOME/.config/rofi/config.rasi.heal" \
              && run mv -f "$HOME/.config/rofi/config.rasi.heal" "$HOME/.config/rofi/config.rasi"
          fi
          # BACKGROUND REMOVED (user request): just STRIP any previous haku-fullscreen-blur block
          # and re-append NOTHING, so rofi falls back to the theme's normal compact opaque window.
          # The old block made `window` fullscreen with a dimmed translucent-black backdrop so the
          # whole-desktop blur layer could show -- but that fullscreen layer was the source of the
          # open "blink" (it slid up from the bottom edge) AND the shadow mess. A compact menu has
          # neither. The sed below still runs on every activation so an already-written config.rasi
          # self-heals back to no-backdrop.
          run sed -i '/haku-fullscreen-blur/,$d' "$HOME/.config/rofi/config.rasi"
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
      # Force the DARK variant for GTK3 apps (blueman, nm-connection-editor, the
      # GTK file-picker fallback, ...). Without this they render Adwaita LIGHT:
      # GTK3 does NOT honor the org.gnome.desktop.interface color-scheme gsetting
      # (that only drives GTK4/libadwaita, which already follows the prefer-dark
      # set in features/cursor-theme). gtk-4.0 gets the key too -- harmless there.
      gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
      gtk4.extraConfig.gtk-application-prefer-dark-theme = true;
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

        # hyprlock without the two greeting labels: "Hi there, $USER" (top)
        # and "Have a nice day!" (bottom); the clock and input field stay.
        #
        # Done at EVAL time (builtins.toFile), NOT via a runCommand: a runCommand
        # is a derivation that would build on the remote builder, and this is
        # the one transformation that must not depend on it. Reads the config
        # from the hakuspace flake INPUT's source (a fetched path, no build,
        # byte-identical to what the package installs), drops each label block
        # by line, and writes the result straight to the store.
        hyprlockSrcDir = "${inputs.feat-hakuspace.inputs.hakuspace}/src/common/config/hypr";
        stripLockLabels =
          text:
          let
            step =
              acc: line:
              if acc.drop then
                (if line == "}" then acc // { drop = false; } else acc)
              else if line == "# USER (TOP)" || line == "# BOTTOM TEXT" then
                acc // { drop = true; }
              else
                acc // { out = acc.out ++ [ line ]; };
            r = lib.foldl' step { drop = false; out = [ ]; } (lib.splitString "\n" text);
          in
          lib.concatStringsSep "\n" r.out;
        # Battery + now-playing for the MAIN lock, placed on the RIGHT (the stock
        # clock/date/input get flipped to the LEFT by `toLeft` below). Dynamic
        # hyprlock labels: battery reads sysfs every 30s; now-playing polls
        # Lock-screen music widgets, each a SCRIPT the label calls by store path.
        # Why scripts: hyprlock uses hyprlang, which chokes on three things in a
        # value -- `{{ }}` (its math-expression syntax; THIS was the long "Sample
        # Text" bug via playerctl --format), `${ }` (its variables), and `{ }`
        # (category delimiters). A bare script path has none of those, and the
        # script can then use awk/`${ }`/`{ }` freely. Each script ALWAYS prints
        # non-empty text -- `general { text_trim = true }` collapses whitespace to
        # empty, which hyprlock renders as "Sample Text". These only DISPLAY;
        # control is the locked media keybinds in features/hyprland (hyprlock has
        # no clickable widgets).
        # AOD guard: when the AOD flag file exists (raised by the idle AOD stage, cleared
        # on any input -- see aodEnter/aodExit below), a lock label collapses to a single
        # BRAILLE BLANK (U+2800) instead of its content, so the right-hand info column +
        # transport row vanish and only the clock + password remain -- the "fake AOD"
        # minimal look. U+2800 (not an empty string) is deliberate: an empty label renders
        # hyprlock's "Sample Text" placeholder (general { text_trim = true }); the braille
        # blank is non-empty, non-whitespace, and draws nothing.
        aodGuard = ''
          flag="''${XDG_RUNTIME_DIR:-/tmp}/haku-aod"
          [ -e "$flag" ] && { printf '⠀'; exit 0; }
        '';
        # The info labels read a CACHE (hakuspace-hyprlock-cache keeps ~/.cache/hyprlock/*
        # warm while hyprlock runs, see the service below) instead of each SPAWNING
        # playerctl/wpctl on every poll. Two wins: (1) on AOD WAKE the labels cat an
        # already-warm cache, so music/battery/weather reappear INSTANTLY and TOGETHER
        # rather than popping in one-by-one as each slow command finishes ("random manner");
        # (2) far fewer process spawns on hyprlock's own path, so the password field doesn't
        # stutter. lockRead = the per-label reader: obey the AOD guard, else print the cached
        # field (U+2800 if the cache is missing/empty -- never empty, or we hit Sample Text).
        lockRead = pkgs.writeShellScript "lock-read" ''
          ${aodGuard}
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          v=$(cat "$HOME/.cache/hyprlock/$1" 2>/dev/null)
          [ -n "$v" ] && printf '%s' "$v" || printf '⠀'
        '';
        # RAW value producers (NO aodGuard): the cache updater runs these and writes their
        # output to ~/.cache/hyprlock/<field>. They must NOT self-hide -- the cache has to
        # hold the REAL value even during AOD so a wake shows it immediately; hiding is the
        # reader's (lockRead's) job.
        lockBattery = pkgs.writeShellScript "lock-battery" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          printf '%s%% · %s' "$(cat /sys/class/power_supply/BAT0/capacity)" "$(cat /sys/class/power_supply/BAT0/status)"
        '';
        lockMusicSong = pkgs.writeShellScript "lock-music-song" ''
          export PATH=${lib.makeBinPath [ pkgs.playerctl pkgs.coreutils pkgs.gnugrep ]}:$PATH
          if playerctl metadata title 2>/dev/null | grep -q .; then
            printf '%s - %s' "$(playerctl metadata artist 2>/dev/null)" "$(playerctl metadata title 2>/dev/null)"
          else
            printf 'No music playing'
          fi
        '';
        lockMusicPosition = pkgs.writeShellScript "lock-music-position" ''
          export PATH=${lib.makeBinPath [ pkgs.playerctl pkgs.gawk pkgs.coreutils ]}:$PATH
          # Only show the progress slider while something is ACTIVELY PLAYING. Checking for a
          # title alone wasn't enough -- a Paused/Stopped player (or no player) still carries
          # metadata, so the dead "0:00" lingered. status != Playing -> hide (U+2800). Volume
          # is a separate label and stays shown. (Cached; lockRead passes the U+2800 through.)
          [ "$(playerctl status 2>/dev/null)" = Playing ] || { printf '⠀'; exit 0; }
          p=$(playerctl position 2>/dev/null)
          l=$(playerctl metadata mpris:length 2>/dev/null)
          exec awk -v p="$p" -v l="$l" 'BEGIN{
            ls = l/1000000
            em = int(p/60); es = int(p)%60
            if (ls > 0) {
              n = 18; f = int((p/ls)*n); if (f>n) f=n
              bar = ""; for (i=0;i<n;i++) bar = bar (i<f ? "━" : (i==f ? "●" : "─"))
              printf "%d:%02d  %s  %d:%02d", em, es, bar, int(ls/60), int(ls)%60
            } else printf "%d:%02d", em, es
          }'
        '';
        lockMusicVolume = pkgs.writeShellScript "lock-music-volume" ''
          export PATH=${lib.makeBinPath [ pkgs.wireplumber pkgs.gawk ]}:$PATH
          # Nerd Font (DepartureMono NF) volume glyphs -- built with bash printf so
          # the private-use codepoints stay out of the source, and passed to awk as
          # vars (awk has no \u escape). No more lone emoji on the lock screen.
          vol=$(printf '\uf028')   # nf-fa-volume-up
          mut=$(printf '\uf026')   # nf-fa-volume-off (muted)
          line=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)
          [ -z "$line" ] && { printf '%s   ------------ --' "$vol"; exit 0; }
          printf '%s' "$line" | awk -v vol="$vol" -v mut="$mut" '{
            v = $2; muted = ($0 ~ /MUTED/)
            pct = int(v*100); n = 12; f = int(v*n); if (f>n) f=n
            bar = ""; for (i=0;i<n;i++) bar = bar (i<f ? "▓" : "░")
            if (muted) printf "%s   %s muted", mut, bar
            else printf "%s   %s %d%%", vol, bar, pct
          }'
        '';

        # Lock-screen weather: a compact linecast line, CACHED so the label reads
        # instantly and the network fetch runs in the background at most every
        # 30 min. The display script only cats the cache (and kicks off a detached
        # refresh when it's missing/stale) -- it never blocks the label on the
        # network. linecast lives in the user profile, not pkgs, so it resolves
        # off the inherited session PATH (kept as the tail of PATH here).
        lockWeatherFetch = pkgs.writeShellScript "lock-weather-fetch" ''
          export PATH=${lib.makeBinPath [ pkgs.jq pkgs.coreutils ]}:$PATH
          out=$(linecast weather --json --print 2>/dev/null \
            | jq -r '"\(.current.icon)  \(.current.temperature|round)°   \(.current.condition)    H\(.today.high|round)°  L\(.today.low|round)°"' 2>/dev/null)
          [ -n "$out" ] && printf '%s' "$out" > "$HOME/.cache/lock-weather"
        '';
        lockWeather = pkgs.writeShellScript "lock-weather" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.util-linux ]}:$PATH
          cache="$HOME/.cache/lock-weather"
          mkdir -p "$(dirname "$cache")"
          if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +30 2>/dev/null)" ]; then
            touch "$cache" 2>/dev/null            # reset the 30-min timer so a failed/slow fetch is not retried every poll
            setsid -f ${lockWeatherFetch} >/dev/null 2>&1 || true
          fi
          if [ -s "$cache" ]; then cat "$cache"; else printf '  …'; fi
        '';

        # Cache updater: write each RAW producer's output to ~/.cache/hyprlock/<field>,
        # ATOMICALLY (tmp + mv) so a reader (lockRead) never cats a half-written file.
        hyprlockCacheUpdate = pkgs.writeShellScript "hakuspace-hyprlock-cache-update" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          d="$HOME/.cache/hyprlock"
          mkdir -p "$d"
          w() { local f="$1"; shift; "$@" > "$d/.$f" 2>/dev/null && mv -f "$d/.$f" "$d/$f" 2>/dev/null; }
          w song     ${lockMusicSong}
          w position ${lockMusicPosition}
          w volume   ${lockMusicVolume}
          w battery  ${lockBattery}
          w weather  ${lockWeather}
        '';
        # The loop that keeps the cache warm -- installed to ~/.local/bin (below) and run by
        # the hakuspace-hyprlock-cache service (systemd.user.services). While hyprlock is up,
        # refresh every ~0.75s (the lit backlight already dwarfs this cost during AOD, so
        # keeping the cache fresh for an INSTANT wake is effectively free); while unlocked,
        # idle-check every 20s so playerctl/wpctl aren't spawned on the live desktop for
        # nothing. Installed-and-exec'd by path rather than referenced from the service
        # directly, because the service lives in the outer `let` and these in home.file's.
        hyprlockCacheLoop = pkgs.writeShellScript "hakuspace-hyprlock-cache-loop" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.procps ]}:$PATH
          while true; do
            if pgrep -x hyprlock >/dev/null 2>&1; then
              ${hyprlockCacheUpdate}
              sleep 0.75
            else
              sleep 20
            fi
          done
        '';

        # Right-hand column: battery on top, then the music cluster (song, the
        # transport row, position bar, volume bar). All halign=right, inset 120px
        # to mirror the left pill's margin; y+ is up. The battery/song keep the
        # theme font; the bar rows use plain font for even glyph spacing.
        hyprlockExtras = ''

          label {
              monitor =
              text = cmd[update:500] ${lockRead} weather
              color = rgba(255, 255, 255, 0.65)
              font_size = 15
              font_family = $font_family extraBold
              position = -120, -150
              halign = right
              valign = center
              zindex = 5
          }

          label {
              monitor =
              text = cmd[update:500] ${lockRead} battery
              color = rgba(255, 255, 255, 0.7)
              font_size = 16
              font_family = $font_family extraBold
              position = -120, 125
              halign = right
              valign = center
              zindex = 5
          }

          label {
              monitor =
              text = cmd[update:250] ${lockRead} song
              color = $accent_color
              font_size = 16
              font_family = $font_family extraBold
              position = -120, 55
              halign = right
              valign = center
              zindex = 5
          }

          label {
              monitor =
              text = cmd[update:250] ${lockRead} position
              color = rgba(255, 255, 255, 0.55)
              font_size = 13
              font_family = $font_family
              position = -120, -35
              halign = right
              valign = center
              zindex = 5
          }

          label {
              monitor =
              text = cmd[update:500] ${lockRead} volume
              color = rgba(255, 255, 255, 0.55)
              font_size = 14
              font_family = $font_family
              position = -120, -80
              halign = right
              valign = center
              zindex = 5
          }
        '';
        # Move the stock centred widgets (clock, date, input, backdrop pill) to
        # the LEFT while KEEPING halign=center, so each stays centred WITHIN the
        # pill instead of flush to its edge. Only the X shifts. -630 puts the
        # 420-wide pill's LEFT edge at 960-630-210 = 120px from the screen edge --
        # matching the battery/music RIGHT margin (halign=right, position=-120 ->
        # 120px from the right edge), so both sides are inset equally. Applied
        # only to the main lock (the one with `extra`); the tiny variant is stock.
        toLeft = builtins.replaceStrings [ "position = 0," ] [ "position = -630," ];
        hyprlockNoText =
          name: extra:
          let
            # Rewrites of the upstream file (replaceStrings is a no-op on a file
            # lacking the string, e.g. hyprlock_tiny.conf):
            #   1. Swap the cutesy password placeholder "<i> Use Me ;) </i>".
            #   2. BACKGROUND = the WALLPAPER, dimmed + blurred -- NOT `path = screenshot`.
            #      Upstream screenshots the live desktop, so the lock leaks whatever
            #      windows were open; point it instead at ${hyprlockBg}, a fixed PNG that
            #      mirrors the current awww wallpaper (regenerated on change, see
            #      hyprlockBgGen + its .path watcher). hyprlock then does its own blur
            #      (passes 2->3, size 8) + noise grain, and brightness 0.5 -> 0.45 DIMS it
            #      so the white widgets read clearly over it. `brightness` is the dim knob
            #      (lower = darker); on a blank first boot the PNG may not exist yet and
            #      hyprlock falls back to a plain dark bg (still no screenshot leak).
            base = builtins.replaceStrings
              [
                "<i> Use Me ;) </i>"
                "path = screenshot"
                "blur_passes = 2"
                "contrast = 1.2"
                "brightness = 0.5"
                "vibrancy_darkness = 0"
              ]
              [
                "<i>Enter password</i>"
                "path = ${hyprlockBg}"
                "blur_passes = 3\n    blur_size = 8"
                "contrast = 1.0"
                "brightness = 0.45"
                "vibrancy_darkness = 0\n    noise = 0.02"
              ]
              (stripLockLabels (builtins.readFile "${hyprlockSrcDir}/${name}"));
          in
          # writeText, NOT builtins.toFile: `extra` now interpolates script store
          # paths (the music widgets), and toFile forbids derivation references.
          # writeText builds locally (trivial) -- no remote builder needed.
          pkgs.writeText "${name}-notext"
            ((if extra == "" then base else toLeft base) + extra);

        # Idle dim via GAMMA, NOT the backlight. The old approach faded brightnessctl down
        # and saved/-restored the pre-dim level -- but a lid-close MID-FADE snapshotted the
        # in-between value (before_sleep re-ran `brightnessctl -s`) and left the hardware
        # brightness stuck somewhere between. Gamma-dimming the OUTPUT (hyprsunset -g) never
        # touches the backlight, so the user's brightness is ALWAYS exactly what they set --
        # nothing to snapshot, nothing to race, nothing to get stuck, and "brightness back to
        # what the user set" (at lock / on wake) is just resetting the gamma. A short-lived
        # hyprsunset DAEMON holds the ramp (wlroots reverts gamma when the gamma client exits,
        # verified), so gammaReset simply kills it to undim. Neutral temp 6500K; gammaLevel% =
        # the dim depth (hyprsunset gamma is a brightness scale, 100 = normal). Tune here.
        gammaLevel = 40;
        gammaDim = pkgs.writeShellScript "hakuspace-gamma-dim" ''
          export PATH=${lib.makeBinPath [ pkgs.hyprsunset pkgs.procps pkgs.brightnessctl pkgs.coreutils pkgs.util-linux ]}:$PATH
          pkill -x hyprsunset 2>/dev/null
          setsid -f hyprsunset -t 6500 -g ${toString gammaLevel} >/dev/null 2>&1
          # Keyboard backlight follows the screen: DIM (level 1). A SEPARATE LED device set to
          # an ABSOLUTE value, so it has none of the brightness-snapshot race the screen had.
          kbd=""; for l in /sys/class/leds/*kbd_backlight; do [ -e "$l" ] && kbd=''${l##*/} && break; done
          [ -n "$kbd" ] && brightnessctl -d "$kbd" set 1 >/dev/null 2>&1
          exit 0
        '';
        gammaReset = pkgs.writeShellScript "hakuspace-gamma-reset" ''
          export PATH=${lib.makeBinPath [ pkgs.procps pkgs.brightnessctl pkgs.coreutils ]}:$PATH
          pkill -x hyprsunset 2>/dev/null   # gamma client exits -> compositor reverts to full
          kbd=""; for l in /sys/class/leds/*kbd_backlight; do [ -e "$l" ] && kbd=''${l##*/} && break; done
          [ -n "$kbd" ] && brightnessctl -d "$kbd" set 100% >/dev/null 2>&1
          exit 0
        '';

        # Idle condition for the DIM + LOCK listeners: block them (exit 1 -> hypridle defers the
        # on-timeout + keeps retrying) when EITHER (1) a media player is PLAYING, so a video isn't
        # dimmed/locked mid-watch, or (2) the notification-centre nosleep toggle is ON. Both are read
        # DIRECTLY, the SAME way suspendGate reads them -- NOT via the stock idle_inhibit.sh these
        # used to defer to. That script is unreliable (its opening `hypridle -V` check misbehaves in
        # the daemon's PATH, and its pactl sink-input check never fires on this pipewire setup -- a
        # playing YouTube still dimmed), so after the AOD rework the nosleep toggle silently stopped
        # blocking dim/lock. playerctl is reliable (also catches the muted video the audio check
        # missed); nosleep is the SAME state file the toggle writes
        # (~/.local/state/haku_theme/idle_inhibit = 1), so the toggle now genuinely holds dim + lock
        # (and AOD with them -- AOD is gated on `pidof hyprlock`, which blocking the lock prevents).
        # Video vs audio isn't cleanly separable, so music also holds the screen -- accepted; lock
        # manually when needed.
        mediaIdleCond = pkgs.writeShellScript "hakuspace-media-idle-cond" ''
          export PATH=${lib.makeBinPath [ pkgs.playerctl pkgs.gnugrep pkgs.coreutils ]}:$PATH
          playerctl -a status 2>/dev/null | grep -q '^Playing$' && exit 1
          [ "$(cat "$HOME/.local/state/haku_theme/idle_inhibit" 2>/dev/null)" = 1 ] && exit 1
          exit 0
        '';

        /*
          Idle AOD stage -- the old "turn off display (DPMS)" listener, retargeted.
          A FAKE always-on-display (the panel is a backlit LCD, so this is a dim
          glanceable screen, not a real zero-power AOD): keep the panel ON and
          collapse the lock screen to just the clock + password -- every dynamic
          label self-hides on the AOD flag (see aodGuard).

          The listener is gated on `pidof hyprlock` with a SHORT (30s) timeout, so it
          is really "30s of idle AFTER the screen is LOCKED" -- which makes it a
          MANUAL-LOCK TIMER too: hit SUPER+Escape (features/hakuspace/compositor.nix)
          and 30s later it dims + minimises, instead of sitting bright until the full
          idle sequence would have reached it. For the AUTO path the 150s lock trips
          the same gate, so AOD follows the auto-lock within condition_retry (10s).
          When NOT locked the gate fails and nothing happens -- AOD only exists behind
          the lock.

          INFINITE AOD while the lid is open: AOD is the SAME on AC and battery --
          ALWAYS raise the flag + dim, never power the panel off, and never idle-suspend
          ((3) below deletes the suspend listener). It just holds the dim clock for as
          long as the lid stays open. Real sleep still happens on LID CLOSE (logind
          HandleLidSwitch) and at critical battery (UPower) -- both independent of
          hypridle -- so a dying cell is still parked cleanly. The dim is GAMMA (gammaDim),
          so AOD never touches the backlight; aodExit resets it (gammaReset). gammaDim is
          idempotent (kills+relaunches the single hyprsunset daemon), so "unlocked dim already
          ran" and "manual lock dims fresh" both land in the same dimmed state.
        */
        aodEnter = pkgs.writeShellScript "hakuspace-aod-enter" ''
          flag="''${XDG_RUNTIME_DIR:-/tmp}/haku-aod"
          : > "$flag"
          ${gammaDim}
        '';
        aodExit = pkgs.writeShellScript "hakuspace-aod-exit" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          flag="''${XDG_RUNTIME_DIR:-/tmp}/haku-aod"
          rm -f "$flag"
          "$HOME/.local/bin/dpms_handler.sh" on
          # Undim: gammaReset kills the hyprsunset daemon so the compositor reverts the gamma
          # ramp to full. The hardware backlight was never touched, so this restores EXACTLY
          # what the user set. The short sleep lets the panel come back on the battery DPMS path.
          sleep 0.3
          ${gammaReset}
        '';

        /*
          NOTE: currently UNUSED -- the idle-suspend listener was removed for infinite
          AOD (see (3) in hypridleFixed). Kept defined so re-enabling idle-suspend is a
          one-line change. The description below documents what it did / would do again.

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

          # (1) idle dim = GAMMA (gammaDim), NOT the backlight -- so the hardware brightness is
          # never touched and can't get snapshotted mid-fade/stuck (see gammaDim). on-resume
          # resets the gamma if the user comes back before the lock.
          substituteInPlace $out \
            --replace-fail 'on-timeout = brightnessctl -s set 10' \
              'on-timeout = ${gammaDim}'
          substituteInPlace $out \
            --replace-fail 'on-resume = brightnessctl -r' \
              'on-resume = ${gammaReset}'
          # (1b) RESET the gamma AT LOCK so the lock screen shows at the user's real brightness
          # ("back to what the user set"); the locked pipeline (AOD, 30s) re-dims after. The
          # lock listener's on-timeout is unique (suspend uses `systemctl suspend`).
          substituteInPlace $out \
            --replace-fail 'on-timeout = loginctl lock-session' \
              'on-timeout = ${gammaReset}; loginctl lock-session'

          # (2) save around the suspend the lid triggers, restore on wake.
          substituteInPlace $out \
            --replace-fail 'before_sleep_cmd = loginctl lock-session && ~/.local/bin/dpms_handler.sh off' \
              'before_sleep_cmd = brightnessctl -s && loginctl lock-session && ~/.local/bin/dpms_handler.sh off'
          substituteInPlace $out \
            --replace-fail 'after_sleep_cmd = ~/.local/bin/dpms_handler.sh on' \
              'after_sleep_cmd = ~/.local/bin/dpms_handler.sh on && brightnessctl -r'

          # (2b) AOD instead of DPMS-off, PLUS a manual-lock timer. Retarget the whole
          #      180s "Turn off display (DPMS)" listener in one anchored sed range:
          #        - timeout 180 -> 30 and condition idle_inhibit.sh -> `pidof hyprlock`,
          #          so it fires 30s of idle AFTER the screen is LOCKED -- by the 150s
          #          auto lock OR a manual SUPER+Escape. Off the lock the gate fails and
          #          nothing happens. (idle_inhibit is implied: no lock -> no hyprlock.)
          #        - condition_retry 60 -> 10 so AOD follows the auto lock within ~10s.
          #        - on-timeout/on-resume -> aodEnter/aodExit.
          #      A range (not substituteInPlace) because condition_cmd/condition_retry are
          #      shared line values across listeners; the `# Turn off display (DPMS)` ..
          #      `}` anchors confine the edits to this one listener. `&` in the on-resume
          #      pattern is literal in a sed LHS; `|` delimiter keeps the store paths clean.
          ${pkgs.gnused}/bin/sed -i \
            -e '/# Turn off display (DPMS)/,/^}/ {
                  s|timeout = 180|timeout = 30|
                  s|on-timeout = ~/.local/bin/dpms_handler.sh off|on-timeout = ${aodEnter}|
                  s|on-resume = ~/.local/bin/dpms_handler.sh on && sleep 0.5 && brightnessctl -r|on-resume = ${aodExit}|
                  s|condition_cmd = ~/.local/bin/idle_inhibit.sh|condition_cmd = pidof hyprlock|
                  s|condition_retry = 60|condition_retry = 10|
                }' \
            $out

          # (3) NO idle-suspend -- "infinite AOD while the lid is open". Delete the whole
          #     "Put machine to Sleep" listener (comment line .. its closing brace) so the
          #     machine never auto-sleeps from idle on AC OR battery; it just holds the dim
          #     AOD clock for as long as the lid is open. Real sleep still happens on LID
          #     CLOSE (logind HandleLidSwitch) and at critical battery (UPower) -- neither
          #     goes through hypridle -- so a dying cell is still parked cleanly. suspendGate
          #     is consequently unused; kept defined for an easy re-enable.
          ${pkgs.gnused}/bin/sed -i \
            -e '/# Put machine to Sleep/,/^}/d' \
            $out

          # (4) Block the DIM + LOCK while media is PLAYING (see mediaIdleCond -- playerctl,
          #     catches muted video the stock audio check misses). Runs LAST on purpose: by
          #     now the AOD listener's condition is already `pidof hyprlock` (2b) and the
          #     suspend block is deleted (3), so only the dim + lock conditions still read
          #     idle_inhibit.sh -- --replace-fail rewrites both remaining occurrences.
          substituteInPlace $out \
            --replace-fail 'condition_cmd = ~/.local/bin/idle_inhibit.sh' \
              'condition_cmd = ${mediaIdleCond}'
        '';
      in
      {
        ".config/hypr/hypridle.conf".source = hypridleFixed;
        ".config/hypr/hyprlock.conf".source = hyprlockNoText "hyprlock.conf" hyprlockExtras;
        ".config/hypr/hyprlock_tiny.conf".source = hyprlockNoText "hyprlock_tiny.conf" "";
        # The lock-screen value cache loop (see hyprlockCacheLoop). Installed to a stable
        # path so the hakuspace-hyprlock-cache service can exec it by `bin "..."` from the
        # outer `let` (it can't see this inner `let`'s store paths).
        ".local/bin/hyprlock-cache-loop".source = hyprlockCacheLoop;
      };
  };
}
