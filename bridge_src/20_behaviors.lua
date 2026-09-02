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
-- Shared helpers for the power-generation / reactive-chemistry kinds below
-- (absorber, pcm, photovoltaic, piezo, reactive, teg, turbine), added
-- 2026-09-01 to recover 16 custom elements that were shipping in
-- pbx-custom-elements.json / bridge_src/07_materials_seed.lua with behavior
-- kinds this file never implemented (registry warning: "unknown behavior
-- kind"). PORTED, not written from scratch: a prior working copy of exactly
-- these seven kinds was found intact at
-- knowledge/_newplayer_audit/extracted_v3/scripts/lua/{chem,power,material}_
-- kinds.lua (dated 2026-08-26, from a different bridge architecture) and its
-- `reactive` rule grammar matches every one of the nine `reactive` specs
-- actually shipped in 07_materials_seed.lua character-for-character, which
-- is strong evidence it is the real source those specs were authored
-- against, not a guess. Ported here with three changes, all deliberate:
--   1. Element name resolution goes through resolveElemName (below), not the
--      original's bespoke per-file `elemId`, so there is one implementation
--      instead of three near-duplicates.
--   2. Neighbour lookups that must see TYPE_ENERGY particles (NEUT, PHOT --
--      absorber and photovoltaic's whole job) go through
--      neighbourOccupantAny (below), which this file's pre-existing
--      neighbourOccupant cannot do: TYPE_ENERGY particles live in a separate
--      photon map (sim.photons), confirmed from src/simulation/elements/
--      NEUT.cpp:40 and PHOT.cpp:39 both declaring Properties = TYPE_ENERGY,
--      and sim.photons(x,y) is a distinct API from sim.pmap (documented at
--      40_worker.lua:158). The original extraction already knew this (its
--      own `occupant()` checked both maps) -- this port keeps that fix and
--      gives it a name that says why.
--   3. `reactive`'s original had one bug fixed in translation: the "no free
--      cell, convert the neighbour into the product instead" fallback used a
--      single upvalue (`r_extra_done`) shared across every rule AND every
--      particle of that element, so one particle's fallback could silently
--      suppress another's `extra` spawn on the same tick. This port uses a
--      call-local flag instead, so each hit is independent.
-- ---------------------------------------------------------------------------

--- Resolve an element name to a numeric id, tolerant of any custom group
--- prefix. A custom element's real `elements` table key is "GROUP_PT_NAME"
--- (src/lua/LuaElements.cpp:335: `identifier = group + "_PT_" + id`), not
--- the bare name -- so a bare lookup (what PBX.vElem tries first, for speed,
--- in the hot registry path) only ever finds DEFAULT_PT_* (stock) or
--- PBX_PT_* elements. The `reactive` kind's rule targets can name a custom
--- element in ANY group (MATL, POWER, ...), e.g. AL61's thermite rule
--- targets "FSLG", a MATL_PT_FSLG element -- so this falls back to scanning
--- every element slot's real Name property when the fast paths miss. Only
--- called once per rule at element-definition time (inside a kind's make()),
--- never per tick, so the O(512) scan cost is paid once per custom element
--- defined, not once per frame.
local function resolveElemName(raw)
    if raw == nil then return nil end
    local name = string.upper(tostring(raw))
    local id = elements[name] or elements["DEFAULT_PT_" .. name] or elements["PBX_PT_" .. name]
    if id ~= nil then return id end
    for j = 0, (2 ^ ((sim and sim.PMAPBITS) or 9)) - 1 do
        local ok, n = pcall(elements.property, j, "Name")
        if ok and n == name then return j end
    end
    return nil
end

--- Bounds-checked neighbour occupant lookup that also finds TYPE_ENERGY
--- particles (PHOT, NEUT, ...), which live in the separate photon map
--- (sim.photons) rather than pmap -- see the file-header note above.
--- neighbourOccupant alone is correct for every other kind in this file
--- because none of them target energy-type neighbours; absorber, reactive
--- and photovoltaic do, and must use this instead.
local function neighbourOccupantAny(nx, ny)
    local occ = neighbourOccupant(nx, ny)
    if occ then return occ end
    if nx < 0 or ny < 0 or nx >= PBX.SIM_W or ny >= PBX.SIM_H then return nil end
    local ok, p = pcall(sim.photons, nx, ny)
    if ok and p and p ~= 0 then return p end
    return nil
end

--- First free (unoccupied, in-bounds) cell in the 8-neighbourhood of (x, y),
--- or nil if all eight are full. Used by `reactive` to place a spawned
--- product (H2, GAS, FIRE, ...) next to the reacting particle.
local function freeNeighbourCell(x, y)
    for k = 1, 8 do
        local nx, ny = x + NX8[k], y + NY8[k]
        if PBX.cellFree(nx, ny) then return nx, ny end
    end
    return nil
end

--- First neighbour of exactly element id `id`, or nil.
local function findNeighbourOfType(x, y, id)
    for k = 1, 8 do
        local nx, ny = x + NX8[k], y + NY8[k]
        local occ = neighbourOccupantAny(nx, ny)
        if occ and sim.partProperty(occ, "type") == id then return occ end
    end
    return nil
end

--- Add `amount` directly to sim.pressure at the cell containing pixel
--- (x, y). sim.pressure is indexed in CELL space (src/lua/LuaSimulation.cpp
--- `pressure()` -> `sim->pv[p.Y][p.X]`, sized to PBX.CELL_W x PBX.CELL_H),
--- and PBX.SIM_W / PBX.CELL_W == 4 exactly, hence the shift. pcall-guarded:
--- a reaction's pressure yield is a bonus effect and must never be able to
--- break the reaction itself if sim.pressure's exact contract ever changes.
local function addReactionPressure(x, y, amount)
    if not amount then return end
    local cx, cy = math.floor(x / 4), math.floor(y / 4)
    local ok, cur = pcall(sim.pressure, cx, cy)
    if ok and cur then pcall(sim.pressure, cx, cy, cur + amount) end
end

--- Apply a rule's `needs` transformation (the ELEM=BECOMES extension) to the
--- located needs-neighbour. No-op unless the rule actually declared a
--- BECOMES target; presence-only `needs` (no '=') gates the reaction
--- elsewhere and never reaches here.
local function consumeNeedsNeighbour(x, y, r)
    if not (r.needsId and r.needsBecomes) then return end
    local nb = findNeighbourOfType(x, y, r.needsId)
    if not nb then return end
    if r.needsBecomes == "NONE" then
        sim.partKill(nb)
    elseif r.needsBecomesId then
        sim.partChangeType(nb, r.needsBecomesId)
    end
end

--- Bitwise AND of two non-negative 31-bit integers (Lua 5.1 has none; see
--- 10_registry.lua's `bor` for the same reasoning applied to OR).
local function band(a, b)
    local res, place = 0, 1
    for _ = 1, 31 do
        local abit, bbit = a % 2, b % 2
        if abit == 1 and bbit == 1 then res = res + place end
        a, b = (a - abit) / 2, (b - bbit) / 2
        place = place * 2
    end
    return res
end

local PROP_CONDUCTS = (elements and elements.PROP_CONDUCTS) or 0

--- True if the live particle at index `partId` is currently an element with
--- PROP_CONDUCTS set. Reads the flag live off `elements.property`, not a
--- fixed name whitelist, so every conductor -- stock (PSCN, NSCN, METL, ...)
--- and every custom one this catalogue defines (CU, STEL, CHRM, CNT, COBT,
--- NBTI, RCNC, S316, via the `conductor` kind above) -- is recognised
--- automatically, including ones defined after this file loads.
local function isConductor(partId)
    local ty = sim.partProperty(partId, "type")
    if ty == nil then return false end
    local ok, props = pcall(elements.property, ty, "Properties")
    if not ok or type(props) ~= "number" then return false end
    return band(props, PROP_CONDUCTS) ~= 0
end

local SPRK_ID = elements and elements["DEFAULT_PT_SPRK"]
if SPRK_ID == nil then
    PBX.warn("behaviors", "DEFAULT_PT_SPRK not found; teg/turbine/piezo/photovoltaic cannot spark conductors")
end

--- Shared "inject power into the wire" primitive for teg/turbine/piezo/
--- photovoltaic: converts every touching, currently-unsparked (life==0)
--- conductor into a spark, using the exact SPRK convention the `conductor`
--- kind above documents and relies on (ctype := the conductor's own type,
--- life := 4 + extraLife, then sim.partChangeType to SPRK; SPRK's own
--- built-in Update reverts it on its own PROP_LIFE_DEC schedule). Returns
--- the number of neighbours sparked.
local function sparkNeighbourConductors(x, y, extraLife)
    if not SPRK_ID then return 0 end
    local sparked = 0
    for k = 1, 8 do
        local nx, ny = x + NX8[k], y + NY8[k]
        local occ = neighbourOccupant(nx, ny)
        if occ and isConductor(occ) and (sim.partProperty(occ, "life") or 0) == 0 then
            local ty = sim.partProperty(occ, "type")
            sim.partProperty(occ, "ctype", ty)
            sim.partProperty(occ, "life", 4 + (extraLife or 0))
            sim.partChangeType(occ, SPRK_ID)
            sparked = sparked + 1
        end
    end
    return sparked
end

-- ---------------------------------------------------------------------------
-- absorber -- eats a target element (default NEUT) out of the 8-neighbourhood
-- with probability `chance` per neighbour per tick, warming itself
-- `heatPerHit` K per capture. Modelled on control-rod / neutron-poison
-- materials (B4C, CD): a fuel/moderator pairing needs this to be genuinely
-- controllable, not just decorative. See the file-header note above on why
-- this must use neighbourOccupantAny (NEUT is TYPE_ENERGY).
-- ---------------------------------------------------------------------------

local ABSORBER_SPECS = {
    absorbs    = { type = "string", min = 0, max = 32,  default = "NEUT" },
    chance     = { type = "num",    min = 0, max = 1,   default = 0.9 },
    heatPerHit = { type = "num",    min = 0, max = 100,  default = 4 },
}

kinds.absorber = {
    params = ABSORBER_SPECS,
    make = function(params)
        local chance     = pNum(params, "chance", ABSORBER_SPECS.chance)
        local heatPerHit = pNum(params, "heatPerHit", ABSORBER_SPECS.heatPerHit)
        local absorbsRaw = (params and params.absorbs) or ABSORBER_SPECS.absorbs.default
        local targetId = resolveElemName(absorbsRaw)
        if not targetId then
            PBX.warn("behaviors", "absorber: unknown absorbs '" .. tostring(absorbsRaw) .. "', falling back to NEUT")
            targetId = resolveElemName("NEUT")
        end

        return safeUpdate("absorber", function(i, x, y, surround_space, nt)
            if not targetId then return false end
            local hits = 0
            for k = 1, 8 do
                local nx, ny = x + NX8[k], y + NY8[k]
                local occ = neighbourOccupantAny(nx, ny)
                if occ and sim.partProperty(occ, "type") == targetId and chanceRoll(chance) then
                    sim.partKill(occ)
                    hits = hits + 1
                end
            end
            if hits > 0 then
                sim.partProperty(i, "temp", (sim.partProperty(i, "temp") or 293.15) + heatPerHit * hits)
                sim.partProperty(i, "tmp", (sim.partProperty(i, "tmp") or 0) + hits)
            end
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- turbine -- condenses an adjacent `input` (default WTRV, steam) into
-- `output` (default DSTW, condensate) with probability `chance` per
-- neighbour per tick, cooling the converted particle by `cool` K, and sparks
-- every touching conductor once per tick that did any work (mechanical work
-- -> electrical). `tmp` accumulates total conversions as a readable output
-- gauge, matching the description shipped in 07_materials_seed.lua.
-- ---------------------------------------------------------------------------

local TURBINE_SPECS = {
    input  = { type = "string", min = 0, max = 32, default = "WTRV" },
    output = { type = "string", min = 0, max = 32, default = "DSTW" },
    chance = { type = "num",    min = 0, max = 1,  default = 0.25 },
    cool   = { type = "num",    min = 0, max = 500, default = 60 },
}

kinds.turbine = {
    params = TURBINE_SPECS,
    make = function(params)
        local chance = pNum(params, "chance", TURBINE_SPECS.chance)
        local cool   = pNum(params, "cool", TURBINE_SPECS.cool)
        local inputId  = resolveElemName((params and params.input) or TURBINE_SPECS.input.default)
        local outputId = resolveElemName((params and params.output) or TURBINE_SPECS.output.default)
        if not inputId then PBX.warn("behaviors", "turbine: unknown input element") end
        if not outputId then PBX.warn("behaviors", "turbine: unknown output element") end

        return safeUpdate("turbine", function(i, x, y, surround_space, nt)
            if not inputId or not outputId then return false end
            local work = 0
            for k = 1, 8 do
                local nx, ny = x + NX8[k], y + NY8[k]
                local occ = neighbourOccupant(nx, ny)
                if occ and sim.partProperty(occ, "type") == inputId and chanceRoll(chance) then
                    sim.partChangeType(occ, outputId)
                    local ot = sim.partProperty(occ, "temp") or 293.15
                    sim.partProperty(occ, "temp", math.max(293.15, ot - cool))
                    work = work + 1
                end
            end
            if work > 0 then
                sim.partProperty(i, "tmp", (sim.partProperty(i, "tmp") or 0) + work)
                sparkNeighbourConductors(x, y, 0)
            end
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- teg -- thermoelectric generator. Once its own temperature is >= `onTemp`,
-- sparks every touching conductor every `period` ticks (using `life` as the
-- tick counter, since TEG never uses `life` for anything else) and sheds
-- `drop` K per pulse -- Seebeck conversion of a standing temperature
-- difference into a wire pulse.
-- ---------------------------------------------------------------------------

local TEG_SPECS = {
    onTemp = { type = "num", min = 0, max = 9999, default = 373.15 },
    period = { type = "int", min = 1, max = 1000, default = 20 },
    drop   = { type = "num", min = 0, max = 100,  default = 2 },
}

kinds.teg = {
    params = TEG_SPECS,
    make = function(params)
        local onTemp = pNum(params, "onTemp", TEG_SPECS.onTemp)
        local period = pInt(params, "period", TEG_SPECS.period)
        local drop   = pNum(params, "drop", TEG_SPECS.drop)

        return safeUpdate("teg", function(i, x, y, surround_space, nt)
            local t = sim.partProperty(i, "temp") or 0
            if t < onTemp then return false end
            local life = (sim.partProperty(i, "life") or 0) + 1
            if life < period then
                sim.partProperty(i, "life", life)
                return false
            end
            sim.partProperty(i, "life", 0)
            sim.partProperty(i, "temp", t - drop)
            sparkNeighbourConductors(x, y, 0)
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- piezo -- once the ambient pressure magnitude at this cell exceeds
-- `threshold`, sparks every touching conductor every `period` ticks (`life`
-- as the tick counter, `tmp2` as a readable pulse count -- PZT has no other
-- use for either). Pressure is read in CELL space, per addReactionPressure's
-- comment above.
-- ---------------------------------------------------------------------------

local PIEZO_SPECS = {
    threshold = { type = "num", min = 0, max = 256,  default = 4 },
    period    = { type = "int", min = 1, max = 1000, default = 2 },
}

kinds.piezo = {
    params = PIEZO_SPECS,
    make = function(params)
        local threshold = pNum(params, "threshold", PIEZO_SPECS.threshold)
        local period    = pInt(params, "period", PIEZO_SPECS.period)

        return safeUpdate("piezo", function(i, x, y, surround_space, nt)
            local ok, p = pcall(sim.pressure, math.floor(x / 4), math.floor(y / 4))
            if not ok or not p or math.abs(p) < threshold then return false end
            local life = (sim.partProperty(i, "life") or 0) + 1
            if life < period then
                sim.partProperty(i, "life", life)
                return false
            end
            sim.partProperty(i, "life", 0)
            sim.partProperty(i, "tmp2", (sim.partProperty(i, "tmp2") or 0) + 1)
            sparkNeighbourConductors(x, y, 0)
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- photovoltaic -- absorbs adjacent PHOT with probability `chance` per
-- neighbour per tick; every `perSpark` photons absorbed (accumulated in
-- `tmp`), fires one spark pulse into touching conductors. Warms `heat` K per
-- absorbed photon. PHOT is TYPE_ENERGY (src/simulation/elements/PHOT.cpp:39)
-- so this must scan with neighbourOccupantAny, not neighbourOccupant.
-- ---------------------------------------------------------------------------

local PV_SPECS = {
    chance   = { type = "num", min = 0, max = 1,   default = 0.8 },
    perSpark = { type = "int", min = 1, max = 100, default = 3 },
    heat     = { type = "num", min = 0, max = 50,  default = 0.5 },
}

kinds.photovoltaic = {
    params = PV_SPECS,
    make = function(params)
        local chance   = pNum(params, "chance", PV_SPECS.chance)
        local perSpark = pInt(params, "perSpark", PV_SPECS.perSpark)
        local heat     = pNum(params, "heat", PV_SPECS.heat)
        local photId   = resolveElemName("PHOT")

        return safeUpdate("photovoltaic", function(i, x, y, surround_space, nt)
            if not photId then return false end
            local got = 0
            for k = 1, 8 do
                local nx, ny = x + NX8[k], y + NY8[k]
                local occ = neighbourOccupantAny(nx, ny)
                if occ and sim.partProperty(occ, "type") == photId and chanceRoll(chance) then
                    sim.partKill(occ)
                    got = got + 1
                end
            end
            if got > 0 then
                sim.partProperty(i, "temp", (sim.partProperty(i, "temp") or 293.15) + heat * got)
                local acc = (sim.partProperty(i, "tmp") or 0) + got
                if acc >= perSpark then
                    acc = acc - perSpark
                    sparkNeighbourConductors(x, y, 0)
                end
                sim.partProperty(i, "tmp", acc)
            end
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- pcm -- phase-change heat buffer. Above `meltK` it soaks up to `rate` K/tick
-- of excess heat into a stored-energy counter (`tmp`, capped at `latent`),
-- holding its own temperature near meltK while charging; below `meltK` with
-- stored energy remaining, it releases stored heat back at the same rate,
-- holding temperature near meltK while discharging. Approximates latent
-- heat without a real enthalpy model.
-- ---------------------------------------------------------------------------

local PCM_SPECS = {
    meltK  = { type = "num", min = 100, max = 2000,   default = 331.15 },
    latent = { type = "int", min = 1,   max = 100000, default = 2000 },
    rate   = { type = "num", min = 0.1, max = 50,     default = 4 },
}

kinds.pcm = {
    params = PCM_SPECS,
    make = function(params)
        local meltK  = pNum(params, "meltK", PCM_SPECS.meltK)
        local latent = pInt(params, "latent", PCM_SPECS.latent)
        local rate   = pNum(params, "rate", PCM_SPECS.rate)

        return safeUpdate("pcm", function(i, x, y, surround_space, nt)
            local t = sim.partProperty(i, "temp") or meltK
            local stored = sim.partProperty(i, "tmp") or 0
            if t > meltK and stored < latent then
                local take = math.min(rate, t - meltK, latent - stored)
                sim.partProperty(i, "temp", t - take)
                sim.partProperty(i, "tmp", stored + take)
            elseif t < meltK and stored > 0 then
                local give = math.min(rate, meltK - t, stored)
                sim.partProperty(i, "temp", t + give)
                sim.partProperty(i, "tmp", stored - give)
            end
            return false
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- reactive -- small chemistry DSL. `params.rules` is a ';'-separated list of:
--
--   TRIGGER>selfBecomes,otherBecomes:dT:chance[:needs][:extra][:conc=N][:pgas=X]
--
--   TRIGGER      neighbour element that triggers the rule, or ANY (any
--                occupied neighbour), AIR (any empty neighbour), or HEATn
--                (fires from self temperature alone at self.temp >= n, no
--                neighbour needed -- otherBecomes is meaningless here)
--   selfBecomes  what this particle becomes: SELF (unchanged), NONE
--                (killed), or an element name
--   otherBecomes same vocabulary, applied to the trigger neighbour
--   dT           temperature delta (K) applied to both particles on a hit
--   chance       per-neighbour, per-tick probability
--   needs        optional second required neighbour: ELEM (must be
--                present), ELEM=BECOMES (present AND itself transformed on a
--                hit, NONE = killed), or HEATn (self-temperature gate)
--   extra        element spawned into a free neighbouring cell on a hit
--   conc=N       (any trailing field, order-independent) treat `life` as a
--                concentration: decrement by N per hit, scale chance by
--                life/100, only actually apply selfBecomes once life reaches 0
--   pgas=X       (any trailing field, order-independent) add X directly to
--                sim.pressure at the reacting cell
--
-- Rules are tried in listed order each tick; the closure returns as soon as
-- one rule's neighbour scan actually rolls a hit (matching this file's
-- return-true-or-false-and-stop convention for every other kind), but a
-- rule whose trigger neighbour is present yet loses its own chance roll
-- falls through to let the next rule try the same tick -- this is what lets
-- AL61 attempt its BRMT/thermite rule on a tick where its FIRE-preheat rule
-- happened not to roll a hit, without waiting a full extra tick.
--
-- Verified against every `reactive` spec actually shipped
-- (bridge_src/07_materials_seed.lua, 9 elements: AL61, BRSS, CAC2, CAO, DU,
-- MG, NA, NAS, RBAR) -- all nine parse and, by inspection against their own
-- prose descriptions in that file, behave as documented there.
-- ---------------------------------------------------------------------------

local function parseReactiveRules(str)
    local rules = {}
    for rule in string.gmatch(str or "", "[^;]+") do
        local with, rest = rule:match("^%s*([%w_<>]+)%s*>(.*)$")
        if with then
            -- Split on ':' keeping empty fields; gmatch("[^:]*") over-yields
            -- on adjacent separators, so this walks the string by hand.
            local f, start = {}, 1
            while true do
                local sep = string.find(rest, ":", start, true)
                if not sep then f[#f + 1] = string.sub(rest, start); break end
                f[#f + 1] = string.sub(rest, start, sep - 1)
                start = sep + 1
            end

            local prod = f[1] or ""
            local selfB, otherB = prod:match("^%s*([%w_]+)%s*,%s*([%w_]+)%s*$")
            local r = {
                with   = string.upper(with),
                selfB  = string.upper(selfB or "SELF"),
                otherB = string.upper(otherB or "SELF"),
                dT     = tonumber(f[2]) or 0,
                chance = tonumber(f[3]) or 0.2,
                needs  = (f[4] and f[4] ~= "") and string.upper(f[4]) or nil,
                extra  = (f[5] and f[5] ~= "") and string.upper(f[5]) or nil,
            }

            local heatK = r.with:match("^HEAT(%d+)$")
            if heatK then r.heatK = tonumber(heatK); r.with = "HEAT" end
            r.withId  = (r.with ~= "ANY" and r.with ~= "HEAT" and r.with ~= "AIR") and resolveElemName(r.with) or nil
            r.selfId  = (r.selfB  ~= "SELF" and r.selfB  ~= "NONE") and resolveElemName(r.selfB)  or nil
            r.otherId = (r.otherB ~= "SELF" and r.otherB ~= "NONE") and resolveElemName(r.otherB) or nil

            if r.needs then
                local needsHeat = r.needs:match("^HEAT(%d+)$")
                if needsHeat then
                    r.needsHeatK = tonumber(needsHeat)
                else
                    local ne, nb = r.needs:match("^([%w_]+)=([%w_]+)$")
                    if ne then
                        r.needsId = resolveElemName(ne)
                        r.needsBecomes = string.upper(nb)
                        r.needsBecomesId = (r.needsBecomes ~= "NONE" and r.needsBecomes ~= "SELF")
                                           and resolveElemName(r.needsBecomes) or nil
                    else
                        r.needsId = resolveElemName(r.needs)
                    end
                end
            end
            r.extraId = r.extra and resolveElemName(r.extra) or nil

            -- conc=/pgas= are scanned by prefix across every trailing field,
            -- not a fixed position, so they can be appended without
            -- disturbing the first five positional fields.
            for idx = 6, #f do
                local field = f[idx]
                if field and field ~= "" then
                    local concN = field:match("^conc=([%d%.]+)$")
                    local pgasX = field:match("^pgas=(%-?[%d%.]+)$")
                    if concN then r.conc = tonumber(concN) end
                    if pgasX then r.pgas = tonumber(pgasX) end
                end
            end

            rules[#rules + 1] = r
        end
    end
    return rules
end

kinds.reactive = {
    params = { rules = { type = "string", min = 0, max = 2000, default = "" } },
    make = function(params)
        local rules = parseReactiveRules(params and params.rules)

        return safeUpdate("reactive", function(i, x, y, surround_space, nt)
            local myT = sim.partProperty(i, "temp") or 293.15

            for ri = 1, #rules do
                local r = rules[ri]

                if r.with == "HEAT" then
                    if myT >= (r.heatK or 1e9) and chanceRoll(r.chance) then
                        if r.extraId then
                            local fx, fy = freeNeighbourCell(x, y)
                            if fx then
                                local n = sim.partCreate(-1, fx, fy, r.extraId)
                                if n and n >= 0 then sim.partProperty(n, "temp", myT + r.dT) end
                            end
                        end
                        addReactionPressure(x, y, r.pgas)
                        sim.partProperty(i, "temp", myT + r.dT)
                        if r.conc then
                            local life = (sim.partProperty(i, "life") or 100) - r.conc
                            sim.partProperty(i, "life", math.max(0, life))
                            if life > 0 then return false end
                        end
                        if r.selfB == "NONE" then
                            sim.partKill(i)
                            return true
                        elseif r.selfId then
                            sim.partChangeType(i, r.selfId)
                            return false
                        end
                        -- selfB == "SELF": no change to this particle; fall
                        -- through so a later rule can still fire this same
                        -- tick, matching the neighbour branch below (which
                        -- only stops the closure on an actual hit).
                    end
                else
                    local effChance = r.chance
                    if r.conc then effChance = r.chance * ((sim.partProperty(i, "life") or 100) / 100) end

                    for k = 1, 8 do
                        local nx, ny = x + NX8[k], y + NY8[k]
                        local occ = neighbourOccupantAny(nx, ny)
                        local hit = false
                        if r.with == "AIR" then
                            hit = (occ == nil)
                        elseif r.with == "ANY" then
                            hit = (occ ~= nil)
                        elseif occ and r.withId then
                            hit = (sim.partProperty(occ, "type") == r.withId)
                        end

                        if hit and chanceRoll(effChance)
                           and (not r.needsId or findNeighbourOfType(x, y, r.needsId))
                           and (not r.needsHeatK or myT >= r.needsHeatK) then
                            local ot = occ and (sim.partProperty(occ, "temp") or myT) or myT
                            local producedExtra = false

                            if occ then
                                if r.otherB == "NONE" and r.extraId and not freeNeighbourCell(x, y) then
                                    -- No free cell for the extra product: turn
                                    -- the consumed neighbour directly into it
                                    -- instead of losing the reaction outright.
                                    sim.partChangeType(occ, r.extraId)
                                    sim.partProperty(occ, "temp", myT + r.dT)
                                    producedExtra = true
                                elseif r.otherB == "NONE" then
                                    sim.partKill(occ)
                                elseif r.otherId then
                                    sim.partChangeType(occ, r.otherId)
                                    sim.partProperty(occ, "temp", ot + r.dT)
                                else
                                    sim.partProperty(occ, "temp", ot + r.dT)
                                end
                            end

                            if r.extraId and not producedExtra then
                                local fx, fy = freeNeighbourCell(x, y)
                                if fx then
                                    local n = sim.partCreate(-1, fx, fy, r.extraId)
                                    if n and n >= 0 then sim.partProperty(n, "temp", myT + r.dT) end
                                end
                            end

                            consumeNeedsNeighbour(x, y, r)
                            addReactionPressure(x, y, r.pgas)
                            sim.partProperty(i, "tmp2", (sim.partProperty(i, "tmp2") or 0) + 1)

                            if r.conc then
                                local life = (sim.partProperty(i, "life") or 100) - r.conc
                                sim.partProperty(i, "life", math.max(0, life))
                                if life > 0 then
                                    sim.partProperty(i, "temp", myT + r.dT)
                                    return false
                                end
                            end

                            if r.selfB == "NONE" then
                                sim.partKill(i)
                                return true
                            elseif r.selfId then
                                sim.partChangeType(i, r.selfId)
                                sim.partProperty(i, "temp", myT + r.dT)
                                return false
                            else
                                sim.partProperty(i, "temp", myT + r.dT)
                            end
                            return false
                        end
                    end
                end
            end

            return false
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
