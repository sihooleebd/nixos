{ config, lib, ... }:

let
  cfg = config.my.sidedock;
in
{
  options.my.sidedock = {
    enable = lib.mkEnableOption
      "right-edge slide-out dock -- light apps park off-screen and cycle in one at a time (Hyprland only)";
    # Accounts this feature applies to; defaults to the primary user.
    users = import ../../lib/user-scope.nix { inherit lib config; };
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "sonora" ];
      example = [ "sonora" "org.kde.dolphin" ];
      description = ''
        Window classes (bare regex bodies, each wrapped as ^(<x>)$) that AUTO-open
        into the dock -- floated to the dock shape, parked off-screen, tagged
        'dock', without grabbing focus. Only list classes that should ALWAYS live in
        the dock; dual-use apps (a terminal, dolphin) are better pushed in on demand
        with SUPER+ALT+D, so their main-area windows are left alone.
      '';
    };
  };

  # No system-level config: the dock is entirely home-manager -- a script plus
  # Hyprland window-rules and binds contributed from features/sidedock/home.nix.
}
