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
# any other legend value is a *logical material token*, resolved to a real
# element id at load time by the has()-guarded table in structures/README.md
AIR, KEEP = "air", "keep"


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


def struct(
    id_, category, description, biomes, depth_band, rest_on_solid, erodible,
    rarity, min_spacing, clearance, anchor, grid: Grid, legend: dict, notes,
    loot=None, variants=None,
):
    used = {c for row in grid.rows for c in row}
    legend = {" ": KEEP, ".": AIR, **legend}
    missing = used - set(legend)
    if missing:
        raise ValueError(f"{id_}: grid uses undeclared symbols {missing}")
    return {
        "id": id_, "category": category, "description": description,
        "biomes": biomes, "depth_band": {"min": depth_band[0], "max": depth_band[1]},
        "rest_on_solid": rest_on_solid, "erodible": erodible,
        "rarity": rarity, "min_spacing": min_spacing, "clearance": clearance,
        "anchor": {"x": anchor[0], "y": anchor[1]},
        "width": grid.w, "height": grid.h,
        "legend": legend, "grid": grid.strs(),
        "loot": loot or [], "variants": variants or [],
        "notes": notes,
    }


ANY = ["any"]
STRUCTS = []


def add(*a, **kw):
    STRUCTS.append(struct(*a, **kw))


# ================================================================ SURFACE (8)
# anchor is always the grid cell that lands on the world placement point;
# for surface structures that point is (px, surfaceAt(px)) -- ground level.

g = Grid(15, 17)
g.fill_rect(1, 12, 13, 15, "F")               # stone/brick foundation slab
g.fill_rect(2, 6, 12, 11, "W")                 # wood wall box (hollow below)
g.fill_rect(3, 7, 11, 10, ".")                 # interior air pocket
g.set(6, 11, "."); g.set(7, 11, ".")           # doorway gap in the front wall
g.set(4, 8, "G"); g.set(10, 8, "G")            # two windows
for x in range(3, 12):                          # single-peak gable roof (wood): highest at center, sloping to the eaves
    peak = 1 + abs(x - 7)
    g.vline(x, peak, 5, "W")
g.set(10, 3, "V"); g.set(10, 2, "V"); g.set(10, 1, "V")  # chimney stack, offset from the peak, poking above the roofline
add("surface_cabin_small", "surface",
    "Small single-room log cabin: peaked wood roof over a wood-wall box on a stone/brick foundation slab, one door gap, two windows, a chimney vent. 15x17px -- about 1.25 player-heights tall inside.",
    ["forest", "swamp", "snow"], (-4, 2), True, True, 0.16, 260,
    {"top": 2, "bottom": 0, "left": 2, "right": 2}, (7, 12),
    g, {"F": "stone", "W": "wood", "G": "glass_colored", "V": "metal_old"},
    "Sourced from 922996 'Medieval Farmer's House' and 3002336/1483510 cabin saves: wood walls always sit on a stone/brick foundation band (never wood-to-dirt), one door gap at ground level, small punched windows, a roof-line chimney vent. erodible=true so a ruined variant is just this JSON with the erosion pass applied, not a second file. Anchor row 12 is the foundation's TOP row (README's anchor rule: anchor.y is the first grounded/embedded row, i.e. rows >= anchor.y sit at-or-below surfaceAt(wx)) so the door gap at row 11 lands exactly one row above ground -- the row a standing player's feet occupy.")

g = Grid(9, 32)
g.vline(3, 4, 30, "T")                          # tower shaft (wood posts, 2 wide)
g.vline(5, 4, 30, "T")
for y in range(6, 30, 6):
    g.hline(3, 5, y, "T")                        # floor joists every 6px (climbable framing)
