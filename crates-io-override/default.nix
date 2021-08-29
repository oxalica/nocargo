{ lib, pkgs }:
with pkgs;
let
  inherit (lib) optionalAttrs;
in
{
  openssl-sys = { features, ... }: optionalAttrs (!(features ? vendored)) {
    nativeBuildInputs = [ pkg-config ];
    # buildInputs = [ openssl ];
    propagatedBuildInputs = [ openssl ];
  };
}
