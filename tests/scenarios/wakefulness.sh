#!/bin/bash
# Never slowed, never asleep mid-call (Windows 1.0.31 item 26): the app is out of App Nap for its whole life without keeping the Mac
# awake, the Mac is kept from idle sleep only while an interview session runs, and after a wake the answer connection is already fresh.
# Starts the REAL app (a Debug build, invisible, against a fake server) and reads the system's own list of sleep assertions.
#   wakefulness.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
PORT=$((18800 + RANDOM % 90)); DATA=/tmp/glass/lab/data-awake; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","screenAnswers":false}' > "$DATA/settings.json"
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
L=$(wc -l < "$LOG")
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
held(){ pmset -g assertions 2>/dev/null | grep -F "pid $PID" | grep -c "PreventUserIdleSystemSleep"; }
since(){ sed -n "$((L+1)),\$p" "$LOG"; }
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
sleep 10
[ "$(held)" = "0" ] && ok "on the Setup page the Mac is not kept awake (a Mac left open sleeps normally)" || no "kept awake on the Setup page"
since | grep -q "AWAKE: App Nap cannot slow the app" && ok "from launch App Nap is told the app is latency critical" || no "no App Nap hold at launch"
cmd start; sleep 4
[ "$(held)" -ge 1 ] && ok "during an interview the Mac is kept from idle sleep" || no "not kept awake during an interview"
pmset -g assertions 2>/dev/null | grep -F "pid $PID" | sed 's/^ *//' | cut -c1-170 | sed 's/^/        /'
cmd back; sleep 4
[ "$(held)" = "0" ] && ok "back on Setup the sleep hold is released" || no "still held after going back to Setup"
cmd start; sleep 3
[ "$(held)" -ge 1 ] && ok "a second interview holds it again" || no "second interview did not hold it"
cmd finish; sleep 5
[ "$(held)" = "0" ] && ok "finishing the interview releases it" || no "still held after finishing"
# A wake: the old connection is dropped and a new one opened before anyone asks
cmd start; sleep 3
cmd wakenote; sleep 5
since | grep -q "NET: connections reset" && ok "on wake the old connections are dropped and a fresh one opens" || no "no connection refresh on wake"
cmd "ask What is a mutex?"; sleep 6
# The fake server closes every connection, so reuse cannot be shown here; the live server shows REUSED (see the soak notes).
since | grep -q "LATENCY: first token" && ok "the first question after the wake is answered at once" || no "no answer to the first question after the wake"
kill $PID 2>/dev/null; kill $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "WAKEFULNESS: all checks passed" || echo "WAKEFULNESS: FAILED"
exit $fail
