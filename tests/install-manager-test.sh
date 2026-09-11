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

cat >"$tmp/bin/brutalctl" <<'EOF'
#!/usr/bin/env bash
echo old-path-tool
EOF
cat >"$tmp/fixed-brutalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
EOF
chmod +x "$tmp/bin/brutalctl" "$tmp/fixed-brutalctl"

export PATH="$tmp/bin:$PATH"
export BRUTAL_MANAGER_LIB=1
# shellcheck disable=SC1090
source "$repo/install.sh"

! grep -Eqi 'x-ui|xray|3x-ui|vless|xhttp' "$repo/install.sh"

(
  need_root() { return 0; }
  BRUTALCTL="$tmp/fixed-brutalctl"
  PEERS_PROC="$tmp/peers"
  PENDING_REBOOT="$tmp/no-pending-reboot"
  [[ $(view) == peers ]]
  mkdir -p "$tmp/view-state"
  printf '%s\n' 2.1.0.custom.2222222 >"$tmp/view-state/reboot-required"
  PENDING_REBOOT="$tmp/view-state/reboot-required"
  ! view >"$tmp/view-output" 2>"$tmp/view-error"
  grep -q '更新已暂存.*2.1.0.custom.2222222.*请重启服务器' "$tmp/view-error"
  set +e
  (view unexpected >/dev/null 2>&1)
  rc=$?
  set -e
  [[ $rc == 1 ]]
)

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
read_tty() { printf -v "$2" 0; }
menu_output=$(menu)
grep -q 'TCP Brutal Custom 管理器' <<<"$menu_output"

(
  have() { return 0; }
  kernel_headers_installed() { return 0; }
  ca_certificates_installed() { return 0; }
  clang_kernel() { return 1; }
  libc_headers_installed() { return 0; }
  apt-get() { return 99; }
  install_dependencies
)

dependency_log="$tmp/dependencies.log"
(
  installed=0
  have() { ((installed)); }
  kernel_headers_installed() { ((installed)); }
  ca_certificates_installed() { ((installed)); }
  clang_kernel() { return 1; }
  libc_headers_installed() { ((installed)); }
  apt-get() {
    printf '%s\n' "$*" >>"$dependency_log"
    [[ $1 == install ]] && installed=1
    return 0
  }
  install_dependencies
)
[[ $(grep -c '^update$' "$dependency_log") == 1 ]]
grep -q '^install -y --no-install-recommends .*dkms.*curl.*iproute2.*make.*tar.*gcc.*libc6-dev.*linux-headers-' "$dependency_log"

llvm_log="$tmp/llvm-dependencies.log"
(
  installed=0
  have() {
    case $1 in clang|ld.lld|llvm-objcopy) ((installed)) ;; *) return 0 ;; esac
  }
  kernel_headers_installed() { return 0; }
  ca_certificates_installed() { return 0; }
  clang_kernel() { return 0; }
  libc_headers_installed() { return 0; }
  apt-get() {
    printf '%s\n' "$*" >>"$llvm_log"
    [[ $1 == install ]] && installed=1
    return 0
  }
  install_dependencies
)
grep -q '^install -y --no-install-recommends clang lld llvm$' "$llvm_log"

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
BRUTALCTL=brutalctl
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
PENDING_REBOOT="$STATE_DIR/reboot-required"
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
PENDING_REBOOT="$STATE_DIR/reboot-required"
PEERS_PROC="$tmp/peers-proc"
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
dkms() {
  if [[ $1 == status && ${UPSTREAM_PRESENT:-0} == 1 ]]; then
    echo 'tcp-brutal/1.2.0, 6.1.0, x86_64: installed'
  fi
  echo "dkms $*" >>"$failure_log"
  return 0
}
module_loaded() { return 0; }
rmmod() { echo rmmod >>"$failure_log"; return "${RMMOD_FAILURE:-0}"; }
depmod() { return 0; }
modprobe() { return 0; }
install_manager() { echo install-manager >>"$failure_log"; }
write_service() { echo write-service >>"$failure_log"; }
enable_boot() { echo enable >>"$failure_log"; return "${ENABLE_FAILURE:-0}"; }
enable_boot_deferred() { echo enable-deferred >>"$failure_log"; return "${DEFER_FAILURE:-0}"; }
mark_pending_reboot() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$VERSION" >"$PENDING_REBOOT"
  echo mark-pending >>"$failure_log"
}
module_supports_peers() { [[ ${SUPPORTS_PEERS:-1} == 1 ]]; }
remove_old_custom_dkms() { return 0; }
save_config() { echo save >>"$failure_log"; }
build_dkms() { echo build >>"$failure_log"; return "${BUILD_FAILURE:-0}"; }
apply_configured_rules() { echo apply >>"$failure_log"; return "${APPLY_FAILURE:-0}"; }

DOWNLOAD_FAILURE=12 BUILD_FAILURE=0 RMMOD_FAILURE=0 APPLY_FAILURE=0 ENABLE_FAILURE=0 DEFER_FAILURE=0 UPSTREAM_PRESENT=0 SUPPORTS_PEERS=1
set +e
install_or_update
rc=$?
set -e
[[ $rc == 12 ]]
! grep -q '^build$' "$failure_log"
! grep -q '^rmmod$' "$failure_log"

