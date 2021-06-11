let pkgs = import <nixpkgs> {}; in
import ./. {
  pkgs = import <nixpkgs> {
    overlays = [
      (builtins.getFlake (toString ../.)).outputs.overlay
      (builtins.getFlake "rust-overlay").outputs.overlay
      (final: prev: {
        rustc = final.rust-bin.stable.latest.minimal;
      })
    ];
  };
}

