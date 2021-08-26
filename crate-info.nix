{ lib, fetchurl }:
let
  inherit (builtins) readFile readDir fromJSON fromTOML toString attrNames;
  inherit (lib) stringLength splitString replaceStrings substring isString filter listToAttrs mapAttrs mapAttrsToList;
in
rec {
  mkIndex = path: let
    # TODO: We currently only support legacy format used by crates.io-index.
    # https://github.com/rust-lang/cargo/blob/2f3df16921deb34a92700f4d5a7ecfb424739558/src/cargo/sources/registry/mod.rs#L230-L244
    downloadEndpoint = (fromJSON (readFile "${path}/config.json")).dl;
    mkDownloadUrl = name: version:
      "${downloadEndpoint}/${name}/${version}/download";

    go = path:
      mapAttrs (k: v:
        if v == "directory"
          then go "${path}/${k}"
          else mkCrateInfoSet mkDownloadUrl k (readFile "${path}/${k}")
      ) (removeAttrs (readDir path) [ "config.json" ]);
  in
    go path // { __registry_index = true; };

  # Get crate info of the given package.
  getCrateInfoFromIndex = index: { name, version, checksum ? null, ... }: let
    len = stringLength name;
    crate =
      if len == 1 then
        index."1".${name} or null
      else if len == 2 then
        index."2".${name} or null
      else if len == 3 then
        index."3".${substring 0 1 name}.${name} or null
      else
        index.${substring 0 2 name}.${substring 2 2 name}.${name} or null;
    info = crate.${version} or null;
  in
    if !(index ? __registry_index) then
      throw "Invalid registry. Do you forget `mkIndex` on registry paths?"
    else if crate == null then
      throw "Crate ${name} is not found in index"
    else if info == null then
      throw "Crate ${name} doesn't have version ${version} in index. Available versions: ${toString (attrNames crate)}"
    else if info.sha256 != null && checksum != null && info.sha256 != checksum then
      throw "Crate ${name} ${version} hash mismatched, expect ${info.sha256}, got ${checksum}"
    else
      info;

  # Make a set of crate infos keyed by version.
  mkCrateInfoSet = mkDownloadUrl: name: content: let
    lines = filter (line: line != "") (splitString "\n" content);
    parseLine = line: let parsed = fromJSON line; in {
      name = parsed.vers;
      value = mkCrateInfo mkDownloadUrl parsed;
    };
  in
    listToAttrs (map parseLine lines);

  # Crate info:
  # {
  #   name = "libz-sys";      # The name in registry.
  #   version = "0.1.0";      # Semver.
  #   src = <drv or path>;    # Source path.
  #   sha256 = "123456....";  # Hash of the `src` tarball. (null or string)
  #   yanked = false;         # Whether it's yanked.
  #   links = "z";            # The native library to link. (null or string)
  #   features = {            # Features provided.
  #     default = [ "std" ];
  #     std = [];
  #   };
  #   dependencies = [
  #     {
  #       name = "libc";            # Reference name.
  #       package = "libc";         # Dependency's name in registry. (default to be `name`)
  #       req = "^0.1.0";           # Semver requirement.
  #       features = [ "foo" ];     # Enabled features.
  #       optional = false;         # Whether this dependency is optional.
  #       default_features = true;  # Whether to enable default features.
  #       target = "cfg(...)";      # Only required on some targets. (null or string, default to be null)
  #       kind = "normal";          # Dependencies (one of "normal", "dev", "build", default to be "normal")
  #       # `registry` and `public` are not supported.
  #     }
  #   ];
  # }
  mkCrateInfo =
    mkDownloadUrl:
    # https://github.com/rust-lang/cargo/blob/2f3df16921deb34a92700f4d5a7ecfb424739558/src/cargo/sources/registry/mod.rs#L259
    { name, vers, deps, features, cksum, yanked ? false, links ? null, v ? 1, ... }:
    if v != 1 then
      throw "${name} ${vers}: Registry layout version ${v} is too new to understand"
    else
    {
      inherit name features yanked links;
      version = vers;
      sha256 = cksum;
      dependencies = deps;
      src = fetchurl {
        # Use the same name as nixpkgs to benifit from cache.
        # https://github.com/NixOS/nixpkgs/pull/122158/files#diff-eb8b8729bfd36f8878c2d8a99f67a2bebb912e9f78c5d2a72457b1f572e26986R67
        name = "crate-${name}-${vers}.tar.gz";
        url = mkDownloadUrl name vers;
        sha256 = cksum;
      };
    };

  # Build a simplified crate into from a parsed Cargo.toml.
  mkCrateInfoFromCargoToml = { package, features ? {}, target ? {}, ... }@args: src: let
    transDeps = target: kind:
      mapAttrsToList (name: v:
        {
          inherit name target kind;
          package = v.package or name;
          # For path or git dependencies, `version` can be omitted.
          req = if isString v then v else v.version or null;
          features = v.features or [];
          optional = v.optional or false;
          # It's `default-features` in Cargo.toml, but `default_features` in index and in crate info.
          default_features =
            lib.warnIf (v ? default_features) "Ignoreing `default_features`. Do you means `default-features`?"
            (v.default-features or true);

          # This is used for dependency resoving inside Cargo.lock.
          source =
            if v ? registry then
              throw "Dependency with `registry` is not supported. Use `registry-index` with explicit URL instead."
            else if v ? registry-index then
              "registry+${v.registry-index}"
            else if v ? git then
              if v ? branch then
                "git+${v.git}?branch=${v.branch}"
              else if v ? tag then
                "git+${v.git}?tag=${v.tag}"
              else if v ? rev then
                "git+${v.git}?rev=${v.rev}"
              else
                "git+${v.git}"
            else
              null;
        });

    collectTargetDeps = target: { dependencies ? {}, devDependencies ? {}, buildDependencies ? {}, ... }:
      transDeps target "normal" dependencies ++
      transDeps target "dev" devDependencies ++
      transDeps target "build" buildDependencies;

  in
    {
      inherit (package) name version;
      inherit src features;
      links = package.links or null;
      dependencies =
        collectTargetDeps null args ++
        mapAttrsToList collectTargetDeps target;
    };

  crate-info-from-toml-tests = { assertDeepEq, ... }: {
    crate-info-from-toml = let
      cargoToml = fromTOML (readFile ./tests/tokio-app/Cargo.toml);
      info = mkCrateInfoFromCargoToml cargoToml "<src>";

      expected = {
        name = "tokio-app";
        version = "0.1.0";
        features = { };
        src = "<src>";
        links = null;
        dependencies = [
          {
            name = "liboldc";
            package = "libc";
            default_features = true;
            features = [ ];
            kind = "normal";
            optional = false;
            req = "0.1";
            target = null;
            source = null;
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
            source = null;
          }
        ];
      };
    in
      assertDeepEq info expected;
  };
}
