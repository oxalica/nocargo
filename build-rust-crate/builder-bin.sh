source $stdenv/setup
source $builderCommon

declare -A buildFlagsMap

dontInstall=1

addBin() {
    local name="$1" path="$2" binEdition="$3"
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
    binsStr="$(jq --raw-output '.bin // [] | .[] | .name // "", .path // "", .edition // ""' "$cargoTomlJson")"
    if [[ -n "$autoDiscovery" ]]; then
        if [[ -f src/main.rs ]]; then
            printf -v binsStr '%s%s\n%s\n%s\n' "$binsStr" "$pkgName" src/main.rs ""
        fi

        local f name
        for f in src/bin/*; do
            name="${f##*/}"
            if [[ "$f" = *.rs && -f "$f" ]]; then
                printf -v binsStr '%s%s\n%s\n%s\n' "$binsStr" "${name%.rs}" "$f" ""
            elif [[ -f "$f/main.rs" ]]; then
                printf -v binsStr '%s%s\n%s\n%s\n' "$binsStr" "$name" "$f/main.rs" ""
            fi
        done
    fi

    local name path binEdition
    local -a pathCandidates
    while read -r name; do
        read -r path
        read -r binEdition

        if [[ -z "$name" ]]; then
            echo "Name of binary target '$name' must be specified"
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
                echo "Cannot guess path of binary target '$name'"
                exit 1
                ;;
            1)
                addBin "$name" "$path" "$binEdition"
                ;;
            *)
                echo "Ambiguous binary target '$name', candidate paths: ${pathCandidates[*]}"
                exit 1
                ;;
        esac
    done < <(printf "%s" "$binsStr") # Avoid trailing newline.

    if [[ ${#buildFlagsMap[@]} = 0 ]]; then
        echo "No binaries to be built"
        mkdir $out
        exit 0
    fi
    echo "Binaries to be built: ${!buildFlagsMap[*]}"

    # Implicitly link library of current crate, if exists.
    local libName="lib$crateName-$rustcMeta"
    if [[ -e "$libDrv/lib/$libName$sharedLibraryExt" ]]; then
        buildFlagsArray+=(--extern "$crateName=$libDrv/lib/$libName$sharedLibraryExt")
    elif [[ -e "$libDrv/lib/$libName.rlib" ]]; then
        buildFlagsArray+=(--extern "$crateName=$libDrv/lib/$libName.rlib")
    fi

    # Actually unused.
    declare -a cdylibBuildFlagsArray

    addExternFlags buildFlagsArray link $dependencies
    addFeatures buildFlagsArray $features
    importBuildOut buildFlagsArray cdylibBuildFlagsArray "$buildOutDrv"
    setCargoCommonBuildEnv

    depsClosure="$(mktemp -d)"
    collectTransDeps "$depsClosure" $dependencies
    buildFlagsArray+=(-L "dependency=$depsClosure")

    runHook postConfigure
}

buildPhase() {
    runHook preBuild

    mkdir -p $out/bin

    local binName
    for binName in "${!buildFlagsMap[@]}"; do
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
