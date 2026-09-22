#!/usr/bin/env bash
# The aarch64 CPython for the spruce bundle. Same release and cache as the armv7
# one linux/onion pulls, just the other triple.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/../onion/fetch_runtime.sh" \
  "cpython-3.9.20+20241016-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz"
