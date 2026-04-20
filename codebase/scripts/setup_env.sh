#!/bin/bash

PERFOMACE_SETUP_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  PERFOMACE_SETUP_SOURCED=1
fi

SETUP_OUTPUT_MODE="${PERFOMACE_SETUP_FORMAT:-text}"
if [ "$SETUP_OUTPUT_MODE" != "structured" ]; then
  SETUP_OUTPUT_MODE="text"
fi

SETUP_FAILED=0
SETUP_WARNINGS=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_ROOT="$PROJECT_ROOT/results"
INTERNAL_RESULTS_ROOT="$RESULTS_ROOT/.perfo_internal"

declare -a SETUP_CHECK_IDS=()
declare -a SETUP_CHECK_STATUSES=()
declare -a SETUP_CHECK_TITLES=()
declare -a SETUP_CHECK_DETAILS=()
declare -a SETUP_CHECK_ACTIONS=()

setup_finish() {
  local code="${1:-0}"
  if [ "$SETUP_OUTPUT_MODE" = "structured" ]; then
    emit_structured_report
  fi
  if [ "$PERFOMACE_SETUP_SOURCED" -eq 1 ]; then
    return "$code"
  fi
  exit "$code"
}

sanitize_setup_field() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/|/-/g'
}

record_check() {
  local id="$1"
  local status="$2"
  local title="$3"
  local detail="$4"
  local action="${5:-}"

  SETUP_CHECK_IDS+=("$id")
  SETUP_CHECK_STATUSES+=("$status")
  SETUP_CHECK_TITLES+=("$title")
  SETUP_CHECK_DETAILS+=("$detail")
  SETUP_CHECK_ACTIONS+=("$action")

  case "$status" in
    fail)
      SETUP_FAILED=1
      ;;
    warn)
      SETUP_WARNINGS=$((SETUP_WARNINGS + 1))
      ;;
  esac

  if [ "$SETUP_OUTPUT_MODE" != "text" ]; then
    return 0
  fi

  local prefix=""
  case "$status" in
    ok) prefix="✅" ;;
    warn) prefix="⚠️" ;;
    fail) prefix="❌" ;;
    *) prefix="ℹ️" ;;
  esac

  echo "$prefix $title: $detail"
  if [ -n "$action" ]; then
    echo "   Fix: $action"
  fi
}

record_ok() {
  record_check "$1" "ok" "$2" "$3" "$4"
}

record_warn() {
  record_check "$1" "warn" "$2" "$3" "$4"
}

record_fail() {
  record_check "$1" "fail" "$2" "$3" "$4"
}

emit_structured_report() {
  local i
  for i in "${!SETUP_CHECK_IDS[@]}"; do
    printf 'SETUP_CHECK|%s|%s|%s|%s|%s\n' \
      "$(sanitize_setup_field "${SETUP_CHECK_IDS[$i]}")" \
      "$(sanitize_setup_field "${SETUP_CHECK_STATUSES[$i]}")" \
      "$(sanitize_setup_field "${SETUP_CHECK_TITLES[$i]}")" \
      "$(sanitize_setup_field "${SETUP_CHECK_DETAILS[$i]}")" \
      "$(sanitize_setup_field "${SETUP_CHECK_ACTIONS[$i]}")"
  done

  local status="ready"
  local summary_message="PerfoMace setup check complete. Ready to go."
  if [ "$SETUP_FAILED" -ne 0 ]; then
    status="failed"
    summary_message="PerfoMace setup needs attention before you run."
  elif [ "$SETUP_WARNINGS" -ne 0 ]; then
    status="warning"
    summary_message="PerfoMace setup is usable, but there are warnings worth fixing."
  fi

  printf 'SETUP_SUMMARY|%s|%s|%s|%s\n' \
    "$status" \
    "$SETUP_FAILED" \
    "$SETUP_WARNINGS" \
    "$(sanitize_setup_field "$summary_message")"
}

