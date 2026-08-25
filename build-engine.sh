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
find ./dist/speechmatics_engine \( -name '*.c' -o -name '*.h' -o -name '*.pyx' \) -delete

# And the .dist-info directories. Every wheel ships METADATA, RECORD, LICENSE.txt,
# INSTALLER and REQUESTED under the same names, and Xcode adds this tree as a GROUP —
# flattening it into Contents/Resources, where five packages' worth of identically named
# metadata collide: "Multiple commands produce .../Resources/METADATA". None of it is read
# at runtime.
find ./dist/speechmatics_engine -name '*.dist-info' -type d -exec rm -rf {} + 2>/dev/null || true
echo "stripped wheel source and .dist-info metadata (Xcode compiles the first and collides on the second)"
echo
echo "built: $COMMIT src:$SRCHASH built:$BUILT"
echo "install with:"
echo "  cp -R $WORK/dist/speechmatics_engine $MAC_DIR/InterviewCopilot/InterviewCopilot/Resources/"
