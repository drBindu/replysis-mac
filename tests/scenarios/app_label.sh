#!/bin/bash
# Every request the app sends to its own server carries X-App-Platform: mac and the plain X-App-Version (Windows 1.0.31 item 28).
# Starts the REAL app (a Debug build, invisible, against a fake server that prints the two headers of every request), runs an
# interview with a spoken style question and a screen question, a wake and a sign-in refresh, and checks all of them.
# (That nothing is labelled for any OTHER host is checked by the regression suite, which has the host rule as a pure function.)
#   app_label.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=$((18900 + RANDOM % 90)); DATA=/tmp/glass/lab/data-label; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","screenAnswers":true}' > "$DATA/settings.json"
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
python3 "$HERE/mock_backend.py" healthy-credits $PORT > /tmp/glass/lab/mock-label.out 2>&1 & MOCK=$!; sleep 1
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch REPLYSIS_SCREEN_IMAGE=/tmp/glass/lab/screen.png "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
sleep 10; cmd micseen; cmd start; sleep 6
cmd "ask What is a mutex?"; sleep 5
cmd "ask Can you solve this problem on my screen?"; sleep 10
cmd wakenote; sleep 5
cmd back; sleep 3
kill $PID 2>/dev/null; kill $MOCK 2>/dev/null
TOTAL=$(grep -c '^HDR ' /tmp/glass/lab/mock-label.out)
GOOD=$(grep '^HDR ' /tmp/glass/lab/mock-label.out | grep -c -E 'platform=mac version=[0-9]+(\.[0-9]+)+$')
[ "$TOTAL" -ge 10 ] && ok "the app made $TOTAL requests to its server in this run" || no "only $TOTAL requests seen"
[ "$GOOD" = "$TOTAL" ] && ok "every one of them carries X-App-Platform: mac and a plain X-App-Version" || { no "$((TOTAL-GOOD)) of $TOTAL requests are missing the labels"; grep '^HDR ' /tmp/glass/lab/mock-label.out | grep -v -E 'platform=mac version=[0-9]+(\.[0-9]+)+$' | sort | uniq -c | head; }
for p in /api/v1/interview/ask /api/v1/interview/analyze-screen /api/v1/interview/screen-cache /api/v1/resume/status; do
  grep '^HDR ' /tmp/glass/lab/mock-label.out | grep -q " $p " && ok "labelled: $p" || echo "  note  no request to $p in this run"
done
grep '^HDR HEAD' /tmp/glass/lab/mock-label.out | grep -q 'platform=mac' && ok "the keep-warm request carries the label too" || no "keep-warm request unlabelled or missing"
HEADS=$(grep -c '^HDR HEAD' /tmp/glass/lab/mock-label.out)
[ "$HEADS" -ge 8 ] && ok "keep-warm pings every 5 seconds ($HEADS in about 45 s)" || no "only $HEADS keep-warm pings in about 45 s"
grep '^HDR ' /tmp/glass/lab/mock-label.out | awk '{print $2" "$3}' | sort | uniq -c | sort -rn | head -12 | sed 's/^/        /'
[ $fail -eq 0 ] && echo "APP LABEL: all checks passed" || echo "APP LABEL: FAILED"
exit $fail
