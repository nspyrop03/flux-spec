#!/bin/bash -l

#SBATCH --job-name=build-missing-tiny
#SBATCH --output=/p/home/jusers/%u/jusuf/flux-spec/runs/%x-%j.out
#SBATCH --error=/p/home/jusers/%u/jusuf/flux-spec/runs/%x-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --threads-per-core=1
#SBATCH --time=00:30:00
#SBATCH --partition=batch
#SBATCH --account=seanergys

set -eo pipefail

: "${PROJECT_seanergys:?PROJECT_seanergys is not set}"
flux_spec_dir="${SLURM_SUBMIT_DIR:?Submit this script from the flux-spec directory}"
spec_root="$PROJECT_seanergys/triantafyllis1/spechpc"
spec_config="$flux_spec_dir/config-spec/flux_spec_gcc.cfg"
build_root="${SPECHPC_BUILD_ROOT:-$HOME/spechpc-builds}"

test -r "$spec_config"
mkdir -p -- "$build_root"
build_root="$(realpath -e -- "$build_root")"

# Keep build metadata separate from the config used for replay.
build_config="$build_root/flux_spec_gcc-build-${SLURM_JOB_ID:?}.cfg"
cp -- "$spec_config" "$build_config"
chmod u+w -- "$build_config"

module purge
module load GCC/14.3.0
module load OpenMPI/5.0.8

cd "$spec_root"
source ./shrc
export LD_LIBRARY_PATH="$spec_root/compat/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

printf 'MPI C compiler: %s\n' "$(mpicc --showme:command)"
printf 'MPI C++ compiler: %s\n' "$(mpicxx --showme:command)"
fortran_command="$(mpif90 --showme:command)"
printf 'MPI Fortran compiler: %s\n' "$fortran_command"
fortran_compiler="${fortran_command%% *}"
case "${fortran_compiler##*/}" in
    gfortran|gfortran-*) ;;
    *)
        printf 'Expected a GCC-built OpenMPI module for %s, got %s\n' \
            "$spec_config" "$fortran_command" >&2
        exit 1
        ;;
esac

printf 'SPEChpc build root: %s\n' "$build_root"
exec runhpc --config="$build_config" \
    --output_root="$build_root" \
    --action=build --tune=base --define model=mpi \
    532.sph_exa_t 534.hpgmgfv_t 528.pot3d_t 535.weather_t
