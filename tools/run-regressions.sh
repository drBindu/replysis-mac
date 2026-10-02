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

# Customer-visible text follows the owner's copy rules: no dashes and no middle dots in anything a
# person reads (Views, and the messages the view model puts on screen). Comments and log lines are
# not customer text and are not checked.
VIEWS="$ROOT/InterviewCopilot/InterviewCopilot/Views"
VM="$ROOT/InterviewCopilot/InterviewCopilot/ViewModels/MainViewModel.swift"
BAD=$( { grep -rnE '"[^"]*(—|–|·)[^"]*"' "$VIEWS" --include='*.swift' | grep -vE '^\S+:[0-9]+:\s*//|///|dlog\(|tag:' ;
         grep -nE '(aiAnswer|aiAnswerHint|thinkingText|listeningNotice|showListeningNotice|showAlert|errorMsg)[^"]*"[^"]*(—|–|·)[^"]*"' "$VM" | grep -v 'dlog(' ; } || true)
if [ -n "$BAD" ]; then echo "COPY CHECK FAILED: dashes or middle dots in customer-visible text:"; echo "$BAD" | cut -c1-200; exit 1; fi
echo "COPY CHECK: no dashes or middle dots in customer-visible text"
