#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)

make -C "$repo/tools"

echo "== namespace and per-IP correctness =="
bash "$repo/tests/netns-integration.sh"

echo "== application-group namespace isolation =="
bash "$repo/tests/app-group-netns.sh"

echo "== peer lifecycle churn =="
PEERS=${PEERS:-1000} bash "$repo/tests/peer-churn.sh"

echo "== same-IP multi-stream benchmark =="
RUNS=${RUNS:-3} SECONDS_PER_RUN=${SECONDS_PER_RUN:-20} STREAMS=${STREAMS:-16} \
RATE_MBPS=${RATE_MBPS:-200} bash "$repo/tests/benchmark.sh" "two-cpu-$(date +%Y%m%d-%H%M%S)" \
    "${OUTPUT_DIR:-$repo/benchmark-results/local}"

echo "2-CPU validation suite passed"
