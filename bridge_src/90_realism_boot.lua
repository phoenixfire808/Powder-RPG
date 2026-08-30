-- ===========================================================================
-- 90_realism_boot.lua -- fresh-session marker for the realism persistence
-- layer (powder_ext/realism_tools.py: realism_apply / realism_status).
--
-- Problem this exists to signal, not to fix: custom behaviour kinds
-- (scripts/lua/*_kinds.lua, registered ad hoc via executeLua) and the
-- stock-element realism patch (knowledge/stock-element-realism-patch*.json,
-- also applied via executeLua) live only in this process's memory -- neither
-- is written to disk by anything, so both are gone the instant powder.exe
-- restarts. (10_registry.lua's own pbx-custom-elements.json snapshot DOES
-- survive a restart and DOES try to recreate each element's Update function
-- from its persisted spec -- but that recreate runs before this module or
-- any executeLua call has had a chance to re-register a custom `behavior.kind`,
-- so an element defined with one of the *_kinds.lua behaviours can still be
-- dropped as "unrecreatable" on the very first tick. Fixing that ordering
-- would mean moving kind registration into bridge_src itself -- a bridge
-- source/semantics change intentionally out of scope for this module; see
-- knowledge/REALISM_RUNBOOK.md for the accepted gap and workaround.)
--
-- This module owns none of that repair work. Its only job is to make a fresh
-- session detectable from outside the process: once per boot, on the first
-- tick after every other numbered module has finished loading (so PBX,
-- PBX.state.behaviors, and PBX.save/PBX.load are all guaranteed to exist),
-- it bumps a persisted boot counter via the same pbx-<name>.json primitive
-- 10_registry.lua/30_colony.lua/50_tasks.lua already use. scripts/realism_watch.py
-- polls this (through executeLua, same as everything else in this file's
-- family) and diffs the counter against the last value it saw; a change means
-- "the game restarted since I last looked", which is this module's entire
-- contract. It never calls PBX.defer and never touches a particle, so it
-- carries none of the mutable-tools-event restrictions the rest of the bridge
-- works around.
-- ===========================================================================

local PBX = _G.PBX
local MOD = "realism_boot"
local MARKER = "realism_boot"

local written = false

PBX.onTick(MOD, function(tick)
    if written then return end
    written = true

    local prev = PBX.load(MARKER)
    local bootCount = 1
    if type(prev) == "table" then
        bootCount = (tonumber(prev.boot_count) or 0) + 1
    end

    local ok, err = PBX.save(MARKER, {
        boot_count = bootCount,
        first_tick = tick,
        bridge_version = PBX.VERSION,
    })
    if ok then
        PBX.log(MOD, "boot marker written: boot_count=" .. tostring(bootCount) ..
                      " first_tick=" .. tostring(tick))
    else
        PBX.warn(MOD, "failed to write boot marker: " .. tostring(err))
    end
end, 1)

PBX.log(MOD, "realism_boot 1.0.0 loaded")
