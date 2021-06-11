source $stdenv/setup
source $builderCommon
shopt -s nullglob

buildFlagsArray+=( -C metadata="$rustcMeta" )

declare -A binBuildFlagsMap

dontFixup=1

configurePhase() {
    runHook preConfigure

    cargoTomlJson="$(convertCargoToml)"

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
    if [[ "$(jq '.lib."proc-macro"' "$cargoTomlJson")" == true ]]; then
        # Override crate type.
        crateType="proc-macro"
        mkdir -p $dev/rust-support
        touch $dev/rust-support/is-proc-macro
    fi

    addFeatures buildFlagsArray $features
    addExternFlags buildFlagsArray $dependencies

    importBuildOut "$buildOutDrv"

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

collectTransDeps() {
    local collectDir="$1" line name binName depOut depDev
    shift
    for line in "$@"; do
        IFS=: read name binName depOut depDev <<<"$line"
        if [[ -n "$(echo $depDev/rust-support/deps-closure/*)" ]]; then
            cp --no-dereference --no-clobber -t $collectDir $depDev/rust-support/deps-closure/*
        fi
    done
}

installPhase() {
    runHook preInstall

    mkdir -p $out $bin $dev/rust-support/deps-closure

    # Collect all transitive dependencies (symlinks).
    collectTransDeps $dev/rust-support/deps-closure $dependencies

    if [[ -n "$(echo $out/lib/*)" ]]; then
        ln -sft $dev/rust-support/deps-closure $out/lib/*
    fi

    runHook postInstall
}

genericBuild
