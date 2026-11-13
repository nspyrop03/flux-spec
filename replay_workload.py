import os
import csv
import math
import re
import subprocess
import sys
import time
import json
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
    test_options = []
    if "SPECHPC_TEST_FAILURE=submit" in assignments:
        test_options.append("--invalid-watcher-test-option")
    with (job_dir / "submit.err").open("wb") as err:
        result = subprocess.run(
            [
                "flux", "batch",
                *test_options,
                "--conf=resource.norestrict=true",
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
        with (job_dir / "exit_code").open("a", encoding="utf-8") as status_file:
            status_file.write(f"batch={status.returncode}\n")
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

def check_jobs(pending, collected):
    result = subprocess.run(
        ["flux", "jobs", "-a", "--count=0", "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    # Replay assigns a unique job name to each row in this Flux instance.
    jobs = {job["name"]: job for job in json.loads(result.stdout)["jobs"]}

    terminal_results = {"COMPLETED", "FAILED", "TIMEOUT", "CANCELED"}
    for name, (job_id, job_dir, _) in pending.items():
        batch_result = jobs.get(name, {}).get("result")
        if batch_result in terminal_results and job_id not in collected:
            collected[job_id] = collect(job_id, job_dir)

    for name, (job_id, job_dir, app) in list(pending.items()):
        job = jobs.get(name, {})
        batch_result = job.get("result")

        status_file = job_dir / "exit_code"
        try:
            status_text = status_file.read_text(encoding="utf-8")
        except FileNotFoundError:
            status_text = ""

        mpi_statuses = [
            int(code) for code in re.findall(r"^mpi=(\d+)\n", status_text, re.MULTILINE)
        ]

        for status in mpi_statuses:
            if status != 0:
                return f"{name} ({job_id}): flux run exited with status {status}"

        if batch_result in {"FAILED", "TIMEOUT", "CANCELED"}:
            note = job.get("exception", {}).get("note")
            detail = f" ({note})" if note else ""
            return f"{name} ({job_id}): batch {batch_result}{detail}"

        if batch_result != "COMPLETED":
            continue

        if not mpi_statuses:
            return f"{name} ({job_id}): batch completed without an MPI exit status"

        with (job_dir / "stdout").open(encoding="utf-8", errors="replace") as stream:
            if not any(line.strip() == f"Success: 1x{app}" for line in stream):
                return f"{name} ({job_id}): SPEC success line missing"

        del pending[name]

    return None

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
    pending = {}
    collected = {}
    failure = None
    watch_interval = float(os.environ.get("SPECHPC_WATCH_INTERVAL", "300"))
    if not math.isfinite(watch_interval) or watch_interval <= 0:
        raise ValueError("SPECHPC_WATCH_INTERVAL must be a positive number of seconds")
    
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
        next_check = start + watch_interval
        rows_to_submit = iter(jobs)
        next_row = next(rows_to_submit, None)

        while next_row is not None or pending:
            now = time.monotonic()

            if pending and now >= next_check:
                try:
                    failure = check_jobs(pending, collected)
                except subprocess.CalledProcessError as exc:
                    detail = (exc.stderr or "").strip()
                    failure = f"Flux watcher query failed: {detail or exc.returncode}"
                except (OSError, ValueError) as exc:
                    failure = f"Watcher could not read job results: {exc}"

                if failure:
                    break

                next_check = time.monotonic() + watch_interval

            if next_row is not None:
                row, app, procs, offset, job_dir, assignments = next_row
                due = start + offset

                if time.monotonic() >= due:
                    job_id = submit(
                        batch_script, config, job_dir, app, procs,
                        control_node, assignments,
                    )
                    writer.writerow([*row, job_id])
                    stream.flush()

                    if not job_id:
                        failure = f"{job_dir.name}: submission failed; see {job_dir / 'submit.err'}"
                        break

                    submitted.append((job_id, job_dir))
                    pending[job_dir.name] = (job_id, job_dir, app)
                    elapsed = time.monotonic() - start
                    print(f"{job_dir.name} t={elapsed:.3f}s {job_id}", flush=True)

                    next_row = next(rows_to_submit, None)
                    if next_row is None:
                        next_check = time.monotonic()
                    continue

                wake_at = min(due, next_check) if pending else due
            elif pending:
                wake_at = next_check
            else:
                break

            time.sleep(max(0.0, wake_at - time.monotonic()))

    if failure:
        print(f"Aborting workload: {failure}", file=sys.stderr, flush=True)
        job_ids = [
            job_id for job_id, _, _ in pending.values()
            if job_id not in collected
        ]
        if job_ids:
            subprocess.run(
                ["flux", "cancel", "--message=Workload watcher aborted replay", *job_ids],
                check=False,
            )

    failed = failure is not None
    for job_id, job_dir in submitted:
        if job_id not in collected:
            collected[job_id] = collect(job_id, job_dir)

    return int(failure is not None or not all(collected.values()))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, csv.Error) as exc:
        sys.exit(str(exc))
