#!/bin/bash
# The interview page is only the answer and the transcript (owner, 2026-10-16). The Setup page has the resume, role and answer style, so the
# interview page no longer carries a resume column or the thin strip with an arrow that used to reopen it. Starts the REAL app (a Debug build,
# invisible) and reads the buttons of each page through accessibility. The strip's arrow was announced as "Forward".
#   interview_page.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
PORT=$((19900 + RANDOM % 90)); DATA=/tmp/glass/lab/data-ipage; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
swiftc -O -o /tmp/login_probe "$HERE/login_probe.swift" 2>/dev/null
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
sleep 10
S=$(/tmp/login_probe $PID all)
echo "$S" | grep -q "^BUTTON Start interview" && ok "on Setup there is a Start interview button (the resume, role and style live here)" || no "Setup page not found"
cmd start; sleep 4
I=$(/tmp/login_probe $PID all)
echo "$I" | grep -q "^BUTTON Forward " && no "the interview page still has the strip with the arrow" || ok "the interview page has no side strip with an arrow"
echo "$I" | grep -q "Drop your resume here\|^BUTTON Auto \|^BUTTON Manual \|Start interview" && no "the interview page still carries setup controls" || ok "the interview page carries no resume or setup controls"
echo "$I" | grep -q "^BUTTON Pin " && ok "the interview page still has its own controls (the pin, from the toolbar)" || no "the interview page lost its toolbar"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "INTERVIEW PAGE: all checks passed" || echo "INTERVIEW PAGE: FAILED"
exit $fail
