#!/bin/bash
# The Mac stays awake only while an interview session runs (Windows 1.0.31, item 26). Starts the REAL app (a Debug build,
# invisible, against a fake server), starts an interview, and reads the system's own list of sleep assertions.
#   wakefulness.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=$((18800 + RANDOM % 90)); DATA=/tmp/glass/lab/data-awake; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","screenAnswers":false}' > "$DATA/settings.json"
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
held(){ pmset -g assertions 2>/dev/null | grep -F "pid $PID" | grep -c "PreventUserIdleSystemSleep"; }
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
sleep 10
[ "$(held)" = "0" ] && ok "on the Setup page the Mac is not kept awake" || no "kept awake on the Setup page"
cmd start; sleep 4
[ "$(held)" -ge 1 ] && ok "during an interview the Mac is kept from idle sleep" || no "not kept awake during an interview"
pmset -g assertions 2>/dev/null | grep -F "pid $PID" | sed 's/^ *//' | cut -c1-170 | sed 's/^/        /'
cmd back; sleep 4
[ "$(held)" = "0" ] && ok "back on Setup the hold is released" || no "still held after going back to Setup"
cmd start; sleep 3
[ "$(held)" -ge 1 ] && ok "a second interview holds it again" || no "second interview did not hold it"
cmd finish; sleep 5
[ "$(held)" = "0" ] && ok "finishing the interview releases it" || no "still held after finishing"
kill $PID 2>/dev/null; kill $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "WAKEFULNESS: all checks passed" || echo "WAKEFULNESS: FAILED"
exit $fail
