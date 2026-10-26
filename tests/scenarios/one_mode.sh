#!/bin/bash
# One listening mode (Windows 1.0.45, 2026-10-22). The REAL app (Debug, invisible) against the fake server:
#  1. A copy that had chosen Interview (microphone off) is moved to the microphone on, once, and the setting is saved with the marker.
#  2. The engine's ">>> SOURCE" labels (imitated by the flow commands source-interviewer and source-candidate) reach the app.
#   one_mode.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
DATA=/tmp/glass/lab/data-onemode; OUT=/tmp/glass/lab/mock-onemode.out
PORT=$((21300 + RANDOM % 90)); rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"auto","micCaptureEnabled":false}' > "$DATA/settings.json"
python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
sleep 10
grep -q '"micCaptureEnabled":true' "$DATA/settings.json" && grep -q '"oneListeningMode":true' "$DATA/settings.json" \
  && ok "a copy on Interview (microphone off) is moved to one mode, microphone on, and saved" || { no "not moved"; cat "$DATA/settings.json" | head -c 300; echo; }
# Who is speaking: the engine's ">>> SOURCE" lines reach the app (the answer rule itself is checked in tools/run-regressions.sh,
# because Auto needs a live speech engine, which the fake server cannot give).
L=$(wc -l < "$LOG"); cmd source-interviewer; sleep 1; cmd source-candidate; sleep 1
sed -n "$((L+1)),\$p" "$LOG" | grep -q "turn spoken by: interviewer" && ok "an interviewer turn is noted" || no "the interviewer label was lost"
sed -n "$((L+1)),\$p" "$LOG" | grep -q "turn spoken by: candidate (interviewer present, will not answer)" && ok "a candidate turn with an interviewer present is marked not to answer" || no "the candidate label was lost"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "ONE MODE: all checks passed" || echo "ONE MODE: FAILED"
exit $fail
