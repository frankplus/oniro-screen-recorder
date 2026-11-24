import sys
from PIL import Image, ImageDraw, ImageFilter
out = sys.argv[1]
N, SS = 1024, 4
W = N * SS

# Background: diagonal dark gradient with a faint red glow at the centre.
bg = Image.new('RGBA', (W // 8, W // 8))
px = bg.load()
n = W // 8
for y in range(n):
    for x in range(n):
        t = (x + y) / (2 * (n - 1))
        r = int(0x3A * (1 - t) + 0x12 * t)
        g = int(0x3A * (1 - t) + 0x12 * t)
        b = int(0x44 * (1 - t) + 0x1A * t)
        px[x, y] = (r, g, b, 255)
bg = bg.resize((N, N), Image.BICUBIC)
glow = Image.new('RGBA', (N, N), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((262, 262, 762, 762), fill=(229, 57, 53, 90))
glow = glow.filter(ImageFilter.GaussianBlur(110))
bg = Image.alpha_composite(bg, glow)

# Foreground: phone screen outline with a record dot, inside the safe zone.
fg = Image.new('RGBA', (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(fg)
s = lambda v: int(v * SS)
cx, cy = 512, 512
pw, ph = 380, 600                      # phone body
x0, y0 = cx - pw / 2, cy - ph / 2
d.rounded_rectangle((s(x0), s(y0), s(x0 + pw), s(y0 + ph)), radius=s(72),
                    outline=(255, 255, 255, 255), width=s(34))
# Notch-like speaker slit.
d.rounded_rectangle((s(cx - 46), s(y0 + 46), s(cx + 46), s(y0 + 64)), radius=s(9),
                    fill=(255, 255, 255, 255))
# Record dot with a white ring.
r_ring, r_dot = 124, 90
d.ellipse((s(cx - r_ring), s(cy + 24 - r_ring), s(cx + r_ring), s(cy + 24 + r_ring)),
          outline=(255, 255, 255, 255), width=s(20))
d.ellipse((s(cx - r_dot), s(cy + 24 - r_dot), s(cx + r_dot), s(cy + 24 + r_dot)),
          fill=(229, 57, 53, 255))
fg = fg.resize((N, N), Image.LANCZOS)

bg.save(f'{out}/background.png')
fg.save(f'{out}/foreground.png')
# Flattened previews: full square, and masked like a launcher squircle.
flat = Image.alpha_composite(bg, fg)
flat.resize((144, 144), Image.LANCZOS).save(f'{out}/startIcon.png')
mask = Image.new('L', (N, N), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, N, N), radius=230, fill=255)
prev = Image.new('RGBA', (N, N), (255, 255, 255, 255))
prev.paste(flat, (0, 0), mask)
prev.resize((256, 256), Image.LANCZOS).save(f'{out}/preview.png')
