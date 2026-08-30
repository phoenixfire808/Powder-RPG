# Powder RPG — design (2026-08-26)

Status note up front: **an MVP already exists and runs**, at `D:/powder-toy/scripts/lua/rpg.lua`
(dated today, loaded via `execute_lua`, state at `PBX.state.rpg`). This document treats that file as
the baseline, keeps everything it already gets right, calls out one load-bearing bug found by reading
the engine source (`AssertMutableSimEvent`, see §1.3 and §8), and specifies the full design around it.
Nothing in this document requires touching the running game; no MCP mutating tool was called to write
it.

Sources read directly for this design (no web search was available this session — the session's
search budget was already exhausted before this task started; see §9 for what that means for
citation of prior art):

- `D:/powder-toy/knowledge/tpt-lua-api-cheatsheet.md`, `EXTENSION_SPEC.md`, `BLUEPRINT_SPEC.md`
- `D:/powder-toy/bridge_src/00_util.lua` (referenced, not re-read in full — its contract is fixed per spec), `20_behaviors.lua`, `30_colony.lua`, `40_worker.lua`, `50_tasks.lua`, `70_people.lua`
- `D:/powder-toy/powder_ext/people_tools.py`, `schemas.py` (execute_lua/run_test/blueprint_build entries)
- `D:/powder-toy/scripts/lua/chem_kinds.lua`, `power_kinds.lua`, `rpg.lua` (the existing MVP)
- `D:/powder-toy/knowledge/materials-catalog.json`, `materials-catalog-packs.json`,
  `power-elements-2026-08-26.json`, `chemistry-rules.json`, `element-interactions-part1.json`
- `D:/The-Powder-Toy/src/simulation/elements/STKM.cpp`, `STKM2.cpp`, `FIGH.cpp`,
  `src/simulation/Stickman.h` (`MAX_FIGHTERS = 100`), `src/lua/LuaEvent.cpp`,
  `src/gui/game/GameController.cpp` (native key bindings, lines ~611-730)

---

## 1. Architecture

### 1.1 Deployment model — a live add-on, not a bridge module

`rpg.lua` is **not** added to `bridge_src/` and is **not** compiled into `build_autorun.py`'s
concatenation. That would require an author slot under `EXTENSION_SPEC.md` and a game restart on
every change. Instead it follows the exact pattern already proven by `chem_kinds.lua` and
`power_kinds.lua`: a standalone file under `scripts/lua/`, deployed by reading its contents and
POSTing them as the `code` field of the `execute_lua` MCP tool (`powder_ext/schemas.py:462`,
`"Lua chunk to run in the live bridge interpreter (loadstring+pcall)... can define/patch elements and
mutate PBX.state.behaviors.kinds"`). The bridge's dispatcher for this is `bridge_src/_base/bridge_base.lua`
line 946: `action == "executeLua"` → `loadstring(code)` → `pcall(fn)`. This is the only mechanism
available that does not touch a file another author owns.

`rpg.lua` reads `PBX` as a pre-existing global (installed by `00_util.lua`, already loaded before any
`execute_lua` call runs, since autorun.lua loads first) and claims exactly one key:
`PBX.state.rpg` — same ownership discipline as `EXTENSION_SPEC.md` §2.7 (`colony`, `worker`, `tasks`,
...). Re-running `execute_lua` with the file's contents is idempotent and is how a live update ships:
the script checks `if not R.registered then event.register(...) end` before installing handlers, so a
hot reload never double-registers.

### 1.2 State shape

```lua
PBX.state.rpg = {
  version, seed, day, frame, deaths,
  inventory   = { [ELEMENT_NAME] = count, ... },
  selected    = "IRON" | nil,
  hud, craftOpen, active,
  surface     = { [x] = surfaceY, ... },   -- terrain heightmap, for spawn/enemy placement
  quests      = { [questId] = { status, progress } },
  tier        = 1,           -- highest unlocked tech tier
  player      = particleIndex,   -- cached STKM index, re-resolved via R.playerId()
  msg         = "last HUD toast",
}
```

Full JSON Schema for the *persisted* subset (see §1.4) is in §10.

### 1.3 The one architectural bug worth fixing before anything else is built on top of it

`EXTENSION_SPEC.md` §2.4 and `40_worker.lua`'s own header comment are explicit and cite a source
line: `sim.partCreate` asserts a mutable-sim event (`LuaSimulation.cpp:394` →
`AssertMonopartAccessEvent` → `AssertMutableSimEvent`) which **the socket/HTTP-handler thread does not
satisfy**. That is exactly why `40_worker.lua`'s `colonySpawnWorkers` and `30_colony.lua`'s
`colonyDestroy(killWorkers=true)` wrap every `sim.partCreate`/`sim.partKill` in `PBX.defer(...)` rather
than calling them straight from the `PBX.register` handler body.

`bridge_base.lua`'s `executeLua` action (line 946) runs the submitted chunk from **the same handler
context** — there is nothing in the dispatcher that distinguishes "an action registered by
`PBX.register`" from "a chunk handed to `loadstring`". The current `rpg.lua` defines `R.generate()`
(hundreds of `sim.createBox`/`sim.partCreate` calls) and exposes `R.start(seed)` which calls it
directly. If `R.start(seed)` is invoked *by sending it straight through `execute_lua`* (the obvious way
to kick off a new game from the MCP side), it will hit the identical assertion `40_worker.lua`'s
authors had to design around, and the call will very likely come back as a caught runtime error from
`pcall(fn)` rather than actually generating a world — this has not been observed live (no game was
touched to write this doc), but it follows directly from the sourced mechanism, so treat it as a
confirmed architectural risk, not a maybe.

**Fix, matching the existing codebase's own pattern exactly**: never call `R.generate`/`R.spawnPlayer`
synchronously from an `execute_lua` request. Instead:

```lua
-- inside rpg.lua, replace the direct R.start(seed) call path with a flag:
function R.requestStart(seed) R.pendingSeed = seed; R.active = true; return "queued" end

-- and inside the existing onTick (already runs on the sim thread — TICK is one of the
-- native event types LuaEvent.cpp registers, and 40_worker.lua/50_tasks.lua's own
-- PBX.onTick hooks do exactly this kind of heavy sim mutation safely):
local function onTick()
  if R.pendingSeed then local s = R.pendingSeed; R.pendingSeed = nil; R.generate(s) end
  ...
end
```

