#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEBASE_DIR="$ROOT_DIR/codebase"
CHECK_SCRIPT="$CODEBASE_DIR/scripts/setup_env.sh"

if [ ! -f "$CHECK_SCRIPT" ]; then
  echo "❌ Ready-check script not found at: $CHECK_SCRIPT"
  exit 1
fi

echo "🩺 Starting PerfoMace Ready Check..."
cd "$CODEBASE_DIR"
bash "./scripts/setup_env.sh"
