-- POWDER RPG plugin: save.lua - full world + player persistence (2026-08-26)
-- Overrides R.save (K key + menu already call it) and adds R.load(path, confirmed).
-- File format: hand-rolled compact JSON at knowledge/rpg-save.json.
--   World tiles are stored per 64px tile as run-length-encoded rows of particle type ids
--   (air = 0) over the tile's seen rect, plus a sparse "ex" list of {relx,rely,temp,ctype,tmp,life}
--   for cells whose temp is >2K from the element's default or whose ctype/tmp/life is nonzero.
-- Extensibility: any other plugin that wants its state (e.g. R.machines) persisted should push the
-- field name onto R.PLUGIN_SAVE_KEYS (created here if absent); save.lua will generically dump/restore
-- R[<key>] verbatim as plain JSON on every save/load. Keep such state to plain numbers/strings/tables -
-- avoid raw particle ids, since those are invalidated by a load's sim.clearSim().
local R = PBX.state.rpg
local TAG = "save"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}

local floor = math.floor
local TS = 64
local SAVE_PATH = "../knowledge/rpg-save.json"
local BACKUP_N = 3
local AUTOSAVE_INTERVAL = 18000   -- ~5 min at 60fps (a day is 14000 frames per rpg.lua)

local function pkey(wx, wy) return (wx + 1000000) * 4096 + wy end
local function tkey(wx, wy) return floor(wx / TS) * 100000 + floor(wy / TS) + 50000 end

-- ================================================================ default temp per element (cached)
local defTempCache = {}
local function defaultTemp(t)
  local v = defTempCache[t]
  if v ~= nil then return v end
  local ok, tv = pcall(elem.property, t, "Temperature")
  v = (ok and type(tv) == "number") and tv or 295.15
  defTempCache[t] = v
  return v
end

-- ================================================================ minimal JSON encode (controlled data)
local function jsonStr(s)
  s = tostring(s)
  s = s:gsub('[%c\\"]', function(c)
    if c == '\\' then return '\\\\' elseif c == '"' then return '\\"'
    elseif c == '\n' then return '\\n' elseif c == '\r' then return '\\r' elseif c == '\t' then return '\\t'
    else return string.format('\\u%04x', string.byte(c)) end
  end)
  return '"' .. s .. '"'
end
local function isArray(t)
  local n = 0; for _ in pairs(t) do n = n + 1 end
  local c = 0; for i = 1, n do if t[i] ~= nil then c = c + 1 end end
  return c == n, n
