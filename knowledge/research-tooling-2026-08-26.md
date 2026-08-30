# Research front 5/5: Tooling, Performance, Observability (2026-08-26)

Scope: `powder_bridge/client.py`, `powder_ext/build_tools.py`, `powder_ext/agent_tools.py`,
`powder_ext/blueprint_tools.py`, `scripts/save_research.py`, `scripts/regression.py`,
`scripts/realism_watch.py`, `knowledge/tpt-lua-api-cheatsheet.md`, `knowledge/REALISM_RUNBOOK.md`,
`bridge_src/_base/bridge_base.lua`. Read-only against the live game the whole session (only
read-only `executeLua`/inspection calls were used; no MCP mutation tools were called).

**Note on sourcing:** this session's WebSearch budget was exhausted before this task started
(200/200 used elsewhere). All external facts below come instead from `curl`/`WebFetch` pulls of
primary sources — the `The-Powder-Toy/The-Powder-Toy` GitHub repo (`master` branch, fetched
2026-08-26) and Anthropic's own tool-design writeup — not from search snippets. Every claim about
game internals is quoted or paraphrased from the actual C++/Lua source, not from memory or the
wiki, so it should be more reliable than the cheat-sheet it supersedes on these points, not less.

---

## (a) Headless / multiple instances

**Command-line flags** (verified in `src/PowderToy.cpp`, `Main()`, the argument-parsing loop and
the `arguments[...]` reads that follow it):

| flag | effect |
|---|---|
| `ddir:DIRECTORY` | chdir's into `DIRECTORY` before anything else runs — prefs, stamps, and (relevant here) whatever `autorun.lua`/token file live next to `powder.exe` are then read from *that* directory instead of the default. This is the mechanism for a second isolated instance. |
| `disable-network` | disables internet connections (checked as a standalone boolean-style arg, `trueArg`/`trueString` treats a bare flag as `true`) |
| `scale:N` | window scale factor, sets `prefs["Scale"]` |
| `kiosk` / `kiosk:true` | fullscreen |
| `open FILE` / `FILE` ending in `.cps`/`.stm` / `file://...` | opens a save/stamp on startup |
| `ptsave:ID` | opens an online save (used by `ptsave:` URL handler) |
| `proxy:SERVER[:PORT]` | proxy server |
| `redirect` | redirects stdout/stderr to `stdout.log`/`stderr.log` in the (post-`ddir`) working directory |
| `console` | Windows: allocate a new console instead |
| `cafile:` / `capath:` | TLS certificate bundle/dir override |
| `disable-bluescreen` | disables the crash-handler blue screen |

There is **no dedicated `--headless` flag** — `Main()` unconditionally calls `SDL_Init(0)` and
builds a window. But `ddir` is sufficient to run a second, fully isolated instance side by side
with Drew's live session: point it at a separate directory containing its own `autorun.lua`,
`powder-bridge.token`, prefs, and stamps folder, and it will never touch Drew's save/stamp state.
Combine with `disable-network` for a sandboxed lab instance that can't hit `powdertoy.co.uk`.

**Genuinely headless rendering exists as a *separate* executable**, `src/PowderToyRenderer.cpp`
(a second `main()` entirely, no SDL video/window, not the game binary at all):

```
Usage: PowderToyRenderer <inputFilename> <outputPrefix>
```

It loads a `.cps`/`.stm` `GameSave`, runs one `Renderer::RenderSimulation()` pass with
`decorationAntiClickbait`, and writes `<outputPrefix>.png`. This is meson's own build target
(`src/meson.build` should list it alongside the main `powder` target) and is the right tool for
"render this saved state to an image with zero interaction with any running game session" — see
(c)/(d) below for why that matters for goldens.

**FPS cap / uncapped is a non-obvious API.** `tpt.fpsCap(n)` (`src/lua/LuaMisc.cpp`,
`static int fpsCap`) errors below 2 ("fps cap too small"), and **`2` is the sentinel for
uncapped**, not a real 2 FPS limit — `fpscap == 2` calls `SetSimFpsLimit(FpsLimitNone{})`;
anything `> 2` sets `FpsLimitExplicit{value}`. Reading with no argument returns `2` when uncapped.
So "run this experiment as fast as possible" is `tpt.fpsCap(2)`, not `tpt.fpsCap(9999)`.

