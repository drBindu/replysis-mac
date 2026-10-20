#!/bin/bash
# India gets its own screening options, detected and never chosen (Windows MAC_CATCHUP item 56, 2026-10-16). Runs the REAL app (a Debug build,
# invisible) against the fake server, whose /api/geo answers the country. For IN the Setup page offers Notice period and Other offers (no
# Authorization, no Can start) and the question sent to the model carries "Notice period:" and "Other offers:" lines and no work
# authorization; for US it is the old pickers and no notice lines.
#   india_screening.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
swiftc -O -o /tmp/login_probe "$HERE/login_probe.swift" 2>/dev/null
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
run() {   # run <label> <country> <expect india: yes|no>
  local label="$1" country="$2" india="$3" PORT=$((20700 + RANDOM % 90)) DATA=/tmp/glass/lab/data-india OUT=/tmp/glass/lab/mock-india.out
  rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  # a saved job context holding both countries' answers: only the detected country's reach the prompt
  echo '{"company":"","description":"","workType":"Full time","workAuth":"H1B","canStart":"Immediately","workLocation":"Remote","payRate":"","inWorkType":"Full time / permanent","inNotice":"30 days","inOffers":"Have an offer in hand","inWorkLocation":"Hybrid","inPay":""}' > "$DATA/job.json"
  MOCK_COUNTRY=$country python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & local MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & local PID=$!
  sleep 10
  local B; B=$(/tmp/login_probe $PID all)
  if [ "$india" = yes ]; then
    echo "$B" | grep -qi "NOTICE PERIOD" && echo "$B" | grep -qi "OTHER OFFERS" && ! echo "$B" | grep -qi "AUTHORIZATION" && ok "$label: Setup offers Notice period and Other offers, not Authorization" || { no "$label: wrong pickers on Setup"; echo "$B" | grep -i "period\|offers\|author\|can start" | cut -c1-90 | sed 's/^/        /'; }
  else
    echo "$B" | grep -qi "AUTHORIZATION" && ! echo "$B" | grep -qi "NOTICE PERIOD" && ok "$label: Setup offers Authorization and Can start, not Notice period" || no "$label: wrong pickers on Setup"
  fi
  echo micseen >> "$DATA/flow.cmd"; echo start >> "$DATA/flow.cmd"; sleep 4; echo "ask What is a mutex?" >> "$DATA/flow.cmd"; sleep 6
  if [ "$india" = yes ]; then
    grep -q "^ASK-PROMPT notice=True offers=True auth=False" "$OUT" && ok "$label: the question carries Notice period and Other offers and no work authorization" || { no "$label: the prompt is wrong"; grep "^ASK-PROMPT" "$OUT" | head -1 | sed 's/^/        /'; }
  else
    grep -q "^ASK-PROMPT notice=False offers=False auth=True" "$OUT" && ok "$label: the question carries work authorization and no notice period" || { no "$label: the prompt is wrong"; grep "^ASK-PROMPT" "$OUT" | head -1 | sed 's/^/        /'; }
  fi
  kill $PID $MOCK 2>/dev/null; sleep 1
}
run "India (the site says IN)" IN yes
run "United States (the site says US)" US no
[ $fail -eq 0 ] && echo "INDIA SCREENING: all checks passed" || echo "INDIA SCREENING: FAILED"
exit $fail
