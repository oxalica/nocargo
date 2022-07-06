{ pkgs, self, inputs }:
let
  inherit (pkgs.lib) mapAttrs attrNames attrValues assertMsg head mapAttrsToList;
  inherit (self.lib.${pkgs.system}) mkRustPackageOrWorkspace;
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

  mkHelloWorldTest = src:
    mapAttrs (_: pkgs: shouldBeHelloWorld (head (attrValues pkgs)))
      (mkRustPackageOrWorkspace {
        inherit src gitSrcs;
      });

  mkWorkspaceTest = src: expectMembers: let
    ws = mkRustPackageOrWorkspace { inherit src; };
    gotMembers = attrNames ws.dev;
  in
    assert assertMsg (gotMembers == expectMembers) ''
      Member assertion failed.
      expect: ${toString expectMembers}
      got:    ${toString gotMembers}
    '';
    ws;

  # Recursive Nix setup.
  # https://github.com/NixOS/nixpkgs/blob/e966ab3965a656efdd40b6ae0d8cec6183972edc/pkgs/top-level/make-tarball.nix#L45-L48
  mkGenInit = name: path:
    pkgs.runCommandNoCC "gen-${name}" {
      nativeBuildInputs = [ noc pkgs.nix ];
      checkFlags =
        mapAttrsToList (from: to: "--override-input ${from} ${to}") {
          inherit (inputs) nixpkgs flake-utils rust-overlay registry-crates-io;
          nocargo = self;
          registry-1 = inputs.registry-crates-io;
          git-1 = git-semver;
          git-2 = git-semver;
          git-3 = git-semver;
          git-4 = git-semver;
        };
    } ''
      cp -r ${path} src
      chmod -R u+w src
      cd src

      header "generating flake.nix"
      noc init
      cat flake.nix
      install -D flake.nix $out/flake.nix

      header "checking with 'nix flake check'"
      export NIX_STATE_DIR=$TMPDIR/nix/var
      export NIX_PATH=
      export HOME=$TMPDIR
      nix-store --init
      nixFlags=(
        --offline
        --option build-users-group ""
        --option experimental-features "ca-derivations nix-command flakes"
        --store $TMPDIR/nix/store
      )

      nix flake check \
        --no-build \
        --show-trace \
        $checkFlags \
        "''${nixFlags[@]}"
    '';

in
{
  _1000-hello-worlds = {
    custom-lib-name = mkHelloWorldTest ./custom-lib-name;
    dep-source-kinds = mkHelloWorldTest ./dep-source-kinds;
    dependent = mkHelloWorldTest ./dependent;
    dependent-v1 = mkHelloWorldTest ./dependent-v1;
    dependent-v2 = mkHelloWorldTest ./dependent-v2;
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

    workspace-virtual = ./workspace-virtual;
    workspace-inline = ./workspace-inline;
  };
}
