{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    registry-crates-io = {
      url = "github:rust-lang/crates.io-index";
      flake = false;
    };
  };

  outputs = { self, flake-utils, nixpkgs, registry-crates-io }@inputs:
    let
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ];

      inherit (builtins) readFile fromJSON toJSON typeOf;
      inherit (nixpkgs.lib)
        isDerivation isFunction isAttrs mapAttrs mapAttrsToList listToAttrs
        replaceStrings flatten composeExtensions;

      nocargo-lib = import ./lib { inherit (nixpkgs) lib; };

    in flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        defaultRegistries = {
          "https://github.com/rust-lang/crates.io-index" =
            nocargo-lib.pkg-info.mkIndex pkgs.fetchurl registry-crates-io
            (import ./crates-io-override {
              inherit (nixpkgs) lib;
              inherit pkgs;
            });
        };
      in rec {
        apps.default = {
          type = "app";
          program = "${packages.noc}/bin/noc";
        };

        # Is there a better place? `naersk` places builders under `lib.${system}`.
        lib = rec {
          mkIndex = nocargo-lib.pkg-info.mkIndex pkgs.fetchurl;
          buildRustCrate = pkgs.callPackage ./build-rust-crate {
            inherit (packages) toml2json;
            inherit nocargo-lib;
          };
          mkRustPackageOrWorkspace = pkgs.callPackage nocargo-lib.support.mkRustPackageOrWorkspace {
            inherit defaultRegistries buildRustCrate;
          };
        };

        packages = rec {
          default = noc;
          toml2json = pkgs.callPackage ./toml2json { };
          noc = (lib.mkRustPackageOrWorkspace {
            src = ./noc;
          }).release.nocargo.bin;

          cache = pkgs.callPackage ./cache {
            inherit (lib) mkRustPackageOrWorkspace;
          };
        };

        checks = let
          okDrv = derivation {
            name = "success";
            inherit system;
            builder = "/bin/sh";
            args = [ "-c" ": >$out" ];
          };

          checkArgs = {
            inherit pkgs defaultRegistries;

            assertEq = got: expect: {
              __assertion = true;
              fn = name:
                if toJSON got == toJSON expect then
                  okDrv
                else
                  pkgs.runCommandNoCC name {
                    nativeBuildInputs = [ pkgs.jq ];
                    got = toJSON got;
                    expect = toJSON expect;
                  } ''
                    if [[ ''${#got} < 32 && ''${#expect} < 32 ]]; then
                      echo "got:    $got"
                      echo "expect: $expect"
                    else
                      echo "got:"
                      jq . <<<"$got"
                      echo
                      echo "expect:"
                      jq . <<<"$expect"
                      echo
                      echo "diff:"
                      diff -y <(jq . <<<"$got") <(jq . <<<"$expect")
                      exit 1
                    fi
                  '';
            };
          };

          tests = with nocargo-lib; {
            _0000-semver-compare = semver.semver-compare-tests;
            _0001-semver-req = semver.semver-req-tests;
            _0002-cfg-parser = target-cfg.cfg-parser-tests;
            _0003-cfg-eval = target-cfg.cfg-eval-tests;
            _0004-platform-cfg = target-cfg.platform-cfg-tests;
            _0005-glob = glob.glob-tests;
            _0006-sanitize-relative-path = support.sanitize-relative-path-tests;

            _0100-pkg-info-from-toml = pkg-info.pkg-info-from-toml-tests;
            _0101-preprocess-feature = resolve.preprocess-feature-tests;
            _0102-update-feature = resolve.update-feature-tests;
            _0103-resolve-feature = resolve.resolve-feature-tests;

            _0200-resolve-deps = resolve.resolve-deps-tests;
            _0201-build-from-src-dry = support.build-from-src-dry-tests;
          } // import ./tests {
            inherit pkgs self inputs defaultRegistries;
          };

          flattenTests = prefix: v:
            if isDerivation v then {
              name = prefix;
              value = v;
            } else if v ? __assertion then {
              name = prefix;
              value = v.fn prefix;
            } else if isFunction v then
              flattenTests prefix (v checkArgs)
            else if isAttrs v then
              mapAttrsToList (name: flattenTests "${prefix}-${name}") v
            else
              throw "Unexpect test type: ${typeOf v}";

          tests' = listToAttrs (flatten (mapAttrsToList flattenTests tests));

        in tests';
      });
}

