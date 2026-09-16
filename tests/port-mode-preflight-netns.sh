#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }
repo=$(cd "$(dirname "$0")/.." && pwd)
ns="tbc-preflight-$$"
dev="tpf-$$"
cleanup() { ip netns del "$ns" 2>/dev/null || true; }
trap cleanup EXIT
test_cc=${TBC_TEST_CC:-brutal}

if [[ $test_cc != brutal ]]; then
  sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -qx "$test_cc" || {
    echo "unsupported test CC: $test_cc" >&2
    exit 1
  }
fi

ip netns add "$ns"
ip -n "$ns" link set lo up
ip -n "$ns" link add "$dev" type dummy
ip -n "$ns" addr add 198.18.0.2/24 dev "$dev"
ip -n "$ns" -6 addr add 2001:db8:18::2/64 dev "$dev" nodad
ip -n "$ns" link set "$dev" up
ip -n "$ns" route add default via 198.18.0.1 dev "$dev"
ip -n "$ns" -6 route add default via 2001:db8:18::1 dev "$dev"

ip netns exec "$ns" bash -s -- "$repo/install.sh" "$dev" "$test_cc" <<'INNER'
set -Eeuo pipefail
export BRUTAL_MANAGER_LIB=1
source "$1"
dev=$2
test_cc=$3
if [[ $test_cc != brutal ]]; then
  clone_port_route() {
    local family=$1 line=$2 clean
    local -a args=()
    clean=$(sanitize_route_line "$line")
    [[ -n $clean ]] || return 0
    read -r -a args <<<"$clean"
    case $clean in
      blackhole*|unreachable*|prohibit*|throw*) ip "-$family" route replace table "$PORT_TABLE" "${args[@]}" ;;
      *) ip "-$family" route replace table "$PORT_TABLE" "${args[@]}" congctl lock "$test_cc" ;;
    esac
  }
fi
MODE=auto
TCP_PORTS=5211

table233_json() {
  local family=$1 out
  if ! out=$(ip "-$family" -j route show table 233 2>/dev/null); then
    out='[]'
  fi
  [[ -n $out ]] || out='[]'
  printf '%s' "$out"
}

rules4_before=$(ip -4 -j rule show)
rules6_before=$(ip -6 -j rule show)
routes4_before=$(table233_json 4)
routes6_before=$(table233_json 6)
apply_port_rules 1
[[ $(ip -4 -j rule show) == "$rules4_before" ]]
[[ $(ip -6 -j rule show) == "$rules6_before" ]]
[[ $(table233_json 4) == "$routes4_before" ]]
[[ $(table233_json 6) == "$routes6_before" ]]

ip -4 rule add priority 100 fwmark 0x1 lookup 100
if apply_port_rules 1 >/tmp/tbc-preflight-out 2>/tmp/tbc-preflight-err; then
  echo "fwmark preflight unexpectedly succeeded" >&2
  exit 1
fi
grep -q '自定义策略路由规则' /tmp/tbc-preflight-err
ip -4 rule del priority 100

ip -4 rule add priority 12000 lookup main
if apply_port_rules 1 >/tmp/tbc-preflight-out 2>/tmp/tbc-preflight-err; then
  echo "reserved priority conflict unexpectedly succeeded" >&2
  exit 1
fi
grep -q '保留区域存在非受管规则' /tmp/tbc-preflight-err
ip -4 rule del priority 12000

# Duplicate defaults that resolve to the same gateway/device are common on cloud VPSes.
ip -4 route add default via 198.18.0.1 dev "$dev" metric 100
apply_port_rules 1
apply_port_rules
rules4_applied=$(ip -4 rule show)
routes4_applied=$(ip -4 route show table 233)
grep -Eq '^12000:.*ipproto tcp.*sport 5211.*lookup 233' <<<"$rules4_applied"
grep -q '^default ' <<<"$routes4_applied"
reset_port_policy
[[ $(ip -4 -j rule show) == "$rules4_before" ]]
[[ $(ip -6 -j rule show) == "$rules6_before" ]]
[[ $(table233_json 4) == "$routes4_before" ]]
[[ $(table233_json 6) == "$routes6_before" ]]
ip -4 route del default via 198.18.0.1 dev "$dev" metric 100

# Distinct default paths remain fail-closed (dual-WAN / multiple uplinks).
alt=tbc-alt0
ip link add "$alt" type dummy
ip addr add 198.19.0.2/24 dev "$alt"
ip link set "$alt" up
ip -4 route add default via 198.19.0.1 dev "$alt" metric 200
if apply_port_rules 1 >/tmp/tbc-preflight-out 2>/tmp/tbc-preflight-err; then
  echo "distinct-default preflight unexpectedly succeeded" >&2
  exit 1
fi
grep -q '多个默认路由' /tmp/tbc-preflight-err
ip -4 route del default via 198.19.0.1 dev "$alt" metric 200
ip link del "$alt"

ip -4 route add 203.0.113.0/24 \
  nexthop via 198.18.0.1 dev "$dev" weight 1 \
  nexthop via 198.18.0.3 dev "$dev" weight 1
if apply_port_rules 1 >/tmp/tbc-preflight-out 2>/tmp/tbc-preflight-err; then
  echo "multipath preflight unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'multipath/nhid/encap' /tmp/tbc-preflight-err
ip -4 route del 203.0.113.0/24

if ip link add tbc-vrf-test type vrf table 1001 2>/dev/null; then
  if apply_port_rules 1 >/tmp/tbc-preflight-out 2>/tmp/tbc-preflight-err; then
    echo "VRF preflight unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Eq 'VRF|自定义策略路由规则' /tmp/tbc-preflight-err
  ip link del tbc-vrf-test
  ip -4 rule del priority 1000 2>/dev/null || true
  ip -6 rule del priority 1000 2>/dev/null || true
fi

apply_port_rules
before_rules4=$(ip -4 -j rule show)
before_rules6=$(ip -6 -j rule show)
before_routes4=$(table233_json 4)
before_routes6=$(table233_json 6)

sync_port_table_family() { return 1; }
TCP_PORTS=5212
if apply_port_rules >/tmp/tbc-preflight-out 2>/tmp/tbc-preflight-err; then
  echo "injected failure unexpectedly succeeded" >&2
  exit 1
fi
[[ $(ip -4 -j rule show) == "$before_rules4" ]]
[[ $(ip -6 -j rule show) == "$before_rules6" ]]
[[ $(table233_json 4) == "$before_routes4" ]]
[[ $(table233_json 6) == "$before_routes6" ]]

echo "port-mode preflight/rollback netns test passed"
INNER
