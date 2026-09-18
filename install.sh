#!/usr/bin/env bash
# TCP Brutal Custom installer and manager for Debian/Ubuntu + systemd.
set -Eeuo pipefail

REPO="sagehere/TCP-Brutal-Custom"
RELEASES_API="https://api.github.com/repos/$REPO/releases"
RELEASE_SOURCE_ASSET="tcp-brutal-custom-source.tar.gz"
RELEASE_SUMS_ASSET="SHA256SUMS"
RELEASE_MANIFEST_ASSET="release-manifest.txt"
TBC_RELEASE_TAG=${TBC_RELEASE_TAG:-}
TBC_ALLOW_DOWNGRADE=${TBC_ALLOW_DOWNGRADE:-0}
PACKAGE="tcp-brutal-custom"
CONFIG="/etc/tcp-brutal-custom.conf"
MANAGER="/usr/local/bin/tbc"
LEGACY_MANAGER="/usr/local/bin/brutal-manager"
BRUTALCTL="/usr/local/bin/brutalctl"
SERVICE="/etc/systemd/system/tcp-brutal-custom.service"
WEB_SERVICE="/etc/systemd/system/tcp-brutal-custom-web.service"
STATS_SERVICE="/etc/systemd/system/tcp-brutal-custom-stats.service"
STATS_TIMER="/etc/systemd/system/tcp-brutal-custom-stats.timer"
WEB_CONFIG="/etc/tcp-brutal-custom-web.conf"
WEB_DIR="/usr/local/lib/tcp-brutal-custom"
MODULES_LOAD="/etc/modules-load.d/brutal.conf"
STATE_DIR="/var/lib/tcp-brutal-custom"
HOTPLUG_LOCK="/run/lock/tcp-brutal-custom.lock"
DKMS_SOURCE_ROOT=${DKMS_SOURCE_ROOT:-/usr/src}
PENDING_REBOOT="$STATE_DIR/reboot-required"
CLEANUP_REQUIRED="$STATE_DIR/cleanup-required"
PEERS_PROC="/proc/net/tcp_brutal/peers"
PORT_TABLE=233
PORT_RULE_PREF_BASE=12000
PORT_RULE_PREF_MAX=12127
AGGREGATE_FILTER_PREF=23300
AGGREGATE_FILTER_HANDLE=0x233
AGGREGATE_STATE="$STATE_DIR/aggregate-egress.state"
MANAGER_VERSION="2.5.4"

IPV4_RATE=80
IPV6_RATE=80
MODE=auto
TCP_PORTS=""
AGGREGATE_RATE=0
HOTPLUG_SERVICES=""
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
  IPV4_RATE=80; IPV6_RATE=80; MODE=auto; TCP_PORTS=""; AGGREGATE_RATE=0; HOTPLUG_SERVICES=""; COMMIT=""; VERSION=""; MANAGED=0
  [[ -f $CONFIG ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case $key in
      IPV4_RATE|IPV6_RATE|MODE|TCP_PORTS|AGGREGATE_RATE|HOTPLUG_SERVICES|COMMIT|VERSION|MANAGED) printf -v "$key" '%s' "$value" ;;
    esac
  done <"$CONFIG"
  valid_rate "$IPV4_RATE" && valid_rate "$IPV6_RATE" || die "配置文件中的速率无效：$CONFIG"
  [[ $MODE =~ ^(auto|ipv4|ipv6|dual)$ ]] || die "配置文件中的地址族模式无效：$CONFIG"
  TCP_PORTS=$(normalize_ports "$TCP_PORTS") || die "配置文件中的 TCP 端口无效：$CONFIG"
  [[ $AGGREGATE_RATE == 0 ]] || valid_rate "$AGGREGATE_RATE" || die "配置文件中的总出口速率无效：$CONFIG"
  HOTPLUG_SERVICES=$(normalize_hotplug_services "$HOTPLUG_SERVICES") || die "配置文件中的热插拔服务列表无效：$CONFIG"
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
TCP_PORTS=$TCP_PORTS
AGGREGATE_RATE=$AGGREGATE_RATE
HOTPLUG_SERVICES=$HOTPLUG_SERVICES
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

normalize_ports() {
  local raw=${1//[[:space:]]/}
  [[ -n $raw ]] || { printf '\n'; return 0; }
  awk -v spec="$raw" 'BEGIN {
    n=split(spec,a,",");
    for(i=1;i<=n;i++) {
      if(a[i] ~ /^[0-9]+$/) { lo=a[i]+0; hi=lo }
      else if(a[i] ~ /^[0-9]+-[0-9]+$/) { split(a[i],r,"-"); lo=r[1]+0; hi=r[2]+0 }
      else exit 2
      if(lo < 1 || hi > 65535 || lo > hi) exit 2
      for(p=lo;p<=hi;p++) used[p]=1
    }
    out=""; p=1
    while(p<=65535) {
      if(!used[p]) { p++; continue }
      first=p
      while(p<65535 && used[p+1]) p++
      token=(first==p ? first : first "-" p)
      out=(out=="" ? token : out "," token)
      p++
    }
    print out
  }'
}

valid_hotplug_service() {
  [[ $1 =~ ^[A-Za-z0-9_.:@-]+\.service$ ]] || return 1
  [[ $1 != tcp-brutal-custom.service && $1 != tcp-brutal-custom-web.service && $1 != tcp-brutal-custom-stats.service ]]
}

normalize_hotplug_services() {
  local raw=$1 service
  local -a services=()
  local -A seen=()
  [[ -n $raw ]] || { printf '\n'; return 0; }
  [[ $raw != ,* && $raw != *, && $raw != *,,* ]] || return 1
  IFS=, read -r -a services <<<"$raw"
  for service in "${services[@]}"; do
    valid_hotplug_service "$service" || return 1
    [[ ${seen[$service]+yes} ]] && return 1
    seen[$service]=1
  done
  (IFS=,; printf '%s\n' "${services[*]}")
}

hotplug_service_list() {
  local service
  local -a services=()
  IFS=, read -r -a services <<<"${HOTPLUG_SERVICES:-}"
  for service in "${services[@]}"; do
    [[ -n $service ]] && printf '%s\n' "$service"
  done
}

set_hotplug_services() {
  need_root; load_config
  case ${1:-} in
    "")
      if [[ -z $HOTPLUG_SERVICES ]]; then
        echo "热插拔服务: 未配置"
      else
        echo "热插拔服务:"
        hotplug_service_list
      fi
      return 0
      ;;
    --clear)
      [[ $# == 1 ]] || die "用法: tbc hotplug-services [服务名...] | --clear"
      HOTPLUG_SERVICES=""
      save_config
      note "热插拔服务已清空。"
      return 0
      ;;
  esac
  local raw state service
  raw=$(IFS=,; printf '%s' "$*")
  HOTPLUG_SERVICES=$(normalize_hotplug_services "$raw") || die "服务名无效、重复，或不允许停止管理器自身服务。"
  while IFS= read -r service; do
    state=$(systemctl show -p LoadState --value "$service" 2>/dev/null || true)
    [[ -n $state && $state != not-found ]] || die "找不到 systemd 服务：$service"
  done < <(hotplug_service_list)
  save_config
  note "热插拔服务已更新：$HOTPLUG_SERVICES"
}

configure_hotplug_services() {
  local answer
  need_root; load_config
  read_tty "热插拔时临时停止的 systemd 服务（空格分隔；none 清空）[$HOTPLUG_SERVICES]: " answer
  answer=${answer:-$HOTPLUG_SERVICES}
  case ${answer,,} in none|off|clear|0) set_hotplug_services --clear ;; *)
    local -a services=()
    read -r -a services <<<"$answer"
    set_hotplug_services "${services[@]}"
    ;;
  esac
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
  local family=$1 out
  out=$(ip "-$family" -o addr show scope global 2>/dev/null) || return 1
  [[ -n $out ]]
}

