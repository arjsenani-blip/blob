#!/bin/bash
# Dev helper: rebuilds Blob whenever .build-request appears, writing the result to build.log.
# Start it once in Terminal:  cd ~/"Arjuns Brain" && ./scripts/dev_watch.sh
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v xcodegen >/dev/null; then echo "Installing xcodegen…"; brew install xcodegen; fi
echo "Watching for build requests (leave this window open, Ctrl+C to stop)…"
while true; do
  if [ -f .build-request ]; then
    what=$(cat .build-request); rm -f .build-request
    echo "[$(date +%H:%M:%S)] building: ${what:-mac}"
    {
      echo "BUILD START $(date)"
      xcodegen generate --quiet 2>&1
      case "$what" in
        ios) xcodebuild -project ArjunsBrain.xcodeproj -scheme ArjunsBrain-iOS -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath build/dev-ios build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)|\*\*" ;;
        test) (cd Packages/BrainCore && swift test 2>&1 | tail -40) ;;
        run) xcodebuild -project ArjunsBrain.xcodeproj -scheme ArjunsBrain-macOS -configuration Debug -derivedDataPath build/dev build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\*";
             pkill -x ArjunsBrain; sleep 1; open build/dev/Build/Products/Debug/ArjunsBrain.app ;;
        snap) app=build/dev/Build/Products/Debug/ArjunsBrain.app/Contents/MacOS/ArjunsBrain
             rm -rf build/snaps; mkdir -p build/snaps
             "$app" -dataDir "$PWD/build/snapdata" -snapshot "$PWD/build/snaps/shot" -snapshotOnlyWindow YES -snapshotCheckIn YES 2>&1 | tail -5; ls build/snaps ;;
        *) xcodebuild -project ArjunsBrain.xcodeproj -scheme ArjunsBrain-macOS -configuration Debug -derivedDataPath build/dev build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\*" ;;
      esac
      echo "BUILD END $(date)"
    } > build.log 2>&1
    tail -1 build.log; grep -c "error:" build.log | sed 's/^/errors: /'
  fi
  sleep 2
done
