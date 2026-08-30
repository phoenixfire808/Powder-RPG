# Companion state audit: spawn-reset + new-world cleanup (round 21, 2026-08-30)

**Track:** roadmap (audit only — no implementation per lane boundaries)
**Files audited:** `rpg.lua` (R.spawnPlayer at 871-887, R.generateWorld at 797-841), `rpg_plugins/companion.lua` (full, 989 lines), `rpg_plugins/survival.lua` (R.spawnPlayer wrap at 106-114)
**Context:** v1.15.4 fixed respawn-state pollutes (R.o2, R.gas, R.need.food/water, R.hurt, R.bloodLast, R.uvAccum, R.radAccum, R.hp=100). Question for this round: was R.COMP (the colonist) audited the same way? **Answer: no — several real state-pollution paths remain.**
**Note on naming:** no `npc.lua` exists; companion.lua IS the NPC plugin. This doc audits it as the canonical NPC state surface.

---

## Findings

### Finding 1 — R.spawnPlayer() does not reset ANY companion state

`R.COMP` (companion.lua:29-47) has 18 fields. **0 are reset** by R.spawnPlayer (rpg.lua:871-887).

**Repro chain:**
1. Player descends, dies to lava at y=-200 (line 1304: `R.hp <= 0 → R.spawnPlayer()`).
2. Colonist was at (-50, -180), alive, `action="fight"` (targeting magma worm).
3. R.spawnPlayer teleports R.P to (0, surfaceAt(0)-1). R.COMP unchanged: C.x/y still (-50, -180), C.dead=false, C.action="fight".
4. Next tick: `checkTeleportHome` only fires if `dx²+dy² > 600²` (line 825). Distance ~200-400px → does NOT fire.
5. `checkSelfDefense` finds no enemies in new neighborhood, no override.
6. `scriptedBrainTick` only preempts if `idleOrFollowing(C.action)` — but C.action is still "fight", status "running", so brain does NOT preempt.
7. STEP.fight runs (line 421-436): navigateTo old target (out-of-range, stuck), `R.damageEnemiesAt` finds no enemy → no progress.
8. **Colonist stranded underground, attempting to fight something invisible.**

**Severity: HIGH.** Companion is functionally broken until next newworld or until player physically returns to range. v1.15.4 explicitly called out this bug class (line 204) but companion state wasn't on the patch list.

**Accidental mitigation:** if colonist was `C.dead` at spawn, tick returns early (line 870-872) until REVIVE_DELAY=300 (~5s), then `reviveNear` teleports (line 856-861). Rare — colonist is usually alive when player dies.

**Recommendation:** add `C.x, C.y = R.P.x - face*12, R.P.y` to R.spawnPlayer's reset block, gated `if C.active and not C.dead`. **DEFERRED** to @bugs/@feature.

---

### Finding 2 — R.companionKill() does NOT clear C.queue

companion.lua:721-726 clears `C.action` and `C.override` but NOT `C.queue`. On revive (line 856-861), C.action is reset to `follow` but C.queue stays populated.

**Verdict: LOW. Real but minor.** Lost-chain behavior: a `enqueueChain` queued before death replays step-by-step after revive. Each queue item is re-invoked fresh (line 891), so it works correctly — just surprising that death doesn't fully cancel in-progress work. Compare with chain-fail (line 893) which DOES clear.

**Severity: LOW.** Functionally correct, just unexpected. The `from` field is also preserved, so a "scripted" chain re-runs after death-revive, which may not match player intent.

**Recommendation:** add `C.queue = {}` to R.companionKill. **DEFERRED** to @bugs.

---

### Finding 3 — Companion newworld hook misses 9 of 18 fields

`R.hooks.newworld` (companion.lua:906-910) resets 9 fields. Of 18 R.COMP fields, **9 are NOT reset**:

| Field | Risk on newworld |
|---|---|
| x, y, vx, vy, onGround, coyote, face, anim | **GHOST FRAME** — drawCompanion runs at OLD (x,y) for one frame between hook firing and next tick's `needsPlace` reposition. Same for tick's stepPhysics on that first frame. |
| name | Fine — always "Aster". |
| sayMsg, sayAt | Bubble from previous world could render for up to 150 frames (5s) if sayAt is recent. |
| hurtAt | Flash red for up to 12 frames. Cosmetic. |
| lastMineHelpAt, lastAutoGiveAt | Rate-limit timers. **Important:** rpg.lua:826 says "never rewind R.frame" → R.frame stays at old high value → these stale timers never expire before reuse. |
| lastHeartbeat | Driver watchdog. If driver died before newworld, mode resets to "auto" but `R.frame - lastHeartbeat > MODEL_TIMEOUT=600` almost certainly → checkModelWatchdog (line 848-853) flips back to "auto" on first tick. **Self-healing, but racy.** |
| index | Self-healing — `refreshIndex` overwrites every 240 frames (line 609). |

**Severity:** LOW overall (mostly cosmetic / self-healing). Two real issues:
- **Ghost frame on (x,y)** — single 16ms visual artifact.
- **chatQueue carry-over** — real cross-world message leak.

**chatQueue leak repro:**
1. Driver in mode="model", player types "follow me" but model takes 8s to respond.
2. Before model responds, player picks "New Seed" from Esc menu.
3. R.generateWorld fires. R.hooks.newworld runs. chatQueue NOT cleared.
4. Model responds with old-world's JSON plan, calls R.companionCmd("follow", {}) — works in new world, colonist follows.

