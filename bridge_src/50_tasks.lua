-- ===========================================================================
-- 50_tasks.lua -- colony task engine (PBX.state.tasks)
--
-- Owns everything between "a human asked for a wall" and "an ant is standing
-- on the pixel that wall needs".  Three bridge actions (colonyAssignTask,
-- colonyTaskStatus, colonyCancelTask) and a four-function interface consumed
-- by 40_worker.lua once per ant per frame.
--
-- The central idea is the *blueprint*: every build-shaped task is compiled,
-- once, at assign time, into three flat parallel arrays cx/cy/ce.  Parallel
-- arrays rather than an array of {x=,y=,element=} tables because a 4096-cell
-- blueprint would otherwise be 4096 heap tables that the GC walks forever;
-- three number arrays are three allocations total.  Nothing rescans or
-- recompiles a blueprint after assign time -- forWorker runs 400x per frame
-- and cannot afford to look at 4096 cells, so the only per-frame work is a
-- handful of table lookups (see "hot path" notes on forWorker).
--
-- Fields owned here (spec section 3): `tmp` = task id, `tmp4` = claim token
-- (cell index + 1, 0 when unclaimed).  Always via PBX.getClaim/PBX.setClaim,
-- because tmp4 does not exist on every build and the accessors degrade for us.
-- ===========================================================================

