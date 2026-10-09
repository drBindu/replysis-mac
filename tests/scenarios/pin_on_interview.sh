#!/bin/bash
# Pin on top is an interview control (owner, 2026-10-09; Windows: Topmost = interview started && pinned). On the Setup page the main window is an
# ordinary one (window layer 0); while an interview runs and the pin is on it floats above other apps (layer 3); with the pin off it stays
# ordinary; when the interview ends it is ordinary again. Starts the REAL app (a Debug build, invisible) and reads the window's layer from the
# window server. The pin button itself is only drawn during an interview (checked through accessibility).
#   pin_on_interview.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
PORT=$((19800 + RANDOM % 90)); DATA=/tmp/glass/lab/data-pin; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","keepOnTop":true}' > "$DATA/settings.json"
swiftc -O -o /tmp/windows_of "$HERE/windows_of.swift" 2>/dev/null; swiftc -O -o /tmp/login_probe "$HERE/login_probe.swift" 2>/dev/null
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
# the layer of the main window: the widest window of the app that is not the 500x500 helper
layer(){ /tmp/windows_of $PID | grep "^window" | grep -v "w=500.0 h=500.0" | sed 's/.*layer=\([0-9-]*\).*w=\([0-9.]*\) h=.*/\2 \1/' | sort -rn | head -1 | cut -d' ' -f2; }
pins(){ /tmp/login_probe $PID all | grep -c "^BUTTON Pin "; }
sleep 10
[ "$(layer)" = "0" ] && ok "on Setup the window is an ordinary one (layer 0)" || no "on Setup the window floats (layer $(layer))"
[ "$(pins)" = "0" ] && ok "on Setup there is no pin button" || no "the pin button shows on Setup"
cmd start; sleep 4
[ "$(layer)" = "3" ] && ok "during an interview, pinned: the window floats (layer 3)" || no "during an interview the window does not float (layer $(layer))"
[ "$(pins)" -ge 1 ] && ok "during an interview the pin button is there" || no "no pin button during an interview"
cmd back; sleep 3
[ "$(layer)" = "0" ] && ok "back on Setup the window is ordinary again" || no "back on Setup the window still floats (layer $(layer))"
cmd start; sleep 3
cmd finish; sleep 5
[ "$(layer)" = "0" ] && ok "after finishing an interview the window is ordinary again" || no "after finishing the window still floats (layer $(layer))"
kill $PID $MOCK 2>/dev/null
# with the pin off, an interview does not float it either
echo '{"listeningMode":"manual","keepOnTop":false}' > "$DATA/settings.json"; rm -f "$DATA/flow.cmd"
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
sleep 10; cmd start; sleep 4
[ "$(layer)" = "0" ] && ok "with the pin off, an interview leaves the window ordinary" || no "with the pin off the window still floats (layer $(layer))"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "PIN ON INTERVIEW: all checks passed" || echo "PIN ON INTERVIEW: FAILED"
exit $fail
