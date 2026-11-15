#!/bin/bash
# The compact bar opens without crashing and closes again (it crashed on open in 1.0.256 and 1.0.257: its window was not handed the
# view model that ModePill reads from the environment). The REAL app, Debug, invisible, against the fake server.
#   compact.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"; HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
DATA=/tmp/glass/lab/data-compact; PORT=$((21400 + RANDOM % 90)); rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
python3 "$HERE/mock_backend.py" healthy-credits $PORT > /tmp/glass/lab/mock-compact.out 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
sleep 10; cmd start; sleep 3
L=$(wc -l < "$LOG"); cmd compact; sleep 3
kill -0 $PID 2>/dev/null && ok "the app is still running 3 s after the compact bar opened" || no "the app crashed when the compact bar opened"
cmd compact; sleep 2
kill -0 $PID 2>/dev/null && ok "and after it closed again" || no "the app crashed when the compact bar closed"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "COMPACT: all checks passed" || echo "COMPACT: FAILED"
exit $fail
