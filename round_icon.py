"""
1. Flood-fill removes the solid background (seeds from all 4 corners).
2. Shrinks artwork to 80% and centres it on a transparent canvas.
3. Clips to macOS squircle rounded corners.
"""
from PIL import Image, ImageDraw, ImageFilter
import collections

SRC     = "InterviewCopilotMac6/Assets/AppIcon.png"
PADDING = 0.10   # 10% padding each side = artwork at 80%
TOLERANCE = 55   # colour-distance threshold for background removal

def color_distance(c1, c2):
    return sum((a - b) ** 2 for a, b in zip(c1[:3], c2[:3])) ** 0.5

# ── 1. Remove background via flood-fill from the 4 corners ──────────────────
img    = Image.open(SRC).convert("RGBA")
w, h   = img.size
pixels = img.load()

bg_color = pixels[0, 0][:3]   # sample background from top-left corner

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
        pixels[x, y] = (0, 0, 0, 0)            # make transparent
        for nx, ny in [(x+1,y),(x-1,y),(x,y+1),(x,y-1)]:
            if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in visited:
                visited.add((nx, ny))
                queue.append((nx, ny))

# Slight blur on edges to smooth the cut-out
img = img.filter(ImageFilter.SMOOTH_MORE)

# ── 2. Crop to the non-transparent bounding box ─────────────────────────────
bbox = img.getbbox()
if bbox:
    img = img.crop(bbox)

# ── 3. Centre artwork at 80% on a transparent canvas ────────────────────────
canvas_size = 512
art_size    = int(canvas_size * (1 - 2 * PADDING))
artwork     = img.resize((art_size, art_size), Image.LANCZOS)
canvas      = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
offset      = (canvas_size - art_size) // 2
canvas.paste(artwork, (offset, offset), artwork)

# ── 4. Apply macOS squircle rounded-corner clip ──────────────────────────────
radius = int(canvas_size * 0.2237)
mask   = Image.new("L", (canvas_size, canvas_size), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    [0, 0, canvas_size - 1, canvas_size - 1], radius=radius, fill=255)

result = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
result.paste(canvas, mask=mask)
result = result.resize((w, h), Image.LANCZOS)   # restore original dimensions
result.save(SRC)

print(f"✓ Background removed + padded + rounded  ({w}×{h})")
