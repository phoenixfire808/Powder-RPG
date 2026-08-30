# Respawn-path-drift retrospective — v1.15.7 through v1.15.10 (2026-08-30)

**Track:** roadmap (round 24, doc-only)
**Files:** rpg.lua (R.spawnPlayer 923-936, R._resetSpawnState 900-905, R._teleportCompanionAndClear 915-918, R.clearAround 922, death 1353, R-key 2093, Magic Mirror 2099, Esc 2288), survival.lua (bed wrap 108-114)
**Bridge verified:** PID 37320, port 9877, VER=1.15.10, both helpers=function.

## 1. PATTERN — respawn paths and what each resets

Five call sites all flow through `R.spawnPlayer` (which may be survival.lua's wrap, which may route to core, which always calls both helpers).

| Path | Trigger | After v1.15.10 |
|---|---|---|
| Surface death | `R.hp <= 0` (rpg.lua:1353) | core body → both helpers → hp=100 |
| Manual R key | `k == "r"` (rpg.lua:2093) | no bed → coreSpawn → both helpers → hp=100 |
| Magic Mirror X | `k == "x" and mirror` (rpg.lua:2099) | coreSpawn → both helpers, BUT hp saved before / restored after |
| Bed respawn | `R.bedRespawn != nil` (survival.lua:108-114) | bed branch → R.P.x/y=bed → hp=max(current,40) → BOTH helpers |
| Esc menu respawn | "Respawn at surface (R)" (rpg.lua:2288) | same as manual R |

**Helper coverage (post-v1.15.10):**

| Helper | Surface | R key | Mirror | Bed | Esc |
|---|---|---|---|---|---|
| `R._resetSpawnState()` (pollution: o2/gas/need/hurt/bloodLast/uvAccum/radAccum) | YES | YES | YES | YES (F5) | YES |
| `R.hp = 100` | YES | YES | NO (preserved) | NO (max(current,40)) | YES |


## 2. BUGS — F1, F2, F3, F5, F8, F9

- **F2 (v1.15.8)** — `R.companionKill()` cleared `C.action`/`C.override` but NOT `C.queue`. Queued chain replayed step-by-step after revive. Fix: add `C.queue = {}` to R.companionKill.
- **F5 (v1.15.9)** + **F9 (v1.15.10)** — same drift pattern, two iterations. F5: survival.lua's bed-respawn wrap (added when beds shipped) took early-return on `if R.bedRespawn then ... else coreSpawn() end`, copying ONLY pollution-reset inline and missing companion-teleport + clearAround. F9: after F5, F1+F8 were STILL only in core spawnPlayer body; bed wrap called `_resetSpawnState` but bypassed companion teleport + clearAround. Both fixed by extraction: F5 → `R._resetSpawnState()` (rpg.lua:900-905); F9 → `R._teleportCompanionAndClear()` (rpg.lua:915-918). Bed wrap calls both at survival.lua:110.
- **F1 (v1.15.7)** + **F8 (v1.15.7)** — F1: `R.COMP.x/y` never reset on surface respawn; Aster stranded at death site. F8: `R.clearAround()` lost in v3 rewrite (commit 6c8d889). Both originally inline in core spawnPlayer; both now folded into `R._teleportCompanionAndClear()` (F1 at line 916, F8 at line 917). F1 gate: active+not-dead so REVIVE_DELAY path is unaffected.

**Pattern across F5 and F9:** each time new state was added to core spawnPlayer, the bed wrap had to be manually updated to match. F5 was missed initially (v1.15.4's inline pollution-reset wasn't replicated when bed wrap was added later). F9 happened because v1.15.7's F1+F8 went into core spawnPlayer body, not the bed wrap's `else coreSpawn()` branch. **Architectural fix in both cases: extract → call from both places.** Single source of truth.

## 3. ARCHITECTURE — the two helpers

```
R.spawnPlayer()                  rpg.lua:923-936
├── R.P.x = 0; R.P.y = surfaceAt(0) - 1   ← surface coords
├── R._resetSpawnState()          rpg.lua:900-905  [F5]
├── R._teleportCompanionAndClear() rpg.lua:915-918  [F9]
├── R.hp = 100
└── shiftCam

R.spawnPlayer() (wrapped)        survival.lua:108-114
├── if R.bedRespawn then
│   ├── R.P.x/y = bed coords
│   ├── R.hp = max(current, 40)   ← bed rule, NOT 100
│   ├── R._resetSpawnState()      ← same helper
│   └── R._teleportCompanionAndClear()  ← same helper
└── else coreSpawn()
```

**Why two, not one:**
- `R._resetSpawnState()` — purely data reset. Touches o2/gas/need/hurt/bloodLast/uvAccum/radAccum. No R.P dependency.
- `R._teleportCompanionAndClear()` — position-dependent. Reads R.P.x/y, teleports companion, calls R.clearAround(). Callers MUST set R.P first.

**What they DON'T cover (intentional gaps):**
- HP — `R.hp = 100` is NOT in any helper (per-path rules: surface=100, Mirror=preserve, bed=max(cur,40)).
- Inventory half-on-death (rpg.lua:1353) — fires from death handler BEFORE spawnPlayer, death-only. Stay in death handler.
- `R.deaths` increment — death-only, same place.

## 4. CHECKLIST — adding spawn-related state

**Step 1: Decide which helper (or neither).**
- Data-only reset, no R.P dependency → add to `R._resetSpawnState()`.
- Position-dependent (companion, spawn-area particles, anything reading R.P) → add to `R._teleportCompanionAndClear()`.
- HP-related with per-path rules → DON'T add to a helper. Put it in each caller with the rule documented inline.
- Death-only (inventory-halve, R.deaths, "you died" message) → DON'T add. Put in death handler at rpg.lua:1353.

**Step 2: If you added to a helper, no caller change needed.** Both helpers fire from both call sites (rpg.lua:932-933 + survival.lua:110). DO NOT add new state inline in either spawnPlayer body or bed wrap — that's the drift pattern.

**Step 3: New spawn path entirely (not just new state).** Each new path MUST call BOTH helpers (unless explicit reason not to, documented inline). Update the PATTERN matrix above.

**Step 4: Verification.** Bridge smoke: set test values, call each spawn path, assert reset. CHANGELOG entry should mention both helpers if state was added to either.

## Decision

- Doc IS the deliverable. No code changes, no new checker.
- Two-helper extraction is the right architectural answer. Both F5 and F9 fixed the same shape with the same shape of fix (extract → call from both). Next spawn-related bug, if any, follows this checklist.
- **No checker buildable** — coupling/maintenance discipline, not mechanical invariant. Closest a checker could get is "grep for `R.X = ...` inside spawnPlayer body, warn if not also in a helper" — noise-prone and misses the real failure mode (failing to call the helper, not failing to define state).

## Verification

- Read rpg.lua:900-936, 1353, 2093, 2099, 2288. Read survival.lua:108-114.
- Bridge live: PID 37320, port 9877, VER=1.15.10, both helpers=function, R.CHANGELOG[1].ver="1.15.10".