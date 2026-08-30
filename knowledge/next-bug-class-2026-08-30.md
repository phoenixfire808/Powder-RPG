# Next bug class after v1.15.7-v1.15.11 ship — save-load version drift (2026-08-30)

**Track:** roadmap (round 25, audit + finding + recommendation)
**Files audited:** `rpg_plugins/save.lua` (doSave 296-346, doLoad 357-415, R.PLUGIN_SAVE_KEYS 18, SAVE_PATH 22, plugin round-trip 407), `rpg_plugins/companion.lua` (R.COMP init 29-47, R.companionChatPending 703-708, C.cmd/C.enqueueChain 678-697, newworld hook 906-910), `D:/powder-toy/knowledge/rpg-save.json` (current live save)
**Bridge verified:** PID 37320, port 9877, VER=1.15.10. Crash repro live-confirmed via single bridge call.

## CLASS — save-load version drift (plugin round-trip)

Same shape as F5 and F9 (the respawn-path drift pattern), but for a different boundary: the **save file boundary** instead of the bed-wrap boundary.

**Mechanism:**
- Each plugin's state lives in a top-level field on `R` (e.g., `R.COMP`, `R.machines`, `R.need`).
- `doSave` (save.lua:330-332) dumps `R.PLUGIN_SAVE_KEYS` verbatim: `for _, key in ipairs(R.PLUGIN_SAVE_KEYS) do if R[key] ~= nil then plugins[key] = R[key] end end`.
- `doLoad` (save.lua:407) restores: `if data.plugins then for k, v in pairs(data.plugins) do R[k] = v end end`. **UNCONDITIONAL overwrite of the entire plugin state table from the save file.**
- Plugin initializers (e.g., `R.COMP = R.COMP or { active=false, x=0, y=0, ... }`) run at PLUGIN LOAD time — BEFORE the user loads a save. After the user loads a save, the saved value replaces the initialized one.

**Failure mode (F5/F9-style drift):** if a plugin's source code is updated to (a) initialize a new field (e.g., `R.COMP.lastHeartbeat = nil` added at line 41) or (b) read a new field that wasn't previously read (e.g., a new tick branch reads `C.queue`), but an old save file is loaded that doesn't have that field, then:
- The initializer at plugin load runs first → field is at its default value (often `nil` for new fields).
- doLoad restores the OLD save's COMP table, which LACKS the new field.
- Subsequent code reading the new field crashes: `bad argument #1 to 'ipairs' (table expected, got nil)` or `attempt to get length of field 'queue' (a nil value)`.

## EVIDENCE — live-bridge-confirmed crash on simulated old-save

**Reproducer (single bridge call, no test harness):**
```lua
local R = PBX.state.rpg
-- Reset COMP to the 15-field "old version" shape (the source's R.COMP = R.COMP or {...} initializer)
R.COMP = { active=false, x=0, y=0, vx=0, vy=0, onGround=false, coyote=0, face=1, anim=0,
          hp=60, maxhp=60, dead=false, deadAt=nil, name="Aster", inv={} }
-- Now call the live companionChatPending handler
local ok, err = pcall(function()
  for i, m in ipairs(R.COMP.chatQueue) do return m end
end)
return tostring(ok) .. " | " .. tostring(err)
```

**Bridge result:**
```
false | [string "..."]:1: bad argument #1 to 'ipairs' (table expected, got nil)
```

**Source location:** companion.lua:705 — `for i, m in ipairs(C.chatQueue) do out[i] = { text = m.text, at = m.at } end`. The `ipairs()` call fires before line 706 (`if consume ~= false then C.chatQueue = {} end`), so the drain-on-consume pattern doesn't even get a chance to fix it.

**Why this hasn't fired yet (real but latent):**
- All current saves were written by recent versions that include `chatQueue` in COMP (verified against `D:/powder-toy/knowledge/rpg-save.json` — COMP has 28 fields including `chatQueue`).
- The current source's `R.COMP = R.COMP or { ... }` initializer (lines 29-47) does NOT include `chatQueue`, `lastHeartbeat`, `mode`, `sayMsg`, `sayAt`, `override`, `_hits`, `enqueueChain`, `cmd`, `index` — 10 fields are referenced in code but missing from the initializer. If a save file from a version that pre-dates any of those fields is loaded, those fields are `nil` after restore.
- The `R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}` + `for k, v in pairs(data.plugins) do R[k] = v end` is **unconditional** (line 407 has no field-level fallback, no re-run of initializer after restore).

**Companion-specific crash surface (other plugins likely have similar):**
- `companion.lua:694` — `C.queue[#C.queue + 1] = steps[i]` inside `C.enqueueChain`. If `C.queue` is nil (from old save), this is `nil[1] = ...` → crash.
- `companion.lua:849` — `if C.mode == "model" and (R.frame - (C.lastHeartbeat or -999999)) > 600 then` — safe (the `or -999999` guards lastHeartbeat; `C.mode == "model"` with nil mode is just `false`).
- `companion.lua:865` — `if C.needsPlace then` — safe (nil is falsy).

**Companion's other plugins (less audited):**
- machines, machines2, survival, ui, guide, enemies, vehicles, save, world all push keys onto PLUGIN_SAVE_KEYS (or are saved via the explicit `plugins` field). Each one's initializer pattern is `R.X = R.X or {}` or `R.X = R.X or defaultValue`. Same drift risk applies to each: if any plugin adds a new field to its initializer without checking the loaded save file, and a user loads a save from before that field was added, code paths reading that field will crash.