end
local encodeValue
encodeValue = function(buf, v)
  local tv = type(v)
  if v == nil then buf[#buf + 1] = "null"
  elseif tv == "boolean" then buf[#buf + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then buf[#buf + 1] = "0"
    elseif v == floor(v) and v < 1e15 and v > -1e15 then buf[#buf + 1] = string.format("%d", v)
    else buf[#buf + 1] = string.format("%.6g", v) end
  elseif tv == "string" then buf[#buf + 1] = jsonStr(v)
  elseif tv == "table" then
    local arr, n = isArray(v)
    if arr then
      buf[#buf + 1] = "["
      for i = 1, n do if i > 1 then buf[#buf + 1] = "," end; encodeValue(buf, v[i]) end
      buf[#buf + 1] = "]"
    else
      buf[#buf + 1] = "{"
      local first = true
      for k, vv in pairs(v) do
        if not first then buf[#buf + 1] = "," end; first = false
        buf[#buf + 1] = jsonStr(tostring(k)); buf[#buf + 1] = ":"; encodeValue(buf, vv)
      end
      buf[#buf + 1] = "}"
    end
  else buf[#buf + 1] = "null" end
end

-- chunked writer: accumulate into a table, flush with table.concat periodically (avoids O(n^2) string concat
-- and keeps peak memory bounded for a well-explored world)
local function newWriter(path)
  local f = io.open(path, "w"); if not f then return nil end
  local buf = {}
  local function flush() if #buf > 0 then f:write(table.concat(buf)); buf = {} end end
  local function raw(s) buf[#buf + 1] = s; if #buf > 4000 then flush() end end
  local function val(v) encodeValue(buf, v); if #buf > 4000 then flush() end end
  local function close() flush(); f:close() end
  return { raw = raw, val = val, close = close }
end

-- ================================================================ minimal JSON decode (matches our own encoder)
local function newJsonParser(s)
  local i, n = 1, #s
  local function skipWS() while i <= n do local c = s:sub(i, i); if c == ' ' or c == '\n' or c == '\r' or c == '\t' then i = i + 1 else break end end end
  local parseValue
  local function parseString()
    i = i + 1; local buf = {}
    while true do
      local c = s:sub(i, i)
      if c == '"' then i = i + 1; break end
      if c == '\\' then
        local nc = s:sub(i + 1, i + 1)
        if nc == 'n' then buf[#buf + 1] = '\n' elseif nc == 'r' then buf[#buf + 1] = '\r' elseif nc == 't' then buf[#buf + 1] = '\t'
        elseif nc == 'u' then buf[#buf + 1] = ""; i = i + 4  -- \uXXXX: skip (not produced for our data other than control chars, drop safely)
        else buf[#buf + 1] = nc end
        i = i + 2
      else buf[#buf + 1] = c; i = i + 1 end
    end
    return table.concat(buf)
  end
  local function parseNumber()
    local j = i
    while i <= n do local c = s:sub(i, i); if c:match('[%d%.%-%+eE]') then i = i + 1 else break end end
    return tonumber(s:sub(j, i - 1))
  end
  local function parseArray()
    i = i + 1; skipWS(); local t = {}
    if s:sub(i, i) == ']' then i = i + 1; return t end
    while true do
      skipWS(); t[#t + 1] = parseValue(); skipWS()
      local c = s:sub(i, i)
      if c == ',' then i = i + 1 elseif c == ']' then i = i + 1; break else error("bad array at " .. i) end
    end
    return t
  end
  local function parseObject()
    i = i + 1; skipWS(); local t = {}
    if s:sub(i, i) == '}' then i = i + 1; return t end
    while true do
      skipWS(); local k = parseString(); skipWS()
      if s:sub(i, i) ~= ':' then error("expected : at " .. i) end
      i = i + 1; skipWS(); t[k] = parseValue(); skipWS()
      local c = s:sub(i, i)
      if c == ',' then i = i + 1 elseif c == '}' then i = i + 1; break else error("bad object at " .. i) end
    end
    return t
  end
  parseValue = function()
    skipWS(); local c = s:sub(i, i)
    if c == '{' then return parseObject()
    elseif c == '[' then return parseArray()
    elseif c == '"' then return parseString()
    elseif c == 't' then i = i + 4; return true
    elseif c == 'f' then i = i + 5; return false
    elseif c == 'n' then i = i + 4; return nil
    else return parseNumber() end
  end
  return { parse = function() skipWS(); return parseValue() end }
end

-- ================================================================ world tile <-> RLE
-- row format: "type,count|type,count|...", indices relative to (sx1,sy1). exceptions: {relx,rely,temp,ctype,tmp,life}
local function writeTile(w, t)
  w.raw('{"tx":'); w.raw(string.format("%d", t.tx)); w.raw(',"ty":'); w.raw(string.format("%d", t.ty))
  local sx1, sy1, sx2, sy2 = t.sx1, t.sy1, t.sx2, t.sy2
  if not sx1 then w.raw('}'); return end
  w.raw(',"sx1":'); w.raw(string.format("%d", sx1)); w.raw(',"sy1":'); w.raw(string.format("%d", sy1))
  w.raw(',"sx2":'); w.raw(string.format("%d", sx2)); w.raw(',"sy2":'); w.raw(string.format("%d", sy2))
  w.raw(',"rle":[')
  local exBuf = {}
  for wy = sy1, sy2 do
    if wy > sy1 then w.raw(',') end
    w.raw('"')
    local runType, runLen = 0, 0
    local rely = wy - sy1
    for wx = sx1, sx2 do
      local rec = t.recs[pkey(wx, wy)]
      local ty = rec and rec[1] or 0
      if rec then
        local dt = rec[2] - defaultTemp(rec[1])
        if dt > 2 or dt < -2 or rec[3] ~= 0 or rec[4] ~= 0 or rec[5] ~= 0 then
          exBuf[#exBuf + 1] = { wx - sx1, rely, rec[2], rec[3], rec[4], rec[5] }
        end
      end
      if ty == runType then runLen = runLen + 1
      else
        if runLen > 0 then w.raw(string.format("%d,%d|", runType, runLen)) end
        runType = ty; runLen = 1
      end
    end
    if runLen > 0 then w.raw(string.format("%d,%d|", runType, runLen)) end
    w.raw('"')
  end
  w.raw('],"ex":[')
  for i, e in ipairs(exBuf) do
    if i > 1 then w.raw(',') end
    w.raw(string.format("[%d,%d,%.2f,%d,%d,%d]", e[1], e[2], e[3], e[4], e[5], e[6]))
  end
  w.raw(']}')
end
local function decodeRow(rowStr, count)
  local types = {}; local idx = 1
  for token in rowStr:gmatch("[^|]+") do
    local tstr, cstr = token:match("^(%-?%d+),(%d+)$")
    local ty, cnt = tonumber(tstr), tonumber(cstr)
    if ty and cnt then for _ = 1, cnt do types[idx] = ty; idx = idx + 1 end end
  end
  return types
end
local function buildTileFromData(td)
  local sx1, sy1, sx2, sy2 = td.sx1, td.sy1, td.sx2, td.sy2
  local recs, n = {}, 0
  if sx1 then
    local width = sx2 - sx1 + 1
    for rely = 0, (sy2 - sy1) do
      local wy = sy1 + rely
      local types = decodeRow(td.rle and td.rle[rely + 1] or "", width)
      for relx = 0, width - 1 do
        local ty = types[relx + 1] or 0
        if ty ~= 0 then recs[pkey(sx1 + relx, wy)] = { ty, defaultTemp(ty), 0, 0, 0 }; n = n + 1 end
      end
    end
    for _, e in ipairs(td.ex or {}) do
      local wx, wy = sx1 + e[1], sy1 + e[2]
      local rec = recs[pkey(wx, wy)]
      if rec then rec[2], rec[3], rec[4], rec[5] = e[3], e[4], e[5], e[6] end
    end
  end
  return { tx = td.tx, ty = td.ty, sx1 = sx1, sy1 = sy1, sx2 = sx2, sy2 = sy2, recs = recs, n = n }
end

-- ================================================================ fillRegion / markSeen re-implementation
-- (the versions in rpg.lua are local to that file; these are functionally identical copies operating on R.tiles/R.cam)
local function fillFromTiles(x1, y1, x2, y2)
  local cx, cy = R.cam.x, R.cam.y
  for y = y1, y2 do local wy = y + cy
    for x = x1, x2 do local wx = x + cx
      local t = R.tiles[tkey(wx, wy)]
      if t and t.sx1 and wx >= t.sx1 and wx <= t.sx2 and wy >= t.sy1 and wy <= t.sy2 then
        local k = pkey(wx, wy); local r = t.recs[k]
        if r then
          local p = sim.partCreate(-1, x, y, r[1])
          if p and p >= 0 then
            sim.partProperty(p, "temp", r[2])
            if r[3] ~= 0 then sim.partProperty(p, "ctype", r[3]) end
            if r[4] ~= 0 then sim.partProperty(p, "tmp", r[4]) end
            if r[5] ~= 0 then sim.partProperty(p, "life", r[5]) end
          end
          t.recs[k] = nil; t.n = (t.n or 1) - 1
        end
      else
        local el = R.gen(wx, wy); if el then local e = R.eid(el); if e then sim.partCreate(-1, x, y, e) end end
      end
    end
  end
end
local function markSeenRegion(wx1, wy1, wx2, wy2)
  for ty = floor(wy1 / TS), floor(wy2 / TS) do for tx = floor(wx1 / TS), floor(wx2 / TS) do
    local key = tkey(tx * TS, ty * TS)
    local t = R.tiles[key]; if not t then t = { recs = {}, n = 0, tx = tx, ty = ty }; R.tiles[key] = t end
    local x1, y1, x2, y2 = math.max(wx1, tx * TS), math.max(wy1, ty * TS), math.min(wx2, tx * TS + TS - 1), math.min(wy2, ty * TS + TS - 1)
    if not t.sx1 then t.sx1, t.sy1, t.sx2, t.sy2 = x1, y1, x2, y2
    else t.sx1 = math.min(t.sx1, x1); t.sy1 = math.min(t.sy1, y1); t.sx2 = math.max(t.sx2, x2); t.sy2 = math.max(t.sy2, y2) end
  end end
end

-- ================================================================ save
-- copy-on-write snapshot of R.tiles merged with everything currently on screen (which R.tiles does not
-- hold yet - it only stores particles that have scrolled off-canvas). Never mutates the live R.tiles/sim.
local function buildSnapshot()
  local snap = {}
  for k, t in pairs(R.tiles) do snap[k] = { tx = t.tx, ty = t.ty, sx1 = t.sx1, sy1 = t.sy1, sx2 = t.sx2, sy2 = t.sy2, recs = t.recs, shared = true } end
  local cx, cy = R.cam.x, R.cam.y
  for i in sim.parts() do
    local x, y = sim.partPosition(i)
    local wx, wy = floor(x + 0.5) + cx, floor(y + 0.5) + cy
    local k = tkey(wx, wy)
    local s = snap[k]
    if not s then
      local tx, ty = floor(wx / TS), floor(wy / TS)
      s = { tx = tx, ty = ty, sx1 = tx * TS, sy1 = ty * TS, sx2 = tx * TS + TS - 1, sy2 = ty * TS + TS - 1, recs = {} }
      snap[k] = s
    elseif s.shared then
      local copy = {}; for rk, rv in pairs(s.recs) do copy[rk] = rv end
      s.recs = copy; s.shared = nil
    end
    if not s.sx1 then s.sx1, s.sy1, s.sx2, s.sy2 = wx, wy, wx, wy
    else
      if wx < s.sx1 then s.sx1 = wx end; if wy < s.sy1 then s.sy1 = wy end
      if wx > s.sx2 then s.sx2 = wx end; if wy > s.sy2 then s.sy2 = wy end
    end
    local pt = sim.partProperty(i, "type")
    s.recs[pkey(wx, wy)] = { pt, sim.partProperty(i, "temp") or defaultTemp(pt), sim.partProperty(i, "ctype") or 0, sim.partProperty(i, "tmp") or 0, sim.partProperty(i, "life") or 0 }
  end
  return snap
end
local function rotateBackups()
  local f = io.open(SAVE_PATH, "r"); if not f then return end; f:close()
  for j = BACKUP_N, 2, -1 do pcall(os.remove, SAVE_PATH .. ".bak" .. j); pcall(os.rename, SAVE_PATH .. ".bak" .. (j - 1), SAVE_PATH .. ".bak" .. j) end
  pcall(os.remove, SAVE_PATH .. ".bak1"); pcall(os.rename, SAVE_PATH, SAVE_PATH .. ".bak1")
end
local function doSave(auto)
  local t0 = os.clock()
  rotateBackups()
  local w = newWriter(SAVE_PATH); if not w then R.say("save failed: could not open file"); return false end
  w.raw('{"version":1,')
  w.raw('"seed":' .. string.format("%d", R.seed or 0) .. ',')
  w.raw('"frame":' .. string.format("%d", R.frame or 0) .. ',')
  w.raw('"day":' .. string.format("%d", R.day or 1) .. ',')
  w.raw('"deaths":' .. string.format("%d", R.deaths or 0) .. ',')
  w.raw('"hp":' .. string.format("%.2f", R.hp or 100) .. ',')
  w.raw('"breath":' .. string.format("%.2f", R.breath or 300) .. ',')
  w.raw('"px":' .. string.format("%.3f", R.P.x) .. ',"py":' .. string.format("%.3f", R.P.y) .. ',')
  w.raw('"pvx":' .. string.format("%.3f", R.P.vx or 0) .. ',"pvy":' .. string.format("%.3f", R.P.vy or 0) .. ',')
  w.raw('"face":' .. string.format("%d", R.P.face or 1) .. ',')
  w.raw('"camx":' .. string.format("%d", R.cam.x) .. ',"camy":' .. string.format("%d", R.cam.y) .. ',')
  w.raw('"sel":' .. string.format("%d", R.sel or 1) .. ',')
  w.raw('"brush":' .. string.format("%d", R.brush or 1) .. ',')
  w.raw('"grid":' .. (R.grid and "true" or "false") .. ',')
  w.raw('"smart":' .. ((R.smart == false) and "false" or "true") .. ',')
  local hb = {}; for s6 = 1, 10 do hb[s6] = (R.hotbar and R.hotbar[s6]) or "" end
  w.raw('"hotbar":'); w.val(hb); w.raw(',')
  w.raw('"inventory":'); w.val(R.inventory or {}); w.raw(',')
  w.raw('"tools":'); w.val(R.TOOLS or {}); w.raw(',')
  w.raw('"acc":'); w.val(R.acc or {}); w.raw(',')
  w.raw('"accOwned":'); w.val(R.accOwned or {}); w.raw(',')
  w.raw('"accOff":'); w.val(R.accOff or {}); w.raw(',')
  w.raw('"stats":'); w.val(R.stats or {}); w.raw(',')
  w.raw('"quest":' .. string.format("%d", R.quest or 1) .. ',')
  w.raw('"stations":'); w.val(R.stations or {}); w.raw(',')
  w.raw('"torches":'); w.val(R.torches or {}); w.raw(',')
  local openedChests = {}
  for k, c in pairs(R.chests or {}) do if c and c.opened then openedChests[#openedChests + 1] = { key = k, x = c.x, y = c.y, item = c.item, opened = true } end end
  w.raw('"chests":'); w.val(openedChests); w.raw(',')
  w.raw('"weather":'); w.val(R.weather or {}); w.raw(',')
  local plugins = {}
  for _, key in ipairs(R.PLUGIN_SAVE_KEYS) do if R[key] ~= nil then plugins[key] = R[key] end end
  w.raw('"plugins":'); w.val(plugins); w.raw(',')
  w.raw('"tiles":[')
  local n, first = 0, true
  local snap = buildSnapshot()
  for _, t in pairs(snap) do
    if not first then w.raw(',') end; first = false
    writeTile(w, t); n = n + 1
  end
  w.raw('],"tileCount":' .. string.format("%d", n) .. '}')
  w.close()
  R.lastAutosave = R.frame
  local dt = (os.clock() - t0) * 1000
  R.say(string.format("%s (%d tiles, %.0fms)", auto and "Autosaved" or "Saved", n, dt))
  return true
end
function R.save(auto)
  local ok, err = pcall(doSave, auto)
  if not ok then R.say("Save failed: " .. tostring(err)); R.pluginErr = tostring(err); return false end
  return true
end

-- ================================================================ load
-- confirmed must be truthy to actually clear the sim and restore over the live game; this is only ever
-- passed by `python scripts/rpg.py load`. Without it, this only parses the file and returns the data table
-- (safe dry-run, used for testing/inspection - never touches R.tiles/sim/player).
local function doLoad(path, confirmed)
  path = path or SAVE_PATH
  local f = io.open(path, "r"); if not f then return false, "file not found: " .. path end
  local content = f:read("*a"); f:close()
  local ok, data = pcall(function() return newJsonParser(content).parse() end)
  if not ok or type(data) ~= "table" then return false, "parse error: " .. tostring(data) end
  if not confirmed then return true, data end

  local newTiles = {}
  for _, td in ipairs(data.tiles or {}) do newTiles[tkey(td.tx * TS, td.ty * TS)] = buildTileFromData(td) end

  sim.clearSim()   -- only reached with confirmed==true, i.e. via `rpg.py load`
  R.tiles = newTiles
  R.seed = data.seed or R.seed
  R.frame = data.frame or 0
  -- cooldowns are frame timestamps (R.lastMine, lastPlace, lastSwing, lastHitAt, hurt, shake, swingAt);
  -- a restored R.frame lower than a stale one leaves tools acting on cooldown forever, so clear them all here
  R.lastMine, R.lastPlace, R.lastSwing, R.lastHitAt, R.hurt, R.shake, R.swingAt = nil, nil, nil, nil, nil, nil, nil
  R.day = data.day or 1
  R.deaths = data.deaths or 0
  R.hp = data.hp or 100
  R.breath = data.breath or 300
  R.P.x, R.P.y = data.px or 0, data.py or 0
  R.P.vx, R.P.vy = data.pvx or 0, data.pvy or 0
  R.P.face = data.face or 1
  R.P.onGround, R.P.coyote, R.P.hook, R.P.jumpHeld, R.P.dj, R.P.fuel = false, 0, nil, false, false, 45
  R.cam.x, R.cam.y = data.camx or 0, data.camy or 0
  R.sel = data.sel or 1
  R.brush = data.brush
  R.grid = data.grid
  R.smart = data.smart
  local hb = {}
  for s6 = 1, 10 do local v = (data.hotbar or {})[s6]; if v and v ~= "" then hb[s6] = v end end
  R.hotbar = hb
  R.inventory = data.inventory or {}
  if data.tools then for k, v in pairs(data.tools) do R.TOOLS[k] = v end end
  R.acc = data.acc or {}
  if data.accOwned then
    R.accOwned = data.accOwned
  else
    R.accOwned = {}; for k in pairs(R.acc) do R.accOwned[k] = true end
  end
  R.accOff = data.accOff or {}
  R.stats = data.stats or { mined = {}, crafted = {}, chests = 0, maxDepth = 0 }
  R.quest = data.quest or 1
  R.stations = data.stations or {}
  R.torches = data.torches or {}
  R.chests = {}
  for _, c in ipairs(data.chests or {}) do R.chests[c.key] = { x = c.x, y = c.y, item = c.item, opened = true } end
  R.weather = data.weather or { rain = false, next = 3000 }
  if data.plugins then
    for k, v in pairs(data.plugins) do
      if k == "COMP" and type(v) == "table" and type(R.COMP) == "table" then
        for fk, fv in pairs(v) do R.COMP[fk] = fv end
      else
        R[k] = v
      end
    end
  end
  if R._applyCompanionDefaults then pcall(R._applyCompanionDefaults) end
  R.blockHits, R.log = {}, {}

  fillFromTiles(R.M, R.M, R.W - R.M - 1, R.H - R.M - 1)
  markSeenRegion(R.M + R.cam.x, R.M + R.cam.y, R.W - R.M - 1 + R.cam.x, R.H - R.M - 1 + R.cam.y)
  R.active = true
  R.say(string.format("Loaded save (%d tiles)", data.tileCount or 0))
  return true, data.tileCount or 0
end
function R.load(path, confirmed)
  local ok, a, b = pcall(doLoad, path, confirmed)
  if not ok then R.say("Load failed: " .. tostring(a)); R.pluginErr = tostring(a); return false, tostring(a) end
  return a, b
end

-- ================================================================ self-test: restore a tiny synthetic tile
-- in an already-empty on-screen rect, verify particle types match, then fully clean up (kill the test
-- particles and put the original tile object - or nil - back). Never touches player/camera/other tiles.
-- Returns ok, mismatches, note. All within one call so nothing else can observe the temporary state.
function R.saveSelfTest()
  local x1, y1, x2, y2 = R.M + 2, R.M + 2, R.M + 9, R.M + 9
  local cx, cy = R.cam.x, R.cam.y
  local wx1, wy1, wx2, wy2 = x1 + cx, y1 + cy, x2 + cx, y2 + cy
  for y = y1, y2 do for x = x1, x2 do if sim.partID(x, y) then return false, 0, "rect not empty, aborted" end end end
  local key = tkey(wx1, wy1)
  local orig = R.tiles[key]
  local brck = R.eid("BRCK") or R.eid("STNE")
  if not brck then return false, 0, "no BRCK/STNE element available" end
  local testRecs, expect = {}, {}
  local idx = 0
  for wy = wy1, wy2 do for wx = wx1, wx2 do
    idx = idx + 1
    if idx % 2 == 0 then testRecs[pkey(wx, wy)] = { brck, 295.15, 0, 0, 0 }; expect[pkey(wx, wy)] = brck end
  end end
  R.tiles[key] = { tx = floor(wx1 / TS), ty = floor(wy1 / TS), sx1 = wx1, sy1 = wy1, sx2 = wx2, sy2 = wy2, recs = testRecs, n = 0 }
  fillFromTiles(x1, y1, x2, y2)
  local mismatches = 0
  for wy = wy1, wy2 do for wx = wx1, wx2 do
    local x, y = wx - cx, wy - cy
    local p = sim.partID(x, y)
    local got = p and sim.partProperty(p, "type") or nil
    local want = expect[pkey(wx, wy)]
    if want ~= got then mismatches = mismatches + 1 end
  end end
  for y = y1, y2 do for x = x1, x2 do local p = sim.partID(x, y); if p then sim.partKill(p) end end end
  R.tiles[key] = orig
  return mismatches == 0, mismatches, "tested " .. ((x2 - x1 + 1) * (y2 - y1 + 1)) .. " cells"
end

-- ================================================================ autosave hook
R.lastAutosave = R.lastAutosave or (R.frame or 0)
hook(R.hooks.tick, function()
  if not R.active then return end
  if (R.frame or 0) - (R.lastAutosave or 0) >= AUTOSAVE_INTERVAL then R.save(true) end
end)
