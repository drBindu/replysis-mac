#!/bin/bash
# Stealth Mode covers EVERY window of the app (owner, 2026-10-16: "no stealth in Past Sessions and the profile").
# Sheets (Past Sessions, sign-in, Settings), popovers (the profile menu) and alerts are windows of their own, and a window's sharingType starts
# as 1 (a screen share can capture it). Only the main panel and the answer bar used to be set to 0. The app reports each of its windows'
# own sharingType through the developer command "capturable". Asked in four states, with Stealth Mode on (every window must say 0) and
# off (every window must say 1: the setting still works both ways). The window server's own list (kCGWindowSharingState) said 0 for sheets
# that were in fact capturable, so it is NOT used here.
#   stealth_windows.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
swiftc -O -o /tmp/axpress "$HERE/axpress.swift" 2>/dev/null
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1

run() {   # run <label> <extra settings json> <wanted sharingType>
  local label="$1" extra="$2" want="$3"
  local PORT=$((20000 + RANDOM % 90)) DATA=/tmp/glass/lab/data-stealthwin
  rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo "{\"listeningMode\":\"manual\"$extra}" > "$DATA/settings.json"
  python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & local MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & local PID=$!
  cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
  check() {   # check <state>
    local L; L=$(wc -l < "$LOG"); cmd capturable; sleep 2
    local line; line=$(sed -n "$((L+1)),\$p" "$LOG" | grep "FLOWSTATE: this app's windows" | tail -1 | sed 's/^.*this app.s windows: //')
    local total wrong; total=$(echo "$line" | tr '|' '\n' | grep -c sharingType); wrong=$(echo "$line" | tr '|' '\n' | grep sharingType | grep -vc "sharingType=$want")
    [ "$total" -ge 1 ] && [ "$wrong" -eq 0 ] && ok "$label, $1: all $total windows say sharingType=$want" || { no "$label, $1: $wrong of $total windows are not $want"; echo "        $line" | cut -c1-260; }
  }
  sleep 10; check "main window"
  cmd sessions; sleep 3; check "Past Sessions open"; cmd closesessions; sleep 2
  /tmp/axpress $PID "SC" >/dev/null; sleep 2; check "profile popover open"
  kill $PID $MOCK 2>/dev/null; sleep 1
}
run "Stealth on" "" 0
run "Stealth off" ',"stealthModeEnabled":false' 1
[ $fail -eq 0 ] && echo "STEALTH WINDOWS: all checks passed" || echo "STEALTH WINDOWS: FAILED"
exit $fail
