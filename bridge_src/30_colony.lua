-- ===========================================================================
-- 30_colony.lua -- Colony state layer (PBX.state.colony)
--
-- A colony is the shared record worker ants belong to: a name, a nest
-- location, a tint colour applied to worker `dcolour`, a pheromone field the
-- workers navigate by, and a store of delivered material. This module owns
-- PBX.state.colony exclusively (00_util.lua section 2.7); other modules may
-- read it but must go through the functions published here to write it, so
-- counters and persistence stay consistent.
--
-- Spec: EXTENSION_SPEC.md section 4.3. Field layout: EXTENSION_SPEC.md
-- section 3 (tmp3 = colony id, dcolour = colony tint, both owned by us but
-- written through PBX.getColony/setColony so the tmp3-vs-tmp2-nibble
-- fallback in 00_util keeps working).
-- ===========================================================================

local PBX = _G.PBX

-- colonies[id] = {
--   id, name, nest = {x,y}, colour, pheromoneDecay,
--   store = { [tostring(elemId)] = count },   -- string keys, see note below
--   phero  = { [cy*CELL_W+cx] = amount },     -- sparse, NEVER persisted
--   createdTick, spawned, died, delivered,
-- }
local colonies = {}

-- ---------------------------------------------------------------------------
-- Element id -> readable name, for colonyStatus's store map. This is an
-- occasional/O(elements) lookup (colonyStatus is polled, not per-tick), so a
-- small memo cache is enough; not worth building a reverse table eagerly
-- since custom elements can be (re)defined at runtime by 10_registry.lua.
-- ---------------------------------------------------------------------------

local elemNameCache = {}

--- Best-effort element id -> short display name (registry prefixes stripped).
--- Never errors: falls back to "elem<id>" if the elements table is odd.
local function elemName(id)
    local cached = elemNameCache[id]
    if cached then return cached end
    local ok, nm = pcall(function()
        if type(elements) ~= "table" then return "elem" .. tostring(id) end
        for name, eid in pairs(elements) do
            if type(name) == "string" and eid == id then
                return (name:gsub("^DEFAULT_PT_", ""):gsub("^PBX_PT_", ""))
            end
        end
        return "elem" .. tostring(id)
    end)
    nm = (ok and nm) or ("elem" .. tostring(id))
    elemNameCache[id] = nm
    return nm
end

-- ---------------------------------------------------------------------------
-- Persistence. Colony records survive a restart; the pheromone field does
-- not (task explicitly calls this out -- it is transient navigation state,
-- not worth the file size, and stale trails from a previous run are not
-- useful anyway).
-- ---------------------------------------------------------------------------

--- Build the on-disk shape: an array of colony records, phero grid excluded.
local function serializeColonies()
    local out = PBX.arr({})
    local ids = {}
    for id in pairs(colonies) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do
        local c = colonies[ids[i]]
        out[#out + 1] = {
            id = c.id, name = c.name,
            nest = { x = c.nest.x, y = c.nest.y },
            colour = c.colour, pheromoneDecay = c.pheromoneDecay,
            store = c.store, createdTick = c.createdTick,
            spawned = c.spawned, died = c.died, delivered = c.delivered,
            deathsByCause = c.deathsByCause,
        }
    end
    return out
end

local function persistColonies()
    PBX.save("colonies", serializeColonies())
end

-- Restore colony records on load. Runs once at require-time (this file is
-- concatenated into autorun.lua, so this executes once at TPT startup).
do
    local raw = PBX.load("colonies")
    local restored = 0
    if type(raw) == "table" then
        for _, rec in ipairs(raw) do
            if type(rec) == "table" and tonumber(rec.id) then
                local id = math.floor(tonumber(rec.id))
                if id >= 1 and id <= PBX.MAX_COLONIES then
                    local nest = type(rec.nest) == "table" and rec.nest or {}
                    local store = {}
                    if type(rec.store) == "table" then
                        for k, v in pairs(rec.store) do
                            local n = tonumber(v)
                            if n then store[tostring(k)] = math.floor(n) end
                        end
                    end
                    local deathsByCause = {}
                    if type(rec.deathsByCause) == "table" then
                        for k, v in pairs(rec.deathsByCause) do
                            local n = tonumber(v)
                            if n and type(k) == "string" then deathsByCause[k] = math.floor(n) end
                        end
                    end
                    colonies[id] = {
                        id = id,
                        name = tostring(rec.name or ("colony" .. id)),
                        nest = { x = tonumber(nest.x) or 0, y = tonumber(nest.y) or 0 },
                        colour = tonumber(rec.colour) or 0xFFFFFFFF,
                        pheromoneDecay = tonumber(rec.pheromoneDecay) or 0.05,
                        store = store,
                        phero = {},  -- deliberately not restored, see above
                        createdTick = tonumber(rec.createdTick) or 0,
                        spawned = tonumber(rec.spawned) or 0,
                        died = tonumber(rec.died) or 0,
                        delivered = tonumber(rec.delivered) or 0,
                        deathsByCause = deathsByCause,
                    }
                    restored = restored + 1
                end
            end
        end
    end
    PBX.log("colony", "restored " .. restored .. " colonies from disk")
