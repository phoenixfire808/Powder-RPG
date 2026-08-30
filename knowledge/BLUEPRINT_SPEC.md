# Powder Blueprint v1 — spec for small local models

Five MCP tools now cover the compile → validate → enforce → learn loop:

- `blueprint_schema` (read-only, `powder_ext/blueprint_tools.py`) → returns this reference, the module table (builtin + registry, merged live), the example, and optionally alias/catalog lists.
- `blueprint_build {blueprint, dry_run=true, pause=true, unpause_after=false}` (`powder_ext/blueprint_tools.py`) → compiles, validates, previews, and runs `blueprint_lint`'s rules over the result (returned under `"lint"`); with `dry_run:false` draws it (stop-on-first-error, sim paused during the build). Lint findings never block a build -- only compile errors do.
- `blueprint_lint {blueprint}` (read-only, `powder_ext/knowledge_tools.py`) → compiles a blueprint and returns just the lint findings, for re-checking without redrawing. See "Lint rules" below.
- `blueprint_module_save {name, description, why, params, parts, anchors_note?}` (mutating, file-only, `powder_ext/blueprint_tools.py`) → the self-improvement loop: validates a new module by expanding+compiling it with its own default params (dry, never draws), then writes it to `knowledge/modules/<name>.json`. See "Module registry" below.
- `element_facts {element?, query?, with?, limit?}` (read-only, `powder_ext/knowledge_tools.py`) → queries the accumulated element-interaction knowledge base (`knowledge/element-interactions-part{1,2}.json` + `knowledge/experiments-*.jsonl`) for facts about one element, reactions between two elements, or a free-text search.

All five are registered in `powder_ext/schemas.py` (`TOOL_SCHEMAS`/`TOOL_DESCRIPTIONS`/`TOOL_READONLY`/`TOOL_ORDER`).

Driver for local models: `python scripts/blueprint_agent.py "what to build" --model qwen2.5:1.5b` (Ollama) — it pastes the reference into the system prompt, loops compile-errors back to the model up to N rounds, then builds.

## Language reference (what the model sees)

```
POWDER BLUEPRINT v1 -- write ONE JSON object, nothing else.
Canvas is 612x384 pixels, x grows right (0-611), y grows DOWN (0-383). origin shifts every part.
Top level: {"name": str, "origin": [x,y], "clear_before": bool, "parts": [...], "then": [{"step": N}]}
Each part has exactly ONE operation key plus placement keys:
  {"box": ELEMENT, "at": [x,y], "size": [w,h], "hollow": t?, "props": {...}?, "id": str?, "replace": false?}
        -- a box clears its region first (so later boxes can sit inside earlier ones); "replace": false layers on top
  {"line": ELEMENT, "from": [x,y], "to": [x,y]}
  {"circle": ELEMENT, "at": [cx,cy], "r": radius}
  {"wall": WALLTYPE, "at": [x,y], "size": [w,h]}            -- walls block air/particles; use "wall" for pressure boxes
  {"erase": true, "at": [x,y], "size": [w,h]}               -- clear a region
  {"set": {"tmp": 3, "ctype": "DEUT", "temp_c": 25, "life": 100}, "at": [x,y], "size": [w,h], "element": ELEMENT?}
  {"module": NAME, "at": [x,y], "params": {...}}            -- expands a proven design (list below)
  {"group": [parts...], "at": [x,y]}                        -- offset a sub-list
  {"repeat": N, "at": [x,y], "step": [dx,dy], "part": {...}}  -- copies
  {"stamp": "6a8e21c900", "at": [x,y]}                      -- load a saved stamp
Coordinates: "at" is the TOP-LEFT corner, size is [width,height] in pixels. Any coordinate may be a
reference to an earlier part's id: "vessel.right+2", "vessel.bottom", "core.cx" (anchors: left right top bottom cx cy).
Element names: 4-letter catalog ids (BRCK METL WATR DSTW DMND TTAN INSL WIFI PRTI PRTO CLNE DEUT PLUT PUMP VACU ...)
or plain words (water, brick, metal, glass, insulation, diamond...). Unknown names come back with a did-you-mean.
Properties (via "props" or "set"): tmp (WIFI/PRTI/PRTO channel), ctype (what CLNE/CRAY/PIPE carries),
temp (Kelvin) or temp_c (Celsius), life, tmp2, dcolour.
Rules that save you from failure (from the build-lessons store):
  * dry_run is ON by default: first call returns errors/preview, then resend with dry_run=false.
  * WIFI, HEAC, PRTO stand at their channel temperature: put them in an insulated_box or INSL jacket.
  * Use DSTW (distilled) not WATR near wires; WATR conducts sparks.
  * Cryogenic liquids spawn at room temperature: add "props": {"temp_c": -200}.
  * PSCN must touch LCRY directly to light it. NSCN will not pass a spark to PSCN.
  * A conductive floor shorts the whole build; break long METL runs with INSL.
  * Pressure boxes need WALL (walls), not particles, as the boundary.
  * Keep it small first: a valid 10-part blueprint beats an invalid 100-part one.
```

