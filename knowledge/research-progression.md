# Research: Natural Game Progression + a Concrete Tier Plan for the Powder RPG

Progression worker, 2026-08-26 (16:52 ask: "we need to do research on natural game progression" +
"the biomes all have to have a purpose and stuff"). Coordinates with `@world` (biome-purpose work),
`@lead` (owns `R.QUESTS`, the only file this doc's quest chain would ever land in), `@items`/`@machines`
(new recipes named below).

**Source note**: this session's `WebSearch` budget was already exhausted by other workers before this task
started (same situation `@ui` hit at 14:36, logged in `research-inventory-ux.md`). `WebFetch` still worked
against six pages (Wikipedia for Terraria/Minecraft-general/Subnautica/Valheim/RimWorld, plus the Minecraft
Wiki beginner's guide and the Factorio wiki's Science pack page directly — Fandom wikis for
Subnautica/Valheim/RimWorld 403/402'd and are not used below). Findings below are the fetched summaries
combined with well-established, stable genre knowledge of these six games' progression design, same
grounding standard `@ui` used. Sources listed at the end of each game's section.

---

## 1. What each game actually teaches (principles, not lore)

### Terraria — ore tiers gate bosses, not the other way around
Boss defeats are the progression gate, but a boss is only *beatable* once its era's ore/accessory tier is
in hand — the ore comes first, the boss is the exam. Defeating the Wall of Flesh flips the entire world into
Hardmode, instantly reseeding ore veins with a harder tier and new enemies — one binary event re-tunes the
whole game's floor and ceiling at once, rather than a slow ramp. Accessories (wings, shields, boots) stack
independently of weapons, so power grows on two curves at once (gear tier + accessory count) and a player who
is under-geared for weapons can often still survive on accessory utility (mobility, immunity). Multiple named
difficulty modes (Classic/Expert/Master) let the *same* content be replayed at a harder setting for better
drops — progression is partly a dial the player turns, not just a track they walk.
**Takeaway for us**: gate tools by ore hardness (already the case — `R.HARD`/`R.MINEABLE`), but also gate a
*second*, independent power axis (accessories, `R.ACCS`) so a player behind on tools isn't fully stuck.
Consider one clear "hardmode-style" world-state flip later (e.g. going below the hell layer) that visibly
re-colors/re-hardens everything at once, rather than a smooth continuous ramp the whole way down.

### Minecraft — the block itself is the tutorial
Minecraft has almost no explicit tutorial text; the *tool-tier gate is the teacher*. You physically cannot
break stone with your hand at a useful rate, and cannot break iron ore with a wood/stone pick at all — the
game refuses the action rather than explaining it, so the player is forced to discover "I need a better tool"
by hitting a wall, not by reading. Each tier unlocks exactly the next tier's material and nothing else (wood
→ stone → iron → diamond → netherite), so the player is never holding a tool two tiers ahead of what they can
mine — the tool and the gate move together. Trading/villages exist as an optional shortcut around one tier
(iron) without breaking the chain for players who skip it.
**Takeaway for us**: this is already our core mining loop (`R.HARD`/`R.MINEABLE` refuse fast mining of
harder blocks). The design lesson to protect is: never let a later tool skip two tiers of gate at once (e.g.
don't let the very first pick ever mine uranium "slowly") — slow-but-possible at the wrong tier is fine
(matches Minecraft's iron pick still being *able* to mine stone, just wasteful), skipping straight to the
endgame material is not.

### Factorio — each science tier's automation pays for the next tier's grind
The core loop: early automation (belts/assemblers) removes the manual-crafting bottleneck on *iron/copper*,
which is precisely the raw material the *next* science tier's packs are made from. Chemical science needs oil
processing, which is only tractable once automation already exists to feed it a steady stream of basic
resources; utility/production science need whole intermediate chains (rails, circuits, engines) that would be
unbearable to hand-craft one at a time. The player never "grinds" a resource twice — once a tier is automated,
its output becomes an ambient background resource for the next tier, never revisited as a manual chore.
**Takeaway for us**: this is the single principle our tech tree is currently missing. Right now every tier is
still hand-mined (chop wood, swing pick, feed furnace by hand). `machines.lua`'s kits (boiler/turbine/
conveyor/crate) are exactly the Factorio move — but they need to sit *inside* the tier gates, not be a side
attraction: e.g. the conveyor should make ore-hauling from tier 3's biome trip bearable for tier 4, not just
be a toy. Building this in is the single highest-leverage change this doc recommends (see §3, Tier 4/5).

### Subnautica — the resource-equipment feedback loop, biome as the hazard *and* the reward
Depth/danger is the currency: a biome is dangerous *because* of what makes it worth entering, not despite it.
Blueprints and rare materials are scattered inside the exact zones a player's current gear can barely survive,
so every trip is "go a little further than is comfortable, come back with what unlocks going a little further
still." There is no quest marker forcing the order — the gating is entirely done by what the player's current
depth/pressure/heat tolerance can survive, which is a *soft* wall (you can go deeper and just die) rather than
Minecraft's *hard* wall (you literally cannot break the block).
**Takeaway for us**: our hazard side (heat/oxygen/hardness) should gate a biome/depth the same soft way —
oxygen (`R.o2`), lava burn, and cold (proposed) should be able to be *survived* through skill/timing at a
tier below where the game expects you, same as a Subnautica player who free-dives past their official depth
limit once. Reserve hard walls (can't-mine-it-at-all) for the tool-tier axis only, per the Minecraft lesson —
don't hard-wall biomes themselves.

### Valheim — a trophy from each boss unlocks the *tool*, not just a number
Every biome has exactly one boss gate, and the boss always drops the specific material/recipe unlock needed
to process that biome's *own* ore (e.g. the tin/copper age's boss unlocks the pickaxe tier that can mine the
next biome's iron equivalent). The biomes are also geographically arranged so a player passing through an
easier biome brushes past the next one's edge before they're ready — they see the danger ahead before they're
asked to enter it, which sets expectations without a cutscene.
**Takeaway for us**: our biome layout (forest/desert/snow/swamp as world-x bands, per `biomeAt`) already gives
"see the next biome's edge in the distance" for free, since biomes blend at a ~90px dithered border
(16:48 fix). The Valheim lesson we're missing is "boss/gate drop = the literal tool for the next step" — see
§3's biome-resource-to-recipe mapping, which is exactly this pattern applied to *resources* since we don't
have discrete boss gates.

### RimWorld — needs create goals; the storyteller times the pressure
RimWorld has almost no authored progression track: colonist needs (food, rest, mood, temperature) are what
generate goals, and a Cassandra/Phoebe/Randy "storyteller" watches the player's current wealth/threat level and
picks the next random event to match — hard pushes are timed to when the colony can plausibly survive them,
not on a fixed schedule. Research exists as a long tail (tribal → spacer tech) but is optional background
progress the needs-loop runs alongside, not the thing driving play minute to minute.
**Takeaway for us**: our existing survival stats (HP, `R.o2`, hunger if ever added) already generate
RimWorld-style goals for free ("I need food/air/warmth *now*") that run independently of the quest chain —
keep them that way rather than trying to route survival needs through `R.QUESTS`. The one importable idea:
scale hazard *pressure*, not just hazard existence, to the player's actual progress (e.g. deep-cave enemy
density or gas-pocket frequency should track `R.quest`/depth reached, the way a storyteller tracks wealth)
rather than being a flat world constant everywhere.

### Cross-cutting principles (used to write §3)
1. **Gating comes in two flavors and both are needed**: *hard* gates (can't-do-it-at-all — tool tier vs. ore
   hardness, Minecraft-style) and *soft* gates (can-survive-it-if-skilled — hazard/danger, Subnautica-style).
   Use hard gates for the tool/ore axis (already `R.HARD`/`R.MINEABLE`), soft gates for hazard axis (heat,
   O2, cold, radiation).
2. **One new verb per tier.** Not just numbers going up — wood age = *chop+dig*, iron age = *combat+basic
   electrics*, biome age = *travel+trade-with-the-map*, depth age = *build+automate*, endgame = *shield+
   contain*. A tier that only raises stat numbers reads as grind; a tier that adds a verb reads as progress.
3. **Feedback loops, not one-way consumption.** Factorio's automation-feeds-the-next-tier and Minecraft's
   trading are both "a completed tier gives you leverage on the *next* tier's grind," not just permission to
   enter it. Our machine kits should do this for ore-hauling once they exist inside the gate (§3, Tier 4).
4. **Teach with a wall, not a tooltip.** `R.HARD`/`R.MINEABLE` already do this — a wood pick physically
   bounces off granite slowly rather than a popup saying "you need a better pickaxe." Extend this same
   philosophy to any new hazard gate (an unshielded player near uranium should visibly hurt, not read a
   warning first).
5. **Backtracking should pay out.** A player who returns to the surface/forest after going deep should find a
   use for their new tools there (felling bigger trees faster, building a proper base) rather than the
   starting biome going "dead" the moment its resources are tapped — this is why Tier 1's forest is framed
   as the permanent home base below (O2/food/renewable wood), not a biome you leave behind.
6. **Biome-unique resources create direction on a map that has none.** Our world has no quest arrows — biome
   bands (forest/desert/snow/swamp) are the only spatial structure that exists. The single biggest opportunity
   named in the 16:52 ask ("biomes all have to have a purpose") is to put one *required* resource in each
   non-home biome so the horizontal map position becomes as meaningful as depth already is.
7. **Difficulty curves should be per-axis, not global.** Tool-hardness curve, hazard-intensity curve, and
   enemy-density curve can each ramp on their own schedule (RimWorld's storyteller principle) — a player who
   is ahead on tools but behind on hazard-prep (e.g. no O2 tank yet) should feel that mismatch specifically,
   not a single flat "this area is level 4" number.

**Sources**:
- [Terraria (Wikipedia)](https://en.wikipedia.org/wiki/Terraria)
- [Minecraft Beginner's Guide (Minecraft Wiki)](https://minecraft.wiki/w/Tutorials/Beginner%27s_guide)
- [Science pack (Factorio Wiki)](https://wiki.factorio.com/Science_pack)
- [Subnautica (Wikipedia)](https://en.wikipedia.org/wiki/Subnautica)
- [Valheim (Wikipedia)](https://en.wikipedia.org/wiki/Valheim)
- [RimWorld (Wikipedia)](https://en.wikipedia.org/wiki/RimWorld)

---

## 2. First 10 minutes — audit against what already ships

Drew's ask was to make the first 10 minutes airtight. Good news: **the exact chop→pick→bench→pick→coal→
furnace→iron chain already exists**, both as the real hard-gate mechanics (`R.HARD`/`R.MINEABLE`/`R.STATIONS`)
and as the literal quest text in `R.QUESTS` (`rpg.lua` lines 432-445, ids `wood`→`iron`):

| step | quest id | mechanic backing it |
|---|---|---|
| chop wood | `wood` | axe `only={WOOD,PLNT,GRSS}`, no gate |
| wood pick | `woodpick` | `R.PICKS[1]`, hand-craftable, `WOOD=6` |
| workbench | `bench` | `R.RECIPES` WORKBENCH, `WOOD=10`, by hand |
| stone pick | `pick` | `R.PICKS[2]`, `GRNT=6,WOOD=4`, needs workbench — granite is `HARD=3`/`MINEABLE=2`, too slow for the wood pick (`power=1`) to be worth it, which is exactly the Minecraft "the wall teaches you" pattern |
| coal | `coal` | surface-depth vein (`d>20`), `MINEABLE=1`, minable with either pick |
| furnace | `furnace` | `GRNT=20,COAL=5`, must be **lit with a real torch** (`nearStation` checks for actual fire/>600K in the box) — this is the one place a *hazard-adjacent* mechanic (real fire) already gates a crafting step, nicely on-theme for "real physics" |
| iron | `iron` | smelt `METL` from `IRON=2` at the lit furnace |

This chain is airtight as designed — no changes needed. The only two risks are pacing risks, not design risks,
and both are things to *watch*, not build:
- **Granite/coal depth (`d>20`) must actually be reachable inside ~10 minutes of digging** from the surface —
  worth a live timed playtest once `@world`'s gen rework is git-committed, since strata bands (Round 2 idea)
  will change exactly how much rock sits between the surface and `d=20`.
- **The wood-pick-to-granite grind must read as "slow but possible," never as a wall** (Minecraft's own
  wood-pick-can-still-mine-stone lesson) — confirm `R.HARD.GRNT=3` against `R.TOOLS.pick` swing timing doesn't
  make granite feel unbreakable before the stone pick.

No new quests are needed for the first 10 minutes. Everything below extends the chain **after** `iron`.

---

## 3. The concrete tier plan (Tiers 3-6 are new; Tiers 1-2 already ship)

Existing chain (§2) already *is* Tier 1 (Wood Age) and the front half of Tier 2 (Iron Age). This section
covers Tier 2's back half through Tier 6, each with the six facets asked for. "NEW" marks anything that
doesn't exist yet in `R.RECIPES`/`R.MINEABLE`/`world.lua` and needs an owner.

### Tier 1 — Wood Age *(ships today, §2)*
Home biome: forest/surface. No hazard beyond none. Verb: chop + dig. No change recommended.

### Tier 2 — Iron Age *(ships today, extending it slightly)*
- **Resources**: `IRON` (`d>60`), `CU` (`d>100`, if `HASCU`), `GOLD` (`d>160`) — already generated by `oreAt`.
- **Where**: shallow caves, biome-independent — any biome's underground looks the same at this depth today
  (flagged to `@world` as intentional for this tier only: Iron Age is the *last* tier that should be
  biome-independent, everything after should not be).
- **Unlocks (existing)**: `ANVIL` (`METL=8`), iron pick (`R.PICKS[3]`), iron sword (`R.SWORDS[2]`), and the
  electrics starter set already in `R.RECIPES` (`PSCN`, `LEDL`, `WIFI`, `CU` refining) — these are currently
  reachable at Tier 2 but nothing *requires* them yet. Recommend (NEW, `@lead`/quest-only, no code beyond a
  quest line): a quest nudging the player to craft one `WIFI` pair or one `LEDL`, so the electrics recipes
  aren't invisible dead content before the machine-kit tiers need them.
- **Hazard**: `R.HARD.IRON=4` vs. stone pick `power=2` — slow, teaches "I want the iron pick," matching
  Minecraft's tool-tier wall.
- **New verb**: combat (iron sword) + basic electrics.
- **Quests**: existing `furnace`→`anvil`→`ironpick` cover this; no new IDs needed.

### Tier 3 — "The Biome Trip" (SHIPPED by `@world`, 17:40/7c5d4f8 — supersedes this doc's original proposal)
This is the tier where horizontal position on the map starts to matter as much as depth. This doc originally
proposed three *invented* resource names (Sun Quartz/Permafrost Ice/Marsh Gas) to make each biome exclusive;
`@world` shipped the same structural idea same-day but grounded entirely in **real, already-existing
materials boosted per biome** instead of new fictional variants - a better fit for this codebase's standing
"real physics, no invented mechanics" bar (see their 17:40 hub commit message verbatim), so this section is
rewritten to match what's actually live rather than what was proposed. `R.biomeInfo[name] = {hazard, offers}`
and `R.depthInfo` (the `DEPTH_BANDS` array) are now exposed on `R` for any plugin/quest to read directly.

| biome | real resource boosted/added | hazard (soft gate, shipped) | new verb |
|---|---|---|---|
| Desert | brick-heavy ("fossil/sedimentary") strata; ruins+chests up to ~65%/cell (vs. flat 30% elsewhere); real water+palm oases | midday-sun HP drain while exposed at the surface (`isMiddayHot`), gone once you dig in | first "read the clock before you travel" verb - oases + shade are the counterplay |
| Snow | boosted `QRTZ` crystal-cave odds ("frozen caves with rare crystals") | hypothermia drain, ~5s grace, cancelled by any real nearby FIRE/LAVA/PLSM/hot particle (`nearHeatSource` - a carried torch works) | first insulation/heat-source-management verb |
| Swamp | boosted `CLST` clay veins; real `OIL`/`GAS` pockets underground (flammable/explosive stock physics, zero new elements); `VINE` decor | poisoned surface water - `SLTW` blocks O2 exactly like water (core's `BADGAS`), rare `CAUS` patches burn on contact | first "read the water before you swim" verb |
| Forest (home) | ~12% wild-beehive `GOLD` cache hidden in oak canopies | none - stays the safe permanent base | (no new verb - home stays home) |

- **Reward structure**: unlike the original three-invented-items proposal, there's no single required
  "turn-in" item yet - the hazards+resource boosts are live, but nothing in `R.QUESTS` reads them. Section 4
  below updates the recommended `biometrip` quest to check real inventory (`QRTZ`/`OIL`+`GAS`/`BRCK`) instead
  of the fictional names, so it's implementable against what's actually shipped with zero further `@world`
  work.
- **Depth is now signposted too**: crossing into Coal Seams/Iron Belt/Copper Vein/Gold Reef/Flooded Caverns/
  Uranium Shelf/The Deep/Bedrock fires a one-time `R.say()` per `DEPTH_BANDS` - Tiers 2/5 already had the
  right depth gates, they just had no player-facing signpost before this; no doc change needed there, just
  noting the depth axis now teaches itself the same way the biome axis does.
- **New verb overall for this tier**: *travel with a purpose* - the map's horizontal axis becomes legible.

### Tier 4 — Automation (NEW machine-kit *integration*, not new kits — `machines.lua`'s existing kits already do this if put behind the gate)
- **Resources**: none new — this tier is about *not hand-carrying* Tier 1-3 resources anymore.
- **Where**: player's own base, any biome (ideally forest/home per §1.5's backtracking principle).
- **Unlocks**: `BOILER`+`TURBINE`+`WIRECOIL`+`CONVEYOR` (all already exist in `machines.lua`) — recommend a
  quest that requires the player to actually *chain* two kits (e.g. a conveyor feeding a furnace, or a boiler
  running a turbine sparking a `LEDL`) rather than just crafting one kit and forgetting it, so the Factorio
  "automation removes the previous tier's grind" payoff is felt, not just unlocked.
- **Hazard**: none new; existing boiler vent-breach/coal-ignition mechanics already documented by `@machines`
  (13:41 hub log) are the hazard here — a badly-built boiler already fails realistically.
- **New verb**: *automate* — first time in the game a system runs without the player's hand on it.
- **Quest** (see §4 exact text): requires a placed+running boiler-to-turbine-to-conductor chain.

### Tier 5 — Deep/Hell Zone (existing gen, currently under-quested)
- **Resources**: `DMND`/`TTAN`/`BRMT` (`wy >= DEPTH-300`, already generated), plus `URAN`/`DU` (`d>420`,
  already generated, biome-independent).
- **Where**: the deep zone near `R.DEPTH`, the one part of the map that's correctly biome-independent (going
  deep enough eventually erases surface biome differences everywhere — this matches every genre example in
  §1: Terraria's Hardmode reseeds the *whole* world at once, not per-biome).
- **Unlocks**: `TTAN` plate (`STEL=2,DU=1`, existing recipe), diamond pick (`R.PICKS[5]`, existing).
- **Hazard (NEW)**: radiation near `URAN`/`DU` veins before they're mined and refined — idea-bank's
  "Radiation zones near ore/reactor" (already speced, owner `@enemies`/`@machines`) is the exact mechanic;
  recommend gating it formally into this tier rather than leaving it unassigned — mitigated by `LEAD`
  shielding, which is **NEW**: `LEAD` isn't in `R.RECIPES` yet despite being in `materials-catalog.json`
  (35 W/mK, real gamma-shielding) — flag to `@items`/`@machines` as a small new recipe:
  `LEAD` bar (workbench or furnace, from a `LEAD` ore vein `@world` would need to add near the uranium band).
- **New verb**: *shield* — first tier where standing near your own resource is actively dangerous without
  prep, distinct from the ambient hazards (lava/O2) that came before.

### Tier 6 — Reactor / Endgame (already fully speced in the idea bank as #2, currently P2/unassigned)
- **Resources**: none new — every element (`UO2`, `B4C`, `GRPH`/`ZIRC`, `NAK`, `TRBN`, `TEG`) is already live
  in `define_power_elements.py` per the idea bank's own note that this is "a quest-chain/UI task, not an
  engine task."
- **Where**: built at the player's base using Tier 5's `URAN`/`DU` fuel and `LEAD` shielding.
- **Unlocks**: a working micro-reactor — steam from `NAK`-cooled `UO2` lattice through a `TRBN`, sparking a
  conductor; this is the natural home for the "8-tier tech tree" P2 idea already logged in the roadmap.
- **Hazard**: `B4C` control rods must actually absorb the neutron flux (real mechanic, no new hazard needed)
  — an unshielded or unmoderated lattice already runs hot per the live element behaviours.
- **New verb**: *contain and generate* — the capstone verb, combining every prior tier's material (steel
  tools, biome accessories for survivability while building it, `LEAD` shielding, automation wiring).
- **Quest**: see §4 — reuses the roadmap's already-planned reactor quest chain, just now anchored to a
  specific `R.QUESTS` entry instead of being a P2 backlog line with no player-facing marker.

---

## 4. Exact `R.QUESTS` entries recommended (for `@lead` — `rpg.lua` is lead-only, this file never edits it)

Continuing the existing array after the last shipped entry (`id="steel"`), same style/fields as the current
twelve. Field names referenced (`R.stats.mined`, `R.stats.crafted`, `R.inventory`, `R.stations`,
`R.nearStation`) all already exist and are used identically to the existing entries above them.

```lua
-- Tier 2 back half: make the electrics starter set required, not just reachable
{ id="wifi", txt="Craft a WIFI wireless link (workbench, needs Copper + Gold)", done=function() return R.stats.crafted.WIFI end, reward={CU=4} },

-- Tier 3: the biome trip - ANY ONE of the three real-material boosts @world shipped (17:40/7c5d4f8) counts,
-- a real choice not a checklist. Updated from this doc's original fictional-resource draft to match what's
-- actually live: boosted QRTZ (snow), real OIL/GAS pockets (swamp), brick-heavy strata + ruin chests (desert).
{ id="biometrip", txt="Bring back proof of a biome trip: Quartz from the snow caves, Oil/Gas from the swamp, or Brick from a desert ruin",
  done=function() return (R.inventory.QRTZ or 0) >= 4 or (R.inventory.GAS or 0) + (R.inventory.OIL or 0) >= 4 or (R.inventory.BRCK or 0) >= 8 end,
  reward={STEL=3} },

-- Tier 4: automation must actually run, not just exist - requires a live boiler->turbine->conductor chain
{ id="automate", txt="Chain a Boiler into a Turbine into a sparked conductor and let it run",
  done=function() for _, m in ipairs(R.machines or {}) do if m.kind == "TURBINE" and m.sparkedEver then return true end end; return false end,
  reward={CU=6, WOOD=10} },

-- Tier 5: deep zone
{ id="titanium", txt="Reach the deep zone (within 300m of the world floor) and mine Titanium", done=function() return (R.stats.mined.TTAN or 0) >= 1 end, reward={DMND=1} },
{ id="lead", txt="Smelt Lead shielding (new recipe, @items/@machines) before mining Uranium", done=function() return (R.stats.crafted.LEAD or 0) >= 1 end, reward={GOLD=3} },
{ id="uranium", txt="Mine Uranium at depth 420m+ while shielded", done=function() return (R.stats.mined.DU or R.stats.mined.URAN or 0) >= 1 end, reward={STEL=6} },
{ id="diamondpick", txt="Forge a diamond pick", done=function() return R.stats.crafted["diamond pick"] end, reward={GOLD=5} },

-- Tier 6: reactor capstone
{ id="reactor", txt="Build a UO2 + B4C + GRPH/ZIRC reactor lattice, run NAK coolant to a boiler, and spark a Turbine off the steam",
  done=function() for _, m in ipairs(R.machines or {}) do if m.kind == "REACTOR" and m.online then return true end end; return false end,
  reward={DMND=5} },
```

Notes for `@lead` on the quests that reference fields nothing currently sets (`m.sparkedEver`,
`m.kind=="REACTOR"`/`m.online`, `R.stats.crafted.LEAD`): these are intentionally written *last*, describing
the field a future `@machines` change would need to set, not a claim that they exist today - flagged
explicitly as **new system, not yet implemented** rather than silently assuming it. **`wifi` and `biometrip`
are now both runnable today with zero further changes from anyone** - `QRTZ`/`WIFI`/`GAS`/`OIL`/`BRCK` all
already exist and `@world`'s 17:40 biome-purpose commit already boosts/places the three `biometrip` materials
per-biome, so this pair can go straight into `R.QUESTS` as-is.

---

## 5. New systems/recipes flagged (owner summary)

- `@world`: **done** (17:40/7c5d4f8) - biome-purpose resources/hazards/signposts all shipped using real
  materials, no invention needed. Nothing further required for the Tier 3 quest to work.
- `@items`/`@machines`: still open, both still good ideas layered on top of what's now real rather than on
  fictional materials - **Focusing Lens** (desert, `SAND=2,QRTZ=2`, `@items` workbench), **Frost Ward**
  accessory (snow, `ICE=6,CU=2`, `@items` workbench), **Gas Canister** (swamp fuel, `GOO=6` + the real `GAS`/
  `OIL` `@world` now generates in swamp caves, `@machines` anvil), and a **Lead** bar/shielding recipe
  (`@items`/`@machines`, flagged missing before Tier 5's uranium/radiation hazard is fair).
- `@lead`: the `R.QUESTS` entries in §4 - `wifi` and `biometrip` are implementable today as-is; the rest wait
  on the `@items`/`@machines` recipes above and the still-P2 reactor structure.

---

## 6. Summary table (for the hub post)

| Tier | Verb gained | Home resource | Gate |
|---|---|---|---|
| 1 Wood Age | chop + dig | forest (wood, surface stone) | none (ships today) |
| 2 Iron Age | combat + electrics | any shallow underground | tool hardness (ships today) |
| 3 Biome Trip | travel with purpose | desert **or** snow **or** swamp (choice, **shipped** 17:40) | soft hazard (heat/cold/poison-water, **shipped**) |
| 4 Automation | automate | base (any biome, ideally forest) | none — payoff tier |
| 5 Deep Zone | shield | hell layer (biome-independent) | radiation (soft, new) |
| 6 Reactor | contain + generate | base, using Tier 5 fuel | none new — assembly capstone |
