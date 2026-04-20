#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/ready_check.applescript"
DIST_DIR="$SCRIPT_DIR/dist"
APP_PATH="$DIST_DIR/PerfoMace Ready Check.app"

mkdir -p "$DIST_DIR"
rm -rf "$APP_PATH"
/usr/bin/osacompile -o "$APP_PATH" "$SOURCE_FILE"

echo "Built: $APP_PATH"
