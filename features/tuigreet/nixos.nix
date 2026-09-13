{ config, lib, pkgs, ... }:

let
  cfg = config.my.tuigreet;
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

    (lib.mkIf cfg.enable (
      let
        # Launch Hyprland through a wrapper that sends its startup output to a
        # log file instead of the greeter TTY. greetd runs on tty1 and the
        # session inherits it, so Hyprland's stdout banner (its ASCII logo +
        # build info) flashes on screen at login, before the compositor grabs
        # KMS -- the "console text with the Hyprland logo". Redirecting
        # stdout+stderr gives a clean hand-off from greeter to desktop; Hyprland
        # still keeps its own full log under ~/.local/share/hyprland, and `>`
        # truncates this one each login so it never grows.
        hyprQuiet = pkgs.writeShellScript "start-hyprland-quiet" ''
          exec ${config.programs.hyprland.package}/bin/start-hyprland \
            >"''${XDG_CACHE_HOME:-$HOME/.cache}/hyprland-greetd.log" 2>&1
        '';
        # Offer exactly that session. NixOS has no /usr/share/wayland-sessions
        # for tuigreet to scan; upstream points --sessions at the displayManager
        # aggregate (hyprland.desktop from programs.hyprland in
        # features/hyprland), but that .desktop runs start-hyprland directly --
        # hence the banner. Keeping Name=Hyprland and the hyprland.desktop
        # filename means --remember-user-session still matches.
        quietSessions = pkgs.writeTextDir "share/wayland-sessions/hyprland.desktop" ''
          [Desktop Entry]
          Name=Hyprland
          Comment=Hyprland
          Type=Application
          DesktopNames=Hyprland
          Exec=${hyprQuiet}
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
