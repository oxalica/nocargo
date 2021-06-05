final: prev:
let
  inherit (final.lib.crates-nix) mkIndex buildRustCrateFromSrcAndLock;
  inherit (final.crates-nix) crates-io-index index buildRustCrate toml2json;
in
{
  lib = prev.lib // {
    crates-nix =
      import ./semver.nix { inherit (final) lib; } //
      import ./target-cfg.nix { inherit (final) lib rust; } //
      import ./crate-info.nix { inherit (final) lib fetchurl; } //
      import ./resolve.nix { inherit (final) lib; } //
      import ./support.nix { inherit (final) lib; };
  };

  crates-nix = {
    crates-io-index = throw "`crates-nix.crates-io-index` must be set to the path to crates.io-index";
    index = mkIndex crates-io-index;

    toml2json = final.callPackage ./toml2json {};

    buildRustCrate = final.callPackage ./build-rust-crate { inherit toml2json; };

    buildRustCrateFromSrcAndLock = buildRustCrateFromSrcAndLock {
      inherit index buildRustCrate;
      inherit (final) stdenv;
    };
  };
}
