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
! valid_rate 1e3

CONFIG="$tmp/missing-config"
load_config
[[ $IPV4_RATE == 80 && $IPV6_RATE == 80 && $MODE == auto && $MANAGED == 0 ]]

read_tty() { printf -v "$2" n; }
! confirm "cancel"
read_tty() { printf -v "$2" 7; }
menu_output=$(menu)
grep -q 'TCP Brutal Custom 管理器' <<<"$menu_output"

systemctl() { return 99; }
STOPPED_SERVICES=()
restore_proxy_services
unset -f systemctl

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
COMMIT=abcdef0123456789abcdef0123456789abcdef01
VERSION=2.1.0.custom.abcdef0
MANAGED=1
UNTRUSTED=$(false)
EOF
load_config
[[ $IPV4_RATE == 120 && $IPV6_RATE == 60 && $MODE == dual && $MANAGED == 1 ]]

cat >"$tmp/bad-config" <<'EOF'
IPV4_RATE=fast
IPV6_RATE=60
MODE=dual
COMMIT=
VERSION=
MANAGED=1
EOF
CONFIG="$tmp/bad-config"
! (load_config)

commands=()
enabled4=1
enabled6=0
modprobe() { return 0; }
family_enabled() { [[ $1 == 4 && $enabled4 == 1 || $1 == 6 && $enabled6 == 1 ]]; }
rule_line() { [[ $1 == ::/0 ]] && echo 'dst=::/0 rate=1 group=perip'; return 0; }
brutalctl() { commands+=("$*"); }
MANAGED=1
IPV4_RATE=80
IPV6_RATE=60
apply_configured_rules
[[ ${commands[*]} == 'add 0.0.0.0/0 80 noroute perip del ::/0' ]]

commands=()
rule_line() { [[ $1 == 0.0.0.0/0 ]] && echo 'dst=0.0.0.0/0 rate=1 group=shared'; return 0; }
! apply_configured_rules
[[ ${#commands[@]} == 0 ]]

dkms_calls=()
dkms() {
  if [[ $1 == status ]]; then
    printf '%s\n' \
      'tcp-brutal-custom/2.1.0.custom.1111111, 6.1.0, x86_64: installed' \
      'tcp-brutal-custom/2.1.0.custom.2222222, 6.1.0, x86_64: installed'
  else
    dkms_calls+=("$*")
  fi
}
removed_paths=()
rm() { removed_paths+=("$*"); }
PACKAGE=tcp-brutal-custom
STATE_DIR="$tmp/state"
VERSION=2.1.0.custom.2222222
remove_custom_dkms
[[ ${dkms_calls[0]} == 'remove -m tcp-brutal-custom -v 2.1.0.custom.1111111 --all' ]]
[[ ${dkms_calls[1]} == 'remove -m tcp-brutal-custom -v 2.1.0.custom.2222222 --all' ]]
unset -f rm dkms

failure_log="$tmp/install-failure.log"
CONFIG="$tmp/live-config"
MANAGER="$tmp/brutal-manager"
BRUTALCTL="$tmp/brutalctl"
SERVICE="$tmp/tcp-brutal-custom.service"
MODULES_LOAD="$tmp/modules-load.conf"
STATE_DIR="$tmp/state"
LEGACY_SERVICE="$tmp/legacy.service"
load_config() {
  IPV4_RATE=80; IPV6_RATE=80; MODE=auto
  COMMIT=1111111111111111111111111111111111111111
  VERSION=2.1.0.custom.1111111
  MANAGED=1
}
need_root() { return 0; }
check_platform() { return 0; }
confirm() { return 0; }
install_dependencies() { return 0; }
make() { return 0; }
download_source() {
  echo download >>"$failure_log"
  ((${DOWNLOAD_FAILURE:-0} == 0)) || return "$DOWNLOAD_FAILURE"
  mkdir -p "$1/source"
  echo 2222222222222222222222222222222222222222
}
source_version() { echo 2.1.0.custom.2222222; }
custom_version_installed() { [[ $1 == 2.1.0.custom.1111111 ]]; }
dkms() { echo "dkms $*" >>"$failure_log"; return 0; }
module_loaded() { return 0; }
stop_proxy_services() {
  STOPPED_SERVICES=(xray.service)
  echo stop >>"$failure_log"
  return "${STOP_FAILURE:-0}"
}
restore_proxy_services() {
  ((${#STOPPED_SERVICES[@]})) && echo restore >>"$failure_log"
  STOPPED_SERVICES=()
}
rmmod() { echo rmmod >>"$failure_log"; return "${RMMOD_FAILURE:-0}"; }
depmod() { return 0; }
modprobe() { return 0; }
install_manager() { return 0; }
write_service() { return 0; }
enable_boot() { echo enable >>"$failure_log"; return "${ENABLE_FAILURE:-0}"; }
remove_old_custom_dkms() { return 0; }
save_config() { echo save >>"$failure_log"; }
build_dkms() { echo build >>"$failure_log"; return "${BUILD_FAILURE:-0}"; }
apply_configured_rules() { echo apply >>"$failure_log"; return "${APPLY_FAILURE:-0}"; }

DOWNLOAD_FAILURE=12 BUILD_FAILURE=0 STOP_FAILURE=0 RMMOD_FAILURE=0 APPLY_FAILURE=0 ENABLE_FAILURE=0
set +e
install_or_update
rc=$?
set -e
[[ $rc == 12 ]]
! grep -q '^build$' "$failure_log"
! grep -q '^stop$' "$failure_log"

: >"$failure_log"
DOWNLOAD_FAILURE=0 BUILD_FAILURE=17
set +e
install_or_update
rc=$?
set -e
[[ $rc == 17 ]]
grep -q '^build$' "$failure_log"
! grep -q '^stop$' "$failure_log"
! grep -q '^save$' "$failure_log"

: >"$failure_log"
BUILD_FAILURE=0 STOP_FAILURE=14
set +e
install_or_update
rc=$?
set -e
[[ $rc == 14 ]]
grep -q '^stop$' "$failure_log"
grep -q '^restore$' "$failure_log"
! grep -q '^save$' "$failure_log"

: >"$failure_log"
STOP_FAILURE=0 RMMOD_FAILURE=15
set +e
install_or_update
rc=$?
set -e
[[ $rc == 1 ]]
grep -q '^restore$' "$failure_log"
! grep -q '^save$' "$failure_log"

: >"$failure_log"
RMMOD_FAILURE=0 APPLY_FAILURE=23
set +e
install_or_update
rc=$?
set -e
[[ $rc == 1 ]]
[[ $(grep -E '^(build|stop|apply|restore)$' "$failure_log" | paste -sd' ') == 'build stop apply apply restore' ]]
! grep -q '^save$' "$failure_log"

: >"$failure_log"
APPLY_FAILURE=0 ENABLE_FAILURE=24
set +e
install_or_update
rc=$?
set -e
[[ $rc == 24 ]]
grep -q '^save$' "$failure_log"
grep -q '^restore$' "$failure_log"

: >"$failure_log"
ENABLE_FAILURE=0
source_version() { echo 2.1.0.custom.1111111; }
install_or_update
! grep -q '^build$' "$failure_log"
! grep -q '^stop$' "$failure_log"
grep -q '^save$' "$failure_log"

if command -v script >/dev/null && command -v timeout >/dev/null; then
  output=$(printf '7\n' | timeout 5 script -qfec "cat '$repo/install.sh' | bash" /dev/null)
  grep -q 'TCP Brutal Custom 管理器' <<<"$output"
fi
echo 'install-manager tests passed'
