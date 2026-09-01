-- ===========================================================================
-- 21_extra_kinds.lua -- boot-time loader for the extra behaviour kinds
-- (absorber, turbine, teg, photovoltaic, piezo, pcm, reactive) that
-- scripts/lua/{power,material,chem}_kinds.lua define on top of 20_behaviors.lua's
-- eight built-ins (conductor, creature, decayer, emitter, glower, grower, inert,
-- pheromone).
--
-- WHY THIS EXISTS (2026-09-0x, @multiplayer): those three files were only ever
-- executed by a human running `python scripts/define_materials.py` against a
-- LIVE, already-running process (its own register_kinds() does the equivalent
-- of what this module does, over the HTTP bridge, on demand). Nothing loaded
-- them automatically at boot. 07_materials_seed.lua persists 9 elements whose
-- spec.behavior.kind is "reactive" (e.g. DU), 1 "absorber" (B4C), 1 "turbine"
-- (TRBN), and a handful more from this set -- and 10_registry.lua's own
-- boot-time recreate (queueSpecList -> scheduleRecreate -> PBX.defer ->
-- applySpec -> resolveBehavior) runs on the FIRST GAME TICK, by which point
-- every bridge_src module (00 through 95) has already finished loading. So
-- this module only needs to run at SOME point during that synchronous load --
-- it does not need to run before 10_registry.lua -- but it DOES need to run
-- AFTER 20_behaviors.lua, because power_kinds.lua/material_kinds.lua both do
-- `local kinds = PBX.state.behaviors.kinds` and index straight into it; that
-- table is only created by 20_behaviors.lua itself (behaviors.kinds = kinds).
-- Loading this at module slot 21 (right after 20) satisfies both constraints.
--
-- Before this module existed, an element persisted with one of these seven
-- kinds would silently fail resolveBehavior on recreate and be dropped as
-- "unrecreatable" (see 10_registry.lua's own scheduleRecreate/applySpec and
-- knowledge/REALISM_RUNBOOK.md, which named this exact gap for a DEV restart
-- -- it is unconditional for a machine that has never run define_materials.py
-- at all, i.e. every downloaded copy of the game).
--
-- Reads the three files straight off disk (same multi-path fallback pattern
-- 86_rpg_loader.lua already uses for rpg.lua itself, so this works whether cwd
-- is a normal deploy, a lab_instance.py ddir, or the dev tree) rather than
-- duplicating their contents here -- scripts/lua/*_kinds.lua stays the single
-- source of truth define_materials.py's own register_kinds() also reads from.
-- ===========================================================================

local KIND_FILES = { "power_kinds.lua", "material_kinds.lua", "chem_kinds.lua" }
local SEARCH_PATHS = {
    "../scripts/lua/",
    "scripts/lua/",
    "D:/The-Powder-Toy/scripts/lua/",
    "D:/powder-toy/scripts/lua/",
}

for _, fname in ipairs(KIND_FILES) do
    local loaded = false
    for _, base in ipairs(SEARCH_PATHS) do
        local f = io.open(base .. fname, "r")
        if f then
            local src = f:read("*a")
            f:close()
            local chunk, compileErr = loadstring(src, "@" .. base .. fname)
            if chunk then
                local ok, runErr = pcall(chunk)
                if ok then
                    loaded = true
                    PBX.log("extra_kinds", "loaded " .. fname .. " from " .. base)
                else
                    PBX.log("extra_kinds", "error running " .. fname .. ": " .. tostring(runErr))
                end
            else
                PBX.log("extra_kinds", "compile error in " .. fname .. ": " .. tostring(compileErr))
            end
            break -- first existing path wins, same convention as 86_rpg_loader.lua
        end
    end
    if not loaded then
        PBX.log("extra_kinds", "WARNING: could not find " .. fname .. " on any search path")
    end
end

PBX.log("extra_kinds", "21_extra_kinds loaded; kinds now=" .. table.concat((function()
    local names = {}
    for k in pairs(PBX.state.behaviors.kinds or {}) do names[#names + 1] = k end
    table.sort(names)
    return names
end)(), ","))
