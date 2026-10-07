#!/bin/bash
# Runs the REAL Mac app (a Debug build) against the fake server's "screen-lab" scenario and shows what the
# screen path does on a fast line, on a slow line, and on a weak line (the fake server reads every body no
# faster than MOCK_UPLINK_KBPS, which is how the 66 KB/s hotspot is imitated on loopback).
#   screen_lab.sh <path-to-Debug-InterviewCopilot.app> <mode> [picture.png]
#   modes: fast           a quick line: pictures go ahead
#          weak           66 KB/s, the real line test decides (it should fail and send words)
#          weak-picture   66 KB/s, forced to keep sending pictures (what a weak line cost before)
#          forced-words   a quick line, forced to send words
# Debug builds only. A stand-in picture is used instead of the screen, so there is no permission prompt.
APP="$1"; MODE="$2"; IMG="${3:-/tmp/glass/lab/screen.png}"
BIN="$APP/Contents/MacOS/InterviewCopilot"
[ -x "$BIN" ] || { echo "no app at $APP"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
DATA=/tmp/glass/lab/data-$MODE
PORT=$((18300 + RANDOM % 400))
rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
echo '{"listeningMode":"manual","screenAnswers":true}' > "$DATA/settings.json"
case "$MODE" in
  fast)          KBPS=0;  LINE="" ;;
  weak)          KBPS=66; LINE="" ;;
  weak-picture)  KBPS=66; LINE="fast" ;;
  forced-words)  KBPS=0;  LINE="slow" ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
MOCK_UPLINK_KBPS=$KBPS MOCK_SCREEN_NEED=$MOCK_SCREEN_NEED python3 "$HERE/mock_backend.py" screen-lab $PORT >/tmp/glass/lab/mock-$MODE.out 2>&1 & MOCK=$!; sleep 1
L=$(wc -l < "$LOG")
env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale \
  REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch REPLYSIS_SCREEN_IMAGE="$IMG" ${LINE:+REPLYSIS_LINE=$LINE} \
  "$BIN" >/dev/null 2>&1 & PID=$!
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
sleep 9                                   # the window settles and the session restores
cmd start; sleep 3
cmd micseen
[ "$MODE" = "weak" ] && { cmd probe; sleep 7; }       # the line test, as at launch
[ "$MODE" != "weak" ] && sleep 6                       # a few 2 second ticks send the screen ahead
cmd linestate; sleep 1
[ "$MODE" = "weak" ] && sleep 8
cmd "ask ${LAB_ASK:-Can you solve this problem on my screen?}"
[ -n "$LAB_SAMPLE" ] && { sleep 0.3; sample $PID 1 1 -file /tmp/glass/lab/sample.txt >/dev/null 2>&1; }
sleep 22
[ -n "$LAB_SNAP" ] && { cmd snap-answer; sleep 4; cp "$DATA/snapshot-answer.png" /tmp/glass/lab/answer-$MODE.png 2>/dev/null; }
[ -n "$LAB_WAKE" ] && { cmd wakenote; sleep 6; }
cmd dump; sleep 1
kill -0 $PID 2>/dev/null && echo "app still running: yes" || echo "app still running: NO (it died)"
echo "=== $MODE (uplink ${KBPS} KB/s)"
echo "-- server saw:"; grep -E 'REQ POST .*(screen-cache|analyze-screen)' /tmp/glass/lab/mock-$MODE.out | cut -c1-230 | sed 's/^/   /'
echo "-- the app said:"
sed -n "$((L+1)),\$p" "$LOG" | grep -E "SCREEN|LATENCY: screen|FLOWSTATE|NET: (first token|request task)|WAKE" | grep -v 'preparing screenshots' | sed 's/^\[[0-9:.]*\] //' | cut -c1-260 | sed 's/^/   /' | head -40
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; kill $MOCK 2>/dev/null