**Scripting a lab instance** (concrete recipe, given the flags above):

```powershell
# one-time: a sibling ddir with its own copy of the bridge deployed at a different port (see item 7 below)
powder.exe ddir:D:\powder-toy\lab_instance disable-network scale:1
```

Python side is already ready for this: `PowderClient.__init__` takes `host`/`port`/`token`
(`powder_bridge/client.py:153-167`), so a second client instance is one line
(`PowderClient(port=9877)`); the blocker is that `bridge_src/_base/bridge_base.lua` hardcodes
`local serverPort = 9876` (line ~965) and the token path is hardcoded in
`powder_bridge/client.py:165` (`D:/The-Powder-Toy/build/powder-bridge.token`) — see change #7.

Source: `PowderToy.cpp` lines 246–420 (argument parsing), `PowderToyRenderer.cpp` (full file, 62
lines), `LuaMisc.cpp` lines 196–225 (`fpsCap`).

---

## (b) Bulk data paths — a `snapshot_fast` design

Current state, read directly from the files in scope:

* `world_state` (`powder_ext/agent_tools.py:55-93`, `_WORLD_LUA`) does **one full `sim.parts()`
  iteration** to build per-element counts/bboxes/temps, **plus** a 153×96 `tpt.get_wallmap`
  double loop, **plus** a second 153×96 `sim.pressure` double loop, **plus** a third occupancy
  pass over `sim.parts()` for the 16px empty-rectangle grid. That's 2 full particle scans + 2
  full cell scans (153*96 = 14,688 cells each) per call, all inside one `executeLua`, so it's one
  HTTP round trip — good — but real engine work scales with total particle/cell count every time.
* `find_features` (`powder_ext/build_tools.py:53-109`, `_FEATURES_LUA`) does one `sim.parts()`
  pass to bucket into coarse cells, then **a second full `sim.parts()` pass per connected
  component** (line 95, inside the `for i = 1, math.min(#comps, 24)` loop) to get an exact pixel
  bbox. Worst case (many small components) this is `O(N * components)`.
* `run_test`'s `_measure` (`powder_ext/build_tools.py:144-161`, `_COUNT_LUA`) does a full
  `sim.parts()` scan **plus** a per-cell pressure min/max loop over the assertion's region,
  **on every sampled frame** (`sample_every`, default `frames // 10`) — for a 3000-frame test with
  10 assertions this is potentially hundreds of full-canvas scans.
