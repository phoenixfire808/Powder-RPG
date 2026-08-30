# Research round 2: Powder Toy building bot (2026-08-25)

Follow-up to `research-building-bot-2026-08-25.md` (round 1). Round 1 already covered: WIFI/PRTI-PRTO/
PSTN-FRME/DTEC/TSNS-PSNS/CLNE-PCLN/CRAY/CONV wiki pages, save-format internals (OPS1/BSON/bzip2), the
confirmed absence of a headless TPT mode, the save-browser search API, ~90 `simulation.*` function
*names* from `LuaSimulation.cpp`, Voyager/T2BM/Factorio-Learning-Environment/Code-as-Policies/Eureka/
ReAct-Reflexion/DreamCoder/LATM/PG-TD, COPE/Aider decomposition, "Try Again Don't Look Back" (arXiv
2607.26117), "How Many Tries" (arXiv 2604.10508), RS-DPO/STaR/ReST, SkillBrew/SkillOps dedup, Ollama
grammar-constrained decoding, BFCL v4 format sensitivity, and few-shot exemplar counts. This pass does
not repeat any of that. Four parallel research forks covered Threads A-D below; a fifth check
(`Bash`/`Grep`) confirmed round 1's roadmap items already implemented since 2026-08-25's first pass:
schema-constrained decoding (`scripts/blueprint_agent.py` `chat()` sends `format:<schema>` to Ollama and
`response_format:{"type":"json_schema",...}` to OpenAI-compatible servers), a 2-round repair cap with a
blind-resample fallback (`--rounds 2 --resample 1` defaults, `solve()`), a golden regression suite
(`scripts/regression.py` + `knowledge/golden/*.json`, 2 goldens present), and attempt logging
(`knowledge/attempts.jsonl` via `record_attempt`, 1 entry present as of this pass). No files other than
this one were modified; the game was not touched.

---

## Thread A — TPT deep techniques (exotic elements, mechanical, computers, portals)

**Access note:** the TPT wiki (`powdertoy.co.uk/Wiki/index.php?title=Element:*`) is now gated by an
Anubis anti-bot challenge — every direct element-page fetch attempted this pass returned 403. This is
new since round 1 (which fetched several element pages directly). Future passes needing wiki pages
should budget for a real browser session or accept search-snippet-only coverage; the forum
(`Discussions/Thread/View.html`) was still directly fetchable throughout.

**Exotic/gravity-confinement elements (GPMP, GRVTY, EXOT, WARP, BHOL, NBHL, SING).**
- **BHOL**: creates a negative-gravity field that sucks in particles like a pressure-free vacuum;
  requires Newtonian gravity mode. Bigger BHOL blob -> larger gravity grid -> stronger pull. Newtonian
  custom gravity is capped at **-20 to 20**. Can be spawned via console by over-compressing particles.
