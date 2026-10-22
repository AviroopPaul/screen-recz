#!/usr/bin/env bash
# Builds build/ScreenRecz.app (release; signed with "ScreenRecz Local Signing" if present, else ad-hoc). Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ScreenRecz"

APP=build/ScreenRecz.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenRecz"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/ScreenRecz"
# A stable identity keeps macOS privacy permissions across rebuilds; ad-hoc signing resets them every build.
IDENTITY="$(security find-identity -p codesigning | awk '/"ScreenRecz Local Signing"/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ScreenRecz 2>/dev/null || true
  rm -rf /Applications/ScreenRecz.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/ScreenRecz.app"
fi
