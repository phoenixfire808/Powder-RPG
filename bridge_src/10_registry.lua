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
---
--- `pendingNames`, when given, is a set (UPPERNAME -> true) of every element
--- name in the current boot batch (see queueSpecList below).  A batch entry
--- is validated before ANY entry's elements.allocate() has run (allocation is
--- deferred, see the module header), so two custom elements naming each
--- other -- NA -> NAK, NAK -> NA -- can never both resolve through
--- elements.exists no matter which is checked first: neither is live yet.
--- Without this, that combination fails validation for BOTH names and drops
--- both elements from the boot entirely, which is strictly worse than the
--- dangling-id bug this format replaced (empirically reproduced 2026-09-02,
--- @phase, see scripts/gen_materials_seed.py _EXPLICIT_CORRECTIONS' NA/NAK
--- entries). A target present in `pendingNames` is accepted on trust that its
--- own batch entry will define it; queueSpecList's post-batch transition
--- fixup (below) corrects any reference that was still unresolved -- fell
--- back to NT -- at the moment its own element was actually created.
local function validateTransition(raw, key, pendingNames)
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
    if e then
        if pendingNames and pendingNames[up] then return up, nil end
        return nil, key .. ": " .. e
    end
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

local function validateField(f, raw, pendingNames)
    if f.kind == "str" then
        return PBX.vStr(raw, f.key, f.max)
    elseif f.kind == "int" then
        return PBX.vInt(raw, f.key, f.min, f.max)
    elseif f.kind == "num" then
        return PBX.vNum(raw, f.key, f.min, f.max)
    elseif f.kind == "menu" then
        return validateMenuSection(raw)
    elseif f.kind == "trans" then
        return validateTransition(raw, f.key, pendingNames)
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
local function validateSpec(req, base, lenientBehavior, pendingNames)
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
            local v, e = validateField(f, raw, pendingNames)
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

    -- FOUND WHILE BUILDING 09_isotopes_seed.lua (@isotopes): a `decayer` particle's initial
    -- "life" was never seeded from its own spec.behavior.params.startLife anywhere in this
    -- pipeline -- confirmed by reading every FIELDS/buildElementTable line, not assumed. TPT
    -- creates a new particle with property "life" defaulting to 0 unless the element's own
    -- DefaultProperties.life says otherwise (elements.element(id,{DefaultProperties={life=N}})
    -- is a real, native key -- see src/lua/LuaElements.cpp:513-514/685-687, setDefaultProperties
    -- -- NOT one of this file's own declarative FIELDS, so it silently never got set). Without
    -- this, every decayer particle's very first Update call sees life-rate<=0 and instantly
    -- kills/transmutes itself on the tick after creation -- 20_behaviors.lua's own decayer
    -- comment claims "startLife is metadata only... seeding is 10_registry.lua/defineElement's
    -- job", but that job was never actually implemented. This silently affected the existing
    -- CRPS corpse element (startLife=150, documented as "fades away in a few seconds") the same
    -- way -- it would have vanished on the tick after death instead.
    if spec.behavior and spec.behavior.kind == "decayer" and spec.behavior.params
        and type(spec.behavior.params.startLife) == "number" then
        t.DefaultProperties = { life = spec.behavior.params.startLife }
    end

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

-- Names of every element in `list` (a plain array of raw spec tables), upper-cased,
-- merged into `into` (created if omitted). Used to build the pending-names set below --
-- deliberately a full pre-scan rather than "names seen so far", so a same-batch
-- transition reference resolves regardless of which of the two entries appears first.
local function namesInList(list, into)
    into = into or {}
    if type(list) == "table" then
        for i = 1, #list do
            local raw = list[i]
            if type(raw) == "table" and type(raw.name) == "string" then
                into[string.upper(raw.name)] = true
            end
        end
    end
    return into
end

-- Queue every entry in `list` (a plain array of raw spec tables, e.g. straight out of
-- PBX.load(PERSIST) or the source-controlled seed) whose name is not already claimed in
-- R.byName. Returns (queued, skipped, queuedSpecs). `label` is only for the warn-log text
-- below. `pendingNames` (UPPERNAME -> true) is every name across the whole boot batch --
-- see the do-block below -- and lets a transition target validate against a sibling entry
-- that has not been created yet. Shared by both boot-time sources so a hand-edited
-- persistence file and the source-controlled seed are held to the identical validation bar.
local function queueSpecList(list, label, pendingNames)
    local queued, skipped = 0, 0
    local queuedSpecs = {}
    if type(list) ~= "table" then return 0, 0, queuedSpecs end
    for i = 1, #list do
        local raw = list[i]
        -- Re-validate on load: the source is plain data (JSON on disk, or a Lua literal
        -- another module could edit), PBX.load does no schema checking, and a bad entry
        -- must not be able to take the whole registry down. Behaviour kinds are not
        -- resolvable this early, hence lenientBehavior.
        local ok, spec = pcall(function()
            if type(raw) ~= "table" then error("not a table", 0) end
            local s, _, err = validateSpec(raw, nil, true, pendingNames)
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
            queuedSpecs[#queuedSpecs + 1] = spec
        end
    end
    return queued, skipped, queuedSpecs
end

-- Post-batch transition fixup (@phase escalation, 2026-09-02): scheduleRecreate defers one
-- job per spec, so within a single boot batch it is possible for spec A's job to run before
-- spec B's -- if A's transition names B, A's elements.element() call resolves it while B is
-- still unallocated and resolveTransition's safe fallback (NT, "no transition") silently
-- wins. That is quieter than the validation-time rejection the pendingNames set above fixes,
-- but just as wrong: A would boot with the reference to B silently dropped. Fixed by
-- re-resolving and re-writing every string-named transition field, for every spec actually
-- queued this boot, in ONE job appended after every scheduleRecreate job from both lists --
-- PBX.defer's queue is strict FIFO (00_util.lua pumpJobs: table.remove(jobQueue, 1)), so
-- deferring this after both queueSpecList calls return guarantees it runs after every entry
-- in the batch has had its own create job attempt, regardless of how many ticks that takes.
-- Re-applying an already-correct transition (e.g. a target that was already live, like LAVA)
-- is a harmless no-op write, so this does not need to track which references were pending.
local function scheduleTransitionFixup(specLists)
    local specs = {}
    for j = 1, #specLists do
        local list = specLists[j]
        for i = 1, #list do specs[#specs + 1] = list[i] end
    end
    local hasNamedTransition = false
    for i = 1, #specs do
        local s = specs[i]
        if type(s.highTemperatureTransition) == "string" or type(s.lowTemperatureTransition) == "string" then
            hasNamedTransition = true
            break
        end
    end
    if not hasNamedTransition then return end

    PBX.defer(function()
        PBX.guard(MODULE, function()
            local fixed = 0
            for i = 1, #specs do
                local s = specs[i]
                local ent = R.byName[s.name]
                if ent and ent.id ~= nil and elements.exists(ent.id) then
                    local patch, any = {}, false
                    if type(s.highTemperatureTransition) == "string" then
                        patch.HighTemperatureTransition = resolveTransition(s.highTemperatureTransition)
                        any = true
                    end
                    if type(s.lowTemperatureTransition) == "string" then
                        patch.LowTemperatureTransition = resolveTransition(s.lowTemperatureTransition)
                        any = true
                    end
                    if any then
                        elements.element(ent.id, patch)
                        fixed = fixed + 1
                    end
                end
            end
            PBX.log(MODULE, "boot transition fixup: re-resolved " .. fixed ..
                            " named transition(s) after every batch element had its own " ..
                            "create job attempt")
        end)
    end)
end

-- Post-batch BEHAVIOUR fixup (@isotopes, found live while boot-testing 09_isotopes_seed.lua's
-- own decay chains): the exact same problem scheduleTransitionFixup above already fixed for
-- HighTemperatureTransition/LowTemperatureTransition ALSO applies to any behavior-kind param
-- that names another element -- decayer's `becomes`, emitter's `emits`, grower's `needs` -- but
-- nothing fixed it there. applySpec's def.make(params) resolves that name via PBX.vElem() and
-- BAKES the resolved id into the returned Update closure as an upvalue at the moment the job
-- runs, which (same root cause as the transition case, cited above) can be before the named
-- sibling element's own job has run in the same boot batch. Live-reproduced building this
-- generator's own seed: 22 of 25 decayer chains hit "decayer: invalid becomes 'X', falling back
-- to kill" on a fresh boot, discovered by reading autorun-runtime.log, not assumed. Unlike the
-- transition case, re-writing element PROPERTIES after the fact does not fix an already-wrong
-- Update closure (the closure is immutable once created) -- so this fixup re-runs def.make(params)
-- and RE-INSTALLS the Update function via elements.property(id,"Update",fn), which is safe and
-- idempotent (make() has no side effects beyond returning a closure). Same FIFO-defer-after-both-
-- queueSpecList-calls guarantee as scheduleTransitionFixup, for the identical reason.
-- CHUNKED (not one giant loop like scheduleTransitionFixup above) -- live-observed on a
-- heavily-loaded shared dev box (autorun-runtime.log: "[string \"10_registry.lua\"]:1017:
-- Error: Script not responding", the PRE-EXISTING transition-fixup loop above hitting the
-- same TPT Lua watchdog under that load) that even a ~227-spec single-call loop can trip the
-- watchdog when the host is contended. Only ~25-30 specs ever actually need this fixup (the
-- ones using a name-referencing behavior kind), so this filters ONCE up front, then processes
-- BEHAVIOR_FIXUP_CHUNK of them per tick, re-deferring itself for the remainder -- bounding the
-- wall-clock cost of any single call regardless of total batch size or host contention.
local NAME_REF_BEHAVIOR_KINDS = { decayer = true, emitter = true, grower = true }
local BEHAVIOR_FIXUP_CHUNK = 8
local function scheduleBehaviorFixup(specLists)
    local specs = {}
    for j = 1, #specLists do
        local list = specLists[j]
        for i = 1, #list do
            local s = list[i]
            local b = s.behavior
            if type(b) == "table" and NAME_REF_BEHAVIOR_KINDS[b.kind] then
                specs[#specs + 1] = s
            end
        end
    end
    if #specs == 0 then return end

    local nextIdx, fixed = 1, 0
    local function runChunk()
        PBX.guard(MODULE, function()
            local stop = math.min(nextIdx + BEHAVIOR_FIXUP_CHUNK - 1, #specs)
            for i = nextIdx, stop do
                local s = specs[i]
                local b = s.behavior
                do
                    local ent = R.byName[s.name]
                    if ent and ent.id ~= nil and elements.exists(ent.id) then
                        local def, params = resolveBehavior(b)
                        if def then
                            local fn = def.make(params)
                            if type(fn) == "function" then
                                elements.property(ent.id, "Update", fn)
                                ent.hasUpdate = true
                                fixed = fixed + 1
                            end
                        end
                    end
                end
            end
            nextIdx = stop + 1
            if nextIdx > #specs then
                PBX.log(MODULE, "boot behaviour fixup: re-resolved " .. fixed ..
                                "/" .. #specs .. " name-referencing behaviour(s) " ..
                                "(decayer/emitter/grower) after every batch element had its " ..
                                "own create job attempt")
            end
        end)
        if nextIdx <= #specs then PBX.defer(runChunk) end
    end
    PBX.defer(runChunk)
end

do
    local persistedList = PBX.load(PERSIST)
    local seedList = _G.PBX_MATERIALS_SEED

    -- Every name across BOTH boot-time sources, computed up front (see validateTransition's
    -- doc comment above for why this has to happen before either list is validated).
    local pendingNames = namesInList(persistedList)
    namesInList(seedList, pendingNames)

    local restored, skipped, restoredSpecs = queueSpecList(persistedList, "persisted", pendingNames)

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
    local seedQueued, seedSkipped, seedSpecs = queueSpecList(seedList, "seed", pendingNames)
    restored, skipped = restored + seedQueued, skipped + seedSkipped

    scheduleTransitionFixup({ restoredSpecs, seedSpecs })
    scheduleBehaviorFixup({ restoredSpecs, seedSpecs })

    PBX.log(MODULE, "registry " .. R.VERSION .. " loaded; queued " .. restored ..
                    " element(s) (persisted+seed), skipped " .. skipped)
end
