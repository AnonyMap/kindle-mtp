#!/bin/sh
# Installs what tests/run.sh needs on an Ubuntu GitHub runner, and fetches the
# pinned koreader-base ffi/ folder for the updater tests. Prints KOREADER_BASE.
set -eu
KOREADER_BASE_COMMIT="a5ad8957c002cc05f8e7b0af644a45ca990629d7"
sudo apt-get update -qq
sudo apt-get install -y -qq busybox luajit lua-dkjson lua-filesystem libarchive13t64 zip shellcheck lua-check mtools dosfstools >/dev/null
dir="${RUNNER_TEMP:-/tmp}/koreader-base"
rm -rf "$dir"
git init -q "$dir"
git -C "$dir" remote add origin https://github.com/koreader/koreader-base.git
git -C "$dir" sparse-checkout set ffi
git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$KOREADER_BASE_COMMIT"
git -C "$dir" checkout -q FETCH_HEAD
echo "KOREADER_BASE=$dir" >>"${GITHUB_ENV:-/dev/null}"
echo "$dir"
