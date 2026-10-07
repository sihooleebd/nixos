{ config, lib, pkgs, osConfig, ... }:
let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "panelbus"; };
in
lib.mkIf (osConfig.my.panelbus.enable && inScope) {
  # Put `panelbus` on the user PATH for general/interactive use. Participating features additionally
  # reference osConfig.my.panelbus.package directly in their own PATHs (dock wrapper, quickshell
  # service) so the broadcast fires even in contexts that don't inherit the login session PATH.
  home.packages = [ osConfig.my.panelbus.package ];
}
