{ config, lib, ... }:

let
  cfg = config.my.hakuspace;
in
{
  options.my.hakuspace = {
    enable = lib.mkEnableOption ''
      Haku Space: a Waybar/Rofi/SwayNC desktop with wallpaper automation,
      accent-colour theming and a dockbar. The alternative to my.dms.enable --
      the two are mutually exclusive, see the `shell` role in features/_meta
    '';

    configNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "waybar" "rofi" "swaync" "cava" "fastfetch" "gtk.css" "xdg-desktop-portal" ];
      description = ''
        Which of hakuspace's ~/.config entries to manage.

        NARROWED FROM UPSTREAM'S FULL SET on purpose. It also ships fish,
        kitty, starship.toml and hypr configs, and every one of those is
        already owned by a feature here -- features/fish, features/kitty,
        features/starship, features/hyprland. Two modules writing the same
        path is a home-manager collision, reported as an error rather than
        resolved by picking a winner, so the shell takes only what nothing
        else claims.

        `hypr` is the sharpest of those: hakuspace ships a COMPLETE Hyprland
        config, and features/hyprland owns that file. Its keybinds are
        contributed through ./compositor.nix instead, which is the same seam
        features/dms uses.
      '';
    };
  };

  # Accounts this feature applies to; defaults to the primary user.
  options.my.hakuspace.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = {
    my.internal.features.hakuspace = {
      # Reads my.desktop.compositor to decide which binds to contribute; with
      # no compositor selected there is nothing to attach to.
      requires = [ "compositor" ];
      # Mutually exclusive with features/dms. Two shells would both draw a bar,
      # both bind Super+R, and both claim the notification daemon.
      provides = [ "shell" ];
      enabledBy = cfg.enable;
    };

    # hyprlock (the lock screen, via lock.sh in home.nix) authenticates against the
    # PAM service "hyprlock". With no such service defined, hyprlock's OWN fallback is
    # /etc/pam.d/su -- which drags in pam_faillock (failure lockout + delays on auth)
    # and, worse, pam_xauth in the SESSION stack (spawns the `xauth` binary on every
    # successful unlock -- slow, and pointless on Wayland). That is the "hangs/lags
    # before admitting" on a correct password. A dedicated minimal service gives the
    # clean default pam_unix stack (no su baggage, no xauth, no faillock), so unlock is
    # fast. This is the standard NixOS hyprlock fix. Gated with the shell.
    security.pam.services.hyprlock = lib.mkIf cfg.enable { };
  };
}
