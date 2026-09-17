#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
rules="$tmp/rules"
log="$tmp/ip.log"
: >"$rules"
: >"$log"

cat >"$tmp/bin/ip" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$IP_LOG"
case "$*" in
  "-N -4 route show exact 192.0.2.0/24")
    case ${ROUTE_MODE:-none} in
      none) ;;
      ours) echo '192.0.2.0/24 via 198.51.100.1 dev eth0 proto 233' ;;
      foreign) echo '192.0.2.0/24 via 198.51.100.9 dev eth9 proto 4 metric 77' ;;
      mixed)
        echo '192.0.2.0/24 via 198.51.100.1 dev eth0 proto 233'
        echo '192.0.2.0/24 via 198.51.100.9 dev eth9 proto 4 metric 77'
        ;;
    esac
    ;;
  "-4 route get 192.0.2.0") echo '192.0.2.0 via 198.51.100.1 dev eth0 src 198.51.100.2' ;;
  "-4 route add 192.0.2.0/24 via 198.51.100.1 dev eth0 congctl lock brutal proto 233") ;;
  "-4 route replace 192.0.2.0/24 via 198.51.100.1 dev eth0 congctl lock brutal proto 233") ;;
  "-4 route del 192.0.2.0/24 proto 233") ;;
  "-4 route flush proto 233"|"-6 route flush proto 233") ;;
  *) echo "unexpected ip call: $*" >&2; exit 99 ;;
esac
MOCK
chmod +x "$tmp/bin/ip"

cc -O2 -Wall -Wextra -Werror -std=c99 -pedantic \
  -DRULES_PATH=\"$rules\" -o "$tmp/brutalctl" \
  "$repo/tools/brutalctl.c" "$repo/tools/brutal_netlink.c"
export PATH="$tmp/bin:$PATH" IP_LOG="$log"

: >"$rules"; : >"$log"
ROUTE_MODE=none "$tmp/brutalctl" add 192.0.2.0/24 80
grep -qx 'add 192.0.2.0/24 rate=10000000' "$rules"
grep -qx -- '-4 route add 192.0.2.0/24 via 198.51.100.1 dev eth0 congctl lock brutal proto 233' "$log"
! grep -q 'route replace' "$log"

: >"$rules"; : >"$log"
ROUTE_MODE=ours "$tmp/brutalctl" add 192.0.2.0/24 80
grep -qx 'add 192.0.2.0/24 rate=10000000' "$rules"
grep -qx -- '-4 route replace 192.0.2.0/24 via 198.51.100.1 dev eth0 congctl lock brutal proto 233' "$log"

for mode in foreign mixed; do
  : >"$rules"; : >"$log"
  if ROUTE_MODE=$mode "$tmp/brutalctl" add 192.0.2.0/24 80 >"$tmp/out" 2>"$tmp/err"; then
    echo "foreign route was unexpectedly replaced ($mode)" >&2
    exit 1
  fi
  [[ ! -s $rules ]]
  grep -q 'refusing to replace existing route' "$tmp/err"
  ! grep -Eq 'route (add|replace)' "$log"
done

: >"$rules"; : >"$log"
printf 'existing\n' >"$rules"
ROUTE_MODE=foreign "$tmp/brutalctl" del 192.0.2.0/24
grep -qx 'del 192.0.2.0/24' "$rules"
grep -qx -- '-4 route del 192.0.2.0/24 proto 233' "$log"

: >"$rules"; : >"$log"
ROUTE_MODE=foreign "$tmp/brutalctl" add 192.0.2.0/24 80 noroute
grep -qx 'add 192.0.2.0/24 rate=10000000' "$rules"
grep -qx -- '-4 route del 192.0.2.0/24 proto 233' "$log"
! grep -q -- '-N -4 route show exact' "$log"

echo 'brutalctl route ownership tests passed'
