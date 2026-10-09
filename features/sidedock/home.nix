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

  # Wine/KakaoTalk "폴더 열기" (open/reveal folder) spawns `explorer.exe /select,<winpath>` DIRECTLY
  # -- it bypasses the Directory shell association (Wine's shell32 hardcodes explorer.exe for folders),
  # so a registry redirect can't catch it (verified live: cmdline was
  # `explorer.exe /select,Z:\home\benjamin\Downloads\CALC2_MID.pdf`). So catch the explorer.exe WINDOW
  # on open (hl.on below), pull the path from /proc/<pid>/cmdline, convert the Wine path to Unix via the
  # prefix's dosdevices symlinks (Z: -> /, C: -> drive_c, ...), CLOSE the Wine window, and reveal the
  # file in the NATIVE file manager (dolphin --select; xdg-open the dir as fallback). Guards: skip the
  # `/desktop` shell explorer and any explorer.exe with no path arg (e.g. the tray), so only real folder
  # windows are redirected.
  folderToDolphin = pkgs.writeShellScript "wine-folder-to-dolphin" ''
    export PATH=${lib.makeBinPath [ osConfig.programs.hyprland.package pkgs.jq pkgs.coreutils pkgs.gnused pkgs.kdePackages.dolphin pkgs.xdg-utils ]}''${PATH:+:$PATH}
    PFX="$HOME/.local/share/wineprefixes/kakaotalk"
    addr="$1"
    pid=$(hyprctl clients -j | jq -r --arg a "$addr" 'first(.[]|select(.address==$a)).pid // empty')
    [ -n "$pid" ] || exit 0
    cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$cl" in *desktop*) exit 0 ;; esac            # the Wine desktop shell -- never touch it
    case "$cl" in *explorer.exe*) : ;; *) exit 0 ;; esac
    arg="''${cl#*explorer.exe }"                         # strip up to "explorer.exe "
    arg="''${arg#/select,}"                              # drop the /select, prefix if present
    arg="$(printf '%s' "$arg" | sed 's/[[:space:]]*$//')"
    [ -n "$arg" ] || exit 0                             # no path (tray / bare shell) -> leave it
    drive="$(printf '%s' "$arg" | cut -c1 | tr '[:upper:]' '[:lower:]')"
    rest="$(printf '%s' "''${arg#?:}" | tr '\\' '/')"   # "\a\b" -> "/a/b"
    base="$(readlink -f "$PFX/dosdevices/$drive:" 2>/dev/null)"
    [ -n "$base" ] || exit 0
    u="$(readlink -m "$base/$rest" 2>/dev/null)"
    [ -n "$u" ] || exit 0
    hyprctl dispatch "hl.dsp.window.close({window=\"address:$addr\"})" >/dev/null 2>&1
    if [ -e "$u" ]; then setsid dolphin --select "$u" >/dev/null 2>&1 &
    else d="$(dirname "$u")"; [ -d "$d" ] && setsid xdg-open "$d" >/dev/null 2>&1 & fi
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
  # NB: do NOT add suppress_event = "activate" here. It maps to SUPPRESS_ACTIVATE (Window.cpp),
  # which the aim was to stop an XWayland/Wine back-of-pile card (KakaoTalk) self-raising to the
  # FRONT and desyncing the cascade -- BUT SUPPRESS_ACTIVATE also blocks the window's OWN raise
  # when it restores from the system tray, so KakaoTalk's window never appeared ("doesn't work",
  # 2026-10-08). The dock already re-asserts z-order (deepest->front) on every render, so a
  # spontaneous self-raise (e.g. an incoming message) is a transient the next dock interaction
  # corrects -- a far smaller cost than the app being unopenable. (If it ever gets annoying, add a
  # window-activate HOOK that re-runs the dock z-order for dock windows -- never a blanket suppress.)
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
      -- The 3-finger HORIZONTAL pile show/hide is now a CONTINUOUS compositor gesture (action
      -- "dockpile" in features/hyprland's gesture list -> CDockPileTrackpadGesture), replacing the
      -- old one-shot Lua-function that only decided the verb on release. Its release command is wired
      -- below (dock_pile_exec). No more per-frame Lua, so the Lua-config-blackout risk is gone too.
      -- 4-finger drag = the built-in MOVE gesture (registered in features/hyprland's gesture list),
      -- made CONTINUOUS by trapezoid.patch's CMoveTrackpadGesture: a drag that starts on a pile card
      -- slides THAT card live under the finger and, on release, runs gestures:dock_swipe_exec below
      -- -> dock.sh gesture-move (l/r cycle the pile, none = spring back). A drag anywhere else moves
      -- the focused window normally. This replaced the old one-shot Lua-function 4-finger gesture.
      hl.config({ gestures = { dock_swipe_exec = "${dock} gesture-move", dock_pile_exec = "${dock} gesture-pile" } })
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
        -- Only adopt a REAL top-level window. Wine apps (KakaoTalk) open tooltips / alt-text labels /
        -- menus / dropdowns as separate windows that SHARE the exe class -- so without this filter the
        -- dock cascades each one and the pile reshuffles ("really small kakaotalk windows ... the dock
        -- has to shift"). Reject: too small (a tooltip is barely a line), passive (accepts_input==false,
        -- a label), OR UNTITLED. The title is the key discriminator -- a real window carries a contact/
        -- account name ("이시후", "KakaoTalk"); a popup/menu has an EMPTY title (verified live: a 321x244
        -- popup had none, the chat window did). pcall-guarded, defaulting to ADOPT if the fields can't be
        -- read, so a real window is never wrongly dropped.
        local function dockable(w)
          local ok, skip = pcall(function()
            local s = w.size or {}
            local titled = type(w.title) == "string" and #w.title > 0
            return (s.x or 999) < 120 or (s.y or 999) < 120 or w.accepts_input == false or (not titled)
          end)
          return not (ok and skip)
        end
        hl.on("window.open",  function(w)
          -- TEMP DIAG (remove once the popup filter is confirmed): log what dockable() decides for every
          -- kakaotalk.exe window, so a TITLED popup that still shifts the dock can be caught. /tmp/dock-adopt.log
          if w and w.class == "kakaotalk.exe" then pcall(function()
            local s = w.size or {}
            local msg = "KAKAO sz=" .. tostring(s.x) .. "x" .. tostring(s.y) .. " ai=" .. tostring(w.accepts_input)
              .. " float=" .. tostring(w.floating) .. " titlelen=" .. tostring(#tostring(w.title or "")) .. " dockable=" .. tostring(dockable(w))
            hl.dispatch(hl.dsp.exec_cmd("printf '%s\\n' '" .. msg .. "' >> /tmp/dock-adopt.log"))
          end) end
          if w and w.class and dockClasses[w.class] and dockable(w) then hl.dispatch(hl.dsp.exec_cmd("${dock} adopt "  .. w.address)) end
        end)
        hl.on("window.close", function(w) if isDockTagged(w) then hl.dispatch(hl.dsp.exec_cmd("${dock} orphan " .. w.address)) end end)
        -- Wine/KakaoTalk "open folder" -> redirect its explorer.exe window to the NATIVE file manager
        -- (dolphin), see folderToDolphin in the let. Fires for every explorer.exe window; the script
        -- itself filters out the /desktop shell + the tray (anything with no folder path in its cmdline).
        hl.on("window.open", function(w) if w and w.class == "explorer.exe" then hl.dispatch(hl.dsp.exec_cmd("${folderToDolphin} " .. w.address)) end end)
        -- KEEP THE DOCK ON ITS HOME MONITOR across workspace switches. The pile is pinned, and
        -- Hyprland's pin follows the active workspace on EVERY monitor -- so switching a workspace on
        -- another screen drags the dock across ("flies across screens"). On each workspace change,
        -- dock.sh 'rehome' re-renders the pile onto its own (rightmost) monitor WITHOUT stealing
        -- focus, and no-ops when it's hidden or already home (a home-monitor switch, which pin handles
        -- right, does nothing). Cheap + self-filtering, same as the open/close handlers above.
        hl.on("workspace.active", function() hl.dispatch(hl.dsp.exec_cmd("${dock} rehome")) end)
        -- NB: Wine windows "popping up from the back of the pile" is fixed in the COMPOSITOR, not here.
        -- An earlier window.active/window.urgent -> restack hook FLASHED (it un-popped after the client
        -- had already raised the card) and missed the X11-configure-request raise entirely (no Lua event
        -- fires for it, so a card "stayed out until we sift the dock"). The real fix: Window.cpp now
        -- SKIPS the client-driven raise (activate / onX11ConfigureRequest / onMap) for dock-tagged
        -- windows, so only the dock's own alter_zorder ever restacks them. See [[kakaotalk-wine-setup]].
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
