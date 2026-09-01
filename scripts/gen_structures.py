"""Generate the community-derived structure library as knowledge/structures/*.json.

Source: knowledge/research-community-structures.md (harvested community save analysis)
and the existing world generator conventions in scripts/lua/rpg_plugins/world.lua
(logical material tokens resolved via has()-guarded fallback chains, erosion via a
single noise threshold, ore/props woven into rock rather than boxed as loot).

Each structure is authored here as a small 2D character grid (easier to keep
readable/editable than hand-written JSON) and dumped to
knowledge/structures/<id>.json. See knowledge/structures/README.md for the full
schema this writes and the Lua loader that reads it back in-game.

Re-run after editing any structure below:
    python scripts/gen_structures.py
"""
from __future__ import annotations

import json
from pathlib import Path

OUT = Path("D:/powder-toy/knowledge/structures")
OUT.mkdir(parents=True, exist_ok=True)

# air        -> forced empty (hollows out solid rock/soil; carves a real cavity)
# keep       -> transparent: this cell has no opinion, the base terrain generator
#               decides (used at footprint edges so e.g. a rubble pile doesn't
#               punch a rectangular hole in the ground it's sitting on)
# door       -> a real DOOR, not a hole in a wall. Until now a "door" was literally an
#               absent wall cell (surface_cabin_small row 11 was `WWWW..WWWWW` and that
#               was the entire mechanism). world.lua normalises this token to "air" ONCE
#               at load so sQuery's per-pixel path is untouched, and the objects[] array
#               written beside the grid tells it which cells are alive.
# any other legend value is a *logical material token*, resolved to a real
# element id at load time by the has()-guarded table in structures/README.md
AIR, KEEP, DOOR = "air", "keep", "door"
DOOR_CH = "+"

# Player box, from BOXL/BOXR/BOXT in rpg.lua. Every size assertion below is in WORLD
# PIXELS against this, never in grid cells -- a grid cell is worth isc pixels and that
# multiplier is the whole reason the library shipped unenterable buildings the first time.
PLAYER_W, PLAYER_H = 4, 10
# Category scale, mirrors SCAT in world.lua.
CAT_SC = {"surface": 20, "detail": 6, "underground": 12, "deep": 12}
# Target world-pixel width for a dense multi-room grid, mirrors the constant in sScale().
DENSE_W = 460


