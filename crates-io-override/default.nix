{ lib, pkgs }:
let
  inherit (lib) optionalAttrs listToAttrs;
  inherit (builtins) compareVersions;
  procMacroOverrides =
    listToAttrs
      (map (name: {
        inherit name;
        value = _: { procMacro = true; };
      }) (import ./proc-macro.nix));
in
with pkgs;
procMacroOverrides //
{
  libz-sys = { features, ... }: optionalAttrs (!(features ? static)) {
    nativeBuildInputs = [ pkg-config ];
    propagatedBuildInputs = [ zlib ];
  };

  openssl-sys = { features, ... }: optionalAttrs (!(features ? vendored)) {
    nativeBuildInputs = [ pkg-config ];
    propagatedBuildInputs = [ openssl ];
  };

  proc-macro-hack = { version, ... }: {
    procMacro = compareVersions version "0.5.0" >= 0;
  };
}