: >"$failure_log"
DOWNLOAD_FAILURE=0 BUILD_FAILURE=17
set +e
install_or_update
rc=$?
set -e
[[ $rc == 17 ]]
grep -q '^build$' "$failure_log"
! grep -q '^rmmod$' "$failure_log"
! grep -q '^save$' "$failure_log"

: >"$failure_log"
BUILD_FAILURE=0 RMMOD_FAILURE=15
DEFER_FAILURE=19
set +e
install_or_update
rc=$?
set -e
[[ $rc == 19 ]]
grep -q '^enable-deferred$' "$failure_log"
grep -q '^dkms install -m tcp-brutal-custom -v 2.1.0.custom.1111111 .* --force$' "$failure_log"
! grep -q '^mark-pending$' "$failure_log"
[[ ! -e $PENDING_REBOOT ]]

: >"$failure_log"
DEFER_FAILURE=0
set +e
install_or_update
rc=$?
set -e
[[ $rc == 0 ]]
[[ $(grep -c '^rmmod$' "$failure_log") == 1 ]]
[[ $(grep -E '^(build|dkms install|install-manager|write-service|rmmod|save|mark-pending|enable-deferred)' "$failure_log" | paste -sd' ') == 'build dkms install -m tcp-brutal-custom -v 2.1.0.custom.2222222 install-manager write-service rmmod save enable-deferred mark-pending' ]]
[[ $(cat "$PENDING_REBOOT") == 2.1.0.custom.2222222 ]]
grep -q '^dkms install -m tcp-brutal-custom -v 2.1.0.custom.2222222$' "$failure_log"
! grep -q '^apply$' "$failure_log"
! grep -q '^enable$' "$failure_log"

: >"$failure_log"
rm -f "$PENDING_REBOOT"
UPSTREAM_PRESENT=1
set +e
install_or_update
rc=$?
set -e
[[ $rc == 1 ]]
[[ $(grep -c '^rmmod$' "$failure_log") == 1 ]]
! grep -q '^mark-pending$' "$failure_log"
! grep -q '^enable-deferred$' "$failure_log"
[[ ! -e $PENDING_REBOOT ]]
UPSTREAM_PRESENT=0

: >"$failure_log"
RMMOD_FAILURE=0 APPLY_FAILURE=23
set +e
install_or_update
rc=$?
set -e
[[ $rc == 1 ]]
[[ $(grep -E '^(build|rmmod|apply)$' "$failure_log" | paste -sd' ') == 'build rmmod apply rmmod apply' ]]
! grep -q '^save$' "$failure_log"

: >"$failure_log"
APPLY_FAILURE=0 ENABLE_FAILURE=24
set +e
install_or_update
rc=$?
set -e
[[ $rc == 24 ]]
grep -q '^save$' "$failure_log"
grep -q '^rmmod$' "$failure_log"

: >"$failure_log"
ENABLE_FAILURE=0
source_version() { echo 2.1.0.custom.1111111; }
install_or_update
! grep -q '^build$' "$failure_log"
! grep -q '^rmmod$' "$failure_log"
grep -q '^save$' "$failure_log"

mkdir -p "$STATE_DIR"
printf '%s\n' 2.1.0.custom.2222222 >"$PENDING_REBOOT"
CONFIG="$tmp/live-config"
apply_rules
[[ ! -e $PENDING_REBOOT ]]

if command -v cc >/dev/null; then
  peers_file="$tmp/peers"
  rules_file="$tmp/rules"
  printf '%s\n' \
    'ip=198.51.100.7 family=4 rule=1 rate=10000000 gain=20 members=3 sent=1250000' \
    'ip=2001:db8::7 family=6 rule=2 rate=2500000 gain=15 members=1 sent=500000' >"$peers_file"
  : >"$rules_file"
  cc -O2 -Wall -Wextra \
    -DPEERS_PATH=\"$peers_file\" -DRULES_PATH=\"$rules_file\" \
    -o "$tmp/brutalctl-test" "$repo/tools/brutalctl.c"
  peers_output=$("$tmp/brutalctl-test" peers)
  grep -q '198.51.100.7.*IPv4.*80.00.*3.*1.2' <<<"$peers_output"
  grep -q '2001:db8::7.*IPv6.*20.00.*1.*0.5' <<<"$peers_output"

  : >"$peers_file"
  grep -q '当前无活跃 perip 连接' <<<"$("$tmp/brutalctl-test" peers)"
  printf '%s\n' 'ip=bad family=4 rule=-1 rate=1 gain=20 members=1 sent=1' >"$peers_file"
  ! "$tmp/brutalctl-test" peers >/dev/null 2>"$tmp/peers-error"
  grep -q 'invalid peers data' "$tmp/peers-error"
  rm "$peers_file"
  ! "$tmp/brutalctl-test" peers >/dev/null 2>"$tmp/peers-error"
  grep -q 'too old for the peers view.*reboot to finish a staged update' "$tmp/peers-error"
  rm "$rules_file"
  ! "$tmp/brutalctl-test" peers >/dev/null 2>"$tmp/peers-error"
  grep -q 'TCP Brutal Custom is not loaded' "$tmp/peers-error"
fi

if command -v script >/dev/null && command -v timeout >/dev/null; then
  output=$(printf '0\n' | timeout 5 script -qfec "cat '$repo/install.sh' | bash" /dev/null)
  grep -q 'TCP Brutal Custom 管理器' <<<"$output"
fi
echo 'install-manager tests passed'
