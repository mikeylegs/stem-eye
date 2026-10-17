#!/bin/bash
# Stem Eye: use the newest Xcode on the runner (App Store Connect takes builds from the current SDK only: Xcode 26+ in 2026).
set -euo pipefail
best=""; bestv="0"
for x in /Applications/Xcode*.app; do
  [ -d "$x/Contents/Developer" ] || continue
  case "$x" in *beta*|*Beta*) continue;; esac
  v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$x/Contents/Info.plist" 2>/dev/null || echo 0)
  if [ "$(printf '%s\n%s\n' "$bestv" "$v" | sort -V | tail -1)" = "$v" ] && [ "$v" != "$bestv" ]; then best="$x"; bestv="$v"; fi
done
[ -n "$best" ] || { echo "no Xcode found"; exit 1; }
echo "Xcode $bestv at $best"
sudo xcode-select -s "$best/Contents/Developer"
xcodebuild -version
# Xcode 15+ can come without its iOS platform: fetch it when the device SDK is missing
if ! xcodebuild -showsdks 2>/dev/null | grep -q "iphoneos"; then
  echo "the iOS platform is not installed in this Xcode: downloading it"
  sudo xcodebuild -downloadPlatform iOS || xcodebuild -downloadPlatform iOS
fi
xcodebuild -showsdks | grep -E "iphoneos|macosx" || true
major=${bestv%%.*}
if [ "${NEED_XCODE_26:-0}" = "1" ] && [ "$major" -lt 26 ]; then
  echo "::error::App Store Connect needs a build from Xcode 26 or later; this runner has $bestv. Change runs-on to a newer macOS image."
  exit 1
fi
