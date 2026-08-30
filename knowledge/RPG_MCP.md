# RPG MCP tools

Seven `rpg_*` tools added to the `powder-toy` MCP server (2026-08-26) so anyone working
on the Powder RPG (`scripts/lua/rpg.lua` + `scripts/lua/rpg_plugins/*`) can rapidly and
constantly index and act on it -- live game state, full-text search over every RPG file,
a structured API dump, the team hub, hot-reload, screenshots, and raw Lua -- without
leaving the MCP session or restarting `powder.exe`.

Implementation: `powder_ext/rpg_tools.py` (handlers), registered in `powder_ext/schemas.py`
(`TOOL_SCHEMAS`/`TOOL_DESCRIPTIONS`/`TOOL_READONLY`/`TOOL_ORDER`) and `powder_toy_mcp.py`
(`_legacy_tool_declarations` Tool() entries, `_CAPABILITY_MANIFEST`, the extension dispatch
tuple, `_MUTATION_TOOLS` for the four mutating ones). Offline unit tests:
`scripts/test_rpg_tools.py` (run via `python scripts/ci.py`).

Three are read-only (`rpg_status`, `rpg_search`, `rpg_api`); four mutate something
(`rpg_hub` writes the hub file, `rpg_reload`/`rpg_screenshot`/`rpg_lua` touch the live game) --
all four are guarded (validated input, refused destructive calls, or scoped/restored state).

---

## rpg_status (read-only)

Live game-state snapshot pulled via `PowderClient().execute_lua`: active/paused/seed/
frame/day, player pos/depth/biome/onGround, hp, camera, inventory, hotbar/sel, tools,
accessories (`acc`/`accOff`), the current quest's index+text, stations, machine/enemy
counts, per-plugin `pluginStatus`, `lastErr`/`pluginErr`, weather, particle count, and an
optional FPS estimate.

FPS is measured by sampling `R.frame` twice, `fps_sample_ms` apart (default 1000ms,
bounded 100-3000ms) -- set `include_fps: false` to skip the wait entirely.

```json
{"tool": "rpg_status", "arguments": {}}
```

```json
{"tool": "rpg_status", "arguments": {"include_fps": true, "fps_sample_ms": 300}}
```

Sample response (trimmed, from a real live session):

```json
{
  "ok": true, "active": true, "paused": false, "seed": 1870, "frame": 85460, "day": 3,
  "player": {"x": 336.9, "y": 192.1, "depth_m": 2, "biome": "forest", "onGround": true, "face": -1},
  "hp": 86,
  "camera": {"x": 50, "y": -32},
  "inventory": {"WOOD": 241, "GRNT": 932, "COAL": 12, "GRSS": 740},
  "hotbar": ["tool:pick", "tool:axe", "tool:sword", "tool:torch", "tool:bucket", "WORKBENCH", "GRSS", "GRNT", "WOOD", "COAL"],
  "quest": {"index": 4, "text": "Dig 6 Granite with the wood pick (slow) and craft a stone pick at the workbench"},
  "pluginStatus": {"save": "ok", "ui": "ok", "items": "ok", "enemies": "ok", "world": "ok", "machines": "ok", "guide": "absent"},
  "fps": 30.87,
  "particles": 88057
}
```

If `rpg.lua` isn't loaded, or the bridge is unreachable, you get `{"ok": false, "error": "..."}`
instead of an exception.

---

## rpg_search (read-only)

Ranked full-text search (TF-IDF/cosine, same technique as the existing `module_search`
tool, no external dependency) over the whole RPG corpus:

- **code**: `scripts/lua/rpg.lua`, every `scripts/lua/rpg_plugins/*.lua`, and its `README.md`
- **docs**: `knowledge/rpg-hub.md`, `rpg-roadmap.md`, `rpg-ideas.md`,
  `research-worldgen-2026-08-26.md`, `research-inventory-ux.md` (if present), and every
  `knowledge/design-rpg-*.md`
- **mechanics**: `knowledge/build-lessons.jsonl`, `knowledge/playbook.json`

The index is line-based and built lazily, cached per-file by mtime -- a repeat call only
re-reads files that actually changed since the last call (verified in
`test_repeated_call_uses_mtime_cache_not_a_reread`).

