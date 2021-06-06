{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    crates-io-index = {
      url = "github:rust-lang/crates.io-index";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crates-io-index }: let
    overlay = final: prev: let
      out = import ./. final prev;
      out' = out // {
        crates-nix = out.crates-nix // {
          inherit crates-io-index;
        };
      };
    in out';
  in {

    inherit overlay;

    checks."x86_64-linux" = let
      inherit (import nixpkgs { system = "x86_64-linux"; overlays = [ overlay ]; }) lib pkgs;

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
        lib.crates-nix.version-req-tests assertFns //
        lib.crates-nix.cfg-parser-tests assertFns //
        lib.crates-nix.platform-cfg-tests assertFns //
        lib.crates-nix.feature-tests assertFns //
        lib.crates-nix.resolve-deps-tests assertFns pkgs.crates-nix //
        lib.crates-nix.resolve-features-tests assertFns //
        lib.crates-nix.crate-info-from-toml-tests assertFns //
        lib.crates-nix.build-from-src-dry-tests assertFns { inherit (pkgs) crates-nix stdenv; };

      checkDrvs = let
        mkHelloWorld = name: drv: pkgs.runCommand "check-${drv.name}" {} ''
          name="${name}"
          name="''${name//-/_}"
          got="$(${drv.bin}/bin/$name)"
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

