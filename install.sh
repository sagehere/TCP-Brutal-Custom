#!/usr/bin/env bash
# TCP Brutal Custom installer and manager for Debian/Ubuntu + systemd.
set -Eeuo pipefail

REPO="sagehere/TCP-Brutal-Custom"
API="https://api.github.com/repos/$REPO/commits/master"
RAW="https://raw.githubusercontent.com/$REPO"
TARBALL="https://github.com/$REPO/archive"
PACKAGE="tcp-brutal-custom"
CONFIG="/etc/tcp-brutal-custom.conf"
MANAGER="/usr/local/bin/brutal-manager"
SERVICE="/etc/systemd/system/tcp-brutal-custom.service"
MODULES_LOAD="/etc/modules-load.d/brutal.conf"
STATE_DIR="/var/lib/tcp-brutal-custom"
LEGACY_SERVICE="/etc/systemd/system/tcp-brutal-xray.service"

IPV4_RATE=80
IPV6_RATE=80
MODE=auto
COMMIT=""
VERSION=""
MANAGED=0
STOPPED_SERVICES=()

die() { echo "错误: $*" >&2; exit 1; }
note() { echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

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
  [[ -f $CONFIG ]] || return
  local key value
  while IFS='=' read -r key value; do
    case $key in
      IPV4_RATE|IPV6_RATE|MODE|COMMIT|VERSION|MANAGED) printf -v "$key" '%s' "$value" ;;
    esac
  done <"$CONFIG"
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
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v r="$1" 'BEGIN { exit !(r >= .5 && r <= 1000000) }'
}

ask_rate() {
  local family=$1 current=$2 answer
  read -r -p "$family 每 IP 速率 Mbps [$current]: " answer
  answer=${answer:-$current}
  valid_rate "$answer" || die "速率必须在 0.5 到 1000000 Mbps 之间。"
  printf '%s\n' "$answer"
}

