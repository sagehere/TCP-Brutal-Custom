#!/usr/bin/env bash
# TCP Brutal Custom installer and manager for Debian/Ubuntu + systemd.
set -Eeuo pipefail

REPO="sagehere/TCP-Brutal-Custom"
API="https://api.github.com/repos/$REPO/commits/master"
TARBALL="https://github.com/$REPO/archive"
PACKAGE="tcp-brutal-custom"
CONFIG="/etc/tcp-brutal-custom.conf"
MANAGER="/usr/local/bin/tbc"
LEGACY_MANAGER="/usr/local/bin/brutal-manager"
BRUTALCTL="/usr/local/bin/brutalctl"
SERVICE="/etc/systemd/system/tcp-brutal-custom.service"
MODULES_LOAD="/etc/modules-load.d/brutal.conf"
STATE_DIR="/var/lib/tcp-brutal-custom"
PENDING_REBOOT="$STATE_DIR/reboot-required"
CLEANUP_REQUIRED="$STATE_DIR/cleanup-required"
PEERS_PROC="/proc/net/tcp_brutal/peers"
MANAGER_VERSION="2.3.1"

IPV4_RATE=80
IPV6_RATE=80
MODE=auto
COMMIT=""
VERSION=""
MANAGED=0
ALLOW_RULE_REPLACE=0

die() { echo "错误: $*" >&2; exit 1; }
note() { echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

read_tty() {
  local prompt=$1 variable=$2
  [[ -r /dev/tty ]] || die "当前没有可用的交互终端；请直接运行 tbc，或使用子命令。"
  printf '%s' "$prompt" >&2
  IFS= read -r "$variable" </dev/tty || die "无法从交互终端读取输入。"
}

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 或 sudo 运行。"; }

check_platform() {
  [[ -r /etc/os-release ]] || die "无法识别系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == debian || ${ID:-} == ubuntu ]] || die "本脚本仅支持 Debian 和 Ubuntu。"
  have systemctl || die "需要 systemd。"
  [[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
  case $(uname -m) in x86_64|aarch64) ;; *) die "仅支持 x86_64 与 ARM64。";; esac
  local major minor
  IFS=. read -r major minor _ <<<"$(uname -r)"
  (( major > 5 || (major == 5 && minor >= 10) )) || die "需要 Linux 5.10 或更新版本。"
}

load_config() {
  IPV4_RATE=80; IPV6_RATE=80; MODE=auto; COMMIT=""; VERSION=""; MANAGED=0
  [[ -f $CONFIG ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case $key in
      IPV4_RATE|IPV6_RATE|MODE|COMMIT|VERSION|MANAGED) printf -v "$key" '%s' "$value" ;;
    esac
  done <"$CONFIG"
  valid_rate "$IPV4_RATE" && valid_rate "$IPV6_RATE" || die "配置文件中的速率无效：$CONFIG"
  [[ $MODE =~ ^(auto|ipv4|ipv6|dual)$ ]] || die "配置文件中的地址族模式无效：$CONFIG"
  [[ $MANAGED == 1 ]] || die "配置文件中的管理标记无效：$CONFIG"
  [[ -z $COMMIT || $COMMIT =~ ^[0-9a-f]{40}$ ]] || die "配置文件中的提交号无效：$CONFIG"
  [[ -z $VERSION ]] || valid_custom_version "$VERSION" || die "配置文件中的版本号无效：$CONFIG"
}

save_config() {
  install -d -m 0755 /etc
  umask 022
  cat >"$CONFIG.tmp" <<EOF
IPV4_RATE=$IPV4_RATE
IPV6_RATE=$IPV6_RATE
MODE=$MODE
COMMIT=$COMMIT
VERSION=$VERSION
MANAGED=1
EOF
  mv "$CONFIG.tmp" "$CONFIG"
  MANAGED=1
}

valid_rate() {
  [[ $1 =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] && awk -v r="$1" 'BEGIN { exit !(r >= .5 && r <= 1000000) }'
}

valid_custom_version() {
  [[ $1 =~ ^[0-9]+[.][0-9]+[.][0-9]+$ || $1 =~ ^[0-9]+[.][0-9]+[.][0-9]+[.]custom[.][0-9a-f]{7}$ ]]
}

ask_rate() {
  local family=$1 current=$2 answer
  read_tty "$family 每 IP 速率 Mbps [$current]: " answer
  answer=${answer:-$current}
  valid_rate "$answer" || die "速率必须在 0.5 到 1000000 Mbps 之间。"
  printf '%s\n' "$answer"
}

confirm() {
  local answer
  read_tty "$1 [y/N]: " answer
  [[ $answer =~ ^[Yy]$ ]]
}

has_global_address() {
  local family=$1
  ip "-$family" -o addr show scope global 2>/dev/null | grep -q .
}

has_default_route() {
  ip "-$1" route show default 2>/dev/null | grep -q .
}

family_enabled() {
  local family=$1 forced
  case $MODE in
    auto) has_global_address "$family" && has_default_route "$family" ;;
    ipv4) [[ $family == 4 ]] && has_global_address 4 ;;
    ipv6) [[ $family == 6 ]] && has_global_address 6 ;;
    dual) has_global_address "$family" ;;
    *) die "无效地址族模式：$MODE" ;;
  esac
}

