#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
peers=${PEERS:-256}
suffix=$$
server="brutal-page-s-$suffix"
client="brutal-page-c-$suffix"
server_dev="bps-$suffix"
client_dev="bpc-$suffix"
port=$((28000 + suffix % 3000))

cleanup() {
  ip netns pids "$server" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns pids "$client" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
}
trap cleanup EXIT

ip netns add "$server"
ip netns add "$client"
ip link add "$server_dev" type veth peer name "$client_dev"
ip link set "$server_dev" netns "$server"
ip link set "$client_dev" netns "$client"
ip -n "$server" addr add 10.208.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.208.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up
ip -n "$client" route add local 10.209.0.0/16 dev lo table local
ip -n "$server" route add 10.209.0.0/16 dev "$server_dev"

ip netns exec "$server" "$ctl" add 10.209.0.0/16 100 noroute perip

ip netns exec "$server" python3 - "$peers" "$port" <<'PY' &
import socket, sys, time
count, port = map(int, sys.argv[1:])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("10.208.0.1", port))
srv.listen(512)
connections = []
for _ in range(count):
    conn, _ = srv.accept()
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"brutal")
    connections.append(conn)
while True:
    time.sleep(1)
PY
server_pid=$!
sleep 1

ip netns exec "$client" python3 - "$peers" "$port" <<'PY' &
import socket, sys, time
count, port = map(int, sys.argv[1:])
IP_FREEBIND = 15
connections = []
for i in range(count):
    third = (i // 254) & 0xff
    fourth = (i % 254) + 1
    source = f"10.209.{third}.{fourth}"
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
    s.bind((source, 0))
    s.connect(("10.208.0.1", port))
    connections.append(s)
while True:
    time.sleep(1)
PY
client_pid=$!

for _ in $(seq 1 100); do
  active=$(ip netns exec "$server" awk -F= '/^active_peer_groups=/{print $2}' /proc/net/tcp_brutal/stats)
  [[ $active -eq $peers ]] && break
  sleep 0.1
done
[[ ${active:-0} -eq $peers ]]

ip netns exec "$server" python3 - "$peers" <<'PY'
import os, sys
expected = int(sys.argv[1])
path = "/proc/net/tcp_brutal/peers"

def read_chunks(fd, size):
    parts = []
    while True:
        chunk = os.read(fd, size)
        if not chunk:
            break
        parts.append(chunk)
    text = b"".join(parts).decode()
    lines = [line for line in text.splitlines() if line]
    assert len(lines) == expected, (len(lines), expected)
    addresses = [line.split()[0].split("=", 1)[1] for line in lines]
    assert len(set(addresses)) == expected
    return set(lines)

fd = os.open(path, os.O_RDONLY)
try:
    first = read_chunks(fd, 67)
    os.lseek(fd, 0, os.SEEK_SET)
    second = read_chunks(fd, 113)
finally:
    os.close(fd)
assert first == second
PY

kill "$client_pid" "$server_pid" 2>/dev/null || true
wait "$client_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
sleep 1
stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
grep -q '^active_peer_groups=0$' <<<"$stats"
grep -q '^peer_fallback_connections=0$' <<<"$stats"

echo "peer pagination test passed: $peers active peers"
