#!/bin/bash
# The saved sign-in is old and the refresh cannot be done. Checks what the person is shown:
#   token-down     no connection yet: the app opens signed in, and never shows the sign-in screen
#   token-refused  the sign-in service refuses the saved sign-in: the sign-in screen is right
#   aged_login.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"; LOG=~/Library/Logs/InterviewCopilot-debug.log
fail=0
for sc in token-down token-refused; do
  port=$((18700 + RANDOM % 200)); DATA=/tmp/glass/lab/data-aged-$sc; rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
  pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
  python3 "$HERE/mock_backend.py" $sc $port >/tmp/glass/lab/mock-$sc.out 2>&1 & MOCK=$!; sleep 1
  L=$(wc -l < "$LOG")
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$port REPLYSIS_TOKEN_URL=http://127.0.0.1:$port/token REPLYSIS_TEST_SESSION=aged \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 "$BIN" >/dev/null 2>&1 & PID=$!
  sleep 22
  T=$(sed -n "$((L+1)),\$p" "$LOG")
  echo "=== $sc"
  echo "  refresh asked: $(grep -c 'POST /token' /tmp/glass/lab/mock-$sc.out) time(s)"
  echo "$T" | grep -E 'Session: |Guest session|opening with the saved|AUTH\]' | sed 's/^\[[0-9:.]*\] //' | cut -c1-200 | head -6 | sed 's/^/  /'
  if [ $sc = token-down ]; then
    echo "$T" | grep -q "opening with the saved sign-in" && echo "  PASS opened with the saved sign-in" || { echo "  FAIL did not open with the saved sign-in"; fail=1; }
    echo "$T" | grep -q "Guest session" && { echo "  FAIL tried a guest session (the sign-in screen path)"; fail=1; } || echo "  PASS no sign-in screen path"
  else
    echo "$T" | grep -q "opening with the saved sign-in" && { echo "  FAIL opened signed in on a refused sign-in"; fail=1; } || echo "  PASS a refused sign-in is not opened"
  fi
  pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; kill $MOCK 2>/dev/null; sleep 1
done
[ $fail -eq 0 ] && echo "AGED LOGIN: all checks passed" || echo "AGED LOGIN: FAILED"
exit $fail
