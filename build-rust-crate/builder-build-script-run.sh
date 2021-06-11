source $stdenv/setup
source $builderCommon

buildScriptBin="$buildDrv/bin/build_script_build"
if [[ ! -e "$buildScriptBin" ]]; then
    echo "No build script to be run"
    mkdir -p $out
    exit 0
fi

dontPatch=1
dontBuild=1
dontFixup=1
preInstallPhases=runPhase

# https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-build-scripts
configurePhase() {
    runHook preConfigure

    convertCargoToml

    CARGO_MANIFEST_DIR="$(pwd)"
    CARGO_MANIFEST_LINKS="$(jq '.package.links // ""' "$cargoTomlJson")"
    export CARGO_MANIFEST_DIR CARGO_MANIFEST_LINKS

    for feat in $features; do
        export "CARGO_FEATURE_${feat//-/_}"=1
    done

    export OUT_DIR="$out/rust-support/out"
    export NUM_JOBS=$NIX_BUILD_CORES
    export RUSTC_BACKTRACE=1 # Make debugging easier.

    local line name binName depOut depDev
    for line in $dependencies; do
        IFS=: read -r name binName depOut depDev <<<"$line"
        if [[ -e "$depDev/rust-support/dependent-meta" ]]; then
            source "$depDev/rust-support/dependent-meta"
        fi
    done

    # Other flags are set outside.
    # - CARGO_CFG_<cfg>
    # - PROFILE
    # - DEBUG
    # - OPT_LEVEL
    # - HOST
    # - TARGET
    # - RUSTC
    # - CARGO
    # - RUSTDOC

    runHook postConfigure
}

runPhase() {
    runHook preRun
    echo "Running build script"
    mkdir -p "$out/rust-support"
    stdoutFile="$out/rust-support/output"
    "$buildScriptBin" | tee "$stdoutFile"
    runHook postRun
}

installPhase() {
    runHook preInstall

    # https://doc.rust-lang.org/cargo/reference/build-scripts.html?highlight=build#outputs-of-the-build-script
    local line rhs
    local -a rerunIfFiles rustcFlags rustcEnvs cdylibLinkFlags dependentMeta
    while read -r line; do
        rhs="${line#*=}"
        case "$line" in
            cargo:rerun-if-env-changed=*)
                ;;
            cargo:rerun-if-changed=*)
                rerunIfFiles+=("$rhs")
                ;;
            cargo:rustc-link-lib=*)
                [[ -z "$rhs" ]] || { echo "Empty link path: $line"; exit 1; }
                rustcFlags+=("$rhs")
                ;;
            cargo:rustc-link-search=*)
                [[ -z "$rhs" ]] || { echo "Empty link path: $line"; exit 1; }
                rustcFlags+=("-L$rhs")
                ;;
            cargo:rustc-flags=*)
                local flags i flag path
                read -r -a flags <<<"$rhs"
                for (( i = 0; i < ${#flags[@]}; i++ )); do
                    flag="${flags[i]}"
                    if [[ "$flag" = -l || "$flag" = -L ]]; then
                        path="${flags[i + 1]}"
                        (( i++ ))
                    elif [[ "$flag" = -l* || "$flag" = -L* ]]; then
                        path="${flag:2}"
                        flag="${flag:0:2}"
                    else
                        echo "Only -l and -L are allowed from build script: $line"
                        exit 1
                    fi
                    [[ -z "$path" ]] || { echo "Empty link path: $line"; exit 1; }
                    rustcFlags+=("$flag$path")
                done
                ;;
            cargo:rustc-cfg=*)
                rustcFlags+=("--cfg=$rhs")
                ;;
            cargo:rustc-env=*=*)
                local k="${rhs%%=*}" v="${rhs#*=}"
                rustcEnvs+=("export ${k@Q}=${v@Q}")
                ;;
            cargo:rustc-cdylib-link-arg=*)
                cdylibLinkFlags+=("-Clink-arg=$rhs")
                ;;
            cargo:warning=*)
                printf "\033[0;1;33mWarning from build script\033[0m: %s" "$rhs"
                ;;
            cargo:*=*)
                if [[ -n "${linksNameShoutCase:-}" ]]; then
                    local k="${rhs%%=*}" v="${rhs#*=}"
                    dependentMeta+=("export DEP_${linksNameShoutCase}_${k@Q}=${v@Q}")
                fi
                ;;
            *)
                ;;
        esac
    done <"$stdoutFile"

    (
        IFS=$'\n'
        # Order of paths may be non deterministic due to filesystem impl. Sort them first.
        printf "%s" "${rerunIfFiles[*]}" | sort -o "$out/rust-support/rerun-if-files"
        # Flags and env vars may be positional. Keep the order.
        printf "%s" "${rustcFlags[*]}" >"$out/rust-support/rustc-flags"
        printf "%s" "${rustcEnvs[*]}" >"$out/rust-support/rustc-envs"
        printf "%s" "${cdylibLinkFlags[*]}" >"$out/rust-support/cdylib-link-flags"
        printf "%s" "${dependentMeta[*]}" >"$out/rust-support/dependent-meta"
    )

    runHook postInstall
}

genericBuild
