#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/InterviewCopilot/InterviewCopilot/Models"
BUILD="$(mktemp -d /private/tmp/replysis-regression.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -module-cache-path "$BUILD/cache" \
  "$SRC/AutoTurnDetector.swift" "$SRC/PromptBuilder.swift" "$SRC/AudioSourceRules.swift" "$SRC/PlanFacts.swift" "$SRC/ListeningProblems.swift" "$SRC/RecoveryPolicy.swift" "$SRC/Gzip.swift" "$SRC/TranscriptTyping.swift" "$SRC/VocabTerms.swift" "$SRC/AccountScope.swift" \
  "$SRC/GlobalHotkey.swift" "$SRC/AppNotifications.swift" \
  "$SRC/AudioInputRoute.swift" "$SRC/ListeningMode.swift" "$SRC/ResumeParser.swift" \
  "$ROOT/tools/regression/main.swift" -o "$BUILD/regressions"
"$BUILD/regressions"
