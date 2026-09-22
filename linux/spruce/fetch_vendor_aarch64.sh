#!/usr/bin/env bash
# Downloads the aarch64 pygame vendor directory for the spruce bundle.
#
# Unlike linux/onion's armv7 vendor, this ships NO SDL2. The Onion stack pins
# steward-fu's "Mini" build, which only presents through the SDL_Renderer path
# and only on the Miyoo Mini's panel. The eighteen aarch64 spruce devices each
# need a different backend - kmsdrm on RGB30 and Miniloong, mali-fbdev on the
# Anbernic BaseOS line, the vendor lib on the Brick - and spruce already ships
# the right one per device. common.sh puts that directory at the front of
# LD_LIBRARY_PATH at launch.
#
# The wheel fights this: auditwheel rewrites its bundled SDL2 to a hashed
# SONAME and points pygame at it through RUNPATH, so LD_LIBRARY_PATH is ignored.
# So the hashed copy is deleted and every DT_NEEDED naming it is rewritten back
# to the plain soname, which then resolves against whatever spruce provides.
#
# Usage:
#   linux/spruce/fetch_vendor_aarch64.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="${SCRIPT_DIR}/vendor-aarch64"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PYGAME_VERSION="${PYGAME_VERSION:-2.6.1}"
PATCHELF="${PATCHELF:-patchelf}"

command -v "${PATCHELF}" >/dev/null 2>&1 || {
  echo "patchelf is required (apt-get install patchelf)" >&2
  exit 1
}

WHEEL_URL="$(
  curl -L --fail -sS "https://pypi.org/pypi/pygame/${PYGAME_VERSION}/json" |
    python3 -c '
import json, sys
data = json.load(sys.stdin)
for entry in data["urls"]:
    name = entry["filename"]
    if "cp39" in name and "aarch64" in name and name.endswith(".whl"):
        print(entry["url"])
        break
'
)"

if [ -z "${WHEEL_URL}" ]; then
  echo "No cp39 aarch64 pygame ${PYGAME_VERSION} wheel on PyPI" >&2
  exit 1
fi

echo "Downloading $(basename "${WHEEL_URL}")..."
curl -L --fail -sS -o "${TMP_DIR}/pygame.whl" "${WHEEL_URL}"
mkdir -p "${TMP_DIR}/extracted"
unzip -q "${TMP_DIR}/pygame.whl" -d "${TMP_DIR}/extracted"

rm -rf "${VENDOR_DIR}"
mkdir -p "${VENDOR_DIR}"
cp -R "${TMP_DIR}/extracted/pygame" "${VENDOR_DIR}/pygame"
cp -R "${TMP_DIR}/extracted/pygame.libs" "${VENDOR_DIR}/pygame.libs"
# Needs a camera device nothing here has, and drags in extra deps.
rm -f "${VENDOR_DIR}"/pygame/_camera.cpython-39-*.so

# Hand SDL2 itself back to spruce, keeping the wheel's freetype/png/etc.
shopt -s nullglob
for bundled in "${VENDOR_DIR}"/pygame.libs/libSDL2-2*.so*; do
  hashed_name="$(basename "${bundled}")"
  plain_soname="libSDL2-2.0.so.0"

  echo "Unpinning ${hashed_name} -> ${plain_soname}"
  for elf in "${VENDOR_DIR}"/pygame/*.so "${VENDOR_DIR}"/pygame.libs/*.so*; do
    [ -f "${elf}" ] || continue
    if "${PATCHELF}" --print-needed "${elf}" 2>/dev/null | grep -qx "${hashed_name}"; then
      "${PATCHELF}" --replace-needed "${hashed_name}" "${plain_soname}" "${elf}"
    fi
  done

  rm -f "${bundled}"
done
shopt -u nullglob

if [ -e "${VENDOR_DIR}/pygame.libs/libSDL2-2.0.so.0" ]; then
  echo "SDL2 is still bundled - spruce's build would be ignored" >&2
  exit 1
fi

echo "Vendored aarch64 pygame ${PYGAME_VERSION} into ${VENDOR_DIR} (SDL2 supplied by spruce)"
