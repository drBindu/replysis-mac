"""
Removes dark navy background cleanly, applies ocean blue colour boost.
"""
from PIL import Image, ImageFilter, ImageEnhance
import collections

SRC            = "InterviewCopilotMac6/Assets/AppIcon.png"
TOLERANCE      = 12   # flood-fill: removes pixels close to (0,12,50) background
EDGE_FRINGE    = 35   # second-pass: removes residual dark fringe at owl boundary

def color_distance(c1, c2):
    return sum((a - b) ** 2 for a, b in zip(c1[:3], c2[:3])) ** 0.5

# ── 1. Load, sample real background colour from top-centre ───────────────────
img      = Image.open(SRC).convert("RGBA")
w, h     = img.size
pixels   = img.load()
bg_color = pixels[w // 2, 3][:3]

# ── 2. Flood-fill background from all 4 edges ────────────────────────────────
visited = set()
queue   = collections.deque()

def add_edge_seeds(pts):
    for (x, y) in pts:
        if (x, y) not in visited:
            r, g, b, a = pixels[x, y]
            if a > 50 and color_distance((r, g, b), bg_color) < TOLERANCE:
                visited.add((x, y))
                queue.append((x, y))

for x in range(w):
    add_edge_seeds([(x, 0), (x, h - 1)])
for y in range(h):
    add_edge_seeds([(0, y), (w - 1, y)])

while queue:
    x, y = queue.popleft()
    r, g, b, a = pixels[x, y]
    if color_distance((r, g, b), bg_color) < TOLERANCE:
        pixels[x, y] = (0, 0, 0, 0)
        for nx, ny in [(x+1,y),(x-1,y),(x,y+1),(x,y-1)]:
            if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in visited:
                visited.add((nx, ny))
                queue.append((nx, ny))

# ── 3. Keep only the largest connected blob ───────────────────────────────────
alpha = img.split()[3]
apx   = alpha.load()

def flood_find(sx, sy):
    blob = []
    q    = collections.deque([(sx, sy)])
    seen = {(sx, sy)}
    while q:
        cx, cy = q.popleft()
        blob.append((cx, cy))
        for nx, ny in [(cx+1,cy),(cx-1,cy),(cx,cy+1),(cx,cy-1)]:
            if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in seen and apx[nx, ny] > 10:
                seen.add((nx, ny))
                q.append((nx, ny))
    return blob

processed = set()
blobs     = []
for y in range(h):
    for x in range(w):
        if apx[x, y] > 10 and (x, y) not in processed:
            blob = flood_find(x, y)
            blobs.append(blob)
            processed.update(blob)

if blobs:
    keep = set(max(blobs, key=len))
    r_ch, g_ch, b_ch, a_ch = img.split()
    a_arr = a_ch.load()
    for y in range(h):
        for x in range(w):
            if (x, y) not in keep:
                a_arr[x, y] = 0
    img = Image.merge("RGBA", (r_ch, g_ch, b_ch, a_ch))

# ── 4. Edge fringe removal — 3 passes removes dark anti-alias fringe ──────────
def remove_edge_fringe(im, tol):
    px = im.load()
    iw, ih = im.size
    for y in range(ih):
        for x in range(iw):
            r, g, b, a = px[x, y]
            if a > 0:
                is_edge = any(
                    0 <= nx < iw and 0 <= ny < ih and px[nx, ny][3] == 0
                    for nx, ny in [(x+1,y),(x-1,y),(x,y+1),(x,y-1)]
                )
                if is_edge and color_distance((r, g, b), bg_color) < tol:
                    px[x, y] = (0, 0, 0, 0)
    return im

img = remove_edge_fringe(img, EDGE_FRINGE)
img = remove_edge_fringe(img, EDGE_FRINGE)
img = remove_edge_fringe(img, EDGE_FRINGE)

# ── 5. Smooth alpha edges ─────────────────────────────────────────────────────
r_ch, g_ch, b_ch, a_ch = img.split()
a_ch = a_ch.filter(ImageFilter.GaussianBlur(radius=1.5))
img  = Image.merge("RGBA", (r_ch, g_ch, b_ch, a_ch))

# ── 6. Ocean blue colour boost ────────────────────────────────────────────────
r_ch, g_ch, b_ch, a_ch = img.split()
r_ch = r_ch.point(lambda p: min(255, int(p * 0.3)))
g_ch = g_ch.point(lambda p: min(255, int(p * 0.7)))
b_ch = b_ch.point(lambda p: min(255, int(p * 1.4)))
rgb  = Image.merge("RGB", (r_ch, g_ch, b_ch))
rgb  = ImageEnhance.Brightness(rgb).enhance(0.55)
rgb  = ImageEnhance.Contrast(rgb).enhance(1.8)
r2, g2, b2 = rgb.split()
img = Image.merge("RGBA", (r2, g2, b2, a_ch))

# ── 7. Crop to bounding box, centre with 12% padding ─────────────────────────
bbox = img.getbbox()
if bbox:
    img = img.crop(bbox)

PADDING  = 0.12
canvas   = Image.new("RGBA", (w, h), (0, 0, 0, 0))
art_w    = int(w * (1 - 2 * PADDING))
art_h    = int(h * (1 - 2 * PADDING))
artwork  = img.resize((art_w, art_h), Image.LANCZOS)
offset_x = (w - art_w) // 2
offset_y = (h - art_h) // 2
canvas.paste(artwork, (offset_x, offset_y), artwork)

canvas.save(SRC)
print(f"✓ Ocean blue owl, clean edges  ({w}×{h})")
