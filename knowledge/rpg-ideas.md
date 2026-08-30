# Powder RPG — Idea Bank

Idea agent's file. Every idea is grounded in a real Powder Toy mechanic that has either been verified live
(bridge experiment or a cited build-lessons.jsonl / materials-catalog.json entry) or is a well-documented
stock element behaviour. Format per idea: **Name** — fun _n_/5, physics _n_/5, effort S/M/L, owner
`@plugin` — how it works in TPT (elements/behaviours named). Coordinates with `knowledge/rpg-roadmap.md`;
hands the top 10 to `@roadmap` for scheduling. Round 1, 2026-08-26.

## Grounding sources used
- `scripts/lua/rpg.lua` v4 (existing systems: breath/O2 meter, HP burn from LAVA/FIRE/PLSM/ACID/NEUT,
  MINEABLE/HARD tiers, chests, quests, RECIPES incl. WIFI/PSCN/TEG/TRBN/B4C/UO2).
- `scripts/define_power_elements.py` — the 13 already-defined custom power elements and their exact live
  behaviours: `UO2` (emitter: NEUT every 120f), `B4C` (absorber: 90% NEUT capture, +4K/hit), `ZIRC`/`GRPH`
  (neutron-transparent solids), `CU`/`STEL` (conductor), `NAK` (liquid sodium coolant, flammable, boils
  883C), `AERO` (insulator, heatConduct 1), `TRBN` (turbine: WTRV→DSTW 25%/frame, sparks conductors),
  `TEG` (teg: >100C pulses SPRK into conductors every 20f), `LEDL` (glower).
- `knowledge/materials-catalog.json` — 80+ real-world-sourced materials with density/heatConduct/hardness/
  melting point (GRNT, BSLT, LMST/MRBL acid-reactive calcination, FBRK, TTAN/TI64, KEVL, PZT piezo, S316,
  AERO/INSL-class insulators, cryogenics LH2/LHE/NAK).
- `knowledge/build-lessons.jsonl` verified entries: PRTI/PRTO **pair by `tmp` channel**, teleporting any
  particle between an inlet and every outlet on the same channel (thermal::prti/prto lesson). WIFI links
  tuned to distinct channel temperatures the same way. **Twin-GPMP walls squeezing a hot VOID well is a
  real, observed gravitational-confinement pattern** (1732752). **VOID is an absorber blanket that deletes
  anything touching it** — must be buffered with a vacuum gap. **AMTR containment is a FRAY/SPRK field
  jacket**, and the lesson explicitly warns a field-only jacket is unsafe without a TTAN/INSL shell around
  it (i.e. "if the field drops, it goes off" is a real, cited risk, not invented drama).
- Stock TPT elements referenced below (FIGH, STKM, VIRS, BHOL/NBHL, PRTI/PRTO, WIFI, PSTN, DTEC, SWCH,
  PSCN/NSCN, CRAY, PUMP, GAS/OIL/NBLE, ACID/CAUS, SAND/SNOW/ICE, GOO, LAVA/WATR/STNE obsidian-crust
  reaction, BOMB/PLEX/C-5, ELEC/water conductivity) are documented stock behaviours already used elsewhere
  in `rpg.lua` (e.g. FIGH, LAVA/FIRE/PLSM/ACID/NEUT damage) or on the TPT wiki.

---

## TOP 10 — ranked, one-paragraph mini-specs

**1. Portal-pipe item network** — fun 5/5, physics 5/5, effort M, owner `@machines`.
Craft a `PRTI`/`PRTO` pair (recipe already has WIFI-tier materials: CU+GOLD) as a placeable "item portal."
Each pair gets a unique `tmp` channel (auto-incremented per crafted pair, shown in the item tooltip). When
the player drops an inventory stack onto a placed PRTI, `rpg.lua`'s existing `mine`-style give/take spawns
a real particle of that ore's element into the PRTI cell; TPT's own portal mechanic (verified:
`thermal::prti/prto channel pairs teleport...; portal temp equals channel state`) moves it to every PRTO on
that `tmp` channel, where a `machines` hook on `tick()` watches PRTO output cells and auto-collects landed
particles back into a chest or the player's inventory if standing nearby. This gives Terraria-style
long-distance item pipes without any new physics — it's the same portal already in the game, driven by
existing recipes.

**2. Buildable fission micro-reactor** — fun 5/5, physics 5/5, effort L, owner `@machines` (+ `@roadmap` for
tier gating).
The core loop already exists as data, not fiction: `UO2` emits `NEUT` every 120 frames; `B4C` control rods
absorb 90% of `NEUT` hits and heat up 4K each; `GRPH`/`ZIRC` pass neutrons through while conducting heat;
`NAK` liquid sodium (900 kg/m3, boils 883C) carries that heat to a `TRBN` turbine, which converts adjacent
`WTRV` to `DSTW` and sparks any touching `CU`/`STEL` conductor; a `TEG` on the reactor's hot side scavenges
extra power once it crosses 100C. Ship this as a guided "Reactor" quest chain (tier 6+ per the roadmap's
8-tier plan): place a UO2+ZIRC+GRPH lattice with `@world`-placed URAN-vein output, run NAK through it to a
boiler, land the steam on a TRBN, wire the TRBN's sparks to power an item (e.g. a WIFI-gated door or a
lit LEDL panel). Every component is a live-tested element with the exact numbers already in
`define_power_elements.py` — no new physics, just a build target and a HUD "core temp" readout.

