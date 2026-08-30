# Research round 3: AGENT METHODS (2026-08-26)

Front 2 of 5. Follow-up to `research-building-bot-2026-08-25.md` (round 1) and
`research-building-bot-round2-2026-08-25.md` (round 2). This pass does not repeat anything already
found there — see the "already covered" recap in each thread below for what was excluded. Current
implementation state confirmed by reading `scripts/blueprint_agent.py` (236 lines),
`scripts/passk_harness.py` (64 lines), `powder_ext/agent_tools.py`, `powder_ext/build_tools.py`,
`BLUEPRINT_SPEC.md`, `PLAYBOOK.md` before researching: schema-constrained decoding, the 2-round
repair cap with blind-resample fallback, **localized CEGIS-style repair feedback is already
implemented** (`solve()`'s `bad_idx`/`failing_parts` block — round 2 item 2 is done), attempt logging
(`record_attempt`, 1 real entry in `knowledge/attempts.jsonl` as of this pass, schema:
`{ts, goal, practice, level, model, verdict, evidence, errors, blueprint}` — verdict is a single
`pass|fail|partial` enum, no reward decomposition), and a working `passk_harness.py` that computes
pass@1/pass@k/pass^k as simple pooled means (not the Beta-Binomial per-item interval round 2 item 3
recommended — still open). The module registry has grown to **76 modules** (up from 47 at round 1).

**Session constraint, disclosed plainly:** `WebSearch` was exhausted (200/200) for this shared session
before any of the five parallel research forks could run a single query — this happened immediately,
not from this pass's own usage, and is a hard session-wide limit the forks could not work around.
Every finding below was instead obtained via `WebFetch` against `export.arxiv.org/api/query` (the
public arXiv API, a plain GET endpoint, distinct from the search-engine tool) plus direct fetches of
specific known pages (Ollama's blog, HuggingFace model cards, TRL docs, Unsloth docs). This is a
**real, cheap, working substitute** for arXiv-heavy research when `WebSearch` is unavailable — worth
remembering for future passes. It cannot discover URLs outside arXiv without a search engine, so
non-arXiv material (blog posts, GitHub issues) is thinner than in rounds 1-2 and web coverage of
2026-specific practitioner blogs is weaker than it would otherwise be.

---

## (a) Construction/engineering-design agents, tree search over plans, design-by-test

**Already covered, not repeated:** Voyager, JARVIS-1/Optimus-1/2, Factorio Learning Environment,
T2BM, Code as Policies, Eureka, ReAct/Reflexion, DreamCoder, LATM, PG-TD, "Architecting Resilient LLM
Agents" (arXiv 2509.08646), VeriGuard (2510.05156), LayoutLLM-T2I, WorldClaw (2608.05248), Co-Layout
(2511.12474), HLG (2508.17832), LayoutGPT, Holodeck (2403.09675), LayoutVLM (2412.02193), CEGIS repair
(2502.07786), SCAFFOLD-CEGIS (2603.08520).

**Minecraft building agents beyond Voyager.**
- **MineAnyBuild** (arXiv 2505.20148, NeurIPS 2025 D&B track) — 4,000-task benchmark scoring
  spatial-planning agents on four dimensions: spatial understanding, spatial reasoning, creativity,
  spatial commonsense. Current MLLM agents show "severe limitations" despite the task's apparent
  simplicity. https://arxiv.org/abs/2505.20148
- **Optimus-2** (arXiv 2502.19902, CVPR 2025) — MLLM planner + a Goal-Observation-Action-conditioned
  low-level policy, trained on 25,000 gameplay videos. https://arxiv.org/abs/2502.19902
- **WALL-E 2.0** (arXiv 2504.15785) — neurosymbolic: learns action-rule/scene-graph symbolic knowledge
  from exploration to complement an LLM's priors, evaluated in Minecraft.
  https://arxiv.org/abs/2504.15785
- **GROOT** (arXiv 2310.08235) — instruction-following from gameplay video, evaluated on a
  **"Minecraft SkillForge" benchmark** via Elo ratings — a named skill-benchmark worth knowing about
  even though it predates this pass's window. https://arxiv.org/abs/2310.08235
- **Luban** (arXiv 2405.15414) — "two-level autonomous embodied verification" combining a visual
  check and a **pragmatic (functional) check** for open-ended Minecraft building tasks with abstract
  creative criteria — directly relevant as a named precedent for pairing a cheap structural check with
  a functional/behavioral one, which is this project's own census-after-N-frames approach already.
  https://arxiv.org/abs/2405.15414

**Factorio beyond FLE.** Thin: only a position paper (arXiv 2502.01492, argues Factorio as a
systems-engineering sandbox, no results) and Prime Agent (arXiv 2608.23552, a general long-horizon
harness evaluated *partly* on Factorio, not construction-specific). No new dedicated Factorio
build-agent method found this pass.

**Text-to-CAD — the most active 2025-2026 area found, 20+ papers.** Concrete mechanisms:
- **RA-CAD** (arXiv 2608.05714) — a "Generate-Execute-Critique-Rewrite" loop where the critique step
  is a *learned policy action* (continue vs. revise), trained via SFT (CAD-Code Bootstrapping) then
  **trajectory-level GRPO** with reward = F1 + Chamfer Distance. Claims SOTA on CADFusion/Text2CAD
  benchmarks (no absolute numbers in the fetched abstract). https://arxiv.org/abs/2608.05714
- **CADSmith** (arXiv 2603.26512) — multi-agent pipeline with "nested correction loops" combining
  exact OpenCASCADE-kernel geometric measurement with a VLM's qualitative assessment — a genuine
  precedent for "deterministic tool check + one LLM-judgment check," not a pure LLM critic.
- **ASSEMCAD** (arXiv 2607.05123) — assembly generation with typed parts, geometry-backed ports, and
  engineering-principle validation beyond pure code generation — the closest analog to this project's
  own module system (typed, parametrized, precondition-bearing units composed into an assembly).
- **TOOLCAD** (arXiv 2604.07960) — a tool-using CAD agent trained via *online curriculum RL*.
- Named benchmarks worth knowing: **CADTests** (2605.07807, executable-test-based CAD evaluation —
  i.e. functional pass/fail via generated tests, not visual similarity), **Text2CAD-Bench**
  (2605.18430, 600 examples across 4 complexity tiers — a concrete difficulty-ladder precedent), MUSE
  (2605.28579).
- **Symbolic Intermediaries for LLM-Driven Geometric Reasoning** (arXiv 2505.17607) — a design agent
  maps NL specs to executable simulation code; a critique agent reasons over a *shared symbolic
  vocabulary* with the design agent (not raw code) and turns feedback into revisions. Reports
  **19-53% improvement over genetic-algorithm baselines** on mechanism-synthesis tasks — the closest
  finding to a quantified "generate -> simulate -> critique -> revise" loop for physical-mechanism
  design, though the paper does not use the phrase "design-by-test." https://arxiv.org/abs/2505.17607

**Robotics assembly-sequence planning with LLMs.** Flagged plainly as a gap: targeted arXiv queries
returned nothing on-topic this pass.

**"Design-by-test" / "test-driven design" as a named methodology.** **Not found under that name
anywhere in arXiv abstracts/full text.** The functional equivalent exists (RA-CAD's
Generate-Execute-Critique-Rewrite, the Symbolic-Intermediaries loop above, CADTests' executable-test
framing) but nobody has named it that — same "real gap in naming, not in substance" pattern round 1
found for TPT+LLM prior art.

**MCTS/tree-search over plans with simulator rollouts.**
- **CEDAR** (arXiv 2608.06871) — the cleanest hit: **explicitly an "MCTS variant with an
  LLM-parameterized transition kernel and value function"** for goal-directed system design. Designs
  are executable programs; an LLM Judge scores emergent behavior against the goal (the fitness
  function/leaf value); an LLM Editor proposes variants (the transition kernel). No tree width/depth
  or rollout-budget numbers were recoverable from the abstract-level fetch — flag for a full-text read
  if this is pursued. https://arxiv.org/abs/2608.06871
- **GATS** (arXiv 2607.08894) — extends LATS with a learned world model plus UCB1 tree search
  specifically to **eliminate LLM calls during planning** (the world model substitutes for repeated
  LLM rollout calls) — directly relevant if tree search over module-plans is ever built, since it
  would otherwise mean one LLM call per tree-search rollout, which is expensive against a small local
  model. https://arxiv.org/abs/2607.08894
- **FlowScout** (arXiv 2608.10039) — MCTS refines a tool-using agent's *workflow topology* (a graph of
  LLM/tool nodes) guided by execution feedback — structurally the same "tree search over a plan
  graph" shape as a module-call plan, just not spatial/construction domain.
- **No paper found that runs MCTS specifically over building/construction plans with a physics-sim
  rollout as the reward** — CEDAR is the closest analog (executable-system rollout as fitness) but is
  general-systems, not spatial. This is a genuine, confirmed gap, consistent with round 1's PG-TD
  finding that this project's cheap-compile-cheap-sim profile is unusually well-suited to a
  tree-search approach nobody has published for this exact task shape.

---

## (b) Turning attempt logs into training data: SFT/DPO/RFT/GRPO recipes and what `attempts.jsonl` needs

**Already covered, not repeated:** LoRA hyperparameter ladder (Unsloth), AutoAssert 1 (2508.07371),
RS-DPO (2402.10038, eta=0.90 threshold), STaR (2203.14465), ReST (2308.08998), ToolWeave (2605.12521),
general 500-2,000/500-5,000 dataset-size consensus.

**GRPO origin and defaults (new this pass — GRPO by name was not in rounds 1-2 at all).**
GRPO originates in the DeepSeekMath paper (arXiv 2402.03300) as a PPO variant that drops the critic
network — trained originally on a 7B model. https://arxiv.org/abs/2402.03300
HuggingFace TRL's `GRPOTrainer` defaults (https://huggingface.co/docs/trl/main/en/grpo_trainer):
group size (`num_generations`) **= 8** completions/prompt, advantages normalized by group mean/std,
LR **1e-6**, `per_device_train_batch_size=8`, **KL coefficient defaults to 0 (disabled)** — TRL's own
docs cite recent findings that the KL term "isn't essential," clip epsilon 0.2, temperature 1.0.
Reward functions can be **plain Python callables returning rule-based/verifiable scores** (compile
success, schema match, test pass) — no learned reward model required, which matches this project's
compiler+lint as a reward source almost exactly. LoRA is supported directly in `GRPOTrainer`
(`r=16, alpha=32, target q/v_proj` in TRL's own small-model example, Qwen2.5-0.5B-Instruct, ~1 GPU-day).

**GRPO/verifiable-reward for small models on structured output — concrete numbers.**
- **ToolRL** (arXiv 2504.13958) — GRPO on Qwen2.5-1.5B/3B/7B and Llama-3.2-3B for tool-calling.
  Reward = binary format reward + correctness reward (tool-name match, param-name match, param-value
  exact match), combined `R_final = R_format + R_correct ∈ [-3,4]`. **4 rollouts/prompt**, batch 512,
  LR 1e-6, no critic, 15 epochs, **KL removed entirely**. Qwen2.5-7B reached 58.4% on BFCL, +17pp over
  base and +15pp over SFT alone. https://arxiv.org/abs/2504.13958 — this is the single closest
  precedent to this project's own compile/lint-graded blueprint task.
- **"Think Inside the JSON"** (arXiv 2502.14905) — 1.5B model (same size class as this project's
  `qwen2.5:1.5b`), GRPO for strict schema adherence; reward = key-value match fraction + JSON
  length-similarity + a binary tag-format reward, combined via a weighted aggregator. 20K RL + 10K SFT
  samples, ~20h on 8xH100.
- **VeriGate** (arXiv 2605.30451) — extends GRPO with **verifier-gated step-level supervision**
  specifically to fix "sparse gradient collapse" when a whole group of sampled rollouts gets the *same*
  outcome-verifier score (a degenerate group with zero learning signal) — falls back to process/step
  reward in that case. Reports **~20% accuracy improvement at 1.5B, ~12% at 7B**. Directly actionable:
  a single pass/fail verdict per attempt (this project's current `record_attempt` schema) is exactly
  the shape that produces degenerate all-same-score groups; logging a finer-grained score (e.g.
  fraction of lint rules passed, not just pass/fail) would let a future GRPO run avoid this failure
  mode without redesigning the verifier. https://arxiv.org/abs/2605.30451
- **Unsloth's RL guide** (https://unsloth.ai/docs/get-started/reinforcement-learning-rl-guide):
  states GRPO reliability needs **>=1.5B params minimum** (this project's default model is exactly at
  that floor), recommends **rubric-style reward decomposition — "a list of smaller verifiable rewards,
  not one all-consuming reward"** — and needs >=500 training rows and >=300 steps before reward curves
  become meaningful.
- **Caveat found and flagged:** RL-Struct (arXiv 2512.00319, claimed 89.7%/92.1% structural
  accuracy/validity via GRPO) **has been withdrawn by its own authors** for "substantial errors in
  references, terminology, and experimental reporting" — do not cite its numbers if this line of work
  is followed up on.

**Rejection-sampling fine-tuning (RFT) — origin paper confirmed with exact hyperparameters.**
arXiv 2308.01825 ("Scaling Relationship on Learning Mathematical Reasoning with LLMs") is the actual
RFT paper: draws **k in {1,3,6,12,25,50,100} candidate samples per prompt** (primary config k=100) at
**temperature 0.7**, filters to only verifiably-correct completions, then **deduplicates by extracted
structural signature** (their domain: distinct equation sequences; 3+4=7 and 4+3=7 kept as different)
— explicitly to preserve *reasoning-path diversity* for generalization, not to keep only the single
best sample. https://arxiv.org/abs/2308.01825 This is a specific, actionable correction to how
`scripts/passk_harness.py` currently behaves: it draws k samples per task and logs **every one**
verbatim via `record_attempt` (`scripts/passk_harness.py:48-50`) with no structural dedup — if this
project ever assembles an SFT set from `attempts.jsonl`, near-duplicate passing blueprints (same
module, same param values, trivial coordinate shifts) would overrepresent whatever the model happened
to converge on first, the opposite of RFT's own stated reason for deduping by structure.

**What a verifiable-reward training example needs to log — direct answer to the task's question.**
- **RobustTests** (arXiv 2608.24135) identifies **weak verifier coverage as the direct cause of reward
  hacking** and argues for logging **per-step/dense pass rates, not a single binary pass/fail** —
  matches VeriGate's finding above.
- **"Spurious Rewards"** (arXiv 2506.10947) shows GRPO's clip mechanism can produce real-looking
  reward-curve improvement even under near-random rewards on some base models (Qwen) but not others
  (Llama3/OLMo2) — meaning a bare reward curve is not trustworthy evidence of genuine learning; the
  practical implication is to **log enough of the raw completion/behavior trace per attempt to audit
  for this**, not just the final scalar verdict.
- No canonical published schema for `{prompt, completion, verifier_trace, reward_decomposition,
  N_candidates, seed, temperature}` was found (a genuine gap, not a "nothing exists" — full-text
  practitioner blogs were unreachable without `WebSearch`), but synthesizing across VeriGate + RobustTests
  + the RFT paper's own dedup rationale + round 1-2's RS-DPO/DPO-pair requirement, `attempts.jsonl`
  needs, beyond its current fields, at minimum: **(1)** a decomposed score, not just `pass|fail|partial`
  (e.g. `{compiles: bool, lint_critical: int, lint_total: int, verify_pass: bool}`); **(2)** the
  `temperature` and `round_no`/`resample_no` that produced this specific sample, so multiple candidates
  for the same goal can be grouped into GRPO-style groups or RS-DPO-style pairs; **(3)** a structural
  signature of the blueprint (module list + param bucket, not raw JSON) cheap enough to dedup on before
  training, per the RFT paper's explicit rationale above.

---

## (c) Retrieval for skill libraries: embeddings, retrieval-augmented planning, dedup/GC

**Already covered, not repeated:** Voyager's Chroma top-5 retrieval, SkillBrew/SkillOps 0.85/0.6
dedup thresholds, DreamCoder wake/sleep/dream, LATM tool-maker/tool-user split, ACCEL/PAIRED.

**Retrieval-augmented planning (RAP) as a named line of work.**
- **RAP** (arXiv 2402.03610, Kagaya et al.) is the canonical name: retrieves past experiences from a
  contextual memory to ground each planning step.
- **ExRAP** (arXiv 2509.08222) extends this for continual embodied agents: each instruction is
  decomposed into queries against environment-context memory, **retrieval re-triggered per
  instruction/query, not once per whole plan**, plus a temporal-consistency refinement against memory
  decay.
- **MagicSelector** (arXiv 2607.17751) gives concrete mechanics directly answerable to "how is
  retrieval inserted": per-subtask query decomposition (not one global query), reranking via
  self-distillation hard-negative mining, and **"Dynamic Top-K"** — the retrieval cutoff adapts to
  observed score cliffs and semantic shifts rather than using a fixed k.
- **TinyAgent** (arXiv 2409.00608, Berkeley) — **the strongest single piece of evidence for this
  project specifically.** Table 1 directly compares full-tool-list-in-prompt against a
  retrieval-augmented shortlist (a fine-tuned DeBERTa-v3-small classifier, not embedding top-k, but
  functionally the same "shortlist before generation" role) on **1.1B and 7B local models**:
  - Full list: 2,762 prompt tokens -> 78.89% success (1.1B), 83.09% (7B).
  - Retrieval-shortlisted: 1,397 tokens (~2x reduction) -> **80.06% (1.1B), 84.95% (7B)** — retrieval
    *improved* accuracy and roughly halved prompt length at both sizes.
  https://arxiv.org/abs/2409.00608 — directly relevant because `blueprint_agent.py`'s
  `system_prompt()` currently dumps **all 76 modules'** `params`+`why` text into every single prompt
  (`scripts/blueprint_agent.py:37-43`), the exact regime TinyAgent's comparison targets, and the
  registry has grown 62% since round 1 (47 -> 76 modules) with no retrieval/shortlisting added yet.
- **"Don't Offer What Can't Be Done"** (arXiv 2608.01050, deployed at Wix's Helpmate assistant, 756.6K
  real messages) — a three-stage pipeline: semantic match (retains 23.1%) -> **deterministic
  executability gate** checking preconditions against live system state (removes a further 59.4% of
  candidates) -> LLM selection over what's left. Result: 90.5% context reduction, 59.1% token savings,
  and **without the gate the model would have picked a blocked/non-executable skill 7.8% of the
  time.** https://arxiv.org/abs/2608.01050 — a real-world precedent for gating on preconditions before
  showing a module to the model at all, distinct from and complementary to embedding-similarity
  retrieval.

**Embedding model choice for short technical text (resolves round 1's flagged open risk).**
Round 1 flagged embedding-based dedup as needing "a new moving part... a real new dependency" for this
otherwise stdlib+Ollama-only stack. This pass found the actual fix: **Ollama itself already serves
embedding models over the same HTTP API this project already calls** — no new dependency at all.
https://ollama.com/blog/embedding-models lists `all-minilm` (23M params, smallest), `nomic-embed-text`
(137M), `mxbai-embed-large` (334M). For a general (not code/technical-text-specific — this gap is
explicitly flagged, no benchmark targeting short structured technical descriptions was found) quality
signal: `bge-small-en-v1.5` (33.4M, 384-dim) scores 62.17 avg/51.68 retrieval on MTEB, ahead of
`gte-small` (61.36/49.46) and `e5-small-v2` (59.93/49.04) at the same size tier
(https://huggingface.co/BAAI/bge-small-en-v1.5) — `all-minilm`/`nomic-embed-text` are the ones
actually servable through this project's existing Ollama endpoint with zero new install, closing round
1's open risk.

**Skill-library GC/lifecycle beyond insertion-time dedup — new since round 1's SkillBrew/SkillOps
citation, which only covered insertion.**
- **"Skill Drift Is Contract Violation"** (arXiv 2605.10990) frames skill degradation as a *contract
  violation* and gives automated (high-precision, per the abstract) detection of when a skill's
  external dependencies make it obsolete/non-functional — the first hit found that treats "does this
  skill still work" as an ongoing check, not a one-time insertion gate.
- **"You Don't Need to Stay in the Loop"** (arXiv 2608.07555) — a robot-policy skill library that is
  version-tagged by commit key and **explicitly expires entries when underlying tools change.**
- **SkillZip** (arXiv 2608.05604) — "contract-preserving graph compression" of a skill library that
  preserves dependency closure across versions during compression, an explicit versioning-aware GC
  mechanism.
- **ContinualSkillBench** (arXiv 2608.03874) — a benchmark specifically asking whether an agent's
  accumulated skill library genuinely consolidates transferable skills over time, versus merely
  overfitting to whatever context it was built in.
- No paper found using explicit "usage-frequency/LRU pruning" language for LLM skill libraries —
  flagged as a genuine gap, not found this pass.

---

## (d) Multi-agent builder patterns: evidence for and against, on spatial tasks specifically

**Already covered, not repeated:** COPE (2506.11578), Aider architect/editor, decomposition helping
small models more (2602.04853), "Architecting Resilient LLM Agents" (2509.08646), VeriGuard
(2510.05156).

**Planner/critic/executor three-role split on spatial/layout tasks specifically.** A dedicated arXiv
query for `planner AND critic AND executor AND layout` returned **zero results** — no paper found
combining all three named roles specifically for a layout/CAD/spatial-construction task. The closest
real instance is CADSmith's (thread a) nested correction loop combining a deterministic geometry
measurement with a VLM assessment — structurally a critic role, but the paper doesn't use
planner/critic/executor terminology and reports no ablation isolating the critic's contribution.

**Multi-agent debate on spatial reasoning specifically.**
- **DART** (arXiv 2512.07132) — uses multi-agent *disagreement* to recruit visual tools for
  multimodal/spatial reasoning, reporting it "improves over multi-agent debate" by **+3.4pp on
  A-OKVQA, +2.4pp on MMMU** — i.e. disagreement-triggered tool recruitment beat plain debate, a useful
  negative-ish result about debate's own ceiling on spatial tasks.
- **Heterogeneous Agent Cohorts** (arXiv 2607.11226) — specialized roles + debate outperform a single
  approach in spatial-semantic environments; a Validator role "prevents all executed breaches" with a
  55.9% token-cost reduction under constraints — real evidence for a validator role specifically,
  though the setup is safety-constraint checking, not build-quality per se.

**Tool-use verification by a separate agent, on spatial/CAD tasks.** A dedicated query for
`critic/verifier agent + CAD/spatial` returned **zero results** — no dedicated paper found on a
separate LLM agent verifying another agent's spatial/CAD output via its own tool calls, distinct from
CADSmith's combined-metric loop above. Flagged plainly as unrecovered, not absent.

**Negative results / multi-agent overhead not worth it — directly relevant given this project already
uses a single-model plan-compile-lint-repair loop, not multi-agent.**
- **"Towards a Science of Scaling Agent Systems"** (arXiv 2512.08296) — 260 configurations tested;
  **"tool-heavy tasks appear to incur multi-agent overhead"** with coordination showing diminishing
  and sometimes strongly negative returns (**+80.8% to -70.0%** depending on task-role alignment). A
  blueprint-building task is exactly tool-heavy (compiler, lint, sim) in this framing.
- **Question-Guided Evidence Acquisition** (arXiv 2608.19739) — a single agent outperformed recent
  multi-agent document-QA systems; explicitly states "adding planners, routers, or multiple
  collaborating agents does not help" for that task class.
- **"Understanding Agent Scaling... via Diversity"** (arXiv 2602.03794) — homogeneous multi-agent
  setups show severe diminishing returns; **2 diverse agents matched or exceeded 16 homogeneous
  agents** — if multi-agent is ever added here, role diversity (planner vs. critic vs. executor doing
  genuinely different things) matters far more than agent count.

**Net read for this project:** the evidence for multi-agent gains is real but role-specific and
task-dependent (validator roles, disagreement-triggered tool recruitment); the evidence against blanket
multi-agent overhead on tool-heavy tasks is at least as strong, and no paper was found showing a
critic/verifier LLM role beating a deterministic compiler+lint pass on a spatial/construction task
specifically — this project's existing architecture (single small model + deterministic
compiler/lint/sim as the "critic") is not shown to be missing anything a second LLM role would fix.

---

## (e) Evaluation: benchmarks, metrics, golden-task design for a physics sandbox

**Already covered, not repeated:** pass@k Beta-Binomial framework (2510.04265), runloop.ai pass@k
blog, pass^k formula (leehanchung.github.io), Langfuse golden-dataset guide and regression-CI
companion, RTAMT/STL robustness scoring (2005.11827, STeP 2607.18580), Hypothesis
`RuleBasedStateMachine`, ChekProp (2505.23549).

**Named generative-building benchmarks with functional (not just visual) metrics.**
- **MineAnyBuild** (2505.20148, thread a) — the strongest match: scores spatial understanding,
  reasoning, creativity, *and* commonsense as four separate dimensions rather than one aggregate score
  — directly transferable as a **coverage-matrix template**: this project's own playbook levels could
  be scored/tagged along analogous axes (does a golden task exercise thermal control? structural
  integrity? logic/signal routing? containment?) rather than only "difficulty level N."
- **Luban** (2405.15414, thread a) — "two-level autonomous embodied verification": a visual check plus
  a **pragmatic/functional** check. This project's own architecture already effectively does the
  Luban-style split (structural = compile+lint, pragmatic = post-build census/verify condition) — the
  new information is that this split is itself a named, validated pattern in the literature, not an ad
  hoc choice.
- **GROOT's "Minecraft SkillForge"** (2310.08235) uses **Elo ratings** rather than pass/fail for
  open-ended creative tasks — worth considering for this project's harder-to-grade "creativity"-shaped
  playbook practices (if any exist) versus its functional/thermal ones, which are better served by a
  hard pass/fail band.
- **CADTests** (2605.07807) frames evaluation itself as **executable tests verifying geometric/
  topological requirements** — i.e. the golden task's "expected output" is itself compiled/run code,
  not a static value — matching this project's own compile+lint+census verify pattern already.
- **Text2CAD-Bench** (2605.18430) — 600 examples across **4 explicit complexity tiers** — a concrete
  precedent for how many goldens-per-difficulty-tier a mature benchmark actually uses, useful context
  for sizing this project's own golden set as it grows past its current 2 items.

**Curriculum-coverage design methodology.** No dedicated "coverage matrix design methodology" paper
was found distinct from what MineAnyBuild and Text2CAD-Bench already demonstrate by example (score/
bucket along named skill dimensions, not only a difficulty scalar) — treat those two as the working
precedent rather than expecting a separate methodology paper.

**Physics-sandbox / cellular-automaton golden-task design specifically.** No dedicated paper found on
"how many trials/seeds per golden task in a physics-sim benchmark" beyond what round 1-2 already
covered (RTAMT/STeP's robustness-margin framing, Eureka's population-based evaluation). This remains a
genuine gap in the literature for this exact task shape (cellular-automaton physics, not continuous
robotics/RL) — the closest transferable numeric precedent is still Text2CAD-Bench's tiered-complexity
sizing above, applied by analogy rather than found directly for a CA sandbox.

---

## Prioritised improvements (round 3)

Ordered by (evidence strength x leverage) / effort, each naming the exact file/function it touches.
Builds on rounds 1-2's already-implemented items (schema decoding, 2-round cap, localized repair,
attempt logging, pass@k harness) — does not repeat them.

1. **Serve module-registry embeddings through Ollama's own `/api/embeddings` endpoint (`all-minilm` or
   `nomic-embed-text`) instead of treating embedding-based dedup as blocked on a new dependency.**
   *Component: new small helper in `powder_ext/blueprint_tools.py` (or a new `embed_tools.py`) calling
   `POST {endpoint}/api/embeddings`, reusing the exact HTTP pattern `scripts/blueprint_agent.py:71-87`
   already uses for chat.* *Effort: small.* *Gain: high* — this directly resolves round 1's own
   flagged open risk ("adding a sentence-embedding dependency... a real new moving part") by showing
   there is no new dependency: the project's existing Ollama runtime already serves `all-minilm`
   (23M params). This unblocks round 1 item 6 (module dedup) and round 1/2's item 11
   (failure-cluster curriculum), both of which were stalled specifically on this "needs an embedding
   model" caveat.

2. **Retrieval-shortlist the module list in `blueprint_agent.py`'s system prompt instead of dumping all
   76 modules into every call.** *Component: `scripts/blueprint_agent.py` `system_prompt()`
   (`scripts/blueprint_agent.py:37-43`, currently `"\n".join(... for n, i in schema["modules"].items())`
   over the full registry).* *Effort: medium* (needs item 1's embedding call, or a cheaper keyword/
   TF-IDF fallback if embeddings aren't wired up yet). *Gain: high* — TinyAgent (arXiv 2409.00608) is
   direct, on-point evidence at exactly this project's model-size range (1.1B and 7B) that a
   retrieval-shortlisted tool list **both improves accuracy and roughly halves prompt tokens** versus a
   full list, and this project's registry has grown 62% (47->76 modules) since round 1 with the prompt
   construction unchanged — this is the single most on-point piece of new evidence this pass found.

3. **Decompose `record_attempt`'s verdict from a single `pass|fail|partial` enum into a small
   verifiable-reward vector, and log `temperature`/`round_no`/`resample_no` per sample.** *Component:
   `powder_ext/agent_tools.py` `record_attempt()` (`powder_ext/agent_tools.py:179-201`, currently
   `rec = {..., "verdict": verdict, ...}` with no score breakdown or sampling metadata) — callers in
   `scripts/blueprint_agent.py` `build_and_log()` and `scripts/passk_harness.py:48-50`.* *Effort:
   small.* *Gain: high* — directly answers the task's own question ("what does attempts.jsonl need to
   contain to be usable"): VeriGate (2605.30451) shows single-bit verdicts produce degenerate
   all-same-score GRPO groups with zero learning signal; Unsloth's GRPO guide independently recommends
   "a list of smaller verifiable rewards, not one all-consuming reward." This is cheap now and, per
   round 1's own open-risk note, expensive to reconstruct retroactively if fine-tuning is attempted
   later without it.

4. **Add structural-signature dedup to `passk_harness.py` before logging k samples, instead of logging
   every sample verbatim.** *Component: `scripts/passk_harness.py` (the `for i in range(args.k):` loop,
   `scripts/passk_harness.py:43-51`, which currently calls `record_attempt` on every one of k samples
   with no dedup).* *Effort: small-medium.* *Gain: medium-high* — the RFT paper (arXiv 2308.01825)
   explicitly dedups by structural signature (not keep-first/keep-best) specifically to avoid
   overrepresenting whatever the model converges on first; this project's harness currently does the
   opposite (keeps everything), which will bias any future SFT/DPO set built from `attempts.jsonl`
   toward whichever module/param combination the model happens to reach most often, not the most
   diverse set of correct solutions.

5. **Add a deterministic executability/precondition pre-filter before offering a module to the model,**
   modeled on the Wix Helpmate pipeline (arXiv 2608.01050: semantic match -> executability gate against
   live state -> LLM selection). *Component: `powder_ext/agent_tools.py` `world_state()`/
   `blueprint_grammar()` (`powder_ext/agent_tools.py:135-158`, `:316-336`) — cross-reference each
   module's stated preconditions (if any exist in `knowledge/modules/*.json`) against the current
   census before including it in the prompt.* *Effort: medium.* *Gain: medium-high* — the cited
   real-world deployment found the model would otherwise pick a blocked/non-executable option **7.8%
   of the time** with no gate; this is a distinct, complementary filter to item 2's similarity-based
   retrieval (this gates on *feasibility given current state*, not semantic relevance to the request).

6. **Treat compiler/lint changes as a module-registry staleness event, not a silent no-op.**
   *Component: `knowledge/modules/*.json` (add a `verified_against` compiler/lint version stamp) +
   whatever script currently edits `powder_ext/blueprint_tools.py`'s compiler or lint rules (no such
   check exists today).* *Effort: small-medium.* *Gain: medium* — new this pass, distinct from round
   1's insertion-time dedup gate: "Skill Drift Is Contract Violation" (2605.10990) and "You Don't Need
   to Stay in the Loop" (2608.07555) both treat *ongoing* re-verification after the environment/tooling
   changes as a separate problem from insertion-time dedup, one this project's 76-module registry has
   no mechanism for at all today.

7. **Use `passk_harness.py`'s existing best-of-N sampling as the tree-search proxy before investing in
   real MCTS over module-call plans; revisit MCTS only if best-of-N plateaus.** *Component:
   `scripts/passk_harness.py` (already built) as the interim solution; a hypothetical future
   `scripts/plan_search.py` modeled on CEDAR's LLM-parameterized MCTS (arXiv 2608.06871) if and when
   needed.* *Effort: none now / medium-large later.* *Gain: medium* — CEDAR is the first paper found
   that frames MCTS-over-executable-designs cleanly, but neither it nor GATS (2607.08894) publish
   tree-width/rollout-budget numbers transferable to this project's scale, and GATS's own motivation
   (eliminate per-rollout LLM calls via a learned world model) is a real engineering cost this project
   would have to pay standalone. The existing pass@k harness already gives "best of N" for free —
   don't build tree search until that specifically is shown to plateau.

8. **Grow the golden set (currently 2 items in `knowledge/golden/`) using a named-dimension coverage
   matrix, not an unstructured difficulty ladder.** *Component: `knowledge/golden/*.json` + wherever
   goldens are chosen/added (currently manual/ad hoc per round 1-2).* *Effort: medium.* *Gain:
   medium-high* — MineAnyBuild's four-dimension scoring (spatial understanding/reasoning/creativity/
   commonsense) and Text2CAD-Bench's 4-tier sizing (600 examples/4 tiers) are both concrete,
   transferable precedents for "what does a well-covered golden set actually look like," which this
   project's 2-item set does not yet approximate; map this project's own thermal/structural/logic/
   containment concerns onto named dimensions the same way, rather than adding goldens one at a time
   with no coverage tracking.

9. **Do not add a second LLM critic/verifier agent role, and do not pursue a debate-style multi-agent
   builder — explicitly deprioritized.** *Rationale:* thread (d)'s negative evidence (arXiv 2512.08296:
   tool-heavy tasks specifically incur multi-agent overhead, up to -70pp in some configurations; arXiv
   2608.19739: adding planners/routers/multiple agents "does not help" one comparable task class) is at
   least as strong as the positive evidence (validator-role gains in a safety-constraint setting, not a
   build-quality setting), and **no paper was found showing an LLM critic beating a deterministic
   compiler+lint pass on a spatial/construction task specifically** — which is exactly this project's
   existing architecture already. The one real precedent (CADSmith's nested correction loop) pairs a
   deterministic geometry check with a VLM check, not two LLM roles debating — if anything is added
   here later, it should be another deterministic tool-backed check (per item 5's precondition gate,
   or round 2's coarse-grid overlap pre-check), not a second model call.

10. **Do not chase RA-CAD's full Generate-Execute-Critique-Rewrite RL training pipeline (own reward
    model geometry, trajectory-level GRPO with F1+Chamfer-distance reward) as new infrastructure —
    explicitly deprioritized at this project's current scale.** *Rationale:* RA-CAD (arXiv 2608.05714)
    is a large training-infrastructure lift (a bespoke geometric reward function, RL training loop,
    likely multi-GPU) disproportionate to this project's current data volume (1 real `attempts.jsonl`
    entry as of this pass) and local-single-model deployment target. Its *shape* — generate, execute,
    critique, rewrite as one named loop — is already what `blueprint_agent.py`'s `solve()` does today
    (compile -> lint -> localized-feedback repair), just without RL training; treat RA-CAD as
    confirmation the existing loop shape is directionally correct, not as a new system to build. GRPO
    itself (item 3's logging groundwork) remains worth preparing for once real attempt volume exists;
    a bespoke Chamfer-distance-style geometric reward specific to CAD meshes does not transfer to this
    project's cellular-automaton domain and should not be ported.

---

## Open risks / caveats

- **The `WebSearch` session-budget exhaustion (200/200, hit instantly) is a hard platform limit, not
  a research-quality problem** — every finding above came from `WebFetch` against arXiv's public API
  and a handful of directly-known pages; non-arXiv sources (blog posts, GitHub discussions, 2026
  practitioner writeups outside arXiv) are correspondingly thinner than in rounds 1-2. If a future pass
  has `WebSearch` available again, re-run threads (b)'s "canonical training-example schema" question
  and (e)'s "physics-sandbox golden-task trial-count" question specifically — both were flagged as
  gaps that may only be answered outside arXiv (practitioner blogs, RL-benchmark engineering writeups).
- **CEDAR and GATS (the two MCTS-over-executable-plans findings) were only read at abstract depth** —
  neither's tree-width/rollout-budget/success-delta numbers were recoverable via `WebFetch` on the
  arXiv abstract page; a full-text read is needed before treating item 7 as more than a directional
  pointer.
- **The embedding-model comparison in (c) is general-purpose MTEB, not code/technical-description-
  specific** — no benchmark was found scoring `all-minilm`/`nomic-embed-text`/`bge-small` specifically
  on short structured module-description-and-precondition text; item 1/2's actual quality (not just
  feasibility) should be spot-checked empirically once wired up, not assumed from general MTEB rank.
- **RL-Struct's (arXiv 2512.00319) withdrawn numbers are a reminder to verify any single striking GRPO
  result against author retractions before citing it further** — flagged explicitly in section (b),
  repeating here because it's the kind of thing easy to miss on a second pass through saved notes.
- **The multi-agent "deprioritize" call in item 9 is a net read across mixed evidence, not a unanimous
  finding** — role-diverse setups (validator roles, disagreement-triggered tool recruitment) do show
  real gains in some spatial-adjacent settings; the call is that no evidence found beats this project's
  specific existing deterministic-compiler-as-critic architecture, not that multi-agent designs are
  never useful anywhere.
