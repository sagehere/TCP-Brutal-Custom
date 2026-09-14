#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
workers=${WORKERS:-8}
iterations=${ITERATIONS:-2000}
suffix=$$
server="brutal-race-s-$suffix"
client="brutal-race-c-$suffix"
server_dev="brs-$suffix"
client_dev="brc-$suffix"
port=$((26000 + suffix % 5000))

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
ip -n "$server" addr add 10.206.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.206.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up

ip netns exec "$server" "$ctl" add 10.206.0.2/32 100 noroute perip

ip netns exec "$server" python3 - "$workers" "$iterations" "$port" <<'PY' &
import socket, sys
workers, iterations, port = map(int, sys.argv[1:])
count = workers * iterations
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("10.206.0.1", port))
srv.listen(512)
for _ in range(count):
    conn, _ = srv.accept()
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"brutal")
    conn.close()
srv.close()
PY
server_pid=$!
sleep 1

ip netns exec "$client" python3 - "$workers" "$iterations" "$port" <<'PY'
import socket, sys, threading
workers, iterations, port = map(int, sys.argv[1:])
errors = []

def worker():
    try:
        for _ in range(iterations):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.connect(("10.206.0.1", port))
            s.close()
    except Exception as exc:
        errors.append(exc)

threads = [threading.Thread(target=worker) for _ in range(workers)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
if errors:
    raise errors[0]
PY
wait "$server_pid"
sleep 1

stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
grep -q '^peer_alloc_failures=0$' <<<"$stats"
grep -q '^peer_insert_failures=0$' <<<"$stats"
grep -q '^peer_fallback_connections=0$' <<<"$stats"
grep -q '^active_peer_groups=0$' <<<"$stats"

echo "peer reconnect race test passed: $((workers * iterations)) connections"
