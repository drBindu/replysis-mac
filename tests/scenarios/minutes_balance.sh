#!/bin/bash
# India pays by the minute (Windows MAC_CATCHUP item 57, 2026-10-16). Runs the REAL app (a Debug build, invisible) against a fake server that
# says the person has 2 bought minutes and a bank that wants approval. The badge must say "2 min left" (not the answers), a minute of
# listening reported with 2 left must ask the website to auto add 15 (once, not again within three minutes), the answer
# {needsApproval, a checkout.stripe.com address} must put up the notice "Your minutes are almost over" with an "Add 15 minutes" button, and
# nothing may be opened by itself. A person with no bought minutes is never asked.
#   minutes_balance.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
run() {   # run <label> <MOCK_MINUTES or empty> <expect: asked|not>
  local label="$1" minutes="$2" want="$3" PORT=$((20800 + RANDOM % 90)) DATA=/tmp/glass/lab/data-minutes OUT=/tmp/glass/lab/mock-minutes.out
  rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  MOCK_MINUTES=$minutes MOCK_MINUTES_ADD=approval python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & local MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & local PID=$!
  cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
  state(){ L=$(wc -l < "$LOG"); cmd dump; sleep 2; sed -n "$((L+1)),\$p" "$LOG" | grep "FLOWSTATE: step" | tail -1; }
  sleep 10; local S; S=$(state)
  if [ "$want" = asked ]; then
    echo "$S" | grep -q "badge='2 min left'" && ok "$label: the badge says 2 min left" || { no "$label: the badge is wrong"; echo "        $S" | cut -c1-240; }
  else
    echo "$S" | grep -q "min left" && no "$label: the badge shows minutes for someone who bought none" || ok "$label: the badge keeps the answers"
  fi
  cmd reportminutes; sleep 5
  local N; N=$(grep -c "^MINUTES-ADD" "$OUT")
  if [ "$want" = asked ]; then
    [ "$N" = "1" ] && ok "$label: with 2 minutes left the website is asked to auto add (once)" || no "$label: the website was asked $N times"
    grep "^MINUTES-ADD" "$OUT" | head -1 | grep -q '"action":"add"' && grep "^MINUTES-ADD" "$OUT" | head -1 | grep -q "auth=yes" && ok "$label: the request is {\"action\":\"add\"} with the sign-in" || no "$label: the request is wrong"
    S=$(state)
    echo "$S" | grep -q "alert='Your minutes are almost over'" && ok "$label: the bank wants approval, so the notice shows" || { no "$label: no notice"; echo "        $S" | cut -c1-240; }
    cmd reportminutes; sleep 4; N=$(grep -c "^MINUTES-ADD" "$OUT")
    [ "$N" = "1" ] && ok "$label: a second minute does not ask again within three minutes" || no "$label: asked again ($N)"
  else
    [ "$N" = "0" ] && ok "$label: nothing is asked of someone who bought no minutes" || no "$label: the website was asked $N times"
  fi
  kill $PID $MOCK 2>/dev/null; sleep 1
}
run "two bought minutes" 2 asked
run "no bought minutes" "" not
[ $fail -eq 0 ] && echo "MINUTES BALANCE: all checks passed" || echo "MINUTES BALANCE: FAILED"
exit $fail
