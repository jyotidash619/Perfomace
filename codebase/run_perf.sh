#!/bin/bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="$PROJECT_ROOT/results"
RUN_SESSION_STAMP="$(date '+%Y-%m-%dT%H-%M-%S')"
RUN_APP_PREFIX="${PERF_APP:-run}"
RUN_APP_PREFIX_LOWER="$(printf '%s' "$RUN_APP_PREFIX" | tr '[:upper:]' '[:lower:]')"
case "$RUN_APP_PREFIX_LOWER" in
  qa) RUN_APP_PREFIX="QA" ;;
  legacy) RUN_APP_PREFIX="Legacy" ;;
  custom) RUN_APP_PREFIX="Custom" ;;
  *) RUN_APP_PREFIX="$(printf '%s' "$RUN_APP_PREFIX" | tr '[:lower:]' '[:upper:]')" ;;
esac
RUN_SESSION_NAME="${RUN_APP_PREFIX}_PerfoMace_${RUN_SESSION_STAMP}"
RUN_SESSION_DIR="$RESULTS_ROOT/$RUN_SESSION_NAME"
RESULTS_DIR="$RUN_SESSION_DIR"
INTERNAL_RESULTS_DIR="$RESULTS_ROOT/.perfo_internal"
cd "$SCRIPT_DIR"
LOG_PATH="$RESULTS_DIR/perf.log"
mkdir -p "$RESULTS_ROOT"
mkdir -p "$RESULTS_DIR"
mkdir -p "$INTERNAL_RESULTS_DIR"
: > "$LOG_PATH"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SCRIPT_REVISION="phase-probe-2026-03-24-r2"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "❌ Python 3 is required to run PerfoMace."
  echo "   Needed for config resolution and HTML/JSON/CSV/TXT report generation."
  echo "   Install Python 3 or Xcode Command Line Tools, then rerun."
  exit 127
fi

emit_phase() {
  local phase="$1"
  echo "PERF_PHASE phase=$phase" | tee -a "$LOG_PATH"
}

emit_output_dir() {
  echo "PERF_OUTPUT_DIR path=$RUN_SESSION_DIR" | tee -a "$LOG_PATH"
}

emit_output_dir

write_run_context() {
  local path="$1"
  "$PYTHON_BIN" - "$path" "$PERF_APP" "$PERF_APP_BUNDLE_ID" "$INSTRUMENTS_PROCESS_NAME" "$SCRIPT_REVISION" "${DESTINATION:-}" "${REAL_DEVICE_ID:-}" "${SIM_UDID:-}" <<'PY'
import json
import subprocess
import sys

path, tested_app, bundle_id, process_name, script_revision, destination, real_device_id, simulator_udid = sys.argv[1:9]


def _os_version(raw):
    value = (raw or "").strip()
    if not value:
        return ""
    return value.split(" (", 1)[0].strip()


def _target_identifier(destination, real_device_id, simulator_udid):
    destination = (destination or "").strip()
    real_device_id = (real_device_id or "").strip()
    simulator_udid = (simulator_udid or "").strip()

    if real_device_id and real_device_id in destination:
        return real_device_id
    if simulator_udid and simulator_udid in destination:
        return simulator_udid
    if "platform=iOS Simulator" in destination and simulator_udid:
        return simulator_udid
    if "platform=iOS" in destination and real_device_id:
        return real_device_id
    return real_device_id or simulator_udid


def _resolve_device_metadata(destination, real_device_id, simulator_udid):
    target_id = _target_identifier(destination, real_device_id, simulator_udid)
    if not target_id:
        return {}

    try:
        result = subprocess.run(
            ["xcrun", "xcdevice", "list"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )
        devices = json.loads(result.stdout)
    except Exception:
        return {}

    for device in devices:
        if str(device.get("identifier") or "").strip() != target_id:
            continue
        model_name = str(device.get("modelName") or "").strip()
        is_simulator = bool(device.get("simulator"))
        os_version = _os_version(device.get("operatingSystemVersion"))
        display_name = model_name or str(device.get("name") or "").strip()
        if is_simulator and display_name and "simulator" not in display_name.lower():
            display_name = f"{display_name} Simulator"
        if display_name and os_version:
            display_name = f"{display_name} • iOS {os_version}"
        return {
            "device_name": str(device.get("name") or "").strip(),
            "device_model": model_name,
            "device_model_code": str(device.get("modelCode") or "").strip(),
            "device_os_version": os_version,
            "device_os_build": str(device.get("operatingSystemVersion") or "").strip(),
            "device_kind": "simulator" if is_simulator else "real_device",
            "device_display_name": display_name,
        }
    return {}


device_metadata = _resolve_device_metadata(destination, real_device_id, simulator_udid)
with open(path, "w", encoding="utf-8") as f:
    json.dump(
        {
            "tested_app": tested_app,
            "bundle_id": bundle_id,
            "process_name": process_name,
            "script_revision": script_revision,
            "destination": destination,
            "real_device_id": real_device_id,
            "simulator_udid": simulator_udid,
            **device_metadata,
        },
        f,
        indent=2,
    )
PY
}

run_with_timeout() {
  local timeout_secs="$1"
  shift
  "$PYTHON_BIN" - "$timeout_secs" "$@" <<'PY'
import subprocess
import sys
import os
import signal

timeout = float(sys.argv[1])
cmd = sys.argv[2:]

proc = subprocess.Popen(cmd, start_new_session=True)
try:
    sys.exit(proc.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
    sys.exit(124)
PY
}

TEST_ITERATIONS="${TEST_ITERATIONS:-1}"
if ! [[ "$TEST_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$TEST_ITERATIONS" -lt 1 ]; then
  TEST_ITERATIONS=1
fi

# --- CONFIGURATION ---
SIMULATOR_NAME="${SIMULATOR_NAME:-}"
CONFIG_PATH="${PERFOMACE_CONFIG:-$SCRIPT_DIR/perfomace.config.json}"
# ---------------------

echo "🔍 Scanning for connected devices..."
emit_output_dir

# ---- APP SELECTION (QA vs Legacy, etc.) ----
# Precedence:
# 1) PERF_APP_BUNDLE_ID (explicit)
# 2) PERF_APP (key like "qa" / "legacy" / "custom")
# 3) perfomace.config.json (default_app + apps map)
# 4) interactive prompt (if running in a TTY)
resolve_app_from_config() {
  local key="$1"
  local field="$2"
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  "$PYTHON_BIN" - "$CONFIG_PATH" "$key" "$field" <<'PY'
import json, sys
path, key, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
apps = cfg.get("apps", {}) or {}
app = apps.get(key) or {}
val = app.get(field)
if val is None:
    sys.exit(2)
print(val)
PY
}

resolve_default_app_key() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  "$PYTHON_BIN" - "$CONFIG_PATH" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
print(cfg.get("default_app") or "")
PY
}

list_app_keys() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  "$PYTHON_BIN" - "$CONFIG_PATH" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
apps = cfg.get("apps", {}) or {}
for k in apps.keys():
    print(k)
PY
}

choose_app_interactively() {
  if [ ! -t 0 ]; then
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  local keys
  keys="$(list_app_keys || true)"
  if [ -z "$keys" ]; then
    return 1
  fi
  echo "🧭 Select app under test:"
  local options=()
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    local name
    name="$(resolve_app_from_config "$k" "name" 2>/dev/null || echo "$k")"
    local bid
    bid="$(resolve_app_from_config "$k" "bundle_id" 2>/dev/null || echo "")"
    options+=("$k — $name ($bid)")
  done <<< "$keys"

  local PS3="Enter choice: "
  select opt in "${options[@]}"; do
    if [ -n "${opt:-}" ]; then
      echo "$opt" | awk '{print $1}'
      return 0
    fi
    echo "Invalid selection."
  done
}

show_xcodebuild_destinations() {
  xcodebuild -showdestinations -project "$PROJECT_ROOT/PerfoMace.xcodeproj" -scheme PerfoMace 2>/dev/null
}

pick_available_simulator_id() {
  local name_filter="${1:-}"
  "$PYTHON_BIN" - "$name_filter" <<'PY'
import json
import subprocess
import sys

name_filter = sys.argv[1].strip().lower()
proc = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "--json"],
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    sys.exit(proc.returncode)

data = json.loads(proc.stdout)
matches = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        udid = device.get("udid", "")
        if not udid:
            continue
        if name_filter and name_filter not in name.lower():
            continue
        matches.append((name, udid))

if not matches:
    sys.exit(1)

print(matches[0][1])
PY
}

