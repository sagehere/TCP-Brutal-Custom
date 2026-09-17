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

echo "== same-peer reconnect lifecycle =="
WORKERS=${RACE_WORKERS:-8} ITERATIONS=${RACE_ITERATIONS:-1000} \
  bash "$repo/tests/peer-reconnect-race.sh"

echo "== exact-host index growth =="
RULES=${EXACT_RULES:-1024} bash "$repo/tests/exact-host-scale.sh"

echo "== paginated peer proc reads =="
PEERS=${PAGE_PEERS:-256} bash "$repo/tests/peer-pagination.sh"

echo "== rule ID index =="
bash "$repo/tests/rule-id-index-netns.sh"

echo "== same-IP multi-stream benchmark =="
RUNS=${RUNS:-3} SECONDS_PER_RUN=${SECONDS_PER_RUN:-20} STREAMS=${STREAMS:-16} \
RATE_MBPS=${RATE_MBPS:-200} bash "$repo/tests/benchmark.sh" "two-cpu-$(date +%Y%m%d-%H%M%S)" \
    "${OUTPUT_DIR:-$repo/benchmark-results/local}"

echo "2-CPU validation suite passed"
