{ lib, config, pkgs, ... }:
let
  # panelbus -- a broadcast-on-open mutual-exclusion bus for "special" windows (dock, pin, notif, ...).
  #
  # Each participating window declares a CLOSE command as a shell snippet in
  #   ~/.config/panelbus/handlers/<name>
  # (dropped by that window's own feature, so features stay decoupled -- nobody hard-codes who else
  # exists). The OPEN motion of a window calls `panelbus open <name>`, which fires every OTHER handler.
  #
  # Each handler runs DETACHED (setsid -f) and TIME-CAPPED (timeout): a close that blocks instead of
  # failing -- e.g. `swaync-client -cp` with no daemon prints "Will wait for connection..." forever --
  # can neither hang the opener nor linger. (That exact hang is what used to freeze SUPER+D.)
  #
  # Scaling to an Nth special window is one new handler file + one `panelbus open <name>` on its open
  # path. The opener never names the others; the registry is the contract.
  panelbus = pkgs.writeShellScriptBin "panelbus" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux ]}''${PATH:+:$PATH}
    DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/panelbus/handlers"
    case "''${1:-}" in
      open)
        me="''${2:-}"
        [ -n "$me" ] || { echo "panelbus: 'open' needs a panel name" >&2; exit 2; }
        [ -d "$DIR" ] || exit 0
        for h in "$DIR"/*; do
          [ -e "$h" ] || continue                      # no handlers registered yet -> nothing to close
          [ "$(basename "$h")" = "$me" ] && continue   # never close the panel that is opening
          # detached + capped: a hanging close can neither block us nor outlive its 2s budget.
          setsid -f timeout 2 sh -c "$(cat "$h")" >/dev/null 2>&1 || true
        done ;;
      list) ls -1 "$DIR" 2>/dev/null || true ;;        # registered panels (debugging)
      *) echo "usage: panelbus open <name> | panelbus list" >&2; exit 2 ;;
    esac
  '';
in
{
  options.my.panelbus = {
    enable = lib.mkEnableOption ''
      panelbus: a broadcast-on-open mutual-exclusion bus for "special" windows (dock, pin, notif).
      Opening any one fires the registered close command of every other, so they never overlap.
      Generalises to N windows: drop a close snippet in ~/.config/panelbus/handlers/<name> and call
      `panelbus open <name>` on that window's open path'';
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = panelbus;
      defaultText = lib.literalExpression ''pkgs.writeShellScriptBin "panelbus" "..."'';
      description = ''
        The panelbus CLI. Features that participate add this to the PATH of whatever context fires the
        broadcast (a wrapper's makeBinPath, a service ExecStart) so `panelbus` resolves without relying
        on the login-time session PATH.'';
    };
    users = import ../../lib/user-scope.nix { inherit lib config; };
  };
}
