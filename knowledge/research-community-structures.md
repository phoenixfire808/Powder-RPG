# Community structure research (Drew 19:20: "walking through the map and come across buildings and cool little features")

Goal: not whole maps — reusable DESIGN FEATURES (doors, windows, roofs, staircases, ladders, beams, bridges, pipes,
chimneys, furnaces, wells, arches, fences, signage, lamps, machinery silhouettes, ruined variants, small clutter)
that our procedural world generator (`scripts/lua/rpg_plugins/world.lua`) can place as the player walks around.

Method: harvested 42 new community saves through the existing pipeline (`scripts/save_research.py`'s logic,
reused via the new `scripts/harvest_structures.py` wrapper which points it at an **isolated lab instance**
(`scripts/lab_instance.py`, port 9877, its own ddir) instead of Drew's live session — his live game was never
touched, no Lua sent to it, no screenshots of it). Queries: house, village, cabin, castle, watch tower, bridge,
stone wall, campfire, ruins, windmill, underground base, mineshaft, dungeon, fence. Outputs land in
`knowledge/saves/<id>/` (census.txt = per-element counts + bounding boxes, logic.txt, map4px.txt/map1px.txt =
ASCII maps, meta.json = Browse metadata) alongside the ~68 saves already harvested by earlier workers (mostly
reactors/power plants — useful for machine silhouettes, not much for buildings). Everything below is analysis of
those files; the lab instance was closed the moment harvesting finished.

Full index: `knowledge/saves/index.jsonl`. Cross-reference any ID below there or in `knowledge/saves/<id>/`.

## What actually reads well at Powder Toy's pixel scale

A few things came up in save after save, independent of theme — these are the load-bearing lessons:

1. **Silhouette over detail.** At the zoom the RPG plays at (player = 12px tall, screen ~600x380px), a structure
   is read from its outline, not its texture. The best houses (76299 "Incredibly detailed house", 922996
   "Medieval Farmer's House") are recognizable from a peaked WOOD roof triangle + a rectangular BRCK/STNE base +
   1-2 small GLAS/BGLA window squares, nothing more. Anything smaller than ~3px reads as noise, matching what
   @world already learned the hard way about "salt-and-pepper" ore speckling.
2. **Foundation material differs from wall material.** Every building sits on STNE/BRCK/CNCT even when its walls
   are WOOD (922996, 2620790 Windmill: WOOD frame tower on a BRCK+STNE+SAND foundation ring). This double-reads
   as "built on the ground" rather than floating, and it's exactly the `rest_on_solid` check our placement needs.
3. **Windows are 1-2px BGLA/GLAS punched into a wall, always with a sill.** BGLA (colored/broken glass) reads
   better than clear GLAS against a rock backdrop — it doesn't disappear into empty space the way clear glass can
   (same "can't see the bullets against the background" lesson @items already hit with projectiles, 17:22).
4. **Ruined variants remove pieces, they don't add wreckage.** 2761960 (Gorod Orekhov Ruins), 2862857 (Echoes from
   the past), and the eroded-gap trick already in `world.lua`'s `ruinHere()` (`vnoise > 0.80 -> return nil`, i.e.
   punch a random hole in an otherwise intact wall) is precisely how the community's own ruins read — broken
   walls with gaps and a collapsed roof line, not a pristine building with debris glued on top. Our structure
   schema below builds this in as a first-class "erosion" step, not a separate ruined structure per building.
5. **Abandoned machinery reads through material, not moving parts.** BMTL (breakable/scrap metal) and BRMT
   (bronze) show up wherever a save wants to say "old machine, possibly still working" — 2620790's windmill gears,
   3002336/4415's vault interiors (BMTL walls, `Tmin` down to 16-19C, i.e. cold/dead). A rusted silhouette with no
   animation communicates "abandoned" cheaper than any logic.
6. **Fuel/ore veins are scattered through mine walls, not boxed off.** 2740888 ("abandoned mines") and 3010075
   ("Reacquisitioned Mine") both have IRON (3702), COAL (2917) and BCOL (2310) sitting directly in the BRCK/STNE
   tunnel walls, not in a separate "loot room" — the existing mineshaft in world.lua already does this
   (`mineshaftHere` returns WOOD framing only; ore comes from the normal `oreAt` vein pass underneath). Our new
   mine structures follow the same rule: real ore veins woven into rock cells of the structure, not a chest.
