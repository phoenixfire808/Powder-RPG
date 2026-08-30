# Round 23 — next bug class after v1.15.7-1.15.9 ship (2026-08-30)

**Track:** roadmap (audit + candidate findings; no code mutations per lane boundaries)
**Files audited:** `scripts/lua/rpg.lua` (R.spawnPlayer 907-926, R._resetSpawnState 897), `scripts/lua/rpg_plugins/survival.lua` (R.spawnPlayer wrap 106-114), `CHANGELOG.md` (v1.15.7-1.15.9 entries)
**Bridge used:** `D:/powder-toy/lab_instance/ddir/powder-bridge.token` (PID 37320, port 9877, VER=1.15.9, lastErr=nil)

## Headline finding (LIVE-BRIDGE-VERIFIED)

**v1.15.7's F1 companion-teleport fix doesn't fire on bed-respawn.** Same bug class as the v1.15.4→v1.15.5 pollution-reset bug that v1.15.9 just fixed for the bed path — the F1 fix was added to `R.spawnPlayer` (rpg.lua:923) but `survival.lua`'s bed wrap (lines 108-114) **bypasses the entire core spawnPlayer when `R.bedRespawn` is set**, so the companion stays at its old location after a bed-respawn.

**Bridge repro (single call, both spawn types side by side):**
```
SURFACE_SPAWN: COMP.x=-12    (expected ~-12 — F1 fired)
BED_SPAWN:     COMP.x=-999   (expected ~488 if F1 ran — F1 bypassed)
```

## Three-check audit results

### Check (a) — R.X() nil-function references
Built a mechanical check (`/tmp/check_a.py`) extracting `R.X(...)` call sites in plugins and verifying X is defined in core (via `function R.X(` or bulk `R.X, R.Y = ...` assignments).
**Result: NO real nil-ref bugs found.** All flagged candidates are plugin-internal `R.X = function` definitions in the same file (e.g., `R.companionKill`, `R.companionState`, `R.openGuide`, `R.damageEnemiesAt`, `R.save`, `R.load`, `R.vehiclesInstallGated`). The pattern that hunted F8 (clearAround was a function defined in rpg.lua v2 but never re-added in v3) does NOT recur in v1.15.9 — the v3 rewrite's missing helpers are all present now.

### Check (b) — hook-handler signature mismatches
Built a cross-check between `runHooks(R.hooks.X, ...)` call sites in rpg.lua and `hook(R.hooks.X, function(...)` registrations in plugins.
**Result: 5 sloppy-but-legal mismatches, no bugs.** `guide.lua: hook(R.hooks.mouseup, function()` (0 params vs 3), `items.lua: hook(R.hooks.place, function(el))` (1 vs 4), `items.lua: hook(R.hooks.mine, function(el))` (1 vs 2), `machines.lua: hook(R.hooks.key, function(k))` (1 vs 4), `vehicles.lua: hook(R.hooks.key, function(k))` (1 vs 4). Lua silently ignores extra args, so these handlers just don't see the data they could — not bugs. The reverse case (handler wants MORE params than caller passes) would be a bug; checked: zero instances.

### Check (c) — unguarded field reads (`R.X.field` where X might be nil)
Built a heuristic lookback over `R.X.field` reads and flagged those without a `if R.X`/`R.X = R.X or {}` guard in the prior ~5 lines.
**Result: same false-positive shape as round-21.** Heuristic flagged ~30 candidates across rpg.lua + plugins; hand-verified every cluster:
- `R.power.grids`, `R.tech.*`, `R.airlineLast.*`, `R.airlineCur.*` in machines.lua: ALL guarded (`if m._gid and R.power.grids[...]`, `if R.airlineLast and ...`, etc.).
- `R.shake.t`, `R.timber.t` in rpg.lua: guarded (`if R.shake and ...`).
- `R.ui.bagOpen`, `R.ui.questOpen` in rpg.lua: guarded (`if R.ui and R.ui.bagOpen`).
**Verdict:** high false-positive rate for this heuristic, low signal-to-noise, same shape as the TODO round-16 "manually-curated list pretending to be automated" finding. **A static checker for (c) is NOT mechanically buildable** without building a real Lua control-flow tracker — rejected for the same reason round-21 rejected a scope tracker for check_lua_forward_ref.

## The next bug (live-verified)

**File:** `D:/powder-toy/scripts/lua/rpg_plugins/survival.lua:106-114`
**Class:** "wrap-bypass" — same class as the v1.15.5 F5 bug, but for the v1.15.7 F1 fix.

