#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

suffix=$$
ns="brutal-rule-id-$suffix"
rules=/proc/net/tcp_brutal/rules

cleanup() {
  ip netns del "$ns" 2>/dev/null || true
}
trap cleanup EXIT

ip netns add "$ns"
ip -n "$ns" link set lo up

write_rule() {
  printf '%s\n' "$1" | ip netns exec "$ns" tee "$rules" >/dev/null
}

write_rule "add 10.230.1.0/24 rate=125000 perip"
write_rule "add 10.230.2.0/24 rate=125000 lock"
write_rule "add 10.230.3.0/24 rate=125000 perip"

mapfile -t ids < <(ip netns exec "$ns" awk '{for (i=1;i<=NF;i++) if ($i ~ /^id=/) {sub(/^id=/,"",$i); print $i}}' "$rules")
[[ ${ids[*]} == "1 2 3" ]]

write_rule "del 10.230.2.0/24"
write_rule "add 10.230.4.0/24 rate=125000 perip"
mapfile -t ids < <(ip netns exec "$ns" awk '{for (i=1;i<=NF;i++) if ($i ~ /^id=/) {sub(/^id=/,"",$i); print $i}}' "$rules")
[[ ${ids[*]} == "1 3 4" ]]

for _ in $(seq 1 100); do
  ip netns exec "$ns" cat /proc/net/tcp_brutal/peers >/dev/null
done &
reader=$!
for i in $(seq 5 104); do
  write_rule "add 10.231.$((i / 256)).$((i % 256))/32 rate=125000 perip"
  write_rule "del 10.231.$((i / 256)).$((i % 256))/32"
done
wait "$reader"

echo "rule ID index test passed"
