#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
ns="brutal-genl-$$"

cleanup() {
  ip netns del "$ns" 2>/dev/null || true
}
trap cleanup EXIT

grep -q 'genl' < <("$ctl" info)
ip netns add "$ns"

ip netns exec "$ns" "$ctl" limits 7 | grep -q '^max_peers=7$'
grep -q '^max_peers=7$' < <(ip netns exec "$ns" cat /proc/net/tcp_brutal/limits)
grep -q '^max_peers=0$' /proc/net/tcp_brutal/limits

ip netns exec "$ns" "$ctl" add 192.0.2.0/24 80 perip \
  aggregate=120 maxpeers=3 noroute
grep -q '^192.0.2.0/24 ' < <(ip netns exec "$ns" "$ctl" list)
grep -q ' rate=10000000 .* group=perip .* aggregate=15000000 maxpeers=3 ' \
  < <(ip netns exec "$ns" cat /proc/net/tcp_brutal/rules)
grep -q '^max_peers=7$' < <(ip netns exec "$ns" "$ctl" stats)

ip netns exec "$ns" "$ctl" del 192.0.2.0/24
! grep -q '^192.0.2.0/24 ' < <(ip netns exec "$ns" "$ctl" list)

echo "Generic Netlink namespace test passed"
