#!/bin/bash
# No microphone (Windows MAC_CATCHUP, 2026-10-18 and 2026-10-19) and problem reports to admin (2026-10-19).
# The engine says NO_MICROPHONE_WAITING when Practice has no microphone to listen to. The alert must STAY (it used to be a note that
# flashed), offer "Use Interview instead", go away by itself when MICROPHONE CONNECTED arrives, and the problem must reach admin once,
# with no account, no path and no email in it. Runs the REAL app (a Debug build, invisible) against the fake server, which records
# the report. The flow commands nomic and miccame do what the two engine lines do.
#   no_microphone.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
PORT=$((20500 + RANDOM % 90)); DATA=/tmp/glass/lab/data-nomic; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; OUT=/tmp/glass/lab/mock-nomic.out
echo '{"listeningMode":"manual","micCaptureEnabled":true}' > "$DATA/settings.json"
swiftc -O -o /tmp/axpress "$HERE/axpress.swift" 2>/dev/null
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
state(){ L=$(wc -l < "$LOG"); cmd dump; sleep 2; sed -n "$((L+1)),\$p" "$LOG" | grep "FLOWSTATE: step" | tail -1; }
sleep 10; cmd start; sleep 4
cmd nomic; sleep 12
S=$(state)
echo "$S" | grep -q "alert='No microphone found'" && ok "Practice with no microphone: the alert is still on screen 14 seconds later" || { no "the alert did not stay"; echo "        $S" | cut -c1-260; }
/tmp/axpress $PID "Use Interview instead" | grep -q "press: ok" && ok "the alert has a Use Interview instead button" || no "no Use Interview instead button"
sleep 2
S=$(state); echo "$S" | grep -q "alert=''" && ok "pressing it takes the alert down" || no "the alert is still there after the button"
grep -q '"micCaptureEnabled":false' "$DATA/settings.json" 2>/dev/null && ok "and the app is now on Interview (the computer's sound)" || { grep -o 'micCaptureEnabled[^,]*' "$DATA/settings.json" | head -1 | sed 's/^/        /'; no "the app did not switch to Interview"; }
cmd nomic; sleep 2; S=$(state); echo "$S" | grep -q "alert='No microphone found'" || no "the alert did not come back for a second test"
cmd miccame; sleep 2; S=$(state)
echo "$S" | grep -q "alert=''" && ok "a microphone plugged in takes the alert down by itself" || no "the alert stayed after MICROPHONE CONNECTED"
sleep 2
N=$(grep -c "^CLIENT-ERROR type=Problem.alert.no-microphone-found" "$OUT")
[ "$N" = "1" ] && ok "the problem reached admin once (two alerts, one report)" || no "the problem was reported $N times"
grep "^CLIENT-ERROR type=Problem.alert.no-microphone-found" "$OUT" | head -1 | grep -q "platform=mac" && grep "^CLIENT-ERROR" "$OUT" | head -1 | grep -q "keys=\['detail', 'frames', 'message', 'os', 'source', 'type', 'user', 'version'\]" && ok "with the same fields as Windows and the Mac platform label" || { grep "^CLIENT-ERROR" "$OUT" | head -2 | cut -c1-240 | sed 's/^/        /'; no "the report is not shaped like Windows'"; }
grep "^CLIENT-ERROR" "$OUT" | grep -qi "example.test\|@\|/Users/" && no "the report carries an account, an email or a path" || ok "and carries no account, email or path"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "NO MICROPHONE: all checks passed" || echo "NO MICROPHONE: FAILED"
exit $fail
