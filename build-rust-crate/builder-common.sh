declare -a buildFlagsArray
buildFlagsArray+=( --color=always )

# Collect all transitive dependencies (symlinks).
collectTransDeps() {
    local collectDir="$1" line rename depOut depDev
    mkdir -p "$collectDir"
    shift
    for line in "$@"; do
        IFS=: read -r rename depOut depDev <<<"$line"
        # May be empty.
        cp --no-dereference --no-clobber -t $collectDir $depDev/rust-support/deps-closure/* 2>/dev/null || true
    done
}

addExternFlags() {
    local var="$1" kind="$2" line rename depOut depDev paths
    shift 2
    for line in "$@"; do
        IFS=: read -r rename depOut depDev <<<"$line"

        if [[ -e "$depDev/rust-support/is-proc-macro" ]]; then
            paths=("$depOut"/lib/*"$sharedLibraryExt")
        elif [[ "$kind" == meta ]]; then
            paths=("$depDev"/lib/*.rmeta)
        else
            # FIXME: Currently we only link rlib.
            paths=("$depOut"/lib/*.rlib)
        fi

        if (( ${#paths[@]} == 0 )); then
            echo "No dependent library found for $line"
            exit 1
        elif (( ${#paths[@]} > 1 )); then
            echo "Multiple candidate found for dependent library $line, found: ${paths[*]}"
            exit 1
        fi
        if [[ -z "$rename" ]]; then
            if [[ "${paths[0]##*/}" =~ ^lib(.*)(-.*)(\.rmeta|\.rlib|"$sharedLibraryExt")$ ]]; then
                rename="${BASH_REMATCH[1]}"
            else
                echo "Invalid library name: ${paths[0]}"
                exit 1
            fi
        fi
        eval "$var"'+=(--extern="$rename=${paths[0]}")'
    done
}

addFeatures() {
    local var="$1" feat
    shift
    for feat in "$@"; do
        eval "$var"'+=(--cfg="feature=\"$feat\"")'
    done
}

importBuildOut() {
    local var="$1" cvar="$2" drv="$3" flags
    [[ ! -e "$drv/rust-support/build-stdout" ]] && return

    echo export OUT_DIR="$drv/rust-support/out-dir"
    export OUT_DIR="$drv/rust-support/out-dir"

    if [[ -e "$drv/rust-support/rustc-env" ]]; then
        cat "$drv/rust-support/rustc-env"
        source "$drv/rust-support/rustc-env"
    fi

    if [[ -e "$drv/rust-support/rustc-flags" ]]; then
        mapfile -t flags <"$drv/rust-support/rustc-flags"
        eval "$var"'+=("${flags[@]}")'
    fi

    if [[ -e "$drv/rust-support/rustc-cdylib-flags" ]]; then
        mapfile -t flags <"$drv/rust-support/rustc-cdylib-flags"
        eval "$cvar"'+=("${flags[@]}")'
    fi
}

runRustc() {
    local msg="$1"
    shift
    echo "$msg: RUSTC ${*@Q}"
    $RUSTC "$@"
}

convertCargoToml() {
    local cargoToml="${1:-"$(pwd)/Cargo.toml"}"
    cargoTomlJson="$(mktemp "$(dirname "$cargoToml")/Cargo.json.XXX")"
    toml2json <"$cargoToml" >"$cargoTomlJson"
}

# https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-crates
setCargoCommonBuildEnv() {
    # CARGO_CRATE_NAME is set outside since targets have individual crate names.

    # export CARGO=
    CARGO_MANIFEST_DIR="$(dirname "$cargoTomlJson")"
    export CARGO_MANIFEST_DIR

    CARGO_PKG_NAME="$(jq --raw-output '.package.name // ""' "$cargoTomlJson")"
    CARGO_PKG_VERSION="$(jq --raw-output '.package.version // ""' "$cargoTomlJson")"
    if [[ -z "CARGO_PKG_NAME" ]]; then
        echo "Package name must be set"
        exit 1
    fi
    if [[ -z "CARGO_PKG_VERSION" ]]; then
        echo "Package version must be set"
        exit 1
    fi

    CARGO_PKG_AUTHORS="$(jq --raw-output '.package.authors // [] | join(":")' "$cargoTomlJson")"
    CARGO_PKG_DESCRIPTION="$(jq --raw-output '.package.description // ""' "$cargoTomlJson")"
    CARGO_PKG_HOMEPAGE="$(jq --raw-output '.package.homepage // ""' "$cargoTomlJson")"
    CARGO_PKG_LICENSE="$(jq --raw-output '.package.license // ""' "$cargoTomlJson")"
    CARGO_PKG_LICENSE_FILE="$(jq --raw-output '.package."license-file" // ""' "$cargoTomlJson")"
    export CARGO_PKG_NAME CARGO_PKG_VERSION CARGO_PKG_AUTHORS CARGO_PKG_DESCRIPTION \
        CARGO_PKG_HOMEPAGE CARGO_PKG_LICENSE CARGO_PKG_LICENSE_FILE

    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([A-Za-z0-9.-]+))?(\+.*)?$ ]]; then
        export CARGO_PKG_VERSION_MAJOR="${BASH_REMATCH[0]}"
        export CARGO_PKG_VERSION_MINOR="${BASH_REMATCH[1]}"
        export CARGO_PKG_VERSION_PATCH="${BASH_REMATCH[2]}"
        export CARGO_PKG_VERSION_PRE="${BASH_REMATCH[4]}"
    else
        echo "Invalid version: $version"
    fi
}
