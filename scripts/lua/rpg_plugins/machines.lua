-- machines.lua - craftable automation kits + real power grid for the Powder RPG (2026-08-26).
-- Boiler (coal + water -> real WTRV steam), turbine (steam -> SPRK), wire coil (drag-line CU/METL conductor),
-- powered lamp (LEDL/LCRY), powered door (own logic, no PSTN), water pump, conveyor (pushes powders), storage crate,
-- hand crank, water wheel, solar panel, thermoelectric generator, fission reactor, battery bank, capacitor,
-- electric furnace, ore crusher, autocrafter, defence turret, mining drill - all wired into R.power (see below).
-- Owns: R.hooks.tick/draw/drawHUD/place/mousedown/mouseup/key/keyup entries tagged "machines", R.machines,
-- R.tech, R.power, R.ITEMS.<kit names>, R.RECIPES entries tagged _plugin="machines". Does not touch any other file.
--
-- POWER GRID (R.power.grids): every 15 frames, every on-screen machine with a role (gen/load/store) is grouped
-- with every other role-machine it is physically wire-connected to (a real flood-fill across CU/METL/PSCN/NSCN/
-- STEL/TRBN/TEG pixels, same "direct contact" rule the rest of this file already uses for SPRK). Each generator's
-- wattage is read from a REAL measurement every cycle (turbine steam-hit count, TEG/reactor temperature, water
-- particle speed, day/night sun angle, held key) - nothing is a flat made-up number. Consumers only actually run
-- when their grid's generation (+battery) covers the grid's total load; batteries buffer surplus/deficit.
-- R.tech gates new recipes behind real power milestones (see checkMilestones below) - see hub post for the ladder.

local R = PBX.state.rpg
local TAG = "machines"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local W, H, M = R.W, R.H, R.M
R.machines = R.machines or {}   -- {kind, x, y, core={x,y}, ...kind-specific fields}, world coords; persists across reloads

-- ================================================================ low-level build helpers (erase-then-place; see
-- build-lessons "placeElement on an occupied pixel is a no-op" - never assume partCreate overwrites)
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function setAt(wx, wy, elName)
  killAt(wx, wy); local t = R.eid(elName); if not t then return nil end
  return sim.partCreate(-1, wx - R.cam.x, wy - R.cam.y, t)
