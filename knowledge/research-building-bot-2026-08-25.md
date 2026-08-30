# Research: how to build the best possible Powder Toy building bot (2026-08-25)

Web research pass for the AI "building bot" project: small local LLMs constructing complex machines
(reactors, cooling loops, control logic) in The Powder Toy through the JSON blueprint compiler +
module registry + lint layer + lessons store + graded playbook already built in this repo. Sources:
`BLUEPRINT_SPEC.md`, `PLAYBOOK.md`, `mechanisms-community-2026-08-25.md` (+ its `-pass2` companion),
`scripts/blueprint_agent.py`, `scripts/save_research.py`, `powder_ext/*.py`. Four parallel research
passes covered (1) TPT-specific tooling, (2) LLM sandbox-building agents, (3) small-model
orchestration, (4) verification/self-improvement. No files other than this one were modified; the
game was not touched.

---

## (a) Executive summary

1. **The TPT-mechanism research is already done better than anything findable online** — 38
   community saves deep-read into `mechanisms-community-2026-08-25.md` beats every wiki page or
   forum thread for reactor/fusion design specifics. The gap in this system is not build knowledge,
   it is **agent architecture**: repair-loop design, decoding constraints, regression testing, and
   skill-library hygiene.
2. **Ollama already does grammar-constrained decoding** via `format: <json-schema>` (since v0.5,
   compiles to GBNF internally) — the driver (`scripts/blueprint_agent.py`) currently uses
   `format: "json"` (bare JSON mode), not a schema, so it is leaving free reliability on the table
   with almost no code change.
3. **The literature says "don't show the model its own broken output" for small models** — the
   sharpest, most surprising finding (arXiv 2607.26117): below 7B, blind resampling beats
   feedback-conditioned repair, and showing the prior failed blueprint verbatim measurably *hurts*
   (models reproduce the same broken structure 33-68% of the time). This directly contradicts the
   current driver's `messages.append(assistant reply); messages.append(user feedback)` accumulation
   pattern.
4. **Two repair rounds capture 76-95% of the achievable gain**; the driver's default of 3 (with
   `--rounds` up to arbitrary N) is already over-budget for a small model — round 3-4 mostly
   thrashes.
5. **No TPT save-format parser or headless simulation mode exists anywhere** (confirmed by direct
   source inspection of `GameSave.cpp` and the CI workflow) — this repo's approach (talk to a live
   game via the Lua bridge, `sim.loadStamp`, `execute_lua`) is already the only practical path; there
   is no "just run TPT in CI" shortcut to chase.
6. **This system's biggest structural gap versus Voyager/Eureka/SkillOps-class agents is a
   regression suite**: none of those systems' central trick (Eureka's population+reflection loop,
   Voyager's append-only verified skill library, Reflexion's capped verbal memory) works without a
   cheap, repeatable way to score "did this get better or worse" — this repo has a lint layer and a
   lessons store but no golden-build regression suite and no dedup/GC pass on the 47-module registry.
7. **The module registry is already past the size where Voyager-style unlimited append is safe** —
   the mechanisms doc's own "duplicates to resolve" section (cray_neut_igniter vs neut_cray_nozzle,
   two RBMK rod modules, etc.) is exactly the failure mode the skill-library literature (SkillBrew,
   SkillOps) warns about and has concrete embedding-similarity thresholds (~0.85 merge, 0.6-0.85
   review) for.
8. **Decomposition helps small models more than large ones** (COPE, Aider architect/editor, 2602.04853)
   — a planner (bigger model or a static rule) that emits an ordered list of module calls, with the
   small model filling one op's JSON at a time against that op's sub-schema, is the single most
   evidence-backed lever for making a 1-8B model reliable, and maps directly onto this system's
   existing modules-as-composable-units design.
9. **Verification here is still "census at frame N," which the STL/temporal-assertion literature
   calls a weak oracle** — a build can be correct at frame 300 and have violated an invariant at
   frame 150 (e.g. a pressure spike, a transient leak); adding a continuous/robustness-margin check
   (`G[a,b] pred`, checked every K steps) is a low-effort upgrade to the playbook's existing verify
   steps.
10. **The fine-tuning loop (goal, blueprint, verdict) → SFT/DPO is realistic at this project's own
    scale** — practitioner consensus and RS-DPO/ReST/STaR literature put the useful data threshold at
    roughly 500-2,000 examples for a <8B model, which this system's own build-lessons.jsonl +
    experiment logs are already most of the way toward generating for free as a side effect of normal
    use.

---

## (b) Per-thread findings

### Thread 1 — TPT-specific tooling

