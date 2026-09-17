#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

mode=${1:?usage: pacer-contention-once.sh same|independent}
[[ $mode == same || $mode == independent ]] || exit 2
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
streams=${P2_STREAMS:-16}
seconds=${P2_SECONDS:-20}
rate=${P2_RATE_MBPS:-200}
cpus=${P2_CPU_LIST:-0}
suffix=$$
server="brutal-pacer-s-$suffix"
client="brutal-pacer-c-$suffix"
server_dev="bps-$suffix"
client_dev="bpc-$suffix"
port=$((35000 + suffix % 1000))
server_pid=
server_output=$(mktemp)

cleanup() {
  set +e
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
  rm -f "$server_output"
}
trap cleanup EXIT

ip netns add "$server"
ip netns add "$client"
ip link add "$server_dev" type veth peer name "$client_dev"
ip link set "$server_dev" netns "$server"
ip link set "$client_dev" netns "$client"
ip -n "$server" addr add 10.242.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.242.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up

if [[ $mode == same ]]; then
  ip -n "$server" route replace 10.242.0.2/32 dev "$server_dev" congctl lock brutal
  ip netns exec "$server" "$ctl" add 10.242.0.2/32 "$rate" perip noroute
else
  for ((i = 1; i <= streams; i++)); do
    third=$(( (i - 1) / 254 ))
    fourth=$(( (i - 1) % 254 + 1 ))
    ip -n "$client" addr add "10.243.$third.$fourth/32" dev "$client_dev"
  done
  ip -n "$server" route add 10.243.0.0/16 via 10.242.0.2 dev "$server_dev" congctl lock brutal
  ip netns exec "$server" "$ctl" add 10.243.0.0/16 "$rate" perip noroute
fi

ip netns exec "$server" python3 - "$port" "$streams" "$seconds" "$cpus" >"$server_output" <<'PY' &
import multiprocessing as mp, os, socket, sys, time
mp.set_start_method('fork')
port, streams, seconds = map(int, sys.argv[1:4])
cpus = []
for part in sys.argv[4].split(','):
    if '-' in part:
        first, last = map(int, part.split('-', 1)); cpus.extend(range(first, last + 1))
    else: cpus.append(int(part))
listener = socket.socket(); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('10.242.0.1', port)); listener.listen(streams)
connections = [listener.accept()[0] for _ in range(streams)]
deadline = time.monotonic() + seconds
def send(index, conn, queue):
    os.sched_setaffinity(0, {cpus[index % len(cpus)]})
    total = 0; data = b'x' * 65536
    while time.monotonic() < deadline:
        try: total += conn.send(data)
        except (BrokenPipeError, ConnectionResetError): break
    conn.close(); queue.put(total)
queue = mp.Queue()
workers = [mp.Process(target=send, args=(i, conn, queue)) for i, conn in enumerate(connections)]
for worker in workers: worker.start()
for conn in connections: conn.close()
for worker in workers: worker.join()
if any(worker.exitcode for worker in workers): raise SystemExit(1)
print(sum(queue.get() for _ in workers))
PY
server_pid=$!
sleep 0.2

client_bytes=$(ip netns exec "$client" python3 - "$mode" "$port" "$streams" "$cpus" <<'PY'
import multiprocessing as mp, os, socket, sys
mp.set_start_method('fork')
mode, port, streams = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
cpus = []
for part in sys.argv[4].split(','):
    if '-' in part:
        first, last = map(int, part.split('-', 1)); cpus.extend(range(first, last + 1))
    else: cpus.append(int(part))
def receive(index, queue):
    os.sched_setaffinity(0, {cpus[index % len(cpus)]})
    sock = socket.socket()
    if mode == 'independent':
        third, fourth = index // 254, index % 254 + 1
        sock.bind((f'10.243.{third}.{fourth}', 0))
    sock.connect(('10.242.0.1', port))
    total = 0
    while True:
        data = sock.recv(65536)
        if not data: break
        total += len(data)
    queue.put(total)
queue = mp.Queue()
workers = [mp.Process(target=receive, args=(i, queue)) for i in range(streams)]
for worker in workers: worker.start()
for worker in workers: worker.join()
if any(worker.exitcode for worker in workers): raise SystemExit(1)
print(sum(queue.get() for _ in workers))
PY
)
wait "$server_pid"
server_pid=
server_bytes=$(cat "$server_output")
[[ $client_bytes == "$server_bytes" ]]
printf 'mode=%s streams=%s seconds=%s bytes=%s throughput_bps=%s\n' \
  "$mode" "$streams" "$seconds" "$client_bytes" \
  "$((client_bytes * 8 / seconds))"
