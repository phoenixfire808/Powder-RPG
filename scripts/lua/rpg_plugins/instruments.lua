-- Lab instrumentation plugin (R.sandboxMode only). Owns: the "I" toggle, the INSTRUMENTS panel
-- (Geiger counter / Multimeter / Thermometer+Calorimeter / Composition scanner / Reaction log)
-- and R.instr.
--
-- WHY THIS EXISTS: PhoenixFire808, verbatim -- "All of the physical interactions in the game
-- need to be completely accurate... we want more detail when we're doing our tests, when we're
-- doing our reactions in the sandbox. We want information about radiation, power, energy,
-- electrons, thickness. We want it to be more interactive." Sandbox today (sandbox.lua) gives a
-- cursor probe with only temperature and pressure -- this file is the rest of the lab bench.
--
-- NON-NEGOTIABLE, per the task brief: no fabricated numbers. Every reading below is either (a)
-- read directly from the live simulation (sim.partProperty/elem.property/R.power.grids), (b) a
-- bounded, honestly-labelled DERIVATION of (a) with the derivation stated in the label itself, or
-- (c) an explicit "not modelled by this engine" disclosure where a real unit (volts, amps, ohms,
-- absolute kilograms) does not actually exist anywhere in this simulation. Every quantity that
-- looks physical and ISN'T cited real-world physics says so in its own label -- see the Multimeter
-- and Composition sections below for the two places this matters most.
--
-- ACCESSIBILITY (his hand is broken -- verbatim: F-keys and chords are out, plain letters are
-- fine, and "few, well-placed controls, not a strip of them"). Every action here has a mouse
-- path (a persistent on-screen tab, five in-panel tab buttons, click-to-probe, drag-to-select,
-- one Pin button, one X per pinned row) -- letter keys are ACCELERATORS for the same actions, not
-- the only path to any of them, and there are exactly six: I (toggle panel), G/M/T/C/L (jump to a
-- tab, only consumed while the panel is open), P (pin the current selection). No F-key, no chord.
--
-- PERFORMANCE (hard constraint, his frame budget is already over). Nothing here is an unbounded
-- per-frame scan over all particles:
--   - every measurement is over a SELECTED region, clamped to MAX_REGION_W x MAX_REGION_H
--     (90x60 = 5400 cells) at selection time (clampRegion below);
--   - the active (unpinned) selection recomputes on a throttle (ACTIVE_THROTTLE = 8 ticks), not
--     every frame;
--   - pinned readouts share ONE more scan every PIN_THROTTLE (=30) ticks, round-robin across
--     pins (advancePin below) -- pin COUNT never multiplies per-frame cost, only how often any
--     one pin's own number goes stale (capped at MAX_PINS = 3);
--   - sim.partID/sim.partProperty/elem.property reads used throughout are all confirmed safe
--     from any hook context (no AssertInterfaceEvent guard) per sandbox.lua's own header, which
--     read src/lua/LuaSimulation.cpp/LuaInterface.cpp directly -- this file reuses that finding
--     rather than re-deriving it.
--
-- RADIOACTIVITY MODEL (verified against the engine source directly, not assumed): a radioactive
-- element carries the real, engine-native `PROP_RADIOACTIVE` flag on its Properties word
-- (confirmed: src/simulation/elements/URAN.cpp `Properties = TYPE_PART | PROP_RADIOACTIVE`; also
-- set on PLUT/POLO/PRMT/UO2/FIGH/STKM and this project's own AM24/CO60/CF25/UO2). The only place
-- that flag actually DOES anything today is direct-contact player damage
-- (src/simulation/elements/STKM.cpp:668-669, `if (elements[TYP(r)].Properties&PROP_RADIOACTIVE)
-- damage++` -- literal pixel contact, no radius, no falloff, no shielding). There is no native
-- flux/dose model to read. So the Geiger counter here reports two REAL, DIRECTLY MEASURED things
-- instead of inventing a becquerel figure: (1) a census of PROP_RADIOACTIVE particles physically
-- present in the sensed region (a genuine source count) and (2) a live count of PHOT/NEUT
-- particles present in that region -- the actual ionizing-radiation carrier particles this
-- engine's own emitter behaviors (AM24/CO60/CF25/UO2, real per-isotope decayers) spawn. That
-- second count is where shielding becomes real and observable: LEAD and CNCR are registered with
-- Properties={} (no PROP_PHOTPASS/PROP_NEUTPASS -- confirmed by direct read of
-- bridge_src/07_materials_seed.lua), so the engine's own collision code stops PHOT/NEUT dead
-- against them, exactly like real gamma/neutron shielding. WATR is registered
-- PROP_NEUTPASS|PROP_PHOTPASS (src/simulation/elements/WATR.cpp:35) -- i.e. this engine's water
-- is fully transparent to both, the opposite of real water's own shielding behaviour. That is
-- disclosed in the panel text itself, not silently "corrected" by fabricating an attenuation
-- coefficient this engine doesn't have.
--
-- MULTIMETER MODEL: R.power.grids (machines.lua, @power) tracks generation/load/battery in real
-- watts, derived from real per-generator measurements (turbine steam hits, TEG delta-T, etc, per
-- that file's own header) -- exposed here properly (probed-machine grid id, gen/load/net W,
-- powered bool, battery stored/capacity). Voltage, current and resistance are NOT modelled
-- anywhere in this engine -- confirmed by reading machines.lua/machines2.lua end to end for
-- "volt"/"current"/"resistance"/"amp", zero hits outside comments about water current speed and
-- unrelated flavour text. Inventing a nominal voltage to back-derive amps/ohms from the real
-- wattage would be exactly the "believable-looking wrong number" the brief forbids, so this file
-- does not. What IS real and reported instead, clearly labelled as a proxy and not an ampere
-- figure: a live count of SPRK (spark/charge-carrier) particles in the probed area -- the actual
-- discrete objects this engine uses to carry a charge along a wire.
--
-- THERMOMETER / CALORIMETER MODEL: temperature (K) is a direct sim.partProperty(id,"temp") read,
-- always real. The "energy absorbed while temperature holds flat" signal the brief specifically
-- asks for (watching water sit at 373K while boiling) reuses thermo.lua's (@thermo) own real,
-- already-shipped per-particle latent-heat debt counter -- `tmp2` on WATR/WTRV/ICEI/SNOW, target
-- ticks TARGET_BOIL=81 / TARGET_MELT=12 (thermo.lua's own header: BASE_TICKS=15 times the real
-- ratio 2257/418=5.40 for vaporisation and 334/418=0.80 for fusion, both against water's own
-- cited real figures 4.18 kJ/kg/K, 2257 kJ/kg, 334 kJ/kg). tmp2 is READ ONLY here, never written
-- -- this file has no write access to thermo.lua's own state machine. The two target constants
-- are copied from thermo.lua's own committed header as of this pass (cited above) rather than
-- fabricated; thermo.lua does not currently export them on R.thermo, so a staleness risk exists
-- if @thermo ever changes BASE_TICKS -- flagged as a follow-up request in knowledge/rpg-hub.md,
-- not hidden.
--
-- COMPOSITION SCANNER MODEL: per-element particle counts and percentages are direct counts, always
-- real. "Mass" is reported as a WEIGHT INDEX -- the sum of each particle's real, engine-native
-- `Weight` property (Element.cpp's own StructProperty, 0-100 relative scale used by the engine's
-- own gravity/pressure code) -- explicitly labelled as engine-relative units, NOT kilograms,
-- because this simulation has no established real-world volume-per-pixel constant anywhere in the
-- codebase (grepped for one; confirmed absent) -- inventing "1 pixel = N litres" to convert Weight
-- into a kilogram figure would be fabrication. Thickness is a direct, real per-column pixel count
-- (topmost to bottommost occupied cell in each column of the selection) -- reported in pixels,
-- the simulation's own native unit, not converted to a real length for the same reason.
--
-- REACTION LOG MODEL: the engine exposes no "a reaction just fired" event to Lua. What IS real
-- and directly observable: comparing a region's own particle-type grid between two throttled
-- samples. Any cell whose type genuinely changed (A at tick T, B at tick T+throttle, same pixel)
-- is a real, engine-caused transformation -- logged as "(x,y): A -> B" with the tick number, which
-- is exactly what phase-change/reactive-kind code paths in this engine actually do to a particle.
-- Appearances/disappearances (a consumed or newly spawned reactant) are counted in aggregate
-- rather than claimed as a specific pairing, since this file cannot see which neighbour caused a
-- change -- reporting a specific "with" reactant beyond what is directly observed would be a
-- believable-looking guess, which the brief explicitly rules out.
local R = PBX.state.rpg
local TAG = "instruments"
-- Same reload-safe hook-dedup every plugin in this project uses (see sandbox.lua's own comment
-- for the 2026-09-02 bug this pattern fixes -- a plugin's second hook silently deleting its
-- first). Runs once per load, across every hook list, before this file registers anything.
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
for _, name in ipairs({ "sandboxKey", "sandboxMouseDown", "sandboxMouseUp", "sandboxMouseMove", "sandboxDrawHUD", "sandboxTick" }) do
  R.hooks[name] = R.hooks[name] or {}
end

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local band = bit and bit.band
local W, H = R.W or 612, R.H or 384

-- ================================================================ tunables (see header for the perf reasoning)
local MAX_REGION_W, MAX_REGION_H = 90, 60      -- clamp any dragged selection to this many cells
local POINT_RADIUS = 10                          -- sensing radius (px) around a single-click point probe
local ACTIVE_THROTTLE = 8                        -- ticks between recomputes of the current (unpinned) selection
local PIN_THROTTLE = 30                          -- ticks between recomputes of ONE pinned readout (round-robin)
local MAX_PINS = 3
local MAX_LOG_LINES = 60
local THERMO_TARGET_BOIL, THERMO_TARGET_MELT = 81, 12   -- cited from thermo.lua's own header, see file header above

local TABS = { "geiger", "multimeter", "thermo", "comp", "log" }
local TAB_LABEL = { geiger = "GEIGER", multimeter = "MULTIMETER", thermo = "THERMO", comp = "COMPOSITION", log = "REACTION LOG" }
local TAB_KEY = { g = "geiger", m = "multimeter", t = "thermo", c = "comp", l = "log" }

-- ================================================================ persistent state (survives hot-reload, on R.*)
R.instr = R.instr or {
  panelOpen = false,
  tab = "geiger",
  mx = 0, my = 0,
  dragging = false, dragStart = nil, dragCur = nil,
  selMode = nil,          -- "point" | "region" | nil
  selPoint = nil,          -- { x, y }
  selRegion = nil,          -- { x0, y0, x1, y1 }
  live = {},                -- per-tab cache for the current (unpinned) selection: live[tab] = { result=, prevAvgT=, prevAt=, grid=, lastDiff= }
  pins = {},                -- { { id=, tab=, mode=, point=/region=, result=, prevAvgT=, prevAt=, grid=, lastDiff= }, ... }
  nextPinId = 1,
  pinCursor = 1,
  log = {},                 -- reaction-log ring buffer, newest first
  tick = 0,
  radCache = {},            -- elementTypeId -> bool PROP_RADIOACTIVE, resolved once per id
}
local S = R.instr

-- ================================================================ small real-measurement helpers
local function isRadioactiveElem(t)
  if t == nil then return false end
  local v = S.radCache[t]
  if v ~= nil then return v end
  local ok, props = pcall(elem.property, t, "Properties")
  v = (ok and type(props) == "number" and band and elem.PROP_RADIOACTIVE and band(props, elem.PROP_RADIOACTIVE) ~= 0) or false
  S.radCache[t] = v
  return v
end

local IDS = {}   -- lazily resolved element ids, cached (custom ids replay onto a later tick -- see sbmaterials.lua's own idcache-self-heal comment; re-resolve on demand, never memoize a nil forever)
local function eid(name)
  local v = IDS[name]
  if v then return v end
  v = R.eid(name)
  if v then IDS[name] = v end
  return v
end

local function clampRegion(x0, y0, x1, y1)
  x0 = max(0, floor(min(x0, x1)))
  y0 = max(0, floor(min(y0, y1)))
  x1 = min(W - 1, floor(max(x0, x1)))
  y1 = min(H - 1, floor(max(y0, y1)))
  if x1 - x0 + 1 > MAX_REGION_W then x1 = x0 + MAX_REGION_W - 1 end
  if y1 - y0 + 1 > MAX_REGION_H then y1 = y0 + MAX_REGION_H - 1 end
  return x0, y0, x1, y1
end

local function pointRegion(x, y, r)
  return clampRegion(x - r, y - r, x + r, y + r)
end

-- ================================================================ reaction-log shared diff engine (also feeds thermo's "phase-change events" readout)
local function scanTypeGrid(x0, y0, x1, y1)
  local w = x1 - x0 + 1
  local grid = {}
  for y = y0, y1 do
    local row = (y - y0) * w
    for x = x0, x1 do
      local ok, pid = pcall(sim.partID, x, y)
      local t = 0
      if ok and pid then
        local okt, ty = pcall(sim.partProperty, pid, "type")
        if okt and ty then t = ty end
      end
      grid[row + (x - x0)] = t
    end
  end
  return grid, w
end

-- container: the S.live[...] entry or pin table this diff's state lives on (persists grid/lastDiff across calls).
-- Appends any genuine A->B transformation to R.instr.log and R.tlog; returns aggregate counts.
local function diffTypeGrid(container, x0, y0, x1, y1, logIt)
  local newGrid, w = scanTypeGrid(x0, y0, x1, y1)
  local prev = container.grid
  local vanished, appeared, changed = 0, 0, 0
  if prev then
    for y = y0, y1 do
      local row = (y - y0) * w
      for x = x0, x1 do
        local idx = row + (x - x0)
        local a, b = prev[idx] or 0, newGrid[idx] or 0
        if a ~= b then
          if a == 0 then appeared = appeared + 1
          elseif b == 0 then vanished = vanished + 1
          else
            changed = changed + 1
            if logIt then
              local fromNm, toNm = R.nameOf(a) or tostring(a), R.nameOf(b) or tostring(b)
              local line = string.format("[t%d] (%d,%d): %s -> %s", R.frame or 0, x, y, R.nice(fromNm), R.nice(toNm))
              table.insert(S.log, 1, line)
              if #S.log > MAX_LOG_LINES then table.remove(S.log) end
              if R.tlog then R.tlog("info", TAG, "reaction observed", { x = x, y = y, from = fromNm, to = toNm }) end
            end
          end
        end
      end
    end
  end
  container.grid = newGrid
  local d = { vanished = vanished, appeared = appeared, changed = changed, tick = R.frame or 0 }
  container.lastDiff = d
  return d
end

-- ================================================================ per-tab compute (all bounded to a clamped region; called only from the throttled tick hook below)
local function computeGeiger(x0, y0, x1, y1)
  local phot, neut = eid("PHOT"), eid("NEUT")
  local leadId, concId, watrId = eid("LEAD"), eid("CNCR"), eid("WATR")
  local sources, sourceTotal, ionizing = {}, 0, 0
  local shieldLead, shieldConc, shieldWatr = 0, 0, 0
  for y = y0, y1 do
    for x = x0, x1 do
      local ok, pid = pcall(sim.partID, x, y)
      if ok and pid then
        local okt, t = pcall(sim.partProperty, pid, "type")
        if okt and t and t > 0 then
          if isRadioactiveElem(t) then
            local nm = R.nameOf(t) or "?"
            sources[nm] = (sources[nm] or 0) + 1
            sourceTotal = sourceTotal + 1
          end
          if t == phot or t == neut then ionizing = ionizing + 1 end
          if leadId and t == leadId then shieldLead = shieldLead + 1
          elseif concId and t == concId then shieldConc = shieldConc + 1
          elseif watrId and t == watrId then shieldWatr = shieldWatr + 1 end
        end
      end
    end
  end
  return { sources = sources, sourceTotal = sourceTotal, ionizing = ionizing, shieldLead = shieldLead,
    shieldConc = shieldConc, shieldWatr = shieldWatr, cells = (x1 - x0 + 1) * (y1 - y0 + 1), tick = R.frame or 0 }
end

local function nearestMachine(wx, wy, maxR)
  local best, bd = nil, maxR * maxR
  for _, m in ipairs(R.machines or {}) do
    local dx, dy = (m.x or 0) - wx, (m.y or 0) - wy
    local d2 = dx * dx + dy * dy
    if d2 <= bd then best, bd = m, d2 end
  end
  return best
end

local function computeMultimeter(x0, y0, x1, y1, cx, cy)
  local result = { probeX = cx, probeY = cy }
  local m = nearestMachine(cx, cy, 24)
  if not m then
    result.status = "no machine within 24px of probe"
  else
    result.kind, result.mx, result.my = m.kind, m.x, m.y
    local g = m._gid and R.power.grids[m._gid]
    if g then
      result.gridId, result.genW, result.loadW = g.id, g.gen, g.load
      result.netW, result.powered = g.gen - g.load, g.powered
      result.capWh, result.storedWh = g.cap, g.stored
    else
      result.status = "machine not on a live wired grid"
    end
  end
  local sprk = eid("SPRK")
  local n = 0
  if sprk then
    for y = y0, y1 do
      for x = x0, x1 do
        local ok, pid = pcall(sim.partID, x, y)
        if ok and pid then
          local okt, t = pcall(sim.partProperty, pid, "type")
          if okt and t == sprk then n = n + 1 end
        end
      end
    end
  end
  result.sparkCount, result.cells = n, (x1 - x0 + 1) * (y1 - y0 + 1)
  return result
end

local PHASE_BIT = { "TYPE_SOLID", "TYPE_LIQUID", "TYPE_GAS", "TYPE_ENERGY" }
local PHASE_LABEL = { TYPE_SOLID = "solid", TYPE_LIQUID = "liquid", TYPE_GAS = "gas", TYPE_ENERGY = "energy" }
local function phaseOf(props)
  if not (band and props) then return "?" end
  for _, bitname in ipairs(PHASE_BIT) do
    local b = elem[bitname]
    if b and band(props, b) ~= 0 then return PHASE_LABEL[bitname] end
  end
  return "particle"
end

local function computeThermo(x0, y0, x1, y1, cx, cy)
  local n, sumT, minT, maxT = 0, 0, nil, nil
  local phase = { solid = 0, liquid = 0, gas = 0, energy = 0, particle = 0 }
  local latent = {}   -- element name -> { count, sumPct }
  local watrId, wtrvId, iceiId, snowId = eid("WATR"), eid("WTRV"), eid("ICEI"), eid("SNOW")
  for y = y0, y1 do
    for x = x0, x1 do
      local ok, pid = pcall(sim.partID, x, y)
      if ok and pid then
        local okt, t = pcall(sim.partProperty, pid, "type")
        if okt and t and t > 0 then
          local okte, temp = pcall(sim.partProperty, pid, "temp")
          if okte and temp then
            n = n + 1; sumT = sumT + temp
            minT = minT and min(minT, temp) or temp
            maxT = maxT and max(maxT, temp) or temp
          end
          local okp, props = pcall(elem.property, t, "Properties")
          local ph = okp and phaseOf(props) or "particle"
          phase[ph] = (phase[ph] or 0) + 1
          if t == watrId or t == wtrvId or t == iceiId or t == snowId then
            local okd, tmp2 = pcall(sim.partProperty, pid, "tmp2")
            if okd and tmp2 then
              local target = (t == watrId or t == wtrvId) and THERMO_TARGET_BOIL or THERMO_TARGET_MELT
              local nm = R.nameOf(t) or "?"
              local e = latent[nm] or { count = 0, sumPct = 0 }
              e.count = e.count + 1; e.sumPct = e.sumPct + min(100, (tmp2 / target) * 100)
              latent[nm] = e
            end
          end
        end
      end
    end
  end
  local center
  local okc, cpid = pcall(sim.partID, cx, cy)
  if okc and cpid then
    local okt, t = pcall(sim.partProperty, cpid, "type")
    local okte, temp = pcall(sim.partProperty, cpid, "temp")
    center = { name = okt and (R.nameOf(t) or "?") or "?", temp = okte and temp or nil }
  else
    local okh, heat = pcall(sim.ambientHeat, floor(cx / 4), floor(cy / 4))
    center = { name = "empty (ambient)", temp = okh and heat or nil }
  end
  return { n = n, avgT = n > 0 and (sumT / n) or nil, minT = minT, maxT = maxT, phase = phase, latent = latent,
    center = center, cells = (x1 - x0 + 1) * (y1 - y0 + 1) }
end

local function computeComposition(x0, y0, x1, y1)
  local counts, total, weightSum = {}, 0, 0
  local thicknesses = {}
  for x = x0, x1 do
    local top, bot
    for y = y0, y1 do
      local ok, pid = pcall(sim.partID, x, y)
      if ok and pid then
        local okt, t = pcall(sim.partProperty, pid, "type")
        if okt and t and t > 0 then
          total = total + 1
          local nm = R.nameOf(t) or "?"
          counts[nm] = (counts[nm] or 0) + 1
          local okw, wt = pcall(elem.property, t, "Weight")
          if okw and wt then weightSum = weightSum + wt end
          top = top or y; bot = y
        end
      end
    end
    if top then thicknesses[#thicknesses + 1] = bot - top + 1 end
  end
  local minTh, maxTh, sumTh = nil, nil, 0
  for _, v in ipairs(thicknesses) do
    minTh = minTh and min(minTh, v) or v
    maxTh = maxTh and max(maxTh, v) or v
    sumTh = sumTh + v
  end
  return { counts = counts, total = total, weightSum = weightSum, minTh = minTh, maxTh = maxTh,
    avgTh = (#thicknesses > 0) and (sumTh / #thicknesses) or nil, cols = #thicknesses,
    cells = (x1 - x0 + 1) * (y1 - y0 + 1) }
end

-- ================================================================ throttled recompute (tick-hook only -- see PERFORMANCE in header)
local function targetOf(mode, point, region)
  if mode == "point" then return pointRegion(point.x, point.y, POINT_RADIUS) end
  return region.x0, region.y0, region.x1, region.y1
end

local function refreshOne(tab, mode, point, region, container, logReaction)
  local x0, y0, x1, y1 = targetOf(mode, point, region)
  local cx, cy = mode == "point" and point.x or floor((x0 + x1) / 2), mode == "point" and point.y or floor((y0 + y1) / 2)
  local result
  if tab == "geiger" then result = computeGeiger(x0, y0, x1, y1)
  elseif tab == "multimeter" then result = computeMultimeter(x0, y0, x1, y1, cx, cy)
  elseif tab == "thermo" then
    result = computeThermo(x0, y0, x1, y1, cx, cy)
    local now = os.clock()
    if container.prevAvgT and result.avgT and container.prevAt then
      local dt = now - container.prevAt
      if dt > 0.05 then result.rateKs = (result.avgT - container.prevAvgT) / dt end
    end
    if result.avgT then container.prevAvgT, container.prevAt = result.avgT, now end
    result.phaseEvents = diffTypeGrid(container, x0, y0, x1, y1, false)
  elseif tab == "comp" then result = computeComposition(x0, y0, x1, y1)
  elseif tab == "log" then
    result = { region = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } }
    diffTypeGrid(container, x0, y0, x1, y1, true)
  end
  container.result = result
  if R.tlog then R.tlog("debug", TAG, "refresh", { tab = tab, mode = mode, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }) end
  return result
end

-- ================================================================ pin management
local function addPin()
  if not (S.selMode) then R.say("Instruments: click or drag on the canvas first"); return end
  if #S.pins >= MAX_PINS then R.say(string.format("Instruments: %d pins max -- remove one first", MAX_PINS)); return end
  local pin = { id = S.nextPinId, tab = S.tab, mode = S.selMode,
    point = S.selMode == "point" and { x = S.selPoint.x, y = S.selPoint.y } or nil,
    region = S.selMode == "region" and { x0 = S.selRegion.x0, y0 = S.selRegion.y0, x1 = S.selRegion.x1, y1 = S.selRegion.y1 } or nil }
  S.nextPinId = S.nextPinId + 1
  refreshOne(pin.tab, pin.mode, pin.point, pin.region, pin, pin.tab == "log")
  S.pins[#S.pins + 1] = pin
  if R.tlog then R.tlog("info", TAG, "pin added", { id = pin.id, tab = pin.tab, mode = pin.mode }) end
  R.say("Pinned " .. TAB_LABEL[pin.tab])
end
local function removePin(idx)
  local p = table.remove(S.pins, idx)
  if p and R.tlog then R.tlog("info", TAG, "pin removed", { id = p.id, tab = p.tab }) end
end

-- ================================================================ tick: throttled recompute only, no per-frame full scan (see PERFORMANCE in header)
hook(R.hooks.sandboxTick, function()
  S.tick = S.tick + 1
  if not S.panelOpen then return end
  if S.selMode and (S.tick % ACTIVE_THROTTLE == 0) then
    S.live[S.tab] = S.live[S.tab] or {}
    refreshOne(S.tab, S.selMode, S.selPoint, S.selRegion, S.live[S.tab], S.tab == "log")
  end
  if #S.pins > 0 and (S.tick % PIN_THROTTLE == 0) then
    S.pinCursor = ((S.pinCursor - 1) % #S.pins) + 1
    local pin = S.pins[S.pinCursor]
    refreshOne(pin.tab, pin.mode, pin.point, pin.region, pin, pin.tab == "log")
    S.pinCursor = S.pinCursor + 1
  end
end)

-- ================================================================ layout
local TX, TY, TW_, TH_ = 4, 214, 130, 14
local PX, PY, PW, PH = 4, 230, 300, 136
local function btn(x, y, w, h, label) return { x = x, y = y, w = w, h = h, label = label } end
local function hit(bt, x, y) return bt and x >= bt.x and x < bt.x + bt.w and y >= bt.y and y < bt.y + bt.h end

local function layout()
  local L = {}
  L.toggle = btn(TX, TY, TW_, TH_, "INSTRUMENTS (I)")
  if not S.panelOpen then return L end
  local tw = floor((PW - 12 - 4 * 3) / 5)
  local tx = PX + 6
  L.tabs = {}
  for i, t in ipairs(TABS) do
    L.tabs[i] = btn(tx, PY + 16, tw, 13, TAB_LABEL[t]:sub(1, 8))
    tx = tx + tw + 3
  end
  L.pin = btn(PX + PW - 60, PY + 16, 54, 13, "PIN")
  L.pinRows = {}
  local py = PY + PH - 12 * min(#S.pins, MAX_PINS) - 4
  for i = 1, #S.pins do
    L.pinRows[i] = { y = py, x_btn = btn(PX + PW - 16, py, 12, 11, "X") }
    py = py + 12
  end
  return L
end

-- ================================================================ mouse
hook(R.hooks.sandboxMouseDown, function(x, y, button)
  local L = layout()
  if hit(L.toggle, x, y) then
    if button ~= 1 then return true end
    S.panelOpen = not S.panelOpen
    if R.tlog then R.tlog("info", TAG, "panel toggled", { open = S.panelOpen }) end
    return true
  end
  if not S.panelOpen then return end
  if x >= PX and x < PX + PW and y >= PY and y < PY + PH then
    if button ~= 1 then return true end
    if L.tabs then for i, t in ipairs(L.tabs) do if hit(t, x, y) then S.tab = TABS[i]; return true end end end
    if hit(L.pin, x, y) then addPin(); return true end
    for i, row in ipairs(L.pinRows) do if hit(row.x_btn, x, y) then removePin(i); return true end end
    return true   -- swallow clicks inside the panel that hit nothing (matches sbmaterials.lua's own convention)
  end
  -- canvas click: begin a probe/drag (only while a tab that reads the canvas is active -- all five do)
  if button ~= 1 then return end
  S.dragging, S.dragStart, S.dragCur = true, { x = x, y = y }, { x = x, y = y }
  return true
end)

hook(R.hooks.sandboxMouseMove, function(x, y, dx, dy)
  S.mx, S.my = x, y
  if S.dragging then S.dragCur = { x = x, y = y } end
end)

hook(R.hooks.sandboxMouseUp, function(x, y, button)
  if not S.dragging then return end
  S.dragging = false
  if not S.panelOpen then S.dragStart, S.dragCur = nil, nil; return true end
  local a, b = S.dragStart, S.dragCur or S.dragStart
  if abs(b.x - a.x) < 4 and abs(b.y - a.y) < 4 then
    S.selMode, S.selPoint, S.selRegion = "point", { x = a.x, y = a.y }, nil
  else
    local x0, y0, x1, y1 = clampRegion(a.x, a.y, b.x, b.y)
    S.selMode, S.selRegion, S.selPoint = "region", { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }, nil
  end
  S.live[S.tab] = {}   -- fresh container: a new selection must not carry the old one's diff-grid/rate history
  refreshOne(S.tab, S.selMode, S.selPoint, S.selRegion, S.live[S.tab], S.tab == "log")
  if R.tlog then R.tlog("info", TAG, "selection made", { tab = S.tab, mode = S.selMode }) end
  S.dragStart, S.dragCur = nil, nil
  return true
end)

-- ================================================================ key: I toggle, G/M/T/C/L tab jump (only while panel open), P pin -- all six plain letters, no chord, no F-key (see header)
hook(R.hooks.sandboxKey, function(key, k, shift, ctrl, alt)
  if k == "i" then S.panelOpen = not S.panelOpen; if R.tlog then R.tlog("info", TAG, "panel toggled (key)", { open = S.panelOpen }) end; return true end
  if not S.panelOpen then return end
  if TAB_KEY[k] then S.tab = TAB_KEY[k]; return true end
  if k == "p" then addPin(); return true end
  return
end)

-- ================================================================ draw
local function drawBtn(bt, active)
  local bg = active and { 30, 70, 34 } or { 26, 30, 46 }
  local border = active and { 140, 255, 140 } or { 110, 120, 150 }
  graphics.fillRect(bt.x, bt.y, bt.w, bt.h, bg[1], bg[2], bg[3], 235)
  graphics.drawRect(bt.x, bt.y, bt.w, bt.h, border[1], border[2], border[3], 255)
  graphics.drawText(bt.x + 3, bt.y + floor((bt.h - 7) / 2), bt.label, 220, 225, 235, 255)
end

local function fmt(n, d) if n == nil then return "?" end; return string.format("%." .. (d or 0) .. "f", n) end

local function drawGeiger(r, y)
  if not r then graphics.drawText(PX + 6, y, "no reading yet -- click or drag on the canvas", 170, 175, 190, 220); return end
  graphics.drawText(PX + 6, y, string.format("sources: %d radioactive particle(s) in %d cells", r.sourceTotal, r.cells), 220, 225, 235, 255)
  local yy = y + 11
  local shown = 0
  for nm, c in pairs(r.sources) do
    if shown < 3 then graphics.drawText(PX + 10, yy, string.format("%s x%d", R.nice(nm), c), 255, 210, 140, 255); yy = yy + 10; shown = shown + 1 end
  end
  graphics.drawText(PX + 6, yy, string.format("ionizing (PHOT+NEUT) in region: %d", r.ionizing), 200, 240, 255, 255); yy = yy + 11
  graphics.drawText(PX + 6, yy, string.format("shielding present: LEAD x%d  CNCR x%d  WATR x%d", r.shieldLead, r.shieldConc, r.shieldWatr), 180, 200, 210, 230); yy = yy + 10
  graphics.drawText(PX + 6, yy, "LEAD/CNCR block PHOT+NEUT (no PHOTPASS/NEUTPASS); WATR passes both -- real engine behaviour, disclosed", 140, 145, 160, 200)
end

local function drawMultimeter(r, y)
  if not r then graphics.drawText(PX + 6, y, "no reading yet -- click on a machine", 170, 175, 190, 220); return end
  if r.status and not r.gridId then graphics.drawText(PX + 6, y, r.status, 255, 170, 140, 255); return end
  graphics.drawText(PX + 6, y, string.format("machine: %s  grid #%s", r.kind or "?", tostring(r.gridId)), 220, 225, 235, 255)
  local yy = y + 11
  if r.gridId then
    graphics.drawText(PX + 6, yy, string.format("gen %sW  load %sW  net %sW  %s", fmt(r.genW), fmt(r.loadW), fmt(r.netW), r.powered and "POWERED" or "unpowered"), r.powered and 170 or 255, r.powered and 255 or 170, 170, 255); yy = yy + 10
    if (r.capWh or 0) > 0 then graphics.drawText(PX + 6, yy, string.format("battery: %s / %s Wh", fmt(r.storedWh), fmt(r.capWh)), 180, 220, 255, 230); yy = yy + 10 end
  end
  graphics.drawText(PX + 6, yy, string.format("spark (charge-carrier) count nearby: %d", r.sparkCount or 0), 200, 220, 255, 230); yy = yy + 10
  graphics.drawText(PX + 6, yy, "voltage/current/resistance: not modelled by this engine (watts is the only real unit here)", 140, 145, 160, 200)
end

local function drawThermo(r, y)
  if not r then graphics.drawText(PX + 6, y, "no reading yet -- click or drag on the canvas", 170, 175, 190, 220); return end
  graphics.drawText(PX + 6, y, string.format("at cursor: %s  %sK", r.center.name, fmt(r.center.temp)), 220, 225, 235, 255)
  local yy = y + 11
  if r.n > 0 then
    graphics.drawText(PX + 6, yy, string.format("region: avg %sK  min %sK  max %sK  (n=%d)", fmt(r.avgT), fmt(r.minT), fmt(r.maxT), r.n), 200, 220, 255, 230); yy = yy + 10
    if r.rateKs then graphics.drawText(PX + 6, yy, string.format("mean temp rate: %s K/s", fmt(r.rateKs, 2)), 255, 220, 160, 230); yy = yy + 10 end
  end
  graphics.drawText(PX + 6, yy, string.format("phase: solid %d liquid %d gas %d energy %d", r.phase.solid, r.phase.liquid, r.phase.gas, r.phase.energy), 190, 210, 190, 220); yy = yy + 10
  for nm, e in pairs(r.latent) do
    graphics.drawText(PX + 6, yy, string.format("%s latent-heat progress: %s%% avg (n=%d, thermo.lua tmp2)", R.nice(nm), fmt(e.sumPct / e.count, 0), e.count), 255, 210, 140, 230); yy = yy + 10
  end
  if r.phaseEvents and (r.phaseEvents.changed > 0 or r.phaseEvents.vanished > 0 or r.phaseEvents.appeared > 0) then
    graphics.drawText(PX + 6, yy, string.format("since last sample: %d changed  %d vanished  %d appeared", r.phaseEvents.changed, r.phaseEvents.vanished, r.phaseEvents.appeared), 200, 240, 200, 220)
  end
end

local function drawComp(r, y)
  if not r then graphics.drawText(PX + 6, y, "no reading yet -- drag a region on the canvas", 170, 175, 190, 220); return end
  graphics.drawText(PX + 6, y, string.format("%d particles in %d cells, %d columns", r.total, r.cells, r.cols), 220, 225, 235, 255)
  local yy = y + 11
  local shown = 0
  local rows = {}
  for nm, c in pairs(r.counts) do rows[#rows + 1] = { nm = nm, c = c } end
  table.sort(rows, function(a, b) return a.c > b.c end)
  for _, row in ipairs(rows) do
    if shown < 3 and r.total > 0 then
      graphics.drawText(PX + 10, yy, string.format("%s x%d (%s%%)", R.nice(row.nm), row.c, fmt(100 * row.c / r.total, 1)), 200, 220, 255, 230)
      yy = yy + 10; shown = shown + 1
    end
  end
  graphics.drawText(PX + 6, yy, string.format("weight index (engine units, not kg): %s", fmt(r.weightSum, 0)), 190, 210, 190, 220); yy = yy + 10
  graphics.drawText(PX + 6, yy, string.format("thickness: avg %spx  min %spx  max %spx", fmt(r.avgTh, 1), tostring(r.minTh or "?"), tostring(r.maxTh or "?")), 190, 210, 190, 220)
end

local function drawLog()
  local y = PY + 34
  if #S.log == 0 then graphics.drawText(PX + 6, y, "no reactions observed yet -- drag a region to watch", 170, 175, 190, 220); return end
  for i = 1, min(9, #S.log) do
    graphics.drawText(PX + 6, y, S.log[i], 200, 230, 200, 220)
    y = y + 9
  end
end

local DRAW_FN = { geiger = drawGeiger, multimeter = drawMultimeter, thermo = drawThermo, comp = drawComp }

local function drawPanel()
  graphics.fillRect(PX, PY, PW, PH, 8, 10, 20, 230)
  graphics.drawRect(PX, PY, PW, PH, 120, 200, 255, 220)
  local L = layout()
  for i, t in ipairs(L.tabs) do drawBtn(t, S.tab == TABS[i]) end
  drawBtn(L.pin, false)
  graphics.drawText(PX + 6, PY + 2, "LAB INSTRUMENTS  (I closes, G/M/T/C/L tabs, P pins)", 160, 220, 255, 255)
  if S.tab == "log" then drawLog()
  else DRAW_FN[S.tab]((S.live[S.tab] or {}).result, PY + 34) end
  for i, row in ipairs(L.pinRows) do
    local pin = S.pins[i]
    drawBtn(row.x_btn, false)
    graphics.drawText(PX + 6, row.y, string.format("pin %d: %s (%s)", pin.id, TAB_LABEL[pin.tab], pin.mode), 190, 220, 255, 220)
  end
  if S.selRegion then
    graphics.drawRect(S.selRegion.x0, S.selRegion.y0, S.selRegion.x1 - S.selRegion.x0 + 1, S.selRegion.y1 - S.selRegion.y0 + 1, 255, 220, 80, 200)
  elseif S.selPoint then
    graphics.drawRect(S.selPoint.x - 3, S.selPoint.y - 3, 6, 6, 255, 220, 80, 220)
  end
  if S.dragging and S.dragStart and S.dragCur then
    local x0, y0, x1, y1 = clampRegion(S.dragStart.x, S.dragStart.y, S.dragCur.x, S.dragCur.y)
    graphics.drawRect(x0, y0, x1 - x0 + 1, y1 - y0 + 1, 140, 200, 255, 180)
  end
end

hook(R.hooks.sandboxDrawHUD, function()
  local L = layout()
  drawBtn(L.toggle, S.panelOpen)
  if S.panelOpen then drawPanel() end
end)

if R.tlog then R.tlog("info", TAG, "instruments plugin loaded", { maxRegionCells = MAX_REGION_W * MAX_REGION_H, maxPins = MAX_PINS }) end
if PBX and PBX.log then PBX.log(TAG, "instruments plugin loaded") end
