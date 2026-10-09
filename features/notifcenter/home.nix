{ config, lib, pkgs, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "notifcenter"; };
  mod = osConfig.my.hyprland.modKey;

  # SUPER+N toggle, mutually exclusive with the sidedock: park the dock, then toggle the centre
  # (both claim the right-edge slot + the keystone trapezoid). `sidedock` is the dock's PATH wrapper
  # (features/sidedock); guarded so a host without the dock just toggles. The reverse direction
  # (showing the dock hides this) lives in sidedock's dock.sh.
  notifToggle = pkgs.writeShellScript "haku-notifcenter-toggle" ''
    export PATH=${lib.makeBinPath [ pkgs.quickshell pkgs.coreutils ]}''${PATH:+:$PATH}
    # Plain toggle. Closing the dock/pins when the panel OPENS is handled by the panel itself
    # broadcasting `panelbus open notif` on open (shell.qml onPanelOpenChanged) -- a toggle can't
    # tell open from close, so the mutual-exclusion lives at the panel where open is unambiguous.
    exec quickshell -c haku-notif ipc call panel toggle
  '';

  # Weather for the panel. Reuses the system `linecast weather` tool (in the user profile, resolved off
  # the inherited PATH) and the SAME compact format + cache file the lock screen uses (features/hakuspace
  # lockWeatherFetch) -- so they stay consistent and share one 30-min fetch instead of hammering it.
  weatherCmd = pkgs.writeShellScript "haku-notif-weather" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils ]}:$PATH
    # Full `linecast weather --json` (current + today + 5-day daily + aqi), cached 30 min in its own
    # file; the panel parses it for a rich card. (The lock screen keeps its compact ~/.cache/lock-weather.)
    cache="$HOME/.cache/haku-notif-weather.json"
    mkdir -p "$(dirname "$cache")"
    if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +30 2>/dev/null)" ]; then
      touch "$cache" 2>/dev/null   # reset the timer so a slow/failed fetch is not retried every poll
      out=$(linecast weather --json --print 2>/dev/null)
      case "$out" in "{"*) printf '%s' "$out" > "$cache" ;; esac   # only overwrite on a valid JSON fetch
    fi
    [ -s "$cache" ] && cat "$cache"
  '';
in
lib.mkIf (osConfig.my.notifcenter.enable && inScope && osConfig.my.desktop.compositor == "hyprland") {
  home.packages = [ pkgs.quickshell ];

  # The quickshell config. `quickshell -c haku-notif` resolves to ~/.config/quickshell/haku-notif.
  xdg.configFile."quickshell/haku-notif/shell.qml".source = ./shell.qml;

  # panelbus close handler (features/panelbus): how this centre gets closed when the dock or a pin
  # opens. Guarded by its daemon being live AND run time-capped by panelbus, so an absent target is a
  # fast no-op (the swaync branch here is the fallback when my.notifcenter is off and swaync is live).
  xdg.configFile."panelbus/handlers/notif".text = ''
    ${pkgs.procps}/bin/pgrep -f 'quickshell -c haku-notif' >/dev/null 2>&1 && ${pkgs.quickshell}/bin/quickshell -c haku-notif ipc call panel hide 2>/dev/null
    ${pkgs.procps}/bin/pgrep -x swaync >/dev/null 2>&1 && ${pkgs.swaynotificationcenter}/bin/swaync-client -cp 2>/dev/null
    true
  '';

  # Run it as a user service (needs the Wayland session). STAGE 1's shell.qml has NO notification
  # daemon, so it coexists with swaync; when it grows a NotificationServer, swaync gets disabled.
  systemd.user.services.haku-notif = {
    Unit = {
      Description = "Haku notification centre (quickshell)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      # quickshell reads shell.qml once at startup, and only the UNIT changing makes home-manager
      # restart a service -- so a shell.qml-only edit (frost, the setsid run(), a widget) would keep
      # running the OLD UI until a manual restart. Tie a restart to the file's content so a rebuild
      # reloads it automatically.
      X-Restart-Triggers = [ "${./shell.qml}" ];
      # Survive the greetd-restart startup race (quickshell aborting before Wayland is ready) instead
      # of hitting the start-limit and staying down -- retry indefinitely, spaced by RestartSec.
      StartLimitIntervalSec = 0;
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      # Wrap to prepend bins to PATH (the service doesn't inherit a rich login PATH):
      #  - hyprsunset: the Night tile's nightlight_toggle.sh calls a bare `hyprsunset`.
      #  - util-linux (setsid): run() detaches every action via `setsid -f` so backgrounded daemons
      #    survive quickshell's process-group teardown -- see the run() comment in shell.qml.
      #  - panelbus: the panel broadcasts `panelbus open notif` on open (mutual exclusion with the dock).
      #  - libnotify (notify-send) + pipewire (pw-play): the timer/pomodoro end-alert is a toast PLUS a
      #    short chime (HAKU_ALERT_SOUND), and must fire even when the panel is closed (the countdown
      #    keeps running regardless).
      ExecStart = pkgs.writeShellScript "haku-notif-start" ''
        export PATH=${lib.makeBinPath [ pkgs.hyprsunset pkgs.util-linux pkgs.libnotify pkgs.pipewire osConfig.my.panelbus.package ]}''${PATH:+:$PATH}
        export HAKU_ALERT_SOUND=${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/complete.oga
        export HAKU_WEATHER_CMD=${weatherCmd}
        exec ${pkgs.quickshell}/bin/quickshell -c haku-notif
      '';
      Restart = "on-failure";
      RestartSec = 2;   # space out the startup-race retries so the compositor has time to come up
      Slice = "session.slice";
    };
  };

  # SUPER+N opens the notif centre (hakuspace's swaync bind is gated off when this feature is on).
  # extraConfig is types.lines -> concatenated into the one generated hyprland.lua.
  wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
    hl.bind("${mod} + N", hl.dsp.exec_cmd("${notifToggle}"))
    -- Frosted glass for the notif centre AND its toast popups (the keystone warps the panel's blur
    -- pass along with it). Neither namespace is covered by hakuspace's swaync layer_rule, so declare
    -- them here. The panel bg is semi-transparent (bgPanel) so this blur reads as frost.
    hl.layer_rule({ match = { namespace = "^(haku-notifcenter|haku-notif-popup)$" }, blur = true, ignore_alpha = 0.05 })
  '';
}
