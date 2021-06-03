import <nixpkgs> {
  overlays = [
    (builtins.getFlake (toString ./.)).outputs.overlay
  ];
}
