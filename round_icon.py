"""
Ocean blue owl on solid dark navy square background, centered with padding.
"""
from PIL import Image, ImageEnhance

SRC     = "InterviewCopilotMac6/Assets/AppIcon.png"
BG      = (0, 12, 50)
PADDING = 0.08   # 8% on each side — standard app icon breathing room

img = Image.open(SRC).convert("RGBA")
w, h = img.size

# Flatten onto solid dark navy (fills any transparent corners)
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

# Shrink and centre on dark navy canvas with padding
pad     = int(w * PADDING)
art_w   = w - 2 * pad
art_h   = h - 2 * pad
artwork = img.resize((art_w, art_h), Image.LANCZOS)
canvas  = Image.new("RGB", (w, h), BG)
canvas.paste(artwork, (pad, pad))

canvas.save(SRC)
print(f"✓ Ocean blue owl, dark navy bg, {PADDING*100:.0f}% padding ({w}×{h})")
