#!/bin/bash
# The top bar (Windows MAC_CATCHUP, 2026-10-19: decided and locked by the owner on Windows, "Mac: match this layout").
# During an interview: the logo, the mic, ONE pill ("Interview Auto", "Practice Manual"...) that opens a menu, Screen, the answers badge,
# the round avatar and close. The Auto and Manual buttons, the Interview and Practice buttons, Compact and Pin are not in the bar any more:
# they are rows of the pill's menu. On Setup there is no pill. Runs the REAL app (a Debug build, invisible) and reads the bar through
# accessibility.
#   top_bar.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
PORT=$((20600 + RANDOM % 90)); DATA=/tmp/glass/lab/data-topbar; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","micCaptureEnabled":false}' > "$DATA/settings.json"
swiftc -O -o /tmp/axpress "$HERE/axpress.swift" 2>/dev/null; swiftc -O -o /tmp/login_probe "$HERE/login_probe.swift" 2>/dev/null
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
buttons(){ /tmp/login_probe $PID all | grep "^BUTTON"; }
sleep 10
buttons | grep -q "^BUTTON Mode menu" && no "the pill shows on Setup" || ok "on Setup there is no pill"
cmd start; sleep 4
B=$(buttons)
echo "$B" | grep -q "^BUTTON Mode menu: Manual" && ok "in the interview the pill says how it answers (Manual); one listening mode, no Interview or Practice" || { no "no pill with the state"; echo "$B" | head -12 | cut -c1-80 | sed 's/^/        /'; }
echo "$B" | grep -q "^BUTTON Account" && ok "the profile is the round avatar" || no "no avatar button"
echo "$B" | grep -q "^BUTTON Read screen\|^BUTTON .*Screen" && ok "Screen is in the bar" || no "no Screen button"
echo "$B" | grep -q "^BUTTON AUTO\|^BUTTON MANUAL\|^BUTTON Compact\|^BUTTON Pin" && no "the old Auto, Manual, Compact or Pin buttons are still in the bar" || ok "the old Auto, Manual, Compact and Pin buttons are gone from the bar"
/tmp/axpress $PID "Mode menu" | grep -q "press: ok" && ok "the pill opens" || no "the pill did not open"
sleep 1; M=$(buttons)
for row in "Auto" "Manual" "Compact" "Pin on top"; do
  echo "$M" | grep -q "^BUTTON $row" && ok "the menu has $row" || no "the menu has no $row"
done
for row in "Interview" "Practice"; do
  echo "$M" | grep -q "^BUTTON $row " && no "the menu still has $row" || ok "the menu has no $row (one listening mode)"
done
/tmp/axpress $PID "Auto" | grep -q "press: ok" && ok "choosing Auto works" || no "could not choose Auto"
sleep 2
buttons | grep -q "^BUTTON Mode menu: Auto" && ok "the pill now says Auto" || no "the pill did not change to Auto"
# the shortcut Control Shift A (the flow command calls what the key calls)
cmd key-a; sleep 2
buttons | grep -q "^BUTTON Mode menu: Manual" && ok "Control Shift A switches Auto to Manual" || no "Control Shift A did not switch to Manual"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "TOP BAR: all checks passed" || echo "TOP BAR: FAILED"
exit $fail
