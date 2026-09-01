-- automation.lua - Automation / electronics plugin for the Powder RPG (2026-09-0X, @automation).
-- PhoenixFire808, verbatim brief: "create a real pathway that they would actually be acquired, and
-- then incorporate those mechanics and create those mechanics in the game." Stock TPT ships a
-- complete logic/sensor toolkit (LSNS/TSNS/PSNS/VSNS, SWCH/DTEC/LDTC/DLAY/ARAY/CRAY, WIFI,
-- PSCN/NSCN/SPRK, METL/INWR conductors) that this RPG had never used as a mechanic. Design
-- reference: knowledge/design-material-progression.md S4 chain 1/9. Built AFTER checking the
-- live source: @matimpl (rpg.lua, this wave's only lane allowed to touch it) had ALREADY landed
-- most of the acquisition pathway (SLCN/SWCH/INWR/TESC/ETRD/DSTW/PSTN/FRME/ACEL/DCEL/FRAY/RPEL/
-- PPIP/SHLD-SHD3/DTEC/LDTC/PSNS/TSNS/VOID/PVOD/VENT, all real R.RECIPES entries, verified by
-- reading rpg.lua directly this pass) from the same design doc before this plugin was written --
-- so this file's job is NOT to re-invent those recipes. It (1) closes the remaining acquisition
-- gaps the brief explicitly names that rpg.lua did not yet cover (LSNS, VSNS, DLAY, ARAY, CRAY --
-- DRAY is deliberately NOT added, see the design doc's own EXCLUDE reasoning: a craftable
-- duplicator ray is an economy-breaking risk, same class as CLNE/BTRY), (2) ships a generic
-- sensor-calibration TOOL (every TSNS/PSNS/LSNS/VSNS/DLAY threshold is that particle's own .temp
-- property per the real engine source -- verified by reading TSNS.cpp/PSNS.cpp/LSNS.cpp/VSNS.cpp/
-- DLAY.cpp directly, D:/The-Powder-Toy/src/simulation/elements/ -- so "calibrate the sensor" means
-- literally setting that one real property, nothing simulated on top), and (3) ships three
-- self-contained, single-purpose "day one" builds (Thermal Alarm / Pressure Switch / Sensor Vault
-- Door) that are 100% driven by real engine spark/pressure/detection physics -- this file only
-- watches for the resulting SPRK the way machines2.lua's poweredAt() already does, never
-- reimplements the sensing itself.
--
-- Owns: R.hooks.tick/drawHUD/mousedown/wheel/place entries tagged "automation", R.automation,
-- R.auto (the public cross-plugin hook contract, see below), R.ITEMS.<THERMALARMKIT,
-- PRESSURESWITCHKIT, SENSORVAULTKIT>, R.RECIPES entries tagged _plugin="automation". Does not
-- touch rpg.lua, machines.lua or machines2.lua.
--
-- VERIFIED INTEGRATION GAP, worth landing separately (not applied by this lane -- machines.lua is
-- not this lane's file this wave, per AGENTS.md): machines.lua:105's power-grid flood-fill walks
-- ONLY pixels whose type is in its own `CONDUCTOR = {CU,METL,PSCN,NSCN,STEL,TRBN,TEG}` allowlist
-- (verified by reading machines.lua:105/138-139/337-338 directly). SWCH is real TYPE_SOLID and
-- genuinely conducts a live spark when on (SWCH.cpp, engine-verified), but it is NOT in that
-- allowlist -- so a SWCH built into a wire run, even while switched ON, is treated as a hard break
-- by R.power.grids' wattage bookkeeping specifically (real per-particle spark propagation is
-- unaffected -- this is a Lua-side classification gap, not an engine bug). EXACT FIX for whoever
-- next owns machines.lua: add `SWCH = true` to the CONDUCTOR table at machines.lua:105. One line,
-- physically correct (SWCH really is TYPE_SOLID + conducts-when-on), lets any @machines/@machines2
-- "load" kit be gated behind a player-built sensor+switch (this plugin's PRESSURESWITCHKIT, or any
-- hand-wired SWCH) without machines.lua needing to know this plugin exists at all. Until that
-- lands, R.auto.sparkNear() below is the working alternative -- a direct point-check against real
-- spark presence, unaffected by the CONDUCTOR allowlist gap because it never joins that flood-fill.

local R = PBX.state.rpg
local TAG = "automation"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local W, H = R.W, R.H
local eid, nameOf, has, say, nice = R.eid, R.nameOf, R.has, R.say, R.nice

R.automation = R.automation or {}   -- placed "kind" builds: {kind, x, y, ...kind-specific fields}, world coords

-- ================================================================ low-level build helpers (same
-- erase-then-place convention as machines2.lua -- see build-lessons "placeElement on an occupied
-- pixel is a no-op")
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function setAt(wx, wy, elName)
  killAt(wx, wy); local t = eid(elName); if not t then return nil end
  return sim.partCreate(-1, wx - R.cam.x, wy - R.cam.y, t)
end
local function boxFill(x1, y1, x2, y2, elName) for y = y1, y2 do for x = x1, x2 do setAt(x, y, elName) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if R.solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
local function partAt(wx, wy) return sim.partID(wx - R.cam.x, wy - R.cam.y) end
local function typeAt(wx, wy) local p = partAt(wx, wy); return p and nameOf(sim.partProperty(p, "type")) or nil end
local function nearPlayer(x, y, r) local dx, dy = x - R.P.x, y - R.P.y; return dx * dx + dy * dy <= (r or 140) * (r or 140) end

-- ================================================================ public cross-plugin contract
-- (the "hooks other lanes can add" the brief asked for -- read-only point checks, never a full
-- per-frame wire scan; O(1) per call, same cost class as machines2.lua's own internal poweredAt())
R.auto = R.auto or {}
-- R.auto.sparkNear(wx, wy, r): true if a real SPRK particle sits at/adjacent to this world coord
-- THIS frame. Any machine's own update() can gate its action behind this with zero coupling to
-- this file (identical convention to machines2.lua's private poweredAt, now exposed for reuse).
function R.auto.sparkNear(wx, wy, r)
  r = r or 1
  for dy = -r, r do for dx = -r, r do
    if typeAt(wx + dx, wy + dy) == "SPRK" then return true end
  end end
  return false
end
-- R.auto.CALIB_TEMP: element codes whose automation threshold is their own .temp property (read
-- with sim.partProperty(id,"temp")) -- informational, for any lane that wants to build its own
-- calibration UI consistent with this plugin's tool instead of re-deriving the element list.
R.auto.CALIB_TEMP = { TSNS = true, PSNS = true, LSNS = true, VSNS = true, DLAY = true }
R.auto.CALIB_CTYPE = { DTEC = true, LDTC = true }

-- ================================================================ recipes: close the remaining
-- acquisition gaps (LSNS/VSNS/DLAY/ARAY/CRAY -- everything else the brief names was already live
-- in rpg.lua, verified by reading it before writing this file). Real stock elements (has()==true),
-- same station-tier convention @matimpl already established for the rest of this chain.
for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
local AUTO_RECIPES = {
  { out = "LSNS", n = 1, need = { SLCN = 1, METL = 2 }, st = "research", txt = "Life sensor",
    desc = "Sparks when a nearby particle's own life-counter exceeds its calibrated threshold -- reacts to freshly reacting or freshly created matter within range. Calibrate with the automation tool" },
  { out = "VSNS", n = 1, need = { SLCN = 1, CU = 2 }, st = "research", txt = "Velocity sensor",
    desc = "Sparks when a nearby particle's real velocity exceeds its calibrated threshold -- a genuine motion trip-wire, not a timer" },
  { out = "DLAY", n = 1, need = { SLCN = 1, METL = 2 }, st = "research", txt = "Delay conductor",
    desc = "Holds a spark and re-emits it after a delay set by its own temperature in Celsius -- sequence a multi-step automation chain instead of firing everything at once" },
  { out = "ARAY", n = 1, need = { QRTZ = 2, CU = 2 }, st = "advlab", txt = "Ray emitter",
    desc = "Fires a ray that marks a collision point when it strikes something -- an advanced tripwire routed through open air, not just along a wire" },
  { out = "CRAY", n = 1, need = { QRTZ = 3, CU = 2, GOLD = 1 }, st = "advlab", txt = "Particle ray emitter",
    desc = "Fires a real, ctype-configurable particle beam with a tunable range -- the most advanced trigger in the automation toolkit" },
}
for _, rc in ipairs(AUTO_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end

-- ================================================================================================
-- KIT 1: Thermal Alarm (workbench). TSNS mounted over a lamp; TSNS's own real .temp property is
-- the trigger threshold (default 373.15K/100C, a "boiling point" reference the player can
-- recalibrate). Native engine physics decides when it fires; this file only watches the lamp pad
-- for the resulting spark and sounds a cooldown-throttled alarm, same pattern as machines2.lua's
-- camera alarm.
-- ================================================================================================
local ALARM_COOLDOWN = 90
local function buildThermAlarm(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 1, gy - 4, wx + 1, gy - 1, "METL")
  local sid = setAt(wx, gy - 7, "TSNS")
  if sid then sim.partProperty(sid, "temp", 373.15) end
  setAt(wx, gy - 6, "CU")
  setAt(wx, gy - 5, "LEDL")
  R.automation[#R.automation + 1] = { kind = "thermalarm", x = wx, y = gy - 3,
    sensor = { x = wx, y = gy - 7 }, lamp = { x = wx, y = gy - 5 }, cool = 0 }
  say("Thermal Alarm placed - default trigger 100C. Right-click the sensor (top) to calibrate")
end
local function updateThermAlarm()
  for _, m in ipairs(R.automation) do if m.kind == "thermalarm" then
    if R.auto.sparkNear(m.lamp.x, m.lamp.y, 1) then
      m.cool = (m.cool or 0) - 1
      if m.cool <= 0 then
        say("ALARM: temperature threshold exceeded at the Thermal Alarm")
        if R.tlog then R.tlog("info", "automation", "thermalarm triggered", { x = m.x, y = m.y }) end
        m.cool = ALARM_COOLDOWN
      end
    end
  end end
end

-- ================================================================================================
-- KIT 2: Pressure Switch (workbench). PSNS's own real .temp property (Celsius) is compared against
-- the REAL ambient pressure grid (sim.pv) by the engine every tick -- verified in PSNS.cpp: fires
-- when local pressure exceeds that threshold. Its spark lands on a PSCN pad (native: a conductor's
-- own type becomes the resulting spark's ctype), which is what SWCH's own documented behaviour
-- ("PSCN switches on, NSCN switches off") reads to latch on. The output pad is a plain CU stud the
-- player wires downstream -- this IS the real automation signal: "automate the boiler->steam-
-- >turbine chain with a temperature/pressure sensor and a switch," exactly as the brief describes,
-- built from nothing but real elements and real physics.
-- ================================================================================================
local function buildPressureSwitch(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 1, gy - 4, wx + 1, gy - 1, "METL")
  local sid = setAt(wx, gy - 7, "PSNS")
  if sid then sim.partProperty(sid, "temp", 273.15) end   -- default: trips on any real pressure above 0
  setAt(wx, gy - 6, "PSCN")
  setAt(wx, gy - 5, "SWCH")
  setAt(wx + 1, gy - 5, "NSCN")   -- reset pad: touch a spark here (torch, or a second sensor) to switch back off
  setAt(wx - 1, gy - 5, "CU")     -- output pad: wire your machine here, only live while the switch is ON
  R.automation[#R.automation + 1] = { kind = "pressureswitch", x = wx, y = gy - 3,
    sensor = { x = wx, y = gy - 7 }, out = { x = wx - 1, y = gy - 5 }, reset = { x = wx + 1, y = gy - 5 } }
  say("Pressure Switch placed - default trigger just above 0 pressure. LATCHES on; spark the NSCN reset pad to turn it back off. Right-click the sensor to calibrate")
end

-- ================================================================================================
-- KIT 3: Sensor Vault Door (workbench). DTEC's own real .ctype property ("creates a spark when
-- something with its ctype is nearby," DTEC.cpp) is calibrated to a chosen material (default GOLD)
-- with the same calibration tool. This file watches the resulting spark at the door's control pad
-- and vanishes/reappears a real METL slab, the same illusion @machines' own DOORKIT already uses --
-- independent implementation, no shared state -- but driven by a real material-presence sensor
-- instead of a manual spark, so the door opens by itself only while the calibrated material is
-- actually nearby.
-- ================================================================================================
local function buildSensorVault(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  local sid = setAt(wx, gy - 7, "DTEC")
  if sid then sim.partProperty(sid, "ctype", eid("GOLD") or 0) end
  setAt(wx, gy - 6, "CU")
  setAt(wx, gy - 5, "CU")
  boxFill(wx - 1, gy - 4, wx + 1, gy - 1, "METL")
  for y = gy - 4, gy - 1 do setAt(wx + 3, y, "METL") end
  R.automation[#R.automation + 1] = { kind = "sensorvault", x = wx, y = gy - 3,
    sensor = { x = wx, y = gy - 7 }, pad = { x = wx, y = gy - 5 },
    slab = { x = wx + 3, y0 = gy - 4, y1 = gy - 1 }, open = false }
  say("Sensor Vault Door placed - opens near real Gold by default. Right-click the sensor to calibrate what it detects")
end
local function updateSensorVault()
  for _, m in ipairs(R.automation) do if m.kind == "sensorvault" then
    local open = R.auto.sparkNear(m.pad.x, m.pad.y, 1)
    if open ~= m.open then
      m.open = open
      for y = m.slab.y0, m.slab.y1 do
        if open then killAt(m.slab.x, y) else setAt(m.slab.x, y, "METL") end
      end
    end
  end end
end

hook(R.hooks.tick, function()
  updateThermAlarm()
  updateSensorVault()
end)

-- ================================================================ crafting: R.RECIPES + R.ITEMS + place
R.ITEMS = R.ITEMS or {}
local BUILDERS = {
  THERMALARMKIT = buildThermAlarm,
  PRESSURESWITCHKIT = buildPressureSwitch,
  SENSORVAULTKIT = buildSensorVault,
}
hook(R.hooks.place, function(el, mx, my, fine)
  local b = BUILDERS[el]; if not b then return end
  if (R.frame - (R.lastAutoPlace or -99)) < 20 then return true end
  R.lastAutoPlace = R.frame
  R.inventory[el] = R.inv(el) - 1
  local ok, err = pcall(b, mx, my); if not ok then R.pluginErr = tostring(err) end
  R.rebuildHotbar()
  return true
end)

local KIT_RECIPES = {
  { out = "THERMALARMKIT", n = 1, need = { METL = 4, TSNS = 1, CU = 1, LEDL = 1 }, st = "workbench", txt = "Thermal Alarm",
    desc = "A real TSNS mounted over a lamp -- sounds an alarm the instant something hotter than its calibrated threshold comes within range. Reads genuine cell temperature, not a fake timer" },
  { out = "PRESSURESWITCHKIT", n = 1, need = { METL = 4, PSNS = 1, PSCN = 1, NSCN = 1, CU = 1, SWCH = 1 }, st = "workbench", txt = "Pressure Switch",
    desc = "A real PSNS wired into a SWCH -- latches on the instant real pressure crosses its calibrated threshold. Wire the output pad into a boiler->turbine line and automate the whole chain" },
  { out = "SENSORVAULTKIT", n = 1, need = { METL = 8, DTEC = 1, CU = 2 }, st = "workbench", txt = "Sensor Vault Door",
    desc = "A real DTEC watching for a calibrated material -- the door slab opens on its own only while that real material is genuinely nearby, and seals again the instant it's gone" },
}
for _, rc in ipairs(KIT_RECIPES) do
  R.ITEMS[rc.out] = R.ITEMS[rc.out] or {
    col = (rc.st == "anvil") and { 150, 155, 165 } or (rc.st == "workbench") and { 150, 115, 70 } or { 190, 185, 175 },
    desc = rc.desc,
  }
end
local function installKitRecipes()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == (TAG .. "-kit") then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(KIT_RECIPES) do rc._plugin = TAG .. "-kit"; table.insert(R.RECIPES, rc) end
end
installKitRecipes()
hook(R.hooks.newworld, function()
  R.automation = {}; R.autoCalib = nil
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(AUTO_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
  installKitRecipes()
end)
hook(R.hooks.sandbox, function() installKitRecipes() end)

-- ================================================================================================
-- Sensor calibration tool: the payoff mechanic. Every TSNS/PSNS/LSNS/VSNS/DLAY's trigger threshold
-- IS its own real .temp property (verified against engine source, file header). Manually heating a
-- sensor to an exact Kelvin value by hand is not real gameplay -- this is the tool that makes the
-- payoff ("the physics is already simulated, turn it into gameplay") actually usable. Works on ANY
-- placed sensor in the world, not just this plugin's own kits -- a player who hand-wires their own
-- TSNS from raw materials gets the same calibration UI.
-- ================================================================================================
local REACH = 56
local CTYPE_CYCLE = { "GOLD", "CU", "IRON", "STEL", "COAL", "WOOD", "DMND", "QRTZ", "SAND", "WATR" }

hook(R.hooks.mousedown, function(x, y, button)
  if button ~= 3 or R.guideOpen then return end
  local wx, wy = x + R.cam.x, y + R.cam.y
  if R.autoCalib then R.autoCalib = nil; R.uiPanelOpen = false; return true end
  if not nearPlayer(wx, wy, REACH) then return end
  local p = partAt(wx, wy)
  if not p then return end
  local nm = nameOf(sim.partProperty(p, "type"))
  if R.auto.CALIB_TEMP[nm] or R.auto.CALIB_CTYPE[nm] then
    R.autoCalib = { wx = wx, wy = wy, name = nm }; R.uiPanelOpen = true; return true
  end
end)

hook(R.hooks.wheel, function(x, y, d)
  if not R.autoCalib then return end
  local c = R.autoCalib
  local p = partAt(c.wx, c.wy)
  if not p or nameOf(sim.partProperty(p, "type")) ~= c.name then R.autoCalib = nil; return true end
  if R.auto.CALIB_CTYPE[c.name] then
    local cur = sim.partProperty(p, "ctype")
    local idx = 1
    for i, mat in ipairs(CTYPE_CYCLE) do if eid(mat) == cur then idx = i; break end end
    idx = ((idx - 1 + (d > 0 and 1 or -1)) % #CTYPE_CYCLE) + 1
    sim.partProperty(p, "ctype", eid(CTYPE_CYCLE[idx]) or 0)
  else
    local t = sim.partProperty(p, "temp")
    sim.partProperty(p, "temp", math.max(1, t + (d > 0 and 5 or -5)))
  end
  return true
end)

hook(R.hooks.drawHUD, function()
  -- discoverability prompt: "[right-click] Calibrate" over any calibratable sensor near the player
  if not R.autoCalib then
    for _, m in ipairs(R.automation) do
      if m.sensor and nearPlayer(m.sensor.x, m.sensor.y, 70) then
        local sx, sy = m.sensor.x - R.cam.x, m.sensor.y - R.cam.y - 12
        if sx > -20 and sx < W + 20 and sy > -20 and sy < H then
          graphics.drawText(sx - 46, sy, "[right-click] Calibrate sensor", 255, 210, 120, 220)
        end
      end
    end
  end
  local c = R.autoCalib
  if c then
    local p = partAt(c.wx, c.wy)
    if not p then R.autoCalib = nil; return end
    local px, py, pw, ph = 190, 40, 236, 90
    graphics.fillRect(px, py, pw, ph, 10, 12, 18, 235)
    graphics.drawRect(px, py, pw, ph, 90, 95, 120, 255)
    graphics.drawText(px + 8, py + 6, "CALIBRATE " .. (nice(c.name) or c.name), 255, 210, 120, 255)
    graphics.drawText(px + pw - 90, py + 6, "[right-click] close", 150, 150, 160, 220)
    if R.auto.CALIB_CTYPE[c.name] then
      local cur = sim.partProperty(p, "ctype")
      graphics.drawText(px + 8, py + 28, "Detects: " .. (nameOf(cur) or "none"), 210, 220, 230, 255)
      graphics.drawText(px + 8, py + 48, "Scroll wheel to cycle material", 255, 230, 150, 255)
    else
      local t = sim.partProperty(p, "temp")
      graphics.drawText(px + 8, py + 28, string.format("Trigger threshold: %.0fK  (%.0fC)", t, t - 273.15), 210, 220, 230, 255)
      graphics.drawText(px + 8, py + 48, "Scroll wheel: +/-5K per notch", 255, 230, 150, 255)
    end
  end
end)

-- ================================================================ save/load: generic plain-data
-- dump via save.lua, same convention as machines2.lua's own final block
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
do
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == "automation" then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, "automation") end
end
