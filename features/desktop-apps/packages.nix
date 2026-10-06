# GUI applications and the icon/theme packages they resolve against.
{ pkgs }:
let
  lib = pkgs.lib;
  # At this host's fractional DOWNSCALE (primary output scale 0.8), Chromium/Electron apps whose
  # fractional-scale path (WaylandFractionalScaleV1, ON by default) build a physical-sized buffer
  # but fill only the scale-FRACTION of their window -- so they render into the top-left ~0.8 of the
  # frame ("smaller than the screen"). Disabling the feature drops Chromium to integer
  # buffer_scale=1: it renders at the LOGICAL window size and Hyprland downscales the whole window
  # -> full-bleed at any scale. Same fix features/claude-desktop bakes into its own wrapper (see the
  # claude-desktop-fractional-scale note). Two mechanisms, because the launch path differs per app:
  #   - google-chrome has a native `commandLineArgs` hook AND its .desktop Exec is an ABSOLUTE store
  #     path, so a symlinkJoin wrapper would be bypassed -- the .override regenerates both the binary
  #     and the .desktop, so rofi/menu launches pick up the flag.
  #   - discord has no such hook and a PATH-resolved bare `Exec=Discord`, so a thin
  #     symlinkJoin+wrapProgram over its binaries IS what the launcher/rofi resolve and run.
  noFracScale = pkg: bins: pkgs.symlinkJoin {
    name = "${lib.getName pkg}-nofracscale";
    paths = [ pkg ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = lib.concatMapStringsSep "\n"
      (b: ''wrapProgram $out/bin/${b} --add-flags "--disable-features=WaylandFractionalScaleV1"'')
      bins;
  };
in
{
  system = with pkgs; [
    libreoffice
    rnote
    (google-chrome.override { commandLineArgs = "--disable-features=WaylandFractionalScaleV1"; })
    (noFracScale discord [ "discord" "Discord" ])
    zoom-us
    poppler-utils

    kdePackages.dolphin
    # kdeconnect-kde is installed by programs.kdeconnect, enabled from
    # features/network -- listing it here too would install it independently of
    # the firewall ranges it needs, which is how it came to be half-configured.
    kdePackages.qt6ct
    kdePackages.breeze-icons
    adwaita-icon-theme
    bibata-cursors
  ];
}
