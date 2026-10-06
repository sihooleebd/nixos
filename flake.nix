{
  description = "NixOS configuration (multi-host)";

  inputs = {
    # Pinned in flake.lock. Use nixos-YY.MM when that branch exists, or keep unstable.
    # combined-fundamental: all cross-build fixes merged onto current
    # nixos-unstable, rebuilt as individual pr/* branches (see nixpkgs-contrib)
    # for upstreaming, plus this one combined branch actually used for building.
    nixpkgs.url = "github:R0K0R/nixpkgs/combined-fundamental";

    # Intentionally NOT follows = "nixpkgs" — unaffected by
    # --override-input nixpkgs path:/home/r0k0r/nixpkgs-patch.
    # Used for nix.nixPath and nix.registry so that nix-shell / nix run
    # evaluate against unpatched nixpkgs and hit the Hydra binary cache.
    nixpkgs-upstream.url = "github:NixOS/nixpkgs/nixos-unstable";

    /*
      Per-feature sub-flakes. Each owns the external inputs only IT consumes, so
      `rm -r features/<name>` takes that feature's whole dependency surface with
      it and the root flake stops carrying pins for things it does not use.
    */
    feat-claude-code.url = "path:./features/claude-code";
    feat-hop.url = "path:./features/hop";
    feat-claude-desktop.url = "path:./features/claude-desktop";
    feat-samsung-galaxybook.url = "path:./features/samsung-galaxybook";
    feat-easyeffects.url = "path:./features/easyeffects";

    # Module/overlay-providing sub-flakes need the second half of the two-level
    # follows -- see each sub-flake's own header for why both are required.
    feat-niri = {
      url = "path:./features/niri";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-dms = {
      url = "path:./features/dms";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-hakuspace = {
      url = "path:./features/hakuspace";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-agenix = {
      url = "path:./features/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-emacs = {
      url = "path:./features/emacs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      # master, not a release branch: nixpkgs here tracks unstable (26.11), and
      # release-26.05's fish module still referenced the pre-fish-4.x
      # share/fish/tools/create_manpage_completions.py path, breaking every
      # *-fish-completions derivation. master is the pairing for nixpkgs unstable.
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Sonora, consumed as a plain prebuilt package
    # (packages.<system>.default) on dell-latitude. No nixpkgs.follows: let it
    # build against its own pin so the author's binary cache applies, rather
    # than forcing it onto this flake's nixpkgs.
    # Benjamin's bugfixed fork (same app: binary + app-id stay "sonora", so the dock route and the
    # my.sidedock app-class references are unchanged -- only the source moves).
    sonora.url = "github:sihooleebd/sononora/feat/niche-fixes-and-features";

  };

  outputs =
    inputs@{ self
    , nixpkgs
    , home-manager
    , ...
    }:
    let
      lib = nixpkgs.lib;

      /*
        Feature registration. Every directory under features/ is imported on
        EVERY host, unconditionally; `my.<feature>.enable` decides whether it
        does anything. `imports` is never used as a switch -- that conflation is
        what made modules/nixos/default.nix all-or-nothing and forced headless
        victus-15 to hand-roll duplicates of locale/users/nix-settings.
        A disabled feature costs an option declaration and an unforced mkIf.

        Discovery is a readDir walk, so there is no import list to maintain and
        no way for a feature to be silently left out. The corollary is that a
        file's mere presence activates it: modules/nixos/boot/{kernel,sysrq}.nix
        were dead and broken (one did not even parse) precisely because the old
        hand-written list never referenced them. Nothing may live under
        features/ that is not a real module.
      */
      featureNames = builtins.attrNames (builtins.readDir ./features);
      collect =
        layer:
        {
          imports = builtins.filter builtins.pathExists (
            map (n: ./features + "/${n}/${layer}") featureNames
          );
        };
      nixosFeatures = collect "nixos.nix";
      homeFeatures = collect "home.nix";

      /*
        WHICH NIXPKGS A HOST GETS, decided before the module system exists.

        `my.tuning.enable = false` hands a host plain upstream nixpkgs so its
        whole package set substitutes from cache.nixos.org. That cannot be an
        ordinary option read from `config`: the input has to be chosen to build
        the fixpoint that `config` lives in. So the literal is read out of the
        host file by RAW IMPORT -- the same technique
        tuning/runtime-cache/lookup.nix:185 uses for my.packages.extra, with the
        same constraint and the same _type rejection, because there is no module
        evaluation here that could resolve a property list.

        WHY NOT nixpkgs.pkgs, the option that exists for exactly this: the
        nixpkgs module asserts `nixpkgs.pkgs is defined -> nixpkgs.config == {}`
        (nixos/modules/misc/nixpkgs.nix:409, unconditional). This config sets
        nixpkgs.config in two places that have nothing to do with tuning --
        features/nix-settings (allowUnfree) and features/emacs (problems.handlers)
        -- so that route needs `nixpkgs.config = mkForce {}` plus a hand-copy of
        those values into the import, where the next key anyone adds is silently
        dropped. It also makes nixpkgs.overlays silently ignored, which would
        quietly delete my.tuning.extraOverlays -- this host's GPU trim and
        fingerprint fork. Swapping the input keeps config and overlays working
        normally.

        SAFE because the fork patches only pkgs/ (71 files; nothing under nixos/
        or lib/, verified by tree diff), so `np.lib.nixosSystem` and the whole
        NixOS module tree are byte-identical either way. This swaps the package
        set, not the module system.
      */
      tuningEnabledOf =
        hostName:
        let
          raw = import (./hosts + "/${hostName}") {
            inherit inputs lib hostName;
            pkgs = throw "flake.nix: hosts/${hostName} -- my.tuning.enable must not read `pkgs`";
            config = throw "flake.nix: hosts/${hostName} -- my.tuning.enable must not read `config`";
          };
          v = raw.my.tuning.enable or false;
        in
        if builtins.isBool v then
          v
        else
          throw ''
            flake.nix: hosts/${hostName}/default.nix wraps my.tuning.enable in ${
              v._type or builtins.typeOf v
            }.
            It must be a literal `true` or `false`. The nixpkgs input is chosen before the
            module system exists, so nothing here can resolve mkIf/mkMerge.'';

      mkHost =
        hostName:
        let
          tuningEnabledRaw = tuningEnabledOf hostName;
          np = if tuningEnabledRaw then nixpkgs else inputs.nixpkgs-upstream;
        in
        np.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs hostName tuningEnabledRaw; };
          modules = [
            home-manager.nixosModules.home-manager
            nixosFeatures
            # Machine-bound tuning backend: march/pseudo-cross platform split,
            # the overlays, and the runtime-cache classifier. Not a feature --
            # it is tied to this nixpkgs fork and to per-host generated data, so
            # it cannot be handed to anyone else the way a feature can.
            ./tuning
            # home-manager wiring, shared with tier2-eval so the classifier sees
            # the same home packages this host does. See lib/home-manager.nix.
            (import ./lib/home-manager.nix {
              homeModules = [ homeFeatures ];
              inherit inputs hostName;
            })
            ./hosts/${hostName}
            # Phase-1 bootstrap: pin nixos-rebuild to unpatched upstream so it
            # hits cache.nixos.org and doesn't need to be built from our patched stdenv.
            { system.build.nixos-rebuild = lib.mkForce
                inputs.nixpkgs-upstream.legacyPackages.x86_64-linux.nixos-rebuild; }
          ];
        };
    in
    {
      nixosConfigurations.victus-15 = mkHost "victus-15";
      nixosConfigurations.galaxybook4-pro360 = mkHost "galaxybook4-pro360";
      # my.tuning.enable = false -- plain upstream nixpkgs, everything from
      # cache.nixos.org. See hosts/dell-latitude/default.nix.
      nixosConfigurations.dell-latitude = mkHost "dell-latitude";

      /*
        Exposed so a feature set can be consumed from outside this repo, and so
        an individual feature stays extractable later without touching any host
        file. mkHost uses the `let` bindings directly rather than these, to keep
        nixosConfigurations from depending on the flake's own output fixpoint.
      */
      nixosModules.default = nixosFeatures;
      homeModules.default = homeFeatures;

      /*
        `nix flake check` as the one-command gate. Forcing each host's toplevel
        is what evaluates its assertions -- including features/_meta's dependency
        checks, which otherwise only fire when someone happens to build.

        Note this triggers nix-doom-emacs-unstraightened's import-from-derivation
        on any change that moves the package set, so run it with a reachable
        builder or `--builders ''`.
      */
      checks.x86_64-linux = lib.mapAttrs (
        _: cfg: cfg.config.system.build.toplevel
      ) self.nixosConfigurations;
    };
}
