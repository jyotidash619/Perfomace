#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/ready_check.applescript"
DIST_DIR="$SCRIPT_DIR/dist"
APP_PATH="$DIST_DIR/PerfoMace Ready Check.app"
ICON_PATH="$SCRIPT_DIR/icons/PerfoMace_Ready_Check.icns"

ensure_tmpdir() {
  local candidate="${TMPDIR:-}"
  local probe=""

  if [ -n "$candidate" ] && [ -d "$candidate" ] && [ -w "$candidate" ]; then
    probe="$(mktemp "$candidate/perfomace_ready_check_tmp.XXXXXX" 2>/dev/null || true)"
    if [ -n "$probe" ]; then
      rm -f "$probe"
      return 0
    fi
  fi

  local fallback=""
  fallback="$(mktemp -d "/tmp/perfomace_ready_check_tmp.XXXXXX" 2>/dev/null || true)"
  if [ -z "$fallback" ]; then
    mkdir -p /tmp/perfomace_ready_check_tmp_fallback
    fallback="/tmp/perfomace_ready_check_tmp_fallback"
  fi

  export TMPDIR="$fallback"
  echo "Using fallback TMPDIR: $TMPDIR"
}

ensure_tmpdir

mkdir -p "$DIST_DIR"
rm -rf "$APP_PATH"
/usr/bin/osacompile -o "$APP_PATH" "$SOURCE_FILE"

if [ -f "$ICON_PATH" ]; then
  cp -f "$ICON_PATH" "$APP_PATH/Contents/Resources/applet.icns"
fi

echo "Built: $APP_PATH"
