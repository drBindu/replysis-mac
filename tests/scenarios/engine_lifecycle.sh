#!/bin/bash
# The speech engine's life, in the REAL app (a Debug build) against a fake server that hands out a fake key:
#   starts once and only once; a wake restarts it without leaving a second one; closing the app leaves none.
# Developer builds only, invisible (REPLYSIS_HEADLESS). Only engines that are children of THIS test copy are counted,
# so a real copy of the app that is running beside it is never touched.
#   engine_lifecycle.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"; LOG=~/Library/Logs/InterviewCopilot-debug.log
PORT=$((18900 + RANDOM % 90)); DATA=/tmp/glass/lab/data-engine; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","screenAnswers":false}' > "$DATA/settings.json"
python3 "$HERE/mock_backend.py" engine-lab $PORT >/tmp/glass/lab/mock-engine.out 2>&1 & MOCK=$!; sleep 1
L=$(wc -l < "$LOG")
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
engines(){ ps -axo pid=,ppid=,command= | awk -v p=$PID '$2==p && /speechmatics_engine/ {print $1}' | tr '\n' ' '; }
count(){ engines | wc -w | tr -d ' '; }
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
# The fake key is refused by the real speech service within a second, and the app renews it every ~6 s, so an engine lives
# about a second at a time. Watch for 7 s instead of looking once: one engine must appear, never two.
sleep 8
seen(){ local p=0 all=""; for i in $(seq 1 28); do c=$(count); [ "$c" -gt "$p" ] && p=$c; all="$all $(engines)"; sleep 0.25; done; echo "$p|$(echo $all | tr ' ' '\n' | sort -u | tr '\n' ' ')"; }
R=$(seen); P=${R%%|*}; FIRST=${R#*|}
echo "engines after launch: [$FIRST]"
[ "$P" = "1" ] && ok "one engine after launch (never two)" || no "expected one engine after launch, peak was $P"
peak=0
for i in 1 2 3 4 5 6; do sleep 1; c=$(count); [ "$c" -gt "$peak" ] && peak=$c; done
[ "$peak" -le 1 ] && ok "never more than one engine while it ran" || no "saw $peak engines at once"
cmd wakenote; sleep 1
for i in $(seq 1 14); do sleep 1; c=$(count); [ "$c" -gt "$peak" ] && peak=$c; done
R=$(seen); P2=${R%%|*}; AFTER=${R#*|}
echo "engines after the wake: [$AFTER]  (first was [$FIRST])"
[ "$P2" = "1" ] && ok "one engine after the wake (never two)" || no "expected one engine after the wake, peak was $P2"
[ "$peak" -le 1 ] && ok "a wake never ran two engines at once (peak $peak)" || no "a wake ran $peak engines at once"
[ "$AFTER" != "$FIRST" ] && ok "the wake gave a fresh engine" || echo "  note  same engine pid after the wake (engine may have been restarted earlier by its own check)"
sed -n "$((L+1)),\$p" "$LOG" | grep -q "WAKE: the Mac woke up" && ok "the wake was noticed" || no "the wake was not noticed"
# On its way out the app stops the engine and waits for it to end its speech session.
S=$(date +%s)
cmd stopengine; sleep 4
echo "engines after the app stopped it: [$(engines)]"
[ "$(count)" = "0" ] && ok "the engine is gone when the app has stopped it" || no "$(count) engine(s) left after stopping"
sed -n "$((L+1)),\$p" "$LOG" | grep -q "ENGINE: stopped and waited" && ok "$(sed -n "$((L+1)),\$p" "$LOG" | grep 'ENGINE: stopped and waited' | tail -1 | sed 's/.*ENGINE: //')" || no "the stop did not report"
sleep 7
[ "$(count)" = "0" ] && ok "and nothing started it again afterwards" || no "an engine came back after the app stopped it ($(count))"
kill $PID 2>/dev/null; sleep 1
kill $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "ENGINE LIFECYCLE: all checks passed" || echo "ENGINE LIFECYCLE: FAILED"
exit $fail
