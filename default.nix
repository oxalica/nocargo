final: prev:
let
  inherit (final.lib.nocargo) mkIndex buildRustCrateFromSrcAndLock buildRustWorkspaceFromSrcAndLock;
in
{
  lib = prev.lib // {
    nocargo =
      import ./semver.nix { inherit (final) lib; } //
      import ./glob.nix { inherit (final) lib; } //
      import ./target-cfg.nix { inherit (final) lib rust; } //
      import ./crate-info.nix { inherit (final) lib fetchurl; } //
      import ./resolve.nix { inherit (final) lib; } //
      import ./support.nix { inherit (final) lib; };
  };

  nocargo = {
    # It will be set in `flake.nix`.
    defaultRegistries = {};

    nocargo = final.nocargo.buildRustCrateFromSrcAndLock { src = ./nocargo; };

    toml2json = final.callPackage ./toml2json {};

    buildRustCrate = final.callPackage ./build-rust-crate { inherit (final.nocargo) toml2json; };

    buildRustCrateFromSrcAndLock = buildRustCrateFromSrcAndLock {
      inherit (final.nocargo) defaultRegistries buildRustCrate;
      inherit (final) stdenv buildPackages;
    };

    buildRustWorkspaceFromSrcAndLock = buildRustWorkspaceFromSrcAndLock {
      inherit (final.nocargo) defaultRegistries buildRustCrate;
      inherit (final) stdenv buildPackages;
    };
  };
}
