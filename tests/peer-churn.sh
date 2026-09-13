#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
peers=${PEERS:-1000}
suffix=$$
server="brutal-churn-s-$suffix"
client="brutal-churn-c-$suffix"
server_dev="bcs-$suffix"
client_dev="bcc-$suffix"
port=$((24000 + suffix % 10000))

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
ip -n "$server" addr add 10.250.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.250.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up

# The client uses arbitrary source addresses without creating thousands of
# interface aliases. The local route makes return traffic local to the client.
ip -n "$client" route add local 10.251.0.0/16 dev lo table local
ip -n "$server" route add 10.251.0.0/16 dev "$server_dev"
ip netns exec "$server" "$ctl" add 10.251.0.0/16 20 noroute perip

ip netns exec "$server" python3 - "$peers" "$port" <<'PY' &
import socket, sys
count = int(sys.argv[1])
port = int(sys.argv[2])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("10.250.0.1", port))
srv.listen(256)
for _ in range(count):
    conn, _ = srv.accept()
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"brutal")
    conn.sendall(b"x" * 1024)
    conn.close()
srv.close()
PY
server_pid=$!
sleep 1

ip netns exec "$client" python3 - "$peers" "$port" <<'PY'
import socket, sys
count = int(sys.argv[1])
port = int(sys.argv[2])
IP_FREEBIND = 15
for i in range(count):
    third = (i // 254) & 0xff
    fourth = (i % 254) + 1
    source = f"10.251.{third}.{fourth}"
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
    s.bind((source, 0))
    s.connect(("10.250.0.1", port))
    while s.recv(4096):
        pass
    s.close()
PY
wait "$server_pid"

# Allow RCU callbacks to retire the final peer before checking the live view.
sleep 1
[[ -z $(ip netns exec "$server" cat /proc/net/tcp_brutal/peers) ]]
stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
grep -q '^active_peer_groups=0$' <<<"$stats"
grep -q '^peer_alloc_failures=0$' <<<"$stats"
grep -q '^peer_insert_failures=0$' <<<"$stats"

echo "peer churn test passed: $peers peer addresses"
