{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    registry-crates-io = {
      url = "github:rust-lang/crates.io-index";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, registry-crates-io }: let
    overlay = final: prev: let
      out = import ./. final prev;
      out' = out // {
        nocargo = out.nocargo // {
          defaultRegistries = {
            "https://github.com/rust-lang/crates.io-index" =
              out.lib.nocargo.mkIndex
                registry-crates-io
                (import ./crates-io-override { inherit (final) lib pkgs; });
          };
        };
      };
    in out';

    inherit (import nixpkgs { system = "x86_64-linux"; overlays = [ overlay ]; }) lib pkgs;

  in {

    inherit overlay;

    legacyPackages."x86_64-linux" = pkgs;

    defaultPackage."x86_64-linux" = pkgs.nocargo.nocargo.bin;

    checks."x86_64-linux" = let

      inherit (lib)
        isDerivation isFunction isAttrs mapAttrs mapAttrsToList listToAttrs replaceStrings flatten;
      inherit (builtins) readFile fromJSON toJSON typeOf;

      okDrv = pkgs.runCommand "ok" {} "touch $out";

      checkArgs = {
        inherit pkgs;

        assertEq = got: expect: {
          __assertion = true;
          fn = name:
            if toJSON got == toJSON expect
              then okDrv
              else pkgs.runCommand name {
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
                  jq . <<<"$got"
                  echo
                  echo "diff:"
                  diff -y <(jq . <<<"$got") <(jq . <<<"$expect")
                fi
                exit 1
              '';
        };

        assertEqFile = got: expectFile: {
          __assertion = true;
          fn = name:
            let
              expect = readFile expectFile;
              got' = toJSON got;
              expect' = toJSON (fromJSON expect);
            in
              if got' == expect'
                then okDrv
                else pkgs.runCommand name {
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

      tests = with lib.nocargo; {
        _0000-semver-compare-tests = semver-compare-tests;
        _0001-semver-req-tests = semver-req-tests;
        _0002-cfg-parser-tests = cfg-parser-tests;
        _0003-cfg-eval-tests = cfg-eval-tests;
        _0004-platform-cfg-tests = platform-cfg-tests;
        _0005-glob-tests = glob-tests;

        _0100-crate-info-from-toml-tests = crate-info-from-toml-tests;
        _0101-update-feature-tests = update-feature-tests;
        _0102-resolve-feature-tests = resolve-feature-tests;

        _0200-resolve-deps-tests = resolve-deps-tests;
        _0201-build-from-src-dry-tests = build-from-src-dry-tests;

        _1000-build-tests = let
          mkHelloWorld = name: drv: pkgs.runCommand "build-tests-${drv.name}" {} ''
            name="${replaceStrings ["-dev" "-"] ["" "_"] name}"
            got="$("${drv.bin}/bin/$name")"
            expect="Hello, world!"
            echo "Got   : $got"
            echo "Expect: $got"
            [[ "$got" == "$expect" ]]
            touch $out
          '';
        in
          mapAttrs mkHelloWorld (import ./tests { inherit pkgs; });
      };

      flattenTests = prefix: v:
        if isDerivation v then { name = prefix; value = v; }
        else if v ? __assertion then { name = prefix; value = v.fn prefix; }
        else if isFunction v then flattenTests prefix (v checkArgs)
        else if isAttrs v then mapAttrsToList (name: flattenTests "${prefix}-${name}") v
        else throw "Unexpect test type: ${typeOf v}";

      tests' = listToAttrs (flatten (mapAttrsToList flattenTests tests));

    in
      tests';
  };
}

