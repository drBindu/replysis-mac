#!/bin/bash
# Windows MAC_CATCHUP items of 2026-10-21 to 2026-10-25, part 1. The REAL app (Debug, invisible) against the fake server:
#  A. Finish pressed while an answer is being written waits for it, then finishes (no "Answer still finishing, choose Finish again").
#  B. Bought minutes let a question through with 0 answers left.
#  C. A paid plan with answers left shows its answers, not "N min left".
#  D. The update notice: "on its way" when found, "ready" when staged, never while listening.
#  E. Invite a friend: asks the website with the sign-in, copies the link, offers WhatsApp. (The clipboard is put back afterwards.)
#   catchup_oct26.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
DATA=/tmp/glass/lab/data-oct26; OUT=/tmp/glass/lab/mock-oct26.out
launch() {   # launch <env assignments...>
  PORT=$((21000 + RANDOM % 90)); rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  env "$@" python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
  sleep 10
}
stop(){ kill $PID $MOCK 2>/dev/null; sleep 1; }
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
state(){ local L; L=$(wc -l < "$LOG"); cmd dump; sleep 2; sed -n "$((L+1)),\$p" "$LOG" | grep "FLOWSTATE: step" | tail -1; }

echo "A. Finish while an answer is being written"
launch MOCK_ASK_WORDS=150
cmd start; sleep 3; L=$(wc -l < "$LOG"); cmd "ask What is a hash map?"; sleep 1.5; cmd finish; sleep 9
NEW=$(sed -n "$((L+1)),\$p" "$LOG")
echo "$NEW" | grep -q "Answer still finishing" && no "Finish refused with 'Answer still finishing'" || ok "Finish did not refuse"
echo "$NEW" | grep -q "Finish pressed while an answer is being written" && ok "Finish waited for the answer" || no "Finish did not wait"
fin=$(echo "$NEW" | grep -n "INTERVIEW: session .* finished" | head -1 | cut -d: -f1); done_at=$(echo "$NEW" | grep -n "LATENCY: complete\|finishAI\|ANSWER: done\|answer complete" | head -1 | cut -d: -f1)
[ -n "$fin" ] && ok "the session finished and opened in Past sessions" || no "the session never finished"
S=$(state); echo "$S" | grep -q "sessions=true" && ok "Past sessions is open" || no "Past sessions is not open"
stop

echo "B. Bought minutes, 0 answers"
launch MOCK_CREDITS=0 MOCK_MINUTES=45
cmd start; sleep 3; cmd "ask What is a queue?"; sleep 5
grep -q "REQ POST /api/v1/interview/ask -> 200" "$OUT" && ok "the question went to the server" || no "the question was stopped in the app"
S=$(state); echo "$S" | grep -q "alert='No answers left\|alert='Your free answers are used" && no "told 'no answers left' with 45 minutes" || ok "not told 'no answers left'"
stop

echo "C. A paid plan with answers left"
launch MOCK_PLAN=pro MOCK_CREDITS=300 MOCK_MINUTES=14
S=$(state); echo "$S" | grep -q "min left" && { no "the badge shows minutes on a paid plan"; echo "        $S" | cut -c1-200; } || ok "the badge shows answers ($(echo "$S" | sed -n "s/.*badge='\([^']*\)'.*/\1/p"))"
stop

echo "D. The update notice"
launch
cmd updatefound; S=$(state); echo "$S" | grep -q "update='Replysis AI 9.9.9 is on its way'" && ok "found: 'is on its way'" || { no "no 'on its way' notice"; echo "        $S" | cut -c1-260; }
cmd start; sleep 3; cmd updateready; S=$(state); echo "$S" | grep -q "update=''" && ok "during the interview: no notice" || no "a notice showed during the interview"
cmd back; sleep 2; S=$(state); echo "$S" | grep -q "update='Replysis AI 9.9.9 is ready'" && ok "back in setup: 'is ready'" || { no "no 'ready' notice"; echo "        $S" | cut -c1-260; }
stop

echo "E. Invite a friend"
CLIP=$(pbpaste 2>/dev/null)
launch
cmd invite; sleep 3
grep -q "^REFERRAL auth=yes" "$OUT" && ok "asked the website with the sign-in" || no "the website was not asked"
[ "$(pbpaste)" = "https://replysis.com/r/TEST123" ] && ok "the link is on the clipboard" || no "the link was not copied"
S=$(state); echo "$S" | grep -q "alert='Invite link copied'" && ok "says 'Invite link copied'" || no "no notice"
printf "%s" "$CLIP" | pbcopy
stop

[ $fail -eq 0 ] && echo "CATCHUP OCT26: all checks passed" || echo "CATCHUP OCT26: FAILED"
exit $fail
