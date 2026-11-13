#!/bin/bash
set -euo pipefail

: "${PROJECT_seanergys:?PROJECT_seanergys is not set}"
shared_spec="$PROJECT_seanergys/triantafyllis1/spechpc"
build_root="${SPECHPC_BUILD_ROOT:-$HOME/spechpc-builds-gcc}"

for app in 505.lbm_t 519.clvleaf_t 513.soma_t 521.miniswp_t 518.tealeaf_t; do
    source_exe="$shared_spec/benchspec/HPC/$app/exe"
    destination="$build_root/benchspec/HPC/$app/exe"

    if [[ ! -d "$source_exe" ]]; then
        printf 'Shared executable directory missing: %s\n' "$source_exe" >&2
        exit 1
    fi

    if [[ -L "$destination" && "$destination" -ef "$source_exe" ]]; then
        continue
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        printf 'Destination already exists: %s\n' "$destination" >&2
        exit 1
    fi

    mkdir -p -- "${destination%/*}"
    ln -sT -- "$source_exe" "$destination"
    printf '%s -> %s\n' "$destination" "$source_exe"
done
