-- ===========================================================================
-- 70_people.lua -- per-person MCP control (Phase 4 of the people-pbx plan)
--
-- Seven direct-particle actions that let the MCP side inspect, move, kill,
-- retrait, feed, and recolour ONE worker particle by id, plus a small world
-- hazard dropper. This module owns no persistent state of its own -- it only
-- reads sim.* directly and PBX.getColony/PBX.getWorkerState (already global,
-- 00_util.lua), and calls into PBX.state.worker's published surface
-- (W.kill/W.setTrait/W.WORKER_LIFE, added in 40_worker.lua for this module)
-- for anything that needs 40_worker.lua's private state (retireAnt, corpse
-- conversion, trait storage).
--
-- particleId bound: sim's live particle slot count is NPART = XRES*YRES
-- (the same precedent bridge_base.lua's partsInventory action documents as
-- "slot_bound_source":"SimulationConfig.h:NPART=XRES*YRES"), so that is the
-- upper bound used here rather than an invented constant.
--
-- Every action that mutates a particle (personMove/personKill/personFeed/
-- personRecolor/worldPlaceHazard) runs through PBX.defer: PBX.register
-- handlers execute on the socket thread, and sim mutation must not happen
-- there (see 40_worker.lua's colonySpawnWorkers comment for the same rule).
-- personInspect is a pure read and personSetTrait only writes an in-memory
-- Lua table, so neither one needs to defer.
-- ===========================================================================

local PBX = _G.PBX
local MOD = "people"

local MAX_PARTICLE_ID = PBX.SIM_W * PBX.SIM_H

local ALLOWED_TRAITS = {
    builder = true, gatherer = true, coward = true, brave = true, lazy = true,
}

local HAZARD_ELEMENTS = { fire = "FIRE", lava = "LAVA", acid = "ACID", void = "VOID" }

--- Same resolution convention as bridge_base.lua's resolveElem / 30_colony's
--- elemName: try the bare name, then the DEFAULT_PT_ prefix TPT's stock
--- elements register under.
local function resolveElem(name)
    if type(elements) ~= "table" then return nil end
    return elements[name] or elements["DEFAULT_PT_" .. name]
end

local function validateParticleId(req)
    return PBX.vInt(req.particleId, "particleId", 0, MAX_PARTICLE_ID)
end

PBX.register("personInspect", function(req)
    local id, e = validateParticleId(req)
    if e then return PBX.err(e) end
    if not sim.partExists(id) then return PBX.err("no such particle") end
    return PBX.ok("personInspect", {
        life = sim.partProperty(id, "life"),
        temp = sim.partProperty(id, "temp"),
        cargo = sim.partProperty(id, "ctype"),
        state = PBX.getWorkerState(id),
        colonyId = PBX.getColony(id),
        x = sim.partProperty(id, "x"),
        y = sim.partProperty(id, "y"),
    })
end, MOD)

PBX.register("personMove", function(req)
    local id, e = validateParticleId(req)
    if e then return PBX.err(e) end
    if not sim.partExists(id) then return PBX.err("no such particle") end
    local x, y, e2 = PBX.vPixel(req.x, req.y)
    if e2 then return PBX.err(e2) end
    local job = PBX.defer(function()
        if not sim.partExists(id) then return { moved = false } end
        sim.partProperty(id, "x", x)
        sim.partProperty(id, "y", y)
        return { moved = true, x = x, y = y }
    end)
    return PBX.ok("personMove", { job = job, status = "pending" })
end, MOD)

PBX.register("personKill", function(req)
    local id, e = validateParticleId(req)
    if e then return PBX.err(e) end
    if not sim.partExists(id) then return PBX.err("no such particle") end
    local cause = req.cause
    if cause ~= nil then
        local c, ce = PBX.vStr(cause, "cause", 32)
        if ce then return PBX.err(ce) end
        cause = c
    else
        cause = "ordered"
    end
    local w = PBX.state.worker
    if type(w) ~= "table" or type(w.kill) ~= "function" then
        return PBX.err("worker module unavailable")
    end
    local job = PBX.defer(function() return { killed = w.kill(id, cause) == true } end)
    return PBX.ok("personKill", { job = job, status = "pending" })
end, MOD)

PBX.register("personSetTrait", function(req)
    local id, e = validateParticleId(req)
    if e then return PBX.err(e) end
    if not sim.partExists(id) then return PBX.err("no such particle") end
    local trait, e2 = PBX.vStr(req.trait, "trait", 16)
    if e2 then return PBX.err(e2) end
    if not ALLOWED_TRAITS[trait] then
        return PBX.err("trait must be one of builder, gatherer, coward, brave, lazy")
    end
    local w = PBX.state.worker
    if type(w) ~= "table" or type(w.setTrait) ~= "function" then
        return PBX.err("worker module unavailable")
    end
    w.setTrait(id, trait)
    return PBX.ok("personSetTrait", { particleId = id, trait = trait })
end, MOD)

PBX.register("personFeed", function(req)
    local id, e = validateParticleId(req)
    if e then return PBX.err(e) end
    if not sim.partExists(id) then return PBX.err("no such particle") end
    local amount, e2 = PBX.vInt(req.amount, "amount", 1, 100000)
    if e2 then return PBX.err(e2) end
    local w = PBX.state.worker
    local cap = (type(w) == "table" and tonumber(w.WORKER_LIFE)) or 1500
    local job = PBX.defer(function()
        if not sim.partExists(id) then return { fed = false } end
        local life = (sim.partProperty(id, "life") or 0) + amount
        if life > cap then life = cap end
        sim.partProperty(id, "life", life)
        return { fed = true, life = life }
    end)
    return PBX.ok("personFeed", { job = job, status = "pending" })
end, MOD)

PBX.register("personRecolor", function(req)
    local id, e = validateParticleId(req)
    if e then return PBX.err(e) end
    if not sim.partExists(id) then return PBX.err("no such particle") end
    local colour, e2 = PBX.vStr(req.colour, "colour", 10, "^0[xX][0-9A-Fa-f]+$")
    if e2 then return PBX.err(e2) end
    local n = tonumber(colour)
    if not n then return PBX.err("colour must parse as a hex number") end
    local job = PBX.defer(function()
        if not sim.partExists(id) then return { recoloured = false } end
        sim.partProperty(id, "dcolour", n)
        return { recoloured = true, colour = n }
    end)
    return PBX.ok("personRecolor", { job = job, status = "pending" })
end, MOD)

PBX.register("worldPlaceHazard", function(req)
    local x, y, e = PBX.vPixel(req.x, req.y)
    if e then return PBX.err(e) end
    local kind, e2 = PBX.vStr(req.kind, "kind", 8)
    if e2 then return PBX.err(e2) end
    local elemName = HAZARD_ELEMENTS[kind]
    if not elemName then
        return PBX.err("kind must be one of fire, lava, acid, void")
    end
    local elemId = resolveElem(elemName)
    if not elemId then return PBX.err("hazard element unavailable: " .. elemName) end
    local job = PBX.defer(function()
        local pid = sim.partCreate(-1, x, y, elemId)
        return { placed = pid ~= nil and pid >= 0, particleId = pid }
    end)
    return PBX.ok("worldPlaceHazard", { job = job, status = "pending" })
end, MOD)

PBX.log(MOD, "people 1.0.0 loaded")
