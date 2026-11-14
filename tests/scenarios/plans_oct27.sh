#!/bin/bash
# MAC_HANDOFF_2026-10-27 items 1 to 3. Runs the REAL app (a Debug build, invisible) against a fake server:
#   the 3 day free trial (plan "pro", trial true) reads "Free trial", never Pro;
#   a trial or free account out of answers gets "Upgrade now" (the plans page), pressing for an answer included;
#   a paid plan out of answers keeps "Get more answers"; Practice is a paid plan.
#   plans_oct27.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
run() {   # run <label> <plan> <trial 0|1> <credits> <want plan text> <want alert or empty> <want button or empty>
  local label="$1" plan="$2" trial="$3" credits="$4" wantPlan="$5" wantAlert="$6" wantButton="$7"
  local PORT=$((20900 + RANDOM % 90)) DATA=/tmp/glass/lab/data-plans OUT=/tmp/glass/lab/mock-plans.out
  rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  MOCK_PLAN=$plan MOCK_TRIAL=$trial MOCK_CREDITS=$credits python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & local MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & local PID=$!
  cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
  state(){ L=$(wc -l < "$LOG"); cmd dump; sleep 2; sed -n "$((L+1)),\$p" "$LOG" | grep "FLOWSTATE: step" | tail -1; }
  sleep 10; local S; S=$(state)
  echo "$S" | grep -q "plan='$wantPlan'" && ok "$label: reads '$wantPlan'" || { no "$label: plan text is wrong"; echo "        $S" | grep -o "badge='[^']*' plan='[^']*'"; }
  echo "$S" | grep -qi "plan='Pro" && [ "$trial" = 1 ] && no "$label: the trial shows Pro"
  if [ -n "$wantAlert" ]; then
    L=$(wc -l < "$LOG"); cmd "ask What is a queue?"; sleep 3
    S=$(state)
    echo "$S" | grep -q "alert='$wantAlert'" && ok "$label: pressing for an answer says '$wantAlert'" || { no "$label: no out of answers notice"; echo "        $S" | grep -o "alert='[^']*'"; }
    sed -n "$((L+1)),\$p" "$LOG" | grep -q "OUT-OF-ANSWERS-BUTTON: $wantButton" && ok "$label: the button is '$wantButton'" || no "$label: the button is not '$wantButton'"
  fi
  kill $PID $MOCK 2>/dev/null; sleep 1
}
run "3 day free trial"            pro      1 250 "Free trial"
run "3 day free trial, used up"   pro      1 0   "Upgrade now"  "Your free answers are used" "Upgrade now"
run "free plan, used up"          free     0 0   "Upgrade now"  "Your free answers are used" "Upgrade now"
run "Pro"                         pro      0 250 "Pro plan"
run "Practice"                    practice 0 250 "Practice plan"
run "Max, used up"                max      0 0   "Get more answers" "No answers left this month" "Get more answers"
[ $fail -eq 0 ] && echo "PLANS OCT27: all checks passed" || echo "PLANS OCT27: FAILED"
exit $fail
