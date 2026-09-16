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

echo "== netns rule isolation =="
BRUTALCTL="$ctl" bash "$repo/tests/netns-integration.sh"
echo "== application-group netns isolation =="
BRUTALCTL="$ctl" bash "$repo/tests/app-group-netns.sh"
echo "== peer lifecycle churn =="
PEERS=${PEERS:-2000} BRUTALCTL="$ctl" bash "$repo/tests/peer-churn.sh"
echo "== same-peer reconnect lifecycle =="
WORKERS=${RACE_WORKERS:-8} ITERATIONS=${RACE_ITERATIONS:-1000} \
  BRUTALCTL="$ctl" bash "$repo/tests/peer-reconnect-race.sh"
echo "== active peer pagination =="
PEERS=$page_peers PEER_WAIT_STEPS=${PEER_WAIT_STEPS:-300} \
  BRUTALCTL="$ctl" bash "$repo/tests/peer-pagination.sh"
echo "== exact-host index growth =="
RULES=${EXACT_RULES:-1000} BRUTALCTL="$ctl" bash "$repo/tests/exact-host-scale.sh"

rmmod brutal
trap - EXIT

log=$(dmesg 2>/dev/null || true)
printf '%s\n' "$log"
if grep -Eiq \
  'BUG: KASAN|KCSAN: data-race|possible circular locking dependency|inconsistent lock state|bad unlock balance|held lock freed|suspicious RCU usage|sleeping function called from invalid context|deadlock|use-after-free|slab-out-of-bounds|refcount_t:|rcu[^:]*stall|kernel BUG|NULL pointer dereference|general protection fault|Oops:' \
  <<<"$log"; then
  echo "debug kernel reported a safety failure" >&2
  exit 1
fi

echo "debug runtime smoke test passed"
