"""
Builds InterviewCopilot-mac.zip — a proper macOS .app bundle —
from the compiled files in publish/arm64/.

Run from Windows:  python build_mac_zip.py
Output goes to:    uiii/frontend/public/InterviewCopilot-mac.zip
"""

import zipfile
import os

SRC_DIR    = r"C:\Users\krish\Desktop\InterviewCopilotMac6\InterviewCopilotMac6\publish\arm64"
OUTPUT_ZIP = r"C:\Users\krish\Desktop\uiii\frontend\public\InterviewCopilot-mac.zip"

APP      = "InterviewCopilot.app"
EXEC     = "InterviewCopilot"   # must match CFBundleExecutable in Info.plist

SKIP = {"InterviewCopilotMac6.pdb"}  # debug symbols — not needed in release

# Unix permission constants
DIR_MODE  = (0o40755)  << 16   # directory, rwxr-xr-x
EXEC_MODE = (0o100755) << 16   # executable file
FILE_MODE = (0o100644) << 16   # regular file

EXECUTABLES = {EXEC, "ScreenOCR", "SystemAudioCapture"}
DYLIBS      = {"libAvaloniaNative.dylib", "libHarfBuzzSharp.dylib", "libSkiaSharp.dylib"}

INFO_PLIST = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>InterviewCopilot</string>

    <key>CFBundleName</key>
    <string>Interview Copilot</string>

    <key>CFBundleDisplayName</key>
    <string>Interview Copilot</string>

    <key>CFBundleIdentifier</key>
    <string>com.coopilotx.interviewcopilot</string>

    <key>CFBundleVersion</key>
    <string>1.0</string>

    <key>CFBundleShortVersionString</key>
    <string>1.0</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>NSPrincipalClass</key>
    <string>NSApplication</string>

    <key>NSHighResolutionCapable</key>
    <true/>

    <key>NSMicrophoneUsageDescription</key>
    <string>Interview Copilot needs microphone access to listen for interview questions.</string>

    <key>NSAccessibilityUsageDescription</key>
    <string>Interview Copilot needs accessibility access for global hotkeys.</string>

    <key>NSScreenCaptureUsageDescription</key>
    <string>Interview Copilot needs screen capture to work invisibly during screen-share.</string>
</dict>
</plist>
"""

def zi(arcname, mode):
    info = zipfile.ZipInfo(arcname)
    info.external_attr = mode
    info.compress_type = zipfile.ZIP_DEFLATED
    return info

print("Building InterviewCopilot-mac.zip ...")

with zipfile.ZipFile(OUTPUT_ZIP, "w", zipfile.ZIP_DEFLATED) as zf:

    # Directory stubs (needed so macOS recognises the bundle)
    for d in [f"{APP}/", f"{APP}/Contents/", f"{APP}/Contents/MacOS/", f"{APP}/Contents/Resources/"]:
        zf.writestr(zi(d, DIR_MODE), b"")

    # Info.plist
    zf.writestr(zi(f"{APP}/Contents/Info.plist", FILE_MODE), INFO_PLIST.encode())
    print("  + Info.plist")

    # All compiled files
    for name in sorted(os.listdir(SRC_DIR)):
        if name in SKIP:
            continue
        src = os.path.join(SRC_DIR, name)
        if not os.path.isfile(src):
            continue

        # Rename the main binary to match CFBundleExecutable
        arc_name = EXEC if name == "InterviewCopilotMac6" else name
        arcpath  = f"{APP}/Contents/MacOS/{arc_name}"

        mode = EXEC_MODE if (arc_name in EXECUTABLES or arc_name in DYLIBS) else FILE_MODE

        mb = os.path.getsize(src) / 1024 / 1024
        print(f"  + {arc_name:<40} {mb:6.1f} MB")

        with open(src, "rb") as f:
            zf.writestr(zi(arcpath, mode), f.read())

zip_mb = os.path.getsize(OUTPUT_ZIP) / 1024 / 1024
print(f"\nDone! {OUTPUT_ZIP}")
print(f"Size: {zip_mb:.1f} MB")
print("\nNext: run  npm run dev  in uiii/frontend and test the Mac download button.")
