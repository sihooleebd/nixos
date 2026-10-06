{ config, lib, ... }:

let
  cfg = config.my.keyd;

  # Per-layout keyd main-section remaps. keyd rewrites at the evdev/uinput layer, so whichever is
  # chosen applies EVERYWHERE -- TTY, greetd, the compositor, Emacs -- not per-session.
  layouts = {
    # HHKB-style: Caps = tap Escape / hold Control; physical Escape = Caps Lock; Right Alt = Hangul,
    # so apps never receive an Alt-modifier from RAlt -- fcitx5 binds IME switching to the Hangul key
    # instead (see the fcitx feature's home half). Verify names with `sudo keyd monitor`; list codes
    # with `sudo keyd list-keys | rg hangeul`.
    hhkb = {
      capslock = "overload(control, esc)";
      esc = "capslock";
      rightalt = "hangeul";
    };
    # Caps alone emits Hangul, nothing else. PLAIN remap, NOT timeout(hangeul, 200, capslock): a
    # tap-hold macro makes keyd hold events for up to 200ms to disambiguate tap vs hold, which lags
    # every Caps press. The plain remap fires instantly and never buffers; the hold-for-real-capslock
    # is dropped, which is fine -- this key is never used for Caps Lock here.
    capsHangul = {
      capslock = "hangeul";
    };
  };
in
{
  options.my.keyd = {
    enable = lib.mkEnableOption ''
      key remapping via keyd. Applies everywhere -- TTY, greetd, the compositor, Emacs -- because it
      rewrites at the evdev/uinput layer rather than per-session. Pick the remap with my.keyd.layout
    '';

    layout = lib.mkOption {
      type = lib.types.enum (lib.attrNames layouts);
      default = "hhkb";
      description = ''
        Which keyd remap to apply:
          "hhkb"       - Caps = tap Esc / hold Ctrl, Esc = Caps Lock, Right Alt = Hangul (HHKB feel).
          "capsHangul" - Caps emits Hangul (plain, instant remap), nothing else.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.keyd = {
      enable = true;
      keyboards.default = {
        ids = [ "*" ];
        settings.main = layouts.${cfg.layout};
      };
    };
  };
}
