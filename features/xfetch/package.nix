{ lib
, rustPlatform
, fetchFromGitHub
}:

# xfetch (https://github.com/xfetch-cli/xfetch) -- a cross-platform system-info fetch tool in Rust,
# the replacement for fastfetch as the shell greeting. Packaged in-flake (not `cargo install`)
# because dell-latitude has no nix-ld, so a cargo-installed dynamic binary fails at runtime;
# buildRustPackage embeds the rpath. Pure Rust (rustls TLS via ureq, pure-Rust image decoders) --
# no system libraries, and all deps resolve from crates.io, so cargoHash (not a vendored Cargo.lock)
# is enough. Reads ~/.config/xfetch/config.jsonc (JSONC) when present; `xfetch --gen-config` seeds one.
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "xfetch";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "xfetch-cli";
    repo = "xfetch";
    rev = "v${finalAttrs.version}";
    hash = "sha256-f6MiZnMcr+gV631auVgb+BG9xozWF94bXmvszlZeHwQ=";
  };

  cargoHash = "sha256-9s78bJZxOZ3k8nl3Dcgt3/xPOgqTgIVDJTFOZkZvfy0=";

  # These two unit tests fail in the build SANDBOX, not for real: the cache test writes to a cache
  # dir the sandbox doesn't provide, and the wasm-host exec test runs an external program that isn't
  # on the sandbox PATH. The other 216 tests pass. (Same sandbox-isolation issue as orbit's ctl_lines.)
  checkFlags = [
    "--skip=cache::tests::test_cache_set_get"
    "--skip=wasm::host::exec::tests::allowlisted_program_returns_output"
  ];

  meta = {
    description = "Cross-platform system information fetch tool, written in Rust";
    homepage = "https://github.com/xfetch-cli/xfetch";
    license = lib.licenses.mit;
    mainProgram = "xfetch";
    platforms = lib.platforms.linux;
  };
})
