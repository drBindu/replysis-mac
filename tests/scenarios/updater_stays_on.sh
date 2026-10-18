#!/bin/bash
# Automatic update checks must survive an interview (owner, 2026-10-16). The app paused the checks for the length of an interview by switching
# Sparkle's own setting off, and Sparkle keeps that setting in the user's defaults (SUEnableAutomaticChecks). An app quit during an interview,
# which is how most of them end, therefore never checked for updates again: on the owner's Mac the setting was found at 0 and the updates
# never came. The pause is now a flag inside the app; the setting is never written false, and a copy that an older build left at false is
# put right at launch. Runs the REAL app (a Debug build, invisible) against the fake server.
# NOTE: Sparkle's defaults are shared with the installed app (same bundle id); this test leaves the setting ON, which is the right state.
#   updater_stays_on.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
DOM=com.bindualekhya.InterviewCopilot
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
val(){ defaults read $DOM SUEnableAutomaticChecks 2>/dev/null || echo "unset"; }
PORT=$((20200 + RANDOM % 90)); DATA=/tmp/glass/lab/data-updater; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
defaults write $DOM SUEnableAutomaticChecks -bool false; sleep 1
[ "$(val)" = "0" ] && ok "start state: the checks are switched off, as an older build left them" || no "could not set the start state"
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
sleep 10
[ "$(val)" = "1" ] && ok "at launch the checks are switched back on" || no "the checks are still off after launch (value: $(val))"
echo start >> "$DATA/flow.cmd"; sleep 4
[ "$(val)" = "1" ] && ok "during an interview the setting stays on (the pause is inside the app)" || no "an interview switched the setting off (value: $(val))"
LOG=~/Library/Logs/InterviewCopilot-debug.log; L=$(wc -l < "$LOG")
echo updatecheck >> "$DATA/flow.cmd"; sleep 4
sed -n "$((L+1)),\$p" "$LOG" | grep -q "held back until the interview ends" && ok "a background check that falls due during an interview is held back" || no "a background check during an interview was not held back"
L=$(wc -l < "$LOG"); echo finish >> "$DATA/flow.cmd"; sleep 6
sed -n "$((L+1)),\$p" "$LOG" | grep -q "automatic background checks resumed" && ok "when the interview ends the checks resume" || no "the checks did not resume after the interview"
sed -n "$((L+1)),\$p" "$LOG" | grep -q "check finished\|update available" && ok "and a check runs at once, for what was skipped" || no "no check ran after the interview"
echo start >> "$DATA/flow.cmd"; sleep 3
kill -9 $PID 2>/dev/null; sleep 2
[ "$(val)" = "1" ] && ok "after the app is killed in the middle of an interview the checks are still on" || no "after a kill in the middle of an interview the checks are off (value: $(val))"
kill $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "UPDATER STAYS ON: all checks passed" || echo "UPDATER STAYS ON: FAILED"
exit $fail
