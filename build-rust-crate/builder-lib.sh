source $stdenv/setup
source $builderCommon
shopt -s nullglob

buildFlagsArray+=( -C metadata="$rustcMeta" )

declare -A binBuildFlagsMap

dontFixup=1

configurePhase() {
    runHook preConfigure

    convertCargoToml

    libSrc="$(jq --raw-output '.lib.path // ""' "$cargoTomlJson")"
    if [[ -z "$libSrc" && -e src/lib.rs ]]; then
        libSrc=src/lib.rs
    fi
    if [[ ! -e "$libSrc" ]]; then
        echo "No library to be built"
        mkdir $out $dev
        exit 0
    fi

    edition="$(jq --raw-output '.package.edition // .lib.edition // ""' "$cargoTomlJson")"
    if [[ -n "$edition" ]]; then
        buildFlagsArray+=(--edition "$edition")
    fi

    crateType="$(jq --raw-output '.lib."crate-type" // ["lib"] | join(",")' "$cargoTomlJson")"
    if [[ "$(jq --raw-output '.lib."proc-macro"' "$cargoTomlJson")" == true ]]; then
        # Override crate type.
        crateType="proc-macro"
        mkdir -p $dev/rust-support
        touch $dev/rust-support/is-proc-macro
    fi

    case "$crateType" in
        lib|rlib)
            addExternFlags buildFlagsArray meta $dependencies
            ;;
        dylib|cdylib|proc-macro|bin)
            addExternFlags buildFlagsArray link $dependencies
            ;;
        *)
            echo "Unsupported crate-type: $crateType"
            exit 1
            ;;
    esac

    addFeatures buildFlagsArray $features
    importBuildOut buildFlagsArray "$buildOutDrv" "$crateType"
    setCargoCommonBuildEnv

    collectTransDeps $dev/rust-support/deps-closure $dependencies
    buildFlagsArray+=(-L "dependency=$dev/rust-support/deps-closure")

    runHook postConfigure
}

buildPhase() {
    runHook preBuild

    mkdir -p $out/lib
    runRustc "Building lib" \
        "$libSrc" \
        --out-dir $out/lib \
        --crate-name "$crateName" \
        --crate-type "$crateType" \
        --emit metadata,link \
        -C embed-bitcode=no \
        -C extra-filename="-$rustcMeta" \
        "${buildFlagsArray[@]}"

    runHook postBuild
}

installPhase() {
    runHook preInstall

    mkdir -p $out $bin $dev/lib $dev/rust-support/deps-closure

    # May be empty.
    mv -t $dev/lib $out/lib/*.rmeta 2>/dev/null || true
    ln -sft $dev/rust-support/deps-closure $out/lib/* $dev/lib/* 2>/dev/null || true

    runHook postInstall
}

genericBuild