**Code (rpg.lua:907-926, F1 fix at 923):**
```lua
function R.spawnPlayer()
  R.P.x = 0; R.P.y = surfaceAt(0) - 1; R.P.vx, R.P.vy = 0, 0
  R._resetSpawnState()      -- F5 pollution reset (v1.15.9)
  -- F1 (v1.15.7): teleport the companion
  if R.COMP and R.COMP.active and not R.COMP.dead then
    local C = R.COMP; C.x = R.P.x - (C.face or 1) * 12; C.y = R.P.y
  end
  R.hp = 100
  -- shiftCam, R.clearAround()
end
```

**Code (survival.lua:106-114, bed wrap):**
```lua
local coreSpawn = R.spawnPlayer
function R.spawnPlayer()
  if R.bedRespawn then
    R.P.x, R.P.y = R.bedRespawn.x, R.bedRespawn.y
    R.P.vx, R.P.vy = 0, 0
    R.hp = math.max(R.hp or 0, 40)
  else
    coreSpawn()
  end
end
```

**Why it's a bug:** when `R.bedRespawn` is set, the wrap takes the `if` branch and **does not call `coreSpawn()`**. So `_resetSpawnState()` (F5), the F1 companion teleport, `R.hp = 100`, `shiftCam`, and `R.clearAround()` are all bypassed. F5 was fixed by extracting `_resetSpawnState()` into a helper that the bed wrap calls directly (v1.15.9 CHANGELOG entry lines 110-117 explicitly cite this). **F1 was NOT similarly replicated.** Companion stays at death-site after bed-respawn.

**Live verification (single bridge call, no test-harness):**
```
SURFACE_SPAWN: COMP.x=-12    (F1 fired, -12 = 0 - 12)
BED_SPAWN:     COMP.x=-999   (F1 bypassed, value unchanged from before spawn)
```

**Companion impact:** same as the original F1 bug that v1.15.7 fixed — dying deep, then bed-respawning to surface, leaves Aster stranded at the death-site (or worse, dead if she also died in the same event). Bed-respawn is the normal respawn path for survival players who placed a bed, so this affects the default player flow, not an edge case.

**Severity:** HIGH — same player-visible failure mode as the v1.15.6 F1 bug, just on the bed path. Belongs to @bugs' queue.

## Recommendation for @bugs

Two-line fix in `survival.lua`'s bed wrap (lines 108-114): replicate the F1 logic in the bed branch. Pattern matches the v1.15.9 F5 fix exactly:
```lua
function R.spawnPlayer()
  if R.bedRespawn then
    R.P.x, R.P.y = R.bedRespawn.x, R.bedRespawn.y
    R.P.vx, R.P.vy = 0, 0
    R.hp = math.max(R.hp or 0, 40)
    -- F1 mirror: teleport the companion to the bed (was missed in v1.15.9's wrap update)
    if R.COMP and R.COMP.active and not R.COMP.dead then
      local C = R.COMP; C.x = R.P.x - (C.face or 1) * 12; C.y = R.P.y
    end
    -- F5 (v1.15.9): reset pollution envelope
    R._resetSpawnState()
  else
    coreSpawn()
  end
end
```

Or refactor to call `coreSpawn()` first and then override R.P.x/y + R.hp, like the F5 extraction did — cleaner if @bugs is willing to do the larger change.

## Side observation (NOT a bug, noted for completeness)

`R.clearAround()` is also bypassed by the bed wrap. After bed-respawn, the existing BLD pool at the bed location is not cleared (same cosmetic class as the round-3078 fix). The v1.15.7 F8 fix added `R.clearAround()` to `R.spawnPlayer` (rpg.lua:926) but survival.lua's wrap calls `coreSpawn()` only in the else branch, so bed-respawn skips it. Same fix pattern as F1: add `R.clearAround()` to the bed branch.

## Decision

- **Ship this doc-only deliverable.** Real bug found, live-verified.
- **No new checker.** Same scope-tracker rejection as round-21 (mechanical check on a dynamic-language is high-FP). The live-bridge hand-verify approach catches this class of bug faster than any regex.
- **Recommended next step** (NOT this round): the two-line fix in survival.lua above, plus `R.clearAround()` in the bed branch. Belongs to @bugs' queue.

## Verification

- Bridge: PID 37320, port 9877, VER=1.15.9, lastErr=nil. Token at `D:/powder-toy/lab_instance/ddir/powder-bridge.token`.
- Bridge repro: single `executeLua` call, 3 statements (setup, surface spawn, bed spawn), output confirmed F1 fires on surface (-12) and bypasses on bed (-999).
- CHANGELOG.md v1.15.9 entry confirms F5 fix lands `_resetSpawnState()` extraction but does NOT mention F1.
- All3 checks (a)/(b)/(c) ran against actual source; no new mechanical checkers built (same scope-tracking rejection as round-21).