**Recommendation:** add `C.x=0; C.y=0; C.vx=0; C.vy=0; C.chatQueue={}; C.sayMsg=nil; C.sayAt=nil` to newworld hook. **DEFERRED** to @bugs.

---

### Finding 4 — newworld resets mode="auto" but ignores lastHeartbeat

R.frame never rewinds (rpg.lua:826). If driver was in `mode="model"` and went silent, newworld resets mode to "auto" but doesn't reset lastHeartbeat. R.frame - lastHeartbeat > 600 is almost certainly true → checkModelWatchdog flips to "auto" on first tick (redundant but harmless).

**Reverse case:** if driver is live and healthy at newworld, mode gets reset to "auto", breaking the integration. Driver doesn't know the world was regenerated; it would still call R.companionCmd but mode is now "auto". Commands still work through C.cmd, but scriptedBrainTick might preempt.

**Verdict: NOTED, NOT A BUG.** Lifecycle question: should mode persist across newworld? Current code chooses "always reset to auto" — safe default. Driver should re-assert mode="model" after each newworld.

**Recommendation:** document this expectation in design-companion-protocol.md. **DEFERRED** to @roadmap doc-only lane.

---

### Finding 5 — survival.lua bed-respawn wrap bypasses core's pollution reset

survival.lua:106-114: when `R.bedRespawn` is set, the wrap teleports player to bed and **does not call coreSpawn**. v1.15.4's pollution reset (R.o2, R.gas, R.need.food/water, R.hurt, R.bloodLast, R.uvAccum, R.radAccum, R.hp=100) does NOT fire on bed-respawn. Same bug class as v1.15.4 just fixed, but persists in the bed-respawn path.

**Severity: MEDIUM.** Not companion-specific, but compound: companion ALSO gets no state reset on bed-respawn (Finding 1's reset would need to happen here too).

**Recommendation:** survival.lua's bed wrap should call coreSpawn() first or extract reset into a shared helper. **DEFERRED** to @bugs.

---

### Finding 6 — Death-loop potential via queue retention

Sequence: player issues "build me a house" → colonist queues `enqueueChain{{placeBlock x12}, {light}}` → mid-placeBlock, colonist dies → C.queue retains {light} step → REVIVE_DELAY → reviveNear → C.action=follow (never completes) → {light} never fires (chain only advances on action completion).

**Verdict: NOT A LOOP.** Just a lost chain — current behavior is acceptable.

**Recommendation:** none. **REJECTED.**

---

## Recommendations summary (shipped/deferred/rejected)

| # | Finding | Severity | Action | Status |
|---|---|---|---|---|
| 1 | R.spawnPlayer leaves companion stranded | HIGH | Add C.x, C.y reset gated by `C.active and not C.dead` | **DEFERRED** to @bugs/@feature |
| 2 | R.companionKill doesn't clear C.queue | LOW | Add `C.queue = {}` | **DEFERRED** to @bugs |
| 3 | newworld hook misses 9 fields | LOW | Add C.x/y/vx/vy/chatQueue/sayMsg/sayAt to newworld | **DEFERRED** to @bugs |
| 4 | newworld resets mode="auto" | LOW | Doc-only note in design-companion-protocol.md | **DEFERRED** to @roadmap |
| 5 | survival bed-respawn bypasses pollution reset | MEDIUM | Bed wrap should call coreSpawn() first | **DEFERRED** to @bugs |
| 6 | Death-loop via queue retention | LOW | None — current behavior OK | **REJECTED** |

**Nothing shipped this round.** Audit + recommendations only per lane boundaries.

---

## Decision: do we do anything now?

**No new checker is needed.** This is a domain-judgment problem ("is X per-world-session state or persistent account state?") — same shape flagged in TODO round-16: "a checker here would just be a manually-curated list pretending to be automated." Existing checkers (check_terrain_solid, check_station_reachable, check_physics_constant_dup, check_lua_forward_ref) cover mechanical invariants; "should R.COMP survive R.spawnPlayer" needs per-field human judgment.

**Future-checker possibility (REJECTED):** static check that flags R.XYZ fields not mentioned in any of R.hooks.newworld / R.spawnPlayer / R.companionKill reset paths. Buildable (regex over `R\.XXX = ` assignments vs reset-hook bodies), but false-positive rate would be high — many fields are MEANT to persist (R.frame, R.worldEverGenerated). Not worth maintenance vs. periodic hand-audit (what this round did).

**Real priority:** F1 (companion stranded on respawn) and F5 (bed-respawn pollution) are the two real bugs worth @bugs' attention. F2/F3 nice-to-haves. F4 doc-only.

---

## Verification

- Read companion.lua end-to-end (4 reads, 989 lines).
- Read rpg.lua:797-841 (generateWorld) + 871-887 (spawnPlayer) + 1304 (death→spawnPlayer) + 2044-2050 (manual respawn + Magic Mirror) + 2439/2790 (draw-before-tick ordering) + 826 (R.frame never rewinds).
- Read survival.lua:97-114 (eat wrap + spawnPlayer wrap).
- Existing checker coverage confirmed: `grep "spawn\|generateWorld\|R.COMP\|R.hook" scripts/check_*.py` → no matches → no existing checker covers this.
- Confirmed companion.lua is the only NPC plugin (no npc.lua file).