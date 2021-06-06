{ lib, stdenv, buildPackages, rust, toml2json, jq }:
let toCrateName = lib.replaceStrings [ "-" ] [ "_" ]; in
{ pname
, crateName ? toCrateName pname
, version
, src
# [ { name = "foo"; drv = <derivation>; } ]
, dependencies ? []
, buildDependencies ? []
, features ? []
, nativeBuildInputs ? []
, ...
}@args:
let
  mkRustcMeta = dependencies: features: let
    deps = lib.concatMapStrings (dep: dep.drv.rustcMeta) dependencies;
    feats = lib.concatStringsSep ";" features;
    final = "${crateName} ${version} ${feats} ${deps}";
  in
    lib.substring 0 16 (builtins.hashString "sha256" final);

  mkDeps = map ({ name, drv, ... }: lib.concatStringsSep ":" [
    (toCrateName name)
    "lib${drv.crateName}-${drv.rustcMeta}"
    drv.out
    drv.dev
  ]);

in
stdenv.mkDerivation ({
  pname = "rust_${pname}";
  inherit crateName version src features;

  builder = ./builder.sh;
  outputs = [ "out" "dev" ];

  buildRustcMeta = mkRustcMeta buildDependencies [];
  rustcMeta = mkRustcMeta dependencies features;

  rustBuildTarget = rust.toRustTarget stdenv.buildPlatform;
  rustHostTarget = rust.toRustTarget stdenv.hostPlatform;

  nativeBuildInputs = [ toml2json jq ] ++ nativeBuildInputs;

  BUILD_RUSTC = "${buildPackages.buildPackages.rustc}/bin/rustc";
  RUSTC = "${buildPackages.rustc}/bin/rustc";

  buildDependencies = mkDeps buildDependencies;
  dependencies = mkDeps dependencies;

} // removeAttrs args [
  "pname"
  "dependencies"
  "buildDependencies"
  "features"
  "nativeBuildInputs"
])
