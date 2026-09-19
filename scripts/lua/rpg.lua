-- POWDER RPG v4 - one continuous world with a scrolling camera (infinite sideways, ~1900px deep), sprite player, tools, bag GUI (2026-08-26).
-- Controls: A/D run  W jump  S fast-fall  Space pause (native TPT)  mouse aim  hold LMB place block  hold RMB use tool  Z = TPT zoom (native)
--           1-0 hotbar (1-5 tools, 6-0 blocks)  wheel  E bag/crafting  Esc  M minimap  N enemies  H HUD  K save  R respawn  F1 debug
PBX = PBX or {}; PBX.state = PBX.state or {}
local old = PBX.state.rpg
local R
if old and old.isolated and old.version == 4 then R = old else
  R = { isolated = true }
  if old then old.active = false; old.hud = false; R.inventory = old.inventory; R.deaths = old.deaths; R.seed = old.seed; R.TOOLS = old.TOOLS
    if old.handlers and event.unregister then for _, h in ipairs(old.handlers) do pcall(event.unregister, h[1], h[2]) end end
    if old.traceH then pcall(event.unregister, event.tick, old.traceH) end end
end
PBX.state.rpg = R
R.version = 4
local W, H = 612, 384
local DEPTH = 1900                   -- world bottom (bedrock from DEPTH-40)
-- sea level y=200 inlined at its single use (200-locals budget)
local idcache = {}
local function id(name)
  local i = elem["DEFAULT_PT_" .. name]
  if i then return i end
  -- The guide resolves the whole catalogue on first open. Scanning all 8192
  -- slots for EACH name (including non-element inventory items) took seconds
  -- and tripped the script watchdog. Build one name index per registry revision.
  if not idcache.__indexed then
    local names = {}
    for j = 0, (2 ^ ((sim and sim.PMAPBITS) or 9)) - 1 do
      local ok, n = pcall(elem.property, j, "Name")
      if ok and type(n) == "string" and names[n] == nil then names[n] = j end
    end
    names.__indexed = true
    idcache = names -- publish only a complete index, never a timed-out partial scan
  end
  return idcache[name] or nil
end
-- NEGATIVE-CACHE SELF-HEAL (2026-09-02). This cache used to store `false` for a missing
-- element FOREVER. Custom elements cannot be registered at load time -- elem.allocate/element/
-- property all assert unless called from a mutable-tools event (bridge_src/10_registry.lua:600),
-- so the registry replays its 64 elements on a later tick, AFTER rpg.lua has already run.
-- Every has() at this file's top level therefore asked before the answer existed, cached the
-- "no", and never asked again. Two independent audits measured the damage on a fresh install:
-- steel could not be crafted at all, and `local ROCK = has("BSLT") and "BSLT" or "BRCK"` fell
-- through to BRICK, so deep strata came out 44.66% BRCK / 41.71% ROCK -- the entire world's
-- primary stone was brick. That is the "too much brick" complaint, and it was never a worldgen
-- tuning problem.
-- Misses are still cached. R.clearIdCache() invalidates the complete name index
-- after registry changes, so newly registered elements and reused slots are visible.
-- The next custom lookup scans the slot table once, not once per catalogue entry.
R.clearIdCache = function()
  idcache = {}
  R.elementRevision = (R.elementRevision or 0) + 1
end
local function eid(name) local v = idcache[name]; if v == nil then v = id(name) or false; idcache[name] = v end; return v or nil end
local namecache = {}
local function nameOf(t) local n = namecache[t]; if n then return n end; local ok, v = pcall(elem.property, t, "Name"); n = ok and v or tostring(t); namecache[t] = n; return n end
local function has(name) return eid(name) ~= nil end

-- MOLTEN NAMING (2026-09-02). "My molten materials still are not being labeled properly. This is
-- a huge issue." The native Powder Toy HUD has actually been correct since 2019 -- @cpp proved
-- that, and disproved my own C++ patch, which turned out to be unreachable dead code. The real
-- cause is here, in the RPG's own Lua:
--   nameOf(t) takes a TYPE, not a particle. A molten particle's type IS PT_LAVA, and the original
--   material lives in its ctype -- which nameOf can never see. So every RPG-drawn surface that
--   names a material (48 call sites in this file alone, plus the plugins) says "LAVA" for molten
--   anything, and always has.
-- R.partLabel takes a particle id instead, so it can consult ctype and say "Molten Steel".
-- Falls back to the plain type name for everything else, so it is a safe drop-in wherever a
-- particle id is in hand.
function R.partLabel(p)
  if not p then return "" end
  local ok, t = pcall(sim.partProperty, p, "type")
  if not ok or not t or t == 0 then return "" end
  local okc, ct = pcall(sim.partProperty, p, "ctype")
  return R.typeLabel(t, okc and ct or 0)
end

-- Same idea for a bare (type, ctype) pair, for callers that have properties but no particle id.
-- Elements that are a STATE of some other material, carrying the real one in ctype. Naming any
-- of these by their own type is useless to a player: "PWCR" and "LAVA" tell you nothing, while
-- "Powdered Steel" and "Molten Steel" tell you everything. Reported directly: "when I'm spawning
-- my powders I don't want it to say PWCR, I want it to say what the material is."
R.CTYPE_FORMS = { LAVA = "Molten %s", PWCR = "Powdered %s", GLOW = "Glowing %s" }

function R.typeLabel(t, ct)
  if not t or t == 0 then return "" end
  local base = nameOf(t)
  local form = R.CTYPE_FORMS[base]
  if form and ct and ct > 0 then
    local okn, cn = pcall(elem.property, ct, "Name")
    if okn and cn and cn ~= "" then
      return string.format(form, (R.NAMES and R.NAMES[cn]) or cn)
    end
  end
  if form then
    -- No ctype: it is the generic form, not a specific material's state.
    if base == "LAVA" then return "Lava" end
    if base == "PWCR" then return "Powder" end
  end
  return (R.NAMES and R.NAMES[base]) or base
end

-- Real physics solidity (does this type actually block a gas particle?) -- deliberately
-- separate from PASS/solidW, which govern the PLAYER's own walk-through collision and
-- include real solids like GRSS/PLNT/WOOD/BLD on purpose (so you can walk through grass).
-- A gas particle doesn't care what the player can walk through.
local solidCache = {}
local function realSolid(t)
  if t == nil then return false end
  local v = solidCache[t]; if v ~= nil then return v end
  local ok, props = pcall(elem.property, t, "Properties")
  v = ok and bit.band(props, elem.TYPE_SOLID) ~= 0
  solidCache[t] = v; return v
end
local function countType(name)
  local t = eid(name); if not t then return 0 end
  local n = 0; for i in sim.parts() do if sim.partProperty(i, "type") == t then n = n + 1 end end
  return n
end
local function o2OnScreenCount()
  if R.frame % 24 ~= 0 and R._o2gCached then return R._o2gCached end
  R._o2gCached = countType("OXYG")
  return R._o2gCached
end
local colourCache = {}
local function colourOf(name)
  if colourCache[name] then return colourCache[name][1], colourCache[name][2], colourCache[name][3] end
  if R.ITEMS[name] then colourCache[name] = R.ITEMS[name].col; return R.ITEMS[name].col[1], R.ITEMS[name].col[2], R.ITEMS[name].col[3] end
  local t = eid(name); local r, g, b = 200, 200, 200
  if t then local ok, c = pcall(elem.property, t, "Colour"); if ok and type(c) == "number" then r, g, b = math.floor(c/65536)%256, math.floor(c/256)%256, c%256 end end
  colourCache[name] = {r, g, b}; return r, g, b
end
R.ITEMS = { FLASK = { col = {150, 220, 235}, desc = "Air bladder: fills itself in fresh air, then keeps you breathing underground or under water. Refill at the surface" },
            WORKBENCH = { col = {150, 100, 50}, desc = "Workbench: place it (right mouse) and stand near it to craft tools and kits" },
            FURNACE = { col = {120, 60, 40}, desc = "Furnace kit: place it, then light the coal inside with the torch. Smelts while it burns" },
            ANVIL = { col = {120, 120, 130}, desc = "Anvil: place it near your workbench to forge iron and steel tools" },
            -- Bug found 2026-08-29: R.ITEMS is the actual gate placeAt uses to decide
            -- "this is a structure kit, call buildStation" instead of trying to place
            -- it as a raw element. RESEARCH/ADVLAB were craftable (as of this session)
            -- but never added here -- so even after fixing the crafting-UI visibility
            -- bug, crafting either kit produced an item that silently could not be
            -- placed at all (fell through to eid("RESEARCH"), which is nil, no-op).
            RESEARCH = { col = {60, 120, 140}, desc = "Research Bench: place it near your workbench to unlock advanced material recipes" },
            ADVLAB = { col = {70, 90, 110}, desc = "Advanced Lab: place it near your Research Bench to unlock its recipes" } }
R.NAMES = { GOO="Dirt", GRNT="Granite", BSLT="Granite", GRSS="Grass", PLNT="Plant", WOOD="Wood", SAND="Sand", ICE="Ice", SNOW="Snow", CLST="Clay",
  COAL="Coal", BCOL="Coal dust", IRON="Iron ore", METL="Iron bar", STEL="Steel", GOLD="Gold", CU="Copper", DU="Uranium ore", URAN="Uranium", CNCR="Concrete",
  DMND="Diamond", QRTZ="Quartz", TTAN="Titanium", BRCK="Brick", GLAS="Glass", INSL="Insulation", WATR="Water", DSTW="Pure water", LAVA="Lava",
  BRMT="Bronze", BMTL="Scrap metal", PSCN="P-silicon", NSCN="N-silicon", TUNG="Tungsten", LEDL="LED lamp", WIFI="Wireless", B4C="Control rod", TRBN="Turbine",
  TEG="Thermo-gen", UO2="Fuel pellet", STNE="Stone", OIL="Oil", FIRE="Fire", GLOW="Glow", WORKBENCH="Workbench", FURNACE="Furnace kit", ANVIL="Anvil",
  -- Found 2026-08-29: R.nice()'s only fallback for an element with no entry here is
  -- the raw string itself -- there's no real-engine-name lookup. RESEARCH/ADVLAB
  -- (added rounds 1/4) fell back to an awkward auto-capitalized guess ("Advlab"),
  -- and GRPH (a real stock element, added round 4) showed its bare code with no
  -- fallback at all. STNE proves R.NAMES is genuinely the only mechanism for a
  -- readable name here, not something GRPH would get automatically over time.
  RESEARCH="Research Bench", ADVLAB="Advanced Lab", GRPH="Graphite",
  -- ADDED 2026-09-02 (@matimpl, design-material-progression.md): names for every material this pass
  -- made obtainable -- without an entry here R.nice() falls back to the raw code (see STNE note above).
  SLCN="Silicon powder", SWCH="Switch", INWR="Insulated wire", TESC="Tesla coil", ETRD="Electrode", DSTW="Distilled water",
  GUN="Gunpowder (raw)", TNT="TNT", FUSE="Fuse", IGNC="Ignition cord", FSEP="Fuse powder", TRON="Tron", THRM="Thermite", NITR="Nitroglycerin",
  PSTN="Piston", FRME="Frame", ACEL="Accelerator", DCEL="Decelerator", FRAY="Force emitter", RPEL="Repeller", PPIP="Powered pipe",
  SHLD="Shield tier 1", SHD2="Shield tier 2", SHD3="Shield tier 3", SHD4="Shield tier 4",
  DTEC="Detector", LDTC="Linear detector", PSNS="Pressure sensor", TSNS="Temperature sensor", SPNG="Sponge", VOID="Void", PVOD="Powered void", VENT="Vent" }
function R.nice(el) if not el then return "?" end; if el:find("^tool:") then return el:sub(6) end; return R.NAMES[el] or (R.ITEMS[el] and (el:sub(1,1) .. el:sub(2):lower())) or el end
local nice = R.nice
local function descOf(name) if R.ITEMS[name] then return R.ITEMS[name].desc end; local t = eid(name); if not t then return "" end; local ok, d = pcall(elem.property, t, "Description"); return ok and tostring(d) or "" end
local function say(msg) R.log = R.log or {}; table.insert(R.log, 1, {msg, R.frame or 0}); if #R.log > 5 then table.remove(R.log) end end
R.say = say
R.eid, R.nameOf, R.has, R.colourOf, R.descOf = eid, nameOf, has, colourOf, descOf
R.W, R.H, R.M = 612, 384, 4
-- SAFE AREA for panels: TPT's own HUD sits at the top and its toolbar at the bottom; plugins must draw inside this box
R.SAFE = { x = 4, y = 16, w = 604, h = 344 }   -- x..x+w, y..y+h
pcall(tpt.hud, 0)
-- Hide TPT's own element-selection menus while playing (Esc menu toggles them back for sandbox building)
-- Re-applies a menu toggle the engine previously refused. MUST be called from a real interface
-- event (key or mouse handler); that is the whole point of it existing.
function R.applyPendingMenus()
  if not R.tptMenusPending then return end
  local n = 0
  local ok = pcall(function() n = tpt.num_menus(false) end)
  if not ok or not n or n <= 0 then return end   -- still not an interface event; try again later
  for i = 0, n - 1 do pcall(tpt.menu_enabled, i, R.tptMenus and 1 or 0) end
  pcall(tpt.hud, R.tptMenus and 1 or 0)
  R.tptMenusPending = nil
  if PBX and PBX.log then PBX.log("menus", "native TPT menus restored on a real input event") end
end

function R.setTptMenus(on)
  R.tptMenus = on and true or false
  -- tpt.hud(0) at boot above hides the WHOLE native HUD, toolbar included --
  -- that's where the Open/stamp-browse button lives (Ctrl+click it to
  -- browse saved stamps), so without this it stayed unreachable even with
  -- the element menu back on. Tying it to the same toggle already used
  -- to mean "give me native TPT controls."
  pcall(tpt.hud, R.tptMenus and 1 or 0)
  -- num_menus() defaults to onlyEnabled=true — when menus were off that
  -- returned 0 and the enable loop never ran, so toggling ON left side
  -- palettes/categories hidden. Iterate every section index.
  -- ui.numMenus/ui.menuEnabled are "restricted to interface events" -- they only work inside a
  -- real click or keypress handler. Called from anywhere else (a hot reload, R.stop() driven from
  -- tooling, or enterSandbox triggered other than by the button) num_menus returns 0, the loop
  -- `for i = 0, -1` never runs, and NO menu is ever enabled -- silently. That is why the native
  -- element menu vanished in sandbox while R.tptMenus still reported true: the flag was set and
  -- the engine call had quietly done nothing.
  -- Verified live: ui.numMenus() -> "this functionality is restricted to interface events".
  -- So: try now, and if the engine refuses, mark it pending and re-apply on the next real input
  -- event (see applyPendingMenus, called from the key and mouse handlers).
  local n = 0
  local okN = pcall(function() n = tpt.num_menus(false) end)
  if not okN or not n or n <= 0 then
    R.tptMenusPending = true
  else
    R.tptMenusPending = nil
    for i = 0, n - 1 do pcall(tpt.menu_enabled, i, R.tptMenus and 1 or 0) end
  end
  -- Same click that toggles this used to leave R.mouse.l stuck. Clearing it
  -- here is why "TPT menus on then off" stopped the spam -- do it on purpose.
  if R.releaseMouse then R.releaseMouse() end
  return R.tptMenus
end
function R.toggleTptMenus()
  local on = not R.tptMenus
  pcall(R.setTptMenus, on)
  say(on and "TPT menus ON — side palettes & categories" or "TPT menus OFF — RPG hotbar mode")
  return on
end
function R.toggleSandbox()
  R.sandbox = not R.sandbox
  if R.sandbox then
    -- Unlock capability, do NOT stock the bag. Sandbox means "nothing is restricted",
    -- not "you now own 999 of all 120 materials" -- that buried the inventory grid in
    -- identical 999 cells and made taking a specific item from the guide pointless.
    -- Crafting still works with an empty bag: canAfford/spend/nearStation all bypass on
    -- the R.sandbox flag itself, not on holding materials.
    pcall(R.sandboxUnlock)
    -- Deliberately does NOT touch R.tptMenus. Sandbox and the native TPT
    -- menus are independent toggles: entering sandbox used to yank the side
    -- palettes on unasked, and the only way back was toggling TPT menus by
    -- hand every single time. Whatever the TPT menu state was, it stays.
    say("SANDBOX ON — no damage, free crafting, take what you want from the guide (L)")
  else
    -- Leaving sandbox should not dump a wall of 999s into a survival run. Clear only stacks
    -- sitting at exactly the sandbox stock value -- a real gathered stack is essentially
    -- never exactly 999, and anything you deliberately took from the guide and then spent
    -- down is below it and survives.
    -- ponytail: exact-999 marker heuristic; give sandbox-granted items a real flag if this
    -- ever misfires on a legitimately hoarded 999 stack.
    local cleared = 0
    local crafted = (R.stats and R.stats.crafted) or {}
    for k, v in pairs(R.inventory or {}) do
      -- 999 is the sandbox stock marker. Kits are also cleared when you never actually
      -- crafted them -- those came from a sandbox grant (some from the old vehicle hook
      -- that has since been removed entirely), and leaving them behind means carrying
      -- stock from a mechanism that no longer exists. Anything you really crafted has a
      -- R.stats.crafted record and survives; gathered raw materials are not R.ITEMS and
      -- are never touched.
      if v > 0 and (v == 999 or (R.ITEMS[k] and not crafted[k])) then
        R.inventory[k] = 0; cleared = cleared + 1
      end
    end
    if cleared > 0 then pcall(R.rebuildHotbar) end
    say("SANDBOX OFF — survival rules" .. (cleared > 0 and ("  (cleared " .. cleared .. " sandbox stacks)") or ""))
  end
  return R.sandbox
end
-- Top-right HUD quick toggles (layout refreshed each draw/click).
R._quickBtns = R._quickBtns or {
  { id = "tpt", label = "TPT", w = 40, h = 17, toggle = function() return R.toggleTptMenus() end,
    on = function() return R.tptMenus end },
  { id = "box", label = "SANDBOX", w = 64, h = 17, toggle = function() return R.toggleSandbox() end,
    on = function() return R.sandbox end },
  { id = "guide", label = "GUIDE", w = 48, h = 17, toggle = function()
      if R.guideOpen then if R.closeGuide then R.closeGuide() else R.guideOpen = false end
      else if R.openGuide then R.openGuide() end end
      return R.guideOpen end,
    on = function() return R.guideOpen end },
}
function R.layoutQuickBar()
  local x, y = 6, (R._hudLeftEndY or 82) + 6
  for _, b in ipairs(R._quickBtns) do
    b.x, b.y = x, y
    y = y + b.h + 3
  end
end
function R.drawQuickBar()
  if not R.hud or R.titleScreen or R.menuOpen then return end
  R.layoutQuickBar()
  for _, b in ipairs(R._quickBtns) do
    local on = false
    if b.on then local ok, v = pcall(b.on); on = ok and v end
    local hov = R.mouse.x >= b.x and R.mouse.x < b.x + b.w and R.mouse.y >= b.y and R.mouse.y < b.y + b.h
    local br, bg, bb = 28, 30, 48
    if on then br, bg, bb = (b.id == "box" and 92 or 34), (b.id == "box" and 58 or 72), (b.id == "box" and 28 or 48) end
    if hov then br, bg, bb = br + 24, bg + 24, bb + 36 end
    graphics.fillRect(b.x, b.y, b.w, b.h, br, bg, bb, 235)
    local er, eg, eb = on and 140 or 90, on and 220 or 110, on and 120 or 130
    if b.id == "box" and on then er, eg, eb = 255, 180, 80 end
    if hov then er, eg, eb = 255, 230, 120 end
    graphics.drawRect(b.x, b.y, b.w, b.h, er, eg, eb, 255)
    local tw = #b.label * 6
    -- math.floor, not the file-local `floor`: that local is declared at line ~929, far BELOW
    -- this function, so referencing it here compiled as a nil GLOBAL and this drawText threw
    -- every single frame -- which is why the SANDBOX/TPT/GUIDE quick buttons were clickable
    -- but completely invisible. Same class as drawMenu/wrap/menuWrap/give/LIFESUPPORT_RANGE.
    graphics.drawText(b.x + math.floor((b.w - tw) / 2), b.y + 4, b.label, on and 255 or 200, on and 255 or 210, on and 240 or 220, 255)
  end
end
function R.quickBarClick(x, y)
  if not R.hud or R.titleScreen or R.menuOpen then return false end
  R.layoutQuickBar()
  for _, b in ipairs(R._quickBtns) do
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
      if b.toggle then pcall(b.toggle) end
      if R.releaseMouse then R.releaseMouse() end
      return true
    end
  end
  return false
end
if R.tptMenus == nil then R.tptMenus = false end
-- Fast mode: air pressure/velocity simulation costs ~25% of the frame rate and is only needed for
-- steam/pressure machines, so it is off by default and machines can switch it on while they run.
function R.setFast(on)
  R.fast = on and true or false
  if R.fast then pcall(sim.airMode, 3); pcall(sim.waterEqualisation, 0)
  else pcall(sim.airMode, 0); pcall(sim.waterEqualisation, 1) end
  return R.fast
end
if R.fast == nil then R.fast = true end
pcall(R.setFast, R.fast)
pcall(R.setTptMenus, R.tptMenus)                              -- hide TPT's fps/pressure readout while the game runs (restored by R.stop)
-- Bullets must read against sand, rock and dark caves: give the projectile elements tracer colours.
-- Fire, steam, sparks and hot things render with TPT's real effect pipeline instead of flat pixels
R.fxOn = (R.fxOn == nil) and true or R.fxOn
R.origRender = R.origRender or { ren.renderModes(), ren.displayModes() }
function R.setFX(on)
  R.fxOn = on and true or false
  if R.fxOn then pcall(ren.renderModes, { ren.RENDER_BASC, ren.RENDER_FIRE, ren.RENDER_GLOW, ren.RENDER_BLUR, ren.RENDER_EFFE }); pcall(ren.displayModes, { ren.DISPLAY_EFFE })
  else pcall(ren.renderModes, R.origRender[1]); pcall(ren.displayModes, R.origRender[2]) end
  return R.fxOn
end
-- SANDBOX LOOKS LIKE STOCK POWDER TOY. Reported: spawning the character "makes all the
-- materials and everything I'm using look shitty."
-- Two RPG-only presentation changes were leaking into sandbox, and both re-applied on EVERY
-- core reload (which happens constantly during development, so it kept coming back):
--   1. R.setFX swaps the renderer to FIRE/GLOW/BLUR/EFFE + DISPLAY_EFFE. That is the RPG's
--      look; on a build canvas it just makes every material smeary and wrong.
--   2. BMTL and BRMT get recoloured for RPG legibility.
-- Sandbox is meant to BE Powder Toy, so it keeps the stock renderer and the stock colours.
if R.sandboxMode then
  pcall(R.setFX, false)
  for name, col in pairs(R.origColours or {}) do
    local id = elem["DEFAULT_PT_" .. name]
    if id then pcall(elem.property, id, "Colour", col) end
  end
else
  pcall(R.setFX, R.fxOn)
  R.origColours = R.origColours or {}
  for name, col in pairs({ BMTL = 0xFFF060, BRMT = 0xFF9030 }) do
    local id = elem["DEFAULT_PT_" .. name]
    if id then if R.origColours[name] == nil then R.origColours[name] = elem.property(id, "Colour") end
      pcall(elem.property, id, "Colour", col) end
  end
end
-- plugin hook API: plugins append callables to these lists (see scripts/lua/rpg_plugins/README.md)
-- IN-GAME CHAT: press Enter to talk to your colonists. Plugins/drivers read R.chatPending() and reply
-- with R.chatSay(who, text); everything is plain data so a local model can drive it over the bridge.
-- IN-GAME FEEDBACK: F8 (or Esc menu) opens a text box for a bug report or
-- suggestion. Always saved locally to feedback.txt next to the game (works
-- with zero setup); also POSTed to R.FEEDBACK_WEBHOOK if one is filled in
-- (a Discord channel webhook URL, say) so reports show up automatically
-- instead of someone having to remember to send the file over.
-- SECRET, NOT IN SOURCE (changed 2026-09-01). This line used to hold the literal
-- Discord webhook URL, and rpg.lua is TRACKED AND PUSHED to the public repo
-- (github.com/phoenixfire808/Powder-RPG, branch rpg-and-realism) -- it was committed in
-- 51241e68 and was still live in HEAD, so anyone who cloned the repo could post into the
-- Discord channel. That URL is burned and must be regenerated in Discord.
-- The webhook now loads from a gitignored file next to the game instead, so a fresh URL
-- can never be committed by accident. Put the new URL, alone on one line, in:
--     D:/The-Powder-Toy/build/feedback_webhook.txt
R.FEEDBACK_WEBHOOK = ""
do
  local wf = io.open("feedback_webhook.txt", "r")
  if wf then
    local url = (wf:read("*l") or ""):gsub("%s+$", "")
    wf:close()
    if url:match("^https://") then R.FEEDBACK_WEBHOOK = url end
  end
end
R.feedbackOpen = false
R.feedbackText = R.feedbackText or ""
R.pendingHttp = R.pendingHttp or {}   -- keeps async http.post() handles alive until they finish
function R.submitFeedback(text)
  if not text or text == "" then return end
  local f = io.open("feedback.txt", "a")
  if f then
    f:write(string.format("[%s] seed=%s day=%s frame=%s\n%s\n\n", os.date("%Y-%m-%d %H:%M:%S"), tostring(R.seed), tostring(R.day), tostring(R.frame), text))
    f:close()
  end
  if R.FEEDBACK_WEBHOOK ~= "" and http and http.post then
    local ok, body = pcall(json.stringify, { content = "**Powder Toy RPG feedback:**\n" .. text })
    if ok then
      -- Discord silently drops a webhook POST sent with a default/blank User-Agent (verified:
      -- it still answers 204, the message just never appears in the channel). Same header
      -- R.checkForUpdate already sends GitHub with, below, for the identical reason.
      local ok2, handle = pcall(http.post, R.FEEDBACK_WEBHOOK, body, { { "Content-Type", "application/json" }, { "User-Agent", "PowderToyRPG" } })
      if ok2 and handle then R.pendingHttp[#R.pendingHttp + 1] = handle end
    end
    say("Feedback saved and sent - thanks!")
  else
    -- No webhook file is shipped in a downloaded copy, deliberately (see the comment above
    -- R.FEEDBACK_WEBHOOK) -- without this branch feedback silently went nowhere but this
    -- player's own disk. Open a pre-filled GitHub issue instead of a no-op.
    local ok, err = R.openBrowserURL(R.buildGithubIssueURL("Feedback: " .. text:sub(1, 80), text, "player-feedback"))
    if ok then
      say("Feedback saved locally, and a GitHub issue draft just opened in your browser - click Submit issue there to actually send it.")
    else
      say("Feedback saved locally only - could not open your browser (" .. tostring(err) .. "). Copy feedback.txt and send it yourself.")
    end
  end
end
-- STAMP SUBMISSIONS -> DISCORD (added 2026-09-01).
-- Community submissions were being written ONLY to build/stamp_submissions/manifest.jsonl,
-- i.e. to the submitting player's own disk, so for anyone who downloads the game the
-- submission never reaches PhoenixFire808 at all. This routes them to the same Discord
-- webhook the F8 feedback box already uses: no server, no hosting cost, and Discord supplies
-- notification and moderation for free.
-- Dual-audience format: a readable summary to skim in the channel, then the exact manifest
-- JSON line in a fenced block so it can be pasted straight into manifest.jsonl or parsed.
function R.submitStampToDiscord(rec)
  if type(rec) ~= "table" then return false, "bad record" end
  local url = R.FEEDBACK_WEBHOOK or ""
  if url == "" then return false, "no webhook configured" end
  if not (http and http.post) then return false, "http unavailable" end
  local cat  = tostring(rec.category or "other")
  local ctx  = tostring(rec.context or "")
  local id   = tostring(rec.id or "?")
  local w    = tonumber(rec.w) or 0
  local h    = tonumber(rec.h) or 0
  local els  = rec.elements_str or ""
  local line = tostring(rec.manifest_line or "")
  local head = (cat == "bug" and "BUG REPORT")
            or (cat == "suggestion" and "SUGGESTION")
            or ("DESIGN SUBMISSION (" .. cat .. ")")
  local body = "**" .. head .. "**\n"
    .. "> " .. ctx:gsub("\n", "\n> ") .. "\n"
    .. "id `" .. id .. "` | size " .. w .. "x" .. h
    .. (els ~= "" and (" | elements: " .. els) or "")
    .. " | seed " .. tostring(R.seed) .. " | day " .. tostring(R.day)
    .. " | v" .. tostring(R.VERSION) .. "\n"
    .. "```json\n" .. line .. "\n```"
  local okj, payload = pcall(json.stringify, { content = body })
  if not okj then return false, "encode failed" end
  -- Same silent-204-drop bug as R.submitFeedback above: Discord needs a real User-Agent.
  local ok2, handle = pcall(http.post, url, payload, { { "Content-Type", "application/json" }, { "User-Agent", "PowderToyRPG" } })
  if not ok2 or not handle then return false, tostring(handle) end
  R.pendingHttp[#R.pendingHttp + 1] = handle
  return true
end
-- Poll/release pending webhook requests so the async handle doesn't get
-- garbage-collected (which cancels it) before the request actually finishes.
function R.pumpFeedbackHttp()
  if #R.pendingHttp == 0 then return end
  local keep = {}
  for _, h in ipairs(R.pendingHttp) do
    local ok, status = pcall(h.status, h)
    if ok and status == "running" then
      keep[#keep + 1] = h
    elseif ok and status == "done" then
      pcall(h.finish, h)   -- releases it; response body isn't needed
    end
    -- "dead" (or a pcall failure): just drop it, nothing left to release
  end
  R.pendingHttp = keep
end

-- GITHUB-ISSUE FALLBACK (added 2026-09-02, @submission). Every downloaded copy ships with NO
-- feedback_webhook.txt -- correctly: it's a bearer credential (see the comment above
-- R.FEEDBACK_WEBHOOK), and a webhook URL baked into a public release zip is exactly the same
-- mistake as committing it to the repo, just harder to rotate once it's out. That means
-- R.submitFeedback/R.submitStampToDiscord had NO delivery path at all for anyone who isn't
-- running his own dev machine -- both silently degraded to "saved to this player's own disk
-- and nothing else", which is indistinguishable from broken. This opens a pre-filled "New
-- issue" page on his public repo in the OS default browser instead: zero secret shipped, zero
-- server to host or pay for, fully attributable (a real GitHub account per report), and --
-- unlike a relay -- provable end-to-end right now with no deployment step. Uses the exact same
-- os.execute('start "" ...') R.applyUpdate() (below) already proves works from this sandboxed
-- Lua on a shipped Windows build. A relay (Cloudflare Worker holding the webhook server-side)
-- is a legitimate future upgrade if he wants tighter abuse control than "needs a GitHub
-- account" gives for free -- see knowledge/submission-delivery.md for that design, deliberately
-- NOT built here since it would ship unproven with no way to deploy or test it from this seat.
function R.urlEncode(s)
  s = tostring(s or ""):gsub("\r\n", "\n")
  s = s:gsub("[^%w %-%_%.%~]", function(c) return string.format("%%%02X", c:byte()) end)
  return (s:gsub(" ", "%%20"))
end
-- Windows' own command-line length cap (~8191 chars total for the `start` invocation) and
-- GitHub's own URL length limit both mean a long description has to be truncated before it
-- goes into the query string -- the FULL text is still saved locally either way (feedback.txt /
-- stamp_submissions/manifest.jsonl); this only bounds what's pre-filled in the browser.
R.GITHUB_ISSUE_BODY_CAP = 1500
function R.buildGithubIssueURL(title, body, labels)
  title = tostring(title or "Powder RPG submission"):sub(1, 120)
  body = tostring(body or "")
  if #body > R.GITHUB_ISSUE_BODY_CAP then
    body = body:sub(1, R.GITHUB_ISSUE_BODY_CAP) .. "\n\n[...truncated for the URL, full text saved locally]"
  end
  local url = "https://github.com/" .. R.UPDATE_REPO .. "/issues/new?title=" .. R.urlEncode(title) .. "&body=" .. R.urlEncode(body)
  if labels and labels ~= "" then url = url .. "&labels=" .. R.urlEncode(labels) end
  return url
end
-- Opens `url` in the OS default browser. Windows-only ('start') -- the whole release is a
-- Windows zip (see the task brief / AGENTS.md), same assumption R.applyUpdate() already makes.
-- Returns false with a REAL reason on any failure (os.execute missing/blocked, launch failing)
-- so a caller can show that honestly instead of claiming a browser opened when nothing did --
-- the exact "make failure visible" requirement this whole fallback exists to satisfy.
function R.openBrowserURL(url)
  if type(url) ~= "string" or url == "" then return false, "empty url" end
  if not os.execute then return false, "os.execute unavailable" end
  local ok, code = pcall(os.execute, 'start "" "' .. url .. '"')
  if not ok then return false, tostring(code) end
  -- Lua 5.1's os.execute returns the raw OS exit code (0 == success); some LuaJIT builds
  -- instead return true/nil for a shell that ran successfully -- accept either "clearly ok"
  -- shape, only fail on an explicit non-zero/false result.
  if code == false or (type(code) == "number" and code ~= 0) then return false, "exit code " .. tostring(code) end
  return true
end

-- VERSION + SELF-UPDATE: shown on screen always (bottom-left corner) so
-- anyone watching knows exactly what build is running. Checks GitHub once
-- on startup for a newer build; if one exists, pops up a changelog dialog
-- (parsed from the release notes' "Changes:" section) so the player can see
-- what's new before choosing U (update now) or Esc (dismiss, corner hint
-- stays so they can still update later). Update itself downloads the new
-- release zip, hands off to a small batch script to extract it over this
-- copy once the game has actually closed (can't overwrite its own
-- .exe/.dll files while they're still running), and relaunches
-- automatically. Every release, bump R.VERSION AND write the GitHub release
-- notes as:
--   Version: X
--
--   Changes:
--   - one line per change
--
--   Ready-to-run build. ...
-- The "Version:" line drives update detection; the "Changes:" ... "Ready-
-- to-run" span is exactly what the in-game changelog dialog shows.
-- CUSTOM ELEMENT CAP (2026-09-01). PBX.MAX_CUSTOM_ELEMENTS lives in the bridge
-- (bridge_src/00_util.lua -> autorun.lua), which only loads at game START -- so raising it
-- there cannot take effect without a restart, and a runtime override is wiped by the next
-- core reload. Setting it here means every hot-reload of rpg.lua restores it, no restart.
-- Why 160 and not 40: the old 40 came from "TPT has 256 ids, ~213 stock; 40 leaves margin",
-- which counted only the ONE-BYTE id range. elem.allocate already falls back to ids
-- 256..PT_NUM-1 (PT_NUM = 512, PMAPBITS = 9) and GameSave round-trips two-byte types, so
-- ~299 ids were sitting unused behind a self-imposed cap. With 40, the 71-material catalogue
-- lost the competition for slots against machines/creatures and the underground collapsed to a
-- single rock type -- BSLT and CNCR simply could not register.
-- Measured: cap 40 -> 160 took live custom elements 40 -> 60+ and priority-1 materials 4/29 -> 28/29.
if PBX and PBX.MAX_CUSTOM_ELEMENTS and PBX.MAX_CUSTOM_ELEMENTS < 160 then
  PBX.MAX_CUSTOM_ELEMENTS = 160
end
R.VERSION = "1.18.0"
R.O2_BREATH_R = 48       -- pixel radius: HUD circle + O2 particle sample (tune ventilation against this)
R.O2_BREATH_CY = -8      -- sample center offset from feet (chest height)

-- LOCAL DEV CHANGELOG: separate from the GitHub update-checker below, and
-- doesn't need one -- that system only ever shows something once a real
-- release is published, which is far too slow a loop for "show me what
-- changed on THIS restart, accumulating every time." This just compares
-- R.VERSION against a version string saved to a tiny local file the last
-- time the popup was dismissed, and shows every entry newer than that,
-- stacked -- same shape as the GitHub changelog dialog, but instant and
-- local. Bump R.VERSION and add ONE new entry (newest first) here every
-- time a batch of fixes goes out; skip several restarts without playing and
-- they all show up together next time, exactly like the GitHub one does
-- across skipped releases.
R.CHANGELOG = {
  { ver = "1.17.2", notes = {
    "Fixed: bug/suggestion reports (F8) and community stamp submissions (Y) went completely nowhere for every downloaded copy of the game -- they only ever saved to your own disk, and the game still told you 'Submitted, thanks!' either way. A downloaded copy has no way to carry the Discord link safely (it's a credential, not a password we can hand out), so submitting now opens a pre-filled GitHub issue in your browser instead -- no account needed to see it, one click to actually send it in. If it can't reach Discord or can't open your browser, it now says so plainly instead of pretending it worked.",
    "Fixed: even on a build with Discord configured, the webhook post was silently dropped by Discord itself -- it wants a real User-Agent header and wasn't getting one.",
  } },
  { ver = "1.17.0", notes = {
    "EVERY ELEMENT NOW HAS A WAY TO GET IT. 150 of the game's 195 Powder Toy elements are now obtainable -- up from 71 this morning. Six new acquisition systems cover fluids, solids, energy, exotics, foraging and extraction machines. The remaining 45 are either deliberately not items (sparks, fire, your own character, the eraser) or still on the list, and the guide now marks those honestly instead of hiding them.",
    "New: Isotope-Z is made by melting solid isotope in a furnace, and frozen back by chilling it in the Advanced Lab -- a real phase change the engine was already simulating.",
    "New: Plutonium is bred from Platinum + solid isotope at the Advanced Lab (reactor-tier), using a real reaction that already existed in the engine.",
    "New: Isotope Forge (reactor-tier) slowly produces Polonium and a second route to Plutonium.",
    "New: Exotic Forge (reactor-tier) slowly produces Singularity and Antimatter. Never required to finish the game.",
    "New: EMP charges, instant conductors, NTC/PTC thermistors, WireWorld wire, gravity pumps, heat switches and pressure pumps are all craftable at the Research Bench and Advanced Lab.",
    "New: Powered clone and powered breakable clone (reactor-tier, one each per world, permanently locked to duplicating Steel only so they can never break progression).",
    "New: five things the engine was already making but you could never pick up are now collectable -- vines, sawdust (from chopping wood hard), broken glass, powdered quartz, and broken electronics from EMP blasts.",
    "New: 20 more craftable solids including ceramic, rime, stone and dust, several using real chemistry the engine already runs.",
    "New: Noble Gas Extractor, Brine Electrolysis Cell, Ore Reduction Furnace and Isotope Enrichment Centrifuge -- machines that turn raw material into the things recipes ask for.",
    "New: Scrap Compactor, Guardian Post, Lightning Rod and a reactor-gated Curio Vault for the strangest elements in the game.",
    "Fixed: the Replicator Core -- the game's FINAL unlock -- needed 4 Diamond when only 3 can be reliably obtained, so it was only reachable if a rare chest happened to spawn. Now costs 3. Same bug as the diamond pick, caught by an automated check this time instead of by you hitting it.",
    "Fixed: after restarting the game, Steel, Copper, Zirconium, Lead, Basalt, Concrete and several other materials silently stopped existing -- the game cached the fact they were missing at startup and never looked again, so half the mid-game economy quietly died. It now recovers properly.",
    "Guide: every element in the game is now browsable, including ones with no recipe yet -- those are dimmed and marked so you can see what is still missing rather than wondering.",
    "Guide: material pages now say how you actually get something -- mine it, craft it, forage it, or receive it -- and mining coal dust correctly says it yields Coal.",
  } },
  { ver = "1.16.6", notes = {
    "New AUTOMATION tier (@automation): Life sensor, Velocity sensor and Delay conductor are now craftable at the Research Bench; Ray Emitter and Particle Ray Emitter at the Advanced Lab. The game has had Powder Toy's whole logic and sensor toolkit sitting unused this entire time -- it is now a real tech tier you can build with.",
    "New: sensor calibration -- right-click any placed temperature, pressure, life, velocity or delay sensor and set its real trigger threshold with the scroll wheel. The physics was always being simulated; now you can read it.",
    "New buildable kit: Thermal Alarm -- a real temperature sensor wired to a lamp that trips when something hotter than its threshold comes near (default 100C).",
    "New buildable kit: Pressure Switch -- a real pressure sensor latched to a switch, so you can finally automate the boiler-steam-turbine chain instead of babysitting it.",
    "New buildable kit: Sensor Vault Door -- a detector calibrated to a material (gold by default) that opens only for the right thing.",
    "Guide (@guide): added a MATERIAL BROWSER -- 12 category tabs covering every element the game can give you, with what it is, where it occurs, and what tool tier digs it.",
    "Guide (@guide): added a PROGRESSION view -- the full tier ladder with your current tier computed live, so you can see what the next one actually unlocks.",
    "Guide (@guide): fixed the progression view claiming you were at the top tier while in sandbox with nothing built.",
    "Power (@lead): switches now count as real conductors. A switched-on SWCH genuinely conducts in the engine but the power grid was not counting it, so any circuit routed through a switch silently mis-reported its wattage.",
  } },
  { ver = "1.16.5", notes = {
    "Fixed a real deadlock: Thermite and Nitroglycerin rounds were already selectable as ammo for kinetic weapons (the musket, shotgun, nail gun, rail gun, harpoon and more) but could never actually be obtained -- go smelt Thermite at a lit furnace (Iron bar + Coal) or brew Nitroglycerin there too (Dirt, GOO), and load them into any kinetic gun for real incendiary/explosive rounds.",
    "New Electronics tier at the Workbench and Research Bench: Switch (on/off circuit gating), Insulated Wire, Silicon powder (smelted from Sand), Tesla Coil and Electrode -- go test wiring a Switch into a grid branch to kill power to just part of it.",
    "New Demolition tier: craft raw Gunpowder from Clay at the furnace, then TNT (Gunpowder + Salt) for real one-shot blast mining -- also added Fuse, Ignition Cord and Fuse Powder for controlled-delay charges, and Tron seeking-ammo at the Research Bench.",
    "Fixed Salt being produced by the Salt Evaporator and Desalinator but impossible to actually mine up -- go pick up the Salt crystals in the evaporator's pan with your pick, same as any other ore.",
    "New Force-Field Automation tier at the Research Bench: real Piston + Frame (pushes a mass of particles, not just loose powder), plus Accelerator/Decelerator/Force-emitter/Repeller for contactless material handling, and a switchable Powered Pipe.",
    "New Shield Defense ladder: craft Shield tier 1 at the Research Bench, tier 2 on top of that, tier 3 at the Advanced Lab, and tier 4 once your reactor goes online -- four real, placeable barrier tiers that grow around a spark and absorb damage before breaking.",
    "New Sensor/Automation Safety tier at the Research Bench: Detector, Linear Detector, Pressure Sensor and Temperature Sensor for wiring real early-warning alarms and shutoffs -- plus a cheap Sponge, Void, Powered Void and Vent for early flood-control and waste disposal.",
  } },
  { ver = "1.16.4", notes = {
    "Mountains (@lead): you can finally climb over them. The world always generated real terrain up to about 755px above sea level, but the camera was clamped at 300px -- so you hit an invisible ceiling less than half way up a mountain that was actually there. Raised to 900px, with the companion pathfinder raised to match so it will follow you up.",
    "Materials (@lead): the underground had quietly collapsed to a single rock type. The game wants 71 materials but the custom-element registry was capped at 40 -- a self-imposed limit that only counted half the ids the engine actually allows -- so Basalt, Concrete, Copper, Steel, Lead, Zirconium and Quartz were all failing to register and every stone fell back to plain Brick. Cap raised; those are all back, and priority materials went from 4 of 29 live to 28 of 29.",
    "Terrain (@worldgen): rock strata are now tinted by depth and topsoil carries embedded rock flecks, so the underground reads as layered ground instead of one flat colour.",
  } },
  { ver = "1.16.3", notes = {
    "Flat world (@lead): New World -> Map type now has a \"Flat (no terrain)\" option. No hills, no caves, no biome noise, no trees, no structures -- just solid ground and you, standing on it. Cycle Map type past Swamp to reach it. Good for messing about, testing machines, or building without the world in the way.",
  } },
  { ver = "1.16.2", notes = {
    "Magnetic Accelerator (@deadlock): the anvil recipe was permanently uncraftable -- it needed N-silicon, which nothing in the game ever gave you. N-silicon is now craftable at the Workbench (Gold + Glass), same as its P-silicon counterpart right next to it.",
    "Tungsten Sniper (@deadlock): both the build cost AND the ammo needed Tungsten, which nothing in the game ever gave you -- the gun could never be built, and if it somehow existed it could never be fired. Tungsten is now craftable at the lit Furnace (Steel + Coal).",
    "Diamond pick (@deadlock): the anvil recipe needed 4 Diamond, but the two quest rewards that give Diamond only ever add up to 3 -- one short, permanently, unless you got lucky with a rare chest drop. Reduced the recipe to 3 Diamond so finishing the Titanium and Steel-pick quests is always enough on its own.",
    "Refined gold (@deadlock): removed the furnace recipe that turned 1 Gold + 1 Coal into 1 Gold -- it did nothing but burn your coal, since mined gold and 'refined' gold were always the same item.",
  } },
  { ver = "1.16.1", notes = {
    "Multiplayer (@multiplayer): new 'Multiplayer' button on the title screen -- host your own game or join a friend's using a shared session code (nobody can join without it).",
    "Multiplayer (@multiplayer): in-game chat now works across a multiplayer session -- press Enter to talk exactly like always, and your friend sees it and can reply.",
    "Multiplayer (@multiplayer): a guest's inventory and progress now saves and reloads with the session instead of resetting every time they rejoin -- the host still owns the actual world.",
    "Deep-zone crafting (@survival): titanium plates, uranium fuel pellets, and both the reactor and RTG power kits are craftable again. All four needed a material that nothing in the game ever actually gave you (a leftover token from before uranium ore existed under its current name); they now draw on the same uranium ore you already mine.",
    "World (@world): fixed PhoenixFire808's own report of 'giant iron blocks in the middle of stuff' -- underground vaults and shrines were spawning much closer to the surface than they were designed to, so they read as a broken metal box dropped into normal dirt. They now stay buried at the depth they were built for.",
    "World (@world): trees no longer read as buried in the ground or floating with exposed roots, and dirt no longer speckles with stray air pockets near tree bases -- both traced to the same root cause (ground height was tested from the wrong spot for wide trunks), now fixed at every column under a tree instead of just its anchor point.",
    "World (@world): desert sand is solid ground again -- it now sits as a shallow loose layer over solid rock instead of a bottomless pit of falling sand, and caves can no longer open up directly underneath the sand cap. Verified in the world generator itself; go check out a fresh desert and let us know how it looks in person.",
    "Camera zoom (@camera): Ctrl+Up / Ctrl+Down to zoom in on your character, up to 4x, actually works now -- it shipped a few versions back but the engine half wasn't linked in yet. It is now.",
    "Sandbox mode (@ux): turning sandbox on no longer force-hides your normal TPT menus and toolbar -- that's its own independent setting now, so however you left it stays how it is.",
    "New (@ui): press Y anywhere in normal play to submit something straight to the dev team -- drag-select a region of the world and send it in as a proposed machine, plant, cave, terrain, building or item design, or just press Enter with nothing selected to file a quick bug report or suggestion, no screenshot needed.",
    "Quest log (@ui): the granite/stone-pick quest hints no longer hardcode a cost that can drift out of date -- they now always show the real live numbers, the same bug class that caused the granite deadlock in the first place, just in the hint text this time.",
    "Internal cleanup (@world): removed a leftover developer debug-export tool from world generation. No effect on play.",
  } },
  { ver = "1.15.109", notes = {
    "Granite/stone pick (@survival, straight off PhoenixFire808's report -- 'granite seemed uneasy to find so that's a huge problem'): GRNT was a phantom token. It was never placed by worldgen (genBase() only ever returns soil/COAL/IRON/CU/GOLD/QRTZ/DU-URAN/DMND/TTAN/ROCK -- no GRNT), never output by any recipe or machine, and its only two sources in the whole game were two one-time quest rewards (16 GRNT lifetime, total -- less than the Furnace kit's own need of 20). The stone pick and Furnace kit needed GRNT to craft, so both were permanently uncraftable for every player, blocking the entire tool tier and everything gated behind it (iron/steel/diamond picks, the anvil, research bench, advanced lab). Retargeted both recipes' need= from GRNT to the existing ROCK local (the real, always-solid fallback rock worldgen fills the underground with, resolved to BSLT in this build) and the two quest rewards that used to hand out dead GRNT now hand out ROCK instead, right before the quests that need it. Separately: ROCK/BSLT itself was missing from R.MINEABLE, so even the correct material was hard-blocked from being mined at all ('cannot be mined') -- a second, independent bug. Added a BSLT entry to R.MINEABLE/R.HARD at the same tier GRNT used to have, so the wood pick can mine it slowly (matching its own flavor text) and the stone pick mines it at full speed. Gave BSLT the display name 'Granite' (R.NAMES) so existing quest/UI text describing 'Granite' is now accurate without touching any other file. No bootstrap deadlock: the wood pick (power=1, craftable from WOOD alone) can mine tier-2 BSLT under the tier<=power+1 rule. rpg.lua R.PICKS/R.RECIPES/R.QUESTS/R.MINEABLE/R.HARD/R.NAMES.",
  } },
  { ver = "1.15.108", notes = {
    "Oxygen (@survival): confirmed the 2026-08-31 breathing fix is live and working -- with real OXYG particles in your breath circle (or open unsealed air), oxygen refills all the way to 100, not partway. Verified live: forced a character down to 30-40 oxygen, watched it climb back to exactly 100 in real elapsed frames.",
    "Ventfan (@survival): the ventfan machine never actually reduced gas. It pushed CO2/SMKE along its duct (vx=2.4) but, unlike the scrubber next to it, never killed the particle -- so it relocated gas forever and never removed any, despite its own item text promising it \"vents\" gas. It now kills the gas particle once it reaches the far end of the duct, so gas actually leaves instead of drifting in place. `rpg_plugins/machines.lua` updateVentfan.",
  } },
  { ver = "1.15.107", notes = {
    "Buildings (@world): the cabin, watchtower, miners' camp, sealed vault, cistern, shrine, mineshaft junction, crystal chamber and reactor room have been re-authored at 3 to 5 times their old grid detail, and they are now buildings you go inside rather than silhouettes you walk past. The cabin has three ground-floor rooms off a central hall with a workbench hearth, a stairwell and an upper storey; the watchtower has a guard room at the bottom, a climbable shaft with staircase landings and a lookout at the top; the vault is an airlock -- outer door, antechamber, blast door, vault. Several of them previously had no way in at all: the cistern and the shrine were sealed rooms with no entrance, so the cistern's drowning hazard could never actually be met by a player who had no way to reach the water.",
    "Buildings (@world): doors are real doors. A 'door' used to be literally a missing wall cell -- there was no door object anywhere in the game's worldgen. Structures now carry a door token and a control pad that the terrain itself stamps, and the first time the generator commits to a placement it creates a genuine door machine at that spot: spark its pad from a powered grid and the slab lifts clear, let the spark fade and it drops back and seals the opening. Every opening is checked offline to be at least 6px wide and 12px tall against the 4x10px player, and the interior behind it is flood-filled to prove you can actually get in and stand up.",
    "Buildings (@world): several structures were impassable in the direction they existed for. The mineshaft junction's support posts were full-height columns spanning the gallery, the shrine's pillars and the cistern's standpipes walled their own rooms in half, and at 12px per cell each of those is a solid barrier to a 4px-wide player. Posts, pillars and pipes are now stubs and arches that you walk past.",
    "Buildings (@world): a very dense structure no longer takes the full landmark scale on top of its extra detail. The re-authored cabin at the old scale would have been 600x440px on a 612x384 screen -- larger than the view it appears in. Extra authored detail now buys thinner walls and a readable floor plan at a roughly constant landmark footprint instead of a bigger box.",
    "Buildings (@world): cabin windows no longer fall out of the walls. The window material resolves to coloured glass, which in this build is a POWDER -- so each window was a 15x15px block of loose glass that would slump out of the wall on the first tick and leave a hole straight into the house. They are ordinary solid glass now, and the generator refuses to write any building whose shell depends on a material that falls.",
    "Guide (@world): a new Structures category lists every structure the library actually loaded this session, with its real world-pixel size stated against your own 4x10px size, its biomes and depth band, how big each of its doorways is, whether that door has a control pad, and a running count of the worldgen door machines instantiated as you explore.",
  } },
  { ver = "1.15.106", notes = {
    "Crafting (@machines2): all 25 second-tier machine kits are craftable again -- the electrolysis cell, acid synthesizer, evaporator, fertiliser mixer, gunpowder mill, check valve, pressure vessel, reservoir, condenser, sump, sorter, splitter, vacuum, silo, quarry, gravity manipulator, portal, magnetic accelerator, cryo chamber, weather machine, lighting rail, camera, signpost, proximity gate and decorative panel. Every one of them had a complete recipe and a working builder, but crafting refuses any recipe whose output is neither a defined item nor a real element, and that file defined items only for its two loose reagents. So all 25 appeared normally in the crafting menu, took the click, and silently refused -- no error, nothing in the log, which is why it went unnoticed. Item definitions are now derived from the recipes themselves, so a kit added later cannot drift out of sync again.",
    "Machines (@core): building a new world no longer carries the old world's machines into it. Every other system cleared its own registry on Create World; the main machine list was the one that did not, so machines from the previous world survived at coordinates that no longer meant anything and were run by every update until the reaper eventually collected them. An open machine panel belonging to a machine that no longer exists is closed at the same time.",
    "Structures (@world): props no longer spawn inside buildings. Each structure category kept its own independent placement cache with no knowledge of the others, so a small detail prop laid down every 120px would routinely land inside a 300px cabin and draw straight through its wall. Categories now check each other's footprints before placing. Structures already could not overlap within a category, and could not grow trees through walls; this closes the last case.",
    "Structures (@world): groundwork for buildings whose doors and fittings are real objects rather than decoration. Worldgen can now turn an authored cell into a genuine machine record once per building, with the identity tracking needed to survive saving, reloading and demolition -- a door you break stays broken instead of returning the next time the world regenerates around it.",
  } },
  { ver = "1.15.105", notes = {
    "Structures (@world): houses and landmarks are far bigger, and buildings you can actually enter. The structure library was harvested from community stamps and one authored grid cell mapped to one world pixel, so measured against the real player box (4px wide, 10px tall) the small cabin was 15x17px -- the entire house was 1.7 player-heights. It was not merely small, it was unenterable: the interior is four grid rows, so a 10px character did not fit inside the building at all, and its only wall gap was 2px against a 4px-wide player. A grid cell now covers many world pixels, which takes the cabin to roughly 300x340px -- a third of the screen wide, with an 80px interior and a walkable doorway. The proportions were always right; only the size was wrong.",
    "Structures (@world): scale is driven by how much detail a structure was authored with, rather than one flat multiplier. A dense grid like the cabin (255 cells) takes the full landmark scale and keeps its roof, chimney and windows readable; a sparse one does not, because every cell becomes a solid block -- verified by rendering, a 3x8 signpost at full scale was a featureless 60x160 slab. Props stay props, landmarks become landmarks, and the authored size relationships between them are preserved.",
    "Structures (@world): buildings no longer grow trees through their walls. Vegetation and structures were independent generation passes with no arbitration between them, so a canopy could occupy the same space as a roof. Structures now win: the ground inside a building's footprint, plus a margin wide enough for the surrounding canopies, is cleared -- which is what building on a site means. Structures also can no longer overlap each other; each one is now confined to its own placement cell, which is the minimum-spacing rule the library always specified and never had.",
    "Structures (@world): fixed a placement bug that would have put buildings across cliffs. The ground-flatness test compared a width measured in grid cells against a distance measured in world pixels -- harmless while those were the same number, but after scaling it was checking 15px away for a 300px-wide building. It now measures the real footprint, samples across it rather than at one corner, and uses a fixed ground-movement budget instead of one proportional to width, which on a large building had grown permissive enough to allow a 105px drop.",
  } },
  { ver = "1.15.104", notes = {
    "Vehicles (@vehicles): press E to board or get off a vehicle, and stand near one to see a pulsing outline plus a prompt naming every control -- the bike gave no clue how to ride it before. E only takes over when a vehicle is actually in range and no panel is open, so it still opens your bag everywhere else. V is now purely brush-shape again: boarding no longer competes for it.",
    "Vehicles: ground vehicles no longer look jittery. Terrain height is whole-pixel and 68% of neighbouring surface columns differ, so at full speed the collision box genuinely steps every frame -- real physics, ugly to watch. The body now eases while the wheels stay planted on the true ground line with a visible strut between them, which reads as suspension instead of the whole machine snapping up and down. Collision itself is unchanged.",
    "Vehicles: sandbox mode unlocks vehicles instead of dumping seven kits into your bag. Take what you want from the guide's Vehicles category instead.",
    "Vehicles: hovering a vehicle can now report what it is and how it is doing (fuel, cargo, damage, whether it is on rails), and every vehicle recipe is tagged so the guide lists them automatically.",
  } },
  { ver = "1.15.103", notes = {
    "Camera (@camera): Ctrl+Up / Ctrl+Down zoom the camera in and out on your character, up to 4x. This is a real world zoom -- the whole simulation is scaled -- not the old magnifier box that was removed for being confusing and getting stuck. The HUD, panels and text stay sharp at normal size because they are drawn after the world image, and Ctrl+Down always walks it back to normal so it can never trap you. Plain arrow keys still nudge the camera exactly as before. NOTE: the engine half of this is compiled but not yet linked -- the running game holds powder.exe open -- so the keys report that a rebuild is pending until the game is next restarted.",
  } },
  { ver = "1.15.102", notes = {
    "Bag (@ux): fixed a live crash that blanked part of the inventory panel -- \"attempt to index local s\". The bag grid is a fixed 60 cells and hands back any slot 1-60, but the slot table was only ever grown as items appeared, and the one-time pre-fill at load does not survive a new world (core resets it on regen). With 3 items carried, the draw asked for slots 4-60 and indexed nil. The table is now padded to full size every draw, so the fixed-size invariant the grid already assumed is actually guaranteed for every consumer -- draw, hover, click-to-drop, sort and trash -- rather than guarded one read site at a time.",
    "Sandbox (@ux): entering sandbox no longer stuffs 999 of every material into your bag. Sandbox now means unrestricted, not pre-filled: no damage, free crafting, every station and accessory unlocked and the best tools, but an empty bag you fill deliberately -- take what you actually want from the guide (L). Crafting is unaffected by the empty bag because the cost/station checks already bypass on the sandbox flag itself rather than on holding materials. Also removed a background task that quietly refilled every stack back to 999 every 30 frames, which made a tidy sandbox bag impossible.",
    "Sandbox (@ux): turning sandbox OFF now clears the sandbox-stocked stacks instead of dumping 999 of everything into a survival run."
  } },
  { ver = "1.15.101", notes = {
    "World gen (@world): FIXED trees spawning buried in the ground on any world after the first. The world generator keeps eleven per-column caches (trees, biome blending, caves, lakes, structures and more) and had no new-world handler at all, while the core only ever cleared its own two. So every Create World filled the terrain from NEW surface heights while the tree cache still held each tree's ground level from the PREVIOUS seed -- leaving trunks pinned to a surface that no longer existed, buried in the new ground with their canopies cut off. Every one of those caches is now cleared on world generation. This was a latent bug rather than a new one; the rolling-hills terrain only made it visible, by moving the surface far enough between seeds that a stale tree base is off by tens of pixels instead of a few.",
    "World gen (@world): dirt no longer reads as warped and full of holes. The new horizontal galleries had no minimum depth, so gallery level one was carving large voids straight through the topsoil -- measured 29.2% air in forest soil just below the surface, i.e. ground that was nearly a third holes. Galleries now start below the soil layer, the same rule the cavern system already followed. Same measurement after: 19.1% air, and dirt 64% to 71% solid. Worth noting for the record that this was never the pixel-scale noise it looked like -- isolated single air pixels measured 0.08%, so it was always big voids in the wrong layer.",
  } },
  { ver = "1.15.100", notes = {
    "Breathing (@systems): if there is real oxygen within your character's breath radius, your air now refills all the way to full instead of only partway. Breathing is not a dosage curve -- either there is air to breathe or there isn't. A single stray particle drifting past still doesn't count as an atmosphere, and having no oxygen and no machine is still just as lethal as before."
  } },
  { ver = "1.15.99", notes = {
    "Desert (@world): FIXED an entire biome dissolving on spawn -- \"all of the sand fell through the earth\". The desert was the only biome whose whole soil column was made of SAND, which is a falling powder with no structural integrity (verified live: Falldown=1, not TYPE_SOLID), and after the topsoil deepening that column was 108-172px -- eleven to seventeen player-heights of loose powder. Every other biome already used a static solid (forest and swamp use dirt, snow uses ice, both Falldown=0). The caves did not cause this: the desert was always unsupported and simply had nowhere to fall until the new galleries and aquifer voids opened real space beneath it. Real deserts are a shallow skin of loose sand over sandstone, so that is what it is now -- a 10-20px sand cap, still genuinely loose so dunes and pouring behave correctly, over solid rock that holds the biome up. Measured over 21 interior desert columns: the soil column went from effectively all falling powder to 7.4% sand over 64.8% solid.",
    "Desert (@world): added scripts/check_biome_soil_solid.py, which reads every material's real Falldown and TYPE_SOLID from the running game and fails if any biome has a contiguous falling-powder column tall enough to collapse into a cave. This is the same failure class as the earlier stone-subsoil regression, so it now has a mechanical check instead of relying on anyone remembering. Whole-world audit passes: desert 19px max contiguous fall, swamp 8px, forest 5px, snow 1px.",
  } },
  { ver = "1.15.98", notes = {
    "Guide / database (L key): the Machines section was one flat list hiding roughly ninety craftables, because the guide identified weapons and machines from two hand-copied lists naming 12 weapons and 8 machines -- written back when those were the real totals. There are now 121 craftable items and 174 recipes, so almost everything built since fell through into Machines as an undifferentiated dump, and genuinely new things (vehicles, terrain weapons, wearable armour) had nowhere of their own to appear at all.",
    "Both lists are deleted. Every craftable is now sorted from live game data, rebuilt whenever the recipe count changes, so anything any plugin adds from here on files itself correctly with no list left to maintain: crafting stations come from the station table, terrain weapons and weapons from the tag each plugin already stamps on its own recipes, wearable armour from the 'Worn passively' line every passive item's own description opens with, and machines from the station that builds them.",
    "Machines are split into one section per build station (Workbench, Furnace, Anvil, Research, Advanced Lab), so the category column doubles as a progression ladder -- everything buildable at the bench you already have sits above the ones you cannot reach yet. A tier holding nothing of its own is hidden rather than shown empty.",
    "New sections: Vehicles, Terrain Weapons, and Wearables & Armor.",
    "Machine and item pages go deeper: what it costs and where it is built, how many it yields per craft, whether you actually have that station placed yet, how many of that machine are standing in the world right now, and every recipe that consumes the item. Wearables state plainly that carrying one is enough and there is no slot to equip.",
  } },
  { ver = "1.15.97", notes = {
    "Gases in water (@systems): oxygen and other gases could not enter a water pixel at all -- the engine blocks any particle from moving into something heavier than itself, and oxygen weighs 1 against water's 30, so gas simply bounced off every liquid surface. Bubbles now rise through water properly by displacing it. Gas through leaves is a separate, harder problem and is deliberately NOT changed yet -- see the notes; doing it wrong either corrupts the world or makes tree canopies drift apart."
  } },
  { ver = "1.15.96", notes = {
    "Vehicles (@vehicles): mine lifts, locomotives and drill trains no longer lose grid power the moment you look away. Power was detected by scanning for real SPRK particles on screen, and that check returns false for anything off-screen -- so scrolling away from a powered mine lift made it read as unpowered and free-fall down its own shaft, and stalled a locomotive mid-route, purely because the camera moved. The last on-screen reading is now cached and reused while off-screen.",
    "Vehicles: new Prospector (anvil) -- a free-roaming miner that drives anywhere the ground allows and bores a narrow shaft ahead of it, crediting every block. Built as the Bulldozer's configuration with a narrower, deeper blade rather than a second mining system.",
    "Vehicles: fixed a latent bug where any newly added tech-gated recipe would never appear. The unlock flag persists across a plugin reload, so once tech had ever unlocked the install condition was false forever afterwards and later additions were stranded -- the Prospector was invisible in crafting until this was found.",
    "Vehicles: the rail fleet was drawn smaller than the player riding it -- handcar 8px, minecart 9px, mine lift 9px, cargo wagon 10px, against a 12px character. Scaled up to 12-13px so you can actually see yourself aboard.",
  } },
  { ver = "1.15.95", notes = {
    "Terrain (@world): a new world now OPENS on visible terrain instead of a flat plain. The mountains added earlier were never broken -- measured on the live seed, relief is 133px across spawn +/-1500 and 451px across +/-8000 -- but the nearest real peak sat about 2.5 screen-widths from spawn, so you started on flat ground, looked around, and saw exactly what you had before. Two fixes: a rolling-hills octave at period 380 that is always on (the existing octaves were 160/60/22 for fine detail and 1100 for rare mountains, leaving the 300-500 band where relief you can actually see across one screen lives completely empty), and a guaranteed hill in view of spawn -- the same reasoning as the existing rule that force-spawns trees near the origin so a new world always has trees in sight. On-screen relief at spawn went from about 30px to 104px, and the nearest peak from 1520px away to 128px away.",
    "Trees (@world): trunks and canopies rescaled against the real player box (4px wide, 10px tall). Oak trunks were 4-7px -- barely wider than the player, and about 1:12 against their own height -- with a canopy only about half the tree's height, which is what made them read as bare poles with a green blob on top. Oak trunks are now 7-12px (about 1.75-3 player-widths) and the canopy is roughly as wide as the tree is tall, the proportion a real broadleaf has. Pines and palms rescaled to match.",
  } },
  { ver = "1.15.94", notes = {
    "Crafting (@ux): categories are drop-downs now. All 13 start collapsed, so the panel opens as a short scannable list instead of 121 recipes at once, and each header reads how many of its recipes you can afford right now (\"TOOLS 1 of 7 craftable now\"). Click a header to open it.",
    "Crafting (@ux): anything you cannot make yet has a [?] button that expands its PREREQUISITE CHAIN in place -- what that thing needs, what those need, three levels deep, each node showing have/need and whether it is craftable now, blocked on a station, or a raw material to go gather. Derived from the recipe data itself so it cannot drift. Answers \"how do I actually get to oxygen generation\" without reading recipes one at a time.",
    "HUD (@ux): the SANDBOX / TPT / GUIDE quick buttons are finally VISIBLE. R.drawQuickBar was fully written -- layout, hover, and a wired click handler -- but nothing ever called the draw half, AND it called the file-local `floor` from line 159 while that local is not declared until line 929, so it resolved as a nil global and threw on its first label every frame. Sandbox is now a one-click toggle on the main HUD, lit orange while active, no menu needed.",
    "HUD (@ux): oxygen particles your character breathes now flash a gold pulse where they are absorbed -- an expanding ring fading over ~16 frames, with a dark backing ring so it stays legible against both the bright surface and the dark underground. Reads @systems' R.breathFX feed. Makes a mechanic that was previously invisible actually observable."
  } },
  { ver = "1.15.93", notes = {
    "Vehicles (@vehicles): free-roaming vehicles are actually worth riding now. They were travelling 0.62px/tick against a 1.3px/tick walk -- slower than your own legs -- because a vehicle was supported only at its centre point, so it dropped into narrow dips barely wider than a pixel and then could not climb back out (a 6px climb limit against an unbounded fall) and sat there permanently. A vehicle now rides on the highest ground under ANY part of its body, so a 30px hauler bridges a 3px crack instead of falling into it. Measured on real terrain: 0.62 -> 2.81px/tick and 85 stalls -> 0, sustained over 300 ticks. The bike now moves at roughly twice walking speed.",
    "Vehicles: the giveaway that this was geometry and not tuning -- distance travelled came out byte-identical across every acceleration, friction, top-speed and stall-penalty variant tested, including one with no stall penalty at all and a 5.0 speed cap.",
  } },
  { ver = "1.15.92", notes = {
    "Terrain weapons (@terraweapons): a new weapon family that reshapes the world with real physics instead of scripted effects, craftable across the workbench/furnace/anvil tiers. TUNNEL BORER carves a corridor tall enough to actually walk through (14px) rather than a hole you cannot fit in. DEPOSITION GUN sprays real rock that then slumps and stacks under real gravity, so you can fill pits and raise ground at range -- terrain-altering that ADDS instead of removing. MAGMA LANCE superheats terrain past its OWN real melting point until it genuinely flows, so granite melts at granite's temperature and ice at ice's -- the weapon never decides what melts, physics does. CRYO FORMER chills real water below freezing so it sets into real ice you can stand and build on. SUPPORT CUTTER destroys nothing directly: it cuts the load path out from under a rock mass and lets the existing structural-collapse model bring it down for real.",
  } },
  { ver = "1.15.91", notes = {
    "Oxygen tank (@items): the tank you craft is now a real shape on your back, drawn on the player sprite with a live fill level -- the cylinder fills bottom-up in cyan as it charges, with a valve cap and a hose to your mask, so you can read your air reserve without opening anything. It tracks the walk cycle so it stays glued to the sprite, and it shows whenever you own the tank rather than only when it is the selected slot.",
    "Oxygen tank (@items): it now fills from REAL oxygen. Topping up consumes an actual OXYG particle out of the air beside you (it already vented real OXYG at your head when running low). There is deliberately no free fallback -- with no real oxygen nearby it does not fill, so refuelling means standing somewhere genuinely breathable. Honest limitation: TPT cannot attach loose particles to a moving entity, so the tank does not literally carry OXYG particles around; consuming real air to fill it and releasing real air to breathe is the physically honest version this engine supports.",
    "Ammo as a modifier (@items): kinetic guns (Musket, Shotgun, Steam Nail Gun, Rail Gun) now fire whatever round you carry, and the round IS a real element, so TPT physics does the rest -- Thermite burns what it hits, Nitro really detonates, Lead is denser and hits harder but flies slower, plain Metal stays the baseline. The HUD names the loaded round. Exotic rounds are preferred over plain metal, so what you carry is how you load a gun.",
  } },
  { ver = "1.15.90", notes = {
    "Breathing (@systems): the game now records each real oxygen particle your character actually inhales, so the UI can glow them as they are drawn in. Data side only -- the visible effect lands with the renderer."
  } },
  { ver = "1.15.89", notes = {
    "Oxygen machines (@systems): an oxygen generator, air pump or life support unit inside a SEALED room contributed nothing to your air. Its output was measured and then thrown away -- it was only ever added to the open-air formula, and every sealed-room limiter ignored it too, so a powered generator in a deep sealed base still left you suffocating at ~6%. That is the one place the machine is the whole point. A supplied sealed room now approaches full air, scaled by how much you have running.",
    "Breathing (@systems): re-applied the fix for suffocating while standing in visible oxygen bubbles -- it was silently reverted by a concurrent edit while the version and changelog still claimed it. The rule that real oxygen beats estimated air was gated on a ratio dividing your nearby bubbles by all ~1737 sampled cells, secretly demanding ~47 bubbles in one small circle; now gated on the real count."
  } },
  { ver = "1.15.88", notes = {
    "Breathing (@systems): fixed a real death bug -- you could suffocate while standing in visible oxygen bubbles that the game was genuinely counting. The rule that says \"real oxygen particles beat the estimated air quality\" was gated on a ratio that divided your nearby particle count by every one of the ~1810 sampled cells in the breath radius, so it secretly required ~43 bubbles packed into one 48px circle -- against a screen-wide oxygen cap of 220. A normal handful of bubbles never tripped it, the deep-underground suffocation estimate then pushed your air down to ~9, and damage starts at 12. Now gated on the actual particle count: 4 bubbles is a survivable pocket, ~28 reads as full air."
  } },
  { ver = "1.15.87", notes = {
    "Vehicles (@vehicles): the first vehicles that don't need rails. Every vehicle until now rode a single shared function that hard-failed without track, which is why there were no bikes -- there is now a real free-roaming ground physics primitive that follows actual terrain, climbs slopes up to each vehicle's grade limit, stalls out on ground too steep for it, falls under real gravity and hurts both machine and rider on a bad landing.",
    "Vehicles: Dirt bike (workbench, no fuel -- light, quick, climbs 4px steps, an early traversal unlock), Bulldozer (anvil -- a real earthmover whose blade genuinely carves terrain using the same pick-tier and hardness rules as the drill train and credits every block, so you can cut roads and open a hillside without laying track) and Hauler (anvil -- free-roaming heavy transport with a big cargo bed that loads by left-clicking it, dumps into a Storage Crate like the wagon does, and genuinely slows down the heavier it gets).",
    "Vehicles: sized against the player for the first time. The player is ~12px and the existing minecart was only ~9px tall -- smaller than its own rider. The bike, dozer and hauler are 11, 16 and 18px tall respectively so you can actually see yourself on them.",
  } },
  { ver = "1.15.86", notes = {
    "Weapons (@items): seven new weapons, each built on a real element doing its real job -- Thermite Lance (real THRM at 2500K, cuts metal a flamethrower cannot), Tungsten Sniper (real dense TUNG slug at hyper-velocity, punches through several blocks), Tesla Arc (real LIGH that chains between up to 4 nearby enemies instead of stopping at the first), Gravity Well Grenade (a real anchored well that drags loose matter and enemies inward by setting real velocities, then collapses), EMP Charge (real EMP burst that kills live sparks and powered machinery in radius without touching terrain), Aerogel Foam Gun (sprays real AERO to bridge gaps and plug leaks), and Disintegrator (void beam that deletes the first solid it meets cleanly, no crater or debris, and banks it if mineable).",
    "Armor (@items): the game had no armor system at all. Five pieces across three sets, built as passive gear -- ownership is the equip, so no new slots or UI. Each counters a REAL survival accumulator core already damages you from rather than adding a defense number: Lead-Lined Vest bleeds accumulated radiation dose (real attenuation), Zirconium Faceplate sheds the geothermal heat load that cooks you at depth, Sealed Pressure Suit keeps a breathable pocket in gas AND underwater (the gap the Gas Mask and Diving Helmet each leave), Padded Harness absorbs landing impact, Miner's Lamp Helm sheds real GLOW so you can see while mining. Set bonuses stack: Deep Caver slows UV burn, Reactor Engineer roughly doubles dose and heat shedding, Void Diver actively clears CO and CO2.",
  } },
  { ver = "1.15.85", notes = {
    "Hover (@ux): hovering now tells you what a THING is, not just what particle it is made of. A tree reads \"Tree trunk - chop with the axe (slot 2) for Wood - cut the trunk through and the whole tree comes down\" instead of \"Wood, 71F\". Also recognises the companion (HP, press Enter to talk), enemies (HP, attack with the sword), machines (right-click for inputs/outputs), and ore, which now tells you whether your pick is strong enough and what tier you need. Falls through to the existing temperature/pressure readout for plain terrain. Purely passive text -- it never captures a click or needs dismissing.",
    "Crafting (@ux): fixed a real error raised on every click in the recipes tab -- \"this functionality is restricted to graphics events\". The material-chip layout helper was drawing a hint inside itself, but the click handler calls that same helper purely to work out row positions, and drawing outside a draw event is illegal. Layout is pure now; the hint is drawn by the draw path."
  } },
  { ver = "1.15.84", notes = {
    "Crafting (@ux): recipes are grouped by what they are FOR -- Tools, Weapons, Survival Gear, Food & Farming, Stations, Materials, Power, Life Support, Fluids & Processing, Logistics & Storage, Building & Utility, Exotic -- instead of by which crafting station makes them. Station answered \"where do I make this\", an implementation detail, rather than \"what am I trying to make\"; it is still shown on every gated row (\"needs Anvil\") but is no longer the organising axis. Each category header reads how many of its recipes you can afford right now (\"TOOLS 1 of 7 craftable now\"), and a \"show: craftable now\" toggle hides everything you cannot make yet.",
    "Bag (@ux): empty inventory cells now highlight on hover. Only occupied cells ever lit up before, so while carrying a stack looking for somewhere to put it, the empty slots you were actually aiming at gave no feedback -- the panel advertised \"drag to move\" with an invisible target."
  } },
  { ver = "1.15.83", notes = {
    "Caves (@world): tunnels now run HORIZONTALLY. Measured the complaint first -- in the dirt layer, where the old worm tunnels are the only cave form, mean horizontal open-run was 9.9px against 40.1px vertical (H:V 0.246), i.e. every tunnel really was a descending shaft. Whole-world averages hid this completely (0.98 by adjacency, 1.17 by run length) because the large cheese caverns dominate them. The cause was structural, not tuning: a worm's centreline is a function of DEPTH, so it must descend while only wandering sideways -- no amount of extra wiggle changes its orientation. Added a second cave family parameterised by X instead, so a passage's depth varies as you travel horizontally: long horizontal galleries at spaced levels, with the old depth-parameterised worms left as the vertical connectors between them. Galleries carry real stalactites and stalagmites (rock spikes reaching in from ceiling and floor) and open into occasional large chambers.",
    "Caves (@world): passages are now big enough to actually walk through. Against the ~12px player, the old worm bore was 6-10px and could pinch to 3px -- physically too small for the character to enter, which is a large part of why caves read as tubes bored through dirt rather than somewhere you can stand. Worm bore is now 14-20px (about 1.2-1.7 player-heights) with a hard floor of 14px, and galleries are 18-28px (1.5-2.3 player-heights).",
    "Aquifers (@world): a real water table, distinct from the existing tree moisture. Saturated strata bands sit confined inside the rock and do nothing until something opens them -- dig into one and it floods. Springs need no special code: because caves are carved before rock is filled, a cave cutting a saturated band stays open while the band's rock becomes water, which then flows into the cave on its own. Galleries crossing a saturated band are generated already flooded, so you can follow a passage and find real standing water while exploring. Saturated layers ride the same per-column wobble the rock strata use, so they line up with the visible banding instead of cutting across it, and ore veins still win over water so the tech tree is never starved.",
  } },
  { ver = "1.15.82", notes = {
    "Trees/air (@systems): found why sawdust keeps appearing on trees, and it was never our code -- the engine itself turns WOOD into SAWD wherever a particle hits it faster than speed 5. The gas-venting fix that was supposed to route trapped oxygen around trunks pushed it at a speed proportional to how far the trunk's hollow column was, with no cap, so venting a pocket ~13px away launched oxygen at ~6.4 and it sandblasted the very trees it was routing around. Released gas is now clamped to a firm 3.2 -- a vent, not a jet. Oxygen should also spread between trees more instead of ricocheting off them."
  } },
  { ver = "1.15.81", notes = {
    "Internal (@locals): rpg.lua and machines.lua were within ~10 declarations of LuaJIT's hard 200-locals-per-scope limit, past which the whole file stops compiling with an error pointing at an unrelated line. Reclaimed slots by deleting two genuinely dead declarations (a never-read FELL_MAX and an unreferenced HELP controls table the Esc menu no longer uses), removing a BADGAS2 table that was byte-identical to the BADGAS already in scope, and inlining single-use layout/tuning constants. No behaviour changes -- every inlined value is the identical literal. Headroom: rpg.lua 10 -> 18, machines.lua 12 -> 17."
  } },
  { ver = "1.15.80", notes = {
    "Bag (@ux): empty inventory cells now highlight when you hover them. Previously only cells that already held an item ever lit up, so while you were carrying a stack looking for somewhere to put it, the empty slots you were actually aiming at gave no feedback at all -- the panel advertised \"drag to move\" with an invisible target."
  } },
  { ver = "1.15.79", notes = {
    "HUD (@ux): the death counter now reads \"Deaths 2\" instead of \"D:2\". Nothing on screen explained what the D stood for, and the changelog entry that introduced this readout had actually promised \"Deaths: N\" -- the code shipped the abbreviation instead. It still fits the top-left band.",
  } },
  { ver = "1.15.78", notes = {
    "World (@world): landmark structures are actually findable now. With real mountains in the world, the flat 3px ground-flatness tolerance was rejecting 9 of 15 landmark-scale placements (60%), leaving only 1.8 buildings per 3000px -- about one per five screens. The tolerance now scales with footprint width (a 15-wide cabin may sit on a 5px rise, which is still near-flat footing) and the surface spawn rate went 0.34 to 0.46. Measured after: 12 placed instead of 6, slope rejections down from 9 to 6, giving 3.7 buildings plus 8.9 small props per 3000px. Genuine cliff edges and cave mouths are still rejected.",
  } },
  { ver = "1.15.77", notes = {
    "World (@world): snow biomes are no longer an unminable ice slab. Snow returned icy strata for the entire top 480px AND skipped ore generation completely, so a measured survey of 207 snow columns found 91.1% of solid cells were ICE and quartz was the biome only ore -- no coal, no iron, no copper, no clay -- meaning the tech tree could not be progressed anywhere in snow. The new mountains made this far more visible by producing large snow landmasses. Snow now has a genuine thick frozen crust (all ice, as before) with normal rock and normal ore beneath it, threaded with ice lenses aligned to the surrounding strata so it still reads as a cold region. Same survey after the change: all five ore types present (coal 319, iron 164, clay 164, copper 50), still 49.6% ice against forest 0.7%. Forest and desert surveys were byte-identical before and after, confirming no spillover.",
  } },
  { ver = "1.15.76", notes = {
    "Crafting (@ux): recipe ingredients you are short of now show how many you actually have, not just how many the recipe wants. A row you cannot afford used to read \"6 Wood\" and nothing else, so working out what you still needed meant closing the panel and counting your inventory. It now reads \"2/6 Wood\" while you are short and goes back to plain \"6 Wood\" once you have enough -- so scanning the list answers \"what can I make next\" on its own, which is the complaint about the crafting screen being confusing.",
  } },
  { ver = "1.15.75", notes = {
    "HUD (@ux): the action hint under the log no longer sticks on screen forever. R.hint is written from 25 places across the core and plugins and was cleared in none of them, and the draw site had no expiry -- so whatever you last did (\"+1 Dirt  +7 Wood\") stayed pinned at full brightness indefinitely, which reads as a stuck UI element rather than feedback about something you just did. It now holds fully legible for about six seconds and then fades out, matching how the log lines above it already behave. Fixed at the draw site, which is the one point all 25 writes flow through, rather than by timestamping every call site.",
  } },
  { ver = "1.15.74", notes = {
    "Trees (@systems): fixed a real bug that could delete a living, rooted tree. The structural-collapse check asked \"is there an unbroken column of pure WOOD from here down to the surface line?\" -- but a real trunk RESTS ON topsoil, so descending from it hits dirt and the old code read that as 'no support', and grass at the trunk base aborted the scan the same way. A direct collapse call on a healthy surface-supported trunk destroyed 397 wood cells against a limit of 25. It now asks the physically correct question -- is this woody mass resting on something solid -- so reaching real ground counts as support and only genuinely open air below counts as unsupported. Measured on the live world: of 47 real trunk cells sampled, 7 that the old rule marked destroyable are now protected. Orphaned canopy after you cut a trunk still crumbles exactly as before, because air below it is still correctly 'unsupported'.",
    "Machines (@systems): new Life Support kit (Advanced Lab tier). Powered, inside a genuinely SEALED room, it holds the air up (feeding the same real oxygen model the air pump uses) and slowly restocks your food and water while you are inside -- a real reason to build an enclosed base and a standing sink for late-game power. Its panel names every failing condition separately (power / sealed / are you inside range) with one concrete next action, so \"it isn't working\" always says why.",
  } },
  { ver = "1.15.73", notes = {
    "HUD (@ux): fixed a regression this lane introduced one version earlier. The new GOAL wrapping called menuWrap, which is a file-level local that is NOT reachable from inside onDraw -- it resolved as a nil global and threw every single frame. Because onDraw is not wrapped in pcall, that one error silently aborted the entire rest of the HUD: the TEMP/PRESS gauges, the sunburn warning, the depth readout, the hotbar numbers and the version line all stopped drawing, while the bridge still reported lastErr=nil. Same failure mode already on record for wrap (v1.15.35) and drawMenu (v1.15.33). menuWrap and its character-width constant are now exposed on the shared R table, which draw code can always reach. On-screen text capture goes from 6 strings back to 38.",
  } },
  { ver = "1.15.72", notes = {
    "World (@world): the 30-structure community library is finally generating. 30 structures (cabins, wells, campsites, watchtowers, mineshaft junctions, shrines, sealed vaults, reactor ruins, crystal chambers, plus 10 small props like barrels, crates, lamp posts and campfires) were authored into knowledge/structures/*.json from 42 analysed community saves and then never wired into worldgen -- they had been generating nothing at all. world.lua now loads all 30 at plugin init (bridge-confirmed structuresLoaded=30) and places them on a per-category grid with biome filtering and rarity weighting.",
    "World (@world): fixed the bug that made the surface half of that library impossible -- worldGen returned aboveGround() for every cell above the surface line, so the structure dispatcher was only ever reached underground and any structure with a body above ground (every cabin, well, tower and prop) could never place. A 3001-column scan found zero structure materials above ground before the fix and real ones after it.",
  } },
  { ver = "1.15.71", notes = {
    "HUD (@ux): the GOAL line now shows up to three wrapped rows instead of two, so a full goal like 'Craft a wood pick by hand (E > craft) - 6 Wood' reads end to end rather than stopping at '(E >...'. When a goal is still too long to fit, the ellipsis is now trimmed into the row's width budget instead of being appended past it, which could previously push the last row wider than the panel it sits in.",
  } },
  { ver = "1.15.70", notes = {
    "World (@world): real mountains. The surface had only three noise octaves with periods of 160/60/22px, giving just 61px of total vertical relief across 8000 columns -- roughly five player-heights, which is why the world read as flat-with-holes. Added a long-wavelength mountain layer (period 1100px) that is hard-thresholded to exactly zero across most of the map, so plains stay plains and 22% of columns rise into real ranges. Measured on seed 7: total relief 61px -> 280px, widest continuous range 1763px, and the steepest slope is still 2px per column so every peak is walkable without digging.",
    "World (@world): topsoil band deepened from 20px to 50px. The player box is ~12px tall, so the old band was under two player-heights -- you hit rock before you could carve out a room with both a floor and a ceiling. 50px is about four player-heights: enough to dig into a hillside and build a real shelter in dirt. Cave entrances are unaffected (those come from world.lua's worm system, which overrides the base generator).",
    "Both world changes apply to newly generated terrain only -- an existing save keeps the terrain it already has. Start a new world from the title screen to see mountains.",
  } },
  { ver = "1.15.69", notes = {
    "Machines (@systems): fixed the real remaining cause of \"I place machines and they disappear.\" The core-existence check only ran while a machine's core was on screen, but its consecutive-miss counter was never cleared while off screen -- so a core that happened to read empty twice before you scrolled away kept that count, and the very first transient miss when you scrolled back (the tile-cache refill frame the grace period exists to survive) hit the limit and tore the machine down. The counter is now cleared whenever the core is off screen, since an off-screen core is no evidence either way.",
  } },
  { ver = "1.15.68", notes = {
    "HUD (@ux): the GOAL line no longer cuts off mid-word. It was chopped at a hardcoded 24 characters that had nothing to do with the panel width, so 'Craft a wood pick by hand' read as 'Craft a wood pick by han'. It now wraps to the real column width across up to two rows, and only genuinely long goals shorten -- on a word boundary, with an ellipsis.",
    "HUD (@ux): forage bonus drops now stack instead of repeating. Chopping a tree that dropped dozens of saplings printed '+Sapling' once per drop -- ~47 copies on one unreadable line, with no count. It now reads '+47 Sapling', matching how '+7 Wood' already worked. Fixed for all six bonus drops (Seeds, Berries, Spore, Mushroom, Root, Sapling), not just saplings.",
  } },
  { ver = "1.15.67", notes = {
    "World gen (@bug): starting a new world no longer carries over stale per-tree chop damage or in-progress cavity ventilation from the previous world — R.treeHP and R.pendingAir are now cleared on New World, matching every other world-coordinate-keyed table (radiation zones, stations, torches, chests, block-hit cooldowns).",
  } },
  { ver = "1.15.66", notes = {
    "Companion (@feature): a task chain (\"cut all these trees\" / \"dig me a big hole\" / \"build me a house\") that fails mid-way now gets one reason-aware re-plan attempt instead of dropping outright — a transient stuck-timeout retries the same step fresh, and running out of building material (walls/room/stairs) sends the colonist to fetch more of that exact item before resuming, so it can actually finish the job instead of leaving it half-built.",
  } },
  { ver = "1.15.65", notes = {
    "Trees (@bug): standing trunks/canopies no longer crumble to sawdust when digging nearby, hot-reloading, or ventilating — woody crumble only removes orphaned canopy (no trunk to surface); mining ventilation eases pressure under tree columns.",
    "Trees (@world): new forest seeds still required for hollow veins/root branches — existing columns keep their particles; Create World / pendingGen for the new tree features.",
  } },
  { ver = "1.15.64", notes = {
    "Trees (@liquids): canopy/gap rain routes harder into hollow trunk veins — stronger horizontal pull, more drain samples, less leaf pooling.",
    "Trees (@liquids): treeMoisture feeds underground aquifer — wet GOO band under roots retains WATR via treeAquiferSpreadTick + moisture seep.",
  } },
  { ver = "1.15.62", notes = {
    "Environment (@bug): TEMP/PRESS HUD samples full depth column (surface→geothermal deep) — min-max spread reflects real underground variation, not flat ~72°F.",
    "Blood (@bug): spray only on sharp damage (falls/lava/combat) — passive O2/CO2/poison/hunger no longer leaves growing red pools while idle.",
    "Trees (@gas): O2 spawn skips tree-gap columns; wedged OXYG/CO2 nudged toward hollow veins or upward instead of pooling between trunks.",
    "Trees (@liquids): canopy/gap water drain runs at surface even when rain stops — puddles on leaves route down hollow columns.",
  } },
  { ver = "1.15.60", notes = {
    "Environment (@feature): ONI-like underground feel — strong geothermal gradient, biome surface temps, cave pocket microclimates, depth-scaled pressure; TEMP/PRESS HUD wider min-max range.",
  } },
  { ver = "1.15.58", notes = {
    "Dig (@perf): less lag while mining — crumble/checkFell only when relevant; debounced hotbar; cached sky-vent checks; tree/gap liquid ticks skip deep underground; water equalisation throttled in caves.",
  } },
  { ver = "1.15.57", notes = {
    "Trees (@liquids): gap-floor pools between trunks — gapFloor routing now beats treeShadeDrain; stronger pull into hollow column + surface-band sweep during rain.",
  } },
  { ver = "1.15.56", notes = {
    "Trees (@visual): removed green canopy stain — water veins are blue WATR particles in hollow trunk air, not leaf overlay.",
    "Trees (@liquids): gap-pool drain pulls surface puddles between trunks into hollow columns; less water particle killing.",
  } },
  { ver = "1.15.55", notes = {
    "World (@terrain): 4x thicker topsoil/subsoil before stone strata — more dirt to dig through.",
    "Trees (@liquids): treeShadeDrain routes rain on canopy/branch air to hollow veins; faster vein tick during rain.",
  } },
  { ver = "1.15.54", notes = {
    "HUD (@ux): top-right quick buttons — TPT (native element palettes), SANDBOX, GUIDE — no Esc menu needed.",
    "TPT menus (@bug): toggle now enables every menu section (num_menus(false)); sandbox auto-shows native UI for powder-first play.",
  } },
  { ver = "1.15.53", notes = {
    "O2 (@bug): sealed deep pockets no longer read full air with zero OXYG — vent=0 stale-air fix + depth thinning; meter tracks visible particles underground.",
    "Esc menu (@layout): controls use one wide column (label + description) — no more 9-char vertical word ribbons.",
  } },
  { ver = "1.15.52", notes = {
    "Blood (@bug): spray only on actual HP loss with 0.5s cooldown — passive poison/suffocation was restarting 6-frame mega-bursts every 5 ticks.",
  } },
  { ver = "1.15.51", notes = {
    "Build (@controls): Ctrl+drag = ellipse/box on release (native TPT); Shift+drag = line on release — no more per-tick overlap thickening walls.",
    "Build (@shell): O toggles hollow brush ring for lines — thinner walls when connecting circle stamps.",
  } },
  { ver = "1.15.50", notes = {
    "Build (@controls): hold Shift with a block selected for full native brush — circle/square/triangle, Shift-drag line, Ctrl+Shift box, any range; Tab/V and wheel/[ ] work.",
  } },
  { ver = "1.15.49", notes = {
    "Esc menu: menuWrap 8px/char + multi-line STATUS — text stays inside left/right column boxes (no horizontal bleed past divider or panel edge).",
  } },
  { ver = "1.15.48", notes = {
    "O2 field (@visual): breathing radius is a large circle (R.O2_BREATH_R=48) centered on chest — matches circular gameplay sample.",
  } },
  { ver = "1.15.47", notes = {
    "HUD (@layout): TEMP/PRESS fixed rows — no overlapping F/kPa gray text; log + hint below gauge band.",
    "HUD (@visual): taller gradient T/P bars with min-max band + avg marker; O2 breath scan box around player.",
    "Cursor (@env): when not placing blocks, 7x7 hover shows nearby OXYG/CO2/SMKE counts.",
  } },
  { ver = "1.15.46", notes = {
    "Esc menu: tighter text fit — menu wrap uses 7px/char budget; CONTROLS lines stop at panel bottom; STATUS/GOAL lines constrained to settings column width.",
  } },
  { ver = "1.15.45", notes = {
    "Trees (@liquids): rain/water on forest floor between tree trunks routes to nearest hollow vein or soaks root GOO — gap cells were outside treeVegQuery soak path.",
    "Mining (@env): shallow digs under tree gaps cap ventilation start — no instant O2 rush through canopy-shaded floor cells.",
  } },
  { ver = "1.15.44", notes = {
    "Esc menu: CONTROLS column text wraps to column width — long tokens (e.g. SHIFT+wheel) break across lines instead of running past the panel edge; SETTINGS labels/status wrapped too.",
  } },
  { ver = "1.15.43", notes = {
    "Mining (@env): delayed cavity air-fill (R.pendingAir) — re-shipped after parallel tree pass; newly dug cells ventilate in from neighbors over ~50–90 ticks instead of instant surface O2.",
  } },
  { ver = "1.15.42", notes = {
    "Trees (@visual): parallax hills no longer wash out trunk/canopy pixels; darker trunk rims + canopy depth accents restore saturation.",
    "Trees (@visual): visible water veins — dark brown/green funnel lines along hollow trunk interior during rain or when treeMoisture > 0 (blood excluded).",
    "Trees (@liquids): trunk-base soak spreads into root-zone GOO and underground aquifer wet layer (treeAquiferAt + treeAquiferSpreadTick).",
  } },
  { ver = "1.15.41", notes = {
    "Mining (@env): newly dug underground cavities no longer fill with breathable air instantly — R.pendingAir tracks per-cell ventilation that diffuses in from adjacent open air over ~50–90 ticks; dig pressure eased from instant -8 to a ramping underpressure. Surface breathing and sealed-room logic unchanged.",
  } },
  { ver = "1.15.40", notes = {
    "Esc menu: STATUS footer moved to the right column below settings — no longer overlaps the bottom of the CONTROLS list.",
  } },
  { ver = "1.15.39", notes = {
    "Zoom (Z): edge/corner of the locked zoom window can be dragged and resized again — RPG mouse handler was swallowing every click (return false) so native GameView frame hit-testing never ran.",
  } },
  { ver = "1.15.38", notes = {
    "Esc menu: settings column wheel scroll now moves ~3 rows per notch (was 1px/notch — felt like endless scrolling).",
  } },
  { ver = "1.15.37", notes = {
    "Trees (@liquids): rain and blood no longer pool on canopy/trunk — treeWaterVeinsTick now uses world.lua treeVegQuery (real trunkW + hollow vein) to route WATR/GOO/BLD down the interior column and soak into root-zone GOO; absorbStandingWater skips tree surfaces.",
  } },
  { ver = "1.15.36", notes = {
    "HUD layout: right-column alerts (GOAL, gas, UV, radiation) no longer stack on the minimap — fixed-width column left of the map (x=310..498). UV sunburn labeled 'UV burn' with yellow bar (was mystery yellow). Pressure gauge labeled PRESS with kPa sublabel (was bare P). TEMP/F labels on temperature gauge. Deaths counter moved to HP row. Esc/L/C shortcuts one line below compass; compass depth-only panel moved to y=100; guide.lua removed duplicate L:Guide hint.",
  } },
  { ver = "1.15.35", notes = {
    "Fix: WHAT'S NEW / update dialogs no longer spam 'attempt to call global wrap (a nil value)' every frame. v1.15.32's UI do/end scope defined wrap as a block-local function, but onDraw (outside the block) calls wrap for changelog line-wrapping — same forward-decl pattern as drawMenu/drawTitleScreen.",
  } },
  { ver = "1.15.34", notes = {
    "Companion (@ux): digArea/buildRoom start+halfway chat milestones now live on R.COMP instead of C.action fields, so re-issued dig commands or action-table replacement no longer spam 'Starting to dig that out.' in chat.",
  } },
  { ver = "1.15.33", notes = {
    "Fix: Esc menu no longer spams 'attempt to call global drawMenu (a nil value)' every frame. v1.15.32's UI do/end scope accidentally re-declared `local drawMenu` inside the block, so onDraw called the never-assigned outer forward-decl — same bug class as the drawTitleScreen forward-decl fix.",
  } },
  { ver = "1.15.32", notes = {
    "Fix: hot reload no longer intermittently fails with 'main function has more than 200 local variables'. UI panel/hotbar/menu and title-screen helpers scoped in do/end blocks (same pattern as tree/liquid/env) so the main chunk stays under Lua 5.1's 200-local cap.",
  } },
  { ver = "1.15.31", notes = {
    "Esc menu UX: settings split into labeled sections (Gameplay, Graphics, World, Tools, Meta) with inline ON/OFF and current-value sublabels; active toggles tint green/orange; controls stay in the left column so nothing overlaps.",
  } },
  { ver = "1.15.30", notes = {
    "Trees (@bug): F10 tree trunk ground gap fix in world.lua veg renderer — trunk/cactus base now uses wy <= surf (was strict <), matching genBase; trees no longer float one pixel above grass.",
  } },
  { ver = "1.15.29", notes = {
    "Fix: V/Tab brush-shape hint no longer lies. placeAt called pullNativeBrush from onTick (no interface trait), so placement ignored the cycled shape; onMouseMove kept re-pulling native shape and stomped V/Tab before the next click. placeAt now uses cached R.brushShape; mouse-move only syncs brush radius from native.",
  } },
  { ver = "1.15.28", notes = {
    "Liquids (@bug): mined-cavity water no longer floats midair — settleLiquidsTick nudges WATR/DSTW/SLTW/OIL/BLD downward; nudgeLiquidsNear runs after every dig swing; dig pressure skips full -8 vacuum when adjacent liquid would be yanked upward.",
    "Environment (@feature): R.env samples temp/pressure min-max-avg on a grid around the player every 15 frames (depth-based geothermal baseline included); T and P HUD gauges show gradient bars with local range, not a single-point readout.",
    "Water (@feature): waterEqualisation stays on underground (depth > 40) even in fast mode so pooled cave water levels and drains realistically.",
  } },
  { ver = "1.15.27", notes = {
    "Blood (@bug): damage now spawns a vivid red BLD spray from your character over several frames — outward velocity from facing direction, not a tiny upward dribble. BLD colour brightened to 0xFF1020.",
    "Companion (@feature): Enter-chat always runs Aster's command parser even when a model driver is connected. Broad intent fallbacks (mine/get/gather/craft/light/dig shaft/quest help/bring me) — no more silent 'Got it.' Manual tasks block the scripted follow brain until the chain finishes.",
    "HUD (@bug): top-left status rows no longer stack AIR/Day/food on the same pixels; survival plugin warmth/events moved out of the HP band. Single version readout at bottom-left.",
    "Trees (@feature): rain on canopy/trunk routes water down the trunk column before soil soak (treeWaterVeinsTick); trunk WOOD no longer instantly absorbs resting rain.",
  } },
  { ver = "1.15.26", notes = {
    "Vehicles (@vehicles): minecart + rail + mine-lift kits on the workbench/anvil tree. Rail kit: LMB-drag snapped track (flat / 45° / vertical shaft). Minecart: place on track, V to board, D/A drive, S brake/dismount via R.mount/R.ride. Mine lift: vertical shaft cage with grid-powered call buttons. V only steals brush-shape when riding or next to a vehicle.",
    "Ventilation fan (VENTFANKIT): new powered life-support machine - registers into R.scrubbers to pull down ambient CO/CO2 near you and pushes real CO2/smoke along its duct. CO2 scrubber (SCRUBBERKIT) now also registers into R.scrubbers when powered (was only killing particles, not reducing R.gas.co/co2). Recipe unlocks at 10W tier alongside air pump and scrubber.",
    "survival.lua (@survival pillar 0b): minimal plant/food loop confirmed live — till SOIL (GOO recipe), plant SEED on patch with nearby WATR, harvest WHEAT, bake BREAD at furnace, right-click any R.FOODS item to eat and refill R.need.food. Idempotent R.eat/R.spawnPlayer wrappers (R._survival guard) so hot-reload no longer stacks illness/bed wraps.",
  } },
  { ver = "1.15.25", notes = {
    "Companion (@feature): refreshIndex now reports nearby LAVA/FIRE/ACID to the model index; chat templates for 'cut trees', 'dig hole', and 'build house' emit multi-step enqueueChain plans; buildRoom refuses to start if the player is inside the rect; digArea/buildRoom speak start + halfway milestones.",
  } },
  { ver = "1.15.24", notes = {
    "Old save files no longer crash companion chat after load (missing chatQueue/queue fields are merged and defaulted). F12 HUD: Day line has its own background row and no longer overlaps the GOAL bar; version readout moved to bottom-left. F13 minimap: 50x30 tiles at 2px, biome tinting, player arrow, north marker, coord readout.",
  } },
  { ver = "1.15.23", notes = {
    "New seed / Create World no longer sprays sand (or whatever native brush is selected) the moment play starts. Root cause: title-screen and inactive clicks returned nil from onMouseDown, and TPT only blocks native brush placement when Lua returns false -- nil lets the real sim think LMB is held from the Create/Play click. Decorative title embers are HUD-only; the spray was native placement continuing while your finger was still down. Title/inactive mouse handlers now return false, onMouseUp always clears RPG state even when inactive, and a short post-start grace blocks RPG placement until the next real click.",
  } },
  { ver = "1.15.22", notes = {
    "Title screen Play no longer dumps you into a world with no choices. New World opens a Create World panel: map type (Mixed / Forest / Desert / Snow / Swamp), Survival or Sandbox, seed (click to reroll), plus cave/ore/tree sliders. Esc menu New world goes there too instead of instantly regenerating. A single-biome map type forces every column to that biome; Mixed keeps the wandering world.",
  } },
  { ver = "1.15.21", notes = {
    "Leaving the Esc menu no longer keeps the brush firing. R.mouse.l could stay true across Esc open/close (the up-event never arrived), so the first frame of play after Resume/Esc dumped particles everywhere. Toggling TPT-menu mode happened to generate a real mouse-up and cleared it -- that was the workaround, not a fix. Every menu/bag/TPT-menu transition now calls R.releaseMouse(), and place/mine only run if the click started while no UI was open (R._clickArmed).",
  } },
  { ver = "1.15.20", notes = {
    "Tab now cycles brush shape in-game (same as the native TPT menu). keyName() was mapping Tab (keycode 9) to hotbar slot 9, so Tab never reached ChangeBrush. placeAt and the cursor preview now pull tpt.brushID/brushRadius before drawing/placing -- the earlier 1.15.20 helpers existed but were not on those two paths, which is why the menu brush changed and the game still placed a square. [ ] / wheel / V write the same native fields. Preview draws circle/square/triangle instead of always a rectangle.",
  } },
  { ver = "1.15.19", notes = {
    "F15b: build-mode brush preview square no longer draws over TPT's native element menu. When R.tptMenus is true (sandbox/TPT-menu mode where the native TPT element palette is visible), the RPG's cursor preview indicator is suppressed entirely so it doesn't visually obstruct the element menu underneath. The preview still draws in the default RPG mode where the RPG owns the selection flow. Same gate pattern as R.invOpen/R.menuOpen/R.uiPanelOpen suppression already in place for the same reason.",
  } },
  { ver = "1.15.18", notes = {
    "F14: build-mode brush shape picker. Press V to cycle brush shape between 'square' (default, current behavior), 'circle' (filled disc within brush radius), and 'single' (1px regardless of brush size). New state field R.brushShape, default 'square', reset on new world. Hotbar hint sub label now shows the current shape (e.g. 'V shape: circle'). Help screen BLOCKS line updated with the new key. commitBox (CTRL+SHIFT box-drag fill) intentionally ignores R.brushShape -- a 'single' or 'circle' shape would defeat the user's explicit box-drag intent. Single/circle dispatch lives in placeAt only.",
  } },
  { ver = "1.15.17", notes = {
    "Fix: molten elements (LAVA, FIRE, PLSM) now stay molten after placement instead of silently converting to stone/smoke in 1-3 frames. Root cause was sim.partCreate spawning them at ambient temperature (~295K) regardless of the element's native hot temperature, so the very first tick of physics cooled them past their state-change threshold. Added MOLTEN_TEMPS lookup { LAVA=1795, FIRE=900, PLSM=8000 } and a setMoltenTemp(p, el) helper called immediately after every successful partCreate in placeAt, commitBox (CTRL+SHIFT box drag fill), and R.actorPlace (worker placement). Lab-verified the temperatures via elem.property(id, 'Temperature') and confirmed each placed particle now persists in its molten state through several frames of physics.",
  } },
  { ver = "1.15.16", notes = {
    "Fix: molten/liquid materials were silently not placing at all -- placeAt returned 'none left' because R.inventory.LAVA was 0 by default (the starting-inventory loop in R.sandboxFill explicitly excluded LAVA along with FIRE and GLOW). User reported 'LAVA turns to stone', which was actually 'nothing placed and the empty canvas reads as a block of stone from a distance'. Dropped LAVA from the exclusion; element default temperature is 1795K so it self-heats on spawn and stays molten until it loses heat to surroundings.",
  } },
  { ver = "1.15.15", notes = {
    "F15: bare mouse wheel now resizes the build brush when a build-block (not tool, not item-kit) is selected and no panel is open -- the user tried the wheel to 'scroll their thing down completely' but it just hotbar-swapped, so they gave up. Existing wheel bindings all preserved: Ctrl+wheel = snap grid, Shift+wheel = brush size (same as bare wheel), wheel in zoom window = brush, wheel in inventory = recipe scroll, wheel with tool/item-kit selected = hotbar swap, tptMenus mode = hands wheel to native TPT.",
    "F16: build-mode brush indicator no longer draws 8 corner ticks and a size label around a 1px brush -- at brush=0 the center pixel IS where you're aiming, and the ticks+label produced a '+' bigger than the pixel itself, covering the single-pixel drawing. Center fill preserved; only the overshoot ticks and '1px' label are skipped when ww==1 and hh==1.",
  } },
  { ver = "1.15.14", notes = {
    "Round-25 HUD fix: top-left status line no longer reads 'Day N day' during daytime -- the format was always emitting a 'day'/'night' word after the day number, so for ~95% of playtime the HUD displayed the duplicate word 'day' (looked like a typo). Dropped the redundant word entirely; only append ' (night)' when it adds information. Visual confirmation via debug screenshot of the live session.",
  } },
  { ver = "1.15.13", notes = {
    "Redesigned HUD temperature and pressure readouts: 'Feels like X F' and 'Pressure' are now visual gauges, not just stacked numbers in a column. Temperature shows a horizontal thermometer bar (cold-blue -> white -> warm-orange -> hot-red, 0-1000 F range, current reading as a moving fill), and pressure shows a parallel gauge (green safe, yellow caution, red dangerous, normal=100). Both sit in the top-left HUD band below the Day/biome status line, visually distinct from the line above (numbers/text) and the log tail below (fading chat). Reads at a glance: glance at the bar colors, not the numbers.",
  } },
  { ver = "1.15.11", notes = {
    "QoL: 'Sunburnt (X% UV exposure) -- get some shade' no longer spams the chat every 5s while you stand outdoors with uvAccum > 70. Added R.lastSunburnAt cooldown: the 1-HP damage tick still fires every 300 frames as before, but the chat message only repeats every ~30s (1800 frames). Reset to nil on new world (added to the existing frame-stamped cooldown reset list at generateWorld).",
  } },
  { ver = "1.15.10", notes = {
    "F9 (HIGH, same bug class as F5): bed-respawn now also fires the F1 companion-teleport and F8 R.clearAround() that the surface-respawn path always did. Same fix pattern as v1.15.9's F5 -- extracted F1+F8 into a shared R._teleportCompanionAndClear() helper so the survival.lua bed wrap can call it directly. Without this, dying deep and bed-respawning left Aster stranded at the death site (or stuck dead until REVIVE_DELAY), defeating the v1.15.7 F1 fix for every survival player who'd placed a bed.",
  } },
  { ver = "1.15.9", notes = {
    "F5 (survival.lua): bed-respawn now resets the same death-pollution envelope (R.o2, R.gas, R.need.food/water, R.hurt/R.bloodLast, R.uvAccum/R.radAccum) that the surface respawn did since v1.15.4. Extracted the reset block into R._resetSpawnState() so the bed wrap and core spawnPlayer share a single source of truth (same bug class as the original death-loop, just on the bed-spawn path). Bed hp rule (max of current or 40) and bed-position teleport unchanged.",
  } },
  { ver = "1.15.8", notes = {
    "CONVENTION (going forward): rpg.lua owns R.VERSION; ALL plugin fixes roll into the next rpg.lua version bump with their own CHANGELOG entries (one unified user-visible stream, matches @github's CHANGELOG.md practice).",
    "F2 (companion.lua): R.companionKill() now also clears C.queue -- before, a queued chain survived the death/revive cycle and each step replayed step-by-step, calling into chain-fail-cleanup behavior that didn't match player intent on a forced test kill.",
    "F3 (companion.lua): R.hooks.newworld now resets 7 additional R.COMP fields that the original reset missed -- C.x=0, C.y=0, C.vx=0, C.vy=0, C.chatQueue={}, C.sayMsg=nil, C.sayAt=nil. Fixes a one-frame ghost at the previous world's last position and a chatQueue leak where driver messages queued in the previous world would drain into the next one.",
  } },
  { ver = "1.15.7", notes = {
    "F1: R.spawnPlayer() now teleports the companion to the fresh player spawn point -- companion.lua:R.COMP.x/y were never reset, so dying deep and respawning at the surface left Aster stranded at the death site (or worse, dead). Gated on C.active and not C.dead so it doesn't interfere with the REVIVE_DELAY auto-respawn path.",
    "F8: R.clearAround() re-added (was lost in the v3 rewrite; commit 6c8d889). No-arg version that reads R.P.x/R.P.y and clears a 6-wide x 11-tall box above the spawn point, matching the v2 shape. Both call sites (generateWorld line 840, R.spawnPlayer line 893) already pass no args. The 'BLD pool at spawn point' bleed noticed at the round-3078 respawn is now actually fixed.",
  } },
  { ver = "1.15.6", notes = {
    "In-game version readout now shown in the always-on HUD (top-right, above Deaths counter). Was only visible on the title screen and during the What's-New popup -- mid-session builds no longer need to be checked via Esc menu or guessed.",
  } },
  { ver = "1.15.5", notes = {
    "Death counter now shows in the always-on HUD (top-right, only when deaths > 0): 'Deaths: N' in bright orange. Was previously only visible in the inventory panel and Esc menu, easy to miss in the moment after a respawn when you actually want to see it.",
  } },
  { ver = "1.15.4", notes = {
    "Fixed respawn-doesn't-clean-state: dying to CO2/suffocation/fire and respawning at the surface left R.o2 at 0 and R.gas (CO/CO2/rad/heat) at its death-time pollution levels, so the surface poisoned you again and a second death followed within seconds. R.spawnPlayer() now resets R.o2=100, R.gas, R.need.food/water, R.hurt/R.bloodLast, R.uvAccum/R.radAccum, and R.hp=100. Magic Mirror is unaffected (it saves/restores hp around the call).",
  } },
  { ver = "1.15.3", notes = {
    "Added R.releaseMouse() (F11 hotkey) -- emergency unstuck for the mouse: clears R.mouse.l/r, R.placeBox, R.placeAnchor, R.zoomClick, R.zoomPending, R.lastPlace, R.lastMine (and R.lineAnchor if any), so a held-click bug that somehow slips past onMouseUp's reset can be killed without restarting the game",
  } },
  { ver = "1.15.2", notes = {
    "Native TPT's toolbar/menus now actually hidden by default from the first frame of a new world, not just once you happen to open the Esc menu -- the function that hides them was only ever wired to that manual toggle",

    "Esc menu is wheel-scrollable now -- 26 settings entries only had room for 16 on screen, the rest silently ran off the bottom",
  } },
  { ver = "1.15.1", notes = {
    "Fixed stuck-mouse-button bug for real: onMouseUp's button-state reset could be skipped entirely by two different early returns (zoomClick, tptMenus), leaving it stuck down forever and turning every later mouse move into a held click/place. Also fixed the same class of bug at the native engine level -- losing window focus while a button was held never got handled at all, now forces a real release.",
    "Fixed a real crash on picking up a duplicate accessory from two chests or two boss kills",
    "Fixed cave entrance tunnels reading as dead-straight vertical shafts for their first ~40 units before winding -- real winding now starts immediately",
    "Companion no longer desyncs from the player on non-default gravity/jump/move-speed settings",
    "Reverted the Stone-under-topsoil change (see 1.15.0 note) -- caused real terrain collapse",
  } },
  { ver = "1.15.0", notes = {
    "New Seed/New World no longer inherits sandbox/creative mode -- always starts in real survival now",
    "Fixed the What's New popup's bottom text overlapping itself and reading as smushed garbage",
    "(REVERTED post-1.15.0: the Stone-under-topsoil change below caused a real subsoil collapse on world generation -- Stone is a falling powder in this engine, not a static wall. Back to brick until a genuine static rock element is built.)",
    "Swinging at your companion now actually registers a hit (she already had HP/death, just nothing was calling into it)",
    "Shift-drag now draws a straight line same as Ctrl-drag; Ctrl+Shift together drags out a box and fills the whole thing on release",
    "Crafting panel's material filter no longer eats half the screen before you see a single recipe",
    "Day length is now adjustable from the Esc menu (Options > Day length)",
    "Longer daytime by default, real sunburn from unsheltered daylight, trees now do real photosynthesis (CO2 -> O2), tree roots are visible, added a tiered Research Bench",
  } },
  { ver = "1.14.0", notes = {
    "Real positive atmospheric pressure at the surface now, not just a low-pressure dip where you dig -- a genuine differential on both ends, so digging down actually pulls surface air with it",
    "Mouse wheel now scrolls the bag's item/recipe lists -- no more clicking tiny arrow buttons one line at a time",
    "Hover tooltip now also shows real pressure, alongside name and temperature",
    "Dig-pressure strength increased so air rushes in noticeably faster",
  } },
  { ver = "1.13.0", notes = {
    "Replaced the laggy dig-spawns-oxygen hack with the real thing: digging now sets genuine low air pressure at the opened cell, and the sim's own actual air physics pulls surrounding atmosphere in -- real negative pressure, not scripted particles, and none of the lag the old version caused",
    "Fixed the What's New popup running every version's changes together with no visible separation",
  } },
  { ver = "1.12.0", notes = {
    "Critical: sealed rooms (a house, a shallow dug-out) were treated as near-vacuum regardless of depth, so stepping into ANY enclosed space could suffocate you almost instantly even right at the surface. Fixed properly -- air quality now genuinely depends on depth first; sealing only adds an extra penalty that scales with how deep you are, so it only turns dangerous far underground like it should",
    "Blood is no longer walkable -- you were able to stand on top of a puddle like solid ground",
    "Oxygen that gets physically wedged in tight canopy gaps now periodically releases instead of piling up forever",
  } },
  { ver = "1.11.0", notes = {
    "Fixed the changelog popup only checking on a brand new world -- since fixes now apply instantly without a restart, it could go several versions without ever showing, then dump all of them at once the next time you started a new seed, looking like something broke (\"it reset my version\"). Now checks right when an update actually applies.",
  } },
  { ver = "1.10.0", notes = {
    "Fixed ambient oxygen getting visibly stuck between tree branches -- it was spawning up at canopy height, where real solid leaves physically trap gas particles; now stays down near the ground where it can actually move",
    "Standing in real water now directly quenches thirst over time -- a Canteen is still the real upgrade (carry water, boil dirty water), but just being in a lake now actually does something",
  } },
  { ver = "1.9.0", notes = {
    "Digging now visibly pulls oxygen into the new opening immediately, instead of waiting on slow ambient diffusion to eventually wander over",
    "Fixed the real cause of \"I keep placing machines and they disappear\": the core-integrity check could misfire on a single-tick false read right as the core scrolled back into view -- now requires a few consecutive misses before actually tearing a machine down",
  } },
  { ver = "1.8.0", notes = {
    "Temperature is now Fahrenheit everywhere (was Celsius), and the hover tooltip is sized to fit instead of running way too long",
    "New: a persistent \"Feels like X F\" readout, top-left, showing the real temperature right around your character -- not just on hover",
  } },
  { ver = "1.7.0", notes = {
    "New: hover your mouse over any real material in the world to see its name and exact temperature",
    "New: taking damage now draws real blood (fall damage, burns, radiation, hunger/thirst, suffocation all trigger it)",
  } },
  { ver = "1.6.0", notes = {
    "Mouse controls settled: ONE button (LEFT click) now does whatever your selected slot does -- places a block, or uses a tool/weapon/sword -- instead of a fixed two-button split. Matches native TPT's own single-button tool convention.",
    "Trees: found and fixed the REAL remaining cause of leftover floating canopies after chopping (confirmed live: a single realistic axe swing could hollow out a gap wide enough to break the earlier fix). Widened the connectivity search further and removed a size cap that was silently refusing to clean up any canopy bigger than 5 cells -- which is all of them.",
  } },
  { ver = "1.5.0", notes = {
    "Tried swapping mouse buttons (left=place/right=use) -- reverted back to LEFT=use tool/RIGHT=place after live testing showed it felt wrong. Mouse-button scheme is still an open question, not settled yet.",
    "Oxygen: reverted the \"must wait for real air to diffuse down a shaft\" change -- it caused sudden suffocation right after digging an obviously open, connected hole. Depth-based air is back to simple and reliable; the visible ambient oxygen particles are unaffected",
  } },
  { ver = "1.4.0", notes = {
    "Critical: crafting anything (workbench included) never actually showed up in the bag's CARRIED tab -- opening it crashed a plugin silently every single time on a freshly generated world (a reset field was set to nil instead of an empty table), leaving the tab permanently empty no matter what you'd made. This could genuinely block progress -- fixed.",
    "Esc menu now has \"View full changelog\" so you can pull up the whole history any time, not just the once-per-version popup on launch",
    "Ctrl+V now pastes into the chat/feedback text boxes via the real OS clipboard",
  } },
  { ver = "1.3.0", notes = {
    "Critical: every plugin (machines, survival, items, ui, guide, enemies, vehicles, companion, save, world) was only ever loading on the original dev machine -- fixed a hardcoded absolute-path bug that made them silently fail as \"absent\" for anyone else running a downloaded copy",
    "Guide: machine/kit items (airline kit, air pump, algae tank, and any future ones) now show up automatically instead of needing to be hand-added to a list that kept going stale",
    "Oxygen: being in an obviously open, shallow dug-out space no longer misreads as \"sealed\" just because the one exact column checked still had rock in it -- was causing sudden false suffocation right after digging a shallow hole",
    "Pausing (Space) now actually stops the world clock -- rain, torches, furnaces, day/night, and enemy spawns all freeze too, not just your character",
    "Removed the Ctrl+Up/Down zoom attempt -- it reused the wrong native tool, didn't work as \"zoom in on my character,\" and could get stuck on; a real version needs an actual engine change",
  } },
  { ver = "1.2.0", notes = {
    "Trees: chopping no longer leaves floating trunk/canopy chunks that never despawn (a chop-created gap was breaking the felling flood-fill)",
    "Oxygen: now a real surface reservoir that diffuses down through dug shafts via the sim's own gas physics, instead of spawning randomly at any depth; detection no longer requires standing exactly on a sparse grid point",
    "Oxygen: breathing now exhales real CO2 next to you, not just consuming O2 into nothing",
    "Rain: standing water now soaks into ground/wood/grass over time instead of pooling forever, including on top of trees",
    "Caves: reworked tunnel generation so passages wind and branch instead of reading as straight shafts; deeper topsoil layer before caves start",
    "Space is the native TPT pause key -- no longer double-bound to jump (W only); movement freezes while paused instead of quietly continuing",
    "Chat/feedback text boxes now use real OS text input, so dictation/speech-to-text works in them",
    "H2 and natural gas now rise and can pool at cave ceilings, matching real gas density (CO2 already sank correctly)",
    "Ctrl+Up/Down zooms in/out on your character using the native zoom lens",
    "Version numbers are now plain semantic versions (e.g. 1.2.0) instead of a date string",
    "The controls-on-join popup defaults off now (still toggleable from the Esc menu)",
  } },
}
R.changesPromptOpen = false
-- Fixed click targets for the changelog/update popups' "Got it"/dismiss
-- button -- computed once, here, so the draw code and the click handler in
-- onMouseDown (defined earlier in this file) agree on the same rectangle
-- without duplicating the geometry math in two places.
do local px, pw = 80, W - 160
  R.changesBtnRect = { x = px + pw - 74, y = 42, w = 66, h = 13 }
  R.updateBtnRect  = { x = px + pw - 74, y = 42, w = 66, h = 13 }
end
-- R.VERSION is overwritten to a fixed literal by rpg_plugins/netlink.lua at plugin load
-- (deliberate cross-plugin version coordination, documented there and in decisionLog.md --
-- NOT a bug, do not "fix" it). That means this changelog's own "has he seen the latest
-- notes" check must never key off R.VERSION: since netlink pins it to one literal string on
-- every load, seen==R.VERSION would either match forever (popup never fires again for any
-- future entry, silently) or never match, depending on load order -- not something new work
-- here should depend on. Key off the newest entry that actually carries a ver field instead:
-- the first { ver=, notes= } table found in R.CHANGELOG, skipping any plain-string entries a
-- plugin may have inserted directly (netlink.lua does this on load via table.insert). Kept as
-- an R.* function, not a top-level local, per the shared locals-budget rule.
function R._changelogHeadVer()
  for _, entry in ipairs(R.CHANGELOG) do
    if type(entry) == "table" and entry.ver then return entry.ver end
  end
  return R.VERSION
end
-- A CHANGELOG entry is normally { ver=, notes={...} }, but a plugin may instead insert a
-- plain already-formatted string (netlink.lua does). The old code here assumed every entry
-- was a table and did entry.notes unconditionally -- the moment a string entry existed
-- in the list, ipairs(entry.notes) on a nil field threw, aborting the whole function. Both
-- call sites wrap this in pcall, so that failure was silent: no crash shown, popup simply
-- never appeared, for every entry newer than the string, forever. Handle both shapes.
function R._appendChangelogLines(lines, entry)
  if type(entry) == "table" then
    lines[#lines + 1] = "v" .. tostring(entry.ver) .. ":"
    for _, n in ipairs(entry.notes or {}) do lines[#lines + 1] = "- " .. n end
  else
    lines[#lines + 1] = tostring(entry)
  end
  lines[#lines + 1] = ""
end
function R.checkLocalChangelog()
  local seen = ""
  local f = io.open("changelog-seen.txt", "r")
  if f then seen = (f:read("*a") or ""):gsub("%s+$", ""); f:close() end
  local head = R._changelogHeadVer()
  if seen == head then return end
  local pending = {}
  for _, entry in ipairs(R.CHANGELOG) do
    if type(entry) == "table" and entry.ver == seen then break end
    pending[#pending + 1] = entry
  end
  if #pending == 0 then return end
  local lines = {}
  for _, entry in ipairs(pending) do R._appendChangelogLines(lines, entry) end
  R.localChanges = { notes = table.concat(lines, "\n"), count = #pending }
  R.changesPromptOpen = true
end
function R.dismissLocalChangelog()
  R.changesPromptOpen = false
  local f = io.open("changelog-seen.txt", "w"); if f then f:write(R._changelogHeadVer()); f:close() end
end
-- Reopens the FULL history any time, not just the "new since last seen"
-- subset the boot check shows -- the ask was "I want to see our changes...
-- so I can keep track of stuff," which the fire-once popup alone doesn't
-- cover once it's been dismissed. Esc menu > "View full changelog".
function R.openFullChangelog()
  local lines = {}
  for _, entry in ipairs(R.CHANGELOG) do R._appendChangelogLines(lines, entry) end
  R.localChanges = { notes = table.concat(lines, "\n"), count = #R.CHANGELOG }
  R.changesScroll = 0
  R.changesPromptOpen = true
end
R.UPDATE_REPO = "phoenixfire808/Powder-RPG"
R.updateChecking = false
R.updateCheckHandle = nil
R.updateInfo = nil            -- { version=, zipUrl=, notes=, count= } once newer builds exist
R.updatePromptOpen = false   -- changelog popup shown once per detected update
R.updateDownloading = false
R.updateDownloadHandle = nil

function R.checkForUpdate()
  if not (http and http.get) or R.updateChecking or R.updateCheckHandle then return end
  R.updateChecking = true
  -- Full release list, not just /latest -- lets a player who skipped several
  -- builds see every version's changes accumulate, like a normal app updater.
  local ok, handle = pcall(http.get, "https://api.github.com/repos/" .. R.UPDATE_REPO .. "/releases",
    { { "User-Agent", "PowderToyRPG" } })
  if ok and handle then R.updateCheckHandle = handle else R.updateChecking = false end
end

function R.pumpUpdateCheck()
  if not R.updateCheckHandle then return end
  local ok, status = pcall(R.updateCheckHandle.status, R.updateCheckHandle)
  if not ok then R.updateCheckHandle = nil; R.updateChecking = false; return end
  if status == "done" then
    local ok2, body = pcall(R.updateCheckHandle.finish, R.updateCheckHandle)
    R.updateCheckHandle = nil; R.updateChecking = false
    local ok3, releases
    if ok2 and body then ok3, releases = pcall(json.parse, body) end
    if ok3 and type(releases) == "table" then
      -- Newest first (GitHub's own order). Walk forward collecting every
      -- release newer than what's running; stop once we reach our own
      -- version -- everything past that point is already installed.
      local pending, zipUrl, newestVer = {}, nil, nil
      for _, rel in ipairs(releases) do
        local ver = rel.body and rel.body:match('Version:%s*([%w%-%.]+)')
        if ver == R.VERSION then break end
        if ver then
          local changes = rel.body:match("Changes:%s*(.-)%s*Ready%-to%-run") or rel.body
          pending[#pending + 1] = { version = ver, changes = changes }
          if not newestVer then
            newestVer = ver
            for _, a in ipairs(rel.assets or {}) do
              if a.browser_download_url and a.browser_download_url:match("%.zip$") then zipUrl = a.browser_download_url; break end
            end
          end
        end
      end
      if newestVer and zipUrl then
        local parts = {}
        for _, p in ipairs(pending) do parts[#parts + 1] = "v" .. p.version .. ":\n" .. p.changes end
        R.updateInfo = { version = newestVer, zipUrl = zipUrl, notes = table.concat(parts, "\n\n"), count = #pending }
        R.updatePromptOpen = true
        say(#pending .. " update" .. (#pending > 1 and "s" or "") .. " available (v" .. newestVer .. ") -- press U to update")
      end
    end
  elseif status == "dead" then
    R.updateCheckHandle = nil; R.updateChecking = false
  end
end

function R.startUpdate()
  if not R.updateInfo or R.updateDownloading then return end
  if not (http and http.get) then say("Can't update: no network access"); return end
  R.updatePromptOpen = false
  R.updateDownloading = true
  say("Downloading update " .. R.updateInfo.version .. "...")
  local ok, handle = pcall(http.get, R.updateInfo.zipUrl, { { "User-Agent", "PowderToyRPG" } })
  if ok and handle then R.updateDownloadHandle = handle else R.updateDownloading = false; say("Update download failed to start") end
end

function R.pumpUpdateDownload()
  if not R.updateDownloadHandle then return end
  local ok, status = pcall(R.updateDownloadHandle.status, R.updateDownloadHandle)
  if not ok then R.updateDownloadHandle = nil; R.updateDownloading = false; return end
  if status == "done" then
    local ok2, data = pcall(R.updateDownloadHandle.finish, R.updateDownloadHandle)
    R.updateDownloadHandle = nil; R.updateDownloading = false
    if ok2 and data and #data > 100000 then
      local f = io.open("update.zip", "wb")
      if f then f:write(data); f:close(); R.applyUpdate()
      else say("Update failed: could not save update.zip") end
    else say("Update failed: download came back empty/too small") end
  elseif status == "dead" then
    R.updateDownloadHandle = nil; R.updateDownloading = false; say("Update download failed")
  end
end

-- Writes a small helper .bat that waits for THIS exe to actually exit (it
-- can't overwrite its own running files), then extracts the new zip over
-- this folder, relaunches Play.bat, and deletes itself. Launched detached
-- before this process exits, so it survives past os.exit() below.
function R.applyUpdate()
  local bat = io.open("apply_update.bat", "w")
  if not bat then say("Update failed: could not write apply_update.bat"); return end
  bat:write("@echo off\r\n")
  bat:write("cd /d \"%~dp0\"\r\n")
  bat:write(":wait\r\n")
  -- FIXED 2026-09-02: this waited only for "PowderToyRPG.exe", but the v1.17.0
  -- redistributable ships the binary as "PowderRPG.exe". The wait loop matched
  -- nothing, fell straight through, and Expand-Archive then tried to overwrite a
  -- RUNNING, file-locked .exe -- so the update silently failed every time. Wait for
  -- every name this game has shipped under before touching any files.
  for _, exeName in ipairs({ "PowderRPG.exe", "PowderToyRPG.exe", "powder.exe" }) do
    bat:write("tasklist /FI \"IMAGENAME eq " .. exeName .. "\" 2>NUL | find /I \"" .. exeName .. "\" >NUL\r\n")
    bat:write("if not errorlevel 1 (\r\n")
    bat:write("  timeout /t 1 /nobreak >NUL\r\n")
    bat:write("  goto wait\r\n")
    bat:write(")\r\n")
  end
  -- ADDED 2026-09-02: preserve the player's own settings across an update.
  -- The release archive contains powder.pref (it is what keeps the build portable --
  -- without it PowderToy.cpp falls back to the AppData data folder and the RPG never
  -- loads), but -Force would overwrite the player's window size, scale and renderer
  -- choices on every single update. Back it up, let the archive land, then restore it.
  bat:write("if exist \"powder.pref\" copy /Y \"powder.pref\" \"powder.pref.userbak\" >NUL\r\n")
  bat:write("powershell -NoProfile -Command \"Expand-Archive -Path 'update.zip' -DestinationPath '.' -Force\"\r\n")
  bat:write("if exist \"powder.pref.userbak\" move /Y \"powder.pref.userbak\" \"powder.pref\" >NUL\r\n")
  bat:write("del update.zip\r\n")
  -- Relaunch the .exe directly; Play.bat is only a fallback and may be absent.
  bat:write("if exist \"%~dp0PowderRPG.exe\" ( start \"\" \"%~dp0PowderRPG.exe\" ) else ( start \"\" \"%~dp0Play.bat\" )\r\n")
  bat:write("del \"%~f0\"\r\n")
  bat:close()
  say("Update downloaded -- restarting now")
  pcall(os.execute, 'start "" /min apply_update.bat')
  pcall(os.exit, 0)
end

R.chatOpen = false
R.chatText = R.chatText or ""
R.chatLog = R.chatLog or {}          -- { {who=, text=, frame=}, ... } newest last
R.chatInbox = R.chatInbox or {}      -- player lines not yet consumed by a brain
function R.chatSay(who, text)
  if not text or text == "" then return end
  R.chatLog[#R.chatLog + 1] = { who = who or "?", text = tostring(text):sub(1, 160), frame = R.frame or 0 }
  while #R.chatLog > 40 do table.remove(R.chatLog, 1) end
  return true
end
function R.chatPending(consume)
  local out = {}
  for i, m in ipairs(R.chatInbox) do out[i] = m end
  if consume ~= false then R.chatInbox = {} end
  return out
end
R.o2Sources = R.o2Sources or {}   -- plugins register {x=, y=, rate=, range=} oxygen emitters here
R.scrubbers = R.scrubbers or {}   -- CO/CO2 scrubbers: {x=, y=, rate=, range=}
R.coolers   = R.coolers or {}     -- climate control against deep heat: {x=, y=, rate=, range=}
R.gas = R.gas or { co = 0, co2 = 0, ch4 = 0, rad = 0, heat = 0 }
-- Delayed cavity air-fill: newly mined cells start unventilated and diffuse O2/pressure
-- in from neighbors over time instead of instant surface-level air the frame rock breaks.
R.pendingAir = R.pendingAir or {}   -- "wx,wy" -> {x, y, vent=0..1, born=frame, liq=bool}
R.AIR_VENT_RATE = R.AIR_VENT_RATE or 0.018   -- neighbor-to-neighbor fill speed (~55 ticks/cell)
R.AIR_VENT_TICK = R.AIR_VENT_TICK or 2
R.AIR_DIG_PRESS_MAX = R.AIR_DIG_PRESS_MAX or -9   -- stronger underpressure vs surface +depth baseline
R.AIR_DIG_PRESS_LIQ = R.AIR_DIG_PRESS_LIQ or -1
R.AIR_PENDING_MAX = R.AIR_PENDING_MAX or 400
-- FALLOUT-STYLE RADIATION: G.rad above is the *live* reading (how hot it is
-- right here, right now) -- it clears fast once you leave, so a source that
-- melts down or gets mined out stops being dangerous instantly, nothing
-- like Fallout's lingering irradiated craters. R.radZones is real ground
-- contamination: a world-anchored mark left wherever nuclear material was
-- actually present, decaying over minutes instead of seconds, so the crater
-- is still hot long after the source is gone. R.radAccum is the player's own
-- long-term dose ("rads"), separate from the live reading -- it barely
-- clears on its own and eats into max HP the way real radiation sickness
-- would, so lingering in a hot zone has a lasting cost instead of resetting
-- the moment you step out.
R.radZones = R.radZones or {}     -- { {x=, y=, strength=}, ... } world coords
R.radAccum = R.radAccum or 0
R.uvAccum = R.uvAccum or 0        -- separate from nuclear radiation: real sun exposure, standing outdoors in daylight
-- day is R.dayFrac of the day/night cycle (default 0.65), shared by the sky render and UV exposure below.
-- Read live off R (not a frozen local) so the Options-menu slider takes effect immediately, no reload needed.
R.dayFrac = R.dayFrac or 0.65
-- survival needs: the survival plugin grows/cooks food and calls R.eat(); core just tracks the meters
R.need = R.need or { food = 100, water = 100 }
R.FOODS = R.FOODS or {}          -- survival plugin fills this: name -> {food=, water=, heal=}
function R.eat(item)
  local f = R.FOODS[item]; if not f then return false end
  if (R.inventory[item] or 0) <= 0 then say("You have no " .. R.nice(item)); return false end
  R.inventory[item] = R.inventory[item] - 1
  R.need.food = math.min(100, R.need.food + (f.food or 0))
  R.need.water = math.min(100, R.need.water + (f.water or 0))
  if f.heal then R.hp = math.min(100, R.hp + f.heal) end
  say("Ate " .. R.nice(item)); R.rebuildHotbar(); return true
end
R.hooks = { tick = { profile = true, throttle = true }, draw = { profile = true }, drawHUD = { profile = true }, key = {}, mousedown = {}, mouseup = {}, place = {}, mine = {}, craft = {}, gen = {}, newworld = {}, sandbox = {}, keyup = {}, wheel = {}, mousemove = {}, chat = {},
  -- Sandbox-mode hook lists (added 2026-09-02 for rpg_plugins/sandbox.lua and ui.lua's
  -- sandbox block). Sandbox deliberately bypasses every normal RPG handler, so plugins
  -- that want to draw or respond THERE need their own dispatch rather than reusing the
  -- RPG ones -- otherwise re-enabling submission would drag the whole HUD back in with it.
  sandboxKey = {}, sandboxTextInput = {}, sandboxMouseDown = {}, sandboxMouseUp = {},
  sandboxMouseMove = {}, sandboxDraw = { profile = true }, sandboxDrawHUD = { profile = true },
  sandboxTick = { profile = true, throttle = true } }
-- FRAME BUDGET: every hook is timed, and any tick hook that exceeds its budget is automatically run less
-- often so one heavy plugin can never eat the frame rate. R.perf holds the measured cost of each hook.
R.perf = R.perf or {}          -- tag -> { ms = exponential moving average, skip = run 1 frame in N }
R.perfOn = (R.perfOn == nil) and true or R.perfOn
-- per-hook per-frame budget 1.2ms (inlined below)
local function hookTag(f, i) return (type(f) == "table" and f.tag) or ("#" .. i) end
local function runHooks(list, ...)
  local sample = R.perfOn and list.profile and (R.frame or 0) % 11 == 0
  for i, f in ipairs(list) do
    local tag = hookTag(f, i)
    local rec = R.perf[tag]
    local run = true
    if list.throttle and rec and rec.skip and rec.skip > 1 then run = ((R.frame or 0) % rec.skip == 0) end
    if run then
      local t0 = sample and os.clock() or nil
      local ok, r = pcall(f, ...)
      if t0 then
        local ms = (os.clock() - t0) * 1000
        rec = rec or { ms = ms, skip = 1 }
        rec.ms = rec.ms * 0.7 + ms * 0.3
        if list.throttle then
          -- a hook that costs more than the budget runs on fewer frames; cheap hooks go back to every frame
          if rec.ms > 1.2 * 4 then rec.skip = 4
          elseif rec.ms > 1.2 then rec.skip = 2
          else rec.skip = 1 end
        end
        R.perf[tag] = rec
      end
      if not ok then R.pluginErr = tostring(r) elseif r then return r end
    end
  end
end
R.runHooks = runHooks
function R.perfReport()
  local rows, total = {}, 0
  for tag, rec in pairs(R.perf) do rows[#rows + 1] = { tag, rec.ms, rec.skip or 1 }; total = total + rec.ms / (rec.skip or 1) end
  table.sort(rows, function(a, b) return a[2] > b[2] end)
  local out = {}
  for i = 1, math.min(8, #rows) do out[#out + 1] = string.format("%s %.2fms%s", rows[i][1], rows[i][2], rows[i][3] > 1 and ("/" .. rows[i][3]) or "") end
  return string.format("lua %.2fms/frame | %s", total, table.concat(out, "  "))
end

-- ================================================================ procedural world: pure function of (wx, wy, seed)
local floor = math.floor
local function frac(v) return v - floor(v) end
local function hash3(a, b, c) return frac(math.sin(a * 127.1 + b * 311.7 + c * 74.7 + (R.seed or 7) * 13.7) * 43758.5453) end
local function vnoise(x, y, salt)
  local ix, iy = floor(x), floor(y); local fx, fy = x - ix, y - iy; fx = fx*fx*(3-2*fx); fy = fy*fy*(3-2*fy)
  local a, b, c, d = hash3(ix, iy, salt), hash3(ix+1, iy, salt), hash3(ix, iy+1, salt), hash3(ix+1, iy+1, salt)
  return (a + (b-a)*fx) * (1-fy) + (c + (d-c)*fx) * fy
end
local function smooth1(x, period, salt) return vnoise(x / period, 0.5, salt) end
-- Mountain relief layer (2026-08-30, @world). Measured complaint, quantified:
-- the three detail octaves below have periods of only 160/60/22px and sum to
-- a 100px span, so a real seed produced just 61px of total vertical relief
-- across 8000 columns -- about five player-heights. That is the "terrain is
-- too flat, I want actual Terraria terrain" report as a number.
--
-- One extra octave with a period ~7x longer than the largest existing one,
-- hard-thresholded so it is exactly zero across most of the world: plains
-- stay plains, and where it does fire it ramps into a real range. Threshold
-- 0.58 came from a measured distribution sweep (26% of columns pass it);
-- amplitude 900 was then solved from the observed max m (0.388^1.3*900
-- ~= 260px peak lift) rather than guessed. Measured on live seed 7:
-- relief 61px -> 280px, 22% of columns mountainous, widest continuous range
-- 1763px, max slope still 2px/px so peaks stay walkable without digging.
-- Subtracts only (never pushes terrain down), so the WATER_LEVEL sea rule in
-- genBase is untouched. Salt 71 is fresh -- salt 11 is already taken by the
-- cave ridge field.
local function mountainAt(wx)
  local m = (smooth1(wx, 1100, 71) - 0.58) / 0.42
  if m < 0 then return 0 end
  return m ^ 1.3
end
local surfCache = {}
local function surfaceAt(wx)
  local s = surfCache[wx]; if s then return s end
  local v = 0.55 * smooth1(wx, 160, 1) + 0.30 * smooth1(wx, 60, 2) + 0.15 * smooth1(wx, 22, 3)
  -- (1) Rolling hills, period 380, always on. The other octaves are 160/60/22 (small detail)
  -- and mountains are 1100 (rare) -- nothing occupied the 300-500 band where relief you can
  -- actually SEE across one ~612px screen lives, so plains read as dead flat. Measured on live
  -- seed 7: across the ~600px visible at spawn the surface varied only ~30px. 70px at period
  -- 380 gives ~1.6 cycles per screen. Max slope ~0.7px/px, gentler than the 2px/px the
  -- mountains already allow, so nothing becomes unwalkable. Salt 72 is fresh.
  --
  -- (2) A guaranteed hill in view of spawn. Mountains were never broken -- measured relief is
  -- 133px across spawn +/-1500 and 451px across +/-8000 -- but the nearest real peak sat at
  -- x=1520, about 2.5 screen-widths away, so a new world still OPENED on a flat plain and read
  -- as "the terrain didn't change." Same reasoning as the existing forceTree band that
  -- guarantees trees at spawn: what a new world opens on is what it gets judged by. Centred at
  -- x=420 (~240px from the x=182 spawn, comfortably in frame), 90px tall, ~600px wide, with a
  -- squared falloff so it blends into the surrounding terrain instead of ending in a cliff.
  local sd = (wx - 420) / 300
  local bump = 0
  if sd > -1 and sd < 1 then local q = 1 - sd*sd; bump = 90 * q * q end
  s = floor(120 + v * 100 - mountainAt(wx) * 900 - smooth1(wx, 380, 72) * 70 - bump)
  surfCache[wx] = s; return s
end
-- biome width 900 inlined at its single use (200-locals budget, see DEVELOPMENT.md)
local MAP_TYPES = { "mixed", "forest", "desert", "snow", "swamp", "flat" }
local MAP_TYPE_OK = { mixed = 1, forest = 1, desert = 1, snow = 1, swamp = 1, flat = 1 }
local MAP_TYPE_LABEL = {
  mixed = "Mixed (all biomes)",
  forest = "Forest",
  desert = "Desert",
  snow = "Snow",
  swamp = "Swamp",
  -- Flat: no hills, no caves, no biome noise, no structures. Ground is solid ROCK
  -- from FLAT_SURFACE_Y down. world.lua's flatWorldGen() has existed since 2026-08-31
  -- but had no way to switch it on; this exposes it as a map type so it appears in the
  -- existing Create World panel with no new UI. Asked for directly: "just spawns our guy
  -- in on a flat map, no terrain or anything, just our guy."
  flat = "Flat (no terrain)",
}
R.mapType = (type(R.mapType) == "string" and MAP_TYPE_OK[R.mapType]) and R.mapType or "mixed"
R.createSandbox = R.createSandbox == true
local function forcedBiome()
  local t = R.mapType
  -- "flat" is a map type, NOT a biome -- flatWorldGen bypasses the biome pipeline
  -- entirely, so returning it here would hand a bogus biome name to every
  -- biome-keyed lookup downstream.
  if type(t) == "string" and t ~= "mixed" and t ~= "flat" and MAP_TYPE_OK[t] then return t end
  return nil
end
function R.cycleMapType()
  local cur = R.mapType or "mixed"
  local idx = 1
  for i, v in ipairs(MAP_TYPES) do if v == cur then idx = i end end
  R.mapType = MAP_TYPES[(idx % #MAP_TYPES) + 1]
  say("Map type: " .. (MAP_TYPE_LABEL[R.mapType] or R.mapType) .. " (new terrain)")
  return R.mapType
end
local function biomeOfCell(c) if c == 0 then return "forest" end; local h = hash3(c, 9, 9); if h < 0.2 then return "desert" elseif h < 0.35 then return "snow" elseif h < 0.5 then return "swamp" else return "forest" end end
-- Warped, soft biome borders: the boundary itself wanders (domain warp) and the last ~90px of each biome
-- interleaves with its neighbour, so a desert fades into forest instead of ending on a straight line.
local function biomeMix(wx)
  local forced = forcedBiome()
  if forced then return forced, nil, 0 end
  local warp = (vnoise(wx / 260, 0.5, 71) - 0.5) * 190 + (vnoise(wx / 70, 0.5, 72) - 0.5) * 60
  local u = (wx + warp) / 900
  local c = floor(u); local f = u - c
  local here, other, t = biomeOfCell(c), nil, 0
  local EDGE = 0.10                        -- fraction of a biome that is transition on each side
  if f < EDGE then other = biomeOfCell(c - 1); t = (EDGE - f) / (2 * EDGE)
  elseif f > 1 - EDGE then other = biomeOfCell(c + 1); t = (f - (1 - EDGE)) / (2 * EDGE) end
  if other == here then other, t = nil, 0 end
  return here, other, t
end
local function biomeAt(wx)
  local forced = forcedBiome()
  if forced then return forced end
  local here, other, t = biomeMix(wx)
  if other and t > 0 then
    -- deterministic per-column dither: near the border the two biomes interleave in patches
    local n = vnoise(wx / 9, 0.5, 73) * 0.6 + vnoise(wx / 28, 0.5, 74) * 0.4
    if n < t then return other end
  end
  return here
end
R.biomeMix = biomeMix
-- Drop the per-column generator caches. The sandbox worldgen sampler swaps R.seed to render a
-- slice of some OTHER world, and without this the already-cached columns would keep returning
-- terrain from the previous seed -- so the sampler would quietly show the wrong world, which is
-- worse than not having the feature. Cheap: both caches are rebuilt lazily per column.
function R.resetGenCaches() surfCache = {}; treeCache = {} end
local BIOME = { forest={grass=GRASS, soil="GOO", trees=0.5}, swamp={grass=GRASS, soil="GOO", trees=0.35}, desert={grass="SAND", soil="SAND", trees=0.0}, snow={grass="ICE", soil="ICE", trees=0.25} }
local treeCache = {}
local function treeAt(cell)
  local t = treeCache[cell]; if t ~= nil then return t end
  local b = BIOME[biomeAt(cell * 24 + 12)]
  if hash3(cell, 5, 5) < b.trees then local x0 = cell * 24 + 3 + floor(hash3(cell, 6, 6) * 17); t = { x0 = x0, h = 12 + floor(hash3(cell, 7, 7) * 14), s = surfaceAt(x0) } else t = false end
  treeCache[cell] = t; return t
end
-- GRSS: grass/leaves that do not spread in water (PLNT grows explosively when it rains). Copy of PLNT without its update.
if not has("GRSS") and elements and elements.allocate then
  local ok, g = pcall(elements.allocate, "RPG", "GRSS")
  if ok and g and g >= 0 then local props = elements.element(elements.DEFAULT_PT_PLNT); props.Name = "GRSS"; props.Description = "Grass and leaves. Burns, does not spread."; props.Update = nil; props.Graphics = nil
    pcall(elements.element, g, props); idcache["GRSS"] = g end
end
local GRASS = has("GRSS") and "GRSS" or "PLNT"
-- BLD: blood. Real liquid physics (copy of WATR), just red -- spawned wherever
-- the player actually takes damage (see R.hurtLast tracking below), not its
-- own hand-rolled particle type.
if not has("BLD") and elements and elements.allocate then
  local ok, b = pcall(elements.allocate, "RPG", "BLD")
  if ok and b and b >= 0 then local props = elements.element(elements.DEFAULT_PT_WATR); props.Name = "BLD"; props.Description = "Blood."; props.Colour = 0xFF1020
    pcall(elements.element, b, props); idcache["BLD"] = b end
end
if has("BLD") then pcall(elements.property, idcache["BLD"], "Colour", 0xFF1020) end
-- coal must smoulder slowly (stock behaviour); the realism patch made it flash-burn (Flammable 40)
pcall(elements.property, elements.DEFAULT_PT_COAL, "Flammable", 0)
pcall(elements.property, elements.DEFAULT_PT_BCOL, "Flammable", 0)
-- Oxygen Not Included-style gas stratification: real gases separate by density
-- instead of just diffusing evenly. Stock TPT already gets CO2 (Gravity 0.1,
-- sinks) and WTRV (Gravity -0.1, rises) right -- H2 and natural gas (GAS) were
-- both left neutral, so neither one visibly rose or pooled at cave ceilings
-- like the genuinely light gases they are. Patched at runtime via
-- elements.property (same mechanism the Flammable overrides above use)
-- instead of touching the C++ source, so no rebuild is needed. H2 is real
-- hydrogen (molar mass ~2, the lightest gas that exists) so it rises harder
-- than water vapour; GAS stands in for methane/natural gas, the classic
-- "firedamp" that pools at mine ceilings, so a milder rise. Left NTRG
-- (nitrogen, ~molar mass 28, essentially the same as air) and NBLE (no
-- specific noble gas named) alone -- no real-density case for moving either.
pcall(elements.property, elements.DEFAULT_PT_H2, "Gravity", -0.18)
pcall(elements.property, elements.DEFAULT_PT_GAS, "Gravity", -0.08)
-- GRNT was never actually registered as a real element in this fork (has()
-- always returned false), so subsoil silently fell back to fired brick.
-- REVERTED 2026-08-29: tried swapping the fallback to STNE without checking
-- its real physics first -- stock STNE is Falldown=1 (a real falling powder,
-- not a static wall), so every existing world's subsoil started collapsing
-- the moment it loaded ("everything fell through the earth"). BRCK is at
-- least genuinely static/solid even though it's not geologically accurate;
-- fixing that for real needs an actual static rock element, verified for
-- Falldown=0/TYPE_SOLID before it's ever used as terrain fill again.
-- FIXED 2026-08-30: bridge-verified BSLT (id=503) has Falldown=0 and
-- Properties & TYPE_SOLID == 4 (bit set) -- a real static solid, unlike
-- STNE/GRAV/BRMT/BCOL/CLST/SAND (all Falldown=1, SOLIDbit=0). GRNT still
-- doesn't exist in this fork (has("GRNT")==false), so BSLT is now primary.
local ROCK = has("BSLT") and "BSLT" or "BRCK"
local UORE = has("DU") and "DU" or "URAN"
local HASCU = has("CU")
local function genBase(wx, wy)
  if wy >= DEPTH then return "DMND" end
  local surf = surfaceAt(wx)
  if wy <= surf then
    if surf > 200 + 3 and wy > 200 then return "WATR" end
    -- F10: tree trunk was drawing WOOD up to wy < t.s (one pixel short of the
    -- surface), and the surface row itself was always b.grass via the early
    -- return below -- leaving a 1-pixel air gap that the eye reads as the
    -- tree "floating" above the grass. Extend the trunk to wy <= t.s so it
    -- overdraws the grass pixel at the trunk's 2px column (Terraria-style),
    -- and hoist the trunk check out of the wy < surf block so it can fire at
    -- wy == surf too. Canopy ellipse at line 675 unchanged -- it has no
    -- matching gap (covers the topmost trunk rows by design).
    local c = floor(wx / 24)
    for cc = c - 1, c + 1 do local t = treeAt(cc)
      if t then if (wx == t.x0 or wx == t.x0 + 1) and wy >= t.s - t.h and wy <= t.s then return "WOOD" end
        local dx, dy = wx - t.x0 - 0.5, wy - (t.s - t.h - 2); if dx*dx/36 + dy*dy/20 <= 1 then return GRASS end end end
    if wy == surf then return b.grass end
    return nil
  end
  local b = BIOME[biomeAt(wx)]
  if wy <= surf + 8 then
    -- Tree roots: a few tapering, branching WOOD fingers fanning down and out from
    -- each trunk base into the topsoil, instead of a tree just stopping dead at
    -- ground level. Narrow near the trunk, only reaching wider offsets once deep
    -- enough -- reads as real roots, not a solid wedge -- and hash-gapped so they
    -- aren't a single continuous mass.
    local c = floor(wx / 24)
    for cc = c - 1, c + 1 do local t = treeAt(cc)
      if t then
        local rdx = wx - t.x0
        if math.abs(rdx) <= 5 and (wy - surf) >= math.abs(rdx) * 0.6 - 1 and hash3(wx, wy, 61) > 0.35 then return "WOOD" end
      end
    end
  end
  -- Topsoil depth 20 -> 50 (2026-08-30, @world): "we need a larger dirt layer
  -- so we can actually dig down and make a house or shelter." The player box is
  -- ~12px tall, so a 20px band was under two player-heights -- you hit rock
  -- before you could carve a room with a floor and a ceiling. 50px is ~4
  -- player-heights: enough to dig in and build out a real shelter in dirt.
  -- Knock-on (intended): genBase's own fallback cave field starts at d>24, so
  -- it now begins below the soil instead of inside it -- caves stop opening
  -- into the shelter band. world.lua's worm/entrance system is a gen HOOK and
  -- overrides genBase, so surface cave entrances are unaffected.
  if wy <= surf + 50 then return b.soil end
  if wy >= DEPTH - 40 then return "DMND" end
  local d = wy - surf
  if d > 24 then
    -- winding tunnel networks (ridged noise) + rare large caverns; more open with depth.
    -- A single noise octave's 0.5-contour is smooth and nearly straight -- it reads as
    -- a shaft, not a cave. Domain-warp the sample point with its own noise field (same
    -- trick biomeMix uses for organic borders) so passages bend and drift, then blend
    -- in a second, finer octave so they branch instead of running as one clean line.
    local wob = (vnoise(wx / 18, wy / 14, 17) - 0.5) * 0.05
    local warpx = (vnoise(wx / 45, wy / 45, 40) - 0.5) * 34
    local warpy = (vnoise(wx / 45, wy / 45, 41) - 0.5) * 34
    local wwx, wwy = wx + warpx, wy + warpy
    local ridge = math.abs((0.65 * vnoise(wwx / 85, wwy / 55, 11) + 0.35 * vnoise(wwx / 32, wwy / 22, 45)) - 0.5) + wob
    local cavern = 0.55 * vnoise(wx / 110, wy / 65, 14) + 0.3 * vnoise(wx / 40, wy / 28, 15) + 0.15 * vnoise(wx / 12, wy / 9, 16)
    local open = ridge < 0.05 + math.min(0.025, d / 9000) or cavern > 0.70 - math.min(0.06, d / 12000)
    if open then
      if wy > 1450 and vnoise(wx / 40, wy / 40, 13) > 0.45 then return "LAVA" end
      if d > 250 and cavern > 0.74 and vnoise(wx / 50, wy / 30, 16) > 0.62 then return "WATR" end
      return nil
    end
  end
  if d < 220 and vnoise(wx / 40, wy / 30, 31) > 0.78 then return b.soil end
  if d > 20 and vnoise(wx / 60, wy / 9, 21) > 0.80 then return "COAL" end
  if d > 60 and vnoise(wx / 16, wy / 9, 22) > 0.84 then return "IRON" end
  if HASCU and d > 100 and vnoise(wx / 12, wy / 8, 23) > 0.86 then return "CU" end
  if d > 160 and vnoise(wx / 8, wy / 8, 24) > 0.88 then return "GOLD" end
  if d > 120 and has("QRTZ") and vnoise(wx / 11, wy / 11, 27) > 0.90 then return "QRTZ" end
  if d > 420 and vnoise(wx / 8, wy / 8, 25) > 0.89 then return UORE end
  if d > 650 and vnoise(wx / 7, wy / 7, 26) > 0.92 then return "DMND" end
  if d > 700 and has("TTAN") then return "TTAN" end
  return ROCK
end
local function gen(wx, wy)   -- plugins may override a cell: hook returns element name, "" for air, or nil to keep the base
  if #R.hooks.gen > 0 then for _, f in ipairs(R.hooks.gen) do local ok, r = pcall(f, wx, wy); if ok and r ~= nil then if r == "" then return nil end; return r end end end
  return genBase(wx, wy)
end
R.gen, R.surfaceAt, R.biomeAt, R.DEPTH = gen, surfaceAt, biomeAt, DEPTH

-- ================================================================ tile store (particles that scrolled off-canvas) + camera
local TS = 64
local CC = 96                        -- chest cell size (world px)
local M = 4                          -- TPT cannot hold particles in the outer 4px border
R.tiles = R.tiles or {}
local function tkey(wx, wy) return floor(wx / TS) * 100000 + floor(wy / TS) + 50000 end
local function pkey(wx, wy) return (wx + 1000000) * 4096 + wy end
local function tile(wx, wy, create) local k = tkey(wx, wy); local t = R.tiles[k]; if not t and create then t = { recs = {}, n = 0, tx = floor(wx / TS), ty = floor(wy / TS) }; R.tiles[k] = t end; return t end
R.cam = R.cam or { x = 0, y = 0 }
local function markSeen(wx1, wy1, wx2, wy2)
  for ty = floor(wy1 / TS), floor(wy2 / TS) do for tx = floor(wx1 / TS), floor(wx2 / TS) do
    local t = tile(tx * TS, ty * TS, true)
    local x1, y1, x2, y2 = math.max(wx1, tx*TS), math.max(wy1, ty*TS), math.min(wx2, tx*TS+TS-1), math.min(wy2, ty*TS+TS-1)
    if not t.sx1 then t.sx1, t.sy1, t.sx2, t.sy2 = x1, y1, x2, y2 else t.sx1 = math.min(t.sx1, x1); t.sy1 = math.min(t.sy1, y1); t.sx2 = math.max(t.sx2, x2); t.sy2 = math.max(t.sy2, y2) end end end
end
local function fillRegion(x1, y1, x2, y2)
  local cx, cy = R.cam.x, R.cam.y
  for y = y1, y2 do local wy = y + cy
    for x = x1, x2 do local wx = x + cx
      local t = tile(wx, wy, false)
      if t and t.sx1 and wx >= t.sx1 and wx <= t.sx2 and wy >= t.sy1 and wy <= t.sy2 then
        local k = pkey(wx, wy); local r = t.recs[k]
        if r then local p = sim.partCreate(-1, x, y, r[1]); if p and p >= 0 then sim.partProperty(p, "temp", r[2]); if r[3] ~= 0 then sim.partProperty(p, "ctype", r[3]) end; if r[4] ~= 0 then sim.partProperty(p, "tmp", r[4]) end; if r[5] ~= 0 then sim.partProperty(p, "life", r[5]) end end; t.recs[k] = nil; t.n = t.n - 1 end
      else local el = gen(wx, wy); if el then local e = eid(el); if e then sim.partCreate(-1, x, y, e) end end end
    end
  end
  markSeen(x1 + cx, y1 + cy, x2 + cx, y2 + cy)
end
local function shiftCam(dx, dy)
  R.cam.x = R.cam.x + dx; R.cam.y = R.cam.y + dy
  local cx, cy = R.cam.x, R.cam.y
  for i in sim.parts() do local x, y = sim.partPosition(i); x, y = floor(x + 0.5) - dx, floor(y + 0.5) - dy
    if x < M or x >= W - M or y < M or y >= H - M then
      local wx, wy = x + cx, y + cy; local t = tile(wx, wy, true)
      t.recs[pkey(wx, wy)] = { sim.partProperty(i, "type"), sim.partProperty(i, "temp"), sim.partProperty(i, "ctype") or 0, sim.partProperty(i, "tmp") or 0, sim.partProperty(i, "life") or 0 }; t.n = t.n + 1
      sim.partKill(i)
    else sim.partPosition(i, x, y) end
  end
  -- the exposed strips are filled on the NEXT tick: TPT rebuilds its position map at the start of each frame,
  -- and partCreate consults that map, so filling now would be refused where particles just moved away
  R.pendingFill = R.pendingFill or {}
  if dx > 0 then R.pendingFill[#R.pendingFill+1] = {W - M - dx, M, W - M - 1, H - M - 1} elseif dx < 0 then R.pendingFill[#R.pendingFill+1] = {M, M, M - dx - 1, H - M - 1} end
  if dy > 0 then R.pendingFill[#R.pendingFill+1] = {M, H - M - dy, W - M - 1, H - M - 1} elseif dy < 0 then R.pendingFill[#R.pendingFill+1] = {M, M, W - M - 1, M - dy - 1} end
end
local function flushFill() local pf = R.pendingFill; if not pf or #pf == 0 then return end; R.pendingFill = {}; for _, r in ipairs(pf) do fillRegion(r[1], r[2], r[3], r[4]) end end
R._testShiftCam = shiftCam; R._testFlushFill = flushFill   -- dev-only verification exposure
-- smooth follow: up to 4px every other frame (a full-canvas shift costs ~15ms). Inlined below.
-- Arrow keys nudge these, shifting where on screen the auto-follow below
-- targets the character -- lets you see further above/below/either side
-- without taking over the camera outright; it still follows your character,
-- just recentred around this offset instead of dead centre.
R.camYOffset = R.camYOffset or 0
R.camXOffset = R.camXOffset or 0

-- Camera zoom (Ctrl+Up / Ctrl+Down). Scales the whole rendered world via the
-- engine's ren.cameraZoom; the HUD is drawn after the sim image lands in the
-- screen buffer, so it stays crisp at 1:1 while the world magnifies.
--
-- Guarded on the binding existing: ren.cameraZoom ships in a C++ change that is
-- compiled but not yet linked (the running game holds powder.exe). Until that
-- rebuild happens this is a no-op that says so, rather than throwing -- calling a
-- nil field from a key handler is exactly the nil-crash class that has bitten
-- this project seven times.
R.camZoom = R.camZoom or 1
function R.setCamZoom(delta)
  if not (ren and ren.cameraZoom) then
    R.hint = "Camera zoom needs the pending engine rebuild"
    return false
  end
  local z = math.max(1, math.min(4, (R.camZoom or 1) + delta))
  R.camZoom = z
  local ok = pcall(ren.cameraZoom, z)
  if not ok then R.hint = "Camera zoom unavailable"; return false end
  R.hint = (z <= 1) and "Zoom: off" or string.format("Zoom: %.1fx  (Ctrl+Down to zoom out)", z)
  return true
end

local CAM_OFFSET_MAX = 150
local function updateCamera()
  if R.frame % 2 == 1 then return end
  local px, py = R.P.x - R.cam.x, R.P.y - R.cam.y
  local ex, ey = px - (306 + R.camXOffset), py - (200 + R.camYOffset)
  local dx = (math.abs(ex) > 20) and math.max(-4, math.min(4, floor(ex * 0.25 + (ex > 0 and 0.5 or -0.5)))) or 0
  local dy = (math.abs(ey) > 28) and math.max(-4, math.min(4, floor(ey * 0.25 + (ey > 0 and 0.5 or -0.5)))) or 0
  if math.abs(ex) > 20 and dx == 0 then dx = ex > 0 and 1 or -1 end
  if math.abs(ey) > 28 and dy == 0 then dy = ey > 0 and 1 or -1 end
  -- SKY CEILING, raised 2026-09-01 from -300 to -900.
  -- PhoenixFire808: "I was walking along and it wouldn't let my guy go up any higher,
  -- I was trying to go over this mountain -- that's a huge problem."
  -- It was never terrain stopping him: worldgen produces real climbable ground up to
  -- about y = -755 (verified by replicating the live noise formula), and gen(wx,wy) is a
  -- pure function of world coords so the world is already effectively unbounded -- only a
  -- 612x384 window is ever materialised. This clamp was the entire ceiling, sitting 455px
  -- BELOW the top of the mountains it was hiding.
  -- -900 leaves ~145px of headroom above the tallest generated peak. Keep this in sync
  -- with the navigation bound near the bottom of this file (search SKY CEILING).
  if R.cam.y + dy < -900 then dy = -900 - R.cam.y end
  if R.cam.y + dy > DEPTH - H + 20 then dy = DEPTH - H + 20 - R.cam.y end
  if dx ~= 0 or dy ~= 0 then shiftCam(dx, dy) end
end
local CAM_OFFSET_STEP = 3
-- Up arrow: target moves DOWN-screen (larger Y) so the character sits lower,
-- revealing more of what's above. Down arrow does the opposite. Same idea
-- for left/right. Got this backwards the first time (up revealed below
-- instead of above) -- signs flipped here. Always on, not tied to
-- sandbox/TPT-menu mode, since it's just a viewing preference either way.
local function adjustCamOffsets()
  if R.keys.up then R.camYOffset = math.min(CAM_OFFSET_MAX, R.camYOffset + CAM_OFFSET_STEP) end
  if R.keys.down then R.camYOffset = math.max(-CAM_OFFSET_MAX, R.camYOffset - CAM_OFFSET_STEP) end
  if R.keys.left then R.camXOffset = math.min(CAM_OFFSET_MAX, R.camXOffset + CAM_OFFSET_STEP) end
  if R.keys.right then R.camXOffset = math.max(-CAM_OFFSET_MAX, R.camXOffset - CAM_OFFSET_STEP) end
end
-- Ctrl+Up/Down zoom REMOVED: it drove TPT's native magnifier lens (no real
-- camera-scale concept exists anywhere in this renderer), and that was the
-- wrong tool for the job in two ways -- it didn't read as "zoom in on my
-- character" at all, and the lens could get stuck fully on with no obvious
-- way off (nothing turned it off except holding Ctrl+Down back down to
-- exactly 1x, and if the mouse then happened to sit over the lens area, a
-- second overlay -- the fine-placement palette, which shows whenever the
-- cursor is inside the zoom lens -- popped up too and looked stuck).
-- A real "zoom the whole view in on the player" needs an actual engine
-- rendering change; flagged in TODO.md rather than re-attempted here.
function R.generateWorld(seed)
  R.seed = seed or 7; R.tiles = {}; surfCache = {}; treeCache = {}; R.treeMoisture = {}
  -- a new world is a fresh start: nothing carries over
  R.inventory = {}; R.hotbar = {}; R.sel = 1; R.acc = {}; R.accOff = {}; R.accOwned = {}; R.deaths = 0
  R.TOOLS = { pick = { name="wood pick", power=1, reach=24, speed=8, radius=3 }, axe = { name="axe", power=1, reach=26, speed=6, radius=4, only={WOOD=1, PLNT=1, GRSS=1} },
              sword = { name="wood sword", reach=34, dmg=15, speed=12 }, torch = { name="torch", reach=26 }, bucket = { name="bucket", reach=26 } }
  -- R.invSlots MUST reset to {}, not nil (unlike this looking like every
  -- other field on this line) -- ui.lua's syncInvSlots() does `ipairs(R.invSlots)`
  -- with no nil-guard, so `nil` here threw "bad argument #1 to 'ipairs'" the
  -- instant the CARRIED tab was drawn on any freshly generated world, forever
  -- after (the error was silently swallowed into R.pluginErr) -- the bag's
  -- inventory tab read as permanently empty no matter what you'd crafted.
  -- A NEW world must always start in normal survival mode. R.sandbox was never
  -- reset here, so once it got toggled on even once (dev testing, or an
  -- accidental menu click), every future "New Seed" silently inherited it --
  -- exactly the reported "why am I starting in creative/sandbox" bug.
  -- Survival is the default. Create World can opt into sandbox for this seed
  -- via R.createSandbox; that choice is applied after the wipe so it is not
  -- inherited from a previous session the way the old bug did.
  local wantSandbox = R.createSandbox == true
  -- Flat map type drives world.lua's flatWorldGen(). Set BEFORE fillRegion below,
  -- since that is what actually stamps terrain.
  R.flatTestWorld = (R.mapType == "flat")
  R.sandbox = false
  -- Same class of bug as R.sandbox above: R.setTptMenus() (the function that
  -- actually calls tpt.hud/tpt.menu_enabled to hide native TPT's far-right
  -- toolbar and bottom bar) was ONLY ever invoked manually from the Esc menu
  -- toggle -- never automatically at world start. R.tptMenus reading false by
  -- default is just an inert Lua variable; it never proved the real native
  -- HUD calls actually fired. the owner: native menus visible unless he's actually
  -- in sandbox/build mode. Calling it for real here so the native UI state
  -- actually matches the RPG's own state from the first frame of play.
  pcall(R.setTptMenus, false)
  R.machines = {}; R.EN = {}; R.invSlots = {}; R.craftScroll = 0; R.invOpen = false; R.brushShape = "square"; R.brushRx = 1; R.brushRy = 1; R.brush = 1
  runHooks(R.hooks.newworld)
  R.frame = R.frame or 0; R.day = 1; R.log = {}; R.hp = 100
  -- never rewind R.frame: every cooldown is a frame timestamp (a reset made tools dead for minutes after "New world")
  R.lastMine, R.lastPlace, R.lastSwing, R.lastHitAt, R.lastSunburnAt, R.hurt, R.shake, R.swingAt, R.blockHits = nil, nil, nil, nil, nil, nil, nil, nil, {}
  R.stations, R.torches, R.chests, R.oreCells = {}, {}, {}, nil; R.stats = { mined = {}, crafted = {}, chests = 0, maxDepth = 0 }; R.quest = 1
  R.radZones = {}   -- new world, new coordinates -- old contamination marks would be meaningless here (R.radAccum, the player's own dose, persists on purpose)
  -- Same argument as R.radZones above, for the two world-coordinate-keyed tables that
  -- were missed: R.treeHP is keyed by a packed absolute world coord, so a leftover
  -- "this trunk already took 40 damage" entry silently applies to whatever brand-new
  -- tree lands on that coord in the fresh world (it has no self-cleanup -- checkFell
  -- only drops a key when that exact tree is fully felled, so partially-chopped trees
  -- accumulate forever across regens). R.pendingAir ("wx,wy" -> delayed cavity
  -- ventilation) does self-heal via pendingAirTick, but a stale entry can still
  -- mis-prime R.ventilationAt for a cell that is solid rock in the new world.
  R.treeHP = {}; R.pendingAir = {}
  R.lastMine = nil; R.lastSwing = nil; R.lastPlace = nil; R.lastHitAt = nil; R.blockHits = {}  -- frame-stamped cooldowns must reset with R.frame, or mining/chopping/placing stays dead after a new seed until the frame counter climbs back up
  if R.grid == nil then R.grid = true end  -- build grid on by default
  R.P.x = 0
  -- On a flat map surfaceAt() still reports hill noise, but flatWorldGen ignores it and
  -- fills solid ROCK from FLAT_SURFACE_Y down -- so spawning at surfaceAt(0) would drop
  -- the player inside rock or leave him falling. R.FLAT_SURFACE_Y is published by
  -- world.lua when available; 200 is that file's own constant and the fallback.
  R.P.y = (R.flatTestWorld and ((R.FLAT_SURFACE_Y or 200) - 1)) or (surfaceAt(0) - 1)
  R.P.vx, R.P.vy = 0, 0
  R.cam.x = floor(R.P.x) - 306; R.cam.y = floor(R.P.y) - 200
  sim.clearSim(); fillRegion(M, M, W - M - 1, H - M - 1); R.clearAround()
  do -- classic Fire display so FIRE/LAVA/PLSM render as blazing gradients instead of flat orange pixels
    local RE, RF, RB, RS = 0x01, 0x02, 0x20, 0x40
    pcall(function() RE = ren.RENDER_EFFE or RE; RF = ren.RENDER_FIRE or RF; RB = ren.RENDER_BASC or RB; RS = ren.RENDER_SPRK or RS end)
    pcall(ren.renderModes, { RE, RF, RB, RS })   -- per knowledge/research-tooling: set modes directly, never useDisplayPreset
  end
  say("World " .. R.seed .. "  " .. (MAP_TYPE_LABEL[R.mapType or "mixed"] or "Mixed") .. ".  Esc = menu & controls")
  R.setMenuOpen(R.tipsOn ~= false)
  if wantSandbox then R.sandbox = true; pcall(R.sandboxUnlock); say("SANDBOX: everything unlocked") end  -- TPT menus left alone on purpose: independent toggle, see R.toggleSandbox
  if R.releaseMouse then R.releaseMouse() end
  R._placeGraceUntil = (R.frame or 0) + 48
end

-- ================================================================ player (world coords; collision read from the canvas)
R.P = R.P or { x = 0, y = 100, vx = 0, vy = 0, onGround = false, coyote = 0, face = 1, anim = 0 }
local GRAV, RUN0, ACC, JUMP, MAXFALL = 0.24, 1.6, 0.3, -2.75, 4.5
local BOXL, BOXR, BOXT = -2, 1, -10
local PLATFORM = { WOOD = 1 }        -- Terraria platforms: stand on top, jump up through, S drops through
local PASS = { GRSS=1, PLNT=1, WOOD=1, VINE=1, SNOW=1, WATR=1, DSTW=1, SLTW=1, LAVA=1, OIL=1, GAS=1, SMKE=1, FIRE=1, WTRV=1, PLSM=1, CO2=1, O2=1, H2=1, HYGN=1, OXYG=1, NBLE=1, NEUT=1, PHOT=1, ELEC=1, GLOW=1, BLD=1 }
-- Molten element default temperatures (K). When sim.partCreate spawns one of these
-- particles, TPT defaults to ambient (~295K), and the particle immediately converts
-- to a cool form (LAVA->STNE, FIRE/SMKE disappear) within 1-3 frames. Forcing the
-- spawn temperature to the element's native hot value keeps it molten until it
-- loses heat to surroundings. Lab-verified against elem.property(id, "Temperature").
local MOLTEN_TEMPS = { LAVA = 1795, FIRE = 900, PLSM = 8000 }
local function setMoltenTemp(p, el)
  local t = MOLTEN_TEMPS[el]
  if t and p and p >= 0 then pcall(sim.partProperty, p, "temp", t) end
end
local function solidW(wx, wy)
  -- SANDBOX COLLISION. Reported: "he keeps vibrating around like a crazy motherfucker."
  -- Two causes, both from reusing world-space collision in a place that has no world:
  --  (a) this subtracts R.cam to convert world->screen, but a sandbox has no camera and the
  --      character is positioned directly in screen space, so every test was offset by whatever
  --      the camera happened to be;
  --  (b) worse, near the screen edge it falls back to gen(wx, wy) -- the WORLD GENERATOR -- and
  --      happily reports solid rock that does not exist on the canvas. He was colliding with a
  --      phantom world, being pushed out, falling back in, and oscillating.
  -- In sandbox there is exactly one source of truth: the particles actually on screen.
  if R.sandboxMode then
    if wx < 4 or wx > 607 or wy > 379 then return true end   -- canvas edges are walls and floor
    if wy < 4 then return false end
    local sp = sim.partID(wx, wy)
    if not sp then return false end
    local st = sim.partProperty(sp, "type")
    if not st or st == 0 then return false end
    return not PASS[nameOf(st)]
  end
  if wy >= DEPTH then return true end
  local x, y = wx - R.cam.x, wy - R.cam.y
  if x < M or x >= W - M or y < M or y >= H - M then local g = gen(wx, wy); return g ~= nil and not PASS[g] end
  local p = sim.partID(x, y); if not p then return false end
  local t = sim.partProperty(p, "type"); if t == eid("FIGH") then return false end
  if PASS[nameOf(t)] then return false end
  return true
end
R.solidW = solidW
local function boxBlocked(x, y) for yy = y + BOXT, y - 1 do for xx = x + BOXL, x + BOXR do if solidW(xx, yy) then return true end end end; return false end
-- Same camera correction as solidW: in sandbox screen space IS world space.
local function platformAt(wx, wy)
  if R.sandboxMode then
    local sp = sim.partID(wx, wy)
    if not sp then return false end
    return PLATFORM[nameOf(sim.partProperty(sp, "type"))] == 1
  end
  local x, y = wx - R.cam.x, wy - R.cam.y
  if x < M or x >= W - M or y < M or y >= H - M then return false end
  local p = sim.partID(x, y); if not p then return false end
  return PLATFORM[nameOf(sim.partProperty(p, "type"))] == 1 end
R.platformAt = platformAt
local function footBlocked(x, y, vy)
  for xx = x + BOXL, x + BOXR do
    if solidW(xx, y) then return true end
    if vy and vy >= 0 and platformAt(xx, y) and not platformAt(xx, y - 1) and R.P.dropThru ~= y then return true end
  end
  return false end

-- Shared reset for the death-pollution envelope. v1.15.4 added these to
-- R.spawnPlayer() to fix the surface-respawn death-loop (respawning still
-- poisoned you because R.o2 was 0 and R.gas held CO/CO2/rad/heat from
-- wherever you died). F5 (v1.15.9) extracted the same block here so the
-- survival.lua bed-respawn wrap can call it too -- same bug class, just on
-- a different spawn path. Don't touch hp here -- callers control hp (death
-- forces 100, Magic Mirror preserves, bed wrap sets max(current, 40)).
function R._resetSpawnState()
  R.o2 = 100
  if R.gas then R.gas.co = 0; R.gas.co2 = 0; R.gas.ch4 = 0; R.gas.rad = 0; R.gas.heat = 0 end
  if R.need then R.need.food = 100; R.need.water = 100 end
  R.hurt = nil; R.bloodLast = nil; R.bloodSprayLeft = 0; R.lastBloodBurst = nil; R.uvAccum = 0; R.radAccum = 0
end
-- Companion teleport + spawn-area clear. v1.15.7 added both inline to
-- R.spawnPlayer() body (F1 companion teleport at the time, F8 R.clearAround()),
-- but the survival.lua bed-respawn wrap takes an early-return path that
-- skips the entire core body. F9 (v1.15.10) extracted both here so the bed
-- wrap can call them too. Companion teleport is gated on active+not-dead
-- so it doesn't fight the REVIVE_DELAY auto-respawn path in
-- companion.lua:856-861. R.clearAround reads R.P.x/R.P.y itself, so callers
-- just need to set R.P first (core does surfaceAt(0), bed wrap does the
-- bed coords).
function R._teleportCompanionAndClear()
  if R.COMP and R.COMP.active and not R.COMP.dead then local C = R.COMP; C.x = R.P.x - (C.face or 1) * 12; C.y = R.P.y end
  R.clearAround()
end
-- R.P.x/R.P.y; both call sites (generateWorld line ~840, R.spawnPlayer line 926)
-- already pass nothing. Was lost in the v3 rewrite (commit 6c8d889); re-added
-- here in v1.15.7 (F8).
function R.clearAround() local x, y = floor(R.P.x), floor(R.P.y); for yy = y - 12, y - 1 do for xx = x - 3, x + 2 do local p = sim.partID(xx, yy); if p then sim.partKill(p) end end end end
function R.spawnPlayer() R.P.x = 0; R.P.y = surfaceAt(0) - 1; R.P.vx, R.P.vy = 0, 0
  -- Death/respawn used to leave a polluted gas envelope (CO/CO2 from the
  -- firebox that killed you, deep-heat rad, etc.) AND a starving food/water
  -- meter AND a stuck R.hurt/R.bloodLast timestamp AND R.o2 at whatever it
  -- was when you died -- so respawning at the surface still showed
  -- "carbon dioxide build-up" and "you cannot breathe" and HP kept draining
  -- the moment you respawned. Reset them all here so a fresh spawn is
  -- actually fresh. hp stays at whatever it is now (death sets it to 100
  -- this call -- so neither caller has to be touched).
  R._resetSpawnState()   -- pollution envelope (R.o2, gas, need, hurt, accum); shared with survival.lua bed wrap (F5)
  R._teleportCompanionAndClear()   -- F1 (companion teleport, gated active+not-dead) + F8 (clearAbove spawn point); shared with survival.lua bed wrap (F9)
  R.hp = 100
  local dx, dy = floor(R.P.x) - 306 - R.cam.x, floor(R.P.y) - 200 - R.cam.y
  if dx ~= 0 or dy ~= 0 then shiftCam(dx, dy) end end
R.keys = R.keys or {}
local fireHook   -- defined in the actions section; used by the double-tap-jump grapple
local function movePlayer()
  -- Space is the native TPT pause key (GameView's own hardcoded hotkey, fires no
  -- matter what this script does with the keypress) -- so when the sim is paused,
  -- freeze the character too instead of quietly still walking/jumping around while
  -- everything else in the world stands still.
  if sim.paused() then return end
  R._hpTickStart = R.hp or 100
  R._bloodEligible = false   -- only falls/lava/combat set true; passive O2/poison/hunger must not spray BLD
  local P = R.P
  -- RIDING: a vehicle plugin owns movement while mounted; it sets R.ride.x/y each tick and we follow it
  if R.ride then
    local v = R.ride
    if v.dead then R.ride = nil
    else P.x, P.y = v.x or P.x, (v.y or P.y) - (v.seatY or 2); P.vx, P.vy = 0, 0; P.onGround = true; P.apex = nil
      if R.keys.s and (R.frame - (v.mounted or 0)) > 20 then R.dismount() end
      return end
  end
  local x, y = floor(P.x), floor(P.y)
  local RUN = (R.accOn("boots") and RUN0 * 1.5 or RUN0) * (R.runMul or 1)
  local want = 0; if R.keys.a then want = -RUN end; if R.keys.d then want = RUN end
  if P.hook then local hx, hy = P.hook.x, P.hook.y; local dx, dy = hx - P.x, hy - (P.y - 5); local d = math.sqrt(dx*dx + dy*dy)
    if d < 8 or P.hook.t > 90 then P.hook = nil; P.vy = -1 else P.hook.t = P.hook.t + 1; P.vx = dx / d * 4; P.vy = dy / d * 4
      local nx, ny = floor(P.x + P.vx), floor(P.y + P.vy)
      if not boxBlocked(nx, ny) then P.x, P.y = P.x + P.vx, P.y + P.vy else P.hook = nil; P.vx, P.vy = 0, 0 end
      P.onGround = footBlocked(floor(P.x), floor(P.y) + 1, 1); return end end
  if want ~= 0 then P.face = want > 0 and 1 or -1 end
  local inWater = false; do local p = sim.partID(x - R.cam.x, y - 5 - R.cam.y); if p then local n = nameOf(sim.partProperty(p, "type")); inWater = (n == "WATR" or n == "DSTW" or n == "SLTW") end end
  P.vx = P.vx + math.max(-ACC, math.min(ACC, want - P.vx))
  if want == 0 then P.vx = P.vx * (P.onGround and 0.5 or 0.9); if math.abs(P.vx) < 0.05 then P.vx = 0 end end
  P.vy = math.min(inWater and 1.2 or MAXFALL, P.vy + (inWater and 0.08 or GRAV * (R.gravMul or 1)))
  if R.keys.s and P.onGround and not P.dropThru then
    -- drop through THIS platform only: remember it, and re-enable platform collision once we are below it
    for xx = x + BOXL, x + BOXR do if platformAt(xx, y + 1) then P.dropThru = y + 1; break end end
  end
  if R.keys.s then P.vy = math.min(MAXFALL, P.vy + 0.3) end
  if P.dropThru and (y > P.dropThru + 3 or not R.keys.s) and P.vy >= 0 then
    local still = false
    for xx = x + BOXL, x + BOXR do if platformAt(xx, P.dropThru) and y <= P.dropThru + 1 then still = true end end
    if not still then P.dropThru = nil end
  end
  if R.keys.w then
    if inWater then P.vy = math.max(-1.5, P.vy - 0.35)
    elseif (P.onGround or P.coyote > 0) and not P.jumpHeld then P.vy = JUMP * (R.jumpMul or 1); P.onGround = false; P.coyote = 0; P.jumpHeld = true; P.jumpFrames = 0
    elseif P.jumpHeld and P.jumpFrames and P.jumpFrames < 5 and P.vy < 0 then P.vy = P.vy - 0.08; P.jumpFrames = P.jumpFrames + 1
    elseif not P.jumpHeld and R.accOn("hook") and not P.onGround and P.coyote == 0 and (R.frame - (P.lastJumpPress or -99)) < 18 and not P.hook then
      P.lastJumpPress = R.frame; fireHook(R.mouse.x, R.mouse.y)
    elseif not P.jumpHeld and R.accOn("cloud") and not P.dj then P.vy = JUMP * (R.jumpMul or 1); P.dj = true; P.jumpHeld = true; P.jumpFrames = 0; P.puff = R.frame
    elseif P.jumpHeld and R.accOn("rocket") and (P.fuel or 0) > 0 and (not P.jumpFrames or P.jumpFrames >= 5) then P.vy = math.max(-2.2, P.vy - 0.45); P.fuel = P.fuel - 1; P.flame = R.frame end
  else if P.jumpHeld then P.lastJumpPress = R.frame end; P.jumpHeld = false end
  if boxBlocked(x, y) then for up = 1, 12 do if not boxBlocked(x, y - up) then y = y - up; break end end end
  local fx = P.x + P.vx; local dir = fx > P.x and 1 or -1
  while floor(fx) ~= x do local tx = x + dir
    if not boxBlocked(tx, y) then x = tx
    else local stepped = false
      for up = 1, 4 do if not boxBlocked(tx, y - up) then x = tx; y = y - up; stepped = true; break end end
      if not stepped then P.vx = 0; fx = x; break end end
  end
  P.x = (floor(fx) == x) and fx or x
  P.landVy = P.vy
  local fy = y + P.vy; local vdir = fy > y and 1 or -1; local landed = false
  while floor(fy) ~= y do local ty = y + vdir
    if vdir > 0 then if footBlocked(x, ty, P.vy) then landed = true; fy = y; break end
    else if boxBlocked(x, ty) then P.vy = 0; fy = y; break end end
    y = ty end
  P.y = (floor(fy) == y) and fy or y
  P.onGround = footBlocked(x, y + 1, math.max(0, P.vy)) or landed
  if not P.onGround then P.apex = math.min(P.apex or P.y, P.y) end
  if P.onGround then
    if P.apex and not inWater then local fall = P.y - P.apex; local landVy = P.landVy or 0
      -- hurts only when you hit the ground fast: hovering/braking (jetpack, rocket boots) before impact makes any fall safe
      if fall > 60 and landVy >= 3.8 and not (R.accOn("cloud") and fall < 90) then local dmg = floor((fall - 60) * 0.5); if dmg > 0 then R.hp = math.max(0, R.hp - dmg); R.hurt = R.frame; R._bloodEligible = true; R.shake = { t = R.frame, mag = math.min(8, 2 + dmg / 5) }; say("Ouch! Fell " .. floor(fall / 4) .. "m (-" .. dmg .. " HP)") end end end
    P.apex = nil
    if P.vy > 0 then P.vy = 0 end; P.coyote = 6; P.dj = false; P.fuel = 45 else P.coyote = math.max(0, P.coyote - 1) end
  if math.abs(P.vx) > 0.2 and P.onGround then P.anim = (P.anim or 0) + 1 end
  if R.frame % 5 == 0 then local dmg = 0
    for yy = y + BOXT - 1, y do for xx = x + BOXL - 1, x + BOXR + 1 do local p = sim.partID(xx - R.cam.x, yy - R.cam.y)
      if p then local n = nameOf(sim.partProperty(p, "type")); local t = sim.partProperty(p, "temp") or 295
        if (n == "LAVA" or n == "FIRE" or n == "PLSM") then if not R.accOn("lava") then dmg = dmg + 3 end elseif n == "ACID" or n == "CAUS" then dmg = dmg + 2 elseif t > 500 and not R.accOn("lava") then dmg = dmg + 1 elseif n == "NEUT" then dmg = dmg + 1 end end end end
    if dmg > 0 then R.hp = math.max(0, R.hp - dmg); R.hurt = R.frame; R._bloodEligible = true end
    -- Ambient comfort commentary: a wider, non-damaging temperature sense
    -- (nearby fire/lava reads hot well before it's actually touching you)
    -- that only speaks up when you cross into a new tier, not on a timer,
    -- so it doesn't spam every few seconds while just standing near a torch.
    if R.frame % 180 == 0 then
      local hottest = 295
      for yy = y - 14, y + 6 do for xx = x - 14, x + 14 do
        local p = sim.partID(xx - R.cam.x, yy - R.cam.y)
        if p then local t = sim.partProperty(p, "temp") or 295; if t > hottest then hottest = t end end
      end end
      local tier = hottest > 500 and "burning" or hottest > 330 and "hot" or hottest < 250 and "freezing" or hottest < 273 and "cold" or "normal"
      if tier ~= (R.comfortTier or "normal") and tier ~= "normal" then
        if tier == "burning" then say("It's scorching here - I need to get away from this heat!")
        elseif tier == "hot" then say("It's uncomfortably hot here")
        elseif tier == "freezing" then say("I'm freezing out here!")
        elseif tier == "cold" then say("It's getting cold") end
      end
      R.comfortTier = tier
      -- feltTempK owned by sampleEnvGradient (depth-column min/max); comfort scan is commentary only
    end
    -- OXYGEN as a real concentration, not a timer:
    -- breathable air comes from (a) open sky above you, (b) real OXYG particles nearby, (c) plants/machines
    -- registered in R.o2Sources. Sealed spaces deplete as you breathe; smoke and heavy gases displace air.
    do
      local BAD = { SMKE=1, CO2=1, H2=1, HYGN=1, NBLE=1, GAS=1, WTRV=1, PLSM=1, FIRE=1, CAUS=1, BOYL=1, NEUT=1 }
      local LIQ2 = { WATR=1, DSTW=1, SLTW=1, LAVA=1, OIL=1 }
      -- Dense scan (every pixel), not a 4px-spaced grid: OXYG particles are sparse
      -- enough that a coarse grid regularly missed real particles sitting a pixel or
      -- two off-grid, so breathing only "counted" when you happened to be standing
      -- exactly on a sample point -- reads as needing to be right on top of it.
      local o2p, bad, liq, cells = 0, 0, 0, 0
      local BR = R.O2_BREATH_R or 48
      local BCY = R.O2_BREATH_CY or -8
      for oy = -BR, BR, 2 do for ox = -BR, BR, 2 do
        if ox * ox + (oy + BCY) * (oy + BCY) <= BR * BR then
          cells = cells + 1
          local p = sim.partID(x + ox - R.cam.x, y + oy - R.cam.y)
          if p then local n = nameOf(sim.partProperty(p, "type"))
            if n == "OXYG" then o2p = o2p + 1 elseif BAD[n] then bad = bad + 1 end end
        end
      end end
      -- you only drown when your HEAD is under: wading through shallow water is fine
      for oy = -12, -8 do local p = sim.partID(x - R.cam.x, y + oy - R.cam.y)
        if p and LIQ2[nameOf(sim.partProperty(p, "type"))] then liq = liq + 1 end end
      -- Is there a way up to open sky? A single column exactly above the
      -- player was too strict -- a hand-dug hole is rarely a perfectly
      -- straight shaft directly overhead (you dig at an angle, walk under
      -- an overhang, etc.), so a real, obviously-open dug-out space kept
      -- reading as "sealed" just because the ONE column checked happened to
      -- still have rock in it. Checks a small spread of nearby columns
      -- instead and counts it open if ANY of them has a mostly-clear path.
      local sealed = true
      for cx = -4, 4, 2 do
        local blocked = 0
        for k = 4, 90, 3 do local p = sim.partID(x + cx - R.cam.x, y - k - R.cam.y)
          if p then local n = nameOf(sim.partProperty(p, "type")); if not PASS[n] then blocked = blocked + 1 end end end
        if blocked <= 1 then sealed = false; break end
      end
      -- nearby oxygen sources (plants, air pumps, greenhouses register themselves)
      local src = 0
      for _, s2 in ipairs(R.o2Sources or {}) do
        if math.abs(s2.x - R.P.x) < (s2.range or 60) and math.abs(s2.y - R.P.y) < (s2.range or 60) then src = src + (s2.rate or 20) end end
      R.o2conc = math.min(100, floor(o2p / math.max(1, cells) * 300))     -- measured O2 enrichment
      local particleBreath = math.min(100, R.o2conc * 1.4)
      local target
      -- Depth thinning: meaningful by ~200px (old curve needed 1000px+ to matter).
      local depth = R.P.y - surfaceAt(floor(R.P.x))
      local thin = math.max(0, math.min(80, (depth - 20) / 200 * 80))
      local pvent = (depth > 8 and R.ventilationAt) and R.ventilationAt(x, y) or 1
      if liq > 0 and (R.acc and R.accOn("dive")) ~= true then target = 0   -- underwater: nothing to breathe
      else
        local base = 100 - thin + src
        if sealed then
          -- Sealed pocket: small trapped reservoir; real OXYG particles or ventilation refill it.
          local pocket = math.max(0, 24 - thin * 0.4 - bad * 10)
          target = math.max(pocket, particleBreath * 0.55)
        else
          target = base
        end
        -- Freshly mined / unventilated cavities: stale air, NOT full target (bug was stale=target when sealed).
        -- Skip when real OXYG particles are already in the breath circle — visible bubbles ARE breathable air.
        if depth > 8 and pvent < 1 and particleBreath < 18 then
          local stale = base * 0.28 + particleBreath * 0.85
          if sealed and particleBreath < 12 then stale = math.min(stale, 10 + particleBreath * 1.2) end
          target = stale + (target - stale) * pvent
        end
        -- Deep with no visible OXYG and no shaft vent: meter cannot stay "fine".
        if depth > 40 and R.o2conc < 4 and pvent < 0.35 then
          target = math.min(target, 6 + R.o2conc * 2 + pvent * 25)
        end
        -- Measured OXYG must not lose to abstract vent/stale math (shallow hole + bubbles bug).
        -- MEASURED SUPPLY BEATS ESTIMATES. Everything above this point is *estimated* air
        -- (depth thinning, sealed-pocket guesses, stale-air and deep-suffocation caps). The two
        -- floors below are *measured* reality, so they are deliberately applied last.
        --
        -- (1) PLAYER-DEATH BUG (2026-08-31): died underground "even though I saw oxygen bubbles
        -- within range". The old gate here was `particleBreath >= 10`, i.e. `o2conc >= 7.14`.
        -- o2conc divides the particle count by EVERY sampled cell in the breath circle
        -- (measured live: 1737 samples), so it really demanded ~47 OXYG particles inside one
        -- 48px circle -- against a screen-wide OXYG cap of 220. A realistic handful of ~10
        -- bubbles scored o2conc ~1.7, this floor never fired, the deep cap just above then
        -- forced target to ~6-9, and death damage begins at o2 <= 12. Gate on the real particle
        -- count instead: a breathed oxygen particle is worth a real breath.
        -- the owner's spec, 2026-08-31: "if there's oxygen in my guy's range he needs to be
        -- replenishing it like all the way full, like if it's available." Breathing is
        -- binary, not a dosage curve -- a person standing in breathable air does not get
        -- 62% of a breath because the air is locally a bit thin. Either there is air to
        -- breathe or there isn't. The earlier `28 + o2p * 2.6` ramp was a reasonable step up
        -- from the broken state (which needed ~47 particles before it registered at all), but
        -- this is the destination. The `>= 4` gate stays so a single stray particle drifting
        -- through a vacuum isn't mistaken for an atmosphere.
        if o2p >= 4 then
          target = math.max(target, 100)
        end
        -- (2) OXYGEN-MACHINE BUG (2026-08-31): "built a little electrolysis machine underground
        -- and my oxygen still isn't refilling completely". `src` (the summed rate of every
        -- registered R.o2Sources emitter in range) was folded ONLY into `base`, and `base` is
        -- read only by the NOT-sealed branch -- so in a sealed room, which is the entire reason
        -- to build life support, the machine's output was computed and then silently discarded.
        -- Worse, all three limiters ignored it too: the sealed pocket, the stale cap
        -- (`min(stale, 10 + ...)`) and the deep cap (`min(target, 6 + ...)`), so a powered
        -- generator in a deep sealed base still got clamped to ~6. Applying it here as a floor
        -- fixes all three at once, and matches the promise of building life support: a
        -- well-supplied sealed room approaches full air. o2gen(18) -> 93, lifesupport(14) -> 79,
        -- airpump(10) -> 65, bellows(8) -> 58. Sources sum, so a bigger installation gets closer
        -- to 100.
        if src > 0 then
          target = math.max(target, math.min(100, 30 + src * 3.5))
        end
      end
      R.o2 = R.o2 or 100
      local rate = (target > R.o2) and 3 or ((liq > 0) and 1.6 or 0.9)
      R.o2 = math.max(0, math.min(100, R.o2 + (target > R.o2 and rate or -rate)))
      -- AMBIENT VISIBLE O2: the meter above already tracks real breathable
      -- air (o2p/target/thin), but nothing ever actually spawned a real
      -- OXYG particle into open air, so there was never anything to see.
      -- Spread across the WHOLE visible screen, not just a bubble near the
      -- player -- each sample point gets its own depth (via surfaceAt for
      -- that point's own world column), so density varies naturally across
      -- the map the same way it would in reality: thick near any patch of
      -- open sky/shallow cave, thin near any patch that's genuinely deep,
      -- regardless of where the character currently happens to stand.
      -- Surface density bumped up (0.15 -> 0.4 chance, 3 -> 6 samples, every
      -- 8 ticks -> every 5) so it actually reads as abundant up top, not
      -- sparse -- depth falloff (wthin/density above) still thins it out
      -- underground on its own. Capped total on-screen count so it settles
      -- into a steady abundant-but-not-spammy population instead of
      -- accumulating without bound (O2 dissipates slowly on its own).
      -- Seed oxygen at the real ground line for random columns, not at a random depth
      -- across the whole screen -- a fresh reservoir sitting on the surface, exactly
      -- like real air. Anywhere it reaches beyond that (a dug shaft, an open cave) is
      -- down to the sim's own gas diffusion carrying it there, not scripted spawning --
      -- that's what makes "dig a hole to the surface and oxygen pools in" actually true
      -- instead of an illusion.
      local OXYG_CAP = 220
      if liq == 0 and R.frame % 5 == 0 and o2OnScreenCount() < OXYG_CAP and depth < 50 then
        for i = 1, 6 do
          local sx = math.random(2, W - 3)
          local wx = sx + R.cam.x
          local surfY = surfaceAt(floor(wx))
          -- Band kept tight to the ground (2-8px), not up at canopy height (trees run
          -- roughly 10-30px above the surface) -- GRSS/leaves are a real solid element
          -- that physically blocks gas particles, so anything spawned up in the canopy
          -- was getting trapped in the gaps between leaf clusters, visibly pooling
          -- "stuck between the trees" instead of dispersing. Real diffusion still
          -- carries some of it up there naturally over time; this just stops seeding
          -- it directly into a spot it can't easily get back out of.
          local wy = surfY - math.random(2, 8)
          local sy = wy - R.cam.y
          if R.nearestTreeDrain and R.nearestTreeDrain(wx, wy) then goto o2_spawn_next end
          if R.treeShadeDrain and R.treeShadeDrain(wx, wy) then goto o2_spawn_next end
          if sy >= 2 and sy < H - 2 and not sim.partID(sx, sy) then
            local e = eid("OXYG"); if e then sim.partCreate(-1, sx, sy, e) end
          end
          ::o2_spawn_next::
        end
      end
      -- Real positive atmospheric pressure at the surface, not just a low-pressure dip
      -- where you dig: "the atmosphere has to have positive pressure... a real
      -- environment thing." Nudges open-air cells near the surface toward a positive
      -- baseline, so there's a genuine, permanent differential against anything dug
      -- out below (set to -8 above) -- the sim's own physics does the rest, pushing
      -- surface air down through whatever's connected, same mechanism, both ends now
      -- real instead of just the low side.
      if R.frame % 30 == 0 then
        for i = 1, 8 do
          local sx = math.random(2, W - 3)
          local wx = sx + R.cam.x
          local surfY = surfaceAt(floor(wx))
          local wy = surfY - math.random(1, 40)   -- open sky band above the ground
          local sy = wy - R.cam.y
          if sy >= 2 and sy < H - 2 and not solidW(sx + R.cam.x, wy) then
            local cx, cy = floor(sx / sim.CELL), floor(sy / sim.CELL)
            local ok, cur = pcall(sim.pressure, cx, cy)
            if ok and cur < 5.5 then pcall(sim.pressure, cx, cy, math.min(5.5, cur + 1.2)) end
          end
        end
      end
      -- Still reported visibly piling up in tight canopy gaps even after moving the
      -- spawn band down -- real diffusion still drifts some of it up there over time,
      -- and once it's wedged between solid leaf cells it has nowhere to go (that's
      -- real physics, not a bug, but it reads as broken). Periodically release any
      -- OXYG particle that's boxed in on 3+ of its 4 sides, simulating it finding a
      -- way to equalize instead of sitting there forever accumulating.
      -- Bug found 2026-08-29 (after two prior attempts still didn't fix "stuck between
      -- the trees"): this checked neighbors against PASS -- the PLAYER's own walk-
      -- through list, which deliberately includes GRSS/PLNT/WOOD/BLD so you can walk
      -- through grass and leaves. A gas particle doesn't care what the player can walk
      -- through -- leaves are real TYPE_SOLID physics (confirmed live: GRSS/PLNT has
      -- TYPE_SOLID set), so an OXYG particle boxed in by leaves showed "0 blocked
      -- neighbors" under the old check and was never released. Now uses realSolid()
      -- (actual engine Properties/TYPE_SOLID), the real thing that blocks a gas
      -- particle, not the player-collision table. Also switched from randomly sampling
      -- 10 of potentially hundreds of thousands of on-screen pixels (near-zero odds of
      -- ever landing on a real OXYG particle) to actually scanning live OXYG particles.
      if R.frame % 45 == 0 then
        local released = 0
        for _, gasNm in ipairs({"OXYG", "CO2"}) do
          local gasid = eid(gasNm)
          if not gasid then goto gas_next end
          for i in sim.parts() do
            if released >= 28 then break end
            if sim.partProperty(i, "type") ~= gasid then goto part_next end
            local sx, sy = sim.partPosition(i)
            sx, sy = floor(sx), floor(sy)
            local wx, wy = sx + R.cam.x, sy + R.cam.y
            local blocked = 0
            for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
              local q = sim.partID(sx + d[1], sy + d[2])
              if q and realSolid(sim.partProperty(q, "type")) then blocked = blocked + 1 end
            end
            if blocked >= 2 then
              local shade = R.treeShadeDrain and R.treeShadeDrain(wx, wy)
              local nvx, nvy
              if shade and shade.hollowCol then
                local hx = shade.hollowCol - R.cam.x
                nvx = (hx - sx) * 0.4
                nvy = -2.8 - math.random() * 1.5
              elseif blocked >= 3 then
                nvy = -2.5 - math.random() * 1.5
                nvx = (sim.partProperty(i, "vx") or 0) * 0.5 + (math.random() - 0.5) * 2.2
              end
              if nvx then
                -- SAWDUST ROOT CAUSE (2026-08-31). Native TPT turns WOOD into SAWD wherever a
                -- particle collides with it at speed > 5 (Simulation.cpp: `if (vel > 5)
                -- part_change_type(..., PT_SAWD)`). Nothing in this codebase creates SAWD at all,
                -- which is why grepping our own Lua for a sawdust source finds nothing.
                -- The hollow-column nudge here is distance-proportional and was unbounded: venting
                -- a pocket ~13px from its tree's hollow column gives vx = 5.2 on its own, ~6.4 once
                -- combined with vy. So the code written to route oxygen AROUND trunks was blasting
                -- those same trunks into sawdust. Measured live before this fix: the fastest
                -- particles anywhere in the world were OXYG at 4.24-4.62, with nothing else above
                -- 0.01 -- consistent with the observed idle-play drift of WOOD -30 / SAWD +29.
                -- Clamp total speed well under the threshold: this is meant to be a vent, not a
                -- jet, and gas flung at near-destructive speed ricochets instead of diffusing
                -- between trunks the way it's supposed to.
                local mag = math.sqrt(nvx * nvx + nvy * nvy)
                if mag > 3.2 then nvx, nvy = nvx * 3.2 / mag, nvy * 3.2 / mag end
                sim.partProperty(i, "vx", nvx)
                sim.partProperty(i, "vy", nvy)
                released = released + 1
              end
            end
            ::part_next::
          end
          ::gas_next::
        end
      end
      -- Breathing consumes real oxygen particles when they're in range, always -- not
      -- only in sealed pockets. "Sealed" only changes where your baseline air comes
      -- from; real nearby OXYG gets drawn down either way, same as breathing thins the
      -- air right around your face outdoors, it's just replenished fast enough there
      -- not to matter until you're relying on it underground.
      if o2p > 0 and R.frame % 30 == 0 then
        for oy = -12, 0 do for ox = -6, 6 do local sx, sy = x + ox - R.cam.x, y + oy - R.cam.y; local p = sim.partID(sx, sy)
          if p and nameOf(sim.partProperty(p, "type")) == "OXYG" then
            sim.partKill(p)
            R.o2 = math.min(100, (R.o2 or 50) + 7)   -- inhaling a real OXYG particle refills the meter
            -- Breath-glow feed for @ux's renderer: marks the exact particles actually inhaled.
            -- WORLD coordinates on purpose -- the draw path must subtract R.cam itself. Canvas
            -- coords would make any effect outliving one frame slide across the screen as the
            -- camera scrolls instead of staying pinned where the breath happened.
            -- Every consumed particle is recorded (this loop can kill several per tick, and the
            -- whole point is to mark what was really breathed). Hard-capped at 24, oldest
            -- discarded. Two numbers appended at an event that already fires -- deliberately not
            -- a scan; an O(particle-count) scan inside a per-cell loop caused real measured lag
            -- in this project once already.
            R.breathFX = R.breathFX or {}
            R.breathFX[#R.breathFX + 1] = { x = x + ox, y = y + oy, at = R.frame }
            if #R.breathFX > 24 then table.remove(R.breathFX, 1) end
            -- Exhaled CO2: breathing in real O2 breathes real CO2 back out, right where you're
            -- standing. In a sealed space this is what actually makes staying put dangerous over
            -- time (CO2 sinks -- see the H2/GAS/CO2 gravity notes above -- so it pools at your feet
            -- in an unventilated room exactly like the real gas would), not just an abstract meter.
            local co2 = eid("CO2"); if co2 and not sim.partID(sx, sy) then sim.partCreate(-1, sx, sy, co2) end
            return
          end end end
      end
      -- Real photosynthesis: leaves near the player consume nearby CO2 and release O2 --
      -- but only in daylight, the same light-dependent reaction real trees use. Sampled
      -- sparsely (not a full-area scan) like the existing star-field/ambient sampling above.
      if R.frame % 90 == 0 and (((R.frame or 0) % 14000) / 14000) < (R.dayFrac or 0.65) then
        local grss, co2id, oxygid = eid("GRSS"), eid("CO2"), eid("OXYG")
        if grss and co2id and oxygid then
          for i = 1, 8 do
            local lx = floor(x + (hash3(i, 9, 91) - 0.5) * 260) - R.cam.x
            local ly = floor(y + (hash3(i, 10, 92) - 0.5) * 180) - R.cam.y
            local lp = sim.partID(lx, ly)
            if lp and sim.partProperty(lp, "type") == grss then
              for dy = -2, 2 do for dx = -2, 2 do
                local cp = sim.partID(lx + dx, ly + dy)
                if cp and sim.partProperty(cp, "type") == co2id then sim.partProperty(cp, "type", oxygid) end
              end end
            end
          end
        end
      end
      -- ATMOSPHERE HAZARDS: carbon monoxide, carbon dioxide, methane and radiation, plus deep heat.
      do
        local G = R.gas
        local fire, urn, gas2, smk = 0, 0, 0, 0
        for oy = -14, 6, 5 do for ox = -12, 12, 6 do
          local p = sim.partID(x + ox - R.cam.x, y + oy - R.cam.y)
          if p then local n = nameOf(sim.partProperty(p, "type")); local t2 = sim.partProperty(p, "temp") or 295
            if n == "FIRE" or n == "PLSM" or n == "LAVA" or (n == "COAL" and t2 > 500) or (n == "BCOL" and t2 > 500) then fire = fire + 1 end
            if n == "SMKE" or n == "CO2" then smk = smk + 1 end
            if n == "GAS" or n == "OIL" or n == "H2" or n == "HYGN" then gas2 = gas2 + 1 end
            if n == "URAN" or n == "DU" or n == "UO2" or n == "NEUT" or n == "PLUT" then urn = urn + 1 end end
        end end
        local scrub = 0
        for _, sc in ipairs(R.scrubbers) do if math.abs(sc.x - R.P.x) < (sc.range or 70) and math.abs(sc.y - R.P.y) < (sc.range or 70) then scrub = scrub + (sc.rate or 25) end end
        -- incomplete combustion in a poorly ventilated space makes carbon monoxide: fire + low air = CO
        local coMake = (fire > 0 and sealed and R.o2 < 70) and (fire * 2.5 * (1 - R.o2 / 100)) or 0
        G.co  = math.max(0, math.min(100, G.co  + coMake - 1.2 - scrub * 0.12))
        G.co2 = math.max(0, math.min(100, G.co2 + smk * 1.6 + (fire > 0 and sealed and 1.2 or 0) - 1.4 - scrub * 0.14))
        G.ch4 = math.max(0, math.min(100, G.ch4 + gas2 * 2.2 - 2.0))
        local deep = math.max(0, depth - 1100) / 700
        -- Ground contamination: live nuclear material nearby leaves a mark
        -- at the player's current spot instead of the danger vanishing the
        -- instant it's mined out or melted down. Strength adds up if you
        -- linger, caps so one spot can't become infinitely deadly.
        if urn > 0 then
          local hit
          for _, z in ipairs(R.radZones) do if math.abs(z.x - R.P.x) < 40 and math.abs(z.y - R.P.y) < 40 then hit = z; break end end
          if hit then hit.strength = math.min(60, hit.strength + urn * 0.5)
          else R.radZones[#R.radZones + 1] = { x = R.P.x, y = R.P.y, strength = urn * 3 } end
        end
        local zoneRad = 0
        for _, z in ipairs(R.radZones) do
          local d2 = (z.x - R.P.x) * (z.x - R.P.x) + (z.y - R.P.y) * (z.y - R.P.y)
          if d2 < 60 * 60 then zoneRad = zoneRad + z.strength * (1 - math.sqrt(d2) / 60) end
        end
        -- Zones fade over minutes, not seconds -- roughly 1 strength every
        -- 10 seconds at 60fps, so a hot crater actually stays hot a while.
        if R.frame % 600 == 0 then
          local kept = {}
          for _, z in ipairs(R.radZones) do
            z.strength = z.strength - 1
            if z.strength > 0.5 then kept[#kept + 1] = z end
          end
          R.radZones = kept
        end
        G.rad = math.max(0, math.min(100, G.rad + urn * 3 + zoneRad * 0.4 + deep * 1.2 - 1.5 - ((R.inventory.LEAD or 0) > 0 and 1.5 or 0)))
        -- Long-term dose: barely clears on its own (real radiation sickness
        -- doesn't just wear off because you left the room), and eats away
        -- at you passively once it builds up, independent of the live
        -- reading -- the actual lasting cost of having been exposed.
        if G.rad > 30 then R.radAccum = math.min(100, R.radAccum + (G.rad - 30) * 0.008)
        elseif R.frame % 300 == 0 then R.radAccum = math.max(0, R.radAccum - 0.5) end
        -- Real UV: the sun itself, not a nuclear source -- standing outdoors in
        -- daylight builds a separate, much gentler dose (sunburn, not sickness).
        -- Sheltered (below the surface) or at night, it just fades.
        local uvOutdoors = depth <= 20 and (((R.frame or 0) % 14000) / 14000) < (R.dayFrac or 0.65)
        if uvOutdoors then R.uvAccum = math.min(100, R.uvAccum + 0.03)
        elseif R.frame % 300 == 0 then R.uvAccum = math.max(0, R.uvAccum - 1) end
        if R.uvAccum > 70 and R.frame % 300 == 0 and not R.sandbox then
          R.hp = math.max(0, R.hp - 1); R.hurt = R.frame
          -- Round-24 fix: message was repeating every 5s while uvAccum > 70 (300-frame
          -- HP tick = 5s @ 60fps). Gate the message itself with a separate, much longer
          -- cooldown so the HP tick keeps firing (damage still applies) but the chat
          -- only repeats every ~30s. 1800 frames = 30s @ 60fps.
          if not R.lastSunburnAt or (R.frame - R.lastSunburnAt) >= 1800 then
            R.lastSunburnAt = R.frame
            say("Sunburnt (" .. floor(R.uvAccum) .. "% UV exposure) -- get some shade")
          end
        end
        -- geothermal heat: it gets hotter the deeper you are unless something is cooling the room
        local cool = 0
        for _, cl in ipairs(R.coolers) do if math.abs(cl.x - R.P.x) < (cl.range or 70) and math.abs(cl.y - R.P.y) < (cl.range or 70) then cool = cool + (cl.rate or 30) end end
        local heatLoad = math.max(0, (depth - 900) / 900 * 60) + (fire > 0 and sealed and 8 or 0) - cool
        G.heat = math.max(0, math.min(100, G.heat + (heatLoad > G.heat and 1.2 or -1.6)))
        local dmg2 = 0
        if G.co  > 35 then dmg2 = dmg2 + 1 + floor(G.co / 40) end
        if G.co2 > 60 then dmg2 = dmg2 + 1 end
        if G.rad > 45 then dmg2 = dmg2 + 1 + floor(G.rad / 50) end
        if G.heat > 55 then dmg2 = dmg2 + 1 + floor(G.heat / 45) end
        -- Radiation sickness: this is separate from dmg2 above (it isn't
        -- gated on being in a hot zone right now -- accumulated dose keeps
        -- hurting you even standing in clean air, same as the real thing).
        if R.radAccum > 40 and R.frame % 60 == 0 and not R.sandbox then
          R.hp = math.max(0, R.hp - (1 + floor(R.radAccum / 40))); R.hurt = R.frame
          if R.frame % 300 == 0 then say("Radiation sickness (" .. floor(R.radAccum) .. " accumulated dose) -- treat it or let it fade") end
        end
        if dmg2 > 0 and not R.sandbox then R.hp = math.max(0, R.hp - dmg2); R.hurt = R.frame
          if R.frame % 120 == 0 then
            local worst = "the air"
            if G.co > 35 then worst = "carbon monoxide - vent the room or scrub the air"
            elseif G.heat > 55 then worst = "the heat down here - you need cooling"
            elseif G.rad > 45 then worst = "radiation - line the walls with lead"
            elseif G.co2 > 60 then worst = "carbon dioxide build-up" end
            say("You are being poisoned by " .. worst) end end
      end
      -- hunger and thirst tick down slowly; starving or parched drains health
      if R.frame % 90 == 0 and not R.sandbox then
        local N = R.need
        N.food = math.max(0, N.food - 0.35 - ((R.gas.heat or 0) > 30 and 0.15 or 0))
        -- Standing in real water now actually quenches thirst directly, slowly --
        -- reported confusion: "my guy is thirsty even though I go in the water...
        -- doesn't seem straightforward how to make water." A Canteen (survival.lua)
        -- is still the real upgrade (carry water away, boil dirty water), but
        -- being submerged shouldn't do nothing at all -- that's the actual
        -- intuitive expectation for "I'm standing in a lake."
        if inWater then N.water = math.min(100, N.water + 3)
        else N.water = math.max(0, N.water - 0.5 - ((R.gas.heat or 0) > 30 and 0.4 or 0)) end
        if N.food <= 0 or N.water <= 0 then R.hp = math.max(0, R.hp - 2); R.hurt = R.frame
          if R.frame % 360 == 0 then say(N.water <= 0 and "You are dehydrated - find or make clean water" or "You are starving - find food") end
        elseif N.food > 60 and N.water > 60 and R.hp < 100 and R.frame % 180 == 0 then R.hp = math.min(100, R.hp + 1) end
      end
      -- AIR BLADDER: fills in breathable air, releases when you start to run out (early-game portable oxygen)
      if (R.inventory.FLASK or 0) > 0 then
        R.flask = R.flask or 0
        local cap = 100 * math.min(3, R.inventory.FLASK)
        if R.o2 > 75 and R.flask < cap then R.flask = math.min(cap, R.flask + 3.5)
        elseif R.o2 < 45 and R.flask > 0 then
          local give2 = math.min(R.flask, 6); R.flask = R.flask - give2; R.o2 = math.min(100, R.o2 + give2 * 0.9)
          if R.frame % 150 == 0 then say("Air bladder: " .. floor(R.flask) .. " left - refill it in fresh air") end
        end
      end
      if R.o2 <= 12 then R.hp = math.max(0, R.hp - 2); R.hurt = R.frame
        if R.frame % 90 == 0 then say(R.o2 <= 1 and "You cannot breathe!" or "Air is running out - get to the surface or make oxygen") end end
      R.breath = R.o2 * 3
    end
    if R.frame % 60 == 0 and dmg == 0 and R.hp < 100 then R.hp = math.min(100, R.hp + 1) end
  end
  for ty = floor((P.y - 20) / CC), floor((P.y + 20) / CC) do for tx = floor((P.x - 20) / CC), floor((P.x + 20) / CC) do
    local c = R.chestAt(tx, ty); if c and not c.opened and math.abs(c.x + 2 - P.x) < 7 and math.abs(c.y - P.y) < 12 then c.opened = true; R.stats.chests = R.stats.chests + 1; R.giveAcc(c.item) end end end
  if R.hp <= 0 then
    R.deaths = (R.deaths or 0) + 1
    -- Per-item loss breakdown, computed BEFORE halving so the player can see exactly
    -- what each stack lost (was: only the generic "inventory halved" string, so a
    -- "lost 47 wood" or "lost 12 COAL" was invisible). Skip entries where the loss
    -- rounds to zero (one-stack-of-one would say "lost 0", which is noise).
    local lost = {}
    for k, v in pairs(R.inventory or {}) do
      local n = floor(v / 2)
      if n > 0 then lost[#lost+1] = n .. " " .. R.nice(k) end
      R.inventory[k] = n
    end
    table.sort(lost)
    local tail = (#lost > 0) and (" -- lost " .. table.concat(lost, ", ")) or ""
    say("You died. Respawned at the surface; inventory halved" .. tail .. ".")
    R.spawnPlayer()
  end
end
local TOOLCOL = { pick={180,180,190}, axe={170,120,60}, sword={220,220,240}, torch={255,180,60}, bucket={150,150,160} }
local function drawO2BreathField()
  if not R.hud or R.titleScreen or R.menuOpen or R.invOpen then return end
  local fx, fy = floor(R.P.x) - R.cam.x, floor(R.P.y) - R.cam.y
  local BR = R.O2_BREATH_R or 48
  local cx, cy = fx, fy + (R.O2_BREATH_CY or -8)
  local pulse = 0.55 + 0.45 * math.sin((R.frame or 0) / 30)
  local fillA = floor(14 + 18 * pulse)
  local edgeA = floor(65 + 50 * pulse)
  pcall(graphics.fillCircle, cx, cy, BR, BR, 30, 120, 200, fillA)
  pcall(graphics.drawCircle, cx, cy, BR, BR, 70, 170, 255, edgeA)
  local BCY = R.O2_BREATH_CY or -8
  for oy = -BR, BR, 3 do for ox = -BR, BR, 3 do
    if ox * ox + (oy + BCY) * (oy + BCY) <= BR * BR then
      local p = sim.partID(fx + ox, fy + oy)
      if p and nameOf(sim.partProperty(p, "type")) == "OXYG" then
        graphics.fillRect(fx + ox - 1, fy + oy - 1, 3, 3, 100, 210, 255, floor(90 + 70 * pulse))
      end
    end
  end end
end
-- Exposed so Sandbox can run the REAL character rather than a lookalike. He asked for
-- "the same guy that we use from our RPG" -- so sandbox calls these two functions
-- directly instead of reimplementing movement and rendering, which guarantees it stays
-- the same character with the same physics, sprite and feel, forever, by construction.
local drawPlayer
function drawPlayer()
  local P = R.P; local x, y = floor(P.x) - R.cam.x, floor(P.y) - R.cam.y; local f = P.face
  if R.shake and R.frame - R.shake.t < 14 then local m = R.shake.mag * (1 - (R.frame - R.shake.t) / 14); x = x + floor((math.random() - 0.5) * 2 * m); y = y + floor((math.random() - 0.5) * 2 * m)
    graphics.fillRect(0, 0, W, H, 255, 40, 40, floor(40 * (1 - (R.frame - R.shake.t) / 14))) end
  local hurt = R.hurt and (R.frame - R.hurt) < 12
  local skin = {235, 190, 150}; local shirt = hurt and {255, 80, 80} or {70, 130, 225}; local pants = {50, 55, 95}; local hair = {110, 65, 30}
  local boots = R.accOn("boots") and {200, 160, 60} or {40, 40, 50}
  local moving = P.onGround and math.abs(P.vx) > 0.2
  local cyc = moving and floor(((P.anim or 0) / 3) % 4) or 0
  local legA = ({0, 1, 0, -1})[cyc + 1]        -- walk cycle offsets
  local bob = (cyc == 1 or cyc == 3) and 1 or 0
  local by = y - bob
  local function R_(xx, yy, w, h, c, a) graphics.fillRect(xx, yy, w, h, c[1], c[2], c[3], a or 255) end
  -- legs (2px wide each), boots
  if not P.onGround then R_(x - 2, by - 4, 2, 3, pants); R_(x + 1, by - 5, 2, 3, pants); R_(x - 2, by - 1, 2, 1, boots); R_(x + 1, by - 2, 2, 1, boots)
  else R_(x - 2 + legA, by - 4, 2, 3, pants); R_(x + 1 - legA, by - 4, 2, 3, pants); R_(x - 2 + legA, by - 1, 2, 1, boots); R_(x + 1 - legA, by - 1, 2, 1, boots) end
  -- torso and belt
  R_(x - 2, by - 9, 5, 5, shirt); R_(x - 2, by - 5, 5, 1, {40, 35, 30})
  -- back arm / front arm (swing when walking, raise when using a tool)
  local armSw = moving and legA or 0
  local using = R.mouse.l and not R.invOpen
  R_(x + (f > 0 and -3 or 3), by - 9 + (using and -1 or armSw), 1, 4, skin)
  -- head, hair, eyes, mouth
  R_(x - 2, by - 14, 5, 5, skin); R_(x - 2, by - 15, 5, 2, hair); R_(x + (f > 0 and -2 or 2), by - 13, 1, 2, hair)
  R_(x + (f > 0 and 1 or -1), by - 12, 1, 1, {25, 25, 45}); R_(x + (f > 0 and 0 or 0), by - 10, 2, 1, {180, 110, 100})
  if R.accOn("helmet") then R_(x - 3, by - 16, 7, 3, {190, 170, 60}); R_(x + (f > 0 and 2 or -3), by - 15, 2, 1, {255, 255, 200}) end
  if R.accOn("cloud") then R_(x + (f > 0 and -4 or 4), by - 9, 1, 4, {230, 235, 255}, 200) end
  if P.flame and R.frame - P.flame < 3 then R_(x - 2, by, 2, 3, {255, 160, 40}, 220); R_(x + 1, by, 2, 3, {255, 200, 80}, 220) end
  if P.puff and R.frame - P.puff < 8 then graphics.fillCircle(x, by + 1, 5, 2, 240, 240, 255, 160) end
  if P.hook then graphics.drawLine(x, by - 8, P.hook.x - R.cam.x, P.hook.y - R.cam.y, 200, 200, 200, 255) end
  y = by
  local s = (R.hotbar or {})[R.sel or 1]
  if s and s:find("^tool:") then local k = s:sub(6); local col = TOOLCOL[k] or {200,200,200}
    local hx = x + (f > 0 and 4 or -5); local swing = R.mouse.l and ((R.frame % 6) < 3) and -3 or 0
    graphics.fillRect(hx, y - 11 + swing, 1, 5, col[1], col[2], col[3], 255); graphics.fillRect(hx + (f > 0 and 0 or -1), y - 12 + swing, 2, 1, col[1], col[2], col[3], 255) end
end

-- ================================================================ items, tools, crafting
R.HARD = { METL=4, GRSS=1, BCOL=1,  GOO=1, SAND=1, SNOW=1, ICE=1, PLNT=1, WOOD=2, CLST=1, COAL=2, GRNT=3, BSLT=3, BRCK=3, GLAS=2, IRON=4, CU=4, GOLD=4, QRTZ=4, DU=5, URAN=5, STEL=5, TTAN=6, DMND=8,
  -- ADDED 2026-09-02 (@lead). @veins placed six new materials as real worldgen veins and
  -- @matimpl added their names/recipes, but NEITHER added R.MINEABLE/R.HARD entries -- so all
  -- six were in the ground and physically un-diggable. That is the same shape as the GRNT /
  -- NSCN / TUNG / THRM / NITR deadlocks: content that exists but no verb reaches.
  -- Hit counts follow the existing tier convention (tier 2 -> 3 hits, 3 -> 4, 4 -> 5).
  MERC=4, LITH=3, DEUT=4, ISZS=5, PTNM=5, BMTL=3 }
-- Display names for the six new vein materials (2026-09-02 @lead); without these
-- they render as raw four-letter codes in every UI surface.
R.NAMES.PTNM = R.NAMES.PTNM or "Platinum"
R.NAMES.ISZS = R.NAMES.ISZS or "Solid isotope"
R.NAMES.DEUT = R.NAMES.DEUT or "Deuterium"
R.NAMES.MERC = R.NAMES.MERC or "Mercury"
R.NAMES.LITH = R.NAMES.LITH or "Lithium"
R.blockHits = R.blockHits or {}
-- BSLT added 2026-08-31: this is the real, always-solid subsoil/fallback rock
-- worldgen actually places everywhere (see ROCK local ~line 1204; GRNT is a
-- phantom token, never placed by genBase()). Without a R.MINEABLE entry, BSLT
-- was hard-blocked from being mined at all ("cannot be mined", line ~5641),
-- even though it's the single most common solid material in the world.
-- Tier 2 matches GRNT's old tier so the wood pick (power=1) can still mine it
-- slowly per its own flavor text ("granite... only slowly"); the stone pick
-- (power=2) mines it at full speed once crafted.
-- CNCR added 2026-09-02. Measured against real generated terrain: 94.9% of solid cells a
-- player digs through were mineable and concrete was the ONLY solid that was not -- mining
-- it destroyed the block and returned nothing, which reads in game as "my pick spawns air".
-- It was 40% of deep stone before tonight's strata rebalance, so this quietly swallowed a
-- large share of every dig for a long time. Verified live before adding, per ADR-003:
-- id=488, Falldown=0, TYPE_SOLID=true. Tier 2 matches BRCK/BSLT/GRNT (stone pick), and it
-- already crumbles to STNE in the RUBBLE table, so the two paths now agree.
R.MINEABLE = { METL=3, GRSS=1, BCOL=1,  GOO=1, SAND=1, SNOW=1, ICE=1, PLNT=1, WOOD=1, CLST=1, STNE=2, COAL=1, BRCK=2, GLAS=2, BRMT=2, IRON=2, GOLD=3, CU=2, DU=4, URAN=4, STEL=4, GRNT=2, BSLT=2, TTAN=4, DMND=6, LEAD=3, ZIRC=3, STEL=4, QRTZ=3, CNCR=2,
  -- ADDED 2026-09-02 (@lead): the six materials @veins placed as worldgen veins.
  -- Tiers set from the depth each is actually generated at, measured from world.lua:
  --   MERC d>160 (swamp only)  LITH d 200-400   DEUT d>420   ISZS d>440   PTNM deep+rare   BMTL ruins
  -- so they slot alongside the existing depth-equivalent ores (LEAD/ZIRC=3, DU/URAN/TTAN=4).
  MERC=3, LITH=3, DEUT=4, ISZS=4, PTNM=4, BMTL=2,
  -- ADDED 2026-09-02 (@matimpl, design-material-progression.md S4 chain 4): SALT is a real particle
  -- already produced in-world by two existing machines (the Salt Evaporator's pan, and the Desalinator's
  -- byproduct stream) but had no R.MINEABLE entry, so a player standing next to a pan full of real SALT
  -- crystals could not pick any of it up -- the exact same "produced but uncollectable" shape as the BSLT
  -- gap noted above. Tier 1 matches the other loose dusts (SAND/CLST/GRSS); this is also what makes the
  -- new TNT recipe below (GUN+SALT) actually reachable rather than a second silent deadlock.
  SALT=1 }
R.TOOLS = R.TOOLS or {
  pick  = { name="wood pick", power=1, reach=24, speed=8, radius=3 },
  axe   = { name="axe", power=1, reach=26, speed=6, radius=4, only={WOOD=1, PLNT=1, GRSS=1} },
  sword = { name="wood sword", reach=34, dmg=15, speed=12 },
  torch = { name="torch", reach=56 },
  bucket= { name="bucket", reach=56 },
}
-- Diamond pick need reduced DMND 4->3, 2026-09-02 (@deadlock, GAME-FLOW.md S10 finding #3):
-- DMND has R.MINEABLE tier 6, but the best pick that does NOT itself require DMND (steel,
-- power 4) only mines up to tier power+1=5 -- DMND cannot be mined until you already have
-- this exact pick. The only deterministic DMND sources are two one-time quest rewards
-- ("titanium":1, "steel":2, both above) totalling exactly 3, one short of the old need of 4:
-- a quantity-sufficiency deadlock on the game's top tool tier, same shape as the historic
-- GRNT bug (one-time supply < recipe demand), previously masked only by the PROBABILISTIC
-- `dpick` chest-loot accessory (tier-3, depth>600) granting the same power for free. Reducing
-- the need to 3 makes the crafted recipe itself deterministically reachable from guaranteed
-- quest rewards alone, with zero DMND mining required -- matching, not replacing, the
-- accessory route (both now independently sufficient instead of one being a silent bugfix
-- for the other). Left R.MINEABLE.DMND=6 untouched: only the recipe's own demand changed.
R.PICKS = { {name="wood pick", power=1, reach=24, speed=8, need={WOOD=6}, st="hand", desc="Digs dirt, sand and coal; granite and iron only slowly"}, {name="stone pick", power=2, reach=26, speed=7, need={[ROCK]=6, WOOD=4}, st="workbench", desc="Digs granite, coal and iron at full speed"}, {name="iron pick", power=3, reach=30, speed=6, need={METL=5, WOOD=4}, st="anvil", desc="Digs gold and quartz too; faster"}, {name="steel pick", power=4, reach=34, speed=5, need={STEL=5, WOOD=4}, st="anvil", desc="Digs uranium ore and deep titanium"}, {name="diamond pick", power=6, reach=40, speed=4, need={DMND=3, STEL=4}, st="anvil", desc="Digs everything, including bedrock"} }
R.SWORDS = { {name="wood sword", dmg=15, need={WOOD=8}, st="workbench", desc="Better than fists"}, {name="iron sword", dmg=35, need={METL=5, WOOD=2}, st="anvil", desc="Solid damage"}, {name="steel sword", dmg=60, need={STEL=5, WOOD=2}, st="anvil", desc="Cleaves most enemies in two hits"} }
R.ACCS = {
  cloud   = { name="Cloud in a Bottle", desc="double jump: press jump again in the air", tier=1 },
  boots   = { name="Hermes Boots", desc="run 50% faster", tier=1 },
  mirror  = { name="Magic Mirror", desc="press X to teleport back to the surface spawn", tier=1 },
  hook    = { name="Grappling Hook", desc="press G to pull yourself to the block you aim at", tier=2 },
  helmet  = { name="Miner Helmet", desc="lights up the underground", tier=2 },
  lava    = { name="Lava Charm", desc="immune to lava and fire", tier=3 },
  rocket  = { name="Rocket Boots", desc="hold jump in the air to fly (refuels on the ground)", tier=3 },
  dpick   = { name="Diamond Pick", desc="mines everything, long reach", tier=3 },
}
R.ACC_ORDER = { "cloud", "boots", "mirror", "hook", "helmet", "lava", "rocket", "dpick" }
R.acc = R.acc or {}            -- equipped (effects active)
R.accOwned = R.accOwned or {}  -- owned (in the bag); UI equips/unequips by toggling R.acc[k]
for k in pairs(R.acc) do R.accOwned[k] = true end
-- ONE model: R.acc[k] = owned (never removed), R.accOff[k] = switched off, R.accOn(k) = effect live. R.accOwned mirrors R.acc for plugins.
R.accOff = R.accOff or {}
function R.equipAcc(k, on) if not R.acc[k] then return false end; R.accOff[k] = (not on) and true or nil; R.accOwned[k] = true; say((on and "Equipped " or "Unequipped ") .. R.ACCS[k].name); return true end
R.accOff = R.accOff or {}                                    -- accessories the player has switched OFF
function R.accOn(k) return R.acc[k] and not R.accOff[k] end  -- owned AND not disabled -> the effect is live
R.chests = R.chests or {}
function R.chestAt(tx, ty)
  local key = tx * 100000 + ty + 50000; local c = R.chests[key]; if c ~= nil then return c end
  c = false
  if ty * CC > 40 and hash3(tx, ty, 41) < 0.45 then
    local x0 = tx * CC + 8 + floor(hash3(tx, ty, 42) * (CC - 16))
    for y = ty * CC + 4, ty * CC + CC - 6, 2 do
      if y > surfaceAt(x0) + 12 and gen(x0, y) == nil and gen(x0 + 3, y) == nil and gen(x0, y + 1) ~= nil and gen(x0 + 3, y + 1) ~= nil and gen(x0, y - 4) == nil then
        local d = y - surfaceAt(x0); local tier = d > 600 and 3 or (d > 200 and 2 or 1)
        local pool = {}; for _, k in ipairs(R.ACC_ORDER) do if R.ACCS[k].tier <= tier and (R.ACCS[k].tier == tier or hash3(tx, ty, 44) < 0.3) then pool[#pool+1] = k end end
        c = { x = x0, y = y, item = pool[1 + floor(hash3(tx, ty, 43) * #pool)], opened = false }; break end end end
  R.chests[key] = c; return c
end
-- Same forward-reference bug class as the title-screen crash: `give` (local function,
-- defined much later in this file) is called here before that declaration exists in
-- source order, so this compiled as a call to a nonexistent global -- a real, reachable
-- crash on picking up a DUPLICATE accessory (two chests, or two boss kills with the
-- same drop). Using R.give (the plugin-facing public wrapper, already defined earlier
-- and used elsewhere in this file) instead of the bare local -- avoids needing yet
-- another forward declaration for the same class of bug.
function R.giveAcc(k) local a = R.ACCS[k]; if not a then return end
  if R.accOwned[k] then R.give("GOLD", 5); say("Duplicate " .. a.name .. " - took 5 Gold instead"); return end
  R.accOwned[k] = true; R.acc[k] = true; say("Found " .. a.name .. "!  " .. a.desc)
  if k == "dpick" then R.TOOLS.pick = {name="diamond pick", power=6, reach=40, speed=4, radius=4} end
end
-- sandbox: test everything. All materials/kits/weapons/machines stocked and topped up, all accessories, no damage, free crafting.
-- Take an item straight from the guide/database into the hotbar (sandbox: unlimited; otherwise only what you own)
function R.grantItem(el)
  if not el then return false end
  if R.sandbox then R.inventory[el] = math.max(R.inventory[el] or 0, 999) end
  if (R.inventory[el] or 0) <= 0 then say(R.nice(el) .. ": you have none (turn on Sandbox mode to take any material)"); return false end
  local slot
  for s2 = 6, 10 do if R.hotbar[s2] == el then slot = s2 break end end
  if not slot then for s2 = 6, 10 do if not R.hotbar[s2] then slot = s2 break end end end
  slot = slot or ((R.sel and R.sel >= 6) and R.sel or 6)
  R.hotbar[slot] = el; R.sel = slot
  say(R.nice(el) .. " -> slot " .. (slot % 10))
  return true
end
-- Capability half of sandbox: everything unlocked, nothing handed to you.
function R.sandboxUnlock()
  for _, k in ipairs(R.ACC_ORDER) do R.acc[k] = true; R.accOwned[k] = true end
  R.TOOLS.pick = {name="diamond pick", power=6, reach=40, speed=4, radius=4}
  R.TOOLS.sword = {name="steel sword", reach=34, dmg=60, speed=12}
  R.rebuildHotbar(); R.runHooks(R.hooks.sandbox)
end
-- Unlock AND stock every material. Kept for anyone who explicitly wants a full bag; it is
-- no longer what entering sandbox does.
function R.sandboxFill()
  local names = {}
  for k in pairs(R.NAMES) do names[#names+1] = k end
  for k in pairs(R.ITEMS) do names[#names+1] = k end
  for _, rc in ipairs(R.RECIPES) do names[#names+1] = rc.out; for el in pairs(rc.need) do names[#names+1] = el end end
  -- 2026-08-30: dropped LAVA from the exclusion list. User reported 'molten materials turn to stone' which
  -- turned out to be 'LAVA silently no-ops in placeAt because inv_LAVA is 0 by default -- the empty
  -- nothing-gets-placed case looks indistinguishable from a lava->stone conversion'. With LAVA in the
  -- starting inventory the user can now actually place it and observe it stays LAVA (element default
  -- temp = 1795K, so it self-heats on spawn and stays LAVA until it loses heat to surroundings).
  for _, k in ipairs(names) do if k ~= "FIRE" and k ~= "GLOW" then R.inventory[k] = math.max(R.inventory[k] or 0, 999) end end
  for _, k in ipairs(R.ACC_ORDER) do R.acc[k] = true; R.accOwned[k] = true end
  R.TOOLS.pick = {name="diamond pick", power=6, reach=40, speed=4, radius=4}; R.TOOLS.sword = {name="steel sword", reach=34, dmg=60, speed=12}
  R.rebuildHotbar(); R.runHooks(R.hooks.sandbox)
end
R.QUESTS = {
  { id="wood", txt="Chop 10 wood with the axe (slot 2)", done=function() return (R.stats.mined.WOOD or 0) >= 10 end, reward={WOOD=10} },
  { id="woodpick", txt="Craft a wood pick by hand (E > craft) - 6 Wood", done=function() return R.stats.crafted["wood pick"] end, reward={WOOD=4} },
  { id="bench", txt="Craft a Workbench (E) and place it", done=function() return #R.stations > 0 end, reward={[ROCK]=6} },
  { id="pick", txt="Dig 6 Granite with the wood pick (slow) and craft a stone pick at the workbench", done=function() return R.stats.crafted["stone pick"] or R.TOOLS.pick.power >= 2 and (R.stats.crafted["stone pick"] or false) end, reward={COAL=3} },
  { id="coal", txt="Mine 10 Coal (black seams underground)", done=function() return (R.stats.mined.COAL or 0) >= 10 end, reward={[ROCK]=10} },
  { id="furnace", txt="Craft a Furnace kit, place it and light it with the torch", done=function() for _, st in ipairs(R.stations) do if st.kind == "furnace" and R.nearStation("furnace") then return true end end; return false end, reward={IRON=6} },
  { id="iron", txt="Smelt 5 Iron bars at the lit furnace (2 Iron ore each)", done=function() return (R.stats.crafted.METL or 0) >= 5 end, reward={WOOD=6} },
  { id="anvil", txt="Craft and place an Anvil", done=function() for _, st in ipairs(R.stations) do if st.kind == "anvil" then return true end end; return false end, reward={METL=3} },
  { id="ironpick", txt="Forge an iron pick at the anvil", done=function() return R.stats.crafted["iron pick"] end, reward={GOLD=2} },
  { id="chest", txt="Find and open a chest in the caves", done=function() return R.stats.chests > 0 end, reward={METL=4} },
  { id="deep", txt="Dig down to 50 m underground", done=function() return R.stats.maxDepth >= 50 end, reward={STEL=4} },
  { id="wifi", txt="Craft a Wireless link at the workbench (needs Copper + Gold)", done=function() return R.stats.crafted.WIFI end, reward={CU=4} },
  { id="biometrip", txt="Travel: bring back Quartz from the snow caves, Oil/Gas from the swamp, or 8 Brick from a desert ruin",
    done=function() return (R.inventory.QRTZ or 0) >= 4 or (R.inventory.GAS or 0) + (R.inventory.OIL or 0) >= 4 or (R.inventory.BRCK or 0) >= 8 end, reward={STEL=3} },
  { id="titanium", txt="Reach the deep zone and mine Titanium", done=function() return (R.stats.mined.TTAN or 0) >= 1 end, reward={DMND=1} },
  { id="steel", txt="Smelt steel and forge a steel pick", done=function() return R.stats.crafted["steel pick"] end, reward={DMND=2} },
  -- Nothing pointed players at the Research Bench/Advanced Lab tiers shipped this
  -- session (round 1/4) -- the quest chain just stopped at "steel". Added so the
  -- new content is actually discoverable, not just theoretically craftable.
  { id="research", txt="Build a Research Bench (needs Steel, Glass, Copper)", done=function() return (R.stats.crafted.RESEARCH or 0) >= 1 end, reward={ZIRC=1} },
  { id="advlab", txt="Build an Advanced Lab and craft a Graphite block", done=function() return (R.stats.crafted.GRPH or 0) >= 1 end, reward={TTAN=2} },
}
R.quest = R.quest or 1
local function updateQuests()
  local q = R.QUESTS[R.quest]; if not q then return end
  if q.done() then for el, n in pairs(q.reward or {}) do R.inventory[el] = (R.inventory[el] or 0) + n end
    local rw = {}; for el, n in pairs(q.reward or {}) do rw[#rw+1] = n .. " " .. nice(el) end
    say("GOAL DONE: " .. q.txt .. "   reward: " .. table.concat(rw, ", ")); R.quest = R.quest + 1; R.rebuildHotbar()
    if R.QUESTS[R.quest] then say("New goal: " .. R.QUESTS[R.quest].txt) else say("All starter goals done - you are on your own now!") end end
end
R.RECIPES = {
  { out="FLASK", n=1, need={GRSS=6, WOOD=3}, st="hand", txt="Air bladder", desc="A sealed plant bladder. Fills in fresh air; releases it automatically when you are running out" },
  -- Concrete is MADE, not mined. Added 2026-09-02 after PhoenixFire808 pointed out that
  -- concrete had no business being a natural rock layer: "that seems like something that we
  -- make, or something that would be found around natural monuments." It has been removed
  -- from natural strata entirely; its only worldgen source is now ruin walls (~35% of ruins),
  -- and this is the manufactured route. Real concrete is aggregate plus sand plus a binder,
  -- which is exactly what these inputs are -- crushed stone for aggregate, sand for the fine
  -- fraction. Yields 4 from 6 inputs, so building with it is worth the trip.
  { out="CNCR", n=4, need={STNE=4, SAND=2}, st="workbench", txt="Concrete", desc="Crushed stone and sand bound into a hard artificial block. Not found in natural rock -- you either make it, or salvage it from ruins" },
  -- Brick is FIRED CLAY, so it is made at the furnace from the clay you dig, not found in
  -- the ground. Removed from natural strata the same day for the same reason as concrete:
  -- it had been generating as 8% of every non-desert stone pixel, justified in a comment as
  -- "thin sedimentary banding", which is not something bricks do. Its only other source is
  -- ruin walls, which is exactly where fired brick belongs. CLST is already mineable at
  -- tier 1, so this is reachable with the very first pick.
  { out="BRCK", n=4, need={CLST=4}, st="furnace", txt="Brick", desc="Clay fired hard in a furnace. A made material -- you will not find bricks in bedrock, only in the ruins of something somebody built" },
  -- by hand
  { out="WORKBENCH", n=1, need={WOOD=10}, st="hand", txt="Workbench", desc="Place it and stand near it: unlocks tools, kits and building blocks" },
  { out="FURNACE", n=1, need={[ROCK]=20, COAL=5}, st="workbench", txt="Furnace kit", desc="Granite box with a coal bed. Place, then light with the torch (slot 4). Smelts ore while burning" },
  { out="ANVIL", n=1, need={METL=8}, st="workbench", txt="Anvil", desc="Forge iron and steel tools here" },
  { out="RESEARCH", n=1, need={STEL=6, GLAS=4, CU=2}, st="workbench", txt="Research Bench", desc="A progression tier past the workbench -- unlocks advanced material recipes" },
  -- research bench (a tier past the workbench -- needs steel/glass/copper the workbench itself can't make, so it's a real gate, not just another crafting spot)
  { out="ZIRC", n=1, need={TTAN=1, STEL=1}, st="research", txt="Zirconium alloy", desc="Advanced reactor cladding. Needs a Research Bench" },
  { out="ADVLAB", n=1, need={ZIRC=4, B4C=2, GLAS=6}, st="research", txt="Advanced Lab", desc="A tier past the Research Bench -- needs Zirconium alloy itself, so it's a real gate on top of a gate" },
  { out="GRPH", n=2, need={COAL=6, B4C=1}, st="advlab", txt="Graphite block", desc="Reactor-grade moderator. Needs an Advanced Lab" },
  -- furnace (must be lit)
  { out="METL", n=1, need={IRON=2}, st="furnace", txt="Iron bar", desc="Smelt 2 iron ore into a bar (METL). Bars make the anvil, picks and swords" },
  { out="STEL", n=1, need={METL=2, COAL=1}, st="furnace", txt="Steel", desc="Iron bars + coal = steel: hardest tool material short of diamond" },
  { out="BRCK", n=4, need={GOO=4}, st="furnace", txt="Fired brick", desc="Kiln-fired dirt. A solid, heat-proof building block" },
  { out="GLAS", n=2, need={SAND=4}, st="furnace", txt="Glass", desc="Melted sand. Lets light through; shatters under pressure" },
  -- REMOVED 2026-09-02 (@deadlock, GAME-FLOW.md S10 finding #4): this used to be
  -- `{ out="GOLD", n=1, need={GOLD=1, COAL=1}, st="furnace", txt="Refined gold", desc="Purify gold ore (used in circuits)" }`
  -- -- a self-referential no-op. Mined gold ore and every other use of "refined
  -- gold" already share one inventory code (R.NAMES.GOLD="Gold"), so this recipe
  -- consumed 1 GOLD + 1 COAL to produce exactly 1 GOLD back: a pure, silent COAL
  -- sink with zero material gain, and the self-loop the reachability script's own
  -- cycle-detector flagged automatically. Deleted rather than reworked into a real
  -- two-tier ore/refined-good split: every other GOLD consumer in the game (CU,
  -- LIGHTGUN/TPWAND/GRAVWELL ammo, WIFI, C-4, the ironpick quest reward) already
  -- expects the single shared code, so splitting it would be a real economy change
  -- across many files, not a targeted fix for a dead recipe.
  { out="CU", n=2, need={GOLD=1, METL=1}, st="furnace", txt="Copper", desc="Conductive copper for wiring" },
  -- workbench
  { out="INSL", n=4, need={SAND=2, WOOD=2}, st="workbench", txt="Insulation", desc="Blocks heat and electricity. Line a base with it" },
  { out="TTAN", n=1, need={STEL=2, [UORE]=1}, st="anvil", txt="Titanium plate", desc="Very hard, heat-resistant plate" },
  -- electrics (workbench, needs furnace materials)
  { out="PSCN", n=2, need={CU=1, GLAS=1}, st="workbench", txt="P-silicon", desc="Semiconductor: passes sparks one way. Basis of circuits" },
  -- ADDED 2026-09-02 (@deadlock, GAME-FLOW.md S10 finding #1): NSCN ("N-silicon")
  -- is a real stock TPT element (src/simulation/elements/NSCN.cpp, TYPE_SOLID,
  -- Falldown=0 -- verified safe per DEVELOPMENT.md rule 4) but had zero sources anywhere
  -- in this fork: not mined, not crafted, not looted -- only ever drawn as decorative
  -- build-geometry pixels inside two machines' own construction code, never given to
  -- the player. That permanently blocked MAGACCELKIT (needs 4xNSCN, machines2.lua).
  -- Doped the other direction from PSCN right above it (GOLD instead of CU as the
  -- dopant stand-in, matching the existing GOLD/CU "circuits" material pairing used
  -- by WIFI/LIGHTGUN/TESLAARC elsewhere) rather than adding new worldgen placement --
  -- same station/tier/output-count as PSCN so the two feel like a matched pair.
  { out="NSCN", n=2, need={GOLD=1, GLAS=1}, st="workbench", txt="N-silicon", desc="Semiconductor: passes sparks the other way; disables powered materials it touches. Basis of circuits" },
  { out="LEDL", n=2, need={GLAS=1, CU=1}, st="workbench", txt="LED lamp", desc="Lights up when sparked" },
  { out="WIFI", n=1, need={CU=2, GOLD=1}, st="workbench", txt="Wireless link", desc="Carries sparks between two WIFI blocks on the same channel" },
  { out="B4C", n=1, need={COAL=4, METL=1}, st="anvil", txt="Control rod", desc="Boron carbide: absorbs neutrons in a reactor" },
  { out="TRBN", n=1, need={STEL=6, CU=2}, st="anvil", txt="Turbine stage", desc="Turns steam/pressure into electricity" },
  { out="TEG", n=1, need={CU=3, GLAS=2}, st="workbench", txt="Thermoelectric", desc="Makes power from a temperature difference" },
  { out="UO2", n=1, need={[UORE]=4, COAL=1}, st="furnace", txt="Fuel pellet", desc="Uranium dioxide reactor fuel. Handle with lead" },
  -- ADDED 2026-09-02 (@matimpl, knowledge/design-material-progression.md): stock-element progression
  -- chains from the design doc's S4 -- craft/react routes only, every input already independently
  -- reachable (no new worldgen veins needed, world.lua is not this lane's file this wave). Grouped by
  -- the doc's own chain numbers; guide.lua buckets these into its existing per-station tabs automatically.
  -- chain 1: Electronics & Circuits (T1-T3)
  { out="SLCN", n=3, need={SAND=4}, st="furnace", txt="Silicon powder", desc="Sand heated past its melting point in a lit furnace -- refined silicon, the base of every semiconductor" },
  { out="SWCH", n=1, need={METL=2, PSCN=1}, st="workbench", txt="Switch", desc="On/off conductor -- gate one branch of your grid without cutting the whole line" },
  { out="INWR", n=2, need={PSCN=2, INSL=1}, st="workbench", txt="Insulated wire", desc="P-silicon core wrapped in insulation -- carries a spark without shorting on contact" },
  { out="TESC", n=1, need={CU=4, GOLD=2, QRTZ=2}, st="research", txt="Tesla coil", desc="Throws real lightning when sparked -- upgrade path for the Tesla Arc and automated defenses" },
  { out="ETRD", n=1, need={CU=3, SLCN=2}, st="research", txt="Electrode", desc="Silicon-cored electrode -- strikes a real plasma arc across a gap when sparked" },
  { out="DSTW", n=2, need={WATR=4}, st="advlab", txt="Distilled water", desc="Boiled and recondensed -- non-conductive, won't corrode wiring the way saltwater does. Makes ocean/swamp bases viable" },
  -- chain 4: Demolition & Blasting (T2) -- THRM/NITR fixed in items.lua; the rest of the chain lives here
  { out="GUN", n=3, need={CLST=4}, st="furnace", txt="Gunpowder (raw)", desc="Clay dust roasted in a lit furnace -- light, flammable powder. Mix with Salt for TNT" },
  { out="TNT", n=1, need={GUN=6, SALT=2}, st="workbench", txt="TNT", desc="Packed gunpowder and salt -- explodes all at once, a real blast-mining charge" },
  { out="FUSE", n=4, need={COAL=2, WOOD=2}, st="workbench", txt="Fuse", desc="Burns slowly, ignites at high heat or spark -- lay a controlled-delay line to a charge" },
  { out="IGNC", n=3, need={FUSE=2, COAL=2}, st="workbench", txt="Ignition cord", desc="A slower-burning fuse cord -- lights reliably from fire or spark" },
  { out="FSEP", n=6, need={FUSE=3}, st="workbench", txt="Fuse powder", desc="Bulk fuse powder for laying a long detonation line fast" },
  { out="TRON", n=1, need={QRTZ=3, TESC=1}, st="research", txt="Tron", desc="Smart particles that steer around obstacles -- seeking-ammo upgrade for kinetic weapons" },
  -- chain 5: Force-Field Automation (T3)
  { out="PSTN", n=1, need={METL=4, PSCN=1, NSCN=1}, st="research", txt="Piston", desc="PSCN extends it, NSCN retracts it -- a real mechanical piston, pushes many particles at once" },
  { out="FRME", n=1, need={METL=6}, st="research", txt="Frame", desc="Used together with pistons to push a solid mass of particles" },
  { out="ACEL", n=1, need={CU=2, QRTZ=2}, st="research", txt="Accelerator", desc="Speeds up nearby elements passing through it -- a contactless conveyor upgrade" },
  { out="DCEL", n=1, need={CU=2, QRTZ=2}, st="research", txt="Decelerator", desc="Slows nearby elements passing through it -- a contactless conveyor upgrade" },
  { out="FRAY", n=1, need={CU=3, QRTZ=2}, st="research", txt="Force emitter", desc="Temperature-tuned push/pull field -- shove hazardous material without touching it" },
  { out="RPEL", n=1, need={CU=3, QRTZ=2}, st="research", txt="Repeller", desc="Repels or attracts by temperature -- pairs with the Force emitter for contactless material handling" },
  { out="PPIP", n=2, need={METL=2, PSCN=1}, st="workbench", txt="Powered pipe", desc="A pipe that only moves particles while PSCN/NSCN-activated -- a switchable logistics line" },
  -- chain 6: Shield Defense Ladder (T3-T5) -- SHD4 (reactor-online only) lives in machines.lua's TIERR_RECIPES
  { out="SHLD", n=2, need={STEL=4, PSCN=2}, st="research", txt="Shield tier 1", desc="Grows a real barrier around a spark, breaks under pressure -- base defense's first tier" },
  { out="SHD2", n=1, need={SHLD=4, QRTZ=2, CU=2}, st="research", txt="Shield tier 2", desc="A tougher shield field -- absorbs more before breaking" },
  { out="SHD3", n=1, need={SHD2=3, ZIRC=2, GLAS=2}, st="advlab", txt="Shield tier 3", desc="Reactor-cladding-grade shielding -- absorbs heavy damage before it breaks" },
  -- chain 9: Sensor/Automation Safety Tier (T3-T4)
  { out="DTEC", n=1, need={METL=3, QRTZ=2}, st="research", txt="Detector", desc="Sparks when a matching material is nearby -- wire it into an early-warning alarm" },
  { out="LDTC", n=1, need={METL=3, QRTZ=2}, st="research", txt="Linear detector", desc="Scans all 8 directions for a matching material -- wider coverage than the Detector" },
  { out="PSNS", n=1, need={METL=2, CU=1}, st="research", txt="Pressure sensor", desc="Sparks when pressure crosses a threshold -- wire a pressure vessel's shutoff to it" },
  { out="TSNS", n=1, need={METL=2, CU=1}, st="research", txt="Temperature sensor", desc="Sparks when temperature crosses a threshold -- wire a reactor's shutoff to it" },
  { out="SPNG", n=4, need={CLST=4}, st="workbench", txt="Sponge", desc="Dried clay that soaks up water -- a cheap flood-control stopgap before you can afford a Sump" },
  { out="VOID", n=1, need={METL=6}, st="research", txt="Void", desc="Drains away anything that enters it -- a waste-disposal sink" },
  { out="PVOD", n=1, need={METL=4, VOID=1}, st="research", txt="Powered void", desc="A void that only drains while PSCN/NSCN-activated -- the core of a trash incinerator" },
  { out="VENT", n=3, need={METL=3}, st="workbench", txt="Vent", desc="Creates pressure and pushes particles -- pairs with an air line for ventilation" },
}
R.STATIONS = { hand = "by hand", workbench = "Workbench", furnace = "lit Furnace", anvil = "Anvil", research = "Research Bench", advlab = "Advanced Lab" }
R.stations = R.stations or {}   -- placed stations: {kind, x, y (world)}
function R.nearStation(kind)
  if kind == "hand" or R.sandbox then return true end
  for _, st in ipairs(R.stations) do if st.kind == kind and math.abs(st.x - R.P.x) < 48 and math.abs(st.y - R.P.y) < 40 then
    if kind ~= "furnace" then return true end
    -- furnace is "lit" when something hot (fire/burning coal) sits inside its box
    for yy = st.y - 10, st.y - 2 do for xx = st.x + 2, st.x + 11 do local p = sim.partID(xx - R.cam.x, yy - R.cam.y)
      if p then local nm = nameOf(sim.partProperty(p, "type")); if nm == "FIRE" or nm == "PLSM" or (sim.partProperty(p, "temp") or 0) > 600 then return true end end end end
    return false, "furnace is not lit - use the torch on its coal" end end
  return false, "need a " .. (R.STATIONS[kind] or kind) .. " nearby"
end
local function inv(el) return (R.inventory or {})[el] or 0 end
R.stats = R.stats or { mined = {}, crafted = {}, chests = 0, maxDepth = 0 }
local function give(el, n) R.inventory[el] = inv(el) + n; if n > 0 then R.stats.mined[el] = (R.stats.mined[el] or 0) + n; runHooks(R.hooks.mine, el, n) end end
R.inv, R.give = inv, give
R.movePlayer, R.drawPlayer = movePlayer, drawPlayer
local TOOLSLOTS = { "tool:pick", "tool:axe", "tool:sword", "tool:torch", "tool:bucket" }
function R.rebuildHotbarNow()
  R.hotbar = R.hotbar or {}
  for s = 1, 5 do R.hotbar[s] = TOOLSLOTS[s] end
  local seen = {}; for s = 6, 10 do local v = R.hotbar[s]; if v and not v:find("^tool:") then seen[v] = true else R.hotbar[s] = nil end end
  local names = {}; for k, v in pairs(R.inventory or {}) do if v > 0 and not seen[k] then names[#names+1] = k end end; table.sort(names)
  for s = 6, 10 do if not R.hotbar[s] then R.hotbar[s] = table.remove(names, 1) end end
  R.sel = R.sel or 1
end
function R.rebuildHotbar() R._hotbarDirty = true end
local function selected() return (R.hotbar or {})[R.sel or 1] end
local function canAfford(need) if R.sandbox then return true end; for el, n in pairs(need) do if inv(el) < n then return false end end; return true end
local function spend(need) if R.sandbox then return end; for el, n in pairs(need) do R.inventory[el] = inv(el) - n end end
function R.craft(idx) local rc = R.RECIPES[idx]; if not rc then return end
  if not R.ITEMS[rc.out] and not has(rc.out) then say(rc.out .. " is not defined in this session"); return end
  local okst, why = R.nearStation(rc.st or "hand"); if not okst then say(why); return end
  if not canAfford(rc.need) then say("Not enough materials for " .. rc.txt); return end
  spend(rc.need); give(rc.out, rc.n); R.rebuildHotbar(); R.stats.crafted[rc.out] = (R.stats.crafted[rc.out] or 0) + rc.n; say("Crafted " .. rc.n .. " " .. rc.txt); runHooks(R.hooks.craft, rc) end
function R.craftPick(idx) local t = R.PICKS[idx]; if not t or not canAfford(t.need) then say("Not enough materials"); return end
  local okst, why = R.nearStation(t.st or "hand"); if not okst then say(why); return end; R.stats.crafted[t.name] = 1
  spend(t.need); R.TOOLS.pick = {name=t.name, power=t.power, reach=t.reach, speed=t.speed, radius=3 + floor((idx-1)/2)}; say("Made a " .. t.name .. " (slot 1)") end
function R.craftSword(idx) local t = R.SWORDS[idx]; if not t or not canAfford(t.need) then say("Not enough materials"); return end
  local okst, why = R.nearStation(t.st or "hand"); if not okst then say(why); return end; R.stats.crafted[t.name] = 1
  spend(t.need); R.TOOLS.sword = {name=t.name, reach=34, dmg=t.dmg, speed=12}; say("Forged a " .. t.name .. " (slot 3)") end

-- ================================================================ actions (mouse is in canvas coords)
local function dist2(ax, ay, bx, by) return (ax-bx)^2 + (ay-by)^2 end
local function pcanvas() return R.P.x - R.cam.x, R.P.y - 5 - R.cam.y end
-- Sandbox/TPT-menu mode decouples building from the character entirely --
-- place and dig anywhere on screen, not just within arm's reach of R.P.
local function inReach(mx, my, reach) if R.tptMenus then return true end; local px, py = pcanvas(); return dist2(mx, my, px, py) <= reach*reach end
-- BRITTLE TERRAIN: fragments left by acid, lasers, explosions or a pick are structurally unsound.
-- Any small isolated clump of solid terrain crumbles into real falling rubble (rock->stone, dirt->clay, ice->snow),
-- which then obeys TPT gravity: it drops, piles up and can be picked up. Keeps cut holes clean instead of leaving specks.
local RUBBLE = { GRNT="STNE", BRCK="STNE", STEL="STNE", TTAN="STNE", METL="STNE", IRON="STNE", GOLD="STNE", CU="STNE",
                 QRTZ="STNE", DMND="STNE", DU="STNE", URAN="STNE", GOO="CLST", ICE="SNOW", GLAS="STNE", CNCR="STNE" }
-- WOOD/GRSS never fall on their own (both are Falldown=0 solids -- reassigning their
-- type like RUBBLE does would just leave them floating in a new skin), so an orphaned
-- chip of trunk or canopy left behind by a chop that broke the tree's flood-fill
-- connectivity (see R.fellFrom) has to be swept away outright instead of converted.
local WOODY = { WOOD = true, GRSS = true }
-- only genuinely tiny floating fragments (5 cells or fewer) are unsupported (inlined below)
-- MAX_CLUMP makes sense for RUBBLE (a small floating rock chip vs a big cliff that's
-- clearly still structurally sound) but not for WOODY -- a chopped tree's whole
-- leftover canopy is easily 100+ cells and has zero self-support at ANY size, so
-- capping it at 5 meant crumble refused to touch a real leftover canopy at all
-- (confirmed the actual cause of "chopped the tree but the canopy's still there"
-- alongside the fellFrom connectivity gap above). Pure-woody clumps use a much
-- higher practical cap instead of none, just to bound one scan's worst case.
-- woody clumps up to 4000 cells are a standing tree, not debris (inlined below)
local function crumbleOk(nm) return nm and (RUBBLE[nm] or WOODY[nm]) end
-- Standing trees are < MAX_WOODY_CLUMP cells, so the old crumble path treated an
-- entire rooted oak as "unsupported debris" whenever crumble ran nearby (dig
-- ventilation, actorMine, axe chips) and partKill'd the whole trunk/canopy --
-- reads as sawdust/DUST in the sim. Only crumble woody clumps that no longer have
-- a WOOD column reaching the surface (orphaned canopy after a trunk cut).
-- FIXED 2026-08-30 (@systems). Confirmed live failure: R.crumble fired directly at a living,
-- surface-supported trunk destroyed 397 WOOD against a limit of 25, because this predicate
-- answered "no support" for a perfectly rooted tree. Two independent reasons, both from the
-- old rule "there must be an unbroken column of pure WOOD from this cell down to the surface
-- row":
--   1. A trunk RESTS ON topsoil -- its lowest WOOD cell sits on GOO/rock. Descending from a
--      trunk cell therefore hits a non-WOOD particle and the old code treated that as failure
--      (`break`), even though hitting solid ground is the strongest possible proof of support.
--   2. GRSS is woody per the WOODY table and real grass/leaf cells occur in and around the
--      trunk base, so the strict `type ~= wood` test aborted the descent mid-trunk.
-- The physically correct question is "is this woody mass resting on something solid", not "is
-- it made of an unbroken wood column". So: walk DOWN through the clump's own woody material,
-- and if we reach any non-woody particle we are resting on it -> supported. Only genuinely
-- open air below (`not p`) still means unsupported, which is exactly the orphaned-canopy case
-- this guard exists to allow crumbling, so that feature is preserved.
-- Bias is deliberately conservative (anything solid-ish below counts, including liquids): the
-- failure being fixed is over-destruction of the owner's real trees, so a false "supported" merely
-- leaves debris standing, while a false "unsupported" deletes a living tree.
local function woodyHasTrunkSupport(cells)
  local wood = eid("WOOD"); if not wood then return false end
  for _, c in ipairs(cells) do
    local x, y = c[1], c[2]
    for dx = -2, 2 do
      local col = x + dx
      for sy = y, H - M - 1 do
        local p = sim.partID(col, sy)
        if not p then break end                                   -- open air below: this column holds nothing up
        if not WOODY[nameOf(sim.partProperty(p, "type"))] then return true end  -- resting on real ground
        local wy = sy + R.cam.y
        if wy >= surfaceAt(col + R.cam.x) - 1 then return true end
      end
    end
  end
  return false
end
function R.crumble(cx, cy, rad)
  local x0, y0 = math.max(M, cx - rad), math.max(M, cy - rad)
  local x1, y1 = math.min(W - M - 1, cx + rad), math.min(H - M - 1, cy + rad)
  local seen, broke = {}, 0
  for y = y0, y1 do for x = x0, x1 do
    local key = x * 4096 + y
    if not seen[key] then
      local p = sim.partID(x, y)
      local nm = p and nameOf(sim.partProperty(p, "type"))
      if crumbleOk(nm) then
        -- flood fill this clump, giving up as soon as it is clearly big enough to hold itself together
        local stack, cells, big, allWoody = { { x, y } }, {}, false, true
        while #stack > 0 do
          local c = table.remove(stack); local ax, ay = c[1], c[2]; local k = ax * 4096 + ay
          -- follow the whole connected mass across the entire canvas: clipping the fill to the scan box
          -- made big formations look like specks and crumbled solid ground
          if not seen[k] and ax >= M and ax < W - M and ay >= M and ay < H - M then
            local q = sim.partID(ax, ay)
            if q and crumbleOk(nameOf(sim.partProperty(q, "type"))) then
              seen[k] = true; cells[#cells + 1] = { ax, ay, q }
              if not WOODY[nameOf(sim.partProperty(q, "type"))] then allWoody = false end
              if #cells > (allWoody and 4000 or 5) then big = true; break end
              for dy = -1, 1 do for dx = -1, 1 do stack[#stack + 1] = { ax + dx, ay + dy } end end
            end
          end
        end
        if not big and #cells > 0 and not (allWoody and woodyHasTrunkSupport(cells)) then
          for _, c in ipairs(cells) do local q = c[3]
            if sim.partExists(q) then local n2 = nameOf(sim.partProperty(q, "type"))
              if WOODY[n2] then sim.partKill(q); if n2 == "WOOD" then give("WOOD", 1) end; broke = broke + 1
              else local t = eid(RUBBLE[n2] or "STNE"); if t then sim.partProperty(q, "type", t); broke = broke + 1 end end
            end end
        end
      else seen[key] = true end
    end
  end end
  return broke
end
-- Sustained heat beam: TPT averages heat across neighbours, so a single hot pulse dilutes below the melting
-- point. Weapons/tools call this every tick to accumulate heat until the material reaches its own transition
-- temperature (granite 1523K -> lava, sand 1973K, titanium 1941K, ice 273K -> water/steam).
function R.addHeat(cx, cy, rad, kelvin, cap)
  cap = cap or 9000
  local n = 0
  for y = cy - rad, cy + rad do for x = cx - rad, cx + rad do
    if (x-cx)^2 + (y-cy)^2 <= rad*rad + 1 then
      local p = sim.partID(x, y)
      if p then local t = sim.partProperty(p, "temp") or 295
        local d = kelvin * (1 - 0.5 * math.sqrt((x-cx)^2 + (y-cy)^2) / math.max(1, rad))
        sim.partProperty(p, "temp", math.min(cap, t + d)); n = n + 1 end
    end
  end end
  return n
end
-- Falling trees: rotate the felled crown about the cut, then let it shatter into wood on impact.
function R.updateFalling()
  local F = R.falling; if not F or #F == 0 then return end
  for i = #F, 1, -1 do local rec = F[i]
    local age = R.frame - rec.t
    local ang = (age / 30) ^ 1.6 * 1.5                              -- accelerating topple, ~85 degrees by frame 30
    local ca, sa = math.cos(ang * rec.dir), math.sin(ang * rec.dir)
    local landed = age >= 30
    for _, c in ipairs(rec.cells) do local p, ox, oy = c[1], c[2], c[3]
      if sim.partExists(p) then
        local nx = rec.px + (ox * ca - oy * sa)
        local ny = rec.py + (ox * sa + oy * ca)
        if nx >= M and nx < W - M and ny >= M and ny < H - M then sim.partPosition(p, nx, ny)
        else sim.partKill(p) end
      end end
    if landed then
      for _, c in ipairs(rec.cells) do if sim.partExists(c[1]) then sim.partKill(c[1]) end end
      R.give("WOOD", rec.wood); R.rebuildHotbar()
      say("The tree crashes down (+" .. rec.wood .. " Wood)")
      -- Now that the falling mass is gone, anything it was propping up as a "big"
      -- clump during the fellFrom sweep is genuinely orphaned -- sweep again.
      pcall(R.crumble, rec.px, rec.py - 10, 18)
      table.remove(F, i)
    end
  end
end
local checkFell   -- forward declaration: useTool calls it after a chop (defined below)
local nudgeLiquidsNear   -- forward: useTool calls after mining (defined below)
local function smartTarget(mx, my, reach, only, power)  -- first mineable block along the ray player -> cursor (Terraria smart cursor)
  local px, py = pcanvas(); local dx, dy = mx - px, my - py; local d = math.sqrt(dx*dx + dy*dy); if d < 1 then return nil end
  local ux, uy = dx / d, dy / d; local maxd = math.min(math.max(d, 10), reach)
  for st = 5, maxd, 1 do local x, y = floor(px + ux*st + 0.5), floor(py + uy*st + 0.5)
    for oy = -1, 1 do for ox = -1, 1 do local p = sim.partID(x + ox, y + oy)
      if p then local nm = nameOf(sim.partProperty(p, "type")); local tier = R.MINEABLE[nm]; if tier and (not only or only[nm]) and (not power or tier <= power + 1) then return x, y end end end end end
  return nil
end
R.smartTarget = smartTarget
local function useTool(mx, my, fine)
  local s = selected(); if not s or not s:find("^tool:") then return end
  local key = s:sub(6); local tool = R.TOOLS[key]; if not tool then return end
  if fine then
  elseif (key == "pick" or key == "axe") and R.smart ~= false then
    local tx, ty = smartTarget(mx, my, tool.reach, tool.only, tool.power)
    if not tx then R.hint = "nothing to dig that way"; return end
    mx, my = tx, ty
  elseif not inReach(mx, my, tool.reach) then R.hint = "out of reach"; return end
  if key == "pick" or key == "axe" then
    if (R.frame - (R.lastMine or -99)) < tool.speed then return end; R.lastMine = R.frame
    local got = {}; local r = fine and (R.brush or 0) or (tool.radius or 3); local blocked; local chipped = 0; local dug = false; local hadAdjLiq = false; local digQueued = false
    local LIQUID_DIG = { WATR=1, DSTW=1, SLTW=1, OIL=1, BLD=1 }
    local function digAdjacentLiquid(cx, cy)
      for _, d in ipairs({{0,1},{0,-1},{1,0},{-1,0}}) do
        local q = sim.partID(cx + d[1], cy + d[2])
        if q and LIQUID_DIG[nameOf(sim.partProperty(q, "type"))] then return true end
      end
      return false
    end
    R.lastHitAt = R.frame; R.swingAt = { mx, my, R.frame }
    for y = my-r, my+r do for x = mx-r, mx+r do local p = sim.partID(x, y)
      if p and (x-mx)^2 + (y-my)^2 <= r*r + 1 then local nm = nameOf(sim.partProperty(p, "type")); local tier = R.MINEABLE[nm]
        if tier and (not tool.only or tool.only[nm]) then
          if tier > tool.power + 1 then blocked = nm
          else local need = fine and 1 or math.max(1, (R.HARD[nm] or 3) - (tool.power - tier)); if tier > tool.power then need = need * 2 end
            local hits = (R.blockHits[p] or 0) + 1      -- per particle: ids are stable across camera shifts
            if hits >= need then R.blockHits[p] = nil; sim.partKill(p); local item = (nm == "BCOL") and "COAL" or nm; give(item, 1); got[item] = (got[item] or 0) + 1; dug = true
              -- Real negative pressure, not scripted particle spawning: the previous
              -- attempt (spawn an OXYG particle on ~55% of hits) called an O(particle
              -- count) scan PER DESTROYED CELL inside this radius loop -- fine for one
              -- cell, a real lag spike for a soft-material swing that clears dozens at
              -- once. Setting real low pressure here is cheap (one float write) and
              -- lets the sim's own actual air/gas physics pull surrounding air in --
              -- genuinely "sealed pockets have their own pressure, opening them lets
              -- outside atmosphere rush in," not an illusion of it.
              -- -2 read as too weak/slow to notice ("air should be rushing in quicker") --
              -- pressure range goes to -256, so -2 was barely a ripple. Bumped to a real,
              -- immediately-felt pull; still self-limiting since the sim's own physics
              -- equalizes it back out over time rather than staying a permanent vacuum.
              -- Full -8 beside liquid was yanking water upward into mined air pockets
              -- (reads as floating midair). Ease off when a liquid neighbor exists.
              -- v1.15.41: queue delayed ventilation instead of instant full vacuum.
              if R.queuePendingAir then
                local nearLiq = digAdjacentLiquid(x, y)
                hadAdjLiq = nearLiq or hadAdjLiq
                if not digQueued then
                  R.queuePendingAir(x + R.cam.x, y + R.cam.y, nearLiq)
                  digQueued = true
                end
              else
                local pcx, pcy = floor(x / sim.CELL), floor(y / sim.CELL)
                pcall(sim.pressure, pcx, pcy, digAdjacentLiquid(x, y) and -2 or -8)
              end
            else R.blockHits[p] = hits; chipped = chipped + 1 end end end end end end
    -- every swing near a trunk damages the tree, even once the aim point is already hollow
    if key == "axe" then pcall(checkFell, mx, my, 1.4) end
    if dug and hadAdjLiq then pcall(nudgeLiquidsNear, mx + R.cam.x, my + R.cam.y, math.min(r + 3, 6)) end
    if dug and key == "axe" and (got.WOOD or got.GRSS or got.PLNT) then pcall(R.crumble, mx, my, (tool.radius or 3) + 2) end
    local t = {}; for k, v in pairs(got) do t[#t+1] = "+" .. v .. " " .. nice(k) end
    if #t > 0 then
      R.hint = table.concat(t, "  ") .. (chipped > 0 and "  (chipping...)" or "")
      if (R.frame - (R._hotbarHintAt or -999)) > 8 then R.rebuildHotbar(); R._hotbarHintAt = R.frame end
    elseif chipped > 0 then R.hint = "chipping..." elseif blocked then R.hint = nice(blocked) .. " needs a better pick" end
  elseif key == "sword" then
    if (R.frame - (R.lastSwing or -99)) < tool.speed then return end; R.lastSwing = R.frame
    local fg = eid("FIGH"); local hits = 0
    if fg then for i in sim.parts() do if sim.partProperty(i, "type") == fg then local x, y = sim.partPosition(i); if dist2(x, y, mx, my) <= 14*14 then local life = (sim.partProperty(i, "life") or 100) - tool.dmg; if life <= 0 then sim.partKill(i); give("BMTL", 2); say("Enemy defeated (+2 scrap)") else sim.partProperty(i, "life", life) end; hits = hits + 1 end end end end
    R.hint = hits > 0 and ("hit x" .. hits) or "swing"
  elseif key == "torch" then
    if inv("WOOD") < 1 then R.hint = "torch needs 1 WOOD"; return end
    if (R.frame - (R.lastPlace or -99)) < 10 then return end; R.lastPlace = R.frame
    local p = sim.partID(mx, my); local lit = false
    for oy = -2, 2 do for ox = -2, 2 do local q = sim.partID(mx + ox, my + oy); if q and nameOf(sim.partProperty(q, "type")) == "COAL" then
      for k = -1, 1 do local a = sim.partID(mx + k, my - 1); if not a then local f = sim.partCreate(-1, mx + k, my - 1, eid("FIRE")); if f and f >= 0 then sim.partProperty(f, "temp", 1200); lit = true end end end
      sim.partProperty(q, "temp", 600) end end end
    if lit then R.hint = "lit!"; R.inventory.WOOD = inv("WOOD") - 1; return end
    if not p then local wd = eid("WOOD"); local ok1 = sim.partCreate(-1, mx, my, wd); local ok2 = sim.partCreate(-1, mx, my - 1, wd)
      if ok1 and ok1 >= 0 then R.torches = R.torches or {}; R.torches[#R.torches + 1] = { x = mx + R.cam.x, y = my - 2 + R.cam.y, born = R.frame }; R.inventory.WOOD = inv("WOOD") - 1; R.hint = "torch lit - real fire, keep it off your wood!" end end
  elseif key == "bucket" then
    if (R.frame - (R.lastPlace or -99)) < 4 then return end; R.lastPlace = R.frame
    local p = sim.partID(mx, my)
    if p and nameOf(sim.partProperty(p, "type")) == "WATR" then local n = 0; for y = my-3, my+3 do for x = mx-3, mx+3 do local q = sim.partID(x, y); if q and nameOf(sim.partProperty(q, "type")) == "WATR" then sim.partKill(q); n = n + 1 end end end; give("WATR", n); R.hint = "+" .. n .. " Water"; R.rebuildHotbar()
    elseif inv("WATR") > 0 then local n = 0; for y = my-2, my+2 do for x = mx-2, mx+2 do if inv("WATR") > 0 and not sim.partID(x, y) then local q = sim.partCreate(-1, x, y, eid("WATR")); if q and q >= 0 then R.inventory.WATR = inv("WATR") - 1; n = n + 1 end end end end; R.hint = "poured " .. n
    else R.hint = "bucket: aim at water to scoop" end
  end
end
R.useTool = useTool
local function buildStation(kind, mx, my)  -- mx,my canvas; structure sits on the ground under the cursor
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local gy = wy; for k = 0, 40 do if solidW(wx, gy + 1) then break end; gy = gy + 1 end
  local function box(x1, y1, x2, y2, el) local t = eid(el); if not t then return end; for y = y1, y2 do for x = x1, x2 do local p = sim.partID(x - R.cam.x, y - R.cam.y); if p then sim.partKill(p) end; sim.partCreate(-1, x - R.cam.x, y - R.cam.y, t) end end end
  if kind == "WORKBENCH" then box(wx, gy - 3, wx + 11, gy - 2, "WOOD"); box(wx + 1, gy - 1, wx + 1, gy, "WOOD"); box(wx + 10, gy - 1, wx + 10, gy, "WOOD")
  elseif kind == "ANVIL" then box(wx + 1, gy - 3, wx + 8, gy - 2, "METL"); box(wx + 3, gy - 1, wx + 6, gy, "METL")
  elseif kind == "RESEARCH" then box(wx, gy - 4, wx + 11, gy - 3, "METL"); box(wx + 2, gy - 6, wx + 4, gy - 4, "GLAS"); box(wx + 1, gy - 2, wx + 1, gy, "METL"); box(wx + 10, gy - 2, wx + 10, gy, "METL")
  elseif kind == "ADVLAB" then box(wx, gy - 5, wx + 13, gy - 4, "STEL"); box(wx + 2, gy - 8, wx + 5, gy - 5, "GLAS"); box(wx + 8, gy - 8, wx + 11, gy - 5, "GLAS"); box(wx + 1, gy - 3, wx + 1, gy, "STEL"); box(wx + 12, gy - 3, wx + 12, gy, "STEL")
  elseif kind == "FURNACE" then local el = ROCK
    box(wx, gy - 12, wx + 13, gy, el)                       -- body
    for y = gy - 10, gy - 2 do for x = wx + 2, wx + 11 do local p = sim.partID(x - R.cam.x, y - R.cam.y); if p then sim.partKill(p) end end end  -- chamber
    box(wx + 2, gy - 3, wx + 11, gy - 2, "COAL")            -- coal bed
    for y = gy - 7, gy - 5 do local p = sim.partID(wx + 13 - R.cam.x, y - R.cam.y); if p then sim.partKill(p) end end    -- side opening
    for y = gy - 12, gy - 11 do local p = sim.partID(wx + 6 - R.cam.x, y - R.cam.y); if p then sim.partKill(p) end; p = sim.partID(wx + 7 - R.cam.x, y - R.cam.y); if p then sim.partKill(p) end end  -- chimney
  end
  R.stations[#R.stations + 1] = { kind = string.lower(kind), x = wx, y = gy }
  say(kind:sub(1, 1) .. kind:sub(2):lower() .. " built" .. (kind == "FURNACE" and " - light the coal with the torch (slot 4)" or ""))
end
R.buildStation = buildStation
-- TREE FELLING: cutting enough of a trunk collapses everything the tree was holding up.
-- Flood-fills the connected WOOD/GRSS/PLNT above the cut, checks it is no longer supported, then drops it as real falling particles.
function R.fellFrom(cx, cy)
  local wood, leaf = eid("WOOD"), eid("GRSS") or eid("PLNT")
  if not wood then return 0 end
  -- TRUNK ONLY: flood fill through WOOD. Leaves never act as a connection, so two trees whose canopies
  -- touch can never be felled together (Terraria fells exactly one tree).
  local seen, stack, trunk = {}, {{cx, cy}}, {}
  while #stack > 0 and #trunk < 600 do
    local c = table.remove(stack); local x, y = c[1], c[2]; local k = x * 4096 + y
    if not seen[k] and x >= M and x < W - M and y >= M and y < H - M and y <= cy then
      seen[k] = true
      local p = sim.partID(x, y)
      if p and sim.partProperty(p, "type") == wood then
        trunk[#trunk + 1] = { x, y, p, wood }
        -- Radius 8, not the earlier radius-3 attempt: confirmed via direct testing that a
        -- single realistic axe swing (radius 4 mining circle) can hollow out a gap wide
        -- enough that radius 3 still failed to bridge it -- the flood fill hit #trunk<8
        -- and fellFrom silently did nothing, leaving the entire canopy above the gap
        -- floating forever (this was the actual, confirmed cause of "chopped the tree
        -- but the canopy's still there," not fully fixed by the earlier attempt). Radius
        -- 8 comfortably clears a radius-4 chop with margin; still cheap since the trunk
        -- array is capped at 600 cells and `seen` dedupes regardless of how many
        -- candidates get pushed per node.
        for dy = -8, 8 do for dx = -8, 8 do if dx*dx + dy*dy <= 64 then stack[#stack + 1] = { x + dx, y + dy } end end end
      end
    end
  end
  if #trunk < 8 then return 0 end
  local cells, lseen = {}, {}
  for _, t in ipairs(trunk) do cells[#cells + 1] = t end
  for _, t in ipairs(trunk) do
    for dy = -14, 6 do for dx = -14, 14 do
      if dx*dx + dy*dy <= 196 then
        local x, y = t[1] + dx, t[2] + dy; local k = x * 4096 + y
        if not lseen[k] and x >= M and x < W - M and y >= M and y < H - M and y <= cy then
          lseen[k] = true
          local p = sim.partID(x, y)
          if p then local ty = sim.partProperty(p, "type")
            if ty == leaf or nameOf(ty) == "PLNT" then cells[#cells + 1] = { x, y, p, ty } end end
        end
      end
    end end
  end
  local drop = 0
  local rec = { cells = {}, px = cx, py = cy, t = R.frame, dir = (R.P.x > cx + R.cam.x) and -1 or 1 }
  for _, c in ipairs(cells) do local p, t = c[3], c[4]
    if sim.partExists(p) then
      if t == wood then drop = drop + 1 end
      rec.cells[#rec.cells + 1] = { p, c[1] - cx, c[2] - cy, t }
    end end
  rec.wood = math.max(1, floor(drop / 3))
  R.falling = R.falling or {}
  R.falling[#R.falling + 1] = rec
  R.timber = { x = cx, y = cy, t = R.frame }
  -- Sweep the canopy footprint right away for any wood/leaf the flood fills above
  -- missed (a clump still touching the falling mass is skipped as "big" here and
  -- picked up by the landed-sweep in R.updateFalling instead).
  pcall(R.crumble, cx, cy - 10, 18)
  say("Timber!")
  return rec.wood
end
function checkFell(mx, my, power)   -- Terraria model: the trunk has HP; only the base fells the tree
  local wood = eid("WOOD"); if not wood then return end
  local hx, hy
  for y = my - 4, my + 4 do for x = mx - 5, mx + 5 do local p = sim.partID(x, y)
    if p and sim.partProperty(p, "type") == wood then hx, hy = x, y; break end end
    if hx then break end end
  if not hx then return end
  local base = hy
  for k = 1, 90 do local found = false
    for dx = -1, 1 do local p = sim.partID(hx + dx, base + 1)
      if p and sim.partProperty(p, "type") == wood then base = base + 1; hx = hx + dx; found = true; break end end
    if not found then break end end
  -- measure the trunk tolerantly: chopping leaves gaps, so count wood in the column and take the top extent
  local h, count, gap = 0, 0, 0
  for k = 1, 90 do local any = false
    for dx = -3, 3 do local p = sim.partID(hx + dx, base - k)
      if p and sim.partProperty(p, "type") == wood then any = true; count = count + 1 end end
    if any then h = k; gap = 0 else gap = gap + 1; if gap > 8 then break end end
  end
  if h < 12 or count < 20 then return end
  -- normalise to the leftmost trunk cell on the base row so every swing keys the same tree
  local lx = hx
  for k = 1, 8 do local p = sim.partID(lx - 1, base); if p and sim.partProperty(p, "type") == wood then lx = lx - 1 else break end end
  local key = (lx + R.cam.x) * 4096 + (base + R.cam.y)
  R.treeHP = R.treeHP or {}
  local hp = (R.treeHP[key] or 100) - math.max(8, 24 * (power or 1))
  R.treeHP[key] = hp
  R.treeHit = { x = hx, y = base, top = base - h, hp = math.max(0, hp), t = R.frame }
  if hp <= 0 then R.treeHP[key] = nil; R.fellFrom(hx, base - 1) end
end
R.checkFell = checkFell
-- Native TPT brush radius (and optionally shape) sync. tpt.brushID/brushRadius
-- assert eventTraitInterface -- KEY/MOUSE/WHEEL only, never onTick/placeAt.
-- RPG placement uses cached R.brushShape + R.brushHit; V/Tab own shape locally.
local BRUSH_ID = { circle = 0, square = 1, triangle = 2 }
local BRUSH_NAME = { [0] = "circle", [1] = "square", [2] = "triangle" }
local BRUSH_R_MAX = 40
function R.pullNativeBrush(shapeToo)
  -- shapeToo=false: sync radius only (mouse-move) so V/Tab shape isn't stomped.
  if shapeToo == nil then shapeToo = true end
  -- tpt.brushID / tpt.brushx / tpt.brushy are PROPERTIES, not functions: reading them
  -- yields a number and writing them is plain assignment. The old code did
  -- pcall(tpt.brushID) -- i.e. CALLING a number -- which failed 100% of the time with
  -- "attempt to call a number value", silently, inside a pcall. So native brush sync has
  -- never worked in either direction, and V/Tab only ever moved the RPG's private copy
  -- while native TPT's own brush (which does the placing in sandbox/TPT-menu mode) never
  -- changed. Reading them also asserts an interface event, hence the closures.
  local ok, id = pcall(function() return tpt.brushID end)
  local ok2, rx, ry = pcall(function() return tpt.brushx, tpt.brushy end)
  R._brushPullErr = (not ok and tostring(id)) or (not ok2 and tostring(rx)) or nil
  if shapeToo and ok and type(id) == "number" then
    R.brushShape = BRUSH_NAME[id] or "circle"
    R._nativeBrushId = id
  end
  if ok2 and type(rx) == "number" then
    R.brushRx = math.max(0, floor(rx + 0.5))
    R.brushRy = math.max(0, floor((ry or rx) + 0.5))
    R.brush = math.max(R.brushRx, R.brushRy)
    if R.brush == 0 then R.brushShape = "single" end
  end
  return (ok and ok2) and true or false
end
function R.pushNativeBrush()
  local shape = R.brushShape or "square"
  local r = math.max(0, math.min(BRUSH_R_MAX, floor(R.brush or 1)))
  if shape == "single" then r = 0; shape = "square" end
  pcall(function() tpt.brushID = BRUSH_ID[shape] or 1 end)
  pcall(function() tpt.brushx = r; tpt.brushy = r end)
  R.brush, R.brushRx, R.brushRy = r, r, r
  if r == 0 then R.brushShape = "single" else R.brushShape = shape end
end
function R.brushHit(x, y, mx, my, rx, ry, shape)
  rx, ry = rx or 0, ry or 0
  if shape == "single" or (rx <= 0 and ry <= 0) then return x == mx and y == my end
  local dx, dy = x - mx, y - my
  if shape == "circle" then
    local nrx, nry = math.max(rx, 1), math.max(ry, 1)
    return (dx * dx) / (nrx * nrx) + (dy * dy) / (nry * nry) <= 1.0001
  end
  if shape == "triangle" then
    local x1, y1 = mx, my - ry
    local x2, y2 = mx - rx, my + ry
    local x3, y3 = mx + rx, my + ry
    local function sign(px, py, ax, ay, bx, by)
      return (px - bx) * (ay - by) - (ax - bx) * (py - by)
    end
    local d1 = sign(x, y, x1, y1, x2, y2)
    local d2 = sign(x, y, x2, y2, x3, y3)
    local d3 = sign(x, y, x3, y3, x1, y1)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))
  end
  return true
end
function R.brushShellHit(x, y, mx, my, rx, ry, shape)
  if not R.brushHit(x, y, mx, my, rx, ry, shape) then return false end
  local irx, iry = math.max(0, rx - 1), math.max(0, ry - 1)
  if irx <= 0 and iry <= 0 then return true end
  return not R.brushHit(x, y, mx, my, irx, iry, shape)
end
local function isPlaceableBlock(el)
  return el and not el:find("^tool:") and not R.ITEMS[el]
end
local function shiftBuildMode()
  return R.shiftHeld and isPlaceableBlock(selected())
end
local function placeCommitContext(el)
  local t = eid(el == "COAL" and has("BCOL") and "BCOL" or el)
  if not t then return nil end
  return t, R.P.x - R.cam.x, R.P.y - R.cam.y
end
local function stampBrushAt(mx, my, el, t, px, py, fine)
  local rx = fine and 0 or (R.brushRx or R.brush or 1)
  local ry = fine and 0 or (R.brushRy or R.brush or 1)
  local shape = R.brushShape or "square"
  local hitFn = R.brushShell and R.brushShellHit or R.brushHit
  local g = R.gridSize or 4
  local x1, y1, x2, y2 = mx - rx, my - ry, mx + rx, my + ry
  if R.grid or R.ctrlHeld or R.shiftHeld then
    local gx = floor((mx + R.cam.x) / g) * g - R.cam.x
    local gy = floor((my + R.cam.y) / g) * g - R.cam.y
    x1, y1, x2, y2 = gx - g * rx, gy - g * ry, gx + g * rx + g - 1, gy + g * ry + g - 1
  end
  local placed = 0
  for yy = y1, y2 do for xx = x1, x2 do
    if hitFn(xx, yy, mx, my, rx, ry, shape) then
      local inPlayer = xx >= px + BOXL - 1 and xx <= px + BOXR + 1 and yy >= py + BOXT - 1 and yy <= py
      if inv(el) > 0 and not sim.partID(xx, yy) and not inPlayer then
        local n = sim.partCreate(-1, xx, yy, t)
        if n and n >= 0 then R.inventory[el] = inv(el) - 1; placed = placed + 1; setMoltenTemp(n, el) end
      end
    end
  end end
  return placed
end
local function snapLineEnd(ax, ay, mx, my)
  if math.abs(mx - ax) >= math.abs(my - ay) then return mx, ay else return ax, my end
end
local function commitLine(mx, my)
  local el = selected(); if not el or el:find("^tool:") or R.ITEMS[el] then return end
  if inv(el) <= 0 then return end
  local t, px, py = placeCommitContext(el); if not t then return end
  local ax, ay = mx, my
  if R.placeAnchor then ax, ay = R.placeAnchor[1], R.placeAnchor[2] end
  mx, my = snapLineEnd(ax, ay, mx, my)
  local placed = 0
  local cx, cy = ax, ay
  local dx, dy = math.abs(mx - ax), math.abs(my - ay)
  local sx = ax < mx and 1 or -1
  local sy = ay < my and 1 or -1
  local err = dx - dy
  while true do
    placed = placed + stampBrushAt(cx, cy, el, t, px, py, false)
    if cx == mx and cy == my then break end
    local e2 = 2 * err
    if e2 > -dy then err = err - dy; cx = cx + sx end
    if e2 < dx then err = err + dx; cy = cy + sy end
  end
  if placed > 0 then R.hint = "placed " .. nice(el) .. (R.brushShell and " (shell)" or "") end
end
local function commitRect(mx, my)
  local el = selected(); if not el or el:find("^tool:") or R.ITEMS[el] then return end
  if inv(el) <= 0 then return end
  local t, px, py = placeCommitContext(el); if not t then return end
  local ax, ay = mx, my
  if R.placeAnchor then ax, ay = R.placeAnchor[1], R.placeAnchor[2] end
  local x1, y1 = math.min(ax, mx), math.min(ay, my)
  local x2, y2 = math.max(ax, mx), math.max(ay, my)
  local shape = R.brushShape or "square"
  local placed = 0
  if shape == "circle" then
    local rcx, rcy = (x1 + x2) / 2, (y1 + y2) / 2
    local erx = math.max(1, (x2 - x1) / 2)
    local ery = math.max(1, (y2 - y1) / 2)
    for yy = y1, y2 do for xx = x1, x2 do
      local ndx = (xx - rcx) / erx
      local ndy = (yy - rcy) / ery
      if ndx * ndx + ndy * ndy <= 1.001 then
        local inPlayer = xx >= px + BOXL - 1 and xx <= px + BOXR + 1 and yy >= py + BOXT - 1 and yy <= py
        if inv(el) > 0 and not sim.partID(xx, yy) and not inPlayer then
          local n = sim.partCreate(-1, xx, yy, t)
          if n and n >= 0 then R.inventory[el] = inv(el) - 1; placed = placed + 1; setMoltenTemp(n, el) end
        end
      end
    end end
  else
    for yy = y1, y2 do for xx = x1, x2 do
      local inPlayer = xx >= px + BOXL - 1 and xx <= px + BOXR + 1 and yy >= py + BOXT - 1 and yy <= py
      if inv(el) > 0 and not sim.partID(xx, yy) and not inPlayer then
        local n = sim.partCreate(-1, xx, yy, t)
        if n and n >= 0 then R.inventory[el] = inv(el) - 1; placed = placed + 1; setMoltenTemp(n, el) end
      end
    end end
  end
  if placed > 0 then R.hint = "placed " .. nice(el) .. " region" end
end
local function placeAt(mx, my, fine)
  local el = selected(); if not el or el:find("^tool:") then R.hint = "pick a block (palette or slots 6-0) to place"; return end
  if inv(el) <= 0 then R.hint = "none left"; return end
  if runHooks(R.hooks.place, el, mx, my, fine) then return end   -- a plugin handled this item
  if R.ITEMS[el] then if (R.frame - (R.lastPlace or -99)) < 20 then return end; R.lastPlace = R.frame; R.inventory[el] = inv(el) - 1; buildStation(el, mx, my); R.mouse.r = false; return end
  if shiftBuildMode() then fine = false end   -- Shift+block: full native brush (circle/square/triangle), not 1px zoom mode
  if not fine and not inReach(mx, my, 30) and not shiftBuildMode() then R.hint = "out of reach"; return end
  if (R.frame - (R.lastPlace or -99)) < 2 then return end; R.lastPlace = R.frame
  local t, px, py = placeCommitContext(el); if not t then return end
  -- Native TPT draw modes: Ctrl+drag = ellipse/box on release, Shift+drag = line on release,
  -- Ctrl+Shift = flood box on release. Per-tick stamping along a locked axis was overlapping
  -- full brush circles every frame and made walls far thicker than intended.
  if R.ctrlHeld and R.shiftHeld then
    if not R.placeAnchor then R.placeAnchor = { mx, my }; R.placeBox = true end
    R.placeRect = false; R.placeLine = false
    return
  end
  if R.ctrlHeld then
    if not R.placeAnchor then R.placeAnchor = { mx, my }; R.placeRect = true end
    R.placeBox = false; R.placeLine = false
    return
  end
  if R.shiftHeld then
    if not R.placeAnchor then R.placeAnchor = { mx, my }; R.placeLine = true end
    R.placeBox = false; R.placeRect = false
    return
  end
  local placed = stampBrushAt(mx, my, el, t, px, py, fine)
  if placed > 0 then R.hint = "placed " .. nice(el); if inv(el) <= 0 then R.hint = "placed " .. nice(el) .. " - none left"; R.mouse.r = false end end
end
-- release point, committed once (not per-tick) so it doesn't burn through
-- inventory or lag out while dragging a big box.
local function commitBox(mx, my)
  -- Box-drag fill is always a filled rectangle; brush shape is ignored here
  -- (a "single" or "circle" shape would defeat the user's explicit box-drag intent).
  local el = selected(); if not el or el:find("^tool:") or R.ITEMS[el] then return end
  if inv(el) <= 0 then return end
  local t = eid(el == "COAL" and has("BCOL") and "BCOL" or el); if not t then return end
  local ax, ay = mx, my
  if R.placeAnchor then ax, ay = R.placeAnchor[1], R.placeAnchor[2] end
  local x1, y1 = math.min(ax, mx), math.min(ay, my)
  local x2, y2 = math.max(ax, mx), math.max(ay, my)
  local px, py = R.P.x - R.cam.x, R.P.y - R.cam.y
  local placed = 0
  for y = y1, y2 do for x = x1, x2 do
    local inPlayer = x >= px + BOXL - 1 and x <= px + BOXR + 1 and y >= py + BOXT - 1 and y <= py
    if inv(el) > 0 and not sim.partID(x, y) and not inPlayer then
      local n = sim.partCreate(-1, x, y, t); if n and n >= 0 then R.inventory[el] = inv(el) - 1; placed = placed + 1; setMoltenTemp(n, el) end
    end
  end end
  if placed > 0 then R.hint = "placed " .. nice(el) end
end

-- ================================================================ input (unhandled keys/clicks fall through to TPT: Z zoom etc.)
R.mouse = R.mouse or {x=0, y=0, l=false, r=false}
-- BUILD MODE: while the TPT zoom window is locked open and the mouse is inside it, RPG handles
-- fine placement; the decorative frame (edge/corners) must pass clicks to native GameView so
-- the window can be dragged/resized (see zoomFrameHit, mirrors GameView::HitTestZoomWindowFrame).
local function inZoom(x, y)
  local ok, en = pcall(ren.zoomEnabled); if not ok or not en then return false end
  local ok2, zx, zy, zf, zs = pcall(ren.zoomWindow); if not ok2 then return false end
  return x >= zx and x < zx + zs and y >= zy and y < zy + zs
end
R.inZoom = inZoom
-- Grabbable zoom frame zone (frameMargin px straddling the border, cornerSize for resize handles).
-- Returns "move", "resizeTL"/"TR"/"BL"/"BR", or nil (not on frame / still placing).
local function zoomFrameHit(x, y)
  local ok, en = pcall(ren.zoomEnabled); if not ok or not en or R.zoomPending then return nil end
  local ok2, zx, zy, zf, zs = pcall(ren.zoomWindow); if not ok2 then return nil end
  local frameMargin, cornerSize = 10, 16
  local outerTLx, outerTLy = zx - frameMargin, zy - frameMargin
  local outerBRx, outerBRy = zx + zs + frameMargin, zy + zs + frameMargin
  if x < outerTLx or y < outerTLy or x >= outerBRx or y >= outerBRy then return nil end
  local innerTLx, innerTLy = zx + frameMargin, zy + frameMargin
  local innerBRx, innerBRy = zx + zs - frameMargin, zy + zs - frameMargin
  if x >= innerTLx and y >= innerTLy and x < innerBRx and y < innerBRy then return nil end
  local nearLeft = x < outerTLx + cornerSize
  local nearRight = x >= outerBRx - cornerSize
  local nearTop = y < outerTLy + cornerSize
  local nearBottom = y >= outerBRy - cornerSize
  if nearLeft and nearTop then return "resizeTL" end
  if nearRight and nearTop then return "resizeTR" end
  if nearLeft and nearBottom then return "resizeBL" end
  if nearRight and nearBottom then return "resizeBR" end
  return "move"
end
R.zoomFrameHit = zoomFrameHit
local function zoomToCanvas(x, y)  -- screen point inside the zoom window -> magnified canvas point
  local ok, zx, zy, zf, zs = pcall(ren.zoomWindow); local ok2, sx, sy, ss = pcall(ren.zoomScope)
  if not ok or not ok2 then return x, y end
  return sx + floor((x - zx) / zf), sy + floor((y - zy) / zf)
end
R.zoomToCanvas = zoomToCanvas
local PAL_Y = 384 - 56
local function paletteHit(x, y)  -- palette strip shown while zoom is open: returns element under (x,y)
  local ok, en = pcall(ren.zoomEnabled); if not ok or not en then return nil end
  if y < PAL_Y or y >= PAL_Y + 24 then return nil end
  local names = {}; for k, v in pairs(R.inventory or {}) do if v > 0 then names[#names+1] = k end end; table.sort(names)
  local i = floor((x - 4) / 26) + 1; return names[i]
end
function fireHook(mx, my)
  if not R.accOn("hook") then return false end
  local tx, ty = smartTarget(mx, my, 110, nil, 99)
  if tx then R.P.hook = { x = tx + R.cam.x, y = ty + R.cam.y, t = 0 }; R.hint = "hook!" else R.hint = "nothing to hook that way" end
  return true
end
R.fireHook = fireHook
local function hitRect(x, y, r) return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h end
-- Forward-declared: drawTitleScreen/titleMouseDown are called here (and at the drawHUD site
-- below) but only DEFINED much later in the file. `local function` at the later point creates
-- a brand new local starting there -- every earlier reference (like the one on the very next
-- line) had already resolved to a global that was never set, so it called nil every single
-- frame ("attempt to call global 'drawTitleScreen'/'titleMouseDown' (a nil value)"), spamming
-- the error console nonstop. Declaring the names here first and assigning the real bodies
-- later (without the `local` keyword there, so they fill THESE locals) fixes it properly.
local drawTitleScreen, titleMouseDown
local titleMouseX, titleMouseY = -1, -1   -- for real button hover highlighting on the title screen
local function onMouseDown(x, y, button)
  if R.tptMenusPending then R.applyPendingMenus() end
  -- TPT native brush only skips placement when Lua returns false; nil/true lets the click
  -- through to Window::DoMouseDown (GameView.cpp). Title/inactive used to return nil, so
  -- Create/Play held the native brush down through world start -- sand spray every new seed.
  if titleMouseDown(x, y) then return false end
  -- SANDBOX FIX 2026-09-02: reported immediately as "the sandbox vanilla isn't working at
  -- all". In TPT, returning FALSE from a Lua mouse handler CANCELS the event
  -- (GameView.cpp / Window::DoMouseDown). Sandbox mode sets R.active = false, so this guard
  -- and its twin in onMouseUp were swallowing every click -- the native brush could never
  -- place a single particle. Sandbox must fall through to stock Powder Toy untouched, so it
  -- returns nil (allow default) BEFORE the inactive guard. Checked first in all three mouse
  -- handlers for the same reason.
  -- SANDBOX BRUSH SIZING. PhoenixFire808: "when I'm holding my middle mouse button and moving
  -- the mouse up or down, I want it to be the same as if I'm scrolling." Stock TPT only
  -- resizes a step at a time on the wheel, so getting to a large brush means spinning it a
  -- lot; this makes sizing a single smooth drag instead. Hold MIDDLE mouse, move up to grow
  -- and down to shrink, exactly like the wheel but continuous.
  -- Size is computed from the ORIGINAL size plus total travel (not accumulated per event) so
  -- it is predictable: return to where you started and you get the size you started with.
  -- tpt.brushx/brushy are writable but "restricted to interface events" (compat.lua:699), so
  -- this only works from a real input handler like this one -- never from tooling.
  if R.sandboxMode then
    if button == 2 then
      local okx, bx = pcall(function() return tpt.brushx end)
      local oky, by = pcall(function() return tpt.brushy end)
      R.sbBrush = {
        active = true, ax = x, ay = y,
        baseX = (okx and type(bx) == "number") and bx or 4,
        baseY = (oky and type(by) == "number") and by or 4,
      }
      return false   -- consume the middle click so it does not also act as a paste/sample
    end
    -- Buttons get the click before anything else, including the plugin hooks, so a panel
    -- opening underneath can never make the toolbar unclickable.
    if button == 1 and R.sbButtonClick(x, y) then return false end
    -- GRAB: pick the character up and place him. Requested directly -- "some sort of grabbing
    -- tool to move him around, put him where I want." Only active while the Grab button is lit,
    -- so it can never interfere with ordinary drawing.
    if button == 1 and R.sbGrab and R.SB and R.SB.on and R.P then
      R.sbGrabbing = true
      R.P.x, R.P.y, R.P.vx, R.P.vy = x, y, 0, 0
      return false
    end
    if runHooks(R.hooks.sandboxMouseDown, x, y, button) then return false end
    return
  end
  if not R.active then return false end
  R.mouse.x, R.mouse.y = x, y
  -- Modal popups: click their button to dismiss (or click anywhere else on
  -- them to just swallow the click) -- explicitly asked for: not wanting to
  -- have to reach for the keyboard for something this simple.
  if R.changesPromptOpen then if hitRect(x, y, R.changesBtnRect) then R.dismissLocalChangelog() end; return false end
  if R.updatePromptOpen then if hitRect(x, y, R.updateBtnRect) then R.updatePromptOpen = false end; return false end
  if runHooks(R.hooks.mousedown, x, y, button) then return false end
  if R.menuOpen then R.menuClick(x, y); return false end
  if R.quickBarClick(x, y) then return false end
  if R.invOpen then R.uiClick(x, y, button); return false end
  -- Sandbox/TPT-menu mode means the real element menu, the
  -- favorites wheel, and normal click-to-place are wanted -- none of that reaches
  -- native TPT if this handler keeps swallowing every click for its own
  -- tool-swing/block-place logic below. Menu (above) and bag stay RPG-owned
  -- either way since those are its own overlay panels, not native TPT UI.
  if R.tptMenus then return end
  if button == 2 and R.accOn("hook") then fireHook(x, y); return false end   -- middle click = grapple
  local pal = paletteHit(x, y)
  if pal then local slot = (R.sel and R.sel >= 6) and R.sel or 6; for s6 = 6, 10 do if R.hotbar[s6] == pal then slot = s6 end end; R.hotbar[slot] = pal; R.sel = slot; R.hint = nice(pal) .. " selected"; return false end
  if button == 1 and zoomFrameHit(x, y) then R._zoomNativeGrab = true; return end  -- native drag/resize
  if R.zoomPending then R.zoomPending = false; R.zoomClick = true; return false end  -- Z pressed: this click locks the TPT zoom window
  if button == 1 then R.mouse.l = true; R._clickArmed = true; return false
  elseif button == 3 then R.mouse.r = true; return false end end
local function onMouseUp(x, y, button)
  -- Button-state reset runs before ANY early return (title/inactive used to skip
  -- the whole handler when not R.active, so a Create-click release never cleared state).
  if button == 1 then R.mouse.l = false; R._clickArmed = false end; if button == 3 then R.mouse.r = false end
  if R.sandboxMode then
    if R.sbGrabbing and button == 1 then R.sbGrabbing = false; return false end
    if R.sbBrush and R.sbBrush.active and button == 2 then R.sbBrush.active = false; return false end
    R.sbCheckShape()   -- also catches clicking the shape button in TPT's own toolbar
    if runHooks(R.hooks.sandboxMouseUp, x, y, button) then return false end
    return   -- see onMouseDown: `return false` here cancelled every click in sandbox
  end
  if R.titleScreen or not R.active then return false end
  if R.placeBox and button == 1 then commitBox(x, y) end
  if R.placeRect and button == 1 then commitRect(x, y) end
  if R.placeLine and button == 1 then commitLine(x, y) end
  R.placeAnchor = nil; R.placeBox = false; R.placeRect = false; R.placeLine = false
  runHooks(R.hooks.mouseup, x, y, button); if R.zoomClick then R.zoomClick = false; return end
  if R._zoomNativeGrab or (button == 1 and zoomFrameHit(x, y)) then R._zoomNativeGrab = false; return end
  if R.tptMenus then return end
  return false end
R._testOnMouseUp = onMouseUp   -- dev-only verification exposure
-- Emergency unstuck for the mouse: a held-click bug can still slip past
-- onMouseUp's button-state reset if the real SDL up-event never reaches
-- the bridge (e.g. window-defocus mid-drag, native-engine-level miss).
-- No tpt.mouseb/tpt.input polling API exists to read the live button
-- state, so the next best thing is a one-key "force release everything"
-- the player can hit without restarting -- bound to F11 by onKeyDown
-- below. Clears the same set onMouseUp resets (plus cooldown timestamps,
-- so a real release on the very next click can't immediately re-spam),
-- says so, returns true. R.lineAnchor is guarded with `if any` because
-- not every build defines it; missing key on a table is a Lua error.
function R.releaseMouse(announce)
  R.mouse = R.mouse or {}
  R.mouse.l = false; R.mouse.r = false
  R._clickArmed = false
  R.placeBox = false; R.placeAnchor = nil; R.placeRect = false; R.placeLine = false
  R.zoomClick = false; R.zoomPending = false; R._zoomNativeGrab = false
  R.lastPlace = nil; R.lastMine = nil
  if R.lineAnchor ~= nil then R.lineAnchor = nil end
  if announce then say("Mouse released") end
  return true
end
function R.setMenuOpen(on)
  local was = R.menuOpen
  R.menuOpen = on and true or false
  R.releaseMouse()
  if was and not R.menuOpen then R._placeGraceUntil = (R.frame or 0) + 30 end
  return R.menuOpen
end
function R.wouldPlace()
  if (R._placeGraceUntil or 0) > (R.frame or 0) then return false end
  return R._clickArmed and R.mouse and R.mouse.l
    and not R.menuOpen and not R.invOpen and not R.tptMenus and not R.uiPanelOpen
end
local function onMouseMove(x, y, dx, dy)
  if R.titleScreen then titleMouseX, titleMouseY = x, y end
  if R.sandboxMode then
    local b = R.sbBrush
    if b and b.active then
      -- WARP THE SHAPE: width and height move INDEPENDENTLY, so one drag can turn a circle
      -- into a wide ellipse or a square into a tall rectangle. Horizontal travel drives
      -- brushx, vertical drives brushy (up = taller, matching a wheel-up growing the brush).
      -- This works for whatever brush shape is selected -- circle, square or triangle -- since
      -- TPT builds all of them from the same x/y radii.
      -- Both are measured from the size the brush had when the drag STARTED, not accumulated
      -- per event, so returning to where you began restores exactly what you began with.
      -- 2px of travel per step felt closest to the wheel's own rate without being twitchy.
      local w = b.baseX + math.floor((x - b.ax) / 2)
      local h = b.baseY + math.floor((b.ay - y) / 2)
      w = math.max(1, math.min(200, w))
      h = math.max(1, math.min(200, h))
      b.w, b.h = w, h
      pcall(function() tpt.brushx = w; tpt.brushy = h end)
      return false
    end
    R.mouse = R.mouse or {}; R.mouse.x, R.mouse.y = x, y
    if R.sbGrabbing and R.P then
      -- carried, not thrown: velocity is zeroed every frame so releasing him drops him gently
      R.P.x, R.P.y, R.P.vx, R.P.vy = x, y, 0, 0
      return false
    end
    runHooks(R.hooks.sandboxMouseMove, x, y, dx, dy)
    return
  end
  if not R.active then return end
  pcall(R.pullNativeBrush, false)
  if R._brushTest then
    local req = R._brushTest; R._brushTest = nil
    R.brushShape = req.shape or "square"
    R.brush = req.r or 1
    local pushOk = pcall(R.pushNativeBrush)
    local pullOk = R.pullNativeBrush()
    R._brushTestOut = {
      pushOk = pushOk, pullOk = pullOk,
      shape = R.brushShape, r = R.brush, rx = R.brushRx, ry = R.brushRy,
      id = R._nativeBrushId, err = R._brushPullErr,
    }
  end
  R.mouse.x, R.mouse.y = x, y; runHooks(R.hooks.mousemove, x, y, dx, dy); R.fine = inZoom(x, y)
end
local SHIFTK = { [1073742049]=1, [1073742053]=1 }
local CTRLK  = { [1073742048]=1, [1073742052]=1 }
-- SDL2 arrow keycodes -- nudge the camera's follow offset in any direction
-- (see adjustCamOffsets); the camera still auto-follows the character the
-- whole time, just recentred around whatever offset these add.
local ARROWK = { [1073741906]="up", [1073741905]="down", [1073741904]="left", [1073741903]="right" }
local function keyName(key) if type(key) == "number" then if key == 9 then return "tab" elseif key == 32 then return "space" elseif key == 27 then return "escape" elseif key == 1073741882 then return "f1" elseif key >= 32 and key < 127 then return string.lower(string.char(key)) end end; return tostring(key) end
-- Native TPT brushes: 0=circle, 1=square, 2=triangle (GameView Tab = ChangeBrush).
-- The RPG used to ignore tpt.brushID and keep a private R.brushShape, so the
-- menu icon could change while in-game placement stayed a square.
local BRUSH_SHAPES = { "circle", "square", "triangle" }
local function syncBrushFromNative()
  local ok, id = pcall(function() return tpt.brushID() end)
  if ok and type(id) == "number" and id >= 0 and id <= 2 then
    R.brushShape = BRUSH_SHAPES[id + 1]
  end
  return R.brushShape or "square"
end
local function cycleBrushShape()
  local prev = R.brushShape or "square"
  R.pullNativeBrush()
  local cur = R._nativeBrushId
  if type(cur) ~= "number" then cur = BRUSH_ID[R.brushShape] or 1 end
  if cur < 0 or cur > 2 then cur = 0 end
  local nxt = (math.floor(cur) + 1) % 3
  R.brushShape = BRUSH_NAME[nxt] or "circle"
  if (R.brush or 0) == 0 then R.brush = 1 end
  R.pushNativeBrush()
  if R.brushShape ~= prev then say("brush shape: " .. R.brushShape) end
  return R.brushShape
end
-- Real text input (interface.grabTextInput + event.TEXTINPUT), not hand-rolled
-- shift/symbol tables off raw keycodes. The old approach only ever saw a
-- physical US-layout keypress, so anything that injects text a different way
-- -- OS dictation/speech-to-text, an IME, a non-US layout -- typed nothing
-- into the chat/feedback boxes even though the key event still fired. Text
-- input must be explicitly grabbed while a box is open (and dropped when it
-- closes) or TEXTINPUT events never fire at all.
local function grabText() pcall(interface.grabTextInput) end
local function releaseText() pcall(interface.dropTextInput) end
local function onTextInput(text)
  if R.titleScreen then
    if R.titleMultiplayerOpen and R.net and R.net.titleTextInput then pcall(R.net.titleTextInput, text) end
    return
  end
  -- Sandbox needs real text input for the bug/suggestion box and the stamp submission form.
  -- Checked before the `not R.active` guard below, because sandbox sets R.active = false and
  -- would otherwise never receive a single character -- the same class of mistake that made
  -- `return false` in the mouse handlers swallow every click when sandbox first shipped.
  if R.sandboxMode then
    if not text or text == "" then return end
    runHooks(R.hooks.sandboxTextInput, text)
    return
  end
  if not R.active or not text or text == "" then return end
  if R.feedbackOpen then if #R.feedbackText < 400 then R.feedbackText = R.feedbackText .. text end
  elseif R.chatOpen then if #R.chatText < 120 then R.chatText = R.chatText .. text end end
end
local function onKeyDown(key, scan, rep, shift, ctrl, alt)
  if R.tptMenusPending then R.applyPendingMenus() end
  -- Sandbox mode: the RPG is stopped, so every handler below is inert. Esc is the one
  -- key we still claim, as the way back to the menu -- checked BEFORE the title-screen
  -- and R.active guards, both of which would otherwise swallow it and leave the player
  -- with no route back to their save. Every other key falls straight through to stock
  -- Powder Toy, which is the entire point of the mode.
  if R.sandboxMode then
    R.sbMod = R.sbMod or {}
    R.sbMod.shift, R.sbMod.ctrl = shift, ctrl   -- tracked here because the mouse handlers get no modifier args
    R.sbCheckShape()   -- TAB and the shape hotkeys come through here
    -- Hooks get EVERY key first, including Esc. Previously Esc was intercepted here and went
    -- straight to exitSandbox, so pressing Esc to back out of the submit form instead threw
    -- you to the main menu -- and from there the only way back into sandbox cleared the
    -- simulation, destroying whatever you were building. Panels must be allowed to consume
    -- Esc first; only an Esc that nothing else wants leaves sandbox.
    if R.SB and R.SB.on then
      local kn = keyName(key)
      if ARROWK[key] then R.keys[ARROWK[key]] = true; return false end
      if kn == "a" or kn == "d" or kn == "w" or kn == "s" then R.keys[kn] = true; return false end
    end
    -- Letter-key shortcuts he already has muscle memory for. E is the inventory and he said
    -- plainly it was working well before; losing it to sandbox was a regression, not a cleanup.
    if not rep then
      local kn2 = keyName(key)
      if kn2 == "e" or kn2 == "i" then
        -- Route through the hook chain so ui.lua's real bag panel opens and DRAWS, rather than
        -- flipping a flag whose renderer never runs in sandbox. (I did exactly that a moment ago
        -- by calling a function that does not exist -- the same silent no-op I keep warning about.)
        runHooks(R.hooks.sandboxKey, 101, "e", false, false, false)
        return false
      end
    end
    if not rep and runHooks(R.hooks.sandboxKey, key, keyName(key), shift, ctrl, alt) then return false end
    if key == 1073741888 then R.sandboxWalk(); return false end   -- F7 still works, but the Character button is the real control
    if key == 27 then
      if R.sbBrush and R.sbBrush.active then R.sbBrush.active = false; return false end
      R.exitSandbox(); return false
    end
    return   -- nil = let every other key through to stock Powder Toy
  end
  if R.titleScreen then
    if key == 27 then
      if R.titleCreateOpen then R.titleCreateOpen = false; return false end
      if R.titleSettingsOpen then R.titleSettingsOpen = false; return false end
      if R.titleMultiplayerOpen then R.titleMultiplayerOpen = false; return false end
    end
    if R.titleMultiplayerOpen and R.net and R.net.titleKeyDown then pcall(R.net.titleKeyDown, key, shift, ctrl, alt) end
    return false
  end
  if not R.active then return end
  -- feedback text box (F8, or Esc menu) -- same shape as chat input below,
  -- separate state so the two can't collide.
  if R.feedbackOpen then
    if key == 13 or key == 271 or key == 1073741912 then
      local msg = R.feedbackText
      R.feedbackOpen = false; R.feedbackText = ""; releaseText()
      R.submitFeedback(msg)
      return false
    elseif key == 27 then R.feedbackOpen = false; R.feedbackText = ""; releaseText(); say("Feedback cancelled"); return false
    elseif key == 8 then R.feedbackText = R.feedbackText:sub(1, -2); return false
    elseif ctrl and key == 118 then   -- Ctrl+V: real OS clipboard, not dependent on TEXTINPUT delivering it
      local ok, text = pcall(platform.clipboardCopy); if ok and text then R.feedbackText = (R.feedbackText .. text):sub(1, 400) end; return false
    end
    return false
  end
  -- chat input swallows the keyboard while it is open
  if R.chatOpen then
    if key == 13 or key == 271 or key == 1073741912 then
      local msg = R.chatText
      R.chatOpen = false; R.chatText = ""; releaseText()
      if msg ~= "" then R.chatSay("You", msg); R.chatInbox[#R.chatInbox + 1] = msg; runHooks(R.hooks.chat, msg) end
      return false
    elseif key == 27 then R.chatOpen = false; R.chatText = ""; releaseText(); return false
    elseif key == 8 then R.chatText = R.chatText:sub(1, -2); return false
    elseif ctrl and key == 118 then
      local ok, text = pcall(platform.clipboardCopy); if ok and text then R.chatText = (R.chatText .. text):sub(1, 120) end; return false
    end
    return false
  end
  if key == 13 or key == 271 or key == 1073741912 then R.chatOpen = true; R.chatText = ""; R.keys = {}; grabText(); return false end
  if SHIFTK[key] then R.shiftHeld = true end
  if shift then R.shiftHeld = true end
  if R.shiftHeld and isPlaceableBlock(selected()) then pcall(R.pullNativeBrush, true) end
  if CTRLK[key] then R.ctrlHeld = true end
  if ctrl then R.ctrlHeld = true end
  local k = keyName(key)
  if not rep and runHooks(R.hooks.key, k, shift, ctrl, alt) then return false end
  if k == "a" or k == "d" or k == "w" or k == "s" then R.keys[k] = true; return false end
  -- space is left alone: it's TPT's native pause hotkey (hardcoded in GameView, not
  -- suppressible from Lua) and W is now the only jump key, so there's nothing left
  -- for the RPG to do with it -- let it fall through and just pause like normal.
  -- Ctrl+Up / Ctrl+Down = camera zoom. Must be checked BEFORE the plain-arrow
  -- branch below, or the same press would also nudge camYOffset and the view
  -- would zoom and pan at once. Plain arrows keep nudging exactly as before.
  if R.ctrlHeld and ARROWK[key] and (ARROWK[key] == "up" or ARROWK[key] == "down") then
    R.setCamZoom(ARROWK[key] == "up" and 0.5 or -0.5); return false
  end
  if ARROWK[key] then R.keys[ARROWK[key]] = true; return false end
  if rep then return end
  if k == "e" then R.invOpen = not R.invOpen; R.releaseMouse(); return false end
  if k == "escape" and R.changesPromptOpen then R.dismissLocalChangelog(); R.releaseMouse(); return false end
  if k == "escape" and R.updatePromptOpen then R.updatePromptOpen = false; R.releaseMouse(); return false end
  if k == "escape" then
    if R.invOpen then R.invOpen = false; R.releaseMouse()
    else R.setMenuOpen(not R.menuOpen) end
    return false
  end
  -- F7 toggles back out of sandbox walk mode. Checked here because while walking R.sandboxMode
  -- is false, so the sandbox key branch above is skipped entirely -- without this you could get
  -- into walk mode but never back to building.
  if R.sandboxWalking and key == 1073741888 then R.sandboxWalk(false); return false end
  if k == "m" then R.minimap = not R.minimap; return false end
  if k == "n" then R.enemies = not R.enemies; say(R.enemies and "Enemies ON" or "Enemies OFF"); return false end
  if k == "h" then R.hud = not R.hud; return false end
  if k == "k" then R.save(); return false end
  if k == "r" then R.spawnPlayer(); say("Respawned"); return false end
  if k == "f1" then R.debug = not R.debug; return false end
  if key == 1073741889 then R.feedbackOpen = true; R.feedbackText = ""; grabText(); return false end  -- F8: report bug/suggestion
  if key == 1073741890 then R.hotReloadRequested = true; return false end  -- F9: hot-reload rpg.lua from disk, no restart
  if key == 1073741892 then R.releaseMouse(true); return false end  -- F11: emergency unstuck for the mouse (see R.releaseMouse)
  if k == "u" and R.updateInfo then R.startUpdate(); return false end  -- U: install an available update
  if k == "x" and R.accOn("mirror") then local hp = R.hp; R.spawnPlayer(); R.hp = hp; say("Magic Mirror: home"); return false end
  if k == "g" and R.accOn("hook") then fireHook(R.mouse.x, R.mouse.y); return false end
  if k == "b" then R.grid = not R.grid; say(R.grid and "Snap grid ON: blocks fill 4px cells (B toggles)" or "Snap grid OFF"); return false end
  if k == "q" then      -- eyedropper: put the material under the cursor into the hotbar (works with any panel closed)
    local p = sim.partID(R.mouse.x, R.mouse.y)
    if p then local nm = nameOf(sim.partProperty(p, "type")); if nm == "BCOL" then nm = "COAL" end
      R.grantItem(nm)
    else R.hint = "point at a block to pick it" end
    return false end
  -- Falls through to native TPT (the favorites wheel) in sandbox/TPT-menu
  -- mode instead of eating T for the RPG's own smart-cursor toggle.
  if k == "t" and not R.tptMenus then R.smart = (R.smart == false); say(R.smart and "Smart cursor ON: digs the first block toward the mouse" or "Smart cursor OFF: digs exactly at the mouse"); return false end
  if k == "[" then
    R.pullNativeBrush()
    R.brush = math.max(0, (R.brush or 1) - 1)
    R.pushNativeBrush()
    say("place brush " .. (2 * (R.brush or 0) + 1) .. "px")
    return false
  end
  if k == "]" then
    R.pullNativeBrush()
    R.brush = math.min(BRUSH_R_MAX, (R.brush or 1) + 1)
    R.pushNativeBrush()
    say("place brush " .. (2 * (R.brush or 0) + 1) .. "px")
    return false
  end
  if k == "o" and isPlaceableBlock(selected()) then
    R.brushShell = not R.brushShell
    say(R.brushShell and "Brush shell ON — lines use hollow ring (thinner walls)" or "Brush shell OFF — full brush fill")
    return false
  end
  if k == "tab" or k == "v" then cycleBrushShape(); return false end
  local d = (#k == 1) and tonumber(k) or nil   -- single digits only: modifier keycodes are not slot numbers
  if d then R.sel = (d == 0) and 10 or d; return false end
  if k == "z" then R.zoomPending = not R.zoomPending; say(R.zoomPending and "Zoom: move to the spot, click to lock. Z again closes." or "Zoom closed"); return end
  return  -- anything else goes to TPT
end
local function onKeyUp(key, scan, rep, shift, ctrl, alt)
  if R.sandboxMode then
    R.sbMod = R.sbMod or {}; R.sbMod.shift, R.sbMod.ctrl = shift, ctrl
    if R.SB and R.SB.on then
      local kn = keyName(key)
      if ARROWK[key] then R.keys[ARROWK[key]] = false end
      if kn == "a" or kn == "d" or kn == "w" or kn == "s" then R.keys[kn] = false end
    end
    return
  end
  if not R.active then return end
  if SHIFTK[key] then R.shiftHeld = false; R.placeAnchor = nil; R.placeBox = false; R.placeRect = false; R.placeLine = false end
  if CTRLK[key] then R.ctrlHeld = false; R.placeAnchor = nil; R.placeBox = false; R.placeRect = false; R.placeLine = false end
  if ARROWK[key] then R.keys[ARROWK[key]] = false; return false end
  local k = keyName(key); runHooks(R.hooks.keyup, k); if R.keys[k] ~= nil then R.keys[k] = false; return false end end

-- ================================================================ UI
-- Lua 5.1 main-chunk local cap (200): panel/hotbar/menu helpers scoped here.
local PANEL, invNames, craftRows, onWheel, drawHotbar, drawMinimap, drawPanel, drawMenu, wrap
do
local CELL = 30
-- Settings column row height (SET_BTN_H + SET_ROW_GAP); wheel step uses MENU_WHEEL_ROWS.
-- settings row height 28, wheel step 3 rows (inlined below)
PANEL = { x=70, y=44, w=472, h=290 }
invNames = function() local names = {}; for k, v in pairs(R.inventory or {}) do if v > 0 then names[#names+1] = k end end; table.sort(names); return names end
craftRows = function()
  local rows = {}
  -- Same bug as ui.lua's buildCraftRows (fixed round 6): never included "research"/
  -- "advlab", so recipes gated on either tier were unreachable through this panel too.
  local order = { "hand", "workbench", "furnace", "anvil", "research", "advlab" }
  for _, stk in ipairs(order) do
    local okst, why = R.nearStation(stk)
    rows[#rows+1] = { header = (R.STATIONS[stk] or stk):upper() .. (okst and "" or ("   (" .. (why or "not here") .. ")")), okst = okst }
    for k, rc in ipairs(R.RECIPES) do if (rc.st or "hand") == stk then
      local avail = R.ITEMS[rc.out] or has(rc.out)
      rows[#rows+1] = { label = rc.n .. " " .. rc.txt, need = rc.need, ok = avail and okst and canAfford(rc.need), dim = not okst, desc = rc.desc, fn = function() R.craft(k) end } end end
    for k, t in ipairs(R.PICKS) do if (t.st or "hand") == stk then rows[#rows+1] = { label = t.name, need = t.need, ok = okst and canAfford(t.need), dim = not okst, desc = t.desc, fn = function() R.craftPick(k) end, have = (R.TOOLS.pick.name == t.name) } end end
    for k, t in ipairs(R.SWORDS) do if (t.st or "hand") == stk then rows[#rows+1] = { label = t.name, need = t.need, ok = okst and canAfford(t.need), dim = not okst, desc = t.desc, fn = function() R.craftSword(k) end, have = (R.TOOLS.sword.name == t.name) } end end
  end
  return rows
end
R.craftScroll = R.craftScroll or 0
function R.uiClick(x, y, button)
  local gx, gy = PANEL.x + 10, PANEL.y + 42
  if x >= gx and x < gx + 6*CELL and y >= gy and y < gy + 5*CELL then
    local col, row = floor((x - gx) / CELL), floor((y - gy) / CELL); local names = invNames(); local el = names[row*6 + col + 1]
    if el then local slot = (R.sel and R.sel >= 6) and R.sel or 6
      for s = 6, 10 do if R.hotbar[s] == el then slot = s end end
      R.hotbar[slot] = el; R.sel = slot; say(nice(el) .. " is now in slot " .. (slot % 10) .. " - hold right mouse to place it") end
    return
  end
  local cx0, cy0 = PANEL.x + 200, PANEL.y + 42
  if x >= cx0 and x < PANEL.x + PANEL.w - 8 and y >= cy0 then
    local row = floor((y - cy0) / 14) + 1 + R.craftScroll; local rows = craftRows(); local r = rows[row]; if r and r.fn then r.fn() end
  end
end
onWheel = function(x, y, d) if not R.active then return end
  if R.changesPromptOpen then R.changesScroll = math.max(0, (R.changesScroll or 0) - d); return false end
  if R.updatePromptOpen then R.updateScroll = math.max(0, (R.updateScroll or 0) - d); return false end
  if R.menuOpen then
    local maxS = R._menuMaxScroll or 0
    local step = 28 * 3
    R.settingsScroll = math.max(0, math.min(maxS, (R.settingsScroll or 0) - d * step))
    return false
  end
  if runHooks(R.hooks.wheel, x, y, d) then return false end
  -- Same decouple as mouse/keys: sandbox/TPT-menu mode hands the wheel
  -- entirely to native TPT (its own brush-size scroll) instead of it
  -- selecting an RPG hotbar slot underneath whatever element you picked.
  if R.tptMenus then return end
  -- Shift + wheel resizes the block you are placing (1,3,5,7,9 px, or 1..5 grid cells with snap on)
  if R.ctrlHeld then
    local sizes = { 2, 4, 8, 16 }; local cur = 2
    for i, v in ipairs(sizes) do if v == (R.gridSize or 4) then cur = i end end
    R.gridSize = sizes[math.max(1, math.min(#sizes, cur + (d > 0 and 1 or -1)))]
    R.hint = "snap grid " .. R.gridSize .. "px cells"
    return false
  end
  if R.shiftHeld then
    R.brush = math.max(0, math.min(BRUSH_R_MAX, (R.brush or 1) + (d > 0 and 1 or -1)))
    R.pushNativeBrush()
    R.hint = "block size " .. (R.grid and ((R.brush + 1) .. " cell" .. (R.brush > 0 and "s" or "")) or ((2 * R.brush + 1) .. "px"))
    return false
  end
  if R.zoomPending then return end  -- wheel resizes the TPT zoom window while placing it
  -- F15: bare wheel used to swap hotbar slots, but the user wants the wheel
  -- to resize the brush ("I want to be able to scroll my thing down completely"
  -- -- tried the wheel, got hotbar switching, gave up). Route bare wheel to
  -- brush-size ONLY when a build-block (not tool, not item-kit) is selected
  -- AND the cursor isn't inside the zoom window AND no panel is open. Hotbar
  -- slot swap still works in all other cases (tool selected, item-kit selected,
  -- cursor in zoom, panel open, etc) so no existing binding is lost.
  local cur = selected()
  if cur and not cur:find("^tool:") and not R.ITEMS[cur] and not R.invOpen and not R.menuOpen and not R.uiPanelOpen then
    R.brush = math.max(0, math.min(BRUSH_R_MAX, (R.brush or 1) + (d > 0 and 1 or -1)))
    R.pushNativeBrush()
    R.hint = "block size " .. (R.grid and ((R.brush + 1) .. " cell" .. (R.brush > 0 and "s" or "")) or ((2 * R.brush + 1) .. "px"))
    return false
  end
  if inZoom(x, y) then
    R.brush = math.max(0, math.min(BRUSH_R_MAX, (R.brush or 1) + (d > 0 and 1 or -1)))
    R.pushNativeBrush()
    R.hint = "brush " .. (2*R.brush+1) .. "px"; return false
  end
  if R.invOpen then R.craftScroll = math.max(0, math.min(math.max(0, #craftRows() - 8), R.craftScroll - d)); return false end
  R.sel = ((R.sel or 1) - 1 - (d > 0 and 1 or -1)) % 10 + 1; return false end
drawHotbar = function()
  R.rebuildHotbar()
  local SLOT, GAP = 30, 3
  local total = 10 * SLOT + 9 * GAP
  local x0 = floor((W - total) / 2)
  local y0 = H - SLOT - 8
  graphics.fillRect(x0 - 5, y0 - 5, total + 10, SLOT + 10, 8, 9, 16, 205)      -- tray
  graphics.drawRect(x0 - 5, y0 - 5, total + 10, SLOT + 10, 70, 74, 100, 255)
  for slot = 1, 10 do
    local x = x0 + (slot - 1) * (SLOT + GAP); local sel = (slot == (R.sel or 1))
    local v = R.hotbar[slot]
    graphics.fillRect(x, y0, SLOT, SLOT, sel and 40 or 22, sel and 42 or 24, sel and 62 or 34, 255)
    graphics.drawRect(x, y0, SLOT, SLOT, sel and 255 or 92, sel and 220 or 96, sel and 90 or 120, 255)
    if sel then graphics.drawRect(x - 2, y0 - 2, SLOT + 4, SLOT + 4, 255, 220, 90, 190) end
    graphics.drawText(x + 2, y0 + 2, tostring(slot % 10), sel and 255 or 120, sel and 220 or 124, sel and 90 or 140, 255)
    if v and v:find("^tool:") then
      local key = v:sub(6); local col = TOOLCOL[key] or {200,200,200}
      local cx, cy = x + SLOT/2, y0 + SLOT/2 + 2
      if key == "pick" then graphics.fillRect(cx - 1, cy - 5, 2, 11, 150, 100, 50, 255); graphics.fillRect(cx - 6, cy - 7, 13, 2, col[1], col[2], col[3], 255); graphics.fillRect(cx - 7, cy - 6, 2, 2, col[1], col[2], col[3], 255); graphics.fillRect(cx + 6, cy - 6, 2, 2, col[1], col[2], col[3], 255)
      elseif key == "axe" then graphics.fillRect(cx - 1, cy - 5, 2, 11, 150, 100, 50, 255); graphics.fillRect(cx - 6, cy - 7, 6, 5, col[1], col[2], col[3], 255)
      elseif key == "sword" then graphics.fillRect(cx - 1, cy - 8, 2, 11, col[1], col[2], col[3], 255); graphics.fillRect(cx - 4, cy + 2, 8, 2, 140, 100, 60, 255); graphics.fillRect(cx - 1, cy + 4, 2, 3, 140, 100, 60, 255)
      elseif key == "torch" then graphics.fillRect(cx - 1, cy - 2, 2, 8, 150, 100, 50, 255); graphics.fillCircle(cx, cy - 5, 3, 4, 255, 190, 60, 255)
      else graphics.fillRect(cx - 4, cy - 4, 8, 9, col[1], col[2], col[3], 255); graphics.fillRect(cx - 5, cy - 6, 10, 2, col[1], col[2], col[3], 255) end
    elseif v then
      local r, g, b = colourOf(v); local a = inv(v) > 0 and 255 or 70
      graphics.fillRect(x + 7, y0 + 6, 16, 16, r, g, b, a); graphics.drawRect(x + 7, y0 + 6, 16, 16, 0, 0, 0, math.min(a, 140))
      local n = inv(v); local txt = n > 999 and "999+" or tostring(n)
      graphics.fillRect(x + SLOT - 4 - #txt * 6, y0 + SLOT - 10, #txt * 6 + 3, 9, 0, 0, 0, 190)
      graphics.drawText(x + SLOT - 2 - #txt * 6, y0 + SLOT - 9, txt, 255, 255, 255, a)
    end
  end
  -- one clean label above the tray for the selected slot
  local s = selected(); local label, sub
  if s and s:find("^tool:") then local t = R.TOOLS[s:sub(6)]
    label = (t and t.name or s); sub = ({pick="hold LEFT mouse to dig", axe="hold LEFT mouse to chop", sword="LEFT mouse to swing", torch="LEFT click to light coal or place a light", bucket="LEFT click water to scoop, again to pour"})[s:sub(6)]
  elseif s then label = nice(s) .. "  x" .. inv(s); sub = "Ctrl-drag circle/box   Shift-drag line   O shell   Tab/V shape   wheel size"
  else label = "empty slot"; sub = "put blocks in slots 6-0 from your bag (E)" end
  local w1 = #label * 6; local w2 = #sub * 6
  graphics.fillRect(floor((W - w1) / 2) - 4, y0 - 22, w1 + 8, 11, 0, 0, 0, 170)
  graphics.drawText(floor((W - w1) / 2), y0 - 21, label, 255, 230, 150, 255)
  graphics.drawText(floor((W - w2) / 2), y0 - 33, sub, 190, 200, 215, 200)
end
drawMinimap = function()
  local mx, my = W - 110, 4; local sz = 2
  local halfW, halfH = 25, 15
  local fw, fh = halfW * sz * 2, halfH * sz * 2
  graphics.fillRect(mx - 2, my - 2, fw + 4, fh + 18, 0, 0, 0, 170)
  graphics.drawText(mx + halfW * sz - 4, my - 1, "N", 160, 160, 170, 200)
  local ctx, cty = floor(R.P.x / TS), floor(R.P.y / TS)
  local ox, oy = mx + halfW * sz, my + halfH * sz
  local tileN = 0
  for _, t in pairs(R.tiles) do
    if t.sx1 then
      tileN = tileN + 1
      local dx, dy = t.tx - ctx, t.ty - cty
      if dx >= -halfW and dx <= halfW and dy >= -halfH and dy <= halfH then
        local wx, wy = t.tx * TS, t.ty * TS + TS / 2
        local surf = surfaceAt(wx)
        local r, g, b
        if wy < surf - 8 then r, g, b = 90, 140, 220
        elseif wy > 1450 then r, g, b = 200, 80, 40
        else
          local bname = biomeAt(wx)
          if bname == "desert" then r, g, b = 210, 180, 120
          elseif bname == "snow" then r, g, b = 200, 220, 255
          elseif bname == "swamp" then r, g, b = 80, 120, 70
          else r, g, b = 100, 150, 90 end
        end
        if t.recs then
          for _, rec in pairs(t.recs) do
            if rec and rec[1] and rec[1] ~= 0 then
              local el = nameOf(rec[1])
              if el == "WOOD" or el == "COAL" then r, g, b = 140, 100, 60
              elseif el == "WATR" or el == "DSTW" then r, g, b = 60, 120, 220
              elseif el == "LAVA" or el == "FIRE" then r, g, b = 255, 120, 40 end
              break
            end
          end
        end
        graphics.fillRect(mx + (dx + halfW) * sz, my + (dy + halfH) * sz, sz, sz, r, g, b, 255)
      end
    end
  end
  graphics.fillRect(ox, oy - 4, 2, 2, 255, 255, 255, 255)
  graphics.fillRect(ox - 1, oy - 2, 4, 2, 255, 255, 255, 255)
  graphics.fillRect(ox - 2, oy, 6, 2, 255, 255, 255, 255)
  graphics.drawText(mx, my + fh + 4, string.format("x=%d z=%d  %d tiles", floor(R.P.x / 4), floor(R.P.y / 4), tileN), 160, 170, 190, 180)
  graphics.fillRect(mx + fw - 28, my + fh + 4, 4, 4, 90, 140, 220, 200)
  graphics.fillRect(mx + fw - 20, my + fh + 4, 4, 4, 100, 150, 90, 200)
  graphics.fillRect(mx + fw - 12, my + fh + 4, 4, 4, 200, 80, 40, 200)
end
drawPanel = function()
  graphics.fillRect(PANEL.x, PANEL.y, PANEL.w, PANEL.h, 14, 16, 32, 242); graphics.drawRect(PANEL.x, PANEL.y, PANEL.w, PANEL.h, 255, 220, 80, 255)
  graphics.fillRect(PANEL.x, PANEL.y, PANEL.w, 18, 40, 44, 80, 255)
  graphics.drawText(PANEL.x+8, PANEL.y+5, "BAG", 255, 220, 80, 255); graphics.drawText(PANEL.x+40, PANEL.y+5, "click an item to put it in a block slot  |  E / Esc closes", 190, 190, 200, 255)
  local gx, gy = PANEL.x + 10, PANEL.y + 42
  graphics.drawText(gx, PANEL.y + 26, "ITEMS", 255, 220, 80, 255)
  local names = invNames(); local hover
  for i = 0, 29 do local col, row = i % 6, floor(i / 6); local x, y = gx + col*CELL, gy + row*CELL
    graphics.fillRect(x, y, CELL-2, CELL-2, 30, 34, 60, 255); graphics.drawRect(x, y, CELL-2, CELL-2, 70, 74, 110, 255)
    local el = names[i+1]
    if el then local r, g, b = colourOf(el); graphics.fillRect(x+3, y+3, 10, 10, r, g, b, 255); graphics.drawText(x+15, y+3, string.sub(nice(el), 1, 3), 200, 200, 210, 255); graphics.drawText(x+3, y+16, tostring(inv(el)), 255, 255, 255, 255)
      local inbar; for s = 6, 10 do if R.hotbar[s] == el then inbar = s end end; if inbar then graphics.drawRect(x, y, CELL-2, CELL-2, 255, 220, 80, 255); graphics.drawText(x+21, y+16, tostring(inbar % 10), 255, 220, 80, 255) end
      if R.mouse.x >= x and R.mouse.x < x+CELL and R.mouse.y >= y and R.mouse.y < y+CELL then hover = el end end end
  graphics.drawText(gx, gy + 5*CELL + 6, "TOOLS: 1 " .. R.TOOLS.pick.name .. "   3 " .. R.TOOLS.sword.name, 200, 200, 200, 255)
  local accs = {}; for _, k in ipairs(R.ACC_ORDER) do if R.acc[k] then accs[#accs+1] = R.ACCS[k].name end end
  graphics.drawText(gx, gy + 5*CELL + 18, "ITEMS: " .. (#accs > 0 and table.concat(accs, ", ") or "none yet - find chests in caves"), 255, 220, 140, 255)
  graphics.drawText(gx, gy + 5*CELL + 30, "Deaths " .. (R.deaths or 0) .. "   Day " .. (R.day or 1), 160, 160, 170, 255)
  local cx0, cy0 = PANEL.x + 200, PANEL.y + 42
  graphics.drawText(cx0, PANEL.y + 26, "CRAFT  (click a green row; wheel scrolls)", 255, 220, 80, 255)
  -- Every row shows its own description underneath it, always -- no more
  -- relying on hovering exactly one row at a time to see what anything
  -- does (that also doubled as an unwanted hover popup). Costs vertical
  -- space (rowH 14 -> 22, fewer rows fit before scrolling), which is the
  -- right trade: legible information beats fitting more blank-looking rows.
  local rowH = 22
  local rows = craftRows(); local maxRows = floor((PANEL.h - 68) / rowH)
  for i = 1, maxRows do local r = rows[i + R.craftScroll]; if not r then break end
    local y = cy0 + (i-1)*rowH
    if r.header then graphics.fillRect(cx0 - 2, y - 1, PANEL.w - 208, 13, 40, 44, 80, 255); graphics.drawText(cx0, y + 1, r.header, r.okst and 255 or 170, r.okst and 220 or 170, r.okst and 80 or 170, 255)
    else
      local need = {}; for el, n in pairs(r.need) do need[#need+1] = n .. " " .. nice(el) .. (inv(el) < n and ("(" .. inv(el) .. ")") or "") end; table.sort(need)
      local hov = R.mouse.x >= cx0 and R.mouse.x < PANEL.x + PANEL.w - 8 and R.mouse.y >= y and R.mouse.y < y + rowH
      if hov then graphics.fillRect(cx0 - 2, y - 1, PANEL.w - 208, rowH, 60, 64, 100, 255) end
      local cr, cg, cb = 150, 150, 150; if r.ok then cr, cg, cb = 140, 255, 140 elseif r.dim then cr, cg, cb = 100, 100, 110 end; if r.have then cr, cg, cb = 255, 220, 80 end
      graphics.drawText(cx0, y + 1, (r.have and "* " or "") .. r.label, cr, cg, cb, 255); graphics.drawText(cx0 + 104, y + 1, table.concat(need, ", "), r.ok and 200 or 120, r.ok and 200 or 120, r.ok and 200 or 120, 255)
      if r.desc then graphics.drawText(cx0 + 2, y + 11, string.sub(r.desc, 1, 72), 160, 165, 185, 255) end
    end
  end
  if #rows - maxRows > 0 then graphics.drawText(PANEL.x + PANEL.w - 60, PANEL.y + 26, "wheel: more", 150, 150, 160, 255) end
  if hover then graphics.fillRect(PANEL.x+8, PANEL.y+PANEL.h-30, 180, 24, 0, 0, 0, 230); graphics.drawText(PANEL.x+12, PANEL.y+PANEL.h-26, nice(hover) .. ": " .. string.sub(descOf(hover), 1, 40), 255, 255, 255, 255) end
end
-- Esc menu: grouped settings with inline status (v1.15.31), inside UI do/end scope.
-- drawMenu forward-declared at top of this do/end (with PANEL, drawHotbar, etc.) — do NOT re-local here.
wrap = function(text, width)                -- 6px per character (shared with changelog dialogs)
  local maxc = math.max(1, floor(width / 6)); local out, line = {}, ""
  local function flush() if line ~= "" then out[#out + 1] = line; line = "" end end
  for word in text:gmatch("%S+") do
    while #word > maxc do flush(); out[#out + 1] = word:sub(1, maxc); word = word:sub(maxc + 1) end
    if line == "" then line = word
    elseif #line + 1 + #word > maxc then flush(); line = word
    else line = line .. " " .. word end
  end
  flush()
  return out
end
-- 8 = conservative drawText width for menu columns. Inlined rather than a top-level
-- local (see DEVELOPMENT.md's 200-locals limit); R.MENU_CHAR_W below is the shared copy.
local function menuWrap(text, widthPx)
  local maxc = math.max(1, floor((widthPx - 4) / 8))
  local out, line = {}, ""
  local function flush() if line ~= "" then out[#out + 1] = line; line = "" end end
  for word in tostring(text):gmatch("%S+") do
    while #word > maxc do flush(); out[#out + 1] = word:sub(1, maxc); word = word:sub(maxc + 1) end
    if line == "" then line = word
    elseif #line + 1 + #word > maxc then flush(); line = word
    else line = line .. " " .. word end
  end
  flush()
  return out
end

-- Reachable from onDraw via the R table. Referencing the bare `menuWrap` local from
-- inside onDraw resolves as a GLOBAL and is nil at runtime -- the exact failure mode
-- DEVELOPMENT.md records for `wrap` (v1.15.35) and `drawMenu` (v1.15.33). Because onDraw is
-- not pcall-wrapped, that error aborts the entire remaining HUD every frame while
-- lastErr stays nil, so the bridge cannot see it. Draw code must use R.menuWrap.
R.menuWrap = menuWrap
R.MENU_CHAR_W = 8
local MENU_DAY_PRESETS = { 0.5, 0.65, 0.8 }
local MENU_DAY_LABELS = { "Shorter", "Normal", "Longer" }
local function menuPresetStatus(val, presets, labels, suffix)
  for i, v in ipairs(presets) do
    if math.abs(v - (val or presets[2])) < 0.01 then
      return labels[i] .. (suffix or "")
    end
  end
  return string.format("%.1fx", val or 1.0) .. (suffix or "")
end
local function menuOnOff(v) return v and "ON" or "OFF" end
local function menuItem(label, fn, status, active)
  return { label = label, fn = fn, status = status, active = active }
end
R.MENU_SECTIONS = {
  { items = {
      menuItem("Resume", function() R.setMenuOpen(false) end),
      menuItem("Quit to menu", function() R.setMenuOpen(false); R.active = false; R.titleScreen = true end),
      menuItem("Save game (K)", function() R.save() end),
    } },
  { header = "Gameplay", items = {
      menuItem("Enemies (N)", function() R.enemies = not R.enemies end,
        function() return menuOnOff(R.enemies) end, function() return R.enemies end),
      menuItem("Controls on join", function() R.tipsOn = not R.tipsOn; say("Controls-on-join " .. menuOnOff(R.tipsOn)) end,
        function() return menuOnOff(R.tipsOn) end, function() return R.tipsOn end),
      menuItem("Smart cursor (T)", function() R.smart = (R.smart == false) end,
        function() return menuOnOff(R.smart ~= false) end, function() return R.smart ~= false end),
      menuItem("Snap grid (B)", function() R.grid = not R.grid end,
        function() return menuOnOff(R.grid) end, function() return R.grid end),
      menuItem("Fast physics", function() R.setFast(not R.fast); say(R.fast and "Fast mode: air simulation off" or "Full physics: air/pressure on") end,
        function() return menuOnOff(R.fast) end, function() return R.fast end),
      menuItem("Sandbox mode", function() R.toggleSandbox() end,
        function() return menuOnOff(R.sandbox) end, function() return R.sandbox end),
      menuItem("Enemy difficulty", function()
          local presets = { 0.7, 1.0, 1.4 }; local cur = R.difficultyMul or 1.0; local idx = 1
          for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
          R.difficultyMul = presets[(idx % #presets) + 1]
          say(string.format("Enemy difficulty: %.1fx (new spawns)", R.difficultyMul))
        end,
        function() return menuPresetStatus(R.difficultyMul, { 0.7, 1.0, 1.4 }, { "Easy", "Normal", "Hard" }, " (new spawns)") end),
      menuItem("Jump height", function()
          local presets, labels = { 0.75, 1.0, 1.3 }, { "Low", "Normal", "High" }
          local cur = R.jumpMul or 1.0; local idx = 1
          for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
          R.jumpMul = presets[(idx % #presets) + 1]
          say(string.format("Jump height: %.1fx", R.jumpMul))
        end,
        function() return menuPresetStatus(R.jumpMul, { 0.75, 1.0, 1.3 }, { "Low", "Normal", "High" }) end),
      menuItem("Move speed", function()
          local presets = { 0.75, 1.0, 1.3 }; local cur = R.runMul or 1.0; local idx = 1
          for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
          R.runMul = presets[(idx % #presets) + 1]
          say(string.format("Move speed: %.1fx", R.runMul))
        end,
        function() return menuPresetStatus(R.runMul, { 0.75, 1.0, 1.3 }, { "Slow", "Normal", "Fast" }) end),
      menuItem("Gravity", function()
          local presets = { 0.7, 1.0, 1.4 }; local cur = R.gravMul or 1.0; local idx = 1
          for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
          R.gravMul = presets[(idx % #presets) + 1]
          say(string.format("Gravity: %.1fx", R.gravMul))
        end,
        function() return menuPresetStatus(R.gravMul, { 0.7, 1.0, 1.4 }, { "Light", "Normal", "Heavy" }) end),
    } },
  { header = "Graphics", items = {
      menuItem("HUD (H)", function() R.hud = not R.hud end,
        function() return menuOnOff(R.hud) end, function() return R.hud end),
      menuItem("Minimap (M)", function() R.minimap = not R.minimap end,
        function() return menuOnOff(R.minimap) end, function() return R.minimap end),
      menuItem("Visual effects", function() R.setFX(not R.fxOn); say(R.fxOn and "Effects ON" or "Effects OFF") end,
        function() return menuOnOff(R.fxOn) end, function() return R.fxOn end),
      menuItem("TPT element menu", function() R.toggleTptMenus() end,
        function() return menuOnOff(R.tptMenus) end, function() return R.tptMenus end),
    } },
  { header = "World", items = {
      menuItem("Map type", function() R.cycleMapType() end,
        function() return (MAP_TYPE_LABEL[R.mapType] or R.mapType or "Mixed") .. " (new terrain)" end),
      menuItem("Day length", function()
          local presets = MENU_DAY_PRESETS; local cur = R.dayFrac or 0.65; local idx = 1
          for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
          R.dayFrac = presets[(idx % #presets) + 1]
          say(string.format("Day length: %d%% of the cycle", math.floor(R.dayFrac * 100)))
        end,
        function() return menuPresetStatus(R.dayFrac, MENU_DAY_PRESETS, MENU_DAY_LABELS) end),
      menuItem("Cave frequency", function()
          local presets = { 0.5, 1.0, 1.8 }; local cur = R.caveFreqMul or 1.0; local idx = 1
          for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
          R.caveFreqMul = presets[(idx % #presets) + 1]
          say(string.format("Cave frequency: %.1fx (new terrain)", R.caveFreqMul))
        end,
        function() return menuPresetStatus(R.caveFreqMul, { 0.5, 1.0, 1.8 }, { "Sparse", "Normal", "Dense" }, " (new terrain)") end),
      menuItem("Ore rarity", function()
          local presets = { 0.7, 1.0, 1.4 }; local cur = R.oreRarityMul or 1.0; local idx = 1
          for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
          R.oreRarityMul = presets[(idx % #presets) + 1]
          say(string.format("Ore rarity: %.1fx (new terrain)", R.oreRarityMul))
        end,
        function() return menuPresetStatus(R.oreRarityMul, { 0.7, 1.0, 1.4 }, { "Common", "Normal", "Rare" }, " (new terrain)") end),
      menuItem("Tree spacing", function()
          local presets = { 0.7, 1.0, 1.4 }; local cur = R.treeSpacingMul or 1.0; local idx = 1
          for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
          R.treeSpacingMul = presets[(idx % #presets) + 1]
          say(string.format("Tree spacing: %.1fx (new terrain)", R.treeSpacingMul))
        end,
        function() return menuPresetStatus(R.treeSpacingMul, { 0.7, 1.0, 1.4 }, { "Dense", "Normal", "Sparse" }, " (new terrain)") end),
    } },
  { header = "Tools", items = {
      menuItem("Respawn at surface (R)", function() R.spawnPlayer(); R.setMenuOpen(false) end,
        function() return string.format("Day %d", R.day or 1) end),
      menuItem("New world...", function() R.setMenuOpen(false); R.active = false; R.titleScreen = true; R.titleCreateOpen = true; R.titleSettingsOpen = false end,
        function() return MAP_TYPE_LABEL[R.mapType or "mixed"] or "Mixed" end),
    } },
  { header = "Meta", items = {
      menuItem("Report bug / suggestion (F8)", function() R.setMenuOpen(false); R.feedbackOpen = true; R.feedbackText = ""; grabText() end),
      menuItem("Check for update now", function() R.setMenuOpen(false); if R.updateInfo then R.startUpdate() else R.checkForUpdate(); say("Checking for an update...") end end),
      menuItem("View full changelog", function() R.setMenuOpen(false); R.openFullChangelog() end),
    } },
}
R.MENU = {}
for _, sec in ipairs(R.MENU_SECTIONS) do
  for _, it in ipairs(sec.items) do
    R.MENU[#R.MENU + 1] = { it.label, it.fn, it.status, it.active }
  end
end
-- (a dead `local HELP` controls table lived here; nothing referenced it -- the Esc
-- menu builds its own CONTROLS column. Removed to reclaim a top-level local slot,
-- see DEVELOPMENT.md's 200-locals limit note.)
local MX, MY, MW, MH = 8, 18, 596, 340          -- inside R.SAFE
local MENU_DIV_X = MX + floor(MW * 0.50)        -- 50/50 split; controls use one full-width column
local CTRL_X, CTRL_W = MX + 10, MENU_DIV_X - MX - 18
local SET_X, SET_W = MENU_DIV_X + 8, MX + MW - (MENU_DIV_X + 8) - 10
local CTRL_TOP, SET_TOP = MY + 22, MY + 22
local SET_BOTTOM = MY + MH - 10
-- STATUS footer height 54 = STATUS box (42) + GOAL line above (inlined below)
local SET_BTN_H, SET_ROW_GAP = 26, 2
-- section header height 13, section gap 5 (inlined below)
R.settingsScroll = R.settingsScroll or 0
local function layoutMenuSettings()
  local rows, y = {}, SET_TOP + 14
  for _, sec in ipairs(R.MENU_SECTIONS) do
    if sec.header then rows[#rows + 1] = { kind = "header", y = y, h = 13, text = sec.header }; y = y + 13 end
    for _, item in ipairs(sec.items) do
      rows[#rows + 1] = { kind = "btn", y = y, h = SET_BTN_H, item = item }
      y = y + SET_BTN_H + SET_ROW_GAP
    end
    y = y + 5
  end
  local totalH = y - (SET_TOP + 14)
  local visibleH = SET_BOTTOM - (SET_TOP + 14) - 54
  local maxScroll = math.max(0, totalH - visibleH)
  R._menuMaxScroll = maxScroll
  R.settingsScroll = math.max(0, math.min(maxScroll, R.settingsScroll or 0))
  return rows, maxScroll, visibleH
end
local function menuBtnAt(x, y)
  local rows, _, visibleH = layoutMenuSettings()
  local scroll = R.settingsScroll or 0
  for _, row in ipairs(rows) do
    if row.kind == "btn" then
      local by = row.y - scroll
      -- fully-inside test, matching drawMenu's clip: a partially-clipped row is not
      -- drawn, so it must not be clickable either (else you hit an invisible button).
      if by >= SET_TOP + 14 and by + row.h <= SET_TOP + 14 + visibleH then
        if x >= SET_X and x <= SET_X + SET_W and y >= by and y < by + row.h then return row.item end
      end
    end
  end
end
function R.menuClick(x, y)
  local item = menuBtnAt(x, y)
  if item then item.fn(); return end
end
drawMenu = function()
  graphics.fillRect(0, 0, W, H, 0, 0, 0, 130)
  graphics.fillRect(MX, MY, MW, MH, 12, 14, 30, 246); graphics.drawRect(MX, MY, MW, MH, 255, 220, 80, 255)
  graphics.fillRect(MX, MY, MW, 16, 40, 44, 80, 255)
  graphics.drawText(MX + 8, MY + 4, "POWDER RPG - MENU & CONTROLS", 255, 220, 80, 255)
  graphics.drawText(MX + MW - 96, MY + 4, "Esc closes", 190, 190, 200, 255)
  graphics.fillRect(MENU_DIV_X, MY + 18, 1, MH - 18, 70, 74, 100, 255)
  -- left column: one wide label | description table (two skinny sub-columns wrapped every ~9 chars)
  local CTRL_LABEL_W = 52
  local CTRL_DESC_W = CTRL_W - CTRL_LABEL_W - 4
  local CTRL_BOTTOM = MY + MH - 4
  local CTRL_ROWS = {
    {"MOVE", "A/D run · W jump · S fall/drop · Space pause"},
    {"TOOLS", "1-5 pick/axe/sword/torch/bucket · hold LMB"},
    {"BLOCKS", "6-0 place mats · Q pick under cursor · Shift = native brush · Ctrl-drag size · O shell"},
    {"HOTBAR", "1-0 or mouse wheel"},
    {"BAG", "E inventory & craft · L or GUIDE = database"},
    {"VIEW", "Z zoom (click lock) · M minimap · build precise inside zoom"},
    {"TALK", "Enter colonist chat · Esc cancel"},
    {"ITEMS", "Middle-click grapple · X mirror home · chest accessories"},
    {"WORLD", "Dig anywhere (scrolls) · half-chop trunk to fell tree"},
  }
  graphics.drawText(CTRL_X, MY + 22, "CONTROLS", 255, 220, 80, 255)
  local cy = CTRL_TOP + 12
  for _, e in ipairs(CTRL_ROWS) do
    if cy > CTRL_BOTTOM then break end
    graphics.drawText(CTRL_X, cy, e[1], 255, 220, 80, 255)
    local ly = cy
    for _, ln in ipairs(menuWrap(e[2], CTRL_DESC_W)) do
      if ly + 10 > CTRL_BOTTOM then break end
      graphics.drawText(CTRL_X + CTRL_LABEL_W, ly, ln, 215, 215, 225, 255)
      ly = ly + 10
    end
    cy = math.max(cy + 10, ly) + 3
  end
  -- right column: grouped settings with status sublabels
  local rows, maxScroll, visibleH = layoutMenuSettings()
  local scroll = R.settingsScroll or 0
  graphics.drawText(SET_X, SET_TOP, "SETTINGS" .. (maxScroll > 0 and ("   wheel (" .. scroll .. "/" .. maxScroll .. ")") or ""), 255, 220, 80, 255)
  graphics.fillRect(SET_X, SET_TOP + 12, SET_W, 1, 70, 74, 100, 255)
  local clipTop, clipBot = SET_TOP + 14, SET_TOP + 14 + visibleH
  for _, row in ipairs(rows) do
    local ry = row.y - scroll
    -- v1.15.40 moved STATUS/GOAL into this column but left the old partial-overlap
    -- clip test, so a row straddling clipBot still drew its full 26px height -- up to
    -- 18px past the clip, straight through the GOAL line and into the STATUS box.
    -- Draw only rows entirely inside the clip; no row becomes unreachable because the
    -- 84px wheel step still lands every row fully in view at some scroll offset.
    if ry >= clipTop and ry + row.h <= clipBot then
      if row.kind == "header" then
        graphics.fillRect(SET_X, ry, SET_W, row.h, 34, 38, 62, 255)
        graphics.drawText(SET_X + 6, ry + 2, menuWrap(row.text, SET_W - 12)[1] or row.text, 255, 220, 80, 255)
      elseif row.kind == "btn" then
        local it = row.item
        local hov = R.mouse.x >= SET_X and R.mouse.x <= SET_X + SET_W and R.mouse.y >= ry and R.mouse.y < ry + row.h
        local on = false
        if it.active then local okA, v = pcall(it.active); on = okA and v end
        local sandboxOn = it.label == "Sandbox mode" and R.sandbox
        local br, bg, bb = 38, 42, 78
        if hov then br, bg, bb = 80, 84, 130
        elseif sandboxOn then br, bg, bb = 92, 58, 28
        elseif on then br, bg, bb = 34, 72, 48 end
        graphics.fillRect(SET_X, ry, SET_W, row.h, br, bg, bb, 255)
        local borderR, borderG, borderB = 120, 124, 170
        if sandboxOn then borderR, borderG, borderB = 255, 170, 60
        elseif on then borderR, borderG, borderB = 120, 220, 120 end
        graphics.drawRect(SET_X, ry, SET_W, row.h, hov and 255 or borderR, hov and 220 or borderG, hov and 80 or borderB, 255)
        graphics.drawText(SET_X + 8, ry + 4, menuWrap(it.label, SET_W - 16)[1] or it.label, 255, 255, 255, 255)
        if it.status then
          local okS, st = pcall(it.status)
          if okS and st and st ~= "" then
            local sr, sg, sb = 165, 170, 185
            if st == "ON" then sr, sg, sb = 140, 230, 140
            elseif st == "OFF" then sr, sg, sb = 150, 150, 160
            elseif sandboxOn then sr, sg, sb = 255, 200, 120 end
            graphics.drawText(SET_X + 8, ry + 15, menuWrap(st, SET_W - 16)[1] or st, sr, sg, sb, 255)
          end
        end
      end
    end
  end
  if maxScroll > 0 and scroll < maxScroll then
    graphics.drawText(SET_X + SET_W - 42, SET_TOP + 14 + visibleH - 12, "more v", 150, 150, 160, 255)
  end
  -- compact status footer (right column — keeps CONTROLS column clear)
  local na = 0; for _ in pairs(R.acc) do na = na + 1 end
  local stY = MY + MH - 52
  graphics.fillRect(SET_X, stY, SET_W, 42, 20, 22, 36, 220)
  graphics.drawText(SET_X + 6, stY + 4, "STATUS", 255, 220, 80, 255)
  local st = { string.format("World %d  Day %d", R.seed or 0, R.day or 1),
               string.format("Deaths %d%s", R.deaths or 0, R.sandbox and "  SANDBOX" or ""),
               string.format("Pick: %s  Foes: %s", R.TOOLS.pick.name, R.enemies and "ON" or "off"),
               string.format("Acc %d  FX %s  Grid %s", na, R.fxOn and "on" or "off", R.grid and "on" or "off") }
  local stMaxY = MY + MH - 2
  for i, line in ipairs(st) do
    local ly = stY + 16 + (i - 1) * 10
    if ly + 10 > stMaxY then break end
    for _, ln in ipairs(menuWrap(line, SET_W - 12)) do
      if ly + 10 > stMaxY then break end
      graphics.drawText(SET_X + 6, ly, ln, 205, 205, 215, 255); ly = ly + 10
    end
  end
  local q = R.QUESTS[R.quest]
  if q then
    graphics.drawText(SET_X + 6, stY - 12, menuWrap("GOAL " .. R.quest .. "/" .. #R.QUESTS .. ": " .. q.txt, SET_W - 12)[1] or "", 200, 230, 200, 255)
  end
end
-- goal_verify draw-path probe (bridge-only; pcalls wrap/drawMenu directly)
function R._goalVerifyDrawProbe()
  local r = { version = tostring(R.VERSION or ""), gauge_labels = "TEMP,PRESS" }
  local okW, resW = pcall(function() return wrap("goal verify: wrap probe line", 24) end)
  r.wrap_ok = okW and type(resW) == "table" and #resW >= 1
  if not okW then r.wrap_err = tostring(resW) end
  r.drawMenu_is_function = type(drawMenu) == "function"
  local env = R.env or {}
  r.env_keys = 0
  for _ in pairs(env) do r.env_keys = r.env_keys + 1 end
  r.hud_day = string.format("Day %d", R.day or 1)
  return r
end
end -- UI/menu scope (hot-reload local cap)
local function onDraw()
  if R.titleScreen then drawTitleScreen(); return end
  -- SANDBOX BRUSH PREVIEW. He asked to "go back to the centre of where I was doing my shape"
  -- after a middle-mouse resize. The cursor itself CANNOT be moved: tpt.mousex/mousey are
  -- explicitly read-only (compat.lua:711-714, "property is read-only") and SDL_WarpMouse is
  -- not present anywhere in src/. So instead of moving the cursor to the shape, this draws
  -- the shape at the anchor: while the middle button is held, an outline of the NEW size is
  -- drawn centred on the point where the drag began, with a live w x h readout. You size the
  -- brush against the exact spot you intend to use it, and the cursor wandering off during
  -- the drag stops mattering. Only runs while actively resizing, so it costs nothing
  -- otherwise, and it is the only thing the RPG draws in sandbox mode.
  if R.sandboxMode then
    local b = R.sbBrush
    if b and b.active and b.w and b.h then
      local ax, ay, w, h = b.ax, b.ay, b.w, b.h
      graphics.drawLine(ax - 5, ay, ax + 5, ay, 255, 220, 120, 200)   -- centre crosshair
      graphics.drawLine(ax, ay - 5, ax, ay + 5, 255, 220, 120, 200)
      if w == h then
        graphics.drawCircle(ax, ay, w, h, 255, 220, 120, 190)
      else
        graphics.drawRect(ax - w, ay - h, w * 2, h * 2, 255, 220, 120, 150)
        graphics.drawCircle(ax, ay, w, h, 255, 220, 120, 190)
      end
      graphics.drawText(ax + 8, ay - 16, w * 2 .. " x " .. h * 2, 255, 235, 170, 230)
      -- name whatever is under the anchor, using the ctype-aware label so molten material
      -- reads as "Molten Steel" rather than "LAVA"
      local okp, pid = pcall(sim.pmap, math.floor(ax), math.floor(ay))
      if okp and pid then
        local lbl = R.partLabel(pid)
        if lbl ~= "" then graphics.drawText(ax + 8, ay - 6, lbl, 210, 225, 245, 220) end
      end
    end
    if R.SB and R.SB.on then
      if R.drawPlayer then pcall(R.drawPlayer) end
    end
    runHooks(R.hooks.sandboxDraw)
    runHooks(R.hooks.sandboxDrawHUD)
    R.sbDrawButtons()   -- drawn last so nothing else can cover the only mouse-reachable controls
    return
  end
  if not R.active then return end
  local phase = ((R.frame or 0) % 14000) / 14000
  local night = phase < (R.dayFrac or 0.65) and 0 or math.max(0, math.sin(((phase - (R.dayFrac or 0.65)) / (1 - (R.dayFrac or 0.65))) * math.pi))
  local depth = R.P.y - surfaceAt(floor(R.P.x))
  do local rain = R.weather and R.weather.rain
    local sr, sg, sb, sa = 110, 170, 255, 80
    if rain then sr, sg, sb = 90, 105, 130 end
    if night > 0 then sr, sg, sb = floor(sr * (1 - night) + 8 * night), floor(sg * (1 - night) + 10 * night), floor(sb * (1 - night) + 45 * night); sa = 80 + floor(60 * night) end
    local dusk = math.max(0, 1 - math.abs(night - 0.12) * 12); if dusk > 0 and not rain then sr = math.min(255, floor(sr + 120 * dusk)); sg = floor(sg + 40 * dusk) end
    for x = 0, W - 1, 4 do local sy = surfaceAt(x + R.cam.x) - R.cam.y; if sy > 0 then graphics.fillRect(x, 0, 4, math.min(sy, H), sr, sg, sb, sa) end end
    -- sun (phase 0..0.5) and moon (0.5..1): rise at the left horizon, peak high at mid-arc, set at the right; hidden behind terrain
    local isDay = phase < (R.dayFrac or 0.65); local t = isDay and (phase / (R.dayFrac or 0.65)) or ((phase - (R.dayFrac or 0.65)) / (1 - (R.dayFrac or 0.65)))
    local elev = math.sin(t * math.pi); local bx = floor(40 + t * (W - 80)); local by = floor(118 - elev * 100 - R.cam.y * 0.1)
    local horizon = surfaceAt(bx + R.cam.x) - R.cam.y
    if not rain and by < horizon - 4 then if isDay then graphics.fillCircle(bx, by, 9, 9, 255, 230, 120, 230); graphics.fillCircle(bx, by, 13, 13, 255, 220, 100, 40) else graphics.fillCircle(bx, by, 7, 7, 230, 230, 240, 220) end end
    if night > 0.3 and not rain then for i = 1, 40 do local sx, sy = floor(hash3(i, 1, 51) * W), floor(hash3(i, 2, 52) * 120); if sy < surfaceAt(sx + R.cam.x) - R.cam.y then graphics.fillRect(sx, sy, 1, 1, 255, 255, 255, floor(200 * (night - 0.3))) end end end
    for i = 1, (rain and 9 or 4) do local cx = floor((hash3(i, 3, 53) * 1600 + R.frame * 0.15) % 1400) - 200 - floor(R.cam.x * 0.3) % 1400; local cy = 20 + floor(hash3(i, 4, 54) * 60) - floor(R.cam.y * 0.2)
      if cy > -20 and cy < 200 then local cr, cg, cb = rain and 120 or 255, rain and 125 or 255, rain and 140 or 255
        graphics.fillCircle(cx, cy, 22, 8, cr, cg, cb, 180); graphics.fillCircle(cx - 14, cy + 3, 12, 6, cr, cg, cb, 180); graphics.fillCircle(cx + 16, cy + 2, 14, 7, cr, cg, cb, 180) end end
  end
  local dark = math.max(0, math.min(1, (depth - 60) / 300)); if R.accOn("helmet") then dark = dark * 0.35 end
  local shade = dark * 150
  if shade > 0 then graphics.fillRect(0, 0, W, H, 0, 0, 0, floor(shade)) end
  for ty = floor(R.cam.y / CC), floor((R.cam.y + H) / CC) do for tx = floor(R.cam.x / CC), floor((R.cam.x + W) / CC) do
    local c = R.chestAt(tx, ty); if c then local x, y = c.x - R.cam.x, c.y - R.cam.y
      if c.opened then graphics.fillRect(x, y - 3, 6, 4, 90, 60, 30, 255) else graphics.fillRect(x, y - 5, 6, 6, 140, 90, 40, 255); graphics.fillRect(x, y - 3, 6, 1, 255, 210, 60, 255); graphics.fillRect(x + 2, y - 4, 2, 2, 255, 230, 120, 255)
        if (R.frame % 40) < 20 then graphics.drawText(x - 6, y - 16, "chest", 255, 220, 80, 200) end end end end end
  for _, t in ipairs(R.torches or {}) do local x, y = t.x - R.cam.x, t.y - R.cam.y; if x > -40 and x < W + 40 and y > -40 and y < H + 40 then
    local fl = 2 + (R.frame % 7) % 3; graphics.fillCircle(x, y, 26 + fl, 22 + fl, 255, 190, 90, 26); graphics.fillCircle(x, y, 14, 12, 255, 210, 120, 40) end end
  -- Contaminated ground glows visibly, Fallout-crater style -- so a hot
  -- zone reads as dangerous just by looking at it, not only once the meter
  -- ticks up standing in it. Pulses; radius/alpha track how strong it still is.
  for _, z in ipairs(R.radZones) do
    local x, y = z.x - R.cam.x, z.y - R.cam.y
    if x > -60 and x < W + 60 and y > -60 and y < H + 60 then
      local pulse = 0.7 + 0.3 * math.sin(R.frame / 20)
      local r = math.min(50, 12 + z.strength) * pulse
      graphics.fillCircle(x, y, r, r * 0.7, 120, 255, 100, math.min(90, 20 + z.strength))
    end
  end
  if R.lastHitAt then for pid, h in pairs(R.blockHits) do if sim.partExists(pid) then local x, y = sim.partPosition(pid); graphics.fillRect(floor(x), floor(y), 1, 1, 0, 0, 0, math.min(200, 60 + h * 50)) end end end
  if R.treeHit and R.frame - R.treeHit.t < 40 then local t = R.treeHit
    -- small damage bar on the trunk itself, no text
    local x, y = t.x - R.cam.x, t.y - R.cam.y - 16
    graphics.fillRect(x - 9, y, 18, 3, 0, 0, 0, 170)
    graphics.fillRect(x - 8, y + 1, floor(16 * t.hp / 100), 1, 235, 180, 70, 220) end
  if R.timber and R.frame - R.timber.t < 30 then local a = 200 - (R.frame - R.timber.t) * 6
    graphics.drawText(R.timber.x - R.cam.x - 18, R.timber.y - R.cam.y - 20, "TIMBER!", 255, 230, 120, a) end
  if R.swingAt and R.frame - R.swingAt[3] < 6 then graphics.drawCircle(R.swingAt[1], R.swingAt[2], 3, 3, 255, 255, 255, 160) end
  runHooks(R.hooks.draw)
  pcall(drawO2BreathField)
  local ok, err = pcall(drawPlayer); if not ok then R.lastErr = tostring(err) end
  if not R.hud then return end
  local s = selected(); local reach = 30; if s and s:find("^tool:") and R.TOOLS[s:sub(6)] then reach = R.TOOLS[s:sub(6)].reach or 30 end
  local px, py = pcanvas()
  local mx, my = R.mouse.x, R.mouse.y
  local shiftBuild = shiftBuildMode()
  local okr = shiftBuild or dist2(mx, my, px, py) <= reach*reach
  -- F15b: when the owner uses TPT's native element menu (R.tptMenus), the RPG's brush preview
  -- square draws on top of it and gets in the way. Suppress the preview entirely in
  -- tptMenus mode -- the TPT menu itself shows what block is selected. The preview
  -- still draws when the RPG owns the selection flow (default mode).
  if not R.invOpen and not R.menuOpen and not R.uiPanelOpen and not R.tptMenus then   -- plugins set R.uiPanelOpen while their panels are open
    -- Terraria-style cursor: highlight only what the action will affect (no reach circle, no lattice)
    local key = s and s:find("^tool:") and s:sub(6) or nil
    if (key == "pick" or key == "axe") and R.smart ~= false then

      local tx2, ty2 = smartTarget(mx, my, reach, R.TOOLS[key].only, R.TOOLS[key].power); if tx2 then local r2 = R.TOOLS[key].radius or 3; graphics.drawRect(tx2 - r2, ty2 - r2, 2*r2 + 1, 2*r2 + 1, 255, 255, 255, 110) end
    elseif s and not s:find("^tool:") and not R.ITEMS[s] then
      local rx = R.brushRx or R.brush or 1; local ry = R.brushRy or R.brush or 1
      local shape = R.brushShape or "square"; local cr, cg, cb = colourOf(s)
      local g = R.gridSize or 4
      if R.placeAnchor then
        local ax, ay = R.placeAnchor[1], R.placeAnchor[2]
        if R.placeLine then
          local lx, ly = snapLineEnd(ax, ay, mx, my)
          graphics.drawLine(ax, ay, lx, ly, 255, 220, 90, 120)
        end
        if R.placeRect then
          local x1, y1 = math.min(ax, mx), math.min(ay, my)
          local x2, y2 = math.max(ax, mx), math.max(ay, my)
          if shape == "circle" then
            pcall(graphics.drawCircle, (x1 + x2) / 2, (y1 + y2) / 2, math.max(1, (x2 - x1) / 2), math.max(1, (y2 - y1) / 2), 255, 220, 90, 180)
          else
            graphics.drawRect(x1, y1, x2 - x1 + 1, y2 - y1 + 1, 255, 220, 90, 180)
          end
        end
      end
      if R.placeBox and R.placeAnchor then
        local ax, ay = R.placeAnchor[1], R.placeAnchor[2]
        local bx1, by1 = math.min(ax, mx), math.min(ay, my)
        local bw, bh = math.abs(mx - ax) + 1, math.abs(my - ay) + 1
        graphics.fillRect(bx1, by1, bw, bh, cr, cg, cb, 50)
        graphics.drawRect(bx1, by1, bw, bh, 255, 220, 90, 180)
      end
      local x1, y1, x2, y2 = mx - rx, my - ry, mx + rx, my + ry
      if R.grid or R.ctrlHeld or R.shiftHeld then local gx = floor((mx + R.cam.x) / g) * g - R.cam.x; local gy = floor((my + R.cam.y) / g) * g - R.cam.y
        x1, y1, x2, y2 = gx - g*rx, gy - g*ry, gx + g*rx + g - 1, gy + g*ry + g - 1 end
      local ww, hh = x2 - x1 + 1, y2 - y1 + 1
      local fr, fg, fb, fa = okr and cr or 255, okr and cg or 60, okr and cb or 60, okr and 90 or 50
      local br, bg, bb, ba = okr and 255 or 255, okr and 255 or 90, okr and 255 or 90, okr and 210 or 180
      if shape == "circle" and ww > 1 then
        pcall(graphics.fillCircle, mx, my, rx, ry, fr, fg, fb, fa)
        pcall(graphics.drawCircle, mx, my, rx, ry, br, bg, bb, ba)
      elseif shape == "triangle" and ww > 1 then
        graphics.drawLine(mx, y1, x1, y2, br, bg, bb, ba)
        graphics.drawLine(x1, y2, x2, y2, br, bg, bb, ba)
        graphics.drawLine(x2, y2, mx, y1, br, bg, bb, ba)
      else
        if okr then graphics.fillRect(x1, y1, ww, hh, cr, cg, cb, 90); graphics.drawRect(x1, y1, ww, hh, 255, 255, 255, 210)
        else graphics.fillRect(x1, y1, ww, hh, 255, 60, 60, 50); graphics.drawRect(x1, y1, ww, hh, 255, 90, 90, 180) end
      end
      -- F16: at brush=0 (1px), the center pixel IS where the user is aiming -- the 8 corner
      -- ticks + size label around it produce a "+" bigger than the pixel itself, covering
      -- the single-pixel drawing they're trying to make. Skip ticks AND label when 1x1.
      if not (ww == 1 and hh == 1) then
      local tc = okr and 255 or 150
      graphics.fillRect(x1 - 1, y1 - 1, 3, 1, tc, tc, tc, 230); graphics.fillRect(x1 - 1, y1 - 1, 1, 3, tc, tc, tc, 230)
      graphics.fillRect(x2 - 1, y1 - 1, 3, 1, tc, tc, tc, 230); graphics.fillRect(x2 + 1, y1 - 1, 1, 3, tc, tc, tc, 230)
      graphics.fillRect(x1 - 1, y2 + 1, 3, 1, tc, tc, tc, 230); graphics.fillRect(x1 - 1, y2 - 1, 1, 3, tc, tc, tc, 230)
      graphics.fillRect(x2 - 1, y2 + 1, 3, 1, tc, tc, tc, 230); graphics.fillRect(x2 + 1, y2 - 1, 1, 3, tc, tc, tc, 230)
      local lbl = (R.grid or R.ctrlHeld or R.shiftHeld) and ((rx + 1) .. "x" .. (ry + 1) .. " cells @" .. g .. "px") or (ww .. "px")
      graphics.drawText(x1, y2 + 4, lbl, 235, 235, 245, 190)
      end
    elseif s and R.ITEMS[s] then graphics.drawRect(mx - 7, my - 12, 15, 13, 255, 220, 120, okr and 160 or 70) end end
  -- HUD layout: left column (HP/day/gauges), right alert column (x=310..498), minimap column (x>=502).
  local MAP_X = W - 110
  local RC_X, RC_W = 310, MAP_X - 310 - 4
  R._rcY = 4
  R.rcLine = function(advance)
    local x, y = RC_X, R._rcY
    if advance then R._rcY = R._rcY + advance end
    return x, y, RC_W
  end
  -- Top-left HUD: fixed rows (HP / day / optional air+food / T / P) — no overlapping bands
  local HUD_X, HUD_W = 4, 248
  graphics.fillRect(HUD_X, 4, HUD_W, 14, 0, 0, 0, 170)
  local n = math.max(0, math.min(10, floor((R.hp or 0) / 10 + 0.5)))
  for i = 1, 10 do local x = 8 + (i-1)*12; if i <= n then graphics.fillRect(x, 8, 9, 8, 230, 50, 60, 255); graphics.fillRect(x+1, 7, 3, 2, 230, 50, 60, 255); graphics.fillRect(x+5, 7, 3, 2, 230, 50, 60, 255) else graphics.drawRect(x, 8, 9, 8, 120, 60, 60, 255) end end
  graphics.drawText(130, 8, tostring(floor(R.hp or 0)), 255, 120, 120, 255)
  local where = depth > 20 and string.format("%dm underground", floor(depth / 4)) or (depth < -20 and string.format("%dm up", floor(-depth / 4)) or "surface")
  graphics.fillRect(HUD_X, 20, HUD_W, 12, 0, 0, 0, 140)
  graphics.drawText(8, 22, string.format("Day %d%s   x %d   %s   %s", R.day or 1, night > 0.2 and " (night)" or "", floor(R.P.x / 4), where, biomeAt(floor(R.P.x))), 220, 220, 220, 255)
  if (R.deaths or 0) > 0 then
    -- was "D:2" -- an abbreviation nothing on screen explains, and the changelog for
    -- this very readout promised "Deaths: N". Spell it out; it still fits the band
    -- (x=168 + ~48px vs the band ending at HUD_X+HUD_W=252).
    graphics.drawText(168, 8, string.format("Deaths %d", R.deaths), 255, 150, 80, 255)
  end
  local N = R.need
  local needAir = (R.o2 or 100) < 100 or (R.o2conc or 0) > 25
  local needFood = (N.food or 100) < 100 or (N.water or 100) < 100
  local vitalsY = 34
  if needAir or needFood then
    graphics.fillRect(HUD_X, vitalsY, HUD_W, 10, 0, 0, 0, 130)
    if needAir then
      local o2 = R.o2 or 100
      local w = floor(o2 / 100 * 116); local r, g, b = 90, 170, 255
      if o2 < 35 then r, g, b = 255, 160, 60 end; if o2 < 15 then r, g, b = 255, 70, 70 end
      graphics.fillRect(8, vitalsY + 4, 116, 3, 40, 40, 60, 255); graphics.fillRect(8, vitalsY + 4, w, 3, r, g, b, 255)
      graphics.drawText(128, vitalsY + 1, "AIR " .. floor(o2) .. "%", r, g, b, 255)
      if (R.inventory.FLASK or 0) > 0 then local cap = 100 * math.min(3, R.inventory.FLASK)
        graphics.fillRect(8, vitalsY + 7, 60, 2, 40, 40, 60, 255); graphics.fillRect(8, vitalsY + 7, floor((R.flask or 0) / cap * 60), 2, 150, 220, 235, 255)
        graphics.drawText(72, vitalsY + 4, "flask", 150, 220, 235, 200) end
    end
    if needFood then
      graphics.fillRect(8, vitalsY + 2, 56, 3, 40, 40, 60, 255); graphics.fillRect(8, vitalsY + 2, floor(N.food / 100 * 56), 3, 210, 160, 70, 255)
      if N.food < 25 or N.water < 25 then graphics.drawText(68, vitalsY, N.water < N.food and "THIRSTY" or "HUNGRY", 255, 150, 80, 255) end
    end
    vitalsY = vitalsY + 12
  end
  local G = R.gas or {}
  local gasLine, gasR, gasG, gasB = nil, 255, 120, 60
  if (G.co or 0) > 20 then gasLine = string.format("CO %d%%%s", floor(G.co), G.co > 35 and " - POISONING" or ""); gasR, gasG, gasB = 255, 120, 60
  elseif (G.ch4 or 0) > 25 then gasLine = string.format("EXPLOSIVE GAS %d%%", floor(G.ch4)); gasR, gasG, gasB = 255, 200, 60
  elseif (G.rad or 0) > 25 then gasLine = string.format("RADIATION %d%%", floor(G.rad)); gasR, gasG, gasB = 140, 255, 120
  elseif (G.heat or 0) > 35 then gasLine = string.format("HEAT %d%%", floor(G.heat)); gasR, gasG, gasB = 255, 150, 90
  elseif (R.o2conc or 0) > 60 and (R.frame % 26) < 13 then gasLine = "OXYGEN RICH - FIRE HAZARD"; gasR, gasG, gasB = 255, 140, 60
  elseif (R.o2 or 100) < 35 and (R.frame % 30) < 15 then gasLine = ((R.o2 or 100) < 15 and "SUFFOCATING" or "AIR RUNNING OUT"); gasR, gasG, gasB = 255, 90, 90
  elseif (R.o2 or 100) < 70 and (R.o2conc or 0) <= 25 then gasLine = ((R.P.y - surfaceAt(floor(R.P.x))) > 140) and "thin air" or "stale air"; gasR, gasG, gasB = 160, 170, 190
  elseif (R.o2conc or 0) > 25 then gasLine = "O2 " .. floor(R.o2conc) .. "%"; gasR, gasG, gasB = 140, 220, 255 end
  do local q = R.QUESTS[R.quest]
    if q then
      -- Was string.sub(q.txt, 1, 24): a hardcoded char cut with no relation to the
      -- actual column width, so it sliced mid-word -- "Craft a wood pick by hand"
      -- (25 chars) rendered as "...by han", captured live. Derive the budget from
      -- the real RC_W instead, via the same menuWrap already used by the Esc menu,
      -- and allow up to three rows so goals read in full; only genuinely long ones
      -- ellipsize, and then on a word boundary rather than mid-word.
      local lines = R.menuWrap("GOAL " .. R.quest .. "/" .. #R.QUESTS .. ": " .. q.txt, RC_W)
      -- The GOAL line is the game's primary "what do I do next" prompt, so it earns
      -- the extra row: 3 fits the current quest set's typical length in full.
      local shown = math.min(#lines, 3)
      local h = 2 + shown * 12
      local x, y = R.rcLine(h + 2)
      graphics.fillRect(x, y, RC_W, h, 0, 0, 0, 150)
      local maxc = math.max(1, floor((RC_W - 4) / R.MENU_CHAR_W))
      for i = 1, shown do
        local t = lines[i]
        -- trim before appending the ellipsis, so the marker cannot push the row
        -- back past the width budget it was just wrapped to
        if i == shown and #lines > shown then t = t:sub(1, math.max(1, maxc - 3)) .. "..." end
        graphics.drawText(x + 2, y + 2 + (i - 1) * 12, t, 255, 220, 120, 255)
      end
    end
  end
  if gasLine then
    local x, y = R.rcLine(12)
    graphics.drawText(x, y, gasLine, gasR, gasG, gasB, 255)
  end
  if (R.radAccum or 0) > 10 then
    local rc = (R.radAccum > 40) and { 255, 120, 90 } or { 200, 230, 140 }
    local x, y = R.rcLine(12)
    graphics.drawText(x, y, string.format("RAD dose %d%%", floor(R.radAccum)), rc[1], rc[2], rc[3], 255)
  end
  if (R.uvAccum or 0) > 20 then
    local uc = (R.uvAccum > 70) and { 255, 150, 90 } or { 255, 220, 140 }
    local x, y = R.rcLine(14)
    graphics.drawText(x, y, string.format("UV burn %d%%", floor(R.uvAccum)), uc[1], uc[2], uc[3], 255)
    graphics.fillRect(x, y + 9, 56, 3, 40, 40, 60, 255)
    graphics.fillRect(x, y + 9, floor(R.uvAccum / 100 * 56), 3, uc[1], uc[2], uc[3], 255)
  end
  do
    local env = R.env or {}
    local BAR_X, BAR_W, ROW_H = 52, 128, 13
    local function kToF(k) return (k - 273.15) * 9 / 5 + 32 end
    local function tempGaugeColor(tF)
      if tF < 70 then
        local k = math.max(0, math.min(1, (tF + 20) / 90))
        return math.floor(80 + 175 * k), math.floor(150 + 105 * k), 255
      elseif tF < 200 then
        local k = (tF - 70) / 130
        return 255, math.floor(255 - 75 * k), math.floor(255 - 195 * k)
      else
        local k = math.max(0, math.min(1, (tF - 200) / 300))
        return 255, math.floor(180 - 130 * k), math.floor(60 - 40 * k)
      end
    end
    local T_LO, T_HI = -40, 950
    local function tFrac(tF) return math.max(0, math.min(1, (tF - T_LO) / (T_HI - T_LO))) end
    local bandY = vitalsY + 2
    graphics.fillRect(HUD_X, bandY, HUD_W, ROW_H * 2 + 2, 0, 0, 0, 130)
    local tY = bandY + 2
    local tMinK = math.min(env.tempMin or 295, env.geoMin or env.tempMin or 295)
    local tMaxK = math.max(env.tempMax or 295, env.geoMax or env.tempMax or 295)
    if tMaxK - tMinK < 10 then
      local spread = 8 + math.min(60, (env.depth or 0) * 0.12)
      tMinK = tMinK - spread * 0.45
      tMaxK = tMaxK + spread * 0.55
    end
    local tMinF = kToF(tMinK)
    local tMaxF = kToF(tMaxK)
    local tAvgF = kToF(env.tempAvg or (tMinK + tMaxK) / 2)
    graphics.drawText(8, tY + 1, "TEMP", 180, 200, 220, 255)
    graphics.fillRect(BAR_X, tY + 2, BAR_W, 6, 40, 40, 60, 200)
    for i = 0, BAR_W - 1 do
      local r, g, b = tempGaugeColor(T_LO + (i / math.max(1, BAR_W - 1)) * (T_HI - T_LO))
      graphics.fillRect(BAR_X + i, tY + 2, 1, 6, r, g, b, 255)
    end
    do
      local x1 = BAR_X + floor(tFrac(tMinF) * (BAR_W - 1))
      local x2 = BAR_X + floor(tFrac(tMaxF) * (BAR_W - 1))
      if x2 < x1 then x1, x2 = x2, x1 end
      if x2 > x1 then
        graphics.fillRect(x1, tY + 1, x2 - x1 + 1, 8, 255, 255, 255, 55)
        graphics.drawRect(x1, tY + 1, x2 - x1 + 1, 8, 255, 255, 255, 180)
      end
      local ax = BAR_X + floor(tFrac(tAvgF) * (BAR_W - 1))
      graphics.fillRect(ax, tY + 1, 2, 8, 255, 255, 255, 220)
    end
    graphics.drawRect(BAR_X, tY + 2, BAR_W, 6, 180, 180, 200, 200)
    local ar, ag, ab = tempGaugeColor(tAvgF)
    graphics.drawText(BAR_X + BAR_W + 4, tY + 1, string.format("%.0f-%.0fF", tMinF, tMaxF), ar, ag, ab, 255)
    local pY = bandY + ROW_H + 1
    local P_LO, P_HI = -12, 24
    local function pFrac(p) return math.max(0, math.min(1, (p - P_LO) / (P_HI - P_LO))) end
    local pMin = env.pressMin or 0
    local pMax = env.pressMax or 0
    local pAvg = env.pressAvg or 0
    graphics.drawText(8, pY + 1, "PRESS", 180, 200, 220, 255)
    graphics.fillRect(BAR_X, pY + 2, BAR_W, 6, 40, 40, 60, 200)
    for i = 0, BAR_W - 1 do
      local pv = P_LO + (i / math.max(1, BAR_W - 1)) * (P_HI - P_LO)
      local apv = math.abs(pv)
      local r, g, b
      if apv <= 1.5 then r, g, b = 90, 200, 110
      elseif apv <= 3.5 then r, g, b = 230, 200, 90
      else r, g, b = 230, 90, 90 end
      graphics.fillRect(BAR_X + i, pY + 2, 1, 6, r, g, b, 255)
    end
    do
      local x1 = BAR_X + floor(pFrac(pMin) * (BAR_W - 1))
      local x2 = BAR_X + floor(pFrac(pMax) * (BAR_W - 1))
      if x2 < x1 then x1, x2 = x2, x1 end
      if x2 > x1 then
        graphics.fillRect(x1, pY + 1, x2 - x1 + 1, 8, 255, 255, 255, 55)
        graphics.drawRect(x1, pY + 1, x2 - x1 + 1, 8, 255, 255, 255, 180)
      end
      local apx = BAR_X + floor(pFrac(pAvg) * (BAR_W - 1))
      graphics.fillRect(apx, pY + 1, 2, 8, 255, 255, 255, 220)
    end
    graphics.fillRect(BAR_X + floor(BAR_W / 2) - 1, pY + 1, 1, 8, 220, 220, 230, 180)
    graphics.drawRect(BAR_X, pY + 2, BAR_W, 6, 180, 180, 200, 200)
    local ap = math.abs(pAvg)
    local pr, pg, pb
    if ap <= 1.5 then pr, pg, pb = 90, 200, 110
    elseif ap <= 3.5 then pr, pg, pb = 230, 200, 90
    else pr, pg, pb = 230, 90, 90 end
    graphics.drawText(BAR_X + BAR_W + 4, pY + 1, string.format("%+d..%+d", math.floor(pMin + 0.5), math.floor(pMax + 0.5)), pr, pg, pb, 255)
    vitalsY = bandY + ROW_H * 2 + 4
    R._hudLeftEndY = vitalsY
  end
  local logY = vitalsY + 6
  local logN = #(R.log or {})
  -- R.hint is assigned in 25 places across core+plugins and cleared in none, and this
  -- draw site had no expiry -- so the last action's text ("+1 Dirt  +7 Wood") sat on the
  -- HUD at full brightness indefinitely, long after the action, reading as a stuck UI
  -- element. Stamp it here instead: this draw is the single choke point every one of
  -- those assignments flows through, so one comparison replaces touching 25 call sites.
  -- Then fade it the same way the R.log entries below already fade by age.
  if R.hint ~= R._hintPrev then R._hintPrev, R._hintAt = R.hint, R.frame or 0 end
  local hintA = 0
  if R.hint then
    -- hold fully legible ~6s, then fade over ~2s (tick rate measured ~36fps under load)
    hintA = math.max(0, math.min(255, 255 - floor(((R.frame or 0) - (R._hintAt or 0) - 220) * 3.5)))
  end
  local showHint = R.hint and hintA > 0
  if logN > 0 or showHint then
    graphics.fillRect(HUD_X, logY, HUD_W, 10 + 11 * math.max(logN, showHint and 1 or 0), 0, 0, 0, 100)
  end
  for k, m in ipairs(R.log or {}) do local age = (R.frame or 0) - m[2]; local a = math.max(0, math.min(255, 255 - floor(age / 2))); if a > 0 then graphics.drawText(8, logY + 11 * (k - 1), m[1], 255, 230, 140, a) end end
  if showHint then graphics.drawText(8, logY + 11 * logN, R.hint, 200, 230, 255, hintA) end
  if R.drawQuickBar then pcall(R.drawQuickBar) end
  runHooks(R.hooks.drawHUD)
  if R.debug then
    graphics.drawText(260, 20, string.format("wx=%.1f wy=%.1f cam=%d,%d parts=%d shift=%.1fms err=%s", R.P.x, R.P.y, R.cam.x, R.cam.y, sim.partCount(), R.shiftMs or 0, tostring(R.lastErr)), 180, 255, 180, 255)
    graphics.drawText(260, 32, R.perfReport(), 180, 230, 255, 255)
  end
  do local n = #R.chatLog
    if R.chatOpen or (n > 0 and (R.frame - R.chatLog[n].frame) < 420) then
      local show = math.min(6, n); local y0 = H - 46 - show * 11 - (R.chatOpen and 16 or 0)
      graphics.fillRect(4, y0 - 4, 300, show * 11 + (R.chatOpen and 22 or 8), 0, 0, 0, 165)
      for i = 1, show do local m = R.chatLog[n - show + i]
        local nameCol = (m.who == "You") and { 150, 210, 255 } or { 255, 210, 130 }
        graphics.drawText(8, y0 + (i - 1) * 11, m.who .. ":", nameCol[1], nameCol[2], nameCol[3], 255)
        graphics.drawText(8 + (#m.who + 2) * 6, y0 + (i - 1) * 11, m.text, 235, 235, 240, 255) end
      if R.chatOpen then local ty = y0 + show * 11 + 3
        graphics.fillRect(6, ty - 2, 296, 14, 20, 24, 40, 235); graphics.drawRect(6, ty - 2, 296, 14, 120, 160, 220, 255)
        graphics.drawText(10, ty + 2, "> " .. R.chatText .. (((R.frame % 30) < 15) and "_" or ""), 235, 245, 255, 255) end
    end end
  if R.feedbackOpen then
    local fx, fy, fw = 156, 60, 300
    graphics.fillRect(fx, fy, fw, 30, 10, 10, 16, 235); graphics.drawRect(fx, fy, fw, 30, 220, 180, 120, 255)
    graphics.drawText(fx + 4, fy + 4, "Bug report / suggestion -- Enter to send, Esc to cancel", 255, 220, 160, 255)
    graphics.drawText(fx + 4, fy + 16, "> " .. R.feedbackText .. (((R.frame % 30) < 15) and "_" or ""), 235, 245, 255, 255)
  end
  if R.updatePromptOpen and R.updateInfo then
    local info = R.updateInfo
    local ux, uw = 80, W - 160
    local lines = {}
    for line in (info.notes .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("%S") then for _, wl in ipairs(wrap(line, uw - 16)) do lines[#lines + 1] = wl end
      else lines[#lines + 1] = "" end   -- blank lines are real spacers between version entries -- keep them, don't drop them (was making everything run together)
    end
    local shown = math.min(#lines, 10)
    local uy, uh = 40, 40 + shown * 11 + 16
    graphics.fillRect(0, 0, W, H, 0, 0, 0, 130)
    graphics.fillRect(ux, uy, uw, uh, 12, 14, 30, 246); graphics.drawRect(ux, uy, uw, uh, 140, 255, 160, 255)
    graphics.fillRect(ux, uy, uw, 16, 40, 44, 80, 255)
    graphics.drawText(ux + 8, uy + 4, "UPDATE AVAILABLE: v" .. info.version .. "  (" .. info.count .. " change" .. (info.count > 1 and "s" or "") .. " since v" .. R.VERSION .. ")", 140, 255, 160, 255)
    for i = 1, shown do graphics.drawText(ux + 8, uy + 22 + (i - 1) * 11, lines[i], 220, 225, 235, 255) end
    graphics.drawText(ux + 8, uy + uh - 12, "U = update now (quick restart)      or click", 190, 200, 220, 255)
    local b = R.updateBtnRect
    graphics.fillRect(b.x, b.y, b.w, b.h, 40, 60, 44, 255); graphics.drawRect(b.x, b.y, b.w, b.h, 140, 255, 160, 255)
    graphics.drawText(b.x + 6, b.y + 3, "Later", 220, 255, 225, 255)
  end
  -- The WHAT'S NEW panel used to draw over EVERYTHING -- the HUD, the hotbar, and the guide's
  -- entire content pane -- and it opens announcing something like "132 updates since you last
  -- played". Reviewed as a real screenshot 2026-09-02: it was the first thing anyone saw and it
  -- buried the actual game behind a wall of text, including making the guide unreadable if you
  -- opened it before dismissing.
  -- Every change still gets its own line (that is a standing rule and it is not being weakened);
  -- what changes is that the panel yields to whatever you are actually trying to look at. If a
  -- real panel is open, the changelog steps aside and waits rather than covering it.
  if R.changesPromptOpen and (R.invOpen or R.menuOpen or (R.guideOpen or (R.ui and R.ui.bagOpen))) then
    -- suppressed this frame; still open, still one keypress from being read
  elseif R.changesPromptOpen and R.localChanges then
    local info = R.localChanges
    local ux, uw = 80, W - 160
    local lines = {}
    for line in (info.notes .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("%S") then for _, wl in ipairs(wrap(line, uw - 16)) do lines[#lines + 1] = wl end
      else lines[#lines + 1] = "" end   -- blank lines are real spacers between version entries -- keep them, don't drop them (was making everything run together)
    end
    local visible = 14
    local maxScroll = math.max(0, #lines - visible)
    R.changesScroll = math.max(0, math.min(maxScroll, R.changesScroll or 0))
    local shown = math.min(#lines - R.changesScroll, visible)
    local uy, uh = 40, 40 + math.max(shown, 1) * 11 + 16
    graphics.fillRect(0, 0, W, H, 0, 0, 0, 130)
    graphics.fillRect(ux, uy, uw, uh, 12, 14, 30, 246); graphics.drawRect(ux, uy, uw, uh, 255, 220, 80, 255)
    graphics.fillRect(ux, uy, uw, 16, 40, 44, 80, 255)
    graphics.drawText(ux + 8, uy + 4, "WHAT'S NEW (v" .. R.VERSION .. ")", 255, 220, 80, 255)
    for i = 1, shown do graphics.drawText(ux + 8, uy + 22 + (i - 1) * 11, lines[i + R.changesScroll], 220, 225, 235, 255) end
    -- real draggable scrollbar -- "a little bar I can grab and go all the way to the bottom" --
    -- wheel-only wasn't enough for a list this long (many version entries, ~11px/line).
    if maxScroll > 0 then
      local trackX, trackY, trackH, trackW = ux + uw - 16, uy + 20, uh - 38, 8
      graphics.fillRect(trackX, trackY, trackW, trackH, 30, 30, 42, 220)
      local thumbH = math.max(14, math.floor(trackH * shown / #lines))
      local thumbY = trackY + math.floor((trackH - thumbH) * (R.changesScroll / maxScroll))
      graphics.fillRect(trackX, thumbY, trackW, thumbH, 255, 220, 80, 255)
      local mx, my = R.mouse.x, R.mouse.y
      local overTrack = mx and my and mx >= trackX - 5 and mx <= trackX + trackW + 5 and my >= trackY and my <= trackY + trackH
      if R.mouse.l and (R.changesDragging or overTrack) then
        R.changesDragging = true
        local rel = (my - trackY - thumbH / 2) / math.max(1, trackH - thumbH)
        R.changesScroll = math.max(0, math.min(maxScroll, math.floor(rel * maxScroll + 0.5)))
      elseif not R.mouse.l then
        R.changesDragging = false
      end
    end
    graphics.drawText(ux + 8, uy + uh - 12, info.count .. " update" .. (info.count > 1 and "s" or "") .. " since you last played" .. (maxScroll > 0 and ("   drag the bar or wheel to scroll (" .. R.changesScroll .. "/" .. maxScroll .. ")") or "") .. "   Esc = got it", 190, 200, 220, 255)
    local b = R.changesBtnRect
    graphics.fillRect(b.x, b.y, b.w, b.h, 60, 52, 20, 255); graphics.drawRect(b.x, b.y, b.w, b.h, 255, 220, 80, 255)
    graphics.drawText(b.x + 10, b.y + 3, "Got it", 255, 240, 200, 255)
  end
  drawHotbar()
  -- Plugin overlay hook for the hotbar (added 2026-09-01 @lead, requested by @hotbar).
  -- drawHotbar() opens with an opaque fill across the whole tray and runs AFTER every
  -- plugin's drawHUD hook, so anything a plugin draws earlier is painted over and there
  -- was no way for ui.lua to add a hover highlight. This is the same idiom as
  -- R.drawQuickBar. pcall so a faulty plugin overlay can never take the HUD down.
  if R.drawHotbarOverlay then pcall(R.drawHotbarOverlay) end
  if R.minimap then drawMinimap() end; if R.invOpen then drawPanel() end
  if R.minimap then
    graphics.drawText(MAP_X, 136, "Esc | L | C", 150, 155, 170, 200)
  end
  -- Always visible, never hover-gated -- so anyone watching (including
  -- mid-stream) can immediately tell what build is running.
  -- Bottom-left corner, below where the chat box/hotbar sit.
  graphics.drawText(4, H - 10, "v" .. R.VERSION, 140, 145, 165, 200)
  if R.updateInfo then
    local blink = (R.frame % 60) < 40
    graphics.drawText(4, H - 20, R.updateDownloading and "Updating..." or (blink and (R.updateInfo.count .. " update" .. (R.updateInfo.count > 1 and "s" or "") .. " available - press U") or ""), 140, 255, 160, 255)
  end
  do local ok, en = pcall(ren.zoomEnabled); if ok and en then local ok2, zx, zy, zf, zs = pcall(ren.zoomWindow)
    if ok2 then graphics.fillRect(zx, zy + zs, zs, 12, 0, 0, 0, 200); graphics.drawText(zx + 4, zy + zs + 2, string.format("DETAIL: left dig / right place %dpx, wheel = size", 2*(R.brush or 0)+1), 140, 255, 140, 255) end
    -- palette of everything in the bag
    local names = invNames(); graphics.fillRect(2, PAL_Y - 12, math.max(120, #names * 26 + 6), 38, 0, 0, 0, 190); graphics.drawText(6, PAL_Y - 10, "PALETTE - click to select what to place", 255, 220, 80, 255)
    for i, el in ipairs(names) do local x = 4 + (i-1) * 26; local r, g, b = colourOf(el); local sel = (selected() == el)
      graphics.fillRect(x, PAL_Y, 24, 24, sel and 60 or 20, sel and 60 or 20, sel and 90 or 30, 255); graphics.drawRect(x, PAL_Y, 24, 24, sel and 255 or 90, sel and 220 or 90, sel and 80 or 110, 255)
      graphics.fillRect(x + 3, PAL_Y + 3, 10, 10, r, g, b, 255); graphics.drawText(x + 2, PAL_Y + 14, string.sub(nice(el), 1, 4), 220, 220, 220, 255) end
    if R.fine and not R.zoomPending then local cx, cy = zoomToCanvas(R.mouse.x, R.mouse.y); local r = R.brush or 0
      local x1, y1, x2, y2 = cx - r, cy - r, cx + r, cy + r
      if R.grid then local g2 = R.gridSize or 4; local gx = floor((cx + R.cam.x) / g2) * g2 - R.cam.x; local gy = floor((cy + R.cam.y) / g2) * g2 - R.cam.y; x1, y1, x2, y2 = gx - g2*r, gy - g2*r, gx + g2*r + g2 - 1, gy + g2*r + g2 - 1 end
      graphics.drawRect(x1, y1, x2 - x1 + 1, y2 - y1 + 1, 255, 255, 120, 220) end end end
  if R.menuOpen and drawMenu then local okM, errM = pcall(drawMenu); if not okM then R.lastErr = tostring(errM) end end
end

-- ================================================================ tick
R.torches = R.torches or {}
local function updateTorches()
  if sim.paused() or R.frame % 6 ~= 0 then return end
  local fire = eid("FIRE"); if not fire then return end
  for i = #R.torches, 1, -1 do local t = R.torches[i]
    local x, y = t.x - R.cam.x, t.y - R.cam.y
    if x >= M and x < W - M and y >= M and y < H - M then
      local stick = sim.partID(x, y + 1)
      if not stick or nameOf(sim.partProperty(stick, "type")) ~= "WOOD" then table.remove(R.torches, i)
      else sim.partProperty(stick, "temp", 295)
        if not sim.partID(x, y) then local f = sim.partCreate(-1, x, y, fire); if f and f >= 0 then sim.partProperty(f, "life", 30); sim.partProperty(f, "temp", 900) end end end end end
end
-- coal in a furnace chamber burns 20x slower than in the open (inlined below)
local function updateFurnaces()
  if sim.paused() then return end
  if R.frame % 20 == 0 then return end   -- on 1 frame in 20 we let the countdown proceed
  for _, st in ipairs(R.stations) do if st.kind == "furnace" then
    local x1, y1 = st.x + 2 - R.cam.x, st.y - 10 - R.cam.y
    if x1 > -20 and x1 < W + 20 and y1 > -20 and y1 < H + 20 then
      for y = y1, y1 + 8 do for x = x1, x1 + 9 do local p = sim.partID(x, y)
        if p then local nm = nameOf(sim.partProperty(p, "type")); if nm == "COAL" or nm == "BCOL" then local life = sim.partProperty(p, "life") or 110
          if life > 1 and life < 100 then sim.partProperty(p, "life", life + 1) end end end end end end end end
end
R.weather = R.weather or { rain = false, next = 3000 }
local function updateWeather()
  if sim.paused() then return end   -- reported bug: rain kept spawning in the sky while paused
  local Wt = R.weather
  if Wt.rain then
    Wt.left = Wt.left - 1; if Wt.left <= 0 then Wt.rain = false; Wt.next = 6000 + floor(math.random() * 9000); say("The rain stops") return end
    local wt = eid("WATR"); if not wt then return end
    for i = 1, 1 do local x = 4 + floor(math.random() * (W - 8)); local y = 6 + floor(math.random() * 24); local wy = y + R.cam.y; if wy > surfaceAt(x + R.cam.x) - 30 then y = -1 end
      if y > 4 and y < H - 4 and not sim.partID(x, y) then
        local wx = x + R.cam.x
        if R.treeVegQuery or R.nearestTreeDrain or R.treeShadeDrain then
          local q = (R.treeShadeDrain and R.treeShadeDrain(wx, wy))
            or (R.treeVegQuery and (R.treeVegQuery(wx, wy + 1) or R.treeVegQuery(wx, wy + 2)))
            or (R.nearestTreeDrain and R.nearestTreeDrain(wx, wy))
          if q and q.hollowCol and (q.canopy or q.poolOnCanopy or q.gapFloor) then
            local hx, hy = q.hollowCol - R.cam.x, y
            for dy = 0, 18 do
              local ty = hy + dy
              if ty >= H - 4 then break end
              if not sim.partID(hx, ty) then hy = ty; break end
            end
            x, y = hx, hy
          end
        end
        if not sim.partID(x, y) then local p = sim.partCreate(-1, x, y, wt); if p and p >= 0 then sim.partProperty(p, "vy", 2) end end
      end end
  else Wt.next = Wt.next - 1; if Wt.next <= 0 then Wt.rain = true; Wt.left = 900 + floor(math.random() * 900); say("Rain clouds roll in") end end
end
-- Nothing in this game ever removes standing water, so rain just piles up forever --
-- on the ground, and just as visibly on top of any tree canopy it lands on, since
-- WOOD/GRSS block it like solid ground would. Real soil/wood don't hold a puddle
-- indefinitely either, so soak resting water into whatever it's sitting on, at a rate
-- that comfortably loses to a real rainstorm but wins once the rain stops.
-- Lua 5.1 main-chunk local cap (200): tree/liquid/env helpers scoped here so hot reload still compiles.
local treeWaterVeinsTick, treeHollowDripTick, gapPoolDrainTick, canopyPoolDrainTick, treeGapGasVentTick, settleLiquidsTick, sampleEnvGradient, geoAmbienceTick, depthPressureTick, absorbStandingWater, pendingAirTick
do
local min, max, abs = math.min, math.max, math.abs
local ABSORBENT = { GOO=1, GRSS=1, WOOD=1, SAND=1, CLST=1, ICE=1, SNOW=1 }
local TREE_LIQ = { WATR=1, GOO=1, BLD=1 }
local function treeVegAt(wx, wy)
  if R.treeVegQuery then return R.treeVegQuery(wx, wy) end
  return nil
end
local function treeOnSurface(wx, wy)
  -- Gap floor between trunks must win over treeShadeDrain (shade matches gap pixels too).
  if R.nearestTreeDrain then
    local gq = R.nearestTreeDrain(wx, wy)
    if gq and gq.gapFloor then return gq end
  end
  local q = treeVegAt(wx, wy)
  if q and (q.poolOnCanopy or q.poolOnTrunk or q.trunkWood or q.inHollow) then return q end
  q = treeVegAt(wx, wy + 1)
  if q and (q.poolOnCanopy or q.poolOnTrunk) then return q end
  if R.treeShadeDrain then
    q = R.treeShadeDrain(wx, wy)
    if q then return q end
  end
  return nil
end
local function screenOK(sx, sy)
  return sx >= R.M and sx < W - R.M and sy >= R.M and sy < H - R.M
end
local function drainColumn(q)
  return q.hollowCol or (q.x0 + floor((q.tw or 2) / 2))
end
local function routeTreeLiquid(p, sx, sy, wx, wy, q, nm)
  local drain = drainColumn(q)
  local tsx = drain - R.cam.x
  local function fallInHollow(maxDy, sameRow)
    if sameRow and screenOK(tsx, sy) and not sim.partID(tsx, sy) then
      sim.partProperty(p, "x", tsx); sim.partProperty(p, "y", sy)
      sim.partProperty(p, "vy", 2.5 + math.random())
      sim.partProperty(p, "vx", 0)
      return true
    end
    for dy = 1, maxDy or 12 do
      local ty = sy + dy
      if screenOK(tsx, ty) and not sim.partID(tsx, ty) then
        sim.partProperty(p, "x", tsx); sim.partProperty(p, "y", ty)
        sim.partProperty(p, "vy", 2.8 + math.random())
        sim.partProperty(p, "vx", 0)
        return true
      end
    end
    return false
  end
  local function seekHollow(maxDy)
    local dist = sx - tsx
    if dist == 0 then return fallInHollow(maxDy) end
    local step = dist > 0 and 1 or -1
    for dy = 0, maxDy or 14 do
      for _, dx in ipairs({step, step * 2, 0}) do
        local tx, ty = sx + dx, sy + dy
        if screenOK(tx, ty) and not sim.partID(tx, ty) then
          sim.partProperty(p, "x", tx)
          if dy > 0 then sim.partProperty(p, "y", ty) end
          sim.partProperty(p, "vx", step * (2.2 + math.random()))
          sim.partProperty(p, "vy", 2.5 + dy * 0.35 + math.random())
          return true
        end
      end
    end
    return false
  end
  local function slideTowardHollow(vyBoost)
    if sx ~= tsx then sim.partProperty(p, "vx", (tsx - sx) * 1.15) end
    if screenOK(sx, sy + 1) and not sim.partID(sx, sy + 1) then
      sim.partProperty(p, "y", sy + 1); sim.partProperty(p, "vy", vyBoost or 3)
      return true
    end
    if sx ~= tsx and screenOK(tsx, sy + 1) and not sim.partID(tsx, sy + 1) then
      sim.partProperty(p, "x", tsx); sim.partProperty(p, "y", sy + 1)
      sim.partProperty(p, "vy", vyBoost or 3.2)
      sim.partProperty(p, "vx", 0)
      return true
    end
    return false
  end
  local function soakRootMoisture(amount)
    if nm ~= "WATR" and nm ~= "GOO" then return false end
    if wy < q.s - 1 then return false end
    for dy = 0, 10 do
      local rx, ry = tsx, sy + dy
      if screenOK(rx, ry) then
        local bp = sim.partID(rx, ry)
        local bnm = bp and nameOf(sim.partProperty(bp, "type"))
        if bnm == "GOO" and math.random() < 0.55 then
          sim.partKill(p)
          R.treeMoisture = R.treeMoisture or {}
          local key = drain .. "," .. q.s
          R.treeMoisture[key] = min(100, (R.treeMoisture[key] or 0) + amount)
          return true
        end
      end
    end
    return false
  end
  local function addTreeMoisture(amount)
    R.treeMoisture = R.treeMoisture or {}
    local key = drain .. "," .. q.s
    R.treeMoisture[key] = min(100, (R.treeMoisture[key] or 0) + amount)
  end
  if q.gapFloor then
    local dist = math.abs(sx - tsx)
    if dist > 0 and dist <= 14 then
      sim.partProperty(p, "vx", (tsx - sx) * 2.0)
      if dist <= 3 and screenOK(tsx, sy) and not sim.partID(tsx, sy) then
        sim.partProperty(p, "x", tsx); sim.partProperty(p, "y", sy)
        sim.partProperty(p, "vy", 2.8 + math.random()); sim.partProperty(p, "vx", 0)
        return
      end
    end
    if seekHollow(18) then return end
    if fallInHollow(20, true) then return end
    if slideTowardHollow(3.8) then return end
    if soakRootMoisture(5) then return end
    if nm == "WATR" and math.random() < 0.42 then
      addTreeMoisture(4)
      sim.partKill(p)
    end
    return
  end
  if q.canopy or q.poolOnCanopy or q.poolOnTrunk or q.trunkWood then
    if seekHollow(24) then return end
    if fallInHollow(32) then return end
    if slideTowardHollow(4.0) then return end
    if nm == "BLD" and math.random() < 0.55 then
      local side = sx + (math.random(0, 1) == 0 and -1 or 1)
      if screenOK(side, sy + 1) and not sim.partID(side, sy + 1) then
        sim.partProperty(p, "x", side); sim.partProperty(p, "y", sy + 1)
        sim.partProperty(p, "vy", 3 + math.random())
        return
      end
    end
    if screenOK(sx, sy + 1) and not sim.partID(sx, sy + 1) then
      sim.partProperty(p, "y", sy + 1); sim.partProperty(p, "vy", 3 + math.random())
    elseif (nm == "WATR" or nm == "GOO") and math.random() < 0.52 then
      addTreeMoisture(3)
      sim.partKill(p)
    end
    return
  end
  if q.inHollow or (q.hollowCol and wx == q.hollowCol) then
    if fallInHollow(14) then return end
    if wy >= q.s - 2 and (nm == "WATR" or nm == "GOO") then
      for dy = 0, 10 do
        local rx, ry = tsx, sy + dy
        if screenOK(rx, ry) then
          local bp = sim.partID(rx, ry)
          local bnm = bp and nameOf(sim.partProperty(bp, "type"))
          if bnm == "GOO" then
            sim.partKill(p)
            addTreeMoisture(6)
            return
          end
          if not bp and dy <= 3 then
            sim.partProperty(p, "x", rx); sim.partProperty(p, "y", ry); return
          end
        end
      end
      if math.random() < 0.38 then
        addTreeMoisture(2)
        sim.partKill(p)
      end
    end
  end
  if wy >= q.s - 1 then
    for dy = 1, 10 do for dx = -8, 8 do
      local rx, ry = wx + dx - R.cam.x, sy + dy
      if screenOK(rx, ry) then
        local bp = sim.partID(rx, ry)
        local bnm = bp and nameOf(sim.partProperty(bp, "type"))
        if not bp and dy <= 4 then
          sim.partProperty(p, "x", rx); sim.partProperty(p, "y", ry)
          sim.partProperty(p, "vy", 2); return
        end
        if bnm == "GOO" and (nm == "WATR" or nm == "GOO") and math.random() < 0.62 then
          sim.partKill(p)
          addTreeMoisture(6)
          return
        end
        local wwx, wwy = wx + dx, wy + dy
        if nm == "WATR" and (R.treeRootSoakAt and R.treeRootSoakAt(wwx, wwy) or R.treeAquiferAt and R.treeAquiferAt(wwx, wwy))
            and bnm == "GOO" and math.random() < 0.58 then
          sim.partKill(p)
          addTreeMoisture(5)
          return
        end
      end
    end end
  end
end
treeAquiferSpreadTick = function()
  if sim.paused() or R.frame % 8 ~= 0 then return end
  local wt = eid("WATR")
  R.treeMoisture = R.treeMoisture or {}
  for key, m in pairs(R.treeMoisture) do
    if m > 0 then
      local hx, s = key:match("^(-?%d+),(-?%d+)$")
      if hx then
        hx, s = tonumber(hx), tonumber(s)
        local chance = 0.22 * (m / 100)
        for dx = -8, 8 do
          for d = 1, 20 do
            local wwx, wwy = hx + dx, s + d
            local aquifer = R.treeAquiferAt and R.treeAquiferAt(wwx, wwy)
            local soak = (R.treeRootSoakAt and R.treeRootSoakAt(wwx, wwy)) or aquifer
            if soak and math.random() < chance then
              local sx, sy = wwx - R.cam.x, wwy - R.cam.y
              if screenOK(sx, sy) then
                local bp = sim.partID(sx, sy)
                local bnm = bp and nameOf(sim.partProperty(bp, "type"))
                if bnm == "GOO" and wt then
                  for _, off in ipairs({{0,1},{1,0},{-1,0},{1,1},{-1,1},{0,-1}}) do
                    local nx, ny = sx + off[1], sy + off[2]
                    if screenOK(nx, ny) and not sim.partID(nx, ny) then
                      local np = sim.partCreate(-1, nx, ny, wt)
                      if np and np >= 0 then
                        sim.partProperty(np, "vy", 0.15)
                        sim.partProperty(np, "life", 90)
                      end
                      break
                    end
                  end
                elseif not bp and aquifer and wt and m > 18 and math.random() < 0.35 then
                  local rq = R.treeRootVeinQuery and R.treeRootVeinQuery(wwx, wwy)
                  if rq and rq.inHollow then
                    local np = sim.partCreate(-1, sx, sy, wt)
                    if np and np >= 0 then
                      sim.partProperty(np, "vy", 0.1)
                      sim.partProperty(np, "life", 70)
                    end
                  end
                end
              end
            end
          end
        end
      end
      R.treeMoisture[key] = max(0, m - 0.15)
    end
  end
end
treeHollowDripTick = function()
  if sim.paused() then return end
  local raining = R.weather and R.weather.rain
  local wt = eid("WATR")
  if not wt then return end
  if raining then
    for i = 1, 36 do
      local sx = math.random(M + 2, W - M - 3)
      local sy = math.random(M + 2, H - M - 3)
      local wx, wy = sx + R.cam.x, sy + R.cam.y
      local q = R.treeVegQuery and R.treeVegQuery(wx, wy)
      if not q or not q.inHollow then goto thd_next end
      if sim.partID(sx, sy) then goto thd_next end
      local p = sim.partCreate(-1, sx, sy, wt)
      if p and p >= 0 then
        sim.partProperty(p, "vy", 1.0 + math.random() * 1.2)
        sim.partProperty(p, "vx", (math.random() - 0.5) * 0.2)
        R.treeMoisture = R.treeMoisture or {}
        local drain = q.hollowCol or wx
        local key = drain .. "," .. q.s
        R.treeMoisture[key] = min(100, (R.treeMoisture[key] or 0) + 2.5)
      end
      ::thd_next::
    end
    for i = 1, 14 do
      local sx = math.random(M + 2, W - M - 3)
      local wx = sx + R.cam.x
      local surf = surfaceAt(wx)
      local q = R.treeShadeDrain and R.treeShadeDrain(wx, surf - 1)
      if not q or not q.hollowCol then goto thd_top_next end
      local hx = q.hollowCol - R.cam.x
      local topWy = q.top or (q.s - 6)
      local hy = topWy - R.cam.y
      if not screenOK(hx, hy) or sim.partID(hx, hy) then goto thd_top_next end
      local p = sim.partCreate(-1, hx, hy, wt)
      if p and p >= 0 then
        sim.partProperty(p, "vy", 2.2 + math.random())
        R.treeMoisture = R.treeMoisture or {}
        local key = q.hollowCol .. "," .. q.s
        R.treeMoisture[key] = min(100, (R.treeMoisture[key] or 0) + 3)
      end
      ::thd_top_next::
    end
  end
  -- Moisture-driven aquifer seep: retain subsurface WATR when treeMoisture is high (no rain needed).
  if R.frame % 16 == 0 then
    R.treeMoisture = R.treeMoisture or {}
    for key, m in pairs(R.treeMoisture) do
      if m < 22 then goto tas_next end
      local hx, s = key:match("^(-?%d+),(-?%d+)$")
      if not hx then goto tas_next end
      hx, s = tonumber(hx), tonumber(s)
      for t = 1, 3 do
        local dx = math.random(-6, 6)
        local d = 4 + math.random(0, 14)
        local wwx, wwy = hx + dx, s + d
        if not (R.treeAquiferAt and R.treeAquiferAt(wwx, wwy)) then goto tas_try_next end
        local sx, sy = wwx - R.cam.x, wwy - R.cam.y
        if not screenOK(sx, sy) then goto tas_try_next end
        local bp = sim.partID(sx, sy)
        if bp then goto tas_try_next end
        local np = sim.partCreate(-1, sx, sy, wt)
        if np and np >= 0 then
          sim.partProperty(np, "vy", 0.08)
          sim.partProperty(np, "life", 85)
        end
        ::tas_try_next::
      end
      ::tas_next::
    end
  end
end
canopyPoolDrainTick = function()
  if sim.paused() then return end
  local raining = R.weather and R.weather.rain
  local bandWx = floor(R.P.x)
  for i = 1, raining and 220 or 90 do
    local wx = bandWx - 140 + math.random(0, 280)
    local surf = R.surfaceAt and R.surfaceAt(wx) or (R.P and R.P.y)
    local wy = surf - math.random(2, 22)
    local q = R.treeShadeDrain and R.treeShadeDrain(wx, wy)
    if not q then
      q = R.treeVegQuery and R.treeVegQuery(wx, wy)
      if not q or not q.poolOnCanopy then goto cpd_next end
    elseif not q.poolOnCanopy then goto cpd_next end
    local sx, sy = wx - R.cam.x, wy - R.cam.y
    if sx < 2 or sx >= W - 3 or sy < 2 or sy >= H - 3 then goto cpd_next end
    local p = sim.partID(sx, sy)
    if not p then goto cpd_next end
    local nm = nameOf(sim.partProperty(p, "type"))
    if nm ~= "WATR" and nm ~= "GOO" then goto cpd_next end
    local vx, vy = sim.partProperty(p, "vx") or 0, sim.partProperty(p, "vy") or 0
    if math.abs(vx) > 1.8 or math.abs(vy) > 2.2 then goto cpd_next end
    routeTreeLiquid(p, sx, sy, wx, wy, q, nm)
    ::cpd_next::
  end
end
treeGapGasVentTick = function()
  if sim.paused() then return end
  local GAS = { OXYG=1, CO2=1, SMKE=1 }
  local n = 48
  for i = 1, n do
    local sx, sy
  if i <= n * 0.7 then
      local wx = floor(R.P.x) - 100 + math.random(0, 200)
      local surf = R.surfaceAt and R.surfaceAt(wx) or (R.P and R.P.y)
      sx = wx - R.cam.x
      sy = surf - R.cam.y + math.random(-2, 4)
    else
      sx, sy = math.random(2, W - 3), math.random(2, H - 3)
    end
    if sx < 2 or sx >= W - 3 or sy < 2 or sy >= H - 3 then goto tgv_next end
    local p = sim.partID(sx, sy)
    if not p then goto tgv_next end
    local nm = nameOf(sim.partProperty(p, "type"))
    if not GAS[nm] then goto tgv_next end
    local wx, wy = sx + R.cam.x, sy + R.cam.y
    local q = R.nearestTreeDrain and R.nearestTreeDrain(wx, wy)
    if not q or not q.gapFloor then
      q = R.treeShadeDrain and R.treeShadeDrain(wx, wy)
      if not q or not q.poolOnCanopy then goto tgv_next end
    end
    local vy = sim.partProperty(p, "vy") or 0
    if vy > -0.5 then
      sim.partProperty(p, "vy", -2.2 - math.random() * 1.5)
    end
    local drain = q.hollowCol or (q.x0 + floor((q.tw or 2) / 2))
    local tsx = drain - R.cam.x
  sim.partProperty(p, "vx", (tsx - sx) * 0.35 + (sim.partProperty(p, "vx") or 0) * 0.5)
    ::tgv_next::
  end
end
gapPoolDrainTick = function()
  if sim.paused() then return end
  local raining = R.weather and R.weather.rain
  local n = raining and 260 or 70
  -- Bias samples toward surface band under the camera (gap pools are tiny vs whole screen).
  local bandWx = floor(R.P.x)
  for i = 1, n do
    local sx, sy
    if i <= n * 0.65 then
      local wx = bandWx - 100 + math.random(0, 200)
      local surf = R.surfaceAt and R.surfaceAt(wx) or (R.P and R.P.y)
      sx = wx - R.cam.x
      sy = surf - R.cam.y + math.random(-1, 2)
    else
      sx, sy = math.random(2, W - 3), math.random(2, H - 3)
    end
    if sx < 2 or sx >= W - 3 or sy < 2 or sy >= H - 3 then goto gpd_next end
    local p = sim.partID(sx, sy)
    if not p then goto gpd_next end
    local nm = nameOf(sim.partProperty(p, "type"))
    if nm ~= "WATR" then goto gpd_next end
    local vx, vy = sim.partProperty(p, "vx") or 0, sim.partProperty(p, "vy") or 0
    if math.abs(vx) > 0.55 or math.abs(vy) > 0.55 then goto gpd_next end
    local wx, wy = sx + R.cam.x, sy + R.cam.y
    local q = R.nearestTreeDrain and R.nearestTreeDrain(wx, wy)
    if not q or not q.gapFloor then goto gpd_next end
    routeTreeLiquid(p, sx, sy, wx, wy, q, nm)
    ::gpd_next::
  end
end
treeWaterVeinsTick = function()
  if sim.paused() then return end
  local raining = R.weather and R.weather.rain
  local n = raining and 300 or 100
  local bandWx = floor(R.P.x)
  for i = 1, n do
    local sx, sy = math.random(2, W - 3), math.random(2, H - 3)
    if raining and i <= 60 then
      for _ = 1, 8 do
        local wx = sx + R.cam.x
        local wy = sy + R.cam.y
        local gq = R.nearestTreeDrain and R.nearestTreeDrain(wx, wy)
        if gq and gq.gapFloor then break end
        local surf = R.surfaceAt and R.surfaceAt(bandWx) or (R.P and R.P.y)
        sx = bandWx - 100 + math.random(0, 200) - R.cam.x
        sy = surf - R.cam.y + math.random(-2, 18)
      end
    end
    local p = sim.partID(sx, sy)
    if not p then goto twv_next end
    local nm = nameOf(sim.partProperty(p, "type"))
    if not TREE_LIQ[nm] then goto twv_next end
    local vx, vy = sim.partProperty(p, "vx") or 0, sim.partProperty(p, "vy") or 0
    if math.abs(vx) > 2.2 or math.abs(vy) > 2.8 then goto twv_next end
    local wx, wy = sx + R.cam.x, sy + R.cam.y
    local q = treeOnSurface(wx, wy)
    if not q then goto twv_next end
    routeTreeLiquid(p, sx, sy, wx, wy, q, nm)
    ::twv_next::
  end
end
-- Cave/mining liquid settle: fast mode disables native water equalisation, so water
-- mined out of saturated rock can hang in midair. Nudge resting liquids down (or
-- give them downward velocity) when the cell below is open or pass-through.
local LIQUID_SET = { WATR=1, DSTW=1, SLTW=1, OIL=1, BLD=1 }
local function isLiquidPart(p)
  return p and LIQUID_SET[nameOf(sim.partProperty(p, "type"))] == 1
end
local function liquidCanFall(sx, sy)
  if sy >= H - M - 1 then return false end
  local below = sim.partID(sx, sy + 1)
  if not below then return true end
  return PASS[nameOf(sim.partProperty(below, "type"))] ~= nil
end
local function nudgeLiquidParticle(p, sx, sy)
  if not liquidCanFall(sx, sy) then return end
  if not sim.partID(sx, sy + 1) then
    sim.partProperty(p, "x", sx); sim.partProperty(p, "y", sy + 1)
    sim.partProperty(p, "vy", 2 + math.random() * 2)
    sim.partProperty(p, "vx", (sim.partProperty(p, "vx") or 0) * 0.5)
  else
    local vy = sim.partProperty(p, "vy") or 0
    sim.partProperty(p, "vy", math.max(vy, 2 + math.random() * 2))
  end
end
nudgeLiquidsNear = function(wx, wy, radius)
  if sim.paused() then return end
  local rad = radius or 8
  for y = wy - rad, wy + rad do for x = wx - rad, wx + rad do
    local sx, sy = x - R.cam.x, y - R.cam.y
    if sx >= M and sx < W - M and sy >= M and sy < H - M then
      local p = sim.partID(sx, sy)
      if isLiquidPart(p) then nudgeLiquidParticle(p, sx, sy) end
    end
  end end
end
R.nudgeLiquidsNear = nudgeLiquidsNear
settleLiquidsTick = function()
  if sim.paused() or R.frame % 3 == 0 then return end
  for i = 1, 30 do
    local sx, sy = math.random(M + 1, W - M - 2), math.random(M + 1, H - M - 2)
    local p = sim.partID(sx, sy)
    if isLiquidPart(p) then
      local vx, vy = sim.partProperty(p, "vx") or 0, sim.partProperty(p, "vy") or 0
      if math.abs(vx) < 2.5 and math.abs(vy) < 3.5 then
        local wx, wy = sx + R.cam.x, sy + R.cam.y
        local q = treeOnSurface(wx, wy)
        if q then
          routeTreeLiquid(p, sx, sy, wx, wy, q, nameOf(sim.partProperty(p, "type")))
        else
          nudgeLiquidParticle(p, sx, sy)
        end
      end
    end
  end
end
-- ONI-like environmental baseline: biome surface temp + geothermal gradient + pocket noise.
-- Returns Kelvin baseline and pressure offset at world coords (per-column depth).
local BIOME_SURF_K = { snow = 268, desert = 308, swamp = 298, forest = 294 }
local function envBaseAt(wx, wy)
  wx, wy = floor(wx), floor(wy)
  local surf = surfaceAt(wx)
  local depth = wy - surf
  local biome = biomeAt(wx)
  local surfK = BIOME_SURF_K[biome] or 294
  local geoK, geoP
  if depth < 0 then
    geoK = surfK - depth * 0.22
    geoP = 2.2 - depth * 0.1
  else
    local gradMul = biome == "snow" and 0.72 or biome == "desert" and 1.16 or biome == "swamp" and 1.06 or 1.0
    geoK = surfK + depth * 0.034 * gradMul
    if depth > 850 then geoK = geoK + (depth - 850) * 0.05 end
    if depth > 1200 then geoK = geoK + (depth - 1200) * 0.11 end
    geoK = geoK + (vnoise(wx / 38, wy / 38, 1842) - 0.5) * 24
    if R.pocketEnvBias then
      local tOff, pOff = R.pocketEnvBias(wx, wy, depth)
      geoK = geoK + (tOff or 0)
      geoP = (pOff or 0)
    else
      geoP = 0
    end
    geoP = 2.0 + depth * 0.015 + (geoP or 0)
  end
  return geoK, geoP, depth, biome
end
R.envBaseAt = envBaseAt
sampleEnvGradient = function()
  local px, py = floor(R.P.x), floor(R.P.y)
  local surfY = surfaceAt(px)
  local playerDepth = py - surfY
  local tMin, tMax, tSum, tN = 1e9, -1e9, 0, 0
  local pMin, pMax, pSum, pN = 1e9, -1e9, 0, 0
  local gMin, gMax, gSum, gN = 1e9, -1e9, 0, 0
  local function sampleAt(wx, wy)
    local geoK, geoP = envBaseAt(wx, wy)
    gMin = math.min(gMin, geoK); gMax = math.max(gMax, geoK); gSum = gSum + geoK; gN = gN + 1
    local sx, sy = wx - R.cam.x, wy - R.cam.y
    local t = geoK
    if sx >= M and sx < W - M and sy >= M and sy < H - M then
      local p = sim.partID(sx, sy)
      if p then t = sim.partProperty(p, "temp") or t end
    end
    tMin = math.min(tMin, t); tMax = math.max(tMax, t); tSum = tSum + t; tN = tN + 1
    local pcx, pcy = floor(wx / sim.CELL), floor(wy / sim.CELL)
    local pr = geoP
    local ok, cur = pcall(sim.pressure, pcx, pcy)
    if ok and type(cur) == "number" then pr = cur end
    pMin = math.min(pMin, pr); pMax = math.max(pMax, pr); pSum = pSum + pr; pN = pN + 1
  end
  for oy = -28, 28, 4 do for ox = -32, 32, 4 do
    sampleAt(px + ox, py + oy)
  end end
  -- ONI-like depth column: surface air through geothermal deep (not just a flat local bubble).
  local colDepth = math.max(100, math.min(560, playerDepth + 360))
  for _, ox in ipairs({0, -64, 64, -128, 128}) do
    for dy = -28, colDepth, 16 do
      sampleAt(px + ox, surfY + dy)
    end
  end
  R.env = {
    tempMin = tMin, tempMax = tMax, tempAvg = tSum / math.max(1, tN),
    pressMin = pMin, pressMax = pMax, pressAvg = pSum / math.max(1, pN),
    geoMin = gMin, geoMax = gMax, geoAvg = gSum / math.max(1, gN),
    depth = playerDepth,
  }
  R.feltTempK = R.env.tempAvg
end
geoAmbienceTick = function()
  if sim.paused() or R.frame % 18 ~= 0 then return end
  for _ = 1, 14 do
    local sx, sy = math.random(M + 2, W - M - 3), math.random(M + 2, H - M - 3)
    local wx, wy = sx + R.cam.x, sy + R.cam.y
    local geoK, geoP, depth = envBaseAt(wx, wy)
    if depth < 22 then goto geo_next end
    local pcx, pcy = floor(wx / sim.CELL), floor(wy / sim.CELL)
    if not sim.partID(sx, sy) then
      local ok, curP = pcall(sim.pressure, pcx, pcy)
      if ok and type(curP) == "number" and math.abs(curP - geoP) > 0.35 then
        pcall(sim.pressure, pcx, pcy, curP + (geoP - curP) * 0.14)
      end
    end
    for _, d in ipairs({{0,0},{1,0},{-1,0},{0,1},{0,-1}}) do
      local p = sim.partID(sx + d[1], sy + d[2])
      if p then
        local n = nameOf(sim.partProperty(p, "type"))
        if n == "OXYG" or n == "CO2" or n == "GAS" or n == "SMKE" or n == "WTRV" or n == "H2" then
          local t = sim.partProperty(p, "temp") or geoK
          if math.abs(t - geoK) > 2.5 then
            sim.partProperty(p, "temp", t + (geoK - t) * 0.11)
          end
        end
      end
    end
    ::geo_next::
  end
end
depthPressureTick = function()
  if sim.paused() or R.frame % 50 ~= 0 then return end
  local px = floor(R.P.x)
  for _ = 1, 7 do
    local wx = px + math.random(-100, 100)
    local surf = surfaceAt(wx)
    local wy = surf + math.random(80, math.min(1500, DEPTH - 120))
    local _, geoP = envBaseAt(wx, wy)
    local sx, sy = wx - R.cam.x, wy - R.cam.y
    if sx >= M and sx < W - M and sy >= M and sy < H - M and not sim.partID(sx, sy) then
      local pcx, pcy = floor(wx / sim.CELL), floor(wy / sim.CELL)
      local ok, cur = pcall(sim.pressure, pcx, pcy)
      if ok and type(cur) == "number" and cur < geoP - 0.8 then
        pcall(sim.pressure, pcx, pcy, math.min(geoP, cur + 1.4))
      end
    end
  end
end
absorbStandingWater = function()
  if sim.paused() or R.frame % 4 ~= 0 then return end
  local bandWx = floor(R.P.x)
  for i = 1, 32 do
    local sx, sy
    if i <= 20 then
      local wx = bandWx - 120 + math.random(0, 240)
      local surf = R.surfaceAt and R.surfaceAt(wx) or (R.P and R.P.y)
      sx = wx - R.cam.x
      sy = surf - R.cam.y + math.random(-2, 16)
    else
      sx, sy = math.random(2, W - 3), math.random(2, H - 3)
    end
    local p = sim.partID(sx, sy)
    if not p then goto abs_next end
    local pnm = nameOf(sim.partProperty(p, "type"))
    if pnm ~= "WATR" and pnm ~= "BLD" then goto abs_next end
    local vx, vy = sim.partProperty(p, "vx") or 0, sim.partProperty(p, "vy") or 0
    if math.abs(vx) >= 0.65 or math.abs(vy) >= 0.65 then goto abs_next end
    local wx, wy = sx + R.cam.x, sy + R.cam.y
    local tq = treeOnSurface(wx, wy)
    if not tq and R.treeShadeDrain then
      tq = R.treeShadeDrain(wx, wy)
    end
    if tq then
      if tq.gapFloor or tq.canopy or tq.poolOnCanopy or tq.poolOnTrunk or tq.inHollow then
        routeTreeLiquid(p, sx, sy, wx, wy, tq, pnm)
      end
      goto abs_next
    end
    local below = sim.partID(sx, sy + 1)
    local nm = below and nameOf(sim.partProperty(below, "type"))
    if nm == "WOOD" and treeVegAt(wx, wy + 1) then goto abs_next end
    if nm == "GRSS" and treeVegAt(wx, wy + 1) and treeVegAt(wx, wy + 1).canopy then goto abs_next end
    if nm and ABSORBENT[nm] and math.random() < 0.2 then sim.partKill(p) end
    ::abs_next::
  end
end
R.absorbStandingWater = absorbStandingWater
R.treeHollowDripTick = treeHollowDripTick
R.canopyPoolDrainTick = canopyPoolDrainTick
R.treeGapGasVentTick = treeGapGasVentTick
R.gapPoolDrainTick = gapPoolDrainTick
R.treeWaterVeinsTick = treeWaterVeinsTick
R.treeAquiferSpreadTick = treeAquiferSpreadTick
-- ---- delayed cavity air-fill (v1.15.41/43) -----------------------------
local function columnOpenToSky(wx, wy)
  local surf = surfaceAt(wx)
  -- Only skip the upward scan when surface is farther than we can reach (k up to 90).
  -- v1.15.58 fast-reject at surf+10 broke shallow dug shafts: vent never reached 1,
  -- OXYG spawned at vent>0.45, but stale-air math still suffocated the player.
  if wy > surf + 88 then return false end
  local blocked, seen = 0, 0
  for k = 4, 90, 3 do
    local sx, sy = wx - R.cam.x, wy - k - R.cam.y
    if sx >= M and sx < W - M and sy >= M and sy < H - M then
      seen = seen + 1
      local p = sim.partID(sx, sy)
      if p then local n = nameOf(sim.partProperty(p, "type")); if not PASS[n] then blocked = blocked + 1 end end
    end
  end
  if seen < 3 then return false end   -- off-screen / too few samples: don't assume open sky
  return blocked <= 1
end
function R.ventilationAt(wx, wy)
  wx, wy = floor(wx), floor(wy)
  local e = R.pendingAir[wx .. "," .. wy]
  if e then return e.vent end
  local sx, sy = wx - R.cam.x, wy - R.cam.y
  if sx >= M and sx < W - M and sy >= M and sy < H - M then
    if not sim.partID(sx, sy) then return 1 end
    return 0
  end
  return columnOpenToSky(wx, wy) and 1 or 0
end
local function digPressMul(wx)
  if R.treeCoversColumn and R.treeCoversColumn(wx) then return 0.12 end
  return 1
end
function R.queuePendingAir(wx, wy, nearLiquid)
  wx, wy = floor(wx), floor(wy)
  local k = wx .. "," .. wy
  if R.pendingAir[k] then return end
  local n = 0; for _ in pairs(R.pendingAir) do n = n + 1; if n >= R.AIR_PENDING_MAX then return end end
  local startVent = columnOpenToSky(wx, wy) and 1 or 0
  if startVent < 1 then
    for _, d in ipairs({{0, 1}, {0, -1}, {1, 0}, {-1, 0}}) do
      startVent = math.max(startVent, R.ventilationAt(wx + d[1], wy + d[2]) * 0.4)
    end
  end
  R.pendingAir[k] = { x = wx, y = wy, vent = startVent, born = R.frame or 0, liq = nearLiquid and true or false }
  local pcx, pcy = floor(wx / sim.CELL), floor(wy / sim.CELL)
  local press = (nearLiquid and R.AIR_DIG_PRESS_LIQ or (R.AIR_DIG_PRESS_MAX * (1 - startVent))) * digPressMul(wx)
  pcall(sim.pressure, pcx, pcy, press)
end
pendingAirTick = function()
  if R.frame % R.AIR_VENT_TICK ~= 0 then return end
  local rate = R.AIR_VENT_RATE * R.AIR_VENT_TICK
  local remove = {}
  for key, e in pairs(R.pendingAir) do
    local sx, sy = e.x - R.cam.x, e.y - R.cam.y
    if sx >= M and sx < W - M and sy >= M and sy < H - M and sim.partID(sx, sy) then
      remove[#remove + 1] = key
    else
      local best = columnOpenToSky(e.x, e.y) and 1 or 0
      for _, d in ipairs({{0, 1}, {0, -1}, {1, 0}, {-1, 0}}) do
        best = math.max(best, R.ventilationAt(e.x + d[1], e.y + d[2]))
      end
      if best > e.vent then e.vent = math.min(1, e.vent + (best - e.vent) * rate) end
      -- Ventilated shaft: spawn visible OXYG so meter + HUD circle match what you see.
      if e.vent > 0.45 and R.frame % 25 == 0 and o2OnScreenCount() < 220 then
        local oxid = eid("OXYG")
        if oxid and math.random() < e.vent * 0.4 then
          local asx, asy = e.x - R.cam.x, e.y - R.cam.y
          if asx >= M and asx < W - M and asy >= M and asy < H - M and not sim.partID(asx, asy) then
            sim.partCreate(-1, asx, asy, oxid)
          end
        end
      end
      if e.vent >= 0.995 then remove[#remove + 1] = key
      else
        local pcx, pcy = floor(e.x / sim.CELL), floor(e.y / sim.CELL)
        local press = (e.liq and R.AIR_DIG_PRESS_LIQ or R.AIR_DIG_PRESS_MAX) * (1 - e.vent) * digPressMul(e.x)
        pcall(sim.pressure, pcx, pcy, press)
      end
    end
  end
  for i = 1, #remove do R.pendingAir[remove[i]] = nil end
end
R.pendingAirTick = pendingAirTick
end -- tree/liquid/env local-scope chunk (hot-reload local cap)
-- Hot-reload rpg.lua from disk with zero process restart. event.register/
-- unregister (needed to rebind onTick/onKeyDown/etc to the freshly-loaded
-- closures -- without this, the engine keeps calling the OLD, stale
-- versions forever) require real interface-event context; a bridge-driven
-- executeLua call doesn't have that, but a real TICK event does. So this
-- only ever runs from inside onTick itself (R.hotReloadRequested, settable
-- from the bridge OR via the F9 key below), never called directly.
-- Position/inventory/world all survive because of the reload-guard at the
-- very top of this file (old.version == 4 reuses the live R table).
local function hotReloadCore()
  -- Defensive reset: if the real mouse button was released right around a reload, the OS
  -- only sends one up-event and the fresh onMouseUp closure installed by this reload can
  -- miss it, leaving R.mouse.l/r (preserved across reload by the isolated-state guard)
  -- stuck true forever -- every subsequent mouse move then reads as a held click, spamming
  -- placement/mining everywhere ("stuck down... spawning bullshit everywhere"). There's no
  -- real polling API to check the actual current button state (checked: tpt.mouseb/
  -- tpt.input don't exist), so the safe default is to assume NOT held across a reload --
  -- worst case a genuinely-still-held click needs one extra press after a reload, which is
  -- far better than an indefinite stuck-click bug.
  R.mouse = R.mouse or {}; R.mouse.l = false; R.mouse.r = false
  local paths = { "../scripts/lua/rpg.lua", "scripts/lua/rpg.lua", "D:/The-Powder-Toy/scripts/lua/rpg.lua", "D:/powder-toy/scripts/lua/rpg.lua" }
  local path, f
  for _, p in ipairs(paths) do f = io.open(p, "r"); if f then path = p; break end end
  if not f then say("Hot reload: rpg.lua not found"); return end
  local code = f:read("*a"); f:close()
  local fn, lerr = loadstring(code)
  if not fn then say("Hot reload: load error - " .. tostring(lerr)); return end
  local ok, rerr = pcall(fn)
  say(ok and "Hot-reloaded rpg.lua" or ("Hot reload error: " .. tostring(rerr)))
  -- checkLocalChangelog otherwise only runs when a new world generates (R.pendingGen),
  -- so hot-reloading straight through several version bumps in one sitting (which is
  -- now the normal workflow) never showed the changelog at all until the next "New
  -- Seed"/restart -- where it then dumped every version at once, unprompted, looking
  -- like something had gone wrong ("it reset my version") rather than "here's what
  -- changed since you last checked."
  if ok then pcall(R.checkLocalChangelog) end
end
local function onTick()
  if R.hotReloadRequested then R.hotReloadRequested = false; hotReloadCore(); return end
  -- BOOT SELF-HEAL, other half of the negative-cache fix above. By this frame the registry
  -- has drained its queue, so the elements this file gave up on at load time now genuinely
  -- exist. Drop the cached misses and re-ask; if an element that was missing has appeared,
  -- request exactly ONE core reload so every top-level constant (ROCK, GRASS, UORE, HASCU and
  -- the rest) is re-evaluated with the real element table. This is the same hot-reload path
  -- that already makes these constants correct on a development machine -- the only reason
  -- the bug never showed up locally is that reloading masked it every single time.
  -- Runs once per session, gated on a flag, and only fires the reload when something actually
  -- changed, so a build with no custom elements pays nothing.
  -- Own counter, NOT R.frame: R.frame is only incremented further down, AFTER
  -- `if not R.active then return end`, so it stays nil on the title screen. Gating on it
  -- meant the heal could not fire until a world was already running -- by which point
  -- worldgen has already baked the wrong ROCK constant into the terrain it just generated.
  -- This counter advances on every tick from the moment the game boots, so the reload lands
  -- while the player is still looking at the menu.
  -- Fill the inventory once the RPG test world actually exists. Deferred to a tick because the
  -- world is generated asynchronously via R.pendingGen -- granting before that would push items
  -- into an inventory that the world start then resets.
  if R.sbGrantAll and R.active and not R.pendingGen then
    R.sbGrantAll = nil
    local n = 0
    for code in pairs(R.NAMES or {}) do pcall(R.give, code, 200); n = n + 1 end
    for _, t in ipairs({ R.PICKS, R.SWORDS }) do
      for _, it in ipairs(t or {}) do if it.name then pcall(R.give, it.name, 1) end end
    end
    say("Granted " .. n .. " materials x200 for testing.")
  end
  R.bootTicks = (R.bootTicks or 0) + 1
  -- Keep R.frame advancing even when no world is running. It is incremented further down, but
  -- only AFTER `if not R.active then return end`, so at the title screen it stays nil forever.
  -- Plugins that schedule work on a frame count therefore never run: reactions.lua reported
  -- "install pass has NOT yet run (frame nil), 10 symbol(s) still pending" -- its cited alkali,
  -- alkaline-earth and halogen reactions were loaded but never installed onto any element, which
  -- is exactly the "I put powders down and added water and nothing reacted" report.
  -- Only advances it when the normal path will not, so in-world timing is untouched.
  if not R.active and not R.sandboxMode then
    R.frame = (R.frame or 0) + 1
    -- Plugin tick hooks are dispatched at the BOTTOM of this function, long after
    -- `if not R.active then return end` -- so with no world running, all 35 of them are dead.
    -- That is why reactions.lua kept reporting "install pass has NOT yet run": its cited alkali,
    -- alkaline-earth and halogen reactions were loaded but never installed onto any element,
    -- which is exactly the "I put powders down, added water, and nothing reacted" report.
    -- Plugins legitimately need a heartbeat for install/setup work that does not depend on a
    -- world existing, so give them one here. In-world dispatch below is untouched.
    local okh = pcall(runHooks, R.hooks.tick)
    if not okh and PBX and PBX.log then PBX.log("tick", "idle tick hook pass raised an error") end
  end
  if not R.bootHealDone and R.bootTicks > 120 then
    R.bootHealDone = true
    local before = { BSLT = has("BSLT"), GRSS = has("GRSS"), DU = has("DU"), CU = has("CU"), STEL = has("STEL") }
    R.clearIdCache()
    local changed = {}
    for n, was in pairs(before) do if not was and has(n) then changed[#changed + 1] = n end end
    if #changed > 0 then
      -- PBX.log, not R.tlog: this must land in autorun-runtime.log, the one file that exists
      -- on a plain downloaded copy with no telemetry plugin and no bridge. Diagnosing this
      -- class of bug on a stranger's machine is otherwise impossible.
      if PBX and PBX.log then PBX.log("boot", "late element registration (" .. table.concat(changed, ",") .. ") -- reloading core so element constants re-resolve") end
      if R.tlog then R.tlog("warn", "boot", "late element registration -- reloading core", { elements = table.concat(changed, ",") }) end
      R.hotReloadRequested = true
      return
    end
  end
  -- Sandbox mode runs NOTHING of the RPG. onDraw already returns early on `not R.active`,
  -- but onTick has never had that guard -- without this, choosing "Sandbox" would still
  -- tick enemies, weather, hunger and world logic underneath a player who asked for plain
  -- Powder Toy. Placed after the hot-reload check so reloading still works from sandbox.
  if R.sandboxMode then
    -- PHYSICS RUNS HERE, NOT IN onDraw. He reported the character "wiggling around everywhere"
    -- through several attempted fixes. Root cause: movePlayer was being called from the DRAW
    -- path, while R.frame never advanced -- onTick returns before the frame counter increments.
    -- movePlayer keys coyote time, jump buffering, drop-through and animation off R.frame, so
    -- with a frozen clock every one of those timers misfired and fought the position each frame.
    -- Advancing the clock and stepping physics on the tick (draw only draws) is the actual fix.
    R.frame = (R.frame or 0) + 1
    if R.SB and R.SB.on and not R.sbGrabbing and R.movePlayer then
      pcall(R.movePlayer)
      R.hp = 100        -- a debugging sandbox must never kill him
      R.o2 = R.o2Max or R.o2 or 100
    end
    runHooks(R.hooks.sandboxTick)
    -- Plugins also need their ORDINARY tick in sandbox. The normal dispatch of R.hooks.tick sits
    -- at the bottom of this function, far below the early return above, so in sandbox it never
    -- ran -- which is why reactions.lua reported "install pass has NOT yet run" forever and
    -- elementsWithUpdate stayed 0: his powders genuinely could not react because the install
    -- hook was never once invoked. The idle branch further down is gated on `not sandboxMode`,
    -- so it did not cover this case either.
    local okt = pcall(runHooks, R.hooks.tick)
    if not okt and PBX and PBX.log then PBX.log("tick", "sandbox tick hook pass raised an error") end
    return
  end
  -- GAS THROUGH LIQUIDS (2026-08-31): "all the oxygen and gases are getting caught on the trees
  -- and the liquids". Root cause is an engine rule, not our Lua: SimulationData.cpp's
  -- init_can_move sets can_move[moving][dest] = 0 (bounce) whenever the mover's Weight is <= the
  -- destination's. OXYG has Weight 1, WATR 30, so can_move[OXYG][WATR] is 0 -- measured live,
  -- every gas read 0 into every liquid. Gas was forbidden from entering the pixel at all, which
  -- is why every previous Lua-side attempt (spawn bands, boxed-in release passes) was working
  -- downstream of a hard rule it could not affect.
  -- Set to 1 (swap), which is exactly right physically: a rising bubble displaces water and the
  -- water fills in behind it. Done from Lua rather than C++ because sim.canMove is a real setter
  -- whose values persist through element reloads via the engine's customCanMove sticky bit -- so
  -- this needs no rebuild and no closing his game. The setter requires interface-event context
  -- (same class as sim.pressure's setter), which is why it runs here in the tick rather than at
  -- file scope. Guarded to run once per load.
  -- NOT applied to foliage: see the hub note. can_move=2 (co-occupy, the "layers" behaviour)
  -- corrupts pmap for non-energy particles, and can_move=1 physically relocates the leaf, which
  -- would make canopies churn -- a new version of the tree-damage complaint. That half needs a
  -- real engine feature (a separate gas occupancy map, like the existing photons[] map) and is
  -- the owner's call, not something to guess at.
  if not R.gasSwapInit then
    R.gasSwapInit = true
    for _, g in ipairs({ "OXYG", "CO2", "WTRV", "SMKE", "NBLE", "CAUS", "HYGN", "H2", "GAS" }) do
      local gi = eid(g)
      if gi then
        for _, l in ipairs({ "WATR", "DSTW", "SLTW", "OIL" }) do
          local li = eid(l)
          if li then pcall(sim.canMove, gi, li, 1) end
        end
      end
    end
  end
  -- Dev-only verification hook: tpt.screenshot() needs real interface-event context, same
  -- restriction as everything else the bridge can't call directly. Set R.debugShotRequested
  -- (a path string) via the bridge, next real tick captures and writes it, R.debugShotDone
  -- flips true so the bridge caller knows the file is ready to read.
  if R.debugShotRequested then
    local path = R.debugShotRequested; R.debugShotRequested = nil
    local ok, data = pcall(tpt.screenshot, 0, 1)
    if ok and data then local f = io.open(path, "wb"); if f then f:write(data); f:close() end end
    R.debugShotDone = ok
  end
  -- (brush native I/O lives on mouse/key/wheel -- TICK has no interface trait)
  if R.pendingGen ~= nil then local seed = R.pendingGen; R.pendingGen = nil; local ok, err = pcall(R.generateWorld, seed); if not ok then say("gen error: " .. tostring(err)); R.lastErr = tostring(err) end; R.active = true; R.worldEverGenerated = true; sim.paused(false); pcall(R.checkLocalChangelog)
    -- GitHub update-check disabled during active dev: it only compares
    -- ver ~= R.VERSION (not "is actually newer"), so once local R.VERSION
    -- moved past the last real published release, it permanently reads as
    -- "update available" against an OLDER release -- confusing, and now
    -- fully superseded for local testing by checkLocalChangelog above.
    -- Re-enable (and give it a real newer-than check) when actually cutting
    -- a real release for other players. "Check for update now" in the Esc
    -- menu still works on demand either way.
    return end
  if not R.active then return end
  if R._hotbarDirty then R._hotbarDirty = false; pcall(R.rebuildHotbarNow) end
  R.frame = (R.frame or 0) + 1
  if R.lastHitAt and R.frame - R.lastHitAt > 90 then R.blockHits = {}; R.lastHitAt = nil end
  local ok, err = pcall(flushFill); if not ok then R.lastErr = tostring(err) end
  if R.menuOpen then R.keys = {} end
  ok, err = pcall(movePlayer); if not ok then R.lastErr = tostring(err) end
  -- Bleed on real HP loss — not every R.hurt tick (suffocation/poison set hurt every
  -- 5 frames and were restarting a 6-frame burst of 4–7 BLD particles each frame).
  local hpDrop = (R._hpTickStart or R.hp or 100) - (R.hp or 0)
  local sharp = R._bloodEligible or hpDrop >= 8
  if hpDrop >= 3 and sharp and (R.lastBloodBurst or -999) + 90 <= R.frame then
    R.bloodSprayLeft = math.min(3, 1 + math.floor(hpDrop / 5))
    R.lastBloodBurst = R.frame
  end
  if (R.bloodSprayLeft or 0) > 0 then
    R.bloodSprayLeft = R.bloodSprayLeft - 1
    local bld = eid("BLD")
    if bld then
      local face = R.P.face or 1
      local px, py = floor(R.P.x - R.cam.x), floor(R.P.y - 6 - R.cam.y)
      for i = 1, 1 + math.random(2) do
        local ox, oy = math.random(-2, 2), math.random(-2, 1)
        local sx, sy = px + ox, py + oy
        if sx >= R.M and sx < W - R.M and sy >= R.M and sy < H - R.M and not sim.partID(sx, sy) then
          local q = sim.partCreate(-1, sx, sy, bld)
          if q and q >= 0 then
            sim.partProperty(q, "vx", face * (1.5 + math.random() * 2) + (math.random() - 0.5) * 1)
            sim.partProperty(q, "vy", -1.5 - math.random() * 1.5)
            sim.partProperty(q, "temp", 310 + math.random() * 8)
          end
        end
      end
    end
  end
  if R.wouldPlace() then
    local shiftBuild = shiftBuildMode()
    if inZoom(R.mouse.x, R.mouse.y) and not shiftBuild then local cx, cy = zoomToCanvas(R.mouse.x, R.mouse.y)
      -- One button (LEFT) does whatever the selected slot does -- a tool
      -- uses itself, a block places itself -- instead of a fixed
      -- LMB=use/RMB=place split. Matches native TPT's own single-button
      -- tool convention, per the explicit ask: "I just want to hit left
      -- click and use all my normal build controls."
      local s = selected(); if s and s:find("^tool:") then useTool(cx, cy, true) else placeAt(cx, cy, true) end
    else
      local s = selected(); if s and s:find("^tool:") then useTool(R.mouse.x, R.mouse.y) else placeAt(R.mouse.x, R.mouse.y, false) end
    end
  end
  local t0 = os.clock(); ok, err = pcall(updateCamera); if not ok then R.lastErr = tostring(err) end; R.shiftMs = (os.clock() - t0) * 1000
  ok, err = pcall(adjustCamOffsets); if not ok then R.lastErr = tostring(err) end
  if not R.zoomLensCleared then pcall(ren.zoomEnabled, false); R.zoomLensCleared = true end   -- one-time: force off any lens left stuck on from the removed Ctrl+zoom feature
  pcall(R.pumpFeedbackHttp)
  -- AUTOMATIC UPDATE CHECK (added 2026-09-02). R.checkForUpdate() previously had exactly
  -- ONE caller -- the Esc menu's "Check for update now" -- so the game could never TELL
  -- anyone a release existed; you had to go looking for it. That defeats the whole point
  -- of the updater, and matters more now that releases ship several times an evening.
  -- Checked once ~10s after the world starts (not at frame 0, so it never competes with
  -- worldgen), then every 30 minutes, so a long session still notices a release pushed
  -- while it was running. GitHub's unauthenticated rate limit is 60 requests/hour; this
  -- uses 2/hour. On success pumpUpdateCheck sets R.updatePromptOpen and says
  -- "N updates available -- press U to update"; U is already bound at the key handler.
  if R.frame == 600 or (R.frame > 600 and R.frame % 108000 == 0) then
    pcall(R.checkForUpdate)
  end
  pcall(R.pumpUpdateCheck)
  pcall(R.pumpUpdateDownload)
  local   okw, errw = pcall(updateWeather); if not okw then R.lastErr = tostring(errw) end
  local digDepth = R.P.y - surfaceAt(floor(R.P.x))
  local raining = R.weather and R.weather.rain
  local nearSurface = digDepth < 72
  if raining or nearSurface then
    okw, errw = pcall(absorbStandingWater); if not okw then R.lastErr = tostring(errw) end
    okw, errw = pcall(canopyPoolDrainTick); if not okw then R.lastErr = tostring(errw) end
    okw, errw = pcall(gapPoolDrainTick); if not okw then R.lastErr = tostring(errw) end
    okw, errw = pcall(treeWaterVeinsTick); if not okw then R.lastErr = tostring(errw) end
    okw, errw = pcall(treeGapGasVentTick); if not okw then R.lastErr = tostring(errw) end
    if raining then
      okw, errw = pcall(treeHollowDripTick); if not okw then R.lastErr = tostring(errw) end
      okw, errw = pcall(treeAquiferSpreadTick); if not okw then R.lastErr = tostring(errw) end
    end
  end
  okw, errw = pcall(settleLiquidsTick); if not okw then R.lastErr = tostring(errw) end
  okw, errw = pcall(pendingAirTick); if not okw then R.lastErr = tostring(errw) end
  if R.frame % 15 == 0 then okw, errw = pcall(sampleEnvGradient); if not okw then R.lastErr = tostring(errw) end end
  do
    local dep = digDepth
    if dep > 40 and R.frame % 4 ~= 0 then
      -- skip most frames underground — waterEqualisation is heavy
    elseif dep > 40 then pcall(sim.waterEqualisation, 1)
    elseif R.fast then pcall(sim.waterEqualisation, 0)
    else pcall(sim.waterEqualisation, 1) end
  end
  okw, errw = pcall(updateTorches); if not okw then R.lastErr = tostring(errw) end
  okw, errw = pcall(updateFurnaces); if not okw then R.lastErr = tostring(errw) end
  if R.frame % 15 == 0 then local okq, errq = pcall(updateQuests); if not okq then R.lastErr = tostring(errq) end; local dep = floor((R.P.y - surfaceAt(floor(R.P.x))) / 4); if dep > R.stats.maxDepth then R.stats.maxDepth = dep end end
  runHooks(R.hooks.tick)
  pcall(R.updateFalling)
  -- answer the player if no brain has consumed the message within half a second
  if #R.chatInbox > 0 then
    R.chatWait = (R.chatWait or 0) + 1
    if R.chatWait > 30 then
      local msgs = R.chatPending(); R.chatWait = 0
      local ok, reply = pcall(R.autoColonistReply, msgs[#msgs] or "")
      if ok and reply then R.colonistSay(reply) end
    end
  else R.chatWait = 0 end
  -- only one big panel at a time: whichever just opened closes the others (bag, guide, core bag, menu)
  do local now = { guide = R.guideOpen and true or false, bag = (R.ui and R.ui.bagOpen) and true or false,
                   quests = (R.ui and R.ui.questOpen) and true or false, menu = R.menuOpen and true or false }
    R.panelWas = R.panelWas or {}
    local opened
    for k, v in pairs(now) do if v and not R.panelWas[k] then opened = k end end
    if opened then
      if opened ~= "guide" and R.guideOpen and R.closeGuide then pcall(R.closeGuide) end
      if opened ~= "bag" and R.ui and R.ui.bagOpen then R.ui.bagOpen = false end
      if opened ~= "quests" and R.ui and R.ui.questOpen then R.ui.questOpen = false end
      if opened ~= "menu" and R.menuOpen then R.setMenuOpen(false) end
      if opened ~= "core" then R.invOpen = false end
      for k in pairs(now) do now[k] = (k == opened) end
    end
    R.panelWas = now
  end
  -- Was also re-filling every stack to 999 every 30 frames, so a sandbox bag could never
  -- be anything but a wall of 999s even if you dropped things. Survivability kept.
  if R.sandbox then R.hp = 100; R.o2 = 100 end
  if not sim.paused() then
    if R.frame % 14000 == 0 then R.day = (R.day or 1) + 1; say("Day " .. R.day) end
    if R.enemies and R.frame % 2400 == 0 and eid("FIGH") then local x = floor(R.P.x - R.cam.x) + (math.random() < 0.5 and -140 or 140); x = math.max(5, math.min(W-5, x)); local y = surfaceAt(x + R.cam.x) - 8 - R.cam.y; if y > 0 and y < H then sim.partCreate(-1, x, y, eid("FIGH")); say("An enemy approaches") end end
  end
end

function R.save()
  -- Was hardcoded to the original dev machine's D:/powder-toy/... path --
  -- silently failed ("save failed") for anyone else, since that folder doesn't exist on
  -- their machine. Relative path instead: writes next to the game, same
  -- portable pattern as the RPG loader and feedback.txt.
  local f = io.open("rpg-save.json", "w"); if not f then say("save failed"); return end
  local parts = {}; for k, v in pairs(R.inventory or {}) do parts[#parts+1] = string.format('"%s":%d', k, v) end
  local n = 0; for _ in pairs(R.tiles or {}) do n = n + 1 end
  f:write(string.format('{"version":4,"seed":%d,"day":%d,"deaths":%d,"frame":%d,"x":%d,"y":%d,"tiles_seen":%d,"pick":"%s","inventory":{%s}}', R.seed or 0, R.day or 1, R.deaths or 0, R.frame or 0, floor(R.P.x), floor(R.P.y), n, R.TOOLS.pick.name, table.concat(parts, ",")))
  f:close(); say("Saved (" .. n .. " tiles explored)")
end

if R.handlers and event.unregister then for _, h in ipairs(R.handlers) do pcall(event.unregister, h[1], h[2]) end end
R.handlers = { {event.mousedown, onMouseDown}, {event.mouseup, onMouseUp}, {event.mousemove, onMouseMove}, {event.mousewheel, onWheel},
               {event.keypress, onKeyDown}, {event.keyrelease, onKeyUp}, {event.textinput, onTextInput}, {event.tick, onTick}, {event.aftersimdraw, onDraw} }
for _, h in ipairs(R.handlers) do event.register(h[1], h[2]) end
if R.TOOLS and R.TOOLS.pick then local t = R.TOOLS.pick; if t.radius > 4 then t.radius = 3 end; if t.reach > 40 then t.reach = 26 end; if t.speed < 5 then t.speed = 7 end end; if R.TOOLS and R.TOOLS.axe then R.TOOLS.axe.radius = 4; R.TOOLS.axe.reach = 26; R.TOOLS.axe.only = {WOOD=1, PLNT=1, GRSS=1} end
R.hud = (R.hud == nil) and true or R.hud; R.minimap = (R.minimap == nil) and true or R.minimap; R.enemies = false
-- Defaults OFF: the auto-opened controls menu was reported "super annoying"
-- even with the toggle available, since a plain restart (which happens
-- constantly during active dev/testing) reset it back to showing every
-- time. Still fully available -- Esc menu > "Show controls on join: on/off"
-- -- for a first-time player or whenever showing someone else.
if R.tipsOn == nil then R.tipsOn = false end   -- `and false or x` is unsafe here: false is falsy, so `or x` always wins
for _, nm in ipairs({"FIGH", "STKM"}) do local t = eid(nm); if t then for i in sim.parts() do if sim.partProperty(i, "type") == t then sim.partKill(i) end end end end
-- Title screen (V1, per the roadmap-agent scope proposal): single save slot exists
-- today, so no world/character select is needed -- just a Play/Settings/Quit screen
-- shown before world generation, plus "Quit to menu" reachable from the in-game Esc
-- menu that returns here WITHOUT killing the process or the in-memory world (there's
-- one continuous sim; quitting to menu just re-hides it, same architecture as pausing).
R.titleScreen = R.titleScreen or false
R.worldEverGenerated = R.worldEverGenerated or false
function R.start(seed)
  R.titleSeed = seed or 7; R.titleScreen = true
  return "rpg v4 start queued seed=" .. tostring(R.titleSeed) .. " (title screen)"
end
do -- title screen (hot-reload local cap)
local TITLE_BTN = {
  play = { x = 0, y = 0, w = 150, h = 26 },
  newworld = { x = 0, y = 0, w = 150, h = 26 },
  settings = { x = 0, y = 0, w = 150, h = 26 },
  quit = { x = 0, y = 0, w = 150, h = 26 },
  multiplayer = { x = 0, y = 0, w = 150, h = 26 },
  -- Sandbox = plain Powder Toy, no RPG. Requested directly: "I want to be able to
  -- play the regular Powder Toy basically... regular build mode like how Powder Toy
  -- is, without the RPG stuff." R.stop() already restores TPT's element menus, its
  -- native HUD, normal sim speed and every original element colour, so this needs no
  -- new teardown path -- it is the same one used when the RPG is stopped.
  sandbox = { x = 0, y = 0, w = 150, h = 26 },
}
local function layoutTitleButtons()
  local cx = floor(W / 2 - 75)
  TITLE_BTN.play.x = cx; TITLE_BTN.play.y = floor(H / 2) - 38
  TITLE_BTN.newworld.x = cx; TITLE_BTN.newworld.y = floor(H / 2) - 6
  TITLE_BTN.sandbox.x = cx; TITLE_BTN.sandbox.y = floor(H / 2) + 26
  TITLE_BTN.settings.x = cx; TITLE_BTN.settings.y = floor(H / 2) + 58
  TITLE_BTN.multiplayer.x = cx; TITLE_BTN.multiplayer.y = floor(H / 2) + 90
  TITLE_BTN.quit.x = cx; TITLE_BTN.quit.y = floor(H / 2) + 122
end
local function openCreateWorld()
  R.titleCreateOpen = true
  R.titleSettingsOpen = false
  R.titleSeed = R.titleSeed or math.random(1, 9999)
end
local function confirmCreateWorld()
  R.pendingGen = R.titleSeed or math.random(1, 9999)
  R.titleScreen = false
  R.titleCreateOpen = false
  R.titleSettingsOpen = false
  if R.releaseMouse then R.releaseMouse() end
  R._placeGraceUntil = (R.frame or 0) + 48
end
-- Round 8 visual pass, per the owner's direct feedback that the functional-but-bare V1
-- ("plain dark background, 3 bordered buttons") needed real Minecraft/Terraria-style
-- presentation, not a flat box. Three real changes instead of a bigger flat box:
-- (1) a semi-transparent overlay instead of an opaque fillRect -- on "quit to menu"
-- a real world already exists and TPT's own native renderer draws it every frame
-- regardless of what this Lua onDraw does, so a translucent overlay lets the actual
-- rendered world show through behind the menu, the same idea as Terraria's title
-- screen rendering a real world scene (on first boot, before any world exists, this
-- just reads as a dark backdrop -- there's nothing to show through yet, which is
-- fine and expected); (2) drifting ember particles for ambient motion, purely
-- decorative HUD-space dots, not real sim particles -- doesn't touch physics at all;
-- (3) a real logo treatment (drop shadow + underline rule) and heavier button
-- styling (double-border bevel) instead of one flat-colour box per button.
-- Round 9: the owner wants Settings reachable straight from the title screen with real
-- presentation, not a jump out to the plain Esc/Options list ("we have our settings
-- here too but it's got to be nice nice shit"). Reuses the exact same R.MENU entries
-- (label substring match) instead of a second parallel slider list -- one source of
-- truth, the Esc menu keeps working exactly as before for mid-game use.
R.titleSettingsOpen = R.titleSettingsOpen or false
R.titleCreateOpen = R.titleCreateOpen or false
R.titleMultiplayerOpen = R.titleMultiplayerOpen or false
local TITLE_SETTINGS_KEYS = { "Map type", "Day length", "Cave frequency", "Ore rarity", "Gravity", "Jump height", "Move speed", "Tree spacing", "Enemy difficulty" }
local titleSettingsRows = {}
local titleBackBtn = { x = 0, y = 0, w = 90, h = 22 }
local function layoutTitleSettings()
  titleSettingsRows = {}
  local top = floor(H / 2) - #TITLE_SETTINGS_KEYS * 13
  for i, key in ipairs(TITLE_SETTINGS_KEYS) do
    for _, e in ipairs(R.MENU) do
      if e[1]:find(key, 1, true) then
        titleSettingsRows[#titleSettingsRows + 1] = { x = floor(W / 2 - 130), y = top + (i - 1) * 26, w = 260, h = 22, label = e[1], fn = e[2] }
        break
      end
    end
  end
  titleBackBtn.x = floor(W / 2 - 45); titleBackBtn.y = top + #TITLE_SETTINGS_KEYS * 26 + 8
end
local function drawTitleSettings()
  layoutTitleSettings()
  graphics.drawText(floor(W / 2 - 24), (titleSettingsRows[1] and titleSettingsRows[1].y or floor(H/2)) - 20, "SETTINGS", 255, 210, 100, 255)
  for _, r in ipairs(titleSettingsRows) do
    local hov = hitRect(titleMouseX, titleMouseY, r)
    graphics.fillRect(r.x, r.y, r.w, r.h, hov and 42 or 26, hov and 46 or 28, hov and 72 or 46, 220); graphics.drawRect(r.x, r.y, r.w, r.h, 255, hov and 235 or 210, hov and 150 or 100, 200)
    graphics.drawText(r.x + 8, r.y + 6, r.label, hov and 255 or 230, hov and 255 or 230, hov and 255 or 240, 255)
  end
  local b = titleBackBtn
  local hovB = hitRect(titleMouseX, titleMouseY, b)
  graphics.fillRect(b.x, b.y, b.w, b.h, hovB and 44 or 26, hovB and 48 or 28, hovB and 76 or 46, 235); graphics.drawRect(b.x, b.y, b.w, b.h, 255, hovB and 235 or 210, hovB and 150 or 100, 255)
  graphics.drawText(b.x + floor(b.w / 2 - 12), b.y + 6, "Back", 255, 240, 210, 255)
end
local function titleSettingsMouseDown(x, y)
  layoutTitleSettings()
  for _, r in ipairs(titleSettingsRows) do if hitRect(x, y, r) then r.fn(); return end end
  if hitRect(x, y, titleBackBtn) then R.titleSettingsOpen = false end
end
local function menuFnFor(key)
  for _, e in ipairs(R.MENU) do if e[1]:find(key, 1, true) then return e[1], e[2] end end
  return key, nil
end
local createRows, createCreateBtn, createBackBtn = {}, { x = 0, y = 0, w = 120, h = 24 }, { x = 0, y = 0, w = 90, h = 24 }
local function layoutTitleCreate()
  createRows = {}
  local top = floor(H / 2) - 118
  local cx = floor(W / 2 - 140)
  createRows[1] = { x = cx, y = top, w = 280, h = 22, kind = "map" }
  createRows[2] = { x = cx, y = top + 26, w = 280, h = 22, kind = "mode" }
  createRows[3] = { x = cx, y = top + 52, w = 280, h = 22, kind = "seed" }
  local extras = { "Cave frequency", "Ore rarity", "Tree spacing" }
  for i, key in ipairs(extras) do
    local label, fn = menuFnFor(key)
    createRows[#createRows + 1] = { x = cx, y = top + 78 + (i - 1) * 26, w = 280, h = 22, kind = "menu", label = label, fn = fn }
  end
  local by = top + 78 + #extras * 26 + 10
  createCreateBtn.x = floor(W / 2 - 120); createCreateBtn.y = by
  createBackBtn.x = floor(W / 2 + 16); createBackBtn.y = by
end
local function drawTitleCreate()
  layoutTitleCreate()
  graphics.drawText(floor(W / 2 - 42), createRows[1].y - 22, "CREATE WORLD", 255, 210, 100, 255)
  graphics.drawText(floor(W / 2 - 150), createRows[1].y - 10, "click a row to change it", 140, 145, 165, 255)
  for _, r in ipairs(createRows) do
    local hov = hitRect(titleMouseX, titleMouseY, r)
    local label
    if r.kind == "map" then label = "Map type: " .. (MAP_TYPE_LABEL[R.mapType or "mixed"] or "Mixed")
    elseif r.kind == "mode" then label = "Mode: " .. (R.createSandbox and "Sandbox" or "Survival")
    elseif r.kind == "seed" then label = "Seed: " .. tostring(R.titleSeed or 7) .. "  (click to reroll)"
    else label = r.label or "?" end
    graphics.fillRect(r.x, r.y, r.w, r.h, hov and 42 or 26, hov and 46 or 28, hov and 72 or 46, 220)
    graphics.drawRect(r.x, r.y, r.w, r.h, 255, hov and 235 or 210, hov and 150 or 100, 200)
    graphics.drawText(r.x + 8, r.y + 6, string.sub(label, 1, 42), hov and 255 or 230, hov and 255 or 230, hov and 255 or 240, 255)
  end
  local hovC = hitRect(titleMouseX, titleMouseY, createCreateBtn)
  graphics.fillRect(createCreateBtn.x, createCreateBtn.y, createCreateBtn.w, createCreateBtn.h, hovC and 70 or 40, hovC and 90 or 50, hovC and 40 or 28, 235)
  graphics.drawRect(createCreateBtn.x, createCreateBtn.y, createCreateBtn.w, createCreateBtn.h, 255, 210, 100, 255)
  graphics.drawText(createCreateBtn.x + 18, createCreateBtn.y + 7, "Create", 255, 240, 210, 255)
  local hovB = hitRect(titleMouseX, titleMouseY, createBackBtn)
  graphics.fillRect(createBackBtn.x, createBackBtn.y, createBackBtn.w, createBackBtn.h, hovB and 44 or 26, hovB and 48 or 28, hovB and 76 or 46, 235)
  graphics.drawRect(createBackBtn.x, createBackBtn.y, createBackBtn.w, createBackBtn.h, 255, hovB and 235 or 210, hovB and 150 or 100, 255)
  graphics.drawText(createBackBtn.x + 28, createBackBtn.y + 7, "Back", 255, 240, 210, 255)
end
local function titleCreateMouseDown(x, y)
  layoutTitleCreate()
  for _, r in ipairs(createRows) do
    if hitRect(x, y, r) then
      if r.kind == "map" then R.cycleMapType()
      elseif r.kind == "mode" then R.createSandbox = not R.createSandbox; say(R.createSandbox and "Mode: Sandbox" or "Mode: Survival")
      elseif r.kind == "seed" then R.titleSeed = math.random(1, 9999); say("Seed " .. R.titleSeed)
      elseif r.fn then r.fn() end
      return
    end
  end
  if hitRect(x, y, createCreateBtn) then confirmCreateWorld(); return end
  if hitRect(x, y, createBackBtn) then R.titleCreateOpen = false end
end
local titleEmbers
local function titleEmberInit()
  if titleEmbers then return end
  titleEmbers = {}
  for i = 1, 14 do
    titleEmbers[i] = { x = math.random(0, W), y = math.random(0, H), spd = 0.15 + math.random() * 0.35, drift = math.random() * 6.28, sz = 1 + math.random(0, 1) }
  end
end
drawTitleScreen = function()
  if not R.titleScreen then return end
  layoutTitleButtons()
  titleEmberInit()
  -- translucent, not opaque: lets a real already-generated world (quit-to-menu case)
  -- show through behind the menu instead of hiding it behind a flat colour.
  graphics.fillRect(0, 0, W, H, 8, 10, 20, 190)
  for _, e in ipairs(titleEmbers) do
    e.y = e.y - e.spd; e.x = e.x + math.sin((R.frame or 0) * 0.02 + e.drift) * 0.15
    if e.y < -4 then e.y = H + 4; e.x = math.random(0, W) end
    local a = 120 + floor(80 * (0.5 + 0.5 * math.sin((R.frame or 0) * 0.05 + e.drift)))
    graphics.fillRect(floor(e.x), floor(e.y), e.sz, e.sz, 255, 170, 70, a)
  end
  if R.titleMultiplayerOpen then
    if R.net and R.net.drawTitleScreen then pcall(R.net.drawTitleScreen)
    else R.titleMultiplayerOpen = false end   -- plugin gone: fall back to the menu, never a blank screen
    return
  end
  if R.titleCreateOpen then drawTitleCreate(); return end
  if R.titleSettingsOpen then drawTitleSettings(); return end
  local title = "POWDER RPG"
  local tx, ty = floor(W / 2 - #title * 6), floor(H / 2) - 110
  graphics.drawText(tx + 2, ty + 2, title, 20, 14, 10, 220)   -- drop shadow
  graphics.drawText(tx, ty, title, 255, 210, 100, 255)
  graphics.fillRect(floor(W / 2 - 70), ty + 16, 140, 1, 255, 210, 100, 140)   -- underline rule
  graphics.drawText(floor(W / 2 - 18), ty + 24, "v" .. R.VERSION, 140, 145, 165, 255)
  local buttons = {
    { TITLE_BTN.play, R.worldEverGenerated and "Resume" or "Play" },
    { TITLE_BTN.newworld, "New World" },
    { TITLE_BTN.sandbox, R.sandboxSuspended and "Resume Sandbox" or "Sandbox (Classic)" },
    { TITLE_BTN.settings, "Settings" },
    { TITLE_BTN.multiplayer, "Multiplayer" },
    { TITLE_BTN.quit, "Quit" },
  }
  for _, b in ipairs(buttons) do
    local r, label = b[1], b[2]
    local hov = hitRect(titleMouseX, titleMouseY, r)
    graphics.fillRect(r.x, r.y, r.w, r.h, hov and 44 or 26, hov and 48 or 28, hov and 76 or 46, 235)
    graphics.fillRect(r.x + 2, r.y + 2, r.w - 4, 2, hov and 110 or 70, hov and 116 or 76, hov and 170 or 120, 200)   -- top bevel highlight
    graphics.drawRect(r.x, r.y, r.w, r.h, 255, hov and 235 or 210, hov and 150 or 100, 255)
    graphics.drawRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2, 120, 90, 30, 130)   -- inner border, double-line look
    graphics.drawText(r.x + floor(r.w / 2 - #label * 3), r.y + floor(r.h / 2) - 3, label, 255, 240, 210, 255)
  end
end
titleMouseDown = function(x, y)
  if not R.titleScreen then return false end
  if R.titleMultiplayerOpen then if R.net and R.net.titleMouseDown then pcall(R.net.titleMouseDown, x, y) end; return true end
  if R.titleCreateOpen then titleCreateMouseDown(x, y); return true end
  if R.titleSettingsOpen then titleSettingsMouseDown(x, y); return true end
  layoutTitleButtons()
  if hitRect(x, y, TITLE_BTN.play) then
    if R.worldEverGenerated then
      R.titleScreen = false; R.active = true
      if R.releaseMouse then R.releaseMouse() end
      R._placeGraceUntil = (R.frame or 0) + 48
    else openCreateWorld() end
    return true
  end
  if hitRect(x, y, TITLE_BTN.newworld) then openCreateWorld(); return true end
  if hitRect(x, y, TITLE_BTN.sandbox) then R.enterSandbox(); return true end
  if hitRect(x, y, TITLE_BTN.settings) then R.titleSettingsOpen = true; return true end
  if hitRect(x, y, TITLE_BTN.multiplayer) then
    if R.net and R.net.drawTitleScreen then R.titleMultiplayerOpen = true end
    return true
  end
  -- No real scriptable full-process-quit exists in TPT Lua -- rather than fake a
  -- broken quit button, this tells the player the real way to close the game.
  if hitRect(x, y, TITLE_BTN.quit) then say("Close the window or Alt+F4 to quit"); return true end
  return true   -- swallow clicks anywhere else on the title screen
end
end -- title screen
-- Sandbox mode: hand the player a plain Powder Toy. Saves first if a world exists,
-- so choosing "Sandbox" can never cost someone their RPG progress -- that would be an
-- unrecoverable, one-click mistake, and the kind of thing a new player does by accident
-- while exploring the menu.
-- WALK MODE inside sandbox. He asked for this directly: "I still can't spawn my guy that I can
-- walk around with, that I normally use in the RPG, and that's a serious problem so that we can
-- test stuff." Building something and then being unable to walk through it makes sandbox useless
-- for testing the thing you just built.
-- This is a toggle, not a mode change: the canvas is never cleared in either direction, so you
-- can build, walk through it, come back and keep building. Enemies are forced off (you asked to
-- test, not to fight) and TPT's element menus stay visible so building keeps working.
-- R.active drives the whole RPG tick/draw path, so enabling it is what actually gives you a
-- controllable character with real physics; R.sandboxMode goes false while walking so onTick
-- stops early-returning, and comes back on when you toggle out.
-- SANDBOX CHARACTER, rewritten 2026-09-02. The first version set R.active = true to reuse the
-- RPG's own player, and he reported it "fucked my game all up" -- correctly, because R.active
-- starts EVERYTHING: weather, hunger, day/night, the camera follow, chunk reveal and worldgen
-- expectations, none of which make sense on a blank 612x384 canvas with no generated terrain.
-- This is a completely self-contained character instead. It runs only on the sandbox hooks, it
-- never sets R.active, and it touches no RPG system at all -- so the element menus, the brush,
-- stamps, submission and settings all keep working exactly as they do in plain Powder Toy.
-- There is deliberately no camera: a sandbox is one fixed screen, so he simply walks around in it.
R.SB = R.SB or { x = 300, y = 60, vx = 0, vy = 0, on = false, face = 1, keys = {} }

-- Solid enough to stand on? Anything with a particle that is not a gas/liquid reads as ground.
-- Uses the same TYPE_SOLID/Falldown discipline ADR-003 requires rather than guessing by name.
function R.sbSolidAt(x, y)
  x, y = math.floor(x), math.floor(y)
  if x < 4 or x > 607 or y > 379 then return true end   -- canvas edges are walls/floor
  if y < 4 then return false end
  local ok, p = pcall(sim.pmap, x, y)
  if not ok or not p then return false end
  local t = sim.partProperty(p, "type")
  if not t or t == 0 then return false end
  local okp, props = pcall(elem.property, t, "Properties")
  if not okp or not props then return false end
  return (props % 8) >= 4        -- TYPE_SOLID bit
end

function R.sbStep()
  local P = R.SB
  if not P.on then return end
  local k = P.keys
  local ax = (k.right and 1 or 0) - (k.left and 1 or 0)
  if ax ~= 0 then P.face = ax end
  P.vx = ax * 1.6
  -- ground check first so jumping is reliable rather than depending on vy sign
  local grounded = R.sbSolidAt(P.x, P.y + 1) or R.sbSolidAt(P.x - 1, P.y + 1) or R.sbSolidAt(P.x + 1, P.y + 1)
  if k.up and grounded then P.vy = -3.2 end
  P.vy = math.min(6, P.vy + 0.32)                      -- gravity, terminal velocity clamped
  -- Axis-separated movement, one pixel at a time. Stepping pixel-by-pixel means he can never
  -- tunnel through a one-pixel wall at speed, which matters here because the player builds the
  -- walls themselves and they are frequently exactly one particle thick.
  local steps = math.ceil(math.max(math.abs(P.vx), math.abs(P.vy)))
  local sx, sy = P.vx / steps, P.vy / steps
  for _ = 1, steps do
    if not R.sbSolidAt(P.x + sx, P.y) then P.x = P.x + sx
    else
      -- one-pixel step-up, so walking over rubble does not need a jump
      if not R.sbSolidAt(P.x + sx, P.y - 1) and not R.sbSolidAt(P.x, P.y - 1) then P.x, P.y = P.x + sx, P.y - 1
      else P.vx = 0 end
    end
    if not R.sbSolidAt(P.x, P.y + sy) then P.y = P.y + sy else P.vy = 0 end
  end
  P.x = math.max(5, math.min(606, P.x))
  P.y = math.max(5, math.min(378, P.y))
end

function R.sbDraw()
  local P = R.SB
  if not P.on then return end
  local x, y = math.floor(P.x), math.floor(P.y)
  graphics.fillRect(x - 1, y - 6, 3, 3, 240, 200, 160, 255)   -- head
  graphics.fillRect(x - 1, y - 3, 3, 4, 90, 130, 200, 255)    -- body
  graphics.fillRect(x - 1, y + 1, 1, 2, 70, 70, 90, 255)      -- legs
  graphics.fillRect(x + 1, y + 1, 1, 2, 70, 70, 90, 255)
  graphics.drawPixel(x + P.face, y - 5, 20, 20, 30, 255)      -- facing dot
end

-- CLICKABLE SANDBOX BAR. He is explicit and it is an accessibility requirement, not a
-- preference: "we don't want to have to push function hotkeys at the top of our shit. We want
-- button options for stuff. I hate having to push buttons on my keyboard. My hand is broken."
-- So every sandbox action has a real on-screen button. The keyboard shortcuts still exist for
-- anyone who wants them, but nothing is reachable ONLY by key.
-- Placed top-left, one row, clear of TPT's own element menus (right edge and bottom strip).
-- TRIMMED 2026-09-02. I over-built this. He asked for buttons because his hand is broken, and
-- I turned that into a seven-button strip across the top of his canvas -- "it looks dumb and
-- there's buttons all over everywhere." The real distinction he drew is narrower than I read it:
-- FUNCTION keys at the top of the keyboard are the problem; ordinary letter keys like E are fine
-- and he explicitly likes them ("being able to push E, that was all working well for us").
-- So: three buttons for the things that have no comfortable key, letter keys for the rest.
R.SB_BTNS = {
  { id = "guy",  w = 62 },
  { id = "grab", w = 44 },
  { id = "menu", w = 46 },
}

-- FULL RPG TEST WORLD. He asked to be able to "test all the features from the RPG -- testing
-- machines and vehicles and everything else" from sandbox. The lightweight sandbox character
-- deliberately runs none of the RPG, which is right for building but useless for testing a
-- conveyor or a vehicle. This is the other half: a real RPG session on a FLAT world, with a full
-- inventory, so every machine, vehicle and tool can actually be exercised.
-- Flat is the important part. `world.lua`'s flatWorldGen fills solid rock from FLAT_SURFACE_Y
-- down and R.P.y is placed against that, so the player lands on real ground instead of falling --
-- which is exactly what went wrong when the first version of the Character button simply set
-- R.active on an empty canvas.
function R.sbRpgTest()
  R.SB.on = false                     -- the toy character and the real one must never coexist
  R.sandboxMode = false
  R.sandboxSuspended = false
  R.mapType = "flat"
  R.flatTestWorld = true
  R.enemies = false                   -- testing, not fighting
  R.pendingGen = math.random(1, 9999)
  R.titleScreen = false
  R.active = true
  if R.releaseMouse then R.releaseMouse() end
  R._placeGraceUntil = (R.frame or 0) + 48
  R.sbGrantAll = true                 -- picked up once the world exists (see onTick)
  say("RPG test world -- flat ground, full inventory, enemies off. Esc for the menu.")
  return "rpgtest"
end
function R.sbLayoutButtons()
  local x, y = 6, 6
  for _, b in ipairs(R.SB_BTNS) do
    b.x, b.y, b.h = x, y, 14
    x = x + b.w + 3
  end
end
function R.sbButtonLabel(b)
  if b.id == "guy"    then return R.SB.on and "Character*" or "Character" end
  if b.id == "grab"   then return R.sbGrab and "Grab*" or "Grab" end
  if b.id == "rpgtest" then return "RPG Test" end
  if b.id == "tools"  then return "Tools" end
  if b.id == "submit" then return "Submit" end
  if b.id == "report" then return "Report" end
  if b.id == "menu"   then return "Menu" end
  return b.id
end
function R.sbDrawButtons()
  R.sbLayoutButtons()
  for _, b in ipairs(R.SB_BTNS) do
    local active = (b.id == "guy" and R.SB.on)
    graphics.fillRect(b.x, b.y, b.w, b.h, 18, 20, 28, 225)
    graphics.drawRect(b.x, b.y, b.w, b.h, active and 235 or 120, active and 190 or 130, active and 90 or 150, 255)
    local label = R.sbButtonLabel(b)
    graphics.drawText(b.x + 5, b.y + 4, label, active and 255 or 210, active and 225 or 220, active and 170 or 235, 255)
  end
end
function R.sbButtonClick(mx, my)
  R.sbLayoutButtons()
  for _, b in ipairs(R.SB_BTNS) do
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then
      if b.id == "guy" then R.sandboxWalk()
      elseif b.id == "grab" then
        R.sbGrab = not R.sbGrab
        say(R.sbGrab and "Grab on -- drag him where you want. Click Grab again to stop." or "Grab off.")
      elseif b.id == "rpgtest" then R.sbRpgTest()
      -- Tools / Submit / Report dispatch the SAME key the plugins already listen for, rather
      -- than setting a private flag. My first version set R.sbToolsRequested and
      -- R.sbSubmitRequested, which nothing anywhere read -- two dead buttons, the exact silent
      -- no-op this project keeps shipping and that I keep telling other lanes to avoid.
      -- Going through the real hook chain means the button and the key can never diverge.
      elseif b.id == "tools"  then runHooks(R.hooks.sandboxKey, 1073741887, "f6", false, false, false)
      elseif b.id == "submit" then runHooks(R.hooks.sandboxKey, 121, "y", false, false, false)
      elseif b.id == "report" then runHooks(R.hooks.sandboxKey, 1073741889, "f8", false, false, false)
      elseif b.id == "menu" then R.exitSandbox() end
      return true
    end
  end
  return false
end

function R.sandboxWalk(on)
  if on == nil then on = not R.SB.on end
  if on then
    local mx = (R.mouse and R.mouse.x) or 300
    local my = (R.mouse and R.mouse.y) or 60
    -- SPAWN ON GROUND, NOT IN MID-AIR. Reported immediately: "when I hit character he just falls
    -- out of the world to his death." A fresh sandbox is an EMPTY canvas, so spawning at the
    -- cursor meant spawning in vacuum and falling until he hit the bottom edge -- which reads as
    -- dying even though nothing can actually kill him here.
    -- Search downward from the cursor for real ground and stand him on it.
    -- ALWAYS give him a proper platform. Reported: "he's spazzing out everywhere." Two causes,
    -- both mine: (a) I built the ledge out of STNE, which check_terrain_solid.py reports as
    -- UNSAFE falldown=1 solid=false -- a POWDER. It collapsed under him every time, which is
    -- exactly the jitter. ADR-003 exists precisely to stop this and I ignored it. (b) landing him
    -- on whatever loose particles happened to be below was never going to be stable anyway.
    -- Now: a real BRCK slab (verified SAFE), placed every time, so he always has firm ground.
    local groundY
    if true then
      -- Genuinely nothing below him. Rather than drop him into the void, give him something to
      -- stand on: a small stone ledge under the cursor. This is a sandbox -- making a floor is a
      -- reasonable thing for the game to do for you, and it is trivially erasable if unwanted.
      local floorY = math.min(345, math.max(60, math.floor(my) + 20))
      local sid = elem["DEFAULT_PT_BRCK"] or elem["DEFAULT_PT_BRMT"]
      if sid then
        for dx = -30, 30 do
          for dy = 0, 3 do pcall(sim.partCreate, -1, math.floor(mx) + dx, floorY + dy, sid) end
        end
      end
      groundY = floorY - 1
      say("Placed a solid platform to stand on.")
    end
    -- Position the REAL RPG player, not a stand-in. R.P is the same table the RPG itself uses,
    -- so he keeps his sprite, physics, facing and animation exactly as in a normal game.
    R.P = R.P or { x = 0, y = 100, vx = 0, vy = 0, onGround = false, coyote = 0, face = 1, anim = 0 }
    -- Sandbox is a single fixed screen with no scrolling, so pin the camera at the origin:
    -- that makes world coordinates and screen coordinates identical, which is what every other
    -- part of the sandbox (mouse, buttons, brush) already assumes.
    R.cam = R.cam or {}
    R.cam.x, R.cam.y = 0, 0
    R.P.x, R.P.y, R.P.vx, R.P.vy = mx, groundY, 0, 0
    R.hp = 100
    R.keys = R.keys or {}
    for k in pairs(R.keys) do R.keys[k] = false end
    R.SB.on = true
    -- Give him something to actually test WITH. He asked for the character plus items; an empty
    -- inventory in a debugging sandbox is useless.
    if not R.sbKitGiven then
      R.sbKitGiven = true
      local n = 0
      for code in pairs(R.NAMES or {}) do pcall(R.give, code, 100); n = n + 1 end
      for _, t in ipairs({ R.PICKS, R.SWORDS }) do
        for _, it in ipairs(t or {}) do if it.name then pcall(R.give, it.name, 1) end end
      end
      if PBX and PBX.log then PBX.log("sandbox", "granted " .. n .. " materials + all picks/swords for testing") end
    end
    say("Character on -- A/D or arrows to walk, W/Space to jump. Click Character again to remove him.")
  else
    R.SB.on = false
    R.SB.keys = {}
    say("Character off.")
  end
  return R.SB.on and "walking" or "off"
end
_G.sandboxWalk = R.sandboxWalk

-- Reset the brush to a clean, un-warped shape whenever the SHAPE ITSELF changes. He asked
-- that "when I switch shapes, the rotation and all the warping go back to regular" -- a
-- squashed ellipse carrying its aspect over onto a freshly-picked square is confusing, and
-- there is no way to tell by looking that the new shape is still warped.
-- Size is preserved (both axes snap to the LARGER of the two) rather than reset to a fixed
-- default, so switching shape never silently shrinks a brush you just spent a drag sizing.
-- MUST be called from an interface event: tpt.brushID/brushx/brushy are "restricted to
-- interface events" (compat.lua:699), so this is invoked from the key and mouse handlers,
-- never from onTick or onDraw, where it would simply error every frame.
function R.sbCheckShape()
  if not R.sandboxMode then return end
  local ok, shape = pcall(function() return tpt.brushID end)
  if not ok or type(shape) ~= "number" then return end
  if R.sbLastShape == nil then R.sbLastShape = shape; return end
  if shape == R.sbLastShape then return end
  R.sbLastShape = shape
  pcall(function()
    local w, h = tpt.brushx, tpt.brushy
    if type(w) == "number" and type(h) == "number" and w ~= h then
      local s = math.max(w, h)
      tpt.brushx = s; tpt.brushy = s
      say("Brush reset to " .. (s * 2) .. " x " .. (s * 2))
    end
  end)
end

function R.enterSandbox()
  -- RESUMING keeps your build. Leaving sandbox (Esc) suspends it rather than discarding it,
  -- so coming back in must NOT clear the canvas -- otherwise stepping out to the menu for ten
  -- seconds silently destroys everything you made, with no warning and no undo.
  local resuming = R.sandboxSuspended
  if R.worldEverGenerated and not resuming then pcall(R.save) end
  R.titleScreen = false; R.titleCreateOpen = false; R.titleSettingsOpen = false
  R.sandboxMode = true
  R.sandboxSuspended = false
  pcall(R.stop)                 -- restores TPT menus, native HUD, speed, element colours
  if not resuming then
    pcall(sim.clearSim)         -- a blank canvas, the way stock Powder Toy opens
  end
  pcall(sim.paused, false)
  if R.releaseMouse then R.releaseMouse() end
  say("Sandbox mode -- plain Powder Toy. Esc = RPG menu | Y = submit a stamp | F8 = bug/suggestion | F6 = dev toolkit (probe, pause/step, world sampler)")
  return "sandbox"
end

-- Return path out of sandbox. Bound to Esc (see the Esc handler) and also exposed as a
-- console global, because a player who somehow loses the key binding should never be
-- stuck in a mode with no way back to their save.
function R.exitSandbox()
  if not R.sandboxMode then return end
  R.sandboxMode = false
  R.sandboxSuspended = true   -- there is a build to come back to; do not clear it on re-entry
  R.active = false
  R.titleScreen = true
  pcall(R.setTptMenus, false)
  return "menu"
end
_G.rpgMenu = function() return R.exitSandbox() or "menu" end

function R.stop() R.active = false; pcall(tpt.hud, 1); pcall(R.setFX, false); pcall(R.setTptMenus, true); pcall(R.setFast, false)
  for name, col in pairs(R.origColours or {}) do local id = elem["DEFAULT_PT_" .. name]; if id then pcall(elem.property, id, "Colour", col) end end
  return "rpg stopped" end
function R.playerId() return nil end
-- vehicles: plugins call R.mount(v) with a table they update each tick ({x, y, seatY, dead}); S dismounts
-- Make the colonist actually answer: a plugin/model may supersede this, but the player never talks to a wall.
function R.colonistSay(text)
  local C = R.COMP
  local name = (C and C.name) or "Aster"
  R.chatSay(name, text)
  if C then C.sayMsg = tostring(text):sub(1, 90); C.sayAt = R.frame end
  return true
end
local function nearestOre()
  local want = { IRON=1, COAL=1, GOLD=1, CU=1, QRTZ=1, DMND=1, DU=1 }
  local best, bd
  for i in sim.parts() do local nm = nameOf(sim.partProperty(i, "type"))
    if want[nm] then local px, py = sim.partPosition(i)
      local d = (px - (R.P.x - R.cam.x))^2 + (py - (R.P.y - R.cam.y))^2
      if not bd or d < bd then bd, best = d, { nm, px, py } end end end
  if not best then return nil end
  local dx = best[2] - (R.P.x - R.cam.x); local dy = best[3] - (R.P.y - R.cam.y)
  local dir = (math.abs(dx) > math.abs(dy)) and (dx > 0 and "east" or "west") or (dy > 0 and "below us" or "above us")
  return nice(best[1]), dir, floor(math.sqrt(bd) / 4)
end
function R.autoColonistReply(msg)
  local m = msg:lower()
  local q = R.QUESTS[R.quest]
  local function have(el) return R.inventory[el] or 0 end
  if m:find("what") and (m:find("do") or m:find("next") or m:find("now")) then
    if q then
      local need = ""
      if q.id == "woodpick" then need = " We have " .. have("WOOD") .. " wood, we need 6."
      elseif q.id == "coal" then need = " Coal shows up as black seams once we are a bit deeper."
      elseif q.id == "furnace" then need = " We need 20 granite and 5 coal, then light it with the torch." end
      return "Next up: " .. q.txt .. "." .. need
    end
    return "We are past the starter goals - I say we dig deeper and set up power."
  end
  if m:find("air") or m:find("oxygen") or m:find("breath") then
    local g = R.gas or {}
    local extra = ""
    if (g.co or 0) > 20 then extra = " Careful, carbon monoxide is building up."
    elseif (g.ch4 or 0) > 25 then extra = " There is gas down here - no open flames."
    elseif (R.o2 or 100) < 60 then extra = " Air is getting thin, we should head up or make oxygen." end
    return string.format("Air is %d%%%s", floor(R.o2 or 100), extra)
  end
  if m:find("where") then
    local d = floor((R.P.y - surfaceAt(floor(R.P.x))) / 4)
    return d > 5 and string.format("We are %dm down in the %s.", d, biomeAt(floor(R.P.x))) or ("We are on the surface in the " .. biomeAt(floor(R.P.x)) .. ".")
  end
  if m:find("ore") or m:find("iron") or m:find("find") or m:find("see") then
    local nm, dir, dist = nearestOre()
    if nm then return string.format("I can see %s %s, about %dm off.", nm, dir, dist) end
    return "No ore in sight from here - we should dig deeper."
  end
  if m:find("have") or m:find("invent") or m:find("carry") then
    local best, bn = nil, 0
    for k, v in pairs(R.inventory) do if v > bn and not R.ITEMS[k] then bn, best = v, k end end
    return string.format("You have %s and your %s. I am carrying what I picked up.", best and (bn .. " " .. nice(best)) or "not much", R.TOOLS.pick.name)
  end
  if m:find("follow") or m:find("come") then return "Right behind you." end
  if m:find("wait") or m:find("stay") or m:find("stop") then return "I will hold here." end
  if m:find("hello") or m:find("hey") or m:find("hi ") or m == "hi" then return "Hey. Ready when you are." end
  if m:find("help") then return "I can follow, mine, fetch wood, light torches and fight. Just tell me what you need." end
  return "Got it."
end
-- ============================================================ ACTOR FRAMEWORK
-- One action + perception surface so any character (the colonist, future NPCs, enemies) can do everything
-- the player can: sense the world, mine, place, craft, use tools, interact with machines, carry and hand over.
-- An "actor" is any table with { x, y, inv, tools } in world coordinates. The player is R.playerActor().
R.CAPS = {
  sense = { "senseRect(x1,y1,x2,y2)", "senseNearest(name|fn, radius)", "senseColumn(x, fromY, toY)", "senseSelf(actor)" },
  move  = { "findPath(sx,sy,gx,gy,opts) -> waypoints {x,y,dig}" },
  act   = { "actorMine(actor,x,y,opts)", "actorPlace(actor,el,x,y,opts)", "actorCraft(actor,recipeName)",
            "actorUse(actor,item,x,y)", "actorGive(actor,to,item,n)", "actorLight(actor,x,y)" },
  build = { "actorFill(actor,x1,y1,x2,y2,el)", "actorClear(actor,x1,y1,x2,y2,opts)" },
  talk  = { "colonistSay(text)", "chatPending()" },
}
function R.playerActor()
  return { x = R.P.x, y = R.P.y, inv = R.inventory, tools = R.TOOLS, isPlayer = true }
end
local function canvasOf(wx, wy) return floor(wx) - R.cam.x, floor(wy) - R.cam.y end
local function onCanvas(x, y) return x >= M and x < W - M and y >= M and y < H - M end

-- ---- perception -------------------------------------------------------
function R.senseRect(x1, y1, x2, y2, step)
  step = step or 2
  local counts, solid, total = {}, 0, 0
  for wy = math.min(y1, y2), math.max(y1, y2), step do
    for wx = math.min(x1, x2), math.max(x1, x2), step do
      local x, y = canvasOf(wx, wy)
      if onCanvas(x, y) then total = total + 1
        local p = sim.partID(x, y)
        if p then local nm = nameOf(sim.partProperty(p, "type"))
          counts[nm] = (counts[nm] or 0) + 1
          if not PASS[nm] then solid = solid + 1 end end
      end
    end
  end
  return { counts = counts, solid = solid, total = total, solidFrac = (total > 0) and (solid / total) or 0 }
end
function R.senseNearest(what, radius)
  radius = radius or 120
  local match = what
  if type(what) == "string" then local target = what; match = function(nm) return nm == target end end
  local best, bd, bnm
  local step = 2
  for wy = R.P.y - radius, R.P.y + radius, step do
    for wx = R.P.x - radius, R.P.x + radius, step do
      local x, y = canvasOf(wx, wy)
      if onCanvas(x, y) then local p = sim.partID(x, y)
        if p then local nm = nameOf(sim.partProperty(p, "type"))
          if match(nm) then local d = (wx - R.P.x)^2 + (wy - R.P.y)^2
            if not bd or d < bd then bd, best, bnm = d, { wx, wy }, nm end end end
      end
    end
  end
  if not best then return nil end
  return best[1], best[2], math.sqrt(bd), bnm
end
function R.senseColumn(wx, fromY, toY)
  local out = {}
  for wy = fromY, toY, 4 do local x, y = canvasOf(wx, wy)
    local nm = "-"
    if onCanvas(x, y) then local p = sim.partID(x, y); if p then nm = nameOf(sim.partProperty(p, "type")) end
    else local g = gen(floor(wx), floor(wy)); nm = g or "-" end
    out[#out + 1] = nm end
  return out
end
function R.senseSelf(a)
  a = a or R.playerActor()
  local depth = a.y - surfaceAt(floor(a.x))
  return { x = floor(a.x), y = floor(a.y), depth = floor(depth / 4), biome = biomeAt(floor(a.x)),
           air = floor(R.o2 or 100), gas = R.gas, hp = a.isPlayer and R.hp or a.hp,
           goal = R.QUESTS[R.quest] and R.QUESTS[R.quest].txt or nil }
end

-- ---- actions ----------------------------------------------------------
local function actorTool(a, kind) return (a.tools and a.tools[kind]) or R.TOOLS[kind] end
function R.actorMine(a, wx, wy, opts)
  opts = opts or {}
  local x, y = canvasOf(wx, wy); if not onCanvas(x, y) then return false, "off screen" end
  local p = sim.partID(x, y); if not p then return false, "nothing there" end
  local nm = nameOf(sim.partProperty(p, "type"))
  local tier = R.MINEABLE[nm]; if not tier then return false, nice(nm) .. " cannot be mined" end
  local power = (actorTool(a, "pick") or {}).power or 1
  if opts.axe then power = math.max(power, (actorTool(a, "axe") or {}).power or 1) end
  if tier > power + 1 then return false, nice(nm) .. " needs a better pick" end
  local need = math.max(1, (R.HARD[nm] or 3) - (power - tier)); if tier > power then need = need * 2 end
  R.blockHits = R.blockHits or {}
  local hits = (R.blockHits[p] or 0) + 1
  if hits < need then R.blockHits[p] = hits; return false, "chipping" end
  R.blockHits[p] = nil; sim.partKill(p)
  local item = (nm == "BCOL") and "COAL" or nm
  if a.isPlayer then give(item, 1) else a.inv[item] = (a.inv[item] or 0) + 1 end
  if R.queuePendingAir then R.queuePendingAir(wx, wy, false) end
  if RUBBLE[nm] or WOODY[nm] then pcall(R.crumble, x, y, 5) end
  if nm == "WOOD" then pcall(checkFell, x, y, 1.4) end
  return true, item
end
function R.actorPlace(a, el, wx, wy, opts)
  local inv = a.isPlayer and R.inventory or a.inv
  if (inv[el] or 0) <= 0 then return false, "no " .. nice(el) end
  local t = eid(el); if not t then return false, el .. " is not a real material" end
  local x, y = canvasOf(wx, wy); if not onCanvas(x, y) then return false, "off screen" end
  if sim.partID(x, y) then return false, "occupied" end
  local px, py = canvasOf(R.P.x, R.P.y)
  if not (opts and opts.allowOnPlayer) and x >= px - 3 and x <= px + 2 and y >= py - 11 and y <= py then return false, "the player is standing there" end
  local n = sim.partCreate(-1, x, y, t)
  if not n or n < 0 then return false, "blocked" end
  inv[el] = inv[el] - 1
  setMoltenTemp(n, el)
  return true
end
function R.actorFill(a, x1, y1, x2, y2, el)
  local placed, missing = 0, false
  for wy = math.max(y1, y2), math.min(y1, y2), -1 do          -- bottom-up so walls stack sensibly
    for wx = math.min(x1, x2), math.max(x1, x2) do
      local ok, why = R.actorPlace(a, el, wx, wy)
      if ok then placed = placed + 1 elseif why and why:find("^no ") then missing = true end
    end
  end
  return placed, missing
end
function R.actorClear(a, x1, y1, x2, y2, opts)
  local removed, blocked = 0, nil
  for wy = math.min(y1, y2), math.max(y1, y2) do
    for wx = math.min(x1, x2), math.max(x1, x2) do
      local ok, why = R.actorMine(a, wx, wy, opts)
      if ok then removed = removed + 1 elseif why and why:find("better pick") then blocked = why end
    end
  end
  return removed, blocked
end
function R.actorCraft(a, name)
  for i, rc in ipairs(R.RECIPES) do
    if rc.out == name or rc.txt == name then
      local okst, why = R.nearStation(rc.st or "hand")
      if not okst then return false, why end
      local inv = a.isPlayer and R.inventory or a.inv
      for el, n in pairs(rc.need) do if (inv[el] or 0) < n and (R.inventory[el] or 0) < n then return false, "need " .. n .. " " .. nice(el) end end
      for el, n in pairs(rc.need) do
        local take = math.min(inv[el] or 0, n)
        inv[el] = (inv[el] or 0) - take
        if take < n then R.inventory[el] = (R.inventory[el] or 0) - (n - take) end
      end
      if a.isPlayer then give(rc.out, rc.n) else a.inv[rc.out] = (a.inv[rc.out] or 0) + rc.n end
      R.stats.crafted[rc.out] = (R.stats.crafted[rc.out] or 0) + rc.n
      return true, rc.txt
    end
  end
  return false, "no such recipe"
end
function R.actorGive(a, to, item, n)
  local from = a.isPlayer and R.inventory or a.inv
  local dest = (to == "player" or (to and to.isPlayer)) and R.inventory or (to and to.inv)
  if not dest then return false, "nobody to give to" end
  n = math.min(n or (from[item] or 0), from[item] or 0)
  if n <= 0 then return false, "none" end
  from[item] = from[item] - n; dest[item] = (dest[item] or 0) + n
  if dest == R.inventory then R.rebuildHotbar() end
  return true, n
end
function R.actorLight(a, wx, wy)
  local inv = a.isPlayer and R.inventory or a.inv
  if (inv.WOOD or 0) < 1 then return false, "no wood for a torch" end
  local x, y = canvasOf(wx, wy); if not onCanvas(x, y) or sim.partID(x, y) then return false, "no room" end
  local wd = eid("WOOD"); local p = sim.partCreate(-1, x, y, wd)
  if not p or p < 0 then return false, "blocked" end
  sim.partCreate(-1, x, y - 1, wd)
  R.torches = R.torches or {}
  R.torches[#R.torches + 1] = { x = wx, y = wy - 2, born = R.frame }
  inv.WOOD = inv.WOOD - 1
  return true
end

-- ============================================================ NAVIGATION
-- Shared A* over a coarse grid so any character (colonist, enemies, vehicles) can actually get somewhere:
-- walking, step-ups, jumps, drops, and optionally digging through soft ground when there is no open route.
-- R.findPath(sx, sy, gx, gy, opts) -> { {x=,y=,dig=bool}, ... } in world coords, or nil.
local NAV_CELL = 4
local function navSolid(wx, wy)
  for dy = 0, NAV_CELL - 1 do for dx = 0, NAV_CELL - 1 do if solidW(wx + dx, wy + dy) then return true end end end
  return false
end
local function navDiggable(wx, wy)
  for dy = 0, NAV_CELL - 1, 2 do for dx = 0, NAV_CELL - 1, 2 do
    local x, y = wx + dx - R.cam.x, wy + dy - R.cam.y
    if x >= M and x < W - M and y >= M and y < H - M then local p = sim.partID(x, y)
      if p then local t = R.MINEABLE[nameOf(sim.partProperty(p, "type"))]; if t and t <= 3 then return true end end end
  end end
  return false
end
function R.findPath(sx, sy, gx, gy, opts)
  opts = opts or {}
  local maxNodes = opts.maxNodes or 1200
  local canDig = opts.dig ~= false
  local c = NAV_CELL
  local function key(cx, cy) return cx * 100000 + cy end
  local scx, scy = floor(sx / c), floor(sy / c)
  local gcx, gcy = floor(gx / c), floor(gy / c)
  local open = { { cx = scx, cy = scy, g = 0, f = 0 } }
  local came, gscore, closed = {}, { [key(scx, scy)] = 0 }, {}
  local best, bestD
  local n = 0
  while #open > 0 and n < maxNodes do
    n = n + 1
    local bi, bf = 1, open[1].f
    for i = 2, #open do if open[i].f < bf then bi, bf = i, open[i].f end end
    local cur = table.remove(open, bi)
    local ck = key(cur.cx, cur.cy)
    if closed[ck] then goto continue end
    closed[ck] = true
    local d = math.abs(cur.cx - gcx) + math.abs(cur.cy - gcy)
    if not bestD or d < bestD then bestD, best = d, cur end
    if d <= 1 then best = cur; break end
    for _, mv in ipairs({ {1,0,1}, {-1,0,1}, {1,-1,1.3}, {-1,-1,1.3}, {0,-1,1.6}, {0,-2,2.6}, {1,1,1.1}, {-1,1,1.1}, {0,1,1}, {0,2,1.2}, {0,3,1.4} }) do
      local nx, ny, cost = cur.cx + mv[1], cur.cy + mv[2], mv[3]
      local wx, wy = nx * c, ny * c
      -- SKY CEILING (nav): raised 2026-09-01 from -400 to -900 to match the camera clamp
      -- in updateCamera. These two are independent and were 100px apart, so pathfinding
      -- would have refused to route a companion up a mountain the player could now reach.
      if wy < -900 or wy > DEPTH then goto skip end
      local blocked = navSolid(wx, wy) or navSolid(wx, wy - c)     -- body is two cells tall
      local dig = false
      if blocked then
        if canDig and navDiggable(wx, wy) then dig = true; cost = cost + 6 else goto skip end
      end
      -- must have ground under it, be a drop, or be a dig
      local supported = navSolid(wx, wy + c) or dig or mv[2] > 0
      if not supported then cost = cost + 0.6 end
      local nk = key(nx, ny)
      local ng = cur.g + cost
      if not gscore[nk] or ng < gscore[nk] then
        gscore[nk] = ng
        came[nk] = { cur = cur, dig = dig }
        open[#open + 1] = { cx = nx, cy = ny, g = ng, f = ng + (math.abs(nx - gcx) + math.abs(ny - gcy)) * 1.05 }
      end
      ::skip::
    end
    ::continue::
  end
  if not best then return nil end
  local path, node = {}, best
  while node do
    local nk = key(node.cx, node.cy)
    table.insert(path, 1, { x = node.cx * c + c / 2, y = node.cy * c + c - 1, dig = came[nk] and came[nk].dig or false })
    node = came[nk] and came[nk].cur or nil
  end
  return path, n
end
-- Open TPT's magnifier locked onto a world rect (machines use this so the player works inside the machine)
function R.zoomTo(wx, wy, size)
  size = math.max(16, math.min(120, size or 48))
  local sx = math.max(M, math.min(W - M - size, floor(wx - R.cam.x - size / 2)))
  local sy = math.max(M, math.min(H - M - size, floor(wy - R.cam.y - size / 2)))
  local factor = math.max(2, math.min(8, floor(220 / size)))
  local ok = pcall(ren.zoomScope, sx, sy, size)
  local wx2 = (sx + size / 2 > W / 2) and 4 or (W - size * factor - 4)
  pcall(ren.zoomWindow, math.max(0, floor(wx2)), 20, factor, floor(size * factor))
  pcall(ren.zoomEnabled, true)
  R.zoomLocked = { x = wx, y = wy, size = size }
  return ok
end
function R.zoomOff() R.zoomLocked = nil; pcall(ren.zoomEnabled, false); return true end
function R.mount(v) if not v then return false end; v.mounted = R.frame; R.ride = v; say("Riding - press S to get off"); return true end
function R.dismount() local v = R.ride; R.ride = nil; if v then R.P.y = (v.y or R.P.y) - 8; R.P.vy = -1 end; say("Dismounted"); return true end
R.hooks.mount = R.hooks.mount or {}
-- "telemetry", "icons" FIRST, deliberately: it installs R.tlog and the project-wide error capture,
-- and every plugin loaded after it can then log its own load failures. Loading it last
-- would mean the diagnostic layer is absent for exactly the failures most worth catching.
-- acq_* acquisition plugins appended 2026-09-02. Each gives a family of stock Powder Toy
-- elements a real acquisition pathway, per design-material-progression{,-part2}.md. Ordered
-- fluids -> solids -> energy -> special -> forage -> machines so that the machines lane,
-- which consumes tokens the others define, loads last.
R.PLUGINS = { "telemetry", "icons", "world", "enemies", "machines", "machines2", "items", "terraweapons", "vehicles", "survival", "companion", "save", "ui", "guide", "netlink", "automation", "fieldtools", "acq_fluids", "acq_solids", "acq_energy", "acq_special", "acq_forage", "acq_machines", "nat_process", "sandbox", "sbmaterials", "sbtools", "periodic", "thermo", "chemistry", "drawperf", "isotopes", "reactions", "instruments" }
R.pluginStatus = {}
-- Critical distribution bug: this only ever checked the original dev
-- machine's absolute path. On any other machine (a packaged copy, a
-- friend's download) that path doesn't exist, so EVERY plugin -- machines,
-- survival, items, ui, guide, enemies, vehicles, companion, save, world --
-- silently loaded as "absent" for anyone else. Same dual-path fix as
-- 86_rpg_loader.lua: absolute dev path first (so a stray shadow copy
-- elsewhere on the dev machine can never shadow the real source), relative
-- path second (what a portable copy handed to someone else actually ships).
function R.reloadPlugin(name)
  local paths = {
    "../scripts/lua/rpg_plugins/" .. name .. ".lua",
    "scripts/lua/rpg_plugins/" .. name .. ".lua",
    "D:/The-Powder-Toy/scripts/lua/rpg_plugins/" .. name .. ".lua",
    "D:/powder-toy/scripts/lua/rpg_plugins/" .. name .. ".lua",
  }
  local path, f
  for _, p in ipairs(paths) do f = io.open(p, "r"); if f then path = p; break end end
  if not f then R.pluginStatus[name] = "absent"; return "absent" end
  f:close()
  local chunk, lerr = loadfile(path); if not chunk then R.pluginStatus[name] = "load error: " .. tostring(lerr); return R.pluginStatus[name] end
  local ok, perr = pcall(chunk); R.pluginStatus[name] = ok and "ok" or ("error: " .. tostring(perr)); return R.pluginStatus[name]
end
for _, name in ipairs(R.PLUGINS) do R.reloadPlugin(name) end
-- No cave backdrops wanted. Until world.lua drops it, strip the world plugin's draw hook after every load.
if R.caveBackdrop == nil then R.caveBackdrop = false end
if R.caveBackdrop == false then for i = #R.hooks.draw, 1, -1 do local f = R.hooks.draw[i]; if type(f) == "table" and f.tag == "world" then table.remove(R.hooks.draw, i) end end end
return "rpg.lua v4 loaded"
