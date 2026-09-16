#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
module=${1:-$repo/brutal.ko}
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
cycles=${CYCLES:-100}

(( cycles > 0 )) || { echo "CYCLES must be positive" >&2; exit 1; }
[[ -f $module ]] || { echo "module not found: $module" >&2; exit 1; }

prefix="brutal-life-$$"
current_ns=

cleanup() {
  set +e
  [[ -n $current_ns ]] && ip netns del "$current_ns" 2>/dev/null || true
  if grep -q '^brutal ' /proc/modules 2>/dev/null; then
    rmmod brutal 2>/dev/null || true
  fi
}
trap cleanup EXIT

make -C "$repo/tools" brutalctl
dmesg -C 2>/dev/null || true

for i in $(seq 1 "$cycles"); do
  insmod "$module"
  grep -q '^brutal ' /proc/modules

  current_ns="$prefix-$i"
  ip netns add "$current_ns"
  ip -n "$current_ns" link set lo up
  ip netns exec "$current_ns" "$ctl" add 10.240.0.0/16 100 noroute perip
  ip netns exec "$current_ns" grep -q '10.240.0.0/16' /proc/net/tcp_brutal/rules
  ip netns exec "$current_ns" test -r /proc/net/tcp_brutal/stats

  # Delete the namespace while its Brutal rule is still installed. This
  # exercises per-net teardown before the module's global exit path runs.
  ip netns del "$current_ns"
  current_ns=

  rmmod brutal
  ! grep -q '^brutal ' /proc/modules
  [[ ! -e /proc/net/tcp_brutal/stats ]]

  if (( i % 10 == 0 || i == cycles )); then
    echo "module lifecycle cycles completed: $i/$cycles"
  fi
done

trap - EXIT

log=$(dmesg 2>/dev/null || true)
printf '%s\n' "$log"
if grep -Eiq \
  'BUG: KASAN|BUG: KCSAN|possible circular locking dependency|inconsistent lock state|bad unlock balance|held lock freed|suspicious RCU usage|sleeping function called from invalid context|deadlock|use-after-free|slab-out-of-bounds|refcount_t:|rcu[^:]*stall|kernel BUG|NULL pointer dereference|general protection fault|Oops:' \
  <<<"$log"; then
  echo "debug kernel reported a safety failure during module lifecycle stress" >&2
  exit 1
fi

echo "module lifecycle stress test passed: cycles=$cycles"
