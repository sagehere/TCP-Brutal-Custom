#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }
command -v perf >/dev/null || { echo "perf is required" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
label=${1:-perf-$(date +%Y%m%d-%H%M%S)}
outdir=${2:-$repo/benchmark-results/local/$label}
mkdir -p "$outdir"

export RUN_SECONDS=${RUN_SECONDS:-30}
export STREAMS=${STREAMS:-16}
export RATE_MBPS=${RATE_MBPS:-200}
export OUTPUT="$outdir/iperf.json"

perf stat -a \
  -e task-clock,cycles,instructions,cache-references,cache-misses,context-switches,cpu-migrations \
  -o "$outdir/perf-stat.txt" -- \
  bash "$repo/tests/benchmark-once.sh"

python3 - "$outdir/iperf.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
print(f"throughput_bps={result['end']['sum_received']['bits_per_second']:.0f}")
PY
cat "$outdir/perf-stat.txt"
echo "perf evidence saved under $outdir"