def sscale(w: int, h: int, sc: int) -> int:
    """World pixels per grid cell. MUST stay in sync with sScale() in world.lua:1057.

    Detail budget and world footprint are separate axes. A 30x22 cabin at the full
    landmark sc=20 would be 600x440px on a 612x384 screen -- you could never see it
    whole -- so a dense grid spends its extra cells on DETAIL (thinner walls, a real
    door, a hallway, a second storey) at a roughly constant landmark footprint.
    """
    cells = w * h
    if cells >= 400:
        return max(8, min(sc, DENSE_W // w))
    if cells >= 150:
        return sc
    if cells >= 60:
        return max(4, int(sc * 0.6))
    return max(3, int(sc * 0.3))


class Grid:
    """Tiny char-grid builder so structures read as ASCII art, not JSON escapes."""

    def __init__(self, w: int, h: int, fill: str = " "):
        self.w, self.h = w, h
        self.rows = [[fill] * w for _ in range(h)]

    def set(self, x: int, y: int, ch: str):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.rows[y][x] = ch

    def hline(self, x0: int, x1: int, y: int, ch: str):
        for x in range(x0, x1 + 1):
            self.set(x, y, ch)

    def vline(self, x: int, y0: int, y1: int, ch: str):
        for y in range(y0, y1 + 1):
            self.set(x, y, ch)

    def rect(self, x0: int, y0: int, x1: int, y1: int, ch: str):
        self.hline(x0, x1, y0, ch)
        self.hline(x0, x1, y1, ch)
        self.vline(x0, y0, y1, ch)
        self.vline(x1, y0, y1, ch)

    def fill_rect(self, x0: int, y0: int, x1: int, y1: int, ch: str):
        for y in range(y0, y1 + 1):
            self.hline(x0, x1, y, ch)

    def strs(self) -> list[str]:
        return ["".join(r) for r in self.rows]


def classify_orientation(grid: Grid, chars: set[str]) -> dict[tuple[int, int], str]:
    """For each cell whose char is in `chars`, measure the contiguous same-char run through
    it vertically and horizontally, and classify 'x' (a VERTICAL wall segment -- thin it along
    the x axis, i.e. reduce its WIDTH) if the vertical run is >= the horizontal run, else 'y'
    (a HORIZONTAL segment -- thin along y, reduce its HEIGHT). Used by struct()'s `thin=` to
    split one authored wall character into two runtime-thinnable variants automatically, instead
    of hand-classifying every wall cell in every structure by eye.

    Known limitation, accepted rather than hidden: at an L-corner where a vertical run and a
    horizontal run meet in the SAME character (e.g. a perimeter column immediately beside a
    horizontal interior partition that starts right next to it), the two runs merge into one
    contiguous run in whichever direction is longer, and the corner cell can be classified with
    the wrong axis. This affects at most the single corner cell, not the run's overall thinness,
    and is visually harmless (a corner reads fine thinned on either axis) -- verified by eye on
    surface_cabin_small's rendered grid before shipping, not assumed.
    """
    out = {}
    for y in range(grid.h):
        for x in range(grid.w):
            ch = grid.rows[y][x]
            if ch not in chars:
                continue
            vy0 = y
            while vy0 > 0 and grid.rows[vy0 - 1][x] == ch:
                vy0 -= 1
            vy1 = y
            while vy1 < grid.h - 1 and grid.rows[vy1 + 1][x] == ch:
                vy1 += 1
            vrun = vy1 - vy0 + 1
            hx0 = x
            while hx0 > 0 and grid.rows[y][hx0 - 1] == ch:
                hx0 -= 1
            hx1 = x
            while hx1 < grid.w - 1 and grid.rows[y][hx1 + 1] == ch:
                hx1 += 1
            hrun = hx1 - hx0 + 1
            out[(x, y)] = "x" if vrun >= hrun else "y"
    return out


def door_openings(grid: Grid) -> list[tuple[int, int, int, int]]:
    """Group contiguous DOOR_CH cells into openings -> (gx0, gy0, gx1, gy1) inclusive."""
    seen, out = set(), []
    for y in range(grid.h):
        for x in range(grid.w):
            if grid.rows[y][x] != DOOR_CH or (x, y) in seen:
                continue
            stack, cells = [(x, y)], []
            seen.add((x, y))
            while stack:
                cx, cy = stack.pop()
                cells.append((cx, cy))
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if (0 <= nx < grid.w and 0 <= ny < grid.h and (nx, ny) not in seen
                            and grid.rows[ny][nx] == DOOR_CH):
                        seen.add((nx, ny))
                        stack.append((nx, ny))
            xs, ys = [c[0] for c in cells], [c[1] for c in cells]
            out.append((min(xs), min(ys), max(xs), max(ys)))
    return sorted(out)


# Tokens whose real element has Falldown != 0 / no TYPE_SOLID in this build, so a cell of it
# does not stay where the grid puts it. Verified against the running game's own element table
# (R.eid + elem.property): BGLA/CLST/SAND/SNOW/BRMT are powders, GLOW/WATR/LAVA flow.
# They are fine as loose contents -- an ember, a lamp, a reservoir, a bone pit -- and fatal in a
# wall, which is what the loose_gone flood below exists to catch.
LOOSE = {"glass_colored", "glow", "clay", "sand", "bone", "water", "lava", "snow", "bronze"}


def flood(grid: Grid, legend: dict, doors_open: bool, loose_gone: bool = False) -> set[tuple[int, int]]:
    """Cells reachable from OUTSIDE the footprint, entering only through open cells.

    Seeded from a 1-cell ring around the grid, so the only way in is a boundary cell the
    author actually left open. "keep" is passable: it means "the terrain generator decides",
    which above ground is air and is exactly the ground a player walks in over.

    loose_gone models every non-solid material having fallen out of place, which is what
    actually happens the first tick a powder or fluid is stamped into a wall.
    """
    def passable(x, y):
        if not (0 <= x < grid.w and 0 <= y < grid.h):
            return True                       # the ring
        tok = legend.get(grid.rows[y][x], KEEP)
        if tok == DOOR:
            return doors_open
        if loose_gone and tok in LOOSE:
            return True
        return tok in (AIR, KEEP)

    start, seen = (-1, -1), set()
    stack = [start]
    seen.add(start)
    while stack:
        cx, cy = stack.pop()
        for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
            if not (-1 <= nx <= grid.w and -1 <= ny <= grid.h) or (nx, ny) in seen:
                continue
            if passable(nx, ny):
                seen.add((nx, ny))
                stack.append((nx, ny))
    return seen


def standing_boxes(grid: Grid, legend: dict, isc: int, reach: set) -> list[tuple[int, int]]:
    """Reachable spots where the player can actually stand up, in WORLD pixels.

    Needs ceil(4/isc) x ceil(10/isc) authored-AIR cells, reachable, resting on a solid cell.
    """
    cw = -(-PLAYER_W // isc)
    ch = -(-PLAYER_H // isc)

    def air(x, y):
        return (0 <= x < grid.w and 0 <= y < grid.h
                and legend.get(grid.rows[y][x], KEEP) in (AIR, DOOR) and (x, y) in reach)

    def solid(x, y):
        if not (0 <= x < grid.w and 0 <= y < grid.h):
            return False
        return legend.get(grid.rows[y][x], KEEP) not in (AIR, KEEP, DOOR)

    out = []
    for y in range(grid.h):
        for x in range(grid.w):
            if (all(air(x + dx, y - dy) for dx in range(cw) for dy in range(ch))
                    and all(solid(x + dx, y + 1) for dx in range(cw))):
                out.append((x, y))
    return out


def struct(
    id_, category, description, biomes, depth_band, rest_on_solid, erodible,
    rarity, min_spacing, clearance, anchor, grid: Grid, legend: dict, notes,
    loot=None, variants=None, enterable=False, thin=None, deco=None,
):
    """`thin`: optional {src_char: (horizontal_variant_char, px)}. Community wall thickness
    measures a median 2px contiguous run vs our authored cells being a full `isc`px (15-20px)
    solid block (knowledge/research-community-aesthetics-measured.md). A grid cell stays ONE
    authored character for placement/validation purposes -- classify_orientation() splits it
    into two runtime-thinnable variants (src_char kept for vertical/x-thin runs, the new variant
    char for horizontal/y-thin runs) so world.lua's sQuery can render only `px` world-pixels of
    material flush to the run's outward edge instead of filling the whole authored cell, without
    changing the footprint, the door objects, or the offline enterable=True validation below
    (which still conservatively treats the cell as fully solid -- thinning only ever makes the
    runtime MORE open than the validator assumed, never less, so a structure that validates safe
    stays safe).
    `deco`: optional {grid_char: {r,g,b,a}} -- a pure recolor tint (sim.decoBox at runtime),
    applied ONLY to cells that already have a material stamped there. Never changes what material
    a cell resolves to; see knowledge/structures/README.md's DECO section for the physics proof.
    """
    legend = {" ": KEEP, ".": AIR, DOOR_CH: DOOR, **legend}
    thin_meta = {}
    if thin:
        chars = set(thin.keys())
        orient = classify_orientation(grid, chars)
        for (x, y), axis in orient.items():
            if axis == "y":
                src_ch = grid.rows[y][x]
                variant_ch, _ = thin[src_ch]
                grid.rows[y][x] = variant_ch
        for src_ch, (variant_ch, px) in thin.items():
            thin_meta[src_ch] = {"axis": "x", "px": px}
            thin_meta[variant_ch] = {"axis": "y", "px": px}
            legend.setdefault(variant_ch, legend.get(src_ch))
    used = {c for row in grid.rows for c in row}
    missing = used - set(legend)
    if missing:
        raise ValueError(f"{id_}: grid uses undeclared symbols {missing}")
    isc = sscale(grid.w, grid.h, CAT_SC[category])

    def tok(x, y):
        if not (0 <= x < grid.w and 0 <= y < grid.h):
            return KEEP
        return legend.get(grid.rows[y][x], KEEP)

    # objects[]: metadata about which grid cells are ALIVE. Grid cells stay pure material
    # tokens so sQuery is unchanged; world.lua reads this once per accepted placement and
    # asks machines.lua to create the runtime record.
    openings = door_openings(grid)
    objects = []
    for (x0, y0, x1, y1) in openings:
        # CORE: machines.lua's reaper deletes a machine whose core pixel reads empty, so the core
        # must be a cell the grid ALWAYS fills and that opening/closing never moves. Never a door
        # block. Prefer the lintel directly above the opening, else the jamb beside it.
        core = next((c for c in ((x0, y0 - 1), (x0 - 1, y1), (x1 + 1, y1), (x0, y1 + 1))
                     if tok(*c) not in (AIR, KEEP, DOOR)), None)
        if core is None:
            raise ValueError(f"{id_}: door at ({x0},{y0}) has no solid lintel or jamb to host its core")
        # PAD: the control cell the player sparks. Optional -- a door with no pad is simply inert
        # until someone wires one, which is the right read for a ruin nobody has powered in years.
        pad = next(((x, y) for y in range(y0 - 2, y1 + 3) for x in range(x0 - 3, x1 + 4)
                    if tok(x, y) == "control"), None)
        o = {"kind": "door", "gx": x0, "gy": y1, "w": x1 - x0 + 1, "h": y1 - y0 + 1,
             "core_gx": core[0], "core_gy": core[1]}
        if pad:
            o["pad_gx"], o["pad_gy"] = pad
        objects.append(o)
    # recomputePower's flood fill runs over every machine every 15 frames and worldgen makes
    # that count unbounded during exploration, so a building gets a handful of live cells, not
    # a door per room. ponytail: hard cap, revisit if recomputePower ever gets a spatial index.
    if len(objects) > 3:
        raise ValueError(f"{id_}: {len(objects)} door objects, cap is 3 (recomputePower cost)")

    if enterable:
        if not openings:
            raise ValueError(f"{id_}: enterable but has no {DOOR_CH} door cell")
        for (x0, y0, x1, y1) in openings:
            wpx, hpx = (x1 - x0 + 1) * isc, (y1 - y0 + 1) * isc
            if wpx < 6 or hpx < 12:
                raise ValueError(
                    f"{id_}: door at ({x0},{y0}) is {wpx}x{hpx}px at sc={isc}; "
                    f"need >=6x12 for a {PLAYER_W}x{PLAYER_H}px player")
        shut = standing_boxes(grid, legend, isc, flood(grid, legend, doors_open=False))
        open_ = standing_boxes(grid, legend, isc, flood(grid, legend, doors_open=True))
        if not open_:
            raise ValueError(f"{id_}: no reachable {PLAYER_W}x{PLAYER_H}px standing spot inside")
        if len(open_) <= len(shut):
            raise ValueError(
                f"{id_}: opening the doors reveals no new standing spot -- the interior is "
                f"either sealed or already open to the outside, so the door is not the mechanism")
        # A shell that depends on a powder or a fluid is not a shell: it is a hole with a delay.
        # Falldown != 0 elements slump out of a wall on the first tick, which is the exact class of
        # bug that once dropped the whole world through its own subsoil.
        # Relative to the doors-shut baseline, not to zero: a structure may legitimately be open to
        # the outside somewhere else (the watchtower's lookout has arrow slits). What must not happen
        # is loose material falling away and opening something that was not already open.
        if len(standing_boxes(grid, legend, isc, flood(grid, legend, False, loose_gone=True))) > len(shut):
            loose_used = sorted({t for row in grid.rows for c in row
                                 if (t := legend.get(c, KEEP)) in LOOSE})
            raise ValueError(
                f"{id_}: the shell relies on non-solid material {loose_used} -- those have "
                f"Falldown != 0 and fall out of the wall, opening the interior. Use a solid token.")

    result = {
        "id": id_, "category": category, "description": description,
        "biomes": biomes, "depth_band": {"min": depth_band[0], "max": depth_band[1]},
        "rest_on_solid": rest_on_solid, "erodible": erodible,
        "rarity": rarity, "min_spacing": min_spacing, "clearance": clearance,
        "anchor": {"x": anchor[0], "y": anchor[1]},
        "width": grid.w, "height": grid.h, "scale": isc,
        "legend": legend, "grid": grid.strs(), "objects": objects,
        "loot": loot or [], "variants": variants or [],
        "notes": notes,
    }
    if thin_meta:
        result["thin"] = thin_meta
    if deco:
        result["deco"] = deco
    return result


ANY = ["any"]
STRUCTS = []


def add(*a, **kw):
    STRUCTS.append(struct(*a, **kw))


# ================================================================ SURFACE (8)
# anchor is always the grid cell that lands on the world placement point;
# for surface structures that point is (px, surfaceAt(px)) -- ground level.

g = Grid(30, 22)
g.fill_rect(1, 17, 28, 21, "F")                  # stone foundation; row 17 IS the ground floor
g.fill_rect(2, 6, 27, 16, "W")                   # wood shell
g.fill_rect(3, 7, 26, 16, ".")                   # hollow it out down onto the foundation
for x in range(1, 29):                            # gable roof, eaves at the walls, peak over the middle
    g.vline(x, 6 - int(5 * (1 - abs(x - 14.5) / 13.5)), 6, "R")   # 'R' = roof, own char so DECO can
                                                     # tint just the roofline distinct from the wall wood below
g.hline(3, 26, 11, "W")                          # upper storey floor slab
g.fill_rect(13, 11, 16, 11, ".")                 # stairwell: 4 cells (60px) of headroom between floors
g.vline(10, 12, 16, "W"); g.vline(19, 12, 16, "W")   # ground floor: three rooms off a central hall
g.fill_rect(10, 15, 10, 16, "."); g.fill_rect(19, 15, 19, 16, ".")   # interior arches (plain gaps, not doors)
g.vline(21, 7, 10, "W"); g.fill_rect(21, 9, 21, 10, ".")             # upper storey: bedroom + machine bay
g.fill_rect(23, 15, 26, 16, "M")                 # ground floor machine bay: a workbench/hearth slab
g.set(24, 14, "E")                               # banked ember over the hearth
g.set(2, 15, "+"); g.set(2, 16, "+")             # THE FRONT DOOR: a real door object, 15x30px at sc=15
g.set(3, 14, "P")                                # its control pad, on the inside wall beside the frame
g.set(2, 9, "G"); g.set(2, 13, "G")              # windows, punched through the actual wall columns
g.set(27, 9, "G"); g.set(27, 13, "G")
g.vline(24, 0, 5, "V")                           # chimney, offset from the peak
add("surface_cabin_small", "surface",
    "Two-storey log cabin: three ground-floor rooms off a central hall with a workbench/hearth bay, a stairwell up to a bedroom and an upper machine bay, four windows, a chimney. 30x22 cells at 15px/cell = 450x330 world px, ~33 player-heights tall, with a real 15x30px front door.",
    ["forest", "swamp", "snow"], (-4, 2), True, True, 0.16, 260,
    {"top": 2, "bottom": 0, "left": 2, "right": 2}, (0, 17),
    g, {"F": "stone", "W": "wood", "R": "wood", "G": "glass", "V": "metal_old", "M": "metal_old",
        "E": "glow", "P": "control"},
    "Regrid from 15x17 to 30x22. The old grid had no cells to spend: its interior was ONE 9x4-cell box, so 'a hallway, a second room, a machine bay' was not expressible at any scale. 660 cells buys all three at a SMALLER per-cell scale (15px vs 20px), which is the point -- footprint stays a 450x330px landmark that fits on a 612x384 screen while walls get thinner and the plan gets readable. anchor.x moved to 0: sRoll's slope test samples surfaceAt(wx0 .. wx0+w) but the footprint actually starts at inst.x0 - anchor.x*isc, so a centred anchor was slope-testing ground the building does not stand on. anchor.y 17 is the foundation's TOP row (README rule: rows >= anchor.y sit at-or-below surfaceAt), so the door's bottom cell (row 16) is exactly the row a standing player's feet occupy outside -- you walk straight in, no step up."
    " DECO+THIN pass (knowledge/research-community-aesthetics-measured.md): roof ('R') and window"
    " ('G') get a tint, per the community median 58.6% deco-tinted-particle finding vs our"
    " previous 0%; wall ('W') cells get auto-split by classify_orientation() into vertical (kept"
    " 'W') and horizontal ('H', the row-11 floor slab) runs, each rendered 2px thick flush to its"
    " outward edge at runtime instead of filling the whole 15px authored cell, matching the"
    " community median 2px wall run-length. Footprint, door object and enterable=True validation"
    " below are all unchanged -- thinning is a pure sQuery rendering choice in world.lua, not a"
    " change to the authored grid the validator sees."
    " DOORWAY SIZE -- CHECKED AND DELIBERATELY LEFT, do not 'fix' this again without re-reading"
    " research-community-aesthetics-measured.md section 3 first: this door is 15x30 world px"
    " (w=1,h=2 cells @ 15px), ~3x the real player box (4x10-11px, BOXL/BOXR/BOXT in rpg.lua),"
    " against a community MEDIAN of 12x10px (range 10-27 tall, 8-14 wide, n=28/75 openings, 6"
    " saves). That research document's own section 3 explicitly recommends AGAINST shrinking it:"
    " community doors don't have to clear a physics-driven player collision box, ours does, and a"
    " past incident already had to fix an 'unenterable building' bug by ENLARGING this exact door"
    " once. Shrinking it toward the community median risks recreating that bug to match a number"
    " measured on builds with a different constraint. Confirmed with @lead 2026-08-31 evening.",
    enterable=True,
    thin={"W": ("H", 2)},
    deco={
        "R": {"r": 96, "g": 46, "b": 28, "a": 200},   # roofline: darker warm red-brown vs plain WOOD, reads as shingles
        "G": {"r": 88, "g": 156, "b": 214, "a": 150},  # window trim: cool blue tint on solid GLAS -- the "colored glass"
                                                        # look the community favors (BGLA, a POWDER) without BGLA's
                                                        # Falldown=1 risk; see README's DECO physics proof.
    })

g = Grid(20, 34)
g.fill_rect(1, 30, 18, 33, "F")                  # stone footing; row 30 is the guard-room floor
g.fill_rect(2, 22, 17, 29, "F")                  # stone guard room at the base
g.fill_rect(3, 23, 16, 29, ".")                  # guard room interior, 14x7 cells = 280x140px
g.fill_rect(6, 6, 13, 22, "T")                   # timber shaft rising out of the guard room
g.fill_rect(7, 7, 12, 22, ".")
for y in range(10, 23, 4):                        # landings with an offset stair gap, so it is climbable
    g.hline(7, 12, y, "T"); g.fill_rect(10 if (y // 4) % 2 else 7, y, 12 if (y // 4) % 2 else 9, y, ".")
for y in range(7, 23):
    if y % 2 == 0:
        g.set(7, y, "L")                          # ladder rungs up the shaft's left side
g.fill_rect(2, 0, 17, 6, "T")                    # lookout box on top
g.fill_rect(3, 1, 16, 5, ".")
g.fill_rect(8, 6, 11, 6, ".")                    # roof hatch: the shaft actually opens into the lookout
g.set(2, 2, "."); g.set(17, 2, "."); g.set(2, 4, "."); g.set(17, 4, ".")   # arrow slits, punched through the wall columns only
g.set(2, 0, "R"); g.set(17, 0, "R")              # corner rail posts
g.set(2, 28, "+"); g.set(2, 29, "+")             # ground-level door into the guard room
g.set(3, 27, "P")                                # its control pad, inside beside the frame
g.set(15, 26, "M"); g.fill_rect(14, 27, 16, 29, "M")   # supply lockers in the guard room
add("surface_watchtower", "surface",
    "Stone guard room with a real door at ground level, a timber shaft above it with a ladder and four offset landings you can actually climb, opening through a roof hatch into a walled lookout with arrow slits and corner rails. 20x34 cells at 20px/cell = 400x680 world px.",
    ANY, (-2, 26), True, True, 0.06, 420,
    {"top": 3, "bottom": 0, "left": 2, "right": 2}, (0, 30),
    g, {"T": "wood", "F": "stone", "R": "metal_old", "L": "wood", "M": "metal_old", "P": "control"},
    "Regrid from 9x32. The old tower was a climbing frame with nothing at the bottom and nothing at the top: no enclosed space, no door, no way in -- at 20x it was a 180x640px ladder standing in a field. 680 cells buys the three parts a watchtower actually has (a room you shelter in, a shaft you climb, a lookout you stand in) and the landings alternate which side their stair gap is on so the climb is a real staircase rather than a single unbroken drop. Arrow slits are authored as air punched through the lookout's own walls, not as glass floating in the interior -- the old grid put its windows on interior cells, which drew glass in mid-air.",
    enterable=True)

g = Grid(9, 9)
g.vline(1, 3, 8, "F"); g.vline(7, 3, 8, "F")      # shaft side walls (rim pokes 1 row above ground, rest is embedded)
g.hline(1, 7, 8, "F")                             # floor cap at the bottom of the shaft
g.fill_rect(2, 3, 6, 7, ".")                       # open shaft interior -- NOT capped at the top (was a bug: rect() draws all 4 sides)
g.fill_rect(2, 6, 6, 7, "L")                        # water fills the lower part of the shaft, above the floor cap
g.hline(0, 2, 2, "R")                              # roof beam resting on the side walls, wider than the shaft (eaves)
g.hline(6, 8, 2, "R")
g.vline(0, 0, 2, "P"); g.vline(8, 0, 2, "P")      # support posts holding the roof beam
g.hline(3, 5, 0, "R")                             # small gabled cap
add("surface_well", "surface",
    "Stone ring well with a wood roof beam on two posts, an open (not capped) shaft down to a real water pool. 9x9px.",
    ["forest", "desert", "swamp"], (-1, 4), True, False, 0.12, 200,
    {"top": 1, "bottom": 0, "left": 1, "right": 1}, (4, 4),
    g, {"F": "stone", "L": "water", "R": "wood", "P": "wood"},
    "Real WATR at the bottom (finding #7: water is a static prop inside these builds, physics left alone). Anchor row 4 = first grounded row, so the rim (row 3) pokes exactly 1px above the surface and the shaft (rows 4-8) is embedded, matching how a real well reads (short visible rim, deep shaft). Desert oasis wells can reuse world.lua's existing oasisPoolAt logic instead of this one if @world prefers a single water-source mechanism.")

g = Grid(20, 10)
g.set(2, 6, "K")                                  # campfire ring (small, see detail_campfire_small for the standalone prop)
g.set(1, 6, "K"); g.set(3, 6, "K")
g.set(2, 5, "F")                                  # fire
g.fill_rect(6, 2, 9, 8, "T")                       # simple lean-to tent frame (wood poles)
g.fill_rect(7, 3, 8, 7, ".")
g.set(6, 2, "T"); g.set(9, 2, "T")
g.fill_rect(12, 7, 14, 8, "C")                     # crate stack
g.fill_rect(16, 6, 17, 8, "B")                     # barrel
add("surface_campsite", "surface",
    "Small camp: a lean-to tent frame, a fire ring, a crate stack and a barrel. Reads as 'someone was here' rather than a building. 20x10px.",
    ANY, (-2, 1), True, False, 0.10, 300,
    {"top": 1, "bottom": 0, "left": 1, "right": 1}, (0, 9),
    g, {"K": "stone", "F": "glow", "T": "wood", "C": "wood", "B": "metal_old"},
    "Composite of detail props (crate/barrel/campfire, see the detail_* structures) pre-arranged into one scene so world.lua can place the whole vignette in one roll instead of coordinating four independent ones. Fire uses 'glow' (static, inert) rather than real FIRE -- a live flame in procedurally generated terrain risks igniting nearby WOOD/PLNT unpredictably; @items/@world should swap in real FIRE deliberately if they want it live.")

g = Grid(16, 6)
g.fill_rect(0, 3, 15, 3, "D")                      # tilled soil row
g.set(2, 2, "P"); g.set(2, 1, "P")                 # crop stalks
g.set(6, 2, "P"); g.set(6, 1, "P")
g.set(10, 2, "P"); g.set(10, 1, "P")
g.set(13, 2, "P"); g.set(13, 1, "P")
g.vline(0, 0, 3, "F"); g.vline(15, 0, 3, "F")      # fence posts at the ends
add("surface_farm_plot", "surface",
    "A row of tilled soil with plant stalks between two fence posts -- a wild/abandoned farm patch, not a player-built one. 16x6px.",
    ["forest", "swamp"], (-3, 0), True, False, 0.14, 180,
    {"top": 1, "bottom": 0, "left": 1, "right": 1}, (0, 3),
    g, {"D": "clay", "P": "plant", "F": "wood"},
    "Deliberately small/sparse (a discoverable trace of past habitation) rather than a functional farming feature -- Drew's ask was exploration variety, not a farming mechanic; @progression owns actual farming if that's ever added.")

g = Grid(24, 6)
g.fill_rect(0, 4, 2, 5, "F")                       # left pier
g.fill_rect(21, 4, 23, 5, "F")
g.hline(2, 21, 3, "S")                             # deck
g.hline(2, 21, 4, "S")
g.vline(11, 2, 3, "F"); g.vline(12, 2, 3, "F")     # mid support pier (only used if span rests over a gap)
add("surface_bridge_wood", "surface",
    "Flat stone-deck footbridge on two end piers plus a mid-span pier, spanning a gap (ravine/cave mouth/water). 24x6px, deck 2px thick.",
    ANY, (-2, 4), False, True, 0.09, 260,
    {"top": 1, "bottom": 3, "left": 1, "right": 1}, (0, 4),
    g, {"F": "stone", "S": "stone"},
    "rest_on_solid=false deliberately: bridges are exactly the case where the placement check should instead verify a GAP (open air/cave/ravine) under the middle third, per finding from 58442/1108906 (deck over air/water, not fill). README documents the alternate 'spans-a-gap' placement rule for this one structure.")

g = Grid(3, 8)
g.vline(1, 0, 6, "T")                              # post
g.hline(0, 2, 6, "T")                              # ground brace
g.set(1, 1, "S")                                    # sign board
add("surface_signpost", "surface",
    "A single wood post with a small sign board -- a wayfinding/flavor prop, not a quest system. 3x8px.",
    ANY, (-1, 0), True, False, 0.20, 140,
    {"top": 1, "bottom": 0, "left": 1, "right": 1}, (1, 6),
    g, {"T": "wood", "S": "wood"},
    "No harvested save had readable signage (text doesn't survive as particles); left generic. @ui could draw actual text over this prop's world position the way chest markers are already drawn, if flavor text is wanted later.")

g = Grid(18, 10)
g.rect(0, 2, 17, 9, "F")
for x in (0, 2, 5, 8, 11, 14, 17):                  # crenellations: gap every 3rd merlon
    g.set(x, 1, "F")
g.fill_rect(1, 3, 16, 8, ".")
g.set(4, 8, "."); g.set(5, 8, ".")                 # collapsed gap at the base (finding #4)
g.set(12, 3, "."); g.set(13, 3, "."); g.set(13, 4, ".")  # eroded corner
add("surface_ruined_wall", "surface",
    "A crumbling brick/stone wall segment with a crenellated top, a collapsed gap at the base and an eroded corner -- a leftover fortification, not a full building. 18x10px.",
    ["desert", "forest"], (-8, 2), True, True, 0.13, 240,
    {"top": 1, "bottom": 0, "left": 1, "right": 1}, (0, 9),
    g, {"F": "brick"},
    "Crenellation motif directly from 304820/2390773 castle saves (alternating solid/gap merlons along the top edge). Erosion holes are hand-placed here rather than via the generic pass so the 'ruined' read is guaranteed even before the per-instance erosion roll runs.")

# ================================================================ UNDERGROUND (8)
# anchor point = (px, surfaceAt(px) + d0) i.e. a point already below ground.

g = Grid(30, 16)
g.hline(0, 29, 5, "T"); g.hline(0, 29, 12, "T")      # gallery roof and floor planks
g.fill_rect(0, 6, 29, 11, ".")                       # east-west gallery, 6 cells = 72px of headroom
g.fill_rect(12, 0, 17, 15, ".")                      # north-south cross shaft, punched through both planks
for x in range(2, 30, 4):
    g.set(x, 6, "T"); g.set(x, 11, "T")              # post stubs at ceiling and floor -- framing you walk PAST,
g.fill_rect(13, 0, 16, 15, ".")                      # not full columns that seal the gallery
# Guide rails sit in the shaft ABOVE and BELOW the gallery only. Run full height they are a solid
# 12px metal wall at cols 12 and 17, severing the east-west gallery this junction exists to join.
g.vline(12, 0, 4, "R"); g.vline(17, 0, 4, "R")
g.vline(12, 13, 15, "R"); g.vline(17, 13, 15, "R")
g.fill_rect(14, 10, 15, 11, "C"); g.set(14, 12, "M"); g.set(15, 12, "M")   # ore cart on the rails
g.set(7, 10, "B"); g.fill_rect(22, 10, 23, 11, "C")  # scattered barrel / crate
add("underground_mineshaft_junction", "underground",
    "A four-way junction: a timber-framed east-west gallery 72px tall crossing a full-height north-south rail shaft, post stubs at ceiling and floor, an ore cart standing on the rails. 30x16 cells at 12px/cell = 360x192 world px.",
    ANY, (60, 900), True, False, 0.16, 340,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 8),
    g, {"T": "wood", "R": "metal_old", "C": "metal_old", "M": "metal", "B": "metal_old"},
    "Regrid from 22x9. The old support posts were full-height columns spanning the gallery, which at 12px/cell is a solid 12px-wide wall of wood every 5 cells -- the 'junction' was impassable in the direction it existed to let you travel. Posts are now stubs at the ceiling and floor lines, which is also how real mine framing reads. No door: a junction is a crossing, not a room.")

g = Grid(20, 7)
g.fill_rect(0, 2, 19, 4, ".")
g.fill_rect(6, 0, 13, 2, "D")                        # partial cave-in (rubble filling half the tunnel height)
g.set(7, 2, "D"); g.set(8, 2, "D"); g.set(11, 2, "D"); g.set(12, 2, "D")
g.vline(3, 1, 4, "T"); g.hline(2, 4, 1, "T")         # a snapped support beam, still half up
add("underground_collapsed_tunnel", "underground",
    "A mine tunnel with a partial cave-in: rubble fills roughly half the passage height and a support beam has snapped -- passable but tight, reads as danger. 20x7px.",
    ANY, (60, 900), True, False, 0.14, 260,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 3),
    g, {"D": "stone", "T": "wood"},
    "Rubble is real solid material woven into the passage (not decoration on top), so it actually narrows the path the way world.lua's own R.crumble() debris does; the snapped beam is two disconnected wood segments, not one -- reads as broken without needing the felling/physics system.")

g = Grid(30, 16)
g.fill_rect(1, 2, 28, 14, "T")                        # timber lining of the excavation
g.fill_rect(2, 3, 27, 13, ".")                        # excavated volume, 26x11 cells = 312x132px
g.vline(15, 3, 13, "T")                               # partition: bunkroom | store room
g.set(15, 12, "+"); g.set(15, 13, "+")                # a real door between the two chambers
g.set(16, 11, "P")                                    # its control pad, store-room side
g.set(1, 12, "."); g.set(1, 13, ".")                  # tunnel mouth: this room opens off a mine corridor
for x in range(4, 28, 6):
    g.set(x, 3, "T"); g.set(x, 13, "T")               # roof props and floor sills, stubs not columns
g.fill_rect(3, 12, 6, 13, "T")                        # bunk
g.set(9, 13, "K"); g.set(10, 13, "K"); g.set(9, 12, "V")   # fire ring with a banked ember
g.fill_rect(12, 12, 13, 13, "C")                      # crate stack
g.fill_rect(18, 12, 19, 13, "B"); g.fill_rect(21, 12, 22, 13, "C")   # store room stock
g.vline(25, 3, 11, "L")                               # ladder up, hanging clear of the floor
add("underground_miners_camp", "underground",
    "A two-chamber miners' camp cut off a mine corridor: a bunkroom with a bunk, a fire ring and crates, a real door through the partition into a store room with barrels and a ladder up. 30x16 cells at 12px/cell = 360x192 world px.",
    ANY, (80, 500), True, False, 0.12, 300,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 14),
    g, {"T": "wood", "K": "stone", "V": "glow", "C": "wood", "B": "metal_old", "L": "wood", "P": "control"},
    "Regrid from 16x8. The old room was 16x8 cells with every prop on the floor row -- one undivided box. 480 cells buys a partition, a real door and two chambers that read differently (living vs storage), which is the difference between a prop and a place. The ladder stops at row 11 rather than reaching the floor so it hangs clear as a climbable rung column instead of walling off the store room's corner.",
    enterable=True)

g = Grid(8, 5)
g.fill_rect(0, 3, 7, 4, ".")
g.vline(1, 0, 4, "R"); g.vline(6, 0, 4, "R")           # rails
g.fill_rect(2, 2, 5, 4, "C")                            # cart body
g.set(2, 4, "M"); g.set(5, 4, "M")                       # wheels (metal accent)
add("underground_ore_cart", "underground",
    "A stray ore cart sitting on a short stub of rail -- a 'detail' scaled up slightly because it needs its own rail segment. 8x5px.",
    ANY, (60, 900), True, False, 0.10, 150,
    {"top": 0, "bottom": 0, "left": 1, "right": 1}, (3, 4),
    g, {"R": "metal_old", "C": "wood", "M": "metal"},
    "Placed independently of underground_mineshaft_junction (not every junction needs one, and stray carts read well alone in a corridor) -- same rail/cart vocabulary, smaller footprint, higher rarity so it shows up more often as incidental detail.")

g = Grid(3, 40)
g.vline(0, 0, 39, "P"); g.vline(2, 0, 39, "P")          # two side rails
for y in range(0, 40, 3):
    g.set(1, y, "P")                                     # rungs every 3px
g.fill_rect(0, 0, 2, 39, ".")                            # the shaft itself is air except the rungs (fall-through climbable column)
for y in range(0, 40, 3):
    g.set(1, y, "P")
add("underground_ladder_shaft", "underground",
    "A vertical wood ladder in its own narrow air shaft connecting two depths, rungs every 3px (a quarter of the player's height). 3x40px -- long, meant to be placed sparingly to connect a surface entrance or room to a deep pocket.",
    ANY, (20, 900), False, False, 0.05, 500,
    {"top": 2, "bottom": 2, "left": 1, "right": 1}, (1, 0),
    g, {"P": "wood"},
    "rest_on_solid=false: a ladder shaft's *bottom* should land on solid ground (checked at placement, see README) but the shaft itself passes through open cave space by design -- it's meant to be the fast way down through an existing cavern, like Minecraft's dungeon ladders.")

g = Grid(24, 18)
g.fill_rect(0, 1, 23, 17, "F")                           # stone shell
g.fill_rect(1, 2, 22, 16, ".")
g.hline(1, 22, 11, "F")                                  # deck slab: pump room above, reservoir below
g.fill_rect(9, 11, 12, 11, ".")                          # hatch down to the water
g.fill_rect(1, 13, 22, 16, "L")                          # the reservoir: real WATR, real drowning
g.set(0, 9, "+"); g.set(0, 10, "+")                      # door into the pump room off the cave
g.fill_rect(3, 9, 5, 10, "M")                            # dead pump housing on the deck
g.set(4, 8, "V")                                          # its cold indicator lamp
g.set(2, 8, "P")                                          # control pad beside the door frame
g.vline(15, 3, 8, "R"); g.vline(18, 3, 8, "R")           # standpipes, stopping 2 cells short of the deck
g.hline(15, 18, 3, "R")                                   # so they do not wall the deck in half
add("underground_water_cistern", "underground",
    "A stone cistern: a pump room with a dead pump housing and standpipes on an upper deck, a real door in from the cave, and a floor hatch down into a genuine WATR reservoir (real drowning, real O2 drain). 24x18 cells at 12px/cell = 288x216 world px.",
    ANY, (100, 700), True, False, 0.09, 320,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 17),
    g, {"F": "stone", "L": "water", "R": "metal_old", "M": "metal_old", "V": "glow", "P": "control"},
    "Regrid from 12x10. The old cistern was fully sealed -- no entrance at all -- so its 'oxygen hazard' could never be met by a player who had no way in. It now has a dry deck you enter through a real door and a hatch you choose to drop through, which is what makes the water a decision instead of scenery. Water is still a static prop with real physics (finding #7), untouched.",
    enterable=True)

g = Grid(24, 18)
g.fill_rect(0, 1, 23, 17, "F")                            # brick shell
g.fill_rect(1, 2, 22, 16, ".")
for x in (5, 9, 14, 18):                                   # colonnade down the nave: pillars hang from the
    g.vline(x, 3, 13, "F")                                 # ceiling to row 13, so rows 14-16 stay walkable arches
    g.set(x, 6, "Q"); g.set(x, 11, "Q")                    # crystal set into each pillar
g.fill_rect(19, 13, 22, 16, "D")                          # raised altar plinth at the far end
g.set(20, 12, "Q"); g.set(21, 12, "Q")                    # the focal crystal on the altar
g.set(2, 3, "Q"); g.set(21, 3, "Q")                       # crystals in the ceiling corners
g.set(0, 15, "+"); g.set(0, 16, "+")                      # entrance
g.set(2, 14, "P")
add("underground_shrine", "underground",
    "A pillared shrine: four crystal-set pillars hanging over a walkable nave, a raised altar plinth with a focal crystal at the far end, entered by a real door. 24x18 cells at 12px/cell = 288x216 world px.",
    ANY, (150, 800), True, False, 0.07, 380,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 17),
    g, {"F": "brick", "Q": "crystal", "D": "stone", "P": "control"},
    "Regrid from 14x11. The old shrine was sealed like the old cistern -- a room with no way in. The pillars deliberately stop at row 13 rather than reaching the floor: a full-height pillar at 12px/cell is a solid 12px wall across a 4px-wide player's path, which would have made a 'nave' you cannot walk down. Same QRTZ motif as world.lua's geode/crystal-cave mechanic, concentrated rather than a new material vocabulary.",
    enterable=True)

g = Grid(26, 16)
g.fill_rect(0, 1, 25, 15, "M")                             # metal outer shell
g.fill_rect(1, 2, 24, 14, "F")                             # stone inner shell
g.fill_rect(2, 3, 23, 13, ".")                             # antechamber + vault
g.vline(13, 3, 13, "M")                                    # blast wall between them
g.fill_rect(4, 12, 5, 13, "C"); g.fill_rect(8, 12, 9, 13, "B")   # antechamber clutter
g.set(3, 11, "P")                                          # outer door's control pad
g.set(12, 11, "P")                                         # vault door's control pad
g.set(13, 12, "+"); g.set(13, 13, "+")                     # THE vault door, through the blast wall
g.set(0, 12, "+"); g.set(0, 13, "+")                       # outer door, through the metal shell
g.set(1, 12, "."); g.set(1, 13, ".")                       # and through the stone shell behind it
g.set(18, 12, "X"); g.set(19, 12, "X")                     # loot slot, deep inside
g.hline(15, 22, 5, "M"); g.vline(15, 5, 8, "M"); g.vline(22, 5, 8, "M")   # empty shelving rack
add("underground_sealed_vault", "underground",
    "A double-shelled vault: an antechamber behind an outer door, then a real blast door through the inner wall into the vault itself, with a shelving rack and a marked loot slot. Two independently powered doors. 26x16 cells at 12px/cell = 312x192 world px.",
    ANY, (200, 1100), True, False, 0.05, 480,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 14),
    g, {"M": "metal_old", "F": "stone", "X": AIR, "C": "wood", "B": "metal_old", "P": "control"},
    "Regrid from 12x10. Double-shell (metal_old outer, stone inner) is still from 4415/1818680, but the old vault's 'single door gap' was a two-cell hole and its loot slot sat in an undivided 8x5 box -- nothing about it read as a vault. The airlock plan (outer door -> antechamber -> blast door -> vault) is what makes the second door mean something, and each door gets its own control pad so they are genuinely independent. The 'X' loot cell stays in loot[] rather than the legend since it needs a tier and isn't a drawable material.",
    loot=[{"x": 18, "y": 12, "tier": 3, "note": "deepest/rarest structure in the library; highest tier by default"}],
    enterable=True)

