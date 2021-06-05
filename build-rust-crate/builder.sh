source $stdenv/setup
set -o pipefail
shopt -s nullglob

commonBuildFlagsArray=(
    --color=always
    -C opt-level=3
    -C incremental=no
    -C codegen-units=$NIX_BUILD_CORES
)

buildBuildFlagsArray=(
    -C metadata="$buildRustcMeta"
)

buildFlagsArray=(
    -C metadata="$rustcMeta"
)

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
        eval "$var+=(--extern $name=$lib -L dependency=$closure)"
    done
}

runBuildRustc() {
    local msg="$1"
    shift
    echo "$msg: BUILD_RUSTC $*"
    $BUILD_RUSTC "$@"
}

runRustc() {
    local msg="$1"
    shift
    echo "$msg: RUSTC $*"
    $RUSTC "$@"
}

configurePhase() {
    runHook preConfigure

    # Target auto-discovery.
    # https://doc.rust-lang.org/cargo/guide/project-layout.html

    toml2json <Cargo.toml >Cargo.toml.json

    edition="$(jq --raw-output '.package.edition // ""' Cargo.toml.json)"
    if [[ -n "$edition" ]]; then
        commonBuildFlagsArray+=(--edition "$edition")
    fi

    buildRs="$(jq --raw-output '.package.build // ""')"
    if [[ -z "$buildRs" && -e build.rs ]]; then
        buildRs=build.rs
    fi
    if [[ -n "$buildRs" ]]; then
        addExternFlags buildBuildFlagsArray $buildDependencies
    fi

    libSrc="$(jq --raw-output '.lib.path // ""' Cargo.toml.json)"
    if [[ -z "$libSrc" && -e src/lib.rs ]]; then
        libSrc=src/lib.rs
    fi

    # https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-build-scripts
    export CARGO_MANIFEST_DIR="$(pwd)"
    export CARGO_PKG_NAME="$crateName"
    export CARGO_PKG_VERSION="$version"
    export CARGO_PKG_AUTHORS="$(jq '.package.authors // "" | join(":")')"
    export CARGO_PKG_DESCRIPTION="$(jq '.package.description // ""')"
    export CARGO_PKG_HOMEPAGE="$(jq '.package.homepage // ""')"

    # export CARGO_CFG_TARGET_ARCH=
    # export CARGO_CFG_TARGET_OS=
    # export CARGO_CFG_TARGET_FAMILY=
    # export CARGO_CFG_UNIX=
    # export CARGO_CFG_TARGET_ENV=
    # export CARGO_CFG_TARGET_ENDIAN=
    # export CARGO_CFG_TARGET_POINTER_WIDTH=
    # export CARGO_CFG_TARGET_VENDOR=

    export HOST="$rustBuildTarget"
    export TARGET="$rustHostTarget"
    export PROFILE=release
    export DEBUG=0
    export OPT_LEVEL=3
    export NUM_JOBS=$NIX_BUILD_CORES
    export RUSTC="$RUSTC"
    # export RUSTDOC="rustdoc"
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([A-Za-z0-9.-]+))?(\+.*)?$ ]]; then
        export CARGO_PKG_VERSION_MAJOR="${BASH_REMATCH[0]}"
        export CARGO_PKG_VERSION_MINOR="${BASH_REMATCH[1]}"
        export CARGO_PKG_VERSION_PATCH="${BASH_REMATCH[2]}"
        export CARGO_PKG_VERSION_PRE="${BASH_REMATCH[4]}"
    else
        echo "Invalid version: $version"
    fi

    # Features. Also enabled for build script.
    for feat in $features; do
        commonBuildFlagsArray+=(--cfg "feature=\"$feat\"")
    done

    # Dependencies.
    addExternFlags buildFlagsArray $dependencies

    if [[ -n "$libSrc" ]]; then
        libCrateType="$(jq --raw-output '.lib."crate-type" // ["lib"] | join(",")' Cargo.toml.json)"
        if [[ "$(jq --raw-output '.lib."proc-macro" // false' Cargo.toml.json)" == true ]]; then
            libCrateType="proc-macro"
        fi

        # Place transitive dependencies (symlinks) in a single directory.
        depsClosure=$dev/nix-support/rust-deps-closure
        mkdir -p $depsClosure
        for dep in $dependencies; do
            local name libPrefix closure
            IFS=: read name libPrefix closure <<<"$dep"
            cp --no-dereference -t $depsClosure $closure/* 2>/dev/null || true
            ln -st $depsClosure $(dirname $libPrefix)/* 2>/dev/null || true
        done
    fi

    if [[ -n "$buildRs" ]]; then
        buildScriptDir="$(mktemp -d)"
        buildOutDir="$buildScriptDir/out"
        mkdir -p "$buildOutDir"

        runBuildRustc "Building build script" \
            "$buildRs" \
            --out-dir "$buildScriptDir" \
            --crate-name "build_script_build" \
            --crate-type bin \
            "${commonBuildFlagsArray[@]}" \
            "${buildBuildFlagsArray[@]}"

        echo "Running build script"
        (
            export RUSTC_BACKTRACE=1
            export OUT_DIR="$buildOutDir"
            for feat in $features; do
                export "CARGO_FEATURE_${feat//-/_}"=1
            done
            "$buildScriptDir/build_script_build" | tee "$buildScriptDir/output"
        )

        # https://doc.rust-lang.org/cargo/reference/build-scripts.html#outputs-of-the-build-script
        local line
        while read -r line; do
            local rhs="${line#*=}"
            case "$line" in
                cargo:rerun-if-changed=*|cargo:rerun-if-env-changed=*)
                    ;;
                cargo:rustc-link-lib=*)
                    buildFlagsArray+=( -l "$rhs" )
                    ;;
                cargo:rustc-link-search=*)
                    buildFlagsArray+=( -L "$rhs" )
                    ;;
                cargo:rustc-flags=*)
                    local i arg arr=( $rhs )
                    for (( i = 0; i < ${#arr[@]}; i++ )); do
                        arg="${arr[i]}"
                        if [[ "$arg" = -l || "$arg" = -L ]]; then
                            buildFlagsArray+=( "$arg" "${arr[i + 1]}" )
                            (( i++ ))
                        elif [[ "$arg" = -l* || "$arg" = -L* ]]; then
                            buildFlagsArray+=( "$arg" )
                        else
                            echo "Only -l and -L are allowed from build script: $line"
                            exit 1
                        fi
                    done
                    ;;
                cargo:rustc-cfg=*)
                    if [[ "$rhs" = *=* ]]; then
                        buildFlagsArray+=(--cfg "${rhs%%=*}=\"${rhs#*=}\"")
                    else
                        buildFlagsArray+=(--cfg "$rhs")
                    fi
                    ;;
                cargo:rustc-env=*)
                    local k="${rhs%%=*}" v="${rhs#*=}"
                    eval 'export '"$k"'="$v"'
                    ;;
                cargo:rustc-cdylib-link-arg=*)
                    echo "Not supported yet: $line"
                    exit 1
                    ;;
                cargo:warning=*)
                    echo "Warning (from build script): $rhs"
                    ;;
                cargo:*)
                    echo "Not supported yet: $line"
                    exit 1
                    ;;
                *)
                    echo "Warning: Unknown line from build script: $line"
            esac
        done <"$buildScriptDir/output"
    fi

    runHook postConfigure
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
            "${commonBuildFlagsArray[@]}" \
            "${buildFlagsArray[@]}"
    fi

    runHook postBuild
}

genericBuild
