-- ===========================================================================
-- 00_util.lua -- Powder Bridge Extension foundation (PBX)
--
-- Provides the shared namespace every extension module codes against: a safe
-- JSON encoder, argument validators with hard caps, a deferred-work queue that
-- moves element mutation off the socket thread, tick hooks, error accounting
-- and small-file persistence.
--
-- Why the deferred queue exists: the HTTP handler runs inside
-- LuaSocket::Process.  TPT asserts on mutable-tools events there
-- (LuaElements.cpp AssertMutableToolsEvent) and sim.step deadlocks on
-- g_pendingMx.  Anything that allocates an element, installs an Update
-- function or touches many particles MUST be queued and run from event.TICK.
-- Blocking the handler until the job finishes would deadlock for the same
-- reason, so jobs are asynchronous and the caller polls `jobStatus`.
-- ===========================================================================

local PBX = {}
_G.PBX = PBX
_G.PB_EXT = _G.PB_EXT or {}

PBX.VERSION = "1.0.0"

-- Hard caps.  These are the contract; no module may exceed them.
PBX.MAX_WORKERS_PER_COLONY = 400
PBX.MAX_COLONIES           = 8
PBX.MAX_TASKS_PER_COLONY   = 16
PBX.MAX_BLUEPRINT_CELLS    = 4096
PBX.MAX_CUSTOM_ELEMENTS    = 40  -- raised 2026-08-26: TPT has 256 ids, ~213 stock; 40 leaves margin

PBX.SIM_W, PBX.SIM_H   = 612, 384
PBX.CELL_W, PBX.CELL_H = 153, 96

-- One key per module.  Reading another module's state is fine, writing is not.
PBX.state = {
    registry  = {},
    behaviors = {},
    colony    = {},
    worker    = {},
    tasks     = {},
    diag      = {},
}

-- ---------------------------------------------------------------------------
-- Logging and error accounting
-- ---------------------------------------------------------------------------

local errorCounts = {}

local function writeLog(line)
    local f = io.open("autorun-runtime.log", "a")
    if f then f:write(line .. "\n"); f:close() end
end

--- Append an informational line attributed to a module.
function PBX.log(module, msg)
    writeLog("[" .. tostring(module) .. "] " .. tostring(msg))
end

--- Append a warning and count it against the module's error budget.
function PBX.warn(module, msg)
    errorCounts[module] = (errorCounts[module] or 0) + 1
    writeLog("[" .. tostring(module) .. "][WARN] " .. tostring(msg))
end

--- Number of caught errors attributed to a module.
function PBX.errorCount(module)
    return errorCounts[module] or 0
end

