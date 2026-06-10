"""
Ocean blue owl on solid dark navy background.
macOS applies squircle corners automatically — same as all other apps.
"""
from PIL import Image, ImageEnhance

SRC     = "InterviewCopilotMac6/Assets/AppIcon.png"
BG      = (0, 12, 50)
PADDING = 0.04   # small padding — owl fills the box like other apps

img = Image.open(SRC).convert("RGBA")
w, h = img.size

# Flatten onto solid dark navy background
base = Image.new("RGBA", (w, h), BG + (255,))
base.paste(img, (0, 0), img)
img = base.convert("RGB")

# Ocean blue colour boost
r_ch, g_ch, b_ch = img.split()
r_ch = r_ch.point(lambda p: min(255, int(p * 0.3)))
g_ch = g_ch.point(lambda p: min(255, int(p * 0.7)))
b_ch = b_ch.point(lambda p: min(255, int(p * 1.4)))
img  = Image.merge("RGB", (r_ch, g_ch, b_ch))
img  = ImageEnhance.Brightness(img).enhance(0.65)
img  = ImageEnhance.Contrast(img).enhance(1.8)

# Center owl with small padding on dark navy canvas
pad     = int(w * PADDING)
art_w   = w - 2 * pad
art_h   = h - 2 * pad
artwork = img.resize((art_w, art_h), Image.LANCZOS)
canvas  = Image.new("RGB", (w, h), BG)
canvas.paste(artwork, (pad, pad))

# Save as solid RGB — macOS applies squircle mask same as all other apps
canvas.save(SRC)
print(f"✓ Solid dark navy icon saved ({w}×{h})")
