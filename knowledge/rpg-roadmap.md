# Powder RPG — Roadmap

_Roadmap keeper file. Every item below is traceable to a hub line (`knowledge/rpg-hub.md`) or a git commit
in `D:\powder-toy`. Updated roughly every 3 min while workers are active; last updated 2026-08-26 19:1x
(roadmap keeper restarted per Drew's 18:42 "the roadmap agent needs to be constantly working... the other
agents work off the roadmap" — this is now a driving role, not just a log: see §0 for what's assigned right
now and §8 for the standing loop)._

## 0a. GAME IDENTITY (Drew, 18:58 — pinned north star, supersedes earlier framing where they conflict)

**Verbatim**: "a crazy amount of machines that all work together and all look really really good — that is
what the game is all about. Maybe it is about underground: we need oxygen down there, there is oxygen
outside." Reiterated harder 19:04: "we need reasons to build those deep machines, and there should be
carbon monoxide — I want the game to have all those mechanics." Then 19:08: "underground trains and ways to
navigate the subterranean, all tied into the building system — vehicles would be really cool."

**What this means for prioritization, effective immediately**: the machines pillar is no longer one system
among several — it is the game's core identity. Read together, the three messages describe one coherent
loop: **descend → the air gets worse (real, already shipped: open-air O2 thins with depth to ~40% at 900px,
`19:04`) → build a sealed base to survive → sealing traps hazard gases (CO/CO2/CH4/radiation/heat, shipped
`19:04`) → building the life-support machines to fix that (scrubbers/coolers/fans/O2 gen) is the moment-to-
moment gameplay → those machines must visibly chain together (power→oxygen→water→heat→materials, shared
pipes/ducts/wires) and look good doing it → vehicles (trains/elevators/drills) make going deeper and
supplying a deep base actually navigable.** Every future prioritization call in this doc should ask "does
this serve the descend-and-sustain loop" first.

**Already shipped toward this** (see §2a): depth-based O2 thinning; the hazard-gas registry (`R.gas` =
{co, co2, ch4, rad, heat}) with real per-cause generation (sealed fire→CO, smelting→CO2, swamp/oil→CH4,
uranium/depth>1100px→radiation mitigated by carried lead, depth<900px→geothermal heat); `R.scrubbers`/
`R.coolers` registries (alongside `R.o2Sources`) for machines to plug into; `R.mount`/`R.dismount`/`R.ride`
core hooks + a reserved `vehicles.lua` plugin slot.

**Reassigned per Drew's own routing** (19:04/18:58, restated here as the standing priority order):
1. `@machines` — CO/CO2 scrubber, ventilation fan, air conditioner/cooler, gas detector, lead shielding are
   now **survival requirements, not decoration**, and take priority over generic "wave 2" variety (backlog
   #15 is retargeted around this, see below). Machines must visibly chain (shared pipes/ducts/wires between
   power→O2→water→heat→materials), not stand alone.
2. `@vehicles` — **new worker, new file `scripts/lua/rpg_plugins/vehicles.lua`**, not started yet. Core
   already exposes `R.mount(v)`/`R.dismount()`/`R.ride` and a registered plugin slot. First target: some
   real means of descending/navigating (minecart+rail, elevator shaft, or a drilling vehicle) tied into the
   building system, not a separate minigame.
3. `@world` — deep zones need to reward the trip (already partially true via Tier 5 `DMND`/`TTAN`/`URAN`,
   per `research-progression.md`; re-check against the new hazard-gates once `@progression` retunes).
4. `@progression` — retune the 6-tier plan around **depth + life support** rather than treating oxygen/gas
   as a side stat. `research-progression.md` needs a revision pass; see backlog item 19.

## 0b. Second pillar: energy + ecology/survival (Drew, 19:14) — and the new input-queue file

**Verbatim (19:14)**: "I want the power and electric generation, the whole energy stuff, to be a pretty big
deal and part of the game. Also plants and food and environmental needs and different types of events. Make
sure you're adding all this to the roadmap/ideas/brainstorming — I'm going to fire off a bunch of ideas all
the time and I need a running list of everything I throw out."

Two standing changes this creates:
1. **`knowledge/rpg-drew-ideas.md` is now the permanent, verbatim input queue** — the lead appends the moment
   Drew says something (currently 52 lines, mirrors the hub's "Drew says" section plus a "Standing themes"
   summary). **This roadmap treats it as the primary source of truth for "what has Drew asked for"** — every
   line in it must map to a tracked backlog item with an owner/priority/acceptance-test, checked each pass
   against this doc (cross-referenced below; nothing in it as of 19:20 is untracked — see the confirmation at
   the end of this section).
2. **Energy/power generation is now a headline pillar**, not a subsystem of `@machines`. This doesn't change
   who owns it (`@machines` still owns power), but it does mean power-chain depth/variety should be weighed
   the same as world/items/combat when prioritizing, not treated as "just one more machine category."
   Concretely: keep expanding `R.power.grids` (generation variety, storage, transmission — see backlog #15's
   life-support-first build order, which *is* largely energy infrastructure) and don't let it stall behind
   other asks.

**New workers from this message**:
- **`@survival`** (new, not started) — owns plants, farming, food, cooking, hunger/thirst, temperature
  comfort, sleep, and an environmental event system. Core already shipped the plumbing: `R.need = {food,
  water}` (a real depleting-need system, same shape as `R.o2`) and `R.FOODS`/`R.eat` (a food-item registry +
  eat action). See backlog #21.
- **`@harvest`** (new, not started, from the very next message at 19:20) — "research community Powder Toy
  maps/saves... take design features and bring them into our procedurally generated world, especially the
  little stuff... walking through the map and come across buildings and cool little features." Runs in a
  **separate lab instance** (Drew is playing in the main one) doing offline save analysis, feeding a
  structure library that `@world` places procedurally. See backlog #22.

**Also shipped alongside this batch** (core, no Drew quote attached but visible in the hub's Ownership/Log
context): ctrl-key snapping/line-lock for building (precision placement aid, matches the standing "Terraria-
grade feel: intuitive controls, snapping/building aids" theme in `rpg-drew-ideas.md`'s "Standing themes"
section) — see §2a.

**Standing themes** (from `rpg-drew-ideas.md`'s own summary, worth keeping visible every pass since they're
the recurring lens Drew applies to everything): things must look like what they are; real Powder Toy physics
over scripted effects; Terraria-grade intuitive controls; depth-and-survival (air outside, life support
below); energy/automation as central; constant open communication and a living roadmap.

## 0c. STANDING RULES (Drew, 20:12 — process rules, apply to every worker including this role, until further notice)

Drew hit a real stack-overflow crash (`pluginErr`) and was direct about it: "you should be testing changes
on the OTHER game and then pushing them to the one I'm playing without messing me up so I can have fun."
Two rules now in force, both must be followed by every plugin worker:

1. **IDEMPOTENT WRAPPERS.** Cause of the crash: plugins wrapping a core function (`R.eat`, `R.spawnPlayer`,
   `R.save`, `R.grantItem`, ...) re-wrap it on every hot reload, so the call chain grows one layer per reload
   until Lua's call stack overflows. Every wrapper must keep the pristine reference on first load and always
   wrap *that*, e.g. `U.origEat = U.origEat or R.eat; R.eat = function(...) ... return U.origEat(...) end` —
   or use a tagged hook instead of wrapping at all. **Confirmed offender: `@survival`** (wraps `R.eat` and
   `R.spawnPlayer`, per its own 19:52 log). **Must audit their own file for this pattern**: `@machines`,
   `@ui`, `@items` (any plugin that wraps a core function, not just these three by name) — each should
   confirm in the hub once checked/fixed, even if the answer is "clean, no wrapping found."
2. ~~LAB-FIRST~~ — **SUPERSEDED (21:44, see rule 4 below).** Lab-instance testing was itself only a
   half-measure; rule 4 replaces it with no worker-side testing at all.

3. **NO TWO-WAY SAVE REFERENCES (added 20:35, second independent stack-overflow cause).** `@vehicles`
   found that `save.lua`'s generic `R.PLUGIN_SAVE_KEYS` dump has no cycle detection — a plugin storing a
   live back-reference between two objects in its saved state (e.g. a cargo wagon pointing directly at its
   locomotive table) will stack-overflow every `R.save()` call. Store plain flags/ids in saved state, never
   a direct object reference to another live object. `@save` should add a depth/visited-set guard to the
   dump walk so this fails safely for everyone, not just the plugins that remember the rule — see backlog #27.

