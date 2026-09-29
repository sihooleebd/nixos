{ config, lib, pkgs, ... }:

{
  /*
    EXTENSION POINTS, so that features/hyprland can be about Hyprland.

    It used to hard-code DankMaterialShell: the transform shim called DMS's
    bar-swap script by store path, and roughly fifteen keybinds ran `dms ipc`.
    A host running Hyprland with no shell got a config full of binds that
    spawned nothing, and swapping shells meant editing the compositor.

    The dependency now points the other way. Anything wanting compositor
    configuration contributes it -- keybinds and rules through home-manager's
    own merging (wayland.windowManager.hyprland.extraConfig is types.lines, and
    settings is a freeform attrsOf, so definitions from any number of modules
    concatenate into the one generated hyprland.lua) and rotation behaviour
    through the option below, which is the one case merging cannot express
    because the value is consumed by a shell script rather than by the config.
  */
  options.my.hyprland = {
    modKey = lib.mkOption {
      type = lib.types.str;
      default = "SUPER";
      description = ''
        The modifier every keybind is expressed against.

        An option rather than the `local mod = "SUPER"` this used to be. That
        local still exists in the generated Lua, and a fragment appended by
        another feature can technically see it -- one file, one chunk, locals
        visible to everything below them. But that is a contract enforced by
        nothing except concatenation order: reorder the fragments and every
        contributed bind silently binds against nil. Interpolating one Nix
        value into both places makes the agreement explicit and order-proof.
      '';
    };

    rotationHooks = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression "[ (pkgs.writeShellScript \"swap-bar\" \"...\") ]";
      description = ''
        Executables run on every screen rotation, each with the new transform
        (0-7) as its only argument.

        WHY AN OPTION AND NOT A KEYBIND. Rotation is not a keypress -- it
        arrives from iio-hyprland as a batch of legacy `hyprctl keyword`
        commands, which the shim in this feature's home half intercepts and
        rewrites. Anything that must react has to be called from inside that
        shim, so the shim needs a list it can iterate instead of a store path
        compiled into it.

        RUN BEFORE the real hyprctl call, and deliberately: the shim `exec`s
        into hyprctl, so a hook placed after it would never run at all. Hooks
        are also best-effort -- a failure is swallowed -- because a shell that
        is not up yet must not turn a rotation into a broken screen.

        Ordering between hooks is list order. Nothing here should depend on
        another hook having run.
      '';
    };

    keystone.enable = lib.mkEnableOption ''
      EXPERIMENTAL per-window perspective-trapezoid rendering for dock-tagged
      windows (my.sidedock). Patches the compositor (features/hyprland/trapezoid.patch):
      the tex vertex shaders honour a projective w, and renderTextureInternal
      post-multiplies a yaw homography into the projection for windows tagged
      "dock". Every other window renders exactly as before. Rebuilds Hyprland from
      source -- test the built binary NESTED before switching the real session'';
  };

  config = lib.mkIf (config.my.desktop.compositor == "hyprland") {
    programs.hyprland = {
      enable = true;
      # DMS greeter launches hyprland.desktop via uwsm regardless of this flag's
      # own default. Without withUWSM, programs.uwsm.enable never fires, so the
      # systemd user units uwsm needs (wayland-session-bindpid@.service etc.)
      # are missing -> "systemctl --user start ... exit status 5" crash loop.
      withUWSM = true;
    };

    # The keystone patch, applied to the exact fork Hyprland this config uses.
    programs.hyprland.package = lib.mkIf config.my.hyprland.keystone.enable
      (pkgs.hyprland.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./trapezoid.patch ];
      }));
  };
}