`rpg_start` (the Python/MCP tool, §1.5) then only ever sends
`execute_lua {code = "PBX.state.rpg.requestStart(7)"}` — a cheap table write, safe on any thread — and
polls `rpg_status` until `PBX.state.rpg.pendingSeed == nil` and `PBX.state.rpg.player ~= nil`, the same
poll-a-flag idiom `PBX.defer`/`jobStatus` already establishes for every other long-running mutation in
this codebase. `R.save()` has no such problem — it is a plain `io.open`/`string.format`, no `sim.*`
call in it at all — so `rpg_save` may keep calling it synchronously exactly as the MVP already does.

### 1.4 Persistence

Exactly the `10_registry.lua`/`30_colony.lua` pattern: `PBX.save(name, tbl)` writes
`D:/powder-toy/knowledge/<name>.json`; `PBX.load(name)` returns the table back or `nil`. Reusing that
(rather than the MVP's own bespoke `io.open("D:/powder-toy/knowledge/rpg-save.json", ...)` hand-rolled
writer) buys two things for free: `PBX.encode`'s existing nil/array/depth-cap-8 safe JSON encoder
(hand-rolled string concatenation of a `pairs(R.inventory)` table is exactly the class of thing
`EXTENSION_SPEC.md` §2.2 calls out as unsafe/inconsistent — the MVP's current `R.save()` already
special-cases this correctly for the flat inventory map, but would not generalise to the richer schema
below), and automatic restore-on-restart symmetry with every other module in this codebase (the
existing `R.save()` has no matching `R.load()` at all — `rpg-save.json` is written but never read back).

```lua
function R.save()
  PBX.save("rpg", {
    version = R.version, seed = R.seed, day = R.day, frame = R.frame, deaths = R.deaths,
    inventory = R.inventory, selected = R.selected, tier = R.tier,
    quests = R.quests, surface = R.surface,
  })
end
-- at load time, mirroring 30_colony.lua's restore-at-require-time pattern:
do
  local saved = PBX.load("rpg")
  if type(saved) == "table" then
    for k, v in pairs(saved) do R[k] = v end
  end
end
```

### 1.5 Python-side MCP tools

New file `D:/powder-toy/powder_ext/rpg_tools.py`, same shape as `people_tools.py`: a `HANDLERS` dict,
reusing `_call_bridge`/`_settle`/`_budget_from` from `colony_tools.py` (per that module's own
"central-utilities rule" comment — a second bridge-call/poll implementation is treated as a bug even
if it works). Three tools, all going through the existing `executeLua` bridge action (no new bridge
action/module needed — this keeps `rpg.lua` entirely out of `bridge_src/`, per §1.1):

| MCP tool | request | bridge call | notes |
|---|---|---|---|
| `rpg_start` | `{seed?: int, tier?: int}` | `execute_lua {code:"PBX.state.rpg.requestStart(<seed>)"}` | fire-and-poll; §1.3 |
| `rpg_status` | `{}` | `execute_lua {code:"return json_of(PBX.state.rpg summary + STKM life/x/y)"}` | read-only |
| `rpg_save` | `{}` | `execute_lua {code:"return PBX.state.rpg.save()"}` | synchronous, safe (§1.3) |

`rpg_status`'s Lua payload (the exact chunk `rpg_status` sends as `code`):

```lua
local R = PBX.state.rpg or {}
local i = R.playerId and R.playerId()
local hp = i and sim.partProperty(i, "life") or nil
return PBX.encode({
  active = R.active, seed = R.seed, day = R.day, frame = R.frame, deaths = R.deaths,
  tier = R.tier, hp = hp, alive = i ~= nil,
  inventory = R.inventory, selected = R.selected, msg = R.msg,
  quests = R.quests, pendingSeed = R.pendingSeed,
})
```

`powder_ext/schemas.py` additions (three more entries in `TOOL_SCHEMAS`/`TOOL_DESCRIPTIONS`/
`TOOL_READONLY`/`TOOL_ORDER`, `rpg_start`/`rpg_save` both `False` for read-only, `rpg_status` `True`) —
per `EXTENSION_SPEC.md` §5/§6.1, `powder_toy_mcp.py` itself is never edited by an agent; the central
integrator wires `rpg_tools.HANDLERS` in exactly as `people_tools.PEOPLE_HANDLERS` already is.

---

## 2. World generation

### 2.1 Why this is bulk procedural code, not a Powder Blueprint

