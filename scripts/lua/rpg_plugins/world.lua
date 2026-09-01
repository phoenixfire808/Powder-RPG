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
-- New veins (design: knowledge/design-material-progression.md chains 3/8). Verified live via
-- scripts/check_terrain_solid.py: PTNM and ISZS are TYPE_SOLID/falldown=0 (SAFE, placed as
-- normal solid vein() ore below). DEUT/MERC are TYPE_LIQUID (falldown=2) and LITH is TYPE_PART
-- (falldown=1) -- all three UNSAFE by the strict terrain-fill check, so none of them are used
-- as bulk fill; each is placed as a compact vein-shaped POCKET, the same already-shipped
-- pattern as CLST (a Falldown=1 powder already placed via oreAt's vein()) and the WATR
-- aquifer (a liquid embedded inert in solid rock until something opens it, then floods) --
-- this is the "ore vein in solid rock, lower risk than bulk fill" case, not the STNE bulk-
-- subsoil bug shape (ADR-003). Raw liquid ISOZ has no separate worldgen source this pass --
-- only its solid twin ISZS is placed; flagged for @matimpl if a recipe needs raw ISOZ directly.
local HASMERC = has("MERC")
local HASLITH = has("LITH")
local HASPTNM = has("PTNM")
local HASDEUT = has("DEUT")
local HASISZS = has("ISZS")
local HASBMTL = has("BMTL")
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
      return { kind="tree", species="palm", x0=x, trunkW=4, h = 30 + floor(hash3(cell,salt,3)*26),
            cw = 34 + floor(hash3(cell,salt,9)*18), ch = 14, s = surfaceAt(x), oasis = true }
    end
    return false
  elseif biome == "snow" then
    if forceTree or h1 < 0.34 * scale then
      local x = cell*vsp() + 6 + floor(hash3(cell,salt,2) * (vsp()-12))
      return { kind="tree", species="pine", x0=x, trunkW = 5 + floor(hash3(cell,salt,8)*4), h = 48 + floor(hash3(cell,salt,3)*36),
            cw = 38 + floor(hash3(cell,salt,9)*22), ch = 0, s = surfaceAt(x) }
    end
    return false
  elseif biome then
    local prob = (biome == "swamp" and 0.42 or 0.62) * scale
    if forceTree or h1 < prob then
      local x = cell*vsp() + 6 + floor(hash3(cell,salt,2) * (vsp()-12))
      local species = (biome == "swamp" and hash3(cell,salt,10) < 0.55) and "dead" or "oak"
      -- SCALE against the real player box (BOXL/BOXR/BOXT in rpg.lua => 4px wide, 10px tall):
      -- oaks were trunkW 4-7 on a 50-91px tree, i.e. a trunk barely wider than the player and
      -- ~1:12 against its own height, with a canopy only about half the tree's height. That is
      -- what makes them read as "bare poles with a green blob" rather than trees. Trunks are now
      -- 7-12px (1.75-3 player-widths) and the canopy is roughly as wide as the tree is tall,
      -- which is the proportion an actual broadleaf has.
      return { kind="tree", species=species, x0=x, trunkW = 7 + floor(hash3(cell,salt,8)*5), h = 50 + floor(hash3(cell,salt,3)*41),
            cw = 48 + floor(hash3(cell,salt,9)*32), ch = 30 + floor(hash3(cell,salt,11)*16), s = surfaceAt(x) }
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
    -- DIRT SPECKLING: this took v.s (the tree's surfaceAt sample cached once at roll time,
    -- same staleness class as the buried-trees bug above) as the root system's ground anchor,
    -- even though root/hollow/wood shapes are queried for columns up to 3 veg cells (<=90px)
    -- away from the tree's own column -- surfaceAt's small-scale octaves drift well past a
    -- root's own span (8-26px) over that distance, so wood/hollow patches landed at depths
    -- that don't line up with the tree's REAL trunk base, reading as dirt "speckled" with
    -- misplaced wood/hollow flecks. Root systems belong to the tree at x0, not the query
    -- column wx, so anchor on a fresh surfaceAt(x0) (memoized, same cost as the old field
    -- read) rather than either the stale cache or the caller's own `surf` arg for wx.
    local x0, tw = v.x0, v.trunkW or 3
    local s = surfaceAt(x0)
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
-- CANOPY POROSITY (2026-09-01, PhoenixFire808's "huge issue": gas needs to travel through/between
-- trees). This is the honest, engine-safe half of that fix -- see knowledge/rpg-hub.md 2026-09-01
-- @foliage for why a can_move override was tried and rejected (it would teleport real leaf
-- particles, confirmed against Simulation.cpp's swap code). Instead of changing how gas moves,
-- this changes what worldgen PLACES: a handful of the canopy's own real interior pixels are left
-- as genuine open air instead of solid GRASS/PLNT, so gas has real empty cells to occupy and pass
-- through -- zero physics change, zero drift risk, nothing here touches can_move or any element's
-- Properties. This is a MITIGATION (real but partial: helps gas already inside/near the canopy
-- interior; does not make solid WOOD/rim pixels gas-permeable). The durable fix is a real engine
-- gas-occupancy layer -- written up as a spec for @engine in this pass's report, not built here.
-- R.treeCanopyPorosity (Options-menu tunable, same pattern as R.treeSpacingMul/R.oreRarityMul/
-- R.caveFreqMul): 1.0 = default, 0 = fully solid canopies (old behaviour, rim-only protection
-- still applies at any setting), >1 = more holes. One knob, so "more"/"less" is a live one-line
-- change rather than a rewrite, per his standing request that these systems stay tunable.
local CANOPY_HOLE_SCALE = 5        -- noise-cell size in px: small clustered patches (natural
                                    -- light-through-leaves), not per-pixel salt-and-pepper
local CANOPY_HOLE_THRESH_BASE = 0.80
local function canopyPorosityMul() return R.treeCanopyPorosity or 1 end
local function canopyHoleAt(wx, wy, salt)
  local mul = canopyPorosityMul()
  if mul <= 0 then return false end
  local thresh = CANOPY_HOLE_THRESH_BASE - (mul - 1) * 0.25
  return vnoise(wx / CANOPY_HOLE_SCALE, wy / CANOPY_HOLE_SCALE, salt) > thresh
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
        --
        -- BURIED/FLOATING TREES: v.s is surfaceAt(x0) sampled ONCE when this tree was rolled,
        -- but the trunk is 7-12px wide (widened from 4-7px for the "lamp post" fix) and the
        -- worldgen dispatch (worldGen's `wy < surf` gate) tests each column against its own
        -- FRESH surfaceAt(wx). The 22px/60px "small detail" hill octaves (surfaceAt in rpg.lua)
        -- can swing several px across a span that short, so a real per-column surface a few px
        -- shallower than v.s clips the trunk's bottom under real dirt/rock before the fill loop
        -- even reaches it (buried), and a few px deeper than v.s leaves open air under the
        -- trunk's assumed base (floating). Bounding the trunk's bottom edge by the REAL
        -- per-column surface instead of the tree's single cached sample makes it hug the actual
        -- ground at every column -- top (canopy anchor) is untouched, only where the trunk
        -- visually terminates changes.
        if wx >= x0 and wx < x0 + tw and wy >= top and wy <= surfaceAt(wx) then
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
          -- Porosity note: the satellite lobes below and the main body ellipse overlap heavily
          -- (a satellite's own radius is nearly as big as the main body's, just offset). Two
          -- earlier versions of this got the overlap rule wrong, both caught live via R.gen()
          -- measurement rather than assumed: v1 gated only the main ellipse and left satellites
          -- unconditional -- satellites silently covered almost the whole interior, 0 holes at
          -- any setting. v2 required EVERY covering shape to independently agree a point was
          -- deep interior -- correct but so conservative (a point deep in the main ellipse is
          -- usually near the EDGE of at least one offset satellite) that porosity=1 only flipped
          -- 13/2416 canopy cells (0.5%) in a live measured sample -- real but too sparse to move
          -- his "huge issue". This version uses the BEST (tightest-fitting) covering shape: a
          -- point is rim-protected only if its closest shape is itself near that shape's OWN
          -- edge (bestVal>0.45) -- i.e. every shape covering it is at least that close to its
          -- edge too, since bestVal is the minimum. Measured after this fix in the same pass.
          local ccy = top + v.ch * 0.10
          local bestVal = nil
          local sharedHole = canopyHoleAt(wx, wy, 900)
          for i = 0, 4 do
            local ang = (i / 4) * math.pi
            local ox = math.cos(ang) * v.cw * 0.34 * (0.7 + hash3(cc,814,i) * 0.5)
            local oy = -math.sin(ang) * v.ch * 0.42 * (0.7 + hash3(cc,814,i+9) * 0.5)
            local ecx, ecy, erx, ery = cx+ox, ccy+oy - v.ch*0.12, v.cw*0.30, v.ch*0.55
            local ddx, ddy = (wx-ecx)/erx, (wy-ecy)/ery
            local val = ddx*ddx + ddy*ddy
            if val <= 1 and (not bestVal or val < bestVal) then bestVal = val end
          end
          do
            local rxo, ryo = v.cw*0.42, v.ch*0.60
            local ddx, ddy = (wx-cx)/rxo, (wy-ccy)/ryo
            local val = ddx*ddx + ddy*ddy
            if val <= 1 and (not bestVal or val < bestVal) then bestVal = val end
          end
          -- Rim stays dense at every porosity setting (bestVal>0.45, meaning this point is close
          -- to the edge of EVERY shape covering it, not just its loosest one) so the tree still
          -- reads as a bounded silhouette per request #1; holes only ever land where its single
          -- tightest-fitting covering shape says deep interior.
          if bestVal and (bestVal > 0.45 or not sharedHole) then return GRASS end
          -- bestVal set but the check above didn't return: deep interior AND sharedHole true --
          -- a genuine hole. Falls through (no return) rather than a goto: the beehive check
          -- below tests its own separate small ellipse near the canopy top and should still be
          -- able to fire regardless of whether this exact pixel is leaf or a hole.
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
            local effRad = rad*(1-((wy-ry+1)/(tierH*1.6)))
            if wy >= ry-1 and wy <= ry + tierH*1.3 and abs(wx-cx) <= effRad then
              if k == 0 and wy <= ry+1 then return (has("SNOW") and "SNOW" or "ICE") end
              -- same rim-protection rule as oak: only the inner half of each tier's radius
              -- can hole out, so every tier's own taper stays a solid, readable cone edge.
              local frac = effRad > 0 and (abs(wx-cx) / effRad) or 1
              if frac > 0.5 or not canopyHoleAt(wx, wy, 901) then return GRASS end
            end
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
  -- Thinned from 0.97 (3% of columns) to 0.982 (1.8%): the depth-parameterised worms are now
  -- the vertical CONNECTORS between horizontal galleries rather than the primary cave form,
  -- so fewer of them both shifts the horizontal:vertical balance and offsets the extra open
  -- volume that came from widening every bore to fit the player.
  local thresh = 1 - (1 - 0.982) * (R.caveFreqMul or 1)
  if hash3(cw, 701, 1) >= thresh then wormCache[cw] = false; return false end
  local isEntrance = hash3(cw,701,3) < 0.22
  w = { originX = cw*WORM_SP + 10 + floor(hash3(cw,701,2) * (WORM_SP-20)),
        isEntrance = isEntrance, startD = isEntrance and 1 or (10 + floor(hash3(cw,701,4) * 50)),
        -- Worms used to have no end at all: every one descended from startD to the bedrock
        -- margin, so even at low frequency a single worm crossed the entire world vertically
        -- and the eye read the whole cave system as vertical shafts (confirmed by rendering a
        -- 700x600 slice and looking at it). Bounding each worm to a segment turns it into what
        -- it should be -- a connector between two horizontal gallery levels, not a bore hole.
        endD = (isEntrance and 1 or (10 + floor(hash3(cw,701,4) * 50)))
               + 90 + floor(hash3(cw,701,9) * 210),
        -- SIZING against the ~12px player: the old 3.0+2.2 gave a 6-10px bore, which the
        -- character physically cannot fit through -- a major reason caves read as "tubes bored
        -- through dirt" rather than passages you can be inside. 7.0+3.0 => 14-20px bore.
        baseR = 7.0 + hash3(cw,701,5) * 3.0, amp = WORM_SP*0.55 + hash3(cw,701,6) * WORM_SP*0.25,
        period = 55 + hash3(cw,701,7) * 70, phase = hash3(cw,701,8) * 1000 }
  wormCache[cw] = w; return w
end
local function wormOpenAt(wx, wy, d)
  local c = floor(wx / WORM_SP)
  for cc = c-1, c+1 do
    local w = wormAt(cc)
    if w and d >= w.startD - 1 and d <= w.endD then
      local dep = d - w.startD
      -- taper the bore shut at both ends so a segment closes off naturally instead of
      -- terminating in a flat disc of air
      local endFade = min(1, (w.endD - d) / 22)
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
        if w.isEntrance then rad = 4.0 + rad * min(1, dep / 18) end        -- mouth widening into the tunnel
        -- Hard floor raised for the ~12px player: the old 1.6/2.2 floors (3-4px bore) were
        -- impassable, so a tunnel could pinch to something the character could not follow.
        rad = max(rad, w.isEntrance and 6.5 or 7.0) * endFade
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
-- ================================================================ aquifers: a real water table
-- Distinct from the existing tree "aquifer" (R.treeAquiferAt), which is only tree-adjacent
-- moisture. This is water held INSIDE the rock: saturated strata bands confined by the rock
-- around them, so they sit inert until something opens them -- dig in and it floods.
--
-- Two ways the player meets it, both falling out of existing ordering rather than new code:
--   * in rock  -- worldGen runs caveAt() before rockAt(), so a saturated band's rock cells
--                 become water while any cave cutting it stays open; the water then flows into
--                 that cave under normal physics. That is the spring/seep, for free.
--   * in cave  -- a gallery crossing a saturated band is generated already flooded, so you
--                 follow a passage and hit real standing water. This is the "tunnel like
--                 aquifer" -- something you find while exploring, not just damp strata.
--
-- Three gates, each doing one job:
--   regional  -- some stretches of the world have a water table, others are dry
--   band      -- rides the SAME per-column wobble strataAt() uses, so a saturated layer lines
--                up with the visible rock banding instead of cutting across it
--   porosity  -- saturated rock is not a solid sheet of water; this is what makes it read as
--                wet rock, and bounds how much any single breach can release
local AQ_TOP, AQ_BOT = 80, 760
local function aquiferAt(wx, wy, d)
  if d < AQ_TOP or d > AQ_BOT then return false end
  if vnoise1(wx / 380, 1310) < 0.42 then return false end
  local wave = (vnoise1(wx / 85, 810) - 0.5) * 8   -- identical to strataAt's wobble, on purpose
  local band = floor((d - wave) / 15)
  -- Measured 2026-08-31: at 0.80/0.42 these gates put WATR at 14.05% of all sampled
  -- underground cells -- far too much standing water. Tightened to ~12% of bands and ~45%
  -- porosity, which is a water table you find rather than one you swim through.
  if hash3(band, 1311, 2) < 0.88 then return false end
  return vnoise(wx / 22, wy / 9, 1312) > 0.55
end
R.aquiferAt = aquiferAt   -- exposed so it can be sampled/measured without re-deriving the math

-- ================================================================ horizontal galleries
-- Measured problem (2026-08-31): in the dirt layer, where worms are the ONLY cave form
-- (cheeseOpenAt requires d>=80), mean horizontal open-run was 9.9px against 40.1px vertical --
-- H:V 0.246, every tunnel reading as a descending shaft. Global metrics hid this completely
-- (0.98 by adjacency, 1.17 by run length) because the big cheese caverns dominate them.
--
-- The cause is structural, not tuning: wormOpenAt parameterises its centreline by DEPTH
-- (cx varies with dep), so a worm necessarily descends while wandering only +/-amp sideways.
-- Extra wiggle cannot fix orientation. This is a second worm family parameterised by X --
-- the passage's DEPTH varies as you travel horizontally -- which makes horizontal galleries
-- the dominant form and leaves the depth-parameterised worms as vertical connectors.
--
-- SIZING: the player is ~12px tall, so every radius here is expressed against that. A passage
-- must clear ~12px vertically to be walkable at all; the old worm radii (3.0-5.2 => 6-10px
-- bore) were literally too small for the character to fit through, which is a large part of
-- why caves read as "tubes bored through dirt" instead of somewhere you can stand.
local GAL_SP = 150                      -- vertical spacing between gallery levels
local galCache = {}
local function galAt(cg)
  local g = galCache[cg]; if g ~= nil then return g end
  if hash3(cg, 741, 1) >= 0.50 then galCache[cg] = false; return false end
  g = { originD = cg*GAL_SP + 40 + floor(hash3(cg,741,2) * (GAL_SP-80)),
        baseR   = 9.0 + hash3(cg,741,3) * 5.0,     -- 18-28px bore = 1.5-2.3 player-heights
        amp     = 20 + hash3(cg,741,4) * 30,       -- how far the gallery rises/falls overall
        period  = 170 + hash3(cg,741,5) * 240,     -- long period: it RUNS, it does not zigzag
        phase   = hash3(cg,741,6) * 1000 }
  galCache[cg] = g; return g
end
-- returns: open(bool). Rock spikes (stalactites/stalagmites) are returned as NOT open, so they
-- appear as real rock hanging from the ceiling / rising from the floor of the passage.
local function galOpenAt(wx, wy, d)
  -- Galleries belong in ROCK, not in the dirt. Gallery level 0 sits at d 40-110, which is
  -- inside the topsoil/subsoil band, so galleries were carving large voids straight through it:
  -- measured 29.2% air in forest soil at d6-70, i.e. the ground was nearly a third holes, which
  -- is what reads as dirt "warping and disorienting" when you walk past it. cheeseOpenAt already
  -- guards itself the same way; this had no gate at all. Isolated single-pixel air was only
  -- 0.08%, so this was never salt-and-pepper noise -- it was big voids in the wrong layer.
  if d < 20 * SOIL_DEPTH_MUL then return false end
  local cg = floor(d / GAL_SP)
  for cc = cg-1, cg+1 do
    local g = galAt(cc)
    if g then
      -- regional presence: a gallery runs in stretches, not unbroken across the whole world
      local pres = vnoise1(wx / 430 + g.phase, 742)
      if pres > 0.38 then
        local cd = g.originD + g.amp * (vnoise1(wx / g.period + g.phase, 743) - 0.5) * 2
        local dy = d - cd
        if abs(dy) <= g.baseR + 26 then                     -- coarse reject before more taps
          local rad = g.baseR + (vnoise1(wx / 45 + g.phase, 744) - 0.5) * 3.0
          local room = vnoise1(wx / 140 + g.phase, 745)
          if room > 0.82 then rad = rad + (room - 0.82) * 90 end   -- occasional big chamber
          rad = rad * min(1, (pres - 0.38) / 0.10)          -- taper shut at a stretch's ends
          if abs(dy) <= rad then
            -- stalactites / stalagmites: rock spikes reaching in from ceiling and floor.
            -- Sampled at a short period so they read as a row of spikes, not one lump.
            local frac = abs(dy) / max(rad, 0.001)
            if frac > 0.42 then
              local sp = vnoise1(wx / 3.2 + g.phase * 3, 746)
              if sp > 0.58 and frac > 1 - ((sp - 0.58) / 0.42) * 0.70 then return false end
            end
            return true
          end
        end
      end
    end
  end
  return false
end

local function caveAt(wx, wy, surf, d, biome)
  if wy >= DEPTH - 40 then return nil end   -- never open in the bedrock margin
  -- Desert bedrock guarantee: the loose SAND cap (soilMaterial's sandD, 10-20px) needs a solid
  -- SANDROCK floor directly beneath it or the biome drains into whatever cave opens under it
  -- ("desert sand falls through the earth" -- desert is the only biome built from a falling
  -- powder). Measured before this guard, live seed 7: sweeping every desert column for d=1..24,
  -- 83 of 432 columns (19%) had a cave breach in that band, 724 of 10368 sampled cells (7%) were
  -- open where SANDROCK should be. Worms are the only cave form here with no depth floor tied to
  -- SOIL_DEPTH_MUL (galleries/cheese already gate at d>=80 -- see galOpenAt/cheeseOpenAt below):
  -- an entrance worm can start at d=1, a normal one at d=10, either right inside or just under
  -- the cap, at close to full bore width immediately (no start-side taper, only endFade near the
  -- far end). This is a flat depth guard rather than per-worm geometry, so the guarantee holds
  -- no matter what any single worm's radius/offset happens to be. 40 is double the cap's max
  -- depth (20) -- deliberate slack, not tuned to the exact number. Trade-off: desert loses cave
  -- mouths in this shallow band (entrance worms can no longer surface there); deeper caves are
  -- untouched, and ruins/mineshafts (desert's actual "underground" content) already live below.
  if d <= 40 and biomeWeight(wx, "desert") > 0 then return nil end
  local wopen = wormOpenAt(wx, wy, d)
  local gopen = (not wopen) and galOpenAt(wx, wy, d)
  local fopen = (not (wopen or gopen)) and waterfallAt(wx, wy, d)
  local copen = (not (wopen or gopen or fopen)) and cheeseOpenAt(wx, wy, d)
  if not (wopen or gopen or fopen or copen) then return nil end
  if wy >= DEPTH - 300 then return hellLavaAt(wx, wy) and "LAVA" or "" end
  if fopen then return "WATR" end
  if copen and d > 140 and lakeAt(wx, wy, d) then return "WATR" end
  -- A gallery crossing a saturated band is generated already flooded: you follow a passage and
  -- hit real standing water. This is what makes the aquifer discoverable while exploring
  -- rather than something you only ever meet by accidentally digging into it.
  if gopen and has("WATR") and aquiferAt(wx, wy, d) then return "WATR" end
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
  -- DEPTH-TIERED PALETTE (PhoenixFire808, verbatim: "I don't like the concrete as in the world" --
  -- knowledge/research-worldgen-design.md has the full layer table). CNCR (ROCK2) used to be a flat
  -- 32% of every non-desert stone pixel at EVERY depth, so it was speckled uniformly from the first
  -- shovelful of rock the player ever hits. His actual objection, read literally, is "concrete is
  -- everywhere" -- not "concrete should never exist". Real strata read as distinct depth bands
  -- (Terraria/Oxygen Not Included: shallow rock looks different from deep rock); this ramps CNCR's
  -- share with depth instead of holding it constant, so it reads as a genuine deep-rock identity
  -- (denser, harder-looking stone near the Uranium Shelf and below) rather than uniform noise near
  -- the surface where the player spends the first hour. Ramp range matches DEPTH_BANDS' own
  -- Iron Belt (60*SOIL_DEPTH_MUL) -> Uranium Shelf (420*SOIL_DEPTH_MUL) run, so the material change
  -- and the HUD's depth-band name change land at roughly the same place. Same single hash3 tap as
  -- before -- zero added noise evaluations, safe against the file's own 18.37ms/invocation cost note.
  local cncrShare = 0.08 + 0.32 * min(1, max(0, (d - 60 * SOIL_DEPTH_MUL) / (360 * SOIL_DEPTH_MUL)))
  local brckAccent = 0.08   -- thin sedimentary banding, everywhere (not just desert) -- a second real material, not a monoculture
  if pick < brckAccent and has("BRCK") then return "BRCK" end
  if pick < brckAccent + cncrShare then return ROCK2 end
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
  -- MERC: swamp/brine-biome pocket, sibling depth to GOLD. biomeWeight() is a cached
  -- table lookup (blendCache), so every non-swamp column bails on one cheap compare
  -- instead of spending vein()'s 1-2 noise taps -- see file header perf note and the
  -- 18.37ms/invocation budget this cascade already dominates.
  if HASMERC and d > 160 * dm and biomeWeight(wx, "swamp") > 0.15
     and vein(wx, wy, 1340, 78, 0.90, 15, 0.52) then return "MERC" end
  -- LITH: reactive metal, explodes on water contact per its own description. Window
  -- 200*dm..400*dm (800-1600 raw d) sits entirely below the aquifer band (AQ_TOP=80,
  -- AQ_BOT=760) and every lake's max floor (topD+h maxes ~788, see lakeInfo), and below
  -- the swampGasZoneAt ceiling (d<500) -- so a LITH vein can never generate adjacent to
  -- a WATR source. Upper bound stays above the hell-zone gate (wy>=DEPTH-300) so it
  -- doesn't compete with TTAN/BRMT/PTNM/DMND cells there.
  if HASLITH and d > 200 * dm and d < 400 * dm
     and vein(wx, wy, 1345, 82, 0.93, 15, 0.50) then return "LITH" end
  if d > 420 * dm and vein(wx, wy, 965, 90, 0.90, 17, 0.52) then return UORE end
  -- DEUT: heavy-water sibling to the uranium vein, same depth gate so the two share a
  -- biome rather than competing for cells (design chain 3). TYPE_LIQUID -- placed as a
  -- vein-shaped pocket, see the HASDEUT-block comment above for the safety reasoning.
  -- Calibrated live against measured URAN rate (0.73% of reachable deep-band pixels,
  -- scripts/_veins_density_probe.py): first-pass DEUT thresholds (92,0.91,16,0.52) measured
  -- 6/70 = 8.6% of URAN's own rate, far too rare for a "sibling ore sharing a biome" per the
  -- design doc. Loosened to land close to URAN's own rate instead of arbitrarily rarer.
  if HASDEUT and d > 420 * dm and vein(wx, wy, 1350, 89, 0.884, 16, 0.49) then return "DEUT" end
  -- ISZS: solid twin of ISOZ (SAFE, TYPE_SOLID/falldown=0), placed as the actual
  -- mineable vein per the design's own "solid form, safer to transport" framing.
  -- Deeper + sparser than DEUT (~1/3 density target) so it reads as a rarer fuel-cycle
  -- byproduct, not a second uranium-sized vein. Loosened alongside DEUT's recalibration
  -- (see comment above) so "~1/3 of DEUT" is measured against DEUT's corrected rate.
  if HASISZS and d > 440 * dm and vein(wx, wy, 1355, 94, 0.92, 14, 0.52) then return "ISZS" end
  local clayThresh = 0.88 - 0.10 * biomeWeight(wx, "swamp")
  if d < 260 * dm and vein(wx, wy, 968, 60, clayThresh, 16, 0.42) then return "CLST" end   -- clay/mud pocket: large, not freckled
  return nil
end
-- Desert bedrock. SAND is Falldown=1 / not TYPE_SOLID (verified live via elem.property, id 44),
-- so it is a powder with no structural integrity -- and the desert was the ONLY biome whose
-- entire soil column was made of it (forest/swamp use GOO, snow uses ICE, both Falldown=0).
-- That column is 108-172px deep after the topsoil deepening, i.e. 11-17 player-heights of loose
-- powder, and once the gallery/worm/aquifer work opened real voids beneath it the whole biome
-- drained into them ("all of the sand fell through the earth"). The caves did not cause this --
-- the desert was always unsupported, it simply had nowhere to fall to before.
-- BRCK is verified Falldown=0 + TYPE_SOLID and is ALREADY this project's desert rock (strataAt
-- uses it for the desert's sedimentary/fossil bands, matching its brick ruins), so it is reused
-- rather than allocating a new element. QRTZ would read better as sandstone but is a mineable
-- ore -- paving the whole desert subsoil with it would wreck the material economy.
local SANDROCK = has("BRCK") and "BRCK" or ROCK
local function soilMaterial(wx, wy, d, biome)
  if biome == "desert" then
    -- Real deserts are a shallow skin of loose sand over sandstone. Keeping the top layer
    -- genuinely loose is what makes dunes, pouring and digging behave like sand should; the
    -- solid beneath is what stops the biome draining into every cave under it.
    local sandD = 10 + floor(vnoise1(wx / 40, 837) * 10)   -- 10-20px, varied so it isn't a flat slab
    return d <= sandD and "SAND" or SANDROCK
  end
  if biome == "snow" then if d == 0 then return has("SNOW") and "SNOW" or "ICE" end; return "ICE" end
  if biome == "forest" or biome == "swamp" or not biome then
    if d == 0 then return GRASS end
    local surf = wy - d
    local rv = rootVeinShapeAt(wx, wy, surf, d)
    if rv == "hollow" then return "" end
    if rv == "wood" then return "WOOD" end
    -- Embedded rock flecks (PhoenixFire808: "I want better materials, I want ALL better
    -- materials" -- knowledge/research-worldgen-design.md). Topsoil/subsoil was a single flat
    -- GOO fill top to bottom -- a live census measured the world at 56.3% GOO, the single
    -- largest material share by far. Real dirt has embedded stones; one extra noise tap (same
    -- cost class as the vein() taps oreAt already spends per rock pixel, and it's charged only
    -- ONCE per soil pixel at generation time, not per tick) breaks up the monoculture with a
    -- real, already-verified-safe solid instead of inventing a new element. d>2 so the grass-
    -- adjacent skin (what the eye reads first) stays clean GOO, not speckled right at the surface.
    if d > 2 and vnoise(wx / 7, wy / 7, 1290) > 0.91 then
      return (hash3(wx, wy, 1291) < 0.6) and ROCK or (has("BRCK") and "BRCK" or ROCK)
    end
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
    if n < t then
      -- Border dither picks between two SOIL materials, not soil-vs-air. soilMaterial(other)
      -- can return "" (a tree's own root hollow, forest/swamp only) which has no meaning on a
      -- neighbouring column -- a root hollow only makes sense directly under its own tree. Near
      -- a desert border this was smearing a forest tree's hollow onto the desert side, punching
      -- a hole under the sand cap the same way the cave carver did. Keep the dither for real
      -- material swaps; never let it introduce air.
      local dm = soilMaterial(wx, wy, d, other)
      if dm ~= "" then mat = dm end
    end
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
    -- PTNM: permanent machine-upgrade catalyst (design chain 8) -- one unit installs once
    -- and is never consumed, so ~1/10th DMND's own hell-zone density is deliberate, not a
    -- placeholder. Calibrated live: first-pass thresholds (0.97,0.62) measured 46/132 = 35%
    -- of DMND's rate, far above the ~10% target; tightened to bring it down toward that
    -- target (see scripts/_veins_density_probe.py). SAFE: TYPE_SOLID/falldown=0, verified.
    if HASPTNM and vein(wx, wy, 1360, 100, 0.988, 18, 0.66) then return "PTNM" end
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
  -- After ore on purpose: an ore vein crossing a saturated band still reads as ore, so the
  -- water table never removes ore the tech tree depends on.
  if has("WATR") and aquiferAt(wx, wy, d) then return "WATR" end
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
-- BMTL scrap pocket (design chain 7): BMTL was previously combat-drop-only for
-- CONVEYOR/AIRLINEKIT/WINDKIT (a single point of RNG failure). ~35% of ruins, rolled
-- once per ruin (not per pixel) on the ruin's own x0, carry a small interior debris
-- pocket -- a second, minable route, alongside the existing combat drop rather than
-- replacing it. SAFE: TYPE_SOLID/falldown=0, verified via check_terrain_solid.py.
local function ruinScrapAt(rr, wx, d)
  if not HASBMTL then return nil end
  if hash3(rr.x0, 1070, 1) >= 0.35 then return nil end
  local cx, cd = (rr.x0 + rr.x1) * 0.5, (rr.d0 + rr.d1) * 0.5
  if inEllipse(wx, d, cx, cd, 2.6, 1.7) then return "BMTL" end
  return nil
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
      local scrap = ruinScrapAt(rr, wx, d); if scrap then return scrap end
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
  -- A worldgen door's CONTROL PAD, stamped by the grid itself. Without a real conductor cell
  -- beside it, machines.lua's updateDoors can never see power at m.pad and the door is inert
  -- forever -- a door object with nothing to spark it is not a door.
  control = pickEl("PSCN", "METL"),
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
      -- The "door" token is normalised to plain air ONCE, here. sQuery's inner loop runs for every
      -- generated pixel in the world; it must not learn a new token. Which cells are actually ALIVE
      -- is carried by def.objects instead (see the instantiation hook in sQuery below), so the grid
      -- stays a pure material map and a door costs the hot path exactly nothing.
      for k, v in pairs(def.legend) do if v == "door" then def.legend[k] = "air" end end
      SByCat[def.category] = SByCat[def.category] or {}
      table.insert(SByCat[def.category], def)
      SLoaded = SLoaded + 1
    end
  end
end
R.structuresLoaded = SLoaded   -- probe hook: how many of the 30 actually parsed
-- Widest authored structure per category, in grid cells. Used to keep each instance inside its
-- own grid cell so two structures can never overlap (see sQuery) -- this is the `min_spacing`
-- that was specified in the library but never implemented, and at 20x scale two overlapping
-- 300px buildings would be impossible to miss.
local SMAXW = {}
for cat, pool in pairs(SByCat) do
  local m = 1
  for _, def in ipairs(pool) do if (def.width or 1) > m then m = def.width end end
  SMAXW[cat] = m
end
-- Grid pitch and per-cell existence odds per category. Pitch >= the largest min_spacing in
-- that category; odds keep the world mostly natural instead of a theme park.
-- `sc` = world pixels per authored grid cell.
--
-- The library was harvested from community stamps whose native scale was never matched to this
-- game, and one grid cell mapped to one pixel. Against the REAL player box (4px wide x 10px
-- tall, from BOXL/BOXR/BOXT in rpg.lua) that made every building a prop:
--   surface_cabin_small  15x17px -> the whole house was 1.7 player-heights tall
--   surface_well          9x9px  -> under one player-height
--   deep_crystal_chamber 16x13px -> a "chamber" 1.3 player-heights tall
-- The cabin proves it was unusable rather than merely small: its interior is 4 grid rows, so a
-- 10px character did not fit INSIDE it, and its only wall gap is 2 cells against a 4px-wide
-- player. Unenterable at any point -- exactly the "ultra ultra small and unusable" report.
--
-- At sc=20 the cabin becomes 300x340px: a third of the ~612px canvas wide, 34 player-heights
-- tall, with an 80px interior and a 40x20px doorway. The scale-up is what makes the door and
-- the room usable -- no re-authoring needed, the proportions were always right, only the size
-- was wrong. Underground/deep sit at 12 because they carve into rock and 20x rooms would gut
-- the cave system; details at 6 so a crate reads as a crate rather than as furniture.
--
-- `sp` (grid pitch) MUST rise with `sc` or the world becomes wall-to-wall buildings: at 300px
-- wide against the old 240px pitch, surface structures would overlap each other continuously.
-- Pitch is set so a structure occupies roughly a fifth of its cell, which keeps them as
-- landmarks you travel to rather than scenery you walk through.
local SCAT = {
  surface     = { sp = 1400, prob = 0.55, sc = 20 },
  detail      = { sp = 120,  prob = 0.35, sc = 6 },
  underground = { sp = 900,  prob = 0.45, sc = 12 },
  deep        = { sp = 1200, prob = 0.40, sc = 12 },
}
-- Per-structure scale, not a flat category scale.
--
-- Uniform 20x correctly preserves the authored size RATIOS (a cabin should dwarf a signpost),
-- but a sparse grid has no detail budget to survive that magnification: verified by rendering,
-- a 3x8 signpost at 20x is a 60x160 featureless brown slab, because every authored cell becomes
-- a solid 20x20 block. The 15x17 cabin has 255 cells and survives -- roof, chimney and windows
-- all still read. So scale is driven by how much detail the grid actually contains: dense grids
-- take the full landmark scale, sparse ones stay props. the owner asked for houses and landmarks to
-- be bigger, not for crates and fence posts to become monoliths.
local function sScale(def, C)
  local cells = (def.width or 1) * (def.height or 1)
  -- DENSE grids (400+ cells: the re-authored multi-room buildings) must NOT also take the full
  -- landmark per-cell scale. Detail budget and world footprint are separate axes. The 30x22 cabin
  -- at sc=20 would be 600x440px on a 612x384 canvas -- you could never see it whole -- so the extra
  -- cells buy DETAIL (thinner walls, a real door, a hallway, a second storey) at a roughly constant
  -- landmark footprint: per-cell scale shrinks to hold the building near 460px wide. The floor of 8
  -- keeps a wall cell a visible band and a 2-cell doorway >= 16px, well past the 4x10px player box.
  -- Mirrored by sscale() in scripts/gen_structures.py, which validates door and interior sizes in
  -- WORLD PIXELS offline -- keep the two in sync.
  if cells >= 400 then return math.max(8, math.min(C.sc, floor(460 / (def.width or 1)))) end
  if cells >= 150 then return C.sc end                        -- campsite, ruined wall, forge ruin
  if cells >= 60  then return math.max(4, floor(C.sc * 0.6)) end  -- well, farm plot, bridge
  return math.max(3, floor(C.sc * 0.3))                       -- signpost, crate, fence post
end
-- Publish the library, stamped with the scale each def will really be placed at, so guide.lua can
-- report what ACTUALLY loaded instead of a hand-copied second list that drifts from this one.
R.structDefs = SByCat
for cat, pool in pairs(SByCat) do
  for _, def in ipairs(pool) do def._sc = sScale(def, SCAT[cat]) end
end
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
    -- UNITS: chosen.width is in authored GRID CELLS; surfaceAt takes PIXELS. Before scaling
    -- these were the same number, so the old check silently probed 15px away for what is now a
    -- 300px-wide building -- it would have approved a cabin sitting across a cliff.
    local esc = sScale(chosen, SCAT[cat])
    local w = (chosen.width or 1) * esc
    -- A proportional tolerance also stops making sense once buildings are landmark-sized:
    -- w*0.35 on a 300px footprint permits a 105px drop, which is most of a screen. Budget is
    -- now ~1.5 grid cells of ground movement regardless of footprint -- gentle slopes pass,
    -- genuine cliffs and cave mouths are rejected. Sampled across the footprint rather than at
    -- one far corner, since a wide building can straddle a dip its endpoints both miss.
    local tol = math.max(6, esc * 1.5)
    for _, f in ipairs({ 0.25, 0.5, 0.75, 1.0 }) do
      if math.abs(surfaceAt(wx0 + floor(w * f)) - refY) > tol then return false end
    end
  end
  -- Each structure JSON authors its own depth_band (e.g. underground_sealed_vault wants d>=200)
  -- but nothing ever read it -- rY is rolled ONCE per CELL before a structure is even chosen (see
  -- sQuery), so a cell that rolled a shallow depth could still hand a deep-only structure that
  -- shallow position anyway. underground's roll spans d=60-479, and several defs want a deeper
  -- floor (sealed_vault min=200, shrine min=150, water_cistern min=100, miners_camp min=80) -- so
  -- roughly a third of sealed_vault's rolls landed shallow enough to surface as an unmistakable
  -- solid all-metal box just under the dirt: this is the "giant iron blocks in the middle of
  -- stuff" report. Only enforce when depth_band is authored in this category's own convention
  -- (non-negative offset below surface, which is what the roll above actually produces) --
  -- "deep" category's depth_band values are all negative (a different, never-wired authoring
  -- pass), and gating on those would zero out every deep structure instead of fixing anything.
  local db = chosen.depth_band
  if db and db.min and db.min >= 0 then
    local d = refY - surfaceAt(wx0)
    if d < db.min or (db.max and d > db.max) then return false end
  end
  return { def = chosen, x0 = wx0, y0 = refY, sc = sScale(chosen, SCAT[cat]) }
end
local function sQuery(cat, wx, wy, refX, refY, biome)
  local C = SCAT[cat]; if not C then return nil end
  local cellIdx = floor(refX / C.sp)
  sCache[cat] = sCache[cat] or {}
  local cache = sCache[cat]
  for cc = cellIdx - 1, cellIdx do
    local inst = cache[cc]
    if inst == nil then
      -- STRUCTURE <-> STRUCTURE spacing. The offset used to span the whole cell, so an instance
      -- placed late in cell N could reach hundreds of pixels into cell N+1 and overlap the
      -- instance there. That was invisible at 1px-per-cell; at 20x it is two 300px buildings
      -- inside each other. Confining the offset so even the widest structure in the category
      -- still ends before the cell boundary makes overlap impossible by construction, which is
      -- the `min_spacing` the library always specified and never got.
      local slack = C.sp - (SMAXW[cat] or 1) * C.sc - 20
      if slack < 10 then slack = 10 end
      local cellX0 = cc * C.sp + 10 + floor(hash3(cc, 8802, 2) * slack)
      -- anchor row: surface/detail sit on the ground at their own column; underground/deep
      -- roll ONE depth origin per cell (mineshaftAt's idiom) instead of following the query
      -- row, which would smear the structure down every row it was asked about.
      local rY = refY
      if cat == "underground" then rY = surfaceAt(cellX0) + 60 + floor(hash3(cc, 8803, 4) * 420)
      elseif cat == "deep" then rY = surfaceAt(cellX0) + 520 + floor(hash3(cc, 8803, 5) * 600) end
      if cat == "surface" or cat == "detail" then rY = surfaceAt(cellX0) end
      inst = sRoll(cat, cc, cellX0, biome, rY)
      cache[cc] = inst
      -- ONE-SHOT INSTANTIATION. Worldgen structures had no runtime identity: sQuery is a pure
      -- per-pixel material query and R.machines records were only ever created by the player's
      -- place path, so an authored door cell was a hole in a wall and nothing more. This is the
      -- exact once-per-accepted-placement site -- `cache[cc]` is nil only the first time this cell
      -- is asked about, and sQuery's inner loop (below) runs for every generated pixel in the world
      -- and must stay untouched.
      --
      -- RISK, accepted deliberately: this can fire BEFORE the structure's own terrain has been
      -- stamped, so a record briefly exists over an unfilled core pixel. It survives only because
      -- machines.lua's reaper (updateMachineCores) skips cores that are off-screen, and worldgen by
      -- definition runs ahead of the camera. If that off-screen skip is ever removed, this needs to
      -- be deferred to the first frame the structure is on screen.
      if inst and R.spawnStructMachine then
        local def = inst.def
        -- isc from inst.sc, NOT SCAT[cat].sc: sScale is per-structure, and the category scale here
        -- would place machines at plausible-but-wrong coordinates -- the hardest kind of bug to see.
        local isc = inst.sc
        for _, o in ipairs(def.objects or {}) do
          -- Inverts sQuery's own transform (gx = floor((wx - x0)/isc) + anchor.x). The half-cell
          -- offset matters: the reaper tests exactly the core pixel, so it must land mid-cell.
          local function w2x(gx) return inst.x0 + (gx - def.anchor.x) * isc + floor(isc / 2) end
          local function w2y(gy) return inst.y0 + (gy - def.anchor.y) * isc + floor(isc / 2) end
          local wx, wy = w2x(o.gx), w2y(o.gy)
          -- The door slab has to fill the authored opening, not machines.lua's default 2x6 stub --
          -- these openings are a whole grid cell wide. ponytail: a per-pixel block list, which is
          -- what machines.lua's door already speaks; store a rect instead if save size ever bites.
          local blocks, x0c, y0c = {}, w2x(o.gx) - floor(isc / 2), w2y(o.gy - (o.h or 1) + 1) - floor(isc / 2)
          for bx = x0c, x0c + (o.w or 1) * isc - 1 do
            for by = y0c, y0c + (o.h or 1) * isc - 1 do blocks[#blocks + 1] = { x = bx, y = by } end
          end
          R.spawnStructMachine(o.kind, wx, wy, cat .. ":" .. cc .. ":" .. o.gx .. "," .. o.gy, {
            core = { x = w2x(o.core_gx), y = w2y(o.core_gy) },
            pad = o.pad_gx and { x = w2x(o.pad_gx), y = w2y(o.pad_gy) } or nil,
            blocks = blocks,
          })
        end
      end
    end
    if inst then
      local def = inst.def
      -- One authored grid cell now covers C.sc world pixels in each axis (see SCAT). floor()
      -- on the offset keeps the anchor cell exactly at (inst.x0, inst.y0) and works for
      -- negative offsets too, so the structure grows symmetrically around its anchor.
      local isc = inst.sc or C.sc
      local gx = floor((wx - inst.x0) / isc) + def.anchor.x
      local gy = floor((wy - inst.y0) / isc) + def.anchor.y
      if gx >= 0 and gx < def.width and gy >= 0 and gy < def.height then
        local row = def.grid[gy + 1]
        if row then
          local ch = row:sub(gx + 1, gx + 1)
          local tok = def.legend[ch]
          if tok == "air" then return "" end
          if tok and tok ~= "keep" then
            -- Optional wall thinning (gen_structures.py's `thin=` / classify_orientation()).
            -- Community wall thickness is a median 2px contiguous run vs an authored cell being
            -- solid isc px (research-community-aesthetics-measured.md); def.thin[ch] marks a
            -- token as thin-eligible with an axis and a px budget. Only render material within
            -- `px` pixels of the cell's OUTWARD edge (the half of the cell farther from the
            -- structure's own center on that axis) and let the rest fall through to "keep" (nil)
            -- -- for a surface structure that's just open air, i.e. a thin shell with a hollow,
            -- slightly bigger interior behind it, not a hole in the wall's own run (every pixel
            -- along the wall's length still gets its thin sliver, so the barrier stays continuous).
            local thin = def.thin and def.thin[ch]
            if thin then
              local cellX0 = inst.x0 + (gx - def.anchor.x) * isc
              local cellY0 = inst.y0 + (gy - def.anchor.y) * isc
              local edge
              if thin.axis == "x" then
                local off = wx - cellX0
                edge = (gx < floor(def.width / 2)) and off or (isc - 1 - off)
              else
                local off = wy - cellY0
                edge = (gy < floor(def.height / 2)) and off or (isc - 1 - off)
              end
              if edge >= thin.px then return nil end
            end
            return SMATERIAL[tok]
          end
        end
      end
    end
  end
  return nil
end
-- Is (wx,wy) inside a placed structure's footprint, including cells its grid leaves as "keep"?
--
-- Trees and structures are independent late passes with no arbitration, which is why canopies
-- grew through walls. worldGen consults structures BEFORE aboveGround, so a structure's own
-- solid cells already win -- but every "keep" cell and the margin around the building were
-- still fair game for vegetation, and a 20x building surrounded by trees is mostly margin.
-- A real building stands on cleared ground, so structures beat vegetation: this reports the
-- whole bounding box (plus a margin for canopy overhang) and worldGen returns air there.
-- Reads the same sCache sQuery just populated for these cells, so it costs no extra rolls.
local function sFootprintAt(cat, wx, wy, margin)
  local C = SCAT[cat]; if not C then return false end
  local cache = sCache[cat]; if not cache then return false end
  local cellIdx = floor(wx / C.sp)
  for cc = cellIdx - 1, cellIdx do
    local inst = cache[cc]
    if inst then
      local def = inst.def
      local isc = inst.sc or C.sc
      local x0 = inst.x0 - def.anchor.x * isc - margin
      local y0 = inst.y0 - def.anchor.y * isc - margin
      if wx >= x0 and wx < x0 + def.width * isc + margin * 2
         and wy >= y0 and wy < y0 + def.height * isc + margin * 2 then return true end
    end
  end
  return false
end
-- Above-ground vegetation suppression. Margin is generous on surface buildings because a tree
-- CANOPY is 48-80px wide and its trunk can sit well outside the wall while its leaves still
-- push through the roof.
function R.structClearsVegAt(wx, wy)
  return sFootprintAt("surface", wx, wy, 26) or sFootprintAt("detail", wx, wy, 4)
end
local function libStructHere(wx, wy, surf, d, biome)
  if SLoaded == 0 then return nil end
  -- Cross-category arbitration. Each category has its own cache and its own pitch and, until now,
  -- no knowledge of the others -- so a "detail" prop at pitch 120 routinely landed INSIDE a 300px
  -- surface cabin and drew through wherever the cabin's grid said "keep". Structure-vs-structure
  -- WITHIN a category is already impossible by construction (one instance per cell), and
  -- structure-vs-tree is handled by R.structClearsVegAt -- this closes the last overlap axis.
  -- Order matters and is free: sQuery("surface") populates sCache.surface for these cells, so the
  -- sFootprintAt call below reads a cache that is already warm and costs no extra rolls.
  local s = sQuery("surface", wx, wy, wx, surf, biome); if s ~= nil then return s end
  if not sFootprintAt("surface", wx, wy, 8) then
    local t = sQuery("detail", wx, wy, wx, surf, biome); if t ~= nil then return t end
  end
  if d and d > 40 then
    local cat = (d > 500) and "deep" or "underground"
    -- The deep/underground pair is only queried one-at-a-time by depth, but a deep structure placed
    -- at d>500 can extend UP past the boundary into rows where "underground" is what gets queried.
    -- This is best-effort: sFootprintAt returns false when the other cache was never warmed, which
    -- degrades to the previous behaviour rather than misplacing anything.
    local other = (d > 500) and "underground" or "deep"
    if not sFootprintAt(other, wx, wy, 0) then
      local u = sQuery(cat, wx, wy, wx, wy, biome); if u ~= nil then return u end
    end
  end
  return nil
end
local function structureAt(wx, wy, surf, d, biome)
  if wy >= DEPTH - 60 then return nil end
  local r = ruinHere(wx, wy, d); if r ~= nil then return r end
  local m = mineshaftHere(wx, wy, d); if m ~= nil then return m end
  return libStructHere(wx, wy, surf, d, biome)
end

-- ================================================================ structure DECO tint (R.hooks.draw)
-- Community builds spend a median 58.6% of their particle budget on a DECO (dcolour) tint layer
-- (knowledge/research-community-aesthetics-measured.md, n=12 saves); before this we used it 0%
-- of the time -- every structure was raw element color. This applies each structure's optional
-- `deco` field (grid char -> {r,g,b,a}, from gen_structures.py's `deco=`) via sim.decoBox, once
-- per placed instance, the first time its whole footprint is on screen.
--
-- PHYSICS SAFETY, verified by reading the engine, not assumed: Simulation::ApplyDecoration
-- (src/simulation/Editing.cpp) reads parts[ID(rp)].dcolour, writes only that field, and returns
-- immediately if pmap/photons is empty at that pixel -- it never creates a particle and never
-- touches type/temp/vx/vy/tmp/ctype/life. decoBox cannot alter Falldown, TYPE_SOLID or
-- temperature, and cannot conjure a particle where structure generation hasn't stamped one yet
-- (an empty cell is a silent no-op, which is why this retries every frame until the footprint's
-- own material has actually landed, rather than firing once at roll time before it exists).
--
-- EVENT CONTEXT, also verified by reading the engine: decoBox/decoLine/decoBrush all call only
-- lsi->AssertToolEvent(), which passes if eventTraits has eventTraitInterface OR eventTraitTool
-- (src/lua/LuaScriptInterface.h). R.hooks.draw runs under AfterSimDrawEvent and R.hooks.tick under
-- TickEvent (src/gui/game/GameControllerEvents.h); both carry eventTraitInterface. So this is
-- callable from an ordinary draw hook with no mouse/tool event needed -- confirmed by it running
-- without the "restricted to tool events" error this pass produces if that weren't true.
local function applyStructDeco(cat, camx, camy, W, H)
  local C = SCAT[cat]; local cache = sCache[cat]; if not C or not cache then return end
  local cellIdx = floor(camx / C.sp)
  for cc = cellIdx - 1, cellIdx + 1 do
    local inst = cache[cc]
    if inst and inst.decoDone == nil then
      local def = inst.def
      if not def.deco then
        inst.decoDone = true   -- no deco field authored for this structure: nothing to ever do
      else
        local isc = inst.sc or C.sc
        local x0 = inst.x0 - def.anchor.x * isc
        local y0 = inst.y0 - def.anchor.y * isc
        local x1 = x0 + def.width * isc
        local y1 = y0 + def.height * isc
        if x1 >= camx and x0 <= camx + W and y1 >= camy and y0 <= camy + H then
          for ch, col in pairs(def.deco) do
            for gy = 0, def.height - 1 do
              local row = def.grid[gy + 1]
              local sy0 = y0 + gy * isc - camy
              local sy1 = sy0 + isc - 1
              if sy1 >= 0 and sy0 < H then
                local searchFrom = 1
                while true do
                  local s = row:find(ch, searchFrom, true)
                  if not s then break end
                  local sx0 = x0 + (s - 1) * isc - camx
                  local sx1 = sx0 + isc - 1
                  if sx1 >= 0 and sx0 < W then
                    sim.decoBox(max(sx0, 0), max(sy0, 0), min(sx1, W - 1), min(sy1, H - 1),
                                 col.r, col.g, col.b, col.a)
                  end
                  searchFrom = s + 1
                end
              end
            end
          end
          -- Only latch "done" once the WHOLE footprint has been on screen at least once -- a
          -- structure this size (<=460px, the dense-tier cap) usually fits inside a 612x384 view,
          -- but if the player enters from one side before the far side/windows were ever on
          -- screen, latching early would leave those cells permanently untinted ("a bad global
          -- tint looks worse than none" applies just as much to a PARTIAL one). Costs a few dozen
          -- decoBox calls per frame only while this specific condition holds for a nearby
          -- structure, which self-limits to the few seconds of approach before it fully clears.
          if x0 >= camx and y0 >= camy and x1 <= camx + W and y1 <= camy + H then
            inst.decoDone = true
          end
        end
      end
    end
  end
end

-- ================================================================ underground colour bands (dcolour, zero element cost)
-- PhoenixFire808: "I don't like the concrete as in the world -- I want better materials." Root cause, verified live
-- against this exact build (D:/The-Powder-Toy/build/powder.exe, same binary his session and this check both loaded --
-- see knowledge/research-worldgen-design.md): the custom-element table is 40/40 slots, 0 free, and BSLT/CNCR lost the
-- slot competition -- has("BSLT") and has("CNCR") both return false RIGHT NOW, so ROCK and ROCK2 have silently
-- collapsed onto the SAME element (BRCK). His entire underground is one physical material; that reads as
-- "concrete"/"monochrome" regardless of what strataAt() intends. Restoring a second rock element is blocked by
-- that hard slot cap -- not something this file can fix. DECO (dcolour) costs ZERO element slots and never touches
-- physics (verified: src/simulation/Editing.cpp::ApplyDecoration writes only the colour channel), so it is the one
-- lever available to make the SAME material read as several different depth-appropriate rocks -- one material,
-- many apparent strata, matching what real games (Terraria/ONI) do with depth-banded rock colour. Community builds
-- lean on this hard already (median 58.6% of particles carry a dcolour tint vs. our measured 0% before this).
--
-- COST DISCIPLINE (world.lua is the single most expensive plugin at 18.37ms/invocation -- see this file's own
-- header and knowledge/PERF-*): this does NOT run the ore/strata noise cascade a second time and does NOT scan
-- live particles to tell rock from ore -- both would be real, measured regressions. It works purely from depth
-- thresholds (the same DEPTH_BANDS-shaped numbers the HUD announcer already uses) and a per-(column,band) cache
-- that tracks the world-y RANGE already decoBox'd, so a column already fully covered for the bands currently in
-- view costs a handful of table lookups and zero decoBox calls on every subsequent frame -- only NEWLY exposed
-- territory (scrolling to a new column, or descending into more of an already-seen band) issues a fresh call, and
-- a hard per-frame budget caps how many of those a single frame may issue regardless. Ore veins inside a tinted
-- band do get the same low-alpha tint (decoBox recolours whatever particle is there, it cannot distinguish ore
-- from plain rock without re-running the placement noise) -- alpha is kept low (40-60/255) specifically so ore's
-- own bright colour still reads through, the same trade every community save with deco makes.
local STRATA_TINT_BANDS = {
  { dmin = 100,               r = 150, g = 122, b = 92,  a = 40 },  -- Coal Seams: warm sedimentary tan
  { dmin = 300,               r = 118, g = 122, b = 128, a = 42 },  -- Iron Belt/Copper Vein: neutral cool gray
  { dmin = 700,               r = 78,  g = 96,  b = 118, a = 48 },  -- Gold Reef/Flooded Caverns: damp blue-gray
  { dmin = 1200,              r = 150, g = 150, b = 70,  a = 55 },  -- Uranium Shelf: sickly hazard yellow-green
  { dmin = DEPTH - 300,       r = 150, g = 70,  b = 55,  a = 60 },  -- The Deep: hot dark red
}
-- "columnStep,bandIdx" -> {lo=worldY, hi=worldY} range already decoBox'd for that band in that column strip
local strataTintCache = {}
local STRATA_TINT_STEP = 4     -- px per tint strip (matches this file's other ground-cover granularity, e.g. DSP)
local STRATA_TINT_BUDGET = 24  -- hard per-frame cap on NEW decoBox calls; already-covered ground costs table lookups only
local function applyStrataDeco(camx, camy, W, H)
  local calls = 0
  local c0 = floor(camx / STRATA_TINT_STEP)
  local c1 = floor((camx + W) / STRATA_TINT_STEP)
  for cc = c0, c1 do
    if calls >= STRATA_TINT_BUDGET then break end
    local wx = cc * STRATA_TINT_STEP
    local surf = surfaceAt(wx)
    local sx0 = max(wx - camx, 0)
    local sx1 = min(wx - camx + STRATA_TINT_STEP - 1, W - 1)
    if sx1 >= sx0 then
      for bi = 1, #STRATA_TINT_BANDS do
        if calls >= STRATA_TINT_BUDGET then break end
        local band = STRATA_TINT_BANDS[bi]
        local nextDmin = STRATA_TINT_BANDS[bi + 1] and STRATA_TINT_BANDS[bi + 1].dmin or 1e9
        local wyTop, wyBot = surf + band.dmin, surf + nextDmin - 1
        local vy0, vy1 = max(wyTop, camy), min(wyBot, camy + H - 1)
        if vy1 >= vy0 then
          local key = cc * 16 + bi
          local rng = strataTintCache[key]
          if not rng then
            sim.decoBox(sx0, vy0 - camy, sx1, vy1 - camy, band.r, band.g, band.b, band.a)
            strataTintCache[key] = { lo = vy0, hi = vy1 }
            calls = calls + 1
          else
            if vy0 < rng.lo and calls < STRATA_TINT_BUDGET then
              sim.decoBox(sx0, vy0 - camy, sx1, rng.lo - 1 - camy, band.r, band.g, band.b, band.a)
              rng.lo = vy0; calls = calls + 1
            end
            if vy1 > rng.hi and calls < STRATA_TINT_BUDGET then
              sim.decoBox(sx0, rng.hi + 1 - camy, sx1, vy1 - camy, band.r, band.g, band.b, band.a)
              rng.hi = vy1; calls = calls + 1
            end
          end
        end
      end
    end
  end
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
  applyStrataDeco(camx, camy, W, H)
  drawTreeAccents(camx, camy, W, H, frame, night)
  applyStructDeco("surface", camx, camy, W, H)

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
-- Flat test world: R.flatTestWorld=true (set before "Create World", like R.oreRarityMul/
-- R.treeSpacingMul already are), so machines/survival/UI can be exercised with no hills, caves
-- or biome noise in the way. Ground fill is ROCK (BSLT/BRCK) -- already verified Falldown=0 +
-- TYPE_SOLID elsewhere in this file (see SANDROCK/ROCK) -- never STNE/SAND, the two elements
-- that already proved unsafe as terrain (ADR-003). Bypasses the whole normal pipeline rather
-- than adding a flat-mode branch to every biome/cave/structure function.
local FLAT_SURFACE_Y = 200
local function flatWorldGen(wx, wy)
  if wy >= DEPTH then return "DMND" end
  if wy < FLAT_SURFACE_Y then return "" end
  return ROCK
end
local function worldGen(wx, wy)
  if R.flatTestWorld then return flatWorldGen(wx, wy) end
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
    -- Cleared ground: inside a building's footprint (and its canopy margin) nothing grows.
    -- Must come AFTER libStructHere so the structure's own cells still draw, and BEFORE
    -- aboveGround so no trunk or canopy can occupy the building's volume. This is the explicit
    -- arbitration the two passes never had -- structures win over vegetation, because that is
    -- what clearing a site to build means.
    if R.structClearsVegAt(wx, wy) then return "" end
    return aboveGround(wx, wy, surf, biome)
  end
  local d = wy - surf
  local st = structureAt(wx, wy, surf, d, biome); if st ~= nil then return st end
  local cave = caveAt(wx, wy, surf, d, biome); if cave ~= nil then return cave end
  return rockAt(wx, wy, surf, d, biome)
end
hook(R.hooks.gen, worldGen)
hook(R.hooks.draw, worldDraw)

-- Clear every per-column cache when a new world is generated.
--
-- This file had NO newworld hook at all, while rpg.lua's regen clears only its own surfCache
-- and treeCache. So on every "Create World" after the first, the terrain was filled from NEW
-- surface heights while these eleven caches still held records computed against the OLD seed.
-- vegAt stores each tree's ground level in its cached record (`s = surfaceAt(x)`), so trees kept
-- the previous world's surface height and ended up buried in the new ground -- "some of the
-- trees are spawning into the ground", bare trunks with no canopy sitting below the grass line.
-- blendCache going stale is the same class of fault for biome blending, which is what makes
-- soil dithering disagree with the actual biome layout.
--
-- This is a latent bug, not a new one: it has been wrong since these caches were introduced.
-- The rolling-hills octave only made it VISIBLE, by moving the surface far enough between seeds
-- that a stale tree base is now tens of pixels off instead of a few.
--
-- Every cache here is a pure function of (wx, R.seed), so clearing on regen is always safe --
-- they will simply repopulate against the new seed on first access.
hook(R.hooks.newworld, function()
  blendCache, vegCache, rootColCache, decoCache = {}, {}, {}, {}
  wormCache, fallCache, lakeCache, galCache = {}, {}, {}, {}
  mshaftCache, ruinCache, sCache = {}, {}, {}
  strataTintCache = {}
end)
