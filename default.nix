final: prev:
let
  inherit (final.lib.nocargo) mkIndex buildRustCrateFromSrcAndLock;
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
    index = mkIndex final.nocargo.crates-io-index;

    nocargo = final.nocargo.buildRustCrateFromSrcAndLock { src = ./nocargo; };

    toml2json = final.callPackage ./toml2json {};

    buildRustCrate = final.callPackage ./build-rust-crate { inherit (final.nocargo) toml2json; };

    buildRustCrateFromSrcAndLock = buildRustCrateFromSrcAndLock {
      inherit (final.nocargo) index buildRustCrate;
      inherit (final) stdenv;
    };
  };
}