# ================================================================ DEEP (4)
# depth_band is expressed relative to surface in px; "deep" zone starts at DEPTH-300 in world.lua.

g = Grid(20, 12)
g.fill_rect(0, 4, 19, 10, ".")
g.rect(3, 5, 8, 9, "M")                                     # forge housing (husk, cold/dead)
g.fill_rect(4, 6, 7, 8, "R")                                 # residual lava pool inside
g.vline(12, 3, 9, "M"); g.vline(14, 3, 9, "M")               # two broken pillar stubs
g.set(12, 8, "."); g.set(12, 9, ".")                          # pillar snapped partway
g.fill_rect(16, 8, 18, 9, "D")                               # slag/rubble pile
add("deep_lava_forge_ruin", "deep",
    "A derelict forge: a cold metal housing still holding a residual lava pool, two broken support pillars (one snapped), a slag pile. Reads as 'someone was smelting down here, long ago'. 20x12px.",
    ANY, (-350, -60), True, True, 0.10, 420,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 10),
    g, {"M": "metal_old", "R": "lava", "D": "stone"},
    "depth_band is negative-of-(DEPTH-...): interpreted by the loader as 'measured up from the world floor' for the deep category, see README. Real LAVA left in the housing (finding: water/lava as static-but-real props) rather than an inert orange fill, so it still emits real heat/light and is a genuine hazard to touch.")

