#!/usr/bin/env bash
# Run busted inside a Kong base image so kong.db.schema.typedefs is available.
# Uses `resty` (OpenResty CLI) as the Lua runtime so that the `ngx` global is
# present — required by Kong's typedefs at module-load time.
# Usage: scripts/run-busted.sh [spec_path...]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPECS=("$@")
if [ "${#SPECS[@]}" -eq 0 ]; then
  SPECS=("spec/")
fi

docker run --rm \
  -v "$REPO_ROOT:/work:ro" \
  -w /work \
  --user root \
  kong:3.7.1-ubuntu \
  bash -c '
    set -e
    if ! command -v busted >/dev/null 2>&1; then
      # root required for first-run apt-get install on Kong base image
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq lua-busted >/dev/null 2>&1
    fi
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$ARCH" in
      arm64|aarch64) DEB_ARCH="aarch64-linux-gnu" ;;
      amd64|x86_64)  DEB_ARCH="x86_64-linux-gnu" ;;
      *)             DEB_ARCH="$ARCH-linux-gnu" ;;
    esac
    export LUA_PATH="./?.lua;./?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;"
    export LUA_CPATH="/usr/lib/${DEB_ARCH}/lua/5.1/?.so;/usr/lib/${DEB_ARCH}/lua/5.1/?/?.so;;"
    resty /usr/bin/busted "$@"
  ' -- "${SPECS[@]}"
