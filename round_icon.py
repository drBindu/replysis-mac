"""
Removes the solid background so only the owl shape remains on
a transparent canvas. macOS Launchpad will show just the owl.
"""
from PIL import Image, ImageDraw, ImageFilter
import collections

SRC       = "InterviewCopilotMac6/Assets/AppIcon.png"
TOLERANCE = 55   # colour-distance threshold for flood-fill removal

def color_distance(c1, c2):
    return sum((a - b) ** 2 for a, b in zip(c1[:3], c2[:3])) ** 0.5

# ── 1. Flood-fill background removal from all 4 corners ─────────────────────
img    = Image.open(SRC).convert("RGBA")
w, h   = img.size
pixels = img.load()

bg_color = pixels[0, 0][:3]   # background colour sampled from top-left

visited = set()
queue   = collections.deque()
for seed in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
    if seed not in visited:
        visited.add(seed)
        queue.append(seed)

while queue:
    x, y = queue.popleft()
    r, g, b, a = pixels[x, y]
    if color_distance((r, g, b), bg_color) < TOLERANCE:
        pixels[x, y] = (0, 0, 0, 0)
        for nx, ny in [(x+1,y),(x-1,y),(x,y+1),(x,y-1)]:
            if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in visited:
                visited.add((nx, ny))
                queue.append((nx, ny))

# ── 2. Smooth edges slightly ─────────────────────────────────────────────────
img = img.filter(ImageFilter.SMOOTH_MORE)

# ── 3. Crop tight to owl, then re-centre on the original canvas with padding ─
bbox = img.getbbox()
if bbox:
    img = img.crop(bbox)

PADDING    = 0.12
canvas     = Image.new("RGBA", (w, h), (0, 0, 0, 0))
art_w      = int(w * (1 - 2 * PADDING))
art_h      = int(h * (1 - 2 * PADDING))
artwork    = img.resize((art_w, art_h), Image.LANCZOS)
offset_x   = (w - art_w) // 2
offset_y   = (h - art_h) // 2
canvas.paste(artwork, (offset_x, offset_y), artwork)

canvas.save(SRC)
print(f"✓ Owl shape only, transparent background  ({w}×{h})")
