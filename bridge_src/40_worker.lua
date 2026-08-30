-- ===========================================================================
-- 40_worker.lua -- Powder Bridge Extension: the worker creature ("the ant")
--
-- Owns:
--   actions  colonySpawnWorkers, colonyKillWorkers
--   state    PBX.state.worker.{update, count, list, elementId, VERSION}
--
-- A worker is one particle of a custom element that 10_registry.lua allocated
-- with behavior {kind="creature"}.  20_behaviors.lua's `creature` kind installs
-- PBX.state.worker.update (below) as that element's Update function, so this
-- file never allocates an element itself -- it only looks one up.
--
-- The element must be TYPE_SOLID with no gravity and no advection: every step
-- an ant takes is written by hand, at most one cell per tick, and only into a
-- pixel we have already proven empty.  That is what stops two ants sharing a
-- pixel and what keeps the position map honest (see stepToward).
--
-- ---------------------------------------------------------------------------
-- THE CONTRACT WE CALL 50_tasks.lua WITH   (match this, please)
-- ---------------------------------------------------------------------------
-- Every entry point below is optional.  If PBX.state.tasks is absent, or
-- forWorker is missing, or a field we expect is nil, the ant degrades to
-- WANDER instead of erroring.
--
--   PBX.state.tasks.forWorker(i, colonyId, taskId)
--       Asked for particle `i` roughly every TASK_REFRESH (12) ticks -- NOT
--       every frame -- plus immediately after anything that invalidates the
--       previous answer (pickup, deposit, task id change).  Return EITHER
--
--         a table { mode      = "seek"|"deliver"|"dig"|"patrol"|"fetch",
--                   tx        = <pixel x>,      -- nil/absent => "no target"
--                   ty        = <pixel y>,
--                   element   = <id or name>,   -- what to carry / dig / place
--                   cellIndex = <blueprint cell index, 0 = not a cell task>,
--                   source    = "store"|"spawn"|nil }
--
--       OR, allocation-free and preferred, the flat tuple
--
--         mode, tx, ty, element, cellIndex          (source defaults to nil)
--
--       A returned table costs one allocation per call: with 8 colonies of 400
--       ants that is ~270 tables per frame, so if you return a table please
--       return ONE reused scratch table rather than a fresh one each time.
--       Returning nil / false / anything else means "nothing to do" and the
--       ant wanders.
--
--   PBX.state.tasks.complete(i, taskId, cellIndex)
--       The ant finished its unit of work: material placed on a claimed cell,
--       a dig target destroyed, a patrol point reached, or a gather load
--       handed to the nest (cellIndex is 0 in that last case).  We clear our
--       claim token immediately afterwards.
--
--   PBX.state.tasks.release(i, taskId)
--       The ant abandoned the work: it starved, colonyKillWorkers took it, or
--       its colony was destroyed.  Free the claim slot.
--
-- Modes we implement:
--   seek     walk to (tx,ty), pick up the first `element` touched -> HAUL
--   deliver  walk to (tx,ty) / the claimed cell and put the cargo down.  When
--            called empty-handed with `element` set, source=="spawn" (or no
--            source at all) materialises it into ctype -- spec 4.5's cheap
--            construction mode; source=="store" debits the colony store and
--            declines when the store is empty.
--   dig      walk to (tx,ty), destroy the first `element` touched.  element
--            0/nil means "anything that is not one of our own ants".
--   fetch    walk to (tx,ty) -- normally the nest -- and load `element` there
--            honouring `source`.  An optional extension: a task engine that
--            only emits the four spec modes never needs it.
--   patrol   walk to (tx,ty) and report complete on arrival, so you can
--            advance to the next point.
--
-- Claim tokens: forWorker owns the decision, we own the write.  When a
-- cellIndex comes back we stamp PBX.setClaim(i, cellIndex + 1) -- spec 3's
-- "cell index +1, or 0 when unclaimed" -- and clear it to 0 on completion or
-- death, including death by starvation or by colonyKillWorkers.
--
-- ---------------------------------------------------------------------------
-- WHY MOMENTUM IS NOT IN pavg0 / pavg1 ON THIS BUILD
-- ---------------------------------------------------------------------------
-- Spec section 3 gives pavg0/pavg1 to the worker for last-dx/last-dy, and
-- tmp3/tmp4 to colony/tasks.  In this TPT tree those are the SAME STORAGE:
-- src/simulation/Particle.cpp GetPropertyAliases() maps pavg0 -> tmp3 and
-- pavg1 -> tmp4, and Particle.h has no pavg members at all (the float pavg[2]
-- pair was renamed to tmp3/tmp4 and the old names kept as save-compat
-- aliases).  Writing a heading into pavg0 would silently destroy the colony id
-- that PBX.getColony reads back out of tmp3.
--
-- PBX.hasTmp34 is exactly the right discriminator: a build that HAS tmp3/tmp4
-- is a build where pavg0/pavg1 alias them, and a build without tmp3/tmp4 is an
-- older one where the pavg fields are genuinely independent.  So
--   hasTmp34 == false -> momentum lives in pavg0/pavg1, exactly as spec'd
--   hasTmp34 == true  -> momentum lives in this module's scalar arrays
-- Either way no other module's column is touched and the accessors stay the
-- only route to tmp2/tmp3/tmp4.
--
-- ---------------------------------------------------------------------------
-- HOT PATH  (up to 8 x 400 = 3200 Update calls every frame)
-- ---------------------------------------------------------------------------
-- Rules held to throughout the update path: no table constructor, no string
-- concatenation, no closure creation, no pcall per particle.  The specific
-- choices, each also explained where it appears:
--   * every sim.* / PBX.* entry point is hoisted to a file-local, so a call
--     costs an upvalue read rather than a global hash plus a field hash
--   * position is never read back: TPT already hands x,y to Update
--   * numeric particle-field ids where the accessors allow it, because
--     sim.partProperty with a string builds a ByteString and linearly compares
--     13 names plus 3 aliases on every single call
--   * per-ant scratch lives in PARALLEL SCALAR ARRAYS, never per-ant tables,
--     so a steady-state write is an array store that allocates nothing
--   * 50_tasks' answer is cached in those arrays and re-asked every 12 ticks,
--     staggered by particle index, instead of every frame
--   * sensing probes ONE rotating neighbour per frame rather than all eight;
--     an ant covers at most one pixel per frame, so a sweep every 8 frames
--     still cannot miss anything it walks past
--   * pixel -> cell is a lookup table, not a divide and a floor
--   * state is written only when it changes, mirrored in cState
--   * error containment is coarse -- see the GUARD section
--
-- The whole module is the body of one immediately-called function, and that is
-- load-bearing rather than stylistic.  Lua 5.1 allows 200 ACTIVE locals per
-- function (luaconf.h LUAI_MAXVARS), build_autorun.py concatenates every module
-- into a single chunk, and this file alone declares over a hundred file-scope
-- locals.  A plain do...end block does not help: it releases its locals only at
-- `end`, so while the block is open its locals still stack on top of every
-- earlier module's.  Measured -- 00+10+20+30 plus this file as a do-block
-- overflowed the limit and the whole autorun failed to compile.  A nested
-- function gets its own counter starting at zero, so this module costs the
-- shared chunk exactly one local.  The closures outlive the call because they
-- are published on PBX.state.worker and _G.PB_EXT.
--
-- For a related reason the update function is split into small steps: a Lua 5.1
-- closure may capture at most 60 upvalues (LUAI_MAXUPVALUES) and one monolithic
-- update body came within two of the ceiling.
-- ===========================================================================

do
local function pbxWorkerMain()

local PBX = _G.PBX
if not PBX then error("40_worker.lua: PBX foundation missing (00_util.lua must load first)") end

local MOD = "worker"
local W = PBX.state.worker      -- our one key: we write here, other modules read

W.VERSION = "1.0.0"

-- ---------------------------------------------------------------------------
-- Hoisted entry points, resolved once at load.
--
-- Signatures confirmed against src/lua/LuaSimulation.cpp:
--   sim.partProperty(i, nameOrFieldId [, value])   :486  get -> value / set
--   sim.partPosition(i)            -> x, y         :450
--   sim.partPosition(i, nx, ny)                    :450  routes to Simulation::move
--   sim.partCreate(-1, x, y, type [, v]) -> index or -1   :394
--   sim.partKill(i)                                :548
--   sim.partChangeType(i, type)                    :383
--   sim.pmap(x, y)     -> particle index or nil    :1610  (index, NOT type)
--   sim.photons(x, y)  -> particle index or nil    :1624
-- ---------------------------------------------------------------------------

