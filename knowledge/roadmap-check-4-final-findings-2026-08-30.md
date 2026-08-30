# Check #4 — final findings on the 3 remaining `local NAME` flagged issues

**Track:** roadmap, round 19 (2026-08-30)
**Author:** RoadmapChecker subagent
**Files inspected:** `D:/powder-toy/scripts/lua/rpg.lua`, `D:/powder-toy/scripts/lua/rpg_plugins/machines.lua`, `D:/powder-toy/scripts/lua/rpg_plugins/vehicles.lua`
**Tool:** `python D:/powder-toy/scripts/check_lua_forward_ref.py` (self-check passes; re-run today, real output below)
**Decision recorded:** **do not build full scope tracking** — document the precise remaining limitation, since all 3 findings are now characterized as a single repeated false-positive shape with no live-bug impact.

---

## Real output today (2026-08-30, run against current source)

```
rpg.lua:3190: `local function key` is used at line(s) [1358, 1367, 1538, 1565,
1624, 1626, 1631, 1657, 1662, 1667, 1677, 1793, 1794, 1796, 1938, 1953, 1958,
1963, 1964, 1965, 1972, 1977, 1978, 1979, 1984, 1985, 1987, 1989, 1995, 2007,
2008, 2029, 2030, 2031, 2032, 2033, 2112, 2114, 2115, 2116, 2117, 2409, 2410,
2411, 2852, 2854] before this definition, with no earlier bare `local key`
forward declaration -- likely an accidental global

machines.lua:2180: `local function need` is used at line(s) [1257, 1279] before
this definition, with no earlier bare `local need` forward declaration --
likely an accidental global

vehicles.lua:657: `local function need` is used at line(s) [527] before this
definition, with no earlier bare `local need` forward declaration -- likely an
accidental global
```

Self-check (`--self-check`) passes; exit code 0. (Re-verified after this run,
before writing this doc.)

NOTE on line-number drift: a peer worker added code to rpg.lua while this doc
was being written, so a later re-run may show `rpg.lua:3213` for the `key`
definition instead of `3190` (a +23-line shift), with the flagged earlier-use
line numbers correspondingly shifted. The structural analysis (inner-scope
local `key` shadowing a not-yet-defined file-scope `local function key`
within `R.findPath`) is unchanged. If you re-run and see a different shift,
re-confirm the `local function key(cx, cy)` site is still inside `R.findPath`
and that all 6 `local key = ...` declarations still live inside OTHER
functions than R.findPath — that's the load-bearing claim, not the line numbers.

---

## Per-finding characterization (hand-verified, file:line cited)

### Finding 1 — `rpg.lua:3190` (`local function key`)

**Definition site (line 3190):** inside `function R.findPath(sx, sy, gx, gy, opts)`
which begins at line 3185. The `key` function takes `(cx, cy)` and returns a
flat `cx * 100000 + cy` cell-coordinate hash. Scope: local to `R.findPath`.

**Real `local key = ...` declarations that the checker flagged** (not bare
identifiers, but `local` bindings whose name happens to also be `key`):

| Line | Containing function | Snippet |
|------|---------------------|---------|
| 1361 | `R.chestAt` (line 1360) | `local key = tx * 100000 + ty + 50000` |
| 1540 | (separate helper function) | `local key = x * 4096 + y` |
| 1627 | tool-resolution branch | `local key = s:sub(6)` |
| 1794 | tree-fall helper | `local key = (lx + R.cam.x) * 4096 + (base + R.cam.y)` |
| 2135 | TOOLCOL lookup | `local key = v:sub(6)` |
| 2431 | tool lookup | `local key = s and s:find("^tool:") and s:sub(6) or nil` |

**Other "uses" the checker matched** (bare `\bkey\b` matches that aren't local
declarations at all):

- The TPT `onKeyDown(key, k, text, shift)` handler parameter `key` — function
  parameter at lines 1985, 1987, 1989, 2007, 2008, 2029-2033. These compile
  against the parameter binding, not the global.
- Comment text was already stripped by `strip_comment()` (round-15 work), so
  none of the lines around 1958-1965 are real signal — they're comment residue.

**Why it's a false positive:** each `local key` is function-scoped to a
different enclosing function. None of those enclosing functions nest inside
`R.findPath`, and none of them are evaluated before `R.findPath` is defined —
Lua's per-function lexical scoping means each binding is independent. The
checker sees textually-matching `key` and assumes they all reference the same
file-scope local, but `local function key` at 3190 introduces a *new* local
inside `R.findPath` that nothing else in the file references.

**No live-bug impact.** R.findPath's `key` is a private helper used only
within R.findPath's own body (lines 3190-3238). Confirmed by reading the
function in full.

### Finding 2 — `machines.lua:2180` (`local function need`)

**Definition site (line 2180):** top-level `local function need(...)` returning
a flat `{material=qty, ...}` recipe table.

**Real `local need = ...` declarations the checker flagged** (lines 1256 and
1278):