pick_destination_id() {
  local mode="$1"
  local name_filter="${2:-}"
  local destinations
  destinations="$(show_xcodebuild_destinations)"
  if [ -z "$destinations" ]; then
    return 1
  fi
  case "$mode" in
    device)
      DESTINATIONS_TEXT="$destinations" "$PYTHON_BIN" - "$name_filter" <<'PY' || return 1
import os
import re
import sys

name_filter = (sys.argv[1] or "").strip().lower()
text = os.environ.get("DESTINATIONS_TEXT", "")

for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line.startswith("{ platform:iOS,"):
        continue
    if "Simulator" in line or "placeholder" in line or "error:" in line:
        continue

    id_match = re.search(r"id:([^,}]+)", line)
    name_match = re.search(r"name:([^,}]+)", line)
    if not id_match:
        continue

    name = name_match.group(1).strip() if name_match else ""
    if name_filter and name_filter not in name.lower():
        continue

    print(id_match.group(1).strip())
    sys.exit(0)

sys.exit(1)
PY
      ;;
    simulator)
      if [ -n "$name_filter" ]; then
        printf '%s\n' "$destinations" | grep -m1 "{ platform:iOS Simulator," | grep "name:${name_filter}" | sed -E 's/.*id:([^,}]+).*/\1/' || return 1
      else
        printf '%s\n' "$destinations" | grep -m1 "{ platform:iOS Simulator," | sed -E 's/.*id:([^,}]+).*/\1/' || return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# Determine PERF_APP and bundle/process from env/config/prompt
if [ -n "${PERF_APP_BUNDLE_ID:-}" ] && [ -z "${PERF_APP:-}" ]; then
  PERF_APP="custom"
fi

PERF_APP="${PERF_APP:-}"
if [ -z "$PERF_APP" ]; then
  PERF_APP="$(resolve_default_app_key 2>/dev/null || true)"
fi
if [ -z "$PERF_APP" ]; then
  PERF_APP="$(choose_app_interactively 2>/dev/null || true)"
fi
PERF_APP="${PERF_APP:-qa}"

if [ "$PERF_APP" = "custom" ]; then
  : "${PERF_APP_BUNDLE_ID:?PERF_APP=custom requires PERF_APP_BUNDLE_ID}"
else
  PERF_APP_BUNDLE_ID="$(resolve_app_from_config "$PERF_APP" "bundle_id" 2>/dev/null || true)"
  if [ -z "$PERF_APP_BUNDLE_ID" ]; then
    echo "❌ Unknown PERF_APP '$PERF_APP'."
    echo "   Set PERF_APP_BUNDLE_ID directly, or update $CONFIG_PATH"
    exit 2
  fi
  INSTRUMENTS_PROCESS_NAME="${INSTRUMENTS_PROCESS_NAME:-$(resolve_app_from_config "$PERF_APP" "instruments_process_name" 2>/dev/null || true)}"
fi

# 2. AUTO-DETECT REAL DEVICE (can override via DEVICE_ID or DESTINATION_OVERRIDE)
# Logic: List devices -> Find "iPhone" -> Remove "Simulator" -> Grab the ID
# This prevents it from accidentally picking up your Mac or Apple Watch.
if [ -n "${DESTINATION_OVERRIDE:-}" ]; then
  DESTINATION="$DESTINATION_OVERRIDE"
  if [[ "$DESTINATION_OVERRIDE" =~ id=([^,]+) ]]; then
    REAL_DEVICE_ID="${BASH_REMATCH[1]}"
  else
    REAL_DEVICE_ID=""
  fi
  SIM_UDID=""
else
  if [ -n "${DEVICE_ID:-}" ]; then
    REAL_DEVICE_ID="$DEVICE_ID"
  else
    REAL_DEVICE_ID="$(pick_destination_id device 2>/dev/null || true)"
  fi
fi

SIM_AVAILABLE=0
SIM_UDID=""
if [ -n "${DESTINATION_OVERRIDE:-}" ]; then
    echo "✅ Using destination override: $DESTINATION_OVERRIDE"
elif [ -n "$REAL_DEVICE_ID" ]; then
    echo "✅ Found Real Device connected! (ID: $REAL_DEVICE_ID)"
    DESTINATION="platform=iOS,id=$REAL_DEVICE_ID"
    SIM_UDID="$REAL_DEVICE_ID"
else
    SIM_AVAILABLE=1
    if [ -n "$SIMULATOR_NAME" ]; then
      echo "⚠️ No USB device found. Resolving available Simulator '$SIMULATOR_NAME'..."
      SIM_UDID="$(pick_available_simulator_id "$SIMULATOR_NAME" 2>/dev/null || true)"
    else
      echo "⚠️ No USB device found. Resolving first available Simulator..."
      SIM_UDID="$(pick_available_simulator_id "" 2>/dev/null || true)"
    fi
    if [ -z "$SIM_UDID" ]; then
      echo "❌ No available simulator destination could be resolved."
      echo "Available destinations:"
      show_xcodebuild_destinations
      exit 2
    fi
    if [ -n "$SIMULATOR_NAME" ]; then
      echo "✅ Using Simulator '$SIMULATOR_NAME' (UDID: $SIM_UDID)"
    else
      echo "✅ Using first available Simulator (UDID: $SIM_UDID)"
    fi
    DESTINATION="platform=iOS Simulator,id=$SIM_UDID"
fi

# Optional: reset simulator content before run
if [ "${RESET_SIM:-0}" -eq 1 ] && [[ "$DESTINATION" == platform=iOS\ Simulator* ]]; then
  if [ -n "$SIM_UDID" ]; then
    echo "🧹 Resetting simulator ($SIM_UDID)..."
    xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
    xcrun simctl erase "$SIM_UDID" >/dev/null 2>&1 || true
  else
    echo "⚠️ Could not resolve simulator UDID for reset."
  fi
fi

echo "🚀 Starting Performance Tests on: $DESTINATION"

STRICT_LOGGED_OUT_PREFLIGHT="${STRICT_LOGGED_OUT_PREFLIGHT:-1}"

# Optional test configuration (consumed by UI tests / Instruments)
# - PERF_APP_BUNDLE_ID: XCUIApplication bundle id under test
# - PERF_EMAIL / PERF_PASSWORD: login credentials
# - PERF_AD_BEHAVIOR: "bypass" (default) or "fail"
export PERF_APP_BUNDLE_ID="${PERF_APP_BUNDLE_ID}"
export PERF_EMAIL="${PERF_EMAIL:-testjp100@test.com}"
export PERF_PASSWORD="${PERF_PASSWORD:-Test1234}"
export PERF_AD_BEHAVIOR="${PERF_AD_BEHAVIOR:-bypass}"
if [ -z "${INSTRUMENTS_PROCESS_NAME:-}" ]; then
  case "${PERF_APP:-qa}" in
    legacy)
      INSTRUMENTS_PROCESS_NAME="iHeartRadio"
      ;;
    *)
      INSTRUMENTS_PROCESS_NAME="iHeart"
      ;;
  esac
fi
export INSTRUMENTS_PROCESS_NAME
export INSTRUMENTS="${INSTRUMENTS:-1}"
export INSTRUMENTS_NETWORK="${INSTRUMENTS_NETWORK:-1}"
export INSTRUMENTS_LEAKS="${INSTRUMENTS_LEAKS:-1}"
export INSTRUMENTS_TIME_PROFILER="${INSTRUMENTS_TIME_PROFILER:-1}"
export INSTRUMENTS_ALLOCATIONS="${INSTRUMENTS_ALLOCATIONS:-1}"
export PERF_REPEAT_COUNT="${TEST_ITERATIONS}"
export AUTO_OPEN_RESULTS="${AUTO_OPEN_RESULTS:-1}"
export AUTO_OPEN_TRACES="${AUTO_OPEN_TRACES:-1}"
export AUTO_OPEN_RESULTS_FOLDER="${AUTO_OPEN_RESULTS_FOLDER:-1}"
export AUTO_PACKAGE_RESULTS="${AUTO_PACKAGE_RESULTS:-1}"
RUN_CONTEXT_PATH="$RESULTS_DIR/run_context.json"
write_run_context "$RUN_CONTEXT_PATH"
cp "$SCRIPT_DIR/run_perf.sh" "$RESULTS_DIR/run_perf.snapshot.sh" >/dev/null 2>&1 || true
echo "ℹ️  Runner revision: $SCRIPT_REVISION" | tee -a "$LOG_PATH"
echo "ℹ️  Using PERF_APP=${PERF_APP:-} PERF_APP_BUNDLE_ID=${PERF_APP_BUNDLE_ID}" | tee -a "$LOG_PATH"

