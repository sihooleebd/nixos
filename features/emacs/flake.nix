{
  description = "Doom Emacs, built as real Nix derivations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    /*
      Builds Doom as real Nix derivations instead of straight.el's imperative
      git-clone/pull. Its own doomemacs/doomemacs-modules sub-inputs are left
      un-`follows`'d on purpose: ride the framework version it is actually
      tested against, rather than hand-managing version skew -- the exact bug
      class this replaced.
    */
    nix-doom-emacs-unstraightened = {
      url = "github:marienz/nix-doom-emacs-unstraightened";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Former ~/.doom.d (https://github.com/R0K0R/doom-emacs).
    doom-private = {
      url = "github:sihooleebd/doom-emacs";
      flake = false;
    };

    /*
      webkitgtk_4_1 ONLY. Emacs xwidgets' configure requires
      webkit2gtk-4.1 < 2.41.92 and unstable is newer, so this is deliberately
      NOT followed to the fork -- it wants its own independent lock, currently
      nixos-22.11 giving webkit 2.38.x. The reason travels with the feature that
      needs it rather than sitting unexplained in a root flake.
    */
    nixpkgs-emacs-webkit.url = "github:NixOS/nixpkgs/nixos-22.11";
  };

  outputs =
    { nix-doom-emacs-unstraightened, doom-private, nixpkgs-emacs-webkit, ... }:
    {
      homeModule = nix-doom-emacs-unstraightened.homeModule;
      doomDir = doom-private;
      webkitPkgs = nixpkgs-emacs-webkit.legacyPackages;
    };
}
