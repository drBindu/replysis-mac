#!/bin/bash
# Weak line (Windows MAC_CATCHUP item 41, 2026-10-13). The speech engine sends the voice in half the bytes (8 bit mu-law) while the app
# data folder holds slowline.flag. The app writes it when its upload test is slow (over 1.2 s for 160 KB) or fails, and removes it when a
# test passes. Runs the REAL app (a Debug build, invisible) against the fake server twice: a line that uploads 60 KB/s (the test takes
# about 2.7 s: the flag must appear) and an unthrottled one with a stale flag left over (the flag must go).
#   slowline_flag.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
run() {   # run <label> <kbps or empty> <flag before: yes|no> <flag expected after: yes|no>
  local label="$1" kbps="$2" before="$3" want="$4" PORT=$((20400 + RANDOM % 90)) DATA=/tmp/glass/lab/data-slowline
  rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  [ "$before" = yes ] && echo 1 > "$DATA/slowline.flag"
  MOCK_UPLINK_KBPS=$kbps python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & local MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & local PID=$!
  sleep 9; echo probe >> "$DATA/flow.cmd"; sleep 9
  if [ "$want" = yes ]; then [ -f "$DATA/slowline.flag" ] && ok "$label: the flag is there" || no "$label: no flag after a slow upload test"
  else [ ! -f "$DATA/slowline.flag" ] && ok "$label: no flag" || no "$label: the flag is still there after a good upload test"; fi
  kill $PID $MOCK 2>/dev/null; sleep 1
}
run "a 60 KB/s line" 60 no yes
run "a fast line, with a stale flag from before" "" yes no
[ $fail -eq 0 ] && echo "SLOW LINE FLAG: all checks passed" || echo "SLOW LINE FLAG: FAILED"
exit $fail
