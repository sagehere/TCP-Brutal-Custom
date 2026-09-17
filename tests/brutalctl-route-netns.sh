#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
ns=tbc-route-$RANDOM-$$
trap 'ip netns del "$ns" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
rules="$tmp/rules"
: >"$rules"
test_cc=${TBC_TEST_CC:-brutal}
real_ip=$(command -v ip)

run_ctl() {
  "$real_ip" netns exec "$ns" env PATH="$tmp:$PATH" "$tmp/brutalctl" "$@"
}

if [[ $test_cc != brutal ]]; then
  sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -qx "$test_cc" || {
    echo "unsupported test CC: $test_cc" >&2
    exit 1
  }
  cat >"$tmp/ip" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  if [[ \${args[i]} == congctl ]]; then
    j=\$((i + 1))
    [[ \${args[j]:-} == lock ]] && j=\$((j + 1))
    [[ \${args[j]:-} == brutal ]] && args[j]="$test_cc"
    break
  fi
done
exec "$real_ip" "\${args[@]}"
EOF
  chmod +x "$tmp/ip"
fi

cc -O2 -Wall -Wextra -Werror -std=c99 -pedantic \
  -DRULES_PATH=\"$rules\" -o "$tmp/brutalctl" \
  "$repo/tools/brutalctl.c" "$repo/tools/brutal_netlink.c"
ip netns add "$ns"
ip -n "$ns" link set lo up
ip -n "$ns" link add dummy0 type dummy
ip -n "$ns" addr add 198.51.100.2/24 dev dummy0
ip -n "$ns" link set dummy0 up
ip -n "$ns" route add default via 198.51.100.1 dev dummy0

ip -n "$ns" route add 192.0.2.0/24 via 198.51.100.1 dev dummy0 proto static metric 77
before=$(ip -n "$ns" -j route show exact 192.0.2.0/24)
set +e
run_ctl add 192.0.2.0/24 80 >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[[ $rc -ne 0 ]]
after=$(ip -n "$ns" -j route show exact 192.0.2.0/24)
[[ $before == "$after" ]]
[[ ! -s $rules ]]
grep -q 'refusing to replace existing route' "$tmp/err"

ip -n "$ns" route del 192.0.2.0/24 proto static metric 77
run_ctl add 192.0.2.0/24 80
ip -n "$ns" -N route show exact 192.0.2.0/24 | grep -q 'proto 233'
run_ctl del 192.0.2.0/24
! ip -n "$ns" -N route show exact 192.0.2.0/24 | grep -q .

echo 'brutalctl real netns route ownership tests passed'