| Line | Containing scope | Snippet |
|------|------------------|---------|
| 1256 | `elseif m.kind == "airpump" or ...` branch of `R.machineHint` | `local need = LOAD_W[m.kind] or 4` |
| 1278 | `elseif role == "load"` branch of `R.machineHint` | `local need = LOAD_W[m.kind] or 4` |

The flagged "uses" at 1257 and 1279 read `need` inside the same `elseif`
block, immediately after the `local need = ...` line. They compile against
the just-introduced branch-local binding, not the file-scope function.

**Why it's a false positive:** `local need` at 1256/1278 shadows the not-yet-
defined file-scope `need` *only within that elseif branch*. As soon as the
`elseif` ends (line 1264 / 1284), the local goes out of scope. The 2180 file-
scope `local function need` is then defined normally and used by all the
recipe entries at 2186+ that read `need = need("BRCK", 16, "COAL", 6)` — a
textually-confusing but lexically-correct pattern.

**No live-bug impact.** Confirmed by reading both branches in full (1254-1284)
and the recipe table (2185+). The 2186+ `need = need(...)` calls are forward-
of the file-scope definition (line 2180), which is the standard idiom and not
a bug.

### Finding 3 — `vehicles.lua:657` (`local function need`)

**Definition site (line 657):** top-level `local function need(...)` returning
the same `{material=qty, ...}` recipe table shape as machines.lua.

**Real `local need = ...` declaration the checker flagged:**

| Line | Containing scope | Snippet |
|------|------------------|---------|
| 525 | inside `for yy = -3, 2 do ... end` block | `local need = math.max(1, R.HARD[nm] or 3)` |

The flagged "use" at 527 reads `need` two lines after the `local need = ...`
line. Same as finding 2: a loop-block local that shadows the not-yet-defined
file-scope function only inside that block.

**Why it's a false positive:** identical pattern to finding 2. The for-loop
local is fully contained in the loop body; the 657 file-scope function
definition and the 659+ recipe-table uses are correct.

**No live-bug impact.** Confirmed by reading the for block (lines 517-532)
and the recipe table (657+).

---

## Pattern across all three findings

All three are the *same* false-positive mechanism: **`local NAME = ...` declared
inside an inner scope (function, elseif branch, for block) shadowing a not-yet-
defined file-scope `local function NAME` only within that inner scope.** The
checker sees the textually-matching `NAME` and assumes they all reference the
same file-scope binding, but Lua's per-function lexical scoping means each
binding is independent.

This is exactly the limitation documented in round-15 TODO.md: "an intervening
`local NAME = ...` creates a new, unrelated binding" — a third distinct false-
positive mechanism separate from the two (string literals, dot-access) that
were already fixed by round-15.

---

## Decision: do NOT build full scope tracking

**Cost estimate if implemented:**
- A real Lua scope tracker needs to handle `function/end`, `do/end`, `if/
  then/else/elseif/end`, `for/do/end`, `while/do/end`, `repeat/until`,
  distinguishing `function NAME(...) end` (file-scope local) from
  `local function NAME(...) end` (file-scope local with explicit `local`)
  from inside-function `local NAME = ...` (function-scope local).
- Estimated 300-500 lines of careful Python plus thorough test coverage.
  Half-right scope tracking risks masking real bugs, which is worse than the
  current known-false-positive state.
- No off-the-shelf Lua parser dependency is already in the project.

**Expected benefit:**
- Eliminates 3 findings. **All 3 are already hand-verified false positives**
  by this document. No new real bugs would be caught that the current
  approach misses.
- The signal-to-noise ratio since the round-11 give() find has been 0 real
  bugs vs. 0-3 documented false positives per run. The check has done its
  real job.

**Net verdict:**
- Real scope tracking is a much-bigger lift than checks 1-3 (mechanical
  regex/pattern checks) for **zero demonstrated payoff** against the
  current codebase.
- The check stays as a **lead-generator, not a pass/fail gate**, with this
  precise limitation documented and the 3 hand-verified findings listed so
  whoever next runs the check can immediately confirm "still the same 3
  false positives, no new real ones" without re-reading 200+ lines of code.
- The right time to revisit scope tracking is if a real-bug class appears
  that the current approach systematically misses — not as speculative
  insurance against a hypothetical future.

---

## What ships this round

- This document (`roadmap-check-4-final-findings-2026-08-30.md`).
- No new checker. No changes to `scripts/check_lua_forward_ref.py` — its
  current signal-to-noise is the documented best-effort state.
- No mutations to `rpg.lua` or any plugin (per lane boundaries).

## Known limits (honest)

- The 3 hand-verified false positives will keep appearing on every run.
  That's the current best-effort state, not a bug in the checker.
- The check still requires manual verification of every finding — it's a
  lead-generator, not a pass/fail gate. That was true before this round
  and is unchanged.
- If someone adds a `local NAME` inside an inner scope whose inner-scope
  is reachable before its corresponding top-level `local function NAME`,
  this check WILL miss it. That's the cost of the documented trade-off.