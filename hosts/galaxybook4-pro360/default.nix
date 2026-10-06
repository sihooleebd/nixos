{ inputs, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  system.stateVersion = "26.05";

  # Kernel choice stays in the host file: it is a property of this machine's
  # hardware, not of any feature.
  boot.kernelPackages = pkgs.linuxPackages_7_1;

  my = {
    tuning = {
      # Literal, and it must stay one: flake.nix raw-imports this file to pick
      # between the patched fork and plain upstream nixpkgs before the module
      # system exists. false here would substitute the whole package set from
      # cache.nixos.org instead of building it.
      enable = true;
      march = "meteorlake";
      pseudoCross.enable = true;
      o3.enable = true;
      lto.enable = true;
      upstreamTools.enable = true;
      qtPatches.enable = true;
      refreshTool.enable = true;
    };

    /*
      The people who use this machine. Declaring an account creates it; the
      primary is what every feature's `users` option defaults to.

      extraGroups is written out in full, including the option's own defaults,
      because a definition REPLACES the default rather than merging with it --
      listing only "dialout" here would silently drop wheel and take sudo with
      it. dialout is for arduino-cli/arduino-ide (/dev/ttyACM*, /dev/ttyUSB*).
    */
    users.r0k0r = {
      primary = true;
      extraGroups = [ "wheel" "networkmanager" "video" "audio" "dialout" ];
      # Was /etc/nixos/secrets/hashed-password-r0k0r -- an untracked file that
      # had to exist on the machine before login worked, and in fact did NOT
      # exist here (mutableUsers = true meant the live shadow entry carried
      # the password and the missing file went unnoticed).
      passwordSecret = ../../age/hashed-password-r0k0r.age;
      shell = pkgs.fish;
    };
    upower.enable = true;
    fonts.enable = true;
    keyd.enable = true;
    pipewire.enable = true;
    libinput.enable = true;
    swapfile.enable = true;
    tailscale.enable = true;
    discovery.enable = true;
    locale.enable = true;
    firefox.enable = true;
    fcitx.enable = true;
    openvpn = {
      enable = true;
      profileSecret = ../../age/openvpn-profile.age;
    };
    waydroid.enable = true;
    session-env.enable = true;
    fish = {
      enable = true;
      # r0k0r's login shell is fish (above), so the NixOS module goes on too --
      # it is what links system packages' /share/fish/vendor_* into the profile.
      # Without it completions from system packages are silently absent.
      systemIntegration = true;
    };
    kitty.enable = true;
    starship.enable = true;
    cursor-theme.enable = true;
    ssh = {
      enable = true;
      hosts = {
        yulee = { };
        victus-15 = { };
        note10.Port = 8022;
      };
    };
    opencode.enable = true;
    direnv.enable = true;
    nix-settings.enable = true;
    emacs.enable = true;
    # Package sets, each owning its own list (features/<name>/packages.nix).
    base.enable = true;
    eza.enable = true;
    dev-toolchain.enable = true;
    latex.enable = true;
    media.enable = true;
    astro.enable = true;
    desktop-apps.enable = true;
    arduino.enable = true;
    diagnostics.enable = true;
    qt-dev.enable = true;
    # HWP/HWPX editor. defaultHandler is left at its default (true), so HOP
    # takes application/x-hwp from LibreOffice, which features/desktop-apps also
    # installs -- see the option's own note on why that is a separate decision.
    hop.enable = true;
    samsung-ecosystem = {
      enable = true;
      budsStartUp = true;
    };

    claude-code = {
      enable = true;
      shareWithRoot = true;
      gemma.enable = true;
    };

    claude-desktop = {
      enable = true;
      cowork.enable = true;
    };

    remote-builder.client = {
      sshKeySecret = ../../age/remote-builder-ssh-key.age;
      enable = true;
      wrappers.enable = true;
      substituters = [ "ssh://r0k0r@yulee" "ssh://r0k0r@victus-15" ];
      trustedPublicKeys = [
        "yulee-1:KgdwkCN5m+hewJTk+A05PjwI3BbnZAE9NW2n634N7vM="
        "victus-15-1:W5OP8VVbu7Q7z2o5grHJ5Zp+ynm536+QVv+b8fBQJlQ="
      ];
      peers = {
        yulee = {
          maxJobs = 7;
          speedFactor = 10;
          # No gccarch-meteorlake -- see victus-15 below. Neither peer is an
          # Intel machine, and neither is asked to EXECUTE meteorlake code:
          # buildPlatform.canExecute hostPlatform is false here, so build-time
          # tools come from the untuned pkgsBuildBuild set. A peer only ever
          # compiles meteorlake code, which any x86_64 can do.
          features = [ "benchmark" "big-parallel" "kvm" "nixos-test" ];
        };
        victus-15 = {
          maxJobs = 5;
          speedFactor = 4;
          /*
            NO gccarch-meteorlake, on either peer, and the reason is worth
            stating because the feature LOOKS like it should be here.

            Neither peer is Intel: yulee is Zen 5, this one is a Ryzen 5 5600H
            (Zen 3) missing avxvnni, gfni, movdiri and movdir64b outright. But
            advertising the feature would not be a white lie about hardware --
            it would be claiming a capability nothing in this setup needs.

            buildPlatform.canExecute hostPlatform is FALSE here: build and host
            share a config string but differ in gcc.arch, and nixpkgs treats
            that as a real cross build. Build-time tools therefore come from
            the untuned pkgsBuildBuild set and run anywhere. A peer only ever
            COMPILES meteorlake code, never runs it, and any x86_64 can do
            that.

            When a build does run tuned code on a peer -- rusty-v8's mksnapshot
            did, and SIGILLed -- that is a defect in the package's own build
            system smuggling host flags into a build-time tool, not a missing
            builder capability. Fix it there (qtbase's -mwaitpkg strip is the
            precedent), rather than requiring every peer to be an Intel CPU.
          */
          features = [ "benchmark" "big-parallel" "kvm" "nixos-test" ];
        };
      };
    };
    /*
      Goodix GXTP7936 panel. by-path, not eventN: event numbers are assigned in
      probe order and move between boots.
    */
    touch-gestures = {
      enable = true;
      device = "/dev/input/by-path/pci-0000:00:15.1-platform-i2c_designware.1-event";
    };

    /*
      One-offs that do not justify a feature. Literal list -- see
      my.packages.extra's own docs on why lookup.nix cannot read a mkIf here.
    */
    packages.extra.user = with pkgs; [
      yt-dlp
      mpv
      foliate
    ];

    /*
      Bootstrap, done: /etc/agenix/identity.txt holds the private age key
      (root, 0600, outside the flake); its public half is in secrets.nix.
      Back that file up offline -- lose it and every age/*.age in the repo
      is permanently undecryptable, by design.

      CLI note: `agenix -d/-e` does NOT read age.identityPaths, so editing an
      existing secret needs the identity passed explicitly:
        sudo TMPDIR=/run/user/1000 agenix -e age/foo.age -i /etc/agenix/identity.txt
      (TMPDIR because agenix stages cleartext via mktemp, and /tmp here is
      btrfs-on-disk, not tmpfs. Activation itself needs none of this.)
    */
    agenix.enable = true;

    samsung-galaxybook.enable = true;

    power.enable = true;
    flatpak.enable = true;
    flamenco.enable = false;
    easyeffects.enable = true;

    boot = {
      enable = true;
      extraEntries = {
        "windows.conf" = ''
          title Windows
          efi /EFI/Microsoft/Boot/bootmgfw.efi
          sort-key o_windows
        '';
        "netboot.conf" = ''
          title Netboot
          efi /EFI/netboot/netboot.xyz.efi
          sort-key o_netboot
        '';
        "asclepius.conf" = ''
          title Asclepius
          efi /EFI/Asclepius/bootx64.efi
          sort-key o_asclepius
        '';
      };
    };

    # Gnus credentials via agenix -> /run/agenix/authinfo (tmpfs, owner r0k0r).
    # features/_meta asserts my.agenix.enable alongside this.
    emacs.authinfoSecret = ../../age/authinfo.age;

    emacs.font = {
      family = "JetBrainsMonoNL Nerd Font";
      size = 13;
      weight = "semi-light";
    };

    greetd.enable = true;
    qt-theming.enable = true;
    session-services.enable = true;

    desktop = {
      compositor = "hyprland";
      # 2880x1800 internal panel.
      primaryOutput = "eDP-1";
      primaryOutputScale = "1.5";
    };

    dms = {
      enable = true;
      greeter.enable = true;
    };

    network = {
      enable = true;
      kdeconnect.enable = true;
    };
  };

  networking.hostName = "galaxybook4-pro360";

  # Declare the local-Qt6 build capability so packages with
  # requiredSystemFeatures = ["galaxybook-local-qt6"] can build here.
  nix.settings.system-features = [ "galaxybook-local-qt6" ];

  /*
    The buildPlatform/hostPlatform split is NOT declared here. `my.tuning.march`
    above is its single definition (tuning/nixos.nix) -- these two options used
    to be set in both places with identical values, which merged only because
    they agreed.

    Duplicating them is actively unsafe now that tuning is gated: a host-file
    definition sits OUTSIDE `mkIf my.tuning.enable`, so `enable = false` with
    `march = null` would leave a gcc.arch-carrying hostPlatform applied to plain
    upstream nixpkgs -- rebuilding the whole package set with -march while
    looking, from the host file, entirely untuned. One definition, in the module
    that owns the switch.
  */



  /*
    Host-specific overlays only. Everything generic -- the pseudo-cross and
    build-load fixes, o3/LTO, upstream-tools, the i686 escape hatch -- moved to
    tuning/, behind the my.tuning.* switches above. What is left is about this
    machine's hardware and nothing else, which is why it cannot be shared.
  */
  my.tuning.extraOverlays = [
    # niri's own package set, needed wherever the niri compositor is selected.
    inputs.feat-niri.overlay

    # Meteor Lake-P integrated graphics (Intel Arc Graphics, PCI 8086:7d55)
    # is the only GPU on this laptop — no discrete AMD/NVIDIA to support.
    # Mesa's default driver lists build ~24 gallium + ~12 vulkan backends "to
    # support cross tools and emulation use cases"; trim to just what this
    # hardware needs plus a software fallback (llvmpipe/swrast — blender's own
    # test derivation uses mesa.llvmpipeHook, so keep that one rather than
    # dropping software rendering entirely).
    (final: prev: {
      mesa =
        (prev.mesa.override {
          galliumDrivers = [ "iris" "llvmpipe" ];
          vulkanDrivers = [ "intel" "swrast" ];
        }).overrideAttrs
          (old: {
            # nixpkgs' mesa flags assume the full default driver list; with the
            # trim above, three of them break or turn into dead weight (meson
            # takes the LAST occurrence of a -D flag, so appending overrides):
            mesonFlags = (old.mesonFlags or [ ]) ++ [
              # -Dauto_features=enabled force-enables the VA-API state tracker,
              # whose meson require() only accepts r600/radeonsi/nouveau/d3d12/
              # virgl -- hard configure error with iris-only. Intel VA-API is
              # provided by intel-media-driver, not mesa, so nothing is lost.
              "-Dgallium-va=disabled"
              # TFLite delegate hard-links the etnaviv/rocket/ethosu NPU
              # drivers (src/gallium/targets/teflon), all trimmed away.
              "-Dteflon=false"
              # Tools for asahi/panfrost, drivers this machine doesn't build.
              "-Dtools="
            ];
            # The spirv2dxil binary/libs only get built with the d3d12/dozen
            # drivers (trimmed away), and moveToOutput silently no-ops on
            # missing sources -- leaving the declared $spirv2dxil output
            # never created, which Nix rejects ("failed to produce output
            # path"). Same hazard for $cross_tools (pco_clc belongs to the
            # trimmed PowerVR driver). Empty outputs are valid; guarantee
            # they exist.
            postInstall = (old.postInstall or "") + ''
              mkdir -p $spirv2dxil $cross_tools
            '';
          });
    })

    /*
      Fingerprint sensor (USB 1c7a:05a1, Egis Technology "Match-On-Chip") enrolls
      and verifies successfully but forgets the print immediately: upstream
      libfprint's egismoc driver doesn't implement SDCP (Secure Device
      Communication Protocol), which these newer Egis MOC sensors require for
      the enrolled template to actually be committed to the sensor's own
      storage — enrollment silently "succeeds" without ever writing anything.
      TenSeventy7/libfprint-egismoc-sdcp implements SDCP support (device table
      confirms 0x05a1); no other patches needed (nixpkgs' libfprint has no
      patches of its own beyond build-system shebang/cross fixups, and openssl
      — the fork's one new hard dependency for SDCP's crypto handshake — is
      already a buildInput).
    */
    (final: prev: {
      libfprint = prev.libfprint.overrideAttrs (old: {
        src = prev.fetchFromGitHub {
          owner = "TenSeventy7";
          repo = "libfprint-egismoc-sdcp";
          rev = "4d128d4f6f0b46182572126e84df88a73ac27859";
          sha256 = "130b1dap0sxysg3grm5yk3fl7l072qv4vsiv9h6s69ln5gka0gwa";
        };
        # nixpkgs has since grown patches on libfprint, all of them new-hardware
        # USB product IDs (realtek-3274-9003, elan-0c58, elan-04F3-0C9C,
        # focal-077a-079a, focal-a97a) that don't apply to this fork's tree and
        # are for sensors this machine doesn't have (ours is the Egis 1c7a:05a1
        # the fork itself supports). The cross fixups live in postPatch, which
        # this override leaves intact.
        patches = [ ];
      });
    })
  ];
}
