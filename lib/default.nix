{ lib, nix-filter }:
let
  callLib = file: import file { inherit lib self; };
  self = {
    glob = callLib ./glob.nix;
    semver = callLib ./semver.nix;
    target-cfg = callLib ./target-cfg.nix;

    pkg-info = callLib ./pkg-info.nix;
    resolve = callLib ./resolve.nix;
    support = callLib ./support.nix;
    inherit nix-filter;
  };
in self
