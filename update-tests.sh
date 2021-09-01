#!/usr/bin/env nix-shell
#!nix-shell -i bash -p jq
set -e
while read -r line; do
    if [[ "$line" =~ ^[A-Za-z0-9-]+"> *** Assert failed for file: ".*-source/(.*)$ ]]; then
        path="${BASH_REMATCH[1]}"
    else
        continue
    fi
    read -r line
    line="${line#*>}"
    echo "Updating $path"
    if [[ ! -f "$path" ]]; then
        echo "Not exist"
        exit 1
    fi
    jq . <<<"$line" >"$path"
done < <(nix flake check --keep-going -vL 2>&1 | tee /dev/stderr)
echo "Updated"
