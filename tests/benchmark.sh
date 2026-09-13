#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }
label=${1:?usage: benchmark.sh LABEL [OUTPUT_DIR]}
output=${2:-benchmark-results}
runs=${RUNS:-5}
seconds=${SECONDS_PER_RUN:-60}
streams=${STREAMS:-16}
rate=${RATE_MBPS:-200}
mkdir -p "$output/$label"

for run in $(seq 1 "$runs"); do
  RUN_SECONDS=$seconds STREAMS=$streams RATE_MBPS=$rate \
    SKIP_RULE_SETUP=${SKIP_RULE_SETUP:-0} \
    OUTPUT="$output/$label/run-$run.json" \
    bash "$(dirname "$0")/benchmark-once.sh"
done

python3 - "$output/$label" <<'PY'
import glob, json, statistics, sys
rates = []
for path in glob.glob(sys.argv[1] + "/run-*.json"):
    with open(path, encoding="utf-8") as stream:
        rates.append(json.load(stream)["end"]["sum_received"]["bits_per_second"])
print(json.dumps({"runs": len(rates), "median_bps": statistics.median(rates),
                  "min_bps": min(rates), "max_bps": max(rates)}, indent=2))
PY
