{ config, lib, pkgs, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "sidedock"; };
  cfg = osConfig.my.sidedock;
  mod = osConfig.my.hyprland.modKey;

  # dock.sh is a plain file (no Nix-escaping headaches); this thin wrapper just puts
  # hyprctl + jq on its PATH. hyprctl comes from the RUNNING compositor's own
  # package so the IPC protocol always matches.
  dock = pkgs.writeShellScript "sidedock" ''
    export PATH=${lib.makeBinPath [ osConfig.programs.hyprland.package pkgs.jq pkgs.coreutils pkgs.swaynotificationcenter pkgs.quickshell osConfig.my.panelbus.package ]}''${PATH:+:$PATH}
    exec ${pkgs.writeShellScript "sidedock-impl" (builtins.readFile ./dock.sh)} "$@"
  '';

  # Re-apply the CURRENT wallpaper to ALL outputs when the monitor layout changes -- awww does
  # NOT auto-paint a freshly-created output, so an opendisplay iPad virtual monitor comes up GRAY.
  # Runs off the same monitor.layout_changed hook as the dock relayout (below). Current wallpaper
  # = the path in awww's per-output cache (binary; the path is the last non-control-char run,
  # same extraction as hyprlock-bg). Instant transition so re-painting the already-correct
  # monitor is invisible. No-op if the cache holds a color/video (no path) or awww is down.
  wallpaperRefresh = pkgs.writeShellScript "sidedock-wallpaper-refresh" ''
    export PATH=${lib.makeBinPath [ pkgs.awww pkgs.gnugrep pkgs.coreutils ]}:$PATH
    d="$HOME/.cache/awww/${pkgs.awww.version}"
    cur=$(grep -aoE '/[^[:cntrl:]]+' "$d/eDP-1" 2>/dev/null | tail -1)
    [ -n "$cur" ] || cur=$(for f in "$d"/*; do [ -f "$f" ] && grep -aoE '/[^[:cntrl:]]+' "$f" | tail -1 && break; done)
    [ -n "$cur" ] && [ -f "$cur" ] && awww img "$cur" --transition-type none >/dev/null 2>&1 || true
  '';

  # NOTE: per-monitor workspace management (pin/rename/evacuate) AND runtime monitor-scale capture
  # moved to features/hyprland (their proper domain -- it now owns a monitor.layout_changed hook of
  # its own; hl.on stacks and reload clears handlers, so it coexists with the dock hook below). This
  # feature's hook keeps only the dock relayout + wallpaper repaint.

  # The dock's own throwaway terminal: SUPER+SHIFT+T spawns a kitty under this
  # class, which the auto-route rule below catches so it opens straight into the
  # pile (SUPER+T stays the normal, main-area terminal -- see features/hyprland).
  dockTermClass = "sidedock-term";

  # One auto-route rule per docked app: open FLOATING, PINNED (shown on every workspace so
  # the dock follows the live workspace), WITHOUT grabbing focus, at a monitor-RELATIVE
  # size/position (percentages are of the LOGICAL monitor) so it lands roughly on the
  # right-edge panel at ANY resolution/scale instead of a fixed 640x928@1266,104. dock.sh
  # is the AUTHORITY on geometry: on the next render it re-sizes + size-LOCKS (min==max)
  # and re-positions every card from the LIVE viewport (physical/scale, see geom()), so a
  # display-size change auto-adjusts the moment you touch the dock -- nothing here is tied
  # to 1920x1080. SUPER+D shows/parks the pile; SUPER+SHIFT+D docks/undocks a window.
  #
  # NB the rule does NOT tag the window 'dock': a rule tag renders as "dock*" and
  # CANNOT be removed by the tag dispatcher, so a route-tagged window could never be
  # undocked (SUPER+SHIFT+D no-oped and left it stuck + bordered in the pile). Instead
  # the window.open handler below recognises a fresh dock window by its CLASS and lets
  # dock.sh apply a DYNAMIC 'dock' tag, which undock can remove like a sent window.
  # cfg.apps are the user's docked apps; dockTermClass is the feature's own terminal.
  #
  # border_size/rounding=0: the BORDER is its own render pass (renderBorder) drawn at the
  # flat box -- it does NOT go through the keystone, so it would box the trapezoid; keep it
  # off. The SHADOW, by contrast, IS now warped: trapezoid.patch runs renderRoundedShadow
  # through the SAME keystone homography (a per-dock ENLARGED + OFFSET drop shadow, tuned by
  # decoration:keystone_shadow_* in features/hyprland), so it follows the trapezoid and gives
  # the pile a "floating" lift -- hence NO no_shadow here anymore. BLUR is likewise kept: the
  # frosted layer is drawn by renderTextureInternal (OpenGL.cpp), the same call the keystone
  # warps, so the frost follows the trapezoid too. That's what makes a docked glass window
  # read as GLASS (background frosted/unreadable) rather than plain see-through. (Keep the
  # window non-`opaque`: shouldBlur() disables blur for opaque/no_blur/RGBX -- Renderer.cpp.)
  routeRules = lib.concatMapStringsSep "\n      " (c:
    ''hl.window_rule({ match = { class = "^(${c})$" }, float = true, size = "33% 88%", move = "66% 8%", opacity = "1.0 1.0", pin = true, border_size = 0, rounding = 0, no_initial_focus = true })''
  ) (cfg.apps ++ [ dockTermClass ]);

  # A Lua set { ["class"] = true, ... } of every dock class, for the window.open
  # handler to recognise a just-opened dock window by class (the rule no longer tags).
  dockClassSet = "{ " + lib.concatMapStringsSep ", " (c: ''["${c}"] = true'') (cfg.apps ++ [ dockTermClass ]) + " }";
in
lib.mkIf (osConfig.my.sidedock.enable && inScope && osConfig.my.desktop.compositor == "hyprland") {
  # Expose the dock on PATH as `sidedock` so OTHER features can drive it without a store-path
  # cross-reference -- features/hakuspace's SUPER+N parks the dock (`sidedock hide`) for the
  # mutually-exclusive notification centre. The dock's own binds still use ${dock} directly; this is
  # just the cross-feature entry point.
  home.packages = [ (pkgs.writeShellScriptBin "sidedock" ''exec ${dock} "$@"'') ];

  # panelbus close handler (features/panelbus): how the dock gets closed when another special window
  # opens. Absolute ${dock} so it runs regardless of the firing context's PATH; `hide` parks the pile.
  # (PiPs deliberately do NOT participate -- a keystone PiP can coexist with the dock/notif.)
  xdg.configFile."panelbus/handlers/dock".text = "${dock} hide";

  wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
      -- Side dock: light apps live on a right-edge panel as a CASCADE STACK.
      -- SUPER+D toggles the pile (show <-> park; parking remembers the front so
      -- the next show restores it). Focused on the dock, SUPER+left/right shift the
      -- pile; SUPER+SHIFT+D toggles the focused window in/out of the dock. Auto-
      -- routed apps (my.sidedock.apps) open at the front of the pile (rule below).
      -- dock.sh places every window BY ADDRESS (never by focusing), so main-area
      -- windows are never disturbed; it only focuses the front, for typing.
      -- Geometry is computed live in dock.sh; the rule literals below must stay in
      -- sync with its front size/position. (The old column-width cycle on D was
      -- removed in features/hyprland; dock windows are also pinned against dragging
      -- there, see the mouse:272 bind.)
      ${routeRules}
      -- SUPER+D toggles the pile (show <-> park). SUPER+SHIFT+D toggles the
      -- FOCUSED window's membership: a normal window is docked, a docked one is
      -- pulled back out.
      hl.bind("${mod} + D", hl.dsp.exec_cmd("${dock} toggle"))
      hl.bind("${mod} + SHIFT + D", hl.dsp.exec_cmd("${dock} dock-toggle"))
      -- SUPER+U: keystone PICTURE-IN-PICTURE. Toggles the focused window into a standalone,
      -- pinned, 3D-tilted mini-card parked bottom-right (reuses the keystone render via the
      -- `dock` tag, but a `pip` tag keeps it out of the cascade pile) -- e.g. a lecture video
      -- while you take notes. Press again on it to drop it back into the tiling layout. (U = a
      -- verified-free key; P/SHIFT+P/ALT+P were play-pause/dpms/pin and V is DMS's clipboard.)
      hl.bind("${mod} + U", hl.dsp.exec_cmd("${dock} pip-toggle"))
      -- 3-finger HORIZONTAL swipe shows/hides the dock: swipe LEFT reveals the pile
      -- (pulled in from the right edge), swipe RIGHT hides it. A Lua-function gesture
      -- (start/update/finish) because the direction picks the verb: accumulate the net
      -- horizontal delta across the swipe and decide on release -- robust whether e.delta
      -- is per-frame or cumulative (the sign of the sum is the dominant direction either
      -- way). The 3-finger VERTICAL workspace swipe is a different axis, so no clash; this
      -- replaced the inert scroll_move gesture (see features/hyprland gesture list). Flip
      -- the `acc < 0` test if the direction feels reversed on the touchpad.
      -- pcall-guarded: this table-action gesture form is only exercised at config load
      -- (relogin), and a bad hl.* call there can blank the whole session (see the Lua
      -- config blackout note). If the API shape is off, the gesture just fails to register
      -- instead of killing the session.
      do
        local acc = 0
        pcall(function()
          hl.gesture({
            fingers = 3,
            direction = "horizontal",
            action = {
              start  = function() acc = 0 end,
              update = function(e) if e and e.delta then acc = acc + (e.delta.x or 0) end end,
              finish = function()
                if acc < 0 then hl.dispatch(hl.dsp.exec_cmd("${dock} show"))
                else            hl.dispatch(hl.dsp.exec_cmd("${dock} hide")) end
              end,
            },
          })
        end)
      end
      -- 4-finger drag is CONTEXT-SENSITIVE: focused ON a dock card it shifts the pile
      -- (left=prev, right=next, same as SUPER+left/right); anywhere else it moves the
      -- focused window (dock.sh gesture-move runs `movewindow <dir>`, the same dwindle
      -- swap the old "move" gesture did). The dominant axis + sign of the accumulated
      -- delta picks l/r/u/d. pcall-guarded like the 3-finger gesture above.
      do
        local ax, ay = 0, 0
        pcall(function()
          hl.gesture({
            fingers = 4,
            direction = "swipe",
            action = {
              start  = function() ax, ay = 0, 0 end,
              update = function(e) if e and e.delta then ax = ax + (e.delta.x or 0); ay = ay + (e.delta.y or 0) end end,
              finish = function()
                local dir
                if math.abs(ax) >= math.abs(ay) then dir = (ax < 0) and "l" or "r"
                else dir = (ay < 0) and "u" or "d" end
                hl.dispatch(hl.dsp.exec_cmd("${dock} gesture-move " .. dir))
              end,
            },
          })
        end)
      end
      -- SUPER+SHIFT+T: a terminal that opens straight into the dock (SUPER+T is
      -- the normal terminal, in features/hyprland). The --class matches the
      -- auto-route rule above, so it floats, size-locks, pins and joins the pile.
      -- No opacity override -- the terminal keeps its normal glass (kitty
      -- background_opacity 0.65). The cascade's per-position WINDOW opacity (1.0 on
      -- top, 0.62 behind, in dock.sh) rides on top of that glass, so the top card is
      -- glass-at-full and cards behind read as clearly more see-through (~0.40).
      hl.bind("${mod} + SHIFT + T", hl.dsp.exec_cmd("kitty --class ${dockTermClass}"))

      -- SUPER + left/right GLOBALLY shift the pile (prev / next), no matter what's
      -- focused -- the earlier focus-conditional proved unreliable. features/hyprland
      -- bound these to movefocus and Hyprland APPENDS duplicate binds, so unbind those
      -- first (this fragment is mkAfter, so it runs after that bind), then bind the
      -- shift. The exec_cmd dispatcher is bound DIRECTLY (same shape as SUPER+D above,
      -- no function wrapper) so there is no dispatcher-call issue; the script no-ops
      -- safely when the dock is empty/hidden/single. Arrow focus-move is given up on
      -- these two keys (SUPER+up/down and the h/l binds still move focus).
      hl.unbind("${mod} + left")
      hl.unbind("${mod} + right")
      hl.bind("${mod} + left",  hl.dsp.exec_cmd("${dock} prev"))
      hl.bind("${mod} + right", hl.dsp.exec_cmd("${dock} next"))

      -- Keep the cascade in sync as dock windows come and go: opening a dock window
      -- brings it to the front and re-flows the pile; closing one re-flows the rest.
      -- Both fire for EVERY window, so each is filtered. OPEN is filtered by CLASS
      -- (the rule no longer tags, so a fresh dock window has no tag yet -- dock.sh
      -- 'adopt' applies the dynamic tag); CLOSE is filtered by the (now dynamic) tag,
      -- so a window the user has UNDOCKED -- tag removed -- correctly isn't re-flowed.
      do
        local dockClasses = ${dockClassSet}
        local function isDockTagged(w)
          local hit = false
          pcall(function()
            if w and w.tags then
              for _, t in ipairs(w.tags) do if t == "dock" or t == "dock*" then hit = true; break end end
            end
          end)
          return hit
        end
        hl.on("window.open",  function(w) if w and w.class and dockClasses[w.class] then hl.dispatch(hl.dsp.exec_cmd("${dock} adopt "  .. w.address)) end end)
        hl.on("window.close", function(w) if isDockTagged(w) then hl.dispatch(hl.dsp.exec_cmd("${dock} orphan " .. w.address)) end end)
        -- AUTO-ADJUST on a live display change: when the monitor layout/scale changes
        -- (e.g. you set a new scale in wdisplays), re-apply the dock geometry from the
        -- fresh viewport so it tracks the new screen size WITHOUT a keypress. dock.sh
        -- 'relayout' re-cascades if shown, re-parks (at the new logical edge) if hidden.
        hl.on("monitor.layout_changed", function()
          hl.dispatch(hl.dsp.exec_cmd("${dock} relayout"))
          -- Paint a newly-added output (e.g. opendisplay virtual monitor) so it's not gray.
          hl.dispatch(hl.dsp.exec_cmd("${wallpaperRefresh}"))
        end)
      end
  '';
}
