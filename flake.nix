{
  inputs = {
    flake-util.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    registry-crates-io = {
      url = "github:rust-lang/crates.io-index";
      flake = false;
    };
  };

  outputs = { self, flake-util, nixpkgs, registry-crates-io }:
    let
      supportedSystems = [ "x86_64-linux" ];

      inherit (flake-util.lib) eachSystem;

      inherit (builtins) readFile fromJSON toJSON typeOf;
      inherit (nixpkgs.lib)
        isDerivation isFunction isAttrs mapAttrs mapAttrsToList listToAttrs
        replaceStrings flatten composeExtensions;

      overlay = composeExtensions (import ./.) (final: prev: {
        nocargo = prev.nocargo // {
          defaultRegistries."https://github.com/rust-lang/crates.io-index" =
            final.lib.nocargo.mkIndex registry-crates-io
            (import ./crates-io-override { inherit (final) lib pkgs; });
        };
      });

    in {
      overlays.default = overlay;
    } // eachSystem supportedSystems (system:
      let
        inherit (import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        })
          pkgs;
      in {
        packages = rec {
          nocargo = pkgs.nocargo.nocargo.bin;
          default = nocargo;
        };

        checks = let
          okDrv = derivation {
            name = "success";
            inherit system;
            builder = "/bin/sh";
            args = [ "-c" ": >$out" ];
          };

          checkArgs = {
            inherit pkgs;

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

            assertEqFile = got: expectFile: {
              __assertion = true;
              fn = name:
                let
                  expect = readFile expectFile;
                  got' = toJSON got;
                  expect' = toJSON (fromJSON expect);
                in if got' == expect' then
                  okDrv
                else
                  pkgs.runCommandNoCC name {
                    nativeBuildInputs = [ pkgs.jq ];
                    got = got';
                  } ''
                    echo "*** Assert failed for file: ${toString expectFile}"
                    echo "$got"
                    echo "*** End of file"
                    exit 1
                  '';
            };
          };

          tests = with pkgs.lib.nocargo; {
            _0000-semver-compare = semver-compare-tests;
            _0001-semver-req = semver-req-tests;
            _0002-cfg-parser = cfg-parser-tests;
            _0003-cfg-eval = cfg-eval-tests;
            _0004-platform-cfg = platform-cfg-tests;
            _0005-glob = glob-tests;
            _0006-sanitize-relative-path = sanitize-relative-path-tests;

            _0100-crate-info-from-toml = crate-info-from-toml-tests;
            _0101-update-feature = update-feature-tests;
            _0102-resolve-feature = resolve-feature-tests;

            _0200-resolve-deps = resolve-deps-tests;
            _0201-build-from-src-dry = build-from-src-dry-tests;

            _1000-build = import ./tests { inherit pkgs; };
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