`BLUEPRINT_SPEC.md`'s own stated limits are `{"parts": 512, "primitives": 2048,
"MAX_BLUEPRINT_CELLS": 4096}`. The playable canvas is `612 x 384 = 235,008` pixels. A full-world
terrain fill is 50-500x over the blueprint compiler's cell budget by design — that budget exists so a
small model's blueprint compiles fast and predictably, not to gate world generation. This is exactly
why the existing MVP's `R.generate()` bypasses the Blueprint DSL entirely and calls `sim.createBox`/
`sim.partID`/`sim.partKill`/`sim.partCreate` directly in a plain Lua loop. That choice is correct and
should stay; **what the "as a blueprint/pipeline using our modules" requirement should mean in
practice is: discrete, repeated structures within world-gen — ore-vein pockets, campfires, a starting
shelter, later crafting stations — are authored as small parametric Blueprint modules (well inside the
4096-cell budget per instance) and *invoked* from inside the procedural generator via
`blueprint_build` for placement, while strata/cave/water bulk fill stays hand-written Lua.**

### 2.2 Pipeline (extends the existing `R.generate(seed)`, same call sequence)

1. **Clear** — `sim.clearSim()`.
2. **Strata** (per-column, `x = 0..611`): height `h = 150 + noise(x, seed) * 70` (cheap 3-octave sine
   noise, already implemented and fine — a real Perlin/simplex port is a "full" nice-to-have, not a
   blocker). Layers, using **real materials from the catalog**, worst-catalog-entry-first so an absent
   custom element degrades gracefully to a stock one (the MVP already does this: `has("GRNT") and
   "GRNT" or "DMND"`):
   - surface: `PLNT` (grass, native TPT growth via the `grower` behaviour already ships on stock PLNT)
   - topsoil (10px): `CLST` (native clay) — a "full" biome variant swaps this for `SAND` in a desert
     biome column range, real analogue of arid vs. temperate topsoil
   - midsoil/rock: `STNE` down to bedrock band
   - bedrock (bottom 13px): `GRNT` (custom-catalog granite, `highTemperature: 1523.15`,
     `hardness: 75`) if defined this session, else stock `DMND` as an always-available hard floor
   - `sim.createBox(x1,y1,x2,y2,elementId)` per band (native, one call per column per band — this is
     the "why it's not a blueprint" case: 612 columns × 4 bands = ~2450 primitive calls, still cheap
     because `createBox` is a single native op per call, not a Lua loop over cells).
3. **Biomes** (new, not in the MVP): tag each column with a biome id from a second, slower noise
   channel (`noise(x, seed*3.1)`), 3 biomes to start — Plains (as above), Desert (topsoil `SAND`
   instead of `CLST`, surface deco sparser), Frozen (surface `SNOW`/`ICE` cap, water pockets become
   `ICE` not `WATR`). Biome only changes *which real material* fills a layer — the layering algorithm
   itself is biome-independent.
4. **Water table** — pond pockets carved into topsoil, filled `WATR` (already implemented). "Full"
   addition: a horizontal water-table plane at a fixed depth band where any cave carved below it
   auto-fills with `WATR` on generation (real hydrology — caves below the table flood), giving a reason
   to need a pump/pressure-chamber module (`BLUEPRINT_SPEC.md`'s `pressure_chamber` module,
   `PUMP`+`VACU` inside a wall grid) to drain a flooded mine — a natural mid-game objective.
5. **Caves** — random ellipse carve-outs via `sim.partID`/`sim.partKill` (already implemented).
6. **Ore veins**, depth-ordered exactly as the MVP already has it, each vein a cluster of small
   ellipses stamped into rock — this is real geology (shallower/lower-temperature ores form nearer
   surface, e.g. coal seams vs. deep uranium deposits is a real depositional-depth pattern, not just a
   difficulty gate):

   | vein | depth band (y) | real element |
   |---|---|---|
   | `COAL` | 190-260 | stock, hardness 18 |
   | `IRON` | 220-300 | stock, hardness 49 (native metallic iron, standing in for smelted-grade ore — see §3.4 for why there is no separate "iron ore" element) |
   | custom `CUOR` (new, copper-bearing rock, `defineElement` this session) | 250-330 | smelts to custom `CU` (already in `power-elements-2026-08-26.json`, `PROP_CONDUCTS`, 400 W/mK) |
   | `GOLD` | 270-350 | stock |
   | `URAN` | 320-368 | stock, `PROP_RADIOACTIVE` — deepest, most dangerous (§4, §5, §8) |

7. **Trees** — `WOOD` trunk + `PLNT` canopy ellipse (already implemented).
8. **Lava pockets** at the very bottom (already implemented) — real magma-near-bedrock geology, and
   the in-fiction heat source for smelting once piped/mined near.
9. **Structures via Blueprint modules** (new): call `blueprint_build` (not raw Lua) to place, at fixed
   or landmark-relative coordinates chosen by the generator:
   - a starter shelter: reuse the existing builtin `house` module
     (`{"module":"house","params":{"width":24,"height":16,"wall_element":"BRCK","roof_element":"WOOD"}}`)
   - a `furnace_station` module (new, register via `blueprint_module_save` — see §3.5)
   - `ore_vein_marker` deco (cosmetic, optional) so a found-but-unmined vein reads visually as a POI.

   Every `blueprint_build` call here should be issued `dry_run:false` from the same tick-thread-safe
   context as §1.3's fix (i.e., driven by `PBX.onTick`, not fired synchronously from an `execute_lua`
   request), since `blueprint_build`'s underlying draw path also calls `sim.partCreate`/`createBox`.

---

## 3. Player

### 3.1 Control mapping (verified against engine source, not assumed)

`STKM` is the built-in player stickman (`src/simulation/elements/STKM.cpp`). Only one may exist at a
time (`createAllowed`: `sim->elementCount[PT_STKM] <= 0 && !sim->player.spwn`) — the RPG must track and
respawn *this one* particle, never spawn a second. Native controls, confirmed in
`src/gui/game/GameController.cpp` lines 611-730 (this is C++ that runs regardless of any Lua script;
it fires **after** `commandInterface->HandleEvent(KeyPressEvent{...})` returns `true` — a Lua
`event.keypress` handler that returns `false` **suppresses** the native STKM movement for that key):

| action | STKM (player 1) | STK2 (player 2, unused here) |
|---|---|---|
| left | `SDLK_LEFT` (comm bit `0x01`) | `SDL_SCANCODE_A` |
| right | `SDLK_RIGHT` (comm bit `0x02`) | `SDL_SCANCODE_D` |
| jump | `SDLK_UP` (comm bit `0x04`) | `SDL_SCANCODE_W` |
| use/place held element | `SDLK_DOWN` (comm bit `0x08`) | `SDL_SCANCODE_S` |

Movement, jumping and the native "place held element downward" action are **free** — do not
reimplement them in Lua; just don't return `false` from `event.keypress`/`event.keyrelease` for arrow
keys. The existing `rpg.lua onKey` already gets this right by construction (it only inspects
`c`/`h`/`k`/digit keys and returns `false` only for those — arrows fall through untouched, §6).

The "held element" (`parts[i].ctype`, set via `Element_STKM_set_element`) is whatever gas/liquid/
energy/powder-with-`Falldown`-set element the player last touched — this is TPT's native "loadout"
slot, separate from our own `R.inventory`/`R.selected`. It only matters if the RPG ever wants the
native down-arrow "shoot" behaviour (e.g. a water gun, a dirt-slinger) — the MVP's own mine/place
system (mouse-driven, §3.3) does not use it and that is the right call; conflating the two would mean
the player accidentally "fires" their pickaxe material downward on every down-arrow jump-cancel.

### 3.2 HP, damage, and why "hunger" should stay a stretch goal

`parts[i].life` **is** HP (default 100, native cap enforced only ad hoc — e.g. `PLNT` heals to 100 max,
STKM.cpp:423-429). Real, sourced damage sources (`Element_STKM_interact`, STKM.cpp:635-712, called for
both feet and for anything found near the head):

- `SPRK` contact: `32-51` damage per hit, unless the player's held element is `LIGH`.
- Any neighbour `>=323 K` (50°C) or `<=243 K` (-30°C), unless it's a heat-insulator or (rocket boots +
  `PLSM`): `+2` damage **per frame** it stays true.
- Any `PROP_DEADLY` neighbour: `ACID` is `+5`, everything else `PROP_DEADLY` is `+1`.
- Any `PROP_RADIOACTIVE` neighbour: `+1`.
- Separately, in the head-sensing loop (STKM.cpp:410-437, not gated by any of the above): a `NEUT`
  particle within 2px of the head **halves current life** (`life -= (102-life)/2`, or `life *= 0.9` if
  already above 100) and is consumed. **A leaking reactor is a real, mechanically enforced player
  hazard**, not just flavour text — see §8.
- `temp < 243 K`: `-1` life/tick continuously (native cold-damage, independent of the above).
- `life < 1`, or being caught in wind `pv >= 4.5` while not using a fan: instant death
  (`die()`, STKM.cpp:97-118 — drops the held element in a cross pattern around the corpse, or adds
  pressure if `playerp->fan`).

Given all of the above, **hunger is correctly scoped as a "full" feature, not MVP** (§7): the engine
already provides a punishing, physically-grounded threat model (heat, radiation, electricity, cold,
suffocation-by-wind) without adding a starvation clock on top. If added later: a `R.hunger` counter
(0-100) ticking down once per in-game "day" (`R.frame % 3600`, already the day-length constant in the
MVP), consumable by eating inventory food items (any harvested `PLNT`), and at `0` either disabling the
native `PLNT`-heal (STKM.cpp already caps healing "if life<100", so a hungry player simply healing
slower is a light-touch way to express it) or applying a small `sim.partProperty(i,"life",...)` tick
of our own. Not simulated as its own chemistry — food is inventory bookkeeping, matching the "station
recipe" tier described in §3.5.

### 3.3 Tools, reach, mining, and hardness-gated pickaxe tiers

Mining and placing are **not** native TPT mechanics — they're the RPG's own mouse-driven logic
(already implemented, kept as-is): `event.register(event.mousedown, onMouse)`, button `1` (LMB) =
mine, button `3` (RMB) = place. `sim.mousedown`'s reach check is a simple squared-distance test against
the cached player position (`playerPos()` → `sim.partPosition(i)`), radius `R.REACH = 46` px.

**New for the full design: hardness-gated pickaxe tiers**, using each element's real `Hardness` stat
(the same stat TPT's own mining tool and this codebase's `materials-catalog.json`/
`element-interactions-part1.json` already carry — read live via `element_facts`/`material_catalog`,
not hand-copied, since custom elements can be redefined mid-session). Confirmed real values from
`element-interactions-part1.json` / `materials-catalog.json`: `SAND=1`, `GYPS=8`, `LMST=10`,
`MRBL=12`, `COAL=18`, `RCNC=25`, `ASPH=45`, `IRON=49`, `FBRK=60`, `SDST=65`, `BSLT=70`, `GRNT=75`.
(`GOLD`, `WOOD`, `DMND`, `URAN`'s exact `Hardness` were not read for this document — confirm with
`element_facts {element:"GOLD"}` etc. before hard-coding the table below; the *shape* of the tier
system does not depend on the exact numbers.)

| tier | tool | crafted from | can mine (hardness ≤) | unlocks |
|---|---|---|---|---|
| 0 | bare hands | — | 5 | SAND, loose dirt |
| 1 | flint pick | `WOOD x2 + STNE x3` | 20 | GYPS, LMST, MRBL, COAL |
| 2 | bronze pick | `BRNZ x3` (catalog alloy, already defined) | 50 | RCNC, ASPH, IRON (surface-adjacent) |
| 3 | iron pick | `IRON x3 + WOOD x1` | 80 | FBRK, SDST, BSLT, GRNT |
| 4 | steel pick | `STEL x3` | 90 | deep rock, custom `URIR` (uranium-bearing rock, new) |
| 5 | titanium pick | `TTAN x3` (stock) | 98 | near-bedrock |
| 6 | diamond pick | `DMND x2` (stock) | 100 (everything) | bedrock itself |

`R.MINEABLE` becomes a hardness lookup instead of a flat allow-list:
`function R.canMine(elName) return (elementHardness[elName] or 999) <= tierCap[R.pickTier] end` where
`elementHardness` is populated once at world-gen time via
`sim.partProperty`... no — hardness is an **element-level** stat (`Element.Hardness`), not a
per-particle one, so it's read once via the same `elem.property`/`element_facts` path already used to
resolve names, cached in a table, never per-frame.

Exact Lua API calls for this feature: `sim.partID(x,y)` → particle index; `sim.partProperty(p,"type")`
→ element id; `elem.property(id,"Hardness")` (mirrors the id/name resolution helper already in
`rpg.lua`'s `id()`/`nameOf()`) → hardness; `sim.partKill(p)` to remove it once a hardness check passes;
`sim.partCreate(-1,x,y,t)` to place from inventory (already implemented, both ways, in `mine()`/
`place()`).

### 3.4 Inventory

Flat map, element name → count (already the MVP's shape — kept, it round-trips cleanly through
`PBX.encode`'s string-keyed-table rule, same reasoning `30_colony.lua`'s `store` uses). `R.inventory =
{ IRON = 12, COAL = 4, ... }`. `R.slots()` (already implemented) returns a sorted key list for the
numbered hotbar (§6).

### 3.5 Crafting — two distinct mechanisms, not one, and why

TPT's `Update` function can only be attached to an element **this session defined** (`defineElement`,
`EXTENSION_SPEC.md` §4.1, idempotent on name). It cannot be attached to a stock element like `IRON` or
`SAND` — there is no hook to make plain iron react differently. That constraint splits crafting into
two genuinely different mechanisms, and conflating them would either be unbuildable (attaching
`reactive` behaviour to stock `IRON`) or unrealistic (pretending every alloy is a live per-particle
chemical reaction when the engine can't express that for stock inputs):

**(a) Ambient ore chemistry — real per-particle reactions, `reactive` behaviour kind**
(`scripts/lua/chem_kinds.lua`, loaded live the same way `rpg.lua` is). Only usable on **custom**
elements this session defines. Grammar (from `chem_kinds.lua`'s own header, confirmed against
`powder_ext/knowledge_tools.py:_parse_reactive_rules`, which is the authoritative parser both the
in-game behaviour and the offline lint rules share):

```
"WITH>SELF_BECOMES,OTHER_BECOMES:dT:chance[:needs][:extra]"
```

`WITH` is a neighbour element name, or `ANY`, `AIR` (empty neighbour cell), or `HEAT<K>` (self
temperature ≥ K, no neighbour needed). `needs` may itself be `HEAT<K>` (a *second* condition: touching
`WITH` **and** hot enough) or a second required neighbour element (e.g. `O2` for combustion). `extra`
spawns a byproduct element into a free adjacent cell.

Real smelting example — a new custom ore, blast-furnace-style carbothermic reduction
(`2Fe2O3 + 3C -> 4Fe + 3CO2`, real reaction, https://en.wikipedia.org/wiki/Blast_furnace):

```
define_element {
  name="FEOR", group="RPG", description="Hematite-bearing rock (iron ore)",
  colour="0x8B4A3A", type="SOLID", hardness=55, weight=100, heatConduct=15,
  temperature=293.15, highTemperature=1523.15, highTemperatureTransition="LAVA",
  behavior={kind="reactive", params={rules="COAL>IRON,NONE:40:0.2:HEAT1200:CO2"}}
}
```

Reads as: touching `COAL`, while this particle's own temperature is ≥1200 K (927°C — inside a real
blast furnace's reduction-zone range), with chance 0.2/frame: this ore becomes `IRON`, the coal is
consumed (`NONE`), both warm by 40 K, and `CO2` gas vents into a free neighbouring cell — matching the
real reaction's carbon monoxide/dioxide off-gas. The player's job is entirely physical: get ore and
coal touching, inside something that reaches 1200 K (a `HEAC`/`LAVA`-heated furnace chamber, itself a
Blueprint module, §3.5c) — this is genuinely "contain a reaction," reusable directly as a quest check
(§5).

Same mechanism for copper: `CUOR` (new) with a rule keyed on its own smelting point, and for reuse of
already-defined catalog materials with their own real rules already written for you —
`chemistry-rules.json` already has `NA`, `MG`, `CAO` (quicklime slaking, `WATR>CLST,NONE:+300:0.4`,
real `CaO + H2O -> Ca(OH)2`), `CAC2`, `AL61` (thermite), etc. `CAO` in particular is worth adding to
the furnace tier as a **flux**: real blast furnaces add limestone/quicklime to bind silica impurities
into slag (`SiO2 + CaO -> CaSiO3`) — a `needs="CAO"` clause on a higher-tier smelting rule is the
in-fiction reason a Tier-3+ furnace recipe requires flux, not just ore and fuel.

**(b) Station recipes — inventory bookkeeping, for stock-element outputs and multi-part assemblies**
(steel, tools, wire, batteries, the reactor). This is what the MVP's `R.craft(idx)`/`R.RECIPES` already
is, extended with a proximity gate to a placed structure and real ratios/citations in the description
text even though the mechanic itself is a simple inventory debit/credit:

```lua
R.RECIPES = {
  { out="STEL", n=2, need={IRON=4, COAL=2}, station="furnace",
    note="carburizing: Fe + C -> Fe-C steel, real ~0.5-2% carbon content" },
  { out="CU",   n=2, need={CUOR=3, COAL=1}, station="furnace" },   -- once CUOR exists (§2)
  { out="BTRY", n=1, need={STEL=2, CU=2, ACID=1}, station="anvil",
    note="lead-acid analogue: steel case, copper terminals, acid electrolyte" },
  { out="GLAS", n=0, need={}, station=nil,
    note="native: heat SAND above 1973 K (1700 C) -> LAVA -> cools to GLAS; no recipe needed, it's real chemistry for free" },
}
```

The `GLAS` row is deliberately a documentation stub, not a real recipe — `SAND`'s own native
`highTemperature: 1973 K → LAVA` transition (confirmed, `element-interactions-part1.json`) already
does this with zero custom code; the "recipe" is "get sand to 1700°C" (a `HEAC` block, a lava pocket
found underground per §2, or a thermite/`AL61` reaction). This is worth stating explicitly in the
design because it is the cleanest example of "real chemistry, not a crafting-table abstraction."

`R.craft`'s proximity gate (new): a `station` field checked against a small registry of placed
structure locations (`R.stations = { {kind="furnace", x=.., y=..}, ... }`, populated when a
`furnace_station`/`anvil_station` Blueprint module — §3.5c — is placed), using the same squared-distance
check `mine()`/`place()` already use against `R.REACH`.

**(c) Structures as Blueprint modules.** `furnace_station` (new, saved via `blueprint_module_save` per
`BLUEPRINT_SPEC.md`'s module-registry contract): an `insulated_box`-lined chamber (reusing the builtin
`insulated_box` module so `blueprint_lint`'s `heat_source_uninsulated` rule is satisfied by
construction) with a `HEAC` element inside settable to furnace-tier temperature, and a small hopper
opening the player mines/places ore and fuel into. `anvil_station`: a plain `STEL` block, no heat
element, just a `station="anvil"` marker for recipes that don't need heat (assembly-only crafts like
`BTRY`). Both are tiny (well under 50 cells), well inside the Blueprint compiler's budget, and once
saved to `knowledge/modules/furnace_station.json` are reusable by `blueprint_build` calls in world-gen
(§2.9) or by the player's own "place a furnace" action later.

### 3.6 Tech tree (8 tiers, each grounded in a real reaction or a real engine mechanic)

| tier | name | unlocks | real grounding |
|---|---|---|---|
| 1 | Stone Age | hand-mine SAND/CLST/COAL/loose STNE/WOOD; campfire (`FIRE`) | — |
| 2 | Kiln & Masonry | `FBRK` (fired clay), `CAO` quicklime flux, flint pick | real clay vitrification ~1150°C; `CaO+H2O` slaking |
| 3 | Bronze | `BRNZ` (already catalog-defined alloy), bronze pick | real Cu-Sn bronze; low corrosion rate already modeled (`chemistry-rules.json`) |
| 4 | Iron & Steel | `FEOR` smelting → `IRON`; `IRON+COAL` → `STEL`; iron pick | real carbothermic reduction, real carburizing |
| 5 | Glass & Power | `SAND`→`LAVA`→`GLAS` (native), `CUOR`→`CU` wire, `BTRY`, `LEDL`/`LCRY` lamps | real 1700°C silica melt; real copper conductivity |
| 6 | Shielding Alloys | `CNCR`/`RCNC` concrete, `LEAD`, `ZIRC`, `GRPH`, `B4C` (all already catalog-defined), titanium pick | real reactor shielding/cladding/moderator/control-rod materials |
| 7 | Fuel Cycle | mine `URAN`, craft `UO2`, assemble `pwr_fuel_bundle`/`rpv_steel_vessel`/`control_rod_drive_b4c` (all **already exist** as proven modules under `knowledge/modules/`) | real PWR fuel-cycle component roles |
| 8 | Reactor & Endgame | add `TRBN`+`TEG`+`CU` busbar output, power a `LEDL` bank / `WIFI` grid; diamond pick | real steam-turbine/thermoelectric power extraction, reuses this repo's own already-tested reactor blueprint |

Tier 7-8 is not speculative — it reuses concrete, already-built assets in this repo
(`knowledge/modules/rbmk_channel_cell.json`, `control_rod_drive_b4c.json`, `pwr_fuel_bundle.json`,
`rpv_steel_vessel.json`, and the full `UO2`/`ZIRC`/`GRPH`/`B4C`/`CU`/`STEL`/`CNCR`/`LEAD`/`NAK`/`AERO`/
`TRBN`/`TEG` element set in `power-elements-2026-08-26.json`). The endgame quest (§5) is "gate these
same modules behind mined resources and inventory recipes" rather than inventing new reactor
mechanics.

---

## 4. NPCs and enemies

**Do not build a second creature system.** Reuse exactly what exists:

- **Friendly/neutral NPCs** (villagers, a shopkeeper, a quest-giver): the `creature` behaviour kind
  (`20_behaviors.lua`, delegates to `PBX.state.worker.update`) plus a one-worker "colony" per NPC (or
  one shared "villagers" colony via `colony_create`), traits set with `person_set_trait` — `builder`/
  `gatherer`/`coward`/`brave`/`lazy` (`70_people.lua`, `_ALLOWED_TRAITS`). A quest-giver NPC is a
  `lazy`+`brave` worker parked at a fixed point (`colony_assign_task {kind:"patrol", points:[{x,y}]}`
  with a single point makes it stand still). Dialogue is pure Lua/HUD (§6), not part of the creature
  system at all — the RPG's own `onMouse` handler checks "is the click within N px of a tagged NPC
  particle" and opens a HUD panel; the creature system never needs to know it's a quest-giver.
- **Hostile enemies**: `FIGH` (`src/simulation/elements/FIGH.cpp`), TPT's built-in fighter AI —
  already seeks the nearest STKM/STK2 within range, already deals damage via the identical
  `Element_STKM_interact` path, already dies to the identical rules (§3.2). Cap: **`MAX_FIGHTERS =
  100`** (`Stickman.h`), a hard engine ceiling, not a design choice — never try to spawn more than the
  live `sim->fighcount` has room for; `Element_FIGH_CanAlloc`/`sim.fighcount` gate this natively (a
  failed `changeType` to `PT_FIGH` when the pool is full simply does not allocate a fighter slot).
  `parts[i].ctype` on a `FIGH` particle sets its weapon element (`Element_FIGH_NewFighter(sim, id, i,
  elem)`, third arg) — spawn a night-time "raider" with `elem=PT_FIRE` or a deep-cave "guardian" with
  `elem=PT_ACID` for a harder late fight, all via the existing native hook, zero new Update code.
  Exact call from Lua: `sim.partCreate(-1,x,y,elem["DEFAULT_PT_FIGH"])` then the native `ChangeType`
  hook allocates the fighter slot and sets a default weapon; overriding the weapon needs one more
  `execute_lua` round-trip since `sim.fighters[]` is not exposed to Lua directly — set it by placing an
  element of the desired type immediately next to the new `FIGH` particle's head on the spawn frame
  (mirrors how a live player's `ctype`/`elem` gets set: `Element_STKM_set_element` fires from the
  "searching for particles near head" scan, STKM.cpp:410-422, which `FIGH`'s `update()` also runs via
  its own `Element_STKM_run_stickman` call).
- **Loot**: on a `FIGH` death (detect via `sim.partExists(i)` going false after having tracked it, or
  simpler — `sim.partProperty` read returning `nil`/`elemId` mismatch each tick for tracked ids),
  `sim.partCreate` a small cluster of the enemy's tier-appropriate drop (raw ore for a cave guardian,
  nothing but message-only "scrap" for a surface raider) at its last known position. No native loot
  table exists for `FIGH` — this is pure RPG-side bookkeeping, same shape as `R.inventory`.

## 5. Day/night and quests

**Day/night**: already implemented, kept as-is — `R.frame % 3600 == 0` advances `R.day`, and past day 2
a `FIGH` spawns near the player every 1500 frames. "Full" upgrade: a `deco` darkness overlay
(`sim.decoColor`/`graphics.fillRect` full-screen at low alpha during night frames, e.g.
`frame % 3600 > 1800`) for a readable day/night signal beyond the HUD text, and scaling enemy spawn
rate/weapon tier with `R.day` so the threat curve matches the tech tree in §3.6.

**Quests, verified with the existing test tooling rather than a bespoke tracker.** This is the
single cleanest reuse in the whole design: `run_test {frames, assertions, ...}`
(`powder_ext/schemas.py:703`, already built for exactly this — "functional acceptance test on the live
sim... assertions over regions"). A quest is a named `run_test` call plus a HUD-visible description;
"complete" means the assertions passed. Examples, using the exact assertion shape `run_test` already
accepts (`{region, element?, metric: count|tavg_c|tmax_c|life_sum|pmin|pmax|delta_count, op, value}`):

```jsonc
// quest: "power a lamp" (tier 5)
{
  "frames": 120,
  "assertions": [
    { "region": [lampX-2, lampY-2, lampX+2, lampY+2], "element": "LEDL", "metric": "life_sum", "op": ">", "value": 0 }
  ]
}

