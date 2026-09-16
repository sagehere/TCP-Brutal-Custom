#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rules="$tmp/rules"
: >"$rules"

cc -O1 -g -Wall -Wextra -Werror -std=c99 -pedantic \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -DRULES_PATH=\"$rules\" -o "$tmp/brutalctl" "$repo/tools/brutalctl.c"

expect_fail() {
  if "$tmp/brutalctl" "$@" >"$tmp/out" 2>"$tmp/err"; then
    echo "unexpected success: brutalctl $*" >&2
    exit 1
  fi
}

expect_fail add 192.0.2.0/24 nan noroute
expect_fail add 192.0.2.0/24 NaN noroute
expect_fail add 192.0.2.0/24 inf noroute
expect_fail add 192.0.2.0/24 Infinity noroute
expect_fail add 192.0.2.0/24 1e999 noroute
expect_fail add 192.0.2.0/24 0 noroute
expect_fail add 192.0.2.0/24 -1 noroute
expect_fail add 192.0.2.0/24 1000000.1 noroute
expect_fail add "$(printf 'a%.0s' {1..200})" 80 noroute
expect_fail del "$(printf 'b%.0s' {1..400})"

expect_fail add 192.0.2.0/24 80 noroute maxpeers=1
expect_fail add 192.0.2.0/24 80 noroute perip maxpeers=-1
expect_fail add 192.0.2.0/24 80 noroute perip maxpeers=2147483648
expect_fail add 192.0.2.0/24 80 noroute perip maxpeers=1 maxpeers=2

: >"$rules"
"$tmp/brutalctl" add 192.0.2.0/24 80 noroute
grep -qx 'add 192.0.2.0/24 rate=10000000' "$rules"

: >"$rules"
"$tmp/brutalctl" add 2001:db8::/32 1000000 noroute gain=20 perip
grep -qx 'add 2001:db8::/32 rate=125000000000 gain=20 perip' "$rules"

: >"$rules"
"$tmp/brutalctl" add 198.51.100.0/24 80 noroute maxpeers=32 perip
grep -qx 'add 198.51.100.0/24 rate=10000000 maxpeers=32 perip' "$rules"

: >"$rules"
"$tmp/brutalctl" add 198.51.100.0/24 80 noroute perip maxpeers=0
grep -qx 'add 198.51.100.0/24 rate=10000000 perip maxpeers=0' "$rules"

echo 'brutalctl safety tests passed'