g = Grid(26, 18)
g.fill_rect(0, 1, 25, 17, "F")
g.fill_rect(1, 2, 24, 16, ".")
for (x, y, n) in [(1, 3, 3), (23, 3, 3), (1, 13, 3), (22, 12, 4), (11, 2, 4), (8, 15, 3), (17, 15, 3)]:
    for i in range(n):                                     # clusters taper as they grow off the rock face
        g.fill_rect(x, y + i, x + n - 1 - i, y + i, "Q")
g.fill_rect(11, 13, 15, 16, "F"); g.fill_rect(12, 12, 14, 12, "Q")   # a crystal-capped plinth mid-floor
g.set(4, 16, "D"); g.set(5, 16, "D"); g.set(20, 16, "D")             # loose rubble on the floor
add("deep_crystal_chamber", "deep",
    "A hollow stone chamber with seven crystal clusters growing off the walls, ceiling and floor around a crystal-capped rock plinth. 26x18 cells at 12px/cell = 312x216 world px, walkable end to end.",
    ANY, (-500, -100), True, False, 0.08, 460,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 17),
    g, {"F": "stone", "Q": "crystal", "D": "stone"},
    "Regrid from 16x13. Clusters now taper (each row one cell narrower) so they read as crystal GROWING out of the rock face rather than as square crystal tiles pasted onto a wall, which is the whole difference at 12px/cell. No door: a geode is a natural void, not a built room -- it connects to whatever cave the generator carved into it.")

