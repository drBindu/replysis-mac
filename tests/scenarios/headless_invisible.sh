#!/bin/bash
# A test copy (REPLYSIS_HEADLESS=1) must never put a window in front of whoever is using this Mac.
# Launches the REAL app (an unsigned Debug build, so microphone, accessibility and screen recording are all undecided and the
# "Set up permissions" sheet would normally open) against a fake server and lists every window the process owns:
# none may be on screen and visible. The sheet used to be pulled back onto the screen by AppKit even though the panel it
# hangs from sat off screen, and it was mistaken for the real app asking for permissions that were already granted.
#   headless_invisible.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL=/tmp/glass/win/windows_of; mkdir -p /tmp/glass/win; xcrun swiftc -O "$HERE/windows_of.swift" -o "$TOOL" 2>/dev/null || { echo "could not build the window lister"; exit 2; }
PORT=$((19100 + RANDOM % 90)); DATA=/tmp/glass/lab/data-win; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 "$BIN" >/dev/null 2>&1 & PID=$!
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
for t in 3 8 15; do
  sleep $([ $t = 3 ] && echo 3 || echo $((t - 3)))
  SEEN=$("$TOOL" $PID | grep '^window' | grep 'onscreen=true' | grep -v 'alpha=0.0')
  [ -z "$SEEN" ] && ok "after ${t} s no window of the test copy is visible" || { no "after ${t} s a window is visible:"; echo "$SEEN" | sed 's/^/        /'; }
done
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "HEADLESS INVISIBLE: all checks passed" || echo "HEADLESS INVISIBLE: FAILED"
exit $fail
