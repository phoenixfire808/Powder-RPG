-- Telemetry / diagnostics plugin. PhoenixFire808, verbatim: "I need... absolutely super detailed
-- logging for everything -- that way we can rapidly determine where particles are and any errors
-- that happened and literally every little detail." Built because the submit-tool bug report
-- (ui.lua's Y-key stamp-submission flow) left NO trace: pluginErr/lastErr both read nil while he
-- was actively hitting errors -- every failure on that path was either caught by a bare pcall and
-- only shown for a few seconds in the fading R.log, or happened somewhere no pcall exists at all.
-- This is a real structured log on disk, a bounded on-demand state/particle dump, and a
-- persistent in-game error surface, built BEFORE guessing at the actual submit bug (see ui.lua's
-- own submit-path R.tlog calls, added in the same pass).
--
-- Owns: key F10 (particle/state dump), key F11 (diagnostics panel toggle). No other keys, no
-- panels that block normal play when closed.
--
-- NOT YET in R.PLUGINS (rpg.lua isn't this lane's file to edit this wave) -- loaded this session
-- via R.reloadPlugin("telemetry") over the bridge, which works with no core edit at all since
-- reloadPlugin loads by filename, not by membership in R.PLUGINS. Residual risk, undisguised:
-- R.PLUGINS is only consulted at BOOT and by a core hot-reload (F9 / R.hotReloadRequested), which
-- re-runs rpg.lua from scratch and does `R.hooks = {...}` -- a fresh table -- then re-registers
-- every plugin named in R.PLUGINS. Until "telemetry" is added to that list (exact patch below),
-- an F9 core reload will silently drop this plugin's hooks; re-run
-- `PBX.state.rpg.reloadPlugin("telemetry")` after any F9 until the patch lands.
--
-- EXACT PATCH for whoever owns rpg.lua this wave (not applied by this lane):
--   1) R.PLUGINS = { "world", "enemies", "machines", "machines2", "items", "terraweapons",
--        "vehicles", "survival", "companion", "save", "telemetry", "ui", "guide", "netlink" }
--      (insert "telemetry" anywhere before "ui" -- ui.lua calls R.tlog and guards every call with
--      `if R.tlog then`, so order relative to earlier plugins doesn't matter, only "before ui".)
--   2) Optional, for hook-level (not just draw/tick-level) auto-capture with the failing hook's
--      NAME attached (currently R.pluginErr has the message but not which hook/tag produced it):
--      in `local function runHooks(list, ...)`, change
--        `if not ok then R.pluginErr = tostring(r) elseif r then return r end`
--      to
--        `if not ok then R.pluginErr = tostring(r); if R.tlog then R.tlog("error", "hook", tostring(r), { tag = tag, frame = R.frame }) end elseif r then return r end`
--      This is additive and guarded (`if R.tlog then`) -- behaves identically to today if the
--      telemetry plugin is ever absent.

local R = PBX.state.rpg
local TAG = "telemetry"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local floor = math.floor
local W, H = R.W or 612, R.H or 384

-- ================================================================ persistent state (survives hot-reload, on R.*)
R.tlogLevel = R.tlogLevel or "info"       -- off < error < warn < info < debug
R.tlogBuf = R.tlogBuf or {}               -- pending lines not yet flushed to disk
R.tlogRecent = R.tlogRecent or {}         -- ring buffer for the in-game panel: { line, frame, level }
R.tlogLastErrAt = R.tlogLastErrAt or nil  -- frame of most recent error, for the persistent banner
R.tlogLastErrText = R.tlogLastErrText or nil
R.tlogBytes = R.tlogBytes or 0            -- running written-byte estimate; avoids a disk seek every flush
R.tlogFile = R.tlogFile or "rpg-debug.log"  -- RELATIVE path deliberately (see below), one line per entry
R.tlogMaxBytes = R.tlogMaxBytes or (2 * 1024 * 1024)  -- 2MB cap; rotates to .old past this, never grows unbounded
R.tlogPanelOpen = R.tlogPanelOpen or false
-- Relative path resolves against the game's cwd (D:/The-Powder-Toy/build for his real session,
-- per process-and-bridge-ops skill -- confirmed the same place manifest.jsonl already lands, so
-- "somewhere obvious" and "the writable dir the submit path already proved it can write to" are
-- the same directory). A lab instance's own --dir gets its OWN rpg-debug.log, same isolation
-- property @stamps already found true of manifest.jsonl for lab dirs -- verified again below.

local LEVEL_ORDER = { error = 1, warn = 2, info = 3, debug = 4 }

function R.tlogSetLevel(level) if LEVEL_ORDER[level] or level == "off" then R.tlogLevel = level end; return R.tlogLevel end