7. **Water is a static prop, not a hazard, inside ruins/bridges.** 58442 ("Blow the Bridge 2"), 2740888: WATR
   sits at the bottom of collapsed sections and flooded shafts purely for atmosphere — matches our own `WATR`
   handling (real physics element, but here just placed and left alone).

## Findings by category (with save citations)

### Surface: houses, cabins, watchtowers, bridges, wells, farms, signage

- **922996 "Medieval Farmer's House"** (62k parts) — WOOD frame (13655), STNE/BRCK/CNCT foundation
  (7340/2752/3289), GOO (dirt) yard, IGNC as a hearth/fire accent. Classic peaked-roof cabin silhouette; a small
  chimney vent breaks the roofline.
- **76299 "Incredibly detailed house"** — WOOD walls (3966) over a stone base, WATR pond feature (2956) beside it,
  PLNT (693) as yard greenery, VENT (552) forming a chimney flue, INSL (524) — even hobby builds insulate a hearth
  wall from the wood frame, matching @items' own laser/heat lessons.
- **3002336 "Cabin In The Cold" / 1483510 "Peaceful Cabin"** — smaller, snow-biome-flavoured cabins; WOOD walls,
  a single-room footprint, no basement. Good template for our `surface_cabin_small`.
- **2620790 "Windmill"** — WOOD tower frame (7728) on a BRCK (7167) + SAND/STNE (6485/3406) foundation ring, BGLA
  windows (2844), BMTL (2009) + BRMT (1830) mechanical parts for the blade hub. Confirms the "wood on stone"
  foundation rule and gives a second silhouette family (tall + narrow vs. squat + wide).
- **58442 "Blow the Bridge 2" / 1108906 "Realistic bridge creator"** — STNE/CNCT deck and piers (32628/15392,
  26284), BGLA/SAND (5535/4256) decorative rubble, WATR (7416) running underneath. Confirms bridges read as a
  flat STNE/CNCT deck on 2+ piers over a real WATR/air gap, not a solid fill.
- **304820 "Destroyable Castle" / 2390773 "Medieval Castle"** — big BRCK/CNCT/SAND walls with crenellations
  (a stepped top edge, 1-on/1-off pattern) and SLTW/WATR moats. Castles are bigger than we need for "the little
  stuff" but the crenellation motif (alternating solid/gap along a wall top) is directly reusable for our
  `surface_ruined_wall` and watchtower parapets.
- **Fences (2148730, 450396, 3345188)** were mostly logic toys (electric fences, lasers), not visual fence
  posts — for the small fence-post/rail detail we fall back to standard Terraria/Minecraft convention (a post
  every 4-6px, one horizontal rail at mid-height) rather than anything harvested; noted as an assumption below.

### Underground: mineshafts, tunnels, camps, cisterns, shrines, vaults

- **2740888 "abandoned mines" / 3010075 "Reacquisitioned Mine" / 2212800 "Mineshaft Base"** — BRCK/STNE/CNCT
  tunnel walls, real ore (IRON/COAL/BCOL) embedded in the rock, WATR flooding low sections. Rail-less carts
  weren't present in the sampled saves; ore-cart-on-rails is a Minecraft/Terraria convention we're importing
  deliberately per Drew's brief ("take design features... from Terraria, Minecraft").
- **4415 "Vault Tec. Vault 1." / 1818680 "Mountain Base"** — BMTL shell (19824) over STNE/BRCK/CNCT (14658/
  3574/3336), SAND fill, small WOOD interior fittings, BGLA viewport. Sealed, air-tight silhouette: a thick
  metal-and-stone shell around a hollow room — exactly the "sealed vault with a chest" shape, just needs a door
  gap and interior loot marker (see schema).
