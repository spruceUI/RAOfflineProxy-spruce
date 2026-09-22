#!/usr/bin/env bash
set -euo pipefail

# spruceOS bundle. One zip for the whole spruce line, which is two architectures:
# MiyooMini and A30 are armv7, the other eighteen devices are aarch64. Both payloads
# ship under runtime/<arch> and lib/<arch>, and common.sh picks one at launch.
#
# armv7 is Onion's stack verbatim - same App layout, same hardware, same "Mini" SDL2 -
# so it is taken from linux/onion rather than duplicated here.
# aarch64 carries no SDL2: spruce ships a working one per device and common.sh points
# at it (see fetch_vendor_aarch64.sh).
#
# Run these once if the caches are missing:
#   linux/onion/fetch_runtime.sh
#   linux/onion/fetch_vendor.sh
#   linux/spruce/fetch_runtime_aarch64.sh
#   linux/spruce/fetch_vendor_aarch64.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ONION_DIR="${LINUX_DIR}/onion"
DIST_DIR="${SCRIPT_DIR}/dist"
BUILD_DIR="${DIST_DIR}/raofflineproxy-spruce-app"
APP_DIR="${BUILD_DIR}/App/RAOfflineProxy"
RUNTIME_CACHE_DIR="${ONION_DIR}/runtime-cache"
RUNTIME_ARCHIVE_NAME="cpython-3.9.20+20241016-armv7-unknown-linux-gnueabihf-install_only_stripped.tar.gz"
RUNTIME_ARCHIVE_PATH="${RUNTIME_CACHE_DIR}/${RUNTIME_ARCHIVE_NAME}"
RUNTIME_ARCHIVE_NAME_ARM64="cpython-3.9.20+20241016-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz"
RUNTIME_ARCHIVE_PATH_ARM64="${RUNTIME_CACHE_DIR}/${RUNTIME_ARCHIVE_NAME_ARM64}"
VENDOR_DIR="${ONION_DIR}/vendor"
VENDOR_DIR_ARM64="${SCRIPT_DIR}/vendor-aarch64"
APP_VERSION="${RAOFFLINEPROXY_APP_VERSION:-1.13.0-alpha1}"
ZIP_NAME="RAOfflineProxy-Spruce-v${APP_VERSION}.zip"

TARGET="arm-linux-gnueabihf.2.17" OUT_DIR="${SCRIPT_DIR}/native/armv7" \
  "${LINUX_DIR}/build_rchash.sh"
TARGET="aarch64-linux-gnu.2.17" OUT_DIR="${SCRIPT_DIR}/native/aarch64" \
  "${LINUX_DIR}/build_rchash.sh"

rm -rf "${BUILD_DIR}"
rm -f "${DIST_DIR}/${ZIP_NAME}"

mkdir -p "${APP_DIR}"

export COPYFILE_DISABLE=1

cp -R "${SCRIPT_DIR}/app/RAOfflineProxy/." "${APP_DIR}/"
mkdir -p "${APP_DIR}/app"
cp -R "${LINUX_DIR}/raofflineproxy" "${APP_DIR}/app/raofflineproxy"
cp "${LINUX_DIR}/../docs/public/logo-320.png" "${APP_DIR}/app/raofflineproxy/logo-320.png"
cp "${LINUX_DIR}/requirements.txt" "${APP_DIR}/app/requirements.txt"
"${LINUX_DIR}/resize_icon.sh" "${LINUX_DIR}/../docs/public/logo.png" "${APP_DIR}/icon.png" 74
mkdir -p "${APP_DIR}/data"

for arch in armv7 aarch64; do
  mkdir -p "${APP_DIR}/lib/${arch}"
  cp "${SCRIPT_DIR}/native/${arch}/libraproxy_rchash.so" "${APP_DIR}/lib/${arch}/libraproxy_rchash.so"
done

install_runtime() {
  arch="$1"
  archive="$2"
  vendor="$3"

  if [ ! -f "${archive}" ]; then
    echo "No cached ${arch} runtime at ${archive} — see the fetch scripts above"
    return
  fi

  runtime_dir="${APP_DIR}/runtime/${arch}"
  rm -rf "${runtime_dir}"
  mkdir -p "${runtime_dir}"
  tar -xzf "${archive}" -C "${runtime_dir}" --strip-components 1
  python3 "${SCRIPT_DIR}/flatten_symlinks.py" "${runtime_dir}"

  if [ ! -d "${vendor}/pygame" ]; then
    echo "No ${arch} vendor directory at ${vendor} — menu-sdl will be unavailable"
    return
  fi

  site_packages="${runtime_dir}/lib/python3.9/site-packages"
  mkdir -p "${site_packages}"
  rm -rf "${site_packages}/pygame"
  cp -R "${vendor}/pygame" "${site_packages}/pygame"
  if [ -d "${vendor}/pygame.libs" ]; then
    cp "${vendor}"/pygame.libs/* "${APP_DIR}/lib/${arch}/"
  fi
  echo "Included ${arch} pygame from ${vendor}"
}

install_runtime armv7 "${RUNTIME_ARCHIVE_PATH}" "${VENDOR_DIR}"
install_runtime aarch64 "${RUNTIME_ARCHIVE_PATH_ARM64}" "${VENDOR_DIR_ARM64}"

if [ -e "${APP_DIR}/lib/aarch64/libSDL2-2.0.so.0" ]; then
  echo "aarch64 payload bundles an SDL2 — spruce's per-device build would be shadowed" >&2
  exit 1
fi

find "${APP_DIR}" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "${APP_DIR}" -name "*.pyc" -delete

chmod +x "${APP_DIR}/launch.sh"
chmod +x "${APP_DIR}/autostart-launch.sh"

mkdir -p "${DIST_DIR}"

BUILD_DIR="${BUILD_DIR}" ZIP_PATH="${DIST_DIR}/${ZIP_NAME}" python3 - <<'PY'
import os
import zipfile
from pathlib import Path

build_dir = Path(os.environ["BUILD_DIR"])
zip_path = Path(os.environ["ZIP_PATH"])

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(build_dir.rglob("*")):
        if path.is_dir():
            continue
        archive.write(path, path.relative_to(build_dir))
PY

echo "Created ${BUILD_DIR}"
echo "Created ${DIST_DIR}/${ZIP_NAME}"
