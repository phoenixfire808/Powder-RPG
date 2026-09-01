-- RPG plugin: terraweapons.lua - terrain-altering weapons. Second file in the weapons domain
-- (items.lua owns general combat gear; same precedent as machines.lua / machines2.lua).
--
-- Design law: every weapon is REAL particle physics, never a scripted effect. The magma lance
-- does not "make lava" - it heats terrain past that terrain's own real HighTemperature and TPT's
-- thermal sim melts it. The support cutter destroys nothing - it removes the load path and
-- R.crumble collapses the mass for real.
--
-- SPECTACLE (v1.15.93): the physics was correct but INVISIBLE - the player clicked and saw
-- almost nothing until material eventually melted. Every weapon now draws a real beam every
-- frame while held and emits real FIRE/PLSM/SMKE/WTRV/SPRK at the contact point. Those are
-- genuine particles that TPT's own fire/glow/blur render pipeline lights up, so the drama is
-- real physics too, not an overlay faked on top of it.
--
-- Catalogue of all 13 planned: knowledge/design-terraweapons-2026-08-31.md
local R = PBX.state.rpg
local TAG = "terraweapons"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local eid, nameOf, say, inv, give = R.eid, R.nameOf, R.say, R.inv, R.give
local floor, sqrt, random = math.floor, math.sqrt, math.random

R.twCD = R.twCD or {}
R.twCount = R.twCount or {}
R.twFx = R.twFx or {}   -- our own beam list: {x1,y1,x2,y2,col,w,frame}

-- ================================================================ definitions
local TW = {
  TUNNELBORE = { col = {210, 170, 90}, cd = 2, ammo = "METL", ammoEvery = 8, continuous = true,
                 fx = {210, 170, 90}, txt = "Tunnel Borer",
                 desc = "Bores a corridor tall enough to actually WALK through (14px) toward the cursor, throwing real rock dust and sparks off the cutting face. Ammo: Iron bar (drains while held)" },
  DEPOSITGUN = { col = {170, 150, 115}, cd = 3, ammo = "STNE", ammoEvery = 4, continuous = true,
                 fx = {180, 160, 120}, txt = "Deposition Gun",
                 desc = "Sprays real rock that then obeys real gravity - fills pits, raises ground, builds at range. Terrain-altering that ADDS instead of removing. Ammo: Stone (drains while held)" },
  MAGMALANCE = { col = {255, 120, 40}, cd = 2, ammo = "COAL", ammoEvery = 6, continuous = true,
                 fx = {255, 150, 40}, txt = "Magma Lance",
                 desc = "A roaring jet of heat that drives terrain past its OWN real melting point until it genuinely runs as lava - real fire and plasma boil off the impact point. Granite melts at granite's temperature, ice at ice's. Ammo: Coal (drains while held)" },
  CRYOFORM   = { col = {150, 220, 255}, cd = 2, ammo = "WATR", ammoEvery = 4, continuous = true,
                 fx = {170, 230, 255}, txt = "Cryo Former",
                 desc = "A freezing jet that flash-chills real water into real ice you can stand and build on, boiling steam off everything it touches. Ammo: Water (drains while held)" },
  SUPPORTCUT = { col = {230, 90, 60}, cd = 45, ammo = "METL", cost = 2,
                 fx = {255, 110, 70}, txt = "Support Cutter",
                 desc = "Cuts the support out from under a rock mass in a shower of sparks and lets it collapse under its own weight - real structural failure, not an explosion. Ammo: Iron bar (2/use)" },
  -- distance mining (the owner: "laser mining, and different sorts of cool distance mining tools")
  MININGLASER = { col = {255, 60, 60}, cd = 1, ammo = "QRTZ", ammoEvery = 10, continuous = true,
                 fx = {255, 70, 70}, txt = "Mining Laser",
                 desc = "Precision cutting beam. Bores one cell at a time from clear across the cavern and the ore drops straight into your bag - hard rock takes longer, exactly like a real pick. Ammo: Quartz (drains while held)" },
  EXCAVATOR  = { col = {255, 150, 60}, cd = 2, ammo = "QRTZ", ammoEvery = 4, continuous = true,
                 fx = {255, 170, 70}, txt = "Excavator Beam",
                 desc = "Wide-swath mining beam - carves a whole seam at range instead of one cell, at the cost of far heavier quartz drain. The bulk counterpart to the Mining Laser. Ammo: Quartz (drains fast while held)" },
}
local TW_ORDER = { "TUNNELBORE", "DEPOSITGUN", "MAGMALANCE", "CRYOFORM", "SUPPORTCUT", "MININGLASER", "EXCAVATOR" }
for _, k in ipairs(TW_ORDER) do R.ITEMS[k] = { col = TW[k].col, desc = TW[k].desc } end

