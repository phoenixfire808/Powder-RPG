-- acq_machines.lua - EXTRACTION & PROCESSING machines for the Powder RPG (2026-09-0X, @acq_machines).
-- NEW FILE this wave, standalone, same convention as @automation/@fieldtools -- does NOT touch
-- rpg.lua, machines.lua or machines2.lua. Task: "195 stock elements, 71 obtainable, 124 not --
-- you five cover being FOUND: placement, extraction machines, growing, discoverability, proof."
-- This lane's slice: the machines that turn "theoretically craftable" into "here is the device
-- that makes it" -- air separation, an alkali-metal electrolysis route, ore reduction, oil
-- cracking, isotope enrichment (the task brief's six bullets). Design reference:
-- knowledge/design-material-progression.md (part 1) + design-material-progression-part2.md.
--
-- SCOPE WAS REVISED MID-TASK after checking sibling lanes' ALREADY-LANDED files (not a design
-- doc -- the real, live source) -- three of the brief's six bullets turned out to already be
-- fully covered, and shipping a competing route for the same token would be exactly the
-- "two unrelated things doing the same job" mistake @fieldtools' own header already argued
-- against for Portals. Evidence, all read directly from the sibling files before writing this
-- one's final version:
--   - CRYSTALLISATION/EVAPORATION FOR SALT: already shipped, machines2.lua "Salt Evaporator"
--     (EVAPORATORKIT, real SLTW -> SALT + WTRV). Not duplicated. Never was in this file's plan.
--   - AIR SEPARATION'S OXYG/HYGN/CO2: acq_fluids.lua ships a Chem Canister that already captures
--     real OXYG/HYGN/CO2 particles (already spawned by other live mechanics: cave-air breathing,
--     O2GENKIT electrolysis byproduct, player exhale/tree respiration) straight into inventory.
--     Building a second machine that ALSO outputs these three would be a duplicate acquisition
--     path for no reason. Verified by reading acq_fluids.lua's own CAPTURABLE table and header
--     before writing this file's final version.
--   - DISTILLATION/CRACKING FOR OIL: acq_fluids.lua already ships `{out="DESL", need={OIL=3},
--     st="research"}` and OIL/GAS are both in its Chem Canister CAPTURABLE table (GAS is also
--     natively world-placed, world.lua:846). Both fractions of "OIL into its fractions" were
--     already closed before this file's Cracking Tower machine was written -- DROPPED entirely
--     rather than shipped as a confusing second route to the same two tokens.
--   - RBDM/LRBD (this file's original "Ore Reduction Furnace" RBDM branch): acq_special.lua's own
--     header explicitly claims RBDM/LRBD as its 33-element scope and documents it as
--     DELIBERATELY BLOCKED on @world's still-unplaced RBDM vein ("a C-5 recipe demanding LRBD
--     would ship as a dead, permanently-unreachable recipe today... revisit and retarget to LRBD
--     once @world lands the RBDM vein"). Building a competing RBDM->LRBD smelt here, in a
--     different file, while they are deliberately holding theirs back for the exact same missing
--     vein, would be uncoordinated duplication of a decision they already made explicitly. DROPPED.
--
-- What that leaves, genuinely unclaimed by any sibling file (verified by grep of every acq_*.lua
-- before writing this final version) and still matching the brief's six bullets:
--   - "Air separation unit... NBLE" -- acq_fluids' own header states NBLE explicitly needs "NEW
--     WORLD PLACEMENT... out of scope for this plugin." Narrowed from a 4-gas family (per the
--     brief's literal wording) to the ONE gas of that family still genuinely open: a Noble Gas
--     Extractor, self-contained (does not require a world-placed pocket -- see machine 1 below
--     for why that is a legitimate reading of the design doc's own "capture" verb).
--   - "Electrolysis cell -- the alkali metals" -- LITH (this fork's one alkali metal with a real
--     acquisition design, design-material-progression.md chain 8; grepped POWDER_TOY_MATERIAL_
--     INDEX.json for any halogen name -- zero matches, so this fork has no halogen token to pair
--     it with; the closest thing, CAUS, already has its own machine, ELECTROLYSISKIT).
--   - "Ore reduction/smelter chain" -- kept, RBDM branch removed, BRMT/ROCK branches kept (see
--     machine 3; both are immediately reachable today with zero dependency on any other lane).
--   - "Isotope separation/enrichment" -- kept in full; zero collision found in any sibling file.
--
-- Owns: R.hooks.tick/draw/drawHUD/mousedown/place/newworld/sandbox entries tagged "acq_machines",
-- R.acqm (own placed-machine state array, world coords, same shape convention as R.machines2),
-- R.ITEMS.<NOBLEEXTRACTKIT,BRINEELECTROKIT,OREREDUCTKIT,ENRICHKIT>, R.RECIPES entries tagged
-- _plugin="acq_machines". Writes nothing to R.tech, R.power, R.machines, R.machines2 or any
-- sibling acq_*.lua file's own tables.
--
-- Power convention: same as @automation/@fieldtools/@machines2 -- a real live SPRK sitting on or
-- adjacent to a machine's own pad this frame, checked with a local poweredAt().
--
-- Collection convention, decided per-output after checking what the engine actually supports:
--   - LITH, ISZS, METL, CU, GOLD are ALL already in R.MINEABLE (LITH/ISZS added 2026-09-02 by
--     @veins for their own not-yet-visible-to-this-lane veins, rpg.lua:2355-2362; METL/CU/GOLD
--     were baseline) -- these outputs are real solid/powder particles placed with setAt(), then
--     collected the SAME way SALT/MERC/PTNM/BMTL already are: the player mines the particle
--     sitting in the machine's basin/vent with their own pick. No new collection code needed;
--     this is the established, already-shipped pattern (rpg.lua:2358-2362's own comment cites
--     this exact "produced but uncollectable without an R.MINEABLE entry" shape for SALT).
--   - NBLE and ISOZ (liquid, no R.MINEABLE possible -- gases/liquids aren't pick-mineable in this
--     engine) have no existing collection route this file can safely reuse without editing
--     another lane's file (acq_fluids.lua owns the only capture tool, CHEMCAN, and NBLE/ISOZ are
--     not in its CAPTURABLE table). Both machines below spawn a REAL particle in a visible sight
--     window for one tick (genuine chemistry, not a lie) and then grant it via a literal
--     `R.give("NBLE", n)` / `R.give("ISOZ", n)` call -- literal per-token calls on purpose, same
--     reasoning acq_fluids.lua's own header gives verbatim: scripts/check_reachable.py's grant
--     parser (GIVE_RE) only matches a literal string first argument, so writing the token out
--     makes this machine's real output visible to the automated reachability gate instead of
--     silently reading as unreachable.

local R = PBX.state.rpg
local TAG = "acq_machines"
-- FIXED 2026-09-02. This used to remove EVERY entry carrying this plugin's tag before appending,
-- which meant a plugin's SECOND hook on a given list silently deleted its FIRST. @audit proved
-- that killed the Replicator Core recovery feature outright -- it was registered, then destroyed
-- by a later registration in the same file, and nobody could see why the feature did nothing.
-- 29 plugins share this helper and several register 7-14 hooks, so an unknown number of features
-- have been quietly dead. The reload cleanup it was trying to do is still needed, so it now
-- happens ONCE per load, across every hook list, before any registration -- and hook() simply
-- appends, so a file can register as many hooks as it likes.
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

local W, H = R.W, R.H
local eid, nameOf, has, say = R.eid, R.nameOf, R.has, R.say
local function nice(n) return (R.nice and R.nice(n)) or n end

R.acqm = R.acqm or {}   -- placed machines: {kind, x, y, ...kind-specific fields}, world coords

-- ================================================================ low-level build helpers (same
-- erase-then-place convention every other plugin in this codebase uses)
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function setAt(wx, wy, elName)
  killAt(wx, wy); local t = eid(elName); if not t then return nil end
  return sim.partCreate(-1, wx - R.cam.x, wy - R.cam.y, t)
end
local function boxFill(x1, y1, x2, y2, elName) for y = y1, y2 do for x = x1, x2 do setAt(x, y, elName) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if R.solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
local function ring(cx, cy, r, elName, thick)
  thick = thick or 1
  for dy = -r, r do for dx = -r, r do
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= r + 0.5 and d >= r - thick + 0.5 then setAt(cx + dx, cy + dy, elName) end
  end end
end
local function nearPlayer(x, y, r) local dx, dy = x - R.P.x, y - R.P.y; return dx * dx + dy * dy <= (r or 140) * (r or 140) end
local function partAt(wx, wy) return sim.partID(wx - R.cam.x, wy - R.cam.y) end
local function typeAt(wx, wy) local p = partAt(wx, wy); return p and nameOf(sim.partProperty(p, "type")) or nil end
-- powered = a real spark on/adjacent to the pad this frame (same physics every other plugin's own
-- poweredAt/sparkNear checks -- see file header)
local function poweredAt(wx, wy, r)
  r = r or 1
  for dy = -r, r do for dx = -r, r do
    if typeAt(wx + dx, wy + dy) == "SPRK" then return true end
  end end
  return false
end
-- material fallbacks: STEL/CU are this RPG's own custom elements, not stock -- a session where
-- they haven't (yet) been registered must still build something real and safe, never no-op onto
-- an unresolved name (LIVE-OBSERVED 2026-09-02: a direct bridge query against the running session
-- found STEL genuinely unregistered at the moment this file was written -- R.has("STEL")==false,
-- R.eid("STEL")==nil, confirmed twice -- while a sibling custom element from the same
-- demo_create_element.lua registration group, CNCR, WAS registered; not investigated further,
-- fixing element registration would touch rpg.lua, not this lane's file this wave; every use of
-- STEL below goes through this same defensive fallback so the machine still builds correctly
-- regardless of registration state).
local STEELMAT = has("STEL") and "STEL" or "METL"
local WMAT = has("CU") and "CU" or "METL"

-- ================================================================ interaction: proximity prompt +
-- right-click panel (same MBOX/NAME/IDLE_HINT/STATE_DESC/NEXT_DESC convention as machines2.lua)
local MBOX = {}
local NAME = {}
local IDLE_HINT = {}
local STATE_DESC = {}
local NEXT_DESC = {}
local function machineCentre(m)
  local b = MBOX[m.kind]
  if b then return m.x + b[1], m.y + b[2], b[3] end
  return m.x, m.y - 3, 8
end
local function machineAt(wx, wy)
  local best, bestD
  for _, m in ipairs(R.acqm) do
    if MBOX[m.kind] then
      local cx, cy, r = machineCentre(m)
      local d = (wx - cx) * (wx - cx) + (wy - cy) * (wy - cy)
      if d <= r * r and (not bestD or d < bestD) then bestD = d; best = m end
    end
  end
  return best
end

hook(R.hooks.mousedown, function(x, y, button)
  if button ~= 3 then return end
  local wx, wy = x + R.cam.x, y + R.cam.y
  if R.acqmPanel then R.acqmPanel = nil; R.uiPanelOpen = false; return true end
  local hit = machineAt(wx, wy)
  if hit and nearPlayer(hit.x, hit.y, 90) then R.acqmPanel = hit; R.uiPanelOpen = true; return true end
end)

hook(R.hooks.drawHUD, function()
  if not R.acqmPanel then
    for _, m in ipairs(R.acqm) do
      if MBOX[m.kind] and nearPlayer(m.x, m.y, 70) then
        local cx, cy = machineCentre(m)
        local sx, sy = cx - R.cam.x, cy - R.cam.y - 16
        if sx > -20 and sx < W + 20 and sy > -20 and sy < H then
          graphics.drawText(sx - 40, sy, "[right-click] " .. (NAME[m.kind] or m.kind), 255, 210, 120, 220)
        end
      end
    end
  end
  local m = R.acqmPanel
  if m then
    local px, py, pw, ph = 190, 40, 250, 130
    graphics.fillRect(px, py, pw, ph, 10, 12, 18, 235)
    graphics.drawRect(px, py, pw, ph, 90, 95, 120, 255)
    graphics.drawText(px + 8, py + 6, (NAME[m.kind] or m.kind):upper(), 255, 210, 120, 255)
    graphics.drawText(px + pw - 90, py + 6, "[right-click] close", 150, 150, 160, 220)
    local state = STATE_DESC[m.kind] and STATE_DESC[m.kind](m) or "OK"
    graphics.drawText(px + 8, py + 24, "State: " .. state, 210, 220, 230, 255)
    local nextLine = NEXT_DESC[m.kind] and NEXT_DESC[m.kind](m) or (IDLE_HINT[m.kind] or "")
    local ny = py + 44
    for line in tostring(nextLine):gmatch("[^\n]+") do
      graphics.drawText(px + 8, ny, line, 255, 230, 150, 255); ny = ny + 12
    end
  end
end)

-- ================================================================================================
-- MACHINE 1: Noble Gas Extractor -- the one gas design-material-progression.md's chain 2 assigns
-- a "capture" verb (NBLE: "spark a sealed noble-gas pocket, canister fills") that no sibling lane
-- has built (acq_fluids.lua's own header explicitly defers it, "needs NEW WORLD PLACEMENT... out
-- of scope for this plugin"). Read literally, the design doc's own verb IS a machine, not a world
-- vein: a player-built SEALED chamber, SPARKED, with a CANISTER that fills -- exactly the shape of
-- every other machine in this codebase, not a terrain feature. This machine is that literal
-- reading: a sealed STEL chamber (the "pocket," built and filled with ordinary ambient air the
-- same way the existing air pump/O2GENKIT already draw it in) that, once sparked, ionizes a real
-- NBLE particle in a sight window (own description: "ionizes to plasma when sparked" -- matches
-- exactly) roughly every 4 seconds while powered, then grants it to inventory (see file header for
-- why R.give is used here instead of a mineable particle).
-- ================================================================================================
NAME.nobleext = "Noble Gas Extractor"
MBOX.nobleext = { 0, -4, 8 }
IDLE_HINT.nobleext = "Power the pad -- ionizes sealed ambient air into real Noble gas"
STATE_DESC.nobleext = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "ionizing" or "unpowered" end
NEXT_DESC.nobleext = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return string.format("Sealed chamber sparking -- %d/150 charge to the next Noble gas canister", m.charge or 0)
end
local NOBLE_RATE = 150
local function buildNobleExt(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 3, gy - 6, wx + 3, gy, STEELMAT)
  clearBox(wx - 2, gy - 5, wx + 2, gy - 1)   -- sealed pocket, genuinely airtight (no open side)
  setAt(wx - 3, gy - 3, "GLAS")              -- sight window onto the sealed chamber
  setAt(wx + 3, gy + 1, "PSCN")              -- power pad
  R.acqm[#R.acqm + 1] = { kind = "nobleext", x = wx, y = gy,
    pad = { x = wx + 3, y = gy + 1 }, sight = { x = wx, y = gy - 3 }, charge = 0 }
  say("Noble gas extractor placed - power the pad to ionize the sealed chamber")
end
local function updateNobleExt()
  for _, m in ipairs(R.acqm) do if m.kind == "nobleext" then
    if poweredAt(m.pad.x, m.pad.y, 1) then
      m.charge = (m.charge or 0) + 1
      if m.charge >= NOBLE_RATE then
        m.charge = 0
        setAt(m.sight.x, m.sight.y, "NBLE")   -- real ionization event, visible for one frame
        R.give("NBLE", 1)
        say("+1 Noble gas")
        if R.tlog then R.tlog("info", "acq_machines", "noble gas extracted", { x = m.x, y = m.y }) end
      end
    end
  end end
end

-- ================================================================================================
-- MACHINE 2: Brine Electrolysis Cell -- the alkali-metal route. "Historically how they were first
-- isolated, so it is a genuine tech gate rather than an arbitrary one" (task brief, verbatim).
-- LITH is this fork's one stock alkali metal with a real acquisition design (design-material-
-- progression.md chain 8: a hazardous, water-adjacent-restricted mined vein). This machine is
-- that chain's own stated safety net in practice -- "every mined material also gets a secondary
-- route" (part 1 S6) -- a slow but genuinely renewable craft-tier alternative that works even if
-- the vein is sparse, not yet placed, or mis-calibrated on first placement (the exact failure
-- @veins' own pass hit twice on other veins, per rpg-hub.md 2026-09-02: DEUT/ISZS measured 12x too
-- rare, PTNM 3.5x too common, on first placement). Output is a real LITH particle (LITH is already
-- R.MINEABLE=3, added 2026-09-02 by @veins for their own vein -- so this machine's output is
-- immediately player-minable with zero new collection code, exactly like the SALT/MERC precedent).
-- ================================================================================================
NAME.brineelectro = "Brine Electrolysis Cell"
MBOX.brineelectro = { 0, -4, 8 }
IDLE_HINT.brineelectro = "Pour real SLTW into the top well, then power the pad"
STATE_DESC.brineelectro = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "unpowered" end
  return (typeAt(m.well.x, m.well.y) == "SLTW") and "electrolysing" or "well empty"
end
NEXT_DESC.brineelectro = function(m)
  if typeAt(m.well.x, m.well.y) ~= "SLTW" then return "Pour real SLTW (bucket) into the top well" end
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return string.format("Electrolysing: %d/6 brine charges to a real Lithium particle at the left vent", m.lithCharge or 0)
end
local function buildBrineElectro(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  -- QRTZ tank, not steel: real brine-electrolysis lab apparatus reads as glassware, and it visually
  -- distinguishes this cell from the existing steel ELECTROLYSISKIT (machines2.lua) at a glance
  boxFill(wx - 3, gy - 6, wx + 3, gy, "QRTZ")
  clearBox(wx - 2, gy - 5, wx + 2, gy - 1)
  setAt(wx - 1, gy - 4, WMAT); setAt(wx - 1, gy - 3, WMAT)
  setAt(wx + 1, gy - 4, WMAT); setAt(wx + 1, gy - 3, WMAT)
  setAt(wx - 3, gy - 6, "GLAS"); setAt(wx - 4, gy - 7, "GLAS")
  setAt(wx + 3, gy - 6, "GLAS"); setAt(wx + 4, gy - 7, "GLAS")
  setAt(wx + 3, gy + 1, "PSCN")
  R.acqm[#R.acqm + 1] = { kind = "brineelectro", x = wx, y = gy,
    well = { x = wx, y = gy - 2 }, pad = { x = wx + 3, y = gy + 1 },
    vlith = { x = wx - 5, y = gy - 8 }, cool = 0, lithCharge = 0 }
  say("Brine electrolysis cell placed - pour real SLTW in the top well and wire the pad")
end
local function updateBrineElectro()
  for _, m in ipairs(R.acqm) do if m.kind == "brineelectro" then
    m.cool = (m.cool or 0) - 1
    if poweredAt(m.pad.x, m.pad.y, 1) and m.cool <= 0 and typeAt(m.well.x, m.well.y) == "SLTW" then
      killAt(m.well.x, m.well.y)
      -- Lithium is the slow, valuable half of the reaction: only every 6th brine charge actually
      -- yields a real LITH particle at the vent (HYGN is also a real cathode byproduct of this
      -- reaction, but is NOT vented separately here -- acq_fluids.lua's Chem Canister already
      -- covers HYGN acquisition; venting a second HYGN source would just be noise, not a new route)
      m.lithCharge = (m.lithCharge or 0) + 1
      if m.lithCharge >= 6 and not typeAt(m.vlith.x, m.vlith.y) then
        setAt(m.vlith.x, m.vlith.y, "LITH"); m.lithCharge = 0
        if R.tlog then R.tlog("info", "acq_machines", "brine electrolysis yielded LITH", { x = m.x, y = m.y }) end
      end
      m.cool = 40
    end
  end end
end

-- ================================================================================================
-- MACHINE 3: Ore Reduction Furnace -- "ore + reductant -> metal", the richest single chain per the
-- brief. A lit COAL firebox (the reductant) heats a steel retort holding one ore-slot charge; real
-- carbothermic ore reduction, same idiom as the existing acid synthesizer's "lit bed -> real
-- chemistry" but for metal recovery. Two recognized ore inputs (RBDM deliberately dropped, see
-- file header -- acq_special.lua's own claimed, deliberately-blocked territory):
--   BRMT  -> METL   (BRMT is already R.MINEABLE=2 today, rpg.lua:2355 -- reachable this pass with
--           zero dependency on any other lane's work)
--   ROCK  -> random one of METL/CU/GOLD (the literal STOCK element, "melts into various elements"
--           per its own description -- design-material-progression-part2.md chain 18's own
--           "multi-output smelt... randomized bonus of METL/CU/GOLD fragments"; addressed here
--           only via the quoted string "ROCK", which resolves through R.eid to the real stock
--           element -- this file never reads or writes rpg.lua's own unrelated local Lua variable
--           also named ROCK, so the design doc's own warned naming collision cannot occur here.
--           ROCK is itself now reachable TODAY: acq_solids.lua already ships `{out="ROCK",
--           need={STNE=6}, st="anvil"}` (verified by reading it directly) with, at the time this
--           file was written, ZERO downstream consumer anywhere in either tree -- this furnace is
--           that consumer, giving a previously-purposeless material an actual use rather than
--           adding a second acquisition route for it)
-- ================================================================================================
NAME.orereduct = "Ore Reduction Furnace"
MBOX.orereduct = { 0, -4, 8 }
IDLE_HINT.orereduct = "Light the firebox, then feed ore + Coal into the two charge slots"
STATE_DESC.orereduct = function(m) return (typeAt(m.bed.x, m.bed.y) == "FIRE") and "firebox lit" or "firebox cold" end
NEXT_DESC.orereduct = function(m)
  if typeAt(m.bed.x, m.bed.y) ~= "FIRE" then return "Light the coal bed with a torch" end
  local ore = typeAt(m.oreSlot.x, m.oreSlot.y)
  if ore ~= "ROCK" and ore ~= "BRMT" then
    return "Drop stock Rock (Fused Rock) or Bronze (BRMT) ore into the left slot"
  end
  if typeAt(m.coalSlot.x, m.coalSlot.y) ~= "COAL" then return "Add Coal (reductant) into the right slot" end
  return "Cooking: " .. ore .. " + Coal -> reduced metal, drops into the basin below"
end
local function buildOreReduct(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 3, gy - 2, wx + 3, gy, "BRCK")
  setAt(wx - 2, gy - 1, "COAL"); setAt(wx - 1, gy - 1, "COAL"); setAt(wx, gy - 1, "COAL")
  setAt(wx + 1, gy - 1, "COAL"); setAt(wx + 2, gy - 1, "COAL")
  boxFill(wx - 2, gy - 7, wx + 2, gy - 3, STEELMAT)   -- steel retort: higher-temp reduction, not acid-safe QRTZ
  clearBox(wx - 2, gy - 6, wx - 1, gy - 4)   -- ore charge slot (left)
  clearBox(wx + 1, gy - 6, wx + 2, gy - 4)   -- coal reductant slot (right)
  setAt(wx - 2, gy - 6, "GLAS")   -- sight strip
  boxFill(wx - 1, gy + 1, wx + 1, gy + 2, "GLAS")
  clearBox(wx, gy + 1, wx, gy + 1)
  R.acqm[#R.acqm + 1] = { kind = "orereduct", x = wx, y = gy,
    bed = { x = wx, y = gy - 1 }, oreSlot = { x = wx - 2, y = gy - 5 }, coalSlot = { x = wx + 2, y = gy - 5 },
    basin = { x = wx, y = gy + 1 }, cool = 0 }
  say("Ore reduction furnace placed - light the coal bed, then feed ore (left) + Coal (right)")
end
local ROCK_BONUS = { "METL", "CU", "GOLD" }
local function updateOreReduct()
  for _, m in ipairs(R.acqm) do if m.kind == "orereduct" then
    m.cool = (m.cool or 0) - 1
    local lit = typeAt(m.bed.x, m.bed.y) == "FIRE"
    local ore = typeAt(m.oreSlot.x, m.oreSlot.y)
    if lit and m.cool <= 0 and typeAt(m.coalSlot.x, m.coalSlot.y) == "COAL"
       and (ore == "ROCK" or ore == "BRMT") and not typeAt(m.basin.x, m.basin.y) then
      killAt(m.oreSlot.x, m.oreSlot.y); killAt(m.coalSlot.x, m.coalSlot.y)
      local out = (ore == "BRMT") and "METL" or ROCK_BONUS[math.random(1, 3)]
      setAt(m.basin.x, m.basin.y, out)
      if R.tlog then R.tlog("info", "acq_machines", "ore reduction output", { ore = ore, out = out }) end
      m.cool = 70
    end
  end end
end

-- ================================================================================================
-- MACHINE 4: Isotope Enrichment Centrifuge -- "natural uranium really is 0.72% U-235; the design
-- docs and ACCRETION's nuclide data both carry the real abundances." Feeds on real URAN (already
-- R.MINEABLE=4, rpg.lua:2355 -- proven, diamond-pick-tier mineable baseline, zero dependency on
-- any other lane). design-material-progression.md chain 3 assigns ISOZ/ISZS a MINE verb (a sibling
-- vein to URAN, not yet placed as of this pass) -- this machine is that chain's own stated safety
-- net (part 1 S6, "every mined material also gets a secondary route"), exactly as brineelectro is
-- for LITH above. ISZS is the primary output: already R.MINEABLE=4 (added 2026-09-02 by @veins for
-- their own vein), so it is a real solid particle the player mines out of the tray with zero new
-- collection code, matching the SALT/MERC/PTNM/BMTL precedent exactly (per file header). ISOZ
-- (liquid, no R.MINEABLE possible) is the rarer secondary output, granted via R.give per the file
-- header's stated reasoning. The 18:1 URAN:batch ratio below is a stated GAMEPLAY ratio, not a
-- literal 1/0.0072~=139:1 reproduction of real U-235 abundance -- that literal ratio would cost
-- more raw ore for one unit of enriched fuel than the entire existing reactor recipe chain
-- combined, a real design choice documented here so nobody reads "0.72%" out of this comment and
-- assumes the ratio is literal.
-- ================================================================================================
NAME.enrich = "Isotope Enrichment Centrifuge"
MBOX.enrich = { 0, -5, 8 }
IDLE_HINT.enrich = "Power the pad, then feed real Uranium ore into the hopper slot"
STATE_DESC.enrich = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "spinning" or "unpowered" end
NEXT_DESC.enrich = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return string.format("Enriching: %d/18 Uranium fed this batch -- solid Isotope fuel taps at the base", m.uCount or 0)
end
local ENRICH_BATCH = 18
local function buildEnrich(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  local cx, cy = wx, gy - 6
  ring(cx, cy, 5, STEELMAT, 1); clearBox(cx - 3, cy - 3, cx + 3, cy + 3)
  setAt(cx, cy - 6, "GLAS")             -- hopper slot, open top of the drum
  boxFill(wx - 1, gy - 1, wx + 1, gy, "GLAS")   -- output tray at the base (solid ISZS taps here)
  clearBox(wx, gy - 1, wx, gy - 1)
  setAt(wx - 2, gy - 5, "GLAS")         -- secondary sight window for the rarer liquid ISOZ tap
  setAt(wx - 5, cy, "PSCN")             -- power pad on the housing side
  R.acqm[#R.acqm + 1] = { kind = "enrich", x = wx, y = gy, cx = cx, cy = cy,
    hopper = { x = cx, y = cy - 6 }, tray = { x = wx, y = gy - 1 }, sight = { x = wx - 2, y = gy - 5 },
    pad = { x = wx - 5, y = cy }, angle = 0, uCount = 0, batches = 0 }
  say("Isotope enrichment centrifuge placed - power the pad, feed real Uranium into the hopper slot")
end
local function updateEnrich()
  for _, m in ipairs(R.acqm) do if m.kind == "enrich" then
    if poweredAt(m.pad.x, m.pad.y, 1) then
      m.angle = (m.angle or 0) + 0.5
      local p = partAt(m.hopper.x, m.hopper.y)
      if p and nameOf(sim.partProperty(p, "type")) == "URAN" then
        sim.partKill(p); m.uCount = (m.uCount or 0) + 1
      end
      if (m.uCount or 0) >= ENRICH_BATCH then
        m.uCount = m.uCount - ENRICH_BATCH
        m.batches = (m.batches or 0) + 1
        -- 1 in 4 batches yields the rarer liquid form (ISOZ) instead of the primary solid (ISZS,
        -- "safer transport" per design doc chain 3) -- ISZS is the R.MINEABLE-registered, directly
        -- pick-collectible primary output; ISOZ is granted via R.give (see file header)
        if m.batches % 4 == 0 then
          setAt(m.sight.x, m.sight.y, "ISOZ")
          R.give("ISOZ", 1)
          say("Enrichment batch complete: +1 Isotope liquid")
        elseif not typeAt(m.tray.x, m.tray.y) then
          setAt(m.tray.x, m.tray.y, "ISZS")
          say("Enrichment batch complete: real Isotope solid in the base tray")
        end
        if R.tlog then R.tlog("info", "acq_machines", "enrichment batch complete", { batches = m.batches }) end
      end
    end
  end end
end

hook(R.hooks.tick, function()
  updateNobleExt(); updateBrineElectro(); updateOreReduct(); updateEnrich()
end)

hook(R.hooks.draw, function()
  for _, m in ipairs(R.acqm) do
    if m.kind == "enrich" and poweredAt(m.pad.x, m.pad.y, 1) then
      local cx, cy = m.cx - R.cam.x, m.cy - R.cam.y
      local a = m.angle or 0
      graphics.drawLine(cx, cy, cx + math.cos(a) * 4, cy + math.sin(a) * 4, 200, 220, 255, 255)
    elseif m.kind == "nobleext" and poweredAt(m.pad.x, m.pad.y, 1) then
      local cx, cy = m.sight.x - R.cam.x, m.sight.y - R.cam.y
      local pulse = 2 + math.sin((R.frame or 0) * 0.15) * 2
      graphics.drawCircle(cx, cy, math.floor(pulse), 150, 200, 255, 140)
    end
  end
end)

-- ================================================================ crafting: R.RECIPES + R.ITEMS + place
R.ITEMS = R.ITEMS or {}
local BUILDERS = {
  NOBLEEXTRACTKIT = buildNobleExt,
  BRINEELECTROKIT = buildBrineElectro,
  OREREDUCTKIT = buildOreReduct,
  ENRICHKIT = buildEnrich,
}
hook(R.hooks.place, function(el, mx, my, fine)
  local b = BUILDERS[el]; if not b then return end
  if (R.frame - (R.lastAcqPlace or -99)) < 20 then return true end
  R.lastAcqPlace = R.frame
  R.inventory[el] = R.inv(el) - 1
  local ok, err = pcall(b, mx, my); if not ok then R.pluginErr = tostring(err) end
  R.rebuildHotbar()
  return true
end)

local function need(...) local t = {}; local a = { ... }; for i = 1, #a, 2 do t[a[i]] = a[i + 1] end; return t end
local ACQ_RECIPES = {
  { out = "NOBLEEXTRACTKIT", n = 1, need = need("STEL", 6, "GLAS", 2, "CU", 2), st = "advlab", txt = "Noble gas extractor",
    desc = "A sealed steel chamber that ionizes trapped ambient air into real Noble gas when sparked -- the same 'spark a sealed pocket, canister fills' process real noble-gas extraction uses, self-contained in one build" },
  { out = "BRINEELECTROKIT", n = 1, need = need("QRTZ", 6, "CU", 4, "INSL", 1), st = "research", txt = "Brine electrolysis cell",
    desc = "Electrolyses real SLTW brine to recover real metallic Lithium at the cathode -- the same commercial process real lithium brine operations use, historically how alkali metals were first isolated at all" },
  { out = "OREREDUCTKIT", n = 1, need = need("STEL", 8, "BRCK", 6, "COAL", 2), st = "anvil", txt = "Ore reduction furnace",
    desc = "A lit coal firebox carbothermically reduces real ore in the retort -- feed Bronze scrap for Metal, or Fused Rock for a random Metal/Copper/Gold bonus, real ore-plus-reductant chemistry" },
  { out = "ENRICHKIT", n = 1, need = need("STEL", 10, "CU", 4, "GLAS", 2), st = "advlab", txt = "Isotope enrichment centrifuge",
    desc = "Feed real Uranium ore into the spinning drum -- after a real batch is processed, separates a real Isotope-solid fuel tap, with a rarer Isotope-liquid tap on some batches" },
}
for _, rc in ipairs(ACQ_RECIPES) do
  R.ITEMS[rc.out] = R.ITEMS[rc.out] or {
    col = (rc.st == "advlab") and { 140, 190, 220 }
       or (rc.st == "research") and { 120, 170, 150 }
       or (rc.st == "anvil") and { 150, 155, 165 }
       or { 190, 185, 175 },
    desc = rc.desc,
  }
end
local function installRecipes()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(ACQ_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
end
installRecipes()
hook(R.hooks.newworld, function()
  R.acqm = {}; R.acqmPanel = nil
  installRecipes()
end)
hook(R.hooks.sandbox, function() installRecipes() end)

-- ================================================================ save/load: generic plain-data
-- dump via save.lua, same convention as every other plugin's final block
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
do
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == "acqm" then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, "acqm") end
end