--- Run fn under pcall, attributing any failure to `module`.  Returns
--- ok, result.  Never re-raises: an error escaping an Update function or a
--- tick hook makes TPT spam and can stall the simulation thread.
function PBX.guard(module, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then PBX.warn(module, res) end
    return ok, res
end

-- ---------------------------------------------------------------------------
-- JSON emission
--
-- json.stringify in TPT crashes on nested tables (it uses a relative stack
-- index), so everything is serialised by hand here.
-- ---------------------------------------------------------------------------

local ARRAY_MT = { __pbx_array = true }
PBX._ARRAY_MT = ARRAY_MT

--- Mark a table as a JSON array so an empty one encodes as [] and not {}.
function PBX.arr(t)
    return setmetatable(t or {}, ARRAY_MT)
end

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escapeString(s)
    s = tostring(s)
    s = s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. s .. '"'
end
PBX.jesc = escapeString

local function encodeNumber(n)
    -- nan ~= nan; inf fails the finite comparison.  Both are invalid JSON.
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    return string.format("%.6g", n)
end
PBX.jnum = encodeNumber

local encodeValue

local function isArray(t)
    if getmetatable(t) == ARRAY_MT then return true end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

encodeValue = function(v, depth)
    depth = depth or 0
    if depth > 8 then return '"<depth>"' end
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return encodeNumber(v) end
    if t == "string" then return escapeString(v) end
    if t ~= "table" then return escapeString(tostring(v)) end

    if isArray(v) then
        local parts = {}
        for i = 1, #v do parts[#parts + 1] = encodeValue(v[i], depth + 1) end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for k in pairs(v) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do
        parts[#parts + 1] = escapeString(keys[i]) .. ":" .. encodeValue(v[keys[i]], depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- Encode any Lua value as a JSON string, depth-capped at 8.
function PBX.encode(v)
    return encodeValue(v, 0)
end

local function inlineFields(tbl)
    if not tbl then return "" end
    local keys = {}
    for k in pairs(tbl) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local out = {}
    for i = 1, #keys do
        out[#out + 1] = "," .. escapeString(keys[i]) .. ":" .. encodeValue(tbl[keys[i]], 1)
    end
    return table.concat(out)
end

--- Success envelope: {"ok":true,"action":"...", <fields>}
function PBX.ok(action, tbl)
    return '{"ok":true,"action":' .. escapeString(action) .. inlineFields(tbl) .. "}"
end

--- Failure envelope: {"ok":false,"error":"...", <fields>}
function PBX.err(msg, tbl)
    return '{"ok":false,"error":' .. escapeString(msg) .. inlineFields(tbl) .. "}"
end

-- ---------------------------------------------------------------------------
-- Validators.  Each returns value, nil on success or nil, message on failure.
-- ---------------------------------------------------------------------------

function PBX.vInt(v, name, min, max)
    local n = tonumber(v)
    if n == nil then return nil, name .. " must be a number" end
    if n ~= n or n == math.huge or n == -math.huge then return nil, name .. " must be finite" end
    n = math.floor(n)
    if min and n < min then return nil, name .. " must be >= " .. min end
    if max and n > max then return nil, name .. " must be <= " .. max end
    return n, nil
end

function PBX.vNum(v, name, min, max)
    local n = tonumber(v)
    if n == nil then return nil, name .. " must be a number" end
    if n ~= n or n == math.huge or n == -math.huge then return nil, name .. " must be finite" end
    if min and n < min then return nil, name .. " must be >= " .. min end
    if max and n > max then return nil, name .. " must be <= " .. max end
    return n, nil
end

function PBX.vStr(v, name, maxLen, pattern)
    if type(v) ~= "string" then return nil, name .. " must be a string" end
    if maxLen and #v > maxLen then return nil, name .. " must be <= " .. maxLen .. " characters" end
    if pattern and not v:match(pattern) then return nil, name .. " has an invalid format" end
    return v, nil
end

function PBX.vBool(v, name, default)
    if v == nil then return default and true or false, nil end
    if type(v) ~= "boolean" then return nil, name .. " must be a boolean" end
    return v, nil
end

function PBX.vEnum(v, name, allowed)
    if type(v) ~= "string" then return nil, name .. " must be a string" end
    for i = 1, #allowed do
        if allowed[i] == v then return v, nil end
    end
    return nil, name .. " must be one of " .. table.concat(allowed, ", ")
end

function PBX.vPixel(x, y)
    local px, e = PBX.vInt(x, "x", 0, PBX.SIM_W - 1); if e then return nil, nil, e end
    local py; py, e = PBX.vInt(y, "y", 0, PBX.SIM_H - 1); if e then return nil, nil, e end
    return px, py, nil
end

function PBX.vCell(x, y)
    local cx, e = PBX.vInt(x, "x", 0, PBX.CELL_W - 1); if e then return nil, nil, e end
    local cy; cy, e = PBX.vInt(y, "y", 0, PBX.CELL_H - 1); if e then return nil, nil, e end
    return cx, cy, nil
end

--- Resolve an element name, identifier or numeric id to a numeric id.
function PBX.vElem(v)
    if v == nil then return nil, "element is required" end
    if tonumber(v) then return math.floor(tonumber(v)), nil end
    local name = string.upper(tostring(v))
    local id = elements[name] or elements["DEFAULT_PT_" .. name] or elements["PBX_PT_" .. name]
    if id == nil then return nil, "unknown element: " .. tostring(v) end
    return id, nil
end

function PBX.vList(v, name, maxItems)
    if type(v) ~= "table" then return nil, name .. " must be an array" end
    if maxItems and #v > maxItems then return nil, name .. " must have <= " .. maxItems .. " items" end
    return v, nil
end

-- ---------------------------------------------------------------------------
-- Action registration
-- ---------------------------------------------------------------------------

PBX.actionOwners = {}

--- Register an HTTP action.  Duplicate names raise at load time on purpose:
--- two modules claiming one action is a contract violation we want loud.
function PBX.register(action, fn, module)
    if _G.PB_EXT[action] then
        error("PBX action already registered: " .. tostring(action) ..
              " (owner " .. tostring(PBX.actionOwners[action]) .. ")")
    end
    _G.PB_EXT[action] = fn
    PBX.actionOwners[action] = module or "?"
end

--- Every action name currently registered, sorted.
function PBX.actions()
    local out = {}
    for k in pairs(_G.PB_EXT) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Deferred work queue
-- ---------------------------------------------------------------------------

local jobs = {}
local jobQueue = {}
local nextJobId = 1

--- Queue fn to run on the simulation thread at the next tick.  Returns a job
--- id; poll it with PBX.jobResult or the `jobStatus` action.
function PBX.defer(fn)
    local id = nextJobId
    nextJobId = nextJobId + 1
    jobs[id] = { id = id, status = "pending" }
    jobQueue[#jobQueue + 1] = { id = id, fn = fn }
    return id
end

--- nil while pending, else { ok=bool, value=..., error=... }.
function PBX.jobResult(id)
    local j = jobs[id]
    if not j or j.status == "pending" then return nil end
    return j
end

local function pumpJobs()
    if #jobQueue == 0 then return end
    -- Drain at most 8 jobs per tick so a large batch cannot stall a frame.
    local processed = 0
    while #jobQueue > 0 and processed < 8 do
        local item = table.remove(jobQueue, 1)
        local ok, res = pcall(item.fn)
        local j = jobs[item.id]
        if ok then
            j.status = "done"; j.ok = true; j.value = res
        else
            j.status = "done"; j.ok = false; j.error = tostring(res)
            PBX.warn("job", "job " .. item.id .. " failed: " .. tostring(res))
        end
        processed = processed + 1
    end
    -- Keep the job table bounded.
    if nextJobId > 512 then
        for id in pairs(jobs) do
            if id < nextJobId - 256 then jobs[id] = nil end
        end
    end
end

PBX.register("jobStatus", function(req)
    local id, e = PBX.vInt(req.job, "job", 1)
    if e then return PBX.err(e) end
    local j = PBX.jobResult(id)
    if not j then return PBX.ok("jobStatus", { job = id, status = "pending" }) end
    return PBX.ok("jobStatus", {
        job = id, status = "done", succeeded = j.ok,
        value = j.value, detail = j.error,
    })
end, "util")

-- ---------------------------------------------------------------------------
-- Tick hooks
-- ---------------------------------------------------------------------------

PBX.tickIndex = 0
local hooks = {}

--- Register a per-tick hook.  Errors are caught and counted; a hook that
--- fails 20 times is disabled so it cannot spam the log forever.
function PBX.onTick(name, fn, everyNTicks)
    hooks[#hooks + 1] = {
        name = name, fn = fn, every = math.max(1, everyNTicks or 1),
        errors = 0, disabled = false,
    }
end

local function runHooks()
    PBX.tickIndex = PBX.tickIndex + 1
    for i = 1, #hooks do
        local h = hooks[i]
        if not h.disabled and (PBX.tickIndex % h.every) == 0 then
            local ok, err = pcall(h.fn, PBX.tickIndex)
            if not ok then
                h.errors = h.errors + 1
                PBX.warn(h.name, err)
                if h.errors >= 20 then
                    h.disabled = true
                    PBX.warn(h.name, "hook disabled after 20 errors")
                end
            end
        end
    end
end

if event and event.register and event.TICK then
    event.register(event.TICK, function()
        pumpJobs()
        runHooks()
    end)
    PBX.log("util", "tick pump registered")
else
    PBX.log("util", "WARNING: event.TICK unavailable, deferred work will not run")
end

-- ---------------------------------------------------------------------------
-- Persistence.  TPT's io is relative to the build directory, so files land
-- next to powder.exe as pbx-<name>.json.
-- ---------------------------------------------------------------------------

function PBX.save(name, tbl)
    local f = io.open("pbx-" .. name .. ".json", "w")
    if not f then return false, "cannot open pbx-" .. name .. ".json for writing" end
    f:write(PBX.encode(tbl))
    f:close()
    return true, nil
end

function PBX.load(name)
    local f = io.open("pbx-" .. name .. ".json", "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then return nil end
    local ok, parsed = pcall(json.parse, body)
    if not ok or type(parsed) ~= "table" then return nil end
    return parsed
end

-- ---------------------------------------------------------------------------
-- Creature field accessors
--
-- tmp3/tmp4 exist in current builds but we probe rather than assume; if they
-- are missing the colony id is packed into the high nibble of tmp2 so every
-- module keeps working through these accessors.
-- ---------------------------------------------------------------------------

PBX.hasTmp34 = false
do
    local ok = pcall(function()
        -- partProperty raises on an unknown property name.
        local probe = sim.partProperty
        if not probe then error("no partProperty") end
        -- Reading slot 0 is harmless whether or not a particle lives there.
        probe(0, "tmp3")
        probe(0, "tmp4")
    end)
    PBX.hasTmp34 = ok and true or false
end

--- Colony id carried by worker particle `i`.
function PBX.getColony(i)
    if PBX.hasTmp34 then
        return sim.partProperty(i, "tmp3") or 0
    end
    local t2 = sim.partProperty(i, "tmp2") or 0
    return math.floor(t2 / 16)
end

--- Set the colony id on worker particle `i`, preserving its state nibble.
function PBX.setColony(i, id)
    if PBX.hasTmp34 then
        sim.partProperty(i, "tmp3", id)
        return
    end
    local t2 = sim.partProperty(i, "tmp2") or 0
    sim.partProperty(i, "tmp2", (id * 16) + (t2 % 16))
end

--- Worker state machine value (0 IDLE 1 SEEK 2 HAUL 3 BUILD 4 HOME 5 DIG 6 WANDER).
function PBX.getWorkerState(i)
    local t2 = sim.partProperty(i, "tmp2") or 0
    if PBX.hasTmp34 then return t2 end
    return t2 % 16
end

function PBX.setWorkerState(i, s)
    if PBX.hasTmp34 then
        sim.partProperty(i, "tmp2", s)
        return
    end
    local t2 = sim.partProperty(i, "tmp2") or 0
    sim.partProperty(i, "tmp2", (math.floor(t2 / 16) * 16) + (s % 16))
end

--- Claim token (blueprint cell index + 1, 0 when unclaimed).
function PBX.getClaim(i)
    if PBX.hasTmp34 then return sim.partProperty(i, "tmp4") or 0 end
    return 0
end

function PBX.setClaim(i, v)
    if PBX.hasTmp34 then sim.partProperty(i, "tmp4", v) end
end

--- True when the pixel is inside the simulation and holds no particle.
function PBX.cellFree(x, y)
    if x < 0 or y < 0 or x >= PBX.SIM_W or y >= PBX.SIM_H then return false end
    local ok, r = pcall(sim.pmap, x, y)
    if not ok then return false end
    return r == nil
end

PBX.log("util", "PBX " .. PBX.VERSION .. " loaded, hasTmp34=" .. tostring(PBX.hasTmp34))
