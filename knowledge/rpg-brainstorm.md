# Powder RPG — Weapons/Tools Brainstorm

Brainstorm agent's file. Answers Drew's 18:48 ask ("way more guns, cooler guns, disruptive stuff, building
stuff, super dope magical tools, a bunch of extremely unique stuff"). Every concept below is NEW — none
duplicate the 30 weapons/gadgets already live in `scripts/lua/rpg_plugins/items.lua` (Musket, Shotgun,
Grenade Launcher, Lightning Rod Gun, Teleport Wand, Flamethrower, Water Cannon, Acid Sprayer, Freeze Ray,
Laser Rifle, Power Drill, Jetpack, Steam Nail Gun, Rail Gun, Plasma Torch, Cryo Grenade, C4 Charge, Sticky
Bomb, Bow, Boomerang, Harpoon, Lava Bucket, Dynamite Bundle, Smoke Bomb, Magnet, Oxygen Tank, Diving Helmet,
Gas Mask, Climbing Gloves, Balloon) or the concepts already banked in `knowledge/rpg-ideas.md` (portal-pipe
item network, fission micro-reactor, structural cave-ins, flash-flood caverns, antimatter core, gravity-well
grenade, wildfire spread, physics dynamite, hypothermia, virus biome, tesla coil turret, freeze tool,
molotov, stickman totem, tamed black-hole pet, neutron pulse bomb, singularity mining charge, zipline rail,
piezo floor tiles, blast door vault, glass greenhouse, O2 tank/diving helmet/air pump). Every item here must
be implementable with real TPT physics (elements + mechanic named), feel distinct from all of the above, and
carry a mini-spec a worker can build from. Round 1, 2026-08-26, ~18:56.

## Grounding sources used
- `scripts/lua/rpg.lua` (`R.addHeat(x,y,rad,kelvin,cap)` — sustained real heat injection, used exactly the
  way items.lua's Laser Rifle/Plasma Torch already prove it must be called every tick to beat TPT's own
  neighbour-averaging; `R.crumble(cx,cy,rad)` — real brittle-rubble collapse for any isolated small clump;
  `R.damageEnemiesAt(x,y,radius,dmg,knockback)`/`R.enemyList()` — the one public damage API; `R.give`/
  `R.grantItem`/`R.inventory`/`R.craft`'s canAfford/spend accounting; `R.o2`/`R.o2conc`/`R.o2Sources`; `R.acc`/
  `R.accOn`/`R.equipAcc`; `R.tiles`/`R.PLUGIN_SAVE_KEYS` persistence convention; `R.machines`/`R.power.grids`
  (real flood-fill wattage system machines.lua shipped 18:30 — battery/capacitor/turret/reactor tiers).
- `knowledge/build-lessons.jsonl` audited entries: **PRTI/PRTO pair by `tmp` channel** (teleports any
  particle between an inlet and every outlet on that channel — cited, live-verified mechanic, reused below
  for player-portal and utility items, not just the ideas-bank's fixed machine network); **twin-GPMP+VOID
  gravitational confinement** (1732752, real observed mini-black-hole pattern — reused below at a different
  scale/purpose than the ideas-bank's combat grenade); **VOID as absorber blanket, not a wall** (needs a
  vacuum gap, deletes anything touching it); **AMTR containment is a FRAY/SPRK field jacket, unsafe without a
  physical shell** (basis for a scaled-down sidearm below).
- `knowledge/materials-catalog.json` (71 entries): `NBTI` (superconductor — coilgun/railgun-tier magnet),
  `GRPN` (graphene — conductive whip), `PZT` (piezoelectric — pressure-pulse weapon), `TI64`/`KEVL`/`S316`
  (armor/frame tiers), `THOR`/`CD`/`BE`/`HF` (real control-rod/shielding materials), `LBE`/`FLBE`/`NA`
  (liquid-metal/molten-salt coolants), `LHE`/`LH2` (cryogenics). All real density/hardness/heatConduct/
  melting-point sourced.
- `scripts/define_power_elements.py` behaviour kinds already live and reusable: `emitter` (UO2: emits NEUT
  every 120f — reusable for any "emits X periodically" item), `absorber` (B4C), `conductor` (CU/STEL),
  `turbine`, `teg`, `glower` (LEDL) — reused below wherever an item needs an existing, tested behaviour
  instead of inventing a new one.
- Stock TPT elements referenced: `PRTI`/`PRTO`, `GPMP`, `VOID`, `NBHL`, `FRAY`, `SPRK`, `PSCN`/`NSCN`, `WIFI`,
  `ICE`/`WTRV`/`WATR` (real melt/freeze transitions), `LIGH`, `CLNE`/`BCLN` (stock cloning elements), `PHOT`.
  Real per-element `HighTemperature`/`HighTemperatureTransition` facts (read live via `elem.property`, e.g.
  SAND→GLAS, GRNT 1523K→LAVA, ICE 273K→WATR) are the backbone of the Transmuter's Wand below.

---

## TOP 15 — ranked, full mini-specs

**1. Portal Gauntlet** — fun 5/5, physics 5/5, effort M, owner `@items`. GROUP: Magical/Exotic.
Wearable upgrade of the existing Teleport Wand. Left-click places a real `PRTI` at the cursor; right-click
places a real `PRTO` at the cursor — both tuned to one `tmp` channel unique to the player (hash of a
per-player counter), reusing the exact audited PRTI/PRTO channel-pairing lesson instead of a scripted
"instant move." Walking into the PRTI teleports the player (and anything else that touches it) to the PRTO,
velocity preserved, and the pair stays live and reusable — a genuine two-way portal network the player
builds, not a one-shot blink. Placing a new PRTI retunes the channel rather than leaving a dangling portal.
API: `sim.partCreate` for PRTI/PRTO with a per-player `tmp` value; a tick hook detecting the player hurtbox
touching the PRTI cell. Cost: GOLD=3+QRTZ=2 per end placed (placing new ends is cheap — the pair should feel
like real infrastructure). Craft the gauntlet itself: anvil, GOLD=4+QRTZ=4+DMND=1. Tier: late-mid.
Acceptance test: place a PRTI at spawn, a PRTO 200px away; walk into the PRTI and confirm instant arrival at
the PRTO with preserved velocity; replace the PRTI elsewhere and walk through again to confirm the channel
retuned rather than creating a second portal.

**2. Blueprint Stamp Wand** — fun 5/5, physics 3/5, effort M, owner `@items` (+ `@save` for persistence).
GROUP: Building Tools.
The literal "copy/paste wand" Drew asked for. Drag a rectangle over the player's own placed blocks to record
a grid snapshot (element per cell — plain data, same convention `R.machines` already uses for save/load, not
raw particle ids). Switch to place mode, click elsewhere: a dim ghost preview shows the stamp; confirming
places every real particle it recorded via the same `sim.partCreate` primitive every machine kit already
uses, deducting the exact material cost per cell from inventory (same `canAfford`/`spend` pattern `R.craft`
already runs) — an honest multi-block placer, not a cheat. Persist stamps under a `stamps` key pushed onto
`R.PLUGIN_SAVE_KEYS` per `@save`'s existing generic dump/restore convention. Cost: wand itself WOOD=6+GOLD=2
at workbench; placing a stamp costs exactly the sum of its recorded cells. Tier: early-mid.
Acceptance test: stamp a 5x5 BRCK wall, place the same stamp 20 blocks away with enough BRCK in inventory —
confirms an identical 5x5 wall and deducts exactly 25 BRCK; attempting to place with insufficient materials
fails cleanly (all-or-nothing) and places nothing, matching `R.craft`'s existing afford-check behaviour.

**3. Terraform Brush** — fun 4/5, physics 3/5, effort S, owner `@items`. GROUP: Building Tools.
Large-radius circular multi-block placer. Mouse wheel resizes the brush (reuses the shift+wheel block-resize
convention already shipped 18:46). Dragging over an area replaces every open-air cell in radius with the
selected inventory material in one motion — the area-scale sibling to placing one block at a time, for
flattening hills or laying floors fast. No new physics: bulk real particle placement via the same primitive
any kit uses, gated by `R.HARD` so it can't overwrite terrain the player hasn't actually mined/cleared, and
costs 1 unit of material per cell placed (no bulk discount). Recipe: workbench, STEL=4+WOOD=4. Tier: early.
Acceptance test: select WOOD, set radius 6, drag across an open pit — every open-air cell in radius fills
with WOOD and inventory drops by exactly that many WOOD; dragging the same brush across solid GRNT places
nothing and spends nothing.

**4. Chronolock Sphere** — fun 5/5, physics 3/5, effort L, owner `@items` (+ 1-line `@enemies` hook).
GROUP: Magical/Exotic (time-freeze).
Throw a sphere that "freezes time" in a ~5-second bounded radius on landing — implemented as a real local
stasis, not a screen effect: on entry, every particle id inside the radius has its (vx, vy, temp) captured
once, then that exact state is re-written to it every tick for the duration (an active hold loop, since
TPT's own gravity/pressure would otherwise keep nudging it), and any `FIGH` inside is excluded from
enemies.lua's own AI tick via a shared `R.frozenUntil[id]` flag (the one item in this whole bank needing a
one-line change outside items.lua — flagged to `@enemies`: skip the AI tick while `R.frozenUntil[id] >
R.frame`). This is the single most "invented" mechanic in the bank — rated lower on fidelity and flagged
honestly rather than oversold. Ammo: rare (DMND=2, GOLD=4, anvil), cooldown ~200f — a panic-button capstone,
not a spammable weapon. Tier: late-game.
Acceptance test: throw into 3 moving enemies + falling loose sand — confirm all 3 enemies stop moving and
the sand freezes mid-fall for the full duration, then everything resumes exactly where it left off (sand
keeps falling, enemies resume AI) the instant the timer ends, with no particles lost or duplicated.

**5. Gravity Well Staff** — fun 4/5, physics 4/5, effort M, owner `@items`. GROUP: Disruptive/Magical
(telekinesis).
Continuously-held staff projecting a small, weak, non-lethal `GPMP` field at the cursor — the reusable,
non-destructive sibling to the ideas-bank's one-shot gravity-well grenade. No `VOID` core at all: nothing
gets deleted, only pulled or (right-click reverses the field) pushed. Real capped pull velocity so it draws
loose particles/dropped ore toward the cursor for gathering-at-a-distance or clearing debris out of a tunnel,
without ripping through solid structure. API: place a temporary weak `GPMP` emitter each tick at the cursor
while held, removed on release. Cost: passive drain from `R.power.grids` while standing near the player's own
grid (or GOLD ammo trickle as a fallback if no grid nearby), craft at anvil (STEL=6, GOLD=4, GPMP-tier
material). Tier: mid, ties the "magic" feel directly to the already-shipped power-grid system.
Acceptance test: hold near a pile of loose SAND/ore — particles visibly draw toward the cursor over ~1s
without destroying or converting them; right-click on the same pile pushes it away instead.

**6. Gauss Coilgun** — fun 5/5, physics 4/5, effort M, owner `@items`. GROUP: Guns — Kinetic.
Hold to charge (visible meter), release to fire a heavy METL/STEL slug whose launch velocity scales with
hold time — a real staged-coil accelerator flavored on the catalog's `NBTI` superconductor material,
distinct from the instant-hitscan Rail Gun already shipped. Each block it penetrates bleeds velocity by that
block's own `R.HARD` tier (so it eventually stops, unlike a true hitscan), and impact knockback via
`R.damageEnemiesAt` scales with charge. Ties into the base's own electricity: firing requires standing near a
grid (`R.power.grids`) with charge above a threshold, or it just clicks empty — a genuine payoff for building
a power base. Ammo: METL=3/shot. Craft: anvil, STEL=8+CU=4+GOLD=2 (NBTI substituted with CU if not yet a
session element — flag to `@lead`). Tier: mid-late.
Acceptance test: fire at 0% charge = musket-equivalent range/damage; fire at ~100% charge (held ~50f) =
penetrates 3 STEL-tier blocks in a line and deals ~3x damage; firing below the grid-charge threshold plays a
dry-fire click, consumes no ammo, and doesn't spawn a projectile.

**7. Tesla Arc Rifle** — fun 5/5, physics 4/5, effort M, owner `@items`. GROUP: Guns — Energy.
Fires a short-range `SPRK` bolt that chains: instead of hitting only the first target, it follows the exact
same real conductor-adjacency rule `machines.lua`'s power-grid flood-fill already computes every 15 frames
(through touching CU/STEL/METL wire or WATR) to hit every connected enemy standing in or touching that
conductive path, via repeated `R.damageEnemiesAt` calls along the traced chain. A genuinely different
combat read from the existing Lightning Rod Gun (a single straight bolt): this one rewards or punishes
positioning relative to real wiring/water. Ammo: GOLD=2/shot, cd 45. Craft: anvil, CU=4+GOLD=3. Tier: mid.
Acceptance test: fire at an enemy standing in a WATR pool touching 3 other enemies through that pool — all 4
take damage; fire at an isolated enemy on dry ground touching no conductor — only that one is hit, proving
it follows the real conduction path rather than a scripted AoE circle.

**8. Void Bore** — fun 5/5, physics 4/5, effort M, owner `@items`. GROUP: Guns — Exotic / Disruptive.
Heavy, expensive, short-range weapon: instead of pushing or melting material, it opens a private `PRTI`
channel at the muzzle tip (a fresh, disposable `tmp` value each shot) paired to a fixed `PRTO` sitting over a
permanent `VOID` buried at world bedrock (the documented VOID-absorber-blanket pattern, keeping the world's
real particle count from leaking). Every particle touching the muzzle PRTI for one frame is genuinely
teleported away and deleted there — real teleportation, not `sim.partKill`. Still pays out ore for anything
`MINEABLE` among the deleted plug (credited via `R.give` before it's ported, same as a pick), then
`R.crumble`s the bore's rim to clean the hole edge. Ammo: DMND=2+GOLD=4/shot, cd ~90f. Craft: anvil,
requires diamond-pick tier unlocked. Tier: late-game.
Acceptance test: fire into a mixed GRNT/IRON/DMND wall — instantly clears a clean 3px-radius plug, credits
the correct ore counts exactly as a pick would, and leaves zero stray particles or heat signature at the
site afterward.

**9. Sinkhole Charge** — fun 4/5, physics 4/5, effort M, owner `@items`. GROUP: Disruptive.
Place-and-detonate charge (same UX shape as C4/Dynamite) that, instead of exploding, spawns a scaled-UP,
timed twin-`GPMP`+`VOID` well (the audited 1732752 confinement pattern) that pulls in loose particles,
dropped ore, and untethered `FIGH` within a wide radius for ~10 seconds before collapsing — the large-scale,
placed/timed excavation-and-area-denial sibling of the ideas-bank's small instant combat grenade. Everything
`MINEABLE` pulled in before the well closes is credited via `R.give` (loot the well before it seals). Leaves
a real permanent open crater, not filled rubble. Cost: rare, STEL=10+GOLD=6, anvil, deep-tier drop only.
Tier: late-game excavation "cheat tool," matching the ideas-bank's own framing of the GPMP/VOID family.
Acceptance test: place against a hillside — pulls in a measurable radius of loose ore/rock over the timer,
credits inventory for anything MINEABLE swallowed, then leaves a real permanent open crater once the well
times out (nothing refills it).

**10. Sonic Resonance Cannon** — fun 4/5, physics 4/5, effort M, owner `@items`. GROUP: Guns — Energy/Exotic.
Fires a narrow directional pressure pulse (a `PZT`-piezo-flavored electrical-to-mechanical conversion, real
material from the catalog) instead of a particle stream — a purely concussive, non-incendiary alternative to
the acid/laser/plasma family. The pulse physically shoves loose particles/enemies (`R.damageEnemiesAt` with
high knockback, low direct damage) and shatters brittle terrain instantly via `R.crumble`, with zero heat/
temperature change logged — the acceptance test that proves it's genuinely different physics from every
heat-based weapon already in the game. Cost: power-grid-drawn (like the Coilgun) or QRTZ=2/shot fallback if
PZT isn't yet a session element (flag to `@items`/`@lead`). Craft: anvil+workbench. Tier: mid.
Acceptance test: fire into a wall of rubble-eligible blocks near a ledge — they crumble/launch without any
scorch marks or temperature change recorded, distinguishing it from every existing heat weapon.

**11. Auto-Scaffold Pole** — fun 3/5, physics 3/5, effort S, owner `@items`. GROUP: Building Tools.
A Terraria-style scaffolding tool: while held and the player is climbing (pressed toward open air above/
below), it auto-extends a real WOOD pole one cell at a time in the direction of movement, letting the player
build a ladder shaft as fast as they climb instead of placing planks by hand. No new physics — the existing
WOOD placement primitive, triggered by movement instead of clicks, consuming 1 WOOD per new cell (same spend
pattern `R.craft` uses). Directly answers the day-one "intuitive Terraria-like controls" pillar. Craft:
workbench, WOOD=4. Tier: very early.
Acceptance test: equip it, hold up+jump repeatedly in an open shaft — a continuous WOOD ladder extends
upward exactly as fast as the player climbs, consuming exactly 1 WOOD per new cell, and stops the instant
the tool is deselected or WOOD runs out.

**12. Frost Ward Phase Gate** — fun 4/5, physics 5/5, effort S, owner `@items`. GROUP: Magical/Exotic
(phase-shift wall).
Reads as "walk through walls," is entirely real phase-change physics: it's a genuine ICE wall, and while
holding this gate's wand (or wearing the already-proposed Frost Ward accessory), a small precisely-aimed
heat pulse (`R.addHeat`, tuned to exactly cross ICE's real 273K melt point without lingering hot enough to
damage the player or melt neighbours) fires one cell ahead of the player's velocity vector, melting a
body-sized hole to WATR/WTRV just long enough to pass through — and because ICE's real freezing point
re-solidifies the cell the instant the heat source moves on (no scripted re-freeze needed, pure TPT thermal
convection), the wall reseals itself behind the player. An enemy without the tool bounces off the same wall
as solid terrain. Cost: no ammo, small inter-phase cooldown so a whole wall can't be permanently melted.
Recipe: ties into the existing Frost Ward accessory (ICE=6+CU=2, workbench). Tier: snow-biome mid.
Acceptance test: build a solid ICE wall, equip the gate, walk into it — the exact cell ahead of the player
melts just long enough to pass and reads back under 273K (re-solidified) within ~1s of the player clearing
it; an enemy without the tool is blocked by the same wall.

**13. Transmuter's Wand** — fun 4/5, physics 4/5, effort M, owner `@items`. GROUP: Magical/Exotic
(philosopher's stone).
Reads as alchemy, is really a targeted instant-trigger of physics the game already models: point at a block
and hold — instead of waiting on ambient heat, the wand reads that material's own real `HighTemperature`/
`HighTemperatureTransition` live via `elem.property` and forces it immediately via `R.addHeat` capped to
exactly that value: SAND→GLAS (real melting-sand-into-glass), ICE→WATR/WTRV, GRNT→LAVA at its real 1523K, or
LMST/MRBL's real acid-reactive calcination if paired with a follow-up acid tick. Materials with
`HighTemperature==10000` (no real transition — diamond, coal) report "cannot transmute" and consume no
charge, an honest limitation instead of a fake universal converter — this is exactly the acceptance test.
`R.crumble` cleans up any brittle remainder afterward. Cost: GOLD=1+QRTZ=1/activation; craft the wand at
anvil, TTAN=4+QRTZ=4+GOLD=2. Tier: mid-late.
Acceptance test: point at real SAND, hold — becomes GLAS in one tick, credited to inventory; point at DMND —
wand reports "cannot transmute," consumes no charge, proving it reads the live property table rather than a
hardcoded list.

**14. Drill Mount (Mining Drone)** — fun 4/5, physics 3/5, effort M, owner `@items`. GROUP: Utility/
Movement (drill mounts).
An autonomous, deployable drone distinct from the hand-held Power Drill: place it, mark a destination, and
it bores a straight real tunnel toward that point on its own over time using the exact same `R.MINEABLE`/
`R.HARD`/`give()` mining pipeline the player's own pick already uses — same rules, same ore payout, just
driven by a scripted advancing position instead of mouse input. The player can optionally ride it for
hands-free travel through solid rock (a Factorio-flavored automation payoff). `R.crumble` cleans the bore
path. Ammo: COAL (drains per cell bored, same `ammoEvery` consumption shape as the Jetpack). Craft: anvil,
STEL=12+CU=4+GOLD=2. Tier: late-mid.
Acceptance test: place it, target a point 100px away through solid GRNT — bores a straight tunnel exactly
along that line, deposits GRNT ore into inventory at the same rate a diamond pick would mine it, and halts
within 1 cell of the target instead of tunnelling forever.

**15. Rocket Sled** — fun 4/5, physics 4/5, effort S, owner `@items`. GROUP: Utility/Movement.
A ground vehicle distinct from the vertical Jetpack: mount it and hold forward to ignite the exact same real
FIRE+GAS combustion thrust the Jetpack already proves (same `ammoEvery`/COAL-burn shape), applied as a
horizontal `vx` impulse instead of vertical `vy`, for fast flat-terrain traversal between distant bases.
Real friction/collision against `solidW` brakes it on release or on a rise; launching off a raised ledge
sends the rider into a real gravity arc (same physics as any projectile), with `R.P.apex` reset on launch
(the same trick fall-capping gear already uses) so it doesn't take fall damage while thrust was active at
the moment of launch. Ammo: COAL, same rate class as Jetpack. Craft: anvil, STEL=8+GOLD=2+COAL=2. Tier: mid.
Acceptance test: mount on flat ground, hold forward — accelerates smoothly to a capped top speed burning
COAL at the jetpack's proven rate; riding off a raised ledge launches a real gravity arc that lands without
fall damage as long as thrust was active at launch (apex reset confirmed).

---

## Full concept bank by category

### GUNS — Kinetic (beyond Gauss Coilgun)
- **Sawblade Launcher** — fun 4/5, fid 3/5, M. Fires a spinning real METL disc (scripted spin+velocity
  vector) that ricochets off HARD-tier walls up to 3 times before stopping, damaging everything it grazes.
- **Ricochet Pistol** — fun 3/5, fid 3/5, S. Cheap sidearm whose slug bounces once off any solid surface at
  a mirrored angle (real reflection off the surface normal) — shoot around corners.
- **Ballista Bolt Launcher** — fun 3/5, fid 3/5, S. Huge slow METL bolt, high knockback/pin damage, embeds
  in terrain (sticky-bomb-style landing) as a climbable/coverable post.
- **Grapple Harpoon Cannon** — fun 4/5, fid 3/5, M. Fires a chained slug that becomes a taut real zipline
  the player can ride hand-over-hand back — distinct from the existing single-pull Harpoon.
- **Seismic Hammer Gun** — fun 4/5, fid 4/5, M. Fires a downward pressure pulse causing a real localized
  shockwave that ripples loose terrain (SAND/GRSS) and staggers enemies via heavy knockback, zero direct dmg.
- **Auto-Turret Deployable** — fun 4/5, fid 3/5, M. Placed structure version of the musket, auto-fires at
  any `FIGH` in line of sight via `R.damageEnemiesAt`, powered by `R.power.grids`.
- **Sticky Net Launcher** — fun 3/5, fid 2/5, S. Fires a real VINE/rope tangle that slows an enemy's
  velocity directly for a few seconds.
- **Shrapnel Mine** — fun 3/5, fid 4/5, S. Proximity charge that sprays real METL fragments in a directional
  fan instead of a blast sphere.

### GUNS — Energy (beyond Tesla Arc Rifle, Sonic Resonance Cannon)
- **Graphene Whip** — fun 4/5, fid 3/5, M. Melee-range conductive whip (`GRPN` material) that lashes for
  damage and, touching a live SPRK/WIFI circuit, transmits a jolt into whatever it hits next.
- **Photon Lance** — fun 4/5, fid 4/5, S. Burst (not continuous) PHOT beam piercing multiple thin targets,
  cooldown-gated instead of ammo-drained — distinct from the sustained-beam Laser Rifle.
- **Induction EMP Caster** — fun 3/5, fid 3/5, M. Short-range magnetic pulse that drains/shorts a nearby
  machine's `R.power.grids` charge — anti-machine utility weapon.
- **Cryo-Fusion Lance** — fun 4/5, fid 3/5, M. Freeze pulse + timed follow-up ignition: flash-freeze then
  shatter the frozen target for bonus damage.
- **Arc Furnace Cannon** — fun 3/5, fid 4/5, S. Point-blank cone of real superheated PLSM, strongest damage
  in the game, but overheats the wielder's own hand (self-damage) after 2 shots in a row.

### GUNS — Exotic
- **Neutron Flash Rifle** — fun 4/5, fid 4/5, M. Short burst of real NEUT (reuses UO2's emitter behaviour)
  passing through solid cover, doing nothing to non-fissile terrain — ties into the reactor's real physics.
- **Singularity Sniper** — fun 5/5, fid 3/5, L. Extreme-range hitscan leaving a tiny short-lived GPMP pull
  at the impact point, yanking the target and nearby debris a few cells before it fades.
- **Antimatter Derringer** — fun 5/5, fid 4/5, L. One-shot, extremely rare sidearm sharing the ideas-bank's
  antimatter-core FRAY/SPRK containment mechanic scaled to a single-fire pocket pistol — devastating, risky.
- **Magma Cannon** — fun 4/5, fid 4/5, M. Scoops and fires real molten LAVA bolts (weaponized Lava-Bucket
  handling), igniting flammables nearby and cooling to real STNE crust after a few seconds.
- **Quark Splitter** — fun 3/5, fid 2/5, L. Novelty exotic gun: slug splits into 3 weaker slugs on first
  hit (reuses the Dynamite Bundle's cluster-launch pattern).

### DISRUPTIVE (beyond Void Bore, Sinkhole Charge, Gravity Well Staff)
- **Terrain Inverter Wand** — fun 4/5, fid 3/5, M. Briefly reverses local gravity in a bounding box (a
  flipped GPMP field) so loose particles/the player fall "up" for a few seconds.
- **Pressure Bomb** — fun 3/5, fid 4/5, S. Thrown charge spiking local ambient pressure hugely (real
  pressure injection, no heat) — implodes/collapses weak brittle structures without fire.
- **Liquefaction Field Grenade** — fun 3/5, fid 3/5, M. Raises local GOO/soil temperature just enough for it
  to flow like a liquid for a few seconds (real thermal softening), for terrain reshaping or muddy traps.
- **Vacuum Sphere** — fun 3/5, fid 3/5, S. Thrown charge creating a small real low-pressure pocket that
  sucks in loose gas/smoke — a toxic-gas-clearing tool, not a weapon.
- **Wormhole Grenade Pair** — fun 5/5, fid 5/5, M. Two grenades auto-link on a shared `tmp` channel (audited
  PRTI/PRTO pairing) — anything that wanders into either one teleports to the other's landing spot; a
  combat/puzzle tool distinct from the fixed machine network and the player-only Portal Gauntlet.
- **Shatterfield Charge** — fun 3/5, fid 3/5, S. Inward-tuned pressure/heat pulse specifically triggering
  `R.crumble` on everything brittle in radius without a crater — clean demolition, no debris field.

### BUILDING TOOLS (beyond Stamp Wand, Terraform Brush, Auto-Scaffold Pole)
- **Symmetry Brush** — fun 3/5, fid 2/5, S. Mirrors every block placed across a chosen axis line.
- **Bridge Layer** — fun 4/5, fid 3/5, M. Dropped at a gap's edge, auto-extends a real WOOD plank bridge
  toward the far solid edge it detects, one cell per frame, consuming WOOD as it goes.
- **Wall Foundry Wand** — fun 3/5, fid 2/5, S. Click twice (top/bottom) to instantly raise a full
  floor-to-ceiling wall in one shaft, material cost per cell exactly like normal placement.
- **Conveyor Line Tool** — fun 3/5, fid 3/5, S. Click-drag to lay a full run of the existing CONVEYOR kit in
  one motion instead of placing each segment by hand.
- **Chunk Relocator Crate** — fun 3/5, fid 3/5, M. Mark a source region + destination; slowly conveys every
  real particle from source to destination over time (real movement, not a copy) — moves a whole stockpile.
- **Foundation Stamp Library** — fun 3/5, fid 2/5, M. Default-shipped Blueprint Stamps (starter house,
  storage room, farm plot) using the Stamp Wand's own placement/cost system.
- **Ladder-to-Rope Converter** — fun 2/5, fid 2/5, S. Converts a placed WOOD ladder run into real VINE/rope
  (climbable, differently flammable) — a cosmetic/functional building variant.
- **Glass Dome Kit** — fun 3/5, fid 3/5, M. Curved-placement Terraform Brush variant for GLAS, auto-arcing a
  dome over a marked footprint — feeds the ideas-bank's Glass Greenhouse.

### MAGICAL/EXOTIC (beyond Portal Gauntlet, Chronolock Sphere, Frost Ward Phase Gate, Transmuter's Wand)
- **Storm Caller Totem** — fun 4/5, fid 4/5, M. Placeable totem that, once charged (standing in open sky
  during a real storm), calls down real LIGH bolts at marked enemy positions periodically — reuses the
  existing weather/lightning system rather than a scripted damage tick.
- **Life-Drain Blade** — fun 4/5, fid 3/5, S. Melee weapon where each `R.damageEnemiesAt` hit also restores
  a fraction of dealt damage as player HP — reuses the existing damage API, reads as vampiric.
- **Mirror Wand (Clone)** — fun 4/5, fid 4/5, M. Uses stock CLNE/BCLN cloning elements to spawn a temporary
  duplicate of whatever material the player stands near — "duplication magic" that's really TPT's own clone
  element exposed as a tool.
- **Levitation Boots** — fun 3/5, fid 3/5, S. Weak continuous upward GPMP-adjacent lift capping fall speed
  to near-zero for slow controlled descent/hover — works both directions, drains a charge (unlike Balloon).
- **Elemental Cloak** — fun 3/5, fid 3/5, M. Worn accessory that passively vents the right countermeasure
  (OXYG in bad air, a heat pulse in cold biomes) for whatever hazard the player currently stands in — three
  existing survival mechanics bundled into one accessory slot.
- **Soul Jar** — fun 4/5, fid 2/5, L. Thrown jar that captures an enemy's "essence" on the killing blow
  instead of a normal drop, later releasable to fight on the player's side — pairs with the ideas-bank's
  Stickman Army Totem as an alternate capture-based ally source.
- **Runed Ward Stakes** — fun 3/5, fid 3/5, S. Placeable stakes projecting a small real heat/cold/gas field
  (reuses Frost Ward/O2-tank mechanics) to keep a camp area passively safe without wearing gear.

### UTILITY/MOVEMENT (beyond Drill Mount, Rocket Sled)
- **Wall-Run Boots** — fun 4/5, fid 3/5, M. Momentum-preserving lateral movement along a vertical `solidW`
  surface for a few frames before gravity reasserts, chainable into a wall-jump.
- **Dash Capacitor** — fun 4/5, fid 3/5, S. Short powerful horizontal velocity impulse on double-tap,
  recharging from `R.power.grids` — base electrification pays off in mobility too.
- **Updraft Thruster Boots** — fun 3/5, fid 3/5, S. Controllable hover via small continuous real GAS/steam
  thrust underfoot — weaker than the Jetpack, no fuel-hungry vertical climb, just hover-in-place.
- **Magboots** — fun 3/5, fid 3/5, S. Lets the player walk on ceilings/walls made of real METL/STEL/IRON
  specifically (electromagnetic, restricted to actual metal terrain, not a universal wall-walk).
- **Tether Anchor Grapple** — fun 3/5, fid 3/5, S. Place a fixed anchor point; the grapple always targets
  the nearest placed anchor instead of the cursor, for repeatable swings across a set course.
- **Momentum Skates** — fun 3/5, fid 2/5, S. Near-frictionless horizontal movement specifically on ICE
  terrain (real reduced-friction physics already true of ICE, just removing the player's artificial
  ground-friction while standing on it).
- **Reinforced Exo-Frame** — fun 4/5, fid 3/5, L. Wearable frame doubling pick/sword power and tanking one
  otherwise-lethal hit, powered by the grid — an end-game "mech suit" built from real armor tiers (TI64/KEVL).

---

## Notes for `@roadmap`
- Highest-confidence physics picks (reuse audited build-lessons.jsonl mechanics almost verbatim): **#1
  Portal Gauntlet** and **#8 Void Bore** (PRTI/PRTO channel pairing), **#9 Sinkhole Charge** and **#5 Gravity
  Well Staff** (twin-GPMP/VOID confinement family, one destructive one not). Recommend these four first if
  "verifiable" is the tie-breaker, same standard the ideas-bank used.
- Direct answers to Drew's exact 18:48 wording: "cooler guns" → #6/#7/#10 (Gauss Coilgun, Tesla Arc Rifle,
  Sonic Resonance Cannon — three genuinely different combat physics: charge-scaled kinetic, conductor-chain
  electric, concussive-not-incendiary); "disruptive stuff" → #8/#9/#5 plus the Disruptive one-liners;
  "building stuff" → #2/#3/#11 (Stamp Wand, Terraform Brush, Auto-Scaffold Pole — the exact multi-block-
  placer/copy-paste/terraforming-brush trio the brief named); "super dope magical tools" → #4/#12/#13/#1
  (Chronolock, Frost Ward Phase Gate, Transmuter's Wand, Portal Gauntlet — all real physics dressed as magic,
  matching the project's zero-invented-mechanics bar except Chronolock, flagged honestly as the one
  scripted-stasis exception).
- Effort spread across the top 15: 5 S, 8 M, 2 L — a good mixed queue for `@items` (quick wins: #3, #11, #12
  are all S-effort and reuse only already-shipped primitives).
- One cross-cutting ask for `@lead`: **#4 Chronolock Sphere** needs a single check added to enemies.lua's AI
  tick (`if R.frozenUntil[id] and R.frozenUntil[id] > R.frame then skip end`) — everything else in the top 15
  needs zero core/enemies changes, only items.lua work.
- `@items`: suggested build order given what's already shipped (guns/gadgets are your strongest muscle) —
  #6 Gauss Coilgun and #7 Tesla Arc Rifle first (both M, both extend your existing projectile/hitscan
  infrastructure almost directly), then #2 Blueprint Stamp Wand (Drew named "building stuff" explicitly and
  nothing in the game does this yet), then #1 Portal Gauntlet and #13 Transmuter's Wand for the "magical"
  ask. Full ranked list and one-liners above are ready to hand off item-by-item as you clear the queue.

---

---

## Round 2 — 2026-08-26, ~19:20 (hazard atmosphere + vehicles + "expand events and ecology")

New Drew comments processed: 18:58 (game identity — depth/oxygen/interlocking machines pillar), 19:04 (real
carbon monoxide/CO2/methane/radiation hazard atmosphere, `R.gas`, shipped in core), 19:08 (underground
trains/vehicles — new `@vehicles` worker owns `vehicles.lua`, core added `R.mount`/`R.dismount`/`R.ride`),
19:14 (power/energy as a headline pillar + plants/food/environmental needs/events + **"@brainstorm/@ideas:
expand events and ecology"** — a direct ask). Per the roadmap's own division of labor (`@ideas` = all-category
gameplay ideas, `@brainstorm` = items/weapons/tools/magic only), the specs below stay in my lane but are
purpose-built for the three new pillars instead of generic reskins.

### Ownership overlap flagged (not built as items — handing to `@vehicles`)
- **Rocket Sled** (top-15 #15) and **Drill Mount/Mining Drone** (top-15 #14) are both vehicle-shaped and now
  sit on `@vehicles`' new turf (`R.mount`/`R.dismount`/`R.ride`, just registered in core). Rather than @items
  building a parallel "ride-a-thing" system, I'm handing both specs to `@vehicles` as-is (the physics/API in
  each spec doesn't change — `R.mount`/`R.ride` replace the informal "player rides it" language) and leaving
  them off `@items`' queue. `@roadmap`: please reassign #14/#15 to `@vehicles` in the plan.

### Events & ecology — new tool/weapon concepts answering Drew's 19:14 ask
- **Storm Rod** — fun 4/5, fid 4/5, effort M, `@machines`(+`@items` for the craftable head). A tall
  lightning-rod mast that, planted during a real storm (reuses the existing weather system that already
  drives rain/lightning), *catches* real `LIGH` strikes instead of just surviving them and feeds the charge
  straight into `R.power.grids` as a burst generator tier — directly ties 19:14's "power/energy is a big
  deal" pillar to 19:14's "environmental events" pillar with one real mechanic (a storm literally powers your
  base). Ammo: none, craft at anvil (STEL=6, CU=4, GOLD=2).
  Acceptance test: plant it during a scripted storm tick, confirm a real LIGH particle striking the rod
  measurably spikes that grid's wattage reading for a few frames, exactly like the existing TEG/turbine
  wattage measurement already does for other generators.
- **Geothermal Tap Drill** — fun 4/5, fid 4/5, effort M, `@machines`. A stationary drill-mount variant (not
  a ride vehicle, so it stays in `@items`/`@machines` territory rather than `@vehicles`') that bores straight
  down until it reaches the real geothermal heat zone 19:04 just added (below ~900px) and then sits there
  converting that real ambient heat into power via the same `teg`-kind behaviour already live on `TEG` —
  directly answers 18:58's "reason to build deep machines" and 19:14's power pillar in one device.
  Acceptance test: place it, let it auto-bore to depth >900px, confirm its output wattage in `R.power.grids`
  rises specifically once it crosses the geothermal-heat depth threshold, not before.
- **Scrubber Grenade** — fun 3/5, fid 4/5, effort S, `@items`. A portable, thrown emergency response to
  19:04's new CO/CO2/methane hazard atmosphere (`R.gas`): bursts into a real absorbent cloud (reuses the
  Smoke Bomb's "real cloud" mechanic, but tuned to pull `R.gas.co`/`co2`/`ch4` down in its radius instead of
  reducing visibility) — a field fix for a sealed room that's gone bad before the player can reach a proper
  scrubber machine. Ammo: COAL=3+GOO=2, anvil.
  Acceptance test: thrown into a room with elevated `R.gas.co`, the local reading drops measurably within
  its burst radius over a few seconds, same measurement `@machines`' scrubber devices already expose.
- **Lead-Lined Rounds** (ammo upgrade, not a new gun) — fun 3/5, fid 4/5, effort S, `@items`. A craftable
  ammo variant (LEAD=1 per shot, works in any existing slug weapon — Musket/Shotgun/Rail Gun/Coilgun) whose
  slugs carry a small real LEAD fragment that lodges near the impact point and, per 19:04's design note
  ("lead in inventory helps" against radiation), locally lowers `R.gas.rad` around wherever it lands — turns
  ammo choice into a genuine radiation-hazard countermeasure near uranium veins/reactors, not just a damage
  stat swap.
  Acceptance test: firing lead-lined rounds into a high-`R.gas.rad` zone measurably lowers the local
  radiation reading near the impact point over time; standard rounds fired at the same spot show no change.
- **Pollinator Charm** (ecology, non-combat) — fun 3/5, fid 3/5, effort S, `@items`(+`@world` hook). A worn
  accessory that slowly attracts real loose pollen/spore-type decoration particles `@world` already spawns
  near flowers/canopies (the 17:40-shipped wild-beehive/forest flora) toward the player, boosting nearby
  crop/flower growth rate as a passive ecology loop — the "ecology" half of 19:14's ask, framed as a wearable
  tool per my brief rather than a `@world`/`@survival` biome system.
  Acceptance test: equip near a flower patch, confirm growth-tick rate on nearby `@survival` crops (once
  that system exists) measurably increases versus an unequipped control patch over the same real time.
- **Weather Vane Beacon** (events, non-combat) — fun 3/5, fid 3/5, effort S, `@items`. A placeable device
  reading the same real weather-cycle state that already drives rain/lightning/storms, giving the player
  advance warning ("Storm approaching — good time to plant the Storm Rod") — a legible-signal tool for the
  new events pillar, zero new physics, just surfacing state that already exists.
  Acceptance test: placed beacon correctly announces an oncoming storm 1 real weather-cycle tick before rain/
  lightning actually starts, confirmed by comparing its announcement frame to the actual storm-start frame.

`@roadmap`: these six are scoped specifically to the three pillars Drew just named (power/events/ecology) and
complement rather than duplicate whatever `@ideas`/`@survival`/`@machines` are building for the same ask —
Storm Rod and Geothermal Tap Drill are the two with the most cross-team dependency (weather system + depth
system + power grid), recommend confirming ownership/sequencing with `@machines` before `@items` starts
either. `@vehicles`: Rocket Sled + Drill Mount specs (top-15 #14/#15) are yours now, full text above in the
Top 15 section — physics/mechanics unchanged, just re-target `R.mount`/`R.ride` instead of ad-hoc "player
rides it."

---

## Next up (handed to `@roadmap`/`@items`/`@vehicles`/`@machines` this pass)
- Posted top-15 ranked queue + full 61-concept bank to the hub (18:56), addressed to `@roadmap` (prioritize
  against the live plan) and `@items` (build queue, suggested order: #6→#7→#2→#1→#13).
- Round 2 (19:22): reassigned #14 Drill Mount and #15 Rocket Sled to the new `@vehicles` worker (specs
  unchanged, re-target `R.mount`/`R.ride`); added 6 new items/tools scoped to Drew's 19:14 "expand events and
  ecology" ask (Storm Rod, Geothermal Tap Drill, Scrubber Grenade, Lead-Lined Rounds, Pollinator Charm,
  Weather Vane Beacon) tying the new power/hazard-atmosphere/depth pillars together.
- Flagged the one core dependency (`@lead`/`@enemies`: Chronolock's frozen-AI-skip hook) so it isn't
  discovered mid-build.
- Open question for `@items`/`@lead`: confirm whether `NBTI` (Gauss Coilgun) and `PZT` (Sonic Resonance
  Cannon) need session-defined elements (like the 13 custom power elements) or should launch v1 with CU/QRTZ
  stand-ins — noted as a substitution in both specs above so neither is blocked either way.
- Per Drew's 19:24 EFFICIENCY PROTOCOL (pack down context, work in small steps, avoid re-deriving/re-reading
  large files), closing this pass here rather than continuing to poll. Resume by re-reading the hub's
  "Drew says" section from 19:24 onward and this file's Round 2 section — do not re-read the full 61-concept
  bank or re-derive the grounding sources list above, they're stable reference material now.
