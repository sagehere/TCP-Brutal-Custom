#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

rules=${RULES:-1024}
suffix=$$
ns="brutal-exact-$suffix"

cleanup() {
  ip netns del "$ns" 2>/dev/null || true
}
trap cleanup EXIT

ip netns add "$ns"
ip -n "$ns" link set lo up

ip netns exec "$ns" python3 - "$rules" <<'PY'
import os, sys
count = int(sys.argv[1])
path = "/proc/net/tcp_brutal/rules"
fd = os.open(path, os.O_WRONLY)
try:
    for i in range(count):
        second = (i // (254 * 254)) % 254 + 1
        third = (i // 254) % 254 + 1
        fourth = i % 254 + 1
        addr = f"10.{second}.{third}.{fourth}"
        os.write(fd, f"add {addr}/32 rate=2500000 lock\n".encode())
    for i in range(min(count, 256)):
        addr = f"2001:db8::{i + 1:x}"
        os.write(fd, f"add {addr}/128 rate=2500000 lock\n".encode())
finally:
    os.close(fd)
PY

listed=$(ip netns exec "$ns" cat /proc/net/tcp_brutal/rules)
v4=$(grep -c '/32 ' <<<"$listed" || true)
v6=$(grep -c '/128 ' <<<"$listed" || true)
[[ $v4 -eq $rules ]]
[[ $v6 -eq $(( rules < 256 ? rules : 256 )) ]]

echo flush | ip netns exec "$ns" tee /proc/net/tcp_brutal/rules >/dev/null
[[ -z $(ip netns exec "$ns" cat /proc/net/tcp_brutal/rules) ]]

echo "exact-host scale test passed: $v4 IPv4 and $v6 IPv6 host rules"