local partProperty = sim.partProperty
local partPosition = sim.partPosition
local partCreate   = sim.partCreate
local partKill     = sim.partKill
local pmapAt       = sim.pmap
local photonsAt    = sim.photons
local wallAt       = sim.wallMap
local partsIter    = sim.parts

-- sim.partChangeType(i, t) reuses a particle's slot and rewrites pmap in place
-- (Simulation::part_change_type).  We deliberately do not use it for cargo:
-- pickup and deposit happen at different pixels, and reusing the ant's own
-- slot would delete the ant.  kill-there plus create-here is the correct pair,
-- and both maintain pmap themselves.
local partChangeType = sim.partChangeType

local getColony      = PBX.getColony
local setColony      = PBX.setColony
local getWorkerState = PBX.getWorkerState
local setWorkerState = PBX.setWorkerState
local getClaim       = PBX.getClaim
local setClaim       = PBX.setClaim
local cellFreeSlow   = PBX.cellFree

local random, floor = math.random, math.floor

-- ---------------------------------------------------------------------------
-- Geometry
--
-- Simulation::move (Simulation.cpp:1539) KILLS any particle it is asked to
-- move outside [CELL, XRES-CELL) x [CELL, YRES-CELL), and CELL is 4.  That is
-- tighter than PBX.cellFree's 0..611 / 0..383, so ants need their own bounds
-- or they quietly evaporate on reaching the edge of the canvas.
-- ---------------------------------------------------------------------------

local CELL = 4
local MINX, MAXX = CELL, PBX.SIM_W - CELL - 1       -- 4 .. 607
local MINY, MAXY = CELL, PBX.SIM_H - CELL - 1       -- 4 .. 379

-- The eight compass directions, clockwise from east, as flat parallel arrays.
-- A table of {x=,y=} pairs would cost a hash probe per lookup; this is an
-- array read, and it is hit up to five times per ant per frame.
local DIRX = { 1,  1,  0, -1, -1, -1,  0,  1 }
local DIRY = { 0,  1,  1,  1,  0, -1, -1, -1 }

-- (dx,dy) in {-1,0,1}^2 -> ring index, keyed by (dx+1)*3 + (dy+1) + 1.
-- Slot 5 is (0,0) and maps to 0, meaning "no heading".
local RING_OF = { 6, 5, 4, 7, 0, 3, 8, 1, 2 }

-- Ring offsets stepToward tries, as two mirrored MONOTONIC sweeps.  The first
-- three entries are the three candidate directions -- straight on, then 45 and
-- 90 degrees round -- and the rest is the sidestep.
--
-- The sweep has to be monotonic, and the direction has to be committed per ant
-- across ticks, or ants cannot get round a wall at all.  An alternating window
-- (0, +1, -1, +2, -2) looks reasonable and deadlocks: an ant pressed against a
-- vertical wall sidesteps north, which makes the target pull south again next
-- tick, so it sidesteps south, and it ping-pongs on the target's axis forever.
-- Sweeping one way and keeping that way turns the same situation into wall
-- following -- the ant runs along the wall until it clears the end.  Verified:
-- with the alternating window a 44px wall between nest and food stopped every
-- ant dead; with this one they round it and forage normally.
--
-- The exact reverse is deliberately not a candidate: an ant boxed in on seven
-- sides is better off standing still for a tick than turning back into the
-- crowd it just came from.
local OFF_CW  = { 0,  1,  2,  3, -3, -2, -1 }
local OFF_CCW = { 0, -1, -2, -3,  3,  2,  1 }

-- pixel -> cell.  Built once; replaces a divide and a floor with one array
-- read, and it is hit two to four times per ant per frame.  Sized for the
-- wider axis so a single table serves both (both divide by CELL), and 1-based
-- so every entry lives in the table's array part.
local CELLOF = {}
for p = 0, PBX.SIM_W - 1 do CELLOF[p + 1] = floor(p / CELL) end

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local WORKER_LIFE   = 1500   -- energy units at spawn and after refuelling
W.WORKER_LIFE = WORKER_LIFE   -- published so 70_people.lua's personFeed can cap at the same ceiling
local ENERGY_PERIOD = 4      -- ticks per energy unit -> ~100 s of range at 60fps
local REFUEL_R      = 6      -- Chebyshev px from the nest that counts as adjacent
local NEST_R        = 3      -- arrival radius for a nest delivery
local CELL_R        = 1      -- arrival radius for a claimed blueprint cell
local PHERO_SEEK    = 0.35   -- laid while searching: a faint, wide haze
local PHERO_HAUL    = 2.5    -- laid while carrying: this is what makes trails
local TASK_REFRESH  = 12     -- ticks between forWorker queries for one ant
local WANDER_TURN   = 0.22   -- per-tick chance a wandering ant changes heading
local WANDER_LOOK   = 6      -- how far ahead it aims, which is what curves the path
local SPAWN_TRIES   = 24     -- rejection samples per ant when placing a spawn
local WARMUP_GUARD  = 300    -- frames of fully-guarded operation after load or fault
local FAULT_LIMIT   = 400   -- faults before the creature update shuts itself off
local FLEE_TEMP     = 350    -- K; a neighbour above this is a fire/heat hazard
local DROWN_TICKS   = 300    -- 5s at 60fps submerged in WATR before an ant drowns
local FLEE_DURATION = 90     -- 1.5s of forced retreat once a flee triggers
local COWARD_BONUS  = 50     -- K; a "coward" trait lowers its effective FLEE_TEMP by this much

-- State machine values, fixed by spec section 3.
local S_IDLE, S_SEEK, S_HAUL, S_BUILD, S_HOME, S_DIG, S_WANDER, S_FLEE = 0, 1, 2, 3, 4, 5, 6, 7

-- Task modes as integers: the hot path compares numbers, and the strings are
-- translated once per refresh rather than once per frame.
local M_NONE, M_SEEK, M_DELIVER, M_DIG, M_PATROL, M_FETCH = 0, 1, 2, 3, 4, 5
local MODE_CODE = {
    seek = M_SEEK, gather = M_SEEK, forage = M_SEEK,
    deliver = M_DELIVER, build = M_DELIVER, haul = M_DELIVER, place = M_DELIVER,
    dig = M_DIG, mine = M_DIG, clear = M_DIG,
    patrol = M_PATROL, walk = M_PATROL,
    fetch = M_FETCH, load = M_FETCH,
    idle = M_NONE, none = M_NONE, wander = M_NONE,
}

local SRC_STORE, SRC_SPAWN = 1, 2
local SOURCE_CODE = { store = SRC_STORE, spawn = SRC_SPAWN }

-- ---------------------------------------------------------------------------
-- Per-ant scratch: parallel scalar arrays keyed by particle index.
--
-- Not one table per ant: 3200 small tables is 3200 hash allocations plus a
-- pointer chase per field.  Scalar arrays give array-part stores, and once a
-- key exists an overwrite allocates nothing at all.  Keys are seeded when the
-- ant is created, inside the deferred spawn job, so the single rehash an ant
-- ever costs is paid off the hot path.
--
-- TPT recycles particle indices through a free list, so a stale entry can be
-- inherited by a new particle.  Everything here is a soft hint -- a heading, a
-- cached task answer carrying a TTL -- so a stale value is harmless and
-- self-corrects within TASK_REFRESH ticks.  seedAnt resets them anyway.
-- ---------------------------------------------------------------------------

local mDX, mDY = {}, {}                 -- last heading, -1/0/1 (see the momentum note)
local cTask, cTTL = {}, {}              -- cached task id and ticks left on the answer
local cMode, cTX, cTY = {}, {}, {}      -- the cached decision from 50_tasks
local cElem, cCell, cSrc = {}, {}, {}
local cState = {}                       -- last state written, so no-op writes are skipped
local tSign = {}                        -- committed turn direction, +1 or -1 (see OFF_CW)
local headOf = {}                       -- particle id of this ant's HEAD pixel, or nil
local drownCounter, fleeTicks, traitOf = {}, {}, {}  -- Phase 2/4: submersion run length, forced-retreat ticks left, personality trait

-- Where the heading may live.  See the header note on pavg0/pavg1 aliasing.
local USE_PAVG = (PBX.hasTmp34 == false)

--- Last heading of ant `i` as dx, dy in {-1,0,1}.  0,0 means "no heading yet".
local function getMom(i)
    if USE_PAVG then
        local a = partProperty(i, "pavg0")
        local b = partProperty(i, "pavg1")
        if a == nil or b == nil then return 0, 0 end
        return a - 1, b - 1
    end
    local a = mDX[i]
    if a == nil then return 0, 0 end
    return a, mDY[i]