* The bridge already has two well-designed bounded/paginated bulk actions:
  `spatialSnapshot` (region + stride + field sampling, `bridge_base.lua:466-775`) and
  `partsInventory` (cursor/`max_scan`/`limit` pagination over raw particle slots,
  `bridge_base.lua:281-465`). Both hand-build JSON with `jesc`/`jnum` string concatenation because
  (per the file's own header comment) `json.stringify`/`LuaToJsonValue` **crashes on nested
  tables** — this is why every bridge response is manually concatenated strings, not a generic
  serializer.
* `sim.elementCount([element])` (`src/lua/LuaSimulation.cpp:1345-1352`) reads
  `lsi->sim->elementCount[element]` — an **engine-maintained O(1) counter array**, not a scan.
  `sim.partCount()` (line 83-87) reads `lsi->sim->NUM_PARTS` directly, also O(1). Neither of these
  is used anywhere in the four census/test Lua fragments above, even though `world_state` and
  `_COUNT_LUA` only need *counts* for their headline numbers and pay for a full scan to get them.

**`snapshot_fast` proposal** — a new bridge action, modeled directly on `partsInventory`'s
contract (same cursor/limit/max_scan/region/type fields, same bounded-response discipline) but
with two changes that matter for throughput:

1. **Compact row encoding instead of per-particle JSON objects.** `partsInventory` currently
   emits `{"id":1,"type":2,"x":3,"y":4,"temp":5,"life":6,"vx":7,"vy":8}` per particle — ~70 bytes
   of key text for 8 numbers. A `\t`- or `,`-joined row (`1,2,3,4,5,6,7,8\n`) carries the same
   information in roughly a third of the bytes, with no `jesc`/quote overhead and one string
   concat op instead of eight `jnum`+key-literal concats per record. At the 256-record page limit
   this is the difference between ~18KB and ~6KB per page — fewer pages needed under the existing
   262144-byte response budget, which is the actual throughput lever (HTTP round-trip count, not
   Lua CPU, dominates bulk reads given the bridge processes one request at a time).
2. **Prefer `elementCount`/`partCount` for headline totals; only fall back to a `sim.parts()` scan
   when per-particle detail (position/temp/bbox) is actually requested.** A `snapshot_fast` call
   with `fields: ["counts"]` should be a handful of `elementCount(id)` lookups (bounded by however
   many element IDs are asked for) instead of an `O(N)` scan — this is a free win for `world_state`
   and `_COUNT_LUA`'s `count` metric specifically (items #3 in the priority list).

Binary packing (Lua `string.pack`) is **not available** — TPT bundles Lua 5.1.5 (confirmed by a
literal comment in `LuaScriptInterface.cpp` line 575, `"the idea stolen from lua-5.1.5/lua.c"`,
and `luaL_checkint`/`luaL_optint` usage throughout, which are 5.1 APIs). Manual byte-packing via
`string.char` is possible but adds a per-byte function-call loop in Lua, which is slower than the
string-concat approach above for anything but very large dumps; it's not worth the complexity
until profiling shows the compact-text encoding is the bottleneck rather than HTTP/JSON-decode
overhead on the Python side.

Chunked reads: reuse `partsInventory`'s existing `cursor`/`max_scan`/`limit` contract verbatim —
it is already a well-designed page cursor (advances by `scanned`, not by returned-record index,
so it can't skip live particles created between pages). `snapshot_fast` should be the same
action with an `encoding: "compact"` flag rather than a fork, to avoid maintaining two pagination
implementations.

Source: `bridge_src/_base/bridge_base.lua` lines 1-3 (json.stringify crash comment), 281-465
(`partsInventory`), `LuaSimulation.cpp` lines 83-87 and 1345-1352 (`partCount`/`elementCount`).

---

## (c) Vision loop

`tpt.screenshot([captureUI, fileType])` — confirmed from `src/lua/LuaMisc.cpp:147-158` and
`src/gui/game/GameView.cpp:943-1008` (`GameView::TakeScreenshot`):

* Returns the written filename as a string (or nothing on failure) — `screenshot.png` naming is
  `screenshot YYYY-MM-DD HH.MM.SS.png`, with a `" (N)"` suffix appended if a second screenshot is
  taken within the same wall-clock second (`lastScreenshotTime`/`screenshotIndex` in
  `GameView.cpp:957-971`).
* `fileType`: `0` (default) → `.png`, `1` → `.bmp`, `2` → `.ppm`. Only PNG round-trips cleanly
  through Pillow/numpy without a conversion step, so always pass `0` explicitly.
* `captureUI=0` (default) captures the render-only frame buffer (`rendererFrame`); `captureUI=1`
  dumps the full UI-composited frame via `ui::Engine::Ref().g->DumpFrame()` — for a VLM feed of
  "what does the sim look like", `0` is almost always what you want (no toolbar/menus in frame).
* **Write location is the current working directory** — i.e., whatever `ddir` resolved to at
  startup (see (a)) — there is no separate "screenshots" folder in the flow inspected. For a lab
  instance with its own `ddir`, screenshots land there automatically, already isolated from
  Drew's session.

**Image diffing** ("what changed between frames"): take two PNGs via `tpt.screenshot(0,0)`,
`Image.open(...).convert("RGB")` in Pillow, `numpy.asarray(...)`, then either a plain
`np.abs(a.astype(int) - b.astype(int))` heatmap (cheap, good enough for "did anything move")
or a bounding-box crop of `np.any(diff > threshold, axis=-1)` to hand the VLM only the changed
region instead of the full 612×384 canvas — much smaller image, cheaper API call, and it directly
answers "where" not just "whether".

**Render modes for heat/pressure views** — the Lua surface is `ren.renderMode`, `ren.displayMode`,
`ren.colorMode`/`ren.colourMode`, and `ren.useDisplayPreset(n)`
(`src/lua/LuaRenderer.cpp:1-100`). The preset function has a documented **legacy off-by-one
quirk** — its own source comment says so: for `cmode` in `0..10` it remaps
`cmode = (cmode + 1) % 11` before indexing `Renderer::renderModePresets`
(`LuaRenderer.cpp:56-63`, comment: `// legacy nonsense`), but presets `11..13` (added later) are
indexed directly with no remap. That means the preset index a caller passes and the preset that
actually gets applied disagree for exactly the first 11 entries. **Skip `useDisplayPreset`
entirely for scripted use** and set `displayMode`/`colorMode` directly with their real bit values,
confirmed from `src/simulation/ElementGraphics.h:41-57`:

| view | Lua calls |
|---|---|
| Heat | `ren.displayMode(8); ren.colorMode(1)` (`DISPLAY_AIRH=8`, `COLOUR_HEAT=1`) |
| Pressure | `ren.displayMode(2); ren.colorMode(0)` (`DISPLAY_AIRP=2`) |
| Velocity | `ren.displayMode(4); ren.colorMode(0)` (`DISPLAY_AIRV=4`) |
| Vorticity | `ren.displayMode(128); ren.colorMode(0)` (`DISPLAY_AIRW`) |
| restore default | `ren.displayMode(0); ren.colorMode(0)` |

These match the built-in "Heat Display" (`RENDER_BASC, DISPLAY_AIRH, COLOUR_HEAT`) and "Pressure
Display" (`RENDER_BASC, DISPLAY_AIRP, 0`) preset entries in
`src/graphics/Renderer.cpp:1355-1435` — same visual result as picking them from the in-game menu,
without the index-remap footgun.

For a pure offline vision pass with **zero interaction with Drew's live session at all**,
`PowderToyRenderer <save.cps> <outprefix>` (see (a)) is strictly better than screenshotting the
live sim: it renders a saved stamp/checkpoint to PNG in a separate process with no window, no
bridge call, no contention for the "one request at a time" HTTP server.

Source: `LuaMisc.cpp:147-225`, `GameView.cpp:943-1008`, `LuaRenderer.cpp:1-100`,
`ElementGraphics.h:41-57`, `Renderer.cpp:1355-1435`.

---

## (d) Determinism

Confirmed Lua surface (`src/lua/LuaSimulation.cpp:1986-2023`):

* `sim.randomSeed()` with no args returns 4 integers (two 64-bit RNG-state words split into
  32-bit halves); called with 4 integers, it **sets** the RNG state back to exactly that. This is
  a real save/restore of the simulation's PRNG state, not just a seed — round-tripping
  `local a,b,c,d = sim.randomSeed()` ... `sim.randomSeed(a,b,c,d)` restores the exact stream.
* `sim.ensureDeterminism([bool])` toggles `sim->ensureDeterminism` — get/set, no return value
  change beyond the boolean.
* `sim.hash()` (line ~2004, right next to these) returns `sim->CreateSnapshot()->Hash()` — a
  full-state content hash of the simulation snapshot. This is the actual "did two runs produce
  bit-identical results" primitive, and **nothing currently in scope calls it**.

**Reproducibility gap:** `scripts/regression.py` never touches the live sim at all — it is purely
an offline blueprint-compiler regression suite (compile practices/modules/goldens and diff
primitive counts, `regression.py:37-68`). That's valuable but it only proves the *compiler* is
stable; it says nothing about whether `run_test` (`powder_ext/build_tools.py:183-245`) produces
the same particle counts/temperatures run over run. Given `sim.hash()` exists for exactly this,
`run_test` is the natural place to close the gap: capture `sim.randomSeed()` before a test,
`sim.hash()` after, and expose both in the returned dict so a caller (or `build_stage`) can assert
"this test is deterministic" by re-running with the saved seed and comparing hashes, rather than
only asserting on the aggregate metrics it already checks (`count`/`tavg_c`/etc., which are
sensitive to but don't *prove* determinism — two different particle-level outcomes can produce the
same aggregate temperature average).

Recommended shape: `run_test` gains an optional `capture_hash: true` argument; on request it
calls `sim.randomSeed()` before the test frames run and `sim.hash()` after, returns
`{"seed": [a,b,c,d], "hash": N}` alongside the existing `assertions`/`trace`. A second call with
`{"seed": [a,b,c,d], ...}` replays deterministically (calls `sim.randomSeed(a,b,c,d)` first) and
the harness can assert `hash == recorded_hash` — a strictly stronger regression signal than
today's metric-threshold assertions, for zero new bridge actions (both `randomSeed` and `hash`
are already exposed to `executeLua`, so this is pure Python-side work in `build_tools.py`).

Source: `LuaSimulation.cpp:1986-2023` (`randomSeed`, `hash`, `ensureDeterminism`).

---

## (e) MCP ergonomics

Anthropic's own "Writing tools for agents" guidance (fetched directly,
anthropic.com/engineering/writing-tools-for-agents) gives four concrete, checkable rules, matched
against what's actually in scope here:

