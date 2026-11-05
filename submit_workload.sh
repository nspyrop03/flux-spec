#!/bin/bash -l

#SBATCH --job-name=flux-spec-workload
#SBATCH --output=/p/home/jusers/%u/jusuf/flux-spec/runs/%x-%j.out
#SBATCH --error=/p/home/jusers/%u/jusuf/flux-spec/runs/%x-%j.err
#SBATCH --nodes=2
#SBATCH --ntasks=256
#SBATCH --threads-per-core=1
#SBATCH --time=00:10:00
#SBATCH --partition=batch
#SBATCH --account=seanergys
#SBATCH --exclusive
#SBATCH --disable-turbomode

set -eo pipefail

ulimit -s unlimited
ulimit -l unlimited

if (( $# < 1 )); then
    echo "Usage: sbatch submit_workload.sh INPUT.csv [--n_way N] [--resource_type TYPE] [--waste_threshold X]" >&2
    exit 2
fi

INPUT_FILE="$(realpath -e -- "$1")"
shift

FLUX_SPEC_DIR="$HOME/flux-spec"
WORKLOAD_DIR="${FLUX_SPEC_DIR}/workload_${SLURM_JOB_ID:?}"
OUTPUT_FILE="${FLUX_SPEC_DIR}/output_${SLURM_JOB_ID}.csv"

module purge

# Dependency hell resolved (I hope so)
module load GCCcore/14.3.0
module load llvm-compilers/20.1.8
module load nvidia-compilers/25.9-CUDA-12
module load OpenMPI/5.0.8

module load git/2.50.1
module load Python/3.13.5

: "${PROJECT_seanergys:?PROJECT_seanergys is not set}"
: "${USER:?USER is not set}"
FLURM_DIR="$PROJECT_seanergys/$USER/flurm"
HOME_FLURM_DIR="$HOME/flurm"

SPEC_CFG="$PROJECT_seanergys/$USER/flux_spec_gcc.cfg"
SPEC_ROOT="$PROJECT_seanergys/triantafyllis1/spechpc"
export SPECHPC_BINARY_ROOT="$SPEC_ROOT"

export SPACK_PYTHON="$(command -v python3)"
export OMP_NUM_THREADS=1

source "$PROJECT_seanergys/spyropoulos1/flurm/load-custom-runtime.sh"
source "$PROJECT_seanergys/spyropoulos1/flurm/load-pmix-runtime.sh"
export SPECHPC_FLUX_PMI=pmix

pushd "$SPEC_ROOT" >/dev/null
source ./shrc
popd >/dev/null

export LD_LIBRARY_PATH="$SPEC_ROOT/compat/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

ldd "$SPEC_ROOT/benchspec/HPC/519.clvleaf_t/exe/clvleaf_base.gnu_mpi" \
    | grep -E 'libmpi|libpciaccess|libcudart|not found'

export PATH="$FLUX_SPEC_DIR:$PATH"
test -x "$FLUX_SPEC_DIR/spec-flux-submit"
command -v flux
command -v runhpc
command -v specinvoke
flux version

ls -l "$SPEC_ROOT/compat/lib/libnsl.so.1"
ldd "$SPEC_ROOT/bin/specperl" | grep -E 'libnsl|not found'
"$SPEC_ROOT/bin/specperl" -e 'print "specperl works\n"'

python3 "$FLUX_SPEC_DIR/edit_flux_config.py" \
    "$FLUX_SPEC_DIR/config/flux-config-cosched.toml" \
    "$WORKLOAD_DIR" \
    "$@"

host_lines="$(scontrol show hostnames "${SLURM_NODELIST:?}")"
mapfile -t hosts <<< "$host_lines"
hostlist="$(IFS=,; echo "${hosts[*]}")"
cores_per_node=$((2 * 4 * 2 * 8))

# If we want a different resource_type co-scheduling, we may have to change the JGF graph given to flux
# python3 "$HOME_FLURM_DIR/scripts/jgf_gen.py" \
#     --nodes "$hostlist" \
#     --set socket=2 --set numanode=4 --set ccd=2 --set core=8 \
#     -o "$WORKLOAD_DIR/aris.json"

python3 "$HOME_FLURM_DIR/scripts/jgf_gen.py" \
    --nodes "$hostlist" \
    --set socket=2 --set numanode=4 --set core=16 \
    -o "$WORKLOAD_DIR/aris.json"

flux R encode -H "$hostlist" -c "0-$((cores_per_node - 1))" > "$WORKLOAD_DIR/R"

exec srun -N "$SLURM_JOB_NUM_NODES" -n "$SLURM_JOB_NUM_NODES" \
    --mpi=pmi2 --cpu-bind=none --export=ALL \
    flux start -o --config-path="$WORKLOAD_DIR/flux-config-cosched.toml" \
    python3 "$FLUX_SPEC_DIR/replay_workload.py" "$INPUT_FILE" "$SPEC_CFG" "$WORKLOAD_DIR" "$OUTPUT_FILE"