g = Grid(34, 20)
g.fill_rect(0, 1, 33, 19, "F")                                # stone shell
g.fill_rect(1, 2, 32, 18, ".")
g.vline(9, 2, 18, "M")                                        # bulkhead: control room | reactor hall
g.fill_rect(6, 14, 8, 16, "M")                                # console bank cantilevered off the bulkhead,
g.set(6, 13, "V"); g.set(8, 13, "V")                          # so the control room FLOOR stays clear end to end
g.set(1, 16, "P")                                             # outer door's control pad, on the entry wall
g.set(8, 16, "P")                                             # blast door's control pad, on the console face
g.set(9, 17, "+"); g.set(9, 18, "+")                          # blast door through the bulkhead
g.set(0, 17, "+"); g.set(0, 18, "+")                          # way in from the cave
for x in (12, 15, 30, 32):
    g.vline(x, 2, 12, "M"); g.set(x, 2, "V")                  # rod-column husks hanging from the ceiling
g.fill_rect(18, 5, 27, 14, "M"); g.fill_rect(19, 6, 26, 13, ".")      # central vessel husk, hollow and cold
g.fill_rect(20, 11, 25, 13, "D"); g.set(22, 10, "V")          # slag settled in the vessel floor
g.fill_rect(12, 17, 14, 18, "D"); g.fill_rect(25, 17, 27, 18, "D")   # debris piles, floor stays walkable
add("deep_abandoned_reactor_room", "deep",
    "A dead reactor: a control room with consoles and lamps, a real blast door through the bulkhead, then a hall of rod-column husks around a hollow central vessel with slag settled in it. 34x20 cells at 12px/cell = 408x240 world px.",
    ANY, (-600, -150), True, True, 0.06, 500,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 19),
    g, {"M": "metal_old", "V": "glow", "F": "stone", "D": "stone", "P": "control"},
    "Regrid from 22x12. The old room was one open box of columns you could not enter or leave -- the RBMK silhouette with no building around it. 680 cells buys the part that makes it a reactor ROOM: a control room you arrive in first, a bulkhead, and a blast door you have to get through, which is the actual shape grammar of 2001108 and 370469's wrecked-core diorama. Rod columns hang from the ceiling and stop at row 12, and the debris is in two piles rather than a floor-wide slag band, so the hall is walkable end to end. Still static and cold -- no reaction, the silhouette does the work.",
    enterable=True)

