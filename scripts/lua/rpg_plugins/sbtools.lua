-- Sandbox mining/tools tester plugin (R.sandboxMode only). Owns: the "MINING & TOOLS TESTER"
-- sub-panel drawn alongside sandbox.lua's own F6 dev-toolkit panel.
--
-- WHY THIS EXISTS: PhoenixFire808's own words -- sandbox mode is for "test[ing] out limitations
-- with the character, different tools, mining resources." Today sandbox runs none of the RPG
-- (rpg.lua deliberately early-returns out of every hook while R.sandboxMode is set -- see
-- sandbox.lua's own header), so none of that was testable without leaving sandbox entirely for
-- R.sbRpgTest()'s full flat-world RPG session. This plugin exercises the REAL mining/tool
-- functions (`R.actorMine`, `R.MINEABLE`/`R.HARD`/`R.PICKS`, `R.partLabel`/`R.typeLabel`)
-- directly against whatever is on the sandbox canvas, mouse-only, without needing a session.
--
-- SCOPE, stated so it isn't assumed complete: mining (any pick tier, real hit-count/yield rules,
-- axe toggle) and a give-material spawner (plain/Molten/Powdered variant of any R.MINEABLE
-- material, so a specific state-of-matter can actually be placed to mine-test in the first
-- place). Torch/bucket/sword testing were looked at and deliberately NOT built this pass --
-- `R.actorLight` places wood but never ignites it (the real "torch lit - real fire" path is a
-- different, inline, non-exported block in rpg.lua ~line 3108), and sword/weapon testing needs
-- a live target, which sandbox intentionally has none of (enemies are forced off). Flagged in
-- the report, not silently skipped.
--
-- Same hook discipline as sandbox.lua: registered on R.hooks.sandbox* (only dispatched while
-- R.sandboxMode is true, see rpg.lua's own sandbox dispatch), tag-based re-registration so a
-- hot-reload never leaves a duplicate copy running.
local R = PBX.state.rpg
local TAG = "sbtools"
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
for _, name in ipairs({ "sandboxMouseDown", "sandboxMouseUp", "sandboxMouseMove", "sandboxDrawHUD", "sandboxTick" }) do
  R.hooks[name] = R.hooks[name] or {}
end

local floor, max, min = math.floor, math.max, math.min

-- ================================================================ state
R.sbt = R.sbt or {
  pickIdx = 1,        -- index into R.PICKS -- the tool this tester mines with
  axeMode = false,     -- opts.axe passthrough to R.actorMine (adds R.TOOLS.axe power on top)
  mineMode = false,    -- while on, left-click anywhere on the canvas test-mines that cell
                        -- instead of placing with the native brush
  matIdx = 1,          -- index into MATERIALS (rebuilt from R.MINEABLE below)
  mx = 300, my = 300,   -- last known CANVAS (non-panel) cursor position, used as the give-material
                          -- spawn point and the mining hover-info target -- see the mousemove hook
                          -- below for why this is deliberately NOT updated from every mousedown
  log = {},             -- last few result lines, newest first
  dummyInv = {},        -- where test-mined material actually goes (never R.inventory --
                        -- this must work with zero RPG session running)
}
local T = R.sbt

-- Rebuilt every load (not just once) so a material another lane adds to R.MINEABLE tonight
-- shows up here without needing this file touched -- same data-driven principle guide.lua's
-- own allElementCodes()/classMap() already use.
local MATERIALS = {}
for code in pairs(R.MINEABLE or {}) do MATERIALS[#MATERIALS + 1] = code end
table.sort(MATERIALS)
if T.matIdx > #MATERIALS then T.matIdx = 1 end
if T.pickIdx > #R.PICKS then T.pickIdx = 1 end

local function logLine(msg)
  table.insert(T.log, 1, msg)
  if #T.log > 4 then table.remove(T.log) end
end

-- ================================================================ mining test
-- A synthetic, non-player actor: R.actorMine already supports NPCs (a.isPlayer=false) banking
-- yield into a.inv instead of R.inventory -- exactly what a resource-free tester needs, and it
-- means this never touches (or requires) the player's real inventory/hotbar at all.
local function dummyActor()
  return { isPlayer = false, inv = T.dummyInv, tools = { pick = R.PICKS[T.pickIdx] } }
end

-- sx, sy are SCREEN/canvas coordinates (mouse position). R.actorMine takes WORLD coordinates
-- and converts world->canvas internally via `canvasOf(wx,wy) = wx - R.cam.x`; adding R.cam back
-- on here makes the round trip land on the exact pixel under the cursor regardless of what
-- R.cam currently holds (usually 0,0 in sandbox, but not guaranteed -- see R.enterSandbox/
-- R.sandboxWalk, both of which pin it to 0,0, but nothing forces it to stay that way forever).
local function mineAtScreen(sx, sy)
  local wx, wy = sx + R.cam.x, sy + R.cam.y
  local ok, success, info = pcall(R.actorMine, dummyActor(), wx, wy, { axe = T.axeMode })
  if not ok then logLine("ERROR: " .. tostring(success)); return end
  if success then
    logLine(string.format("MINED -> +1 %s (dummy inv now %d)", R.nice(info), T.dummyInv[info] or 0))
  else
    logLine(tostring(info))   -- "chipping" (partial hit), "needs a better pick", "cannot be mined", etc -- real R.actorMine reasons, not reworded
  end
end

-- ================================================================ give-material spawner
-- Places the RAW element directly (no inventory involved, same idea as sandbox.lua's own
-- worldgen sampler placing raw generated elements) -- variants use the same ctype-carrying
-- mechanism real melting/PWCR already use, verified live by @survival (LAVA+ctype="Molten X",
-- PWCR+ctype="Powdered X"), so R.partLabel/R.typeLabel name these exactly the way they would
-- name a naturally-melted or naturally-crushed particle -- this is not a second, parallel
-- naming path.
local MOLTEN_FALLBACK_TEMP = 1700   -- used only when the target has no HighTemperature transition
                                      -- of its own to read (see spawnGive("molten") below)
local function spawnGive(variant)
  local code = MATERIALS[T.matIdx]
  if not code then logLine("no material selected"); return end
  local x, y = floor(T.mx), floor(T.my)
  if x < 4 or x > 607 or y < 4 or y > 379 then logLine("cursor is off the canvas"); return end
  if sim.partID(x, y) then logLine(R.nice(code) .. ": cell occupied, clear it first"); return end
  local baseId = R.eid(code)
  if not baseId then logLine(code .. ": not a real element (no id)"); return end
  local placeId, ctype, temp = baseId, nil, nil
  if variant == "molten" then
    placeId = R.eid("LAVA")
    ctype = baseId
    local okh, hiT = pcall(elem.property, baseId, "HighTemperature")
    temp = (okh and type(hiT) == "number" and hiT > 0 and hiT < 30000) and (hiT + 60) or MOLTEN_FALLBACK_TEMP
  elseif variant == "powder" then
    placeId = R.eid("PWCR")
    ctype = baseId
  end
  if not placeId then logLine(variant .. " form unavailable (missing element id)"); return end
  local p = sim.partCreate(-1, x, y, placeId)
  if not p or p < 0 then logLine(R.nice(code) .. ": placement blocked"); return end
  if ctype then pcall(sim.partProperty, p, "ctype", ctype) end
  if temp then pcall(sim.partProperty, p, "temp", temp) end
  local label = R.partLabel(p)
  logLine("placed " .. label .. (temp and (string.format(" @ %.0fK", temp)) or ""))
end

-- ================================================================ tick: nothing gated needed here (sim.partID/property/create/kill are all safe from any context per sandbox.lua's own header discipline) -- kept only so the tag exists and reload dedupe has something to remove
hook(R.hooks.sandboxTick, function() end)

-- ================================================================ panel layout + hit-testing
-- Placed to the right of sandbox.lua's own toolkit panel (that one occupies x 4..214, y 4..204
-- after its own PH fix) so the two never overlap; only drawn/interactive while that panel is
-- open, since Tools is the one on-screen entry point into this whole toolkit.
local PX, PY, PW = 222, 4, 250
local function btn(x, y, w, h, label) return { x = x, y = y, w = w, h = h, label = label } end
local function layout()
  local b = {}
  local y = PY + 26
  b.pickMinus = btn(PX + 8, y, 16, 14, "-"); b.pickPlus = btn(PX + PW - 24, y, 16, 14, "+")
  y = y + 18
  b.axe = btn(PX + 8, y, PW - 16, 16, T.axeMode and "AXE BONUS: ON" or "AXE BONUS: OFF")
  y = y + 20
  b.mine = btn(PX + 8, y, PW - 16, 18, T.mineMode and "MINE MODE: ON (click canvas to mine)" or "MINE MODE: OFF (click to enable)")
  y = y + 24
  b.cursorInfoY = y
  y = y + 30
  b.matMinus = btn(PX + 8, y, 16, 14, "-"); b.matPlus = btn(PX + PW - 24, y, 16, 14, "+")
  y = y + 18
  b.givePlain = btn(PX + 8, y, 74, 16, "Plain")
  b.giveMolten = btn(PX + 88, y, 74, 16, "Molten")
  b.givePowder = btn(PX + 168, y, 74, 16, "Powdered")
  y = y + 22
  b.logY = y
  b.bottom = y + 60
  return b
end
local function hit(bt, x, y) return bt and x >= bt.x and x < bt.x + bt.w and y >= bt.y and y < bt.y + bt.h end
local function visible() return R.sbx and R.sbx.panelOpen and not R.feedbackOpen end
local function panelBottom() local b = layout(); return b.bottom end

-- ================================================================ mouse
hook(R.hooks.sandboxMouseDown, function(x, y, button)
  if not visible() then return end
  -- NOTE: deliberately does NOT do `T.mx, T.my = x, y` here. Found live (lab instance, both
  -- give-material buttons triggered): a naive top-of-handler position update stomps T.mx/T.my
  -- with the BUTTON's own click coordinates the instant Give Molten/Powdered/Plain is pressed,
  -- so material spawned under the panel itself instead of wherever the player was actually
  -- pointing on the canvas a moment before. T.mx/T.my is the last position seen OUTSIDE the
  -- panel (mousemove hook below); a click on a button must never move that target.
  local bottom = panelBottom()
  if x >= PX and x < PX + PW and y >= PY and y < bottom then
    if button ~= 1 then return true end
    local b = layout()
    if hit(b.pickMinus, x, y) then T.pickIdx = max(1, T.pickIdx - 1)
    elseif hit(b.pickPlus, x, y) then T.pickIdx = min(#R.PICKS, T.pickIdx + 1)
    elseif hit(b.axe, x, y) then T.axeMode = not T.axeMode
    elseif hit(b.mine, x, y) then T.mineMode = not T.mineMode; logLine(T.mineMode and "Mine mode ON -- click a placed particle" or "Mine mode OFF")
    elseif hit(b.matMinus, x, y) then T.matIdx = max(1, T.matIdx - 1)
    elseif hit(b.matPlus, x, y) then T.matIdx = min(#MATERIALS, T.matIdx + 1)
    elseif hit(b.givePlain, x, y) then spawnGive("plain")
    elseif hit(b.giveMolten, x, y) then spawnGive("molten")
    elseif hit(b.givePowder, x, y) then spawnGive("powder")
    end
    T._consumedDown = true
    return true
  end
  if button == 1 and T.mineMode then
    mineAtScreen(x, y)
    T._consumedDown = true
    return true
  end
  return
end)
hook(R.hooks.sandboxMouseUp, function(x, y, button)
  if T._consumedDown then T._consumedDown = false; return true end
  return
end)
hook(R.hooks.sandboxMouseMove, function(x, y, dx, dy)
  local bottom = panelBottom()
  if x >= PX and x < PX + PW and y >= PY and y < bottom then return end   -- over our own panel: not a canvas position, ignore
  T.mx, T.my = x, y
end)

-- ================================================================ draw
local function drawBtn(bt, active, primary)
  local bg = active and (primary and { 30, 80, 34 } or { 30, 70, 34 }) or { 26, 30, 46 }
  local border = active and { 140, 255, 140 } or { 110, 120, 150 }
  graphics.fillRect(bt.x, bt.y, bt.w, bt.h, bg[1], bg[2], bg[3], 235)
  graphics.drawRect(bt.x, bt.y, bt.w, bt.h, border[1], border[2], border[3], 255)
  graphics.drawText(bt.x + 4, bt.y + floor((bt.h - 7) / 2), bt.label, 220, 225, 235, 255)
end

hook(R.hooks.sandboxDrawHUD, function()
  if not visible() then return end
  local b = layout()
  local bottom = panelBottom()
  graphics.fillRect(PX, PY, PW, bottom - PY, 8, 10, 20, 225)
  graphics.drawRect(PX, PY, PW, bottom - PY, 120, 200, 255, 220)
  graphics.drawText(PX + 6, PY + 4, "MINING & TOOLS TESTER", 160, 220, 255, 255)
  graphics.drawText(PX + 6, PY + 16, "click a placed particle to mine it (Mine Mode on)", 170, 175, 190, 220)

  local pick = R.PICKS[T.pickIdx]
  drawBtn(b.pickMinus); drawBtn(b.pickPlus)
  graphics.drawText(PX + 28, b.pickMinus.y + 3, string.format("Pick: %s (tier %d)", pick.name, pick.power), 220, 225, 235, 255)
  drawBtn(b.axe, T.axeMode)
  drawBtn(b.mine, T.mineMode, true)

  -- cursor info -- live read, safe from draw (sim.partID/property have no interface-event guard, see sandbox.lua's own header)
  local cy = b.cursorInfoY
  local mx, my = floor(T.mx), floor(T.my)
  local pid = sim.partID(mx, my)
  if not pid then
    graphics.drawText(PX + 6, cy, "Under cursor: empty", 200, 200, 210, 255)
  else
    local label = R.partLabel(pid)
    local t = sim.partProperty(pid, "type")
    local nm = R.nameOf(t)
    local tier = R.MINEABLE[nm]
    graphics.drawText(PX + 6, cy, "Under cursor: " .. label, 200, 200, 210, 255)
    if not tier then
      graphics.drawText(PX + 6, cy + 12, "cannot be mined (no R.MINEABLE entry)", 255, 150, 130, 255)
    else
      local power = pick.power
      if T.axeMode then power = max(power, (R.TOOLS.axe or {}).power or 1) end
      if tier > power + 1 then
        graphics.drawText(PX + 6, cy + 12, string.format("tier %d -- needs a better pick (have tier %d)", tier, power), 255, 190, 120, 255)
      else
        local need = max(1, (R.HARD[nm] or 3) - (power - tier)); if tier > power then need = need * 2 end
        local hits = (R.blockHits and R.blockHits[pid]) or 0
        graphics.drawText(PX + 6, cy + 12, string.format("tier %d, pick tier %d -- %d/%d hits", tier, power, hits, need), 170, 230, 170, 255)
      end
    end
  end

  local mat = MATERIALS[T.matIdx] or "?"
  drawBtn(b.matMinus); drawBtn(b.matPlus)
  graphics.drawText(PX + 28, b.matMinus.y + 3, string.format("Material: %s (%s)", R.nice(mat), mat), 220, 225, 235, 255)
  drawBtn(b.givePlain); drawBtn(b.giveMolten); drawBtn(b.givePowder)

  local ly = b.logY
  graphics.drawText(PX + 6, ly, "Log:", 160, 220, 255, 255)
  for i, line in ipairs(T.log) do
    graphics.drawText(PX + 6, ly + 10 * i, line, 190, 220, 190, 220)
  end
end)
