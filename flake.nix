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
            "https://github.com/rust-lang/crates.io-index" = out.lib.nocargo.mkIndex registry-crates-io;
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

      assertEqMsg = msg: lhs: rhs: {
        assertion = lhs == rhs;
        message = "${msg}: `${toString lhs}` != `${toString rhs}`";
      };

      assertEq = lhs: rhs: {
        assertion = lhs == rhs;
        message = "`${toString lhs}` != `${toString rhs}`";
      };

      assertDeepEq = lhs: rhs: let
        lhs' = builtins.toJSON lhs;
        rhs' = builtins.toJSON rhs;
      in {
        assertion = lhs' == rhs';
        message = "\nLhs:\n${lhs'}\nRhs:\n${rhs'}";
      };

      assertFns = { inherit assertEq assertEqMsg assertDeepEq; };

      assertions =
        lib.nocargo.version-req-tests assertFns //
        lib.nocargo.cfg-parser-tests assertFns //
        lib.nocargo.platform-cfg-tests assertFns //
        lib.nocargo.feature-tests assertFns //
        lib.nocargo.resolve-deps-tests assertFns pkgs.nocargo //
        lib.nocargo.resolve-features-tests assertFns //
        lib.nocargo.crate-info-from-toml-tests assertFns //
        lib.nocargo.build-from-src-dry-tests assertFns { inherit (pkgs) nocargo pkgs; };

      checkDrvs = let
        mkHelloWorld = name: drv: pkgs.runCommand "check-${drv.name}" {} ''
          name="${lib.replaceStrings ["-dev" "-"] ["" "_"] name}"
          got="$("${drv.bin}/bin/$name")"
          expect="Hello, world!"
          echo "Got   : $got"
          echo "Expect: $got"
          [[ "$got" == "$expect" ]]
          touch $out
        '';
      in
        lib.mapAttrs mkHelloWorld (import ./tests { inherit pkgs; });

      failedAssertions =
        lib.filter (msg: msg != null) (
          lib.flatten (
            lib.mapAttrsToList
            (name: asserts:
              map ({ assertion, message }: if assertion
                then null
                else "Assertion `${name}` failed: ${message}\n"
              ) (lib.flatten [asserts]))
            assertions));

    in if failedAssertions == []
      then checkDrvs
      else throw (builtins.toString failedAssertions);
  };
}