1. **"Describe your tool to a new hire."** `build_tools.py`'s module docstring already does this
   well for `run_test`/`build_stage`/`run_pipeline` (explicit argument shapes in the docstring,
   e.g. `run_test`'s one-line arg spec at `build_tools.py:184-186`). Tools elsewhere in
   `powder_toy_mcp.py` that aren't in scope for this pass should be audited against the same bar —
   a small model needs the *shape*, not just a one-line summary.
2. **Unambiguous parameter names.** The guidance's own example is `user` → `user_id`. In scope,
   `set_part_property`/`set_particle_property` (`client.py:1255-1283`, `1333-1335`) use a bare
   `value: Any` — fine for a typed Python caller, but the MCP-exposed wrapper around it should
   make the *type* of `value` explicit in its schema/description per property name (`temp` is a
   float in Kelvin, `life`/`tmp`/`tmp2` are ints, `ctype` is an element-name string) rather than
   leaving a small model to guess from an `Any`.
3. **Consolidate multi-step operations into one tool call.** This codebase already does the thing
   Anthropic recommends, and does it well: `build_stage` (`build_tools.py:252-301`) is
   compile+lint-gate → checkpoint stamp → real build → run all tests → record_attempt, as *one*
   MCP call with a single pass/fail plus a `failed_gate` pointer to what to fix — exactly the
   "one tool call runs a full stage" pattern the task asks about, already implemented. Same for
   `run_pipeline` (line 304-338) chaining stages with `find_features` refreshed between them. No
   change needed here beyond making sure every new capability follows this shape rather than
   exposing its sub-steps as separate tools.
4. **Response-size control.** `spatial_snapshot`/`parts_inventory` already do real budget
   enforcement — `max_response_bytes` clamps `SPATIAL_MAX_RESPONSE_BYTES=262144` client-side
   (`client.py:51,187-194`) *and* the Lua handler independently re-checks
   `#result + 1 > maxResponseBytes` before returning (`bridge_base.lua:772-774`) — belt-and-braces,
   good. `run_test`'s `trace` is explicitly truncated to `trace[-40:]`
   (`build_tools.py:243`) rather than returning the full per-sample history. The one thing missing
   per Anthropic's guidance is *steering instructions on truncation* — when `spatialSnapshot`
   truncates, the response has `truncated: true` and a `reasons` array (good), but no
   human-readable "next step" hint the way `run_pipeline`'s `next_action` field does
   (`build_tools.py:338`); worth copying that field's pattern onto the truncated-response path too.

**Streaming logs:** nothing in scope streams — `run_test` and `build_stage` return one final JSON
blob after the whole test/stage completes, so a 3000-frame test with 10 sampled assertions is a
single long-blocking call with no intermediate signal. For a small model driving `next_task` in a
loop this is fine (it wants the final verdict, not a stream), but for Drew watching a long build
interactively, a `logs/` sidecar file that `build_stage`/`run_pipeline` append one line to per gate
(mirroring `realism_watch.py`'s `_log()` pattern, `scripts/realism_watch.py:59-60`) would give a
`tail -f`-able progress signal without changing the MCP call contract at all.

Source: Anthropic, "Writing tools for agents" (anthropic.com/engineering/writing-tools-for-agents,
fetched 2026-08-26); in-repo files as cited inline above.

---

## (f) Repo hygiene

`D:/powder-toy` is **not** a git repository (`git rev-parse --is-inside-work-tree` →
`fatal: not a git repository`) and measured at **748MB total** on disk right now, broken down as:

* `knowledge/` — **602MB**, of which `knowledge/saves/` alone is **504MB** (community-save
  harvests from `scripts/save_research.py`: each save gets a `parts.jsonl` + two `.map.txt` dumps
  under `knowledge/saves/<id>/`, several individually 10–21MB — e.g. `495241/`, `479043/`,
  `2894043/`, `2654235/` each ~21MB).
* Five stale `powder_toy_mcp.py.bak.pre-*` copies at the repo root (`pre-agent-tools`,
  `pre-blueprint`, `pre-ext`, `pre-integrator`, `pre-playbook`, 199–222KB each) — this is exactly
  what git history is for; they exist only because there's no version control to fall back on.
* Stray root-level binary/log noise: `titanic-scene-screen.png` (1.1MB), two more PNGs, `.log`
  files, `__pycache__/`.

**Recommendation: `git init` now**, with a `.gitignore` that excludes the bulk/regenerable data
and keeps the actually-authored knowledge:

```gitignore
# regenerable / bulk research dumps (scripts/save_research.py output)
knowledge/saves/

# stale hand-rolled backups — use git history instead
*.bak.pre-*
powder_toy_mcp.py.bak*

# Python
__pycache__/
*.pyc

# logs / run artifacts
logs/
*.log

# ad hoc screenshots dropped at repo root by manual tpt.screenshot() calls
/*.png
/*.bmp

# empty scratch ddir
ddir-empty/
```

Keep tracked: `knowledge/*.md`, `knowledge/*.json` (`playbook.json`, `chemistry-rules.json`,
`materials-catalog*.json`, etc.), `knowledge/golden/`, `knowledge/modules/`,
`knowledge/attempts.jsonl` (small, and per `agent_tools.py`'s own docstring this *is* the future
SFT/DPO dataset — it should absolutely be versioned, not just left as a local file one `rm` away
from gone), and obviously all of `powder_ext/`, `powder_bridge/`, `bridge_src/`, `scripts/`. A
first commit should happen *before* anything in the priority list below touches
`bridge_src/_base/bridge_base.lua` or `powder_bridge/client.py` — right now a bad edit to either
has no undo.

**CI-ish script:** three pieces already exist independently — `scripts/regression.py` (offline
compiler/lint/golden suite, exit-code-driven, already has `--add`/`--update` for maintaining
goldens), `scripts/test_lint.py` (not read in this pass but present in `scripts/`), and
`extension_self_test` (an MCP tool already listed in the tool roster, i.e. some self-check already
exists at the extension level). None of them are wired together. A single
`scripts/ci.py` that runs all three in sequence, stopping at (and clearly labeling) the first
failure, is a small, mechanical piece of work — see change #10 below — and is what makes "does
this change break anything" a one-command question instead of three commands someone has to
remember to run in the right order.

---

## Ten prioritized changes

Ranked by (gain / effort), file-mapped, most impactful first.

| # | Change | Files | Effort | Gain |
|---|---|---|---|---|
| 1 | `git init` + `.gitignore` (exclude `knowledge/saves/`, `*.bak.pre-*`, `__pycache__/`, `logs/`, root PNGs/logs; keep `knowledge/*.md`, `*.json`, `golden/`, `modules/`, `attempts.jsonl`) | repo root (new `.gitignore`) | S | High — currently zero undo history on every hand-edited file in the whole framework |
| 2 | Un-hardcode the bridge port and token path so a second instance is possible at all | `bridge_src/_base/bridge_base.lua` (`local serverPort = 9876`, ~line 965); `powder_bridge/client.py:165` (hardcoded token path) | S | High — blocks a lab instance entirely today |
| 3 | Stand up a second "lab" TPT instance via `ddir:` + isolated port, for experiments that must not collide with Drew's live session | new `lab_instance/` ddir + a `build_autorun.py`-deployed bridge copy on a different port; `powder_bridge/client.py` (`PowderClient(port=...)`, already supports this) | M | High — the core ask: experiments and Drew's session stop colliding |
| 4 | `sim.hash()`/`sim.randomSeed()`-based determinism capture in `run_test`, so passes are provably reproducible, not just metric-threshold passes | `powder_ext/build_tools.py` (`run_test`, lines 183-245) | M | High — closes the one reproducibility gap `scripts/regression.py` explicitly doesn't cover (it never touches the live sim) |
| 5 | `snapshot_fast` bridge action: compact delimited rows instead of per-particle JSON keys, reusing `partsInventory`'s cursor/limit/max_scan contract; use `elementCount`/`partCount` for count-only requests instead of a full `sim.parts()` scan | `bridge_src/_base/bridge_base.lua` (new action, modeled on `partsInventory`, lines 281-465); `powder_bridge/client.py` (new typed method near `parts_inventory`, line 867) | M | High — cuts bulk-read bytes ~3x and turns O(N) count queries into O(1) |
| 6 | Swap `sim.parts()` full scans for `sim.elementCount(id)`/`sim.partCount()` wherever only totals are needed | `powder_ext/agent_tools.py` (`_WORLD_LUA`, lines 55-93); `powder_ext/build_tools.py` (`_FEATURES_LUA` lines 53-109, `_COUNT_LUA` lines 144-156) | S | Medium-High — free CPU/latency win on the three hottest census paths, no protocol change |
| 7 | Direct `ren.displayMode`/`ren.colorMode` bit constants for a VLM heat/pressure vision loop (skip `useDisplayPreset`'s legacy off-by-one remap entirely) | new `powder_ext/vision_tools.py` wrapping `tpt.screenshot(0,0)` + the mode-switch calls; Pillow/numpy diff helper | S | High — direct, correct visual feedback path, currently nonexistent in scope |
| 8 | Wire up `PowderToyRenderer` (standalone headless save→PNG) as an offline golden-image check | build target `PowderToyRenderer` (`src/PowderToyRenderer.cpp`, already in source tree); `scripts/regression.py` (new golden-image mode using `build_stage`'s existing checkpoint stamps) | M | Medium-High — zero-contention regression rendering, doesn't touch the live bridge at all |
| 9 | `scripts/ci.py`: chain `regression.py` + `test_lint.py` + `extension_self_test` into one exit-code | new `scripts/ci.py`; imports `scripts/regression.py`, `scripts/test_lint.py`, `powder_toy_mcp.extension_self_test` | S | Medium — turns "did I break anything" into one command |
| 10 | Truncation responses get a `next_action`-style human-readable hint (mirroring `run_pipeline`'s existing field) instead of just `truncated: true` + `reasons` | `bridge_src/_base/bridge_base.lua` (`spatialSnapshot`/`partsInventory` truncation paths, ~lines 428-465, 720-765); `powder_ext/build_tools.py:338` (existing pattern to copy) | S | Medium — small-model ergonomics per Anthropic's own tool-design guidance |

---

## Sources

- The-Powder-Toy GitHub repo, `master` branch, fetched 2026-08-26 via `curl`/raw.githubusercontent.com:
  `src/PowderToy.cpp`, `src/PowderToyRenderer.cpp`, `src/lua/LuaSimulation.cpp`,
  `src/lua/LuaMisc.cpp`, `src/lua/LuaRenderer.cpp`, `src/lua/LuaScriptInterface.cpp`,
  `src/gui/game/GameView.cpp`, `src/gui/game/GameController.cpp`, `src/graphics/Renderer.cpp`,
  `src/graphics/RendererSettings.h`, `src/simulation/ElementGraphics.h`.
- Anthropic, ["Writing tools for agents"](https://www.anthropic.com/engineering/writing-tools-for-agents),
  fetched 2026-08-26.
- In-repo: `D:/powder-toy/powder_bridge/client.py`, `powder_ext/build_tools.py`,
  `powder_ext/agent_tools.py`, `powder_ext/blueprint_tools.py`, `scripts/save_research.py`,
  `scripts/regression.py`, `scripts/realism_watch.py`, `bridge_src/_base/bridge_base.lua`,
  `knowledge/tpt-lua-api-cheatsheet.md`, `knowledge/REALISM_RUNBOOK.md`.
- Local `du`/`git rev-parse` measurements against `D:/powder-toy`, 2026-08-26 (see (f)).
