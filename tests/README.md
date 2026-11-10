Run all tests with:
```bash
SPECHPC_WATCH_INTERVAL=5 sbatch submit_workload.sh tests/<filename>
```

All failure tests should cancel the first row that is running and never submit the third one.