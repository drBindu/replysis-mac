#!/bin/bash
# Sign in first (owner, 2026-10-16: "without sign in why is there the setup page? first only the sign-in page, then the setup, and if I sign
# out go back to the sign-in page"). Starts the REAL app (a Debug build, invisible) against the fake server three ways and reads the window's
# controls through accessibility: nobody signed in (the sign-in page and nothing else), someone signed in (the Setup page, no sign-in form),
# and signed in then signed out (back to the sign-in page, no Setup).
#   signin_first.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
swiftc -O -o /tmp/login_probe "$HERE/login_probe.swift" 2>/dev/null
pkill -f "Debug/InterviewCopilot.app/Contents/MacOS" 2>/dev/null; sleep 1
PORT=$((20100 + RANDOM % 90)); DATA=/tmp/glass/lab/data-signinfirst
launch() {   # launch [extra env]
  rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"; echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token "$@" \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
  sleep 9
}
python3 "$HERE/mock_backend.py" healthy-credits $PORT >/dev/null 2>&1 & MOCK=$!; sleep 1
only_signin() { echo "$1" | grep -q "^BUTTON Continue with Google" && ! echo "$1" | grep -q "Start interview\|^BUTTON Auto \|^BUTTON Manual \|Drop your resume"; }

launch REPLYSIS_X=1
B=$(/tmp/login_probe $PID all)
only_signin "$B" && ok "nobody signed in: the window is the sign-in page and nothing else (no Setup, no header)" || { no "nobody signed in, but more than the sign-in page is showing"; echo "$B" | cut -c1-90 | sed 's/^/        /'; }
kill $PID 2>/dev/null; sleep 1

launch REPLYSIS_TEST_SESSION=stale
B=$(/tmp/login_probe $PID all)
echo "$B" | grep -q "Start interview" && ! echo "$B" | grep -q "Continue with Google" && ok "signed in: the Setup page opens, with no sign-in form" || no "signed in, but the Setup page is not what shows"
echo signout >> "$DATA/flow.cmd"; sleep 3
B=$(/tmp/login_probe $PID all)
only_signin "$B" && ok "after signing out: back on the sign-in page, and no Setup page" || { no "after signing out the sign-in page is not all that shows"; echo "$B" | cut -c1-90 | sed 's/^/        /'; }
kill $PID $MOCK 2>/dev/null
[ $fail -eq 0 ] && echo "SIGN IN FIRST: all checks passed" || echo "SIGN IN FIRST: FAILED"
exit $fail
