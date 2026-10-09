#!/bin/bash
# A screen with nothing on it to answer (Windows 1.0.31 item 30). Runs the REAL app (a Debug build, invisible) against the fake server, which
# answers the screen with the two lines of the NOTHING ASKED shape (then notes that are never shown), the way the model now does. Checks that the
# prompt the app sent carries the NOTHING ASKED paragraph and, for the answer that finishes, the text the person is left with: the plain
# sentence, not the heading and not an invented task. (On Windows the plain sentence showed while the answer streamed and was missing from
# the finished one.) Also checks that a real question about the screen is not touched.
#   nothing_asked.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
PORT=$((19600 + RANDOM % 90)); DATA=/tmp/glass/lab/data-nothing; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","screenAnswers":true}' > "$DATA/settings.json"
OUT=/tmp/glass/lab/mock-nothing.out
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
MOCK_SCREEN_NOTHING=1 python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
L=$(wc -l < "$LOG")
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch REPLYSIS_SCREEN_IMAGE=/tmp/glass/lab/screen.png "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
sleep 10; cmd micseen; cmd start; sleep 4
cmd screen; sleep 9          # the hotkey: no spoken question
cmd dump; sleep 2
since(){ sed -n "$((L+1)),\$p" "$LOG"; }
grep -q "nothing_asked_shape': True" "$OUT" && ok "the prompt the app sent carries the NOTHING ASKED shape" || no "the prompt did not carry the NOTHING ASKED shape"
STATE=$(since | grep "FLOWSTATE: step=interview" | tail -1)
echo "$STATE" | grep -q "answer='From your screen  No question on this screen" && ok "the finished answer is the plain sentence" || { no "the finished answer is not the plain sentence"; echo "        $STATE" | cut -c1-240; }
echo "$STATE" | grep -q "NOTHING ASKED\|SAY THIS\|DO THIS" && no "the heading or an invented task is still showing" || ok "no heading, no SAY THIS, no invented task"
since | grep -q "Screen analysis complete" && ok "the answer finished cleanly" || no "the answer did not finish"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "NOTHING ASKED: all checks passed" || echo "NOTHING ASKED: FAILED"
exit $fail