g.fill_rect(1, 0, 7, 4, "T")                     # lookout platform
g.fill_rect(2, 1, 6, 3, ".")                     # platform interior (open-air lookout)
g.set(1, 1, "R"); g.set(7, 1, "R")               # corner rail posts
g.fill_rect(1, 30, 7, 31, "F")                   # stone footing
add("surface_watchtower", "surface",
    "Tall wood-framed watchtower: two vertical support posts with cross-joists every 6px (a real climbable ladder-like frame) up to an open lookout platform with corner rails, on a stone footing. 9x32px -- ~2.5 player-heights.",
    ANY, (-2, 26), True, True, 0.06, 420,
    {"top": 3, "bottom": 0, "left": 2, "right": 2}, (4, 30),
    g, {"T": "wood", "F": "stone", "R": "metal_old"},
    "The crenellation/parapet motif from 304820/2390773 castle saves, scaled down to a single-player lookout. Joist spacing (6px) matches the mineshaft support-post spacing already in world.lua so it reads as the same 'built structure' vocabulary. Anchor row 30 = the footing's top row (first grounded row), same rule as surface_cabin_small.")

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
    "Deliberately small/sparse (a discoverable trace of past habitation) rather than a functional farming feature -- the owner's ask was exploration variety, not a farming mechanic; @progression owns actual farming if that's ever added.")

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

g = Grid(22, 9)
g.fill_rect(0, 3, 21, 5, ".")                       # east-west main gallery
g.fill_rect(9, 0, 12, 8, ".")                       # north-south cross shaft
for x in range(0, 22, 5):
    g.vline(x, 2, 6, "T")                            # support posts every 5px, matches world.lua's 16px post spacing scaled to a junction room
g.hline(0, 21, 2, "T"); g.hline(0, 21, 6, "T")       # roof / floor planks
g.vline(9, 0, 8, "R"); g.vline(12, 0, 8, "R")        # cart rails down the cross shaft
g.set(10, 7, "C")                                    # ore cart prop
add("underground_mineshaft_junction", "underground",
    "A four-way mineshaft junction: wood-framed east-west gallery crossing a north-south rail shaft, support posts, an ore cart sitting on the rails. 22x9px.",
    ANY, (60, 900), True, False, 0.16, 340,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (10, 4),
    g, {"T": "wood", "R": "metal_old", "C": "metal_old"},
    "Wood framing pattern matches world.lua's existing mineshaftHere() (roof/floor plank + posts) so a generated junction blends with the plain mineshaft corridors either side of it; ore cart + rails are the imported Terraria/Minecraft convention the owner asked for.")

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

g = Grid(16, 8)
g.fill_rect(0, 3, 15, 6, ".")
g.fill_rect(2, 5, 3, 6, "T")                          # bedroll (wood-toned placeholder)
g.set(6, 5, "K")                                       # campfire ring
g.set(6, 4, "V")                                       # glow ember
g.fill_rect(9, 5, 10, 6, "C")                          # crate
g.fill_rect(12, 5, 13, 6, "B")                          # barrel
g.vline(14, 2, 6, "L")                                  # a wall-mounted ladder up
add("underground_miners_camp", "underground",
    "A small excavated room off a shaft: bedroll, campfire ring with an ember glow, a crate and a barrel, and a ladder up in the corner. 16x8px.",
    ANY, (80, 500), True, False, 0.12, 300,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 6),
    g, {"T": "wood", "K": "stone", "V": "glow", "C": "wood", "B": "metal_old", "L": "wood"},
    "Same 'trace of past habitation' read as surface_campsite, underground flavor. Ladder rungs use the same wood-post vocabulary as underground_ladder_shaft below so the two compose along a single vertical route.")

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

g = Grid(12, 10)
g.rect(0, 2, 11, 9, "F")
g.fill_rect(1, 3, 10, 8, ".")
g.fill_rect(2, 6, 9, 8, "L")                             # deep water reservoir
g.hline(0, 11, 2, "F")
g.set(5, 1, "P"); g.set(6, 1, "P")                        # small roof vent
add("underground_water_cistern", "underground",
    "A sealed stone cistern room holding a real water reservoir -- a navigation landmark and an oxygen hazard if the player dives in (real WATR, real O2 rules already apply). 12x10px.",
    ANY, (100, 700), True, False, 0.09, 320,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 9),
    g, {"F": "stone", "L": "water", "P": "wood"},
    "No new mechanic -- reuses R.o2's existing underwater drain, this just gives the player a reason to find (and a hazard to respect) a large real water body underground, matching the 'water is a static prop but real physics' finding.")

