-- Sandbox toolkit plugin (R.sandboxMode only). Owns: F6 toggle, the small dev-toolkit panel,
-- and the worldgen slice sampler. Does NOT own submission (Y-key stamp/region submit lives in
-- ui.lua, right next to the functions it reuses) or F8 bug/suggestion (handled here since it
-- needs no locals from any other file -- R.feedbackOpen/R.feedbackText/R.submitFeedback are all
-- public R.* already, see rpg.lua's own non-sandbox F8 handling this mirrors).
--
-- WHY THIS EXISTS: PhoenixFire808, on sandbox v1 -- "I want some UI in the vanilla sandbox --
-- just in case people want to test stuff out, or if I want to build samples for world
-- generation." Sandbox is his own dev surface for prototyping worldgen, so the star feature
-- here is the slice sampler (2), not decoration.
--
-- rpg.lua stops running the whole RPG while R.sandboxMode is set (onKeyDown/onMouseDown/
-- onMouseUp/onMouseMove/onTextInput/onDraw/onTick all return before ever reaching
-- runHooks(R.hooks.key/mousedown/...) -- see rpg.lua's own SANDBOX FIX comments). This plugin's
-- hooks run through a SEPARATE set of lists (R.hooks.sandboxKey/sandboxMouseDown/
-- sandboxMouseUp/sandboxMouseMove/sandboxDraw/sandboxDrawHUD/sandboxTick) that rpg.lua only
-- dispatches while R.sandboxMode is true -- patch requested from @survival (rpg.lua is not this
-- lane's file this wave), posted to knowledge/rpg-hub.md. Until that patch lands these hooks are
-- registered but never called -- this file is inert (compiles, no error) rather than broken.
--
-- INTERFACE-EVENT DISCIPLINE (verified against src/lua/LuaInterface.cpp/LuaSimulation.cpp
-- directly, not assumed): tpt.brushx/tpt.brushID/tpt.selectedl (interface.cpp's brushID/
-- brushRadius/activeTool) and sim.paused()/sim.step()/sim.saveStamp()/sim.loadStamp() all call
-- AssertInterfaceEvent() UNCONDITIONALLY, even to just READ -- calling them from a draw hook
-- throws. sim.partID/partProperty/pressure/ambientHeat/partCount reads and sim.partKill have no
-- such guard (LuaBlockMap's 2-arg form skips AssertMutableSimEvent entirely) -- confirmed safe
-- from anywhere, including draw, and already used that way throughout rpg.lua's own onDraw.
-- Tick IS an interface-event context (rpg.lua's onTick calls sim.paused()/sim.pressure(...,v)
-- unguarded in dozens of places) -- only draw is excluded. So: every tpt.*/sim.paused/sim.step/
-- sim.saveStamp/sim.loadStamp call in this file happens from sandboxTick/sandboxKey/
-- sandboxMouseDown (all interface events), cached onto R.sbx, and sandboxDraw/sandboxDrawHUD
-- only ever READ that cache -- never call a gated API directly.
local R = PBX.state.rpg
local TAG = "sandbox"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end
-- Lazily create the hook lists this file (and ui.lua's sandbox-submission block) dispatch into,
-- in case this plugin loads before rpg.lua's patch adds them to the R.hooks literal -- an empty
-- table here is harmless; runHooks on an empty list just does nothing.
for _, name in ipairs({ "sandboxKey", "sandboxTextInput", "sandboxMouseDown", "sandboxMouseUp", "sandboxMouseMove", "sandboxDraw", "sandboxDrawHUD", "sandboxTick" }) do
  R.hooks[name] = R.hooks[name] or {}
end

local floor, min, max = math.floor, math.min, math.max
local W, H = R.W or 612, R.H or 384

R.sbx = R.sbx or {
  panelOpen = false,
  mx = 0, my = 0,
  paused = false, brushShape = 0, brushX = 1, brushY = 1, selectedEl = "?",
  fpsSmoothed = 0, lastClock = nil,
  clearArm = false, clearArmTick = 0,
  seed = 7, depthStart = 200, worldX = 40, sizeIdx = 2,   -- sizeIdx: 1=Small 2=Medium 3=Large
  lastSample = nil,   -- { seed, depthStart, worldX, w, h, ms, cells }
  tick = 0,
}
local S = R.sbx
-- feedback (F8) box state lives on R already (R.feedbackOpen/R.feedbackText), shared with the
-- normal RPG's own F8 flow so a hot-reload or an Esc-out-and-back-in can never desync two
-- separate copies of "is the feedback box open".

local SIZES = { { w = 100, h = 100, label = "Small 100x100" }, { w = 160, h = 140, label = "Medium 160x140" }, { w = 220, h = 170, label = "Large 220x170" } }

-- ================================================================ tick: cache every gated (interface-event-only) read
hook(R.hooks.sandboxTick, function()
  S.tick = S.tick + 1
  local now = os.clock()
  if S.lastClock then
    local dt = now - S.lastClock
    if dt > 0 then local fps = 1 / dt; S.fpsSmoothed = S.fpsSmoothed == 0 and fps or (S.fpsSmoothed * 0.9 + fps * 0.1) end
  end
  S.lastClock = now
  local ok, p = pcall(sim.paused); if ok then S.paused = p end
  local okb, bid = pcall(function() return tpt.brushID end); if okb then S.brushShape = bid end
  local okx, bx, by = pcall(function() return tpt.brushx, tpt.brushy end); if okx then S.brushX, S.brushY = bx, by end
  local oks, sel = pcall(function() return tpt.selectedl end)
  if oks and sel then S.selectedEl = tostring(sel):match("_PT_(.+)$") or tostring(sel) end
  if S.clearArm and S.tick - S.clearArmTick > 90 then S.clearArm = false end   -- 2-click confirm expires ~1.5s
end)

-- ================================================================ key: F6 toggle, F8 feedback (mirrors rpg.lua's own non-sandbox flow, self-contained)
local function grabText() pcall(interface.grabTextInput) end
local function releaseText() pcall(interface.dropTextInput) end
hook(R.hooks.sandboxKey, function(key, k, shift, ctrl, alt)
  if R.feedbackOpen then
    if key == 13 or key == 271 or key == 1073741912 then
      local msg = R.feedbackText
      R.feedbackOpen = false; R.feedbackText = ""; releaseText()
      R.submitFeedback(msg)
      return true
    elseif key == 27 then R.feedbackOpen = false; R.feedbackText = ""; releaseText(); R.say("Feedback cancelled"); return true
    elseif key == 8 then R.feedbackText = R.feedbackText:sub(1, -2); return true
    elseif ctrl and key == 118 then
      local ok, text = pcall(platform.clipboardCopy); if ok and text then R.feedbackText = (R.feedbackText .. text):sub(1, 400) end; return true
    end
    return true
  end
  if key == 1073741887 then S.panelOpen = not S.panelOpen; return true end   -- F6
  if key == 1073741889 then R.feedbackOpen = true; R.feedbackText = ""; grabText(); return true end   -- F8
  return
end)
hook(R.hooks.sandboxTextInput, function(text)
  if R.feedbackOpen and #R.feedbackText < 400 then R.feedbackText = R.feedbackText .. text end
end)

-- ================================================================ worldgen slice sampler
-- Synchronous, single click, deliberately bounded small (see SIZES above) rather than an
-- incremental multi-tick job: a job spanning ticks would need to survive the player pressing
-- Esc mid-job (R.sandboxMode flips off -> sandboxTick stops firing entirely -> a seed left
-- swapped on R.seed would silently corrupt every NOT-YET-EXPLORED tile of the player's real
-- world after they leave sandbox). One synchronous pass with the restore in the same call,
-- wrapped so the restore always runs, has no such window at all.
local function runSample()
  local sz = SIZES[S.sizeIdx]
  local origSeed = R.seed
  local t0 = os.clock()
  local ok, err = pcall(function()
    R.seed = S.seed
    if R.resetGenCaches then R.resetGenCaches() end
    -- placed below the panel (panel is ~4,4..214,mm) so the sample never draws under its own controls
    local x0, y0 = 8, 180
    local x1, y1 = min(W - 8, x0 + sz.w), min(H - 8, y0 + sz.h)
    for y = y0, y1 - 1 do
      local wy = S.depthStart + (y - y0)
      for x = x0, x1 - 1 do
        local wx = S.worldX + (x - x0)
        local existing = sim.partID(x, y); if existing then sim.partKill(existing) end
        local el = R.gen(wx, wy)
        if el then local e = R.eid(el); if e then sim.partCreate(-1, x, y, e) end end
      end
    end
    S.lastSample = { seed = S.seed, depthStart = S.depthStart, worldX = S.worldX, w = x1 - x0, h = y1 - y0 }
  end)
  R.seed = origSeed
  if R.resetGenCaches then R.resetGenCaches() end
  local ms = (os.clock() - t0) * 1000
  if ok and S.lastSample then
    S.lastSample.ms = ms
    R.say(string.format("World sample: seed %d, depth %d-%d, x %d-%d (%dx%d cells, %.1fms)",
      S.lastSample.seed, S.lastSample.depthStart, S.lastSample.depthStart + S.lastSample.h,
      S.lastSample.worldX, S.lastSample.worldX + S.lastSample.w, S.lastSample.w, S.lastSample.h, ms))
  else
    R.say("World sample failed: " .. tostring(err))
  end
end

-- ================================================================ panel layout + hit-testing (mouse-only, no typed fields -- see file header)
local PX, PY, PW, PH = 4, 4, 210, 168
local function btn(x, y, w, h, label) return { x = x, y = y, w = w, h = h, label = label } end
local function layoutButtons()
  local y = PY + 62
  local b = {}
  b.pause = btn(PX + 8, y, 62, 14, "PAUSE"); b.step = btn(PX + 74, y, 46, 14, "STEP"); b.clear = btn(PX + 124, y, 78, 14, "CLEAR ALL")
  y = y + 18
  b.save = btn(PX + 8, y, 96, 14, "SAVE SCRATCH"); b.load = btn(PX + 108, y, 94, 14, "LOAD SCRATCH")
  y = y + 24   -- + divider text
  b.seedMinus = btn(PX + 60, y, 14, 12, "-"); b.seedPlus = btn(PX + 116, y, 14, 12, "+")
  y = y + 15
  b.xMinus = btn(PX + 60, y, 14, 12, "-"); b.xPlus = btn(PX + 116, y, 14, 12, "+")
  y = y + 15
  b.depthMinus = btn(PX + 60, y, 14, 12, "-"); b.depthPlus = btn(PX + 116, y, 14, 12, "+")
  y = y + 16
  b.size = btn(PX + 8, y, 194, 14, SIZES[S.sizeIdx].label .. "  (click to cycle)")
  y = y + 18
  b.generate = btn(PX + 8, y, 194, 16, "GENERATE SLICE")
  return b
end
local function hit(bt, x, y) return bt and x >= bt.x and x < bt.x + bt.w and y >= bt.y and y < bt.y + bt.h end

hook(R.hooks.sandboxMouseDown, function(x, y, button)
  if not S.panelOpen then return end
  if not (x >= PX and x < PX + PW and y >= PY and y < PY + PH) then return end   -- click outside the panel: let it fall through (native draw / other sandbox hooks)
  S._consumedDown = true
  local b = layoutButtons()
  if hit(b.pause, x, y) then local ok, p = pcall(sim.paused); if ok then pcall(sim.paused, not p) end
  elseif hit(b.step, x, y) then pcall(sim.step, 1)
  elseif hit(b.clear, x, y) then
    if S.clearArm then pcall(sim.clearSim); S.clearArm = false; R.say("Sandbox cleared")
    else S.clearArm = true; S.clearArmTick = S.tick; R.say("Click CLEAR ALL again to confirm") end
  elseif hit(b.save, x, y) then
    local ok, id = pcall(sim.saveStamp, 0, 0, W, H, 1)
    if ok and id and id ~= "" then S.scratchId = id; R.say("Scratch saved (" .. tostring(id) .. ")") else R.say("Scratch save failed") end
  elseif hit(b.load, x, y) then
    if S.scratchId then local ok = pcall(sim.loadStamp, S.scratchId, 0, 0); R.say(ok and "Scratch loaded" or "Scratch load failed")
    else R.say("No scratch stamp saved yet") end
  elseif hit(b.seedMinus, x, y) then S.seed = S.seed - 1
  elseif hit(b.seedPlus, x, y) then S.seed = S.seed + 1
  elseif hit(b.xMinus, x, y) then S.worldX = S.worldX - 200
  elseif hit(b.xPlus, x, y) then S.worldX = S.worldX + 200
  elseif hit(b.depthMinus, x, y) then S.depthStart = max(0, S.depthStart - 100)
  elseif hit(b.depthPlus, x, y) then S.depthStart = S.depthStart + 100
  elseif hit(b.size, x, y) then S.sizeIdx = (S.sizeIdx % #SIZES) + 1
  elseif hit(b.generate, x, y) then runSample()
  end
  return true
end)
hook(R.hooks.sandboxMouseUp, function(x, y, button)
  if S._consumedDown then S._consumedDown = false; return true end
  return
end)
hook(R.hooks.sandboxMouseMove, function(x, y, dx, dy) S.mx, S.my = x, y end)

-- ================================================================ draw: HUD only (screen-space); no world-space overlay needed
local function drawPanel()
  graphics.fillRect(PX, PY, PW, PH, 8, 10, 20, 225); graphics.drawRect(PX, PY, PW, PH, 120, 200, 255, 220)
  graphics.drawText(PX + 6, PY + 4, "SANDBOX TOOLKIT", 160, 220, 255, 255)
  graphics.drawText(PX + PW - 60, PY + 4, "F6 closes", 150, 150, 165, 220)
  local okpc, pc = pcall(sim.partCount)
  graphics.drawText(PX + 6, PY + 16, string.format("FPS %d   Particles %d", floor(S.fpsSmoothed + 0.5), okpc and pc or -1), 200, 200, 210, 255)
  graphics.drawText(PX + 6, PY + 28, string.format("Brush: shape %d  r%d,%d   Tool: %s", S.brushShape or 0, S.brushX or 0, S.brushY or 0, S.selectedEl or "?"), 200, 200, 210, 255)
  local mx, my = S.mx, S.my
  local pel = "empty"
  local okp, pid = pcall(sim.partID, mx, my)
  if okp and pid then local okn, t = pcall(sim.partProperty, pid, "type"); if okn then pel = R.nameOf(t) or "?" end end
  local okpr, press = pcall(sim.pressure, floor(mx / 4), floor(my / 4))
  local okh, heat = pcall(sim.ambientHeat, floor(mx / 4), floor(my / 4))
  graphics.drawText(PX + 6, PY + 40, string.format("Cursor: %-6s T=%sK  P=%s", pel, okh and string.format("%.0f", heat) or "?", okpr and string.format("%.2f", press) or "?"), 200, 200, 210, 255)
  local b = layoutButtons()
  local function drawBtn(bt, active, danger)
    local bg = danger and { 70, 25, 20 } or (active and { 30, 70, 34 } or { 26, 30, 46 })
    local border = danger and { 255, 120, 90 } or (active and { 140, 255, 140 } or { 110, 120, 150 })
    graphics.fillRect(bt.x, bt.y, bt.w, bt.h, bg[1], bg[2], bg[3], 235)
    graphics.drawRect(bt.x, bt.y, bt.w, bt.h, border[1], border[2], border[3], 255)
    graphics.drawText(bt.x + 3, bt.y + math.floor((bt.h - 7) / 2), bt.label, 220, 225, 235, 255)
  end
  drawBtn(b.pause, S.paused); drawBtn(b.step, false); drawBtn(b.clear, false, S.clearArm)
  drawBtn(b.save, false); drawBtn(b.load, false)
  graphics.drawText(PX + 6, b.seedMinus.y - 11, "WORLD SAMPLE (seed slice preview)", 180, 220, 255, 255)
  graphics.drawText(PX + 8, b.seedMinus.y - 1, "Seed", 190, 190, 205, 255); drawBtn(b.seedMinus); graphics.drawText(PX + 78, b.seedMinus.y - 1, tostring(S.seed), 230, 230, 240, 255); drawBtn(b.seedPlus)
  graphics.drawText(PX + 8, b.xMinus.y - 1, "X", 190, 190, 205, 255); drawBtn(b.xMinus); graphics.drawText(PX + 78, b.xMinus.y - 1, tostring(S.worldX), 230, 230, 240, 255); drawBtn(b.xPlus)
  graphics.drawText(PX + 8, b.depthMinus.y - 1, "Depth", 190, 190, 205, 255); drawBtn(b.depthMinus); graphics.drawText(PX + 78, b.depthMinus.y - 1, tostring(S.depthStart), 230, 230, 240, 255); drawBtn(b.depthPlus)
  drawBtn(b.size); drawBtn(b.generate)
  if S.lastSample then
    graphics.drawText(PX + 6, PY + PH + 4, string.format("last: seed %d depth %d-%d x %d-%d (%.0fms)",
      S.lastSample.seed, S.lastSample.depthStart, S.lastSample.depthStart + S.lastSample.h,
      S.lastSample.worldX, S.lastSample.worldX + S.lastSample.w, S.lastSample.ms or 0), 160, 220, 160, 220)
  end
end
hook(R.hooks.sandboxDrawHUD, function()
  if R.feedbackOpen then
    -- same box shape as the normal RPG's F8 flow (rpg.lua's drawHUD), reimplemented here since
    -- that draw path never runs in sandbox -- kept intentionally small/plain, this is a utility
    -- box not a styled panel.
    local bw, bh = 420, 90
    local bx, by = floor((W - bw) / 2), floor((H - bh) / 2)
    graphics.fillRect(bx, by, bw, bh, 12, 14, 26, 250); graphics.drawRect(bx, by, bw, bh, 255, 220, 80, 255)
    graphics.drawText(bx + 8, by + 6, "Bug / suggestion for PhoenixFire808 (Enter sends, Esc cancels)", 255, 220, 80, 255)
    graphics.drawText(bx + 8, by + 26, (R.feedbackText or "") .. "_", 220, 220, 230, 255)
    return
  end
  if not S.panelOpen then
    graphics.drawText(4, H - 14, "F6: sandbox toolkit", 190, 190, 205, 180)
    return
  end
  drawPanel()
end)
