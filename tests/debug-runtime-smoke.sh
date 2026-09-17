#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

# The active-peer pagination test intentionally holds thousands of sockets open.
# virtme guests may inherit a conservative soft RLIMIT_NOFILE (commonly 1024).
# Raise it enough for the requested peer count without exceeding the guest's hard
# limit (GitHub's virtme guest currently exposes 4096).
page_peers=${PAGE_PEERS:-2000}
required_nofile=$((page_peers + 128))
nofile_target=${NOFILE_TARGET:-$((page_peers + 1024))}
soft_nofile=$(ulimit -Sn)
hard_nofile=$(ulimit -Hn)
if [[ $hard_nofile != unlimited && $nofile_target -gt $hard_nofile ]]; then
  nofile_target=$hard_nofile
fi
if [[ $soft_nofile != unlimited && $soft_nofile -lt $nofile_target ]]; then
  if ! ulimit -Sn "$nofile_target" 2>/dev/null; then
    echo "unable to raise RLIMIT_NOFILE: target=$nofile_target soft=$(ulimit -Sn) hard=$hard_nofile" >&2
    exit 1
  fi
fi
soft_nofile=$(ulimit -Sn)
if [[ $soft_nofile != unlimited && $soft_nofile -lt $required_nofile ]]; then
  echo "RLIMIT_NOFILE too low for active-peer stress: required=$required_nofile soft=$soft_nofile hard=$hard_nofile" >&2
  exit 1
fi
echo "RLIMIT_NOFILE soft=$soft_nofile hard=$hard_nofile"

repo=$(cd "$(dirname "$0")/.." && pwd)
module=${1:-$repo/brutal.ko}
ctl=$repo/tools/brutalctl

[[ -f $module ]] || { echo "module not found: $module" >&2; exit 1; }

cleanup() {
  set +e
  if grep -q '^brutal ' /proc/modules 2>/dev/null; then
    rmmod brutal
  fi
}
trap cleanup EXIT

make -C "$repo/tools"
dmesg -C 2>/dev/null || true
insmod "$module"
grep -q '^brutal ' /proc/modules

echo "== info ABI and capability discovery =="
BRUTALCTL="$ctl" bash "$repo/tests/info-abi.sh"
echo "== netns rule isolation =="
BRUTALCTL="$ctl" bash "$repo/tests/netns-integration.sh"
echo "== application-group netns isolation =="
BRUTALCTL="$ctl" bash "$repo/tests/app-group-netns.sh"
echo "== peer lifecycle churn =="
PEERS=${PEERS:-2000} BRUTALCTL="$ctl" bash "$repo/tests/peer-churn.sh"
echo "== peer resource budget =="
BRUTALCTL="$ctl" bash "$repo/tests/peer-budget-netns.sh"
echo "== peer resource budget race =="
BRUTALCTL="$ctl" bash "$repo/tests/peer-budget-race.sh"
echo "== same-peer reconnect lifecycle =="
WORKERS=${RACE_WORKERS:-8} ITERATIONS=${RACE_ITERATIONS:-1000} \
  BRUTALCTL="$ctl" bash "$repo/tests/peer-reconnect-race.sh"
echo "== active peer pagination =="
PEERS=$page_peers PEER_WAIT_STEPS=${PEER_WAIT_STEPS:-300} \
  BRUTALCTL="$ctl" bash "$repo/tests/peer-pagination.sh"
echo "== rule ID index =="
BRUTALCTL="$ctl" bash "$repo/tests/rule-id-index-netns.sh"
echo "== intermediate prefix index =="
BRUTALCTL="$ctl" bash "$repo/tests/prefix-index-netns.sh"
echo "== kernel aggregate pacing =="
BRUTALCTL="$ctl" bash "$repo/tests/kernel-aggregate-netns.sh"
echo "== exact-host index growth =="
RULES=${EXACT_RULES:-1000} BRUTALCTL="$ctl" bash "$repo/tests/exact-host-scale.sh"

rmmod brutal
trap - EXIT

log=$(dmesg 2>/dev/null || true)
printf '%s\n' "$log"

# Fatal kernel diagnostics stay global. KCSAN is handled separately below
# because virtme-ng's shared root uses virtiofs/FUSE and can report unrelated
# filemap/virtqueue races even in a preflight guest that only runs `uname`.
if grep -Eiq \
  'BUG: KASAN|possible circular locking dependency|inconsistent lock state|bad unlock balance|held lock freed|suspicious RCU usage|sleeping function called from invalid context|deadlock|use-after-free|slab-out-of-bounds|refcount_t:|rcu[^:]*stall|kernel BUG|NULL pointer dereference|general protection fault|Oops:' \
  <<<"$log"; then
  echo "debug kernel reported a safety failure" >&2
  exit 1
fi

kcsan_reports=$(grep -Eic 'BUG: KCSAN: data-race' <<<"$log" || true)
if (( kcsan_reports > 0 )); then
  # Attribute a KCSAN report to this module only when an actual access stack
  # frame belongs to [brutal]. Workqueue metadata can name the current Brutal
  # callback even when both raced accesses are entirely inside core kernel code,
  # so a bare module marker is not sufficient attribution. A real Brutal stack
  # frame still fails the job.
  if awk '
    /BUG: KCSAN: data-race/ { in_report=1; report=$0 ORS; next }
    in_report {
      report=report $0 ORS
      if (index($0, "================================") != 0) {
        lower=tolower(report)
        if (lower ~ /\+0x[0-9a-f]+\/0x[0-9a-f]+[[:space:]]+\[brutal\]/)
          found=1
        in_report=0
        report=""
      }
    }
    END {
      if (in_report) {
        lower=tolower(report)
        if (lower ~ /\+0x[0-9a-f]+\/0x[0-9a-f]+[[:space:]]+\[brutal\]/)
          found=1
      }
      exit found ? 0 : 1
    }
  ' <<<"$log"; then
    echo "KCSAN reported a data race involving a Brutal stack frame" >&2
    exit 1
  fi
  echo "KCSAN reported $kcsan_reports unrelated data race(s); no Brutal access stack frames found" >&2
fi

echo "debug runtime smoke test passed"