**Lua API.** Canonical index: https://powdertoy.co.uk/Wiki/W/Powder_Toy_Lua_API.html. Ground-truth
verified directly against source (not just the wiki):
- `simulation.*` — https://github.com/The-Powder-Toy/The-Powder-Toy/blob/master/src/lua/LuaSimulation.cpp
  — confirmed ~90 functions incl. `partCreate`, `partChangeType`, `partProperty`, `partNeighbors`,
  `createBox`/`createLine`, `pressure`/`velocityX`/`velocityY`, `ambientHeat`, `gravityMask`,
  `saveStamp`/`loadStamp`/`listStamps`, `takeSnapshot`/`historyRestore`, `clearSim`/`clearRect`,
  `resetTemp`/`resetPressure`/`resetVelocity`, `edgeMode`/`gravityMode`/`customGravity`.
- `elements.*` — https://github.com/The-Powder-Toy/The-Powder-Toy/blob/master/src/lua/LuaElements.cpp
  — `elements.allocate(group,id)`, `elements.element(id[,table])` (get/set the full property table —
  this is the actual "define a custom element" entry point), `elements.property`, `elements.free`,
  `elements.getByName`.
- `event.*` — https://github.com/The-Powder-Toy/The-Powder-Toy/blob/master/src/lua/LuaEvent.cpp —
  `event.register(type, handler)`; hook types `event.tick`/`beforesim`/`aftersim` are the relevant
  ones for a build-then-verify loop (step N frames, then assert).
- Community IDE support: https://github.com/Maticzpl/TPT-LuaAPI-Addon (Lua-Language-Server addon,
  useful as a machine-readable-ish type reference if the blueprint compiler ever needs to emit raw
  Lua instead of just calling the bridge).

**Save format.** No formal spec page; the spec is the source. Confirmed by reading
https://github.com/The-Powder-Toy/The-Powder-Toy/blob/master/src/client/GameSave.cpp (2888 lines):
modern `OPS1` = 12-byte header (`'OPS1'`, version, cell size, blockW/H, data length) + bzip2-compressed
BSON document (keys: `origin`, feature-enable booleans, `parts`/`partsPos`/`wallMap`/`fanMap`/
`soapLinks` binary blobs, element name/ID map, signs). Legacy `.cps`/`PSv` handled by the same file's
`readPSv()`, gated to `version <= 97`. Forum threads describe the same thing informally:
https://powdertoy.co.uk/Discussions/Thread/View.html?Thread=17998 (OPS1),
https://powdertoy.co.uk/Discussions/Thread/View.html?Thread=10955 (PSv). **No standalone parser
library exists in any language** — this repo's Lua-bridge approach (`sim.loadStamp`/`saveStamp`
through a live game) is already the only practical integration point; a from-scratch parser is
possible (BSON + bzip2 are both off-the-shelf) but nobody has built one.

