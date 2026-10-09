{ config, lib, osConfig, pkgs, ... }:

/*
  Haku Space's half of the compositor configuration -- the same seam
  features/dms/compositor.nix uses, and for the same reason: the compositor
  feature must not know which shell is running.

  These are the SHELL binds from upstream's src/wm/hyprland/config/keybinding.lua
  only. Its window-management, focus, workspace and mouse binds are not
  reproduced: features/hyprland already binds all of them, and that file is not
  installed here.

  mkAfter for the ordering reason documented at the top of
  features/dms/compositor.nix -- `hakuspace` sorts before `hyprland` in the
  alphabetical feature glob, so without it this lands above `local mod`.
*/

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "hakuspace"; };
  cfg = osConfig.my.hakuspace;
  enabled = cfg.enable && inScope;

  compositor = osConfig.my.desktop.compositor;
  mod = osConfig.my.hyprland.modKey;
  bin = name: "${config.home.homeDirectory}/.local/bin/${name}";

  /*
    STORE PATHS for the binds that exec a bare binary. Every other bind here
    runs a wrapped ~/.local/bin script, which carries rofi and friends on its
    own PATH -- but a bind that names the binary directly execs in Hyprland's
    spawn environment, where rofi and swaync-client are installed by nothing
    (the hakuspace package wraps them into its scripts and exposes neither).
    That is why hakumenu (a script) always worked while the launcher (bare
    `rofi`) never did.

    With the emoji plugin, because the emoji bind needs it and upstream's
    install.sh puts rofi-emoji on the system; plain pkgs.rofi would make that
    bind silently show an empty mode list.
  */
  rofi = pkgs.rofi.override { plugins = [ pkgs.rofi-emoji ]; };

  # SUPER+N notification-centre toggle, made MUTUALLY EXCLUSIVE with the sidedock: opening the panel
  # parks the dock first, because both claim the right-edge slot and the keystone trapezoid shape
  # (the compositor keystones the "swaync-control-center" layer so the panel IS a dock-card shape --
  # see features/hyprland/trapezoid.patch; geometry matched in features/hakuspace home.nix). `sidedock`
  # is the dock's PATH wrapper (features/sidedock); the guard makes this a plain toggle on a host with
  # no dock. The reverse direction (showing the dock closes the panel) is in sidedock's dock.sh.
  notifToggle = pkgs.writeShellScript "haku-notif-toggle" ''
    export PATH=${lib.makeBinPath [ pkgs.swaynotificationcenter pkgs.coreutils ]}''${PATH:+:$PATH}
    command -v sidedock >/dev/null 2>&1 && sidedock hide >/dev/null 2>&1 || true
    exec swaync-client -t -sw
  '';

  # Toggle a rofi surface: a second press closes it instead of erroring "Rofi
  # already running". Both the drun launcher (SUPER+Space) and hakumenu
  # (SUPER+Tab, itself `rofi -show` with custom modes) are rofi, so one check
  # serves both -- pass the launch command as arguments. pgrep/pkill cover both
  # the bare `rofi` comm and the `.rofi-wrapped` name the plugin override may
  # produce.
  rofiToggle = pkgs.writeShellScript "rofi-toggle" ''
    if ${pkgs.procps}/bin/pgrep -x rofi >/dev/null 2>&1 \
      || ${pkgs.procps}/bin/pgrep -x .rofi-wrapped >/dev/null 2>&1; then
      ${pkgs.procps}/bin/pkill -x rofi 2>/dev/null || true
      ${pkgs.procps}/bin/pkill -x .rofi-wrapped 2>/dev/null || true
    else
      exec "$@"
    fi
  '';

  # Panic gesture (SUPER+SHIFT+Escape): lock the screen INSTANTLY, then SIGKILL
  # every app window behind the lock. Lock first (setsid -f so it outlives this
  # script) so the screen is covered before anything else happens; then kill --
  # panic means the windows go NOW, no graceful close / save prompts. hyprlock
  # and waybar are layer surfaces, not clients, so `hyprctl clients` never lists
  # them and they survive. PIDs 0/-1 (xwayland-internal) are filtered out.
  panic = pkgs.writeShellScript "panic-mode" ''
    ${pkgs.util-linux}/bin/setsid -f ${bin "lock.sh"} >/dev/null 2>&1 || true
    pids=$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[].pid' | ${pkgs.gnugrep}/bin/grep -vxE '0|-1')
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  '';
in
{
  config = lib.mkIf (enabled && compositor == "hyprland") {
    wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
      -- Launcher, menus and the notification centre.
      --
      -- SPACE, not upstream's R: Hyprland fires EVERY bind registered on a
      -- combo, and features/hyprland already has mod+R (colresize +conf, the
      -- niri-style column width cycle) -- upstream's key would resize the
      -- column AND open the launcher on one press. Same collision class as
      -- the W / SHIFT+P moves documented below, but these three were only
      -- caught live: registration order reports nothing.
      hl.bind("${mod} + space", hl.dsp.exec_cmd("${rofiToggle} ${rofi}/bin/rofi -show drun"))
      hl.bind("${mod} + slash", hl.dsp.exec_cmd("${rofi}/bin/rofi -modi emoji -show emoji"))
      hl.bind("${mod} + Tab", hl.dsp.exec_cmd("${rofiToggle} ${bin "hakumenu.sh"}"))
      ${lib.optionalString (!osConfig.my.notifcenter.enable) ''hl.bind("${mod} + N", hl.dsp.exec_cmd("${notifToggle}"))''}
      hl.bind("${mod} + V", hl.dsp.exec_cmd("${bin "clipboard_menu.sh"}"))
      hl.bind("${mod} + SHIFT + V", hl.dsp.exec_cmd("${bin "clipboard_menu.sh"} --wipe"))

      -- Session. ESCAPE, not upstream's K (mod+K is focus workspace -1 --
      -- locking the screen while switching workspaces); SHIFT+L, not
      -- upstream's L (mod+L is focus right).
      hl.bind("${mod} + Escape", hl.dsp.exec_cmd("${bin "lock.sh"}"), { locked = true })
      -- Panic: kill every window + lock, one gesture. Sits next to the lock bind
      -- on purpose (SUPER+Escape locks, SUPER+SHIFT+Escape nukes + locks).
      hl.bind("${mod} + SHIFT + Escape", hl.dsp.exec_cmd("${panic}"))
      hl.bind("${mod} + SHIFT + L", hl.dsp.exec_cmd("${bin "nightlight_toggle.sh"}"))

      -- Appearance: wallpaper, the cava underbar, and the bar layout cycle.
      hl.bind("${mod} + Y", hl.dsp.exec_cmd("${bin "wallpaper_select.sh"}"))
      hl.bind("${mod} + SHIFT + Y", hl.dsp.exec_cmd("${bin "wallpaper_video_select.sh"}"))
      -- Cava's keybind was mod+T, now reassigned to the terminal (launch
      -- scheme in features/hyprland). Cava stays toggleable from the hakumenu
      -- (SUPER+TAB -> Theme -> Cava Underbar); moved to mod+SHIFT+C for a key.
      hl.bind("${mod} + SHIFT + C", hl.dsp.exec_cmd("${bin "cava_manager.sh"}"))
      hl.bind("${mod} + SHIFT + W", hl.dsp.exec_cmd("${bin "waybar_manager.sh"} --cycle"))

      -- Capture.
      hl.bind("${mod} + F11", hl.dsp.exec_cmd("${bin "record.sh"}"))

      -- TWO BINDS MOVED OFF UPSTREAM'S DEFAULTS, because features/hyprland
      -- already owns those keys and a duplicate bind in Hyprland is decided by
      -- registration order rather than reported:
      --
      --   SUPER + W          upstream: dockbar toggle
      --                      here:     firefox (features/hyprland app spawns)
      --                      moved to: SUPER + SHIFT + B
      --
      --   SUPER + SHIFT + P  upstream: fullscreen screenshot
      --                      here:     dpms off (features/hyprland)
      --                      moved to: SUPER + CTRL + P
      --
      -- SUPER + P itself is free -- features/hyprland deliberately leaves it
      -- for the shell layer -- so the plain screenshot keeps its upstream key.
      --
      -- LUA COMMENTS, NOT NIX ONES. This block is inside a Lua string; a
      -- /* */ comment here reaches Hyprland verbatim and the config dies with
      -- "unexpected symbol near '/'" at session start. Caught by parsing the
      -- generated file rather than by evaluation, which cannot see inside a
      -- string literal.
      hl.bind("${mod} + P", hl.dsp.exec_cmd("${bin "screenshot.sh"}"))
      hl.bind("${mod} + CTRL + P", hl.dsp.exec_cmd("${bin "screenshot.sh"} --fullscreen"))
      hl.bind("${mod} + SHIFT + B", hl.dsp.exec_cmd("${bin "dockbar_manager.sh"} --toggle"))

      -- Glassmorphism for the bar and the launcher, matching what
      -- features/hyprland enables compositor-side. A layer surface has to opt
      -- into blur; only windows get it automatically.
      hl.layer_rule({ match = { namespace = "^(waybar)$" }, blur = true, ignore_alpha = 0.05 })
      -- rofi is launched fullscreen + transparent (the haku-fullscreen-blur
      -- override appended to config.rasi in home.nix), so its layer spans the
      -- whole screen and this blur frosts the entire desktop behind the menu --
      -- a real blur, not a dim. NO ignore_alpha here: the backdrop is fully
      -- transparent, and ignore_alpha would EXCLUDE transparent pixels from the
      -- blur, leaving the desktop sharp. The centered box (mainbox) stays opaque.
      -- animation = "fade": without an explicit layer animation, this fullscreen
      -- layer inherits the global "layers" curve (a SLIDE), so on open the whole
      -- transparent-blur layer slides up from the bottom edge and the centered box
      -- rises with it -- it reads as "the menu blinks small/low then snaps to the
      -- middle" (the pseudo-hidpi blink). A fade appears at the final size + centre
      -- with only opacity ramping: no slide, no scale, no blink.
      hl.layer_rule({ match = { namespace = "^(rofi)$" }, blur = true, animation = "fade" })
      hl.layer_rule({ match = { namespace = "^(swaync.*)$" }, blur = true, ignore_alpha = 0.05 })
    '';
  };
}