confirm() {
  local answer
  read -r -p "$1 [y/N]: " answer
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

install_dependencies() {
  note "安装 DKMS、编译工具、内核 headers 和网络工具"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    dkms build-essential curl ca-certificates iproute2 "linux-headers-$(uname -r)"
  [[ -d /lib/modules/"$(uname -r)"/build ]] || die "当前内核缺少 headers；请安装匹配 $(uname -r) 的 headers 后重试。"
}

active_proxy_services() {
  local service
  for service in x-ui.service xray.service; do
    systemctl is-active --quiet "$service" && printf '%s\n' "$service"
  done
}

stop_proxy_services() {
  STOPPED_SERVICES=()
  local service
  while IFS= read -r service; do
    [[ -n $service ]] || continue
    note "暂停 $service"
    systemctl stop "$service"
    STOPPED_SERVICES+=("$service")
  done < <(active_proxy_services)
}

restore_proxy_services() {
  local service
  for service in "${STOPPED_SERVICES[@]:-}"; do
    systemctl start "$service" || echo "警告: 无法恢复 $service，请执行 systemctl status $service" >&2
  done
}

module_loaded() { lsmod | awk '$1 == "brutal" { found=1 } END { exit !found }'; }

download_source() {
  local temp=$1 sha archive
  sha=$(curl -fsSL "$API" | sed -nE 's/.*"sha": "([0-9a-f]{40})".*/\1/p' | head -1)
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "无法解析 GitHub master 提交。"
  archive="$temp/source.tar.gz"
  curl -fsSL "$TARBALL/$sha.tar.gz" -o "$archive"
  mkdir -p "$temp/source"
  tar -xzf "$archive" --strip-components=1 -C "$temp/source"
  printf '%s\n' "$sha"
}

source_version() {
  local source=$1 sha=$2 version
  version=$(sed -nE 's/^#define BRUTAL_VERSION_(MAJOR|MINOR|PATCH)[[:space:]]+([0-9]+).*/\2/p' "$source/brutal.h" | paste -sd.)
  [[ $version =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "无法读取模块版本。"
  printf '%s.custom.%s\n' "$version" "${sha:0:7}"
}

install_manager() {
  local source=$1 sha=$2 temp=$3
  curl -fsSL "$RAW/$sha/install.sh" -o "$temp/brutal-manager"
  install -Dm755 "$temp/brutal-manager" "$MANAGER"
  install -Dm644 /dev/null "$MODULES_LOAD"
  printf 'brutal\n' >"$MODULES_LOAD"
  install -d -m 0755 "$STATE_DIR"
  cp -a "$source/." "$STATE_DIR/source-$VERSION"
}

install_dkms() {
  local source=$1 target="/usr/src/$PACKAGE-$VERSION"
  rm -rf "$target"
  install -d -m 0755 "$target"
  cp -a "$source/." "$target/"
  (cd "$target" && PACKAGE_NAME="$PACKAGE" PACKAGE_VERSION="$VERSION" ./scripts/mkdkmsconf.sh >dkms.conf)
  dkms add -m "$PACKAGE" -v "$VERSION"
  dkms build -m "$PACKAGE" -v "$VERSION"
  dkms install -m "$PACKAGE" -v "$VERSION"
  make -C "$target/tools"
  install -Dm755 "$target/tools/brutalctl" /usr/local/bin/brutalctl
  depmod -a
}

backup_upstream() {
  install -d -m 0700 "$STATE_DIR/backup"
  dkms status -m tcp-brutal >"$STATE_DIR/backup/upstream-dkms-status" 2>/dev/null || true
  [[ -x /usr/local/bin/brutalctl ]] && cp -a /usr/local/bin/brutalctl "$STATE_DIR/backup/brutalctl"
  [[ -f $LEGACY_SERVICE ]] && cp -a "$LEGACY_SERVICE" "$STATE_DIR/backup/tcp-brutal-xray.service"
}

remove_upstream_dkms() {
  local version
  while IFS= read -r version; do
    [[ $version =~ ^[0-9][A-Za-z0-9.+-]*$ ]] || continue
    note "移除已迁移的上游 DKMS tcp-brutal/$version"
    dkms remove -m tcp-brutal -v "$version" --all
  done < <(dkms status -m tcp-brutal 2>/dev/null | sed -nE 's#^tcp-brutal/([^,]+),.*#\1#p' | sort -u)
}

retire_legacy_service() {
  [[ -f $LEGACY_SERVICE ]] || return 0
  note "停用已迁移的 tcp-brutal-xray.service"
  systemctl disable --now tcp-brutal-xray.service || return 1
  rm -f "$LEGACY_SERVICE"
  systemctl daemon-reload
}

remove_custom_dkms() {
  [[ $VERSION =~ ^[0-9]+[.][0-9]+[.][0-9]+[.]custom[.][0-9a-f]{7}$ ]] || return
  dkms remove -m "$PACKAGE" -v "$VERSION" --all >/dev/null 2>&1 || true
  rm -rf "/usr/src/$PACKAGE-$VERSION"
}

rule_line() { grep -E "^dst=$1 " /proc/net/tcp_brutal/rules 2>/dev/null || true; }

apply_family() {
  local prefix=$1 rate=$2 line
  line=$(rule_line "$prefix")
  if [[ -n $line && $line != *"group=perip"* ]]; then
    if [[ $MANAGED != 1 ]]; then
      echo "错误: 检测到 $prefix 的非 perip 规则；请先手动删除，或完成迁移后重试。" >&2
      return 1
    fi
    brutalctl del "$prefix"
  fi
  brutalctl add "$prefix" "$rate" noroute perip
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
    echo "错误: 未检测到可用地址族；请设置 brutal-manager rate 的模式为 ipv4、ipv6 或 dual。" >&2
    return 1
  fi
}

apply_rules() {
  load_config
  [[ $MANAGED == 1 ]] || die "尚未完成安装。"
  apply_configured_rules || die "恢复规则失败。"
}

write_service() {
  cat >"$SERVICE" <<EOF
[Unit]
Description=TCP Brutal Custom per-IP rules
Wants=network-online.target
After=network-online.target
Before=x-ui.service xray.service

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
  [[ -f $SERVICE ]] || write_service
  systemctl enable --now tcp-brutal-custom.service
}

disable_boot() {
  systemctl disable --now tcp-brutal-custom.service 2>/dev/null || true
}

install_or_update() {
  need_root; check_platform; load_config
  local old_version=$VERSION temp sha source has_upstream=0 needs_migration=0
  if dkms status -m tcp-brutal 2>/dev/null | grep -q .; then
    has_upstream=1
    needs_migration=1
  fi
  [[ -f $LEGACY_SERVICE ]] && needs_migration=1
  if (( needs_migration )); then
    confirm "检测到旧 TCP Brutal 安装，将在新模块构建成功后迁移，是否继续？" || return
    backup_upstream
  fi
  if module_loaded || (( needs_migration )); then
    confirm "检测到正在运行的 Brutal。将暂停 x-ui/xray 并替换模块，是否继续？" || return
    stop_proxy_services
    if module_loaded && ! rmmod brutal; then
      restore_proxy_services
      die "模块仍被其他进程占用，未执行迁移。"
    fi
  fi
  install_dependencies
  temp=$(mktemp -d)
  trap 'rm -rf "$temp"' RETURN
  sha=$(download_source "$temp")
  source="$temp/source"
  VERSION=$(source_version "$source" "$sha")
  if [[ $VERSION == "$old_version" ]] && dkms status -m "$PACKAGE" -v "$VERSION" >/dev/null 2>&1; then
    note "当前提交已安装：${sha:0:7}"
  else
    install_dkms "$source"
  fi
  if (( has_upstream )) && ! remove_upstream_dkms; then
    restore_proxy_services
    die "上游 DKMS 仍无法移除；新构建已保留，未替换规则。"
  fi
  if (( needs_migration )) && ! retire_legacy_service; then
    restore_proxy_services
    die "旧 tcp-brutal-xray.service 无法停用；新构建已保留，未替换规则。"
  fi
  COMMIT=$sha
  install_manager "$source" "$sha" "$temp"
  if [[ $MANAGED != 1 ]]; then
    MODE=auto
    IPV4_RATE=$(ask_rate IPv4 "$IPV4_RATE")
    IPV6_RATE=$(ask_rate IPv6 "$IPV6_RATE")
  fi
  save_config
  write_service
  if ! apply_configured_rules; then
    restore_proxy_services
    die "新规则应用失败；已保留 DKMS 构建和旧代理服务。"
  fi
  enable_boot
  restore_proxy_services
  trap - RETURN
  rm -rf "$temp"
  note "安装完成。3x-ui 的 Custom Sockopt 需设置 TCP_CONGESTION=brutal。"
}

set_rate() {
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "请先安装。"
  local answer old_mode=$MODE old_ipv4=$IPV4_RATE old_ipv6=$IPV6_RATE
  read -r -p "地址族模式 [auto/ipv4/ipv6/dual] [$MODE]: " answer
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
  note "速率已更新，无需重启 Xray。"
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
  [[ -r /proc/net/tcp_brutal/rules ]] && brutalctl list || true
}

uninstall() {
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "未找到本项目安装记录。"
  echo "请先在 3x-ui/Xray 移除 Custom Sockopt 中的 brutal，然后再卸载。"
  confirm "确认已移除且继续卸载？" || return
  if module_loaded; then
    confirm "将暂停正在运行的 x-ui/xray，是否继续？" || return
    stop_proxy_services
  fi
  [[ $(rule_line 0.0.0.0/0) == *"group=perip"* ]] && brutalctl del 0.0.0.0/0 2>/dev/null || true
  [[ $(rule_line ::/0) == *"group=perip"* ]] && brutalctl del ::/0 2>/dev/null || true
  if module_loaded && ! rmmod brutal; then
    restore_proxy_services
    die "模块仍被占用，已保留安装和配置。"
  fi
  disable_boot
  rm -f "$SERVICE" "$MODULES_LOAD" /usr/local/bin/brutalctl
  remove_custom_dkms
  rm -rf "$STATE_DIR" "$CONFIG"
  systemctl daemon-reload
  restore_proxy_services
  rm -f "$MANAGER"
  note "卸载完成。系统编译依赖和第三方 Brutal 安装未删除。"
}

menu() {
  while :; do
    cat <<'EOF'

TCP Brutal Custom 管理器
1. 安装 / 更新
2. 设置 IPv4 / IPv6 速率
3. 开启开机启动
4. 关闭开机启动
5. 查看状态
6. 卸载
0. 退出
EOF
    local choice
    read -r -p '请选择: ' choice
    case $choice in
      1) install_or_update ;;
      2) set_rate ;;
      3) need_root; enable_boot ;;
      4) need_root; disable_boot ;;
      5) status ;;
      6) uninstall ;;
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
  enable) need_root; enable_boot ;;
  disable) need_root; disable_boot ;;
  status) status ;;
  uninstall) uninstall ;;
  *) echo "用法: $0 {install|update|rate|apply|enable|disable|status|uninstall}" >&2; exit 2 ;;
esac
