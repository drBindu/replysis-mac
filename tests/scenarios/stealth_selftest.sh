#!/bin/bash
# The hiding self-test at start (Windows StealthSelfTest, 2026-10-22) and the setup "Screen share" row (2026-10-23). Flashes a 16 pt
# square at the top left of the screen for half a second per run (three runs). Stealth on: Hidden. Control, a probe without hiding:
# Visible (so the check can see a window at all). Stealth off: Off, and no square.
#   stealth_selftest.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
run() {   # run <label> <settings extra> <extra env> <wanted label>
  local label="$1" extra="$2" envx="$3" want="$4" PORT=$((21100 + RANDOM % 90)) DATA=/tmp/glass/lab/data-selftest
  rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo "{\"listeningMode\":\"manual\"$extra}" > "$DATA/settings.json"
  python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & local MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_SELFTEST=1 $envx REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & local PID=$!
  sleep 9
  local L; L=$(wc -l < "$LOG"); echo dump >> "$DATA/flow.cmd"; sleep 2
  local S; S=$(sed -n "$((L+1)),\$p" "$LOG" | grep "FLOWSTATE: step" | tail -1)
  echo "$S" | grep -q "screenshare='$want'" && ok "$label: Screen share says $want" || { no "$label: wanted $want"; echo "        $S" | sed -n "s/.*\(screenshare='[^']*'\).*/\1/p"; }
  kill $PID $MOCK 2>/dev/null; sleep 1
}
run "Stealth on" "" "" Hidden
run "Control, a probe with no hiding" "" "REPLYSIS_SELFTEST_UNHIDDEN=1" Visible
run "Stealth off" ',"stealthModeEnabled":false' "" Off
[ $fail -eq 0 ] && echo "STEALTH SELFTEST: all checks passed" || echo "STEALTH SELFTEST: FAILED"
exit $fail
