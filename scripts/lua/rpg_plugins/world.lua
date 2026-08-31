-- rpg_plugins/world.lua : natural terrain + underground generator (surface biomes, strata, caves, structures)
-- Design notes / sources: knowledge/research-worldgen-2026-08-26.md
-- Root cause of the old "slitty" caves: a level-set crossing (abs(noise-0.5) < tiny epsilon) can pinch to
-- zero width wherever the noise gradient is steep. Fix: explicit worm tunnels with a centerline + a radius
-- that has a hard floor, so they can never pinch shut (Minecraft-style "spaghetti" done as a real tube, not
-- an implicit level-set). Cheese-style caverns are kept as a separate, wider, low-frequency field (union of
-- the two, like Minecraft's cheese+spaghetti split). Strata are depth bands computed BEFORE caves/ore are
-- carved into them (Terraria's pass order: shape, then caves, then ore, then structures - each independent).
-- Ore/mineral/crystal pockets use a cheap "zone then detail" two-tap test so they read as blobs/veins
-- instead of salt-and-pepper speckling. Everything is a pure function of (wx, wy, R.seed); all repeated work
-- is cached per column/chunk index in plain Lua tables (mirrors surfCache/treeCache in rpg.lua).
local R = PBX.state.rpg
local TAG = "world"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local has, eid = R.has, R.eid
local surfaceAt, biomeAt, biomeMix, DEPTH = R.surfaceAt, R.biomeAt, R.biomeMix, R.DEPTH

-- ================================================================ soft-border helpers (the player 16:48: "extremely harsh,
-- just a straight line"). Core's biomeAt/biomeMix already warp the boundary and dither it column-by-column; on top of
-- that, everything below uses a continuous 0..1 "how much of biome X is here" weight (not a coin-flip) so flora
-- density, soil material and depth all fade smoothly across the ~90px band instead of snapping. Cached per column
-- (blendCache), same pattern as every other per-column cache in this file - one extra table lookup, not extra noise.
local blendCache = {}
local function blendAt(wx)
  local b = blendCache[wx]
  if not b then local here, other, t = biomeMix(wx); b = { here, other, t }; blendCache[wx] = b end
  return b[1], b[2], b[3]
end
local function biomeWeight(wx, name)   -- 0..1 influence of `name` at this column; 0 if `name` has no presence here
  local here, other, t = blendAt(wx)
  if here == name then return 1 - t end
  if other == name then return t end
  return 0
end
local GRASS = has("GRSS") and "GRSS" or "PLNT"
-- FIXED 2026-08-30: bridge-verified BSLT (id=503) Falldown=0, Properties&TYPE_SOLID==4
-- (real static solid); STNE/GRAV/BRMT/BCOL/CLST/SAND all Falldown=1 -- rejected. See rpg.lua note.
local ROCK = has("BSLT") and "BSLT" or "BRCK"
-- CNCR (id=495) bridge-verified Falldown=0, Properties&TYPE_SOLID==4 -- also a real static solid.
local ROCK2 = has("CNCR") and "CNCR" or ROCK
local HASCU = has("CU")
local UORE = has("DU") and "DU" or "URAN"
local SOIL_DEPTH_MUL = 4   -- topsoil/subsoil before stone strata (~4x default; new columns only)

-- ================================================================ noise (same style as rpg.lua's hash3/vnoise)
local function frac(v) return v - floor(v) end
local function hash3(a, b, c) return frac(math.sin(a * 127.1 + b * 311.7 + c * 74.7 + (R.seed or 7) * 13.7) * 43758.5453) end
local function vnoise(x, y, salt)
  local ix, iy = floor(x), floor(y); local fx, fy = x - ix, y - iy; fx = fx*fx*(3-2*fx); fy = fy*fy*(3-2*fy)
  local a, b, c, d = hash3(ix, iy, salt), hash3(ix+1, iy, salt), hash3(ix, iy+1, salt), hash3(ix+1, iy+1, salt)
  return (a + (b-a)*fx) * (1-fy) + (c + (d-c)*fx) * fy
end
-- half-cost 1D noise (2 taps instead of 4) for things that are conceptually a function of one coordinate only
-- (worm centerlines/radii, strata waviness, dune/pool shape) - per-cell perf matters here (see file header note)
local function vnoise1(x, salt)
  local ix = floor(x); local fx = x - ix; fx = fx*fx*(3-2*fx)
  local a, b = hash3(ix, 0, salt), hash3(ix+1, 0, salt)
  return a + (b-a)*fx
end
-- cheap "zone then detail" vein test: usually bails after 1 tap, only spends a 2nd tap inside a vein zone.
-- produces blobs/veins instead of a single flat threshold's speckled peppering.
local function vein(wx, wy, salt, zoneScale, zoneThresh, detailScale, detailThresh)
  -- R.oreRarityMul (Options menu slider): 1.0 = unchanged; >1 raises the zone
  -- threshold (rarer), <1 lowers it (more common). One knob for every ore/
  -- crystal call site, since they all route through this shared function.
  local zt = zoneThresh + ((R.oreRarityMul or 1) - 1) * 0.15
  if vnoise(wx / zoneScale, wy / zoneScale, salt) < zt then return false end
  return vnoise(wx / detailScale, wy / detailScale, salt + 1) > detailThresh
end
local function inEllipse(wx, wy, cx, cy, rx, ry) local dx, dy = (wx-cx)/rx, (wy-cy)/ry; return dx*dx + dy*dy <= 1 end
local function inCapsule(wx, wy, x1, y1, x2, y2, r)   -- thick line segment (used for branches/fronds)
  local dx, dy = x2-x1, y2-y1; local len2 = dx*dx + dy*dy
  local t = len2 > 0 and max(0, min(1, ((wx-x1)*dx + (wy-y1)*dy) / len2)) or 0
  local px, py = x1 + t*dx, y1 + t*dy; local ddx, ddy = wx-px, wy-py
  return ddx*ddx + ddy*ddy <= r*r
end

-- ================================================================ surface vegetation: BIG trees (chop-able, see the
-- felling section below), cacti, oases. Scale target: player is ~12px tall, trees are 4-7 player-heights (50-90px),
-- trunks 4-6px thick, canopies 30-50px wide / 20-30px tall, spaced close enough to overlap into a real forest.
-- R.treeSpacingMul (Options menu slider, part of the "everything configurable"
-- sliders pattern): 1.0 = default 30px spacing; used as a function (not a plain
-- constant) so a change is picked up live like the other worldgen sliders --
-- affects newly-generated columns only, per-column vegCache/blendCache means
-- already-visited columns keep whatever spacing they generated with.
local function vsp() return 30 * (R.treeSpacingMul or 1) end
local MAXFEAT = 110       -- tallest tree + canopy overshoot; skip noise entirely above this for plain sky
local vegCache = {}
-- one biome's flora roll, parameterized so it can be rolled for "here" (full density, thinned near an edge) and
-- "other" (a few neighbouring-biome trees bleeding into the band) with independent salts so the rolls don't correlate.
local function vegRollFor(biome, cell, forceTree, scale, salt)
  if scale <= 0.02 then return false end
  local h1 = hash3(cell, salt, 1)
  if biome == "desert" then
    if h1 < 0.16 * scale then
      local x = cell*vsp() + 5 + floor(hash3(cell,salt,2) * (vsp()-10))
      return { kind="cactus", x0=x, h = 6 + floor(hash3(cell,salt,3)*7), arm = hash3(cell,salt,4) < 0.5,
            armH = 2 + floor(hash3(cell,salt,5)*3), armSide = hash3(cell,salt,6) < 0.5 and -1 or 1, s = surfaceAt(x) }
    elseif h1 < 0.22 * scale then   -- rare desert-oasis palm; marks the spot for a real water pool too (oasisPoolAt)
      local x = cell*vsp() + 6 + floor(hash3(cell,salt,2) * (vsp()-12))
      return { kind="tree", species="palm", x0=x, trunkW=2, h = 30 + floor(hash3(cell,salt,3)*26),
            cw = 22 + floor(hash3(cell,salt,9)*12), ch = 10, s = surfaceAt(x), oasis = true }
    end
    return false
  elseif biome == "snow" then
    if forceTree or h1 < 0.34 * scale then
      local x = cell*vsp() + 6 + floor(hash3(cell,salt,2) * (vsp()-12))
      return { kind="tree", species="pine", x0=x, trunkW = 3 + floor(hash3(cell,salt,8)*2), h = 48 + floor(hash3(cell,salt,3)*36),
            cw = 24 + floor(hash3(cell,salt,9)*14), ch = 0, s = surfaceAt(x) }
    end
    return false
  elseif biome then
    local prob = (biome == "swamp" and 0.42 or 0.62) * scale
    if forceTree or h1 < prob then
      local x = cell*vsp() + 6 + floor(hash3(cell,salt,2) * (vsp()-12))
      local species = (biome == "swamp" and hash3(cell,salt,10) < 0.55) and "dead" or "oak"
      return { kind="tree", species=species, x0=x, trunkW = 4 + floor(hash3(cell,salt,8)*3), h = 50 + floor(hash3(cell,salt,3)*41),
            cw = 30 + floor(hash3(cell,salt,9)*21), ch = 20 + floor(hash3(cell,salt,11)*11), s = surfaceAt(x) }
    end
    return false
  end
  return false
end
local function vegAt(cell)
  local v = vegCache[cell]; if v ~= nil then return v end
  local x0c = cell * vsp() + 12
  local here, other, t = blendAt(x0c)
  local forceTree = cell >= -2 and cell <= 2   -- guarantee trees right at spawn (wx~0) on every seed
  -- thin the home biome's own flora smoothly as the border approaches (was a hard biomeAt() check before)
  v = vegRollFor(here, cell, forceTree, 1 - t*0.75, 811)
  if not v and other and t > 0.12 then
    -- a few of the neighbouring biome's trees/cacti bleed a short way into this side of the border
    v = vegRollFor(other, cell, false, t*0.55, 1811)
  end
  vegCache[cell] = v; return v
end
local rootColCache = {}
local function rootColumn(wx)   -- is a tree trunk within reach of this column? (used to seed root flecks below it)
  local r = rootColCache[wx]; if r ~= nil then return r end
  local c = floor(wx / vsp()); r = false
  for cc = c-2, c+2 do local v = vegAt(cc); if v and v.kind == "tree" and wx >= v.x0-1 and wx <= v.x0+(v.trunkW or 3) then r = true; break end end
  rootColCache[wx] = r; return r
end

-- Branching underground root veins: WOOD shell + 1px hollow core (like trunk vein).
-- Deterministic per tree cell; water routes through hollow air in rpg.lua liquid ticks.
local ROOT_BRANCHES = 6
local function rootVeinOnSegment(wx, wy, x1, y1, x2, y2)
  if not inCapsule(wx, wy, x1, y1, x2, y2, 1.35) then return nil end
  if inCapsule(wx, wy, x1, y1, x2, y2, 0.42) then return "hollow" end
  return "wood"
end
local function rootVeinShapeAt(wx, wy, surf, d)
  if d < 1 or d > 22 * SOIL_DEPTH_MUL then return nil end
  local c = floor(wx / vsp())
  for cc = c - 3, c + 3 do
    local v = vegAt(cc)
    if not v or v.kind ~= "tree" then goto rv_tree_next end
    local x0, s, tw = v.x0, v.s, v.trunkW or 3
    local hc = x0 + floor(tw / 2)
    local maxD = floor(8 + v.h * 0.14 * SOIL_DEPTH_MUL)
    if d > maxD then goto rv_tree_next end
  if wx == hc and wy > s and wy <= s + maxD then return "hollow" end
  if wy > s and wy <= s + maxD - 1 then
    if wx == hc - 1 or wx == hc + 1 then return "wood" end
    if tw >= 4 and d <= maxD * 0.65 and (wx == hc - 2 or wx == hc + 2) then return "wood" end
  end
    for i = 0, ROOT_BRANCHES - 1 do
      local bd = floor(2 + i * (2.2 + hash3(cc, 850, i) * 2.8))
      if bd > maxD - 2 then break end
      local span = 6 + floor(hash3(cc, 854, i) * 5)
      if d < bd - 1 or d > bd + span then goto rv_br_next end
      local dir = hash3(cc, 851, i) < 0.5 and -1 or 1
      local len = 8 + floor(hash3(cc, 852, i) * 18)
      local y0 = s + bd
      local role = rootVeinOnSegment(wx, wy, hc, y0, hc + dir * len, y0 + 1 + floor(hash3(cc, 853, i) * 4))
      if role then return role end
      if hash3(cc, 855, i) > 0.32 then
        local mx = hc + dir * floor(len * 0.45)
        local my = y0 + 1 + floor(hash3(cc, 856, i) * 3)
        local sdir = -dir
        role = rootVeinOnSegment(wx, wy, mx, my, mx + sdir * floor(5 + hash3(cc, 857, i) * 10), my + 2 + floor(hash3(cc, 858, i) * 3))
        if role then return role end
      end
      ::rv_br_next::
    end
    ::rv_tree_next::
  end
  return nil
end
function R.treeRootVeinQuery(wx, wy)
  wx, wy = floor(wx), floor(wy)
  local surf = surfaceAt(wx)
  if wy <= surf then return nil end
  local d = wy - surf
  local role = rootVeinShapeAt(wx, wy, surf, d)
  if not role then return nil end
  local c = floor(wx / vsp())
  local bestV, bestD, bestHc = nil, 999, nil
  for cc = c - 3, c + 3 do
    local v = vegAt(cc)
    if v and v.kind == "tree" then
      local hc = v.x0 + floor((v.trunkW or 3) / 2)
      local dist = abs(wx - hc)
      if dist < bestD then bestD = dist; bestV = v; bestHc = hc end
    end
  end
  if not bestV then return nil end
  local info = {
    x0 = bestV.x0, tw = bestV.trunkW or 3, s = bestV.s, hollowCol = bestHc,
    species = bestV.species, inRootVein = true,
  }
  if role == "hollow" then info.inHollow = true else info.rootWood = true end
  return info
end
local function vegShapeAt(wx, wy)
  local c = floor(wx / vsp())
  for cc = c-2, c+2 do
    local v = vegAt(cc)
    if v then
      if v.kind == "tree" then
        local top, tw, x0 = v.s - v.h, v.trunkW or 3, v.x0
        -- Real "internal vein" per the big feature bundle: a genuine 1px hollow
        -- channel down the trunk's center (only on trunks wide enough to spare it,
        -- tw>=3 -- palm's tw=2 stays solid), open air rather than solid WOOD, so
        -- real rain/water that lands in it actually falls through under gravity
        -- into the trunk and drains out through the round-1 root fingers already
        -- generated at ground level -- real physics, not scripted particle
        -- teleportation. Skipped on tw<3 trunks: too thin to read as anything but
        -- a rendering glitch.
        if wx >= x0 and wx < x0 + tw and wy >= top and wy <= v.s then
          if tw >= 3 and wx == x0 + floor(tw / 2) then return nil end
          return "WOOD"
        end
        local cx = x0 + tw/2
        if v.species == "oak" then
          for i = 0, 2 do
            local byy = top + v.h * (0.30 + i*0.20); local dir = (i % 2 == 0) and -1 or 1
            local blen = 8 + floor(hash3(cc,813,i) * 7)
            local bx = (dir > 0) and (x0 + tw) or x0
            if inCapsule(wx, wy, bx, byy, bx + dir*blen, byy - blen*0.45, 1.3) then return "WOOD" end
          end
          local ccy = top + v.ch * 0.10
          for i = 0, 4 do
            local ang = (i / 4) * math.pi
            local ox = math.cos(ang) * v.cw * 0.34 * (0.7 + hash3(cc,814,i) * 0.5)
            local oy = -math.sin(ang) * v.ch * 0.42 * (0.7 + hash3(cc,814,i+9) * 0.5)
            if inEllipse(wx, wy, cx+ox, ccy+oy - v.ch*0.12, v.cw*0.30, v.ch*0.55) then return GRASS end
          end
          if inEllipse(wx, wy, cx, ccy, v.cw*0.42, v.ch*0.60) then return GRASS end
          -- wild beehive: ~12% of oaks hide a small mineable cache in the canopy (forest's "food" bonus, real GOLD ore)
          if hash3(cc,816,1) < 0.12 and inEllipse(wx, wy, cx, ccy - v.ch*0.35, 3, 2.4) then return "GOLD" end
        elseif v.species == "dead" then
          for i = 0, 4 do
            local byy = top + v.h * (0.08 + i*0.17); local dir = (i % 2 == 0) and -1 or 1
            local blen = 9 + floor(hash3(cc,813,i) * 9); local bend = -3 - floor(hash3(cc,813,i+5) * 5)
            local bx = (dir > 0) and (x0 + tw) or x0
            if inCapsule(wx, wy, bx, byy, bx + dir*blen, byy + bend, 1.1) then return "WOOD" end
            if has("VINE") and hash3(cc,817,i) < 0.5 then   -- swamp "plentiful plants": vines hanging off dead branches
              local ex, ey = bx + dir*blen, byy + bend
              if inCapsule(wx, wy, ex, ey, ex, ey + 6 + floor(hash3(cc,817,i+10)*8), 0.8) then return "VINE" end
            end
          end
          if hash3(cc,815,1) < 0.4 and inEllipse(wx, wy, cx, top+2, 3, 2) then return GRASS end
        elseif v.species == "pine" then
          local tiers, tierH = 6, v.h * 0.115
          for k = 0, tiers - 1 do
            local ry, rad = top + k*tierH, (v.cw*0.5) * (1 - k/tiers) + 1.6
            if wy >= ry-1 and wy <= ry + tierH*1.3 and abs(wx-cx) <= rad*(1-((wy-ry+1)/(tierH*1.6))) then
              return (k == 0 and wy <= ry+1) and (has("SNOW") and "SNOW" or "ICE") or GRASS end
          end
        elseif v.species == "palm" then
          for i = 0, 4 do
            local ang = math.pi*0.12 + (i/4) * math.pi*0.76
            local fx, fy = cx + math.cos(ang) * v.cw*0.5, top - math.sin(ang) * v.ch*1.3
            if inCapsule(wx, wy, cx, top, fx, fy, 1.2) then return GRASS end
          end
        end
      elseif v.kind == "cactus" then
        if (wx == v.x0 or wx == v.x0+1) and wy >= v.s - v.h and wy <= v.s then return GRASS end
        if v.arm then
          local ay = v.s - v.h + v.armH; local ax = v.x0 + (v.armSide > 0 and 2 or -1)
          if wx == ax and (wy == ay or wy == ay - 1) then return GRASS end
        end
      end
    end
  end
  return nil
end

-- Tree liquid routing: expose real world.lua geometry to rpg.lua soak ticks (trunkW,
-- hollow column, canopy GRASS). The old rpg.lua treeAt() used a 2px trunk on a 24px
-- grid and never matched these trees — rain pooled on canopy WOOD/GRSS instead of
-- draining through the hollow vein.
function R.treeVegQuery(wx, wy)
  local c = floor(wx / vsp())
  for cc = c - 2, c + 2 do
    local v = vegAt(cc)
    if v and v.kind == "tree" then
      local top, tw, x0 = v.s - v.h, v.trunkW or 3, v.x0
      local hollowCol = (tw >= 3) and (x0 + floor(tw / 2)) or nil
      local info = { x0 = x0, tw = tw, top = top, s = v.s, hollowCol = hollowCol, species = v.species }
      local shape = vegShapeAt(wx, wy)
      if shape == "WOOD" then
        if hollowCol and wx == hollowCol then info.inHollow = true else info.trunkWood = true end
        return info
      end
      if shape == GRASS and wy < v.s and wy >= top - 4 then
        info.canopy = true; info.poolOnCanopy = true; return info
      end
      local below = vegShapeAt(wx, wy + 1)
      if below == "WOOD" and wy + 1 >= top and wy + 1 <= v.s then
        if hollowCol and wx == hollowCol then info.inHollow = true else info.poolOnTrunk = true end
        return info
      end
      if below == GRASS and wy + 1 < v.s and wy + 1 >= top - 4 then
        info.canopy = true; info.poolOnCanopy = true; return info
      end
      if hollowCol and wx == hollowCol and wy >= top and wy <= v.s + 1 then
        info.inHollow = true; return info
      end
    end
  end
  return nil
end
function R.treeRootSoakAt(wx, wy)
  local q = R.treeRootVeinQuery and R.treeRootVeinQuery(wx, wy)
  if q and q.inHollow then return true end
  local surf = surfaceAt(wx); local d = wy - surf
  if d < 1 or d > 12 * (SOIL_DEPTH_MUL or 4) then return false end
  return rootColumn(wx) and vnoise(wx / 3, wy / 3, 830) > 0.65
end
-- Underground wet layer: hollow root branches + aquifer pockets around roots.
function R.treeAquiferAt(wx, wy)
  local q = R.treeRootVeinQuery and R.treeRootVeinQuery(wx, wy)
  if q and (q.inHollow or q.rootWood) then return true end
  local surf = surfaceAt(wx); local d = wy - surf
  if d < 3 or d > 24 * (SOIL_DEPTH_MUL or 4) then return false end
  if not rootColumn(wx) then return false end
  return vnoise(wx / 4, wy / 4, 831) > 0.50
end
local function treeCoversColumn(wx)
  if rootColumn(wx) then return true end
  local c = floor(wx / vsp())
  for cc = c - 1, c + 1 do
    local v = vegAt(cc)
    if v and v.kind == "tree" then
      local span = max(v.trunkW or 3, floor((v.cw or 24) * 0.55))
      if wx >= v.x0 - span and wx <= v.x0 + (v.trunkW or 3) + span then return true end
    end
  end
  return false
end
function R.treeCoversColumn(wx) return treeCoversColumn(floor(wx)) end
-- Forest floor between adjacent tree trunks: rain pools on GRSS gaps because
-- treeVegQuery only matches canopy/trunk/hollow pixels, not the open columns
-- between trees. Returns nearest hollow drain + gapFloor when wx,wy is on the
-- surface strip under tree shade but not on trunk wood/canopy itself.
function R.nearestTreeDrain(wx, wy)
  wx, wy = floor(wx), floor(wy)
  if not treeCoversColumn(wx) then return nil end
  local surf = surfaceAt(wx)
  if wy < surf - 3 or wy > surf + 4 then return nil end
  local c = floor(wx / vsp())
  local best, bestD = nil, 999
  for cc = c - 5, c + 5 do
    local v = vegAt(cc)
    if v and v.kind == "tree" then
      local tw = v.trunkW or 3
      if tw >= 2 then
        local hollowCol = v.x0 + floor(tw / 2)
        local d = abs(wx - hollowCol)
        if d < bestD then
          bestD = d
          best = { x0 = v.x0, tw = tw, top = v.s - v.h, s = v.s, hollowCol = hollowCol, species = v.species }
        end
      end
    end
  end
  if not best or bestD > 50 then return nil end
  local shape = vegShapeAt(wx, wy)
  if shape == "WOOD" then return nil end
  if shape == GRASS and wy < best.s and wy >= best.top - 4 then return nil end
  if best.hollowCol and wx == best.hollowCol and wy >= best.top and wy <= best.s + 1 then return nil end
  local q = R.treeVegQuery(wx, wy)
  if q and (q.trunkWood or q.poolOnCanopy or q.poolOnTrunk or q.inHollow) then return nil end
  best.gapFloor = true
  return best
end
-- Any pixel under tree shade (canopy air, branch wood, leaf gaps) routes rain to nearest hollow vein.
function R.treeShadeDrain(wx, wy)
  wx, wy = floor(wx), floor(wy)
  if not treeCoversColumn(wx) then return nil end
  local surf = surfaceAt(wx)
  if wy > surf + 2 or wy < surf - MAXFEAT then return nil end
  local c = floor(wx / vsp())
  local best, bestD = nil, 999
  for cc = c - 4, c + 4 do
    local v = vegAt(cc)
    if v and v.kind == "tree" and (v.trunkW or 3) >= 3 then
      local hollowCol = v.x0 + floor((v.trunkW or 3) / 2)
      local d = abs(wx - hollowCol)
      if d < bestD then
        bestD = d
        best = {
          x0 = v.x0, tw = v.trunkW or 3, top = v.s - v.h, s = v.s,
          hollowCol = hollowCol, species = v.species,
          canopy = true, poolOnCanopy = true,
        }
      end
    end
  end
  if not best or bestD > 44 then return nil end
  return best
end

-- desert dunes (thin SAND cap over solid rock so it can't avalanche far), swamp shallow pools, ground-cover deco.
-- All of these are now scaled by biomeWeight() instead of a hard biome=="x" check, so the sand cap/pool depth/ground
-- cover density tapers to nothing across the border band rather than switching on/off at a line (feathers the sand
-- edge so it never reads as a wall against dirt).
local function duneBumpAt(wx) return floor(vnoise1(wx/16, 1150) * 3.2) end
local function swampPoolAt(wx) local v = vnoise1(wx/70, 1160); if v > 0.68 then return 1 + floor((v-0.68)*8) end; return nil end
local function oasisPoolAt(wx, surf)   -- a real water pool at the base of every oasis palm (desert's water source)
  local c = floor(wx / vsp())
  for cc = c-1, c+1 do local v = vegAt(cc); if v and v.oasis then
    local base = v.x0 + (v.trunkW or 2) * 0.5
    if abs(wx - base) <= 9 then return true end
  end end
  return false
end
-- coloured "flower tip" palette: distinct, solid (fd=0 or safely-resting fd=1 clay), harmless elements only
local FLOWER_TIPS = {}
for _, nm in ipairs({ "GOLD", "CU", "QRTZ", "CLST", "ZIRC", "LEAD" }) do if has(nm) then FLOWER_TIPS[#FLOWER_TIPS+1] = nm end end
local DSP = 4     -- dense ground-cover grid: tufts/flowers/bushes read as a lush carpet, not sparse dots
local decoCache = {}
local function decoAt(cell)
  local info = decoCache[cell]; if info ~= nil then return info end
  local x0 = cell*DSP + floor(hash3(cell,1180,1) * DSP)
  local wGreen = biomeWeight(x0, "forest") + biomeWeight(x0, "swamp")   -- lush ground cover fades with forest/swamp
  local wDesert = biomeWeight(x0, "desert")
  info = false
  if wGreen > 0.03 and not rootColumn(x0) then
    local r = hash3(cell,1180,2)
    if r < 0.34 * wGreen then info = { x = x0, kind = "tuft" }
    elseif r < 0.46 * wGreen then info = { x = x0, kind = "tall" }
    elseif r < 0.53 * wGreen and #FLOWER_TIPS > 0 then info = { x = x0, kind = "flower", col = FLOWER_TIPS[1 + floor(hash3(cell,1180,3) * #FLOWER_TIPS)] }
    elseif r < 0.58 * wGreen then info = { x = x0, kind = "bush" } end
  end
  if not info and wDesert > 0.03 and hash3(cell,1180,2) < 0.03 * wDesert then info = { x = x0, kind = "deadbush" } end
  decoCache[cell] = info; return info
end
local function surfaceDecoAt(wx, wy, surf, biome)
  local rel = surf - wy; if rel < 1 or rel > 3 then return nil end
  local cell = floor(wx / DSP)
  for cc = cell-1, cell+1 do
    local info = decoAt(cc)
    if info and info.x == wx then
      local k = info.kind
      if k == "tuft" and rel == 1 then return GRASS end
      if k == "tall" and rel <= 2 then return GRASS end
      if k == "flower" then if rel == 1 then return GRASS elseif rel == 2 then return info.col end end
      if k == "bush" and rel <= 2 then return GRASS end
      if k == "deadbush" and rel <= 2 then return "WOOD" end
    end
  end
  return nil
end
local function aboveGround(wx, wy, surf, biome)
  if surf - wy > MAXFEAT then return "" end
  local v = vegShapeAt(wx, wy); if v then return v end
  if oasisPoolAt(wx, surf) and surf - wy <= 1 then return "WATR" end
  local wDesert = biomeWeight(wx, "desert")
  if wDesert > 0.04 and surf - wy <= duneBumpAt(wx) * wDesert then return "SAND" end
  local wSwamp = biomeWeight(wx, "swamp")
  if wSwamp > 0.04 then
    local p = swampPoolAt(wx)
    if p and surf - wy <= p * wSwamp then
      -- poisonous swamp water (the player 16:52): mostly real WATR, some patches genuinely toxic - SLTW blocks
      -- oxygen exactly like water (see core's BADGAS), rare CAUS actively burns on contact (core's dmg tick)
      local poison = vnoise1(wx/9, 1161)
      if poison > 0.90 and has("CAUS") then return "CAUS" end
      if poison > 0.55 and has("SLTW") then return "SLTW" end
      return "WATR"
    end
  end
  local d = surfaceDecoAt(wx, wy, surf, biome); if d ~= nil then return d end
  return ""
end

-- ================================================================ caves: worm tunnels (guaranteed round+open) + cheese caverns
local WORM_SP = 90
local wormCache = {}
local function wormAt(cw)
  local w = wormCache[cw]; if w ~= nil then return w end
  -- R.caveFreqMul (Options menu slider): 1.0 = default 3% spawn rate per column;
  -- >1 raises it, <1 lowers it. Cached per-column like everything else here, so a
  -- change only affects newly-generated columns, not already-carved terrain.
  local thresh = 1 - (1 - 0.97) * (R.caveFreqMul or 1)
  if hash3(cw, 701, 1) >= thresh then wormCache[cw] = false; return false end
  local isEntrance = hash3(cw,701,3) < 0.22
  w = { originX = cw*WORM_SP + 10 + floor(hash3(cw,701,2) * (WORM_SP-20)),
        isEntrance = isEntrance, startD = isEntrance and 1 or (10 + floor(hash3(cw,701,4) * 50)),
        baseR = 3.0 + hash3(cw,701,5) * 2.2, amp = WORM_SP*0.55 + hash3(cw,701,6) * WORM_SP*0.25,
        period = 55 + hash3(cw,701,7) * 70, phase = hash3(cw,701,8) * 1000 }
  wormCache[cw] = w; return w
end
local function wormOpenAt(wx, wy, d)
  local c = floor(wx / WORM_SP)
  for cc = c-1, c+1 do
    local w = wormAt(cc)
    if w and d >= w.startD - 1 then
      local dep = d - w.startD
      -- Root cause of "empty vertical tunnels going straight down" (confirmed with real
      -- numbers, not guessed): dep/w.period only covers ~0.3 of a full noise cycle over the
      -- first 40 depth units (period is 55-125), so the centerline barely leaves whatever
      -- local slope of the noise it started on -- it drifts in a near-straight line instead
      -- of winding. A second, much faster noise layer (its own short period, independent
      -- phase) adds real wiggle near the entrance and is weighted OUT by dep/40 so the
      -- already-tuned deep behavior (the slow layer alone) is completely unchanged past
      -- the first ~40 units.
      local wiggle = w.amp * 0.4 * (vnoise1(dep / 14 + w.phase + 500, 703) - 0.5) * 2 * max(0, 1 - dep / 40)
      local cx = w.originX + w.amp * (vnoise1(dep / w.period + w.phase, 703) - 0.5) * 2 + wiggle
      if abs(wx - cx) <= w.baseR + 14 then    -- coarse reject before spending more taps
        local rad = w.baseR + (vnoise1(dep / 40 + w.phase, 704) - 0.5) * 2.4
        local room = vnoise1(dep / 130 + w.phase, 705)
        if room > 0.80 then rad = rad + (room - 0.80) * 40 end            -- occasional wider room along the path
        if w.isEntrance then rad = 1.6 + rad * min(1, dep / 18) end        -- thin mouth widening into the tunnel
        rad = max(rad, w.isEntrance and 1.6 or 2.2)                       -- hard floor: can never pinch to a slit
        if abs(wx - cx) <= rad then return true end
      end
    end
  end
  return false
end
local FALL_SP = 420
local fallCache = {}
local function fallAt(cf)
  local f = fallCache[cf]; if f ~= nil then return f end
  if hash3(cf, 1001, 1) >= 0.35 then fallCache[cf] = false; return false end
  f = { x = cf*FALL_SP + 40 + floor(hash3(cf,1001,2) * (FALL_SP-80)),
        topD = 140 + floor(hash3(cf,1001,3) * 200), h = 40 + floor(hash3(cf,1001,4) * 90) }
  fallCache[cf] = f; return f
end
local function waterfallAt(wx, wy, d)   -- a vertical crack of falling water from a lake down into a lower cavern
  local cf = floor(wx / FALL_SP)
  for cc = cf-1, cf+1 do local f = fallAt(cc); if f and d >= f.topD and d <= f.topD + f.h and abs(wx - f.x) <= 1 then return true end end
  return false
end
local function cheeseOpenAt(wx, wy, d)
  if d < 20 * SOIL_DEPTH_MUL then return false end
  -- 2-tap fBm (worm tunnels already fixed the "slitty" look, so this stays cheap: no domain warp needed here)
  local cavern = 0.60*vnoise(wx/110, wy/65, 611) + 0.40*vnoise(wx/38, wy/26, 612)
  return cavern > (0.70 - min(0.08, d/9000))
end
local LAKE_SP = 460
local lakeCache = {}
local function lakeInfo(cl)
  local L = lakeCache[cl]; if L ~= nil then return L end
  if hash3(cl, 1101, 1) >= 0.4 then lakeCache[cl] = false; return false end
  L = { x0 = cl*LAKE_SP + 30 + floor(hash3(cl,1101,2) * 40) }
  L.x1 = L.x0 + 120 + floor(hash3(cl,1101,3) * 220)
  L.topD = 150 + floor(hash3(cl,1101,4) * 500)
  L.botD = L.topD + 50 + floor(hash3(cl,1101,5) * 90)   -- capped depth so a lake reads as a contained pool, not a shaft
  lakeCache[cl] = L; return L
end
local function lakeAt(wx, wy, d)   -- fills the bottom of a cheese cavern up to a flat surface row, like a real lake
  local cl = floor(wx / LAKE_SP)
  for cc = cl-1, cl+1 do local L = lakeInfo(cc); if L and wx >= L.x0 and wx <= L.x1 and d >= L.topD and d <= L.botD then return true end end
  return false
end
local function geodeZoneAt(wx, wy) return vnoise(wx/260, wy/260, 920) > 0.90 end
local function hellLavaAt(wx, wy) return vnoise(wx/50, wy/40, 1220) > 0.42 end
local function swampGasZoneAt(wx, wy) return vnoise(wx/140, wy/90, 1230) > 0.82 end
local function caveAt(wx, wy, surf, d, biome)
  if wy >= DEPTH - 40 then return nil end   -- never open in the bedrock margin
  local wopen = wormOpenAt(wx, wy, d)
  local fopen = (not wopen) and waterfallAt(wx, wy, d)
  local copen = (not (wopen or fopen)) and cheeseOpenAt(wx, wy, d)
  if not (wopen or fopen or copen) then return nil end
  if wy >= DEPTH - 300 then return hellLavaAt(wx, wy) and "LAVA" or "" end
  if fopen then return "WATR" end
  if copen and d > 140 and lakeAt(wx, wy, d) then return "WATR" end
  -- crystal cave pockets: coarse zone+detail so it reads as a solid crystal mass, not speckle (nothing under ~4px).
  -- Snow's "frozen caves with rare crystals" purpose: a lower detail threshold makes real crystal noticeably
  -- more common under snow than elsewhere (still the same QRTZ, same real material, just biome-weighted odds).
  if d > 130 and geodeZoneAt(wx, wy) then
    local crystalThresh = 0.36 - 0.10 * biomeWeight(wx, "snow")
    if vnoise(wx/20, wy/20, 921) > crystalThresh then return "QRTZ" end
  end
  -- swamp purpose: real OIL pools and GAS pockets in its underground caves (the player 16:52) - genuinely flammable/
  -- explosive hazards using stock TPT physics, nothing invented. Biome-weighted so it fades out at the border.
  if d > 40 and d < 500 and biomeWeight(wx, "swamp") > 0.4 and swampGasZoneAt(wx, wy) then
    local r = vnoise(wx/14, wy/14, 1231)
    if has("OIL") and r > 0.62 then return "OIL" end
    if has("GAS") and r > 0.40 then return "GAS" end
  end
  return ""
end

-- ================================================================ solid rock: depth-band strata, then ore/crystal veins
local function strataAt(wx, wy, d, icy, cold)
  local wave = (vnoise1(wx/85, 810) - 0.5) * 8      -- slow per-column wobble: bands aren't perfectly flat
  local band = floor((d - wave) / 15)
  if icy then
    if has("QRTZ") and hash3(band, 816, 4) > 0.95 then return "QRTZ" end
    return "ICE"
  end
  -- `cold`: below a snow biome's frozen crust the rock is normal (and carries normal ore),
  -- but occasional ice lenses keep it reading as a cold region instead of flipping to
  -- generic forest rock at an invisible depth line. Shares `band` so the lenses line up
  -- with the surrounding strata rather than looking like unrelated noise.
  if cold and hash3(band, 817, 6) > 0.74 then return "ICE" end
  local pick = hash3(band, 815, 3)
  -- desert purpose: exposed sedimentary/fossil-bearing layers under the sand - real fired brick, banded and common,
  -- reads as ancient strata (and matches the desert's brick ruins). Fades in with desert weight, not a hard switch.
  if pick < 0.30 * biomeWeight(wx, "desert") and has("BRCK") then return "BRCK" end
  if pick < 0.58 then return ROCK end
  if pick < 0.90 then return ROCK2 end
  if pick < 0.97 and has("BRCK") then return "BRCK" end
  return ROCK
end
-- ore/mineral veins: zoneScale/detailScale are both large so a "hit" fills most of a compact, contiguous blob
-- (Terraria-style vein) instead of speckling individual pixels - nothing here should read smaller than ~4-8px.
local function oreAt(wx, wy, d)
  local dm = SOIL_DEPTH_MUL
  if d > 20 * dm and vein(wx, wy, 950, 65, 0.80, 18, 0.50) then return "COAL" end
  if d > 60 * dm and vein(wx, wy, 953, 70, 0.84, 18, 0.50) then return "IRON" end
  if HASCU and d > 100 * dm and vein(wx, wy, 956, 75, 0.87, 17, 0.50) then return "CU" end
  if d > 160 * dm and vein(wx, wy, 959, 80, 0.90, 16, 0.50) then return "GOLD" end
  if d > 120 * dm and has("QRTZ") and vein(wx, wy, 962, 85, 0.90, 16, 0.48) then return "QRTZ" end
  if d > 420 * dm and vein(wx, wy, 965, 90, 0.90, 17, 0.52) then return UORE end
  local clayThresh = 0.88 - 0.10 * biomeWeight(wx, "swamp")
  if d < 260 * dm and vein(wx, wy, 968, 60, clayThresh, 16, 0.42) then return "CLST" end   -- clay/mud pocket: large, not freckled
  return nil
end
local function soilMaterial(wx, wy, d, biome)
  if biome == "desert" then return "SAND" end
  if biome == "snow" then if d == 0 then return has("SNOW") and "SNOW" or "ICE" end; return "ICE" end
  if biome == "forest" or biome == "swamp" or not biome then
    if d == 0 then return GRASS end
    local surf = wy - d
    local rv = rootVeinShapeAt(wx, wy, surf, d)
    if rv == "hollow" then return "" end
    if rv == "wood" then return "WOOD" end
    return "GOO"
  end
  return "GOO"
end
-- soil material blends per-pixel across the border band (fine dither weighted by t) instead of the whole column
-- committing to one biome's soil - this is what actually kills the "vertical wall of sand against dirt" (16:48).
local function soilAt(wx, wy, d)
  local here, other, t = blendAt(wx)
  local mat = soilMaterial(wx, wy, d, here)
  if other and t > 0.02 then
    local n = vnoise(wx/5, wy/5, 833)
    if n < t then mat = soilMaterial(wx, wy, d, other) end
  end
  return mat
end
local function rockAt(wx, wy, surf, d, biome)
  local here, other, t = blendAt(wx)
  local soilDepthFor = function(b) return floor((b == "desert" and 3 or (b == "snow" and 5 or 9)) * SOIL_DEPTH_MUL) end
  local soilD = other and (soilDepthFor(here) * (1 - t) + soilDepthFor(other) * t) or soilDepthFor(here)
  if d <= floor(soilD + 0.5) then return soilAt(wx, wy, d) end
  -- Extended subsoil: more GOO/dirt with depth noise before the stone strata kick in.
  local subDeep = soilD + floor(24 * SOIL_DEPTH_MUL + vnoise(wx / 18, wy / 14, 834) * 16 * SOIL_DEPTH_MUL)
  if d <= subDeep then return soilAt(wx, wy, d) end
  if wy >= DEPTH - 40 then return "DMND" end
  if wy >= DEPTH - 300 then    -- deep/"hell" zone: rare deep gem veins in dark, brimstone-patched rock
    if vein(wx, wy, 940, 90, 0.92, 18, 0.52) then return "DMND" end
    if has("TTAN") and vein(wx, wy, 945, 95, 0.88, 18, 0.48) then return "TTAN" end
    if has("BRMT") and vein(wx, wy, 1210, 70, 0.80, 16, 0.42) then return "BRMT" end
    return ROCK2
  end
  -- Snow biome used to return icy strata for the ENTIRE d<480 band and skip oreAt
  -- completely, so a snow region was a 480px ore-free ice slab. Measured before this
  -- change: 91.1% of solid cells were ICE and QRTZ was the biome's ONLY ore -- no coal,
  -- no iron, no copper, no clay -- meaning the tech tree simply could not be progressed
  -- anywhere in snow. Mountains made this far more visible by producing large snow
  -- landmasses. Now snow gets a genuine frozen crust (thick, distinct, still all ice),
  -- and below it normal rock WITH normal ore, threaded with ice lenses so it keeps a cold
  -- identity instead of becoming indistinguishable from forest rock.
  if biome == "snow" and d < 70 then return strataAt(wx, wy, d, true) end
  local ore = oreAt(wx, wy, d); if ore then return ore end
  return strataAt(wx, wy, d, false, biome == "snow" and d < 480)
end

-- ================================================================ structures: mineshafts (wood-framed tunnels), ruins (brick)
local MSHAFT_SP = 340
local mshaftCache = {}
local function mineshaftAt(cm)
  local m = mshaftCache[cm]; if m ~= nil then return m end
  if hash3(cm, 1021, 1) >= 0.5 then mshaftCache[cm] = false; return false end
  local x0 = cm*MSHAFT_SP + 30 + floor(hash3(cm,1021,2) * 60)
  m = { x0 = x0, x1 = x0 + 70 + floor(hash3(cm,1021,3) * 90), d0 = 60 + floor(hash3(cm,1021,4) * 500) }
  mshaftCache[cm] = m; return m
end
local function mineshaftHere(wx, wy, d)
  local cm = floor(wx / MSHAFT_SP)
  for cc = cm-1, cm+1 do
    local m = mineshaftAt(cc)
    if m and wx >= m.x0 and wx <= m.x1 and d >= m.d0 and d <= m.d0 + 6 then
      local rel, lx = d - m.d0, wx - m.x0
      if rel == 0 or rel == 6 then return "WOOD" end          -- roof / floor plank
      if lx % 16 == 0 or lx % 16 == 1 then return "WOOD" end  -- vertical support post every 16px
      return ""
    end
  end
  return nil
end
local RUIN_SP = 300
local ruinCache = {}
local function ruinAt(cr)
  local rr = ruinCache[cr]; if rr ~= nil then return rr end
  -- desert purpose: ancient ruins (with the chests they house) concentrate under the desert; base 30% chance
  -- everywhere else, up to 65% under solid desert - real BRCK structure, real R.chestAt loot, nothing invented.
  local existProb = 0.30 + 0.35 * biomeWeight(cr*RUIN_SP + RUIN_SP/2, "desert")
  if hash3(cr, 1051, 1) >= existProb then ruinCache[cr] = false; return false end
  local x0 = cr*RUIN_SP + 40 + floor(hash3(cr,1051,4) * 40)
  local d0 = 16 + floor(hash3(cr,1051,5) * 40)
  rr = { x0 = x0, x1 = x0 + 14 + floor(hash3(cr,1051,2) * 10), d0 = d0, d1 = d0 + 8 + floor(hash3(cr,1051,3) * 6) }
  ruinCache[cr] = rr; return rr
end
local function ruinHere(wx, wy, d)
  local cr = floor(wx / RUIN_SP)
  for cc = cr-1, cr+1 do
    local rr = ruinAt(cc)
    if rr and wx >= rr.x0 and wx <= rr.x1 and d >= rr.d0 and d <= rr.d1 then
      local onWall = (wx == rr.x0 or wx == rr.x1 or d == rr.d0 or d == rr.d1)
      if onWall then
        if vnoise(wx/2.3, wy/2.3, 1060) > 0.80 then return nil end   -- eroded gap: read as a ruin, not a pristine box
        return has("BRCK") and "BRCK" or ROCK
      end
      return ""
    end
  end
  return nil
end
-- ================================================================ community structure library
-- 30 structures were authored into knowledge/structures/*.json by @harvest (from 42 analysed
-- community saves) along with a reference loader in that folder's README, then never wired
-- into generation -- they have been delivering zero value since. This is that integration.
--
-- Deviations from the README's reference implementation, all of which were real bugs in it:
--   1. rollStructure() referenced an undefined `refY` (its parameter is named `surf`).
--   2. It had NO existence roll -- every cell of every category always won a structure, so
--      the world would have been wall-to-wall props. Each category now gets a probability,
--      matching ruinAt()'s own `if hash3(...) >= existProb then return false` idiom.
--   3. Structures.at() never queried the "detail" category at all, so 10 of the 30
--      structures (barrel/crate/campfire/lamp post/...) could never appear.
--   4. underground/deep passed raw `wy` as the anchor row, which smears a structure down
--      every row it is queried at. Each cell now rolls one d0 origin, the same way
--      mineshaftAt/ruinAt already roll theirs.
-- Not implemented (README sketches them, deliberately skipped as unneeded for a first pass):
-- min_spacing/clearance overlap rejection between neighbouring rolls, and the bridge/ladder
-- structure-specific placement predicates. Both are noted in knowledge/TODO.md.
local function jsonDecode(s)
  local i = 1
  local function skip() while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end end
  local parseValue
  local function parseString()
    i = i + 1; local buf = {}
    while true do
      local c = s:sub(i,i)
      if c == '"' then i = i + 1; break end
      if c == "\\" then
        local n = s:sub(i+1,i+1)
        local map = { n="\n", t="\t", r="\r", ['"']='"', ["\\"]="\\", ["/"]="/" }
        buf[#buf+1] = map[n] or n; i = i + 2
      else buf[#buf+1] = c; i = i + 1 end
    end
    return table.concat(buf)
  end
  local function parseNumber()
    local j = i
    while i <= #s and s:sub(i,i):match("[%d%.%-%+eE]") do i = i + 1 end
    return tonumber(s:sub(j, i-1))
  end
  local function parseArray()
    i = i + 1; local out = {}; skip()
    if s:sub(i,i) == "]" then i = i + 1; return out end
    while true do
      skip(); out[#out+1] = parseValue(); skip()
      if s:sub(i,i) == "," then i = i + 1 else break end
    end
    skip(); i = i + 1; return out
  end
  local function parseObject()
    i = i + 1; local out = {}; skip()
    if s:sub(i,i) == "}" then i = i + 1; return out end
    while true do
      skip(); local k = parseString(); skip(); i = i + 1; skip()
      out[k] = parseValue(); skip()
      if s:sub(i,i) == "," then i = i + 1 else break end
    end
    skip(); i = i + 1; return out
  end
  parseValue = function()
    skip(); local c = s:sub(i,i)
    if c == '"' then return parseString() end
    if c == "{" then return parseObject() end
    if c == "[" then return parseArray() end
    if s:sub(i,i+3) == "true" then i = i + 4; return true end
    if s:sub(i,i+4) == "false" then i = i + 5; return false end
    if s:sub(i,i+3) == "null" then i = i + 4; return nil end
    return parseNumber()
  end
  return parseValue()
end
local function pickEl(primary, fallback) return has(primary) and primary or fallback end
-- Logical material token -> real element. Resolved once at load, never per pixel. Reuses
-- world.lua's own ROCK/ROCK2 for stone/concrete per the README's own advice, rather than
-- duplicating a second fallback chain that could drift from them.
local SMATERIAL = {
  wood = "WOOD", brick = has("BRCK") and "BRCK" or ROCK, glass = pickEl("GLAS", "BRCK"),
  stone = ROCK, concrete = ROCK2,
  glass_colored = pickEl("BGLA", "GLAS"), metal = pickEl("STEL", "METL"),
  metal_old = pickEl("BMTL", "METL"), bronze = pickEl("BRMT", "METL"),
  iron_ore = pickEl("IRON", "BRMT"), coal = "COAL", gold = pickEl("GOLD", "BRMT"),
  copper = pickEl("CU", "METL"), clay = pickEl("CLST", "SAND"),
  crystal = pickEl("QRTZ", "GLAS"), plant = GRASS, glow = pickEl("GLOW", "GLAS"),
  ice = "ICE", snow = "SNOW", sand = "SAND", water = "WATR", lava = "LAVA",
  bone = "SAND",
}
local STRUCT_DIR = "D:/powder-toy/knowledge/structures/"
local STRUCT_FILES = {
  "surface_cabin_small","surface_watchtower","surface_well","surface_campsite","surface_farm_plot",
  "surface_bridge_wood","surface_signpost","surface_ruined_wall",
  "underground_mineshaft_junction","underground_collapsed_tunnel","underground_miners_camp",
  "underground_ore_cart","underground_ladder_shaft","underground_water_cistern","underground_shrine",
  "underground_sealed_vault",
  "deep_lava_forge_ruin","deep_crystal_chamber","deep_abandoned_reactor_room","deep_bone_pit",
  "detail_rubble_pile","detail_crate","detail_barrel","detail_torch_sconce","detail_broken_pipe",
  "detail_broken_cart","detail_old_machine_husk","detail_fence_post","detail_lamp_post","detail_campfire_small",
}
local SByCat, SLoaded = {}, 0
for _, name in ipairs(STRUCT_FILES) do
  local f = io.open(STRUCT_DIR .. name .. ".json", "r")
  if f then
    local raw = f:read("*a"); f:close()
    local ok, def = pcall(jsonDecode, raw)
    if ok and type(def) == "table" and def.grid and def.legend and def.anchor then
      SByCat[def.category] = SByCat[def.category] or {}
      table.insert(SByCat[def.category], def)
      SLoaded = SLoaded + 1
    end
  end
end
R.structuresLoaded = SLoaded   -- probe hook: how many of the 30 actually parsed
-- Grid pitch and per-cell existence odds per category. Pitch >= the largest min_spacing in
-- that category; odds keep the world mostly natural instead of a theme park.
local SCAT = {
  surface     = { sp = 240, prob = 0.46 },
  detail      = { sp = 90,  prob = 0.35 },
  underground = { sp = 300, prob = 0.45 },
  deep        = { sp = 440, prob = 0.40 },
}
local sCache = {}
local function sBiomeOk(def, biome)
  for _, b in ipairs(def.biomes or {}) do if b == "any" or b == biome then return true end end
  return false
end
local function sRoll(cat, cellIdx, wx0, biome, refY)
  local pool = SByCat[cat]; if not pool then return false end
  if hash3(cellIdx, 8801, cat == "detail" and 3 or 1) >= SCAT[cat].prob then return false end
  -- Category already partitions by depth (surface/detail sit on the ground, underground/deep
  -- roll their own d0 band below), so biome is the only per-structure filter needed here.
  local elig = {}
  for _, def in ipairs(pool) do
    if sBiomeOk(def, biome) then elig[#elig+1] = def end
  end
  if #elig == 0 then return false end
  local total = 0
  for _, def in ipairs(elig) do total = total + (def.rarity or 0.1) end
  local r = hash3(cellIdx, 8801, 2) * total
  local chosen = elig[1]
  for _, def in ipairs(elig) do r = r - (def.rarity or 0.1); if r <= 0 then chosen = def; break end end
  if (cat == "surface" or cat == "detail") and chosen.rest_on_solid then
    -- surfaceAt(wx0) IS the first solid row, so a flat-ground test there is vacuous; the real
    -- hazard is a WIDE structure whose far edge overhangs a slope.
    -- Tolerance scales with footprint width rather than a flat 3px: once real mountains
    -- existed, a flat budget measured out at rejecting 9 of 15 landmark-scale rolls (60%),
    -- leaving only 1.8 buildings per 3000px -- roughly one per five screens, far too sparse
    -- to feel discoverable. A 15-wide cabin tolerating a 5px rise is still a sane, near-flat
    -- footing; what this rejects is genuine cliff edges and cave mouths.
    local w = chosen.width or 1
    if math.abs(surfaceAt(wx0 + w) - refY) > math.max(3, w * 0.35) then return false end
  end
  return { def = chosen, x0 = wx0, y0 = refY }
end
local function sQuery(cat, wx, wy, refX, refY, biome)
  local C = SCAT[cat]; if not C then return nil end
  local cellIdx = floor(refX / C.sp)
  sCache[cat] = sCache[cat] or {}
  local cache = sCache[cat]
  for cc = cellIdx - 1, cellIdx do
    local inst = cache[cc]
    if inst == nil then
      local cellX0 = cc * C.sp + 10 + floor(hash3(cc, 8802, 2) * (C.sp - 20))
      -- anchor row: surface/detail sit on the ground at their own column; underground/deep
      -- roll ONE depth origin per cell (mineshaftAt's idiom) instead of following the query
      -- row, which would smear the structure down every row it was asked about.
      local rY = refY
      if cat == "underground" then rY = surfaceAt(cellX0) + 60 + floor(hash3(cc, 8803, 4) * 420)
      elseif cat == "deep" then rY = surfaceAt(cellX0) + 520 + floor(hash3(cc, 8803, 5) * 600) end
      if cat == "surface" or cat == "detail" then rY = surfaceAt(cellX0) end
      inst = sRoll(cat, cc, cellX0, biome, rY)
      cache[cc] = inst
    end
    if inst then
      local def = inst.def
      local gx = wx - inst.x0 + def.anchor.x
      local gy = wy - inst.y0 + def.anchor.y
      if gx >= 0 and gx < def.width and gy >= 0 and gy < def.height then
        local row = def.grid[gy + 1]
        if row then
          local tok = def.legend[row:sub(gx + 1, gx + 1)]
          if tok == "air" then return "" end
          if tok and tok ~= "keep" then return SMATERIAL[tok] end
        end
      end
    end
  end
  return nil
end
local function libStructHere(wx, wy, surf, d, biome)
  if SLoaded == 0 then return nil end
  local s = sQuery("surface", wx, wy, wx, surf, biome); if s ~= nil then return s end
  local t = sQuery("detail", wx, wy, wx, surf, biome);  if t ~= nil then return t end
  if d and d > 40 then
    local cat = (d > 500) and "deep" or "underground"
    local u = sQuery(cat, wx, wy, wx, wy, biome); if u ~= nil then return u end
  end
  return nil
end
local function structureAt(wx, wy, surf, d, biome)
  if wy >= DEPTH - 60 then return nil end
  local r = ruinHere(wx, wy, d); if r ~= nil then return r end
  local m = mineshaftHere(wx, wy, d); if m ~= nil then return m end
  return libStructHere(wx, wy, surf, d, biome)
end

-- ================================================================ ambience: parallax background (R.hooks.draw)
-- runs once per frame after the core's flat sky/darkness overlay and before the player sprite (see README).
-- Surface-only by design: an underground cave-wall backdrop was tried and pulled per the player's call (16:18) - it read
-- as "whack" over TPT's black empty space. Just the sky parallax hills/treeline and night fireflies remain.
local function drawTreeAccents(camx, camy, W, H, frame, night)
  local moist = R.treeMoisture or {}
  local raining = R.weather and R.weather.rain
  local c0 = floor((camx - 40) / vsp())
  local c1 = floor((camx + W + 40) / vsp())
  for cc = c0, c1 do
    local v = vegAt(cc)
    if not v or v.kind ~= "tree" then goto tree_acc_next end
    local top, tw, x0, s = v.s - v.h, v.trunkW or 3, v.x0, v.s
    local hollowCol = (tw >= 3) and (x0 + floor(tw / 2)) or nil
    local m = hollowCol and (moist[hollowCol .. "," .. s] or 0) or 0
    local showVeins = hollowCol and m > 0.5   -- blue hint only when real water in the vein (not rain alone)
    local wy0, wy1 = max(top, camy), min(s + 2, camy + H - 1)
    for wy = wy0, wy1 do
      local sy = wy - camy
      if sy < 0 or sy >= H then goto wy_acc_next end
      -- trunk edge saturation: darker WOOD rim so trunks don't read washed-out under parallax
      for edge = 0, tw - 1 do
        local wx = x0 + edge
        if wx == x0 or wx == x0 + tw - 1 then
          if vegShapeAt(wx, wy) == "WOOD" then
            local sx = wx - camx
            if sx >= 0 and sx < W then
              local shade = night > 0.3 and 50 or 68
              graphics.fillRect(floor(sx), floor(sy), 1, 1, shade, shade - 18, 28, 210)
            end
          end
        end
      end
      -- No canopy tint — green overlay read as "tree rotting"; water is real WATR particles only.
      ::wy_acc_next::
    end
    if showVeins and m > 0.5 then
      -- Thin blue hint in hollow trunk air (actual water is spawned in rpg.lua treeHollowDripTick).
      local pulse = 0.5 + 0.5 * abs(math.sin(frame / 9 + cc))
      local a = floor(70 + 50 * pulse * min(1, m / 25))
      for wy = top + 1, s + 1 do
        local sx, sy = hollowCol - camx, wy - camy
        if sx < 0 or sx >= W or sy < 0 or sy >= H then goto vein_next end
        if vegShapeAt(hollowCol, wy) == nil then
          graphics.fillRect(floor(sx), floor(sy), 1, 1, 50, 130, 230, a)
        end
        ::vein_next::
      end
      -- Branching root veins underground (visible when dug open or thin soil).
      if m > 1 then
        local rootA = floor(45 + 35 * pulse * min(1, m / 30))
        local maxD = floor(8 + v.h * 0.14 * SOIL_DEPTH_MUL)
        local surf = surfaceAt(x0)
        for i = 0, ROOT_BRANCHES - 1 do
          local bd = floor(2 + i * (2.2 + hash3(cc, 850, i) * 2.8))
          if bd > maxD - 2 then break end
          local dir = hash3(cc, 851, i) < 0.5 and -1 or 1
          local len = 8 + floor(hash3(cc, 852, i) * 18)
          local y0 = s + bd
          local x1, y1 = hollowCol, y0
          local x2, y2 = hollowCol + dir * len, y0 + 1 + floor(hash3(cc, 853, i) * 4)
          for t = 0, 20 do
            local u = t / 20
            local rx = floor(x1 + (x2 - x1) * u)
            local ry = floor(y1 + (y2 - y1) * u)
            if rootVeinShapeAt(rx, ry, surf, ry - surf) == "hollow" then
              local sx, sy = rx - camx, ry - camy
              if sx >= 0 and sx < W and sy >= 0 and sy < H then
                graphics.fillRect(floor(sx), floor(sy), 1, 1, 40, 110, 210, rootA)
              end
            end
          end
        end
        for wy = s + 1, s + maxD do
          if rootVeinShapeAt(hollowCol, wy, surf, wy - surf) == "hollow" then
            local sx, sy = hollowCol - camx, wy - camy
            if sx >= 0 and sx < W and sy >= 0 and sy < H then
              graphics.fillRect(floor(sx), floor(sy), 1, 1, 40, 110, 210, rootA)
            end
          end
        end
      end
    end
    ::tree_acc_next::
  end
end
local function worldDraw()
  local camx, camy, W, H = R.cam.x, R.cam.y, R.W, R.H
  local frame = R.frame or 0
  local night = max(0, math.sin((((frame % 14000) / 14000) - 0.5) * math.pi * 2))

  -- two parallax layers (far hills, nearer treeline) drifting slower than the real foreground as the camera moves
  local farR, farG, farB = (night > 0.3) and 35 or 120, (night > 0.3) and 45 or 150, (night > 0.3) and 70 or 190
  local nrR, nrG, nrB = (night > 0.3) and 15 or 55, (night > 0.3) and 30 or 95, (night > 0.3) and 20 or 55
  for sx = 0, W - 1, 6 do
    local wxMid = sx + camx + 3
    if treeCoversColumn(wxMid) then goto parallax_skip end   -- v1.15.40: don't wash out real tree pixels
    local realSurfY = surfaceAt(sx + camx) - camy
    if realSurfY > 4 then
      local farY = 120 - camy*0.12 + 34 * (vnoise((camx*0.12 + sx)/150, 3, 300) - 0.5) * 2
      local top = max(0, floor(farY)); local bot = min(H, floor(realSurfY))
      if top < bot then graphics.fillRect(sx, top, 6, bot - top, farR, farG, farB, 130) end
      local bx2 = camx*0.32 + sx
      local nearY = 150 - camy*0.32 + 22 * (vnoise(bx2/70, 9, 320) - 0.5) * 2 - 18 * max(0, vnoise(bx2/9, 1, 321) - 0.55)
      top, bot = max(0, floor(nearY)), min(H, floor(realSurfY))
      if top < bot then graphics.fillRect(sx, top, 6, bot - top, nrR, nrG, nrB, 150) end
    end
    ::parallax_skip::
  end
  drawTreeAccents(camx, camy, W, H, frame, night)

  -- fireflies drifting over forest/swamp treelines at night
  if night > 0.35 then
    for i = 1, 18 do
      local wx = camx + ((hash3(i,1,410) * 1400 + frame * 0.25) % 1400) - 200
      local b = biomeAt(floor(wx))
      if b == "forest" or b == "swamp" then
        local sx2, sy = wx - camx, surfaceAt(floor(wx)) - camy - 3 - 5 * math.abs(math.sin(frame/26 + i))
        if sx2 > -4 and sx2 < W + 4 and sy > 0 and sy < H then
          graphics.fillRect(floor(sx2), floor(sy), 1, 1, 210, 255, 120, min(255, 120 + floor(100 * math.abs(math.sin(frame/9 + i*2)))))
        end
      end
    end
  end
end

-- ================================================================ felling: chop the base, the whole tree comes down
-- R.hooks.mine fires (el, n) with no position, so we use R.swingAt (set by the core's own mining code, same frame)
-- as the chop location. If that chop was within ~6px of solid non-wood ground (i.e. it was the trunk's base), flood
-- fill the connected WOOD/GRSS particles above it (capped at 800 cells, 8-connected) and remove them top-down over
-- ~20 frames, paying out ~1 WOOD per 2 trunk cells removed. Leaves (GRSS) just vanish.
local function partAt(wx, wy)
  local cx, cy = wx - R.cam.x, wy - R.cam.y
  if cx < R.M or cx >= R.W - R.M or cy < R.M or cy >= R.H - R.M then return nil end
  local p = sim.partID(cx, cy); if not p then return nil end
  return p, R.nameOf(sim.partProperty(p, "type"))
end
local function isTreeMat(nm) return nm == "WOOD" or nm == GRASS or nm == "PLNT" end
local fell = nil   -- { cells = {{x,y},...} sorted top-down, idx, trunkN, per }
hook(R.hooks.mine, function(el, n)
  if fell or el ~= "WOOD" or (n or 0) <= 0 then return end
  local sw = R.swingAt; if not sw or (R.frame - sw[3]) > 1 then return end
  local wx0, wy0 = sw[1] + R.cam.x, sw[2] + R.cam.y
  local nearGround = false
  for dy = 0, 6 do local p2, nm2 = partAt(wx0, wy0 + dy); if p2 and not isTreeMat(nm2) then nearGround = true; break end end
  if not nearGround then return end
  local seen, cells, stack = {}, {}, {}
  for ddx = -5, 5 do for ddy = -8, 3 do
    local x, y = wx0 + ddx, wy0 + ddy; local key = x*100000 + y
    if not seen[key] then local p2, nm2 = partAt(x, y); if p2 and isTreeMat(nm2) then seen[key] = true; stack[#stack+1] = {x,y} end end
  end end
  local head = 1
  local NB = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}}
  while head <= #stack and #stack < 800 do
    local c = stack[head]; head = head + 1
    for _, o in ipairs(NB) do
      local x, y = c[1]+o[1], c[2]+o[2]; local key = x*100000 + y
      if not seen[key] then
        local p2, nm2 = partAt(x, y)
        if p2 and isTreeMat(nm2) then seen[key] = true; stack[#stack+1] = {x,y} end
      end
    end
  end
  if #stack < 6 then return end   -- too small to be a real tree (stray plank etc.)
  table.sort(stack, function(a, b) return a[2] < b[2] end)   -- top (smallest y) first
  fell = { cells = stack, idx = 1, trunkN = 0, per = max(2, math.ceil(#stack / 20)) }
  R.say("Timber!")
end)
hook(R.hooks.tick, function()
  if not fell then return end
  local n = 0
  while n < fell.per and fell.idx <= #fell.cells do
    local c = fell.cells[fell.idx]; fell.idx = fell.idx + 1
    local p2, nm2 = partAt(c[1], c[2])
    if p2 then if nm2 == "WOOD" then fell.trunkN = fell.trunkN + 1 end; sim.partKill(p2) end
    n = n + 1
  end
  if fell.idx > #fell.cells then
    R.give("WOOD", max(1, floor(fell.trunkN / 2)))
    fell = nil
  end
end)

-- ================================================================ biome purpose (the player 16:52: "the biomes all have to
-- have a purpose and stuff"). Each biome's signature resources are wired in above (beehive/GOLD + vines in the flora
-- section, oasis water + brick "fossil" strata + heat-scaled ruins in desert, crystal-boosted caves in snow, clay
-- veins + real OIL/GAS pockets + poisonous water in swamp); what's left is the two active surface hazards (desert
-- midday heat, snow hypothermia without a fire) and the "biome sign" announcement on entry.
local function isMiddayHot()   -- mirrors core's day-cycle constant (14000f); sun peaks near phase 0.25 (see rpg.lua's
  local phase = ((R.frame or 0) % 14000) / 14000            -- own sun-arc math) - a window either side of that is "midday"
  return phase > 0.15 and phase < 0.35
end
local function nearHeatSource(wx, wy)   -- real fire/lava/plasma/hot particle nearby - a torch or furnace counts
  for oy = -20, 6, 4 do for ox = -14, 14, 4 do
    local p = sim.partID(wx + ox - R.cam.x, wy + oy - R.cam.y)
    if p then
      local nm = R.nameOf(sim.partProperty(p, "type")); local t = sim.partProperty(p, "temp") or 295
      if nm == "FIRE" or nm == "LAVA" or nm == "PLSM" or t > 320 then return true end
    end
  end end
  return false
end
local snowChill = 0
hook(R.hooks.tick, function()
  if R.frame % 20 ~= 0 or not R.P then return end
  local wx, wy = floor(R.P.x), floor(R.P.y)
  -- desert: scorching midday surface heat - a real reason to duck into shade or dig in rather than walk the dunes at noon
  local wDesert = biomeWeight(wx, "desert")
  if wDesert > 0.5 and wy <= surfaceAt(wx) + 6 and isMiddayHot() then
    R.hp = math.max(0, R.hp - 1); R.hurt = R.frame
    if R.frame % 100 == 0 then R.say("The midday desert sun is brutal out here - find shade or dig in") end
  end
  -- snow: hypothermia without a nearby fire - a grace period (~5s) before the cold actually starts hurting
  local wSnow = biomeWeight(wx, "snow")
  if wSnow > 0.5 then
    if nearHeatSource(wx, wy) then snowChill = max(0, snowChill - 2)
    else
      snowChill = snowChill + 1
      if snowChill > 15 then
        R.hp = math.max(0, R.hp - 1); R.hurt = R.frame
        if R.frame % 100 == 0 then R.say("You're freezing out here - get near a fire or torch") end
      end
    end
  else snowChill = 0 end
end)

-- "biome sign" - name the biome and what it offers, once, the moment you clearly enter it (not while flickering
-- through the dithered border band: wait until t < 0.2, i.e. solidly on one side, before trusting the reading).
local BIOME_SIGN = {
  forest = "FOREST - safe ground. Wood and food: chop the groves, raid a wild beehive in the oak canopies.",
  desert = "DESERT - sand for glass, brick fossil-beds and ruined chests below, an oasis if you can find one. Watch the midday sun.",
  snow   = "SNOW - ice and snow, and crystal-rich frozen caves beneath. Keep a fire close or the cold will take you.",
  swamp  = "SWAMP - mud and clay, real oil and gas underground, plants everywhere. The water here is not all safe to drink.",
}
-- exposed for @guide's ONI-style database (hub 15:40 ask): where each biome is found and why you'd go there,
-- plus the depth-band table so descending has a labelled, discoverable progression in the guide too.
R.biomeInfo = {
  forest = { hazard = "none - the safe starting biome", offers = "Wood (chop trees, felling drops bonus logs), rare wild-beehive GOLD caches in oak canopies" },
  desert = { hazard = "midday surface heat drains HP in the open sun", offers = "Sand (smelt to Glass), brick fossil-bed strata, ruins with chests (more common than elsewhere), oasis water+palms" },
  snow   = { hazard = "hypothermia - HP drains if you linger away from a fire/torch", offers = "Ice/Snow, frozen caves with boosted Quartz crystal odds" },
  swamp  = { hazard = "some surface pools are poisonous (SLTW blocks oxygen, rare CAUS burns)", offers = "Clay/Mud (boosted CLST veins), real Oil and Gas pockets underground, dense plant cover" },
}
local lastBiomeSign = nil
hook(R.hooks.tick, function()
  if R.frame % 15 ~= 0 or not R.P then return end
  local here, other, t = blendAt(floor(R.P.x))
  if t >= 0.2 then return end
  if here ~= lastBiomeSign then lastBiomeSign = here; if BIOME_SIGN[here] then R.say(BIOME_SIGN[here]) end end
end)

-- depth bands already exist (strata/ore gating above); announce the milestone once per descent so it reads as
-- progress, same "only on change" rule as the biome sign.
local DEPTH_BANDS = {
  { d = 0,          name = "Topsoil",          note = "thick dirt and roots" },
  { d = 20 * SOIL_DEPTH_MUL, name = "Coal Seams", note = "coal veins to fuel a furnace" },
  { d = 60 * SOIL_DEPTH_MUL, name = "Iron Belt",  note = "iron ore for real tools" },
  { d = 100 * SOIL_DEPTH_MUL, name = "Copper Vein", note = "copper for wiring" },
  { d = 160 * SOIL_DEPTH_MUL, name = "Gold Reef", note = "gold reefs - watch for flooded caverns" },
  { d = 250 * SOIL_DEPTH_MUL, name = "Flooded Caverns", note = "deep lakes, mind your oxygen" },
  { d = 420 * SOIL_DEPTH_MUL, name = "Uranium Shelf", note = "radioactive ore - keep lead handy" },
  { d = DEPTH-300,  name = "The Deep",         note = "lava, brimstone, rare titanium and bronze" },
  { d = DEPTH-40,   name = "Bedrock",          note = "diamond-laced bedrock, the bottom of the world" },
}
R.depthInfo = DEPTH_BANDS
local lastDepthBand = nil
hook(R.hooks.tick, function()
  if R.frame % 20 ~= 0 or not R.P then return end
  local wx = floor(R.P.x)
  local d = floor(R.P.y) - surfaceAt(wx)
  if d < 0 then return end
  local band = DEPTH_BANDS[1]
  for _, b in ipairs(DEPTH_BANDS) do if d >= b.d then band = b end end
  if band ~= lastDepthBand then
    if lastDepthBand then R.say(band.name .. " - " .. band.note) end
    lastDepthBand = band
  end
end)

-- ================================================================ tie it together
-- Cave pocket microclimates for env sampling (swamp warmth, crystal chill, deep heat).
function R.pocketEnvBias(wx, wy, d)
  local tempOff, pressOff = 0, 0
  if d > 40 and d < 520 and biomeWeight(wx, "swamp") > 0.38 and swampGasZoneAt(wx, wy) then
    tempOff = tempOff + 10 + vnoise(wx / 18, wy / 18, 1232) * 14
    pressOff = pressOff + 1.8
  end
  if d > 120 and geodeZoneAt(wx, wy) then
    tempOff = tempOff - 14 - vnoise(wx / 22, wy / 22, 921) * 12
  end
  if d > 950 and hellLavaAt(wx, wy) then
    tempOff = tempOff + 45 + vnoise(wx / 16, wy / 16, 1221) * 20
    pressOff = pressOff + 3.5
  end
  return tempOff, pressOff
end
local function worldGen(wx, wy)
  if wy >= DEPTH then return "DMND" end
  local surf = surfaceAt(wx)
  local biome = biomeAt(wx)
  if wy < surf then
    -- Structure library must be consulted ABOVE ground too. structureAt() is only reached in
    -- the wy >= surf branch below, which was fine while the only structures were ruins and
    -- mineshafts (both underground) -- but a cabin/well/campsite draws its body above the
    -- surface line, so those cells were short-circuiting into aboveGround() and the entire
    -- surface + detail half of the library could never place. Verified: before this, a
    -- 3001-column scan found zero structure materials above ground.
    local sa = libStructHere(wx, wy, surf, nil, biome); if sa ~= nil then return sa end
    return aboveGround(wx, wy, surf, biome)
  end
  local d = wy - surf
  local st = structureAt(wx, wy, surf, d, biome); if st ~= nil then return st end
  local cave = caveAt(wx, wy, surf, d, biome); if cave ~= nil then return cave end
  return rockAt(wx, wy, surf, d, biome)
end
hook(R.hooks.gen, worldGen)
hook(R.hooks.draw, worldDraw)
