"""
Applies macOS-standard rounded corners to AppIcon.png.
Run once during CI before the icon is sliced into .iconset sizes.

macOS Big Sur+ corner radius ≈ 22.37 % of icon width
  256 px  →  ~57 px radius
  1024 px → ~229 px radius
"""
from PIL import Image, ImageDraw

SRC = "InterviewCopilotMac6/Assets/AppIcon.png"

img    = Image.open(SRC).convert("RGBA")
w, h   = img.size
radius = int(w * 0.2237)          # macOS standard squircle radius

# Build a smooth alpha mask
mask = Image.new("L", (w, h), 0)
draw = ImageDraw.Draw(mask)
draw.rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)

# Composite: keep pixels inside the rounded rect, clear the corners
result = Image.new("RGBA", (w, h), (0, 0, 0, 0))
result.paste(img, mask=mask)
result.save(SRC)

print(f"✓ Rounded corners applied  ({w}×{h}, radius={radius}px)")
