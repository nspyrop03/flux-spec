#!/bin/bash
set -euo pipefail

config=$1
job_dir=$2
app=$3
procs=$4
shift 4

spec_output="$job_dir/spec"
binary_root="${SPECHPC_BINARY_ROOT:?SPECHPC_BINARY_ROOT is required}"
source_exe="$binary_root/benchspec/HPC/$app/exe"
target_dir="$spec_output/benchspec/HPC/$app"

if [[ ! -d "$source_exe" ]]; then
    printf 'Prebuilt executable directory missing: %s\n' "$source_exe" >&2
    exit 1
fi

mkdir -p -- "$target_dir"
ln -s -- "$source_exe" "$target_dir/exe"

export OMP_NUM_THREADS=1

# Set benchmark-specific environment variables here
for assignment in "$@"; do
    export -- "$assignment"
    name=${assignment%%=*}
    printf 'Row environment: %s=%q\n' "$name" "${!name}"
done

exec runhpc \
    --config="$config" \
    --action=validate \
    --noreportable \
    --nobuild \
    --tune=base \
    --iterations=1 \
    --threads=1 \
    --size="${SPECHPC_SIZE:-ref}" \
    --ranks="$procs" \
    --output_root="$spec_output" \
    "$app"
