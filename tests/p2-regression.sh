#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
dry_run=${P2_DRY_RUN:-0}
full=${P2_FULL:-0}

run() {
  printf '== %s ==\n' "$1"
  shift
  if [[ $dry_run == 1 ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

if [[ $dry_run != 1 && $EUID -ne 0 ]]; then
  echo "run as root (or set P2_DRY_RUN=1)" >&2
  exit 1
fi

if [[ $full == 1 ]]; then
  peers=${P2_PEERS:-10000}
  race_workers=${P2_RACE_WORKERS:-8}
  race_iterations=${P2_RACE_ITERATIONS:-10000}
  exact_rules=${P2_EXACT_RULES:-10000}
  page_peers=${P2_PAGE_PEERS:-1000}
  benchmark_runs=${P2_BENCHMARK_RUNS:-5}
  benchmark_seconds=${P2_BENCHMARK_SECONDS:-60}
else
  peers=${P2_PEERS:-1000}
  race_workers=${P2_RACE_WORKERS:-8}
  race_iterations=${P2_RACE_ITERATIONS:-1000}
  exact_rules=${P2_EXACT_RULES:-1024}
  page_peers=${P2_PAGE_PEERS:-256}
  benchmark_runs=${P2_BENCHMARK_RUNS:-3}
  benchmark_seconds=${P2_BENCHMARK_SECONDS:-20}
fi

run "build brutalctl" make -C "$repo/tools"
run "P1 runtime regression" env \
  PEERS="$peers" \
  RACE_WORKERS="$race_workers" \
  RACE_ITERATIONS="$race_iterations" \
  EXACT_RULES="$exact_rules" \
  PAGE_PEERS="$page_peers" \
  RUNS="$benchmark_runs" \
  SECONDS_PER_RUN="$benchmark_seconds" \
  STREAMS="${P2_STREAMS:-16}" \
  RATE_MBPS="${P2_RATE_MBPS:-200}" \
  OUTPUT_DIR="${P2_OUTPUT_DIR:-$repo/benchmark-results/p2-local}" \
  bash "$repo/tests/two-cpu-validation.sh"

run "brutalctl input safety" bash "$repo/tests/brutalctl-safety.sh"
run "brutalctl route ownership" bash "$repo/tests/brutalctl-route-ownership.sh"
run "brutalctl route netns" env TBC_TEST_CC="${P2_ROUTE_TEST_CC:-reno}" \
  bash "$repo/tests/brutalctl-route-netns.sh"
run "aggregate egress manager" bash "$repo/tests/aggregate-egress-netns.sh"

if [[ ${P2_RUN_NETEM:-0} == 1 ]]; then
  run "RTT/loss matrix" bash "$repo/tests/netem-matrix.sh"
fi

printf 'P2 regression suite completed (full=%s dry_run=%s)\n' "$full" "$dry_run"
