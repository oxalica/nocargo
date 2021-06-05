{ lib, stdenv, buildPackages, rust, yj, jq }:
{ crateName
, version
, src
# [ { name = "foo"; drv = <derivation>; } ]
, dependencies ? []
# TODO: buildDependencies
, features ? []
, nativeBuildInputs ? []
, ...
}@args:
let
  rustcMeta = let
    deps = lib.concatMapStrings (dep: dep.drv.rustcMeta) dependencies;
    feats = lib.concatStringsSep ";" features;
    final = "${crateName} ${version} ${feats} ${deps}";
  in
    lib.substring 0 16 (builtins.hashString "sha256" final);

  # Extensions are not included here.
  mkDeps = map ({ name, drv, ... }:
    "${name}:${drv}/lib/lib${drv.crateName}-${drv.rustcMeta}:${drv.dev}/nix-support/rustc-dep-closure");

in
stdenv.mkDerivation ({
  pname = "rust_${crateName}";
  inherit crateName version src features rustcMeta;

  outputs = [ "out" "dev" ];

  builder = ./builder.sh;

  rustcBuildTarget = rust.toRustTarget stdenv.buildPlatform;
  rustcHostTarget = rust.toRustTarget stdenv.hostPlatform;

  nativeBuildInputs = [ yj jq ] ++ nativeBuildInputs;

  BUILD_RUSTC = "${buildPackages.buildPackages.rustc}/bin/rustc";
  RUSTC = "${buildPackages.rustc}/bin/rustc";

  dependencies = mkDeps dependencies;

  dontInstall = true;

} // removeAttrs args [
  "dependencies"
  "features"
  "nativeBuildInputs"
  "dependencyDef"
  "featureDef"
])
