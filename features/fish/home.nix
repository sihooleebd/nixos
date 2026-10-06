{ config, pkgs, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.fish.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "fish"; };

in
lib.mkIf (osConfig.my.fish.enable && inScope) {
  # The fish greeting runs xfetch (below). xfetch ships NO NixOS logo, so it falls back to a
  # placeholder "fake public key" ascii -- point it at the real NixOS snowflake instead. Only the
  # logo is overridden; modules/layout stay xfetch's defaults. The art is vendored in
  # features/xfetch/nixos-logo.txt (from `xfetch --gen-config --logo nixos`) and referenced by its
  # STORE path -- no per-run network fetch, no hardcoded home path. Harmless if xfetch isn't installed
  # (the greeting's `command -q xfetch` guard skips it).
  xdg.configFile."xfetch/config.jsonc".text = builtins.toJSON {
    ascii = "${../xfetch/nixos-logo.txt}";
  };

  /*
    zoxide and fzf earn their keep only through the shell hooks, so they are
    declared here (with fish integration) rather than as bare binaries in the
    host package list. zoxide adds `z <dir>` frecency jumping; fzf adds
    Ctrl-R history search and Ctrl-T file insertion. Both append their init to
    interactiveShellInit, which composes with the block below.
  */
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };

  programs.fish = {
    enable = true;

    shellAliases = {
      # Kitty doesn’t clear properly; hard-reset scrollback + cursor.
      clear = "printf '\\033[2J\\033[3J\\033[1;1H'";
      celar = "printf '\\033[2J\\033[3J\\033[1;1H'";
      claer = "printf '\\033[2J\\033[3J\\033[1;1H'";
      pamcan = "pacman";
      q = "qs -c ii";
    };

    functions.starship_transient_prompt_func.body = "starship module character";

    /*
      xfetch as the greeting, replacing fish's default text. A function,
      not `set fish_greeting`: defining the function overrides the
      variable-printing default outright. `command -q` guards hosts that do
      not install xfetch (the headless builder), where the greeting
      quietly stays empty.
    */
    functions.fish_greeting.body = ''
      command -q xfetch; and xfetch
    '';

    interactiveShellInit = ''

      # Theme (from former fish_variables; omit fisher plugin state)
      set -g fish_color_autosuggestion '555\x1ebrblack'
      set -g fish_color_cancel -r
      set -g fish_color_command blue
      set -g fish_color_comment red
      set -g fish_color_cwd green
      set -g fish_color_cwd_root red
      set -g fish_color_end green
      set -g fish_color_error brred
      set -g fish_color_escape brcyan
      set -g fish_color_history_current -- --bold
      set -g fish_color_host normal
      set -g fish_color_host_remote yellow
      set -g fish_color_normal normal
      set -g fish_color_operator brcyan
      set -g fish_color_param cyan
      set -g fish_color_quote yellow
      set -g fish_color_redirection 'cyan\x1e--bold'
      set -g fish_color_search_match -- --background=111
      set -g fish_color_selection 'white\x1e--bold\x1e--background=brblack'
      set -g fish_color_status red
      set -g fish_color_user brgreen
      set -g fish_color_valid_path -- --underline
      set -g fish_key_bindings fish_default_key_bindings
      set -g fish_pager_color_completion normal
      set -g fish_pager_color_description 'B3A06D\x1eyellow\x1e-i'
      set -g fish_pager_color_prefix 'cyan\x1e--bold\x1e--underline'
      set -g fish_pager_color_progress 'brwhite\x1e--background=cyan'
      set -g fish_pager_color_selected_background -- -r

      if test -f ~/.local/state/quickshell/user/generated/terminal/sequences.txt
        cat ~/.local/state/quickshell/user/generated/terminal/sequences.txt
      end

      if test "$TERM" != linux
        alias ls 'eza --icons'
      end
      if test "$TERM" = xterm-kitty
        alias ssh 'kitten ssh'
      end

      if test "$TERM" != linux
        ${pkgs.starship}/bin/starship init fish | source
        enable_transience
      end
    '';
  };
}