g = Grid(18, 8)
g.fill_rect(0, 3, 17, 7, ".")
for x in range(1, 17, 2):
    g.set(x, 6, "B")
    if x % 4 == 1:
        g.set(x, 5, "B")
g.fill_rect(7, 6, 9, 7, "B")                                   # a larger skull-like mound at the centre
add("deep_bone_pit", "deep",
    "A shallow pit scattered with pale debris (this build has no dedicated bone element, see notes) with a larger mound at the centre -- reads as an old kill site / mass grave. 18x8px.",
    ANY, (-400, -80), True, False, 0.05, 440,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 7),
    g, {"B": "bone"},
    "'bone' resolves to SAND (pale, heat-tolerant, already used for desert fossil-bed strata in world.lua's strataAt) as a placeholder -- swap the resolve-table entry the moment a real bone/ivory-toned element exists in the materials catalog; do not hardcode SAND directly in case that changes.")

# ================================================================ DETAILS (10)
# small, cheap, meant to be scattered densely near their parent structure or
# independently along corridors/rooms the same way world.lua's decoAt() scatters
# ground cover. clearance is tiny/zero; min_spacing is small on purpose.

g = Grid(4, 3)
g.set(0, 2, "D"); g.set(1, 1, "D"); g.set(2, 2, "D"); g.set(3, 1, "D"); g.set(1, 2, "D"); g.set(2, 1, "D")
add("detail_rubble_pile", "detail",
    "A loose pile of small rock chunks sitting on the ground -- pure ambience. 4x3px.",
    ANY, (-2, 900), True, False, 0.30, 40,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (1, 2),
    g, {"D": "stone"},
    "Placeable on the surface or underground (depth_band spans both); the loader should just re-roll it into whatever pocket it fits, per finding: rubble is scattered incidental clutter, not a landmark.")

