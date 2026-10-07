{ lib, config, ... }:
{
  options.my.notifcenter = {
    enable = lib.mkEnableOption ''
      Quickshell notification centre: a SIZED keystone-able panel (the compositor keystone warps it
      into a dock-card trapezoid, via the "swaync-control-center" layer namespace) carrying wifi/BT/
      DND/nosleep/nightmode/battery-mode/power/volume/brightness/music/notifications. Replaces swaync
      once complete; STAGE 1 is a proof-of-concept panel that runs ALONGSIDE swaync for testing'';
    users = import ../../lib/user-scope.nix { inherit lib config; };
  };
}
