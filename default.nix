final: prev:
let
  inherit (final.crates-nix) crates-io-index;
  pkgs = {};
in
{
  crates-nix = {
    crates-io-index = throw "`crates-nix.crates-io-index` must be set to the path to crates.io-index";
    inherit pkgs;
  };
}