g = Grid(2, 2)
g.fill_rect(0, 0, 1, 1, "C")
add("detail_crate", "detail",
    "A single wood crate. 2x2px.",
    ANY, (-1, 900), True, False, 0.22, 30,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 1),
    g, {"C": "wood"},
    "Deliberately tiny/generic -- appears alone or stacked (see surface_campsite for a 2-high stack) near camps, mines and ruins alike.")

g = Grid(2, 2)
g.fill_rect(0, 0, 1, 1, "B")
add("detail_barrel", "detail",
    "A single metal-banded barrel. 2x2px.",
    ANY, (-1, 900), True, False, 0.18, 30,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 1),
    g, {"B": "metal_old"},
    "Same role as detail_crate with a different material read (metal_old vs wood) so a cluster of both doesn't look uniform.")

g = Grid(2, 4)
g.vline(0, 1, 3, "P")
g.set(0, 0, "V")
add("detail_torch_sconce", "detail",
    "A wood post with a static glow tip -- a wall-mountable light, inert (not real fire, see surface_campsite notes on why). 2x4px.",
    ANY, (-2, 900), False, False, 0.20, 24,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 3),
    g, {"P": "wood", "V": "glow"},
    "rest_on_solid=false because this one mounts to a WALL cell of a parent structure, not the ground -- placement should check for an adjacent solid cell in any direction, not specifically below.")

