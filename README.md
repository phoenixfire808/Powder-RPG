Powder RPG
==========================

[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/phoenixfire808/Powder-RPG?label=latest%20build&color=orange)](https://github.com/phoenixfire808/Powder-RPG/releases/latest)
[![Changelog](https://img.shields.io/badge/changelog-full%20history-brightgreen.svg)](CHANGELOG.md)

**Powder RPG** is a survival game mod for [The Powder Toy](https://powdertoy.co.uk/) — real falling-sand
physics, not a fake meter on top. You mine, craft, breathe real oxygen, build machines, and survive
in a side-scrolling world made entirely of simulated particles. This repo is **not** the upstream
Powder Toy project; it is an RPG fork (`phoenixfire808/Powder-RPG` on GitHub).

**[Download the latest Windows build](https://github.com/phoenixfire808/Powder-RPG/releases/latest)**
— unzip, then **double-click `PowderToyRPG.exe`**. No batch file required.

## Repo layout (everything is here)

| Path | What |
|------|------|
| `src/` | Engine fork (C++ elements, bridge HTTP, game view) |
| `scripts/lua/rpg.lua` | **Powder RPG** gameplay (survival, world gen, HUD) |
| `scripts/lua/rpg_plugins/` | RPG plugins (machines, companion, save, UI, …) |
| `bridge_src/` | Lua bridge modules (realism, RPG loader) |
| `build_autorun.py` | Builds `build/autorun.lua` from `bridge_src/` |
| `powder_toy_mcp.py` | Scripting/automation server for external tooling (`python powder_toy_mcp.py`) |
| `powder_ext/` | MCP tool implementations |
| `knowledge/` | Design docs, modules, structures, build lessons |
| `releases/` | Per-version release notes |
| `DEVELOPMENT.md` | Development protocol and house rules for this project |

Clone this repo, build the engine (`meson` + `ninja` — see wiki), run `python build_autorun.py`,
then play from `build/PowderRPG.exe`. MCP: point Cursor at `.mcp.json` in the repo root.

Table of contents
---------------------------------------------------------------------------
- [Powder RPG](#powder-rpg)
- [Life support & machines](#life-support--machines)
- [New physics & elements](#new-physics--elements)
- [Sandbox quality-of-life](#sandbox-quality-of-life)
- [Getting the update while you play](#getting-the-update-while-you-play)
- [Vision](#vision)
- [Roadmap](#roadmap)
- [Running from source](#running-from-source)
- [Credit & license](#credit--license)

Powder RPG
===========================================================================
A continuous, side-scrolling world built entirely out of the sandbox's own particles —
every block you stand on, mine, or die to is a real simulated element, and every survival
system runs on the engine's actual physics rather than a scripted approximation of it.

- **A real atmosphere, not a meter.** Digging opens a genuine low-pressure pocket that the
  sim's own air physics fills from above; the surface holds a real, permanent positive
  pressure baseline pushing back down. Oxygen is a real, visible particle whose density
  scales with depth — thin and sparse far underground, abundant at the surface — and
  breathing consumes it and exhales real CO2 next to you. Sealed rooms only get dangerous
  once they're genuinely deep, not the instant you close a door at ground level.
- **Survival needs**: hunger and thirst drain over time and do real damage at zero; a
  Canteen lets you carry and boil water, and simply standing in a real lake quenches thirst
  directly. Taking damage (falls, burns, radiation, hunger, suffocation) draws real blood
  that isn't walkable, so you can't casually stand on your own puddle.
- **A permanent companion** — not a summonable pet: she's present from the moment a new
  world generates, pathfinds and fights alongside you with her own HP and death/revive
  cycle, reacts to what she sees in the world, and answers you in a chat box. Her behaviour
  is hand-authored against the simulation, not delegated to a model.
- **Fallout-style radiation** — uranium and plutonium contaminate the ground around them,
  which decays slowly over real time, and your character accumulates a long-term dose that
  keeps doing damage even after you've walked away. Lead blocks the buildup.
- **Day/night cycle and weather**, with an adjustable day length, rain that can strike
  lightning, and a toggleable enemy spawner that sends stick-figure attackers your way.
- **Deep crafting progression** — workbench, furnace, and anvil crafting stations feed into
  a Research Bench and an Advanced Lab past that, gated behind real material costs; ores
  smelt into bars, bars forge into tools across wood → stone → iron → steel tiers, each with
  its own damage/mining-power stats and an always-visible description.
- **Native drawing tools in survival** — Shift-drag draws a straight line and Ctrl+Shift
  drags out and fills a whole box from your own inventory, the same gestures the sandbox's
  own tools use, now working against what you've actually mined and carry.
- **A live-tunable world engine** — day length, cave frequency, ore rarity, gravity, jump
  height, and move speed are all real sliders in the Esc/Options menu, not fixed constants,
  so the feel of the world is something you dial in rather than accept.
- **A real title screen** — Play/Settings/Quit before world generation, with "quit to menu"
  reachable mid-game without killing the process or losing your in-memory world.
- **A 14-step guided quest chain** — from "chop 10 wood" through smelting, forging, biome
  exploration, and a 50m depth milestone, up to steel tools and diamond rewards, so a new
  player always has a next goal instead of an empty sandbox.
- **Persistent saves**, a chat/log feed, and a minimap.
- **Built-in bug reporting** — press F8 in-game to send a bug report or suggestion straight
  to the dev's Discord, with automatic context (seed, day, frame) attached, no alt-tabbing
  or GitHub account required.
- **Self-updating** — the game checks this repo's releases on startup. If you're behind, it
  shows a changelog dialog — now with a real scrollbar you can drag, not just the mouse
  wheel — listing everything you've missed across every skipped release, and lets you
  install with one keypress; it downloads, swaps its own files out, and relaunches on its
  own.

Life support & machines
===========================================================================
Underneath the survival layer is a real energy/life-support progression: descending
requires sustaining yourself with machines that chain into each other, not just better gear.

- **Real atmosphere engineering** — bellows, air lines, compressors, and life-support panels
  that report whether a room is genuinely sealed or open to sky, all reading and feeding the
  same pressure/oxygen physics the player breathes.
- **A full energy tree** — solar, wind, geothermal, fuel cells, and electrolysis, plus
  boilers and turbines running on real steam physics (measured live: water climbs through a
  real 373K phase change, boils dry on schedule with the fuel that's lit under it, and a
  piped connection to a turbine produces real, measurable output).
- **Chemistry, fluids, and logistics machines** — electrolysis cells, acid synthesis, sorters
  and splitters, silos and quarries, all built from real reagents and real particle behavior
  rather than abstract recipes.
- **Hazard atmosphere** — carbon monoxide from fire in a sealed room, CO2 from smelting,
  explosive methane from swamp/oil pockets, and depth radiation all demand real mitigation
  (scrubbers, ventilation, lead shielding) instead of just better armor.

New physics & elements
===========================================================================
Roughly 60 new elements on top of the ~180 stock ones, several backed by real physical
constants rather than arbitrary game numbers.

**Antimatter & magnetism showcase** — a from-scratch physics demo (inspired by
[Veritasium's antimatter video](https://www.youtube.com/watch?v=fp7GetAY-1I)) with four
live bays: antimatter production, magnetic containment, an annihilation chain reaction, and
a shielded-vs-unshielded comparison. `AMTR` annihilates on contact, releasing its full mass
as heat, light, and a shockwave — unless it's inside a live `MGNT` electromagnetic field.

**Real rare-earth magnetism** — `GADO` (gadolinium) is a genuine permanent ferromagnet
below its real Curie point (~20°C) and loses magnetism above it; `FEFL` (iron filings) is
light enough to actually be pulled and clumped by a magnetic field, unlike a solid iron bar;
`LUTE` (lutetium) rounds out the set as the densest, hardest rare earth.

**Everything else**, grouped by what it's for:

| Category | Elements |
|---|---|
| Reactive chemistry | Chlorine, sodium, phosphorus, acetylene, nitrogen/liquid nitrogen, ammonia paths, graphite oxidation |
| Nuclear & radiation | Promethium, radon, quark-gluon plasma, radiation-shielding fabric (Demron) |
| Electronics & power | Customizable wire, LEDs, lithium-ion batteries, thermostats, tmp/ctype/gravity sensors, digital signs, powered converters, turbines |
| Materials processing | Generic gas/liquid/powder/cast-solid forms so any material can boil, melt, pulverize, or cast |
| Structural & defensive | Load-bearing structure blocks that collapse without support, defence foam, indestructible elemental walls, rubber |
| Creatures & robots | A bee that pollinates and defends its hive, a robot pet that follows and fights alongside you |
| Weapons & mechanisms | Guided missiles, powered projectiles, custom explosives, mechanical wheels |

Sandbox quality-of-life
===========================================================================
- **Sandbox / RPG-menu toggle** — flip the native element menu, HUD, and toolbar on or off
  from one place, so the RPG's own input handling never fights the classic sandbox tools
  underneath it.
- **Favorites wheel** and **custom brush shapes** for faster building.
- A local, loopback-only HTTP bridge (`net.listen`) that exposes safe, read-only and
  queued-mutation actions for external tooling — the same bridge this whole feature list was
  verified through.

Getting the update while you play
===========================================================================
The version you're running is always shown bottom-left. When a newer build exists, a
changelog window lists exactly what changed in every release you've missed — press **U** to
install immediately (it restarts on its own in a few seconds), or **Esc** to keep playing
and update later; the reminder stays on screen either way.
Vision
===========================================================================

The pillar this project is built around: **a survival RPG where the physics is real, not
simulated-looking.** Every system below — atmosphere, fire, radiation, energy — is meant to
behave the way the underlying particle sim actually computes it, not a game-design
approximation layered on top. That constraint is deliberate and won't loosen as the game
grows; a new mechanic has to be a real consequence of real physics before it ships.

**The identity, stated plainly: you are not just surviving against a hostile world — you are
building a small industrial ecosystem that converts energy into breathable air, drinking
water, and food, and the tech tree is the story of that ecosystem getting bigger, safer, and
more self-sufficient.** That's not a pitch for something planned — it's already true of the
current build, assembled piece by piece across many sessions without ever being named out
loud until now. Concretely, today, in shipped code: power (turbines, reactors, solar) feeds
electrolysis, which splits real water into real oxygen for life support and hydrogen as a
byproduct; a gas turbine or fuel cell burns that hydrogen for more power (explicitly a closed
loop back to electrolysis); the water side feeds real crop farming and a desalinator turns
brine into more of it. Food and water are real depleting stats (`R.need.food`,
`R.need.water`), and this is the same loop that keeps them (and you) alive — closer to a
Factorio / Oxygen Not Included hybrid than a generic survival-craft game, and already real.

The tech tree already reflects this: Workbench → Furnace → Anvil (where the power chain
begins — `O2GENKIT`, turbines, and fuel cells are Anvil recipes, several gated on a real
"100W generated" production threshold, not just proximity to a bench) → Research Bench →
Advanced Lab, each tier requiring the previous tier's own output as an ingredient, so a
real production-rate gate exists alongside every station gate. The next rungs follow the same
shape, and the material work backing them is already shipped or scoped:

- **Reactor tier** — turns the existing fission-plant-scale `UO2` / `ZIRC` / `GRPH` / `B4C`
  chain (already real, already simulated with a genuine neutron economy — `UO2` emits real
  `NEUT` via spontaneous fission, `ZIRC` is a real neutron-transparent cladding, `GRPH` is a
  real high-conductivity neutron moderator, `B4C` is a real neutron absorber for control
  rods) into a repeatable Advanced-Lab recipe chain instead of a one-off demo build. Each
  intermediate is its own craftable item (Fuel Rod: `UO2` + `ZIRC` cladding; Moderator
  Block: `GRPH`; Control Rod: `B4C` + `STEL` actuator) wrapped in a `CNCR`-shielded
  Reactor Core structure that runs the real neutron-economy simulation already proven out
  in the existing `FSN-2` / `PLUT` precedent builds and wires its output to the same
  turbine / power-grid system everything else uses. The real design work already exists in
  the project's community-plant notes — this tier is packaging proven physics into a
  repeatable player-facing recipe chain, not inventing new reactor physics.
- **Sealed-base life support** — a designated enclosed area where life-support machines
  maintain `O2` / `food` / `water` automatically for time spent there, so the base-building
  loop matters mechanically (not just cosmetically) and late-game power generation has an
  actual sink. Implementation deliberately reuses the same cheap multi-ray
  `roomSealed(wx, wy)` heuristic the game already runs every tick for the player's
  breathing check, sampled at a life-support machine's location plus a small ring around
  it — not an `O(area)` flood-fill, which risks exactly the oxygen-spawn-lag bug the
  project has already learned the hard way not to repeat. While sealed, the controller
  tops up a persistent `base O2 / food / water` pool the player draws from while inside,
  reusing `R.o2` / `R.need.food` / `R.need.water` and their existing regen logic.
- **Fluid / gas logistics tier** — pipes moving `WATR` / `HYGN` / `OXYG` between machines
  without the player manually carrying it. A `CONVEYOR` machine already exists
  (`buildConveyor`, pushes solid / powder materials along a belt); the actual gap is
  narrower than "build a logistics tier from scratch," because fluids / gases don't have
  automation yet — existing "pipes" (e.g. the boiler's steam-takeoff pipe) are fixed
  structural channels built as part of one specific machine, not a general player-placeable
  pipe connecting arbitrary machines. Concrete proposal: placeable pipe segments (visually
  similar to the conveyor's belt-segment pattern) that, once connected between two
  machines with matching fluid ports (e.g. an `O2GENKIT`'s `HYGN` output and a turbine's
  fuel input), move a bounded amount of that fluid per tick — the same per-tick
  solid-pushing shape `CONVEYOR` already uses, generalized to liquids and gases. This is
  what actually completes the closed energy / oxygen / water loop into something a player
  builds once and leaves running automatically, instead of manually re-carrying water and
  hydrogen between machines forever.

Roadmap
===========================================================================
This section reflects the real, current state of the project — what's actually shipped and
verified (grounded in `R.CHANGELOG` / `CHANGELOG.md`, not aspiration), what's designed but not
yet built, and what's still just a proposal. The full running wishlist of proposed systems,
including newer ones not yet promoted into this roadmap, lives in
[knowledge/feature-wishlist.md](knowledge/feature-wishlist.md) and is meant to keep growing
across sessions — check there for the latest state if this section looks stale.

### Shipped (selected — see [CHANGELOG.md](CHANGELOG.md) for the full version-by-version list)
- [x] **Cave generation, "empty vertical tunnels going straight down"** — root-caused
      with real measured numbers (an entrance-tunnel centerline formula covered too little of
      its own noise cycle to wind naturally for the first 20–40 depth units below the
      surface) and fixed with a second, fast-decaying noise layer active only near the
      surface; deep-cave behavior is numerically unchanged. Shipped v1.15.0.
- [x] **Respawn-path-drift bug class closed** — four-version saga (v1.15.7 → v1.15.10)
      fixing state (companion position, pollution stats, overhead cleanup) that silently
      didn't apply on the bed-respawn path because it bypassed the main `R.spawnPlayer()`
      entry point; closed with two shared helpers (`R._resetSpawnState()`,
      `R._teleportCompanionAndClear()`) called from every spawn path. Full retrospective:
      [releases/v1.15.7-v1.15.10-retrospective.md](releases/v1.15.7-v1.15.10-retrospective.md).
- [x] **Tree water routing + underground aquifer soak (v1.15.42 → v1.15.65)** — rain and
      standing water now visibly route down hollow tree trunks as vein lines, soak into a
      root-zone moisture band that feeds a small underground aquifer layer
      (`treeAquiferAt` / `treeAquiferSpreadTick`), and drain correctly out of the gaps
      *between* adjacent trunks instead of pooling on canopy leaves. Trunk/canopy no
      longer crumbles to sawdust from nearby digging or hot-reloads (v1.15.65) — though
      the underlying support check was still wrong at that point and was re-fixed in
      v1.15.74, which found a direct collapse call on a healthy surface-supported trunk
      destroying 397 wood cells against a limit of 25. This is
      real, live, bridge-verified plumbing — but it's scoped to tree-adjacent moisture,
      not a world-wide water table or player-facing flooding/draining/pumping system; see
      [knowledge/current-progress.md](knowledge/current-progress.md) for the verification
      detail and [knowledge/feature-wishlist.md](knowledge/feature-wishlist.md#1-full-aquifer-system)
      for the full-aquifer-system item this precedent feeds into.
- [x] **Underground environment feel (v1.15.60 → v1.15.62)** — real depth-scaled
      geothermal gradient, biome-specific surface temperatures, and per-cave-pocket
      microclimates, with the TEMP/PRESS HUD reading the full depth column instead of a
      flat ~72°F everywhere.
- [x] **Mining ventilation physics (v1.15.28 → v1.15.58)** — newly dug cavities no longer
      fill with breathable air instantly; ventilation diffuses in from adjacent open air
      over ~50–90 ticks, mined-cavity water no longer floats mid-air, and dig-pressure lag
      was root-caused and optimized.
- [x] **HUD legibility pass (v1.15.24 → v1.15.47)** — multiple rounds closing real overlap
      bugs (Day/GOAL text collision, minimap crowding, Esc-menu column bleed, TEMP/PRESS
      gauge labeling) rather than a single redesign; each round is its own verified fix.
- [x] **Vehicles: minecart + rail + mine-lift kits (v1.15.26)** — buildable rail network
      (LMB-drag snapped track), rideable minecart, and a powered vertical mine-lift cage.
- [x] **Inventory UX overhaul (v1.15.28, `UI-INV-1/2/3`)** — Carried tab rebuilt from a
      scrollable text list into a real bordered grid with Terraria-style left-click
      pick/place semantics and a stack-merging SORT.
- [x] **Fail-closed visual verification harness (v1.15.33 → v1.15.38)** — `goal_verify.py`
      / `verify_claim.py` with a mandatory screenshot gate, because `lastErr == nil` was
      repeatedly proven **not** sufficient on its own (three real bugs — `drawMenu`,
      `wrap`, HUD row overlap — all shipped with `lastErr=nil` and passed the old,
      bridge-only checks). See [knowledge/verification-system.md](knowledge/verification-system.md).

### Near-term (designed or actively in flight)
- [ ] **Full aquifer system** — extend the tree-water precedent above into a real
      world-wide water table (connected cavern volume below one global depth fills with
      real `WATR` via TPT's own hydrostatic settling, replacing today's isolated
      noise-placed deep-cavern pockets), tunnels that fill/drain in response to player
      digging, and wells/pumps as a craftable hook into it. Proposed, not yet designed in
      full — see [feature-wishlist.md #1](knowledge/feature-wishlist.md#1-full-aquifer-system).
- [ ] **Real geological layering for subsoil / bedrock** — currently the bottom of the
      world keeps defaulting to fired brick, which is structurally fine but cosmetically
      wrong. Researched against actual soil science (topsoil → subsoil / regolith →
      bedrock) and this engine's real element physics. The recommended V1 fix is a single
      substance swap: `BSLT` (real basalt, id 503), which is verified genuinely solid
      (`Falldown = 0` AND `bit.band(props, elem.TYPE_SOLID) ~= 0`) and is already a real
      registered element, so no new `elements.allocate` cost. An earlier attempt swapped
      in `STNE` instead and the generated terrain collapsed — caught and reverted in the
      same session (`STNE` is `Falldown = 1`, i.e. a falling powder, not solid rock). The
      `BSLT` swap itself is researched and spec'd but not yet applied to the world-gen
      fallback; full fix awaits a re-verified code change.
- [ ] **Structural cave-ins** — wide mining tunnels become genuinely dangerous: ceiling
      blocks over a large unsupported span convert to a falling-powder copy after a short
      warning delay, using TPT's own unsupported-granular-fall physics, no new elements.
      Proposed — see [feature-wishlist.md #5](knowledge/feature-wishlist.md#5-structural-cave-ins).
- [ ] **Flash-flood caverns** — some deep-cavern water pockets are sealed behind a thin
      rock membrane; breaking through with a pick lets TPT's real pressure/gravity sim
      flood the newly opened tunnel instead of just revealing static water. Proposed — see
      [feature-wishlist.md #6](knowledge/feature-wishlist.md#6-flash-flood-caverns).
- [ ] **Behavior-kind persistence** — a few of the power / reactor elements (turbine,
      thermoelectric, reactive concrete) are defined through custom behavior kinds that
      are not yet re-registered on restart, so they currently only work in a live dev
      session rather than a fresh launch — everything else in the elements table above
      survives a restart intact. This is being driven from a single
      `apply_realism_modules` call against the lab instance so it can be re-tested
      end-to-end before claiming it's fixed.
- [ ] **Item quality system** — crafted tools rolling a quality tier that affects their
      stats, not just their tier.

### Mid-term (proposed, grounded in existing mechanics, not yet designed)
- [ ] **Landmarks / points of interest** — *placement shipped, discovery not.* A
      30-structure library (cabins, wells, campsites, watchtowers, mineshaft junctions,
      shrines, sealed vaults, reactor ruins, crystal chambers, plus 10 small props),
      authored from 42 analysed community saves, had been wired into nothing; v1.15.72
      loads and places all 30, and v1.15.78 retuned flatness tolerance so they survive the
      new mountain terrain (3.7 buildings + 8.9 props per 3000px). What remains is making
      them *worth finding* — rewards and a discovery hook — e.g. a rare deep-cave `VIRS`
      outbreak pocket (cured by fire, chest reward gated on infection clearing) or a
      `PSCN`/`NSCN` logic-gate puzzle vault, both built entirely from existing element
      behaviors. See
      [feature-wishlist.md #2](knowledge/feature-wishlist.md#2-landmarks--points-of-interest).
- [ ] **Biome variety expansion** — visual *and* mechanical variety beyond the current
      forest/desert/snow/swamp set, pairing real geological strata bands (granite,
      sandstone, limestone with genuine acid reactivity) with per-biome survival mechanics
      instead of just re-skinned terrain. See
      [feature-wishlist.md #3](knowledge/feature-wishlist.md#3-biome-variety-expansion).
- [x] **Mountains / vertical terrain (v1.15.70)** — shipped as the predicted
      low-frequency surface-height noise pass: a long-wavelength layer (period 1100px)
      hard-thresholded to zero across most of the map, so plains stay plains while 22% of
      columns rise into real ranges. Measured on seed 7, total relief went 61px → 280px
      across 8000 columns with the steepest slope still 2px per column, so peaks stay
      walkable without digging. Topsoil was deepened 20px → 50px in the same bump so a
      hillside can actually be dug into. Applies to newly generated terrain only. See
      [feature-wishlist.md #4](knowledge/feature-wishlist.md#4-mountains--vertical-terrain).
- [ ] **Portal-pipe item logistics network** — placeable `PRTI`/`PRTO` portal pairs (real
      stock teleport-by-channel mechanic) for Terraria-style long-distance item pipes,
      complementing the fluid/gas logistics tier below. See
      [feature-wishlist.md #7](knowledge/feature-wishlist.md#7-portal-pipe-item-logistics-network).
- [ ] **Snow-biome hypothermia + insulated bases** — real cold-drain tick outside
      snow-biome shelter, countered by real insulator material (`AERO`) and a `TEG` that
      passively generates power at a warm/cold boundary. See
      [feature-wishlist.md #8](knowledge/feature-wishlist.md#8-snow-biome-hypothermia--insulated-bases).
- [ ] **Meteor strike events** — rare scheduled falling hot-rock event that craters
      terrain and leaves a rare-ore impact site, giving the world something that can
      *happen* during play rather than only be discovered. See
      [feature-wishlist.md #9](knowledge/feature-wishlist.md#9-meteor-strike-events).
- [ ] **Reactor tier, sealed-base life support, fluid/gas logistics tier** — the next
      three rungs of the industrial-ecosystem tech tree; see the [Vision](#vision) section
      above for the full grounding (each already reuses existing, live-tested element
      physics rather than inventing new ones).
- [ ] More biomes and quest content past the current 14-step starter chain.

### Long-term (real architecture research done, large scope, not started)
- [ ] **Co-op multiplayer** — real architecture research done, not just an ask. This
      class of falling-sand simulation cannot do peer-to-peer lockstep (physics is
      chaotic and iteration-order-dependent — two machines running the "same" step on the
      same data diverge within a few ticks from float rounding and update-order
      differences alone, and exhaustive deterministic-math engineering is fragile and
      expensive). The two real precedents confirm this: **Noita Together** deliberately
      did NOT attempt shared-simulation multiplayer (each player keeps a separate
      world; see [the wiki](https://noita.wiki.gg/wiki/Mod:Noita_Together) /
      [GitHub](https://github.com/Noita-Together/noita-together)), and **Noita Entangled
      Worlds** ([GitHub](https://github.com/IntQuant/noita_entangled_worlds)) only ships
      a proxy-relay plus per-pixel delta sync — i.e. exactly host-authoritative, not
      lockstep. Recommended shape for this codebase: **host-authoritative** — one machine
      runs the real simulation untouched, every other player connects as a thin client
      sending only input (`movePlayer` / `useTool` / `placeAt`, all already exist) and
      receiving back a bounded region per client reusing the existing camera-scroll
      windowing system (the same windowed approach already used by the tile-cache /
      `shiftCam` infrastructure, so no new windowing scheme is invented). V1 scope:
      LAN-only, host + one remote player, no client-side prediction / rollback — accept
      host-latency lag on remote inputs in exchange for a much smaller, ship-able
      surface. Each player is genuinely just a second instance of the existing
      `P`-like state table driven by network input instead of local mouse / keyboard —
      which is the same actor-command shape `companion.lua` already separates
      ("decide what to do" vs "execute the action"), so the actor layer is real,
      existing, reusable infrastructure, not a new one. Not started.
- [ ] **Physics-driven character overhaul + dismemberment** — real technique identified:
      Verlet integration with distance ("stick") constraints, the same method Happy
      Wheels and Source-engine ragdolls use (going back to Thomas Jakobsen's paper for
      Hitman: Codename 47; reference:
      [Tuts+ verlet ragdoll tutorial](https://gamedevelopment.tutsplus.com/tutorials/simulate-tearable-cloth-and-ragdolls-with-simple-verlet-integration--gamedev-519)).
      Body is ~11 point masses (head, chest, pelvis, 2× upper arm, 2× forearm, 2× thigh,
      2× shin); each point stores current and previous position (Verlet needs no explicit
      velocity — it is implicit as `pos − prevPos`); rigid areas get multiple constraints
      per joint so they don't fold, loose areas (elbows, knees) get exactly one. 4–8
      constraint-relaxation iterations per frame looks convincingly rigid; collision
      reuses the same solid-style check the player already uses today, just once per
      point instead of once for the whole player box. **Dismemberment is just a
      conditional constraint break:** each stick gets a `breakForce`, and the simulation
      removes a stick whose current stretched length exceeds its rest length by more
      than `breakForce` for the rest of the ragdoll's life. The two sides then drift
      away under existing Verlet motion — this is "limb tears off" without any
      special-case code path, and decapitation is the neck stick breaking with the same
      mechanism; real `BLD` (blood) particles already in the codebase spawn at the break
      point for free. Recommended V1 cut: ragdoll only activates on death or a heavy hit,
      not full-time movement control — normal walking / running / jumping stays exactly
      as it is today (the current sprite + velocity model already feels responsive, and
      replacing it wholesale is real risk for no clear gain). Respawn resets back to
      normal sprite control. Explicitly out of V1: full-time ragdoll-driven walking, a
      real skeletal / inverse-kinematics rig, organs as separate simulated bodies
      (spawn as particle effects / decals at death instead — cheaper, same visual
      payoff). Not started; awaiting confirmation that "death-only ragdoll" matches the
      intended scope vs. always-on ragdoll movement.
- [ ] **Real biome-varied geology (V2)** — properly distinct layers per biome: granite
      under mountains, sandstone under deserts, limestone / shale variation, a real
      saprolite transition band at the topsoil / bedrock boundary. Each new layer would
      be its own custom element following the same `elements.allocate("RPG", "NAME")`
      pattern as `GRSS` / `BLD`, and every one would need its own
      `Falldown == 0 AND TYPE_SOLID` verification before being trusted as structural
      fill — the `STNE` regression generalized to a real rule. Flagged as the V2 scope,
      not V1, per the design doc.

For the respawn-path-drift saga spanning v1.15.7 → v1.15.10 (one bug class, four
versions, helper extraction pattern established), see the cross-version retrospective
at [releases/v1.15.7-v1.15.10-retrospective.md](releases/v1.15.7-v1.15.10-retrospective.md)
and the individual release pages linked from its summary table.

Full version-by-version history lives in [CHANGELOG.md](CHANGELOG.md). The full, growing
wishlist of proposed systems (including anything added after this roadmap pass) lives in
[knowledge/feature-wishlist.md](knowledge/feature-wishlist.md).

Running from source
===========================================================================
Standard Powder Toy build (Meson + Ninja); see the
[_Powder Toy Development Help_ wiki page](https://powdertoy.co.uk/Wiki/W/Main_Page.html) for
toolchain setup. The RPG layer is pure Lua (`scripts/lua/`,
autorun-compiled from `bridge_src/`) and need no rebuild — only the new elements above
require a native rebuild.

Credit & license
===========================================================================
Built on [The Powder Toy](https://powdertoy.co.uk/) by Stanislaw K Skowronek and the TPT
team — see [powdertoy.co.uk](https://powdertoy.co.uk/) and the
[official forum](https://powdertoy.co.uk/Discussions/Categories/Index.html) for the
original game, online saves, and the wider community. Distributed, like the original,
under the [GNU General Public License v3](LICENSE).
