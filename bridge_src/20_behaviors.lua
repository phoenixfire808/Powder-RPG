-- ===========================================================================
-- 20_behaviors.lua -- Powder Bridge Extension behaviour library
--
-- Registers NO HTTP actions.  Publishes a factory table at
-- PBX.state.behaviors.kinds so 10_registry.lua can turn a `behavior =
-- {kind=..., params=...}` spec (from defineElement) into a plain Lua
-- Update closure and install it with elements.property(id, "Update", fn).
--
-- Contract for a Lua Update function (confirmed from source, not guessed):
--   src/simulation/ElementDefs.h:46
--     #define UPDATE_FUNC_ARGS Simulation* sim, int i, int x, int y,
--                               int surround_space, int nt, Parts &parts,
--                               int pmap[YRES][XRES]
--   src/lua/LuaElements.cpp:82-121 (luaUpdateWrapper) shows the exact
--   marshalling into Lua: it pushes (i, x, y, surround_space, nt) -- five
--   arguments, no `parts`/`pmap` (those stay native side; Lua reaches
--   particle state through sim.partProperty/sim.pmap instead) -- calls the
--   registered function with 5 args expecting 1 return, and only a Lua
--   *boolean* `true` (checked with lua_isboolean/lua_toboolean at line 111)
--   means "stop, do not fall through to the built-in update"; anything
--   else (nil, false, a number) is treated as false.  So every closure here
--   returns a real boolean, never a bare truthy value.
--
-- Confirmed sim.* signatures (src/lua/LuaSimulation.cpp, registered by
-- literal C identifier via the LFUNC macro at line 2101-2162):
--   sim.partProperty(i, name [, value])   -- get, or set when value present
--                                          (line 486-546)
--   sim.partCreate(newID, x, y, type [, v]) -- newID=-1 picks a free slot;
--                                          returns the new index or -1 on
--                                          failure, NEVER nil (line 394-426)
--   sim.partKill(i)                       -- single-arg form kills index i
--                                          directly (line 548-561)
--   sim.partChangeType(i, type)           -- keeps i's own x/y (line 383-392)
--   sim.pmap(x, y)                        -- returns the occupant's part id,
--                                          or nothing (nil) if the cell is
--                                          empty; errors if (x,y) is out of
--                                          range (line 1610-1622), so every
--                                          neighbour scan below bounds-checks
--                                          before calling it (PBX.cellFree
--                                          already does this for the
--                                          single-cell "is it free" case).
-- ===========================================================================

local behaviors = PBX.state.behaviors
behaviors.VERSION = "1.0.0"

local kinds = {}
behaviors.kinds = kinds

-- ---------------------------------------------------------------------------
-- Small shared helpers.  Kept local (not on PBX) because they're only
-- meaningful in terms of this module's own neighbour-scan/param patterns.
-- ---------------------------------------------------------------------------

-- 8-neighbourhood offsets, paired by index.  Shared by every behaviour that
-- scans adjacent cells so there's exactly one place that defines "adjacent".
local NX8 = { -1, 0, 1, -1, 1, -1, 0, 1 }
local NY8 = { -1, -1, -1, 0, 0, 1, 1, 1 }

--- True with probability p (0..1), without the >=1/<=0 edge cases costing a
--- wasted math.random call.
local function chanceRoll(p)
    if p <= 0 then return false end
    if p >= 1 then return true end
    return math.random() < p
end

--- Fetch a validated+clamped integer param, falling back to the spec's
--- default on anything invalid (missing, wrong type, out of range).  A
--- caller passing garbage must get a sane element, never a runtime error --
--- so failures here are silent by design; the validators still exist to
--- produce the clamped value, we just never propagate their error string.
local function pInt(params, name, spec)
    local v = params and params[name]
    if v == nil then return spec.default end
    local n, e = PBX.vInt(v, name, spec.min, spec.max)
    if e then return spec.default end
    return n
end

local function pNum(params, name, spec)
    local v = params and params[name]
    if v == nil then return spec.default end
    local n, e = PBX.vNum(v, name, spec.min, spec.max)
    if e then return spec.default end
    return n
end

--- Wrap a factory-produced Update body so no error escapes it (PBX.guard)
--- and so the value handed back to the engine is always a real boolean --
--- luaUpdateWrapper only special-cases lua_isboolean(true) (LuaElements.cpp
--- line 111), so a stray nil/number return would silently behave like
--- false anyway, but being explicit means the diagnostics error counter
--- (PBX.errorCount) is the only place a bug in one of these shows up
--- instead of TPT's own log.
local function safeUpdate(name, fn)
    return function(i, x, y, surround_space, nt)
        local ok, res = PBX.guard(name, fn, i, x, y, surround_space, nt)
        if not ok then return false end
        return res and true or false
    end