**Headless/CLI.** Confirmed **no headless mode exists**: README flags
(https://github.com/The-Powder-Toy/The-Powder-Toy/blob/master/README.md) are all GUI/network related
(`scale`, `kiosk`, `proxy`, `open`, `ptsave`); the only CI workflow
(https://github.com/The-Powder-Toy/The-Powder-Toy/blob/master/.github/workflows/build.yaml) is a pure
compile check with zero test/headless/xvfb steps; community requests for a real server/headless mode
go back years (https://powdertoy.co.uk/Discussions/Thread/View.html?Thread=20590) and remain unsolved.
Practical workaround if a second automated-test surface is ever needed: Xvfb + Lua
`autorun.lua`/script-manager (https://powdertoy.co.uk/Wiki/W/Getting_Lua_Scripts.html,
https://github.com/The-Powder-Toy/TPT-Script-Manager) — still a real (virtual) display, not true
headless. **This validates the existing architecture (drive a real running instance via the MCP
bridge) as the only viable approach**, not a stopgap.

**Prior art.** Genuinely thin. One forum post of a user having ChatGPT write a native C++ element
(https://powdertoy.co.uk/Discussions/Thread/View.html?Thread=26594) — not an in-sim building agent.
Powderworld (https://arxiv.org/pdf/2211.13051) is an unrelated from-scratch RL benchmark "inspired by"
falling-sand games, not TPT itself. **Zero hits for "Powder Toy" + "MCP"/agent/LLM-builder** — this
project is in unclaimed territory, which cuts both ways (no shortcuts to borrow, but also no
competing prior design to reconcile with).

**Save-browser search API.** `https://powdertoy.co.uk/Browse/View.json?ID=<id>` is a real, directly
fetchable per-save metadata endpoint (Score, Tags, Description, Views, etc.) — already used by
`scripts/save_research.py`'s `view()`. Bulk search: `https://powdertoy.co.uk/Browse.json?Search_Query=<q>&PageNum=N`
(already used by `save_research.py`'s `browse()`) supports an informal boolean query syntax
(`&`/`|`/`!`, `sort:`) per https://powdertoy.co.uk/Discussions/Thread/View.html?Thread=19755, but there
is **no documented tag/element-filtered REST endpoint** beyond free-text query strings — the existing
harvester is already using the best available surface.

**Element mechanics — docs exist, confirming (not re-deriving) the empirical save analysis**: WIFI,
PRTI/PRTO, PSTN/FRME, DTEC (fetched directly — "generates SPRK when its ctype element is nearby"),
TSNS, PSNS, CLNE/PCLN, CRAY, CONV (fetched directly — "converts touched particles to ctype") all have
official wiki pages under `powdertoy.co.uk/Wiki/index.php?title=Element:<NAME>`.

### Thread 2 — LLM building agents in other sandboxes

**Voyager** (https://arxiv.org/abs/2305.16291, https://github.com/MineDojo/Voyager). Skill library =
Chroma vector DB keyed by an LLM-written NL description's embedding, valued by a standalone JS
function; retrieval is top-**5** by embedding similarity to a plan sketch + current feedback, pasted
into the next prompt. Automatic curriculum = a separate GPT-4 call given full state (biome, inventory,
equipment, **completed and failed task lists**) proposing exactly one next task in a fixed format,
banning task types the environment can't grade. Self-verification loop caps at **4 rounds**, folding
three feedback channels (raw stack trace, textual env feedback, a separate GPT-4 critic's pass/fail +
diagnosis) into the next prompt. Crucially: **no dedup, pruning, or re-verification of old skills** —
the paper's only integrity check is a count assertion between the vector DB and the JSON index. This
is a confirmed gap this project's own module registry is already running into (see mechanisms doc's
"duplicates to resolve").

**Mineflayer/MineDojo** (https://github.com/PrismarineJS/mineflayer,
https://arxiv.org/abs/2206.08853). Voyager's action space is raw JS calling a promise-based bot API
(`bot.dig`, `bot.placeBlock`, `bot.pathfinder.goto(goal)`) plus hand-written "control primitives" — no
intermediate schema at all; reliability comes entirely from the bounded repair loop, not from action
validation. Useful negative lesson: this project's compiler+lint validation layer is strictly stronger
than what Voyager relies on.

**T2BM** (https://arxiv.org/abs/2406.08751) is the closest published analog to this project's own
architecture: prompt-refine → JSON "interlayer" (structural cuboids with `start/end/material/hollow`
+ functional point blocks with a `state` dict) → **deterministic repair pass** (fill defaults, strip
disallowed properties, substitute illegal materials, normalize names) → compile via GDPC
`placeCuboid`/`placeBlock`. It has **no post-build inspect-and-revise loop** — validation is entirely
static/deterministic, which is a step behind this project's dry-run-compile-then-draw-then-verify
design. DreamCraft (https://arxiv.org/abs/2404.15538) turned out to be a differentiable-NeRF voxel
system, not an LLM-DSL system — a useful negative example, not a technique to borrow.

**Factorio Learning Environment** (https://arxiv.org/abs/2503.09617,
https://github.com/JackHopkins/factorio-learning-environment). Agents write Python against a
persistent REPL namespace (`place_entity`, `connect_entities`, `nearest`, `production_stats`), scored
by a value-weighted **Production Score** and, for lab-play, sustained-throughput milestones measured
over a **60-second holdout window** — i.e., verification is "stayed correct for a while," not
"compiled once," which is directly relevant to strengthening this project's playbook verify-steps.
Documented failure modes: weaker models can't coordinate more than ~6 machines, make spatial
overlap/collision errors, and get stuck in **repeat-the-same-fix loops** rather than trying a different
approach — the exact failure mode the "blind resampling beats repair" finding (Thread 3) explains and
fixes.

**Code as Policies** (https://arxiv.org/abs/2209.07753). Hierarchical generation: the system parses the
generated code's AST, finds undefined function references, and recursively invokes a specialized
LMP to write just that function's body — a real "modules calling modules, generate missing ones
on demand" pattern, directly analogous to `blueprint_module_save`'s self-improvement loop but doing it
inline during generation rather than as a separate save step.

**Eureka** (https://arxiv.org/abs/2310.12931). Population-based: K=16 candidates/iteration, 55
iterations, 5 runs; each candidate is actually evaluated in the real simulator (RL training), ranked by
an explicit fitness function separate from the generated artifact itself (avoids reward hacking); the
key mechanism is **reward reflection** — feeding back the trajectory of *every individual scoring
component* over time as text, not just a final scalar, so the LLM can target specific failures. Maps
directly onto this project's lint findings (per-rule breakdown) plus a hypothetical per-module sim
telemetry breakdown.

**ReAct** (https://arxiv.org/abs/2210.03629) / **Reflexion** (https://arxiv.org/abs/2303.11366).
Reflexion's verbal-memory mechanism is cheap and small-model-friendly: after a failure, one LLM call
produces a short diagnosis string, stored **verbatim in a capped buffer (Ω usually 1-3 entries)**,
reinjected at the top of the next attempt's prompt. This is a lightweight complement to the existing
`build-lessons.jsonl` (which is unbounded and full-text-searched via `element_facts`) — a small capped,
task-scoped reflection buffer is a different, more immediately-actionable memory than a large lessons
corpus.

**Skill libraries w/ verifiers.** DreamCoder (https://arxiv.org/abs/2006.08381): wake (search) / sleep
(compress solutions into new named primitives via version-space algebra, keeping only what maximizes a
Bayesian compression objective) / dream (retrain retrieval on replays+fantasies) — the "compress solved
builds into new registry primitives, unsolved builds are the frontier" idea maps onto growing this
project's module registry from playbook successes. **LATM** (https://arxiv.org/abs/2305.17126): a
strong "tool-maker" model authors and unit-test-verifies a function once; a cheap "tool-user" model only
calls it — this is the strongest single match for a small-local-model project: let a bigger model (or
a human via `blueprint_module_save`, as today) author and verify modules, and keep the small model's
job strictly to composition over the trusted registry.

**Test-time tree search.** PG-TD (https://arxiv.org/abs/2303.05510) is the cleanest instance of
"simulator as leaf verifier": partial programs are nodes, leaves are completed and *actually executed*
against tests, pass rate backpropagated via P-UCB. Because a TPT blueprint's evaluation (compile + lint
+ short sim run) is comparatively cheap and near-deterministic versus an RL training run, a small tree
search over "which module goes next" with the compiler+lint as a fast pre-filter and a short sim run as
the real leaf check is plausible at a much smaller budget than Eureka's or PG-TD's.

### Thread 3 — Small-model orchestration

**Grammar-constrained decoding.** Ollama's `format` parameter has accepted a **full JSON Schema**
since v0.5 (Dec 2024, compiled internally to GBNF — https://ollama.com/blog/structured-outputs,
PR https://github.com/ollama/ollama/pull/7900); the current driver (`scripts/blueprint_agent.py:95`)
passes `"format": "json"` (bare JSON-object mode only), not a schema — switching to a real schema for
the blueprint format is close to free. Caveats found: schema is sometimes ignored unless also echoed
in-prompt (https://github.com/ollama/ollama/issues/8162); `pattern`/regex and numeric min/max are
**not** supported in Ollama's schema subset (https://github.com/ollama/ollama/issues/8325) — range/
pattern checks must stay in the compiler. For anything needing true regex-level constraints (element-id
patterns, coordinate ranges), bypassing Ollama for `llama-cpp-python` + **LM Format Enforcer**
(https://github.com/noamgat/lm-format-enforcer) or **Outlines**
(https://dottxt-ai.github.io/outlines/latest/features/models/) is the documented path — but Outlines
explicitly cannot constrain a model served over Ollama's HTTP API
(https://github.com/dottxt-ai/outlines/issues/1135), only a directly-loaded GGUF.

**Few-shot exemplars.** Meta-Tool (https://arxiv.org/abs/2604.20148) on 3B-class tool calling: 0-shot
27.0% → 1-shot 35.0% → 3-shot 43.0% → 5-shot 47.0% — biggest jump 0→1, plateau after 3. Role of
Diversity in ICL (https://arxiv.org/abs/2505.19426): for extraction-shaped tasks (closer to blueprint
JSON than free reasoning), format is learned in **one** example — diversity matters more for
compositional tasks. "When Correct Demonstrations Hurt" (https://arxiv.org/html/2605.26350): small
models are far more fragile to noisy/mismatched exemplars than large ones. Practical read for this
project: **1 schema-exact example + 1-2 shape-diverse examples (a `module` op vs. a `box` op), closest
one last** — the current driver includes exactly one example from `blueprint_schema`, which is close
to optimal already; adding one more genuinely different example (e.g. a `repeat`+anchors example) is
worth trying.

**Repair loops.** The single most important, most counter-intuitive finding across all four threads:
**"Try Again, Don't Look Back"** (https://arxiv.org/abs/2607.26117) — for code models at 1.5B/3B, blind
resampling (fresh attempt, no feedback, no prior output shown) *beats* feedback-conditioned repair;
showing the model its own failed output cost 6.1 points at 1.5B (p=0.006), and small models
reproduce a near-identical broken artifact 33-68% of retries under feedback-conditioning vs. 2-14%
under fresh resampling. "How Many Tries Does It Take?" (https://arxiv.org/abs/2604.10508): **2 repair
rounds capture 76-95%** of total achievable gain across 8B-70B, round 1 is the biggest, rounds 3-4
mostly thrash. Small-model self-correction only reliably works with an **external verifier**
(https://arxiv.org/abs/2404.17140, https://arxiv.org/abs/2305.11738) — which this project already has
(the compiler) — and structured field-level error pointers help small models disproportionately
*if they engage with feedback at all* (https://arxiv.org/pdf/2602.02416), which the existing
`{path, problem, fix}` error contract already provides.

**Decomposition.** COPE (https://arxiv.org/html/2506.11578v3): a bigger planner model handing plans to
a small executor lifts small-model task success 10-11 points; the *reverse* direction (small plans for
big) hurts. Aider's architect/editor split (https://aider.chat/2024/09/26/architect.html) is a
production precedent for exactly this pattern. Decomposed prompts help smaller models disproportionately
more than larger ones (https://arxiv.org/html/2602.04853v1: +7.88% at 8B vs +3.95% at 405B). "Don't
Adapt SLMs for Tools; Adapt Tool Schemas to the Models" (https://arxiv.org/pdf/2510.07248): flatter
fields, fewer enum choices, fixed key order improve small-model fill accuracy more than fine-tuning
would.

**Tool-calling format.** BFCL v4's format-sensitivity study
(https://gorilla.cs.berkeley.edu/blogs/17_bfcl_v4_prompt_variation.html) and a dedicated small-model
study (https://arxiv.org/abs/2507.01810, 3-14B) both find **plain JSON clearly beats XML and YAML** for
small models specifically (YAML as low as 23.4% unguided-parseable at small sizes) — this project
should not consider switching the blueprint format to YAML/TOON for token-efficiency reasons; the
accuracy cost at small model sizes would outweigh it.

**Eval harnesses.** No existing framework (promptfoo, DeepEval, BFCL) has a native `pass^k` metric
(all of k independent trials must succeed) even though it's the more relevant metric for a system with
a repair loop than plain `pass@k`; https://leehanchung.github.io/blogs/2025/09/08/pass-at-k/ gives the
formula and notes 75% per-trial success is only ~42% at pass^3 — a concrete argument for building a
small custom harness (repeat N=5-10, log first-try-valid / valid-after-repair-round-k / compile-ok,
compute pass^k yourself) rather than assuming an off-the-shelf tool covers it.

### Thread 4 — Verification and self-improvement

**Simulation-in-the-loop, beyond frame-N census.** RTAMT (https://arxiv.org/pdf/2005.11827) and STeP
(https://arxiv.org/html/2607.18580v1) formalize "temporal assertions" as **Signal Temporal Logic**
checked continuously against a streaming signal, producing a real-valued **robustness score**
(sign = pass/fail, magnitude = margin) rather than a boolean at one instant — and STeP's loop
specifically **halts mid-run when robustness drops below a threshold** and feeds the observation +
robustness trace back for replanning. This is a direct, concrete upgrade path for this project's
playbook verify-steps (currently "census after N frames") to something like `G[0,600] |DEUT_life - target| < margin`,
checked every K frames, catching a transient pressure spike or leak that a single end-of-window census
would miss.

**Property-based testing on generated artifacts.** Hypothesis's `RuleBasedStateMachine`
(https://hypothesis.readthedocs.io/en/latest/stateful.html) pattern — `@rule` = an operation (add
module / connect / set param), `@invariant` = a check run after every rule, with automatic shrinking to
a minimal failing sequence — maps cleanly onto fuzzing a registry module's own numeric `params` schema
(already parametric via arithmetic expressions per `BLUEPRINT_SPEC.md`): generate a rule machine that
sweeps a module's params, assert it still compiles clean and its invariants (e.g. "still passes
`heat_source_uninsulated`") hold, shrink any counterexample to the minimal failing param set, and file
it as a lesson automatically. ChekProp (https://arxiv.org/html/2505.23549) shows the same generated
property code can double as a **runtime guardrail**, not just an offline test.

**Golden/regression suites.** Langfuse's golden-dataset engineering guide
(https://langfuse.com/resources/engineering/golden-dataset-evaluation) gives a concrete, adaptable item
schema (`input`, `expected_output`, `metadata{source, date_added}`) and sizing guidance (~10 for
exploration, tens-to-low-hundreds for per-change gating, "100 diverse beats 1000 near-duplicate"); its
regression-CI companion (https://langfuse.com/resources/engineering/llm-regression-testing) runs the
golden set on every change and fails on hard-floor thresholds set ~0.08 below baseline (to absorb
judge/sim noise), flagging item-level pass→fail flips rather than trusting aggregate averages alone
(an offsetting swing can hide a real regression). **This project has zero such suite today** despite
having 47 verified modules and dozens of lessons that would populate one almost for free.

**Curriculum from failures.** Voyager's curriculum lists failed tasks but doesn't cluster or analyze
them (https://arxiv.org/html/2305.16291). DreamCoder's abstraction step
(https://ar5iv.labs.arxiv.org/html/2006.08381) compresses *solved* programs into new primitives —
implicitly this project's own `blueprint_module_save` already does this. The more relevant curriculum
mechanism is from RL-environment-generation: **PAIRED** (https://arxiv.org/abs/2012.02096) and
**ACCEL** (https://arxiv.org/abs/2203.01302) generate the next challenge by *mutating a past
high-regret example* rather than proposing freeform new tasks — i.e., for this project, cluster
`build-lessons.jsonl` by embedding similarity, and generate the next playbook practice by perturbing a
blueprint known to trigger a recurring lesson cluster, rather than composing something novel from
scratch (cheaper to verify, guaranteed to stress the right thing).

**Fine-tune loops.** Concrete, chainable recipe surfaced across several papers: (1) log every attempt
as `(goal, blueprint, verdict-bundle{compile, lint[], verify pass, census score})` — cheap, should
start now regardless of whether fine-tuning happens soon; (2) SFT set = compile ∧ verify ∧ zero hard
lint findings; (3) DPO pairs per RS-DPO (https://arxiv.org/html/2402.10038v1) — for same-goal attempts,
compute a score-gap and keep only pairs above a threshold η (their worked example: η=0.90 kept 12.8K of
a larger pool, tighter than looser thresholds); (4) STaR-style rationalization
(https://arxiv.org/abs/2203.14465) for goals that always fail but are close to an existing registry
module — have a bigger model write the hindsight adaptation and file it as a success; (5) escalate the
acceptance bar each retraining round (ReST, https://arxiv.org/html/2308.08998v2). Practitioner
consensus on data volume: **500-5,000 narrow, high-quality examples** produce noticeable gains in a
<8B model via LoRA — well within reach of this project's own logs if attempt-logging starts now.

**Skill-library drift avoidance.** Voyager confirmed to have **no dedup, pruning, versioning, or GC** —
an acknowledged gap, not a solved problem, in the literature itself. SkillBrew
(https://arxiv.org/pdf/2605.29440) and SkillOps (https://arxiv.org/abs/2605.13716) are the concrete
fixes: embedding-similarity gate at insertion (cosine ≥0.85 → merge/reject, 0.6-0.85 → flag for
review — general thresholds from code-dedup tooling, not TPT-specific), typed module "contracts"
(precondition/output/verification/failure-mode) rather than bare code, and a periodic (not per-insert)
consolidation pass that re-verifies every stored skill under the current compiler/environment version
and archives ones that no longer pass. **This project's own module registry has already hit the exact
failure this predicts** — the mechanisms doc's "duplicates to resolve" list
(`cray_neut_igniter`/`neut_cray_nozzle`, `rbmk_rod_drive`/`rbmk_channel_cell`/`control_rod_pstn_bank`,
`tsns_wifi_ladder`/`tsns_ladder_10`) is precisely the near-duplicate accumulation the literature warns
about, produced by two parallel harvesting passes with no insertion-time similarity check.

---

## (c) Prioritised roadmap for this system

Ordered by (evidence strength × leverage) / effort. Each item names the concrete component it touches.

1. **Switch `blueprint_agent.py`'s Ollama call from `format:"json"` to `format:<blueprint JSON
   Schema>`.** *Component: local-model driver (`scripts/blueprint_agent.py`).* *Effort: small* (derive
   a JSON Schema from `blueprint_schema`'s existing reference/module table once, pass it as `format`).
   *Gain: large* — eliminates the whole class of syntax-shaped compile errors the repair loop currently
   spends rounds on, for close to zero engineering cost. Caveat: Ollama's schema subset has no
   `pattern`/min-max, so element-name and coordinate-range validation stays in the compiler as today.

2. **Cap the repair loop at 2 rounds by default, then fall back to a fresh (blind) attempt instead of
   round 3-4 feedback-conditioned repair.** *Component: local-model driver.* *Effort: small* (change
   `--rounds` default and, past round 2, drop the assistant's prior reply from the message list instead
   of appending another correction turn). *Gain: large* — directly implements the strongest single
   finding in Thread 3 (arXiv 2607.26117, 2604.10508): small models anchor on their own broken output
   under feedback-conditioning, and most of the achievable gain is already captured by round 2.

3. **Add a blind-resample A/B mode to the driver and measure it against the current repair-loop mode
   on a fixed set of test prompts.** *Component: local-model driver + new eval harness (below).*
   *Effort: medium.* *Gain: medium-high* — turns item 2 from "trust the paper" into "verified on our
   own blueprint DSL," which matters because the paper's domain (MBPP+ Python) is not this project's
   domain.

4. **Build a small pass@k / pass^k regression harness for the driver.** *Component: new script,
   sibling to `blueprint_agent.py` (e.g. `scripts/agent_eval.py`).* *Effort: medium* (N=5-10 repeats
   per test prompt, log first-try-valid / valid-after-round-k / final-compile-ok, compute pass^k per
   Thread 3's formula). *Gain: high* — every other change on this list (schema format, round count,
   exemplar count, decomposition) needs this to know if it helped; currently there is no way to tell.
   This is the single highest-leverage infrastructure gap.

5. **Add a golden-build regression suite: 20-50 blueprints (verified registry modules + past
   lesson-triggering builds) with expected census bands + lint baseline, re-run on every change to the
   compiler, lint rules, or playbook.** *Component: `blueprint_lint`/`blueprint_build` (new test
   harness around them) + `knowledge/modules/*.json` as the seed corpus.* *Effort: medium.* *Gain:
   high* — this project has zero regression protection today despite 47 modules and a compiler that
   gets edited; a lint-rule change or compiler bugfix could silently break a previously-verified module
   with no signal. Auto-promote a golden item whenever `record_build_lesson` files a lesson not yet
   covered.

6. **Add an embedding-similarity gate to `blueprint_module_save` (reject/merge ≥0.85 cosine on the
   module's `description`+`why` text, flag 0.6-0.85 for review) plus a one-time dedup pass over the
   existing 47 modules to resolve the mechanisms doc's own documented duplicates.** *Component:
   `blueprint_module_save` (`powder_ext/blueprint_tools.py`) + `knowledge/modules/*.json`.* *Effort:
   medium* (needs an embedding call — could reuse whatever the harvester/knowledge stack already has
   available, or a cheap local sentence-embedding model). *Gain: medium-high* — the failure mode this
   prevents has already happened once (documented duplicates from two parallel harvest passes); left
   unfixed it will keep recurring and will actively confuse a small model given a long module list to
   choose from.

7. **Add a planner/executor split to the driver for multi-module builds: a bigger model (or a static
   rule extracting an ordered module list from the playbook practice being attempted) emits a short
   ordered plan of `{module, params}` calls; the small model fills/validates one call's JSON at a time
   against that op's own sub-schema.** *Component: local-model driver + `blueprint_schema`'s module
   table (already structured enough to slice per-module).* *Effort: medium-large.* *Gain: high for
   complex builds specifically* — COPE/Aider/2602.04853 all show decomposition helps small models
   most, and this project's module system is already the right shape for a plan to be "a list of module
   calls" rather than a monolithic blueprint the small model must get entirely right in one shot.

8. **Extend the playbook's verify-step language from "census at frame N" to a bounded temporal
   assertion (`hold over frames [a,b] within margin`), checked every K frames with a robustness/margin
   value, not just a single boolean at the end.** *Component: `PLAYBOOK.md` / `playbook.json` verify
   steps + whatever runs them (currently manual/spatial_snapshot-based).* *Effort: medium.* *Gain:
   medium-high* — several already-documented pitfalls (pressure chamber stability, valve leaks, DEUT
   concentration drift) are exactly the kind of transient-violation-then-recovery case a single
   end-of-window census can miss.

9. **Log every agent attempt as a `(goal, blueprint, verdict-bundle)` triple now**, independent of
   whether fine-tuning happens soon. *Component: local-model driver (append one line per attempt to a
   new `knowledge/agent-attempts.jsonl`) + existing `experiment_run`/`experiment_evaluate` tools as the
   verdict source where applicable.* *Effort: small.* *Gain: high long-run, ~zero cost now* — this is
   the raw material for items 10, 11, and any future fine-tuning; it is free to start collecting and
   expensive to reconstruct retroactively.

10. **Add a capped verbal-reflection buffer (Reflexion-style, Ω=1-3 entries) scoped to a single task
    attempt, distinct from the long-running `build-lessons.jsonl`.** *Component: local-model driver.*
    *Effort: small* — after a failed round, one short diagnosis string (could literally be the
    lint/compile summary already computed) prepended to the next attempt's system context, capped and
    FIFO. *Gain: medium* — cheap, complements rather than duplicates the existing lessons store, which
    is corpus-wide and full-text-searched rather than task-scoped.

11. **Failure-cluster-driven curriculum: cluster `build-lessons.jsonl` by embedding similarity, and for
    high-recurrence clusters generate the next playbook practice by mutating a known lesson-triggering
    blueprint (ACCEL-style small edits) rather than composing a fresh one.** *Component: `PLAYBOOK.md`
    authoring process + `knowledge/build-lessons.jsonl` + module registry as the mutation source.*
    *Effort: medium-large* (needs the same embedding infrastructure as item 6 — worth building once and
    sharing). *Gain: medium* — turns the lessons store from a passive reference into an active
    curriculum generator; lower priority than items 4-6 because it depends on having the regression
    harness and dedup infra first.

12. **Property-based parameter sweeps for registry modules**: for each module's numeric `params`
    schema (already arithmetic-expression-based per `BLUEPRINT_SPEC.md`), generate a range sweep,
    assert compile-clean + no new-critical-lint across the range, shrink any failing point to a minimal
    counterexample, file it as a lesson automatically. *Component: `knowledge/modules/*.json` + a new
    test script around `blueprint_lint`/`blueprint_build`.* *Effort: medium.* *Gain: medium* — modules
    are currently validated once at save-time with their *default* params only; nothing checks the
    parametric range actually used in practice stays compile-clean, which is a real gap given how
    heavily the playbook's "scale up" sections reuse modules at different sizes.

13. **Trim/standardize few-shot exemplars in the driver's system prompt to 1 schema-exact + 1
    shape-diverse example (e.g. add one `repeat`+anchor-reference example alongside the existing
    `module`-heavy example).** *Component: local-model driver (`system_prompt()` in
    `blueprint_agent.py`).* *Effort: trivial.* *Gain: small-medium* — cheap, evidence-backed
    (diminishing returns past 3 examples at this model size per Thread 3), easy to bundle with item 1's
    schema change.

14. **Do not port TSNS/PSNS-threshold-ladder-style continuous monitoring or attempt a from-scratch TPT
    save-format parser** — explicitly deprioritized. *Rationale:* Thread 1 confirms no headless mode
    and no existing parser exist upstream; building one would be a large, TPT-specific engineering
    project orthogonal to the actual bottleneck (agent reliability), which is better spent on items
    1-8 above. Revisit only if the live-bridge approach (`sim.loadStamp`/`execute_lua`) becomes an
    actual throughput bottleneck for the harvester or experimenter.

---

## (d) TPT save IDs and wiki pages worth harvesting next

Beyond the 38 already deep-read (`mechanisms-community-2026-08-25.md`) and the LOW-relevance saves
already triaged (`knowledge/saves/triage.md`):

**Save IDs (non-reactor, general control-logic/mechanism harvest):**
- `2993999` — "Logic gate examples" (Thisfact) — worked logic-gate reference set, good for a future
  general-control-logic module family beyond reactor SCRAM/valve patterns.
- `3096033` — radix/base converter using parallel SPRK data.
- `3096036` — SIPO/PISO shift registers (serial↔parallel FILT conversion) — good general "digital
  circuit primitive" harvest target.
- `1101093` — "[Tutorial] PSTN and FRME" (FilipT) — canonical piston/frame tutorial, complements the
  empirically-derived `control_rod_pstn_bank`/`rbmk_rod_drive` modules with an author-intended
  reference case.
- `1382457` — "Pstn Tutorial" (G-LinuxorU) — second independent piston tutorial, useful for
  cross-checking which PSTN/FRME conventions are universal vs. author-specific.
- Seed further harvesting from `search:tutorial` and `search:computer` query strings against
  `Browse.json?Search_Query=` (already the harvester's own query mechanism) — e.g. the "how to make a
  working computer?" discussion thread (https://powdertoy.co.uk/Discussions/Thread/View.html?Thread=23598)
  links to several attempted full-computer builds worth triaging.

**Wiki pages (index/category pages, high harvest yield per page):**
- `Elements:Sensors` (https://powdertoy.co.uk/Wiki/index.php?title=Elements:Sensors) — category index
  covering all sensor elements (DTEC/TSNS/PSNS/etc.) in one page.
- `Elements:Force` (https://powdertoy.co.uk/Wiki/index.php?title=Elements:Force) — category index for
  PSTN/FRME-family mechanical elements.
- `Elements:Special`, `Elements:Electronics`, `Elements:Powered_materials` — category-level pages
  indexing everything CLNE/CRAY/CONV/WIFI-adjacent, higher yield per fetch than one element page at a
  time.
- External (non-wiki) cross-reference: https://blog.javadhamidi.com/posts/powder-toy-circuits/ —
  independent digital-logic-in-TPT writeup, useful as a second source to validate logic-gate
  conventions the harvester extracts from saves.

---

## (e) Open risks

- **Blind resampling vs. feedback-repair is evidence from Python code-generation benchmarks (MBPP+),
  not from a spatial JSON-DSL task.** The mechanism (small models anchoring on their own broken output)
  is plausible here too, but item 3 (A/B measurement on this project's own driver) should confirm it
  before fully committing item 2's default-round-cap change — don't take the paper's number as
  this project's number without checking.
- **Embedding-based module dedup (item 6) requires picking and hosting an embedding model** — this
  project's stack is otherwise dependency-light (stdlib + Ollama's HTTP API); adding a sentence-embedding
  dependency, even a small local one, is a real new moving part and its own source of drift if the
  embedding model changes between passes.
- **Ollama's `format:<schema>` is reported inconsistent on some backends/model runners** (MLX,
  thinking-mode models per the GitHub issues cited in Thread 3) — verify behavior specifically on
  whatever model(s) this project actually runs (`qwen2.5:1.5b`, `llama3.2:1b`) before relying on it as
  the sole validity guarantee; keep the compiler as the backstop regardless.
- **No TPT save-format parser or headless mode exists upstream and none is likely to appear** — any
  future desire to run many parallel/fast experiments (e.g. for the property-based sweeps in item 12,
  or a fine-tuning data-generation push) is bottlenecked on however many live game instances can be
  driven via the Lua bridge at once; this is a real ceiling on throughput that no amount of agent-side
  cleverness removes.
- **The regression suite (item 5) and dedup pass (item 6) both need to be run by something** — neither
  is self-triggering; without wiring them into whatever process edits the compiler/lint/module registry
  (currently manual, ad hoc), they will silently go stale the same way the module registry already did.
- **Fine-tuning (Thread 4 pipeline) assumes 500-2,000 clean triples are reachable** — this depends
  entirely on item 9 (attempt logging) actually being turned on and left running; if it isn't, the
  fine-tuning roadmap item has no data and stays theoretical indefinitely.
- **The community-save mechanism research itself documents real safety patterns this bot must not
  regress on** (unjacketed WIFI as the single most common community mistake, unarmed CLNE left in a
  live fuel column, field-only containment with no physical backup) — as the roadmap above adds more
  automation (planner/executor split, mutation-based curriculum, property sweeps), each new automated
  build-generation path should be checked against the existing lint rules and lessons store, not just
  against compile-success, or the bot could learn to generate builds that pass the compiler while
  reproducing a documented community mistake.
