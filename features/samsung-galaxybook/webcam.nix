# Galaxy Book4 Pro 360 — IPU6 + libcamera (webcam-fix-libcamera).
# Ports upstream install.sh + patterns from nixos/webcam-fix-book5.nix.
# https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes

{ inputs, config, lib, pkgs, ... }:

let
  fixes = inputs.feat-samsung-galaxybook.fixes;
  kernelPackages = config.boot.kernelPackages;
  kernel = kernelPackages.kernel;
  kernelUsesClang = kernel.stdenv.cc.isClang or false;
  isCross = !pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
  cc = if kernelUsesClang then pkgs.llvmPackages.clang-unwrapped else pkgs.stdenv.cc;
  clangMakeFlags =
    lib.optionalString kernelUsesClang "LLVM=1 CC=${cc}/bin/clang LD=${pkgs.llvmPackages.lld}/bin/ld.lld";
  # In cross builds the kernel Makefile defaults to CC=$(CROSS_COMPILE)gcc with empty
  # CROSS_COMPILE, falling back to bare 'gcc' which is not in PATH. Pass CC explicitly.
  gccMakeFlags =
    lib.optionalString (!kernelUsesClang && isCross) "CC=${cc}/bin/${pkgs.stdenv.cc.targetPrefix}gcc";

  ivscModules = [
    "mei-vsc"
    "mei-vsc-hw"
    "ivsc-ace"
    "ivsc-csi"
  ];

  ipuBridgeModule = pkgs.stdenvNoCC.mkDerivation {
    pname = "ipu-bridge-fix";
    version = "1.4-${kernel.modDirVersion}";
    src = "${fixes}/webcam-fix-book5/ipu-bridge-fix";
    nativeBuildInputs = [ kernel.dev cc pkgs.gnumake pkgs.perl ]
      ++ lib.optionals kernelUsesClang [ pkgs.llvmPackages.lld ];
    buildPhase = ''
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
        M=$PWD modules ${clangMakeFlags} ${gccMakeFlags}
    '';
    installPhase = ''
      install -Dm644 ipu-bridge.ko $out/lib/modules/${kernel.modDirVersion}/extra/ipu-bridge.ko
    '';
    meta = with lib; {
      description = "Samsung ipu-bridge rotation fix (Galaxy Book4 360 / NP960QGK)";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  /*
    ov02c10 fails to probe entirely on this board: dmesg shows
    "error -EINVAL: external clock 26000000 is not supported" / "probe with
    driver ov02c10 failed with error -22". The in-tree driver only accepts
    19.2 MHz; this board's IPU6 clocks the sensor at 26 MHz. Without a
    successful probe there's no v4l2 subdevice at all, so libcamera's Simple
    pipeline handler reports "No sensor found for /dev/media0" and
    camera-relay's gstreamer pipeline has nothing real to capture (produces a
    synthetic black frame instead of erroring). Same fix as ov02c10-26mhz-fix's
    DKMS module — patched source accepts both 19.2 MHz and 26 MHz. Out-of-tree
    modules in extra/ take priority over the in-tree kernel/ one in depmod's
    search order, same mechanism the DKMS variant relies on via /updates.
  */
  ov02c10Fix = pkgs.stdenvNoCC.mkDerivation {
    pname = "ov02c10-26mhz-fix";
    version = "1.0-${kernel.modDirVersion}";
    src = "${fixes}/ov02c10-26mhz-fix";
    nativeBuildInputs = [ kernel.dev cc pkgs.gnumake pkgs.perl ]
      ++ lib.optionals kernelUsesClang [ pkgs.llvmPackages.lld ];
    buildPhase = ''
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
        M=$PWD modules ${clangMakeFlags} ${gccMakeFlags}
    '';
    installPhase = ''
      install -Dm644 ov02c10.ko $out/lib/modules/${kernel.modDirVersion}/extra/ov02c10.ko
    '';
    meta = with lib; {
      description = "ov02c10: accept 26 MHz external clock in addition to 19.2 MHz";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  cameraRelayMonitor = pkgs.stdenv.mkDerivation {
    pname = "camera-relay-monitor";
    version = "1.0";
    src = "${fixes}/camera-relay";
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      $CC -O2 -Wall -o camera-relay-monitor camera-relay-monitor.c
    '';
    installPhase = ''
      install -Dm755 camera-relay-monitor $out/bin/camera-relay-monitor
    '';
  };

  cameraRelayRuntimeInputs = with pkgs; [
    bash
    coreutils
    findutils
    gawk
    gnugrep
    gnused
    kmod
    procps
    systemd
    util-linux
    libcamera
    v4l-utils
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
  ];

  cameraRelay = pkgs.stdenvNoCC.mkDerivation {
    pname = "camera-relay";
    version = "1.0";
    src = "${fixes}/camera-relay";
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontConfigure = true;
    dontFixup = true;
    installPhase = ''
      install -Dm755 camera-relay $out/share/camera-relay/camera-relay
      substituteInPlace $out/share/camera-relay/camera-relay \
        --replace-fail "/usr/local/bin/camera-relay-monitor" "${cameraRelayMonitor}/bin/camera-relay-monitor" \
        --replace-fail "/usr/local/bin/camera-relay" "$out/bin/camera-relay"
      mkdir -p $out/bin
      makeWrapper $out/share/camera-relay/camera-relay $out/bin/camera-relay \
        --prefix PATH : ${lib.makeBinPath cameraRelayRuntimeInputs} \
        --set LIBCAMERA_IPA_MODULE_PATH ${pkgs.libcamera}/lib/libcamera/ipa \
        --prefix GST_PLUGIN_PATH : ${lib.makeSearchPath "lib/gstreamer-1.0" [ pkgs.libcamera ]} \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libcamera ]}
    '';
  };

  libcameraEnv = {
    LIBCAMERA_IPA_MODULE_PATH = "${pkgs.libcamera}/lib/libcamera/ipa";
    GST_PLUGIN_PATH = lib.makeSearchPath "lib/gstreamer-1.0" [ pkgs.libcamera ];
    LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.libcamera ];
    /*
      kamoso builds its own GStreamer pipeline directly (confirmed via ldd on
      the real binary — links libgstreamer/libgstbase/libgstvideo, no
      libQt6Multimedia.so at all) and its autoplugger picks `libcamerasrc`
      (direct sensor access) over `pipewiresrc` (through camera-relay) when
      choosing a Video/Source element. libcamerasrc's viewfinder stream
      negotiates ABGR8888 with a garbage/unset alpha channel, causing the live
      preview to render transparent or black (still-capture uses a different,
      alpha-free format, which is why photos work fine). Deprioritizing
      libcamerasrc's rank makes GStreamer's autoplugger prefer pipewiresrc
      instead, which goes through our relay's alpha-free YUY2 output. Scoped
      to GStreamer's own element selection only — doesn't touch Qt, audio, or
      anything outside camera-source autoplugging.
    */
    GST_PLUGIN_FEATURE_RANK = "libcamerasrc:0";
  };

  wireplumberLuaRule = ''
    rule = {
      matches = {
        {
          { "node.name", "matches", "v4l2_input.pci-0000_00_05*" },
        },
      },
      apply_properties = {
        ["node.disabled"] = true,
      },
    }
    table.insert(v4l2_monitor.rules, rule)
  '';

  wireplumberConfRule = ''
    monitor.v4l2.rules = [
      {
        matches = [
          { node.name = "~v4l2_input.pci-0000_00_05*" }
        ]
        actions = {
          update-props = {
            node.disabled = true
          }
        }
      }
    ]
  '';

  wireplumberUsesConf = lib.versionAtLeast (pkgs.wireplumber.version or "0.5") "0.5";
in
lib.mkIf config.my.samsung-galaxybook.enable {
  nixpkgs.overlays = [
    (final: prev: {
      libcamera = prev.libcamera.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          HELPER_FILE=""
          for candidate in src/ipa/libipa/camera_sensor_helper.cpp \
                           src/libcamera/sensor/camera_sensor_helper.cpp; do
            if [ -f "$candidate" ]; then
              HELPER_FILE="$candidate"
              break
            fi
          done
          if [ -n "$HELPER_FILE" ]; then
            if ! grep -q 'CameraSensorHelperOv02c10' "$HELPER_FILE"; then
              sed -i '/#endif.*__DOXYGEN__/i\
          class CameraSensorHelperOv02c10 : public CameraSensorHelper\
          {\
          public:\
          \tCameraSensorHelperOv02c10()\
          \t{\
          \t\tgain_ = AnalogueGainLinear{ 1, 0, 0, 16 };\
          \t}\
          };\
          REGISTER_CAMERA_SENSOR_HELPER("ov02c10", CameraSensorHelperOv02c10)\
          ' "$HELPER_FILE"
            fi
          fi
        '';
        postInstall = (old.postInstall or "") + ''
          install -Dm644 ${fixes}/webcam-fix-libcamera/ov02c10.yaml \
            $out/share/libcamera/ipa/simple/ov02c10.yaml
          # The upstream tuning file's Ccm block (boost R/B 1.05x, cut G to 0.92x)
          # was calibrated against someone else's unit that ran green; on this
          # unit it overshoots into magenta instead. Confirmed by testing with
          # LIBCAMERA_IPA_CONFIG_PATH pointed at a copy with the Ccm block
          # removed — tint fixed. Drop just the Ccm algorithm entry.
          sed -i '/- Ccm:/,/-0.01, -0.02,  1.05 \]/d' \
            $out/share/libcamera/ipa/simple/ov02c10.yaml
        '';
      });
    })
  ];

  boot.initrd.kernelModules = ivscModules;

  boot.kernelModules = ivscModules ++ [
    "ipu-bridge"
    "v4l2loopback"
  ];

  boot.extraModulePackages = [
    ipuBridgeModule
    ov02c10Fix
    kernelPackages.v4l2loopback
  ];

  environment.systemPackages = [
    cameraRelay
    pkgs.libcamera
    pkgs.v4l-utils
  ];

  environment.sessionVariables = libcameraEnv;

  # Keyed off the primary account rather than a literal: `users.users.<n>.X`
  # DECLARES the user, so a literal name here creates a stray half-defined
  # account on any host where that person does not exist.
  users.users.${config.my.internal.primaryUser}.extraGroups = [ "kvm" ];

  programs.firefox.preferences = {
    "media.webrtc.camera.allow-pipewire" = true;
  };

  # Do not use environment.etc for udev/rules.d/* — systemd already owns etc/udev/rules.d
  # as a symlink tree; nesting another rules file there fails on remote builders.
  services.udev.extraRules = lib.mkAfter ''
    SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU6 ISYS Capture*", TAG-="uaccess"
    SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU6 CSI2*", TAG-="uaccess"
  '';

  environment.etc = {
    "modules-load.d/ivsc.conf".text = lib.concatStringsSep "\n" ivscModules + "\n";

    "modprobe.d/ivsc-camera.conf".text = ''
      softdep ov02c10 pre: mei-vsc mei-vsc-hw ivsc-ace ivsc-csi
    '';

    "modprobe.d/99-camera-relay-loopback.conf".text = ''
      # width/height/max_*: without a fixed format declared at module load,
      # the loopback device has no known capability until the on-demand relay
      # actually starts producing frames. PipeWire enumerates a device's
      # formats once when it discovers the node; if that happens while the
      # relay is idle, it caches an empty format list and every future
      # consumer (cheese, any PipeWire-based app) fails permanently with
      # "no more input formats", even after the relay starts. Declaring a
      # fixed format up front matches what camera-relay-monitor always
      # produces (1920x1080) regardless of on-demand state.
      options v4l2loopback devices=1 exclusive_caps=0 card_label="Camera Relay" width=1920 height=1080 max_width=1920 max_height=1080
    '';
  }
  // lib.optionalAttrs wireplumberUsesConf {
    "wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf".text = wireplumberConfRule;
  }
  // lib.optionalAttrs (!wireplumberUsesConf) {
    "wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua".text = wireplumberLuaRule;
  };

  systemd.user.services.camera-relay = {
    description = "Camera Relay (on-demand libcamera to v4l2loopback)";
    after = [ "pipewire.service" "wireplumber.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${cameraRelay}/bin/camera-relay start --on-demand";
      ExecStop = "${cameraRelay}/bin/camera-relay stop";
      Restart = "on-failure";
      RestartSec = 5;
    };
    environment = libcameraEnv;
  };

  systemd.user.services.pipewire.environment = libcameraEnv;
  systemd.user.services.wireplumber.environment = libcameraEnv;
}
