{ config, lib, pkgs, ... }:

let
  cfg = config.my.kakaotalk;

  # Wine, patched to route file dialogs to xdg-desktop-portal (Wine MR10060 -- verified to
  # apply cleanly to 11.0). With the `FileDialogPortal`="always" registry key set in the
  # launcher's reg block below, GetOpenFileName / GetSaveFileName / IFileDialog /
  # SHBrowseForFolder ask org.freedesktop.portal.FileChooser instead of Wine drawing its own
  # dialog -> the session's FileChooser backend (kde -- features/session-services + hakuspace)
  # shows the native KDE/Dolphin-style picker. Covers ANY wine process (the user's `wine` is
  # this one). Builds from SOURCE (~1h; offload to a remote builder -- the cached binary can't
  # carry a patch). portal_dbus.c dlopens libdbus by bare SONAME, which has no global path on
  # NixOS, so bake the store path (the pattern nixpkgs uses for wine's other dlopen'd libs);
  # the launcher also exports LD_LIBRARY_PATH as a belt-and-suspenders.
  winePortal = pkgs.wine.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./portal-filedialog.patch ];
    buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.dbus ];
    postPatch = (old.postPatch or "") + ''
      substituteInPlace dlls/comdlg32/portal_dbus.c \
        --replace-quiet '"libdbus-1.so.3"' '"${pkgs.dbus.lib}/lib/libdbus-1.so.3"'
    '';
  });

  # KakaoTalk via Wine (no native Linux build, not in nixpkgs). Plain 32-bit
  # `wine` runs this 32-bit app natively in a win32 prefix -- and it's CACHED,
  # unlike the multilib wineWow*, which builds from source (an hour+ on an 8GB
  # box). The launcher sets up a dedicated prefix, downloads the official
  # installer on first run, tunnels the Windows Documents folder to the real
  # ~/Documents (so saved/received files land inside ~/Documents), wires up the
  # Korean fonts/locale/IME, then launches. See the inline comments for each
  # Hangul fix -- they were all hard-won.
  kakaotalk = pkgs.writeShellScriptBin "kakaotalk" ''
    set -e
    export WINEPREFIX="$HOME/.local/share/wineprefixes/kakaotalk"
    export WINEARCH=win32
    export WINEDLLOVERRIDES="mscoree,mshtml="   # skip the mono/gecko install prompts
    # Run under a Korean locale. Wine derives its Windows ANSI codepage from
    # LANG/LC_ALL (it parses the string itself, no glibc locale needed): en_US
    # -> cp1252 (Latin) mangles Hangul typed into KakaoTalk's input to tofu;
    # ko_KR -> cp949 (Korean) and it renders. The locale is built via
    # i18n.supportedLocales below.
    export LANG=ko_KR.UTF-8
    export LC_ALL=ko_KR.UTF-8
    # xdg-utils puts `xdg-open` on Wine's PATH so winebrowser can hand URLs/files/folders to the
    # NATIVE handlers (browser, PDF viewer, Dolphin, ...) -- see the WineBrowser + folder-association
    # registry keys below. gio/mimeopen are its resolver fallbacks under a non-KDE session.
    export PATH=${lib.makeBinPath ([ winePortal ] ++ (with pkgs; [ curl coreutils findutils xdg-utils glib ]))}:$PATH
    # portal file dialogs: comdlg32's portal_dbus dlopens libdbus at runtime -- make it findable
    # (the store path is also baked into the build; this covers any edge the baking misses).
    export LD_LIBRARY_PATH=${pkgs.dbus.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

    mkdir -p "$HOME/Documents/KakaoTalk"

    find_exe() { find "$WINEPREFIX/drive_c" -iname KakaoTalk.exe 2>/dev/null | grep -vi uninstall | head -1; }
    exe=$(find_exe)

    if [ -z "$exe" ]; then
      echo ">> First run: creating the Wine prefix and installing KakaoTalk."
      mkdir -p "$WINEPREFIX"          # wineboot won't create the prefix ROOT; it only inits an existing dir
      # Real Korean font FILES in the prefix Fonts dir, placed BEFORE init so
      # wineboot registers them with their HANGUL charset. The chat area is
      # fixed by FontSubstitutes alone, but the message INPUT (a richedit
      # control) selects a font by charset, which substitutes don't cover --
      # without a HANGUL-charset font file present it renders Hangul as tofu.
      mkdir -p "$WINEPREFIX/drive_c/windows/Fonts"
      find ${pkgs.nanum}/share/fonts ${pkgs.baekmuk-ttf}/share/fonts -name '*.ttf' 2>/dev/null \
        | while read -r ttf; do ln -sf "$ttf" "$WINEPREFIX/drive_c/windows/Fonts/"; done
      wineboot -i >/dev/null 2>&1 || true
      wineserver -w || true
      # Wine ALREADY symlinks the Windows Documents folder to ~/Documents on
      # prefix init, so KakaoTalk's saved files land inside ~/Documents. Only
      # force it in the unlikely case it came up as a real dir.
      wdocs="$WINEPREFIX/drive_c/users/$USER/Documents"
      if [ ! -L "$wdocs" ]; then
        mkdir -p "$(dirname "$wdocs")"
        rm -rf "$wdocs" 2>/dev/null || true
        ln -sfn "$HOME/Documents" "$wdocs"
      fi
      inst="$WINEPREFIX/KakaoTalk_Setup.exe"
      echo ">> Downloading the official installer…"
      curl -fL --retry 3 -o "$inst" "https://app-pc.kakaocdn.net/talk/win32/KakaoTalk_Setup.exe"
      echo ">> Launching the installer -- click through it, then log in."
      wine "$inst" || true
      wineserver -w || true
      exe=$(find_exe)
    fi

    # Korean font substitutes: map the Windows fonts KakaoTalk asks for
    # (Gulim, Malgun Gothic, 맑은 고딕, ...) to the installed Nanum fonts, or
    # Hangul renders as tofu. Also set the Wine XIM preedit style to "root":
    # by default Wine draws the IME preedit itself ("over-the-spot"), which
    # mangles fcitx's Hangul composition (typed 가나다 arrives decomposed into
    # jamo, and the composing text tofus in the input box). "root" hands the
    # preedit back to fcitx, which composes + renders Korean correctly.
    # Marker-guarded (once per prefix); bump the marker to re-import on prefixes
    # created before a given key existed.
    if [ ! -f "$WINEPREFIX/.kakao-reg-v4" ]; then
      reg="$WINEPREFIX/.kakao-reg.reg"
      cat > "$reg" <<'FONTREG'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"InputStyle"="root"
"FileDialogPortal"="always"

; Native integration: hand URLs / mailto / folders / documents to the native Linux apps instead
; of Wine's built-ins. winebrowser resolves each through xdg-open (on PATH via xdg-utils), which
; uses the desktop's MIME associations -> native browser, mail client, Dolphin, PDF viewer, etc.
; Browsers/Mailers force winebrowser to prefer xdg-open over its hardcoded browser search.
[HKEY_CURRENT_USER\Software\Wine\WineBrowser]
"Browsers"="xdg-open"
"Mailers"="xdg-open"

; Folder open ("폴더 열기" / Explorer) -> native file manager instead of Wine's winefile.
[HKEY_CLASSES_ROOT\Directory\shell\open\command]
@="C:\\windows\\system32\\winebrowser.exe \"%1\""

[HKEY_CLASSES_ROOT\Folder\shell\open\command]
@="C:\\windows\\system32\\winebrowser.exe \"%1\""

; URL protocols -> native browser / mail (Wine usually defaults these to winebrowser already; set
; them explicitly so a stale prefix is corrected too).
[HKEY_CLASSES_ROOT\http\shell\open\command]
@="C:\\windows\\system32\\winebrowser.exe \"%1\""

[HKEY_CLASSES_ROOT\https\shell\open\command]
@="C:\\windows\\system32\\winebrowser.exe \"%1\""

[HKEY_CLASSES_ROOT\mailto\shell\open\command]
@="C:\\windows\\system32\\winebrowser.exe \"%1\""

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
"Gulim"="NanumGothic"
"GulimChe"="NanumGothicCoding"
"Dotum"="NanumGothic"
"DotumChe"="NanumGothicCoding"
"Batang"="NanumMyeongjo"
"BatangChe"="NanumMyeongjo"
"Gungsuh"="NanumMyeongjo"
"Malgun Gothic"="NanumGothic"
"MS Shell Dlg"="NanumGothic"
"MS Shell Dlg 2"="NanumGothic"
"MS Sans Serif"="NanumGothic"
"Microsoft Sans Serif"="NanumGothic"
"Tahoma"="NanumGothic"
"Segoe UI"="NanumGothic"
"MS UI Gothic"="NanumGothic"
"MS Gothic"="NanumGothic"
"MS PGothic"="NanumGothic"
"System"="NanumGothic"
"Fixedsys"="NanumGothicCoding"
"SimSun"="NanumGothic"
"NSimSun"="NanumGothic"
"Microsoft YaHei"="NanumGothic"
"Microsoft JhengHei"="NanumGothic"
"Yu Gothic"="NanumGothic"
"Yu Gothic UI"="NanumGothic"
"Meiryo"="NanumGothic"
"MingLiU"="NanumGothic"
"PMingLiU"="NanumGothic"
"Apple SD Gothic Neo"="NanumGothic"
FONTREG
      wine regedit /S "$reg" >/dev/null 2>&1 || true
      wineserver -w || true
      touch "$WINEPREFIX/.kakao-reg-v4"
    fi

    [ -n "$exe" ] && exec wine "$exe"
    echo "KakaoTalk.exe not found; the install may not have finished. Re-run 'kakaotalk' to retry."
    exit 1
  '';
in
{
  options.my.kakaotalk = {
    enable = lib.mkEnableOption
      "KakaoTalk via Wine -- Korean fonts + ko_KR locale, Daum ad-block, and the XEmbed->SNI tray bridge";
    # Accounts this feature applies to; defaults to the primary user.
    users = import ../../lib/user-scope.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    # Korean fonts, system-level (fontconfig) so Wine/Pango can resolve them --
    # otherwise KakaoTalk (and Hangul anywhere) renders as tofu boxes. Merges
    # with the fonts feature's own list.
    fonts.packages = with pkgs; [ nanum baekmuk-ttf ];

    # Build the Korean locale so the launcher can run KakaoTalk under
    # LANG=ko_KR.UTF-8 (see the codepage note in the launcher). supportedLocales
    # REPLACES the default list (it's an mkDefault), so carry the base two
    # forward -- defaultLocale (from my.locale) + C -- alongside ko_KR.
    i18n.supportedLocales = [
      "C.UTF-8/UTF-8"
      "${config.i18n.defaultLocale}/UTF-8"
      "ko_KR.UTF-8/UTF-8"
    ];

    # Blackhole KakaoTalk's ad banners (Kakao/Daum AdFit network). Wine resolves
    # through the Linux stack, so the prefix's Windows hosts file is ignored, but
    # /etc/hosts wins anyway -- nsswitch checks `files` before `dns`, so this
    # beats a MagicDNS/systemd-resolved resolver too. ad.daum.net +
    # info.ad.daum.net are baked into the KakaoTalk binary; display/analytics are
    # the same ad-only subdomain family. NOT t1.daumcdn.net -- that CDN also
    # serves emoticons/images. Restart KakaoTalk after a switch for the banner to
    # vanish.
    networking.extraHosts = ''
      0.0.0.0 ad.daum.net
      0.0.0.0 info.ad.daum.net
      0.0.0.0 display.ad.daum.net
      0.0.0.0 analytics.ad.daum.net
    '';

    # The app itself, per-account (the primary user, via my.kakaotalk.users),
    # the same way every other package-owning feature contributes.
    my.packages.perUser = lib.genAttrs cfg.users (_: [ winePortal kakaotalk ] ++ (with pkgs; [ winetricks ]));
  };
}
