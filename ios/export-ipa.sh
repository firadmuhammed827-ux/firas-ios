#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE_PATH="$SCRIPT_DIR/build/FirasAI.xcarchive"
EXPORT_PATH="$SCRIPT_DIR/build/export"

mkdir -p "$SCRIPT_DIR/build"

xcodebuild \
  -project "$SCRIPT_DIR/FirasAI.xcodeproj" \
  -scheme FirasAI \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates

echo "IPA export finished in: $EXPORT_PATH"
