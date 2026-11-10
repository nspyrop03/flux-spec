import argparse
import json
import math
import re
import tomllib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("template", type=Path)
parser.add_argument("workload", type=Path)
parser.add_argument("--n_way", type=int, default=2)
parser.add_argument("--resource_type", default="numanode")
parser.add_argument("--waste_threshold", type=float, default=0.0)
parser.add_argument("--compact", action="store_true", help="Disable CPU co-scheduling")
args = parser.parse_args()

if args.n_way < 1:
    parser.error("--n_way must be positive")
if not args.resource_type.strip():
    parser.error("--resource_type must be nonempty")
if not math.isfinite(args.waste_threshold) or args.waste_threshold < 0:
    parser.error("--waste_threshold must be finite and nonnegative")

values = {
    "PATH": json.dumps(str(args.workload / "R")),
    "SCHEDULING": json.dumps(str(args.workload / "aris.json")),
    "RTYPE": json.dumps(args.resource_type),
    "NWAY": str(args.n_way),
    "WTHR": repr(args.waste_threshold),
    "ALLOWED": json.dumps(not args.compact)
}
template = args.template.read_text()
config = re.sub(
    r"\b(?:PATH|SCHEDULING|ALLOWED|RTYPE|NWAY|WTHR)\b",
    lambda match: values[match[0]],
    template,
)
tomllib.loads(config)

args.workload.mkdir()
(args.workload / "flux-config-cosched.toml").write_text(config)