end

--- Record the heading ant `i` just took.  Stored as dx+1 / dy+1 in the pavg
--- fields when those genuinely exist, which is spec section 3's encoding.
local function setMom(i, dx, dy)
    if USE_PAVG then
        partProperty(i, "pavg0", dx + 1)
        partProperty(i, "pavg1", dy + 1)
        return
    end
    mDX[i] = dx
    mDY[i] = dy
end

-- ---------------------------------------------------------------------------
-- Particle field ids.
--
-- sim.partProperty takes either a name or an index into
-- Particle::GetProperties (LuaSimulation.cpp:486 -- the LUA_TNUMBER branch
-- indexes the vector directly, while the string branch builds a ByteString and
-- linearly compares 13 names plus 3 aliases).  The numeric form skips all of
-- that, and the "type"/"x"/"y" special cases in LuaSetParticleProperty
-- dispatch on property.Name, so they still apply either way.
--
-- The ids below come from Particle.h in this source tree (FIELD_TMP = 9,
-- FIELD_TMP2 = 10, ...), but that header itself warns they are positions in a
-- vector rather than offsets in the struct.  So they are not trusted until a
-- live particle proves them; until then every access uses the name and is
-- merely slower, never wrong.  tmp2/tmp3/tmp4 are never in this set -- those
-- only ever go through the PBX accessors.
-- ---------------------------------------------------------------------------

local F_TYPE, F_LIFE, F_CTYPE, F_TMP, F_DCOL = "type", "life", "ctype", "tmp", "dcolour"
local fieldIdsChecked = false

--- Prove the numeric field ids against a live particle, then switch to them.
--- Only `life` and `ctype` are written and both are worker-owned columns, so
--- no other module's field is ever disturbed, and both are restored exactly.
--- A sentinel has to land on its own id AND on no other, which is what rules
--- out a permuted layout rather than merely a coincidental match.  Any
--- surprise at all leaves us on names forever.  Runs once, ever.
local function checkFieldIds(i)
    if fieldIdsChecked then return end
    fieldIdsChecked = true
    local ok = pcall(function()
        local oldLife  = partProperty(i, "life")
        local oldCtype = partProperty(i, "ctype")
        local SL, SC = 0x51F31, 0x0C7E5     -- distinct, and not plausible real values
        partProperty(i, "life", SL)
        partProperty(i, "ctype", SC)
        local good = (partProperty(i, 1) == SL)
                 and (partProperty(i, 2) == SC)
                 and (partProperty(i, 0) == partProperty(i, "type"))
        if good then
            for id = 0, 13 do
                if id ~= 1 and id ~= 2 then
                    local v = partProperty(i, id)
                    if v == SL or v == SC then good = false end
                end
            end
        end
        partProperty(i, "life", oldLife)
        partProperty(i, "ctype", oldCtype)
        if good then
            F_TYPE, F_LIFE, F_CTYPE, F_TMP, F_DCOL = 0, 1, 2, 9, 13
            PBX.log(MOD, "numeric particle field ids verified; using fast property access")
        else
            PBX.log(MOD, "particle field id probe inconclusive; staying on property names")
        end
    end)
    if not ok then
        PBX.log(MOD, "particle field id probe failed; staying on property names")
    end
end

-- ---------------------------------------------------------------------------
-- Worker element resolution.
--
-- 10_registry.lua allocates the element; we only find it.  The spec does not
-- pin the registry's state shape, so the plausible shapes are probed once and
-- cached.  As a last resort the Update function learns the id from the first
-- particle it is ever called for: if TPT is invoking us as an element's
-- Update, that particle is a worker by definition.
-- ---------------------------------------------------------------------------

W.ELEMENT_NAME = "ANT"          -- overridable before the first spawn

local workerType  = nil         -- id resolved from the registry
local learnedType = nil         -- id observed on a live particle

local function idFrom(v)
    if type(v) == "number" then return v end
    if type(v) == "table" then return v.id or v.elementId or v.type end
    return nil
end

local REG_MAPS   = { "byName", "elements", "ids" }
local REG_DEFINE = { "ensure", "define", "defineElement" }

--- The worker element id, or nil plus a message saying exactly how to make it.
local function resolveWorkerType()
    if workerType then return workerType end
    local name = W.ELEMENT_NAME
    local R = PBX.state.registry

    if type(R) == "table" then
        -- 1. the documented accessor
        if type(R.get) == "function" then
            local ok, v = pcall(R.get, name)
            local id = ok and idFrom(v) or nil
            if id then workerType = id; return id end
        end
        -- 2. plain maps a registry might expose instead
        for n = 1, #REG_MAPS do
            local t = R[REG_MAPS[n]]
            if type(t) == "table" then
                local id = idFrom(t[name])
                if id then workerType = id; return id end
            end
        end
        -- 3. a define/ensure entry point, if the registry exposes one.  We ask
        --    for exactly what a creature needs; defineElement is idempotent on
        --    name (spec 4.1) so an existing element comes straight back.
        for n = 1, #REG_DEFINE do
            local fn = R[REG_DEFINE[n]]
            if type(fn) == "function" then
                local ok, v = pcall(fn, {
                    name = name, group = "PBX", description = "Colony worker ant",
                    colour = 0xE8C27A, type = "SOLID", menuSection = "special",
                    temperature = 295.15, hardness = 0, weight = 100,
                    gravity = 0, diffusion = 0, flammable = 0, explosive = 0,
                    heatConduct = 0, behavior = { kind = "creature", params = {} },
                })
                local id = ok and idFrom(v) or nil
                if id then workerType = id; return id end
            end
        end
    end

    -- 4. the element table, through PBX's resolver (it knows PBX_PT_<NAME>)
    local id = PBX.vElem(name)
    if id then workerType = id; return id end

    -- 5. whatever we have actually seen ticking
    if learnedType then workerType = learnedType; return learnedType end

    return nil, "worker element '" .. tostring(name) ..
        "' does not exist yet: call defineElement with name='" .. tostring(name) ..
        "', type='SOLID', gravity=0, diffusion=0 and behavior={kind='creature'}" ..
        " before spawning workers"
end

local headType, learnedHeadType = nil, nil     -- HEAD element id, resolved lazily

--- The HEAD element id, or nil.  Unlike resolveWorkerType this never errors:
--- a body-less ant (HEAD not yet defined via define_element/execute_lua) is
--- a cosmetic gap, never a reason to refuse a spawn.
local function resolveHeadType()
    if headType then return headType end
    if learnedHeadType then headType = learnedHeadType; return headType end
    local ok, id = pcall(PBX.vElem, "HEAD")
    if ok and id then headType = id; return id end
    return nil
end

local waterType = nil     -- WATR element id, resolved lazily via the same PBX.vElem convention
local function resolveWaterType()
    if waterType then return waterType end
    local ok, id = pcall(PBX.vElem, "WATR")
    if ok and id then waterType = id end
    return waterType
end

-- ---------------------------------------------------------------------------
-- Colony interface (30_colony.lua).
--
-- Bound once into locals so the hot path calls through an upvalue instead of
-- walking PBX.state.colony every frame.  All of it is optional: an ant with no
-- colony module still walks, it just has no nest to return to and lays no
-- pheromone.
-- ---------------------------------------------------------------------------

local fnColonyGet, fnGradient, fnDeposit, fnAddStore, fnTakeStore, fnRecordDied
local nestX, nestY, colColour = {}, {}, {}      -- per-colony cache, refreshed cold

local function bindColony()
    local C = PBX.state.colony
    if type(C) ~= "table" then return end
    fnColonyGet = (type(C.get) == "function" and C.get)
               or (type(C.colony) == "function" and C.colony) or nil
    fnGradient  = (type(C.gradient) == "function" and C.gradient) or nil
    fnDeposit   = (type(C.deposit) == "function" and C.deposit) or nil
    fnAddStore  = (type(C.addStore) == "function" and C.addStore)
               or (type(C.storeAdd) == "function" and C.storeAdd) or nil
    fnTakeStore = (type(C.takeStore) == "function" and C.takeStore)
               or (type(C.storeTake) == "function" and C.storeTake) or nil
    fnRecordDied = (type(C.recordDied) == "function" and C.recordDied) or nil
end
bindColony()    -- 30_colony.lua concatenates above us, so this normally succeeds

