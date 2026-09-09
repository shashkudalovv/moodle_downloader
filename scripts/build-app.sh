#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="Moodle Downloader"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

cd "$ROOT_DIR"
swift build -c release
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/MoodleDownloader" "$APP_DIR/Contents/MacOS/MoodleDownloader"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
