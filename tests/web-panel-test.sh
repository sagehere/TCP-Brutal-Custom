#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
python3 -m py_compile "$repo/web/tbc_web.py" "$repo/web/tbc_stats.py"
bash -n "$repo/install.sh"
grep -q 'brutalctl port-stats' "$repo/README.zh.md"
grep -q 'tcp-brutal-custom-web.service' "$repo/install.sh"
