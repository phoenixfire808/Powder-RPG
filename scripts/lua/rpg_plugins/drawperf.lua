-- Draw-perf instrumentation plugin. PhoenixFire808's wave-brief target: "find and fix the real
-- framerate cost." @perf (2026-09-02, rpg-hub.md) established that R.hooks.gen (worldgen) is
-- never routed through the profiled runHooks() -- hooks.gen.profiled=nil, confirmed live -- so
-- the widely-repeated "world.lua costs 17-18ms" figure cannot be worldgen. That much is correct
-- and is NOT re-litigated here.
--
-- What WAS still genuinely unproven (this file's whole reason to exist): rpg.lua's runHooks()
-- keys R.perf purely by hook TAG (local hookTag(f,i) = f.tag), with no regard for which LIST
-- (tick / draw / drawHUD) is currently iterating it. world.lua calls its own local hook(list, fn)
-- helper (TAG="world") TWICE -- once into R.hooks.tick, once into R.hooks.draw -- and both writes
-- land in the exact same R.perf["world"] EMA slot. So "world.lua's draw hook costs 17ms" was an
-- inference from a NUMBER THAT CANNOT DISTINGUISH TICK FROM DRAW, not a measurement of draw
-- specifically -- confirmed by reading rpg.lua's runHooks/hookTag directly (rpg.lua:1278-1305)
-- and cross-checked live (see the hub entry this file's own author posted). The same conflation
-- affects EVERY plugin that registers the same tag into more than one profiled list -- verified
-- live against Drew's own running session moments before writing this: of the 9 tags currently in
-- R.hooks.draw (enemies, machines, machines2, vehicles, survival, companion, ui, netlink,
-- acq_machines), all 9 ALSO appear in R.hooks.tick under the identical tag. R.perf, as shipped,
-- cannot honestly answer "is this plugin's cost tick or draw" for ANY of them, not just world.
--
-- THE FIX, entirely from outside rpg.lua/world.lua (neither is this lane's file this wave): wrap
-- each already-tagged hook ENTRY, per LIST, with an independent os.clock() timer that writes into
-- this plugin's own R.dpPerf[tag][listName] table instead of the shared R.perf[tag] slot. The
-- wrapped entry keeps the SAME .tag field (so R.perf/R.perfReport/the existing HUD keep working
-- exactly as before -- this is additive instrumentation, not a behaviour change) and still calls
-- the real original function via pcall, so a wrapped hook errors and recovers identically to an
-- unwrapped one.
--
-- Idempotent and reload-safe: world.lua's own hook() helper (and every other plugin's) STRIPS any
-- existing entry with its tag before appending a fresh one on every reload of ITS file -- which
-- means a reload of world.lua (or any wrapped plugin) silently discards this file's wrapper too.
-- rewrapAll() is cheap (a handful of table scans, no per-particle work) and is re-run from a
-- throttled tick hook so a plugin reloaded independently of this file gets re-wrapped within
-- SPLIT_RESCAN_EVERY frames rather than silently going back to being unmeasured.
--
-- Owns: key F12 (on-screen breakdown toggle, currently-unclaimed per a repo-wide grep before
-- picking it). No other keys, no panels that block normal play when closed. Does not touch
-- R.perf's own values or thresholds (R.perfOn, the throttle/skip logic) -- read-only with respect
-- to the existing system, this file only ADDS a second, disambiguated table alongside it.
--
-- NOT YET in R.PLUGINS (rpg.lua isn't this lane's file to edit this wave) -- same situation
-- telemetry.lua documents in its own header: load it via R.reloadPlugin("drawperf") for now, and
-- re-run that after any core F9/hot-reload until "drawperf" is added to the R.PLUGINS literal
-- (insert anywhere -- this file has no load-order dependency on any other plugin, only on rpg.lua
-- itself already being loaded, which is true for every plugin).

local R = PBX.state.rpg
local TAG = "drawperf"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local floor = math.floor
local W, H = R.W or 612, R.H or 384

-- ================================================================ persistent state (survives hot-reload, on R.*)
-- R.dpPerf[tag][listName] = { ms = EMA, maxMs = worst single sample seen, n = sample count }
R.dpPerf = R.dpPerf or {}
R.dpPanelOpen = (R.dpPanelOpen == nil) and false or R.dpPanelOpen
R.dpSampleEvery = R.dpSampleEvery or 5   -- sample 1 frame in N per wrapped hook (finer than R.perf's 1-in-11, still cheap)
R.dpLastSnapshotAt = R.dpLastSnapshotAt or 0
R.dpSnapshotFile = R.dpSnapshotFile or "rpg-drawperf.json"  -- relative: same cwd-resolution rule telemetry.lua documents

-- The three lists rpg.lua actually profiles (rpg.lua:1265 -- tick/draw/drawHUD all have
-- `profile = true`; every other hook list has none and is not a candidate for this conflation).
local WATCH_LISTS = { "tick", "draw", "drawHUD" }

local function ema(rec, ms)
  rec.ms = rec.ms and (rec.ms * 0.7 + ms * 0.3) or ms
  rec.maxMs = math.max(rec.maxMs or 0, ms)
  rec.n = (rec.n or 0) + 1
end

-- Wrap every not-yet-wrapped tagged entry in one list. Skips:
--   - entries with no .tag (nothing to key R.dpPerf by; rare -- rpg.lua's own hookTag falls back
--     to "#i" for these, but an index isn't stable across reloads so this file doesn't chase them)
--   - this file's own TAG (would time itself)
--   - entries already wrapped by this file (marked _dpWrapped, checked before re-wrapping)
local function wrapList(list, listName)
  for i, f in ipairs(list) do
    if type(f) == "table" and f.tag and f.tag ~= TAG and not f._dpWrapped then
      local origTag = f.tag
      local orig = f   -- the whole callable table (has its own __call metamethod) -- calling
                        -- pcall(orig, ...) below invokes it exactly as runHooks itself would.
      local sampleCounter = 0
      local wrapped = setmetatable({ tag = origTag, _dpWrapped = true, _dpList = listName }, {
        __call = function(_, ...)
          sampleCounter = sampleCounter + 1
          local doSample = (sampleCounter % R.dpSampleEvery) == 0
          if not doSample then return orig(...) end
          local t0 = os.clock()
          local ok, a, b, c = pcall(orig, ...)
          local ms = (os.clock() - t0) * 1000
          local byTag = R.dpPerf[origTag]
          if not byTag then byTag = {}; R.dpPerf[origTag] = byTag end
          local rec = byTag[listName]
          if not rec then rec = {}; byTag[listName] = rec end
          ema(rec, ms)
          if not ok then error(a, 0) end   -- preserve pcall-at-runHooks-level error behaviour
          return a, b, c
        end,
      })
      list[i] = wrapped
    end
  end
end

local function rewrapAll()
  for _, listName in ipairs(WATCH_LISTS) do
    local list = R.hooks[listName]
    if list then wrapList(list, listName) end
  end
end

rewrapAll()   -- wrap whatever is already registered at load/reload time

-- ================================================================ reporting
-- Returns, per tag that appears in MORE THAN ONE watched list, its per-list ms breakdown --
-- exactly the set of tags R.perf cannot currently disambiguate. Tags that only ever appear in
-- one list are omitted from the "conflated" section (R.perf's number for them was already
-- correct) but included in the full table for completeness.
function R.dpReport()
  local rows = {}
  for tag, byList in pairs(R.dpPerf) do
    local total, listCount, parts = 0, 0, {}
    for _, listName in ipairs(WATCH_LISTS) do
      local rec = byList[listName]
      if rec and rec.ms then
        listCount = listCount + 1
        total = total + rec.ms
        parts[#parts + 1] = string.format("%s=%.3fms", listName, rec.ms)
      end
    end
    rows[#rows + 1] = { tag = tag, total = total, listCount = listCount, detail = table.concat(parts, " ") }
  end
  table.sort(rows, function(a, b) return a.total > b.total end)
  local lines = {}
  for _, r in ipairs(rows) do
    local flag = r.listCount > 1 and " [WAS CONFLATED IN R.perf]" or ""
    lines[#lines + 1] = string.format("%-14s total=%.3fms  %s%s", r.tag, r.total, r.detail, flag)
  end
  return table.concat(lines, "\n")
end

-- Bounded on-disk snapshot, same discipline telemetry.lua documents (io.open cost is real,
-- ~18.6ms on Windows per open/close per that file's own measurement) -- write once on request /
-- periodically, never every frame, and reuse one open handle.
local snapshotHandle = nil
local function openSnapshotHandle()
  if snapshotHandle then return snapshotHandle end
  snapshotHandle = io.open(R.dpSnapshotFile, "w")
  return snapshotHandle
end

function R.dpSnapshot()
  local f = openSnapshotHandle()
  if not f then return false, "could not open " .. tostring(R.dpSnapshotFile) end
  local parts = { '{"frame":' .. tostring(R.frame or 0) .. ',"tags":{' }
  local first = true
  for tag, byList in pairs(R.dpPerf) do
    if not first then parts[#parts + 1] = "," end
    first = false
    local lp = {}
    for _, listName in ipairs(WATCH_LISTS) do
      local rec = byList[listName]
      if rec and rec.ms then lp[#lp + 1] = string.format('"%s":{"ms":%.4f,"maxMs":%.4f,"n":%d}', listName, rec.ms, rec.maxMs or 0, rec.n or 0) end
    end
    parts[#parts + 1] = string.format('"%s":{%s}', tag, table.concat(lp, ","))
  end
  parts[#parts + 1] = "}}"
  f:seek("set", 0)
  f:write(table.concat(parts))
  f:flush()
  if R.tlog then R.tlog("info", "drawperf", "snapshot written", { file = R.dpSnapshotFile, frame = R.frame }) end
  return true
end

-- ================================================================ housekeeping tick hook
-- Re-wraps anything a plugin reload silently un-wrapped, and takes a periodic snapshot. Both are
-- throttled (rescan every 30 frames ~ 0.5s at 60fps; snapshot every 300 frames ~ 5s) -- neither is
-- a per-frame cost.
local RESCAN_EVERY = 30
local SNAPSHOT_EVERY = 300
hook(R.hooks.tick, function()
  local frame = R.frame or 0
  if frame % RESCAN_EVERY == 0 then rewrapAll() end
  if frame - R.dpLastSnapshotAt >= SNAPSHOT_EVERY then
    R.dpLastSnapshotAt = frame
    pcall(R.dpSnapshot)
  end
end)

hook(R.hooks.key, function(k)
  if k == "1073741893" then R.dpPanelOpen = not R.dpPanelOpen; return true end   -- F12
  return
end)

-- On-screen breakdown, off by default, one line when closed via the same convention telemetry.lua
-- uses for its own F11 panel. This is a SEPARATE tag from the tick housekeeping hook above
-- (drawperf/drawperfHUD would collide identically to the bug this file exists to fix if drawn
-- under the same tag as a tick hook -- registering the reporting draw under its own dedicated tag
-- avoids that on principle, even though nobody currently reads R.perf["drawperf"]).
local HUD_TAG = "drawperfHUD"
do
  local list = R.hooks.drawHUD
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == HUD_TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = HUD_TAG }, { __call = function()
    if not R.dpPanelOpen then
      graphics.drawText(4, H - 12, "F12: draw-perf breakdown", 140, 150, 170, 160)
      return
    end
    local px, py, pw, ph = 4, 30, 330, 340
    graphics.fillRect(px, py, pw, ph, 10, 12, 18, 225)
    graphics.drawRect(px, py, pw, ph, 120, 180, 220, 255)
    graphics.drawText(px + 6, py + 4, "DRAW-PERF (F12 to close) -- tick vs draw, per tag", 200, 220, 255, 255)
    local rows = {}
    for tag, byList in pairs(R.dpPerf) do
      local total, listCount, parts = 0, 0, {}
      for _, listName in ipairs(WATCH_LISTS) do
        local rec = byList[listName]
        if rec and rec.ms then
          listCount = listCount + 1; total = total + rec.ms
          parts[#parts + 1] = listName:sub(1, 1) .. "=" .. string.format("%.2f", rec.ms)
        end
      end
      rows[#rows + 1] = { tag = tag, total = total, listCount = listCount, detail = table.concat(parts, " ") }
    end
    table.sort(rows, function(a, b) return a.total > b.total end)
    for i = 1, math.min(20, #rows) do
      local r = rows[i]
      local flag = r.listCount > 1 and " *" or ""
      local col = r.listCount > 1 and { 255, 210, 140 } or { 200, 220, 230 }
      graphics.drawText(px + 6, py + 20 + (i - 1) * 14, string.format("%-13s %6.2fms %s%s", r.tag, r.total, r.detail, flag), col[1], col[2], col[3], 255)
    end
    graphics.drawText(px + 6, py + ph - 12, "* = was one shared R.perf slot before this file", 150, 150, 150, 255)
  end })
end

if R.tlog then R.tlog("info", "drawperf", "drawperf plugin loaded", { sampleEvery = R.dpSampleEvery }) end
