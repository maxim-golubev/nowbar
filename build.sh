#!/bin/bash
# Build NowBar and install it as the one copy on this Mac: /Applications/NowBar.app.
#
#   ./build.sh               build, install to /Applications, relaunch
#   ./build.sh --no-install  build only; leaves the bundle in build/NowBar.app
#   ./build.sh --release     build/release/NowBar-<version>.zip and its SHA-256; installs nothing
#
# Only /Applications/NowBar.app may stay on the Mac: Spotlight lists every other copy
# beside it, so a staging bundle is unregistered from LaunchServices and deleted once it
# has been installed or zipped.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.3.0"
BUILD_NUMBER="3"
DEST="/Applications/NowBar.app"
STAGE="build/NowBar.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
MODE="${1:-install}"
case "$MODE" in install|--no-install|--release) ;; *) echo "usage: $0 [--no-install|--release]" >&2; exit 2 ;; esac

# Remove a staging bundle the way the one-copy rule needs: out of LaunchServices, then off disk.
drop_stage() { "$LSREGISTER" -u "$STAGE" 2>/dev/null || true; rm -rf "$STAGE"; }

# ── Build into a clean staging bundle ──
drop_stage
rm -rf build
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
echo "Compiling NowBar $VERSION..."
swiftc -O -target arm64-apple-macos13.0 Sources/*.swift -o "$STAGE/Contents/MacOS/NowBar" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement
cp Resources/NowBar.icns "$STAGE/Contents/Resources/NowBar.icns"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NowBar</string>
  <key>CFBundleDisplayName</key><string>NowBar</string>
  <key>CFBundleIdentifier</key><string>com.nowbar.app</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>NowBar</string>
  <key>CFBundleIconFile</key><string>NowBar</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Maxim Golubev. MIT License.</string>
  <key>NSAppleEventsUsageDescription</key><string>NowBar asks Spotify for the cover image when macOS doesn't provide one.</string>
</dict>
</plist>
PLIST
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null

# ── Sign ──
# With the self-signed "NowBar Dev" identity when this Mac has it, so the Accessibility
# grant (which macOS ties to the signature) survives rebuilds; ad hoc otherwise.
xattr -cr "$STAGE" 2>/dev/null || true   # codesign refuses bundles carrying Finder/iCloud attributes
if security find-identity -p codesigning 2>/dev/null | grep -q "NowBar Dev"; then
  echo "Signing with 'NowBar Dev'..."
  codesign --force --sign "NowBar Dev" "$STAGE"
else
  echo "No 'NowBar Dev' identity: signing ad hoc (Accessibility must be granted again after each build)." >&2
  codesign --force --sign - "$STAGE"
fi
codesign --verify --strict "$STAGE"

case "$MODE" in
  --no-install)
    echo "Built: $(pwd)/$STAGE"
    exit 0 ;;
  --release)
    mkdir -p build/release
    ZIP="build/release/NowBar-$VERSION.zip"
    ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"   # no __MACOSX clutter; the signature lives in the bundle
    drop_stage
    shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
    echo "Release: $(pwd)/$ZIP"
    exit 0 ;;
esac

# ── Install: quit the running copy, replace /Applications/NowBar.app, relaunch ──
if pgrep -x NowBar >/dev/null; then
  echo "Quitting the running NowBar..."
  pkill -TERM -x NowBar || true          # NowBar turns SIGTERM into a normal quit
  for _ in $(seq 1 50); do pgrep -x NowBar >/dev/null || break; sleep 0.1; done
  if pgrep -x NowBar >/dev/null; then
    echo "NowBar did not quit; not replacing $DEST while it runs." >&2
    exit 1
  fi
fi
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
drop_stage
rm -rf build
"$LSREGISTER" -f "$DEST"
codesign --verify --strict "$DEST"
echo "Installed: $DEST ($VERSION)"
open "$DEST"
