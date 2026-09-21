{
  pkgs,
  lib,
  osConfig,
  ...
}:

let
  # hyprlang (Hyprland's config parser) uses bare $ for its own variable
  # substitution and chokes on embedded shell $(...) / $var syntax in exec
  # strings ("<name> expected near '$'"). Keep the shell logic in a real
  # script file instead of inlining it into hyprland.conf.
  hangulToggle = pkgs.writeShellScript "hangul-toggle" ''
    im=$(fcitx5-remote -n)
    if [ "$im" = hangul ]; then
      fcitx5-remote -s keyboard-us
      fcitx5-remote -c
    else
      fcitx5-remote -s hangul
      fcitx5-remote -o
    fi
  '';

  # On-screen keyboard toggle (wvkbd): show it if hidden, hide it if shown.
  # wvkbd speaks the zwp_virtual_keyboard protocol, so it types into ANY
  # Wayland/XWayland app -- unlike an X11 OSK (onboard), which can only reach
  # XWayland windows. It's a layer-shell overlay anchored to the bottom edge
  # (floats above windows); no Wayland OSK is a real draggable window and still
  # types into native apps, so this is the practical "floating keyboard". -x
  # matches the exact process name so the toggle never signals itself. -L is the
  # landscape height in px; ~30% of a 1080p panel gives finger/pen-sized keys.
  wvkbdToggle = pkgs.writeShellScript "wvkbd-toggle" ''
    export PATH=${lib.makeBinPath [ pkgs.wvkbd pkgs.procps pkgs.util-linux ]}:$PATH
    if pgrep -x wvkbd-mobintl >/dev/null; then
      pkill -x wvkbd-mobintl
    else
      # setsid -f: detach into its own session so it survives the launcher
      # (waybar on-click / Hyprland exec) reaping this script's process group.
      # A bare `&` gets killed with the parent group -- the "keyboard won't open".
      setsid -f wvkbd-mobintl -L 320
    fi
  '';

  /*
    Run every my.hyprland.rotationHooks entry with the new transform.

    A generated script rather than a loop inlined twice: the shim reaches the
    real hyprctl through `exec`, which replaces the process, so hooks have to
    run BEFORE it at both exit paths and there is no "after" to put them in.
    One script means the two call sites cannot drift.

    Best-effort per hook -- a shell that has not started yet, or has no bar to
    swap, must not turn a physical rotation into a screen that never rotates.
  */
  runRotationHooks = pkgs.writeShellScript "hypr-rotation-hooks" (
    ''
      xform="''${1:-0}"
    ''
    + lib.concatMapStrings (h: ''
      ${h} "$xform" >/dev/null 2>&1 || true
    '') osConfig.my.hyprland.rotationHooks
  );

  /*
    iio-hyprland speaks legacy hyprctl -- a four-command keyword batch per
    rotation (monitor transform, touchdevice transform, tablet transform,
    workspace orientation). Under configType = "lua" the keyword parser is
    gone entirely, so this shim (PATH-shadowed for iio-hyprland only,
    below) translates the whole batch into one `hyprctl eval` of the
    equivalent hl.* calls. History worth keeping: the shim originally
    existed for a different bug -- keyword-era Hyprland applied a bare
    "monitor X,transform,N" without recomputing the swapped w/h box, so the
    shim restated the full rule from live monitor state. hl.monitor's
    merge-with-existing-rule application makes that original problem moot.
  */
  hyprctlTransformShim = pkgs.writeShellScriptBin "hyprctl" ''
    real=${pkgs.hyprland}/bin/hyprctl
    if [ "$1" = "--batch" ] && [[ "$2" == *"keyword monitor "*",transform,"* ]]; then
      if [[ "$2" =~ keyword\ monitor\ ([^,]+),transform,([0-9]+) ]]; then
        mon="''${BASH_REMATCH[1]}"
        xform="''${BASH_REMATCH[2]}"
        if [ "$xform" = "0" ]; then
          # Returning to transform 0 is its own separate bug: even a full
          # monitor rule leaves layer-shell clients stuck at the rotated
          # geometry here, though hyprctl monitors correctly reports
          # transform:0 -- verified live. `reload` reliably forces the
          # resync; under the Lua config it also re-runs the whole script,
          # which resets input:touchdevice/tablet transforms to their
          # config defaults (0) and clears the workspace orientation rule
          # -- exactly the landscape state wanted, and the same net effect
          # the pre-Lua reload had.
          # Back to landscape. Hooks BEFORE exec -- exec replaces this
          # process, so anything after it never runs.
          ${runRotationHooks} "$xform"
          exec "$real" reload
        fi
        # configType = "lua" killed `hyprctl keyword` outright ("keyword
        # can't work with non-legacy parsers. Use eval."), so every part of
        # iio-hyprland's batch must be translated, not just patched. The
        # batch is FOUR commands (main.c, system_fmt):
        #   keyword monitor <out>,transform,N
        #   keyword input:touchdevice:transform N   <- touch mapping
        #   keyword input:tablet:transform N        <- pen mapping
        #   keyword workspace m[ID], layoutopt:orientation:<dir>
        # An earlier version of this shim translated only the monitor line
        # and silently dropped the rest -- display rotated, touch/pen
        # coordinates did not. All four go in one eval now:
        #   - hl.monitor merges into the output's existing rule
        #     (hlMonitor: parser.rule() = *existing), which also obsoletes
        #     the original partial-rule bug this shim was born for
        #   - input transforms are plain config values
        #     (input:touchdevice:transform, input:tablet:transform)
        #   - the orientation keyword is NOT forwarded as-is; it names a
        #     master-layout option this layout ignores, so it is remapped to
        #     scrolling:direction below
        lua="hl.monitor({ output = \"$mon\", transform = $xform }) hl.config({ input = { touchdevice = { transform = $xform }, tablet = { transform = $xform } } })"
        # THE LAYOUT AXIS. iio-hyprland's fourth command is
        #
        #   keyword workspace m[<ID>], layoutopt:orientation:<left|top|right|bottom>
        #
        # which is a MASTER-layout option. general:layout here is "scrolling",
        # and that algorithm never reads `orientation` -- it reads `direction`:
        #
        #   if (WORKSPACERULE->m_layoutopts.contains("direction"))
        #     -- src/layout/algorithm/tiled/scrolling/ScrollingAlgorithm.cpp:1942
        #
        # So the orientation this shim used to forward was translated
        # faithfully and then silently discarded, which is why rotating left
        # windows side by side instead of stacking them.
        #
        # Derived from $xform rather than from iio's orientation word: the
        # transform is unambiguous, and it keeps the mapping readable as
        # "which way is the long axis now".
        #
        #   0 normal    -> right  tape runs across the wide axis
        #   1 90 deg    -> down   long axis is now vertical, so stack
        #   2 180 deg   -> left   horizontal again, reversed
        #   3 270 deg   -> up     vertical again, reversed
        #
        # Set globally rather than per workspace so it applies to workspaces
        # that do not exist yet. Returning to landscape needs no counterpart:
        # the transform-0 branch above execs `reload`, which drops back to the
        # configured default.
        case "$xform" in
          1) _dir=down ;;
          2) _dir=left ;;
          3) _dir=up ;;
          *) _dir=right ;;
        esac
        lua="$lua hl.config({ scrolling = { direction = \"$_dir\" } })"
        # Same reason: hooks before exec, not after.
        ${runRotationHooks} "$xform"
        exec "$real" eval "$lua"
      fi
    fi
    exec "$real" "$@"
  '';

  # Only iio-hyprland's own hyprctl calls go through the shim -- everything
  # else in the session (DMS, terminal, keybinds) keeps using the real one.
  #
  # flock singleton: hard cap of one instance per session, enforced at the
  # wrapper regardless of who spawns it. This is the second half of the
  # 4068-process fork bomb fix (see the hl.on("hyprland.start") comment in
  # extraConfig for the first half): even if some future path re-executes
  # the spawn, the lock makes the duplicate exit instead of joining a
  # rotation -> reload -> respawn feedback loop.
  iioHyprlandWithTransformFix = pkgs.writeShellScriptBin "iio-hyprland" ''
    exec ${pkgs.util-linux}/bin/flock -n "''${XDG_RUNTIME_DIR:-/tmp}/iio-hyprland.lock" \
      ${pkgs.writeShellScript "iio-hyprland-locked" ''
        export PATH="${hyprctlTransformShim}/bin:$PATH"
        exec ${pkgs.iio-hyprland}/bin/iio-hyprland "$@"
      ''} "$@"
  '';

  /*
    Page-relative workspace navigation.

    Compositor-level on purpose, not part of any shell: the numbering is how
    the KEYS behave, and it stays coherent with no bar on screen at all. A
    shell that draws a workspace strip is expected to mirror this arithmetic
    (features/dms/plugins/workspaces does) rather than to own it.

    Slot N means "the Nth workspace of the group of ten I am currently in", not
    workspace N. The page is derived from the LIVE focused workspace on every
    press rather than tracked in a variable, so the bar plugin and the keybinds
    cannot disagree -- they run the same arithmetic against the same source and
    neither writes state the other has to trust.

    Legacy `hyprctl dispatch workspace N` does NOT work here: configType = "lua"
    routes dispatch through hl.dispatch(), and the bare form dies with
    "')' expected near '2'". The lua dispatcher form is the only one that
    parses.
  */
  wsSlot = pkgs.writeShellScript "hypr-ws-slot" ''
    slot="$1"
    active=$(${pkgs.hyprland}/bin/hyprctl activeworkspace -j | ${pkgs.jq}/bin/jq -r '.id')
    # Workspaces are 1-based, so bias before dividing: 1..10 -> page 0.
    page=$(( (active - 1) / 10 ))
    target=$(( page * 10 + slot ))
    if [ "$2" = move ]; then
      ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.window.move({ workspace = $target, follow = true })"
    else
      ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.focus({ workspace = $target })"
    fi
  '';

