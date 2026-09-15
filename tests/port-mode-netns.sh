#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }
repo=$(cd "$(dirname "$0")/.." && pwd)
suffix=$$
server="tbc-port-s-$suffix"
client="tbc-port-c-$suffix"
sdev="tps-$suffix"
cdev="tpc-$suffix"
server_py=$(mktemp)
client_py=$(mktemp)

cleanup() {
  ip netns pids "$server" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns pids "$client" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
  rm -f "$server_py" "$client_py"
}
trap cleanup EXIT

modprobe brutal
ip netns add "$server"
ip netns add "$client"
ip link add "$sdev" type veth peer name "$cdev"
ip link set "$sdev" netns "$server"
ip link set "$cdev" netns "$client"
ip -n "$server" addr add 10.204.0.1/24 dev "$sdev"
ip -n "$client" addr add 10.204.0.2/24 dev "$cdev"
ip -n "$server" -6 addr add 2001:db8:204::1/64 dev "$sdev" nodad
ip -n "$client" -6 addr add 2001:db8:204::2/64 dev "$cdev" nodad
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$sdev" up
ip -n "$client" link set "$cdev" up
ip -n "$server" route add default via 10.204.0.2 dev "$sdev"
ip -n "$server" -6 route add default via 2001:db8:204::2 dev "$sdev"

ip netns exec "$server" bash -c '
  export BRUTAL_MANAGER_LIB=1
  source "$1"
  MODE=auto
  TCP_PORTS=5211
  apply_port_rules
' _ "$repo/install.sh"

ip -n "$server" -4 rule show | grep -q 'sport 5211 lookup 233'
ip -n "$server" -6 rule show | grep -q 'sport 5211 lookup 233'
ip -n "$server" -4 route show table 233 | grep -q '10.204.0.0/24.*congctl lock brutal'
ip -n "$server" -6 route show table 233 | grep -q '2001:db8:204::/64.*congctl lock brutal'
cat >"$server_py" <<'PY'
import socket, threading, time
socks=[]
for family, addr in [(socket.AF_INET,('0.0.0.0',5211)),(socket.AF_INET,('0.0.0.0',5212)),(socket.AF_INET6,('::',5211)),(socket.AF_INET6,('::',5212))]:
    s=socket.socket(family,socket.SOCK_STREAM)
    if family == socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
    s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(addr); s.listen(2); socks.append(s)
def accept_one(s):
    c,_=s.accept(); time.sleep(8); c.close()
threads=[threading.Thread(target=accept_one,args=(s,)) for s in socks]
[t.start() for t in threads]
[t.join() for t in threads]
PY
cat >"$client_py" <<'PY'
import socket, time
conns=[]
for family, addr in [(socket.AF_INET,('10.204.0.1',5211)),(socket.AF_INET,('10.204.0.1',5212)),(socket.AF_INET6,('2001:db8:204::1',5211)),(socket.AF_INET6,('2001:db8:204::1',5212))]:
    s=socket.socket(family,socket.SOCK_STREAM)
    s.connect(addr); conns.append(s)
time.sleep(6)
PY

ip netns exec "$server" python3 "$server_py" &
server_pid=$!
sleep 1
ip netns exec "$client" python3 "$client_py" &
client_pid=$!
sleep 2

port_5211=$(ip netns exec "$server" ss -tin '( sport = :5211 )')
port_5212=$(ip netns exec "$server" ss -tin '( sport = :5212 )')
[[ $(grep -c '^ESTAB' <<<"$port_5211") == 2 ]]
[[ $(grep -c '^ESTAB' <<<"$port_5212") == 2 ]]
grep -q ' brutal ' <<<" $port_5211 "
! grep -q ' brutal ' <<<" $port_5212 "
wait "$client_pid"
wait "$server_pid"
echo "port-mode netns test passed"