has_default_route() {
  local family=$1 out
  out=$(ip "-$family" route show default 2>/dev/null) || return 1
  [[ -n $out ]]
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
  have tc || packages+=(iproute2)
  have flock || packages+=(util-linux)
  have make || packages+=(make)
  have tar || packages+=(tar)
  have python3 || packages+=(python3)
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

  have dkms && have curl && have ip && have tc && have flock && have make && have tar && have python3 || die "必要工具安装不完整。"
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
module_supports_port_stats() { [[ -w /proc/net/tcp_brutal/port_stats ]]; }

sync_port_stats() {
  module_supports_port_stats || return 0
  "$BRUTALCTL" port-stats "$TCP_PORTS" >/dev/null
}

read_password() {
  local prompt=$1 variable=$2
  [[ -r /dev/tty ]] || die "当前没有可用的交互终端。"
  printf '%s' "$prompt" >&2
  IFS= read -rs "$variable" </dev/tty || die "无法从交互终端读取密码。"
  printf '\n' >&2
}

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

release_asset_digest() {
  local metadata=$1 asset=$2
  if have jq; then
    jq -r --arg asset "$asset" '[.assets[]? | select(.name == $asset) | .digest // empty][0] // empty' "$metadata" |
      sed -nE 's/^sha256:([0-9a-f]{64})$/\1/p' | sed -n '1p'
    return
  fi
  awk -v asset="\"$asset\"" 'BEGIN { RS="\"name\":" } { sub(/^[[:space:]]*/, "", $0) } index($0, asset)==1 { print; exit }' "$metadata" |
    grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]{64}"' |
    sed -nE 's/.*sha256:([0-9a-f]{64}).*/\1/p' | sed -n '1p'
}

release_field() {
  local metadata=$1 field=$2
  grep -oE "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$metadata" |
    sed -nE 's/^[^:]+:[[:space:]]*"([^"]*)"$/\1/p' | sed -n '1p'
}

release_immutable() {
  local metadata=$1
  grep -oE '"immutable"[[:space:]]*:[[:space:]]*(true|false)' "$metadata" |
    sed -nE 's/.*:[[:space:]]*(true|false)/\1/p' | sed -n '1p'
}

version_lt() {
  local a=$1 b=$2 first
  [[ $a != "$b" ]] || return 1
  first=$(printf '%s\n%s\n' "$a" "$b" | sort -V | sed -n '1p')
  [[ $first == "$a" ]]
}

release_manifest_value() {
  local file=$1 key=$2
  sed -nE "s/^${key}=([A-Za-z0-9._:\/-]+)$/\\1/p" "$file" | sed -n '1p'
}

verify_release_asset_digest() {
  local metadata=$1 file=$2 asset=$3 expected actual
  expected=$(release_asset_digest "$metadata" "$asset")
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || { echo "错误: Release 缺少 $asset 的可信 SHA256 digest。" >&2; return 1; }
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ $actual == "$expected" ]] || {
    echo "错误: Release 资产 $asset 的 GitHub digest 校验失败。" >&2
    return 1
  }
}

