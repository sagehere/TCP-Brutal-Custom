#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }
command -v tc >/dev/null || { echo "tc is required" >&2; exit 1; }
command -v iperf3 >/dev/null || { echo "iperf3 is required" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
outdir=${1:-$repo/benchmark-results/local/netem-$(date +%Y%m%d-%H%M%S)}
rate=${RATE_MBPS:-50}
seconds=${SECONDS_PER_CASE:-8}
rtts=${RTT_MS_LIST:-"1 50 200"}
losses=${LOSS_PERCENT_LIST:-"0 1 5 20"}
suffix=$$
server="brutal-netem-s-$suffix"
client="brutal-netem-c-$suffix"
server_dev="bns-$suffix"
client_dev="bnc-$suffix"
mkdir -p "$outdir"

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
ip -n "$server" addr add 10.205.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.205.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up
ip netns exec "$server" "$ctl" add 10.205.0.0/24 "$rate" perip
ip netns exec "$server" iperf3 -s -D >/dev/null 2>&1

printf 'rtt_ms,loss_percent,throughput_bps,retransmits\n' >"$outdir/results.csv"

for rtt in $rtts; do
  half=$(python3 - "$rtt" <<'PY'
import sys
print(float(sys.argv[1]) / 2)
PY
)
  for loss in $losses; do
    file="$outdir/rtt-${rtt}ms-loss-${loss}pct.json"
    ip netns exec "$server" tc qdisc replace dev "$server_dev" root netem delay "${half}ms" loss "${loss}%"
    ip netns exec "$client" tc qdisc replace dev "$client_dev" root netem delay "${half}ms"
    ip netns exec "$client" iperf3 -c 10.205.0.1 -R -P 4 -t "$seconds" -J >"$file"
    python3 - "$file" "$rtt" "$loss" >>"$outdir/results.csv" <<'PY'
import json, sys
path, rtt, loss = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    result = json.load(stream)
throughput = result["end"]["sum_received"]["bits_per_second"]
retransmits = result["end"].get("sum_sent", {}).get("retransmits", 0)
print(f"{rtt},{loss},{throughput:.0f},{retransmits}")
PY
  done
done

cat "$outdir/results.csv"
echo "netem matrix saved under $outdir"
