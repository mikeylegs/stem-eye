#!/bin/bash
# Stem Eye: compile the iPad app + its broadcast extension for a real iPad, without signing (no Apple account needed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-logs
xcodebuild -project StemEye.xcodeproj -scheme StemEye -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > build-logs/compile.log 2>&1 || { grep -E "error:" build-logs/compile.log | head -60 || true; tail -40 build-logs/compile.log; exit 1; }
grep -cE "warning:" build-logs/compile.log | sed 's/^/warnings: /' || true
grep -E "warning:" build-logs/compile.log | sort -u | head -30 || true
APP=$(find build/dd/Build/Products -name "StemEye.app" -maxdepth 3 | head -1)
echo "built: $APP"
ls -la "$APP" "$APP/PlugIns" || true
/usr/libexec/PlistBuddy -c "Print :NSExtension" "$APP/PlugIns/StemEyeBroadcast.appex/Info.plist"
