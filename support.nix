{ lib }:
let
  inherit (builtins) fromTOML fromJSON toJSON match;
  inherit (lib) readFile mapAttrs filter replaceStrings elem elemAt;
  inherit (lib.nocargo)
    mkCrateInfoFromCargoToml getCrateInfoFromIndex resolveDepsFromLock resolveFeatures
    platformToCfgs evalTargetCfgStr;
in
rec {
  buildRustCrateFromSrcAndLock =
    { defaultRegistries, buildRustCrate, stdenv, buildPackages }:
    { src
    , cargoTomlFile ? src + "/Cargo.toml"
    , cargoLockFile ? src + "/Cargo.lock"
    , features ? null
    , profile ? "release"
    , extraRegistries ? {}
    , gitSources ? {}
    , rustc ? buildPackages.rustc
    , buildCrateOverrides ? {}
    }:
    assert elem profile [ "dev" "release" ];
    let
      cargoToml = fromTOML (readFile cargoTomlFile);
      cargoLock = fromTOML (readFile cargoLockFile);

      toCrateId = info: "${info.name} ${info.version} (${info.source or ""})";

      rootInfo = mkCrateInfoFromCargoToml cargoToml src // {
        isRootCrate = true;
      };
      rootId = toCrateId rootInfo;

      registries = defaultRegistries // extraRegistries;

      getCrateInfo = { source ? null, name, version, ... }@args: let
        m = match "(registry|git)\\+([^#]*).*" source;
        kind = elemAt m 0;
        url = elemAt m 1;
      in
        if source == null then
          if name == rootInfo.name && version == rootInfo.version then
            rootInfo
          else
            throw "Local path dependency is not supported yet"
        else if m == null then
          throw "Invalid source: ${source}"
        else if kind == "registry" then
          getCrateInfoFromIndex
            (registries.${url} or
              (throw "Registry `${url}` not found. Please specify it in `extraRegistries`."))
            args
          // { inherit source; } # `source` is for crate id, which is used for overrides.
        else if kind == "git" then
          let
            gitSrc = gitSources.${url} or
              (throw "Git source `${url}` not found. Please specify it in `gitSources`.");
            gitCargoToml = fromTOML (readFile (gitSrc + "/Cargo.toml"));
          in
            mkCrateInfoFromCargoToml gitCargoToml gitSrc
        else
          throw "Invalid source schema: ${source}";

      pkgSetRaw = resolveDepsFromLock getCrateInfo cargoLock;
      pkgSet = mapAttrs (id: info: info // {
        dependencies = map (dep: dep // {
          targetEnabled = dep.target != null -> evalTargetCfgStr hostCfgs dep.target;
        }) info.dependencies;
      }) pkgSetRaw;

      hostCfgs = platformToCfgs stdenv.hostPlatform;

      rootFeatures = if features != null then features
        else if rootInfo.features ? default then [ "default" ]
        else [];

      resolvedBuildFeatures = resolveFeatures {
        inherit pkgSet rootId rootFeatures;
        depFilter = dep: dep.targetEnabled && dep.kind == "normal" || dep.kind == "build";
      };
      resolvedNormalFeatures = resolveFeatures {
        inherit pkgSet rootId rootFeatures;
        depFilter = dep: dep.targetEnabled && dep.kind == "normal";
      };

      selectDeps = pkgs: deps: features: selectKind: onlyLinks:
        map
          (dep: { rename = dep.rename or null; drv = pkgs.${dep.resolved}; })
          (filter
            ({ kind, name, optional, targetEnabled, resolved, ... }@dep:
              targetEnabled && kind == selectKind
              && (optional -> elem name features)
              && (if resolved == null then throw "Unresolved dependency: ${toJSON dep}" else true)
              && (onlyLinks -> pkgSet.${resolved}.links != null))
            deps);

      buildRustCrate' = info: args:
        let
          args' = args // (info.__override or lib.id) args;
          args'' = args' // (buildCrateOverrides.${toCrateId info} or lib.id) args';
        in
          buildRustCrate args'';

      pkgsBuild = mapAttrs (id: features: let info = pkgSet.${id}; in
        if features != null then
          buildRustCrate' info {
            inherit (info) version src;
            inherit features profile rustc;
            pname = info.name;
            capLints = if info ? isRootCrate then null else "allow";
            buildDependencies = selectDeps pkgsBuild info.dependencies features "build" false;
            # Build dependency's normal dependency is still build dependency.
            dependencies = selectDeps pkgsBuild info.dependencies features "normal" false;
            linksDependencies = selectDeps pkgsBuild info.dependencies features "normal" true;
          }
        else
          null
      ) resolvedBuildFeatures;

      pkgs = mapAttrs (id: features: let info = pkgSet.${id}; in
        if features != null then
          buildRustCrate' info {
            inherit (info) version src links;
            inherit features profile rustc;
            pname = info.name;
            capLints = if info ? isRootCrate then null else "allow";
            buildDependencies = selectDeps pkgsBuild info.dependencies features "build" false;
            dependencies = selectDeps pkgs info.dependencies features "normal" false;
            linksDependencies = selectDeps pkgs info.dependencies features "normal" true;
          }
        else
          null
      ) resolvedNormalFeatures;

    in
      pkgs.${rootId};

  build-from-src-dry-tests = { assertEqFile, pkgs, ... }: let
    buildRustCrateFromSrcAndLock' = buildRustCrateFromSrcAndLock {
      inherit (pkgs) stdenv buildPackages;
      inherit (pkgs.nocargo) defaultRegistries;
      buildRustCrate = args: removeAttrs args [ "src" "rustc" ];
    };
    test = src: args: test' src (src + "/dry-build.json") args;
    test' = src: expectFile: args: let
      got = buildRustCrateFromSrcAndLock' ({ inherit src; } // args);
    in
      assertEqFile got expectFile;
  in
  {
    simple-features = test ./tests/simple-features {};
    dependent = test ./tests/dependent {};
    tokio-app = test ./tests/tokio-app {};
    dep-source-kinds = test ./tests/dep-source-kinds {
      gitSources = {
        "https://github.com/dtolnay/semver?tag=1.0.4" = ./tests/dep-source-kinds/fake-semver;
        "git://github.com/dtolnay/semver?branch=master" = ./tests/dep-source-kinds/fake-semver;
        "ssh://git@github.com/dtolnay/semver?rev=ea9ea80c023ba3913b9ab0af1d983f137b4110a5" = ./tests/dep-source-kinds/fake-semver;
        "ssh://git@github.com/dtolnay/semver" = ./tests/dep-source-kinds/fake-semver;
      };
    };
    openssl = test ./tests/test-openssl {};
    libz-link = test ./tests/libz-link {};

    dependent-overrided = test' ./tests/dependent ./tests/dependent/dry-build-overrided.json {
      buildCrateOverrides."" = old: { a = "b"; };
      buildCrateOverrides."serde 1.0.126 (registry+https://github.com/rust-lang/crates.io-index)" = old: {
        buildInputs = [ "some-inputs" ];
      };
    };
  };
}
