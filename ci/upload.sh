#!/bin/bash
# Stem Eye: sign the app with Apple's cloud-managed certificate and send it to App Store Connect (TestFlight).
# The recipe that works on GitHub's Mac without a Mac of your own: archive ad-hoc signed (keeps the entitlements),
# then -exportArchive signs for the App Store with the API key (-allowProvisioningUpdates: Xcode makes the profiles).
# Needs (repository settings): variable TEAM_ID; secrets ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (the .p8 file's text).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-logs
miss=""
[ -n "${TEAM_ID:-}" ] || miss="$miss TEAM_ID(variable)"
[ -n "${ASC_KEY_ID:-}" ] || miss="$miss ASC_KEY_ID(secret)"
[ -n "${ASC_ISSUER_ID:-}" ] || miss="$miss ASC_ISSUER_ID(secret)"
[ -n "${ASC_KEY_P8:-}" ] || miss="$miss ASC_KEY_P8(secret)"
if [ -n "$miss" ]; then echo "::error::Missing in the repository settings (Settings > Secrets and variables > Actions):$miss"; exit 1; fi

KEY="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
if printf '%s' "$ASC_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then printf '%s\n' "$ASC_KEY_P8" > "$KEY"; else printf '%s' "$ASC_KEY_P8" | base64 --decode > "$KEY"; fi
trap 'rm -f "$KEY"' EXIT
export ASC_KEY_PATH="$KEY"
APP_ID="${BUNDLE_PREFIX}.djayreader"

echo "== 1. app ids (registered once)"
python3 ci/asc.py ids "$APP_ID" "djay reader" "$APP_ID.broadcast" "djay reader broadcast"
echo "== 2. the App Store Connect app"
python3 ci/asc.py app "$APP_ID"

echo "== 3. archive (build $BUILD_NUMBER)"
ARCHIVE="$RUNNER_TEMP/StemEye.xcarchive"
APPP="$ARCHIVE/Products/Applications/StemEye.app"
APPX="$APPP/PlugIns/StemEyeBroadcast.appex"
ents(){ codesign -d --entitlements - --xml "$1" 2>/dev/null || codesign -d --entitlements :- "$1" 2>/dev/null; }
has_group(){ ents "$1" | grep -q 'djayreader.shared'; }
# ad-hoc signed: keeps the entitlements (the keychain group the app + its broadcast share) for the App Store signing at export
if ! xcodebuild -project StemEye.xcodeproj -scheme StemEye -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  AD_HOC_CODE_SIGNING_ALLOWED=YES PROVISIONING_PROFILE_SPECIFIER= archive > build-logs/archive.log 2>&1; then
  echo "ad-hoc archive failed -- trying unsigned + signing ad-hoc by hand"
  grep -E "error:" build-logs/archive.log | head -20 || true
  rm -rf "$ARCHIVE"
  xcodebuild -project StemEye.xcodeproj -scheme StemEye -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGNING_ALLOWED=NO archive > build-logs/archive-unsigned.log 2>&1 \
    || { grep -E "error:" build-logs/archive-unsigned.log | head -40 || true; tail -40 build-logs/archive-unsigned.log; exit 1; }
  codesign -f -s - --entitlements Broadcast/Broadcast.entitlements "$APPX"
  codesign -f -s - --entitlements StemEye/StemEye.entitlements "$APPP"
fi
for p in "$APPP" "$APPX"; do
  [ -d "$p" ] || { echo "::error::the archive has no $(basename "$p")"; ls -R "$ARCHIVE/Products" | head -40; exit 1; }
  has_group "$p" || { echo "::error::$(basename "$p") lost the keychain group (settings would not reach the broadcast)"; ents "$p" || true; exit 1; }
done
echo "archived: $ARCHIVE (the app + the broadcast carry the shared keychain group)"

echo "== 4. sign for the App Store + upload"
OPTS="$RUNNER_TEMP/ExportOptions.plist"
cp ExportOptions.plist "$OPTS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$OPTS"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTS" -exportPath "$RUNNER_TEMP/export" \
  -allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  > build-logs/export.log 2>&1 || { grep -E "error:|Error" build-logs/export.log | head -40 || true; tail -60 build-logs/export.log; exit 1; }
tail -20 build-logs/export.log
echo "Sent build $BUILD_NUMBER of $APP_ID to App Store Connect. TestFlight shows it after Apple's processing (usually 5-30 minutes)."
