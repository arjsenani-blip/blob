#!/bin/zsh
# Builds the Mac app and packages it as "Blob.dmg" (drag-to-Applications installer).
# Usage: ./scripts/build_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
(cd Packages/BrainCore && swift test >/dev/null) && echo "✓ core tests pass"

LOG=build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project ArjunsBrain.xcodeproj -scheme ArjunsBrain-macOS -configuration Release \
  -derivedDataPath build/dd build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u
  echo "✗ Build failed — no DMG made (full log: $LOG)"
  exit 1
fi

APP="build/dd/Build/Products/Release/ArjunsBrain.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

STAGE="build/dmg-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Blob.app"
ln -s /Applications "$STAGE/Applications"

DMG="build/Blob.dmg"
rm -f "$DMG"
hdiutil create -volname "Blob" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
