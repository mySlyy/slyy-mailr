"""Slyy Mailr icon: white macOS squircle, Slyy blue dot, white envelope inside the dot."""
import sys, os
from PIL import Image, ImageDraw, ImageFilter

BLUE = (43, 59, 255, 255)   # #2B3BFF
SS = 4                      # supersampling

def envelope(d, cx, cy, w, h, stroke, color):
    x0, y0, x1, y1 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
    r = stroke * 1.1
    d.rounded_rectangle([x0, y0, x1, y1], radius=r * 1.6, outline=color, width=int(stroke))
    # flap: a V from the top corners to the middle
    inset = stroke * 0.9
    d.line([(x0 + inset, y0 + inset), (cx, cy + h * 0.06), (x1 - inset, y0 + inset)], fill=color, width=int(stroke), joint="curve")
    for p in [(x0 + inset, y0 + inset), (cx, cy + h * 0.06), (x1 - inset, y0 + inset)]:
        d.ellipse([p[0] - stroke / 2, p[1] - stroke / 2, p[0] + stroke / 2, p[1] + stroke / 2], fill=color)

def mac_icon(size=1024):
    S = size * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Big Sur grid: 824/1024 body, radius ~185/1024, soft shadow below
    body = 824 / 1024 * S
    off = (S - body) / 2
    radius = 185 / 1024 * S
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([off, off + 12 * SS, off + body, off + body + 12 * SS], radius=radius, fill=(0, 0, 0, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18 * SS))
    img.alpha_composite(shadow)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([off, off, off + body, off + body], radius=radius, fill=(255, 255, 255, 255))
    d.rounded_rectangle([off, off, off + body, off + body], radius=radius, outline=(226, 226, 226, 255), width=2 * SS)
    draw_mark(d, S / 2, S / 2, body * 0.66)
    return img.resize((size, size), Image.LANCZOS)

def draw_mark(d, cx, cy, dot):
    d.ellipse([cx - dot / 2, cy - dot / 2, cx + dot / 2, cy + dot / 2], fill=BLUE)
    envelope(d, cx, cy + dot * 0.01, dot * 0.52, dot * 0.36, max(2, dot * 0.045), (255, 255, 255, 255))

def ios_icon(size=1024):
    S = size * SS
    img = Image.new("RGBA", (S, S), (255, 255, 255, 255))   # iOS masks the corners itself
    draw_mark(ImageDraw.Draw(img), S / 2, S / 2, S * 0.62)
    return img.resize((size, size), Image.LANCZOS).convert("RGB")

if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    big = mac_icon(1024)
    big.save(os.path.join(out, "preview-mac.png"))
    ios_icon(1024).save(os.path.join(out, "preview-ios.png"))
    if len(sys.argv) > 2:   # write into the asset catalog
        cat = sys.argv[2]
        for pt in [16, 32, 128, 256, 512]:
            for sc in [1, 2]:
                px = pt * sc
                img = mac_icon(px) if px >= 64 else big.resize((px, px), Image.LANCZOS)
                img.save(os.path.join(cat, f"mac-{pt}@{sc}x.png"))
        ios_icon(1024).save(os.path.join(cat, "ios-1024.png"))
