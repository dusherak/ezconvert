#!/bin/zsh
# Builds ezconvert.app next to this script.
# Usage: ./build.sh             build ezconvert.app (Apple Silicon + Intel)
#        ./build.sh --install   also copy it to /Applications and launch it
#        ./build.sh --release   also write dist/ezconvert-<version>-macos.zip for a GitHub release
set -euo pipefail
cd "${0:A:h}"

VERSION=1.0.0

# Build and sign in a temp folder: iCloud-synced Desktop folders keep re-adding
# Finder metadata, which codesign rejects ("resource fork ... detritus not allowed").
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
APP=ezconvert.app
mkdir -p "$BUILD/$APP/Contents/MacOS" "$BUILD/$APP/Contents/Resources"

# One binary that runs on both Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  # FoundationModels (on-device AI) only exists on macOS 26+, so link it weakly to keep launching on 14/15.
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 -Xlinker -weak_framework -Xlinker FoundationModels \
    Sources/*.swift -o "$BUILD/ezconvert-$arch"
done
lipo -create "$BUILD/ezconvert-arm64" "$BUILD/ezconvert-x86_64" -output "$BUILD/$APP/Contents/MacOS/ezconvert"

cat > "$BUILD/$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ezconvert</string>
  <key>CFBundleDisplayName</key><string>ezconvert</string>
  <key>CFBundleIdentifier</key><string>local.ezconvert</string>
  <key>CFBundleExecutable</key><string>ezconvert</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSAppleEventsUsageDescription</key><string>ezconvert opens Keynote files with Keynote to read their slides.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUILD/$APP"

rm -rf "$APP"
ditto --norsrc --noextattr "$BUILD/$APP" "$APP"
echo "Built $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/ezconvert"))"

case "${1:-}" in
  --install)
    pkill -x ezconvert || true
    rm -rf "/Applications/$APP"
    ditto --norsrc --noextattr "$BUILD/$APP" "/Applications/$APP"
    codesign --verify "/Applications/$APP"
    open "/Applications/$APP"
    echo "Installed to /Applications and launched"
    ;;
  --release)
    mkdir -p dist
    ZIP="dist/ezconvert-$VERSION-macos.zip"
    rm -f "$ZIP"
    # ditto keeps the bundle and its signature intact (plain zip can break them).
    ditto -c -k --norsrc --noextattr --keepParent "$BUILD/$APP" "$ZIP"
    echo "Release zip: $PWD/$ZIP ($(du -h "$ZIP" | cut -f1))"
    ;;
esac