**3. Structural cave-ins** — fun 4/5, physics 4/5, effort M, owner `@world`.
Terraria and Minecraft both punish over-wide tunnels; TPT already does this for free via stock `SAND`/loose
material falling when unsupported. Tag any generated ceiling block (`ROCK`/soil/ore) that has more than
`N` (e.g. 5) contiguous air cells directly beneath it and no vertical support column within 2 cells as
"unstable" in a `gen()` hook; on a `tick()` pass, unstable blocks above an open span get their type swapped
to a session copy of `SAND` (falls, does real fall damage on landing like the existing LAVA/FIRE hazard
check) after a short random delay shown by a dust-particle warning (cheap FIRE/SMKE puff). This directly
answers Drew's "still super displeased with subterranean area" note by making wide mining feel dangerous
and Minecraft/Terraria-like instead of just hollow, using zero new elements.

**4. Flash-flood caverns** — fun 4/5, physics 5/5, effort M, owner `@world`.
`genBase` already places `WATR` pockets in deep caverns (`d > 250 and cavern > 0.74 ... return "WATR"`).
Extend `gen()` so a fraction of these pockets are sealed behind a thin (2-3px) rock membrane instead of
open water, marked in `R.tiles` metadata. When the player's pick breaks through that membrane (detected in
the existing per-particle chip-mining loop in `useTool`), don't just reveal it — let TPT's real pressure/
gravity sim do the work: the sealed WATR column drops into the newly-opened tunnel exactly like breaching
an aquifer, filling downward corridors and forcing the player to swim or divert it with a placed block/
bucket (the bucket tool already exists). No new element, just deferred reveal + real hydrostatic behavior
already present in stock WATR.

**5. Antimatter core — endgame weapon/power cell** — fun 5/5, physics 4/5, effort L, owner `@items`
(+ `@machines` for the power-cell variant).
Grounded directly in a cited, audited community build: `AMTR` containment in the wild is a `FRAY` field
jacket energized by `SPRK`, and the lesson explicitly flags that the field is the *only* barrier — no
physical shell — so if it drops, containment fails. Make that the game mechanic instead of a bug: craft a
rare "antimatter core" item (TTAN-tier recipe, deep-tier drop) that must be carried inside a player-worn
`FRAY`+`SPRK`-jacketed housing; while worn, it slowly drains a "field charge" resource (crafted from
CU/GOLD electrics already in RECIPES). If charge hits 0 near real matter, trigger a scaled real
annihilation burst (large radial heat+pressure event, reusing the existing LAVA/FIRE damage-tick pattern)
— a genuine "handle with care" superweapon whose danger comes from the *actual* containment lesson learned
from a real save file, not an invented gimmick.

**6. Gravity-well grenade** — fun 5/5, physics 5/5, effort M, owner `@items`.
Also grounded in a cited, audited build: twin `GPMP` (gravity pump) fields squeezing a `VOID` core is a
documented real gravitational-confinement pattern (1732752, GPMP n=3096 / VOID n=1784, Tavg 9700K). Scale
it down into a throwable: on impact, spawn a small ring of `GPMP` cells around a 1-3px `VOID` core for a
few hundred frames (a timed despawn, matching how `VOID` must always be buffered from anything worth
keeping, per the "absorber blanket" lesson). Loose particles, dropped ore, and `FIGH` enemies within the
GPMP ring's pull radius get drawn in and deleted by the VOID center exactly like the source build's fusion
well — a genuinely simulated miniature black hole, not a scripted "everything nearby dies" effect.

**7. Wildfire spreading through wood builds** — fun 4/5, physics 5/5, effort S, owner `@world` (fire rules)
+ `@ui` (warning HUD).
`rpg.lua` already forces "real fire" for smelting (torch + coal) and had to zero out stock `COAL`
`Flammable` because it was catching everything too fast. Flip that danger onto the player's own base: leave
placed `WOOD` at its default `Flammable`, so an untended torch, nearby `LAVA`, or an enemy fire attack can
ignite a real chain fire through a wooden build exactly like it would ignite terrain wood today. Add a
`@ui` warning when `FIRE` first appears within N cells of 3+ player-placed WOOD blocks, and give the
existing bucket tool a "douse" use against adjacent FIRE (kills it, matching how WATR extinguishes FIRE in
stock TPT). This turns Drew's existing real-fire requirement into a base-defense mechanic instead of only a
crafting gate.

**8. Physics dynamite — mining tool and weapon in one** — fun 4/5, physics 4/5, effort S, owner `@items`.
Craft a stick of `PLEX`/`BOMB`-equivalent (session element copying stock C-4/dynamite behaviour) from
COAL+GOO (a crude blackpowder analogue) as a tier-2 hotbar tool. Thrown or placed and lit with the torch
(reusing the existing torch-ignition code path), it detonates using TPT's real explosion (pressure +
heat pulse), which both breaks `MINEABLE` blocks in the blast radius (feeding the same `give()`/mining pipe
already used by picks) and damages `FIGH` in range via the same distance-squared hit check the sword
already uses. One item, two uses, zero new physics — it is stock TPT's own explosive pressure wave routed
through the existing mine/damage hooks.

