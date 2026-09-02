-- Icon system. PhoenixFire808, verbatim: "We need actual ICONS for everything, not just the
-- material colours. Everything has to look super good."
--
-- HARD ENGINE CONSTRAINT (verified in src/lua/LuaGraphics.cpp, 2026-09-01): there is no image,
-- texture or sprite loading -- the entire drawing surface is textSize/drawText/drawPixel/drawLine/
-- drawRect/fillRect/drawCircle/fillCircle/getColors/getHexColor/setClipRect. Every icon here is a
-- list of primitive draw calls, compiled once and cached, never a loaded asset.
--
-- OWNERSHIP: does not edit rpg.lua or any other rpg_plugins/*.lua file. It owns exactly the
-- R.icon.* namespace. IN R.PLUGINS since 2026-09-01 (second entry, right after "telemetry", so
-- anything loaded after it can use R.icon.* immediately) -- corrected 2026-09-02, this comment had
-- drifted stale ("NOT YET in R.PLUGINS") for a full day after the wiring actually landed; verified
-- live against rpg.lua's own R.PLUGINS = {...} literal, not assumed from an old comment.
--
-- ================================================================ THE FORMAT
-- An icon is a GRID x GRID grid (GRID=16) of characters, one per cell, plus a palette mapping
-- each character to an {r,g,b[,a]} colour. '.' is always transparent, reserved, needs no palette
-- entry. This is the format R.icon.define(id, {grid=..., pal=...}) takes -- plain Lua, one line
-- per row, meant to be pleasant to hand-author:
--
--   R.icon.define("example:dot", {
--     grid = {
--       "................", "................", "................", "................",
--       "................", "................", "......RR........", "......RR........",
--       "................", "................", "................", "................",
--       "................", "................", "................", "................",
--     },
--     pal = { R = {230,60,60} },
--   })
--
-- The 64 hand-authored icons below (tools/stations/materials/foraged food/first weapons/early
-- machines -- the highest-traffic things, count verified 2026-09-02 by counting ICON.defineCanvas
-- calls directly, not carried over from an earlier draft) are instead built with the small
-- numeric-coordinate helpers further down (lineC/rectc/thickLine on a 16x16 canvas) rather than
-- typed as literal grids: several of them share one silhouette across
-- tiers (5 picks, 3 swords) recoloured per tier, which a coordinate function expresses as one call
-- per tier instead of 16 hand-typed rows apiece, and is far less error-prone to get exactly right
-- without a screenshot loop. Both paths compile to the exact same internal representation
-- (compileCanvas), so R.icon.draw() cannot tell which authoring path an icon came from -- pick
-- whichever is more pleasant for the next 400 icons.
--
-- ================================================================ PERFORMANCE
-- Every icon compiles ONCE (compileCanvas: horizontal run-length per row, then a vertical merge of
-- identical adjacent spans into one taller rect) into a list of {x,y,w,h,r,g,b,a} rectangles in
-- GRID-unit space. R.icon.draw(id,x,y,size) then looks up a SEPARATE cache keyed "id@size" holding
-- that same list pre-scaled to pixel space (integer, rounded) -- so a draw call at steady state is
-- just N graphics.fillRect() calls with an add, no scaling math, no table walk of the raw grid, no
-- per-pixel loop, ever. R.icon.warm(ids, sizes) forces this pre-scaling to happen at load time
-- instead of on the first frame something is drawn. R.icon.benchmark() (called once by selfTest())
-- measures the real per-icon and per-10-icon (hotbar-sized) cost with os.clock() -- see the hub
-- entry for this pass for the actual measured numbers, not a guess.
--
-- ================================================================ THE PROCEDURAL FALLBACK
-- R.icon.resolve(code) is a TOTAL function -- it always returns a drawable icon id, never nil, and
-- never a flat single-colour square:
--   1. a hand-authored mapping (R.icon.ELEMENT_ICON[code]) if one exists,
--   2. else, if code resolves to a real element (R.eid), a procedural icon built from its actual
--      state of matter (solid/powder/liquid/gas/energy, via the same Properties-bit classification
--      guide.lua's own material page already uses), its REAL colour (R.colourOf, already reads
--      elem.property(id,"Colour")), and a texture seeded deterministically from a hash of the
--      element's own name -- so re-rolling never changes an icon between frames, and two elements
--      with the same grey base colour still look different from each other. Ore-named elements
--      (name matches the whole word "ore", e.g. "Iron ore") get bright speckle; a small hardcoded
--      metal set gets a diagonal shine; liquids get a meniscus; gases get sparse scattered
--      dots inside a dotted container hint; powders get an irregular granular mound.
--   3. else (an arbitrary non-element id, e.g. a machine kit or accessory name with no backing
--      particle) a colour hashed from the id string itself, drawn as the same solid-chunk
--      silhouette with speckle -- distinctive and never a plain square, even for something this
--      file has never heard of.
--
-- ================================================================ GRAMMAR
-- Every shape shares: a darker outline one shade in from the silhouette edge, a light source from
-- the top-left (a highlight streak/cluster on that side, never elsewhere), and a restrained
-- 3-4-colour palette per icon (base/outline/highlight/[accent]) -- so a wall of icons reads as one
-- artist's language instead of 400 unrelated swatches.

local R = PBX.state.rpg
local TAG = "icons"
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

local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min
local band, bxor, rshift = bit.band, bit.bxor, bit.rshift

-- Fresh tables every load (rebuild is cheap, correctness > preserving stale compiled geometry
-- across a hot-reload edit) -- only the debug-sheet toggle survives, same "preserve state, rebuild
-- functions" idiom every other plugin here uses.
local prevDebugSheet = (R.icon and R.icon.debugSheet) or false
R.icon = {}
local ICON = R.icon
ICON.debugSheet = prevDebugSheet
ICON.GRID = 16
ICON.SIZE_SMALL = 16
ICON.SIZE_LARGE = 48

local GRID = ICON.GRID
ICON._defs = {}
ICON._compiledCache = {}
ICON._sizeCache = {}
local defs, compiledCache, sizeCache = ICON._defs, ICON._compiledCache, ICON._sizeCache

-- ================================================================ colour helpers
local function clamp255(v) if v < 0 then return 0 elseif v > 255 then return 255 else return floor(v + 0.5) end end
local function darken(c, f) return { clamp255(c[1] * (1 - f)), clamp255(c[2] * (1 - f)), clamp255(c[3] * (1 - f)) } end
local function lighten(c, f) return { clamp255(c[1] + (255 - c[1]) * f), clamp255(c[2] + (255 - c[2]) * f), clamp255(c[3] + (255 - c[3]) * f) } end

-- ================================================================ deterministic hash/noise (no math.random -- same icon every reload/frame)
local function strHash(s)
  local h = 2166136261
  for i = 1, #s do
    h = bxor(h, s:byte(i))
    h = (h * 16777619) % 4294967296
  end
  return h
end
local function cellNoise(seed, x, y)
  local h = (seed * 374761393 + x * 668265263 + y * 2654435761 + 1) % 4294967296
  h = bxor(h, rshift(h, 13))
  h = (h * 1274126177) % 4294967296
  return h % 100
end

-- ================================================================ canvas primitives (0-indexed, GRIDxGRID)
-- Every colour landing in a canvas cell is normalised to a 4-tuple HERE, the one place all of
-- rectc/lineC/thickLine funnel through -- darken()/lighten() (and plenty of hand-authored literals
-- below) return/write 3-element {r,g,b} tables with no alpha. Without this, a cell's baked alpha
-- (compileCanvas's `a = o.c[4]`) is nil, which drew fine by accident when nil reached
-- graphics.fillRect() directly (the engine defaults a missing alpha arg to opaque) but throws
-- "attempt to perform arithmetic on a nil value" the moment ICON.draw's alpha-dimming path tries
-- to scale it -- caught live in the lab instance testing ui.lua's own `R.icon.draw(code,x,y,size,
-- alpha)` contract with alpha=128.
local function newCanvas() local c = {}; for y = 0, GRID - 1 do c[y] = {} end; return c end
local function setc(c, x, y, col)
  if x < 0 or y < 0 or x >= GRID or y >= GRID then return end
  c[y][x] = col and (col[4] and col or { col[1], col[2], col[3], 255 }) or nil
end
local function getc(c, x, y) if x < 0 or y < 0 or x >= GRID or y >= GRID then return nil end; return c[y][x] end
local function rectc(c, x0, y0, x1, y1, col) for y = y0, y1 do for x = x0, x1 do setc(c, x, y, col) end end end
local function clearc(c, x, y) setc(c, x, y, nil) end

local function lineC(c, x0, y0, x1, y1, col)
  x0, y0, x1, y1 = floor(x0), floor(y0), floor(x1), floor(y1)
  local dx, dy = math.abs(x1 - x0), math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx - dy
  while true do
    setc(c, x0, y0, col)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 > -dy then err = err - dy; x0 = x0 + sx end
    if e2 < dx then err = err + dx; y0 = y0 + sy end
  end
end
-- Cheap thickness approximation (good enough at 16x16): offset duplicate strokes, not a real polygon.
local function thickLine(c, x0, y0, x1, y1, col, thickness)
  lineC(c, x0, y0, x1, y1, col)
  if thickness >= 2 then lineC(c, x0 + 1, y0, x1 + 1, y1, col) end
  if thickness >= 3 then lineC(c, x0, y0 + 1, x1, y1 + 1, col) end
  if thickness >= 4 then lineC(c, x0 + 1, y0 + 1, x1 + 1, y1 + 1, col) end
end

local function addSpeckle(c, seed, col, count)
  count = count or 6
  local n = 0
  for y = 3, 13 do
    for x = 2, 13 do
      if n < count and getc(c, x, y) and cellNoise(seed, x, y) < 6 then setc(c, x, y, col); n = n + 1 end
    end
  end
end
local function addMetalShine(c, base)
  local hi = lighten(base, 0.65)
  for i = 0, 3 do local x, y = 5 + i, 5 + i; if getc(c, x, y) then setc(c, x, y, hi) end end
end

-- ================================================================ shared silhouettes (grammar: outline + top-left highlight)
-- `seed`, when given, adds a few darkened grain flecks (a subtler, neutral-toned cousin of
-- addSpeckle's bright ore treatment) -- raises the long-tail procedural fallback (@iconart pass,
-- 2026-09-02: PhoenixFire808's bar is "everything has to look super good", and a flat bevel with
-- no texture at all was the honest gap in an otherwise-total function) without touching any of the
-- 64 hand-authored icons above, which never pass a seed and render byte-identical to before.
local function drawChunk(c, base, seed)
  local out, hi = darken(base, 0.55), lighten(base, 0.45)
  rectc(c, 2, 3, 13, 13, out)
  rectc(c, 3, 4, 12, 12, base)
  for _, p in ipairs({ { 2, 3 }, { 13, 3 }, { 2, 13 }, { 13, 13 } }) do clearc(c, p[1], p[2]) end
  for _, p in ipairs({ { 3, 4 }, { 12, 4 }, { 3, 12 }, { 12, 12 } }) do setc(c, p[1], p[2], out) end
  for i = 0, 4 do setc(c, 4 + i, 5, hi) end
  setc(c, 4, 6, hi)
  if seed then
    local grain = darken(base, 0.2)
    local n = 0
    for y = 5, 11 do
      for x = 4, 11 do
        if n < 5 and getc(c, x, y) and cellNoise(seed, x, y) < 5 then setc(c, x, y, grain); n = n + 1 end
      end
    end
  end
end

-- Filled ellipse via two passes over the same per-row half-width (fill, then darken the two edge
-- columns) -- exactly the technique the hand-authored food:generic icon below already uses inline;
-- factored out here so the new food icons in this pass share one implementation instead of five
-- copies of the same sqrt loop. Existing hand icons are left calling their own inline version
-- untouched (targeted addition, not a refactor of already-shipped code).
local function drawBlobOutlined(c, cx, cy, rx, ry, col)
  local dark = darken(col, 0.5)
  for y = cy - ry, cy + ry do
    local dy = (y - cy) / ry
    local t = 1 - dy * dy
    if t > 0 then
      local halfw = floor(sqrt(t) * rx + 0.5)
      rectc(c, cx - halfw, y, cx + halfw, y, col)
    end
  end
  for y = cy - ry, cy + ry do
    local dy = (y - cy) / ry
    local t = 1 - dy * dy
    if t > 0 then
      local halfw = floor(sqrt(t) * rx + 0.5)
      setc(c, cx - halfw, y, dark); setc(c, cx + halfw, y, dark)
    end
  end
end

local function drawPowder(c, base, seed)
  local out, hi, sh = darken(base, 0.5), lighten(base, 0.4), darken(base, 0.25)
  for x = 2, 13 do
    local h = 6 + (cellNoise(seed, x, 0) % 4) -- 6..9 tall, irregular top edge
    local top = 13 - h
    for y = top, 13 do setc(c, x, y, base) end
    setc(c, x, top, out)
  end
  for x = 2, 13 do
    for y = 4, 13 do
      if getc(c, x, y) then
        local n = cellNoise(seed, x, y)
        if n < 14 then setc(c, x, y, sh) elseif n > 90 then setc(c, x, y, hi) end
      end
    end
  end
end

-- `seed`, when given, shifts the meniscus's raised span left/right by up to 1 cell so two liquids
-- with similar colours (e.g. clean vs boiled water) still read as distinct shapes, not just tints.
-- Omitted entirely, existing hand-authored liquid:water renders byte-identical to before.
local function drawLiquid(c, base, seed)
  local out, hi = darken(base, 0.5), lighten(base, 0.5)
  rectc(c, 2, 7, 13, 13, out)
  rectc(c, 3, 8, 12, 13, base)
  local shift = seed and (cellNoise(seed, 1, 1) % 3 - 1) or 0
  for x = 3, 12 do setc(c, x, (x >= 6 + shift and x <= 9 + shift) and 6 or 7, hi) end -- meniscus, higher mid-span
  setc(c, 5, 9, hi); setc(c, 9, 10, hi)
end

local function drawGas(c, base, seed)
  local out = darken(base, 0.3)
  for x = 2, 13 do if x % 2 == 0 then setc(c, x, 2, out); setc(c, x, 13, out) end end
  for i = 1, 10 do
    local n1, n2 = cellNoise(seed, i, 1), cellNoise(seed, i, 2)
    local x, y = 3 + (n1 % 10), 2 + (n2 % 10)
    local a = min(255, 90 + (n1 % 130))
    setc(c, x, y, { base[1], base[2], base[3], a })
  end
end

local function drawEnergy(c, base)
  local hi = lighten(base, 0.8)
  rectc(c, 7, 7, 8, 8, { 255, 255, 255, 255 })
  local rays = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
  for _, d in ipairs(rays) do
    for k = 1, 5 do
      local x, y = 7 + d[1] * (1 + k), 7 + d[2] * (1 + k)
      local a = max(40, 255 - k * 45)
      setc(c, x, y, { base[1], base[2], base[3], a })
    end
  end
  setc(c, 7, 6, hi); setc(c, 8, 6, hi); setc(c, 7, 9, hi); setc(c, 8, 9, hi)
end

-- ================================================================ compile: grid+pal OR raw canvas -> run-length rect list (memoised)
local function canvasFromGrid(grid, pal)
  local canvas = newCanvas()
  for y = 0, GRID - 1 do
    local line = grid[y + 1] or ""
    for x = 0, GRID - 1 do
      local ch = line:sub(x + 1, x + 1)
      if ch ~= "" and ch ~= "." then
        local col = pal[ch]
        canvas[y][x] = col and { col[1], col[2], col[3], col[4] or 255 } or { 255, 0, 255, 255 } -- unmapped char: loud magenta, not a silent gap
      end
    end
  end
  return canvas
end

local function sameColor(a, b) return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4] end

local function compileCanvas(canvas)
  local open, result = {}, {}
  for y = 0, GRID do
    local spans = {}
    if y < GRID then
      local x = 0
      while x < GRID do
        local col = canvas[y][x]
        if col then
          local x0 = x
          while x < GRID and sameColor(canvas[y][x], col) do x = x + 1 end
          spans[#spans + 1] = { x = x0, w = x - x0, c = col }
        else
          x = x + 1
        end
      end
    end
    local newOpen, used = {}, {}
    for _, o in ipairs(open) do
      local extended = false
      for si, sp in ipairs(spans) do
        if not used[si] and sp.x == o.x and sp.w == o.w and sameColor(sp.c, o.c) then
          o.h = o.h + 1; used[si] = true; newOpen[#newOpen + 1] = o; extended = true; break
        end
      end
      if not extended then result[#result + 1] = { x = o.x, y = o.y0, w = o.w, h = o.h, r = o.c[1], g = o.c[2], b = o.c[3], a = o.c[4] } end
    end
    for si, sp in ipairs(spans) do
      if not used[si] then newOpen[#newOpen + 1] = { x = sp.x, w = sp.w, c = sp.c, y0 = y, h = 1 } end
    end
    open = newOpen
  end
  return result
end

local function getCompiled(id)
  local c = compiledCache[id]
  if c then return c end
  local def = defs[id]
  if not def then
    -- Drawing an id nobody ever defined is an authoring bug, not a silent square: loud magenta X.
    local cv = newCanvas(); rectc(cv, 3, 3, 12, 12, { 255, 0, 255, 255 })
    def = { kind = "canvas", canvas = cv }
    defs[id] = def
  end
  local canvas = (def.kind == "canvas") and def.canvas or canvasFromGrid(def.grid, def.pal)
  c = compileCanvas(canvas)
  compiledCache[id] = c
  return c
end

-- ================================================================ public authoring API
function ICON.define(id, def)
  defs[id] = { kind = "grid", grid = def.grid, pal = def.pal or {} }
  compiledCache[id] = nil
  for k in pairs(sizeCache) do if k:find(id .. "@", 1, true) == 1 then sizeCache[k] = nil end end
end
function ICON.defineCanvas(id, canvas)
  defs[id] = { kind = "canvas", canvas = canvas }
  compiledCache[id] = nil
  for k in pairs(sizeCache) do if k:find(id .. "@", 1, true) == 1 then sizeCache[k] = nil end end
end

local function buildSizeCache(id, size)
  local compiled = getCompiled(id)
  local scale = size / GRID
  local cached = {}
  for _, r in ipairs(compiled) do
    local px, py = floor(r.x * scale + 0.5), floor(r.y * scale + 0.5)
    local pw = floor((r.x + r.w) * scale + 0.5) - px
    local ph = floor((r.y + r.h) * scale + 0.5) - py
    if pw < 1 then pw = 1 end
    if ph < 1 then ph = 1 end
    cached[#cached + 1] = { px, py, pw, ph, r.r, r.g, r.b, r.a }
  end
  return cached
end

-- Steady-state cost: one table lookup (plus one resolve() call ONLY the first time a given raw
-- code is seen -- resolve() itself early-outs on an already-defined key), then N graphics.fillRect
-- calls -- no per-frame scaling math, no per-pixel loop, no walk of the raw grid. Returns the rect
-- count actually drawn (used by the benchmark).
--
-- `id` may be either a real icon id ("mat:wood", "tool:pick:steel", anything ICON.list() returns)
-- OR a raw material/element code ("WOOD", "IRON", a pseudo-item name) -- ui.lua's and guide.lua's
-- own drawMatIcon() call this with the raw code directly (`R.icon.draw(code, x, y, size, alpha)`,
-- their documented contract, verified against ui.lua:38-52/guide.lua:16-30 in the live tree, shipped
-- by @icons_apply in parallel this wave) and rely on this function to resolve it, exactly like
-- resolve() would, but without a caller ever needing to call resolve() itself.
function ICON.draw(id, x, y, size, alpha)
  size = size or ICON.SIZE_SMALL
  local iconId = defs[id] and id or ICON.resolve(id)
  local key = iconId .. "@" .. size
  local cached = sizeCache[key]
  if not cached then cached = buildSizeCache(iconId, size); sizeCache[key] = cached end
  if alpha and alpha < 255 then
    local mul = alpha / 255
    for _, e in ipairs(cached) do graphics.fillRect(x + e[1], y + e[2], e[3], e[4], e[5], e[6], e[7], floor(e[8] * mul + 0.5)) end
  else
    for _, e in ipairs(cached) do graphics.fillRect(x + e[1], y + e[2], e[3], e[4], e[5], e[6], e[7], e[8]) end
  end
  return #cached
end

-- Pre-populate the (id,size) cache now instead of paying the compile+scale cost on the first real
-- draw call (e.g. the first frame a machine list scrolls a new row into view).
function ICON.warm(ids, sizes)
  sizes = sizes or { ICON.SIZE_SMALL, ICON.SIZE_LARGE }
  for _, id in ipairs(ids) do
    for _, sz in ipairs(sizes) do
      local key = id .. "@" .. sz
      if not sizeCache[key] then sizeCache[key] = buildSizeCache(id, sz) end
    end
  end
end

function ICON.list()
  local out = {}
  for id in pairs(defs) do out[#out + 1] = id end
  table.sort(out)
  return out
end

-- ================================================================ procedural fallback
-- Same Properties-bit classification guide.lua's own elemFactsLines() uses for its material pages
-- (guide.lua:596-600) -- reimplemented here rather than calling into guide.lua, since this plugin
-- must not depend on load order relative to it (icons loads FIRST, before guide).
local function classifyState(tid)
  local ok, props = pcall(elem.property, tid, "Properties")
  props = ok and props or 0
  local function hasBit(b) return b and band(props, b) ~= 0 end
  if hasBit(elem.TYPE_LIQUID) then return "liquid" end
  if hasBit(elem.TYPE_GAS) then return "gas" end
  if hasBit(elem.TYPE_SOLID) then return "solid" end
  if hasBit(elem.TYPE_PART) then
    local okf, fd = pcall(elem.property, tid, "Falldown")
    if okf and fd and fd > 0 then return "powder" end
    return "solid"
  end
  if hasBit(elem.TYPE_ENERGY) then return "energy" end
  return "solid"
end

-- INFERRED heuristics (name-pattern / small hardcoded set), not a real engine property -- there is
-- no "is this an ore" or "is this a refined metal" bit on a TPT element. Good enough to visually
-- differentiate the highest-traffic materials; documented here so the next lane can extend the set
-- rather than guess why gold ore has speckle and a plain rock doesn't.
local METAL_CODES = { METL = true, STEL = true, CU = true, BMTL = true, BRMT = true, TTAN = true, PTNM = true, ZIRC = true, LEAD = true, TUNG = true, GOLD = true, ZINC = true }
local function looksLikeOre(code)
  local nice = (R.nice and R.nice(code)) or code
  return tostring(nice):lower():find("%f[%a]ore%f[%A]") ~= nil
end
local function looksMetal(code) return METAL_CODES[code] == true end

function ICON._defineElementFallback(key, code, tid)
  local r, g, b = R.colourOf(code)
  local base = { r or 150, g or 150, b or 160 }
  local state = classifyState(tid)
  local seed = strHash(tostring(code))
  local canvas = newCanvas()
  if state == "liquid" then drawLiquid(canvas, base, seed)
  elseif state == "gas" then drawGas(canvas, base, seed)
  elseif state == "powder" then drawPowder(canvas, base, seed)
  elseif state == "energy" then drawEnergy(canvas, base)
  else drawChunk(canvas, base, seed) end
  if state ~= "gas" and state ~= "energy" then
    if looksLikeOre(code) then addSpeckle(canvas, seed, { 255, 240, 190, 255 }, 7) end
    if looksMetal(code) then addMetalShine(canvas, base) end
  end
  ICON.defineCanvas(key, canvas)
end

function ICON._defineStringFallback(key, code)
  local seed = strHash(tostring(code))
  local base = { 90 + seed % 140, 90 + floor(seed / 7) % 140, 90 + floor(seed / 13) % 140 }
  local canvas = newCanvas()
  drawChunk(canvas, base, seed)
  addSpeckle(canvas, seed, lighten(base, 0.8), 6)
  ICON.defineCanvas(key, canvas)
end

ICON.ELEMENT_ICON = {} -- filled below, after the hand-authored icons exist to point at

-- Total function: hand-authored mapping, else a real-element procedural fallback (memoised),
-- else a hashed-string procedural fallback (memoised) -- never nil, never a plain square.
function ICON.resolve(code)
  code = code or "?"
  local mapped = ICON.ELEMENT_ICON[code]
  if mapped and defs[mapped] then return mapped end
  local ekey = "elem:" .. code
  if defs[ekey] then return ekey end
  local tid = R.eid and R.eid(code)
  if tid then ICON._defineElementFallback(ekey, code, tid); return ekey end
  local skey = "str:" .. code
  if defs[skey] then return skey end
  ICON._defineStringFallback(skey, code)
  return skey
end

-- ================================================================ 64 hand-authored icons (highest-traffic things,
-- extended 2026-09-02 by @iconart with the first-hour food/weapon/machine icons -- see that pass's
-- comment further down for what was added and why)
local function pickCanvas(head, handle)
  local c = newCanvas()
  thickLine(c, 11, 14, 5, 5, darken(handle, 0.55), 4)
  thickLine(c, 11, 14, 5, 5, handle, 2)
  thickLine(c, 3, 6, 13, 3, darken(head, 0.55), 4)
  thickLine(c, 3, 6, 13, 3, head, 2)
  setc(c, 5, 5, lighten(head, 0.5)); setc(c, 6, 4, lighten(head, 0.5))
  return c
end
local function swordCanvas(blade, guard)
  local c = newCanvas()
  thickLine(c, 8, 2, 8, 11, darken(blade, 0.5), 4)
  thickLine(c, 8, 2, 8, 11, blade, 2)
  setc(c, 7, 3, lighten(blade, 0.5)); setc(c, 7, 4, lighten(blade, 0.5))
  thickLine(c, 4, 11, 12, 11, darken(guard, 0.4), 3)
  thickLine(c, 4, 11, 12, 11, guard, 1)
  local wood = { 150, 105, 60 }
  thickLine(c, 8, 12, 8, 14, darken(wood, 0.5), 3)
  thickLine(c, 8, 12, 8, 14, wood, 1)
  setc(c, 8, 15, guard)
  return c
end

ICON.defineCanvas("tool:pick:wood", pickCanvas({ 150, 130, 110 }, { 150, 105, 60 }))
ICON.defineCanvas("tool:pick:stone", pickCanvas({ 130, 130, 135 }, { 150, 105, 60 }))
ICON.defineCanvas("tool:pick:iron", pickCanvas({ 190, 190, 200 }, { 120, 85, 50 }))
ICON.defineCanvas("tool:pick:steel", pickCanvas({ 210, 215, 225 }, { 100, 70, 45 }))
do
  local dpick = pickCanvas({ 170, 235, 245 }, { 90, 60, 40 })
  addSpeckle(dpick, strHash("DPICK"), { 255, 255, 255, 255 }, 3)
  ICON.defineCanvas("tool:pick:diamond", dpick)
end

ICON.defineCanvas("tool:sword:wood", swordCanvas({ 190, 175, 150 }, { 120, 85, 50 }))
ICON.defineCanvas("tool:sword:iron", swordCanvas({ 200, 200, 210 }, { 120, 85, 50 }))
ICON.defineCanvas("tool:sword:steel", swordCanvas({ 220, 225, 235 }, { 90, 90, 100 }))

do -- axe: single tier
  local c = newCanvas()
  local handle = { 150, 105, 60 }
  thickLine(c, 11, 14, 5, 3, darken(handle, 0.5), 4)
  thickLine(c, 11, 14, 5, 3, handle, 2)
  local head = { 180, 180, 190 }
  rectc(c, 3, 1, 8, 6, darken(head, 0.5))
  rectc(c, 4, 2, 7, 5, head)
  clearc(c, 3, 1); clearc(c, 3, 6); clearc(c, 8, 1); clearc(c, 8, 6)
  setc(c, 4, 2, lighten(head, 0.5)); setc(c, 5, 2, lighten(head, 0.5))
  ICON.defineCanvas("tool:axe", c)
end

do -- torch: stick + layered flame
  local c = newCanvas()
  local wood = { 150, 105, 60 }
  thickLine(c, 8, 15, 8, 7, darken(wood, 0.5), 3)
  thickLine(c, 8, 15, 8, 7, wood, 1)
  rectc(c, 5, 6, 11, 7, { 230, 90, 20, 255 })
  rectc(c, 6, 4, 10, 6, { 230, 90, 20, 255 })
  rectc(c, 6, 3, 9, 5, { 255, 170, 40, 255 })
  rectc(c, 7, 1, 9, 3, { 255, 170, 40, 255 })
  setc(c, 8, 1, { 255, 235, 140, 255 }); setc(c, 7, 2, { 255, 235, 140, 255 }); setc(c, 8, 2, { 255, 235, 140, 255 })
  ICON.defineCanvas("tool:torch", c)
end

do -- bucket: trapezoid pail + arc handle
  local c = newCanvas()
  local body = { 150, 150, 160 }
  for y = 6, 13 do
    local inset = floor((y - 6) / 2)
    rectc(c, 3 + inset, y, 12 - inset, y, darken(body, 0.5))
  end
  for y = 7, 12 do
    local inset = floor((y - 6) / 2)
    rectc(c, 4 + inset, y, 11 - inset, y, body)
  end
  setc(c, 5, 8, lighten(body, 0.5)); setc(c, 5, 9, lighten(body, 0.5))
  lineC(c, 4, 6, 6, 3, darken(body, 0.5)); lineC(c, 11, 6, 9, 3, darken(body, 0.5)); lineC(c, 6, 3, 9, 3, darken(body, 0.5))
  ICON.defineCanvas("tool:bucket", c)
end

do -- workbench
  local c = newCanvas()
  local wood = { 150, 105, 60 }
  rectc(c, 2, 6, 13, 8, darken(wood, 0.5))
  rectc(c, 2, 5, 13, 7, wood)
  rectc(c, 3, 9, 4, 14, darken(wood, 0.5)); rectc(c, 11, 9, 12, 14, darken(wood, 0.5))
  for i = 0, 2 do setc(c, 3 + i, 6, lighten(wood, 0.4)) end
  setc(c, 9, 5, { 200, 200, 210, 255 }); setc(c, 10, 5, { 200, 200, 210, 255 })
  ICON.defineCanvas("station:workbench", c)
end
do -- furnace
  local c = newCanvas()
  local brick = { 150, 60, 45 }
  rectc(c, 3, 3, 12, 14, darken(brick, 0.5))
  rectc(c, 4, 4, 11, 13, brick)
  for y = 5, 12, 3 do for x = 4, 11 do setc(c, x, y, darken(brick, 0.3)) end end
  rectc(c, 6, 9, 9, 12, { 30, 20, 18, 255 })
  rectc(c, 7, 10, 8, 11, { 255, 150, 40, 255 })
  setc(c, 7, 10, { 255, 220, 120, 255 })
  ICON.defineCanvas("station:furnace", c)
end
do -- anvil
  local c = newCanvas()
  local metal = { 90, 90, 100 }
  rectc(c, 2, 7, 12, 8, darken(metal, 0.5)); rectc(c, 2, 7, 12, 8, metal)
  rectc(c, 4, 9, 11, 10, darken(metal, 0.5)); rectc(c, 5, 9, 10, 10, metal)
  rectc(c, 3, 11, 12, 13, darken(metal, 0.5)); rectc(c, 4, 11, 11, 12, metal)
  lineC(c, 12, 7, 14, 6, darken(metal, 0.5)); lineC(c, 12, 8, 14, 7, metal)
  setc(c, 3, 7, lighten(metal, 0.5)); setc(c, 4, 7, lighten(metal, 0.5))
  ICON.defineCanvas("station:anvil", c)
end
do -- research bench: table + beaker
  local c = newCanvas()
  local tbl = { 90, 95, 110 }
  rectc(c, 2, 9, 13, 11, darken(tbl, 0.5)); rectc(c, 2, 8, 13, 10, tbl)
  rectc(c, 3, 12, 4, 14, darken(tbl, 0.5)); rectc(c, 11, 12, 12, 14, darken(tbl, 0.5))
  lineC(c, 6, 3, 6, 7, { 170, 170, 180, 255 }); lineC(c, 10, 3, 10, 7, { 170, 170, 180, 255 })
  lineC(c, 6, 7, 10, 7, { 170, 170, 180, 255 })
  rectc(c, 7, 5, 9, 7, { 90, 220, 170, 220 })
  setc(c, 8, 4, { 200, 255, 230, 255 })
  ICON.defineCanvas("station:research", c)
end
do -- advanced lab: housing + glowing crystal
  local c = newCanvas()
  local base = { 70, 70, 90 }
  rectc(c, 2, 9, 13, 12, darken(base, 0.5)); rectc(c, 2, 9, 13, 11, base)
  local crystal, glow = { 170, 90, 230, 255 }, { 220, 160, 255, 180 }
  lineC(c, 8, 2, 5, 7, crystal); lineC(c, 8, 2, 11, 7, crystal)
  lineC(c, 5, 7, 8, 9, crystal); lineC(c, 11, 7, 8, 9, crystal)
  setc(c, 8, 4, glow); setc(c, 7, 6, glow); setc(c, 9, 6, glow)
  ICON.defineCanvas("station:advlab", c)
end
do -- crate: wooden box with diagonal cross-bracing
  local c = newCanvas()
  local wood = { 160, 120, 70 }
  rectc(c, 3, 3, 12, 13, darken(wood, 0.5)); rectc(c, 4, 4, 11, 12, wood)
  lineC(c, 4, 4, 11, 12, darken(wood, 0.5)); lineC(c, 11, 4, 4, 12, darken(wood, 0.5))
  rectc(c, 4, 7, 11, 8, darken(wood, 0.5))
  setc(c, 4, 4, lighten(wood, 0.4)); setc(c, 5, 4, lighten(wood, 0.4))
  ICON.defineCanvas("station:crate", c)
end

local function matBar(color)
  local c = newCanvas()
  rectc(c, 2, 6, 13, 10, darken(color, 0.5))
  rectc(c, 3, 7, 12, 9, color)
  setc(c, 4, 7, lighten(color, 0.5)); setc(c, 5, 7, lighten(color, 0.5)); setc(c, 6, 8, lighten(color, 0.5))
  return c
end

do local c = newCanvas(); drawChunk(c, { 150, 105, 60 })
  for _, p in ipairs({ { 5, 6 }, { 10, 6 }, { 5, 9 }, { 10, 9 }, { 7, 11 } }) do
    if getc(c, p[1], p[2]) then setc(c, p[1], p[2], darken({ 150, 105, 60 }, 0.3)) end
  end
  ICON.defineCanvas("mat:wood", c)
end
do local c = newCanvas(); drawChunk(c, { 130, 130, 135 })
  addSpeckle(c, strHash("STONE_ICON"), darken({ 130, 130, 135 }, 0.4), 8)
  ICON.defineCanvas("mat:stone", c)
end
do local c = newCanvas(); drawChunk(c, { 120, 110, 100 })
  addSpeckle(c, strHash("IRON_ORE_ICON"), { 200, 120, 70, 255 }, 6)
  ICON.defineCanvas("mat:iron_ore", c)
end
do local c = newCanvas(); drawChunk(c, { 95, 95, 105 })
  addSpeckle(c, strHash("GOLD_ORE_ICON"), { 255, 215, 90, 255 }, 6)
  ICON.defineCanvas("mat:gold_ore", c)
end
do local c = newCanvas(); drawChunk(c, { 40, 40, 45 })
  local shine = { 90, 100, 140, 255 }
  setc(c, 5, 6, shine); setc(c, 9, 9, shine); setc(c, 7, 10, shine)
  ICON.defineCanvas("mat:coal", c)
end
do local c = newCanvas(); drawChunk(c, { 150, 100, 60 })
  addSpeckle(c, strHash("COPPER_ICON"), { 255, 170, 110, 255 }, 5)
  addMetalShine(c, { 150, 100, 60 })
  ICON.defineCanvas("mat:copper", c)
end
ICON.defineCanvas("mat:steel", matBar({ 175, 180, 190 }))
ICON.defineCanvas("mat:iron_bar", matBar({ 160, 150, 140 }))
do -- diamond: rhombus gem via per-row spans, faceted highlight
  local c = newCanvas()
  local gem, out = { 150, 230, 240 }, darken({ 150, 230, 240 }, 0.5)
  local cx, topY, botY, midY = 8, 2, 14, 7
  for y = topY, botY do
    local t = (y <= midY) and (y - topY) / (midY - topY) or (botY - y) / (botY - midY)
    local halfw = floor(t * 6) + 1
    rectc(c, cx - halfw, y, cx + halfw, y, gem)
  end
  for y = topY, botY do
    local t = (y <= midY) and (y - topY) / (midY - topY) or (botY - y) / (botY - midY)
    local halfw = floor(t * 6) + 1
    setc(c, cx - halfw, y, out); setc(c, cx + halfw, y, out)
  end
  setc(c, 6, 5, { 255, 255, 255, 255 }); setc(c, 7, 4, { 255, 255, 255, 255 })
  ICON.defineCanvas("mat:diamond", c)
end
do local c = newCanvas(); drawPowder(c, { 110, 80, 55 }, strHash("DIRT_ICON")); ICON.defineCanvas("mat:dirt", c) end
do local c = newCanvas(); drawPowder(c, { 210, 190, 140 }, strHash("SAND_ICON")); ICON.defineCanvas("mat:sand", c) end
do local c = newCanvas(); drawLiquid(c, { 70, 130, 220 }); ICON.defineCanvas("liquid:water", c) end

do -- food: generic meal (round + stem/leaf)
  local c = newCanvas()
  local red = { 200, 60, 60 }
  for y = 4, 13 do
    local dy = y - 8.5
    local halfw = floor(sqrt(max(0, 26 - dy * dy)))
    rectc(c, 8 - halfw, y, 8 + halfw, y, red)
  end
  for y = 4, 13 do
    local dy = y - 8.5
    local halfw = floor(sqrt(max(0, 26 - dy * dy)))
    setc(c, 8 - halfw, y, darken(red, 0.5)); setc(c, 8 + halfw, y, darken(red, 0.5))
  end
  setc(c, 6, 6, lighten(red, 0.5)); setc(c, 6, 7, lighten(red, 0.5))
  setc(c, 8, 3, { 110, 70, 40, 255 }); setc(c, 9, 2, { 60, 150, 60, 255 }); setc(c, 10, 2, { 60, 150, 60, 255 })
  ICON.defineCanvas("food:generic", c)
end
do -- food: bread loaf
  local c = newCanvas()
  local base = { 200, 160, 90 }
  rectc(c, 2, 7, 13, 12, darken(base, 0.5)); rectc(c, 3, 6, 12, 11, base)
  for _, p in ipairs({ { 2, 7 }, { 13, 7 }, { 2, 12 }, { 13, 12 } }) do clearc(c, p[1], p[2]) end
  for _, x in ipairs({ 5, 8, 11 }) do setc(c, x, 7, darken(base, 0.35)); setc(c, x, 8, darken(base, 0.35)) end
  setc(c, 4, 6, lighten(base, 0.4)); setc(c, 5, 6, lighten(base, 0.4))
  ICON.defineCanvas("food:bread", c)
end

-- ================================================================ @iconart pass, 2026-09-02: the game is
-- public (v1.17.3) -- these are the things a first-hour player actually sees and holds that had NO
-- real particle backing at all (foraged food, held weapons, machine kits), so they were falling
-- through to the WORST fallback tier (_defineStringFallback's hashed-colour chunk, no real shape).
-- Same grammar as the block above: darken()/lighten() outline+highlight, restrained palette.
local function gunCanvas(barrelColor, stockColor, doubleBarrel)
  local c = newCanvas()
  local stock = stockColor
  thickLine(c, 3, 13, 8, 10, darken(stock, 0.5), 4)
  thickLine(c, 3, 13, 8, 10, stock, 2)
  if doubleBarrel then
    thickLine(c, 6, 11, 14, 4, darken(barrelColor, 0.5), 4)
    thickLine(c, 6, 11, 14, 4, barrelColor, 2)
    thickLine(c, 6, 13, 14, 6, darken(barrelColor, 0.5), 3)
    thickLine(c, 6, 13, 14, 6, barrelColor, 1)
  else
    thickLine(c, 6, 12, 14, 4, darken(barrelColor, 0.5), 3)
    thickLine(c, 6, 12, 14, 4, barrelColor, 2)
  end
  setc(c, 8, 9, lighten(barrelColor, 0.5)); setc(c, 9, 8, lighten(barrelColor, 0.5))
  return c
end
ICON.defineCanvas("wpn:musket", gunCanvas({ 150, 110, 60 }, { 110, 80, 50 }, false))
ICON.defineCanvas("wpn:shotgun", gunCanvas({ 90, 90, 100 }, { 120, 85, 55 }, true))

do -- weapon: bow (arc via connected segments + string)
  local c = newCanvas()
  local wood, dark = { 150, 105, 60 }, darken({ 150, 105, 60 }, 0.5)
  local pts = { { 9, 2 }, { 6, 3 }, { 4, 6 }, { 4, 10 }, { 6, 13 }, { 9, 14 } }
  for i = 1, #pts - 1 do lineC(c, pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2], dark) end
  for i = 1, #pts - 1 do lineC(c, pts[i][1] + 1, pts[i][2], pts[i + 1][1] + 1, pts[i + 1][2], wood) end
  lineC(c, 9, 2, 9, 14, { 230, 230, 220, 255 })
  setc(c, 5, 4, lighten(wood, 0.5))
  ICON.defineCanvas("wpn:bow", c)
end
do -- weapon: boomerang (two curved arms meeting at the grip)
  local c = newCanvas()
  local wood = { 170, 130, 80 }
  thickLine(c, 3, 4, 8, 12, darken(wood, 0.5), 3); thickLine(c, 3, 4, 8, 12, wood, 2)
  thickLine(c, 13, 4, 8, 12, darken(wood, 0.5), 3); thickLine(c, 13, 4, 8, 12, wood, 2)
  setc(c, 4, 5, lighten(wood, 0.5)); setc(c, 12, 5, lighten(wood, 0.5))
  ICON.defineCanvas("wpn:boomerang", c)
end

do -- food: wheat sheaf (fanned stalks + tie band)
  local c = newCanvas()
  local gold, dark = { 215, 178, 70 }, { 150, 110, 40 }
  local tips = { { 3, 3 }, { 6, 2 }, { 9, 1 }, { 12, 2 } }
  for _, t in ipairs(tips) do lineC(c, 8, 14, t[1], t[2], dark) end
  for _, t in ipairs(tips) do lineC(c, 8, 14, t[1], t[2] + 1, gold) end
  for _, t in ipairs(tips) do
    local mx, my = floor((8 + t[1]) / 2), floor((14 + t[2]) / 2)
    setc(c, mx - 1, my, gold); setc(c, mx + 1, my, gold)
  end
  rectc(c, 6, 13, 10, 14, { 120, 85, 50, 255 })
  ICON.defineCanvas("food:wheat", c)
end
do -- food: berries (three red blobs, green leaf accent)
  local c = newCanvas()
  local red, hi = { 200, 45, 60 }, lighten({ 200, 45, 60 }, 0.5)
  drawBlobOutlined(c, 6, 10, 3, 3, red)
  drawBlobOutlined(c, 10, 10, 3, 3, red)
  drawBlobOutlined(c, 8, 6, 3, 3, red)
  setc(c, 5, 9, hi); setc(c, 9, 5, hi)
  rectc(c, 7, 2, 9, 3, { 70, 150, 60, 255 })
  setc(c, 8, 1, { 70, 150, 60, 255 })
  ICON.defineCanvas("food:berry", c)
end
do -- food: root (tapering tuber + leaf top)
  local c = newCanvas()
  local root, dark = { 190, 140, 90 }, darken({ 190, 140, 90 }, 0.5)
  for y = 5, 13 do
    local w = max(1, 5 - floor((y - 5) / 2))
    rectc(c, 8 - w, y, 8 + w, y, root)
  end
  setc(c, 8, 5, dark)
  rectc(c, 7, 2, 9, 4, { 80, 160, 70, 255 })
  ICON.defineCanvas("food:root", c)
end
do -- food: fish (oval body, tail notch, eye)
  local c = newCanvas()
  local body, dark, hi = { 150, 180, 200 }, darken({ 150, 180, 200 }, 0.5), lighten({ 150, 180, 200 }, 0.5)
  drawBlobOutlined(c, 9, 8, 5, 3, body)
  lineC(c, 4, 8, 2, 5, dark); lineC(c, 4, 10, 2, 13, dark)
  setc(c, 7, 7, { 20, 20, 25, 255 })
  setc(c, 8, 6, hi)
  ICON.defineCanvas("food:fish", c)
end
do -- food: mushroom (raw -- warm tan cap, pale stem)
  local c = newCanvas()
  local cap, stem = { 190, 90, 60 }, { 230, 220, 200 }
  drawBlobOutlined(c, 8, 6, 6, 4, cap)
  for _, p in ipairs({ { 5, 5 }, { 8, 4 }, { 11, 6 } }) do setc(c, p[1], p[2], lighten(cap, 0.5)) end
  rectc(c, 6, 9, 10, 14, darken(stem, 0.3))
  rectc(c, 7, 9, 9, 13, stem)
  ICON.defineCanvas("food:mushroom", c)
end
do -- food: cooked fish (browner body + steam wisp, same silhouette as raw)
  local c = newCanvas()
  local body, dark = { 170, 110, 70 }, darken({ 170, 110, 70 }, 0.5)
  drawBlobOutlined(c, 9, 8, 5, 3, body)
  lineC(c, 4, 8, 2, 5, dark); lineC(c, 4, 10, 2, 13, dark)
  setc(c, 7, 7, { 40, 25, 20, 255 })
  setc(c, 7, 3, { 230, 230, 230, 160 }); setc(c, 8, 2, { 230, 230, 230, 140 })
  ICON.defineCanvas("food:cfish", c)
end
do -- food: roasted mushroom (charred cap flecks, same silhouette as raw)
  local c = newCanvas()
  local cap, stem = { 120, 60, 40 }, { 210, 190, 160 }
  drawBlobOutlined(c, 8, 6, 6, 4, cap)
  setc(c, 6, 5, { 40, 25, 20, 255 }); setc(c, 10, 6, { 40, 25, 20, 255 })
  rectc(c, 6, 9, 10, 14, darken(stem, 0.3))
  rectc(c, 7, 9, 9, 13, stem)
  ICON.defineCanvas("food:cmshrm", c)
end
do -- food: hearty stew (bowl + filling + veggie flecks)
  local c = newCanvas()
  local bowl, food = { 160, 160, 170 }, { 140, 90, 55 }
  rectc(c, 2, 9, 13, 13, darken(bowl, 0.5)); rectc(c, 3, 9, 12, 12, bowl)
  rectc(c, 4, 7, 11, 9, darken(food, 0.4)); rectc(c, 4, 8, 11, 9, food)
  setc(c, 6, 8, { 200, 60, 50, 255 }); setc(c, 9, 8, { 90, 150, 60, 255 })
  ICON.defineCanvas("food:stew", c)
end
do local c = newCanvas(); drawLiquid(c, { 150, 210, 235 }); setc(c, 10, 9, { 255, 255, 255, 200 }); ICON.defineCanvas("food:boiledwater", c) end
do local c = newCanvas(); drawLiquid(c, { 130, 200, 235 }); ICON.defineCanvas("food:cleanwater", c) end
do
  local c = newCanvas(); drawLiquid(c, { 110, 110, 70 })
  addSpeckle(c, strHash("DIRTYWATER"), darken({ 110, 110, 70 }, 0.5), 4)
  ICON.defineCanvas("food:dirtywater", c)
end

do -- machine: boiler (riveted tank + lit firebox + vent stub)
  local c = newCanvas()
  local metal = { 110, 110, 120 }
  rectc(c, 3, 2, 12, 13, darken(metal, 0.5)); rectc(c, 4, 3, 11, 12, metal)
  for _, p in ipairs({ { 4, 3 }, { 11, 3 }, { 4, 12 }, { 11, 12 } }) do clearc(c, p[1], p[2]) end
  for y = 4, 11, 3 do setc(c, 4, y, darken(metal, 0.3)); setc(c, 11, y, darken(metal, 0.3)) end
  rectc(c, 6, 10, 9, 12, { 40, 25, 20, 255 })
  rectc(c, 7, 11, 8, 12, { 255, 140, 40, 255 })
  rectc(c, 7, 0, 9, 2, darken(metal, 0.4))
  setc(c, 4, 4, lighten(metal, 0.4))
  ICON.defineCanvas("mach:boiler", c)
end
do -- machine: turbine (housing + radiating blades + shaft hub)
  local c = newCanvas()
  local metal, blade = { 90, 95, 105 }, { 200, 210, 220 }
  drawBlobOutlined(c, 8, 8, 6, 6, metal)
  for _, a in ipairs({ 0, 60, 120, 180, 240, 300 }) do
    local rad = a * math.pi / 180
    lineC(c, 8, 8, floor(8 + math.cos(rad) * 5), floor(8 + math.sin(rad) * 5), blade)
  end
  drawBlobOutlined(c, 8, 8, 2, 2, darken(metal, 0.3))
  setc(c, 6, 6, lighten(metal, 0.6))
  ICON.defineCanvas("mach:turbine", c)
end
do -- machine: hand crank generator (housing + handle arm + knob)
  local c = newCanvas()
  local metal, wood = { 120, 120, 130 }, { 150, 105, 60 }
  drawBlobOutlined(c, 6, 8, 4, 4, metal)
  thickLine(c, 9, 8, 14, 4, darken(wood, 0.5), 3)
  thickLine(c, 9, 8, 14, 4, wood, 2)
  setc(c, 14, 3, { 90, 90, 95, 255 })
  setc(c, 5, 7, lighten(metal, 0.5))
  ICON.defineCanvas("mach:crank", c)
end
do -- machine: water wheel (spoked wooden wheel + water trough)
  local c = newCanvas()
  local wood, water = { 150, 105, 60 }, { 70, 130, 220 }
  drawBlobOutlined(c, 8, 7, 6, 6, wood)
  for _, a in ipairs({ 0, 45, 90, 135, 180, 225, 270, 315 }) do
    local rad = a * math.pi / 180
    lineC(c, 8, 7, floor(8 + math.cos(rad) * 5), floor(7 + math.sin(rad) * 5), darken(wood, 0.5))
  end
  rectc(c, 2, 13, 13, 14, water)
  setc(c, 6, 5, lighten(wood, 0.5))
  ICON.defineCanvas("mach:wheel", c)
end
do -- machine: water pump (housing + intake pipe + valve wheel)
  local c = newCanvas()
  local metal, pipe = { 110, 115, 125 }, { 70, 130, 220 }
  rectc(c, 4, 7, 11, 13, darken(metal, 0.5)); rectc(c, 5, 8, 10, 12, metal)
  rectc(c, 6, 3, 9, 7, darken(pipe, 0.4)); rectc(c, 7, 3, 8, 6, pipe)
  drawBlobOutlined(c, 8, 5, 2, 2, darken(metal, 0.3))
  setc(c, 5, 8, lighten(metal, 0.5))
  ICON.defineCanvas("mach:pump", c)
end
do -- machine: powered door (slab + handle)
  local c = newCanvas()
  local slab = { 130, 120, 110 }
  rectc(c, 4, 1, 11, 14, darken(slab, 0.5)); rectc(c, 5, 2, 10, 13, slab)
  setc(c, 9, 7, { 230, 210, 80, 255 })
  for _, x in ipairs({ 6, 9 }) do setc(c, x, 3, lighten(slab, 0.4)) end
  ICON.defineCanvas("mach:door", c)
end
do -- machine: conveyor belt (two rollers + belt strip + direction arrow)
  local c = newCanvas()
  local metal, belt = { 90, 90, 100 }, { 60, 60, 65 }
  drawBlobOutlined(c, 3, 11, 2, 2, metal)
  drawBlobOutlined(c, 13, 11, 2, 2, metal)
  rectc(c, 3, 8, 13, 9, darken(belt, 0.4)); rectc(c, 3, 9, 13, 10, belt)
  lineC(c, 5, 6, 9, 6, { 230, 210, 80, 255 }); lineC(c, 9, 6, 7, 4, { 230, 210, 80, 255 }); lineC(c, 9, 6, 7, 8, { 230, 210, 80, 255 })
  ICON.defineCanvas("mach:conveyor", c)
end
do -- machine: wire coil (spiralled copper loop)
  local c = newCanvas()
  local cu = { 200, 120, 70 }
  for r = 2, 6, 2 do
    for a = 0, 350, 20 do
      local rad = a * math.pi / 180
      setc(c, floor(8 + math.cos(rad) * r), floor(8 + math.sin(rad) * r), r == 6 and darken(cu, 0.4) or cu)
    end
  end
  setc(c, 6, 6, lighten(cu, 0.5))
  ICON.defineCanvas("mach:wirecoil", c)
end
do -- machine: LED lamp (glowing bulb + base)
  local c = newCanvas()
  local glass, glow = { 230, 225, 150 }, { 255, 240, 120, 220 }
  drawBlobOutlined(c, 8, 6, 4, 4, glass)
  for _, p in ipairs({ { 6, 4 }, { 10, 4 }, { 8, 2 } }) do setc(c, p[1], p[2], glow) end
  rectc(c, 6, 10, 10, 13, darken({ 140, 140, 150 }, 0.4))
  rectc(c, 7, 10, 9, 12, { 140, 140, 150, 255 })
  ICON.defineCanvas("mach:lamp", c)
end
do -- machine: solar panel (grid of cells + sun-ray corner)
  local c = newCanvas()
  local panel, cell = { 40, 50, 90 }, { 70, 90, 160 }
  rectc(c, 2, 6, 13, 12, darken(panel, 0.5)); rectc(c, 3, 7, 12, 11, panel)
  for x = 4, 11, 2 do for y = 8, 10, 2 do rectc(c, x, y, x + 1, y + 1, cell) end end
  setc(c, 12, 3, { 255, 220, 120, 255 }); setc(c, 13, 4, { 255, 220, 120, 255 }); setc(c, 11, 2, { 255, 220, 120, 255 })
  ICON.defineCanvas("mach:solar", c)
end
do -- machine: battery bank (case + two terminal nubs)
  local c = newCanvas()
  local body = { 70, 150, 90 }
  rectc(c, 3, 5, 12, 13, darken(body, 0.5)); rectc(c, 4, 6, 11, 12, body)
  rectc(c, 6, 3, 7, 5, darken({ 90, 90, 95 }, 0.3)); rectc(c, 9, 3, 10, 5, darken({ 90, 90, 95 }, 0.3))
  setc(c, 5, 6, lighten(body, 0.5))
  ICON.defineCanvas("mach:battery", c)
end
do -- machine: gas detector (handheld body + dial)
  local c = newCanvas()
  local body, dial = { 90, 95, 105 }, { 230, 90, 60 }
  rectc(c, 4, 6, 11, 13, darken(body, 0.5)); rectc(c, 5, 7, 10, 12, body)
  drawBlobOutlined(c, 8, 9, 2, 2, { 230, 230, 230 })
  setc(c, 8, 9, dial)
  rectc(c, 7, 3, 9, 6, darken(body, 0.4))
  ICON.defineCanvas("mach:gasdetector", c)
end
do -- machine: sorter (T-junction chute + diverting arrow)
  local c = newCanvas()
  local metal, arrow = { 110, 110, 120 }, { 230, 210, 80 }
  rectc(c, 6, 2, 9, 9, darken(metal, 0.5)); rectc(c, 7, 3, 8, 8, metal)
  rectc(c, 9, 9, 13, 12, darken(metal, 0.5)); rectc(c, 9, 10, 12, 11, metal)
  rectc(c, 3, 9, 7, 12, darken(metal, 0.5)); rectc(c, 4, 10, 6, 11, metal)
  lineC(c, 8, 6, 11, 9, arrow); lineC(c, 8, 6, 5, 9, arrow)
  ICON.defineCanvas("mach:sorter", c)
end
do -- machine: splitter (single input, two output lanes)
  local c = newCanvas()
  local metal, arrow = { 110, 110, 120 }, { 230, 210, 80 }
  rectc(c, 7, 2, 8, 7, darken(metal, 0.5)); rectc(c, 7, 3, 8, 6, metal)
  rectc(c, 3, 9, 7, 12, darken(metal, 0.5)); rectc(c, 4, 10, 6, 11, metal)
  rectc(c, 9, 9, 13, 12, darken(metal, 0.5)); rectc(c, 10, 10, 12, 11, metal)
  lineC(c, 7, 7, 5, 9, arrow); lineC(c, 8, 7, 10, 9, arrow)
  ICON.defineCanvas("mach:splitter", c)
end
do -- machine: proximity gate (lintel + alternating bars)
  local c = newCanvas()
  local metal = { 100, 100, 110 }
  rectc(c, 2, 2, 13, 3, darken(metal, 0.5))
  for x = 3, 12, 2 do rectc(c, x, 4, x, 13, darken(metal, 0.4)) end
  for x = 4, 12, 2 do rectc(c, x, 4, x, 13, metal) end
  setc(c, 4, 5, lighten(metal, 0.5))
  ICON.defineCanvas("mach:gate", c)
end
do -- machine: security camera (housing + lens)
  local c = newCanvas()
  local body, lens = { 70, 70, 80 }, { 40, 180, 220 }
  rectc(c, 3, 5, 12, 9, darken(body, 0.5)); rectc(c, 4, 6, 11, 8, body)
  drawBlobOutlined(c, 11, 7, 2, 2, lens)
  rectc(c, 7, 9, 9, 12, darken(body, 0.4))
  ICON.defineCanvas("mach:camera", c)
end
do -- machine: breaker (switch box + lever)
  local c = newCanvas()
  local body, lever = { 90, 90, 100 }, { 230, 90, 60 }
  rectc(c, 4, 4, 11, 13, darken(body, 0.5)); rectc(c, 5, 5, 10, 12, body)
  thickLine(c, 7, 10, 9, 5, darken(lever, 0.5), 3); thickLine(c, 7, 10, 9, 5, lever, 2)
  ICON.defineCanvas("mach:breaker", c)
end
do -- machine: sprinkler (riser pipe + spray fan)
  local c = newCanvas()
  local metal, water = { 110, 110, 120 }, { 90, 150, 230 }
  rectc(c, 7, 7, 9, 14, darken(metal, 0.5)); rectc(c, 7, 7, 8, 13, metal)
  for _, p in ipairs({ { 4, 4 }, { 6, 2 }, { 9, 2 }, { 12, 4 }, { 3, 7 }, { 13, 7 } }) do setc(c, p[1], p[2], water) end
  ICON.defineCanvas("mach:sprinkler", c)
end

-- Direct exports so other lanes can wire these in without re-deriving indices/heuristics --
-- order matches R.PICKS/R.SWORDS exactly (verified against rpg.lua:2404-2405, 2026-09-01).
ICON.PICK_ICON = { "tool:pick:wood", "tool:pick:stone", "tool:pick:iron", "tool:pick:steel", "tool:pick:diamond" }
ICON.SWORD_ICON = { "tool:sword:wood", "tool:sword:iron", "tool:sword:steel" }
ICON.STATION_ICON = { workbench = "station:workbench", furnace = "station:furnace", anvil = "station:anvil", research = "station:research", advlab = "station:advlab", crate = "station:crate" }
ICON.TOOL_ICON = { axe = "tool:axe", torch = "tool:torch", bucket = "tool:bucket" }

-- INFERRED best-effort code->icon mapping for R.icon.resolve()'s first tier. BSLT/BRCK/GRNT/STNE
-- are the plausible values of rpg.lua's local ROCK (BSLT-or-BRCK, rpg.lua:1382) plus the granite
-- ore item itself -- not all of these are guaranteed to be real elements in every session, which
-- is exactly why resolve() falls through to the procedural path when a mapped id has no def.
ICON.ELEMENT_ICON = {
  WOOD = "mat:wood", BSLT = "mat:stone", BRCK = "mat:stone", GRNT = "mat:stone", STNE = "mat:stone",
  IRON = "mat:iron_ore", COAL = "mat:coal", GOLD = "mat:gold_ore", CU = "mat:copper",
  STEL = "mat:steel", METL = "mat:iron_bar", DMND = "mat:diamond", WATR = "liquid:water",
  GOO = "mat:dirt", SAND = "mat:sand",
  -- @iconart pass, 2026-09-02 -- foraged food, held weapons and machine kits have NO backing TPT
  -- element (R.eid(code) returns nil for every one of these, verified against survival.lua's/
  -- machines.lua's own R.give()/recipe `out` strings), so without an explicit mapping here they
  -- fell through to the worst fallback tier (hashed-colour chunk, no real shape at all).
  WHEAT = "food:wheat", BERRY = "food:berry", ROOT = "food:root", FISH = "food:fish",
  MSHRM = "food:mushroom", CFISH = "food:cfish", CMSHRM = "food:cmshrm", STEW = "food:stew",
  BOILEDWATER = "food:boiledwater", CLEANWATER = "food:cleanwater", DIRTYWATER = "food:dirtywater",
  MUSKET = "wpn:musket", SHOTGUN = "wpn:shotgun", BOW = "wpn:bow", BOOMERANG = "wpn:boomerang",
  BOILER = "mach:boiler", TURBINE = "mach:turbine", CRANKKIT = "mach:crank", WHEELKIT = "mach:wheel",
  PUMPKIT = "mach:pump", DOORKIT = "mach:door", CONVEYOR = "mach:conveyor", WIRECOIL = "mach:wirecoil",
  LAMPKIT = "mach:lamp", SOLARKIT = "mach:solar", BATTERYKIT = "mach:battery",
  GASDETECTORKIT = "mach:gasdetector", SORTERKIT = "mach:sorter", SPLITTERKIT = "mach:splitter",
  GATEKIT = "mach:gate", CAMERAKIT = "mach:camera", BREAKERKIT = "mach:breaker",
  SPRINKLERKIT = "mach:sprinkler",
}

-- Warm the small/large caches for every hand-authored icon right now, at load time, so the very
-- first frame anything draws one costs nothing extra.
ICON.warm(ICON.list(), { ICON.SIZE_SMALL, ICON.SIZE_LARGE })

-- ================================================================ benchmark
-- Real numbers, not a guess: draws every hand-authored icon `reps` times (cache already warm, so
-- this measures the steady-state fillRect-call cost, not compile cost) and reports per-icon and
-- per-10-icon (hotbar-sized row) milliseconds.
function ICON.benchmark()
  local ids = ICON.list()
  if #ids == 0 then return { perIconMs = 0, hotbarMs = 0, n = 0, reps = 0 } end
  ICON.warm(ids, { ICON.SIZE_SMALL })
  local reps = 200
  local t0 = os.clock()
  for _ = 1, reps do for _, id in ipairs(ids) do ICON.draw(id, -100, -100, ICON.SIZE_SMALL) end end
  local totalMs = (os.clock() - t0) * 1000
  local perIconMs = totalMs / (reps * #ids)
  return { perIconMs = perIconMs, hotbarMs = perIconMs * 10, n = #ids, reps = reps, totalMs = totalMs }
end

-- ================================================================ self-test contact sheet
-- No render-to-texture exists in this engine (see the header comment) -- "offscreen" here means a
-- full-canvas debug overlay drawn ONLY while ICON.debugSheet is true (toggled by ICON.selfTest(),
-- opt-in, off by default, never drawn during normal play). One frame of this while true covers the
-- whole screen -- exactly the point, a contact sheet is meant to be looked at, not glimpsed behind
-- gameplay -- so it must only ever be turned on deliberately (a lab instance, or a moment Drew asks
-- for) and turned back off immediately after the screenshot is taken.
local SHOWCASE_ELEMENTS = { "IRON", "GOLD", "CU", "COAL", "DMND", "STEL", "WOOD", "WATR", "LAVA", "OIL", "GAS", "PLSM", "METL", "SAND", "ICE" }
local function contactSheetEntries()
  local out = {}
  for _, id in ipairs(ICON.list()) do out[#out + 1] = { label = id, id = id } end
  for _, code in ipairs(SHOWCASE_ELEMENTS) do
    local ok, rid = pcall(ICON.resolve, code)
    if ok and rid then out[#out + 1] = { label = "auto:" .. code, id = rid } end
  end
  local ok, rid = pcall(ICON.resolve, "unmapped_concept_xyz")
  if ok then out[#out + 1] = { label = "auto:unknown", id = rid } end
  return out
end

function ICON.selfTest()
  ICON.debugSheet = not ICON.debugSheet
  return ICON.debugSheet
end

hook(R.hooks.drawHUD, function()
  if not ICON.debugSheet then return end
  local W, H = R.W or 612, R.H or 384
  graphics.fillRect(0, 0, W, H, 8, 8, 14, 255)
  local entries = contactSheetEntries()
  local cols, cellW, cellH, iconSize = 10, 58, 46, 32
  local ox, oy = 6, 6
  for i, e in ipairs(entries) do
    local col = (i - 1) % cols
    local row = floor((i - 1) / cols)
    local x, y = ox + col * cellW, oy + row * cellH
    graphics.drawRect(x, y, iconSize + 4, iconSize + 4, 60, 64, 80, 255)
    ICON.draw(e.id, x + 2, y + 2, iconSize)
    graphics.drawText(x, y + iconSize + 6, e.label:sub(1, 10), 200, 210, 220, 255)
  end
  graphics.drawText(6, H - 12, string.format("ICON CONTACT SHEET -- %d icons -- R.icon.selfTest() to close", #entries), 255, 220, 140, 255)
end)

-- ================================================================ version/changelog
-- From THIS file only, same monotonic pattern netlink.lua already established (rpg.lua owns
-- R.VERSION/R.CHANGELOG's FILE this wave -- @survival's lane -- so this raises the shared runtime
-- table rather than editing rpg.lua; only ever raises the version, matches the existing dedupe).
do
  local function vnum(v)
    local a, b, c = tostring(v or "0"):match("(%d+)%.(%d+)%.(%d+)")
    if not a then return -1 end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
  end
  local ENTRIES = {
    { ver = "1.17.1", note = "Icons: new procedural icon system -- every material and machine can "
      .. "now draw a real distinctive icon instead of a flat colour swatch (ore gets speckle, liquid "
      .. "gets a meniscus, gas gets scatter, powder gets granules, metal gets a shine), plus ~30 "
      .. "hand-drawn icons for the picks, swords, stations, core materials, water, food and torch. "
      .. "Not wired into any screen yet in this pass -- see the contact-sheet self-test." },
    -- @iconart, 2026-09-02: the game is public now, so "most icons are still procedural" is a
    -- stranger's first impression, not a backlog item. Four lines, one per discrete change (see
    -- shipping-and-release skill): more hand-drawn icons, a quality pass on the fallback, plus the
    -- two things that made both possible without a new visual bug slipping through blind.
    { ver = "1.17.4", note = "Icons: 31 more hand-drawn icons for things every new player sees in "
      .. "the first hour -- foraged food (wheat, berries, root, fish, mushroom, cooked versions, "
      .. "stew, water), the first weapons (musket, shotgun, bow, boomerang), and early machines "
      .. "(boiler, turbine, crank, water wheel, pump, powered door, conveyor, wire coil, lamp, "
      .. "solar panel, battery, gas detector, sorter, splitter, gate, camera, breaker, sprinkler)." },
    { ver = "1.17.4", note = "Icons: the procedural fallback (everything still without hand-drawn "
      .. "art) now has subtle grain texture on solids and a shifted meniscus highlight on liquids, "
      .. "so the long tail reads less like a flat bevel and two similar-coloured materials look "
      .. "less identical to each other." },
    { ver = "1.17.4", note = "Icons: captured a fresh full contact sheet of every icon (hand-drawn "
      .. "and procedural) for review -- nothing shipped blind, per the standing lesson from the "
      .. "dotted-effect revert." },
  }
  for _, entry in ipairs(ENTRIES) do
    local NEW_VERSION, NOTE = entry.ver, entry.note
    if vnum(NEW_VERSION) > vnum(R.VERSION) then R.VERSION = NEW_VERSION end
    R.CHANGELOG = R.CHANGELOG or {}
    local dupe = false
    for _, e in ipairs(R.CHANGELOG) do
      local s = type(e) == "table" and tostring(e.ver or "") or tostring(e)
      if s == NOTE then dupe = true break end
    end
    if not dupe then
      local at = #R.CHANGELOG + 1
      for i, e in ipairs(R.CHANGELOG) do
        local s = type(e) == "table" and tostring(e.ver or "") or tostring(e)
        if vnum(s) <= vnum(NEW_VERSION) then at = i break end
      end
      table.insert(R.CHANGELOG, at, NOTE)
    end
  end
end

if R.tlog then R.tlog("info", "icons", "icons plugin loaded", { defined = #ICON.list() }) end
return true
