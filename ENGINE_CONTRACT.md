# What each client needs from the shared speech engine

The engine is one file built for two apps. Three times now, a capability only one
client depended on was absent from the shared build and nothing caught it until a
real session failed — `--sysfifo`, the single-dash argument convention, and the
turn-end signal. Each was found by running the thing. None was visible from the
other platform, because Windows has no FIFO, no single-dash convention and no
acoustic turn detection.

More care does not fix that. Neither side can see requirements that only exist on
the other's platform. This is the checkable list instead.

**A missing line here should fail a check, not a silent interview.**

## What the Mac client reads

### Stdout lines it acts on

| Line | Consumed by | What breaks without it |
|---|---|---|
| `>>> UTTERANCE END` | `SpeechmaticsEngine.monitorPipes` → `onUtteranceEnd` → `handleUtteranceEnd` | **Everything.** This is the only trigger for an automatic turn. Without it the app listens, transcribes correctly, accumulates a transcript and never answers. It looks like a hung app and is a healthy one waiting for a signal that never comes. |
| `>>> STATUS: ONLINE` / `ENGINE: READY` | sets `isReady` | The header shows CONNECTING forever and automatic modes refuse to submit, because `engine.isReady` gates them. |
| `>>> STATUS: OFFLINE` / `EndOfTranscript` | clears `isReady` | A dropped session goes unnoticed and the app answers nothing while looking armed. |
| `... AUDIO live ...` | deaf detector, input side | The detector can never fire; a deaf engine looks healthy. |
| `... received (N chars)` | deaf detector, output side | Same. `(0 chars)` deliberately does not count — an empty result is what a deaf engine emits. |
| `>>> ENGINE BUILD: <commit> src:<blob> built:<ts>` | `engineBuildId`, logged | Support cannot answer "which engine is this user running?" |
| auth failure text | `isAuthFailure` | See below. |

### Arguments it passes

| Argument | Note |
|---|---|
| `-mode both\|system\|mic` | **Single dash.** All three values are required — `mic` is the fallback when the system-audio tap fails, and rejecting it turns a degraded-but-working state into an engine that will not start. |
| `-sysfifo <path>` | macOS cannot capture system audio in a helper process — macOS feeds it silence, because the helper does not inherit the app's TCC grant. The tap runs in-process and streams 16 kHz mono s16le to a FIFO. There is no alternative on this platform. |
| `-max-delay 0.7` | Speechmatics' documented floor; below it the API refuses to connect. |
| `-device <n>` | Optional. |
| `--utterance-silence <s>` | 0.8. Measured, not guessed: it is what the retired fork used. |

### Environment

| Variable | Note |
|---|---|
| `APP_DATA_DIR` | Where `latest.txt`, `pause.flag` and `reset.flag` live. Without it the engine writes to a temp directory the app never reads, and the app shows an empty transcript forever with no error at either end. |
| `SPEECHMATICS_API_KEY` | Accepted alongside `SM_API_KEY`. |

### Files it polls

`latest.txt` (transcript), `pause.flag`, `reset.flag` — all under `APP_DATA_DIR`.

## What the Windows client reads

Recorded from the Windows side, listed here so one document covers both:

`STATUS: ONLINE`, `MIC SIGNAL DETECTED`, `PARTIAL received` / `FINAL received`.

## The failure this exists to prevent

Every one of these is consumed by matching a **string** on stdout. A rename is
invisible at build time, invisible in review, and produces an app that starts,
connects, and does nothing — which is the hardest failure to attribute, because
every signal the engine emits says it is healthy.

Adding a capability for one client is fine. Removing or renaming a line in this
table is a breaking change to the other, and cannot be detected by that client's
tests, because its tests do not run the engine.
