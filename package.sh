#!/bin/bash
# Builds NotchIsland.app. No Xcode project needed — SPM builds the binary and we assemble
# the bundle by hand, which keeps the whole thing buildable from a terminal.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/NotchIsland.app"
BIN="$(swift build -c release --show-bin-path)/NotchIsland"

echo "==> building"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchIsland"

# OCR A Extended is copied from the system at package time rather than committed, so a
# font of uncertain redistribution license never enters the repo. The app falls back to a
# system-installed copy, then to Menlo, if it is absent.
if [ -f /Library/Fonts/OCRAEXT.TTF ]; then
  cp /Library/Fonts/OCRAEXT.TTF "$APP/Contents/Resources/OCRAEXT.TTF"
  echo "    bundled OCR A Extended"
else
  echo "    WARNING: /Library/Fonts/OCRAEXT.TTF not found — falling back to Menlo"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NotchIsland</string>
    <key>CFBundleDisplayName</key><string>NotchIsland</string>
    <key>CFBundleIdentifier</key><string>com.stratcore.notchisland</string>
    <key>CFBundleExecutable</key><string>NotchIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchIsland brings the Terminal tab that owns a CLI session to the front when you click it.</string>
</dict>
</plist>
PLIST

echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> done: $APP"