## Modules

| module | params (defaults) | why it exists |
|---|---|---|
| `insulated_box` | `{"element": "fill element (NONE=empty)", "width": 12, "height": 12, "jacket": 2, "props": "optional {tmp,ctype,temp,life} applied to the fill"}` | WIFI/HEAC/PRTO stand at channel temperature - jacket every heat source |
| `wifi_node` | `{"channel": 1, "size": 3, "pad": "PSCN", "pad_side": "right|left|top|bottom"}` | WIFI channel lives in tmp; INSL jacket; PSCN pad to spark it |
| `portal_pair` | `{"channel": 1, "size": 4, "to": "[dx,dy] of the PRTO relative to the PRTI"}` | PRTI tmp=N feeds every PRTO tmp=N |
| `clne_liner` | `{"element": "INSL", "length": 40, "vertical": false}` | CLNE armed to INSL regrows the barrier after damage |
| `pressure_chamber` | `{"width": 40, "height": 32, "sump_height": 16, "pump_width": 4, "fill": "optional element inside", "wall": "WALL"}` | PUMP columns + VACU sump pressure pair inside a wall grid |
| `shld_pipe_riser` | `{"length": 60, "bore": 2, "vertical": true}` | SHLD sheath self-repairs and insulates the pipe |
| `lcry_panel` | `{"width": 12, "height": 8}` | PSCN must touch LCRY directly |
| `tank` | `{"width": 30, "height": 20, "shell": "GLAS", "liquid": "WATR", "level": 0.7, "sealed": true}` | sealed shells; liquids leak through any gap |
| `deut_cell_mk2` | `{"channel": 10, "pocket": 7}` | Drew's proven DEUT battery: DMND hull, cold CLNE(DEUT), CRAY(NEUT) trigger via WIFI |
| `cooling_tower` | `{"width": 40, "height": 70, "basin": 8}` | visual tower, DMND base band, DSTW basin |
| `house` | `{"width": 24, "height": 16, "wall_element": "BRCK", "roof_element": "WOOD"}` | simple cottage |

The 11 modules above are builtin (hard-coded in `blueprint_tools.py`). `blueprint_schema`'s `modules` output also
merges in every **registry module** from `knowledge/modules/*.json` (re-scanned on every call, no restart needed),
marked `"source": "registry"` -- see "Module registry" below. A `{"module": NAME, ...}` part resolves against
builtin names first, then the registry; unknown names get a did-you-mean across both.

## Module registry (`knowledge/modules/*.json`)

Any module an author (ANALYST, or a model itself via `blueprint_module_save`) wants to make reusable is dropped as
one JSON file per module in `knowledge/modules/`:

```json
{
  "name": "snake_case_id",
  "description": "one line",
  "why": "what lesson or verified build justifies this module",
  "params": {"width": 12, "height": 8, "channel": 1},
  "anchors_note": "optional free text about anchors this module exposes",
  "parts": [ ...ordinary blueprint parts (box/line/circle/wall/set/erase/module/group/repeat/stamp)... ]
}
```

**Parametric expressions**: inside `parts`, any field that would normally be a number may instead be a *string*
arithmetic expression over the module's own `params` names -- `"at": ["width/2", "height-2"]`, `"size": ["width",
"jacket*2"]`. The evaluator supports integers, `+ - * / //`, parentheses, and identifiers that are exactly one of
the module's numeric `params` keys; nothing else (no `eval`/`exec`, no attribute access, no function calls). Any
string that is not a fully-valid expression of this form (an anchor reference like `"core.right+2"`, an element
name, a hex colour) is left completely untouched -- there is no denylist of field names to maintain, the evaluator
is simply self-limiting to pure arithmetic over declared numeric params.

