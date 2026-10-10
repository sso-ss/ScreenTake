#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
app_path=${1:-}
output_path=${2:-}

if [[ -z "$app_path" || ! -d "$app_path" || "$app_path" != *.app ]]; then
  print -u2 "Usage: $0 /path/to/ScreenTake.app [output.dmg]"
  exit 1
fi

if ! codesign --verify --deep --strict "$app_path"; then
  print -u2 "The app signature is invalid. Build and sign ScreenTake before creating the DMG."
  exit 1
fi

signing_authority=$(codesign -dv --verbose=4 "$app_path" 2>&1 | awk -F= '/^Authority=/ && !found++ {print $2}')
allow_local_signing=${SCREENTAKE_ALLOW_LOCAL_SIGNING:-0}
notary_profile=${SCREENTAKE_NOTARY_PROFILE:-}

if [[ "$signing_authority" != "Developer ID Application:"* ]]; then
  if [[ "$allow_local_signing" != 1 ]]; then
    print -u2 "Public downloads must be signed with an Apple Developer ID Application certificate."
    print -u2 "Current signing authority: ${signing_authority:-none}"
    print -u2 "For a private local test DMG only, set SCREENTAKE_ALLOW_LOCAL_SIGNING=1."
    exit 1
  fi
elif [[ -z "$notary_profile" ]]; then
  print -u2 "Set SCREENTAKE_NOTARY_PROFILE to a notarytool keychain profile for public distribution."
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
output_path=${output_path:-"$PWD/ScreenTake-${version}-build${build}.dmg"}
output_path=${output_path:A}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/screentake-dmg.XXXXXX")
read_write_image="$work_dir/ScreenTake-rw.dmg"
volume_name=${SCREENTAKE_DMG_VOLUME_NAME:-"Install ScreenTake"}
mount_path="/Volumes/$volume_name"
mounted=0

cleanup() {
  if (( mounted )); then
    hdiutil detach "$mount_path" -quiet -force || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

if [[ -e "$mount_path" ]]; then
  print -u2 "$mount_path is already in use. Eject it before creating the DMG."
  exit 1
fi
app_size_mb=$(du -sm "$app_path" | awk '{ print $1 }')
image_size_mb=$(( app_size_mb + 40 ))

hdiutil create -quiet -size "${image_size_mb}m" -fs HFS+ \
  -volname "$volume_name" "$read_write_image"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$read_write_image"
mounted=1

ditto "$app_path" "$mount_path/ScreenTake.app"
ln -s /Applications "$mount_path/Applications"
mkdir "$mount_path/.background"
/usr/bin/swift "$script_dir/DMGBackground.swift" "$mount_path/.background/background.png"
/usr/bin/SetFile -a V "$mount_path/.background"

osascript <<APPLESCRIPT
set backgroundImage to POSIX file "$mount_path/.background/background.png" as alias
tell application "Finder"
  set targetDisk to disk "$volume_name"
  open targetDisk
  set targetWindow to container window of targetDisk
  set current view of targetWindow to icon view
  set toolbar visible of targetWindow to false
  set statusbar visible of targetWindow to false
  set bounds of targetWindow to {220, 180, 820, 520}
  set viewOptions to icon view options of targetWindow
  set icon size of viewOptions to 128
  set text size of viewOptions to 14
  set background picture of viewOptions to backgroundImage
  set position of item "ScreenTake.app" of targetDisk to {165, 205}
  set position of item "Applications" of targetDisk to {435, 205}
  update targetDisk
  delay 2
  close targetWindow
end tell
APPLESCRIPT

sync
hdiutil detach "$mount_path" -quiet
mounted=0

mkdir -p "${output_path:h}"
rm -f "$output_path"
hdiutil convert -quiet "$read_write_image" -format UDZO -imagekey zlib-level=9 \
  -o "$output_path"

if [[ "$signing_authority" == "Developer ID Application:"* ]]; then
  codesign --force --timestamp --sign "$signing_authority" "$output_path"
  xcrun notarytool submit "$output_path" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$output_path"
  xcrun stapler validate "$output_path"
fi

print "Created $output_path"
