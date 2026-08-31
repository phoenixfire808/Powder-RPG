-- vehicles.lua - underground trains, minecarts, mine lifts and a drill train for the Powder RPG (2026-08-26).
-- Rails are a placeable material (real METL/BMTL particles laid by dragging), and every vehicle rides them with
-- real gravity/momentum/friction, ties into the machines.lua power grid or a real coal firebox, and mounts the
-- player via core's R.mount/R.dismount/R.ride so movement is entirely physics-driven, not scripted teleporting.
-- Owns: R.hooks.tick/draw/drawHUD/place/mousedown/mouseup/key entries tagged "vehicles", R.vehicles, R.railSegs,
-- R.trainStops, R.ITEMS.<kit names>, R.RECIPES entries for those kits. Does not touch any other file.
--
-- Vehicles: MINECART (manual, gravity+momentum, derails off the end of the track), HANDCAR (no power, tap D to
-- pump), LOCOMOTIVE + up to 3 CARGO WAGONS (coal firebox or grid power, simple two-stop auto-route, wagons follow
-- a recorded trail so they trace the loco's exact path through curves/slopes), MINE LIFT (a cage on a vertical
-- rail shaft with call buttons at both ends, climbs while grid-powered, free-falls if power is lost), DRILL TRAIN
-- (bores forward through rock using the normal pick tier/hardness rules, credits ore, lays its own rail behind).
--
-- Controls: V = board the nearest vehicle (or climb out of the current one); D = drive/accelerate forward,
-- A = slow/reverse, S = brake (holding S more than ~20 frames also climbs you out, same as any other mount);
-- P = toggle a locomotive's two-stop auto-route. Rails: select the Rail kit, hold RIGHT mouse and drag - the
-- track snaps to flat, +-45 degree slopes, or straight up/down.

local R = PBX.state.rpg
local TAG = "vehicles"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local W, H = R.W, R.H
local floor, sqrt, cos, sin, abs = math.floor, math.sqrt, math.cos, math.sin, math.abs
local function nice(n) return (R.nice and R.nice(n)) or n end

-- ================================================================ persisted state
R.vehicles = R.vehicles or {}     -- {kind, x, y, dir={x,y}, speed, dead, ...kind-specific fields}, world coords
R.railSegs = R.railSegs or {}     -- {x1,y1,x2,y2,kind} straight track pieces, world coords
R.trainStops = R.trainStops or {} -- {x, y}
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
for _, k in ipairs({ "vehicles", "railSegs", "trainStops" }) do
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == k then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, k) end
end

-- ================================================================ low-level particle helpers (own copies; these
-- are plugin-local everywhere else in this codebase, not shared on R)
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function setAt(wx, wy, elName)
  killAt(wx, wy); local t = R.eid(elName); if not t then return nil end
  return sim.partCreate(-1, wx - R.cam.x, wy - R.cam.y, t)
end
local function boxFill(x1, y1, x2, y2, elName) for y = y1, y2 do for x = x1, x2 do setAt(x, y, elName) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if R.solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
local function atan2(y, x)
  if x > 0 then return math.atan(y / x)
  elseif x < 0 and y >= 0 then return math.atan(y / x) + math.pi
  elseif x < 0 and y < 0 then return math.atan(y / x) - math.pi
  elseif x == 0 and y > 0 then return math.pi / 2
  elseif x == 0 and y < 0 then return -math.pi / 2
  else return 0 end
end
local function onScreen(wx, wy, pad) local cx, cy = wx - R.cam.x, wy - R.cam.y; pad = pad or 20; return cx > -pad and cx < W + pad and cy > -pad and cy < H + pad end
local function poweredNear(wx, wy, r)
  r = r or 1
  if not onScreen(wx, wy, 24) then return false end
  local cx, cy = wx - R.cam.x, wy - R.cam.y
  for dy = -r, r do for dx = -r, r do
    local p = sim.partID(cx + dx, cy + dy)
    if p and R.nameOf(sim.partProperty(p, "type")) == "SPRK" then return true end
  end end
  return false
end

-- ================================================================ RAIL SYSTEM: a persisted graph of straight
-- segments (world coords). Real METL/BMTL particles are laid for looks and for the player to see/mine, but
-- vehicle physics reads the segment list, not particles, so a train stays on the rail hundreds of px off-screen.
local function classifyDir(ux, uy) if abs(uy) < 0.01 then return "flat" elseif abs(ux) < 0.01 then return "vert" else return "slope" end end
local function segClosest(seg, x, y)
  local dx, dy = seg.x2 - seg.x1, seg.y2 - seg.y1
  local len2 = dx * dx + dy * dy
  if len2 < 0.0001 then return seg.x1, seg.y1, sqrt((x - seg.x1) ^ 2 + (y - seg.y1) ^ 2), 0, 0, 0 end
  local t = ((x - seg.x1) * dx + (y - seg.y1) * dy) / len2
  local tc = math.max(0, math.min(1, t))
  local px, py = seg.x1 + dx * tc, seg.y1 + dy * tc
  local ddx, ddy = x - px, y - py
  local len = sqrt(len2)
  return px, py, sqrt(ddx * ddx + ddy * ddy), t, dx / len, dy / len
