{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    crates-io-index = {
      url = "github:rust-lang/crates.io-index";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crates-io-index }: {
    overlay = final: prev: let
      out = import ./. final prev;
      out' = out // {
        crates-nix = out.crates-nix // {
          inherit crates-io-index;
        };
      };
    in out';

    checks."x86_64-linux" = let
      inherit (nixpkgs) lib;

      inherit (import ./lib.nix { inherit lib; }) compareSemver parseSemverReq version-req-tests;

      assertEqWithMsg = msg: lhs: rhs: {
        assertion = lhs == rhs;
        message = "${msg}: `${toString lhs}` != `${toString rhs}`";
      };

      assertEq = lhs: rhs: {
        assertion = lhs == rhs;
        message = "`${toString lhs}` != `${toString rhs}`";
      };

      testMatchReq = req: { yes ? [], no ? [] }: let
        checker = parseSemverReq req;
      in
        map (ver: assertEqWithMsg ver (checker ver) true) yes ++
        map (ver: assertEqWithMsg ver (checker ver) false) no;

      assertions = {
        version-compare-simple1 = assertEq (compareSemver "1.2.3" "1.2.2") 1;
        version-compare-simple2 = assertEq (compareSemver "1.2.3" "1.2.3") 0;
        version-compare-simple3 = assertEq (compareSemver "1.2.3" "1.2.4") (-1);
        version-compare-simple4 = assertEq (compareSemver "1.2.3" "1.1.3") 1;
        version-compare-simple5 = assertEq (compareSemver "1.2.3" "1.3.3") (-1);
        version-compare-simple6 = assertEq (compareSemver "1.2.3" "0.2.3") 1;
        version-compare-simple7 = assertEq (compareSemver "1.2.3" "2.2.3") (-1);
      } // version-req-tests testMatchReq;

      checkDrvs = {};

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

