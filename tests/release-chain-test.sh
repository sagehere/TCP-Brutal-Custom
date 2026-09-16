#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export BRUTAL_MANAGER_LIB=1
source "$repo/install.sh"

fixture="$tmp/fixture"
mkdir -p "$fixture/src/TCP-Brutal-Custom-2.5.3"
commit=1234567890abcdef1234567890abcdef12345678
tag=v2.5.3
cat >"$fixture/src/TCP-Brutal-Custom-2.5.3/.tbc-release" <<META
TAG=$tag
VERSION=2.5.3
COMMIT=$commit
META
cat >"$fixture/src/TCP-Brutal-Custom-2.5.3/brutal.h" <<'HDR'
#define BRUTAL_VERSION_MAJOR 2
#define BRUTAL_VERSION_MINOR 5
#define BRUTAL_VERSION_PATCH 2
HDR
tar -czf "$fixture/tcp-brutal-custom-source.tar.gz" -C "$fixture/src" TCP-Brutal-Custom-2.5.3
cat >"$fixture/release-manifest.txt" <<META
TAG=$tag
VERSION=2.5.3
COMMIT=$commit
META
printf 'dummy dkms\n' >"$fixture/tcp-brutal.dkms.tar.gz"
(cd "$fixture" && sha256sum tcp-brutal-custom-source.tar.gz tcp-brutal.dkms.tar.gz release-manifest.txt >SHA256SUMS)

asset_json() {
  local name=$1 file=$2 digest
  digest=$(sha256sum "$file" | awk '{print $1}')
  printf '{ "name": "%s", "digest": "sha256:%s" }' "$name" "$digest"
}
cat >"$fixture/release.json" <<JSON
{"tag_name":"$tag","target_commitish":"$commit","immutable":true,"assets":[
$(asset_json SHA256SUMS "$fixture/SHA256SUMS"),
$(asset_json release-manifest.txt "$fixture/release-manifest.txt"),
$(asset_json tcp-brutal-custom-source.tar.gz "$fixture/tcp-brutal-custom-source.tar.gz"),
$(asset_json tcp-brutal.dkms.tar.gz "$fixture/tcp-brutal.dkms.tar.gz")
]}
JSON

expected_sums_digest=$(sha256sum "$fixture/SHA256SUMS" | awk '{print $1}')
[[ $(release_asset_digest "$fixture/release.json" SHA256SUMS) == "$expected_sums_digest" ]]
(
  have() { [[ $1 != jq ]] && command -v "$1" >/dev/null 2>&1; }
  [[ $(release_asset_digest "$fixture/release.json" SHA256SUMS) == "$expected_sums_digest" ]]
)

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[[ $1 == release && ( $2 == verify || $2 == verify-asset ) ]]
GH
chmod +x "$fakebin/gh"
cat >"$fakebin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
out=""
url=""
while (($#)); do
  case $1 in
    -o) out=$2; shift 2 ;;
    -H|-A|--header) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  */releases/latest|*/releases/tags/v2.5.3) src="$FIXTURE/release.json" ;;
  */SHA256SUMS) src="$FIXTURE/SHA256SUMS" ;;
  */release-manifest.txt) src="$FIXTURE/release-manifest.txt" ;;
  */tcp-brutal-custom-source.tar.gz) src="$FIXTURE/tcp-brutal-custom-source.tar.gz" ;;
  *) echo "unexpected URL: $url" >&2; exit 2 ;;
esac
cp "$src" "$out"
CURL
chmod +x "$fakebin/curl"

run_good() {
  local work=$tmp/work-good
  rm -rf "$work"; mkdir -p "$work"
  GH_LOG="$tmp/gh.log" FIXTURE="$fixture" PATH="$fakebin:$PATH" download_source "$work"
}
[[ $(run_good) == "$commit" ]]
grep -q '^release verify v2.5.3 -R sagehere/TCP-Brutal-Custom$' "$tmp/gh.log"
[[ $(grep -c '^release verify-asset v2.5.3 ' "$tmp/gh.log") == 3 ]]

# An early unsafe member followed by a long listing used to trigger grep -q/SIGPIPE under pipefail.
cp "$fixture/tcp-brutal-custom-source.tar.gz" "$tmp/source-good.tar.gz"
cp "$fixture/SHA256SUMS" "$tmp/sums-good"
cp "$fixture/release.json" "$tmp/release-good.json"
python3 - "$fixture/tcp-brutal-custom-source.tar.gz" <<'PYTAR'
import io, sys, tarfile
path=sys.argv[1]
with tarfile.open(path, 'w:gz') as tf:
    data=b'escape'
    ti=tarfile.TarInfo('../escape')
    ti.size=len(data)
    tf.addfile(ti, io.BytesIO(data))
    for i in range(12000):
        ti=tarfile.TarInfo(f'TCP-Brutal-Custom-2.5.3/padding/{i:05d}')
        ti.size=0
        tf.addfile(ti)
PYTAR
(cd "$fixture" && sha256sum tcp-brutal-custom-source.tar.gz tcp-brutal.dkms.tar.gz release-manifest.txt >SHA256SUMS)
cat >"$fixture/release.json" <<JSON
{"tag_name":"$tag","target_commitish":"$commit","immutable":true,"assets":[
$(asset_json SHA256SUMS "$fixture/SHA256SUMS"),
$(asset_json release-manifest.txt "$fixture/release-manifest.txt"),
$(asset_json tcp-brutal-custom-source.tar.gz "$fixture/tcp-brutal-custom-source.tar.gz"),
$(asset_json tcp-brutal.dkms.tar.gz "$fixture/tcp-brutal.dkms.tar.gz")
]}
JSON
set +e
(run_good >"$tmp/unsafe-out" 2>"$tmp/unsafe-err")
unsafe_rc=$?
set -e
[[ $unsafe_rc -ne 0 ]]
grep -q '包含不安全路径' "$tmp/unsafe-err"
cp "$tmp/source-good.tar.gz" "$fixture/tcp-brutal-custom-source.tar.gz"
cp "$tmp/sums-good" "$fixture/SHA256SUMS"
cp "$tmp/release-good.json" "$fixture/release.json"

cp "$fixture/release.json" "$tmp/release-good.json"
sed -i 's/"immutable":true/"immutable":false/' "$fixture/release.json"
! (run_good >/dev/null 2>&1)
cp "$tmp/release-good.json" "$fixture/release.json"

sed -i 's/^COMMIT=.*/COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$fixture/release-manifest.txt"
! (run_good >/dev/null 2>&1)
cp "$tmp/release-good.json" "$fixture/release.json"
cat >"$fixture/release-manifest.txt" <<META
TAG=$tag
VERSION=2.5.3
COMMIT=$commit
META
(cd "$fixture" && sha256sum tcp-brutal-custom-source.tar.gz tcp-brutal.dkms.tar.gz release-manifest.txt >SHA256SUMS)

# Rebuild metadata digests after fixture repair.
cat >"$fixture/release.json" <<JSON
{"tag_name":"$tag","target_commitish":"$commit","immutable":true,"assets":[
$(asset_json SHA256SUMS "$fixture/SHA256SUMS"),
$(asset_json release-manifest.txt "$fixture/release-manifest.txt"),
$(asset_json tcp-brutal-custom-source.tar.gz "$fixture/tcp-brutal-custom-source.tar.gz")
]}
JSON
printf 'tamper\n' >>"$fixture/tcp-brutal-custom-source.tar.gz"
! (run_good >/dev/null 2>&1)

echo 'release chain tests passed'
