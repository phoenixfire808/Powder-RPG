-- THERMO: latent heat for phase changes. Own file, own R.thermo table, zero edits to any other
-- plugin. Task (PhoenixFire808, verbatim): "the way that water boils in the game has to be
-- natural... it seems like it just heats up and then all the water just fucking explodes at once."
--
-- ============================================================ ENGINE READ, 2026-09-03 (cite lines, not vibes)
-- TPT's heat model has NO latent heat anywhere -- confirmed by reading the actual transition
-- code, not inferred from behaviour:
--   - `Simulation::TransitionPhase` (src/simulation/Simulation.cpp) does heat exchange and the
--     phase-change type check in the SAME per-particle pass, back to back, every single tick:
--     * Neighbour heat exchange (lines 2582-2632): every touching, non-insulating neighbour's temp
--       is pooled into one heat-capacity-weighted average `pt = c_heat/hc_total` and EVERY particle
--       in the pool (line 2631 `parts[i].temp = pt`, 2633-2635 the loop over `surround_hconduct`)
--       is set to that average IN ONE STEP. There is no per-tick fractional exchange for a
--       touching neighbour -- that's the alpha/0.04 formula at lines 2588-2595, but that path is
--       ONLY for ambient air, not for a touching solid/liquid neighbour. A WATR particle touching
--       a 1795K LAVA particle does not warm gradually; it becomes the weighted average of the two
--       on that same tick, which for two similar heat capacities is already >>373K.
--     * The very next lines, same pass, same particle, no gate in between: line 2660
--       `if (elements[t].HighTemperatureTransition != NT && ctemph>=elements[t].HighTemperature)`
--       converts the type immediately if that just-computed average crossed the threshold. There
--       is no accumulator, no "how much energy has this particle absorbed", nothing -- crossing
--       373.0K (WATR.cpp:43-44) on a single tick is suficient and immediate.
--   - WATR.cpp:41-44: `LowTemperature=273.15/ICEI`, `HighTemperature=373.0/WTRV`. WTRV.cpp:38-41:
--     `LowTemperature=371.0/ST` (condenses to DSTW, or RIME if <273K, Simulation.cpp:2766-2767 --
--     the 2K gap between 373/371 is the engine's own hysteresis band, not something I invented).
--     ICEI.cpp:38-45/SNOW.cpp (same): the struct's own `HighTemperature=252.05` is only a cheap
--     pre-gate: the REAL melt check is hardcoded at Simulation.cpp:2675 `pt<273.15f -> s=0` against
--     the frozen particle's own `ctype` (what it was before freezing, default PT_WATR per
--     ICEI.cpp:47) -- so ice genuinely melts at 273.15K, the pre-gate just avoids re-checking ice
--     that's nowhere near warm yet.
--   - `SimulationData::HeatCapacityOf` (SimulationData.cpp:343-349) reads `Element.HeatCapacity`,
--     default 1.0 (Element.cpp:33), never overridden by WATR/WTRV/ICEI/SNOW -- so the engine's own
--     "heat capacity" is a dimensionless per-element multiplier, NOT real J/(kg*K). There is no
--     unit in this engine I can plug real kJ/kg numbers into directly; the ratio below is applied
--     to an engine-native tick-count, not to a real energy balance (see BALANCE note).
--   - `Simulation::part_change_type` (Simulation.cpp:1840-1881) sets only `.type` (+ pmap/photon/
--     elementCount bookkeeping) and calls each side's `ChangeType` handler if one exists. WATR.cpp,
--     WTRV.cpp, ICEI.cpp, SNOW.cpp, DSTW.cpp and RIME.cpp define no `ChangeType` (grepped, zero
--     hits) -- so `tmp`/`tmp2`/`tmp3`/`tmp4` on these six elements pass through every transition
--     completely untouched by the engine. Independently confirmed none of these six .cpp files
--     ever read or write tmp/tmp2/tmp3/tmp4 themselves (grepped each file directly), and grepped
--     every Lua plugin in this repo for `"tmp2"` next to WATR/WTRV/ICEI/SNOW -- zero hits (the
--     `tmp2`-nibble/behaviour-kind usages that DO exist, `material_kinds.lua`/`chem_kinds.lua`/
--     `acq_energy.lua`, are all on unrelated custom elements). **tmp2 is genuinely free on these
--     six types and is what this file uses as the per-particle latent-heat debt counter.**
--     Deliberately NOT reusing `ctype` -- it already carries real meaning on all six (WATR/WTRV:
--     FIRE-origin + BUBW `CarriesTypeIn` tracking, WATR.cpp:73/WTRV.cpp:66; ICEI/SNOW: "what I
--     unfreeze back into", ICEI.cpp:47, cleared to PT_NONE on melt at Simulation.cpp:2683).
--
-- ============================================================ REAL PHYSICS CITED (standard reference values, not fabricated)
-- Water, standard atmospheric pressure, from any standard thermodynamics/steam-table reference:
--   specific heat of liquid water            c  = 4.18  kJ/(kg*K)
--   latent heat of vaporization at 100C       Lv = 2257  kJ/kg
--   latent heat of fusion at 0C               Lf = 334   kJ/kg
-- Both latent heats are expressed here against the SAME reference energy (heating 1kg of liquid
-- water through 100K, c*100 = 418 kJ/kg) so the two ratios are on one consistent scale:
--   RATIO_BOIL (= RATIO_CONDENSE, same magnitude, opposite direction) = 2257/418 = 5.40
--   RATIO_MELT (= RATIO_FREEZE, same magnitude, opposite direction)  = 334/418  = 0.80
-- This is the number the task brief itself asks for ("roughly 5.4x") and it is real, not tuned.
--
-- ============================================================ BALANCE (labelled, not physics)
-- The engine has no real energy unit to spend these ratios against (see HeatCapacity note above),
-- so the ratios are applied to an engine-native pacing constant instead of a real joule count:
-- BASE_TICKS = 15 real simulation ticks is a chosen (BALANCE) unit representing "one reference
-- dose of sensible reheating" while a particle sits inside this file's own hot/cold detection
-- zone (see mechanism below) -- NOT a measurement, not physics, purely a pacing knob so a pot of
-- water visibly takes several real seconds to fully boil off instead of one tick or one real
-- minute. TARGET_BOIL/TARGET_MELT below are BASE_TICKS*RATIO, real-ratio-scaled but balance-paced.
--
-- ============================================================ MECHANISM (why this is safe against the just-fixed melt/solidify round-trip)
-- This file NEVER calls create_part/part_change_type with a materials decision of its own, and
-- NEVER touches `ctype`. Its only two actions are: (1) hold `temp` a small margin on the
-- not-yet-transitioned side of the real threshold via `sim.partProperty(id,"temp",...)`, so the
-- ENGINE's own TransitionPhase (same code, same ctype logic, completely unmodified) simply
-- doesn't fire yet; and (2) if the engine's neighbour-averaging still jumps clean over that margin
-- in one tick anyway (a direct LAVA/FIRE contact CAN do this in a single step, see the engine read
-- above -- proactive clamping one tick behind can't always prevent it), revert the resulting
-- particle back with `sim.partProperty(id,"type",srcType)` ONLY (never ctype) if its latent debt
-- isn't paid yet, otherwise leave it alone. Every real conversion this file ever allows to stick
-- is performed BY THE ENGINE ITSELF on a later tick, through the exact same code path (and exact
-- same ctype handling) as today -- this cannot regress the 53/81 round-trip fix because it never
-- participates in the round trip's own logic, only in when it's allowed to start.
--
-- WHY WATR/WTRV/ICEI/SNOW ONLY THIS PASS, not the 81 custom-element melt/solidify set: applying
-- this same technique to a custom metal is safe in principle (same non-invasive clamp-only
-- mechanism) but the debt counter still needs a verified-free field on THAT element, and auditing
-- tmp/tmp2/tmp3/tmp4 usage across 81 custom elements (many with their own behaviour-kind fields,
-- material_kinds.lua/chem_kinds.lua/power_kinds.lua) is real work this pass's time budget did not
-- include -- narrower and correct now beats broad and unverified. `R.thermo.registerZone` (below)
-- and `gateGeneric` are written so a future pass can extend this per-element once each one's own
-- free field is confirmed the same way WATR/WTRV/ICEI/SNOW's was here.
--
-- ============================================================ COST / DISCOVERY DESIGN
-- companion.lua's own measurement (rpg-hub.md, 2026-09-01/02, cited again in that file's own
-- header) found a single blocking `for i in sim.parts() do` tally costs 13-24ms against this
-- world's live particle count -- close to the whole frame budget by itself. This file reuses
-- companion.lua's own proven fix verbatim: `sim.parts()` returns a real, hand-steppable Lua
-- iterator triple, so full-world discovery is spread across many ticks at a small bounded
-- per-tick cost (DISCOVERY_CHUNK, same 2000/tick companion.lua measured safe) instead of ever
-- entering one tick's budget in one call. Discovery only ever looks for the handful of extreme
-- heat/cold source types (FIRE/LAVA/PLSM for hot, ICEI/SNOW for cold) -- not water, which is by
-- far the most common particle in most worlds -- and buckets their positions into a coarse
-- GRID-px grid (dedup: one raging campfire of hundreds of FIRE particles collapses to a handful of
-- grid cells, not a scan per particle). The actual per-tick gating work only ever touches a
-- rotating WINDOW of those cells (bounded, independent of total particle count or fire size) plus
-- any explicitly `R.thermo.registerZone`'d machine (boiler etc). rpg.lua's own runHooks() throttle
-- (R.hooks.tick has `throttle=true`, rpg.lua:1337-1360) is the backstop if this file's own cost
-- estimate is still wrong on his machine -- an over-budget tick hook is automatically run less
-- often rather than eating frame rate, same governor every other plugin's tick hook already uses.
--
-- ============================================================ INTERFACE FOR @power (steam engine)
-- `R.thermo.registerZone(x, y, range, kind, ttlFrames)` -- kind = "hot" or "cold", ttlFrames
-- defaults to 120 (~2s at 60fps) and must be re-called periodically (same re-registration
-- convention as R.o2Sources) or the zone expires and stops being scanned. Use this for a boiler's
-- firebox-to-water contact face so its own water column gates through this same latent-heat
-- system instead of flash-converting the instant the shell reaches 373K -- this is deliberately
-- the same non-invasive mechanism as the ambient/natural case, not a separate boiler-only hack.
-- `R.thermo.report()` returns a one-line string of live counters (checked/gated/released/reverted)
-- for verification; no key or panel is bound to it (see accessibility note below) -- call it from
-- the bridge/console.
--
-- ============================================================ ACCESSIBILITY (PhoenixFire808's hand)
-- Zero new keys, zero new UI, zero buttons. This is a background physics correction with nothing
-- for a player to operate -- the single best way to respect "few, well-placed controls, not a
-- strip" for a feature like this is to add no control surface at all. `R.thermo.report()` exists
-- for developer verification only, callable from the bridge, never bound to a key.

local R = PBX.state.rpg
local TAG = "thermo"

-- FIXED hook helper (per-list strip-then-append-once, matching drawperf.lua's already-shipped fix
-- for the project-wide bug: a plugin's SECOND hook(list,...) on the SAME list used to silently
-- delete its first -- @audit traced this to the dead Replicator Core recovery feature). This file
-- only ever registers ONE hook on R.hooks.tick, so the bug can't bite here regardless, but the
-- fixed helper is used anyway for consistency with the rest of the plugin set.
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

local floor, min, max = math.floor, math.min, math.max

-- ================================================================ element ids (all six are stock, always present)
local WATR_ID = elem.DEFAULT_PT_WATR
local WTRV_ID = elem.DEFAULT_PT_WTRV
local ICEI_ID = elem.DEFAULT_PT_ICEI
local SNOW_ID = elem.DEFAULT_PT_SNOW
local DSTW_ID = elem.DEFAULT_PT_DSTW
local FIRE_ID = elem.DEFAULT_PT_FIRE
local LAVA_ID = elem.DEFAULT_PT_LAVA
local PLSM_ID = elem.DEFAULT_PT_PLSM

-- ================================================================ real thresholds (cited above, engine source line numbers in header)
local BOIL_THRESH, BOIL_MARGIN   = 373.0,  0.5   -- WATR.cpp:43-44
local COND_THRESH, COND_MARGIN   = 371.0,  0.5   -- WTRV.cpp:40-41
local MELT_THRESH, MELT_MARGIN   = 273.15, 0.35  -- Simulation.cpp:2675 (real ICEI/SNOW melt check)
local FREEZE_THRESH, FREEZE_MARGIN = 273.15, 0.5 -- WATR.cpp:41-42

-- ================================================================ real ratios (cited above) + balance pacing
local RATIO_BOIL, RATIO_MELT = 5.40, 0.80   -- physics: 2257/418 and 334/418 (see header)
local BASE_TICKS = 15                        -- BALANCE: engine has no real energy unit to spend these against; see header
local TARGET_BOIL = floor(BASE_TICKS * RATIO_BOIL + 0.5)   -- 81 ticks
local TARGET_COND = TARGET_BOIL                              -- condensation: same latent magnitude, opposite direction
local TARGET_MELT = floor(BASE_TICKS * RATIO_MELT + 0.5)   -- 12 ticks
local TARGET_FREEZE = TARGET_MELT

-- ================================================================ state (survives hot-reload, on R.*)
R.thermo = R.thermo or {
  zones = {},              -- externally registered {x,y,range,kind,expiresAt} (see registerZone)
  scan = nil,               -- in-progress incremental discovery scan (see scanStep)
  hotCellList = nil,        -- array of grid-cell keys containing FIRE/LAVA/PLSM, from the last completed discovery pass
  coldCellList = nil,       -- array of grid-cell keys containing ICEI/SNOW, from the last completed discovery pass
  hotCursor = 1, coldCursor = 1,
  stats = { checked = 0, gated = 0, released = 0, reverted = 0 },
}

local DISCOVERY_CHUNK = 2000   -- particles/tick during discovery -- same figure companion.lua measured safe (~0.4ms/tick)
local GRID = 14                 -- px, coarse dedup grid for discovered hot/cold cells
local ACTIVE_WINDOW = 24        -- cells processed per tick per list (24 * 14*14 = ~4700 sim.partID lookups/tick worst case)
local W = R.W or 612
local H = R.H or 384

local function cellKeyOf(x, y) return floor(x / GRID) * 100000 + floor(y / GRID) end
local function cellXY(key) local cx = floor(key / 100000); return cx * GRID, (key - cx * 100000) * GRID end

-- ================================================================ discovery: incremental, bounded, never a blocking full pass
local HOT_TYPES = { [FIRE_ID] = true, [LAVA_ID] = true, [PLSM_ID] = true }
local COLD_TYPES = { [ICEI_ID] = true, [SNOW_ID] = true }

local function scanStart()
  local f, s, var = sim.parts()
  R.thermo.scan = { f = f, s = s, var = var, hot = {}, cold = {} }
end

local function scanStep()
  local sc = R.thermo.scan
  if not sc then scanStart(); return end
  for _ = 1, DISCOVERY_CHUNK do
    local pid = sc.f(sc.s, sc.var)
    if pid == nil then
      local hotList, coldList = {}, {}
      for k in pairs(sc.hot) do hotList[#hotList + 1] = k end
      for k in pairs(sc.cold) do coldList[#coldList + 1] = k end
      R.thermo.hotCellList = hotList
      R.thermo.coldCellList = coldList
      R.thermo.scan = nil
      return
    end
    sc.var = pid
    local t = sim.partProperty(pid, "type")
    if HOT_TYPES[t] then
      local x, y = sim.partPosition(pid)
      if x then sc.hot[cellKeyOf(x, y)] = true end
    elseif COLD_TYPES[t] then
      local x, y = sim.partPosition(pid)
      if x then sc.cold[cellKeyOf(x, y)] = true end
    end
  end
end

-- ================================================================ the gate itself
-- Pair gate (boil<->condense, freeze<->melt-of-plain-water): fixed src/dst, real revert-on-overshoot.
local function tryGatePair(id, curType, srcType, dstType, thresh, margin, dirHigh, target, allowRevert)
  if curType ~= srcType and curType ~= dstType then return end
  R.thermo.stats.checked = R.thermo.stats.checked + 1
  local temp = sim.partProperty(id, "temp")
  if not temp then return end
  local tmp2 = sim.partProperty(id, "tmp2") or 0
  local myTarget = target + floor(target * 0.25 * ((id % 11) / 10))   -- deterministic +0..25% stagger so a uniformly-heated body doesn't finish in one tick
  if curType == srcType then
    local approaching = dirHigh and (temp >= thresh - margin) or (temp <= thresh + margin)
    if not approaching then
      if tmp2 ~= 0 then sim.partProperty(id, "tmp2", 0) end
      return
    end
    if tmp2 >= myTarget then
      if tmp2 ~= 0 then sim.partProperty(id, "tmp2", 0) end   -- clean slate before the engine converts it on a later tick
      R.thermo.stats.released = R.thermo.stats.released + 1
      return
    end
    sim.partProperty(id, "tmp2", tmp2 + 1)
    local clamped = dirHigh and min(temp, thresh - margin) or max(temp, thresh + margin)
    if clamped ~= temp then sim.partProperty(id, "temp", clamped) end
    R.thermo.stats.gated = R.thermo.stats.gated + 1
  elseif allowRevert and curType == dstType then
    if tmp2 > 0 and tmp2 < myTarget then
      -- the engine's own neighbour-averaging jumped clean over our margin in one tick (a direct
      -- FIRE/LAVA contact can do this, see header) before we ever got a chance to hold it back --
      -- revert, keep the accumulated debt, try again next tick. Never touches ctype.
      sim.partProperty(id, "type", srcType)
      sim.partProperty(id, "temp", dirHigh and (thresh - margin) or (thresh + margin))
      R.thermo.stats.reverted = R.thermo.stats.reverted + 1
    elseif tmp2 ~= 0 then
      sim.partProperty(id, "tmp2", 0)   -- arrived with debt already paid -- clear it so the NEXT phase change (e.g. this steam later re-condensing) starts from zero, not carrying boil-debt into the condense gate
    end
  end
end

-- Melt gate (ICEI/SNOW -> real ctype target, usually WATR): proactive-only, no revert. Ice/snow
-- are stationary TYPE_SOLID particles that sit continuously inside whatever grid cell discovery
-- already flagged as hot, so the every-tick (non-throttled) zone scan below reliably clamps them
-- before a native crossing rather than after -- unlike WATR, which can flow into sudden contact
-- with an existing hot particle in a single frame. Not reusing tryGatePair here because the real
-- destination type is dynamic (parts[i].ctype, corrected to PT_WATR by the engine itself for any
-- invalid ctype before this file ever reads it -- Simulation.cpp's own "ice with ctype=0" fix) and
-- the engine clears ctype to PT_NONE on a successful melt, so there is no reliable "dst type" left
-- to revert against after the fact even if we wanted to.
local function tryGateMelt(id, srcType)
  R.thermo.stats.checked = R.thermo.stats.checked + 1
  local temp = sim.partProperty(id, "temp")
  if not temp then return end
  local approaching = temp >= MELT_THRESH - MELT_MARGIN
  local tmp2 = sim.partProperty(id, "tmp2") or 0
  if not approaching then
    if tmp2 ~= 0 then sim.partProperty(id, "tmp2", 0) end
    return
  end
  local myTarget = TARGET_MELT + floor(TARGET_MELT * 0.25 * ((id % 11) / 10))
  if tmp2 >= myTarget then
    if tmp2 ~= 0 then sim.partProperty(id, "tmp2", 0) end
    R.thermo.stats.released = R.thermo.stats.released + 1
    return
  end
  sim.partProperty(id, "tmp2", tmp2 + 1)
  local clamped = min(temp, MELT_THRESH - MELT_MARGIN)
  if clamped ~= temp then sim.partProperty(id, "temp", clamped) end
  R.thermo.stats.gated = R.thermo.stats.gated + 1
end

local function hotCellFn(id)
  local t = sim.partProperty(id, "type")
  if t == WATR_ID or t == WTRV_ID then
    tryGatePair(id, t, WATR_ID, WTRV_ID, BOIL_THRESH, BOIL_MARGIN, true, TARGET_BOIL, true)
  elseif t == ICEI_ID then
    tryGateMelt(id, ICEI_ID)
  elseif t == SNOW_ID then
    tryGateMelt(id, SNOW_ID)
  end
end

local function coldCellFn(id)
  local t = sim.partProperty(id, "type")
  if t == WATR_ID or t == ICEI_ID then
    tryGatePair(id, t, WATR_ID, ICEI_ID, FREEZE_THRESH, FREEZE_MARGIN, false, TARGET_FREEZE, true)
  elseif t == WTRV_ID or t == DSTW_ID then
    tryGatePair(id, t, WTRV_ID, DSTW_ID, COND_THRESH, COND_MARGIN, false, TARGET_COND, true)
  end
  -- RIME (very-cold condensation, <273K) is deliberately left ungated -- real deposition is
  -- already a fast process physically and it isn't the flash-conversion complaint this file
  -- exists to fix; gating it too would be scope creep against an unasked-for case.
end

-- ================================================================ rotating window over discovered/registered cells -- bounded cost regardless of world size
local function processCellWindow(list, cursor, fn)
  local n = list and #list or 0
  if n == 0 then return 1 end
  if cursor > n then cursor = 1 end
  local endIdx = min(cursor + ACTIVE_WINDOW - 1, n)
  for idx = cursor, endIdx do
    local cx, cy = cellXY(list[idx])
    local y0, y1 = max(0, cy), min(H - 1, cy + GRID - 1)
    local x0, x1 = max(0, cx), min(W - 1, cx + GRID - 1)
    for y = y0, y1 do
      for x = x0, x1 do
        local p = sim.partID(x, y)
        if p then fn(p) end
      end
    end
  end
  if endIdx >= n then return 1 end
  return endIdx + 1
end

-- ================================================================ externally registered zones (@power boiler etc) -- small list, scanned in full every tick
function R.thermo.registerZone(x, y, range, kind, ttlFrames)
  local now = R.frame or 0
  R.thermo.zones[#R.thermo.zones + 1] = { x = x, y = y, range = range or 6, kind = kind == "cold" and "cold" or "hot", expiresAt = now + (ttlFrames or 120) }
end

local function processExternalZones()
  local now = R.frame or 0
  local zones = R.thermo.zones
  for k = #zones, 1, -1 do
    local z = zones[k]
    if z.expiresAt < now then
      table.remove(zones, k)
    else
      local fn = z.kind == "cold" and coldCellFn or hotCellFn
      local y0, y1 = max(0, z.y - z.range), min(H - 1, z.y + z.range)
      local x0, x1 = max(0, z.x - z.range), min(W - 1, z.x + z.range)
      for y = y0, y1 do
        for x = x0, x1 do
          local p = sim.partID(x, y)
          if p then fn(p) end
        end
      end
    end
  end
end

-- ================================================================ tick hook
hook(R.hooks.tick, function()
  scanStep()
  R.thermo.hotCursor = processCellWindow(R.thermo.hotCellList, R.thermo.hotCursor, hotCellFn)
  R.thermo.coldCursor = processCellWindow(R.thermo.coldCellList, R.thermo.coldCursor, coldCellFn)
  processExternalZones()
end)

-- ================================================================ MEASURED, 2026-09-03, own isolated lab instance (port 9931, D:/powder-toy/lab_instance_thermo, killed cleanly after, Drew's port 9876 session never touched)
-- Sealed BRCK box, 200 real WATR particles, real LAVA heat source, thermo plugin live via
-- R.reloadPlugin("thermo"), sampled over the bridge every 0.6-1.5s while stepping real frames:
--   (1) SUSTAINED heating (bottom row forced back to 1700K roughly once per sample round, the
--       closest this rig could get to a real firebox that doesn't go out): WATR count declined
--       182 -> 52 -> 43 -> 11 -> ... -> 0 over ~20 real seconds / ~220 real ticks, with
--       R.thermo.report() showing checked/gated climbing into the thousands and reverted into the
--       hundreds throughout -- i.e. the gate was actively intercepting and holding particles the
--       whole time, not doing nothing. Compare to the unpatched engine, which (per the header's
--       own TransitionPhase read) converts a particle the SAME tick its neighbour-average crosses
--       373K -- this rig's water lasted roughly 200x longer than one tick before fully converting.
--   (2) KNOWN LIMITATION found by the same rig: instantiating a LARGE new heat source in one shot
--       (80 LAVA particles created simultaneously under the water block in a single Lua call, not
--       a realistic gradual gameplay heat source) converted most of the adjacent water before this
--       file's own discovery scan had found the new LAVA cells at all -- `R.thermo.report()` showed
--       `checked=25` and never climbed further while `watr` had already dropped to 0. Root cause:
--       discovery latency, not window size -- new hot/cold cells only enter hotCellList/coldCellList
--       once the incremental sim.parts() scan reaches them (bounded by DISCOVERY_CHUNK vs total
--       particle count, up to roughly one full cycle, ~50 ticks at this world's ~98k particles),
--       and the ENGINE's own instant neighbour-averaging does not wait for that. This is the direct
--       cost of the discovery scan being incremental rather than a full-world-every-tick scan (the
--       companion.lua-measured 13-24ms full pass this file deliberately avoids paying, see COST
--       DESIGN above). MITIGATION SHIPPED: `R.thermo.registerZone` (below) is processed in full
--       EVERY tick with no discovery latency at all -- @power/@machines should register a boiler's
--       water-contact face explicitly rather than rely on organic discovery, which is the honest
--       reason that API exists rather than just "wait for the scan." Organic/natural cases (a
--       player pouring water near EXISTING lava, or lava flowing toward EXISTING water) are
--       unaffected since the heat source is typically already-discovered before contact begins.

-- ================================================================ verification surface (no key/panel -- bridge/console only, see accessibility note)
function R.thermo.report()
  local st = R.thermo.stats
  return string.format(
    "thermo: checked=%d gated=%d released=%d reverted=%d | hotCells=%d coldCells=%d zones=%d | targets boil=%d melt=%d",
    st.checked, st.gated, st.released, st.reverted,
    R.thermo.hotCellList and #R.thermo.hotCellList or 0,
    R.thermo.coldCellList and #R.thermo.coldCellList or 0,
    #R.thermo.zones, TARGET_BOIL, TARGET_MELT)
end

if R.tlog then
  R.tlog("info", "thermo", "thermo plugin loaded", { targetBoil = TARGET_BOIL, targetMelt = TARGET_MELT, ratioBoil = RATIO_BOIL, ratioMelt = RATIO_MELT })
end
if PBX.log then PBX.log("thermo", "loaded, latent-heat gate active for WATR/WTRV/ICEI/SNOW") end
