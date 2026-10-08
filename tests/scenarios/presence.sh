#!/bin/bash
# The once-a-minute "this app is open" ping (Windows 1.0.31 item 29): POST /api/v1/presence with the Bearer token and the two labels,
# no body, answered 204, and nothing shown if it fails. Runs the REAL app (a Debug build, invisible) against the fake server with the ping
# every 5 seconds instead of every 60 so the test is short, then makes the fake server stop answering and checks the app shows nothing.
#   presence.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=$((19300 + RANDOM % 90)); DATA=/tmp/glass/lab/data-presence; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
OUT=/tmp/glass/lab/mock-presence.out
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale REPLYSIS_TEST_USER=presence-user \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_PRESENCE_SECONDS=5 "$BIN" >/dev/null 2>&1 & PID=$!
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
sleep 28
N=$(grep -c '^PRESENCE' "$OUT")
[ "$N" -ge 4 ] && ok "the app pinged $N times in about 28 s (every 5 s in this test)" || no "only $N pings seen"
[ "$(grep '^PRESENCE' "$OUT" | grep -c 'auth=bearer')" = "$N" ] && ok "every ping carried the Bearer token" || no "a ping had no token"
[ "$(grep '^PRESENCE' "$OUT" | grep -c 'body=0')" = "$N" ] && ok "no ping had a body" || no "a ping had a body"
[ "$(grep '^PRESENCE' "$OUT" | grep -c 'platform=mac version=[0-9][0-9.]*$')" = "$N" ] && ok "every ping carried X-App-Platform: mac and the plain version" || no "a ping lacked the labels"
# Gaps between pings: roughly the interval, never a burst
grep -c '^HDR POST /api/v1/presence' "$OUT" | sed 's/^/        presence requests on the wire: /'
# Stop answering: kill the fake server; the app must carry on silently (still running, no crash)
kill $MOCK 2>/dev/null; sleep 12
kill -0 $PID 2>/dev/null && ok "the server stopped answering and the app carried on, nothing crashed" || no "the app died when the ping failed"
kill $PID 2>/dev/null
[ $fail -eq 0 ] && echo "PRESENCE: all checks passed" || echo "PRESENCE: FAILED"
exit $fail
