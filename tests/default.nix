{ pkgs ? import <nixpkgs> { overlays = [ (builtins.getFlake (toString ../.)).outputs.overlay ]; } }:
let
  inherit (pkgs) lib;
  build = src: profile: pkgs.nocargo.buildRustCrateFromSrcAndLock { inherit src profile; };
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
