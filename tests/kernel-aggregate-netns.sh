#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

suffix=$$
server="brutal-kagg-s-$suffix"
client="brutal-kagg-c-$suffix"
server_dev="bks-$suffix"
client_dev="bkc-$suffix"
port=$((34000 + suffix % 1000))
server_pid=
client_pid=

cleanup() {
  set +e
  [[ -n $client_pid ]] && kill "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
}
trap cleanup EXIT

write_rule() {
  printf '%s\n' "$1" | ip netns exec "$server" tee /proc/net/tcp_brutal/rules >/dev/null
}

ip netns add "$server"
ip netns add "$client"
ip link add "$server_dev" type veth peer name "$client_dev"
ip link set "$server_dev" netns "$server"
ip link set "$client_dev" netns "$client"
ip -n "$server" addr add 10.240.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.240.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up
ip -n "$client" route add local 10.241.0.0/16 dev lo table local
ip -n "$server" route add 10.241.0.0/16 via 10.240.0.2 dev "$server_dev" congctl lock brutal

write_rule "add 10.241.0.0/16 rate=12500000 perip aggregate=10000000"
grep -q ' aggregate=10000000 ' < <(ip netns exec "$server" cat /proc/net/tcp_brutal/rules)

ip netns exec "$server" python3 - "$port" <<'PY' &
import socket, sys, threading, time
port = int(sys.argv[1])
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("10.240.0.1", port))
srv.listen(2)
connections = [srv.accept()[0] for _ in range(2)]
stop = time.monotonic() + 5
def send(conn):
    data = b"x" * 65536
    while time.monotonic() < stop:
        conn.sendall(data)
threads = [threading.Thread(target=send, args=(conn,)) for conn in connections]
for thread in threads: thread.start()
for thread in threads: thread.join()
PY
server_pid=$!
sleep 0.2

ip netns exec "$client" python3 - "$port" <<'PY' &
import socket, sys, threading
port = int(sys.argv[1])
totals = [0, 0]
def receive(index):
    IP_FREEBIND = 15
    sock = socket.socket()
    sock.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
    sock.bind((f"10.241.0.{index + 1}", 0))
    sock.connect(("10.240.0.1", port))
    while True:
        data = sock.recv(65536)
        if not data: break
        totals[index] += len(data)
threads = [threading.Thread(target=receive, args=(i,)) for i in range(2)]
for thread in threads: thread.start()
for thread in threads: thread.join()
assert min(totals) > 1024 * 1024, totals
PY
client_pid=$!

for _ in $(seq 1 100); do
  active=$(ip netns exec "$server" awk -F= '/^active_peer_groups=/{print $2}' /proc/net/tcp_brutal/stats)
  [[ $active == 2 ]] && break
  sleep 0.05
done
[[ ${active:-0} == 2 ]]

for _ in $(seq 1 20); do
  write_rule "add 10.241.0.0/16 rate=12500000 perip aggregate=0"
  write_rule "add 10.241.0.0/16 rate=12500000 perip aggregate=10000000"
done

wait "$client_pid"
wait "$server_pid"
client_pid=
server_pid=

for _ in $(seq 1 100); do
  active=$(ip netns exec "$server" awk -F= '/^active_peer_groups=/{print $2}' /proc/net/tcp_brutal/stats)
  [[ $active == 0 ]] && break
  sleep 0.05
done
[[ ${active:-1} == 0 ]]
grep -q '^peer_fallback_connections=0$' < <(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)

echo "kernel aggregate pacing test passed"
