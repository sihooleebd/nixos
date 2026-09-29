{ config, lib, pkgs, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "sidedock"; };
  cfg = osConfig.my.sidedock;
  mod = osConfig.my.hyprland.modKey;

  # dock.sh is a plain file (no Nix-escaping headaches); this thin wrapper just puts
  # hyprctl + jq on its PATH. hyprctl comes from the RUNNING compositor's own
  # package so the IPC protocol always matches.
  dock = pkgs.writeShellScript "sidedock" ''
    export PATH=${lib.makeBinPath [ osConfig.programs.hyprland.package pkgs.jq pkgs.coreutils ]}''${PATH:+:$PATH}
    exec ${pkgs.writeShellScript "sidedock-impl" (builtins.readFile ./dock.sh)} "$@"
  '';

  # The dock's own throwaway terminal: SUPER+SHIFT+T spawns a kitty under this
  # class, which the auto-route rule below catches so it opens straight into the
  # pile (SUPER+T stays the normal, main-area terminal -- see features/hyprland).
  dockTermClass = "sidedock-term";

  # One auto-route rule per docked app: open floating at the dock size, at the
  # panel's FRONT position and opaque (so it's the visible top of the cascade, not
  # vanished off-screen), size-LOCKED via min==max (so it can't be resized), PINNED
  # (shown on every workspace, so the dock follows the live workspace), tagged
  # 'dock', WITHOUT grabbing focus. The literals must match dock.sh's live geometry:
  # 640x928 front at 1266,104 (640-wide panel, 48px top/bottom + 14px side insets,
  # below a 56px waybar on 1920x1080). dock.sh re-lays the whole cascade (position,
  # opacity, z-order, pin) on the next SUPER+D. SUPER+SHIFT+D tucks the pile away.
  # cfg.apps are the user's docked apps; dockTermClass is the feature's own terminal.
  routeRules = lib.concatMapStringsSep "\n      " (c:
    ''hl.window_rule({ match = { class = "^(${c})$" }, float = true, size = "640 928", min_size = "640 928", max_size = "640 928", move = "1266 104", opacity = "1.0 1.0", pin = true, border_size = 0, rounding = 0, no_blur = true, no_shadow = true, tag = "+dock", no_initial_focus = true })''
  ) (cfg.apps ++ [ dockTermClass ]);
in
lib.mkIf (osConfig.my.sidedock.enable && inScope && osConfig.my.desktop.compositor == "hyprland") {
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
      -- SUPER+SHIFT+T: a terminal that opens straight into the dock (SUPER+T is
      -- the normal terminal, in features/hyprland). The --class matches the
      -- auto-route rule above, so it floats, size-locks, pins and joins the pile.
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
      -- These fire for every window, so the tag check keeps it to dock windows; the
      -- script does the real work by address.
      do
        local function isDockWin(w)
          local hit = false
          pcall(function()
            if w and w.tags then
              for _, t in ipairs(w.tags) do if t == "dock" or t == "dock*" then hit = true; break end end
            end
          end)
          return hit
        end
        hl.on("window.open",  function(w) if isDockWin(w) then hl.dispatch(hl.dsp.exec_cmd("${dock} adopt "  .. w.address)) end end)
        hl.on("window.close", function(w) if isDockWin(w) then hl.dispatch(hl.dsp.exec_cmd("${dock} orphan " .. w.address)) end end)
      end
  '';
}
