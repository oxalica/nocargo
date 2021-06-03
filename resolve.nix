{ lib }:
let
  inherit (builtins) readFile match fromTOML fromJSON toJSON;
  inherit (lib)
    foldl' foldr mapAttrs attrNames filterAttrs listToAttrs filter elemAt length optional sort composeManyExtensions;
  inherit (lib.crates-nix) parseSemverReq;
in rec {

  # Resolve the dependencies graph based on lock file.
  # Output:
  # {
  #   "libz-sys 0.1.0 (https://...)" = {
  #     # name, sha256, ... All fields from crate info.
  #     dependencies = [
  #       {
  #         # name, kind, ... All fields from dependency in crate info.
  #         resolved = "libc 0.1.0 (https://...)";
  #       };
  #     };
  #   };
  # }
  resolveDepsFromLock = getCrateInfo: lock: let
    pkgs = lock.package;

    pkgId = { name, version, source ? "", ... }: "${name} ${version} (${source})";

    pkgsByName = foldl' (set: { name, ... }@pkg:
      set // { ${name} = (set.${name} or []) ++ [ pkg ]; }
    ) {} pkgs;

    resolved = listToAttrs (map resolvePkg pkgs);

    resolvePkg = { name, version, source ? "", dependencies ? [], ... }@args: let
      info = getCrateInfo args;
      candidates = map findPkgId dependencies;

      # Disambiguous.
      crateName = name;
      crateVersion = version;

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
          filter ({ version, source, ... }:
            (lockVersion == null || version == lockVersion) &&
            (lockSource == null || source == lockSource))
          (pkgsByName.${lockName} or []);
        candidateCnt = length candidates;
      in
        if candidateCnt == 0 then
          throw "When resolving ${crateName} ${crateVersion}, locked dependency `${key}` not found"
        else if candidateCnt > 1 then
          throw "When resolving ${crateName} ${crateVersion}, locked dependency `${key}` is ambiguous"
        else
          elemAt candidates 0;

      selectDep = candidates: { name, package ? name, req, ... }: let
        checkReq = parseSemverReq req;
        selected = filter ({ name, version, ... }: name == package && checkReq version) candidates;
        selectedCnt = length selected;
      in
        if selectedCnt == 0 then
          throw "When resolving ${crateName} ${crateVersion}, dependency ${package} ${req} isn't satisfied in lock file"
        else if selectedCnt > 1 then
          throw "When resolving ${crateName} ${crateVersion}, dependency ${package} ${req} has multiple candidates in lock file"
        else
          pkgId (elemAt selected 0);

    in
      {
        name = pkgId args;
        value = info // { dependencies = resolvedDependencies; };
      };

  in
    resolved;

  # Enable `features` in `prev` and do recursive update according to `defs`.
  # Optional dependencies must be included in `defs`.
  enableFeatures = defs: prev: features:
    foldl' (prev: feat: let
      m = match "(.*)/.*" feat;
      mDep = elemAt m 0;
      nexts =
        if m == null then
          # Must be defined.
          defs.${feat}
        else
          # Dependent features implies optional dependency to be enabled.
          # But non-optional dependency doesn't have coresponding feature flag.
          optional (defs ? ${mDep}) mDep;
    in
      if prev.${feat} or false then
        prev
      else
        enableFeatures defs (prev // { ${feat} = true; }) nexts
    ) prev features;

  # Resolve all features.
  # Note that dependent features like `foo/bar` are only available during resolution,
  # and will be removed in result set.
  #
  # Input follows the layout of output of `resolveDepsFromLock`.
  # rootFeatures: [ "foo" "bar/baz" ]
  resolveFeatures = pkgSet: rootId: rootFeatures: let

    featureDefs = mapAttrs (id: { features, dependencies, ... }:
      features //
      listToAttrs
        (map (dep: { name = dep.name; value = []; })
          (filter (dep: dep.optional) dependencies))
    ) pkgSet;

    initialFeatures = mapAttrs (id: defs: mapAttrs (k: v: false) defs) featureDefs;

    # Overlay of spreading <id>'s nested features into dependencies and enable optional dependencies.
    updateDepsOverlay = id: final: prev: let
      info = pkgSet.${id};
      finalFeatures = final.${id};
      updateDep = { name, optional, resolved, default_features, features, ... }: final: prev: let
        depFeatures =
          lib.optional default_features "default" ++
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
                featureDefs.${resolved}
                prev.${resolved}
                depFeatures
            else
              prev.${resolved};
        };
    in
      composeManyExtensions (map updateDep info.dependencies) final prev;

    rootOverlay = final: prev: {
      ${rootId} = enableFeatures
        featureDefs.${rootId}
        initialFeatures.${rootId}
        rootFeatures;
    };

    final =
      composeManyExtensions
      (map updateDepsOverlay (attrNames pkgSet) ++ [ rootOverlay ])
      final
      initialFeatures;

  in
    mapAttrs (id: feats: filterAttrs (k: v: match ".*/.*" k == null) feats) final;

  feature-tests = { assertEq, ... }: let
    testUpdate = defs: features: expect: let
      init = mapAttrs (k: v: false) defs;
      out = enableFeatures defs init features;
      enabled = attrNames (filterAttrs (k: v: v) out);
    in
      assertEq enabled expect;
  in {
    feature-simple1 = testUpdate { a = []; } [] [];
    feature-simple2 = testUpdate { a = []; } [ "a" ] [ "a" ];
    feature-simple3 = testUpdate { a = []; } [ "a" "a" ] [ "a" ];
    feature-simple4 = testUpdate { a = []; b = []; } [ "a" ] [ "a" ];
    feature-simple5 = testUpdate { a = []; b = []; } [ "a" "b" ] [ "a" "b" ];
    feature-simple6 = testUpdate { a = []; b = []; } [ "a" "b" "a" ] [ "a" "b" ];

  } // (let defs = { a = []; b = [ "a" ]; }; in {
    feature-link1 = testUpdate defs [ "a" ] [ "a" ];
    feature-link2 = testUpdate defs [ "b" "a" ] [ "a" "b" ];
    feature-link3 = testUpdate defs [ "b" ] [ "a" "b" ];
    feature-link4 = testUpdate defs [ "b" "a" ] [ "a" "b" ];
    feature-link5 = testUpdate defs [ "b" "b" ] [ "a" "b" ];

  }) // (let defs = { a = []; b = [ "a" ]; c = [ "a" ]; }; in {
    feature-common1 = testUpdate defs [ "a" ] [ "a" ];
    feature-common2 = testUpdate defs [ "b" ] [ "a" "b" ];
    feature-common3 = testUpdate defs [ "a" "b" ] [ "a" "b" ];
    feature-common4 = testUpdate defs [ "b" "a" ] [ "a" "b" ];
    feature-common5 = testUpdate defs [ "b" "c" ] [ "a" "b" "c" ];
    feature-common6 = testUpdate defs [ "a" "b" "c" ] [ "a" "b" "c" ];
    feature-common7 = testUpdate defs [ "b" "c" "b" ] [ "a" "b" "c" ];

  }) // (let defs = { a = [ "b" "c" ]; b = [ "d" "e" ]; c = [ "f" "g"]; d = []; e = []; f = []; g = []; }; in {
    feature-tree1 = testUpdate defs [ "a" ] [ "a" "b" "c" "d" "e" "f" "g" ];
    feature-tree2 = testUpdate defs [ "b" ] [ "b" "d" "e" ];
    feature-tree3 = testUpdate defs [ "d" ] [ "d" ];
    feature-tree4 = testUpdate defs [ "d" "b" "g" ] [ "b" "d" "e" "g" ];
    feature-tree5 = testUpdate defs [ "c" "e" "f" ] [ "c" "e" "f" "g" ];

  }) // (let defs = { a = [ "b" ]; b = [ "c" ]; c = [ "b" ]; }; in {
    feature-cycle1 = testUpdate defs [ "b" ] [ "b" "c" ];
    feature-cycle2 = testUpdate defs [ "c" ] [ "b" "c" ];
    feature-cycle3 = testUpdate defs [ "a" ] [ "a" "b" "c" ];
  });

  resolve-deps-tests = { assertDeepEq, ... }: crates-nix: {
    resolve-deps-simple = let
      index = {
        libc."0.1.12" = { name = "libc"; version = "0.1.12"; dependencies = []; };
        libc."0.2.95" = { name = "libc"; version = "0.2.95"; dependencies = []; };
        testt."0.1.0" = {
          name = "testt";
          version = "0.1.0";
          dependencies = [
            { name = "libc"; req = "^0.1.0"; }
            { name = "liba"; package = "libc"; req = "^0.2.0"; }
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
        "testt 0.1.0 ()" = {
          name = "testt";
          version = "0.1.0";
          dependencies = [
            {
              name = "libc";
              req = "^0.1.0";
              resolved = "libc 0.1.12 (registry+https://github.com/rust-lang/crates.io-index)";
            }
            {
              name = "liba";
              package = "libc";
              req = "^0.2.0";
              resolved = "libc 0.2.95 (registry+https://github.com/rust-lang/crates.io-index)";
            }
          ];
        };
      };

      getCrateInfo = { name, version, ... }: index.${name}.${version};
      resolved = resolveDepsFromLock getCrateInfo lock;
    in
      assertDeepEq resolved expected;

    resolve-deps-tokio-app = let
      lock = fromTOML (readFile ./tests/tokio-app/Cargo.lock);
      expected = readFile ./tests/tokio-app/Cargo.lock.resolved.json;

      cargoToml = fromTOML (readFile ./tests/tokio-app/Cargo.toml);
      info = crates-nix.mkCrateInfoFromCargoToml cargoToml;
      getCrateInfo = args:
        if args ? source then
          crates-nix.getCrateInfo args
        else
          assert args.name == "tokio-app";
          info;

      resolved = resolveDepsFromLock getCrateInfo lock;
      resolved' = mapAttrs (id: { dependencies, ... }@args:
        args // {
          dependencies = filter (dep: !dep.optional && dep.kind != "dev") dependencies;
        }
      ) resolved;
    in
      assertDeepEq resolved' (fromJSON expected); # Normalize.

    crate-info-from-toml = let
      cargoToml = fromTOML (readFile ./tests/tokio-app/Cargo.toml);
      info = crates-nix.mkCrateInfoFromCargoToml cargoToml;

      expected = {
        name = "tokio-app";
        version = "0.1.0";
        features = { };
        dependencies = [
          {
            name = "liboldc";
            package = "libc";
            default_features = false;
            features = [ ];
            kind = "normal";
            optional = false;
            req = "0.1";
            target = null;
          }
          {
            name = "tokio";
            package = "tokio";
            default_features = false;
            features = [ "rt-multi-thread" "macros" "time" ];
            kind = "normal";
            optional = false;
            req = "1.6.1";
            target = null;
          }
        ];
      };
    in
      assertDeepEq info expected;
  };

  resolve-features-tests = { assertDeepEq, ... }: let
    test = pkgSet: rootId: rootFeatures: expect: let
      resolved = resolveFeatures pkgSet rootId rootFeatures;
      resolved' = mapAttrs (id: feats: filter (feat: feats.${feat}) (attrNames feats)) resolved;
      expect' = mapAttrs (id: feats: sort (a: b: a < b) feats) expect;
    in
      assertDeepEq resolved' expect';

    pkgSet1 = {
      a = {
        features = { foo = [ "bar" ]; bar = []; baz = [ "b" ]; };
        dependencies = [
          { name = "b"; resolved = "b-id"; optional = true; default_features = true; features = [ "a" ]; }
          { name = "unused"; resolved = null; optional = true; default_features = true; features =
          []; }
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
    resolve-features-simple = test pkgSet1 "a" [ "foo" ] {
      a = [ "foo" "bar" ];
      b-id = [ ];
    };

    resolve-features-depend = test pkgSet1 "a" [ "foo" "baz" ] {
      a = [ "foo" "bar" "baz" "b" ];
      b-id = [ "default" "a" ];
    };

    resolve-features-override = test pkgSet1 "a" [ "b/bar" ] {
      a = [ "b" ];
      b-id = [ "default" "a" "bar" "foo" ];
    };

    resolve-features-merge = test pkgSet2 "my-id" [ "default" ] {
      my-id = [ "default" ];
      dep-id = [ "default" ];
      tokio-id = [ "fs" "sync" "macros" ];
    };
  };
}
