#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 4 ]] || { echo "usage: $0 <tag> <version> <commit> <output-dir>" >&2; exit 2; }
tag=$1
version=$2
commit=$3
out=$4
[[ $tag == "v$version" && $version =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || { echo "invalid tag/version" >&2; exit 2; }
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "invalid commit" >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd)
[[ $(git -C "$repo" rev-parse HEAD) == "$commit" ]] || { echo "commit does not match HEAD" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rm -rf "$out"
mkdir -p "$out" "$work/source"
git -C "$repo" archive --format=tar HEAD | tar -xf - -C "$work/source"
cat >"$work/source/.tbc-release" <<META
TAG=$tag
VERSION=$version
COMMIT=$commit
META
mkdir -p "$work/package/TCP-Brutal-Custom-$version"
cp -a "$work/source/." "$work/package/TCP-Brutal-Custom-$version/"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -czf "$out/tcp-brutal-custom-source.tar.gz" \
  -C "$work/package" "TCP-Brutal-Custom-$version"
cp "$work/source/install.sh" "$out/install.sh"
chmod 0755 "$out/install.sh"
make -C "$repo" dkms-tarball
mv "$repo/dkms.tar.gz" "$out/tcp-brutal.dkms.tar.gz"
cat >"$out/release-manifest.txt" <<META
TAG=$tag
VERSION=$version
COMMIT=$commit
META
(cd "$out" && sha256sum install.sh tcp-brutal-custom-source.tar.gz tcp-brutal.dkms.tar.gz release-manifest.txt >SHA256SUMS)
