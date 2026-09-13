{ pkgs, lib, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  services.tailscale.enable = true;

  /*
    Laptop system upgrades (plain NixOS options -- machine-appropriate, not
    feature-worthy):

      thermald  Intel's thermal daemon. Proactively manages package temp and
                throttling instead of leaving it to the kernel's reactive
                trip points -- the lever for the build-time heat this machine
                hits when it can't offload.
      fwupd     Firmware/BIOS/SSD/Thunderbolt updates via LVFS; Dell has broad
                coverage. `fwupdmgr refresh && fwupdmgr update` to apply.
      zramSwap  A compressed-RAM swap device, higher priority than the
                features/swapfile 16 GB file (which stays for overflow and
                hibernation). Faster than swapping to the SSD and spares it
                the writes. systemd-oomd (on by NixOS default) still guards
                the hard-pressure case.
  */
  services.thermald.enable = true;
  services.fwupd.enable = true;
  zramSwap.enable = true;

  # Portable microcode. The Latitude is Intel (its hardware-config pulls the
  # Intel blob), but this SSD also gets run on an AMD box -- the HP Victus --
  # while the Latitude is out for repair. amd-ucode rides in the initrd next to
  # intel-ucode; each CPU's early loader applies only its own, so this is free
  # on the Latitude and gives the Ryzen its microcode updates meanwhile.
  hardware.cpu.amd.updateMicrocode = true;

  /*
    Steam. programs.steam (not just the package) is required on NixOS: it wraps
    Steam in its FHS environment, pulls the 32-bit graphics/runtime libraries
    (it flips hardware.graphics.enable32Bit on itself), and installs the udev
    rules for controllers. allowUnfree is already true. Intel iGPU here, so
    expect light games only -- but Steam itself, Proton, and remote play work.
  */
  programs.steam.enable = true;

  /*
    Syncthing, running as benjamin. overrideDevices/overrideFolders = false so
    the pairings and folders added through the web UI (http://localhost:8384)
    are the source of truth -- Nix only turns the daemon on and does not
    reconcile its contents away on the next rebuild. Reachable across the
    tailnet like any other service on this host.
  */
  services.syncthing = {
    enable = true;
    user = "benjamin";
    group = "users";
    dataDir = "/home/benjamin";
    configDir = "/home/benjamin/.config/syncthing";
    overrideDevices = false;
    overrideFolders = false;
  };

  /*
    Caps Lock as the macOS-style language toggle.

    keyd rewrites at the evdev/uinput layer, so a TAP of Caps emits the Hangul
    key -- which features/hyprland already binds to the fcitx keyboard-us <->
    hangul switch (hl.bind("Hangul", ...)) -- and a HOLD past 200ms is a real
    Caps Lock, the "leave it as long press" fallback. Nothing else is remapped.

    my.keyd.enable stays false ON PURPOSE: that feature is the HHKB layout
    (Caps -> Ctrl/Esc, RAlt -> Hangul), a different intent. This is one key,
    so services.keyd is set directly here rather than by flipping on a layout
    this host does not want. keyd applies everywhere -- TTY, greeter,
    compositor -- because it rewrites before any session sees the key.
  */
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      # Plain remap, NOT timeout(hangeul, 200, capslock). The tap-hold macro
      # made keyd hold events for up to 200ms to disambiguate tap vs hold,
      # which (a) delayed the language toggle -- the first key typed after a
      # switch beat the Hangul emit and landed in the old language -- and
      # (b) buffered near-simultaneous keys, reordering them (typing ㅛ then ㅇ
      # arrived as ㅇㅛ and composed to 요). A 1:1 remap emits Hangul the
      # instant Caps is pressed and never buffers. The hold-for-real-capslock
      # is dropped, which is fine: this key is never used for capslock here.
      settings.main.capslock = "hangeul";
    };
  };

  system.stateVersion = "26.05";

  # Kernel choice stays in the host file: it is a property of this machine's
  # hardware, not of any feature.
  boot.kernelPackages = pkgs.linuxPackages_7_1;

  my = {
    /*
      This machine builds nothing.

      `enable = false` makes flake.nix hand it plain upstream nixpkgs, so the
      entire package set substitutes from cache.nixos.org and the only things
      compiled here are the few hundred config-generated derivations every NixOS
      system produces (system-path, etc, units) -- symlink and text assembly, no
      compilers.

      Literal, and it must stay one: flake.nix raw-imports this file to choose
      the nixpkgs input BEFORE the module system exists, so mkIf/mkMerge here
      cannot be resolved. It throws rather than guessing, and an assertion in
      tuning/nixos.nix cross-checks what flake.nix read against what the module
      system evaluated.

      Do NOT reach for `nixpkgs.pkgs = import inputs.nixpkgs-upstream { ... }`
      instead. It cannot work in this config: the nixpkgs module asserts
      `nixpkgs.pkgs is defined -> nixpkgs.config == {}`, and features/nix-settings
      sets allowUnfree while features/emacs sets problems.handlers. It also makes
      nixpkgs.overlays silently ignored. And `march = null` on its own does not
      help either -- the fork patches cc-wrapper's setup-hook.sh, whose bytes are
      a build input, so stdenv's hash moves and everything rebuilds regardless of
      the tuning switches.
    */
    tuning.enable = false;

    /*
      The person who uses this machine. Declaring an account creates it, and the
      primary is what every feature's `users` option defaults to -- so benjamin
      gets the accounts's packages and the home-manager side of every feature
      enabled below, with no feature naming him anywhere.
    */
    users.benjamin = {
      primary = true;
      description = "Benjamin S.H. Lee";
    };

    upower.enable = true;
    fonts.enable = true;
    keyd.enable = false;
    pipewire.enable = true;
    libinput.enable = true;
    swapfile.enable = true;
    discovery.enable = true;
    locale.enable = true;
    firefox.enable = true;
    fcitx.enable = true;
    openvpn.enable = true;
    waydroid = {
      enable = true;
      # Present as a tablet so KakaoTalk registers as a secondary device
      # rather than fighting the phone login. See the option's docs.
      tablet = true;
    };
    session-env.enable = true;
    fish.enable = true;
    kitty.enable = true;
    starship.enable = true;
    cursor-theme.enable = true;
    ssh = {
      enable = true;
      # Interactive `ssh yulee`. IdentityFile defaults to
      # my.ssh.builderKeyFile, which remote-builder points at its own sshKey --
      # so the human and the nix-daemon reach the peer with the same
      # credential, as benjamin.
      hosts.yulee = { };
    };
    opencode.enable = true;
    nix-settings = {
      enable = true;
      # Automatic GC is off repo-wide (fork-project artifact preservation), but
      # this host is untuned and does no fork builds -- its store just grows.
      # Weekly GC + 14-day retention (see the feature) keeps it in check.
      gc.automatic = true;
    };
    emacs.enable = true;
    neovim.enable = true;

    # Package sets, each owning its own list (features/<name>/packages.nix).
    base.enable = true;
    eza.enable = true;
    dev-toolchain.enable = true;
    latex.enable = true;
    media.enable = true;
    desktop-apps.enable = true;
    diagnostics.enable = true;
    qt-dev.enable = true;

    hop.enable = true;

    claude-code = {
      enable = true;
      shareWithRoot = true;
      gemma.enable = true;
    };

    claude-desktop = {
      enable = true;
      cowork.enable = true;
    };

    /*
      Offload builds to yulee, as benjamin.

      Deliberately NOT a copy of galaxybook4-pro360's block, on three counts:

        - sshUser is left at its default, which is this host's primary user --
          benjamin, not r0k0r. That single fact is what the peer's ssh_config
          block now reads (peer-yulee.nix), instead of the literal it used to
          hardcode.

        - sshKeySecret stays null. There is no my.agenix.enable on this host,
          and the option's own docs make null the documented fallback: the key
          is hand-installed at /etc/nix/remote-builder/ssh_key, a DIFFERENT
          keypair from the one galaxybook decrypts out of
          age/remote-builder-ssh-key.age. Two client hosts, two credentials,
          two authorized_keys entries on the peer -- so revoking this laptop
          does not lock the other one out. Bootstrap is
          scripts/bootstrap-yulee-builder-benjamin.sh.

          UNLIKE victus-15, yulee is not a nixosConfigurations output of this
          flake -- there is no hosts/yulee. Its /etc/nix/nix.conf is hand-
          administered (see scripts/yulee-nix-access-fix.sh for the existing
          pattern). So granting benjamin trusted-user status there, and
          confirming a benjamin account even exists on that machine, is NOT
          something a rebuild here can do -- it happens only on yulee itself,
          by hand. The bootstrap script prints the exact steps and will not
          silently proceed without them.

        - `features` is left at its default (no gccarch-*). my.tuning.enable
          is false here, so nothing this host builds requests one, and
          nix.buildMachines.supportedFeatures now reads each peer's own
          declared `features` rather than assuming every peer can execute
          meteorlake code (features/remote-builder, upstream commit
          64f6696) -- so /etc/nix/machines advertises exactly what this
          peer supports and nothing this host doesn't need.

      max-jobs becomes 0 (features/remote-builder sets it whenever the client
      is enabled) -- this host then builds NOTHING locally, including the
      doom-intermediates IFD that runs during evaluation. If yulee is
      unreachable, park it: peers.yulee.enable = false. That is the only
      lever that works; --builders cannot reach the eval step. See the
      `enable` option's description for why.
    */
    globaltun = {
      enable = true;
      jump = "r0k0r@172.30.0.215";
      remote = "root@192.168.0.100";
      sshKey = "/etc/nix/remote-builder/ssh_key";
      remoteSocksPort = 1083;
    };
    remote-builder.client = {
      enable = true;
      wrappers.enable = true;
      flakePath = "/home/benjamin/flakes/nixos";
      # The ALIAS, not the FQDN -- peer-yulee.nix emits
      # `Host yulee / HostName <address>` into /etc/ssh/ssh_config, and the
      # daemon's ssh resolves this through it. Same for /etc/nix/machines.
      substituters = [ "ssh://benjamin@yulee" ];
      trustedPublicKeys = [
        "yulee-1:KgdwkCN5m+hewJTk+A05PjwI3BbnZAE9NW2n634N7vM="
      ];
      peers.yulee = {
        maxJobs = 7;
        speedFactor = 10;
        /*
          This laptop is in the `sihooleebd@` tailnet; yulee is in
          `injoystickly@` and reaches us as a SHARED node, same as victus-15.
          Shared nodes get no short MagicDNS name -- `ssh yulee` does not
          resolve here, only the FQDN does. galaxybook4-pro360 is inside the
          peer's own tailnet, so it leaves this at the default and keeps using
          the bare name.
        */
        address = "yulee.tail2d4da1.ts.net";
      };
    };

    /*
      One-offs that do not justify a feature. Literal list -- see
      my.packages.extra's own docs on why lookup.nix cannot read a mkIf here.
    */
    packages.extra.user = with pkgs; [
      fastfetch
      kdePackages.okular
      btop # hakuspace's theme pipeline already writes ~/.config/btop themes
      gimp
      qalculate-qt # calculator (Qt build -- themes via qt6ct like the KDE apps)
      lunar-client # Minecraft client/launcher
      discord

      # linecast (ashuttl/linecast): terminal weather/tides/sun/moon/radar.
      # Not in nixpkgs; packaged straight from PyPI. Pure Python, hatchling
      # build, and NO runtime deps on Linux (its only deps are win32-gated), so
      # a bare buildPythonApplication is the whole story. A literal expression
      # (no mkIf), so lookup.nix reads it fine.
      (python3.pkgs.buildPythonApplication rec {
        pname = "linecast";
        version = "2.4.0";
        pyproject = true;
        src = python3.pkgs.fetchPypi {
          inherit pname version;
          hash = "sha256-TH4elNMit617YssDriVxVowHNUgc3PJGO6vuAP5CYTw=";
        };
        build-system = [ python3.pkgs.hatchling ];
        nativeBuildInputs = [ makeWrapper ];
        pythonImportsCheck = [ "linecast" ];
        meta.mainProgram = "linecast";
        # linecast ships short aliases (weather, moon, tides, ...) that just
        # dispatch to `linecast <name>`. Upstream's `linecast link` creates them
        # as symlinks NEXT TO the binary -- which is the read-only Nix store, so
        # it errors. Bake them as wrappers here instead; each is on PATH and
        # runs the matching command.
        postInstall = ''
          for a in weather sunshine moon sky tides radar maps; do
            makeWrapper $out/bin/linecast $out/bin/$a --add-flags "$a"
          done
        '';
      })

      # Nix workflow. nh wraps nixos-rebuild with a change diff; nom turns the
      # build wall-of-text into a live tree; comma (`, foo`) runs a program
      # from nixpkgs without installing it.
      nh
      nix-output-monitor
      comma

      # Modern CLI. fzf and zoxide get their fish hooks in features/fish;
      # the rest are drop-in binaries. ripgrep is already on PATH via
      # features/neovim, so it is not repeated here.
      fd
      bat
      dust
      duf
      procs
      sd
      tealdeer # `tldr`; run `tldr --update` once to fetch the page cache
      hyperfine
      jless
      yq-go
      lazygit
      uv # fast Python package/project manager (Astral)
      bluetui # Bluetooth TUI; the waybar bluetooth icon opens it, also on PATH

      # Sonora, from its flake (prebuilt packages.default). Literal system
      # string, not pkgs.system: this list is also raw-imported by
      # tuning/runtime-cache/lookup.nix, and a literal keeps it independent of
      # how pkgs is provided there.
      inputs.sonora.packages."x86_64-linux".default

      /*
        Display management (zoom/scale, placement, resolution, extend). Both
        show up in the launcher via their .desktop entries.

          wdisplays  the workhorse: applies changes LIVE through the
                     wlr-output-management Wayland protocol, which Hyprland
                     implements natively -- so it works regardless of this
                     host's Lua config (nwg-displays, by contrast, persists by
                     writing hyprlang `monitor=` lines that a Lua config cannot
                     `source`). Drag to arrange, set mode/scale/rotation,
                     enable/disable -- effective immediately.
          wlr-randr  the CLI behind it; also what a mirror toggle would script
                     (`wlr-randr --output HDMI-A-1 --pos 0,0` etc.).

        Live-only, on purpose: the built-in panel stays declarative
        (my.desktop.primaryOutput/Scale); externals are ad-hoc, re-arranged
        when plugged in. Mirroring is the one thing wdisplays can't do from its
        UI -- ask and I'll add a bound `hyprctl keyword monitor …,mirror,eDP-1`
        toggle once there's an external to test against.
      */
      wdisplays
      wlr-randr

      cava # standalone terminal audio visualizer (hakuspace bundles its own
      # wrapped copy for the bar underbar; this puts `cava` on PATH too)
    ];

    power.enable = true;
    flatpak.enable = true;
    easyeffects = {
      enable = true;
      # Effects applied from login, window hidden -- the feature's own
      # graphical-session service, not an exec-once. (Was briefly disabled while
      # this SSD ran on the AMD Victus, where EasyEffects' virtual-sink default
      # let audio bypass mute; back on the Latitude, where its presets fit the
      # speakers, it's re-enabled.)
      startUp = true;
    };

    boot.enable = true;

    emacs.machineLocalElisp = ''
      ;;; -*- lexical-binding: t; -*-
      ;;; Loaded by Doom `config.el` from ~/.config/home-manager/doom-machine-local.el

      (defun my/machine-local-reset-fonts-h ()
        (setq doom-font (font-spec :family "DepartureMono Nerd Font" :size 16)
              doom-variable-pitch-font (font-spec :family "DepartureMono Nerd Font" :size 16))
        (when (fboundp 'doom-init-fonts-h)
          (doom-init-fonts-h 'reload)))

      (add-hook 'emacs-startup-hook #'my/machine-local-reset-fonts-h)
    '';

    greetd.enable = true;
    qt-theming.enable = true;
    session-services.enable = true;

    desktop = {
      compositor = "hyprland";
      primaryOutput = "eDP-1";
      primaryOutputScale = "1";
    };

    /*
      Shell is Haku Space, not DMS -- mutually exclusive `provides = ["shell"]`
      claimants (features/_meta), so dms.enable must be false or the role
      assertion fires. The greeter switch is off too: with the shell gone,
      dank-greeter was the last DMS piece running, and the login screen is now
      tuigreet (below) -- a terminal greeter matching the rest of this
      machine's aesthetic. Both greeters define greetd's
      default_session.command, so enabling this alongside tuigreet fails
      evaluation rather than racing.
    */
    dms = {
      enable = false;
      greeter.enable = false;
    };

    tuigreet.enable = true;

    hakuspace.enable = true;

    network = {
      enable = true;
      kdeconnect.enable = true;
    };
  };

  /*
    Sonora (music player), host-scoped since it is a dell-latitude-only app.
    Installed above; here it only floats + centers on the current workspace,
    exactly like Dolphin and the other utility windows -- no autostart (removed
    per request; launch it from the dock/menu), no special workspace, no summon
    keybind. extraConfig is types.lines and features/hyprland's fragments are
    mkAfter, so this appends cleanly to the generated Lua.
  */
  home-manager.users.benjamin = {
    wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
      -- Sonora floats+centers, same as Dolphin. Class from StartupWMClass.
      hl.window_rule({ match = { class = "^(sonora)$" }, float = true, center = true })
      -- ...and the same 0.65 glass as the other chrome-heavy apps.
      hl.window_rule({ match = { class = "^(sonora)$" }, opacity = "0.65 0.65" })
    '';
  };

  networking.hostName = "dell-latitude";

  /*
    No nixpkgs.buildPlatform / hostPlatform here. hardware-configuration.nix
    already sets hostPlatform at mkDefault, and on an untuned host the
    build != host split must NOT exist -- that split is precisely what
    tuning/overlays/upstream-tools.nix keys off to tell a build tool from
    something that runs at runtime. The platform is owned by my.tuning.march and
    by nothing else.
  */
}
