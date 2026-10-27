#!/bin/zsh
# Builds Blob (Release) and installs it into /Applications, replacing the old one, then opens it.
# Usage: ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "› Building Blob…"
xcodegen generate >/dev/null
LOG=build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project ArjunsBrain.xcodeproj -scheme ArjunsBrain-macOS -configuration Release \
  -derivedDataPath build/dd build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u
  echo "✗ Build failed — nothing installed (full log: $LOG)"
  exit 1
fi
APP="build/dd/Build/Products/Release/ArjunsBrain.app"

echo "› Quitting the old Blob…"
pkill -x ArjunsBrain 2>/dev/null || true
sleep 1

echo "› Installing to /Applications/Blob.app…"
rm -rf /Applications/Blob.app
ditto "$APP" /Applications/Blob.app
xattr -dr com.apple.quarantine /Applications/Blob.app 2>/dev/null || true

open /Applications/Blob.app
echo "✓ Blob 2.0 installed and opened."
