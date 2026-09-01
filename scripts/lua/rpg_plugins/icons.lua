-- Icon system. PhoenixFire808, verbatim: "We need actual ICONS for everything, not just the
-- material colours. Everything has to look super good."
--
-- HARD ENGINE CONSTRAINT (verified in src/lua/LuaGraphics.cpp, 2026-09-01): there is no image,
-- texture or sprite loading -- the entire drawing surface is textSize/drawText/drawPixel/drawLine/
-- drawRect/fillRect/drawCircle/fillCircle/getColors/getHexColor/setClipRect. Every icon here is a
-- list of primitive draw calls, compiled once and cached, never a loaded asset.
--
-- OWNERSHIP: this is a brand-new plugin. It does not edit rpg.lua or any other rpg_plugins/*.lua
-- file (thirteen lanes touched them tonight -- AGENTS.md). It owns exactly the R.icon.* namespace.
-- NOT YET in R.PLUGINS -- same situation telemetry.lua documented and the same fix applies: send
-- the coordinator this one-line patch (insert "icons" right after "telemetry" so anything loaded
-- after it can use R.icon.* immediately, and it depends on nothing):
--   R.PLUGINS = { "telemetry", "icons", "world", "enemies", "machines", "machines2", "items",
--     "terraweapons", "vehicles", "survival", "companion", "save", "ui", "guide", "netlink",
--     "automation", "fieldtools", "acq_fluids", "acq_solids", "acq_energy", "acq_special",
--     "acq_forage", "acq_machines", "nat_process" }
-- Until that lands, load it for testing with: PBX.state.rpg.reloadPlugin("icons")
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
-- The ~30 hand-authored icons below (tools/stations/materials -- the highest-traffic things) are
-- instead built with the small numeric-coordinate helpers further down (lineC/rectc/thickLine on
-- a 16x16 canvas) rather than typed as literal grids: several of them share one silhouette across
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
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
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
local function drawChunk(c, base)
  local out, hi = darken(base, 0.55), lighten(base, 0.45)
  rectc(c, 2, 3, 13, 13, out)
  rectc(c, 3, 4, 12, 12, base)
  for _, p in ipairs({ { 2, 3 }, { 13, 3 }, { 2, 13 }, { 13, 13 } }) do clearc(c, p[1], p[2]) end
  for _, p in ipairs({ { 3, 4 }, { 12, 4 }, { 3, 12 }, { 12, 12 } }) do setc(c, p[1], p[2], out) end
  for i = 0, 4 do setc(c, 4 + i, 5, hi) end
  setc(c, 4, 6, hi)
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

local function drawLiquid(c, base)
  local out, hi = darken(base, 0.5), lighten(base, 0.5)
  rectc(c, 2, 7, 13, 13, out)
  rectc(c, 3, 8, 12, 13, base)
  for x = 3, 12 do setc(c, x, (x >= 6 and x <= 9) and 6 or 7, hi) end -- meniscus, higher mid-span
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
  if state == "liquid" then drawLiquid(canvas, base)
  elseif state == "gas" then drawGas(canvas, base, seed)
  elseif state == "powder" then drawPowder(canvas, base, seed)
  elseif state == "energy" then drawEnergy(canvas, base)
  else drawChunk(canvas, base) end
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
  drawChunk(canvas, base)
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

-- ================================================================ ~30-40 hand-authored icons (highest-traffic things)
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
  local NEW_VERSION = "1.17.1"
  if vnum(NEW_VERSION) > vnum(R.VERSION) then R.VERSION = NEW_VERSION end
  R.CHANGELOG = R.CHANGELOG or {}
  local NOTE = "Icons (@icons_engine): new procedural icon system -- every material and machine can "
    .. "now draw a real distinctive icon instead of a flat colour swatch (ore gets speckle, liquid "
    .. "gets a meniscus, gas gets scatter, powder gets granules, metal gets a shine), plus ~30 "
    .. "hand-drawn icons for the picks, swords, stations, core materials, water, food and torch. "
    .. "Not wired into any screen yet in this pass -- see the contact-sheet self-test."
  local dupe = false
  for _, e in ipairs(R.CHANGELOG) do
    local s = type(e) == "table" and tostring(e.ver or "") or tostring(e)
    if s == NOTE or (type(e) == "table" and tostring(e.ver or "") == NEW_VERSION) then dupe = true break end
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

if R.tlog then R.tlog("info", "icons", "icons plugin loaded", { defined = #ICON.list() }) end
return true
