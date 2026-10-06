# Claude Desktop (official Linux beta, 2026-06-30) repackaged from the .deb
# in Anthropic's apt repo. Same pattern as ../claude-code: the deb comes from
# the claude-desktop-bin flake input (hash-pinned in flake.lock), the version
# lives in that input's URL and in the version attr here -- ./update.sh
# rewrites both and relocks.
#
# Contents beyond the stock Electron tree: node-pty + @ant/claude-native
# prebuilt .node modules (Code tab terminal), and Cowork's microVM pieces
# (virtiofsd + smol-bin guest image; needs /dev/kvm). cowork-linux-helper is
# statically linked, hence the `|| true` on the patchelf loop.
{
  lib,
  stdenv,
  dpkg,
  makeWrapper,
  python3,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libGL,
  libcap_ng,
  libdrm,
  libgbm,
  libnotify,
  libpulseaudio,
  libseccomp,
  libsecret,
  libuuid,
  libxcb,
  libxkbcommon,
  nspr,
  nss,
  pango,
  pipewire,
  systemd,
  wayland,
  xdg-utils,
  libx11,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxrandr,
  libxrender,
  libxshmfence,
  libxtst,
  # the claude-desktop-bin flake input (the raw .deb in the store)
  src,
}:
stdenv.mkDerivation {
  pname = "claude-desktop";
  version = "1.40609.0";

  inherit src;

  rpath = lib.makeLibraryPath [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libGL
    libcap_ng # virtiofsd
    libdrm
    libgbm
    libnotify
    libpulseaudio
    libseccomp # virtiofsd
    libsecret # dlopened for the keyring
    libuuid
    libxcb
    libxkbcommon
    nspr
    nss
    pango
    pipewire
    stdenv.cc.cc # libstdc++ for the node-pty prebuild
    systemd # libudev
    wayland
    libx11
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxshmfence
    libxtst
  ];

  buildInputs = [
    gtk3 # GSETTINGS_SCHEMAS_PATH for the wrapper
  ];

  nativeBuildInputs = [
    dpkg
    # Supplies GSETTINGS_SCHEMAS_PATH for the makeWrapper call below, by way of
    # glib's setup hook scanning our buildInputs for share/gsettings-schemas/*.
    #
    # It has to be here rather than in buildInputs: that hook registers itself
    # with `addEnvHooks "$targetOffset"`, and the offsets a dependency is
    # activated at come from the accumulator it lands in. buildInputs is
    # pkgsHostTarget, i.e. (hostOffset 0, targetOffset 1), so glib arriving that
    # way registers into envTargetTargetHooks -- which run over depsTargetTarget,
    # empty for this package. nativeBuildInputs is pkgsBuildHost, (-1, 0), so the
    # hook lands in envHostTargetHooks, and those are the ones that scan
    # buildInputs, where gtk3 is. Same idiom as nixpkgs' own baobab/gedit.
    #
    # gtk3 alone is not enough even though it propagates glib, because the
    # propagated copy inherits gtk3's offsets. Before the intra-ISA strictDeps
    # relaxation was dropped this still worked by accident: _addToEnv's
    # non-strict branch ran every hook over all six accumulators, so the
    # misfiled registration swept up gtk3 anyway.
    #
    # Left unquoted at the use site on purpose -- an empty value then eats the
    # following flag and makeWrapper aborts, rather than silently emitting a
    # wrapper with no schema path and failing at runtime instead.
    glib
    makeWrapper
    python3
  ];

  dontUnpack = true;
  dontBuild = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    dpkg --fsys-tarfile $src | tar --extract
    rm -rf usr/share/lintian

    mkdir -p $out
    mv usr/* $out

    chmod -R g-w $out

    for file in $(find $out -type f \( -perm /0111 -o -name \*.so\* \)); do
      patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$file" 2> /dev/null || true
      patchelf --set-rpath "$rpath:$out/lib/claude-desktop" "$file" 2> /dev/null || true
    done

    # The deb's bin entry is a symlink into lib/; replace it with a wrapper.
    # No NIXOS_OZONE_WL gate: this config is Wayland-only, and native Wayland
    # is required for fcitx5 input (--enable-wayland-ime). The WAYLAND_DISPLAY
    # guard keeps a plain-X11 session working.
    #
    # WaylandFractionalScaleV1 is DISABLED on purpose. Chromium's fractional-scale
    # support targets HiDPI (scale > 1); at a DOWNSCALE (this host runs 0.6-0.8) it is
    # on by default but broken -- it builds a physical-sized buffer (scale x logical)
    # and never scales it up to the logical window, so the UI fills only the scale
    # fraction (measured: exactly 0.8 of the window at scale 0.8) and the rest shows
    # the blurred desktop ("gigantic frosted margin on the right + bottom"). Disabling
    # it drops Chromium to integer buffer_scale=1: it renders at the logical window size
    # and Hyprland downscales the whole window -> the content fills edge-to-edge at any
    # scale (verified by grim: disabled = full-bleed, enabled/default = 0.8 fill). At 1x
    # there's nothing to mis-scale, which is why only 1x ever looked right.
    rm $out/bin/claude-desktop
    makeWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
      --prefix XDG_DATA_DIRS : $GSETTINGS_SCHEMAS_PATH \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils glib ]} \
      --add-flags "\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations,WebRTCPipeWireCapturer --disable-features=WaylandFractionalScaleV1 --enable-wayland-ime=true}"

    substituteInPlace $out/share/applications/com.anthropic.Claude.desktop \
      --replace-fail "Exec=claude-desktop" "Exec=$out/bin/claude-desktop"

    # Black-glass: force the dark theme's base backgrounds to #000 so the
    # 0.65 Hyprland window opacity composites like kitty/dolphin. The theme
    # lives inside app.asar (window-shared.css + inline CSS in the renderer
    # HTMLs, class `.darkTheme`) and in the loose chat-SPA CSS under
    # resources/ion-dist; blacken.py patches both with same-length byte
    # replacements and re-signs the asar's SHA256 integrity records (the
    # integrity fuse is enabled). It fails the build if the palette
    # literals ever change on an update.
    ${python3.interpreter} ${./blacken.py} $out/lib/claude-desktop/resources

    runHook postInstall
  '';

  meta = {
    description = "Desktop application for Claude.ai (Chat, Cowork, Claude Code)";
    homepage = "https://claude.com/download";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "claude-desktop";
  };
}
