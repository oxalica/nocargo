{ lib }:
let
  inherit (builtins) fromTOML fromJSON toJSON match tryEval split;
  inherit (lib)
    readFile mapAttrs warnIf
    isString replaceStrings hasPrefix
    filter flatten elem elemAt listToAttrs subtractLists concatStringsSep;
  inherit (lib.nocargo)
    mkPkgInfoFromCargoToml getPkgInfoFromIndex resolveDepsFromLock resolveFeatures toPkgId
    platformToCfgs evalTargetCfgStr
    globMatchDir;
in
rec {
  buildRustPackageFromSrcAndLock =
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
    , dontWarnForWorkspace ? false
    , workspacePkgInfos ? {}
    }:
    assert elem profile [ "dev" "release" ];
    let
      cargoToml = fromTOML (readFile cargoTomlFile);
      cargoLock = fromTOML (readFile cargoLockFile);

      rootInfo = mkPkgInfoFromCargoToml cargoToml src // {
        isRootPkg = true;
      };
      rootId = toPkgId rootInfo;

      registries = defaultRegistries // extraRegistries;

      getPkgInfo = { source ? null, name, version, ... }@args: let
        m = match "(registry|git)\\+([^#]*).*" source;
        kind = elemAt m 0;
        url = elemAt m 1;
      in
        # Local crates have no `source`.
        if source == null then
          if name == rootInfo.name && version == rootInfo.version then
            rootInfo
          else
            workspacePkgInfos.${toPkgId args}
              or (throw "Local crate is outside the workspace: ${toPkgId args}")
        else if m == null then
          throw "Invalid source: ${source}"
        else if kind == "registry" then
          getPkgInfoFromIndex
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
            mkPkgInfoFromCargoToml gitCargoToml gitSrc
        else
          throw "Invalid source schema: ${source}";

      pkgSetRaw = resolveDepsFromLock getPkgInfo cargoLock;
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
          args'' = args' // (buildCrateOverrides.${toPkgId info} or lib.id) args';
        in
          buildRustCrate args'';

      pkgsBuild = mapAttrs (id: features: let info = pkgSet.${id}; in
        if features != null then
          buildRustCrate' info {
            inherit (info) version src;
            inherit features profile rustc;
            pname = info.name;
            capLints = if info ? isRootPkg then null else "allow";
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
            capLints = if info ? isRootPkg then null else "allow";
            buildDependencies = selectDeps pkgsBuild info.dependencies features "build" false;
            dependencies = selectDeps pkgs info.dependencies features "normal" false;
            linksDependencies = selectDeps pkgs info.dependencies features "normal" true;
          }
        else
          null
      ) resolvedNormalFeatures;

    in
      warnIf (!dontWarnForWorkspace && cargoToml ? workspace) ''
        `buildRustPackageFromSrcAndLock` doesn't support workspace. Maybe use `buildRustWorkspaceFromSrcAndLock` instead?
      '' pkgs.${rootId};

  sanitizeRelativePath = path:
    if hasPrefix "/" path then
      throw "Absolute path is not allowed: ${path}"
    else
      concatStringsSep "/"
        (filter
          (s:
            isString s && s != "" && s != "." &&
            (if match ''.*[[?*].*|\.\.'' s != null then throw ''
              Globing and `..` are not allowed: ${path}
            '' else true))
          (split ''[\/]'' path));

  # Return a set of derivations keyed by sub-package names.
  buildRustWorkspaceFromSrcAndLock =
    args0:
    { src
    , cargoTomlFile ? src + "/Cargo.toml"
    , cargoLockFile ? src + "/Cargo.lock"
    , ...
    }@args:
    let
      cargoToml = fromTOML (readFile cargoTomlFile);

      selected = flatten (map (glob: globMatchDir glob src) cargoToml.workspace.members);
      excluded = map sanitizeRelativePath (cargoToml.workspace.exclude or []);
      members = subtractLists excluded selected;

      workspacePkgInfos =
        listToAttrs
          (map (relPath:
            let
              memberRoot = src + ("/" + relPath);
              memberManifest = fromTOML (readFile (memberRoot + "/Cargo.toml"));
            in {
              name = toPkgId memberManifest.package;
              value = mkPkgInfoFromCargoToml memberManifest memberRoot;
            }
          )members);

      pathToEntry = path:
        let
          src' = src + ("/" + path);
          cargoTomlFile' = src' + "/Cargo.toml";
          name = (fromTOML (readFile cargoTomlFile')).package.name;
          pkg = buildRustPackageFromSrcAndLock args0 (args // {
            src = src';
            cargoTomlFile = cargoTomlFile';
            # Use the common `Cargo.lock`.
            inherit cargoLockFile;
            # A Cargo.toml may be both workspace and package. Suppress warnings if any.
            dontWarnForWorkspace = true;
            inherit workspacePkgInfos;
          });
        in
      {
        inherit name;
        value = pkg;
      };

      pkgs = listToAttrs (map pathToEntry members);

    in
      if !(cargoToml ? workspace) then
        throw "`buildRustWorkspaceFromSrcAndLock` only support workspace, use `buildRustPackageFromSrcAndLock` instead"
      else if (cargoToml.workspace.members or []) == [] then
        throw "Workspace auto-detection is not supported yet. Please manually specify `workspace.members`"
      else
        pkgs;

  build-from-src-dry-tests = { assertEq, assertEqFile, pkgs, ... }: let
    inherit (builtins) seq toJSON head listToAttrs;

    buildRustPackageFromSrcAndLock' = buildRustPackageFromSrcAndLock {
      inherit (pkgs) stdenv buildPackages;
      inherit (pkgs.nocargo) defaultRegistries;
      buildRustCrate = args: args;
    };

    build = src: args:
      let
        ret = buildRustPackageFromSrcAndLock' ({ inherit src; } // args);
        # deepSeq but don't decent into derivations.
      in seq (toJSON ret) ret;

  in
  {
    simple-features = let ret = build ./tests/simple-features {}; in
      assertEq ret.features [ "a" "default" ];

    dependent = let
      ret = build ./tests/dependent {};
      semver = (head ret.dependencies).drv;
      serde = (head semver.dependencies).drv;
    in assertEq
      { inherit (semver) pname features; serde = serde.pname; }
      { pname = "semver"; features = [ "default" "serde" "std" ]; serde = "serde"; };

    dependent-overrided = let
      ret = build ./tests/dependent {
        buildCrateOverrides."" = old: { a = "b"; };
        buildCrateOverrides."serde 1.0.126 (registry+https://github.com/rust-lang/crates.io-index)" = old: {
          buildInputs = [ "some-inputs" ];
        };
      };
      semver = (head ret.dependencies).drv;
      serde = (head semver.dependencies).drv;
    in
      assertEq serde.buildInputs [ "some-inputs" ];

    dep-source-kinds = let
      mkSrc = from: { __toString = _: ./tests/dep-source-kinds/fake-semver; inherit from; };

      ret = build ./tests/dep-source-kinds {
        gitSources = {
          "https://github.com/dtolnay/semver?tag=1.0.4" = mkSrc "tag";
          "git://github.com/dtolnay/semver?branch=master" = mkSrc "branch";
          "ssh://git@github.com/dtolnay/semver?rev=ea9ea80c023ba3913b9ab0af1d983f137b4110a5" = mkSrc "rev";
          "ssh://git@github.com/dtolnay/semver" = mkSrc "nothing";
        };
      };
      ret' = listToAttrs
        (map (dep: {
          name = if dep.rename != null then dep.rename else dep.drv.pname;
          value = dep.drv.src.from or dep.drv.src.name;
        }) ret.dependencies);
    in
      assertEq ret' {
        bitflags = "crate-bitflags-1.3.2.tar.gz";
        cfg_if2 = "crate-cfg-if-1.0.0.tar.gz";
        semver1 = "tag";
        semver2 = "branch";
        semver3 = "rev";
        semver4 = "nothing";
      };

    openssl = let
      ret = build ./tests/test-openssl {};
      openssl = (head ret.dependencies).drv;
      openssl-sys = (head openssl.linksDependencies).drv;
    in
      assertEq (head openssl-sys.propagatedBuildInputs).pname "openssl";

    libz-link = let
      ret = build ./tests/libz-link {};
      libz = (head ret.dependencies).drv;
      libz' = (head ret.linksDependencies).drv;
    in
      assertEq [ libz.links libz'.links ] [ "z" "z" ];
  };

  sanitize-relative-path-tests = { assertEq, ... }: let
    assertOk = raw: expect: assertEq (tryEval (sanitizeRelativePath raw)) { success = true; value = expect; };
    assertInvalid = raw: assertEq (tryEval (sanitizeRelativePath raw)) { success = false; value = false; };
  in
  {
    empty = assertOk "" "";
    simple1 = assertOk "foo" "foo";
    simple2 = assertOk "foo/bar" "foo/bar";
    dot1 = assertOk "." "";
    dot2 = assertOk "./././" "";
    dot3 = assertOk "./foo/./bar/" "foo/bar";

    dotdot1 = assertInvalid "..";
    dotdot2 = assertInvalid "./foo/..";
    dotdot3 = assertInvalid "../bar";
    root1 = assertInvalid "/";
    root2 = assertInvalid "/foo";
  };
}
