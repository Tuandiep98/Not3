"""Turn a rounded, transparent icon render into an App Store-ready AppIcon.

Usage: python3 scripts/make_app_icon.py <source.png> <out-1024.png> <preview.png>

Output: 1024x1024 RGB PNG (no alpha), full-bleed square - iOS applies the corner mask.
Rebuilds the background row by row from the interior colours, drops the baked-in corners,
glossy bevel and stray pixels, and keeps the inner artwork. preview.png shows it masked.
"""
import sys
from statistics import median
from PIL import Image, ImageFilter

src_path, out_path, preview_path = sys.argv[1:4]
src = Image.open(src_path).convert("RGBA")
W, H = src.size
rgb = src.convert("RGB")
alpha = src.getchannel("A")

# 1. Body = pixels that are (almost) opaque. Erode it to drop the glossy bevel and baked-in corners.
body = alpha.point(lambda v: 255 if v > 240 else 0)
interior = body
for _ in range(45):
    interior = interior.filter(ImageFilter.MinFilter(3))
x0, y0, x1, y1 = body.getbbox()                  # (127, 140, 1127, 1091)
HEADER_END = 400                                  # yellow header + separator end above this row

# 2. Background colour per row = median of interior pixels (bright pixels only in the white body,
#    so pills / dotted lines do not leak into the background).
px, ipx = rgb.load(), interior.load()
row_color = {}
for y in range(H):
    samples = [px[x, y] for x in range(x0, x1) if ipx[x, y]]
    if y >= HEADER_END:
        samples = [c for c in samples if min(c) > 225]
    if len(samples) >= 40:
        row_color[y] = tuple(int(median(c[i] for c in samples)) for i in range(3))
valid = sorted(row_color)

def color_at(y):
    if y in row_color:
        return row_color[y]
    nearest = min(valid, key=lambda v: abs(v - y))
    return row_color[nearest]

# 3. Square, full-bleed canvas: body width, vertically centred on the body.
side = x1 - x0                                    # 1000
top = (y0 + y1) // 2 - side // 2
bg = Image.new("RGB", (side, side))
bpx = bg.load()
for j in range(side):
    c = color_at(top + j)
    for i in range(side):
        bpx[i, j] = c

# 4. Paste the original interior over the rebuilt background with a feathered mask.
crop_box = (x0, top, x0 + side, top + side)
content = rgb.crop(crop_box)
mask = interior.crop(crop_box).filter(ImageFilter.GaussianBlur(10))
icon = Image.composite(content, bg, mask)

# 5. 1024×1024, RGB (no alpha), sRGB PNG.
icon = icon.resize((1024, 1024), Image.LANCZOS)
icon.save(out_path, "PNG", optimize=True)

# Preview with an iOS-style squircle mask on grey, to check corners and margins.
from PIL import ImageDraw
m = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(m).rounded_rectangle((0, 0, 1023, 1023), radius=230, fill=255)
prev = Image.new("RGB", (1224, 1224), (90, 90, 96))
prev.paste(icon, (100, 100), m)
prev.save(preview_path)
print("rows sampled:", len(valid), "square top:", top, "side:", side)
