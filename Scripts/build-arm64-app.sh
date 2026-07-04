#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacOS下载器.app"
APP_PATH="$ROOT_DIR/build/$APP_NAME"
BINARY_PATH="$ROOT_DIR/.build/arm64-apple-macosx/release/MacOSDownloader"

cd "$ROOT_DIR"

swift build -c release --arch arm64

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/MacOSDownloader"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

/usr/bin/xattr -cr "$APP_PATH"
/usr/bin/codesign --force --deep --sign - "$APP_PATH" >/dev/null
/usr/bin/xattr -cr "$APP_PATH"

echo "$APP_PATH"
