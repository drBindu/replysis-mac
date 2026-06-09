"""Resize AppIcon.png to all iconset sizes using Pillow (preserves RGBA alpha)."""
from PIL import Image
import os

src = "InterviewCopilotMac6/Assets/AppIcon.png"
out = "AppIcon.iconset"
os.makedirs(out, exist_ok=True)

sizes = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}

img = Image.open(src).convert("RGBA")
for name, size in sizes.items():
    img.resize((size, size), Image.LANCZOS).save(f"{out}/{name}", "PNG")
    print(f"  {name}: {size}x{size}")

print(f"✓ Iconset created from {src}")
