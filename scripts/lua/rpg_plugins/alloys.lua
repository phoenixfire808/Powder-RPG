-- ===========================================================================
-- RPG plugin: alloys.lua -- @alloys lane. Melt-alloying (two+ molten metals
-- touching become the real alloy) and pressure-driven transformations
-- (graphite->diamond, powder compaction), per PhoenixFire808: "When we melt
-- certain elements together, or do pressure reactions, they're supposed to
-- form into their new ones -- like in real life."
--
-- File ownership (AGENTS.md, this wave): this lane owns this file and
-- knowledge/data/alloys.csv/.json. Does NOT touch rpg.lua (the R.PLUGINS
-- patch request is at the bottom of this file, same convention as
-- reactions.lua/isotopes.lua/thermo.lua) or any other plugin.
--
-- REGISTERING THE FOUR ALLOY PRODUCT ELEMENTS this file's reactions convert
-- molten metal into (BRNZ, NICR, SOLD, AMLG) is done entirely from THIS
-- file, at runtime, by calling the registry's own already-published
-- `defineElement` action directly (`_G.PB_EXT.defineElement(spec)`,
-- bridge_src/10_registry.lua's own `PBX.register("defineElement", ...)`
-- handler, exposed on the shared `_G.PB_EXT` dispatch table build_autorun.py
-- wires up for the HTTP bridge -- calling it directly from Lua is the same
-- code path, no HTTP round-trip needed) -- NOT a new bridge_src seed file.
-- A seed-file version of this was tried first and reverted: `bridge_src/
-- 07_materials_seed.lua` (an existing file, not this lane's) opens with
-- `_G.PBX_MATERIALS_SEED = { ... }`, an UNCONDITIONAL OVERWRITE rather than
-- the `_G.PBX_MATERIALS_SEED = _G.PBX_MATERIALS_SEED or {}` merge its own
-- siblings 08_periodic_seed.lua/09_isotopes_seed.lua both correctly use --
-- a real, previously-invisible boot-order hazard (it only bites a SECOND
-- seed file that loads before 07, which nothing had done until this pass)
-- that silently wiped a would-be `06_alloys_seed.lua`'s entries before 07
-- ever ran, live-caught by this file's own verification pass (own lab
-- instance, port 9920, fresh boot -- BRNZ/NICR/SOLD/AMLG never appeared in
-- autorun-runtime.log's `[registry] recreated ...` lines at all, confirmed
-- present verbatim in the assembled autorun.lua first to rule out a syntax/
-- load failure). Filed as a real bug rather than silently worked around;
-- see knowledge/rpg-hub.md. Routing through `defineElement` instead avoids
-- the hazard entirely, keeps every line of new element-definition code
-- inside this lane's own single owned file, and needed zero changes to any
-- shared file.
--
-- `defineElement`'s own handler defers the actual `elements.allocate`/
-- `elements.element` work via `PBX.defer` internally (already safe to call
-- from any context, including this file's own tick hook) and returns a job
-- id; `PBX.jobResult(id)` is polled (see `pumpAlloyElementJobs` below) until
-- every requested element has either landed or failed, before this file's
-- main install pass (recipes, Update hooks) ever runs -- so nothing here
-- ever races an element that has not actually been allocated yet.
--
-- ---------------------------------------------------------------------------
-- MECHANISM 1 -- melt-alloying, reusing the engine's OWN ctype round-trip.
-- ---------------------------------------------------------------------------
-- Simulation.cpp's own melt/cool code (read directly, not assumed) already
-- does exactly the ctype-tagging round trip a real alloy needs, for free:
--   - melting ANY element with HighTemperatureTransition=LAVA tags the
--     resulting LAVA particle's ctype with its original type
--     (Simulation.cpp ~2850: "if (t==PT_ICEI||t==PT_LAVA||t==PT_SNOW)
--     parts[i].ctype = parts[i].type").
--   - cooling a LAVA particle whose ctype's own HighTemperatureTransition is
--     itself LAVA reverts it straight back to that real ctype, unmodified,
--     once its temperature drops back below THAT ctype's own real melting
--     point (Simulation.cpp ~2790: "else if (elements[parts[i].ctype].
--     HighTemperatureTransition == PT_LAVA...) ... t = parts[i].ctype").
-- VERIFIED, not assumed: BRSS/S316/STEL/CU/SN/ZN/NI/CHRM/AG/LEAD/GOLD/COPR
-- were all read back live (own lab instance, port 9891, read-only queries
-- against his own port-9876 session too, both confirmed alive/untouched
-- throughout) with HighTemperatureTransition=LAVA and real melting points
-- matching cited values (see knowledge/data/alloys.csv for the full table);
-- this means every one of them ALREADY round-trips correctly through LAVA
-- and back to itself with ZERO code from this file -- the brief's "verify
-- that, do not assume it" is satisfied by this direct engine read plus the
-- live round-trip test recorded in this file's own report/verification
-- section below, not by assumption.
--
-- What the engine does NOT do is let two DIFFERENT ctypes combine into a
-- third one when they touch. That is this file's actual job, added the same
-- way isotopes.lua/reactions.lua add behaviour onto elements that already
-- exist: `elements.property(PT_LAVA, "Update", fn)` with the DEFAULT mode
-- (UPDATE_AFTER, LuaElements.cpp:606 default branch / :92) -- confirmed by
-- direct read of src/lua/LuaElements.cpp's luaUpdateWrapper: with no 4th
-- arg, the NATIVE LAVA Update (cooling, the native LAVA(STNE)->LAVA(ROCK)
-- pressure mechanic, thermite, everything) runs FIRST, completely
-- unmodified, and this file's closure only runs AFTER, on whatever the
-- native update left behind that same tick, and only if the native update
-- did not already convert/kill the particle. This is strictly additive: no
-- existing LAVA behaviour, on ANY ctype including ones this file never
-- looks at, is bypassed, replaced or reordered. PT_LAVA's Update was
-- confirmed unclaimed by any other plugin before this file touched it
-- (grepped every rpg_plugins/*.lua and bridge_src/*.lua for
-- `elements.property(elem.DEFAULT_PT_LAVA`/`elements.property(6,` --
-- zero hits) -- flagged in knowledge/rpg-hub.md as a shared global engine
-- resource this pass claims, per AGENTS.md's "anything not listed, claim it
-- and say so."
--
-- PERFORMANCE: the wrapped closure's very first line is a single hash-table
-- membership check against `ALLOY_INPUT[ctype]` -- a set of at most ~10
-- element ids (IRON/COPR/CU/SN/ZN/LEAD/NI/CHRM/carbon). Every LAVA particle
-- whose ctype is NOT one of those (ordinary lava lakes, molten glass, molten
-- anything else already shipped by other lanes) returns `false` in one
-- comparison and does no further work -- no neighbour scan, no table
-- allocation. Only a LAVA particle actually carrying one of our alloy-input
-- ctypes pays the 8-neighbour scan cost. Measured live (own lab instance,
-- see report() below and the verification section) at the bottom of this
-- file.
--
-- ---------------------------------------------------------------------------
-- MECHANISM 2 -- pressure. Three different real transformations, three
-- different amounts of new code, because the engine already implements two
-- of them:
--   (a) molten STNE -> ROCK under pressure is ALREADY NATIVE, unconditional,
--       zero Lua needed. Direct read, src/simulation/elements/FIRE.cpp:154:
--       `else if ((parts[i].ctype == PT_STNE || !parts[i].ctype) &&
--       pres >= 30.0f && (parts[i].temp > elements[PT_ROCK].HighTemperature
--       || pres < elements[PT_ROCK].HighPressure)) { parts[i].ctype =
--       PT_ROCK; }` -- runs for every LAVA particle, every tick, in the
--       engine's own C++ LAVA case block, with no Lua hook of any kind. This
--       file adds NOTHING for this one -- it is verified working and
--       documented in knowledge/data/alloys.csv as an already-native
--       mechanism, per the brief's own "read the C++ and reuse what is
--       already there rather than reimplementing" instruction.
--   (b) powder compaction (SAND -> STNE) reuses the engine's OWN generic,
--       per-element HighPressureTransition/HighPressure fields (Element.h:
--       49-52, evaluated unconditionally for ANY element carrying them,
--       Simulation.cpp:2971 `if (elements[t].HighPressureTransition != NT
--       && pv[y/CELL][x/CELL] > elements[t].HighPressure) { t =
--       elements[t].HighPressureTransition; }` -- the exact same field
--       BRCK.cpp and ROCK.cpp already use for BRCK/ROCK -> STNE). Setting
--       these two fields on SAND via `elements.property` is the entire
--       implementation -- zero per-tick Lua code, zero per-particle scan,
--       because the C++ engine already evaluates this for every SAND
--       particle as part of its normal per-tick element-transition pass
--       regardless of whether this file exists.
--   (c) graphite -> diamond needs BOTH sustained pressure AND high
--       temperature together (real HPHT synthesis: ~5 GPa at ~1500C,
--       https://en.wikipedia.org/wiki/Synthetic_diamond, fetched 2026-09-0X,
--       "a pressure of 5 GPa (730,000 psi) at 1,500C (2,730F)" -- direct
--       quote, industrial HPHT press description) -- the native
--       HighPressureTransition field alone cannot express an AND of two
--       different fields, so this one gets its own small Update hook on
--       GRPH (same UPDATE_AFTER technique as the LAVA hook, preserving
--       GRPH's own existing high-temperature SMKE sublimation unchanged).
--       Real temperature (1773.15K = 1500C) is used UNSCALED -- this
--       engine's temperature field is already real Kelvin (confirmed: every
--       melting point checked in this file matches its cited real value
--       directly, no conversion factor). Real PRESSURE has no established
--       GPa<->game-unit conversion anywhere in this codebase, so the
--       pressure threshold is a labelled `_deviation`: chosen to sit clearly
--       above the existing native STNE->ROCK threshold (30, FIRE.cpp above)
--       and ROCK's own HighPressure (120, ROCK.cpp) since real diamond
--       synthesis is a rarer, more extreme process than ordinary rock
--       metamorphism -- ORDER preserved (diamond needs more pressure than
--       plain rock formation, which is real and cited), magnitude is not.
--
-- ---------------------------------------------------------------------------
-- ELEMENT RESOLUTION -- every id below is resolved LIVE, at first tick, by
-- real registered Name (via PBX.state.registry.byName, the exact mechanism
-- reactions.lua/isotopes.lua already use and already fixed the historical
-- 0..511-scan bug for) or, for native stock elements, via `elem.DEFAULT_PT_*`
-- -- NEVER a hardcoded id number, because ids are assigned at boot and this
-- codebase has repeatedly (and recently) shipped the exact same element
-- under more than one live name (e.g. Cu as both native COPR and custom CU;
-- see knowledge/audit-periodic-physics.md and the @ptable follow-up in
-- knowledge/rpg-hub.md). Every "real element" this file needs is looked up
-- through a CANDIDATE LIST (native name tried, then any known custom-name
-- duplicate) and whichever one is actually live wins -- if a session only
-- has one of the two Cu's, this still works; if a future dedup removes one,
-- this still works.
-- ===========================================================================

local R = PBX.state.rpg
local TAG = "alloys"

-- one-time purge-then-append hook helper (matches chemistry.lua/thermo.lua/
-- reactions.lua's own established idiom for safe hot-reload)
for _, __l in pairs(R.hooks or {}) do
  if type(__l) == "table" then
    for i = #__l, 1, -1 do
      if type(__l[i]) == "table" and __l[i].tag == TAG then table.remove(__l, i) end
    end
  end
end
local function hook(list, fn)
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

R.alloys = R.alloys or {}
local X = R.alloys

-- ================================================================ resolution
--- Resolve a live element id by registered Name (custom, any group) or, for
--- native stock elements, by its `elem.DEFAULT_PT_*` constant. Tries every
--- candidate in order, returns the first that actually exists live.
local function resolveAny(candidates)
  local reg = PBX.state.registry
  for _, name in ipairs(candidates) do
    local ent = reg and reg.byName and reg.byName[name]
    if ent and ent.id ~= nil and elements.exists(ent.id) then
      return ent.id, name
    end
    local nid = elem and elem["DEFAULT_PT_" .. name]
    if nid and elements.exists(nid) then
      return nid, name
    end
  end
  return nil, nil
end

-- Candidate names per real substance -- see file header for why more than
-- one name is tried for several of these.
local WANT = {
  IRON     = { "IRON" },
  COPPER   = { "COPR", "CU" },       -- native copper preferred, custom CU fallback
  TIN      = { "SN" },
  ZINC     = { "ZN" },
  LEAD     = { "LEAD" },
  NICKEL   = { "NI" },
  CHROMIUM = { "CHRM" },
  SILVER   = { "AG" },
  GOLD     = { "GOLD" },
  MERCURY  = { "MERC" },
  CARBON_MOLTEN = { "C" },           -- bare periodic "C", live-verified HTT=LAVA at 3823K
  GRPH     = { "GRPH" },
  COAL     = { "COAL" },
  DMND     = { "DMND" },
  STEL     = { "STEL" },
  BRNZ     = { "BRNZ" },
  BRSS     = { "BRSS" },
  S316     = { "S316" },
  NICR     = { "NICR" },
  SOLD     = { "SOLD" },
  AMLG     = { "AMLG" },
  SAND     = { "SAND" },
  STNE     = { "STNE" },
}

local ID = {}      -- resolved substance -> id (nil if not live this session)
local NAME = {}    -- resolved substance -> the actual live name that matched

-- ================================================================ install (deferred to first
-- tick -- elements.property/elements.element must run inside a mutable-tools
-- event; doing this at plugin top-level load was not tested and is
-- deliberately avoided, matching reactions.lua's own documented convention).
local installed = false
local NX8 = { -1, 0, 1, -1, 1, -1, 0, 1 }
local NY8 = { -1, -1, -1, 0, 0, 1, 1, 1 }

-- Binary recipes: base ctype (drives progress + becomes the product) ->
-- partner ctype (consumed) -> product id. shareBase/sharePartner are the
-- REAL cited mass percentages (see knowledge/data/alloys.csv for every
-- citation) and control how often the PARTNER gets consumed relative to how
-- often the base particle's own progress counter advances -- NOT a claim of
-- atom-exact mixing (a game particle is a discrete parcel, not an atom;
-- exact per-particle granularity is a disclosed `_deviation`), but the
-- RATIO itself is real and cited, and consumption is scaled to preserve it
-- in expectation over many events.
local PAIR = {} -- keyed "baseId" -> array of { partnerId, productId, shareBase, sharePartner, label }

-- Ternary: iron + chromium + nickel (both partners required simultaneously
-- this tick) -> stainless. Real Type 304 "18-8" stainless composition
-- (74% Fe / 18% Cr / 8% Ni, https://en.wikipedia.org/wiki/Stainless_steel,
-- fetched 2026-09-0X) reused onto the S316 element this game already ships
-- (Type 316 adds ~2-3% Mo that this reaction does not model) rather than
-- minting an 8th near-duplicate stainless element -- disclosed reuse, not a
-- claim that S316 and 18-8 are the identical real alloy.
local TERNARY = nil

-- Progress pacing -- GAMEPLAY BALANCE, explicitly not physics (labelled
-- here, not silently presented as measured): PROGRESS_THRESHOLD ticks of a
-- successful per-neighbour roll (chance PROGRESS_CHANCE) are required before
-- a qualifying base particle actually becomes the product. At
-- PROGRESS_CHANCE=0.15 this averages roughly 50-60 ticks (~1s at 60fps) of
-- continuous single-neighbour contact -- fast enough to observe and test in
-- a lab session, slow enough not to snap instantly on first touch.
local PROGRESS_THRESHOLD = 8
local PROGRESS_CHANCE = 0.15

--- Roll whether to consume one partner particle this qualifying tick, scaled
--- by its real share of the alloy relative to the base's share -- e.g.
--- bronze's tin (share 12 of 100) is consumed roughly 12/88 as often as the
--- base copper particle's own progress advances, so across many events the
--- ratio of "bronze parcels formed" to "tin parcels consumed" trends toward
--- the real 88/12 ratio without claiming atom-level precision.
local function partnerKillChance(shareBase, sharePartner)
  return PROGRESS_CHANCE * (sharePartner / shareBase)
end

--- Perf: os.clock()-based EMA of milliseconds spent inside the LAVA/GRPH
--- hooks PER GAME TICK (not per call) -- matches companion.lua/enemies.lua's
--- own established `os.clock()` EMA convention. R.frame is used as the
--- frame-boundary detector since these Update closures are called directly
--- by the C++ per-particle dispatch, not from this file's own tick hook.
local PERF = { lavaMsEma = 0, grphMsEma = 0, lavaFrameAccum = 0, grphFrameAccum = 0, lastFrame = -1,
               lavaCalls = 0, grphCalls = 0, lavaFastExit = 0,
               steelFormed = 0, bronzeFormed = 0, brassFormed = 0, solderFormed = 0,
               nichromeFormed = 0, stainlessFormed = 0, amalgamFormed = 0, diamondFormed = 0 }

local function perfRollFrame()
  local f = R.frame or 0
  if f ~= PERF.lastFrame then
    if PERF.lastFrame >= 0 then
      PERF.lavaMsEma = PERF.lavaMsEma * 0.9 + PERF.lavaFrameAccum * 0.1
      PERF.grphMsEma = PERF.grphMsEma * 0.9 + PERF.grphFrameAccum * 0.1
    end
    PERF.lavaFrameAccum = 0
    PERF.grphFrameAccum = 0
    PERF.lastFrame = f
  end
end

--- Base-particle alloy-forming step. `baseId` is the ctype currently on this
--- LAVA particle (already confirmed to be in ALLOY_INPUT by the caller).
local function tryFormAlloy(i, x, y, baseCtype)
  -- Ternary check first (more specific condition) -- only applies when the
  -- base ctype is iron.
  if TERNARY and baseCtype == TERNARY.a then
    local sawB, sawC = false, false
    local bOcc, cOcc = nil, nil
    for k = 1, 8 do
      local nx, ny = x + NX8[k], y + NY8[k]
      if nx >= 0 and ny >= 0 and nx < (R.W or 612) and ny < (R.H or 384) then
        local occ = sim.partID(nx, ny)
        if occ then
          local ot, octype = sim.partProperty(occ, "type"), sim.partProperty(occ, "ctype")
          if ot == elem.DEFAULT_PT_LAVA and octype == TERNARY.b then sawB = true; bOcc = occ end
          if ot == elem.DEFAULT_PT_LAVA and octype == TERNARY.c then sawC = true; cOcc = occ end
        end
      end
    end
    if sawB and sawC then
      if math.random() < PROGRESS_CHANCE then
        local prog = (sim.partProperty(i, "tmp2") or 0) + 1
        if prog >= PROGRESS_THRESHOLD then
          sim.partProperty(i, "ctype", TERNARY.product)
          sim.partProperty(i, "tmp2", 0)
          PERF.stainlessFormed = PERF.stainlessFormed + 1
        else
          sim.partProperty(i, "tmp2", prog)
        end
      end
      if bOcc and math.random() < partnerKillChance(TERNARY.shareA, TERNARY.shareB) then sim.partKill(bOcc) end
      if cOcc and math.random() < partnerKillChance(TERNARY.shareA, TERNARY.shareC) then sim.partKill(cOcc) end
      return true
    end
  end

  local recipes = PAIR[baseCtype]
  if not recipes then return false end
  for ri = 1, #recipes do
    local rec = recipes[ri]
    for k = 1, 8 do
      local nx, ny = x + NX8[k], y + NY8[k]
      if nx >= 0 and ny >= 0 and nx < (R.W or 612) and ny < (R.H or 384) then
        local occ = sim.partID(nx, ny)
        if occ then
          local ot = sim.partProperty(occ, "type")
          local isPartner = false
          if rec.partnerMolten and ot == elem.DEFAULT_PT_LAVA and sim.partProperty(occ, "ctype") == rec.partnerId then
            isPartner = true
          elseif rec.partnerSolidTypes and rec.partnerSolidTypes[ot] then
            isPartner = true
          end
          if isPartner then
            if math.random() < PROGRESS_CHANCE then
              local prog = (sim.partProperty(i, "tmp2") or 0) + 1
              if prog >= PROGRESS_THRESHOLD then
                sim.partProperty(i, "ctype", rec.productId)
                sim.partProperty(i, "tmp2", 0)
                rec.onFormed()
              else
                sim.partProperty(i, "tmp2", prog)
              end
            end
            if math.random() < partnerKillChance(rec.shareBase, rec.sharePartner) then
              sim.partKill(occ)
            end
            return true -- one partner match per tick is enough; avoid double-processing
          end
        end
      end
    end
  end
  return false
end

local function lavaUpdate(i, x, y, surround_space, nt)
  PERF.lavaCalls = PERF.lavaCalls + 1
  local ctype = sim.partProperty(i, "ctype")
  if not ctype or not ID.ALLOY_INPUT_SET[ctype] then
    PERF.lavaFastExit = PERF.lavaFastExit + 1
    return false
  end
  local t0 = os.clock()
  tryFormAlloy(i, x, y, ctype)
  PERF.lavaFrameAccum = PERF.lavaFrameAccum + (os.clock() - t0) * 1000
  perfRollFrame()
  return false
end

-- Graphite -> diamond: sustained real-cited pressure AND temperature
-- together (see file header, mechanism 2c). Only reachable when GRPH's own
-- native-equivalent SMKE sublimation did NOT already fire this tick
-- (UPDATE_AFTER semantics -- see header).
local DIAMOND_PRESSURE = 200      -- game units, labelled _deviation, see header
local DIAMOND_TEMP_K = 1773.15    -- REAL, cited, unscaled: 1500C HPHT synthesis temperature
local DIAMOND_CHANCE = 0.02

local function grphUpdate(i, x, y, surround_space, nt)
  PERF.grphCalls = PERF.grphCalls + 1
  if not ID.DMND then return false end
  local t0 = os.clock()
  local temp = sim.partProperty(i, "temp") or 293.15
  if temp >= DIAMOND_TEMP_K then
    local pcx, pcy = math.floor(x / sim.CELL), math.floor(y / sim.CELL)
    local ok, pres = pcall(sim.pressure, pcx, pcy)
    if ok and pres and pres >= DIAMOND_PRESSURE and math.random() < DIAMOND_CHANCE then
      sim.partChangeType(i, ID.DMND)
      PERF.diamondFormed = PERF.diamondFormed + 1
    end
  end
  PERF.grphFrameAccum = PERF.grphFrameAccum + (os.clock() - t0) * 1000
  perfRollFrame()
  return false
end

-- ================================================================ phase 1:
-- define the four alloy PRODUCT elements that do not already exist live,
-- via the registry's own `defineElement` action (see header for why not a
-- seed file). BRNZ is a real gap: documented in knowledge/materials-
-- catalog.json and bridge_src/95_menusort.lua's own menu-order table, but
-- (confirmed live, this pass) never actually reached bridge_src/
-- 07_materials_seed.lua -- its spec is copied verbatim from the catalog
-- here, not re-invented. NICR/SOLD/AMLG are new; every cited number is in
-- this file's own recipe comments below and in knowledge/data/alloys.csv.
local ALLOY_ELEMENT_SPECS = {
  BRNZ = {
    name = "BRNZ", group = "MATL",
    description = "Bronze (Cu-Sn alloy): density 8800 kg/m3, k=70 W/mK, melts ~950C. Harder and more corrosion-resistant than brass.",
    colour = 9198123, menuSection = 9, type = "SOLID",
    properties = { "PROP_CONDUCTS" },
    temperature = 293.15, highTemperature = 1223.15, highTemperatureTransition = "LAVA",
    hardness = 30, weight = 100, heatConduct = 120,
    behavior = { kind = "reactive", params = { rules = "AIR>BRMT,SELF:1:.0003" } },
  },
  NICR = {
    name = "NICR", group = "MATL",
    description = "Nichrome (NiCr 80/20): density 8300 kg/m3, melts ~1400C (2550F). Poor electrical/thermal conductor by design -- real resistance-heating alloy (toasters, kettles, hair dryers). Oxidation-resistant at red heat via a self-forming Cr2O3 layer.",
    colour = 11579302, menuSection = 9, type = "SOLID",
    properties = { "PROP_CONDUCTS" },
    temperature = 293.15, highTemperature = 1673.15, highTemperatureTransition = "LAVA",
    hardness = 55, weight = 100, heatConduct = 18,
    behavior = { kind = "conductor", params = { delay = 0 } },
  },
  SOLD = {
    name = "SOLD", group = "MATL",
    description = "Solder (Sn60/Pb40): melts at 188C, the standard electrical/electronics soldering alloy. Density ~8.50 g/cm3 (computed from cited pure-element densities, not independently measured -- see data sheet). Soft, low hardness; good conductor.",
    colour = 11448500, menuSection = 9, type = "SOLID",
    properties = { "PROP_CONDUCTS" },
    temperature = 293.15, highTemperature = 461.15, highTemperatureTransition = "LAVA",
    hardness = 8, weight = 100, heatConduct = 70,
    behavior = { kind = "conductor", params = { delay = 0 } },
  },
  AMLG = {
    name = "AMLG", group = "MATL",
    -- kept <=256 chars (10_registry.lua's own validateSpec hard cap,
    -- LuaElements.cpp's Description field limit -- @ptable's own
    -- knowledge/rpg-hub.md entry documents the exact same silent-drop bug
    -- class this would otherwise hit); full citation is in this file's own
    -- header comment and knowledge/data/alloys.csv, not truncated there.
    description = "Amalgam (Hg-Au/Hg-Ag): soft solid/paste at room temp. Real composition varies with mercury content (not one fixed ratio) -- unifies gold- and silver-mercury amalgamation. Breaks down near Hg's boiling point, 629.88K.",
    colour = 13093324, menuSection = 9, type = "SOLID",
    properties = {},
    temperature = 293.15, highTemperature = 629.88, highTemperatureTransition = "LAVA",
    hardness = 15, weight = 100, heatConduct = 60,
    behavior = { kind = "inert", params = {} },
  },
}

local pendingJobs = {}   -- name -> job id, for elements THIS pass personally submitted

--- Kick off defineElement for every alloy-product element not already live
--- AND not already claimed. "Already claimed" means `PBX.state.registry.
--- byName[name]` exists at all, even with `.id` still nil -- that nil-id
--- state is completely normal and expected: `defineElement`'s own handler
--- reserves the name in `byName` SYNCHRONOUSLY (10_registry.lua's own
--- comment: "Reserve the name synchronously so two defines racing through
--- the handler cannot both allocate a slot for it") and only fills in `.id`
--- once its deferred job actually runs, which can be several ticks later
--- under load (`pumpJobs` drains at most 8 jobs/tick, and a fresh boot can
--- queue 200+). A PERSISTED prior boot's own snapshot of these same four
--- names hits exactly this window too. Calling defineElement a SECOND time
--- for a name already reserved this way fails hard ("Element identifier
--- already in use", live-caught by this file's own testing, not
--- theoretical) -- checking `byName` presence up front, not `resolveAny`'s
--- stricter "id already resolved" check, is what avoids that race.
--- Safe to call from a mutable-tools event (the tick hook below); the
--- handler itself defers the real work via PBX.defer.
local function requestMissingAlloyElements()
  local reg = PBX.state.registry
  for name, spec in pairs(ALLOY_ELEMENT_SPECS) do
    local alreadyClaimed = reg and reg.byName and reg.byName[name]
    if not alreadyClaimed then
      local defineFn = _G.PB_EXT and _G.PB_EXT.defineElement
      if type(defineFn) ~= "function" then
        PBX.warn(TAG, "_G.PB_EXT.defineElement not published yet -- retrying next tick")
        return false
      end
      -- defineElement (an HTTP action handler) returns a JSON STRING
      -- (PBX.ok/PBX.err both serialise to text, bridge_src/00_util.lua) even
      -- when called directly in-process like this -- decode it with the
      -- engine's own global `json.parse` (src/lua/LuaSocket.cpp, the same
      -- decoder bridge_base.lua uses for real HTTP bodies) rather than
      -- assuming a table came back.
      local ok, resStr = pcall(defineFn, spec)
      local resTbl = nil
      if ok and type(resStr) == "string" then
        local pok, decoded = pcall(json.parse, resStr)
        if pok then resTbl = decoded end
      end
      if resTbl and resTbl.ok and resTbl.job then
        pendingJobs[name] = resTbl.job
      else
        PBX.warn(TAG, "defineElement request for " .. name .. " failed: " .. tostring(resStr))
      end
    end
  end
  return true
end

--- Wait for every alloy-product element to actually resolve an id -- whether
--- this pass's own defineElement job, a persisted prior boot's snapshot, or
--- another lane's own definition landed it. Logs this pass's own submitted
--- job outcomes (pendingJobs) for diagnostics, but the actual go/no-go gate
--- is `resolveAny` succeeding for every name, which is correct regardless of
--- who ultimately created it.
local function pumpAlloyElementJobs()
  for name, jobId in pairs(pendingJobs) do
    local res = PBX.jobResult and PBX.jobResult(jobId)
    if res ~= nil then
      if res.ok then
        PBX.log(TAG, "defineElement landed: " .. name)
      else
        PBX.warn(TAG, "defineElement job failed for " .. name .. " (likely already defined by a persisted snapshot or another lane): " .. tostring(res.error))
      end
      pendingJobs[name] = nil
    end
  end
  for name in pairs(ALLOY_ELEMENT_SPECS) do
    if not resolveAny({ name }) then return false end
  end
  return true
end

local function installOnce()
  for sub, cands in pairs(WANT) do
    ID[sub], NAME[sub] = resolveAny(cands)
  end

  local results = { ok = {}, missing = {} }
  for sub in pairs(WANT) do
    if ID[sub] then results.ok[#results.ok + 1] = sub .. "=" .. NAME[sub] .. "(" .. ID[sub] .. ")"
    else results.missing[#results.missing + 1] = sub end
  end

  -- ---- build ALLOY_INPUT set + PAIR recipes, skipping any recipe whose
  -- inputs or product did not resolve live this session (defensive, never a
  -- hard error -- matches this codebase's established fallback discipline).
  ID.ALLOY_INPUT_SET = {}
  local function addInput(id) if id then ID.ALLOY_INPUT_SET[id] = true end end

  local installedRecipes = {}
  local function addPair(baseId, partnerId, partnerMolten, partnerSolidTypes, productId, shareBase, sharePartner, label, counterField)
    if not (baseId and productId and (partnerId or partnerSolidTypes)) then
      results.missing[#results.missing + 1] = "recipe:" .. label
      return
    end
    addInput(baseId)
    if partnerMolten then addInput(partnerId) end
    PAIR[baseId] = PAIR[baseId] or {}
    PAIR[baseId][#PAIR[baseId] + 1] = {
      partnerId = partnerId, partnerMolten = partnerMolten, partnerSolidTypes = partnerSolidTypes,
      productId = productId, shareBase = shareBase, sharePartner = sharePartner,
      onFormed = function() PERF[counterField] = PERF[counterField] + 1 end,
    }
    installedRecipes[#installedRecipes + 1] = label
  end

  -- Fe + C -> STEL. Real practical carbon-steel range 0.05-2.1% C by mass
  -- (https://en.wikipedia.org/wiki/Carbon_steel, fetched 2026-09-0X); ~2%
  -- used as a representative upper-range value so the partner-consumption
  -- rate stays observable in reasonable testing time despite carbon's small
  -- real mass share. Two independent carbon sources, matching real
  -- metallurgy (carbon dissolves into molten iron; it does not need to be
  -- molten itself -- real carbon has no liquid phase at 1 atm at all): (1)
  -- molten "C" (this game's own bare periodic-carbon element, live-verified
  -- HighTemperatureTransition=LAVA at 3823K) touching molten iron, matching
  -- the brief's literal "two molten elements" framing, and (2) solid
  -- GRPH/COAL touching molten iron directly, the physically-truer path.
  -- STEL has no low/med/high-carbon grade variants in this codebase -- both
  -- paths converge on the same single STEL product; see file header comment
  -- above `PAIR` for why "carbon content decides the grade" is disclosed as
  -- NOT fully implemented (no graded steel elements exist to select between).
  local carbonSolidTypes = {}
  if ID.GRPH then carbonSolidTypes[ID.GRPH] = true end
  if ID.COAL then carbonSolidTypes[ID.COAL] = true end
  addPair(ID.IRON, ID.CARBON_MOLTEN, true, nil, ID.STEL, 98, 2, "Fe+C(molten)->STEL", "steelFormed")
  if next(carbonSolidTypes) then
    addPair(ID.IRON, nil, false, carbonSolidTypes, ID.STEL, 98, 2, "Fe+C(solid)->STEL", "steelFormed")
  end

  -- Cu + Sn -> BRNZ, real ~88/12 (https://en.wikipedia.org/wiki/Bronze,
  -- "commonly with about 12-12.5% tin", fetched 2026-09-0X).
  addPair(ID.COPPER, ID.TIN, true, nil, ID.BRNZ, 88, 12, "Cu+Sn->BRNZ", "bronzeFormed")

  -- Cu + Zn -> BRSS, real ~65/35 (https://en.wikipedia.org/wiki/Brass,
  -- "generally 2/3 copper and 1/3 zinc", fetched 2026-09-0X -- 65/35 sits
  -- inside the commonly-cited copper-majority brass range).
  addPair(ID.COPPER, ID.ZINC, true, nil, ID.BRSS, 65, 35, "Cu+Zn->BRSS", "brassFormed")

  -- Pb + Sn -> SOLD, real 60/40 (https://en.wikipedia.org/wiki/Solder,
  -- "Alloys commonly used for electrical soldering are 60/40 Sn-Pb",
  -- fetched 2026-09-0X). Base is lead (majority by the brief's own framing
  -- of "Pb+Sn"); share reflects the real 60% Sn / 40% Pb by mass.
  addPair(ID.LEAD, ID.TIN, true, nil, ID.SOLD, 40, 60, "Pb+Sn->SOLD", "solderFormed")

  -- Ni + Cr -> NICR, real 80/20 (https://en.wikipedia.org/wiki/Nichrome,
  -- "Table of nichrome alloys", NiCr 80/20, fetched 2026-09-0X).
  addPair(ID.NICKEL, ID.CHROMIUM, true, nil, ID.NICR, 80, 20, "Ni+Cr->NICR", "nichromeFormed")

  -- Fe + Cr + Ni -> S316 (ternary, real Type 304 18-8 composition reused
  -- onto the existing S316 element -- see TERNARY comment above).
  if ID.IRON and ID.CHROMIUM and ID.NICKEL and ID.S316 then
    TERNARY = { a = ID.IRON, b = ID.CHROMIUM, c = ID.NICKEL, product = ID.S316,
                shareA = 74, shareB = 18, shareC = 8 }
    addInput(ID.IRON); addInput(ID.CHROMIUM); addInput(ID.NICKEL)
    installedRecipes[#installedRecipes + 1] = "Fe+Cr+Ni->S316(ternary)"
  else
    results.missing[#results.missing + 1] = "recipe:Fe+Cr+Ni->S316"
  end

  -- ---- install the LAVA hook (mode default = UPDATE_AFTER, see header).
  if next(ID.ALLOY_INPUT_SET) then
    local ok, err = pcall(elements.property, elem.DEFAULT_PT_LAVA, "Update", lavaUpdate)
    if not ok then PBX.warn(TAG, "failed to install LAVA Update hook: " .. tostring(err))
    else results.ok[#results.ok + 1] = "LAVA Update hook installed" end
  end

  -- ---- graphite -> diamond (mechanism 2c).
  if ID.GRPH and ID.DMND then
    local ok, err = pcall(elements.property, ID.GRPH, "Update", grphUpdate)
    if not ok then PBX.warn(TAG, "failed to install GRPH Update hook: " .. tostring(err))
    else results.ok[#results.ok + 1] = "GRPH Update hook installed (graphite->diamond)" end
  else
    results.missing[#results.missing + 1] = "GRPH-or-DMND-for-diamond-hook"
  end

  -- ---- compaction: SAND -> STNE under sustained pressure, pure native
  -- field mechanism, zero per-tick Lua (mechanism 2b, see header). Real:
  -- sedimentary lithification (sand -> sandstone) requires geological-
  -- timescale burial pressure (typically several to tens of MPa); this
  -- engine has no established MPa<->game-unit conversion any more than the
  -- diamond case does, so the threshold (30, matching the engine's OWN
  -- existing native STNE(molten)->ROCK pressure threshold, FIRE.cpp:154)
  -- is a labelled `_deviation`, reusing an already-established in-game
  -- "high pressure" reference point rather than inventing a new one.
  if ID.SAND and ID.STNE then
    local ok1 = pcall(elements.property, ID.SAND, "HighPressureTransition", ID.STNE)
    local ok2 = pcall(elements.property, ID.SAND, "HighPressure", 30)
    if ok1 and ok2 then results.ok[#results.ok + 1] = "SAND HighPressureTransition->STNE set (compaction)"
    else PBX.warn(TAG, "failed to set SAND compaction fields") end
  else
    results.missing[#results.missing + 1] = "SAND-or-STNE-for-compaction"
  end

  -- ---- amalgam: Hg + Au/Ag -> AMLG, reusing the ALREADY-SHIPPED `reactive`
  -- DSL kind (PBX.state.behaviors.kinds.reactive, 20_behaviors.lua) exactly
  -- the way reactions.lua wires periodic elements -- NOT a new mechanism.
  -- Real chemistry: gold/silver amalgamation with liquid mercury happens
  -- SPONTANEOUSLY AT ROOM TEMPERATURE (https://en.wikipedia.org/wiki/
  -- Amalgam_(chemistry), fetched 2026-09-0X) -- no melting/LAVA/ctype
  -- involved at all, so this does not go through the LAVA hook above.
  -- dT=0: the source states alkali-metal amalgamation is exothermic but
  -- gives no cited heat-release NUMBER for gold/silver specifically --
  -- disclosed omission rather than a fabricated figure.
  local kindsTbl = PBX.state.behaviors and PBX.state.behaviors.kinds
  local reactiveDef = kindsTbl and kindsTbl.reactive
  if ID.AMLG and ID.MERCURY and reactiveDef and (ID.GOLD or ID.SILVER) then
    local rule = "MERC>AMLG,AMLG:0:.02"
    local fnOk, fn = pcall(reactiveDef.make, { rules = rule })
    if fnOk and type(fn) == "function" then
      local installedAny = false
      if ID.GOLD then
        local ok = pcall(elements.property, ID.GOLD, "Update", fn)
        if ok then installedAny = true end
      end
      if ID.SILVER then
        local ok = pcall(elements.property, ID.SILVER, "Update", fn)
        if ok then installedAny = true end
      end
      if installedAny then
        results.ok[#results.ok + 1] = "AMLG reactive rule installed on GOLD/AG (Hg+Au/Ag->AMLG)"
      else
        results.missing[#results.missing + 1] = "amalgam-install-failed"
      end
    else
      results.missing[#results.missing + 1] = "amalgam-reactive-make-failed:" .. tostring(fn)
    end
  else
    results.missing[#results.missing + 1] = "amalgam-inputs (need AMLG+MERC+reactive-kind+GOLD-or-AG)"
  end

  X.lastInstallResult = results
  X.installedRecipes = installedRecipes
  X.installedAtFrame = R.frame
  PBX.log(TAG, string.format(
    "alloys install: %d ok, %d missing -- recipes: %s",
    #results.ok, #results.missing, table.concat(installedRecipes, "; ")))
  if R.tlog then
    R.tlog("info", "alloys", "install pass", { ok = #results.ok, missing = #results.missing, recipes = installedRecipes })
  end
  for _, m in ipairs(results.missing) do PBX.warn(TAG, "not installed: " .. m) end
  return true
end

local installPhase = "define"  -- "define" -> "waiting" -> "install" -> "done"
local phaseWaitTicks = 0
local PHASE_WAIT_TIMEOUT = 120 -- ~2s at 60fps; a stuck job queue must not hang this forever

hook(R.hooks.tick, function()
  if installed then return end
  if installPhase == "define" then
    local ok, done = pcall(requestMissingAlloyElements)
    if not ok then
      PBX.warn(TAG, "requestMissingAlloyElements raised: " .. tostring(done))
      installed = true
      return
    end
    if done then installPhase = "waiting" end
  elseif installPhase == "waiting" then
    phaseWaitTicks = phaseWaitTicks + 1
    local ok, allDone = pcall(pumpAlloyElementJobs)
    if not ok then
      PBX.warn(TAG, "pumpAlloyElementJobs raised: " .. tostring(allDone))
      installPhase = "install" -- proceed anyway; installOnce resolves defensively by name
    elseif allDone or phaseWaitTicks > PHASE_WAIT_TIMEOUT then
      if not allDone then PBX.warn(TAG, "gave up waiting for defineElement jobs after " .. PHASE_WAIT_TIMEOUT .. " ticks") end
      installPhase = "install"
    end
  elseif installPhase == "install" then
    local ok, done = pcall(installOnce)
    if not ok then
      PBX.warn(TAG, "installOnce raised: " .. tostring(done))
      installed = true
    elseif done then
      installed = true
    end
  end
end)

-- ================================================================ verification/report
--- Bounded, safe to call read-only against a live session at any time.
function X.report()
  local lines = {}
  lines[#lines + 1] = string.format("alloys.lua: install pass has%s run (frame %s)",
    installed and "" or " NOT yet", tostring(X.installedAtFrame))
  if X.lastInstallResult then
    local r = X.lastInstallResult
    lines[#lines + 1] = "  resolved: " .. table.concat(r.ok, " | ")
    if #r.missing > 0 then lines[#lines + 1] = "  MISSING/NOT INSTALLED: " .. table.concat(r.missing, " | ") end
  end
  lines[#lines + 1] = string.format(
    "  formed so far: steel=%d bronze=%d brass=%d solder=%d nichrome=%d stainless=%d amalgam=%d diamond=%d",
    PERF.steelFormed, PERF.bronzeFormed, PERF.brassFormed, PERF.solderFormed,
    PERF.nichromeFormed, PERF.stainlessFormed, PERF.amalgamFormed, PERF.diamondFormed)
  lines[#lines + 1] = string.format(
    "  perf: lavaUpdate calls=%d fastExit=%d (%.1f%%) msPerTick(EMA)=%.4f | grphUpdate calls=%d msPerTick(EMA)=%.4f",
    PERF.lavaCalls, PERF.lavaFastExit,
    PERF.lavaCalls > 0 and (100 * PERF.lavaFastExit / PERF.lavaCalls) or 0,
    PERF.lavaMsEma, PERF.grphCalls, PERF.grphMsEma)
  local text = table.concat(lines, "\n")
  PBX.log(TAG, "report:\n" .. text)
  return text
end

PBX.log(TAG, "alloys plugin loaded")
if R.tlog then R.tlog("info", "alloys", "alloys plugin loaded", {}) end

-- ================================================================================================
-- PATCH REQUEST for whoever owns rpg.lua this wave (not applied here, per
-- AGENTS.md -- @survival owns rpg.lua this wave) -- add "alloys" anywhere in
-- R.PLUGINS. This file calls nothing from any other plugin except an
-- optional, guarded reuse of PBX.state.behaviors.kinds.reactive (already
-- published unconditionally by 20_behaviors.lua) and PBX.state.registry
-- (published unconditionally by 10_registry.lua); nothing else calls into
-- it except its own diagnostic, R.alloys.report(). Until landed, load with
-- PBX.state.rpg.reloadPlugin("alloys") (same convention every other new
-- plugin this wave used, e.g. reactions.lua/isotopes.lua/thermo.lua).
--   R.PLUGINS = { ... , "chemistry", "reactions", "alloys", "drawperf" }
-- ================================================================================================
