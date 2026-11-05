import csv
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path

def read_trace(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.reader(stream, strict=True)
        header = next(reader, [])
        required = ("app", "procs", "submit_time")
        if len(set(header)) != len(header) or not set(required) <= set(header):
            raise ValueError("CSV needs unique columns including app, procs, submit_time")
        if "flux_job_id" in header:
            raise ValueError("CSV already contains flux_job_id")

        app_col, procs_col, time_col = map(header.index, required)
        rows = []
        last_offset = 0.0

        for row in reader:
            if not row:
                continue
            line = reader.line_num
            if len(row) != len(header):
                raise ValueError(f"CSV line {line}: wrong number of fields")

            app = row[app_col].strip()
            if not re.fullmatch(r"[0-9]{3}\.[A-Za-z0-9_]+", app):
                raise ValueError(f"CSV line {line}: expected one SPEChpc benchmark ID")

            try:
                procs = int(row[procs_col])
                offset = float(row[time_col])
            except ValueError as exc:
                raise ValueError(f"CSV line {line}: invalid procs or submit_time") from exc

            if procs < 1:
                raise ValueError(f"CSV line {line}: procs must be positive")
            if not math.isfinite(offset) or offset < last_offset:
                raise ValueError(
                    f"CSV line {line}: submit_time must be nonnegative and nondecreasing"
                )

            rows.append((row, app, procs, offset))
            last_offset = offset

    return header, rows

def prepare(job_dir, config, app, procs):
    spec_root = job_dir / "spec"
    binary_root = Path(os.environ["SPECHPC_BINARY_ROOT"])
    source_exe = binary_root / "benchspec" / "HPC" / app / "exe"
    target_exe = spec_root / "benchspec" / "HPC" / app / "exe"

    if not source_exe.is_dir():
        raise ValueError(f"Prebuilt executable directory missing: {source_exe}")

    target_exe.parent.mkdir(parents=True, exist_ok=True)
    target_exe.symlink_to(source_exe, target_is_directory=True)
    
    size = os.environ.get("SPECHPC_SIZE", "ref")

    with (job_dir / "setup.log").open("wb") as log:
        subprocess.run(
            [
                "runhpc", f"--config={config}", "--action=runsetup",
                "--noreportable", "--nobuild", "--tune=base", "--iterations=1",
                "--threads=1", f"--size={size}", f"--ranks={procs}",
                f"--output_root={spec_root}", app,
            ],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )

        command_files = list(spec_root.rglob("speccmds.cmd"))
        if len(command_files) != 1:
            raise ValueError(f"expected one speccmds.cmd, found {len(command_files)}")

        command_file = command_files[0]
        preview = subprocess.run(
            ["specinvoke", "-n", command_file.name],
            cwd=command_file.parent,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=log,
            text=True,
            check=True,
        ).stdout

    (job_dir / "specinvoke.plan").write_text(preview, encoding="utf-8")

    commands = [
        line.strip()
        for line in preview.splitlines()
        if line.strip() and not line.lstrip().startswith(("#", "specinvoke exit:"))
    ]
    if len(commands) != 1 or not commands[0].startswith("spec-flux-submit "):
        raise ValueError("expected one spec-flux-submit command; see specinvoke.plan")

    return command_file

def submit(command_file, job_dir, procs):
    env = dict(os.environ, WORKLOAD_JOB_DIR=str(job_dir), WORKLOAD_PROCS=str(procs))
    with (job_dir / "specinvoke.out").open("wb") as out, \
         (job_dir / "specinvoke.err").open("wb") as err:
        result = subprocess.run(
            ["specinvoke", command_file.name],
            cwd=command_file.parent,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=err,
        )

    id_file = job_dir / "flux_job_id"
    job_id = id_file.read_text(encoding="utf-8").strip() if id_file.exists() else ""
    return job_id, result.returncode

def collect(job_id, job_dir):
    with (job_dir / "collect.err").open("ab") as err:
        status = subprocess.run(
            ["flux", "job", "status", job_id],
            stdout=subprocess.DEVNULL,
            stderr=err,
        )
        (job_dir / "exit_code").write_text(f"{status.returncode}\n", encoding="utf-8")
        ok = status.returncode == 0

        for key, filename in (
            ("jobspec", "jobspec.json"),
            ("R", "R"),
            ("eventlog", "eventlog.jsonl"),
        ):
            result = subprocess.run(
                ["flux", "job", "info", job_id, key],
                stdout=subprocess.PIPE,
                stderr=err,
            )
            if result.returncode == 0:
                (job_dir / filename).write_bytes(result.stdout)
            else:
                ok = False

    return ok

def main():
    input_csv, config, workload, output_csv = map(Path, sys.argv[1:])
    header, rows = read_trace(input_csv)
    prepared = []
    submitted = []
    failed = False

    with output_csv.open("x", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow([*header, "flux_job_id"])
        stream.flush()

        for index, (row, app, procs, offset) in enumerate(rows, start=1):
            job_dir = workload / f"{index:06d}-{app}"
            job_dir.mkdir()
            try:
                command_file = prepare(job_dir, config, app, procs)
            except (ValueError, subprocess.CalledProcessError) as exc:
                (job_dir / "setup.err").write_text(f"{exc}\n", encoding="utf-8")
                command_file = None
            prepared.append((row, procs, offset, job_dir, command_file))

        start = time.monotonic()
        for row, procs, offset, job_dir, command_file in prepared:
            job_id = ""
            if command_file is not None:
                time.sleep(max(0.0, start + offset - time.monotonic()))
                job_id, launch_status = submit(command_file, job_dir, procs)
                failed |= launch_status != 0

            writer.writerow([*row, job_id])
            stream.flush()

            if job_id:
                submitted.append((job_id, job_dir))
                elapsed = time.monotonic() - start
                print(f"{job_dir.name} t={elapsed:.3f}s {job_id}", flush=True)
            else:
                failed = True
                print(f"{job_dir.name}: no Flux job ID; see {job_dir}", file=sys.stderr)

    for job_id, job_dir in submitted:
        if not collect(job_id, job_dir):
            failed = True

    return int(failed)

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, csv.Error) as exc:
        sys.exit(str(exc))