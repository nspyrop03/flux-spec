#!/bin/bash -l

# #SBATCH --job-name=workload_type_A
#SBATCH --job-name=testing

#SBATCH --output=/p/project1/seanergys/spyropoulos1/experiments/%x-%j.out
#SBATCH --error=/p/project1/seanergys/spyropoulos1/experiments/%x-%j.err

# #SBATCH --nodes=17
# #SBATCH --ntasks=2176
# #SBATCH --time=04:30:00

#SBATCH --nodes=3
#SBATCH --ntasks=384
#SBATCH --time=00:10:00

#SBATCH --threads-per-core=1
#SBATCH --partition=batch
#SBATCH --account=seanergys
#SBATCH --exclusive
#SBATCH --disable-turbomode

set -eo pipefail

ulimit -s unlimited
ulimit -l unlimited

if (( $# < 1 )); then
    echo "Usage: sbatch submit_workload.sh INPUT.csv [--compact] [--n_way N] [--resource_type TYPE] [--waste_threshold X] [--experiment]" >&2
    exit 2
fi

INPUT_FILE="$(realpath -e -- "$1")"
shift

experiment_mode=false
compact_mode=false
n_way=""
waste_threshold=""
resource_type="numanode"
extra_args=()

while (( $# > 0 )); do
    case "$1" in
        --experiment)
            experiment_mode=true
            shift
            ;;
        --compact)
            compact_mode=true
            shift
            ;;
        --n_way)
            if (( $# < 2 )); then
                echo "Error: --n_way requires a value" >&2
                exit 2
            fi
            n_way="$2"
            shift 2
            ;;
        --waste_threshold)
            if (( $# < 2 )); then
                echo "Error: --waste_threshold requires a value" >&2
                exit 2
            fi
            waste_threshold="$2"
            shift 2
            ;;
        --resource_type)
            if (( $# < 2 )); then
                echo "Error: --resource_type requires a value" >&2
                exit 2
            fi
            resource_type="$2"
            shift 2
            ;;
        *)
            extra_args+=("$1")
            shift
            ;;
    esac
done

if [[ "$resource_type" != "numanode" && "$resource_type" != "ccx" ]]; then
    echo "Error: --resource_type must be 'numanode' or 'ccx' (got '$resource_type')" >&2
    exit 2
fi

module purge

# Dependency hell resolved (I hope so)
module load GCC/14.3.0
module load OpenMPI/5.0.8
module load git/2.50.1
module load Python/3.13.5

: "${PROJECT_seanergys:?PROJECT_seanergys is not set}"
: "${USER:?USER is not set}"

FLUX_SPEC_DIR="$HOME/flux-spec"
SHARED_FLURM_DIR="$PROJECT_seanergys/spyropoulos1/flurm"

EXPERIMENTS_DIR="/p/project1/seanergys/$USER/experiments/$SLURM_JOB_ID"
mkdir -p "$EXPERIMENTS_DIR"

SPEC_CFG="$PROJECT_seanergys/spyropoulos1/spechpc-builds-gcc/flux_spec_gcc-build-905594.cfg"
SPEC_ROOT="$PROJECT_seanergys/triantafyllis1/spechpc"
export SPECHPC_BINARY_ROOT="${SPECHPC_BINARY_ROOT:-$PROJECT_seanergys/spyropoulos1/spechpc-builds-gcc}"

export SPACK_PYTHON="$(command -v python3)"
export OMP_NUM_THREADS=1

source "$PROJECT_seanergys/spyropoulos1/flurm/load-custom-runtime.sh"
source "$PROJECT_seanergys/spyropoulos1/flurm/load-pmix-runtime.sh"

pushd "$SPEC_ROOT" >/dev/null
source ./shrc
popd >/dev/null

export LD_LIBRARY_PATH="$SPEC_ROOT/compat/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$FLUX_SPEC_DIR:$PATH"

test -r "$FLUX_SPEC_DIR/run_spec_row.sh"
command -v flux
command -v runhpc
flux version

host_lines="$(scontrol show hostnames "${SLURM_NODELIST:?}")"
mapfile -t hosts <<< "$host_lines"

if (( ${#hosts[@]} < 2 )); then
    echo "Need at least two nodes: one control node and one compute node" >&2
    exit 2
fi

export CONTROL_NODE="${hosts[0]}"
printf 'Control node: %s\n' "$CONTROL_NODE"
printf 'Compute node: %s\n' "${hosts[@]:1}"

hostlist="$(IFS=,; echo "${hosts[*]}")"
cores_per_node=$((2 * 4 * 16))

build_common_variant_args() {
    local -n out_args=$1

    out_args=()
    if [[ "$compact_mode" == true ]]; then
        out_args+=(--compact)
    fi
    if [[ -n "$n_way" ]]; then
        out_args+=(--n_way "$n_way")
    fi
    if [[ -n "$waste_threshold" ]]; then
        out_args+=(--waste_threshold "$waste_threshold")
    fi
    if (( ${#extra_args[@]} > 0 )); then
        out_args+=("${extra_args[@]}")
    fi
    out_args+=(--resource_type "numanode")
}

run_variant() {
    local suffix="$1"
    shift

    local workload_dir="$EXPERIMENTS_DIR/workload_${SLURM_JOB_ID:?}${suffix}"
    local output_file="$EXPERIMENTS_DIR/output_${SLURM_JOB_ID}${suffix}.csv"

    printf '\nStarting workload %s%s\n' "$SLURM_JOB_ID" "$suffix"

    python3 "$FLUX_SPEC_DIR/edit_flux_config.py" \
        "$FLUX_SPEC_DIR/config-flux/flux-config-cosched.toml" \
        "$workload_dir" "$@" || return

    # Build JGF arguments based on resource_type
    local jgf_args=(
        --nodes "$hostlist"
        --set socket=2
    )

    if [[ "$resource_type" == "ccx" ]]; then
        jgf_args+=(
            --set numanode=16
            --set core=4
        )
    else
        jgf_args+=(
            --set numanode=4
            --set core=16
        )
    fi

    python3 "$SHARED_FLURM_DIR/jgf_gen.py" \
        "${jgf_args[@]}" \
        -o "$workload_dir/aris.json" || return

    flux R encode -H "$hostlist" -c "0-$((cores_per_node - 1))" \
        > "$workload_dir/R" || return

    unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK SRUN_EXACT
    srun -N "$SLURM_JOB_NUM_NODES" -n "$SLURM_JOB_NUM_NODES" \
        --mpi=pmi2 --cpu-bind=none --export=ALL \
        flux start -o --config-path="$workload_dir/flux-config-cosched.toml" \
        python3 "$FLUX_SPEC_DIR/replay_workload.py" \
        "$INPUT_FILE" "$SPEC_CFG" "$workload_dir" "$output_file"
}

# Experiment modes take precedence over all other workload arguments
if [[ "$experiment_mode" == false ]]; then
    variant_args=()
    build_common_variant_args variant_args
    run_variant "" "${variant_args[@]}"
    exit $?
fi

experiment_status=0
echo "[DEBUG] Experiment mode enabled"
echo "[DEBUG] Resource type (JGF graph): $resource_type"

extra_exp_args=()
if [[ -n "$waste_threshold" ]]; then
    extra_exp_args+=(--waste_threshold "$waste_threshold")
fi
if (( ${#extra_args[@]} > 0 )); then
    extra_exp_args+=("${extra_args[@]}")
fi

# Compact experiment
run_variant "_compact" \
    --compact \
    "${extra_exp_args[@]}" \
    --resource_type "numanode" \
    || experiment_status=1

# N-way experiments
for exp_n_way in 2 4 8; do
    sleep 30

    run_variant "_nway${exp_n_way}" \
        --n_way "$exp_n_way" \
        "${extra_exp_args[@]}" \
        --resource_type "numanode" \
        || experiment_status=1
done

exit "$experiment_status"
