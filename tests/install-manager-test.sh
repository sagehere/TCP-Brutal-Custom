#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-4 -o addr show scope global")
    if [[ ${TEST_MANY_IPV4_ADDR:-0} == 1 ]]; then
      for i in $(seq 1 4096); do printf '2: eth0 inet 198.51.100.%d/24 scope global eth0\n' "$((i % 250 + 2))"; done
    else
      echo '2: eth0 inet 198.51.100.2/24 scope global eth0'
    fi
    ;;
  "-4 route show default")
    if [[ ${TEST_MANY_IPV4_ROUTE:-0} == 1 ]]; then
      for i in $(seq 1 4096); do printf 'default via 198.51.100.1 dev eth0 metric %d\n' "$i"; done
    else
      echo 'default via 198.51.100.1 dev eth0'
    fi
    ;;
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

# A grep -q downstream of a verbose producer can SIGPIPE the producer under pipefail.
if grep -nE '\|[[:space:]]*grep[[:space:]]+-[^[:space:]]*q' "$repo/install.sh"; then
  echo "pipefail-unsafe grep -q pipeline remains in install.sh" >&2
  exit 1
fi

! grep -Eqi 'x-ui|xray|3x-ui|vless|xhttp' "$repo/install.sh"
[[ $MANAGER_VERSION == 2.5.3 ]]
[[ $(source_product_version "$repo") == 2.5.3 ]]
sha_a=abcdef0123456789abcdef0123456789abcdef01
sha_b=1234567890abcdef1234567890abcdef12345678
[[ $(source_version "$repo" "$sha_a") == 2.5.3.custom.abcdef0 ]]
[[ $(source_version "$repo" "$sha_b") == 2.5.3.custom.1234567 ]]
[[ $(source_version "$repo" "$sha_a") != $(source_version "$repo" "$sha_b") ]]
! (source_version "$repo" invalid >/dev/null 2>&1)
header_version=$(sed -nE 's/^#define BRUTAL_VERSION_(MAJOR|MINOR|PATCH)[[:space:]]+([0-9]+).*/\2/p' "$repo/brutal.h" | paste -sd.)
[[ $header_version == "$MANAGER_VERSION" ]]

