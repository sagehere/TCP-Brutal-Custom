#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
dry_run=${P2_DRY_RUN:-0}
counts=${P2_RULE_COUNTS:-"100 1000 10000"}
[[ ${P2_EXTREME:-0} == 1 ]] && counts="$counts 100000"

if [[ $dry_run != 1 && $EUID -ne 0 ]]; then
  echo "run as root (or set P2_DRY_RUN=1)" >&2
  exit 1
fi

printf 'index,rules,elapsed_ms\n'
for count in $counts; do
  [[ $count =~ ^[1-9][0-9]*$ ]] || { echo "invalid rule count: $count" >&2; exit 1; }
  if [[ $dry_run == 1 ]]; then
    printf 'exact,%s,DRY-RUN\n' "$count"
    printf 'prefix,%s,DRY-RUN\n' "$count"
    continue
  fi
  start=$(date +%s%N)
  RULES="$count" bash "$repo/tests/exact-host-scale.sh"
  end=$(date +%s%N)
  printf 'exact,%s,%s\n' "$count" "$(( (end - start) / 1000000 ))"
  start=$(date +%s%N)
  RULES="$count" bash "$repo/tests/intermediate-prefix-scale.sh"
  end=$(date +%s%N)
  printf 'prefix,%s,%s\n' "$count" "$(( (end - start) / 1000000 ))"
done
