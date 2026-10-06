{ lib
, stdenv
, fetchFromGitHub
, cmake
, pkg-config
, qt6
, kdePackages
, pipewire
, avahi
, libusbmuxd
, wayland
, ffmpeg
, libdrm
}:

# opendisplay-linux (tixwho fork) -- use an iPhone/iPad as an extra Wayland display. The
# Linux SENDER: captures via PipeWire + xdg-desktop-portal, H.264-encodes, streams to the
# upstream iOS receiver over Wi-Fi (Avahi) or USB (usbmuxd). CLI `opendisplay-linux` + an
# experimental Kirigami GUI `opendisplay-gui`. Packaged (not the Arch PKGBUILD) so it links
# against nixpkgs libs with the right rpath and finds ffmpeg at runtime.
#
# RUNTIME (separate from this build -- enable as NixOS services / they're already present on
# Hyprland): pipewire, xdg-desktop-portal + xdg-desktop-portal-hyprland (screencast),
# services.avahi (Wi-Fi discovery), services.usbmuxd (USB). Hardware H.264 (h264_vaapi) also
# needs the GPU VAAPI driver; else it falls back to software libx264.
stdenv.mkDerivation (finalAttrs: {
  pname = "opendisplay-linux";
  version = "1.14.0-unstable-2026-10-03";

  # Benjamin's own fork, not tixwho's. The portal/output-controller fixes and
  # the capture/encode rework that used to be carried here as a local patch
  # are committed in the fork now, so this builds straight from source with
  # nothing applied on top. Bump rev + hash to update.
  src = fetchFromGitHub {
    owner = "sihooleebd";
    repo = "opendisplay-linux";
    rev = "96a847a411c72df3fda7698d2f587813744ae0f1"; # branch linux-port HEAD
    hash = "sha256-zzeWNVCZHUR5XZ7I7fXPyekVGE6kcykmGoe1N4lrdLY=";
  };

  # The CMake project is the Linux/ subtree (upstream builds with `cmake -S opendisplay/Linux`).
  # cmakeDir is resolved relative to the BUILD dir (cmakeBuildDir = ./build), so "../Linux".
  cmakeDir = "../Linux";

  nativeBuildInputs = [ cmake pkg-config qt6.wrapQtAppsHook ];

  buildInputs = [
    qt6.qtbase # Core/DBus/Gui + Widgets
    qt6.qtdeclarative # Quick/Qml/QuickControls2 (GUI)
    qt6.qtwayland
    kdePackages.kirigami # KF6Kirigami (GUI)
    kdePackages.libkscreen # KF6Screen (core, REQUIRED)
    pipewire # libpipewire-0.3
    avahi # avahi-client
    libusbmuxd # libusbmuxd-2.0
    wayland # wayland-client

    # LINKED, not just spawned (see the PATH wrapper below, which is still
    # needed). The VA-API path now encodes in-process through libavcodec /
    # libavfilter / libavutil instead of piping raw frames to an ffmpeg
    # subprocess, and imports the compositor's DMA-BUF straight into a VA-API
    # surface -- which is what libdrm's drm_fourcc.h describes.
    ffmpeg
    libdrm
  ];

  cmakeFlags = [
    "-DOPENDISPLAY_BUILD_GUI=ON"
    "-DBUILD_TESTING=OFF"
  ];

  # ffmpeg is ALSO still spawned as a binary (popen/execvp "ffmpeg ...", see
  # Linux/src/ffmpeg_encoder.cpp), so it must be on PATH as well as linked. That path is no
  # longer the default -- VA-API now encodes in-process -- but it remains the fallback for
  # NVENC, for libx264, and for any machine where opening a VA-API device fails, so dropping
  # the wrapper would strand those hosts. (Hardware encoders still need the system GPU
  # driver; libx264 is the software fallback.)
  qtWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath [ ffmpeg ]}" ];

  meta = {
    description = "Use an iPhone/iPad as an additional Wayland display (Linux sender; KDE + Hyprland)";
    homepage = "https://github.com/tixwho/opendisplay-linux";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "opendisplay-linux";
  };
})
