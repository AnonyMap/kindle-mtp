#!/bin/sh
# Rebuild usbmtp.koplugin/mtp/bin/umtprd from source.
#
# Needs: git, make, and an ARM cross compiler (Debian/Ubuntu: gcc-arm-linux-gnueabi).
# On Bazzite/Fedora Atomic, run it inside an Ubuntu toolbox/distrobox:
#   distrobox create -i ubuntu:24.04 -n kbuild && distrobox enter kbuild
#   sudo apt install -y git make gcc-arm-linux-gnueabi
#   sh tools/build-umtprd.sh
set -eu

UPSTREAM="https://github.com/viveris/uMTP-Responder.git"
COMMIT="85a26f4"   # v1.10.1, the version the shipped binary was built from
CC="${CC:-arm-linux-gnueabi-gcc}"
# umtprd embeds __DATE__/__TIME__; pin them so builds are byte-for-byte reproducible.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1793577600}"  # 2026-11-01 00:00 UTC
export TZ=UTC

REPO="$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)"
SRCDIR="${REPO}/usbmtp.koplugin/mtp/umtprd-source"
OUT="${REPO}/usbmtp.koplugin/mtp/bin/umtprd"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

command -v "${CC}" >/dev/null || { echo "missing cross compiler: ${CC}"; exit 1; }

git clone -q "${UPSTREAM}" "${WORK}/umtp"
git -C "${WORK}/umtp" checkout -q "${COMMIT}"
for p in "${SRCDIR}"/*.patch; do
    [ -e "${p}" ] || continue
    echo "applying $(basename "${p}")"
    (cd "${WORK}/umtp" && patch -p1 <"${p}")
done

make -C "${WORK}/umtp" CC="${CC}" \
    CFLAGS="-I./inc -Wall -O2 -march=armv7-a -mtune=cortex-a9" \
    LDFLAGS="-static -s -lpthread -lrt" -j"$(nproc 2>/dev/null || echo 2)"

mkdir -p "$(dirname "${OUT}")"
cp "${WORK}/umtp/umtprd" "${OUT}"
file "${OUT}" 2>/dev/null || true
echo "built ${OUT}"