end
local function boxFill(x1, y1, x2, y2, elName) for y = y1, y2 do for x = x1, x2 do setAt(x, y, elName) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if R.solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
-- powered = a spark sitting on/adjacent to a pad this frame (SPRK is transient, so continuous operation needs a
-- continuously-fed wire, exactly like a real lit furnace needing continuous fuel - see nearStation's furnace check)
local function poweredAt(wx, wy, r)
  r = r or 1
  for dy = -r, r do for dx = -r, r do
    local p = sim.partID(wx + dx - R.cam.x, wy + dy - R.cam.y)
    if p and R.nameOf(sim.partProperty(p, "type")) == "SPRK" then return true end
  end end
  return false
end
local function bresenham(x0, y0, x1, y1)
  local pts = {}; local dx = math.abs(x1 - x0); local sx = x0 < x1 and 1 or -1
  local dy = -math.abs(y1 - y0); local sy = y0 < y1 and 1 or -1
  local err = dx + dy; local x, y = x0, y0
  while true do
    pts[#pts + 1] = { x = x, y = y }
    if (x == x1 and y == y1) or #pts > 200 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x = x + sx end
    if e2 <= dx then err = err + dx; y = y + sy end
  end
  return pts
end
local N4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
-- shape helpers so machines read as round housings/wheels/vessels instead of plain boxes (the player 17:38: "the
-- turbine looks like just a block and that's complete ass" - every generator/consumer below is built from these).
local function ring(cx, cy, r, elName, thick)
  thick = thick or 1
  for dy = -r, r do for dx = -r, r do
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= r + 0.5 and d >= r - thick + 0.5 then setAt(cx + dx, cy + dy, elName) end
  end end
end
local function disk(cx, cy, r, elName)
  for dy = -r, r do for dx = -r, r do if dx * dx + dy * dy <= r * r + 0.5 then setAt(cx + dx, cy + dy, elName) end end end
end
local function clearDisk(cx, cy, r)
  for dy = -r, r do for dx = -r, r do if dx * dx + dy * dy <= r * r + 0.5 then killAt(cx + dx, cy + dy) end end end
end
local function nearPlayer(x, y, r) local dx, dy = x - R.P.x, y - R.P.y; return dx * dx + dy * dy <= (r or 140) * (r or 140) end

-- WMAT: whichever real conductor is available this session (custom CU if the power-elements set is loaded, else
-- stock METL - both carry PROP_CONDUCTS per build-lessons "a conductive floor or plane shorts the whole build").
-- LAMPEL: custom LEDL if loaded, else stock LCRY (a real element - crystal lamp, verified: only lights on direct
-- contact with a sparked conductor, per build-lessons "LCRY only lights on direct contact...a 1px gap leaves it dark").
local WMAT = R.has("CU") and "CU" or "METL"
local LAMPEL = R.has("LEDL") and "LEDL" or "LCRY"
-- VMAT: same fallback pattern - real reactor-grade STEL if the power-elements set is loaded, else stock METL.
-- A session/instance without STEL defined would otherwise silently build NO wall at all (setAt no-ops on an
-- undefined element) - a real bug this caught live in the lab instance (port 9877 has no custom elements
-- defined at all, unlike the main game), used for the boiler's pressure-vessel shell.
local VMAT = R.has("STEL") and "STEL" or "METL"
local function wireEl() return R.has("CU") and "CU" or "METL" end   -- re-checked at reload in case CU appears later
local function nice(n) return (R.nice and R.nice(n)) or n end   -- the player 14:26: show real-world names, never raw element ids

-- ================================================================ POWER GRID CORE (must precede any function that
-- reads it - Lua locals are resolved lexically by textual order, not call order, so this section sits before every
-- update*/draw function that references gridPowered/R.power below).
local installRecipes, checkMilestones, recomputePower, genWatts   -- forward decls, assigned further down
-- 1 real steam->water/condensate conversion ~= 3W, shared by turbine + reactor (inlined below)
local WATT_TEG_K = 1        -- 1W per Kelvin a TEG part sits above its 373.15K (100C) threshold
local WATT_CRANK = 6        -- a person cranking a real hand generator: a few watts, sustained only while held
local WATT_WHEEL_K = 5      -- W per (px/frame) of real adjacent WATR speed sampled at the paddles
local WATT_SOLAR_BASE = 16  -- rated output at local noon with open sky
local WATT_LIGHTNING = 22   -- flat, only while R.weather.rain is true and the rod sees open sky
local TICKS_PER_COAL = 900  -- ~15s of real burn time per real COAL cell in the bed (tuned live 19:58, see hub)
-- ember refresh every 6 frames: same cadence R.torches uses to keep its FIRE particle alive (inlined below)
local UNLOCK10, UNLOCK100 = 10, 100
-- SWCH added 2026-09-02 (@lead, found by @automation): a switched-on SWCH really does
-- conduct spark in the engine, but it was missing from this allowlist -- so any grid routed
-- through a switch had its wattage bookkeeping silently wrong. Verified against the engine
-- source before adding; this is the one-line fix @automation specified rather than applied,
-- since machines.lua was not its file.
local CONDUCTOR = { CU = true, METL = true, PSCN = true, NSCN = true, STEL = true, TRBN = true, TEG = true, SWCH = true }
local ROLE = {
  crank = "gen", wheel = "gen", solar = "gen", teg = "gen", turbine = "gen", reactor = "gen",
  rtg = "gen", lightning = "gen", gasturbine = "gen",
  fuelcell = "gen", wind = "gen", geotap = "gen", methanecap = "gen",
  battery = "store", capacitor = "store", flywheel = "store",
  lamp = "load", door = "load", pump = "load", efurnace = "load", crusher = "load",
  autocraft = "load", turret = "load", turret2 = "load", drill = "load",
  airpump = "load", o2gen = "load", scrubber = "load", ventfan = "load", sawmill = "load", desal = "load",
  blastfurnace = "load", elevator = "load", tunneler = "load", sprinkler = "load", breaker = "load",
  compressor = "load", lifesupport = "load",
  -- greenhouse/bellows/airline are deliberately absent: greenhouse is passive (real PLNT + daylight),
  -- bellows is hand-operated (F key, no grid), airline is a pure air network with no electrical role
}
local TERM = {
  crank = "output", wheel = "output", solar = "output", teg = "output", turbine = "output", reactor = "output",
  rtg = "output", lightning = "output", gasturbine = "output",
  fuelcell = "output", wind = "output", geotap = "output", methanecap = "output",
  battery = "pad", capacitor = "pad", flywheel = "pad", lamp = "core", door = "pad", pump = "pad", efurnace = "pad",
  crusher = "pad", autocraft = "pad", turret = "pad", turret2 = "pad", drill = "pad",
  airpump = "pad", o2gen = "pad", scrubber = "pad", ventfan = "pad", sawmill = "pad", desal = "pad",
  blastfurnace = "pad", elevator = "pad", tunneler = "pad", sprinkler = "pad", breaker = "pad",
  compressor = "pad", lifesupport = "pad",
}
local LOAD_W = { lamp = 2, door = 4, pump = 6, efurnace = 15, crusher = 20, autocraft = 15, turret = 10, turret2 = 25, drill = 18,
  airpump = 5, o2gen = 12, scrubber = 8, ventfan = 5, sawmill = 10, desal = 10, blastfurnace = 30, elevator = 6, tunneler = 14,
  sprinkler = 6, breaker = 0, compressor = 10, lifesupport = 12 }
local function machineTerminal(m) local f = TERM[m.kind]; return f and m[f] end
local function findConductorNear(wx, wy)
  local pts = { { wx, wy }, { wx + 1, wy }, { wx - 1, wy }, { wx, wy + 1 }, { wx, wy - 1 } }
  for _, p in ipairs(pts) do
    local cx, cy = p[1] - R.cam.x, p[2] - R.cam.y
    if cx >= 0 and cx < W and cy >= 0 and cy < H then
      local id = sim.partID(cx, cy)
      if id then local nm = R.nameOf(sim.partProperty(id, "type")); if CONDUCTOR[nm] then return p[1], p[2] end end
    end
  end
  return nil
end
local function gridPowered(m) if m.disabled then return false end; local g = m._gid and R.power.grids[m._gid]; return g ~= nil and g.powered end

genWatts = function(m)
  if m.kind == "crank" then
    return m.turning and WATT_CRANK or 0
  elseif m.kind == "wheel" then
    local sum, n = 0, 0
    for _, pd in ipairs(m.paddles) do
      local cx, cy = pd.x - R.cam.x, pd.y - R.cam.y
      if cx >= 0 and cx < W and cy >= 0 and cy < H then
        local id = sim.partID(cx, cy)
        if id and R.nameOf(sim.partProperty(id, "type")) == "WATR" then
          local vx, vy = sim.partProperty(id, "vx") or 0, sim.partProperty(id, "vy") or 0
          sum = sum + math.sqrt(vx * vx + vy * vy); n = n + 1
        end
      end
    end
    local avg = n > 0 and (sum / n) or 0
    m.spinSpeed = math.min(0.5, avg * 0.15)
    return avg * WATT_WHEEL_K
  elseif m.kind == "solar" then
    local cx, cy = m.panel.x1 - R.cam.x, m.panel.y1 - R.cam.y - 1
    local open = true
    if cx >= 0 and cx < W then
      for step = 1, 30 do local yy = cy - step; if yy < 0 then break end
        if sim.partID(cx, yy) then open = false; break end
      end
    end
    if not open then return 0 end
    local phase = ((R.frame or 0) % 14000) / 14000
    local day = math.max(0, -math.sin((phase - 0.5) * math.pi * 2))
    local fouling = 1 - math.min(0.8, (m.dust or 0) / 100)   -- panel fouling: real dust buildup cuts output
    return day * WATT_SOLAR_BASE * fouling
  elseif m.kind == "teg" then
    local w = 0
    for _, c in ipairs(m.cells) do
      local cx, cy = c.x - R.cam.x, c.y - R.cam.y
      if cx >= 0 and cx < W and cy >= 0 and cy < H then
        local id = sim.partID(cx, cy)
        if id then w = w + math.max(0, (sim.partProperty(id, "temp") or 0) - 373.15) * WATT_TEG_K end
      end
    end
    return w
  elseif m.kind == "turbine" then
    local h = m.hits or 0; m.hits = 0
    m.spinSpeed = math.min(0.6, h * 0.05)
    return h * 3
  elseif m.kind == "reactor" then
    local total = 0
    m.lastTmp = m.lastTmp or {}
    for i, t in ipairs(m.turb) do
      local cx, cy = t.x - R.cam.x, t.y - R.cam.y
      if cx >= 0 and cx < W and cy >= 0 and cy < H then
        local id = sim.partID(cx, cy)
        if id and R.nameOf(sim.partProperty(id, "type")) == "TRBN" then
          local tmp = sim.partProperty(id, "tmp") or 0
          local last = m.lastTmp[i] or tmp
          local d = tmp - last; if d < 0 then d = 0 end
          total = total + d; m.lastTmp[i] = tmp
        end
      end
    end
    local tegw = 0
    do local cx, cy = m.teg.x - R.cam.x, m.teg.y - R.cam.y
      if cx >= 0 and cx < W and cy >= 0 and cy < H then
        local id = sim.partID(cx, cy)
        if id then tegw = math.max(0, (sim.partProperty(id, "temp") or 0) - 373.15) * WATT_TEG_K end
      end
    end
    m.spinSpeed = math.min(0.6, total * 0.08)
    local w = total * 3 + tegw
    if w > 0 then m.online = true; m.sparkedEver = true else m.online = false end
    return w
  elseif m.kind == "rtg" then
    -- always-on: real UO2 decay/NEUT self-heat, captured by the tight B4C shell, read off the TEG cell that
    -- shell is touching - genuine radioisotope-thermoelectric physics, no day/night or grid dependency at all
    local cx, cy = m.teg.x - R.cam.x, m.teg.y - R.cam.y
    if cx >= 0 and cx < W and cy >= 0 and cy < H then
      local id = sim.partID(cx, cy)
      if id then return math.max(0, (sim.partProperty(id, "temp") or 0) - 373.15) * WATT_TEG_K end
    end
    return 0
  elseif m.kind == "lightning" then
    -- storm charger: a grounded rod builds real static charge only during an actual storm (R.weather.rain),
    -- and only with open sky above it - explicitly NOT a literal lightning-strike particle (none exists yet)
    if not (R.weather and R.weather.rain) then return 0 end
    local cx, cy = m.rodTop.x - R.cam.x, m.rodTop.y - R.cam.y - 1
    if cx < 0 or cx >= W then return 0 end
    for step = 1, 30 do local yy = cy - step; if yy < 0 then break end
      if sim.partID(cx, yy) then return 0 end
    end
    -- real strike capture: rare, spawns an actual LIGH bolt at the rod tip during a storm for a power spike -
    -- explicitly on top of the steady static trickle above, not a replacement for it
    local bonus = 0
    if R.has("LIGH") and math.random() < 0.05 then
      local lx, ly = m.rodTop.x - R.cam.x, m.rodTop.y - R.cam.y
      if not sim.partID(lx, ly) then local l = sim.partCreate(-1, lx, ly, R.eid("LIGH")); if l and l >= 0 then bonus = 40 end end
    end
    return WATT_LIGHTNING + bonus
  elseif m.kind == "gasturbine" then
    -- real combustion: burns real HYGN/OIL/GAS particles sitting in the intake, not a scripted fuel meter
    local ix, iy = m.intake.x - R.cam.x, m.intake.y - R.cam.y
    local burned = 0
    if ix >= 0 and ix < W and iy >= 0 and iy < H then
      for dx = -2, 2 do for dy = -2, 2 do
        if burned < 3 then
          local p = sim.partID(ix + dx, iy + dy)
          if p then local nm = R.nameOf(sim.partProperty(p, "type"))
            if nm == "HYGN" or nm == "OIL" or nm == "GAS" then sim.partKill(p); burned = burned + 1 end
          end
        end
      end end
    end
    return burned * 8
  elseif m.kind == "fuelcell" then
    -- combines a real HYGN + a real OXYG particle, one of each, into power and a real WATR byproduct - the
    -- reverse of the electrolyser (O2GENKIT), closing the loop the player asked for
    local hx, hy = m.hin.x - R.cam.x, m.hin.y - R.cam.y
    local ox, oy = m.oin.x - R.cam.x, m.oin.y - R.cam.y
    local hp = sim.partID(hx, hy); local op = sim.partID(ox, oy)
    if hp and op and R.nameOf(sim.partProperty(hp, "type")) == "HYGN" and R.nameOf(sim.partProperty(op, "type")) == "OXYG" then
      sim.partKill(hp); sim.partKill(op)
      local wx2, wy2 = math.floor((m.hin.x + m.oin.x) / 2) - R.cam.x, m.hin.y - R.cam.y
      if not sim.partID(wx2, wy2) then sim.partCreate(-1, wx2, wy2, R.eid("WATR")) end
      return 14
    end
    return 0
  elseif m.kind == "wind" then
    local cx, cy = m.cx - R.cam.x, m.cy - R.cam.y
    local open = cx >= 0 and cx < W
    if open then for step = 1, 20 do local yy = cy - step; if yy < 0 then break end
      if sim.partID(cx, yy) then open = false; break end
    end end
    if not open then m.spinSpeed = 0; return 0 end
    local base = 10
    local storm = (R.weather and R.weather.rain) and 14 or 0
    m.spinSpeed = math.min(0.6, (base + storm) * 0.03)
    return base + storm
  elseif m.kind == "geotap" then
    -- a bigger 3-cell TEG array, same real temperature-difference physics as TEGKIT, sized for a hell-layer
    -- lava wall instead of a single fire
    local w = 0
    for _, c in ipairs(m.cells) do
      local cx, cy = c.x - R.cam.x, c.y - R.cam.y
      if cx >= 0 and cx < W and cy >= 0 and cy < H then
        local id = sim.partID(cx, cy)
        if id then w = w + math.max(0, (sim.partProperty(id, "temp") or 0) - 373.15) * WATT_TEG_K end
      end
    end
    return w
  elseif m.kind == "methanecap" then
    -- draws down the real ambient swamp-methane concentration (R.gas.ch4, core's own gas model) near the
    -- player and burns it - only meaningful on-screen/near the player, same limitation every ambient reading has
    if math.abs(m.x - R.P.x) > 200 or math.abs(m.y - R.P.y) > 200 then return 0 end
    local ch4 = (R.gas and R.gas.ch4) or 0
    if ch4 <= 0 then return 0 end
    R.gas.ch4 = math.max(0, ch4 - 4)
    return math.min(20, ch4 * 0.4)
  end
  return 0
end

checkMilestones = function()
  local p = R.tech.peakW or 0
  if not R.tech.unlock10 and p >= UNLOCK10 then
    R.tech.unlock10 = true; installRecipes()
    R.say("TECH: " .. UNLOCK10 .. "W generated - Electric Furnace + Battery Bank unlocked")
  end
  if not R.tech.unlock100 and p >= UNLOCK100 then
    R.tech.unlock100 = true; installRecipes()
    R.say("TECH: " .. UNLOCK100 .. "W generated - Crusher, Autocrafter, Capacitor, Turret, Drill + Reactor kit unlocked")
  end
  if not R.tech.reactor then
    for _, m in ipairs(R.machines) do if m.kind == "reactor" and m.online then
      R.tech.reactor = true; installRecipes(); R.say("TECH: reactor online - Turret Mk2 unlocked"); break
    end end
  end
end

recomputePower = function()
  local visited, compOf = {}, {}
  local function keyOf(x, y) return x * 100000 + y end
  local nextId = 0
  local function flood(sx, sy)
    nextId = nextId + 1; local id = nextId; local stack = { { sx, sy } }; local n = 0
    while #stack > 0 and n < 4000 do
      local top = table.remove(stack); local x, y = top[1], top[2]; local k = keyOf(x, y)
      if not visited[k] then
        visited[k] = true
        local cx, cy = x - R.cam.x, y - R.cam.y
        if cx >= 0 and cx < W and cy >= 0 and cy < H then
          local p = sim.partID(cx, cy)
          if p then
            local nm = R.nameOf(sim.partProperty(p, "type"))
            if CONDUCTOR[nm] then
              compOf[k] = id; n = n + 1
              for _, d in ipairs(N4) do stack[#stack + 1] = { x + d[1], y + d[2] } end
            end
          end
        end
      end
    end
  end
  local term = {}
  for i, m in ipairs(R.machines) do
    if ROLE[m.kind] then
      local t = machineTerminal(m)
      if t then
        local fx, fy = findConductorNear(t.x, t.y)
        if fx then
          term[i] = { fx, fy }
          local k = keyOf(fx, fy)
          if not visited[k] then flood(fx, fy) end
        end
      end
    end
  end
  local grids = {}; local anon = 0
  for i, m in ipairs(R.machines) do
    local role = ROLE[m.kind]
    if role then
      local gid; local tw = term[i]
      if tw then gid = compOf[keyOf(tw[1], tw[2])] end
      if not gid then anon = anon - 1; gid = anon end
      m._gid = gid
      grids[gid] = grids[gid] or { id = gid, gen = 0, load = 0, cap = 0, stored = 0, members = {} }
      table.insert(grids[gid].members, m)
      if role == "gen" then
        local w = m.disabled and 0 or genWatts(m)
        m.lastWatts = w
        grids[gid].gen = grids[gid].gen + w
      elseif role == "load" then grids[gid].load = grids[gid].load + (LOAD_W[m.kind] or 4)
      elseif role == "store" then grids[gid].cap = grids[gid].cap + (m.cap or 0); grids[gid].stored = grids[gid].stored + (m.stored or 0) end
    else
      m._gid = nil
    end
  end
  local peak = 0
  for _, g in pairs(grids) do
    local net = g.gen - g.load
    if net >= 0 then
      g.powered = true
      if g.cap > 0 and net > 0 then
        local add = math.min(net, g.cap - g.stored)
        if add > 0 then
          for _, m in ipairs(g.members) do if ROLE[m.kind] == "store" and (m.cap or 0) > 0 then
            m.stored = math.min(m.cap, (m.stored or 0) + add * ((m.cap or 0) / g.cap)) end end
          g.stored = g.stored + add
        end
      end
    else
      local deficit = -net
      if g.stored >= deficit then
        g.powered = true
        for _, m in ipairs(g.members) do if ROLE[m.kind] == "store" and (m.cap or 0) > 0 then
          m.stored = math.max(0, (m.stored or 0) - deficit * ((m.cap or 0) / g.cap)) end end
        g.stored = math.max(0, g.stored - deficit)
      else
        g.powered = false
        for _, m in ipairs(g.members) do if ROLE[m.kind] == "store" then m.stored = 0 end end
        g.stored = 0
      end
    end
    if g.gen > peak then peak = g.gen end
  end
  R.power.grids = grids
  if peak > (R.tech.peakW or 0) then R.tech.peakW = peak end
  checkMilestones()
end

-- ================================================================ machine builders
local function buildBoiler(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  -- ONE continuous rectangular chamber (the player 19:58: the physics must be real, verified by reading particles
  -- back - a decorative round vessel that leaves an air gap between coal and water was the actual bug behind
  -- "the boiling mechanics don't work"; the shape below guarantees direct contact everywhere so real heat
  -- conduction and the real 373K WATR->WTRV transition do all the work, no scripting).
  -- the player 21:20 follow-up: walls were 1px thick and blew out under sustained 1100K firebox + steam pressure.
  -- Now: 2px-thick steel vessel walls on every face, 2px-thick firebrick lining around the firebox (so the
  -- heat has to conduct through real refractory before reaching the steel shell), and a thicker 2px-walled
  -- steam takeoff pipe. The chimney is widened to 3px so pressure vents up rather than sideways.
  local w2, h2 = 18, 26
  -- outer steel shell (2px thick on every face: outer ring + inner ring 1 cell in)
  boxFill(wx, gy - h2, wx + w2 - 1, gy, VMAT)
  boxFill(wx + 1, gy - h2 + 1, wx + w2 - 2, gy - 1, VMAT)
  -- hollow the inside of the second ring -> 2px-thick steel walls everywhere
  clearBox(wx + 2, gy - h2 + 2, wx + w2 - 3, gy - 2)
  -- grate + 2-row coal bed inside the brick-lined firebox. Reserve an air gap (gy-3) between
  -- the grate and the coal so the FIRE particle spawned by updateBoiler actually has a cell
  -- to live in (previously the ember sat on the coal/grate and sim.partID never returned nil,
  -- so FIRE never spawned and no real combustion happened).
  boxFill(wx + 3, gy - 2, wx + w2 - 4, gy - 2, "BRMT")
  -- gy-3 intentionally left empty (ember cell, FIRE spawns here)
  boxFill(wx + 3, gy - 5, wx + w2 - 4, gy - 4, "COAL")
  -- water chamber directly above the coal, every cell touching the row above
  boxFill(wx + 3, gy - 11, wx + w2 - 4, gy - 6, "WATR")
  -- by VMAT so it can't grow under pressure. Centered on the water chamber's middle row.
  setAt(wx + 1, gy - 9, "GLAS"); setAt(wx + 1, gy - 8, "GLAS"); setAt(wx + 1, gy - 7, "GLAS")
  -- chimney flue: 3px-wide hollow shaft from open sky straight down into the steam headspace (pour point).
  -- 2px-thick walls (matches the rest of the chamber) so pressure vents up the chimney, not sideways.
  boxFill(wx + 6, gy - h2 - 4, wx + 8, gy - h2 - 1, VMAT)
  boxFill(wx + 7, gy - h2 - 4, wx + 7, gy - h2 - 1, VMAT)   -- solid divider row keeps the shell 2px thick
  clearBox(wx + 7, gy - h2 - 3, wx + 7, gy - h2 + 1)
  -- steam takeoff pipe: 2px-thick METL shell, 2-row hollow core, exiting the right wall above the water line
  boxFill(wx + w2, gy - 14, wx + w2 + 7, gy - 9, "METL")
  boxFill(wx + w2 + 1, gy - 13, wx + w2 + 6, gy - 10, "METL")
  clearBox(wx + w2 + 1, gy - 12, wx + w2 + 6, gy - 11)
  R.machines[#R.machines + 1] = { kind = "boiler", x = wx, y = gy, core = { x = wx, y = gy },
    vent = { x = wx + w2 + 7, y = gy - 12 }, vessel = { x = wx + w2 / 2, y = gy - 8 },
    fire = { x = wx + w2 / 2, y = gy - 4 }, ember = { x = wx + w2 / 2, y = gy - 3 },
    coalBox = { x1 = wx + 3, y1 = gy - 5, x2 = wx + w2 - 4, y2 = gy - 4 },
    lit = false, fuel = 0 }

end

local function buildTurbine(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local r = 10   -- rescaled 21:20 (was 7)
  local cx, cy = wx + r + 3, gy - r - 5
  -- pedestal/shaft mount, connects the round housing down to the ground
  boxFill(cx - 2, cy + r + 1, cx + 2, gy, "STEL")
  -- round housing: a real ring with a hollow throat, a rotor hub and 4 blade nubs steam actually hits
  ring(cx, cy, r, "STEL", 2)
  clearDisk(cx, cy, r - 2)
  disk(cx, cy, 2, "METL")
  local blades = {}
  for i = 0, 3 do
    local ang = i * (math.pi / 2)
    local bx, by = cx + math.floor(math.cos(ang) * (r - 4) + 0.5), cy + math.floor(math.sin(ang) * (r - 4) + 0.5)
    setAt(bx, by, "METL"); blades[#blades + 1] = { x = bx, y = by }
  end
  -- intake nozzle (left, where the boiler's steam pipe connects) and exhaust nozzle (right)
  boxFill(cx - r - 3, cy - 1, cx - r + 1, cy + 1, "METL")
  clearBox(cx - r - 1, cy, cx - r + 1, cy)
  boxFill(cx + r - 1, cy - 1, cx + r + 3, cy + 1, "METL")
  clearBox(cx + r - 1, cy, cx + r + 1, cy)
  setAt(cx, gy, "PSCN")                                            -- output stud on the pedestal base
  R.machines[#R.machines + 1] = { kind = "turbine", x = wx, y = gy, core = { x = cx - 2, y = gy },
    cx = cx, cy = cy, r = r, blades = blades, output = { x = cx, y = gy }, hits = 0, angle = 0 }
  R.say("Turbine built - pipe steam into the left-side nozzle; the rotor spins and the base stud sparks when it does")
end

local function buildDoor(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  setAt(wx - 1, gy, "METL")                            -- frame post: stable anchor, never touched by open/close
  local blocks = {}
  for dy = 0, 5 do local y = gy - dy
    setAt(wx, y, "METL"); setAt(wx + 1, y, "METL")
    blocks[#blocks + 1] = { x = wx, y = y }; blocks[#blocks + 1] = { x = wx + 1, y = y }
  end
  setAt(wx + 3, gy, "PSCN")                            -- control pad
  R.machines[#R.machines + 1] = { kind = "door", x = wx, y = gy, core = { x = wx - 1, y = gy }, blocks = blocks, pad = { x = wx + 3, y = gy }, open = false }
  R.say("Door built - touch a live wire to the pad beside it to raise the door; it drops when the spark fades")
end

-- Worldgen object instantiation (requested by the worldgen lane). Structures are stamped per-pixel
-- from a grid and have no runtime identity, so a "door" cell in a building had nowhere to become a
-- real door. world.lua calls this ONCE per accepted placement (guarded: `if R.spawnStructMachine`),
-- so a missing/older machines.lua degrades to an inert decorative stamp rather than erroring.
--
-- It deliberately does NOT call buildDoor: that setAt()s camera-relative particles and R.say()s a
-- message, both wrong here -- worldgen runs far from the player, over terrain the grid has already
-- stamped. This creates the RECORD only.
--
-- `src` is a deterministic identity (cat:cellIdx:gx,gy) and carries the whole save/reload story.
-- The world regenerates from a seed while R.machines persists, so sRoll re-fires on every reload:
-- without the dedupe the record duplicates, and without the R.structSpent tombstone a building the
-- player demolished comes back. Both are cheap linear scans over a small list, once per placement.
R.structSpent = R.structSpent or {}   -- src -> true, for objects the player has already torn down
function R.spawnStructMachine(kind, wx, wy, src, fields)
  if kind ~= "door" then return false end            -- see the PRESSURE note below; unknown kind is not an error
  if src then
    if R.structSpent[src] then return false end
    for _, m in ipairs(R.machines) do if m.src == src then return false end end
  end
  local f = fields or {}
  -- INVARIANT: core must be a cell the grid ALWAYS fills and that open/close never moves. buildDoor
  -- uses the frame post beside the panel for exactly this reason -- if the core were a door block,
  -- opening the door would read as an empty core and the reaper would delete the machine.
  local core = f.core or { x = wx - 1, y = wy }
  local blocks = f.blocks
  if not blocks then
    blocks = {}
    for dy = 0, 5 do local y = wy - dy
      blocks[#blocks + 1] = { x = wx, y = y }; blocks[#blocks + 1] = { x = wx + 1, y = y }
    end
  end
  R.machines[#R.machines + 1] = { kind = "door", x = wx, y = wy, core = core, blocks = blocks,
    pad = f.pad or { x = wx + 3, y = wy }, open = false, src = src }
  return true
end
-- WHY WORLDGEN EMITS DOORS ONLY: syncFastMode below scans ALL of R.machines for a PRESSURE_KINDS
-- member with no distance check, so a single worldgen boiler anywhere the player had ever explored
-- would force the air simulation on globally at ~25% fps forever. recomputePower's flood fill has
-- the same unbounded-growth problem. Both need a proximity gate BEFORE any pressure-bearing or
-- powered kind becomes worldgen-eligible; until then this refuses everything else by construction.

local function buildPump(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local bx, by = wx + 8, gy - 3
  -- compact round pump body with a visible impeller hub, real pipe runs either side instead of one box
  disk(bx, by, 3, "STEL"); clearDisk(bx, by, 1); setAt(bx, by, "METL")
  setAt(bx, by - 3, "PSCN")
  boxFill(bx - 8, by - 1, bx - 3, by + 1, "METL"); clearBox(bx - 8, by, bx - 2, by); setAt(bx - 9, by + 1, "METL")
  boxFill(bx + 3, by - 1, bx + 8, by + 1, "METL"); clearBox(bx + 2, by, bx + 8, by); setAt(bx + 9, by + 1, "METL")
  R.machines[#R.machines + 1] = { kind = "pump", x = wx, y = gy, core = { x = bx, y = by },
    intake = { x = bx - 8, y = by }, outlet = { x = bx + 8, y = by }, pad = { x = bx, y = by - 3 }, cool = 0 }
  R.say("Pump built - power the pad on top; real pipes drag water from the left mouth out through the right mouth")
end

-- conveyor length 8 inlined below (200-locals budget, see DEVELOPMENT.md)
local function buildConveyor(mx, my, dir)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local cells = {}
  for i = 0, 8 - 1 do local x = wx + i; setAt(x, gy, "BMTL"); cells[#cells + 1] = { x = x, y = gy } end
  R.machines[#R.machines + 1] = { kind = "conveyor", x = wx, y = gy, core = { x = wx, y = gy }, cells = cells, dir = dir >= 0 and 1 or -1 }
  R.say("Conveyor built - loose sand/ore/coal dropped on top rides along; mine the left end block to remove it")
end

local function buildCrate(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 3, wx + 3, gy, "WOOD")
  clearBox(wx + 1, gy - 2, wx + 2, gy - 1)
  R.machines[#R.machines + 1] = { kind = "crate", x = wx, y = gy, core = { x = wx, y = gy }, items = {} }
  R.say("Storage crate built - right-click it to store or retrieve items")
end

-- ---------------- new power-tier builders ----------------
local function buildCrank(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 5, wx + 4, gy, "WOOD")
  clearBox(wx + 1, gy - 4, wx + 3, gy - 1)
  setAt(wx + 2, gy - 5, "PSCN")
  R.machines[#R.machines + 1] = { kind = "crank", x = wx, y = gy, core = { x = wx, y = gy }, output = { x = wx + 2, y = gy - 5 } }
  R.say("Hand crank built - stand next to it and hold F to turn it; a real generator needs a real hand on the shaft")
end

local function buildWheel(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local r = 9   -- rescaled 21:20 (was 6)
  local cx, cy = wx + r + 2, gy - r - 2
  boxFill(cx - 1, cy + r, cx + 1, gy, "METL")   -- axle mount frame, holds the wheel above the ground
  ring(cx, cy, r, "WOOD", 1)                    -- real spoked-looking rim (wood, distinct from the metal frame)
  disk(cx, cy, 1, "METL")                       -- axle hub
  local paddles = {}
  for i = 0, 5 do
    local ang = i * (math.pi / 3)
    paddles[#paddles + 1] = { x = cx + math.floor(math.cos(ang) * r), y = cy + math.floor(math.sin(ang) * r) }
  end
  setAt(cx, gy, "PSCN")
  R.machines[#R.machines + 1] = { kind = "wheel", x = wx, y = gy, core = { x = cx - 1, y = gy },
    cx = cx, cy = cy, r = r, output = { x = cx, y = gy }, paddles = paddles, angle = 0 }
  R.say("Water wheel built - stand it in a real current so flowing water pushes past the rim; faster flow spins it harder")
end

local function buildSolar(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx + 3, gy - 1, wx + 4, gy, "STEL")            -- mounting leg
  for i = 0, 6 do setAt(wx + i, gy - 2 - math.floor(i / 2), "PSCN") end   -- tilted backing, stepped diagonal
  for i = 0, 6 do setAt(wx + i, gy - 3 - math.floor(i / 2), "GLAS") end   -- dark tilted panel face on top of it
  setAt(wx + 6, gy - 6, "CU")
  R.machines[#R.machines + 1] = { kind = "solar", x = wx, y = gy, core = { x = wx + 3, y = gy },
    output = { x = wx + 6, y = gy - 6 }, panel = { x1 = wx + 3, y1 = gy - 5 } }
  R.say("Solar panel built - needs open sky above the tilted face; output follows the real day/night cycle")
end

local function buildTeg(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 3, wx + 3, gy, "CNCR")
  setAt(wx + 1, gy - 3, "TEG"); setAt(wx + 2, gy - 3, "TEG")
  setAt(wx + 3, gy - 1, "CU")
  R.machines[#R.machines + 1] = { kind = "teg", x = wx, y = gy, core = { x = wx, y = gy }, output = { x = wx + 3, y = gy - 1 },
    cells = { { x = wx + 1, y = gy - 3 }, { x = wx + 2, y = gy - 3 } } }
  R.say("Thermoelectric generator built - its exposed top row must touch something genuinely hot (lava, fire) to cross 100C and start pulsing power")
end

local function buildBattery(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  -- a case with an internal cell divider and two visibly different terminals (+ CU, - PSCN)
  boxFill(wx, gy - 5, wx + 7, gy, "STEL")
  clearBox(wx + 1, gy - 4, wx + 6, gy - 1)
  boxFill(wx + 3, gy - 4, wx + 3, gy - 1, "STEL")
  setAt(wx + 1, gy - 5, "CU"); setAt(wx + 6, gy - 5, "PSCN")
  R.machines[#R.machines + 1] = { kind = "battery", x = wx, y = gy, core = { x = wx, y = gy }, pad = { x = wx + 6, y = gy - 5 }, cap = 200, stored = 0 }
  R.say("Battery bank built - two terminals on top, wire the right one in; charges from surplus, discharges to cover a deficit")
end

local function buildCapacitor(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 4, wx + 2, gy, "GLAS")
  setAt(wx + 1, gy - 4, "CU")
  R.machines[#R.machines + 1] = { kind = "capacitor", x = wx, y = gy, core = { x = wx, y = gy }, pad = { x = wx + 1, y = gy - 4 }, cap = 40, stored = 0 }
  R.say("Capacitor built - small, fast-charging buffer for burst loads like the turret")
end

local function buildEFurnace(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 6, wx + 5, gy, "STEL")
  clearBox(wx + 1, gy - 5, wx + 4, gy - 1)
  setAt(wx + 2, gy - 6, "PSCN")
  R.machines[#R.machines + 1] = { kind = "efurnace", x = wx, y = gy, core = { x = wx, y = gy }, pad = { x = wx + 2, y = gy - 6 }, cool = 0 }
  R.say("Electric furnace built - power the pad; it smelts raw ore straight out of your bag, no fire needed")
end

local function buildCrusher(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  -- hopper funnel on top, two visible rollers, a frame, and an angled output chute
  boxFill(wx, gy - 9, wx + 7, gy - 6, "STEL")
  clearBox(wx + 1, gy - 8, wx + 6, gy - 6)
  setAt(wx + 6, gy - 9, "PSCN")
  disk(wx + 2, gy - 4, 2, "METL"); disk(wx + 5, gy - 4, 2, "METL")
  boxFill(wx, gy - 2, wx + 7, gy, "STEL")
  clearBox(wx + 1, gy - 2, wx + 6, gy - 2)
  boxFill(wx + 8, gy - 1, wx + 10, gy, "STEL")
  R.machines[#R.machines + 1] = { kind = "crusher", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 6, y = gy - 9 }, rollers = { { x = wx + 2, y = gy - 4 }, { x = wx + 5, y = gy - 4 } }, cool = 0 }
  R.say("Ore crusher built - power the pad on the hopper rim; two rollers crush coal into coal dust, two for one")
end

local function buildAutocraft(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 7, wx + 6, gy, "STEL")
  clearBox(wx + 1, gy - 6, wx + 5, gy - 1)
  setAt(wx + 3, gy - 7, "PSCN")
  R.machines[#R.machines + 1] = { kind = "autocraft", x = wx, y = gy, core = { x = wx, y = gy }, pad = { x = wx + 3, y = gy - 7 }, cool = 0 }
  R.say("Autocrafter built - powered, and within reach of a storage crate, it turns that crate's raw ore into bars on its own")
end

local function buildTurretKind(mx, my, kind, dmg, range)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 5, wx + 2, gy, "STEL")
  setAt(wx + 1, gy - 6, "STEL")
  setAt(wx + 1, gy - 7, "PSCN")
  R.machines[#R.machines + 1] = { kind = kind, x = wx, y = gy, core = { x = wx, y = gy }, pad = { x = wx + 1, y = gy - 7 }, cool = 0, dmg = dmg, range = range }
  R.say((kind == "turret2" and "Heavy turret" or "Defence turret") .. " built - power the pad; it fires at anything hostile within range on its own")
end
local function buildTurret(mx, my) buildTurretKind(mx, my, "turret", 8, 150) end
local function buildTurret2(mx, my) buildTurretKind(mx, my, "turret2", 20, 220) end

local function buildDrill(mx, my, dir)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local d = dir >= 0 and 1 or -1
  boxFill(wx, gy - 4, wx + 3, gy, "STEL")
  local padx = d > 0 and wx + 3 or wx
  setAt(padx, gy - 2, "PSCN")
  R.machines[#R.machines + 1] = { kind = "drill", x = wx, y = gy, core = { x = wx, y = gy }, pad = { x = padx, y = gy - 2 },
    dir = d, tx = wx + d * 4, ty = gy - 2, prog = 0, cool = 0 }
  R.say("Mining drill built - power it; it auto-mines whatever sits directly ahead of it, one hit at a time")
end

local function buildReactor(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  -- Part A: fuel lattice bay - CNCR shell, LEAD roof cap (shielding stays on the coolest, outermost surface -
  -- LEAD melts at 327C, keep it off anything hot), a UO2/B4C/ZIRC/GRPH lattice, a NAK coolant bath beneath it,
  -- and a TEG tapped through the west wall for waste-heat scavenging (idea bank's "free power" tip).
  boxFill(wx, gy - 19, wx + 9, gy, "CNCR")
  boxFill(wx, gy - 19, wx + 9, gy - 19, "LEAD")
  clearBox(wx + 1, gy - 18, wx + 8, gy - 12)
  for i = 0, 3 do
    local cx = wx + 2 + i * 2
    setAt(cx, gy - 17, "ZIRC")
    for ry = gy - 16, gy - 13 do setAt(cx, ry, "UO2") end
    setAt(cx, gy - 12, "ZIRC")
    local rx = cx + 1
    for ry = gy - 17, gy - 12 do setAt(rx, ry, "B4C") end
  end
  boxFill(wx + 2, gy - 11, wx + 8, gy - 11, "GRPH")
  boxFill(wx + 2, gy - 10, wx + 8, gy - 2, "NAK")
  setAt(wx, gy - 15, "TEG"); setAt(wx - 1, gy - 15, "CU")
  -- Part B: NAK->steam boiler bay, sharing a single STEL heat-exchange wall (wx+9) with the NAK bath - real
  -- particle-to-particle heat conduction does the actual work here, nothing scripted.
  boxFill(wx + 9, gy - 15, wx + 21, gy, "CNCR")
  boxFill(wx + 9, gy - 15, wx + 9, gy, "STEL")
  clearBox(wx + 10, gy - 14, wx + 20, gy - 2)
  boxFill(wx + 10, gy - 2, wx + 20, gy - 2, "WATR")
  clearBox(wx + 21, gy - 13, wx + 22, gy - 12)   -- steam vent, full-thickness breach (boiler-vent lesson)
  -- Part C: a small round turbine housing across the vent, same ring/hub language as the standalone turbine,
  -- but its 3 blade nubs are real TRBN elements - genuine tmp work-counter output, not hand-scripted.
  local tcx, tcy = wx + 26, gy - 12
  ring(tcx, tcy, 4, "STEL", 1); clearDisk(tcx, tcy, 2)
  clearBox(wx + 22, gy - 13, tcx - 3, gy - 11)     -- tunnel connecting the vent mouth into the turbine housing
  setAt(tcx - 3, tcy, "TRBN"); setAt(tcx, tcy - 2, "TRBN"); setAt(tcx, tcy + 2, "TRBN")
  setAt(tcx, tcy - 4, "CU")
  R.machines[#R.machines + 1] = { kind = "reactor", x = wx, y = gy, core = { x = wx, y = gy },
    output = { x = tcx, y = tcy - 4 },
    turb = { { x = tcx - 3, y = tcy }, { x = tcx, y = tcy - 2 }, { x = tcx, y = tcy + 2 } },
    tcx = tcx, tcy = tcy, angle = 0,
    teg = { x = wx, y = gy - 15 }, lastTmp = {}, online = false, sparkedEver = false }
  R.say("Reactor built - the UO2/B4C lattice heats real NAK coolant across a steel wall into steam; wire the roof stud once the turbine bank sparks")
end

-- ---------------- second wave: life support / processing / power / logistics / utility (the player 18:36) ----------------
local function buildAirpump(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local cx, cy = wx + 4, gy - 5
  ring(cx, cy, 4, "STEL", 1); clearDisk(cx, cy, 2)
  setAt(cx, cy, "METL")
  boxFill(cx + 4, cy - 1, cx + 8, cy + 1, "STEL"); clearBox(cx + 3, cy, cx + 8, cy)
  setAt(cx, cy - 5, "PSCN")
  R.machines[#R.machines + 1] = { kind = "airpump", x = wx, y = gy, core = { x = cx, y = cy - 5 },
    cx = cx, cy = cy, pad = { x = cx, y = cy - 5 }, duct = { x = cx + 3, y = cy }, angle = 0 }
  R.say("Air pump built - power it; it drives real air along the duct and registers as an oxygen source nearby")
end

local function buildO2gen(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 6, wx + 5, gy, "STEL")
  clearBox(wx + 1, gy - 5, wx + 4, gy - 2)
  boxFill(wx + 1, gy - 4, wx + 4, gy - 3, "WATR")
  clearBox(wx + 6, gy - 5, wx + 7, gy - 4)
  setAt(wx + 2, gy - 6, "PSCN")
  R.machines[#R.machines + 1] = { kind = "o2gen", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 2, y = gy - 6 }, tank = { x = wx + 2, y = gy - 3 }, outlet = { x = wx + 6, y = gy - 4 }, cool = 0 }
  R.say("Oxygen generator built - power it with a WATR charge inside; real electrolysis splits it into OXYG and HYGN at the vent")
end

-- Sealed-base life support (design-vision-2026-08-29.md's remaining unbuilt rung). Deliberately
-- reuses what already works instead of adding a parallel system: oxygen goes through the existing
-- O2_RATE/R.o2Sources path (same as the air pump), "is this actually enclosed" goes through the
-- existing cheap roomSealed multi-ray probe, and power goes through the existing grid/LOAD_W model.
-- The only genuinely new behaviour is topping up R.need.food/water while you are inside a sealed,
-- powered base -- see updateLifeSupport below.
local function buildLifeSupport(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 7, wx + 6, gy, "STEL")
  clearBox(wx + 1, gy - 6, wx + 5, gy - 2)
  boxFill(wx + 1, gy - 3, wx + 5, gy - 2, "WATR")   -- visible reservoir: reads as life support, not a blank box
  setAt(wx + 3, gy - 7, "PSCN")                      -- power pad (TERM.lifesupport = "pad")
  setAt(wx + 1, gy - 6, "LEDL"); setAt(wx + 5, gy - 6, "LEDL")
  R.machines[#R.machines + 1] = { kind = "lifesupport", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 3, y = gy - 7 }, tank = { x = wx + 3, y = gy - 3 }, sealed = false, inRange = false }
  R.say("Life support built - power it inside a SEALED room; it keeps the air up and slowly tops up food/water while you're inside")
end

local function buildScrubber(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 5, wx + 4, gy, "STEL")
  clearBox(wx + 1, gy - 4, wx + 3, gy - 1)
  for i = 0, 2 do setAt(wx + 1 + i, gy - 4, "NSCN") end
  setAt(wx + 2, gy - 5, "PSCN")
  R.machines[#R.machines + 1] = { kind = "scrubber", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 2, y = gy - 5 }, cool = 0 }
  R.say("CO2 scrubber built - power it; registers into R.scrubbers and breaks down real CO2/smoke in range")
end

local function buildVentfan(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 4, wx + 3, gy, VMAT)
  clearBox(wx + 1, gy - 3, wx + 2, gy - 1)
  setAt(wx + 1, gy - 2, "METL")
  boxFill(wx + 4, gy - 2, wx + 9, gy - 2, VMAT)
  clearBox(wx + 5, gy - 2, wx + 8, gy - 2)
  setAt(wx + 2, gy - 4, "PSCN")
  R.machines[#R.machines + 1] = { kind = "ventfan", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 2, y = gy - 4 }, hub = { x = wx + 1, y = gy - 2 }, duct = { x = wx + 7, y = gy - 2 }, angle = 0 }
  R.say("Ventilation fan built - power it to vent ambient CO/CO2 (R.scrubbers) and push heavy gases along the duct")
end

local function buildGreenhouse(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 6, wx + 6, gy, "GLAS")
  clearBox(wx + 1, gy - 5, wx + 5, gy - 1)
  boxFill(wx + 1, gy - 1, wx + 5, gy - 1, "WATR")
  setAt(wx + 2, gy - 3, "PLNT"); setAt(wx + 4, gy - 4, "PLNT")
  R.machines[#R.machines + 1] = { kind = "greenhouse", x = wx, y = gy, core = { x = wx, y = gy },
    plants = { { x = wx + 2, y = gy - 3 }, { x = wx + 4, y = gy - 4 } } }
  R.say("Greenhouse built - no power needed; real plants photosynthesise by daylight and add fresh oxygen nearby")
end

local function buildSawmill(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 6, wx + 7, gy, "WOOD")
  clearBox(wx + 1, gy - 5, wx + 6, gy - 1)
  local bcx, bcy = wx + 3, gy - 3
  ring(bcx, bcy, 2, "METL", 1)
  setAt(wx + 3, gy - 6, "PSCN")
  R.machines[#R.machines + 1] = { kind = "sawmill", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 3, y = gy - 6 }, bcx = bcx, bcy = bcy, angle = 0, cool = 0 }
  R.say("Sawmill built - power it; it pyrolyses raw wood from your bag into real charcoal")
end

local function buildDesal(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 5, wx + 7, gy, "STEL")
  clearBox(wx + 1, gy - 4, wx + 6, gy - 1)
  for dy = -3, -1 do setAt(wx + 6, gy + dy, "GLAS") end
  clearBox(wx - 1, gy - 2, wx - 1, gy - 2)
  clearBox(wx + 8, gy - 2, wx + 8, gy - 2)
  setAt(wx + 3, gy - 5, "PSCN")
  R.machines[#R.machines + 1] = { kind = "desal", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 3, y = gy - 5 }, intake = { x = wx - 1, y = gy - 2 }, outlet = { x = wx + 8, y = gy - 2 }, cool = 0 }
  R.say("Desalinator built - power it; it drags SLTW in from the left and drives real WATR + SALT out the right")
end

local function buildBlastfurnace(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 8, wx + 7, gy, "STEL")
  clearBox(wx + 1, gy - 7, wx + 6, gy - 1)
  boxFill(wx + 2, gy - 12, wx + 4, gy - 8, "STEL")
  clearBox(wx + 3, gy - 12, wx + 3, gy - 9)
  setAt(wx + 5, gy - 8, "PSCN")
  R.machines[#R.machines + 1] = { kind = "blastfurnace", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 5, y = gy - 8 }, stack = { x = wx + 3, y = gy - 11 }, cool = 0 }
  R.say("Blast furnace built - power it; hotter and faster than the electric furnace, and smelts uranium ore directly")
end

local function buildRTG(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local y = gy - 3
  boxFill(wx, gy - 4, wx + 9, gy, "LEAD")
  clearBox(wx + 1, gy - 3, wx + 8, gy - 2)
  setAt(wx + 2, y, "B4C"); setAt(wx + 3, y, "UO2"); setAt(wx + 4, y, "B4C"); setAt(wx + 5, y, "TEG")
  setAt(wx + 6, y, "CU")
  R.machines[#R.machines + 1] = { kind = "rtg", x = wx, y = gy, core = { x = wx, y = gy },
    teg = { x = wx + 5, y = y }, output = { x = wx + 6, y = y } }
  R.say("RTG built - a sealed UO2 pellet decaying inside a lead shell, always producing a small steady trickle of power")
end

local function buildFlywheel(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local cx, cy = wx + 7, gy - 8   -- re-anchored 21:20 to match the bigger ring below
  boxFill(cx - 1, cy + 7, cx + 1, gy, "STEL")
  ring(cx, cy, 7, "METL", 2); clearDisk(cx, cy, 5)   -- rescaled 21:20 (was r=5)
  disk(cx, cy, 1, "STEL")
  setAt(cx, gy, "PSCN")
  R.machines[#R.machines + 1] = { kind = "flywheel", x = wx, y = gy, core = { x = cx - 1, y = gy },
    cx = cx, cy = cy, pad = { x = cx, y = gy }, cap = 80, stored = 0, angle = 0 }
  R.say("Flywheel built - a real spinning mass; spins faster the more charge it holds, answers a burst load instantly")
end

local function buildBreaker(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 3, wx + 4, gy, "STEL")
  clearBox(wx + 1, gy - 2, wx + 3, gy - 1)
  setAt(wx, gy - 1, "PSCN"); setAt(wx + 4, gy - 1, "PSCN"); setAt(wx + 2, gy - 1, "PSCN")
  R.machines[#R.machines + 1] = { kind = "breaker", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx, y = gy - 1 }, bridge = { x = wx + 2, y = gy - 1 }, outPad = { x = wx + 4, y = gy - 1 }, tripped = false }
  R.say("Breaker built - wire through it; it snaps the connection if its grid overloads, right-click it to reset")
end

local function buildElevator(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local h = 26
  boxFill(wx, gy - h, wx + 3, gy, "METL")
  clearBox(wx + 1, gy - h + 1, wx + 2, gy - 1)
  setAt(wx + 1, gy - 1, "PSCN")
  R.machines[#R.machines + 1] = { kind = "elevator", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 1, y = gy - 1 }, top = gy - h + 1, bottom = gy - 1, colx = wx + 1 }
  R.say("Item elevator built - power it and drop loose items in the base; the shaft lifts them straight up")
end

local function buildTunneler(mx, my, dir)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  local d = dir >= 0 and 1 or -1
  boxFill(wx, gy - 4, wx + 3, gy, "STEL")
  disk(wx + 1, gy + 1, 1, "METL"); disk(wx + 2, gy + 1, 1, "METL")
  local padx = d > 0 and wx + 3 or wx
  setAt(padx, gy - 2, "PSCN")
  R.machines[#R.machines + 1] = { kind = "tunneler", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = padx, y = gy - 2 }, dir = d, tx = wx + d * 4, ty = gy - 2, prog = 0, cool = 0, travelled = 0 }
  R.say("Tunneler built - power it; it mines its way forward one hit at a time instead of sitting still")
end

local function buildSprinkler(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 3, wx + 2, gy - 2, "METL")
  setAt(wx + 1, gy - 1, "STEL")
  setAt(wx + 1, gy - 3, "PSCN")
  R.machines[#R.machines + 1] = { kind = "sprinkler", x = wx, y = gy, core = { x = wx + 1, y = gy - 1 },
    pad = { x = wx + 1, y = gy - 3 }, nozzle = { x = wx + 1, y = gy - 2 }, cool = 0 }
  R.say("Sprinkler built - power it; it sprays real water on any fire within range")
end

local function buildGasTurbine(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 6, wx + 7, gy, "STEL")
  clearBox(wx + 1, gy - 5, wx + 6, gy - 1)
  clearBox(wx - 1, gy - 3, wx - 1, gy - 3)
  setAt(wx + 7, gy - 6, "CU")
  R.machines[#R.machines + 1] = { kind = "gasturbine", x = wx, y = gy, core = { x = wx, y = gy },
    output = { x = wx + 7, y = gy - 6 }, intake = { x = wx - 1, y = gy - 3 } }
  R.say("Gas turbine built - feed real HYGN (from an oxygen generator) or OIL into the left intake; it burns real fuel for power")
end

local function buildLightning(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 3, wx + 1, gy, "STEL")
  boxFill(wx, gy - 12, wx, gy - 4, "METL")
  setAt(wx, gy - 13, "CU")
  R.machines[#R.machines + 1] = { kind = "lightning", x = wx, y = gy, core = { x = wx, y = gy },
    output = { x = wx, y = gy - 13 }, rodTop = { x = wx, y = gy - 13 } }
  R.say("Lightning rod built - a grounded rod that trickles bonus power during a real storm, if it can see open sky")
end

-- ---------------- solar/electrolysis energy tree, priority 1 (the player 21:20) ----------------
local function buildFuelCell(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 5, wx + 5, gy, VMAT)
  clearBox(wx + 1, gy - 4, wx + 4, gy - 1)
  clearBox(wx - 1, gy - 3, wx - 1, gy - 3)
  clearBox(wx + 6, gy - 3, wx + 6, gy - 3)
  setAt(wx + 2, gy - 5, "CU")
  R.machines[#R.machines + 1] = { kind = "fuelcell", x = wx, y = gy, core = { x = wx, y = gy },
    output = { x = wx + 2, y = gy - 5 }, hin = { x = wx - 1, y = gy - 3 }, oin = { x = wx + 6, y = gy - 3 } }
  R.say("Fuel cell built - feed real HYGN into the left port and OXYG into the right; it combines them into power and water")
end

local function buildWind(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 14, wx + 1, gy, "METL")
  local cx, cy = wx, gy - 15
  for i = 0, 2 do local a = i * (math.pi * 2 / 3)
    setAt(cx + math.floor(math.cos(a) * 3 + 0.5), cy + math.floor(math.sin(a) * 3 + 0.5), "BMTL") end
  setAt(wx, gy, "PSCN")
  R.machines[#R.machines + 1] = { kind = "wind", x = wx, y = gy, core = { x = wx, y = gy },
    cx = cx, cy = cy, output = { x = wx, y = gy }, angle = 0 }
  R.say("Wind turbine built - needs open sky on the surface; spins harder during a real storm")
end

local function buildSolarFurnace(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 4, wx + 5, gy, VMAT)
  clearBox(wx + 1, gy - 3, wx + 4, gy - 1)
  for i = 0, 5 do setAt(wx + i, gy - 5, "GLAS") end
  R.machines[#R.machines + 1] = { kind = "solarfurnace", x = wx, y = gy, core = { x = wx, y = gy }, cool = 0 }
  R.say("Solar furnace built - no power needed; a concentrator lens focuses real daylight to smelt ore inside")
end

local function buildFlare(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 10, wx + 1, gy, VMAT)
  clearBox(wx, gy - 9, wx, gy - 1)
  R.machines[#R.machines + 1] = { kind = "flare", x = wx, y = gy, core = { x = wx, y = gy }, tip = { x = wx, y = gy - 10 } }
  R.say("Flare stack built - no power needed; safely burns off real HYGN/gas near its base and vents ambient methane nearby")
end

local function buildGeotap(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 6, wx + 7, gy, "CNCR")
  clearBox(wx + 1, gy - 5, wx + 6, gy - 1)
  setAt(wx + 1, gy - 3, "TEG"); setAt(wx + 3, gy - 3, "TEG"); setAt(wx + 5, gy - 3, "TEG")
  setAt(wx + 7, gy - 3, "CU")
  R.machines[#R.machines + 1] = { kind = "geotap", x = wx, y = gy, core = { x = wx, y = gy },
    output = { x = wx + 7, y = gy - 3 },
    cells = { { x = wx + 1, y = gy - 3 }, { x = wx + 3, y = gy - 3 }, { x = wx + 5, y = gy - 3 } } }
  R.say("Geothermal tap built - press its exposed face against real lava/hot rock in the deep zone; three TEG cells scavenge the heat")
end

local function buildMethaneCap(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 5, wx + 5, gy, VMAT)
  clearBox(wx + 1, gy - 4, wx + 4, gy - 1)
  setAt(wx + 2, gy - 5, "CU")
  R.machines[#R.machines + 1] = { kind = "methanecap", x = wx, y = gy, core = { x = wx, y = gy }, output = { x = wx + 2, y = gy - 5 } }
  R.say("Methane capture built - draws down real ambient swamp methane nearby and burns it for power")
end

-- ---------------- gas detector + lead shielding, priority 2 (the player 21:20, roadmap-nudged x3) ----------------
local function buildGasDetector(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 3, wx + 2, gy, "STEL")
  setAt(wx + 1, gy - 3, "LEDL")
  R.machines[#R.machines + 1] = { kind = "gasdetector", x = wx, y = gy, core = { x = wx, y = gy }, warn = false }
  R.say("Gas detector built - no power needed; it watches real ambient methane/CO2/smoke near it and warns you")
end

local function buildLeadShield(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 5, wx + 1, gy, "LEAD")
  R.machines[#R.machines + 1] = { kind = "leadshield", x = wx, y = gy, core = { x = wx, y = gy } }
  R.say("Lead shielding panel placed - real 35 W/mK lead, blocks radiation exposure from the far side")
end

-- ================================================================ wire coil: drags a continuous conductor line
local function placeWire(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local pts
  if R.wireLast and math.abs(R.wireLast.x - wx) + math.abs(R.wireLast.y - wy) < 40 then
    pts = bresenham(R.wireLast.x, R.wireLast.y, wx, wy)
  else
    pts = { { x = wx, y = wy } }
  end
  local el = wireEl(); local t = R.eid(el)
  if t then
    for _, p in ipairs(pts) do
      if R.inv("WIRECOIL") <= 0 then break end
      local cx, cy = p.x - R.cam.x, p.y - R.cam.y
      if not sim.partID(cx, cy) then
        local n = sim.partCreate(-1, cx, cy, t)
        if n and n >= 0 then R.inventory.WIRECOIL = R.inv("WIRECOIL") - 1 end
      end
    end
  end
  R.wireLast = { x = wx, y = wy }
  R.rebuildHotbar()
  return true
end

-- ---------------- oxygen chain, round 2 (the player 20:38): bellows/hand pump, air line duct, compressor+tanks ----------------
local function buildBellows(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 4, wx + 4, gy, "WOOD")
  clearBox(wx + 1, gy - 3, wx + 3, gy - 1)
  boxFill(wx + 5, gy - 2, wx + 8, gy - 1, "WOOD")
  clearBox(wx + 5, gy - 2, wx + 8, gy - 2)
  R.machines[#R.machines + 1] = { kind = "bellows", x = wx, y = gy, core = { x = wx, y = gy },
    duct = { x = wx + 8, y = gy - 2 }, angle = 0 }
  R.say("Bellows built - stand next to it and hold F to hand-pump; refills your air bladder fast and pushes real air down the short duct")
end

local function placeAirline(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local pts
  if R.airlineLast and math.abs(R.airlineLast.x - wx) + math.abs(R.airlineLast.y - wy) < 40 then
    pts = bresenham(R.airlineLast.x, R.airlineLast.y, wx, wy)
  else
    pts = { { x = wx, y = wy } }
  end
  local t = R.eid("BMTL")
  if t then
    if not R.airlineCur then
      R.airlineCur = { kind = "airline", x = wx, y = wy, core = { x = wx, y = wy }, segs = {}, intact = 0 }
      R.machines[#R.machines + 1] = R.airlineCur
    end
    for _, p in ipairs(pts) do
      if R.inv("AIRLINEKIT") <= 0 then break end
      local cx, cy = p.x - R.cam.x, p.y - R.cam.y
      if not sim.partID(cx, cy) then
        local n = sim.partCreate(-1, cx, cy, t)
        if n and n >= 0 then R.inventory.AIRLINEKIT = R.inv("AIRLINEKIT") - 1; R.airlineCur.segs[#R.airlineCur.segs + 1] = { x = p.x, y = p.y } end
      end
    end
    R.airlineCur.core = { x = R.airlineCur.segs[1] and R.airlineCur.segs[1].x or wx, y = R.airlineCur.segs[1] and R.airlineCur.segs[1].y or wy }
  end
  R.airlineLast = { x = wx, y = wy }
  R.rebuildHotbar()
  return true
end

local function buildCompressor(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = groundY(wx, wy)
  boxFill(wx, gy - 7, wx + 5, gy, "STEL")
  clearBox(wx + 1, gy - 6, wx + 4, gy - 1)
  disk(wx + 2, gy - 3, 2, "METL")
  clearBox(wx - 1, gy - 3, wx - 1, gy - 3)   -- real air intake, breach of the left wall
  setAt(wx + 2, gy - 7, "PSCN")
  R.machines[#R.machines + 1] = { kind = "compressor", x = wx, y = gy, core = { x = wx, y = gy },
    pad = { x = wx + 2, y = gy - 7 }, intake = { x = wx - 1, y = gy - 3 }, cool = 0 }
  R.say("Compressor built - power it and stand close with a bladder or Oxygen Tank equipped; it compresses real nearby OXYG into them")
end

-- ================================================================ place dispatch
local BUILDERS = {
  BOILERKIT = buildBoiler,
  -- BOILER/TURBINE aliases: BASE_RECIPES emits "BOILER"/"TURBINE" and saved hotbars store those bare names, so the
  -- dispatch must match both. The KIT keys are kept for any code path/save that still emits the suffixed name.
  BOILER = buildBoiler,
  TURBINEKIT = buildTurbine,
  TURBINE = buildTurbine,
  DOORKIT = buildDoor,
  PUMPKIT = buildPump,
  CRATE = buildCrate,
  CONVEYOR = function(mx, my) buildConveyor(mx, my, R.P.face) end,
  LAMPKIT = function(mx, my)
    local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
    setAt(wx, gy - 1, LAMPEL)
    R.machines[#R.machines + 1] = { kind = "lamp", x = wx, y = gy - 1, core = { x = wx, y = gy - 1 } }
    R.say(nice(LAMPEL) .. " placed - touch a sparked " .. nice(wireEl()) .. " wire directly to it, no gap; needs a live grid too (2W)")
  end,
  CRANKKIT = buildCrank,
  WHEELKIT = buildWheel,
  SOLARKIT = buildSolar,
  TEGKIT = buildTeg,
  BATTERYKIT = buildBattery,
  CAPACITORKIT = buildCapacitor,
  EFURNACE = buildEFurnace,
  CRUSHERKIT = buildCrusher,
  AUTOCRAFTKIT = buildAutocraft,
  TURRETKIT = buildTurret,
  TURRETKIT2 = buildTurret2,
  DRILLKIT = function(mx, my) buildDrill(mx, my, R.P.face) end,
  REACTORKIT = buildReactor,
  AIRPUMPKIT = buildAirpump,
  O2GENKIT = buildO2gen,
  SCRUBBERKIT = buildScrubber,
  LIFESUPPORTKIT = buildLifeSupport,
  VENTFANKIT = buildVentfan,
  GREENHOUSEKIT = buildGreenhouse,
  SAWMILLKIT = buildSawmill,
  DESALKIT = buildDesal,
  BLASTFURNACEKIT = buildBlastfurnace,
  RTGKIT = buildRTG,
  FLYWHEELKIT = buildFlywheel,
  BREAKERKIT = buildBreaker,
  ELEVATORKIT = buildElevator,
  TUNNELERKIT = function(mx, my) buildTunneler(mx, my, R.P.face) end,
  SPRINKLERKIT = buildSprinkler,
  LIGHTNINGKIT = buildLightning,
  GASTURBINEKIT = buildGasTurbine,
  BELLOWSKIT = buildBellows,
  COMPRESSORKIT = buildCompressor,
  FUELCELLKIT = buildFuelCell,
  WINDKIT = buildWind,
  SOLARFURNACEKIT = buildSolarFurnace,
  FLAREKIT = buildFlare,
  GEOTAPKIT = buildGeotap,
  METHANECAPKIT = buildMethaneCap,
  GASDETECTORKIT = buildGasDetector,
  LEADSHIELDKIT = buildLeadShield,
}
hook(R.hooks.place, function(el, mx, my, fine)
  if el == "WIRECOIL" then return placeWire(mx, my) end
  if el == "AIRLINEKIT" then return placeAirline(mx, my) end
  local b = BUILDERS[el]; if not b then return end
  if (R.frame - (R.lastPlace or -99)) < 20 then return true end
  R.lastPlace = R.frame
  R.inventory[el] = R.inv(el) - 1
  local ok, err = pcall(b, mx, my); if not ok then R.pluginErr = tostring(err) end
  R.rebuildHotbar()
  return true
end)
hook(R.hooks.mouseup, function(x, y, button) if button == 3 then R.wireLast = nil; R.airlineCur = nil end end)

-- ================================================================ hand-crank interact key (F, held, near the crank)
local heldF = false
hook(R.hooks.key, function(k) if k == "f" then heldF = true end end)
hook(R.hooks.keyup, function(k) if k == "f" then heldF = false end end)

-- ================================================================ crate right-click panel
-- ================================================================ interaction: proximity prompt + right-click panel
-- the player 19:34/19:37/19:38: machines must read as interactive - an outline+"[right-click] Name" prompt within
-- ~30px, and right-click opens a real panel (state, live inputs/outputs, a NEXT ACTION line, and buttons).
-- MBOX[kind] = {dx, dy, r}: offset from m.x,m.y to the structure's visual centre + an interaction radius,
-- used for both the hover/proximity test and the right-click hit-test (approximate, generous on purpose).
local MBOX = {
  boiler = { 6, -9, 13 }, turbine = "ring", door = { 1, -3, 6 }, pump = { 8, -3, 10 }, conveyor = { 4, 0, 6 },
  crate = { 2, -1, 5 }, lamp = { 0, 0, 3 }, crank = { 2, -3, 6 }, wheel = "ring", solar = { 4, -3, 7 },
  teg = { 2, -2, 5 }, battery = { 4, -3, 7 }, capacitor = { 1, -2, 4 }, efurnace = { 3, -3, 6 },
  crusher = { 5, -5, 9 }, autocraft = { 3, -4, 7 }, turret = { 1, -4, 6 }, turret2 = { 1, -4, 6 },
  drill = { 2, -2, 5 }, reactor = { 16, -10, 20 }, airpump = { 4, -5, 9 }, o2gen = { 3, -3, 6 },
  scrubber = { 2, -3, 5 }, ventfan = { 4, -2, 6 }, greenhouse = { 3, -3, 6 }, sawmill = { 3, -3, 7 }, desal = { 3, -3, 8 },
  blastfurnace = { 3, -6, 9 }, rtg = { 4, -3, 8 }, flywheel = "ring", breaker = { 2, -1, 5 },
  elevator = { 1, -13, 14 }, tunneler = { 2, -2, 5 }, sprinkler = { 1, -2, 4 }, lightning = { 0, -6, 8 },
  gasturbine = { 3, -3, 8 }, bellows = { 2, -3, 7 }, compressor = { 2, -4, 7 },
  fuelcell = { 2, -3, 6 }, wind = { 0, -8, 10 }, solarfurnace = { 2, -3, 7 }, flare = { 0, -5, 8 },
  geotap = { 3, -3, 9 }, methanecap = { 2, -3, 6 }, gasdetector = { 1, -3, 5 }, leadshield = { 0, -3, 4 },
  -- airline has no fixed MBOX radius (it's a laid line, not a point) - handled specially in machineAt/draw
}
local function machineCentre(m)
  local b = MBOX[m.kind]
  if b == "ring" then return m.cx, m.cy, (m.r or 6) + 6 end
  if b then return m.x + b[1], m.y + b[2], b[3] end
  return m.x, m.y - 3, 8
end
local function machineAt(wx, wy)
  local best, bestD
  for _, m in ipairs(R.machines) do
    if MBOX[m.kind] then
      local cx, cy, r = machineCentre(m)
      local d = (wx - cx) * (wx - cx) + (wy - cy) * (wy - cy)
      if d <= r * r and (not bestD or d < bestD) then bestD = d; best = m end
    end
  end
  return best
end
local IDLE_HINT = {
  crank = "Hold F beside it to turn the crank", wheel = "Place it in real flowing water",
  solar = "Needs open sky and daylight", teg = "Needs its exposed face touching something hot (lava/fire)",
  reactor = "Needs the internal lattice hot enough to boil its water", rtg = "Should read >0 once built and intact",
  lightning = "Only generates during a real storm with open sky",
  gasturbine = "Feed real HYGN/OIL/GAS into the left intake",
  fuelcell = "Feed real HYGN into the left port and OXYG into the right",
  wind = "Needs open sky - spins harder in a real storm", geotap = "Needs its face touching real lava/hot rock",
  methanecap = "Only draws down real ambient methane (R.gas.ch4) near you",
}
local LOAD_DESC = {
  lamp = "Lights up", door = "Opens the passage", pump = "Moves water intake -> outlet",
  efurnace = "Smelts ore from your bag", crusher = "Crushes 1 coal into 2 coal dust",
  autocraft = "Turns a nearby crate's ore into bars", turret = "Fires at hostiles in range",
  turret2 = "Fires at hostiles in range (heavy)", drill = "Auto-mines the block ahead of it",
  airpump = "Freshens the air, feeds the real O2 model", o2gen = "Splits a water charge into O2 + H2",
  scrubber = "Breaks down real CO2/smoke; registers R.scrubbers", ventfan = "Vents CO/CO2 (R.scrubbers) and pushes heavy gas along duct",
  sawmill = "Turns wood into charcoal",
  desal = "Turns salt water into fresh water + salt", blastfurnace = "Smelts ore, handles uranium directly",
  elevator = "Lifts loose material up the shaft", tunneler = "Mines forward one hit at a time",
  sprinkler = "Sprays real water on nearby fire", breaker = "Protects its grid from overload",
  lifesupport = "Keeps a sealed base breathable and stocked while you are inside it",
}
-- same vertical-probe "is there open sky above" check core's own O2 model uses (rpg.lua's breathability calc) -
-- reused here so a life-support machine's panel can tell the player whether the room it is in even needs it
local function roomSealed(wx, wy)
  local blocked = 0
  for k = 4, 90, 3 do if R.solidW(wx, wy - k) then blocked = blocked + 1 end end
  return blocked > 1
end
-- inspect(m): read-only - must never mutate sim state or consume anything, this can run every frame on hover
local function realCoalCount(m)
  local n = 0
  for x = m.coalBox.x1, m.coalBox.x2 do for y = m.coalBox.y1, m.coalBox.y2 do
    local p = sim.partID(x - R.cam.x, y - R.cam.y)
    if p and R.nameOf(sim.partProperty(p, "type")) == "COAL" then n = n + 1 end
  end end
  return n
end
local O2_RATE = { airpump = 10, o2gen = 18, greenhouse = 12, bellows = 8, lifesupport = 14 }
-- Declared HERE, above inspect(), on purpose: inspect() reads it and is defined earlier in this
-- file than updateLifeSupport(). Declaring it only at the update site would leave the inspect
-- reference resolving to a nil GLOBAL -- the exact drawMenu/wrap/give forward-reference bug class
-- that has produced per-frame error spam in this project three times already.
local LIFESUPPORT_RANGE = 90
local AIRLINE_SEG_RATE, AIRLINE_SEG_RANGE, AIRLINE_SEG_STEP = 4, 40, 6
local function inspect(m)
  local role = ROLE[m.kind]
  local state, inputs, outputs, nextline = "IDLE", {}, {}, "No action needed"
  if m.kind == "boiler" then
    -- everything here is a real measurement (particle scan), never the m.lit/m.fuel intent flags alone -
    -- the player 19:58: "verified by reading particles back, not by drawn overlays"
    local hotFire = false
    do local p = sim.partID(m.ember.x - R.cam.x, m.ember.y - R.cam.y)
      if p and R.nameOf(sim.partProperty(p, "type")) == "FIRE" then hotFire = true end end
    local hasWater, hasSteam, maxTemp = false, false, 0
    for dx = -6, 6 do for dy = -10, 2 do
      local p = sim.partID(m.vessel.x + dx - R.cam.x, m.vessel.y + dy - R.cam.y)
      if p then local nm = R.nameOf(sim.partProperty(p, "type")); local t = sim.partProperty(p, "temp") or 0
        if nm == "WATR" then hasWater = true elseif nm == "WTRV" then hasSteam = true end
        if t > maxTemp then maxTemp = t end
      end
    end end
    local coalN = realCoalCount(m)
    inputs[1] = "Coal bed: " .. coalN .. " real cell" .. (coalN == 1 and "" or "s") .. (m.lit and (", burning (" .. math.floor((m.fuel or 0) / 60) .. "s left)") or ", unlit")
    inputs[2] = string.format("Chamber: %s%s, %dK", hasWater and "water" or "empty", hasSteam and "+real steam" or "", math.floor(maxTemp))
    outputs[1] = hasSteam and "Real WTRV present - venting to the takeoff pipe" or "No steam yet"
    if hasSteam then state = "RUNNING"; nextline = "Working - pipe the steam to a turbine if you haven't"
    elseif m.lit and hasWater then state = "HEATING"; nextline = "Water is heating (" .. math.floor(maxTemp) .. "K, needs 373K) - give it a moment"
    elseif not hasWater then state = "NO WATER"; nextline = "Fill it with the button below, or pour water down the chimney flue yourself"
    elseif coalN == 0 then state = "NO FUEL"; nextline = "No real coal left in the bed - rebuild or restock it"
    else state = "UNLIT"; nextline = "Light the coal bed with the button below" end
  elseif m.kind == "turbine" or (m.kind == "reactor") then
    local hits = m.kind == "turbine" and (m.hits or 0) or nil
    outputs[1] = "Power: " .. math.floor(m.lastWatts or 0) .. "W"
    if (m.lastWatts or 0) > 0 then state = "RUNNING"; nextline = "Working - wire the output stud to what needs power"
    else state = "IDLE"; nextline = m.kind == "turbine" and "Pipe real steam (WTRV) into the left-side nozzle" or IDLE_HINT.reactor end
    if hits then inputs[1] = "Steam hits this cycle: " .. hits end
  elseif role == "gen" then
    local w = m.lastWatts or 0
    outputs[1] = "Power: " .. math.floor(w) .. "W"
    if m.disabled then state = "STOPPED"; nextline = "Press Start to resume"
    elseif w > 0 then state = "RUNNING"; nextline = "Working - wire the output stud to what needs power"
    else state = "IDLE"; nextline = IDLE_HINT[m.kind] or "Check its real input condition (see description)" end
  elseif m.kind == "lifesupport" then
    -- Every failing condition gets its own named line and a single concrete NEXT ACTION, because
    -- this machine has three independent requirements (power / sealed / you inside) and "it isn't
    -- working" with no reason shown is exactly the complaint that drove the whole inspect panel.
    -- roomSealed is recomputed live here rather than read from the 90-frame cache so the panel is
    -- never up to ~2.5s stale while you are standing there wondering why it is idle. Read-only.
    local g = m._gid and R.power.grids[m._gid]
    local need = LOAD_W.lifesupport or 12
    local sealed = roomSealed(m.x, m.y) and roomSealed(m.x - 6, m.y) and roomSealed(m.x + 6, m.y)
    local px, py = (R.P and R.P.x or 0), (R.P and R.P.y or 0)
    local dxp, dyp = px - m.x, py - m.y
    local dist = math.floor(math.sqrt(dxp * dxp + dyp * dyp))
    local inRange = dist <= LIFESUPPORT_RANGE
    inputs[1] = "Power: " .. (g and math.floor(g.gen) or 0) .. "W avail / " .. need .. "W needed"
    inputs[2] = "Room: " .. (sealed and "SEALED - good" or "NOT sealed - roof it over")
    inputs[3] = "You: " .. dist .. "px away (" .. (inRange and "inside range" or "outside " .. LIFESUPPORT_RANGE .. "px range") .. ")"
    outputs[1] = "Oxygen: feeds the real O2 model (~" .. (O2_RATE.lifesupport or 14) .. " O2/s while powered)"
    outputs[2] = string.format("Stores: food %d%% / water %d%% (+0.9 / +1.2 per 90 frames while running)",
      math.floor((R.need and R.need.food) or 0), math.floor((R.need and R.need.water) or 0))
    if m.disabled then state = "STOPPED"; nextline = "Press Start to resume"
    elseif not m._gid then state = "BLOCKED"; nextline = "Wire it to a generator with copper/iron wire"
    elseif not gridPowered(m) then state = "STARVED"; nextline = "Needs more generation or a battery on its grid (" .. need .. "W)"
    elseif not sealed then state = "OPEN ROOM"; nextline = "Roof the room over - it only stocks a genuinely sealed base"
    elseif not inRange then state = "STANDBY"; nextline = "Working, but you're " .. dist .. "px away - stay within " .. LIFESUPPORT_RANGE .. "px to draw from it"
    else state = "RUNNING"; nextline = "Working - no action needed" end
  elseif m.kind == "airpump" or m.kind == "o2gen" or m.kind == "scrubber" or m.kind == "ventfan" or m.kind == "compressor" then
    local g = m._gid and R.power.grids[m._gid]
    local need = LOAD_W[m.kind] or 4
    inputs[1] = "Power: " .. (g and math.floor(g.gen) or 0) .. "W avail / " .. need .. "W needed"
    inputs[2] = "Room: " .. (roomSealed(m.x, m.y) and "sealed - needs a real source" or "open to sky - already fine")
    local rate = O2_RATE[m.kind]
    local scrubReg = ({ scrubber = { 28, 70 }, ventfan = { 18, 90 } })[m.kind]
    if scrubReg then outputs[1] = LOAD_DESC[m.kind] .. " (~" .. scrubReg[1] .. " scrub/s, " .. scrubReg[2] .. "px)"
    else outputs[1] = rate and (LOAD_DESC[m.kind] .. " (~" .. rate .. " O2/s while running)") or LOAD_DESC[m.kind] end
    if m.disabled then state = "STOPPED"; nextline = "Press Start to resume"
    elseif gridPowered(m) then state = "RUNNING"; nextline = "Working - no action needed"
    elseif not m._gid then state = "BLOCKED"; nextline = "Wire it to a generator with copper/iron wire"
    else state = "STARVED"; nextline = "Needs more generation or a battery on its grid" end
  elseif m.kind == "bellows" then
    inputs[1] = "Air bladders owned: " .. (R.inventory.FLASK or 0)
    outputs[1] = "Refills your bladder ~6/frame while pumped, pushes air down the duct"
    if m.pumping then state = "PUMPING"; nextline = "Working - keep holding F"
    else state = "IDLE"; nextline = (R.inventory.FLASK or 0) > 0 and "Stand next to it and hold F to pump" or "Craft an air bladder (FLASK) first" end
  elseif m.kind == "airline" then
    inputs[1] = string.format("Duct: %d/%d segments intact", m.intact or 0, #m.segs)
    outputs[1] = string.format("Feeds real air roughly every %dpx along the intact run", AIRLINE_SEG_STEP)
    if (m.intact or 0) >= #m.segs then state = "INTACT"; nextline = "Working - no action needed"
    elseif (m.intact or 0) > 0 then state = "PARTIAL"; nextline = "Cut at segment " .. (m.intact + 1) .. " - relay a new pipe from there"
    else state = "CUT"; nextline = "The very first segment is gone - relay from the source" end
  elseif role == "load" then
    local g = m._gid and R.power.grids[m._gid]
    local need = LOAD_W[m.kind] or 4
    inputs[1] = "Power: " .. (g and math.floor(g.gen) or 0) .. "W avail / " .. need .. "W needed"
    outputs[1] = LOAD_DESC[m.kind] or "Working while powered"
    if m.disabled then state = "STOPPED"; nextline = "Press Start to resume"
    elseif gridPowered(m) then state = "RUNNING"; nextline = "Working - no action needed"
    elseif not m._gid then state = "BLOCKED"; nextline = "Wire it to a generator with copper/iron wire"
    else state = "STARVED"; nextline = "Needs more generation or a battery on its grid" end
  elseif role == "store" then
    inputs[1] = "Charge: " .. math.floor(m.stored or 0) .. " / " .. (m.cap or 0)
    state = (m.stored or 0) > 0 and "HOLDING CHARGE" or "EMPTY"
  end
  if m.kind == "breaker" and m.tripped then state = "TRIPPED"; nextline = "Right-click, or press Reset below" end
  return state, inputs, outputs, nextline
end
local PANEL_BUTTONS = {
  boiler = { "light", "fillwater" }, breaker = { "reset" }, solar = { "clean" },
}
local function panelButtonLabel(m, id)
  if id == "light" then return m.lit and "Refuel" or "Light firebox" end
  if id == "fillwater" then return "Fill water" end
  if id == "reset" then return "Reset" end
  if id == "clean" then return "Clean panel" end
  if id == "toggle" then return m.disabled and "Start" or "Stop" end
end
local function panelButtonEnabled(m, id)
  if id == "light" then local n = realCoalCount(m); return n > 0, "No real coal left in the bed - rebuild or restock it" end
  if id == "fillwater" then return (R.hotbar and R.hotbar[R.sel or 1]) == "tool:bucket", "Equip the bucket (slot 5) first" end
  if id == "reset" then return m.tripped == true, "Not tripped" end
  if id == "clean" then return (m.dust or 0) > 0, "Already clean" end
  return true
end
local function pressPanelButton(m, id)
  if id == "toggle" then m.disabled = not m.disabled; R.say(m.disabled and "Stopped" or "Started")
  elseif id == "light" then
    -- real, sustained ignition: counts the actual COAL particles present and burns for TICKS_PER_COAL of
    -- real time per cell (see updateBoiler) - not a one-off temperature bump, which cools straight back down
    local n = realCoalCount(m)
    m.lit = true; m.fuel = n * TICKS_PER_COAL
    R.say("Lit the coal bed - " .. n .. " real coal cells, should burn for roughly " .. math.floor(m.fuel / 60) .. "s")
  elseif id == "fillwater" then
    if not sim.partID(m.vessel.x - R.cam.x, m.vessel.y - R.cam.y) then
      sim.partCreate(-1, m.vessel.x - R.cam.x, m.vessel.y - R.cam.y, R.eid("WATR"))
    end
    for dx = -2, 2 do for dy = 2, 4 do
      if not sim.partID(m.vessel.x + dx - R.cam.x, m.vessel.y + dy - R.cam.y) then
        sim.partCreate(-1, m.vessel.x + dx - R.cam.x, m.vessel.y + dy - R.cam.y, R.eid("WATR"))
      end
    end end
    R.say("Filled with water")
  elseif id == "reset" then
    setAt(m.bridge.x, m.bridge.y, "PSCN"); m.tripped = false; R.say("Breaker reset")
  elseif id == "clean" then
    m.dust = 0; R.say("Panel wiped clean")
  end
end
local PX, PY, PW, PH = 190, 40, 236, 176
local CX, CY, CW, CH = 190, 56, 236, 160
local function crateRows(tbl) local n = {}; for k, v in pairs(tbl) do if v > 0 then n[#n + 1] = k end end; table.sort(n); return n end
local function handleCratePanelClick(x, y)
  local m = R.cratePanel; if not m then return end
  local rowH = 14; local top = CY + 42
  if y < top then return end
  local row = math.floor((y - top) / rowH) + 1
  if x >= CX + 8 and x < CX + 110 then
    local nm = crateRows(m.items)[row]
    if nm then m.items[nm] = m.items[nm] - 1; if m.items[nm] <= 0 then m.items[nm] = nil end; R.give(nm, 1); R.rebuildHotbar(); R.say("took 1 " .. nice(nm)) end
  elseif x >= CX + 124 and x < CX + CW - 6 then
    local nm = crateRows(R.inventory)[row]
    if nm and R.inv(nm) > 0 then R.inventory[nm] = R.inv(nm) - 1; m.items[nm] = (m.items[nm] or 0) + 1; R.say("stored 1 " .. nice(nm)) end
  end
end
local function panelButtons(m)
  local ids = {}
  local role = ROLE[m.kind]
  if role == "gen" or role == "load" then ids[#ids + 1] = "toggle" end
  for _, id in ipairs(PANEL_BUTTONS[m.kind] or {}) do ids[#ids + 1] = id end
  return ids
end
local function panelButtonRects(m)
  local rects = {}; local bw, bh, gap = 104, 18, 8
  local bx, by = PX + 10, PY + PH - 26
  for i, id in ipairs(panelButtons(m)) do
    local col = (i - 1) % 2; local row = math.floor((i - 1) / 2)
    rects[#rects + 1] = { id = id, x1 = bx + col * (bw + gap), y1 = by - row * (bh + 4),
      x2 = bx + col * (bw + gap) + bw, y2 = by - row * (bh + 4) + bh }
  end
  return rects
end
hook(R.hooks.mousedown, function(x, y, button)
  if R.cratePanel then
    if button == 1 then handleCratePanelClick(x, y); return true end
    if button == 3 then R.cratePanel = nil; return true end
  end
  if R.machinePanel then
    local m = R.machinePanel
    if button == 1 then
      for _, r in ipairs(panelButtonRects(m)) do
        if x >= r.x1 and x < r.x2 and y >= r.y1 and y < r.y2 then
          local ok, reason = panelButtonEnabled(m, r.id)
          if ok then pressPanelButton(m, r.id) else R.say(reason or "Can't do that yet") end
          return true
        end
      end
      return true
    end
    if button == 3 then R.machinePanel = nil; R.uiPanelOpen = false; return true end
  end
  if button == 3 and not R.invOpen and not R.menuOpen then
    local wx, wy = x + R.cam.x, y + R.cam.y
    for _, m in ipairs(R.machines) do
      if m.kind == "crate" and math.abs(m.x + 1 - wx) < 14 and math.abs(m.y - 1 - wy) < 14 then
        R.cratePanel = m; return true
      end
    end
    local hit = machineAt(wx, wy)
    if hit and hit.kind ~= "crate" then R.machinePanel = hit; R.uiPanelOpen = true; return true end
  end
end)

-- ================================================================ per-tick machine logic
-- Real sustained combustion (the player 19:58): mirrors exactly what the player's own placeable torch item does in
-- core (rpg.lua's updateTorches) - COAL in this session has Flammable=0 and HighTemperature=10000 (a deliberate
-- realism-patch choice, see the 19:05 hub note), so it never self-ignites or transitions on its own. A real,
-- continuously-refreshed FIRE particle pinned to the ember cell is therefore the only physically honest way to
-- get sustained heat: TPT's own engine then does the rest for real (heat conducts from FIRE into the coal/grate/
-- water by direct contact, and WATR crosses its real 373K HighTemperature threshold and becomes WTRV on its own -
-- nothing here creates or fakes a steam particle).
local function updateBoiler()
  for _, m in ipairs(R.machines) do if m.kind == "boiler" and m.lit then
    m.fuel = (m.fuel or 0) - 1
    if m.fuel <= 0 then
      m.lit = false
      clearBox(m.coalBox.x1, m.coalBox.y1, m.coalBox.x2, m.coalBox.y2)
      R.say("Boiler ran out of coal")
    elseif (R.frame % 6) == 0 then
      local ex, ey = m.ember.x - R.cam.x, m.ember.y - R.cam.y
      if ex >= 0 and ex < W and ey >= 0 and ey < H then
        local p = sim.partID(ex, ey)
        if p then sim.partProperty(p, "temp", 1100)
        else local f = sim.partCreate(-1, ex, ey, R.eid("FIRE")); if f and f >= 0 then sim.partProperty(f, "life", 30); sim.partProperty(f, "temp", 1100) end end
      end
    end
  end end
end
local function updateTurbines()
  for _, m in ipairs(R.machines) do if m.kind == "turbine" then
    local ox, oy = m.output.x - R.cam.x, m.output.y - R.cam.y
    if ox > -10 and ox < W + 10 and oy > -10 and oy < H + 10 then
      local hits = 0
      for _, b in ipairs(m.blades) do
        local bx, by = b.x - R.cam.x, b.y - R.cam.y
        for _, d in ipairs(N4) do
          local p = sim.partID(bx + d[1], by + d[2])
          if p and R.nameOf(sim.partProperty(p, "type")) == "WTRV" and math.random() < 0.35 then
            sim.partProperty(p, "type", R.eid("WATR"))
            sim.partProperty(p, "temp", math.max(295, (sim.partProperty(p, "temp") or 295) - 40))
            hits = hits + 1
          end
        end
      end
      if hits > 0 then
        m.hits = (m.hits or 0) + hits
        local op = sim.partID(ox, oy)
        if op and (sim.partProperty(op, "life") or 0) == 0 then
          sim.partProperty(op, "ctype", sim.partProperty(op, "type")); sim.partProperty(op, "type", R.eid("SPRK")); sim.partProperty(op, "life", 4)
        end
        m.lastHit = R.frame
      end
    end
  end end
end
local function updateDoors()
  for _, m in ipairs(R.machines) do if m.kind == "door" then
    local px, py = m.pad.x - R.cam.x, m.pad.y - R.cam.y
    if px > -5 and px < W + 5 and py > -5 and py < H + 5 then
      local pw = poweredAt(m.pad.x, m.pad.y, 1) and gridPowered(m)
      if pw and not m.open then
        for _, b in ipairs(m.blocks) do local p = sim.partID(b.x - R.cam.x, b.y - R.cam.y); if p then sim.partKill(p) end end
        m.open = true
      elseif not pw and m.open then
        for _, b in ipairs(m.blocks) do setAt(b.x, b.y, "METL") end
        m.open = false
      end
    end
  end end
end
local function updatePumps()
  for _, m in ipairs(R.machines) do if m.kind == "pump" then
    local px, py = m.pad.x - R.cam.x, m.pad.y - R.cam.y
    if px > -5 and px < W + 5 and py > -5 and py < H + 5 then
      if poweredAt(m.pad.x, m.pad.y, 1) and gridPowered(m) then
        m.cool = (m.cool or 0) - 1
        if m.cool <= 0 then
          local ix, iy = m.intake.x - R.cam.x, m.intake.y - R.cam.y
          local ox, oy = m.outlet.x - R.cam.x, m.outlet.y - R.cam.y
          local ip = sim.partID(ix, iy)
          if ip and R.nameOf(sim.partProperty(ip, "type")) == "WATR" and not sim.partID(ox, oy) then
            sim.partKill(ip); sim.partCreate(-1, ox, oy, R.eid("WATR")); m.cool = 3
          end
        end
      end
    end
  end end
end
local POWDERY = { SAND = 1, BCOL = 1, COAL = 1, IRON = 1, GOLD = 1, CU = 1, GOO = 1, SNOW = 1, ASH = 1, DUST = 1, CLST = 1 }
local function updateConveyors()
  for _, m in ipairs(R.machines) do if m.kind == "conveyor" then
    for _, c in ipairs(m.cells) do
      local cx, cy = c.x - R.cam.x, c.y - R.cam.y
      if cx > -2 and cx < W + 2 and cy > -2 and cy < H + 2 then
        local p = sim.partID(cx, cy - 1)
        if p then local nm = R.nameOf(sim.partProperty(p, "type")); if POWDERY[nm] then sim.partProperty(p, "vx", 1.6 * m.dir) end end
      end
    end
  end end
end
local function updateCranks()
  for _, m in ipairs(R.machines) do if m.kind == "crank" then
    local near = math.abs(m.x - R.P.x) < 24 and math.abs(m.y - R.P.y) < 30
    m.turning = near and heldF
    m.angle = (m.angle or 0) + (m.turning and 0.35 or 0)
    if m.turning and (R.frame % 6 == 0) then
      local op = sim.partID(m.output.x - R.cam.x, m.output.y - R.cam.y)
      if op and (sim.partProperty(op, "life") or 0) == 0 then
        sim.partProperty(op, "ctype", sim.partProperty(op, "type")); sim.partProperty(op, "type", R.eid("SPRK")); sim.partProperty(op, "life", 4)
      end
    end
  end end
end
local SMELT_MAP = { IRON = "METL", DU = "URAN" }
local function updateEFurnace()
  for _, m in ipairs(R.machines) do if m.kind == "efurnace" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      for ore, bar in pairs(SMELT_MAP) do
        if R.inv(ore) > 0 then R.inventory[ore] = R.inv(ore) - 1; R.give(bar, 1); m.cool = 40; break end
      end
    end
  end end
end
local function updateCrusher()
  for _, m in ipairs(R.machines) do if m.kind == "crusher" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 and R.inv("COAL") > 0 then
      R.inventory.COAL = R.inv("COAL") - 1; R.give("BCOL", 2); m.cool = 50
    end
  end end
end
local function updateAutocraft()
  for _, m in ipairs(R.machines) do if m.kind == "autocraft" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      for _, c in ipairs(R.machines) do if c.kind == "crate" and math.abs(c.x - m.x) < 60 and math.abs(c.y - m.y) < 60 then
        for ore, bar in pairs(SMELT_MAP) do
          if (c.items[ore] or 0) > 0 then
            c.items[ore] = c.items[ore] - 1; if c.items[ore] <= 0 then c.items[ore] = nil end
            c.items[bar] = (c.items[bar] or 0) + 1; m.cool = 30; break
          end
        end
      end end
    end
  end end
end
local function updateTurret()
  for _, m in ipairs(R.machines) do if m.kind == "turret" or m.kind == "turret2" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 and type(R.damageEnemiesAt) == "function" then
      local hits = R.damageEnemiesAt(m.x, m.y - 6, m.range or 150, m.dmg or 8, 2)
      if hits and hits > 0 then m.cool = 30; m.lastFire = R.frame end
    end
  end end
end
local function updateDrill()
  for _, m in ipairs(R.machines) do if m.kind == "drill" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      local tx, ty = m.tx - R.cam.x, m.ty - R.cam.y
      if tx > -4 and tx < W + 4 and ty > -4 and ty < H + 4 then
        local p = sim.partID(tx, ty)
        if p then
          local nm = R.nameOf(sim.partProperty(p, "type")); local tier = R.MINEABLE[nm]
          if tier and tier <= 4 then
            m.prog = (m.prog or 0) + 1
            if m.prog >= (R.HARD[nm] or 3) then sim.partKill(p); R.give(nm, 1); m.prog = 0 end
          end
        end
      end
      m.cool = 6
    end
  end end
end
-- ---------------- second wave tick logic ----------------
-- Life support registers into core's real O2 model (R.o2Sources - {x,y,rate,range}, sampled every 5 frames
-- near the player, see rpg.lua's breathability calc). Rebuilt from scratch every cycle so a destroyed/unpowered
-- machine's contribution disappears immediately instead of leaking a stale source forever.
local function syncO2Sources()
  R.o2Sources = R.o2Sources or {}
  for i = #R.o2Sources, 1, -1 do if R.o2Sources[i]._src == TAG then table.remove(R.o2Sources, i) end end
  for _, m in ipairs(R.machines) do
    local rate = O2_RATE[m.kind]
    if rate then
      local on = (m.kind == "greenhouse") or (m.kind == "bellows" and m.pumping) or gridPowered(m)
      if on then table.insert(R.o2Sources, { x = m.x, y = m.y, rate = rate, range = 70, _src = TAG }) end
    elseif m.kind == "airline" then
      -- real supply-chain check: walk the laid segments from the source end, counting only the ones that
      -- still physically exist - a cut duct (a segment killed by mining/an explosion) genuinely stops the
      -- air beyond that point, exactly like the player asked ("breaks if the duct is cut")
      local intact = 0
      for _, seg in ipairs(m.segs) do
        if sim.partID(seg.x - R.cam.x, seg.y - R.cam.y) then intact = intact + 1 else break end
      end
      m.intact = intact
      for i = AIRLINE_SEG_STEP, intact, AIRLINE_SEG_STEP do
        local seg = m.segs[i]
        table.insert(R.o2Sources, { x = seg.x, y = seg.y, rate = AIRLINE_SEG_RATE, range = AIRLINE_SEG_RANGE, _src = TAG })
      end
    end
  end
end
-- Sealed-base life support. Runs on core's OWN hunger/thirst cadence (rpg.lua drains on
-- `R.frame % 90 == 0`: food -0.35, water -0.5 baseline) so the rates below are directly
-- comparable to the drain instead of being invented numbers: +0.9 food / +1.2 water is a
-- net gain of roughly 2.5x drain, i.e. a powered sealed base slowly refills you rather than
-- merely holding you level, and refills 0 -> 100 in about 4-5 real minutes.
-- Oxygen is deliberately NOT handled here -- it already flows through O2_RATE/syncO2Sources
-- exactly like the air pump, so there is no second oxygen code path to keep in sync.
-- "Sealed" reuses the existing cheap roomSealed vertical multi-ray probe at three columns
-- (centre and +/-6) rather than a bounded flood-fill: a real O(area) region scan is what
-- caused the oxygen-spawn lag regression earlier in this project, and three rays are enough
-- to reject the common false positive of a single covered column under an open room.
local function updateLifeSupport()
  if (R.frame or 0) % 90 ~= 0 then return end
  for _, m in ipairs(R.machines) do if m.kind == "lifesupport" then
    local powered = gridPowered(m)
    local sealed = roomSealed(m.x, m.y) and roomSealed(m.x - 6, m.y) and roomSealed(m.x + 6, m.y)
    local px, py = (R.P and R.P.x or 0), (R.P and R.P.y or 0)
    local dx, dy = px - m.x, py - m.y
    local inRange = (dx * dx + dy * dy) <= (LIFESUPPORT_RANGE * LIFESUPPORT_RANGE)
    -- cached for the inspect panel so the player can see exactly which condition is failing
    m.powered, m.sealed, m.inRange = powered, sealed, inRange
    if powered and sealed and inRange and R.need and not R.sandbox then
      R.need.food = math.min(100, R.need.food + 0.9)
      R.need.water = math.min(100, R.need.water + 1.2)
    end
  end end
end
local function updateAirpump()
  for _, m in ipairs(R.machines) do if m.kind == "airpump" then
    m.angle = (m.angle or 0) + (gridPowered(m) and 0.3 or 0)
    if gridPowered(m) then
      local dx, dy = m.duct.x - R.cam.x, m.duct.y - R.cam.y
      if dx > -4 and dx < W + 4 and dy > -4 and dy < H + 4 then
        for i = 0, 4 do local p = sim.partID(dx + i, dy)
          if p and R.nameOf(sim.partProperty(p, "type")) == "OXYG" then sim.partProperty(p, "vx", 2.2) end end
      end
    end
  end end
end
local function updateBellows()
  for _, m in ipairs(R.machines) do if m.kind == "bellows" then
    local near = math.abs(m.x - R.P.x) < 24 and math.abs(m.y - R.P.y) < 30
    m.pumping = near and heldF
    if m.pumping then
      m.angle = (m.angle or 0) + 0.3
      if (R.inventory.FLASK or 0) > 0 then
        local cap = 100 * math.min(3, R.inventory.FLASK)
        R.flask = math.min(cap, (R.flask or 0) + 6)
      end
      local dx, dy = m.duct.x - R.cam.x, m.duct.y - R.cam.y
      if dx > -4 and dx < W + 4 and dy > -4 and dy < H + 4 then
        for i = 0, 3 do local p = sim.partID(dx + i, dy)
          if p and R.nameOf(sim.partProperty(p, "type")) == "OXYG" then sim.partProperty(p, "vx", 1.8) end end
      end
    end
  end end
end
local function updateCompressor()
  for _, m in ipairs(R.machines) do if m.kind == "compressor" then
    m.cool = (m.cool or 0) - 1
    local near = math.abs(m.x - R.P.x) < 30 and math.abs(m.y - R.P.y) < 34
    if gridPowered(m) and near and m.cool <= 0 then
      local ix, iy = m.intake.x - R.cam.x, m.intake.y - R.cam.y
      local ip = sim.partID(ix, iy)
      if ip and R.nameOf(sim.partProperty(ip, "type")) == "OXYG" then
        local used = false
        if R.inv("OXYTANK") > 0 and (R.itemsO2Charge or 0) < 400 then
          R.itemsO2Charge = math.min(400, (R.itemsO2Charge or 0) + 40); used = true
        end
        if (R.inventory.FLASK or 0) > 0 then
          local cap = 100 * math.min(3, R.inventory.FLASK)
          if (R.flask or 0) < cap then R.flask = math.min(cap, (R.flask or 0) + 20); used = true end
        end
        if used then sim.partKill(ip); m.filled = R.frame end
      end
      m.cool = 15
    end
  end end
end
local function updateO2gen()
  for _, m in ipairs(R.machines) do if m.kind == "o2gen" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      local tx, ty = m.tank.x - R.cam.x, m.tank.y - R.cam.y
      local ox, oy = m.outlet.x - R.cam.x, m.outlet.y - R.cam.y
      local tp = sim.partID(tx, ty)
      if tp and R.nameOf(sim.partProperty(tp, "type")) == "WATR" and not sim.partID(ox, oy) then
        sim.partKill(tp)
        sim.partCreate(-1, ox, oy, R.eid("OXYG"))
        if math.random() < 0.5 and R.has("HYGN") then sim.partCreate(-1, ox, oy - 1, R.eid("HYGN")) end
        m.fired = R.frame; m.cool = 25
      end
    end
  end end
end
local BADGAS = { CO2 = true, SMKE = true }
local SCRUB_REG = { scrubber = { rate = 28, range = 70 }, ventfan = { rate = 18, range = 90 } }
local function syncScrubbers()
  R.scrubbers = R.scrubbers or {}
  for i = #R.scrubbers, 1, -1 do if R.scrubbers[i]._src == TAG then table.remove(R.scrubbers, i) end end
  for _, m in ipairs(R.machines) do
    local reg = SCRUB_REG[m.kind]
    if reg and gridPowered(m) then
      table.insert(R.scrubbers, { x = m.x, y = m.y, rate = reg.rate, range = reg.range, _src = TAG })
    end
  end
end
local function updateScrubber()
  for _, m in ipairs(R.machines) do if m.kind == "scrubber" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      local px, py = m.pad.x - R.cam.x, m.pad.y - R.cam.y
      local hit = false
      for dy = -10, 10, 2 do for dx = -10, 10, 2 do
        local p = sim.partID(px + dx, py + dy)
        if p and BADGAS[R.nameOf(sim.partProperty(p, "type"))] then sim.partKill(p); hit = true end
      end end
      m.cool = hit and 10 or 20
    end
  end end
end
local function updateVentfan()
  for _, m in ipairs(R.machines) do if m.kind == "ventfan" then
    m.angle = (m.angle or 0) + (gridPowered(m) and 0.35 or 0)
    if gridPowered(m) then
      local dx, dy = m.duct.x - R.cam.x, m.duct.y - R.cam.y
      if dx > -4 and dx < W + 4 and dy > -4 and dy < H + 4 then
        for i = 0, 5 do
          local p = sim.partID(dx + i, dy)
          if p and BADGAS[R.nameOf(sim.partProperty(p, "type"))] then
            -- VENTFAN-NO-OP BUG (2026-08-31): this loop pushed gas along the duct (vx=2.4)
            -- but never removed it -- unlike the sibling scrubber (which sim.partKill's
            -- BADGAS directly), the fan measurably relocated CO2/SMKE and never reduced the
            -- real particle count, despite its own item text claiming it "vents" gas. Kill it
            -- at the duct's far cell so gas actually exits instead of just drifting in place.
            if i == 5 then sim.partKill(p) else sim.partProperty(p, "vx", 2.4) end
          end
        end
      end
    end
  end end
end
local function updateSawmill()
  for _, m in ipairs(R.machines) do if m.kind == "sawmill" then
    m.angle = (m.angle or 0) + ((gridPowered(m) and m.cool and m.cool > 40) and 0.5 or 0)
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      if R.inv("WOOD") >= 2 then R.inventory.WOOD = R.inv("WOOD") - 2; R.give("COAL", 1); m.cool = 45 else m.cool = 30 end
    end
  end end
end
local function updateDesal()
  for _, m in ipairs(R.machines) do if m.kind == "desal" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      local ix, iy = m.intake.x - R.cam.x, m.intake.y - R.cam.y
      local ox, oy = m.outlet.x - R.cam.x, m.outlet.y - R.cam.y
      local ip = sim.partID(ix, iy)
      if ip and R.nameOf(sim.partProperty(ip, "type")) == "SLTW" and not sim.partID(ox, oy) then
        sim.partKill(ip); sim.partCreate(-1, ox, oy, R.eid("WATR"))
        if R.has("SALT") and math.random() < 0.4 then sim.partCreate(-1, ox, oy - 1, R.eid("SALT")) end
        m.cool = 8
      end
    end
  end end
end
local BF_SMELT = { IRON = "METL", DU = "URAN", GOLD = "GOLD" }
local function updateBlastfurnace()
  for _, m in ipairs(R.machines) do if m.kind == "blastfurnace" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      for ore, bar in pairs(BF_SMELT) do
        if R.inv(ore) > 0 then R.inventory[ore] = R.inv(ore) - 1; R.give(bar, 1); m.cool = 18; m.hot = R.frame; break end
      end
    end
  end end
end
local function updateSolarFurnace()
  for _, m in ipairs(R.machines) do if m.kind == "solarfurnace" then
    m.cool = (m.cool or 0) - 1
    local phase = ((R.frame or 0) % 14000) / 14000
    local day = math.max(0, -math.sin((phase - 0.5) * math.pi * 2))
    if day > 0.4 and m.cool <= 0 then
      for ore, bar in pairs(SMELT_MAP) do
        if R.inv(ore) > 0 then R.inventory[ore] = R.inv(ore) - 1; R.give(bar, 1); m.cool = 70; break end
      end
    end
  end end
end
local FLARE_GAS = { HYGN = true, GAS = true }
local function updateFlare()
  for _, m in ipairs(R.machines) do if m.kind == "flare" then
    local bx, by = m.x - R.cam.x, m.y - R.cam.y
    for dx = -2, 2 do for dy = -2, 2 do
      local p = sim.partID(bx + dx, by + dy)
      if p and FLARE_GAS[R.nameOf(sim.partProperty(p, "type"))] then sim.partKill(p) end
    end end
    if R.gas and math.abs(m.x - R.P.x) < 150 and math.abs(m.y - R.P.y) < 150 then
      R.gas.ch4 = math.max(0, (R.gas.ch4 or 0) - 0.5)
    end
  end end
end
local function updateSolarDust()
  if R.frame % 600 ~= 0 then return end
  for _, m in ipairs(R.machines) do if m.kind == "solar" then m.dust = math.min(80, (m.dust or 0) + 3) end end
end
-- (BADGAS2 removed: byte-identical to BADGAS above, which is already in scope here)
local function updateGasDetector()
  for _, m in ipairs(R.machines) do if m.kind == "gasdetector" then
    local bx, by = m.x - R.cam.x, m.y - R.cam.y
    local bad = false
    for dx = -8, 8, 2 do for dy = -8, 8, 2 do
      local p = sim.partID(bx + dx, by + dy)
      if p and BADGAS[R.nameOf(sim.partProperty(p, "type"))] then bad = true end
    end end
    local near = math.abs(m.x - R.P.x) < 150 and math.abs(m.y - R.P.y) < 150
    local ch4hi = near and R.gas and (R.gas.ch4 or 0) > 25
    m.warn = bad or ch4hi or false
    if m.warn and near and (R.frame % 90 == 0) then R.say("Gas detector: dangerous gas nearby!") end
  end end
end
local function updateBreaker()
  for _, m in ipairs(R.machines) do if m.kind == "breaker" then
    if not m.tripped then
      local g = m._gid and R.power.grids[m._gid]
      if g and g.load > (g.gen + g.stored) * 1.4 and g.load > 4 then
        killAt(m.bridge.x, m.bridge.y); m.tripped = true
        R.say("BREAKER TRIPPED - grid overloaded, right-click it to reset")
      end
    end
  end end
end
local function updateElevator()
  for _, m in ipairs(R.machines) do if m.kind == "elevator" then
    if gridPowered(m) then
      local cx = m.colx - R.cam.x
      if cx > -2 and cx < W + 2 then
        for y = m.top, m.bottom do
          local p = sim.partID(cx, y - R.cam.y)
          if p then local nm = R.nameOf(sim.partProperty(p, "type")); if POWDERY[nm] then sim.partProperty(p, "vy", -2.2) end end
        end
      end
    end
  end end
end
local function updateTunneler()
  for _, m in ipairs(R.machines) do if m.kind == "tunneler" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 and (m.travelled or 0) < 200 then
      local tx, ty = m.tx - R.cam.x, m.ty - R.cam.y
      if tx > -4 and tx < W + 4 and ty > -4 and ty < H + 4 then
        local p = sim.partID(tx, ty)
        if p then
          local nm = R.nameOf(sim.partProperty(p, "type")); local tier = R.MINEABLE[nm]
          if tier and tier <= 4 then
            m.prog = (m.prog or 0) + 1
            if m.prog >= (R.HARD[nm] or 3) then
              sim.partKill(p); R.give(nm, 1); m.prog = 0
              m.x = m.x + m.dir; m.core.x = m.core.x + m.dir; m.pad.x = m.pad.x + m.dir
              m.tx = m.tx + m.dir; m.travelled = (m.travelled or 0) + 1
            end
          end
        end
      end
      m.cool = 6
    end
  end end
end
local FIRE_NAMES = { FIRE = true, PLSM = true }
local function updateSprinkler()
  for _, m in ipairs(R.machines) do if m.kind == "sprinkler" then
    m.cool = (m.cool or 0) - 1
    if gridPowered(m) and m.cool <= 0 then
      local nx, ny = m.nozzle.x - R.cam.x, m.nozzle.y - R.cam.y
      local sprayed = false
      for dy = -12, 4 do for dx = -12, 12, 2 do
        local p = sim.partID(nx + dx, ny + dy)
        if p and (FIRE_NAMES[R.nameOf(sim.partProperty(p, "type"))] or (sim.partProperty(p, "temp") or 0) > 700) then
          sim.partCreate(-1, nx + dx, ny + dy, R.eid("WATR")); sprayed = true
        end
      end end
      m.spraying = sprayed; m.cool = sprayed and 6 or 20
    end
  end end
end
local TEARDOWN = {
  boiler = function(m) clearBox(m.x - 2, m.y - 22, m.x + 20, m.y) end,
  turbine = function(m) clearBox(m.cx - m.r - 4, m.cy - m.r - 1, m.cx + m.r + 4, m.y) end,
  door = function(m) for _, b in ipairs(m.blocks) do killAt(b.x, b.y) end; killAt(m.pad.x, m.pad.y); killAt(m.core.x, m.core.y) end,
  pump = function(m) clearBox(m.intake.x - 2, m.core.y - 4, m.outlet.x + 2, m.core.y + 4) end,
  conveyor = function(m) for _, c in ipairs(m.cells) do killAt(c.x, c.y) end end,
  crate = function(m) clearBox(m.x, m.y - 3, m.x + 3, m.y); for nm, n in pairs(m.items) do R.give(nm, n) end end,
  lamp = function(m) killAt(m.core.x, m.core.y) end,
  crank = function(m) clearBox(m.x, m.y - 5, m.x + 4, m.y) end,
  wheel = function(m) clearBox(m.cx - m.r - 1, m.cy - m.r - 1, m.cx + m.r + 1, m.y) end,
  solar = function(m) clearBox(m.x - 1, m.y - 7, m.x + 8, m.y) end,
  teg = function(m) clearBox(m.x, m.y - 3, m.x + 3, m.y) end,
  battery = function(m) clearBox(m.x, m.y - 5, m.x + 7, m.y) end,
  capacitor = function(m) clearBox(m.x, m.y - 4, m.x + 2, m.y) end,
  efurnace = function(m) clearBox(m.x, m.y - 6, m.x + 5, m.y) end,
  crusher = function(m) clearBox(m.x, m.y - 9, m.x + 10, m.y) end,
  autocraft = function(m) clearBox(m.x, m.y - 7, m.x + 6, m.y) end,
  turret = function(m) clearBox(m.x, m.y - 7, m.x + 2, m.y) end,
  turret2 = function(m) clearBox(m.x, m.y - 7, m.x + 2, m.y) end,
  drill = function(m) clearBox(m.x, m.y - 4, m.x + 3, m.y) end,
  reactor = function(m) clearBox(m.x - 1, m.y - 19, m.x + 32, m.y) end,
  airpump = function(m) clearBox(m.cx - 5, m.cy - 6, m.cx + 9, m.y) end,
  o2gen = function(m) clearBox(m.x, m.y - 6, m.x + 7, m.y) end,
  scrubber = function(m) clearBox(m.x, m.y - 5, m.x + 4, m.y) end,
  ventfan = function(m) clearBox(m.x, m.y - 4, m.x + 9, m.y) end,
  greenhouse = function(m) clearBox(m.x, m.y - 6, m.x + 6, m.y) end,
  sawmill = function(m) clearBox(m.x, m.y - 6, m.x + 7, m.y) end,
  desal = function(m) clearBox(m.intake.x, m.y - 5, m.outlet.x, m.y) end,
  blastfurnace = function(m) clearBox(m.x, m.y - 12, m.x + 7, m.y) end,
  rtg = function(m) clearBox(m.x, m.y - 4, m.x + 9, m.y) end,
  flywheel = function(m) clearBox(m.cx - 6, m.cy - 6, m.cx + 6, m.y) end,
  breaker = function(m) clearBox(m.x, m.y - 3, m.x + 4, m.y) end,
  elevator = function(m) clearBox(m.x, m.top, m.x + 3, m.y) end,
  tunneler = function(m) clearBox(m.x - 4, m.y - 4, m.tx + 4, m.y + 2) end,
  sprinkler = function(m) clearBox(m.x, m.y - 3, m.x + 2, m.y) end,
  lightning = function(m) clearBox(m.x, m.y - 13, m.x + 1, m.y) end,
  gasturbine = function(m) clearBox(m.x - 2, m.y - 6, m.x + 8, m.y) end,
  bellows = function(m) clearBox(m.x, m.y - 4, m.x + 8, m.y) end,
  fuelcell = function(m) clearBox(m.x - 2, m.y - 6, m.x + 7, m.y) end,
  wind = function(m) clearBox(m.x - 4, m.y - 19, m.x + 4, m.y) end,
  solarfurnace = function(m) clearBox(m.x, m.y - 6, m.x + 5, m.y) end,
  flare = function(m) clearBox(m.x - 1, m.y - 10, m.x + 2, m.y) end,
  geotap = function(m) clearBox(m.x, m.y - 6, m.x + 7, m.y) end,
  methanecap = function(m) clearBox(m.x, m.y - 6, m.x + 5, m.y) end,
  gasdetector = function(m) clearBox(m.x, m.y - 4, m.x + 2, m.y) end,
  leadshield = function(m) clearBox(m.x, m.y - 5, m.x + 1, m.y) end,
  compressor = function(m) clearBox(m.x - 1, m.y - 7, m.x + 5, m.y) end,
  airline = function(m) for _, seg in ipairs(m.segs) do killAt(seg.x, seg.y) end end,
}
-- machine-core check runs every 25 frames (inlined below)
local function updateMachineCores()
  if R.frame % 25 ~= 0 then return end
  for i = #R.machines, 1, -1 do
    local m = R.machines[i]
    local cx, cy = m.core.x - R.cam.x, m.core.y - R.cam.y
    if cx > M and cx < W - M and cy > M and cy < H - M then
      if not sim.partID(cx, cy) then
        -- Reported bug: placed machines "just disappear." Confirmed this check IS
        -- the mechanism (it actively removes a machine the instant its core cell
        -- reads empty), but a single-tick miss right as the core scrolls back
        -- into view -- one frame where the scroll/tile-cache fill hasn't quite
        -- landed yet -- reads identically to "actually destroyed." Requiring a
        -- few consecutive misses (~1s) filters that out without meaningfully
        -- delaying real destruction (an explosion, a mined-out core) being caught.
        m.coreMiss = (m.coreMiss or 0) + 1
        if m.coreMiss >= 3 then
          local td = TEARDOWN[m.kind]; if td then pcall(td, m) end
          -- Tombstone a worldgen-spawned object so sRoll doesn't resurrect it on the next reload:
          -- terrain regenerates from the seed, so "the player demolished this" can only live in the save.
          if m.src then R.structSpent[m.src] = true end
          if R.cratePanel == m then R.cratePanel = nil end
          if R.machinePanel == m then R.machinePanel = nil; R.uiPanelOpen = false end
          R.say(m.kind .. " destroyed"); table.remove(R.machines, i)
        end
      else
        m.coreMiss = nil
      end
    else
      -- An OFF-SCREEN core carries no evidence either way, so it must not keep a
      -- half-accumulated miss count alive. Without this, the grace period above
      -- defeats itself: a core that read empty twice (coreMiss=2) before the player
      -- scrolled away kept that 2 while off-screen, so the FIRST transient miss on
      -- scrolling back -- exactly the tile-cache-refill frame the grace period was
      -- added to survive -- hit 3 and destroyed the machine. Matches the original
      -- "I place machines and they disappear (after scrolling away and back)" report.
      m.coreMiss = nil
    end
  end
end
-- Fast mode (core, the player/lead 18:36): air pressure/velocity sim is off by default for ~25% more fps and only
-- needed for steam/pressure machines. Turn it on for real while any exist, and give it back the moment they
-- don't - never leave it forced on, and never fight a manual toggle beyond what we ourselves changed.
local PRESSURE_KINDS = { boiler = true, turbine = true, reactor = true, blastfurnace = true, gasturbine = true }
local function syncFastMode()
  local needAir = false
  for _, m in ipairs(R.machines) do if PRESSURE_KINDS[m.kind] then needAir = true; break end end
  if needAir and R.fast then R.setFast(false); R._machinesForcedFast = true
  elseif not needAir and R._machinesForcedFast and R.fast == false then R.setFast(true); R._machinesForcedFast = false end
end
hook(R.hooks.tick, function()
  for _, f in ipairs({ updateBoiler, updateTurbines, updateDoors, updatePumps, updateConveyors, updateCranks,
                       updateEFurnace, updateCrusher, updateAutocraft, updateTurret, updateDrill,
                       updateAirpump, updateBellows, updateCompressor, updateO2gen, updateScrubber, updateVentfan, updateSawmill, updateDesal,
                       updateBlastfurnace, updateSolarFurnace, updateFlare, updateSolarDust, updateGasDetector,
                       updateBreaker, updateElevator, updateTunneler, updateSprinkler, updateLifeSupport,
                       updateMachineCores }) do
    local ok, err = pcall(f); if not ok then R.pluginErr = tostring(err) end
  end
  if (R.frame or 0) % 15 == 0 then
    local ok, err = pcall(recomputePower); if not ok then R.pluginErr = tostring(err) end
    ok, err = pcall(syncO2Sources); if not ok then R.pluginErr = tostring(err) end
    ok, err = pcall(syncScrubbers); if not ok then R.pluginErr = tostring(err) end
    ok, err = pcall(syncFastMode); if not ok then R.pluginErr = tostring(err) end
  end
end)

-- ================================================================ overlays
local MLABEL = { boiler = "BOILER", turbine = "TURBINE", door = "DOOR", pump = "PUMP", conveyor = "BELT", crate = "CRATE",
  lamp = "LAMP", crank = "CRANK", wheel = "WATER WHEEL", solar = "SOLAR PANEL", teg = "TEG-GEN", battery = "BATTERY",
  capacitor = "CAPACITOR", efurnace = "E-FURNACE", crusher = "CRUSHER", autocraft = "AUTOCRAFTER",
  turret = "TURRET", turret2 = "TURRET MK2", drill = "DRILL", reactor = "REACTOR",
  airpump = "AIR PUMP", o2gen = "O2 GENERATOR", scrubber = "CO2 SCRUBBER", ventfan = "VENT FAN", greenhouse = "GREENHOUSE",
  sawmill = "SAWMILL", desal = "DESALINATOR", blastfurnace = "BLAST FURNACE", rtg = "RTG",
  flywheel = "FLYWHEEL", breaker = "BREAKER", elevator = "ELEVATOR", tunneler = "TUNNELER",
  sprinkler = "SPRINKLER", lightning = "LIGHTNING ROD", gasturbine = "GAS TURBINE",
  bellows = "BELLOWS", airline = "AIR LINE", compressor = "COMPRESSOR", lifesupport = "LIFE SUPPORT",
  fuelcell = "FUEL CELL", wind = "WIND TURBINE", solarfurnace = "SOLAR FURNACE", flare = "FLARE STACK",
  geotap = "GEOTHERMAL TAP", methanecap = "METHANE CAPTURE", gasdetector = "GAS DETECTOR", leadshield = "LEAD SHIELD" }
local GAUGE_MAX = { crank = WATT_CRANK, wheel = 30, solar = WATT_SOLAR_BASE, teg = 20, turbine = 60, reactor = 120,
  rtg = 6, lightning = WATT_LIGHTNING, gasturbine = 24, fuelcell = 14, wind = 24, geotap = 60, methanecap = 20 }
local function onscreen(x, y, m) return x > -m and x < W + m and y > -m and y < H + m end
hook(R.hooks.draw, function()
  for _, m in ipairs(R.machines) do
    local x, y = m.x - R.cam.x, m.y - R.cam.y
    if onscreen(x, y, 40) then
      if nearPlayer(m.x, m.y, 160) and y - 24 < H - 42 then graphics.drawText(x - 2, y - 24, MLABEL[m.kind] or m.kind, 255, 230, 150, 220) end
      local role = ROLE[m.kind]
      local termPt = role and machineTerminal(m)
      local powered
      if termPt then
        if role == "load" then powered = poweredAt(termPt.x, termPt.y, 1) and gridPowered(m)
        elseif role == "gen" then local g = m._gid and R.power.grids[m._gid]; powered = g ~= nil and (g.gen or 0) > 0
        elseif role == "store" then powered = (m.stored or 0) > 0 end
        local px, py = termPt.x - R.cam.x, termPt.y - R.cam.y
        graphics.fillCircle(px, py - 2, 2, 2, powered and 90 or 90, powered and 255 or 60, powered and 90 or 60, 255)
      end
      -- animated moving parts: nothing sits static once it has real output
      if m.kind == "turbine" or (m.kind == "reactor" and m.tcx) then
        local hcx, hcy = (m.kind == "turbine" and m.cx or m.tcx) - R.cam.x, (m.kind == "turbine" and m.cy or m.tcy) - R.cam.y
        local rad = m.kind == "turbine" and (m.r - 3) or 3
        m.angle = ((m.angle or 0) + (m.spinSpeed or 0)) % (2 * math.pi)
        for i = 0, 3 do
          local a = m.angle + i * (math.pi / 2)
          graphics.drawLine(hcx, hcy, hcx + math.cos(a) * rad, hcy + math.sin(a) * rad, 255, 240, 180, 255)
        end
      elseif m.kind == "wheel" then
        local hcx, hcy = m.cx - R.cam.x, m.cy - R.cam.y
        m.angle = ((m.angle or 0) + (m.spinSpeed or 0)) % (2 * math.pi)
        for i = 0, 5 do
          local a = m.angle + i * (math.pi / 3)
          graphics.drawLine(hcx, hcy, hcx + math.cos(a) * (m.r - 1), hcy + math.sin(a) * (m.r - 1), 210, 180, 120, 255)
        end
      elseif m.kind == "crank" then
        local hx, hy = x + 2, y - 5
        local a = m.angle or 0
        graphics.drawLine(hx, hy, hx + math.cos(a) * 3, hy + math.sin(a) * 3, 220, 220, 230, 255)
      elseif m.kind == "airpump" or m.kind == "ventfan" then
        local hcx, hcy = (m.cx or m.hub.x) - R.cam.x, (m.cy or m.hub.y) - R.cam.y
        for i = 0, 2 do local a = (m.angle or 0) + i * (math.pi * 2 / 3)
          graphics.drawLine(hcx, hcy, hcx + math.cos(a) * 3, hcy + math.sin(a) * 3, 200, 220, 255, 255) end
      elseif m.kind == "wind" then
        local hcx, hcy = m.cx - R.cam.x, m.cy - R.cam.y
        m.angle = ((m.angle or 0) + (m.spinSpeed or 0)) % (2 * math.pi)
        for i = 0, 2 do local a = m.angle + i * (math.pi * 2 / 3)
          graphics.drawLine(hcx, hcy, hcx + math.cos(a) * 5, hcy + math.sin(a) * 5, 220, 230, 220, 255) end
      elseif m.kind == "gasdetector" and m.warn and (R.frame % 20) < 10 then
        graphics.fillCircle(x + 1, y - 3, 2, 2, 255, 60, 60, 255)
      elseif m.kind == "sawmill" then
        local hcx, hcy = m.bcx - R.cam.x, m.bcy - R.cam.y
        for i = 0, 5 do local a = (m.angle or 0) + i * (math.pi / 3)
          graphics.drawLine(hcx, hcy, hcx + math.cos(a) * 2, hcy + math.sin(a) * 2, 230, 230, 240, 255) end
      elseif m.kind == "flywheel" then
        local hcx, hcy = m.cx - R.cam.x, m.cy - R.cam.y
        m.angle = ((m.angle or 0) + math.min(0.5, ((m.stored or 0) / math.max(1, m.cap or 1)) * 0.5)) % (2 * math.pi)
        for i = 0, 3 do local a = m.angle + i * (math.pi / 2)
          graphics.drawLine(hcx, hcy, hcx + math.cos(a) * 4, hcy + math.sin(a) * 4, 220, 200, 140, 255) end
      elseif m.kind == "sprinkler" and m.spraying then
        local nx, ny = m.nozzle.x - R.cam.x, m.nozzle.y - R.cam.y
        graphics.drawText(nx - 1, ny + (R.frame % 10), ".", 120, 180, 255, 220)
      elseif m.kind == "lightning" and R.weather and R.weather.rain then
        local rx, ry = m.rodTop.x - R.cam.x, m.rodTop.y - R.cam.y
        if (R.frame % 12) < 3 then graphics.drawText(rx - 2, ry - 3, "*", 220, 240, 255, 255) end
      elseif m.kind == "o2gen" and m.fired and (R.frame - m.fired) < 20 then
        local ox, oy = m.outlet.x - R.cam.x, m.outlet.y - R.cam.y
        graphics.drawText(ox, oy - (R.frame - m.fired), "o", 180, 220, 255, 200)
      elseif m.kind == "breaker" and m.tripped then
        graphics.drawText(x, y - 8, "!", 255, 80, 80, 255)
      elseif m.kind == "boiler" then
        -- pipe fluid-flow overlay (priority 3, 21:20): a moving dot along the real steam pipe, drawn ONLY
        -- while a real WTRV particle is actually present at the vent mouth right now - visualises a real
        -- reading, never a fake puff (the player 19:58 stands: no decoration simulating physics that isn't real)
        local vp = sim.partID(m.vent.x - R.cam.x, m.vent.y - R.cam.y)
        if vp and R.nameOf(sim.partProperty(vp, "type")) == "WTRV" then
          local t = (R.frame % 30) / 30
          local px = (m.vessel.x - R.cam.x) + math.floor(((m.vent.x - m.vessel.x)) * t)
          graphics.fillCircle(px, m.vent.y - R.cam.y, 1, 1, 220, 220, 230, 200)
        end
      elseif m.kind == "pump" and (m.cool or 0) > 0 then
        -- same real-flow dot, gated on the pump's own cool-down firing (only true right after it actually
        -- dragged a real WATR particle from intake to outlet, see updatePumps)
        local t = (R.frame % 20) / 20
        local px = (m.intake.x - R.cam.x) + math.floor(((m.outlet.x - m.intake.x)) * t)
        graphics.fillCircle(px, m.intake.y - R.cam.y, 1, 1, 120, 170, 230, 200)
      end
      -- output/charge gauge bar above generators and storage
      if role == "gen" or role == "store" then
        local val, maxv, col
        if role == "gen" then
          maxv = GAUGE_MAX[m.kind] or 40
          -- NEVER call genWatts() here - some generators (gas turbine, fuel cell) consume real particles as a
          -- side effect of measuring output, and this draw code runs every frame. m.lastWatts is the cached
          -- reading recomputePower already takes once per 15-frame cycle for every gen-role machine - reuse it.
          val = m.lastWatts or 0
          col = { 250, 210, 90 }
        else val = m.stored or 0; maxv = m.cap or 1; col = { 120, 220, 255 } end
        if nearPlayer(m.x, m.y, 160) then
          local gw = 20
          graphics.fillRect(x - gw / 2, y - 18, gw, 3, 30, 30, 40, 200)
          graphics.fillRect(x - gw / 2, y - 18, math.floor(gw * math.max(0, math.min(1, val / maxv))), 3, col[1], col[2], col[3], 255)
        end
      elseif (m.kind == "airpump" or m.kind == "o2gen" or m.kind == "greenhouse") and nearPlayer(m.x, m.y, 160) then
        -- life-support gauge: blue while producing, flips to amber/red once the room is over-oxygenated
        -- (R.o2conc>60 - core's own real fire-hazard threshold, see rpg.lua's HUD) so a player reads the
        -- risk at the machine itself, not just the corner HUD line
        local on = (m.kind == "greenhouse") or gridPowered(m)
        local conc = R.o2conc or 0
        local r2, g2, b2 = 120, 200, 255
        if conc > 60 then r2, g2, b2 = 255, 120, 60 elseif not on then r2, g2, b2 = 60, 60, 70 end
        graphics.fillRect(x - 10, y - 18, 20, 3, 30, 30, 40, 200)
        graphics.fillRect(x - 10, y - 18, on and math.floor(20 * math.min(1, conc / 100 + 0.15)) or 0, 3, r2, g2, b2, 255)
      end
      -- proximity affordance: pulsing outline + "[right-click] Name" prompt within reach (the player 19:34/19:37/19:38) -
      -- this is the single change that tells the player a structure is a clickable machine, not decoration
      if MBOX[m.kind] then
        local ccx, ccy, cr = machineCentre(m)
        local dx2, dy2 = ccx - R.P.x, ccy - R.P.y
        if dx2 * dx2 + dy2 * dy2 <= (cr + 22) * (cr + 22) then
          local pcx, pcy = ccx - R.cam.x, ccy - R.cam.y
          local pulse = 140 + math.floor(90 * math.abs(math.sin(R.frame * 0.06)))
          graphics.drawRect(pcx - cr, pcy - cr, cr * 2, cr * 2, 255, 230, 150, pulse)
          local label = "[right-click] " .. (MLABEL[m.kind] or m.kind)
          graphics.drawText(pcx - #label * 3, pcy - cr - 12, label, 255, 230, 150, 255)
        end
      end
    end
  end
end)
hook(R.hooks.drawHUD, function()
  -- power grid readout: nearest grid to the player, only while within range of one of its members
  local best, bestD
  for _, g in pairs(R.power.grids or {}) do
    for _, m in ipairs(g.members) do
      local d = (m.x - R.P.x) * (m.x - R.P.x) + (m.y - R.P.y) * (m.y - R.P.y)
      if not bestD or d < bestD then bestD = d; best = g end
    end
  end
  if best and bestD and bestD < 240 * 240 then
    local px, py, pw2, ph = 8, 278, 210, 54   -- sits just above the redesigned hotbar tray (y = H-38), never under it
    graphics.fillRect(px, py, pw2, ph, 10, 12, 26, 210); graphics.drawRect(px, py, pw2, ph, 120, 220, 255, 255)
    graphics.drawText(px + 6, py + 4, "POWER GRID", 120, 220, 255, 255)
    graphics.drawText(px + 6, py + 18, string.format("gen %dW   load %dW", math.floor(best.gen or 0), math.floor(best.load or 0)), 220, 220, 220, 255)
    local barw = pw2 - 12
    local frac = (best.cap or 0) > 0 and math.max(0, math.min(1, (best.stored or 0) / best.cap)) or 0
    graphics.fillRect(px + 6, py + 32, barw, 8, 40, 40, 60, 255)
    graphics.fillRect(px + 6, py + 32, math.floor(barw * frac), 8, 250, 210, 90, 255)
    local sr, sg, sb = 150, 255, 150; if not best.powered then sr, sg, sb = 255, 100, 100 end
    graphics.drawText(px + 6, py + 42, string.format("stored %d/%d   %s", math.floor(best.stored or 0), math.floor(best.cap or 0), best.powered and "STABLE" or "BROWNOUT"), sr, sg, sb, 255)
  end
  -- machine interaction panel (the player 19:34/19:37/19:38): right-click a machine's structure to open it
  if R.machinePanel then
    local pm = R.machinePanel
    local state, inputs, outputs, nextline = inspect(pm)
    local scol = { 150, 255, 150 }
    if state == "STARVED" or state == "BLOCKED" or state == "UNLIT" or state == "NO WATER" or state == "TRIPPED" then scol = { 255, 120, 100 }
    elseif state == "IDLE" or state == "STOPPED" or state == "EMPTY" then scol = { 230, 200, 120 } end
    graphics.fillRect(PX, PY, PW, PH, 10, 12, 26, 235); graphics.drawRect(PX, PY, PW, PH, 255, 220, 80, 255)
    graphics.fillRect(PX, PY, PW, 16, 40, 44, 80, 255)
    graphics.drawText(PX + 6, PY + 4, (MLABEL[pm.kind] or pm.kind), 255, 220, 80, 255)
    graphics.drawText(PX + PW - 8 - #state * 6, PY + 4, state, scol[1], scol[2], scol[3], 255)
    local ly = PY + 22
    graphics.drawText(PX + 6, ly, "INPUTS", 160, 190, 255, 255); ly = ly + 12
    if #inputs == 0 then graphics.drawText(PX + 10, ly, "none", 180, 180, 190, 200); ly = ly + 12 end
    for _, line in ipairs(inputs) do graphics.drawText(PX + 10, ly, line, 220, 220, 230, 255); ly = ly + 12 end
    ly = ly + 4
    graphics.drawText(PX + 6, ly, "OUTPUTS", 160, 255, 190, 255); ly = ly + 12
    if #outputs == 0 then graphics.drawText(PX + 10, ly, "none", 180, 180, 190, 200); ly = ly + 12 end
    for _, line in ipairs(outputs) do graphics.drawText(PX + 10, ly, line, 220, 230, 220, 255); ly = ly + 12 end
    ly = ly + 4
    graphics.drawText(PX + 6, ly, "NEXT: " .. nextline, 255, 220, 140, 255)
    for _, r in ipairs(panelButtonRects(pm)) do
      local ok = panelButtonEnabled(pm, r.id)
      local bg = ok and { 60, 70, 110 } or { 40, 40, 50 }
      local mx, my = R.mouse and R.mouse.x, R.mouse and R.mouse.y
      if ok and mx and mx >= r.x1 and mx < r.x2 and my >= r.y1 and my < r.y2 then bg = { 80, 100, 150 } end
      graphics.fillRect(r.x1, r.y1, r.x2 - r.x1, r.y2 - r.y1, bg[1], bg[2], bg[3], 255)
      graphics.drawRect(r.x1, r.y1, r.x2 - r.x1, r.y2 - r.y1, 200, 200, 215, 255)
      graphics.drawText(r.x1 + 6, r.y1 + 5, panelButtonLabel(pm, r.id), ok and 240 or 130, ok and 240 or 130, ok and 250 or 140, 255)
    end
    graphics.drawText(PX + 6, PY + PH - 10, "right-click closes", 150, 150, 160, 200)
  end
  -- crate panel
  local m = R.cratePanel; if not m then return end
  graphics.fillRect(CX, CY, CW, CH, 10, 12, 26, 235); graphics.drawRect(CX, CY, CW, CH, 255, 220, 80, 255)
  graphics.fillRect(CX, CY, CW, 16, 40, 44, 80, 255)
  graphics.drawText(CX + 6, CY + 4, "CRATE", 255, 220, 80, 255); graphics.drawText(CX + 124, CY + 4, "BAG", 255, 220, 80, 255)
  graphics.drawText(CX + 6, CY + 20, "click to take / store, right-click closes", 160, 160, 170, 255)
  local cn = crateRows(m.items)
  for i, nm in ipairs(cn) do graphics.drawText(CX + 8, CY + 42 + (i - 1) * 14, nice(nm) .. " x" .. m.items[nm], 200, 255, 200, 255) end
  local bn = crateRows(R.inventory)
  for i, nm in ipairs(bn) do graphics.drawText(CX + 124, CY + 42 + (i - 1) * 14, nice(nm) .. " x" .. R.inv(nm), 200, 200, 255, 255) end
end)

-- ================================================================ items + recipes
R.ITEMS.BOILER = { col = { 130, 50, 40 }, desc = "Boiler kit: place it, pour water in the open top with the bucket, then light the coal bed with the torch" }
R.ITEMS.TURBINE = { col = { 180, 180, 200 }, desc = "Steam turbine: pipe steam into the intake side; the roof stud sparks output wire" }
R.ITEMS.WIRECOIL = { col = { 200, 120, 60 }, desc = "Wire coil: hold right mouse and drag to lay a continuous conductive line" }
R.ITEMS.LAMPKIT = { col = { 255, 230, 120 }, desc = "Lamp: lights only on direct contact with a sparked wire, and only while its grid has power" }
R.ITEMS.DOORKIT = { col = { 150, 150, 160 }, desc = "Powered door: spark its control pad to raise it" }
R.ITEMS.PUMPKIT = { col = { 90, 140, 200 }, desc = "Water pump: powered pad drags water from intake to outlet" }
R.ITEMS.CONVEYOR = { col = { 120, 100, 80 }, desc = "Conveyor belt: pushes loose powder/sand sideways" }
R.ITEMS.CRATE = { col = { 110, 80, 50 }, desc = "Storage crate: right-click to store/retrieve items" }
R.ITEMS.CRANKKIT = { col = { 160, 120, 70 }, desc = "Hand crank: hold F beside it to generate a few real watts while you turn it" }
R.ITEMS.WHEELKIT = { col = { 120, 160, 200 }, desc = "Water wheel: place its open face into flowing water; output scales with real current speed" }
R.ITEMS.SOLARKIT = { col = { 90, 130, 220 }, desc = "Solar panel: needs open sky; output follows the real day/night cycle" }
R.ITEMS.TEGKIT = { col = { 60, 170, 110 }, desc = "Thermoelectric generator: place its exposed face against something genuinely hot" }
R.ITEMS.BATTERYKIT = { col = { 200, 60, 60 }, desc = "Battery bank: stores surplus grid power, discharges when generation drops" }
R.ITEMS.CAPACITORKIT = { col = { 220, 220, 255 }, desc = "Capacitor: small fast-charging buffer for burst loads" }
R.ITEMS.EFURNACE = { col = { 200, 90, 60 }, desc = "Electric furnace: smelts raw ore from your bag with no fire, while powered" }
R.ITEMS.CRUSHERKIT = { col = { 130, 130, 140 }, desc = "Ore crusher: crushes coal into coal dust two-for-one, while powered" }
R.ITEMS.AUTOCRAFTKIT = { col = { 150, 170, 220 }, desc = "Autocrafter: turns a nearby crate's raw ore into bars on its own, while powered" }
R.ITEMS.TURRETKIT = { col = { 180, 60, 60 }, desc = "Defence turret: fires at hostiles in range on its own, while powered" }
R.ITEMS.TURRETKIT2 = { col = { 255, 80, 40 }, desc = "Heavy turret: longer range and heavier hits - reactor-tier" }
R.ITEMS.DRILLKIT = { col = { 140, 140, 160 }, desc = "Mining drill: auto-mines whatever sits ahead of it, while powered" }
R.ITEMS.REACTORKIT = { col = { 70, 200, 90 }, desc = "Fission reactor: end-game generator - real UO2/B4C/NAK/TRBN chain" }
R.ITEMS.AIRPUMPKIT = { col = { 180, 210, 255 }, desc = "Air pump: drives real air along a duct, registers as an oxygen source" }
R.ITEMS.LIFESUPPORTKIT = { col = { 140, 235, 200 }, desc = "Life support: in a SEALED powered room it holds the air up and slowly restocks your food and water while you're inside" }
R.ITEMS.O2GENKIT = { col = { 150, 220, 255 }, desc = "Oxygen generator: electrolyses a WATR charge into real OXYG + HYGN" }
R.ITEMS.SCRUBBERKIT = { col = { 100, 140, 140 }, desc = "CO/CO2 scrubber: kills real CO2/smoke and registers into R.scrubbers" }
R.ITEMS.VENTFANKIT = { col = { 160, 180, 200 }, desc = "Ventilation fan: vents ambient CO/CO2 (R.scrubbers) and pushes heavy gas along a duct" }
R.ITEMS.GREENHOUSEKIT = { col = { 120, 220, 140 }, desc = "Greenhouse: real plants behind glass add oxygen by daylight, no power needed" }
R.ITEMS.SAWMILLKIT = { col = { 160, 120, 70 }, desc = "Sawmill: pyrolyses wood from your bag into real charcoal" }
R.ITEMS.DESALKIT = { col = { 90, 160, 200 }, desc = "Desalinator: turns real SLTW into WATR + SALT" }
R.ITEMS.BLASTFURNACEKIT = { col = { 220, 100, 50 }, desc = "Blast furnace: hotter/faster smelting, handles uranium ore directly" }
R.ITEMS.RTGKIT = { col = { 90, 200, 130 }, desc = "RTG: sealed UO2 pellet, always-on trickle power, no grid needed" }
R.ITEMS.FLYWHEELKIT = { col = { 200, 180, 120 }, desc = "Flywheel: a real spinning mass, fast-answering storage" }
R.ITEMS.BREAKERKIT = { col = { 200, 200, 210 }, desc = "Breaker: snaps the wire on overload, right-click to reset" }
R.ITEMS.ELEVATORKIT = { col = { 150, 150, 160 }, desc = "Item elevator: powered shaft lifts loose material straight up" }
R.ITEMS.TUNNELERKIT = { col = { 140, 140, 150 }, desc = "Tunneler: an auto-miner that advances forward while powered" }
R.ITEMS.SPRINKLERKIT = { col = { 120, 170, 220 }, desc = "Sprinkler: sprays real water on fire in range while powered" }
R.ITEMS.LIGHTNINGKIT = { col = { 210, 210, 255 }, desc = "Lightning rod: trickles bonus power during a real storm" }
R.ITEMS.GASTURBINEKIT = { col = { 200, 150, 90 }, desc = "Gas turbine: burns real HYGN/OIL/GAS for power" }
R.ITEMS.BELLOWSKIT = { col = { 150, 110, 70 }, desc = "Bellows: hold F beside it to hand-pump your air bladder and a short duct" }
R.ITEMS.AIRLINEKIT = { col = { 130, 150, 170 }, desc = "Air line: drag to lay a real duct that feeds oxygen along its intact length" }
R.ITEMS.COMPRESSORKIT = { col = { 100, 160, 200 }, desc = "Compressor: compresses real air straight into a bladder or Oxygen Tank" }
R.ITEMS.WINDKIT = { col = { 210, 220, 210 }, desc = "Wind turbine: real 3-blade mast, needs open sky, storm-boosted" }
R.ITEMS.SOLARFURNACEKIT = { col = { 230, 200, 100 }, desc = "Solar furnace: no power - a concentrator lens smelts ore by real daylight" }
R.ITEMS.FLAREKIT = { col = { 200, 120, 60 }, desc = "Flare stack: no power - safely burns off real gas buildup" }
R.ITEMS.GEOTAPKIT = { col = { 90, 200, 150 }, desc = "Geothermal tap: 3-cell TEG array for a real lava/hot-rock face" }
R.ITEMS.METHANECAPKIT = { col = { 140, 180, 90 }, desc = "Methane capture: burns real ambient swamp methane for power" }
R.ITEMS.GASDETECTORKIT = { col = { 220, 200, 80 }, desc = "Gas detector: no power - warns of real CO2/smoke/methane nearby" }
R.ITEMS.LEADSHIELDKIT = { col = { 90, 90, 105 }, desc = "Lead shielding panel: real gamma-shielding wall block" }
R.ITEMS.FUELCELLKIT = { col = { 120, 200, 220 }, desc = "Fuel cell: combines real HYGN + OXYG into power and water" }

local function need(...)
  local t = {}; local args = { ... }
  for k = 1, #args, 2 do t[args[k]] = (t[args[k]] or 0) + args[k + 1] end
  return t
end
local BASE_RECIPES = {
  { out = "BOILER", n = 1, need = need("BRCK", 16, "COAL", 6), st = "workbench", txt = "Boiler kit",
    desc = "Brick firebox with a 2-row coal bed and a hollow water chamber open at the top. Pour water in with the bucket, then light the coal with the torch (same trick as the furnace). Real heat turns the water to WTRV steam once it crosses 100C, and the steam finds the side vent under its own pressure - pipe that into a turbine." },
  { out = "TURBINE", n = 1, need = need(WMAT, 4, "METL", 4), st = "anvil", txt = "Steam turbine",
    desc = "Steam entering the intake crosses three " .. nice(WMAT) .. " blades in the throat; every impact cools the steam back to water and taps a spark out through the roof stud - the same mechanical-to-electrical conversion a real turbine performs, modeled by hand here instead of true blade torque. Every impact also feeds the power grid's wattage reading." },
  { out = "WIRECOIL", n = 10, need = need(WMAT, 2), st = "workbench", txt = "Wire coil (" .. nice(WMAT) .. ")",
    desc = "Hold right mouse and drag to lay a solid, unbroken strand of " .. nice(WMAT) .. ". Real conductors need direct contact - a single 1px gap silently kills a run - so this pours a continuous line instead of a scattered blob. Conducts SPRK exactly like solid " .. nice(WMAT) .. ", and is what the power grid flood-fills across to find which machines share a grid." },
  { out = "LAMPKIT", n = 2, need = need("GLAS", 2, WMAT, 1), st = "workbench", txt = "Lamp (" .. nice(LAMPEL) .. ")",
    desc = "A " .. nice(LAMPEL) .. " cell that lights only on direct contact with a sparked conductor - a 1px gap leaves it fully dark, so butt your wire straight up against it. Draws a small 2W and only lights when its grid is actually generating enough to cover it." },
  { out = "DOORKIT", n = 1, need = need("METL", 10, "WOOD", 4), st = "workbench", txt = "Powered door",
    desc = "A solid metal slab blocking the gap. Spark the control pad beside it and the slab lifts clear; let the spark fade and it drops back to seal the passage. Real TPT pistons are twitchy, so this door is our own logic - blocks vanish and reappear rather than sliding, functionally a solenoid gate. Needs its grid to actually have the 4W spare." },
  { out = "PUMPKIT", n = 1, need = need("METL", 6, WMAT, 2), st = "anvil", txt = "Water pump",
    desc = "Powering the pad on top makes the pump drag one WATR particle at a time from the intake mark on its left out through the outlet on its right - a hand-scripted impeller, since TPT has no native pressure-pump force field. 6W draw." },
  { out = "CONVEYOR", n = 1, need = need("BMTL", 6), st = "workbench", txt = "Conveyor belt",
    desc = "A strip of scrap-metal rollers. Loose material sitting on top gets its sideways speed set every frame, so sand, coal and ore ride along automatically - it only pushes powders/dust, so a placed block just sits on top." },
  { out = "CRATE", n = 1, need = need("WOOD", 12), st = "workbench", txt = "Storage crate",
    desc = "Right-click it to open a small panel that moves items between your bag and the crate's own hold. Pure bookkeeping, same as a chest - it doesn't touch the physics engine at all." },
  { out = "ZIRC", n = 2, need = need("STEL", 2, "SAND", 2), st = "furnace", txt = "Zirconium cladding",
    desc = "Zircaloy-style cladding for reactor fuel: neutron-transparent, conducts heat well, keeps UO2 sealed. Needed for the reactor lattice." },
  { out = "GRPH", n = 2, need = need("COAL", 6), st = "furnace", txt = "Graphite moderator",
    desc = "Coal pressure-baked into graphite - the same pyrolysis real graphite electrodes are made by. Passes neutrons through while carrying heat away fast (140 W/mK), used as the reactor's moderator floor." },
  { out = "NAK", n = 4, need = need("GOLD", 1, "CU", 3), st = "anvil", txt = "Liquid sodium coolant",
    desc = "Electrolytically reduced sodium metal (the real industrial process), kept liquid - 140 W/mK, the reactor's primary coolant loop." },
  { out = "LEAD", n = 2, need = need("IRON", 3, "COAL", 2), st = "furnace", txt = "Lead shielding bar",
    desc = "Dense, real gamma-shielding lead (35 W/mK, melts at only 327C - keep it off the hot side of anything). Flagged by the progression research doc as missing before uranium is fair; now craftable." },
  { out = "CNCR", n = 4, need = need("SAND", 4, "STNE", 4), st = "workbench", txt = "Reactor concrete",
    desc = "Heavy shielding concrete (1.5 W/mK, non-conductive) - the containment shell material for the TEG housing and the reactor." },
  { out = "CRANKKIT", n = 1, need = need("WOOD", 6, "METL", 2), st = "workbench", txt = "Hand crank generator",
    desc = "Tier-0 generator: a geared handle you turn yourself. No fuel, no wiring beyond the output stud - just hold F beside it. Real hand-crank generators work exactly this way." },
  { out = "WHEELKIT", n = 1, need = need("WOOD", 10, "METL", 4), st = "workbench", txt = "Water wheel",
    desc = "Paddles that sample the real speed of adjacent WATR particles - place it in an actual current or waterfall, not still water, or it reads zero." },
  { out = "SOLARKIT", n = 1, need = need("GLAS", 6, "PSCN", 2, "CU", 2), st = "anvil", txt = "Solar panel",
    desc = "PSCN-backed glass panel. Reads the same day/night sun-angle formula the sky already uses, and needs a clear column of open air above it or it produces nothing." },
  { out = "TEGKIT", n = 1, need = need("TEG", 2, "CNCR", 2), st = "anvil", txt = "Thermoelectric generator",
    desc = "A concrete housing exposing two real TEG faces. TEG already pulses SPRK into conductors once it crosses 100C (power_kinds.lua) - this just gives it a mount and a wire stud. Sit its hot face against lava or a fire." },
  { out = "BELLOWSKIT", n = 1, need = need("WOOD", 8), st = "hand", txt = "Bellows",
    desc = "A cheap hand-operated pump, no power needed. Stand next to it and hold F - it refills a carried air bladder (FLASK) fast and pushes real OXYG down its short duct, exactly what a shallow early dig needs before any generator exists." },
  { out = "AIRLINEKIT", n = 10, need = need("BMTL", 2), st = "workbench", txt = "Air line",
    desc = "Hold right mouse and drag to lay a real duct, the same continuous-line trick WIRECOIL uses for wire. Every intact stretch of it registers as a real oxygen source along its length - and a segment that gets mined out or blown up genuinely cuts the air off beyond that point, not just a flag." },
  { out = "WINDKIT", n = 1, need = need("METL", 8, "BMTL", 3), st = "anvil", txt = "Wind turbine",
    desc = "A mast with 3 real blades. Needs open sky on the surface - reads 0 the moment anything is built over it - and spins harder for real during a storm (R.weather.rain), on top of a steady baseline breeze." },
  { out = "SOLARFURNACEKIT", n = 1, need = need("GLAS", 6, "BRCK", 4), st = "workbench", txt = "Solar furnace",
    desc = "No power needed. A real concentrator lens on top focuses daylight to smelt ore straight from your bag - only works at day > 40% brightness, same real sun-angle formula every solar device here uses." },
  { out = "FLAREKIT", n = 1, need = need("METL", 6), st = "workbench", txt = "Flare stack",
    desc = "No power needed. A tall open flue that quietly burns off real HYGN/GAS reaching its base and vents a little ambient swamp methane nearby - the safety valve for a base running an electrolyser or sitting over gas pockets." },
  { out = "GASDETECTORKIT", n = 1, need = need("METL", 2, "LEDL", 1), st = "workbench", txt = "Gas detector",
    desc = "No power needed. Watches real CO2/smoke right next to it and the real ambient methane level (R.gas.ch4) near the player, and blinks + warns when either crosses a dangerous real threshold." },
  { out = "LEADSHIELDKIT", n = 2, need = need("LEAD", 4), st = "anvil", txt = "Lead shielding panel",
    desc = "A placeable wall of real 35 W/mK lead. Keep it between yourself and a uranium vein or an active reactor - LEAD is the real gamma-shielding material here, and this makes it a build-able panel instead of only a raw bar." },
}
local TIER10_RECIPES = {
  { out = "COMPRESSORKIT", n = 1, need = need("STEL", 8, "CU", 4, "PSCN", 2), st = "anvil", txt = "Compressor",
    desc = "Unlocked at 10W generated. Powered, standing close with a bladder or an Oxygen Tank (@items' OXYTANK) equipped, it pulls in a real nearby OXYG particle and compresses it straight into whichever one you're carrying - the fast, portable top-up station the electrolyser/air-line chain feeds into." },
  { out = "EFURNACE", n = 1, need = need("STEL", 6, "PSCN", 2, "CU", 2), st = "anvil", txt = "Electric furnace",
    desc = "Unlocked at 10W generated. Smelts ore straight out of your bag with resistive heat instead of fire, while its grid is powered." },
  { out = "BATTERYKIT", n = 1, need = need("LEAD", 2, "CU", 2, "GOO", 4), st = "anvil", txt = "Battery bank",
    desc = "Unlocked at 10W generated. A lead-acid-style cell (real chemistry) that stores 200 units of grid surplus and discharges it back when generation drops." },
  { out = "AIRPUMPKIT", n = 1, need = need("STEL", 4, "CU", 2), st = "anvil", txt = "Air pump",
    desc = "Unlocked at 10W generated. Powered, it drives real air along its duct and registers as an oxygen source - the first line of defence in a sealed base now that air actually thins with depth." },
  { out = "GREENHOUSEKIT", n = 1, need = need("GLAS", 8, "WOOD", 4, "PLNT", 2), st = "workbench", txt = "Greenhouse",
    desc = "Unlocked at 10W generated (needs no power itself). Real living plants behind glass photosynthesise by daylight and add fresh oxygen to a nearby sealed room - a passive, renewable life-support layer." },
  { out = "SCRUBBERKIT", n = 1, need = need("STEL", 4, "COAL", 4), st = "anvil", txt = "CO2 scrubber",
    desc = "Unlocked at 10W generated. Powered, kills real CO2/smoke in range and registers into R.scrubbers to pull down ambient CO/CO2 near you - smelting and fires both dump exactly these gases." },
  { out = "VENTFANKIT", n = 1, need = need("METL", 4, "STEL", 2, "CU", 1), st = "workbench", txt = "Ventilation fan",
    desc = "Unlocked at 10W generated. Powered, registers into R.scrubbers (wider but gentler than a scrubber) and pushes real CO2/smoke along its duct - the passive fix for a sealed room with a fire or smelter." },
  { out = "SAWMILLKIT", n = 1, need = need("WOOD", 10, "METL", 2), st = "workbench", txt = "Sawmill",
    desc = "Unlocked at 10W generated. Powered, it pyrolyses raw wood from your bag into real charcoal (same fuel-from-wood chemistry a real charcoal kiln uses) - the first automation loop that turns your forest home base into an ongoing fuel supply." },
}
local TIER100_RECIPES = {
  { out = "LIFESUPPORTKIT", n = 1, need = need("STEL", 8, "CU", 4, "GLAS", 4, "ZIRC", 2), st = "advlab", txt = "Life support",
    desc = "Advanced Lab tier. Powered, inside a genuinely SEALED room, it holds the air up and slowly restocks your food and water while you are inside - a real reason to build an enclosed base, and a real standing sink for late-game power." },
  { out = "CRUSHERKIT", n = 1, need = need("STEL", 8, "METL", 4), st = "anvil", txt = "Ore crusher",
    desc = "Unlocked at 100W generated. Crushes 1 coal into 2 coal dust while powered - the Factorio-style payoff for having built real generation." },
  { out = "AUTOCRAFTKIT", n = 1, need = need("STEL", 6, "PSCN", 4, "CU", 4), st = "anvil", txt = "Autocrafter",
    desc = "Unlocked at 100W generated. Build it beside a storage crate: while powered, it turns that crate's raw ore into bars with nobody standing there." },
  { out = "CAPACITORKIT", n = 1, need = need("GLAS", 4, "CU", 4), st = "anvil", txt = "Capacitor",
    desc = "Unlocked at 100W generated. Tiny capacity (40) but charges/discharges fast - smooths burst loads like the turret firing." },
  { out = "TURRETKIT", n = 1, need = need("STEL", 6, "CU", 4, "PSCN", 2), st = "anvil", txt = "Defence turret",
    desc = "Unlocked at 100W generated. Fires at any hostile in range on its own via the same damage hook items.lua's guns use, while powered." },
  { out = "DRILLKIT", n = 1, need = need("STEL", 6, "CU", 2, "QRTZ", 2), st = "anvil", txt = "Mining drill",
    desc = "Unlocked at 100W generated. Auto-mines the block directly ahead of it, one real MINEABLE-tier hit at a time, while powered." },
  { out = "REACTORKIT", n = 1, need = need("UO2", 6, "B4C", 4, "ZIRC", 6, "GRPH", 6, "NAK", 6, "CNCR", 10, "LEAD", 4, "TRBN", 2, "CU", 4), st = "anvil", txt = "Fission reactor",
    desc = "Unlocked at 100W generated - the end-game generator. Places a real UO2/B4C/ZIRC/GRPH lattice, a NAK coolant bath, a steam boiler and a live TRBN turbine bank; going online for the first time unlocks the reactor-tier turret." },
  { out = "O2GENKIT", n = 1, need = need("STEL", 6, "PSCN", 2, "CU", 2), st = "anvil", txt = "Oxygen generator",
    desc = "Unlocked at 100W generated. Powered, real electrolysis splits a WATR charge into real OXYG (breathe it) and HYGN (feed a gas turbine) - the water->power->air->fuel loop a deep sealed base actually needs." },
  { out = "DESALKIT", n = 1, need = need("STEL", 8, "GLAS", 2, "CU", 2), st = "anvil", txt = "Desalinator",
    desc = "Unlocked at 100W generated. Powered, it drags real SLTW in one side and drives real WATR plus a SALT byproduct out the other - turns an ocean/underground brine pocket into a usable water supply for boilers and oxygen generators." },
  { out = "BLASTFURNACEKIT", n = 1, need = need("STEL", 12, "BRCK", 6, "CU", 2), st = "anvil", txt = "Blast furnace",
    desc = "Unlocked at 100W generated. A hotter, faster upgrade over the electric furnace that also handles uranium ore directly - the higher wattage draw is the real cost of the higher throughput." },
  { out = "FLYWHEELKIT", n = 1, need = need("STEL", 4, "METL", 8), st = "anvil", txt = "Flywheel",
    desc = "Unlocked at 100W generated. A real spinning mass instead of a chemical cell - smaller capacity than a battery but answers a sudden load (like a turret volley) instantly, and the rim visibly spins faster the more energy it's holding." },
  { out = "BREAKERKIT", n = 1, need = need("STEL", 3, "PSCN", 2), st = "workbench", txt = "Breaker",
    desc = "Unlocked at 100W generated. Wire it into a run: if that grid's load ever badly outstrips its generation and storage, the breaker's own bridge cell is killed - a real break in the conductor - protecting everything else on the line until you right-click it to reset." },
  { out = "ELEVATORKIT", n = 1, need = need("METL", 16, "PSCN", 2), st = "anvil", txt = "Item elevator",
    desc = "Unlocked at 100W generated. Powered, loose material dropped at its base gets real upward velocity all the way up the shaft - vertical logistics using the same vx-injection trick the conveyor uses sideways." },
  { out = "TUNNELERKIT", n = 1, need = need("STEL", 8, "CU", 2, "METL", 4), st = "anvil", txt = "Tunneler",
    desc = "Unlocked at 100W generated. The mining drill's moving cousin: every successful hit advances it one step further into the rock instead of sitting still, tunnelling a real path while powered." },
  { out = "SPRINKLERKIT", n = 1, need = need("METL", 4, "CU", 1), st = "workbench", txt = "Sprinkler",
    desc = "Unlocked at 100W generated. Powered, it watches its radius for real fire/plasma/anything past 700K and sprays real WATR onto it - genuine fire suppression, not a flag." },
  { out = "LIGHTNINGKIT", n = 1, need = need("METL", 6, "CU", 3), st = "anvil", txt = "Lightning rod",
    desc = "Unlocked at 100W generated. A grounded rod under open sky trickles bonus power for as long as R.weather.rain is actually true - static buildup during a real storm, not a literal lightning-strike particle (none exists in this engine yet)." },
  { out = "GASTURBINEKIT", n = 1, need = need("STEL", 8, "CU", 3), st = "anvil", txt = "Gas turbine",
    desc = "Unlocked at 100W generated. Feed it real HYGN (an oxygen generator's byproduct) or OIL/GAS and it burns the fuel for power - closes the electrolysis-to-power loop the player asked for." },
  { out = "FUELCELLKIT", n = 1, need = need("STEL", 6, "CU", 4, "PSCN", 2), st = "anvil", txt = "Fuel cell",
    desc = "Unlocked at 100W generated. The electrolyser's reverse: one real HYGN + one real OXYG particle in, power and a real WATR droplet out. Feed it from an O2GENKIT's byproduct stream or an air line." },
  { out = "GEOTAPKIT", n = 1, need = need("CNCR", 6, "TEG", 3, "CU", 2), st = "anvil", txt = "Geothermal tap",
    desc = "Unlocked at 100W generated. A 3-cell TEG array in a concrete housing, sized for the hell layer - press its face against real lava or hot rock and it scavenges the heat, the same real physics as TEGKIT scaled up." },
  { out = "METHANECAPKIT", n = 1, need = need("STEL", 6, "CU", 3), st = "anvil", txt = "Methane capture",
    desc = "Unlocked at 100W generated. Draws down the real ambient swamp-methane concentration near you (R.gas.ch4, core's own gas model) and burns it for power - the more of a real methane buildup there is, the more it makes, up to a cap." },
}
local TIERR_RECIPES = {
  { out = "TURRETKIT2", n = 1, need = need("STEL", 10, "CU", 8, "TRBN", 2), st = "anvil", txt = "Heavy turret",
    desc = "Unlocked once a reactor goes online. Longer range, heavier hits - the reward for finishing the power tech tree." },
  { out = "RTGKIT", n = 1, need = need("UO2", 2, "LEAD", 6, "B4C", 2, "TEG", 1, "CU", 1), st = "anvil", txt = "RTG",
    desc = "Unlocked once a reactor goes online - you've proven you can handle fissile material safely. A sealed UO2 pellet's real neutron emission is captured by a tight B4C shell (real heating-per-capture) and read off a touching TEG: always-on power, no day/night, no grid dependency, exactly like a real deep-space RTG." },
  -- ADDED 2026-09-02 (@matimpl, design-material-progression.md S4 chain 6): SHD4 is the top rung of the
  -- Shield ladder (SHLD/SHD2/SHD3 live in rpg.lua's R.RECIPES, reachable at research/advlab tier) -- this
  -- is the one tier the design doc deliberately gates on "reactor online", same shape as TURRETKIT2/RTGKIT
  -- right above, so it installs through this same R.tech.reactor-gated table instead of a raw materials
  -- consumable (PLUT breeding) this pass didn't implement.
  { out = "SHD4", n = 1, need = need("SHD3", 2, "TTAN", 4, "GOLD", 3), st = "advlab", txt = "Shield tier 4",
    desc = "Unlocked once a reactor goes online. The strongest defensive field material in the game -- tempered under sustained reactor heat." },
}
installRecipes = function()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
  local list = {}
  for _, rc in ipairs(BASE_RECIPES) do list[#list + 1] = rc end
  if R.tech.unlock10 then for _, rc in ipairs(TIER10_RECIPES) do list[#list + 1] = rc end end
  if R.tech.unlock100 then for _, rc in ipairs(TIER100_RECIPES) do list[#list + 1] = rc end end
  if R.tech.reactor then for _, rc in ipairs(TIERR_RECIPES) do list[#list + 1] = rc end end
  for _, rc in ipairs(list) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
end

-- ================================================================ tech/power state + lifecycle hooks
R.tech = R.tech or { peakW = 0, unlock10 = false, unlock100 = false, reactor = false }
R.power = R.power or { grids = {} }
installRecipes()
hook(R.hooks.newworld, function()
  -- R.machines MUST be cleared here. It was the only plugin registry that wasn't (machines2.lua:1108
  -- clears R.machines2, vehicles/survival/world/guide all clear theirs), so every machine from the
  -- previous world survived "Create World" at stale coordinates and was executed by every update*
  -- until the off-screen-tolerant reaper eventually collected it. R.machinePanel is nil'd for the
  -- same reason machines2 nils R.machine2Panel: it holds a machine reference and gates R.uiPanelOpen,
  -- so a panel for a machine that no longer exists would stay open over the new world.
  R.machines = {}; R.machinePanel = nil; R.uiPanelOpen = false; R.structSpent = {}
  R.tech = { peakW = 0, unlock10 = false, unlock100 = false, reactor = false }
  R.power = { grids = {} }
  installRecipes()
end)
hook(R.hooks.sandbox, function()
  R.tech.unlock10 = true; R.tech.unlock100 = true; R.tech.reactor = true
  installRecipes(); R.say("SANDBOX: all machine tiers unlocked")
end)

-- per save.lua's convention (hub 13:34): plain-data fields pushed here get generically dumped/restored on
-- save/load. R.machines is already plain data (coords + small kind-specific fields, no raw particle ids).
-- "tech" is pushed too (milestones + all-time peak watts) so unlocks survive a reload. "power" is deliberately
-- NOT pushed: R.power.grids is fully derived (recomputed every 15 frames from R.machines + live wire pixels)
-- and its member lists alias the same tables as R.machines - persisting it would just duplicate/tangle that dump.
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
for _, k in ipairs({ "machines", "tech", "structSpent" }) do
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == k then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, k) end
end

return "ok"
