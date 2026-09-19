#!/bin/bash
# Assemble pfeifer.app from the release build, codesign it, and
# (optionally) launch it. Run from the repo root via `make app`.
#
# The app is a menu-bar agent (LSUIElement): no Dock icon, no main window.
# The bundle identifier and usage descriptions below are required for the
# microphone TCC prompt and notification center to work.
#
# Signing: an ad-hoc signature changes with every rebuild, which silently
# invalidates the TCC Accessibility grant (the System Settings toggle
# stays on, but the new binary isn't trusted — so the app re-prompts
# forever). To keep the grant stable across rebuilds, create once in
# Keychain Access → Certificate Assistant → Create Certificate: a
# self-signed certificate named "Pfeifer Development", certificate type
# "Code Signing", in the login keychain. This script signs with it
# automatically when present and falls back to ad-hoc (with a warning)
# when not.
set -euo pipefail

APP_NAME="pfeifer"
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

# The bundle and binary are lowercase; the display name keeps its capital P.
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
    <string>Pfeifer</string>
    <key>CFBundleDisplayName</key>
    <string>Pfeifer</string>
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

# Prefer the stable "Pfeifer Development" identity over ad-hoc so the
# Accessibility grant survives rebuilds (see header). Fall back to ad-hoc
# when the certificate is missing or unusable (e.g. locked keychain).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Pfeifer Development/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "codesigned $APP with '$IDENTITY' (stable across rebuilds)"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "warning: signed ad-hoc — the Accessibility grant breaks on every rebuild." >&2
  echo "         Create a 'Pfeifer Development' code-signing certificate; see the" >&2
  echo "         header of scripts/make-app.sh for one-time setup." >&2
fi
echo "built $APP"

if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
  echo "launched"
fi
