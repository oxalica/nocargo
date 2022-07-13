{ lib, pkgs }:
with pkgs;
let
  inherit (lib) optionalAttrs;
in
{
  libz-sys = { features, ... }: optionalAttrs (!(features ? static)) {
    nativeBuildInputs = [ pkg-config ];
    propagatedBuildInputs = [ zlib ];
  };

  openssl-sys = { features, ... }: optionalAttrs (!(features ? vendored)) {
    nativeBuildInputs = [ pkg-config ];
    propagatedBuildInputs = [ openssl ];
  };
}
