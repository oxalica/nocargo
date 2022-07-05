{ pkgs, self, inputs }:
let
  inherit (pkgs.lib) mapAttrs attrNames assertMsg;
  inherit (self.lib.${pkgs.system}) mkRustPackage mkRustWorkspace;
  inherit (self.packages.${pkgs.system}) noc;

  git-semver = builtins.fetchTarball {
    url = "https://github.com/dtolnay/semver/archive/1.0.4/master.tar.gz";
    sha256 = "1l2nkfmjgz2zkqw03hmy66q0v1rxvs7fc4kh63ph4lf1924wrmix";
  };

  gitSrcs = {
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

  mkHelloWorldTest = src: {
    release = shouldBeHelloWorld (mkRustPackage {
      profile = "release";
      inherit src gitSrcs;
    });
    debug = shouldBeHelloWorld (mkRustPackage {
      profile = "dev";
      inherit src gitSrcs;
    });
  };

  mkWorkspaceTest = src: expectMembers: let
    check = ws:
      let gotMembers = attrNames ws.pkgs; in
      assert assertMsg (gotMembers == expectMembers) ''
        Member assertion failed.
        expect: ${toString expectMembers}
        got:    ${toString gotMembers}
      '';
      ws;
  in {
    release = check (mkRustWorkspace {
      inherit src;
      profile = "release";
    });
    debug = check (mkRustWorkspace {
      inherit src;
      profile = "dev";
    });
  };

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
  _1000-hello-worlds = {
    custom-lib-name = mkHelloWorldTest ./custom-lib-name;
    dep-source-kinds = mkHelloWorldTest ./dep-source-kinds;
    dependent = mkHelloWorldTest ./dependent;
    libz-link = mkHelloWorldTest ./libz-link;
    simple-features = mkHelloWorldTest ./simple-features;
    test-openssl = mkHelloWorldTest ./test-openssl;
    test-rand = mkHelloWorldTest ./test-rand;
    test-rustls = mkHelloWorldTest ./test-rustls;
    tokio-app = mkHelloWorldTest ./tokio-app;

    workspace-virtual = mkWorkspaceTest ./workspace-virtual [ "bar" "foo" ];
    workspace-inline = mkWorkspaceTest ./workspace-inline [ "bar" "baz" "foo" ];
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