# Ensure XCTest gets the env (xcodebuild doesn't always pass shell env to tests)
SCHEME_FILE="$PROJECT_ROOT/PerfoMace.xcodeproj/xcshareddata/xcschemes/PerfoMace.xcscheme"
"$PYTHON_BIN" - "$SCHEME_FILE" "$PERF_APP" "$PERF_APP_BUNDLE_ID" "$PERF_EMAIL" "$PERF_PASSWORD" "$PERF_AD_BEHAVIOR" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, app_key, bundle_id, email, password, ad_behavior = sys.argv[1:7]
tree = ET.parse(path)
root = tree.getroot()

def set_env(test_action):
    envs = test_action.find("EnvironmentVariables")
    if envs is None:
        envs = ET.SubElement(test_action, "EnvironmentVariables")
    desired = {
        "PERF_APP": app_key,
        "PERF_APP_BUNDLE_ID": bundle_id,
        "PERF_EMAIL": email,
        "PERF_PASSWORD": password,
        "PERF_AD_BEHAVIOR": ad_behavior,
    }
    existing = {e.get("key"): e for e in envs.findall("EnvironmentVariable")}
    for key, val in desired.items():
        if key in existing:
            existing[key].set("value", val or "")
            existing[key].set("isEnabled", "YES")
        else:
            ET.SubElement(envs, "EnvironmentVariable", key=key, value=val or "", isEnabled="YES")

test_action = root.find("TestAction")
if test_action is not None:
    set_env(test_action)

tree.write(path, encoding="UTF-8", xml_declaration=True)
PY

# 3. CLEAN UP
rm -rf "$RESULTS_DIR/Performance.xcresult"
rm -rf "$RESULTS_DIR/iterations"
rm -rf "$RESULTS_DIR/instruments_probe"
rm -rf "$RESULTS_DIR/traces"
rm -f "$RESULTS_DIR/PerformanceReport.html" "$RESULTS_DIR/PerformanceReport.json" "$RESULTS_DIR/PerformanceReport.txt" "$RESULTS_DIR/PerformanceReport.csv"
mkdir -p "$RESULTS_DIR/iterations"

DERIVED_DATA_DIR="$INTERNAL_RESULTS_DIR/DerivedData"
BUILD_CONTEXT_FILE="$DERIVED_DATA_DIR/.perf_build_context"
REUSE_EXISTING_BUILD="${REUSE_EXISTING_BUILD:-1}"
CLEAN_DERIVED_DATA="${CLEAN_DERIVED_DATA:-0}"

if [ "$CLEAN_DERIVED_DATA" -eq 1 ]; then
  rm -rf "$DERIVED_DATA_DIR"
fi

# 4. RUN TESTS
# We use -allowProvisioningUpdates so Xcode can handle the 'Trust' certificate automatically
TIMEOUT_SECS="${TIMEOUT_SECS:-900}"
XCODEBUILD_HELP="$(xcodebuild -help 2>/dev/null)"

# Verify destination is actually available to xcodebuild
if [ -n "$REAL_DEVICE_ID" ]; then
  device_visible=0
  for _attempt in 1 2 3 4 5 6; do
    if xcodebuild -showdestinations -project "$PROJECT_ROOT/PerfoMace.xcodeproj" -scheme PerfoMace 2>&1 | grep -q "$REAL_DEVICE_ID"; then
      device_visible=1
      break
    fi
    sleep 2
  done
  if [ "$device_visible" -ne 1 ]; then
    if [ -n "${DEVICE_ID:-}" ]; then
      echo "⚠️ Device $REAL_DEVICE_ID was not consistently visible during preflight." | tee -a "$LOG_PATH"
      echo "   Continuing because DEVICE_ID was explicitly provided." | tee -a "$LOG_PATH"
    else
      echo "❌ Device $REAL_DEVICE_ID is not visible to xcodebuild."
      echo "   Make sure the iPhone is unlocked, trusted, and Developer Mode is enabled."
      echo "   In Xcode: Window → Devices and Simulators → select device → wait for 'Preparing'."
      exit 2
    fi
  fi
fi

COMMON_XCODEBUILD_ARGS=(
  -project "$PROJECT_ROOT/PerfoMace.xcodeproj"
  -scheme PerfoMace
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_DIR"
  -allowProvisioningUpdates
)

# Ensure a compile-time default when runtime env isn't visible on device
if [ "${PERF_APP:-}" = "legacy" ]; then
  COMMON_XCODEBUILD_ARGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) PERF_APP_LEGACY")
elif [ "${PERF_APP:-}" = "qa" ]; then
  COMMON_XCODEBUILD_ARGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) PERF_APP_QA")
fi

# Inject env into generated Info.plist for test bundles (fallback if scheme env is not propagated)
COMMON_XCODEBUILD_ARGS+=(
  "INFOPLIST_KEY_PERF_APP_BUNDLE_ID=${PERF_APP_BUNDLE_ID}"
  "INFOPLIST_KEY_PERF_APP=${PERF_APP}"
  "INFOPLIST_KEY_PERF_EMAIL=${PERF_EMAIL}"
  "INFOPLIST_KEY_PERF_PASSWORD=${PERF_PASSWORD}"
  "INFOPLIST_KEY_PERF_AD_BEHAVIOR=${PERF_AD_BEHAVIOR}"
  "INFOPLIST_KEY_PERF_REPEAT_COUNT=${TEST_ITERATIONS}"
)

scenario_selected() {
  local key="$1"
  if [ -z "${PERF_SCENARIOS:-}" ]; then
    return 0
  fi
  case ",${PERF_SCENARIOS}," in
    *,"$key",*) return 0 ;;
    *) return 1 ;;
  esac
}

selected_requires_preflight() {
  for key in login tab_switch_journey search image_loading radio_play_start podcast_play_start playlist_play_start radio_scroll logout; do
    if scenario_selected "$key"; then
      return 0
    fi
  done
  return 1
}

# Run only the curated perf tests explicitly, filtered by the selected scenario set.
LAUNCH_TEST_ARGS=()
scenario_selected cold_launch && LAUNCH_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartLaunchPerfTests/testColdLaunchTime)
scenario_selected warm_resume && LAUNCH_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartLaunchPerfTests/testWarmResumeTime)

ACCOUNT_TEST_ARGS=()
scenario_selected login && ACCOUNT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testLoginSpeed)

PREP_TEST_ARGS=()
if selected_requires_preflight; then
  PREP_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testPrepareFreshLoggedOutState)
fi

CONTENT_TEST_ARGS=()
scenario_selected tab_switch_journey && CONTENT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testTabSwitchJourney)
scenario_selected search && CONTENT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testSearchSpeed)
scenario_selected image_loading && CONTENT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testImageLoading)
scenario_selected radio_play_start && CONTENT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testRadioPlayStart)
scenario_selected podcast_play_start && CONTENT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testPodcastTabLoad)
scenario_selected playlist_play_start && CONTENT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testPlaylistLoad)
scenario_selected radio_scroll && CONTENT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testRadioScrollPerformance)

LOGOUT_TEST_ARGS=()
scenario_selected logout && LOGOUT_TEST_ARGS+=(-only-testing:PerfoMaceUITests/iHeartPerfTests/testLogoutSpeed)

INSTRUMENTS_PROBE_TEST_ARGS=(
  -only-testing:PerfoMaceUITests/iHeartPerfTests/testInstrumentsProbeJourney
)

# Combined execution order:
# preflight fresh-state -> cold launch -> warm resume/background -> login -> navigation/content flows -> logout
ONLY_TEST_ARGS=(
  "${PREP_TEST_ARGS[@]}"
  "${LAUNCH_TEST_ARGS[@]}"
  "${ACCOUNT_TEST_ARGS[@]}"
  "${CONTENT_TEST_ARGS[@]}"
  "${LOGOUT_TEST_ARGS[@]}"
)