-- ================================================================ helpers
local MUZZLE = 11
local function handAnchor()
  local face = R.P.face or 1
  return floor(R.P.x) - R.cam.x + (face > 0 and 3 or -4), floor(R.P.y) - R.cam.y - 8
end
local function aimAt(mx, my)
  local cx, cy = handAnchor()
  local dx, dy = mx - cx, my - cy
  local d = sqrt(dx * dx + dy * dy)
  if d < 1 then dx, dy, d = (R.P.face or 1), 0, 1 end
  return dx / d, dy / d, cx, cy, d
end
local function ready(name, w) return (R.frame - (R.twCD[name] or -9999)) >= w.cd end
local function fired(name) R.twCD[name] = R.frame end
local function ammoOk(w) return (not w.ammo) or inv(w.ammo) >= (w.cost or 1) end
local function ammoTick(name, w)
  if not w.ammo then return end
  R.twCount[name] = (R.twCount[name] or 0) + 1
  if R.twCount[name] % w.ammoEvery == 0 then R.inventory[w.ammo] = inv(w.ammo) - 1 end
end
local function spendAmmo(w) if w.ammo then R.inventory[w.ammo] = inv(w.ammo) - (w.cost or 1) end end

-- our own beam list so a beam can be re-emitted EVERY frame while the button is held, independent
-- of the weapon's fire cooldown - that gating is exactly why the old version looked like nothing
-- was happening (physics ran every 2-3 frames, so the beam blinked).
local function fx(x1, y1, x2, y2, col, wide)
  R.twFx[#R.twFx + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, col = col, w = wide or 1, frame = R.frame }
end
-- spawn a real particle if the cell is free. Real physics, and TPT renders these itself.
local function puff(nm, x, y, life, temp)
  local t = eid(nm); if not t then return end
  if sim.partID(x, y) then return end
  local id = sim.partCreate(-1, x, y, t)
  if id and id >= 0 then
    if life then pcall(sim.partProperty, id, "life", life) end
    if temp then pcall(sim.partProperty, id, "temp", temp) end
  end
end
-- trace to the first blocking particle; returns hit x,y,name,partID or the max-range point
local function trace(cx, cy, ux, uy, range)
  local lx, ly = floor(cx + ux * MUZZLE), floor(cy + uy * MUZZLE)
  for st = MUZZLE, range, 2 do
    local x, y = floor(cx + ux * st), floor(cy + uy * st)
    local p = sim.partID(x, y)
    if p then
      local nm = nameOf(sim.partProperty(p, "type"))
      if R.MINEABLE[nm] or R.HARD[nm] then return x, y, nm, p end
    end
    lx, ly = x, y
  end
  return lx, ly, nil, nil
end

-- ================================================================ 1. TUNNEL BORER
local BORE_H = 14
local function boreTunnel(mx, my)
  local w = TW.TUNNELBORE
  local ux, uy, cx, cy = aimAt(mx, my)
  local ex, ey = floor(cx + ux * (MUZZLE + 26)), floor(cy + uy * (MUZZLE + 26))
  fx(cx + ux * MUZZLE, cy + uy * MUZZLE, ex, ey, w.fx, 5)   -- wide cutting head, drawn every frame
  if not ready("TUNNELBORE", w) then return end
  if not ammoOk(w) then R.hint = "Tunnel Borer needs " .. R.nice("METL"); return end
  fired("TUNNELBORE"); ammoTick("TUNNELBORE", w)
  local px, py = -uy, ux
  local dug, half = 0, floor(BORE_H / 2)
  for step = MUZZLE, MUZZLE + 26, 2 do
    for off = -half, half do
      local sx, sy = floor(cx + ux * step + px * off), floor(cy + uy * step + py * off)
      local p = sim.partID(sx, sy)
      if p then
        local nm = nameOf(sim.partProperty(p, "type"))
        if R.MINEABLE[nm] then give(nm == "BCOL" and "COAL" or nm, 1) end
        sim.partKill(p); dug = dug + 1
      end
    end
  end
  -- real dust and sparks off the cutting face
  if dug > 0 then
    puff("SMKE", ex, ey - 1, 22)
    if R.frame % 3 == 0 then puff("SPRK", ex + (random() > 0.5 and 1 or -1), ey, 3) end
  end
  R.hint = dug > 0 and ("Boring - " .. BORE_H .. "px walkable passage") or "Tunnel Borer: nothing to cut"
end

-- ================================================================ 2. DEPOSITION GUN
local function depositRock(mx, my)
  local w = TW.DEPOSITGUN
  local ux, uy, cx, cy = aimAt(mx, my)
  local d = math.min(34, math.max(MUZZLE + 2, sqrt((mx - cx) ^ 2 + (my - cy) ^ 2)))
  local tx, ty = floor(cx + ux * d), floor(cy + uy * d)
  fx(cx + ux * MUZZLE, cy + uy * MUZZLE, tx, ty, w.fx, 3)
  if not ready("DEPOSITGUN", w) then return end
  if not ammoOk(w) then R.hint = "Deposition Gun needs " .. R.nice("STNE"); return end
  local t = eid("STNE"); if not t then R.hint = "Deposition Gun: no stone available"; return end
  fired("DEPOSITGUN"); ammoTick("DEPOSITGUN", w)
  local made = 0
  for dy = -1, 1 do for dx = -1, 1 do
    local sx, sy = tx + dx, ty + dy
    if not sim.partID(sx, sy) then
      local id = sim.partCreate(-1, sx, sy, t)
      if id and id >= 0 then made = made + 1 end
    end
  end end
  if made > 0 and R.frame % 4 == 0 then puff("SMKE", tx, ty - 2, 14) end
  R.hint = made > 0 and ("Depositing rock - " .. R.nice("STNE") .. " x" .. inv("STNE")) or "Deposition Gun: no room there"
end

-- ================================================================ 3. MAGMA LANCE
local function magmaLance(mx, my)
  local w = TW.MAGMALANCE
  local ux, uy, cx, cy = aimAt(mx, my)
  local hx, hy, hitNm = trace(cx, cy, ux, uy, MUZZLE + 22)
  fx(cx + ux * MUZZLE, cy + uy * MUZZLE, hx, hy, w.fx, 4)
  if not ready("MAGMALANCE", w) then return end
  if not ammoOk(w) then R.hint = "Magma Lance needs " .. R.nice("COAL"); return end
  fired("MAGMALANCE"); ammoTick("MAGMALANCE", w)
  local heated = 0
  for step = MUZZLE, MUZZLE + 22, 2 do
    local sx, sy = floor(cx + ux * step), floor(cy + uy * step)
    for dy = -1, 1 do for dx = -1, 1 do
      local p = sim.partID(sx + dx, sy + dy)
      if p then
        local pt = sim.partProperty(p, "type")
        local ok, ht = pcall(elem.property, pt, "HighTemperature")
        local target = (ok and ht and ht > 0 and ht < 9000) and (ht + 250) or 3000
        pcall(sim.partProperty, p, "temp", target)
        heated = heated + 1; hitNm = hitNm or nameOf(pt)
      end
    end end
  end
  -- real fire off the jet, real plasma at the contact point where it is hottest
  puff("FIRE", floor(cx + ux * (MUZZLE + 4)), floor(cy + uy * (MUZZLE + 4)), 30, 2200)
  if heated > 0 then
    if R.frame % 2 == 0 then puff("PLSM", hx, hy - 1, 14, 3500) end
    if R.frame % 5 == 0 then puff("SMKE", hx + 1, hy - 2, 26) end
  end
  R.hint = heated > 0 and ("Melting " .. R.nice(hitNm or "rock") .. " past its melting point") or "Magma Lance: aim at terrain"
end

-- ================================================================ 4. CRYO FORMER
local function cryoForm(mx, my)
  local w = TW.CRYOFORM
  local ux, uy, cx, cy = aimAt(mx, my)
  local ex, ey = floor(cx + ux * (MUZZLE + 20)), floor(cy + uy * (MUZZLE + 20))
  fx(cx + ux * MUZZLE, cy + uy * MUZZLE, ex, ey, w.fx, 4)
  if not ready("CRYOFORM", w) then return end
  if not ammoOk(w) then R.hint = "Cryo Former needs " .. R.nice("WATR"); return end
  fired("CRYOFORM"); ammoTick("CRYOFORM", w)
  local chilled = 0
  for step = MUZZLE, MUZZLE + 20, 2 do
    local sx, sy = floor(cx + ux * step), floor(cy + uy * step)
    for dy = -1, 1 do for dx = -1, 1 do
      local p = sim.partID(sx + dx, sy + dy)
      if p then pcall(sim.partProperty, p, "temp", 240); chilled = chilled + 1 end
    end end
  end
  -- real steam where the freezing jet meets warmer matter
  if chilled > 0 and R.frame % 2 == 0 then
    puff("WTRV", ex + (random() > 0.5 and 1 or -1), ey - 1, 26)
  end
  R.hint = chilled > 0 and "Freezing - water sets into real ice you can stand on" or "Cryo Former: aim at water"
end

-- ================================================================ 5. SUPPORT CUTTER
local function cutSupport(mx, my)
  local w = TW.SUPPORTCUT
  local ux, uy, cx, cy = aimAt(mx, my)
  local tx, ty = floor(cx + ux * 24), floor(cy + uy * 24)
  fx(cx + ux * MUZZLE, cy + uy * MUZZLE, tx, ty, w.fx, 3)
  if not ready("SUPPORTCUT", w) then return end
  if not ammoOk(w) then R.hint = "Support Cutter needs 2 " .. R.nice("METL"); return end
  fired("SUPPORTCUT"); spendAmmo(w)
  local cut = 0
  for dx = -7, 7 do for dy = -1, 1 do
    local p = sim.partID(tx + dx, ty + dy)
    if p then
      local nm = nameOf(sim.partProperty(p, "type"))
      if R.MINEABLE[nm] then give(nm == "BCOL" and "COAL" or nm, 1) end
      sim.partKill(p); cut = cut + 1
    end
  end end
  if type(R.crumble) == "function" then pcall(R.crumble, tx, ty - 6, 16) end
  -- shower of sparks along the kerf
  for i = -6, 6, 3 do puff("SPRK", tx + i, ty, 4) end
  puff("SMKE", tx, ty - 2, 30)
  fx(tx - 8, ty, tx + 8, ty, {255, 200, 120}, 3)   -- bright kerf flash
  if cut > 0 then say("Support cut - the mass above is now unsupported") end
  R.hint = cut > 0 and ("Cut " .. cut .. " support cells - watch it fall") or "Support Cutter: aim at rock under a mass"
end

-- ================================================================ 6/7. DISTANCE MINING
-- Reuses the real heat-mining pipeline items.lua already owns: R.addHeat does the real heating,
-- and items.lua's tick reaper watches R.itemsHeat and credits the material to the bag when the
-- particle finally melts. We only add entries in its format - no second mining system.
-- Heat rate divides by R.HARD, so diamond genuinely takes far longer than dirt.
local function heatCell(x, y, nm, p, rateMul)
  R.itemsHeat = R.itemsHeat or {}
  local rec = R.itemsHeat[p]
  if not rec or rec.nm ~= nm then rec = { nm = nm, accum = 0 }; R.itemsHeat[p] = rec end
  local hard = R.HARD[nm] or 3
  local k = (260 * 3 / hard) * (rateMul or 1)
  if type(R.addHeat) == "function" then pcall(R.addHeat, x, y, 3, k, 4000) end
  rec.accum = rec.accum + k; rec.touch = R.frame; rec.x, rec.y = x, y
  return rec.accum
end

local function miningLaser(mx, my)
  local w = TW.MININGLASER
  local ux, uy, cx, cy = aimAt(mx, my)
  local hx, hy, nm, p = trace(cx, cy, ux, uy, 130)
  fx(cx + ux * MUZZLE, cy + uy * MUZZLE, hx, hy, w.fx, 2)
  if not ready("MININGLASER", w) then return end
  if not ammoOk(w) then R.hint = "Mining Laser needs " .. R.nice("QRTZ"); return end
  fired("MININGLASER"); ammoTick("MININGLASER", w)
  if not p then R.hint = "Mining Laser: no rock in range"; return end
  local accum = heatCell(hx, hy, nm, p, 1.0)
  if R.frame % 3 == 0 then puff("SPRK", hx, hy - 1, 3) end
  if accum > 1400 and R.frame % 6 == 0 then puff("WTRV", hx + 1, hy - 1, 18) end
  R.hint = "Cutting " .. R.nice(nm) .. " at range (" .. floor(math.min(99, accum / 30)) .. "%)"
end

local function excavatorBeam(mx, my)
  local w = TW.EXCAVATOR
  local ux, uy, cx, cy = aimAt(mx, my)
  local hx, hy, nm, p = trace(cx, cy, ux, uy, 110)
  fx(cx + ux * MUZZLE, cy + uy * MUZZLE, hx, hy, w.fx, 6)   -- visibly a much heavier beam
  if not ready("EXCAVATOR", w) then return end
  if not ammoOk(w) then R.hint = "Excavator Beam needs " .. R.nice("QRTZ"); return end
  fired("EXCAVATOR"); ammoTick("EXCAVATOR", w)
  if not p then R.hint = "Excavator Beam: no seam in range"; return end
  -- wide swath: heat a band across the beam axis, so a whole seam goes at once
  local px, py = -uy, ux
  local n = 0
  for off = -4, 4 do
    local sx, sy = floor(hx + px * off), floor(hy + py * off)
    local q = sim.partID(sx, sy)
    if q then
      local qn = nameOf(sim.partProperty(q, "type"))
      if R.MINEABLE[qn] or R.HARD[qn] then heatCell(sx, sy, qn, q, 0.7); n = n + 1 end
    end
  end
  if R.frame % 2 == 0 then puff("SPRK", hx, hy - 1, 4) end
  if R.frame % 4 == 0 then puff("SMKE", hx, hy - 2, 20) end
  R.hint = n > 0 and ("Excavating a " .. n .. "-cell seam of " .. R.nice(nm)) or "Excavator Beam: no seam in range"
end

-- ================================================================ dispatch + hooks
local DISPATCH = {
  TUNNELBORE = boreTunnel, DEPOSITGUN = depositRock, MAGMALANCE = magmaLance,
  CRYOFORM = cryoForm, SUPPORTCUT = cutSupport,
  MININGLASER = miningLaser, EXCAVATOR = excavatorBeam,
}
R.twDispatch = DISPATCH

hook(R.hooks.place, function(el)
  if TW[el] then R.hint = TW[el].txt .. ": hold LEFT mouse to use it"; return true end
end)

hook(R.hooks.mousedown, function(x, y, button)
  if button ~= 1 or R.invOpen or R.menuOpen then return end
  if R.inZoom and R.inZoom(x, y) then return end
  local sel = R.hotbar and R.hotbar[R.sel or 1]
  local fn = sel and DISPATCH[sel]
  if fn then pcall(fn, x, y) end
  return false
end)

hook(R.hooks.tick, function()
  for i = #R.twFx, 1, -1 do if R.frame - R.twFx[i].frame >= 2 then table.remove(R.twFx, i) end end
  if not R.mouse or not R.mouse.l or R.invOpen or R.menuOpen then return end
  local sel = R.hotbar and R.hotbar[R.sel or 1]
  local w = sel and TW[sel]
  if w and w.continuous and DISPATCH[sel] then pcall(DISPATCH[sel], R.mouse.x, R.mouse.y) end
end)

-- beams drawn on the HUD pass so they sit on top of the world, like items.lua's own
hook(R.hooks.drawHUD, function()
  for _, b in ipairs(R.twFx) do
    if R.frame - b.frame < 2 then
      local c = b.col
      -- glow: dim offset lines first, bright core on top
      for o = b.w, 1, -1 do
        local a = floor(70 * (1 - (o - 1) / (b.w + 1)))
        graphics.drawLine(floor(b.x1), floor(b.y1) + o, floor(b.x2), floor(b.y2) + o, c[1], c[2], c[3], a)
        graphics.drawLine(floor(b.x1), floor(b.y1) - o, floor(b.x2), floor(b.y2) - o, c[1], c[2], c[3], a)
      end
      graphics.drawLine(floor(b.x1), floor(b.y1), floor(b.x2), floor(b.y2), c[1], c[2], c[3], 255)
    end
  end
end)

-- ================================================================ recipes (idempotent via _tag)
for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._tag == TAG then table.remove(R.RECIPES, i) end end
local function addRecipe(out, n, need, st, txt, desc)
  R.RECIPES[#R.RECIPES + 1] = { out = out, n = n, need = need, st = st, txt = txt, desc = desc, _tag = TAG }
end
addRecipe("TUNNELBORE",  1, { METL = 12, WOOD = 6 },            "workbench", "Tunnel Borer",   TW.TUNNELBORE.desc)
addRecipe("DEPOSITGUN",  1, { METL = 8,  STNE = 20 },           "workbench", "Deposition Gun", TW.DEPOSITGUN.desc)
addRecipe("MAGMALANCE",  1, { METL = 10, COAL = 12, GLAS = 4 }, "furnace",   "Magma Lance",    TW.MAGMALANCE.desc)
addRecipe("CRYOFORM",    1, { METL = 10, GLAS = 6,  QRTZ = 3 }, "furnace",   "Cryo Former",    TW.CRYOFORM.desc)
addRecipe("SUPPORTCUT",  1, { STEL = 6,  METL = 12 },           "anvil",     "Support Cutter", TW.SUPPORTCUT.desc)
addRecipe("MININGLASER", 1, { STEL = 8,  QRTZ = 10, GLAS = 6 }, "anvil",     "Mining Laser",   TW.MININGLASER.desc)
addRecipe("EXCAVATOR",   1, { STEL = 14, QRTZ = 18, CU = 6 },   "anvil",     "Excavator Beam", TW.EXCAVATOR.desc)

return true
