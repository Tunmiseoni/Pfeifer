#!/bin/bash
# Assemble Pfeifer.app from the release build, ad-hoc codesign it, and
# (optionally) launch it. Run from the repo root via `make app`.
#
# The app is a menu-bar agent (LSUIElement): no Dock icon, no main window.
# The bundle identifier and usage descriptions below are required for the
# microphone TCC prompt and notification center to work.
set -euo pipefail

APP_NAME="Pfeifer"
BUNDLE_ID="com.tunmise.pfeifer"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/$APP_NAME.app"

BIN_PATH="$(swift build -c release --show-bin-path 2>/dev/null)"
if [[ -z "$BIN_PATH" || ! -x "$BIN_PATH/$APP_NAME" ]]; then
  echo "error: release binary not found — run 'swift build -c release' first" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Pfeifer records your voice on this Mac and transcribes it locally; audio never leaves the machine.</string>
    <key>NSUserNotificationsUsageDescription</key>
    <string>Pfeifer notifies you when a transcript is placed on the clipboard instead of being typed.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $APP"

if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
  echo "launched"
fi