in
{
  /*
    Screenshots are a COMPOSITOR concern here, not a shell one. DMS does ship a
    screenshot IPC, but it is documented as niri-only (`dms ipc call niri
    screenshot*`, niri 25.11+) with no hyprland equivalent, so this feature
    carries a standalone slurp-based wrapper and every shell gets the same
    behaviour.

    HYPRSHOT RATHER THAN GRIMBLAST, because grimblast's area mode is unusable by
    touch. Both wrap the same slurp, but they call it differently:

      grimblast  echo "$rects" | slurp -o ... -f '%x,%y %wx%h|%l'   snap-to-window
      hyprshot   slurp -d                                          free-form

    grimblast's `area` has no free-form path at all -- it always feeds slurp the
    window rectangles on stdin and passes -o, i.e. selection is constrained to
    snapping onto an existing window. Measured on this machine: bare `slurp`
    accepts finger input, grimblast's area mode does not.

    S PEN DOES NOT WORK IN EITHER, and that is not what this change fixes.
    Tested against slurp directly and against hyprshot: touch works, stylus does
    not, so the gap is below both wrappers -- either slurp's zwp_tablet_v2
    handling or Hyprland's routing of tablet events to a layer surface. Ruled
    out rather than assumed: slurp 1.5.0 does carry the tablet protocol symbols,
    so it is not simply built without support. Accepted as a limitation: a
    finger is always present, the pen is not.

    NOTE a real behaviour change on CTRL+Print. `grimblast copy screen` captured
    ALL monitors into one image; hyprshot has no such mode, and `-m output`
    captures the focused output only. Nothing else moves.
  */
  home.packages = lib.mkIf (osConfig.my.desktop.compositor == "hyprland") [
    pkgs.hyprshot
    iioHyprlandWithTransformFix
    # iio-hyprland shells out to `hyprctl -j monitors | jq` internally; without
    # jq in PATH it fails immediately and aborts uncleanly (dbus_disconnect
    # crash) instead of just erroring on the missing monitor lookup.
  ];

  wayland.windowManager.hyprland = {
    enable = osConfig.my.desktop.compositor == "hyprland";

    # Lua, not hyprlang. Verified against this exact build's own source
    # (0.56.0's src/config/lua/bindings/*.cpp) rather than assumed from docs
    # of a fast-moving pre-1.0 API -- see extraConfig below for API notes.
    configType = "lua";

    settings = lib.mkIf (osConfig.my.desktop.compositor == "hyprland") {
      /*
        Everything below is ONE hl.config({...}) call: the Lua renderer emits
        `hl.<name>(...)` per top-level settings key, and `config` is the
        generic "any hyprlang-equivalent value" sink -- general, decoration,
        input, gestures, group, animations, scrolling, binds all nest inside
        it rather than getting their own top-level hl.<category>() call.
      */
      config = {
        general = {
          gaps_in = 2;
          gaps_out = 4;
          border_size = 0;
          # Scrolling layout off (again -- same tweak as pre-readopt commit
          # 990f0f5): no horizontal window tape on this machine. Falls back
          # to the default layout; the colresize binds below go inert.
          # layout = "scrolling";
          # Ask 2: resize by dragging a window's edge/gap, with mouse or
          # finger -- both route through the same click-and-drag hit-test,
          # so enabling this covers touch too (verified against 0.56.0
          # source: general:resize_on_border, default false).
          resize_on_border = true;
          # border_size = 0 above means there is no visible border to grab;
          # this extends the invisible hitbox around the window edge instead
          # (general:extend_border_grab_area, px, default 15 -- kept at
          # default, generous enough for a finger).
          extend_border_grab_area = 15;
          hover_icon_on_border = true;
        };

        /*
          GAPS, BORDER AND ROUNDING ARE THIS FEATURE'S, and a themed shell must
          not be allowed to set them. Stated here because DMS makes the offer:
          its Hyprland theming writes two Lua snippets, each its own hl.config
          call -- colors.lua (general.col.*, group.col.*) and layout.lua
          (gaps_in/gaps_out/border_size/decoration.rounding).

          Colours are safe to hand over, and features/dms does exactly that.
          layout.lua is not: it sets border_size = 2, and border_size is not
          cosmetic here. The touchscreen workspace-swipe activation strip is
          (gaps_out + border_size) / screen_height, so a shell nudging the
          border silently widens the strip that steals edge touches. The values
          below stay static for that reason.
        */

        # Niri's touchpad block explicitly enables natural-scroll; Hyprland
        # has no input block at all here, defaulting to non-natural (i.e.
        # inverted relative to what niri was doing).
        input.touchpad = {
          natural_scroll = true;
          # libinput's "clickfinger" method: a two-finger physical click is
          # a right click and three fingers a middle click, replacing the
          # default software button areas at the pad's bottom edge.
          clickfinger_behavior = true;
        };

        /*
          Ask 1, root cause (verified against 0.56.0 source, not guessed):
          Super+H/L (movefocus l/r) direction-queries "is there a window to
          my left/right?" -- a maximized window fills the screen, so the
          query finds nothing and the dispatcher silently no-ops. That's
          binds:movefocus_cycles_fullscreen (default false); enabling it
          makes movefocus cycle through fullscreen/maximized windows instead
          of finding no neighbor. src/config/shared/actions/ConfigActions.cpp,
          Actions::moveFocus: the window-to-change-to is only computed via
          the fullscreen-aware cycle query when this is true.

          Super+J/K (workspace e∓1) and the touchscreen swipe (lisgd, the
          SAME dispatcher) were also reported dead on a maximized window,
          but that is NOT this setting's doing: the whole changeWorkspace
          chain (resolveWorkspaceForChange -> Actions::changeWorkspace ->
          CMonitor::changeWorkspace) has no fullscreen/maximize gate
          anywhere in 0.56.0 -- the switch and refocus proceed regardless of
          the outgoing window's state. Two things have since removed the
          likely real causes without touching workspace code at all: the
          lisgd commands were legacy-syntax and silently failing under the
          Lua config (fixed), and emacs -- the window those reports were
          made against -- no longer opens in a fullscreen state at all (see
          the scrolling_width rule below, replacing `maximize`). Recheck
          before assuming a Hyprland-level bug remains here.
        */
        binds.movefocus_cycles_fullscreen = true;

        /*
          3-finger swipe drags/moves the focused window around; 4-finger
          swipe switches workspaces. Vertical to match niri's
          vertical-workspace model (workspaces animation style below must
          also be "slidevert" -- the swipe's up/down vs left/right behavior
          is derived from the animation style, not just this setting).

          Hyprland's only touchscreen gesture: a single-finger swipe from the
          screen EDGE, switching workspaces. Complements the lisgd daemon
          (features/touch-gestures) rather than replacing it -- that handles
          multi-finger swipes anywhere on the panel.

          The activation strip is (gaps_out + border_size) / screen_height,
          so with gaps_out = 4 and border_size = 0 it is four pixels. Enabled
          because it costs nothing and is occasionally hit by
          accident-turned-habit, but it is not the mechanism to rely on.
          Widening it means widening the gaps, which is not worth it.

          The axis follows the workspaces animation style, not this setting:
          "slidevert" below makes it top/bottom edges, matching the
          touchpad's 4-finger vertical gesture.
        */
        gestures = {
          workspace_swipe_touch = true;
          workspace_swipe_touch_invert = false;

          # Swipe sensitivity, tuned for the 3-finger workspace gesture: the
          # 300px default needs most of this touchpad's height for one
          # switch. Distance is how far a full swipe travels (lower = more
          # sensitive); cancel_ratio commits the switch once 30% of that is
          # covered instead of half, so a short flick lands.
          workspace_swipe_distance = 120;
          workspace_swipe_cancel_ratio = 0.3;
        };

        # NEITHER general.col.* NOR group.col.* is set here, deliberately.
        # A shell with live theming writes them at runtime (DMS emits a
        # colors.lua setting both in a single hl.config call, and its feature
        # requires that file), so a static value here would only race it. With
        # no shell selected, Hyprland's own defaults apply -- which is the
        # correct outcome, not a gap.

        decoration = {
          rounding = 16;
          # Glassmorphism: true backdrop blur behind translucent surfaces.
          # Compositor-side half only. Blur applies to translucent WINDOWS
          # automatically, but a layer surface has to opt in with a
          # layer_rule, so a shell that wants frosted panels contributes that
          # rule (and its own alpha) from its own feature.
          blur = {
            enabled = true;
            size = 8;
            passes = 3;
            vibrancy = 0.17;
            ignore_opacity = true;
            popups = true;
            # Frost texture: over dark/flat backdrops (e.g. the wallpaper
            # strip behind the bar's exclusive zone -- windows never go
            # under it), plain blur is invisible. Noise + slight brightness
            # lift make the glass read as glass regardless of what's behind
            # it.
            noise = 0.02;
            brightness = 1.1;
            contrast = 1.0;
          };
        };

        /*
          Native scrolling layout (Hyprland >=0.55, src/layout/algorithm/tiled/scrolling) —
          niri-like columns, no plugin needed. column_width matches niri's
          layout.default-column-width.proportion = 0.5 from features/niri/home.nix.
        */
        scrolling = {
          column_width = 0.5;
          fullscreen_on_one_column = true;
          follow_focus = true;
        };

        # animations.enabled is a real scalar hyprlang value, so it belongs
        # here; the actual curve/speed data does NOT (see extraConfig's
        # hl.animation calls below for why).
        animations.enabled = true;

        # XWayland surfaces on this 1.5-scaled panel get upscaled by the
        # compositor and look pixelated (first seen on galaxy-buds-client,
        # an Avalonia/X11 app). force_zero_scaling makes XWayland render at
        # scale 1 -- crisp, but each X11 app is then responsible for its own
        # DPI scaling, which for Avalonia the AVALONIA_GLOBAL_SCALE_FACTOR
        # env below provides. Other-toolkit X11 apps that don't self-scale
        # will render small until given their own toolkit's scale env
        # (GDK_SCALE etc.) -- deliberate trade: crisp-but-small beats
        # blurry, and this host runs almost everything native Wayland.
        xwayland.force_zero_scaling = true;

        # damage_tracking = 0 (default 2 = full damage tracking): stop trusting
        # per-region damage and redraw the whole output each frame. Native-
        # Wayland Qt/KDE apps (Okular) intermittently went BLACK -- the surface
        # stopped being repainted after some event (idle DPMS wake, workspace
        # switch, occlusion) and a window resize did NOT bring it back, which
        # rules out a simple stale-buffer-until-damage bug and points at the
        # compositor's damage regions going wrong. Full redraws sidestep it, at
        # a modest GPU/power cost. Verified live: `hyprctl getoption
        # debug:damage_tracking` -> 0 after hl.config applied it.
        debug.damage_tracking = 0;

        # No Hyprland startup splash. Right after tuigreet login, before awww
        # paints the wallpaper, Hyprland shows its DEFAULT wallpaper -- the
        # Hyprland logo plus a splash line (version / random blurb). That is the
        # "text with the hyprland logo" that flashes up on login. Kill all three
        # so the hand-off from greeter to wallpaper is a clean black, not a
        # branded flash. force_default_wallpaper = 0 also drops the logo image
        # itself, not just the text.
        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
          force_default_wallpaper = 0;
        };
      };

      /*
        Touchpad multi-finger gestures. hl.gesture({fingers, direction, action}) --
        one call per list element; direction values verified against
        TrackpadGestures.cpp's dirForString ("swipe" for the free-drag verb,
        "vertical"/"horizontal" for axis-locked ones -- NOT the legacy
        "3, swipe, move" string form, which Lua mode doesn't parse at all).
      */
      # Finger counts swapped from upstream's (workspace on 3, move on 4) --
      # the same preference the pre-readopt commit 990f0f5 carried.
      gesture = [
        # 4-finger free drag/move of the focused window.
        {
          fingers = 4;
          direction = "swipe";
          action = "move";
        }
        # 3-finger vertical swipe: workspace switch, matching the touchscreen
        # gesture direction above and the "slidevert" animation style.
        {
          fingers = 3;
          direction = "vertical";
          action = "workspace";
        }
        # scroll_move (snake_case -- verified against source, NOT the legacy
        # dispatcher's "scrollMove" spelling, which errors here:
        # "hl.gesture: unknown action \"scrollMove\""): purpose-built gesture
        # for the scrolling layout's tape -- live momentum + snap-to-column
        # (gestures:scrolling:* defaults handle it). Inert while the layout
        # is off, kept for the day it comes back.
        {
          fingers = 3;
          direction = "horizontal";
          action = "scroll_move";
        }
      ];
    };

    /*
      Hand-written Lua rather than the settings-attrset DSL, for everything
      whose Nix->Lua rendering would need mkLuaInline gymnastics anyway
      (binds threading a `mod` variable through dispatcher-call expressions).
      Every hl.* call below is verified against this exact build's own
      source (0.56.0, src/config/lua/bindings/*.cpp), not assumed from docs
      of a fast-moving pre-1.0 API:
        - hl.bind(key_string, dispatcher_call, opts?) -- LuaBindingsToplevel.cpp:132.
          key_string: "+"-separated tokens, mods first ("SUPER + SHIFT + Q").
        - hl.dsp.* dispatcher table -- LuaBindingsDispatchers.cpp:1339
          (registerDispatcherBindings), enumerated exhaustively, not guessed.
        - hl.env(name, value), hl.monitor({output=...}), hl.window_rule({...}),
          hl.layer_rule({...}) -- LuaBindingsConfigRules.cpp.
        - hl.exec_cmd(cmd) at top level (NOT hl.dsp.exec_cmd, which is the
          bind-dispatcher-factory form) runs immediately as the script loads
          -- the exec-once equivalent. LuaBindingsToplevel.cpp:321.
    */
    /*
      mkBefore, and it is load-bearing.

      extraConfig is types.lines, so every module defining it is concatenated
      into the one generated hyprland.lua -- that is what lets other features
      contribute binds and rules. Order between definitions is definition
      order, and flake.nix builds the feature list from
      `builtins.readDir ./features`, which is ALPHABETICAL: `dms` sorts before
      `hyprland`. Without an explicit order a contributed fragment lands above
      this one, referencing `mod` before it is declared and calling hl.* before
      hl.config has run -- a Lua error at session start, not at build time.

      So: this block is mkBefore, every contributed fragment is mkAfter.
    */
    extraConfig = lib.mkBefore ''
      -- From my.hyprland.modKey, so a bind contributed by another feature
      -- interpolates the same Nix value rather than depending on this local
      -- happening to be concatenated above it.
      local mod = "${osConfig.my.hyprland.modKey}"

      -- Cursor, set here because no shell reliably sets it for Hyprland: DMS's
      -- cursorSettings plumbing is niri-only (cursorSettings.niri.hideWhenTyping),
      -- so Hyprland would otherwise fall back to its own built-in hyprcursor
      -- theme. Set both XCURSOR_* (X/Wayland apps) and HYPRCURSOR_*
      -- (Hyprland's native cursor renderer) so it's consistent everywhere.
      -- Bibata-Modern-Classic-Glass = Bibata-Modern-Classic with alpha
      -- multiplied down, generated in features/cursor-theme/home.nix (home.pointerCursor
      -- there also enforces it via dconf + ~/.icons/default so apps can't
      -- resolve a different theme). No hyprcursor manifest; Hyprland falls
      -- back to the XCursor theme of the same name, which is intended.
      hl.env("XCURSOR_THEME", "Bibata-Modern-Classic-Glass")
      hl.env("XCURSOR_SIZE", "24")
      hl.env("HYPRCURSOR_THEME", "Bibata-Modern-Classic-Glass")
      hl.env("HYPRCURSOR_SIZE", "24")
      -- Qt apps outside Plasma (dolphin, kdenlive, ...) have no platform
      -- theme and fall back to a broken mixed palette (black-on-black text).
      -- qt6ct is installed and a matugen-driven shell generates its palette
      -- (DMS writes ~/.config/qt6ct -> DankMatugen.colors) -- this activates
      -- it, and is harmless with no such shell: qt6ct then simply uses
      -- whatever palette is on disk.
      -- This alone is NOT sufficient -- plugin discovery, qt6ct.conf
      -- contents, and KDE apps' KColorSchemeManager each needed their own
      -- fix. See features/qt-theming/nixos.nix (QT_PLUGIN_PATH +
      -- the full debugging story) and features/qt-theming/
      -- qt-theming.nix (kdeglobals + qt6ct.conf enforcement).
      hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
      -- Pairs with xwayland.force_zero_scaling in the config table above:
      -- XWayland now renders at scale 1, so Avalonia apps
      -- (galaxy-buds-client) must scale themselves. Avalonia reads this env
      -- var and accepts fractional values, unlike GDK_SCALE. Kept in sync
      -- with the monitor scale via my.desktop.primaryOutputScale.
      hl.env("AVALONIA_GLOBAL_SCALE_FACTOR", "${osConfig.my.desktop.primaryOutputScale}")

      -- Hyprland's stock animation speeds read as sluggish coming from
      -- niri. NOT a field of hl.config's "animations" table: "animation" is
      -- not a real scalar hyprlang config value (only animations:enabled
      -- is, hence that staying in the config table above) -- it's a
      -- repeatable curve/speed RULE, which Lua mode exposes only through
      -- this dedicated function (verified: putting it inside hl.config did
      -- not error, it just silently did nothing, leaving Hyprland's default
      -- animation timings active -- "extremely slow" was this, not a units
      -- mistake).
      --
      -- `enabled` is required on every call despite defaulting to true in
      -- the C++ parser's own constructor: parseTableField() (Lua bindings
      -- internal helper) treats ANY missing table field as a hard error
      -- ("missing required field") before the parser object's constructor
      -- default is ever consulted -- that default only matters for a value
      -- parseTableField already found and is parsing, not for whether the
      -- field may be omitted. Confirmed live: leaving it out errored
      -- "missing required field \"enabled\"" on all five calls.
      -- bezier = "linear", not "default": the built-in "default" curve is
      -- 0.05,0.9,0.1,1.05 -- the trailing 1.05 OVERSHOOTS past the target and
      -- springs back, which is the "jelly" wobble (most visible on resizing
      -- layer surfaces, e.g. the desktop-icons layer). "linear" ends exactly
      -- at 1.0, so motion stays smooth but never bounces. This hl API exposes
      -- only the built-in named beziers (hl.bezier / hl.keyword are absent), so
      -- a custom ease-out is not available -- "linear" is the no-overshoot one.
      hl.animation({ leaf = "global", enabled = true, speed = 4, bezier = "linear" })
      hl.animation({ leaf = "windows", enabled = true, speed = 3, bezier = "linear" })
      hl.animation({ leaf = "border", enabled = true, speed = 3, bezier = "linear" })
      hl.animation({ leaf = "fade", enabled = true, speed = 3, bezier = "linear" })
      -- Layer surfaces explicitly on the no-overshoot curve too: this is where
      -- the jelly was actually seen (the desktop-icons layer bouncing on every
      -- resize). The reimplemented desktop layer no longer resizes, but pinning
      -- this stops any layer from wobbling.
      hl.animation({ leaf = "layers", enabled = true, speed = 3, bezier = "linear" })
      -- slidevert: vertical slide, matching niri's vertical workspace model
      -- and the gesture's vertical swipe direction above.
      hl.animation({ leaf = "workspaces", enabled = true, speed = 3, bezier = "linear", style = "slidevert" })

      -- Auto-scale differs between compositors (Hyprland picked 2.0 for this
      -- 2880x1800 panel; niri's own auto heuristic apparently picked something
      -- smaller, hence text/buttons looking oversized after switching). Pin
      -- explicitly so it doesn't depend on Hyprland's auto-detection. Output name
      -- and scale both come from the host -- see my.desktop.primaryOutput.
      hl.monitor({
        output = "${osConfig.my.desktop.primaryOutput}",
        mode = "preferred",
        position = "auto",
        scale = "${osConfig.my.desktop.primaryOutputScale}",
      })

      -- Wacom One 13 pen display: EXTEND to the right of the laptop panel (was
      -- mirror). Matched by the DP port name, not desc: -- verified live that a
      -- `desc:` selector is silently ignored through this hl.monitor Lua API
      -- (returns "ok" but never matches), whereas "DP-1" applies cleanly. Both
      -- panels are 1920x1080 @ scale 1, so auto-right lands it flush at 1920,0.
      -- Pen mapping in extend mode is OTD's job: set its output area to the Wacom
      -- screen (Artist Mode auto-maps a pen display; Absolute Mode needs the
      -- display area dragged onto DP-1). Harmless when nothing is on DP-1.
      hl.monitor({
        output = "DP-1",
        mode = "preferred",
        position = "auto-right",
        scale = 1,
      })

      -- Confine the pen to the Wacom (DP-1) at the COMPOSITOR level. On a
      -- multi-monitor Wayland desktop, letting OTD target a specific monitor via
      -- its own Display area fights Hyprland (OTD's coords land outside the range
      -- Hyprland maps the virtual tablet to, so X saturates -- "stuck to the
      -- right"). input:tablet:output makes Hyprland do the monitor mapping, so
      -- OTD just maps the full tablet 1:1 and Hyprland puts it on DP-1. Works in
      -- mirror too (DP-1 sits at 0,0 there). Pair with OTD Artist Mode, whose
      -- virtual tablet is 16:9 like the panel, for a clean no-distortion 1:1.
      hl.config({ input = { tablet = { output = "DP-1" } } })

      -- Keep the on-screen keyboard (wvkbd) at the very top of the overlay level,
      -- above other overlay surfaces like the rofi launcher, so its keys stay
      -- tappable while a launcher/menu is open. Verified via screenshot with rofi
      -- up. `order` is Hyprland's within-level z hint; higher = closer to the top.
      hl.layer_rule({ match = "wvkbd", order = 999 })

      -- iio-hyprland: reads iio-sensor-proxy orientation over D-Bus, rotates the
      -- eDP-1 output and touch input transform automatically (accel_3d + hinge
      -- sensors confirmed present via /sys/bus/iio/devices; enabled in hardware.nix).
      -- NOTHING ELSE IS SPAWNED HERE, and a shell least of all: its feature
      -- starts it as a systemd user service off graphical-session.target,
      -- which uwsm activates. An exec-once copy alongside that produced a
      -- second, unmanaged instance -- observed as two bars, one
      -- hyprland-parented. Same reasoning as the niri side's
      -- spawn-at-startup comment.
      --
      -- INSIDE hl.on("hyprland.start"), NEVER at top level: a top-level
      -- hl.exec_cmd runs on EVERY config reload (the whole Lua script
      -- re-executes; hyprlang's exec-once semantics do not exist here), and
      -- the rotation shim's transform-0 path calls `hyprctl reload` -- each
      -- landscape rotation spawned another instance, every instance reacted
      -- to every subsequent rotation, and the loop compounded to 4068 live
      -- processes and a load average of 125 before it was caught. The
      -- start event fires once per compositor lifetime; reloads re-register
      -- this handler but never re-fire it (ConfigManager clears and
      -- re-registers event handlers on reload; the event itself is
      -- startup-only -- same mechanism Unstraightened relies on for its
      -- own systemd activation block). The wrapper also carries a flock
      -- singleton as defense in depth.
      hl.on("hyprland.start", function()
        hl.exec_cmd("iio-hyprland ${osConfig.my.desktop.primaryOutput}")
      end)

      -- Emacs opens as a FULL-WIDTH COLUMN, not maximized. `maximize` is a
      -- fullscreen STATE: it renders over the reserved area, drops gaps and
      -- corner rounding, and has to be cleared before any colresize can be
      -- seen (which is exactly why Mod+D "didn't shrink" emacs). scrolling_width
      -- is the column-width equivalent of `layoutmsg colresize 1` and applies
      -- at window-open time -- the scrolling layout reads it in newTarget and
      -- feeds it to the new column (ScrollingAlgorithm.cpp: add(width), where
      -- the value is a fraction of the tape in the same units as
      -- scrolling.column_width, so 1.0 = full width). Result: same footprint,
      -- but a normal tiled window -- decorations intact, Mod+D toggles it
      -- straight back to 0.5 with no state to clear first.
      hl.window_rule({ match = { class = "^(emacs)$" }, scrolling_width = 1.0 })
      hl.window_rule({ match = { class = "^(org.gnu.emacs)$" }, scrolling_width = 1.0 })
      -- Matplotlib floating
      hl.window_rule({ match = { class = "^(Matplotlib)$" }, float = true })
      -- Waydroid size lock
      hl.window_rule({ match = { class = "^(Waydroid)$" }, scrolling_width = 1.0 })
      -- Glassmorphism: translucent KDE apps; backdrop blur applies to
      -- translucent windows automatically (decoration.blur). kdeconnect
      -- covers all its windows (.app, .sms, -indicator, ...).
      hl.window_rule({ match = { class = "^(org\\.kde\\.dolphin)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(org\\.kde\\.kdeconnect.*)$" }, opacity = "0.65 0.65" })
      -- Claude Desktop: app_id from the deb's desktop-file StartupWMClass
      -- (Chromium derives it from package.json desktopName). Same 0.65 as
      -- the KDE apps -- the package forces its dark backgrounds to #000
      -- (see packages/claude-desktop/package.nix), so it composites
      -- identically to kitty/dolphin.
      hl.window_rule({ match = { class = "^(com\\.anthropic\\.Claude)$" }, opacity = "0.65 0.65" })
      -- qalculate: same 0.65 glass as kitty/Claude/dolphin. Its runtime
      -- Wayland app_id is the reverse-DNS "io.github.Qalculate.qalculate-qt"
      -- (NOT the .desktop's StartupWMClass "qalculate-qt") -- confirmed with
      -- `hyprctl clients | grep -i qalc`.
      hl.window_rule({ match = { class = "^(io\\.github\\.Qalculate\\.qalculate-qt)$" }, opacity = "0.65 0.65" })
      -- Settings / utility panels: same 0.65 glass. They already float+center
      -- (rules further down); on control panels the translucency is purely
      -- aesthetic -- no content to mud.
      hl.window_rule({ match = { class = "^(.*pavucontrol.*)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(blueman-manager)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(nm-connection-editor)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(.*[Ss]ystem-config-printer.*)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(com\\.github\\.wwmm\\.easyeffects)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(wdisplays)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(qt6ct)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(org\\.kde\\.systemsettings)$" }, opacity = "0.65 0.65" })
      -- Emacs: glass on the editor; both app_ids it reports (X11 "emacs",
      -- pgtk "org.gnu.emacs").
      hl.window_rule({ match = { class = "^(emacs)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(org\\.gnu\\.emacs)$" }, opacity = "0.65 0.65" })
      -- Firefox: MILDER 0.9, not 0.65 -- web content (photos, video, white
      -- pages) muds at 0.65; 0.9 stays legible while still glassy.
      hl.window_rule({ match = { class = "^(firefox)$" }, opacity = "0.9 0.9" })
      -- Galaxy Buds client: small settings-style utility, better floating
      -- than as a full tape column. Class from the package's own
      -- makeDesktopItem name (= meta.mainProgram = "GalaxyBudsClient",
      -- which Avalonia also uses for WM_CLASS). If the rule doesn't bite,
      -- verify the real class with `hyprctl clients | grep -i buds`.
      -- Its XWayland pixelation is handled globally above
      -- (xwayland.force_zero_scaling + AVALONIA_GLOBAL_SCALE_FACTOR), not
      -- per-window -- force_zero_scaling has no per-window form.
      hl.window_rule({ match = { class = "^(GalaxyBudsClient)$" }, float = true })

      -- Utility / settings windows float AND center, rather than joining the
      -- tape as a full column or opening at the cursor. These are the small
      -- managers, pickers and config panels that are only in the way when
      -- tiled: audio/bluetooth/network/display/printer settings, EasyEffects,
      -- the file browser, the KDE file-picker portal. Class regexes (Wayland
      -- app_id / XWayland WM_CLASS); if a rule doesn't bite, check the real
      -- class with `hyprctl clients | grep -i <app>`. float + center in one
      -- rule -- both verified accepted by this build's Lua binding.
      hl.window_rule({ match = { class = "^(org\\.kde\\.dolphin)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(.*pavucontrol.*)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(blueman-manager)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(nm-connection-editor)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(.*[Ss]ystem-config-printer.*)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(com\\.github\\.wwmm\\.easyeffects)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(wdisplays)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(qt6ct)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(org\\.kde\\.systemsettings)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(xdg-desktop-portal-.*)$" }, float = true, center = true })
      hl.window_rule({ match = { class = "^(io\\.github\\.Qalculate\\.qalculate-qt)$" }, float = true, center = true })

      -- ============================================================
      -- Binds. Key-layout aligned with end-4/dots-hyprland's
      -- keybinds.lua where it has a real Hyprland-dispatcher
      -- equivalent; its quickshell:* global-IPC actions (overview,
      -- sidebars, OSK, cheatsheet -- end-4's own shell's protocol, which
      -- DMS does not implement) are NOT ported -- see the chat for the
      -- explicit list of what that leaves out.
      -- ============================================================

      -- Application spawns. Anything that toggles a SHELL surface -- launcher,
      -- notifications, clipboard, power menu, lock -- is contributed by
      -- whichever feature implements that shell, not bound here.
      -- Launch scheme: W browser, T terminal, B file browser, L office
      -- (mod+L was focus-right -- see the note there; use mod+Right instead).
      hl.bind(mod .. " + Return", hl.dsp.exec_cmd("kitty"))
      hl.bind(mod .. " + T", hl.dsp.exec_cmd("kitty"))
      hl.bind(mod .. " + W", hl.dsp.exec_cmd("firefox"))
      hl.bind(mod .. " + B", hl.dsp.exec_cmd("dolphin"))
      hl.bind(mod .. " + E", hl.dsp.exec_cmd("emacsclient -c"))
      -- On-screen keyboard: toggle the wvkbd overlay (handy with the Wacom pen).
      hl.bind(mod .. " + O", hl.dsp.exec_cmd("${wvkbdToggle}"))
      -- Compositor-level IME toggle, same logic as niri.nix's Hangul bind.
      hl.bind("Hangul", hl.dsp.exec_cmd("${hangulToggle}"))

      -- Laptop Fn media keys. The keys emit XF86 keysyms; nothing was bound to
      -- them, so they did nothing. Global (no mod), locked = true so they work
      -- on the lock screen, and repeating = true so HOLDING ramps. NOTE: the
      -- hold-to-ramp flag is `repeating`, NOT `repeat` -- this was written as
      -- ["repeat"] = true (guessing the Lua keyword needed quoting), which
      -- hl.bind silently ignores, so the keys quietly stopped ramping and only
      -- stepped once per press. wpctl (wireplumber) for audio, brightnessctl for
      -- backlight; volume capped at 100% (-l 1.0).
      hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
      hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
      hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
      hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"), { locked = true, repeating = true })
      hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl set 5%+"), { locked = true, repeating = true })

      -- Window management
      hl.bind(mod .. " + Q", hl.dsp.window.close())
      hl.bind(mod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
      -- niri's maximize-column, now a real TOGGLE on Mod+D (end-4's key for
      -- it; Mod+D is free now that its earlier weirdness is understood --
      -- it was never a DMS collision, just Hyprland's MAXIMIZED state
      -- dropping gaps/rounding, see the git log of this file for the whole
      -- misdiagnosis saga). `colresize 1` keeps the window a normal tiled
      -- column -- gaps and rounding intact -- unlike MAXIMIZED.
      --
      -- The toggle is STATE-FREE on purpose: no stored flag to go stale
      -- when Mod+R or a mouse edge-drag changes the width behind its back.
      -- It reads the focused window's actual laid-out width against the
      -- monitor's usable logical width and picks the direction each press:
      --   window object: .size (GEOMETRIC_GOAL layout px), .floating,
      --   .monitor -- LuaWindow.cpp
      --   monitor object: .size (PIXEL size -- divide by .scale for
      --   logical), .transform (odd = rotated 90°: swap w/h -- this is a
      --   convertible with autorotate, so it matters), .reserved
      --   (bar exclusive zone) -- LuaMonitor.cpp
      -- 0.9 threshold: a full column is usable minus 2*gaps_out (8px);
      -- the next preset down is 0.66, comfortably below.
      hl.bind(mod .. " + D", function()
        local w = hl.get_active_window()
        if not w or w.floating then return end
        -- A window in fullscreen STATE (w.fullscreen: 0 none, 1 maximized,
        -- 2 fullscreen -- the FSMODE enum) renders full-screen regardless
        -- of its column width, so colresize alone visibly does nothing.
        -- Emacs is the live case: its `maximize on` windowrule opens it in
        -- state 1, and the first Mod+D "didn't shrink" because it resized
        -- the column underneath the state. Clear the state instead; the
        -- column width it returns to is whatever it had.
        if w.fullscreen ~= 0 then
          hl.dispatch(hl.dsp.window.fullscreen({
            mode = (w.fullscreen == 1) and "maximized" or "fullscreen",
            action = "unset",
          }))
          return
        end
        local m = w.monitor
        if not m then return end
        local pw = (m.transform % 2 == 1) and m.size.height or m.size.width
        local usable = pw / m.scale - m.reserved.left - m.reserved.right
        if w.size.x >= usable * 0.9 then
          -- 0.5 = scrolling.column_width in the config table above; keep in sync.
          hl.dispatch(hl.dsp.layout("colresize 0.5"))
        else
          hl.dispatch(hl.dsp.layout("colresize 1"))
        end
      end)
      hl.bind(mod .. " + ALT + space", hl.dsp.window.float())
      -- Same float toggle on Mod+Shift+F (pairs with Mod+F = fullscreen).
      hl.bind(mod .. " + SHIFT + F", hl.dsp.window.float())
      -- end-4's Mod+P is "pin". Mod+P is left free here for a shell to claim
      -- (DMS binds its notepad there), so pin goes on Mod+Alt+P rather than
      -- taking a key the shell layer is expected to want.
      hl.bind(mod .. " + ALT + P", hl.dsp.window.pin())
      -- niri's Mod+Shift+V (switch focus between floating/tiling) has no
      -- direct hyprland dispatcher; `togglegroup` is a different concept
      -- (window grouping), so it's dropped rather than mis-mapped.

      -- Mod+R (was: scrolling layout's colresize +conf) is GONE, not just
      -- inert: the scrolling layout is off on this machine, and the freed
      -- key avoids the drun-launcher collision hakuspace had to dodge.
      -- In its place, the default Lua config's mouse pair that this file
      -- never carried over: Mod + left-drag moves a window anywhere
      -- (floats it out of the tiling if dragged free), Mod + right-drag
      -- resizes. { mouse = true } is what makes a bind track the pointer.
      hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
      hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

      -- Focus movement (h/j/k/l + arrows). hl.dsp.focus is the single
      -- dispatcher covering movefocus/focusmonitor/focus-workspace by
      -- which field its table has -- direction here.
      hl.bind(mod .. " + left", hl.dsp.focus({ direction = "left" }))
      hl.bind(mod .. " + down", hl.dsp.focus({ direction = "down" }))
      hl.bind(mod .. " + up", hl.dsp.focus({ direction = "up" }))
      hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
      -- H/L go through the scrolling layout's OWN focus navigation, not
      -- movefocus. movefocus is geometry-based and the
      -- movefocus_cycles_fullscreen fallback is explicitly bypassed for
      -- layout-managed fullscreen (Actions::moveFocus checks
      -- !layoutManagedFS; the scrolling layout registers its own fullscreen
      -- handler, so its windows ALWAYS take that bypass) -- which is why
      -- H/L stayed dead on maximized windows even after enabling that
      -- setting. `layoutmsg focus l/r` walks the tape's column data
      -- structure instead of screen geometry (ScrollingAlgorithm.cpp,
      -- "focus" branch: pure column->prev/next, no fullscreen gate), so it
      -- works identically maximized or not -- and matches niri's
      -- focus-column semantics, which is what H/L meant here originally.
      -- Arrows stay movefocus: layoutmsg only knows tiled tape members, so
      -- arrows remain the way to reach floating windows.
      -- mod+L reassigned to LibreOffice (launch scheme above). Focus-right is
      -- now mod+Right only; focus-left keeps mod+H. Asymmetric on purpose --
      -- the office launcher was wanted on L.
      hl.bind(mod .. " + H", hl.dsp.layout("focus l"))
      hl.bind(mod .. " + L", hl.dsp.exec_cmd("libreoffice"))
      -- Workspace cycle among EXISTING workspaces ("e±1"), same string
      -- syntax as the legacy `workspace, e-1` dispatcher -- hl.dsp.focus's
      -- workspace-selector overload hands it to the identical parser.
      -- RELATIVE, NOT e-RELATIVE. These were "e-1"/"e+1", which walk only
      -- workspaces that already EXIST -- so from workspace 10 with nothing
      -- above it, e+1 wrapped back to 1 (measured, not assumed). That made
      -- every page past the first unreachable, and paging is the whole point
      -- of a shell's workspace strip.
      --
      -- Plain "+1"/"-1" step into empty workspaces, creating them on demand:
      -- 10 -> 11 -> 12, which rolls the page over as intended. "-1" clamps at
      -- workspace 1 rather than running negative, so the low end needs no
      -- special case.
      hl.bind(mod .. " + K", hl.dsp.focus({ workspace = "-1" }))
      hl.bind(mod .. " + J", hl.dsp.focus({ workspace = "+1" }))
      hl.bind(mod .. " + Page_Down", hl.dsp.focus({ workspace = "-1" }))
      hl.bind(mod .. " + Page_Up", hl.dsp.focus({ workspace = "+1" }))
      hl.bind(mod .. " + CTRL + U", hl.dsp.window.move({ workspace = "-1", follow = true }))
      hl.bind(mod .. " + CTRL + I", hl.dsp.window.move({ workspace = "+1", follow = true }))

      -- Move window (direction)
      hl.bind(mod .. " + CTRL + left", hl.dsp.window.move({ direction = "left" }))
      hl.bind(mod .. " + CTRL + down", hl.dsp.window.move({ direction = "down" }))
      hl.bind(mod .. " + CTRL + up", hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + CTRL + right", hl.dsp.window.move({ direction = "right" }))
      hl.bind(mod .. " + CTRL + H", hl.dsp.window.move({ direction = "left" }))
      hl.bind(mod .. " + CTRL + J", hl.dsp.window.move({ direction = "down" }))
      hl.bind(mod .. " + CTRL + K", hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + CTRL + L", hl.dsp.window.move({ direction = "right" }))
      hl.bind(mod .. " + CTRL + Page_Down", hl.dsp.window.move({ workspace = "-1", follow = true }))
      hl.bind(mod .. " + CTRL + Page_Up", hl.dsp.window.move({ workspace = "+1", follow = true }))

      -- Resize (niri's Mod+Minus/Equal, Mod+Shift+Minus/Equal). BEHAVIOR
      -- CHANGE from the pre-Lua config: legacy `resizeactive` took
      -- percentage-of-current-size ("-10% 0"); hl.dsp.window.resize's table
      -- form only takes pixel x/y (verified against source -- no percentage
      -- support), so this is now a fixed 160px/90px step regardless of the
      -- window's current size.
      hl.bind(mod .. " + minus", hl.dsp.window.resize({ x = -160, y = 0, relative = true }))
      hl.bind(mod .. " + equal", hl.dsp.window.resize({ x = 160, y = 0, relative = true }))
      hl.bind(mod .. " + SHIFT + minus", hl.dsp.window.resize({ x = 0, y = -90, relative = true }))
      hl.bind(mod .. " + SHIFT + equal", hl.dsp.window.resize({ x = 0, y = 90, relative = true }))

      -- Monitor focus
      hl.bind(mod .. " + SHIFT + left", hl.dsp.focus({ monitor = "l" }))
      hl.bind(mod .. " + SHIFT + down", hl.dsp.focus({ monitor = "d" }))
      hl.bind(mod .. " + SHIFT + up", hl.dsp.focus({ monitor = "u" }))
      hl.bind(mod .. " + SHIFT + right", hl.dsp.focus({ monitor = "r" }))

      -- Move window to monitor (niri's Mod+Shift+Ctrl+...)
      hl.bind(mod .. " + SHIFT + CTRL + left", hl.dsp.window.move({ monitor = "l" }))
      hl.bind(mod .. " + SHIFT + CTRL + down", hl.dsp.window.move({ monitor = "d" }))
      hl.bind(mod .. " + SHIFT + CTRL + up", hl.dsp.window.move({ monitor = "u" }))
      hl.bind(mod .. " + SHIFT + CTRL + right", hl.dsp.window.move({ monitor = "r" }))
      hl.bind(mod .. " + SHIFT + CTRL + H", hl.dsp.window.move({ monitor = "l" }))
      hl.bind(mod .. " + SHIFT + CTRL + J", hl.dsp.window.move({ monitor = "d" }))
      hl.bind(mod .. " + SHIFT + CTRL + K", hl.dsp.window.move({ monitor = "u" }))
      hl.bind(mod .. " + SHIFT + CTRL + L", hl.dsp.window.move({ monitor = "r" }))

      -- Workspaces: PAGE-RELATIVE, not absolute.
      --
      -- Super+N goes to slot N of the group of ten containing the focused
      -- workspace, so on workspace 15 Super+1 means 11. The digits keep meaning
      -- "first slot of what I am looking at" instead of an id you have to
      -- remember. A shell drawing a workspace strip derives its page the same
      -- way, from the live focused workspace, so the two cannot drift -- see
      -- features/dms/plugins/workspaces for the one that does.
      --
      -- The persistent workspace_rule calls that used to be here are GONE. They
      -- existed to force the DankBar switcher to render a fixed 1-9; the plugin
      -- draws ten slots whether or not the workspaces exist, so keeping them
      -- would only pin page 0 into existence while every other page stayed
      -- ephemeral -- an asymmetry with no upside.
      -- SHIFT as a second spelling for move-to-slot, alongside CTRL: the
      -- SUPER+SHIFT+<n> convention from stock Hyprland/most WMs. Both stay --
      -- CTRL mirrors the CTRL+U/I workspace-move pair above, SHIFT is muscle
      -- memory.
      for i = 1, 9 do
        hl.bind(mod .. " + " .. tostring(i), hl.dsp.exec_cmd("${wsSlot} " .. tostring(i)))
        hl.bind(mod .. " + CTRL + " .. tostring(i), hl.dsp.exec_cmd("${wsSlot} " .. tostring(i) .. " move"))
        hl.bind(mod .. " + SHIFT + " .. tostring(i), hl.dsp.exec_cmd("${wsSlot} " .. tostring(i) .. " move"))
      end
      -- 0 is the tenth slot, keeping the row of digits contiguous.
      hl.bind(mod .. " + 0", hl.dsp.exec_cmd("${wsSlot} 10"))
      hl.bind(mod .. " + CTRL + 0", hl.dsp.exec_cmd("${wsSlot} 10 move"))
      hl.bind(mod .. " + SHIFT + 0", hl.dsp.exec_cmd("${wsSlot} 10 move"))

      hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())
      -- --clipboard-only skips writing a file at all (hyprshot otherwise saves
      -- AND copies); --silent matches grimblast's old no-notification default.
      hl.bind("Print", hl.dsp.exec_cmd("hyprshot -m region --clipboard-only --silent"))
      hl.bind("CTRL + Print", hl.dsp.exec_cmd("hyprshot -m output --clipboard-only --silent"))
      hl.bind("ALT + Print", hl.dsp.exec_cmd("hyprshot -m window -m active --clipboard-only --silent"))
      -- Mod+Shift+S: region screenshot that SAVES a file and copies it -- the
      -- muscle-memory shortcut, discoverable without a Print key (awkward on
      -- this laptop). Uses hakuspace's screenshot.sh (grim+slurp) rather than
      -- raw hyprshot so it writes to SCREENSHOT_DIR from main_setting.sh
      -- (~/Pictures/Screenshots) -- the single source of truth, matching where
      -- recordings go via SCREENREC_SAVE_DIR -- and notifies with the path.
      hl.bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd("$HOME/.local/bin/screenshot.sh"))
      hl.bind(mod .. " + SHIFT + P", hl.dsp.dpms({ action = "off" }))

    '';
  };
}
