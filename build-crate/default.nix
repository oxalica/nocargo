{ lib, stdenv, rustc, yj, jq }:
{ crateName
, version
, src
, dependencies ? {}
, features ? {}
, nativeBuildInputs ? []
}@args:
stdenv.mkDerivation ({
  pname = "rust_${crateName}";
  inherit crateName version src;

  nativeBuildInputs = [ rustc yj jq ] ++ nativeBuildInputs;

  rustcMeta = let
    deps = lib.concatMapStrings (dep: dep.rustcMeta)
      (builtins.attrValues dependencies);
    feats = lib.concatStringsSep ";" (builtins.attrNames features);
    final = "${crateName} ${version} ${feats} ${deps}";
  in
    lib.substring 0 16 (builtins.hashString "sha256" final);

  features = builtins.attrNames features;

  dependencies = lib.mapAttrsToList
    (name: dep: "${name}=${dep}/lib/lib${dep.crateName}-${dep.rustcMeta}.rlib")
    dependencies;

  configurePhase = ''
    buildFlagsArray=()
    buildFlagsArray+=(-C codegen-units=$NIX_BUILD_CORES)

    runHook preConfigure

    # Metadata.

    buildFlagsArray+=(-C metadata="$rustcMeta")

    # Features and dependencies.

    for feat in $features; do
      buildFlagsArray+=(--cfg "feature=\"$feat\"")
    done
    for dep in $dependencies; do
      buildFlagsArray+=(--extern "$dep")
    done

    # Common info from Cargo.toml.

    yj -tj <Cargo.toml >Cargo.toml.json

    edition="$(jq --raw-output '.package.edition // ""' Cargo.toml.json)"
    if [[ -n "$edition" ]]; then
      buildFlagsArray+=(--edition "$edition")
    fi

    # Target auto-discovery.
    # https://doc.rust-lang.org/cargo/guide/project-layout.html

    libSrc="$(jq --raw-output '.lib.path // ""' Cargo.toml.json)"
    if [[ -z "$libSrc" && -e src/lib.rs ]]; then
      libSrc=src/lib.rs
    fi

    libCrateType="$(jq --raw-output '.lib."crate-type" // ["lib"] | join(",")' Cargo.toml.json)"
    if [[ "$(jq --raw-output '.lib."proc-macro" // false' Cargo.toml.json)" == true ]]; then
      libCrateType="proc-macro"
    fi

    isProcMacro="$()"

    runRustc() {
      echo "$1: rustc ''${*:2}"
      rustc "''${@:2}"
    }

    runHook postConfigure
  '';

  buildFlags = [
    "-C opt-level=3"
    "-C incremental=no"
    "--color=always"
  ];

  buildPhase = ''
    runHook preBuild

    if [[ -n "$libSrc" ]]; then
      # Place transitive dependencies (symlinks) in a single directory.
      depsClosure=$out/nix-support/rust-deps-closure
      mkdir -p $depsClosure
      shopt -s nullglob
      for dep in $dependencies; do
        depPath="''${dep##*=}"
        cp --no-dereference -t $depsClosure $depPath/nix-support/rust-deps-closure/* 2>/dev/null || true
        ln -st $depsClosure $depPath/lib/* 2>/dev/null || true
      done

      mkdir -p $out/lib
      runRustc "Building lib" \
        "$libSrc" \
        --out-dir $out/lib \
        --crate-name "$crateName" \
        --crate-type "$libCrateType" \
        -C extra-filename="-$rustcMeta" \
        -L dependency=$depsClosure \
        $buildFlags \
        "''${buildFlagsArray[@]}"
    fi

    runHook postBuild
  '';

  dontInstall = true;

} // removeAttrs args [ "dependencies" "features" "nativeBuildInputs" ])
