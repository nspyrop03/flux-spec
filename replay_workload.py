import os
import csv
import math
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
        variables_col = header.index("variables") if "variables" in header else None
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

            assignments = []
            if variables_col is not None and row[variables_col].strip():
                for item in row[variables_col].split(","):
                    name, separator, value = item.partition("=")
                    name = name.strip()
                    if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                        raise ValueError(
                            f"CSV line {line}: invalid environment assignment {item!r}"
                        )
                    assignments.append(f"{name}={value}")

            rows.append((row, app, procs, offset, assignments))
            last_offset = offset

    return header, rows

def submit(batch_script, config, job_dir, app, procs, control_node, assignments):
    with (job_dir / "submit.err").open("wb") as err:
        result = subprocess.run(
            [
                "flux", "batch",
                "-n", str(procs),
                "-c", "1",
                f"--requires=-hosts:{control_node}",
                f"--job-name={job_dir.name}",
                f"--cwd={job_dir}",
                f"--output={job_dir / 'stdout'}",
                f"--error={job_dir / 'stderr'}",
                str(batch_script), str(config), str(job_dir), app, str(procs),
                *assignments,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=err,
            text=True,
        )

    if result.returncode != 0:
        return ""

    job_id = result.stdout.strip()
    if job_id:
        (job_dir / "flux_job_id").write_text(f"{job_id}\n", encoding="utf-8")
    return job_id

def collect(job_id, job_dir):
    with (job_dir / "collect.err").open("ab") as err:
        status = subprocess.run(
            ["flux", "job", "status", job_id],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=err,
        )
        (job_dir / "exit_code").write_text(
            f"{status.returncode}\n", encoding="utf-8"
        )
        ok = status.returncode == 0

        for key, filename in (
            ("jobspec", "jobspec.json"),
            ("R", "R"),
            ("eventlog", "eventlog.jsonl"),
        ):
            result = subprocess.run(
                ["flux", "job", "info", job_id, key],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=err,
            )
            if result.returncode == 0:
                (job_dir / filename).write_bytes(result.stdout)
            else:
                ok = False

    return ok

def main():
    if len(sys.argv) != 5:
        raise ValueError(
            f"Usage: {Path(sys.argv[0]).name} INPUT.csv SPEC.cfg WORKLOAD_DIR OUTPUT.csv"
        )

    control_node = os.environ.get("CONTROL_NODE")
    if not control_node:
        raise ValueError("CONTROL_NODE is missing. Launch through submit_workload.sh.")

    input_csv, config, workload, output_csv = map(Path, sys.argv[1:])
    config = config.resolve(strict=True)
    workload = workload.resolve(strict=True)
    batch_script = Path(__file__).resolve().with_name("run_spec_row.sh")
    if not batch_script.is_file():
        raise FileNotFoundError(f"Batch script missing: {batch_script}")

    header, rows = read_trace(input_csv)
    submitted = []
    failed = False

    with output_csv.open("x", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow([*header, "flux_job_id"])
        stream.flush()

        jobs = []
        for index, (row, app, procs, offset, assignments) in enumerate(rows, start=1):
            job_dir = workload / f"{index:06d}-{app}"
            job_dir.mkdir()
            jobs.append((row, app, procs, offset, job_dir, assignments))

        start = time.monotonic()
        for row, app, procs, offset, job_dir, assignments in jobs:
            time.sleep(max(0.0, start + offset - time.monotonic()))
            job_id = submit(
                batch_script, config, job_dir, app, procs, control_node, assignments
            )

            writer.writerow([*row, job_id])
            stream.flush()

            if job_id:
                submitted.append((job_id, job_dir))
                elapsed = time.monotonic() - start
                print(f"{job_dir.name} t={elapsed:.3f}s {job_id}", flush=True)
            else:
                failed = True
                print(
                    f"{job_dir.name}: no Flux job ID; see {job_dir / 'submit.err'}",
                    file=sys.stderr,
                )

    for job_id, job_dir in submitted:
        if not collect(job_id, job_dir):
            failed = True

    return int(failed)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, csv.Error) as exc:
        sys.exit(str(exc))
