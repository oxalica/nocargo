{ pkgs ? import <nixpkgs> { overlays = [ (builtins.getFlake (toString ../.)).outputs.overlay ]; } }:
let
  inherit (pkgs) lib;

  git-semver = builtins.fetchTarball {
    url = "https://github.com/dtolnay/semver/archive/1.0.4/master.tar.gz";
    sha256 = "1l2nkfmjgz2zkqw03hmy66q0v1rxvs7fc4kh63ph4lf1924wrmix";
  };

  gitSources = {
    "https://github.com/dtolnay/semver?tag=1.0.4" = git-semver;
    "git://github.com/dtolnay/semver?branch=master" = git-semver;
    "ssh://git@github.com/dtolnay/semver?rev=ea9ea80c023ba3913b9ab0af1d983f137b4110a5" = git-semver;
    "ssh://git@github.com/dtolnay/semver" = git-semver;
  };

  mkHelloWorlds = set:
    let
      build = src: profile: pkgs.nocargo.buildRustCrateFromSrcAndLock {
        inherit src profile gitSources;
      };

      toTest = name: drv: pkgs.runCommand "${drv.name}" {} ''
        name="${lib.replaceStrings ["-"] ["_"] name}"
        got="$("${drv.bin}/bin/$name")"
        expect="Hello, world!"
        echo "Got   : $got"
        echo "Expect: $expect"
        [[ "$got" == "$expect" ]]
        touch $out
      '';

      genProfiles = name: path: [
        { name = name; value = toTest name (build path "release"); }
        { name = name + "-debug"; value = toTest name (build path "dev"); }
      ];

    in
      lib.listToAttrs
        (lib.flatten
          (lib.mapAttrsToList genProfiles set));

in
{
  hello-worlds = mkHelloWorlds {
    custom-lib-name = ./custom-lib-name;
    dep-source-kinds = ./dep-source-kinds;
    dependent = ./dependent;
    libz-link = ./libz-link;
    simple-features = ./simple-features;
    test-openssl = ./test-openssl;
    test-rand = ./test-rand;
    test-rustls = ./test-rustls;
    tokio-app = ./tokio-app;
  };
}
