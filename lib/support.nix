{ lib, self }:
let
  inherit (builtins) fromTOML toJSON match tryEval split;
  inherit (lib)
    readFile mapAttrs mapAttrs' assertMsg makeOverridable warnIf
    isString hasPrefix
    head filter flatten elem elemAt listToAttrs subtractLists concatStringsSep
    attrNames attrValues recursiveUpdate optionalAttrs;
  inherit (self.pkg-info) mkPkgInfoFromCargoToml getPkgInfoFromIndex toPkgId;
  inherit (self.resolve) resolveDepsFromLock resolveFeatures;
  inherit (self.target-cfg) platformToCfgs evalTargetCfgStr;
  inherit (self.glob) globMatchDir;
in
rec {

  # https://doc.rust-lang.org/cargo/reference/profiles.html#default-profiles
  defaultProfiles = rec {
    dev = {
      name = "dev";
      build-override = defaultBuildProfile;
      opt-level = 0;
      debug = true;
      debug-assertions = true;
      overflow-checks = true;
      lto = false;
      panic = "unwind";
      codegen-units = 256;
      rpath = false;
    };
    release = {
      name = "release";
      build-override = defaultBuildProfile;
      opt-level = 3;
      debug = false;
      debug-assertions = false;
      overflow-checks = false;
      lto = false;
      panic = "unwind";
      codegen-units = 16;
      rpath = false;
    };
    test = dev // { name = "test"; };
    bench = release // { name = "bench"; };
  };

  defaultBuildProfile = {
    opt-level = 0;
    codegen-units = 256;
  };

  profilesFromManifest = manifest:
    let
      knownFields = [
        "name"
        "inherits"
        # "package" # Unsupported yet.
        "build-override"

        "opt-level"
        "debug"
        # split-debug-info # Unsupported.
        "strip"
        "debug-assertions"
        "overflow-checks"
        "lto"
        "panic"
        # incremental # Unsupported.
        "codegen-units"
        "rpath"
      ];

      profiles = mapAttrs (name: p:
        let unknown = removeAttrs p knownFields; in
        warnIf (unknown != {}) "Unsupported fields of profile ${name}: ${toString (attrNames unknown)}"
          (optionalAttrs (p ? inherits) profiles.${p.inherits} // p)
      ) (recursiveUpdate defaultProfiles (manifest.profile or {}));

    in profiles;

  mkRustPackage =
    { defaultRegistries, pkgsBuildHost, buildRustCrate, stdenv }@default:
    { src # : Path
    , gitSrcs ? {} # : Attrset Path
    , buildCrateOverrides ? {} # : Attrset (Attrset _)
    , extraRegistries ? {} # : Attrset Registry
    , registries ? defaultRegistries // extraRegistries

    , rustc ? pkgsBuildHost.rustc
    , stdenv ? default.stdenv
    }:
    let
      manifest = fromTOML (readFile (src + "/Cargo.toml"));

      profiles = profilesFromManifest manifest;

      ws = mkRustPackageSet {
        lock = fromTOML (readFile (src + "/Cargo.lock"));

        localSrcInfos.${toPkgId manifest.package} = mkPkgInfoFromCargoToml manifest src;

        gitSrcInfos = mapAttrs (url: src:
          mkPkgInfoFromCargoToml (fromTOML (readFile (src + "/Cargo.toml"))) src
        ) gitSrcs;

        inherit profiles buildRustCrate buildCrateOverrides registries rustc stdenv;
      };

    in
    assert assertMsg (!(manifest ? workspace)) ''
      `mkRustPackage` called on a workspace: ${src}
      Do you mean to call `mkRustWorkspace`?
    '';
    mapAttrs (_: members: head (attrValues members))
      ws;

  mkRustWorkspace =
    { defaultRegistries, pkgsBuildHost, buildRustCrate, stdenv }@default:
    { src # : Path
    , gitSrcs ? {} # : Attrset Path
    , buildCrateOverrides ? {} # : Attrset (Attrset _)
    , extraRegistries ? {} # : Attrset Registry
    , registries ? defaultRegistries // extraRegistries

    , rustc ? pkgsBuildHost.rustc
    , stdenv ? default.stdenv
    }:
    let
      manifest = fromTOML (readFile (src + "/Cargo.toml"));

      profiles = profilesFromManifest manifest;

      selected = flatten (map (glob: globMatchDir glob src) manifest.workspace.members);
      excluded = map sanitizeRelativePath (manifest.workspace.exclude or []);
      members = subtractLists excluded selected;

      localSrcInfos = listToAttrs
        (map (relativePath:
          let
            memberRoot = src + ("/" + relativePath);
            memberManifest = fromTOML (readFile (memberRoot + "/Cargo.toml"));
          in {
            name = toPkgId memberManifest.package;
            value = mkPkgInfoFromCargoToml memberManifest memberRoot;
          }
        ) members);

    in
    mkRustPackageSet {
      lock = fromTOML (readFile (src + "/Cargo.lock"));

      gitSrcInfos = mapAttrs (url: src:
        mkPkgInfoFromCargoToml (fromTOML (readFile (src + "/Cargo.toml"))) src
      ) gitSrcs;

      inherit profiles localSrcInfos buildRustCrate buildCrateOverrides registries rustc stdenv;
    };

  mkRustPackageSet =
    { lock # : <fromTOML>
    , localSrcInfos # : Attrset PkgInfo
    , gitSrcInfos # : Attrset PkgInfo
    , profiles # : Attrset Profile
    , buildCrateOverrides # : Attrset (Attrset _)
    , buildRustCrate # : Attrset -> Derivation
    , registries # : Attrset Registry

    # FIXME: Cross compilation.
    , rustc
    , stdenv
    }:
    let

      getPkgInfo = { source ? null, name, version, ... }@args: let
        m = match "(registry|git)\\+([^#]*).*" source;
        kind = elemAt m 0;
        url = elemAt m 1;
      in
        # Local crates have no `source`.
        if source == null then
          localSrcInfos.${toPkgId args}
            or (throw "Local crate is outside the workspace: ${toPkgId args}")
          // { isLocalPkg = true; }
        else if m == null then
          throw "Invalid source: ${source}"
        else if kind == "registry" then
          getPkgInfoFromIndex
            (registries.${url} or
              (throw "Registry `${url}` not found. Please define it in `extraRegistries`."))
            args
          // { inherit source; } # `source` is for crate id, which is used for overrides.
        else if kind == "git" then
          gitSrcInfos.${url}
            or (throw "Git source `${url}` not found. Please define it in `gitSrcs`.")
        else
          throw "Invalid source: ${source}";

      hostCfgs = platformToCfgs stdenv.hostPlatform;

      pkgSetRaw = resolveDepsFromLock getPkgInfo lock;
      pkgSet = mapAttrs (id: info: info // {
        dependencies = map (dep: dep // {
          targetEnabled = dep.target != null -> evalTargetCfgStr hostCfgs dep.target;
        }) info.dependencies;
      }) pkgSetRaw;

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

      mkPkg = profile: rootId: makeOverridable (
        { features }:
        let
          rootFeatures = if features != null then features
            else if pkgSet.${rootId}.features ? default then [ "default" ]
            else [];

          resolvedBuildFeatures = resolveFeatures {
            inherit pkgSet rootId rootFeatures;
            depFilter = dep: dep.targetEnabled && dep.kind == "normal" || dep.kind == "build";
          };
          resolvedNormalFeatures = resolveFeatures {
            inherit pkgSet rootId rootFeatures;
            depFilter = dep: dep.targetEnabled && dep.kind == "normal";
          };

          pkgsBuild = mapAttrs (id: features: let info = pkgSet.${id}; in
            if features != null then
              buildRustCrate' info {
                inherit (info) version src;
                inherit features profile rustc;
                pname = info.name;
                capLints = if localSrcInfos ? id then null else "allow";
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
                capLints = if localSrcInfos ? id then null else "allow";
                buildDependencies = selectDeps pkgsBuild info.dependencies features "build" false;
                dependencies = selectDeps pkgs info.dependencies features "normal" false;
                linksDependencies = selectDeps pkgs info.dependencies features "normal" true;
              }
            else
              null
          ) resolvedNormalFeatures;
        in
          pkgs.${rootId}
      ) {
        features = null;
      };

    in
      mapAttrs (_: profile:
        mapAttrs' (pkgId: pkgInfo: {
          name = pkgInfo.name;
          value = mkPkg profile pkgId;
        }) localSrcInfos
      ) profiles;

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

  build-from-src-dry-tests = { assertEq, pkgs, defaultRegistries, ... }: let
    inherit (builtins) seq toJSON head listToAttrs;

    mkPackage = pkgs.callPackage mkRustPackage {
      inherit defaultRegistries;
      buildRustCrate = args: args;
    };

    build = src: args: (mkPackage ({ inherit src; } // args)).dev;

  in
  {
    simple-features = let ret = build ../tests/simple-features {}; in
      assertEq ret.features [ "a" "default" ];

    dependent = let
      ret = build ../tests/dependent {};
      semver = (head ret.dependencies).drv;
      serde = (head semver.dependencies).drv;
    in assertEq
      { inherit (semver) pname features; serde = serde.pname; }
      { pname = "semver"; features = [ "default" "serde" "std" ]; serde = "serde"; };

    dependent-overrided = let
      ret = build ../tests/dependent {
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
      mkSrc = from: { __toString = _: ../tests/dep-source-kinds/fake-semver; inherit from; };

      ret = build ../tests/dep-source-kinds {
        gitSrcs = {
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
      ret = build ../tests/test-openssl {};
      openssl = (head ret.dependencies).drv;
      openssl-sys = (head openssl.linksDependencies).drv;
    in
      assertEq (head openssl-sys.propagatedBuildInputs).pname "openssl";

    libz-link = let
      ret = build ../tests/libz-link {};
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
