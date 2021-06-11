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

  buildRustcMeta = mkRustcMeta buildDependencies [];
  rustcMeta = mkRustcMeta dependencies [];

  mkDeps = map ({ name, drv, ... }: lib.concatStringsSep ":" [
    (toCrateName name)
    "lib${drv.crateName}-${drv.rustcMeta}"
    drv.out
    drv.dev
  ]);

  buildDeps = mkDeps buildDependencies;
  libDeps = mkDeps dependencies;

  builderCommon = ./builder-common.sh;

  commonArgs = {
    inherit crateName version src;

    nativeBuildInputs = [ toml2json jq ];
    sharedLibraryExt = stdenv.hostPlatform.extensions.sharedLibrary;

    RUSTC = "${buildPackages.rustc}/bin/rustc";
  };

  buildDrv = stdenv.mkDerivation ({
    pname = "rust_${pname}-build";
    name = "rust_${pname}-build-${version}";
    builder = ./builder-build-script.sh;
    inherit builderCommon features;
    rustcMeta = buildRustcMeta;
    dependencies = buildDeps;
  } // commonArgs);

  buildOutDrv = stdenv.mkDerivation ({
    pname = "rust_${pname}-build-out";
    name = "rust_${pname}-build-out-${version}";
    builder = ./builder-build-script-run.sh;
    inherit buildDrv builderCommon;
    dependencies = buildDeps;

    HOST = rust.toRustTarget stdenv.buildPlatform;
    TARGET = rust.toRustTarget stdenv.hostPlatform;
    PROFILE = "release";
    DEBUG = 0;
    OPT_LEVEL = 3;
  } // commonArgs);

  libDrv = stdenv.mkDerivation ({
    pname = "rust_${pname}";
    name = "rust_${pname}-${version}";

    builder = ./builder-lib.sh;
    outputs = [ "out" "dev" ];
    inherit builderCommon buildOutDrv features rustcMeta;

    dependencies = libDeps;

  } // commonArgs);

  binDrv = stdenv.mkDerivation ({
    pname = "rust_${pname}-bin";
    name = "rust_${pname}-bin-${version}";
    builder = ./builder-bin.sh;
    inherit builderCommon features rustcMeta libDrv;
    dependencies = libDeps;
  } // commonArgs);

in
  libDrv // {
    build = buildDrv;
    buildOut = buildOutDrv;
    bin = binDrv;
  }
