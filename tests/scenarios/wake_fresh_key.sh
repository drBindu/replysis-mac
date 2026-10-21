#!/bin/bash
# Waking with an expired speech key while the Wi-Fi is still joining (the owner's Mac, 2026-10-21 04:30). A failed renewal had thrown
# the key away and the wake reconnect asked once, failed, and gave up without a word, so speech came back half a minute later.
# Here: the key is dropped, the Mac "wakes", key requests fail for 6 s (dropped connections = offline, then 503 = server down), then work.
# The app must have a fresh key within about 2 s of the line coming back (offline) and within the server's back-off (503).
#   wake_fresh_key.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
run() {   # run <offline|server-down> <max seconds after the line is back>
  local mode="$1" limit="$2" PORT=$((20400 + RANDOM % 90)) DATA=/tmp/glass/lab/data-wake DOWN=/tmp/glass/lab/keydown
  rm -rf "$DATA" "$DOWN"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  MOCK_KEYDOWN_FILE=$DOWN MOCK_KEYDOWN_MODE=$mode python3 "$HERE/mock_backend.py" wake-lab $PORT > /tmp/glass/lab/mock-wake.out 2>&1 & local MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & local PID=$!
  sleep 10
  local L; L=$(wc -l < "$LOG")
  touch "$DOWN"; echo dropkey >> "$DATA/flow.cmd"; sleep 1; echo wakenote >> "$DATA/flow.cmd"
  sleep 6; rm -f "$DOWN"; local back; back=$(date +%s)
  sleep 12
  local NEW; NEW=$(sed -n "$((L+1)),\$p" "$LOG")
  kill $PID $MOCK 2>/dev/null; sleep 1
  local at; at=$(echo "$NEW" | grep -m1 "WAKE: fresh speech key ready" | sed 's/^\[\([0-9:]*\)\..*/\1/')
  if [ -z "$at" ]; then no "$mode: no fresh key after the wake"; echo "$NEW" | grep -E "WAKE|SM key" | head -12 | cut -c1-160 | sed 's/^/        /'; return; fi
  local s=$(( $(date -j -f %H:%M:%S "$at" +%s) - back ))
  [ $s -le $limit ] && ok "$mode: fresh key ${s}s after the line came back (limit ${limit}s)" || no "$mode: fresh key only ${s}s after the line came back"
  echo "    key requests while down: $(grep -c 'stt/key -> \(dropped\|503\)' /tmp/glass/lab/mock-wake.out)"
}
run offline 2
run server-down 6
[ $fail -eq 0 ] && echo "WAKE FRESH KEY: all checks passed" || echo "WAKE FRESH KEY: FAILED"
exit $fail
