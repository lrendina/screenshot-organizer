#!/bin/zsh
# Builds an unsigned Shotsort.ipa for sideloading tools (AltStore, SideStore, Sideloadly),
# which re-sign it with the installing person's free Apple ID.
set -euo pipefail
root=${0:A:h:h}
cd $root
xcodegen generate -q
xcodebuild archive -project ScreenshotOrganizer.xcodeproj -scheme ScreenshotOrganizer -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/unsigned.xcarchive \
  CODE_SIGNING_ALLOWED=NO > build/ipa.log 2>&1 || { grep error: build/ipa.log | head; exit 1; }
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R build/unsigned.xcarchive/Products/Applications/ScreenshotOrganizer.app build/ipa/Payload/
(cd build/ipa && zip -qr ../Shotsort.ipa Payload)
echo "build/Shotsort.ipa ($(du -h build/Shotsort.ipa | cut -f1))"
