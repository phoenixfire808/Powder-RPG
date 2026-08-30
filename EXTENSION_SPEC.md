# Powder Bridge Extension Spec (v1)

This is the binding contract for the runtime-extension layer. It lets us add new
elements, behaviours and autonomous creatures to The Powder Toy **without rebuilding
`powder.exe`**, and exposes all of it as MCP tools.

Every module below is written by a different author working in parallel. Code only
against this document. Do not read or edit another module's file.

---

## 1. Why this shape

`autorun.lua` is a single file loaded once at TPT startup. TPT's Lua sandbox does not
guarantee `require`/`dofile` from the build directory, so the extension is authored as
separate source modules that are **concatenated** into the final `autorun.lua` by
`D:/powder-toy/build_autorun.py` in filename order.

```
D:/powder-toy/bridge_src/00_util.lua        (written, foundation - read it, do not edit)
D:/powder-toy/bridge_src/10_registry.lua
D:/powder-toy/bridge_src/20_behaviors.lua
D:/powder-toy/bridge_src/30_colony.lua
D:/powder-toy/bridge_src/40_worker.lua
D:/powder-toy/bridge_src/50_tasks.lua
D:/powder-toy/bridge_src/60_diag.lua
```

Build order at runtime: all `bridge_src` modules are injected **above** the existing
bridge code, so `_G.PB_EXT` is fully populated before the HTTP server starts. The base
bridge's unknown-action fallthrough is patched to consult `_G.PB_EXT` first.

Language level is **Lua 5.1** (TPT ships 5.1 semantics: `loadstring`, no `goto`, no
integer division operator, `#t` for length, `table.getn` deprecated but present).

---

## 2. The `_G.PBX` foundation (provided by `00_util.lua`)

`00_util.lua` is already written. Treat its API as fixed.

### 2.1 Registering an action

```lua
PBX.register("myAction", function(req, ctx)
    -- req  : the parsed request table (already token-authenticated)
    -- ctx  : { jok=, jerr=, jesc=, jnum=, resolveElem=, resolveWall=, resolveTool= }
    -- MUST return a JSON string, built with PBX.ok / PBX.err
    return PBX.ok("myAction", { count = 3, name = "hello" })
end)
```

Action names are camelCase and must be globally unique. Registering a duplicate name
raises at load time — this is deliberate, it catches two modules claiming one action.

### 2.2 JSON emission

Never hand-roll JSON. `json.stringify` in TPT crashes on nested tables; `PBX` has a
safe encoder.

```lua
PBX.ok(action, tbl)        --> '{"ok":true,"action":"...", ...tbl}'
PBX.err(msg, tbl)          --> '{"ok":false,"error":"...", ...tbl}'
PBX.encode(value)          --> encodes nil/boolean/number/string/array/map, depth-capped at 8
PBX.arr(list)              --> marks a table as a JSON array (empty table would otherwise emit {})
```

Numbers that are `nan`/`inf` encode as `null`. Strings are escaped for `"` `\` and
control characters.

### 2.3 Validation helpers

All return `value, nil` on success or `nil, "message"` on failure. Always propagate the
message to the caller with `PBX.err`.

```lua
PBX.vInt(v, name, min, max)          -- integer within inclusive bounds
PBX.vNum(v, name, min, max)          -- finite number within inclusive bounds
PBX.vStr(v, name, maxLen, pattern)   -- string, optional Lua pattern to match
PBX.vBool(v, name, default)
PBX.vEnum(v, name, {"a","b"})
PBX.vPixel(x, y)                     -- 0<=x<612, 0<=y<384
PBX.vCell(x, y)                      -- 0<=x<153, 0<=y<96
PBX.vElem(nameOrId)                  -- resolves to a numeric element id or errors
PBX.vList(v, name, maxItems)         -- array table with a length cap
```

Hard limits enforced by `PBX` and not to be exceeded by any module:
`MAX_WORKERS_PER_COLONY = 400`, `MAX_COLONIES = 8`, `MAX_TASKS_PER_COLONY = 16`,
`MAX_BLUEPRINT_CELLS = 4096`, `MAX_CUSTOM_ELEMENTS = 24`.

### 2.4 Deferred work (critical)

`elements.allocate`, `elements.element`, `elements.property` and `sim.step` **must not**
be called from inside the HTTP handler — the handler runs inside `LuaSocket::Process`
and TPT asserts on mutable-tools events there (`LuaElements.cpp: AssertMutableToolsEvent`).

Queue the work instead and it runs on the next `event.TICK`:

```lua
local jobId = PBX.defer(function()
    -- runs on the simulation thread, safe for element mutation
    return { id = 42 }              -- return value stored as the job result
end)
PBX.jobResult(jobId)   --> nil while pending, else { ok=bool, value=..., error=... }
```

**There is no synchronous wait.** Blocking the handler until a job completes would
deadlock on the very same lock. Any action whose work must be deferred returns
`{ "job": <id>, "status": "pending" }` and the caller polls the built-in `jobStatus`
action (`{action:"jobStatus", job:<id>}` → `status` `pending`|`done`, plus `succeeded`,
`value`, `detail`). The MCP layer is responsible for polling and presenting a single
settled result to the model. At most 8 jobs drain per tick.

### 2.5 Per-tick hooks

```lua
PBX.onTick(name, fn, everyNTicks)   -- fn(tickIndex, dtTicks); errors are caught,
                                    -- counted, and the hook is disabled after 20 errors
