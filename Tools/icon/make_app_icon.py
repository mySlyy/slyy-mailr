#!/usr/bin/env python3
"""Generate the Slyy Mailr app icon set (AppIcon.appiconset) from one SVG design.

Design: envelope outlined in Slyy blue (#2b3bff) with the Slyy blue dot as its seal.
- mac: white rounded tile on the Apple 1024 grid (824 px tile, 100 px transparent margin).
- iOS: full-bleed opaque white square (iOS masks the corners itself).
- 16/32 px get a heavier stroke variant so the envelope still reads.
Needs rsvg-convert (brew install librsvg). Run from anywhere:
    python3 Tools/icon/make_app_icon.py
"""
import pathlib
import subprocess

BLUE = "#2b3bff"
ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset"


def motif(stroke: int, dot_r: int) -> str:
    """Envelope + seal dot, drawn on the 1024 grid inside the 824 tile."""
    return (
        f'<rect x="222" y="322" width="580" height="400" rx="44" fill="#fff" '
        f'stroke="{BLUE}" stroke-width="{stroke}"/>'
        f'<polyline points="246,346 512,555 778,346" fill="none" stroke="{BLUE}" '
        f'stroke-width="{stroke}" stroke-linejoin="round"/>'
        # white ring separates the seal from the flap lines
        f'<circle cx="512" cy="555" r="{dot_r}" fill="{BLUE}" stroke="#fff" stroke-width="24"/>'
    )


def svg(tile: str, stroke: int, dot_r: int) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{tile}{motif(stroke, dot_r)}</svg>'


MAC_TILE = '<rect x="100" y="100" width="824" height="824" rx="185" fill="#fff"/>'
# iOS: full-bleed white square, motif slightly enlarged but clear of the corner mask (no alpha)
IOS = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="40 40 944 944">'
    f'<rect x="0" y="0" width="1024" height="1024" fill="#fff"/>{motif(30, 120)}</svg>'
)

# filename -> pixel size (from Contents.json)
MAC = {"16@1x": 16, "16@2x": 32, "32@1x": 32, "32@2x": 64, "128@1x": 128, "128@2x": 256,
       "256@1x": 256, "256@2x": 512, "512@1x": 512, "512@2x": 1024}


def render(src: str, px: int, dest: pathlib.Path, opaque: bool = False) -> None:
    cmd = ["rsvg-convert", "-w", str(px), "-h", str(px), "-o", str(dest)]
    if opaque:
        cmd[1:1] = ["-b", "#ffffff"]
    subprocess.run(cmd, input=src.encode(), check=True)


for name, px in MAC.items():
    # small sizes: heavier lines + bigger seal
    src = svg(MAC_TILE, 52, 135) if px <= 32 else svg(MAC_TILE, 30, 120)
    render(src, px, OUT / f"mac-{name}.png")
render(IOS, 1024, OUT / "ios-1024.png", opaque=True)
(ROOT / "Tools/icon/app_icon.svg").write_text(svg(MAC_TILE, 30, 120) + "\n")
print("icon set written to", OUT)
