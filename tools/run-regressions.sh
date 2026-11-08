#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/InterviewCopilot/InterviewCopilot/Models"
BUILD="$(mktemp -d /private/tmp/replysis-regression.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -module-cache-path "$BUILD/cache" \
  "$SRC/AutoTurnDetector.swift" "$SRC/PromptBuilder.swift" "$SRC/AudioSourceRules.swift" "$SRC/PlanFacts.swift" "$SRC/ListeningProblems.swift" "$SRC/RecoveryPolicy.swift" "$SRC/Gzip.swift" "$SRC/TranscriptTyping.swift" "$SRC/VocabTerms.swift" "$SRC/AccountScope.swift" "$SRC/SessionInsights.swift" "$SRC/UplinkGovernor.swift" "$SRC/OcrLayout.swift" "$SRC/AnswerClosers.swift" "$SRC/AnswerLayout.swift" "$SRC/CaptureTarget.swift" "$SRC/Clipboard.swift" "$SRC/ScreenOcr.swift" "$SRC/OAuthLoopback.swift" "$SRC/ClosingMarker.swift" "$SRC/AppIdentity.swift" "$SRC/PresencePing.swift" "$SRC/ClientErrorReporter.swift" "$SRC/ScreeningOptions.swift" "$SRC/MinutesBalance.swift" \
  "$SRC/GlobalHotkey.swift" "$SRC/AppNotifications.swift" \
  "$SRC/AudioInputRoute.swift" "$SRC/StealthSelfTestRules.swift" "$SRC/ListeningMode.swift" "$SRC/ResumeParser.swift" \
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

# Banners are reported to admin by their KIND, never by their title (Windows MAC_CATCHUP 2026-11-07, rounds 17 and 22), and the
# information banners are not reported at all.
if grep -nE 'reportProblem\("alert\." *\+ *ClientErrorReporter\.slug\(title\)' "$VM" >/dev/null; then echo "REPORT CHECK FAILED: a banner is reported by its title"; exit 1; fi
for info in "Nothing heard yet" "Your minutes are almost over" "Invite link copied" "Sign in to invite friends"; do
  if grep -A3 "showAlert(title: \"$info\"" "$VM" | grep -q "reportAs:"; then echo "REPORT CHECK FAILED: the information banner '$info' is reported as a problem"; exit 1; fi
done
grep -q 'reportAs: ListeningProblems.reportKind(kind)' "$VM" || { echo "REPORT CHECK FAILED: speech problems are not reported by kind"; exit 1; }
grep -q 'reportAs: "no-microphone-minor"' "$VM" || { echo "REPORT CHECK FAILED: no microphone is not reported as minor"; exit 1; }
echo "REPORT CHECK: banners are reported by kind, information banners not at all"
