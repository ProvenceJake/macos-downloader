#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <release-tag>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="$1"
APP_NAME="MacOS下载器.app"
DMG_NAME="MacOS-Downloader-${TAG}-arm64.dmg"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/$DMG_NAME"

if [[ -e "$DMG_PATH" ]]; then
  echo "Release image already exists: $DMG_PATH" >&2
  exit 1
fi

"$ROOT_DIR/Scripts/build-arm64-app.sh"
/usr/bin/codesign --verify --deep --strict "$ROOT_DIR/build/$APP_NAME"
/usr/bin/lipo "$ROOT_DIR/build/$APP_NAME/Contents/MacOS/MacOSDownloader" -verify_arch arm64

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}MacOSDownloader-DMG.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

/usr/bin/ditto "$ROOT_DIR/build/$APP_NAME" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$ROOT_DIR/README.md" "$STAGING_DIR/README.md"
cp "$ROOT_DIR/README.zh-CN.md" "$STAGING_DIR/README.zh-CN.md"

/usr/bin/hdiutil create \
  -srcfolder "$STAGING_DIR" \
  -volname "macOS Downloader" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt
)

echo "$DMG_PATH"
