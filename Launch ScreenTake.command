#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h}"
DERIVED_DATA_DIR="$PROJECT_DIR/.build/DerivedData"
BUILD_CONFIGURATION="${SCREENTAKE_BUILD_CONFIGURATION:-Debug}"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/$BUILD_CONFIGURATION/ScreenTake.app"
SIGNING_FLAGS=()
if [[ "$BUILD_CONFIGURATION" == Release ]]; then
  SIGNING_FLAGS=(CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

cd "$PROJECT_DIR"

echo "Building ScreenTake..."
xcodebuild \
  -project "$PROJECT_DIR/Screen.xcodeproj" \
  -scheme Screen \
  -configuration "$BUILD_CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGN_IDENTITY="Developer ID Application: So Eun Ahn (43LSH32H5S)" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  "${SIGNING_FLAGS[@]}" \
  build

echo "Opening ScreenTake..."
open "$APP_PATH"