download_source() {
  local temp=$1 metadata tag immutable target product archive sums manifest
  local manifest_tag manifest_version manifest_commit source_tag source_version source_commit
  metadata="$temp/release.json"
  if [[ -n $TBC_RELEASE_TAG ]]; then
    [[ $TBC_RELEASE_TAG =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "TBC_RELEASE_TAG 格式无效。"
    curl -fsSL -H 'Accept: application/vnd.github+json' "$RELEASES_API/tags/$TBC_RELEASE_TAG" -o "$metadata"
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' "$RELEASES_API/latest" -o "$metadata"
  fi
  tag=$(release_field "$metadata" tag_name)
  immutable=$(release_immutable "$metadata")
  target=$(release_field "$metadata" target_commitish)
  [[ $tag =~ ^v([0-9]+[.][0-9]+[.][0-9]+)$ ]] || die "无法解析可信 Release 版本。"
  product=${BASH_REMATCH[1]}
  [[ $immutable == true ]] || die "Release $tag 不是 Immutable Release；拒绝作为安装/更新源。"
  [[ $target =~ ^[0-9a-f]{40}$ ]] || die "Release $tag 未绑定到固定 40 位提交；拒绝继续。"
  if have gh && gh release verify --help >/dev/null 2>&1 && gh release verify-asset --help >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 gh release verify "$tag" -R "$REPO" >/dev/null || die "Release $tag 的 GitHub attestation 验证失败。"
    local verify_attestation=1
  else
    local verify_attestation=0
    echo "警告: 当前 GitHub CLI 不支持 release attestation 本地验证；继续使用 immutable Release + GitHub asset digest + SHA256 + manifest 校验。" >&2
  fi
  if version_lt "$product" "$MANAGER_VERSION" && [[ $TBC_ALLOW_DOWNGRADE != 1 ]]; then
    die "Release $tag 低于当前管理器最低可信版本 v$MANAGER_VERSION；拒绝降级。"
  fi
  if [[ -n $VERSION && $VERSION =~ ^([0-9]+[.][0-9]+[.][0-9]+) ]] &&
     version_lt "$product" "${BASH_REMATCH[1]}" && [[ $TBC_ALLOW_DOWNGRADE != 1 ]]; then
    die "Release $tag 低于当前已安装版本 ${BASH_REMATCH[1]}；如确需降级请显式设置 TBC_ALLOW_DOWNGRADE=1。"
  fi

  sums="$temp/$RELEASE_SUMS_ASSET"
  manifest="$temp/$RELEASE_MANIFEST_ASSET"
  archive="$temp/$RELEASE_SOURCE_ASSET"
  curl -fsSL "https://github.com/$REPO/releases/download/$tag/$RELEASE_SUMS_ASSET" -o "$sums"
  verify_release_asset_digest "$metadata" "$sums" "$RELEASE_SUMS_ASSET" || die "Release 校验文件不可信。"
  curl -fsSL "https://github.com/$REPO/releases/download/$tag/$RELEASE_MANIFEST_ASSET" -o "$manifest"
  curl -fsSL "https://github.com/$REPO/releases/download/$tag/$RELEASE_SOURCE_ASSET" -o "$archive"
  if (( verify_attestation )); then
    GH_PROMPT_DISABLED=1 gh release verify-asset "$tag" "$sums" -R "$REPO" >/dev/null || die "$RELEASE_SUMS_ASSET attestation 验证失败。"
    GH_PROMPT_DISABLED=1 gh release verify-asset "$tag" "$manifest" -R "$REPO" >/dev/null || die "$RELEASE_MANIFEST_ASSET attestation 验证失败。"
    GH_PROMPT_DISABLED=1 gh release verify-asset "$tag" "$archive" -R "$REPO" >/dev/null || die "$RELEASE_SOURCE_ASSET attestation 验证失败。"
  fi
  (cd "$temp" && sha256sum -c "$RELEASE_SUMS_ASSET" --ignore-missing) >/dev/null || die "Release SHA256 校验失败。"
  verify_release_asset_digest "$metadata" "$manifest" "$RELEASE_MANIFEST_ASSET" || die "Release manifest digest 校验失败。"
  verify_release_asset_digest "$metadata" "$archive" "$RELEASE_SOURCE_ASSET" || die "Release source digest 校验失败。"

  manifest_tag=$(release_manifest_value "$manifest" TAG)
  manifest_version=$(release_manifest_value "$manifest" VERSION)
  manifest_commit=$(release_manifest_value "$manifest" COMMIT)
  [[ $manifest_tag == "$tag" && $manifest_version == "$product" && $manifest_commit == "$target" ]] ||
    die "Release manifest 与 GitHub Release 元数据不一致。"

  if tar -tzf "$archive" | grep -E '(^/|(^|/)\.\.(/|$))' >/dev/null; then
    die "Release source archive 包含不安全路径。"
  fi
  mkdir -p "$temp/source"
  tar -xzf "$archive" --strip-components=1 -C "$temp/source"
  [[ -r $temp/source/.tbc-release ]] || die "Release source 缺少 .tbc-release 身份文件。"
  source_tag=$(release_manifest_value "$temp/source/.tbc-release" TAG)
  source_version=$(release_manifest_value "$temp/source/.tbc-release" VERSION)
  source_commit=$(release_manifest_value "$temp/source/.tbc-release" COMMIT)
  [[ $source_tag == "$manifest_tag" && $source_version == "$manifest_version" && $source_commit == "$manifest_commit" ]] ||
    die "Release source 身份与 manifest 不一致。"
  printf '%s\n' "$manifest_commit"
}

source_product_version() {
  local source=$1 version
  version=$(sed -nE 's/^#define BRUTAL_VERSION_(MAJOR|MINOR|PATCH)[[:space:]]+([0-9]+).*/\2/p' "$source/brutal.h" | paste -sd.)
  [[ $version =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "无法读取模块版本。"
  printf '%s\n' "$version"
}

source_version() {
  local source=$1 sha=$2 product
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "无法生成 DKMS 构建身份：提交号无效。"
  product=$(source_product_version "$source")
  printf '%s.custom.%s\n' "$product" "${sha:0:7}"
}

build_commit_marker() {
  local version=$1
  [[ -r $DKMS_SOURCE_ROOT/$PACKAGE-$version/.tbc-commit ]] || return 1
  cat "$DKMS_SOURCE_ROOT/$PACKAGE-$version/.tbc-commit"
}

install_manager() {
  local source=$1
  install -Dm755 "$source/install.sh" "$MANAGER"
  ln -sfn "$MANAGER" "$LEGACY_MANAGER"
  install -Dm755 "$source/tools/brutalctl" "$BRUTALCTL"
  install -Dm755 "$source/web/tbc_web.py" "$WEB_DIR/tbc_web.py"
  install -Dm755 "$source/web/tbc_stats.py" "$WEB_DIR/tbc_stats.py"
  install -Dm644 "$source/web/tcp-brutal-custom-web.service" "$WEB_SERVICE"
  install -Dm644 "$source/web/tcp-brutal-custom-stats.service" "$STATS_SERVICE"
  install -Dm644 "$source/web/tcp-brutal-custom-stats.timer" "$STATS_TIMER"
  install -d -m 0755 "$STATE_DIR"
  cp -a "$source/." "$STATE_DIR/source-$VERSION"
  systemctl daemon-reload
}

build_dkms() {
  local source=$1 target="$DKMS_SOURCE_ROOT/$PACKAGE-$VERSION"
  [[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || die "缺少有效提交号，拒绝构建 DKMS。"
  rm -rf "$target"
  install -d -m 0755 "$target"
  cp -a "$source/." "$target/"
  printf '%s\n' "$COMMIT" >"$target/.tbc-commit"
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
    rm -rf "$DKMS_SOURCE_ROOT/$PACKAGE-$version" "$STATE_DIR/source-$version"
  done < <(dkms status -m "$PACKAGE" 2>/dev/null | sed -nE "s#^$PACKAGE/([^,]+),.*#\1#p" | sort -u)
  if valid_custom_version "$VERSION"; then
    dkms remove -m "$PACKAGE" -v "$VERSION" --all || return 1
    rm -rf "$DKMS_SOURCE_ROOT/$PACKAGE-$VERSION" "$STATE_DIR/source-$VERSION"
  fi
}

custom_version_installed() {
  dkms status -m "$PACKAGE" -v "$1" -k "$(uname -r)" 2>/dev/null | grep -E ': installed(,|$)' >/dev/null
}

remove_old_custom_dkms() {
  local keep=$1 version
  while IFS= read -r version; do
    [[ $version == "$keep" ]] && continue
    valid_custom_version "$version" || continue
    dkms remove -m "$PACKAGE" -v "$version" --all || return 1
    rm -rf "$DKMS_SOURCE_ROOT/$PACKAGE-$version" "$STATE_DIR/source-$version"
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

sanitize_route_line() {
  local line=$1
  sed -E 's/(^|[[:space:]])linkdown([[:space:]]|$)/ /g; s/[[:space:]]+expires[[:space:]]+[^[:space:]]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//' <<<"$line"
}

clone_port_route() {
  local family=$1 line=$2 clean
  local -a args=()
  clean=$(sanitize_route_line "$line")
  [[ -n $clean ]] || return 0
  read -r -a args <<<"$clean"
  case $clean in
    blackhole*|unreachable*|prohibit*|throw*)
      ip "-$family" route replace table "$PORT_TABLE" "${args[@]}"
      ;;
    *)
      ip "-$family" route replace table "$PORT_TABLE" "${args[@]}" congctl lock brutal
      ;;
  esac
}

sync_port_table_family() {
  local family=$1 line
  ip "-$family" route flush table "$PORT_TABLE" >/dev/null 2>&1 || true
  while IFS= read -r line; do
    [[ -n $line && $line != default\ * ]] || continue
    clone_port_route "$family" "$line" || return 1
  done < <(ip "-$family" route show table main)
  while IFS= read -r line; do
    [[ $line == default\ * ]] || continue
    clone_port_route "$family" "$line" || return 1
  done < <(ip "-$family" route show table main)
}

clear_managed_port_rules_family() {
  local family=$1 pref sport
  while read -r pref sport; do
    [[ -n ${pref:-} && -n ${sport:-} ]] || continue
    ip "-$family" rule del priority "$pref" ipproto tcp sport "$sport" lookup "$PORT_TABLE" 2>/dev/null ||       ip "-$family" rule del priority "$pref" 2>/dev/null || return 1
  done < <(ip "-$family" rule show | awk -v t="$PORT_TABLE" -v b="$PORT_RULE_PREF_BASE" -v m="$PORT_RULE_PREF_MAX" '
    {
      pref=$1; sub(/:$/, "", pref); sport=""; table=""; proto=""
      for(i=1;i<=NF;i++) {
        if($i=="sport") sport=$(i+1)
        if($i=="lookup") table=$(i+1)
        if($i=="ipproto") proto=$(i+1)
      }
      if(pref>=b && pref<=m && table==t && proto=="tcp" && sport!="") print pref, sport
    }')
}

managed_port_rules_family() {
  local family=$1
  ip "-$family" rule show | awk -v t="$PORT_TABLE" -v b="$PORT_RULE_PREF_BASE" -v m="$PORT_RULE_PREF_MAX" '
    {
      pref=$1; sub(/:$/, "", pref); sport=""; table=""; proto=""
      for(i=1;i<=NF;i++) {
        if($i=="sport") sport=$(i+1)
        if($i=="lookup") table=$(i+1)
        if($i=="ipproto") proto=$(i+1)
      }
      if(pref>=b && pref<=m && table==t && proto=="tcp" && sport!="") print pref, sport
    }'
}

check_port_policy_conflicts_family() {
  local family=$1 bad managed_count route_count
  bad=$(ip "-$family" rule show | awk -v t="$PORT_TABLE" -v b="$PORT_RULE_PREF_BASE" -v m="$PORT_RULE_PREF_MAX" '
    {
      pref=$1; sub(/:$/, "", pref); sport=""; table=""; proto=""
      for(i=1;i<=NF;i++) {
        if($i=="sport") sport=$(i+1)
        if($i=="lookup") table=$(i+1)
        if($i=="ipproto") proto=$(i+1)
      }
      ours=(pref>=b && pref<=m && table==t && proto=="tcp" && sport!="")
      if((table==t || (pref>=b && pref<=m)) && !ours) print
    }')
  [[ -z $bad ]] || { echo "错误: IPv$family 端口策略保留区域存在非受管规则：$bad" >&2; return 1; }
  managed_count=$(managed_port_rules_family "$family" | awk 'END {print NR+0}')
  route_count=$(ip "-$family" route show table "$PORT_TABLE" 2>/dev/null | awk 'END {print NR+0}')
  if (( route_count > 0 && managed_count == 0 )); then
    echo "错误: IPv$family 路由表 $PORT_TABLE 已被其他配置占用。" >&2
    return 1
  fi
}

default_route_path_count() {
  awk '
    $1=="default" {
      via="<direct>"; dev=""
      for(i=2;i<=NF;i++) {
        if($i=="via" && i<NF) {
          via=$(i+1)
          if((via=="inet" || via=="inet6") && i+2<=NF) via=$(i+2)
        }
        if($i=="dev" && i<NF) dev=$(i+1)
      }
      if(dev=="") { bad=1; next }
      seen[dev SUBSEP via]=1
    }
    END {
      if(bad) exit 2
      for(k in seen) n++
      print n+0
    }'
}

check_port_policy_complex_family() {
  local family=$1 bad defaults default_paths routes
  bad=$(ip "-$family" rule show | awk -v t="$PORT_TABLE" -v b="$PORT_RULE_PREF_BASE" -v m="$PORT_RULE_PREF_MAX" '
    {
      pref=$1; sub(/:$/, "", pref); sport=""; table=""; proto=""
      for(i=1;i<=NF;i++) {
        if($i=="sport") sport=$(i+1)
        if($i=="lookup") table=$(i+1)
        if($i=="ipproto") proto=$(i+1)
      }
      ours=(pref>=b && pref<=m && table==t && proto=="tcp" && sport!="")
      standard=(pref==0 && table=="local") || (pref==32766 && table=="main") || (pref==32767 && table=="default")
      if(!ours && !standard) print
    }')
  [[ -z $bad ]] || {
    echo "错误: IPv$family 检测到自定义策略路由规则；端口模式不会自动接管复杂策略路由：$bad" >&2
    return 1
  }
  routes=$(ip "-$family" route show table main)
  if grep -Eq '(^|[[:space:]])(nexthop|nhid|encap)([[:space:]]|$)' <<<"$routes"; then
    echo "错误: IPv$family main 路由表包含 multipath/nhid/encap，端口模式拒绝自动克隆。" >&2
    return 1
  fi
  defaults=$(awk '$1=="default" {n++} END {print n+0}' <<<"$routes")
  if (( defaults > 1 )); then
    if ! default_paths=$(default_route_path_count <<<"$routes"); then
      echo "错误: IPv$family main 路由表存在无法安全解析的默认路由，端口模式拒绝自动克隆。" >&2
      return 1
    fi
    if (( default_paths > 1 )); then
      echo "错误: IPv$family main 路由表存在多个默认路由且下一跳路径不同，端口模式拒绝自动选择。" >&2
      return 1
    fi
  fi
}

port_policy_preflight() {
  local normalized=$1 family
  check_port_policy_conflicts_family 4 || return 1
  check_port_policy_conflicts_family 6 || return 1
  [[ -n $normalized ]] || return 0
  if ip -o link show type vrf 2>/dev/null | grep . >/dev/null; then
    echo "错误: 检测到 VRF；端口模式不会自动修改 VRF/策略路由环境。" >&2
    return 1
  fi
  for family in 4 6; do
    family_enabled "$family" || continue
    check_port_policy_complex_family "$family" || return 1
  done
}

normalize_route_fingerprint_line() {
  local line=$1
  sed -E 's/[[:space:]]+expires[[:space:]]+[^[:space:]]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//' <<<"$line"
}

port_route_fingerprint_family() {
  local family=$1 routes line
  routes=$(ip "-$family" -N route show table main 2>/dev/null) || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    normalize_route_fingerprint_line "$line"
  done <<<"$routes" | LC_ALL=C sort | cksum | awk '{print $1 ":" $2}'
}

snapshot_port_policy_family() {
  local family=$1 dir=$2
  ip "-$family" -N route show table "$PORT_TABLE" >"$dir/routes$family" 2>/dev/null || : >"$dir/routes$family"
  managed_port_rules_family "$family" >"$dir/rules$family"
}

snapshot_port_policy() {
  local dir=$1
  snapshot_port_policy_family 4 "$dir" || return 1
  snapshot_port_policy_family 6 "$dir" || return 1
}

restore_port_policy_family() {
  local family=$1 dir=$2 line pref sport clean phase
  local -a args=()
  clear_managed_port_rules_family "$family" || return 1
  ip "-$family" route flush table "$PORT_TABLE" >/dev/null 2>&1 || true
  for phase in nondefault default; do
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      if [[ $phase == nondefault ]]; then
        [[ $line != default\ * ]] || continue
      else
        [[ $line == default\ * ]] || continue
      fi
      clean=$(sanitize_route_line "$line")
      [[ -n $clean ]] || continue
      read -r -a args <<<"$clean"
      ip "-$family" route add table "$PORT_TABLE" "${args[@]}" || return 1
    done <"$dir/routes$family"
  done
  while read -r pref sport; do
    [[ -n ${pref:-} && -n ${sport:-} ]] || continue
    ip "-$family" rule add priority "$pref" ipproto tcp sport "$sport" lookup "$PORT_TABLE" || return 1
  done <"$dir/rules$family"
}

restore_port_policy() {
  local dir=$1
  restore_port_policy_family 4 "$dir" || return 1
  restore_port_policy_family 6 "$dir" || return 1
}

reset_port_policy() {
  clear_managed_port_rules_family 4 || return 1
  clear_managed_port_rules_family 6 || return 1
  ip -4 route flush table "$PORT_TABLE" >/dev/null 2>&1 || true
  ip -6 route flush table "$PORT_TABLE" >/dev/null 2>&1 || true
}

HOTPLUG_PAUSED=0
HOTPLUG_PORT_SNAPSHOT=""
HOTPLUG_PORT_POLICY_PAUSED=0
HOTPLUG_SERVICES_STARTED=()
HOTPLUG_SOCKETS_STARTED=()

acquire_hotplug_lock() {
  install -d -m 0755 "${HOTPLUG_LOCK%/*}"
  have flock || die "缺少 flock，无法安全执行模块热插拔。"
  exec {HOTPLUG_LOCK_FD}>"$HOTPLUG_LOCK"
  flock -n "$HOTPLUG_LOCK_FD" || die "已有安装、更新或卸载操作正在进行。"
}

hotplug_report_busy() {
  local refs
  refs=$(awk '$1 == "brutal" { print $3; exit }' /proc/modules 2>/dev/null || true)
  echo "错误: brutal 模块仍被占用（引用计数：${refs:-未知}）。" >&2
  [[ -n ${HOTPLUG_SERVICES:-} ]] && echo "已尝试暂停: $HOTPLUG_SERVICES" >&2
  if have ss; then
    ss -tinp 2>/dev/null | awk '/brutal/ { print "占用连接: " $0 }' >&2 || true
  fi
  echo "请将持有 Brutal 连接的 systemd 服务加入 tbc hotplug-services 后重试；不会强制卸载或终止其他进程。" >&2
}

hotplug_remember_socket() {
  local socket=$1 known
  [[ $socket =~ ^[A-Za-z0-9_.:@-]+\.socket$ ]] || return 0
  for known in "${HOTPLUG_SOCKETS_STARTED[@]}"; do
    [[ $known == "$socket" ]] && return 0
  done
  systemctl is-active --quiet "$socket" && HOTPLUG_SOCKETS_STARTED+=("$socket")
}

hotplug_pause_services() {
  local service socket
  (( HOTPLUG_PAUSED )) && return 0
  [[ -n ${HOTPLUG_SERVICES:-} ]] || { hotplug_report_busy; return 1; }
  HOTPLUG_SERVICES_STARTED=()
  HOTPLUG_SOCKETS_STARTED=()
  HOTPLUG_PORT_POLICY_PAUSED=0
  while IFS= read -r service; do
    systemctl is-active --quiet "$service" && HOTPLUG_SERVICES_STARTED+=("$service")
    while IFS= read -r socket; do
      hotplug_remember_socket "$socket"
    done < <(systemctl show -p TriggeredBy --value "$service" 2>/dev/null | tr ' ' '\n')
  done < <(hotplug_service_list)
  HOTPLUG_PORT_SNAPSHOT=$(mktemp -d)
  if [[ -n $TCP_PORTS ]] && ! snapshot_port_policy "$HOTPLUG_PORT_SNAPSHOT"; then
    rm -rf "$HOTPLUG_PORT_SNAPSHOT"
    HOTPLUG_PORT_SNAPSHOT=""
    echo "错误: 无法备份端口策略，拒绝中断业务服务。" >&2
    return 1
  fi
  HOTPLUG_PAUSED=1
  for socket in "${HOTPLUG_SOCKETS_STARTED[@]}"; do
    if ! systemctl stop "$socket"; then
      echo "错误: 无法停止 socket 激活单元：$socket" >&2
      hotplug_resume_services 1 || true
      return 1
    fi
  done
  for service in "${HOTPLUG_SERVICES_STARTED[@]}"; do
    if ! systemctl stop "$service"; then
      echo "错误: 无法停止服务：$service" >&2
      hotplug_resume_services 1 || true
      return 1
    fi
  done
  if [[ -n $TCP_PORTS ]] && ! reset_port_policy; then
    echo "错误: 无法暂停受管端口策略。" >&2
    hotplug_resume_services 1 || true
    return 1
  fi
  [[ -z $TCP_PORTS ]] || HOTPLUG_PORT_POLICY_PAUSED=1
}

hotplug_resume_services() {
  local restore_policy=${1:-0} service socket failed=0
  (( HOTPLUG_PAUSED )) || return 0
  if (( restore_policy && HOTPLUG_PORT_POLICY_PAUSED )) && [[ -n $HOTPLUG_PORT_SNAPSHOT ]]; then
    restore_port_policy "$HOTPLUG_PORT_SNAPSHOT" || { echo "警告: 无法恢复热插拔前的端口策略。" >&2; failed=1; }
  fi
  for socket in "${HOTPLUG_SOCKETS_STARTED[@]}"; do
    systemctl start "$socket" || { echo "警告: 无法恢复 socket 激活单元：$socket" >&2; failed=1; }
  done
  for service in "${HOTPLUG_SERVICES_STARTED[@]}"; do
    systemctl start "$service" || { echo "警告: 无法恢复服务：$service" >&2; failed=1; }
  done
  [[ -z $HOTPLUG_PORT_SNAPSHOT ]] || rm -rf "$HOTPLUG_PORT_SNAPSHOT"
  HOTPLUG_PORT_SNAPSHOT=""
  HOTPLUG_PORT_POLICY_PAUSED=0
  HOTPLUG_PAUSED=0
  HOTPLUG_SERVICES_STARTED=()
  HOTPLUG_SOCKETS_STARTED=()
  return "$failed"
}

hotplug_unload_module() {
  local deadline
  module_loaded || return 0
  rmmod brutal && return 0
  hotplug_pause_services || return 1
  deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    rmmod brutal && return 0
    sleep 1
  done
  rmmod brutal && return 0
  hotplug_report_busy
  hotplug_resume_services 1 || true
  return 1
}

apply_port_rules() {
  local dry_run=${1:-0} normalized applied=0 family pref spec snapshot="" current_fingerprint
  local -a specs=()
  local -A route_fingerprint=()
  normalized=$(normalize_ports "$TCP_PORTS") || { echo "错误: TCP 端口配置无效。" >&2; return 1; }
  TCP_PORTS=$normalized
  if [[ -n $TCP_PORTS ]]; then
    IFS=, read -r -a specs <<<"$TCP_PORTS"
    ((${#specs[@]} <= PORT_RULE_PREF_MAX - PORT_RULE_PREF_BASE + 1)) || {
      echo "错误: 端口规则过多；最多支持 $((PORT_RULE_PREF_MAX - PORT_RULE_PREF_BASE + 1)) 个合并区间。" >&2
      return 1
    }
  fi
  port_policy_preflight "$TCP_PORTS" || return 1
  if [[ $dry_run == 1 ]]; then
    note "端口策略预检通过；未修改任何路由或规则。"
    return 0
  fi
  for family in 4 6; do
    family_enabled "$family" || continue
    route_fingerprint[$family]=$(port_route_fingerprint_family "$family") || return 1
  done
  snapshot=$(mktemp -d) || return 1
  if ! snapshot_port_policy "$snapshot"; then
    rm -rf "$snapshot"
    echo "错误: 无法创建端口策略快照，拒绝修改。" >&2
    return 1
  fi
  if ! reset_port_policy; then
    restore_port_policy "$snapshot" || true
    rm -rf "$snapshot"
    return 1
  fi
  if [[ -z $TCP_PORTS ]]; then
    sync_port_stats || return 1
    rm -rf "$snapshot"
    return 0
  fi
  for family in 4 6; do
    family_enabled "$family" || continue
    current_fingerprint=$(port_route_fingerprint_family "$family") || current_fingerprint=""
    if [[ $current_fingerprint != "${route_fingerprint[$family]}" ]]; then
      echo "错误: IPv$family main 路由表在预检后发生变化；已取消端口策略修改。" >&2
      restore_port_policy "$snapshot" || echo "警告: 端口策略自动回滚失败。" >&2
      rm -rf "$snapshot"
      return 1
    fi
    if ! sync_port_table_family "$family"; then
      restore_port_policy "$snapshot" || echo "警告: 端口策略自动回滚失败。" >&2
      rm -rf "$snapshot"
      return 1
    fi
    current_fingerprint=$(port_route_fingerprint_family "$family") || current_fingerprint=""
    if [[ $current_fingerprint != "${route_fingerprint[$family]}" ]]; then
      echo "错误: IPv$family main 路由表在复制过程中发生变化；已回滚端口策略。" >&2
      restore_port_policy "$snapshot" || echo "警告: 端口策略自动回滚失败。" >&2
      rm -rf "$snapshot"
      return 1
    fi
    pref=$PORT_RULE_PREF_BASE
    for spec in "${specs[@]}"; do
      if ! ip "-$family" rule add priority "$pref" ipproto tcp sport "$spec" lookup "$PORT_TABLE"; then
        restore_port_policy "$snapshot" || echo "警告: 端口策略自动回滚失败。" >&2
        rm -rf "$snapshot"
        return 1
      fi
      ((pref+=1))
    done
    applied=1
  done
  if (( ! applied )); then
    restore_port_policy "$snapshot" || echo "警告: 端口策略自动回滚失败。" >&2
    rm -rf "$snapshot"
    echo "错误: 未检测到可用地址族，无法应用端口策略。" >&2
    return 1
  fi
  rm -rf "$snapshot"
  sync_port_stats || return 1
}

ports_check() {
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "请先安装。"
  apply_port_rules 1 || die "端口策略预检失败。"
}

aggregate_filter_owned() {
  local dev=$1 out
  out=$(tc filter show dev "$dev" egress pref "$AGGREGATE_FILTER_PREF" 2>/dev/null || true)
  [[ -n $out && $out == *"handle $AGGREGATE_FILTER_HANDLE"* && $out == *"matchall"* && $out == *"police"* ]]
}

aggregate_filter_conflicts() {
  local dev=$1 out
  out=$(tc filter show dev "$dev" egress pref "$AGGREGATE_FILTER_PREF" 2>/dev/null || true)
  [[ -z $out ]] && return 1
  aggregate_filter_owned "$dev" && return 1
  return 0
}

aggregate_other_egress_filters() {
  local dev=$1 out
  out=$(tc filter show dev "$dev" egress 2>/dev/null || true)
  [[ -z $out ]] && return 1
  if aggregate_filter_owned "$dev"; then
    out=$(awk -v p="$AGGREGATE_FILTER_PREF" '
      /^filter / {keep=($0 !~ ("pref " p " ") && $0 !~ ("pref " p "$"))}
      keep {print}
    ' <<<"$out")
  fi
  [[ -n $out ]]
}

aggregate_resolve_dev() {
  local family line dev
  local -a devs=()
  for family in 4 6; do
    family_enabled "$family" || continue
    while IFS= read -r line; do
      dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$line")
      [[ -n $dev ]] && devs+=("$dev")
    done < <(ip "-$family" route show default)
  done
  mapfile -t devs < <(printf '%s\n' "${devs[@]}" | sed '/^$/d' | sort -u)
  ((${#devs[@]} == 1)) || {
    if ((${#devs[@]} == 0)); then
      echo "错误: 未检测到唯一出口接口，无法启用总出口保护。" >&2
    else
      echo "错误: 检测到多个出口接口（${devs[*]}）；总出口保护拒绝自动拆分限速。" >&2
    fi
    return 1
  }
  printf '%s\n' "${devs[0]}"
}

aggregate_burst_bytes() {
  awk -v r="$1" 'BEGIN { b=int(r*12500); if(b<16384)b=16384; if(b>4194304)b=4194304; print b }'
}

aggregate_state_load() {
  AGG_STATE_DEV=""; AGG_STATE_CLSACT=0
  [[ -r $AGGREGATE_STATE ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case $key in
      DEV) AGG_STATE_DEV=$value ;;
      CLSACT_CREATED) [[ $value == 0 || $value == 1 ]] || return 1; AGG_STATE_CLSACT=$value ;;
    esac
  done <"$AGGREGATE_STATE"
  [[ -z $AGG_STATE_DEV || $AGG_STATE_DEV =~ ^[A-Za-z0-9_.:@-]{1,32}$ ]] || return 1
}

aggregate_state_save() {
  local dev=$1 created=$2
  install -d -m 0755 "$STATE_DIR"
  {
    printf 'DEV=%s\n' "$dev"
    printf 'CLSACT_CREATED=%s\n' "$created"
  } >"$AGGREGATE_STATE.tmp"
  mv "$AGGREGATE_STATE.tmp" "$AGGREGATE_STATE"
}

aggregate_remove_owned_from_dev() {
  local dev=$1 remove_clsact=${2:-0}
  [[ -n $dev ]] || return 0
  if aggregate_filter_owned "$dev"; then
    tc filter del dev "$dev" egress pref "$AGGREGATE_FILTER_PREF" protocol all handle "$AGGREGATE_FILTER_HANDLE" matchall || return 1
  elif tc filter show dev "$dev" egress pref "$AGGREGATE_FILTER_PREF" 2>/dev/null | grep . >/dev/null; then
    echo "错误: $dev 的 egress pref $AGGREGATE_FILTER_PREF 不再属于本项目，拒绝删除。" >&2
    return 1
  fi
  if [[ $remove_clsact == 1 ]] && tc qdisc show dev "$dev" | grep '^qdisc clsact ' >/dev/null; then
    if ! tc filter show dev "$dev" ingress 2>/dev/null | grep . >/dev/null && ! tc filter show dev "$dev" egress 2>/dev/null | grep . >/dev/null; then
      tc qdisc del dev "$dev" clsact || return 1
    fi
  fi
}

aggregate_preflight() {
  local dev=$1
  ip link show dev "$dev" >/dev/null 2>&1 || { echo "错误: 出口接口不存在：$dev" >&2; return 1; }
  if aggregate_filter_conflicts "$dev"; then
    echo "错误: $dev 的 egress pref $AGGREGATE_FILTER_PREF 已被其他配置占用。" >&2
    return 1
  fi
  if aggregate_other_egress_filters "$dev"; then
    echo "错误: $dev 已存在其他 egress tc filter；为避免改变宿主流控语义，拒绝自动叠加。" >&2
    return 1
  fi
}

apply_aggregate_cap() {
  local dry_run=${1:-0} dev old_dev old_created=0 created=0 burst
  aggregate_state_load || { echo "错误: 总出口保护状态文件损坏。" >&2; return 1; }
  old_dev=$AGG_STATE_DEV; old_created=$AGG_STATE_CLSACT
  if [[ $AGGREGATE_RATE == 0 ]]; then
    if [[ $dry_run == 1 ]]; then
      note "总出口保护关闭；预检未修改系统。"
      return 0
    fi
    aggregate_remove_owned_from_dev "$old_dev" "$old_created" || return 1
    rm -f "$AGGREGATE_STATE"
    return 0
  fi
  valid_rate "$AGGREGATE_RATE" || { echo "错误: 总出口速率无效。" >&2; return 1; }
  dev=$(aggregate_resolve_dev) || return 1
  aggregate_preflight "$dev" || return 1
  if [[ $dry_run == 1 ]]; then
    note "总出口保护预检通过：$dev @ ${AGGREGATE_RATE} Mbps；未修改 root qdisc。"
    return 0
  fi
  if tc qdisc show dev "$dev" | grep '^qdisc clsact ' >/dev/null; then
    [[ $old_dev == "$dev" ]] && created=$old_created || created=0
  else
    tc qdisc add dev "$dev" clsact || return 1
    created=1
  fi
  burst=$(aggregate_burst_bytes "$AGGREGATE_RATE")
  if ! tc filter replace dev "$dev" egress pref "$AGGREGATE_FILTER_PREF" protocol all handle "$AGGREGATE_FILTER_HANDLE" matchall \
      action police rate "${AGGREGATE_RATE}mbit" burst "${burst}b" drop; then
    (( created )) && tc qdisc del dev "$dev" clsact >/dev/null 2>&1 || true
    return 1
  fi
  aggregate_state_save "$dev" "$created" || {
    aggregate_remove_owned_from_dev "$dev" "$created" || true
    return 1
  }
  if [[ -n $old_dev && $old_dev != "$dev" ]]; then
    aggregate_remove_owned_from_dev "$old_dev" "$old_created" || {
      echo "警告: 新出口保护已启用，但旧接口 $old_dev 的受管 filter 清理失败。" >&2
      return 1
    }
  fi
}

aggregate_check() {
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "请先安装。"
  apply_aggregate_cap 1 || die "总出口保护预检失败。"
}

set_aggregate() {
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "请先安装。"
  local answer old=$AGGREGATE_RATE
  if [[ -n ${1:-} ]]; then
    answer=$1
  else
    read_tty "总出口上限 Mbps [$AGGREGATE_RATE]（输入 none/off/0 关闭）: " answer
    answer=${answer:-$AGGREGATE_RATE}
  fi
  case ${answer,,} in none|off|clear|0) answer=0 ;; esac
  [[ $answer == 0 ]] || valid_rate "$answer" || die "速率必须为 0（关闭）或 0.5 到 1000000 Mbps。"
  [[ $answer != "$AGGREGATE_RATE" ]] || { note "总出口配置未变化。"; return 0; }
  AGGREGATE_RATE=$answer
  if ! apply_aggregate_cap; then
    AGGREGATE_RATE=$old
    apply_aggregate_cap || true
    die "应用总出口保护失败，已尝试恢复原配置。"
  fi
  save_config
  note "总出口保护已更新：$([[ $AGGREGATE_RATE == 0 ]] && echo 已关闭 || echo "${AGGREGATE_RATE} Mbps")"
}

apply_rules() {
  load_config
  [[ $MANAGED == 1 ]] || die "尚未完成安装。"
  apply_configured_rules || die "恢复规则失败。"
  apply_port_rules || die "恢复端口策略失败。"
  apply_aggregate_cap || die "恢复总出口保护失败。"
  module_supports_peers || die "当前加载的模块不支持活跃 IP 视图；请重启服务器完成更新。"
  finalize_pending_update || die "更新收尾验证失败；请检查当前加载模块后重试。"
}

write_service() {
  cat >"$SERVICE" <<EOF
[Unit]
Description=TCP Brutal Custom per-IP and TCP-port rules
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

web_password_hash() {
  WEB_PASSWORD="$1" python3 - <<'PY'
import base64, hashlib, os
password = os.environ['WEB_PASSWORD'].encode()
salt = os.urandom(16)
digest = hashlib.pbkdf2_hmac('sha256', password, salt, 200000)
print('200000$%s$%s' % (base64.b64encode(salt).decode(), base64.b64encode(digest).decode()))
PY
}

save_web_config() {
  local port=$1 user=$2 password=$3 hash
  [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "Web 面板端口无效。"
  [[ $user =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "管理员账户只能使用字母、数字、点、下划线和短横线。"
  (( ${#password} >= 12 )) || die "管理员密码至少需要 12 个字符。"
  hash=$(web_password_hash "$password") || die "无法生成管理员密码摘要。"
  umask 077
  printf 'PORT=%s\nUSER=%s\nPASSWORD_HASH=%s\n' "$port" "$user" "$hash" >"$WEB_CONFIG.tmp"
  mv "$WEB_CONFIG.tmp" "$WEB_CONFIG"
  chmod 600 "$WEB_CONFIG"
}

web_setup() {
  need_root
  local port=8080 user=admin password password2
  [[ -r $WEB_CONFIG ]] && {
    port=$(sed -n 's/^PORT=//p' "$WEB_CONFIG" | head -n1)
    user=$(sed -n 's/^USER=//p' "$WEB_CONFIG" | head -n1)
  }
  read_tty "Web 面板本机端口 [$port]: " port
  port=${port:-8080}
  read_tty "Web 管理员账户 [$user]: " user
  user=${user:-admin}
  read_password "Web 管理员密码（至少 12 位）: " password
  read_password "再次输入密码: " password2
  [[ $password == "$password2" ]] || die "两次输入的密码不一致。"
  save_web_config "$port" "$user" "$password"
  systemctl enable --now tcp-brutal-custom-stats.timer
  systemctl enable --now tcp-brutal-custom-web.service
  note "Web 面板已开启：http://127.0.0.1:$port/（请通过反向代理或 SSH 隧道访问）"
}

web_disable() {
  need_root
  systemctl disable --now tcp-brutal-custom-web.service 2>/dev/null || true
  note "Web 面板已关闭；管理员配置和统计数据仍会保留。"
}

web_status() {
  local port=8080 user=admin
  [[ -r $WEB_CONFIG ]] && {
    port=$(sed -n 's/^PORT=//p' "$WEB_CONFIG" | head -n1)
    user=$(sed -n 's/^USER=//p' "$WEB_CONFIG" | head -n1)
  }
  systemctl is-active --quiet tcp-brutal-custom-web.service && echo "Web 面板: 已开启（127.0.0.1:$port，账户 $user）" || echo "Web 面板: 未开启"
  systemctl is-active --quiet tcp-brutal-custom-stats.timer && echo "流量采集: 已开启" || echo "流量采集: 未开启"
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
  local old_version=$VERSION old_mode=$MODE old_ipv4=$IPV4_RATE old_ipv6=$IPV6_RATE old_tcp_ports=$TCP_PORTS old_aggregate=$AGGREGATE_RATE old_managed=$MANAGED
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
      MODE=$old_mode; IPV4_RATE=$old_ipv4; IPV6_RATE=$old_ipv6; TCP_PORTS=$old_tcp_ports; AGGREGATE_RATE=$old_aggregate; MANAGED=$old_managed
      ALLOW_RULE_REPLACE=0
      if (( old_managed )); then
        apply_configured_rules >/dev/null 2>&1 || echo "警告: 无法恢复原 TCP Brutal 规则。" >&2
        apply_port_rules >/dev/null 2>&1 || echo "警告: 无法恢复原端口策略。" >&2
        apply_aggregate_cap >/dev/null 2>&1 || echo "警告: 无法恢复原总出口保护。" >&2
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
    if (( HOTPLUG_PAUSED )); then
      hotplug_resume_services 1 || echo "警告: 热插拔回滚后仍有服务未能恢复。" >&2
    fi
    [[ -z $temp ]] || rm -rf "$temp"
    exit "$rc"
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT TERM
  if dkms status -m tcp-brutal 2>/dev/null | grep . >/dev/null; then
    has_upstream=1
    needs_migration=1
    mapfile -t upstream_versions < <(dkms status -m tcp-brutal 2>/dev/null | sed -nE 's#^tcp-brutal/([^,]+),.*#\1#p' | sort -u)
  fi
  if (( needs_migration )); then
    confirm "检测到旧 TCP Brutal 安装，将在新模块构建成功后迁移，是否继续？" || return 0
  fi
  install_dependencies
  acquire_hotplug_lock
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
  COMMIT=$sha
  if custom_version_installed "$VERSION"; then
    local installed_commit
    installed_commit=$(build_commit_marker "$VERSION" || true)
    [[ $installed_commit == "$COMMIT" ]] || die "检测到 DKMS 构建身份冲突：$VERSION 未绑定到目标提交 $COMMIT；拒绝继续。"
    note "当前构建已安装：$VERSION"
  else
    build_dkms "$source"
    needs_install=1
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
      hotplug_unload_module || die "上游 Brutal 模块仍被占用，无法安全迁移。"
    fi
    switch_needed=1
    if (( has_upstream )) && ! remove_upstream_dkms; then
      die "上游 DKMS 仍无法移除；新构建已保留，未替换规则。"
    fi
  fi
  if (( ! needs_migration )); then
    if module_loaded && { [[ $VERSION != "$old_version" ]] || [[ -f $PENDING_REBOOT ]]; }; then
      hotplug_unload_module || die "Brutal 模块仍被占用，无法完成热更新。"
      switch_needed=1
    elif ! module_loaded; then
      switch_needed=1
    fi
  fi
  if (( needs_migration )); then ALLOW_RULE_REPLACE=1; fi
  if ! apply_configured_rules; then
    die "新规则应用失败；已保留 DKMS 构建。"
  fi
  if ! apply_port_rules; then
    die "端口策略应用失败；已保留 DKMS 构建。"
  fi
  if ! apply_aggregate_cap; then
    die "总出口保护应用失败；已保留 DKMS 构建。"
  fi
  module_supports_peers || die "新模块缺少活跃 IP 视图接口。"
  save_config
  systemctl enable --now tcp-brutal-custom-stats.timer
  enable_boot
  rm -f "$PENDING_REBOOT"
  hotplug_resume_services 0 || echo "警告: 模块已更新，但部分热插拔服务未能恢复。" >&2
  switch_complete=1
  remove_old_custom_dkms "$VERSION" || echo "警告: 旧版 Custom DKMS 清理失败，可稍后重新执行更新。" >&2
  note "TCP Brutal Custom 安装完成。"
)

set_rate() {
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "请先安装。"
  local answer old_mode=$MODE old_ipv4=$IPV4_RATE old_ipv6=$IPV6_RATE
  if [[ -n ${1:-} || -n ${2:-} ]]; then
    IPV4_RATE=${1:-$IPV4_RATE}
    IPV6_RATE=${2:-$IPV6_RATE}
    MODE=${3:-$MODE}
  else
    read_tty "地址族模式 [auto/ipv4/ipv6/dual] [$MODE]: " answer
    MODE=${answer:-$MODE}
  fi
  [[ $MODE =~ ^(auto|ipv4|ipv6|dual)$ ]] || die "无效模式。"
  if [[ -z ${1:-} && -z ${2:-} ]]; then
    IPV4_RATE=$(ask_rate IPv4 "$IPV4_RATE")
    IPV6_RATE=$(ask_rate IPv6 "$IPV6_RATE")
  fi
  valid_rate "$IPV4_RATE" && valid_rate "$IPV6_RATE" || die "速率无效。"
  if ! apply_configured_rules || ! apply_port_rules || ! apply_aggregate_cap; then
    MODE=$old_mode; IPV4_RATE=$old_ipv4; IPV6_RATE=$old_ipv6
    apply_configured_rules || true
    apply_port_rules || true
    apply_aggregate_cap || true
    die "应用新速率失败，已尝试恢复原规则、端口策略和总出口保护。"
  fi
  save_config
  note "速率已更新。"
}

set_ports() {
  need_root; load_config
  [[ $MANAGED == 1 ]] || die "请先安装。"
  local answer normalized old_ports=$TCP_PORTS
  if [[ -n ${1:-} ]]; then
    answer=$1
  else
    read_tty "Brutal TCP 端口 [$TCP_PORTS]（如 443,8443,10000-10100；输入 none 清除）: " answer
    answer=${answer:-$TCP_PORTS}
  fi
  case ${answer,,} in none|off|clear|0) answer="" ;; esac
  normalized=$(normalize_ports "$answer") || die "端口格式无效；支持单端口、逗号分隔和端口范围。"
  [[ $normalized != "$TCP_PORTS" ]] || { note "端口配置未变化。"; return 0; }
  TCP_PORTS=$normalized
  if ! apply_port_rules; then
    TCP_PORTS=$old_ports
    apply_port_rules || true
    die "应用端口策略失败，已尝试恢复原配置。"
  fi
  save_config
  note "Brutal TCP 端口已更新：${TCP_PORTS:-未配置}"
}

status() {
  need_root; load_config
  echo "TCP Brutal Custom"
  echo "提交: ${COMMIT:-未安装}"
  if [[ -n $VERSION ]]; then
    echo "产品版本: ${VERSION%%.custom.*}"
    echo "DKMS 构建: $VERSION"
  else
    echo "产品版本: 未安装"
    echo "DKMS 构建: 未安装"
  fi
  echo "配置速率: IPv4 ${IPV4_RATE} Mbps，IPv6 ${IPV6_RATE} Mbps"
  echo "Brutal TCP 端口: ${TCP_PORTS:-未配置}"
  echo "总出口保护: $([[ $AGGREGATE_RATE == 0 ]] && echo 已关闭 || echo "${AGGREGATE_RATE} Mbps")"
  echo "热插拔服务: ${HOTPLUG_SERVICES:-未配置}"
  web_status
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
  acquire_hotplug_lock
  local complete=0 changed=0 old_aggregate=$AGGREGATE_RATE
  cleanup_uninstall() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if (( changed && ! complete )); then
      modprobe brutal >/dev/null 2>&1 || echo "警告: 无法重新加载 brutal 模块。" >&2
      apply_configured_rules >/dev/null 2>&1 || echo "警告: 无法恢复卸载前的规则。" >&2
      apply_port_rules >/dev/null 2>&1 || echo "警告: 无法恢复卸载前的端口策略。" >&2
      AGGREGATE_RATE=$old_aggregate
      apply_aggregate_cap >/dev/null 2>&1 || echo "警告: 无法恢复卸载前的总出口保护。" >&2
    fi
    if (( HOTPLUG_PAUSED )); then
      hotplug_resume_services 1 || echo "警告: 热插拔回滚后仍有服务未能恢复。" >&2
    fi
    exit "$rc"
  }
  trap cleanup_uninstall EXIT
  trap 'exit 130' INT TERM
  confirm "确认卸载 TCP Brutal Custom？" || return 0
  changed=1
  if [[ -n $TCP_PORTS ]]; then
    check_port_policy_conflicts_family 4 || die "端口策略存在冲突，拒绝卸载。"
    check_port_policy_conflicts_family 6 || die "端口策略存在冲突，拒绝卸载。"
  fi
  hotplug_unload_module || die "Brutal 模块仍被占用，无法安全卸载。"
  [[ -z $TCP_PORTS ]] || reset_port_policy || die "清理端口策略失败。"
  AGGREGATE_RATE=0
  apply_aggregate_cap || die "清理总出口保护失败。"
  remove_custom_dkms || die "DKMS 移除失败，已保留安装记录。"
  disable_boot
  systemctl disable --now tcp-brutal-custom-web.service tcp-brutal-custom-stats.timer 2>/dev/null || true
  rm -f "$SERVICE" "$WEB_SERVICE" "$STATS_SERVICE" "$STATS_TIMER" "$MODULES_LOAD" "$BRUTALCTL" "$WEB_CONFIG"
  rm -rf "$WEB_DIR"
  rm -rf "$STATE_DIR" "$CONFIG"
  systemctl daemon-reload
  rm -f "$MANAGER" "$LEGACY_MANAGER"
  hotplug_resume_services 0 || echo "警告: 卸载完成，但部分热插拔服务未能恢复。" >&2
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
3. 设置 Brutal TCP 端口
4. 设置总出口带宽保护
5. 开启开机启动
6. 关闭开机启动
7. 查看状态
8. 查看活跃 IP
9. 实时查看活跃 IP
10. 卸载
11. 端口策略安全预检（不修改系统）
12. 总出口保护安全预检（不修改系统）
13. 开启或重置 Web 面板
14. 关闭 Web 面板
15. 设置热插拔服务
0. 退出
EOF
    local choice
    read_tty '请选择: ' choice
    case $choice in
      1) run_menu_action install_or_update ;;
      2) run_menu_action set_rate ;;
      3) run_menu_action set_ports ;;
      4) run_menu_action set_aggregate ;;
      5) run_menu_action enable_boot ;;
      6) run_menu_action disable_boot ;;
      7) run_menu_action status ;;
      8) run_menu_action view ;;
      9) run_menu_action view --watch ;;
      10) run_menu_action uninstall ;;
      11) run_menu_action ports_check ;;
      12) run_menu_action aggregate_check ;;
      13) run_menu_action web_setup ;;
      14) run_menu_action web_disable ;;
      15) run_menu_action configure_hotplug_services ;;
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
  rate) set_rate "${2:-}" "${3:-}" "${4:-}" ;;
  ports) set_ports "${2:-}" ;;
  ports-check) ports_check ;;
  aggregate) set_aggregate "${2:-}" ;;
  aggregate-check) aggregate_check ;;
  apply) apply_rules ;;
  enable) enable_boot ;;
  disable) disable_boot ;;
  status) status ;;
  view) shift; view "$@" ;;
  hotplug-services) shift; set_hotplug_services "$@" ;;
  web) case ${2:-status} in setup|on|enable) web_setup ;; off|disable) web_disable ;; status) web_status ;; *) die "用法: tbc web {setup|on|off|status}" ;; esac ;;
  uninstall) uninstall ;;
  *) echo "用法: $0 {install|update|rate [IPv4 Mbps] [IPv6 Mbps]|ports [端口]|ports-check|aggregate [Mbps]|aggregate-check|apply|enable|disable|status|view [--watch]|hotplug-services [服务名...]|web {setup|on|off|status}|uninstall}" >&2; exit 2 ;;
esac
