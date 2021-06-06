source $stdenv/setup
set -o pipefail
shopt -s nullglob

commonBuildFlagsArray=(
    --color=always
    -C opt-level=3
    -C incremental=no
    -C codegen-units=$NIX_BUILD_CORES
)

buildBuildFlagsArray=( -C metadata="$buildRustcMeta" )
libBuildFlagsArray=( -C metadata="$rustcMeta" )
binBuildFlagsArray=( -C metadata="$rustcMeta" )

declare -A binBuildFlagsMap

findLinkable() {
    if [[ -e "$1.rlib" ]]; then
        echo "$1.rlib"
    elif [[ -e "$1$sharedLibraryExt" ]]; then
        echo "$1$sharedLibraryExt"
    else
        echo "No linkable file found for $1"
        exit 1
    fi
}

addExternFlags() {
    local var="$1" kind="$2" dep name binName depOut depDev value
    shift 2
    for dep in "$@"; do
        IFS=: read name binName depOut depDev <<<"$dep"
        if [[ $kind == rmeta && -e $depDev/nix-support/rust-deps-closure/$binName.rmeta ]]; then
            value=$depDev/nix-support/rust-deps-closure/$binName.rmeta
        else
            value="$(findLinkable "$depOut/lib/$binName")"
        fi
        eval "$var+=(--extern $name=$value)"
        if [[ -e $depDev/nix-support/rust-deps-closure ]]; then
            eval "$var+=(-L dependency=$depDev/nix-support/rust-deps-closure)"
        fi
    done
}

