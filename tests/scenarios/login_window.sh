#!/bin/bash
# The sign-in window (owner, 2026-10-09): two things were wrong in every Mac build since the new sign-in window of 1.0.247.
#  1. The close button did nothing under a real mouse click: it was drawn UNDER the scrolling form, which covers the whole panel, so the click
#     landed on the form. (Pressing it through accessibility worked, so only a hit test shows it.)
#  2. There was no "Continue with Google": the button only showed when the app held a Google key, which nobody ships. Windows has the button
#     always and lets the server finish the sign-in.
# Runs the REAL app (a Debug build, invisible) with the sign-in window open, asks accessibility what is there, then sends a mouse click
# to the middle of the close button through the window, the way the system does (the invisible copy cannot be reached by a real mouse).
#   login_window.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
PORT=$((19700 + RANDOM % 90)); DATA=/tmp/glass/lab/data-loginwin; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
swiftc -O -o /tmp/login_probe "$HERE/login_probe.swift" 2>/dev/null || { echo "  FAIL  could not build the probe"; exit 1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
sleep 9; echo login >> "$DATA/flow.cmd"; sleep 3
OUT=$(/tmp/login_probe $PID)
echo "$OUT" | sed 's/^/        /'
echo "$OUT" | grep -q "^SHEETS 1" && ok "the sign-in window is open" || no "the sign-in window did not open"
echo "$OUT" | grep -q "^GOOGLE_BUTTONS [1-9]" && ok "the sign-in window has a Continue with Google button" || no "no Continue with Google button"
SPOT=$(echo "$OUT" | sed -n 's/^CLOSE_AT //p')
[ -n "$SPOT" ] && ok "the close button is there" || no "no close button"
echo "clickat $SPOT" >> "$DATA/flow.cmd"; sleep 2
/tmp/login_probe $PID | grep -q "^SHEETS 0" && ok "a mouse click on the close button closes the window" || no "a mouse click on the close button did not close the window"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "LOGIN WINDOW: all checks passed" || echo "LOGIN WINDOW: FAILED"
exit $fail