end
-- returns { seg, t, dx, dy(unit) } for the best matching rail near (x,y), preferring one that continues
-- in direction (pdx,pdy) when several are within tolerance (handles junctions/curve hand-offs)
local function nearestRail(x, y, pdx, pdy, tol)
  tol = tol or 3
  local cands = {}
  for _, seg in ipairs(R.railSegs) do
    local px, py, dist, t, dx, dy = segClosest(seg, x, y)
    local len = sqrt((seg.x2 - seg.x1) ^ 2 + (seg.y2 - seg.y1) ^ 2)
    if len > 0.01 then
      local tExt = tol / len
      if dist <= tol and t >= -tExt and t <= 1 + tExt then
        cands[#cands + 1] = { seg = seg, t = t, dx = dx, dy = dy, dist = dist }
      end
    end
  end
  if #cands == 0 then return nil end
  if pdx and (pdx ~= 0 or pdy ~= 0) then
    local best, bestScore
    for _, c in ipairs(cands) do
      local dot = c.dx * pdx + c.dy * pdy
      local score = -abs(dot) + c.dist * 0.05
      if not best or score < bestScore then best, bestScore = c, score end
    end
    return best
  end
  table.sort(cands, function(a, b) return a.dist < b.dist end)
  return cands[1]
end
R.railFind = nearestRail

-- drag-to-lay: RMB-held anchor set on mousedown, extended in place each tick placeAt calls the place hook
local function layRailStep(x, y, ux, uy)
  setAt(x, y, "BMTL")
  if (x + y) % 4 == 0 then setAt(x - uy, y + ux, "METL"); setAt(x + uy, y - ux, "METL") end
end
local function placeRail(mx, my)
  local wx, wy = floor(mx + R.cam.x), floor(my + R.cam.y)
  if not R.railAnchor then R.railAnchor = { x = wx, y = wy }; R.railBuilt = 0; return true end
  local ax, ay = R.railAnchor.x, R.railAnchor.y
  local dx, dy = wx - ax, wy - ay
  local dist = sqrt(dx * dx + dy * dy)
  if dist < 4 then return true end
  local ang = atan2(dy, dx)
  local step = math.pi / 4
  local snapped = floor(ang / step + 0.5) * step
  local ux, uy = cos(snapped), sin(snapped)
  local proj = math.max(0, dx * ux + dy * uy)
  local built = R.railBuilt or 0
  if proj <= built + 1 then return true end
  if not R.railSegRef then
    R.railSegRef = { x1 = ax, y1 = ay, x2 = ax, y2 = ay, kind = classifyDir(ux, uy) }
    table.insert(R.railSegs, R.railSegRef)
  end
  local s = built; local n = 0
  while s < proj do
    if R.inv("RAILKIT") <= 0 then break end
    local x, y = floor(ax + ux * s + 0.5), floor(ay + uy * s + 0.5)
    layRailStep(x, y, ux, uy)
    R.inventory.RAILKIT = R.inv("RAILKIT") - 1
    s = s + 1; n = n + 1
  end
  built = math.min(proj, s)
  R.railBuilt = built
  R.railSegRef.x2, R.railSegRef.y2 = floor(ax + ux * built + 0.5), floor(ay + uy * built + 0.5)
  if n > 0 then R.rebuildHotbar() end
  if R.inv("RAILKIT") <= 0 then R.hint = "out of rail" end
  return true
end

-- ================================================================ generic on-rail physics, shared by every
-- wheeled vehicle (minecart / handcar / locomotive / drill train)
local GRAV_ALONG, FRICTION, MAXSPD = 0.045, 0.994, 3.2
local function derailCrash(v)
  if v.dead then return end
  v.dead = true
  local wasRiding = (R.ride == v)
  if wasRiding then
    local dmg = math.min(20, 4 + floor(abs(v.speed or 0) * 4))
    R.hp = math.max(0, R.hp - dmg); R.hurt = R.frame
    R.shake = { t = R.frame, mag = 6 }
    R.say("CRASH! The " .. (v.label or "vehicle") .. " derails - you're thrown clear (-" .. dmg .. " HP)")
  else
    R.say("A " .. (v.label or "vehicle") .. " ran off the end of the rail and derailed")
  end
  local cx, cy = floor(v.x - R.cam.x), floor(v.y - R.cam.y)
  for _ = 1, 6 do
    local p = sim.partCreate(-1, cx + math.random(-3, 3), cy + math.random(-4, 0), R.eid("SPRK") or R.eid("SMKE"))
    if p and p >= 0 then sim.partProperty(p, "life", 3) end
  end
end
-- moves v forward along the rail by driveAccel (added to speed before gravity/friction); returns false if the
-- vehicle has run off the end of the track (caller should crash it)
local function advanceOnRail(v, driveAccel)
  local pdx, pdy = (v.dir and v.dir.x) or 0, (v.dir and v.dir.y) or 0
  local c = nearestRail(v.x, v.y, pdx, pdy, v.railTol or 3)
  if not c then return false end
  local ndx, ndy = c.dx, c.dy
  if v.dir and (ndx * v.dir.x + ndy * v.dir.y) < 0 then ndx, ndy = -ndx, -ndy end
  v.dir = { x = ndx, y = ndy }
  local seg = c.seg
  v.x = seg.x1 + (seg.x2 - seg.x1) * c.t
  v.y = seg.y1 + (seg.y2 - seg.y1) * c.t
  v.speed = (v.speed or 0) + GRAV_ALONG * v.dir.y + (driveAccel or 0)
  v.speed = v.speed * FRICTION
  if v.speed > MAXSPD then v.speed = MAXSPD elseif v.speed < -MAXSPD then v.speed = -MAXSPD end
  local nx, ny = v.x + v.dir.x * v.speed, v.y + v.dir.y * v.speed
  local blocked = false
  for h = 2, 7 do if R.solidW(floor(nx + 0.5), floor(ny + 0.5) - h) then blocked = true; break end end
  if blocked then v.speed = 0 else v.x, v.y = nx, ny end
  v.wheelAngle = (v.wheelAngle or 0) + v.speed * 0.35
  return true
end
local function nearestVehicle(wx, wy, range)
  local best, bestD
  for _, v in ipairs(R.vehicles) do
    if not v.dead and v.rideable then
      local dx, dy = v.x - wx, v.y - wy; local d = dx * dx + dy * dy
      if d <= range * range and (not best or d < bestD) then best, bestD = v, d end
    end
  end
  return best
end
local function fireboxLit(v)
  local fb = v.firebox; if not fb then return false end
  for yy = fb.y1, fb.y2 do for xx = fb.x1, fb.x2 do
    local p = sim.partID(xx - R.cam.x, yy - R.cam.y)
    if p then local nm = R.nameOf(sim.partProperty(p, "type")); local t = sim.partProperty(p, "temp") or 295
      if nm == "FIRE" or nm == "PLSM" or t > 600 then return true end end
  end end
  return false
end
local function trailPointAt(trail, backDist)
  local n = #trail; if n == 0 then return nil end
  if backDist <= 0 then return trail[n].x, trail[n].y end
  local acc = 0
  for i = n, 2, -1 do
    local a, b = trail[i], trail[i - 1]
    local dx, dy = a.x - b.x, a.y - b.y; local d = sqrt(dx * dx + dy * dy)
    if acc + d >= backDist then
      local f = (d > 0.0001) and ((backDist - acc) / d) or 0
      return a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f
    end
    acc = acc + d
  end
  return trail[1].x, trail[1].y
end

-- ================================================================ MINECART
local function buildMinecart(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local c = nearestRail(wx, wy, nil, nil, 6)
  if not c then R.say("Minecart: place it directly on a laid rail"); return false end
  local x, y = c.seg.x1 + (c.seg.x2 - c.seg.x1) * c.t, c.seg.y1 + (c.seg.y2 - c.seg.y1) * c.t
  table.insert(R.vehicles, { kind = "minecart", label = "Minecart", x = x, y = y, dir = { x = c.dx, y = c.dy },
    speed = 0, seatY = 7, rideable = true, dead = false })
  R.say("Minecart placed on the rail - press V to climb aboard")
  return true
end
local function tickMinecart(v)
  local accel = 0
  if R.ride == v then
    if R.keys.d then accel = 0.05 end
    if R.keys.a then accel = accel - 0.05 end
    if R.keys.s then v.speed = (v.speed or 0) * 0.82 end
  end
  if not advanceOnRail(v, accel) then derailCrash(v) end
end
local function drawWheeled(v, bodyCol, bodyW, bodyH, wheelR)
  local x, y = floor(v.x - R.cam.x), floor(v.y - R.cam.y)
  local ang = math.atan and math.atan(v.dir.y, v.dir.x) or atan2(v.dir.y, v.dir.x)
  -- body: a small rotated-look box approximated as a rect aligned to the rail (good enough at this scale)
  graphics.fillRect(x - bodyW / 2, y - bodyH - wheelR, bodyW, bodyH, bodyCol[1], bodyCol[2], bodyCol[3], 255)
  graphics.fillRect(x - bodyW / 2, y - bodyH - wheelR - 1, bodyW, 1, math.min(255, bodyCol[1] + 40), math.min(255, bodyCol[2] + 40), math.min(255, bodyCol[3] + 40), 255)
  for _, wx in ipairs({ -bodyW / 2 + wheelR, bodyW / 2 - wheelR }) do
    graphics.fillCircle(x + wx, y - wheelR, wheelR, wheelR, 40, 40, 45, 255)
    local sa = v.wheelAngle or 0
    graphics.drawLine(x + wx, y - wheelR, x + wx + cos(sa) * wheelR, y - wheelR + sin(sa) * wheelR, 200, 200, 210, 255)
    graphics.drawLine(x + wx, y - wheelR, x + wx - cos(sa) * wheelR, y - wheelR - sin(sa) * wheelR, 200, 200, 210, 255)
  end
  return x, y
end
local function drawMinecart(v)
  local x, y = drawWheeled(v, { 120, 70, 40 }, 12, 6, 3)
  -- headlight cone when underground and moving
  if v.y > (R.surfaceAt(floor(v.x)) or 0) and abs(v.speed or 0) > 0.05 then
    local fx = (v.speed or 0) >= 0 and v.dir.x or -v.dir.x
    local fy = (v.speed or 0) >= 0 and v.dir.y or -v.dir.y
    for a = -1, 1 do
      local ang = atan2(fy, fx) + a * 0.22
      graphics.drawLine(x, y - 5, x + cos(ang) * 26, y - 5 + sin(ang) * 26, 255, 245, 190, 55 - abs(a) * 15)
    end
  end
end

-- ================================================================ HANDCAR (no power - tap D to pump)
local function buildHandcar(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local c = nearestRail(wx, wy, nil, nil, 6)
  if not c then R.say("Handcar: place it directly on a laid rail"); return false end
  local x, y = c.seg.x1 + (c.seg.x2 - c.seg.x1) * c.t, c.seg.y1 + (c.seg.y2 - c.seg.y1) * c.t
  table.insert(R.vehicles, { kind = "handcar", label = "Handcar", x = x, y = y, dir = { x = c.dx, y = c.dy },
    speed = 0, seatY = 6, rideable = true, dead = false, pumpFlash = 0 })
  R.say("Handcar placed - press V to board, tap D to pump the lever")
  return true
end
local function tickHandcar(v)
  local accel = 0
  if R.ride == v and R.keys.s then v.speed = (v.speed or 0) * 0.8 end
  if not advanceOnRail(v, accel) then derailCrash(v) end
end

-- ================================================================ LOCOMOTIVE + CARGO WAGONS + STOPS
local WAGON_SPACING = 15
local function buildLoco(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local c = nearestRail(wx, wy, nil, nil, 6)
  if not c then R.say("Locomotive: place it directly on a laid rail"); return false end
  local x, y = c.seg.x1 + (c.seg.x2 - c.seg.x1) * c.t, c.seg.y1 + (c.seg.y2 - c.seg.y1) * c.t
  boxFill(floor(x) - 2, floor(y) - 9, floor(x) - 1, floor(y) - 8, "BRCK")   -- firebox shell
  clearBox(floor(x) - 2, floor(y) - 8, floor(x) - 1, floor(y) - 8)
  setAt(floor(x) - 2, floor(y) - 8, "COAL")
  setAt(floor(x) + 4, floor(y) - 12, "CU")                                 -- power stud on the roof
  table.insert(R.vehicles, { kind = "loco", label = "Locomotive", x = x, y = y, dir = { x = c.dx, y = c.dy },
    speed = 0, seatY = 10, rideable = true, dead = false,
    firebox = { x1 = floor(x) - 2, y1 = floor(y) - 9, x2 = floor(x) - 1, y2 = floor(y) - 8 },
    padX = floor(x) + 4, padY = floor(y) - 12, trail = {}, wagons = {}, autoRoute = false, dwell = 0 })
  R.say("Locomotive placed - light the coal firebox with the torch or wire the roof stud to a live grid, then press V")
  return true
end
local function buildWagon(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local c = nearestRail(wx, wy, nil, nil, 6)
  if not c then R.say("Cargo wagon: place it directly on a laid rail"); return false end
  local x, y = c.seg.x1 + (c.seg.x2 - c.seg.x1) * c.t, c.seg.y1 + (c.seg.y2 - c.seg.y1) * c.t
  table.insert(R.vehicles, { kind = "wagon", label = "Cargo wagon", x = x, y = y, dir = { x = c.dx, y = c.dy },
    speed = 0, dead = false, rideable = false, cargo = {}, coupledTo = nil })
  R.say("Cargo wagon placed - a nearby locomotive will couple to it automatically")
  return true
end
local function buildStop(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local c = nearestRail(wx, wy, nil, nil, 6)
  if not c then R.say("Train stop: place it directly on a laid rail"); return false end
  local x, y = c.seg.x1 + (c.seg.x2 - c.seg.x1) * c.t, c.seg.y1 + (c.seg.y2 - c.seg.y1) * c.t
  boxFill(floor(x) - 1, floor(y) - 10, floor(x) + 1, floor(y) - 9, "WOOD")
  setAt(floor(x), floor(y) - 11, "PSCN")
  table.insert(R.trainStops, { x = x, y = y })
  R.say("Train stop built (" .. #R.trainStops .. " on the line)")
  return true
end
local function doCargoTransfer(v)
  for _, w in ipairs(v.wagons or {}) do
    if next(w.cargo or {}) then
      local crate
      for _, m in ipairs(R.machines or {}) do
        if m.kind == "crate" then local dx, dy = m.x - w.x, m.y - w.y; if dx * dx + dy * dy < 900 then crate = m; break end end
      end
      if crate then
        crate.items = crate.items or {}
        for k2, n2 in pairs(w.cargo) do crate.items[k2] = (crate.items[k2] or 0) + n2 end
        w.cargo = {}
        R.say("Wagon unloaded into the nearby crate")
      end
    end
  end
end
local function updateWagons(v)
  for i, w in ipairs(v.wagons or {}) do
    local bx, by = trailPointAt(v.trail, i * WAGON_SPACING)
    if bx then w.x, w.y = bx, by; w.dead = false end
  end
  -- auto-couple any nearby uncoupled wagon
  if #v.wagons < 3 then
    local tail = v.wagons[#v.wagons] or v
    for _, w in ipairs(R.vehicles) do
      if w.kind == "wagon" and not w.dead and not w.coupledTo and #v.wagons < 3 then
        local dx, dy = w.x - tail.x, w.y - tail.y
        -- coupledTo is a plain boolean flag, NEVER a reference to the loco: save.lua walks R.vehicles
        -- recursively to persist it, and a wagon<->loco table cycle here stack-overflows that walk
        if dx * dx + dy * dy < 24 * 24 then w.coupledTo = true; table.insert(v.wagons, w) end
      end
    end
  end
end
local function autoRouteAccel(v)
  if not (v.stopA and v.stopB) then return 0 end
  local target = v.headingToB and v.stopB or v.stopA
  local remain = (target.x - v.x) * v.dir.x + (target.y - v.y) * v.dir.y
  if abs(remain) < 6 then
    v.speed = v.speed * 0.5
    if abs(v.speed) < 0.15 then
      v.dwell = (v.dwell or 0) + 1
      if v.dwell == 1 then doCargoTransfer(v); R.say("Locomotive stopped at a station") end
      if v.dwell > 90 then v.dwell = 0; v.headingToB = not v.headingToB end
    end
    return 0
  end
  v.dwell = 0
  return (remain > 0) and 0.05 or -0.05
end
local function toggleAutoRoute(v)
  if v.autoRoute then v.autoRoute = false; R.say("Auto-route off"); return end
  if #R.trainStops < 2 then R.say("Need at least 2 Train Stops on this line for auto-route"); return end
  -- pick the two stops closest to the loco (by simple distance - a route is meant to be along one line)
  local ordered = {}
  for _, s in ipairs(R.trainStops) do ordered[#ordered + 1] = s end
  table.sort(ordered, function(a, b) return (a.x - v.x) ^ 2 + (a.y - v.y) ^ 2 < (b.x - v.x) ^ 2 + (b.y - v.y) ^ 2 end)
  v.stopA, v.stopB = ordered[1], ordered[2]
  v.headingToB = true; v.autoRoute = true; v.dwell = 0
  R.say("Auto-route ON: shuttling between 2 stations")
end
local function tickLoco(v)
  v.lit = fireboxLit(v)
  v.gridPower = poweredNear(v.padX, v.padY, 1)
  local powered = v.lit or v.gridPower
  local accel = 0
  if R.ride == v then
    if R.keys.d then accel = powered and 0.05 or 0.01 end
    if R.keys.a then accel = accel - (powered and 0.05 or 0.01) end
    if R.keys.s then v.speed = (v.speed or 0) * 0.85 end
  elseif v.autoRoute and powered then
    accel = autoRouteAccel(v)
  end
  if not advanceOnRail(v, accel) then derailCrash(v); return end
  if v.lit and R.frame % 14 == 0 then
    local sx, sy = v.firebox.x1 - R.cam.x, v.firebox.y1 - R.cam.y - 2
    local p = sim.partCreate(-1, sx, sy, R.eid("SMKE")); if p and p >= 0 then sim.partProperty(p, "vy", -1) end
  end
  table.insert(v.trail, { x = v.x, y = v.y }); if #v.trail > 2000 then table.remove(v.trail, 1) end
  updateWagons(v)
end
local function drawLoco(v)
  local x, y = drawWheeled(v, { 40, 40, 45 }, 20, 9, 4)
  -- firebox glow + chimney
  graphics.fillRect(x - 10, y - 8, 2, 3, v.lit and 255 or 120, v.lit and 140 or 60, v.lit and 40 or 40, 255)
  graphics.fillRect(x + 6, y - 16, 2, 6, 60, 60, 65, 255)
  -- power dot at the pad
  local pw = (v.lit or v.gridPower)
  graphics.fillCircle(x + 8, y - 17, 2, 2, pw and 90 or 90, pw and 255 or 60, pw and 90 or 60, 255)
end
local function drawWagon(v)
  local x, y = drawWheeled(v, { 90, 60, 35 }, 14, 7, 3)
  local n = 0; for _ in pairs(v.cargo or {}) do n = n + 1 end
  if n > 0 then graphics.fillRect(x - 3, y - 11, 6, 3, 200, 170, 90, 255) end
end

-- ================================================================ MINE LIFT (elevator on a vertical rail shaft)
local function findVerticalShaft(wx, wy)
  local best
  for _, seg in ipairs(R.railSegs) do
    if abs(seg.x2 - seg.x1) < 1.5 and abs(seg.x1 - wx) < 5 then
      local y1, y2 = math.min(seg.y1, seg.y2), math.max(seg.y1, seg.y2)
      if wy >= y1 - 6 and wy <= y2 + 6 and (not best or (y2 - y1) > (best.y2 - best.y1)) then
        best = { x = seg.x1, y1 = y1, y2 = y2 }
      end
    end
  end
  return best
end
local function buildLift(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local shaft = findVerticalShaft(wx, wy)
  if not shaft then R.say("Mine lift: place it on a VERTICAL rail shaft (drag the Rail kit straight up/down first)"); return false end
  local sx, topY, botY = shaft.x, shaft.y1, shaft.y2
  boxFill(sx - 4, topY - 2, sx - 2, topY, "PSCN")   -- top call button
  boxFill(sx - 4, botY, sx - 2, botY + 2, "PSCN")   -- bottom call button
  setAt(sx + 3, topY - 3, "CU")                     -- power stud
  table.insert(R.vehicles, { kind = "lift", label = "Mine lift", x = wx, y = math.max(topY, math.min(botY, wy)),
    dir = { x = 0, y = 1 }, speed = 0, seatY = 9, rideable = true, dead = false,
    shaftX = sx, topY = topY, botY = botY, target = nil,
    btnTop = { x = sx - 3, y = topY - 1 }, btnBot = { x = sx - 3, y = botY + 1 }, padX = sx + 3, padY = topY - 3 })
  R.say("Mine lift installed on the shaft - power its stud, then click a call button at either end")
  return true
end
local ELEV_MAXSPD, ELEV_FALL = 2.0, 3.0
local function tickLift(v)
  local powered = poweredNear(v.padX, v.padY, 1)
  v.gridPower = powered
  if v.target then
    local dy = v.target - v.y
    if abs(dy) < 1.2 then v.y = v.target; v.speed = 0; v.target = nil
    elseif powered then
      local dir = dy > 0 and 1 or -1
      local dist = abs(dy)
      local desired = math.min(ELEV_MAXSPD, sqrt(2 * 0.05 * dist)) * dir
      v.speed = (v.speed or 0) + (desired - (v.speed or 0)) * 0.25
      v.y = v.y + v.speed
    else
      v.speed = math.min(ELEV_FALL, (v.speed or 0) + 0.15); v.y = v.y + v.speed
    end
  else
    if powered then v.speed = (v.speed or 0) * 0.7
    else v.speed = math.min(ELEV_FALL, (v.speed or 0) + 0.15); v.y = v.y + v.speed end
  end
  if v.y < v.topY then v.y = v.topY; v.speed = 0 end
  if v.y > v.botY then v.y = v.botY; if v.speed > 0.5 then R.say("The lift cage slams into the bottom stop") end; v.speed = 0 end
  v.wheelAngle = (v.wheelAngle or 0) + v.speed * 0.4
end
local function drawLift(v)
  local x, y = floor(v.x - R.cam.x), floor(v.y - R.cam.y)
  graphics.drawLine(x, floor(v.topY - R.cam.y), x, y - 9, 90, 90, 100, 200)   -- cable
  graphics.fillRect(x - 5, y - 9, 10, 9, 60, 65, 75, 255)
  for i = 0, 2 do graphics.drawLine(x - 5, y - 9 + i * 3, x + 4, y - 9 + i * 3, 30, 30, 35, 255) end
  local pw = v.gridPower
  for _, b in ipairs({ v.btnTop, v.btnBot }) do
    local bx, by = floor(b.x - R.cam.x), floor(b.y - R.cam.y)
    graphics.fillRect(bx - 1, by - 1, 3, 3, pw and 90 or 150, pw and 255 or 60, pw and 90 or 60, 255)
  end
end

-- ================================================================ DRILL TRAIN (tunnels forward, lays rail behind)
local DRILL_POWER = 4
local function buildDrillTrain(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx - 3, gy - 8, wx - 2, gy - 7, "BRCK")
  clearBox(wx - 3, gy - 7, wx - 2, gy - 7); setAt(wx - 3, gy - 7, "COAL")
  setAt(wx - 3, gy - 11, "CU")
  local seg = { x1 = wx, y1 = gy - 3, x2 = wx, y2 = gy - 3, kind = "flat" }
  table.insert(R.railSegs, seg)
  table.insert(R.vehicles, { kind = "drill", label = "Drill train", x = wx, y = gy - 3, dir = { x = R.P.face >= 0 and 1 or -1, y = 0 },
    speed = 0, seatY = 8, rideable = true, dead = false, face = R.P.face >= 0 and 1 or -1,
    firebox = { x1 = wx - 3, y1 = gy - 8, x2 = wx - 2, y2 = gy - 7 }, padX = wx - 3, padY = gy - 11, railRef = seg })
  R.say("Drill train placed - light its firebox or power its stud, board with V, hold D/A to bore through rock")
  return true
end
local function mineDrill(v, sign)
  if (R.frame - (v.lastBite or -99)) < 3 then return end
  v.lastBite = R.frame
  local aheadX = floor(v.x + sign * 3)
  local blocked, cleared = nil, true
  for yy = -3, 2 do
    local wy = floor(v.y) + yy
    local p = sim.partID(aheadX - R.cam.x, wy - R.cam.y)
    if p then
      local nm = R.nameOf(sim.partProperty(p, "type")); local tier = R.MINEABLE[nm]
      if tier then
        if tier > DRILL_POWER + 1 then blocked = nm; cleared = false
        else
          local need = math.max(1, R.HARD[nm] or 3)
          local hits = (R.blockHits[p] or 0) + 1
          if hits >= need then R.blockHits[p] = nil; sim.partKill(p); R.give((nm == "BCOL") and "COAL" or nm, 1)
          else R.blockHits[p] = hits; cleared = false end
        end
      end
    end
  end
  pcall(R.crumble, aheadX - R.cam.x, floor(v.y) - R.cam.y, 4)
  if blocked then R.hint = nice(blocked) .. " is too hard for this drill"; return end
  if cleared then
    v.face = sign; v.x = v.x + sign * 0.6
    if v.railRef then v.railRef.x2 = floor(v.x); v.railRef.y2 = floor(v.y) end
    v.dir = { x = sign, y = 0 }
  end
end
local function tickDrill(v)
  v.lit = fireboxLit(v)
  v.gridPower = poweredNear(v.padX, v.padY, 1)
  local powered = v.lit or v.gridPower
  if R.ride == v and powered then
    if R.keys.d then mineDrill(v, 1) end
    if R.keys.a then mineDrill(v, -1) end
  end
  v.wheelAngle = (v.wheelAngle or 0) + (powered and R.keys and (R.keys.d or R.keys.a) and 0.5 or 0)
end
local function drawDrill(v)
  local x, y = floor(v.x - R.cam.x), floor(v.y - R.cam.y)
  graphics.fillRect(x - 6, y - 10, 12, 7, 60, 60, 68, 255)
  graphics.fillCircle(x - 10, y - 6, 4, 4, 40, 40, 45, 255)
  graphics.fillCircle(x + 10, y - 6, 4, 4, 40, 40, 45, 255)
  local tipx = x + v.face * 12
  graphics.fillCircle(tipx, y - 7, 3, 3, 150, 150, 160, 255)
  local sa = v.wheelAngle or 0
  for a = 0, 2 do
    local ang = sa + a * 2.09
    graphics.drawLine(tipx, y - 7, tipx + v.face * cos(ang) * 3, y - 7 + sin(ang) * 3, 220, 220, 230, 255)
  end
  graphics.fillRect(x - 4, y - 8, 2, 3, v.lit and 255 or 100, v.lit and 140 or 60, v.lit and 40 or 40, 255)
end

-- ================================================================ mount/interact + gated recipes
local DRAW = { minecart = drawMinecart, handcar = function(v) drawWheeled(v, { 130, 100, 60 }, 10, 5, 3) end,
  loco = drawLoco, wagon = drawWagon, lift = drawLift, drill = drawDrill }
local TICK = { minecart = tickMinecart, handcar = tickHandcar, loco = tickLoco, lift = tickLift, drill = tickDrill }

hook(R.hooks.tick, function()
  for i = #R.vehicles, 1, -1 do
    local v = R.vehicles[i]
    if v.dead then
      if R.ride == v then R.ride = nil end
      table.remove(R.vehicles, i)
    else
      local fn = TICK[v.kind]; if fn then pcall(fn, v) end
    end
  end
  -- lazily unlock the heavier kits once the machines power grid says the base is producing real watts
  if not R.vehiclesTechOK and (R.frame % 60 == 0) then
    if (not R.tech) or R.tech.unlock10 then R.vehiclesTechOK = true; R.vehiclesInstallGated() end
  end
end)

hook(R.hooks.draw, function()
  for _, v in ipairs(R.vehicles) do
    if not v.dead and onScreen(v.x, v.y, 24) then local fn = DRAW[v.kind]; if fn then pcall(fn, v) end end
  end
end)

local NAMEOF = { minecart = "Minecart", handcar = "Handcar", loco = "Locomotive", wagon = "Cargo wagon", lift = "Mine lift", drill = "Drill train" }
hook(R.hooks.drawHUD, function()
  local nearBoard
  for _, v in ipairs(R.vehicles) do
    if not v.dead and onScreen(v.x, v.y, 24) then
      local dx, dy = v.x - R.P.x, v.y - R.P.y
      local d2 = dx * dx + dy * dy
      if d2 < 160 * 160 then
        local x, y = floor(v.x - R.cam.x), floor(v.y - R.cam.y) - 18
        if y > 4 then graphics.drawText(x - 2, y, NAMEOF[v.kind] or v.kind, 255, 230, 150, 220) end
        if v.kind == "loco" and v.autoRoute then graphics.drawText(x - 2, y - 10, "AUTO", 140, 220, 255, 220) end
      end
      if v.rideable and not v.dead and not R.ride and d2 < 26 * 26 then nearBoard = v end
    end
  end
  if nearBoard then
    R.hint = "[V] board " .. (nearBoard.label or NAMEOF[nearBoard.kind] or "vehicle") .. "   (S to climb off)"
  end
end)

hook(R.hooks.key, function(k)
  -- Only eat V when actually boarding/dismounting; otherwise core uses V for brush shape (Tab/V).
  if k == "v" then
    if R.ride and R.ride._vehTag then R.dismount(); return true end
    local v = nearestVehicle(R.P.x, R.P.y, 26)
    if v then v._vehTag = true; R.mount(v); return true end
    return false
  end
  if k == "p" and R.ride and R.ride.kind == "loco" then toggleAutoRoute(R.ride); return true end
  if k == "d" and R.ride and R.ride.kind == "handcar" then R.ride.speed = (R.ride.speed or 0) + 0.85; return true end
end)

hook(R.hooks.mousedown, function(x, y, button)
  if R.invOpen or R.menuOpen or R.cratePanel then return end
  local wx, wy = x + R.cam.x, y + R.cam.y
  if button == 3 then
    local sel = R.hotbar and R.hotbar[R.sel]
    if sel == "RAILKIT" then R.railAnchor = { x = wx, y = wy }; R.railBuilt = 0; R.railSegRef = nil end
    return
  end
  if button == 1 then
    for _, v in ipairs(R.vehicles) do
      if v.kind == "lift" and not v.dead then
        if v.btnTop and abs(wx - v.btnTop.x) < 6 and abs(wy - v.btnTop.y) < 5 then v.target = v.topY; return true end
        if v.btnBot and abs(wx - v.btnBot.x) < 6 and abs(wy - v.btnBot.y) < 5 then v.target = v.botY; return true end
      end
      if v.kind == "wagon" and not v.dead and abs(wx - v.x) < 10 and abs(wy - v.y) < 8 then
        local sel = R.hotbar and R.hotbar[R.sel]
        if sel and not tostring(sel):find("^tool:") and not R.ITEMS[sel] and R.inv(sel) > 0 then
          local n = math.min(20, R.inv(sel))
          v.cargo[sel] = (v.cargo[sel] or 0) + n
          R.inventory[sel] = R.inv(sel) - n
          R.rebuildHotbar(); R.say("Loaded " .. n .. " " .. nice(sel) .. " onto the wagon")
          return true
        end
      end
    end
  end
end)
hook(R.hooks.mouseup, function(x, y, button) if button == 3 then R.railAnchor = nil; R.railSegRef = nil; R.railBuilt = nil end end)

-- ================================================================ items + recipes + place dispatch
R.ITEMS.RAILKIT = { col = { 255, 240, 96 }, desc = "Rail kit: select it, hold LEFT mouse and drag along flat ground, a slope, or straight up to lay real track (METL sleepers + a bright rail line). Snaps to horizontal, 45-degree slopes and vertical shafts. Craft at a workbench; every vehicle below rides this." }
R.ITEMS.MINECARTKIT = { col = { 120, 70, 40 }, desc = "Minecart: place it directly on laid track. Press V to climb aboard - D accelerates, A slows/reverses, S brakes (holding S also climbs you back out). Gravity does the rest on slopes; run off the end of the track and it derails." }
R.ITEMS.HANDCARKIT = { col = { 130, 100, 60 }, desc = "Handcar: no power needed. Place on track, press V to board, then tap D to pump the lever - each fresh tap gives it a push. Coasts and obeys gravity like any other cart." }
R.ITEMS.LOCOKIT = { col = { 40, 40, 45 }, desc = "Steam locomotive: place on track. Needs a lit coal firebox (torch it, same trick as the furnace) or a live grid connection at the roof stud to move under power. Board with V - D/A drive it, P toggles a two-stop auto-route." }
R.ITEMS.WAGONKIT = { col = { 90, 60, 35 }, desc = "Cargo wagon: place on track near a locomotive to auto-couple (up to 3 per train). Left-click it while holding a material to load up to 20; it dumps its hold into any Storage Crate it stops beside." }
R.ITEMS.TRAINSTOPKIT = { col = { 200, 170, 90 }, desc = "Train stop: place on track. A locomotive with auto-route (P) on will stop here, transfer cargo, then head for the next stop. Needs at least two stops on the line." }
R.ITEMS.LIFTKIT = { col = { 60, 65, 75 }, desc = "Mine lift: place it on a VERTICAL rail shaft to drop in a powered cage plus call buttons at both ends. Needs a live grid spark at its stud to climb - lose power and it free-falls, so keep it wired." }
R.ITEMS.DRILLTRAINKIT = { col = { 60, 60, 68 }, desc = "Drill train: place it against a rock wall. Needs a lit firebox or grid power; hold D/A to bore through anything your pick tier allows, crediting every block mined, and it lays its own track behind it as it goes." }

local function need(...) local t = {}; local a = { ... }; for i2 = 1, #a, 2 do t[a[i2]] = (t[a[i2]] or 0) + a[i2 + 1] end; return t end
local BASE_RECIPES = {
  { out = "RAILKIT", n = 10, need = need("METL", 2, "WOOD", 1), st = "workbench", txt = "Rail kit (10)", desc = R.ITEMS.RAILKIT.desc },
  { out = "MINECARTKIT", n = 1, need = need("WOOD", 6, "METL", 10), st = "workbench", txt = "Minecart", desc = R.ITEMS.MINECARTKIT.desc },
  { out = "HANDCARKIT", n = 1, need = need("WOOD", 10, "METL", 4), st = "workbench", txt = "Handcar", desc = R.ITEMS.HANDCARKIT.desc },
  { out = "TRAINSTOPKIT", n = 1, need = need("WOOD", 8, "METL", 4), st = "workbench", txt = "Train stop", desc = R.ITEMS.TRAINSTOPKIT.desc },
  { out = "WAGONKIT", n = 1, need = need("STEL", 4, "METL", 6, "WOOD", 4), st = "anvil", txt = "Cargo wagon", desc = R.ITEMS.WAGONKIT.desc },
}
local GATED_RECIPES = {
  { out = "LOCOKIT", n = 1, need = need("STEL", 15, "METL", 10, "COAL", 5, "CU", 4), st = "anvil", txt = "Locomotive", desc = R.ITEMS.LOCOKIT.desc },
  { out = "LIFTKIT", n = 1, need = need("STEL", 10, "METL", 8, "CU", 4), st = "anvil", txt = "Mine lift", desc = R.ITEMS.LIFTKIT.desc },
  { out = "DRILLTRAINKIT", n = 1, need = need("STEL", 18, "METL", 10, "CU", 6), st = "anvil", txt = "Drill train", desc = R.ITEMS.DRILLTRAINKIT.desc },
}
local function alreadyIn(out) for _, rc in ipairs(R.RECIPES) do if rc.out == out then return true end end; return false end
for _, rc in ipairs(BASE_RECIPES) do if not alreadyIn(rc.out) then table.insert(R.RECIPES, rc) end end
function R.vehiclesInstallGated()
  for _, rc in ipairs(GATED_RECIPES) do if not alreadyIn(rc.out) then table.insert(R.RECIPES, rc) end end
end
if (not R.tech) or R.tech.unlock10 then R.vehiclesTechOK = true; R.vehiclesInstallGated() end

local BUILDERS = {
  MINECARTKIT = buildMinecart, HANDCARKIT = buildHandcar, LOCOKIT = buildLoco, WAGONKIT = buildWagon,
  TRAINSTOPKIT = buildStop, LIFTKIT = buildLift, DRILLTRAINKIT = buildDrillTrain,
}
hook(R.hooks.place, function(el, mx, my, fine)
  if el == "RAILKIT" then return placeRail(mx, my) end
  local b = BUILDERS[el]; if not b then return end
  if (R.frame - (R.lastPlace or -99)) < 20 then return true end
  R.lastPlace = R.frame
  R.inventory[el] = R.inv(el) - 1
  local ok, placedOk = pcall(b, mx, my)
  if not ok then R.pluginErr = tostring(placedOk)
  elseif placedOk == false then R.inventory[el] = R.inv(el) + 1 end   -- refund: no rail/shaft under the cursor
  R.rebuildHotbar()
  return true
end)

-- ================================================================ lifecycle
hook(R.hooks.newworld, function() R.vehicles = {}; R.railSegs = {}; R.trainStops = {}; R.railAnchor = nil; R.railSegRef = nil end)
hook(R.hooks.sandbox, function()
  R.inventory.RAILKIT = math.max(R.inventory.RAILKIT or 0, 999)
  R.inventory.MINECARTKIT = math.max(R.inventory.MINECARTKIT or 0, 5)
  R.inventory.LIFTKIT = math.max(R.inventory.LIFTKIT or 0, 2)
  R.vehiclesTechOK = true; R.vehiclesInstallGated(); R.rebuildHotbar()
end)
