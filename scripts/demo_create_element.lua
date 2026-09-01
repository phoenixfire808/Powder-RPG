-- ===================================================================
-- GENERATED FILE -- do not edit.
-- Built by D:/powder-toy/build_autorun.py from bridge_src/.
-- Base bridge: bridge_src/_base/bridge_base.lua
-- Each module below is loaded in its own chunk so a broken module
-- logs to autorun-runtime.log and is skipped rather than taking the
-- whole bridge down with it.
-- ===================================================================

-- ==== bridge_src/00_util.lua ====
do
    local __src = [=[
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
PBX.MAX_CUSTOM_ELEMENTS    = 160  -- raised 2026-08-26: TPT has 256 ids, ~213 stock; 40 leaves margin

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

]=]
    local __chunk, __err = loadstring(__src, '00_util.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 00_util.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 00_util.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/07_materials_seed.lua ====
do
    local __src = [[
-- ===========================================================================
-- 07_materials_seed.lua -- GENERATED by scripts/gen_materials_seed.py. Do not
-- hand-edit; re-run the generator against a live pbx-custom-elements.json snapshot
-- instead (see that script's own docstring for why this file exists and how it is
-- used -- short version: bridge_src/10_registry.lua seed-fills any of these 64
-- material names not already supplied by a machine's own dev-tooling history, so a
-- fresh download boots with the identical material catalogue as this dev machine,
-- by construction, with no tooling run required).
--
-- Generated: see git blame / the commit that touched this file for the date.
-- Source snapshot entries: 64
-- ===========================================================================

_G.PBX_MATERIALS_SEED = {
    { name = "AERO", group = "POWER", description = "Silica aerogel insulation: 0.02 W/mK (best insulator), fragile, decomposes above 1200 C. Power-saving lagging for pipes and tanks.", colour = 15003898, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1473.15, highTemperatureTransition = "NONE", hardness = 5, weight = 100, heatConduct = 1, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "AL61", group = "MATL", description = "Aluminium 6061-T6: density 2700 kg/m3, k=167 W/mK, melts 582-652C. Self-passivating oxide layer. 2026-08-26 two-stage thermite: FIRE preheats without consuming AL61; at 480K it converts BRMT to IRON and itself to low-conductivity FSLG slag.", colour = 14080733, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 913.15, highTemperatureTransition = "LAVA", hardness = 55, weight = 100, heatConduct = 60, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "FIRE>SELF,SELF:120:.5::FIRE;BRMT>FSLG,IRON:450:.9:HEAT480:FIRE" } } },
    { name = "ALUM", group = "MATL", description = "Alumina (Al2O3) ceramic: density 3950 kg/m3, k=30 W/mK, melts 2072C. Chemically near-inert, used for acid-resistant linings.", colour = 15592941, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 2345.15, highTemperatureTransition = "LAVA", hardness = 2, weight = 100, heatConduct = 80, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "AM24", group = "PBX", description = "Weak radioactive source, like in a smoke detector.", colour = 10133664, type = "SOLID", properties = { "PROP_RADIOACTIVE" }, temperature = 293.15, highTemperature = 1449.15, highTemperatureTransition = "LAVA", hardness = 30, weight = 100, heatConduct = 34, behavior = { ["kind"] = "emitter", ["params"] = { ["count"] = 1, ["emits"] = "PHOT", ["interval"] = 200, ["speed"] = 0, ["temperature"] = 0 } } },
    { name = "ANT", group = "PBX", description = "Colony worker ant.", colour = 14725184, type = "SOLID", properties = {  }, temperature = 295.15, behavior = { ["kind"] = "creature", ["params"] = {  } } },
    { name = "ARGN", group = "MATL", description = "Inert noble gas.", colour = 14208240, menuSection = 6, type = "GAS", properties = {  }, temperature = 293.15, highTemperature = 2273.15, highTemperatureTransition = "NONE", hardness = 0, weight = 1, gravity = 0.1, diffusion = 2, heatConduct = 1, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "ASPH", group = "MATL", description = "Asphalt. Softens when warm, smokes when very hot.", colour = 2829099, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 573.15, highTemperatureTransition = "SMKE", hardness = 55, weight = 100, flammable = 150, heatConduct = 10, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "B4C", group = "POWER", description = "Boron carbide control rod / neutron poison: absorbs NEUT (90%/frame per neighbour), warms 4 K per capture, melts 2763 C.", colour = 1842222, menuSection = 10, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 3036.15, highTemperatureTransition = "LAVA", hardness = 85, weight = 100, heatConduct = 40, behavior = { ["kind"] = "absorber", ["params"] = { ["absorbs"] = "NEUT", ["chance"] = 0.9, ["heatPerHit"] = 4 } } },
    { name = "BAMB", group = "MATL", description = "Bamboo. Strong for its weight, burns easily.", colour = 13157482, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 573.15, highTemperatureTransition = "FIRE", hardness = 30, weight = 100, flammable = 35, heatConduct = 6, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "BE", group = "MATL", description = "Beryllium. Reflects neutrons back into a reactor. Toxic dust.", colour = 12633280, menuSection = 10, type = "SOLID", properties = { "PROP_NEUTPENETRATE" }, temperature = 293.15, highTemperature = 1560.15, highTemperatureTransition = "LAVA", hardness = 55, weight = 100, heatConduct = 187, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "BONE", group = "MATL", description = "Bone. Chars to ash instead of catching fire.", colour = 15591122, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 873.15, highTemperatureTransition = "STNE", hardness = 55, weight = 100, flammable = 10, heatConduct = 9, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "BORO", group = "MATL", description = "Borosilicate glass. Heat- and acid-resistant.", colour = 13624296, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1093.15, highTemperatureTransition = "LAVA", hardness = 3, weight = 100, heatConduct = 11, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "BRSS", group = "MATL", description = "Brass (Cu-Zn alloy): density 8500 kg/m3, k=120 W/mK, melts ~930-940C. Good conductor, moderate corrosion resistance.", colour = 13214247, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 1208.15, highTemperatureTransition = "LAVA", hardness = 45, weight = 100, heatConduct = 140, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "AIR>BRMT,SELF:1:.0005" } } },
    { name = "BSLT", group = "MATL", description = "Basalt rock. Melts back into lava when hot enough.", colour = 3815996, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1473.15, highTemperatureTransition = "LAVA", hardness = 70, weight = 100, heatConduct = 15, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "C60", group = "MATL", description = "Fullerene carbon cage. Sublimes away when very hot.", colour = 2761760, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 950.15, highTemperatureTransition = "SMKE", hardness = 30, weight = 100, heatConduct = 9, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "CAC2", group = "MATL", description = "Calcium carbide CaC2: with water releases acetylene gas (flammable) + lime, mildly exothermic; melts 2160 C. 2026-08-26: reaction now also adds pgas=8 sim.pressure per event (carbide-gas-generator).", colour = 7039842, menuSection = 8, type = "PART", properties = {  }, temperature = 293.15, highTemperature = 2433.15, highTemperatureTransition = "LAVA", hardness = 30, weight = 85, gravity = 0.5, heatConduct = 25, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "WATR>CLST,NONE:+60:0.5::GAS::pgas=8;DSTW>CLST,NONE:+60:0.5::GAS" } } },
    { name = "CACL", group = "MATL", description = "Calcium chloride. Pulls moisture out of the air.", colour = 14737624, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1045.15, highTemperatureTransition = "LAVA", hardness = 20, weight = 100, heatConduct = 11, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "CAF2", group = "MATL", description = "Calcium fluoride crystal. Clear, heat-resistant.", colour = 10141578, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1691.15, highTemperatureTransition = "LAVA", hardness = 20, weight = 100, heatConduct = 34, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "CAO", group = "MATL", description = "Quicklime CaO: reacts exothermically with water (slaking, +~300 K) to hydrated lime (clay-like solid); melts 2613 C.", colour = 15592931, menuSection = 8, type = "PART", properties = {  }, temperature = 293.15, highTemperature = 2886.15, highTemperatureTransition = "LAVA", hardness = 30, weight = 85, gravity = 0.5, heatConduct = 25, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "WATR>CLST,NONE:+300:0.4;DSTW>CLST,NONE:+300:0.4" } } },
    { name = "CD", group = "MATL", description = "Cadmium metal: density 8650 kg/m3, melts only 321C, k=97 W/mK. Very high neutron capture cross-section; used in the first Chicago Pile control rods.", colour = 13159632, menuSection = 10, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 594.15, highTemperatureTransition = "LAVA", hardness = 40, weight = 100, heatConduct = 132, behavior = { ["kind"] = "absorber", ["params"] = { ["absorbs"] = "NEUT", ["chance"] = 0.92, ["heatPerHit"] = 5 } } },
    { name = "CF25", group = "PBX", description = "Intense neutron source.", colour = 8026752, type = "SOLID", properties = { "PROP_NEUTPENETRATE", "PROP_RADIOACTIVE" }, temperature = 293.15, highTemperature = 1173.15, highTemperatureTransition = "LAVA", hardness = 20, weight = 100, heatConduct = 34, behavior = { ["kind"] = "emitter", ["params"] = { ["count"] = 1, ["emits"] = "NEUT", ["interval"] = 8, ["speed"] = 0, ["temperature"] = 0 } } },
    { name = "CFIB", group = "MATL", description = "Carbon fibre. Strong, light, mildly conductive.", colour = 1842204, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 653.15, highTemperatureTransition = "SMKE", hardness = 55, weight = 100, flammable = 60, heatConduct = 25, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "CHIT", group = "MATL", description = "Chitin. Insect-shell material, ignites easily.", colour = 14733480, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 590.15, highTemperatureTransition = "FIRE", hardness = 40, weight = 100, flammable = 180, heatConduct = 8, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "CHRM", group = "MATL", description = "Chromium. Very hard metal, conducts electricity.", colour = 13949148, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 2180.15, highTemperatureTransition = "LAVA", hardness = 5, weight = 100, heatConduct = 129, behavior = { ["kind"] = "conductor", ["params"] = { ["delay"] = 0 } } },
    { name = "CNCR", group = "POWER", description = "Heavy shielding concrete: non-conductive, 1.5 W/mK, spalls to STNE above 1200 C, hardness 95.", colour = 10263182, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1473.15, highTemperatureTransition = "STNE", hardness = 95, weight = 100, heatConduct = 12, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "CNT", group = "MATL", description = "Carbon nanotube. Superb heat conductor.", colour = 4868690, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 3773.15, highTemperatureTransition = "SMKE", hardness = 95, weight = 100, heatConduct = 250, behavior = { ["kind"] = "conductor", ["params"] = { ["delay"] = 0 } } },
    { name = "CO60", group = "MATL", description = "Radioactive cobalt. Strong gamma-ray source.", colour = 9476256, menuSection = 10, type = "SOLID", properties = { "PROP_RADIOACTIVE" }, temperature = 293.15, highTemperature = 1768.15, highTemperatureTransition = "LAVA", hardness = 60, weight = 100, heatConduct = 133, behavior = { ["kind"] = "emitter", ["params"] = { ["count"] = 2, ["emits"] = "PHOT", ["interval"] = 15, ["speed"] = 0, ["temperature"] = 0 } } },
    { name = "COBT", group = "MATL", description = "Cobalt. Magnetic conductive metal.", colour = 9213608, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 1768.15, highTemperatureTransition = "LAVA", hardness = 60, weight = 100, heatConduct = 133, behavior = { ["kind"] = "conductor", ["params"] = { ["delay"] = 0 } } },
    { name = "CORK", group = "MATL", description = "Cork. Light and insulating, chars slowly.", colour = 12618322, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 648.15, highTemperatureTransition = "SMKE", hardness = 40, weight = 100, flammable = 150, heatConduct = 3, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "CROX", group = "PBX", description = "Chromium oxide ember. Glows while hot.", colour = 2771488, type = "SOLID", properties = { "PROP_HOT_GLOW" }, temperature = 293.15, hardness = 30, weight = 100, heatConduct = 60, behavior = { ["kind"] = "glower", ["params"] = { ["maxLife"] = 100, ["minLife"] = 0, ["period"] = 40 } } },
    { name = "CRPS", group = "PBX", description = "A worker's corpse. Fades away in a few seconds.", colour = 4202512, type = "SOLID", properties = {  }, behavior = { ["kind"] = "decayer", ["params"] = { ["becomes"] = "NONE", ["rate"] = 1, ["startLife"] = 150 } } },
    { name = "CRYE", group = "PBX", description = "Cryogenic emitter. Drips liquid nitrogen.", colour = 5012121, type = "SOLID", properties = {  }, temperature = 77, heatConduct = 40, behavior = { ["kind"] = "emitter", ["params"] = { ["count"] = 1, ["emits"] = "LN2", ["interval"] = 20, ["speed"] = 0, ["temperature"] = 0 } } },
    { name = "CTIL", group = "MATL", description = "Glazed ceramic tile. Resists household acids.", colour = 15132384, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1473.15, highTemperatureTransition = "LAVA", hardness = 15, weight = 100, heatConduct = 11, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "CU", group = "POWER", description = "Copper busbar: best practical conductor, 400 W/mK, melts 1085 C. Use for generator output lines.", colour = 13138490, menuSection = 1, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 1358.15, highTemperatureTransition = "LAVA", hardness = 30, weight = 100, heatConduct = 251, behavior = { ["kind"] = "conductor", ["params"] = { ["delay"] = 0 } } },
    { name = "DU", group = "MATL", description = "Depleted uranium: density 19100 kg/m3 (same as natural U), melts 1132C, k=27 W/mK. Much less radioactive than URAN; valued for density.", colour = 4868680, menuSection = 10, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1405.15, highTemperatureTransition = "LAVA", hardness = 25, weight = 100, heatConduct = 73, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "FIRE>STNE,SELF:500:.1:O2:FIRE" } } },
    { name = "EPDM", group = "MATL", description = "EPDM rubber. Weatherproof and chemical-resistant.", colour = 1973790, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 523.15, highTemperatureTransition = "SMKE", hardness = 10, weight = 100, flammable = 90, heatConduct = 7, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "FBRK", group = "MATL", description = "Fired clay brick: density 1900 kg/m3, k=0.8 W/mK, vitrifies/melts ~1150C. Classic load-bearing masonry unit.", colour = 10896926, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1423.15, highTemperatureTransition = "LAVA", hardness = 20, weight = 100, heatConduct = 10, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "FSLG", group = "MATL", description = "Thermite slag (solidified Al2O3/Fe-oxide mix): k~3 W/mK (low, real molten-oxide diffusivity), density ~4200 kg/m3 (rough estimate). Deliberately low HeatConduct so a reacted AL61/BRMT cell holds heat instead of flash-averaging away in one conduction frame.", colour = 4864564, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 2073.15, highTemperatureTransition = "LAVA", hardness = 3, weight = 100, heatConduct = 15, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "GRNT", group = "MATL", description = "Granite: igneous silicate rock, density 2700 kg/m3, k=2.8 W/mK, begins melting ~1215-1260C. Acid-resistant except HF.", colour = 12036506, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1523.15, highTemperatureTransition = "LAVA", hardness = 15, weight = 100, heatConduct = 19, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "GRPH", group = "POWER", description = "Nuclear graphite moderator: neutron-transparent, very high thermal conductivity (~120 W/mK), sublimes ~3600 C.", colour = 3947580, menuSection = 9, type = "SOLID", properties = { "PROP_NEUTPENETRATE" }, temperature = 293.15, highTemperature = 3873.15, highTemperatureTransition = "SMKE", hardness = 50, weight = 100, heatConduct = 140, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "HDPE", group = "MATL", description = "HDPE: density 950 kg/m3, k=0.45-0.5 W/mK, melts ~130C. Outstanding chemical resistance, flammable when molten.", colour = 15263454, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 403.15, highTemperatureTransition = "SMKE", hardness = 3, weight = 100, flammable = 250, heatConduct = 9, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "LEAD", group = "POWER", description = "Lead gamma shielding: heavy, 35 W/mK, melts 327 C - keep it off the hot side.", colour = 5921386, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 600.15, highTemperatureTransition = "LAVA", hardness = 40, weight = 100, heatConduct = 90, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "LEDL", group = "POWER", description = "LED indicator: low-power glow lamp (glower period 30), no heat, for status panels instead of hot LCRY/WIFI.", colour = 16769126, menuSection = 2, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 573.15, highTemperatureTransition = "BMTL", hardness = 20, weight = 100, heatConduct = 20, behavior = { ["kind"] = "glower", ["params"] = { ["maxLife"] = 100, ["minLife"] = 0, ["period"] = 30 } } },
    { name = "LH2", group = "MATL", description = "Liquid hydrogen: boils at 20.3K, density 71 kg/m3, k=0.1 W/mK. Rocket fuel, boils into HYGN gas.", colour = 13166847, menuSection = 7, type = "LIQUID", properties = {  }, temperature = 20, highTemperature = 20.28, highTemperatureTransition = "HYGN", hardness = 0, weight = 2, gravity = 0.1, diffusion = 1, flammable = 1000, heatConduct = 5, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "LHE", group = "MATL", description = "Liquid helium-4: boils at 4.2K, density 125 kg/m3, k=0.02 W/mK. No native freezing point at 1 atm.", colour = 14217471, menuSection = 7, type = "LIQUID", properties = {  }, temperature = 4, highTemperature = 4.22, highTemperatureTransition = "NBLE", hardness = 0, weight = 3, gravity = 0.15, diffusion = 1, heatConduct = 1, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "MG", group = "MATL", description = "Magnesium metal: melts 650 C; once ignited (~630 C) burns at ~3100 C in air producing MgO ash (STNE) and intense white light. 2026-08-26: FIRE-branch now consumes a real O2 neighbour (needs=O2=NONE).", colour = 13225940, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS", "PROP_HOT_GLOW" }, temperature = 293.15, highTemperature = 3373.15, highTemperatureTransition = "LAVA", hardness = 20, weight = 100, flammable = 0, heatConduct = 200, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "FIRE>STNE,SELF:900:.35:O2=NONE:FIRE;PLSM>STNE,SELF:900:.5::FIRE" } } },
    { name = "MWOL", group = "MATL", description = "Mineral (rock) wool batt: k=0.04 W/mK, non-combustible, fibers melt/slag ~1100C.", colour = 14731384, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 1373.15, highTemperatureTransition = "LAVA", hardness = 45, weight = 100, flammable = 0, heatConduct = 3, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "NA", group = "MATL", description = "Sodium metal: melts 98 C, boils 883 C; reacts violently with water -> H2 + NaOH(aq) + ~600 K, ignites the hydrogen.", colour = 14211304, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 371.15, highTemperatureTransition = "243", hardness = 5, weight = 100, flammable = 300, heatConduct = 215, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "WATR>NONE,SLTW:600:.6::H2;DSTW>NONE,SLTW:600:.6::H2" } } },
    { name = "NAK", group = "POWER", description = "Liquid sodium coolant (fast-reactor primary loop): excellent heat carrier (140 W/mK), boils 883 C, burns in air (flammable).", colour = 14277862, menuSection = 7, type = "LIQUID", properties = {  }, temperature = 393.15, highTemperature = 1156.15, highTemperatureTransition = "SMKE", lowTemperature = 371.15, lowTemperatureTransition = "SALT", hardness = 0, weight = 25, gravity = 0.3, diffusion = 0, flammable = 400, heatConduct = 220, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "NAS", group = "MATL", description = "Molten sodium-sulfur (NaS) battery couple: operates 300-350C, freezes solid below ~300C, sodium boils 883C.", colour = 13138474, menuSection = 7, type = "LIQUID", properties = {  }, temperature = 598.15, highTemperature = 1156.15, highTemperatureTransition = "SMKE", lowTemperature = 573.15, lowTemperatureTransition = "SALT", hardness = 0, weight = 64, gravity = 0.25, diffusion = 0, heatConduct = 25, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "WATR>NONE,SLTW:500:.3::FIRE;DSTW>NONE,SLTW:500:.3::FIRE" } } },
    { name = "NBTI", group = "MATL", description = "Niobium-titanium alloy: superconducts below Tc=9.3K, density 6000 kg/m3, k~9 W/mK at room temp, melts ~1950C.", colour = 12633288, menuSection = 1, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 2223.15, highTemperatureTransition = "LAVA", hardness = 75, weight = 100, heatConduct = 33, behavior = { ["kind"] = "conductor", ["params"] = { ["delay"] = 0 } } },
    { name = "PCMP", group = "MATL", description = "Paraffin-wax PCM (RT58-type): melts 58C, latent heat ~200 kJ/kg. Absorbs/releases heat at constant temperature.", colour = 15591126, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 523.15, highTemperatureTransition = "SMKE", hardness = 50, weight = 100, flammable = 200, heatConduct = 7, behavior = { ["kind"] = "pcm", ["params"] = { ["latent"] = 200, ["meltK"] = 331.15, ["rate"] = 4 } } },
    { name = "PTFE", group = "MATL", description = "PTFE (Teflon): density 2200 kg/m3, k=0.25 W/mK, melts 327C, decomposes to toxic fumes above melt. Nearly chemically inert.", colour = 15921902, menuSection = 9, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 600.15, highTemperatureTransition = "SMKE", hardness = 2, weight = 100, flammable = 5, heatConduct = 7, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "PZT", group = "MATL", description = "Lead zirconate titanate ceramic: Curie point ~360C, density 8060 kg/m3, k~1.5 W/mK. Generates charge under mechanical stress.", colour = 5921370, menuSection = 1, type = "SOLID", properties = {  }, temperature = 293.15, highTemperature = 633.15, highTemperatureTransition = "BMTL", hardness = 65, weight = 100, heatConduct = 12, behavior = { ["kind"] = "piezo", ["params"] = { ["period"] = 2, ["threshold"] = 5 } } },
    { name = "RBAR", group = "MATL", description = "Mild-steel rebar: density 7850 kg/m3, k=50 W/mK, melts ~1500C. Conducts; rusts easily (low corrosion resistance).", colour = 8022613, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 1773.15, highTemperatureTransition = "LAVA", hardness = 70, weight = 100, heatConduct = 108, behavior = { ["kind"] = "reactive", ["params"] = { ["rules"] = "WATR>BRMT,SELF:3:.004:O2" } } },
    { name = "RCNC", group = "MATL", description = "Reinforced concrete (steel rebar mesh in 2400 kg/m3 concrete, k=1.7 W/mK). Rebar corrodes; spalls ~300C under fire load.", colour = 10132116, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 573.15, highTemperatureTransition = "STNE", hardness = 25, weight = 100, heatConduct = 13, behavior = { ["kind"] = "conductor", ["params"] = { ["delay"] = 0 } } },
    { name = "S316", group = "MATL", description = "316 stainless steel: density 8000 kg/m3, k=16 W/mK, melts ~1400C. Mo-alloyed, excellent chloride/acid resistance.", colour = 13094353, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 1673.15, highTemperatureTransition = "LAVA", hardness = 5, weight = 100, heatConduct = 51, behavior = { ["kind"] = "conductor", ["params"] = { ["delay"] = 0 } } },
    { name = "SIC", group = "MATL", description = "Silicon carbide: density 3210 kg/m3, k=120 W/mK, decomposes/sublimes ~2700C. Semiconductor; used in power electronics.", colour = 2829104, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 2973.15, highTemperatureTransition = "LAVA", hardness = 3, weight = 100, heatConduct = 140, behavior = { ["kind"] = "inert", ["params"] = {  } } },
    { name = "SIPV", group = "MATL", description = "Monocrystalline silicon PV cell: ~22% sunlight-to-electricity efficiency, melts 1414C, k=150 W/mK. Attacked only by HF.", colour = 1714762, menuSection = 1, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 1687.15, highTemperatureTransition = "LAVA", hardness = 5, weight = 100, heatConduct = 161, behavior = { ["kind"] = "photovoltaic", ["params"] = { ["chance"] = 0.88, ["heat"] = 0.5, ["perSpark"] = 3 } } },
    { name = "STEL", group = "POWER", description = "SA-508 reactor pressure-vessel steel: conducts, 40 W/mK, melts 1500 C, hardness 80.", colour = 9080984, menuSection = 9, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 1773.15, highTemperatureTransition = "LAVA", hardness = 80, weight = 100, heatConduct = 100, behavior = { ["kind"] = "conductor", ["params"] = { ["delay"] = 0 } } },
    { name = "TEG", group = "POWER", description = "Thermoelectric generator (Bi2Te3): above 100 C it pulses SPRK into touching conductors every 20 frames, shedding 2 K per pulse. Waste-heat recovery / power saving.", colour = 4172394, menuSection = 2, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 858.15, highTemperatureTransition = "BMTL", hardness = 40, weight = 100, heatConduct = 80, behavior = { ["kind"] = "teg", ["params"] = { ["drop"] = 2, ["onTemp"] = 373.15, ["period"] = 20 } } },
    { name = "TRBN", group = "POWER", description = "Steam turbine stage: condenses adjacent WTRV to DSTW (25%/frame) and sparks touching conductors per unit of work; tmp = cumulative work. Steel body, melts 1400 C.", colour = 7241360, menuSection = 2, type = "SOLID", properties = { "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 1673.15, highTemperatureTransition = "LAVA", hardness = 70, weight = 100, heatConduct = 100, behavior = { ["kind"] = "turbine", ["params"] = { ["chance"] = 0.25, ["cool"] = 60, ["input"] = "WTRV", ["output"] = "DSTW" } } },
    { name = "UO2", group = "POWER", description = "Uranium dioxide fuel pellet: slow spontaneous fission (NEUT emitter), melts 2865 C, poor heat conductor (8 W/mK). Clad it in ZIRC.", colour = 2829104, menuSection = 10, type = "SOLID", properties = { "PROP_NEUTPENETRATE", "PROP_RADIOACTIVE" }, temperature = 293.15, highTemperature = 3138.15, highTemperatureTransition = "LAVA", hardness = 90, weight = 100, heatConduct = 30, behavior = { ["kind"] = "emitter", ["params"] = { ["count"] = 1, ["emits"] = "NEUT", ["interval"] = 120, ["speed"] = 0, ["temperature"] = 0 } } },
    { name = "ZIRC", group = "POWER", description = "Zircaloy-4 cladding: neutron-transparent, conducts heat (22 W/mK) and electricity, melts 1852 C.", colour = 11844804, menuSection = 9, type = "SOLID", properties = { "PROP_NEUTPENETRATE", "PROP_CONDUCTS" }, temperature = 293.15, highTemperature = 2125.15, highTemperatureTransition = "LAVA", hardness = 60, weight = 100, heatConduct = 60, behavior = { ["kind"] = "inert", ["params"] = {  } } },
}

]]
    local __chunk, __err = loadstring(__src, '07_materials_seed.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 07_materials_seed.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 07_materials_seed.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/10_registry.lua ====
do
    local __src = [=[
-- ===========================================================================
-- 10_registry.lua -- PBX custom-element registry
--
-- Owns the four actions from EXTENSION_SPEC section 4.1 -- defineElement,
-- listCustomElements, updateElement, deleteCustomElement -- and the
-- PBX.state.registry namespace other modules use to resolve a custom element
-- id by name.
--
-- Two hard constraints shape everything below.
--
-- 1) elements.allocate / elements.element / elements.property / elements.free
--    all call lsi->AssertMutableToolsEvent() (LuaElements.cpp:316, :414, :565,
--    :719).  The HTTP handler runs inside LuaSocket::Process, which is not a
--    mutable-tools event, so calling any of them from an action would abort
--    the game.  Every mutation is therefore pushed through PBX.defer and the
--    action returns { job = <id>, status = "pending" }.  There is no
--    synchronous wait -- blocking the handler deadlocks on the same lock --
--    so the caller polls the built-in `jobStatus` action.
--
-- 2) Because the real work happens a tick later, validation has to happen up
--    front.  Everything is checked with the PBX.v* validators *before* the job
--    is queued, so a bad request fails synchronously with a message the caller
--    can act on, instead of surfacing as a dead job one poll later.
--
-- Lua 5.1 only: no goto, no `//`, no bitwise operators.
-- ===========================================================================

local MODULE  = "registry"
local R       = PBX.state.registry     -- our single key on the shared namespace
local PERSIST = "custom-elements"      -- -> pbx-custom-elements.json

R.VERSION = "1.0.0"

-- UPPERNAME -> { id = <int|nil>, spec = <table>, hasUpdate = <bool> }
-- `id` is nil in the window between a define being accepted and its deferred
-- job running; listCustomElements reports that honestly rather than inventing
-- an id that does not exist yet.
R.byName = R.byName or {}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

--- Bitwise OR of two non-negative 31-bit integers.
--- Lua 5.1 has no bitwise operators and TPT's `bit` library is an optional
--- extra we would rather not depend on.  A plain sum would *almost* work,
--- because every element flag is a distinct bit, but it would silently carry
--- if a caller ever listed one flag twice and corrupt the word.  OR cannot.
local function bor(a, b)
    local res, place = 0, 1
    for _ = 1, 31 do
        local abit, bbit = a % 2, b % 2
        if abit == 1 or bbit == 1 then res = res + place end
        a, b = (a - abit) / 2, (b - bbit) / 2
        place = place * 2
    end
    return res
end

--- Sorted key list of a map, for "available: a, b, c" error messages.
local function sortedKeys(t)
    local out = {}
    if type(t) == "table" then
        for k in pairs(t) do out[#out + 1] = tostring(k) end
    end
    table.sort(out)
    return out
end

local function copyList(t)
    local out = {}
    if type(t) == "table" then
        for i = 1, #t do out[i] = t[i] end
    end
    return PBX.arr(out)
end

local function copyMap(t)
    local out = {}
    if type(t) == "table" then
        for k, v in pairs(t) do out[k] = v end
    end
    return out
end

--- Stable string form of a value, used only to decide whether an update
--- actually changed a field, so `changed` never reports a no-op write.
--- PBX.encode sorts map keys, so two equal tables always compare equal.
local function fingerprint(v)
    if v == nil then return "nil" end
    return PBX.encode(v)
end

-- ---------------------------------------------------------------------------
-- Element constants, read once from the `elements` table.
--
-- Reading elements.TYPE_* / PROP_* / SC_* is a plain table lookup and does not
-- trip AssertMutableToolsEvent, so this is safe at load time.  Flags are
-- resolved through the live table rather than hard-coded numbers: their values
-- are build-time constants in TPT and we do not want to bake them in here.
-- ---------------------------------------------------------------------------

local E = _G.elements

local TYPE_NAMES = { "PART", "LIQUID", "SOLID", "GAS", "ENERGY" }
local TYPE_BITS  = {}
for i = 1, #TYPE_NAMES do
    local n = TYPE_NAMES[i]
    TYPE_BITS[n] = (E and E["TYPE_" .. n]) or 0
end

-- Exactly the PROP_* constants LuaElements::Open publishes
-- (LuaElements.cpp:865-:879).  Anything outside this list is rejected by name.
local PROP_NAMES = {
    "CONDUCTS", "PHOTPASS", "NEUTPENETRATE", "NEUTABSORB", "NEUTPASS",
    "DEADLY", "HOT_GLOW", "LIFE", "RADIOACTIVE", "LIFE_DEC", "LIFE_KILL",
    "LIFE_KILL_DEC", "SPARKSETTLE", "NOAMBHEAT", "NOCTYPEDRAW",
}
local PROP_BITS, PROP_LIST = {}, {}
for i = 1, #PROP_NAMES do
    local n = PROP_NAMES[i]
    local v = E and E["PROP_" .. n]
    -- A build that does not export one of these simply does not offer it,
    -- rather than us OR-ing a nil into the Properties word.
    if type(v) == "number" then
        PROP_BITS[n] = v
        PROP_LIST[#PROP_LIST + 1] = "PROP_" .. n
    end
end
local PROP_LIST_STR = table.concat(PROP_LIST, ", ")

local SECTION_NAMES = {
    "WALL", "ELEC", "POWERED", "SENSOR", "FORCE", "EXPLOSIVE", "GAS",
    "LIQUID", "POWDERS", "SOLIDS", "NUCLEAR", "SPECIAL", "LIFE", "TOOL", "DECO",
}
local SECTION_BITS = {}
for i = 1, #SECTION_NAMES do
    local n = SECTION_NAMES[i]
    local v = E and E["SC_" .. n]
    if type(v) == "number" then SECTION_BITS[n] = v end
end
local MAX_SECTION     = ((E and E.NUM_MENUSECTIONS) or 16) - 1
local DEFAULT_SECTION = SECTION_BITS.SPECIAL or 0

-- Transition sentinel from TransitionConstants.h: NT = -1 means "no
-- transition".  MIN_TEMP/MAX_TEMP are 0/9999 and ITL/ITH (the "never fires"
-- values) sit one step outside that, which is why the temperature *threshold*
-- bounds below are -1..10000 while the spawn temperature is 0..9999.
local NT = -1

-- ---------------------------------------------------------------------------
-- Per-type physics baseline.
--
-- SPEC INTERPRETATION: section 4.1 only says `type` maps onto TYPE_*.  But a
-- TYPE_LIQUID element with Falldown 0 and Advection 0 does not flow at all, so
-- declaring `type = "LIQUID"` and getting a static block back would be
-- useless.  Each type therefore also seeds the movement fields from a
-- representative built-in (DUST / WATR / GAS / PHOT), and any field the caller
-- states explicitly overrides the baseline.  CFDS is 4.0/CELL == 1.0 in this
-- build (SimulationConfig.h:33), so the `x * CFDS` numbers in the element
-- sources are reused verbatim.  SOLID is a neutral structural middle ground
-- rather than a copy of BRCK, and deliberately has zero advection and gravity
-- so it is directly usable as the worker body described in spec section 3.
-- ---------------------------------------------------------------------------

local PHYSICS = {
    PART = {   -- modelled on DUST
        Advection = 0.7, AirDrag = 0.02, AirLoss = 0.96, Loss = 0.80,
        Collision = 0.0, Gravity = 0.1, Diffusion = 0.00, HotAir = 0.0,
        Falldown = 1, Weight = 85, HeatConduct = 70, Hardness = 30,
    },
    LIQUID = { -- modelled on WATR
        Advection = 0.6, AirDrag = 0.01, AirLoss = 0.98, Loss = 0.95,
        Collision = 0.0, Gravity = 0.1, Diffusion = 0.00, HotAir = 0.0,
        Falldown = 2, Weight = 30, HeatConduct = 29, Hardness = 20,
    },
    SOLID = {  -- neutral structural solid; immobile by construction
        Advection = 0.0, AirDrag = 0.00, AirLoss = 0.90, Loss = 0.00,
        Collision = 0.0, Gravity = 0.0, Diffusion = 0.00, HotAir = 0.0,
        Falldown = 0, Weight = 100, HeatConduct = 100, Hardness = 30,
    },
    GAS = {    -- modelled on GAS
        Advection = 1.0, AirDrag = 0.01, AirLoss = 0.99, Loss = 0.30,
        Collision = -0.1, Gravity = 0.0, Diffusion = 0.75, HotAir = 0.0,
        Falldown = 0, Weight = 1, HeatConduct = 42, Hardness = 1,
    },
    ENERGY = { -- modelled on PHOT
        Advection = 0.0, AirDrag = 0.00, AirLoss = 1.00, Loss = 1.00,
        Collision = -0.99, Gravity = 0.0, Diffusion = 0.00, HotAir = 0.0,
        Falldown = 0, Weight = -1, HeatConduct = 251, Hardness = 0,
    },
}

-- ---------------------------------------------------------------------------
-- Declarative field table.
--
-- key   : request/spec field name (camelCase, as the bridge action sees it)
-- prop  : the Element property name written through elements.element().  Names
--         verified against Element::GetProperties (Element.cpp:63-105).
-- kind  : which validator runs
-- alias : accepted alternative request key
--
-- Driving validation, application and the `changed` diff from one table is
-- what keeps those three from drifting apart.
-- ---------------------------------------------------------------------------

local FIELDS = {
    { key = "description",               prop = "Description",               kind = "str", max = 256 },
    { key = "colour",                    prop = "Colour",                    kind = "int", min = 0, max = 0xFFFFFF, alias = "color" },
    { key = "menuSection",               prop = "MenuSection",               kind = "menu" },
    { key = "temperature",               prop = "Temperature",               kind = "num", min = 0,  max = 9999 },
    { key = "highTemperature",           prop = "HighTemperature",           kind = "num", min = -1, max = 10000 },
    { key = "highTemperatureTransition", prop = "HighTemperatureTransition", kind = "trans" },
    { key = "lowTemperature",            prop = "LowTemperature",            kind = "num", min = -1, max = 10000 },
    { key = "lowTemperatureTransition",  prop = "LowTemperatureTransition",  kind = "trans" },
    { key = "hardness",                  prop = "Hardness",                  kind = "int", min = 0,  max = 255 },
    { key = "weight",                    prop = "Weight",                    kind = "int", min = -1, max = 100 },
    { key = "gravity",                   prop = "Gravity",                   kind = "num", min = -5, max = 5 },
    { key = "diffusion",                 prop = "Diffusion",                 kind = "num", min = 0,  max = 5 },
    { key = "flammable",                 prop = "Flammable",                 kind = "int", min = 0,  max = 1000 },
    { key = "explosive",                 prop = "Explosive",                 kind = "int", min = 0,  max = 2 },
    { key = "heatConduct",               prop = "HeatConduct",               kind = "int", min = 0,  max = 255 },
}

-- ---------------------------------------------------------------------------
-- Field validators.  Each returns value, nil or nil, message.
-- ---------------------------------------------------------------------------

--- Menu section: a numeric id, or a section name with or without the SC_
--- prefix ("SOLIDS", "SC_SOLIDS").  Names are friendlier for a model caller
--- than remembering which integer SC_SPECIAL happens to be in this build.
local function validateMenuSection(raw)
    if type(raw) == "string" then
        local up = string.upper(raw)
        up = up:gsub("^SC_", "")
        local v = SECTION_BITS[up]
        if v == nil then
            return nil, "menuSection must be a section id or one of " ..
                        table.concat(SECTION_NAMES, ", ")
        end
        return v, nil
    end
    return PBX.vInt(raw, "menuSection", 0, MAX_SECTION)
end

--- Transition target.  Stored in the spec as given (an upper-cased element
--- name, or a number) and re-resolved at apply time, so a spec persisted as
--- "WATR" still means water after a restart.  -1 / "NT" is no transition;
--- 0 / "NONE" destroys the particle.
local function validateTransition(raw, key)
    if type(raw) == "number" then
        local n, e = PBX.vInt(raw, key, -1, 65535)
        if e then return nil, e end
        if n ~= NT and n ~= 0 and not elements.exists(n) then
            return nil, key .. " must be -1 (no transition), 0 (destroy), or a live element id"
        end
        return n, nil
    end
    if type(raw) ~= "string" then
        return nil, key .. " must be an element name, an element id, or \"NT\""
    end
    local up = string.upper(raw)
    if up == "NT" or up == "NONE_TRANSITION" then return NT, nil end
    local _, e = PBX.vElem(up)
    if e then return nil, key .. ": " .. e end
    return up, nil
end

--- Turn a stored transition value back into the number elements.element wants.
local function resolveTransition(v)
    if type(v) == "number" then return v end
    local up = string.upper(tostring(v))
    if up == "NT" or up == "NONE_TRANSITION" then return NT end
    local id = PBX.vElem(up)
    -- Validation already proved this resolves; NT is the safe fallback if a
    -- hand-edited persisted spec names an element that no longer exists.
    return id or NT
end

local function validateField(f, raw)
    if f.kind == "str" then
        return PBX.vStr(raw, f.key, f.max)
    elseif f.kind == "int" then
        return PBX.vInt(raw, f.key, f.min, f.max)
    elseif f.kind == "num" then
        return PBX.vNum(raw, f.key, f.min, f.max)
    elseif f.kind == "menu" then
        return validateMenuSection(raw)
    elseif f.kind == "trans" then
        return validateTransition(raw, f.key)
    end
    return nil, f.key .. " has no validator"
end

--- Element name: 1-4 characters of A-Z0-9.  allocate() upper-cases the name
--- and rejects '_' itself (LuaElements.cpp:322), but it does so by raising a
--- Lua error inside the deferred job, which the caller would only discover on
--- a later jobStatus poll -- so the same rule is enforced here, synchronously.
local function validateName(raw)
    if raw == nil then return nil, "name is required" end
    if type(raw) ~= "string" then return nil, "name must be a string" end
    local up = string.upper(raw)
    local v, e = PBX.vStr(up, "name", 4, "^[A-Z0-9]+$")
    if e then
        return nil, "name must be 1-4 characters of A-Z or 0-9 (no underscore)"
    end
    return v, nil
end

--- Group name, default PBX.  'DEFAULT' and any '_' are refused by allocate
--- (LuaElements.cpp:322-:333); refuse them here for the same fail-fast reason.
local function validateGroup(raw)
    if raw == nil then return "PBX", nil end
    if type(raw) ~= "string" then return nil, "group must be a string" end
    local up = string.upper(raw)
    local v, e = PBX.vStr(up, "group", 12, "^[A-Z0-9]+$")
    if e then
        return nil, "group must be 1-12 characters of A-Z or 0-9 (no underscore)"
    end
    if v == "DEFAULT" then
        return nil, "group must not be DEFAULT (elements.allocate refuses that group)"
    end
    return v, nil
end

--- Flag-name array -> canonical "PROP_X" names.  Unknown flags are rejected
--- *by name* so the caller learns which entry was wrong, not merely that one
--- of them was.
local function validateProperties(raw)
    local list, e = PBX.vList(raw, "properties", 32)
    if e then return nil, e end
    local out, seen = {}, {}
    for i = 1, #list do
        local v = list[i]
        if type(v) ~= "string" then
            return nil, "properties[" .. i .. "] must be a flag name string"
        end
        local up = string.upper(v)
        up = up:gsub("^PROP_", "")
        if TYPE_BITS[up] ~= nil or up:match("^TYPE_") then
            return nil, "properties[" .. i .. "]: '" .. v ..
                        "' is a state flag -- set it through the `type` field instead"
        end
        if PROP_BITS[up] == nil then
            return nil, "unknown element property flag '" .. v ..
                        "'; known flags: " .. PROP_LIST_STR
        end
        if not seen[up] then
            seen[up] = true
            out[#out + 1] = "PROP_" .. up
        end
    end
    return PBX.arr(out), nil
end

-- ---------------------------------------------------------------------------
-- Behaviour resolution (20_behaviors.lua publishes PBX.state.behaviors.kinds)
-- ---------------------------------------------------------------------------

--- Normalise one parameter descriptor.  Spec section 4.2 writes a kind's
--- params as `{name = {type, min, max, default}}`, which is ambiguous between
--- a keyed and a positional table, so both shapes are accepted.
local function paramSchema(p)
    if type(p) ~= "table" then return nil end
    if p.type ~= nil then
        return { type = p.type, min = p.min, max = p.max, default = p.default, max_len = p.maxLen }
    end
    return { type = p[1], min = p[2], max = p[3], default = p[4] }
end

--- Look up a behaviour kind and validate/default its params.
--- Returns kindDef, params on success or nil, message on failure.
--- Called from the handler so a bad kind fails fast, and again from inside the
--- job, which is the authoritative call.  Note 20_behaviors.lua is
--- concatenated *after* this file, so kinds do not exist while this module is
--- loading -- see the lenient path in validateSpec for why that matters.
local function resolveBehavior(behavior)
    local B = PBX.state.behaviors
    local kinds = B and B.kinds
    if type(kinds) ~= "table" or next(kinds) == nil then
        return nil, "no behavior kinds are registered yet -- " ..
                    "20_behaviors.lua has not published PBX.state.behaviors.kinds"
    end

    local kind = behavior and behavior.kind
    local def = kinds[kind]
    if type(def) ~= "table" then
        return nil, "unknown behavior kind '" .. tostring(kind) ..
                    "'; available kinds: " .. table.concat(sortedKeys(kinds), ", ")
    end

    local given = (behavior and behavior.params) or {}
    if type(given) ~= "table" then
        return nil, "behavior.params must be a table"
    end

    local out = {}
    if type(def.params) == "table" then
        -- Reject params the kind does not declare: a typo'd param name would
        -- otherwise silently do nothing and read as a broken element.
        local allowed = sortedKeys(def.params)
        for pname in pairs(given) do
            if def.params[pname] == nil then
                return nil, "behavior kind '" .. tostring(kind) .. "' has no parameter '" ..
                            tostring(pname) .. "'; accepts: " ..
                            (#allowed > 0 and table.concat(allowed, ", ") or "(none)")
            end
        end
        for pname, praw in pairs(def.params) do
            local ps = paramSchema(praw)
            local v = given[pname]
            if v == nil and ps then v = ps.default end
            if v ~= nil and ps then
                local label = tostring(kind) .. "." .. tostring(pname)
                local t = string.lower(tostring(ps.type or ""))
                local e = nil
                if t == "int" or t == "integer" then
                    v, e = PBX.vInt(v, label, ps.min, ps.max)
                elseif t == "num" or t == "number" or t == "float" then
                    v, e = PBX.vNum(v, label, ps.min, ps.max)
                elseif t == "bool" or t == "boolean" then
                    v, e = PBX.vBool(v, label, ps.default)
                elseif t == "str" or t == "string" then
                    v, e = PBX.vStr(v, label, ps.max_len or 64)
                elseif t == "elem" or t == "element" then
                    v, e = PBX.vElem(v)
                end
                -- An unrecognised declared type is passed through untouched
                -- rather than rejected: 20_behaviors owns that vocabulary and
                -- we must not start failing on a type name it adds later.
                if e then return nil, e end
            end
            if v ~= nil then out[pname] = v end
        end
    else
        -- The kind declares no schema; take the caller's params as given.
        out = copyMap(given)
    end

    return def, out
end

-- ---------------------------------------------------------------------------
-- Spec validation
-- ---------------------------------------------------------------------------

--- Build a validated spec from a request, optionally merged onto an existing
--- one (that is what makes updateElement a partial update).
--- Returns spec, changed, nil or nil, nil, message.  `changed` lists the
--- request keys whose stored value actually differs from the base.
---
--- `lenientBehavior` skips behaviour-kind resolution.  It is used only when
--- re-validating specs read off disk during module load, at which point
--- 20_behaviors.lua has not been concatenated in yet and every kind would
--- otherwise look unknown; the recreation job resolves the kind for real one
--- tick later.
local function validateSpec(req, base, lenientBehavior)
    local spec, changed = {}, {}

    local function note(key, oldv, newv)
        if fingerprint(oldv) ~= fingerprint(newv) then
            changed[#changed + 1] = key
        end
    end

    -- name and group are identity: the identifier GROUP_PT_NAME is baked into
    -- the element slot at allocation and cannot be rewritten in place.
    if base then
        spec.name  = base.name
        spec.group = base.group
        if req.group ~= nil then
            local g, e = validateGroup(req.group)
            if e then return nil, nil, e end
            if g ~= base.group then
                return nil, nil, "group cannot be changed (identifier " .. base.group ..
                                 "_PT_" .. base.name .. " is fixed at allocation); " ..
                                 "delete the element and define it again"
            end
        end
    else
        local n, e = validateName(req.name)
        if e then return nil, nil, e end
        spec.name = n
        local g; g, e = validateGroup(req.group)
        if e then return nil, nil, e end
        spec.group = g
    end

    -- type -> TYPE_* state flag
    if req.type ~= nil then
        local t, e = PBX.vEnum(string.upper(tostring(req.type)), "type", TYPE_NAMES)
        if e then return nil, nil, e end
        note("type", base and base.type, t)
        spec.type = t
    else
        spec.type = (base and base.type) or "SOLID"
    end

    -- properties -> PROP_* flag names
    if req.properties ~= nil then
        local p, e = validateProperties(req.properties)
        if e then return nil, nil, e end
        note("properties", base and base.properties, p)
        spec.properties = p
    elseif base then
        spec.properties = copyList(base.properties)
    else
        spec.properties = PBX.arr({})
    end

    -- scalar fields
    for i = 1, #FIELDS do
        local f = FIELDS[i]
        local raw = req[f.key]
        if raw == nil and f.alias then raw = req[f.alias] end
        if raw ~= nil then
            local v, e = validateField(f, raw)
            if e then return nil, nil, e end
            note(f.key, base and base[f.key], v)
            spec[f.key] = v
        elseif base then
            spec[f.key] = base[f.key]
        end
    end

    -- behaviour
    local bReq = req.behavior
    if bReq ~= nil and type(bReq) ~= "table" then
        return nil, nil, "behavior must be a table { kind = ..., params = { ... } }"
    end
    local baseB = base and base.behavior
    local wanted
    if bReq then
        wanted = { kind = bReq.kind or (baseB and baseB.kind) or "inert", params = bReq.params }
        -- Carrying the old params forward when only the kind was restated
        -- lets a caller re-send `{kind="glower"}` without wiping its tuning.
        if wanted.params == nil and baseB and wanted.kind == baseB.kind then
            wanted.params = copyMap(baseB.params)
        end
    elseif baseB then
        wanted = { kind = baseB.kind, params = copyMap(baseB.params) }
    else
        wanted = { kind = "inert", params = {} }
    end
    if type(wanted.kind) ~= "string" then
        return nil, nil, "behavior.kind must be a string"
    end

    if lenientBehavior then
        spec.behavior = { kind = wanted.kind, params = copyMap(wanted.params) }
    else
        local def, params = resolveBehavior(wanted)
        if not def then return nil, nil, params end   -- params holds the message
        spec.behavior = { kind = wanted.kind, params = params }
    end
    if bReq then note("behavior", baseB, spec.behavior) end

    return spec, changed, nil
end

-- ---------------------------------------------------------------------------
-- Applying a spec (SIMULATION THREAD ONLY -- always reached through PBX.defer)
-- ---------------------------------------------------------------------------

--- Translate a spec into the property table elements.element() consumes.
local function buildElementTable(spec)
    local t = {
        Name        = spec.name,
        MenuVisible = 1,
        MenuSection = DEFAULT_SECTION,
        Description = "PBX custom element " .. spec.name,
    }

    -- Type baseline first, explicit fields last: the caller always wins.
    local base = PHYSICS[spec.type] or PHYSICS.SOLID
    for k, v in pairs(base) do t[k] = v end

    -- Properties word: the TYPE_* state flag OR'd with every requested PROP_*.
    local bits = TYPE_BITS[spec.type] or TYPE_BITS.SOLID or 0
    local props = spec.properties or {}
    for i = 1, #props do
        local name = tostring(props[i]):gsub("^PROP_", "")
        local v = PROP_BITS[name]
        if v then bits = bor(bits, v) end
    end
    t.Properties = bits

    for i = 1, #FIELDS do
        local f = FIELDS[i]
        local v = spec[f.key]
        if v ~= nil then
            if f.kind == "trans" then v = resolveTransition(v) end
            t[f.prop] = v
        end
    end

    return t
end

--- Create or refresh the live element for `spec`.  MUST run inside a deferred
--- job: allocate/element/property all assert unless the calling event is a
--- mutable-tools event.  Returns id, hasUpdate.  Raises on failure so the job
--- record carries the message.
local function applySpec(spec, existingId)
    local id = existingId
    if id == nil or not elements.exists(id) then
        -- elements.allocate(group, id) -> new numeric id, or -1 when every
        -- element slot is taken (LuaElements.cpp:313-:395).
        id = elements.allocate(spec.group, spec.name)
        if type(id) ~= "number" or id < 0 then
            error("elements.allocate returned " .. tostring(id) ..
                  " -- no free element slots for " .. spec.group .. "_PT_" .. spec.name, 0)
        end
    end

    -- elements.element(id, table) writes every recognised Element property
    -- present in the table and leaves the rest alone.
    elements.element(id, buildElementTable(spec))

    -- Behaviour is installed separately, as spec section 4.2 requires.
    local def, params = resolveBehavior(spec.behavior)
    if not def then error(params, 0) end
    local fn = def.make(params)
    if type(fn) == "function" then
        -- elements.property(id, "Update", fn) stores the closure and points
        -- Element::Update at luaUpdateWrapper (LuaElements.cpp:565-:600).
        elements.property(id, "Update", fn)
        return id, true
    end
    -- `inert` and friends may legitimately return nothing; the caller decides
    -- whether an older Update needs clearing.
    return id, false
end

--- Drop a previously installed Update.  Passing `false` (not nil) is what
--- restores the builtin handler -- a nil third argument is a silent no-op in
--- LuaElements::property (LuaElements.cpp:565-:585).
local function clearUpdate(id)
    elements.property(id, "Update", false)
end

-- ---------------------------------------------------------------------------
-- Persistence and the published registry API
-- ---------------------------------------------------------------------------

--- Write every known spec to pbx-custom-elements.json.  Called after any
--- mutation.  Failures are logged, never raised: losing the snapshot must not
--- fail a request whose in-world effect already succeeded.
local function persist()
    local list = {}
    for _, ent in pairs(R.byName) do list[#list + 1] = ent.spec end
    table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
    local ok, err = PBX.save(PERSIST, PBX.arr(list))
    if not ok then PBX.warn(MODULE, "persist failed: " .. tostring(err)) end
end

--- Number of registered custom elements (60_diag reports this).
function R.count()
    local n = 0
    for _ in pairs(R.byName) do n = n + 1 end
    return n
end

--- Resolve a custom element by name -> { id = <int|nil>, spec = <table> }.
--- `id` is nil only between a define being accepted and its deferred job
--- running, so callers must tolerate that.
function R.get(name)
    if type(name) ~= "string" then return nil end
    return R.byName[string.upper(name)]
end

--- Convenience: the live numeric id for a custom element name, or nil.
function R.id(name)
    local ent = R.get(name)
    return ent and ent.id or nil
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- defineElement -- allocate, or redefine in place, a custom element.
--- Idempotent on `name`: a second define for the same name reuses the same
--- element id instead of burning another of the 24 slots.
--- Returns { job, status = "pending", name, identifier, created } plus the
--- already-known `id` on a redefine.  The job's value is
--- { id, identifier, created }.
PBX.register("defineElement", function(req)
    local nameOk, nameErr = validateName(req.name)
    if nameErr then return PBX.err(nameErr) end

    local existing = R.byName[nameOk]
    local created  = (existing == nil)

    if created and R.count() >= PBX.MAX_CUSTOM_ELEMENTS then
        return PBX.err("custom element limit reached (" .. PBX.MAX_CUSTOM_ELEMENTS ..
                       "); delete one with deleteCustomElement first",
                       { limit = PBX.MAX_CUSTOM_ELEMENTS, count = R.count() })
    end

    local spec, _, err = validateSpec(req, existing and existing.spec or nil, false)
    if err then return PBX.err(err) end

    local identifier = spec.group .. "_PT_" .. spec.name
    local prevId     = existing and existing.id or nil
    local prevHad    = (existing and existing.hasUpdate) and true or false

    -- Reserve the name synchronously so two defines racing through the handler
    -- cannot both allocate a slot for it, and so the count cap stays honest
    -- during the tick before the job runs.
    R.byName[spec.name] = { id = prevId, spec = spec, hasUpdate = prevHad }

    local job = PBX.defer(function()
        local ok, res, hadUpdate = pcall(applySpec, spec, prevId)
        if not ok then
            -- Roll the reservation back so the name, and the slot it counted
            -- against, are free again.  An element that already existed is
            -- left registered because it is still live in the sim.
            if prevId == nil then R.byName[spec.name] = nil end
            error(res, 0)
        end
        local id = res
        local ent = R.byName[spec.name]
        if ent then
            -- Going from a behaviour that has an Update to one that does not
            -- must actively clear the old closure, or the element keeps
            -- running last definition's code.
            if ent.hasUpdate and not hadUpdate then clearUpdate(id) end
            ent.id = id
            ent.hasUpdate = hadUpdate and true or false
        end
        persist()
        PBX.log(MODULE, (created and "defined " or "redefined ") .. identifier ..
                        " as id " .. tostring(id))
        return { id = id, identifier = identifier, created = created }
    end)

    return PBX.ok("defineElement", {
        job = job, status = "pending", name = spec.name,
        identifier = identifier, created = created, id = prevId,
    })
end, MODULE)

--- listCustomElements -- every registered spec plus its live id.
--- Pure read, so it answers synchronously with no job.
PBX.register("listCustomElements", function()
    local names = sortedKeys(R.byName)
    local out = PBX.arr({})
    for i = 1, #names do
        local ent = R.byName[names[i]]
        local row = {}
        for k, v in pairs(ent.spec) do row[k] = v end
        row.id         = ent.id
        row.identifier = ent.spec.group .. "_PT_" .. ent.spec.name
        -- elements.exists is a pure read with no AssertMutableToolsEvent
        -- (LuaElements.cpp:752), so it is safe from the socket thread.
        row.live       = (ent.id ~= nil) and elements.exists(ent.id) or false
        out[#out + 1]  = row
    end
    return PBX.ok("listCustomElements", {
        elements = out, count = #out, limit = PBX.MAX_CUSTOM_ELEMENTS,
    })
end, MODULE)

--- updateElement -- change any subset of an existing element's define fields.
--- Returns { job, status, id, name, changed }; the job re-applies the merged
--- spec and its value is { id, changed }.
PBX.register("updateElement", function(req)
    local nameOk, nameErr = validateName(req.name)
    if nameErr then return PBX.err(nameErr) end

    local ent = R.byName[nameOk]
    if not ent then
        return PBX.err("no custom element named " .. nameOk ..
                       " (use defineElement first)", { name = nameOk })
    end

    local spec, changed, err = validateSpec(req, ent.spec, false)
    if err then return PBX.err(err) end

    local prevId  = ent.id
    local prevHad = ent.hasUpdate and true or false
    -- Store the merged spec immediately: a second update in the same tick has
    -- to build on the first one, not on the pre-update state.
    ent.spec = spec

    local job = PBX.defer(function()
        local ok, res, hadUpdate = pcall(applySpec, spec, prevId)
        if not ok then error(res, 0) end
        local id = res
        local e = R.byName[spec.name]
        if e then
            if prevHad and not hadUpdate then clearUpdate(id) end
            e.id = id
            e.hasUpdate = hadUpdate and true or false
        end
        persist()
        PBX.log(MODULE, "updated " .. spec.name .. " (id " .. tostring(id) .. ")")
        return { id = id, changed = PBX.arr(changed) }
    end)

    return PBX.ok("updateElement", {
        job = job, status = "pending", id = prevId,
        name = spec.name, changed = PBX.arr(changed),
    })
end, MODULE)

--- deleteCustomElement -- free the element slot and forget the spec.
--- Returns { job, status, id, name }; the job's value is { freed, id, name }.
--- The registry entry is dropped inside the job, only after elements.free has
--- actually succeeded, so the registry never claims a slot is free while the
--- element is still allocated.
PBX.register("deleteCustomElement", function(req)
    local nameOk, nameErr = validateName(req.name)
    if nameErr then return PBX.err(nameErr) end

    local ent = R.byName[nameOk]
    if not ent then
        return PBX.err("no custom element named " .. nameOk, { name = nameOk })
    end

    local id = ent.id

    local job = PBX.defer(function()
        local freed = false
        if id ~= nil and elements.exists(id) then
            -- elements.free(id) also asserts a mutable-tools event
            -- (LuaElements.cpp:719) and refuses DEFAULT_* identifiers.
            elements.free(id)
            freed = true
        end
        R.byName[nameOk] = nil
        persist()
        PBX.log(MODULE, "deleted " .. nameOk .. " (id " .. tostring(id) ..
                        ", freed=" .. tostring(freed) .. ")")
        return { freed = freed, id = id, name = nameOk }
    end)

    return PBX.ok("deleteCustomElement", {
        job = job, status = "pending", id = id, name = nameOk,
    })
end, MODULE)

-- ---------------------------------------------------------------------------
-- Startup: recreate persisted elements
--
-- One job per spec, each body wrapped in PBX.guard, so a single corrupt or
-- unsatisfiable spec cannot stop the rest from coming back.  The jobs run from
-- event.TICK, which is a mutable-tools event and is also late enough that
-- 20_behaviors.lua has published its kinds.
-- ---------------------------------------------------------------------------

local function scheduleRecreate(spec)
    PBX.defer(function()
        local ok = PBX.guard(MODULE, function()
            local ent = R.byName[spec.name]
            if not ent then return end
            local id, hadUpdate = applySpec(spec, nil)
            ent.id = id
            ent.hasUpdate = hadUpdate and true or false
            PBX.log(MODULE, "recreated " .. spec.group .. "_PT_" .. spec.name ..
                            " as id " .. tostring(id))
        end)
        if not ok then
            -- Drop the entry: a phantom would consume one of the 24 slots and
            -- block a later define of the same name.  PBX.guard has already
            -- logged the reason.
            R.byName[spec.name] = nil
            PBX.warn(MODULE, "dropped unrecreatable element " .. tostring(spec.name))
        end
        return { name = spec.name, ok = ok }
    end)
end

-- Queue every entry in `list` (a plain array of raw spec tables, e.g. straight out of
-- PBX.load(PERSIST) or the source-controlled seed) whose name is not already claimed in
-- R.byName. Returns (queued, skipped). `label` is only for the warn-log text below.
-- Shared by both boot-time sources so a hand-edited persistence file and the
-- source-controlled seed are held to the identical validation bar.
local function queueSpecList(list, label)
    local queued, skipped = 0, 0
    if type(list) ~= "table" then return 0, 0 end
    for i = 1, #list do
        local raw = list[i]
        -- Re-validate on load: the source is plain data (JSON on disk, or a Lua literal
        -- another module could edit), PBX.load does no schema checking, and a bad entry
        -- must not be able to take the whole registry down. Behaviour kinds are not
        -- resolvable this early, hence lenientBehavior.
        local ok, spec = pcall(function()
            if type(raw) ~= "table" then error("not a table", 0) end
            local s, _, err = validateSpec(raw, nil, true)
            if err then error(err, 0) end
            return s
        end)
        if not ok then
            skipped = skipped + 1
            PBX.warn(MODULE, "skipped " .. label .. " element #" .. i .. ": " .. tostring(spec))
        elseif R.count() >= PBX.MAX_CUSTOM_ELEMENTS then
            skipped = skipped + 1
            PBX.warn(MODULE, "skipped " .. label .. " element " .. tostring(spec.name) ..
                             ": over MAX_CUSTOM_ELEMENTS")
        elseif R.byName[spec.name] then
            skipped = skipped + 1
            -- Not a warning: the common case here is the seed pass finding a name the
            -- persisted snapshot (a dev machine's own live history) already supplied --
            -- that machine's own copy wins on purpose, see queueSeedMaterials below.
        else
            R.byName[spec.name] = { id = nil, spec = spec, hasUpdate = false }
            scheduleRecreate(spec)
            queued = queued + 1
        end
    end
    return queued, skipped
end

do
    local restored, skipped = queueSpecList(PBX.load(PERSIST), "persisted")

    -- SOURCE-CONTROLLED BASELINE (2026-09-0x, @multiplayer): pbx-custom-elements.json is a
    -- gitignored snapshot of ONE machine's own dev-tooling history (scripts/define_materials.py
    -- talking to a long-running process) -- a fresh checkout/download has never had that
    -- tooling run against it and so has none of it, which is exactly the bug that shipped in
    -- the v1.17.0 public zip (it had zero of these 64 elements; see knowledge/rpg-hub.md,
    -- 2026-09-0x @multiplayer entry, and REALISM_RUNBOOK.md for the pre-existing half of this
    -- gap). bridge_src/07_materials_seed.lua is checked into source control and sets
    -- _G.PBX_MATERIALS_SEED to the same 64 specs, generated from that snapshot by
    -- scripts/gen_materials_seed.py -- so every fresh boot, on ANY machine, ends up with the
    -- identical baseline by construction, with zero dev tooling required. A name already
    -- present (from the persisted snapshot above, i.e. a dev machine with its own live edits)
    -- always wins over the seed -- queueSpecList's R.byName[spec.name] check gives whichever
    -- list is processed first priority, and persisted is processed first.
    local seedQueued, seedSkipped = queueSpecList(_G.PBX_MATERIALS_SEED, "seed")
    restored, skipped = restored + seedQueued, skipped + seedSkipped

    PBX.log(MODULE, "registry " .. R.VERSION .. " loaded; queued " .. restored ..
                    " element(s) (persisted+seed), skipped " .. skipped)
end

]=]
    local __chunk, __err = loadstring(__src, '10_registry.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 10_registry.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 10_registry.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/20_behaviors.lua ====
do
    local __src = [=[
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
    for j = 0, 511 do
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

]=]
    local __chunk, __err = loadstring(__src, '20_behaviors.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 20_behaviors.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 20_behaviors.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/21_extra_kinds.lua ====
do
    local __src = [[
-- ===========================================================================
-- 21_extra_kinds.lua -- boot-time loader for the extra behaviour kinds
-- (absorber, turbine, teg, photovoltaic, piezo, pcm, reactive) that
-- scripts/lua/{power,material,chem}_kinds.lua define on top of 20_behaviors.lua's
-- eight built-ins (conductor, creature, decayer, emitter, glower, grower, inert,
-- pheromone).
--
-- REDUNDANT-BUT-HARMLESS as of 2026-09-01 (@behaviors): 20_behaviors.lua now
-- implements these same seven kinds natively (ported from the same source
-- these three scripts/lua/*_kinds.lua files came from -- content verified
-- byte-identical against a captured copy at knowledge/_newplayer_audit/
-- extracted_v3/scripts/lua/{chem,material,power}_kinds.lua). Root cause this
-- module could not fix by itself: it depends on files OUTSIDE bridge_src/
-- (scripts/lua/) being present at a guessed relative path at runtime, and on
-- some human/agent remembering to re-run build_autorun.py so a build
-- containing this loader actually reaches the deployed autorun.lua -- it did
-- not, on the copy this was verified against tonight (D:/The-Powder-Toy/
-- build/autorun.lua had no "21_extra_kinds" marker at all until this same
-- pass regenerated it), which is why the 16 elements using these kinds were
-- still dropping on a fresh install despite this file existing in source.
-- Kept rather than deleted: if scripts/lua/*_kinds.lua is ever edited
-- directly (e.g. by a future materials-tooling change) without the
-- equivalent edit landing in 20_behaviors.lua, this loader's registrations
-- simply overwrite 20_behaviors.lua's (last loaded wins, both assign into
-- the same PBX.state.behaviors.kinds table, plain assignment, no
-- registration guard) -- defense in depth, not the primary path anymore.
-- 20_behaviors.lua is now the authoritative, self-contained implementation:
-- it ships inside bridge_src/ itself and needs no external file to exist on
-- disk at runtime, which is the fragility this loader's own file-search-path
-- design (SEARCH_PATHS below) could not remove.
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

]]
    local __chunk, __err = loadstring(__src, '21_extra_kinds.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 21_extra_kinds.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 21_extra_kinds.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/30_colony.lua ====
do
    local __src = [=[
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

]=]
    local __chunk, __err = loadstring(__src, '30_colony.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 30_colony.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 30_colony.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/40_worker.lua ====
do
    local __src = [=[
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

]=]
    local __chunk, __err = loadstring(__src, '40_worker.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 40_worker.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 40_worker.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/50_tasks.lua ====
do
    local __src = [=[
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

]=]
    local __chunk, __err = loadstring(__src, '50_tasks.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 50_tasks.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 50_tasks.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/60_diag.lua ====
do
    local __src = [=[
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

]=]
    local __chunk, __err = loadstring(__src, '60_diag.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 60_diag.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 60_diag.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/70_people.lua ====
do
    local __src = [[
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

]]
    local __chunk, __err = loadstring(__src, '70_people.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 70_people.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 70_people.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/85_antimatter_lab.lua ====
do
    local __src = [[
-- ===========================================================================
-- Antimatter physics showcase, built from the Veritasium video the owner asked to
-- have translated into the game ("What happens if you drop 0.125 grams of
-- antimatter?"). Four bays laid out in a 2x2 grid, each one a real, running
-- demonstration of a chapter from that video using the actual sim mechanics
-- added for it this session (AMTR.cpp, MGNT.cpp) plus the PROT+TUNG->AMTR
-- production path that already existed in PROT.cpp.
--
-- Not an MCP tool: the MCP bridge is currently broken end to end (every
-- dispatch branch missing, confirmed via mcp__powder-toy__powder_status), and
-- The owner's standing rule is no synthetic mouse/keyboard input into his game
-- session regardless. This is a plain Lua function the owner runs himself from
-- TPT's in-game console (F2), same as any other bridge-exposed command.
-- ===========================================================================
do
local PBX = _G.PBX
if not PBX then error("85_antimatter_lab.lua: PBX foundation missing (00_util.lua must load first)") end

local partCreate   = sim.partCreate
local partProperty = sim.partProperty
local partKill     = sim.partKill
local pmapAt       = sim.pmap
local photonsAt    = sim.photons

local function clearRect(x0, y0, x1, y1)
    for y = y0, y1 do
        for x = x0, x1 do
            local pi = pmapAt(x, y)
            if pi then partKill(pi) end
            local ph = photonsAt(x, y)
            if ph then partKill(ph) end
        end
    end
end

local function fillRect(x0, y0, x1, y1, elemId)
    for y = y0, y1 do
        for x = x0, x1 do
            partCreate(-1, x, y, elemId)
        end
    end
end

-- Pre-charges a magnet so it's a live Penning-trap wall from tick one instead
-- of slowly warming up through MGNT's own random charge/discharge cycle --
-- see the tmp3 exemption this session added to AMTR.cpp.
local function chargeMagnet(id)
    if not id or id < 0 then return end
    partProperty(id, "tmp", 30)
    partProperty(id, "tmp3", 1)
    partProperty(id, "life", 20)
end

local function magnetRing(cx, cy, radius, count)
    for k = 0, count - 1 do
        local a = (2 * math.pi * k) / count
        local x = math.floor(cx + radius * math.cos(a) + 0.5)
        local y = math.floor(cy + radius * math.sin(a) + 0.5)
        chargeMagnet(partCreate(-1, x, y, elem.DEFAULT_PT_MGNT))
    end
end

local function magnetRails(xLeft, xRight, y0, y1)
    for y = y0, y1 do
        chargeMagnet(partCreate(-1, xLeft, y, elem.DEFAULT_PT_MGNT))
        chargeMagnet(partCreate(-1, xRight, y, elem.DEFAULT_PT_MGNT))
    end
end

function buildAntimatterLab()
    -- BAY 1 (top-left): The Antimatter Factory -- protons into a tungsten
    -- target (PROT.cpp: PROT + TUNG -> AMTR once accumulated collision energy
    -- passes 500000). Two real beams are fired at each other through the
    -- target so you can watch actual proton-proton collision physics run,
    -- but CERN's real antiproton yield is on the order of 1 in 10^5-10^6
    -- protons fired -- a literal beam here would need to run far longer than
    -- anyone's going to wait on a demo, so one seed proton is pre-loaded with
    -- the energy a genuinely successful collision would have produced,
    -- guaranteeing you see the actual yield instead of waiting on statistics.
    clearRect(5, 5, 300, 185)
    fillRect(145, 95, 150, 105, elem.DEFAULT_PT_TUNG)
    local beamL = partCreate(-1, 20, 100, elem.DEFAULT_PT_PROT)
    if beamL and beamL >= 0 then partProperty(beamL, "vx", 20); partProperty(beamL, "vy", 0) end
    local beamR = partCreate(-1, 280, 100, elem.DEFAULT_PT_PROT)
    if beamR and beamR >= 0 then partProperty(beamR, "vx", -20); partProperty(beamR, "vy", 0) end
    local seed = partCreate(-1, 147, 99, elem.DEFAULT_PT_PROT)
    if seed and seed >= 0 then partProperty(seed, "tmp", 600000) end
    -- No trap here on purpose: the antiproton this produces annihilates
    -- against its own tungsten target within a tick or two, which is exactly
    -- CERN's real problem -- freshly made antimatter dies immediately unless
    -- something catches it. That something is bay 2.

    -- BAY 2 (top-right): The Portable Antimatter Trap / how do you store it --
    -- a ring of pre-charged magnets (MGNT.cpp) forming a real Penning-trap
    -- style cage. AMTR is exempted from annihilating against a live magnet
    -- field (AMTR.cpp), so this particle should sit here indefinitely instead
    -- of detonating the instant it's placed.
    clearRect(312, 5, 602, 185)
    magnetRing(457, 95, 40, 14)
    partCreate(-1, 457, 95, elem.DEFAULT_PT_AMTR)

    -- BAY 3 (bottom-left): particle annihilation, the video's core demo --
    -- antimatter dropped onto ordinary matter releases its full rest mass as
    -- heat, light and a shockwave (E=mc^2, ~100% efficient) instead of just
    -- quietly deleting what it touches.
    clearRect(5, 197, 300, 372)
    fillRect(50, 340, 250, 360, elem.DEFAULT_PT_BMTL)
    partCreate(-1, 150, 300, elem.DEFAULT_PT_AMTR)

    -- BAY 4 (bottom-right): does antimatter fall up or down? -- an open
    -- question until CERN's 2023 ALPHA-g result. A magnetically shielded drop
    -- tube keeps the particle off the rails as it falls, so what you're
    -- watching is gravity alone (Gravity = 0.10f in AMTR.cpp) pulling it down
    -- onto the landing plate below, where it leaves the field and annihilates.
    clearRect(312, 197, 602, 372)
    magnetRails(440, 474, 210, 340)
    fillRect(430, 345, 485, 360, elem.DEFAULT_PT_BMTL)
    partCreate(-1, 457, 220, elem.DEFAULT_PT_AMTR)

    PBX.log("antimatter_lab", "built 4-bay antimatter demo: factory, trap, annihilation, gravity drop")
    if tpt and tpt.print then
        pcall(tpt.print, "Antimatter lab built -- factory (top-left), trap (top-right), annihilation (bottom-left), gravity drop (bottom-right)")
    end
end

_G.buildAntimatterLab = buildAntimatterLab
PBX.log("antimatter_lab", "85_antimatter_lab loaded -- run buildAntimatterLab() from the console to build the demo")
end

]]
    local __chunk, __err = loadstring(__src, '85_antimatter_lab.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 85_antimatter_lab.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 85_antimatter_lab.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/86_rpg_loader.lua ====
do
    local __src = [[
-- Loads the standalone RPG demo (scripts/lua/rpg.lua, not part of this
-- bridge bundle) into the running game and starts it, so the owner can hand
-- control straight to a friend without typing anything in the console
-- himself. Load-only, no auto-start -- see the bottom of this file for why
-- start is a separate, explicit step.
-- The owner asked to go back to plain sandbox and not work on the RPG right now
-- -- flip this to true (and rebuild) to bring the loader back; false means
-- this whole module does nothing, since even just loading rpg.lua has
-- side effects on the plain sandbox (hides the HUD/menus, registers event
-- handlers) that shouldn't happen when nobody asked for the RPG.
local RPG_ENABLED = true
if RPG_ENABLED then
do
local PBX = _G.PBX
if not PBX then error("86_rpg_loader.lua: PBX foundation missing") end

-- io.open + loadstring, not dofile -- dofile is untested in this fork's
-- sandbox, whereas this exact pattern is already proven working (see
-- bridge_base.lua's executeLua action).
-- Absolute dev path first: something on the owner's machine keeps recreating a
-- stale scripts/lua/rpg.lua next to build/PowderToyRPG.exe (same old file,
-- same old timestamp -- not a fresh write from anything in this session's
-- own workflow, cause not identified), and a relative-path-first order let
-- that stale copy silently shadow every real edit to the dev source for an
-- entire evening even after being deleted once. Checking the absolute path
-- first makes that shadow file inert on the owner's machine regardless of
-- whether it comes back. Relative path second, for a portable copy handed
-- to someone else -- their machine has no D:/powder-toy at all, so this
-- lookup just fails over to their bundled copy exactly as before.
local RPG_PATHS = {
  "../scripts/lua/rpg.lua",
  "scripts/lua/rpg.lua",
  "D:/The-Powder-Toy/scripts/lua/rpg.lua",
  "D:/powder-toy/scripts/lua/rpg.lua",
}
local ok, err = pcall(function()
    local f
    for _, path in ipairs(RPG_PATHS) do
        f = io.open(path, "r")
        if f then break end
    end
    if not f then error("could not open rpg.lua (tried: " .. table.concat(RPG_PATHS, ", ") .. ")") end
    local code = f:read("*a")
    f:close()
    local fn, loadErr = loadstring(code)
    if not fn then error(loadErr) end
    return fn()
end)
if not ok then
    PBX.log("rpg_loader", "failed to load rpg.lua: " .. tostring(err))
else
    PBX.log("rpg_loader", "rpg.lua loaded -- call startRPG() from the console, or it's already been started for tonight below")
    _G.startRPG = function(seed)
        local R = PBX.state.rpg
        if not R then return "rpg.lua didn't load" end
        return R.start(seed)
    end
    _G.stopRPG = function()
        local R = PBX.state.rpg
        if not R then return "rpg.lua didn't load" end
        return R.stop()
    end
    -- Plain, always-available manual unpause -- rpg.lua's own start-up path
    -- already unpauses once world generation finishes (a deferred tick, not
    -- immediate), but if that ever gets stuck (generation errors, or just
    -- runs long), there was no obvious way to unstick it. This works no
    -- matter what state the RPG script itself is in.
    _G.unpauseSim = function() sim.paused(false); return "unpaused" end
    -- Belt-and-suspenders watchdog: force an unpause every tick for the
    -- first 5 seconds after start, in case rpg.lua's own generation-done
    -- unpause never fires for some reason. Self-removes after that window
    -- so it doesn't fight a deliberate pause later in the play session.
    local watchdogTicks = 300
    local watchdogHandler
    watchdogHandler = function()
        watchdogTicks = watchdogTicks - 1
        pcall(sim.paused, false)
        if watchdogTicks <= 0 and event.unregister then
            pcall(event.unregister, event.TICK, watchdogHandler)
        end
    end
    if event and event.register and event.TICK then
        event.register(event.TICK, watchdogHandler)
    end
    _G.startRPG()
end
end
end

]]
    local __chunk, __err = loadstring(__src, '86_rpg_loader.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 86_rpg_loader.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 86_rpg_loader.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/90_realism_boot.lua ====
do
    local __src = [[
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

]]
    local __chunk, __err = loadstring(__src, '90_realism_boot.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 90_realism_boot.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 90_realism_boot.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- ==== bridge_src/95_menusort.lua ====
do
    local __src = [[
-- ===========================================================================
-- 95_menusort.lua -- assigns Tool::MenuSort bands to elements so the native
-- subcategory-chip menu (GameView.cpp/GameModel.cpp, SubCategory.h) has
-- something to filter. Runs once per boot, after 10_registry.lua has
-- recreated any persisted elements, using the same "scan 0-511 for a custom
-- element's live id by name" pattern chem_kinds.lua already uses -- this file
-- has no dependency on the HTTP bridge (LuaSocket::Process), only on the
-- elements table, so it works even while that code path is stubbed out.
--
-- Bands below MUST match src/gui/game/SubCategory.h exactly (same numeric
-- ranges per section) or the native filter will show nothing for a chip.
--
-- One unified numeric band per theme per section, 10/20/30/... -- stock and
-- custom tables both feed the SAME band number when they're the same theme
-- (e.g. stock METL/TUNG and custom CU both land on ELEC band 10,
-- "Conductors & Insulators"). There used to be a second range (100+)
-- reserved purely so custom elements couldn't collide with stock ones, but
-- collision was never actually possible -- MenuSort is just an int per
-- tool -- so all that range bought was a near-duplicate chip next to every
-- stock chip that had a custom counterpart ("Inert & Cold" beside "Noble &
-- Inert", "Fissile Fuel" beside "Fuel", etc). Gone now.
--
-- An element only shows under the section named in its live MenuSection
-- property, which is a SEPARATE property from Type/MenuSort and is not set
-- automatically -- a handful of elements built directly in bridge_src (not
-- through the materials-catalog pipeline) never got one set at creation and
-- were invisible in every chip as a result. applyBand() below force-sets
-- MenuSection for every custom group (2nd item of its `entry` pair), so this
-- file is now the single source of truth for where each custom element
-- lives, not just how it's subdivided once there.
-- ===========================================================================

local function elemId(name)
	local id = elem["DEFAULT_PT_" .. name]
	if id then return id end
	for j = 0, 511 do
		local ok, n = pcall(elem.property, j, "Name")
		if ok and n == name then return j end
	end
	return nil
end

-- `section`, when given, force-sets the native MenuSection too (not just
-- MenuSort). Needed for elements created outside the materials-catalog
-- pipeline (e.g. AM24/CF25/ANT/CRPS/CRYE, built directly in bridge_src) --
-- those never got a MenuSection at creation, so without this they're a live,
-- placeable particle that's simply unreachable from every menu chip.
local function applyBand(names, sort, section)
	local applied, missing = 0, 0
	for _, name in ipairs(names) do
		local id = elemId(name)
		if id then
			if section then pcall(elements.property, id, "MenuSection", section) end
			local ok = pcall(elements.property, id, "MenuSort", sort)
			if ok then applied = applied + 1 else missing = missing + 1 end
		else
			missing = missing + 1
		end
	end
	return applied, missing
end

-- ===========================================================================
-- Custom elements, grouped by native section. Each band number matches the
-- stock table below for the same theme (see SubCategory.h).
-- ===========================================================================

local SOLIDS = {
	[10] = { "NICK", "ZINC", "TIN", "SLVR", "CHRM", "COBT", "CNT", "GRPN", "GAN", "INP",
	         "GERM", "S316", "WC", "INC7", "TI64", "AL61", "CIRN", "RBAR", "BRSS", "BRNZ",
	         "FSLG" },                                                                        -- Metals
	[20] = { "NA", "MG", "MGRB", "WP", "CS", "K", "CA" },                                     -- Alkali Metals
	[30] = { "CACL", "CAF2", "LIF", "KCL", "NA2C", "MGO", "SIC", "BORO", "FSIL",
	         "CTIL", "ZRCA", "GRNT", "BSLT", "FBRK", "GYPS", "SDST", "ASPH", "RCNC" },        -- Minerals, Ceramics & Glass
	-- (Nuclear-specific materials -- U235/UO2/ZIRC/B4C/CD/HF/BPE/CO60/AM24/CF25/RA26/THOR/BE/
	-- LEAD/DU/STEL/CNCR -- live exclusively under the NUCLEAR group below, same convention
	-- stock TPT uses: fissile/radioactive/reactor-specific material gets its own SC_NUCLEAR
	-- tab regardless of TYPE_SOLID. STEL is "SA-508 reactor pressure-vessel steel", CNCR is
	-- "Heavy shielding concrete" -- generic-sounding names, purpose-built nuclear items. RCNC
	-- ("Reinforced concrete", no reactor-specific purpose) is the genuinely generic one and
	-- stays here. ALUM/GRPH/RUBR used to be custom Lua elements listed in this file too, but
	-- got replaced by native compiled versions ported from the cracker1000 mod -- see
	-- STOCK_SOLIDS below; a custom and a native element can't share one Name.)
	[50] = { "BONE", "CHIT", "LIGN", "KERA", "BEES", "TLLW", "ADCM", "MSCN", "CROX" },        -- Organic & Life
	[80] = { "NITS", "NITI" },                                                                -- Novel Mechanics
	[90] = { "OAK", "PINE", "BAMB", "KEVL", "CFIB", "GFIB", "PUFM", "MWOL", "PTFE", "HDPE",
	         "PVC", "NYLN", "SILR", "EPDM", "PCAR", "CORK", "C60", "AERO" },                  -- Timber & Polymers
}

local LIQUID = {
	[20] = { "ETOH", "KERO", "GLYC", "BDSL", "H2O2", "NTGL", "HYPA", "HYPB" },      -- Fuels, Oils & Solvents
	[30] = { "AQRG", "AQAU", "CUSO" },                                             -- Acids & Corrosives
	[40] = { "LH2", "LHE", "LNE", "LAR", "LKR", "LXE", "LCH4", "LF2" },            -- Cryogenic
	[60] = { "NAK", "NAS", "LBE", "FLBE" },                                        -- Reactor Coolants
}

local GAS = {
	[10] = { "CH4", "NH3", "PROP" },              -- Combustible & Fuel
	[20] = { "O3", "CL2", "F2", "TRIT" },         -- Toxic & Reactive
	[30] = { "ARGN", "NE", "KR", "XE", "HE3" },   -- Noble & Inert
}

local POWDERS = {
	[30] = { "CAC2", "CAO", "SOOT" },                            -- Explosive & Reactive
	[40] = { "LMST", "MRBL", "SUGR", "STAR", "B10", "CELL" },    -- Organic Dust
}

-- SC_NUCLEAR -- also force-sets native MenuSection (see applyBand below),
-- since AM24/CF25 in particular were created with no MenuSection at all and
-- were previously unreachable from any menu chip.
local NUCLEAR = {
	[10] = { "U235", "UO2", "DU" },                                              -- Fuel
	[50] = { "B4C", "CD", "HF", "BPE", "ZIRC", "BE", "LEAD", "STEL", "CNCR" }, -- Control & Shielding
	[60] = { "CO60", "AM24", "CF25", "RA26", "THOR" },                           -- Sources
}

local POWERED = {
	[30] = { "TRBN", "TEG", "SIPV", "GAAS", "CDTE", "PZT" },  -- Generators
	[40] = { "PCMP", "PCMS", "LEDL" },                        -- Sensors & Converters
}

local ELEC = {
	[10] = { "CU" },     -- Conductors & Insulators
	[50] = { "NBTI" },   -- Superconductors & Electronics
}

-- SC_LIFE -- legacy colony-system pieces, not chemistry, but still elements,
-- so still get a place in the ladder per "sort everything". ANT/CRPS/CRYE
-- were created directly in 30_colony.lua/40_worker.lua with no MenuSection
-- at all, so they were unreachable from any menu chip until this file
-- started force-setting MenuSection alongside MenuSort (see applyBand).
local LIFE = {
	[20] = { "ANT", "CRPS", "CRYE" },   -- Colony System
}

-- ===========================================================================
-- Stock/base-game elements, grouped by what they actually do (pulled from
-- each element's real Description in src/simulation/elements). Same band
-- numbers as the custom tables above for shared themes.
-- ===========================================================================

-- Ported-from-mod elements are tagged with a trailing "-- mod" comment on
-- their own so a future audit can tell them apart from base-game stock.
local STOCK_SOLIDS = {
	[10] = { "BMTL", "GOLD", "IRON", "PTNM", "TTAN", "ALUM" },                  -- Metals (ALUM -- mod)
	[20] = { "SODM" },                                                         -- Alkali Metals (mod)
	[30] = { "GLAS", "QRTZ", "BRCK", "CRMC", "ROCK", "COAL", "GRPH" },         -- Minerals, Ceramics & Glass (GRPH -- mod)
	[40] = { "ICE", "NICE", "RIME", "DRIC" },                                  -- Ice & Cold
	[50] = { "PLNT", "VINE", "WOOD", "WAX", "SPNG" },                          -- Organic & Life
	[60] = { "SHLD", "SHD2", "SHD3", "SHD4", "FILT", "SPWN", "SPWN2", "HEAC", "RSSS",
	         "DMRN", "STRC" },                                                -- Structural & Signal (DMRN/STRC -- mod)
	[70] = { "GOO", "BIZS", "VRSS", "PSTS" },                                  -- Reactive & Bizarre
}

local STOCK_LIQUID = {
	[10] = { "WATR", "DSTW", "SLTW", "FRZW", "BUBW" },                         -- Water & Variants
	[20] = { "OIL", "DESL", "MWAX", "FUEL" },                                  -- Fuels, Oils & Solvents (FUEL -- mod)
	[30] = { "ACID", "BASE", "BIZR", "RSST" },                                 -- Acids & Corrosives
	[40] = { "LN2", "LOXY" },                                                  -- Cryogenic
	[50] = { "GEL", "GLOW", "PSTE", "RFGL", "SOAP", "VIRS", "LAVA", "MERC",
	         "CLRC", "RUBR" },                                                -- Special & Utility (CLRC/RUBR -- mod)
	[60] = { "CLNT" },                                                        -- Reactor Coolants (mod)
}

local STOCK_GAS = {
	[10] = { "GAS", "HYGN", "OXYG", "ACTY" },                                  -- Combustible & Fuel (ACTY -- mod)
	[20] = { "CAUS", "VRSG", "BIZG", "RFRG", "Cl" },                           -- Toxic & Reactive (Cl -- mod)
	[30] = { "NBLE", "CO2", "NTRG" },                                          -- Noble & Inert (NTRG -- mod)
	[40] = { "FOG", "SMKE", "WTRV", "PLSM", "BOYL", "CLUD", "DFOM", "QGP" },   -- Vapors & Effects (CLUD/DFOM/QGP -- mod)
}

local STOCK_POWDERS = {
	[10] = { "SAND", "STNE", "PQRT", "SLCN", "SALT", "CLST", "CNCT", "CMNT" },  -- Minerals & Sand (CMNT -- mod)
	[20] = { "BCOL", "BGLA", "BREL", "BRMT", "SNOW" },                         -- Broken & Debris
	[30] = { "PHOS" },                                                        -- Explosive & Reactive (mod)
	[40] = { "SAWD", "SEED", "YEST", "DYST" },                                 -- Organic Dust
	[50] = { "ANAR", "GRAV", "DUST", "FRZZ" },                                 -- Special Effects
}

local STOCK_NUCLEAR = {
	[10] = { "URAN", "PLUT", "DEUT" },                                         -- Fuel
	[20] = { "POLO", "ISOZ", "ISZS", "RADN" },                                 -- Radioactive Decay (RADN -- mod)
	[30] = { "NEUT", "PROT", "ELEC", "PHOT", "UV" },                           -- Particles (UV -- mod)
	[40] = { "AMTR", "EXOT", "GRVT", "SING", "VIBR", "WARP", "BVBR" },         -- Exotic Physics
	[60] = { "PRMT" },                                                        -- Sources (mod)
}

local STOCK_POWERED = {
	[10] = { "PPIP", "PUMP", "GPMP", "STOR", "PVOD" },                         -- Pipes & Storage
	[20] = { "DLAY", "HSWC", "LCRY", "PBCN", "PCLN", "DIGS", "LED", "PCON",
	         "PINV", "PPTI", "PPTO", "TIMC" },                                -- Switches & Signals (mod: DIGS/LED/PCON/PINV/PPTI/PPTO/TIMC)
	[40] = { "AMBE" },                                                        -- Sensors & Converters (mod)
}

local STOCK_ELEC = {
	[10] = { "METL", "TUNG", "INST", "INWR", "INSL", "COPR", "CWIR" },        -- Conductors & Insulators (COPR/CWIR -- mod)
	[20] = { "PSCN", "NSCN", "NTCT", "PTCT", "SWCH", "WWLD", "FNTC", "FPTC" }, -- Silicon & Logic (FNTC/FPTC -- mod)
	[30] = { "SPRK", "BTRY", "WIFI", "TESC", "ETRD", "EMP", "LBTR" },         -- Signal & Power (LBTR -- mod)
	[40] = { "ARAY", "BRAY", "CRAY", "DRAY" },                                -- Rays & Special
}

local STOCK_LIFE = {
	[10] = { "LIFE" },                                                         -- Cellular Automata
}

local STOCK_EXPLOSIVE = {
	[10] = { "BOMB", "DEST", "TNT", "NITR", "C-4", "CEXP" },                  -- Primary Explosives (CEXP -- mod)
	[20] = { "FUSE", "FSEP", "IGNC", "GUN", "THRM" },                         -- Slow Burn & Fuses
	[30] = { "FIRE", "EMBR", "CFLM", "C-5", "LITH", "RBDM", "LRBD",
	         "ALMP", "BFLM", "NAPM" },                                       -- Fire & Heat (ALMP/BFLM/NAPM -- mod)
	[40] = { "LIGH", "THDR", "FIRW", "FWRK" },                                -- Electric & Light
}

local STOCK_FORCE = {
	[10] = { "PSTN", "PIPE", "FRME", "PROJ", "WHEL" },                         -- Movers (PROJ/WHEL -- mod)
	[20] = { "ACEL", "DCEL", "FRAY", "RPEL", "EMGT" },                         -- Fields (EMGT -- mod)
	[30] = { "DMG", "GBMB", "MISL" },                                          -- Destructive (MISL -- mod)
	[40] = { "THMO", "ECLR", "TURB" },                                        -- Mechanisms & Signal (mod)
}

local STOCK_SENSOR = {
	[10] = { "DTEC", "LDTC" },                                                 -- Detectors
	[20] = { "PSNS", "TSNS", "VSNS", "LSNS", "CSNS", "TMPS" },                 -- Property Sensors (CSNS/TMPS -- mod)
	[30] = { "INVS" },                                                        -- Optical
}

local STOCK_SPECIAL = {
	[10] = { "CLNE", "BCLN", "CONV" },                                         -- Duplication & Conversion
	[20] = { "PRTI", "PRTO", "VOID", "VACU", "VENT", "BHOL", "WHOL" },        -- Portals & Voids
	[30] = { "STKM", "STK2", "FIGH", "TRON", "BEE", "PET" },                  -- Stickmen & AI (BEE/PET -- mod)
	[40] = { "DMND", "LOLZ", "LOVE", "MORT", "NONE", "EQVE",
	         "BALL", "ELEX", "SUN", "WALL" },                                -- Novelty & Meta (BALL/ELEX/SUN/WALL -- mod)
}

-- 10_registry.lua restores persisted elements through PBX.defer, drained a
-- few per tick (see 00_util.lua's job queue) -- they don't all exist yet at
-- module-load time. Wait a few seconds of ticks before assigning MenuSort so
-- everything persisted has actually been recreated first, then run once and
-- disable this hook (self-removal isn't exposed, so just guard with a flag).
-- SC_* numeric ids, from src/simulation/MenuSection.h (not exposed to Lua).
local SC_ELEC, SC_POWERED, SC_GAS, SC_LIQUID = 1, 2, 6, 7
local SC_POWDERS, SC_SOLIDS, SC_NUCLEAR, SC_LIFE = 8, 9, 10, 12

local applied = false
PBX.onTick("menusort_apply", function()
	if applied then return end
	applied = true
	local totalApplied, totalMissing = 0, 0
	for _, entry in ipairs({
		{ SOLIDS, SC_SOLIDS }, { LIQUID, SC_LIQUID }, { GAS, SC_GAS },
		{ POWDERS, SC_POWDERS }, { NUCLEAR, SC_NUCLEAR }, { POWERED, SC_POWERED },
		{ ELEC, SC_ELEC }, { LIFE, SC_LIFE },
		{ STOCK_SOLIDS }, { STOCK_LIQUID }, { STOCK_GAS }, { STOCK_POWDERS },
		{ STOCK_NUCLEAR }, { STOCK_POWERED }, { STOCK_ELEC }, { STOCK_LIFE },
		{ STOCK_EXPLOSIVE }, { STOCK_FORCE }, { STOCK_SENSOR }, { STOCK_SPECIAL },
	}) do
		local group, section = entry[1], entry[2]
		for sort, names in pairs(group) do
			local a, m = applyBand(names, sort, section)
			totalApplied = totalApplied + a
			totalMissing = totalMissing + m
		end
	end
	PBX.log("menusort", string.format("applied MenuSort to %d elements (%d not currently live)", totalApplied, totalMissing))
end, 180)

]]
    local __chunk, __err = loadstring(__src, '95_menusort.lua')
    if __chunk then
        local __ok, __e = pcall(__chunk)
        if not __ok then
            local f = io.open('autorun-runtime.log', 'a')
            if f then f:write('[loader] RUNTIME ERROR in 95_menusort.lua: ' .. tostring(__e) .. '\n'); f:close() end
        end
    else
        local f = io.open('autorun-runtime.log', 'a')
        if f then f:write('[loader] SYNTAX ERROR in 95_menusort.lua: ' .. tostring(__err) .. '\n'); f:close() end
    end
end

-- Powder Bridge HTTP API — listen-first, no heavy startup, no json.stringify
-- json.stringify LuaToJsonValue crashes on nested tables (relative stack index).
-- sim.step inside LuaSocket::Process deadlocks (g_pendingMx). Defer via event.TICK.

local function log(msg)
    print(msg)
    local f = io.open("autorun-runtime.log", "a")
    if f then f:write(tostring(msg) .. "\n"); f:close() end
end

do
    local f = io.open("autorun-runtime.log", "a")
    if f then f:write("autorun entered\n"); f:close() end
end
local bridgeToken
do
    local f = io.open("powder-bridge.token", "r")
    if f then
        bridgeToken = f:read("*l")
        f:close()
    end
end

local function jesc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
    return '"' .. s .. '"'
end

local function jnum(n)
    if n == nil then return "null" end
    return tostring(n)
end

local function jok(action, extra)
    extra = extra or ""
    return '{"ok":true,"action":' .. jesc(action) .. extra .. "}"
end

local function jerr(msg, extra)
    extra = extra or ""
    return '{"ok":false,"error":' .. jesc(msg) .. extra .. "}"
end

local function resolveElem(name)
    if name == nil then return nil end
    if tonumber(name) then return tonumber(name) end
    name = string.upper(tostring(name))
    return elements[name] or elements["DEFAULT_PT_" .. name]
end
local function resolveWall(name)
    if name == nil then return nil end
    if tonumber(name) then return tonumber(name) end
    name = string.upper(tostring(name))
    return (sim.walls and (sim.walls[name] or sim.walls["DEFAULT_WL_" .. name])) or nil
end

local function resolveTool(name)
    if name == nil then return nil end
    if tonumber(name) then return tonumber(name) end
    name = string.upper(tostring(name))
    return (tools and tools.index and (tools.index[name] or tools.index["DEFAULT_TOOL_" .. name])) or nil
end
local function stampExists(name)
    if type(name) ~= "string" or name == "" then return false end
    for _, stamp in ipairs(sim.listStamps()) do
        if stamp == name then return true end
    end
    return false
end

_G.POWDER_BRIDGE_PENDING_STEPS = 0
_G.POWDER_BRIDGE_COMPLETED_STEPS = 0

-- Diagnosed 2026-09-01: LuaSocketNet.cpp's net.listen accept/serve loop
-- (Process(), called from CommandInterface::OnTick() BEFORE HandleEvent(TickEvent{}))
-- invokes this file's handleRequest via a raw lua_pcall with no eventTraits set,
-- so lsi->eventTraits == eventTraitNone for the whole HTTP request. Any C++ Lua
-- binding that unconditionally calls AssertInterfaceEvent() -- the entire `ren.*`
-- module (LuaRenderer.cpp), tpt.set_pause()/sim.paused (both get AND set --
-- LuaSimulation.cpp:138), tpt.screenshot, sim.saveStamp/loadStamp/deleteStamp/
-- listStamps, event.register/unregister, socket/http client calls -- throws
-- "this functionality is restricted to interface events" no matter what the
-- request does. TickEvent{} traits ARE eventTraitInterface (GameControllerEvents.h),
-- so a call deferred into this onTick handler is legal -- exactly the existing
-- sim.frameRender precedent below. Generalised into a request/poll queue so any
-- bridge action can defer a privileged call instead of throwing.
_G.POWDER_BRIDGE_IFACE_NEXT_ID = 0
_G.POWDER_BRIDGE_IFACE_QUEUE = {}   -- FIFO list of {id=N, fn=<loaded function>}
_G.POWDER_BRIDGE_IFACE_RESULTS = {} -- id -> {ok=bool, result=<string tostring'd>}

local function onTick()
    local pending = _G.POWDER_BRIDGE_PENDING_STEPS or 0
    if pending > 0 and sim and sim.step then
        local batch = math.min(pending, 200)
        _G.POWDER_BRIDGE_PENDING_STEPS = pending - batch
        -- sim.step() takes NO argument in TPT (always one frame); loop it.
        -- Bug found 2026-08-25: pcall(sim.step, batch) advanced 1 frame per tick
        -- while claiming `batch` frames done.
        -- sim.frameRender(n) queues exactly n engine frames (works while paused; verified 2026-08-25).
        -- sim.step() on this build requires a count argument and still advances only one frame.
        local ok, err = pcall(function() sim.frameRender(batch) end)
        if ok then
            _G.POWDER_BRIDGE_COMPLETED_STEPS = (_G.POWDER_BRIDGE_COMPLETED_STEPS or 0) + batch
        else
            _G.POWDER_BRIDGE_PENDING_STEPS = (_G.POWDER_BRIDGE_PENDING_STEPS or 0) + batch
            log("STEP_ERR " .. tostring(err))
        end
    end

    -- Run queued interface-only calls now that eventTraits includes
    -- eventTraitInterface. Capped per tick so one client can't starve the frame.
    local queue = _G.POWDER_BRIDGE_IFACE_QUEUE
    local ran = 0
    while #queue > 0 and ran < 4 do
        local job = table.remove(queue, 1)
        local jok2, jresult = pcall(job.fn)
        _G.POWDER_BRIDGE_IFACE_RESULTS[job.id] = { ok = jok2, result = jresult }
        ran = ran + 1
    end
end
if event and event.register and event.TICK then
    event.register(event.TICK, onTick)
    log("[OK] event.TICK step defer registered")
end

local function handleRequest(body)
    local ok, res = pcall(function()
        if body == nil or body == "" then
            return jerr("empty body")
        end
        local pok, req = pcall(json.parse, body)
        if not pok then
            return jerr("bad JSON", ',"detail":' .. jesc(req))
        end
        if type(req) ~= "table" then
            return jerr("json parse returned non-table")
        end
        if not bridgeToken or req.token ~= bridgeToken then
            return jerr("unauthorized")
        end
        local action = req.action or ""

        if action == "stepSim" then
            local n = tonumber(req.n) or 1
            if n < 1 then n = 1 end
            _G.POWDER_BRIDGE_PENDING_STEPS = (_G.POWDER_BRIDGE_PENDING_STEPS or 0) + n
            return jok("stepSim", ',"stepped":' .. jnum(n) .. ',"deferred":true')

        elseif action == "placeElement" then
            local elemId = resolveElem(req.element)
            if not elemId then
                return jerr("unknown element", ',"name":' .. jesc(req.element))
            end
            local x1 = tonumber(req.x1) or 0
            local y1 = tonumber(req.y1) or 0
            local x2 = tonumber(req.x2) or 50
            local y2 = tonumber(req.y2) or 50
            if sim.createBox then
                sim.createBox(x1, y1, x2, y2, elemId)
            else
                return jerr("sim.createBox missing")
            end
            return jok("placeElement", ',"placed":true,"id":' .. jnum(elemId))
        elseif action == "placeElementLine" then
            local elemId = resolveElem(req.element)
            if not elemId then return jerr("unknown element", ',"name":' .. jesc(req.element)) end
            local x1 = tonumber(req.x1) or 0
            local y1 = tonumber(req.y1) or 0
            local x2 = tonumber(req.x2) or 50
            local y2 = tonumber(req.y2) or 50
            if x1 < 0 or y1 < 0 or x2 >= sim.XRES or y2 >= sim.YRES then
                return jerr("element line outside pixel bounds")
            end
            sim.createLine(x1, y1, x2, y2, 0, 0, elemId, sim.BRUSH_CIRCLE, 0)
            return jok("placeElementLine", ',"id":' .. jnum(elemId))

        elseif action == "placeWallBox" then
            local wallId = resolveWall(req.wall)
            if wallId == nil then return jerr("unknown wall", ',"name":' .. jesc(req.wall)) end
            local x1 = tonumber(req.x1) or 0
            local y1 = tonumber(req.y1) or 0
            local x2 = tonumber(req.x2) or 50
            local y2 = tonumber(req.y2) or 50
            if x1 < 0 or y1 < 0 or x2 >= sim.XRES or y2 >= sim.YRES or x1 > x2 or y1 > y2 then
                return jerr("wall box outside pixel bounds")
            end
            sim.createWallBox(x1, y1, x2, y2, wallId)
            return jok("placeWallBox", ',"wall":' .. jnum(wallId))
        elseif action == "placeWallLine" then
            local wallId = resolveWall(req.wall)
            if wallId == nil then return jerr("unknown wall", ',"name":' .. jesc(req.wall)) end
            local x1 = tonumber(req.x1) or 0
            local y1 = tonumber(req.y1) or 0
            local x2 = tonumber(req.x2) or 50
            local y2 = tonumber(req.y2) or 50
            if x1 < 0 or y1 < 0 or x2 >= sim.XRES or y2 >= sim.YRES then
                return jerr("wall line outside pixel bounds")
            end
            sim.createWallLine(x1, y1, x2, y2, 0, 0, wallId)
            return jok("placeWallLine", ',"wall":' .. jnum(wallId))

        elseif action == "applyToolBox" then
            local toolId = resolveTool(req.tool)
            if toolId == nil then return jerr("unknown native tool", ',"name":' .. jesc(req.tool)) end
            local x1 = tonumber(req.x1) or 0
            local y1 = tonumber(req.y1) or 0
            local x2 = tonumber(req.x2) or 50
            local y2 = tonumber(req.y2) or 50
            local strength = tonumber(req.strength) or 1.0
            local brush = tonumber(req.brush) or sim.BRUSH_CIRCLE
            local rx = tonumber(req.rx) or 0
            local ry = tonumber(req.ry) or 0
            if x1 < 0 or y1 < 0 or x2 >= sim.XRES or y2 >= sim.YRES or x1 > x2 or y1 > y2 then
                return jerr("tool box outside pixel bounds")
            end
            sim.toolBox(x1, y1, x2, y2, toolId, strength, brush, rx, ry)
            return jok("applyToolBox", ',"tool":' .. jnum(toolId))

        elseif action == "placeDecoBox" then
            local x1 = tonumber(req.x1) or 0
            local y1 = tonumber(req.y1) or 0
            local x2 = tonumber(req.x2) or 50
            local y2 = tonumber(req.y2) or 50
            local r = math.max(0, math.min(255, tonumber(req.r) or 255))
            local g = math.max(0, math.min(255, tonumber(req.g) or 255))
            local b = math.max(0, math.min(255, tonumber(req.b) or 255))
            local a = math.max(0, math.min(255, tonumber(req.a) or 255))
            local tool = tonumber(req.tool) or sim.DECO_DRAW
            if tool < 0 or tool > 6 or x1 < 0 or y1 < 0 or x2 >= sim.XRES or y2 >= sim.YRES or x1 > x2 or y1 > y2 then
                return jerr("deco box outside safe bounds")
            end
            sim.decoBox(x1, y1, x2, y2, r, g, b, a, tool)
            return jok("placeDecoBox")
        elseif action == "placeDecoLine" then
            local x1 = tonumber(req.x1) or 0
            local y1 = tonumber(req.y1) or 0
            local x2 = tonumber(req.x2) or 50
            local y2 = tonumber(req.y2) or 50
            local rx = tonumber(req.rx) or 5
            local ry = tonumber(req.ry) or 5
            local r = math.max(0, math.min(255, tonumber(req.r) or 255))
            local g = math.max(0, math.min(255, tonumber(req.g) or 255))
            local b = math.max(0, math.min(255, tonumber(req.b) or 255))
            local a = math.max(0, math.min(255, tonumber(req.a) or 255))
            local tool = tonumber(req.tool) or sim.DECO_DRAW
            local brush = tonumber(req.brush) or sim.BRUSH_CIRCLE
            if tool < 0 or tool > 6 or brush < 0 or brush > 2 or rx < 0 or rx > 100 or ry < 0 or ry > 100 or x1 < 0 or y1 < 0 or x2 >= sim.XRES or y2 >= sim.YRES then
                return jerr("deco line outside safe bounds")
            end
            sim.decoLine(x1, y1, x2, y2, rx, ry, r, g, b, a, tool, brush)
            return jok("placeDecoLine")

        elseif action == "listStamps" then
            local stamps = sim.listStamps()
            local names = {}
            for i, stamp in ipairs(stamps) do names[i] = jesc(stamp) end
            return jok("listStamps", ',"stamps":[' .. table.concat(names, ",") .. "]")

        elseif action == "saveStamp" then
            local x = tonumber(req.x) or 0
            local y = tonumber(req.y) or 0
            local w = tonumber(req.w) or 50
            local h = tonumber(req.h) or 50
            if x < 0 or y < 0 or w < 1 or h < 1 or x + w >= sim.XRES or y + h >= sim.YRES then
                return jerr("stamp bounds outside pixel domain")
            end
            local name = sim.saveStamp(x, y, w, h, req.includePressure == false and 0 or 1)
            return jok("saveStamp", ',"name":' .. jesc(name))

        elseif action == "loadStamp" then
            local name = req.name
            local x = tonumber(req.x) or 0
            local y = tonumber(req.y) or 0
            if not stampExists(name) then return jerr("unknown stamp", ',"name":' .. jesc(name)) end
            if x < 0 or y < 0 or x >= sim.XRES or y >= sim.YRES then
                return jerr("stamp position outside pixel domain")
            end
            local loaded, detail = sim.loadStamp(name, x, y)
            if not loaded then return jerr("loadStamp failed", ',"detail":' .. jesc(detail)) end
            return jok("loadStamp", ',"loaded":true')

        elseif action == "deleteStamp" then
            local name = req.name
            if not stampExists(name) then return jerr("unknown stamp", ',"name":' .. jesc(name)) end
            sim.deleteStamp(name)
            return jok("deleteStamp", ',"deleted":true')
        elseif action == "placeCircle" then
            local elemId = resolveElem(req.element)
            if not elemId then return jerr("unknown element") end
            local cx = tonumber(req.cx) or 100
            local cy = tonumber(req.cy) or 100
            local r = tonumber(req.radius) or 10
            sim.createParts(cx, cy, r, r, elemId)
            return jok("placeCircle", ',"cx":' .. jnum(cx) .. ',"cy":' .. jnum(cy))

        elseif action == "getField" then
            local field = string.lower(tostring(req.field or "temp"))
            local x = tonumber(req.x) or 10
            local y = tonumber(req.y) or 10
            local value
            if field == "temp" or field == "temperature" then
                value = sim.getTemp(x, y)
            elseif field == "pressure" then
                value = sim.getPressure(x, y)
            else
                return jerr("unknown field", ',"field":' .. jesc(field))
            end
            return jok("getField", ',"field":' .. jesc(field) .. ',"x":' .. jnum(x) .. ',"y":' .. jnum(y) .. ',"value":' .. jnum(value))
        elseif action == "partsInventory" then
            local slotBound = 235008
            local function pInt(value, name)
                if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then
                    return nil, (name or "value") .. " must be an integer"
                end
                return value, nil
            end
            local function pFinite(value)
                return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
            end
            local function pNow()
                local nowOk, now = pcall(function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end)
                return nowOk and type(now) == "string" and now or nil
            end
            local correlationId = req.correlation_id
            local correlationSafe = type(correlationId) == "string" and #correlationId >= 1 and #correlationId <= 64
                and correlationId:match("^[A-Za-z0-9_-]+$")
            local function pProvenance()
                return '{"source_root":"D:/The-Powder-Toy","runtime_deploy":"D:/The-Powder-Toy/build/autorun.lua","mcp_source_root":"D:/powder-toy"'
                    .. ',"runtime_host":"127.0.0.1","runtime_port":9876,"particle_source":"sim.partExists/partPosition/partProperty"'
                    .. ',"slot_bound_source":"SimulationConfig.h:NPART=XRES*YRES","slot_bound":' .. jnum(slotBound)
                    .. ',"pid_source":"runtime_binding_or_unavailable"}'
            end
            local function pError(code, detail)
                local now = pNow()
                return jerr(detail, ',"action":"partsInventory","schema_version":"parts-inventory/v1","error_code":' .. jesc(code)
                    .. ',"correlation_id":' .. (correlationSafe and jesc(correlationId) or "null")
                    .. ',"timestamp":' .. (now and jesc(now) or "null")
                    .. ',"cursor_next":null,"done":false,"scanned":0,"returned":0,"matched":0,"partCount":null,"truncated":false,"records":[]'
                    .. ',"limits":{"max_limit":256,"max_scan":4096,"slot_bound":' .. jnum(slotBound) .. '}'
                    .. ',"provenance":' .. pProvenance()
                    .. ',"evidence":{"contract":"parts-inventory-evidence/v1","status":"failed","postcondition_ok":false,"complete":false,"strength":"absent","correlation_id":' .. (correlationSafe and jesc(correlationId) or "null")
                    .. ',"reason":' .. jesc(code) .. "}")
            end
            local allowedKeys = {
                token = true, action = true, correlation_id = true, cursor = true, limit = true, max_scan = true,
                x1 = true, y1 = true, x2 = true, y2 = true, type = true
            }
            local requestKeys = 0
            for key, _ in pairs(req) do
                requestKeys = requestKeys + 1
                if requestKeys > 16 or type(key) ~= "string" or not allowedKeys[key] then
                    return pError("invalid_request", "unknown partsInventory request key")
                end
            end
            if correlationId ~= nil and not correlationSafe then
                return pError("invalid_request", "correlation_id must be a safe identifier")
            end
            local xres, yres = sim.XRES, sim.YRES
            if not pFinite(xres) or not pFinite(yres) or xres < 1 or yres < 1 or xres ~= math.floor(xres) or yres ~= math.floor(yres) then
                return pError("runtime_unavailable", "runtime pixel bounds unavailable")
            end
            slotBound = xres * yres
            local cursor, cursorErr = pInt(req.cursor ~= nil and req.cursor or 0, "cursor")
            if cursorErr or cursor < 0 or cursor > slotBound then
                return pError("invalid_request", cursorErr or "cursor is outside the particle slot domain")
            end
            local limit, limitErr = pInt(req.limit ~= nil and req.limit or 256, "limit")
            if limitErr or limit < 1 or limit > 256 then
                return pError("invalid_request", limitErr or "limit must be between 1 and 256")
            end
            local maxScan, maxScanErr = pInt(req.max_scan ~= nil and req.max_scan or 4096, "max_scan")
            if maxScanErr or maxScan < 1 or maxScan > 4096 then
                return pError("invalid_request", maxScanErr or "max_scan must be between 1 and 4096")
            end
            local typeFilter
            if req.type ~= nil then
                local typeErr
                typeFilter, typeErr = pInt(req.type, "type")
                if typeErr or typeFilter < 0 then
                    return pError("invalid_request", typeErr or "type must be a non-negative integer")
                end
            end
            local hasRect = req.x1 ~= nil or req.y1 ~= nil or req.x2 ~= nil or req.y2 ~= nil
            local region
            if hasRect then
                if req.x1 == nil or req.y1 == nil or req.x2 == nil or req.y2 == nil then
                    return pError("invalid_request", "x1, y1, x2, and y2 are required together")
                end
                local x1, y1, x2, y2, regionErr
                x1, regionErr = pInt(req.x1, "x1")
                if regionErr then return pError("invalid_request", regionErr) end
                y1, regionErr = pInt(req.y1, "y1")
                if regionErr then return pError("invalid_request", regionErr) end
                x2, regionErr = pInt(req.x2, "x2")
                if regionErr then return pError("invalid_request", regionErr) end
                y2, regionErr = pInt(req.y2, "y2")
                if regionErr then return pError("invalid_request", regionErr) end
                region = {x1 = x1, y1 = y1, x2 = x2, y2 = y2}
            end
            if region then
                if region.x1 > region.x2 or region.y1 > region.y2 then
                    return pError("invalid_request", "region lower bounds exceed upper bounds")
                end
                if region.x1 < 0 or region.y1 < 0 or region.x2 >= xres or region.y2 >= yres then
                    return pError("coordinate_out_of_bounds", "region is outside pixel bounds")
                end
            end
            if type(sim.partCount) ~= "function" or type(sim.partExists) ~= "function"
                or type(sim.partPosition) ~= "function" or type(sim.partProperty) ~= "function" then
                return pError("runtime_unavailable", "particle inventory APIs are unavailable")
            end
            local startedAt = pNow()
            local countOk, partCount = pcall(sim.partCount)
            if not countOk or not pFinite(partCount) or partCount < 0 then
                return pError("runtime_unavailable", "partCount read unavailable")
            end
            local records, errors = {}, {}
            local scanned, matched, returned = 0, 0, 0
            local nextCursor = cursor
            local stoppedByLimit = false
            while nextCursor < slotBound and scanned < maxScan do
                local id = nextCursor
                scanned = scanned + 1
                nextCursor = id + 1
                local existsOk, exists = pcall(sim.partExists, id)
                if not existsOk then
                    if #errors < 16 then errors[#errors + 1] = "partExists:" .. tostring(id) end
                elseif exists then
                    local positionOk, px, py = pcall(sim.partPosition, id)
                    local typeOk, particleType = pcall(sim.partProperty, id, "type")
                    if not positionOk or not pFinite(px) or not pFinite(py) or not typeOk or not pFinite(particleType) then
                        if #errors < 16 then errors[#errors + 1] = "particle_read:" .. tostring(id) end
                    elseif (not typeFilter or particleType == typeFilter)
                        and (not region or (px >= region.x1 and px <= region.x2 and py >= region.y1 and py <= region.y2)) then
                        matched = matched + 1
                        if returned < limit then
                            local tempOk, temp = pcall(sim.partProperty, id, "temp")
                            local lifeOk, life = pcall(sim.partProperty, id, "life")
                            local vxOk, vx = pcall(sim.partProperty, id, "vx")
                            local vyOk, vy = pcall(sim.partProperty, id, "vy")
                            if tempOk and lifeOk and vxOk and vyOk and pFinite(temp) and pFinite(life) and pFinite(vx) and pFinite(vy) then
                                returned = returned + 1
                                records[#records + 1] = '{"id":' .. jnum(id)
                                    .. ',"type":' .. jnum(particleType) .. ',"x":' .. jnum(px) .. ',"y":' .. jnum(py)
                                    .. ',"temp":' .. jnum(temp) .. ',"life":' .. jnum(life)
                                    .. ',"vx":' .. jnum(vx) .. ',"vy":' .. jnum(vy) .. "}"
                                if returned >= limit then stoppedByLimit = true end
                            elseif #errors < 16 then
                                errors[#errors + 1] = "particle_properties:" .. tostring(id)
                            end
                        end
                    end
                end
                if stoppedByLimit then break end
            end
            local done = nextCursor >= slotBound
            local truncated = not done and (stoppedByLimit or scanned >= maxScan)
            local completedAt = pNow()
            local responseOk = #errors == 0
            local complete = responseOk and done and not truncated
            local status = not responseOk and "failed" or (truncated and "partial" or "verified")
            local reason = not responseOk and "runtime_read_failed" or (truncated and (stoppedByLimit and "limit" or "max_scan") or nil)
            local regionJson = "null"
            if region then
                regionJson = '{"x1":' .. jnum(region.x1) .. ',"y1":' .. jnum(region.y1)
                    .. ',"x2":' .. jnum(region.x2) .. ',"y2":' .. jnum(region.y2) .. "}"
            end
            local encodedErrors = {}
            for i = 1, #errors do encodedErrors[i] = jesc(errors[i]) end
            local result = '{"ok":' .. (responseOk and "true" or "false") .. ',"action":"partsInventory","schema_version":"parts-inventory/v1"'
                .. ',"correlation_id":' .. (correlationSafe and jesc(correlationId) or "null")
                .. ',"timestamp":' .. (completedAt and jesc(completedAt) or "null")
                .. ',"capture":{"started_at":' .. (startedAt and jesc(startedAt) or "null") .. ',"completed_at":' .. (completedAt and jesc(completedAt) or "null") .. ',"consistency":"handler_capture"}'
                .. ',"cursor":' .. jnum(cursor) .. ',"cursor_next":' .. jnum(nextCursor) .. ',"done":' .. (done and "true" or "false")
                .. ',"scanned":' .. jnum(scanned) .. ',"matched":' .. jnum(matched) .. ',"returned":' .. jnum(returned)
                .. ',"partCount":' .. jnum(partCount) .. ',"truncated":' .. (truncated and "true" or "false")
                .. ',"records":[' .. table.concat(records, ",") .. ']'
                .. ',"filters":{"region":' .. regionJson .. ',"type":' .. (typeFilter and jnum(typeFilter) or "null") .. "}"
                .. ',"limits":{"max_limit":256,"max_scan":4096,"slot_bound":' .. jnum(slotBound) .. ',"limit":' .. jnum(limit) .. ',"max_scan_requested":' .. jnum(maxScan) .. "}"
                .. ',"provenance":' .. pProvenance()
                .. ',"evidence":{"contract":"parts-inventory-evidence/v1","status":' .. jesc(status)
                .. ',"postcondition_ok":' .. (responseOk and "true" or "false") .. ',"complete":' .. (complete and "true" or "false")
                .. ',"strength":"atomic_runtime_read","correlation_id":' .. (correlationSafe and jesc(correlationId) or "null")
                .. ',"requested":{"cursor":' .. jnum(cursor) .. ',"limit":' .. jnum(limit) .. ',"max_scan":' .. jnum(maxScan)
                .. ',"region":' .. regionJson .. ',"type":' .. (typeFilter and jnum(typeFilter) or "null") .. "}"
                .. ',"readback":{"action":"partsInventory","timestamp":' .. (completedAt and jesc(completedAt) or "null")
                .. ',"cursor_next":' .. jnum(nextCursor) .. ',"returned":' .. jnum(returned) .. ',"scanned":' .. jnum(scanned)
                .. ',"matched":' .. jnum(matched) .. ',"partCount":' .. jnum(partCount) .. "}"
                .. ',"reason":' .. (reason and jesc(reason) or "null") .. "}"
            if #errors > 0 then
                result = result .. ',"errors":[' .. table.concat(encodedErrors, ",") .. "]"
            end
            return result .. "}"
        elseif action == "spatialSnapshot" then
            local function sInt(value, name)
                if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil, (name or "value") .. " must be an integer" end
                return value, nil
            end
            local function sNum(value)
                if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return "null" end
                return tostring(value)
            end
            local function sStrings(values)
                local out = {}
                for i = 1, #values do out[i] = jesc(values[i]) end
                return "[" .. table.concat(out, ",") .. "]"
            end
            local function sNumbers(values)
                local out = {}
                for i = 1, #values do out[i] = sNum(values[i]) end
                return "[" .. table.concat(out, ",") .. "]"
            end
            local function sNow()
                local ok, value = pcall(function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end)
                return ok and type(value) == "string" and value or nil
            end
            local cid = req.correlation_id
            local cidSafe = type(cid) == "string" and #cid >= 1 and #cid <= 64 and cid:match("^[A-Za-z0-9_-]+$")
            local function sError(code, detail)
                local now = sNow()
                return jerr(detail, ',"action":"spatialSnapshot","schema_version":"spatial-snapshot/v1","error_code":' .. jesc(code)
                    .. ',"correlation_id":' .. (cidSafe and jesc(cid) or "null") .. ',"timestamp":' .. (now and jesc(now) or "null") .. ',"pid":null'
                    .. ',"limits":{"max_region_area":12288,"max_samples":4096,"max_stride":128,"max_particles":256,"max_particle_ids":256,"max_response_bytes":262144}'
                    .. ',"truncation":{"any":false,"fields":false,"particles":false,"reasons":[]}'
                    .. ',"provenance":{"source_root":"D:/The-Powder-Toy","runtime_deploy":"D:/The-Powder-Toy/build/autorun.lua","runtime_host":"127.0.0.1","runtime_port":9876,"pid_source":"runtime_binding_or_unavailable"}'
                    .. ',"evidence":{"contract":"spatial-evidence/v1","status":"failed","postcondition_ok":false,"complete":false,"strength":"absent","correlation_id":' .. (cidSafe and jesc(cid) or "null") .. ',"reason":' .. jesc(code) .. "}")
            end
            local allowedSnapshotKeys = {
                token = true, action = true, correlation_id = true, space = true,
                x = true, y = true, x1 = true, y1 = true, x2 = true, y2 = true,
                fields = true, sample_fields = true, stride = true, sample_stride = true,
                max_samples = true, allow_truncation = true, include_particles = true,
                particle_ids = true, max_particles = true, max_response_bytes = true, discover_particles = true
            }
            local requestKeys = 0
            for key, _ in pairs(req) do
                requestKeys = requestKeys + 1
                if requestKeys > 32 or type(key) ~= "string" or not allowedSnapshotKeys[key] then
                    return sError("invalid_request", "unknown spatialSnapshot request key")
                end
            end
            if cid ~= nil and not cidSafe then return sError("invalid_request", "correlation_id must be a safe identifier") end
            local space = req.space
            if type(space) ~= "string" or (space ~= "cell" and space ~= "pixel") then return sError("invalid_request", "space must be exactly pixel or cell") end
            local xres, yres, xcells, ycells, cell = sim.XRES, sim.YRES, sim.XCELLS, sim.YCELLS, sim.CELL
            if type(xres) ~= "number" or type(yres) ~= "number" or type(xcells) ~= "number" or type(ycells) ~= "number"
                or xres < 1 or yres < 1 or xcells < 1 or ycells < 1
                or xres ~= math.floor(xres) or yres ~= math.floor(yres) or xcells ~= math.floor(xcells) or ycells ~= math.floor(ycells) then
                return sError("coordinate_bounds_unverified", "runtime coordinate bounds unavailable")
            end
            if type(cell) ~= "number" or cell < 1 or cell ~= math.floor(cell) then cell = nil end
            local hasPoint = req.x ~= nil or req.y ~= nil
            local hasRect = req.x1 ~= nil or req.y1 ~= nil or req.x2 ~= nil or req.y2 ~= nil
            if hasPoint and hasRect then return sError("invalid_request", "provide x and y or x1, y1, x2, y2, not both") end
            local x1, y1, x2, y2
            if hasPoint then
                if req.x == nil or req.y == nil then return sError("invalid_request", "x and y are required together") end
                local err
                x1, err = sInt(req.x, "x")
                if err then return sError("invalid_request", err) end
                y1, err = sInt(req.y, "y")
                if err then return sError("invalid_request", err) end
                x2, y2 = x1, y1
            elseif hasRect then
                if req.x1 == nil or req.y1 == nil or req.x2 == nil or req.y2 == nil then return sError("invalid_request", "x1, y1, x2, and y2 are required together") end
                local err
                x1, err = sInt(req.x1, "x1")
                if err then return sError("invalid_request", err) end
                y1, err = sInt(req.y1, "y1")
                if err then return sError("invalid_request", err) end
                x2, err = sInt(req.x2, "x2")
                if err then return sError("invalid_request", err) end
                y2, err = sInt(req.y2, "y2")
                if err then return sError("invalid_request", err) end
            else
                return sError("invalid_request", "a point or inclusive rectangle is required")
            end
            local maxx, maxy = space == "cell" and xcells - 1 or xres - 1, space == "cell" and ycells - 1 or yres - 1
            if x1 > x2 or y1 > y2 then return sError("invalid_request", "rectangle lower bounds exceed upper bounds") end
            if x1 < 0 or y1 < 0 or x2 > maxx or y2 > maxy then return sError("coordinate_out_of_bounds", "region is outside coordinate bounds") end
            local width, height, area = x2 - x1 + 1, y2 - y1 + 1, (x2 - x1 + 1) * (y2 - y1 + 1)
            if area > 12288 then return sError("snapshot_limit_exceeded", "region area exceeds 12288") end
            if req.fields ~= nil and req.sample_fields ~= nil then return sError("invalid_request", "provide fields or sample_fields, not both") end
            local rawFields = req.fields ~= nil and req.fields or req.sample_fields
            if rawFields == nil then rawFields = space == "cell" and {"temp", "pressure"} or {} end
            if type(rawFields) ~= "table" then return sError("invalid_request", "fields must be an array") end
            local fieldCount, fieldKeys = 0, 0
            for key, _ in pairs(rawFields) do
                fieldKeys = fieldKeys + 1
                if fieldKeys > 2 or type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return sError("invalid_request", "fields must be a dense array") end
                if key > fieldCount then fieldCount = key end
            end
            if fieldCount ~= fieldKeys then return sError("invalid_request", "fields must be a dense array") end
            if fieldCount > 2 then return sError("invalid_request", "fields must contain at most two entries") end
            local fields, seen = {}, {}
            for i = 1, fieldCount do
                if rawFields[i] == nil or type(rawFields[i]) ~= "string" then return sError("invalid_request", "fields must be a dense string array") end
                local field = rawFields[i] == "temperature" and "temp" or rawFields[i]
                if field ~= "temp" and field ~= "pressure" then return sError("field_unavailable", "field is not available") end
                if not seen[field] then
                    seen[field] = true
                    fields[#fields + 1] = field
                end
            end
            if space == "pixel" and #fields > 0 then return sError("coordinate_domain_mismatch", "pixel coordinates cannot sample cell fields; no conversion performed") end
            if req.stride ~= nil and req.sample_stride ~= nil then return sError("invalid_request", "provide stride or sample_stride, not both") end
            local strideValue = req.stride ~= nil and req.stride or (req.sample_stride ~= nil and req.sample_stride or 1)
            local stride, strideErr = sInt(strideValue, "stride")
            if strideErr or stride < 1 or stride > 128 then return sError("invalid_request", strideErr or "stride is outside the allowed range") end
            local maxSamples, maxSamplesErr = sInt(req.max_samples ~= nil and req.max_samples or 4096, "max_samples")
            if maxSamplesErr or maxSamples < 1 or maxSamples > 4096 then return sError("invalid_request", maxSamplesErr or "max_samples is outside the allowed range") end
            local maxResponseBytes, maxResponseErr = sInt(req.max_response_bytes ~= nil and req.max_response_bytes or 262144, "max_response_bytes")
            if maxResponseErr or maxResponseBytes < 4096 or maxResponseBytes > 262144 then return sError("invalid_request", maxResponseErr or "max_response_bytes must be between 4096 and 262144") end
            local allowTruncation = req.allow_truncation
            if allowTruncation ~= nil and type(allowTruncation) ~= "boolean" then return sError("invalid_request", "allow_truncation must be boolean") end
            allowTruncation = allowTruncation == true
            local includeParticles = req.include_particles
            if includeParticles ~= nil and type(includeParticles) ~= "boolean" then return sError("invalid_request", "include_particles must be boolean") end
            includeParticles = includeParticles == true
            local discoverParticles = req.discover_particles
            if discoverParticles ~= nil and type(discoverParticles) ~= "boolean" then return sError("invalid_request", "discover_particles must be boolean") end
            discoverParticles = discoverParticles == true
            local rawIds = req.particle_ids
            if rawIds == nil then rawIds = {} elseif type(rawIds) ~= "table" then return sError("invalid_request", "particle_ids must be an array") end
            local idCount, idKeys = 0, 0
            for key, _ in pairs(rawIds) do
                idKeys = idKeys + 1
                if idKeys > 256 or type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return sError("invalid_request", "particle_ids must be a dense array") end
                if key > idCount then idCount = key end
            end
            if idCount ~= idKeys then return sError("invalid_request", "particle_ids must be a dense array") end
            if idCount > 256 then return sError("invalid_request", "particle_ids cannot exceed 256 entries") end
            local particleIds, idSeen = {}, {}
            for i = 1, idCount do
                local id, idErr = sInt(rawIds[i], "particle_ids entry")
                if idErr or id < 0 then return sError("invalid_request", idErr or "particle IDs must be non-negative") end
                if not idSeen[id] then idSeen[id] = true; particleIds[#particleIds + 1] = id end
            end
            local explicitParticleIds = {}
            for i = 1, #particleIds do explicitParticleIds[i] = particleIds[i] end
            if #particleIds > 0 then includeParticles = true end
            if includeParticles and #particleIds == 0 and not discoverParticles then return sError("invalid_request", "include_particles requires explicit particle_ids or discover_particles") end
            local maxParticles, maxParticlesErr = sInt(req.max_particles ~= nil and req.max_particles or 256, "max_particles")
            if maxParticlesErr or maxParticles < 1 or maxParticles > 256 then return sError("invalid_request", maxParticlesErr or "max_particles is outside the allowed range") end
            table.sort(particleIds, function(a, b) return a < b end)
            local discoverySlots = math.max(0, maxParticles - #particleIds)
            local discoveredIds, discoveredSeen = {}, {}
            local discoveryScanned, discoveryTruncated = 0, false
            local pmapFailed, photonsFailed = false, false
            if discoverParticles then
                if space ~= "pixel" then return sError("coordinate_domain_mismatch", "discover_particles requires pixel space") end
                includeParticles = true
                if type(sim.pmap) ~= "function" or type(sim.photons) ~= "function" then
                    return sError("runtime_unavailable", "pmap and photons occupancy APIs are required")
                end
                for yy = y1, y2 do
                    for xx = x1, x2 do
                        discoveryScanned = discoveryScanned + 1
                        local mapIds = {}
                        local pmapOk, pmapId = pcall(sim.pmap, xx, yy)
                        if not pmapOk then pmapFailed = true elseif type(pmapId) == "number" then mapIds[#mapIds + 1] = pmapId end
                        local photonsOk, photonsId = pcall(sim.photons, xx, yy)
                        if not photonsOk then photonsFailed = true elseif type(photonsId) == "number" then mapIds[#mapIds + 1] = photonsId end
                        for _, id in ipairs(mapIds) do
                            if id >= 0 and not idSeen[id] then
                                idSeen[id] = true
                                discoveredSeen[id] = true
                                if #discoveredIds < discoverySlots then
                                    discoveredIds[#discoveredIds + 1] = id
                                    particleIds[#particleIds + 1] = id
                                else
                                    discoveryTruncated = true
                                end
                            end
                        end
                    end
                end
            if discoveryTruncated and not allowTruncation then
                return sError("snapshot_limit_exceeded", "discovered occupancy exceeds max_particles")
            end
            end
            local columns, rows = math.floor((x2 - x1) / stride) + 1, math.floor((y2 - y1) / stride) + 1
            local plannedSamples = columns * rows * #fields
            local fieldTruncated = plannedSamples > maxSamples
            if fieldTruncated and not allowTruncation then return sError("snapshot_limit_exceeded", "requested samples exceed max_samples") end
            local particleTruncated = #particleIds > maxParticles
            if particleTruncated and not allowTruncation then return sError("snapshot_limit_exceeded", "requested particles exceed max_particles") end
            local startedAt = sNow()
            local partCount
            if type(sim.partCount) == "function" then
                local countOk, countValue = pcall(sim.partCount)
                if countOk and type(countValue) == "number" and countValue >= 0 then partCount = countValue end
            end
            local values, served, readErrors, sampleCount = {}, {}, {}, 0
            for yy = y1, y2, stride do
                if sampleCount >= maxSamples then break end
                for xx = x1, x2, stride do
                    if sampleCount >= maxSamples then break end
                    for fi = 1, #fields do
                        if sampleCount >= maxSamples then break end
                        local field, readOk, value = fields[fi], false, nil
                        if field == "temp" and type(sim.getTemp) == "function" then readOk, value = pcall(sim.getTemp, xx, yy)
                        elseif field == "pressure" and type(sim.getPressure) == "function" then readOk, value = pcall(sim.getPressure, xx, yy) end
                        local available = readOk and type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
                        if available then served[field] = true else readErrors[#readErrors + 1] = "field:" .. field .. ":" .. tostring(xx) .. "," .. tostring(yy) end
                        values[#values + 1] = '{"field":' .. jesc(field) .. ',"space":"cell","x":' .. jnum(xx) .. ',"y":' .. jnum(yy) .. ',"value":' .. sNum(value) .. ',"available":' .. (available and "true" or "false") .. (available and "" or ',"reason":"runtime field read unavailable"') .. "}"
                        sampleCount = sampleCount + 1
                    end
                end
            end
            local particles, missingIds, particleReturned, discoveredReturned = {}, {}, 0, 0
            local particleLimit = math.min(#particleIds, maxParticles)
            if includeParticles then
                for i = 1, particleLimit do
                    local id = particleIds[i]
                    local existsOk, exists = false, false
                    if type(sim.partExists) == "function" then existsOk, exists = pcall(sim.partExists, id) end
                    if existsOk and exists and type(sim.partPosition) == "function" and type(sim.partProperty) == "function" then
                        local posOk, px, py = pcall(sim.partPosition, id)
                        if posOk and type(px) == "number" and type(py) == "number" then
                            local typeOk, ptype = pcall(sim.partProperty, id, "type")
                            local tempOk, ptemp = pcall(sim.partProperty, id, "temp")
                            local lifeOk, life = pcall(sim.partProperty, id, "life")
                            local vxOk, vx = pcall(sim.partProperty, id, "vx")
                            local vyOk, vy = pcall(sim.partProperty, id, "vy")
                            if typeOk and tempOk and lifeOk and vxOk and vyOk then
                                particles[#particles + 1] = '{"id":' .. jnum(id)
                                    .. ',"type":' .. sNum(ptype)
                                    .. ',"x":' .. sNum(px)
                                    .. ',"y":' .. sNum(py)
                                    .. ',"temp":' .. sNum(ptemp)
                                    .. ',"life":' .. sNum(life)
                                    .. ',"vx":' .. sNum(vx)
                                    .. ',"vy":' .. sNum(vy) .. "}"
                                particleReturned = particleReturned + 1
                                if discoveredSeen[id] then discoveredReturned = discoveredReturned + 1 end
                            else
                                missingIds[#missingIds + 1] = id
                            end
                        else
                            missingIds[#missingIds + 1] = id
                        end
                    else
                        missingIds[#missingIds + 1] = id
                    end
                end
            end
            local fieldsTruncated = plannedSamples > sampleCount
            local particlesTruncated = #particleIds > particleLimit or discoveryTruncated
            local truncated = fieldsTruncated or particlesTruncated
            local responseOk = #readErrors == 0 and #missingIds == 0 and (not discoverParticles or (not pmapFailed and not photonsFailed))
            local complete = responseOk and not truncated
            local completedAt = sNow()
            local status = not responseOk and "failed" or (truncated and "partial" or "verified")
            local reasonList = {}
            if discoveryTruncated then reasonList[#reasonList + 1] = "occupancy_max_particles" end
            if particlesTruncated and not discoveryTruncated then reasonList[#reasonList + 1] = "max_particles" end
            if fieldsTruncated then reasonList[#reasonList + 1] = "max_samples" end
            if pmapFailed then reasonList[#reasonList + 1] = "pmap_read_failed" end
            if photonsFailed then reasonList[#reasonList + 1] = "photons_read_failed" end
            local reasons = sStrings(reasonList)
            local function bounds(target)
                local bx, by = target == "pixel" and xres or xcells, target == "pixel" and yres or ycells
                return '{"x":{"min":0,"max":' .. jnum(bx - 1) .. ',"max_exclusive":' .. jnum(bx) .. ',"size":' .. jnum(bx) .. '},"y":{"min":0,"max":' .. jnum(by - 1) .. ',"max_exclusive":' .. jnum(by) .. ',"size":' .. jnum(by) .. "}}"
            end
            local regionJson = '{"space":' .. jesc(space) .. ',"x1":' .. jnum(x1) .. ',"y1":' .. jnum(y1) .. ',"x2":' .. jnum(x2) .. ',"y2":' .. jnum(y2) .. ',"width":' .. jnum(width) .. ',"height":' .. jnum(height) .. ',"area":' .. jnum(area) .. "}"
            local domains = '{"pixel":' .. bounds("pixel") .. ',"cell":' .. bounds("cell") .. ',"pixel_per_cell":' .. (cell and '{"x":' .. jnum(cell) .. ',"y":' .. jnum(cell) .. "}" or "null") .. ',"active_space":' .. jesc(space) .. ',"region":' .. regionJson .. "}"
            local servedFields = {}
            for _, field in ipairs(fields) do if served[field] then servedFields[#servedFields + 1] = field end end
            local particleReason
            if not includeParticles then
                particleReason = "particle_sampling_disabled"
            elseif discoverParticles and #explicitParticleIds > 0 then
                particleReason = "mixed"
            elseif discoverParticles then
                particleReason = "discovered"
            else
                particleReason = "explicit_ids"
            end
            if #missingIds > 0 then readErrors[#readErrors + 1] = "unknown_particle_ids:" .. sNumbers(missingIds) end
            if pmapFailed then readErrors[#readErrors + 1] = "pmap_read_failed" end
            if photonsFailed then readErrors[#readErrors + 1] = "photons_read_failed" end
            local errorCode = #readErrors == 0 and "none" or (#missingIds > 0 and "particle_read_failed" or (pmapFailed or photonsFailed) and "occupancy_read_failed" or "field_read_failed")
            local result = '{"ok":' .. (responseOk and "true" or "false") .. ',"action":"spatialSnapshot","schema_version":"spatial-snapshot/v1","correlation_id":' .. (cid and jesc(cid) or "null") .. ',"timestamp":' .. (completedAt and jesc(completedAt) or "null") .. ',"pid":null'
                .. ',"capture":{"started_at":' .. (startedAt and jesc(startedAt) or "null") .. ',"completed_at":' .. (completedAt and jesc(completedAt) or "null") .. ',"duration_ms":null,"consistency":"handler_capture"}'
                .. ',"coordinate_domains":' .. domains .. ',"bounds":' .. bounds(space) .. ',"partCount":' .. sNum(partCount) .. ',"part_count":' .. sNum(partCount)
                .. ',"available_fields":{"requested":' .. sStrings(fields) .. ',"served":' .. sStrings(servedFields) .. ',"runtime_available":' .. (space == "cell" and '["temp","pressure"]' or "[]") .. ',"source_indexed":["temp","pressure"],"unsupported":[]}'
                .. ',"sampled_fields":{"space":' .. jesc(space) .. ',"region":' .. regionJson .. ',"stride":' .. jnum(stride) .. ',"requested":' .. sStrings(fields) .. ',"items":[' .. table.concat(values, ",") .. '],"requested_count":' .. jnum(plannedSamples) .. ',"sample_count":' .. jnum(sampleCount) .. ',"returned_count":' .. jnum(sampleCount) .. ',"truncated":' .. (fieldsTruncated and "true" or "false") .. ',"limit":' .. jnum(maxSamples) .. '}'
                .. ',"occupancy":{"requested":' .. (discoverParticles and "true" or "false") .. ',"space":"pixel","source_maps":["pmap","photons"],"scanned_points":' .. jnum(discoverParticles and discoveryScanned or 0) .. ',"discovered_ids":' .. jnum(discoverParticles and (#discoveredIds) or 0) .. ',"returned":' .. jnum(discoverParticles and discoveredReturned or 0) .. ',"truncated":' .. (discoveryTruncated and "true" or "false") .. ',"reasons":' .. (discoveryTruncated and '["max_particles"]' or "[]") .. '}'
                .. ',"particles":{"coordinate_space":"pixel","items":[' .. table.concat(particles, ",") .. '],"requested_ids":' .. sNumbers(explicitParticleIds) .. ',"requested":' .. jnum(#explicitParticleIds) .. ',"returned":' .. jnum(particleReturned) .. ',"scanned":' .. jnum(particleLimit) .. ',"truncated":' .. (particlesTruncated and "true" or "false") .. ',"limit":' .. jnum(maxParticles) .. ',"missing_ids":' .. sNumbers(missingIds) .. ',"reason":' .. jesc(particleReason) .. '}'
                .. ',"limits":{"max_region_area":12288,"max_samples":4096,"max_stride":128,"max_particles":256,"max_particle_ids":256,"max_response_bytes":262144},"truncated":' .. (truncated and "true" or "false") .. ',"truncation":{"any":' .. (truncated and "true" or "false") .. ',"fields":' .. (fieldsTruncated and "true" or "false") .. ',"particles":' .. (particlesTruncated and "true" or "false") .. ',"reasons":' .. reasons .. '},"truncation_reasons":' .. reasons
                .. ',"provenance":{"source_root":"D:/The-Powder-Toy","runtime_deploy":"D:/The-Powder-Toy/build/autorun.lua","mcp_source_root":"D:/powder-toy","runtime_host":"127.0.0.1","runtime_port":9876,"coordinate_source":"runtime_constants","field_source":"runtime_handler","particle_source":"sim.partExists/partPosition/partProperty","pid_source":"runtime_binding_or_unavailable"}'
                .. ',"evidence":{"contract":"spatial-evidence/v1","status":' .. jesc(status) .. ',"postcondition_ok":' .. (responseOk and "true" or "false") .. ',"complete":' .. (complete and "true" or "false") .. ',"strength":"atomic_runtime_read","correlation_id":' .. (cid and jesc(cid) or "null") .. ',"requested":{"space":' .. jesc(space) .. ',"region":' .. regionJson .. ',"fields":' .. sStrings(fields) .. '},"readback":{"action":"spatialSnapshot","timestamp":' .. (completedAt and jesc(completedAt) or "null") .. ',"pid":null,"returned_counts":{"samples":' .. jnum(sampleCount) .. ',"particles":' .. jnum(particleReturned) .. '}},"reason":' .. (responseOk and (truncated and '"snapshot_truncated"' or "null") or jesc(errorCode)) .. '}'
            if #readErrors > 0 then
                local encoded = {}
                for i = 1, #readErrors do encoded[i] = jesc(readErrors[i]) end
                result = result .. ',"errors":[' .. table.concat(encoded, ",") .. "]"
            end
            if not responseOk then result = result .. ',"error_code":' .. jesc(errorCode) .. ',"error":"one or more bounded reads failed"' end
            if #result + 1 > maxResponseBytes then
                return sError("snapshot_limit_exceeded", "encoded response exceeds max_response_bytes")
            end
            return result .. "}"
        elseif action == "setFieldRegion" then
            local field = string.lower(tostring(req.field or ""))
            local x = tonumber(req.x) or 0
            local y = tonumber(req.y) or 0
            local w = tonumber(req.w) or 1
            local h = tonumber(req.h) or 1
            local value = tonumber(req.value)
            if value == nil or x < 0 or y < 0 or w < 1 or h < 1 or x + w > sim.XCELLS or y + h > sim.YCELLS then
                return jerr("field region outside cell domain")
            end
            if field == "temp" or field == "temperature" or field == "ambientheat" then
                sim.ambientHeat(x, y, w, h, value)
            elseif field == "pressure" then
                sim.pressure(x, y, w, h, value)
            elseif field == "velocityx" or field == "vx" then
                sim.velocityX(x, y, w, h, value)
            elseif field == "velocityy" or field == "vy" then
                sim.velocityY(x, y, w, h, value)
            elseif field == "fanvelocityx" or field == "fanvelocityy" then
                if value < -256 or value > 256 then return jerr("fan velocity outside safe range") end
                if field == "fanvelocityx" then
                    sim.fanVelocityX(x, y, w, h, value)
                else
                    sim.fanVelocityY(x, y, w, h, value)
                end
            else
                return jerr("unknown field", ',"field":' .. jesc(field))
            end
            return jok("setFieldRegion", ',"field":' .. jesc(field) .. ',"cells":' .. jnum(w * h))

        elseif action == "listElements" then
            local parts = {}
            local count = 0
            for name, idx in pairs(elements) do
                if type(name) == "string" and type(idx) == "number" then
                    count = count + 1
                    parts[#parts + 1] = '{"id":' .. jnum(idx) .. ',"identifier":' .. jesc(name) .. "}"
                    if count >= 40 then break end
                end
            end
            return jok("listElements", ',"count":' .. jnum(count) .. ',"elements":[' .. table.concat(parts, ",") .. "]")

        elseif action == "getSimulationState" then
            local pc = 0
            if sim.partCount then
                pc = sim.partCount()
            elseif sim.NUM_PARTS then
                pc = sim.NUM_PARTS
            end
            return jok("getSimulationState", ',"partCount":' .. jnum(pc))

        elseif action == "getParticle" then
            local id = tonumber(req.id)
            if not id or not sim.partExists(id) then
                return jerr("unknown particle", ',"id":' .. jnum(id))
            end
            local px, py = sim.partPosition(id)
            local info = '{"id":' .. jnum(id)
                .. ',"type":' .. jnum(sim.partProperty(id, "type"))
                .. ',"x":' .. jnum(px)
                .. ',"y":' .. jnum(py)
                .. ',"temp":' .. jnum(sim.partProperty(id, "temp"))
                .. ',"life":' .. jnum(sim.partProperty(id, "life"))
                .. ',"vx":' .. jnum(sim.partProperty(id, "vx"))
                .. ',"vy":' .. jnum(sim.partProperty(id, "vy")) .. '}'
            return jok("getParticle", ',"particle":' .. info)
        elseif action == "createParticle" then
            local elemId = resolveElem(req.element)
            local x = tonumber(req.x)
            local y = tonumber(req.y)
            if not elemId then return jerr("unknown element") end
            if not x or not y or x < 0 or y < 0 or x >= sim.XRES or y >= sim.YRES then
                return jerr("particle position outside pixel domain")
            end
            local id = sim.partCreate(-1, x, y, elemId)
            if id == nil or id < 0 then return jerr("particle allocation failed") end
            return jok("createParticle", ',"id":' .. jnum(id))

        elseif action == "changeParticleType" then
            local id = tonumber(req.id)
            local elemId = resolveElem(req.element)
            if not id or not sim.partExists(id) then return jerr("unknown particle") end
            if not elemId then return jerr("unknown element") end
            sim.partChangeType(id, elemId)
            return jok("changeParticleType", ',"id":' .. jnum(id) .. ',"element":' .. jnum(elemId))

        elseif action == "setParticleProperty" then
            local id = tonumber(req.id)
            local property = tostring(req.property or "")
            local allowed = {life=true, ctype=true, temp=true, vx=true, vy=true, tmp=true, tmp2=true, tmp3=true, tmp4=true, dcolour=true, dcolor=true}
            local value = tonumber(req.value)
            if not id or not sim.partExists(id) then return jerr("unknown particle") end
            if not allowed[property] then return jerr("particle property not allowed") end
            if value == nil or value ~= value or value == math.huge or value == -math.huge then
                return jerr("particle property must be finite numeric")
            end
            if property == "temp" and (value < 0 or value > 9999) then return jerr("temperature outside range") end
            if (property == "dcolour" or property == "dcolor") and (value < 0 or value > 4294967295) then return jerr("dcolour outside range") end
            sim.partProperty(id, property, value)
            return jok("setParticleProperty", ',"id":' .. jnum(id))

        elseif action == "killParticle" then
            local id = tonumber(req.id)
            if not id or not sim.partExists(id) then return jerr("unknown particle") end
            sim.partKill(id)
            return jok("killParticle", ',"id":' .. jnum(id) .. ',"killed":true')

        elseif action == "placeDecoPoint" then
            local x = tonumber(req.x) or 0
            local y = tonumber(req.y) or 0
            local rx = math.max(0, math.min(100, tonumber(req.rx) or 5))
            local ry = math.max(0, math.min(100, tonumber(req.ry) or 5))
            local r = math.max(0, math.min(255, tonumber(req.r) or 255))
            local g = math.max(0, math.min(255, tonumber(req.g) or 255))
            local b = math.max(0, math.min(255, tonumber(req.b) or 255))
            local a = math.max(0, math.min(255, tonumber(req.a) or 255))
            local tool = tonumber(req.tool) or 0
            local brush = tonumber(req.brush) or 0
            if x < 0 or y < 0 or x >= sim.XRES or y >= sim.YRES then
                return jerr("deco point outside pixel bounds")
            end
            sim.decoBrush(x, y, rx, ry, r, g, b, a, tool, brush)
            return jok("placeDecoPoint")

        elseif action == "setCustomGravity" then
            local gx = tonumber(req.gx) or 0
            local gy = tonumber(req.gy) or 0
            if gx ~= gx or gy ~= gy or gx == math.huge or gy == math.huge then return jerr("custom gravity components must be finite numeric") end
            if gx < -100 or gx > 100 or gy < -100 or gy > 100 then return jerr("custom gravity components out of safe range") end
            sim.customGravity(gx, gy)
            return jok("setCustomGravity")

        elseif action == "setEdgePressure" then
            local v = tonumber(req.value)
            if v == nil or v ~= v or v == math.huge then return jerr("edge pressure must be finite numeric") end
            if v < -256 or v > 256 then return jerr("edge pressure out of safe range") end
            sim.edgePressure(v)
            return jok("setEdgePressure")

        elseif action == "setEdgeVelocity" then
            local vx = tonumber(req.vx) or 0
            local vy = tonumber(req.vy) or 0
            if vx ~= vx or vy ~= vy or vx == math.huge or vy == math.huge then return jerr("edge velocity components must be finite numeric") end
            if vx < -256 or vx > 256 or vy < -256 or vy > 256 then return jerr("edge velocity components out of safe range") end
            sim.edgeVelocity(vx, vy)
            return jok("setEdgeVelocity")
        elseif action == "setSimulationModes" then
            local edge = req.edgeMode ~= nil and tonumber(req.edgeMode) or nil
            local gravity = req.gravityMode ~= nil and tonumber(req.gravityMode) or nil
            local air = req.airMode ~= nil and tonumber(req.airMode) or nil
            if edge ~= nil and (edge ~= math.floor(edge) or edge < 0 or edge > 2) then return jerr("edgeMode outside range 0..2") end
            if gravity ~= nil and (gravity ~= math.floor(gravity) or gravity < 0 or gravity > 3) then return jerr("gravityMode outside range 0..3") end
            if air ~= nil and (air ~= math.floor(air) or air < 0 or air > 4) then return jerr("airMode outside range 0..4") end
            if req.paused ~= nil and type(req.paused) ~= "boolean" then return jerr("paused must be boolean") end
            if edge ~= nil then sim.edgeMode(edge) end
            if gravity ~= nil then sim.gravityMode(gravity) end
            if air ~= nil then sim.airMode(air) end
            if req.paused ~= nil then sim.paused(req.paused) end
            return jok("setSimulationModes")
        elseif action == "getSimulationModes" then
            return jok("getSimulationModes",
                ',"edgeMode":' .. jnum(sim.edgeMode())
                .. ',"gravityMode":' .. jnum(sim.gravityMode())
                .. ',"airMode":' .. jnum(sim.airMode())
                .. ',"paused":' .. (sim.paused() and "true" or "false"))
        elseif action == "clearAll" then
            if sim.clearSim then pcall(sim.clearSim) end
            return jok("clearAll")


        elseif action == "executeLua" then
            local code = req.code or req.lua
            if not code then return jerr("missing code") end
            local fn, err = loadstring(code)
            if not fn then return jerr("load error", ',"detail":' .. jesc(err)) end
            local rok, rval = pcall(fn)
            if not rok then return jerr("runtime", ',"detail":' .. jesc(rval)) end
            return jok("executeLua", ',"result":' .. jesc(rval))

        -- Two-step counterpart to executeLua for code that needs a real
        -- interface-event context (ren.*, tpt.screenshot, sim.paused, ...;
        -- see the comment above onTick()). runInterfaceLua queues the code to
        -- run on the next tick's TickEvent dispatch and returns immediately;
        -- pollInterfaceLua fetches the result once onTick has run it. A
        -- client calls queue then polls (0.05-0.1s intervals; one game tick
        -- is normally enough) -- the same pattern rpg_reload already uses for
        -- R.hotReloadRequested.
        elseif action == "runInterfaceLua" then
            local code = req.code or req.lua
            if not code then return jerr("missing code") end
            local fn, err = loadstring(code)
            if not fn then return jerr("load error", ',"detail":' .. jesc(err)) end
            _G.POWDER_BRIDGE_IFACE_NEXT_ID = (_G.POWDER_BRIDGE_IFACE_NEXT_ID or 0) + 1
            local id = _G.POWDER_BRIDGE_IFACE_NEXT_ID
            table.insert(_G.POWDER_BRIDGE_IFACE_QUEUE, { id = id, fn = fn })
            return jok("runInterfaceLua", ',"id":' .. jnum(id) .. ',"queued":true')

        elseif action == "pollInterfaceLua" then
            local id = tonumber(req.id)
            if not id then return jerr("missing id") end
            local entry = _G.POWDER_BRIDGE_IFACE_RESULTS[id]
            if not entry then
                return jok("pollInterfaceLua", ',"done":false')
            end
            _G.POWDER_BRIDGE_IFACE_RESULTS[id] = nil
            if not entry.ok then
                return jerr("runtime", ',"id":' .. jnum(id) .. ',"detail":' .. jesc(entry.result))
            end
            return jok("pollInterfaceLua", ',"done":true,"result":' .. jesc(entry.result))
        else
            -- Extension dispatch: modules register into _G.PB_EXT at load time.
            local ext = _G.PB_EXT and _G.PB_EXT[action]
            if ext then
                local ectx = {
                    jok = jok, jerr = jerr, jesc = jesc, jnum = jnum,
                    resolveElem = resolveElem, resolveWall = resolveWall,
                    resolveTool = resolveTool,
                }
                local eok, eres = pcall(ext, req, ectx)
                if eok then return eres end
                return jerr("extension error", ',"detail":' .. jesc(eres))
            end
            return jerr("unknown action", ',"action":' .. jesc(action))
        end
    end)
    if not ok then
        log("HANDLER_ERR " .. tostring(res))
        return jerr("handler exception", ',"detail":' .. jesc(res))
    end
    return res
end

-- Port is overridable via POWDER_BRIDGE_PORT so a second, isolated instance
-- (scripts/lab_instance.py) can run its own bridge without colliding with the
-- default session; unset/invalid falls back to the historical default.
local serverPort = tonumber(os.getenv and os.getenv("POWDER_BRIDGE_PORT") or "") or 9876
-- OPT-IN 2026-09-02. The bridge used to call net.listen() unconditionally. On a player's
-- machine that raises a Windows Firewall prompt on first launch and opens a port nobody
-- asked for -- and handleRequest already REJECTS every request when bridgeToken is nil, so
-- listening without a token could never serve anyone anyway. It was pure cost.
-- Enabled by the presence of powder-bridge.token (dev machines and lab_instance.py have
-- one; a downloaded copy does not) or by POWDER_BRIDGE_PORT being set explicitly.
-- This lives in bridge_base.lua rather than the generated autorun.lua so that rebuilding
-- autorun.lua cannot silently undo it -- the previous fix was applied to the generated
-- artifact only, which is exactly how the MAX_CUSTOM_ELEMENTS=40 regression reached a
-- public release.
local bridgeWanted = (bridgeToken ~= nil and bridgeToken ~= "")
              or ((os.getenv and os.getenv("POWDER_BRIDGE_PORT")) and true or false)
local server
local listenOk, err = pcall(function()
    if bridgeWanted then server = net.listen(serverPort, handleRequest) end
end)
if not bridgeWanted then
    log("[INFO] Bridge disabled (no powder-bridge.token). Normal play needs no network.")
elseif listenOk and server then
    _G.POWDER_BRIDGE_SERVER = server
    _G.POWDER_BRIDGE_HANDLER = handleRequest
    log("[OK] HTTP API listening on port " .. tostring(serverPort))
else
    log("[WARN] Could not start HTTP server: " .. tostring(err))
end
