source $stdenv/setup
source $builderCommon
shopt -s nullglob

buildFlagsArray+=( -C metadata="$rustcMeta" )

dontInstall=1

configurePhase() {
    runHook preConfigure

    convertCargoToml

    buildRs="$(jq --raw-output '.package.build // ""' "$cargoTomlJson")"
    if [[ -z "$buildRs" && -e build.rs ]]; then
        buildRs=build.rs
    fi
    if [[ -z "$buildRs" ]]; then
        echo "No build script to be built"
        mkdir -p $out
        exit 0
    fi

    edition="$(jq --raw-output '.package.edition // ""' "$cargoTomlJson")"
    if [[ -n "$edition" ]]; then
        buildFlagsArray+=(--edition "$edition")
    fi

    addFeatures buildFlagsArray $features
    addExternFlags buildFlagsArray link $dependencies
    setCargoCommonBuildEnv

    depsClosure="$(mktemp -d)"
    collectTransDeps "$depsClosure" $dependencies
    buildFlagsArray+=(-L "dependency=$depsClosure")

    runHook postConfigure
}

buildPhase() {
    runHook preBuild

    mkdir -p $out/bin

    runRustc "Building build script" \
        "$buildRs" \
        --out-dir "$out/bin" \
        --crate-name "build_script_build" \
        --crate-type bin \
        --emit link \
        -C embed-bitcode=no \
        "${buildFlagsArray[@]}"

    runHook postBuild
}

genericBuild
