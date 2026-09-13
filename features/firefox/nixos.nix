{ config, lib, pkgs, ... }:

let
  cfg = config.my.firefox;
in
{
  options.my.firefox = {
    enable = lib.mkEnableOption "Firefox";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.firefox-bin;
      defaultText = lib.literalExpression "pkgs.firefox-bin";
      description = ''
        Defaults to the Mozilla binary build rather than the source build: on a
        tuned host the source build is a multi-hour compile for no runtime gain
        this config cares about.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.firefox = {
      enable = true;
      inherit (cfg) package;

      # Force Firefox's file dialogs through the XDG desktop portal, which
      # features/session-services routes to the KDE backend -- so open/save use
      # the same Dolphin-style picker (and it's dark, following the Qt theme)
      # as the rest of the desktop, instead of Firefox's own light GTK chooser.
      # Firefox has its OWN file-picker logic and ignores GTK_USE_PORTAL, so
      # this pref is the only lever. 2 = always (0 = never, 1 = auto, which
      # wasn't biting here).
      preferences = {
        "widget.use-xdg-desktop-portal.file-picker" = 2;
      };
    };
  };
}