--- The colony record, tolerating the field spellings a colony module may use.
--- Re-binds if the colony module had not published yet when we loaded: module
--- concatenation order puts 30_colony above us, but nothing guarantees it
--- populates PBX.state.colony at load time rather than on first use, and a
--- colony created after startup must still be visible to the first spawn.
--- Only reached while fnColonyGet is nil, and never from the per-frame path.
local function colonyRecord(cid)
    if not fnColonyGet then bindColony() end
    if fnColonyGet then
        local ok, r = pcall(fnColonyGet, cid)
        if ok and type(r) == "table" then return r end
    end
    local C = PBX.state.colony
    if type(C) == "table" and type(C.colonies) == "table" then
        local r = C.colonies[cid]
        if type(r) == "table" then return r end
    end
    return nil
end

--- Refresh nest positions and colours.  A tick hook runs this every 30 frames
--- so the update function only ever reads flat arrays.
local function refreshColonyCache()
    if not fnColonyGet then bindColony() end
    for cid = 0, PBX.MAX_COLONIES do
        local r = colonyRecord(cid)
        if r then
            local nx = r.nestX or r.nx or r.x
            local ny = r.nestY or r.ny or r.y
            if type(nx) == "number" and type(ny) == "number" then
                nestX[cid], nestY[cid] = floor(nx), floor(ny)
            end
            local col = r.colour or r.color
            if type(col) == "number" then colColour[cid] = col end
        end
    end
end

--- 0xAARRGGBB tint for a colony.  Deco with a zero alpha byte does not render,
--- so a plain 0xRRGGBB from the colony module gets full alpha forced on.
---
--- Reads the colony record live rather than the 30-tick cache: this runs once
--- per spawn action, and the tint is baked into dcolour permanently, so an ant
--- created in the window before the cache first fills would otherwise keep the
--- fallback colour for the rest of its life.  The very first spawn after
--- startup always lands in that window.
local function colonyTint(cid)
    local r = colonyRecord(cid)
    local c = (r and (r.colour or r.color)) or colColour[cid]
    if type(c) ~= "number" then
        -- Keep colonies visually separable even if no colour was published.
        c = 0x404040 + ((cid * 67) % 256) * 0x010101 + (cid % 3) * 0x300000
    end
    if c < 0x1000000 then c = c + 0xFF000000 end
    return c
end

--- Lay pheromone.  A silent no-op when 30_colony is absent.
local function layPhero(cid, cx, cy, amount)
    if fnDeposit then fnDeposit(cid, cx, cy, amount) end
end

--- Pheromone gradient at a cell, as gx, gy.  Accepts the two-number return
--- (preferred, allocation-free) or a table with x/y or [1]/[2].
local function gradientAt(cid, cx, cy)
    if not fnGradient then return 0, 0 end
    local a, b = fnGradient(cid, cx, cy)
    if type(a) == "number" then
        if type(b) ~= "number" then b = 0 end
        return a, b
    end
    if type(a) == "table" then
        local gx, gy = a.x or a[1], a.y or a[2]
        if type(gx) ~= "number" then gx = 0 end
        if type(gy) ~= "number" then gy = 0 end
        return gx, gy
    end
    return 0, 0
end

-- ---------------------------------------------------------------------------
-- Corpses (Phase 3): a dying worker becomes a CORPSE particle instead of
-- vanishing, tinted a darkened shade of its colony colour, and left for the
-- CORPSE element's own `decayer` behavior (defined via define_element/
-- execute_lua) to remove after ~2-3s.  Falls back to a bare partKill when
-- CORPSE has not been defined yet, exactly like resolveHeadType's fallback.
-- ---------------------------------------------------------------------------

local CORPSE_LIFE = 150   -- ~2.5s at 60fps; matches the CORPSE decayer's startLife
local corpseType, learnedCorpseType = nil, nil

local function resolveCorpseType()
    if corpseType then return corpseType end
    if learnedCorpseType then corpseType = learnedCorpseType; return corpseType end
    local ok, id = pcall(PBX.vElem, "CRPS")
    if ok and id then corpseType = id; return id end
    return nil
end

--- Halve each RGB channel of an 0xAARRGGBB tint, alpha untouched -- a cheap,
--- allocation-free "darker" without a colour-space conversion.  No bit32 on
--- this Lua 5.1 build, so channels are peeled with floor division/modulo.
local function darkenTint(c)
    local a = floor(c / 0x1000000) % 0x100
    local r = floor(c / 0x10000) % 0x100
    local g = floor(c / 0x100) % 0x100
    local b = c % 0x100
    return a * 0x1000000 + floor(r / 2) * 0x10000 + floor(g / 2) * 0x100 + floor(b / 2)
end

--- Convert a dying worker particle into a corpse in place, or kill it
--- outright if CORPSE has not been defined.  Caller must have already run
--- retireAnt (task release, colony decrement, cause recording, head kill) --
--- none of that depends on whether the torso is killed or re-skinned.
local function killAsCorpse(i, cid)
    local ct = resolveCorpseType()
    if ct then
        partChangeType(i, ct)
        partProperty(i, F_LIFE, CORPSE_LIFE)
        partProperty(i, F_DCOL, darkenTint(colonyTint(cid)))
    else
        partKill(i)
    end
end

local function addStore(cid, elem, n)
    if fnAddStore then fnAddStore(cid, elem, n); return true end
    local r = colonyRecord(cid)
    if r and type(r.store) == "table" then
        r.store[elem] = (r.store[elem] or 0) + n
        return true
    end
    return false
end

--- Take one unit of `elem` out of the colony store.  Returns true only when
--- the store actually gave it up, so a source="store" build cannot conjure
--- material the colony never gathered.
local function takeStore(cid, elem)
    if fnTakeStore then
        local ok, got = pcall(fnTakeStore, cid, elem, 1)
        return ok and got ~= false and got ~= 0 and got ~= nil
    end
    local r = colonyRecord(cid)
    if r and type(r.store) == "table" then
        local have = r.store[elem] or 0
        if have >= 1 then r.store[elem] = have - 1; return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Task interface (50_tasks.lua).  Every entry point optional.
-- ---------------------------------------------------------------------------

local ELEM_CACHE = {}   -- element name -> id, so a named element costs one lookup ever

local function elemId(v)
    if v == nil then return 0 end
    if type(v) == "number" then return v end
    local hit = ELEM_CACHE[v]
    if hit then return hit end
    local id = PBX.vElem(v) or 0
    ELEM_CACHE[v] = id
    return id
end

local function tasksMod()
    local T = PBX.state.tasks
    if type(T) == "table" then return T end
    return nil
end

local function taskComplete(i, taskId, cellIndex)
    local T = tasksMod()
    if T and type(T.complete) == "function" then T.complete(i, taskId, cellIndex or 0) end
    setClaim(i, 0)
end

local function taskRelease(i, taskId)
    local T = tasksMod()
    if T and type(T.release) == "function" then T.release(i, taskId) end
    setClaim(i, 0)
end

--- Ask 50_tasks what this ant should do and cache the answer in the scalar
--- arrays.  Called about once every TASK_REFRESH ticks per ant, never every
--- frame: that is the difference between ~270 cross-module calls a frame and
--- 3200 of them.
local function refreshTask(i, cid, taskId)
    cTask[i] = taskId
    cTTL[i]  = TASK_REFRESH

    local T = tasksMod()
    if not T or type(T.forWorker) ~= "function" then cMode[i] = M_NONE; return end

    local a, b, c, d, e = T.forWorker(i, cid, taskId)
    local mode, tx, ty, elem, cellIdx, src

    if type(a) == "table" then
        mode, tx, ty = a.mode, a.tx, a.ty
        elem, cellIdx, src = a.element, a.cellIndex, a.source
    elseif type(a) == "string" then
        mode, tx, ty, elem, cellIdx = a, b, c, d, e
    else
        cMode[i] = M_NONE
        return
    end

    local code = MODE_CODE[mode]
    if code == nil then code = M_SEEK end       -- unknown mode: at least go there
    cMode[i] = code
    cTX[i]   = (type(tx) == "number") and floor(tx) or -1
    cTY[i]   = (type(ty) == "number") and floor(ty) or -1
    cElem[i] = elemId(elem)
    cCell[i] = (type(cellIdx) == "number") and floor(cellIdx) or 0
    cSrc[i]  = SOURCE_CODE[src] or 0

    -- 50_tasks owns the decision; we own the write of the claim token.
    local want = (cCell[i] > 0) and (cCell[i] + 1) or 0
    if getClaim(i) ~= want then setClaim(i, want) end
end

-- ---------------------------------------------------------------------------
-- Movement
-- ---------------------------------------------------------------------------

