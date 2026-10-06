{ config, lib, pkgs, ... }:

let
  cfg = config.my.tuigreet;
  compositor = config.my.desktop.compositor;

  # Per-compositor session: display Name, the .desktop FILENAME (kept matching the compositor's own
  # aggregate so tuigreet's --remember-user-session still matches), and the launch binary. tuigreet
  # is compositor-agnostic -- it just needs to know which one to offer -- so this derives everything
  # from my.desktop.compositor instead of assuming Hyprland. null when no compositor is selected,
  # which the assertion below rejects.
  session =
    if compositor == "hyprland" then
      {
        name = "Hyprland";
        file = "hyprland.desktop";
        bin = "${config.programs.hyprland.package}/bin/start-hyprland";
      }
    else if compositor == "niri" then
      {
        name = "niri";
        file = "niri.desktop";
        bin = "${config.programs.niri.package}/bin/niri-session";
      }
    else
      null;
in
{
  options.my.tuigreet.enable = lib.mkEnableOption "tuigreet, the terminal login greeter, as greetd's session";

  config = lib.mkMerge [
    {
      my.internal.features.tuigreet = {
        # A greetd session, the same relationship dms.greeter declares:
        # without greetd it is installed and never launched.
        requires = [ "greetd" ];
        enabledBy = cfg.enable;
      };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = session != null;
          message = "my.tuigreet.enable needs my.desktop.compositor set (hyprland or niri) -- tuigreet has to know which session to offer.";
        }
      ];
    })

    (lib.mkIf (cfg.enable && session != null) (
      let
        # Launch the compositor through a wrapper that sends its startup output to a log file instead
        # of the greeter TTY. greetd runs on tty1 and the session inherits it, so the compositor's
        # stdout banner (Hyprland's ASCII logo + build info, say) flashes on screen at login before it
        # grabs KMS. Redirecting stdout+stderr gives a clean hand-off; the compositor still keeps its
        # own full log, and `>` truncates this one each login so it never grows.
        quietLaunch = pkgs.writeShellScript "start-${compositor}-quiet" ''
          exec ${session.bin} \
            >"''${XDG_CACHE_HOME:-$HOME/.cache}/${compositor}-greetd.log" 2>&1
        '';
        # Offer exactly that session. NixOS has no /usr/share/wayland-sessions for tuigreet to scan;
        # upstream points --sessions at the displayManager aggregate, but that .desktop runs the
        # compositor directly -- hence the banner. Keeping the compositor's own Name + .desktop
        # filename means --remember-user-session still matches.
        quietSessions = pkgs.writeTextDir "share/wayland-sessions/${session.file}" ''
          [Desktop Entry]
          Name=${session.name}
          Comment=${session.name}
          Type=Application
          DesktopNames=${session.name}
          Exec=${quietLaunch}
        '';
      in
      {
        /*
          Mutually exclusive with dms.greeter by construction rather than by
          assertion: both define greetd's default_session.command, and enabling
          the two at once fails evaluation with a conflicting-definitions
          error naming both files.
        */
        services.greetd.settings.default_session.command = lib.concatStringsSep " " [
          "${pkgs.tuigreet}/bin/tuigreet"
          "--time"
          # Prefill the last user, and reopen each user's last-used session --
          # so the daily path is: type password, Enter.
          "--remember"
          "--remember-user-session"
          "--asterisks"
          "--sessions ${quietSessions}/share/wayland-sessions"
        ];

        # --remember persists into /var/cache/tuigreet, which nothing creates
        # for the unprivileged greeter user greetd runs the session as.
        systemd.tmpfiles.rules = [
          "d /var/cache/tuigreet 0755 greeter greeter - -"
        ];
      }
    ))
  ];
}