- **2298674 "Pyramid One" / 2761960/2862857 (ruins)** — BRCK/SAND/CNCT/STNE walls, IRON scatter, PQRT (a
  decorative colored quartz) as a "treasure" accent color, BGLA rubble. Good template for `underground_shrine`
  (small sealed chamber with a colored-crystal focal point) and for eroded ruin walls in general.
- **Dungeons (2834260, 2371755, 259530)** were mostly gameplay mechanisms (traps/mazes) rather than build
  features — nothing structural worth extracting beyond "narrow corridor + occasional wider room", which
  `world.lua`'s existing cheese-cavern "room" bump (`vnoise1(dep/130...) > 0.80 -> rad += ...`) already covers.

### Deep: forges, crystal chambers, reactor ruins, bone pits

No community saves at this depth theme came back structural (queries for "underground base"/"mineshaft" stayed
shallow); the ~68 earlier-harvested reactor/power-plant saves (`knowledge/saves/index.jsonl`, queries like
"nuclear reactor", "fusion reactor") are the actual source for this tier, filtered for their *derelict* look
rather than their function:
- **370469 "Chernobyl Disaster"** (already in build-lessons.jsonl) — a wrecked-core diorama: URAN grid pinned hot
  with a fixed dcolour, BRCK/GLAS shell, SALT/COAL rubble, a WATR pool. This is the exact recipe for
  `deep_abandoned_reactor_room`: a machine silhouette that's visually "off" (glassy dark URAN blocks, cracked
  BRCK shell) with no working logic needed.
- Reactor cores generally (2001108 RBMK, 2591226, 2867243, etc.) confirm the "recognisable by shape" lesson
  @machines already applied 17:38: rod columns, a turbine hub, pipe runs — our `deep_lava_forge_ruin` and
  `deep_crystal_chamber` borrow the shape grammar (vertical rod/pillar rows, a central vessel) without any of the
  working reactions, i.e. static METL/BMTL "husks" plus real LAVA/QRTZ for atmosphere.
- Bone pit has no real-world save precedent (Powder Toy doesn't have a bone element); built from the same
  "silhouette communicates the idea" principle as everything else — see the JSON file's notes for the material
  choice made (bleached SAND-toned debris) and why.

### Tiny details: rubble, crates, barrels, torches, pipes, carts, machine husks, fences, lamps

These came from the same saves' incidental clutter rather than a dedicated search: BCOL/COAL dust piles at the
base of mine walls (2740888), scattered IRON/PQRT flecks read as "loose ore" (2298674), BMTL fragments read as
scrap regardless of what they're attached to (windmill gears, vault plating). All of the tiny-detail structures
below are 3-9px, meant to be scattered densely and cheaply near their parent structure (or randomly along
corridors/rooms) the same way `world.lua`'s `decoAt()` already scatters ground-cover tufts/flowers/bushes.

## What this means for the structure library

- Use **logical material tokens** (`wood`, `stone`, `brick`, `concrete`, `glass`, `glass_colored`, `metal`,
  `metal_old`, `bronze`, `iron_ore`, `coal`, `gold`, `copper`, `clay`, `crystal`, `plant`, `glow`, `bone`, `ice`,
  `snow`, `sand`, `water`, `lava`) resolved through `has()`-guarded fallback chains at load time, exactly like
  `world.lua`'s own `ROCK`/`ROCK2`/`GRASS`/`UORE` locals — never hardcode a possibly-absent custom element id.
  See `knowledge/structures/README.md`'s resolve table.
- Every structure gets a `foundation` band (stone/brick/concrete) distinct from its main material, per finding #2.
- Windows use `glass_colored` (BGLA-preferring) per finding #3.
- A generic **erosion pass** (documented in the README, one extra noise tap per solid-wall cell, same shape as
  `world.lua`'s `ruinHere` 0.80 threshold) is available to any structure marked `erodible: true`, instead of
  hand-authoring a second "ruined" JSON per building.
- Ore/coal/water/crystal accents inside underground structures are placed as **real elements woven into the
  rock cells**, not floating loot icons, per findings #6/#7.
- Loot sits behind an explicit `loot` marker in the JSON (not guaranteed today — see the handover note in the
  structures README about wiring it to a guaranteed-chest core API vs. today's `R.chestAt` 45%-per-cell roll).