--- True when (x,y) is inside the ants' safe box, holds no particle, and is not
--- inside a wall.
---
--- This is PBX.cellFree with its pcall removed.  cellFree wraps sim.pmap
--- because sim.pmap raises on out-of-range coordinates (LuaSimulation.cpp:1610
--- luaL_error) -- and the bounds test on the line above has already made that
--- impossible.  Paying a setjmp up to five times per ant per frame to guard an
--- error that cannot occur is the one cost this file will not carry; the
--- semantics are otherwise identical, and PBX.cellFree itself is still used on
--- the cold spawn path.  The bounds are also tighter than cellFree's, per the
--- CELL note above.
---
--- The wall check runs only after pmap has already said "empty", so on the
--- winning candidate it costs one extra call and ants respect drawn walls
--- essentially for free.
local function freeAt(x, y)
    if x < MINX or x > MAXX or y < MINY or y > MAXY then return false end
    if pmapAt(x, y) ~= nil then return false end
    return wallAt(CELLOF[x + 1], CELLOF[y + 1]) == 0
end

--- Move ant `i` one cell from (x,y) towards (tx,ty).  Returns true if it moved.
---
--- Tries the direct heading, then progressively larger turns to one side --
--- the first three are the three candidate directions -- and then the same
--- sweep the other way as a sidestep, so an ant pressed against a wall slides
--- along it instead of deadlocking.  Which side it sweeps first is committed
--- per ant (tSign) rather than chosen per call, which is what makes the slide
--- persist into wall following; see the OFF_CW note for why the obvious
--- alternating version deadlocks.  When every candidate is blocked the
--- commitment flips, so an ant wedged in a pocket unwinds itself next tick.
---
--- Position is written with sim.partPosition(i, nx, ny), which routes through
--- Simulation::move (Simulation.cpp:1539).  That function DOES maintain the
--- position map -- it clears pmap[y][x] when the entry is ours and writes
--- pmap[ny][nx] -- but it does NOT check whether the destination is occupied,
--- so it will happily overwrite another particle's pmap entry and orphan that
--- particle.  Every candidate is therefore proven empty by freeAt first, which
--- is also exactly what guarantees two ants can never share a pixel.
local function stepToward(i, x, y, tx, ty)
    local dx = (tx > x) and 1 or ((tx < x) and -1 or 0)
    local dy = (ty > y) and 1 or ((ty < y) and -1 or 0)
    if dx == 0 and dy == 0 then return false end

    local k = RING_OF[(dx + 1) * 3 + (dy + 1) + 1]
    local sgn = tSign[i]
    local offs = (sgn == -1) and OFF_CCW or OFF_CW

    for a = 1, 7 do
        local kk = ((k - 1 + offs[a]) % 8) + 1
        local ox, oy = DIRX[kk], DIRY[kk]
        local nx, ny = x + ox, y + oy
        if freeAt(nx, ny) then
            partPosition(i, nx, ny)
            setMom(i, ox, oy)
            return true
        end
    end
    tSign[i] = -(sgn or 1)      -- boxed in: try the other way round next tick
    return false
end

--- Biased random walk: hold the previous heading, occasionally turn one step
--- around the compass.  Aiming WANDER_LOOK cells ahead rather than at the
--- adjacent pixel routes the move back through stepToward, so wandering
--- inherits the sidestep behaviour and traces believable curves instead of
--- vibrating on the spot.  The momentum is what makes it a curve at all.
local function wanderStep(i, x, y)
    local dx, dy = getMom(i)
    local k = RING_OF[(dx + 1) * 3 + (dy + 1) + 1]
    if k == 0 then
        k = random(8)
    elseif random() < WANDER_TURN then
        k = ((k - 1 + random(3) - 2) % 8) + 1       -- -1, 0 or +1 around the ring
    end
    if not stepToward(i, x, y, x + DIRX[k] * WANDER_LOOK, y + DIRY[k] * WANDER_LOOK) then
        setMom(i, 0, 0)     -- boxed in from that heading; pick fresh next tick
    end
end

--- Forced retreat: step toward a point WANDER_LOOK cells past (x,y) in the
--- awayDX/awayDY direction, reusing stepToward exactly like wanderStep so a
--- flee inherits the same sidestep-around-obstacles behaviour.
local function fleeStep(i, x, y, awayDX, awayDY)
    if not stepToward(i, x, y, x + awayDX * WANDER_LOOK, y + awayDY * WANDER_LOOK) then
        setMom(i, 0, 0)
    end
end

--- One of the eight neighbours, rotated by frame and by particle index.
--- A full 3x3 sweep is eight pmap calls per ant per frame; an ant travels at
--- most one pixel per frame, so probing a single cell per frame still covers
--- the whole neighbourhood every 8 frames and cannot miss anything it walks
--- past.  Returns particle index, x, y -- or nil.
local function probeNeighbour(i, x, y, tick)
    local k = ((tick + i) % 8) + 1
    local px, py = x + DIRX[k], y + DIRY[k]
    if px < MINX or px > MAXX or py < MINY or py > MAXY then return nil end
    local j = pmapAt(px, py)
    if j == nil then
        -- Energy elements (PHOT and friends) live in sim.photons, not pmap, so
        -- a gather task naming one would otherwise never find its target.
        j = photonsAt(px, py)
        if j == nil then return nil end
    end
    return j, px, py
end

-- ---------------------------------------------------------------------------
-- Cargo
-- ---------------------------------------------------------------------------

--- Put `elem` down.  A build delivery has to land in its claimed cell so that
--- pixel is tried first; a nest delivery just wants any free neighbour.
--- Returns true when a particle was created, or when the exact cell was
--- already filled, which counts as satisfied.
local function placeCarry(i, x, y, elem, exX, exY)
    if exX and exX >= 0 then
        if freeAt(exX, exY) then
            if partCreate(-1, exX, exY, elem) >= 0 then return true end
        elseif exX >= MINX and exX <= MAXX and exY >= MINY and exY <= MAXY then
            return true         -- somebody already filled it
        end
    end
    for k = 1, 8 do
        local px, py = x + DIRX[k], y + DIRY[k]
        if freeAt(px, py) and partCreate(-1, px, py, elem) >= 0 then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Ant bookkeeping
-- ---------------------------------------------------------------------------

local liveCount = {}    -- colony id -> workers; incremental, resynced cold

local function seedAnt(i)
    mDX[i], mDY[i] = 0, 0
    cTask[i], cTTL[i] = -1, 0
    cMode[i], cTX[i], cTY[i] = M_NONE, -1, -1
    cElem[i], cCell[i], cSrc[i] = 0, 0, 0
    cState[i] = getWorkerState(i)
    -- Which way this ant prefers to go round things, fixed for its lifetime so
    -- that wall following is consistent, and randomised per ant so a crowd
    -- meeting one obstacle splits either side of it instead of queueing.
    tSign[i] = (random(2) == 1) and 1 or -1
    drownCounter[i], fleeTicks[i] = 0, 0
end

local function forgetAnt(i)
    mDX[i], mDY[i] = nil, nil
    cTask[i], cTTL[i] = nil, nil
    cMode[i], cTX[i], cTY[i] = nil, nil, nil
    cElem[i], cCell[i], cSrc[i] = nil, nil, nil
    cState[i] = nil
    tSign[i] = nil
    drownCounter[i], fleeTicks[i], traitOf[i] = nil, nil, nil
end

--- Write the state nibble only when it actually changed.  Reading it back to
--- compare would cost the very C call we are avoiding, so the last value
--- written is mirrored in cState.
local function setState(i, s)
    if cState[i] ~= s then
        setWorkerState(i, s)
        cState[i] = s
    end
end

--- Everything that must happen before an ant stops existing.
local function retireAnt(i, taskId, cause)
    if taskId and taskId ~= 0 then taskRelease(i, taskId) else setClaim(i, 0) end
    local cid = getColony(i)
    if liveCount[cid] then liveCount[cid] = liveCount[cid] - 1 end
    if fnRecordDied then fnRecordDied(cid, 1, cause) end
    local hid = headOf[i]
    if hid then partKill(hid); headOf[i] = nil end
    forgetAnt(i)
end

-- ---------------------------------------------------------------------------
-- Behaviour, one step per branch.
--
-- Split into separate closures rather than one body, so no closure comes near
-- Lua 5.1's 60-upvalue ceiling.  Only one of them runs per ant per frame, so
-- the split costs a single extra Lua call.
-- ---------------------------------------------------------------------------

