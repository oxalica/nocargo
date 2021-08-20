{ pkgs ? import <nixpkgs> { overlays = [ (builtins.getFlake (toString ../.)).outputs.overlay ]; } }:
let
  inherit (pkgs) lib;

  git-semver = builtins.fetchTarball {
    url = "https://github.com/dtolnay/semver/archive/1.0.4/master.tar.gz";
    sha256 = "1l2nkfmjgz2zkqw03hmy66q0v1rxvs7fc4kh63ph4lf1924wrmix";
  };

  gitSources = {
    "https://github.com/dtolnay/semver?tag=1.0.4" = git-semver;
    "git://github.com/dtolnay/semver?branch=master" = git-semver;
    "ssh://git@github.com/dtolnay/semver?rev=ea9ea80c023ba3913b9ab0af1d983f137b4110a5" = git-semver;
    "ssh://git@github.com/dtolnay/semver" = git-semver;
  };

  build = src: profile: pkgs.nocargo.buildRustCrateFromSrcAndLock {
    inherit src profile gitSources;
  };

  f = name: type:
    if type != "directory" then null else
    [
      { name = name; value = build (./. + "/${name}") "release"; }
      { name = name + "-dev"; value = build (./. + "/${name}") "dev"; }
    ];
in
  lib.listToAttrs
    (lib.flatten
      (lib.filter
        (x: x != null)
        (lib.mapAttrsToList
          f
          (builtins.readDir ./.))))