if [ "${#ONLY_TEST_ARGS[@]}" -eq 0 ]; then
  echo "❌ No scenarios were selected for this run." | tee -a "$LOG_PATH"
  exit 2
fi

FULL_SCENARIO_SELECTION=1
for scenario_key in \
  cold_launch \
  warm_resume \
  login \
  tab_switch_journey \
  search \
  image_loading \
  radio_play_start \
  podcast_play_start \
  playlist_play_start \
  radio_scroll \
  logout; do
  if ! scenario_selected "$scenario_key"; then
    FULL_SCENARIO_SELECTION=0
    break
  fi
done

if [ "$FULL_SCENARIO_SELECTION" -ne 1 ]; then
  echo "ℹ️ Custom scenario subset selected; Instruments traces will be skipped for this run." | tee -a "$LOG_PATH"
  INSTRUMENTS=0
fi

BUILD_TEST_ARGS=(
  "${ONLY_TEST_ARGS[@]}"
  "${INSTRUMENTS_PROBE_TEST_ARGS[@]}"
)

# Add timeout flags only if supported by this Xcode
if echo "$XCODEBUILD_HELP" | grep -q "test-timeouts-enabled"; then
  COMMON_XCODEBUILD_ARGS+=(
    -test-timeouts-enabled YES
    -default-test-execution-time-allowance 300
    -maximum-test-execution-time-allowance 600
  )
fi