-- All modules are concatenated into ONE Lua chunk by build_autorun.py, and a
-- Lua 5.1 function may hold at most 200 active local variables.  Seven modules
-- declaring their file-level locals in that single main chunk overruns it and
-- the whole autorun fails to compile ("main function has more than 200 local
-- variables") -- which takes down every module, not just the one that tipped
-- the count over.  Wrapping this module's body in do ... end scopes its ~60
-- locals to the block, so the compiler releases those registers at the `end`
-- below and the modules that follow start from a clean budget.  Everything
-- this module publishes leaves through PBX.register / PBX.state.tasks, so
-- nothing needs to survive the block.
do

local M   = PBX.state.tasks
local MOD = "tasks"

M.VERSION = "1.0.0"

local W, H       = PBX.SIM_W, PBX.SIM_H
local MAX_CELLS  = PBX.MAX_BLUEPRINT_CELLS
local MAX_TASKS  = PBX.MAX_TASKS_PER_COLONY
local MAX_CREW   = PBX.MAX_WORKERS_PER_COLONY

local KINDS = { "gather", "dig", "buildLine", "buildBox", "buildCircle",
                "buildBlueprint", "patrol" }

-- Cell lifecycle inside a blueprint.  Kept as small integers in a dense
-- array: 4096 booleans-in-tables would cost the same but read worse.
local CELL_PENDING, CELL_CLAIMED, CELL_DONE = 0, 1, 2

-- ---------------------------------------------------------------------------
-- Module-private registry
-- ---------------------------------------------------------------------------

local tasksById = {}   -- [taskId]  = task record (ids are unique across colonies
                       --             because a worker carries only `tmp`)
local byColony  = {}   -- [colonyId] = array of task records, kept sorted by
                       --             (priority desc, createdAt asc) at mutation
                       --             time so assignWorker never sorts
local nextTaskId = 1
local createSeq  = 0
local dirty      = false
local lastWarnTick = -1000

--- Rate-limited warning.  forWorker is called 400x per frame; a genuine bug
--- there would otherwise write 24000 log lines a second and stall on io.
local function warnOnce(msg)
    if PBX.tickIndex - lastWarnTick < 600 then return end
    lastWarnTick = PBX.tickIndex
    PBX.warn(MOD, msg)
end

-- ---------------------------------------------------------------------------
-- Talking to 30_colony.lua
--
-- We are loaded after it but must still tolerate it being absent entirely --
-- a missing colony module has to surface as a clean error from an action, not
-- as an index-a-nil crash at load time that takes the whole autorun down.
-- The exact shape of its published helpers is not pinned by the spec beyond
-- `phero` and `takeStore`, so every call below is probed and optional.
-- ---------------------------------------------------------------------------

--- The colony module table, or nil plus a message fit for PBX.err.
local function colonyMod()
    local c = PBX.state.colony
    if type(c) ~= "table" or next(c) == nil then
        return nil, "colony module unavailable (30_colony.lua not loaded)"
    end
    return c, nil
end

--- True when the colony id is known to exist.  If the colony module exposes
--- no way to ask, we assume yes: refusing a task because we cannot verify
--- would be worse than letting it stall visibly.
local function colonyExists(c, id)
    if type(c.exists) == "function" then
        local ok, r = pcall(c.exists, id)
        if ok then return r and true or false end
    end
    if type(c.get) == "function" then
        local ok, r = pcall(c.get, id)
        if ok then return r ~= nil end
    end
    if type(c.colonies) == "table" then return c.colonies[id] ~= nil end
    return true
end

--- Nest pixel for a colony, or nil.  Called only through the per-task cache
--- below -- a cross-module lookup per ant per frame is exactly the kind of
--- cost forWorker must not pay.
local function nestOf(id)
    local c = PBX.state.colony
    if type(c) ~= "table" then return nil end
    if type(c.nest) == "function" then
        local ok, a, b = pcall(c.nest, id)
        if ok and type(a) == "table" then
            return a.x or a.nestX, a.y or a.nestY
        elseif ok and type(a) == "number" and type(b) == "number" then
            return a, b
        end
    end
    local rec
    if type(c.get) == "function" then
        local ok, r = pcall(c.get, id); if ok then rec = r end
    elseif type(c.colonies) == "table" then
        rec = c.colonies[id]
    end
    if type(rec) == "table" then
        local x = rec.nestX or rec.nest_x or (rec.nest and rec.nest.x)
        local y = rec.nestY or rec.nest_y or (rec.nest and rec.nest.y)
        if x and y then return x, y end
    end
    return nil
end

--- Put material back / deposit gathered material.  The spec names only
--- takeStore, so the deposit half is probed under the three plausible names
--- and silently skipped if the colony module offers none -- losing a unit of
--- book-keeping is preferable to breaking delivery.
local function addStore(colonyId, elem, n)
    local c = PBX.state.colony
    if type(c) ~= "table" then return false end
    local fn = c.addStore or c.putStore or c.giveStore
    if type(fn) ~= "function" then return false end
    local ok = pcall(fn, colonyId, elem, n or 1)
    return ok
end

--- Take `n` (default 1) units of `elem` out of the colony store.  Returns
--- true only on a full take: 30_colony.lua's takeStore returns how many units
--- it actually removed, which may be fewer than asked, and a partial take
--- would leave us believing a cell is funded when it is not.
--- Treated as "not available" on any failure, including the function being
--- absent, so a store-sourced task degrades to `blocked` instead of erroring.
local function takeStore(colonyId, elem, n)
    n = n or 1
    local c = PBX.state.colony
    if type(c) ~= "table" or type(c.takeStore) ~= "function" then return false end
    local ok, r = pcall(c.takeStore, colonyId, elem, n)
    if not ok then return false end
    if type(r) == "number" then
        if r >= n then return true end
        if r > 0 then addStore(colonyId, elem, r) end   -- hand back a partial take
        return false
    end
    return r and true or false                          -- tolerate a boolean API
end

-- ---------------------------------------------------------------------------
-- Blueprint compilation
--
-- Every generated shape funnels through emit(), which clips to the canvas and
-- de-duplicates.  De-duplication matters for correctness, not tidiness: two
-- blueprint entries on one pixel means two ants each claim "their" cell,
-- both walk to the same pixel, and the second one's completion is a lie.
-- Midpoint circles emit duplicates at every octant seam, so this is not
-- hypothetical.
-- ---------------------------------------------------------------------------

local function emitNew()
    return { n = 0, cx = {}, cy = {}, ce = {}, seen = {} }
end

local function emit(B, x, y, e)
    if x < 0 or y < 0 or x >= W or y >= H then return end  -- clip, do not error:
    -- a circle whose rim leaves the canvas is a reasonable request, and the
    -- cap is measured against what is actually buildable.
    local key = y * W + x
    if B.seen[key] then return end
    B.seen[key] = true
    local n = B.n + 1
    B.n = n; B.cx[n] = x; B.cy[n] = y; B.ce[n] = e
end

--- Bresenham, integer only.  Endpoints are validated in bounds by the caller
--- so no clipping occurs and the count is exactly max(|dx|,|dy|)+1.
local function lineCells(B, x1, y1, x2, y2, e)
    local dx = math.abs(x2 - x1)
    local dy = math.abs(y2 - y1)
    local sx = x1 < x2 and 1 or -1
    local sy = y1 < y2 and 1 or -1
    local err = dx - dy
    local x, y = x1, y1
    while true do
        emit(B, x, y, e)
        if x == x2 and y == y2 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x = x + sx end
        if e2 < dx then err = err + dx; y = y + sy end
    end
end

local function boxCells(B, x1, y1, x2, y2, filled, e)
    if x1 > x2 then x1, x2 = x2, x1 end
    if y1 > y2 then y1, y2 = y2, y1 end
    if filled then
        for y = y1, y2 do
            for x = x1, x2 do emit(B, x, y, e) end
        end
        return
    end
    -- Outline: full top and bottom rows, then the two side columns without
    -- re-emitting the corners (emit would dedupe them anyway, this is just
    -- cheaper).
    for x = x1, x2 do
        emit(B, x, y1, e)
        emit(B, x, y2, e)
    end
    for y = y1 + 1, y2 - 1 do
        emit(B, x1, y, e)
        emit(B, x2, y, e)
    end
end

--- Midpoint circle, driving a callback rather than emitting directly so the
--- same traversal can be used to count cells before committing memory to
--- them (see compile() -- a filled circle of radius 900 is 2.5M cells and we
--- must report that number without ever building the array).
local function circleWalk(cx, cy, r, filled, fn)
    if r <= 0 then fn(cx, cy); return end
    local x, y = r, 0
    local err = 1 - r
    while x >= y do
        if filled then
            -- Horizontal spans: the two mirrored pairs cover the whole disc.
            fn(cx - x, cy + y, x * 2 + 1)
            fn(cx - x, cy - y, x * 2 + 1)
            fn(cx - y, cy + x, y * 2 + 1)
            fn(cx - y, cy - x, y * 2 + 1)
        else
            fn(cx + x, cy + y); fn(cx - x, cy + y)
            fn(cx + x, cy - y); fn(cx - x, cy - y)
            fn(cx + y, cy + x); fn(cx - y, cy + x)
            fn(cx + y, cy - x); fn(cx - y, cy - x)
        end
        y = y + 1
        if err < 0 then
            err = err + 2 * y + 1
        else
            x = x - 1
            err = err + 2 * (y - x) + 1
        end
    end
end

--- Clip a horizontal span to the canvas; returns x0, count (count may be 0).
local function clipSpan(x, y, len)
    if y < 0 or y >= H then return 0, 0 end
    local x2 = x + len - 1
    if x < 0 then x = 0 end
    if x2 > W - 1 then x2 = W - 1 end
    if x2 < x then return 0, 0 end
    return x, x2 - x + 1
end

local function tooBig(n)
    return nil, "blueprint would be " .. n .. " cells, limit is " .. MAX_CELLS
end

--- Compile a validated spec into cx/cy/ce/total.
--- Returns bp (a table with n/cx/cy/ce), nil on success or nil, message.
--- Rejects -- never truncates -- an oversized shape, and names the real count
--- so the caller can shrink it intelligently.
local function compile(kind, spec)
    local B

    if kind == "buildLine" then
        local n = math.max(math.abs(spec.x2 - spec.x1), math.abs(spec.y2 - spec.y1)) + 1
        if n > MAX_CELLS then return tooBig(n) end
        B = emitNew()
        lineCells(B, spec.x1, spec.y1, spec.x2, spec.y2, spec.element)

    elseif kind == "buildBox" or kind == "dig" then
        local x1, y1 = spec.x1, spec.y1
        local x2, y2 = spec.x2, spec.y2
        if x1 > x2 then x1, x2 = x2, x1 end
        if y1 > y2 then y1, y2 = y2, y1 end
        local bw, bh = x2 - x1 + 1, y2 - y1 + 1
        -- Analytic pre-count: never allocate an array we are about to reject.
        local filled = spec.filled
        if kind == "dig" then filled = true end
        local n
        if filled then
            n = bw * bh
        elseif bw < 3 or bh < 3 then
            n = bw * bh                      -- degenerate box: outline == fill
        else
            n = 2 * bw + 2 * bh - 4
        end
        if n > MAX_CELLS then return tooBig(n) end
        B = emitNew()
        boxCells(B, x1, y1, x2, y2, filled, spec.element)

    elseif kind == "buildCircle" then
        local n = 0
        if spec.filled then
            circleWalk(spec.cx, spec.cy, spec.radius, true, function(x, y, len)
                local _, c = clipSpan(x, y, len)
                n = n + c
            end)
            -- Spans overlap between the mirrored pairs, so this over-counts;
            -- only reject when even the over-count is small enough to be
            -- wrong about, i.e. reject when it is genuinely hopeless.
            if n > MAX_CELLS * 4 then return tooBig(n) end
        end
        B = emitNew()
        if spec.filled then
            circleWalk(spec.cx, spec.cy, spec.radius, true, function(x, y, len)
                local x0, c = clipSpan(x, y, len)
                for k = 0, c - 1 do emit(B, x0 + k, y, spec.element) end
            end)
        else
            circleWalk(spec.cx, spec.cy, spec.radius, false, function(x, y)
                emit(B, x, y, spec.element)
            end)
        end

    elseif kind == "buildBlueprint" then
        local cells = spec.cells
        if #cells > MAX_CELLS then return tooBig(#cells) end
        B = emitNew()
        for k = 1, #cells do
            local c = cells[k]
            emit(B, c.x, c.y, c.element or spec.element)
        end

    else
        return nil, "kind " .. tostring(kind) .. " has no blueprint"
    end

    if B.n > MAX_CELLS then return tooBig(B.n) end
    if B.n == 0 then return nil, "blueprint compiled to 0 cells" end
    B.seen = nil   -- the dedupe set is compile-time scaffolding; drop it so a
                   -- 4096-cell blueprint does not keep a 4096-entry hash alive
    return B, nil
end

-- ---------------------------------------------------------------------------
-- Task records
-- ---------------------------------------------------------------------------

--- Re-sort one colony's task list.  Only ever called on mutation (assign,
--- cancel, completion) so assignWorker -- which runs for every idle ant --
--- is a straight linear scan over at most MAX_TASKS_PER_COLONY entries.
local function resort(colonyId)
    local list = byColony[colonyId]
    if not list then return end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.createdAt < b.createdAt      -- ties break by creation order
    end)
end

local function isLive(t)
    return t.status ~= "done" and t.status ~= "cancelled"
end

