#!/bin/zsh
# SPM embeds Sparkle with ad hoc helper signatures. Sign inside out before distribution.
set -euo pipefail
app_path=${1:?Usage: sign-sparkle.sh /path/to/ScreenTake.app}
identity='Developer ID Application: So Eun Ahn (43LSH32H5S)'
framework="$app_path/Contents/Frameworks/Sparkle.framework"
[[ -d "$framework" ]] || { print -u2 'Missing Sparkle framework'; exit 1; }
sign() {
  codesign --force --sign "$identity" --options runtime --timestamp \
    --preserve-metadata=identifier,entitlements --generate-entitlement-der "$1"
}
for helper in "$framework/Versions/Current/XPCServices/"*.xpc; do
  sign "$helper"
done
sign "$framework/Versions/Current/Autoupdate"
sign "$framework/Versions/Current/Updater.app"
sign "$framework"
sign "$app_path"
codesign --verify --deep --strict "$app_path"
