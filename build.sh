#!/bin/bash
# Builds ShotShelf.app into ./dist
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/ShotShelf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ShotShelf "$APP/Contents/MacOS/ShotShelf"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --sign - --identifier com.pax.shotshelf "$APP" >/dev/null 2>&1 || true

echo "built: $(pwd)/$APP"
