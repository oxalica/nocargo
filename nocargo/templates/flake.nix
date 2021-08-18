{
  description = "Rust crate {{ crate_name }}";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    crates-io-index = { url = "github:rust-lang/crates.io-index"; flake = false; };
    nocargo = { url = "github:oxalica/nocargo"; inputs.crates-io-index.follows = "crates-io-index"; };
  };

  outputs = { nixpkgs, flake-utils, rust-overlay, nocargo, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [rust-overlay.overlay nocargo.overlay ];
        };
        rustc = pkgs.rust-bin.stable.latest.minimal;
      in
      rec {
        defaultPackage = packages.{{ crate_name_escaped }};
        defaultApp = defaultPackage.bin;
        packages.{{ crate_name_escaped }} = pkgs.nocargo.buildRustCrateFromSrcAndLock {
          # inherit rustc;
          src = ./.;
        };
      });
}