--- Priority 1: energy.  Returns true when the ant starved and was killed.
--- Ants adjacent to the nest top up continuously rather than only at zero: an
--- ant that has to reach exactly 0 before refuelling starves on its last leg
--- home, and a colony that quietly evaporates reads as a broken feature rather
--- than as a simulation.  An ant whose colony has no known nest does not decay
--- at all -- starving it would punish an integration gap, not model anything.
local function energyTick(i, x, y, cid, tick)
    local nx, ny = nestX[cid], nestY[cid]
    if not nx then return false end

    local ax = x - nx; if ax < 0 then ax = -ax end
    local ay = y - ny; if ay < 0 then ay = -ay end
    if ax <= REFUEL_R and ay <= REFUEL_R then
        if partProperty(i, F_LIFE) < WORKER_LIFE then
            partProperty(i, F_LIFE, WORKER_LIFE)
        end
        return false
    end

    -- Staggered by particle index so the colony neither pays the write on one
    -- frame nor dies all together on one frame.
    if (tick + i) % ENERGY_PERIOD == 0 then
        local life = partProperty(i, F_LIFE) - 1
        if life <= 0 then
            retireAnt(i, partProperty(i, F_TMP), "starved")
            killAsCorpse(i, cid)
            return true
        end
        partProperty(i, F_LIFE, life)
    end
    return false
end

--- Phase 4 bias: a "coward" trait flees sooner (lower heat threshold); other
--- traits (including nil / unset) use the baseline.
local function fleeThreshold(i)
    if traitOf[i] == "coward" then return FLEE_TEMP - COWARD_BONUS end
    return FLEE_TEMP
end

