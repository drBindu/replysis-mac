#!/bin/bash
# The sign-in page (owner, 2026-10-09 and 2026-10-16). Nobody signed in: the window IS the sign-in page, filling the window, with Continue with Google
# (it was missing in every build because it needed a key nobody ships), and a close button that works under a real mouse click
# (it was drawn under the scrolling form, so a click never reached it). Here the close button quits the app, because there is nothing
# else to close to. Runs the REAL app (a Debug build, invisible) with nobody signed in, asks accessibility what is there, then sends a
# mouse click to the middle of the close button through the window the way the system does.
#   login_window.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
PORT=$((19700 + RANDOM % 90)); DATA=/tmp/glass/lab/data-loginwin; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
swiftc -O -o /tmp/login_probe "$HERE/login_probe.swift" 2>/dev/null || { echo "  FAIL  could not build the probe"; exit 1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
# no REPLYSIS_TEST_SESSION: nobody is signed in (a test run never reads the real Keychain)
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
sleep 9
OUT=$(/tmp/login_probe $PID)
echo "$OUT" | sed 's/^/        /'
echo "$OUT" | grep -q "^GOOGLE_BUTTONS [1-9]" && ok "the sign-in page has a Continue with Google button" || no "no Continue with Google button"
SPOT=$(echo "$OUT" | sed -n 's/^CLOSE_AT //p')
[ -n "$SPOT" ] && ok "the close button is there" || no "no close button"
echo "clickat $SPOT" >> "$DATA/flow.cmd"; sleep 3
kill -0 $PID 2>/dev/null && no "a mouse click on the close button did not close the app" || ok "a mouse click on the close button quits the app"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "LOGIN WINDOW: all checks passed" || echo "LOGIN WINDOW: FAILED"
exit $fail
