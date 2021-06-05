{ lib }:
let
  inherit (builtins) fromTOML fromJSON;
  inherit (lib) readFile mapAttrs filter replaceStrings elem id;
  inherit (lib.crates-nix)
    mkCrateInfoFromCargoToml getCrateInfoFromIndex resolveDepsFromLock resolveFeatures;
in
rec {
  buildRustCrateFromSrcAndLock =
    index:
    buildRustCrate:
    { src
    , cargoTomlFile ? src + "/Cargo.toml"
    , cargoLockFile ? src + "/Cargo.lock"
    , features ? null
    }:
    let
      cargoToml = fromTOML (readFile cargoTomlFile);
      cargoLock = fromTOML (readFile cargoLockFile);

      rootInfo = mkCrateInfoFromCargoToml cargoToml src;

      getCrateInfo' = args:
        if args ? source then
          getCrateInfoFromIndex index args
        else
          assert args.name == rootInfo.name && args.version == rootInfo.version;
          rootInfo;

      rootId = "${rootInfo.name} ${rootInfo.version} ()";
      pkgSet = resolveDepsFromLock getCrateInfo' cargoLock;

      rootFeatures = if features != null then features
        else if rootInfo.features ? default then [ "default" ]
        else [];
      resolvedNormalFeatures = resolveFeatures {
        inherit pkgSet rootId rootFeatures;
        depFilter = dep: dep.kind == "normal";
      };

      pkgs = mapAttrs (id: { name, version, src, dependencies, ... }: let
        selectedDeps =
          map (dep: { name = dep.name; drv = pkgs.${dep.resolved}; })
            (filter ({ kind, name, optional, ... }:
              kind == "normal" && (optional -> elem name resolvedNormalFeatures.${id}))
            dependencies);
      in
        buildRustCrate {
          inherit version src;
          crateName = "${replaceStrings [ "-" ] [ "_" ] name}";
          features = resolvedNormalFeatures.${id};
          dependencies = selectedDeps;
        }
      ) pkgSet;

    in
      pkgs.${rootId};

  build-from-src-dry-tests = { assertDeepEq, ... }: crates-nix: let
    buildRustCrate = args: removeAttrs args [ "src" ];
    test = src: let
      got = buildRustCrateFromSrcAndLock crates-nix.index buildRustCrate {
        inherit src;
      };
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