end

-- ---------------------------------------------------------------------------
-- Pheromone grid.
--
-- Decay strategy: SPARSE TABLE, not row-slicing.
--
-- Each colony's grid is a plain Lua table keyed by `cy*CELL_W+cx`, holding
-- only cells that currently have a non-zero amount -- there is no
-- pre-allocated 153x96 array at all. The per-tick decay hook below iterates
-- `pairs(grid)`, so its cost is O(active cells), never O(153*96). A fresh
-- colony's grid starts empty and only grows as workers actually deposit, and
-- decay removes an entry outright once it drops under 0.01 (the floor the
-- task specifies), so the active set is naturally self-limiting -- it can
-- never be bigger than "cells someone deposited into recently", which for an
-- ant trail is a small fraction of the 14688-cell grid.
--
-- Row-slicing (decay 1/8 of rows per tick on a rolling cursor) was the other
-- option the task offered. It was rejected because it still touches every
-- cell in the grid once per 8 ticks regardless of whether that cell has ever
-- been deposited into -- for a colony that has only laid a short trail near
-- its nest, slicing wastes almost all of that work on cells that are already
-- and will remain zero. The sparse table costs nothing for a cell nobody has
-- ever touched, which matches the actual access pattern of an ant colony far
-- better than "eventually touch the whole grid on a fixed schedule".
-- deposit()/phero()/gradient() below are direct key lookups on the same
-- table, so this doubles as the storage for the read side too -- no separate
-- flat array to keep in sync.
-- ---------------------------------------------------------------------------

local CELL_W, CELL_H = PBX.CELL_W, PBX.CELL_H

--- Coerce a coordinate to an integer cell index, or nil if it isn't numeric.
local function toCell(v)
    v = tonumber(v)
    if not v then return nil end
    return math.floor(v)
end

--- Current pheromone amount at (cx,cy) for colonyId. 0 if the colony doesn't
--- exist, the cell is out of range, or nothing has been deposited there.
function PBX.state.colony.phero(colonyId, cx, cy)
    local col = colonies[tonumber(colonyId)]
    if not col then return 0 end
    cx, cy = toCell(cx), toCell(cy)
    if not cx or not cy then return 0 end
    if cx < 0 or cx >= CELL_W or cy < 0 or cy >= CELL_H then return 0 end
    return col.phero[cy * CELL_W + cx] or 0
end

--- Add `amount` to the cell (clamped 0..100). Silently a no-op for a bad
--- colony/cell -- this is called from the worker tick loop, it must never
--- error and callers do not check a return value for validity.
function PBX.state.colony.deposit(colonyId, cx, cy, amount)
    local col = colonies[tonumber(colonyId)]
    if not col then return 0 end
    cx, cy = toCell(cx), toCell(cy)
    if not cx or not cy then return 0 end
    if cx < 0 or cx >= CELL_W or cy < 0 or cy >= CELL_H then return 0 end
    local key = cy * CELL_W + cx
    local v = (col.phero[key] or 0) + (tonumber(amount) or 0)
    if v > 100 then v = 100 end
    if v < 0 then v = 0 end
    col.phero[key] = v
    return v
end

