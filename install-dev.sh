#!/bin/bash
# Build and install the dev app somewhere macOS will REMEMBER its permissions.
#
# TCC identifies an app by its code signature. An ad-hoc signature (the default for a
# local build) is a fresh identity every time it is re-signed, so Screen Recording and
# Accessibility grants could never stick: each rebuild asked again, the entry already in
# Settings belonged to a binary that no longer existed, and pressing Allow did nothing
# visible. Signing with the real Developer ID gives every build the same identity as the
# released app, so a grant survives rebuilds — and it exercises the identity users
# actually get rather than one only this machine ever sees.
#
# The stable PATH matters for the same reason as the stable signature: a build living in
# a derived-data folder moves every time.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DD=/private/tmp/claude-501/p11
DEST="$HOME/Desktop/Replysis-dev.app"
IDENTITY="Developer ID Application: bindu alekhya (687K9LK6N4)"

xcodebuild build -project "$HERE/InterviewCopilot/InterviewCopilot.xcodeproj" \
  -scheme InterviewCopilot -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  | grep -E "^\*\* |error:" || true

pkill -9 -f "Replysis-dev.app/Contents/MacOS" 2>/dev/null || true
pkill -9 -f speechmatics_engine 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$DD/Build/Products/Debug/InterviewCopilot.app" "$DEST"
codesign --force --deep --options runtime \
  --entitlements "$HERE/InterviewCopilot/InterviewCopilot/InterviewCopilot.entitlements" \
  --sign "$IDENTITY" "$DEST"
codesign --verify --strict "$DEST"
echo "installed and signed: $DEST"
codesign -dv --verbose=2 "$DEST" 2>&1 | grep -E "TeamIdentifier|Authority=Developer ID"
open "$DEST"
