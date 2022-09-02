{ lib, self }:
let
  inherit (builtins) readFile match fromTOML fromJSON toJSON;
  inherit (lib)
    foldl' foldr concatStringsSep listToAttrs filter elemAt length optional sort elem flatten
    hasPrefix substring
    attrValues mapAttrs attrNames filterAttrs composeManyExtensions assertMsg;
  inherit (self.semver) parseSemverReq;
  inherit (self.pkg-info) mkPkgInfoFromCargoToml getPkgInfoFromIndex toPkgId sanitizeDep;
in rec {

  # Resolve the dependencies graph based on the lock file.
  # Output:
  # {
  #   "libz-sys 0.1.0 (https://...)" = {
  #     # name, sha256, ... All fields from pkg info.
  #     dependencies = [
  #       {
  #         # name, kind, ... All fields from dependency in the pkg info.
  #         resolved = "libc 0.1.0 (https://...)";
  #       };
  #     };
  #   };
  # }
  #
  # Currently (rust 1.63.0), there are 3 versions of the lock file.
  # We supports V1, V2 and V3.
  # See:
  # https://github.com/rust-lang/cargo/blob/rust-1.63.0/src/cargo/core/resolver/resolve.rs#L56
  # https://github.com/rust-lang/cargo/blob/rust-1.63.0/src/cargo/core/resolver/encode.rs
  resolveDepsFromLock = getPkgInfo: lock: let
    # For git sources, they are referenced without the locked hash part after `#`.
    # Define: "git+https://github.com/dtolnay/semver?tag=1.0.4#ea9ea80c023ba3913b9ab0af1d983f137b4110a5"
    # Reference: "semver 1.0.4 (git+https://github.com/dtolnay/semver?tag=1.0.4)"
    removeUrlHash = s:
      let m = match "([^#]*)#.*" s; in
      if m == null then s else elemAt m 0;

    pkgs = map
      (pkg: if pkg ? source then pkg // { source = removeUrlHash pkg.source; } else pkg)
      lock.package;

    pkgsByName = foldl' (set: { name, ... }@pkg:
      set // { ${name} = (set.${name} or []) ++ [ pkg ]; }
    ) {} pkgs;

    resolved = listToAttrs (map resolvePkg pkgs);

    resolvePkg = { name, version, source ? "", dependencies ? [], ... }@args: let
      info = getPkgInfo args;
      candidates = map findPkgId dependencies;

      id = toPkgId args;
      resolvedDependencies =
        map (dep: dep // {
          resolved = selectDep candidates dep;
        }) info.dependencies;

      # Find the exact package id of a dependency key, which may omit version or source.
      findPkgId = key: let
        m = match "([^ ]+)( ([^ ]+))?( \\(([^\\)]*)\\))?" key;
        lockName = elemAt m 0;
        lockVersion = elemAt m 2;
        lockSource = elemAt m 4;
        candidates =
          filter (pkg:
            (lockVersion != null -> pkg.version == lockVersion) &&
            (lockSource != null -> pkg.source or null == lockSource))
          (pkgsByName.${lockName} or []);
        candidateCnt = length candidates;
      in
        if candidateCnt == 0 then
          throw "When resolving ${id}, locked dependency `${key}` not found"
        else if candidateCnt > 1 then
          throw ''
            When resolving ${id}, locked dependency `${key}` is ambiguous.
            Found: ${toJSON candidates}
          ''
        else
          elemAt candidates 0;

      selectDep = candidates: { name, package, req, source ? null, ... }@dep:
        let
          # Local path or git dependencies don't have version req.
          checkReq = if req != null then parseSemverReq req else (ver: true);
          checkSource = if source != null then s: s == source else s: true;

          selected = filter
            ({ name, version, source ? null, ... }: name == package && checkReq version && checkSource source)
            candidates;

          selectedCnt = length selected;
        in
          if selectedCnt == 0 then
            # Cargo will omit disabled optional dependencies in lock file.
            # throw "When resolving ${pkgName} ${crateVersion}, dependency ${package} ${req} isn't satisfied in lock file"
            null
          else if selectedCnt > 1 then
            throw ''
              When resolving ${id}, dependency ${package} ${if req == null then "*" else req} has multiple candidates in lock file.
              Found: ${toJSON selected}
            ''
          else
            toPkgId (elemAt selected 0);

    in
      {
        name = toPkgId args;
        value = info // { dependencies = resolvedDependencies; };
      };

  in
    assert assertMsg (lock.version or 3 == 3) "Unsupported version of Cargo.lock: ${toString lock.version}";
    resolved;

  # Calculate the closure of each feature, with `dep:pkg` and `pkg?/feat` syntax desugared.
  # [String] -> { [String] } -> { [String | { dep: String, feat?: String }] }
  preprocessFeatures = optionalDeps: defs: let
    allRefs = flatten (attrValues defs);
    defs' =
      listToAttrs
        (map (dep: { name = dep; value = [ "dep:${dep}" ]; })
          (filter (dep: !elem "dep:${dep}" allRefs)
            optionalDeps))
      // defs;
    go = prev: feat:
      let
        m = match "([a-zA-Z0-9]+)(\\?)?/([a-zA-Z0-9]+)" feat;
        depName = elemAt m 0;
        isWeak = elemAt m 1 != null;
        depFeat = elemAt m 2;
      in if elem feat prev then
        prev
      else if defs' ? ${feat} then
        foldl' go ([ feat ] ++ prev) defs'.${feat}
      else if hasPrefix "dep:" feat then
        [ { dep = substring 4 (-1) feat; } ] ++ prev
      else if m == null then
        [ feat ] ++ prev
      else if isWeak then
        [ { dep = depName; feat = depFeat; } ] ++ prev
      else
        [ { dep = depName; } { dep = depName; feat = depFeat; } ] ++ prev;
    fixed = mapAttrs (feat: _: go [ ] feat) defs';
  in
    fixed;

  # Enable `features` in `prev` and do recursive update according to `defs`.
  # Optional dependencies must be included in `defs`.
  enableFeatures = pkgId: defs: prev: features:
    foldl' (prev: feat: let
      m = match "(.*)/.*" feat;
      mDep = elemAt m 0;
      nexts =
        if m == null then
          # Must be defined.
          defs.${feat} or (throw ''
            Feature '${feat}' is invalid for ${pkgId}.
            Possible features: ${concatStringsSep "," (attrNames defs)}
          '')
        else
          # Dependent features implies optional dependency to be enabled.
          # But non-optional dependency doesn't have coresponding feature flag.
          optional (defs ? ${mDep}) mDep;
    in
      if prev.${feat} or false then
        prev
      else
        enableFeatures pkgId defs (prev // { ${feat} = true; }) nexts
    ) prev features;

  # Resolve all features.
  # Note that dependent features like `foo/bar` are only available during resolution,
  # and will be removed in result set.
  #
  # Returns:
  # {
  #   "libc 0.1.0 (https://...)" = [ "default" "foo" "bar" ];
  # }
  resolveFeatures = {
  # Follows the layout of the output of `resolveDepsFromLock`.
    pkgSet
  # Dependency edges (`{ name, kind, resolved, ... }`) will be checked by this filter.
  # Only edges returning `true` are considered and propagated.
  , depFilter ? dep: true
  # Eg. "libc 0.1.0 (https://...)"
  , rootId
  # Eg. [ "foo" "bar/baz" ]
  , rootFeatures
  }: let

    featureDefs = mapAttrs (id: { features, dependencies, ... }:
      features //
      listToAttrs
        (map (dep: { name = dep.name; value = []; })
          # We should collect all optional dependencies for feature def, even though they are not selected.
          # This happens on `rand@0.8.3`, whose `default` feature enables `rand_hc`, which is only available
          # for `cfg(target_os = "emscripten")`. This feature should be still enable, though optional dependency
          # is not.
          (filter (dep: dep.optional) dependencies))
    ) pkgSet;

    # initialFeatures = mapAttrs (id: defs: mapAttrs (k: v: false) defs) featureDefs;
    initialFeatures = mapAttrs (id: info: {}) pkgSet;

    # Overlay of spreading <id>'s nested features into dependencies and enable optional dependencies.
    updateDepsOverlay = id: final: prev: let
      info = pkgSet.${id};
      finalFeatures = final.${id} or {};
      updateDep = { name, optional, resolved, default_features, features, ... }: final: prev: let
        depFeatures =
          lib.optional (default_features && featureDefs.${resolved} ? default) "default" ++
          features ++
          filter (feat: feat != null)
            (map (feat: let m = match "(.*)/(.*)" feat; in
              if m != null && elemAt m 0 == name then
                elemAt m 1
              else
                null
              ) (attrNames finalFeatures));
      in
        {
          ${resolved} =
            # This condition must be evaluated under `${resolved} =`,
            # or we'll enter an infinite recursion.
            if optional -> finalFeatures.${name} or false then
              enableFeatures
                resolved
                featureDefs.${resolved}
                prev.${resolved}
                depFeatures
            else
              prev.${resolved};
        };
    in
      composeManyExtensions
        (map updateDep
          (filter depFilter info.dependencies))
        final
        prev;

    rootOverlay = final: prev: {
      ${rootId} = enableFeatures
        rootId
        featureDefs.${rootId}
        initialFeatures.${rootId}
        rootFeatures;
    };

    final =
      composeManyExtensions
      (map updateDepsOverlay (attrNames pkgSet) ++ [ rootOverlay ])
      final
      initialFeatures;

    final' =
      mapAttrs (id: feats: filter (feat: match ".*/.*" feat == null) (attrNames feats)) final;

  in
    final';

  preprocess-feature-tests = { assertEq, ... }: let
    test = optionalDeps: featureDefs: expect:
      assertEq (preprocessFeatures optionalDeps featureDefs) expect;
  in {
    recursive = test [ ] { a = [ "b" ]; b = [ "a" "c" ]; c = [ ]; } {
      a = [ "c" "b" "a" ];
      b = [ "c" "a" "b" ];
      c = [ "c" ];
    };
    auto-dep = test [ "a" ] { b = [ "a" ]; } {
      a = [ { dep = "a"; } "a" ];
      b = [ { dep = "a"; } "a" "b" ];
    };
    manual-dep = test [ "a" ] { b = [ "dep:a" ]; } {
      b = [ { dep = "a"; } "b" ];
    };
    strong-dep = test [ "a" ] { b = [ "a/c" ]; } {
      a = [ { dep = "a"; } "a" ];
      b = [ { dep = "a"; } { dep = "a"; feat = "c"; } "b" ];
    };
    weak-dep = test [ "a" ] { b = [ "a?/c" ]; } {
      a = [ { dep = "a"; } "a" ];
      b = [ { dep = "a"; feat = "c"; } "b" ];
    };
  };

  update-feature-tests = { assertEq, ... }: let
    testUpdate = defs: features: expect: let
      init = mapAttrs (k: v: false) defs;
      out = enableFeatures "pkgId" defs init features;
      enabled = attrNames (filterAttrs (k: v: v) out);
    in
      assertEq enabled expect;
  in {
    simple1 = testUpdate { a = []; } [] [];
    simple2 = testUpdate { a = []; } [ "a" ] [ "a" ];
    simple3 = testUpdate { a = []; } [ "a" "a" ] [ "a" ];
    simple4 = testUpdate { a = []; b = []; } [ "a" ] [ "a" ];
    simple5 = testUpdate { a = []; b = []; } [ "a" "b" ] [ "a" "b" ];
    simple6 = testUpdate { a = []; b = []; } [ "a" "b" "a" ] [ "a" "b" ];

  } // (let defs = { a = []; b = [ "a" ]; }; in {
    link1 = testUpdate defs [ "a" ] [ "a" ];
    link2 = testUpdate defs [ "b" "a" ] [ "a" "b" ];
    link3 = testUpdate defs [ "b" ] [ "a" "b" ];
    link4 = testUpdate defs [ "b" "a" ] [ "a" "b" ];
    link5 = testUpdate defs [ "b" "b" ] [ "a" "b" ];

  }) // (let defs = { a = []; b = [ "a" ]; c = [ "a" ]; }; in {
    common1 = testUpdate defs [ "a" ] [ "a" ];
    common2 = testUpdate defs [ "b" ] [ "a" "b" ];
    common3 = testUpdate defs [ "a" "b" ] [ "a" "b" ];
    common4 = testUpdate defs [ "b" "a" ] [ "a" "b" ];
    common5 = testUpdate defs [ "b" "c" ] [ "a" "b" "c" ];
    common6 = testUpdate defs [ "a" "b" "c" ] [ "a" "b" "c" ];
    common7 = testUpdate defs [ "b" "c" "b" ] [ "a" "b" "c" ];

  }) // (let defs = { a = [ "b" "c" ]; b = [ "d" "e" ]; c = [ "f" "g"]; d = []; e = []; f = []; g = []; }; in {
    tree1 = testUpdate defs [ "a" ] [ "a" "b" "c" "d" "e" "f" "g" ];
    tree2 = testUpdate defs [ "b" ] [ "b" "d" "e" ];
    tree3 = testUpdate defs [ "d" ] [ "d" ];
    tree4 = testUpdate defs [ "d" "b" "g" ] [ "b" "d" "e" "g" ];
    tree5 = testUpdate defs [ "c" "e" "f" ] [ "c" "e" "f" "g" ];

  }) // (let defs = { a = [ "b" ]; b = [ "c" ]; c = [ "b" ]; }; in {
    cycle1 = testUpdate defs [ "b" ] [ "b" "c" ];
    cycle2 = testUpdate defs [ "c" ] [ "b" "c" ];
    cycle3 = testUpdate defs [ "a" ] [ "a" "b" "c" ];
  });

  resolve-feature-tests = { assertEq, ... }: let
    test = pkgSet: rootId: rootFeatures: expect: let
      resolved = resolveFeatures { inherit pkgSet rootId rootFeatures; };
      expect' = mapAttrs (id: feats: sort (a: b: a < b) feats) expect;
    in
      assertEq resolved expect';

    pkgSet1 = {
      a = {
        features = { foo = [ "bar" ]; bar = []; baz = [ "b" ]; };
        dependencies = [
          { name = "b"; resolved = "b-id"; optional = true; default_features = true; features = [ "a" ]; }
          { name = "unused"; resolved = null; optional = true; default_features = true; features = []; }
        ];
      };
      b-id = {
        features = { default = []; foo = []; bar = [ "foo" ]; a = []; };
        dependencies = [];
      };
    };

    pkgSet2 = {
      my-id = {
        features = { default = [ "tokio/macros" ]; };
        dependencies = [
          { name = "tokio"; resolved = "tokio-id"; optional = false; default_features = false; features = [ "fs" ]; }
          { name = "dep"; resolved = "dep-id"; optional = false; default_features = true; features = []; }
        ];
      };
      dep-id = {
        features = { default = [ "tokio/sync" ]; };
        dependencies = [
          { name = "tokio"; resolved = "tokio-id"; optional = false; default_features = false; features = [ "sync" ]; }
        ];
      };
      tokio-id = {
        features = { default = []; fs = []; sync = []; macros = []; io = []; };
        dependencies = [];
      };
    };

  in {
    simple = test pkgSet1 "a" [ "foo" ] {
      a = [ "foo" "bar" ];
      b-id = [ ];
    };

    depend = test pkgSet1 "a" [ "foo" "baz" ] {
      a = [ "foo" "bar" "baz" "b" ];
      b-id = [ "default" "a" ];
    };

    override = test pkgSet1 "a" [ "b/bar" ] {
      a = [ "b" ];
      b-id = [ "default" "a" "bar" "foo" ];
    };

    merge = test pkgSet2 "my-id" [ "default" ] {
      my-id = [ "default" ];
      dep-id = [ "default" ];
      tokio-id = [ "fs" "sync" "macros" ];
    };
  };

  resolve-deps-tests = { assertEq, defaultRegistries, ... }: {
    simple = let
      index = {
        libc."0.1.12" = { name = "libc"; version = "0.1.12"; dependencies = []; };
        libc."0.2.95" = { name = "libc"; version = "0.2.95"; dependencies = []; };
        testt."0.1.0" = {
          name = "testt";
          version = "0.1.0";
          dependencies = map sanitizeDep [
            { name = "libc"; req = "^0.1.0"; kind = "normal"; }
            { name = "liba"; package = "libc"; req = "^0.2.0"; kind = "normal"; }
          ];
        };
      };

      lock = {
        package = [
          {
            name = "libc";
            version = "0.1.12";
            source = "registry+https://github.com/rust-lang/crates.io-index";
          }
          {
            name = "libc";
            version = "0.2.95";
            source = "registry+https://github.com/rust-lang/crates.io-index";
          }
          {
            name = "testt";
            version = "0.1.0";
            dependencies = [
             "libc 0.1.12"
             "libc 0.2.95 (registry+https://github.com/rust-lang/crates.io-index)"
            ];
          }
        ];
      };

      expected = {
        "libc 0.1.12 (registry+https://github.com/rust-lang/crates.io-index)" = {
          name = "libc";
          version = "0.1.12";
          dependencies = [ ];
        };
        "libc 0.2.95 (registry+https://github.com/rust-lang/crates.io-index)" = {
          name = "libc";
          version = "0.2.95";
          dependencies = [ ];
        };
        "testt" = {
          name = "testt";
          version = "0.1.0";
          dependencies = [
            {
              name = "libc";
              package = "libc";
              req = "^0.1.0";
              resolved = "libc 0.1.12 (registry+https://github.com/rust-lang/crates.io-index)";
              kind = "normal";
              optional = false;
              features = [];
              default_features = true;
              target = null;
            }
            {
              name = "liba";
              rename = "liba";
              package = "libc";
              req = "^0.2.0";
              resolved = "libc 0.2.95 (registry+https://github.com/rust-lang/crates.io-index)";
              kind = "normal";
              optional = false;
              features = [];
              default_features = true;
              target = null;
            }
          ];
        };
      };

      getPkgInfo = { name, version, ... }: index.${name}.${version};
      resolved = resolveDepsFromLock getPkgInfo lock;
    in
      assertEq resolved expected;

    workspace-virtual = let
      lock = fromTOML (readFile ../tests/workspace-virtual/Cargo.lock);
      cargoTomlFoo = fromTOML (readFile ../tests/workspace-virtual/crates/foo/Cargo.toml);
      cargoTomlBar = fromTOML (readFile ../tests/workspace-virtual/crates/bar/Cargo.toml);
      infoFoo = mkPkgInfoFromCargoToml cargoTomlFoo "<src>";
      infoBar = mkPkgInfoFromCargoToml cargoTomlBar "<src>";

      getCrateInfo = args:
        if args ? source then
          throw "No crates.io dependency"
        else if args.name == "foo" then
          infoFoo
        else if args.name == "bar" then
          infoBar
        else
          throw "Unknow crate: ${toJSON args}";

      resolved = resolveDepsFromLock getCrateInfo lock;
    in
    assertEq resolved {
      bar = {
        dependencies = [];
        features = {};
        links = null;
        name = "bar";
        src = "<src>";
        version = "0.1.0";
      };
      foo = {
        dependencies = [ {
          default_features = true;
          features = [];
          kind = "normal";
          name = "bar";
          optional = false;
          package = "bar";
          req = null;
          resolved = "bar";
          source = null;
          target = null;
        } ];
        features = {};
        links = null;
        name = "foo";
        src = "<src>";
        version = "0.1.0";
      };
    };
  };
}