```json
{"tool": "rpg_search", "arguments": {"query": "grappling hook accessory", "k": 5, "scope": "code"}}
```

```json
{
  "ok": true, "query": "grappling hook accessory", "scope": "code", "count": 5,
  "results": [
    {"file": "D:\\powder-toy\\scripts\\lua\\rpg.lua", "line": 353, "snippet": "hook = { name=\"Grappling Hook\", desc=\"press G to pull yourself to the block you aim at\", tier=2 },", "score": 0.62},
    ...
  ]
}
```

`scope` defaults to `all`; `k` is bounded 1-50 (default 10).

---

## rpg_api (read-only)

Structured dump of the RPG's scriptable API for agents:

- **hooks**: every name in `R.hooks` (`tick`, `draw`, `drawHUD`, `key`, `mousedown`,
  `mouseup`, `place`, `mine`, `craft`, `gen`, `newworld`, plus anything added later, e.g.
  `sandbox`), parsed straight from rpg.lua's `R.hooks = { ... }` declaration.
- **helpers**: every `function R.foo(...)` and `R.foo = ...` / `R.a, R.b = ...` defined at
  module scope in rpg.lua -- name, `kind` (`function`/`field`), line, one-line context.
  This is the same list `rpg_plugins/README.md`'s "Helpers on R" documents by hand.
- **key_bindings**: every `k == "..."` check found across rpg.lua and every plugin file,
  with file+line, so you can see at a glance which keys are already claimed.
- **tables**: `R.RECIPES`/`ITEMS`/`ACCS`/`QUESTS`/`STATIONS`/`NAMES`/`MINEABLE`/`HARD`
  read **live** from the running game via `execute_lua` (`tables_source: "live"`) when the
  bridge is reachable, so you see exactly what a live worker's edits produced -- not a
  stale copy of the source. Falls back to a static parse of rpg.lua's source
  (`tables_source: "static"`) when the bridge is down: the four flat tables
  (NAMES/HARD/MINEABLE/STATIONS) are parsed into real dicts, the four nested tables
  (RECIPES/ITEMS/ACCS/QUESTS) come back as `{"raw_source": "<the literal Lua block>"}`
  since they're too structurally varied (nested `need={...}` tables, `done=function()...end`
  quest predicates) for a safe regex parse.

```json
{"tool": "rpg_api", "arguments": {}}
```

```json
{
  "ok": true, "tables_source": "live",
  "hooks": ["tick", "draw", "drawHUD", "key", "mousedown", "mouseup", "place", "mine", "craft", "gen", "newworld", "sandbox"],
  "helpers": [
    {"name": "nice", "kind": "function", "line": 40, "context": "function R.nice(el) if not el then return \"?\" end; ..."},
    {"name": "eid", "kind": "field", "line": 45, "context": "R.eid, R.nameOf, R.has, R.colourOf, R.descOf = eid, nameOf, has, colourOf, descOf"}
  ],
  "key_bindings": [
    {"key": "e", "file": "D:\\powder-toy\\scripts\\lua\\rpg_plugins\\ui.lua", "line": 861}
  ],
  "tables": {
    "RECIPES": [{"out": "WORKBENCH", "n": 1, "need": {"WOOD": 10}, "st": "hand", "txt": "Workbench", "desc": "..."}],
    "NAMES": {"GOO": "Dirt", "GRNT": "Granite"}
  }
}
```

---

## rpg_hub (mutation)

Read or append to the team hub (`knowledge/rpg-hub.md`).

```json
{"tool": "rpg_hub", "arguments": {"action": "read"}}
```

```json
{"tool": "rpg_hub", "arguments": {"action": "read", "lines": 20}}
```

