"""
Applies ocean blue colour boost to owl on solid dark navy background.
"""
from PIL import Image, ImageEnhance

SRC = "InterviewCopilotMac6/Assets/AppIcon.png"
BG  = (0, 12, 50)

img = Image.open(SRC).convert("RGBA")
w, h = img.size

# Flatten onto solid dark navy background (fills any transparent corners/patches)
base = Image.new("RGBA", (w, h), BG + (255,))
base.paste(img, (0, 0), img)
img = base.convert("RGB")

# Ocean blue colour boost
r_ch, g_ch, b_ch = img.split()
r_ch = r_ch.point(lambda p: min(255, int(p * 0.3)))
g_ch = g_ch.point(lambda p: min(255, int(p * 0.7)))
b_ch = b_ch.point(lambda p: min(255, int(p * 1.4)))
img = Image.merge("RGB", (r_ch, g_ch, b_ch))
img = ImageEnhance.Brightness(img).enhance(0.65)
img = ImageEnhance.Contrast(img).enhance(1.8)

img.save(SRC)
print(f"✓ Ocean blue owl on dark navy background ({w}×{h})")