--- Direction (dx,dy in {-1,0,1}) toward the strongest of the 8 neighbours of
--- (cx,cy), or 0,0 if every neighbour is empty (or out of range). This is the
--- routine workers call every tick to find their way, so it is written to be
--- allocation-free: only numeric locals, no table construction, and it reads
--- directly from the sparse grid table rather than any derived structure.
function PBX.state.colony.gradient(colonyId, cx, cy)
    local col = colonies[tonumber(colonyId)]
    if not col then return 0, 0 end
    cx, cy = toCell(cx), toCell(cy)
    if not cx or not cy then return 0, 0 end
    local grid = col.phero
    local bestDx, bestDy, bestV = 0, 0, 0.01  -- floor matches the decay cutoff
    for dy = -1, 1 do
        local ny = cy + dy
        if ny >= 0 and ny < CELL_H then
            local rowBase = ny * CELL_W
            for dx = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local nx = cx + dx
                    if nx >= 0 and nx < CELL_W then
                        local v = grid[rowBase + nx]
                        if v and v > bestV then
                            bestV, bestDx, bestDy = v, dx, dy
                        end
                    end
                end
            end
        end
    end
    return bestDx, bestDy
end

--- Per-tick decay hook: multiply every currently-active cell by
--- (1-pheromoneDecay), dropping it from the table below the 0.01 floor.
--- Registered with PBX.onTick, so 00_util already pcalls this for us and
--- disables it after 20 failures -- no extra guard needed here.
local function decayTick()
    for _, col in pairs(colonies) do
        local decay = 1 - col.pheromoneDecay
        local grid = col.phero
        for k, v in pairs(grid) do
            v = v * decay
            -- Setting an existing key to nil mid-pairs() is well-defined in
            -- Lua 5.1 (only *adding new* keys during traversal is not).
            if v < 0.01 then grid[k] = nil else grid[k] = v end
        end
    end
end

PBX.onTick("colony", decayTick)

--- Highest pheromone value currently on a colony's grid (0 if empty).
--- Only walks the active set, same reasoning as decayTick.
local function pheromonePeak(col)
    local peak = 0
    for _, v in pairs(col.phero) do
        if v > peak then peak = v end
    end
    return peak
end

-- ---------------------------------------------------------------------------
-- Store accounting. Tasks with source="store" (buildLine/Box/Circle/
-- Blueprint) draw from here; gather tasks deposit into it.
--
-- Keys are tostring(elemId) rather than the raw numeric id. PBX.encode's
-- object branch only emits string-keyed tables (see 00_util's isArray /
-- encodeValue) -- a numeric-keyed map would silently encode as {} since none
-- of its keys pass the `type(k) == "string"` filter. Keeping the internal
-- representation string-keyed means colony persistence round-trips cleanly
-- through PBX.save/PBX.load without a special case.
-- ---------------------------------------------------------------------------

