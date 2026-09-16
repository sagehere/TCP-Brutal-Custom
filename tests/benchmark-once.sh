#!/usr/bin/env bash
set -Eeuo pipefail

server="brutal-bench-server-$$"
client="brutal-bench-client-$$"
server_dev="bbs-$$"
client_dev="bbc-$$"
ctl=${BRUTALCTL:-$(cd "$(dirname "$0")/.." && pwd)/tools/brutalctl}

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
ip -n "$server" addr add 10.204.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.204.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up
if [[ ${SKIP_RULE_SETUP:-0} != 1 ]]; then
  ip netns exec "$server" "$ctl" add 10.204.0.0/24 "${RATE_MBPS}" perip noroute
  ip -n "$server" route change 10.204.0.0/24 dev "$server_dev" congctl lock brutal
else
  # Baseline releases keep rules in init_net, but route congctl is per netns.
  ip -n "$server" route change 10.204.0.0/24 dev "$server_dev" congctl lock brutal
fi
ip netns exec "$server" iperf3 -s -D >/dev/null 2>&1
iperf_args=(-c 10.204.0.1 -R -P "${STREAMS}" -t "${RUN_SECONDS}" -J)
[[ ${IPERF_ZEROCOPY:-0} == 1 ]] && iperf_args+=(-Z)
[[ ${IPERF_REPEATING_PAYLOAD:-0} == 1 ]] && iperf_args+=(--repeating-payload)
ip netns exec "$client" iperf3 "${iperf_args[@]}" >"${OUTPUT}"
