{ pkgs ? import <nixpkgs> { overlays = [ (builtins.getFlake (toString ../.)).outputs.overlay ]; } }:
let build = src: pkgs.nocargo.buildRustCrateFromSrcAndLock { inherit src; }; in
{
  simple-features = build ./simple-features;
  dependent = build ./dependent;
  tokio-app = build ./tokio-app;
  libz-link = build ./libz-link;
}
