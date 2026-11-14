#!/bin/bash
# The activity diary (CHANNEL 2026-11-14): events go to POST /api/v1/activity in batches every 10 s and at quit, each one carrying
# t, uid, session_id, app mac, v and fixed props only. Runs the REAL app (a Debug build, invisible) against the fake server, starts an
# interview, asks a typed question that holds a made-up secret word, switches Auto and Manual with the shortcut, finishes and quits.
# Then checks the batches, the fields, and that neither the question nor the answer text is in anything the diary sent or kept.
# A second run plays a server with no endpoint yet (404): the app must stop sending and keep the events on disk.
#   activity.sh <path-to-Debug-InterviewCopilot.app>
APP="$1"; BIN="$APP/Contents/MacOS/InterviewCopilot"
[ -x "$BIN" ] || { echo "no app at $APP"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/glass/lab/mock-activity.out; DATA=/tmp/glass/lab/data-activity
SECRET="Bluefinchquokka"
fail=0; ok(){ echo "  PASS  $1"; }; no(){ echo "  FAIL  $1"; fail=1; }
mkdir -p /tmp/glass/lab
launch(){  # $1 = forced status for the activity endpoint ("" = 204 for a fresh token)
  PORT=$((19500 + RANDOM % 90)); rm -rf "$DATA"; mkdir -p "$DATA"; touch "$DATA/onboarding_seen"
  echo '{"listeningMode":"manual"}' > "$DATA/settings.json"
  MOCK_ACTIVITY_STATUS=$1 MOCK_SECRET="$SECRET" python3 "$HERE/mock_backend.py" healthy-credits $PORT > "$OUT" 2>&1 & MOCK=$!; sleep 1
  env REPLYSIS_BACKEND_URL=http://127.0.0.1:$PORT REPLYSIS_TOKEN_URL=http://127.0.0.1:$PORT/token REPLYSIS_TEST_SESSION=stale REPLYSIS_TEST_USER=diary-user \
    REPLYSIS_DATA_DIR="$DATA" REPLYSIS_HEADLESS=1 REPLYSIS_FLOW_SCRIPT=watch "$BIN" >/dev/null 2>&1 & PID=$!
}
cmd(){ echo "$1" >> "$DATA/flow.cmd"; }
batches(){ grep '^ACTIVITY ' "$OUT"; }
sent(){ batches | grep 'status=204'; }
gone(){ for i in $(seq 1 60); do kill -0 $PID 2>/dev/null || return 0; sleep 0.1; done; return 1; }

launch ""
sleep 10
cmd micseen; cmd start; sleep 4
cmd "ask What does the $SECRET service do with a mutex?"; sleep 6
cmd key-a; sleep 2; cmd key-a; sleep 2
cmd finish; sleep 14
cmd closesessions; sleep 1   # Past sessions opens on Finish; a quit waits for it to close
BEFORE_QUIT=$(sent | wc -l | tr -d ' ')
cmd quitapp; gone || { no "the app did not quit"; kill $PID 2>/dev/null; }
sleep 0.5; kill $MOCK 2>/dev/null

N=$(sent | wc -l | tr -d ' ')
[ "$BEFORE_QUIT" -ge 2 ] && ok "events arrived in $BEFORE_QUIT batches while the app ran (every 10 s), $N in all" || no "only $BEFORE_QUIT batches before quit"
MAXN=$(sent | sed -E 's/.* n=([0-9]+) .*/\1/' | sort -n | tail -1)
[ "${MAXN:-0}" -le 200 ] && ok "no batch had more than 200 events (largest $MAXN)" || no "a batch had $MAXN events"
ALL=$(sent | sed -E 's/.* events=([^ ]*) .*/\1/' | tr ',' '\n')
for e in app_opened interview_started answer_shown mode_changed interview_finished app_closed; do
  echo "$ALL" | grep -qx "$e" && ok "event sent: $e" || no "event missing: $e"
done
sent | tail -1 | grep -q 'app_closed' && ok "the last batch, at quit, carried app_closed" || no "no app_closed in the batch sent at quit"
[ "$(sent | sed -E 's/.* sessions=([^ ]*) .*/\1/' | sort -u | wc -l | tr -d ' ')" = "1" ] && ! sent | grep -q 'sessions=[^ ]*,' && sent | grep -q 'sessions=[0-9a-f-]\{36\} ' \
  && ok "every event carries the same session_id for this launch" || no "session_id missing or not one per launch"
[ "$(sent | grep -c 'apps=mac vs=[0-9][0-9.]* ')" = "$N" ] && ok "every event carries app mac and the plain version" || no "app or v wrong on some events"
[ "$(sent | grep -c 'keys=app,event,props,session_id,t,uid,v ')" = "$N" ] && ok "every event is exactly {t, uid, session_id, app, v, event, props}" || no "an event has other fields"
[ "$(sent | grep -c 'platform=mac version=[0-9]')" = "$N" ] && ok "every batch carries X-App-Platform and X-App-Version" || no "a batch lacks the labels"
batches | grep -q 'status=401' && ok "the stale token was refused (401), refreshed, and sent again" || echo "  note  no 401 seen (the token was fresh already)"
grep -q 'ASK-SECRET seen=True' "$OUT" && ok "the question with the secret word did reach the answer server" || no "the test question never reached the server"
if grep '^ACTIVITY' "$OUT" | grep -qiE "$SECRET|mutex|fake server|test answer"; then no "question or answer text is in what the diary sent"; grep '^ACTIVITY' "$OUT" | grep -iE "$SECRET|mutex|fake server" | cut -c1-200; else ok "no question or answer text in anything the diary sent"; fi
grep '^ACTIVITY-RAW' "$OUT" | grep -o '"ms_to_first_words":[0-9-]*' | head -1 | grep -q '[0-9]' && ok "answer_shown carries ms_to_first_words ($(grep '^ACTIVITY-RAW' "$OUT" | grep -o '"ms_to_first_words":[0-9-]*' | head -1))" || no "answer_shown has no ms_to_first_words"
grep '^ACTIVITY-RAW' "$OUT" | grep -q '"uid":"diary-user-user"' && ok "events after sign-in carry the user id" || no "no event carries the user id"
grep '^ACTIVITY-RAW' "$OUT" | grep -q '"via":"shortcut"' && ok "mode_changed says it came from the shortcut" || no "mode_changed has no via"
Q="$DATA/activity_queue.json"
[ -f "$Q" ] && [ "$(stat -f %Lp "$Q")" = "600" ] && ok "the diary file is in the data folder and is the user's only (0600)" || no "diary file missing or not 0600"
grep -qiE "$SECRET|mutex" "$Q" 2>/dev/null && no "question text is in the diary file on disk" || ok "no question text in the diary file on disk"

# A server with no activity endpoint yet: one try, then quiet, and everything kept on disk.
launch 404
sleep 34
T=$(batches | wc -l | tr -d ' ')
cmd quitapp; gone || kill $PID 2>/dev/null
sleep 0.3; kill $MOCK 2>/dev/null
[ "$T" -le 2 ] && ok "the server answered 404: the app stopped sending ($T tries in 34 s, the ticks are 10 s apart)" || no "the app kept sending to a missing endpoint ($T tries)"
KEPT=$(python3 -c "import json;print(len(json.load(open('$Q'))))" 2>/dev/null || echo 0)
[ "$KEPT" -ge 1 ] && ok "the events stay on disk for later ($KEPT kept)" || no "nothing kept on disk after a 404"

[ $fail -eq 0 ] && echo "ACTIVITY: all checks passed" || echo "ACTIVITY: FAILED"
exit $fail
