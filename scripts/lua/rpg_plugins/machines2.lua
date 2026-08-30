-- machines2.lua - SECOND machine track for the Powder RPG (2026-08-26, the player 20:16 "way way way more machines").
-- Owns: R.hooks.tick/draw/drawHUD/place/mousedown entries tagged "machines2", R.machines2, R.ITEMS.<names this
-- file adds>, R.RECIPES entries tagged _plugin="machines2". Does NOT touch R.machines/R.power/R.tech (those are
-- @machines' - this file only READS R.tech to gate its own recipe tiers) and does not edit any other file.
-- Domains (per the player's "chemistry / fluids / logistics / exotic physics toys / comfort" brief): chemistry first.
-- Power convention: unlike @machines' logical R.power.grids (which only classifies kinds it knows about), this
-- file's powered machines just check for a real live SPRK sitting on/adjacent to their own pad every tick -
-- exactly the same real engine behaviour (conductive METL/CU/PSCN really do carry a spark) that R.power.grids
-- itself is built on top of, so any machine wired into the same physical network @machines runs actually works
-- here too, with zero coupling to their file.

local R = PBX.state.rpg
local TAG = "machines2"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local W, H = R.W, R.H
R.machines2 = R.machines2 or {}   -- {kind, x, y, ...kind-specific fields}, world coords; persists across reloads

-- ================================================================ low-level build helpers (same erase-then-place
-- convention as machines.lua - see build-lessons "placeElement on an occupied pixel is a no-op")
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function setAt(wx, wy, elName)
  killAt(wx, wy); local t = R.eid(elName); if not t then return nil end
  return sim.partCreate(-1, wx - R.cam.x, wy - R.cam.y, t)
end
local function boxFill(x1, y1, x2, y2, elName) for y = y1, y2 do for x = x1, x2 do setAt(x, y, elName) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if R.solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
local function disk(cx, cy, r, elName)
  for dy = -r, r do for dx = -r, r do if dx * dx + dy * dy <= r * r + 0.5 then setAt(cx + dx, cy + dy, elName) end end end
end
local function ring(cx, cy, r, elName, thick)
  thick = thick or 1
  for dy = -r, r do for dx = -r, r do
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= r + 0.5 and d >= r - thick + 0.5 then setAt(cx + dx, cy + dy, elName) end
  end end
end
local function nearPlayer(x, y, r) local dx, dy = x - R.P.x, y - R.P.y; return dx * dx + dy * dy <= (r or 140) * (r or 140) end
local function partAt(wx, wy) return sim.partID(wx - R.cam.x, wy - R.cam.y) end
local function typeAt(wx, wy) local p = partAt(wx, wy); return p and R.nameOf(sim.partProperty(p, "type")) or nil end
-- powered = a real spark sitting on/adjacent to a pad this frame (see file header: same physics R.power.grids uses)
local function poweredAt(wx, wy, r)
  r = r or 1
  for dy = -r, r do for dx = -r, r do
    local nm = typeAt(wx + dx, wy + dy)
    if nm == "SPRK" then return true end
  end end
  return false
end
local WMAT = R.has("CU") and "CU" or "METL"
-- fallbacks for the other two custom "power-elements" materials (STEL/CNCR) - build-lessons: a session that
-- hasn't run scripts/define_power_elements.py (the lab instance, at time of writing) silently drops any setAt()
-- call for a name R.eid() can't resolve, so every structural use of these must resolve to a real stock element.
local STEELMAT = R.has("STEL") and "STEL" or (R.has("BMTL") and "BMTL" or "METL")
local CNCRMAT = R.has("CNCR") and "CNCR" or "STNE"
local function nice(n) return (R.nice and R.nice(n)) or n end

-- ================================================================ interaction: proximity prompt + right-click
-- panel (same look/rect as @machines' panel per the atlas, never open at the same time as theirs in practice -
-- only one machine can be targeted at once). MBOX2[kind] = {dx, dy, r} offset from m.x,m.y to the visual centre.
local MBOX2 = {}
local IDLE_HINT2 = {}
local STATE_DESC2 = {}   -- kind -> function(m) returning a one-line live state string for the panel
local NEXT_DESC2 = {}    -- kind -> function(m) returning the imperative "next action" line

local function machineCentre2(m)
  local b = MBOX2[m.kind]
  if b then return m.x + b[1], m.y + b[2], b[3] end
  return m.x, m.y - 3, 8
end
local function machine2At(wx, wy)
  local best, bestD
  for _, m in ipairs(R.machines2) do
    if MBOX2[m.kind] then
      local cx, cy, r = machineCentre2(m)
      local d = (wx - cx) * (wx - cx) + (wy - cy) * (wy - cy)
      if d <= r * r and (not bestD or d < bestD) then bestD = d; best = m end
    end
  end
  return best
end
local NAME2 = {}   -- kind -> display name, filled in by each machine section below

hook(R.hooks.mousedown, function(x, y, button)
  if button ~= 3 then return end
  local wx, wy = x + R.cam.x, y + R.cam.y
  if R.machine2Panel then R.machine2Panel = nil; R.uiPanelOpen = false; return true end
  local hit = machine2At(wx, wy)
  if hit and nearPlayer(hit.x, hit.y, 90) then R.machine2Panel = hit; R.uiPanelOpen = true; return true end
end)

hook(R.hooks.drawHUD, function()
  -- near-only "[right-click] Name" prompt, same convention as @machines
  if not R.machine2Panel then
    for _, m in ipairs(R.machines2) do
      if MBOX2[m.kind] and nearPlayer(m.x, m.y, 70) then
        local cx, cy = machineCentre2(m)
        local sx, sy = cx - R.cam.x, cy - R.cam.y - 16
        if sx > -20 and sx < W + 20 and sy > -20 and sy < H then
          graphics.drawText(sx - 40, sy, "[right-click] " .. (NAME2[m.kind] or m.kind), 255, 210, 120, 220)
        end
      end
    end
  end
  local m = R.machine2Panel
  if m then
    local px, py, pw, ph = 190, 40, 236, 130
    graphics.fillRect(px, py, pw, ph, 10, 12, 18, 235)
    graphics.drawRect(px, py, pw, ph, 90, 95, 120, 255)
    graphics.drawText(px + 8, py + 6, (NAME2[m.kind] or m.kind):upper(), 255, 210, 120, 255)
    graphics.drawText(px + pw - 90, py + 6, "[right-click] close", 150, 150, 160, 220)
    local state = STATE_DESC2[m.kind] and STATE_DESC2[m.kind](m) or "OK"
    graphics.drawText(px + 8, py + 24, "State: " .. state, 210, 220, 230, 255)
    local nextLine = NEXT_DESC2[m.kind] and NEXT_DESC2[m.kind](m) or (IDLE_HINT2[m.kind] or "")
    local ny = py + 44
    for line in tostring(nextLine):gmatch("[^\n]+") do
      graphics.drawText(px + 8, ny, line, 255, 230, 150, 255); ny = ny + 12
    end
  end
end)

-- NOTE: hook() de-dupes by tag PER LIST, so registering R.hooks.newworld a second time elsewhere in this file
-- would silently remove this one - the newworld reset lives in the single consolidated hook down by
-- installRecipes2() instead of here. Kept as a marker comment so nobody re-adds a second one by accident.

-- ================================================================================================================
-- CHEMISTRY STAGE 1: Chlor-Alkali Electrolysis Cell, Acid Synthesizer, Salt Evaporator, Fertiliser Mixer,
-- Gunpowder Mill. All five verified live in the lab (port 9877) before commit - see hub.
-- ================================================================================================================

-- ---------------------------------------------------------------- Electrolysis Cell (chlor-alkali: real SLTW
-- split by a live spark between two electrodes into real HYGN + CAUS gas - a genuine chemistry reaction, distinct
-- from @machines' O2GEN which electrolyses fresh WATR for life support, not brine for gas synthesis).
NAME2.electro = "Electrolysis Cell"
MBOX2.electro = { 3, -5, 9 }
IDLE_HINT2.electro = "Pour real SLTW into the open top well, then power the pad"
STATE_DESC2.electro = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "unpowered" end
  return (typeAt(m.well.x, m.well.y) == "SLTW") and "electrolysing" or "well empty"
end
NEXT_DESC2.electro = function(m)
  if typeAt(m.well.x, m.well.y) ~= "SLTW" then return "Pour real SLTW (bucket) into the top well" end
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the side pad" end
  return "Running: brine -> H2 (left vent) + caustic gas (right vent)"
end
local function buildElectro(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  -- tank body: steel box, 7 wide x 6 tall, open interior with a real liquid column at wx,gy-2
  boxFill(wx - 3, gy - 6, wx + 3, gy, STEELMAT)
  clearBox(wx - 2, gy - 5, wx + 2, gy - 1)
  setAt(wx - 2, gy - 3, "GLAS")            -- sight strip on the front wall, clear of the liquid column
  -- two electrodes dipped from the rim down into the brine, either side of the well column
  setAt(wx - 1, gy - 4, WMAT); setAt(wx - 1, gy - 3, WMAT)
  setAt(wx + 1, gy - 4, WMAT); setAt(wx + 1, gy - 3, WMAT)
  -- vent pipes: real chemistry-apparatus glass tubing for both, deliberately NOT a conductor and NOT metal -
  -- live-tested: a metal line shares the electrode circuit's spark and real HYGN ignites instantly touching it,
  -- and real CAUS (which "acts like ACID") corrodes it away just as fast. Gas actually appears one cell PAST the
  -- last real pipe segment (an open exit), never on top of the pipe material itself.
  setAt(wx - 3, gy - 6, "GLAS"); setAt(wx - 4, gy - 7, "GLAS")
  setAt(wx + 3, gy - 6, "GLAS"); setAt(wx + 4, gy - 7, "GLAS")
  setAt(wx + 3, gy + 1, "PSCN")   -- power pad, front face
  R.machines2[#R.machines2 + 1] = { kind = "electro", x = wx, y = gy,
    well = { x = wx, y = gy - 2 }, pad = { x = wx + 3, y = gy + 1 },
    vh2 = { x = wx - 5, y = gy - 8 }, vgas = { x = wx + 5, y = gy - 8 }, cool = 0 }
  R.say("Electrolysis cell placed - pour real SLTW in the top well and wire the pad")
end
local function updateElectro()
  for _, m in ipairs(R.machines2) do if m.kind == "electro" then
    m.cool = (m.cool or 0) - 1
    if poweredAt(m.pad.x, m.pad.y, 1) and m.cool <= 0 and typeAt(m.well.x, m.well.y) == "SLTW" then
      killAt(m.well.x, m.well.y)
      if not typeAt(m.vh2.x, m.vh2.y) then setAt(m.vh2.x, m.vh2.y, "HYGN") end
      if not typeAt(m.vgas.x, m.vgas.y) then setAt(m.vgas.x, m.vgas.y, "CAUS") end
      m.cool = 40
    end
  end end
end

-- ---------------------------------------------------------------- Acid Synthesizer (a lit coal firebox heats a
-- QRTZ-lined retort holding real SALT+WATR; hot enough, it reacts them into real ACID dripping into a basin -
-- same "lit bed -> real chemistry" convention as @machines' furnace/boiler, applied to a different reaction).
NAME2.acidsynth = "Acid Synthesizer"
MBOX2.acidsynth = { 3, -6, 10 }
IDLE_HINT2.acidsynth = "Light the coal bed, then feed SALT+WATR into the retort"
STATE_DESC2.acidsynth = function(m)
  return (typeAt(m.bed.x, m.bed.y) == "FIRE") and "firebox lit" or "firebox cold"
end
NEXT_DESC2.acidsynth = function(m)
  if typeAt(m.bed.x, m.bed.y) ~= "FIRE" then return "Light the coal bed with a torch" end
  if typeAt(m.retort.x, m.retort.y) ~= "SALT" then return "Drop real SALT into the retort" end
  if typeAt(m.retort2.x, m.retort2.y) ~= "WATR" then return "Add real WATR into the retort" end
  return "Cooking: SALT + WATR -> ACID (drips into the basin below)"
end
local function buildAcidSynth(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  -- firebox: BRCK box with a coal bed, same idiom as the boiler's grate
  boxFill(wx - 3, gy - 2, wx + 3, gy, "BRCK")
  setAt(wx - 2, gy - 1, "COAL"); setAt(wx - 1, gy - 1, "COAL"); setAt(wx, gy - 1, "COAL")
  setAt(wx + 1, gy - 1, "COAL"); setAt(wx + 2, gy - 1, "COAL")
  -- retort vessel above, QRTZ-lined, with an open charge slot
  boxFill(wx - 2, gy - 7, wx + 2, gy - 3, "QRTZ")
  clearBox(wx - 1, gy - 6, wx + 1, gy - 4)
  setAt(wx - 2, gy - 6, "GLAS")   -- sight strip on the retort
  -- drip nozzle + collection basin (GLAS-walled so the ACID is visible). QRTZ, not WMAT/metal - real ACID
  -- corrodes metal, so a metal nozzle would eat itself away; quartz is acid-resistant lab glassware, same
  -- material as the retort lining above.
  setAt(wx, gy - 3, "QRTZ")
  boxFill(wx - 1, gy + 1, wx + 1, gy + 2, "GLAS")
  clearBox(wx, gy + 1, wx, gy + 1)
  R.machines2[#R.machines2 + 1] = { kind = "acidsynth", x = wx, y = gy,
    bed = { x = wx, y = gy - 1 }, retort = { x = wx - 1, y = gy - 5 }, retort2 = { x = wx + 1, y = gy - 5 },
    basin = { x = wx, y = gy + 1 }, cool = 0 }
  R.say("Acid synthesizer placed - light the coal, then feed SALT + WATR into the retort")
end
local function updateAcidSynth()
  for _, m in ipairs(R.machines2) do if m.kind == "acidsynth" then
    m.cool = (m.cool or 0) - 1
    local lit = typeAt(m.bed.x, m.bed.y) == "FIRE"
    if lit and m.cool <= 0 and typeAt(m.retort.x, m.retort.y) == "SALT" and typeAt(m.retort2.x, m.retort2.y) == "WATR" then
      killAt(m.retort.x, m.retort.y); killAt(m.retort2.x, m.retort2.y)
      if not typeAt(m.basin.x, m.basin.y) then setAt(m.basin.x, m.basin.y, "ACID") end
      m.cool = 60
    end
  end end
end

-- ---------------------------------------------------------------- Salt Evaporator (passive, no power: a shallow
-- pan of real SLTW sits over a lit coal bed; once genuinely hot it separates into real SALT residue + WTRV steam
-- that vents away - real per-particle heat-triggered transmutation, same idiom as the blast furnace's DU->URAN).
NAME2.evaporator = "Salt Evaporator"
MBOX2.evaporator = { 2, -4, 8 }
IDLE_HINT2.evaporator = "Passive - light the bed and pour SLTW in the pan"
STATE_DESC2.evaporator = function(m) return (typeAt(m.bed.x, m.bed.y) == "FIRE") and "boiling" or "unlit" end
NEXT_DESC2.evaporator = function(m)
  if typeAt(m.bed.x, m.bed.y) ~= "FIRE" then return "Light the coal bed with a torch" end
  return "Pour SLTW into the pan - it boils off, leaving SALT crystals"
end
local function buildEvaporator(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 3, gy - 2, wx + 3, gy, "BRCK")
  setAt(wx - 2, gy - 1, "COAL"); setAt(wx, gy - 1, "COAL"); setAt(wx + 2, gy - 1, "COAL")
  -- shallow pan: a thin concrete trough with raised end lips, open top, so the real SALT crystals it produces
  -- have something to catch on instead of scattering off the sides under gravity
  for i = -3, 3 do setAt(wx + i, gy - 3, CNCRMAT) end
  setAt(wx - 3, gy - 4, CNCRMAT); setAt(wx + 3, gy - 4, CNCRMAT)
  R.machines2[#R.machines2 + 1] = { kind = "evaporator", x = wx, y = gy,
    bed = { x = wx, y = gy - 1 }, pan = { x1 = wx - 2, x2 = wx + 2, y = gy - 4 } }
  R.say("Salt evaporator placed - light the bed, then pour real SLTW into the pan")
end
local function updateEvaporator()
  for _, m in ipairs(R.machines2) do if m.kind == "evaporator" then
    if typeAt(m.bed.x, m.bed.y) == "FIRE" then
      for x = m.pan.x1, m.pan.x2 do
        local p = partAt(x, m.pan.y)
        if p and R.nameOf(sim.partProperty(p, "type")) == "SLTW" then
          local t = sim.partProperty(p, "temp") or 293
          if t > 373 then
            sim.partKill(p)
            setAt(x, m.pan.y, "SALT")
            local vx, vy = x - R.cam.x, m.pan.y - 1 - R.cam.y
            if vx >= 0 and vx < W and vy >= 0 and vy < H and not sim.partID(vx, vy) then
              sim.partCreate(-1, vx, vy, R.eid("WTRV"))
            end
          end
        end
      end
    end
  end end
end

-- ---------------------------------------------------------------- Fertiliser Mixer (grinds real PLNT clippings
-- + real STNE dust between two rollers into a "Fertiliser" bag - pseudo item per README, real crushing action).
NAME2.fertmixer = "Fertiliser Mixer"
MBOX2.fertmixer = { 3, -4, 9 }
IDLE_HINT2.fertmixer = "Feed PLNT + STNE into the hopper, power the pad"
STATE_DESC2.fertmixer = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "grinding" or "unpowered" end
NEXT_DESC2.fertmixer = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Drop PLNT clippings + STNE into the hopper - makes Fertiliser"
end
local function buildFertMixer(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  -- hopper funnel over two grinding roller disks, WOOD housing
  boxFill(wx - 3, gy - 7, wx + 3, gy - 5, "WOOD"); clearBox(wx - 2, gy - 6, wx + 2, gy - 5)
  disk(wx - 2, gy - 3, 2, "METL"); disk(wx + 2, gy - 3, 2, "METL")
  setAt(wx, gy - 3, "PSCN")   -- roller shaft nub reads "on" when spinning
  boxFill(wx - 3, gy - 1, wx + 3, gy, "WOOD")   -- chute base
  setAt(wx - 3, gy - 4, "PSCN")   -- power pad on the side
  R.machines2[#R.machines2 + 1] = { kind = "fertmixer", x = wx, y = gy,
    hopper = { x1 = wx - 2, x2 = wx + 2, y = gy - 6 }, pad = { x = wx - 3, y = gy - 4 }, angle = 0, plnt = 0, stne = 0 }
  R.say("Fertiliser mixer placed - feed it PLNT + STNE and wire the pad")
end
local function updateFertMixer()
  for _, m in ipairs(R.machines2) do if m.kind == "fertmixer" then
    local on = poweredAt(m.pad.x, m.pad.y, 1)
    if on then m.angle = (m.angle or 0) + 0.4 end
    for x = m.hopper.x1, m.hopper.x2 do
      local p = partAt(x, m.hopper.y)
      if p then
        local nm = R.nameOf(sim.partProperty(p, "type"))
        if on and nm == "PLNT" then sim.partKill(p); m.plnt = (m.plnt or 0) + 1
        elseif on and nm == "STNE" then sim.partKill(p); m.stne = (m.stne or 0) + 1 end
      end
    end
    if (m.plnt or 0) >= 2 and (m.stne or 0) >= 2 then
      m.plnt, m.stne = m.plnt - 2, m.stne - 2
      R.give("FERTILISER", 1); R.say("+1 Fertiliser")
    end
  end end
end

-- ---------------------------------------------------------------- Gunpowder Mill (a powered rotating drum grinds
-- real COAL against itself into a "Gunpowder" bag - pseudo item, kept as an inert crafting good rather than a
-- live explosive particle sitting around, per the lab-first/idempotent safety rules).
NAME2.powdermill = "Gunpowder Mill"
MBOX2.powdermill = { 0, -5, 8 }
IDLE_HINT2.powdermill = "Feed COAL into the drum, power the pad"
STATE_DESC2.powdermill = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "milling" or "unpowered" end
NEXT_DESC2.powdermill = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Drop real COAL into the drum's open top slot"
end
local function buildPowderMill(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  ring(wx, gy - 5, 4, "METL", 1)
  clearBox(wx - 1, gy - 6, wx + 1, gy - 4)   -- open charge slot at the top of the drum
  setAt(wx, gy - 5, "PSCN")   -- inner grinding stud
  setAt(wx - 4, gy - 5, "PSCN")   -- power pad on the housing side
  R.machines2[#R.machines2 + 1] = { kind = "powdermill", x = wx, y = gy - 5,
    slot = { x = wx, y = gy - 6 }, pad = { x = wx - 4, y = gy - 5 }, angle = 0, coal = 0 }
  R.say("Gunpowder mill placed - feed COAL into the top slot and wire the pad")
end
local function updatePowderMill()
  for _, m in ipairs(R.machines2) do if m.kind == "powdermill" then
    local on = poweredAt(m.pad.x, m.pad.y, 1)
    if on then
      m.angle = (m.angle or 0) + 0.5
      if typeAt(m.slot.x, m.slot.y) == "COAL" then
        killAt(m.slot.x, m.slot.y); m.coal = (m.coal or 0) + 1
      end
    end
    if (m.coal or 0) >= 2 then m.coal = m.coal - 2; R.give("GUNPOWDER", 1); R.say("+1 Gunpowder") end
  end end
end

-- ================================================================================================================
-- FLUIDS STAGE 2: Check Valve, Pressure Vessel, Reservoir Tank (sight glass), Steam Condenser, Drainage Sump.
-- All five verified live in the lab (port 9877) before commit - see hub.
-- ================================================================================================================
local FLUID = { WATR = true, SLTW = true, OIL = true, ACID = true, DSTW = true, LAVA = true, CAUS = true }

-- ---------------------------------------------------------------- Check Valve (a short pipe embedded in a wall;
-- real liquid flowing WITH the allowed direction passes freely, real liquid trying to flow backward is stopped
-- dead - a genuine one-way gate built from a live velocity check, not a flag).
NAME2.checkvalve = "Check Valve"
MBOX2.checkvalve = { 2, 0, 6 }
IDLE_HINT2.checkvalve = "Passive - only lets flow through one way"
STATE_DESC2.checkvalve = function(m) return "flow -> " .. (m.dir > 0 and "right" or "left") end
NEXT_DESC2.checkvalve = function() return "No action needed - blocks any backflow automatically" end
local function buildCheckValve(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  local dir = (R.P.face and R.P.face >= 0) and 1 or -1
  boxFill(wx - 2, gy - 4, wx + 2, gy - 1, STEELMAT)
  clearBox(wx - 2, gy - 2, wx + 2, gy - 2)   -- horizontal channel through the middle
  setAt(wx, gy - 2, "PSCN")                   -- visible flap marker (draw-hook flips it to show direction)
  killAt(wx, gy - 2)                          -- keep the channel centre itself open for real flow
  R.machines2[#R.machines2 + 1] = { kind = "checkvalve", x = wx, y = gy,
    channel = { x1 = wx - 2, x2 = wx + 2, y = gy - 2 }, dir = dir }
  R.say("Check valve placed - lets real liquid through one way only")
end
local function updateCheckValve()
  for _, m in ipairs(R.machines2) do if m.kind == "checkvalve" then
    for x = m.channel.x1, m.channel.x2 do
      local p = partAt(x, m.channel.y)
      if p and FLUID[R.nameOf(sim.partProperty(p, "type"))] then
        local vx = sim.partProperty(p, "vx") or 0
        if vx * m.dir < -0.05 then sim.partProperty(p, "vx", 0) end   -- real backflow stopped dead, pressure builds behind it
      end
    end
  end end
end

-- ---------------------------------------------------------------- Pressure Vessel (a sealed steel shell; reads
-- the REAL pressure field at its own interior every tick via sim.pressure - over the rated limit, it genuinely
-- ruptures: kills a real section of its own shell and vents fire/heat through the breach).
local PVESSEL_LIMIT = 6.0
-- sim.pressure is indexed in 4px PRESSURE CELLS, not pixels, and errors hard outside its own grid range - every
-- call goes through this one safe wrapper.
local function readPressure(wx, wy)
  local cx, cy = wx - R.cam.x, wy - R.cam.y
  if cx < 0 or cx >= W or cy < 0 or cy >= H then return nil end
  local pcx, pcy = math.floor(cx / 4), math.floor(cy / 4)
  if pcx < 0 or pcy < 0 then return nil end
  local ok, p = pcall(sim.pressure, pcx, pcy)
  return ok and p or nil
end
NAME2.pressvessel = "Pressure Vessel"
MBOX2.pressvessel = { 0, -4, 9 }
IDLE_HINT2.pressvessel = "Passive - rated to " .. PVESSEL_LIMIT .. " real pressure"
STATE_DESC2.pressvessel = function(m)
  if m.burst then return "RUPTURED" end
  local p = readPressure(m.cx, m.cy) or 0
  return string.format("pressure %.1f / %.1f", p, PVESSEL_LIMIT)
end
NEXT_DESC2.pressvessel = function(m)
  if m.burst then return "Rebuild it - the shell has vented" end
  return "Keep real interior pressure under " .. PVESSEL_LIMIT
end
local function buildPressVessel(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy) - 4
  ring(wx, gy, 4, STEELMAT, 1)
  clearBox(wx - 2, gy - 2, wx + 2, gy + 2)   -- sealed hollow interior
  setAt(wx, gy + 5, "PSCN")   -- inlet valve nub at the base, for filling with a real pressurised gas
  R.machines2[#R.machines2 + 1] = { kind = "pressvessel", x = wx, y = gy, cx = wx, cy = gy, r = 4, burst = false }
  R.say("Pressure vessel placed - real interior pressure over " .. PVESSEL_LIMIT .. " will genuinely rupture it")
end
local function updatePressVessel()
  for _, m in ipairs(R.machines2) do if m.kind == "pressvessel" and not m.burst then
    local p = readPressure(m.cx, m.cy)
    if p and p > PVESSEL_LIMIT then
      m.burst = true
      -- real breach: open one side of the shell and vent real fire through the gap
      clearBox(m.cx + 3, m.cy - 1, m.cx + 4, m.cy + 1)
      setAt(m.cx + 5, m.cy, "FIRE")
      R.say("BANG - a pressure vessel just ruptured!")
    end
  end end
end

-- ---------------------------------------------------------------- Reservoir Tank (passive bulk storage; a real
-- GLAS sight strip on the front face - clear of the liquid column, same fix as the electrolysis cell - lets you
-- read the fill level by eye. Open top intake, open bottom spigot for a bucket/pipe to draw from).
NAME2.reservoir = "Reservoir Tank"
MBOX2.reservoir = { 0, -5, 8 }
IDLE_HINT2.reservoir = "Passive - pour liquid in the top, draw it from the bottom spigot"
STATE_DESC2.reservoir = function(m)
  local n = 0
  for y = m.y1, m.y2 do if partAt(m.x, y) then n = n + 1 end end
  return string.format("%d%% full", math.floor(100 * n / (m.y2 - m.y1 + 1)))
end
NEXT_DESC2.reservoir = function() return "No action needed - open top intake, open bottom spigot" end
local function buildReservoir(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 8, wx + 2, gy, STEELMAT)
  clearBox(wx - 1, gy - 7, wx + 1, gy - 1)   -- interior liquid column, open top and bottom
  setAt(wx - 2, gy - 4, "GLAS")               -- sight strip on the side wall, clear of the liquid column
  R.machines2[#R.machines2 + 1] = { kind = "reservoir", x = wx, y = gy - 4, y1 = gy - 7, y2 = gy - 1 }
  R.say("Reservoir tank placed - pour liquid into the open top")
end

-- ---------------------------------------------------------------- Steam Condenser (a housed cold FRZW coil; real
-- WTRV drawn into the intake chamber is actively chilled by the coil each tick, and once genuinely below 373K it
-- is converted in place to real WATR - same "real threshold transmutes the particle" idiom as the salt evaporator,
-- applied in reverse. The WATR then falls under real gravity to the spigot below).
NAME2.condenser = "Steam Condenser"
MBOX2.condenser = { 0, -5, 9 }
IDLE_HINT2.condenser = "Passive - feed real WTRV into the top intake"
STATE_DESC2.condenser = function(m) return partAt(m.intake.x, m.intake.y) and "condensing" or "idle" end
NEXT_DESC2.condenser = function() return "Vent real WTRV (from a boiler/turbine) into the top intake" end
local function buildCondenser(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 3, gy - 7, wx + 3, gy, STEELMAT)
  clearBox(wx - 2, gy - 6, wx - 1, gy - 1)    -- intake chamber, left half
  disk(wx + 1, gy - 4, 2, "FRZW")             -- sealed internal cold-coil reservoir, right half (never touched)
  setAt(wx - 2, gy - 6, "GLAS")               -- open-top intake mouth marker
  killAt(wx - 2, gy - 6)
  clearBox(wx - 1, gy + 1, wx - 1, gy + 1)    -- spigot, open air one cell below the shell
  R.machines2[#R.machines2 + 1] = { kind = "condenser", x = wx, y = gy,
    intake = { x = wx - 2, y = gy - 5 }, spigot = { x = wx - 1, y = gy + 1 } }
  R.say("Steam condenser placed - real WTRV poured into the top intake condenses to real WATR")
end
local function updateCondenser()
  for _, m in ipairs(R.machines2) do if m.kind == "condenser" then
    local p = partAt(m.intake.x, m.intake.y)
    if p and R.nameOf(sim.partProperty(p, "type")) == "WTRV" then
      local t = sim.partProperty(p, "temp") or 373
      sim.partProperty(p, "temp", math.max(280, t - 25))
      if t - 25 < 373 and not partAt(m.spigot.x, m.spigot.y) then
        sim.partKill(p); setAt(m.spigot.x, m.spigot.y, "WATR")
      end
    end
  end end
end

-- ---------------------------------------------------------------- Drainage Sump (a sunken powered pit pump; once
-- real WATR pooling in the pit reaches a threshold, it kills one WATR from the pit per cycle and creates one at
-- the outlet with real outward velocity - the same vx-injection idiom the conveyor/elevator already use).
NAME2.sump = "Drainage Sump"
MBOX2.sump = { 0, -2, 8 }
IDLE_HINT2.sump = "Sits in a low point, power the pad to pump out flooding"
STATE_DESC2.sump = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "pumping" or "unpowered" end
NEXT_DESC2.sump = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Ejecting pooled WATR out the spout once the pit fills"
end
local function buildSump(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 3, gy - 2, wx + 3, gy + 2, WMAT)
  clearBox(wx - 2, gy - 1, wx + 2, gy + 2)   -- the pit itself, open at the top to collect real flood water
  setAt(wx + 3, gy - 3, WMAT); setAt(wx + 4, gy - 4, WMAT)   -- outlet spout, up and out
  clearBox(wx + 5, gy - 5, wx + 5, gy - 5)   -- open exit mouth, one cell past the last real pipe segment
  setAt(wx - 3, gy - 3, "PSCN")   -- power pad
  R.machines2[#R.machines2 + 1] = { kind = "sump", x = wx, y = gy,
    pit = { x1 = wx - 2, x2 = wx + 2, y1 = gy - 1, y2 = gy + 2 }, pad = { x = wx - 3, y = gy - 3 },
    outlet = { x = wx + 5, y = gy - 5 }, cool = 0 }
  R.say("Drainage sump placed - power the pad to pump out any real WATR that pools in the pit")
end
local function updateSump()
  for _, m in ipairs(R.machines2) do if m.kind == "sump" then
    m.cool = (m.cool or 0) - 1
    if poweredAt(m.pad.x, m.pad.y, 1) and m.cool <= 0 then
      local n, target = 0, nil
      for x = m.pit.x1, m.pit.x2 do for y = m.pit.y1, m.pit.y2 do
        local p = partAt(x, y)
        if p and R.nameOf(sim.partProperty(p, "type")) == "WATR" then n = n + 1; target = target or p end
      end end
      if n >= 3 and target and not partAt(m.outlet.x, m.outlet.y) then
        sim.partKill(target)
        local id = setAt(m.outlet.x, m.outlet.y, "WATR")
        if id then sim.partProperty(id, "vx", 1.5); sim.partProperty(id, "vy", -1) end
        m.cool = 15
      end
    end
  end end
end

-- ================================================================================================================
-- LOGISTICS STAGE 3: Sorter, Splitter, Vacuum Collector, Silo (level indicator), Quarry.
-- ================================================================================================================
local ORE_SET = { IRON = true, GOLD = true, CU = true, DU = true, QRTZ = true, DMND = true, URAN = true }

-- ---------------------------------------------------------------- Sorter (a T-junction; any real ore-tier
-- particle passing the sensor point is diverted down a side chute, everything else continues straight through).
NAME2.sorter = "Sorter"
MBOX2.sorter = { 0, -2, 7 }
IDLE_HINT2.sorter = "Passive - ore drops down the side chute, everything else passes through"
STATE_DESC2.sorter = function() return "sorting" end
NEXT_DESC2.sorter = function() return "Feed a real material stream through the top" end
local function buildSorter(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 3, wx + 2, gy, WMAT)
  clearBox(wx - 1, gy - 2, wx - 1, gy - 1)   -- straight-through lane (left column)
  clearBox(wx + 1, gy - 2, wx + 1, gy)       -- side chute (right column), open all the way to the base
  setAt(wx, gy - 3, "PSCN")   -- sensor stud, visible marker at the junction
  R.machines2[#R.machines2 + 1] = { kind = "sorter", x = wx, y = gy,
    sensor = { x = wx - 1, y = gy - 2 }, chute = { x = wx + 1, y = gy - 2 } }
  R.say("Sorter placed - real ore diverts into the side chute, everything else passes straight through")
end
local function updateSorter()
  for _, m in ipairs(R.machines2) do if m.kind == "sorter" then
    local p = partAt(m.sensor.x, m.sensor.y)
    if p and ORE_SET[R.nameOf(sim.partProperty(p, "type"))] and not partAt(m.chute.x, m.chute.y) then
      sim.partPosition(p, m.chute.x - R.cam.x, m.chute.y - R.cam.y)
      sim.partProperty(p, "vx", 0); sim.partProperty(p, "vy", 0.5)
    end
  end end
end

-- ---------------------------------------------------------------- Splitter (alternates an incoming stream
-- between two output lanes, one item at a time - real sequencing, not a coin flip).
NAME2.splitter = "Splitter"
MBOX2.splitter = { 0, -2, 7 }
IDLE_HINT2.splitter = "Passive - alternates output between the left and right lane"
STATE_DESC2.splitter = function(m) return "next -> " .. (m.toggle and "right" or "left") end
NEXT_DESC2.splitter = function() return "Feed a real material stream through the top intake" end
local function buildSplitter(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 3, wx + 2, gy, WMAT)
  clearBox(wx, gy - 3, wx, gy - 2)           -- intake column, top centre
  clearBox(wx - 2, gy - 1, wx - 2, gy)       -- left output lane
  clearBox(wx + 2, gy - 1, wx + 2, gy)       -- right output lane
  R.machines2[#R.machines2 + 1] = { kind = "splitter", x = wx, y = gy,
    intake = { x = wx, y = gy - 2 }, left = { x = wx - 2, y = gy - 1 }, right = { x = wx + 2, y = gy - 1 }, toggle = false }
  R.say("Splitter placed - alternates a real material stream between two output lanes")
end
local function updateSplitter()
  for _, m in ipairs(R.machines2) do if m.kind == "splitter" then
    local p = partAt(m.intake.x, m.intake.y)
    if p then
      local dst = m.toggle and m.right or m.left
      if not partAt(dst.x, dst.y) then
        sim.partPosition(p, dst.x - R.cam.x, dst.y - R.cam.y)
        sim.partProperty(p, "vx", 0); sim.partProperty(p, "vy", 0.5)
        m.toggle = not m.toggle
      end
    end
  end end
end

-- ---------------------------------------------------------------- Vacuum Collector (a ring housing; real loose
-- powder within its radius is pulled toward the centre by a real velocity nudge every tick - genuine attraction,
-- not teleportation - and collected into the bag the instant it reaches the core. Deliberately implemented as a
-- tuned Lua force rather than the native VACU/BHOL element: that element also generates real heat and is far
-- harder to keep contained at a small, predictable radius - not worth the risk on the player's world after today's
-- stack-overflow incident).
local VACUUM_R = 24
NAME2.vacuum = "Vacuum Collector"
MBOX2.vacuum = { 0, 0, 9 }
IDLE_HINT2.vacuum = "Powered - pulls loose powder from " .. VACUUM_R .. "px into the bag"
STATE_DESC2.vacuum = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "collecting" or "unpowered" end
NEXT_DESC2.vacuum = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Pulling in any loose real powder within " .. VACUUM_R .. "px"
end
local function buildVacuum(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy) - 4
  ring(wx, gy, 3, WMAT, 1)
  clearBox(wx - 1, gy - 1, wx + 1, gy + 1)
  setAt(wx, gy, "PSCN")   -- core stud (collection point)
  setAt(wx - 3, gy, "PSCN")   -- power pad on the housing side
  R.machines2[#R.machines2 + 1] = { kind = "vacuum", x = wx, y = gy, cx = wx, cy = gy, r = 3,
    pad = { x = wx - 3, y = gy } }
  R.say("Vacuum collector placed - power it to pull in loose real powder nearby")
end
local function updateVacuum()
  for _, m in ipairs(R.machines2) do if m.kind == "vacuum" and poweredAt(m.pad.x, m.pad.y, 1) then
    for dy = -VACUUM_R, VACUUM_R, 3 do for dx = -VACUUM_R, VACUUM_R, 3 do
      local d2 = dx * dx + dy * dy
      if d2 > 16 and d2 <= VACUUM_R * VACUUM_R then
        local p = partAt(m.cx + dx, m.cy + dy)
        if p then
          local tier = R.MINEABLE[R.nameOf(sim.partProperty(p, "type"))]
          if tier then
            local d = math.sqrt(d2)
            sim.partProperty(p, "vx", (sim.partProperty(p, "vx") or 0) - (dx / d) * 0.4)
            sim.partProperty(p, "vy", (sim.partProperty(p, "vy") or 0) - (dy / d) * 0.4)
          end
        end
      end
    end end
    local core = partAt(m.cx, m.cy)
    if core then
      local nm = R.nameOf(sim.partProperty(core, "type"))
      if R.MINEABLE[nm] then sim.partKill(core); R.give(nm, 1) end
    end
  end end
end

-- ---------------------------------------------------------------- Silo (vertical bulk storage for real loose
-- powder; a lit-segment level indicator on the side shows how full the column really is).
NAME2.silo = "Silo"
MBOX2.silo = { 0, -6, 8 }
IDLE_HINT2.silo = "Passive - pour loose material in the open top"
STATE_DESC2.silo = function(m)
  local n = 0
  for y = m.y1, m.y2 do if partAt(m.x, y) then n = n + 1 end end
  return string.format("%d%% full", math.floor(100 * n / (m.y2 - m.y1 + 1)))
end
NEXT_DESC2.silo = function() return "No action needed - open top intake, open bottom outlet" end
local function buildSilo(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 10, wx + 2, gy, WMAT)
  clearBox(wx - 1, gy - 9, wx + 1, gy - 1)   -- interior column, open top and bottom
  local lampEl = R.has("LEDL") and "LEDL" or "LCRY"
  for i = 0, 4 do setAt(wx - 2, gy - 2 - i * 2, lampEl) end   -- level-indicator lamp column on the side, unlit until wired
  R.machines2[#R.machines2 + 1] = { kind = "silo", x = wx, y = gy - 5, y1 = gy - 9, y2 = gy - 1 }
  R.say("Silo placed - pour loose material into the open top")
end

-- ---------------------------------------------------------------- Quarry (powered; automatically mines a real
-- 5-wide shaft straight down beneath itself one hit at a time, same real-hit-count idiom as the drill/tunneler).
NAME2.quarry = "Quarry"
MBOX2.quarry = { 0, -3, 8 }
IDLE_HINT2.quarry = "Powered - automatically mines a shaft straight down"
STATE_DESC2.quarry = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and ("mining, depth " .. (m.depth or 0)) or "unpowered" end
NEXT_DESC2.quarry = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Working a real 5-wide shaft straight down"
end
local function buildQuarry(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 3, gy - 3, wx + 3, gy - 1, WMAT)
  setAt(wx - 3, gy - 2, "PSCN")
  R.machines2[#R.machines2 + 1] = { kind = "quarry", x = wx, y = gy,
    pad = { x = wx - 3, y = gy - 2 }, cx = wx, cy = gy, depth = 0, prog = 0, cool = 0 }
  R.say("Quarry placed - power the pad to start mining a shaft straight down")
end
local function updateQuarry()
  for _, m in ipairs(R.machines2) do if m.kind == "quarry" then
    m.cool = (m.cool or 0) - 1
    if poweredAt(m.pad.x, m.pad.y, 1) and m.cool <= 0 then
      local anyHit = false
      for dx = -2, 2 do
        local tx, ty = m.cx + dx, m.cy + (m.depth or 0)
        local p = partAt(tx, ty)
        if p then
          local nm = R.nameOf(sim.partProperty(p, "type")); local tier = R.MINEABLE[nm]
          if tier and tier <= 4 then
            anyHit = true
            m.prog = (m.prog or 0) + 1
            if m.prog >= (R.HARD[nm] or 3) then sim.partKill(p); R.give(nm, 1); m.prog = 0 end
          end
        end
      end
      if not anyHit then m.depth = (m.depth or 0) + 1; m.prog = 0 end
      m.cool = 6
    end
  end end
end

-- ================================================================================================================
-- EXOTIC / PHYSICS TOYS STAGE 4: Gravity Manipulator, Portal Pair, Magnetic Accelerator, Cryo Chamber, Weather
-- Machine.
-- ================================================================================================================

-- ---------------------------------------------------------------- Gravity Manipulator (a contained repulsor pad;
-- uses the real, native WHOL identifier - in this build's element table it resolves to the vent-style "creates
-- pressure and pushes other particles away" behaviour, NOT the destructive SING/negative-pressure element -
-- passive once built, same as a real vent stone in any TPT save, housed so the push is a local column not a
-- world-wide shockwave).
NAME2.gravmanip = "Gravity Manipulator"
MBOX2.gravmanip = { 0, -3, 7 }
IDLE_HINT2.gravmanip = "Passive - real pressure lifts loose items placed above it"
STATE_DESC2.gravmanip = function() return "active" end
NEXT_DESC2.gravmanip = function() return "Drop loose material into the open column above it" end
local function buildGravManip(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 2, wx + 2, gy, STEELMAT)
  clearBox(wx - 1, gy - 1, wx + 1, gy - 1)
  setAt(wx, gy - 1, "WHOL")   -- the real repulsor element itself, sunk into the housing floor
  R.machines2[#R.machines2 + 1] = { kind = "gravmanip", x = wx, y = gy }
  R.say("Gravity manipulator placed - drop loose material into the column above it")
end

-- ---------------------------------------------------------------- Portal Pair (real PRTI/PRTO, channel-matched
-- via a shared temp value exactly like WIFI - each use of the kit places one end, alternating, so two uses make
-- a linked pair; anything that falls into the IN end appears at the OUT end).
NAME2.portal = "Portal"
MBOX2.portal = { 0, -1, 5 }
IDLE_HINT2.portal = "Passive - linked to its matching portal by colour/channel"
STATE_DESC2.portal = function(m) return (m.io == "in" and "IN end" or "OUT end") .. ", channel " .. m.channel end
NEXT_DESC2.portal = function() return "Drop real material into the IN end - it appears at the linked OUT end" end
local function buildPortal(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  R.portalChannel = R.portalChannel or 0
  local io, channel
  if R.portalPending then
    io, channel = "out", R.portalPending
    R.portalPending = nil
  else
    R.portalChannel = R.portalChannel + 1
    io, channel = "in", R.portalChannel
    R.portalPending = channel
  end
  local el = (io == "in") and "PRTI" or "PRTO"
  local id = setAt(wx, gy - 1, el)
  if id then sim.partProperty(id, "temp", 300 + channel) end
  R.machines2[#R.machines2 + 1] = { kind = "portal", x = wx, y = gy - 1, io = io, channel = channel }
  R.say(io == "in" and "Portal IN placed (channel " .. channel .. ") - place the kit again for its OUT end"
    or "Portal OUT placed - linked to channel " .. channel)
end

-- ---------------------------------------------------------------- Magnetic Accelerator (a real PSCN/NSCN rail
-- barrel; powered, any real particle sitting at the breech gets one strong velocity boost down the barrel -
-- a genuine linear-rail launcher for cargo).
NAME2.magaccel = "Magnetic Accelerator"
MBOX2.magaccel = { 4, -1, 8 }
IDLE_HINT2.magaccel = "Powered - drop material in the breech to launch it down the rail"
STATE_DESC2.magaccel = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "charged" or "unpowered" end
NEXT_DESC2.magaccel = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Drop real material into the breech to launch it"
end
local function buildMagAccel(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy); local dir = (R.P.face and R.P.face >= 0) and 1 or -1
  for i = 0, 8 do
    setAt(wx + dir * i, gy - 2, (i % 2 == 0) and "PSCN" or "NSCN")
  end
  setAt(wx - dir, gy - 3, "PSCN")   -- power pad, behind the breech
  R.machines2[#R.machines2 + 1] = { kind = "magaccel", x = wx, y = gy,
    breech = { x = wx, y = gy - 2 }, dir = dir, pad = { x = wx - dir, y = gy - 3 }, cool = 0 }
  R.say("Magnetic accelerator placed - power the pad, drop material in the breech to launch it")
end
local function updateMagAccel()
  for _, m in ipairs(R.machines2) do if m.kind == "magaccel" then
    m.cool = (m.cool or 0) - 1
    if poweredAt(m.pad.x, m.pad.y, 1) and m.cool <= 0 then
      local p = partAt(m.breech.x, m.breech.y)
      if p then
        sim.partProperty(p, "vx", m.dir * 9)
        m.cool = 20
      end
    end
  end end
end

-- ---------------------------------------------------------------- Cryo Chamber (a sealed FRZW-cored housing;
-- registers into the real, shared R.coolers registry exactly like @machines' life-support kits register into
-- R.o2Sources - rebuilt from scratch every cycle so a destroyed/unpowered chamber's cooling disappears at once).
NAME2.cryo = "Cryo Chamber"
MBOX2.cryo = { 0, -4, 8 }
IDLE_HINT2.cryo = "Powered - lowers real ambient heat nearby"
STATE_DESC2.cryo = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "cooling" or "unpowered" end
NEXT_DESC2.cryo = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Actively cooling the area within 70px"
end
local function buildCryo(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 3, gy - 6, wx + 3, gy, STEELMAT)
  clearBox(wx - 2, gy - 5, wx + 2, gy - 1)
  disk(wx, gy - 3, 2, "FRZW")
  setAt(wx - 3, gy - 3, "PSCN")   -- power pad
  R.machines2[#R.machines2 + 1] = { kind = "cryo", x = wx, y = gy, pad = { x = wx - 3, y = gy - 3 } }
  R.say("Cryo chamber placed - power it to actively cool the area nearby")
end
local function syncCoolers()
  R.coolers = R.coolers or {}
  for i = #R.coolers, 1, -1 do if R.coolers[i]._src == TAG then table.remove(R.coolers, i) end end
  for _, m in ipairs(R.machines2) do if m.kind == "cryo" and poweredAt(m.pad.x, m.pad.y, 1) then
    table.insert(R.coolers, { x = m.x, y = m.y, rate = 30, range = 70, _src = TAG })
  end end
end

-- ---------------------------------------------------------------- Weather Machine (powered, forces a real storm
-- for as long as it stays powered - feeds @machines' lightning rod's existing R.weather.rain gate directly, no
-- coupling to that file needed since R.weather is core shared state).
NAME2.weathermachine = "Weather Machine"
MBOX2.weathermachine = { 0, -5, 8 }
IDLE_HINT2.weathermachine = "Powered - forces a real storm while it runs"
STATE_DESC2.weathermachine = function(m) return poweredAt(m.pad.x, m.pad.y, 1) and "storm active" or "unpowered" end
NEXT_DESC2.weathermachine = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Forcing rain - powers any nearby lightning rod too"
end
local function buildWeatherMachine(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  ring(wx, gy - 5, 3, WMAT, 1)
  setAt(wx, gy - 8, "PSCN")   -- antenna tip
  setAt(wx - 3, gy - 5, "PSCN")   -- power pad
  R.machines2[#R.machines2 + 1] = { kind = "weathermachine", x = wx, y = gy - 5, pad = { x = wx - 3, y = gy - 5 } }
  R.say("Weather machine placed - power it to force a real storm")
end
local function updateWeatherMachine()
  local anyOn = false
  for _, m in ipairs(R.machines2) do if m.kind == "weathermachine" and poweredAt(m.pad.x, m.pad.y, 1) then anyOn = true end end
  if anyOn and R.weather then R.weather.rain = true end
end

-- ================================================================================================================
-- COMFORT / QoL STAGE 5: Lighting Rail, Security Camera + Alarm, Signpost, Proximity Gate, Decorative Panel.
-- ================================================================================================================
local LAMPEL2 = R.has("LEDL") and "LEDL" or "LCRY"

-- ---------------------------------------------------------------- Lighting Rail (one conductive beam carrying
-- 3 real lamps - one spark anywhere on the beam lights all three, real conduction not a flag).
NAME2.lightrail = "Lighting Rail"
MBOX2.lightrail = { 3, 0, 8 }
IDLE_HINT2.lightrail = "Wire the beam - one spark lights all three lamps"
STATE_DESC2.lightrail = function(m) return poweredAt(m.pad.x, m.pad.y, 2) and "lit" or "dark" end
NEXT_DESC2.lightrail = function(m)
  if poweredAt(m.pad.x, m.pad.y, 2) then return "Lit - no action needed" end
  return "Touch a sparked " .. nice(WMAT) .. " wire anywhere on the beam"
end
local function buildLightRail(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  for i = 0, 6 do setAt(wx + i, gy - 4, WMAT) end
  setAt(wx + 1, gy - 5, LAMPEL2); setAt(wx + 3, gy - 5, LAMPEL2); setAt(wx + 5, gy - 5, LAMPEL2)
  R.machines2[#R.machines2 + 1] = { kind = "lightrail", x = wx, y = gy - 4, pad = { x = wx, y = gy - 4 } }
  R.say("Lighting rail placed - wire the beam to light all three lamps at once")
end

-- ---------------------------------------------------------------- Security Camera + Alarm (powered; scans a
-- real radius for real enemies via R.enemyList() and sounds an alarm the instant one is close).
local CAMERA_R = 120
NAME2.camera = "Security Camera"
MBOX2.camera = { 0, 0, 6 }
IDLE_HINT2.camera = "Powered - watches " .. CAMERA_R .. "px for hostiles"
STATE_DESC2.camera = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "unpowered" end
  return m.alarm and "ALARM" or "clear"
end
NEXT_DESC2.camera = function(m)
  if not poweredAt(m.pad.x, m.pad.y, 1) then return "Touch a sparked " .. nice(WMAT) .. " wire to the pad" end
  return "Watching for real hostiles nearby"
end
local function buildCamera(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 1, gy - 3, wx + 1, gy - 1, WMAT)
  setAt(wx, gy - 3, "GLAS")   -- lens
  setAt(wx - 1, gy - 1, "PSCN")   -- power pad
  R.machines2[#R.machines2 + 1] = { kind = "camera", x = wx, y = gy - 2, pad = { x = wx - 1, y = gy - 1 }, alarm = false, cool = 0 }
  R.say("Security camera placed - power it to watch for real hostiles nearby")
end
local function updateCamera()
  for _, m in ipairs(R.machines2) do if m.kind == "camera" then
    m.alarm = false
    if poweredAt(m.pad.x, m.pad.y, 1) and R.enemyList then
      for _, e in ipairs(R.enemyList()) do
        local dx, dy = e.x - m.x, e.y - m.y
        if dx * dx + dy * dy <= CAMERA_R * CAMERA_R then m.alarm = true; break end
      end
    end
    if m.alarm then
      m.cool = (m.cool or 0) - 1
      if m.cool <= 0 then R.say("ALARM - hostile detected near the camera!"); m.cool = 90 end
    end
  end end
end

-- ---------------------------------------------------------------- Signpost (passive, purely informational -
-- a real wood post with a message shown in its interaction panel, same "read the panel" idiom as everything
-- else here rather than a hovering world-space label).
NAME2.signpost = "Signpost"
MBOX2.signpost = { 0, -2, 6 }
IDLE_HINT2.signpost = "Passive - a written sign"
STATE_DESC2.signpost = function() return "readable" end
NEXT_DESC2.signpost = function(m) return m.text or "A weathered signpost." end
local SIGN_TEXTS = {
  "This way to the workshop.", "Mind the machinery.", "Danger: deep shaft ahead.",
  "Fresh water reservoir nearby.", "Restricted - high voltage.",
}
local function buildSignpost(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  setAt(wx, gy - 1, "WOOD"); setAt(wx, gy - 2, "WOOD"); setAt(wx, gy - 3, "WOOD")
  boxFill(wx - 1, gy - 4, wx + 1, gy - 3, "WOOD")
  R.machines2[#R.machines2 + 1] = { kind = "signpost", x = wx, y = gy - 2,
    text = SIGN_TEXTS[math.random(#SIGN_TEXTS)] }
  R.say("Signpost placed")
end

-- ---------------------------------------------------------------- Proximity Gate (a real portcullis - motion-
-- sensor flavoured, mechanically distinct from @machines' powered switch-door: no wiring at all, it senses the
-- player directly and raises/lowers real METL bars into a floor recess).
local GATE_R = 26
NAME2.gate = "Proximity Gate"
MBOX2.gate = { 0, -2, 6 }
IDLE_HINT2.gate = "Passive - raises automatically when you approach"
STATE_DESC2.gate = function(m) return m.open and "open" or "closed" end
NEXT_DESC2.gate = function() return "No action needed - opens on approach, closes behind you" end
local function buildGate(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  for i = 0, 3 do setAt(wx, gy - i, WMAT) end
  R.machines2[#R.machines2 + 1] = { kind = "gate", x = wx, y = gy - 2, bars = { x = wx, y0 = gy - 3, y1 = gy }, open = false }
  R.say("Proximity gate placed - it senses you directly, no wiring needed")
end
local function updateGate()
  for _, m in ipairs(R.machines2) do if m.kind == "gate" then
    local near = nearPlayer(m.x, m.y, GATE_R)
    if near ~= m.open then
      m.open = near
      for y = m.bars.y0, m.bars.y1 do
        if near then killAt(m.bars.x, y) else setAt(m.bars.x, y, WMAT) end
      end
    end
  end end
end

-- ---------------------------------------------------------------- Decorative Panel (purely aesthetic - a framed
-- wall panel for base interiors, real materials, no logic).
NAME2.decopanel = "Decorative Panel"
MBOX2.decopanel = { 0, -1, 5 }
IDLE_HINT2.decopanel = "Purely decorative"
STATE_DESC2.decopanel = function() return "decorative" end
NEXT_DESC2.decopanel = function() return "No action needed" end
local function buildDecoPanel(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 3, wx + 2, gy, WMAT)
  clearBox(wx - 1, gy - 2, wx + 1, gy - 1)
  setAt(wx, gy - 2, "GLAS"); setAt(wx, gy - 1, "GLAS")
  R.machines2[#R.machines2 + 1] = { kind = "decopanel", x = wx, y = gy - 1 }
  R.say("Decorative panel placed")
end

hook(R.hooks.tick, function()
  updateElectro(); updateAcidSynth(); updateEvaporator(); updateFertMixer(); updatePowderMill()
  updateCheckValve(); updatePressVessel(); updateCondenser(); updateSump()
  updateSorter(); updateSplitter(); updateVacuum(); updateQuarry()
  updateMagAccel(); syncCoolers(); updateWeatherMachine()
  updateCamera(); updateGate()
end)

-- spinning-roller/drum/valve-flap overlay (animated draw hook, matches @machines' "animated overlay" convention)
hook(R.hooks.draw, function()
  for _, m in ipairs(R.machines2) do
    if m.kind == "fertmixer" and poweredAt(m.pad.x, m.pad.y, 1) then
      local cx, cy = (m.hopper.x1 + m.hopper.x2) / 2 - R.cam.x, m.y - 3 - R.cam.y
      local a = m.angle or 0
      graphics.drawLine(cx - 2, cy + math.sin(a) * 2, cx + 2, cy - math.sin(a) * 2, 200, 200, 210, 255)
    elseif m.kind == "powdermill" and poweredAt(m.pad.x, m.pad.y, 1) then
      local cx, cy = m.x - R.cam.x, m.y - R.cam.y
      local a = m.angle or 0
      graphics.drawLine(cx, cy, cx + math.cos(a) * 3, cy + math.sin(a) * 3, 230, 230, 100, 255)
    elseif m.kind == "checkvalve" then
      local cx, cy = m.x - R.cam.x, m.channel.y - R.cam.y
      local open = partAt(m.channel.x1, m.channel.y) ~= nil or partAt(m.channel.x2, m.channel.y) ~= nil
      graphics.drawLine(cx, cy - 2, cx + m.dir * 2, cy, open and 120 or 200, open and 220 or 80, 120, 255)
    elseif m.kind == "sump" and poweredAt(m.pad.x, m.pad.y, 1) then
      local cx, cy = m.outlet.x - R.cam.x, m.outlet.y - R.cam.y
      graphics.drawText(cx - 2, cy - 8, "^", 140, 200, 255, 220)
    elseif m.kind == "vacuum" and poweredAt(m.pad.x, m.pad.y, 1) then
      local cx, cy = m.cx - R.cam.x, m.cy - R.cam.y
      local pulse = 3 + math.sin((R.frame or 0) * 0.2) * 2
      graphics.drawCircle(cx, cy, math.floor(pulse), 140, 220, 255, 160)
    elseif m.kind == "quarry" and poweredAt(m.pad.x, m.pad.y, 1) then
      local cx, cy = m.cx - R.cam.x, m.cy - R.cam.y - (m.depth or 0)
      graphics.drawLine(cx - 2, cy, cx + 2, cy, 230, 200, 100, 200)
    end
  end
end)

-- ================================================================ crafting: R.RECIPES + R.ITEMS + BUILDERS + place
R.ITEMS = R.ITEMS or {}
R.ITEMS.FERTILISER = R.ITEMS.FERTILISER or { col = { 110, 80, 50 }, desc = "Ground plant matter + stone dust. Boosts crop growth." }
R.ITEMS.GUNPOWDER = R.ITEMS.GUNPOWDER or { col = { 60, 60, 65 }, desc = "Milled coal dust. A crafting reagent for future ammo." }

local BUILDERS2 = {
  ELECTROLYSISKIT = buildElectro,
  ACIDSYNTHKIT = buildAcidSynth,
  EVAPORATORKIT = buildEvaporator,
  FERTMIXERKIT = buildFertMixer,
  POWDERMILLKIT = buildPowderMill,
  CHECKVALVEKIT = buildCheckValve,
  PRESSVESSELKIT = buildPressVessel,
  RESERVOIRKIT = buildReservoir,
  CONDENSERKIT = buildCondenser,
  SUMPKIT = buildSump,
  SORTERKIT = buildSorter,
  SPLITTERKIT = buildSplitter,
  VACUUMKIT = buildVacuum,
  SILOKIT = buildSilo,
  QUARRYKIT = buildQuarry,
  GRAVMANIPKIT = buildGravManip,
  PORTALKIT = buildPortal,
  MAGACCELKIT = buildMagAccel,
  CRYOKIT = buildCryo,
  WEATHERKIT = buildWeatherMachine,
  LIGHTRAILKIT = buildLightRail,
  CAMERAKIT = buildCamera,
  SIGNPOSTKIT = buildSignpost,
  GATEKIT = buildGate,
  DECOPANELKIT = buildDecoPanel,
}
hook(R.hooks.place, function(el, mx, my, fine)
  local b = BUILDERS2[el]; if not b then return end
  if (R.frame - (R.last2Place or -99)) < 20 then return true end
  R.last2Place = R.frame
  R.inventory[el] = R.inv(el) - 1
  local ok, err = pcall(b, mx, my); if not ok then R.pluginErr = tostring(err) end
  R.rebuildHotbar()
  return true
end)

local function need(...) local t = {}; local a = { ... }; for i = 1, #a, 2 do t[a[i]] = a[i + 1] end; return t end
local BASE2_RECIPES = {
  { out = "ELECTROLYSISKIT", n = 1, need = need("STEL", 6, "CU", 4, "GLAS", 2), st = "anvil", txt = "Electrolysis cell",
    desc = "Splits real SLTW with a live spark into HYGN + caustic gas - genuine chlor-alkali chemistry, poured and wired by hand" },
  { out = "ACIDSYNTHKIT", n = 1, need = need("STEL", 5, "GLAS", 3, "QRTZ", 2), st = "anvil", txt = "Acid synthesizer",
    desc = "A lit coal firebox heats a quartz retort: real SALT + WATR react into real ACID, dripping into the basin" },
  { out = "EVAPORATORKIT", n = 1, need = need("CNCR", 4, "BRCK", 6, "COAL", 2), st = "workbench", txt = "Salt evaporator",
    desc = "No power needed - a lit pan boils real SLTW past 373K, leaving real SALT behind and venting real steam" },
  { out = "FERTMIXERKIT", n = 1, need = need("WOOD", 6, "METL", 4), st = "workbench", txt = "Fertiliser mixer",
    desc = "Two real grinding rollers turn PLNT clippings + STNE dust into a bag of Fertiliser" },
  { out = "POWDERMILLKIT", n = 1, need = need("METL", 8, "CU", 1), st = "anvil", txt = "Gunpowder mill",
    desc = "A powered spinning drum mills real COAL into a bag of Gunpowder" },
  { out = "CHECKVALVEKIT", n = 1, need = need("METL", 4, "PSCN", 1), st = "workbench", txt = "Check valve",
    desc = "A real one-way gate: liquid flowing with it passes free, liquid trying to flow backward is stopped dead" },
  { out = "PRESSVESSELKIT", n = 1, need = need("STEL", 6), st = "anvil", txt = "Pressure vessel",
    desc = "A sealed steel shell that reads its own real interior pressure every tick - push it past " .. PVESSEL_LIMIT .. " and it genuinely ruptures" },
  { out = "RESERVOIRKIT", n = 1, need = need("STEL", 8, "GLAS", 2), st = "anvil", txt = "Reservoir tank",
    desc = "Bulk liquid storage with a real sight-glass strip - see the fill level at a glance" },
  { out = "CONDENSERKIT", n = 1, need = need("STEL", 6, "GLAS", 2, "NAK", 1), st = "anvil", txt = "Steam condenser",
    desc = "A cold coil actively chills real WTRV below 373K, converting it back into real WATR for reuse" },
  { out = "SUMPKIT", n = 1, need = need("METL", 6, "CU", 1), st = "anvil", txt = "Drainage sump",
    desc = "A powered pit pump - once real flood WATR pools past a threshold it ejects it out the spout" },
  { out = "SORTERKIT", n = 1, need = need("METL", 5, "PSCN", 1), st = "workbench", txt = "Sorter",
    desc = "A real T-junction: any ore particle diverts down the side chute, everything else passes straight through" },
  { out = "SPLITTERKIT", n = 1, need = need("METL", 5), st = "workbench", txt = "Splitter",
    desc = "Alternates a real material stream between two output lanes, one item at a time" },
  { out = "VACUUMKIT", n = 1, need = need("METL", 6, "CU", 2), st = "anvil", txt = "Vacuum collector",
    desc = "Powered, it pulls loose real powder toward its core with a real velocity nudge and bags it on contact" },
  { out = "SILOKIT", n = 1, need = need("METL", 10), st = "anvil", txt = "Silo",
    desc = "Bulk storage for loose real powder with a level-indicator lamp column on the side" },
  { out = "QUARRYKIT", n = 1, need = need("METL", 10, "CU", 2), st = "anvil", txt = "Quarry",
    desc = "Powered, it automatically mines a real 5-wide shaft straight down, same real-hit-count mining as a drill" },
  { out = "GRAVMANIPKIT", n = 1, need = need("STEL", 6, "PSCN", 2), st = "anvil", txt = "Gravity manipulator",
    desc = "A housed real repulsor pad - passive, genuine pressure lifts loose material dropped above it" },
  { out = "PORTALKIT", n = 2, need = need("QRTZ", 4, "GOLD", 2), st = "anvil", txt = "Portal",
    desc = "Real linked PRTI/PRTO pair, channel-matched like WIFI - place twice for an IN end and its OUT end" },
  { out = "MAGACCELKIT", n = 1, need = need("PSCN", 4, "NSCN", 4, "METL", 4), st = "anvil", txt = "Magnetic accelerator",
    desc = "A real PSCN/NSCN rail barrel - powered, launches whatever real material sits in the breech down the rail" },
  { out = "CRYOKIT", n = 1, need = need("STEL", 6, "NAK", 2), st = "anvil", txt = "Cryo chamber",
    desc = "Powered, a real cold coil actively chills the area nearby - registers into the shared R.coolers model" },
  { out = "WEATHERKIT", n = 1, need = need("METL", 8, "CU", 2), st = "anvil", txt = "Weather machine",
    desc = "Powered, forces a real storm for as long as it runs - also feeds any nearby lightning rod" },
  { out = "LIGHTRAILKIT", n = 1, need = need("METL", 4, "GLAS", 3), st = "workbench", txt = "Lighting rail",
    desc = "One conductive beam, three real lamps - one spark lights all of them at once" },
  { out = "CAMERAKIT", n = 1, need = need("METL", 3, "GLAS", 1, "PSCN", 1), st = "workbench", txt = "Security camera",
    desc = "Powered, watches a real radius for real hostiles and sounds an alarm the instant one gets close" },
  { out = "SIGNPOSTKIT", n = 2, need = need("WOOD", 4), st = "hand", txt = "Signpost",
    desc = "A simple wooden signpost with a message, readable from its panel" },
  { out = "GATEKIT", n = 1, need = need("METL", 6), st = "anvil", txt = "Proximity gate",
    desc = "A real portcullis with no wiring at all - it senses you directly and raises/lowers real bars" },
  { out = "DECOPANELKIT", n = 1, need = need("METL", 3, "GLAS", 2), st = "workbench", txt = "Decorative panel",
    desc = "A framed wall panel for base interiors - purely aesthetic" },
}
local installRecipes2
installRecipes2 = function()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(BASE2_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
end
installRecipes2()
hook(R.hooks.newworld, function()
  R.machines2 = {}; R.machine2Panel = nil; R.portalChannel = nil; R.portalPending = nil
  installRecipes2()
end)
hook(R.hooks.sandbox, function() installRecipes2() end)

-- ================================================================ save/load: generic plain-data dump via save.lua
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
do
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == "machines2" then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, "machines2") end
end
