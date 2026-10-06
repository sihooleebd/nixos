{ config, lib, ... }:

let
  cfg = config.my.emacs;
in
{
  options.my.emacs = {
    enable = lib.mkEnableOption "Doom Emacs, built as real Nix derivations by nix-doom-emacs-unstraightened";

    headless = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Build the terminal-only Emacs (emacs-nox) instead of the
        pgtk/webkit/xwidgets one, and bind the daemon to default.target rather
        than graphical-session.target.

        Set this on a host with no display manager and no compositor. The pgtk
        build would still *run* under `-nw`, but it drags GTK, WebKit 2.38 and
        xwidgets into the closure of a machine that can never display them --
        and on a machine that also serves as a builder, that closure is built,
        not just downloaded.

        This replaced a `hostName == "victus-15"` test: the thing that decides
        the build is the absence of a display, not the name of a particular
        machine, and a cloned headless host has to get this right without
        being renamed.
      '';
    };

    authinfoSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "../../age/authinfo.age";
      description = ''
        agenix-encrypted netrc credentials for auth-source (Gnus IMAP/SMTP),
        decrypted at activation to /run/agenix/authinfo owned by the user.

        Null leaves auth-source alone -- the doom config's own auth-sources
        setting then decides, which is what a host without agenix wants.

        Requires my.agenix.enable; features/_meta asserts it rather than
        auto-enabling, because a declared age.secrets entry on a host where
        agenix is off produces NO error at all -- it evaluates, builds,
        switches, and leaves auth-source pointing at a file that was never
        decrypted. Exactly the silent-breakage class that assertion exists for.
      '';
    };

    machineLocalElisp = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Elisp written to ~/.config/home-manager/doom-machine-local.el, which
        Doom's config.el loads if present. For genuinely per-machine settings --
        font sizes tuned to one display, and nothing that should follow the
        config to another host.
      '';
    };

    font = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            family = lib.mkOption {
              type = lib.types.str;
              description = ''Doom font family (e.g. "JetBrainsMonoNL Nerd Font").'';
            };
            size = lib.mkOption {
              type = lib.types.int;
              description = "Doom font size in px, tuned to this machine's display.";
            };
            weight = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''Optional doom-font :weight (e.g. "semi-light"); variable-pitch stays default.'';
            };
          };
        }
      );
      default = null;
      description = ''
        Per-machine Doom font. When set, generates the doom-machine-local.el hook that pins doom-font
        + doom-variable-pitch-font and reloads -- the common per-host tweak, so a host writes
        `my.emacs.font = { family; size; }` instead of hand-copying the same defun. Prepended to
        machineLocalElisp, which stays free-form for anything else.
      '';
    };
  };

  # Accounts this feature applies to; defaults to the primary user.
  options.my.emacs.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable {
    my.internal.features."emacs.authinfo" = {
      requires = [ "agenix" ];
      enabledBy = cfg.authinfoSecret != null;
    };

    /*
      owner, not the default root:root 0400: this is read by Emacs running as
      the user, and agenix's default would make auth-source fail the lookup
      SILENTLY -- indistinguishable from a missing file, the same trap the old
      /etc/nix/secrets install line documented.

      Path is left at agenix's default (/run/agenix/<name>), which is tmpfs, so
      the plaintext exists only in RAM and is gone at reboot.
    */
    age.secrets = lib.mkIf (cfg.authinfoSecret != null) {
      authinfo = {
        file = cfg.authinfoSecret;
        owner = config.my.internal.primaryUser;
        group = "users";
        mode = "0400";
      };
    };

    /*
      `withNativeCompilation` flips emacs' `meta.broken` in this nixpkgs fork.
      Isolated by evaluating each flag on the host's pkgs:

        emacs-nox plain              broken = false
        emacs-nox +withTreeSitter    broken = false
        emacs-nox +withNativeComp    broken = TRUE

      ONE KEY PER WRAPPING STAGE, because the flag is re-checked at each. The
      list is not guessable and was grown twice by being bitten:

        <pkg>                                the bare package
        <pkg>-x86_64-unknown-linux-gnu       its pseudo-cross spliced form
        <pkg>-...-with-packages              emacsWithPackages, which
                                             Unstraightened builds via
                                             emacsPackagesFor
        <pkg>-...-with-doom                  emacsWithDoom on top

      -with-packages surfaced only once the classifier fix stopped aliasing
      emacs-pgtk to an unbroken upstream build; before that the stage existed
      but was never evaluated against the fork's broken flag.

      Both builds are listed whenever the feature is on, not gated on
      `headless`: these are inert handler entries, and gating them means the
      list is wrong the moment a host flips. The pgtk keys used to live in
      tuning/pkgs-config.nix, which is gated on qtPatches.enable -- unrelated to
      Emacs, and the reason a desktop host could lose them by turning off Qt
      patching.
    */
    nixpkgs.config.problems.handlers = {
      emacs-nox.broken = "warn";
      emacs-nox-x86_64-unknown-linux-gnu.broken = "warn";
      emacs-nox-x86_64-unknown-linux-gnu-with-packages.broken = "warn";
      emacs-nox-x86_64-unknown-linux-gnu-with-doom.broken = "warn";

      emacs-pgtk.broken = "warn";
      emacs-pgtk-x86_64-unknown-linux-gnu.broken = "warn";
      emacs-pgtk-x86_64-unknown-linux-gnu-with-packages.broken = "warn";
      emacs-pgtk-x86_64-unknown-linux-gnu-with-doom.broken = "warn";
    };
  };
}
