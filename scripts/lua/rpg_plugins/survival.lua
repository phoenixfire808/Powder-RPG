-- survival.lua - plants, farming, food/cooking, environmental needs and world events (2026-08-26).
-- the player 19:14: "plants and food and environmental needs and different types of events."
-- Owns: R.hooks.tick/draw/drawHUD/place/mousedown/mine/newworld/sandbox tagged "survival", R.farms, R.saplings,
-- R.tanks, R.beds, R.sEvent, R.warmth, R.survSick, R.RECIPES/R.ITEMS/R.NAMES entries for its own items, and
-- fills the core-owned R.FOODS table + wraps core's R.eat/R.spawnPlayer (monkey-patch, not a core file edit).
-- Does not touch any other plugin's file. See knowledge/rpg-ui-atlas.md "Survival" section for exact geometry.
--
-- Design notes (posted to the hub too):
--  * Crops are NOT real particles - they are bookkeeping in R.farms plus a small drawn sprite per stage
--    (the player's brief: "crops mature in stages you draw"). Growth is gated on REAL nearby WATR (wheat) or REAL
--    darkness/no heat source (mushrooms), sampled with sim.partID - which only resolves on-screen, so a plot
--    only grows while the tile is loaded (same constraint every other machine in this project already has).
--  * The Algae Tank is deliberately NOT a duplicate of @machines' GREENHOUSEKIT (daylight, real plants,
--    no power). Mine is the deep-base answer: needs a real nearby FIRE/torch/LEDL (artificial light) instead
--    of sunlight, so it works in total darkness far underground where a daylight greenhouse cannot.
--  * Bed sets a real respawn point by wrapping R.spawnPlayer (core function, extended not edited).

local R = PBX.state.rpg
local TAG = "survival"
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

local floor = math.floor
local W, H = R.W, R.H
local eid, nameOf, has, say = R.eid, R.nameOf, R.has, R.say
local solidW, surfaceAt, biomeAt = R.solidW, R.surfaceAt, R.biomeAt

-- ================================================================ persistent state
R.farms    = R.farms    or {}   -- {wx, wy, kind="soil"|"cave", crop=nil|"wheat"|"mushroom", stage, prog}
R.saplings = R.saplings or {}   -- {wx, wy, t0}
R.tanks    = R.tanks    or {}   -- {wx, wy, on=false} algae tanks (registers into R.o2Sources)
R.beds     = R.beds     or {}   -- {wx, wy}
R.warmth   = R.warmth   or 100  -- 0-100 comfort meter (cold side of temperature; heat side reuses R.gas.heat)
R.survSick = R.survSick or nil  -- frame until which the player is ill from bad food/water
R.sEvent   = R.sEvent   or nil  -- {key, phase="warn"|"active", t0, warnFor, activeFor, data={}}
-- Needs toggle (2026-09-01, PhoenixFire808: "for now I think I want to turn off the thirst and
-- all that.") "For now" is explicit -- a toggle, not a deletion. rpg.lua's need-drain tick (not
-- this file -- rpg.lua is a different lane's file this wave, see knowledge/rpg-hub.md 2026-09-01
-- @foliage for the exact one-hunk edit specified and routed) is the only place that should ever
-- read this table; this file just owns the state + a way to flip it today. Default thirst=false
-- (off) because that is the one need he actually named. hunger defaults ON (true, not left to
-- infer from nil) -- asked rather than guessed whether "and all that" covers it too.
R.survivalNeeds = R.survivalNeeds or { thirst = false, hunger = true }
for _, k in ipairs({ "farms", "saplings", "tanks", "beds", "warmth", "survSick", "sEvent", "survivalNeeds", "need", "gas" }) do
  R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
  local seen = false; for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == k then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, k) end
end

-- ================================================================ friendly names
for k, v in pairs({
  SEED="Seeds", SPORE="Mushroom Spore", SAPLING="Sapling", WHEAT="Wheat",
  BERRY="Berries", ROOT="Root Vegetable", MSHRM="Wild Mushroom", FISH="Raw Fish",
  CLEANWATER="Clean Water", DIRTYWATER="Dirty Water", BOILEDWATER="Boiled Water",
  CFISH="Cooked Fish", CMSHRM="Roasted Mushroom", STEW="Hearty Stew", BREAD="Bread",
  SOIL="Tilled Soil", ALGAETANK="Algae Tank", BED="Bed", CANTEEN="Canteen",
  WARMCOAT="Insulated Coat", COOLSUIT="Cooling Wrap",
}) do R.NAMES[k] = v end

