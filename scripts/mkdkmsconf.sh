#!/usr/bin/env bash

set -e

cd "$(dirname "$0")/.."

# The version comes from the BRUTAL_VERSION_* macros in brutal.h.
module_version() {
  sed -nE 's/^#define BRUTAL_VERSION_(MAJOR|MINOR|PATCH)[[:space:]]+([0-9]+).*/\2/p' brutal.h | paste -sd.
}

PACKAGE_NAME=${PACKAGE_NAME:-tcp-brutal}
PACKAGE_VERSION=${PACKAGE_VERSION:-$(module_version)}
[[ $PACKAGE_VERSION =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
  echo "PACKAGE_VERSION must use X.X.X format" >&2
  exit 1
}

cat << EOF
PACKAGE_NAME="$PACKAGE_NAME"
PACKAGE_VERSION="$PACKAGE_VERSION"

MAKE[0]="make KERNEL_DIR=\${kernel_source_dir} all"
CLEAN="make KERNEL_DIR=\${kernel_source_dir} clean"

BUILT_MODULE_NAME[0]="brutal"
DEST_MODULE_LOCATION[0]="/extra"

AUTOINSTALL="yes"
EOF
