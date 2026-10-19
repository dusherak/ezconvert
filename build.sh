#!/bin/zsh
# Builds ezconvert.app next to this script. Usage: ./build.sh [--install]
set -euo pipefail
cd "${0:A:h}"

# Build and sign in a temp folder: iCloud-synced Desktop folders keep re-adding
# Finder metadata, which codesign rejects ("resource fork ... detritus not allowed").
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
APP=ezconvert.app
mkdir -p "$BUILD/$APP/Contents/MacOS" "$BUILD/$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$BUILD/$APP/Contents/MacOS/ezconvert"

cat > "$BUILD/$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ezconvert</string>
  <key>CFBundleDisplayName</key><string>ezconvert</string>
  <key>CFBundleIdentifier</key><string>local.ezconvert</string>
  <key>CFBundleExecutable</key><string>ezconvert</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUILD/$APP"

rm -rf "$APP"
ditto --norsrc --noextattr "$BUILD/$APP" "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ezconvert || true
  rm -rf "/Applications/$APP"
  ditto --norsrc --noextattr "$BUILD/$APP" "/Applications/$APP"
  codesign --verify "/Applications/$APP"
  open "/Applications/$APP"
  echo "Installed to /Applications and launched"
fi
