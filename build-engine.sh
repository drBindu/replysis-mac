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
SRCHASH=$(shasum -a 256 "$SRC" | cut -c1-12)
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