repair_tmpdir() {
  local candidate="${TMPDIR:-}"
  local probe=""

  if [ -n "$candidate" ] && [ -d "$candidate" ] && [ -w "$candidate" ]; then
    probe="$(mktemp "$candidate/perfomace_tmp_check.XXXXXX" 2>/dev/null || true)"
    if [ -n "$probe" ]; then
      rm -f "$probe"
      record_ok \
        "tmpdir" \
        "Temporary Directory" \
        "Temporary directory is healthy: $candidate" \
        ""
      return 0
    fi
  fi

  local fallback=""
  fallback="$(mktemp -d "/tmp/perfomace_tmp.XXXXXX" 2>/dev/null || true)"
  if [ -z "$fallback" ]; then
    mkdir -p /tmp/perfomace_tmp_fallback >/dev/null 2>&1 || true
    fallback="/tmp/perfomace_tmp_fallback"
  fi

  if [ -d "$fallback" ] && [ -w "$fallback" ]; then
    export TMPDIR="$fallback"
    record_warn \
      "tmpdir" \
      "Temporary Directory" \
      "TMPDIR was unavailable, so PerfoMace switched to a writable fallback: $TMPDIR" \
      "If this keeps happening, restart Terminal or repair /tmp permissions so Xcode can use the default temp folder."
    return 0
  fi

  record_fail \
    "tmpdir" \
    "Temporary Directory" \
    "PerfoMace could not prepare a writable temporary directory." \
    "Restart Terminal first. If it still fails, fix /tmp permissions before running PerfoMace again."
  return 1
}

ensure_xcode_select() {
  if command -v xcode-select >/dev/null 2>&1; then
    record_ok \
      "xcode_select" \
      "Xcode Select" \
      "xcode-select is available." \
      ""
    return 0
  fi

  record_fail \
    "xcode_select" \
    "Xcode Select" \
    "xcode-select is missing." \
    "Install Xcode Command Line Tools with: xcode-select --install"
  return 1
}

ensure_xcode_developer_dir() {
  local current="${DEVELOPER_DIR:-}"
  if [ -z "$current" ]; then
    current="$(xcode-select -p 2>/dev/null || true)"
  fi

  if [ -n "$current" ] && [ -d "$current" ]; then
    export DEVELOPER_DIR="$current"
    record_ok \
      "developer_dir" \
      "Xcode Developer Directory" \
      "Using Xcode developer directory: $DEVELOPER_DIR" \
      ""
    return 0
  fi

  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    record_warn \
      "developer_dir" \
      "Xcode Developer Directory" \
      "xcode-select was not ready, so PerfoMace is falling back to $DEVELOPER_DIR for this run." \
      "Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer so future runs use the normal Xcode path."
    return 0
  fi

  record_fail \
    "developer_dir" \
    "Xcode Developer Directory" \
    "Xcode developer directory was not found." \
    "Install Xcode, open it once, and make sure /Applications/Xcode.app exists."
  return 1
}

check_swift_toolchain() {
  if ! command -v xcrun >/dev/null 2>&1; then
    record_fail \
      "swift_toolchain" \
      "Swift Toolchain" \
      "xcrun is missing." \
      "Install Xcode Command Line Tools and open Xcode once."
    return 1
  fi

  if ! xcrun --find swiftc >/dev/null 2>&1; then
    record_fail \
      "swift_toolchain" \
      "Swift Toolchain" \
      "swiftc was not found in the active Xcode toolchain." \
      "Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    return 1
  fi

  if xcrun swiftc --version >/dev/null 2>&1; then
    record_ok \
      "swift_toolchain" \
      "Swift Toolchain" \
      "Swift command-line toolchain is healthy." \
      ""
    return 0
  fi

  record_fail \
    "swift_toolchain" \
    "Swift Toolchain" \
    "Swift CLI health check failed." \
    "Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept && xcodebuild -runFirstLaunch"
  return 1
}

