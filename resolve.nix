{ lib }:
let
  inherit (builtins) readFile match fromTOML fromJSON toJSON;
  inherit (lib) foldl' mapAttrs attrNames filterAttrs listToAttrs filter elemAt length;
  inherit (lib.crates-nix) parseSemverReq;
in rec {

  # Enable `features` in `prev` and do recursive update according to `defs`.
  enableFeatures = defs: prev: features:
    foldl' (prev: feat:
      if prev.${feat} then
        prev
      else
        enableFeatures defs (prev // { ${feat} = true; }) defs.${feat}
    ) prev features;

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

  resolve-tests = { assertEq, ... }: crates-nix: {
    resolve-simple = let
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
      assertEq (toJSON resolved) (toJSON expected);

    resolve-tokio-app = let
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
      assertEq (toJSON resolved') (toJSON (fromJSON expected)); # Normalize.

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
      assertEq (toJSON info) (toJSON expected);

  };
}
