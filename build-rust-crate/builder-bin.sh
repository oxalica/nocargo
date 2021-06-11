source $stdenv/setup
source $builderCommon

declare -A buildFlagsMap

dontInstall=1

addBin() {
    local name="$1" path="$2" binEdition="$3"
    # TODO: Other flags.
    buildFlagsMap["$name"]="$path --crate-name ${name//-/_} -C metadata=$rustcMeta-$name"
    if [[ -n "${binEdition:=$edition}" ]]; then
        buildFlagsMap["$name"]+=" --edition $binEdition"
    fi
}

configurePhase() {
    runHook preConfigure

    convertCargoToml

    edition="$(jq --raw-output '.package.edition // ""' "$cargoTomlJson")"
    pkgName="$(jq --raw-output '.package.name // ""' "$cargoTomlJson")"

    local name path
    while read -r name; do
        read -r path
        read -r binEdition
        if [[ -z "$name" ]]; then
            echo "Name of binary target '$name' must be specified"
            exit 1
        fi
        if [[ -z "$path" ]]; then
            if [[ "$name" == "$pkgName" ]]; then
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
        addBin "$name" "$path" "$binEdition"
    done < <(jq --raw-output '.bin // [] | .[] | .name, .path, .edition' "$cargoTomlJson")

    local autobins
    autobins="$(jq '.package.autobins' "$cargoTomlJson")"
    if [[ "$autobins" != false && ( "${edition:-2015}" != 2015 || ${#buildFlagsMap[@]} = 0 ) ]]; then
        if [[ -z "${buildFlagsMap["$pkgName"]}" && -f src/main.rs ]]; then
            addBin "$pkgName" src/main.rs
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
            if [[ -n "$path" && -z "${buildFlagsMap["$name"]}" ]]; then
                addBin "$name" "$path"
            fi
        done
    fi

    if [[ ${#buildFlagsMap[@]} = 0 ]]; then
        echo "No binaries to be built"
        mkdir $out
        exit 0
    fi

    # Implicitly link library of current crate, if exists.
    local libName="lib$crateName-$rustcMeta"
    if [[ -e "$libDrv/lib/$libName$sharedLibraryExt" ]]; then
        buildFlagsArray+=(--extern "$crateName=$libDrv/lib/$libName$sharedLibraryExt")
    elif [[ -e "$libDrv/lib/$libName.rlib" ]]; then
        buildFlagsArray+=(--extern "$crateName=$libDrv/lib/$libName.rlib")
    fi

    addExternFlags buildFlagsArray $dependencies
    addFeatures buildFlagsArray $features
    importBuildOut buildFlagsArray "$buildOutDrv"
    setCargoCommonBuildEnv

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
