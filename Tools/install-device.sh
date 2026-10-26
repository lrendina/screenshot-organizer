#!/bin/zsh
# Builds Shotsort, signs it with your free (or paid) Apple team, and installs it on a plugged-in iPhone.
# Usage: Tools/install-device.sh
# Optional: SHOTSORT_TEAM_ID (defaults to the first team signed in to Xcode),
#           SHOTSORT_BUNDLE_ID (defaults to com.lrendina.ScreenshotOrganizer; must be unique to your team),
#           SHOTSORT_DEVICE (UDID; defaults to the first connected iPhone).
set -euo pipefail
root=${0:A:h:h}
cd $root

team=${SHOTSORT_TEAM_ID:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
  | grep -m1 'teamID = ' | sed -E 's/.*teamID = "?([A-Z0-9]+)"?;/\1/')}
[[ -n $team ]] || { echo "No Apple team found. Sign in under Xcode → Settings → Accounts first."; exit 1; }

device=${SHOTSORT_DEVICE:-$(xcrun devicectl list devices 2>/dev/null \
  | awk '/physical/ && /connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')}
[[ -n $device ]] || { echo "No iPhone connected. Plug it in, unlock it, and tap Trust."; exit 1; }

echo "Team $team → device $device"
xcodegen generate -q
mkdir -p build
xcodebuild -project ScreenshotOrganizer.xcodeproj -scheme ScreenshotOrganizer -configuration Release \
  -destination "id=$device" -derivedDataPath build/device DEVELOPMENT_TEAM="$team" \
  -allowProvisioningUpdates build > build/device.log 2>&1 \
  || { grep -E "error:" build/device.log | head -20; echo "Build failed, full log: build/device.log"; exit 1; }

xcrun devicectl device install app --device "$device" \
  build/device/Build/Products/Release-iphoneos/ScreenshotOrganizer.app > /dev/null
echo "Installed. First time only: on the phone, Settings → General → VPN & Device Management → your Apple ID → Trust."
