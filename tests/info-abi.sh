#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
ctl=${BRUTALCTL:-$repo/tools/brutalctl}
[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }
grep -q '^brutal ' /proc/modules || { echo "brutal module is not loaded" >&2; exit 1; }

cc -O2 -Wall -Wextra -Werror -std=c99 -o /tmp/brutal-info-abi "$repo/tests/info-abi.c"
/tmp/brutal-info-abi
make -C "$repo/tools" brutalctl

info=$($ctl info)
grep -q '^version=2[.]5[.]3$' <<<"$info"
grep -q '^vendor=tcp-brutal-custom$' <<<"$info"
grep -q '^abi=1$' <<<"$info"
grep -Eq '^build=[0-9a-f]{40}$' <<<"$info"
grep -Eq '^capabilities=0x[0-9a-f]{16}$' <<<"$info"
grep -q '^capability_names=perip,netns,exact-rule-hash,peer-stats,tc-aggregate-manager,peer-budget,prefix-index,kernel-aggregate,genl$' <<<"$info"

proc_info=$(cat /proc/net/tcp_brutal/version)
grep -q '^version=2[.]5[.]3$' <<<"$proc_info"
grep -q '^vendor=tcp-brutal-custom$' <<<"$proc_info"
grep -q '^abi=1$' <<<"$proc_info"
[[ $(sed -n 's/^build=//p' <<<"$info") == $(sed -n 's/^build=//p' <<<"$proc_info") ]]
[[ $(sed -n 's/^capabilities=//p' <<<"$info") == $(sed -n 's/^capabilities=//p' <<<"$proc_info") ]]

python3 - <<'PY'
import errno, socket, struct
TCP_BRUTAL_INFO = 23303
EXPECTED_CAPS = 0x1ff
for family in (socket.AF_INET, socket.AF_INET6):
    if family == socket.AF_INET6 and not socket.has_ipv6:
        continue
    s = socket.socket(family, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"brutal")
        try:
            s.getsockopt(socket.IPPROTO_TCP, TCP_BRUTAL_INFO, 63)
        except OSError as e:
            assert e.errno == errno.EINVAL, e
        else:
            raise AssertionError("short TCP_BRUTAL_INFO buffer unexpectedly succeeded")
        raw = s.getsockopt(socket.IPPROTO_TCP, TCP_BRUTAL_INFO, 64)
        assert len(raw) == 64, len(raw)
        size, abi, vendor, version, flags, caps = struct.unpack_from("=HHIIIQ", raw)
        assert size == 64 and abi == 1 and vendor == 1
        assert version == (2 << 16 | 5 << 8 | 3)
        assert flags == 0 and caps == EXPECTED_CAPS, hex(caps)
        build = raw[24:64].decode("ascii")
        assert len(build) == 40 and all(c in "0123456789abcdef" for c in build)
    finally:
        s.close()
PY

ns="brutal-info-$$"
trap 'ip netns del "$ns" 2>/dev/null || true' EXIT
ip netns add "$ns"
ip -n "$ns" link set lo up
ip netns exec "$ns" test -r /proc/net/tcp_brutal/version
ns_info=$(ip netns exec "$ns" "$ctl" info)
[[ $(sed -n 's/^build=//p' <<<"$ns_info") == $(sed -n 's/^build=//p' <<<"$info") ]]
[[ $(sed -n 's/^capabilities=//p' <<<"$ns_info") == $(sed -n 's/^capabilities=//p' <<<"$info") ]]
ip netns del "$ns"
trap - EXIT

echo "brutal info ABI test passed"
