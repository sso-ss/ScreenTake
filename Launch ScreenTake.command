#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h}"
DERIVED_DATA_DIR="$PROJECT_DIR/.build/DerivedData"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Debug/ScreenTake.app"

cd "$PROJECT_DIR"

echo "Building ScreenTake..."
xcodebuild \
  -project "$PROJECT_DIR/Screen.xcodeproj" \
  -scheme Screen \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

echo "Opening ScreenTake..."
open "$APP_PATH"