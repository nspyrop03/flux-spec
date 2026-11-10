**Proper README coming soon...**

# Quick steps
1) Clone the repository into your JUSUF `$HOME` directory
2) Change the path to the `jgf_gen.py` script (line 95 of `submit_workload.sh`)
3) Submit your workload with:
```bash
sbatch flux-spec/submit_workload.sh flux-spec/test_input.csv
```

# Usage
```bash
sbatch submit_workload.sh INPUT.csv [--compact] [--n_way N] [--resource_type TYPE] [--waste_threshold X]
```

