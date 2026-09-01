"""Offline PNG preview renderer for knowledge/structures/*.json (Pillow, no game
instance needed -- pure validation of the JSON grids at real pixel scale before
handing the library to @world).

Colors approximate each logical material token's real Powder Toy element color
(see knowledge/structures/README.md's resolve table) so the preview reads the
way it will actually look in-game. Each structure is rendered at 12x zoom (1
world px -> 12 preview px) with a 1px grid guide and the player's 12px height
drawn alongside for scale, since that comparison is the whole point of the
"does this read as a doorway/window/roof at real scale" check.

Usage:
    python scripts/render_structures.py                # renders the curated set below
    python scripts/render_structures.py --all          # renders all 30
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

STRUCT_DIR = Path("D:/powder-toy/knowledge/structures")
OUT_DIR = Path("D:/powder-toy/knowledge/previews")
OUT_DIR.mkdir(parents=True, exist_ok=True)

ZOOM = 12
PLAYER_W, PLAYER_H = 4, 10  # the REAL player box, from BOXL/BOXR/BOXT in rpg.lua

# Approximate real Powder Toy element colors for each logical material token
# (same tokens as the has()-guarded resolve table in structures/README.md).
# air/keep are drawing directives, not materials -- handled separately below.
COLORS = {
    "wood":          (140, 90, 45),
    "stone":         (130, 130, 130),
    "brick":         (150, 95, 75),
    "concrete":      (140, 140, 130),
    "glass":         (200, 255, 255),
    "glass_colored": (110, 190, 220),
    "metal":         (180, 180, 190),
    "metal_old":     (120, 110, 100),
    "bronze":        (170, 120, 60),
    "iron_ore":      (160, 130, 110),
    "coal":          (35, 35, 35),
    "gold":          (255, 215, 0),
    "copper":        (184, 115, 51),
    "clay":          (110, 85, 60),
    "crystal":       (225, 190, 230),
    "plant":         (60, 170, 60),
    "glow":          (255, 250, 200),
    "bone":          (225, 210, 180),
    "ice":           (180, 220, 255),
    "snow":          (245, 245, 255),
    "sand":          (225, 200, 140),
    "water":         (40, 90, 200),
    "lava":          (255, 90, 10),
    "control":       (255, 120, 120),   # PSCN control pad
}
DOOR_BG = (255, 200, 60)   # the "door" token: a real door object, not a hole in a wall
AIR_BG = (18, 18, 22)     # forced-empty cavity: dark, like real cave air
KEEP_BG = (54, 42, 34)    # transparent/terrain cell: muted earth tone so it visually recedes vs authored material
GRID_LINE = (0, 0, 0, 40)


def load(id_: str) -> dict:
    return json.loads((STRUCT_DIR / f"{id_}.json").read_text(encoding="utf-8"))


def render(id_: str) -> Path:
    s = load(id_)
    w, h = s["width"], s["height"]
    legend = s["legend"]
    grid = s["grid"]
    pad = 3
    MIN_W = 260  # tiny detail structures (2-6px) still need room for the caption line
    img_w = max(MIN_W, w * ZOOM + pad * 2)
    img = Image.new("RGB", (img_w, (h + 2) * ZOOM + pad * 2 + 20), (30, 30, 34))
    d = ImageDraw.Draw(img, "RGBA")

    for gy, row in enumerate(grid):
        for gx, ch in enumerate(row):
            token = legend.get(ch, "keep")
            if token == "air":
                col = AIR_BG
            elif token == "door":
                col = DOOR_BG
            elif token == "keep":
                col = KEEP_BG
            else:
                col = COLORS.get(token, (255, 0, 255))  # magenta = missing color mapping, should never show
            x0, y0 = pad + gx * ZOOM, pad + gy * ZOOM
            d.rectangle([x0, y0, x0 + ZOOM - 1, y0 + ZOOM - 1], fill=col)
    for gx in range(w + 1):
        x = pad + gx * ZOOM
        d.line([(x, pad), (x, pad + h * ZOOM)], fill=GRID_LINE)
    for gy in range(h + 1):
        y = pad + gy * ZOOM
        d.line([(pad, y), (pad + w * ZOOM, y)], fill=GRID_LINE)

    # anchor marker: a magenta crosshair at the placement point
    ax, ay = s["anchor"]["x"], s["anchor"]["y"]
    cx, cy = pad + ax * ZOOM + ZOOM // 2, pad + ay * ZOOM + ZOOM // 2
    d.line([(cx - 8, cy), (cx + 8, cy)], fill=(255, 0, 255), width=2)
    d.line([(cx, cy - 8), (cx, cy + 8)], fill=(255, 0, 255), width=2)

    # THE POINT OF THIS RENDERER: the player, at true relative size, standing in the doorway.
    # One grid cell is `sc` WORLD pixels, so the 4x10px player is only 4/sc x 10/sc cells -- drawing
    # him as a fixed 12px bar (which is what this did while a cell was worth one world pixel) makes
    # every structure look correctly proportioned no matter how wrong it is.
    sc = s.get("scale", 1)
    pw = max(2, round(PLAYER_W / sc * ZOOM))
    ph = max(3, round(PLAYER_H / sc * ZOOM))
    doors = [o for o in s.get("objects", []) if o.get("kind") == "door"]
    if doors:
        o = doors[0]
        fx = pad + o["gx"] * ZOOM + (ZOOM - pw) // 2
        fy = pad + (o["gy"] + 1) * ZOOM        # feet on the row below the door's bottom cell
        d.rectangle([fx, fy - ph, fx + pw, fy], fill=(255, 90, 200), outline=(255, 255, 255))

    scale_y0 = pad + h * ZOOM + 10
    d.rectangle([pad, scale_y0 + 12 - ph, pad + pw, scale_y0 + 12], fill=(255, 90, 200))
    try:
        font = ImageFont.load_default()
    except Exception:
        font = None
    d.text((pad + pw + 6, scale_y0),
           f"{id_}  {w}x{h} cells @ {sc}px = {w * sc}x{h * sc} world px"
           f"  (pink = {PLAYER_W}x{PLAYER_H}px player, to scale)",
           fill=(230, 230, 230), font=font)

    out = OUT_DIR / f"{id_}.png"
    img.save(out)
    return out


CURATED = [
    "surface_cabin_small", "surface_watchtower", "surface_well",
    "underground_mineshaft_junction", "underground_sealed_vault",
    "deep_crystal_chamber", "deep_abandoned_reactor_room",
    "detail_campfire_small",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--ids", nargs="*")
    args = ap.parse_args()
    if args.ids:
        ids = args.ids
    elif args.all:
        ids = sorted(p.stem for p in STRUCT_DIR.glob("*.json"))
    else:
        ids = CURATED
    for i in ids:
        out = render(i)
        print(f"rendered {i} -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
