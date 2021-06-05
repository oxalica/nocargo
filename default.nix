final: prev:
let
  inherit (final.lib.crates-nix) mkIndex;
  inherit (final.crates-nix) crates-io-index;
in
{
  lib = prev.lib // {
    crates-nix =
      import ./semver.nix { inherit (final) lib; } //
      import ./target-cfg.nix { inherit (final) lib; } //
      import ./crate-info.nix { inherit (final) lib fetchurl; } //
      import ./resolve.nix { inherit (final) lib; };
  };

  crates-nix = {
    crates-io-index = throw "`crates-nix.crates-io-index` must be set to the path to crates.io-index";
    index = mkIndex crates-io-index;

    buildRustCrate = final.callPackage ./build-rust-crate {};
  };
}
