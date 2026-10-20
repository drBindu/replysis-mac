#!/bin/bash
# VISIBLE TEST (puts a test copy on screen for about two minutes; warn the owner first). Proves what a real screen share sees: captures
# the screen the way Zoom/Meet/Teams do (ScreenCaptureKit) with a test copy's windows open, in three states (main window, Past Sessions,
# profile popover). Stealth on: every window must be HIDDEN from the shared screen. Stealth off (control): the main window must be
# VISIBLE, which proves the check can see a window at all.
#   real_capture.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
swiftc -O -o /tmp/axpress "$HERE/axpress.swift" 2>/dev/null
swiftc -O -o /tmp/capture_probe "$HERE/capture_probe.swift" 2>/dev/null
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1

run() {   # run <label> <extra settings json> <wanted HIDDEN|VISIBLE>
  local label="$1" extra="$2" want="$3"
  local PORT=$((20100 + RANDOM % 90)) DATA=/tmp/glass/lab/data-realcapture
  rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo "{\"listeningMode\":\"manual\"$extra}" > "$DATA/settings.json"
  python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & local MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & local PID=$!
  cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
  check() {   # check <state>
    local out; out=$(/tmp/capture_probe $PID)
    echo "$out" | sed 's/^/        /'
    local n bad; n=$(echo "$out" | grep -c '^WINDOW'); bad=$(echo "$out" | grep '^WINDOW' | grep -vc "shared-screen=$want")
    if [ "$want" = HIDDEN ]; then
      [ "$n" -ge 1 ] && [ "$bad" -eq 0 ] && ok "$label, $1: all $n windows hidden from the shared screen" || no "$label, $1: $bad of $n windows show on the shared screen"
    else
      [ "$n" -ge 1 ] && [ "$bad" -lt "$n" ] && ok "$label, $1: the share sees the window (the check works)" || no "$label, $1: the check saw nothing"
    fi
  }
  popover() {   # the profile menu is not listed as a window of its own, so compare the shared screen before and after it opens
    /tmp/capture_probe $PID snap /tmp/glass/lab/before.raw >/dev/null
    /tmp/axpress $PID "Account" >/dev/null; sleep 2
    local out c; out=$(/tmp/capture_probe $PID since /tmp/glass/lab/before.raw); echo "$out" | sed 's/^/        /'
    c=$(echo "$out" | sed -n 's/^CHANGED //p')
    if [ "$want" = HIDDEN ]; then
      awk "BEGIN{exit !($c < 0.002)}" && ok "$label, profile menu open: the shared screen did not change ($c)" || no "$label, profile menu open: the shared screen changed ($c)"
    else
      awk "BEGIN{exit !($c >= 0.002)}" && ok "$label, profile menu open: the share sees the menu ($c, the check works)" || no "$label, profile menu open: the check saw nothing ($c)"
    fi
  }
  sleep 10; check "main window"
  popover
  [ "$want" = HIDDEN ] || { kill $PID $MOCK 2>/dev/null; sleep 1; return; }
  /tmp/axpress $PID "Account" >/dev/null; sleep 1
  cmd sessions; sleep 3; check "Past Sessions open"; cmd closesessions; sleep 2
  kill $PID $MOCK 2>/dev/null; sleep 1
}
run "Stealth on" "" HIDDEN
run "Stealth off" ',"stealthModeEnabled":false' VISIBLE
[ $fail -eq 0 ] && echo "REAL CAPTURE: all checks passed" || echo "REAL CAPTURE: FAILED"
exit $fail
