#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
: "${MURMUR_NOTARY_PROFILE:?Set MURMUR_NOTARY_PROFILE to a notarytool Keychain profile name}"
: "${MURMUR_DEVELOPMENT_TEAM:?Set MURMUR_DEVELOPMENT_TEAM to your Apple Developer team ID}"
release_root="build/releases/$(date +%Y%m%d-%H%M%S)"
archive_path="$release_root/Murmur.xcarchive"
export_path="$release_root/export"
mkdir -p "$release_root"
export_options="$release_root/ExportOptions.plist"
cp Config/ExportOptions.plist "$export_options"
/usr/libexec/PlistBuddy -c "Add :teamID string $MURMUR_DEVELOPMENT_TEAM" "$export_options"

xcodegen generate
xcodebuild \
  -project Murmur.xcodeproj \
  -scheme Murmur \
  -configuration Release \
  -archivePath "$archive_path" \
  "DEVELOPMENT_TEAM=$MURMUR_DEVELOPMENT_TEAM" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options"

ditto -c -k --keepParent "$export_path/Murmur.app" "$release_root/Murmur-notarization.zip"
xcrun notarytool submit "$release_root/Murmur-notarization.zip" \
  --keychain-profile "$MURMUR_NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$export_path/Murmur.app"
xcrun stapler validate "$export_path/Murmur.app"
spctl --assess --type execute --verbose=4 "$export_path/Murmur.app"

ditto -c -k --keepParent "$export_path/Murmur.app" build/Murmur.zip
print "Notarized release: $PWD/build/Murmur.zip"
