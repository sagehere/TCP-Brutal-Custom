#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
module=${1:-$repo/brutal.ko}
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
peers=${PEERS:-64}
fault_attempts=${FAULT_ATTEMPTS:-40}
wait_steps=${PEER_WAIT_STEPS:-300}

(( peers > 32 )) || { echo "PEERS must exceed the 32-object peer mempool reserve" >&2; exit 1; }
(( fault_attempts > 32 )) || { echo "FAULT_ATTEMPTS must exceed 32 to force fallback" >&2; exit 1; }
[[ -f $module ]] || { echo "module not found: $module" >&2; exit 1; }

suffix=$$
server="brutal-fault-s-$suffix"
client="brutal-fault-c-$suffix"
server_dev="bfs-$suffix"
client_dev="bfc-$suffix"
port=$((30000 + suffix % 2000))
cache=/sys/kernel/slab/tcp_brutal_peer
failslab=/sys/kernel/debug/failslab
server_pid=
client_pid=

fault_off() {
  set +e
  if [[ -d $failslab ]]; then
    echo 0 >"$failslab/probability" 2>/dev/null || true
    echo 0 >"$failslab/times" 2>/dev/null || true
    echo N >"$failslab/cache-filter" 2>/dev/null || true
    echo N >"$failslab/task-filter" 2>/dev/null || true
  fi
  if [[ -e $cache/failslab ]]; then
    echo 0 >"$cache/failslab" 2>/dev/null || true
  fi
}

cleanup() {
  set +e
  fault_off
  [[ -n $client_pid ]] && kill "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true
  [[ -n $client_pid ]] && wait "$client_pid" 2>/dev/null || true
  [[ -n $server_pid ]] && wait "$server_pid" 2>/dev/null || true
  ip netns del "$client" 2>/dev/null || true
  ip netns del "$server" 2>/dev/null || true
  if grep -q '^brutal ' /proc/modules 2>/dev/null; then
    rmmod brutal 2>/dev/null || true
  fi
}
trap cleanup EXIT

make -C "$repo/tools" brutalctl
if ! mountpoint -q /sys/kernel/debug; then
  mount -t debugfs debugfs /sys/kernel/debug
fi

dmesg -C 2>/dev/null || true
insmod "$module"
grep -q '^brutal ' /proc/modules

ip netns add "$server"
ip netns add "$client"
ip link add "$server_dev" type veth peer name "$client_dev"
ip link set "$server_dev" netns "$server"
ip link set "$client_dev" netns "$client"
ip -n "$server" addr add 10.218.0.1/24 dev "$server_dev"
ip -n "$client" addr add 10.218.0.2/24 dev "$client_dev"
ip -n "$server" link set lo up
ip -n "$client" link set lo up
ip -n "$server" link set "$server_dev" up
ip -n "$client" link set "$client_dev" up
ip -n "$client" route add local 10.219.0.0/16 dev lo table local
ip -n "$server" route add 10.219.0.0/16 via 10.218.0.2 dev "$server_dev"
ip netns exec "$server" "$ctl" add 10.219.0.0/16 100 noroute perip

[[ -d $failslab ]] || { echo "failslab debugfs controls are unavailable" >&2; exit 1; }
[[ -d $cache ]] || { echo "tcp_brutal_peer slab cache is unavailable" >&2; exit 1; }
[[ ! -L $cache ]] || {
  echo "tcp_brutal_peer cache is merged; boot the guest with slab_nomerge" >&2
  exit 1
}
[[ -w $cache/failslab ]] || { echo "tcp_brutal_peer failslab selector is unavailable" >&2; exit 1; }
[[ -w $failslab/task-filter ]] || { echo "failslab task-filter control is unavailable" >&2; exit 1; }

# Mark only the peer cache, then enable deterministic allocation failures. The
# module's 32-object mempool reserve was populated before injection starts.
# Disable task filtering explicitly: virtme guests may leave it enabled, which
# otherwise requires setting /proc/<pid>/make-it-fail for the allocating task.
echo 0 >"$failslab/probability"
echo N >"$failslab/task-filter"
echo 1 >"$cache/failslab"
echo Y >"$failslab/cache-filter"
echo 1 >"$failslab/interval"
echo "$fault_attempts" >"$failslab/times"
echo 0 >"$failslab/space"
echo 1 >"$failslab/verbose"
echo 100 >"$failslab/probability"