-- ================================================================ R.ITEMS (palette colours + descriptions)
R.ITEMS.SOIL       = { col = { 90, 60, 40 },   desc = "Place on solid ground to till it. Plant Seeds or Spores on a tilled patch." }
R.ITEMS.ALGAETANK  = { col = { 60, 160, 120 }, desc = "Deep-base O2 farm: needs a real light source (torch/lamp/fire) nearby and a WATR charge inside. Registers as an oxygen source, unlike a sunlit greenhouse this works in total darkness." }
R.ITEMS.BED        = { col = { 150, 60, 70 },  desc = "Right/left-click at night to sleep: skips to morning, heals a little, and sets this as your respawn point." }
R.ITEMS.CANTEEN    = { col = { 140, 140, 150 },desc = "Right-click real water to fill it: clean WATR gives Clean Water, anything else gives Dirty Water. Reusable." }
R.ITEMS.WARMCOAT   = { col = { 150, 90, 60 },  desc = "Worn passively (owned = active). Halves cold drain in snow biomes and ice caves." }
R.ITEMS.COOLSUIT   = { col = { 90, 160, 190 }, desc = "Worn passively (owned = active). Halves heat drain from deep zones, desert sun and heat waves." }

-- ================================================================ R.RECIPES
local RC = R.RECIPES
local function add(rc) RC[#RC + 1] = rc end
add{ out="SOIL",    n=4, need={GOO=6},              st="hand",      txt="Tilled Soil x4", desc="Till a patch of ground for farming" }
add{ out="ALGAETANK",n=1,need={GLAS=6, WATR=4},     st="workbench", txt="Algae Tank",      desc="An underground O2 farm - light it with a torch/lamp and keep it filled" }
add{ out="BED",     n=1, need={WOOD=12},            st="hand",      txt="Bed",             desc="Sleep, heal a little, set your respawn point" }
add{ out="CANTEEN", n=1, need={METL=2},             st="workbench", txt="Canteen",         desc="Fill from real water; boil dirty water at a lit furnace" }
add{ out="WARMCOAT",n=1, need={INSL=4, WOOD=2},     st="workbench", txt="Insulated Coat",  desc="Cold-weather insulation" }
add{ out="COOLSUIT",n=1, need={INSL=4, CU=2},       st="workbench", txt="Cooling Wrap",    desc="Heat-resistant wrap" }
-- cooking (needs a real lit furnace, same nearStation("furnace") gate as every other smelt recipe)
add{ out="CFISH",   n=1, need={FISH=1},             st="furnace",   txt="Cooked Fish",     desc="Cooking kills the risk of raw fish" }
add{ out="CMSHRM",  n=1, need={MSHRM=1},            st="furnace",   txt="Roasted Mushroom",desc="Cooking kills the risk of raw mushroom" }
add{ out="STEW",    n=1, need={BERRY=1, ROOT=1, FISH=1}, st="furnace", txt="Hearty Stew",  desc="A full meal - big food+water and a small heal" }
add{ out="BREAD",   n=1, need={WHEAT=2},            st="furnace",   txt="Bread",           desc="Baked wheat - the payoff for a farm" }
add{ out="BOILEDWATER", n=1, need={DIRTYWATER=1},   st="furnace",   txt="Boiled Water",    desc="Boiling purifies dirty/salt water" }

-- ================================================================ R.FOODS (food/water/heal) + illness table
for k, v in pairs({
  BERRY       = { food = 10, water = 3 },
  ROOT        = { food = 8,  water = 0 },
  MSHRM       = { food = 6,  water = 0 },
  FISH        = { food = 5,  water = 0 },
  CLEANWATER  = { food = 0,  water = 25 },
  DIRTYWATER  = { food = 0,  water = 15 },
  BOILEDWATER = { food = 0,  water = 25 },
  CFISH       = { food = 22, water = 2,  heal = 2 },
  CMSHRM      = { food = 16, water = 0,  heal = 1 },
  STEW        = { food = 45, water = 20, heal = 8 },
  BREAD       = { food = 30, water = 5,  heal = 3 },
}) do R.FOODS[k] = v end
local ILLNESS = { BERRY = 0.08, ROOT = 0.05, MSHRM = 0.12, FISH = 0.15, DIRTYWATER = 0.20 }

-- wrap core's R.eat: (a) right-click a food item to eat it (wired below via the place hook), (b) risk of illness
-- from raw/unclean items, on top of core's plain need/heal bookkeeping.
-- Idempotent guard: R persists across hot-reload, so stash the pristine core fn once (hub §0c).
local U = R._survival or {}; R._survival = U
U.coreEat = U.coreEat or R.eat
function R.eat(item)
  local ok = U.coreEat(item)
  if ok and ILLNESS[item] and not R.sandbox and math.random() < ILLNESS[item] then
    R.survSick = R.frame + 1200
    say("That did not sit right - you feel sick")
  end
  return ok
end

-- wrap core's R.spawnPlayer so a placed Bed becomes a real respawn point without editing rpg.lua
U.coreSpawn = U.coreSpawn or R.spawnPlayer
function R.spawnPlayer()
  if R.bedRespawn then
    R.P.x, R.P.y = R.bedRespawn.x, R.bedRespawn.y; R.P.vx, R.P.vy = 0, 0; R.hp = math.max(R.hp or 0, 40); R._resetSpawnState(); R._teleportCompanionAndClear()   -- F5 + F9: shared pollution reset, then F1 companion teleport + F8 clearAround (otherwise bed-respawn strands the companion and leaves the BLD pool at the spawn point)
  else
    U.coreSpawn()
  end
end

-- ================================================================ low-level build helpers (same pattern as machines.lua)
local function setAt(wx, wy, elName)
  local t = eid(elName); if not t then return nil end
  local cx, cy = wx - R.cam.x, wy - R.cam.y
  local p = sim.partID(cx, cy); if p then sim.partKill(p) end
  return sim.partCreate(-1, cx, cy, t)
end
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function boxFill(x1, y1, x2, y2, el) for y = y1, y2 do for x = x1, x2 do setAt(x, y, el) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
local function onScreen(wx, wy) local cx, cy = wx - R.cam.x, wy - R.cam.y; return cx > -8 and cx < W + 8 and cy > -8 and cy < H + 8 end
local function dist2(x1, y1, x2, y2) local dx, dy = x1 - x2, y1 - y2; return dx*dx + dy*dy end

-- a real particle of any of `names` within radius r of world point (wx,wy); on-screen only (engine limit)
local function nearReal(wx, wy, r, names)
  if not onScreen(wx, wy) then return false end
  for oy = -r, r, 3 do for ox = -r, r, 3 do
    local p = sim.partID(wx + ox - R.cam.x, wy + oy - R.cam.y)
    if p then local n = nameOf(sim.partProperty(p, "type")); if names[n] then return true end end
  end end
  return false
end
local LIGHT = { FIRE=1, PLSM=1, LAVA=1, LEDL=1, LCRY=1, GLOW=1 }
local WATERY = { WATR=1, DSTW=1 }
local function hasOpenSky(wx, wy, cap) for k = 1, (cap or 260), 4 do if solidW(wx, wy - k) then return false end end; return true end

-- Bonus forage drops append to R.hint. Each drop used to append its own bare
-- "  +Sapling" with no count, so a single axe swing that yields dozens of
-- saplings produced one line repeating "+Sapling" ~47 times (captured live).
-- Stack per frame instead, so it reads "+47 Sapling" -- matching how the core
-- mining hint already reports "+7 Wood". Fixed here, at the one point all six
-- drop paths route through, rather than patching each call site.
local bFrame, bCount, bSuffix = -1, {}, ""
local function bonus(item, label)
  R.give(item, 1)
  if R.frame ~= bFrame then bFrame, bCount, bSuffix = R.frame, {}, "" end
  -- remove the suffix this helper appended earlier in the same frame, then
  -- rebuild it with the updated counts (leaves any other hint text intact)
  if bSuffix ~= "" and R.hint and R.hint:sub(-#bSuffix) == bSuffix then
    R.hint = R.hint:sub(1, #R.hint - #bSuffix)
  end
  bCount[label] = (bCount[label] or 0) + 1
  local parts = {}
  for k, v in pairs(bCount) do parts[#parts + 1] = "+" .. v .. " " .. k end
  table.sort(parts)
  bSuffix = "  " .. table.concat(parts, "  ")
  R.hint = (R.hint or "") .. bSuffix
end

-- ================================================================ FORAGING: mining wild flora/wood/water gives raw food
hook(R.hooks.mine, function(el, n)
  if not R.P then return end
  local depth = R.P.y - surfaceAt(floor(R.P.x))
  if el == "GRSS" or el == "PLNT" then
    local roll = math.random()
    if depth <= 4 then
      if roll < 0.10 then bonus("SEED", "Seeds")
      elseif roll < 0.22 then bonus("BERRY", "Berries") end
    else
      if roll < 0.06 then bonus("SPORE", "Spore")
      elseif roll < 0.16 then bonus("MSHRM", "Mushroom") end
    end
  elseif el == "GOO" and depth <= 8 and math.random() < 0.06 then
    bonus("ROOT", "Root")
  elseif el == "WOOD" and math.random() < 0.10 then
    bonus("SAPLING", "Sapling")
  end
end)

-- passive fishing: standing at the edge of a real body of water occasionally lands a fish (throttled, cheap)
hook(R.hooks.tick, function()
  if not R.P or R.frame % 240 ~= 0 or R.sandbox then return end
  local px, py = floor(R.P.x), floor(R.P.y)
  if nearReal(px, py, 10, WATERY) and math.random() < 0.20 then
    R.give("FISH", 1); say("A fish jumps into your hands"); R.rebuildHotbar()
  end
end)

-- ================================================================ PLACE HOOK: everything the player interacts with
hook(R.hooks.place, function(el, mx, my, fine)
  local wx, wy = mx + R.cam.x, my + R.cam.y

  -- right-click a food/drink item = eat/drink it instead of trying to place it
  if R.FOODS[el] then R.eat(el); return true end

  if el == "SOIL" then
    if not solidW(wx, wy + 1) then R.hint = "till it on top of solid ground"; return true end
    for _, f in ipairs(R.farms) do if dist2(f.wx, f.wy, wx, wy) < 36 then R.hint = "already tilled here"; return true end end
    R.inventory.SOIL = R.inv("SOIL") - 1
    R.farms[#R.farms + 1] = { wx = wx, wy = wy, kind = "soil", crop = nil, stage = -1, prog = 0 }
    say("Tilled a patch - plant Seeds here and keep real water nearby"); R.rebuildHotbar(); return true
  end

  if el == "SEED" or el == "SPORE" then
    if el == "SEED" then
      for _, f in ipairs(R.farms) do if f.kind == "soil" and not f.crop and dist2(f.wx, f.wy, wx, wy) < 100 then
        R.inventory.SEED = R.inv("SEED") - 1; f.crop = "wheat"; f.stage = 0; f.prog = 0
        say("Planted wheat - it needs real water nearby to grow"); R.rebuildHotbar(); return true end end
      R.hint = "plant Seeds on a tilled patch (Tilled Soil)"; return true
    else
      if not solidW(wx, wy + 1) or hasOpenSky(wx, wy, 120) then R.hint = "mushrooms need a dark, solid underground spot"; return true end
      for _, f in ipairs(R.farms) do if dist2(f.wx, f.wy, wx, wy) < 100 then R.hint = "too close to another plot"; return true end end
      R.inventory.SPORE = R.inv("SPORE") - 1
      R.farms[#R.farms + 1] = { wx = wx, wy = wy, kind = "cave", crop = "mushroom", stage = 0, prog = 0 }
      say("Planted a mushroom spore - keep it dark and away from fire"); R.rebuildHotbar(); return true
    end
  end

  if el == "SAPLING" then
    if not solidW(wx, wy + 1) then R.hint = "plant a sapling on solid ground"; return true end
    R.inventory.SAPLING = R.inv("SAPLING") - 1
    R.saplings[#R.saplings + 1] = { wx = wx, wy = wy, t0 = R.frame }
    say("Planted a sapling - it will regrow into a tree"); R.rebuildHotbar(); return true
  end

  if el == "ALGAETANK" then
    local gy = groundY(wx, wy)
    R.inventory.ALGAETANK = R.inv("ALGAETANK") - 1
    clearBox(wx, gy - 9, wx + 6, gy - 1)
    boxFill(wx, gy - 9, wx + 6, gy - 1, "GLAS")
    clearBox(wx + 1, gy - 8, wx + 5, gy - 2)
    boxFill(wx + 1, gy - 8, wx + 5, gy - 2, "WATR")
    R.tanks[#R.tanks + 1] = { wx = wx + 3, wy = gy - 5, on = false }
    say("Algae tank built - light it with a torch/lamp nearby to start producing oxygen"); return true
  end

  if el == "BED" then
    local gy = groundY(wx, wy)
    R.inventory.BED = R.inv("BED") - 1
    boxFill(wx, gy - 1, wx + 7, gy - 1, "WOOD")
    boxFill(wx, gy - 3, wx + 1, gy - 2, "WOOD")
    boxFill(wx + 2, gy - 2, wx + 7, gy - 2, "CLST")
    R.beds[#R.beds + 1] = { wx = wx, wy = gy - 3 }
    say("Bed built - use it at night to sleep"); return true
  end

  if el == "CANTEEN" then
    if (R.frame - (R.survLastCanteen or -99)) < 15 then return true end; R.survLastCanteen = R.frame
    local p = sim.partID(mx, my); local nm = p and nameOf(sim.partProperty(p, "type"))
    if nm == "WATR" then R.give("CLEANWATER", 1); R.hint = "filled: Clean Water"
    elseif nm == "DSTW" or nm == "SLTW" then R.give("DIRTYWATER", 1); R.hint = "filled: Dirty Water (boil before drinking)"
    else R.hint = "canteen: aim at real water" end
    R.rebuildHotbar(); return true
  end
  return false
end)

-- harvesting a mature farm plot: left or right click near it
hook(R.hooks.mousedown, function(x, y, button)
  if R.uiPanelOpen or R.invOpen or R.menuOpen or not R.P then return false end
  local wx, wy = x + R.cam.x, y + R.cam.y
  for _, f in ipairs(R.farms) do
    if f.crop and f.stage and f.stage >= 3 and dist2(f.wx, f.wy, wx, wy) < 64 and dist2(f.wx, f.wy, R.P.x, R.P.y) < 40*40 then
      if f.crop == "wheat" then
        R.give("WHEAT", 2 + floor(math.random() * 2)); say("Harvested wheat"); f.stage = 0; f.prog = 0
        if math.random() < 0.4 then R.give("SEED", 1) end
      elseif f.crop == "mushroom" then
        R.give("MSHRM", 2 + floor(math.random() * 2)); say("Harvested mushrooms")
        for i = #R.farms, 1, -1 do if R.farms[i] == f then table.remove(R.farms, i) end end
      end
      R.rebuildHotbar(); return true
    end
  end
  -- sleep in a bed at night
  for _, b in ipairs(R.beds) do if dist2(b.wx, b.wy, wx, wy) < 100 and dist2(b.wx, b.wy, R.P.x, R.P.y) < 40*40 then
    local phase = ((R.frame or 0) % 14000) / 14000
    local night = math.max(0, math.sin((phase - 0.5) * math.pi * 2))
    if night <= 0.15 then R.hint = "not sleepy yet - try at night"; return true end
    R.bedRespawn = { x = b.wx, y = b.wy - 4 }
    R.frame = R.frame - (R.frame % 14000) + 14000 - 1
    R.hp = math.min(100, (R.hp or 100) + 20); R.need.food = math.min(100, R.need.food + 5)
    say("You sleep through the night - respawn point set here"); return true
  end end
  return false
end)

-- ================================================================ TICK: farms, saplings, tanks, warmth, illness
local function farmDraw(f)
  local cx, cy = f.wx - R.cam.x, f.wy - R.cam.y
  if cx < -4 or cx > W + 4 or cy < -4 or cy > H + 4 then return end
  if f.stage == -1 then graphics.fillRect(cx - 2, cy - 1, 5, 1, 90, 60, 40, 220); return end
  if f.crop == "wheat" then
    local col = { {70,130,60}, {90,160,70}, {150,190,70}, {225,205,70} }
    local c = col[math.min(4, f.stage + 1)]
    local h = 2 + f.stage * 2
    graphics.fillRect(cx, cy - h, 1, h, c[1], c[2], c[3], 255)
    if f.stage >= 3 then graphics.fillRect(cx - 1, cy - h - 1, 3, 2, 235, 210, 90, 255) end
  elseif f.crop == "mushroom" then
    local h = 1 + f.stage
    graphics.fillRect(cx, cy - h, 1, h, 220, 220, 210, 255)
    if f.stage >= 2 then graphics.fillRect(cx - 1, cy - h - 1, 3, 1, 200, 90, 90, 255) end
    if f.stage >= 3 then graphics.fillRect(cx - 2, cy - h - 1, 5, 2, 210, 100, 100, 255) end
  end
end
hook(R.hooks.draw, function()
  for _, f in ipairs(R.farms) do pcall(farmDraw, f) end
  for _, s in ipairs(R.saplings) do
    local cx, cy = s.wx - R.cam.x, s.wy - R.cam.y
    if cx > -4 and cx < W + 4 and cy > -4 and cy < H + 4 then
      graphics.fillRect(cx, cy - 3, 1, 3, 90, 130, 60, 255); graphics.fillRect(cx - 1, cy - 4, 3, 2, 70, 150, 70, 255)
    end
  end
  for _, t in ipairs(R.tanks) do
    local cx, cy = t.wx - R.cam.x, t.wy - R.cam.y
    if t.on and cx > -8 and cx < W + 8 and cy > -8 and cy < H + 8 and (R.frame % 20) < 10 then
      graphics.fillRect(cx - 2, cy - 2, 5, 5, 90, 220, 140, 70)
    end
  end
end)

local FARM_CHECK = 60
hook(R.hooks.tick, function()
  if not R.P then return end
  -- farms: staggered, cheap - one plot advances per FARM_CHECK/len frames on average
  for i, f in ipairs(R.farms) do
    if (R.frame + i * 7) % FARM_CHECK == 0 and onScreen(f.wx, f.wy) then
      if f.crop == "wheat" then
        if nearReal(f.wx, f.wy, 20, WATERY) then
          f.prog = f.prog + 1
          if f.prog >= 10 and f.stage < 3 then f.stage = f.stage + 1; f.prog = 0 end
        end
      elseif f.crop == "mushroom" then
        if not nearReal(f.wx, f.wy, 30, LIGHT) then
          f.prog = f.prog + 1
          if f.prog >= 14 and f.stage < 3 then f.stage = f.stage + 1; f.prog = 0 end
        end
      end
    end
  end
  -- saplings: grow into a small real tree after a while, then remove the bookkeeping entry
  if R.frame % 90 == 0 then
    for i = #R.saplings, 1, -1 do local s = R.saplings[i]
      if onScreen(s.wx, s.wy) and R.frame - s.t0 > 3600 then
        local gy = groundY(s.wx, s.wy); local th = 16 + floor(math.random() * 8)
        boxFill(s.wx, gy - th, s.wx, gy - 1, "WOOD")
        boxFill(s.wx - 2, gy - th - 4, s.wx + 2, gy - th, "GRSS")
        say("A sapling has grown into a tree"); table.remove(R.saplings, i)
      end
    end
  end
  -- algae tanks: need a real WATR charge inside + a real light source nearby to register O2
  if R.frame % 90 == 0 then
    for _, t in ipairs(R.tanks) do
      if onScreen(t.wx, t.wy) then
        local wet = nearReal(t.wx, t.wy, 5, WATERY)
        local lit = nearReal(t.wx, t.wy, 40, LIGHT)
        t.on = wet and lit
        local found
        for _, s in ipairs(R.o2Sources) do if s.tankId == t then found = s end end
        if t.on then
          if not found then R.o2Sources[#R.o2Sources + 1] = { x = t.wx, y = t.wy, rate = 22, range = 90, tankId = t } end
        elseif found then for i = #R.o2Sources, 1, -1 do if R.o2Sources[i] == found then table.remove(R.o2Sources, i) end end end
      end
    end
  end
  -- WARMTH: the cold side of temperature comfort (R.gas.heat already covers the hot side in core)
  if R.frame % 60 == 0 and not R.sandbox then
    local biome = biomeAt(floor(R.P.x))
    local cold = (biome == "snow")
    local warm = nearReal(floor(R.P.x), floor(R.P.y), 40, LIGHT)
    local coat = R.inv("WARMCOAT") > 0
    local blizzard = R.sEvent and R.sEvent.key == "blizzard" and R.sEvent.phase == "active"
    local drain = 0
    if cold and not warm then drain = (blizzard and 3.2 or 1.4) * (coat and 0.5 or 1) end
    local regen = (not cold or warm) and 2 or 0
    R.warmth = math.max(0, math.min(100, R.warmth + (drain > 0 and -drain or regen)))
    if R.warmth <= 0 then
      R.hp = math.max(0, R.hp - 1); R.hurt = R.frame
      if R.frame % 240 == 0 then say("You are freezing - find warmth or wear insulation") end
    end
  end
  -- illness tick
  if R.survSick and R.frame < R.survSick and R.frame % 90 == 0 and not R.sandbox then
    R.hp = math.max(0, R.hp - 1); R.hurt = R.frame
  elseif R.survSick and R.frame >= R.survSick then R.survSick = nil; say("You feel better") end
end)

-- ================================================================ EVENTS
local EVENTS = {
  rainstorm = { name = "RAINSTORM", warnMsg = "Dark clouds gather - a storm is coming, open tunnels may flood",
    warnFor = 300, activeFor = 3600,
    req = function() return true end,
    start = function() R.weather = R.weather or {}; R.weather.rain = true; R.weather.left = math.max(R.weather.left or 0, 2400) end,
  },
  cavein = { name = "CAVE-IN", warnMsg = "The ceiling groans overhead...",
    warnFor = 150, activeFor = 20,
    req = function() return R.P.y - surfaceAt(floor(R.P.x)) > 30 end,
    start = function()
      local dx = (math.random() < 0.5 and -1 or 1) * (16 + floor(math.random() * 24))
      local wx, wy = floor(R.P.x) + dx, floor(R.P.y) - 20 - floor(math.random() * 20)
      pcall(R.crumble, wx - R.cam.x, wy - R.cam.y, 4 + math.min(6, floor((R.day or 1) / 3)))
      say("The ceiling gives way nearby!")
    end,
  },
  methane = { name = "GAS POCKET", warnMsg = "You smell gas...",
    warnFor = 240, activeFor = 20,
    req = function() return R.P.y - surfaceAt(floor(R.P.x)) > 30 and nearReal(floor(R.P.x), floor(R.P.y), 60, { GAS=1, OIL=1 }) end,
    start = function()
      for oy = -50, 50, 4 do for ox = -50, 50, 4 do
        local p = sim.partID(floor(R.P.x) + ox - R.cam.x, floor(R.P.y) + oy - R.cam.y)
        if p and (nameOf(sim.partProperty(p, "type")) == "GAS" or nameOf(sim.partProperty(p, "type")) == "OIL") then
          sim.partProperty(p, "temp", 1200); say("The gas pocket ignites!"); return end
      end end
      say("The smell fades")
    end,
  },
  meteor = { name = "METEOR SHOWER", warnMsg = "Streaks of light are crossing the night sky...",
    warnFor = 180, activeFor = 900,
    req = function()
      local phase = ((R.frame or 0) % 14000) / 14000; local night = math.max(0, math.sin((phase - 0.5) * math.pi * 2))
      return night > 0.3 and hasOpenSky(floor(R.P.x), floor(R.P.y), 200)
    end,
    tick = function(data)
      if R.frame % 100 == 0 then
        local cx = 4 + floor(math.random() * (W - 8)); local t = eid("STNE")
        if t then local p = sim.partCreate(-1, cx, 6, t)
          if p and p >= 0 then sim.partProperty(p, "vy", 6); sim.partProperty(p, "temp", 1400) end end
      end
    end,
  },
  blizzard = { name = "BLIZZARD", warnMsg = "The wind turns bitter - a blizzard is rolling in",
    warnFor = 240, activeFor = 1500,
    req = function() return biomeAt(floor(R.P.x)) == "snow" end,
    tick = function()
      if R.frame % 60 == 0 then
        local px, py = floor(R.P.x), floor(R.P.y)
        for oy = -20, 20, 4 do for ox = -20, 20, 4 do
          local p = sim.partID(px + ox - R.cam.x, py + oy - R.cam.y)
          if p and nameOf(sim.partProperty(p, "type")) == "WATR" and math.random() < 0.3 then
            local t = eid("ICE"); if t then sim.partProperty(p, "type", t) end end
        end end
      end
    end,
  },
  heatwave = { name = "HEAT WAVE", warnMsg = "The air is shimmering - a heat wave is building",
    warnFor = 240, activeFor = 1500,
    req = function() local b = biomeAt(floor(R.P.x)); local d = R.P.y - surfaceAt(floor(R.P.x)); return b == "desert" or d > 900 end,
    tick = function()
      if R.frame % 90 == 0 and not R.sandbox then
        local mult = R.inv("COOLSUIT") > 0 and 0.5 or 1
        R.gas.heat = math.min(100, (R.gas.heat or 0) + 4 * mult)
        R.need.water = math.max(0, R.need.water - 1 * mult)
      end
    end,
  },
  aquifer = { name = "AQUIFER BREACH", warnMsg = "You hear rushing water behind the rock...",
    warnFor = 200, activeFor = 20,
    req = function() local d = R.P.y - surfaceAt(floor(R.P.x)); return d > 140 and d < 320 end,
    start = function()
      local wt = eid("WATR"); if not wt then return end
      local dx = (R.P.face or 1) * 14
      for i = 1, 40 do
        local x = floor(R.P.x) + dx + floor((math.random() - 0.5) * 10) - R.cam.x
        local y = floor(R.P.y) - 10 + floor((math.random()) * 20) - R.cam.y
        if not sim.partID(x, y) then sim.partCreate(-1, x, y, wt) end
      end
      say("The wall bursts - water floods in!")
    end,
  },
  migration = { name = "MIGRATION", warnMsg = "Something is on the move out there...",
    warnFor = 200, activeFor = 20,
    req = function() return (R.day or 1) >= 2 end,
    start = function()
      R.survPrevEnemies = R.enemies
      if not R.enemies then R.enemies = true end
      say("A migration is passing through - creatures are more active (@enemies: ping for a real spawn API)")
    end,
  },
  quietnight = { name = "QUIET NIGHT", warnMsg = nil, warnFor = 0, activeFor = 2400,
    req = function()
      local phase = ((R.frame or 0) % 14000) / 14000; local night = math.max(0, math.sin((phase - 0.5) * math.pi * 2))
      return night > 0.5
    end,
    start = function() say("A strange calm settles over the night - it feels safe") end,
    tick = function()
      if R.frame % 240 == 0 and not R.sandbox then
        R.need.food = math.min(100, R.need.food + 2); R.need.water = math.min(100, R.need.water + 2)
      end
    end,
  },
}
local EVENT_ORDER = { "rainstorm", "cavein", "methane", "meteor", "blizzard", "heatwave", "aquifer", "migration", "quietnight" }

local function endEvent()
  local e = R.sEvent
  if e and e.key == "migration" then R.enemies = R.survPrevEnemies end
  R.sEvent = nil
end

hook(R.hooks.tick, function()
  if not R.P or R.sandbox then return end
  local e = R.sEvent
  if e then
    local def = EVENTS[e.key]
    if e.phase == "warn" then
      if R.frame - e.t0 >= e.warnFor then
        e.phase = "active"; e.t0 = R.frame
        local ok, err = pcall(def.start or function() end); if not ok then R.lastErr = tostring(err) end
      end
    else
      if def.tick then local ok, err = pcall(def.tick, e.data); if not ok then R.lastErr = tostring(err) end end
      if R.frame - e.t0 >= e.activeFor and not (e.key == "rainstorm" and R.weather and R.weather.rain) then endEvent() end
      if e.key == "rainstorm" and R.weather and not R.weather.rain then endEvent() end
    end
    return
  end
  -- roll for a new event: scales with day count and current depth, throttled to a few checks per game-day
  if R.frame % 600 ~= 0 then return end
  local day = R.day or 1
  local depth = (R.P.y - surfaceAt(floor(R.P.x))) / 4
  local chance = math.min(0.5, 0.03 + day * 0.01 + math.max(0, depth) * 0.0003)
  if math.random() > chance then return end
  local pool = {}
  for _, key in ipairs(EVENT_ORDER) do local d = EVENTS[key]; local ok, req = pcall(d.req); if ok and req then pool[#pool + 1] = key end end
  if #pool == 0 then return end
  local key = pool[1 + floor(math.random() * #pool)]
  local def = EVENTS[key]
  if def.warnMsg then say(def.warnMsg) end
  R.sEvent = { key = key, phase = (def.warnFor > 0 and "warn" or "active"), t0 = R.frame, warnFor = def.warnFor, activeFor = def.activeFor, data = {} }
  if def.warnFor <= 0 then local ok, err = pcall(def.start or function() end); if not ok then R.lastErr = tostring(err) end end
end)

-- ================================================================ HUD
hook(R.hooks.drawHUD, function()
  local e = R.sEvent
  if e then
    local def = EVENTS[e.key]
    local warn = e.phase == "warn"
    local col = warn and { 255, 200, 90 } or { 255, 120, 90 }
    local label = (warn and "INCOMING: " or "") .. def.name
    if (R.frame % 30) < 22 or not warn then
      local x, y, rw = R.rcLine and R.rcLine(12) or 310, 48, 188
      graphics.fillRect(x, y, rw, 12, 0, 0, 0, 150)
      graphics.drawText(x + 2, y + 2, label, col[1], col[2], col[3], 255)
    end
  end
  if R.warmth and R.warmth < 60 then
    local wy = (R._hudLeftEndY or 58) + 4
    local wx = 8
    local w = floor(R.warmth / 100 * 56)
    graphics.fillRect(wx, wy, 56, 3, 40, 40, 60, 255)
    graphics.fillRect(wx, wy, w, 3, 140, 190, 255, 255)
    if R.warmth < 25 then graphics.drawText(wx + 60, wy - 2, "COLD", 140, 190, 255, 255) end
  end
  if R.survSick then
    local x, y = R.rcLine and R.rcLine(12) or 310, 48
    graphics.drawText(x, y, "SICK", 180, 220, 90, 255)
  end
end)

-- Chat command for the toggle above: "needs thirst off", "needs hunger on", "needs status".
-- Lets it actually be switched today without waiting on a UI control (ui.lua) or a rpg.lua
-- edit (both other lanes' files this wave). Registers on the shared R.hooks.chat list the same
-- way companion.lua already does -- does not consume or block the message, so a companion, if
-- active, still sees the same line and may also reply to it; that is how this hook list already
-- works for every other listener on it, not something introduced here.
hook(R.hooks.chat, function(msg)
  if msg:match("^%s*needs?%s+status%s*$") then
    local t = (R.survivalNeeds and R.survivalNeeds.thirst == false) and "OFF" or "ON"
    local hgr = (R.survivalNeeds and R.survivalNeeds.hunger == false) and "OFF" or "ON"
    say("Needs: thirst " .. t .. ", hunger " .. hgr)
    return
  end
  local what, state = msg:match("^%s*needs?%s+(%a+)%s+(%a+)%s*$")
  if not what then return end
  what, state = what:lower(), state:lower()
  if what ~= "thirst" and what ~= "hunger" then return end
  if state ~= "on" and state ~= "off" then return end
  R.survivalNeeds = R.survivalNeeds or {}
  R.survivalNeeds[what] = (state == "on")
  say((what:sub(1, 1):upper() .. what:sub(2)) .. " need turned " .. state:upper() ..
      (state == "off" and " -- it will no longer drain or hurt you" or " -- back to normal"))
end)

-- ================================================================ sandbox / new-world resets
hook(R.hooks.sandbox, function()
  for _, k in ipairs({ "SOIL", "SEED", "SPORE", "SAPLING", "ALGAETANK", "BED", "CANTEEN", "WARMCOAT", "COOLSUIT",
                        "BERRY", "ROOT", "MSHRM", "FISH", "WHEAT", "CLEANWATER", "DIRTYWATER" }) do
    R.inventory[k] = math.max(R.inventory[k] or 0, 5)
  end
  R.rebuildHotbar()
end)
hook(R.hooks.newworld, function()
  R.farms, R.saplings, R.beds = {}, {}, {}
  for i = #R.o2Sources, 1, -1 do if R.o2Sources[i].tankId then table.remove(R.o2Sources, i) end end
  R.tanks = {}
  R.warmth, R.survSick, R.sEvent = 100, nil, nil
  R.bedRespawn = nil
  R.need.food, R.need.water = 100, 100
end)
