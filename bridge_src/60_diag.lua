-- ===========================================================================
-- 60_diag.lua -- extension diagnostics (extStatus, extSelfTest)
--
-- Why this module exists: every other bridge module can fail to load, fail to
-- register, or silently stop ticking, and the only symptom visible from the
-- MCP side is "some action doesn't work". This module's entire job is to make
-- that visible, so it must be the one module that can never itself be the
-- thing that's broken. Every lookup below tolerates the module it reads being
-- absent, half-initialised, or throwing -- PBX.guard/pcall wraps every
-- section so a crash in the thing being inspected never becomes a crash in
-- the inspector.
--
-- extStatus is a pure read: it never calls PBX.defer and never mutates
-- PBX.state.diag beyond what's needed to answer. extSelfTest runs cheap
-- synchronous checks plus (with deep=true) one deferred check, and restores
-- anything it touches -- see the particle_roundtrip job below.
-- ===========================================================================

PBX.state.diag.VERSION = "1.0.0"

-- ---------------------------------------------------------------------------
-- Small shared helpers
-- ---------------------------------------------------------------------------

--- Count entries in any table via pairs(), not #. `#` only gives a sane
--- answer for a dense array; several of the "is this collection populated"
--- questions below read maps keyed by id or name, so pairs()-counting is the
--- only version that is correct for every shape a module might choose.
local function mapCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- Last of N return values -- every PBX.v* validator's contract is "value(s)
--- then an error message last, or nil last on success", regardless of how
--- many leading values it returns (vElem returns 1, vPixel/vCell return 2).
local function lastReturn(...)
    local n = select('#', ...)
    return select(n, ...)
end

-- ---------------------------------------------------------------------------
-- extStatus -- read-only inventory of what actually loaded
-- ---------------------------------------------------------------------------

