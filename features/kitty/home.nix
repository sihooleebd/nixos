{ config, pkgs, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.kitty.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "kitty"; };
in
let
  # Kitty kittens from https://github.com/end-4/dots-hyprland (dots/.config/kitty/).
  kittySearchPy = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/end-4/dots-hyprland/main/dots/.config/kitty/search.py";
    # nix-prefetch-url output (base32); do not prefix with sha256- here
    sha256 = "15z1cs4wwxnvw96hkj7zl5wy7a26q8qnvc812vph93mnz9q2qsvq";
  };
  kittyScrollMarkPy = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/end-4/dots-hyprland/main/dots/.config/kitty/scroll_mark.py";
    sha256 = "1a1l7sp2x247da8fr54wwq7ffm987wjal9nw2f38q956v3cfknzi";
  };
in
lib.mkIf (osConfig.my.kitty.enable && inScope) {
  xdg.configFile."kitty/search.py".source = kittySearchPy;
  xdg.configFile."kitty/scroll_mark.py".source = kittyScrollMarkPy;

  programs.kitty = {
    enable = true;

    shellIntegration.enableFishIntegration = true;

    settings = {
      shell = "${pkgs.fish}/bin/fish";

      font_family = "DepartureMono Nerd Font";
      bold_font = "auto";
      italic_font = "auto";
      bold_italic_font = "auto";
      font_size = 11;

      dynamic_background_opacity = true;
      background_opacity = "0.65";

      cursor_shape = "beam";
      cursor_beam_thickness = 2;
      cursor_trail = 1;
      shell_integration = "enabled";

      # Needed for dots-hyprland-style search kitten (launch … kitty @ …).
      allow_remote_control = "yes";

      # Inspired by https://github.com/end-4/dots-hyprland/blob/main/dots/.config/kitty/kitty.conf
      # (end-4 uses 21.75, which reads as a lot of dead space here -- trimmed.)
      window_margin_width = 8;
      # Kitty ≥0.40: integer, not yes/no; HM bools become `no` and break parsing. 0 = never confirm.
      confirm_os_window_close = 0;

      scrollback_lines = 50000;
      scrollback_pager = "less --chop-long-lines --RAW-CONTROL-CHARS +INPUT_LINE_NUMBER";
      enable_audio_bell = false;

      copy_on_select = "clipboard";

      strip_trailing_spaces = "smart";
      detect_urls = "yes";

      foreground = "#cdd6f4";
      background = "#000000";

      /*
        Gray "[> command X]" strip = Kitty’s own tab/title bar (shell integration
        updates the title). Niri does not draw that. Hide for a flat window like
        end-4’s minimal kitty.conf (no tab_bar_* there).
      */
      tab_bar_style = "hidden";

      # Prefer niri’s SSD / no extra client titlebar when supported.
      hide_window_decorations = true;

      mouse_hide_wait = "1.5";
      focus_follows_mouse = "yes";
    };

    extraConfig = ''
      modify_font underline_position 125%
      modify_font underline_thickness 175%

      clipboard_control write-clipboard read-clipboard write-primary read-primary

      map ctrl+c copy_or_interrupt

      map ctrl+f launch --location=hsplit --allow-remote-control kitty +kitten search.py @active-kitty-window-id
      map kitty_mod+f launch --location=hsplit --allow-remote-control kitty +kitten search.py @active-kitty-window-id

      map page_up scroll_page_up
      map page_down scroll_page_down

      map ctrl+plus change_font_size all +1
      map ctrl+equal change_font_size all +1
      map ctrl+kp_add change_font_size all +1
      map ctrl+minus change_font_size all -1
      map ctrl+underscore change_font_size all -1
      map ctrl+kp_subtract change_font_size all -1
      map ctrl+0 change_font_size all 0
      map ctrl+kp_0 change_font_size all 0

      map ctrl+shift+t     new_tab_with_cwd
      map ctrl+shift+right next_tab
      map ctrl+shift+left  previous_tab

      map ctrl+shift+u     kitten hints --type url
      map ctrl+shift+o     kitten hints --type linenum --program @
      map ctrl+shift+p     kitten hints --type path --program -

      map ctrl+shift+h     show_scrollback
    '';
  };
}
