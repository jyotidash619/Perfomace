#!/bin/bash

PERFOMACE_SETUP_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  PERFOMACE_SETUP_SOURCED=1
fi

setup_finish() {
  local code="${1:-0}"
  if [ "$PERFOMACE_SETUP_SOURCED" -eq 1 ]; then
    return "$code"
  fi
  exit "$code"
}

setup_info() {
  echo "ℹ️  $*"
}

setup_ok() {
  echo "✅ $*"
}

setup_warn() {
  echo "⚠️ $*"
}

setup_fail() {
  echo "❌ $*"
  SETUP_FAILED=1
}

SETUP_FAILED=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_ROOT="$PROJECT_ROOT/results"
INTERNAL_RESULTS_ROOT="$RESULTS_ROOT/.perfo_internal"

repair_tmpdir() {
  local candidate="${TMPDIR:-}"
  local probe=""

  if [ -n "$candidate" ] && [ -d "$candidate" ] && [ -w "$candidate" ]; then
    probe="$(mktemp "$candidate/perfomace_tmp_check.XXXXXX" 2>/dev/null || true)"
    if [ -n "$probe" ]; then
      rm -f "$probe"
      setup_ok "Temporary directory is healthy: $candidate"
      return 0
    fi
  fi

  setup_warn "TMPDIR is unavailable. Attempting self-heal..."

  local fallback=""
  fallback="$(mktemp -d "/tmp/perfomace_tmp.XXXXXX" 2>/dev/null || true)"
  if [ -z "$fallback" ]; then
    mkdir -p /tmp/perfomace_tmp_fallback >/dev/null 2>&1 || true
    fallback="/tmp/perfomace_tmp_fallback"
  fi

  if [ -d "$fallback" ] && [ -w "$fallback" ]; then
    export TMPDIR="$fallback"
    setup_ok "Using fallback temporary directory: $TMPDIR"
    return 0
  fi

  setup_fail "Could not prepare a writable temporary directory. Please restart Terminal or fix /tmp permissions."
  return 1
}

ensure_xcode_developer_dir() {
  local current="${DEVELOPER_DIR:-}"
  if [ -z "$current" ]; then
    current="$(xcode-select -p 2>/dev/null || true)"
  fi

  if [ -n "$current" ] && [ -d "$current" ]; then
    export DEVELOPER_DIR="$current"
    setup_ok "Using Xcode developer directory: $DEVELOPER_DIR"
    return 0
  fi

  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    setup_warn "xcode-select was not ready. Falling back to $DEVELOPER_DIR for this run."
    return 0
  fi

  setup_fail "Xcode developer directory not found. Install Xcode and open it once before running PerfoMace."
  return 1
}

check_swift_toolchain() {
  if ! command -v xcrun >/dev/null 2>&1; then
    setup_fail "xcrun is missing. Install Xcode Command Line Tools."
    return 1
  fi

  if ! xcrun --find swiftc >/dev/null 2>&1; then
    setup_fail "swiftc was not found. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    return 1
  fi

  if xcrun swiftc --version >/dev/null 2>&1; then
    setup_ok "Swift command-line toolchain is healthy."
    return 0
  fi

  setup_fail "Swift CLI health check failed. Try: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept && xcodebuild -runFirstLaunch"
  return 1
}

check_xcodebuild() {
  if ! command -v xcodebuild >/dev/null 2>&1; then
    setup_fail "xcodebuild is missing. Install Xcode and Command Line Tools."
    return 1
  fi

  if xcodebuild -version >/dev/null 2>&1; then
    setup_ok "xcodebuild is available."
    return 0
  fi

  setup_fail "xcodebuild is not ready. Open Xcode once and run xcodebuild -runFirstLaunch."
  return 1
}

prepare_results_dirs() {
  mkdir -p "$RESULTS_ROOT" "$INTERNAL_RESULTS_ROOT"
  setup_ok "Results folders are ready."
}

check_python3() {
  if command -v python3 >/dev/null 2>&1; then
    setup_ok "Python 3 is available."
    return 0
  fi

  setup_fail "python3 is missing. Install Python 3 or Xcode Command Line Tools before running PerfoMace."
  return 1
}

check_ios_targets() {
  local status
  status="$(
    python3 - <<'PY' 2>/dev/null
import json
import subprocess

try:
    result = subprocess.run(
        ["xcrun", "xcdevice", "list"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=20,
    )
    devices = json.loads(result.stdout)
except Exception:
    print("error")
    raise SystemExit(0)

simulators = 0
real_devices = 0
for device in devices:
    if device.get("ignored") or device.get("available") is False:
        continue
    platform = str(device.get("platform") or "")
    if device.get("simulator") and "iphonesimulator" in platform:
        simulators += 1
    elif not device.get("simulator") and "iphoneos" in platform:
        real_devices += 1

print(f"{simulators}:{real_devices}")
PY
  )"

  case "$status" in
    error|"")
      setup_warn "Could not inspect simulator/device availability. PerfoMace will re-check this at run time."
      return 0
      ;;
    *:*)
      local simulators="${status%%:*}"
      local real_devices="${status##*:}"
      if [ "${simulators:-0}" -gt 0 ] || [ "${real_devices:-0}" -gt 0 ]; then
        setup_ok "Found usable iOS targets (simulators: ${simulators:-0}, real devices: ${real_devices:-0})."
        return 0
      fi
      setup_fail "No usable iOS simulator runtime or connected iPhone was found. Install a simulator runtime in Xcode or connect a prepared device."
      return 1
      ;;
  esac
}

echo "🩺 Running PerfoMace setup check..."

if ! command -v xcode-select >/dev/null 2>&1; then
  setup_fail "xcode-select is missing. Install Xcode Command Line Tools with: xcode-select --install"
else
  setup_ok "xcode-select is available."
fi

repair_tmpdir || true
ensure_xcode_developer_dir || true
check_swift_toolchain || true
check_xcodebuild || true
check_python3 || true
check_ios_targets || true
prepare_results_dirs

if [ "$SETUP_FAILED" -ne 0 ]; then
  setup_warn "PerfoMace setup check did not fully pass."
  setup_warn "Fix the issue(s) above, then rerun."
  setup_finish 1
fi

setup_ok "PerfoMace setup check complete. Ready to go."
setup_finish 0