g = Grid(6, 2)
g.hline(0, 5, 0, "M")
g.set(2, 1, ".")
add("detail_broken_pipe", "detail",
    "A short horizontal pipe run with a broken/leaking gap in the middle. 6x2px.",
    ANY, (0, 900), False, False, 0.14, 60,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 0),
    g, {"M": "metal_old"},
    "Embed inside underground/deep rock cells (rest_on_solid=false, it belongs mid-wall, not on the floor) -- reads as leftover infrastructure the same way world.lua's mineshaft framing reads as leftover construction.")

g = Grid(6, 3)
g.vline(0, 1, 2, "R"); g.vline(5, 1, 2, "R")
g.fill_rect(1, 0, 4, 1, "C")
g.set(1, 2, "M"); g.set(4, 2, "M")
add("detail_broken_cart", "detail",
    "An overturned/derailed ore cart, wheels askew, no rails under it (distinguishes it from underground_ore_cart which is upright on rail). 6x3px.",
    ANY, (60, 900), True, False, 0.10, 80,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 2),
    g, {"R": "metal_old", "C": "wood", "M": "metal_old"},
    "Deliberately the 'wrecked' counterpart to underground_ore_cart -- same vocabulary, no rail cells, tipped silhouette (cart box row above the wheel row, not centred).")

g = Grid(6, 5)
g.rect(0, 0, 5, 4, "M")
g.fill_rect(1, 1, 4, 3, ".")
g.set(2, 2, "M"); g.set(3, 2, "M")
add("detail_old_machine_husk", "detail",
    "A small rusted machine housing, hollow and dead inside with a couple of stub components -- generic 'someone built something here once' clutter, smaller/cheaper than a full deep_abandoned_reactor_room. 6x5px.",
    ANY, (100, 900), True, False, 0.09, 120,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 4),
    g, {"M": "metal_old"},
    "The BMTL-reads-as-abandoned-machinery finding, minimized to a single prop so it can be sprinkled through ordinary mine corridors, not just dedicated deep-zone rooms.")

g = Grid(1, 4)
g.vline(0, 0, 3, "P")
add("detail_fence_post", "detail",
    "A single wood fence post -- placed in a repeating row by the loader (spacing documented in README) to form a fence line, not authored as one big structure. 1x4px.",
    ["forest", "swamp", "desert"], (-3, 0), True, False, 0.25, 6,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 3),
    g, {"P": "wood"},
    "No harvested save had a clean fence-post reference (the harvested 'fence' saves were logic toys, see research doc) -- built from standard Terraria/Minecraft fence conventions instead, called out explicitly as an assumption.")

g = Grid(2, 6)
g.vline(0, 2, 5, "P")
g.set(0, 1, "V"); g.set(1, 1, "V"); g.set(0, 2, "P")
g.hline(0, 1, 2, "P")
add("detail_lamp_post", "detail",
    "A wood lamp post with a static glow lantern on top -- a taller, freestanding cousin of detail_torch_sconce for open ground rather than a wall. 2x6px.",
    ANY, (-1, 0), True, False, 0.12, 100,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 5),
    g, {"P": "wood", "V": "glow"},
    "Freestanding surface version; useful along paths near cabins/campsites so a small settlement reads as lit at night, matching @world's existing night/firefly ambience work.")

g = Grid(4, 3)
g.set(1, 2, "K"); g.set(2, 2, "K")
g.set(1, 1, "V")
add("detail_campfire_small", "detail",
    "A minimal stone-ringed campfire with a glow ember -- the standalone version of the fire prop baked into surface_campsite, for scattering alone. 4x3px.",
    ANY, (-1, 0), True, False, 0.14, 100,
    {"top": 0, "bottom": 0, "left": 0, "right": 0}, (1, 2),
    g, {"K": "stone", "V": "glow"},
    "Kept separate from surface_campsite so world.lua can place a bare campfire far more often (min_spacing 100) than a full camp scene (min_spacing 300).")

def selftest():
    """The enterable=True checks are worthless if they cannot fail. Prove they discriminate.

    Run: python scripts/gen_structures.py --selftest
    """
    def box(door_ch=None, w=24, h=18):
        g = Grid(w, h)
        g.fill_rect(0, 1, w - 1, h - 1, "F")
        g.fill_rect(1, 2, w - 2, h - 2, ".")
        if door_ch:
            g.set(0, h - 4, door_ch); g.set(0, h - 3, door_ch)
        return g

    def fails(g, legend=None, **kw):
        try:
            struct("t", "underground", "d", ANY, (0, 0), True, False, 0.1, 10,
                   {"top": 0, "bottom": 0, "left": 0, "right": 0}, (0, 0), g,
                   legend or {"F": "stone"}, "n", enterable=True, **kw)
        except ValueError as e:
            return str(e)
        return None

    assert fails(box(None)), "a sealed room with no door must be rejected"
    assert fails(box(".")), "an open hole must be rejected -- it is not a door"
    assert not fails(box(DOOR_CH)), "a real door into a real room must pass"
    # a 3x3 grid scales to 3px/cell, so a 1x2 door there is 3x6px -- too small for a 4x10 player
    tiny = Grid(4, 5)
    tiny.fill_rect(0, 0, 3, 4, "F"); tiny.set(1, 2, "."); tiny.set(1, 3, ".")
    tiny.set(0, 3, DOOR_CH)
    assert "need >=6x12" in (fails(tiny) or ""), "an under-sized door must be rejected by pixel size"
    # a window of BGLA (Falldown=1) punched through the shell falls out and opens the interior
    glassy = box(DOOR_CH)
    glassy.set(0, 5, "G")
    assert "non-solid material" in (fails(glassy, {"F": "stone", "G": "glass_colored"}) or ""), \
        "a shell that depends on a powder must be rejected"
    assert not fails(box(DOOR_CH), {"F": "stone", "G": "glass"}), "a solid-glass shell must pass"

    # Round-trip the world.lua instantiation transform against sQuery's own forward transform.
    # world.lua computes  wx = x0 + (gx - anchor.x)*isc + isc//2  and sQuery reads back
    # gx = floor((wx - x0)/isc) + anchor.x. If those ever disagree, machines land at
    # plausible-but-wrong coordinates -- the failure mode is invisible in-game, so it is checked here.
    n = 0
    for s in STRUCTS:
        isc, ax, ay = s["scale"], s["anchor"]["x"], s["anchor"]["y"]
        for x0, y0 in ((0, 0), (1234, -57), (-800, 991)):     # arbitrary placement origins
            for o in s["objects"]:
                for gx, gy in ((o["gx"], o["gy"]), (o["core_gx"], o["core_gy"])):
                    wx = x0 + (gx - ax) * isc + isc // 2
                    wy = y0 + (gy - ay) * isc + isc // 2
                    back = ((wx - x0) // isc + ax, (wy - y0) // isc + ay)
                    assert back == (gx, gy), f"{s['id']}: {(gx, gy)} -> {(wx, wy)} -> {back}"
                    n += 1
    print(f"selftest ok: sealed room / plain hole / undersized door / powder-dependent shell all "
          f"rejected, real door accepted, {n} object<->world round-trips exact")
    return 0


if "--selftest" in __import__("sys").argv:
    raise SystemExit(selftest())

with_ids = set()
for s in STRUCTS:
    if s["id"] in with_ids:
        raise SystemExit(f"duplicate id {s['id']}")
    with_ids.add(s["id"])
    path = OUT / f"{s['id']}.json"
    path.write_text(json.dumps(s, indent=1) + "\n", encoding="utf-8")

print(f"wrote {len(STRUCTS)} structures to {OUT}")
by_cat = {}
for s in STRUCTS:
    by_cat.setdefault(s["category"], []).append(s["id"])
for cat, ids in by_cat.items():
    print(f"  {cat}: {len(ids)} -> {', '.join(ids)}")
