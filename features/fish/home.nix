{ config, pkgs, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.fish.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "fish"; };

  # fastfetch as a centered BANNER. fastfetch has no horizontal centering and a
  # greeting's window width varies, so a wrapper does it live:
  #   * fastfetch prints the NixOS logo + the identity ❄ line (left-aligned);
  #   * we append a second ❄ line of system status (RAM/disk/load/battery);
  #   * awk block-centers the logo (all non-❄, non-blank lines share ONE pad, so
  #     the art stays intact) and centers each ❄ info line by its own width;
  #   * `banner` blank lines top and bottom give it room to breathe.
  # `--pipe false` keeps fastfetch's colors (dropped when stdout is a pipe);
  # tput reads the real width (COLUMNS/80 fallback). fastfetch stays a bare
  # (PATH) call so headless hosts without it pull nothing -- the `command -q`
  # guard below still gates running the wrapper there.
  ffCentered = pkgs.writeShellScript "fastfetch-centered" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.procps pkgs.gawk pkgs.ncurses ]}:$PATH
    cols=$(tput cols 2>/dev/null || echo "''${COLUMNS:-80}")
    banner=2

    mem=$(free 2>/dev/null | awk '/^Mem:/{printf "%d", ($2-$7)/$2*100}')
    disk=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc 0-9)
    load=$(cut -d' ' -f1 /proc/loadavg)
    bat=""
    [ -r /sys/class/power_supply/BAT0/capacity ] && bat=" · bat $(cat /sys/class/power_supply/BAT0/capacity)%"
    status="❄ RAM ''${mem}% · disk ''${disk}% · load $load$bat"

    { fastfetch --pipe false; printf '%s\n' "$status"; } | awk -v cols="$cols" -v banner="$banner" '
      { lines[NR]=$0; v=$0; gsub(/\033\[[0-9;]*m/,"",v); w[NR]=length(v);
        isinfo[NR]=(v ~ /^[ \t]*❄/); blank[NR]=(v ~ /^[ \t]*$/) }
      END {
        logomax=0
        for (i=1;i<=NR;i++) if (!isinfo[i] && !blank[i] && w[i]>logomax) logomax=w[i]
        lpad=int((cols-logomax)/2); if (lpad<0) lpad=0
        for (j=0;j<banner;j++) print ""
        for (i=1;i<=NR;i++) {
          if (blank[i]) { print ""; continue }
          if (isinfo[i]) { p=int((cols-w[i])/2); if (p<0) p=0 } else { p=lpad }
          printf "%*s%s\n", p, "", lines[i]
        }
        for (j=0;j<banner;j++) print ""
      }'
  '';
in
lib.mkIf (osConfig.my.fish.enable && inScope) {
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
      fastfetch as the greeting, replacing fish's default text. A function,
      not `set fish_greeting`: defining the function overrides the
      variable-printing default outright. `command -q` guards hosts that do
      not install fastfetch (the headless builder), where the greeting
      quietly stays empty.
    */
    functions.fish_greeting.body = ''
      command -q fastfetch; and ${ffCentered}
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
