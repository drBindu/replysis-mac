#!/bin/bash
# Build the macOS speech engine from the SHARED source, stamped with its provenance.
#
# The Mac shipped a 1,074-line fork of this engine for months while every build
# succeeded. Nothing would have caught it, and nothing would catch it recurring —
# which is why the binary now says what it was built from, out loud, before
# anything can fail.
#
# The SOURCE HASH is the part that matters. A commit id says which revision was
# checked out; the hash says whether what was compiled is actually that revision.
# The fork lived in exactly that gap: a build from a checked-out commit that was
# not the code that shipped.
# ⚠ THE SHARED ENGINE CANNOT CURRENTLY DRIVE THIS APP'S AUTO MODE.
#
# Mac decides a turn is over from one line the engine prints:
#
#     >>> UTTERANCE END
#
# The retired fork emits it from a Speechmatics EndOfUtterance handler, with
# end_of_utterance_silence_trigger set in the transcription config. The shared engine
# has NEITHER the handler nor the config, so Speechmatics is never asked to send the
# event. Building from the shared source therefore produces an engine that connects,
# transcribes correctly, and never ends a turn — the app listens, the transcript grows,
# and no answer is ever produced. Verified in a real session: zero UTTERANCE END lines,
# zero turns, zero answers.
#
# Windows does not need it; it decides turn-end client-side from the text. Mac
# deliberately does not, because the recogniser has the waveform and everything
# text-based is a guess at what it already knows.
#
# Until the shared engine emits it, this script builds an engine that is stamped,
# reproducible and unable to answer a question. Do not install its output as the app's
# engine without checking for that line first.
set -euo pipefail
MAC_DIR="$(cd "$(dirname "$0")" && pwd)"
WIN_DIR="${1:-$MAC_DIR/../replysis-windows}"
SRC="$WIN_DIR/speechmatics_engine.py"

[ -f "$SRC" ] || { echo "shared engine source not found at $SRC"; exit 1; }

COMMIT=$(git -C "$WIN_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "$WIN_DIR" diff --quiet 2>/dev/null || COMMIT="${COMMIT}+dirty"
# THE SOURCE ID IS git's BLOB ID, not a hash of the file on disk.
#
# Hashing the file directly cannot work across platforms and would have cried wolf on
# every honest build, forever: git translates line endings on checkout, so a Windows
# working tree holds CRLF where this one holds LF. Same commit, same content, different
# bytes — and therefore a different hash for identical source. The instrument built to
# detect a fork would have reported one every time.
#
# git hash-object is content-addressed and normalises line endings, so both platforms
# produce the same value. It also proves something the old method could not: because the
# value IS the id git stores, a match shows both that the content is the same AND that
# this working tree is the committed content. A stamp taken from a half-saved file used
# to look exactly like one taken from a clean checkout.
if command -v git >/dev/null 2>&1; then
    SRCHASH=$(git -C "$WIN_DIR" hash-object "$SRC" | cut -c1-12)
else
    # No git: reproduce the blob id EXACTLY rather than inventing a second scheme.
    # A normalised sha256 would be stable but incomparable to a git-derived stamp, which
    # is the same class of bug — an instrument silently producing values that cannot be
    # compared to each other.
    SRCHASH=$(python3 -c "
import hashlib, sys
data = open(sys.argv[1], 'rb').read().replace(b'\r\n', b'\n')
print(hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()[:12])
" "$SRC")
fi
BUILT=$(date -u +%Y-%m-%dT%H:%MZ)

WORK="$MAC_DIR/.engine-build"
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$SRC" "$WORK/speechmatics_engine.py"

# A PyInstaller RUNTIME HOOK, not an edit to the shared source. Runs before the
# main script, so the stamp is printed before any failure can swallow it — and
# the shared .py stays byte-identical to the Windows copy, which is the whole point.
cat > "$WORK/_engine_stamp.py" <<EOF
print(">>> ENGINE BUILD: $COMMIT src:$SRCHASH built:$BUILT", flush=True)
EOF

sed "s|\['speechmatics_engine.py'\]|['$WORK/speechmatics_engine.py']|; \
     s|runtime_hooks=\[\]|runtime_hooks=['$WORK/_engine_stamp.py']|" \
    "$MAC_DIR/speechmatics_engine.spec" > "$WORK/build.spec"

cd "$WORK"
python3 -m PyInstaller --clean --noconfirm --distpath ./dist --workpath ./build build.spec

# collect_all() drags a wheel's SOURCE files along with its runtime ones. Xcode then finds
# _internal/websockets/speedups.c inside Resources and tries to COMPILE it, failing the app
# build on a missing Python.h. They are build artifacts of the wheel and nothing at runtime
# reads them, so they are removed rather than worked around in the Xcode project.
# NOTHING IS STRIPPED HERE ANY MORE, and it must stay that way.
#
# An earlier version removed wheel sources (.c/.h/.pyx) and .dist-info directories,
# because the engine was being placed in the SOURCE tree — where Xcode treats the
# directory as a group, tries to compile the .c files, and collides on the identically
# named METADATA and RECORD that every wheel ships.
#
# Removing .dist-info broke transcription completely. The speechmatics SDK resolves its
# own version through importlib.metadata, and with the metadata gone it falls back to
# reading a VERSION file that does not exist in the package at all — so every websocket
# connect threw FileNotFoundError, the engine retried forever, and the app sat on
# "connecting" with no explanation. The engine was running and healthy in every other
# respect, which is exactly the shape the deaf detector was built for.
#
# The Xcode problem is solved properly by the Install-speech-engine build phase, which
# copies the tree with cp -R so Xcode never enumerates its contents as build inputs.
# Stripping was working around a problem that no longer exists, at the cost of one that
# does.
echo
echo "built: $COMMIT src:$SRCHASH built:$BUILT"
echo "install with:"
echo "  cp -R $WORK/dist/speechmatics_engine $MAC_DIR/InterviewCopilot/InterviewCopilot/Resources/"
