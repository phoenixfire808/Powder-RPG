# World-gen research notes (WORLDGEN-2, 2026-08-26) — "it looks terrible" rebuild #4

Scope: this is a *visual* rebuild of the same generator whose cave-shape bug was already fixed by
WORLDGEN-1 (see `knowledge/research-worldgen-2026-08-26.md` — worm-tunnel hard-floor radius, cheese
caverns, zone+detail ore veins, soft biome borders). Caves no longer pinch to slits, but Drew's
diagnosis of the *rendered result* is a separate, real problem: flat single-tone rock, worm-shaped
(not room-shaped) caves, blob ore, a hard surface line, zero small-scale texture. Then, mid-task, a
second hard constraint arrived: this has to ship on Steam and TPT's frame cost is dominated by
particle *count* — the old generator put ~87k/235k (37%) particles on a mixed screen and higher in
solid rock, at 40fps/24k particles measured. Both problems turn out to point at the *same* fix
(bigger real caverns instead of worm tunnels + zone-based multi-material rock instead of single-tone
fill), which is the throughline of everything below.

## What I could fetch live this session

WebSearch was already at its 200/200 session budget when I started (shared across the parallel
worker team), so research here is WebFetch on specific wiki pages plus documented general technique
knowledge, same as WORLDGEN-1's doc did for the one source it couldn't reach.