local function liveCount(colonyId)
    local list = byColony[colonyId]
    if not list then return 0 end
    local n = 0
    for k = 1, #list do
        if isLive(list[k]) then n = n + 1 end
    end
    return n
end

local function markDirty() dirty = true end

-- ---------------------------------------------------------------------------
-- Persistence
--
-- We save the *recipe*, not the compiled cells.  A 4096-cell blueprint as
-- three JSON arrays is ~40KB of numbers we can regenerate deterministically
-- from six integers, and buildBlueprint is the only kind whose cells really
-- are irreducible input.  Claims are deliberately not saved: after a restart
-- every particle that held one is gone (spec 4.5).
--
-- Flush cadence: structural changes (assign / cancel / task finished) write
-- immediately; per-cell progress only marks dirty and is flushed by the
-- 60-tick hook.  Writing pbx-tasks.json on every completed cell would mean
-- hundreds of synchronous file writes per second on the simulation thread.
-- ---------------------------------------------------------------------------

local function serialise(t)
    return {
        id         = t.id,
        colonyId   = t.colonyId,
        kind       = t.kind,
        priority   = t.priority,
        workersCap = t.workersCap,
        status     = (t.status == "active") and "pending" or t.status,
        reason     = t.reason,
        createdAt  = t.createdAt,
        source     = t.source,
        spec       = t.rawSpec,
        progress   = t.progress,
        done       = PBX.arr(t.doneList or {}),
    }
end

