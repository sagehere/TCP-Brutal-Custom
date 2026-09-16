#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
suffix=$$
server="brutal-budget-s-$suffix"
client="brutal-budget-c-$suffix"
server_dev="bbs-$suffix"
client_dev="bbc-$suffix"
port=$((32000 + suffix % 1000))
server_pid=
client_pid=

cleanup_procs() {
  set +e
  [[ -n $client_pid ]] && kill "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true
  [[ -n $client_pid ]] && wait "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && wait "$server_pid" 2>/dev/null || true
  client_pid=
  server_pid=
}

cleanup() {
  set +e
  cleanup_procs
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
}
trap cleanup EXIT

wait_stat() {
  local key=$1 expected=$2 value i
  for i in $(seq 1 200); do
    value=$(ip netns exec "$server" awk -F= -v key="$key" '$1 == key {print $2}' /proc/net/tcp_brutal/stats)
    [[ $value == "$expected" ]] && return 0
    sleep 0.05
  done
  echo "timed out waiting for $key=$expected (last=${value:-missing})" >&2
  return 1
}

start_connections() {
  local peers=$1 base=$2
  ip netns exec "$server" python3 - "$peers" "$port" <<'PY' &
import socket, sys, time
count, port = map(int, sys.argv[1:])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("10.220.0.1", port))
srv.listen(64)
connections = []
for _ in range(count):
    conn, _ = srv.accept()
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"brutal")
    connections.append(conn)
while True:
    time.sleep(1)
PY
  server_pid=$!
  sleep 0.3

  ip netns exec "$client" python3 - "$peers" "$port" "$base" <<'PY' &
import socket, sys, time
count, port, base = map(int, sys.argv[1:])
IP_FREEBIND = 15
connections = []
for i in range(count):
    source = f"10.221.{base}.{i + 1}"
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
    s.bind((source, 0))
    s.connect(("10.220.0.1", port))
    connections.append(s)
while True:
    time.sleep(1)
PY
  client_pid=$!
}

ip netns add "$server"
ip netns add "$client"
ip link add "$server_dev" type veth peer name "$client_dev"
ip link set "$server_dev" netns "$server"
ip link set "$client_dev" netns "$client"
ip -n "$server" addr add 10.220.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.220.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up
ip -n "$client" route add local 10.221.0.0/16 dev lo table local
ip -n "$server" route add 10.221.0.0/16 via 10.220.0.2 dev "$server_dev"

# Rule limit wins before the wider netns limit.
echo max_peers=3 | ip netns exec "$server" tee /proc/net/tcp_brutal/limits >/dev/null
ip netns exec "$server" "$ctl" add 10.221.0.0/16 100 noroute perip maxpeers=2
start_connections 5 1
wait_stat peer_slots 2
wait_stat active_peer_groups 2
stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
rule=$(ip netns exec "$server" cat /proc/net/tcp_brutal/rules)
grep -q '^max_peers=3$' <<<"$stats"
grep -q '^peer_budget_fallbacks=3$' <<<"$stats"
grep -q '^peak_peer_slots=2$' <<<"$stats"
grep -q 'maxpeers=2 peer_slots=2 peak_peer_slots=2 budget_fallbacks=3' <<<"$rule"
grep -q '^max_peers=0$' < <(ip netns exec "$client" cat /proc/net/tcp_brutal/limits)

# Updating rate without maxpeers preserves the existing resource policy.
ip netns exec "$server" "$ctl" add 10.221.0.0/16 90 noroute perip
grep -q 'maxpeers=2 peer_slots=2 peak_peer_slots=2' < <(ip netns exec "$server" cat /proc/net/tcp_brutal/rules)
cleanup_procs
wait_stat peer_slots 0
wait_stat active_peer_groups 0

# Explicit maxpeers=0 removes the rule cap; the netns-wide cap now wins.
ip netns exec "$server" "$ctl" add 10.221.0.0/16 100 noroute perip maxpeers=0
start_connections 5 2
wait_stat peer_slots 3
wait_stat active_peer_groups 3
stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
rule=$(ip netns exec "$server" cat /proc/net/tcp_brutal/rules)
grep -q '^peer_budget_fallbacks=5$' <<<"$stats"
grep -q '^peak_peer_slots=3$' <<<"$stats"
grep -q 'maxpeers=0 peer_slots=3 peak_peer_slots=3 budget_fallbacks=2' <<<"$rule"
cleanup_procs
wait_stat peer_slots 0
wait_stat active_peer_groups 0

# Exercise the literal 99/100/101 boundary required by the P2 plan.
ip netns exec "$server" "$ctl" add 10.221.0.0/16 100 noroute perip maxpeers=0
echo max_peers=100 | ip netns exec "$server" tee /proc/net/tcp_brutal/limits >/dev/null
start_connections 99 3
wait_stat peer_slots 99
wait_stat active_peer_groups 99
grep -q '^peer_budget_fallbacks=5$' < <(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
cleanup_procs
wait_stat peer_slots 0
wait_stat active_peer_groups 0

start_connections 100 4
wait_stat peer_slots 100
wait_stat active_peer_groups 100
grep -q '^peer_budget_fallbacks=5$' < <(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
cleanup_procs
wait_stat peer_slots 0
wait_stat active_peer_groups 0

start_connections 101 5
wait_stat peer_slots 100
wait_stat active_peer_groups 100
grep -q '^peer_budget_fallbacks=6$' < <(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
cleanup_procs
wait_stat peer_slots 0
wait_stat active_peer_groups 0

# Deleting a rule must not invalidate slot accounting owned by live peers.
echo max_peers=8 | ip netns exec "$server" tee /proc/net/tcp_brutal/limits >/dev/null
ip netns exec "$server" "$ctl" add 10.221.0.0/16 100 noroute perip maxpeers=8
start_connections 4 6
wait_stat peer_slots 4
wait_stat active_peer_groups 4
ip netns exec "$server" "$ctl" del 10.221.0.0/16
[[ -z $(ip netns exec "$server" cat /proc/net/tcp_brutal/rules) ]]
wait_stat peer_slots 4
cleanup_procs
wait_stat peer_slots 0
wait_stat active_peer_groups 0

# Removing the netns cap returns to the compatibility default: unlimited.
echo max_peers=0 | ip netns exec "$server" tee /proc/net/tcp_brutal/limits >/dev/null
limits=$(ip netns exec "$server" cat /proc/net/tcp_brutal/limits)
grep -q '^max_peers=0$' <<<"$limits"
grep -q '^overflow=hashed_fallback$' <<<"$limits"

ip netns del "$client"
ip netns del "$server"
trap - EXIT

echo "peer budget netns test passed"
