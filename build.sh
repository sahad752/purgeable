#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Purgeable.app"

pkill -f "Purgeable.app/Contents/MacOS/Purgeable" 2>/dev/null || true
pkill -f "Cache Cleaner.app/Contents/MacOS/CacheCleaner" 2>/dev/null || true
sleep 0.5

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

clang++ -std=c++17 -ObjC++ -fobjc-arc -O2 \
  -framework Cocoa \
  -framework UserNotifications \
  -o "$APP/Contents/MacOS/Purgeable" \
  "$DIR/main.mm"

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" 2>/dev/null || true

# Nudge Launch Services / Finder to pick up the fresh bundle + icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo "Built and installed: $APP"
