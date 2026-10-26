#!/bin/bash
# The phone Companion and "Answers on my phone only" (Windows MAC_CATCHUP 2026-10-24/25). The REAL app (Debug, invisible) against the
# fake server, which records what the laptop reports to /api/v1/companion/laptop and hands out the phone's commands.
#   companion.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
DATA=/tmp/glass/lab/data-companion; OUT=/tmp/glass/lab/mock-companion.out; CMDF=/tmp/glass/lab/phone-command
launch() {
  PORT=$((21200 + RANDOM % 90)); rm -rf "$DATA" "$CMDF"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  env "$@" MOCK_COMMAND_FILE=$CMDF python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
  sleep 10
}
stop(){ kill $PID $MOCK 2>/dev/null; sleep 1; }
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
state(){ local L; L=$(wc -l < "$LOG"); cmd dump; sleep 2; sed -n "$((L+1)),\$p" "$LOG" | grep "FLOWSTATE: step" | tail -1; }

echo "No phone watching"
launch MOCK_PHONES=0
cmd start; sleep 4
grep -q '^COMPANION {"listening":true,"heard":""} auth=yes\|^COMPANION {"heard":"","listening":true} auth=yes' "$OUT" && ok "listening is reported, with no words and with the sign-in" || { no "no listening report"; grep "^COMPANION" "$OUT" | head -3 | sed 's/^/        /'; }
cmd "ask What is a binary tree?"; sleep 5
grep "^COMPANION" "$OUT" | grep -q "binary tree" && no "words were sent with no phone watching" || ok "no words are sent while no phone watches"
stop

echo "A phone watching"
launch MOCK_PHONES=1
cmd start; sleep 3; cmd "ask What is a binary tree?"; sleep 3
grep "^COMPANION" "$OUT" | grep -q "binary tree" && ok "the phone gets the words heard" || { no "the phone did not get the words"; grep "^COMPANION" "$OUT" | tail -3 | sed 's/^/        /'; }
L=$(wc -l < "$LOG"); echo answer > $CMDF; sleep 5
sed -n "$((L+1)),\$p" "$LOG" | grep -q "Answer asked from the phone" && ok "Answer on the phone reaches the laptop" || no "Answer from the phone was lost"
sed -n "$((L+1)),\$p" "$LOG" | grep -q "SPACE from PHONE\|from PHONE" && ok "and works like Space" || no "Answer did not act like Space"
L=$(wc -l < "$LOG"); echo stop > $CMDF; sleep 6
sed -n "$((L+1)),\$p" "$LOG" | grep -q "INTERVIEW: session .* finished" && ok "Stop on the phone finishes the interview" || no "Stop on the phone did not finish"
stop

echo "Answers on my phone only"
launch MOCK_PHONES=0
cmd phoneonly-on; sleep 1; cmd start; sleep 3
S=$(state); echo "$S" | grep -q "phoneonly=true" && ok "Start hides Replysis on this Mac" || { no "not hidden"; echo "        $S" | cut -c1-260; }
echo "$S" | grep -q "auto=true" && ok "and switches to Auto (nobody can press Space on a hidden window)" || no "still Manual"
grep -q '"phoneOnly":true' "$DATA/settings.json" && ok "the setting is saved" || no "the setting was not saved"
stop

[ $fail -eq 0 ] && echo "COMPANION: all checks passed" || echo "COMPANION: FAILED"
exit $fail