- **GPMP vs WHOL for reactor containment** — forum Thread=26827 ("On using WHOL and GPMP for
  reactors", https://powdertoy.co.uk/Discussions/Thread/View.html?Thread=26827, new vs. round 1): GPMP
  rings toggle on/off but trap heat with no radiating hole, causing instability without a deliberate
  gap; WHOL rings are always-on and let core heat conduct through the ring wall directly. One build:
  thorium/polonium/deuterium core inside a distilled-water or H+O buffer with a noble gas for ignition
  pressure reaches **~1000C** with the water buffer (vs. ~4x hotter without it). A refined "oval ring,
  single apex hole" design directs steam to turbines and self-pulses: neutron reaction -> expulsion ->
  pressure drop -> gravity pulls material back -> repeat, minimizing fuel top-ups.
- **EXOT**: transforms into **WARP** gas when hit with enough electron radiation, or when its `tmp2`
  reaches **6003**. Pulses brightness on a `tmp`-driven cycle and can transmute touching elements only
  during a few frames at the peak of that pulse.
- **WARP**: always max-temperature, max-pressure gas; generates its own ELEC while airborne — usable
  as a self-sustaining heat/pressure source once triggered. Threads 17013 ("Warp core") and 14027
  ("Warp from exotic matter") discuss triggering it but no finished generator design was found.
- **GRVTY, NBHL, SING**: no usable numeric data recovered this pass (wiki blocked, no dedicated forum
  builds found distinct from BHOL/GPMP/WHOL). Flagging plainly as unrecoverable this pass, not as
  "doesn't exist."

**Advanced FRME/PSTN mechanics** (forum Thread=16174, 18181, 16021, 18567, 18900 — all new vs. round
1's tutorial threads 1101093/1382457):
- PSTN extends based on length when sparked by PSCN; minimum 2px, normal max push **31px**, adjustable
  via `.tmp` (push amount) and `.tmp2` (push distance, hard-caps around **255px**).
- FRME lets a piston push multiple particles at once; FRME's pull radius from the piston center is
  **+-15px** (a community "FRME extender" mod by cracker64 exists to work around this — no build
  details recovered). `FRME.tmp = 1` makes it non-sticky.
- "Piston ships" (passive-motion walkers): two body sections separated by a perpendicular line of FRME
  in the direction of travel — the core mechanism for FRME/PSTN walkers/steppers. No worked
  timing-gear or multi-leg stepper build with concrete frame counts was found.

**TPT computers and data buses — three complete architectures with numbers:**

| Build (thread/saves) | Width | Registers/Memory | ALU | Data-bus element | Clock |
|---|---|---|---|---|---|
| "Smallest 8-bit Computer Ever" (Thread=22062, saves 2169745/2169805/2172222/2172235) | 8-bit | 4 registers + 1 standby, 30-word RAM, 31-word instruction memory, 15 instructions | — | not specified | 0.2-3 Hz, instruction-driven; 65x98px, ~3800 particles |
| **C4C 1** (Thread=21752, saves 2148569/2149714) | 8-bit, semi-Von Neumann | 16 GP registers (AX-PX), 256B ROM + 256B RAM | 7-function ALU (OR/AND/NOT/SHL/SHR/ADD/MOV+STORE/LOADRAM/LOADROM) | **FILT** — each ROM cell is a FILT particle whose **CTYPE 30-bit wavelength field** encodes a byte, laid out as a 16x16 address grid; a PSTN+DTEC tool programs the grid | **0.02 Hz** ("designed to teach patience") |
| **Ray162K** (Thread=19916, saves 1748157/1748719) | 16-bit | 3 registers (AX/BX/CX), 8 IO ports, 2 KiB memory (1024x16-bit) | add/sub/shift/rotate/OR/AND/XOR/NOT, no mul/div | FILT rectangle at (224,235) for memory; heavy DRAY/RAY-family use for fast memory ops | memory op = 8 frames, full instruction = 16 frames (two mem ops per window); no WIFI/layering used |

**ARAY/BRAY signal logic** (Thread=18952, 2413506, 12733, 21817, 12196 — wiki page blocked, forum
content recovered): ARAY emits a directional **BRAY** ray when sparked by any metal; BRAY is normally
invisible in the menu (mod/script-only). Logic gates are built from compact ARAY ray intersections with
precise timing — e.g. an XOR gate fires each input into METL to redirect a ray at the opposing input's
path, so a crossing ray only completes the circuit when exactly one input is sparked. Brown BRAY has no
wavelength and doesn't spark conductors or interact with FILT — BRAY color is itself a logic-channel
selector, analogous to FILT's CTYPE wavelength bus. No concrete gate-propagation-delay numbers were
recovered.

**Portal-based heat export** (Thread=25025, 24334, 22894 — new): PRTI buffers whatever enters it
off-simulation; PRTO releases it matched by **temperature channel**, not just id — with no matching
PRTO it just absorbs particles like a capacity-limited VOID. **Documented failure mode directly
relevant to reactor cooling**: portals can hold more than one particle per cell, so shuttling coolant
through them creates "ghost heat" — effectively double the coolant mass is present versus what's
rendered. One user reported hot "glow" disappearing entirely after ~10s looping through a PRTI/PRTO
pair (particle loss, not heat export). **No confirmed working portal-heat-export design with real
temperature deltas was found — treat as a known-hazardous pattern to avoid, not a technique to adopt.**

**Reactor control — new author write-up with hard numbers.** Thread=27188 ("MONR reactor manual") is
the standout find: core temp held ~**500C**; control-rod insertion levels **0 (idle)-4 (full)**;
boiler held above **130C** (efficient boiling) and below **180C** (overheat); coolant container
optimal **70-80C**, warning at **>=90C**; a **1064C** safety threshold triggers automatic neutron-poison
injection; shutdown sequence holds rods fully inserted for **40 seconds** before idling; final
safe-shutdown state is **<160C and <5 PSI**. CRAY deletes CRMC (conductive cement) lines to free stuck
rod/piston joints; NSCN/PSCN manually open/close reactor hatches. Thread=27033 ("Project Reactor") and
Thread=7395 ("Pressure-controlled Nuclear Power Reactor") are also new but shallower — turbine loop
described only qualitatively, no numbers recovered.

**Not found / explicitly ruled out this pass:** GRVTY/NBHL/SING community-build data; a working
portal-based heat exporter with real numbers; a walking/stepper-leg mechanism with frame-level timing;
quantified ARAY/BRAY gate propagation delay.

---

## Thread B — TPT Lua API cheat-sheet (corrected signatures)

Verified by fetching actual source (not the wiki, which is now bot-walled — see Thread A) from
`github.com/The-Powder-Toy/The-Powder-Toy` (`master` branch, fetched 2026-08-25):
`src/lua/LuaSimulation.cpp` (2289 lines, the `simulation`/`sim` table), `src/lua/LuaElements.cpp`
(`elements`/`elem`), `src/lua/LuaEvent.cpp` (`event`/`evt`), `src/lua/LuaMisc.cpp` (`tpt`), and
`src/lua/luascripts/compat.lua` (the auto-loaded backward-compat shim that defines legacy names —
this is the piece round 1 didn't know existed and is the answer to several "does X still work"
questions below). A companion pass by a research fork cross-checked the same source independently and
its summary is saved at `knowledge/tpt-lua-api-cheatsheet.md` (not part of this deliverable, produced
by another process this session — cross-referenced here, not duplicated).

**The headline correction, precisely stated:** round 1 flagged `sim.loadSave`'s signature as guessed
and wrong. The actual problem is a category confusion, not a wrong arg order: **`sim.loadSave(saveID)`
is not a local-stamp loader at all** — it opens the online save browser's preview UI for a numeric
Browse-ID save (`LuaSimulation.cpp:1103`, calls into `gameController`'s online-save-preview path). The
function that actually loads a locally-saved stamp is **`sim.loadStamp`** (`LuaSimulation.cpp:992`,
separate function, separate registration entry). If any script hangs or opens a UI dialog unexpectedly
after calling a "load" function, check whether `loadSave` was called instead of `loadStamp` — this is
an easy name confusion since both exist side by side in the same table.

**Frame-stepping — confirmed a real deterministic primitive exists**, contrary to round 1's uncertainty:
`sim.frameRender([n]) -> queued:int` (`LuaSimulation.cpp:1568`). With no args it returns the number of
frames still queued to simulate; called with `n` it queues exactly `n` frames to run **while paused**
(`AssertInterfaceEvent` — callable from the console/an external script driver). The deterministic loop
is: `sim.frameRender(n)` then poll `sim.frameRender()` until it returns 0 (or count `event.AFTERSIM`
firings, which fire once per simulated frame). This is a real, precise alternative to this project's
current `tpt.set_pause(0) tpt.set_pause(1)` toggle-loop (`powder_ext/build_tools.py:166`,
`scripts/fix_pods_and_retest.py:100`), which advances frames by racing real wall-clock time between two
separate Lua calls over the bridge — exactly the "wall-clock tool latency silently advances real frames"
pitfall the playbook's own `checkpoint_verify_loop` practice already warns about
(`knowledge/PLAYBOOK.md`). `frameRender` sidesteps that race entirely.

**`tpt.set_pause` is not a dead/guessed name — it is real, via the compat shim, not native C++.**
`LuaSimulation.cpp` has no `set_pause` function; the actual native pause getter/setter is
**`sim.paused([bool]) -> bool`** (`LuaSimulation.cpp:68`, get returns current state with 0 args, set
takes a bool). `tpt.set_pause` is defined in `luascripts/compat.lua:118`:
`tpt.set_pause = fake_boolean_wrapper(sim.paused, false)` — a `0`/`1`-tolerant wrapper auto-loaded into
every script's environment (`LuaMisc.cpp`'s `compatChunk`/autorun mechanism). **This project's existing
`tpt.set_pause(1)`/`tpt.set_pause(0)`/`tpt.set_pause()` calls throughout `blueprint_tools.py`,
`build_tools.py`, `agent_tools.py`, and the `scripts/*.py` helpers are all valid and will keep working**
— no fix needed there. Prefer `sim.paused(...)` in new code only for symmetry with `sim.frameRender`,
not because `set_pause` is broken.

### Cheat-sheet (grouped by namespace; each entry: `call(args) -> return`, source)

**`simulation.*` / `sim.*`** (all in `LuaSimulation.cpp` unless noted):
- `partCreate(newID, x, y, type[, v]) -> id` — `newID=-1` picks the first free slot, `-2` requires a
  tool-context event, returns `-1` on failure (:324).
- `partProperty(id, field[, value])` — get (1 return) or set (0 returns); `field` is a property name
  string (e.g. `"temp"`, `"ctype"`) or a numeric `FIELD_*` constant (:416).
- `partPosition(id[, x, y]) -> x, y` — get (2 returns) or move the particle (:380).
- `partID(x, y) -> id | nil` (:358). `partChangeType(id, newType)` (:313, no return).
- `partKill(id)` or `partKill(x, y)` (2-arg form deletes whatever's at that cell) (:478).
- `partExists(id) -> bool` (:493).
- `partNeighbors(x, y, r[, type]) -> {ids}` (also aliased `partNeighbours` and lowercase
  `neighbors(x,y[,r,type])`/`neighbours` via compat) (:269).
- `pressure(x, y[, v])`, `velocityX(x, y[, v])`, `velocityY(x, y[, v])`, `ambientHeat(x, y[, v])`,
  `gravityMask(x, y[, v])`, `gravityMass(x, y[, v])`, `wallMap(x, y[, v])`, `elecMap(x, y[, v])`,
  `fanVelocityX/Y(x, y[, v])` — **all share one calling convention** (`LuaBlockMap` helper, :106-172):
  2 args = get 1 cell; 3 args = set 1 cell (clamped to the field's min/max, e.g.
  `MIN_PRESSURE`/`MAX_PRESSURE`); 5 args `(x,y,w,h,v)` = set a rectangular block. **Coordinates here are
  in CELL units (the coarse air/pressure grid, `CELL`=4px), not raw pixel coordinates** — this is a real
  trap for a builder tool that otherwise works in pixel coords for particle placement.
- `gravityField(x, y) -> forceX, forceY` — read-only (:225).
- `createLine(x1,y1,x2,y2[,rx,ry,c,brushID,flags])`, `createBox(x1,y1,x2,y2[,c,flags])` — dual-mode:
  called outside a UI/tool event they draw a raw element line/box directly (`c` = element id, no
  return); called inside a tool event they use the active brush/tool with UI semantics (:539, :571).
- `clearSim()` (:909), `clearRect(x,y,w,h)` (:917, w/h are inclusive-minus-one internally, pass
  actual width/height), `resetTemp([onlyConductors])` (:929), `resetPressure([x,y[,w,h]])` (:947),
  `resetVelocity([x,y[,w,h]])` (:1955), `resetSpark()` (:1978) — all cell-grid-scoped like the field
  accessors above.
- `saveStamp([x,y,w,h,includePressure=true]) -> filename:string` (:978, pixel coords here, defaults to
  the whole canvas).
- `loadStamp(id_or_filename[, x, y, hflip, rotation, includePressure]) -> 1 | nil, err` (:992) — **id or
  filename first**, x/y placement second (contra any earlier `(x,y,name)` guess); accepts either a
  numeric stamp-list index or a 10-char stamp name string; `rotation` is `& 3` (0-3 quarter-turns).
- `deleteStamp(id_or_filename)` (:1057), `listStamps() -> {stamp_id_strings}` (:1087).
- `loadSave(saveID[, ...])` / `reloadSave()` / `getSaveID() -> id, version` (:1103-1136) — **online
  Browse-ID preview UI, not a local loader; do not use for stamps** (see correction above).
- `paused([bool]) -> bool` (:68, native; `tpt.set_pause` is the compat alias, see above).
- `frameRender([n]) -> queued:int` (:1568, native; also aliased lowercase `framerender` via compat).
- `takeSnapshot()` (:1600), `historyRestore() -> bool` (:1609), `historyForward() -> bool` (:1618) —
  the undo/redo stack, not a general-purpose snapshot/diff tool.
- `edgeMode([mode]) -> mode` (:1180), `gravityMode([mode]) -> mode` (:1195),
  `customGravity([gx, gy]) -> gx, gy` (:1210 — 1-arg form sets Y only, X=0; 2-arg sets both).
- `elementCount([id]) -> count`, `partCount() -> count` (aliased `tpt.get_numOfParts`).
- `temperatureScale([scale])`, `randomSeed([n])`, `hash() -> int`, `ensureDeterminism([bool])`.
- Iterator-style helpers: `parts()`, `pmap(x,y)`, `photons(x,y)`, `brush(id)` — closures for Lua
  `for`-loop iteration over live particles/brushes (:1380-1554).

**`elements.*` / `elem.*`** (`LuaElements.cpp`):
- `allocate(group, name) -> newID | -1` (:313) — registers `GROUP_PT_NAME` as the identifier; group/name
  may not contain `_`; group `"DEFAULT"` is reserved; returns `-1` if the identifier already exists or
  no ID slot is free. **This is the actual custom-element creation entry point**, confirming round 1.
- `element(id[, table])` (:401) — get returns the full property table; set (`table` arg) requires a
  mutable-tools event context and writes every field present in the table onto the native element
  struct.
- `property(id, name[, value[, mode]])` (:546) — single-field get/set, cheaper than round-tripping the
  whole `element()` table for one field.
- `free(id)` (:716, deletes a custom element), `exists(id) -> bool` (:755, confirms round 1's guess),
  `loadDefault([id])` (:762, resets to stock properties), `getByName(name) -> id` (:835).

**`event.*` / `evt.*`** (`LuaEvent.cpp`, 73 lines total):
- `register(eventType, fn) -> fn` (`fregister`, :5) — `eventType` must be one of the constants below;
  registering runs `fn` on every occurrence (returns the same `fn` for chaining/removal).
- `unregister(eventType, fn)` (:19).
- `getModifiers() -> int` (:32, current keyboard-modifier bitmask).
- Event-type constants (all upper-case natively; compat.lua adds lowercase aliases
  `event.tick`/`event.beforesim`/`event.aftersim`/etc.): `TEXTINPUT, TEXTEDITING, KEYPRESS, KEYRELEASE,
  MOUSEDOWN, MOUSEUP, MOUSEMOVE, MOUSEWHEEL, TICK, BLUR, CLOSE, BEFORESIM, AFTERSIM, BEFORESIMDRAW,
  AFTERSIMDRAW`. **`AFTERSIM` fires exactly once per simulated frame** — the correct hook for exact
  frame counting if not simply polling `frameRender()`.

**`tpt.*`** (`LuaMisc.cpp`) — render/system, not simulation:
- `screenshot([captureUI=0, fileType=0]) -> filename | nil` (:147) — **the only render-to-disk call in
  the entire API**; `graphics.*` (not separately fetched this pass, listed on the wiki) is draw-only
  (`drawPixel`/`drawLine`/`drawRect`/`fillRect`/`drawCircle`/`drawText`/etc.) — there is no pixel-readback
  function outside of `tpt.screenshot` writing a file to disk.
- `record(bool) -> recordingFolder:int` (:169) — video-frame-sequence recording, a second, coarser
  screenshot-adjacent path.
- `getUserName()`, `installScriptManager()`, `debug([flags])`, `fpsCap([n>=2])`, `drawCap([n|"display"])`,
  `log(...)` (aliased to `print`), `version` (a table: `major/minor/build/upstreamMajor/...`).
- Compat-layer aliases worth knowing (`luascripts/compat.lua`): `tpt.set_pause` (-> `sim.paused`),
  `tpt.reset_spark`/`tpt.reset_velocity` (-> `sim.resetSpark`/`resetVelocity`), `tpt.setfpscap`/
  `tpt.setdrawcap` (-> `tpt.fpsCap`/`drawCap`), `sim.framerender`/`sim.gspeed`/`sim.neighbours`/
  `sim.can_move`/`sim.randomseed` (lowercase spellings of the functions above).

**Practical build-verify loop this cheat-sheet supports** (matches this project's existing pattern,
now with exact calls): `sim.paused(true)` -> draw -> `sim.paused(false); sim.frameRender(N)` -> poll
`sim.frameRender()` until 0 (or count `AFTERSIM`) -> `sim.paused(true)` -> census via
`partID`/`partProperty`/`pmap`/`elementCount` -> optional `tpt.screenshot()` for a human-facing artifact
-> `sim.saveStamp()` checkpoint.

---

## Thread C — Agent methods for precision building

**1. Plan-then-execute with a verifier (new since round 1's Voyager/COPE coverage).**
- "Architecting Resilient LLM Agents" (arXiv 2509.08646, https://arxiv.org/abs/2509.08646) formalizes
  Planner/Executor separation; plan representations include "structured JSON objects, programs, or
  DAGs of subtasks" — matches this project's blueprint-as-plan design directly. Advocates dynamic
  re-planning and DAG-based parallel execution over linear retry.
- VeriGuard (arXiv 2510.05156, https://arxiv.org/html/2510.05156v1): the verifier's
  counterexample/logical-inconsistency is fed back as a "concrete, actionable critique," not just
  pass/fail — independent 2025 confirmation of the same principle behind this project's existing
  `{path, problem, fix}` lint contract.
- No hits combining plan-then-execute with CAD/3D generation as a named pattern beyond the above —
  flagged as a real gap, not padding.

**2. Sketch-then-refine / coarse-to-fine spatial generation.**
- LayoutLLM-T2I (https://layoutllm-t2i.github.io/): coarse layout induced by LLM from text, refined
  after — direct precedent for "compile a rough module-level plan first, place/size precisely second."
- WorldClaw (arXiv 2608.05248, https://arxiv.org/html/2608.05248v1): agentic coarse-to-fine open-world
  3D gen — planning agents emit a structured spec of regions/terrain/assets/materials/spatial relations
  *before* any placement, analogous to a blueprint's `origin` + module-list phase preceding parameter
  fill.
- Co-Layout (arXiv 2511.12474): solves the layout constraint problem on a **coarse grid first** as a
  warm start for a fine-grid solve — directly reusable: compile at a coarse/scaled-down grid to catch
  overlap errors cheaply before the full-resolution compile.
- HLG (arXiv 2508.17832): 3-stage — extract scene info -> coarse room generation -> hierarchical
  refinement of object placement. Same three-phase shape recommended for a builder: extract goal
  constraints -> coarse module layout -> per-module param refinement.

**3. Constraint solvers (CSP/ILP) for non-overlapping layout.**
- LayoutGPT (per search summary): treats scene elements like CSS-positioned boxes but "often produces
  physically infeasible layouts" — LLMs alone are unreliable at overlap-avoidance, consistent with this
  project's existing compiler-side bounds/overlap checks being necessary, not optional.
- Holodeck (arXiv 2403.09675, https://arxiv.org/pdf/2403.09675): LLM generates a spatial scene graph,
  then a **separate optimizer** places it — confirms "LLM proposes symbolic relations, solver places"
  as the dominant real pattern, not LLM-does-both.
- LayoutVLM (arXiv 2412.02193, https://arxiv.org/html/2412.02193): differentiable optimization guided
  by a VLM — an alternative to discrete CSP/ILP, not applicable to TPT's discrete grid.
- **No paper found using literal ILP/MILP for LLM-driven layout placement** (only differentiable or
  scene-graph-then-solver patterns) — a genuine literature gap. Classical ILP (e.g. OR-Tools CP-SAT)
  for placing modules on a bounded 2D grid without overlap looks straightforward to implement and
  simply hasn't been published as a named technique — not something to borrow, something to just build.

**4. CEGIS-style counterexample-guided repair (sharpest new finding of this thread).**
- Orvalho et al., AAAI 2025 (arXiv 2502.07786, https://arxiv.org/html/2502.07786; code
  https://github.com/pmorvalho/LLM-CEGIS-Repair): MaxSAT-based fault localization finds the buggy
  program *fragment*; the LLM sees a sketch with only that fragment removed (not the whole broken
  program) plus a failing counterexample from the test suite; repair targets just the localized hole.
  Evaluated on 1,431 real broken programs; measurably improved repair rate and fix size across six LLMs
  versus whole-program feedback. **Directly actionable**: this project's current repair feedback shows
  the whole blueprint's error list; localizing to just the failing module/region (bounding box or
  module name from the lint finding) and showing only that fragment + its specific counterexample is a
  more targeted, better-evidenced variant of the existing `{path,problem,fix}` contract.
- SCAFFOLD-CEGIS (arXiv 2603.08520): warns naive iterative LLM refinement under CEGIS can *regress*
  previously-fixed properties across rounds if the scaffold isn't preserved — a caution for any
  multi-round repair loop that doesn't pin down what already passed (relevant to this project's
  2-round repair cap).

**5. Pass@k eval design for small (10-50 prompt) harnesses.**
- "Don't Pass@k: A Bayesian Framework for LLM Evaluation" (arXiv 2510.04265,
  https://arxiv.org/pdf/2510.04265): naive CLT/Wald confidence intervals miscalibrate on small
  benchmarks; recommends a Beta-Binomial posterior per item rather than a single aggregate mean.
- runloop.ai (https://runloop.ai/blog/i-have-opinions-on-pass-k-you-should-too): report multiple k
  values together (pass@1 realistic single-shot, pass@10 "good enough set," pass@100 capability
  ceiling); bootstrap CIs *underestimate* uncertainty on small sets, especially near 0%/100% pass rates
  with few samples — a prompt passing 5/5 or failing 0/5 needs more repeats before trusting it.
- No concrete "k for N=30 items" formula exists in the literature — real gap. Actionable takeaway:
  generate n>=k samples per item, use the unbiased pass@k estimator (not naive resampling), report
  per-item Beta-Binomial or bootstrap intervals rather than a pooled mean.

**6. LoRA fine-tuning recipes for structured-JSON/tool-calling at 1.5-8B.**
- Unsloth's guide (https://unsloth.ai/docs/get-started/fine-tuning-llms-guide/lora-hyperparameters-guide):
  rank r=16 or 32 to start (8/16/32/64/128 ladder), alpha = r or 2r, dropout 0 default (0.1 if
  overfitting), **LR 2e-4 for SFT / 5e-6 for DPO/GRPO**, **1-3 epochs** (more = overfitting risk),
  effective batch ~16 (e.g. batch=2, grad-accum=8), target all of q/k/v/o_proj + gate/up/down_proj for
  complex tasks, weight decay 0.01-0.1, warmup 5-10% of steps.
- AutoAssert 1 (arXiv 2508.07371): alpha=32, dropout 0.05, r=32 for synthetic-data experiments, r=16
  for real-world fine-tuning — one concrete precedent for a narrow structured-generation task shaped
  like this project's.
- Dataset size: general 2026 practitioner guides (futureagi.com, digitalapplied.com) put single-task
  fine-tuning at "a few hundred to thousands of examples," consistent with round 1's 500-2,000 figure —
  no tighter number specific to tool-calling/JSON-only tasks found. One unattributed 2026 workflow used
  200 seed examples expanded via Self-Instruct to 80,000 rows before DPO (multi-task chat, not directly
  comparable).
- ToolWeave (arXiv 2605.12521, https://arxiv.org/pdf/2605.12521): synthetic multi-turn tool-calling
  data generation explicitly designed to work with small open-weight models — flagged as a follow-up
  read, not fetched in full this pass.

---

## Thread D — Screenshot/vision feedback loop

**1. VLM-in-the-loop for building/construction agents.** Voyager (arXiv 2305.16291) is **text-only** —
no screenshots; its "self-verification" is a second GPT-4 call graded on environment-state text, not
pixels. JARVIS-1 (arXiv 2311.05997) is the actual vision-in-the-loop case: it fuses visual observations
with symbolic state (inventory, position, life stats) for planning/self-check — **vision augments
symbolic state, it does not replace it**; no extractable detail on resolution/annotation/frequency was
recoverable from the abstract (PDF body not extractable via WebFetch). Optimus-1/2/3
(arXiv 2408.03615, CVPR2025 paper, arXiv 2506.10357) build "Goal-Observation-Action" multimodal memory
— same pattern: screenshots feed a policy/memory module, not a standalone verifier. JARVIS-VLA
(arXiv 2503.16365) is action-generation (VLM emits keyboard/mouse actions from screenshots), not build
verification. **Net finding: no system in this space uses screenshots as the sole verifier for "did the
build come out right" — vision is consistently a planning/perception input, with symbolic/inventory
state doing the actual pass/fail check.**

**2. Structured state vs. vision for verification.** Closest studied analog: GUI agents. "Do LLMs Need
to See Everything?" (arXiv 2604.17817, https://arxiv.org/pdf/2604.17817) benchmarks screentext vs.
screenshots for phone automation and recommends a **hybrid**: screenshots win for spatial-layout/
visual-design judgments, text state wins for efficiency and cleanly-extractable facts — exactly this
system's situation, since a particle census (element type/count/temp in a region) is a cleanly
extractable fact, not a layout judgment. Broader GUI-agent surveys (arXiv 2504.13865, 2503.11069,
2508.04412) confirm accessibility-tree/DOM state is precise but only as good as what the app declares —
TPT's Lua particle API has no such gap (it *is* ground truth, not declared metadata), strengthening the
case for keeping census as primary.

**3. Cheap diffing — two different toolchains, pick by task.**
- **Perceptual hashing** (pHash/dHash via Python `imagehash`, https://github.com/JohannesBuchner/imagehash)
  answers "is this roughly the same image," tolerant of scaling/compression — the **wrong tool** here,
  since it would blur past exactly the small structured changes (a few particles) this system cares
  about.
- **Exact pixel-diff with tolerance** — the actual standard for "did the rendered thing change as
  expected" in software visual-regression testing: pixelmatch (https://github.com/mapbox/pixelmatch,
  threshold 0-1, default 0.005, plus antialiasing-radius suppression) and Resemble.js
  (https://rsmbl.github.io/Resemble.js/), both operating on raw RGBA arrays with no ML — directly
  portable to a NumPy one-liner (`np.abs(a.astype(int)-b.astype(int)).sum(axis=-1) > thresh`) restricted
  to a region-of-interest bounding box. Right shape for "did pixel/region X change" as a cheap
  pre-filter, not perceptual hashing.

**4. TPT-specific precedent.** None found — consistent with round 1's "zero prior art" finding.

**Recommendation for this system.** Do **not** build a general VLM-in-the-loop verifier — TPT's Lua
bridge already gives exact, structured, per-particle ground truth (`spatial_snapshot`, `execute_lua`
census) that is strictly better than anything a screenshot+VLM pipeline could recover, and Thread D.2's
finding (vision only wins for spatial/layout judgment, not extractable facts) argues against replacing
census with vision for build verification. The one narrow use worth adding: a **cheap pixel-diff
pre-filter** (`research/capture_tpt.py` + a pixelmatch-style NumPy region diff, no VLM) run *before* an
expensive full census, to cheaply detect "nothing happened" (dead build, sim not advancing, wrong
origin) or "region touched outside intended bbox" (overspill) in milliseconds — a fast triage gate, not
a correctness verifier. A VLM screenshot call is only worth it for a final **human-facing** artifact
(attach a screenshot to a lesson/regression-failure record for a person to eyeball), never as the
pass/fail signal itself.

---

## Prioritised improvements

Round 1's items 1 (schema-constrained decoding), 2 (2-round repair cap), 3 (blind-resample fallback), 5
(golden regression suite), and 9 (attempt logging) are already implemented (`scripts/blueprint_agent.py`
`chat()`/`solve()`, `scripts/regression.py` + `knowledge/golden/*.json`, `knowledge/attempts.jsonl`).
This list picks up from there — ordered by (evidence strength x leverage) / effort, each naming the file
it touches.

1. **Replace the pause-toggle frame-stepping trick with `sim.frameRender(n)`.** *Component:
   `powder_ext/build_tools.py:164-166` (`_frame()`), `scripts/fix_pods_and_retest.py:100`,
   `scripts/functional_test_deut.py:11`.* *Effort: small.* *Gain: high* — Thread B confirms
   `sim.frameRender(n)` queues exactly `n` frames deterministically while paused, with no wall-clock
   race; the current `"for i=1,%d do tpt.set_pause(0) tpt.set_pause(1) end"` loop advances frames by
   racing real time between two separate bridge round-trips, which is exactly the "wall-clock tool
   latency silently advances real frames" pitfall `PLAYBOOK.md`'s own `checkpoint_verify_loop` practice
   warns about. This is a direct, low-risk correctness fix, not a nice-to-have.

2. **Localize repair feedback to the failing module/region instead of the whole blueprint's error
   list.** *Component: `scripts/blueprint_agent.py` `solve()` feedback-construction block (the
   `feedback = "Fix these and resend the WHOLE corrected JSON object..."` branch).* *Effort: medium.*
   *Gain: high* — Thread C's sharpest new finding (arXiv 2502.07786, AAAI 2025): LLM repair improves
   measurably when only the localized broken fragment + its specific counterexample is shown, not the
   whole artifact plus a full error list. `blueprint_lint`/`compile_blueprint` errors already carry a
   `path` (e.g. `parts[3].props.temp_c`); group errors by top-level part index, and when only one/two
   parts are implicated, ask the model to resend just that part's JSON fragment (still validated against
   the whole blueprint) rather than the entire object every round.

3. **Build the pass@k/pass^k regression harness (round 1 item 4, still open), using per-item
   Beta-Binomial intervals, not a pooled mean.** *Component: new `scripts/agent_eval.py`, sibling to
   `blueprint_agent.py`.* *Effort: medium.* *Gain: high* — Thread C confirms no off-the-shelf harness
   covers this and gives the concrete statistical fix: naive CLT confidence intervals miscalibrate on
   10-50-prompt sets (arXiv 2510.04265); report pass@1/pass@10 together per item with a per-item
   Beta-Binomial or bootstrap interval, and generate n>=k samples per item using the unbiased pass@k
   estimator rather than reusing the same n samples across different k's.

4. **Add a lint rule (and a lesson) against portal-based coolant loops.** *Component:
   `powder_ext/knowledge_tools.py` (new `_rule_portal_ghost_heat`, alongside the existing
   `_rule_pump_vacu_wall`/`_rule_clne_ctype`-style rules), `knowledge/build-lessons.jsonl`.* *Effort:
   small.* *Gain: medium-high* — Thread A's portal research found a **documented, real failure mode**:
   PRTI/PRTO can hold more than one particle per cell, so shuttling coolant through a portal pair
   creates "ghost heat" (double-counted coolant mass not reflected on screen) and can silently lose
   particles entirely (~10s full disappearance reported in one build). No working portal-heat-exporter
   with real numbers exists to emulate — this is purely a pattern to detect and warn against: flag any
   compiled blueprint routing a `PRTI`-family element within N cells of a `PRTO`-family element inside a
   region also containing a coolant-typed liquid (`DSTW`/`CBNW`/etc.).

5. **Encode the MONR reactor manual's numeric thresholds as playbook verify bands.** *Component:
   `knowledge/PLAYBOOK.md` reactor/control practices (the fission/control-rod topics).* *Effort:
   small-medium.* *Gain: medium-high* — Thread A's Thread=27188 find is a rare author-written operating
   manual with concrete numbers this project didn't have before: core held ~500C; rod insertion levels
   0(idle)-4(full); boiler kept 130-180C; coolant container 70-80C optimal, warn at >=90C; 1064C triggers
   automatic poison injection; shutdown holds rods fully inserted 40s before idling; final safe state
   <160C and <5 PSI. These map directly onto verify-step bands (`hold within [130,180]` etc.) for any
   future reactor-control-loop practice, and onto Thread A's own portal-heat-export anti-pattern (item 4)
   as a "here is what a correctly-scaled thermal band actually looks like" reference.

6. **Add a coarse-grid overlap pre-check before full compile, for large blueprints.** *Component:
   `powder_ext/blueprint_tools.py` `Compiler.compile_parts`/`compile_part` (the bounds/overlap-checking
   path around `_check_bounds`/`_register`).* *Effort: medium.* *Gain: medium* — Thread C's Co-Layout
   citation (arXiv 2511.12474) gives a concrete, reusable technique: solve placement/overlap on a
   coarsened grid first as a cheap warm-start filter before the expensive full-resolution compile; for
   blueprints with many modules this catches gross overlap errors an order of magnitude cheaper than
   running the real compiler, complementing (not replacing) the existing per-primitive bounds checks.

7. **Add a cheap pixel-diff pre-filter before the full particle census in `run_test`.** *Component:
   `powder_ext/build_tools.py` `run_test`/`_measure`, using `research/capture_tpt.py` +
   `tpt.screenshot()` (Thread B) for capture.* *Effort: medium.* *Gain: medium* — Thread D's
   recommendation: do not add a VLM/vision verifier (TPT's Lua particle census is already strictly
   better ground truth), but a pixelmatch-style NumPy region diff
   (`np.abs(a.astype(int)-b.astype(int)).sum(axis=-1) > thresh` on a bounding box) run before the full
   census is a millisecond-cost triage gate for "nothing happened" (dead build, sim not advancing) or
   "changed outside the intended bbox" (overspill) — catching two common failure classes cheaply before
   spending a full census on them.

8. **Add a FILT-as-databus / CTYPE-wavelength-addressing module family for a future "TPT computer"
   playbook level.** *Component: `knowledge/modules/*.json` (new modules), `knowledge/PLAYBOOK.md` (new
   topic beyond the current reactor/control-logic levels).* *Effort: medium-large.* *Gain: medium* —
   Thread A found three complete, numbered TPT computer architectures (C4C1: 16x16 FILT-CTYPE ROM grid
   programmed via PSTN+DTEC, 0.02Hz clock; Ray162K: FILT memory rectangle + DRAY/RAY-family fast bus,
   8-frame memory ops; "Smallest 8-bit Computer": 4 registers, 30-word RAM, 0.2-3Hz) — enough concrete
   detail to derive a `filt_wavelength_cell`/`filt_addr_grid` module pair distinct from the existing
   `mod_tank`/`mod_deut_cell_mk2`-style reactor modules, opening a genuinely new playbook branch (digital
   logic/memory) rather than another reactor variant.

9. **Expose `elements.allocate`/`elements.element` through `blueprint_grammar` for custom-element
   definitions, and `event.register(event.AFTERSIM, ...)` for exact-frame counting in `run_test`.**
   *Component: `powder_ext/agent_tools.py` `blueprint_grammar()`, `powder_ext/build_tools.py`
   `_frame()`/`run_test()`.* *Effort: small.* *Gain: small-medium* — Thread B confirms
   `elements.allocate(group,name)` is the real custom-element entry point (round 1 suspected this but
   hadn't pinned the exact signature or the `group`/`name` no-underscore, `DEFAULT`-reserved
   constraints) and that `AFTERSIM` fires exactly once per simulated frame — a cleaner exact-frame-count
   primitive than polling `sim.frameRender()==0`, worth exposing as an alternative in the grammar/build
   tools for cases that need to count rather than just wait.

10. **Do not build a portal-based heat exporter, a GRVTY/NBHL/SING-based mechanism, or a general
    VLM-in-the-loop build verifier — explicitly deprioritized.** *Rationale:* Thread A found portal
    coolant loops are a documented anti-pattern with no working counter-example (see item 4); GRVTY/NBHL/
    SING have no recoverable community-build data this pass (wiki access degraded, no forum builds
    found); Thread D found no system in the agent-building literature uses screenshots as a sole
    verifier, and this project's Lua particle census is already strictly better ground truth than
    anything a screenshot+VLM pipeline could recover for a structured field like element/temp/count. Any
    of these would be real engineering effort spent away from the higher-leverage items above.

---

## Open risks / caveats

- **Wiki access degraded**: the Anubis anti-bot gate now blocks direct `powdertoy.co.uk/Wiki` fetches;
  round 1's citations to the same pages predate this. Any future harvesting pass needs a browser-based
  fetch path or must accept forum/search-snippet-only coverage of wiki content.
- **Exotic-element findings are thin for GRVTY/NBHL/SING** — do not treat their absence from this
  report as "not useful," only as "not found this pass"; a browser-based wiki fetch would likely
  recover their base mechanics even without a community-build writeup.
- **Portal-based heat export is a documented anti-pattern, not a technique** — the ghost-heat/
  double-counted-mass failure mode should be added to the lint/lessons store as a thing to warn against
  if a build ever routes coolant through PRTI/PRTO, not chased as a build target.
- **CELL-vs-pixel coordinate mismatch is a live trap, not just a documentation nicety**: `sim.pressure`/
  `velocityX`/`velocityY`/`ambientHeat`/`gravityMask`/`gravityMass`/`wallMap`/`elecMap` all operate on
  the coarse `CELL`-unit grid (`CELL`=4px), while `sim.partCreate`/`partID`/`partPosition`/`createLine`/
  `createBox`/`saveStamp` all operate in raw pixel coordinates. Any future code that reads a field value
  at "the same" coordinate it just placed a particle at (e.g. checking ambient heat right where a heater
  part was drawn) must divide by `CELL` first or it will silently read the wrong cell — worth a compiler-
  or lint-level assertion if a module ever mixes the two, since this is exactly the kind of off-by-a-
  constant-factor bug that produces a plausible-looking but wrong result rather than a hard error.