dkms_version=$("$repo/scripts/mkdkmsconf.sh" | sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p')
[[ $dkms_version == 2.5.3 ]]
mkdir -p "$tmp/no-git/scripts"
cp "$repo/brutal.h" "$tmp/no-git/brutal.h"
cp "$repo/scripts/mkdkmsconf.sh" "$tmp/no-git/scripts/mkdkmsconf.sh"
[[ $(cd "$tmp/no-git" && ./scripts/mkdkmsconf.sh | sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p') == 2.5.3 ]]
(cd "$repo" && PACKAGE_VERSION=2.5.3.custom.abcdef0 ./scripts/mkdkmsconf.sh >/dev/null)
! (cd "$repo" && PACKAGE_VERSION=2.5.3.custom.abcdef ./scripts/mkdkmsconf.sh >/dev/null 2>&1)

(
  DKMS_SOURCE_ROOT="$tmp/dkms-source"
  PACKAGE=tcp-brutal-custom
  VERSION=2.5.3.custom.abcdef0
  COMMIT=$sha_a
  dkms() { return 0; }
  build_dkms "$repo"
  [[ $(build_commit_marker "$VERSION") == "$sha_a" ]]
  grep -qx 'PACKAGE_VERSION="2.5.3.custom.abcdef0"' "$DKMS_SOURCE_ROOT/$PACKAGE-$VERSION/dkms.conf"
)

(
  need_root() { return 0; }
  BRUTALCTL="$tmp/fixed-brutalctl"
  PEERS_PROC="$tmp/peers"
  PENDING_REBOOT="$tmp/no-pending-reboot"
  [[ $(view) == 'peers --limit 1000' ]]
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

[[ $(normalize_ports 443) == 443 ]]
[[ $(normalize_ports '443,8443') == '443,8443' ]]
[[ $(normalize_ports '443,444,445') == '443-445' ]]
[[ $(normalize_ports '443,443,440-445,444-450') == '440-450' ]]
[[ $(normalize_ports ' 443 , 8443 ') == '443,8443' ]]
! normalize_ports 0 >/dev/null 2>&1
! normalize_ports 65536 >/dev/null 2>&1
! normalize_ports 100-99 >/dev/null 2>&1
! normalize_ports abc >/dev/null 2>&1
! normalize_ports '443,,8443' >/dev/null 2>&1

CONFIG="$tmp/missing-config"
load_config
[[ $IPV4_RATE == 80 && $IPV6_RATE == 80 && $MODE == auto && -z $TCP_PORTS && $AGGREGATE_RATE == 0 && $MANAGED == 0 ]]

read_tty() { printf -v "$2" n; }
! confirm "cancel"
read_tty() { printf -v "$2" 0; }
menu_output=$(menu)
grep -q 'TCP Brutal Custom 管理器 v2.5.3' <<<"$menu_output"

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
( export TEST_MANY_IPV4_ADDR=1; family_enabled 4 )
( export TEST_MANY_IPV4_ROUTE=1; family_enabled 4 )
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
TCP_PORTS=443,8443,10000-10100
AGGREGATE_RATE=500
COMMIT=abcdef0123456789abcdef0123456789abcdef01
VERSION=2.1.0.custom.abcdef0
MANAGED=1
UNTRUSTED=$(false)
EOF
load_config
[[ $IPV4_RATE == 120 && $IPV6_RATE == 60 && $MODE == dual && $TCP_PORTS == 443,8443,10000-10100 && $AGGREGATE_RATE == 500 && $MANAGED == 1 ]]

sed 's/^VERSION=.*/VERSION=2.4.0/' "$CONFIG" >"$tmp/current-config"
CONFIG="$tmp/current-config"
load_config
[[ $VERSION == 2.4.0 ]]

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

cat >"$tmp/bad-aggregate-config" <<'EOF'
IPV4_RATE=80
IPV6_RATE=60
MODE=dual
TCP_PORTS=
AGGREGATE_RATE=nan
COMMIT=
VERSION=
MANAGED=1
EOF
CONFIG="$tmp/bad-aggregate-config"
! (load_config)

sed 's/^VERSION=.*/VERSION=41a9ce9/' "$tmp/current-config" >"$tmp/bad-version-config"
CONFIG="$tmp/bad-version-config"
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
      'tcp-brutal-custom/2.1.0.custom.2222222, 6.1.0, x86_64: installed' \
      'tcp-brutal-custom/2.4.0, 6.1.0, x86_64: installed'
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
[[ ${dkms_calls[1]} == 'remove -m tcp-brutal-custom -v 2.4.0 --all' ]]
[[ ${dkms_calls[2]} == 'remove -m tcp-brutal-custom -v 2.1.0.custom.2222222 --all' ]]
unset -f rm dkms

(
  STATE_DIR="$tmp/finalize-state"
  PENDING_REBOOT="$STATE_DIR/reboot-required"
  CLEANUP_REQUIRED="$STATE_DIR/cleanup-required"
  VERSION=2.4.0
  finalize_log="$tmp/finalize.log"
  MATCH_OK=1
  CLEAN_FAIL=0
  module_matches_installed() { (( MATCH_OK )); }
  remove_old_custom_dkms() { echo "custom $1" >>"$finalize_log"; return "$CLEAN_FAIL"; }
  remove_upstream_dkms() { echo upstream >>"$finalize_log"; return 0; }
  dkms() { echo "dkms $*" >>"$finalize_log"; return 0; }
  depmod() { echo depmod >>"$finalize_log"; return 0; }

  mark_pending_reboot 1
  [[ $(cat "$PENDING_REBOOT") == "$VERSION" ]]
  grep -qx 'CUSTOM=1' "$CLEANUP_REQUIRED"
  grep -qx 'UPSTREAM=1' "$CLEANUP_REQUIRED"

  MATCH_OK=0
  ! finalize_pending_update
  [[ -f $PENDING_REBOOT && -f $CLEANUP_REQUIRED ]]
  [[ ! -e $finalize_log ]]

  MATCH_OK=1
  finalize_pending_update
  [[ ! -e $PENDING_REBOOT && ! -e $CLEANUP_REQUIRED ]]
  [[ $(paste -sd' ' "$finalize_log") == "custom $VERSION upstream dkms install -m tcp-brutal-custom -v $VERSION -k $(uname -r) --force depmod" ]]

  : >"$finalize_log"
  mark_pending_reboot 0
  CLEAN_FAIL=1
  finalize_pending_update
  [[ ! -e $PENDING_REBOOT && -f $CLEANUP_REQUIRED ]]
  grep -qx "custom $VERSION" "$finalize_log"
  ! grep -q '^upstream$' "$finalize_log"

  CLEAN_FAIL=0
  retry_pending_cleanup
  [[ ! -e $CLEANUP_REQUIRED ]]
)

(
  source="$tmp/manager-source"
  MANAGER="$tmp/manager-install/tbc"
  LEGACY_MANAGER="$tmp/manager-install/brutal-manager"
  BRUTALCTL="$tmp/manager-install/brutalctl"
  STATE_DIR="$tmp/manager-state"
  VERSION=2.4.0
  mkdir -p "$source/tools"
  cp "$repo/install.sh" "$source/install.sh"
  printf '#!/usr/bin/env bash\n' >"$source/tools/brutalctl"
  chmod +x "$source/tools/brutalctl"
  install_manager "$source"
  [[ -x $MANAGER && -x $BRUTALCTL && -e $LEGACY_MANAGER ]]
  cmp "$MANAGER" "$LEGACY_MANAGER"
  [[ ! -L $LEGACY_MANAGER ]] || [[ $(readlink "$LEGACY_MANAGER") == "$MANAGER" ]]
  SERVICE="$tmp/manager-install/service"
  systemctl() { return 0; }
  write_service
  grep -qx "ExecStart=$MANAGER apply" "$SERVICE"
)

(
  root="$tmp/uninstall"
  MANAGER="$root/tbc"
  LEGACY_MANAGER="$root/brutal-manager"
  BRUTALCTL="$root/brutalctl"
  SERVICE="$root/tcp-brutal-custom.service"
  MODULES_LOAD="$root/modules-load.conf"
  STATE_DIR="$root/state"
  CONFIG="$root/config"
  mkdir -p "$STATE_DIR"
  touch "$MANAGER" "$LEGACY_MANAGER" "$BRUTALCTL" "$SERVICE" "$MODULES_LOAD" "$CONFIG"
  need_root() { return 0; }
  load_config() { MANAGED=1; VERSION=2.4.0; AGGREGATE_RATE=0; }
  confirm() { return 0; }
  module_loaded() { return 1; }
  remove_custom_dkms() { return 0; }
  apply_aggregate_cap() { return 0; }
  disable_boot() { return 0; }
  systemctl() { return 0; }
  uninstall
  [[ ! -e $MANAGER && ! -e $LEGACY_MANAGER && ! -e $BRUTALCTL && ! -e $SERVICE && ! -e $MODULES_LOAD && ! -e $STATE_DIR && ! -e $CONFIG ]]
)

failure_log="$tmp/install-failure.log"
CONFIG="$tmp/live-config"
MANAGER="$tmp/tbc"
LEGACY_MANAGER="$tmp/brutal-manager"
BRUTALCTL="$tmp/brutalctl"
SERVICE="$tmp/tcp-brutal-custom.service"
MODULES_LOAD="$tmp/modules-load.conf"
STATE_DIR="$tmp/state"
PENDING_REBOOT="$STATE_DIR/reboot-required"
PEERS_PROC="$tmp/peers-proc"
printf 'old tbc\n' >"$MANAGER"
printf 'old brutal-manager\n' >"$LEGACY_MANAGER"
load_config() {
  IPV4_RATE=80; IPV6_RATE=80; MODE=auto; TCP_PORTS=""; AGGREGATE_RATE=0
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
source_version() { echo 2.5.3.custom.2222222; }
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
finalize_pending_update() { rm -f "$PENDING_REBOOT"; return 0; }
remove_old_custom_dkms() { return 0; }
save_config() {
  echo save >>"$failure_log"
  printf '%s\n' "$COMMIT" >"$tmp/saved-commit"
}
build_dkms() { echo build >>"$failure_log"; return "${BUILD_FAILURE:-0}"; }
apply_configured_rules() { echo apply >>"$failure_log"; return "${APPLY_FAILURE:-0}"; }
apply_aggregate_cap() { echo aggregate >>"$failure_log"; return "${AGG_FAILURE:-0}"; }

DOWNLOAD_FAILURE=12 BUILD_FAILURE=0 RMMOD_FAILURE=0 APPLY_FAILURE=0 AGG_FAILURE=0 ENABLE_FAILURE=0 DEFER_FAILURE=0 UPSTREAM_PRESENT=0 SUPPORTS_PEERS=1
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
grep -qx 'old tbc' "$MANAGER"
grep -qx 'old brutal-manager' "$LEGACY_MANAGER"

: >"$failure_log"
DEFER_FAILURE=0
set +e
install_or_update
rc=$?
set -e
[[ $rc == 0 ]]
[[ $(grep -c '^rmmod$' "$failure_log") == 1 ]]
[[ $(grep -E '^(build|dkms install|install-manager|write-service|rmmod|save|mark-pending|enable-deferred)' "$failure_log" | paste -sd' ') == 'build dkms install -m tcp-brutal-custom -v 2.5.3.custom.2222222 install-manager write-service rmmod save enable-deferred mark-pending' ]]
[[ $(cat "$PENDING_REBOOT") == 2.5.3.custom.2222222 ]]
grep -q '^dkms install -m tcp-brutal-custom -v 2.5.3.custom.2222222$' "$failure_log"
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
source_version() { echo 2.5.3.custom.2222222; }
custom_version_installed() { [[ $1 == 2.5.3.custom.2222222 ]]; }
build_commit_marker() { echo 2222222222222222222222222222222222222222; }
install_or_update
[[ -f $tmp/saved-commit && $(cat "$tmp/saved-commit") == 2222222222222222222222222222222222222222 ]]

: >"$failure_log"
source_version() { echo 2.1.0.custom.1111111; }
custom_version_installed() { [[ $1 == 2.1.0.custom.1111111 ]]; }
build_commit_marker() { echo 2222222222222222222222222222222222222222; }
install_or_update
! grep -q '^build$' "$failure_log"
! grep -q '^rmmod$' "$failure_log"
grep -q '^save$' "$failure_log"
grep -qx '2222222222222222222222222222222222222222' "$tmp/saved-commit"

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
  [[ $("$tmp/brutalctl-test" peers --family 4 | grep -c '198.51.100.7') == 1 ]]
  ! ("$tmp/brutalctl-test" peers --family 4 | grep -q '2001:db8::7')
  [[ $("$tmp/brutalctl-test" peers --rule 2 --limit 1 | grep -c '2001:db8::7') == 1 ]]
  [[ $("$tmp/brutalctl-test" peers --ip 198.51.100.7 | grep -c '198.51.100.7') == 1 ]]
  ! "$tmp/brutalctl-test" peers --family 5 >/dev/null 2>&1

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
  output=$(printf '0\n' | BRUTAL_MANAGER_LIB=0 timeout 5 script -qfec "cat '$repo/install.sh' | bash" /dev/null)
  grep -q 'TCP Brutal Custom 管理器' <<<"$output"
fi
echo 'install-manager tests passed'
