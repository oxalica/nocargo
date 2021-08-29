{ lib, stdenv, buildPackages, rust, toml2json, jq }:
let toCrateName = lib.replaceStrings [ "-" ] [ "_" ]; in
{ pname
, crateName ? toCrateName pname
, version
, src
, rustc ? buildPackages.rustc
, links ? null
# [ { name = "foo"; drv = <derivation>; } ]
, dependencies ? []
# Normal dependencies with non empty `links`, which will propagate `DEP_<LINKS>_<META>` environments to build script.
, linksDependencies ? dependencies
, buildDependencies ? []
, features ? []
, profile ? "release"
, capLints ? null

, nativeBuildInputs ? []
, propagatedBuildInputs ? []
, ...
}@args:
assert lib.elem profile [ "dev" "release" ];
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
  toDevDrvs = map ({ drv, ... }: drv.dev);

  buildDeps = mkDeps buildDependencies;
  libDeps = mkDeps dependencies;

  builderCommon = ./builder-common.sh;

  profileExt = if profile == "dev" then "-debug" else "";

  commonArgs = {
    inherit crateName version src;

    nativeBuildInputs = [ toml2json jq ] ++ nativeBuildInputs;

    sharedLibraryExt = stdenv.hostPlatform.extensions.sharedLibrary;

    inherit capLints;

    # FIXME: Support custom profiles in Cargo.toml
    inherit profile;
    debugInfo = if profile == "dev" then 2 else null;
    optLevel = if profile == "dev" then null else 3;
    debugAssertions = profile == "dev";

    RUSTC = "${rustc}/bin/rustc";
  } // removeAttrs args [
    "pname"
    "crateName"
    "version"
    "src"
    "rustc"
    "links"
    "dependencies"
    "linksDependencies"
    "buildDependencies"
    "features"
    "profile"
    "capLints"
    "nativeBuildInputs"
    "propagatedBuildInputs"
  ];

  # Build script doesn't need optimization.
  buildScriptProfile = {
    profile = null;
    debug = null;
    optLevel = null;
    debugAssertions = false;
  };

  cargoCfgs = lib.mapAttrs' (key: value: {
    name = "CARGO_CFG_${lib.toUpper key}";
    value = if lib.isList value then lib.concatStringsSep "," value
      else if value == true then ""
      else value;
  }) (lib.nocargo.platformToCfgAttrs stdenv.hostPlatform);

  buildDrv = stdenv.mkDerivation ({
    pname = "rust_${pname}${profileExt}-build";
    name = "rust_${pname}${profileExt}-build-${version}";
    builder = ./builder-build-script.sh;
    inherit propagatedBuildInputs builderCommon features;
    rustcMeta = buildRustcMeta;
    dependencies = buildDeps;

    # This requires link.
    # So include transitively propagated upstream `-sys` crates' ld dependencies.
    buildInputs = toDevDrvs dependencies;

  } // commonArgs // buildScriptProfile);

  buildOutDrv = stdenv.mkDerivation ({
    pname = "rust_${pname}${profileExt}-build-out";
    name = "rust_${pname}${profileExt}-build-out-${version}";
    builder = ./builder-build-script-run.sh;
    inherit propagatedBuildInputs buildDrv builderCommon links;
    linksDependencies = map (dep: dep.drv.buildOutDrv) linksDependencies;

    HOST = rust.toRustTarget stdenv.buildPlatform;
    TARGET = rust.toRustTarget stdenv.hostPlatform;
  } // commonArgs // cargoCfgs);

  libDrv = stdenv.mkDerivation ({
    pname = "rust_${pname}${profileExt}";
    name = "rust_${pname}${profileExt}-${version}";

    builder = ./builder-lib.sh;
    outputs = [ "out" "dev" ];
    inherit builderCommon buildOutDrv features rustcMeta;

    # Transitively propagate upstream `-sys` crates' ld dependencies.
    # Since `rlib` doesn't link.
    propagatedBuildInputs = toDevDrvs dependencies ++ propagatedBuildInputs;

    dependencies = libDeps;

  } // commonArgs);

  binDrv = stdenv.mkDerivation ({
    pname = "rust_${pname}${profileExt}-bin";
    name = "rust_${pname}${profileExt}-bin-${version}";
    builder = ./builder-bin.sh;
    inherit propagatedBuildInputs builderCommon buildOutDrv libDrv features rustcMeta;

    # This requires link.
    # Include transitively propagated upstream `-sys` crates' ld dependencies.
    buildInputs = toDevDrvs dependencies;

    dependencies = libDeps;
  } // commonArgs);

in
  libDrv // {
    build = buildDrv;
    buildOut = buildOutDrv;
    bin = binDrv;
  }
