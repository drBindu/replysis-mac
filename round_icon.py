"""
Applies macOS-standard padding + rounded corners to AppIcon.png.
Artwork is scaled to 80% of canvas so it matches the visual weight
of other Mac app icons (Developer, Claude, Cluely, etc.)

macOS Big Sur+ corner radius ≈ 22.37 % of icon width
  256 px  →  ~57 px radius
"""
from PIL import Image, ImageDraw

SRC     = "InterviewCopilotMac6/Assets/AppIcon.png"
PADDING = 0.10   # 10% padding on each side = artwork fills 80% of canvas

img = Image.open(SRC).convert("RGBA")
w, h = img.size

# Shrink artwork to 80% and centre it on transparent canvas
art_w = int(w * (1 - 2 * PADDING))
art_h = int(h * (1 - 2 * PADDING))
offset_x = (w - art_w) // 2
offset_y = (h - art_h) // 2

artwork = img.resize((art_w, art_h), Image.LANCZOS)
canvas  = Image.new("RGBA", (w, h), (0, 0, 0, 0))
canvas.paste(artwork, (offset_x, offset_y))

# Apply rounded corners (macOS squircle radius on the full canvas)
radius = int(w * 0.2237)
mask = Image.new("L", (w, h), 0)
draw = ImageDraw.Draw(mask)
draw.rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)

result = Image.new("RGBA", (w, h), (0, 0, 0, 0))
result.paste(canvas, mask=mask)
result.save(SRC)

print(f"✓ Icon padded + rounded  ({w}×{h}, artwork={art_w}×{art_h}, radius={radius}px)")
