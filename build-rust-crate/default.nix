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
, buildFlags ? []
, buildScriptBuildFlags ? []

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

  # https://doc.rust-lang.org/cargo/reference/profiles.html
  profileToRustcFlags = p:
    []
    ++ lib.optional (p.opt-level or 0 != 0) "-Copt-level=${toString p.opt-level}"
    ++ lib.optional (p.debug or false != false) "-Cdebuginfo=${if p.debug == true then "2" else toString p.debug}"
    # TODO: `-Cstrip` is not handled since stdenv will always strip them.
    ++ lib.optional (p ? debug-assertions) "-Cdebug-assertions=${convertBool "no" "yes" p.debug-assertions}"
    ++ lib.optional (p ? overflow-checks) "-Coverflow-checks=${convertBool "no" "yes" p.debug-assertions}"
    ++ lib.optional (p.lto or false != false) "-Clto=${if p.lto == true then "fat" else p.lto}"
    ++ lib.optional (p.panic or "unwind" != "unwind") "-Cpanic=${p.panic}"
    # `incremental` is not useful since Nix builds in a sandbox.
    ++ lib.optional (p ? codegen-units) "-Ccodegen-units=${toString p.codegen-units}"
    ++ lib.optional (p.rpath or false) "-Crpath"

    ++ lib.optional (p.lto or false == false) "-Cembed-bitcode=no"
    ;

  convertProfile = p: {
    buildFlags =
      profileToRustcFlags p
      ++ lib.optional (capLints != null) "--cap-lints=${capLints}"
      ++ buildFlags;

    buildScriptBuildFlags =
      profileToRustcFlags (p.build-override or {})
      ++ buildScriptBuildFlags;

    # Build script environments.
    PROFILE = p.name or null;
    OPT_LEVEL = p.opt-level or 0;
    DEBUG = p.debug or 0 != 0;
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

  } // commonArgs // cargoCfgs // buildProfile');

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