--- Priority 1.5: environmental hazards (heat flee, drowning).  Rides the
--- same one-neighbour-per-tick probe every other sensing call uses, so this
--- adds no new per-frame cost class (40_worker.lua's stagger note).
---
--- Returns died, handled -- NOT a single true/false mirroring energyTick.
--- died means the ant no longer exists (workerUpdate must `return true`
--- immediately, exactly like a starvation death). handled means this call
--- already decided the ant's move for the tick (a flee step), so the normal
--- priority 2-4 dispatch below must be skipped WITHOUT also returning true --
--- returning true while the particle is still alive would make TPT skip the
--- movement/transition phase for a live particle (see workerUpdate's own
--- header note on that contract), which handled alone avoids.
local function envTick(i, x, y, cid, tick)
    local j, nx, ny = probeNeighbour(i, x, y, tick)
    local inWater = false
    if j ~= nil then
        if partProperty(j, F_TYPE) == resolveWaterType() then
            inWater = true
        elseif (partProperty(j, "temp") or 0) > fleeThreshold(i) then
            fleeTicks[i] = FLEE_DURATION
            setState(i, S_FLEE)
            local awayDX = (x > nx) and 1 or ((x < nx) and -1 or 0)
            local awayDY = (y > ny) and 1 or ((y < ny) and -1 or 0)
            if awayDX == 0 and awayDY == 0 then awayDX, awayDY = getMom(i) end
            fleeStep(i, x, y, awayDX, awayDY)
            return false, true
        end
    end

    -- Drowning: accumulate while a sampled neighbour is water, decay twice as
    -- fast on a miss so crossing one water pixel never drowns anyone.
    drownCounter[i] = inWater and ((drownCounter[i] or 0) + 1)
                              or (((drownCounter[i] or 0) - 2 > 0) and (drownCounter[i] - 2) or 0)
    if drownCounter[i] >= DROWN_TICKS then
        retireAnt(i, partProperty(i, F_TMP), "drowned")
        killAsCorpse(i, cid)
        return true, true
    end

    -- Continue an in-progress forced retreat until it expires.
    local ft = fleeTicks[i]
    if ft and ft > 0 then
        setState(i, S_FLEE)
        fleeTicks[i] = ft - 1
        local mx, my = getMom(i)
        if mx ~= 0 or my ~= 0 then fleeStep(i, x, y, mx, my) end
        return false, true
    end

    return false, false
end

--- Priority 2: nothing to do.  Wander and lay a faint trail.
local function idleStep(i, x, y, cid, cx, cy)
    setState(i, S_WANDER)
    wanderStep(i, x, y)
    layPhero(cid, cx, cy, PHERO_SEEK)
end

--- Priority 3: carrying something -- take it to the delivery point.
--- isCell distinguishes a claimed blueprint cell (exact placement, CELL_R)
--- from a nest delivery (any free neighbour, NEST_R).  taskId 0 means the ant
--- is simply walking a load home with no task attached, so nothing is reported.
local function deliverStep(i, x, y, cid, cx, cy, carry, tx, ty, isCell, cellIdx, taskId)
    setState(i, isCell and S_BUILD or S_HOME)

    if tx < 0 then
        -- Nowhere to take it: drop it here rather than carry it forever.
        if placeCarry(i, x, y, carry, -1, -1) then partProperty(i, F_CTYPE, 0) end
        return
    end

    local dxs, dys = tx - x, ty - y
    local adx = (dxs < 0) and -dxs or dxs
    local ady = (dys < 0) and -dys or dys

    if adx <= (isCell and CELL_R or NEST_R) and ady <= (isCell and CELL_R or NEST_R) then
        if isCell then
            if placeCarry(i, x, y, carry, tx, ty) then
                partProperty(i, F_CTYPE, 0)
                if taskId ~= 0 then taskComplete(i, taskId, cellIdx) end
                cTTL[i] = 0             -- ask for the next cell immediately
            end
        else
            -- A nest delivery always succeeds: whatever will not fit as a
            -- particle is absorbed into the store instead.  That self-limits
            -- the heap around the nest rather than walling the colony in.
            placeCarry(i, x, y, carry, -1, -1)
            partProperty(i, F_CTYPE, 0)
            addStore(cid, carry, 1)
            if taskId ~= 0 then taskComplete(i, taskId, 0) end
            cTTL[i] = 0
        end
        return
    end

    -- Follow the trail, but never let it cancel the route home.  The heading is
    -- the target direction at weight 2 plus the gradient at weight 1, so the
    -- trail bends the path while the component that makes progress always
    -- survives.
    --
    -- The tempting version -- steer by the gradient whenever it roughly agrees
    -- with the target -- deadlocks hard, and it is worth saying why: a hauling
    -- ant lays PHERO_HAUL on its own cell every single tick, so the strongest
    -- neighbouring cell is almost always the one it just left, and the gradient
    -- points backwards at the ant itself.  Any test loose enough to admit a
    -- perpendicular gradient then lets it zero out the target direction, and
    -- behind an obstacle the ant orbits its own trail forever.  Measured in a
    -- mock sim: 20 ants with a wall between food and nest delivered 0 loads in
    -- 1200 frames that way, and ~1300 with this blend.
    local gx, gy = gradientAt(cid, cx, cy)
    local px = (dxs > 0) and 2 or ((dxs < 0) and -2 or 0)
    local py = (dys > 0) and 2 or ((dys < 0) and -2 or 0)
    if gx > 0 then px = px + 1 elseif gx < 0 then px = px - 1 end
    if gy > 0 then py = py + 1 elseif gy < 0 then py = py - 1 end
    stepToward(i, x, y, x + px, y + py)
    layPhero(cid, cx, cy, PHERO_HAUL)
end

--- Empty-handed on a deliver/fetch: get hold of the material first.
--- source="spawn" (or an unstated source) materialises it, which is spec 4.5's
--- cheap construction mode; source="store" debits what the colony gathered and
--- declines when the store is empty.
local function acquireStep(i, x, y, cid, cx, cy, mode, tx, ty, want, src)
    local loadHere = (mode ~= M_FETCH)
    if mode == M_FETCH then
        if tx < 0 then
            idleStep(i, x, y, cid, cx, cy)
            return
        end
        local adx = tx - x; if adx < 0 then adx = -adx end
        local ady = ty - y; if ady < 0 then ady = -ady end
        loadHere = (adx <= NEST_R and ady <= NEST_R)
    end

    if loadHere then
        if src ~= SRC_STORE or takeStore(cid, want) then
            partProperty(i, F_CTYPE, want)
            setState(i, S_HAUL)
            cTTL[i] = 0                 -- the delivery target is the next question
        else
            -- Store is empty: wander rather than spin on the spot waiting.
            idleStep(i, x, y, cid, cx, cy)
        end
        return
    end

    setState(i, S_SEEK)
    stepToward(i, x, y, tx, ty)
    layPhero(cid, cx, cy, PHERO_SEEK)
end

--- Priority 4: empty-handed and tasked -- seek the target, or dig it out.
local function seekDigStep(i, x, y, cid, cx, cy, tick, mode, tx, ty, want, cellIdx, taskId)
    local digging = (mode == M_DIG)
    setState(i, digging and S_DIG or S_SEEK)

    local j = probeNeighbour(i, x, y, tick)
    if j ~= nil then
        local jt = partProperty(j, F_TYPE)
        local match
        if want ~= 0 then
            match = (jt == want)
        else
            -- "anything" for a dig -- but never each other, and never our kind.
            match = (jt ~= workerType and jt ~= learnedType)
        end
        if match then
            if digging then
                partKill(j)
                taskComplete(i, taskId, cellIdx)
            else
                -- Pick up: the target's type becomes our cargo and the target
                -- particle is removed, so matter is conserved across the swap.
                partProperty(i, F_CTYPE, jt)
                partKill(j)
                setState(i, S_HAUL)
                layPhero(cid, cx, cy, PHERO_HAUL)
            end
            cTTL[i] = 0                 -- the cached answer is stale now
            return
        end
    end

    if tx < 0 or not stepToward(i, x, y, tx, ty) then
        -- No target, or standing on it with nothing to grab: sweep around so a
        -- whole task's worth of ants do not pile onto one pixel.
        wanderStep(i, x, y)
    end
    layPhero(cid, cx, cy, PHERO_SEEK)
end

--- Patrol: arriving is the whole job.
local function patrolStep(i, x, y, cid, cx, cy, tx, ty, cellIdx, taskId)
    setState(i, S_SEEK)
    if tx < 0 then
        wanderStep(i, x, y)
    else
        local adx = tx - x; if adx < 0 then adx = -adx end
        local ady = ty - y; if ady < 0 then ady = -ady end
        if adx <= CELL_R and ady <= CELL_R then
            taskComplete(i, taskId, cellIdx)
            cTTL[i] = 0
        else
            stepToward(i, x, y, tx, ty)
        end
    end
    layPhero(cid, cx, cy, PHERO_SEEK)
end

-- ---------------------------------------------------------------------------
-- The update body.
--
-- Called as Update(i, x, y, surround_space, nt).  x and y are already the
-- rounded pixel coordinates, so position is never read back from the particle.
-- Returns true only when the particle no longer exists: TPT's caller
-- (Simulation.cpp:2392) skips the transition and movement phases on a true
-- return, which is exactly right after a kill and wrong at any other time.
-- ---------------------------------------------------------------------------

local function workerUpdate(i, x, y)
    local tick = PBX.tickIndex

    if learnedType == nil then
        learnedType = partProperty(i, F_TYPE)
        if workerType == nil then workerType = learnedType end
        checkFieldIds(i)
    end
    if cState[i] == nil then seedAnt(i) end     -- save-loaded or hand-placed ant

    local cid = getColony(i)

    -- 1. Energy.
    if energyTick(i, x, y, cid, tick) then return true end

    -- Head repaint (Phase 1c): unconditional every live tick regardless of
    -- which branch below runs, so it never freezes on an idle/deliver early
    -- return.  x,y are this tick's pre-movement position; the head therefore
    -- trails the torso by exactly one tick, which self-corrects every frame
    -- and is not perceptible at 60fps.
    local hid = headOf[i]
    if hid then partProperty(hid, "y", y - 1); partProperty(hid, "x", x) end

    -- 1.5. Environmental hazards (heat flee, drowning).  envHandled means
    -- this call already decided the ant's move for the tick (fleeing);
    -- envDied mirrors energyTick's "no longer exists" contract.  Only envDied
    -- may `return true` -- returning true while still alive would make TPT
    -- skip the movement/transition phase for a live particle.
    local envDied, envHandled = envTick(i, x, y, cid, tick)
    if envDied then return true end
    if envHandled then return false end

    local cx, cy = CELLOF[x + 1], CELLOF[y + 1]
    local taskId = partProperty(i, F_TMP)
    local carry  = partProperty(i, F_CTYPE)

    -- 2. No task.  An idle ant wanders; an idle ant that is still holding
    --    something walks it home first.  Losing gathered matter to a cancelled
    --    task would be worse than this slightly less literal reading of
    --    "no task means wander", and it looks right either way.
    if taskId == 0 then
        local nx = nestX[cid]
        if carry ~= 0 and nx then
            deliverStep(i, x, y, cid, cx, cy, carry, nx, nestY[cid], false, 0, 0)
        else
            idleStep(i, x, y, cid, cx, cy)
        end
        return false
    end

    -- The cached decision from 50_tasks, refreshed on a stagger.
    local ttl = (cTTL[i] or 0) - 1
    if ttl <= 0 or cTask[i] ~= taskId then
        refreshTask(i, cid, taskId)
        ttl = TASK_REFRESH
    end
    cTTL[i] = ttl

    local mode = cMode[i]
    if mode == M_NONE then
        idleStep(i, x, y, cid, cx, cy)
        return false
    end

    local tx, ty = cTX[i], cTY[i]
    local cellIdx = cCell[i]
    local isCell = cellIdx > 0

    -- A target with no coordinates falls back to the nest, which is where a
    -- gather load belongs anyway.
    if tx < 0 then
        local nx = nestX[cid]
        if nx then tx, ty = nx, nestY[cid] end
    end

    -- 3. Carrying something: deliver it.
    if carry ~= 0 then
        deliverStep(i, x, y, cid, cx, cy, carry, tx, ty, isCell, cellIdx, taskId)
        return false
    end

    -- 4. Empty handed and tasked.
    local want = cElem[i]
    if (mode == M_DELIVER or mode == M_FETCH) and want ~= 0 then
        acquireStep(i, x, y, cid, cx, cy, mode, tx, ty, want, cSrc[i])
    elseif mode == M_SEEK or mode == M_DIG then
        seekDigStep(i, x, y, cid, cx, cy, tick, mode, tx, ty, want, cellIdx, taskId)
    elseif mode == M_PATROL then
        patrolStep(i, x, y, cid, cx, cy, tx, ty, cellIdx, taskId)
    else
        idleStep(i, x, y, cid, cx, cy)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- GUARD: containing errors without a pcall per particle.
--
-- A pcall per ant per frame is 3200 setjmps a frame, which this file will not
-- pay.  Instead:
--   * the first WARMUP_GUARD frames after load run FULLY guarded, so a
--     systematic bug is caught quietly and never reaches TPT's console at all
--   * after that exactly one call per frame is guarded -- the first ant of the
--     frame -- as a cheap continuous canary
--   * every other call sets `inFlight` before the body and clears it after.
--     If the body raises, that flag stays set: TPT's own pcall around Update
--     (LuaElements.cpp luaUpdateWrapper) swallows the error, and the NEXT ant
--     sees the stale flag, counts a fault, names the particle, and drops the
--     whole module back into fully-guarded mode for WARMUP_GUARD frames.
--
-- The tradeoff, stated plainly: the one call that triggers a new fault is
-- unguarded, so that single error is logged by TPT before we notice it.
-- Everything after it is guarded.  A bug therefore costs one console line per
-- incident instead of one per particle per frame, and the simulation never
-- stalls.  After FAULT_LIMIT incidents the update disables itself outright.
-- ---------------------------------------------------------------------------

local guardAll  = WARMUP_GUARD
local guardTick = -1
local inFlight  = -1
local faults    = 0
local disabled  = false

local function countFault()
    faults = faults + 1
    guardAll = WARMUP_GUARD
    if faults >= FAULT_LIMIT then
        disabled = true
        PBX.warn(MOD, "creature update disabled after " .. FAULT_LIMIT .. " faults")
    end
end

--- The Update closure installed by 20_behaviors.lua's `creature` kind.
--- Returns true only when the particle was killed.
function W.update(i, x, y, surround, nt)
    if disabled then return false end

    if inFlight >= 0 then
        local culprit = inFlight
        inFlight = -1
        PBX.warn(MOD, "update raised for particle " .. culprit .. "; re-arming guarded mode")
        countFault()
        if disabled then return false end
    end

    local tick = PBX.tickIndex
    if guardAll > 0 or tick ~= guardTick then
        guardTick = tick
        local ok, res = pcall(workerUpdate, i, x, y)
        if not ok then
            PBX.warn(MOD, res)
            countFault()
            return false
        end
        return res == true
    end

    -- Fast path: two integer stores bracket the body and buy error detection
    -- for a fraction of the cost of a protected call.
    inFlight = i
    local res = workerUpdate(i, x, y)
    inFlight = -1
    return res == true
end

-- ---------------------------------------------------------------------------
-- Census
-- ---------------------------------------------------------------------------

--- Walk every live particle and count one colony's workers.  O(active
--- particles), so this is a cold-path operation only: spawning, where the cap
--- has to be exact, and the periodic resync.
local function recount(cid)
    local wt = workerType or learnedType
    if not wt then liveCount[cid] = 0; return 0 end
    local n = 0
    for i in partsIter() do
        if partProperty(i, F_TYPE) == wt and getColony(i) == cid then n = n + 1 end
    end
    liveCount[cid] = n
    return n
