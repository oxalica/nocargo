{ lib, nocargo-lib, stdenv, buildPackages, rust, toml2json, jq }:
{ pname
, version
, src
, rustc ? buildPackages.rustc
, links ? null
# [ { rename = "foo" /* or null */; drv = <derivation>; } ]
, dependencies ? []
# Normal dependencies with non empty `links`, which will propagate `DEP_<LINKS>_<META>` environments to build script.
, linksDependencies ? dependencies
, buildDependencies ? []
, features ? []
, profile ? {}
, capLints ? null

, nativeBuildInputs ? []
, propagatedBuildInputs ? []
, ...
}@args:
let
  inherit (nocargo-lib.target-cfg) platformToCfgAttrs;

  mkRustcMeta = dependencies: features: let
    deps = lib.concatMapStrings (dep: dep.drv.rustcMeta) dependencies;
    feats = lib.concatStringsSep ";" features;
    final = "${pname} ${version} ${feats} ${deps}";
  in
    lib.substring 0 16 (builtins.hashString "sha256" final);

  buildRustcMeta = mkRustcMeta buildDependencies [];
  rustcMeta = mkRustcMeta dependencies [];

  mkDeps = map ({ rename, drv, ... }: lib.concatStringsSep ":" [
    (toString rename)
    drv.out
    drv.dev
  ]);
  toDevDrvs = map ({ drv, ... }: drv.dev);

  buildDeps = mkDeps buildDependencies;
  libDeps = mkDeps dependencies;

  builderCommon = ./builder-common.sh;

  convertBool = f: t: x:
    if x == true then t
    else if x == false then f
    else x;

  convertProfile = p: {
    profileName = p.name or null; # Build profile has no name.
    optLevel = p.opt-level or null;
    debugInfo = convertBool 0 2 (p.debug or null);
    debugAssertions = convertBool "no" "yes" (p.debug-assertions or null);
    overflowChecks = convertBool "no" "yes" (p.overflow-checks or null);
    lto = convertBool "no" "yes" (p.lto or null);
    panic = p.panic or null;
    codegenUnits = p.codegen-units or null;
    rpath = convertBool "no" "yes" (p.rpath or null);
  };
  profile' = convertProfile profile;
  buildProfile' = convertProfile (profile.build-override or {});

  commonArgs = {
    inherit pname version src;

    nativeBuildInputs = [ toml2json jq ] ++ nativeBuildInputs;

    sharedLibraryExt = stdenv.hostPlatform.extensions.sharedLibrary;

    inherit capLints;

    RUSTC = "${rustc}/bin/rustc";
  } // removeAttrs args [
    "pname"
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

  cargoCfgs = lib.mapAttrs' (key: value: {
    name = "CARGO_CFG_${lib.toUpper key}";
    value = if lib.isList value then lib.concatStringsSep "," value
      else if value == true then ""
      else value;
  }) (platformToCfgAttrs stdenv.hostPlatform);

  buildDrv = stdenv.mkDerivation ({
    name = "rust_${pname}-${version}-build";
    builder = ./builder-build-script.sh;
    inherit propagatedBuildInputs builderCommon features links;
    rustcMeta = buildRustcMeta;
    dependencies = buildDeps;

    linksDependencies = map (dep: dep.drv.buildDrv) linksDependencies;

    HOST = rust.toRustTarget stdenv.buildPlatform;
    TARGET = rust.toRustTarget stdenv.hostPlatform;

    # This drv links for `build_script_build`.
    # So include transitively propagated upstream `-sys` crates' ld dependencies.
    buildInputs = toDevDrvs dependencies;

    # Build script may produce object files and static libraries which should not be modified.
    dontFixup = true;

  } // commonArgs // buildProfile');

  libDrv = stdenv.mkDerivation ({
    name = "rust_${pname}-${version}";

    builder = ./builder-lib.sh;
    outputs = [ "out" "dev" ];
    inherit builderCommon buildDrv features rustcMeta;

    # Transitively propagate upstream `-sys` crates' ld dependencies.
    # Since `rlib` doesn't link.
    propagatedBuildInputs = toDevDrvs dependencies ++ propagatedBuildInputs;

    dependencies = libDeps;

  } // commonArgs // profile');

  binDrv = stdenv.mkDerivation ({
    name = "rust_${pname}-${version}-bin";
    builder = ./builder-bin.sh;
    inherit propagatedBuildInputs builderCommon buildDrv features rustcMeta;

    libOutDrv = libDrv.out;
    libDevDrv = libDrv.dev;

    # This requires linking.
    # Include transitively propagated upstream `-sys` crates' ld dependencies.
    buildInputs = toDevDrvs dependencies;

    dependencies = libDeps;
  } // commonArgs // profile');

in
  libDrv // {
    build = buildDrv;
    bin = binDrv;
  }
