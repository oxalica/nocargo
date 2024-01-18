{ lib, self }:
let
  inherit (builtins) readFile match fromTOML toJSON;
  inherit (lib)
    foldl' listToAttrs filter elemAt length sort elem flatten
    hasPrefix substring
    attrValues mapAttrs filterAttrs assertMsg;
  inherit (self.semver) parseSemverReq;
  inherit (self.pkg-info) mkPkgInfoFromCargoToml toPkgId sanitizeDep;
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
  # We support V1, V2 and V3.
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

      selectDep = candidates: { name, package, req, source ? null, ... }:
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

  parse-feature = feat: let
    is-optional-dependency = match "dep:(.*)" feat;
    is-dependency-feature = match "([^?]*)([?])?/(.*)" feat;
  in
    if is-optional-dependency != null then
      { type= "enable-dep"; dep-name= (builtins.head is-optional-dependency);}
    else if is-dependency-feature != null then
      { type = "dep-feature";
        dep-name = (elemAt is-dependency-feature 0);
        weak = (elemAt is-dependency-feature 1) != null;
        feat-name = (elemAt is-dependency-feature 2);
      } else
        { type = "normal";
          feat-name = feat;
        };

  # Merges different feature sets
  # by concatenating the features and or'ing the enable field.
  # Eg:
  # mergeChanges [
  # { "normal" = { "a" = { "features" = [ "foo" ]; enabled = false }; };
  #   "build" = { "b" = { "features" = []; enabled = true; }; };
  # }
  # { "normal" = { "a" = { "features" = [ "bar" ]; enabled = true; }; }; }
  # ]
  # ->
  # { "normal" = { "a" = { "features" = [ "foo" "bar" ]; enabled = true }; };
  #   "build" = { "b" = { "features" = []; enabled = true; }; };
  # }
  # TODO: this function is horribly inneficient. rewrite it using better
  #       functions for performance
  mergeChanges = changes:
    lib.attrsets.foldAttrs (deps: outer-acc:
      lib.attrsets.foldAttrs (args: acc:
        { features = lib.lists.unique ((acc.features or []) ++ (args.features or []));
          deferred = lib.lists.unique ((acc.deferred or []) ++ (args.deferred or []));
          enabled = (acc.enabled or false) || (args.enabled or false); }
      ) {} [deps outer-acc]
    ) {} changes;

  # Folds a function `f` through all the dependencies of a package that
  # are named dep-name and are enabled for the build. This is used to
  # be able to enable different kinds (and different targets) all in one
  # fell swoop.
  forall-deps-with-same-name = { pkgSet, pkgId, dep-name, seen, kind }: f: 
    let deps = filter (dep: dep.name == dep-name &&
                            dep.resolved != null &&
                            dep.targetEnabled &&
                            (kind == "dev" -> dep.kind == kind) # FIXME: is this correct?
        ) pkgSet.${pkgId}.dependencies; in
    lib.foldl' (acc: dep:
      let next = f dep; in
      mergeChanges [acc next]
    ) seen deps;
  
  # Activates a single feature, and all the changes made by it.
  # It may enable other packages, as well as other features.
  # {
  #   "libc 0.1.0 (https://...)" = {
  #     features = [ "bar" ];
  #   };
  #   ...
  # }
  enableFeature = {
    pkgSet, # Follows the output of `resolveDepsFromLock`.
      pkgId, # pkgId of the dependency of the feature that is being enabled
      feat-name, # feature name
      kind, # build kind: normal, dev, build
      seen # to avoid cyclic references entering infinite loops
  }:
    let
      feature = parse-feature feat-name;
    in
      if feature.type == "normal" then
        enableFeatureRecursively {
          inherit pkgSet pkgId kind seen;
          inherit (feature) feat-name;
        }
      else if feature.type == "dep-feature" then
        enableDepFeature {
          inherit pkgSet pkgId kind seen;
          inherit (feature) dep-name feat-name weak;
        }
      else if feature.type == "enable-dep" then
        enableDependency {
          inherit pkgSet pkgId seen kind;
          inherit (feature) dep-name;
        }
      else
        throw "Unrecognized feature type: ${feature.type}";

  # Enables all optional dependencies of package `pkgId` named `dep-name`.
  # This means same dependency for different build kinds, as they appear as different dependencies on
  # the dependency graph.
  enableDependency = { pkgSet, pkgId, dep-name, seen, kind }:
    forall-deps-with-same-name { inherit pkgSet pkgId dep-name seen kind; } (dep: let
      add-default = if dep.default_features && (pkgSet.${dep.resolved}.features ? "default") then ["default"] else [];
      deferred-features = lib.attrByPath [dep.kind dep.resolved "deferred"] [] seen;
    in
      enablePackage {
        inherit pkgSet seen;
        inherit (dep) kind;
        pkgId = dep.resolved;
        features = deferred-features ++ dep.features ++ add-default;
      });

  # Enable the feature `feat-name` together with all the other features enabled by it.
  enableFeatureRecursively = {pkgSet, pkgId, kind, seen, feat-name}: let
    features = pkgSet.${pkgId}.features;
    add-feature = mergeChanges [seen { ${kind}.${pkgId}.features = [ feat-name ]; }];
    already-enabled = elem feat-name (lib.attrByPath [kind pkgId "features"] [] seen);
    changes =
      if features ? ${feat-name} then
        enableFeatures {
          inherit pkgSet pkgId kind;
          features = features.${feat-name};
          seen = add-feature;
        }
      else
        # old style optional dependencies define features with the exact
        # same name as the dependency. this is called implicit features.
        # https://doc.rust-lang.org/cargo/reference/features.html#optional-dependencies
        enableDependency {
          inherit pkgSet pkgId kind;
          seen = add-feature;
          dep-name = feat-name;
        };
  in
    if !already-enabled then 
      changes
    else
      seen;


  # Enable a dependency feature, of the form dep-name?/feat-name
  enableDepFeature = { pkgSet, pkgId, kind, seen, feat-name, dep-name, weak }:
    forall-deps-with-same-name { inherit pkgSet pkgId dep-name seen kind; } (dep:
      let
        defer-feature = mergeChanges [seen { ${dep.kind}.${dep.resolved}.deferred = [feat-name]; }];
        enable-feature-with-dep-name-on-pkg = enableFeature {
          inherit pkgSet pkgId kind seen;
          feat-name = dep-name;
        };
        enable-dependency = if !weak && dep.optional then
          enableDependency {
            inherit pkgSet pkgId dep-name kind;
            seen = enable-feature-with-dep-name-on-pkg;
          } else enable-feature-with-dep-name-on-pkg;
      in
        if weak && !(lib.attrByPath [dep.kind dep.resolved "enabled"] false seen) && dep.optional then
          defer-feature
        else
          enableFeature {
            inherit pkgSet feat-name;
            inherit (dep) kind;
            seen = enable-dependency;
            pkgId = dep.resolved;
          }
    ) ;

  # Enable the feature list `features` for pkgId.
  enableFeatures = { pkgSet, pkgId, kind, seen, features }:
    foldl' (acc: feat-name: 
      let next = enableFeature { inherit pkgSet pkgId feat-name kind; seen = acc;}; in
      mergeChanges [acc next]
    ) seen features;

  # Enables a package with `features` enabled, together with
  # it's non-optional dependencies. Only cycles through the dependencies
  # if it hasn't already been enabled, otherwise only enables the features.
  enablePackage = { pkgSet, pkgId, kind, features, seen }: let
    deps = pkgSet.${pkgId}.dependencies;
    already-enabled = lib.attrByPath [kind pkgId "enabled"] false seen;
    enable-package = { ${kind}.${pkgId}.enabled = true; };
    enable-features = enableFeatures {
      inherit pkgSet pkgId kind features; seen = mergeChanges [seen enable-package];
    };
    enable-dependencies = foldl' (acc: dep:
      if dep.targetEnabled && dep.resolved != null && !dep.optional then let
        default = if dep.default_features && (pkgSet.${dep.resolved}.features ? "default") then ["default"] else [];
      in
        enablePackage {
          inherit pkgSet;
          inherit (dep) kind;
          pkgId = dep.resolved;
          features = dep.features ++ default;
          seen = acc;
        }
      else acc
    ) enable-features deps;
  in
    if !already-enabled then
      enable-dependencies
    else
      enable-features;

  # Resolve all features.
  #
  # Returns:
  # {
  #   "normal" = {
  #     "libc 0.1.0 (https://...)" = [ "default" "foo" "bar" ];
  #     ...
  #     };
  #   "build" = {...};
  #   "dev" = {...};
  # }
  resolveFeatures = {
    # Follows the layout of the output of `resolveDepsFromLock`.
    pkgSet
    # Eg. "libc 0.1.0 (https://...)"
    , rootId
    # Eg. [ "foo" "bar/baz" ]
    , rootFeatures
  }:
    let
      root-package = enablePackage {
        inherit pkgSet;
        kind = "normal";
        pkgId = rootId;
        features = rootFeatures;
        seen = {};
      };
    in
      mapAttrs
        (kind: pkgs: mapAttrs (_: { features, ...}: features)            # return only the enabled features
          (filterAttrs (_: {enabled, ...}: enabled) pkgs)) root-package; # only if it is enabled

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
      pkgSet = { pkgId = { dependencies = []; features = defs; }; };
      out = enablePackage {
        inherit pkgSet features;
        pkgId = "pkgId";
        kind = "normal";
        seen = {};
      };
      enabled = lib.lists.naturalSort out.normal.pkgId.features;
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
      got = mapAttrs (id: feats: sort (a: b: a < b) feats) resolved.normal;
    in
      assertEq got expect';

    pkgSet1 = {
      a = {
        features = { foo = [ "bar" ]; bar = []; baz = [ "b" ]; };
        dependencies = [
          { name = "b"; resolved = "b-id"; optional = true; default_features = true; features = [ "a" ]; targetEnabled = true; kind = "normal";}
          { name = "unused"; resolved = null; optional = true; default_features = true; features = []; targetEnabled = true; kind = "normal";}
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
          { name = "tokio"; resolved = "tokio-id"; optional = false; default_features = false; features = [ "fs" ]; targetEnabled = true; kind = "normal";}
          { name = "dep"; resolved = "dep-id"; optional = false; default_features = true; features = []; targetEnabled = true; kind = "normal";}
        ];
      };
      dep-id = {
        features = { default = [ "tokio/sync" ]; };
        dependencies = [
          { name = "tokio"; resolved = "tokio-id"; optional = false; default_features = false; features = [ "sync" ]; targetEnabled = true; kind = "normal";}
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
      # b-id is not enabled so it does not appear in features.
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
      my-id = [ "default" "tokio" ];
      dep-id = [ "default" "tokio"];
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
      cargoTomlWs = fromTOML (readFile ../test/workspace-virtual/Cargo.toml);
      cargoTomlFoo = fromTOML (readFile ../tests/workspace-virtual/crates/foo/Cargo.toml);
      cargoTomlBar = fromTOML (readFile ../tests/workspace-virtual/crates/bar/Cargo.toml);
      infoFoo = mkPkgInfoFromCargoToml cargoTomlFoo "<src>" cargoTomlWs;
      infoBar = mkPkgInfoFromCargoToml cargoTomlBar "<src>" cargoTomlWs;

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
          procMacro = false;
          src = "<src>";
          version = "0.1.0";
          edition = "2018";
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
          edition = "2018";
          features = {};
          links = null;
          name = "foo";
          procMacro = false;
          src = "<src>";
          version = "0.1.0";
        };
      };
  };
}