collectTransDeps() {
    local collectDir="$1" dep name binName depOut depDev closureDir
    shift
    mkdir -p "$collectDir"
    for dep in "$@"; do
        IFS=: read name binName depOut depDev <<<"$dep"
        if [[ -e $depDev/nix-support/rust-deps-closure ]]; then
            find -P $depDev/nix-support/rust-deps-closure -type f -print0 |
                xargs -0 --no-run-if-empty -- ln -sft $collectDir 2>/dev/null || true
            find -P $depDev/nix-support/rust-deps-closure -type l -print0 |
                xargs -0 --no-run-if-empty -- cp --no-dereference --no-clobber -t $collectDir 2>/dev/null || true
        fi
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

configureBins() {
    local name path
    while read -r name; do
        read -r path
        if [[ -z "$name" ]]; then
            echo "Name of binary target '$name' must be specified"
            exit 1
        fi
        if [[ -z "$path" ]]; then
            if [[ "$name" == "$crateName" ]]; then
                path=src/main.rs
            elif [[ -f src/bin/$name.rs ]]; then
                path=src/bin/$name.rs
            elif [[ -d src/bin/$name ]]; then
                path=src/bin/$name/main.rs
            else
                echo "Failed to guess path of binary target '$name'"
                exit 1
            fi
        fi
        binBuildFlagsMap[$path]="$path --crate-name $name"
    done < <(jq --raw-output '.bin // [] | .[] | .name, .path' Cargo.toml.json)

    local autobins="$(jq '.package.autobins' Cargo.toml.json)"
    if [[ "$autobins" != false && ( "${edition:-2015}" != 2015 || $binCnt = 0 ) ]]; then
        if [[ -f src/main.rs ]]; then
            name="$crateName"
            path=src/main.rs
            binBuildFlagsMap[$path]="$path --crate-name $name"
        fi
        local f
        for f in src/bin/*; do
            path=
            if [[ "$f" = *.rs && -f "$f" ]]; then
                name="${f%.rs}"
                path="$f"
            elif [[ -d "$f" && -e "$f/main.rs" ]]; then
                name="$(basename "$f")"
                path="$f/main.rs"
            fi
            if [[ -n "$path" && -z "${registerdPaths[$path]}" ]]; then
                binBuildFlagsMap[$path]="$path --crate-name $name"
            fi
        done
    fi

    addExternFlags binBuildFlagsArray lib $dependencies
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
        addExternFlags buildBuildFlagsArray lib $buildDependencies
    fi

    libSrc="$(jq --raw-output '.lib.path // ""' Cargo.toml.json)"
    if [[ -z "$libSrc" && -e src/lib.rs ]]; then
        libSrc=src/lib.rs
    fi

    if [[ -n "$buildBins" ]]; then
        configureBins
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

    if [[ -n "$libSrc" ]]; then
        libCrateType="$(jq --raw-output '.lib."crate-type" // ["lib"] | join(",")' Cargo.toml.json)"
        if [[ "$(jq --raw-output '.lib."proc-macro"' Cargo.toml.json)" == true ]]; then
            libCrateType="proc-macro"
        fi

        # Dependencies.
        if [[ "$libCrateType" = *proc-macro* || "$libCrateType" = *dylib* ]]; then
            # OS libraries is already the final product and doesn't need rmeta (and should not have).
            addExternFlags libBuildFlagsArray lib $dependencies
        else
            libBuildFlagsArray+=(--emit metadata)
            addExternFlags libBuildFlagsArray rmeta $dependencies
            # Place transitive dependencies (symlinks) in a single directory.
            collectTransDeps $dev/nix-support/rust-deps-closure $dependencies
        fi
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
            --emit link \
            -C embed-bitcode=no \
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
                    commonBuildFlagsArray+=( -l "$rhs" )
                    ;;
                cargo:rustc-link-search=*)
                    commonBuildFlagsArray+=( -L "$rhs" )
                    ;;
                cargo:rustc-flags=*)
                    local i arg arr=( $rhs )
                    for (( i = 0; i < ${#arr[@]}; i++ )); do
                        arg="${arr[i]}"
                        if [[ "$arg" = -l || "$arg" = -L ]]; then
                            commonBuildFlagsArray+=( "$arg" "${arr[i + 1]}" )
                            (( i++ ))
                        elif [[ "$arg" = -l* || "$arg" = -L* ]]; then
                            commonBuildFlagsArray+=( "$arg" )
                        else
                            echo "Only -l and -L are allowed from build script: $line"
                            exit 1
                        fi
                    done
                    ;;
                cargo:rustc-cfg=*)
                    if [[ "$rhs" = *=* ]]; then
                        commonBuildFlagsArray+=(--cfg "${rhs%%=*}=\"${rhs#*=}\"")
                    else
                        commonBuildFlagsArray+=(--cfg "$rhs")
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

    if [[ -n "$libSrc" ]]; then
        mkdir -p $out/lib
        runRustc "Building lib" \
            "$libSrc" \
            --out-dir $out/lib \
            --crate-name "$crateName" \
            --crate-type "$libCrateType" \
            --emit=link \
            -C embed-bitcode=no \
            -C extra-filename="-$rustcMeta" \
            "${commonBuildFlagsArray[@]}" \
            "${libBuildFlagsArray[@]}"
    fi

    if (( ${#binBuildFlagsMap[@]} )); then
        local binName flags
        for binName in "${!binBuildFlagsMap[@]}"; do
            flags="${binBuildFlagsMap["$binName"]}"
            runRustc "Building binary $binName" \
                $flags \
                --crate-type bin \
                --out-dir $bin/bin \
                --extern "$crateName=$(findLinkable $out/lib/lib$crateName-$rustcMeta)" \
                "${commonBuildFlagsArray[@]}" \
                "${binBuildFlagsArray[@]}"
        done
    fi

    runHook postBuild
}

installPhase() {
    runHook preInstall
    mkdir -p $out $bin $dev/nix-support/rust-deps-closure
    if [[ -z "$isFinalProduct" ]]; then
        if [[ -n "$(echo $out/lib/*.rmeta)" ]]; then
            mv -ft $dev/nix-support/rust-deps-closure $out/lib/*.rmeta
        fi
        if [[ -n "$(echo $out/lib/*)" ]]; then
            ln -sft $dev/nix-support/rust-deps-closure $out/lib/*
        fi
        runHook postInstall
    fi
}

genericBuild
