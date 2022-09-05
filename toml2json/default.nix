{ lib, stdenv, fetchurl, rustc, darwin }:
let
  fetch = name: version: sha256:
    fetchurl {
      name = "crate-${name}-${version}.tar.gz";
      url = "https://crates.io/api/v1/crates/${name}/${version}/download";
      inherit sha256;
    };

  manifest = builtins.fromTOML (builtins.readFile ./Cargo.toml);
  lock = builtins.fromTOML (builtins.readFile ./Cargo.lock);

in stdenv.mkDerivation {
  pname = manifest.package.name;
  version = manifest.package.version;

  srcs = map ({ name, version, checksum ? null, ... }: if checksum != null then fetch name version checksum else null) lock.package;

  sourceRoot = ".";

  buildInputs = lib.optional stdenv.isDarwin darwin.libiconv;
  nativeBuildInputs = [ rustc ];

  buildPhase = ''
    buildFlagsArray+=(
      --color=always
      --out-dir .
      -L .
      -C codegen-units=1
      -C opt-level=3
      --cap-lints allow
    )

    run() {
      echo "rustc $* ''${buildFlagsArray[*]}"
      rustc "$@" "''${buildFlagsArray[@]}"
    }

    run itoa-*/src/lib.rs --crate-name itoa --crate-type lib \
      --cfg 'feature="default"' --cfg 'feature="std"'
    run ryu-*/src/lib.rs --crate-name ryu --crate-type lib
    run serde-*/src/lib.rs --crate-name serde --crate-type lib \
      --cfg 'feature="default"' --cfg 'feature="std"'
    run serde_json-*/src/lib.rs --crate-name serde_json --crate-type lib \
      --edition=2018 \
      --cfg 'feature="default"' --cfg 'feature="std"' \
      --extern itoa=libitoa.rlib \
      --extern ryu=libryu.rlib \
      --extern serde=libserde.rlib
    run toml-*/src/lib.rs --crate-name toml --crate-type lib \
      --edition=2018 \
      --extern serde=libserde.rlib
    run ${./src/main.rs} --crate-name toml2json --crate-type bin \
      --extern serde_json=./libserde_json.rlib \
      --extern toml=libtoml.rlib
  '';

  testToml = ''
    [hello]
    world = "good"
    [target."cfg(target = \"good\")"]
    foo = "bar"
  '';

  testJson = ''{"hello":{"world":"good"},"target":{"cfg(target = \"good\")":{"foo":"bar"}}}'';

  doCheck = true;
  checkPhase = ''
    ./toml2json <<<"$testToml" >out.json
    echo "Got   : $(cat out.json)"
    echo "Expect: $testJson"
    [[ "$(cat out.json)" == "$testJson" ]]
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp -t $out/bin ./toml2json
  '';
}
