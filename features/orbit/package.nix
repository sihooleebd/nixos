{ lib
, rustPlatform
, fetchFromGitHub
, pkg-config
, alsa-lib
, dbus
}:

# orbit -- Benjamin's own terminal music player (github.com/sihooleebd/orbit).
# Packaged rather than `cargo install`ed because this host has no nix-ld: a cargo
# binary that dynamically links libasound/libdbus would build (given pkg-config +
# the dev libs) but then fail to RUN, since nothing puts those libs on its path.
# buildRustPackage embeds the correct rpath, so the binary runs standalone.
#
# Bump: set `rev` + `hash` (nix-prefetch-url --unpack the archive tarball) and
# refresh ./Cargo.lock from the repo at that rev (cp its Cargo.lock here).
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "orbit";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "sihooleebd";
    repo = "orbit";
    rev = "65a479dea5b9765d801808a8b8c290a967c355e0";
    hash = "sha256-AFei+ErOqJ1lXvoO00k8UDTnRN4jGWPhhIrgdtMo0aI=";
  };

  # Vendored from the repo's own Cargo.lock (copied in). No git dependencies, so the
  # lock's crates.io checksums verify every crate and no cargoHash is needed.
  cargoLock.lockFile = ./Cargo.lock;

  # Linux system libs the crates' build scripts pkg-config for: alsa-lib (rodio ->
  # alsa-sys, audio out) and dbus (souvlaki -> libdbus-sys, MPRIS media-key integration).
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ alsa-lib dbus ];

  # The one `tests::ctl_lines` assertion reads $HOME and fs::canonicalize("src")/CWD
  # paths, which the Nix build sandbox doesn't provide the way a dev shell does (HOME is
  # a stub, CWD is /build/source) -- an environment assumption, not an orbit bug. The
  # other 275 tests run. Skip just this one so the package still builds.
  checkFlags = [ "--skip=ctl_lines" ];

  meta = {
    description = "A beautiful terminal music player for your local library";
    homepage = "https://github.com/sihooleebd/orbit";
    license = lib.licenses.mit;
    mainProgram = "orbit";
    platforms = lib.platforms.linux;
  };
})
