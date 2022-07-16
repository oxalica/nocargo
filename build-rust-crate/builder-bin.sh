source $stdenv/setup
source $builderCommon

declare -A buildFlagsMap
declare -A binPathMap

dontInstall=1

addBin() {
    local name="$1" path="$2" binEdition="$3"
    local -a pathCandidates

    if [[ -z "$name" ]]; then
        echo "Name of the binary target is not specified"
        exit 1
    fi

    if [[ -n "$path" ]]; then
        pathCandidates=("$path")
    else
        pathCandidates=()
        if [[ -f "src/bin/$name.rs" ]]; then
            pathCandidates+=("src/bin/$name.rs")
        fi
        if [[ -f "src/bin/$name/main.rs" ]]; then
            pathCandidates+=("src/bin/$name/main.rs")
        fi
        if [[ "$name" == "$pkgName" && -f "src/main.rs" ]]; then
            pathCandidates+=("src/main.rs")
        fi
    fi

    case ${#pathCandidates[@]} in
        0)
            echo "Cannot guess path of binary target"
            exit 1
            ;;
        1)
            path="${pathCandidates[0]}"
            ;;
        *)
            echo "Ambiguous binary target, candidate paths: ${pathCandidates[*]}"
            exit 1
            ;;
    esac

    printf "Found binary %q at %q\n" "$name" "$path"
    binPathMap["$path"]=1

    # TODO: Other flags.
    buildFlagsMap["$name"]="$path --crate-name ${name//-/_} -C metadata=$rustcMeta-$name"
    if [[ -n "${binEdition:=$globalEdition}" ]]; then
        buildFlagsMap["$name"]+=" --edition $binEdition"
    fi
}

configurePhase() {
    runHook preConfigure

    convertCargoToml

    globalEdition="$(jq --raw-output '.package.edition // ""' "$cargoTomlJson")"
    pkgName="$(jq --raw-output '.package.name // ""' "$cargoTomlJson")"

    # For packages with the 2015 edition, the default for auto-discovery is false if at least one target is
    # manually defined in Cargo.toml. Beginning with the 2018 edition, the default is always true.
    # See: https://doc.rust-lang.org/cargo/reference/cargo-targets.html#target-auto-discovery
    autoDiscovery=
    if [[
        "$(jq --raw-output '.package.autobins' "$cargoTomlJson")" != false &&
        ( "${globalEdition:-2015}" != 2015 || ${#buildFlagsMap[@]} = 0 )
    ]]; then
        autoDiscovery=1
    fi

    local binsStr
    while read -r name; do
        read -r path
        read -r binEdition
        addBin "$name" "$path" "$binEdition"
        # Don't strip whitespace.
    done < <(jq --raw-output '.bin // [] | .[] | .name // "", .path // "", .edition // ""' "$cargoTomlJson")

    if [[ -n "$autoDiscovery" ]]; then
        if [[ -f src/main.rs && -z ${binPathMap[src/main.rs]} ]]; then
            addBin "$pkgName" src/main.rs ""
        fi
        local f name
        for f in src/bin/*; do
            name="${f##*/}"
            if [[ "$f" = *.rs && -f "$f" ]]; then
                [[ -n "${binPathMap["$f"]}" ]] || addBin "${name%.rs}" "$f" ""
            elif [[ -f "$f/main.rs" ]]; then
                [[ -n "${binPathMap["$f/main.rs"]}" ]] || addBin "$name" "$f/main.rs" ""
            fi
        done
    fi

    if [[ ${#buildFlagsMap[@]} = 0 ]]; then
        echo "No binaries to be built"
        mkdir $out
        exit 0
    fi

    # Implicitly link library of current crate, if exists.
    if [[ -e "$libDevDrv"/lib ]]; then
        addExternFlags buildFlagsArray link ":$libOutDrv:$libDevDrv"
    fi

    # Actually unused.
    declare -a cdylibBuildFlagsArray

    addExternFlags buildFlagsArray link $dependencies
    addFeatures buildFlagsArray $features
    importBuildOut buildFlagsArray cdylibBuildFlagsArray "$buildDrv"
    setCargoCommonBuildEnv

    depsClosure="$(mktemp -d)"
    collectTransDeps "$depsClosure" $dependencies
    buildFlagsArray+=(-Ldependency="$depsClosure")

    runHook postConfigure
}

buildPhase() {
    runHook preBuild

    mkdir -p $out/bin

    local binName
    for binName in "${!buildFlagsMap[@]}"; do
        export CARGO_CRATE_NAME="$binName"
        export CARGO_BIN_NAME="$binName"
        runRustc "Building binary $binName" \
            ${buildFlagsMap["$binName"]} \
            --crate-type bin \
            --out-dir $out/bin \
            "${buildFlagsArray[@]}"
    done

    runHook postBuild
}

genericBuild
