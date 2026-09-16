#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }
repo=$(cd "$(dirname "$0")/.." && pwd)
ns="tbc-agg-$$"
state=$(mktemp -d)

cleanup() {
  ip netns del "$ns" >/dev/null 2>&1 || true
  rm -rf "$state"
}
trap cleanup EXIT

ip netns add "$ns"
ip -n "$ns" link add d0 type dummy
ip -n "$ns" addr add 198.18.0.2/24 dev d0
ip -n "$ns" link set lo up
ip -n "$ns" link set d0 up
ip -n "$ns" route add default via 198.18.0.1 dev d0
ip netns exec "$ns" tc qdisc replace dev d0 root fq

root_json() {
  ip netns exec "$ns" tc -j qdisc show dev d0 |
    python3 -c 'import json,sys; print(json.dumps([x for x in json.load(sys.stdin) if x.get("root")],sort_keys=True))'
}
root_before=$(root_json)

ip netns exec "$ns" bash -c '
  set -Eeuo pipefail
  export BRUTAL_MANAGER_LIB=1
  source "$1"
  STATE_DIR=$2
  AGGREGATE_STATE="$STATE_DIR/aggregate-egress.state"
  MODE=ipv4
  AGGREGATE_RATE=80
  apply_aggregate_cap 1
  apply_aggregate_cap
  aggregate_filter_owned d0
' _ "$repo/install.sh" "$state"

[[ $(root_json) == "$root_before" ]]
ip netns exec "$ns" tc filter show dev d0 egress pref 23300 | grep 'handle 0x233' >/dev/null
ip netns exec "$ns" tc filter show dev d0 egress pref 23300 | grep 'rate 80Mbit' >/dev/null

ip netns exec "$ns" bash -c '
  set -Eeuo pipefail
  export BRUTAL_MANAGER_LIB=1
  source "$1"
  STATE_DIR=$2
  AGGREGATE_STATE="$STATE_DIR/aggregate-egress.state"
  MODE=ipv4
  AGGREGATE_RATE=0
  apply_aggregate_cap
' _ "$repo/install.sh" "$state"

! ip netns exec "$ns" tc filter show dev d0 egress pref 23300 2>/dev/null | grep . >/dev/null
[[ $(root_json) == "$root_before" ]]

# Existing egress filters must block automatic aggregate shaping without mutation.
ip netns exec "$ns" tc qdisc show dev d0 | grep '^qdisc clsact ' >/dev/null || ip netns exec "$ns" tc qdisc add dev d0 clsact
ip netns exec "$ns" tc filter add dev d0 egress pref 100 protocol all matchall action pass
filters_before=$(ip netns exec "$ns" tc -j filter show dev d0 egress)
set +e
ip netns exec "$ns" bash -c '
  set -Eeuo pipefail
  export BRUTAL_MANAGER_LIB=1
  source "$1"
  STATE_DIR=$2
  AGGREGATE_STATE="$STATE_DIR/aggregate-egress.state"
  MODE=ipv4
  AGGREGATE_RATE=80
  apply_aggregate_cap 1
' _ "$repo/install.sh" "$state" >/tmp/tbc-agg-out 2>/tmp/tbc-agg-err
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q '已存在其他 egress tc filter' /tmp/tbc-agg-err
[[ $(ip netns exec "$ns" tc -j filter show dev d0 egress) == "$filters_before" ]]
ip netns exec "$ns" tc filter del dev d0 egress pref 100

# Reserved preference owned by somebody else must be rejected.
ip netns exec "$ns" tc filter add dev d0 egress pref 23300 protocol all handle 0x999 matchall action pass
set +e
ip netns exec "$ns" bash -c '
  set -Eeuo pipefail
  export BRUTAL_MANAGER_LIB=1
  source "$1"
  STATE_DIR=$2
  AGGREGATE_STATE="$STATE_DIR/aggregate-egress.state"
  MODE=ipv4
  AGGREGATE_RATE=80
  apply_aggregate_cap 1
' _ "$repo/install.sh" "$state" >/tmp/tbc-agg-out 2>/tmp/tbc-agg-err
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q 'pref 23300 已被其他配置占用' /tmp/tbc-agg-err
ip netns exec "$ns" tc filter del dev d0 egress pref 23300

# More than one default egress device cannot represent a single aggregate cap.
ip -n "$ns" link add d1 type dummy
ip -n "$ns" addr add 203.0.113.2/24 dev d1
ip -n "$ns" link set d1 up
ip -n "$ns" route add default via 203.0.113.1 dev d1 metric 200
set +e
ip netns exec "$ns" bash -c '
  set -Eeuo pipefail
  export BRUTAL_MANAGER_LIB=1
  source "$1"
  STATE_DIR=$2
  AGGREGATE_STATE="$STATE_DIR/aggregate-egress.state"
  MODE=ipv4
  AGGREGATE_RATE=80
  apply_aggregate_cap 1
' _ "$repo/install.sh" "$state" >/tmp/tbc-agg-out 2>/tmp/tbc-agg-err
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q '多个出口接口' /tmp/tbc-agg-err

echo "aggregate egress netns test passed"
