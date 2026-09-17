#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

suffix=$$
server="brutal-prefix-s-$suffix"
client="brutal-prefix-c-$suffix"
server_dev="bxs-$suffix"
client_dev="bxc-$suffix"
rules=/proc/net/tcp_brutal/rules
server_pid=
client_pid=

cleanup_pair() {
  set +e
  [[ -n $client_pid ]] && kill "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true
  [[ -n $client_pid ]] && wait "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && wait "$server_pid" 2>/dev/null || true
  client_pid=
  server_pid=
}

cleanup() {
  cleanup_pair
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
}
trap cleanup EXIT

write_rule() {
  printf '%s\n' "$1" | ip netns exec "$server" tee "$rules" >/dev/null
}

wait_rule() {
  local expected=$1 actual i
  for i in $(seq 1 100); do
    actual=$(ip netns exec "$server" awk '{for (i=1;i<=NF;i++) if ($i ~ /^rule=/) {sub(/^rule=/,"",$i); print $i}}' /proc/net/tcp_brutal/peers)
    [[ $actual == "$expected" ]] && return 0
    sleep 0.05
  done
  echo "timed out waiting for rule=$expected (last=${actual:-none})" >&2
  return 1
}

wait_empty() {
  local i
  for i in $(seq 1 100); do
    [[ -z $(ip netns exec "$server" cat /proc/net/tcp_brutal/peers) ]] && return 0
    sleep 0.05
  done
  return 1
}

run_connection() {
  local family=$1 source=$2 destination=$3 port=$4 expected=$5

  ip netns exec "$server" python3 - "$family" "$destination" "$port" <<'PY' &
import socket, sys, time
family, address, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
af = socket.AF_INET if family == "4" else socket.AF_INET6
bind_address = "::" if family == "mapped" else address
srv = socket.socket(af, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if family == "mapped":
    srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
srv.bind((bind_address, port))
srv.listen(1)
conn, _ = srv.accept()
conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"brutal")
time.sleep(30)
PY
  server_pid=$!
  sleep 0.2

  ip netns exec "$client" python3 - "$family" "$source" "$destination" "$port" <<'PY' &
import socket, sys, time
family, source, destination, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
af = socket.AF_INET6 if family == "6" else socket.AF_INET
s = socket.socket(af, socket.SOCK_STREAM)
if family == "6":
    s.setsockopt(socket.IPPROTO_IPV6, 78, 1)  # IPV6_FREEBIND
else:
    s.setsockopt(socket.IPPROTO_IP, 15, 1)  # IP_FREEBIND
s.bind((source, 0))
s.connect((destination, port))
time.sleep(30)
PY
  client_pid=$!

  wait_rule "$expected"
  cleanup_pair
  wait_empty
}

ip netns add "$server"
ip netns add "$client"
ip link add "$server_dev" type veth peer name "$client_dev"
ip link set "$server_dev" netns "$server"
ip link set "$client_dev" netns "$client"
ip -n "$server" addr add 10.232.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.232.0.2/24 dev "$client_dev"
ip -n "$server" addr add 2001:db8:232::1/64 dev "$server_dev" nodad
ip -n "$client" addr add 2001:db8:232::2/64 dev "$client_dev" nodad
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up
ip -n "$client" route add local 10.233.0.0/16 dev lo table local
ip -n "$server" route add 10.233.0.0/16 via 10.232.0.2 dev "$server_dev"
ip -n "$client" -6 route add local 2001:db8:233::/48 dev lo table local
ip -n "$server" -6 route add 2001:db8:233::/48 via 2001:db8:232::2 dev "$server_dev"

write_rule "add 0.0.0.0/0 rate=125000 perip"
write_rule "add 10.233.0.0/16 rate=125000 perip"
write_rule "add 10.233.1.0/24 rate=125000 perip"
write_rule "add 10.233.1.42/32 rate=125000 perip"
write_rule "add ::/0 rate=125000 perip"
write_rule "add 2001:db8:233::/48 rate=125000 perip"
write_rule "add 2001:db8:233:1::/64 rate=125000 perip"
write_rule "add 2001:db8:233:1::42/128 rate=125000 perip"

port=$((33000 + suffix % 1000))
run_connection 4 10.233.1.42 10.232.0.1 "$port" 4
write_rule "del 10.233.1.42/32"
run_connection mapped 10.233.1.42 10.232.0.1 "$((port + 1))" 3
write_rule "del 10.233.1.0/24"
run_connection 4 10.233.1.42 10.232.0.1 "$((port + 2))" 2

run_connection 6 2001:db8:233:1::42 2001:db8:232::1 "$((port + 3))" 8
write_rule "del 2001:db8:233:1::42/128"
run_connection 6 2001:db8:233:1::42 2001:db8:232::1 "$((port + 4))" 7
write_rule "del 2001:db8:233:1::/64"
run_connection 6 2001:db8:233:1::42 2001:db8:232::1 "$((port + 5))" 6

echo "prefix index test passed"
