# Incident Playbook

The exact process that worked, twice, in one night (2026-07-16): the mic-toggle crash,
and the Google Sign-In backend-proxy failure. Follow this instead of improvising under
pressure — it's already proven to work.

## 1. Detect

- A real user report, a debug log, or an error screenshot counts as detection — don't
  wait for "proof" beyond that. If something looks broken, treat it as broken.
- Pull the actual debug log (`~/Library/Logs/InterviewCopilot-debug.log`) or ask for the
  exact copy-pasted error text (not a screenshot, if it contains long content like a
  token — screenshots can't be safely transcribed character-for-character).

## 2. Find the real cause — don't guess blind

- Read the actual code path involved before proposing a fix. Both incidents tonight had
  a root cause findable directly in the code + log evidence, not from theorizing.
- If a first theory turns out wrong (like the Firebase-safelist theory did), say so
  plainly and move to the next one — don't keep the wrong theory around out of
  momentum.
- It's fine to not have 100% certainty on the deepest root cause (see: why Google's
  response was missing `access_token` — still unknown). Ship the fix that stops the
  damage now; investigate the deeper "why" later, calmly, off the clock.

## 3. Fix small, fix scoped

- Change only what's needed to address the specific failure. Don't bundle unrelated
  cleanup into an incident fix.
- Prefer reverting to the last known-good state over trying a clever new fix live, unless
  the new fix is small, well-understood, and testable before shipping.

## 4. Verify before shipping

- Build and confirm it compiles (Xcode build succeeds / `mvn test` passes) before
  copying anywhere near the real repo.
- Where possible, actually exercise the fix (run the app, trigger the flow) rather than
  relying on code review alone. If live verification genuinely isn't possible (e.g. a
  system permission dialog blocks automation), say so explicitly instead of claiming
  certainty you don't have.

## 5. Ship it

- Rebase onto `origin/main` first (CI's own appcast-bot commits move main forward
  independently — always `git fetch` + `git pull --ff-only` before committing).
- Write a commit message that explains *why*, not just *what* — future-you (or
  Windows Claude) needs the reasoning, not just the diff.
- Push, then confirm CI actually picked it up (check the Actions tab for the new
  commit's run).

## 6. Confirm the fix landed for real

- Don't consider it done until the *actual released build* is tested — not a stale
  local copy sitting outside `/Applications`, and not the TEST folder (that's source
  code, not a runnable release).
- If the fix doesn't fully resolve it (like the first Google Sign-In attempt didn't),
  that's not a failure of the process — it's exactly what step 4/5 are for: find out
  fast, fix again, ship again. Two rounds in one night is the process working, not
  the process failing.

## The one non-negotiable rule

**When in doubt, revert first, investigate later.** A reverted feature that used to
work is always safer than a new feature that might be broken. Every incident tonight
was resolved by either reverting cleanly or falling back to a previously-proven method
— never by pushing forward on an unverified new approach under pressure.
