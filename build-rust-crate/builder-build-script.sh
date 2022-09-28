source $stdenv/setup
source $builderCommon
shopt -s nullglob

preInstallPhases+="runPhase "

buildFlagsArray+=( -Cmetadata="$rustcMeta" )

configurePhase() {
    runHook preConfigure

    convertCargoToml

    buildScriptSrc="$(jq --raw-output '.package.build // ""' "$cargoTomlJson")"
    if [[ -z "$buildScriptSrc" && -e build.rs ]]; then
        buildScriptSrc=build.rs
    elif [[ -z "$buildScriptSrc" ]]; then
        echo "No build script, doing nothing"
        mkdir -p $out
        exit 0
    fi

    edition="$(jq --raw-output '.package.edition // ""' "$cargoTomlJson")"
    if [[ -n "$edition" ]]; then
        buildFlagsArray+=(--edition="$edition")
    fi

    addFeatures buildFlagsArray $features
    addExternFlags buildFlagsArray link $dependencies
    setCargoCommonBuildEnv

    depsClosure="$(mktemp -d)"
    collectTransDeps "$depsClosure" $dependencies
    buildFlagsArray+=(-Ldependency="$depsClosure")

    runHook postConfigure
}

buildPhase() {
    runHook preBuild

    mkdir -p $out/bin

    runRustc "Building build script" \
        "$buildScriptSrc" \
        --out-dir="$out/bin" \
        --crate-name="build_script_build" \
        --crate-type=bin \
        --emit=link \
        -Cembed-bitcode=no \
        $buildScriptBuildFlags \
        "${buildFlagsArray[@]}"

    runHook postBuild
}

runPhase() {
    runHook preRun

    export CARGO_MANIFEST_DIR="$(pwd)"
    if [[ -n "$links" ]]; then
        export CARGO_MANIFEST_LINKS="$links"
    fi

    for feat in $features; do
        feat_uppercase="${feat^^}"
        export "CARGO_FEATURE_${feat_uppercase//-/_}"=1
    done

    export OUT_DIR="$out/rust-support/out-dir"
    export NUM_JOBS=$NIX_BUILD_CORES
    export RUSTC_BACKTRACE=1 # Make debugging easier.

    local buildOut
    for buildOut in $linksDependencies; do
        if [[ -e "$buildOut/rust-support/links-metadata" ]]; then
            source "$buildOut/rust-support/links-metadata"
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

    echo "Running build script"
    stdoutFile="$out/rust-support/build-stdout"
    "$out/bin/build_script_build" | tee "$stdoutFile"

    runHook postRun
}

installPhase() {
    runHook preInstall

    # https://doc.rust-lang.org/1.61.0/cargo/reference/build-scripts.html#outputs-of-the-build-script
    local line rhs
    while read -r line; do
        rhs="${line#*=}"
        case "$line" in
            cargo:rerun-if-changed=*|cargo:rerun-if-env-changed=*)
                # Ignored due to the sandbox.
                ;;
            cargo:rustc-link-arg=*)
                echo "-Clink-arg=$rhs" >>"$out/rust-support/rustc-link-args"
                ;;
            cargo:rustc-link-arg-bin=*)
                if [[ "$rhs" != *=* ]]; then
                    echo "Missing binary name: $line"
                    exit 1
                fi
                echo "-Clink-arg=${rhs%%=*}" >>"$out/rust-support/rustc-link-args-bin-${rhs#*=}"
                ;;
            cargo:rustc-link-arg-bins=*)
                echo "-Clink-arg=$rhs" >>"$out/rust-support/rustc-link-args-bins"
                ;;
            cargo:rustc-link-arg-tests=*)
                echo "-Clink-arg=$rhs" >>"$out/rust-support/rustc-link-args-tests"
                ;;
            cargo:rustc-link-arg-examples=*)
                echo "-Clink-arg=$rhs" >>"$out/rust-support/rustc-link-args-examples"
                ;;
            cargo:rustc-link-arg-benches=*)
                echo "-Clink-arg=$rhs" >>"$out/rust-support/rustc-link-args-benches"
                ;;
            cargo:rustc-link-lib=*)
                if [[ -z "$rhs" ]]; then
                    echo "Empty link path: $line"
                    exit 1
                fi
                echo "-l$rhs" >>"$out/rust-support/rustc-flags"
                ;;
            cargo:rustc-link-search=*)
                if [[ -z "$rhs" ]]; then
                    echo "Empty link path: $line"
                    exit 1
                fi
                echo "-L$rhs" >>"$out/rust-support/rustc-flags"
                ;;
            cargo:rustc-flags=*)
                local flags i flag
                read -r -a flags <<<"$rhs"
                for (( i = 0; i < ${#flags[@]}; i++ )); do
                    flag="${flags[i]}"
                    if [[ "$flag" = -[lL] ]]; then
                        (( i++ ))
                        flag+="${flags[i]}"
                    elif [[ "$flag" != -[lL]* ]]; then
                        echo "Only -l and -L are allowed from build script: $line"
                        exit 1
                    fi
                    if [[ ${#flag} == 2 ]]; then
                        echo "Empty link path: $line"
                        exit 1
                    fi
                    echo "$flag" >>"$out/rust-support/rustc-flags"
                done
                ;;
            cargo:rustc-cfg=*)
                echo "--cfg=$rhs" >>"$out/rust-support/rustc-flags"
                ;;
            cargo:rustc-env=*=*)
                printf 'export %q=%q\n' "${rhs%%=*}" "${rhs#*=}" >>"$out/rust-support/rustc-env"
                ;;
            cargo:rustc-cdylib-link-arg=*)
                echo "-Clink-arg=$rhs" >>"$out/rust-support/rustc-cdylib-flags"
                ;;
            cargo:warning=*)
                printf "\033[0;1;33mWarning\033[0m: %s\n" "$rhs"
                ;;
            cargo:*=*)
                if [[ -n "${links:-}" ]]; then
                    rhs="${line#*:}"
                    local k="DEP_${links}_${rhs%%=*}" v="${rhs#*=}"
                    k="${k^^}"
                    k="${k//-/_}"
                    printf 'export %q=%q\n' "$k" "$v" >>"$out/rust-support/links-metadata"
                else
                    printf "\033[0;1;33mWarning\033[0m: no 'links' defined in Cargo.toml, ignoring %s" "$line"
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

    local file
    for file in "$out"/rust-support/{rustc-*,links-metadata*}; do
        sort "$file" -o "$file"
    done

    runHook postInstall
}

genericBuild
