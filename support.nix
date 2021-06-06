{ lib }:
let
  inherit (builtins) fromTOML fromJSON;
  inherit (lib) readFile mapAttrs filter replaceStrings elem id;
  inherit (lib.crates-nix)
    mkCrateInfoFromCargoToml getCrateInfoFromIndex resolveDepsFromLock resolveFeatures
    platformToCfgs evalTargetCfgStr;
in
rec {
  buildRustCrateFromSrcAndLock =
    { index, buildRustCrate, stdenv }:
    { src
    , cargoTomlFile ? src + "/Cargo.toml"
    , cargoLockFile ? src + "/Cargo.lock"
    , features ? null
    }:
    let
      cargoToml = fromTOML (readFile cargoTomlFile);
      cargoLock = fromTOML (readFile cargoLockFile);

      rootInfo = mkCrateInfoFromCargoToml cargoToml src;
      rootId = "${rootInfo.name} ${rootInfo.version} ()";

      getCrateInfo' = args:
        if args ? source then
          getCrateInfoFromIndex index args
        else
          assert args.name == rootInfo.name && args.version == rootInfo.version;
          rootInfo;

      pkgSetRaw = resolveDepsFromLock getCrateInfo' cargoLock;
      pkgSet = mapAttrs (id: info: info // {
        dependencies =
          filter
            (dep: dep.target != null -> evalTargetCfgStr hostCfgs dep.target)
            info.dependencies;
      }) pkgSetRaw;

      hostCfgs = platformToCfgs stdenv.hostPlatform;

      rootFeatures = if features != null then features
        else if rootInfo.features ? default then [ "default" ]
        else [];

      resolvedBuildFeatures = resolveFeatures {
        inherit pkgSet rootId rootFeatures;
        depFilter = dep: dep.kind == "normal" || dep.kind == "build";
      };
      resolvedNormalFeatures = resolveFeatures {
        inherit pkgSet rootId rootFeatures;
        depFilter = dep: dep.kind == "normal";
      };

      selectDeps = pkgs: deps: features: selectKind:
        map (dep: { name = dep.name; drv = pkgs.${dep.resolved}; })
          (filter ({ kind, name, optional, ... }:
            kind == selectKind && (optional -> elem name features))
          deps);

      pkgsBuild = mapAttrs (id: features: let info = pkgSet.${id}; in
        if features != null then
          buildRustCrate {
            inherit (info) version src;
            inherit features;
            pname = info.name;
            buildDependencies = selectDeps pkgsBuild info.dependencies features "build";
            # Build dependency's normal dependency is still build dependency.
            dependencies = selectDeps pkgsBuild info.dependencies features "normal";
          }
        else
          null
      ) resolvedBuildFeatures;

      pkgs = mapAttrs (id: features: let info = pkgSet.${id}; in
        if features != null then
          buildRustCrate {
            inherit (info) version src;
            inherit features;
            pname = info.name;
            buildBins = if id == rootId then "*" else null;
            buildDependencies = selectDeps pkgsBuild info.dependencies features "build";
            dependencies = selectDeps pkgs info.dependencies features "normal";
          }
        else
          null
      ) resolvedNormalFeatures;

    in
      pkgs.${rootId};

  build-from-src-dry-tests = { assertDeepEq, ... }: { crates-nix, stdenv }: let
    buildRustCrateFromSrcAndLock' = buildRustCrateFromSrcAndLock {
      inherit (crates-nix) index;
      inherit stdenv;
      buildRustCrate = args: removeAttrs args [ "src" ];
    };
    test = src: let
      got = buildRustCrateFromSrcAndLock' { inherit src; };
      expect = fromJSON (readFile (src + "/dry-build.json"));
    in
      assertDeepEq got expect;
  in
  {
    build-from-src-dry-simple-features = test ./tests/simple-features;
    build-from-src-dry-dependent = test ./tests/dependent;
    build-from-src-dry-tokio-app = test ./tests/tokio-app;
  };
}