-- Cheap-when-off by construction: the level compare happens BEFORE any string building, so a
-- call at "debug" severity while R.tlogLevel="info" costs one table lookup and one compare, never
-- string.format/concat. Measured overhead reported in the hub entry for this pass.
function R.tlog(level, subsystem, msg, fields)
  local threshold = LEVEL_ORDER[R.tlogLevel] or 3
  local lv = LEVEL_ORDER[level] or 3
  if R.tlogLevel == "off" or lv > threshold then return end
  local frame = R.frame or 0
  local line
  if fields then
    local parts = {}
    for k, v in pairs(fields) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    line = string.format("[%s] f=%d %s %s: %s {%s}", os.date("%H:%M:%S"), frame, level:upper(), subsystem, tostring(msg), table.concat(parts, " "))
  else
    line = string.format("[%s] f=%d %s %s: %s", os.date("%H:%M:%S"), frame, level:upper(), subsystem, tostring(msg))
  end
  R.tlogBuf[#R.tlogBuf + 1] = line
  R.tlogRecent[#R.tlogRecent + 1] = { line = line, frame = frame, level = level }
  if #R.tlogRecent > 40 then table.remove(R.tlogRecent, 1) end
  if level == "error" then
    R.tlogLastErrAt = frame
    R.tlogLastErrText = subsystem .. ": " .. tostring(msg)
  end
  -- No per-frame disk I/O: only flush immediately for an error (he needs to see it fast) or once
  -- the buffer gets large; everything else waits for the periodic tick-hook flush below.
  if level == "error" or #R.tlogBuf >= 40 then R.tlogFlush() end
end

-- MEASURED, own lab instance (port 9892): io.open("a")+write+close costs ~18.6ms/flush (Windows
-- open/close syscall overhead, not the write itself) -- close to an entire 16.7ms frame budget,
-- unacceptable for something that can fire on every error. Reusing one open handle across flushes
-- and calling :flush() instead of :close() measured ~0.0ms/flush for the identical 40-line write.
-- R.tlogHandle is kept OPEN (not closed) between flushes for exactly this reason; R.* survives
-- hot-reload, so the handle survives a plugin reload without needing to reopen.
local function tlogOpenHandle()
  if R.tlogHandle then return R.tlogHandle end
  R.tlogHandle = io.open(R.tlogFile, "a")
  return R.tlogHandle
end

function R.tlogFlush()
  if #R.tlogBuf == 0 then return true end
  local f = tlogOpenHandle()
  if not f then return false, "could not open " .. tostring(R.tlogFile) end
  local blob = table.concat(R.tlogBuf, "\n") .. "\n"
  f:write(blob)
  f:flush()  -- durability without the close/reopen cost -- see measurement above
  R.tlogBuf = {}
  R.tlogBytes = (R.tlogBytes or 0) + #blob
  if R.tlogBytes > R.tlogMaxBytes then
    f:close(); R.tlogHandle = nil
    pcall(os.remove, R.tlogFile .. ".old")
    pcall(os.rename, R.tlogFile, R.tlogFile .. ".old")
    R.tlogBytes = 0
  end
  return true
end

-- ================================================================ on-demand particle/state dump (F10)
-- Bounded, on request, NOT every frame -- a full sim.parts() type tally is a real, measured cost
-- (companion.lua's own comment: 13-24ms live, a single-frame hitch, not a per-frame one), which is
-- exactly why this only runs when the player asks for it.
local function depthBandAt(wx, wy)
  local bands = R.depthInfo
  if not bands or not R.surfaceAt then return "?" end
  local d = floor(wy) - R.surfaceAt(floor(wx))
  local band = bands[1]
  for _, b in ipairs(bands) do if d >= b.d then band = b end end
  return band and band.name or "?", d
end

function R.tlogDump()
  local t0 = os.clock()
  local counts, total = {}, 0
  for i in sim.parts() do
    total = total + 1
    local ty = sim.partProperty(i, "type")
    local nm = (R.nameOf and R.nameOf(ty)) or tostring(ty)
    counts[nm] = (counts[nm] or 0) + 1
  end
  local rows = {}
  for nm, n in pairs(counts) do rows[#rows + 1] = { nm, n } end
  table.sort(rows, function(a, b) return a[2] > b[2] end)
  local top = {}
  for i = 1, math.min(15, #rows) do top[#top + 1] = rows[i][1] .. "=" .. rows[i][2] end

  local px, py = (R.P and R.P.x) or 0, (R.P and R.P.y) or 0
  local biome = (R.biomeAt and R.biomeAt(floor(px))) or "?"
  local band, depth = depthBandAt(px, py)
  local sel = R.hotbar and R.hotbar[R.sel or 1] or "?"
  local mx, my = (R.mouse and R.mouse.x) or 0, (R.mouse and R.mouse.y) or 0
  local under = "none"
  local okc, p = pcall(sim.partID, mx, my)
  if okc and p then
    local okt, ty = pcall(sim.partProperty, p, "type")
    if okt then under = (R.nameOf and R.nameOf(ty)) or tostring(ty) end
  end
  local ms = (os.clock() - t0) * 1000

  R.tlog("info", "dump", "particle/state snapshot", {
    total = total, top = "[" .. table.concat(top, ",") .. "]",
    px = string.format("%.1f", px), py = string.format("%.1f", py),
    camx = (R.cam and R.cam.x) or 0, camy = (R.cam and R.cam.y) or 0,
    biome = biome, band = band, depth = depth or 0,
    selected = sel, underCursor = under, scanMs = string.format("%.2f", ms),
  })
  R.tlogFlush()
  R.say(string.format("Dump written to %s (%d particles, %.1fms scan)", R.tlogFile, total, ms))
end

-- ================================================================ auto-capture existing error channels
-- Best-effort until the runHooks patch above lands: R.pluginErr already carries every hook pcall
-- failure's MESSAGE (just not which hook), R.lastErr carries every draw-path pcall failure's
-- message. Neither was ever written to disk or shown persistently before this plugin -- this is
-- the fix for "pluginErr=nil, lastErr=nil... whatever is failing is failing somewhere nothing
-- records": nothing was polling and persisting them, not that nothing was failing.
local lastSeenPluginErr, lastSeenLastErr = nil, nil
local flushCounter = 0

hook(R.hooks.tick, function()
  if R.pluginErr and R.pluginErr ~= lastSeenPluginErr then
    lastSeenPluginErr = R.pluginErr
    R.tlog("error", "hook", R.pluginErr, { frame = R.frame })
  end
  if R.lastErr and R.lastErr ~= lastSeenLastErr then
    lastSeenLastErr = R.lastErr
    R.tlog("error", "draw", R.lastErr, { frame = R.frame })
  end
  flushCounter = flushCounter + 1
  if flushCounter >= 60 then flushCounter = 0; R.tlogFlush() end
end)

hook(R.hooks.key, function(k)
  if k == "1073741891" then R.tlogDump(); return true end       -- F10
  if k == "1073741892" then R.tlogPanelOpen = not R.tlogPanelOpen; return true end  -- F11
  return
end)

-- ================================================================ in-game error surface
-- He plays and cannot read a log file mid-session (his own framing of the problem) -- this is
-- the in-game half. Two tiers: a small persistent banner whenever something recent failed (no
-- key needed, impossible to miss and impossible to leave open by accident), and F11 for the
-- fuller scrollback when he wants more than one line.
hook(R.hooks.drawHUD, function()
  if R.tlogLastErrAt then
    local age = (R.frame or 0) - R.tlogLastErrAt
    if age >= 0 and age < 600 then
      local a = age < 400 and 255 or math.max(0, 255 - floor((age - 400) * 1.3))
      if a > 0 then
        graphics.fillRect(W - 302, H - 30, 298, 22, 40, 8, 8, math.min(160, a))
        graphics.drawText(W - 296, H - 24, ("ERR: " .. tostring(R.tlogLastErrText)):sub(1, 60), 255, 160, 160, a)
      end
    else
      R.tlogLastErrAt = nil
    end
  end

  if R.tlogPanelOpen then
    local px, py, pw, ph = 150, 40, 320, 300
    graphics.fillRect(px, py, pw, ph, 10, 12, 18, 225)
    graphics.drawRect(px, py, pw, ph, 120, 160, 220, 255)
    graphics.drawText(px + 8, py + 6, string.format("DIAGNOSTICS (F11 to close) - level=%s file=%s", R.tlogLevel, R.tlogFile), 200, 220, 255, 255)
    graphics.drawText(px + 8, py + 18, "F10 = dump particles/state now", 150, 170, 200, 255)
    local n = #R.tlogRecent
    local rows = math.min(18, n)
    for i = 1, rows do
      local e = R.tlogRecent[n - rows + i]
      local r, g, b = 200, 210, 220
      if e.level == "error" then r, g, b = 255, 150, 150 elseif e.level == "warn" then r, g, b = 240, 210, 130 end
      graphics.drawText(px + 8, py + 32 + (i - 1) * 13, e.line:sub(1, 62), r, g, b, 255)
    end
  end
end)

-- Open the log handle now, at load/reload time, rather than lazily on the first real flush --
-- the one-time io.open cost (measured up to tens of ms the very first time this session) should
-- land here, a naturally expected pause point, not mid-gameplay on the first actual error.
tlogOpenHandle()
R.tlog("info", "telemetry", "telemetry plugin loaded", { level = R.tlogLevel, file = R.tlogFile })
