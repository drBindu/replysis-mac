#!/bin/bash
# Rebuild the SystemAudioCapture helper (Core Audio process-tap edition) and
# install it into the app's Resources. Run from this directory.
#
#   ./build.sh
#
# The helper captures system output audio via Core Audio taps (macOS 14.4+),
# which — unlike ScreenCaptureKit — does NOT trigger the purple "Currently
# Sharing" menu-bar indicator. It writes 16 kHz mono s16le PCM to stdout.
#
# Requirements to actually capture audio (not just silence):
#   • App Info.plist must contain NSAudioCaptureUsageDescription
#     (set via INFOPLIST_KEY_NSAudioCaptureUsageDescription in the pbxproj).
#   • The responsible process (the app) must be code-signed. The helper runs
#     disclaimed under the app, so ad-hoc signing of the helper is fine.
set -e
cd "$(dirname "$0")"

swiftc -O -target arm64-apple-macosx14.4 main.swift -o SystemAudioCapture \
  -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework Foundation

codesign --force --sign - --timestamp=none SystemAudioCapture

DEST="../InterviewCopilot/InterviewCopilot/Resources/SystemAudioCapture"
cp SystemAudioCapture "$DEST"
chmod +x "$DEST"
echo "Installed → $DEST"