ip netns exec "$server" python3 - "$peers" "$port" <<'PY' &
import socket, sys, time
count, port = map(int, sys.argv[1:])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("10.218.0.1", port))
srv.listen(256)
connections = []
for _ in range(count):
    conn, _ = srv.accept()
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"brutal")
    connections.append(conn)
while True:
    time.sleep(1)
PY
server_pid=$!
sleep 1

ip netns exec "$client" python3 - "$peers" "$port" <<'PY' &
import socket, sys, time
count, port = map(int, sys.argv[1:])
IP_FREEBIND = 15
connections = []
for i in range(count):
    third = (i // 254) & 0xff
    fourth = (i % 254) + 1
    source = f"10.219.{third}.{fourth}"
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
    s.bind((source, 0))
    s.connect(("10.218.0.1", port))
    connections.append(s)
while True:
    time.sleep(1)
PY
client_pid=$!

active=0
fallback=0
alloc_fail=0
insert_fail=0
for _ in $(seq 1 "$wait_steps"); do
  stats=$(ip netns exec "$server" cat /proc/net/tcp_brutal/stats)
  active=$(awk -F= '/^active_peer_groups=/{print $2}' <<<"$stats")
  fallback=$(awk -F= '/^peer_fallback_connections=/{print $2}' <<<"$stats")
  alloc_fail=$(awk -F= '/^peer_alloc_failures=/{print $2}' <<<"$stats")
  insert_fail=$(awk -F= '/^peer_insert_failures=/{print $2}' <<<"$stats")
  if (( active + fallback >= peers && fallback > 0 )); then
    break
  fi
  sleep 0.1
done

printf 'fault stats: peers=%d active=%d alloc_failures=%d fallbacks=%d insert_failures=%d\n' \
  "$peers" "$active" "$alloc_fail" "$fallback" "$insert_fail"
(( alloc_fail > 0 )) || { echo "fault injection did not reach peer allocation failure" >&2; exit 1; }
(( fallback > 0 )) || { echo "peer allocation failures did not use fallback pacers" >&2; exit 1; }
(( active > 0 && active < peers )) || { echo "unexpected active peer count under allocation faults" >&2; exit 1; }
(( active + fallback >= peers )) || { echo "not all peer connections reached Brutal grouping" >&2; exit 1; }
(( insert_fail == 0 )) || { echo "unexpected peer hash insertion failures" >&2; exit 1; }

fault_off
kill "$client_pid" "$server_pid" 2>/dev/null || true
wait "$client_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
client_pid=
server_pid=

for _ in $(seq 1 "$wait_steps"); do
  active=$(ip netns exec "$server" awk -F= '/^active_peer_groups=/{print $2}' /proc/net/tcp_brutal/stats)
  [[ $active -eq 0 ]] && break
  sleep 0.1
done
[[ ${active:-0} -eq 0 ]] || { echo "peer groups did not drain after fault test: active=$active" >&2; exit 1; }

ip netns del "$client"
ip netns del "$server"
rmmod brutal
trap - EXIT

log=$(dmesg 2>/dev/null || true)
printf '%s\n' "$log"
grep -q 'FAULT_INJECTION: forcing a failure' <<<"$log" || {
  echo "failslab did not record a forced allocation failure" >&2
  exit 1
}
if grep -Eiq \
  'BUG: KASAN|possible circular locking dependency|inconsistent lock state|bad unlock balance|held lock freed|suspicious RCU usage|sleeping function called from invalid context|deadlock|use-after-free|slab-out-of-bounds|refcount_t:|rcu[^:]*stall|kernel BUG|NULL pointer dereference|general protection fault|Oops:' \
  <<<"$log"; then
  echo "debug kernel reported a safety failure during peer allocation faults" >&2
  exit 1
fi

echo "peer allocation fault-injection test passed"