check_xcodebuild() {
  if ! command -v xcodebuild >/dev/null 2>&1; then
    record_fail \
      "xcodebuild" \
      "xcodebuild" \
      "xcodebuild is missing." \
      "Install Xcode and the Command Line Tools, then open Xcode once."
    return 1
  fi

  if xcodebuild -version >/dev/null 2>&1; then
    record_ok \
      "xcodebuild" \
      "xcodebuild" \
      "xcodebuild is available." \
      ""
    return 0
  fi

  record_fail \
    "xcodebuild" \
    "xcodebuild" \
    "xcodebuild is not ready yet." \
    "Open Xcode once, accept any prompts, then run: xcodebuild -runFirstLaunch"
  return 1
}

check_python3() {
  if command -v python3 >/dev/null 2>&1; then
    record_ok \
      "python3" \
      "Python 3" \
      "Python 3 is available." \
      ""
    return 0
  fi

  record_fail \
    "python3" \
    "Python 3" \
    "python3 is missing." \
    "Install Python 3 or the Xcode Command Line Tools before running PerfoMace."
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
      record_warn \
        "ios_targets" \
        "iOS Targets" \
        "PerfoMace could not inspect simulator or device availability right now." \
        "Open Xcode and Window > Devices and Simulators, then rerun the ready check if you plan to test on a phone."
      return 0
      ;;
    *:*)
      local simulators="${status%%:*}"
      local real_devices="${status##*:}"
      if [ "${simulators:-0}" -gt 0 ] || [ "${real_devices:-0}" -gt 0 ]; then
        record_ok \
          "ios_targets" \
          "iOS Targets" \
          "Found usable iOS targets (simulators: ${simulators:-0}, real devices: ${real_devices:-0})." \
          ""
        return 0
      fi
      record_fail \
        "ios_targets" \
        "iOS Targets" \
        "No usable iOS simulator runtime or connected iPhone was found." \
        "Install an iOS simulator runtime in Xcode, or connect and prepare an iPhone for development."
      return 1
      ;;
  esac
}

check_codesigning_identity() {
  local identity_count
  identity_count="$(
    security find-identity -v -p codesigning 2>/dev/null | \
      grep -E 'Apple Development|iPhone Developer' | \
      wc -l | tr -d ' '
  )"

  if [ -n "$identity_count" ] && [ "$identity_count" -gt 0 ] 2>/dev/null; then
    record_ok \
      "codesigning" \
      "Apple Development Signing" \
      "Found at least one Apple Development signing identity." \
      ""
    return 0
  fi

  record_warn \
    "codesigning" \
    "Apple Development Signing" \
    "No Apple Development signing identity was found." \
    "Simulator runs can still work, but real-device runs need Xcode > Settings > Accounts and a valid Apple Development team."
  return 0
}

prepare_results_dirs() {
  mkdir -p "$RESULTS_ROOT" "$INTERNAL_RESULTS_ROOT"
  record_ok \
    "results_dirs" \
    "Results Folders" \
    "Results folders are ready." \
    ""
}

if [ "$SETUP_OUTPUT_MODE" = "text" ]; then
  echo "🩺 Running PerfoMace setup check..."
fi

ensure_xcode_select || true
repair_tmpdir || true
ensure_xcode_developer_dir || true
check_swift_toolchain || true
check_xcodebuild || true
check_python3 || true
check_ios_targets || true
check_codesigning_identity || true
prepare_results_dirs

if [ "$SETUP_OUTPUT_MODE" = "text" ]; then
  if [ "$SETUP_FAILED" -ne 0 ]; then
    echo "⚠️ PerfoMace setup check did not fully pass."
    echo "⚠️ Fix the issue(s) above, then rerun."
    setup_finish 1
  fi

  if [ "$SETUP_WARNINGS" -ne 0 ]; then
    echo "⚠️ PerfoMace setup check passed with warnings."
  fi
  echo "✅ PerfoMace setup check complete. Ready to go."
  setup_finish 0
fi

if [ "$SETUP_FAILED" -ne 0 ]; then
  setup_finish 1
fi

setup_finish 0
