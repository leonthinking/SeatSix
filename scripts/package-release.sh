#!/bin/bash
# Package the full player and its corresponding decoder source together.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid bundle version' >&2; exit 2; }
if [[ $# -gt 1 || ($# -eq 1 && "$1" != "v$version") ]]; then
  echo "Expected release tag v$version" >&2
  exit 2
fi

identity=${SEATSIX_DEVELOPER_ID:-}
profile=${SEATSIX_NOTARY_PROFILE:-}
if [[ -n "$identity" && -z "$profile" || -z "$identity" && -n "$profile" ]]; then
  echo 'For notarization set both SEATSIX_DEVELOPER_ID and SEATSIX_NOTARY_PROFILE.' >&2
  exit 2
fi

output="$PWD/build/releases"
mkdir -p "$output"
stage=$(mktemp -d "$output/.stage.XXXXXX")
assets="$stage/assets"
name="SeatSix-$version-universal.dmg"
source_name="SeatSix-$version-decoder-sources.tar.gz"
cleanup() {
  rm -rf "$stage/volume" "$stage/sources"
  rm -f "$stage/notarize.zip"
  # An atomic exchange leaves the old release here. Preserve extra user files.
  if [[ -d "$assets" ]]; then
    rm -f "$assets/$name" "$assets/$name.sha256" "$assets/$source_name" "$assets/$source_name.sha256"
    rmdir "$assets" || return 1
  fi
  rmdir "$stage"
}
trap cleanup EXIT
mkdir "$stage/volume" "$assets"
sdk="${SEATSIX_DECODER_PREFIX:-$PWD/.runtime/decoder-sdk}"
python3 scripts/prepare-decoder.py "$sdk"
python3 scripts/decoder-sources.py "$stage/sources"
mv "$stage/sources/decoder-sources.tar.gz" "$assets/$source_name"
SEATSIX_DECODER_PREFIX="$sdk" SEATSIX_DECODER_NOTICES="$stage/sources/ThirdPartyNotices" \
  SEATSIX_PUBLIC_OUTPUT_DIR="$stage/volume" ./scripts/build-app.sh release --full
app="$stage/volume/SeatSix.app"
python3 scripts/bundle-media-libraries.py --verify-full-app "$app"
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
ln -s /Applications "$stage/volume/Applications"

if [[ -n "$identity" ]]; then
  ditto -c -k --keepParent "$app" "$stage/notarize.zip"
  xcrun notarytool submit "$stage/notarize.zip" --keychain-profile "$profile" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute "$app"
fi

hdiutil create -quiet -format UDZO -fs HFS+ -volname "SeatSix" -srcfolder "$stage/volume" "$assets/$name"
if [[ -n "$identity" ]]; then
  codesign --force --timestamp --sign "$identity" "$assets/$name"
  xcrun notarytool submit "$assets/$name" --keychain-profile "$profile" --wait
  xcrun stapler staple "$assets/$name"
  xcrun stapler validate "$assets/$name"
fi
hdiutil verify -quiet "$assets/$name"
(cd "$assets" && shasum -a 256 "$name" > "$name.sha256" && shasum -a 256 "$source_name" > "$source_name.sha256")
python3 scripts/publish-release.py "$assets" "$output/v$version"
printf 'Installer: %s/v%s/%s\nDecoder source: %s/v%s/%s\n' "$output" "$version" "$name" "$output" "$version" "$source_name"
