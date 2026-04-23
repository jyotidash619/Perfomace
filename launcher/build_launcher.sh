#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="/tmp/PerfoMaceLauncherBuild"
APP_NAME="PerfoMace Launcher v2.app"
DIST_DIR="${ROOT_DIR}/launcher/dist"
DEST_APP="${DIST_DIR}/${APP_NAME}"
READY_CHECK_APP="${DIST_DIR}/PerfoMace Ready Check.app"
LOCAL_SHARE_DIR="${ROOT_DIR}/local_share"
SHAREABLE_ZIP="${LOCAL_SHARE_DIR}/PerfoMace-v2-local-share.zip"

ensure_tmpdir() {
  local candidate="${TMPDIR:-}"
  local probe=""

  if [ -n "$candidate" ] && [ -d "$candidate" ] && [ -w "$candidate" ]; then
    probe="$(mktemp "$candidate/perfomace_launcher_tmp.XXXXXX" 2>/dev/null || true)"
    if [ -n "$probe" ]; then
      rm -f "$probe"
      return 0
    fi
  fi

  local fallback=""
  fallback="$(mktemp -d "/tmp/perfomace_launcher_tmp.XXXXXX" 2>/dev/null || true)"
  if [ -z "$fallback" ]; then
    mkdir -p /tmp/perfomace_launcher_tmp_fallback
    fallback="/tmp/perfomace_launcher_tmp_fallback"
  fi

  export TMPDIR="$fallback"
  echo "Using fallback TMPDIR: $TMPDIR"
}

ensure_tmpdir

echo "Building ${APP_NAME}..."
xcodebuild -project "${ROOT_DIR}/PerfoMace.xcodeproj" \
  -scheme PerfoMaceLauncher \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${BUILD_DIR}" \
  build

echo "Publishing app bundle to ${DEST_APP}..."
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
cp -R "${BUILD_DIR}/Build/Products/Debug/${APP_NAME}" "${DEST_APP}"

echo "Building ready check app..."
"${ROOT_DIR}/launcher/build_ready_check_app.sh"

mkdir -p "${LOCAL_SHARE_DIR}"
echo "Creating shareable zip at ${SHAREABLE_ZIP}..."
python3 - "${ROOT_DIR}" "${SHAREABLE_ZIP}" <<'PY'
import os
import pathlib
import shutil
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
zip_path = pathlib.Path(sys.argv[2])
stage_root = pathlib.Path("/tmp/PerfoMace_v2_share_stage")
share_root = stage_root / "PerfoMace v2"

if stage_root.exists():
    shutil.rmtree(stage_root)
share_root.mkdir(parents=True)

include_roots = [
    "README.md",
    "README_FIRST.md",
    "PerfoMace_Ready_Check.sh",
    "PerfoMace.xcodeproj",
    "assets",
    "codebase",
    "launcher",
]

exclude_parts = {
    ".git",
    "results",
    "history",
    "exports",
    "dist_build",
    "__pycache__",
    "xcuserdata",
    ".DS_Store",
    ".setup_done",
}

def should_skip(path: pathlib.Path) -> bool:
    return any(part in exclude_parts for part in path.parts)

for entry in include_roots:
    source = root / entry
    if not source.exists():
        continue
    if entry in {"README.md", "README_FIRST.md", "PerfoMace_Ready_Check.sh"}:
        destination = share_root / pathlib.Path(entry).name
    else:
        destination = share_root / "Source" / entry
    if source.is_dir():
        shutil.copytree(
            source,
            destination,
            ignore=shutil.ignore_patterns(
                ".git",
                "results",
                "history",
                "exports",
                "dist_build",
                "dist.zip",
                "__pycache__",
                "xcuserdata",
                ".DS_Store",
                ".setup_done",
            ),
        )
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

launcher_app = root / "launcher" / "dist" / "PerfoMace Launcher v2.app"
ready_check_app = root / "launcher" / "dist" / "PerfoMace Ready Check.app"

if launcher_app.exists():
    shutil.copytree(launcher_app, share_root / launcher_app.name, dirs_exist_ok=True)
if ready_check_app.exists():
    shutil.copytree(ready_check_app, share_root / ready_check_app.name, dirs_exist_ok=True)

start_here = share_root / "START_HERE.txt"
start_here.write_text(
    "\n".join([
        "PerfoMace v2",
        "",
        "Start here:",
        "1. Open 'PerfoMace Launcher v2.app' to run PerfoMace.",
        "2. Open 'PerfoMace Ready Check.app' if you want a guided setup check first.",
        "",
        "If macOS blocks the app the first time, right-click the app and choose Open.",
        "",
        "If you want the source project, open the 'Source' folder.",
        "",
    ]),
    encoding="utf-8",
)

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for path in stage_root.rglob("*"):
        if path.is_dir() or should_skip(path.relative_to(stage_root)):
            continue
        zf.write(path, path.relative_to(stage_root).as_posix())

shutil.rmtree(stage_root, ignore_errors=True)
PY

echo "Done."
