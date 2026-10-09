#!/bin/bash
# The quit message must carry a token the server accepts. After a long sleep the saved token is an hour old; the first version sent it anyway
# and the live server answered 401, so the admin panel kept the Mac for another two minutes. Runs the REAL app (a Debug build, invisible)
# against a fake server that refuses stale tokens with 401, ages the token the way a long sleep does (or makes the server refuse one that
# looks fine), quits, and checks the message that reached the server last.
#   presence_quit_token.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/glass/lab/mock-presence-token.out; DATA=/tmp/glass/lab/data-presence-token
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
run(){  # $1 = flow action that spoils the token
  PORT=$((19500 + RANDOM % 90)); rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
  echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
  python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale REPLYSIS_TEST_USER=presence-user \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch REPLYSIS_PRESENCE_SECONDS=30 "$BIN" >/dev/null 2>&1 & PID=$!
  sleep 12
  echo "$1" >> "$DATA/flow.cmd"; sleep 1
  M=$(wc -l < "$OUT")
  T0=$(python3 -c 'import time;print(f"{time.time():.3f}")'); echo quitapp >> "$DATA/flow.cmd"
  for i in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 0.1; done
  T1=$(python3 -c 'import time;print(f"{time.time():.3f}")')
  GONE=$(python3 -c "print(round($T1-$T0,2))"); AFTER=$(tail -n +$((M+1)) "$OUT")
  kill $PID $MOCK 2>/dev/null
}
run agetoken
echo "$AFTER" | grep -q "REQ POST /token" && ok "after a long sleep the token is refreshed before the quit message" || no "no token refresh before the quit message"
echo "$AFTER" | grep '^PRESENCE DELETE' | tail -1 | grep -q 'auth=fresh status=204' && ok "and the quit message that arrived carried the fresh token and was accepted (204)" || { no "the quit message did not carry a fresh token"; echo "$AFTER" | grep '^PRESENCE' | sed 's/^/        /'; }
echo "$AFTER" | grep -c '^PRESENCE DELETE' | grep -q '^1$' && ok "exactly one quit message was sent" || no "more than one quit message after a refresh that worked"
python3 -c "import sys;sys.exit(0 if $GONE < 3.0 else 1)" && ok "the app was gone $GONE s after the quit request" || no "the quit took $GONE s"
run staletoken
echo "$AFTER" | grep '^PRESENCE DELETE' | head -1 | grep -q 'auth=stale status=401' && ok "a token that looks fine but is refused: the first quit message is answered 401" || no "expected a first refusal"
echo "$AFTER" | grep '^PRESENCE DELETE' | tail -1 | grep -q 'auth=fresh status=204' && ok "then the token is refreshed and the message sent again, and accepted (204)" || { no "no second, accepted quit message"; echo "$AFTER" | grep '^PRESENCE' | sed 's/^/        /'; }
python3 -c "import sys;sys.exit(0 if $GONE < 3.0 else 1)" && ok "the app was gone $GONE s after the quit request" || no "the quit took $GONE s"
[ $fail -eq 0 ] && echo "PRESENCE QUIT TOKEN: all checks passed" || echo "PRESENCE QUIT TOKEN: FAILED"
exit $fail