build_for_testing_once() {
  local build_flavor="device"
  if [[ "$DESTINATION" == platform=iOS\ Simulator* ]]; then
    build_flavor="simulator"
  fi
  local expected_context="PERF_APP=${PERF_APP};BUNDLE_ID=${PERF_APP_BUNDLE_ID};DESTINATION_KIND=${build_flavor}"
  local runner_app=""
  local app_bundle=""
  local xctestrun_file=""
  case "$build_flavor" in
    device)
      runner_app="$DERIVED_DATA_DIR/Build/Products/Debug-iphoneos/PerfoMaceUITests-Runner.app"
      app_bundle="$DERIVED_DATA_DIR/Build/Products/Debug-iphoneos/PerfoMace.app"
      xctestrun_file="$(find "$DERIVED_DATA_DIR/Build/Products" -maxdepth 1 -name '*.xctestrun' 2>/dev/null | head -n 1)"
      ;;
    simulator)
      runner_app="$DERIVED_DATA_DIR/Build/Products/Debug-iphonesimulator/PerfoMaceUITests-Runner.app"
      app_bundle="$DERIVED_DATA_DIR/Build/Products/Debug-iphonesimulator/PerfoMace.app"
      xctestrun_file="$(find "$DERIVED_DATA_DIR/Build/Products" -maxdepth 1 -name '*.xctestrun' 2>/dev/null | head -n 1)"
      ;;
  esac

  if [ "$REUSE_EXISTING_BUILD" -eq 1 ] &&
     [ -f "$BUILD_CONTEXT_FILE" ] &&
     grep -Fxq "$expected_context" "$BUILD_CONTEXT_FILE" &&
     [ -d "$runner_app" ] &&
     [ -d "$app_bundle" ] &&
     [ -n "$xctestrun_file" ]; then
    echo "♻️ Reusing existing build products for $PERF_APP ($build_flavor)." | tee -a "$LOG_PATH"
    emit_phase "Preparing Build"
    return 0
  fi

  local build_args=(
    build-for-testing
    "${COMMON_XCODEBUILD_ARGS[@]}"
    "${BUILD_TEST_ARGS[@]}"
  )

  echo "🏗️ Preparing build products once before test iterations..." | tee -a "$LOG_PATH"
  emit_phase "Preparing Build"

  if [ "$TIMEOUT_SECS" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECS" xcodebuild "${build_args[@]}" 2>&1 | tee -a "$LOG_PATH"
    local build_status=${PIPESTATUS[0]}
    if [ "$build_status" -eq 0 ]; then
      mkdir -p "$DERIVED_DATA_DIR"
      printf '%s\n' "$expected_context" > "$BUILD_CONTEXT_FILE"
    fi
    return "$build_status"
  elif [ "$TIMEOUT_SECS" -gt 0 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT_SECS" xcodebuild "${build_args[@]}" 2>&1 | tee -a "$LOG_PATH"
    local build_status=${PIPESTATUS[0]}
    if [ "$build_status" -eq 0 ]; then
      mkdir -p "$DERIVED_DATA_DIR"
      printf '%s\n' "$expected_context" > "$BUILD_CONTEXT_FILE"
    fi
    return "$build_status"
  else
    xcodebuild "${build_args[@]}" 2>&1 | tee -a "$LOG_PATH"
    local build_status=${PIPESTATUS[0]}
    if [ "$build_status" -eq 0 ]; then
      mkdir -p "$DERIVED_DATA_DIR"
      printf '%s\n' "$expected_context" > "$BUILD_CONTEXT_FILE"
    fi
    return "$build_status"
  fi
}

run_xcodebuild_phase() {
  local iteration="$1"
  local total_iterations="$2"
  local phase_key="$3"
  local phase_label="$4"
  shift 4
  local result_bundle="$RESULTS_DIR/iterations/iteration_${iteration}_${phase_key}.xcresult"
  local phase_timeout="$TIMEOUT_SECS"

  case "$phase_key" in
    preflight)
      phase_timeout="${PREFLIGHT_TIMEOUT_SECS:-180}"
      ;;
    content)
      phase_timeout="${CONTENT_TIMEOUT_SECS:-$TIMEOUT_SECS}"
      ;;
    final_logout)
      phase_timeout="${FINAL_LOGOUT_TIMEOUT_SECS:-120}"
      ;;
  esac

  rm -rf "$result_bundle"
  emit_phase "$phase_label"

  export PERF_CURRENT_ITERATION="${iteration}"
  export PERF_REPEAT_COUNT="${total_iterations}"

  local run_args=(
    test-without-building
    "${COMMON_XCODEBUILD_ARGS[@]}"
    -resultBundlePath "$result_bundle"
    "$@"
  )

  if [ "$phase_timeout" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$phase_timeout" xcodebuild "${run_args[@]}" 2>&1 | tee -a "$LOG_PATH"
    return ${PIPESTATUS[0]}
  elif [ "$phase_timeout" -gt 0 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$phase_timeout" xcodebuild "${run_args[@]}" 2>&1 | tee -a "$LOG_PATH"
    return ${PIPESTATUS[0]}
  else
    xcodebuild "${run_args[@]}" 2>&1 | tee -a "$LOG_PATH"
    return ${PIPESTATUS[0]}
  fi
}

merge_iteration_results() {
  local iteration="$1"
  local merged_result="$RESULTS_DIR/iterations/iteration_${iteration}.xcresult"
  local phase_results=()
  local phase_result=""

  rm -rf "$merged_result"

  for phase_result in \
    "$RESULTS_DIR/iterations/iteration_${iteration}_launch.xcresult" \
    "$RESULTS_DIR/iterations/iteration_${iteration}_login.xcresult" \
    "$RESULTS_DIR/iterations/iteration_${iteration}_content.xcresult"; do
    [ -d "$phase_result" ] || continue
    phase_results+=("$phase_result")
  done

  if [ "${#phase_results[@]}" -eq 0 ]; then
    return 1
  fi

  if [ "${#phase_results[@]}" -eq 1 ]; then
    cp -R "${phase_results[0]}" "$merged_result"
    return 0
  fi

  if xcrun xcresulttool merge --output-path "$merged_result" "${phase_results[@]}" >/dev/null 2>&1; then
    return 0
  fi

  echo "⚠️ xcresult merge failed for iteration ${iteration}; falling back to last phase result." | tee -a "$LOG_PATH"
  cp -R "${phase_results[$((${#phase_results[@]} - 1))]}" "$merged_result"
  return 1
}

run_xcodebuild_iteration() {
  local iteration="$1"
  local total_iterations="$2"
  local login_phase_succeeded=0
  local iteration_exit=0

  echo "" | tee -a "$LOG_PATH"
  echo "🔁 Iteration ${iteration}/${total_iterations}" | tee -a "$LOG_PATH"
  echo "PERF_ITERATION iteration=${iteration} total=${total_iterations}" | tee -a "$LOG_PATH"

  if [ "${STRICT_LOGGED_OUT_PREFLIGHT:-1}" -eq 1 ]; then
    if ! run_xcodebuild_phase "$iteration" "$total_iterations" "preflight" "Preparing Fresh Logged-Out State" "${PREP_TEST_ARGS[@]}"; then
      iteration_exit=1
      echo "⚠️ Preflight state preparation failed for iteration ${iteration}/${total_iterations}. Skipping measured phases." | tee -a "$LOG_PATH"
      return "$iteration_exit"
    fi
  fi

  if ! run_xcodebuild_phase "$iteration" "$total_iterations" "launch" "Running Launch Tests" "${LAUNCH_TEST_ARGS[@]}"; then
    iteration_exit=1
    echo "⚠️ Launch phase failed for iteration ${iteration}/${total_iterations}." | tee -a "$LOG_PATH"
  fi

  if ! run_xcodebuild_phase "$iteration" "$total_iterations" "login" "Running Login Test" "${ACCOUNT_TEST_ARGS[@]}"; then
    iteration_exit=1
    echo "⚠️ Login phase failed for iteration ${iteration}/${total_iterations}. Skipping content phase." | tee -a "$LOG_PATH"
  else
    login_phase_succeeded=1
    LOGIN_SUCCEEDED_AT_LEAST_ONCE=1
  fi

  if [ "$login_phase_succeeded" -eq 1 ]; then
    if ! run_xcodebuild_phase "$iteration" "$total_iterations" "content" "Running Content Tests" "${CONTENT_TEST_ARGS[@]}"; then
      iteration_exit=1
      echo "⚠️ Content phase failed for iteration ${iteration}/${total_iterations}." | tee -a "$LOG_PATH"
    fi
  fi

  merge_iteration_results "$iteration" >/dev/null 2>&1 || true
  return "$iteration_exit"
}

XCODEBUILD_EXIT=0
LAST_SUCCESSFUL_RESULT=""
LAST_ITERATION_RESULT=""
FINAL_LOGOUT_RESULT=""
LOGIN_SUCCEEDED_AT_LEAST_ONCE=0

if ! build_for_testing_once; then
  echo "❌ build-for-testing failed. Skipping test iterations." | tee -a "$LOG_PATH"
  XCODEBUILD_EXIT=1
fi

if [ "$XCODEBUILD_EXIT" -eq 0 ]; then
  for ((iteration=1; iteration<=TEST_ITERATIONS; iteration++)); do
    LAST_ITERATION_RESULT="$RESULTS_DIR/iterations/iteration_${iteration}.xcresult"
    if run_xcodebuild_iteration "$iteration" "$TEST_ITERATIONS"; then
      LAST_SUCCESSFUL_RESULT="$RESULTS_DIR/iterations/iteration_${iteration}.xcresult"
    else
      XCODEBUILD_EXIT=1
      echo "⚠️ Iteration ${iteration}/${TEST_ITERATIONS} failed." | tee -a "$LOG_PATH"
    fi
  done
fi

TRACE_DIR="$RESULTS_DIR/traces"
TRACE_MANIFEST="$TRACE_DIR/trace_manifest.txt"
mkdir -p "$TRACE_DIR"
rm -rf \
  "$TRACE_DIR/ActivityMonitor.trace" \
  "$TRACE_DIR/ActivityMonitor.sysmon-process.xml" \
  "$TRACE_DIR/ActivityMonitor.export.log" \
  "$TRACE_DIR/TimeProfiler.trace" \
  "$TRACE_DIR/TimeProfiler.export.log" \
  "$TRACE_DIR/Allocations.trace" \
  "$TRACE_DIR/Allocations.export.log" \
  "$TRACE_DIR/Network.har" \
  "$TRACE_DIR/Network.task-intervals.xml" \
  "$TRACE_DIR/Network.export.log" \
  "$TRACE_DIR/Network.trace" \
  "$TRACE_DIR/Leaks.trace" \
  "$TRACE_DIR/Energy.trace"
: > "$TRACE_MANIFEST"

# 6. REQUIRED INSTRUMENTS PASS (Activity, CPU, Memory, Leaks, Network)
if [ "${INSTRUMENTS:-0}" -eq 1 ]; then
  if [ "${XCODEBUILD_EXIT:-0}" -ne 0 ]; then
    echo "⚠️ Tests failed, but continuing with standalone Instruments capture." | tee -a "$LOG_PATH"
  fi
fi

if [ "${INSTRUMENTS:-0}" -eq 1 ]; then
  if [ -z "$REAL_DEVICE_ID" ] && [ "$SIM_AVAILABLE" -ne 1 ]; then
    echo "⚠️ Skipping Instruments: no device or simulator available."
    INSTRUMENTS=0
  fi
fi

# 6. REQUIRED INSTRUMENTS PASS (Activity, CPU, Memory, Leaks, Network)
if [ "${INSTRUMENTS:-0}" -eq 1 ]; then
  emit_phase "Capturing Instruments"
  echo "🔬 Running Instruments traces (Activity Monitor + Time Profiler + Allocations + Leaks + Network)..."

  DEVICE_FOR_TRACE=""
  if [ -n "$REAL_DEVICE_ID" ]; then
    DEVICE_FOR_TRACE="$REAL_DEVICE_ID"
  else
    DEVICE_FOR_TRACE="$SIM_UDID"
  fi

  PROBE_RESULTS_DIR="$RESULTS_DIR/instruments_probe"
  mkdir -p "$PROBE_RESULTS_DIR"
  rm -rf "$PROBE_RESULTS_DIR"/*.xcresult 2>/dev/null || true

  validate_trace_bundle() {
    local trace_path="$1"
    [ -d "$trace_path" ] || return 1
    find "$trace_path" -mindepth 1 | head -n 1 >/dev/null 2>&1
  }

  cleanup_stale_trace_recorders() {
    local trace_root="$1"
    ps -axo pid=,command= | while read -r pid command; do
      case "$command" in
        *"/usr/bin/xctrace record"*"$trace_root"*)
          if [ -n "$pid" ]; then
            kill "$pid" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "$pid" >/dev/null 2>&1 || true
          fi
          ;;
      esac
    done
  }

  wait_for_background_pid() {
    local pid="$1"
    local hard_timeout="$2"
    local waited=0
    while kill -0 "$pid" >/dev/null 2>&1; do
      if [ "$waited" -ge "$hard_timeout" ]; then
        kill "$pid" >/dev/null 2>&1 || true
        sleep 2
        kill -9 "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
        return 124
      fi
      sleep 1
      waited=$((waited + 1))
    done
    wait "$pid"
    return $?
  }

  run_instruments_probe() {
    local result_bundle="$1"
    rm -rf "$result_bundle"
    local probe_args=(
      test-without-building
      "${COMMON_XCODEBUILD_ARGS[@]}"
      -resultBundlePath "$result_bundle"
      "${INSTRUMENTS_PROBE_TEST_ARGS[@]}"
    )

    local probe_timeout="${INSTRUMENTS_PROBE_TIMEOUT_SECS:-120}"
    if [ "$probe_timeout" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
      timeout "$probe_timeout" xcodebuild "${probe_args[@]}" >>"$LOG_PATH" 2>&1
      return $?
    elif [ "$probe_timeout" -gt 0 ] && command -v gtimeout >/dev/null 2>&1; then
      gtimeout "$probe_timeout" xcodebuild "${probe_args[@]}" >>"$LOG_PATH" 2>&1
      return $?
    else
      xcodebuild "${probe_args[@]}" >>"$LOG_PATH" 2>&1
      return $?
    fi
  }

  trace_status() {
    local trace_name="$1"
    local state="$2"
    echo "PERF_TRACE name=${trace_name} state=${state}" | tee -a "$LOG_PATH"
  }

  trace_log_path() {
    local trace_name="$1"
    printf '%s/%s.log\n' "$TRACE_DIR" "${trace_name// /_}"
  }

  trace_preflight_log_path() {
    local trace_name="$1"
    printf '%s/%s.preflight.log\n' "$TRACE_DIR" "${trace_name// /_}"
  }

  trace_debug_permission_error_from_log() {
    local log_path="$1"
    [ -f "$log_path" ] || return 1
    if grep -qi "Permission to debug .* was denied" "$log_path" || grep -qi "get-task-allow" "$log_path"; then
      echo "app is not debuggable for this Instruments template (missing get-task-allow)"
      return 0
    fi
    if grep -qi "Unable to acquire required task port" "$log_path"; then
      echo "unable to acquire required task port"
      return 0
    fi
    if grep -qi "could not acquire the necessary privileges" "$log_path"; then
      echo "instruments could not acquire profiling privileges"
      return 0
    fi
    if grep -qi "Failed to attach to target process" "$log_path"; then
      echo "failed to attach to target process"
      return 0
    fi
    return 1
  }

  preflight_privileged_template() {
    local template_name="$1"
    local preflight_log
    preflight_log="$(trace_preflight_log_path "$template_name")"
    rm -f "$preflight_log"

    [ -n "${INSTRUMENTS_PROCESS_NAME:-}" ] || return 0
    [ -n "${REAL_DEVICE_ID:-}" ] || return 0

    local tmp_trace
    tmp_trace="$(mktemp "/tmp/${template_name// /_}_preflight_XXXXXX")"
    rm -f "$tmp_trace"
    tmp_trace="${tmp_trace}.trace"
    rm -rf "$tmp_trace"
    xcrun xctrace record \
      --template "$template_name" \
      --device "$DEVICE_FOR_TRACE" \
      --time-limit "${INSTRUMENTS_PERMISSION_PRECHECK_SECS:-3}s" \
      --no-prompt \
      --attach "$INSTRUMENTS_PROCESS_NAME" \
      --output "$tmp_trace" \
      >"$preflight_log" 2>&1 || true
    rm -rf "$tmp_trace"

    trace_debug_permission_error_from_log "$preflight_log" || true
  }

  run_xctrace_export() {
    local timeout_secs="$1"
    local stdout_path="$2"
    local stderr_path="$3"
    shift 3

    "$PYTHON_BIN" - "$timeout_secs" "$stdout_path" "$stderr_path" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
stdout_path = sys.argv[2]
stderr_path = sys.argv[3]
cmd = sys.argv[4:]

with open(stdout_path, "wb") as stdout_file, open(stderr_path, "ab") as stderr_file:
    proc = subprocess.Popen(
        cmd,
        stdout=stdout_file,
        stderr=stderr_file,
        start_new_session=True,
    )
    try:
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        stderr_file.write(f"\nTimed out after {timeout:.0f}s: {' '.join(cmd)}\n".encode("utf-8"))
        stderr_file.flush()
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        rc = 124

sys.exit(rc)
PY
  }

  record_trace_with_probe() {
    local template_name="$1"
    local output_path="$2"
    local trace_log="$TRACE_DIR/${template_name// /_}.log"
    local probe_result="$PROBE_RESULTS_DIR/${template_name// /_}.xcresult"
    local record_secs="${INSTRUMENTS_SECS:-60}"
    local hard_timeout="${INSTRUMENTS_HARD_TIMEOUT_SECS:-$((record_secs + 45))}"
    local trace_pid=""
    local trace_exit=0
    local probe_exit=0
    local record_target_args=()

    case "$template_name" in
      "Activity Monitor"|"Leaks"|"Network"|"Time Profiler"|"Allocations")
        if [ -n "${INSTRUMENTS_PROCESS_NAME:-}" ]; then
          record_target_args=(
            --attach "$INSTRUMENTS_PROCESS_NAME"
          )
        else
          record_target_args=(
            --all-processes
          )
        fi
        ;;
      *)
        if [ -n "${INSTRUMENTS_PROCESS_NAME:-}" ]; then
          record_target_args=(
            --attach "$INSTRUMENTS_PROCESS_NAME"
          )
        else
          record_target_args=(
            --all-processes
          )
        fi
        ;;
    esac

    emit_phase "Capturing Instruments"
    echo "🔬 Trace: $template_name" | tee -a "$LOG_PATH"
    rm -rf "$output_path" "$probe_result"

    xcrun xctrace record \
      --template "$template_name" \
      --device "$DEVICE_FOR_TRACE" \
      --time-limit "${record_secs}s" \
      --no-prompt \
      "${record_target_args[@]}" \
      --output "$output_path" \
      >"$trace_log" 2>&1 &
    trace_pid=$!

    sleep 4
    run_instruments_probe "$probe_result"
    probe_exit=$?
    if [ "$probe_exit" -ne 0 ]; then
      echo "⚠️ Instruments probe for $template_name failed (non-fatal)" | tee -a "$LOG_PATH"
    fi

    wait_for_background_pid "$trace_pid" "$hard_timeout"
    trace_exit=$?

    if [ "$trace_exit" -eq 124 ]; then
      echo "⚠️ $template_name trace hit hard timeout and was terminated (non-fatal)" | tee -a "$LOG_PATH"
      [ -f "$trace_log" ] && tail -n 20 "$trace_log" | sed 's/^/   /'
      return 1
    fi

    if [ "$trace_exit" -ne 0 ]; then
      echo "⚠️ $template_name trace failed (non-fatal)" | tee -a "$LOG_PATH"
      [ -f "$trace_log" ] && tail -n 20 "$trace_log" | sed 's/^/   /'
      return 1
    fi

    if [ "$probe_exit" -ne 0 ]; then
      echo "⚠️ $template_name probe exercise failed; trace may be incomplete." | tee -a "$LOG_PATH"
    fi

    if ! validate_trace_bundle "$output_path"; then
      echo "⚠️ $template_name trace bundle is empty or invalid (non-fatal)" | tee -a "$LOG_PATH"
      [ -f "$trace_log" ] && tail -n 20 "$trace_log" | sed 's/^/   /'
      return 1
    fi

    echo "$(basename "$output_path")" >> "$TRACE_MANIFEST"
    return 0
  }

  export_network_trace_data() {
    rm -f "$TRACE_DIR/Network.har" "$TRACE_DIR/Network.task-intervals.xml" "$TRACE_DIR/Network.export.log"
    if [ ! -d "$TRACE_DIR/Network.trace" ]; then
      return 1
    fi
    local export_timeout="${INSTRUMENTS_EXPORT_TIMEOUT_SECS:-25}"

    run_xctrace_export \
      "$export_timeout" \
      "$TRACE_DIR/Network.task-intervals.xml" \
      "$TRACE_DIR/Network.export.log" \
      xcrun xctrace export \
        --input "$TRACE_DIR/Network.trace" \
        --xpath "/trace-toc/run[@number='1']/data/table[@schema='com-apple-cfnetwork-task-intervals']" || true

    HAR_EXPORT_DIR="$(mktemp -d /tmp/perf_network_har_XXXXXX)"
    if run_xctrace_export \
      "$export_timeout" \
      "/dev/null" \
      "$TRACE_DIR/Network.export.log" \
      xcrun xctrace export \
        --input "$TRACE_DIR/Network.trace" \
        --har \
        --output "$HAR_EXPORT_DIR"; then
      HAR_FILE="$(find "$HAR_EXPORT_DIR" -type f -name '*.har' | head -n 1)"
      if [ -n "${HAR_FILE:-}" ] && [ -f "$HAR_FILE" ]; then
        cp "$HAR_FILE" "$TRACE_DIR/Network.har"
      fi
    fi
    rm -rf "$HAR_EXPORT_DIR"
  }

  network_trace_has_payload() {
    local har_size=0
    if [ -f "$TRACE_DIR/Network.har" ]; then
      har_size=$(wc -c < "$TRACE_DIR/Network.har" 2>/dev/null || echo 0)
    fi
    if [ "$har_size" -gt 120 ]; then
      return 0
    fi
    if [ -f "$TRACE_DIR/Network.task-intervals.xml" ] && grep -q "<row" "$TRACE_DIR/Network.task-intervals.xml"; then
      return 0
    fi
    return 1
  }

  cleanup_stale_trace_recorders "$TRACE_DIR"

  ALLOCATIONS_PRECHECK_ERROR=""
  LEAKS_PRECHECK_ERROR=""
  if [ "${INSTRUMENTS_ALLOCATIONS:-1}" -eq 1 ]; then
    ALLOCATIONS_PRECHECK_ERROR="$(preflight_privileged_template "Allocations")"
    if [ -n "$ALLOCATIONS_PRECHECK_ERROR" ]; then
      echo "⚠️ Allocations preflight failed: $ALLOCATIONS_PRECHECK_ERROR" | tee -a "$LOG_PATH"
    fi
  fi
  if [ "${INSTRUMENTS_LEAKS:-0}" -eq 1 ]; then
    LEAKS_PRECHECK_ERROR="$(preflight_privileged_template "Leaks")"
    if [ -n "$LEAKS_PRECHECK_ERROR" ]; then
      echo "⚠️ Leaks preflight failed: $LEAKS_PRECHECK_ERROR" | tee -a "$LOG_PATH"
    fi
  fi

  trace_status "Activity Monitor" "started"
  if record_trace_with_probe "Activity Monitor" "$TRACE_DIR/ActivityMonitor.trace"; then
    trace_status "Activity Monitor" "captured"
  else
    trace_status "Activity Monitor" "failed"
  fi

  if [ "${INSTRUMENTS_LEAKS:-0}" -eq 1 ]; then
    echo "🔬 Trace: Leaks" | tee -a "$LOG_PATH"
    trace_status "Leaks" "started"
    if [ -n "$LEAKS_PRECHECK_ERROR" ]; then
      cat "$(trace_preflight_log_path "Leaks")" > "$(trace_log_path "Leaks")" 2>/dev/null || true
      trace_status "Leaks" "failed"
    elif record_trace_with_probe "Leaks" "$TRACE_DIR/Leaks.trace"; then
      trace_status "Leaks" "captured"
    else
      trace_status "Leaks" "failed"
    fi
  else
    echo "ℹ️ Leak capture disabled for this run." | tee -a "$LOG_PATH"
    trace_status "Leaks" "disabled"
  fi

  if [ "${INSTRUMENTS_TIME_PROFILER:-1}" -eq 1 ]; then
    trace_status "Time Profiler" "started"
    if record_trace_with_probe "Time Profiler" "$TRACE_DIR/TimeProfiler.trace"; then
      trace_status "Time Profiler" "captured"
    else
      trace_status "Time Profiler" "failed"
    fi
  else
    echo "ℹ️ Time Profiler capture disabled for this run." | tee -a "$LOG_PATH"
    trace_status "Time Profiler" "disabled"
  fi

  if [ "${INSTRUMENTS_ALLOCATIONS:-1}" -eq 1 ]; then
    trace_status "Allocations" "started"
    if [ -n "$ALLOCATIONS_PRECHECK_ERROR" ]; then
      cat "$(trace_preflight_log_path "Allocations")" > "$(trace_log_path "Allocations")" 2>/dev/null || true
      trace_status "Allocations" "failed"
    elif record_trace_with_probe "Allocations" "$TRACE_DIR/Allocations.trace"; then
      trace_status "Allocations" "captured"
    else
      trace_status "Allocations" "failed"
    fi
  else
    echo "ℹ️ Allocations capture disabled for this run." | tee -a "$LOG_PATH"
    trace_status "Allocations" "disabled"
  fi

  if [ "${INSTRUMENTS_NETWORK:-1}" -eq 1 ]; then
    trace_status "Network" "started"
    if record_trace_with_probe "Network" "$TRACE_DIR/Network.trace"; then
      trace_status "Network" "captured"
    else
      trace_status "Network" "failed"
    fi
  else
    echo "ℹ️ Network capture disabled for this run." | tee -a "$LOG_PATH"
    trace_status "Network" "disabled"
  fi

  for fallback_trace in "$TRACE_DIR"/*.trace; do
    [ -d "$fallback_trace" ] || continue
    fallback_name="$(basename "$fallback_trace")"
    if ! grep -qxF "$fallback_name" "$TRACE_MANIFEST" 2>/dev/null; then
      echo "$fallback_name" >> "$TRACE_MANIFEST"
    fi
  done

  export_trace_table_preference() {
    local trace_path="$1"
    local output_path="$2"
    local log_path="$3"
    shift 3
    local export_timeout="${INSTRUMENTS_EXPORT_TIMEOUT_SECS:-25}"

    rm -f "$output_path"
    : > "$log_path"

    local schema=""
    local export_rc=0
    for schema in "$@"; do
      [ -n "$schema" ] || continue
      if run_xctrace_export \
        "$export_timeout" \
        "$output_path" \
        "$log_path" \
        xcrun xctrace export \
          --input "$trace_path" \
          --xpath "/trace-toc/run[@number='1']/data/table[@schema='${schema}']"; then
        if [ -s "$output_path" ] && grep -Eq "<(row|table|trace-query-result)" "$output_path"; then
          echo "$schema" >> "$log_path"
          return 0
        fi
        export_rc=0
      else
        export_rc=$?
      fi
      echo "schema=${schema} rc=${export_rc}" >> "$log_path"
      rm -f "$output_path"
    done
    return 1
  }

  if [ -d "$TRACE_DIR/ActivityMonitor.trace" ]; then
    export_trace_table_preference \
      "$TRACE_DIR/ActivityMonitor.trace" \
      "$TRACE_DIR/ActivityMonitor.sysmon-process.xml" \
      "$TRACE_DIR/ActivityMonitor.export.log" \
      "sysmon-process" \
      "activity-monitor-process-live" \
      "activity-monitor-process-ledger" || true
  fi

  if [ -d "$TRACE_DIR/TimeProfiler.trace" ]; then
    export_trace_table_preference \
      "$TRACE_DIR/TimeProfiler.trace" \
      "$TRACE_DIR/TimeProfiler.table.xml" \
      "$TRACE_DIR/TimeProfiler.export.log" \
      "time-profile" \
      "com.apple.xray.instrument-type.time-profiler" \
      "com.apple.xray.time-profiler" \
      "com.apple.xray.cpu-profile" || true
  fi

  if [ -d "$TRACE_DIR/Allocations.trace" ]; then
    export_trace_table_preference \
      "$TRACE_DIR/Allocations.trace" \
      "$TRACE_DIR/Allocations.table.xml" \
      "$TRACE_DIR/Allocations.export.log" \
      "allocations" \
      "com.apple.xray.instrument-type.allocations" \
      "com.apple.xray.allocations" \
      "com.apple.xray.instrument-type.oa" || true
  fi

  if [ -d "$TRACE_DIR/Leaks.trace" ]; then
    export_trace_table_preference \
      "$TRACE_DIR/Leaks.trace" \
      "$TRACE_DIR/Leaks.table.xml" \
      "$TRACE_DIR/Leaks.export.log" \
      "leaks" \
      "com.apple.xray.instrument-type.leaks" \
      "com.apple.xray.leaks" || true
  fi

  if [ -d "$TRACE_DIR/Network.trace" ]; then
    export_network_trace_data
    if network_trace_has_payload; then
      trace_status "Network" "exported"
    else
      echo "⚠️ Network trace exported no payload." | tee -a "$LOG_PATH"
      trace_status "Network" "no payload"
    fi
  else
    trace_status "Network" "missing"
  fi

  # Auto-open traces
  if [ "${AUTO_OPEN_TRACES:-1}" -eq 1 ] && [ -d "$TRACE_DIR/ActivityMonitor.trace" ]; then
    open -a Instruments "$TRACE_DIR/ActivityMonitor.trace" >/dev/null 2>&1 || \
      open "$TRACE_DIR/ActivityMonitor.trace" >/dev/null 2>&1 &
  fi
  if [ "${AUTO_OPEN_TRACES:-1}" -eq 1 ] && [ -d "$TRACE_DIR/TimeProfiler.trace" ]; then
    open -a Instruments "$TRACE_DIR/TimeProfiler.trace" >/dev/null 2>&1 || \
      open "$TRACE_DIR/TimeProfiler.trace" >/dev/null 2>&1 &
  fi
  if [ "${AUTO_OPEN_TRACES:-1}" -eq 1 ] && [ -d "$TRACE_DIR/Allocations.trace" ]; then
    open -a Instruments "$TRACE_DIR/Allocations.trace" >/dev/null 2>&1 || \
      open "$TRACE_DIR/Allocations.trace" >/dev/null 2>&1 &
  fi
  if [ "${AUTO_OPEN_TRACES:-1}" -eq 1 ] && [ -d "$TRACE_DIR/Leaks.trace" ]; then
    open -a Instruments "$TRACE_DIR/Leaks.trace" >/dev/null 2>&1 || \
      open "$TRACE_DIR/Leaks.trace" >/dev/null 2>&1 &
  fi
  if [ "${AUTO_OPEN_TRACES:-1}" -eq 1 ] && [ -d "$TRACE_DIR/Network.trace" ]; then
    open -a Instruments "$TRACE_DIR/Network.trace" >/dev/null 2>&1 || \
      open "$TRACE_DIR/Network.trace" >/dev/null 2>&1 &
  fi
fi

if [ "$LOGIN_SUCCEEDED_AT_LEAST_ONCE" -eq 1 ]; then
  FINAL_LOGOUT_RESULT="$RESULTS_DIR/iterations/iteration_${TEST_ITERATIONS}_final_logout.xcresult"
  if ! run_xcodebuild_phase "$TEST_ITERATIONS" "$TEST_ITERATIONS" "final_logout" "Running Final Logout Test" "${LOGOUT_TEST_ARGS[@]}"; then
    XCODEBUILD_EXIT=1
    echo "⚠️ Final logout phase failed." | tee -a "$LOG_PATH"
  fi
fi

rm -rf "$RESULTS_DIR/Performance.xcresult"
BASE_RESULT=""
if [ -n "$LAST_ITERATION_RESULT" ] && [ -d "$LAST_ITERATION_RESULT" ]; then
  BASE_RESULT="$LAST_ITERATION_RESULT"
elif [ -n "$LAST_SUCCESSFUL_RESULT" ] && [ -d "$LAST_SUCCESSFUL_RESULT" ]; then
  BASE_RESULT="$LAST_SUCCESSFUL_RESULT"
fi

if [ -n "$BASE_RESULT" ] && [ -d "$BASE_RESULT" ] && [ -n "$FINAL_LOGOUT_RESULT" ] && [ -d "$FINAL_LOGOUT_RESULT" ]; then
  if ! xcrun xcresulttool merge --output-path "$RESULTS_DIR/Performance.xcresult" "$BASE_RESULT" "$FINAL_LOGOUT_RESULT" >/dev/null 2>&1; then
    echo "⚠️ Failed to merge final logout result; falling back to base result only." | tee -a "$LOG_PATH"
    cp -R "$BASE_RESULT" "$RESULTS_DIR/Performance.xcresult"
  fi
elif [ -n "$BASE_RESULT" ] && [ -d "$BASE_RESULT" ]; then
  cp -R "$BASE_RESULT" "$RESULTS_DIR/Performance.xcresult"
elif [ -n "$FINAL_LOGOUT_RESULT" ] && [ -d "$FINAL_LOGOUT_RESULT" ]; then
  cp -R "$FINAL_LOGOUT_RESULT" "$RESULTS_DIR/Performance.xcresult"
fi

# 5. GENERATE REPORTS (after Instruments so traces can be included)
REPORT_TIMEOUT_SECS="${REPORT_TIMEOUT_SECS:-120}"
emit_phase "Generating Report"
RUN_REPORT_CMD=("$PYTHON_BIN" scripts/perf_report.py \
  --xcresult "$RESULTS_DIR/Performance.xcresult" \
  --xcresult-dir "$RESULTS_DIR/iterations" \
  --log "$LOG_PATH" \
  --out "$RESULTS_DIR/PerformanceReport.html" \
  --json "$RESULTS_DIR/PerformanceReport.json" \
  --csv "$RESULTS_DIR/PerformanceReport.csv" \
  --txt "$RESULTS_DIR/PerformanceReport.txt")

REPORT_EXIT=0
if [ "$REPORT_TIMEOUT_SECS" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
  timeout "$REPORT_TIMEOUT_SECS" "${RUN_REPORT_CMD[@]}" || REPORT_EXIT=$?
elif [ "$REPORT_TIMEOUT_SECS" -gt 0 ] && command -v gtimeout >/dev/null 2>&1; then
  gtimeout "$REPORT_TIMEOUT_SECS" "${RUN_REPORT_CMD[@]}" || REPORT_EXIT=$?
elif [ "$REPORT_TIMEOUT_SECS" -gt 0 ]; then
  "$PYTHON_BIN" - "$REPORT_TIMEOUT_SECS" "${RUN_REPORT_CMD[@]}" <<'PY'
import subprocess
import sys

timeout_secs = int(sys.argv[1])
cmd = sys.argv[2:]
try:
    completed = subprocess.run(cmd, timeout=timeout_secs, check=False)
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
  REPORT_EXIT=$?
else
  "${RUN_REPORT_CMD[@]}" || REPORT_EXIT=$?
fi

if [ "$REPORT_EXIT" -eq 124 ]; then
  echo "⚠️ Report generation timed out after ${REPORT_TIMEOUT_SECS}s" | tee -a "$LOG_PATH"
elif [ "$REPORT_EXIT" -ne 0 ]; then
  echo "⚠️ Report generation exited with code $REPORT_EXIT" | tee -a "$LOG_PATH"
fi

if [ ! -f "$RESULTS_DIR/PerformanceReport.html" ] || [ ! -f "$RESULTS_DIR/PerformanceReport.csv" ] || [ ! -f "$RESULTS_DIR/PerformanceReport.json" ] || [ ! -f "$RESULTS_DIR/PerformanceReport.txt" ]; then
  echo "⚠️ Report missing; generating fast fallback report without trace exports..."
  "$PYTHON_BIN" scripts/perf_report.py \
    --skip-traces \
    --xcresult "$RESULTS_DIR/Performance.xcresult" \
    --xcresult-dir "$RESULTS_DIR/iterations" \
    --log "$LOG_PATH" \
    --out "$RESULTS_DIR/PerformanceReport.html" \
    --json "$RESULTS_DIR/PerformanceReport.json" \
    --csv "$RESULTS_DIR/PerformanceReport.csv" \
    --txt "$RESULTS_DIR/PerformanceReport.txt" || echo "⚠️ Fast fallback report generation failed." | tee -a "$LOG_PATH"
fi

emit_phase "Report Ready"

echo "✅ Done! Results are here:"
echo "   - $RUN_SESSION_DIR"
echo "   - $RUN_SESSION_DIR/PerformanceReport.html"
echo "   - $RUN_SESSION_DIR/PerformanceReport.json"
echo "   - $RUN_SESSION_DIR/PerformanceReport.csv"
echo "   - $RUN_SESSION_DIR/PerformanceReport.txt"
if [ "${AUTO_OPEN_RESULTS:-1}" -eq 1 ] || [ "${AUTO_OPEN_RESULTS_FOLDER:-1}" -eq 1 ]; then
  echo "✅ Attempting to open results..."
fi
if [ "${AUTO_OPEN_RESULTS:-1}" -eq 1 ]; then
  if [ -d "$RUN_SESSION_DIR/Performance.xcresult" ]; then
    open -a Xcode "$RUN_SESSION_DIR/Performance.xcresult" >/dev/null 2>&1 || \
      open "$RUN_SESSION_DIR/Performance.xcresult" >/dev/null 2>&1 &
  else
    echo "⚠️ .xcresult not found: $RUN_SESSION_DIR/Performance.xcresult"
    echo "   (Check $RESULTS_DIR/perf.log for xcodebuild errors)"
  fi

  if [ -f "$RUN_SESSION_DIR/PerformanceReport.html" ]; then
    open "$RUN_SESSION_DIR/PerformanceReport.html" >/dev/null 2>&1 &
  else
    echo "⚠️ HTML report not found: $RUN_SESSION_DIR/PerformanceReport.html"
    echo "   (Check $RESULTS_DIR/perf.log for xcodebuild errors)"
  fi

  echo "If nothing opened, run these manually:"
  echo "  open \"$RUN_SESSION_DIR/Performance.xcresult\""
  echo "  open \"$RUN_SESSION_DIR/PerformanceReport.html\""
fi

if [ "${AUTO_OPEN_RESULTS_FOLDER:-1}" -eq 1 ]; then
  open "$RUN_SESSION_DIR" >/dev/null 2>&1 &
fi

# 6. AUTO-PACKAGE (optional)
# Create a zip file named after the device used (e.g., Report_2026-01-28.zip)
if [ "${ZIP_RESULTS:-1}" -eq 1 ] && [ "${AUTO_PACKAGE_RESULTS:-1}" -eq 1 ]; then
  ZIP_NAME="$RUN_SESSION_DIR/Report_$(date +%F).zip"
  echo "📦 Packaging results in background: $ZIP_NAME"
  nohup zip -r "$ZIP_NAME" "$RUN_SESSION_DIR/Performance.xcresult" >/dev/null 2>&1 </dev/null &
fi

emit_phase "Done"
echo "PERF_DONE exit=$XCODEBUILD_EXIT" | tee -a "$LOG_PATH"
exit "$XCODEBUILD_EXIT"
