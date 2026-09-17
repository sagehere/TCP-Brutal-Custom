#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

rules=${RULES:-1024}
suffix=$$
ns="brutal-prefix-scale-$suffix"

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
        third = (i >> 16) & 0xffff
        fourth = i & 0xffff
        os.write(fd, f"add 2001:db8:{third:x}:{fourth:x}::/64 rate=2500000 lock\n".encode())
finally:
    os.close(fd)
PY

listed=$(ip netns exec "$ns" grep -c '/64 ' /proc/net/tcp_brutal/rules || true)
[[ $listed -eq $rules ]]
echo flush | ip netns exec "$ns" tee /proc/net/tcp_brutal/rules >/dev/null
[[ -z $(ip netns exec "$ns" cat /proc/net/tcp_brutal/rules) ]]

echo "intermediate-prefix scale test passed: $listed IPv6 /64 rules"