4. **NO TESTING BY WORKERS (Drew, 21:44 — supersedes rule 2/LAB-FIRST, now the standing rule for how anyone
   verifies anything).** Drew, verbatim: "I don't want any of the agents to do any testing. We're going to
   do all that — I'll test it all out. When we're ready you can lay out all the machines and I can test
   everything myself, and then we can make changes." Effective immediately: **no live testing, no
   verification loops, no screenshot loops, no test structures, in his game OR the lab instance.** A worker
   builds from known-good patterns, confirms only that the plugin **loads clean** (`pluginStatus` ok, no
   `pluginErr`) and that recipes/panels/items are correctly **registered** (a data/table read-back, not a
   live-fired reaction), then ships and posts **one short hub line** saying what shipped — no multi-paragraph
   verification writeups. The lab instance still exists but only for a syntax/load check, not behavioral
   testing. Drew tests everything himself in his own session and reports back; `@lead` maintains an
   inspection manifest for him at `knowledge/machine-manifest.html` (published as an artifact) so he can see
   what's ready to try without hunting through the hub.
   **Notified this pass** (21:4x): `@machines`, `@machines2`, `@companion`, `@world` (mid-rebuild), `@items`,
   `@ui`, `@guide`, `@save`, `@vehicles`, `@survival`, and the new `@engine` architect role (see backlog #29).

**Recovery already done** (20:12 incident): lead reloaded core once then every plugin once; Drew's game was
clean, 37fps. **This roadmap's job under these rules**: track wrapper-audit/no-two-way-reference compliance
(backlog #25/#27) and, from 21:44 on, call out any worker whose hub post describes live-firing a reaction,
running a verification loop, or leaving test structures anywhere — that pattern is now against the rules
everywhere, not just in Drew's session.

## 0. Next 5 things Drew should see (ready to check right now)

1. **Start a fresh seed / New World.** Everything world-side only applies to newly generated terrain:
   worm-tunnel+cheese-cavern caves (no more slits), depth-band strata, big choppable trees that topple with
   a "TIMBER!" crash, soft dithered biome borders (no more hard line), and per-biome purpose (desert
   ruins/oases + midday heat, snow crystal caves + hypothermia, swamp oil/gas + poison water, forest
   beehive gold). Old dug-out terrain will look unchanged — this needs a new seed to judge.
2. **Look at the machines.** Full visual overhaul shipped (18:30, 6110188) — turbine now has a spinning
   rotor/blade housing, boiler has a real firebox+chimney+sight-glass, pump/crusher/battery/solar/water-wheel
   all read as what they are, plus a real power grid (wattage, storage, brownouts) and ~10 new machine kinds
   (crusher, autocrafter, turret, drill, capacitor, battery, solar, water wheel, hand crank, electric
   furnace). Build a boiler→turbine→conductor chain and watch the blades actually spin.
3. **Fire the Laser Rifle or Plasma Torch at solid rock.** Per the 17:53/18:05 ask, it no longer deletes
   blocks — it deposits real sustained heat, ice flashes to vapor almost instantly, granite/titanium melt
   slowly and correctly via their real melting points, and hard non-melting materials (dirt/coal/diamond)
   fall back to a 3-hit destroy. Aim/tracers were also fixed (17:22/17:34) — bullets now visibly leave the
   drawn barrel and shotgun pellets reach much further.
4. **Look at fire, steam, and lava.** Render pipeline switched to TPT's real BASC+FIRE+GLOW+BLUR+EFFE mode
   (17:50 ask) — these now render as glowing/hazy effects instead of flat particles, toggle in the Esc menu.
5. **Try sealing a room and breathing in it.** The oxygen model was reworked (18:40 ask, `ae859fe`) from a
   simple drain into a real concentration model: open sky = 100%, a sealed room depletes as you breathe,
   water = 0%, and real `OXYG` enrichment above 60% now triggers an "OXYGEN RICH — FIRE HAZARD" warning
   (TPT's own fire physics does the rest — don't light a torch in an O2-rich room).

**Unowned / needs a decision from Drew or a roadmap call — see §5 for the full list:**
- Nobody has started "way more machines" (18:40, ~35 machines wave 2) or the "way more items" round 3 yet —
  both are open standing asks with no fresh spec, next in line for `@machines`/`@items` once they resurface.
- Two different oxygen mechanisms now coexist (items' hand-rolled tank/helmet/mask particle-killing from
  16:35, and core's new `R.o2Sources`/`R.o2conc` registration model from 18:40) — flagged to `@items`/`@lead`
  in §4 backlog item 13, needs a decision on which one the accessories should register with going forward.
- `@brainstorm` (new role, Drew 18:48) — owns `knowledge/rpg-brainstorm.md`, feeds ranked physics-grounded
  weapon/tool/magic concepts to `@roadmap`→`@items`. File does not exist yet as of this pass — first output
  not yet posted to the hub. See §3 for its assignment.

**Team protocol now in force (Drew 18:51)** — everyone (including this roadmap role) must: (1) read the hub
IN FULL before every major step, (2) post a line after every step, addressed with `@who` to anyone whose
plugin the change touches, (3) answer `@`-mentions aimed at them in the next post, (4) work off
`rpg-roadmap.md`'s assignments rather than self-selecting tasks. This roadmap keeper's job under that
protocol: call out silence/ignored @-mentions each cycle (see §3) and keep the assignment list in §3/§4
current so nobody has to re-derive "what's next" themselves.

## 1. Vision (Drew, in his words)

- "explorative physics/engineering game" — Terraria + RimWorld + Factorio-style automation, built on real
  Powder Toy mechanics (real fire, coal, water, steam) (hub, standing)
- "natural-looking underground"; "special tiered items/chests"; "intuitive Terraria-like controls and UI"
  (hub, standing)
- Hard rules: never a laser-like pick; don't auto-switch hotbar items; optional snap grid; zoom = detailed
  placing with own inventory (hub, standing)
- "still super displeased with how the subterranean area looks — take detailed notes from Terraria,
  Minecraft, other procedural generators" (13:06) — underground worldgen is not meeting the bar, research
  required before more building
- "Items are a big deal: be creative, lots of unique options; guns with destructive shooting; capitalize
  on the physics" (13:06) — items/weapons is now a dedicated, high-priority track, not an afterthought of
  the crafting system
- "give yourself five sonnet workers to massively improve everything" (hub, 12:55)
- "everyone constantly communicating in the hub; I'll be mentioning stuff as everybody's working —
  constantly keep a note of the stuff I'm adding on" (hub, 12:57)
- "add a specialist that keeps track of the entire roadmap and what's happening" (hub, 12:57 — this role)
- Prior version verdicts that shaped the whole architecture (memory/powder-rpg.md): "looks like crap…
  laggy… hard to navigate" (v1); "legs get stuck" (STKM, v2); "can't dig down… can't equip tools… want a
  GUI" (v2/v3); "wants to go down into the earth, continuous world" (v3→v4); "gets caught on microscopic
  particles" (pick corridors, pre-smart-cursor)

## 2. What exists now (v4 live, `scripts/lua/rpg.lua`, 883 lines + plugin loader)

**Core / engine**
- Plugin hook API + loader: `R.hooks.{tick,draw,drawHUD,key,mousedown,mouseup,place,mine,craft,gen}`,
  `R.PLUGINS = {world, enemies, machines, save, ui}`, hot-reload via `R.reloadPlugin(name)` (ae38e77)
- Quest reward crash fixed (be89019)

**World generation**
- Continuous scrolling world (no chunk swaps), deep world gen, off-screen tile store `R.tiles`, menu, zoom
  passthrough (c1f2ecd)
- Natural caves, per-particle chip mining, sky + real rain weather, chests + accessories (8d9140e)
- Rounder caves, per-particle chip mining refined (86b2342)
- Chest cell constant scope bug fixed (f9bdbaf)
- Biomes stubbed in code (`biomeAt`: forest/desert/snow/swamp per world column) but not yet differentiated
  by material — flagged as world-worker P1 below

**Player & controls**
- Sprite player with own kinematics (gravity 0.24, run 1.6 px/f, jump ≈28px, 4px step-up, coyote time),
  not native STKM (6c8d889, memory/powder-rpg.md) — see Decisions §6
- Fall damage (>15m) + screen shake on landing (2c60862, 14:14, lead)
- Detailed player sprite with walk cycle and gear (8f836b8, lead)
- Friendly element names: `R.NAMES`/`R.nice(el)` applied across hotbar/palette/hints/craft lists
  (228de09, lead) — see standing convention in Decisions §6
- Accessories: single reconciled model (22bf8ab, lead, superseding 1a5dade's first pass) —
  `R.acc[k]` = owned (set once, never removed), `R.accOwned` mirrors it for plugins, `R.accOff[k]` =
  explicitly switched off, `R.accOn(k)` = `R.acc[k] and not R.accOff[k]` (the actual live-effect
  check used everywhere in core), `R.equipAcc(k, on)` toggles `accOff`. `save.lua` persists both
  `accOwned` (73016c5) and `accOff` (eb30b38).
- Fall damage refined: requires a fast landing speed, hovering (e.g. cloud accessory) avoids it
  (b1e0867, d23cbdd, lead)
- Smooth camera follow, zoom lock passthrough (93afa96)
- Precise dig/place inside the TPT zoom window + inventory palette (a25ed9f)
- Build mode inside the zoom window (551c1ad)
- BCOL placement, furnace slow-burn, hotbar auto-switch disabled, snap grid with preview (43eef03)

**Mining & tools**
- Smart cursor (T toggle), wide pick corridor, pick tiers (5016a51)
- Per-particle chip mining (86b2342, 8d9140e)

**Progression**
- Stations (workbench/furnace/anvil) as real placed structures; smelting requires real fire; quests;
  described craft menu; `GRSS` grass element; real torches (5a3716d)
- Coal smoulders slowly: stock `Flammable` reset to 0, long-life furnace bed (640258c)

**Weather / day-night**
- Real rain, sky (8d9140e); day counter + night `FIGH` spawns (enemies off by default, `R.enemies=false`)

**Enemies (plugin, committed 132d0c7)**
- Sprite slimes/zombies/bats + Slime King boss, own gravity/collision, contact damage+knockback, HP bars,
  floating damage numbers, sword combat, all live-tested end to end on Drew's running session (see §3)

**UI / HUD**
- HP/day/deaths/hotbar/message panel, minimap, craft menu, Esc menu listing every control (original,
  pre-plugin-split)
- Full inventory/UI rebuild (plugin, **committed 034ab01**) — grid `R.invSlots` inventory with
  drag+click-click, right-click half/one-stack, shift-click/hover-hotkey to hotbar, sort, search, trash
  slot; two-row Equipment/Bag drag-and-drop for accessories using `R.acc`/`R.accOn`/`R.equipAcc`; recipe
  book with x1/x5 crafting; quest log (`J`), controls card (`C`)

**Core polish (lead, misc, not all individually itemised above)**
- Terraria-style cursor: single-block highlight, reach circle and grid-box lattice removed (616bc77,
  0a0516d)
- Sandbox mode (16:00 ask, **DONE**) — Esc-menu toggle, stocks/tops up everything, all accessories, no
  damage, free crafting, fires `R.hooks.sandbox` for plugins to unlock their own content — see backlog
  item 11

**Plugin split — five of six original plugins shipped and git-committed**: `enemies.lua`
(132d0c7), `machines.lua` (6f4407b), `save.lua` (a8f17e1), `ui.lua` (034ab01), `items.lua`
(9272d44/0a7236b). `world.lua` is functionally live (loaded and working, per §3) but **not yet
git-committed** — held back pending the final clutter-noise fix (P0 #3). Two more plugins added
mid-session and in progress: `guide.lua` (ONI-style database, not started) and the non-plugin
`powder_ext/rpg_tools.py` MCP worker (in progress). See §3 for live per-worker status.

## 2a. Shipped since the 16:26 pass (new — folded in from the hub through 18:42)

**World / terrain**
- Trees now topple and crash when felled instead of vanishing, with a "TIMBER!" flash (16:24 ask,
  `881ef1d`) — core's `R.fellFrom`/`checkFell`, `@world` only had to keep generating big trees with connected
  trunks.
- Soft, dithered biome borders (16:48 ask) — core added `R.biomeMix`/domain-warped borders; `@world` made
  every downstream system (soil, dune/pool size, ground-cover density, tree/cactus density) blend across the
  ~90px band via `blendAt`/`biomeWeight` instead of hard-switching (`99ea1e4`, verified with before/after
  renders in `knowledge/previews/`).
- Biome purpose (16:52 ask, `7c5d4f8`) — every non-home biome now has one real hazard + one real resource
  pull using only existing catalog materials (no invented items): desert = brick-heavy strata + up to 65%
  ruin/chest odds + oases + midday-sun HP drain; snow = boosted `QRTZ` crystal caves + hypothermia (canceled
  near real heat); swamp = boosted `CLST` clay + real `OIL`/`GAS` pockets + poisonous `SLTW`/`CAUS` water;
  forest (home) = ~12% wild-beehive `GOLD` cache, stays hazard-free. Depth bands now self-announce once via
  `R.say()` on crossing (Coal Seams → Iron Belt → … → Bedrock). Exposes `R.biomeInfo`/`R.depthInfo` for
  `@guide`.

**Player / controls / core polish**
- Grapple simplified (16:32 ask) — middle-click or double-tap-jump-in-air grapples toward the cursor, `G`
  still works too.
- TPT's own element-selection menus hidden while playing, hotbar fully redesigned — centred tray, drawn tool
  glyphs, 16px swatches with count badges (18:20 ask, `69a8238`); Esc menu rebuilt to fit `R.SAFE` with
  wrapped two-column help + status (16:40 ask, `1870ed0`).
- `tpt.hud(0)` hides TPT's own fps/pressure readout; `R.SAFE = {4,16,604,344}` is now the one panel-safe-area
  constant every plugin panel must respect (16:40 ask).
- Real TPT render pipeline (BASC+FIRE+GLOW+BLUR+EFFE, `DISPLAY_EFFE`) — fire/steam/heat now render as actual
  glowing effects, not flat particles; togglable in the Esc menu, restored on stop (17:50 ask, `8c4137b`).
- Brittle terrain (`R.crumble`): isolated small clumps left behind by acid/laser/explosions collapse into
  real falling rubble instead of leaving micro-specks the player snags on (17:58 ask, `29d8b55`). **Then
  dialed back same-day** (18:10, "world is falling apart, too much") — removed the periodic every-24-frame
  sweep so it only ever fires at actual damage points, fixed the flood-fill to follow the *whole* connected
  mass, tightened the clump-size limit 7→5 (`2a60b77`). Standing rule now: `@items` calls `R.crumble` only at
  its own weapons' impact points, never as an ambient sweep.
- Fast physics mode (measured 18:28: air pressure/velocity sim was costing ~25% of frame time) — `airMode 3`
  + water-equalisation off, default ON, Esc-menu toggle. **Standing rule**: `@machines` must call
  `R.setFast(false)` while a steam/pressure-dependent machine actually needs the real air sim, then restore
  it after.
- `R.grantItem(el)` (18:30 ask) — in sandbox, clicking a guide/database entry grants an unlimited stack +
  hotbar slot; otherwise only if already owned. `@guide` wired this into its material pages' TAKE button.
- Shift+wheel resizes the placed-block brush size (core, `c7bde6a`); modifier keys (shift/ctrl/alt) no
  longer get misread as hotbar digit presses (`133be06`) — both landed 18:46, no plugin action needed.
- Oxygen reworked into a real concentration model (18:40 ask, `ae859fe`): `R.o2` = breathability (open sky
  100%, sealed rooms deplete as you actually breathe, water 0%), `R.o2conc` = measured real `OXYG`
  enrichment, `R.o2Sources` = a list plugins register `{x,y,rate,range}` emitters into, damage below 12%,
  "OXYGEN RICH — FIRE HAZARD" warning above 60% (TPT's own fire physics does the rest). **See §4 backlog
  item 13 — this may now overlap/conflict with items.lua's separately-built oxygen tank/helmet/mask
  mechanism (16:35).**
- Open-air oxygen now thins with depth (18:58 game-identity ask) — 100% at the surface down to ~40% at
  ~900px, so a deep sealed base *requires* interlocking life support rather than being optional. See §0a.
- Hazard-gas atmosphere system (19:04 ask): `R.gas = {co, co2, ch4, rad, heat}` — fire in a sealed low-air
  room produces silent carbon monoxide (damages without dropping the O2 reading, the real CO-poisoning
  danger), smelting/furnaces produce CO2, swamp/oil pockets produce explosive methane, uranium veins and
  depth >1100px produce radiation (carried lead mitigates it), and geothermal heat rises below ~900px. New
  registries alongside `R.o2Sources`: `R.scrubbers` and `R.coolers` (`{x,y,rate,range}`) for machines to
  plug into. This is the direct "reason to build deep machines" backlog #15 was retargeted around — see §0a.
- Vehicle mounting hooks (19:08 ask): `R.mount(v)`/`R.dismount()`/`R.ride` let a plugin drive the player, and
  a `vehicles.lua` plugin slot is registered — no vehicle content shipped yet, this is core plumbing only
  for the new `@vehicles` worker (backlog #20).
- Survival needs core (`R.need = {food, water}`, `R.FOODS`/`R.eat`) and vehicle riding are now live per the
  19:14 sync — see the new `@survival` row in §3z and backlog #21/#22 for the full picture.

**UI / guide**
- Guide (`guide.lua`) addressed Drew's 16:40 feedback in full: dropped every "Oxygen Not Included" mention,
  fits `R.SAFE`, hover highlighting, an always-visible BACK button + breadcrumb, PgUp/PgDn paging, drag
  scrollbar + click-to-seek, real mouse-wheel scrolling once `@lead` added `R.hooks.wheel` (17:14).
- Guide reachable from the bag menu (17:17 ask): `ui.lua` added a GUIDE(L) tab button (`305e854`);
  `guide.lua` exposed a clean public API, `R.openGuide(entryOrNil)` / `R.closeGuide()`, so any plugin can
  open a specific category or entry without touching guide.lua internals (`1f35636`).
- **Known small gap, unowned**: `@ui` flagged (15:08 log) that opening guide via `L` while the bag panel is
  open doesn't close the bag (only the GUIDE button→bag direction is guarded), so both can render at once.
  Low priority, needs a one-line mutual-exclusion fix from either `@ui` or `@guide` — see §4 backlog.

**Items / weapons**
- Aim + visibility + range fixes (17:22/17:34 asks, `0e79631`): every weapon's muzzle and the held-sprite
  now share one `handAnchor()` point, so shots visibly leave the drawn barrel; every tracked projectile gets
  a drawn tracer (fading 3-segment trail + bright core dot) so bullets read against any terrain; shotgun
  pellets sped up to 11px/frame with an explicit 220-frame lifetime so they actually reach targets.
- Laser Rifle / Plasma Torch now melt terrain instead of deleting it (17:53/18:05 ask, part of `0e79631`):
  stop at the first solid, apply sustained real heat every tick via core's new `R.addHeat`, rate scaled by
  the material's real hardness so ice/sand cook fast and titanium/diamond slow; materials with a real
  `HighTemperature` transition melt via TPT's own physics, non-melting materials (dirt/coal/diamond) fall
  back to a 3-hit destroy. White-hot glow + sparks/steam drawn at the impact point.
- Rail gun cleaned up to a pure hitscan (no more decorative leftover slug trail per the 18:02 ask).
- **Open verification gaps, still not closed out** (see §4): granite/titanium laser-melt confirmed via
  `elem.property` readback but never burned live start-to-finish in a real session (18:10 items log);
  Harpoon/Rail-Gun pierce-and-pull still never exercised against a real live enemy despite `@items`
  repeatedly asking `@enemies` for a joint test since 13:45.

**Machines**
- Full visual overhaul + a real power grid shipped together (17:38 ask, `6110188`) — every kind above is a
  recognisable particle-built shape (see `knowledge/rpg-ui-atlas.md`'s Machines table for exact geometry),
  animated overlays (spinning turbine/reactor/water-wheel blades scaled to real measured output, boiler
  flame-flicker + steam puffs, gauges), plus `R.power.grids` (real flood-fill wire network every 15 frames,
  wattage read from real measurements — steam hits, TRBN tmp-delta, real water speed, sun angle, TEG/reactor
  temp), storage (battery/capacitor), and `R.tech` milestone gating (10W→efurnace+battery, 100W→crusher/
  autocrafter/capacitor/turret/drill/reactor-kit, reactor-online→heavy turret). ~13 new machine kinds shipped
  in this same commit (crusher, autocrafter, turret/turret-mk2, drill, capacitor, battery, solar, water
  wheel, hand crank, electric furnace) plus 5 previously-undefinable base materials (ZIRC/GRPH/NAK/LEAD/CNCR)
  needed to actually build the reactor.
- **Open items** (see §4): rotation-under-real-steam-load never confirmed live (graphics calls only fire
  inside a real draw event, couldn't be unit-tested); a `machines.lua:886` error ("restricted to graphics
  events") was seen in `@items`' logs, not yet triaged by `@machines`; inert test-machine debris left at
  several off-screen world coordinates (18:30 log has the exact list) — cosmetic only, needs a cleanup pass
  whenever convenient.

**Progression / research**
- `knowledge/research-progression.md` written (17:05, per the 16:52 "research natural game progression" +
  "biomes need purpose" double ask) — 6-tier plan (Wood→Iron→Biome Trip→Automation→Deep Zone→Reactor)
  grounded in Terraria/Minecraft/Factorio/Subnautica/Valheim/RimWorld progression principles. Reconciled
  17:48 against `@world`'s actual biome-purpose ship (real materials, not the doc's originally-proposed
  fictional ones). Two quests (`wifi`, `biometrip`) already added to core `R.QUESTS` by `@lead` (17:44,
  `09b6093`); five more (`automate`/`lead`/`uranium`/`diamondpick`/`reactor`) are written out verbatim in the
  doc §4 waiting on fields that now exist (`m.kind`, lowercase per `@machines`' 17:52 note; `m.sparkedEver`;
  the LEAD/etc. recipes machines.lua already shipped) — **ready for `@lead` to add now, see §4 new-P0-2**.

## 3. In progress (per worker, from hub log)

### 3z. Current status + assignment (as of 18:5x — read this first, table below is history for traceability)

Team protocol is now active (Drew 18:51, see §0) — this is the "what to do next" list everyone should be
working off. **Silence check this pass**: `@enemies` hasn't posted since 13:25 despite `@items` asking
repeatedly (13:45, 15:34, 18:10) for a joint damage/pierce/pull test — please respond. `@save` hasn't posted
since 13:34; its P1 (below) has been sitting unpicked-up for a while. `@mcp` hasn't posted since 14:08 (done,
but should confirm `rpg_search` also indexes the new `rpg-brainstorm.md` once that file exists). `@ideas`
hasn't posted since 15:52 — fine if genuinely idle, but ping the hub either way per the protocol.

| worker | current state | **assigned next** |
|---|---|---|
| `@world` | Biome purpose (7c5d4f8) + soft borders (99ea1e4) shipped and committed. No open ask right now. | Pick from backlog: differentiate remaining biome soil textures further, or start on idea-bank #3/#4 (structural cave-ins, flash-flood caverns) which are still unimplemented despite being greenlit 13:52. Low urgency — nothing burning. |
| `@enemies` | **Silent since 13:25.** `R.damageEnemiesAt`/`R.enemyList` API shipped and stable; nothing since. | **Do the joint test `@items` has been asking for since 13:45**: fire Harpoon/Rail Gun/every weapon at a real live enemy and confirm pierce/pull/knockback/damage-numbers all fire correctly. Then pick up idea-bank #10 (virus-outbreak biome) or terrain-aware enemy variants — both unclaimed P2/backlog. |
| `@machines` | Visual overhaul + power grid + reactor materials shipped (6110188). Two open loose ends (rotation-under-load unverified, `machines.lua:886` graphics-event error). | Triage the `machines.lua:886` error `@items` flagged (18:02 log). Then start Drew's 18:40 "way more machines wave 2" (~35 more: life support/processing/power/logistics/utility) — no spec exists yet, so post a short plan to the hub before building. |
| `@save` | **Silent since 13:34.** Save/load shipped and stable (a8f17e1). | Confirm `newworld` hook resets save-relevant state cleanly (P1 below); verify `R.o2Sources`/`R.o2conc` (new 18:40 core fields) round-trip through the generic `R.PLUGIN_SAVE_KEYS` dump without any save.lua change needed — just confirm and post. |
| `@ui` | Inventory rebuild (034ab01), hotbar/atlas geometry updates all shipped and current. | Fix the bag/guide mutual-exclusion gap it flagged itself (15:08 log, backlog #14) — one-line guard so `L` closes the bag panel same as the GUIDE button closes it in reverse. |
| `@items` | 30 items/weapons total across 3 rounds, aim/tracer/laser-melt fixes all shipped (0e79631). Waiting on `@enemies` for a joint test. | `@brainstorm` is live (backlog #16) with a ranked top-15 — pick 1-2 top concepts to build (Gauss Coilgun/Tesla Arc Rifle suggested first). Until then: verify the granite/titanium laser-melt live end-to-end (18:10's one open gap), and weigh in on backlog #13 (which O2 mechanism accessories should use). |
| `@guide` | ONI-wording removed, R.SAFE-compliant, scroll/wheel/paging, E-menu button, public open/close API — all shipped and current. | Nothing urgent assigned; could pick up the bag/guide mutual-exclusion fix jointly with `@ui` (#14), or start wiring `R.biomeInfo`/`R.depthInfo` (already exposed by `@world`) in place of guide's static BIOME mirror. |
| `@mcp` | 7 `rpg_*` tools shipped and self-tested (554a877). Silent since 14:08 (this is fine — done). | No action needed; ping the hub once, confirming `rpg_search` covers `rpg-ideas.md`/`rpg-brainstorm.md`/`build-lessons.jsonl` per the earlier ask. |
| `@progression` | `research-progression.md` complete and reconciled with real shipped biome-purpose work (17:48). | Its 5 remaining quest specs (`automate`/`lead`/`uranium`/`diamondpick`/`reactor`) are ready for `@lead` to add — see backlog #12. No further progression-worker action needed unless Drew raises a new progression/difficulty comment. |
| `@ideas` | 3 rounds posted (Top 10, Round 2, Round 3), mostly validated/absorbed into shipped work. Quiet since 15:52. | Idea-bank picks #3/#4 (cave-ins, flash floods) and #1/#2 (portal network, fission reactor UI/quest wrapper) are still unbuilt and greenlit — worth a check-in post even if just "still waiting on @world/@machines to pick these up." |
| `@brainstorm` | **Live** — 2 rounds posted, 61+ concepts, top-15 ranked in `rpg-brainstorm.md`. | Keep going per Drew's live comments (19:14 events/ecology ask already answered in Round 2); no blocker. |
| `@survival` | **New (19:14), not started.** File TBD. Core plumbing (`R.need`, `R.FOODS`/`R.eat`) already shipped. | First ship: one farmable plant + a couple foods + hunger/thirst HUD hookup with `@ui`. See backlog #21. |
| `@harvest` | **New (19:20), not started.** Separate lab instance, offline save research. | Start pulling community-save structures into a library `@world` can place. See backlog #22. |
| `@lead` | Extremely active this whole session — see §2a for the full list of core additions since 16:26. | Add the 5 ready progression quests (backlog #12); otherwise keep responding to core-API asks in the hub as they come in (this is working well, no change needed). |

### 3y. Detailed worker history (kept for traceability — see 3z above for current status)

| worker | owns | status as of 13:06 |
|---|---|---|
| world | `rpg_plugins/world.lua` | **13:22**: research done (`knowledge/research-worldgen-2026-08-26.md`)
  — root cause of the "slitty" caves found: tunnels were a level-set crossing of one noise field, which
  mathematically pinches to zero width wherever the gradient is steep, with no domain warp so cracks ran
  parallel to the noise grid axes. Now implementing worm-tunnel + cheese-cavern caves (hard radius floor,
  domain-warped), depth-band strata computed before the carve pass, zone+detail two-tap ore/crystal veins,
  surface cave mouths — writing `world.lua` now. |
| enemies | `rpg_plugins/enemies.lua` | **COMMITTED 132d0c7 (13:25)** — sprite slimes (hop, day+night), zombies (walk, night+surface), cave bats (fly, underground), a Slime King boss (spawns after a night with `R.enemies` on, drops a rare accessory). Own gravity/collision via `R.solidW`; contact damage+knockback on the player; HP bars; floating damage numbers. **Live-tested end to end on Drew's running session** (reload -> `pluginStatus` ok, no errors; damage/kill/drop/cull/knockback/perf all verified with real particle reads, then cleaned up with HP/state restored — no `clearSim`/`loadSave`, matches the run-it-for-real verification standard). Sword combat lives here for now (`R.hooks.mousedown/tick`, `R.TOOLS.sword`, skips swinging while `R.invOpen or R.menuOpen`); **agreed hand-off**: `@enemies` will move the sword *input* hook into `items.lua` once `@items` is ready to take it (ping in hub), keeping `R.damageEnemiesAt`/`R.enemyList` in enemies.lua as the one damage-application API — resolves the 13:28 ownership flag. **Resolved (14:20, `@ui`)**: `R.uiPanelOpen` wired up (dffd36b) — true whenever bag/quest/controls is open, false otherwise, live-verified both directions; `@enemies` can add it to the sword-suppression check alongside `R.invOpen`/`R.menuOpen`, not confirmed yet whether they have. |
| machines | `rpg_plugins/machines.lua` | **COMMITTED 6f4407b (13:41), DONE** — 8 kits (BOILER,
  TURBINE, WIRECOIL, LAMPKIT, DOORKIT, PUMPKIT, CONVEYOR, CRATE) added to `R.RECIPES`/`R.ITEMS`, tracked in
  `R.machines` with core-mined cleanup. **Live-tested** via direct hook invocation on the shared session:
  boiler pixel-verified after fixing two real vent-breach bugs found during testing (a 1-column gap in a
  2px wall does not vent; a vent below the waterline just leaks liquid under hydrostatic pressure, not
  steam); turbine `WTRV`→`WATR`+`SPRK` confirmed deterministic; door/pump/conveyor/crate all confirmed.
  Caught and self-corrected a test-harness bug mid-run (leaving `R.cratePanel` open during scripted
  testing briefly hijacked the live player's real mouse clicks — immediately reverted via `R.give`; real
  players can't hit this since the panel only opens on their own right-click). Known limitation: coal
  ignition needs sustained torching since this session's `COAL` has `Flammable=0` + no `HighTemperature`
  transition (shared realism-patch behaviour, same limit the base furnace already has, not
  boiler-specific). Adopted the `R.nice()` naming convention and `R.PLUGIN_SAVE_KEYS` save convention
  (aaaca34). |
| save | `rpg_plugins/save.lua` | **COMMITTED a8f17e1 (13:34), DONE** — full save/load: `R.save` (K key,
  menu, autosave ~every 18000 frames w/ rotating `.bak1-3`) writes `knowledge/rpg-save.json` (whole world —
  every `R.tiles` rec + on-screen particles, RLE-encoded per tile row + sparse temp/ctype/tmp/life
  exceptions — plus player/cam/inventory/hotbar/tools/acc/stats/quest/stations/torches/opened-chests/
  weather). `R.load(path, confirmed)` added — `confirmed=true` (only set by `python scripts/rpg.py load`)
  gates any `sim.clearSim`/`R.tiles`/player mutation; otherwise a safe parse-only dry run. **Live-verified**:
  an 8x8 sky-region self-test (`R.saveSelfTest()`) round-tripped with 0 mismatches; a real save was
  2.1MB/211 tiles/0.36s and parsed back consistently from both Lua and Python. This closes the P1 gap in
  design doc §1.4 (old `R.save()` was write-only, nothing ever read it back). Established a convention:
  any plugin with persistent state pushes its field name onto `R.PLUGIN_SAVE_KEYS`, and save.lua dumps/
  restores `R.<key>` verbatim — must be plain data, not raw particle ids (die on load's `clearSim`). |
| ui | `rpg_plugins/ui.lua` | **13:26**: starting — quest log, tooltips, recipe book, onboarding tips, HUD
  polish. Claims `j` (quest log panel) and `c` (controls card); takes over `e` entirely (own richer
  bag/craft panel, `R.invOpen` stays false permanently — verified against `rpg.lua`'s core `onKeyDown`:
  the plugin `R.hooks.key` chain runs *before* core's own switch statement and a truthy return
  short-circuits it, so this cleanly pre-empts core's `e`→`R.invOpen` toggle rather than conflicting with
  it). Checked against core key list (`e/h/k/m/n/r/f1/x/g/b/t/[/]/digits/z`) — `j`/`c` are unclaimed,
  confirmed no collision. |
| items | `rpg_plugins/items.lua` (**new worker, added 13:06**) | **COMMITTED 9272d44 + 0a7236b, DONE**
  — 12 weapons/gadgets in `R.ITEMS`/`R.RECIPES` (craftable at anvil/workbench/furnace, hotbar 6-0, hold
  LMB to fire): **Musket** (real ballistic slug, craters + damages via `R.damageEnemiesAt`, recoil),
  **Shotgun** (6-pellet spread), **Grenade Launcher** (a real stock `BOMB` thrown with velocity — gravity
  arc + TPT's own explosion physics, zero custom explosion code), **Lightning Rod Gun** (hitscan + real
  `LIGH` visual), **Teleport Wand** (blinks player along the aim ray, `PHOT` flash both ends), **Flame-
  thrower/Water Cannon/Acid Sprayer/Freeze Ray** (continuous real `FIRE`/`WATR`/`ACID`/`LN2` streams),
  **Laser Rifle** (continuous `PHOT` beam that melts tier<=4 blocks — real tunnel-boring), **Power Drill**
  (fast auto-mine reusing core's `MINEABLE`/`HARD`, not a second mining system), **Jetpack** (real
  `FIRE`+`GAS` exhaust). Held weapon sprites (aimed, recoil, muzzle flash, idle bob) drawn in `drawHUD`
  (only layer left on top of the arm). Drew (15:08): jetpack moved off LMB to hold-W/Space-while-airborne
  (gated so it doesn't stack onto the jump impulse; sets `R.P.apex` each thrust tick to cooperate with
  fall damage) — **DONE**, code-reviewed but not live-fall-tested. **Bug found + fixed live**: continuous
  weapons originally spawned their stream ~5px from the player's own head, which is inside the hurtbox for
  steep upward aim — firing straight up cooked the wielder; fixed with a `MUZZLE=12` radial offset,
  verified safe at every aim angle, HP held at 100 across a 0.9s test burst post-fix. **Open integration
  test**: `R.damageEnemiesAt` is called from every weapon but hasn't been exercised against a live enemy
  yet (enemies.lua wasn't loaded during this test pass) — `@items`/`@enemies` should do a joint test.
  Optional 13th weapon suggested by `@ideas` (15:34, not required): steam nail gun (`PSTN`
  pressure-discharge, real knockback via existing `R.damageEnemiesAt`). |
| mcp | `powder_ext/rpg_tools.py` (**new worker, added 15:24**) | Drew wants rapid indexing/access to
  everything (all info + core mechanics) via MCP tools while the team works. **Starting (15:55)**: 7 tools
  planned — `rpg_status`, `rpg_search`, `rpg_api`, `rpg_hub`, `rpg_reload`, `rpg_screenshot`, `rpg_lua`;
  read-only status/search/api first, then the mutating hub/reload/screenshot/lua tools. `rpg_hub`
  self-tested end-to-end (14:02, wrote a real line to the hub via the tool). Will post again once fully
  registered and all 7 tools' tests pass. |
| guide | `rpg_plugins/guide.lua` (**new worker, added 15:40**) | Drew wants an ONI (Oxygen Not Included)
  style in-game database/encyclopedia. Key `L`. No progress reported yet. |
| lead | `rpg.lua` core | Since 13:02: sun/moon arc + rain height fix, fall damage + screen shake, detailed
  player sprite, `R.NAMES`/`R.nice()` naming convention, New-World-rewind bugfix, fresh-start New World +
  `R.hooks.newworld`, accessory model reconciliation (`R.acc`/`R.accOff`/`R.accOn`/`R.equipAcc`). Currently
  the most active single contributor to core; see Decisions (§6) and P0 list (§4) for details. |

## 4. Backlog (prioritised)

**P0 — bugs/quality Drew flagged, live now**
1. ~~Sun/moon arc "way too low, it doesn't even look right"~~ — **FIXED** by lead, arc now clipped by
   terrain (1283ef5, 13:04)
2. ~~Rain spawns too low to the ground~~ — **FIXED** by lead, rain now spawns at cloud height (1283ef5, 13:04)
2a. ~~"New World" left tools dead / mining broken on a fresh seed~~ — **FIXED**: root cause was the frame
    counter rewinding on New World while cooldown timestamps (tool swing, torch, etc.) stayed at their old
    values, so every cooldown read as "still active" forever. Fixed in core (09b2da8, 945a913 — never
    rewind the frame counter, reset per-world state instead) and in save.lua (4d3e797 — clear
    frame-timestamp cooldowns on load, same bug class on the load path).
2b. **Ambience — "the background is all gray and bad"** — Drew (14:20, reiterated 15:12 "black is
    whack" re: caves specifically). **Surface half implemented by `@world`, committed to disk but not yet
    git-committed**: surface flora (trees, bushes, flowers, tufts, cacti, snow pines), parallax
    hill/treeline background, fireflies at night. **Cave half shipped then reverted**: an air-mask-based
    underground cave-wall backdrop was built (depth-tinted translucent rock texture into air cells,
    stalactites, crystal glints, vignette) but Drew killed it at 16:18 ("get rid of the cave backgrounds,
    it looks whack") — see P0 #10 and Decisions §6. Net effect: ship the surface ambience, drop the cave
    backdrop entirely (not fix it). Will move to "what exists now" once `@world` commits the surface-only
    version to git (see P0 #3, same commit).
3. **Subterranean area quality** — "still super displeased" (13:06), reiterated harder at 15:22 ("stuff
   is everywhere, it looks like crap for the most part"). **Nearly done, `@world`**: the root cause (a raw
   noise level-set crossing with no width floor/domain warp, pinching tunnels to slits — see
   `knowledge/research-worldgen-2026-08-26.md`) is fixed with a full gen rework, **implemented and
   committed to disk (not git yet)**: worm-tunnel + cheese-cavern caves, depth-band strata, structures/
   mineshafts/ruins, lakes/waterfalls, a hell layer. Drew's 15:22 clutter complaint is the *last* thing
   blocking the git commit — `@world` self-diagnosed it live (ore/clay/crystal noise used too small a
   detail scale, reading as freckle-speckle instead of chunky veins, plus a couple of sub-4px decoration
   flecks) and is reworking to 2-3x larger zone+detail noise scales for compact contiguous veins, removing
   the too-small flecks. ETA was ~10min as of their last post; will only git-commit once the offline
   preview looks clean, then post "@lead world gen ready" — **this needs a fresh seed/New World to see**,
   existing dug-out terrain won't change. Move to "what exists now" once that commit lands.
   **Idea-bank picks approved for this pass** (`knowledge/rpg-ideas.md`, 13:45, top 10, still pending —
   confirm with `@world` whether these made it into the rework): **#3 structural cave-ins** (unsupported
   ceiling spans collapse into real falling `SAND`-copy debris, fall damage) and **#4 flash-flood caverns**
   (sealed `WATR` pockets behind a thin membrane, breached on mining, real hydrostatic fill).
   **Idea-bank Round 2** (`knowledge/rpg-ideas.md`, 15:34 — `@ideas` reviewed the shipped work and pivoted
   to validation/refinement instead of duplicate asks): (a) a **clutter acceptance checklist** (2-3x vein
   noise period, no sub-3px decoration, rooms/tunnels from separate passes) to confirm Drew's 15:22
   complaint actually reads as fixed on a fresh seed — use this before declaring #3 done; (b) **depth
   strata tied to real catalog materials** (`SDST`→`LMST`→`GRNT`→`BSLT` by depth) as a refinement on the
   depth-band strata, with a side benefit that `LMST` is real acid-reactive so the acid gun (14:38) tunnels
   that band faster; (c) a **global hydrostatic water-table rule** (extend `WATER_LEVEL=200` so connected
   caverns below it fill with real `WATR` via TPT's own gravity/pressure) — `@world`, confirm whether your
   13:49 lakes/waterfalls pass already does this before treating it as new work.
4a. **Accessory equipment slots + truncated item names** — Drew (14:16): accessories need their own
    equipment slots/section (currently just inventory entries, no dedicated slot UI), and item names in
    the bag are truncated and look bad. **In progress (14:18, `@ui`)**: ITEMS tab rework — full-width
    scrollable list (Carried/Catalog sub-tabs, reusing the recipe tab's scroll pattern) so names are never
    cut, plus a dedicated Accessories equipment-slot row (`R.ACC_ORDER`, icon + hover tooltip,
    locked/found state). Screenshot verification promised before finishing.
4b. **Full inventory UX overhaul** — Drew (14:34): "inventory must be way better; research the best
    designs online first." **Supersedes/absorbs 4a** — 4a's fix stays as useful in-flight progress, but
    the scope is now the whole inventory system. Marked P0 by Drew directly. **In progress (14:36,
    `@ui`)**: researching Terraria/Minecraft/Stardew/Factorio UX into `knowledge/research-inventory-ux.md`,
    then a real grid inventory — stacks, drag-drop (incl. hotbar sync), click-to-pick-up/drop, right-click
    half-stack, equipment/accessory slots, trash slot, sort, search-by-typing, tooltips, recipe book with
    craft x1/x5. `R.inventory` stays the single source of truth; slot layout goes in a new `R.invSlots`,
    pushed onto `R.PLUGIN_SAVE_KEYS` so `@save` picks it up automatically with no save.lua changes needed.
    Two more requirements folded in since: Drew (14:45) wants **fewer clicks to move items** — quick-move
    should be part of the grid rebuild, not a separate pass. Drew (14:52): **"disable my accessories — take
    them out of my bag and equip them if I want."** Core's reconciled model (22bf8ab): `R.acc[k]`=owned,
    `R.accOff[k]`=switched off, `R.accOn(k)`=live effect, `R.equipAcc(k,on)`=toggle — `@ui` uses
    `equipAcc`/`accOn` (not raw `R.acc`) per lead's 15:02 clarification; `@save` persists both `accOwned`
    (73016c5) and `accOff` (eb30b38). **In progress (15:05, `@ui`)**: research done
    (`knowledge/research-inventory-ux.md` — built from existing Terraria/Minecraft/Stardew/Factorio
    knowledge, not fresh web sources, since this session's search quota was already exhausted by other
    workers, noted in the doc); now rebuilding the bag as a real slot inventory (`R.invSlots`,
    drag+click-click hybrid, right-click half-stack, shift-click-to-hotbar, number-key hover-assign, sort,
    search, trash slot, equipment panel, recipe craft x1/x5). One caught-and-worked-around conflict:
    `machines.lua`'s crate-panel mousedown hook unconditionally consumes every click while open and runs
    earlier in the hook chain, so `@ui` can't add clickable quick-stack/take-all buttons there — using
    keyboard shortcuts (Q/F) scoped to `R.cratePanel` open instead; no `@machines` action needed.
    Drew (15:36) restated the accessory panel specifically needs **drag-and-drop** (not just click-toggle)
    — already inside the grid-inventory spec above ("drag-drop incl. hotbar sync"), calling it out since
    Drew named it a second time for the equipment slots specifically.
    **DONE (14:05, `@ui`), committing shortly**: full rebuild live-verified end-to-end via direct hook
    invocation (pickup/drag/drop/swap and accessory equip/unequip both confirmed changing real state, not
    just visuals) plus screenshots. Shipped: `R.invSlots`-backed grid (drag+click-click hybrid, right-click
    half/one, shift-click and hover+6-0 both send straight to hotbar, sort button, search-by-typing, trash
    slot), a real two-row Equipment/Bag drag-and-drop for accessories (drag tray→equipped to equip,
    equipped→anywhere else to unequip, valid-drop-target highlighting, plus click-to-toggle as a fast
    path) using `R.acc`/`R.accOn`/`R.equipAcc` exactly as specified, and recipe-book x1(click)/x5(button)
    crafting. Confirmed `items.lua`'s 12 weapons + jetpack show up correctly with proper names/icons for
    free (`R.ITEMS`-driven). Confirmed no `R.frame`-caching that New World's frame-reset could break. Move
    **COMMITTED (14:12/034ab01)**: `ui.lua` + `knowledge/research-inventory-ux.md`. All panels
    (bag/items/catalog/recipes, quest log `J`, controls card `C`) screenshotted and working; live game
    left clean afterward. This P0 is now fully closed — move to "what exists now" on the next pass.
5. **Items/weapons depth** — "Items are a big deal: be creative, lots of unique options; guns with
   destructive shooting; capitalize on the physics" (13:06). New `@items` worker owns `rpg_plugins/items.lua`
   (slot committed d1da069). This is now a first-class pillar alongside world/enemies/machines/save/ui, not
   a subset of the existing crafting recipes. `@enemies` is copied in for projectile-damage interplay.
   **Idea-bank picks approved for this pass**: **#8 physics dynamite** first (S-effort, zero new physics —
   reuses the existing torch-ignition path, `MINEABLE`/`give()` mining pipe, and the sword's distance-squared
   hit check via `R.damageEnemiesAt`) as the fast first ship; **#6 gravity-well grenade** next (M-effort,
   twin-`GPMP`-around-`VOID` — a *real*, previously-audited gravitational-confinement build scaled into a
   throwable, the highest physics-fidelity item proposed). **#5 antimatter core** (L-effort endgame weapon/
   power cell, `FRAY`+`SPRK` field containment per the audited AMTR lesson) is a good pick but deferred to
   P2 — too large to be `@items`' first ship.

6. ~~"New World" must be a true fresh start~~ — Drew (15:15): "when I click start from new seed I
    expect to start over from scratch." **FIXED** (c32294a): New World now wipes inventory/tools/
    accessories/goals/deaths/stations/machines/enemies and fires a new `R.hooks.newworld` hook. **Action
    needed from every plugin**: `@enemies`/`@machines`/`@items`/`@ui`/`@save` should each register a
    `newworld` hook to reset their own tables (`R.EN`, `R.machines`, item state, UI state, etc.) — not
    confirmed yet whether any plugin has done this.

7. **Big choppable trees + wood pick progression** — Drew (15:31): wants substantial trees you actually
   fell, and a wood-tier pick as an early progression step. Core done: wood pick progression (ba554ca).
   Reiterated harder at 15:43: **"the trees are way, way, way too tiny"** — exact spec given: trunks 4-6px,
   heights 50-90px, canopies 30-50px wide (player is 12px tall, so a tree should read as 4-7 player
   heights). **DONE, `@world` (13:58 status)**: big trees confirmed live in `world.lua` (reloaded,
   `pluginStatus.world == "ok"`) — forest oaks (trunk 4-6px x 50-90px, branches, 30-50px canopies from
   overlapping ellipse clusters), snow pines, swamp dead-trees, desert oasis palms; spacing widened so
   canopies overlap into real forest cover, and spawn (`wx~=0`) always forces a tree on every seed. Felling
   also live: chopping `WOOD` flood-fills the connected trunk/canopy (8-conn, cap 800), removes it top-down
   over ~20 frames, pays out half the trunk cell count as `WOOD`. Gen perf unaffected (9ms cold/8ms warm
   per ~2400-cell strip). New-terrain-only, needs a fresh seed to see it. Drew asked for an ETA a third
   time at 16:00, seemingly crossing in transit with this fix — confirm with `@world`/`@lead` that Drew has
   actually seen it on a fresh seed.
8. **ONI-style in-game database** — Drew (15:40): wants an Oxygen Not Included-style in-game
   encyclopedia/database — "details about everything: materials, what processes they're used in, all of
   that." New `@guide` worker owns `rpg_plugins/guide.lua`, key `L`. Dependencies assigned: `@world`
   exposes `R.oreInfo`/`R.biomeInfo` (where things are found), `@machines`/`@items`/`@enemies` each expose
   a list of their own content for the database to read. Not started as of this sync.
9. **Oxygen meter (replaces plain drowning)** — Drew (15:48): "instead of just drowning, an oxygen meter /
   oxygen level." **DONE in core**: `R.o2` (0-100), drains underwater and in smoke/CO2/gas (samples a 5x5
   grid around the head every 5 frames against a `BADGAS` table: `WATR`/`DSTW`/`SLTW`/`LAVA`/`SMKE`/`CO2`/
   `H2`/`HYGN`/`NBLE`/`GAS`/`WTRV`/`PLSM`/`FIRE`/`CAUS`/`BOYL` — 1.6/tick underwater, `1.0*frac` when >35%
   of samples are bad), refills 3/tick in clean air, suffocation damage (3 HP/tick) at 0, HUD O2 bar.
   Assigned: `@ui` reads `R.o2` for the HUD bar; `@machines` builds an air pump (gas-mode `PUMP` recipe);
   `@ideas` tasked with tanks/plants/pumps as O2 sources (see idea-bank Round 3 below).
   **Idea-bank Round 3** (`knowledge/rpg-ideas.md`, 15:52, `@ideas`) — every idea hooks into the existing
   `R.o2` sampling loop rather than adding a parallel stat, so they compose: (a) **oxygen tank accessory**
   (`@items`) vents real stored `OXYG` (already off the `BADGAS` list) into the head-sample box, physically
   displacing bad-gas hits; (b) **diving helmet** (`@items`, pairs with the tank) only special-cases the 3
   water names in `BADGAS` while tank charge > 0 — blocks drowning but not toxic gas, the real
   diving-helmet-vs-gas-mask distinction; (c) **trees/plants as real O2 sources** (`@world`) reuses the
   `emitter` behaviour already live on `UO2`, repointed at `GRSS`/canopy to emit real `OXYG` — makes
   greenhouses/forests mechanically raise local O2, zero new behaviour code; (d) **CO2 buildup from
   furnaces/boilers** (`@machines`+`@world`), grounded in a real cited catalog reaction: `LMST`/`MRBL`
   (the Round-2 strata bands) have `highTemperatureTransition: "CO2"` at 900-1173K and an acid reaction
   that also vents `CO2`, so a furnace/boiler built near limestone genuinely pools CO2 in a sealed room;
   (e) **cave gas pockets needing venting** (`@world`) splits into flammable (`GAS`/`OIL`, ignites) vs.
   asphyxiant (`CO2`, silent, same calcination source as (d)) hazards; (f) **air pump / sealed-base life
   support** (`@machines`) — stock `PUMP` already moves gas, not just liquid (current `PUMPKIT` only uses
   the liquid case) — a second gas-mode recipe intakes outside air / exhausts CO2, the direct fix for
   (d)/(e). `@mcp`'s planned `rpg_search` tool is flagged as a good home for searching
   `rpg-ideas.md`/`build-lessons.jsonl`.
10. **Cave background drifting** — Drew (15:52): "the background for the caves is drifting, looks
    crappy." Bug in the cave-wall backdrop shipped under P0 2b: the air-mask lags the camera. Fix spec
    given: offset the mask by `(cam - camAtMask)` each frame, rebuild every 2-3 frames at 8px, key the
    texture to WORLD coordinates (not canvas), no parallax for the near cave wall specifically. **In
    progress (13:58, `@world`)**: code done and reloaded clean, but not yet visually confirmed underground
    (player was at the surface for the status check) — needs someone to dig down briefly, or wait for
    `@world` to grab shots themselves.
    **SUPERSEDED (16:18)** — Drew: "get rid of the cave backgrounds, it looks whack." Not a drift bug to
    fix anymore; the whole cave-wall backdrop is being deleted. Lead already pulled `world.lua`'s draw hook
    live and defaulted `R.caveBackdrop=false`. `@world`: delete the cave-backdrop code entirely; keep only
    the surface ambience (hills/treeline/fireflies) behind its own flag, and re-register the draw hook
    without the cave-wall part. See Decisions (§6) for why.
11. **Sandbox mode** — Drew (16:00): wants a sandbox mode to test all the items. **DONE in core**:
    accessible from the Esc menu, `R.sandbox` stocks/tops up everything, grants all accessories, disables
    damage, makes crafting free; fires `R.hooks.sandbox` for plugins to unlock their own stuff (e.g.
    `@items` should unlock all 12 weapons, `@machines` all kits) — not confirmed yet whether any plugin has
    hooked it.
12. ~~"Way more items" (round 2)~~ — **DONE**: `@items` shipped 18 more items+gadgets (8b9b13c) on top of
    the original 12, including the idea-bank's suggested steam nail gun. `@lead`: the 5 progression quests
    from `research-progression.md` §4 (`automate`/`lead`/`uranium`/`diamondpick`/`reactor`) are ready to add
    to `R.QUESTS` now — every field they reference (`m.kind` lowercase, `m.sparkedEver`, the LEAD/ZIRC/GRPH/
    NAK/CNCR recipes) has shipped since this was last checked.

13. **Two oxygen mechanisms now coexist — needs reconciling.** `@items` built a hand-rolled oxygen tank/
    diving-helmet/gas-mask system (16:35, 8b9b13c) that mirrors core's breathing-sample grid and directly
    kills bad-gas particles at each sample point. Separately, core's 18:40 rework (`ae859fe`) added a formal
    `R.o2Sources` registration list (`{x,y,rate,range}`) specifically so plugins don't have to hand-roll gas
    sampling. These may now be doing the same job two different ways. `@items`/`@lead`: confirm whether the
    existing accessories should be migrated to register via `R.o2Sources` (cleaner, one code path) or if the
    direct-kill approach is intentionally kept for a reason (e.g. instant local displacement vs. an
    ambient-range source) — either answer is fine, but it should be a decision, not an accident.
14. **Bag/guide panel mutual-exclusion gap** — `@ui` self-flagged (15:08 log): the GUIDE button closes the
    bag panel before opening guide, but pressing `L` while the bag is open doesn't close the bag first, so
    both can render on top of each other. Small one-line fix, owner `@ui` or `@guide` (whoever gets there
    first) — either add `R.ui.bagOpen = false` inside guide's key-`L`/open path, or have `R.openGuide` do it
    generically.
15. **"Way more machines" wave 2 — now retargeted around life support (P0, promoted by the 18:58/19:04 game-
    identity pivot, see §0a).** Originally just "~35 machines across 5 categories," now has a concrete
    forcing function: real hazard gases (`R.gas` = co/co2/ch4/rad/heat, shipped 19:04) that only these
    machines can fix. **Build order**: (1) CO/CO2 scrubber and a ventilation fan (registers into
    `R.scrubbers`, `{x,y,rate,range}` — the direct fix for sealed-room CO/CO2 buildup), (2) air
    conditioner/cooler (registers into `R.coolers` — fixes geothermal heat below ~900px), (3) gas detector
    (a HUD/panel readout of `R.gas` at the player's position — the "you can't see CO coming" problem), (4)
    lead-shielding wall/plate (mitigates radiation near uranium/depth>1100px — pairs with `research-
    progression.md` Tier 5's already-flagged missing LEAD recipe, now doubly justified). Only *after* those
    four ship does the original "~35 machines, 5 categories, more variety" scope resume. **Also required**:
    machines should visibly chain — shared pipe/duct/wire art between a power source, an O2/scrubber unit,
    and whatever they're feeding — per Drew's "all work together" framing, not just standalone boxes with a
    power dot each. `@machines` should still post a short plan before building, per the team protocol.
    **UPDATE (19:05, in progress)** — `@machines` is already executing this exact build order. **Stage 1
    committing now**: Air pump (real duct pushes `OXYG`, registers `R.o2Sources`), Oxygen generator
    (electrolyses real `WATR`→`OXYG`+`HYGN`), CO2 scrubber (kills real CO2/SMKE in radius, the direct fix),
    Greenhouse (passive daylight-only `R.o2Sources`, real `PLNT`+`WATR`), Sawmill, Desalinator (`SLTW`→`WATR`
    +salt), Blast furnace (30W, only one that smelts DU→URAN). All 7 live-verified via direct placement +
    grid sampling, gated behind existing tech tiers. **Stage 2 next post**: RTG, flywheel, breaker, elevator,
    tunneler, sprinkler, lightning rod, gas turbine (power/logistics/utility). Gas detector and lead-shielding
    (items 3-4 of the original build order above) not yet seen in either stage — worth a nudge next cycle if
    stage 2 doesn't cover them. `@world`: `@machines` asked where any underground brine/ocean `SLTW` sits for
    a live desalinator test.
    **Stage 2 shipped** (RTG/flywheel/breaker/elevator/tunneler/sprinkler/lightning-rod/gas-turbine, grid-
    verified) alongside the full interaction system (backlog #23). **Oxygen chain round 2 (20:55, in the lab
    instance)**: Bellows (hand-pump, no power, fast `R.flask` refill), Air line (drag-placed real duct
    segments — a mined-out gap genuinely cuts air off beyond that point, not a single always-on source),
    Compressor (10W, tops up a carried bladder or `@items`' Oxygen Tank from real ambient `OXYG` — genuinely
    fed by an electrolyser/air line, not a free top-up), life-support panels now show a real sealed/open-to-
    sky room verdict. Gas detector and lead-shielding — **DONE (21:36, batch 2/3)**: GASDETECTORKIT
    (passive, warns on real CO2/smoke/methane) and LEADSHIELDKIT (placeable real-`LEAD` wall panel), the
    two items this backlog nudged three times. This closes out the original P0 build order in full.
16. **`@brainstorm` — LIVE, two rounds posted** (18:56, 19:22). `knowledge/rpg-brainstorm.md` has 61+ concepts,
    top 15 ranked with full specs, checked against items.lua/rpg-ideas.md for zero duplication. Routed to
    `@items` build order (per brainstorm's own note, not re-derived here): Gauss Coilgun + Tesla Arc Rifle
    first (extend existing plumbing), then Blueprint Stamp Wand (Drew's "building stuff" ask, nothing does
    multi-block copy/paste yet), then Portal Gauntlet + Transmuter's Wand. **Reassignment**: Drill Mount and
    Rocket Sled (top-15 #14/#15) move from `@items`' queue to `@vehicles`' (vehicle-shaped, ride via
    `R.mount`). Round 2 (19:22) ties 6 new item specs to the power/hazard pillars (Storm Rod, Geothermal Tap
    Drill for `@machines`; Scrubber Grenade, Lead-Lined Rounds, Pollinator Charm, Weather Vane Beacon for
    `@items`) — read the doc directly for full specs rather than duplicating them here.
17. **Machines open-item triage** — `@items` flagged (18:02 log) a recurring `R.lastErr`:
    `machines.lua:886: this functionality is restricted to graphics events` seen during reload checks.
    `@machines` hasn't acknowledged it yet — likely a `graphics.*` call (used for the new rotation overlays)
    being invoked outside a real draw event; low urgency (doesn't appear to break anything) but worth a
    one-line triage so it doesn't mask a real bug later.
18. **Verification gaps** — (a) granite/titanium laser-melt confirmed only via `elem.property` readback,
    never burned live start-to-finish (`@items`, 18:10 log) — still open. (b) ~~turbine/reactor blade rotation
    under real steam~~ — **CLOSED (20:55)**: `@machines` found and fixed a real boiler bug (the decorative
    vessel from the visual-overhaul pass left an actual solid-wall gap between coal bed and water charge, so
    heat never conducted at all — rebuilt as one continuous chamber), then confirmed the full physical chain
    live: real sustained ember ignition, finite real fuel (900 ticks/cell), water crossing 373K into real
    `WTRV`, hand-piped to a turbine, turbine's real hit counter incrementing — boiler→steam→piped→turbine→
    watts confirmed end to end. Bonus: removed the old decorative flame/steam glyphs entirely now that TPT's
    real effect pipeline renders them for real. (c) Harpoon/Rail-Gun pierce-and-pull never exercised against
    a real live enemy (`@items`+`@enemies` joint test asked for since 13:45, still outstanding — see §3z
    silence-check). (d) tiny `R.sel` keycode glitch (`@guide`, not urgent, unchanged).
    **New (20:55)**: `@machines` flagged the lab instance (port 9877) has zero custom power elements defined
    (`STEL`/`CU`/etc all nil — only the main game ever ran `define_power_elements.py`), which caused a false
    test failure. Whoever owns the lab instance setup (`@harvest` built `scripts/lab_instance.py`) should
    run the same element-definition step there for parity, or every worker doing LAB-FIRST verification on
    power/custom elements will hit the same false negative.
    **Escalating (21:10)**: `@machines2` independently hit this exact same gap doing unrelated chemistry
    work — two separate workers wasting time on the same environment bug in one session means this should
    move ahead of new-feature work, not stay a low-key flag.
19. **Progression retune around depth + life support (P0, new — 19:04/18:58 game-identity pivot, see §0a)**
    — `research-progression.md`'s existing 6-tier plan (Wood→Iron→Biome Trip→Automation→Deep Zone→Reactor)
    was written before the hazard-gas system existed and treats oxygen as a side stat, not the spine of the
    game. `@progression`: revise the tier plan so each depth band's *defining* challenge is life support
    (what hazard gas dominates there, what machine chain answers it), not just "harder ore." Concretely:
    Tier 2 (shallow caves) = first CO risk from sealed torch/furnace rooms; Tier 3 (biome trip) = swamp CH4
    pockets as an explicit hazard, not just a resource; Tier 4 (automation) = first scrubber/cooler chain,
    reframe the existing `automate` quest around "keep a sealed room breathable," not just "spark a
    conductor"; Tier 5 (deep zone) = radiation + geothermal heat as the headline hazard (lead shielding
    already flagged as a missing recipe here, now doubly justified); Tier 6 (reactor) unchanged. Hand the
    revised quest text to `@lead` the same way the original set was (backlog #12).
20. **`@vehicles` — DONE, first ship complete (20:35, closes this item, f6a8e82).** Rails as a real
    placeable segment-graph material (flat/45-slope/vertical) + 6 vehicles on one shared on-rail physics core
    (gravity-along-slope, friction, derail-with-crash): Minecart, Handcar, Locomotive (coal or grid power)
    towing up to 3 auto-coupling Cargo Wagons, Train Stops + 2-stop auto-route, Mine Lift (powered vertical
    cage, free-falls if power drops mid-trip), Drill Train (bores rock on real pick-tier rules, lays its own
    rail). Live-tested end to end, confirmed clean on the wrapper-function audit (backlog #25). **Found and
    fixed a second, independent stack-overflow cause** — see new item 27, promoted given its severity.
21. **`@survival` — DONE, first ship complete (19:52, closes this item).** `survival.lua` shipped in
    one pass: farming (Tilled Soil/Seeds/Spore/Saplings, staged growth gated on real WATR/darkness), an
    Algae Tank (dark-deep-base O2 source, deliberately distinct niche from `@machines`' daylight
    Greenhouse — good example of the team avoiding a duplicate), food/cooking (4 foraged raw foods -> 4
    cooked/purified recipes via `R.FOODS`, illness-on-raw-eating wired through core's `R.eat`), a Canteen
    for clean water, `R.warmth` (cold-side companion to `R.gas.heat`) with insulated-gear counterplay, a
    sleep-to-morning Bed that also sets respawn, and a 10-event weather/hazard system (`R.sEvent`) reusing
    real mechanics throughout (rain, `R.crumble`, real GAS ignition, real STNE meteors, real ICE freezing,
    real WATR aquifer bursts) rather than scripted effects. Live-tested end to end in Sandbox, cleaned up
    after. One open note: Migration event just flips `R.enemies` on as a stand-in, `@enemies` could offer a
    real spawn-wave API if convenient, not urgent.
22. **`@harvest` — DONE, first library delivered (15:41 log, closes this item).** Mined 42 community saves
    via an isolated lab instance (port 9877) — confirmed correctly LAB-FIRST, Drew's live session never
    touched. Delivered 30 structures (`knowledge/structures/*.json`: 8 surface, 8 underground, 4 deep, 10
    tiny detail props) with offline Pillow-rendered previews for all 30, plus a ready-to-paste JSON schema +
    Lua loader/placement engine for `@world` in `knowledge/structures/README.md` (two pieces intentionally
    left as sketches for `@world` to finish: underground/deep depth-origin roll, two placement predicates).
    Also flagged a small core API ask for `@lead` (`R.placeChestAt(x,y,tier)` to guarantee loot in specific
    structures like the sealed vault, bypassing `R.chestAt`'s 45% roll) and sourcing lessons for
    `@ideas`/`@progression` (wood-on-stone not wood-on-dirt, coloured glass reads better than clear against
    terrain, crenellated walls, ore woven into rock not boxed, BMTL/bronze as the "abandoned machinery" tell).
    **Next**: `@world` wires the loader in (small, well-scoped per the README).
23. **Machine interactivity — DONE (19:34/19:37/19:38 ask, `@machines` shipped 19:45).** Drew: couldn't
    tell what a machine needed or that it was interactive at all. Shipped: proximity pulsing-outline +
    "[right-click] Name" prompt on every machine, right-click opens a real panel (coloured state word, live
    INPUTS/OUTPUTS, an imperative NEXT line e.g. "Light the coal bed..."), universal Start/Stop (`m.disabled`,
    respected by the power grid), boiler-specific Light-firebox/Fill-water, breaker Reset. Live-verified via
    real bridge clicks (boiler fire cell 297K->700K, a real WATR particle appeared). E is not touched — the
    whole thing is right-click only per Drew's 19:38 clarification, no key collision with `@ui`'s bag.
    **Deferred items — PARTIALLY DONE (21:37, batch 3/3)**: rescale done for turbine/wheel/flywheel/boiler
    (low-risk ring/box-parameterised shapes only; reactor's intricate multi-part layout deliberately left
    alone rather than rescale blind); pipe fluid-flow overlay done as a real-condition-gated moving dot
    (only drawn while real `WTRV`/active-drag is actually detected, never decorative). Reactor rescale is
    the one remaining piece, not yet scheduled.
24. **Energy-harvesting tree — DONE (21:35, closes this item).** `@machines` batch 1/3 shipped every
    scoped piece: FUELCELLKIT, WINDKIT, SOLARFURNACEKIT, FLAREKIT (real `R.gas.ch4` vent), GEOTAPKIT,
    METHANECAPKIT, panel fouling (dust reduces output, Clean-panel button), real `LIGH`-strike bonus on
    LIGHTNINGKIT — all wired into `R.power`/`R.tech`/`genWatts`/`inspect` like the existing chain. Built to
    the new no-testing standard (known-good patterns, reload-clean check, no live-sampling loop).
25. **Wrapper-audit + lab-first compliance tracking (P0, new — 20:12 incident, see §0c).** Every plugin
    that wraps a core function must confirm it's idempotent (guarded first-load capture, not re-wrap-on-
    reload). Status: `@survival` — confirmed offender (wraps `R.eat`/`R.spawnPlayer`), fix not yet confirmed
    in the hub. `@machines`/`@ui`/`@items` — audit not yet confirmed by any of them. `@harvest` is a good
    positive example (explicitly ran its whole research pass on an isolated lab instance, never touched
    Drew's session). `@enemies`/`@world`/`@save`/`@guide`/`@vehicles` — no known wrapping, haven't explicitly
    confirmed either; low priority to chase unless one is known to wrap something. Acceptance test: every
    plugin that wraps a core function has posted "audited, clean" or "found + fixed (commit)" in the hub.
26. **`@machines2` — LIVE, stage 1 shipped (21:10).** Owns `scripts/lua/rpg_plugins/machines2.lua`, own
    `R.machines2` table, zero edits to `machines.lua`/`R.machines`/`R.power`/`R.tech` (read-only on tech
    tiers) — clean split confirmed. **Stage 1 (Chemistry, 5 machines, lab-verified with real reagent+spark
    reactions, not just structure reads)**: Electrolysis Cell (real `SLTW`+spark→`HYGN`+`CAUS`, chlor-alkali,
    distinct niche from `@machines`' fresh-water O2GEN), Acid Synthesizer (`SALT`+`WATR`→real `ACID`), Salt
    Evaporator (passive, `SLTW`>373K→`SALT`+`WTRV`), Fertiliser Mixer, Gunpowder Mill. Confirmed clean on the
    wrapper audit (backlog #25) — hooks only, no `R.<fn> =` reassignment. Also independently hit the same
    lab-instance missing-custom-elements issue `@machines` flagged (backlog #18, escalated).
    **Stage 2 (Fluids, 21:35)**: Check Valve, Pressure Vessel (real pressure-field read, ruptures past 6.0 —
    caught a real hard-error bug here: `sim.pressure(x,y)` is 4px-celled and throws outside its own grid,
    fixed with a bounds-checked helper), Reservoir Tank, Steam Condenser, Drainage Sump.
    **Stage 3 (Logistics, 21:55)**: Sorter, Splitter, Vacuum Collector (deliberately real velocity-nudge, not
    the native VACU/BHOL element — a safety call given the day's two stack-overflow incidents), Silo, Quarry
    (auto-mining shaft). Caught a real crash here too: Silo's table had no plain `x`/`y`, crashed the shared
    proximity-hint code — fixed, now grepping every machine table for `x`/`y` before shipping a stage.
    **Stage 4 (Exotic/Physics Toys, 22:15)**: Gravity Manipulator (real WHOL, not destructive SING — same
    safety call as stage 3), Portal (real PRTI/PRTO), Magnetic Accelerator (real PSCN/NSCN rail), Cryo
    Chamber (`R.coolers`), Weather Machine (`R.weather.rain`). Self-caught a real bug here worth flagging
    project-wide: `hook()` de-dupes by tag *per call-site*, and this file had two separate
    `hook(R.hooks.newworld, ...)` registrations — the second silently overwrote the first, so `R.machines2`'s
    own new-world reset had never actually fired since stage 1. Fixed to one registration. **Any other
    plugin that calls `hook()` on the same event from more than one place in its file should check for this
    same silent-overwrite pattern** — added to §6 decisions log.
    **URGENT, unresolved**: `@machines` flagged (21:37) that `machines2.lua` has a live `pluginErr`
    (`machines2.lua:42`, arithmetic on nil) as of batch 3 — this is exactly the one thing the no-testing rule
    still requires ("confirm your plugin loads clean"), so it should be `@machines2`'s top priority to fix
    and confirm in the hub, ahead of stage 5.
27. **Second stack-overflow root cause — no cycle guard in `R.save()` (P0, new — found by `@vehicles`,
    20:35).** Distinct from the 20:12 IDEMPOTENT-WRAPPERS incident: `save.lua`'s generic
    `R.PLUGIN_SAVE_KEYS` dump is a plain recursive JSON walk with no cycle detection, so any plugin storing a
    live two-way object reference in its saved-state table (e.g. a cargo wagon holding a direct table
    pointer back to its locomotive) stack-overflows every `R.save()` call the instant that reference exists.
    `@vehicles` hit this for real (`save.lua:48: stack overflow`, real save failures) and fixed their own
    side (a plain boolean flag instead of the back-reference), but the underlying gap is in `save.lua` itself
    and will recur for the next plugin that makes the same mistake. **New standing rule, added to §0c**:
    never store a two-way object reference in `R.PLUGIN_SAVE_KEYS`-tracked state, only plain flags/ids.
    **Assigned `@save`**: add a depth or visited-set guard to the generic dump walk so this fails safely
    (skip/null the cycle, or raise a clear error) instead of overflowing, protecting every other plugin too.
28. **`@companion` — shipped, then redesign requested (21:06).** First `companion.lua` shipped but its
    `scriptedBrainTick` just auto-handed the player any held item every 60 frames with a filler chat line —
    Drew: "he is just spamming, handing me random shit." `@lead` audited the file and wrote
    `knowledge/design-companion-core.md` (root cause: no planner, no area/build tasks, purely a scripted
    tick). Drew's actual ask is a **local-model-driven agent that acts intelligently on real commands** —
    "cut all these trees, dig me a big hole, build me a really cool house — dynamically, not pre-made stuff."
    `@companion` should implement the redesign doc: a real planner/task system (area-selection commands,
    multi-step build/dig/chop tasks executed over time via the existing mine/place/craft hooks, not one-shot
    item-giving), keeping the proactive-narration half of the original ask. Built to the no-testing standard
    like everyone else — confirm load-clean + registered, no live-fire verification loops.
29. **`@engine` — new architect role, not started (P1, new — mentioned this pass, no hub post yet).**
    Referenced by the lead as an "engine architect" alongside the other active workers when the 21:44
    no-testing rule went out. No spec, file, or first post seen in the hub as of this sync — flagging as
    unowned/unclear rather than guessing at scope. Likely candidate scope given the name and this session's
    growth (7 plugins, 2 machine tracks, vehicles, survival, companion, all hot-reloading into one `rpg.lua`
    core): overall architecture health — plugin-load order, hook-registration hygiene (see the `hook()`
    de-dupe-by-call-site lesson `@machines2` just hit, backlog #26), and cross-plugin API consistency —
    but this is a guess, not a confirmed brief. `@roadmap`: confirm scope with `@engine` directly once it
    posts.



*P0s already resolved (kept for traceability, no action needed):* STKM legs snagging → sprite player
(6c8d889); ragged pick corridors / stuck on iron veins → smart cursor + pick tiers (5016a51); tools not
equippable / hotkeys undiscoverable → hotbar fix + Esc menu (43eef03); coal burning out uncontrollably →
`Flammable=0` + slow-burn bed (640258c); quest reward crash (be89019); chest cell constant scope (f9bdbaf);
sun/moon arc + rain height (1283ef5); **Spelunker Glowstick accessory "spamming the screen"** — per-pixel
ore highlights replaced with soft pulsing outlines on ore clusters, refreshed every 20 frames instead of
every frame (ce6f55b, 14:10, lead). Also resolved this pass (16:24-18:46, see §2a for full detail): trees
break/topple when felled; grapple simplified to middle-click/double-jump; TPT menus hidden + hotbar/Esc-menu
redesigned to fit `R.SAFE`; harsh biome border softened; biome purpose shipped; guide reachable from the bag
menu with a public open/close API; weapon aim/tracer/shotgun-range fixed; laser/plasma now melt terrain
instead of deleting it; brittle terrain shipped then correctly dialed back to damage-triggered-only; real
fire/steam/glow render effects; sandbox-guide item granting; fast physics mode; oxygen concentration model;
shift+wheel block resize.

**P1 — next features (per worker ownership + design doc "full" scope) — updated 18:5x**
- ~~`@world`: differentiate biome materials~~ — **DONE**, see biome-purpose ship (7c5d4f8) in §2a.
  Still open from this line: the **water-table flood/drain mechanic** (idea-bank Round 2's global
  hydrostatic water table) — not confirmed whether `@world`'s lakes/waterfalls pass already covers this;
  worth a one-line confirmation.
- ~~`@mcp`~~ — **DONE** (554a877, see §3z).
- `@items`: still an open standing pillar — keep building against `R.damageEnemiesAt`/`R.enemyList`; now
  also fed by `@brainstorm` (backlog #16) once that starts producing.
- `@enemies`: `FIGH` integration into the plugin is done (enemies.lua); still open: weapon-by-tier loot
  scaling, day/night spawn-rate scaling by depth/progress (per `research-progression.md`'s RimWorld-storyteller
  principle — hazard pressure should track player progress, not be a flat constant), and idea-bank #10
  (virus-outbreak biome).
- `@machines`: hardness-gated pickaxe tiers already exist (`R.HARD`/`R.MINEABLE`); ambient ore-chemistry
  reactive rules still open, lower priority than backlog #15 (machines wave 2).
- ~~`@save`~~ — **DONE** (a8f17e1, 13:34). See §2/§3.
- `@ui`: quest-log key (`J`, shipped) + tier/active-quest HUD line — mostly covered by the shipped quest
  log; day/night darkness overlay still open (low priority, cosmetic).

**P2 — later (design doc "full" scope)**
- 8-tier tech tree — **substantially shipped**: Wood→Iron→Biome Trip→Automation→Deep Zone→Reactor is now
  live end-to-end per `research-progression.md` + `@machines`' reactor kit + `@lead`'s quest additions
  (backlog #12). Remaining: `@lead` add the last 5 quest entries (backlog #12).
- NPC villagers/quest-givers via the `creature`/worker-colony system (design doc §4) — **still untouched**,
  nobody has picked this up.
- `run_test`-backed quest verification replacing ad hoc quest tracking (design doc §5) — **still untouched**.
- ~~`rpg_start`/`rpg_status`/`rpg_save` MCP tools~~ — effectively superseded by `@mcp`'s shipped `rpg_*`
  tool suite (rpg_status/rpg_search/rpg_api/rpg_hub/rpg_reload/rpg_screenshot/rpg_lua).
- **Idea-bank picks, deferred but tracked, still unbuilt** (`knowledge/rpg-ideas.md`, top 10): **#1
  portal-pipe item network** (`@machines`, M); **#2 buildable fission micro-reactor** — **now effectively
  superseded/shipped** as the real reactor kit (`REACTORKIT`) + progression quest chain, no longer a
  separate P2 item; **#3 structural cave-ins** and **#4 flash-flood caverns** (`@world`, both M, greenlit
  13:52, still not built — good next pick per §3z); **#5 antimatter core** (`@items`, L); **#7 wildfire
  spreading through wood builds** (`@world`+`@ui`, S); **#9 snow-biome hypothermia** — **partially shipped**
  (snow hypothermia hazard is live per biome-purpose 7c5d4f8; the insulated-base/`AERO`/`TEG` counterplay
  half is still open for `@items`/`@machines`); **#10 virus-outbreak cave biome** (`@enemies`+`@world`, M).
  None of the still-open ones are assigned to a worker's *next* task yet — pull from here once
  the P0/first-P1 items above are shipped.

## 3a. Validated direction (14:38)

Drew, unprompted positive feedback: **"I really like the acid gun, a lot of fun."** First live proof that
the items/weapons pillar (§4 P0 item 5, greenlit 13:52 from the idea bank) is landing exactly as intended —
physics-driven weapons are a hit. Treat this as a steer, not just a compliment: prioritise more of this
class of item over less-physical alternatives when `@items` is choosing what to build next. Immediate
follow-up assigned to `@items`: held gun models that actually look cool — aimed held sprites (gun tracks
aim direction, not just a HUD icon), recoil kick, muzzle flash on fire.

## 4a. Ideas pipeline (new, 13:09)

Drew asked for an idea agent to pair with the roadmap: `@ideas` now exists, will write ranked,
physics-grounded feature specs to `knowledge/rpg-ideas.md` (not created yet as of 13:13) and post them to
the hub. Process going forward: `@ideas` proposes → roadmap keeper rates and pulls the best into the P1/P2
backlog above with an owning plugin → reply posted in the hub telling `@ideas` what to elaborate next.
First ask sent to `@ideas` (see hub log): elaborate specs for (1) the underground-quality overhaul feeding
`@world`'s research task, and (2) the items/weapons pillar feeding `@items` — those are Drew's two named
priorities at 13:06, so ideas should land there first rather than spreading thin.

**Second lane added 18:48**: `@brainstorm` runs the identical process but scoped specifically to
weapons/tools/magic/building concepts (`knowledge/rpg-brainstorm.md`, not created yet) — the two files
should not duplicate: `@ideas` stays all-category (biomes, hazards, engineering, progression, combat),
`@brainstorm` is items/weapons/tools/magic only. Same routing: `@brainstorm` proposes → `@roadmap` rates and
hands the best straight to `@items`' queue → reply posted in the hub telling `@brainstorm` what to refine
next. First ask once it starts posting: Drew's own framing (18:48) — "way more guns, cooler guns, disruptive
stuff, building stuff, super dope magical tools, extremely unique stuff" — so lean into novelty/disruption
within the project's real-physics-grounding bar (every idea must cite a real TPT element/behaviour, per the
standing convention `@ideas` already follows in `rpg-ideas.md`'s grounding-sources section).

## 5. Open questions for Drew

1. **Design doc vs. shipped code contradict each other on the player.** `design-rpg-2026-08-26.md` (today,
   same day as v4) is written entirely around the native `STKM` stickman — control mapping, HP/damage model
   (fire/heat/radiation/cold via `Element_STKM_interact`), and enemy `FIGH`-vs-`STKM` targeting all assume
   STKM. But the actual `rpg.lua` v4 uses a custom sprite player with its own kinematics — STKM was
   abandoned earlier because "legs get stuck." None of the design doc's sourced native damage/control
   mechanics apply to a sprite player without manual re-implementation. Should the design doc be revised to
   document the sprite architecture (dropping the STKM sections), or is there appetite to reconsider STKM
   now that pick tiers/smart cursor have fixed the original movement complaints? Flagged to `@enemies` and
   `@machines` in the hub since their P1/P2 items (damage sources, FIGH targeting) depend on the answer.
2. Should hunger/food stay a stretch goal (design doc's recommendation, given fire/heat/radiation/cold are
   already punishing) or get scheduled now?
3. `R.enemies` defaults to `false` — at what day/tier should enemies turn on by default, if ever?
4. **(new)** With the 6-tier progression plan (`research-progression.md`) now substantially live, is the
   reactor (Tier 6) meant to be the actual endgame, or does Drew want a 7th/8th tier beyond it (e.g. the
   idea-bank's antimatter core, #5, as a true capstone)? Affects whether `@items` should treat antimatter
   core as P1 or leave it at P2.
5. **(new)** "Way more machines" (18:40) named 5 categories but no count/specifics — is ~35 a hard target or
   just "a lot"? Affects how big a spec `@machines` should write before starting (see backlog #15).

## 6. Decisions log (with reasons)

- **`hook()` de-dupes by tag per call-site, not globally — registering the same event twice in one file
  silently drops the first.** `@machines2` (22:15) had two separate `hook(R.hooks.newworld, ...)` calls in
  the same plugin; the second silently overwrote the first, so `R.machines2 = {}`'s own new-world reset had
  never actually fired since stage 1, undetected until a full-file self-review (not live testing, consistent
  with the no-testing rule). **Lesson for every plugin, especially ones with multiple stages/authors touching
  one file over a session**: register each event exactly once per file, consolidating multiple concerns into
  one handler rather than calling `hook()` on the same event from more than one spot.

- **Live testing on Drew's shared session is retired as a convention — replaced by a lab instance.** Earlier
  in this doc (see the enemies/machines/items rows in §3y), careful live-testing directly against Drew's
  running game was the established, praised convention, with a rule to correct only exact deltas rather than
  snapshot-restore. That approach finally caused real harm: a plugin re-wrapping a core function on every hot
  reload built up an unbounded call chain until Lua's stack overflowed Drew's actual game (20:12). **Lesson**:
  "be careful and clean up after" was not sufficient insurance against a whole class of bug (unbounded
  wrapper growth across reloads) that only manifests after many reload cycles — exactly what happens over a
  long active session. Going forward, verification happens in a separate lab instance first (port 9877); nothing
  untested reaches Drew's session at all, which is a stronger guarantee than careful-plus-cleanup. See §0c.

- **Cave-wall background shipped, then removed one message later.** `@world` built a technically careful
  underground backdrop (air-mask so it never covers particles, depth-tinted bands, budgeted under 2ms, shipped, then removed one message later.** `@world` built a technically careful
  underground backdrop (air-mask so it never covers particles, depth-tinted bands, budgeted under 2ms,
  even a same-session fix for camera drift) in direct response to Drew's own 14:20/15:12 ask for cave
  ambience. Drew tried it and killed it at 16:18: "get rid of the cave backgrounds, it looks whack."
  **Lesson**: a request for "less gray/more ambience" doesn't guarantee any specific visual treatment will
  land well once seen live — subjective visual features should be treated as provisional until Drew has
  actually looked at them running, not "done" once they're technically correct and match the brief. Surface
  ambience (flora, parallax hills, fireflies) was not part of this rejection and stays.
- **Standing process lesson: testing on the shared live session must never risk Drew's real progress.**
  While live-testing weapons, `@items` drove the player's HP to 0 several times via self-inflicted damage
  before finding the muzzle-offset bug (see items row, §3); each death halves the *entire* inventory
  (core `movePlayer`), which briefly wiped a large chunk of Drew's real stockpile (e.g. `GRNT` 2883→180,
  `GOO` 807→0) since he was playing concurrently. `@items` caught it and restored an exact pre-test
  snapshot, but flagged the fix itself as risky: a full-table snapshot-restore can clobber real progress
  Drew made *during* the test window. **Going forward**: when a test perturbs shared state while Drew may
  be playing live, correct only the specific keys/amounts you changed, by the exact delta, rather than
  snapshot-and-replace the whole table.
- **Player is a drawn sprite, not STKM.** STKM's legs kept snagging on terrain; the sprite gets its own
  kinematics (gravity 0.24, run 1.6 px/f, jump ≈28px, 4px step-up, coyote time) tuned to feel right.
  (6c8d889; memory/powder-rpg.md)
- **Chunks replaced by one continuous world + a stepped camera.** Drew: "one continuous map instead of
  loading the next." Smooth per-frame scrolling was tried and lagged (36 ms/frame); the camera instead
  steps 32px when the player leaves the dead zone, with evicted particles cached per 64px tile in
  `R.tiles`. (c1f2ecd; memory)
- **`GRSS` (session-defined PLNT copy, no growth) exists** because real rain made stock `PLNT` explode.
  (5a3716d)
- **Coal `Flammable` reset to 0, long-life furnace bed added.** Stock coal burned out too fast/
  uncontrollably; the furnace now needs a lit torch and coal smoulders slowly instead. (640258c)
- **Smart cursor (T toggle) added.** Flat-radius pick corridors were ragged and narrower than the player,
  and hard ore veins (iron, tier 3) stalled progress; smart cursor mines the first minable block along the
  ray to the cursor, skipping ore too hard for the current pick. (5016a51; memory)
- **Hotbar auto-switch disabled + snap grid added.** Drew found tools hard to equip and hotkeys
  undiscoverable in earlier versions; auto-switching mid-build was also unwanted. (43eef03)
- **Plugin hook API introduced.** Needed to let five workers extend world/enemies/machines/save/ui in
  parallel without merge conflicts in shared `rpg.lua`; lead keeps sole ownership of the core file, each
  plugin removes its own hooks on reload so live-reloading stays idempotent. (ae38e77)
- **Player-facing element names must read as their real-world thing, not the raw TPT element code.**
  Drew (14:26): "rename elements to their real-world thing (dirt, not goo) — confusing otherwise." Lead
  added `R.NAMES`/`R.nice(name)` in core and applied it to the hotbar, palette, hints, and craft lists.
  **Standing convention going forward**: `@ui`, `@items`, and `@machines` must display element names via
  `R.nice(...)`, never the raw internal element string (`GOO`, `STNE`, etc.), in any new tooltip, item
  label, recipe row, or panel text.
- **Accessory/effect visuals must be calm and readable, never full-screen noise.** The Spelunker Glowstick
  drew a per-pixel highlight on every visible ore particle every frame, which read as screen spam rather
  than a helpful indicator; fixed by outlining ore *clusters* with a soft pulse refreshed every 20 frames
  instead (ce6f55b, 14:10). **Standing lesson for `@ui`/`@items`/`@enemies`** going forward: any new HUD
  overlay, damage-number fx, or item visual effect (dynamite blast, gravity-well grenade, radiation
  warning, etc.) should default to low-frequency/subtle rendering (throttled refresh, soft/faded style)
  rather than a full-detail per-frame per-particle overlay — cheap to render is not the same as pleasant
  to look at.
- **A shipped physics-accurate effect can still be "too much" and needs a dial, not just a toggle.**
  Brittle terrain (`R.crumble`) was built correctly per spec (17:58) — isolated small clumps collapse into
  real falling rubble — but a periodic ambient sweep every 24 frames made *too much* of the world
  crumble at once (18:10: "world is falling apart"). Fixed by making it damage-triggered only, never
  periodic, and shrinking the clump-size limit. **Lesson**: when a real-physics reaction is correct but
  applied both reactively (at impact) and ambiently (on a timer), the ambient half is usually the one to
  cut first if Drew says "too much" — the reactive half is what he actually asked for.
- **Real air/pressure simulation is expensive enough to need an explicit fidelity toggle.** Measured live:
  ~25% of frame time was air/pressure sim (18:28). Rather than degrade it silently or leave it always-on,
  core added an explicit Fast-physics toggle (default on) with a `R.setFast(false)` escape hatch for the one
  class of machine (steam/pressure-driven) that actually needs it. **Standing rule**: any future
  mechanic that depends on real air/pressure/water simulation must call `R.setFast(false)` while active and
  restore it after, rather than assuming full fidelity is always on.
- **TPT's own native UI and the plugin UI must never compete for the same screen space.** Drew's 18:20/18:40
  complaints (element bar cutting off the screen, menus getting clipped) both trace to plugins/core not
  fully respecting that TPT still has its own HUD/menus running underneath. Fixed by hiding TPT's native
  chrome while playing (`tpt.hud(0)`, `R.setTptMenus(false)`) and defining one shared `R.SAFE` rect that
  every plugin panel must draw inside. **Standing rule, now enforced project-wide**: any new panel/HUD
  element must fit inside `R.SAFE`, and any feature that needs TPT's native element-selection menu must
  restore it via the Esc-menu toggle rather than assuming it's visible.

## 7. Plugin status snapshot

All seven plugin files exist and are committed and live: `world.lua`, `enemies.lua`, `machines.lua`,
`save.lua`, `ui.lua`, `items.lua`, `guide.lua` (`rpg_plugins/README.md` is the only non-code file in the
folder as of this pass — the earlier stray `_probe.py` flagged at 13:17 is gone, no action needed). Two more
knowledge-only "virtual plugins" exist alongside them: `powder_ext/rpg_tools.py` (MCP tools, done) and the
research/idea files (`research-progression.md`, `rpg-ideas.md`) that don't touch the game directly.
`knowledge/rpg-brainstorm.md` (backlog #16) is now live with 2 rounds posted.

## 8. Standing loop (roadmap keeper's own process, for continuity across passes)

Per Drew's 18:42/18:51 asks, this role runs continuously while the team works: re-read `rpg-hub.md` **in
full** (not just the tail — a partial/hash-based re-read has silently dropped concurrent worker posts twice
before, see the 15:46 and 16:08 hub corrections) roughly every 3 minutes; fold every new "Drew says" line
into a tracked backlog item with an owner/priority/acceptance-test; expand backlog items into 2-4 line specs
so a worker can pick them up cold; post hub lines assigning/prioritizing work and flagging conflicts; note
unowned items explicitly with a proposed owner. If this pass ends (time limit, or handed off) before Drew's
asks stop coming in, the correct move is a short **handoff note right here** — current backlog state, who's
mid-task, what's unowned — not silence.

_2026-08-26 18:5x — mid-pass, continuing. No handoff needed yet; still inside the active window._

## HANDOFF (2026-08-26, ~22:20, end of this pass's ~60-minute window)

This pass covered 18:42 through 21:44/22:20 in real terms (the hub's own in-fiction clock ran 12:55→22:20+).
Whoever resumes this role: **re-read this whole file once, then read the hub from wherever your own re-read
of the "Drew says" section and Log tail leaves off** — do not assume this handoff note is fully current by
the time you start, since workers post asynchronously and several were mid-stage when this pass ended.

**Snapshot of state right now**:
- Standing rules (§0c) are at rule 4 (NO TESTING BY WORKERS, 21:44) — this supersedes LAB-FIRST entirely.
  Watch for any worker still describing a live-fire test or screenshot loop and call it out.
- Backlog #1-22 are fully resolved or superseded (see the numbered list in §4) except #13 (two oxygen
  mechanisms, still an open decision), #14 (bag/guide panel gap, small, unowned), #17 (machines.lua:886
  graphics-event error, never confirmed triaged), #18 (item (a) laser-melt live-verify, now moot under the
  no-testing rule — consider closing it as "no longer applicable" rather than chasing it), and #19
  (progression retune — `@progression` never confirmed doing this despite being asked at 18:58/19:04).
- #23-24 DONE. #25 (wrapper audit) — `@vehicles`/`@machines2` confirmed clean; `@machines`/`@ui`/`@items`
  never explicitly confirmed either way, worth a direct nudge. #26 (`@machines2`) has an **unresolved urgent
  pluginErr** (`machines2.lua:42`) flagged by `@machines` at 21:37 — check first whether this is fixed.
  #27 (`@save` cycle guard) — never confirmed done by `@save`, who has otherwise been quiet since the
  initial ship. #28 (`@companion` redesign) and #29 (`@engine`, still no first post seen) are both fresh.
- Two structural deliverables are ready for someone to consume: `@harvest`'s structure library
  (`knowledge/structures/`, README has a ready-to-paste loader) waiting on `@world` to wire in, and
  `@lead`'s planned `knowledge/machine-manifest.html` artifact for Drew to inspect machines — worth checking
  whether that manifest exists yet and, if so, publishing/linking it per the artifact workflow.
- `research-progression.md` still needs the depth+life-support retune asked for at 18:58/19:04 (backlog #19)
  — this is the single oldest unactioned ask in the whole backlog at handoff time.

**Top 5 things for the next pass to check on first**: (1) is `machines2.lua:42` fixed; (2) has `@save` added
the cycle guard (#27); (3) has anyone heard from `@engine` yet; (4) did `@progression` ever retune the tier
doc; (5) full re-read of "Drew says" for anything past 21:44 that arrived after this pass ended.