`action: "post"` appends `- [HH:MM] <who>: text` under the Log (matching every other
worker's existing convention):

```json
{"tool": "rpg_hub", "arguments": {"action": "post", "who": "mcp", "text": "rpg_* tools shipped, see knowledge/RPG_MCP.md"}}
```

`action: "drew"` inserts a `- HH:MM "text"` line under **Drew says**, immediately above the
**Ownership** section -- matching how the lead has been relaying Drew's live comments:

```json
{"tool": "rpg_hub", "arguments": {"action": "drew", "text": "make the torch brighter at night"}}
```

`text` is required for `post`/`drew`; `who` defaults to `mcp` for `post`.

---

## rpg_reload (mutation)

Hot-reload rpg.lua itself, or one plugin, without restarting `powder.exe`.

```json
{"tool": "rpg_reload", "arguments": {"target": "core"}}
```

`target: "core"` re-executes `scripts/lua/rpg.lua`'s own source through `execute_lua`.
This is safe to do while Drew is playing: rpg.lua's own top-of-file guard
(`if old and old.isolated and old.version == 4 then R = old`) makes it reuse the live `R`
table instead of resetting the world -- the same thing `scripts/rpg.py start` does.

```json
{"tool": "rpg_reload", "arguments": {"target": "plugin", "name": "world"}}
```

`target: "plugin"` calls `R.reloadPlugin(name)`; `name` must match
`^[a-z][a-z_]{0,30}$` (e.g. `world`, `enemies`, `machines`, `items`, `save`, `ui`, or a
newly added plugin). Both forms return the reload result plus a fresh
`pluginStatus`/`pluginErr`/`lastErr` snapshot so a broken reload is immediately visible:

```json
{"ok": true, "target": "plugin", "name": "world", "result": "ok", "pluginStatus": {"world": "ok", ...}, "pluginErr": "", "lastErr": ""}
```

---

## rpg_screenshot (mutation)

Capture a PNG of the live RPG view via `tpt.screenshot`, exactly like the existing generic
`screenshot` tool but RPG-aware: it can open the bag, menu, or quest panel first and
restores its prior open/closed state afterward (even if the capture itself fails).

```json
{"tool": "rpg_screenshot", "arguments": {}}
```

```json
{"tool": "rpg_screenshot", "arguments": {"panel": "bag"}}
```

`panel` is one of `bag` (`R.ui.bagOpen`, set by `rpg_plugins/ui.lua`), `menu`
(`R.menuOpen`, the core pause/help menu), or `quests` (`R.ui.questOpen`); omit it to
capture the plain view. Returns `{"ok": true, "panel": ..., "path": "D:\\The-Powder-Toy\\build\\screenshot ....png"}`.

---

## rpg_lua (mutation)

Run one Lua snippet against the live RPG with `local R = PBX.state.rpg` prepended.

```json
{"tool": "rpg_lua", "arguments": {"code": "return tostring(R.hp)"}}
```

Refuses any snippet that mentions `clearSim`, `loadSave`, or `pendingGen`
(case-insensitive) unless `allow_destructive: true` is also passed -- those are exactly
the calls `rpg_plugins/README.md` says never to make while the user is playing live:

```json
{"tool": "rpg_lua", "arguments": {"code": "sim.clearSim()"}}
```
```json
{"ok": false, "error": "refused: snippet references ['clearsim']; pass allow_destructive=true to override", "matched": ["clearsim"]}
```

```json
{"tool": "rpg_lua", "arguments": {"code": "sim.clearSim()", "allow_destructive": true}}
```

---

## Verification

All seven tools were exercised end-to-end against Drew's actual running game session
(not just config/schema checks): `rpg_status` returned real live player/inventory/quest
state; `rpg_api` read real `R.RECIPES`/`R.ACCS`/etc. via `execute_lua` (`tables_source:
"live"`); `rpg_search` returned genuinely relevant ranked hits across code and docs;
`rpg_hub` posted a real line that is now in `knowledge/rpg-hub.md`; `rpg_reload` reloaded
the (then-absent) `guide` plugin and returned a correct status snapshot; `rpg_lua` refused
a `clearSim` call and separately evaluated a benign read; `rpg_screenshot` captured a real
PNG from the live canvas. `python scripts/test_rpg_tools.py` (45 offline tests, mocked
bridge) and `python scripts/ci.py` (manifest + every existing suite) both pass.

**Note:** the MCP server process Drew is already connected to will keep reporting
"manifest inconsistent" for these tools until the session reconnects (`/mcp`) and reloads
`powder_toy_mcp.py` -- the manifest/dispatch/schema wiring is correct in the source, this
is just the running process holding stale in-memory declarations.
