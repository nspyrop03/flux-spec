#!/bin/bash

set -eo pipefail

FLURM_DIR="$PROJECT_seanergys/$USER/flurm"

export SPACK_USER_CACHE_PATH="$FLURM_DIR/.spack"
export SPACK_USER_CONFIG_PATH="$FLURM_DIR/.spack"
export SPACK_STAGE="$FLURM_DIR/spack_stage"

source "$FLURM_DIR/spack/share/spack/setup-env.sh"

if [[ -n "${SPACK_ENV:-}" ]]; then
    spack env deactivate
fi

source "$PROJECT_seanergys/spyropoulos1/flurm/load-custom-runtime.sh"

spack repo list

CORE_HASH="$(spack find --format '{hash}' \
    'customflux.flux-core@=0.85.0-cosched%gcc@13')"

if [[ ! "$CORE_HASH" =~ ^[[:alnum:]]+$ ]]; then
    echo "Expected exactly one installed custom Flux core" >&2
    exit 1
fi

echo "Custom Flux hash: $CORE_HASH"
spack info flux-pmix

PMIX_SPEC="flux-pmix@0.7.1%gcc@13 ^/$CORE_HASH ^openmpi@5.0.8"

spack spec -Il "$PMIX_SPEC"
spack install "$PMIX_SPEC"

PMIX_PREFIX="$(spack location -i "$PMIX_SPEC")"
PMIX_RC_DIR="$PMIX_PREFIX/etc/flux/shell/lua.d"

if [[ ! -r "$PMIX_RC_DIR/pmix.lua" ]]; then
    echo "Missing PMIx activation file: $PMIX_RC_DIR/pmix.lua" >&2
    exit 1
fi

printf 'export FLUX_SHELL_RC_PATH=%q"${FLUX_SHELL_RC_PATH:+:$FLUX_SHELL_RC_PATH}"\n' \
    "$PMIX_RC_DIR" \
    > "$FLURM_DIR/load-pmix-runtime.sh"

printf 'PMIx installed at %s\n' "$PMIX_PREFIX"
printf 'Runtime loader written to %s/load-pmix-runtime.sh\n' "$FLURM_DIR"