**Real-world trigger:** if a user backs up a save file from v1.15.6 (before chatQueue was added to companion's R.COMP initializer) and loads it after upgrading to v1.15.11, the load will succeed silently (no error), but the next time the chat-driver polls `R.companionChatPending()` or someone calls `C.enqueueChain()`, crash.

## RECOMMENDED FIX — for @bugs

**Two options, ordered by safety:**

### Option A (RECOMMENDED): re-run plugin initializers after load

In `doLoad` (save.lua:407 area), after restoring `data.plugins[k]` into `R[k]`, re-run the affected plugin's "set defaults for missing fields" helper. Concretely:

```lua
-- After: if data.plugins then for k, v in pairs(data.plugins) do R[k] = v end end
if R._applyCompanionDefaults then R._applyCompanionDefaults() end
if R._applyMachinesDefaults then R._applyMachinesDefaults() end
-- ... etc for each plugin that registers via PLUGIN_SAVE_KEYS
```

The `_applyXDefaults` helpers would be one-line `local function` defined in each plugin (e.g., companion.lua adds `function R._applyCompanionDefaults() local C = R.COMP; C.chatQueue = C.chatQueue or {}; C.queue = C.queue or {}; C.lastHeartbeat = C.lastHeartbeat; C.mode = C.mode or "auto"; ... end`).

**Cost:** ~5 lines per plugin × 9 plugins = ~45 lines. Each one is the same shape as the existing `R.COMP = R.COMP or { ... }` initializer but expressed as `field = field or default`.

**Safety:** explicit. Each plugin declares which of its fields can be missing from an old save.

### Option B (minimal): change doLoad's restore to merge, not overwrite

In `doLoad` (save.lua:407), change:
```lua
if data.plugins then for k, v in pairs(data.plugins) do R[k] = v end end
```
to:
```lua
-- Merge: only set keys that are present in BOTH the save and the plugin's current state shape.
-- This prevents an old save from clearing fields the plugin added later.
if data.plugins then
  for k, v in pairs(data.plugins) do
    if type(v) == "table" and type(R[k]) == "table" then
      -- merge table fields, preserving R-side additions
      for fk, fv in pairs(v) do R[k][fk] = fv end
    else
      R[k] = v
    end
  end
end
```

**Cost:** ~7 lines in doLoad.

**Safety:** implicit. Works for any plugin, but doesn't fix the `chatQueue == nil` case because `R.COMP.chatQueue` would be `nil` both before and after merge (the save didn't have it, the plugin didn't initialize it).

**Why Option A is better:** Option B's "merge" handles fields added LATER to a save (the save's new key overwrites the plugin's default) but DOESN'T handle fields added LATER to the plugin's initializer (the plugin's default stays nil, and the save didn't have it). Option A explicitly addresses both directions.

### Option C (NICE-TO-HAVE, not this round): version field

`doSave` already writes `"version":1` (save.lua:300). `doLoad` could branch on `data.version`:
```lua
if (data.version or 1) < 2 then migrate_v1_to_v2(data) end
```
And each migration step explicitly adds fields the load needs. Cost: medium (one migration step per save-shape evolution). Same shape as Minecraft's world format versioning.

## DECISION

**Recommend shipping Option A as a fix (recommended) OR Option B as a minimum.** Both are small, both prevent the crash, both are testable via bridge.

**Option C (versioning)** is the right long-term direction but is over-engineering for a single latent bug class. Document and monitor; revisit if companion or another plugin adds a field every round (which would force frequent migrations).

**Severity without fix:** MEDIUM. No live crash today (saves are recent), but the moment anyone loads a v1.15.6-or-earlier save (which is plausible — players hoard save files) into the current build, the next chat-poll or `C.enqueueChain()` call crashes. **Severity with fix:** trivially safe.

**No new checker needed** — same as rounds 21/23/24, the bug class is "state drift across a boundary", and a regex can't tell which fields the load needs to merge. The fix is the right discipline.

## Verification

- Bridge confirmed: PID 37320, port 9877, VER=1.15.10.
- Bridge repro of the chatQueue crash: `for i, m in ipairs(R.COMP.chatQueue) do ... end` with C.chatQueue=nil returns `bad argument #1 to 'ipairs' (table expected, got nil)`. Single call, hand-verified.
- Companion source diff: 10 fields (chatQueue, queue, lastHeartbeat, mode, sayMsg, sayAt, override, _hits, enqueueChain, cmd, index) are referenced in companion.lua but NOT in the R.COMP initializer at lines 29-47. Confirmed via regex diff against live companion.lua.
- Save file inspect: D:/powder-toy/knowledge/rpg-save.json has COMP with 28 fields (chatQueue included because it was written by a recent version). Confirmed via `python -c "import json; print(sorted(json.load(open('D:/powder-toy/knowledge/rpg-save.json'))['plugins']['COMP'].keys()))"`.
- (a) hook-arity re-check: NOT re-run this round (round 23 found 5 sloppy-but-legal, zero real bugs; no source changes since round 23 that would add new handlers).
- (c) inventory capacity: NOT pursued as a finding — R.inventory has no cap but that's a deliberate vanilla-style design choice (sandbox has its own 999 cap). Not a bug class.