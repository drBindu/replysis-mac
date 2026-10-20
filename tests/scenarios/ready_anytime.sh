#!/bin/bash
# The speech key service is down at launch and comes back 10 seconds later. The app must have a key within about 5 seconds of
# that (it used to look again only once a minute), and must not show "Reconnecting" for a wait of a moment.
#   ready_anytime.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
PORT=$((20300 + RANDOM % 90)) DATA=/tmp/glass/lab/data-ready
rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
python3 "$HERE/mock_backend.py" key-down-then-back $PORT > /tmp/glass/lab/mock-ready.out 2>&1 & MOCK=$!; T0=$(date +%s); sleep 1
L=$(wc -l < "$LOG")
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
sleep 20
NEW=$(sed -n "$((L+1)),\$p" "$LOG")
kill $PID $MOCK 2>/dev/null; sleep 1
okat=$(echo "$NEW" | grep -m1 "SM key fetch: SUCCESS" | sed 's/^\[\([0-9:]*\)\..*/\1/')
[ -n "$okat" ] || { no "no key within 20 s"; echo "REAL ANYTIME: FAILED"; exit 1; }
s=$(( $(date -j -f %H:%M:%S "$okat" +%s) - T0 ))
[ $s -le 16 ] && ok "key received ${s}s after the server started (it was down for the first 10 s)" || no "key only ${s}s after the server started"
echo "$NEW" | grep -q "waitingToReconnect" && no "a Reconnecting notice was shown" || ok "no Reconnecting notice"
echo "    key requests: $(grep -c 'stt/key' /tmp/glass/lab/mock-ready.out)"
[ $fail -eq 0 ] && echo "READY ANYTIME: all checks passed" || echo "READY ANYTIME: FAILED"
exit $fail
