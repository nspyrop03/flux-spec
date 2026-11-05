#!/bin/bash -l

#SBATCH --job-name=check-env
#SBATCH --output=/p/home/jusers/%u/jusuf/tests/%x-%j.out
#SBATCH --error=/p/home/jusers/%u/jusuf/tests/%x-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=128
#SBATCH --threads-per-core=1
#SBATCH --time=00:10:00
#SBATCH --partition=batch
#SBATCH --account=seanergys
#SBATCH --exclusive

SPEC_ROOT="$PROJECT_seanergys/triantafyllis1/spechpc"

# ldd "$SPEC_ROOT/bin/specperl" | grep -E 'libnsl|not found'
# "$SPEC_ROOT/bin/specperl" -e 'print "specperl works\n"'

# module spider libnsl
# ldconfig -p | grep libnsl

ldd "$SPEC_ROOT/benchspec/HPC/519.clvleaf_t/exe/clvleaf_base.gnu_mpi" \
    | grep -E 'libpciaccess|not found'

module spider libpciaccess