--- One row per key in PBX.state (the fixed set of module slots from
--- 00_util.lua), not per bridge_src filename -- we can only discover modules
--- through the namespace contract, and that contract is one state key per
--- module. A module whose file never loaded still has its {} initial table
--- from 00_util, just with no VERSION written into it; that is exactly the
--- "loaded=false" signal the spec asks for.
local function buildModuleReport()
    local actionsByOwner = {}
    for action, owner in pairs(PBX.actionOwners) do
        actionsByOwner[owner] = actionsByOwner[owner] or {}
        actionsByOwner[owner][#actionsByOwner[owner] + 1] = action
    end

    local names = {}
    for key in pairs(PBX.state) do names[#names + 1] = key end
    table.sort(names)

    local out = {}
    for i = 1, #names do
        local name = names[i]
        local st = PBX.state[name]
        local version = (type(st) == "table") and st.VERSION or nil
        local acts = actionsByOwner[name] or {}
        table.sort(acts)
        local row = {
            name = name,
            loaded = version ~= nil,
            actions = PBX.arr(acts),
            errors = PBX.errorCount(name),
        }
        if version ~= nil then
            row.version = version
        else
            row.note = "state table has no VERSION; file failed to load or was left out of the build"
        end
        out[#out + 1] = row
    end
    return PBX.arr(out)
end

--- Try a short list of plausible field shapes on a module's state table and
--- return the first count that resolves. The spec fixes only VERSION on
--- another module's state -- the rest of that module's internal layout is
--- its author's choice, so this degrades to a note instead of guessing wrong
--- and reporting a confident, made-up number.
local function firstCount(state, numericKeys, tableKeys)
    if type(state) ~= "table" then return nil, "state table absent" end
    for i = 1, #numericKeys do
        local v = state[numericKeys[i]]
        if type(v) == "number" then return v, nil end
    end
    for i = 1, #tableKeys do
        local v = state[tableKeys[i]]
        if type(v) == "table" then return mapCount(v), nil end
    end
    return nil, "no recognised count field on this module's state"
end

local function customElementCount()
    return firstCount(PBX.state.registry, { "count" }, { "list", "byName", "elements" })
end

local function colonyCount()
    return firstCount(PBX.state.colony, { "count" }, { "list", "byId", "colonies" })
end

--- Worker count needs its own logic rather than firstCount: the spec says
--- "sum across colonies", which implies a per-colony breakdown (map of
--- colonyId -> list or count) rather than one flat collection.
local function workerCount()
    local st = PBX.state.worker
    if type(st) ~= "table" then return nil, "state table absent" end
    if type(st.count) == "number" then return st.count, nil end
    if type(st.list) == "table" then return mapCount(st.list), nil end
    if type(st.byColony) == "table" then
        local total = 0
        for _, v in pairs(st.byColony) do
            if type(v) == "number" then total = total + v
            elseif type(v) == "table" then total = total + mapCount(v)
            end
        end
        return total, nil
    end
    return nil, "no recognised count field on this module's state"
end

--- Section 4.2 documents PBX.state.behaviors.kinds explicitly but the diag
--- contract in section 4.6 asks for a `.list()` call; try that first and
--- fall back to deriving names from `.kinds` so status still reports
--- something useful if `.list()` never gets added.
local function behaviorKindsList()
    local st = PBX.state.behaviors
    if type(st) ~= "table" then return nil, "state table absent" end
    if type(st.list) == "function" then
        local ok, result = pcall(st.list)
        if ok and type(result) == "table" then return result, nil end
        return nil, "behaviors.list() present but failed or returned a non-table"
    end
    if type(st.kinds) == "table" then
        local names = {}
        for k in pairs(st.kinds) do names[#names + 1] = k end
        table.sort(names)
        return names, nil
    end
    return nil, "no list() function or kinds map on this module's state"
end

PBX.register("extStatus", function(req)
    local result = {}

    -- modules: never null'd as a whole -- each row carries its own
    -- loaded/note so one missing module can't hide the rest of the report.
    local mok = PBX.guard("diag", function() result.modules = buildModuleReport() end)
    if not mok then result.modules = PBX.arr({}) end

    -- Always available straight off PBX itself; nothing to tolerate here.
    result.tickIndex = PBX.tickIndex
    result.hasTmp34 = PBX.hasTmp34
    result.pbxVersion = PBX.VERSION

    -- jobQueue: 00_util.lua keeps its pending-job list as a Lua `local`
    -- (jobQueue/jobs in the defer section) with no accessor exposed on PBX.
    -- That is a deliberate encapsulation we must not reach around by editing
    -- 00_util.lua, so this is genuinely not introspectable rather than
    -- merely "absent" -- report the gap honestly instead of faking a number.
    -- (0/0 is how PBX.encode itself renders "no value" for a numeric field:
    -- nan/inf both serialise to JSON null, see PBX.jnum in 00_util.lua.)
    result.jobQueue = 0 / 0
    result.jobQueueNote = "PBX does not expose its pending-job queue length (private local in 00_util.lua)"

    PBX.guard("diag", function()
        local n, note = customElementCount()
        if n then result.customElementCount = n
        else result.customElementCount = 0 / 0; result.customElementCountNote = note end
    end)

    PBX.guard("diag", function()
        local n, note = colonyCount()
        if n then result.colonyCount = n
        else result.colonyCount = 0 / 0; result.colonyCountNote = note end
    end)

    PBX.guard("diag", function()
        local n, note = workerCount()
        if n then result.workerCount = n
        else result.workerCount = 0 / 0; result.workerCountNote = note end
    end)

    PBX.guard("diag", function()
        local kinds, note = behaviorKindsList()
        if kinds then result.behaviorKinds = PBX.arr(kinds)
        else result.behaviorKinds = PBX.arr({}); result.behaviorKindsNote = note end
    end)

    return PBX.ok("extStatus", result)
end, "diag")

-- ---------------------------------------------------------------------------
-- extSelfTest -- active checks, still read-mostly
-- ---------------------------------------------------------------------------

local function checkPbxLoaded()
    if type(_G.PBX) ~= "table" then return false, "PBX missing from _G" end
    local v = PBX.VERSION
    if type(v) ~= "string" or not v:match("^%d+%.%d+%.%d+$") then
        return false, "PBX.VERSION missing or malformed: " .. tostring(v)
    end
    return true, "PBX " .. v .. " loaded"
end

--- Exercises the encoder on everything the spec calls out: nested tables,
--- an empty array (which the encoder would render {} for without PBX.arr),
--- strings needing escapes, and non-finite numbers -- then parses the result
--- back with json.parse to prove it is actually valid JSON, not just
--- plausible-looking text.
local function checkJsonRoundtrip()
    local sample = {
        str = "quote\"back\\slash\ttab\nline",
        nested = { deep = { value = 42, arr = PBX.arr({ 1, 2, 3 }) } },
        emptyArr = PBX.arr({}),
        nanField = 0 / 0,
        infField = 1 / 0,
    }
    local encoded = PBX.encode(sample)
    local pok, parsed = pcall(json.parse, encoded)
    if not pok then return false, "json.parse rejected encoded output: " .. tostring(parsed) end
    if type(parsed) ~= "table" then return false, "parsed result is not a table" end
    if parsed.str ~= sample.str then return false, "string escaping round-trip mismatch" end
    if type(parsed.nested) ~= "table" or type(parsed.nested.deep) ~= "table"
        or parsed.nested.deep.value ~= 42 then
        return false, "nested table round-trip mismatch"
    end
    if type(parsed.nested.deep.arr) ~= "table" or mapCount(parsed.nested.deep.arr) ~= 3 then
        return false, "array round-trip mismatch"
    end
    if type(parsed.emptyArr) ~= "table" or mapCount(parsed.emptyArr) ~= 0 then
        return false, "empty array round-trip mismatch (PBX.arr marker not honoured)"
    end
    -- nan/inf encode as JSON null (PBX.jnum); a conforming parser hands those
    -- back as an absent/nil field, never as a number.
    if parsed.nanField ~= nil or parsed.infField ~= nil then
        return false, "non-finite numbers did not encode as null"
    end
    return true, "encode/parse round-trip verified (strings, nesting, empty array, non-finite numbers)"
end

--- One good value and one bad value per PBX.v* validator. vPixel/vCell/vElem
--- have different arities than the plain v*(value, name, ...) shape, so each
--- case supplies its own argument lists rather than assuming a common one.
local VALIDATOR_CASES = {
    { name = "vInt", good = { 5, "n", 1, 10 }, bad = { 20, "n", 1, 10 } },
    { name = "vNum", good = { 5.5, "n", 0, 10 }, bad = { 1 / 0, "n", 0, 10 } },
    { name = "vStr", good = { "hi", "n", 10 }, bad = { 42, "n", 10 } },
    { name = "vBool", good = { true, "n", false }, bad = { "nope", "n", false } },
    { name = "vEnum", good = { "a", "n", { "a", "b" } }, bad = { "z", "n", { "a", "b" } } },
    { name = "vPixel", good = { 0, 0 }, bad = { -1, -1 } },
    { name = "vCell", good = { 0, 0 }, bad = { 99999, 99999 } },
    { name = "vElem", good = { "DUST" }, bad = { "NOT_A_REAL_ELEMENT_XYZ" } },
    { name = "vList", good = { { 1, 2 }, "n", 5 }, bad = { "nope", "n", 5 } },
}

local function checkValidators()
    local failures = {}
    for i = 1, #VALIDATOR_CASES do
        local c = VALIDATOR_CASES[i]
        local fn = PBX[c.name]
        if type(fn) ~= "function" then
            failures[#failures + 1] = c.name .. ":missing"
        else
            local goodErr = lastReturn(fn(unpack(c.good)))
            local badErr = lastReturn(fn(unpack(c.bad)))
            if goodErr ~= nil then
                failures[#failures + 1] = c.name .. ":good value rejected(" .. tostring(goodErr) .. ")"
            end
            if badErr == nil then
                failures[#failures + 1] = c.name .. ":bad value accepted"
            end
        end
    end
    if #failures == 0 then
        return true, "all " .. #VALIDATOR_CASES .. " validators accept good input and reject bad input"
    end
    return false, table.concat(failures, "; ")
end

--- Jobs only run on event.TICK and this action must answer synchronously, so
--- there is no way to see this call's own job settle before it returns. The
--- honest thing (per spec) is to report on the PREVIOUS call's job -- whose
--- id we kept in PBX.state.diag -- and queue a fresh one for next time.
local function checkDeferQueue()
    local diagState = PBX.state.diag
    local prevId = diagState.deferJobId
    local ok, detail

    if prevId == nil then
        ok, detail = false, "no prior job to check yet (first call only seeds one)"
    else
        local prevResult = PBX.jobResult(prevId)
        if prevResult == nil then
            ok, detail = false, "job " .. prevId .. " still pending (tick pump may be slow or dead)"
        elseif prevResult.ok then
            ok, detail = true, "job " .. prevId .. " settled successfully"
        else
            ok, detail = false, "job " .. prevId .. " failed: " .. tostring(prevResult.error)
        end
    end

    local newId = PBX.defer(function() return { ping = "pong", queuedAtTick = PBX.tickIndex } end)
    diagState.deferJobId = newId
    return ok, detail .. "; queued job " .. newId .. " for the next call"
end

--- PBX.tickIndex only advances via event.TICK. Comparing it against the
--- value we saw last call is exactly what catches a dead tick pump -- if the
--- game were stalled or event.TICK never registered (see 00_util.lua's
--- "WARNING: event.TICK unavailable" branch), this index would be frozen.
local function checkTickRunning()
    local diagState = PBX.state.diag
    local prev = diagState.lastTickIndex
    local current = PBX.tickIndex
    diagState.lastTickIndex = current
    if prev == nil then
        return true, "baseline recorded at tick " .. current .. "; call again to verify advancement"
    end
    if current > prev then
        return true, "tick advanced " .. prev .. " -> " .. current
    end
    return false, "tick index unchanged since last call (" .. current .. "); tick pump may be dead"
end

--- Every registered action must appear in both PBX.actionOwners (the
--- bookkeeping map) and _G.PB_EXT (what the HTTP dispatcher actually calls).
--- PBX.register keeps these in lockstep by construction, so a mismatch here
--- would mean something outside PBX.register poked one table directly.
local function checkActionTable()
    local missing, extra = {}, {}
    for action in pairs(PBX.actionOwners) do
        if _G.PB_EXT[action] == nil then missing[#missing + 1] = action end
    end
    for action in pairs(_G.PB_EXT) do
        if PBX.actionOwners[action] == nil then extra[#extra + 1] = action end
    end
    if #missing == 0 and #extra == 0 then
        return true, mapCount(PBX.actionOwners) .. " actions registered and consistent"
    end
    table.sort(missing)
    table.sort(extra)
    return false, "missing_in_PB_EXT=[" .. table.concat(missing, ",") ..
        "] extra_in_PB_EXT=[" .. table.concat(extra, ",") .. "]"
end

--- Proves the bridge is actually attached to a live simulation, not just that
--- the Lua VM is up. sim.partCount is the primary check; sim.pmap is a
--- fallback for a build where partCount is missing but the sim table itself
--- still responds.
local function checkSimReadable()
    if type(sim) ~= "table" then return false, "sim table missing entirely" end
    if type(sim.partCount) == "function" then
        local ok, n = pcall(sim.partCount)
        if ok and type(n) == "number" and n >= 0 then
            return true, "sim.partCount() = " .. n
        end
        return false, "sim.partCount present but call failed or returned an invalid value"
    end
    if type(sim.pmap) == "function" then
        local ok = pcall(sim.pmap, 0, 0)
        if ok then return true, "sim.partCount unavailable; sim.pmap(0,0) readable as fallback" end
    end
    return false, "no readable sim accessor found"
end

-- Bounded so a self-test can never itself stall a tick: at most this many
-- pixels are probed looking for a free cell before giving up honestly.
local ROUNDTRIP_SCAN_LIMIT = 4000

--- Row-major scan for the first empty pixel, capped at `limit` probes.
--- Returns nil, nil, scanned when nothing free turned up within the cap.
local function findFreeCell(limit)
    local scanned = 0
    for y = 0, PBX.SIM_H - 1 do
        for x = 0, PBX.SIM_W - 1 do
            scanned = scanned + 1
            if PBX.cellFree(x, y) then return x, y, scanned end
            if scanned >= limit then return nil, nil, scanned end
        end
    end
    return nil, nil, scanned
end

--- Runs on the simulation thread via PBX.defer (element mutation is not
--- allowed from the HTTP handler thread, see 00_util.lua section on the
--- deferred queue). Creates one particle, reads its type back, then kills it
--- and confirms the cell is empty again -- this must never leave a stray
--- particle behind, which is why the kill happens unconditionally once
--- create succeeded, even if the type read failed.
local function runParticleRoundtripJob()
    local elemId, elemErr = PBX.vElem("DUST")
    if not elemId then
        return { skipped = true, reason = "DUST unavailable: " .. tostring(elemErr) }
    end

    local x, y, scanned = findFreeCell(ROUNDTRIP_SCAN_LIMIT)
    if not x then
        return { skipped = true, reason = "no free cell found in a bounded scan of " .. scanned .. " pixels" }
    end

    local id = sim.partCreate(-1, x, y, elemId)
    if not id or id < 0 then
        return { skipped = true, reason = "sim.partCreate failed at (" .. x .. "," .. y .. ")" }
    end

    local readOk, readType = pcall(sim.partProperty, id, "type")
    sim.partKill(id) -- always clean up, even if the read above failed
    local emptyAfterKill = PBX.cellFree(x, y)

    return {
        x = x, y = y,
        typeMatched = readOk and readType == elemId,
        emptyAfterKill = emptyAfterKill,
    }
end

--- Same "check the previous call's job" shape as checkDeferQueue, since this
--- action also cannot block for its own job to settle. Reported ok=false
--- (pending) whenever there is nothing settled yet to point to, per spec.
local function checkParticleRoundtrip()
    local diagState = PBX.state.diag
    local prevId = diagState.particleJobId
    local ok, detail

    if prevId == nil then
        ok, detail = false, "no prior job to check yet (first call only seeds one)"
    else
        local prevResult = PBX.jobResult(prevId)
        if prevResult == nil then
            ok, detail = false, "job " .. prevId .. " still pending"
        elseif not prevResult.ok then
            ok, detail = false, "job " .. prevId .. " failed: " .. tostring(prevResult.error)
        else
            local v = prevResult.value or {}
            if v.skipped then
                ok, detail = true, "skipped: " .. tostring(v.reason)
            else
                ok = v.typeMatched and v.emptyAfterKill
                detail = "at (" .. tostring(v.x) .. "," .. tostring(v.y) ..
                    ") typeMatched=" .. tostring(v.typeMatched) ..
                    " emptyAfterKill=" .. tostring(v.emptyAfterKill)
            end
        end
    end

    local newId = PBX.defer(runParticleRoundtripJob)
    diagState.particleJobId = newId
    return ok, detail .. "; queued job " .. newId .. " for the next deep call"
end

--- Runs one check under pcall so a single broken check reports itself as a
--- failed check rather than aborting the whole extSelfTest response -- the
--- same never-fail-the-inspector principle as extStatus above.
local function runCheck(name, fn)
    local success, a, b = pcall(fn)
    if not success then
        return { name = name, ok = false, detail = "check raised: " .. tostring(a) }
    end
    return { name = name, ok = a and true or false, detail = b }
end

PBX.register("extSelfTest", function(req)
    local deep, derr = PBX.vBool(req.deep, "deep", false)
    if derr then return PBX.err(derr) end

    local checks = PBX.arr({})
    checks[#checks + 1] = runCheck("pbx_loaded", checkPbxLoaded)
    checks[#checks + 1] = runCheck("json_roundtrip", checkJsonRoundtrip)
    checks[#checks + 1] = runCheck("validators", checkValidators)
    checks[#checks + 1] = runCheck("defer_queue", checkDeferQueue)
    checks[#checks + 1] = runCheck("tick_running", checkTickRunning)
    checks[#checks + 1] = runCheck("action_table", checkActionTable)
    checks[#checks + 1] = runCheck("sim_readable", checkSimReadable)
    if deep then
        checks[#checks + 1] = runCheck("particle_roundtrip", checkParticleRoundtrip)
    end

    -- Keep PBX.state.diag small: a compact pass/fail summary, not the full
    -- checks array (the per-check state that must persist -- job ids, last
    -- tick index -- is already written by the individual check functions
    -- above; this is just an at-a-glance summary for the next call).
    local passed = 0
    for i = 1, #checks do if checks[i].ok then passed = passed + 1 end end
    PBX.state.diag.lastSelfTest = { atTick = PBX.tickIndex, passed = passed, total = #checks }

    return PBX.ok("extSelfTest", { deep = deep, checks = checks })
end, "diag")

PBX.log("diag", "60_diag loaded, actions=extStatus,extSelfTest")