**9. Snow-biome hypothermia + insulated bases** — fun 3/5, physics 4/5, effort S, owner `@world` (cold
tick) + `@machines`/`@items` (insulation, TEG hookup).
`biomeAt`/`BIOME` already defines a snow biome (`ICE` surface). Add a cold-drain tick mirroring the
existing lava/breath damage block in `movePlayer`: while outside snow-biome ICE/SNOW with no FIRE/torch/
lava heat source within reach, drain HP slowly (same pattern as the current burn/acid/breath ticks — this
is a one-function addition next to code that already exists). The counter: `AERO` (heatConduct 1, already
in the catalog as "power-saving lagging for pipes and tanks") crafted into wall blocks keeps a torch-heated
room warm — real insulator physics, not a flat "% resistance" stat — and a `TEG` mounted on the warm/cold
boundary of that wall passively trickles power (its real >100C-pulse behaviour) as a side benefit for
building a good winter base.

**10. Virus-outbreak cave biome** — fun 4/5, physics 3/5, effort M, owner `@enemies` (+ `@world` for the
biome pocket).
Stock `VIRS` is a real, documented TPT epidemic element: it infects touching particles, which after a life
countdown convert to VIRS themselves and spread further, exactly like the wiki's "infection" description.
Seed a rare deep-cave pocket (tier 3+, gated behind the existing depth/quest system) where `VIRS` has
already infected the local wood/plant matter and even wandering `FIGH`; entering triggers a `@ui` warning,
and the only real cure is fire — burning infected particles with the torch or a thrown dynamite (#8) kills
the VIRS chain outright, same as burning out an infestation in the actual simulation. Reward: the cured
pocket's original chest tier is unlocked once VIRS count in the region hits zero, giving a concrete
"epidemic control" mini-dungeon built entirely from one existing stock element's real spread rule.

---

## Full idea bank by category

### Exploration — biomes, hazards, real pressure/gravity
- **Biome-differentiated worldgen materials** — fun 3/5, fidelity 3/5, effort S, `@world`. `BIOME` table
  already has per-biome grass/soil; swap desert soil to `SAND` (already stock, real granular slump), snow
  soil to packed `SNOW`/`ICE`, swamp soil to `GOO` bogs with patchy shallow `WATR`. Closes the exact P1 gap
  the roadmap already flags.
- **Underground gas pockets** — fun 4/5, fidelity 4/5, effort M, `@world`. Real `GAS`/`OIL` pockets sealed
  in caverns (stock flammable gases); a torch or stray spark within reach ignites a real pressure-driven
  FIRE blowout — mining too eagerly near a gas seam should feel dangerous.
- **Lava-water obsidian crust** — fun 3/5, fidelity 5/5, effort S, `@world`. Where generated `LAVA` borders
  `WATR` at a biome edge, TPT's own LAVA+WATR→STNE reaction already crusts the surface; expose a "crossing
  point" that only opens once the crust cools below a temp threshold, using real heat, not a timer.
- **Quicksand pits** — fun 3/5, fidelity 3/5, effort S, `@world`. Desert-biome `SAND` patches with a lower
  local "density" (partial vacuum under them via existing `PASS` table) sink the player slowly; escape
  needs a placed WOOD plank to stand on, reusing the existing solidW/PASS distinction.
- **Geothermal vents** — fun 3/5, fidelity 4/5, effort S, `@world`. Cells adjacent to deep LAVA periodically
  emit `WTRV` (real steam), creating a rising column the player can ride upward — a free fast-travel shaft
  if they can survive the heat (existing burn-tick already punishes standing in it too long).
- **Bioluminescent deep fungus** — fun 3/5, fidelity 2/5, effort S, `@world`. Deep-cave GRSS-family variant
  with a `glower`-kind behaviour (same `behavior.kind="glower"` already used for `LEDL`) lighting up caverns
  without a placed torch — cheap and reuses an existing behaviour kind.
- **Meteor strike events** — fun 4/5, fidelity 3/5, effort M, `@world`. Rare scheduled event spawns a
  falling hot rock (real high-temp solid, transitions to LAVA on impact per catalog's highTemperature
  fields) that craters terrain and leaves a rare-ore-rich impact site to mine.
- **Wind caverns / updraft shafts** — fun 3/5, fidelity 3/5, effort M, `@world`. Large caverns get a
  scripted local velocity field (TPT's real pressure/velocity grid, same API `set_field_region` uses)
  giving a rideable updraft — a natural elevator shaft instead of a crafted one.

### Survival — temperature, oxygen, fire spread
- **Snow hypothermia** — see Top 10 #9.
- **Wildfire through wood builds** — see Top 10 #7.
- **Desert heatstroke** — fun 3/5, fidelity 3/5, effort S, `@world`. Real `SAND` radiates ambient heat at
  midday (day/night cycle already tracked); standing on exposed desert surface at peak day without shade
  drains HP like the existing lava/breath ticks.
- **Radiation zones near ore/reactor** — fun 4/5, fidelity 5/5, effort M, `@enemies`/`@machines`. `UO2`
  already has `PROP_RADIOACTIVE`; extend the existing damage-tick block to add slow HP drain near unshielded
  uranium veins or an active reactor core, mitigated by standing behind `LEAD` (already in the catalog,
  35 W/mK, real gamma-shielding material) — ties directly into the reactor build (#2).
- **Underwater O2 refill pockets** — fun 3/5, fidelity 3/5, effort S, `@world`. The breath meter already
  exists (`R.breath`); place rare stock `O2`/`OXYG` gas pockets in flooded caverns that instantly top up
  breath when swum through, turning flooded caves into a real risk/reward traversal puzzle.
- **Toxic low-point gas** — fun 3/5, fidelity 4/5, effort M, `@world`. Real heavier-than-air gas (density-
  based settling, already how TPT gases behave) pools in cavern low points; breathing it drains HP unless
  vented by digging a shaft to the surface — teaches the player to read real gas physics, not a hazard
  marker.
- **Frozen-water trap** — fun 2/5, fidelity 3/5, effort S, `@world`. Cold-biome `WATR` below the stock
  freezing point becomes real `ICE`, potentially trapping the player mid-swim; the existing pick can break
  it out (already MINEABLE-tagged).
- **Farming/hunger loop** — fun 3/5, fidelity 3/5, effort M, `@world`/`@machines`. Roadmap open question #2
  — use the real `GRSS` (session PLNT copy, doesn't explode in rain) already added for crops; harvested
  food restores HP over time instead of a hard hunger-death, matching the design doc's "keep it lighter
  than STKM's native hunger" recommendation.

### Engineering / automation — steam, WIFI, portals, pumps, reactors
- **Portal-pipe item network** — see Top 10 #1.
- **Buildable fission micro-reactor** — see Top 10 #2.
- **WIFI ore-alarm / auto-sorter** — fun 3/5, fidelity 3/5, effort S, `@machines`. A placed WIFI receiver
  tuned to a channel keyed to an ore type lights an `LEDL` panel (existing recipe) when that ore is mined
  nearby — real channel-matching, not a scripted popup.
- **Steam-piston elevator** — fun 4/5, fidelity 4/5, effort M, `@machines`. Real WTRV pressure building in
  a shaft (from a lit furnace/lava source below) pushes a `PSTN` piston platform upward; venting a valve
  drops it — actual pressure-driven lift, not a scripted animation.
- **Automated smelting line** — fun 3/5, fidelity 3/5, effort M, `@machines`. Ore dropped above a hopper
  funnel falls by real gravity into the furnace box; a `DTEC`-style presence check auto-feeds coal from an
  adjacent bin so the furnace stays lit without manual torch relighting each batch.
- **Pressure-plate traps/doors** — fun 4/5, fidelity 3/5, effort S, `@machines`. `PSTN`+weight-detection
  (particle-count-in-cell check, same primitive the existing `nearStation` proximity check already uses)
  opens vault doors or drops a portcullis — real mechanical triggering.
- **Irrigation pump** — fun 2/5, fidelity 3/5, effort S, `@machines`. Stock `PUMP` moves WATR uphill to a
  farm plot for the hunger-loop crops above — reuses a stock element with zero new code beyond placement.
- **TEG waste-heat scavenger** — fun 3/5, fidelity 4/5, effort S, `@machines`. `TEG`'s live behaviour
  (`onTemp: 373K, period 20, drop 2`) already exists — expose it as a "free power" building tip: mount one
  on any furnace/lava wall to trickle-charge a WIFI-linked light without burning extra fuel.
- **Logic-gate puzzle vault** — fun 4/5, fidelity 3/5, effort M, `@world`. Dungeon room requires wiring
  `PSCN`/`NSCN` (real one-way-spark semiconductors, already a RECIPE) into an AND/OR combination to open a
  door — a real logic puzzle built from the game's own conductor rules, not an abstracted minigame.
- **Zipline rail** — fun 3/5, fidelity 2/5, effort S, `@items`. A crafted rail item the player can grapple
  onto (extends the existing Grappling Hook accessory's `P.hook` physics) for fast horizontal cave travel.

### Combat — physics weapons, world-interacting enemies
- **Physics dynamite** — see Top 10 #8.
- **Molotov fire bottle** — fun 4/5, fidelity 4/5, effort S, `@items`. Thrown `GLAS` vial of `OIL`; on
  impact (detected via velocity/collision, matching the existing hook-rope collision check) it shatters and
  the OIL catches real fire from any nearby heat source, spreading exactly like the wildfire mechanic (#7).
- **Tesla coil turret** — fun 4/5, fidelity 4/5, effort M, `@machines`/`@enemies`. Placed `SPRK` emitter
  zaps anything standing in `WATR` nearby — real electrical conductivity through water, which also means
  the player must respect the same rule (don't fight in a flooded room near your own turret).
- **Freeze tool** — fun 3/5, fidelity 3/5, effort S, `@items`. A `CRAY`-style cold-ray tool chills `FIGH`
  below its stock freezing behaviour, locking it in place (real low-temp phase effect) for a follow-up
  pick/sword hit — reuses the existing sword hit-detection loop.
- **Acid sprayer** — fun 3/5, fidelity 4/5, effort S, `@items`. Real stock `ACID`/`CAUS` dissolves both
  terrain and `FIGH` particles over time — a weapon that also digs, mirroring the existing ACID damage-tick
  already coded into the player's own hurt logic (symmetric risk/reward).
- **Terrain-aware enemy variants** — fun 4/5, fidelity 3/5, effort M, `@enemies`. Digger `FIGH` that mines
  through soft blocks toward the player (reusing `MINEABLE`/`HARD` tables), swimmer `FIGH` that gets real
  buoyancy in `WATR`, flyer `FIGH` that only shows up over `GAS`/open caverns.
- **Explosion knockback** — fun 3/5, fidelity 4/5, effort S, `@items`. Blast tools (#8) impart real velocity
  impulses to nearby `FIGH` particles (TPT's own explosion push, not a scripted "-10 y") — physically
  correct knockback for free.
- **Lava-elemental boss** — fun 5/5, fidelity 4/5, effort L, `@enemies`. A `LAVA`+`STNE` composite creature
  that melts terrain it touches (real heat diffusion into neighbouring blocks) and cools/crusts when it
  steps in `WATR`, forcing the player to fight it near a water source — an entire boss fight built from two
  stock reactions.

### Building — real material properties, glass/insulation/heat
- **Insulated winter base** — see Top 10 #9 (AERO/TEG half).
- **Glass greenhouse** — fun 3/5, fidelity 4/5, effort S, `@items`. `GLAS` (real light-transmissive, poor
  insulator per the catalog) roofing lets the hunger-loop crops (`GRSS`) grow indoors under real light while
  blocking rain — but a GLAS-roofed room won't hold furnace heat the way a stone one would, so the two
  builds compete for the same room.
- **Blast door vault** — fun 3/5, fidelity 4/5, effort S, `@items`. `TTAN`/`STEL` door recipes (already in
  RECIPES) gated by hardness against the new dynamite (#8) — a door that's genuinely blast-resistant because
  its `MINEABLE`/`HARD` tier is higher than the explosive's power, not a flag.
- **Structural support spans** — fun 3/5, fidelity 3/5, effort M, `@world`. Mirrors cave-ins (#3) applied to
  player builds: an unsupported BRCK/GRNT span past N cells sags/collapses under real weight, teaching the
  same lesson Terraria teaches with wood platforms — add support columns.
- **Real wire aesthetics** — fun 2/5, fidelity 3/5, effort S, `@items`. `CU` conductor wire + `PSCN`
  switches for player-built lighting circuits — already-defined conductor behaviour, just exposed as a
  cosmetic/functional building material instead of only machine internals.
- **Piezo floor tiles** — fun 3/5, fidelity 4/5, effort S, `@items`. `PZT` (piezoelectric, in the materials
  catalog) floor tiles generate a real `SPRK` pulse when the player's weight lands on them — a "fun to walk
  on" power source for small builds like light-up staircases.

### Progression — tiers tied to physics milestones
- **8-tier physics tech tree** — fun 5/5, fidelity 5/5, effort L, `@roadmap`+`@machines`. Already flagged
  P2 in the roadmap; grounds each tier gate in a real material milestone: wood→stone (hardness), stone→iron
  (needs a lit furnace, real fire), iron→steel (real alloying temp), steel→titanium (TTAN, catalog melting
  point), titanium→uranium (radiation-shielded mining, ties to #survival radiation), uranium→working
  reactor (#2), reactor→antimatter (#5) as the final tier — every gate is a physics fact, not a number.
- **"First fire" milestone** — fun 2/5, fidelity 3/5, effort S, `@ui`. Frame the existing torch-needs-real-
  fire requirement as the game's literal first achievement, narratively tying tool-tier unlocks to it.
- **"First smelt" milestone** — fun 2/5, fidelity 3/5, effort S, `@ui`. Same treatment for the existing
  furnace-lit-with-real-fire check (`nearStation("furnace")`) — surface the actual internal temp check as a
  visible HUD milestone instead of a silent gate.
- **Reactor Engineer achievement** — fun 3/5, fidelity 4/5, effort S, `@ui`. Fires once a placed TRBN has
  sparked a conductor at least once (detectable via the TRBN's own `tmp` cumulative-work counter already
  defined) — a real "you generated actual power" badge.

### Weird-fun — black holes, antimatter, virus, stickman armies
- **Gravity-well grenade** — see Top 10 #6.
- **Antimatter core** — see Top 10 #5.
- **Virus outbreak biome** — see Top 10 #10.
- **Stickman army totem** — fun 4/5, fidelity 3/5, effort M, `@enemies`. Craftable totem spawns friendly
  `FIGH`-type allies (same element, opposing faction flag) that fight enemy FIGH using the exact AI already
  in the game — an "army" built from the one enemy element already implemented, just re-flagged as allied.
- **Tamed black-hole pet** — fun 4/5, fidelity 4/5, effort M, `@items`. A small `NBHL` (the weaker stock
  black-hole variant) on a leash follows the player and eats pointed-at obstacles/loose particles in real
  time — same absorption behaviour as the wild element, just leashed via the existing hook/rope physics.
- **Neutron pulse bomb** — fun 4/5, fidelity 4/5, effort M, `@items`. Weaponizes `UO2`'s own real emitter
  behaviour (bursts of `NEUT`) for area denial — and correctly risks a real chain reaction if thrown near
  another UO2 stash, since neutrons plus fissile material is exactly how the reactor (#2) works.
- **Singularity mining charge** — fun 4/5, fidelity 4/5, effort M, `@items`. A heavier, permanent-placement
  version of the gravity-well grenade (#6) sized to open massive caverns in one shot by pulling in and
  deleting a whole vein's worth of rock — an intentional "cheat tool" late-game toy, still just GPMP+VOID.

---

## Notes for `@roadmap`
- Ideas #1, #2, #5, #6 in the Top 10 reuse mechanics that are *already audited in build-lessons.jsonl* from
  real community saves (PRTI/PRTO channel pairing, GPMP+VOID confinement, AMTR/FRAY containment) — these
  carry the highest physics-fidelity confidence in the whole bank and should be prioritized if "verifiable"
  is the tie-breaker.
- Cave-ins (#3) and flash floods (#4) both answer the still-open "subterranean area looks bad" complaint
  with mechanics instead of just more decoration — recommend pairing with whatever `@world` is already
  researching from Terraria/Minecraft.
- The fission reactor (#2) is not new physics — every element it needs is already live and defined
  (`define_power_elements.py`), so it is really a quest-chain/UI task, not an engine task. Good candidate
  for `@machines` to pick up immediately.

---

## Round 2 — 2026-08-26, 15:26 ("make sure you're all communicating on the hub")

New Drew comments processed from the hub's "Drew says" log: 15:12 (cave backgrounds), 15:15 (fresh-start
new world), 15:22 (underground clutter), 15:24 (MCP tool), 15:08 (jetpack on jump key), 14:38 (loves the
acid gun). Three of these (15:15 fresh-start, 15:08 jetpack key, 15:24 MCP tool) are input-mapping/state-
reset/tooling fixes already owned and in progress by `@lead`/`@items`/the new `@mcp` worker per the hub —
no new idea-bank spec needed there, see the hub line below. The other three turn directly into grounded
specs, elaborating what `@world` is already mid-flight on (13:22/13:49 hub log) and what `@items` is
already tasked with (14:40 hub log) rather than duplicating it.

### What actually makes a TPT underground read as "natural" (grounding note for #world)
Terraria/Minecraft-style undergrounds read as natural because three separate signals are legible at once —
this is the checklist behind the four ideas below: **(1) strata** — rock type changes with depth in wide
contiguous bands, not randomly; **(2) a water table** — everything below one global level is wet, above it
is dry, with a sharp readable boundary; **(3) veins/rooms are chunky, not speckled** — ore and decoration
noise sampled at a large enough period that features are multi-pixel blobs. TPT gives all three for free:
real solid elements already have distinct colours/hardness (materials-catalog.json), `WATR` already obeys
real hydrostatic settling, and noise period is just a tuning number in `genBase`'s existing `vnoise` calls.

- **Global hydrostatic water table** — fun 3/5, fidelity 5/5, effort M, `@world`. `rpg.lua` already has a
  `WATER_LEVEL=200` surface-sea constant; extend the *underground* open-cavern rule so any connected cavern
  volume below that same depth is allowed to fill with real `WATR` (today `genBase` only spawns isolated
  deep-cavern WATR pockets via a local noise check, `d > 250 and cavern > 0.74 ...`). Let TPT's own gravity/
  pressure settle it flat instead of noise-placing blobs: caves above the table stay dry (torch-friendly,
  matches the existing furnace/torch mechanics), caves below it are flooded (needs the bucket or breath
  management, feeding directly into the round-1 O2-pocket and flash-flood ideas). This is the single
  biggest lever for "coherent, not scattered" because it replaces arbitrary water specks with one readable
  global rule, exactly like Minecraft's aquifer boundary or Terraria's underground lakes.
- **Depth strata bands from the real material catalog** — fun 3/5, fidelity 4/5, effort M, `@world`.
  Replace the single flat `ROCK` filler in `genBase` with 4-6 wide horizontal bands, each a real catalog
  material with its own colour/hardness already defined: ~0-150px topsoil/`GOO`, 150-400px `SDST`
  (sandstone, tan, soft — hardness 15), 400-700px `LMST` (limestone, pale — real `ACID`-reactive band per
  materials-catalog.json's `rules: "ACID>NONE,SELF:80:.15::CO2"`), 700-1100px `GRNT` (granite, gray,
  hardness 15 but denser), 1100-1500px `BSLT` (basalt, near-black, hardness 70), 1500px+ deep zone toward
  bedrock/`DMND`. Warp each band boundary with the large-period noise `@world` is already adding for strata
  (13:22 hub log) so it reads as tilted sediment, not a ruler line. Bonus payoff for Drew's favorite weapon
  (14:38, acid gun): the limestone band is a real, cited acid-soluble material, so the acid gun tunnels
  through that band faster than granite/basalt — a second genuine use for the gun beyond combat, for free.
- **Clutter checklist (verifies the 15:22 complaint is actually fixed)** — fun 3/5, fidelity 3/5, effort S,
  `@world`. Codifies `@world`'s own 13:49 diagnosis into a concrete acceptance check rather than a vibe:
  (a) every ore/crystal noise check uses a period 2-3x larger than today so veins render as contiguous
  3-8px blobs, never single-pixel freckles; (b) no decorative element (moss, mushroom, crystal fleck) is
  ever placed smaller than 3x3px; (c) cavern "rooms" come from exactly one threshold pass (cheese-cavern
  noise) and tunnels from a separate worm-tunnel pass — never both algorithms writing the same cell, which
  is what produces the "stuff is everywhere" mush; (d) every chest sits inside a real open room (already
  true per `chestAt`), never floating inside solid rock. Ship this alongside the strata/water-table ideas
  above as one combined "new gen" pass so Drew only needs to start one fresh seed to see all of it (per his
  15:15 fresh-start expectation, already wired in core).
- **Depth-tinted cave backdrop with real crystal glow** — fun 4/5, fidelity 3/5, effort S, `@world`
  (elaborates the spec already assigned at 15:12 in the hub). Draw parallax rock-silhouette layers behind
  open-air cave cells via `R.hooks.draw` (alpha over air only, same technique as the planned surface
  ambience layers), but tint the backdrop using the *actual strata band colour* at that depth from the
  catalog (SDST tan near the surface fading through GRNT gray to BSLT near-black by 1500px) instead of a
  generic gradient — so the background itself teaches the player the strata system above. Scatter rare
  glowing crystal deposits using the same `glower`-kind behaviour already live on `LEDL` (period-based pulse,
  zero new behaviour code) only near real ore veins, so the glow is a legible "ore nearby" signal instead of
  pure decoration. Stay inside `@world`'s own <2ms budget by drawing backdrop only for camera-visible tiles,
  the same windowing the existing `fillRegion`/tile-store already does.

### Weapon/gun ideas — building on the validated acid-gun direction (14:38)
- **Held weapon sprite system** — fun 4/5, fidelity 2/5, effort S, `@items` (elaborates the spec already
  assigned at 14:40 in the hub). `drawPlayer` already renders a held-tool indicator for pick/axe/sword
  (a colored rect swung on a frame timer) — extend that exact code path to a per-weapon pixel sprite that
  rotates/flips toward the cursor using the aim data the player already tracks, add a short recoil kick
  (offset the hand position opposite the aim vector for ~4 frames after firing, the same duration pattern
  the sword swing already uses), and a one-shot muzzle flash using a real `PHOT`/`FIRE` burst particle at
  the barrel tip. Zero new physics: it's the existing hand-draw hook made per-weapon, plus a cosmetic
  particle burst from elements already in the game.
- **Plasma jet** — fun 4/5, fidelity 4/5, effort S, `@items`. Same "real element as ammo" shape as the acid
  gun, swapped to a short-range continuous stream of stock `PLSM` (ionized gas): high damage/heat against
  armored enemies, but holding the trigger too long heats the player's own hand (reuses the existing >500K
  burn-tick check already in `movePlayer`) — a genuine risk/reward tradeoff instead of a free upgrade.
- **Cryo gun** — fun 4/5, fidelity 3/5, effort S, `@items`. Upgrades round-1's single-cast Freeze tool into
  the acid gun's continuous-stream form factor: a cold field that phase-changes nearby `WATR`/moisture into
  real `ICE`, locking enemies solid for a follow-up melee/pick hit.
- **Steam nail gun** — fun 3/5, fidelity 4/5, effort S, `@items`. A `PSTN`-driven real pressure-discharge
  weapon (same mechanic underlying the round-1 steam-piston elevator idea): each shot is a literal pressure
  pulse launching a metal sliver, feeding `R.damageEnemiesAt`'s existing knockback parameter for a
  physically real kick instead of a scripted one.
All four reuse whatever stream/hitscan plumbing `@items` already built for the acid gun rather than needing
new weapon infrastructure — this is explicitly "more of what Drew already said he likes," per the roadmap's
own 14:40 note to prioritise physics-driven weapons like it.

### Not added as idea-bank specs (already handled elsewhere, noted for traceability)
- **15:08 jetpack-on-jump-key** — a control-scheme remap (`@items`: jump held in air = jetpack, left mouse
  freed for tools), not a new mechanic; nothing to ground.
- **15:15 fresh-start new world** — already fixed in core (full state wipe + `R.hooks.newworld` fired on new
  seed); the strata/water-table/clutter ideas above are exactly what a fresh seed needs to look right when
  Drew tries it.
- **15:24 MCP indexing tool** — a tooling/infra request for the new `@mcp` worker, not a gameplay idea. One
  concrete suggestion for that worker: expose `knowledge/rpg-ideas.md` and `knowledge/build-lessons.jsonl`
  as searchable MCP resources so every plugin worker can pull a grounded mechanic mid-build instead of
  re-deriving it — directly serves Drew's "rapidly, constantly index and work on this" ask.

---

## Round 3 — 2026-08-26, 15:48 (oxygen meter follow-ons)

Core now has `R.o2` (0-100, `rpg.lua` movePlayer): every 5 frames it samples a 5x5 grid of points around
the head (`oy=-14..2 step4, ox=-8..8 step4`) against a `BADGAS` table (`WATR/DSTW/SLTW/LAVA/SMKE/CO2/H2/
HYGN/NBLE/GAS/WTRV/PLSM/FIRE/CAUS/BOYL`), drains 1.6/tick underwater or `1.0*frac` when >35% of sampled
cells are bad gas, refills 3/tick in clean air, and deals 3 HP/tick suffocation damage at 0. Every follow-on
below hooks into that exact sampling loop (raising/lowering `bad`/`tot` or the O2 gain/drain rate) rather
than adding a parallel stat, so they compose with each other and with anything else that touches the air.

- **Oxygen tank accessory** — fun 4/5, fidelity 4/5, effort S, `@items`. A wearable "tank" that stores a
  charge of real compressed `OXYG` (already `PASS`-listed and *not* in `BADGAS`, i.e. already coded as
  breathable). While worn and charge > 0, on each 5-frame O2 tick the accessory vents a few `OXYG` particles
  into the same head-sample box the core loop already scans — this directly displaces `BADGAS` hits in that
  specific 5x5 grid, lowering `frac` the same way standing in genuinely clean air would, rather than a flag
  that ignores the sampling. Charge drains with use and is refilled by standing near an air pump (below) or
  swapped for a fresh tank crafted from mined/compressed OXYG. Craft path: mine natural `OXYG` pockets
  (`@world` seeds a few near the surface/shallow caves, it's already a passable stock gas) and compress them
  into a tank at the anvil — same tier slot as the existing Lava Charm/Rocket Boots accessories in
  `R.ACCS`/`R.ACC_ORDER`.
- **Diving helmet** — fun 3/5, fidelity 4/5, effort S, `@items` (pairs with the tank above). A second,
  higher-tier accessory that represents an airtight seal rather than a gas source: while worn *and* an
  oxygen tank is equipped with charge > 0, the head-sample loop is skipped entirely for `WATR`/`DSTW`/`SLTW`
  hits specifically (so submersion no longer drains O2 at all, matching a real sealed helmet), while other
  `BADGAS` members (smoke, CO2, flammable gas) still count normally since a diving helmet doesn't filter
  toxic air, only keeps water out — this is the actual real-world distinction between a diving helmet and a
  gas mask, and it falls out for free by only special-casing the three water names in the existing table
  instead of a blanket "no drowning" switch. Tank drains faster while submerged (real consumption is higher
  underwater) — reuse the existing `inWater` local the loop already computes.
- **Trees/plants as real O2 sources** — fun 3/5, fidelity 4/5, effort S, `@world`. `UO2`'s live behaviour is
  already `{kind="emitter", params={emits="NEUT", interval=120, count=1, ...}}` (`power_kinds.lua`, see
  `define_power_elements.py`) — reuse that exact emitter kind on the existing `GRSS`/tree-canopy cells
  (session-defined PLNT copy) with `params={emits="OXYG", interval=90, count=1}` instead of NEUT. This
  makes a real, already-tested custom behaviour do double duty: a planted greenhouse (round-1 idea) or a
  natural forest biome now measurably raises local O2 fraction around the player exactly like any other
  emitter in the game, giving farming/greenhouses (and the GLAS-roofed greenhouse idea) an actual mechanical
  payoff beyond food — stand in a lush grove or a glass-roofed indoor garden and the O2 bar visibly climbs
  faster than in a bare stone room.
- **CO2 buildup from furnaces/boilers in enclosed rooms** — fun 4/5, fidelity 5/5, effort M, `@machines` (+
  `@world` for the strata tie-in). Grounded in a real, already-cited catalog reaction rather than an
  invented "machines pollute" rule: `LMST`/`MRBL` (limestone/marble — both proposed as real strata bands in
  Round 2) have `highTemperatureTransition: "CO2"` at 900-1173K and *also* the reactive rule
  `"ACID>NONE,SELF:80:.15::CO2"` — i.e. real rock, real heat or real acid, real CO2 gas, already fully
  specced in `materials-catalog.json`. Any furnace/boiler built with LMST/MRBL walls (a plausible player
  choice once that strata band exists) or simply operating near a natural limestone vein will calcine it
  over time and vent real CO2 into the room. In an open room the gas disperses; in a sealed player base it
  pools at floor level (real density-based gas settling, same physics the toxic-gas-pocket idea already
  relies on) and will eventually push the head-sample `frac` over the 0.35 drain threshold if the room has
  no vent shaft — teaching the exact real lesson that motivated carbon-monoxide detectors, but built from a
  cited rock reaction instead of a scripted "machines are dangerous" flag.
- **Cave gas pockets that need venting** — fun 4/5, fidelity 4/5, effort M, `@world`. Splits round-1's single
  "underground gas pockets" idea into two distinct, correctly-modeled hazards now that the O2 system exists:
  **flammable pockets** (real `GAS`/`OIL`, ignite loudly on contact with a torch/spark — the round-1
  version, a *fast, obvious* danger) versus **asphyxiant pockets** (real `CO2`, already in `BADGAS`,
  produced the same way as the machines version above from a buried, ancient LMST/MRBL vein that calcined
  underground) which do **not** ignite and give no warning beyond the O2 bar quietly dropping — a genuinely
  different, quieter hazard that rewards players who watch their O2% while digging rather than just their
  torch. Both pocket types sit in real cavern low points (gas settles by density) so a player who digs a
  vent shaft upward — or drags an air pump hose down (below) — clears either one via the same real
  mechanism: diluting the local gas fraction the head-sample loop measures.
- **Air pump / sealed-base life support** — fun 4/5, fidelity 4/5, effort M, `@machines`. Stock TPT's `PUMP`
  element is a real pressure-field tool (raises/lowers ambient pressure in a region, moving *any* fluid or
  gas along the field, not just liquid) — `machines.lua`'s existing PUMPKIT already uses it for `WATR`
  intake/outlet (13:41 hub log). Add a second PUMPKIT mode/recipe that points the same real pressure-field
  behaviour at gas instead of liquid: an intake hose reaching outside/upward pulls in ambient air (raising
  local non-`BADGAS` fraction) while an exhaust hose vents accumulated `CO2`/`SMKE` out of a sealed room —
  a real HVAC system built from the exact element already shipped, just re-plumbed. This is the direct fix
  for both the furnace-CO2 idea and the asphyxiant cave-pocket idea above: place one in any sealed base or
  flooded/gassed dig site and the O2 sampling loop reads clean air again because the air actually is
  cleaner, not because a flag was set.
