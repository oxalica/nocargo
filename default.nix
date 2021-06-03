final: prev:
let
  inherit (builtins) attrNames filter readFile readDir fromJSON foldl';
  inherit (final.lib)
    stringLength substring splitString replaceStrings
    mapAttrs listToAttrs fix mapAttrsToList isString;

  inherit (final.lib.crates-nix) compareSemver parseSemverReq;
  inherit (final.crates-nix) crates-io-index index downloadUrl;

  mkIndex = path:
    mapAttrs (k: v:
      if v == "directory"
        then mkIndex "${path}/${k}"
        else mkCrateInfoSet k (readFile "${path}/${k}")
    ) (removeAttrs (readDir path) [ "config.json" ]);

  # Get crate info of the given package.
  getCrateInfo = { name, version, checksum ? null, ... }: let
    len = stringLength name;
    info =
      if len == 1 then
        index."1".${name}.${version} or null
      else if len == 2 then
        index."2".${name}.${version} or null
      else if len == 3 then
        index."3".${substring 0 1 name}.${name}.${version} or null
      else
        index.${substring 0 2 name}.${substring 2 2 name}.${name}.${version} or null;
  in
    if info == null then
      throw "Crate ${name} ${version} is not available in index"
    else if info.sha256 != null && checksum != null && info.sha256 != checksum then
      throw "Crate ${name} ${version} hash mismatched, expect ${info.sha256}, got ${checksum}"
    else
      info;

  mkCrateInfoSet = name: content: let
    lines = splitString "\n" content;
    foldFn = revs: line: let parsed = fromJSON line; in
      if line == "" then
        revs
      else
        revs // { ${parsed.vers} = mkCrateInfo parsed; };
  in
    foldl' foldFn {} lines;

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
      src = final.fetchurl {
        # Use the same name as nixpkgs to benifit from cache.
        # https://github.com/NixOS/nixpkgs/pull/122158/files#diff-eb8b8729bfd36f8878c2d8a99f67a2bebb912e9f78c5d2a72457b1f572e26986R67
        name = "crate-${name}-${vers}.tar.gz";
        url = downloadUrl name vers;
        sha256 = cksum;
      };
    };

    # Build a simplified crate into from a parsed Cargo.toml.
    mkCrateInfoFromCargoToml = { package , features ? {} , target ? {}, ... }@args: let
      transDeps = target: kind:
        mapAttrsToList (name: v:
          {
            inherit name target kind;
            package = v.package or name;
            req = if isString v then v else v.version;
            features = v.features or [];
            optional = v.optional or false;
            default_features = v.default_features or false;
          });

      collectTargetDeps = target: { dependencies ? {}, devDependencies ? {}, buildDependencies ? {}, ... }:
        transDeps target "normal" dependencies ++
        transDeps target "dev" devDependencies ++
        transDeps target "build" buildDependencies;

    in
      {
        inherit (package) name version;
        inherit features;
        dependencies =
          collectTargetDeps null args ++
          mapAttrsToList collectTargetDeps target;
      };

in
{
  lib = prev.lib // {
    crates-nix =
      import ./semver.nix { inherit (final) lib; } //
      import ./target-cfg.nix { inherit (final) lib; } //
      import ./resolve.nix { inherit (final) lib; };
  };

  crates-nix = {
    crates-io-index = throw "`crates-nix.crates-io-index` must be set to the path to crates.io-index";
    downloadUrl = name: version: "https://crates.io/api/v1/crates/${name}/${version}/download";

    index = mkIndex crates-io-index;
    inherit getCrateInfo mkCrateInfoFromCargoToml;

    buildCrate = final.callPackage ./build-crate {};
  };
}
