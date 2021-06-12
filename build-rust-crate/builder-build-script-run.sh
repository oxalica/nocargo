source $stdenv/setup

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

    CARGO_MANIFEST_DIR="$(pwd)"
    export CARGO_MANIFEST_DIR
    export CARGO_MANIFEST_LINKS="$links"

    for feat in $features; do
        export "CARGO_FEATURE_${feat//-/_}"=1
    done

    export OUT_DIR="$out/rust-support/out-dir"
    export NUM_JOBS=$NIX_BUILD_CORES
    export OPT_LEVEL="${optLevel:-}"
    export DEBUG="${debug:-}"
    export PROFILE="$profile"

    export RUSTC_BACKTRACE=1 # Make debugging easier.

    local buildOut
    for buildOut in $linksDependencies; do
        if [[ -e "$buildOut/rust-support/dependent-meta" ]]; then
            source "$buildOut/rust-support/dependent-meta"
        fi
    done

    # Other flags are set outside.
    # - CARGO_CFG_<cfg>
    # - HOST
    # - TARGET
    # - RUSTC
    # - CARGO
    # - RUSTDOC

    mkdir -p "$out/rust-support" "$OUT_DIR"

    runHook postConfigure
}

runPhase() {
    runHook preRun
    echo "Running build script"
    stdoutFile="$out/rust-support/build-stdout"
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
                if [[ -z "$rhs" ]]; then
                    echo "Empty link path: $line"
                    exit 1
                fi
                rustcFlags+=("-l$rhs")
                ;;
            cargo:rustc-link-search=*)
                if [[ -z "$rhs" ]]; then
                    echo "Empty link path: $line"
                    exit 1
                fi
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
                    if [[ -z "$path" ]]; then
                        echo "Empty link path: $line"
                        exit 1
                    fi
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
                if [[ -n "${links:-}" ]]; then
                    rhs="${line#*:}"
                    local k="DEP_${links}_${rhs%%=*}" v="${rhs#*=}"
                    k="${k^^}"
                    k="${k//-/_}"
                    dependentMeta+=("export ${k@Q}=${v@Q}")
                fi
                ;;
            cargo:*)
                echo "Unknown or wrong output line: $line"
                exit 1
                ;;
            *)
                ;;
        esac
    done <"$stdoutFile"

    sortTo "$out/rust-support/rerun-if-files" "${rustcFlags[@]}"
    sortTo "$out/rust-support/rustc-flags" "${rustcFlags[@]}"
    sortTo "$out/rust-support/rustc-envs" "${rustcEnvs[@]}"
    sortTo "$out/rust-support/cdylib-link-flags" "${cdylibLinkFlags[@]}"
    sortTo "$out/rust-support/dependent-meta" "${dependentMeta[@]}"

    runHook postInstall
}

sortTo() {
    local path="$1"
    shift
    if [[ $# = 0 ]]; then
        touch "$path"
    else
        ( IFS=$'\n'; sort -o "$path" <<<"$*" )
    fi
}

genericBuild