local function flush()
    dirty = false
    local out = PBX.arr({})
    for _, t in pairs(tasksById) do
        out[#out + 1] = serialise(t)
    end
    local ok, err = PBX.save("tasks", { version = M.VERSION, nextId = nextTaskId, tasks = out })
    if not ok then warnOnce("save failed: " .. tostring(err)) end
end

local function saveNow()
    dirty = false
    flush()
end

-- ---------------------------------------------------------------------------
-- Claim book-keeping
--
-- Three structures, all sparse or O(1):
--   t.cellState[idx]  dense small-int array, the authoritative cell status
--   t.claims[idx]     cell index -> particle index   (sparse, <= crew size)
--   t.byWorker[i]     particle index -> cell index   (sparse, <= crew size)
-- The sweep walks t.crew, never the blueprint, so its cost is bounded by the
-- number of live ants and not by the 4096-cell array.
-- ---------------------------------------------------------------------------

--- Give cell `idx` of task `t` to particle `i`.  Writes the tmp4 claim token
--- ourselves rather than trusting the worker to do it, because tmp4 is this
--- module's field (spec section 3) and the stale sweep validates against it.
local function claimCell(t, i, idx)
    t.cellState[idx] = CELL_CLAIMED
    t.claims[idx]    = i
    t.byWorker[i]    = idx
    t.pending        = t.pending - 1
    t.claimed        = t.claimed + 1
    PBX.setClaim(i, idx + 1)
end

--- Drop particle `i`'s claim on task `t` without completing it.  The cell
--- goes back to pending and the cursor rewinds if the freed cell is behind
--- it -- without the rewind a released cell in front of the cursor's wake is
--- never revisited and the blueprint stalls one cell short forever.
local function unclaim(t, i, refund)
    local idx = t.byWorker[i]
    if not idx then return false end
    t.byWorker[i] = nil
    t.claims[idx] = nil
    if t.cellState[idx] == CELL_CLAIMED then
        t.cellState[idx] = CELL_PENDING
        t.pending  = t.pending + 1
        t.claimed  = t.claimed - 1
        if idx < t.cursor then t.cursor = idx end
    end
    if refund and t.source == "store" and t.reserved and t.reserved[i] then
        -- The unit was taken out of the store when the cell was claimed; an
        -- ant that dies mid-haul must not permanently consume it.
        addStore(t.colonyId, t.reserved[i], 1)
        t.reserved[i] = nil
    end
    PBX.setClaim(i, 0)
    return true
end

--- Remove a particle from a task entirely (claim, crew slot, patrol cursor).
local function dropWorker(t, i, refund)
    unclaim(t, i, refund)
    if t.crew[i] then
        t.crew[i]  = nil
        t.crewCount = t.crewCount - 1
        if t.crewCount < 0 then t.crewCount = 0 end
    end
    if t.patrolAt then t.patrolAt[i] = nil end
    if t.reserved then t.reserved[i] = nil end
end

--- Next pending cell for a new claimant, or nil.
--- The cursor is the whole point: a linear rescan from index 1 on every claim
--- would be O(cells) per claim and O(cells * ants) per blueprint.  Cells
--- behind the cursor are done or claimed; unclaim() rewinds when that stops
--- being true, so the scan is amortised O(1) plus at most one pass per task.
local function nextCell(t)
    if t.pending <= 0 then return nil end
    local n     = t.total
    local state = t.cellState
    local c     = t.cursor
    while c <= n do
        if state[c] == CELL_PENDING then t.cursor = c + 1; return c end
        c = c + 1
    end
    -- Pending cells exist but all sit behind the cursor (possible only after
    -- an unusual release ordering).  One wrapped pass, then give up.
    c = 1
    while c <= n do
        if state[c] == CELL_PENDING then t.cursor = c + 1; return c end
        c = c + 1
    end
    t.cursor = n + 1
    return nil
end

local function finish(t)
    t.status = "done"
    t.reason = nil
    resort(t.colonyId)
    saveNow()
end

-- ---------------------------------------------------------------------------
-- Validation helpers for action parameters
-- ---------------------------------------------------------------------------

--- Accept both {x1=,y1=,x2=,y2=} and positional {x1,y1,x2,y2}; the MCP layer
--- and hand-written calls disagree about which is natural.
local function vRect(r, label)
    if type(r) ~= "table" then return nil, label .. " must be {x1,y1,x2,y2}" end
    local x1, e = PBX.vInt(r.x1 or r[1], label .. ".x1", 0, W - 1); if e then return nil, e end
    local y1;   y1, e = PBX.vInt(r.y1 or r[2], label .. ".y1", 0, H - 1); if e then return nil, e end
    local x2;   x2, e = PBX.vInt(r.x2 or r[3], label .. ".x2", 0, W - 1); if e then return nil, e end
    local y2;   y2, e = PBX.vInt(r.y2 or r[4], label .. ".y2", 0, H - 1); if e then return nil, e end
    return { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }, nil
end

--- Build the normalised, JSON-safe spec for a kind.  Element inputs are kept
--- in their original form under `elemSpec` so that a restart can re-resolve
--- them: a custom element's numeric id is not stable across runs, its name is.
local function buildSpec(kind, p)
    local spec = {}
    local e

    if kind == "gather" then
        spec.elemSpec = p.element
        spec.element, e = PBX.vElem(p.element); if e then return nil, e end
        local r; r, e = vRect(p.region, "region"); if e then return nil, e end
        spec.x1, spec.y1, spec.x2, spec.y2 = r.x1, r.y1, r.x2, r.y2
        spec.amount, e = PBX.vInt(p.amount == nil and 10 or p.amount, "amount", 1, 100000)
        if e then return nil, e end

    elseif kind == "dig" then
        local r; r, e = vRect(p.region, "region"); if e then return nil, e end
        spec.x1, spec.y1, spec.x2, spec.y2 = r.x1, r.y1, r.x2, r.y2
        if p.element ~= nil then
            spec.elemSpec = p.element
            spec.element, e = PBX.vElem(p.element); if e then return nil, e end
        else
            spec.element = 0                      -- 0 == "whatever is there"
        end

    elseif kind == "buildLine" or kind == "buildBox" then
        spec.elemSpec = p.element
        spec.element, e = PBX.vElem(p.element); if e then return nil, e end
        spec.x1, e = PBX.vInt(p.x1, "x1", 0, W - 1); if e then return nil, e end
        spec.y1, e = PBX.vInt(p.y1, "y1", 0, H - 1); if e then return nil, e end
        spec.x2, e = PBX.vInt(p.x2, "x2", 0, W - 1); if e then return nil, e end
        spec.y2, e = PBX.vInt(p.y2, "y2", 0, H - 1); if e then return nil, e end
        if kind == "buildBox" then
            spec.filled, e = PBX.vBool(p.filled, "filled", false); if e then return nil, e end
        end

    elseif kind == "buildCircle" then
        spec.elemSpec = p.element
        spec.element, e = PBX.vElem(p.element); if e then return nil, e end
        spec.cx, e = PBX.vInt(p.cx, "cx", 0, W - 1); if e then return nil, e end
        spec.cy, e = PBX.vInt(p.cy, "cy", 0, H - 1); if e then return nil, e end
        -- 1024 comfortably exceeds the canvas diagonal, so a legitimate
        -- circle is never refused here; it bounds the midpoint walk.
        spec.radius, e = PBX.vInt(p.radius, "radius", 0, 1024); if e then return nil, e end
        spec.filled, e = PBX.vBool(p.filled, "filled", false); if e then return nil, e end

    elseif kind == "buildBlueprint" then
        local cells; cells, e = PBX.vList(p.cells, "cells", MAX_CELLS)
        if e then
            -- vList's cap message hides the real size, and the contract says
            -- name the actual count.
            if type(p.cells) == "table" then
                return nil, "blueprint would be " .. #p.cells .. " cells, limit is " .. MAX_CELLS
            end
            return nil, e
        end
        if #cells == 0 then return nil, "cells must not be empty" end
        local defElem
        if p.element ~= nil then
            spec.elemSpec = p.element
            defElem, e = PBX.vElem(p.element); if e then return nil, e end
            spec.element = defElem
        end
        local out = {}
        for k = 1, #cells do
            local c = cells[k]
            if type(c) ~= "table" then return nil, "cells[" .. k .. "] must be a table" end
            local x, y
            x, e = PBX.vInt(c.x or c[1], "cells[" .. k .. "].x", 0, W - 1); if e then return nil, e end
            y, e = PBX.vInt(c.y or c[2], "cells[" .. k .. "].y", 0, H - 1); if e then return nil, e end
            local ce = c.element or c[3]
            local eid
            if ce ~= nil then
                eid, e = PBX.vElem(ce); if e then return nil, e end
            elseif defElem then
                eid, ce = defElem, spec.elemSpec
            else
                return nil, "cells[" .. k .. "] needs an element (or set a task-level element)"
            end
            out[k] = { x = x, y = y, element = eid, elemSpec = ce }
        end
        spec.cells = out

    elseif kind == "patrol" then
        local pts; pts, e = PBX.vList(p.points, "points", 64); if e then return nil, e end
        if #pts < 1 then return nil, "points must not be empty" end
        local out = {}
        for k = 1, #pts do
            local c = pts[k]
            if type(c) ~= "table" then return nil, "points[" .. k .. "] must be a table" end
            local x, y
            x, e = PBX.vInt(c.x or c[1], "points[" .. k .. "].x", 0, W - 1); if e then return nil, e end
            y, e = PBX.vInt(c.y or c[2], "points[" .. k .. "].y", 0, H - 1); if e then return nil, e end
            out[k] = { x = x, y = y }
        end
        spec.points = out
        -- loops = 0 means patrol forever; such a task never reaches `done`.
        spec.loops, e = PBX.vInt(p.loops == nil and 1 or p.loops, "loops", 0, 10000)
        if e then return nil, e end
    end

    return spec, nil
end

--- Re-resolve element ids from the stored names.  Called after a restore,
--- and retried by the sweep while it keeps failing, because custom elements
--- are recreated by 10_registry.lua's own deferred jobs and may not exist yet
--- when we come back.
local function resolveElements(spec, kind)
    local e
    if spec.elemSpec ~= nil then
        spec.element, e = PBX.vElem(spec.elemSpec)
        if e then return false, e end
    end
    if kind == "buildBlueprint" and spec.cells then
        for k = 1, #spec.cells do
            local c = spec.cells[k]
            if c.elemSpec ~= nil then
                local id; id, e = PBX.vElem(c.elemSpec)
                if e then return false, e end
                c.element = id
            end
        end
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- Task construction
-- ---------------------------------------------------------------------------

local BLUEPRINT_KINDS = {
    dig = "dig", buildLine = "deliver", buildBox = "deliver",
    buildCircle = "deliver", buildBlueprint = "deliver",
}

--- Build the live task record from a validated spec.  Returns task, nil or
--- nil, message.  `doneList` optionally replays completed cells from a saved
--- file.  Touches no particles, so it is safe to call from the HTTP handler.
local function makeTask(id, colonyId, kind, spec, priority, workersCap, source, doneList)
    local t = {
        id = id, colonyId = colonyId, kind = kind,
        priority = priority, workersCap = workersCap,
        source = source, status = "pending", reason = nil,
        rawSpec = spec,
        crew = {}, crewCount = 0,
        progress = 0, doneCount = 0, claimed = 0,
        doneList = {},
    }

    local cellMode = BLUEPRINT_KINDS[kind]
    if cellMode then
        local B, err = compile(kind, spec)
        if not B then return nil, err end
        t.cellMode  = cellMode
        t.cx, t.cy, t.ce = B.cx, B.cy, B.ce
        t.total     = B.n
        t.cellState = {}
        for k = 1, B.n do t.cellState[k] = CELL_PENDING end
        t.pending  = B.n
        t.cursor   = 1
        t.claims   = {}
        t.byWorker = {}
        t.retry    = {}          -- sparse: cellIndex -> failed verification count
        if source == "store" then t.reserved = {} end
        if doneList then
            for k = 1, #doneList do
                local idx = doneList[k]
                if type(idx) == "number" and idx >= 1 and idx <= B.n
                   and t.cellState[idx] == CELL_PENDING then
                    t.cellState[idx] = CELL_DONE
                    t.pending   = t.pending - 1
                    t.doneCount = t.doneCount + 1
                    t.doneList[#t.doneList + 1] = idx
                end
            end
            t.progress = t.doneCount
        end
        if t.doneCount >= t.total then t.status = "done" end

    elseif kind == "gather" then
        t.total   = spec.amount
        t.element = spec.element
        t.claims, t.byWorker = {}, {}    -- unused, kept for uniform teardown

    elseif kind == "patrol" then
        t.px, t.py = {}, {}
        for k = 1, #spec.points do
            t.px[k] = spec.points[k].x
            t.py[k] = spec.points[k].y
        end
        t.npoints  = #spec.points
        t.total    = (spec.loops > 0) and (spec.loops * t.npoints) or 0
        t.patrolAt = {}
        t.claims, t.byWorker = {}, {}
    end

    return t, nil
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- colonyAssignTask: validate, compile the blueprint and register the task.
--- Fully synchronous -- we allocate no elements and touch no particles, so
--- none of PBX.defer's constraints apply and the caller gets a real taskId
--- and cell count back in one round trip.
PBX.register("colonyAssignTask", function(req)
    local c, cerr = colonyMod()
    if not c then return PBX.err(cerr) end

    local colonyId, e = PBX.vInt(req.colonyId, "colonyId", 1, PBX.MAX_COLONIES)
    if e then return PBX.err(e) end
    if not colonyExists(c, colonyId) then
        return PBX.err("no such colony: " .. colonyId)
    end

    local kind; kind, e = PBX.vEnum(req.kind, "kind", KINDS)
    if e then return PBX.err(e) end

    local priority; priority, e = PBX.vInt(req.priority == nil and 5 or req.priority, "priority", 1, 9)
    if e then return PBX.err(e) end

    local workersCap
    if req.workers ~= nil then
        workersCap, e = PBX.vInt(req.workers, "workers", 1, MAX_CREW)
        if e then return PBX.err(e) end
    end

    -- Params may be nested under `params` (spec 4.5) or flattened by a
    -- caller that finds that awkward; accept both.
    local p = req.params
    if type(p) ~= "table" then p = req end

    local source = "spawn"
    if p.source ~= nil then
        source, e = PBX.vEnum(p.source, "source", { "store", "spawn" })
        if e then return PBX.err(e) end
    end

    if liveCount(colonyId) >= MAX_TASKS then
        return PBX.err("colony " .. colonyId .. " already has " .. MAX_TASKS ..
                       " active tasks (limit " .. MAX_TASKS .. "); cancel one first")
    end

    local spec; spec, e = buildSpec(kind, p)
    if not spec then return PBX.err(e) end

    local id = nextTaskId
    local t; t, e = makeTask(id, colonyId, kind, spec, priority, workersCap, source, nil)
    if not t then return PBX.err(e) end

    nextTaskId = nextTaskId + 1
    createSeq  = createSeq + 1
    t.createdAt = createSeq

    tasksById[id] = t
    byColony[colonyId] = byColony[colonyId] or {}
    local list = byColony[colonyId]
    list[#list + 1] = t
    resort(colonyId)
    saveNow()

    PBX.log(MOD, "task " .. id .. " " .. kind .. " colony=" .. colonyId ..
                 " total=" .. tostring(t.total) .. " source=" .. source)

    return PBX.ok("colonyAssignTask", {
        taskId = id, colonyId = colonyId, kind = kind,
        total = t.total, priority = priority, source = source,
        status = t.status, workers = workersCap,
    })
end, MOD)

--- One task rendered for the wire.
local function taskInfo(t)
    local total = t.total or 0
    local done  = t.doneCount
    if t.cellMode == nil then done = t.progress end
    return {
        id       = t.id,
        kind     = t.kind,
        status   = t.status,
        reason   = t.reason,
        priority = t.priority,
        source   = t.source,
        element  = t.rawSpec and t.rawSpec.element,
        total    = total,
        done     = done,
        claimed  = t.claimed,
        workers  = t.crewCount,
        -- Cells counted done that the world never actually confirmed; 0 in a
        -- healthy build, non-zero means the blueprint asked for something the
        -- ants could not physically place.
        unverified = t.unverified,
        cap      = t.workersCap,
        -- progress is the completion fraction; `done`/`total` carry the raw
        -- counts so a caller never has to divide to get either.
        progress = (total > 0) and (math.floor((done / total) * 1000) / 1000) or 0,
    }
end

--- colonyTaskStatus: one task, or every task the colony has ever had this run
--- (terminal ones included, so a caller can see what finished).
PBX.register("colonyTaskStatus", function(req)
    local c, cerr = colonyMod()
    if not c then return PBX.err(cerr) end

    local colonyId, e = PBX.vInt(req.colonyId, "colonyId", 1, PBX.MAX_COLONIES)
    if e then return PBX.err(e) end

    if req.taskId ~= nil then
        local id; id, e = PBX.vInt(req.taskId, "taskId", 1)
        if e then return PBX.err(e) end
        local t = tasksById[id]
        if not t or t.colonyId ~= colonyId then
            return PBX.err("no such task " .. id .. " for colony " .. colonyId)
        end
        return PBX.ok("colonyTaskStatus", { colonyId = colonyId, tasks = PBX.arr({ taskInfo(t) }) })
    end

    local list = byColony[colonyId] or {}
    local out  = PBX.arr({})
    for k = 1, #list do out[k] = taskInfo(list[k]) end
    return PBX.ok("colonyTaskStatus", { colonyId = colonyId, tasks = out, count = #out })
end, MOD)

--- colonyCancelTask: stop a task and free every claim it holds.  Workers
--- notice on their next forWorker call and fall back to assignWorker.
PBX.register("colonyCancelTask", function(req)
    local c, cerr = colonyMod()
    if not c then return PBX.err(cerr) end

    local colonyId, e = PBX.vInt(req.colonyId, "colonyId", 1, PBX.MAX_COLONIES)
    if e then return PBX.err(e) end
    local id; id, e = PBX.vInt(req.taskId, "taskId", 1)
    if e then return PBX.err(e) end

    local t = tasksById[id]
    if not t or t.colonyId ~= colonyId then
        return PBX.err("no such task " .. id .. " for colony " .. colonyId)
    end
    if not isLive(t) then
        return PBX.ok("colonyCancelTask", { taskId = id, cancelled = false, status = t.status })
    end

    -- Refund reserved material; the ants carrying it are about to be retasked.
    for i in pairs(t.crew) do dropWorker(t, i, true) end
    t.crewCount = 0
    t.status    = "cancelled"
    t.reason    = nil
    resort(colonyId)
    saveNow()

    return PBX.ok("colonyCancelTask", { taskId = id, cancelled = true, status = "cancelled" })
end, MOD)

-- ---------------------------------------------------------------------------
-- Worker interface
--
-- Called by 40_worker.lua.  40_worker.lua does not exist on disk yet, so this
-- is the spec's shape verbatim.
-- ---------------------------------------------------------------------------

-- One shared result table, reused for every call.  forWorker runs up to 400
-- times per frame; allocating a fresh 5-field table each time is 24000 short
-- lived tables a second and a visible GC cost in a 60fps sim loop.  The
-- contract that buys this: the caller must read the returned table before it
-- calls forWorker again.  Every field is rewritten on every call so nothing
-- leaks from the previous ant.
local R = { mode = "idle", tx = nil, ty = nil, element = nil, cellIndex = nil }

local function res(mode, tx, ty, elem, cellIndex)
    R.mode = mode; R.tx = tx; R.ty = ty; R.element = elem; R.cellIndex = cellIndex
    return R
end

--- Element the ant is currently holding (ctype, 0 = empty handed).
local function carried(i)
    local v = sim.partProperty(i, "ctype")
    return v or 0
end

--- Nest pixel, cached on the task record.  Resolved lazily and refreshed by
--- the 60-tick sweep so the hot path is two field reads, not a cross-module
--- probe with pcalls in it.
local function nestFor(t)
    if t.nestX then return t.nestX, t.nestY end
    local x, y = nestOf(t.colonyId)
    if not x then
        -- Colony module cannot tell us; aim at the canvas centre so haulers
        -- at least converge somewhere instead of standing still.
        x, y = math.floor(W / 2), math.floor(H / 2)
    end
    t.nestX, t.nestY = x, y
    return x, y
end

--- Deterministic per-ant scatter inside a region so a hundred gatherers do
--- not stack on one pixel.  Knuth multiplicative hash on the particle index:
--- no randomness (an ant must keep walking towards the same spot between
--- frames) and no allocation.
local function scatter(t, i)
    local s  = t.rawSpec
    local w  = s.x2 - s.x1
    local h  = s.y2 - s.y1
    if w < 0 then w = -w end
    if h < 0 then h = -h end
    local lx = (s.x1 < s.x2) and s.x1 or s.x2
    local ly = (s.y1 < s.y2) and s.y1 or s.y2
    local hx = (i * 2654435761) % (w + 1)
    local hy = (i * 40503 + 7)  % (h + 1)
    return lx + hx, ly + hy
end

--- Put ant `i` on task `t`'s roster, honouring the optional worker cap.
--- Returns false when the task is full.  Crew membership is what `workers`
--- caps count, and the sweep is what removes the dead from it.
local function joinCrew(t, i)
    if t.crew[i] then return true end
    if t.workersCap and t.crewCount >= t.workersCap then return false end
    t.crew[i]   = true
    t.crewCount = t.crewCount + 1
    return true
end

local function blockTask(t, why)
    if t.status ~= "blocked" or t.reason ~= why then
        t.status = "blocked"
        t.reason = why
        markDirty()
    end
end

local function activate(t)
    if t.status == "pending" or t.status == "blocked" then
        t.status = "active"
        t.reason = nil
        markDirty()
    end
end

local function forWorkerInner(i, colonyId, taskId)
    if not taskId or taskId == 0 then return res("idle") end
    local t = tasksById[taskId]
    if t and t.unresolved then
        -- Restored task whose element name does not exist yet; the sweep is
        -- retrying.  Handing out cells now would deliver a nil element.
        return res("idle")
    end
    if not t or t.colonyId ~= colonyId or not isLive(t) then
        -- Task gone, cancelled or finished: make sure this ant is not still
        -- holding a claim on it before we send it back to assignWorker.
        if t then dropWorker(t, i, true) else PBX.setClaim(i, 0) end
        return res("idle")
    end

    -- Crew membership and the optional per-task worker cap.  assignWorker
    -- cannot register the ant (it is not given a particle index), so the cap
    -- is enforced for real here, on first contact -- and again by the
    -- dispatcher, which registers ants as it hands out task ids.
    if not joinCrew(t, i) then
        return res("idle")                   -- full: the dispatcher retasks it
    end
    activate(t)

    if t.cellMode then
        -- ---- blueprint kinds (dig / build*) ------------------------------
        -- Hot path: one table lookup.  We trust our own byWorker mirror over
        -- reading tmp4 back off the particle, because partProperty is a C
        -- call and this runs 400x per frame.  The 60-tick sweep reconciles
        -- the mirror against tmp4 and against particle liveness, so a stale
        -- entry (slot reuse after a death) survives at most one second.
        local idx = t.byWorker[i]
        if not idx then
            idx = nextCell(t)
            if not idx then
                if t.doneCount >= t.total then finish(t) end
                return res("idle")           -- every remaining cell is spoken for
            end
            if t.source == "store" and t.cellMode == "deliver" then
                local elem = t.ce[idx]
                if not takeStore(t.colonyId, elem, 1) then
                    -- Stall, do not fail: the store may be refilled by a
                    -- gather task running alongside this one.  nextCell has
                    -- already stepped the cursor past this cell, so rewind --
                    -- otherwise the one cell we could not fund is orphaned
                    -- behind the cursor and the blueprint never completes.
                    if idx < t.cursor then t.cursor = idx end
                    blockTask(t, "store empty for element " .. tostring(elem))
                    return res("idle")
                end
                t.reserved[i] = elem
            end
            claimCell(t, i, idx)
            activate(t)
        end

        local cx, cy = t.cx[idx], t.cy[idx]
        if t.cellMode == "dig" then
            return res("dig", cx, cy, t.ce[idx], idx)
        end
        -- Both sources emit a plain "deliver"; the difference between them is
        -- accounting, which is ours, not a different walk.
        --
        -- Two things forced this.  First, 40_worker.lua's "seek" means "walk
        -- there and pick up the first `element` you touch" -- so routing a
        -- store-sourced ant via the nest to collect its load would strand it
        -- next to a store that is a number in a table, not a particle it can
        -- touch, and the task would never advance.  Second, we must NOT set
        -- `source="store"` on the result: the worker debits the store itself
        -- when it sees that flag, and we have already debited one unit at
        -- claim time (so that a death mid-carry can refund it, and so that an
        -- empty store blocks the task instead of failing it).  Leaving the
        -- field unset makes the worker materialise the pixel, which is right
        -- -- the unit it represents is already paid for.
        return res("deliver", cx, cy, t.ce[idx], idx)

    elseif t.kind == "gather" then
        local elem = t.element
        if carried(i) == elem and elem ~= 0 then
            local nx, ny = nestFor(t)
            return res("deliver", nx, ny, elem, nil)
        end
        local sx, sy = scatter(t, i)
        return res("seek", sx, sy, elem, nil)

    elseif t.kind == "patrol" then
        local at = t.patrolAt[i]
        if not at then at = 1; t.patrolAt[i] = 1 end
        return res("patrol", t.px[at], t.py[at], nil, nil)
    end

    return res("idle")
end

--- What ant `i` of `colonyId` should do this frame for `taskId`.
--- Returns a table {mode, tx, ty, element, cellIndex}; mode is one of
--- "seek" | "deliver" | "dig" | "patrol" | "idle".
---
--- IMPORTANT: the returned table is a single shared buffer (see R above).  It
--- is valid only until the next forWorker call -- read the fields you need
--- straight away, and never hold the table across ants or across frames.
--- Never raises: a failure here would be raised inside an element Update
--- function, which TPT handles badly.
function M.forWorker(i, colonyId, taskId)
    local ok, r = pcall(forWorkerInner, i, colonyId, taskId)
    if ok then return r end
    warnOnce("forWorker(" .. tostring(i) .. "," .. tostring(colonyId) .. "," ..
             tostring(taskId) .. "): " .. tostring(r))
    return res("idle")
end

-- A completion is a claim by the worker that the pixel now looks the way the
-- blueprint asked.  Running the two modules together showed that claim is not
-- always true: 40_worker.lua reports success for a cell it could not actually
-- fill (an ant boxed in by its neighbours, a target pixel already occupied),
-- and 2 of 44 cells in a box outline came back "done" while still empty.
-- Trusting it would make `done` mean "an ant said so" instead of "it is
-- built", so we look at the pixel.
--
-- A cell that fails verification goes back into the pool and someone tries
-- again.  That must not become an infinite loop when the request is
-- physically impossible (building with something that flows away, digging a
-- pixel that keeps refilling), so after MAX_CELL_RETRIES attempts the cell is
-- retired anyway and counted in `unverified`, which colonyTaskStatus reports.
local MAX_CELL_RETRIES = 3

--- True when the world already matches what cell `idx` asked for.
local function cellSatisfied(t, idx)
    local x, y = t.cx[idx], t.cy[idx]
    local p    = sim.pmap(x, y)
    if t.cellMode == "dig" then
        if p == nil then return true end                 -- nothing left: dug
        local want = t.ce[idx]
        if want and want ~= 0 then
            return sim.partProperty(p, "type") ~= want   -- the filtered element is gone
        end
        return false
    end
    if p == nil then return false end
    return sim.partProperty(p, "type") == t.ce[idx]
end

local function completeInner(i, taskId, cellIndex)
    local t = tasksById[taskId]
    if not t or not isLive(t) then
        PBX.setClaim(i, 0)
        return false
    end
    -- 40_worker.lua sends `cellIndex or 0`, using 0 for "this was not a cell".
    -- Our indices are 1-based, and 0 is truthy in Lua, so without this the
    -- fallback to byWorker[i] below would never run and a legitimate
    -- completion would be thrown away as a mismatched claim.
    if cellIndex == 0 then cellIndex = nil end

    if t.cellMode then
        local idx = cellIndex or t.byWorker[i]
        if not idx or t.claims[idx] ~= i then
            -- Somebody else owns that cell (or the sweep already took it
            -- back).  Drop whatever this ant holds and let it re-claim.
            dropWorker(t, i, true)
            return false
        end
        -- Verify before counting it (see the note above cellSatisfied).
        if not cellSatisfied(t, idx) then
            local tries = (t.retry[idx] or 0) + 1
            t.retry[idx] = tries
            if tries < MAX_CELL_RETRIES then
                -- unclaim puts the cell back to pending, rewinds the cursor
                -- and refunds any store unit reserved for it -- exactly the
                -- right outcome, because the material was never placed.
                unclaim(t, i, true)
                return false
            end
            t.unverified = (t.unverified or 0) + 1
            warnOnce("task " .. t.id .. " cell " .. idx .. " at (" .. t.cx[idx] .. "," ..
                     t.cy[idx] .. ") retired unverified after " .. tries .. " attempts")
        end

        t.byWorker[i]    = nil
        t.claims[idx]    = nil
        t.cellState[idx] = CELL_DONE
        t.claimed        = t.claimed - 1
        t.doneCount      = t.doneCount + 1
        t.progress       = t.doneCount
        t.doneList[#t.doneList + 1] = idx
        if t.reserved then t.reserved[i] = nil end   -- consumed, do not refund
        PBX.setClaim(i, 0)
        markDirty()
        if t.doneCount >= t.total then finish(t) end
        return true

    elseif t.kind == "gather" then
        -- The ant reached the nest with a load; the store book-keeping is
        -- ours because the task defines what "one unit" meant.
        addStore(t.colonyId, t.element, 1)
        t.progress = t.progress + 1
        PBX.setClaim(i, 0)
        markDirty()
        if t.progress >= t.total then finish(t) end
        return true

    elseif t.kind == "patrol" then
        local at = (t.patrolAt[i] or 1) + 1
        if at > t.npoints then at = 1 end
        t.patrolAt[i] = at
        t.progress    = t.progress + 1
        markDirty()
        if t.total > 0 and t.progress >= t.total then finish(t) end
        return true
    end

    return false
end

--- Mark one unit of work finished by ant `i`: a blueprint cell built or dug,
--- a load delivered to the nest, or a patrol point reached.  Clears the ant's
--- claim and advances progress.  Returns true when it counted.
function M.complete(i, taskId, cellIndex)
    local ok, r = pcall(completeInner, i, taskId, cellIndex)
    if ok then return r end
    warnOnce("complete: " .. tostring(r))
    return false
end

--- Give up a claim without completing it -- the ant died, could not reach the
--- cell, or is being retasked.  The cell returns to the pool (and any store
--- material reserved for it is refunded).  Returns true when something was
--- actually released.
function M.release(i, taskId)
    local ok, r = pcall(function()
        local t = tasksById[taskId]
        if not t then PBX.setClaim(i, 0); return false end
        dropWorker(t, i, true)
        return true
    end)
    if ok then return r end
    warnOnce("release: " .. tostring(r))
    return false
end

--- Highest-priority task an idle ant of this colony should join, or nil.
--- Ties break by creation order (the list is pre-sorted, so this is a scan of
--- at most 16 records with no allocation and no sort).
--- Blocked tasks are considered only as a last resort: a store-sourced build
--- that ran dry must still be re-offered, otherwise a gather task refilling
--- the store could never unblock it.
function M.assignWorker(colonyId)
    local list = byColony[colonyId]
    if not list then return nil end
    local fallback
    for k = 1, #list do
        local t = list[k]
        if isLive(t) then
            local room = (not t.workersCap) or (t.crewCount < t.workersCap)
            if room then
                if t.status == "blocked" then
                    if not fallback then fallback = t.id end
                else
                    return t.id
                end
            end
        end
    end
    return fallback
end

--- Number of live (pending/active/blocked) tasks for a colony.  Published for
--- 30_colony.lua's colonyStatus and 60_diag.lua.
function M.count(colonyId)
    return liveCount(colonyId)
end

--- Task summaries for one colony as a JSON-ready array -- the same records
--- colonyTaskStatus returns.  30_colony.lua's colonyStatus calls this for its
--- `tasks` field, so the shape is fixed by that consumer as well as by ours.
--- Returns an empty PBX.arr rather than nil when the colony has no tasks.
function M.forColony(colonyId)
    local list = byColony[colonyId]
    local out  = PBX.arr({})
    if not list then return out end
    for k = 1, #list do out[k] = taskInfo(list[k]) end
    return out
end

-- ---------------------------------------------------------------------------
-- Dispatch: putting a task id on an idle ant
--
-- `tmp` is the tasks column (spec section 3), and 40_worker.lua treats it as
-- read-only input: an ant whose tmp is 0 simply wanders, and the worker never
-- calls assignWorker.  So if this module does not write tmp, nothing does --
-- a colony with a full task board stands around doing nothing, which is
-- exactly what happened the first time these two modules were run together.
--
-- Runs on its own 30-tick hook rather than per frame because the only way to
-- enumerate a colony's ants is PBX.state.worker.list, which is O(live
-- particles).  Half a second of latency before an idle ant picks up new work
-- is invisible next to the time it takes one to walk anywhere.
-- ---------------------------------------------------------------------------

local function dispatchColony(colonyId, list, w)
    local anyLive = false
    for k = 1, #list do
        if isLive(list[k]) then anyLive = true break end
    end
    if not anyLive then return end

    local ants = w.list(colonyId, MAX_CREW)
    if type(ants) ~= "table" then return end

    for k = 1, #ants do
        local i   = ants[k]
        local cur = sim.partProperty(i, "tmp") or 0
        local t   = (cur ~= 0) and tasksById[cur] or nil

        -- Retask when the ant has no task, when its task is finished,
        -- cancelled or another colony's, or when it is parked on a task whose
        -- worker cap is already met by other ants.
        local needs = (not t) or (not isLive(t)) or (t.colonyId ~= colonyId)
                      or (not t.crew[i] and t.workersCap and t.crewCount >= t.workersCap)

        if needs then
            if t then dropWorker(t, i, true) end
            local newId = M.assignWorker(colonyId)
            local nt    = newId and tasksById[newId] or nil
            if nt and joinCrew(nt, i) then
                sim.partProperty(i, "tmp", newId)
                activate(nt)
            else
                sim.partProperty(i, "tmp", 0)
                PBX.setClaim(i, 0)
            end
        end
    end
end

PBX.onTick("tasks-dispatch", function()
    local w = PBX.state.worker
    if type(w) ~= "table" or type(w.list) ~= "function" then return end
    for colonyId, list in pairs(byColony) do
        PBX.guard(MOD, dispatchColony, colonyId, list, w)
    end
end, 30)

-- ---------------------------------------------------------------------------
-- Stale claim sweep
--
-- Core, not housekeeping.  An ant that dies mid-haul leaves its cell marked
-- CLAIMED with an owner that no longer exists; nothing else ever puts that
-- cell back, so a blueprint permanently stalls short of completion and the
-- colony looks alive while building nothing.  Every 60 ticks we walk the crew
-- of each live task -- bounded by the number of ants, never by the 4096-cell
-- blueprint -- and drop anyone who is dead, no longer ours, or whose tmp4
-- token disagrees with our mirror.
-- ---------------------------------------------------------------------------

--- Is particle `i` still a live worker of `colonyId` holding claim `idx`?
local function claimStillValid(i, colonyId, idx)
    local ok, ty = pcall(sim.partProperty, i, "type")
    if not ok or not ty or ty == 0 then return false end        -- slot is empty

    local w = PBX.state.worker
    if type(w) == "table" then
        -- Optional: if the worker module tells us which element ids are ants,
        -- a recycled particle slot is caught immediately instead of only when
        -- its colony nibble happens to differ.
        if type(w.isWorkerType) == "function" then
            local okk, r = pcall(w.isWorkerType, ty)
            if okk and r == false then return false end
        elseif type(w.elementId) == "number" and w.elementId ~= 0 then
            if ty ~= w.elementId then return false end
        end
    end

    local okc, cid = pcall(PBX.getColony, i)
    if not okc or cid ~= colonyId then return false end

    if idx and PBX.hasTmp34 then
        -- We wrote this token ourselves in claimCell; a mismatch means the
        -- ant was retasked or the slot was reused.  Only meaningful when the
        -- field exists -- getClaim returns 0 for everyone otherwise.
        local okt, tok = pcall(PBX.getClaim, i)
        if not okt or tok ~= idx + 1 then return false end
    end

    -- `tmp` is the task id.  Zero means "the worker never wrote it", which we
    -- must not read as evidence of anything; a different non-zero value is
    -- definitive proof the ant moved on.
    return true
end

local function sweepTask(t)
    for i in pairs(t.crew) do
        local idx = t.byWorker[i]
        if not claimStillValid(i, t.colonyId, idx) then
            -- Refund store material: the ant died carrying it.
            dropWorker(t, i, true)
            markDirty()
        end
    end
    -- A blocked task whose crew has drained can be retried from scratch.
    if t.status == "blocked" and t.crewCount == 0 and t.pending and t.pending > 0 then
        t.status = "pending"
        markDirty()
    end
    if t.cellMode and t.doneCount >= t.total and isLive(t) then finish(t) end
end

PBX.onTick("tasks", function()
    -- PBX.onTick already pcalls us, but a failure there disables the hook
    -- after 20 strikes and the sweep is the thing keeping blueprints alive.
    -- Guarding per task means one sick task cannot take the sweep down.
    for _, t in pairs(tasksById) do
        if isLive(t) then
            PBX.guard(MOD, sweepTask, t)

            -- Retry element resolution for tasks restored before
            -- 10_registry.lua finished recreating its custom elements.
            if t.unresolved then
                local ok, err = resolveElements(t.rawSpec, t.kind)
                if ok then
                    t.unresolved = nil
                    t.status, t.reason = "pending", nil
                    -- Element ids are not stable across restarts, so the
                    -- compiled cells have to be re-stamped from the freshly
                    -- resolved spec.  buildBlueprint keeps a per-cell element,
                    -- everything else has one element for the whole shape.
                    if t.cellMode and t.kind ~= "buildBlueprint" and t.rawSpec.element then
                        for k = 1, t.total do t.ce[k] = t.rawSpec.element end
                    elseif t.cellMode and t.rawSpec.cells then
                        -- Cells were de-duplicated at compile time, so match
                        -- on coordinates rather than on index.
                        local byXY = {}
                        for k = 1, #t.rawSpec.cells do
                            local c = t.rawSpec.cells[k]
                            byXY[c.y * W + c.x] = c.element
                        end
                        for k = 1, t.total do
                            local v = byXY[t.cy[k] * W + t.cx[k]]
                            if v then t.ce[k] = v end
                        end
                    end
                    markDirty()
                else
                    t.reason = err
                end
            end

            -- Nest may have moved (or only just become knowable).
            t.nestX, t.nestY = nil, nil
        end
    end
    if dirty then flush() end
end, 60)

-- ---------------------------------------------------------------------------
-- Restore
--
-- Split in two on purpose.
--
-- The *file* is read here, at load time.  The compile step is deferred,
-- because 10_registry.lua recreates its custom elements through PBX.defer and
-- the job queue is FIFO, so running after it is the only way element names
-- resolve to the ids they will actually have.
--
-- Reading the file later, inside the deferred job, was a real bug: the HTTP
-- server accepts requests before the first tick, so a colonyAssignTask can
-- land first, flush() rewrites pbx-tasks.json, and the restore then reads its
-- own freshly written file back and re-registers the live task as a duplicate
-- -- resetting its progress.  Snapshotting at load time also lets us claim
-- the saved id range immediately, so a task created in that window cannot be
-- handed an id that the file is about to restore.
-- ---------------------------------------------------------------------------

local savedData = PBX.load("tasks")
if type(savedData) == "table" then
    if type(savedData.nextId) == "number" and savedData.nextId > nextTaskId then
        nextTaskId = savedData.nextId
    end
    if type(savedData.tasks) == "table" then
        for k = 1, #savedData.tasks do
            local s = savedData.tasks[k]
            if type(s) == "table" and type(s.id) == "number" and s.id >= nextTaskId then
                nextTaskId = s.id + 1
            end
        end
    end
end

PBX.defer(function()
    local data = savedData
    savedData = nil
    if type(data) ~= "table" or type(data.tasks) ~= "table" then return { restored = 0 } end

    local restored, failed, skipped = 0, 0, 0
    for k = 1, #data.tasks do
        local s = data.tasks[k]
        if type(s) == "table" and s.id and tasksById[s.id] then
            -- Assigned in the window between load and this job; the live copy
            -- is newer than anything on disk.
            skipped = skipped + 1
        elseif type(s) == "table" and type(s.spec) == "table" and s.kind and s.colonyId then
            local unresolved
            local okRes, resErr = resolveElements(s.spec, s.kind)
            if not okRes then unresolved = resErr end

            local t, err = makeTask(
                s.id or nextTaskId, s.colonyId, s.kind, s.spec,
                s.priority or 5, s.workersCap, s.source or "spawn",
                type(s.done) == "table" and s.done or nil)

            if t then
                createSeq   = createSeq + 1
                t.createdAt = s.createdAt or createSeq
                if s.status == "cancelled" or s.status == "done" then
                    t.status = s.status
                elseif unresolved then
                    t.status, t.reason, t.unresolved = "blocked", unresolved, true
                end
                if t.kind == "gather" or t.kind == "patrol" then
                    t.progress = s.progress or 0
                end
                -- Claims are intentionally not restored: every particle that
                -- held one died with the previous process.
                tasksById[t.id] = t
                byColony[t.colonyId] = byColony[t.colonyId] or {}
                local list = byColony[t.colonyId]
                list[#list + 1] = t
                if t.id >= nextTaskId then nextTaskId = t.id + 1 end
                restored = restored + 1
            else
                failed = failed + 1
                PBX.warn(MOD, "restore of task " .. tostring(s.id) .. " failed: " .. tostring(err))
            end
        end
    end

    for cid in pairs(byColony) do resort(cid) end
    PBX.log(MOD, "restored " .. restored .. " task(s), " .. failed .. " failed, " ..
                 skipped .. " already live")
    if restored > 0 then saveNow() end
    return { restored = restored, failed = failed, skipped = skipped }
end)

PBX.log(MOD, "tasks " .. M.VERSION .. " loaded")

end  -- module scope (see the 200-local note at the top)
