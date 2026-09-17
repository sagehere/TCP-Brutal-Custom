#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dry_run=${P2_DRY_RUN:-0}
cpu_counts=${P2_CPU_COUNTS:-"8 16 32"}
outdir=${P2_OUTPUT_DIR:-$repo/benchmark-results/p2-pacer-$(date +%Y%m%d-%H%M%S)}

if [[ $dry_run != 1 ]]; then
  [[ $EUID == 0 ]] || { echo "run as root (or set P2_DRY_RUN=1)" >&2; exit 1; }
  command -v perf >/dev/null || { echo "perf is required" >&2; exit 1; }
  command -v taskset >/dev/null || { echo "taskset is required" >&2; exit 1; }
fi

mkdir -p "$outdir"
printf 'kernel=%s\narchitecture=%s\ncpus=%s\n' \
  "$(uname -r)" "$(uname -m)" "$(nproc)" >"$outdir/system.txt"

object_size=unknown
[[ -r /sys/kernel/slab/tcp_brutal_peer/object_size ]] && \
  object_size=$(</sys/kernel/slab/tcp_brutal_peer/object_size)
{
  echo 'peers,peer_slab_lower_bound_bytes'
  for peers in 1000 10000 100000; do
    if [[ $object_size =~ ^[0-9]+$ ]]; then
      printf '%s,%s\n' "$peers" "$((peers * object_size))"
    else
      printf '%s,unavailable\n' "$peers"
    fi
  done
} >"$outdir/memory.csv"

available=$(nproc)
[[ $dry_run == 1 ]] && available=999
ran=0
for count in $cpu_counts; do
  [[ $count =~ ^[1-9][0-9]*$ ]] || { echo "invalid CPU count: $count" >&2; exit 1; }
  ((count <= available)) || continue
  ran=1
  cpulist="0-$((count - 1))"
  for mode in same independent; do
    prefix="$outdir/${mode}-${count}cpu"
    command=(env P2_CPU_LIST="$cpulist" P2_STREAMS="${P2_STREAMS:-$count}" \
      P2_SECONDS="${P2_SECONDS:-20}" P2_RATE_MBPS="${P2_RATE_MBPS:-200}" \
      taskset -c "$cpulist" bash "$repo/tests/pacer-contention-once.sh" "$mode")
    if [[ $dry_run == 1 ]]; then
      printf 'DRY-RUN:'; printf ' %q' "${command[@]}"; printf '\n'
      continue
    fi
    events=cycles,instructions,cache-references,cache-misses,context-switches,cpu-migrations
    perf list 2>/dev/null | grep -q 'LLC-loads' && events+=,LLC-loads,LLC-load-misses
    cp /proc/softirqs "$prefix-softirqs-before.txt"
    cp /proc/stat "$prefix-proc-stat-before.txt"
    perf stat -a -C "$cpulist" -e "$events" -o "$prefix-stat.txt" -- \
      "${command[@]}" >"$prefix-throughput.txt"
    cp /proc/softirqs "$prefix-softirqs-after.txt"
    cp /proc/stat "$prefix-proc-stat-after.txt"
    if [[ ${P2_PERF_DEEP:-1} == 1 ]]; then
      if perf lock record -o "$prefix-lock.data" -- "${command[@]}" \
          >"$prefix-lock-throughput.txt"; then
        perf lock report -i "$prefix-lock.data" >"$prefix-lock.txt" 2>&1 || \
          echo 'perf lock report unavailable' >"$prefix-lock.txt"
      else
        echo 'perf lock unavailable' >"$prefix-lock.txt"
      fi
      if perf c2c record -o "$prefix-c2c.data" -a -C "$cpulist" -- \
          "${command[@]}" >"$prefix-c2c-throughput.txt"; then
        perf c2c report -i "$prefix-c2c.data" --stdio >"$prefix-c2c.txt" 2>&1 || \
          echo 'perf c2c report unavailable' >"$prefix-c2c.txt"
      else
        echo 'perf c2c unavailable' >"$prefix-c2c.txt"
      fi
      if perf sched record -o "$prefix-sched.data" -- "${command[@]}" \
          >"$prefix-sched-throughput.txt"; then
        perf sched latency -i "$prefix-sched.data" >"$prefix-sched.txt" 2>&1 || \
          echo 'perf sched report unavailable' >"$prefix-sched.txt"
      else
        echo 'perf sched unavailable' >"$prefix-sched.txt"
      fi
    fi
  done
done

if (( !ran )); then
  echo "no requested CPU count is available (have $available; requested $cpu_counts)" >&2
  exit 1
fi
echo "pacer contention evidence saved under $outdir"
