#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
suffix=$$
left="brutal-app-a-$suffix"
right="brutal-app-b-$suffix"
helper=$(mktemp)
out_a=$(mktemp)
out_b=$(mktemp)

cleanup() {
  ip netns pids "$left" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns pids "$right" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$left" 2>/dev/null || true
  ip netns del "$right" 2>/dev/null || true
  rm -f "$helper" "$out_a" "$out_b"
}
trap cleanup EXIT

cc -O2 -Wall -Wextra -o "$helper" "$repo/tests/app-group-netns.c"
ip netns add "$left"
ip netns add "$right"
ip -n "$left" link set lo up
ip -n "$right" link set lo up

# The same group ID must resolve to independent objects in different netns.
ip netns exec "$left" "$helper" 424242 6250000 4 >"$out_a" &
pid_a=$!
sleep 1
ip netns exec "$right" "$helper" 424242 3750000 2 >"$out_b" &
pid_b=$!
wait "$pid_b"
wait "$pid_a"

grep -q '^initial rate=6250000 group=424242 gain=20$' "$out_a"
grep -q '^final rate=6250000 group=424242 gain=20$' "$out_a"
grep -q '^initial rate=3750000 group=424242 gain=20$' "$out_b"
grep -q '^final rate=3750000 group=424242 gain=20$' "$out_b"

echo "application-group netns isolation test passed"
