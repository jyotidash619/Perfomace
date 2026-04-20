#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="/tmp/PerfoMaceLauncherBuild"
APP_NAME="PerfoMace Launcher v2.app"
DIST_DIR="${ROOT_DIR}/launcher/dist"
DEST_APP="${DIST_DIR}/${APP_NAME}"
READY_CHECK_APP="${DIST_DIR}/PerfoMace Ready Check.app"
SHAREABLE_ZIP="/Users/jyotidash/Desktop/PerfoMace-v2-shareable.zip"

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

echo "Creating shareable zip at ${SHAREABLE_ZIP}..."
python3 - "${ROOT_DIR}" "${SHAREABLE_ZIP}" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
zip_path = pathlib.Path(sys.argv[2])
exclude_parts = {
    ".git",
    "results",
    "dist_build",
    "__pycache__",
    "xcuserdata",
    ".DS_Store",
    ".setup_done",
}

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for path in root.rglob("*"):
        if path.is_dir():
            continue
        rel = path.relative_to(root)
        if any(part in exclude_parts for part in rel.parts):
            continue
        if rel == pathlib.Path("launcher/dist.zip"):
            continue
        zf.write(path, rel.as_posix())
PY

echo "Done."
