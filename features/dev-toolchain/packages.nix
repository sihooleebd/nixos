# Language servers, compilers and debuggers -- the interactive development set.
# `user` (users.users.<n>.packages), not `system`: these belong to a person, not
# to the machine.
{ pkgs }:
{
  user = with pkgs; [
    cursor-cli
    /*
      git from the BUILD splice, deliberately -- this is the only way to get
      `git send-email` on a tuned host.

      pkgs/by-name/gi/git/package.nix gates it twice:

        perlSupport      ? stdenv.buildPlatform == stdenv.hostPlatform,
        sendEmailSupport ? perlSupport,

      and my.tuning.march exists precisely to make those platforms differ. So on
      any host with march set, plain `git` is built with perlSupport = false and
      git-send-email is simply never installed -- verified: the tuned git ships
      git-cvsimport and git-imap-send but no git-send-email. `gitFull` does not
      help either; all-packages.nix sets its sendEmailSupport to the same
      buildPlatform == hostPlatform test.

      pkgsBuildHost is the plain native set, where those platforms ARE equal, so
      perlSupport is on and send-email is built. It is also byte-identical to
      upstream, hence substitutable from cache.nixos.org rather than built. On an
      untuned host (my.tuning.enable = false) pkgsBuildHost == pkgs, so this is a
      no-op there.

      The cost is that git itself is no longer -march tuned, which is nothing
      next to losing the tool kernel patches are sent with.
    */
    pkgsBuildHost.git
    gh
    nixd
    nixfmt
    statix
    deadnix
    tree
    python3
    # Python LSP for Emacs `lsp-pyright` when using BasedPyright (`basedpyright-langserver`).
    basedpyright
    clang-tools # clangd LSP + clang-format/clang-tidy
    gcc
    gdb
    # Rust: cargo + rustc (cargo can't compile without the toolchain), rust-analyzer the
    # LSP (matching clangd/basedpyright above). clippy/rustfmt are a line away if wanted.
    cargo
    rustc
    rust-analyzer
    tinymist
    typst
  ];

  system = with pkgs; [
    openjdk25_headless
  ];
}
