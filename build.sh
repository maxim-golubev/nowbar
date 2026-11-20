#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="NowBar.app"
BIN="$APP/Contents/MacOS/NowBar"

echo "Compiling..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O NowBar.swift -o "$BIN" -framework Cocoa -framework ApplicationServices

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NowBar</string>
  <key>CFBundleDisplayName</key><string>NowBar</string>
  <key>CFBundleIdentifier</key><string>com.nowbar.app</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>NowBar</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>NowBar reads Spotify/Music track info for the controller.</string>
</dict>
</plist>
PLIST

# Sign with a stable self-signed identity if present (so the Accessibility grant
# survives rebuilds); fall back to ad-hoc otherwise.
if security find-identity -p codesigning 2>/dev/null | grep -q "NowBar Dev"; then
  echo "Code-signing with stable identity 'NowBar Dev'..."
  codesign --force --deep --options runtime --sign "NowBar Dev" "$APP" 2>/dev/null \
    || codesign --force --deep --sign "NowBar Dev" "$APP"
else
  echo "Code-signing (ad-hoc — no stable identity found)..."
  codesign --force --deep --sign - "$APP"
fi
echo "Built: $(pwd)/$APP"
codesign -dv "$APP" 2>&1 | grep -iE "Authority|Identifier=" | head -3
