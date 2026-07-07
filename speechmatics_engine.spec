# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['InterviewCopilotMac6/bin/Debug/net8.0/speechmatics_engine.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

# ONEDIR build (exclude_binaries=True + COLLECT below), not onefile. Onefile bundles
# extract their entire embedded Python + numpy + pyaudio + speechmatics payload into a
# fresh /var/folders temp directory on EVERY launch — that self-extraction was a
# multi-second delay before the engine printed even its first startup line, on every
# single app open. Onedir extracts once at BUILD time; the app just launches the
# executable directly from files already sitting in Resources.
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='speechmatics_engine',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='speechmatics_engine',
)