```

`PBX.tickIndex` is a monotonically increasing integer.

### 2.6 Logging and error accounting

```lua
PBX.log(module, msg)       -- appends to autorun-runtime.log, prefixed [module]
PBX.warn(module, msg)
PBX.errorCount(module)     -- number of caught errors attributed to a module
```

Never let an error escape an Update function or a tick hook — TPT will spam and may
stall. Wrap risky bodies in `PBX.guard(module, fn)`.

### 2.7 Shared state namespace

Each module owns exactly one key on `PBX.state`:
`PBX.state.registry`, `.behaviors`, `.colony`, `.worker`, `.tasks`, `.diag`.
Reading another module's state is allowed; writing it is not.

### 2.8 Persistence

```lua
PBX.save(name, tbl)   -- writes D:/powder-toy/knowledge/<name>.json
PBX.load(name)        -- returns table or nil
```

Used so custom elements and colonies survive a TPT restart.

---

## 3. Particle field layout for creatures

Fixed allocation. Do not repurpose a field outside your module's column.

| field     | meaning                                                              | owner   |
|-----------|----------------------------------------------------------------------|---------|
| `type`    | the allocated worker element id                                      | worker  |
| `ctype`   | carried element id, `0` = empty handed                               | worker  |
| `life`    | energy, 0 means starve/despawn                                       | worker  |
| `tmp`     | task id (0 = idle)                                                   | tasks   |
| `tmp2`    | state machine: 0 IDLE 1 SEEK 2 HAUL 3 BUILD 4 HOME 5 DIG 6 WANDER    | worker  |
| `tmp3`    | colony id                                                            | colony  |
| `tmp4`    | claim token: blueprint cell index +1, or 0 when unclaimed            | tasks   |
| `pavg0`   | last dx (-1/0/1) encoded as dx+1                                     | worker  |
| `pavg1`   | last dy (-1/0/1) encoded as dy+1                                     | worker  |
| `dcolour` | colony tint, `0xAARRGGBB`                                            | colony  |

`tmp3`/`tmp4` exist in current TPT builds. `00_util.lua` probes for them at load and
sets `PBX.hasTmp34`. If false, colony id falls back to the high nibble of `tmp2` and
modules must use `PBX.getColony(i)` / `PBX.setColony(i, id)` rather than touching the
field directly. **Always use those accessors.**

Movement is manual: workers are `TYPE_SOLID` with zero advection/gravity and are
repositioned with `sim.partPosition(i, nx, ny)` after checking `sim.pmap(nx, ny)` is
free. Never move more than one cell per tick per worker.

---

## 4. Bridge actions

All requests already carry `token` and are authenticated before dispatch. Responses are
`{"ok":true,"action":...}` plus the fields listed. Errors are `{"ok":false,"error":...}`.

### 4.1 `10_registry.lua`

| action                 | request                                                                                        | response |
|------------------------|------------------------------------------------------------------------------------------------|----------|
| `defineElement`        | `name` (1-4 chars A-Z0-9, no `_`), `group` (default `PBX`), `description`, `colour` `0xRRGGBB`, `menuSection`, `type` one of PART/LIQUID/SOLID/GAS/ENERGY, `properties` array of flag names, `temperature`, `highTemperature`, `highTemperatureTransition`, `lowTemperature`, `lowTemperatureTransition`, `hardness`, `weight`, `gravity`, `diffusion`, `flammable`, `explosive`, `heatConduct`, `behavior` `{kind=..., params={...}}` | `id`, `identifier`, `created` |
| `listCustomElements`   | -                                                                                                | `elements` array of full specs plus live `id` |
| `updateElement`        | `name`, plus any subset of the define fields                                                     | `id`, `changed` array |
| `deleteCustomElement`  | `name`                                                                                           | `freed` bool |

`defineElement` is idempotent on `name`: redefining updates in place rather than
allocating a second id. Specs persist through `PBX.save("custom-elements", ...)` and are
recreated on startup.

### 4.2 `20_behaviors.lua`

Exposes no actions. Publishes `PBX.state.behaviors.kinds` — a map of
`kind -> { params = {name = {type, min, max, default}}, make = function(params) return updateFn end }`.

Required kinds: `inert`, `glower`, `decayer`, `emitter`, `grower`, `pheromone`,
`conductor`, `creature` (the last one delegates to `PBX.state.worker.update`).

`10_registry.lua` calls `PBX.state.behaviors.kinds[kind].make(params)` and installs the
result with `elements.property(id, "Update", fn)`.

### 4.3 `30_colony.lua`

| action           | request                                                          | response |
|------------------|-------------------------------------------------------------------|----------|
| `colonyCreate`   | `name`, `nestX`, `nestY`, `colour`, `pheromoneDecay` (0..1)       | `colonyId` |
| `colonyList`     | -                                                                 | `colonies` |
| `colonyStatus`   | `colonyId`                                                        | `workers`, `alive`, `carrying`, `store` map, `tasks`, `nest`, `pheromonePeak` |
| `colonyDestroy`  | `colonyId`, `killWorkers` bool                                    | `destroyed` |

Owns the pheromone grid: `153 x 96` floats, decayed every tick by `pheromoneDecay`,
deposited by workers, readable via `PBX.state.colony.phero(colonyId, cx, cy)`.

### 4.4 `40_worker.lua`

| action              | request                                                     | response |
|---------------------|--------------------------------------------------------------|----------|
| `colonySpawnWorkers`| `colonyId`, `count` (1..400 total cap), `x`, `y`, `spread`   | `spawned`, `total` |
| `colonyKillWorkers` | `colonyId`, `count` optional (default all)                   | `killed` |

Also owns the `creature` update function published at `PBX.state.worker.update`.

### 4.5 `50_tasks.lua`

| action              | request                                                                                             | response |
|---------------------|------------------------------------------------------------------------------------------------------|----------|
| `colonyAssignTask`  | `colonyId`, `kind`, `params` (see below), `priority` 1..9, `workers` optional cap                    | `taskId` |
| `colonyTaskStatus`  | `colonyId`, `taskId` optional                                                                         | `tasks` with `progress`, `claimed`, `done`, `total` |
| `colonyCancelTask`  | `colonyId`, `taskId`                                                                                  | `cancelled` |

Task kinds and their params:

- `gather` — `element`, `region` `{x1,y1,x2,y2}`, `amount`: find the element in region,
  carry it to the nest, add to the colony store.
- `dig` — `region`, `element` optional: remove matter from a region, discard it.
- `buildLine` — `element`, `x1,y1,x2,y2`, `source` (`store` or `spawn`): deposit the
  element along the line, one cell per delivery.
- `buildBox` — `element`, `x1,y1,x2,y2`, `filled` bool, `source`.
- `buildCircle` — `element`, `cx,cy,radius`, `filled`, `source`.
- `buildBlueprint` — `cells` array of `{x,y,element}` up to 4096, `source`.
- `patrol` — `points` array of `{x,y}`, `loops`.

A blueprint is a flat array of target cells. Each cell has a claim slot so two workers
never target the same cell — a worker writes `tmp4 = cellIndex+1` when it claims, clears
it on completion or death. Unclaim stale cells whose owning particle no longer exists
(sweep every 60 ticks).

`source="store"` means the colony must already hold the material (gathered); `"spawn"`
means workers materialise it, which is the cheap mode for pure construction demos.

### 4.6 `60_diag.lua`

| action        | request | response |
|---------------|---------|----------|
| `extStatus`   | -       | `modules` array `{name, version, actions, errors}`, `tickIndex`, `jobQueue`, `hasTmp34`, `customElementCount`, `colonyCount`, `workerCount` |
| `extSelfTest` | `deep` bool | `checks` array `{name, ok, detail}` — must not permanently mutate the sim |

---

## 5. MCP layer (`D:/powder-toy/powder_ext/`)

The MCP server `D:/powder-toy/powder_toy_mcp.py` is a single file with a strict
registration contract (manifest entry + `Tool()` declaration + dispatch branch, all
three checked by `_capability_manifest_check`). **No agent edits that file.** Instead:

```
D:/powder-toy/powder_ext/__init__.py       (empty)
D:/powder-toy/powder_ext/schemas.py
D:/powder-toy/powder_ext/element_tools.py
D:/powder-toy/powder_ext/colony_tools.py
D:/powder-toy/powder_ext/selftest.py
```

`schemas.py` must expose:

```python
TOOL_SCHEMAS: dict[str, dict]     # mcp tool name -> JSON Schema (additionalProperties False)
TOOL_DESCRIPTIONS: dict[str, str] # mcp tool name -> one-line description
TOOL_READONLY: dict[str, bool]    # mcp tool name -> whether it mutates the sim
TOOL_ORDER: tuple[str, ...]       # stable registration order
```

`element_tools.py` and `colony_tools.py` must each expose:

```python
HANDLERS: dict[str, callable]     # mcp tool name -> handler(arguments: dict) -> dict
```

Handlers talk to the bridge through the existing client:

```python
from powder_bridge.client import bridge_request   # verify the real symbol name first
```

Read `D:/powder-toy/powder_bridge/client.py` and use whatever the existing MCP tools
use — mirror the call style in `powder_toy_mcp.py`, do not invent a new transport.
Every handler returns a plain dict containing at minimum `ok`, `tool`, and either the
bridge payload or `errors: [str]`. Validate arguments locally before hitting the bridge
so a bad call fails fast with a useful message.

MCP tool names (snake_case, these are what the model sees):

`define_element`, `list_custom_elements`, `update_element`, `delete_custom_element`
`colony_create`, `colony_list`, `colony_status`, `colony_destroy`,
`spawn_workers`, `kill_workers`, `assign_task`, `task_status`, `cancel_task`,
`extension_status`, `extension_self_test`

---

## 6. Non-negotiables

1. **Do not edit `D:/powder-toy/powder_toy_mcp.py`.** Integration is done centrally.
2. **Do not edit `D:/powder-toy/scripts/demo_create_element.lua` or
   `D:/The-Powder-Toy/build/autorun.lua`.** They are generated at deploy time.
3. **Do not restart, launch or kill `powder.exe`,** and do not call `clear_sim`,
   `draw_project`, `place_element`, `set_field_region` or any other simulation-mutating
   MCP tool. The canvas is shared and someone else is using it.
4. **Do not write to `D:/powder-toy/knowledge/build-lessons.jsonl`.**
5. Only edit the one file you were assigned. If you need something from another
   module, code against this spec and assume it exists.
6. Lua must be 5.1-compatible and must parse. Verify with
   `luac -p yourfile.lua` if available, otherwise re-read carefully — a syntax error in
   any module breaks the whole game's autorun.
7. Python must be syntax-clean under `python -c "import ast,io; ast.parse(...)"`.
8. Every public function gets a short docstring/comment saying what it does and what it
   returns. Match the surrounding code's density — this codebase comments the *why*.

---

## 7. Physics facts already established (do not re-derive)

- `LN2` is `LNTG`, spawns at `70.15 K`, boils to nothing at `77 K`. Direct particle-to-
  particle conduction is unconditional, so it dies on contact with warm matter.
- `PLSM` has `PROP_LIFE_DEC|PROP_LIFE_KILL`, life 50-199. Plasma made by **sparking
  NBLE** carries `ctype = PT_NBLE` and **reverts to NBLE** at end of life instead of
  dying, so a re-sparked NBLE bed is the only self-sustaining glow.
- `TTAN` melts at `1941 K` and **is `PROP_CONDUCTS`**. Non-conductive structural
  materials are `BRCK`, `CNCT`, `GLAS`.
- `INST` conducts by special-cased type id, not by the `PROP_CONDUCTS` flag.
- `ARAY` fires the whole `BRAY` line in a single `Update()`, out the face opposite the
  spark; `BRAY` lives 30 frames (1020 if the line is re-sparked over itself).
- The simulation is `612 x 384` pixels and `153 x 96` cells; fields are cell-space.
