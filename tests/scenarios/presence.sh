#!/bin/bash
# "This app is open" (Windows 1.0.31 item 29): POST /api/v1/presence with the Bearer token and the two labels, no body, answered 204;
# at once, with ?listening=1, when a session starts and without it when it stops; and DELETE /api/v1/presence when the app quits,
# waiting for it 1.5 s at most. Runs the REAL app (a Debug build, invisible) against the fake server with the ordinary ping every 20 s
# so anything that comes sooner can only be the immediate one. Then quits it against a server that answers the DELETE only after 6 s.
#   presence.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/glass/lab/mock-presence.out; DATA=/tmp/glass/lab/data-presence
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
launch(){  # $1 = mock delay for the DELETE answer
  PORT=$((19300 + RANDOM % 90)); rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
  echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
  MOCK_PRESENCE_DELAY=$1 python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale REPLYSIS_TEST_USER=presence-user \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch REPLYSIS_PRESENCE_SECONDS=20 "$BIN" >/dev/null 2>&1 & PID=$!
}
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
lines(){ grep '^PRESENCE' "$OUT"; }
count(){ lines | grep -c "$1"; }
total(){ lines | wc -l | tr -d ' '; }
launch 0
sleep 10
N0=$(total)
[ "$N0" -ge 1 ] && ok "the app is open and signed in: a ping is already there ($N0)" || no "no ping in the first 10 s"
[ "$(lines | grep -c 'listening=yes')" = "0" ] && ok "before any session the pings carry no listening flag" || no "listening flag with no session"
cmd start; sleep 3
lines | tail -1 | grep -q 'POST listening=yes' && ok "a session started: a ping with ?listening=1 went out at once (the ordinary ping is 20 s apart)" || { no "no immediate ping when a session started"; lines | tail -3 | sed 's/^/        /'; }
sleep 22
[ "$(lines | tail -2 | grep -c 'listening=yes')" -ge 1 ] && ok "while the session runs, the ordinary ping keeps the flag" || no "the ordinary ping dropped the flag during a session"
cmd back; sleep 3
lines | tail -1 | grep -q 'POST listening=no' && ok "the session stopped: a plain ping went out at once" || { no "no immediate plain ping when the session stopped"; lines | tail -3 | sed 's/^/        /'; }
[ "$(count 'auth=bearer')" = "$(total)" ] && ok "every message carried the Bearer token" || no "a message had no token"
[ "$(count 'body=0')" = "$(total)" ] && ok "no message had a body" || no "a message had a body"
[ "$(count 'platform=mac version=[0-9][0-9.]*')" = "$(total)" ] && ok "every message carried the platform and version" || no "a message lacked the labels"
# Quit while the server answers the DELETE at once
cmd start; sleep 3; cmd back; sleep 3
T0=$(python3 -c 'import time;print(f"{time.time():.3f}")'); cmd quitapp
for i in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 0.1; done
T1=$(python3 -c 'import time;print(f"{time.time():.3f}")')
D=$(count '^PRESENCE DELETE')
[ "$D" -ge 1 ] && ok "the app quit and told the server (DELETE)" || no "no DELETE on quit"
python3 -c "import sys;print('        the app was gone ' + str(round($T1-$T0,2)) + ' s after the quit request')"
kill $MOCK 2>/dev/null
# Quit while the server takes 6 s to answer: the quit must not wait for it
launch 6
sleep 9; cmd start; sleep 3; cmd back; sleep 3
T0=$(python3 -c 'import time;print(f"{time.time():.3f}")'); cmd quitapp
for i in $(seq 1 100); do kill -0 $PID 2>/dev/null || break; sleep 0.1; done
T1=$(python3 -c 'import time;print(f"{time.time():.3f}")')
GONE=$(python3 -c "print(round($T1-$T0,2))")
python3 -c "import sys;sys.exit(0 if $GONE < 4.0 else 1)" && ok "the server answered the DELETE only after 6 s, and the app was gone in $GONE s (the wait is capped)" || no "the quit waited $GONE s for a slow server"
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "PRESENCE: all checks passed" || echo "PRESENCE: FAILED"
exit $fail