g = Grid(14, 11)
g.rect(1, 2, 12, 10, "F")
g.fill_rect(2, 3, 11, 9, ".")
g.set(6, 3, "Q"); g.set(7, 3, "Q")                        # crystal set into the ceiling
g.set(6, 8, "Q"); g.set(7, 8, "Q")                        # and the floor -- a lit focal point
g.set(6, 5, "."); g.set(7, 5, ".")
g.hline(5, 8, 9, "D")                                      # low altar/plinth
add("underground_shrine", "underground",
    "A small sealed stone chamber with crystal accents set into floor and ceiling around a low plinth -- a quiet landmark room, no combat/mechanic attached. 14x11px.",
    ANY, (150, 800), True, False, 0.07, 380,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 10),
    g, {"F": "brick", "Q": "crystal", "D": "clay"},
    "Modeled on the pyramid/ruin saves' PQRT-as-treasure-accent convention (2298674) scaled down to a real QRTZ crystal motif consistent with world.lua's existing geode/crystal-cave mechanic, so a shrine reads as 'more of that, concentrated' rather than a new material vocabulary.")

g = Grid(12, 10)
g.rect(0, 1, 11, 9, "M")                                   # thick metal-and-stone sealed shell
g.rect(1, 2, 10, 8, "F")
g.fill_rect(2, 3, 9, 7, ".")
g.set(5, 8, "."); g.set(6, 8, ".")                          # single door gap, otherwise fully sealed
g.set(5, 5, "X")                                             # loot marker (chest slot)
add("underground_sealed_vault", "underground",
    "A fully sealed metal-shelled stone vault with exactly one door gap and a marked loot slot inside. 12x10px.",
    ANY, (200, 1100), True, False, 0.05, 480,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 9),
    g, {"M": "metal_old", "F": "stone", "X": AIR},
    "Double-shell (metal_old outer, stone inner) directly from 4415/1818680 (BMTL-over-STNE/BRCK). The 'X' loot cell is documented separately in the JSON's loot[] list (see below) rather than the legend, since it needs a tier and isn't a drawable material -- see structures/README.md's handover note about wiring this to a guaranteed chest instead of relying on R.chestAt's 45% roll.",
    loot=[{"x": 5, "y": 5, "tier": 3, "note": "deepest/rarest structure in the library; highest tier by default"}])

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

g = Grid(16, 13)
g.rect(0, 2, 15, 11, "F")
g.fill_rect(1, 3, 14, 10, ".")
for (x, y) in [(3, 4), (12, 4), (3, 9), (12, 9), (7, 6), (8, 7)]:
    g.set(x, y, "Q")
    g.set(x + 1, y, "Q") if x < 10 else None
add("deep_crystal_chamber", "deep",
    "A hollow stone chamber deep underground with large crystal clusters growing from multiple walls/corners -- a bright, valuable landmark room. 16x13px.",
    ANY, (-500, -100), True, False, 0.08, 460,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 12),
    g, {"F": "stone", "Q": "crystal"},
    "Scaled-up sibling of underground_shrine's crystal motif -- more clusters, bigger chamber, deeper band -- so descending reads as 'the crystal theme intensifies', matching world.lua's existing geodeZoneAt bias toward deeper/snow-biome crystal odds.")

g = Grid(22, 12)
g.fill_rect(0, 3, 21, 10, ".")
for x in (3, 8, 13, 18):
    g.vline(x, 3, 9, "M")                                    # rod-column husks, evenly spaced (RBMK/BWR shape grammar)
    g.set(x, 3, "V")                                          # each capped with a dead glow marker (was-lit indicator)
g.fill_rect(0, 9, 21, 10, "D")                                # cracked floor slag
g.rect(9, 4, 12, 8, "F")                                       # central vessel husk
add("deep_abandoned_reactor_room", "deep",
    "A dead reactor room: evenly spaced rod-column husks around a central vessel, floor cracked with slag, one dead glow marker per column. 22x12px.",
    ANY, (-600, -150), True, True, 0.06, 500,
    {"top": 1, "bottom": 1, "left": 1, "right": 1}, (0, 10),
    g, {"M": "metal_old", "V": "glow", "F": "stone", "D": "stone"},
    "Shape grammar (evenly spaced vertical rod columns + a central vessel) copied from the community RBMK saves (2001108 etc.) and from 370469's 'Chernobyl Disaster' wrecked-core diorama technique -- static and cold (no reaction), the silhouette alone reads as 'reactor'.")

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