`params` values that are **not** numbers (e.g. an element name passed as a param) cannot be used inside an
expression -- they can still be referenced directly as a whole field value the normal way a builtin module's `fn`
would use them, but only builtin modules get that flexibility; JSON registry modules should bake non-numeric
choices (which element, which wall type, which ctype) as literals in `parts` and expose only numeric knobs as
`params`, exactly as ANALYST's first 19 registry modules do.

`blueprint_module_save {name, description, why, params, parts, anchors_note?}` is the write path: it merges
`params` as defaults, expands `parts` through the same expression substitution, compiles the result (dry, never
draws), and refuses to write the file if that does not compile clean. `name` must be lowercase snake_case and
cannot collide with a builtin module name. This is the self-improvement loop the whole framework is built around:
a verified build becomes a named, parametric, geometry-checked module with no code change and no restart.

## Lint rules (`blueprint_lint`, also run inside `blueprint_build`)

`blueprint_lint {blueprint}` compiles the blueprint (same compiler `blueprint_build` uses) and runs a fixed rule
set over the resulting **absolute, compiled primitives** -- never the raw relative JSON -- so modules, repeats,
groups and anchor references have already been resolved into concrete pixel geometry. "Adjacent" means two
primitives' bounding boxes touch (0px gap) or overlap. Findings are `{"severity", "path", "rule", "problem",
"fix"}`; severity is one of `critical` / `warning` / `info`. **Findings never block anything** -- only compile
errors (returned separately, before lint even runs) block a build.

Each rule prefers real numbers from `knowledge/element-interactions-part{1,2}.json` when present (structured
`props.highTemperature`/`lowTemperature`/`flammable`, or the same values written as prose like
`"HighTemperature=1887.15"`, which the rule engine also regex-extracts) and falls back to a small hardcoded table
otherwise, so the rules get more accurate automatically as MINER-A/MINER-B's files fill in -- no code change needed.

The rules marked "catalog" below are additionally (some *only*) driven by `knowledge/materials-catalog.json` and
`knowledge/power-elements-2026-08-26.json` -- every custom (`define_element`) material's `type`, `properties`
(`PROP_CONDUCTS`, `PROP_DEADLY`, ...), `highTemperature`/`highTemperatureTransition`, `lowTemperature`,
`temperature` (spawn temp), `flammable`, and `behavior` (`{"kind": ..., "params": {...}}`; a `"reactive"` behavior's
`params.rules` is a `chem_kinds.lua`-style rules string, parsed the same way the Lua engine reads it). Both files
are loaded lazily, cached, and tolerant of absence exactly like the element-interactions files -- see
`knowledge_tools._load_custom_catalog` / `_parse_reactive_rules`.

| rule id | severity | trigger |
|---|---|---|
| `watr_conductor_adjacency` | warning | WATR touching/adjacent to a conductor element (flags mention "conduct", or a static fallback list) |
| `heat_source_uninsulated` | critical | WIFI/PRTO/HEAC box not INSL-jacketed on all 4 sides |
| `cryo_no_cold_temp` | warning | LN2/LO2/ICE/... placed with no overlapping temp/temp_c prop at or below its boiling/melting point |
| `hot_adjacent_meltable` | critical | PLSM/LAVA/FIRE adjacent to a meltable/flammable element |
| `pump_vacu_no_wall` | critical | PUMP/VACU not enclosed by a wall box on all 4 sides |
| `pscn_not_touching_lcry` | warning | LCRY with no PSCN touching it directly (0px gap) |
| `clne_no_ctype` | warning | CLNE (or BCLN/PCLN) with no `ctype` set over its region |
| `channel_reuse` | critical | the same WIFI/PRTI/PRTO channel number used by more than one distinct PRTI or PRTO region (crosstalk) |
| `conductive_floor_span` | critical | a thin, wide conductive run spanning >40% of the whole build's width |
| `above_high_temp_transition` | warning | an element's `set` temp exceeds its own HighTemperature transition point |
| `reactive_hazard` *(catalog)* | warning | a catalog `"reactive"` element (NA, MG, CAO, CAC2, ...) placed adjacent to a trigger element from its own `behavior.params.rules` (e.g. NA next to WATR/DSTW, MG next to FIRE **with** O2 also adjacent per its `needs` clause) -- this will react the instant the sim unpauses |
| `flammable_near_heat` *(catalog)* | critical | a `flammable>=100` element (catalog `flammable`, or knowledge `props.flammable`) within 2px of a heat source: FIRE/LAVA/PLSM, or any element with an overlapping `set` temp >=600K (including a high WIFI channel, since channel is converted to `temp` at compile time) |
| `deadly_gas_unsealed` *(catalog)* | warning | a `PROP_DEADLY` or `type:"GAS"` catalog element with no solid primitive (catalog `type:"SOLID"`, a small native fallback set, or a `wall_box`) on all 4 sides within 3px |
| `molten_needs_temp` *(catalog)* | warning | a catalog element whose spawn `temperature` is >=500K (NAS, LBE, FLiBe, ...) placed with no overlapping temp/temp_c prop at or above its `lowTemperature` freeze point -- mirrors `cryo_no_cold_temp` but for elements that freeze *solid* when too cold instead of vaporizing when too warm |
| `melt_point_exceeded` *(catalog)* | warning | same shape as `above_high_temp_transition`, sourced from the materials catalog's `highTemperature`/`highTemperatureTransition` instead of `element-interactions-part{1,2}.json`, so custom materials that never appear in the miners' files (GRNT, BSLT, ...) are covered too |
| `conductor_touching_coolant` *(catalog)* | warning | broader sibling of `watr_conductor_adjacency`: any conductor -- native, or a custom `PROP_CONDUCTS`/`behavior.kind:"conductor"` material (CU, STEL, RBAR, S316, AL61, ZIRC, NBTI, ...) -- adjacent to a liquid/cryogenic coolant *other than plain WATR* (DSTW, SLTW, LN2, LO2, LOXY, OIL, NAK, LBE, FLiBe, LHE, LH2) |

## Example

```json
{
 "name": "mini reactor demo",
 "origin": [
  200,
  150
 ],
 "clear_before": false,
 "parts": [
  {
   "id": "vessel",
   "box": "TTAN",
   "at": [
    0,
    0
   ],
   "size": [
    60,
    40
   ],
   "hollow": 3
  },
  {
   "box": "water",
   "at": [
    "vessel.left+3",
    "vessel.top+3"
   ],
   "size": [
    54,
    34
   ]
  },
  {
   "id": "heater",
   "module": "insulated_box",
   "at": [
    "vessel.right+4",
    "vessel.top"
   ],
   "params": {
    "element": "HEAC",
    "width": 6,
    "height": 6,
    "props": {
     "temp_c": 800
    }
   }
  },
  {
   "module": "wifi_node",
   "at": [
    "heater.right+2",
    "heater.top"
   ],
   "params": {
    "channel": 7
   }
  },
  {
   "repeat": 4,
   "at": [
    "vessel.left",
    "vessel.bottom+6"
   ],
   "step": [
    16,
    0
   ],
   "part": {
    "box": "brick",
    "at": [
     0,
     0
    ],
    "size": [
     12,
     4
    ]
   }
  },
  {
   "wall": "air",
   "at": [
    "vessel.left-6",
    "vessel.top-6"
   ],
   "size": [
    4,
    52
   ]
  }
 ],
 "then": [
  {
   "step": 60
  }
 ]
}
```

## element_facts

`element_facts {element?, query?, with?, limit?}` reads `knowledge/element-interactions-part1.json`,
`-part2.json` (merged, part2 wins per-field on conflict; also supplies a top-level `signal_rules` list), and
`knowledge/experiments-*.jsonl`. All three files are optional -- a missing or not-yet-written file is reported
in `sources_loaded` (`*_loaded`/`*_error` flags), never treated as an error, and every file is re-read whenever
its mtime changes (no restart needed while the miners/experimenter are actively writing).

- `{"element": "WATR"}` → that element's merged facts plus any experiment record that mentions it (by 4-letter
  id, checked in `claim`/`setup`/`observed`/`numbers` keys, or a dedicated `"elements": [...]` field on the
  experiment record when present).
- `{"element": "PSCN", "with": "LCRY"}` → every recorded interaction between the two, searched in both
  directions across each element's `reacts`/`signals`/`transitions`/`behaviour`/`builder_notes` fields plus
  `signal_rules`, and experiments mentioning both.
- `{"query": "conduct"}` → free-text search across every element's facts, `signal_rules`, and experiment records.

Every result carries `src` (file + JSON path) so a claim can be traced back to where it was written, and an
`experiments` list of matching records (`id`, `claim`, `verdict`, `observed`, `numbers`, `frames`, `src`).

## Error contract
Every error is `{"path": "parts[3].module", "problem": "...", "fix": "..."}`. Paths point into the blueprint (`parts[i]`, `parts[i].module:NAME[j]` for expanded module parts, `then[i]`). Nothing is drawn while any error exists.

## Limits
{"parts": 512, "primitives": 2048, "steps": 32, "frames_per_step": 2000}

## Element aliases (plain word → id)
water→WATR, distilled→DSTW, distilled water→DSTW, brick→BRCK, metal→METL, steel→METL, wood→WOOD, glass→GLAS, stone→STNE, sand→SAND, dirt→GOO, ground→GOO, grass→PLNT, plant→PLNT, diamond→DMND, titanium→TTAN, tungsten→TUNG, gold→GOLD, insulation→INSL, insulator→INSL, fire→FIRE, lava→LAVA, oil→OIL, coal→COAL, smoke→SMKE, steam→WTRV, ice→ICE, snow→SNOW, acid→ACID, salt→SALT, concrete→CNCT, clay→CLST, vacuum→VACU, pump→PUMP, void→VOID, clone→CLNE, cloner→CLNE, wire→METL, battery→BTRY, switch→SWCH, wifi→WIFI, lamp→LCRY, lcd→LCRY, sponge→SPNG, pipe→PIPE, valve→PPIP, portal in→PRTI, portal out→PRTO, shield→SHLD, piston→PSTN, frame→FRME, plutonium→PLUT, uranium→URAN, deuterium→DEUT, neutron→NEUT, neutrons→NEUT, hydrogen→H2, nitrogen→N2, oxygen→O2, lithium→LITH, heater→HEAC, cooler→COOL, thermometer→TSNS, pressure sensor→PSNS, delay→DLAY, spark→SPRK, laser→ARAY, ray→ARAY, photon→PHOT, light→PHOT, glow→GLOW, filter→FILT, bomb→BOMB, c4→C4, tnt→TNT, gunpowder→GUN, nitro→NITR, thermite→THRM, plasma→PLSM, nsilicon→NSCN, psilicon→PSCN, inst→INST, instant wire→INST, heat switch→HSWC, brick wall→BRCK, goo→GOO, gel→GEL, soap→SOAP, rubber→RBDM, bmetal→BMTL, broken metal→BMTL, iron→IRON, copper→COPR, spawner→CLNE, eraser→NONE, empty→NONE, air→NONE, nothing→NONE

## Wall aliases
wall→WALL, solid→WALL, solid wall→WALL, air→AIR, airwall→AIR, erase→ERASE, none→ERASE, fan→FAN, liquid→LIQD, liquid wall→LIQD, powder→POWDR, gas→GAS, energy→ENRGY, detector→DTECT, detect→DTECT, stream→STRM, gravity→GRVTY, gravity wall→GRVTY, conductor→CNDTR, blocking→WALL, allow air→AIR, allowliquid→LIQD, eholes→EHOLE, e-hole→EHOLE, eh→EHOLE

## Valid element ids (195)
ACEL ACID AMTR ANAR ARAY BASE BCLN BCOL BGLA BHOL BIZG BIZR BIZS BMTL BOMB BOYL BRAY BRCK BREL BRMT BTRY BUBW BVBR C-4 C-5 CAUS CFLM CLNE CLST CNCT CO2 COAL CONV CRAY CRMC DCEL DESL DEST DEUT DLAY DMG DMND DRAY DRIC DSTW DTEC DUST DYST ELEC EMBR EMP EQVE ETRD EXOT FIGH FILT FIRE FIRW FOG FRAY FRME FRZW FRZZ FSEP FUSE FWRK GAS GBMB GEL GLAS GLOW GOLD GOO GPMP GRAV GRVT GUN HEAC HSWC HYGN ICE IGNC INSL INST INVS INWR IRON ISOZ ISZS LAVA LCRY LDTC LIFE LIGH LITH LN2 LOLZ LOVE LOXY LRBD LSNS MERC METL MORT MWAX NBLE NEUT NICE NITR NONE NSCN NTCT OIL OXYG PBCN PCLN PHOT PIPE PLNT PLSM PLUT POLO PPIP PQRT PROT PRTI PRTO PSCN PSNS PSTE PSTN PSTS PTCT PTNM PUMP PVOD QRTZ RBDM RFGL RFRG RIME ROCK RPEL RSSS RSST SALT SAND SAWD SEED SHD2 SHD3 SHD4 SHLD SING SLCN SLTW SMKE SNOW SOAP SPNG SPRK SPWN SPWN2 STK2 STKM STNE STOR SWCH TESC THDR THRM TNT TRON TSNS TTAN TUNG URAN VACU VENT VIBR VINE VIRS VOID VRSG VRSS VSNS WARP WATR WAX WHOL WIFI WOOD WTRV WWLD YEST

## Valid wall ids
ABSRB AIR CNDTR CNDTW DTECT EHOLE ENRGY ERASE ERASEA EWALL FAN GAS GRVTY LIQD NOAIR POWDR STASIS STRM WALL

## Agent-loop tools (added 2026-08-25 from building-agent research)
- `world_state {max_elements?, include_grid?}` (read-only, live) — compact state for every model turn: counts/boxes/temps per element, walls, pressure extremes, hot spots, largest empty rectangles, one-line `summary`. Reason: Factorio Learning Environment found ~98% of agent failures were state tracking.
- `next_task {topic?, max_level?, max_retries?}` — deterministic Voyager-style curriculum over `playbook.json`: lowest unpassed practice; failures come back decomposed into sub-tasks with the previous errors; 3 consecutive fails = stuck (flag for a human).
- `record_attempt {goal, verdict, practice?, level?, model?, evidence?, errors?, blueprint?, score?, temperature?, round_no?, resample_no?}` — appends to `knowledge/attempts.jsonl` (curriculum memory + future SFT/DPO/GRPO dataset). `score` is an optional decomposed reward `{compiles, lint_critical, lint_total, verify_pass}` alongside the single `verdict` enum (round 3 item 3: a bare pass|fail bit produces degenerate all-same-score RL groups); `temperature`/`round_no`/`resample_no` record which sampling condition produced this attempt.
- `blueprint_grammar {format}` — GBNF + JSON Schema for Powder Blueprint v1 for grammar-constrained decoding (Ollama `format`, llama.cpp `grammar`/`response_format`). Shape only; still dry_run and feed errors back.
- Driver: `scripts/blueprint_agent.py` now injects world_state each turn, constrains decoding, feeds compile+critical-lint errors back, logs every attempt, and has `--curriculum --max-level N`.

## Retrieval-shortlisted modules + precondition gate (round 3, 2026-08-26)
- `module_search {query, k?, explicit?, endpoint?, model?}` (read-only, does not touch the sim) — ranks the 76+ builtin+registry modules by relevance to `query`. Tries Ollama's own `POST /api/embeddings` (`nomic-embed-text` or `all-minilm` — already served by the same Ollama runtime this project calls for chat, no new dependency) first; falls back to a pure-stdlib TF-IDF/cosine ranker when Ollama is unreachable, so this is always usable offline. `explicit` names are kept regardless of rank. Backed by `powder_ext/agent_tools.py`'s `module_retrieve`.
- `scripts/blueprint_agent.py`'s `system_prompt(request, modules_k=12)` now calls `module_retrieve` to shortlist the module list to the top `modules_k` plus any module named directly in the request, instead of dumping the full registry into every call (TinyAgent, arXiv 2409.00608: a retrieval-shortlisted tool list both improves accuracy and roughly halves prompt tokens at this project's model-size range). `--modules-k` on both `blueprint_agent.py` and `passk_harness.py` controls it.
- Precondition gate: `agent_tools.gate_modules(names)` / `missing_elements_for_module(name)` cross-reference each *registry* module's referenced elements against the stock catalog and the live custom-element list (`blueprint_tools._custom_elements()`, read-only). A module needing a not-yet-defined custom element is listed in the system prompt as explicitly unavailable ("do NOT use these") rather than offered and left to fail later (modeled on arXiv 2608.01050's Wix Helpmate pipeline). Builtin (Python-function) modules are always available.

## pass@k harness dataset hygiene (round 3, 2026-08-26)
- `scripts/passk_harness.py` deduplicates its k samples per task by **structural signature** (canonical JSON of `parts`, ids stripped) before counting pass@1/pass@k/pass^k — a duplicate is still logged to `attempts.jsonl` for audit but excluded from the counts and from the SFT export, per arXiv 2308.01825's rejection-sampling dedup rationale (avoid overrepresenting whatever the model converges on first).
- Each task's `pass@1` now carries a `pass@1_ci95` 95% Wilson score interval alongside the point estimate (and the summary carries a pooled `pooled_pass@1_ci95`).
- Every deduplicated sample is appended to `knowledge/attempts-sft.jsonl` as `{prompt, completion, verdict, verifier_feedback}` — directly usable as an SFT (filter to `verdict=="pass"`) or RFT training file; `attempts.jsonl` still carries the fuller per-sample record (score, temperature, round_no, resample_no) for GRPO-style grouping.
- `--tasks knowledge/tasks-basic.json` — 10 golden tasks, each optionally carrying an `expected {elements?, min_primitives?}` block checked informationally against the compiled preview (`expected_checks_ok`/`expected_checks_total` per task row); it does not affect the pass/fail verdict, which stays compile+critical-lint-clean.

## Build-anything layer (2026-08-25): features, functional tests, staged pipelines
- `find_features {cell?}` (live, read-only) — connected components of the canvas as named objects: `{id, shape, main, elements, box, anchors, tmax_c, describe}`. Pass `features_auto: true` to `blueprint_build` and reference them like blueprint ids: `"at": ["ttan1.right+3", "ttan1.cy"]`.
- `run_test {frames, pulses?, watch?, assertions, tx_at?, sample_every?}` — exact-frame functional test (microstep = 1 engine frame). `pulses` fire WIFI channels via a temporary transmitter; `assertions` are `{region, element?, metric: count|tavg_c|tmax_c|life_sum|pmin|pmax|delta_count, op, value}`; `watch` regions are traced over time. Leaves the sim paused.
- `build_stage {stage:{name, blueprint, tests:[run_test args], require_lint_clean?}, dry_run?, record?}` — gates in order: compile → lint → checkpoint stamp → build → tests → record_attempt. Stops at the first failed gate with diagnostics so the planner fixes only that stage.
- Pipeline = a list of stages, executed in order; each stage's blueprint may anchor to features created by earlier stages (re-run find_features) or to hand-drawn objects. "Done" means every stage's tests pass on the live sim.

## Research-driven hardening (2026-08-25, see research-building-bot-2026-08-25.md)
- Driver: `--rounds 2` feedback repair then `--resample N` blind re-asks (small models degrade when shown their own failures); Ollama calls use the JSON schema as `format`.
- `run_test` assertions accept `"when": "always"` — evaluated at every sample; any transient violation fails the test (temporal oracle).
- `blueprint_module_save` refuses exact geometric duplicates of registry modules (pass `force: true` with a why) and reports near-duplicates.
- `scripts/regression.py` — golden suite: every practice fragment + every module compiles/lints, goldens in `knowledge/golden/*.json` keep their primitive counts; run after any compiler/lint/playbook/module change. `--add name file.json` to add a golden, `--update` to re-baseline.

## SAFETY-LINT: catalog-driven rules for custom elements (2026-08-26)
`scripts/test_lint.py` — asserts each of the 6 catalog-driven rules above fires on its
`knowledge/fixtures/lint_fixture_<rule>.json` fixture (plus a couple of negative controls, e.g. NAS above its
freeze point does *not* trip `molten_needs_temp`) and that the older `knowledge/fixtures/lint_fixture_blueprint.json`
still trips its pre-existing rules. Run after any change to the lint rules, `materials-catalog.json`, or
`power-elements-*.json`; exits 1 on any regression. Because custom (`define_element`) materials like NA, MG, GRNT,
NAS, and NBTI only resolve through `blueprint_tools.resolve_element` against a *live* running game, the 6 new-rule
fixtures store an already-*compiled* primitive list (their `"compiled"` key) instead of raw blueprint DSL, and are
fed straight to `knowledge_tools.lint_compiled` -- this script needs no live game.
