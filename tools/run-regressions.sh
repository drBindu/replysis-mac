#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/InterviewCopilot/InterviewCopilot/Models"
BUILD="$(mktemp -d /private/tmp/replysis-regression.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -module-cache-path "$BUILD/cache" \
  "$SRC/AutoTurnDetector.swift" "$SRC/PromptBuilder.swift" "$SRC/AudioSourceRules.swift" "$SRC/PlanFacts.swift" "$SRC/ListeningProblems.swift" "$SRC/RecoveryPolicy.swift" "$SRC/Gzip.swift" "$SRC/TranscriptTyping.swift" "$SRC/VocabTerms.swift" "$SRC/AccountScope.swift" "$SRC/SessionInsights.swift" "$SRC/UplinkGovernor.swift" "$SRC/OcrLayout.swift" "$SRC/AnswerClosers.swift" "$SRC/AnswerLayout.swift" "$SRC/CaptureTarget.swift" "$SRC/Clipboard.swift" "$SRC/ScreenOcr.swift" "$SRC/OAuthLoopback.swift" "$SRC/ClosingMarker.swift" "$SRC/AppIdentity.swift" "$SRC/PresencePing.swift" "$SRC/ClientErrorReporter.swift" "$SRC/ScreeningOptions.swift" "$SRC/MinutesBalance.swift" \
  "$SRC/GlobalHotkey.swift" "$SRC/AppNotifications.swift" \
  "$SRC/AudioInputRoute.swift" "$SRC/StealthSelfTestRules.swift" "$SRC/ListeningMode.swift" "$SRC/ResumeParser.swift" "$SRC/SignInMessages.swift" "$SRC/UpdateNoticeRules.swift" "$SRC/LanguageRules.swift" \
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

# The sign-in page (Windows bug rounds 1 and 32): fields and icon buttons carry names for VoiceOver, a closed window reports
# nothing, and no sign-in words blame the connection.
LOGIN="$ROOT/InterviewCopilot/InterviewCopilot/Views/LoginView.swift"
for label in '"Email address"' '"Password"' '"Full name"' 'showPassword ? "Hide password" : "Show password"' '"Close"'; do
  grep -q "accessibilityLabel($label)" "$LOGIN" || { echo "SIGN IN CHECK FAILED: no accessibility label $label"; exit 1; }
done
grep -q 'onDisappear { life.closed = true }' "$LOGIN" && grep -q 'guard !life.closed else { return }' "$LOGIN" || { echo "SIGN IN CHECK FAILED: a closed sign-in window still reports"; exit 1; }
if grep -niE '"[^"]*(connection|internet|network)[^"]*"' "$LOGIN" "$ROOT/InterviewCopilot/InterviewCopilot/Models/GoogleSignIn.swift" | grep -v 'dlog(' ; then echo "SIGN IN CHECK FAILED: sign-in words blame the connection"; exit 1; fi
echo "SIGN IN CHECK: labels for VoiceOver, a closed window reports nothing, no connection words"

# Settings Save starts from the stored settings, never a blank object (Windows bug round 6).
grep -q 'obj.merge(current) { _, new in new }' "$VM" || { echo "SETTINGS CHECK FAILED: Save does not start from the stored settings"; exit 1; }
echo "SETTINGS CHECK: Save keeps what it does not write"

# Local security (Windows bug round 18): the FIFO carrying the computer's sound to the engine is the user's only, and so is the
# folder holding it and the transcript.
grep -q 'mkfifo(path, 0o600)' "$SRC/SystemAudioTapper.swift" || { echo "SECURITY CHECK FAILED: the audio FIFO is not 0600"; exit 1; }
grep -q 'posixPermissions: 0o700], ofItemAtPath: dir.path' "$SRC/SpeechmaticsEngine.swift" || { echo "SECURITY CHECK FAILED: the engine folder is not the user's only"; exit 1; }
if grep -nE '"/tmp/|NSTemporaryDirectory\(\)' "$SRC/SpeechmaticsEngine.swift" "$SRC/SystemAudioTapper.swift"; then echo "SECURITY CHECK FAILED: engine audio or words pass through /tmp"; exit 1; fi
echo "SECURITY CHECK: audio FIFO 0600 in a folder that is the user's only"

# A crash on the last run is said to admin once on the next launch (Windows bug round 39).
grep -q 'SentrySDK.lastRunStatus == .didCrash' "$SRC/CrashReporter.swift" && grep -q '"previous-run-crashed"' "$SRC/CrashReporter.swift" || { echo "CRASH CHECK FAILED: the next launch does not report a crash"; exit 1; }
echo "CRASH CHECK: previous-run-crashed is reported on the next launch"

# A custom date format that is written or sent uses en_US_POSIX (Windows round 16: a Thai Windows sent the year 2569).
# Display-only formats (Sessions list, debug log time) follow the person's own settings and are not checked.
for f in "$VM" "$SRC/NetworkClient.swift"; do
  if grep -n 'dateFormat = "' "$f" | while IFS=: read -r n _; do sed -n "$((n-4)),$((n))p" "$f" | grep -q 'en_US_POSIX' || echo "$f:$n"; done | grep .; then
    echo "DATE CHECK FAILED: a custom date format without en_US_POSIX"; exit 1; fi
done
echo "DATE CHECK: custom date formats use en_US_POSIX"
