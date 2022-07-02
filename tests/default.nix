{ pkgs, self, inputs }:
let
  inherit (pkgs.lib) listToAttrs flatten mapAttrsToList mapAttrs;
  inherit (self.lib.${pkgs.system}) buildRustPackageFromSrcAndLock buildRustWorkspaceFromSrcAndLock;
  inherit (self.packages.${pkgs.system}) noc;

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

  shouldBeHelloWorld = drv: pkgs.runCommand "${drv.name}" {} ''
    binaries=(${drv.bin}/bin/*)
    [[ ''${#binaries[@]} == 1 ]]
    got="$(''${binaries[0]})"
    expect="Hello, world!"
    echo "Got   : $got"
    echo "Expect: $expect"
    [[ "$got" == "$expect" ]]
    touch $out
  '';

  mkHelloWorlds = set:
    let
      genProfiles = name: f: [
        { name = name; value = shouldBeHelloWorld (f "release"); }
        { name = name + "-debug"; value = shouldBeHelloWorld (f "dev"); }
      ];
    in
      listToAttrs
        (flatten
          (mapAttrsToList genProfiles set));

  mkPackage = src: profile: buildRustPackageFromSrcAndLock {
    inherit src profile gitSources;
  };

  mkWorkspace = src: expectMembers: entry: profile:
    let
      set = buildRustWorkspaceFromSrcAndLock {
        inherit src profile;
      };
    in
      assert builtins.attrNames set == expectMembers;
      set.${entry};

  # Check `noc init`.
  # TODO: Recursive nix?
  mkGenInit = name: path:
    pkgs.runCommandNoCC "gen-${name}" {
      nativeBuildInputs = [ noc pkgs.nix ];
    } ''
      cp -r ${path} build
      chmod -R u+w build
      cd build
      noc init
      install -D flake.nix $out/flake.nix
    '';

in
{
  _1000-hello-worlds = mkHelloWorlds {
    custom-lib-name = mkPackage ./custom-lib-name;
    dep-source-kinds = mkPackage ./dep-source-kinds;
    dependent = mkPackage ./dependent;
    libz-link = mkPackage ./libz-link;
    simple-features = mkPackage ./simple-features;
    test-openssl = mkPackage ./test-openssl;
    test-rand = mkPackage ./test-rand;
    test-rustls = mkPackage ./test-rustls;
    tokio-app = mkPackage ./tokio-app;

    workspace-virtual = mkWorkspace ./workspace-virtual [ "bar" "foo" ] "foo";
    workspace-inline = mkWorkspace ./workspace-inline [ "bar" "baz" "foo" ] "foo";
  };

  _1100-gen-init = mapAttrs mkGenInit {
    custom-lib-name = ./custom-lib-name;
    dep-source-kinds = ./dep-source-kinds;
    dependent = ./dependent;
    libz-link = ./libz-link;
    simple-features = ./simple-features;
    test-openssl = ./test-openssl;
    test-rand = ./test-rand;
    test-rustls = ./test-rustls;
    tokio-app = ./tokio-app;

    # workspace-virtual = ./workspace-virtual;
    # workspace-inline = ./workspace-inline;
  };
}