show_stack() {
  printf '地址族模式：%s；IPv4：%s；IPv6：%s\n' "$MODE" \
    "$(family_enabled 4 && echo 可用 || echo 不可用)" \
    "$(family_enabled 6 && echo 可用 || echo 不可用)"
}

kernel_headers_installed() { [[ -d /lib/modules/"$(uname -r)"/build ]]; }
ca_certificates_installed() { [[ -r /etc/ssl/certs/ca-certificates.crt ]]; }

clang_kernel() {
  local config
  for config in /lib/modules/"$(uname -r)"/build/include/config/auto.conf \
                /lib/modules/"$(uname -r)"/build/.config /boot/config-"$(uname -r)"; do
    [[ -r $config ]] || continue
    grep -q '^CONFIG_CC_IS_CLANG=y' "$config"
    return
  done
  return 1
}

libc_headers_installed() {
  local compiler
  compiler=$(command -v cc || command -v gcc || command -v clang || true)
  [[ -n $compiler ]] && printf '#include <errno.h>\n' | "$compiler" -E -x c - >/dev/null 2>&1
}

install_dependencies() {
  local packages=() package
  declare -A missing=()

  have dkms || packages+=(dkms)
  have curl || packages+=(curl)
  ca_certificates_installed || packages+=(ca-certificates)
  have ip || packages+=(iproute2)
  have make || packages+=(make)
  have tar || packages+=(tar)
  if clang_kernel; then
    have clang || packages+=(clang)
    have ld.lld || packages+=(lld)
    have llvm-objcopy || packages+=(llvm)
  else
    have cc || have gcc || packages+=(gcc)
  fi
  libc_headers_installed || packages+=(libc6-dev)
  kernel_headers_installed || packages+=("linux-headers-$(uname -r)")

  if ((${#packages[@]})); then
    local unique=()
    for package in "${packages[@]}"; do
      [[ ${missing[$package]+yes} ]] && continue
      missing[$package]=1
      unique+=("$package")
    done
    note "安装缺失依赖：${unique[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${unique[@]}"
  else
    note "所需依赖已安装，跳过软件包安装"
  fi

  have dkms && have curl && have ip && have make && have tar || die "必要工具安装不完整。"
  if clang_kernel; then
    have clang && have ld.lld && have llvm-objcopy || die "当前内核需要完整的 LLVM 工具链。"
  else
    have cc || have gcc || die "缺少 C 编译器。"
  fi
  libc_headers_installed || die "缺少 C 标准库头文件。"
  kernel_headers_installed || die "当前内核缺少 headers；请安装匹配 $(uname -r) 的 headers 后重试。"
}

module_loaded() { lsmod | awk '$1 == "brutal" { found=1 } END { exit !found }'; }
module_supports_peers() { [[ -r $PEERS_PROC ]]; }

mark_pending_reboot() {
  local cleanup_upstream=${1:-0}
  install -d -m 0755 "$STATE_DIR"
  printf '%s\n' "$VERSION" >"$PENDING_REBOOT.tmp"
  mv "$PENDING_REBOOT.tmp" "$PENDING_REBOOT"
  {
    printf 'CUSTOM=1\n'
    printf 'UPSTREAM=%s\n' "$cleanup_upstream"
  } >"$CLEANUP_REQUIRED.tmp"
  mv "$CLEANUP_REQUIRED.tmp" "$CLEANUP_REQUIRED"
}

pending_reboot_message() {
  local pending
  pending=$(cat "$PENDING_REBOOT" 2>/dev/null || true)
  printf '更新已暂存%s，请重启服务器以加载新模块。\n' "${pending:+（$pending）}"
}

download_source() {
  local temp=$1 sha archive metadata
  metadata="$temp/commit.json"
  curl -fsSL "$API" -o "$metadata"
  sha=$(sed -nE 's/.*"sha": "([0-9a-f]{40})".*/\1/p' "$metadata" | sed -n '1p')
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "无法解析 GitHub master 提交。"
  archive="$temp/source.tar.gz"
  curl -fsSL "$TARBALL/$sha.tar.gz" -o "$archive"
  mkdir -p "$temp/source"
  tar -xzf "$archive" --strip-components=1 -C "$temp/source"
  printf '%s\n' "$sha"
}

source_version() {
  local source=$1 version
  version=$(sed -nE 's/^#define BRUTAL_VERSION_(MAJOR|MINOR|PATCH)[[:space:]]+([0-9]+).*/\2/p' "$source/brutal.h" | paste -sd.)
  [[ $version =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "无法读取模块版本。"
  printf '%s\n' "$version"
}

install_manager() {
  local source=$1
  install -Dm755 "$source/install.sh" "$MANAGER"
  ln -sfn "$MANAGER" "$LEGACY_MANAGER"
  install -Dm755 "$source/tools/brutalctl" "$BRUTALCTL"
  install -d -m 0755 "$STATE_DIR"
  cp -a "$source/." "$STATE_DIR/source-$VERSION"
}

build_dkms() {
  local source=$1 target="/usr/src/$PACKAGE-$VERSION"
  rm -rf "$target"
  install -d -m 0755 "$target"
  cp -a "$source/." "$target/"
  (cd "$target" && PACKAGE_NAME="$PACKAGE" PACKAGE_VERSION="$VERSION" ./scripts/mkdkmsconf.sh >dkms.conf)
  dkms status -m "$PACKAGE" -v "$VERSION" >/dev/null 2>&1 || dkms add -m "$PACKAGE" -v "$VERSION"
  dkms build -m "$PACKAGE" -v "$VERSION"
}

remove_upstream_dkms() {
  local version
  while IFS= read -r version; do
    [[ $version =~ ^[0-9][A-Za-z0-9.+-]*$ ]] || continue
    note "移除已迁移的上游 DKMS tcp-brutal/$version"
    dkms remove -m tcp-brutal -v "$version" --all || return 1
  done < <(dkms status -m tcp-brutal 2>/dev/null | sed -nE 's#^tcp-brutal/([^,]+),.*#\1#p' | sort -u)
}

remove_custom_dkms() {
  local version
  while IFS= read -r version; do
    valid_custom_version "$version" || continue
    [[ $version == "$VERSION" ]] && continue
    dkms remove -m "$PACKAGE" -v "$version" --all || return 1
    rm -rf "/usr/src/$PACKAGE-$version" "$STATE_DIR/source-$version"
  done < <(dkms status -m "$PACKAGE" 2>/dev/null | sed -nE "s#^$PACKAGE/([^,]+),.*#\1#p" | sort -u)
  if valid_custom_version "$VERSION"; then
    dkms remove -m "$PACKAGE" -v "$VERSION" --all || return 1
    rm -rf "/usr/src/$PACKAGE-$VERSION" "$STATE_DIR/source-$VERSION"
  fi
}

custom_version_installed() {
  dkms status -m "$PACKAGE" -v "$1" -k "$(uname -r)" 2>/dev/null | grep -Eq ': installed(,|$)'
}

remove_old_custom_dkms() {
  local keep=$1 version
  while IFS= read -r version; do
    [[ $version == "$keep" ]] && continue
    valid_custom_version "$version" || continue
    dkms remove -m "$PACKAGE" -v "$version" --all || return 1
    rm -rf "/usr/src/$PACKAGE-$version" "$STATE_DIR/source-$version"
  done < <(dkms status -m "$PACKAGE" 2>/dev/null | sed -nE "s#^$PACKAGE/([^,]+),.*#\1#p" | sort -u)
}

module_matches_installed() {
  local live_version live_src disk_version disk_src target_version
  [[ -r /sys/module/brutal/version && -r /sys/module/brutal/srcversion ]] || return 1
  [[ $VERSION =~ ^([0-9]+[.][0-9]+[.][0-9]+)([.]custom[.][0-9a-f]{7})?$ ]] || return 1
  target_version=${BASH_REMATCH[1]}
  live_version=$(cat /sys/module/brutal/version 2>/dev/null || true)
  live_src=$(cat /sys/module/brutal/srcversion 2>/dev/null || true)
  disk_version=$(modinfo -F version brutal 2>/dev/null || true)
  disk_src=$(modinfo -F srcversion brutal 2>/dev/null || true)
  [[ -n $live_src && -n $disk_src && $disk_version == "$target_version" &&
     $live_version == "$disk_version" && $live_src == "$disk_src" ]]
}

cleanup_wants_upstream() {
  [[ -f $CLEANUP_REQUIRED ]] && grep -qx 'UPSTREAM=1' "$CLEANUP_REQUIRED"
}

retry_pending_cleanup() {
  [[ -f $CLEANUP_REQUIRED ]] || return 0
  local failed=0
  remove_old_custom_dkms "$VERSION" || failed=1
  if cleanup_wants_upstream; then
    remove_upstream_dkms || failed=1
  fi
  if (( failed )); then
    echo "警告: 新模块已生效，但旧 DKMS 清理未完成；稍后执行 tbc apply 可重试。" >&2
    return 0
  fi
  dkms install -m "$PACKAGE" -v "$VERSION" -k "$(uname -r)" --force >/dev/null 2>&1 || {
    echo "警告: 旧 DKMS 已清理，但无法重新确认目标 Custom 模块；保留清理状态以便重试。" >&2
    return 0
  }
  depmod -a || {
    echo "警告: DKMS 已清理，但 depmod 失败；稍后执行 tbc apply 可重试。" >&2
    return 0
  }
  module_matches_installed || {
    echo "警告: DKMS 清理后磁盘模块与当前目标不一致；保留清理状态以便重试。" >&2
    return 0
  }
  rm -f "$CLEANUP_REQUIRED"
}

finalize_pending_update() {
  if [[ -f $PENDING_REBOOT ]]; then
    module_matches_installed || {
      echo "错误: 已加载的 brutal 模块与磁盘目标模块不一致；保留旧 DKMS 与待重启状态。" >&2
      return 1
    }
    rm -f "$PENDING_REBOOT"
  fi
  retry_pending_cleanup
}

rule_line() { grep -E "^dst=$1 " /proc/net/tcp_brutal/rules 2>/dev/null || true; }

apply_family() {
  local prefix=$1 rate=$2 line
  line=$(rule_line "$prefix")
  if [[ -n $line && $MANAGED != 1 && $ALLOW_RULE_REPLACE != 1 ]]; then
    echo "错误: 检测到 $prefix 的现有规则；为避免覆盖非受管配置，请先手动删除。" >&2
    return 1
  fi
  if [[ -n $line && $line != *"group=perip"* ]]; then
    if [[ $ALLOW_RULE_REPLACE != 1 ]]; then
      echo "错误: 检测到 $prefix 的非受管规则；拒绝覆盖。" >&2
      return 1
    fi
    "$BRUTALCTL" del "$prefix"
  fi
  "$BRUTALCTL" add "$prefix" "$rate" noroute perip
}

apply_configured_rules() {
  modprobe brutal || return 1
  local applied=0
  if family_enabled 4; then
    apply_family 0.0.0.0/0 "$IPV4_RATE" || return 1
    applied=1
  fi
  if family_enabled 6; then
    apply_family ::/0 "$IPV6_RATE" || return 1
    applied=1
  fi
  if (( ! applied )); then
    echo "错误: 未检测到可用地址族；请设置 tbc rate 的模式为 ipv4、ipv6 或 dual。" >&2
    return 1
  fi
  if ! family_enabled 4 && [[ $(rule_line 0.0.0.0/0) == *"group=perip"* ]]; then
    "$BRUTALCTL" del 0.0.0.0/0 || return 1
  fi
  if ! family_enabled 6 && [[ $(rule_line ::/0) == *"group=perip"* ]]; then
    "$BRUTALCTL" del ::/0 || return 1
  fi
}

apply_rules() {
  load_config
  [[ $MANAGED == 1 ]] || die "尚未完成安装。"
  apply_configured_rules || die "恢复规则失败。"
  module_supports_peers || die "当前加载的模块不支持活跃 IP 视图；请重启服务器完成更新。"
  finalize_pending_update || die "更新收尾验证失败；请检查当前加载模块后重试。"
}

write_service() {
  cat >"$SERVICE" <<EOF
[Unit]
Description=TCP Brutal Custom per-IP rules
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$MANAGER apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

enable_boot() {
  need_root
  load_config
  [[ $MANAGED == 1 && -x $BRUTALCTL && -x $MANAGER ]] || die "安装不完整，请先执行安装 / 更新。"
  custom_version_installed "$VERSION" || die "当前内核缺少已安装的 Custom DKMS 模块，请先执行安装 / 更新。"
  if [[ -f $PENDING_REBOOT ]] && ! module_supports_peers; then
    pending_reboot_message >&2
    return 1
  fi
  [[ -f $SERVICE ]] || write_service
  printf 'brutal\n' >"$MODULES_LOAD"
  systemctl enable --now tcp-brutal-custom.service
}

enable_boot_deferred() {
  [[ -f $SERVICE ]] || write_service
  printf 'brutal\n' >"$MODULES_LOAD"
  systemctl enable tcp-brutal-custom.service
}

disable_boot() {
  need_root
  systemctl disable --now tcp-brutal-custom.service 2>/dev/null || true
  rm -f "$MODULES_LOAD"
}

install_or_update() (
  set -Eeuo pipefail
  need_root; check_platform; load_config
  local old_version=$VERSION old_mode=$MODE old_ipv4=$IPV4_RATE old_ipv6=$IPV6_RATE old_managed=$MANAGED
  local temp="" sha source has_upstream=0 needs_migration=0 needs_install=0 switch_needed=0 switch_complete=0
  local disk_module_changed=0 artifacts_changed=0
  local had_config=0 had_manager=0 had_legacy_manager=0 had_brutalctl=0 had_service=0 had_modules_load=0 was_boot_enabled=0
  local upstream_versions=()
  cleanup_install() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if (( switch_needed && ! switch_complete )); then
      echo "警告: 安装未完成，正在尝试恢复原模块。" >&2
      rmmod brutal >/dev/null 2>&1 || true
      if [[ -n $old_version ]] && custom_version_installed "$old_version"; then
        dkms install -m "$PACKAGE" -v "$old_version" -k "$(uname -r)" --force >/dev/null 2>&1 || echo "警告: 无法恢复 DKMS $PACKAGE/$old_version。" >&2
      else
        local version
        for version in "${upstream_versions[@]}"; do
          dkms install -m tcp-brutal -v "$version" -k "$(uname -r)" --force >/dev/null 2>&1 || echo "警告: 无法恢复 DKMS tcp-brutal/$version。" >&2
        done
      fi
      depmod -a >/dev/null 2>&1 || true
      if [[ -n $old_version || ${#upstream_versions[@]} -gt 0 ]]; then
        modprobe brutal >/dev/null 2>&1 || echo "警告: 无法重新加载原 brutal 模块。" >&2
      fi
      MODE=$old_mode; IPV4_RATE=$old_ipv4; IPV6_RATE=$old_ipv6; MANAGED=$old_managed
      ALLOW_RULE_REPLACE=0
      if (( old_managed )) && ! apply_configured_rules >/dev/null 2>&1; then
        echo "警告: 无法恢复原 TCP Brutal 规则。" >&2
      fi
    elif (( disk_module_changed && ! switch_complete )); then
      if [[ -n $old_version ]] && custom_version_installed "$old_version"; then
        dkms install -m "$PACKAGE" -v "$old_version" -k "$(uname -r)" --force >/dev/null 2>&1 || echo "警告: 无法恢复磁盘上的 DKMS $PACKAGE/$old_version。" >&2
      else
        local version
        for version in "${upstream_versions[@]}"; do
          dkms install -m tcp-brutal -v "$version" -k "$(uname -r)" --force >/dev/null 2>&1 || echo "警告: 无法恢复磁盘上的 DKMS tcp-brutal/$version。" >&2
        done
      fi
      depmod -a >/dev/null 2>&1 || true
    fi
    if (( artifacts_changed && ! switch_complete )); then
      if (( had_config )); then cp -a "$temp/old-config" "$CONFIG" || echo "警告: 无法恢复原配置文件。" >&2; else rm -f "$CONFIG"; fi
      if (( had_manager )); then rm -f "$MANAGER"; cp -a "$temp/old-manager" "$MANAGER" || echo "警告: 无法恢复原管理器。" >&2; else rm -f "$MANAGER"; fi
      if (( had_legacy_manager )); then rm -f "$LEGACY_MANAGER"; cp -a "$temp/old-legacy-manager" "$LEGACY_MANAGER" || echo "警告: 无法恢复原兼容入口。" >&2; else rm -f "$LEGACY_MANAGER"; fi
      if (( had_brutalctl )); then cp -a "$temp/old-brutalctl" "$BRUTALCTL" || echo "警告: 无法恢复原 brutalctl。" >&2; else rm -f "$BRUTALCTL"; fi
      if (( had_service )); then cp -a "$temp/old-service" "$SERVICE" || echo "警告: 无法恢复原 systemd 服务。" >&2; else rm -f "$SERVICE"; fi
      if (( had_modules_load )); then cp -a "$temp/old-modules-load" "$MODULES_LOAD" || echo "警告: 无法恢复原模块自动加载配置。" >&2; else rm -f "$MODULES_LOAD"; fi
      systemctl daemon-reload >/dev/null 2>&1 || true
      if (( was_boot_enabled )); then
        systemctl enable tcp-brutal-custom.service >/dev/null 2>&1 || true
      else
        systemctl disable --now tcp-brutal-custom.service >/dev/null 2>&1 || true
      fi
    fi
    [[ -z $temp ]] || rm -rf "$temp"
    exit "$rc"
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT TERM
  if dkms status -m tcp-brutal 2>/dev/null | grep -q .; then
    has_upstream=1
    needs_migration=1
    mapfile -t upstream_versions < <(dkms status -m tcp-brutal 2>/dev/null | sed -nE 's#^tcp-brutal/([^,]+),.*#\1#p' | sort -u)
  fi
  if (( needs_migration )); then
    confirm "检测到旧 TCP Brutal 安装，将在新模块构建成功后迁移，是否继续？" || return 0
  fi
  install_dependencies
  temp=$(mktemp -d)
  if [[ -f $CONFIG ]]; then cp -a "$CONFIG" "$temp/old-config"; had_config=1; fi
  if [[ -f $MANAGER ]]; then cp -a "$MANAGER" "$temp/old-manager"; had_manager=1; fi
  if [[ -e $LEGACY_MANAGER || -L $LEGACY_MANAGER ]]; then cp -a "$LEGACY_MANAGER" "$temp/old-legacy-manager"; had_legacy_manager=1; fi
  if [[ -f $BRUTALCTL ]]; then cp -a "$BRUTALCTL" "$temp/old-brutalctl"; had_brutalctl=1; fi
  if [[ -f $SERVICE ]]; then cp -a "$SERVICE" "$temp/old-service"; had_service=1; fi
  if [[ -f $MODULES_LOAD ]]; then cp -a "$MODULES_LOAD" "$temp/old-modules-load"; had_modules_load=1; fi
  systemctl is-enabled --quiet tcp-brutal-custom.service 2>/dev/null && was_boot_enabled=1 || true
  sha=$(download_source "$temp")
  source="$temp/source"
  VERSION=$(source_version "$source" "$sha")
  if custom_version_installed "$VERSION"; then
    note "当前版本已安装：$VERSION"
    [[ $old_version == "$VERSION" ]] || COMMIT=""
  else
    build_dkms "$source"
    needs_install=1
    COMMIT=$sha
  fi
  make -C "$source/tools"
  if (( ! old_managed )); then
    MODE=auto
    IPV4_RATE=$(ask_rate IPv4 "$IPV4_RATE")
    IPV6_RATE=$(ask_rate IPv6 "$IPV6_RATE")
  fi
  if (( needs_install )); then
    disk_module_changed=1
    dkms install -m "$PACKAGE" -v "$VERSION"
  fi
  depmod -a
  artifacts_changed=1
  install_manager "$source"
  write_service
  if (( needs_migration )); then
    if module_loaded; then
      rmmod brutal || die "上游 Brutal 模块正在使用，无法安全迁移；请结束使用该模块的连接后重试。"
    fi
    switch_needed=1
    if (( has_upstream )) && ! remove_upstream_dkms; then
      die "上游 DKMS 仍无法移除；新构建已保留，未替换规则。"
    fi
  fi
  if (( ! needs_migration )); then
    if module_loaded && { [[ $VERSION != "$old_version" ]] || [[ -f $PENDING_REBOOT ]]; }; then
      if ! rmmod brutal; then
        save_config
        enable_boot_deferred
        mark_pending_reboot "$has_upstream"
        switch_complete=1
        note "更新已暂存，现有连接继续使用旧模块；请重启服务器完成更新。"
        return 0
      fi
      switch_needed=1
    elif ! module_loaded; then
      switch_needed=1
    fi
  fi
  if (( needs_migration )); then ALLOW_RULE_REPLACE=1; fi
  if ! apply_configured_rules; then
    die "新规则应用失败；已保留 DKMS 构建。"
  fi
  module_supports_peers || die "新模块缺少活跃 IP 视图接口。"
  save_config
  enable_boot
  rm -f "$PENDING_REBOOT"
  switch_complete=1
  remove_old_custom_dkms "$VERSION" || echo "警告: 旧版 Custom DKMS 清理失败，可稍后重新执行更新。" >&2
  note "TCP Brutal Custom 安装完成。"
)

set_rate() {
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "请先安装。"
  local answer old_mode=$MODE old_ipv4=$IPV4_RATE old_ipv6=$IPV6_RATE
  read_tty "地址族模式 [auto/ipv4/ipv6/dual] [$MODE]: " answer
  MODE=${answer:-$MODE}
  [[ $MODE =~ ^(auto|ipv4|ipv6|dual)$ ]] || die "无效模式。"
  IPV4_RATE=$(ask_rate IPv4 "$IPV4_RATE")
  IPV6_RATE=$(ask_rate IPv6 "$IPV6_RATE")
  if ! apply_configured_rules; then
    MODE=$old_mode; IPV4_RATE=$old_ipv4; IPV6_RATE=$old_ipv6
    apply_configured_rules || true
    die "应用新速率失败，已尝试恢复原规则。"
  fi
  save_config
  note "速率已更新。"
}

status() {
  need_root; load_config
  echo "TCP Brutal Custom"
  echo "提交: ${COMMIT:-未安装}"
  echo "DKMS: ${VERSION:-未安装}"
  echo "配置速率: IPv4 ${IPV4_RATE} Mbps，IPv6 ${IPV6_RATE} Mbps"
  show_stack
  systemctl is-enabled --quiet tcp-brutal-custom.service && echo "开机启动: 已启用" || echo "开机启动: 未启用"
  module_loaded && echo "模块: 已加载" || echo "模块: 未加载"
  if [[ -f $PENDING_REBOOT ]]; then
    printf '更新状态: '
    pending_reboot_message
  else
    echo "更新状态: 已生效"
  fi
  [[ -f $CLEANUP_REQUIRED ]] && echo "清理状态: 旧 DKMS 清理待完成" || echo "清理状态: 已完成"
  [[ -r /proc/net/tcp_brutal/rules && -x $BRUTALCTL ]] && "$BRUTALCTL" list || true
}

show_peers() {
  [[ -x $BRUTALCTL ]] || die "未找到 $BRUTALCTL，请先执行安装 / 更新。"
  if [[ -f $PENDING_REBOOT ]] && ! module_supports_peers; then
    pending_reboot_message >&2
    return 1
  fi
  "$BRUTALCTL" peers --limit 1000
}

view() {
  need_root
  case ${1:-} in
    "") show_peers ;;
    --watch)
      while :; do
        printf '\033[H\033[2J'
        printf 'TCP Brutal Custom 活跃 IP  %s\n\n' "$(date '+%F %T')"
        show_peers || return
        sleep 2
      done
      ;;
    *) die "用法: tbc view [--watch]" ;;
  esac
}

uninstall() (
  set -Eeuo pipefail
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "未找到本项目安装记录。"
  local complete=0 changed=0
  cleanup_uninstall() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if (( changed && ! complete )); then
      modprobe brutal >/dev/null 2>&1 || echo "警告: 无法重新加载 brutal 模块。" >&2
      apply_configured_rules >/dev/null 2>&1 || echo "警告: 无法恢复卸载前的规则。" >&2
    fi
    exit "$rc"
  }
  trap cleanup_uninstall EXIT
  trap 'exit 130' INT TERM
  confirm "确认卸载 TCP Brutal Custom？" || return 0
  if module_loaded && ! rmmod brutal; then
    die "Brutal 模块正在使用，无法安全卸载；请结束使用该模块的连接后重试。"
  fi
  changed=1
  remove_custom_dkms || die "DKMS 移除失败，已保留安装记录。"
  disable_boot
  rm -f "$SERVICE" "$MODULES_LOAD" "$BRUTALCTL"
  rm -rf "$STATE_DIR" "$CONFIG"
  systemctl daemon-reload
  rm -f "$MANAGER" "$LEGACY_MANAGER"
  complete=1
  note "卸载完成。系统编译依赖和上游 TCP Brutal 安装未删除。"
)

run_menu_action() {
  local rc
  set +e
  ( set -Eeuo pipefail; "$@" )
  rc=$?
  set -e
  if (( rc != 0 )); then
    echo "操作失败，请根据上方错误信息处理后重试。" >&2
  fi
}

menu() {
  while :; do
    cat <<EOF

TCP Brutal Custom 管理器 v$MANAGER_VERSION
1. 安装 / 更新
2. 设置 IPv4 / IPv6 速率
3. 开启开机启动
4. 关闭开机启动
5. 查看状态
6. 查看活跃 IP
7. 实时查看活跃 IP
8. 卸载
0. 退出
EOF
    local choice
    read_tty '请选择: ' choice
    case $choice in
      1) run_menu_action install_or_update ;;
      2) run_menu_action set_rate ;;
      3) run_menu_action enable_boot ;;
      4) run_menu_action disable_boot ;;
      5) run_menu_action status ;;
      6) run_menu_action view ;;
      7) run_menu_action view --watch ;;
      8) run_menu_action uninstall ;;
      0) return ;;
      *) echo "无效选择。" ;;
    esac
  done
}

if [[ ${BRUTAL_MANAGER_LIB:-0} == 1 ]]; then
  return 0
fi

case ${1:-menu} in
  menu) menu ;;
  install|update) install_or_update ;;
  rate) set_rate ;;
  apply) apply_rules ;;
  enable) enable_boot ;;
  disable) disable_boot ;;
  status) status ;;
  view) shift; view "$@" ;;
  uninstall) uninstall ;;
  *) echo "用法: $0 {install|update|rate|apply|enable|disable|status|view [--watch]|uninstall}" >&2; exit 2 ;;
esac
