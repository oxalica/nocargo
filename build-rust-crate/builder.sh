source $stdenv/setup

buildFlagsArray=(
    --color=always
    -C opt-level=3
    -C incremental=no
    -C codegen-units=$NIX_BUILD_CORES
    -C metadata="$rustcMeta"
)

for feat in $features; do
    buildFlagsArray+=(--cfg "feature=\"$feat\"")
done

addExternFlags() {
    local var="$1" dep name libBasename closure lib
    shift
    for dep in "$@"; do
        IFS=: read name libBasename closure <<<"$dep"
        if [[ -e $libBasename.rlib ]]; then
            lib=$libBasename.rlib
        elif [[ -e $libBasename.so ]]; then
            lib=$libBasename.so
        else
            echo "No linkable file found for dependency: $libBasename"
            exit 1
        fi
        eval "$var+=(--extern $name=$lib)"
    done
}

configurePhase() {
    runHook preConfigure

    # Dependencies.
    addExternFlags buildFlagsArray $dependencies

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

    if [[ -n "$libSrc" ]]; then
        libCrateType="$(jq --raw-output '.lib."crate-type" // ["lib"] | join(",")' Cargo.toml.json)"
        if [[ "$(jq --raw-output '.lib."proc-macro" // false' Cargo.toml.json)" == true ]]; then
            libCrateType="proc-macro"
        fi

        # Place transitive dependencies (symlinks) in a single directory.
        depsClosure=$dev/nix-support/rust-deps-closure
        mkdir -p $depsClosure
        shopt -s nullglob
        for dep in $dependencies; do
            depPath="${dep##*=}"
            cp --no-dereference -t $depsClosure $depPath/nix-support/rust-deps-closure/* 2>/dev/null || true
            ln -st $depsClosure $depPath/lib/* 2>/dev/null || true
        done
    fi

    runHook postConfigure
}

runRustc() {
    local msg="$1"
    shift
    echo "$msg: RUSTC $*"
    $RUSTC "$@"
}

buildPhase() {
    runHook preBuild

    mkdir -p "$out" "$dev"

    if [[ -n "$libSrc" ]]; then
        mkdir -p $out/lib
        runRustc "Building lib" \
            "$libSrc" \
            --out-dir $out/lib \
            --crate-name "$crateName" \
            --crate-type "$libCrateType" \
            -C extra-filename="-$rustcMeta" \
            -L dependency=$depsClosure \
            $buildFlags \
            "${buildFlagsArray[@]}"
    fi

    runHook postBuild
}

genericBuild
