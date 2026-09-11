#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-4 -o addr show scope global") echo '2: eth0 inet 198.51.100.2/24 scope global eth0' ;;
  "-4 route show default") echo 'default via 198.51.100.1 dev eth0' ;;
  "-6 -o addr show scope global") [[ ${TEST_IPV6_GLOBAL:-0} == 1 ]] && echo '2: eth0 inet6 2001:db8::2/64 scope global' ;;
  "-6 route show default") [[ ${TEST_IPV6_ROUTE:-0} == 1 ]] && echo 'default via 2001:db8::1 dev eth0' ;;
esac
EOF
chmod +x "$tmp/bin/ip"

export PATH="$tmp/bin:$PATH"
export BRUTAL_MANAGER_LIB=1
# shellcheck disable=SC1090
source "$repo/install.sh"

valid_rate .5
valid_rate 1000000
! valid_rate .49
! valid_rate 1000000.1

MODE=auto
family_enabled 4
! family_enabled 6
TEST_IPV6_GLOBAL=1 TEST_IPV6_ROUTE=1 family_enabled 6
MODE=ipv4
family_enabled 4
! family_enabled 6
MODE=dual
TEST_IPV6_GLOBAL=1 family_enabled 6

CONFIG="$tmp/config"
cat >"$CONFIG" <<'EOF'
IPV4_RATE=120
IPV6_RATE=60
MODE=dual
COMMIT=abcdef0
VERSION=2.1.0.custom.abcdef0
MANAGED=1
UNTRUSTED=$(false)
EOF
load_config
[[ $IPV4_RATE == 120 && $IPV6_RATE == 60 && $MODE == dual && $MANAGED == 1 ]]
echo 'install-manager tests passed'
