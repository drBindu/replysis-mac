#!/bin/bash
# After a wake or a roam the app learns the line again with one 160 KB test (the server answers 400 and keeps nothing: that IS the expected
# answer). The change used to be reported two or three times within seconds, and the test went up three times in three seconds, which the
# server logged as three rejected uploads. Here the wake is reported twice, 3 s apart; only one test may go up.
#   linetest_debounce.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=$((19400 + RANDOM % 90)); DATA=/tmp/glass/lab/data-linetest; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","screenAnswers":true}' > "$DATA/settings.json"
OUT=/tmp/glass/lab/mock-linetest.out
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
sleep 10; cmd micseen; cmd start; sleep 5
BEFORE=$(grep -c 'line test' "$OUT")
cmd wakenote; sleep 3; cmd wakenote; sleep 9
AFTER=$(grep -c 'line test' "$OUT")
N=$((AFTER - BEFORE))
[ "$N" = "1" ] && ok "the wake was reported twice and the line was tested once" || no "the line was tested $N times after two wake reports (expected 1)"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "LINE TEST: all checks passed" || echo "LINE TEST: FAILED"
exit $fail
