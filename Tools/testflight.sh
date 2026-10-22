#!/bin/zsh
# Archives Shotsort and uploads it to App Store Connect, from where it goes to TestFlight.
#
# Needs (see README → TestFlight):
#   SHOTSORT_TEAM_ID   your 10-character Apple Developer Team ID
#   ASC_KEY_ID         App Store Connect API key ID
#   ASC_ISSUER_ID      App Store Connect API issuer ID
#   ASC_KEY_PATH       path to the AuthKey_<id>.p8 file
set -euo pipefail
root=${0:A:h:h}
cd $root
: ${SHOTSORT_TEAM_ID:?set SHOTSORT_TEAM_ID} ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID} ${ASC_KEY_PATH:?set ASC_KEY_PATH}

build_number=$(date +%Y%m%d%H%M)
auth=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

xcodegen generate -q
rm -rf build/Shotsort.xcarchive build/export

xcodebuild archive \
  -project ScreenshotOrganizer.xcodeproj -scheme ScreenshotOrganizer -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Shotsort.xcarchive \
  DEVELOPMENT_TEAM="$SHOTSORT_TEAM_ID" CURRENT_PROJECT_VERSION="$build_number" \
  "${auth[@]}" > build/archive.log 2>&1 || { grep -E "error:" build/archive.log | head -20; echo "archive failed, full log: build/archive.log"; exit 1; }

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$SHOTSORT_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>testFlightInternalTestingOnly</key><false/>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath build/Shotsort.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export "${auth[@]}"

echo "Uploaded build $build_number. It shows up in App Store Connect → TestFlight after processing (usually 5–15 min)."
