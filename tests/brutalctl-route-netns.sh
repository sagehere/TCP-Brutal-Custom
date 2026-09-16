#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
ns=tbc-route-$RANDOM-$$
trap 'ip netns del "$ns" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
rules="$tmp/rules"
: >"$rules"

cc -O2 -Wall -Wextra -Werror -std=c99 -pedantic \
  -DRULES_PATH=\"$rules\" -o "$tmp/brutalctl" "$repo/tools/brutalctl.c"
ip netns add "$ns"
ip -n "$ns" link set lo up
ip -n "$ns" link add dummy0 type dummy
ip -n "$ns" addr add 198.51.100.2/24 dev dummy0
ip -n "$ns" link set dummy0 up
ip -n "$ns" route add default via 198.51.100.1 dev dummy0

ip -n "$ns" route add 192.0.2.0/24 via 198.51.100.1 dev dummy0 proto static metric 77
before=$(ip -n "$ns" -j route show exact 192.0.2.0/24)
set +e
ip netns exec "$ns" "$tmp/brutalctl" add 192.0.2.0/24 80 >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[[ $rc -ne 0 ]]
after=$(ip -n "$ns" -j route show exact 192.0.2.0/24)
[[ $before == "$after" ]]
[[ ! -s $rules ]]
grep -q 'refusing to replace existing route' "$tmp/err"

ip -n "$ns" route del 192.0.2.0/24 proto static metric 77
ip netns exec "$ns" "$tmp/brutalctl" add 192.0.2.0/24 80
ip -n "$ns" -N route show exact 192.0.2.0/24 | grep -q 'proto 233'
ip netns exec "$ns" "$tmp/brutalctl" del 192.0.2.0/24
! ip -n "$ns" -N route show exact 192.0.2.0/24 | grep -q .

echo 'brutalctl real netns route ownership tests passed'
