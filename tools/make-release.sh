#!/bin/sh
# Build the release assets the plugin's updater (and Storefront) expect:
#   dist/usbmtp.koplugin-v<VERSION>.zip   only the usbmtp.koplugin/ folder
#   dist/SHA256SUMS                       checksum line for that zip
# Usage:  sh tools/make-release.sh
set -eu
REPO="$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)"
cd "${REPO}"
VERSION="$(tr -d ' \n' < usbmtp.koplugin/mtp/VERSION)"
[ -n "${VERSION}" ] || { echo "empty usbmtp.koplugin/mtp/VERSION"; exit 1; }
ZIP="usbmtp.koplugin-v${VERSION}.zip"

file usbmtp.koplugin/mtp/bin/umtprd 2>/dev/null | grep -q "ARM" || { echo "bin/umtprd is not an ARM binary"; exit 1; }

rm -rf dist && mkdir -p dist
# Fixed timestamps and sorted entries so the zip is reproducible. Stamp a copy,
# never the working tree: git would miss same-size edits if mtimes were reset.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp -R usbmtp.koplugin "${STAGE}/"
find "${STAGE}/usbmtp.koplugin" \( -name '*.log' -o -name '.DS_Store' \) -exec rm -f {} +
find "${STAGE}/usbmtp.koplugin" -exec touch -h -d '2026-01-01 00:00:00 UTC' {} +
(cd "${STAGE}" && find usbmtp.koplugin -print | LC_ALL=C sort | zip -X -q -@ "${REPO}/dist/${ZIP}")
(cd dist && sha256sum "${ZIP}" > SHA256SUMS)
echo "version ${VERSION}"
cat dist/SHA256SUMS