--- Add n (floored, >=0) units of elemId to the colony store. Returns the new
--- total for that element (0 if the colony doesn't exist).
function PBX.state.colony.addStore(colonyId, elemId, n)
    local col = colonies[tonumber(colonyId)]
    local id = tonumber(elemId)
    n = tonumber(n)
    if not col or not id or not n or n <= 0 then return col and (col.store[tostring(math.floor(id or 0))] or 0) or 0 end
    n = math.floor(n)
    local key = tostring(math.floor(id))
    local total = (col.store[key] or 0) + n
    col.store[key] = total
    col.delivered = col.delivered + n
    persistColonies()
    return total
end

--- Take up to n units of elemId out of the store. Returns how many were
--- actually available and removed (may be less than n, never more).
function PBX.state.colony.takeStore(colonyId, elemId, n)
    local col = colonies[tonumber(colonyId)]
    local id = tonumber(elemId)
    n = tonumber(n)
    if not col or not id or not n or n <= 0 then return 0 end
    n = math.floor(n)
    local key = tostring(math.floor(id))
    local have = col.store[key] or 0
    local taken = math.min(have, n)
    if taken > 0 then
        col.store[key] = have - taken
        persistColonies()
    end
    return taken
end

-- ---------------------------------------------------------------------------
-- Lifetime counters. Colony owns PBX.state.colony (section 2.7: other
-- modules may read it but not write it), yet worker/task modules are the
-- ones that know when a spawn or death happens. So the task's "counters
-- (spawned, died)" requirement is served through these two setter functions
-- rather than by letting other modules poke colonies[id].spawned directly --
-- that keeps the "only colony writes colony state" rule intact while still
-- letting 40_worker.lua report what it did. (This pair isn't named in the
-- spec's action/response tables; it's the natural extension of "you own the
-- counters" once another module needs to move them. Flagging it as an
-- interpretation.)
-- ---------------------------------------------------------------------------

--- Record that n workers were spawned for colonyId (lifetime counter).
function PBX.state.colony.recordSpawned(colonyId, n)
    local col = colonies[tonumber(colonyId)]
    n = tonumber(n)
    if not col or not n or n <= 0 then return end
    col.spawned = col.spawned + math.floor(n)
    persistColonies()
end

--- Record that n workers died/despawned for colonyId (lifetime counter).
function PBX.state.colony.recordDied(colonyId, n, cause)
    local col = colonies[tonumber(colonyId)]
    n = tonumber(n)
    if not col or not n or n <= 0 then return end
    col.died = col.died + math.floor(n)
    cause = cause or "despawned"
    col.deathsByCause = col.deathsByCause or {}
    col.deathsByCause[cause] = (col.deathsByCause[cause] or 0) + math.floor(n)
    persistColonies()
end

-- ---------------------------------------------------------------------------
-- Registry helpers for other modules.
-- ---------------------------------------------------------------------------

--- The raw colony record for id, or nil. Callers must not write fields on
--- the returned table (see the ownership note above); it's exposed for
--- reading (e.g. worker module checking pheromoneDecay or nest position).
function PBX.state.colony.get(id)
    return colonies[tonumber(id)]
end

--- All colony records, sorted by id.
function PBX.state.colony.all()
    local ids = {}
    for id in pairs(colonies) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for i = 1, #ids do out[i] = colonies[ids[i]] end
    return out
end

--- Nest pixel position for id, or nil,nil if the colony doesn't exist.
function PBX.state.colony.nest(id)
    local col = colonies[tonumber(id)]
    if not col then return nil, nil end
    return col.nest.x, col.nest.y
end

-- ---------------------------------------------------------------------------
-- Actions.
-- ---------------------------------------------------------------------------

--- colonyCreate: validates the nest is inside the sim, enforces MAX_COLONIES,
--- assigns the lowest free id 1..MAX_COLONIES. No element/particle touches,
--- so (unlike destroy-with-kill) this can run synchronously in the handler.
PBX.register("colonyCreate", function(req, ctx)
    local name, e = PBX.vStr(req.name, "name", 40)
    if e then return PBX.err(e) end
    if name == "" then return PBX.err("name must not be empty") end

    local nestX, nestY, e2 = PBX.vPixel(req.nestX, req.nestY)
    if e2 then return PBX.err(e2) end

    local colour = req.colour
    if colour == nil then colour = 0xFFFFFFFF end
    colour, e = PBX.vInt(colour, "colour", 0, 4294967295)
    if e then return PBX.err(e) end

    local decay = req.pheromoneDecay
    if decay == nil then decay = 0.05 end
    decay, e = PBX.vNum(decay, "pheromoneDecay", 0, 1)
    if e then return PBX.err(e) end

    local count = 0
    for _ in pairs(colonies) do count = count + 1 end
    if count >= PBX.MAX_COLONIES then
        return PBX.err("max colonies reached (" .. PBX.MAX_COLONIES .. ")")
    end

    local id
    for cand = 1, PBX.MAX_COLONIES do
        if not colonies[cand] then id = cand; break end
    end
    if not id then return PBX.err("no free colony id") end  -- unreachable given the count check above

    colonies[id] = {
        id = id, name = name,
        nest = { x = nestX, y = nestY },
        colour = colour, pheromoneDecay = decay,
        store = {}, phero = {}, deathsByCause = {},
        createdTick = PBX.tickIndex,
        spawned = 0, died = 0, delivered = 0,
    }
    persistColonies()
    return PBX.ok("colonyCreate", { colonyId = id })
end, "colony")

--- colonyList: summary of every colony, no pheromone grid (that's per-cell
--- internal state, not something a caller lists).
PBX.register("colonyList", function(req, ctx)
    local out = PBX.arr({})
    local list = PBX.state.colony.all()
    for i = 1, #list do
        local c = list[i]
        out[#out + 1] = {
            id = c.id, name = c.name,
            nest = { x = c.nest.x, y = c.nest.y },
            colour = c.colour, pheromoneDecay = c.pheromoneDecay,
            createdTick = c.createdTick,
            spawned = c.spawned, died = c.died, delivered = c.delivered,
        }
    end
    return PBX.ok("colonyList", { colonies = out })
end, "colony")

--- colonyStatus: workers/alive/carrying come from 40_worker.lua, which may
--- not be loaded (e.g. mid-build, or this module tested standalone) --
--- tolerated per spec, reported as 0 with a `note`. `workers` is the colony's
--- own lifetime spawn counter (interpretation: distinct from the worker
--- module's live `alive` count, since both are useful and the spec lists
--- them as separate fields). `tasks` similarly comes from PBX.state.tasks,
--- tolerated absent (empty array, no note required by spec for that one).
PBX.register("colonyStatus", function(req, ctx)
    local id, e = PBX.vInt(req.colonyId, "colonyId", 1, PBX.MAX_COLONIES)
    if e then return PBX.err(e) end
    local col = colonies[id]
    if not col then return PBX.err("unknown colonyId: " .. tostring(id)) end

    local alive, carrying, note = 0, 0, nil
    local w = PBX.state.worker
    if type(w) == "table" and type(w.colonyStats) == "function" then
        local ok, stats = pcall(w.colonyStats, id)
        if ok and type(stats) == "table" then
            alive = tonumber(stats.alive) or 0
            carrying = tonumber(stats.carrying) or 0
        else
            note = "worker module stats unavailable"
        end
    elseif type(w) == "table" and type(w.count) == "function" then
        -- 40_worker publishes count(colonyId, exact) rather than colonyStats;
        -- an exact count walks the particle table, which is what "alive" means.
        local ok, n = pcall(w.count, id, true)
        alive = ok and tonumber(n) or 0
    else
        note = "worker module not loaded"
    end

    local storeOut = {}
    for k, v in pairs(col.store) do
        local eid = tonumber(k)
        storeOut[eid and elemName(eid) or k] = v
    end

    local tasksOut = PBX.arr({})
    local t = PBX.state.tasks
    if type(t) == "table" and type(t.forColony) == "function" then
        local ok, list = pcall(t.forColony, id)
        if ok and type(list) == "table" then tasksOut = list end
    end

    local resp = {
        workers = col.spawned, alive = alive, carrying = carrying,
        store = storeOut, tasks = tasksOut,
        nest = { x = col.nest.x, y = col.nest.y },
        pheromonePeak = pheromonePeak(col),
        deathsByCause = col.deathsByCause or {},
    }
    if note then resp.note = note end
    return PBX.ok("colonyStatus", resp)
end, "colony")

--- colonyDestroy: killWorkers=false drops the record synchronously (no
--- particle touch, safe in the handler). killWorkers=true must defer --
--- it scans particle slots and calls sim.partKill, which is exactly the
--- "touches many particles" case section 2.4 requires to run off the
--- socket thread. The colony record itself is removed once the sweep
--- finishes, inside the deferred job, so a status query for a pending
--- destroy still sees the colony (and its workers) rather than a half
--- torn-down state.
PBX.register("colonyDestroy", function(req, ctx)
    local id, e = PBX.vInt(req.colonyId, "colonyId", 1, PBX.MAX_COLONIES)
    if e then return PBX.err(e) end
    local col = colonies[id]
    if not col then return PBX.err("unknown colonyId: " .. tostring(id)) end

    local killWorkers, e2 = PBX.vBool(req.killWorkers, "killWorkers", false)
    if e2 then return PBX.err(e2) end

    if not killWorkers then
        colonies[id] = nil
        persistColonies()
        return PBX.ok("colonyDestroy", { destroyed = true })
    end

    local jobId = PBX.defer(function()
        local killed = 0
        local slotBound = (sim.XRES or PBX.SIM_W) * (sim.YRES or PBX.SIM_H)
        for i = 0, slotBound - 1 do
            local existsOk, exists = pcall(sim.partExists, i)
            if existsOk and exists then
                local colOk, cid = pcall(PBX.getColony, i)
                if colOk and cid == id then
                    pcall(sim.partKill, i)
                    killed = killed + 1
                end
            end
        end
        colonies[id] = nil
        persistColonies()
        return { destroyed = true, killed = killed }
    end)
    return PBX.ok("colonyDestroy", { job = jobId, status = "pending" })
end, "colony")

PBX.state.colony.VERSION = "1.0.0"
PBX.log("colony", "PBX.state.colony " .. PBX.state.colony.VERSION .. " loaded")
