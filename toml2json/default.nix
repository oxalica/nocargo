{ stdenv, fetchurl, rustc }:
let
  fetch = name: version: sha256:
    fetchurl {
      name = "crate-${name}-${version}.tar.gz";
      url = "https://crates.io/api/v1/crates/${name}/${version}/download";
      inherit sha256;
    };

in stdenv.mkDerivation {
  pname = "toml2json";
  version = "0.0.0";

  srcs = [
    (fetch "itoa" "0.4.7" "dd25036021b0de88a0aff6b850051563c6516d0bf53f8638938edbb9de732736")
    (fetch "ryu" "1.0.5" "71d301d4193d031abdd79ff7e3dd721168a9572ef3fe51a1517aba235bd8f86e")
    (fetch "serde" "1.0.126" "ec7505abeacaec74ae4778d9d9328fe5a5d04253220a85c4ee022239fc996d03")
    (fetch "serde_json" "1.0.64" "799e97dc9fdae36a5c8b8f2cae9ce2ee9fdce2058c57a93e6099d919fd982f79")
    (fetch "toml" "0.5.8" "a31142970826733df8241ef35dc040ef98c679ab14d7c3e54d827099b3acecaa")
  ];

  sourceRoot = ".";

  nativeBuildInputs = [ rustc ];

  buildPhase = ''
    buildFlagsArray+=(
      --color=always
      --out-dir .
      -L .
      -C codegen-units=1
      -C opt-level=3
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
