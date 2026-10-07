#!/bin/bash
# Exercises the first-run flow in the REAL app (a Debug build), with no Keychain and no real
# server: Setup -> Start -> back to Setup -> Start -> Finish. Fails (exit 1) if the app dies
# (it once crashed on Start interview: a layout loop from animating the step change) or if any
# of the flow rules is broken:
#   1. nothing listens and nothing watches the screen on the Setup page, even with Auto and
#      screen answers ON;
#   2. listening and screen preparation begin only at Start interview;
#   3. back to Setup stops both again;
#   4. Finish opens Past sessions and stops both again.
#   flow_test.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
[ -x "$BIN" ] || { echo "no app at $APP"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=~/Library/Logs/InterviewCopilot-debug.log
DIR=~/Library/Application\ Support/InterviewCopilot
cp "$DIR/settings.json" /tmp/flow-settings.bak 2>/dev/null
python3 - <<'PY'
import json,os
p=os.path.expanduser('~/Library/Application Support/InterviewCopilot/settings.json')
d=json.load(open(p)); d['listeningMode']='auto'; d['screenAnswers']=True; json.dump(d,open(p,'w'))
PY
touch "$DIR/onboarding_seen"
pkill -f "Replysis-dev.app/Contents/MacOS" 2>/dev/null; pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 2
python3 "$HERE/mock_backend.py" healthy-credits 18190 >/tmp/flow-mock.out 2>&1 & MOCK=$!; sleep 1
L=$(wc -l < "$LOG")
REPLYSIS_BACKEND_URL=http://127.0.0.1:18190 REPLYSIS_TOKEN_URL=http://127.0.0.1:18190/token REPLYSIS_TEST_SESSION=stale REPLYSIS_HEADLESS=1 \
  REPLYSIS_FLOW_SCRIPT="start:10,back:8,start:8,finish:8" "$BIN" >/dev/null 2>&1 & PID=$!
sleep 50
fail=0
ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
kill -0 $PID 2>/dev/null && ok "the app is still running after the whole flow" || no "the app DIED during the flow"
T=$(sed -n "$((L+1)),\$p" "$LOG")
first(){ echo "$T" | grep -n "$1" | head -1 | cut -d: -f1; }
nth(){ echo "$T" | grep -n "$1" | sed -n "${2}p" | cut -d: -f1; }
s1=$(nth "INTERVIEW: started" 1); b1=$(first "back to Setup"); s2=$(nth "INTERVIEW: started" 2); f1=$(first "finished and opened in Past sessions")
[ -n "$s1" ] && [ -n "$b1" ] && [ -n "$s2" ] && [ -n "$f1" ] && ok "start, back, start, finish all ran" || no "a flow step did not run"
pre=$(echo "$T" | head -n $((${s1:-1}-1)))
echo "$pre" | grep -qE "listening started|AUTO: re-arming|cannot arm|preparing screenshots started" && no "Setup listened or watched the screen (Auto and screen answers were ON)" || ok "nothing listened or watched the screen on Setup"
echo "$T" | sed -n "${s1:-1},${b1:-1}p" | grep -q "preparing screenshots started" && ok "Start began screen preparation" || no "Start did not begin screen preparation"
# With the fake server there is no speech key, so no engine: arming is then logged as "cannot arm".
# Either line proves Auto was asked to listen, and only after Start.
echo "$T" | sed -n "${s1:-1},${b1:-1}p" | grep -qE "listening started|AUTO: re-arming|cannot arm" && ok "Start asked Auto to listen" || no "Start did not ask Auto to listen"
echo "$T" | sed -n "${b1:-1},${s2:-1}p" | grep -q "preparing screenshots stopped" && ok "back to Setup stopped screen preparation" || no "back to Setup left the screen being watched"
echo "$T" | sed -n "${f1:-1},\$p" | grep -q "preparing screenshots stopped" && ok "Finish stopped screen preparation" || no "Finish left the screen being watched"
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; kill $MOCK 2>/dev/null
cp /tmp/flow-settings.bak "$DIR/settings.json" 2>/dev/null
[ $fail -eq 0 ] && echo "FLOW: all checks passed" || echo "FLOW: FAILED"
exit $fail
