# Companion `mode` reset on new-world (round 22, 2026-08-30)

**Track:** roadmap (doc-only; closes F4 from round-21 audit)
**Inspected:** companion.lua (709, 782, 798-806, 848-853, 906-910), companion_driver.py (273, 311, 350), rpg.lua (830).

> **Discrepancy vs round-21 brief:** mode strings are exactly `auto | manual | model` (companion.lua:709 validates), **not** `"command"` or `"follow"` (those are STEP command names). `R.generateWorld` is one-shot menu-initiated, not per-tick. Doc below reflects actual code.

---

## 1. WHY — rationale for forcing `mode = "auto"` on new-world

`R.hooks.newworld` (companion.lua:906-910) unconditionally sets `C.mode = "auto"`. Three reasons `auto` is the safe default:

- **Auto is the only mode that runs reflexes.** `scriptedBrainTick` (line 798-806) is gated on `C.mode ~= "auto"` returning early. The reflex layer (`checkSelfDefense`, `checkTeleportHome`, `checkModelWatchdog`) all assume auto-mode scripted brain is in the loop.
- **New-world state is poisoned for prior drivers.** A driver mid-loop has stale state, stale plan, stale chatQueue. Forcing `auto` drops the driver out without it needing to notice the world changed.
- **Watchdog only flips `model → auto`, not `manual → auto`.** A `manual`-mode colonist on a new world with no one watching would be stuck silent forever (no watchdog reverts manual).

## 2. WHO IT BREAKS — real failure modes

**Live `companion_driver.py` mid-loop (real today).** Driver enters mode="model" on iteration 1 (line 311). Player picks "New Seed" → R.hooks.newworld fires (rpg.lua:830) → companion resets mode="auto". Two breakages:
- Chat-polling hook (line 782: `if C.mode == "model" then return end`) stops answering player chat until mode is re-asserted.
- `scriptedBrainTick` is now active; if the driver's last `R.companionEnqueue` issued a multi-step plan, scriptedBrainTick can preempt it with a `fight` reflex or default to `follow`. Plan silently dropped.

Driver recovers on next poll only if it explicitly re-asserts `mode="model"`. **Today the driver does not** — it sets mode only on entry (line 311) and exit (line 350), not per cycle. So a "New Seed" while driver is live leaves it broken until restart.

**Future chat-driven drivers, scripted cutscenes (mode="manual" sequences), test harnesses** — same shape, all would silently break. None built today; noted for completeness.

## 3. HOW TO OPT-OUT

Three real escape hatches, ordered by invasiveness:

### 3.1 Driver-side: re-assert mode every poll (RECOMMENDED, no rpg.lua/compaion.lua touch)

`R.companionSetMode("model")` is idempotent, ~free. Change companion_driver.py's main loop to call `set_mode(c, "model")` at the top of every iteration, not just on entry. One-line change. New-world reset is silently healed within one poll. Routes to whoever owns companion_driver.py next.

### 3.2 Plugin-side: wrap `R.hooks.newworld`

Register a second `hook(R.hooks.newworld, fn)` from a different plugin (companion.lua's tag-based de-dup at lines 23-26 means it won't collide). The second hook can re-assert `C.mode = "model"` if a `C._driverAssertsMode` flag is set. ~5-10 LOC in a new or existing plugin.

### 3.3 Different reset strategy (FUTURE, rejected)

Change newworld to: `if (R.frame - (C.lastHeartbeat or 0)) > MODEL_TIMEOUT then C.mode = "auto" end`. Self-heals for live drivers only IF `R.companionHeartbeat` is called every cycle (currently only on entry, line 315). Until 3.1 lands, this is no better than current behavior.

---

## Decision

- Ship the doc-only update. F4 closed.
- **No new checker.** Mode-reset policy is a deliberate design choice (auto is the safe default); flagging it as "missing" would be wrong.
- **Recommended next step** (not this round): 3.1 one-line driver change. Until that ships, every "New Seed" while driver is live requires restarting the driver.