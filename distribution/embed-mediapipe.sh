#!/bin/zsh
# Vendor the pinned arm64/macOS 14 runtime compressed; do not download at build time.
set -euo pipefail
archive="$SRCROOT/Screen/Resources/MediaPipe/libmediapipe_source.so.gz"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
identity='Developer ID Application: So Eun Ahn (43LSH32H5S)'
[[ "$CODE_SIGNING_ALLOWED" == YES && "$CODE_SIGNING_REQUIRED" == YES ]] || {
  print -u2 'The MediaPipe runtime requires the project Developer ID signature.'
  exit 1
}
mkdir -p "$frameworks"
library="$frameworks/libmediapipe_source.so"
gzip -dc "$archive" > "$library"
chmod 755 "$library"
timestamp=(--timestamp=none)
if [[ "$CONFIGURATION" == Release ]]; then timestamp=(--timestamp); fi
codesign --force --sign "$identity" --options runtime "${timestamp[@]}" "$library"
codesign --verify --strict "$library"
