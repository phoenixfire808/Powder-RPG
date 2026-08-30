# World-gen research notes (world worker, 2026-08-26 13:2x)

Goal: fix "slitty and unnatural" underground. Root cause found in current `rpg.lua genBase`:
tunnels are `abs(vnoise(x,y)-0.5) < 0.035` (a level-set crossing of a single noise field). That is a
mathematically thin crack: wherever the noise gradient is steep, the "band" width `~ threshold/|gradient|`
collapses toward zero, so tunnels randomly pinch to slits instead of staying open. No domain warp, so the
cracks also run parallel to the noise grid axes ("slitty"). This is the thing to actually fix, not just re-skin.

## Minecraft (fetched minecraft.wiki/w/Cave)
- Modern MC uses 3D noise "density functions" with three named cave styles, all noise-threshold based but
  tuned differently:
  - **Cheese caves**: low-frequency noise, wide threshold band -> big blobby pockets/caverns (the "holes in cheese").
  - **Spaghetti caves**: noise evaluated near a fixed value with a **width term that changes with depth/2nd noise**
    -> long, wide, winding tunnels. Key idea: width is a controlled parameter, not an accidental level-set thickness.
  - **Noodle caves**: same idea as spaghetti but width forced small (1-5 blocks) -> thin veins for variety.
  - Caves are independent of ore/structure placement (generated in their own pass), which is why they read as
    a clean network rather than fighting with ore veins.
  - Aquifers: separate liquid pass, lava below a fixed depth band, water above it, following the cave shape
    rather than being sprinkled per-pixel.
- Takeaway: treat "width" as an explicit, depth-varying parameter with a floor > 0, not a raw level-set.

## Terraria (fetched terraria.wiki.gg/wiki/World_generation)
- World starts as solid dirt (surface/underground band) over stone (cavern band) - i.e. **strata are depth
  bands first**, caves are carved into that afterward as a separate pass. Explicit passes in order: terrain
  shape -> dirt-layer caves (small) -> rock-layer caves (larger, more open) -> "small holes" (random pockets,
  sometimes water/lava depending on depth) -> ore ("Shinies") -> structures (dungeon/temple/pyramid/etc).
  Wiki doesn't give exact formulas, but the pass *order and separation of concerns* (shape, then small caves,
  then big caverns, then holes, then ore, then structures - each independent) is the useful signal: don't try
  to encode everything in one noise formula.
- Ore/gem placement is a late, separate pass overlaid on the finished rock - i.e. veins are blobs stamped onto
  existing solid rock, not computed as "is this the same noise field as the cave check."

## fBm / domain warping (fetched redblobgames.com/articles/noise/introduction.html)
- fBm = weighted sum of octaves; classic choice is amplitude *0.5 per octave, frequency *2 per octave
  (this is what `smooth1`/`vnoise` combos in rpg.lua already approximate for `surfaceAt`).
- "Pink noise" (amplitude ~ 1/sqrt(f)) reads as the most natural terrain; **red noise** (amplitude ~ 1/f,
  i.e. persistence 0.5 doubled emphasis on low freq) gives longer, smoother hills/valleys - good for cave
  centerlines so they don't wiggle at high frequency.
- Domain warping (perturb the (x,y) fed into a noise function by another noise function) is the standard fix
  for noise that "looks like a grid" or has straight/aligned features - breaks axis alignment cheaply (2 extra
  taps). This directly addresses the "slitty" complaint (the existing ridge noise has no warp at all).

## Cellular automata caves (general knowledge, could not fetch a live source - session noise/gamedev.net page
had no technical content)
- Classic recipe (Rogue Basin "cellular automata method for generating cave-like levels"): random fill ~40-55%
  wall, then 4-5 iterations of "become wall if >=5 of 8 neighbours are wall, else open" - the majority-rule
  smoothing is what produces rounded, blobby, connected caves instead of static/salt-and-pepper noise.
  Not directly usable here (gen() is a stateless per-pixel function, no grid to iterate), but the *lesson*
  transfers: connectivity and roundness come from an explicit smoothing/shape constraint, not from thresholding
  raw noise harder.

## What this plugin actually does about it (see world.lua)
1. **Explicit worm tunnels, not level-set ridges.** Each ~90px x-chunk gets a tunnel whose centerline
   `wormX(depth)` is a smooth 1D noise path (red-noise-like, low frequency) and whose radius is
   `baseRadius + smallNoise` **with a hard floor (>=2.2px)** - by construction it can never pinch to a slit,
   and radius grows gently with depth like Terraria's dirt-cave -> rock-cave widening. Neighbouring chunks
   are checked (c-1,c,c+1) the same way `treeAt`/`chestAt` already do in rpg.lua, so tunnels can visually
   merge into a network (Terraria/Minecraft "spaghetti" analogue).
2. **Cheese caverns kept from the existing formula** (3-octave weighted vnoise sum, already fBm-like) but fed
   through a 2-tap domain warp before thresholding, and unioned with the worm tunnels - this is the
   Minecraft "cheese + spaghetti" split.
3. **Strata are depth bands first** (Terraria order): a per-column, gently wavy (low-freq warp, +-4px) band
   index alternates GRNT/CNCR (with occasional BRCK/QRTZ seams), computed *before* the cave/ore pass carves
   into it - exactly mirroring "shape, then carve, then ore" instead of one formula deciding everything.
4. **Ore/mineral veins use a zone+detail two-tap test** (`vein()`: cheap low-freq "is this a vein zone" check
   that early-exits ~85-90% of the time, then a detail tap only inside the zone) instead of a single flat
   threshold - turns speckled "peppering" into coherent blobs/veins, addressing "unnatural" ore look too.
5. **Crystal/deep-vein zones use the same zone+detail test** at very low frequency so QRTZ/DMND/TTAN show up
   as pockets/clusters, not scattered pixels.
6. **Surface cave entrances**: a fraction of the worm chunks start their centerline at the surface itself
   (depth ~1-3) with a thin-to-wide taper over the first ~20px, guaranteeing a real, walkable-looking mouth
   that feeds into the general tunnel network below - otherwise caves are only found by mining, like both
   reference games allow.
7. Performance budget kept to a handful of taps per cell: 1 domain-warp pair (2 taps, shared/cached per column
   where possible), 1-3 worm-candidate lookups (1-2 taps each, only while `d` is in cave range), zone+detail
   taps for ore/crystal (early-exit keeps this ~1 tap on average). Per-column data (surface, biome, strata
   wave offset, worm chunk params, structure chunk params) is computed once and cached in Lua tables keyed by
   column/chunk index, mirroring `surfCache`/`treeCache` in rpg.lua.

Sources:
- [Cave – Minecraft Wiki](https://minecraft.wiki/w/Cave)
- [World generation – Terraria Wiki](https://terraria.wiki.gg/wiki/World_generation)
- [Noise and Turbulence, "Introduction" – Red Blob Games](https://www.redblobgames.com/articles/noise/introduction.html)
