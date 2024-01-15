{ lib, ... }:
let
  inherit (builtins) readFile readDir fromJSON fromTOML toString attrNames match;
  inherit (lib)
    stringLength splitString replaceStrings substring isString toLower
    filter listToAttrs mapAttrs mapAttrsToList optionalAttrs warnIf;
in
rec {
  toPkgId = { name, version, source ? null, ... }:
    if source != null then
      "${name} ${version} (${source})"
    else
      # Local crates must be collide names. Simply use the name to make overriding easier.
      name;

  mkIndex = fetchurl: path: overrides: let
    # TODO: We currently only support legacy format used by crates.io-index.
    # https://github.com/rust-lang/cargo/blob/2f3df16921deb34a92700f4d5a7ecfb424739558/src/cargo/sources/registry/mod.rs#L230-L244
    downloadEndpoint = (fromJSON (readFile (path + "/config.json"))).dl;
    mkDownloadUrl =
      assert match ".*\\{.*" downloadEndpoint == null;
      { name, version, ... }: "${downloadEndpoint}/${name}/${version}/download";

    mkSrc = { name, version, sha256 }@args: fetchurl {
      # Use the same name as nixpkgs to benifit from cache.
      # https://github.com/NixOS/nixpkgs/pull/122158/files#diff-eb8b8729bfd36f8878c2d8a99f67a2bebb912e9f78c5d2a72457b1f572e26986R67
      name = "crate-${name}-${version}.tar.gz";
      url = mkDownloadUrl args;
      inherit sha256;
    };

    go = path:
      mapAttrs (k: v:
        if v == "directory"
          then go (path + "/${k}")
          else mkPkgInfoSet mkSrc k (readFile (path + "/${k}")) (overrides.${k} or null)
      ) (removeAttrs (readDir path) [ "config.json" ]);
  in
    go path // { __registry_index = true; };

  # Get pkg info of the given package, with overrides applied if exists.
  getPkgInfoFromIndex = index: { name, version, checksum ? null, ... }: let
    name' = toLower name;
    len = stringLength name';
    crate =
      if len == 1 then
        index."1".${name'} or null
      else if len == 2 then
        index."2".${name'} or null
      else if len == 3 then
        index."3".${substring 0 1 name'}.${name'} or null
      else
        index.${substring 0 2 name'}.${substring 2 2 name'}.${name'} or null;
    info = crate.${version} or null;
  in
    if !(index ? __registry_index) then
      throw "Invalid registry. Do you forget `mkIndex` on registry paths?"
    else if crate == null then
      throw "Package ${name} is not found in index"
    else if info == null then
      throw "Package ${name} doesn't have version ${version} in index. Available versions: ${toString (attrNames crate)}"
    else if info.sha256 != null && checksum != null && info.sha256 != checksum then
      throw "Package ${name} ${version} hash mismatched, expect ${info.sha256}, got ${checksum}"
    else
      info;

  # Make a set of pkg infos keyed by version.
  mkPkgInfoSet = mkSrc: name: content: override: let
    lines = filter (line: line != "") (splitString "\n" content);
    parseLine = line: let parsed = fromJSON line; in {
      name = parsed.vers;
      value = mkPkgInfoFromRegistry mkSrc parsed
        // optionalAttrs (override != null) {
          # Proc macro crates behave differently in dependency resolution.
          procMacro = (override { inherit (parsed) version; features = { }; }).procMacro or false;
          __override = override;
        };
    };
  in
    listToAttrs (map parseLine lines);

  # Package info:
  # {
  #   name = "libz-sys";      # The name in registry.
  #   version = "0.1.0";      # Semver.
  #   src = <drv or path>;    # Source path.
  #   sha256 = "123456....";  # Hash of the `src` tarball. (null or string)
  #   yanked = false;         # Whether it's yanked.
  #   links = "z";            # The native library to link. (null or string)
  #   procMacro = false;      # Whether this is a proc-macro library. See comments below.
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
  mkPkgInfoFromRegistry =
    mkSrc:
    # https://github.com/rust-lang/cargo/blob/2f3df16921deb34a92700f4d5a7ecfb424739558/src/cargo/sources/registry/mod.rs#L259
    { name, vers, deps, features, cksum, yanked ? false, links ? null, features2 ? {}, ... }:
    {
      inherit name yanked links;
      features = features // features2;
      version = vers;
      sha256 = cksum;
      dependencies = map sanitizeDep deps;
      # N.B. Proc macro indicator is not in the registry: https://github.com/rust-lang/cargo/issues/9605
      # This would be overrided in `mkPkgInfoSet`.
      procMacro = false;
      src = mkSrc {
        inherit name;
        version = vers;
        sha256 = cksum;
      };
    };

  # Sanitize a dependency reference.
  # Handling `package` and fill missing fields.
  sanitizeDep =
    { name
    , package ? name
    , version ? null # Cargo.toml use `version`
    , req ? version
    , features ? []
    , optional ? false
    , default_features ? true
    , target ? null
    , kind
    , ...
    }@args: args // {
      inherit name package req features optional default_features target kind;

      # Note that `package` == `name` is not the same as omitting `package`.
      # See: https://github.com/rust-lang/cargo/issues/6827
      # Here we let `package` fallback to name, but set a special `rename` to the renamed `name`
      # if `package` != `name`. `rename` will affect the `--extern` flags.
      #
      # For remind:
      # - `name` is used for coresponding feature name for optional dependencies.
      # - `package` is used for the original package name of dependency crate.
      #   - If `package` isn't set, the code name (for `use` or `extern crate`) of the dependency is its lib name.
      #     `--extern` also use its own lib name.
      #   - If `package` is set, the code name and `--extern` both use the renamed `name`.
    } // optionalAttrs (args.package or null != null) {
      rename = replaceStrings ["-"] ["_"] name;
    };

  # Build a simplified crate into from a parsed Cargo.toml.
  mkPkgInfoFromCargoToml = { lockVersion ? 3, package, features ? {}, target ? {}, ... }@args: src: main-workspace: let
    transDeps = target: kind:
      mapAttrsToList (name: v:
        {
          inherit name target kind;
          package = v.package or name;
          # For path or git dependencies, `version` can be omitted.
          req = if isString v then v else v.version or null;
          features = v.features or [];
          optional = v.optional or false;
          # It's `default-features` in Cargo.toml, but `default_features` in index and in pkg info.
          default_features =
            warnIf (v ? default_features) "Ignoring `default_features`. Do you mean `default-features`?"
            (v.default-features or true);

          # This is used for dependency resoving inside Cargo.lock.
          source =
            if v ? registry then
              throw "Dependency with `registry` is not supported. Use `registry-index` with explicit URL instead."
            else if v ? registry-index then
              "registry+${v.registry-index}"
            else if v ? git then
              # For v1 and v2, git-branch URLs are encoded as "git+url" with no query parameters.
              if v ? branch && lockVersion >= 3 then
                "git+${v.git}?branch=${v.branch}"
              else if v ? tag then
                "git+${v.git}?tag=${v.tag}"
              else if v ? rev then
                "git+${v.git}?rev=${v.rev}"
              else
                "git+${v.git}"
            else if v ? path then
              # Local crates are mark with `null` source.
              null
            else
              # Default to use crates.io registry.
              # N.B. This is necessary and must not be `null`, or it will be indinstinguishable
              # with local crates or crates from other registries.
              "registry+https://github.com/rust-lang/crates.io-index";

        # See `sanitizeDep`
        } // optionalAttrs (v.package or null != null) {
          rename = replaceStrings ["-"] ["_"] name;
        });

    collectTargetDeps = target: { dependencies ? {}, dev-dependencies ? {}, build-dependencies ? {}, ... }:
      # per https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html#inheriting-a-dependency-from-a-workspace
      let inherit-dep-from-ws = dep_name: info:
            if info ? "workspace" && info.workspace then
              let ws-dep = main-workspace.dependencies.${dep_name}; in
              if builtins.typeOf ws-dep == "string" then
                { version = ws-dep; } // { optional = info.optional or false; features = info.features or []; }
              else if builtins.typeOf ws-dep == "set" then
                ws-dep // { optional = info.optional or false; features = ws-dep.features or [] ++ info.features or []; }
              else
                throw "Unrecognized dep type ${dep_name}"
            else info;
      in
        transDeps target "normal" (mapAttrs inherit-dep-from-ws dependencies) ++
        transDeps target "dev" (mapAttrs inherit-dep-from-ws dev-dependencies) ++
        transDeps target "build" (mapAttrs inherit-dep-from-ws build-dependencies);
    inherit-package-from-workspace = name: info:
      if builtins.typeOf info == "set" && info ? "workspace" && info.workspace then
        main-workspace.package.${name}
      else
        info;
  in
    {
      inherit src features;
      links = package.links or null;
      procMacro = args.lib.proc-macro or false;
      dependencies =
        collectTargetDeps null args ++
        (lib.lists.flatten (mapAttrsToList collectTargetDeps target));
    } // (mapAttrs inherit-package-from-workspace package);

  pkg-info-from-toml-tests = { assertEq, ... }: {
    simple = let
      cargoToml = fromTOML (readFile ../tests/tokio-app/Cargo.toml);
      info = mkPkgInfoFromCargoToml cargoToml "<src>" {};

      expected = {
        name = "tokio-app";
        version = "0.0.0";
        edition = "2018";
        features = { };
        src = "<src>";
        links = null;
        procMacro = false;
        dependencies = [
          {
            name = "tokio";
            package = "tokio";
            default_features = false;
            features = [ "rt-multi-thread" "macros" "time" ];
            kind = "normal";
            optional = false;
            req = "1";
            target = null;
            source = "registry+https://github.com/rust-lang/crates.io-index";
          }
        ];
      };
    in
      assertEq info expected;

    build-deps =
      let
        cargoToml = fromTOML (readFile ../tests/build-deps/Cargo.toml);
        info = mkPkgInfoFromCargoToml cargoToml "<src>" {};
        expected = {
          name = "build-deps";
          edition = "2015";
          version = "0.0.0";
          features = { };
          src = "<src>";
          links = null;
          procMacro = false;
          dependencies = [
            {
              name = "semver";
              package = "semver";
              default_features = true;
              features = [ ];
              kind = "build";
              optional = false;
              req = "1";
              target = null;
              source = "registry+https://github.com/rust-lang/crates.io-index";
            }
          ];
        };
      in
        assertEq info expected;
  };
}
