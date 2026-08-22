# -*- mode: python ; coding: utf-8 -*-
#
# macOS build of the SHARED speech engine.
#
# THE SOURCE IS NOT IN THIS REPOSITORY. It lives in replysis-windows as
# speechmatics_engine.py and is built for both platforms from that one file.
# This spec previously pointed at InterviewCopilotMac6/bin/Debug/net8.0/, a
# 1,074-line fork left behind by the retired .NET app, which is why the Mac
# never received the Sarvam language path, additional_vocab, or the melia-1
# handling: it had been rebuilding the old fork all along, invisibly, because
# the build still succeeded.
#
# Build (with the two repos checked out side by side):
#   cp ../replysis-windows/speechmatics_engine.py .
#   python3 -m PyInstaller --clean --noconfirm speechmatics_engine.spec
#   cp -R dist/speechmatics_engine InterviewCopilot/InterviewCopilot/Resources/
#
# DIFFERENCES FROM THE WINDOWS SPEC — four lines, and each one has a reason:
#
#   1. collect_all('pyaudio') instead of collect_all('pyaudiowpatch').
#      pyaudiowpatch is the WASAPI-loopback fork and is Windows-only. The engine
#      already falls back to stock pyaudio on ImportError, so nothing else changes.
#
#   2/3. collect_all('speechmatics') and collect_all('websockets').
#      Both are imported INSIDE functions rather than at module scope, so they are
#      collected explicitly rather than left to static discovery.
#
#   4. upx=False. UPX is not installed by default on macOS and compressing a
#      Mach-O binary that then gets code-signed and notarized invites problems
#      that are not worth the megabytes.
#
# Verified on macOS 14+/arm64: builds clean, honours APP_DATA_DIR, accepts
# SPEECHMATICS_API_KEY, supports -mode mic, and transcribed real audio fed
# through -sysfifo end to end.
from PyInstaller.utils.hooks import collect_all

datas, binaries, hiddenimports = [], [], []
for pkg in ('pyaudio', 'speechmatics', 'websockets'):
    d, b, h = collect_all(pkg)
    datas += d; binaries += b; hiddenimports += h

a = Analysis(
    ['speechmatics_engine.py'],
    pathex=[], binaries=binaries, datas=datas,
    hiddenimports=hiddenimports + ['speechmatics.models', 'speechmatics.client'],
    hookspath=[], hooksconfig={}, runtime_hooks=[], excludes=[],
    noarchive=False, optimize=0,
)
pyz = PYZ(a.pure)

# ONEDIR, not onefile. A onefile build re-extracts its entire embedded Python,
# numpy, pyaudio and speechmatics payload into a fresh temp directory on EVERY
# launch — that self-extraction was the multi-second gap between spawning the
# process and its first printed line, on every single app open. Onedir extracts
# once at build time and the app launches the executable directly from Resources.
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='speechmatics_engine',
          debug=False, bootloader_ignore_signals=False, strip=False, upx=False,
          console=True, disable_windowed_traceback=False, argv_emulation=False,
          target_arch=None, codesign_identity=None, entitlements_file=None)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, upx_exclude=[],
               name='speechmatics_engine')
