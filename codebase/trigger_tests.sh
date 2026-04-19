#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🚀 Running ONLY Performance Tests..."

xcodebuild test \
  -project "$PROJECT_ROOT/PerfoMace.xcodeproj" \
  -scheme PerfoMace \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:PerfoMaceTests/PerfoMaceTests/testPerformanceExample
