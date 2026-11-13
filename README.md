**Proper README coming soon...**

# Quick steps

1) Clone the repository into your JUSUF `$HOME/flux-spec` directory and `cd ~/flux-spec`
2) Change the `#SBATCH` directives of `submit_workload.sh` if needed
3) Submit your workload with one of the following ways:
    - Submit whole experiment with compact and 2/4/8-way modes:
    ```bash
    sbatch submit_workload.sh input.csv --experiment
    ```
    - Submit the workload only with compact mode:
    ```bash
    sbatch submit_workload.sh input.csv --compact
    ```
    - Submit the workload only with a co-scheduling mode:
    ```bash
    sbatch submit_workload.sh input.csv [--n_way N] [--resource_type TYPE] [--waste_threshold X]
    ```

# Input files

Inside the `inputs/` directory there are example input CSV files for all small and tiny SPEC benchmarks.