- **[Ores – Terraria Wiki](https://terraria.wiki.gg/wiki/Ores)**: ore veins are placed as a late pass
  ("spawned") in a *quantity* that scales with world size and how many altars have been smashed (e.g.
  a small world's first altar generates 276 Cobalt veins, fewer each subsequent altar) — i.e. ore
  density is a tunable global knob, not baked into the terrain-shape noise. Ore placement is
  restricted to specific existing block types (Dirt/Stone/sand-and-grass variants) and explicitly
  refuses to place over Granite/Marble — **ore reads as ore because it never overwrites the "special"
  strata**, only the plain background rock. Ore also avoids the outer 100 tiles of the world (a
  "the edges are boring" pattern, not relevant at RPG-world scale but confirms zoning is deliberate).
- **[Ore – Minecraft Wiki](https://minecraft.wiki/w/Ore)**: modern generation is "ore veins" per chunk
  with a **triangle depth distribution** (abundance peaks at one depth and falls off both above and
  below — coal ranges the full 0-320 range, diamond is bounded -64..256 and peaks near the bottom,
  ancient debris peaks sharply at Y16 and "quickly tapers off above and below"). Deepslate — a
  visually distinct dark stone — replaces plain stone below a fixed layer, and ore variants get a
  distinct deepslate-tinted texture at that depth: **the depth transition is a visible material swap,
  not just an ore-rarity curve.** Some ores (emerald) generate as single "scattered blocks" rather
  than multi-block veins — not everything should be vein-shaped; scattered rare accents read as
  "special find," veins read as "resource."
- **[Cave – Minecraft Wiki](https://minecraft.wiki/w/Cave)**: three distinct noise-cave archetypes,
  literally described as image thresholding — "black regions become stone, white regions become
  air": **cheese caves** (low-frequency noise → big blobby open pockets, the dominant "walkable room"
  type and the type that most exposes ore), **spaghetti caves** (noise evaluated near a target value
  with a *width term*, not a bare level-set — long winding tunnels), **noodle caves** (same idea,
  width forced to 1-5 blocks — thin connective tissue, meant to be the minority case). Aquifers are a
  *separate* liquid pass laid onto the finished cave shape (lava below a fixed depth band, water
  above), not per-pixel wet/dry noise. "Noise pillars" (large dripstone/speleothem shapes) are
  explicitly called out as a *visual* feature layered onto the noise caves for realism — confirms
  stalactite-style decoration is a known, named technique, not an afterthought.

## What WORLDGEN-1's doc already established (cited, not re-derived)

- fBm/domain-warping: perturbing the (x,y) fed into a noise function by another noise function is the
  standard, cheap (2 extra taps) fix for noise that looks grid-aligned or has straight/aligned
  features — directly the tool for "caves read as scribbles."
- Cellular-automata cave smoothing (Rogue Basin's "cellular automata method"): random fill ~40-55%
  wall, 4-5 passes of "wall if ≥5 of 8 neighbours are wall" — the *lesson* that transfers to a
  stateless per-pixel `gen(wx,wy)` is that roundness/connectivity comes from an explicit smoothing or
  shape constraint, not from thresholding raw noise harder. Doing this literally (re-evaluating a full
  8-neighbour majority vote through the whole worm+cheese+shaft stack) is too many extra noise taps
  per cell for a scrolling-cost budget, so this rebuild uses a **cheap 4-neighbour "lite CA"**: only
  the cardinal (N/S/E/W) orthogonal neighbours of the *combined* open/closed test are re-evaluated,
  and a cell only flips (closed→open if all 4 neighbours are open, open→closed if all 4 are closed) —
  enough to dissolve stray 1px pillars/pinholes without paying for a true 8-neighbour pass.

## General technique knowledge used (not independently re-verified this session; consistent with the
above sources and standard in the genre — Terraria wall/tile dithering, Starbound's per-biome block
palettes, Noita's material-heavy sandbox rendering, Dwarf Fortress's layered-stone strata)

- **Strata read as bands because each band swaps its *dominant material*, and each band is itself a
  2-3 material dither**, not a flat fill — Terraria's dirt/stone/ebonstone and Minecraft's stone/
  deepslate both change the *base* material at a boundary; the "looks natural" part on top of that is
  that no single material fills a band edge-to-edge uninterrupted (real sedimentary rock has
  inclusions). A cheap per-pixel dither between an 80/15/5-ish split of a dominant + 2 accessory
  materials, gated by one extra noise tap, gets most of that effect for one tap's cost.
- **Ore/vein shape**: elongate a blob by sampling the "am I in a vein" test along a rotated axis
  (scale x and y differently after rotating by a per-vein random angle) instead of a circular
  zone-check — this is the standard "stretched noise" vein trick and is a direct one-line extension
  of the zone+detail `vein()` helper already in `world.lua`.
- **Poisson-disc-like decoration scattering**: true Poisson-disc needs shared mutable state (a grid of
  accepted points), which doesn't fit a stateless per-cell `gen()`. The practical substitute used
  throughout this file (and already used for trees/ground-cover in `world.lua`'s `vegAt`/`decoAt`) is
  a **jittered grid**: divide space into cells of the target minimum spacing, one candidate per cell
  at a hashed jittered offset, roll placement per-candidate. This gives Poisson-disc's *visual*
  result (even, non-clumped, non-grid-aligned spacing) without needing shared state — used here for
  stalactites, gravel piles, and moss patches.
- **Decoration layer (`dcolour`)**: TPT's decoration/deco layer is a per-particle RGBA tint
  (`sim.partProperty(id, "dcolour", argb)`) drawn under/over the particle without touching physics —
  confirmed present and settable in this build via `bridge_src/_base/bridge_base.lua`'s
  `placeDecoBox` action (`sim.decoBox(x1,y1,x2,y2,r,g,b,a,tool)`) and the property allow-list at
  bridge_base.lua:865 (`dcolour`/`dcolor` are on the settable-property list alongside `ctype`/`tmp`).
  **Important constraint found while wiring this up**: `world.lua` only owns the `R.hooks.gen`
  callback, which returns an element *name string* — the core (`rpg.lua:266-268`) creates the actual
  particle itself and never touches `dcolour`. Worse, `rpg.lua`'s infinite-world tile store
  (`rpg.lua:272-316`) captures/restores particles that scroll off the visible TPT canvas using only
  5 raw fields (`type,temp,ctype,tmp,life` — see `shiftCam`'s capture at rpg.lua:306 and the restore
  at rpg.lua:294); `dcolour` is not one of them, so a tint set once at creation would be silently
  wiped every time a cell scrolls off-screen and back. Fix used here: a small `R.hooks.tick` pass in
  `world.lua` (not touching `rpg.lua`) that re-applies texture to *whatever newly-revealed screen
  strip* the camera exposed this tick (same edge-strip math `rpg.lua`'s own `shiftCam`/`pendingFill`
  already uses, mirrored read-only), so the tint is recomputed deterministically from `(wx,wy,seed)`
  every time a cell becomes visible — cheap (bounded by the camera's per-tick move distance × screen
  edge, not the whole screen) and immune to the tile-store round-trip losing it.

## Performance requirement (added mid-task): particle count is the real cost, not visual complexity

Measured by Drew: TPT itself caps ~60fps; the lab benchmarks ~40fps at 24k particles and ~57fps
near-empty; Drew's live world runs 17-50fps at ~87k on-screen particles (612×384 = 235,008 cells,
so ~37% filled) and is worse in solid-rock-heavy views. The fix the brief asks for — bigger real
chambers instead of worm-only tunnels — is *also* the performance fix: a screen dominated by a few
large open caverns has far fewer solid cells than the same screen laced with many thin tunnels
through otherwise-100%-solid rock, for the same or better "readable cave" outcome. This rebuild
therefore treats **openness fraction as a first-class tuned parameter**, verified by instrumenting
the same offline `R.gen` sampler used for the visual previews (counts non-air cells / total cells per
screen-sized window at several depths) rather than guessed at. Decoration is added via the tint layer
(free) and via small, local, sparse real-particle accents (stalactites, gravel floor caps) rather than
a dense scatter of pebble/gravel particles — texture must come from *material variety and tint*, not
from *more particles*.

## Parameters settled on for `world.lua` (see file for exact code; summarized here for the record)

- **Strata**: 7 named depth bands (Topsoil-adjacent Shale, Granite/Concrete Upper, Brick/Slate
  Mid, Basalt-analogue Lower-Mid, Brimstone-Marbled Deep, Obsidian-analogue Abyssal, Diamond-laced
  Bedrock margin), each a dominant material + 2 accessory materials mixed by a per-pixel noise
  dither (roughly 70/20/10 split), band boundary perturbed by a slow 1D noise wave (±6-10px) so no
  boundary is a straight line.
- **Caves**: union of (1) large low-frequency domain-warped "cheese" chambers (the dominant open
  space, tuned so the union hits ~55-65% open at mid/deep screens), (2) worm tunnels with radius
  drawn from 3-8px (was 3-5.2px) connecting chambers, (3) rare vertical shafts, all passed through
  the 4-neighbour lite-CA speck removal described above. Chamber floors are flattened by filling the
  bottom ~15% of a chamber's local vertical extent with rock/rubble-dithered material so they're
  walkable instead of a random lower boundary; ceilings get sparse (jittered-grid, low probability)
  stalactite spurs.
- **Ore**: `vein()` calls now sample along a per-vein rotated, stretched axis so veins read as
  elongated streaks rather than round blobs, frequency/size still scaled by depth band per the
  existing `d > threshold` gating, with rare large "motherlode" zones (very-low-frequency second
  gate) that widen the normal vein radius by ~3x.
- **Surface transition**: root-zone band (real WOOD root flecks reaching down from trees, unchanged
  concept from the existing `rootColumn`) widened and followed by a mixed dirt/pebble dither zone
  before hitting the first strata band, replacing the previous hard `d<=soilD` single-material cutoff.
- **Decoration**: tick-based re-texture pass (dcolour) for per-pixel darkening/lightening noise on
  rock, a depth-darkening gradient, damp-darker patches near water/lava; small jittered-grid real
  accents (gravel cap on chamber floors, occasional stalactites, moss near cave-mouth light) kept
  sparse specifically to protect the particle-count budget.

Sources used directly:
- [Ores – Terraria Wiki](https://terraria.wiki.gg/wiki/Ores)
- [Ore – Minecraft Wiki](https://minecraft.wiki/w/Ore)
- [Cave – Minecraft Wiki](https://minecraft.wiki/w/Cave)
- [research-worldgen-2026-08-26.md](research-worldgen-2026-08-26.md) (WORLDGEN-1, this session's
  team) — Minecraft cave-type breakdown, Terraria pass ordering, Red Blob Games noise/domain-warp
  article, Rogue Basin cellular-automata recipe
