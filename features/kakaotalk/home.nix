{ config, lib, pkgs, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "kakaotalk"; };
in
lib.mkIf (osConfig.my.kakaotalk.enable && inScope) {
  /*
    XEmbed -> StatusNotifier tray bridge. Wine (KakaoTalk) only speaks the legacy
    X11 XEmbed system tray, which Hyprland doesn't host -- so Wine draws its own
    floating tray window (the "pill"). xembedsniproxy claims the XEmbed tray
    selection (Wine hands it the icon, no pill) and re-exposes each icon as an SNI
    item REGISTERED WITH the existing StatusNotifier watcher (waybar's) -- it does
    NOT seize org.kde.StatusNotifierWatcher, so it coexists with the bar's tray.
    (snixembed goes the reverse direction and clobbers the tray -- don't use it.)

    Lives here, gated on my.kakaotalk.enable, rather than in the shell feature,
    because it only ships inside kdePackages.plasma-workspace -- a 3GB closure
    that has no business landing on hosts without a Wine tray app. The daemon
    itself is tiny (~30MB RSS). Its 32x32 XEmbed host window is hidden by a
    window rule in features/hyprland (class ^(xembedsniproxy)$).
  */
  systemd.user.services.kakaotalk-tray-bridge = {
    Unit = {
      Description = "KakaoTalk XEmbed->SNI tray bridge (xembedsniproxy)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = "${pkgs.kdePackages.plasma-workspace}/bin/xembedsniproxy";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
