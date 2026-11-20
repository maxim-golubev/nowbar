#!/bin/bash
# Build NowBar and install it as the one copy on this Mac: /Applications/NowBar.app.
#
#   ./build.sh               build, install to /Applications, relaunch
#   ./build.sh --no-install  build only; leaves the bundle in build/NowBar.app
#
# Only /Applications/NowBar.app may stay on the Mac: Spotlight lists every other copy
# beside it, so the staging bundle is unregistered from LaunchServices and deleted once
# it has been installed.
set -euo pipefail
cd "$(dirname "$0")"

APP_ID="com.nowbar.app"
DEST="/Applications/NowBar.app"
STAGE="build/NowBar.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
INSTALL=true
[ "${1:-}" = "--no-install" ] && INSTALL=false

# ── Build into a clean staging bundle ──
rm -rf build
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
echo "Compiling..."
swiftc -O NowBar.swift -o "$STAGE/Contents/MacOS/NowBar" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement
cp packaging/NowBar.icns "$STAGE/Contents/Resources/NowBar.icns"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NowBar</string>
  <key>CFBundleDisplayName</key><string>NowBar</string>
  <key>CFBundleIdentifier</key><string>com.nowbar.app</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>NowBar</string>
  <key>CFBundleIconFile</key><string>NowBar</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>NowBar reads Spotify/Music track info for the controller.</string>
</dict>
</plist>
PLIST
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null

# ── Sign ──
# With the stable self-signed identity when present, so the Accessibility grant (which macOS
# ties to the signature) survives rebuilds; ad hoc otherwise, which needs a re-grant each build.
if security find-identity -p codesigning 2>/dev/null | grep -q "NowBar Dev"; then
  echo "Code-signing with stable identity 'NowBar Dev'..."
  codesign --force --sign "NowBar Dev" "$STAGE"
else
  echo "WARNING: no 'NowBar Dev' identity; signing ad hoc (re-grant Accessibility after installing)." >&2
  codesign --force --sign - "$STAGE"
fi
codesign --verify --strict "$STAGE"

if ! $INSTALL; then
  echo "Built: $(pwd)/$STAGE"
  exit 0
fi

# ── Install: quit the running copy, replace /Applications/NowBar.app, relaunch ──
if pgrep -x NowBar >/dev/null; then
  echo "Quitting the running NowBar..."
  pkill -TERM -x NowBar || true          # NowBar turns SIGTERM into a normal quit
  for _ in $(seq 1 50); do pgrep -x NowBar >/dev/null || break; sleep 0.1; done
  if pgrep -x NowBar >/dev/null; then
    echo "ERROR: NowBar did not quit; not replacing $DEST while it runs." >&2
    exit 1
  fi
fi
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
"$LSREGISTER" -u "$STAGE" 2>/dev/null || true
rm -rf build
"$LSREGISTER" -f "$DEST"
codesign --verify --strict "$DEST"
echo "Installed: $DEST ($(defaults read "$DEST/Contents/Info" CFBundleShortVersionString))"
open "$DEST"
