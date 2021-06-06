final: prev:
let
  inherit (final.lib.nocargo) mkIndex buildRustCrateFromSrcAndLock;
  inherit (final.nocargo) crates-io-index index buildRustCrate toml2json;
in
{
  lib = prev.lib // {
    nocargo =
      import ./semver.nix { inherit (final) lib; } //
      import ./target-cfg.nix { inherit (final) lib rust; } //
      import ./crate-info.nix { inherit (final) lib fetchurl; } //
      import ./resolve.nix { inherit (final) lib; } //
      import ./support.nix { inherit (final) lib; };
  };

  nocargo = {
    crates-io-index = throw "`nocargo.crates-io-index` must be set to the path to crates.io-index";
    index = mkIndex crates-io-index;

    toml2json = final.callPackage ./toml2json {};

    buildRustCrate = final.callPackage ./build-rust-crate { inherit toml2json; };

    buildRustCrateFromSrcAndLock = buildRustCrateFromSrcAndLock {
      inherit index buildRustCrate;
      inherit (final) stdenv;
    };
  };
}