end

--- Bounds-checked neighbour occupant lookup.  sim.pmap errors outside the
--- sim, and returns nothing (nil) rather than 0 for an empty cell, so this
--- normalises both into a single nil-or-id result.
local function neighbourOccupant(nx, ny)
    if nx < 0 or ny < 0 or nx >= PBX.SIM_W or ny >= PBX.SIM_H then return nil end
    local ok, occ = pcall(sim.pmap, nx, ny)
    if not ok then return nil end
    return occ
end

-- ---------------------------------------------------------------------------
-- inert -- the default.  Does nothing; exists so "no behavior configured"
-- is a real, named kind rather than a nil special case every caller has to
-- handle separately.
-- ---------------------------------------------------------------------------

kinds.inert = {
    params = {},
    make = function(params)
        return safeUpdate("inert", function(i, x, y, surround_space, nt)
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- glower -- cycles `life` between minLife and maxLife on a `period`-tick
-- triangle wave so the element reads as pulsing.
--
-- Deliberately stateless: the phase is derived from PBX.tickIndex and the
-- particle's own index i (so a field of glowers doesn't all pulse in
-- lockstep), rather than stored in a particle field.  That means this
-- kind needs no bookkeeping column and can't drift out of sync with itself.
--
-- Note on visible bloom (why this behavior stops at the life value): TPT's
-- DEFAULT render preset downgrades PMODE_GLOW unless the element also
-- contributes to the fire buffer (see the *_FIRE_RGB/firea handling other
-- elements' Graphics functions use, e.g. SPRK.cpp's graphics() sets *firea
-- and OR's in FIRE_SPARK).  Whether a glower actually blooms on screen is a
-- function of the element's declared render properties/Graphics, which is
-- 10_registry.lua's concern, not this behavior's -- this kind only ever
-- touches `life`.
-- ---------------------------------------------------------------------------

local GLOWER_SPECS = {
    period  = { type = "int", min = 2,  max = 3600,  default = 60 },
    minLife = { type = "int", min = 0,  max = 10000, default = 0 },
    maxLife = { type = "int", min = 0,  max = 10000, default = 100 },
}

kinds.glower = {
    params = GLOWER_SPECS,
    make = function(params)
        local period  = pInt(params, "period", GLOWER_SPECS.period)
        local minLife = pInt(params, "minLife", GLOWER_SPECS.minLife)
        local maxLife = pInt(params, "maxLife", GLOWER_SPECS.maxLife)
        if maxLife < minLife then minLife, maxLife = maxLife, minLife end
        local span = maxLife - minLife
        local half = period / 2

        return safeUpdate("glower", function(i, x, y, surround_space, nt)
            -- Offset by i so glowers with the same period don't all peak on
            -- the same frame; triangle wave 0->half->0 over `period` ticks.
            local t = (PBX.tickIndex + i) % period
            local frac
            if t <= half then frac = t / half else frac = (period - t) / half end
            sim.partProperty(i, "life", minLife + math.floor(frac * span + 0.5))
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- decayer -- life ticks down at `rate`/tick; at zero, becomes another
-- element (or is killed if `becomes` is NONE/absent).
--
-- `startLife` is metadata only: it's not read inside the Update closure at
-- all.  Seeding a particle's initial life is 10_registry.lua/defineElement's
-- job (setting the element's default life at creation time), and the two
-- can't be conflated here -- life==0 has to mean "decayed to death" inside
-- this closure, so it can never also double as "not yet initialised".
-- ---------------------------------------------------------------------------

local DECAYER_SPECS = {
    rate      = { type = "int",    min = 1, max = 1000,  default = 1 },
    becomes   = { type = "string", min = 0, max = 32,    default = "NONE" },
    startLife = { type = "int",    min = 0, max = 10000, default = 100 },
}

kinds.decayer = {
    params = DECAYER_SPECS,
    make = function(params)
        local rate = pInt(params, "rate", DECAYER_SPECS.rate)

        local becomesRaw = params and params.becomes
        local killMode, becomesId = true, nil
        if becomesRaw ~= nil and not (type(becomesRaw) == "string" and string.upper(becomesRaw) == "NONE") then
            local id, e = PBX.vElem(becomesRaw)
            if e then
                PBX.warn("behaviors", "decayer: invalid becomes '" .. tostring(becomesRaw) .. "', falling back to kill")
            else
                killMode, becomesId = false, id
            end
        end

        return safeUpdate("decayer", function(i, x, y, surround_space, nt)
            local life = (sim.partProperty(i, "life") or 0) - rate
            if life <= 0 then
                if killMode then
                    sim.partKill(i)
                else
                    sim.partChangeType(i, becomesId)
                end
                return true
            end
            sim.partProperty(i, "life", life)
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- emitter -- every `interval` ticks, spawns `count` particles of `emits`
-- into random free neighbouring cells, with optional temperature/outward
-- velocity.
--
-- Global per-tick budget: a wall of emitters could otherwise try to create
-- thousands of particles on the same frame and flood the particle table
-- (NPART is finite; sim.partCreate just starts returning -1 once it's
-- full, but getting there via unbounded emission is exactly the failure
-- mode we're avoiding).  The budget is a module-level upvalue shared by
-- every emitter closure, reset lazily the first time it's touched on a new
-- PBX.tickIndex -- cheaper than a dedicated PBX.onTick hook, and correct
-- because tickIndex only advances once per simulation frame, so every
-- particle Update running "this frame" observes the same value.
-- ---------------------------------------------------------------------------

local EMIT_BUDGET_PER_TICK = 200
local emitBudgetTick, emitBudgetUsed, emitBudgetWarned = -1, 0, false

local function consumeEmitBudget(want)
    if PBX.tickIndex ~= emitBudgetTick then
        emitBudgetTick, emitBudgetUsed, emitBudgetWarned = PBX.tickIndex, 0, false
    end
    local room = EMIT_BUDGET_PER_TICK - emitBudgetUsed
    if room <= 0 then
        if not emitBudgetWarned then
            PBX.warn("behaviors", "emitter global budget (" .. EMIT_BUDGET_PER_TICK .. "/tick) reached")
            emitBudgetWarned = true
        end
        return 0
    end
    local granted = want
    if granted > room then
        granted = room
        if not emitBudgetWarned then
            PBX.warn("behaviors", "emitter global budget (" .. EMIT_BUDGET_PER_TICK .. "/tick) reached")
            emitBudgetWarned = true
        end
    end
    emitBudgetUsed = emitBudgetUsed + granted
    return granted
end

local EMITTER_SPECS = {
    emits       = { type = "string", min = 0, max = 32,   default = "DUST" },
    interval    = { type = "int",    min = 1, max = 10000, default = 30 },
    count       = { type = "int",    min = 1, max = 20,    default = 1 },
    -- 0 is a sentinel meaning "leave the new particle's default temp/vel
    -- alone" -- 0 K and zero velocity are both degenerate/uninteresting
    -- values to explicitly request, so reusing them as "don't override"
    -- costs nothing real and keeps the param optional without a third
    -- has-a-value flag.
    temperature = { type = "num", min = 0, max = 9999, default = 0 },
    speed       = { type = "num", min = 0, max = 20,   default = 0 },
}

kinds.emitter = {
    params = EMITTER_SPECS,
    make = function(params)
        local interval    = pInt(params, "interval", EMITTER_SPECS.interval)
        local count       = pInt(params, "count", EMITTER_SPECS.count)
        local temperature = pNum(params, "temperature", EMITTER_SPECS.temperature)
        local speed       = pNum(params, "speed", EMITTER_SPECS.speed)

        local emitsRaw = (params and params.emits) or EMITTER_SPECS.emits.default
        local emitsId, e = PBX.vElem(emitsRaw)
        if e then
            PBX.warn("behaviors", "emitter: invalid emits '" .. tostring(emitsRaw) .. "', falling back to " .. EMITTER_SPECS.emits.default)
            emitsId = PBX.vElem(EMITTER_SPECS.emits.default) -- DUST always resolves in a stock build
        end

        return safeUpdate("emitter", function(i, x, y, surround_space, nt)
            -- Stagger by i so emitters sharing an interval don't all fire
            -- the same frame; the budget below is the real flood guard.
            if ((PBX.tickIndex + i) % interval) ~= 0 then return false end
            local granted = consumeEmitBudget(count)
            for n = 1, granted do
                -- Scan the 8-neighbourhood from a random start so the free
                -- cell chosen isn't biased toward one direction.
                local start = math.random(0, 7)
                for k = 0, 7 do
                    local idx = (start + k) % 8 + 1
                    local dx, dy = NX8[idx], NY8[idx]
                    local nx, ny = x + dx, y + dy
                    if PBX.cellFree(nx, ny) then
                        local pid = sim.partCreate(-1, nx, ny, emitsId)
                        if pid >= 0 then
                            if temperature > 0 then sim.partProperty(pid, "temp", temperature) end
                            if speed > 0 then
                                sim.partProperty(pid, "vx", dx * speed)
                                sim.partProperty(pid, "vy", dy * speed)
                            end
                        end
                        break
                    end
                end
            end
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- grower -- PLNT-style spread: with probability `chance`, claims one free
-- neighbouring cell (copying its own element type into it) as long as no
-- more than `maxNeighbours` cells around it are already occupied, and (if
-- `needs` is set) at least one neighbour is that element.
-- ---------------------------------------------------------------------------

local GROWER_SPECS = {
    chance        = { type = "num", min = 0, max = 1, default = 0.02 },
    maxNeighbours = { type = "int", min = 0, max = 8, default = 4 },
    needs         = { type = "string", min = 0, max = 32, default = false },
}

kinds.grower = {
    params = GROWER_SPECS,
    make = function(params)
        local chance = pNum(params, "chance", GROWER_SPECS.chance)
        local maxN   = pInt(params, "maxNeighbours", GROWER_SPECS.maxNeighbours)

        local needsRaw = params and params.needs
        local needsId = nil
        if needsRaw ~= nil and needsRaw ~= false then
            local id, e = PBX.vElem(needsRaw)
            if e then
                PBX.warn("behaviors", "grower: invalid needs '" .. tostring(needsRaw) .. "', ignoring requirement")
            else
                needsId = id
            end
        end

        return safeUpdate("grower", function(i, x, y, surround_space, nt)
            if not chanceRoll(chance) then return false end

            local occupied, needSatisfied = 0, (needsId == nil)
            local freeCount, freeK = 0, {}
            for k = 1, 8 do
                local nx, ny = x + NX8[k], y + NY8[k]
                if nx >= 0 and ny >= 0 and nx < PBX.SIM_W and ny < PBX.SIM_H then
                    local occ = neighbourOccupant(nx, ny)
                    if occ then
                        occupied = occupied + 1
                        if needsId and not needSatisfied and sim.partProperty(occ, "type") == needsId then
                            needSatisfied = true
                        end
                    else
                        freeCount = freeCount + 1
                        freeK[freeCount] = k
                    end
                end
            end

            if occupied > maxN or not needSatisfied or freeCount == 0 then return false end

            local pick = freeK[math.random(1, freeCount)]
            local myType = sim.partProperty(i, "type")
            sim.partCreate(-1, x + NX8[pick], y + NY8[pick], myType)
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- pheromone -- diffusing, decaying trail marker.  life -= decay each tick,
-- dies at zero; with probability `spread`, copies a fraction of its
-- remaining life into one random adjacent same-type particle.
-- ---------------------------------------------------------------------------

local PHEROMONE_SPECS = {
    decay  = { type = "int", min = 0, max = 1000, default = 2 },
    spread = { type = "num", min = 0, max = 1,    default = 0.1 },
}

kinds.pheromone = {
    params = PHEROMONE_SPECS,
    make = function(params)
        local decay  = pInt(params, "decay", PHEROMONE_SPECS.decay)
        local spread = pNum(params, "spread", PHEROMONE_SPECS.spread)

        return safeUpdate("pheromone", function(i, x, y, surround_space, nt)
            local life = (sim.partProperty(i, "life") or 0) - decay
            if life <= 0 then
                sim.partKill(i)
                return true
            end
            sim.partProperty(i, "life", life)

            if chanceRoll(spread) then
                local myType = sim.partProperty(i, "type")
                -- Collect same-type neighbours and pick one at random so a
                -- whole trail doesn't refresh in the same direction every
                -- tick.  The carried fraction (half of our own remaining
                -- life) isn't spec'd exactly -- decay/spread are the only
                -- tunable params -- it just needs to read as "diffusing",
                -- so only raise the neighbour's life, never lower it.
                local candidates, n = {}, 0
                for k = 1, 8 do
                    local nx, ny = x + NX8[k], y + NY8[k]
                    if nx >= 0 and ny >= 0 and nx < PBX.SIM_W and ny < PBX.SIM_H then
                        local occ = neighbourOccupant(nx, ny)
                        if occ and sim.partProperty(occ, "type") == myType then
                            n = n + 1
                            candidates[n] = occ
                        end
                    end
                end
                if n > 0 then
                    local target = candidates[math.random(1, n)]
                    local carried = math.floor(life * 0.5)
                    if carried > (sim.partProperty(target, "life") or 0) then
                        sim.partProperty(target, "life", carried)
                    end
                end
            end
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- conductor -- mirrors SPRK's own conduction check (src/simulation/elements/
-- SPRK.cpp) for a custom element that isn't PROP_CONDUCTS itself: while our
-- own life==0 (not currently sparked), if an adjacent particle is SPRK with
-- life<4 (SPRK.cpp line 391: `parts[ID(r)].life==0 && parts[i].life<4` is
-- the exact receiver/sender condition it uses for every other conductive
-- receiver), become SPRK ourselves using the same convention SPRK relies on
-- to revert: ctype := our own element id, life := 4 (SPRK.cpp line 392,
-- the base "just sparked" life) plus `delay` extra ticks so the caller can
-- tune how long it stays lit.  SPRK's own built-in Update (not ours -- once
-- we're type SPRK, elements[SPRK].Update runs, not this closure, since
-- dispatch is keyed by parts[i].type) then decrements that life on its own
-- PROP_LIFE_DEC schedule and, at life<=0, converts back to `ctype`
-- (SPRK.cpp lines 63-85) -- i.e. back to us. We don't need to manage the
-- reversion at all; reusing SPRK's own machinery is the whole point.
-- ---------------------------------------------------------------------------

local CONDUCTOR_SPECS = {
    delay = { type = "int", min = 0, max = 1000, default = 0 },
}

kinds.conductor = {
    params = CONDUCTOR_SPECS,
    make = function(params)
        local delay = pInt(params, "delay", CONDUCTOR_SPECS.delay)

        local sprkId, sprkErr = PBX.vElem("SPRK")
        if sprkErr then
            -- SPRK is a stock TPT element; this should be unreachable, but
            -- a caller must never get a crashing Update out of a bad build.
            PBX.warn("behaviors", "conductor: SPRK element not found, behavior disabled")
            return safeUpdate("conductor", function() return false end)
        end

        return safeUpdate("conductor", function(i, x, y, surround_space, nt)
            if (sim.partProperty(i, "life") or 0) ~= 0 then return false end
            for k = 1, 8 do
                local nx, ny = x + NX8[k], y + NY8[k]
                if nx >= 0 and ny >= 0 and nx < PBX.SIM_W and ny < PBX.SIM_H then
                    local occ = neighbourOccupant(nx, ny)
                    if occ and sim.partProperty(occ, "type") == sprkId then
                        local senderLife = sim.partProperty(occ, "life") or 0
                        if senderLife < 4 then
                            local myType = sim.partProperty(i, "type")
                            sim.partProperty(i, "ctype", myType)
                            sim.partProperty(i, "life", 4 + delay)
                            sim.partChangeType(i, sprkId)
                            return true
                        end
                    end
                end
            end
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- creature -- delegates entirely to PBX.state.worker.update, written by
-- 40_worker.lua.  Looked up INSIDE the returned closure, every call, rather
-- than once at make() time: module load order (00 -> 10 -> 20 -> 30 -> 40)
-- means 40_worker.lua hasn't run yet when 20_behaviors.lua's kinds table is
-- being built, so PBX.state.worker.update would still be nil if we
-- resolved it eagerly.  By the time any particle actually ticks (well after
-- every module has loaded), it's populated.
-- ---------------------------------------------------------------------------

local creatureWarned = false

kinds.creature = {
    params = {},
    make = function(params)
        return safeUpdate("creature", function(i, x, y, surround_space, nt)
            local update = PBX.state.worker.update
            if type(update) ~= "function" then
                if not creatureWarned then
                    PBX.warn("behaviors", "creature: PBX.state.worker.update is not available yet")
                    creatureWarned = true
                end
                return false
            end
            return update(i, x, y, surround_space, nt) and true or false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- Diagnostics support: sorted list of every kind with its param descriptor.
-- ---------------------------------------------------------------------------

--- Every registered behaviour kind, sorted by name, with its param specs --
--- consumed by 60_diag.lua so extStatus/extSelfTest can report on what's
--- available without reaching into this module's internals directly.
function behaviors.list()
    local names = {}
    for k in pairs(kinds) do names[#names + 1] = k end
    table.sort(names)
    local out = PBX.arr({})
    for idx = 1, #names do
        out[idx] = { kind = names[idx], params = kinds[names[idx]].params }
    end
    return out
end

PBX.log("behaviors", "PBX behaviors " .. behaviors.VERSION .. " loaded, kinds=" .. table.concat((function()
    local names = {}
    for k in pairs(kinds) do names[#names + 1] = k end
    table.sort(names)
    return names
end)(), ","))