end

--- Live workers in a colony.  Maintained incrementally and resynced every 60
--- ticks, because ants also die by the user's brush, by heat, or by a save
--- load -- none of which route through this module.  Pass `exact` to force a
--- full scan.
function W.count(cid, exact)
    if exact then return recount(cid) end
    return liveCount[cid] or recount(cid)
end

--- Up to `max` particle indices of a colony's workers, as a JSON array.
--- A diagnostic helper for 60_diag: it allocates, so never call it per frame.
function W.list(cid, max)
    max = max or PBX.MAX_WORKERS_PER_COLONY
    local out = PBX.arr({})
    local wt = workerType or learnedType
    if not wt then return out end
    local n = 0
    for i in partsIter() do
        if partProperty(i, F_TYPE) == wt and getColony(i) == cid then
            n = n + 1
            out[n] = i
            if n >= max then break end
        end
    end
    return out
end

--- The resolved worker element id, or nil if it has not been created yet.
function W.elementId()
    return workerType or learnedType
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Initialise a freshly created worker particle.  partCreate resets every
--- field to the element's DefaultProperties (Simulation.cpp create_part), so
--- everything the ant needs has to be written afterwards.  tmp is the tasks
--- column but a brand-new ant has to start idle and 50_tasks is not involved
--- in creation, so zeroing it here is initialisation, not repurposing.
local function initAnt(j, cid, tint, px, py)
    partProperty(j, F_LIFE, WORKER_LIFE)
    partProperty(j, F_CTYPE, 0)
    partProperty(j, F_TMP, 0)
    partProperty(j, F_DCOL, tint)
    setWorkerState(j, S_IDLE)
    setColony(j, cid)
    setClaim(j, 0)
    seedAnt(j)
    cState[j] = S_IDLE
    local ht = resolveHeadType()
    if ht and px then
        local hj = partCreate(-1, px, py - 1, ht)
        if hj and hj >= 0 then headOf[j] = hj end
    end
    checkFieldIds(j)        -- one-shot; the first ant ever created pays for it
end

--- Create up to `count` workers around (x,y), respecting the colony-wide cap.
--- Runs on the simulation thread: partCreate asserts a mutable-sim event
--- (LuaSimulation.cpp:394 -> AssertMonopartAccessEvent -> AssertMutableSimEvent)
--- which the socket thread does not satisfy, hence PBX.defer.
local function doSpawn(cid, count, x, y, spread)
    local wt, werr = resolveWorkerType()
    if not wt then error(werr, 0) end

    -- The cap is a colony total, not a per-call limit, so it is recounted from
    -- the live particles rather than trusted from a running counter.
    local have = recount(cid)
    local room = PBX.MAX_WORKERS_PER_COLONY - have
    if room <= 0 then
        return { spawned = 0, total = have, capped = true }
    end
    if count > room then count = room end

    local tint = colonyTint(cid)
    local spawned = 0
    for _ = 1, count do
        local px, py = nil, nil
        for _ = 1, SPAWN_TRIES do
            local tx = x + random(-spread, spread)
            local ty = y + random(-spread, spread)
            if tx < MINX then tx = MINX elseif tx > MAXX then tx = MAXX end
            if ty < MINY then ty = MINY elseif ty > MAXY then ty = MAXY end
            if cellFreeSlow(tx, ty) then px, py = tx, ty; break end
        end
        if px then
            local j = partCreate(-1, px, py, wt)
            if j and j >= 0 then
                initAnt(j, cid, tint, px, py)
                spawned = spawned + 1
            end
        end
    end

    local total = have + spawned
    liveCount[cid] = total
    return { spawned = spawned, total = total,
             capped = (total >= PBX.MAX_WORKERS_PER_COLONY) }
end

--- Kill up to `count` of a colony's workers, all of them when count is nil,
--- releasing each one's task claim first so blueprint cells do not leak.
--- Killing while iterating sim.parts() is safe: the iterator only moves
--- forward and Parts::Free clears the type, so a freed slot is skipped.
local function doKill(cid, count)
    local wt = workerType or learnedType
    if not wt then return { killed = 0, total = 0 } end
    local killed = 0
    for i in partsIter() do
        if partProperty(i, F_TYPE) == wt and getColony(i) == cid then
            retireAnt(i, partProperty(i, F_TMP), "ordered")
            killAsCorpse(i, cid)
            killed = killed + 1
            if count and killed >= count then break end
        end
    end
    return { killed = killed, total = recount(cid) }
end

--- External kill entry point for 70_people.lua's personKill: same corpse-
--- conversion path colonyKillWorkers uses, for one named particle instead of
--- a colony-wide sweep.  Returns false if `i` is not a live worker particle.
local function externalKill(i, cause)
    local wt = workerType or learnedType
    if not wt or partProperty(i, F_TYPE) ~= wt then return false end
    local cid = getColony(i)
    retireAnt(i, partProperty(i, F_TMP), cause or "ordered")
    killAsCorpse(i, cid)
    return true
end
W.kill = externalKill

--- Personality trait storage for 70_people.lua's personSetTrait; consulted by
--- fleeThreshold above.  Never validated here -- 70_people.lua owns the enum.
function W.setTrait(i, trait) traitOf[i] = trait end
function W.getTrait(i) return traitOf[i] end

PBX.register("colonySpawnWorkers", function(req)
    local cid, e = PBX.vInt(req.colonyId, "colonyId", 0, PBX.MAX_COLONIES)
    if e then return PBX.err(e) end
    local count; count, e = PBX.vInt(req.count, "count", 1, PBX.MAX_WORKERS_PER_COLONY)
    if e then return PBX.err(e) end
    local x, y; x, y, e = PBX.vPixel(req.x, req.y)
    if e then return PBX.err(e) end
    local spread; spread, e = PBX.vInt(req.spread == nil and 8 or req.spread, "spread", 0, 256)
    if e then return PBX.err(e) end

    -- Creating particles is element mutation: it must not happen on the socket
    -- thread, and there is no synchronous wait, so the caller polls jobStatus
    -- for { spawned, total, capped }.
    local job = PBX.defer(function() return doSpawn(cid, count, x, y, spread) end)
    return PBX.ok("colonySpawnWorkers", { job = job, status = "pending" })
end, MOD)

PBX.register("colonyKillWorkers", function(req)
    local cid, e = PBX.vInt(req.colonyId, "colonyId", 0, PBX.MAX_COLONIES)
    if e then return PBX.err(e) end
    local count = nil
    if req.count ~= nil then
        count, e = PBX.vInt(req.count, "count", 1, PBX.MAX_WORKERS_PER_COLONY)
        if e then return PBX.err(e) end
    end
    -- Deferred for the same reason: partKill asserts a mutable-sim event.
    -- jobStatus yields { killed, total }.
    local job = PBX.defer(function() return doKill(cid, count) end)
    return PBX.ok("colonyKillWorkers", { job = job, status = "pending" })
end, MOD)

PBX.register("workerResetFaults", function(req)
    local hadFaults, wasDisabled = faults, disabled
    faults, disabled, guardAll = 0, false, WARMUP_GUARD
    return PBX.ok("workerResetFaults", { hadFaults = hadFaults, wasDisabled = wasDisabled })
end, MOD)

-- ---------------------------------------------------------------------------
-- Cold-path maintenance: everything expensive the update function refuses to
-- do, amortised across frames.
-- ---------------------------------------------------------------------------

PBX.onTick(MOD, function()
    -- One integer decrement a frame is what buys the guarded warm-up window.
    if guardAll > 0 then guardAll = guardAll - 1 end
end, 1)

local resyncPhase = 0
PBX.onTick(MOD, function()
    refreshColonyCache()
    resyncPhase = resyncPhase + 1
    if resyncPhase >= 2 then            -- i.e. every 60 ticks
        resyncPhase = 0
        for cid = 0, PBX.MAX_COLONIES do
            if liveCount[cid] then recount(cid) end
        end
    end
end, 30)

PBX.log(MOD, "worker " .. W.VERSION .. " loaded; momentum in " ..
    (USE_PAVG and "pavg0/pavg1" or "module arrays (pavg aliases tmp3/tmp4 here)"))

end

pbxWorkerMain()
end
