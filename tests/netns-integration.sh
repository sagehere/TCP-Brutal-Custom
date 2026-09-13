#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
suffix=$$
server="brutal-server-$suffix"
client="brutal-client-$suffix"
server_dev="brs-$suffix"
client_dev="brc-$suffix"
result=$(mktemp)
update_result=$(mktemp)
exact_result=$(mktemp)

cleanup() {
  ip netns pids "$server" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns pids "$client" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
  rm -f "$result" "$update_result" "$exact_result"
}
trap cleanup EXIT

ip netns add "$server"
ip netns add "$client"
ip link add "$server_dev" type veth peer name "$client_dev"
ip link set "$server_dev" netns "$server"
ip link set "$client_dev" netns "$client"
ip -n "$server" addr add 10.203.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.203.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up

ip netns exec "$server" "$ctl" add 10.203.0.99/24 50 noroute perip
ip netns exec "$server" "$ctl" list | grep -q '^10.203.0.0/24[[:space:]]'
ip -n "$server" route change 10.203.0.0/24 dev "$server_dev" congctl lock brutal
[[ -z $(ip netns exec "$client" cat /proc/net/tcp_brutal/rules) ]]
ip netns exec "$server" iperf3 -s -D >/dev/null 2>&1
ip netns exec "$client" iperf3 -c 10.203.0.1 -R -P 4 -t 12 -J >"$result" &
runpid=$!
sleep 3
peer=$(ip netns exec "$server" cat /proc/net/tcp_brutal/peers)
grep -q 'ip=10.203.0.2 .*members=' <<<"$peer"
wait "$runpid"

python3 - "$result" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
rate = result["end"]["sum_received"]["bits_per_second"]
assert 49_000_000 <= rate <= 51_000_000, rate
PY

ip netns exec "$server" "$ctl" add 10.203.0.2/32 40 noroute perip
ip netns exec "$client" iperf3 -c 10.203.0.1 -R -P 4 -t 8 -J >"$exact_result"
ip netns exec "$server" "$ctl" del 10.203.0.2/32
python3 - "$exact_result" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
rate = result["end"]["sum_received"]["bits_per_second"]
assert 39_000_000 <= rate <= 41_000_000, rate
PY

ip netns exec "$client" iperf3 -c 10.203.0.1 -R -P 4 -t 14 -J >"$update_result" &
runpid=$!
sleep 4
ip netns exec "$server" "$ctl" add 10.203.0.0/24 30 noroute perip
wait "$runpid"
python3 - "$update_result" <<'PY'
import json, statistics, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
rates = [interval["sum"]["bits_per_second"] for interval in result["intervals"][-5:]]
rate = statistics.median(rates)
assert 29_000_000 <= rate <= 31_000_000, rate
PY

sleep 1
[[ -z $(ip netns exec "$server" cat /proc/net/tcp_brutal/peers) ]]
stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
grep -q '^active_peer_groups=0$' <<<"$stats"
grep -q '^peak_peer_groups=1$' <<<"$stats"
grep -q '^peer_alloc_failures=0$' <<<"$stats"
grep -q '^peer_insert_failures=0$' <<<"$stats"
echo "netns integration test passed"