// quest: "contain a reaction" (tier 4/7 — furnace running without venting CO2/NEUT past its walls)
{
  "frames": 300,
  "assertions": [
    { "region": furnaceInteriorBox, "element": "IRON", "metric": "delta_count", "op": ">", "value": 0 },
    { "region": furnaceOuterRing,   "element": "FIRE", "metric": "count", "op": "==", "value": 0 }
  ]
}

// quest: "build a sealed reactor" (tier 8) — reuses the exact rule shape blueprint_lint
// already enforces (pump_vacu_no_wall / heat_source_uninsulated), plus a live functional check
{
  "frames": 600,
  "assertions": [
    { "region": reactorVesselBox, "element": "NEUT", "metric": "count", "op": "<", "value": 3 },
    { "region": turbineOutputBox, "element": "TEG",  "metric": "life_sum", "op": ">", "value": 0 }
  ]
}
```

`R.quests[id] = {status, progress}` records only the *result* (persisted, §1.4/§10); the actual check
is re-run live via `run_test` on demand (e.g. bound to a key, §6, or auto-checked every N ticks for
quests near the player) rather than duplicated as bespoke Lua conditionals — one verification engine,
reused for both building-agent tests and player-facing quests, per the instruction to build quests "that
use our verification tools."

## 6. UI

### 6.1 HUD (already implemented, extended)

All via `graphics.*` — draw-only, no pixel readback, so every value drawn must come from `sim.*`/
`R.*` state read fresh each `aftersimdraw` (`event.register(event.aftersimdraw, onDraw)`, already the
right event — fires once per rendered frame *after* the sim draw, so HUD text always overlays the
current frame rather than lagging one behind `beforesimdraw`).

```
graphics.fillRect(4, 4, 200, 46, 0,0,0,160)                         -- HUD backing panel
graphics.drawText(8, 8,  "HP "..hp.."  day "..day.."  deaths "..d, 255,255,255,255)
graphics.drawText(8, 22, hotbarLine, 200,230,255,255)                -- "1:IRONx4* 2:COALx2 ..."
graphics.drawText(8, 36, R.msg, 255,220,120,255)                     -- last toast
-- new: tier + active quest, one more line, same panel widened to accommodate it
graphics.drawText(8, 50, "tier "..R.tier.."  quest: "..questLabel, 180,255,180,255)
```

Font/position limits: `graphics.drawText` has no native wrap — every line above is kept to a single
row of plain ASCII by construction (already true of the MVP's HUD strings); a longer quest description
should truncate (`string.sub(desc,1,40).."..."`) rather than wrap, since `textSize` would need to be
queried per-string to wrap correctly and this HUD does not need that complexity for an MVP-adjacent
scope. Panel size: canvas is `612x384` — keep every HUD panel within the top-left ~220x120px quadrant
(already respected) so it never overlaps the mine/place reach circle around the player during normal
play.

### 6.2 Key bindings — collision check against native STKM/STK2 defaults

| key | action | collides with STKM/STK2? |
|---|---|---|
| Arrow keys | native STKM movement (unmodified, §3.1) | — is the native binding |
| `LMB` | mine | native LMB is "place currently selected TPT tool" only while the *game* (not this script) has an active brush selected; the RPG's `onMouse` returns `false` for button 1 inside the canvas, suppressing that — acceptable since a player running the RPG mode isn't expected to also be drawing with TPT's own tool palette |
| `RMB` | place | same reasoning, button 3 |
| `1`-`9` | select hotbar slot / craft recipe (context: `craftOpen`) | no native single-digit binding in `GameController.cpp`'s key table (digits are consumed by TPT's zoom/tool-shortcut system only when a numeric tool shortcut is configured, which is off by default) — **verify empirically before shipping**, this was not exhaustively confirmed against every default keybind in `GameController.cpp` beyond the STKM-specific lines actually read for this document |
| `C` | toggle crafting menu | no native `C` binding found in the STKM-adjacent code read; TPT's own hotkeys use `Ctrl+`/`Shift+` combinations for most global actions, and this design only intercepts the bare key |
| `H` | toggle HUD | none found |
| `K` | save | none found |
| *(new)* `Q` | open/close quest log | none found |
| *(new)* `Tab` | cycle hotbar selection without opening craft menu | not checked — recommend `[`/`]` instead if `Tab` turns out to be reserved for TPT's own focus-cycling |

The one confirmed, sourced fact of real importance: **a Lua `event.keypress` handler runs before, and
can suppress, every native binding** (`GameController::KeyPress`, `commandInterface->HandleEvent(...)`
gates everything after it on its own return value) — so the collision question is entirely "does our
handler return `false` for a key TPT also binds," never "can TPT's native code even be reached." The
existing `onKey` already returns `false` only for the keys it explicitly matches and returns nothing
(→ `true`, native handling proceeds) for everything else, which is the correct default-safe shape to
keep as this grows.

One open risk carried into §8 rather than asserted as fact here: whether `event.keypress` still fires
(and can therefore still swallow `c`/`h`/`k`/digits) while a native TPT textbox (e.g. renaming a save)
has input focus was not confirmed by reading the GUI focus-routing code — `LuaEvent.cpp` shows
`TEXTINPUT`/`TEXTEDITING` are separate event types from `KEYPRESS`, which suggests they might route
exclusively, but this needs an empirical check, not an assumption baked into the keybinding table above.

---

## 7. MVP cut vs. full

**MVP (2-3 days), everything below already exists in `scripts/lua/rpg.lua` today except the two
explicitly marked fixes:**

- World gen: strata + caves + water pockets + 4-5 ore veins + trees + lava (as-is)
- Player: STKM spawn/respawn-on-death (inventory halved), native movement untouched
- Mining/placing: reach-gated, hardness ignored (flat allow-list, as-is — tiered hardness is a full-scope item)
- Inventory + 9 hardcoded recipes (as-is)
- Day counter + night `FIGH` spawns (as-is)
- HUD: HP/day/deaths/hotbar/message/craft menu (as-is)
- Keybinds: arrows (native), LMB/RMB, `1`-`9`, `C`/`H`/`K` (as-is)
- **Fix 1 (§1.3)**: route `R.generate`/`R.spawnPlayer` through a tick-consumed flag instead of calling
  them synchronously from `execute_lua` — this is a correctness fix to ship *with* the MVP, not an
  enhancement, since the direct-call path is the one the sourced engine assertion says can fail.
- **Fix 2 (§1.4)**: add `R.load()`/use `PBX.save`/`PBX.load` instead of the hand-rolled `io.open` save
  file, so a save actually restores on the next session (currently write-only).

**Full** (everything else in this document): biomes, water table + flood/drain mechanic, hardness-
tiered pickaxes, the two-track crafting split (ambient ore chemistry + station recipes) with `FEOR`/
`CUOR` custom ores and real smelting rules, the 8-tier tech tree through the existing reactor modules,
NPC villagers/quest-givers via the creature system, `FIGH` weapon-by-tier and loot, day/night visual
overlay, quest log UI + `run_test`-backed quest verification, `rpg_start`/`rpg_status`/`rpg_save` MCP
tools replacing ad hoc `execute_lua` calls from the operator side.

---

## 8. Risks

1. **`AssertMutableSimEvent` on synchronous world-gen via `execute_lua`** (§1.3) — sourced, not
   speculative; fix is specified and cheap (a flag + existing `onTick`).
2. **STKM death-by-own-chemistry is a real, sourced hazard, not just difficulty tuning.** Standing
   next to your own furnace (§3.5c) or an unshielded lava pocket applies `+2` damage/frame the instant
   any neighbour is `>=323 K`, with no immunity window (`Element_STKM_interact`, STKM.cpp:651-655) —
   at 60 fps that's up to 120 HP/second if fully surrounded, easily lethal in under a second before a
   player can react. Mitigation: the `furnace_station` module (§3.5c) *must* be `insulated_box`-lined
   on all four sides facing outward (exactly what `blueprint_lint`'s `heat_source_uninsulated` rule
   already checks for free), and world-gen-placed lava pockets (§2.6) should keep a minimum buffer of
   normal-temperature rock between the pocket and any path the player is expected to walk, or be
   fenced with a wall/deco warning.
3. **Leaking `NEUT` near the reactor tiers is separately, natively lethal** (§3.2, STKM.cpp:432-437) —
   a control-rod (`B4C`) failure in the tier-7/8 reactor doesn't just fail a quest check, it can halve
   the player's HP per exposed frame. This is desirable as *design* (matches "contain a reaction"
   thematically) but must be a deliberate, telegraphed risk (HUD radiation warning once `NEUT` count in
   a region near the player crosses a threshold, checked the same way `run_test`'s `count` metric
   already works) rather than a silent instant-death trap.
4. **Per-frame Lua cost.** `onTick`/`onDraw` run every simulated/rendered frame unconditionally once
   `R.active`. The existing MVP's per-tick body is already cheap (a few modulo checks, one particle
   lookup via `R.playerId()` which itself is an **O(all particles) scan** — `for i in sim.parts() do`
   over the whole particle table every 60 frames to find the STKM index). At `235,008` max particle
   slots this is the same class of cost `40_worker.lua` went to great lengths to avoid paying more than
   once per ant per 30-60 ticks; for a single lookup it's acceptable today, but any "full" feature that
   scans all particles more often (e.g. a naive `NEUT` proximity check for risk #3 done every frame
   rather than every N frames) should follow `40_worker.lua`'s own staggering discipline rather than
   re-deriving it from scratch.
5. **Input capture correctness is unverified in one specific case** (§6.2): whether `event.keypress`
   fires while a native TPT textbox has focus. If it does, `rpg.lua`'s current unconditional key
   matching (`c`/`h`/`k`/digits, no focus check) could swallow keystrokes meant for, e.g., a save-name
   text field. Needs an empirical check (type `"check"` into a TPT save dialog while the RPG's handler
   is registered and see if a `c` goes missing) before this is considered settled either way.
6. **Single-STKM constraint interacts badly with manual play.** `createAllowed` refuses a new `STKM` if
   `sim->elementCount[PT_STKM] > 0` anywhere on the canvas — if a human manually places a stickman with
   TPT's own tool palette while the RPG is `R.active`, `R.spawnPlayer()`'s respawn-on-death logic can
   silently fail to create a new player (no error surfaced, `R.playerId()` just keeps returning `nil`).
   Worth a HUD message ("no player found — remove any stray STKM particles") rather than a silent
   retry loop.
7. **`GOLD`/`WOOD`/`DMND`/`URAN` hardness values used nowhere in this document were verified live** —
   flagged already in §3.3, repeated here because the tool-tier table's exact thresholds are the part
   of this design most likely to need a one-line correction once `element_facts` is actually queried
   against the running session.

---

## 9. On "existing TPT RPG/adventure saves" prior art

This session's web-search budget was already exhausted (0 of 200 remaining) before this task started,
so no new external search was possible; citation here relies on what was already recorded in this
repo's own prior research pass, `D:/powder-toy/knowledge/research-building-bot-2026-08-25.md`, which
did search this ground directly and found **"zero hits for 'Powder Toy' + MCP/agent/LLM-builder"** and
no headless/scriptable-game prior art beyond the stock `STKM`/`FIGH` mechanics themselves — i.e., the
built-in stickman-vs-fighter system (used informally in some community "boss fight" saves on the
in-game browser, per that mechanic's own existence and `MenuVisible=1` default availability) is the
only "RPG-adjacent" feature TPT ships natively, and there is no dedicated third-party RPG/adventure
Lua framework for TPT on record in this repo's research. If a fresher external check is wanted, it
needs a session with search budget remaining, or the user's own knowledge of specific saves/threads to
point at (e.g. `powdertoy.co.uk` discussion threads, which this repo has previously cited by direct
URL for other topics, per `research-building-bot-2026-08-25.md`'s own citation style).

---

## 10. JSON Schema — persisted save state (`PBX.save("rpg", ...)` / `knowledge/rpg.json`)

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "PowderRPGSave",
  "type": "object",
  "additionalProperties": false,
  "required": ["version", "seed", "day", "frame", "deaths", "inventory", "tier"],
  "properties": {
    "version":   { "type": "integer", "minimum": 1, "description": "save format version" },
    "seed":      { "type": "integer", "description": "world-gen seed, replayed by R.generate(seed)" },
    "day":       { "type": "integer", "minimum": 1 },
    "frame":     { "type": "integer", "minimum": 0, "description": "R.frame counter at save time" },
    "deaths":    { "type": "integer", "minimum": 0 },
    "tier":      { "type": "integer", "minimum": 1, "maximum": 8, "description": "highest unlocked tech tier" },
    "selected":  { "type": ["string", "null"], "description": "element name of the active hotbar slot" },
    "inventory": {
      "type": "object",
      "description": "element name -> count; only positive counts are ever written",
      "additionalProperties": { "type": "integer", "minimum": 0 }
    },
    "surface": {
      "type": "object",
      "description": "sparse map of pixel-x (as a string key, per PBX.encode's string-keyed-table rule) -> terrain surface y, used to re-place NPCs/enemies without re-scanning the world",
      "additionalProperties": { "type": "integer", "minimum": 0, "maximum": 383 }
    },
    "quests": {
      "type": "object",
      "description": "questId -> status",
      "additionalProperties": {
        "type": "object",
        "additionalProperties": false,
        "required": ["status"],
        "properties": {
          "status":   { "type": "string", "enum": ["locked", "active", "complete"] },
          "progress": { "type": "number", "minimum": 0, "maximum": 1 }
        }
      }
    },
    "stations": {
      "type": "array",
      "description": "placed furnace_station/anvil_station instances, for the proximity gate in 3.5",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["kind", "x", "y"],
        "properties": {
          "kind": { "type": "string", "enum": ["furnace", "anvil"] },
          "x": { "type": "integer", "minimum": 0, "maximum": 611 },
          "y": { "type": "integer", "minimum": 0, "maximum": 383 }
        }
      }
    }
  }
}
```

Deliberately **not** persisted: `phero`-style transient grids (n/a here), the live `player` particle
index (re-resolved via `R.playerId()` on load, same reasoning `30_colony.lua` gives for not persisting
its pheromone grid — every particle from the previous process is gone on restart), and `hud`/
`craftOpen` UI toggles (session-local presentation state, not save data, mirroring why `50_tasks.lua`
does not persist per-particle claim tokens either).
