#!/usr/bin/env bash

set -e

cd "$(dirname "$0")/.."

# The version comes from the BRUTAL_VERSION_* macros in brutal.h.
module_version() {
  sed -nE 's/^#define BRUTAL_VERSION_(MAJOR|MINOR|PATCH)[[:space:]]+([0-9]+).*/\2/p' brutal.h | paste -sd.
}

PACKAGE_NAME=${PACKAGE_NAME:-tcp-brutal}
PACKAGE_VERSION=${PACKAGE_VERSION:-$(module_version)}
default_build_id() {
  local id=
  if [[ -r .tbc-release ]]; then
    id=$(sed -nE 's/^COMMIT=([0-9a-f]{40})$/\1/p' .tbc-release | sed -n '1p')
  elif [[ -r .tbc-commit ]]; then
    id=$(sed -nE 's/^([0-9a-f]{40})$/\1/p' .tbc-commit | sed -n '1p')
  elif command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    id=$(git rev-parse HEAD 2>/dev/null || true)
  fi
  [[ $id =~ ^[0-9a-f]{40}$ ]] && printf '%s\n' "$id" || printf '%040d\n' 0
}

BRUTAL_BUILD_ID=${BRUTAL_BUILD_ID:-$(default_build_id)}
[[ $PACKAGE_VERSION =~ ^[0-9]+[.][0-9]+[.][0-9]+([.]custom[.][0-9a-f]{7})?$ ]] || {
  echo "PACKAGE_VERSION must use X.X.X or X.X.X.custom.<sha7> format" >&2
  exit 1
}
[[ $BRUTAL_BUILD_ID =~ ^[0-9a-f]{40}$ ]] || {
  echo "BRUTAL_BUILD_ID must be a 40-character lowercase Git SHA or all zeros" >&2
  exit 1
}

cat << EOF
PACKAGE_NAME="$PACKAGE_NAME"
PACKAGE_VERSION="$PACKAGE_VERSION"

MAKE[0]="make KERNEL_DIR=\${kernel_source_dir} BRUTAL_BUILD_ID=$BRUTAL_BUILD_ID all"
CLEAN="make KERNEL_DIR=\${kernel_source_dir} clean"

BUILT_MODULE_NAME[0]="brutal"
DEST_MODULE_LOCATION[0]="/extra"

AUTOINSTALL="yes"
EOF
