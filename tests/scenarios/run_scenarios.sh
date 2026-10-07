#!/bin/bash
# Runs the REAL Mac app (a Debug build) against a fake server, one account situation at a time.
#   run_scenarios.sh <path-to-Debug-InterviewCopilot.app> [scenario ...]
# Prints, per scenario: what the person was told (in words) and what the app asked the server.
# Debug builds only: the override is compiled out of Release. The Keychain is inert while a
# test runs, so the real signed-in session is never touched.
APP="$1"; shift
BIN="$APP/Contents/MacOS/InterviewCopilot"
[ -x "$BIN" ] || { echo "no app at $APP"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
SETTINGS=~/Library/Application\ Support/InterviewCopilot/settings.json
cp "$SETTINGS" /tmp/scenario-settings.bak 2>/dev/null
SCENARIOS=("$@"); [ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(no-listening no-credits signed-out service-down provider-busy rate-limited refused-then-rate-limited wake-token-rejected wake-token-expired)
WAIT=${WAIT:-22}
port=18100
for sc in "${SCENARIOS[@]}"; do
  port=$((port+1))
  pkill -f "Replysis-dev.app/Contents/MacOS" 2>/dev/null; pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 2
  session=stale; [ "$sc" = "wake-token-expired" ] && session=expired
  python3 "$HERE/mock_backend.py" "$sc" $port >/tmp/mock-$sc.out 2>&1 &
  MOCK=$!; sleep 1
  M=$(wc -l < "$LOG")
  REPLYSIS_BACKEND_URL="http://127.0.0.1:$port" REPLYSIS_TOKEN_URL="http://127.0.0.1:$port/token" \
    REPLYSIS_TEST_SESSION=$session REPLYSIS_HEADLESS=1 "$BIN" >/dev/null 2>&1 &
  sleep "$WAIT"
  echo "=== $sc"
  echo "  server saw:"; grep REQ /tmp/mock-$sc.out | sed 's/^/    /' | uniq -c | head -8
  echo "  keys requested: $(grep -c 'stt/key' /tmp/mock-$sc.out)"
  echo "  the person was told:"
  sed -n "$((M+1)),\$p" "$LOG" | grep -E "\[ALERT\]" | sed 's/.*ALERT: /    /' | cut -c1-230 | head -3
  sed -n "$((M+1)),\$p" "$LOG" | grep -E "Problem shown" | sed 's/.*\] /    (log) /' | head -2
  pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; kill $MOCK 2>/dev/null; sleep 1
done
cp /tmp/scenario-settings.bak "$SETTINGS" 2>/dev/null
echo "(your settings restored)"
