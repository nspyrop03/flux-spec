#!/bin/bash -l

#SBATCH --job-name=test-workload
#SBATCH --output=/p/home/jusers/%u/jusuf/flux-spec/runs/%x-%j.out
#SBATCH --error=/p/home/jusers/%u/jusuf/flux-spec/runs/%x-%j.err
# #SBATCH --nodes=17
# #SBATCH --ntasks=2176

#SBATCH --nodes=3
#SBATCH --ntasks=384
#SBATCH --time=00:30:00

#SBATCH --threads-per-core=1
# #SBATCH --time=07:10:00
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
cores_per_node=$((2 * 4 * 2 * 8))

run_variant() {
    local suffix="$1"
    shift
    local workload_dir="$FLUX_SPEC_DIR/workload_${SLURM_JOB_ID:?}${suffix}"
    local output_file="$FLUX_SPEC_DIR/output_${SLURM_JOB_ID}${suffix}.csv"

    printf '\nStarting workload %s%s\n' "$SLURM_JOB_ID" "$suffix"

    python3 "$FLUX_SPEC_DIR/edit_flux_config.py" \
        "$FLUX_SPEC_DIR/config-flux/flux-config-cosched.toml" \
        "$workload_dir" "$@" || return

    # If we want a different resource_type co-scheduling, we may have to change the JGF graph given to flux
    python3 "$SHARED_FLURM_DIR/jgf_gen.py" \
        --nodes "$hostlist" \
        --set socket=2 --set numanode=4 --set core=16 \
        -o "$workload_dir/aris.json" || return

    flux R encode -H "$hostlist" -c "0-$((cores_per_node - 1))" \
        > "$workload_dir/R" || return

    srun -N "$SLURM_JOB_NUM_NODES" -n "$SLURM_JOB_NUM_NODES" \
        --mpi=pmi2 --cpu-bind=none --export=ALL \
        flux start -o --config-path="$workload_dir/flux-config-cosched.toml" \
        python3 "$FLUX_SPEC_DIR/replay_workload.py" \
        "$INPUT_FILE" "$SPEC_CFG" "$workload_dir" "$output_file"
}

if [[ ${1:-} != --experiment ]]; then
    run_variant "" "$@"
    exit
fi

if (( $# != 1 )); then
    echo "--experiment takes no additional scheduling flags" >&2
    exit 2
fi

experiment_status=0
run_variant "_compact" --compact || experiment_status=1

for n_way in 2 4 8; do
    sleep 30
    run_variant "_nway${n_way}" --n_way "$n_way" --resource_type numanode \
        || experiment_status=1
done

exit "$experiment_status"