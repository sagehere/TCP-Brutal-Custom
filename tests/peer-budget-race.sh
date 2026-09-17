#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
connections=${CONNECTIONS:-128}
limit=${PEER_LIMIT:-32}
suffix=$$
server="brutal-budget-race-s-$suffix"
client="brutal-budget-race-c-$suffix"
server_dev="bbrs-$suffix"
client_dev="bbrc-$suffix"
port=$((33000 + suffix % 1000))
server_pid=
client_pid=

cleanup() {
  set +e
  [[ -n $client_pid ]] && kill "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true
  [[ -n $client_pid ]] && wait "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && wait "$server_pid" 2>/dev/null || true
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
}
trap cleanup EXIT

(( connections > limit )) || { echo "CONNECTIONS must exceed PEER_LIMIT" >&2; exit 1; }

ip netns add "$server"
ip netns add "$client"
ip link add "$server_dev" type veth peer name "$client_dev"
ip link set "$server_dev" netns "$server"
ip link set "$client_dev" netns "$client"
ip -n "$server" addr add 10.222.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.222.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up
ip -n "$client" route add local 10.223.0.0/16 dev lo table local
ip -n "$server" route add 10.223.0.0/16 via 10.222.0.2 dev "$server_dev"
echo "max_peers=$limit" | ip netns exec "$server" tee /proc/net/tcp_brutal/limits >/dev/null
ip netns exec "$server" "$ctl" add 10.223.0.0/16 100 noroute perip

ip netns exec "$server" python3 - "$connections" "$port" <<'PY' &
import socket, sys, time
count, port = map(int, sys.argv[1:])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("10.222.0.1", port))
srv.listen(256)
conns = []
for _ in range(count):
    conn, _ = srv.accept()
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"brutal")
    conns.append(conn)
while True:
    time.sleep(1)
PY
server_pid=$!
sleep 0.3

ip netns exec "$client" python3 - "$connections" "$port" <<'PY' &
import concurrent.futures, socket, sys, time
count, port = map(int, sys.argv[1:])
IP_FREEBIND = 15

def connect(i):
    third = (i // 254) & 0xff
    fourth = (i % 254) + 1
    source = f"10.223.{third}.{fourth}"
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
    s.bind((source, 0))
    s.connect(("10.222.0.1", port))
    return s

with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
    conns = list(pool.map(connect, range(count)))
while True:
    time.sleep(1)
PY
client_pid=$!

active=0
slots=0
fallbacks=0
for _ in $(seq 1 300); do
  stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
  slots=$(awk -F= '/^peer_slots=/{print $2}' <<<"$stats")
  active=$(awk -F= '/^active_peer_groups=/{print $2}' <<<"$stats")
  fallbacks=$(awk -F= '/^peer_budget_fallbacks=/{print $2}' <<<"$stats")
  (( slots <= limit )) || { echo "peer slot limit exceeded: $slots > $limit" >&2; exit 1; }
  (( active <= limit )) || { echo "active peer limit exceeded: $active > $limit" >&2; exit 1; }
  if (( active == limit && fallbacks >= connections - limit )); then
    break
  fi
  sleep 0.05
done

(( slots == limit )) || { echo "expected peer_slots=$limit, got $slots" >&2; exit 1; }
(( active == limit )) || { echo "expected active_peer_groups=$limit, got $active" >&2; exit 1; }
(( fallbacks >= connections - limit )) || {
  echo "expected at least $((connections - limit)) budget fallbacks, got $fallbacks" >&2
  exit 1
}

kill "$client_pid" "$server_pid" 2>/dev/null || true
wait "$client_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
client_pid=
server_pid=

for _ in $(seq 1 300); do
  stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
  slots=$(awk -F= '/^peer_slots=/{print $2}' <<<"$stats")
  active=$(awk -F= '/^active_peer_groups=/{print $2}' <<<"$stats")
  if (( slots == 0 && active == 0 )); then
    break
  fi
  sleep 0.05
done
(( slots == 0 && active == 0 )) || { echo "peer budget did not drain: slots=$slots active=$active" >&2; exit 1; }

ip netns del "$client"
ip netns del "$server"
trap - EXIT

echo "peer budget race test passed: connections=$connections limit=$limit fallbacks=$fallbacks"
