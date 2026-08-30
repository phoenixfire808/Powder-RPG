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
local WATER_LEVEL = 200
local function id(name) local i = elem["DEFAULT_PT_"..name]; if i then return i end; for j = 0, 511 do local ok, n = pcall(elem.property, j, "Name"); if ok and n == name then return j end end; return nil end
local idcache = {}
local function eid(name) local v = idcache[name]; if v == nil then v = id(name) or false; idcache[name] = v end; return v or nil end
local namecache = {}
local function nameOf(t) local n = namecache[t]; if n then return n end; local ok, v = pcall(elem.property, t, "Name"); n = ok and v or tostring(t); namecache[t] = n; return n end
local function has(name) return eid(name) ~= nil end

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
R.NAMES = { GOO="Dirt", GRNT="Granite", GRSS="Grass", PLNT="Plant", WOOD="Wood", SAND="Sand", ICE="Ice", SNOW="Snow", CLST="Clay",
  COAL="Coal", BCOL="Coal dust", IRON="Iron ore", METL="Iron bar", STEL="Steel", GOLD="Gold", CU="Copper", DU="Uranium ore", URAN="Uranium",
  DMND="Diamond", QRTZ="Quartz", TTAN="Titanium", BRCK="Brick", GLAS="Glass", INSL="Insulation", WATR="Water", DSTW="Pure water", LAVA="Lava",
  BRMT="Bronze", BMTL="Scrap metal", PSCN="P-silicon", NSCN="N-silicon", LEDL="LED lamp", WIFI="Wireless", B4C="Control rod", TRBN="Turbine",
  TEG="Thermo-gen", UO2="Fuel pellet", STNE="Stone", OIL="Oil", FIRE="Fire", GLOW="Glow", WORKBENCH="Workbench", FURNACE="Furnace kit", ANVIL="Anvil",
  -- Found 2026-08-29: R.nice()'s only fallback for an element with no entry here is
  -- the raw string itself -- there's no real-engine-name lookup. RESEARCH/ADVLAB
  -- (added rounds 1/4) fell back to an awkward auto-capitalized guess ("Advlab"),
  -- and GRPH (a real stock element, added round 4) showed its bare code with no
  -- fallback at all. STNE proves R.NAMES is genuinely the only mechanism for a
  -- readable name here, not something GRPH would get automatically over time.
  RESEARCH="Research Bench", ADVLAB="Advanced Lab", GRPH="Graphite" }
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
function R.setTptMenus(on)
  R.tptMenus = on and true or false
  -- tpt.hud(0) at boot above hides the WHOLE native HUD, toolbar included --
  -- that's where the Open/stamp-browse button lives (Ctrl+click it to
  -- browse saved stamps), so without this it stayed unreachable even with
  -- the element menu back on. Tying it to the same toggle already used
  -- to mean "give me native TPT controls."
  pcall(tpt.hud, R.tptMenus and 1 or 0)
  local n = 0; pcall(function() n = tpt.num_menus() end)
  for i = 0, (n or 0) - 1 do pcall(tpt.menu_enabled, i, R.tptMenus and 1 or 0) end
  -- Same click that toggles this used to leave R.mouse.l stuck. Clearing it
  -- here is why "TPT menus on then off" stopped the spam -- do it on purpose.
  if R.releaseMouse then R.releaseMouse() end
  return R.tptMenus
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
pcall(R.setFX, R.fxOn)
R.origColours = R.origColours or {}
for name, col in pairs({ BMTL = 0xFFF060, BRMT = 0xFF9030 }) do
  local id = elem["DEFAULT_PT_" .. name]
  if id then if R.origColours[name] == nil then R.origColours[name] = elem.property(id, "Colour") end
    pcall(elem.property, id, "Colour", col) end
end
-- plugin hook API: plugins append callables to these lists (see scripts/lua/rpg_plugins/README.md)
-- IN-GAME CHAT: press Enter to talk to your colonists. Plugins/drivers read R.chatPending() and reply
-- with R.chatSay(who, text); everything is plain data so a local model can drive it over the bridge.
-- IN-GAME FEEDBACK: F8 (or Esc menu) opens a text box for a bug report or
-- suggestion. Always saved locally to feedback.txt next to the game (works
-- with zero setup); also POSTed to R.FEEDBACK_WEBHOOK if one is filled in
-- (a Discord channel webhook URL, say) so reports show up automatically
-- instead of someone having to remember to send the file over.
R.FEEDBACK_WEBHOOK = "https://discord.com/api/webhooks/1543391892128006235/0Bk5UVk0-O-McNWYhc3--YyqxsT2XEmuMmCfw-BOBb1leh10yMQfRMFyPpp0o_9uE1re"
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
      local ok2, handle = pcall(http.post, R.FEEDBACK_WEBHOOK, body, { { "Content-Type", "application/json" } })
      if ok2 and handle then R.pendingHttp[#R.pendingHttp + 1] = handle end
    end
  end
  say("Feedback saved" .. ((R.FEEDBACK_WEBHOOK ~= "") and " and sent - thanks!" or " - thanks!"))
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
R.VERSION = "1.15.23"

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
function R.checkLocalChangelog()
  local seen = ""
  local f = io.open("changelog-seen.txt", "r")
  if f then seen = (f:read("*a") or ""):gsub("%s+$", ""); f:close() end
  if seen == R.VERSION then return end
  local pending = {}
  for _, entry in ipairs(R.CHANGELOG) do
    if entry.ver == seen then break end
    pending[#pending + 1] = entry
  end
  if #pending == 0 then return end
  local lines = {}
  for _, entry in ipairs(pending) do
    lines[#lines + 1] = "v" .. entry.ver .. ":"
    for _, n in ipairs(entry.notes) do lines[#lines + 1] = "- " .. n end
    lines[#lines + 1] = ""
  end
  R.localChanges = { notes = table.concat(lines, "\n"), count = #pending }
  R.changesPromptOpen = true
end
function R.dismissLocalChangelog()
  R.changesPromptOpen = false
  local f = io.open("changelog-seen.txt", "w"); if f then f:write(R.VERSION); f:close() end
end
-- Reopens the FULL history any time, not just the "new since last seen"
-- subset the boot check shows -- the ask was "I want to see our changes...
-- so I can keep track of stuff," which the fire-once popup alone doesn't
-- cover once it's been dismissed. Esc menu > "View full changelog".
function R.openFullChangelog()
  local lines = {}
  for _, entry in ipairs(R.CHANGELOG) do
    lines[#lines + 1] = "v" .. entry.ver .. ":"
    for _, n in ipairs(entry.notes) do lines[#lines + 1] = "- " .. n end
    lines[#lines + 1] = ""
  end
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
  bat:write("tasklist /FI \"IMAGENAME eq PowderToyRPG.exe\" 2>NUL | find /I \"PowderToyRPG.exe\" >NUL\r\n")
  bat:write("if not errorlevel 1 (\r\n")
  bat:write("  timeout /t 1 /nobreak >NUL\r\n")
  bat:write("  goto wait\r\n")
  bat:write(")\r\n")
  bat:write("powershell -NoProfile -Command \"Expand-Archive -Path 'update.zip' -DestinationPath '.' -Force\"\r\n")
  bat:write("del update.zip\r\n")
  bat:write("start \"\" \"%~dp0Play.bat\"\r\n")
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
R.hooks = { tick = { profile = true, throttle = true }, draw = { profile = true }, drawHUD = { profile = true }, key = {}, mousedown = {}, mouseup = {}, place = {}, mine = {}, craft = {}, gen = {}, newworld = {}, sandbox = {}, keyup = {}, wheel = {}, mousemove = {}, chat = {} }
-- FRAME BUDGET: every hook is timed, and any tick hook that exceeds its budget is automatically run less
-- often so one heavy plugin can never eat the frame rate. R.perf holds the measured cost of each hook.
R.perf = R.perf or {}          -- tag -> { ms = exponential moving average, skip = run 1 frame in N }
R.perfOn = (R.perfOn == nil) and true or R.perfOn
local TICK_BUDGET_MS = 1.2     -- per hook, per frame
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
          if rec.ms > TICK_BUDGET_MS * 4 then rec.skip = 4
          elseif rec.ms > TICK_BUDGET_MS then rec.skip = 2
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
local surfCache = {}
local function surfaceAt(wx)
  local s = surfCache[wx]; if s then return s end
  local v = 0.55 * smooth1(wx, 160, 1) + 0.30 * smooth1(wx, 60, 2) + 0.15 * smooth1(wx, 22, 3)
  s = floor(120 + v * 100); surfCache[wx] = s; return s
end
local BIOME_W = 900
local MAP_TYPES = { "mixed", "forest", "desert", "snow", "swamp" }
local MAP_TYPE_OK = { mixed = 1, forest = 1, desert = 1, snow = 1, swamp = 1 }
local MAP_TYPE_LABEL = {
  mixed = "Mixed (all biomes)",
  forest = "Forest",
  desert = "Desert",
  snow = "Snow",
  swamp = "Swamp",
}
R.mapType = (type(R.mapType) == "string" and MAP_TYPE_OK[R.mapType]) and R.mapType or "mixed"
R.createSandbox = R.createSandbox == true
local function forcedBiome()
  local t = R.mapType
  if type(t) == "string" and t ~= "mixed" and MAP_TYPE_OK[t] then return t end
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
  local u = (wx + warp) / BIOME_W
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
  if ok and b and b >= 0 then local props = elements.element(elements.DEFAULT_PT_WATR); props.Name = "BLD"; props.Description = "Blood."; props.Colour = 0xAA1020
    pcall(elements.element, b, props); idcache["BLD"] = b end
end
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
local ROCK = has("GRNT") and "GRNT" or "BRCK"
local UORE = has("DU") and "DU" or "URAN"
local HASCU = has("CU")
local function genBase(wx, wy)
  if wy >= DEPTH then return "DMND" end
  local surf = surfaceAt(wx)
  if wy <= surf then
    if surf > WATER_LEVEL + 3 and wy > WATER_LEVEL then return "WATR" end
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
  if wy <= surf + 20 then return b.soil end       -- a real topsoil band before caves can start, not a thin skin over them
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
local CAM_MAX = 4   -- smooth follow: up to 4px every other frame (a full-canvas shift costs ~15ms, so not every frame)
-- Arrow keys nudge these, shifting where on screen the auto-follow below
-- targets the character -- lets you see further above/below/either side
-- without taking over the camera outright; it still follows your character,
-- just recentred around this offset instead of dead centre.
R.camYOffset = R.camYOffset or 0
R.camXOffset = R.camXOffset or 0
local CAM_OFFSET_MAX = 150
local function updateCamera()
  if R.frame % 2 == 1 then return end
  local px, py = R.P.x - R.cam.x, R.P.y - R.cam.y
  local ex, ey = px - (306 + R.camXOffset), py - (200 + R.camYOffset)
  local dx = (math.abs(ex) > 20) and math.max(-CAM_MAX, math.min(CAM_MAX, floor(ex * 0.25 + (ex > 0 and 0.5 or -0.5)))) or 0
  local dy = (math.abs(ey) > 28) and math.max(-CAM_MAX, math.min(CAM_MAX, floor(ey * 0.25 + (ey > 0 and 0.5 or -0.5)))) or 0
  if math.abs(ex) > 20 and dx == 0 then dx = ex > 0 and 1 or -1 end
  if math.abs(ey) > 28 and dy == 0 then dy = ey > 0 and 1 or -1 end
  if R.cam.y + dy < -300 then dy = -300 - R.cam.y end
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
  R.seed = seed or 7; R.tiles = {}; surfCache = {}; treeCache = {}
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
  R.sandbox = false
  -- Same class of bug as R.sandbox above: R.setTptMenus() (the function that
  -- actually calls tpt.hud/tpt.menu_enabled to hide native TPT's far-right
  -- toolbar and bottom bar) was ONLY ever invoked manually from the Esc menu
  -- toggle -- never automatically at world start. R.tptMenus reading false by
  -- default is just an inert Lua variable; it never proved the real native
  -- HUD calls actually fired. Drew: native menus visible unless he's actually
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
  R.lastMine = nil; R.lastSwing = nil; R.lastPlace = nil; R.lastHitAt = nil; R.blockHits = {}  -- frame-stamped cooldowns must reset with R.frame, or mining/chopping/placing stays dead after a new seed until the frame counter climbs back up
  if R.grid == nil then R.grid = true end  -- build grid on by default
  R.P.x = 0; R.P.y = surfaceAt(0) - 1; R.P.vx, R.P.vy = 0, 0
  R.cam.x = floor(R.P.x) - 306; R.cam.y = floor(R.P.y) - 200
  sim.clearSim(); fillRegion(M, M, W - M - 1, H - M - 1); R.clearAround()
  do -- classic Fire display so FIRE/LAVA/PLSM render as blazing gradients instead of flat orange pixels
    local RE, RF, RB, RS = 0x01, 0x02, 0x20, 0x40
    pcall(function() RE = ren.RENDER_EFFE or RE; RF = ren.RENDER_FIRE or RF; RB = ren.RENDER_BASC or RB; RS = ren.RENDER_SPRK or RS end)
    pcall(ren.renderModes, { RE, RF, RB, RS })   -- per knowledge/research-tooling: set modes directly, never useDisplayPreset
  end
  say("World " .. R.seed .. "  " .. (MAP_TYPE_LABEL[R.mapType or "mixed"] or "Mixed") .. ".  Esc = menu & controls")
  R.setMenuOpen(R.tipsOn ~= false)
  if wantSandbox then R.sandbox = true; pcall(R.sandboxFill); say("SANDBOX: everything unlocked") end
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
local function platformAt(wx, wy) local x, y = wx - R.cam.x, wy - R.cam.y
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
  R.hurt = nil; R.bloodLast = nil; R.uvAccum = 0; R.radAccum = 0
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
      if fall > 60 and landVy >= 3.8 and not (R.accOn("cloud") and fall < 90) then local dmg = floor((fall - 60) * 0.5); if dmg > 0 then R.hp = math.max(0, R.hp - dmg); R.hurt = R.frame; R.shake = { t = R.frame, mag = math.min(8, 2 + dmg / 5) }; say("Ouch! Fell " .. floor(fall / 4) .. "m (-" .. dmg .. " HP)") end end end
    P.apex = nil
    if P.vy > 0 then P.vy = 0 end; P.coyote = 6; P.dj = false; P.fuel = 45 else P.coyote = math.max(0, P.coyote - 1) end
  if math.abs(P.vx) > 0.2 and P.onGround then P.anim = (P.anim or 0) + 1 end
  if R.frame % 5 == 0 then local dmg = 0
    for yy = y + BOXT - 1, y do for xx = x + BOXL - 1, x + BOXR + 1 do local p = sim.partID(xx - R.cam.x, yy - R.cam.y)
      if p then local n = nameOf(sim.partProperty(p, "type")); local t = sim.partProperty(p, "temp") or 295
        if (n == "LAVA" or n == "FIRE" or n == "PLSM") then if not R.accOn("lava") then dmg = dmg + 3 end elseif n == "ACID" or n == "CAUS" then dmg = dmg + 2 elseif t > 500 and not R.accOn("lava") then dmg = dmg + 1 elseif n == "NEUT" then dmg = dmg + 1 end end end end
    if dmg > 0 then R.hp = math.max(0, R.hp - dmg); R.hurt = R.frame end
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
      R.feltTempK = hottest   -- persistent top-left HUD readout reads this (drawn in the main draw function)
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
      for oy = -14, 2 do for ox = -8, 8 do cells = cells + 1
        local p = sim.partID(x + ox - R.cam.x, y + oy - R.cam.y)
        if p then local n = nameOf(sim.partProperty(p, "type"))
          if n == "OXYG" then o2p = o2p + 1 elseif BAD[n] then bad = bad + 1 end end
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
      local target
      -- the surface is free air; the deeper you go the thinner and staler it gets, so a deep base needs life support
      local depth = R.P.y - surfaceAt(floor(R.P.x))
      local thin = math.max(0, math.min(60, (depth - 140) / 900 * 60))
      if liq > 0 and (R.acc and R.accOn("dive")) ~= true then target = 0   -- underwater: nothing to breathe
      else
        -- Confirmed live and by screenshot: a shallow (16m) sealed pocket was reading
        -- "stale air" and draining almost immediately -- the sealed branch used to have
        -- a flat baseline of 12, meaning ANY enclosed room (a house, a shallow dug-out,
        -- a shed) was treated as near-vacuum regardless of depth. That's backwards: a
        -- sealed room already has whatever air was in it when it was sealed, and this
        -- should only turn genuinely dangerous far underground, exactly the reported
        -- expectation. Both branches now start from the same depth-only baseline
        -- (thin=0 near the surface -> ~100 either way); sealing only adds an EXTRA
        -- depth-scaled penalty on top (worse the deeper you are, ~0 near the surface),
        -- instead of an instant, depth-independent floor.
        local base = 100 - thin + src
        if sealed then target = math.max(0, base - thin * 0.7 - bad * 12 + R.o2conc * 1.2)
        else target = base end
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
      if liq == 0 and R.frame % 5 == 0 and countType("OXYG") < OXYG_CAP then
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
          if sy >= 2 and sy < H - 2 and not sim.partID(sx, sy) then
            local e = eid("OXYG"); if e then sim.partCreate(-1, sx, sy, e) end
          end
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
            if ok and cur < 3 then pcall(sim.pressure, cx, cy, math.min(3, cur + 1)) end
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
      if R.frame % 60 == 0 then
        local oxid = eid("OXYG")
        if oxid then
          local released = 0
          for i in sim.parts() do
            if released >= 20 then break end
            if sim.partProperty(i, "type") == oxid then
              local sx, sy = sim.partPosition(i)
              sx, sy = floor(sx), floor(sy)
              local blocked = 0
              for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
                local q = sim.partID(sx + d[1], sy + d[2])
                if q and realSolid(sim.partProperty(q, "type")) then blocked = blocked + 1 end
              end
              if blocked >= 3 then sim.partKill(i); released = released + 1 end
            end
          end
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
local function drawPlayer()
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
R.HARD = { METL=4, GRSS=1, BCOL=1,  GOO=1, SAND=1, SNOW=1, ICE=1, PLNT=1, WOOD=2, CLST=1, COAL=2, GRNT=3, BRCK=3, GLAS=2, IRON=4, CU=4, GOLD=4, QRTZ=4, DU=5, URAN=5, STEL=5, TTAN=6, DMND=8 }
R.blockHits = R.blockHits or {}
R.MINEABLE = { METL=3, GRSS=1, BCOL=1,  GOO=1, SAND=1, SNOW=1, ICE=1, PLNT=1, WOOD=1, CLST=1, STNE=2, COAL=1, BRCK=2, GLAS=2, BRMT=2, IRON=2, GOLD=3, CU=2, DU=4, URAN=4, STEL=4, GRNT=2, TTAN=4, DMND=6, LEAD=3, ZIRC=3, STEL=4, QRTZ=3 }
R.TOOLS = R.TOOLS or {
  pick  = { name="wood pick", power=1, reach=24, speed=8, radius=3 },
  axe   = { name="axe", power=1, reach=26, speed=6, radius=4, only={WOOD=1, PLNT=1, GRSS=1} },
  sword = { name="wood sword", reach=34, dmg=15, speed=12 },
  torch = { name="torch", reach=56 },
  bucket= { name="bucket", reach=56 },
}
R.PICKS = { {name="wood pick", power=1, reach=24, speed=8, need={WOOD=6}, st="hand", desc="Digs dirt, sand and coal; granite and iron only slowly"}, {name="stone pick", power=2, reach=26, speed=7, need={GRNT=6, WOOD=4}, st="workbench", desc="Digs granite, coal and iron at full speed"}, {name="iron pick", power=3, reach=30, speed=6, need={METL=5, WOOD=4}, st="anvil", desc="Digs gold and quartz too; faster"}, {name="steel pick", power=4, reach=34, speed=5, need={STEL=5, WOOD=4}, st="anvil", desc="Digs uranium ore and deep titanium"}, {name="diamond pick", power=6, reach=40, speed=4, need={DMND=4, STEL=4}, st="anvil", desc="Digs everything, including bedrock"} }
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
  { id="bench", txt="Craft a Workbench (E) and place it", done=function() return #R.stations > 0 end, reward={GRNT=6} },
  { id="pick", txt="Dig 6 Granite with the wood pick (slow) and craft a stone pick at the workbench", done=function() return R.stats.crafted["stone pick"] or R.TOOLS.pick.power >= 2 and (R.stats.crafted["stone pick"] or false) end, reward={COAL=3} },
  { id="coal", txt="Mine 10 Coal (black seams underground)", done=function() return (R.stats.mined.COAL or 0) >= 10 end, reward={GRNT=10} },
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
  -- by hand
  { out="WORKBENCH", n=1, need={WOOD=10}, st="hand", txt="Workbench", desc="Place it and stand near it: unlocks tools, kits and building blocks" },
  { out="FURNACE", n=1, need={GRNT=20, COAL=5}, st="workbench", txt="Furnace kit", desc="Granite box with a coal bed. Place, then light with the torch (slot 4). Smelts ore while burning" },
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
  { out="GOLD", n=1, need={GOLD=1, COAL=1}, st="furnace", txt="Refined gold", desc="Purify gold ore (used in circuits)" },
  { out="CU", n=2, need={GOLD=1, METL=1}, st="furnace", txt="Copper", desc="Conductive copper for wiring" },
  -- workbench
  { out="INSL", n=4, need={SAND=2, WOOD=2}, st="workbench", txt="Insulation", desc="Blocks heat and electricity. Line a base with it" },
  { out="TTAN", n=1, need={STEL=2, DU=1}, st="anvil", txt="Titanium plate", desc="Very hard, heat-resistant plate" },
  -- electrics (workbench, needs furnace materials)
  { out="PSCN", n=2, need={CU=1, GLAS=1}, st="workbench", txt="P-silicon", desc="Semiconductor: passes sparks one way. Basis of circuits" },
  { out="LEDL", n=2, need={GLAS=1, CU=1}, st="workbench", txt="LED lamp", desc="Lights up when sparked" },
  { out="WIFI", n=1, need={CU=2, GOLD=1}, st="workbench", txt="Wireless link", desc="Carries sparks between two WIFI blocks on the same channel" },
  { out="B4C", n=1, need={COAL=4, METL=1}, st="anvil", txt="Control rod", desc="Boron carbide: absorbs neutrons in a reactor" },
  { out="TRBN", n=1, need={STEL=6, CU=2}, st="anvil", txt="Turbine stage", desc="Turns steam/pressure into electricity" },
  { out="TEG", n=1, need={CU=3, GLAS=2}, st="workbench", txt="Thermoelectric", desc="Makes power from a temperature difference" },
  { out="UO2", n=1, need={DU=4, COAL=1}, st="furnace", txt="Fuel pellet", desc="Uranium dioxide reactor fuel. Handle with lead" },
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
local TOOLSLOTS = { "tool:pick", "tool:axe", "tool:sword", "tool:torch", "tool:bucket" }
function R.rebuildHotbar()
  R.hotbar = R.hotbar or {}
  for s = 1, 5 do R.hotbar[s] = TOOLSLOTS[s] end
  local seen = {}; for s = 6, 10 do local v = R.hotbar[s]; if v and not v:find("^tool:") then seen[v] = true else R.hotbar[s] = nil end end
  local names = {}; for k, v in pairs(R.inventory or {}) do if v > 0 and not seen[k] then names[#names+1] = k end end; table.sort(names)
  for s = 6, 10 do if not R.hotbar[s] then R.hotbar[s] = table.remove(names, 1) end end
  R.sel = R.sel or 1
end
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
local MAX_CLUMP = 5            -- only genuinely tiny floating fragments (5 cells or fewer) are unsupported
-- MAX_CLUMP makes sense for RUBBLE (a small floating rock chip vs a big cliff that's
-- clearly still structurally sound) but not for WOODY -- a chopped tree's whole
-- leftover canopy is easily 100+ cells and has zero self-support at ANY size, so
-- capping it at 5 meant crumble refused to touch a real leftover canopy at all
-- (confirmed the actual cause of "chopped the tree but the canopy's still there"
-- alongside the fellFrom connectivity gap above). Pure-woody clumps use a much
-- higher practical cap instead of none, just to bound one scan's worst case.
local MAX_WOODY_CLUMP = 4000
local function crumbleOk(nm) return nm and (RUBBLE[nm] or WOODY[nm]) end
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
              if #cells > (allWoody and MAX_WOODY_CLUMP or MAX_CLUMP) then big = true; break end
              for dy = -1, 1 do for dx = -1, 1 do stack[#stack + 1] = { ax + dx, ay + dy } end end
            end
          end
        end
        if not big and #cells > 0 then
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
    local got = {}; local r = fine and (R.brush or 0) or (tool.radius or 3); local blocked; local chipped = 0
    R.lastHitAt = R.frame; R.swingAt = { mx, my, R.frame }
    for y = my-r, my+r do for x = mx-r, mx+r do local p = sim.partID(x, y)
      if p and (x-mx)^2 + (y-my)^2 <= r*r + 1 then local nm = nameOf(sim.partProperty(p, "type")); local tier = R.MINEABLE[nm]
        if tier and (not tool.only or tool.only[nm]) then
          if tier > tool.power + 1 then blocked = nm
          else local need = fine and 1 or math.max(1, (R.HARD[nm] or 3) - (tool.power - tier)); if tier > tool.power then need = need * 2 end
            local hits = (R.blockHits[p] or 0) + 1      -- per particle: ids are stable across camera shifts
            if hits >= need then R.blockHits[p] = nil; sim.partKill(p); local item = (nm == "BCOL") and "COAL" or nm; give(item, 1); got[item] = (got[item] or 0) + 1
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
              pcall(sim.pressure, floor(x / sim.CELL), floor(y / sim.CELL), -8)
            else R.blockHits[p] = hits; chipped = chipped + 1 end end end end end end
    -- every swing near a trunk damages the tree, even once the aim point is already hollow
    if key == "axe" or key == "pick" then pcall(checkFell, mx, my, (key == "axe") and 1.4 or 0.55) end
    pcall(R.crumble, mx, my, (tool.radius or 3) + 2)
    local t = {}; for k, v in pairs(got) do t[#t+1] = "+" .. v .. " " .. nice(k) end
    if #t > 0 then R.hint = table.concat(t, "  ") .. (chipped > 0 and "  (chipping...)" or ""); R.rebuildHotbar()
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
  elseif kind == "FURNACE" then local el = has("GRNT") and "GRNT" or "BRCK"
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
local FELL_MAX = 6000
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
-- Native TPT brush (Tab / options menu / HUD wheel) is the source of truth.
-- Survival placeAt used to ignore it and keep a private 0-4 square, so changing
-- the brush in the menu did nothing in-game. These must run inside a real
-- interface event (onTick / onKey / onWheel) -- tpt.brushID/brushRadius assert that.
local BRUSH_ID = { circle = 0, square = 1, triangle = 2 }
local BRUSH_NAME = { [0] = "circle", [1] = "square", [2] = "triangle" }
local BRUSH_R_MAX = 40
function R.pullNativeBrush()
  -- tpt.brushID / brushRadius assert eventTraitInterface. TICK does not have
  -- it; KEY/MOUSE/WHEEL do. Only call this from those handlers.
  local ok, id = pcall(tpt.brushID)
  local ok2, rx, ry = pcall(tpt.brushRadius)
  R._brushPullErr = (not ok and tostring(id)) or (not ok2 and tostring(rx)) or nil
  if ok and type(id) == "number" then
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
  pcall(tpt.brushID, BRUSH_ID[shape] or 1)
  pcall(tpt.brushRadius, r, r)
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
local function placeAt(mx, my, fine)
  local el = selected(); if not el or el:find("^tool:") then R.hint = "pick a block (palette or slots 6-0) to place"; return end
  if inv(el) <= 0 then R.hint = "none left"; return end
  if runHooks(R.hooks.place, el, mx, my, fine) then return end   -- a plugin handled this item
  if R.ITEMS[el] then if (R.frame - (R.lastPlace or -99)) < 20 then return end; R.lastPlace = R.frame; R.inventory[el] = inv(el) - 1; buildStation(el, mx, my); R.mouse.r = false; return end
  if not fine and not inReach(mx, my, 30) then R.hint = "out of reach"; return end
  if (R.frame - (R.lastPlace or -99)) < 2 then return end; R.lastPlace = R.frame
  R.pullNativeBrush()
  local t = eid(el == "COAL" and has("BCOL") and "BCOL" or el); if not t then return end
  local placed = 0; local px, py = R.P.x - R.cam.x, R.P.y - R.cam.y
  local rx = fine and 0 or (R.brushRx or R.brush or 1)
  local ry = fine and 0 or (R.brushRy or R.brush or 1)
  local shape = R.brushShape or "square"
  -- CTRL+SHIFT together: box mode -- track the anchor only, the whole rectangle
  -- is filled once on release (see onMouseUp/commitBox), not per-tick like a line.
  if R.ctrlHeld and R.shiftHeld then
    if not R.placeAnchor then R.placeAnchor = { mx, my }; R.placeBox = true end
    return
  end
  -- CTRL or SHIFT alone: snap to the grid and lock to a straight line from where
  -- the stroke began (fast walls and floors) -- SHIFT does the same thing CTRL
  -- already did, since "Shift-drag to draw a line" was the actual reported gesture.
  if R.ctrlHeld or R.shiftHeld then
    if not R.placeAnchor then R.placeAnchor = { mx, my } end
    local ax, ay = R.placeAnchor[1], R.placeAnchor[2]
    if math.abs(mx - ax) >= math.abs(my - ay) then my = ay else mx = ax end
  end
  local g = R.gridSize or 4
  local x1, y1, x2, y2 = mx - rx, my - ry, mx + rx, my + ry
  if R.grid or R.ctrlHeld then
    local gx = floor((mx + R.cam.x) / g) * g - R.cam.x; local gy = floor((my + R.cam.y) / g) * g - R.cam.y
    x1, y1, x2, y2 = gx - g*rx, gy - g*ry, gx + g*rx + g - 1, gy + g*ry + g - 1
  end
  for y = y1, y2 do for x = x1, x2 do
    if R.brushHit(x, y, mx, my, rx, ry, shape) then
      local inPlayer = x >= px + BOXL - 1 and x <= px + BOXR + 1 and y >= py + BOXT - 1 and y <= py
      if inv(el) > 0 and not sim.partID(x, y) and not inPlayer then local n = sim.partCreate(-1, x, y, t); if n and n >= 0 then R.inventory[el] = inv(el) - 1; placed = placed + 1; setMoltenTemp(n, el) end end
    end
  end end
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
-- BUILD MODE: while the TPT zoom window is locked open and the mouse is inside it, every mouse event goes to TPT
-- (native brush, wheel = brush size, right-click erase); the RPG resumes when the mouse leaves the window.
local function inZoom(x, y)
  local ok, en = pcall(ren.zoomEnabled); if not ok or not en then return false end
  local ok2, zx, zy, zf, zs = pcall(ren.zoomWindow); if not ok2 then return false end
  return x >= zx and x < zx + zs and y >= zy and y < zy + zs
end
R.inZoom = inZoom
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
  -- TPT native brush only skips placement when Lua returns false; nil/true lets the click
  -- through to Window::DoMouseDown (GameView.cpp). Title/inactive used to return nil, so
  -- Create/Play held the native brush down through world start -- sand spray every new seed.
  if titleMouseDown(x, y) then return false end
  if not R.active then return false end
  R.mouse.x, R.mouse.y = x, y
  -- Modal popups: click their button to dismiss (or click anywhere else on
  -- them to just swallow the click) -- explicitly asked for: not wanting to
  -- have to reach for the keyboard for something this simple.
  if R.changesPromptOpen then if hitRect(x, y, R.changesBtnRect) then R.dismissLocalChangelog() end; return false end
  if R.updatePromptOpen then if hitRect(x, y, R.updateBtnRect) then R.updatePromptOpen = false end; return false end
  if runHooks(R.hooks.mousedown, x, y, button) then return false end
  if R.menuOpen then R.menuClick(x, y); return false end
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
  if R.zoomPending then R.zoomPending = false; R.zoomClick = true; return false end  -- Z pressed: this click locks the TPT zoom window
  if button == 1 then R.mouse.l = true; R._clickArmed = true; return false
  elseif button == 3 then R.mouse.r = true; return false end end
local function onMouseUp(x, y, button)
  -- Button-state reset runs before ANY early return (title/inactive used to skip
  -- the whole handler when not R.active, so a Create-click release never cleared state).
  if button == 1 then R.mouse.l = false; R._clickArmed = false end; if button == 3 then R.mouse.r = false end
  if R.titleScreen or not R.active then return false end
  if R.placeBox and button == 1 then commitBox(x, y) end
  R.placeAnchor = nil; R.placeBox = false
  runHooks(R.hooks.mouseup, x, y, button); if R.zoomClick then R.zoomClick = false; return end
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
  R.placeBox = false; R.placeAnchor = nil
  R.zoomClick = false; R.zoomPending = false
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
  if not R.active then return end
  pcall(R.pullNativeBrush)
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
  R.pullNativeBrush()
  local cur = R._nativeBrushId
  if type(cur) ~= "number" then cur = BRUSH_ID[R.brushShape] or 1 end
  if cur < 0 or cur > 2 then cur = 0 end
  local nxt = (math.floor(cur) + 1) % 3
  R.brushShape = BRUSH_NAME[nxt] or "circle"
  if (R.brush or 0) == 0 then R.brush = 1 end
  R.pushNativeBrush()
  say("brush shape: " .. (R.brushShape or "?"))
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
  if not R.active or not text or text == "" then return end
  if R.feedbackOpen then if #R.feedbackText < 400 then R.feedbackText = R.feedbackText .. text end
  elseif R.chatOpen then if #R.chatText < 120 then R.chatText = R.chatText .. text end end
end
local function onKeyDown(key, scan, rep, shift, ctrl, alt)
  if R.titleScreen then
    if key == 27 then
      if R.titleCreateOpen then R.titleCreateOpen = false; return false end
      if R.titleSettingsOpen then R.titleSettingsOpen = false; return false end
    end
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
  if CTRLK[key] then R.ctrlHeld = true end
  if ctrl then R.ctrlHeld = true end
  local k = keyName(key)
  if not rep and runHooks(R.hooks.key, k, shift, ctrl, alt) then return false end
  if k == "a" or k == "d" or k == "w" or k == "s" then R.keys[k] = true; return false end
  -- space is left alone: it's TPT's native pause hotkey (hardcoded in GameView, not
  -- suppressible from Lua) and W is now the only jump key, so there's nothing left
  -- for the RPG to do with it -- let it fall through and just pause like normal.
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
  if k == "tab" or k == "v" then cycleBrushShape(); return false end
  local d = (#k == 1) and tonumber(k) or nil   -- single digits only: modifier keycodes are not slot numbers
  if d then R.sel = (d == 0) and 10 or d; return false end
  if k == "z" then R.zoomPending = not R.zoomPending; say(R.zoomPending and "Zoom: move to the spot, click to lock. Z again closes." or "Zoom closed"); return end
  return  -- anything else goes to TPT
end
local function onKeyUp(key, scan, rep, shift, ctrl, alt) if not R.active then return end
  if SHIFTK[key] then R.shiftHeld = false; R.placeAnchor = nil; R.placeBox = false end
  if CTRLK[key] then R.ctrlHeld = false; R.placeAnchor = nil; R.placeBox = false end
  if ARROWK[key] then R.keys[ARROWK[key]] = false; return false end
  local k = keyName(key); runHooks(R.hooks.keyup, k); if R.keys[k] ~= nil then R.keys[k] = false; return false end end

-- ================================================================ UI
local PANEL = { x=70, y=44, w=472, h=290 }
local CELL = 30
local function invNames() local names = {}; for k, v in pairs(R.inventory or {}) do if v > 0 then names[#names+1] = k end end; table.sort(names); return names end
local function craftRows()
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
local function onWheel(x, y, d) if not R.active then return end
  if R.changesPromptOpen then R.changesScroll = math.max(0, (R.changesScroll or 0) - d); return false end
  if R.updatePromptOpen then R.updateScroll = math.max(0, (R.updateScroll or 0) - d); return false end
  if R.menuOpen then R.settingsScroll = math.max(0, (R.settingsScroll or 0) - d); return false end
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
local function drawHotbar()
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
  elseif s then label = nice(s) .. "  x" .. inv(s); sub = "hold LEFT to place    wheel/[ ] size " .. (2*(R.brush or 1)+1) .. "px    Tab/V shape: " .. (R.brushShape or "square")
  else label = "empty slot"; sub = "put blocks in slots 6-0 from your bag (E)" end
  local w1 = #label * 6; local w2 = #sub * 6
  graphics.fillRect(floor((W - w1) / 2) - 4, y0 - 22, w1 + 8, 11, 0, 0, 0, 170)
  graphics.drawText(floor((W - w1) / 2), y0 - 21, label, 255, 230, 150, 255)
  graphics.drawText(floor((W - w2) / 2), y0 - 33, sub, 190, 200, 215, 200)
end
local function drawMinimap()
  local mx, my = W - 110, 4; local sz = 4
  graphics.fillRect(mx-2, my-2, 108, 62, 0, 0, 0, 170)
  local ctx, cty = floor((R.P.x) / TS), floor((R.P.y) / TS)
  for k, t in pairs(R.tiles) do if t.sx1 then
    local dx, dy = t.tx - ctx, t.ty - cty; if dx >= -12 and dx <= 12 and dy >= -6 and dy <= 6 then
      local wy = t.ty * TS; local col = wy < surfaceAt(t.tx * TS) and {90, 140, 220} or (wy > 1450 and {200, 80, 40} or {120, 110, 100})
      graphics.fillRect(mx + 50 + dx*sz, my + 26 + dy*sz, sz, sz, col[1], col[2], col[3], 255) end end end
  graphics.fillRect(mx + 50, my + 26, sz, sz, 255, 255, 255, 255)
end
local function drawPanel()
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
R.MENU = {
  { "Resume", function() R.setMenuOpen(false) end },
  { "Quit to menu", function() R.setMenuOpen(false); R.active = false; R.titleScreen = true end },
  { "Save game (K)", function() R.save() end },
  { "Enemies on/off (N)", function() R.enemies = not R.enemies end },
  { "Show controls on join: on/off", function() R.tipsOn = not R.tipsOn; say("Controls-on-join " .. (R.tipsOn and "ON" or "OFF")) end },
  { "Smart cursor on/off (T)", function() R.smart = (R.smart == false) end },
  { "Snap grid on/off (B)", function() R.grid = not R.grid end },
  { "Minimap on/off (M)", function() R.minimap = not R.minimap end },
  { "HUD on/off (H)", function() R.hud = not R.hud end },
  { "Respawn at surface (R)", function() R.spawnPlayer(); R.setMenuOpen(false) end },
  { "New world (choose map type)...", function() R.setMenuOpen(false); R.active = false; R.titleScreen = true; R.titleCreateOpen = true; R.titleSettingsOpen = false end },
  { "Map type: mixed/forest/desert/snow/swamp (cycles, new terrain only)", function() R.cycleMapType() end },
  { "Fast physics (air off) on/off", function() R.setFast(not R.fast); say(R.fast and "Fast mode: air simulation off" or "Full physics: air/pressure on") end },
  { "TPT element menu on/off", function() R.setTptMenus(not R.tptMenus); say(R.tptMenus and "TPT menus shown" or "TPT menus hidden") end },
  { "Visual effects on/off", function() R.setFX(not R.fxOn); say(R.fxOn and "Effects ON" or "Effects OFF") end },
  -- first real entry in "sliders for the whole world engine" -- cycles through a few day-length presets,
  -- takes effect immediately (R.dayFrac is read live, not a frozen local). More presets/params to follow;
  -- this is a genuine start, not the full ask -- see TODO for what's still uncovered.
  { "Day length: shorter/normal/longer (cycles)", function()
      local presets = { 0.5, 0.65, 0.8 }; local cur = R.dayFrac or 0.65; local idx = 1
      for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
      R.dayFrac = presets[(idx % #presets) + 1]
      say(string.format("Day length: %d%% of the cycle", math.floor(R.dayFrac * 100)))
    end },
  { "Cave frequency: sparse/normal/dense (cycles, new terrain only)", function()
      local presets = { 0.5, 1.0, 1.8 }; local cur = R.caveFreqMul or 1.0; local idx = 1
      for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
      R.caveFreqMul = presets[(idx % #presets) + 1]
      say(string.format("Cave frequency: %.1fx (affects newly generated terrain only)", R.caveFreqMul))
    end },
  { "Ore rarity: common/normal/rare (cycles, new terrain only)", function()
      local presets = { 0.7, 1.0, 1.4 }; local cur = R.oreRarityMul or 1.0; local idx = 1
      for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
      R.oreRarityMul = presets[(idx % #presets) + 1]
      say(string.format("Ore rarity: %.1fx (affects newly generated terrain only)", R.oreRarityMul))
    end },
  { "Gravity: light/normal/heavy (cycles, takes effect immediately)", function()
      local presets = { 0.7, 1.0, 1.4 }; local cur = R.gravMul or 1.0; local idx = 1
      for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
      R.gravMul = presets[(idx % #presets) + 1]
      say(string.format("Gravity: %.1fx", R.gravMul))
    end },
  { "Jump height: low/normal/high (cycles, takes effect immediately)", function()
      local presets = { 0.75, 1.0, 1.3 }; local cur = R.jumpMul or 1.0; local idx = 1
      for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
      R.jumpMul = presets[(idx % #presets) + 1]
      say(string.format("Jump height: %.1fx", R.jumpMul))
    end },
  { "Move speed: slow/normal/fast (cycles, takes effect immediately)", function()
      local presets = { 0.75, 1.0, 1.3 }; local cur = R.runMul or 1.0; local idx = 1
      for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
      R.runMul = presets[(idx % #presets) + 1]
      say(string.format("Move speed: %.1fx", R.runMul))
    end },
  { "Tree spacing: dense/normal/sparse (cycles, new terrain only)", function()
      local presets = { 0.7, 1.0, 1.4 }; local cur = R.treeSpacingMul or 1.0; local idx = 1
      for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
      R.treeSpacingMul = presets[(idx % #presets) + 1]
      say(string.format("Tree spacing: %.1fx (affects newly generated terrain only)", R.treeSpacingMul))
    end },
  { "Enemy difficulty: easy/normal/hard (cycles, applies to newly spawned enemies)", function()
      local presets = { 0.7, 1.0, 1.4 }; local cur = R.difficultyMul or 1.0; local idx = 1
      for i, v in ipairs(presets) do if math.abs(v - cur) < 0.01 then idx = i end end
      R.difficultyMul = presets[(idx % #presets) + 1]
      say(string.format("Enemy difficulty: %.1fx (applies to newly spawned enemies)", R.difficultyMul))
    end },
  { "Sandbox mode on/off", function() R.sandbox = not R.sandbox; if R.sandbox then R.sandboxFill(); say("SANDBOX: everything unlocked, no damage, infinite materials") else say("Sandbox off") end end },
  { "Report bug / suggestion (F8)", function() R.setMenuOpen(false); R.feedbackOpen = true; R.feedbackText = ""; grabText() end },
  { "Check for update now", function() R.setMenuOpen(false); if R.updateInfo then R.startUpdate() else R.checkForUpdate(); say("Checking for an update...") end end },
  { "View full changelog", function() R.setMenuOpen(false); R.openFullChangelog() end },
}
local HELP = {
  "MOVE     A / D run      W jump (hold = higher)      S fast-fall / sink      Space pauses",
  "TOOLS    slots 1-5 = pick, axe, sword, torch, bucket -> hold LEFT mouse. Picks: wood (hand) > stone (bench) > iron/steel/diamond (anvil)",
  "BLOCKS   slots 6-0 = materials you carry -> hold LEFT mouse to place   [ ] or wheel = brush size (same as TPT menu)   Tab/V = shape (circle/square/triangle)   B snap grid",
  "SELECT   number keys 1-0 or mouse wheel      E = bag + crafting (click items / recipes)",
  "VIEW     Z = zoom: move, click to lock, Z closes. Inside the zoom box: dig/place 1px precisely, wheel = brush, palette below",
  "WORLD    walk or dig anywhere - it scrolls. Stone pick digs granite/coal/iron. Gold: iron pick. Deep titanium: steel pick",
  "CRAFT    hand -> Workbench -> Furnace (light its coal with the torch; smelts ore to bars) -> Anvil (tools)",
  "ITEMS    chests hold accessories: grapple = MIDDLE CLICK (or G, or double-tap jump in the air), X mirror home, double jump, rocket boots",
  "OTHER    K save   R respawn   N enemies   F8 report bug/suggestion   U install update (when one's available)   Esc = this menu",
}
local MX, MY, MW, MH = 8, 18, 596, 340          -- inside R.SAFE
local BTN_W, BTN_H, BTN_COLS = 178, 19, 2
local BTN_X, BTN_Y = MX + 10, MY + 150
-- Drew: "all options all the way down to the bottom" -- confirmed with real math
-- before fixing, not just eyeballed: BTN_COLS=2, row height 22, BTN_Y=168, panel
-- bottom MY+MH=358 -> only 8 rows (16 of 26 entries) actually fit on screen; the
-- rest silently ran off both the drawn panel box and the visible screen. Added
-- wheel-scroll, same shape as every other scrollable list this session.
local MENU_VISIBLE_ROWS = floor((MY + MH - BTN_Y) / (BTN_H + 3))
R.settingsScroll = R.settingsScroll or 0
local function btnRect(i) local idx = i - 1 - R.settingsScroll * BTN_COLS
  local c, r = idx % BTN_COLS, floor(idx / BTN_COLS)
  if idx < 0 or r >= MENU_VISIBLE_ROWS then return nil end
  return BTN_X + c * (BTN_W + 8), BTN_Y + r * (BTN_H + 3), BTN_W, BTN_H end
local function wrap(text, width)                -- 6px per character
  local maxc = floor(width / 6); local out, line = {}, ""
  for word in text:gmatch("%S+") do
    if #line + #word + 1 > maxc then out[#out + 1] = line; line = word else line = (line == "") and word or (line .. " " .. word) end end
  if line ~= "" then out[#out + 1] = line end
  return out
end
function R.menuClick(x, y)
  for i, m in ipairs(R.MENU) do local bx, by, bw, bh = btnRect(i)
    if bx and x >= bx and x <= bx + bw and y >= by and y < by + bh then m[2](); return end end
end
local function drawMenu()
  graphics.fillRect(0, 0, W, H, 0, 0, 0, 130)
  graphics.fillRect(MX, MY, MW, MH, 12, 14, 30, 246); graphics.drawRect(MX, MY, MW, MH, 255, 220, 80, 255)
  graphics.fillRect(MX, MY, MW, 16, 40, 44, 80, 255)
  graphics.drawText(MX + 8, MY + 4, "POWDER RPG - MENU & CONTROLS", 255, 220, 80, 255)
  graphics.drawText(MX + MW - 96, MY + 4, "Esc closes", 190, 190, 200, 255)
  -- controls: two columns of wrapped lines so nothing runs off the edge
  local colW = floor((MW - 30) / 2)
  local lx, rx, ty = MX + 10, MX + 20 + colW, MY + 22
  local left = { {"MOVE", "A / D run,  W jump,  S fast-fall or drop through a wood platform.  Space pauses"},
                 {"TOOLS", "slots 1-5: pick, axe, sword, torch, bucket - hold RIGHT mouse"},
                 {"BLOCKS", "Q picks the material under the cursor into your hotbar.  LEFT mouse places.  SHIFT+wheel = block size.  CTRL = snap + straight line, CTRL+wheel = cell size.  B locks the grid on"},
                 {"SELECT", "number keys 1-0 or the mouse wheel"} }
  local right = { {"TALK", "ENTER opens chat with your colonists (Esc cancels)"},
                  {"BAG", "E - items, crafting, equipment.  L or the GUIDE button - database"},
                  {"VIEW", "Z zoom (click to lock; inside it you build 1px precise),  M map"},
                  {"ITEMS", "grapple: MIDDLE CLICK,  X mirror home,  double-tap jump in air"},
                  {"WORLD", "dig anywhere - it scrolls.  Chop half a trunk to fell a tree"} }
  local function block(entries, x)
    local y = ty
    for _, e in ipairs(entries) do
      graphics.drawText(x, y, e[1], 255, 220, 80, 255)
      for _, ln in ipairs(wrap(e[2], colW - 54)) do graphics.drawText(x + 54, y, ln, 215, 215, 225, 255); y = y + 11 end
      y = y + 4
    end
  end
  block(left, lx); block(right, rx)
  local maxSettingsScroll = math.max(0, math.ceil(#R.MENU / BTN_COLS) - MENU_VISIBLE_ROWS)
  R.settingsScroll = math.max(0, math.min(maxSettingsScroll, R.settingsScroll))
  graphics.drawText(MX + 10, MY + 138, "SETTINGS" .. (maxSettingsScroll > 0 and ("   wheel to scroll (" .. R.settingsScroll .. "/" .. maxSettingsScroll .. ")") or ""), 255, 220, 80, 255)
  for i, m in ipairs(R.MENU) do local bx, by, bw, bh = btnRect(i)
    if bx then
      local hov = R.mouse.x >= bx and R.mouse.x <= bx + bw and R.mouse.y >= by and R.mouse.y < by + bh
      graphics.fillRect(bx, by, bw, bh, hov and 80 or 38, hov and 84 or 42, hov and 130 or 78, 255)
      graphics.drawRect(bx, by, bw, bh, hov and 255 or 120, hov and 220 or 124, hov and 80 or 170, 255)
      graphics.drawText(bx + 7, by + 5, string.sub(m[1], 1, floor((bw - 12) / 6)), 255, 255, 255, 255)
    end end
  -- status column on the right of the buttons
  local sx = BTN_X + BTN_COLS * (BTN_W + 8) + 8
  local na = 0; for _ in pairs(R.acc) do na = na + 1 end
  graphics.drawText(sx, MY + 138, "STATUS", 255, 220, 80, 255)
  local st = { string.format("World %d   Day %d", R.seed or 0, R.day or 1),
               string.format("Deaths %d%s", R.deaths or 0, R.sandbox and "   SANDBOX" or ""),
               "Pick: " .. R.TOOLS.pick.name, "Sword: " .. R.TOOLS.sword.name,
               string.format("Accessories %d   Enemies %s", na, R.enemies and "ON" or "off"),
               string.format("Effects %s   Grid %s", R.fxOn and "on" or "off", R.grid and "on" or "off") }
  for i, line in ipairs(st) do graphics.drawText(sx, MY + 152 + (i - 1) * 12, line, 205, 205, 215, 255) end
  local q = R.QUESTS[R.quest]
  if q then graphics.drawText(sx, MY + 232, "GOAL " .. R.quest .. "/" .. #R.QUESTS, 255, 220, 80, 255)
    local yy = MY + 246
    for _, ln in ipairs(wrap(q.txt, MW - (sx - MX) - 12)) do graphics.drawText(sx, yy, ln, 200, 230, 200, 255); yy = yy + 11 end end
end
local function onDraw()
  if R.titleScreen then drawTitleScreen(); return end
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
  local ok, err = pcall(drawPlayer); if not ok then R.lastErr = tostring(err) end
  if not R.hud then return end
  runHooks(R.hooks.drawHUD)
  local s = selected(); local reach = 30; if s and s:find("^tool:") and R.TOOLS[s:sub(6)] then reach = R.TOOLS[s:sub(6)].reach or 30 end
  local px, py = pcanvas()
  local mx, my = R.mouse.x, R.mouse.y; local okr = dist2(mx, my, px, py) <= reach*reach
  -- F15b: when Drew uses TPT's native element menu (R.tptMenus), the RPG's brush preview
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
      if R.ctrlHeld and R.placeAnchor then local ax, ay = R.placeAnchor[1], R.placeAnchor[2]
        if math.abs(mx - ax) >= math.abs(my - ay) then my = ay else mx = ax end
        graphics.drawLine(ax, ay, mx, my, 255, 220, 90, 90) end
      local x1, y1, x2, y2 = mx - rx, my - ry, mx + rx, my + ry
      if R.grid or R.ctrlHeld then local gx = floor((mx + R.cam.x) / g) * g - R.cam.x; local gy = floor((my + R.cam.y) / g) * g - R.cam.y
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
      local lbl = (R.grid or R.ctrlHeld) and ((rx + 1) .. "x" .. (ry + 1) .. " cells @" .. g .. "px") or (ww .. "px")
      graphics.drawText(x1, y2 + 4, lbl, 235, 235, 245, 190)
      end
    elseif s and R.ITEMS[s] then graphics.drawRect(mx - 7, my - 12, 15, 13, 255, 220, 120, okr and 160 or 70) end end
  graphics.fillRect(4, 4, 250, 30, 0, 0, 0, 170)
  local n = math.max(0, math.min(10, floor((R.hp or 0) / 10 + 0.5)))
  for i = 1, 10 do local x = 8 + (i-1)*12; if i <= n then graphics.fillRect(x, 8, 9, 8, 230, 50, 60, 255); graphics.fillRect(x+1, 7, 3, 2, 230, 50, 60, 255); graphics.fillRect(x+5, 7, 3, 2, 230, 50, 60, 255) else graphics.drawRect(x, 8, 9, 8, 120, 60, 60, 255) end end
  graphics.drawText(130, 8, tostring(floor(R.hp or 0)), 255, 120, 120, 255)
  do local o2 = R.o2 or 100
    if o2 < 100 or (R.o2conc or 0) > 25 then
      local w = floor(o2 / 100 * 116); local r, g, b = 90, 170, 255
      if o2 < 35 then r, g, b = 255, 160, 60 end; if o2 < 15 then r, g, b = 255, 70, 70 end
      graphics.fillRect(8, 18, 116, 3, 40, 40, 60, 255); graphics.fillRect(8, 18, w, 3, r, g, b, 255)
      graphics.drawText(128, 15, "AIR " .. floor(o2) .. "%", r, g, b, 255)
      if (R.o2 or 100) < 70 and (R.o2conc or 0) <= 25 then graphics.drawText(178, 15, ((R.P.y - surfaceAt(floor(R.P.x))) > 140) and "thin air" or "stale air", 160, 170, 190, 255) end
      if (R.o2conc or 0) > 25 then graphics.drawText(178, 15, "O2 " .. floor(R.o2conc) .. "%", 140, 220, 255, 255) end
      if (R.inventory.FLASK or 0) > 0 then local cap = 100 * math.min(3, R.inventory.FLASK)
        graphics.fillRect(8, 22, 60, 3, 40, 40, 60, 255); graphics.fillRect(8, 22, floor((R.flask or 0) / cap * 60), 3, 150, 220, 235, 255)
        graphics.drawText(72, 20, "flask", 150, 220, 235, 200) end
      local G = R.gas or {}
      if (G.co or 0) > 20 then graphics.drawText(240, 15, string.format("CO %d%%%s", floor(G.co), G.co > 35 and " - POISONING" or ""), 255, 120, 60, 255)
      elseif (G.ch4 or 0) > 25 then graphics.drawText(240, 15, string.format("EXPLOSIVE GAS %d%%", floor(G.ch4)), 255, 200, 60, 255)
      elseif (G.rad or 0) > 25 then graphics.drawText(240, 15, string.format("RADIATION %d%%", floor(G.rad)), 140, 255, 120, 255)
      elseif (G.heat or 0) > 35 then graphics.drawText(240, 15, string.format("HEAT %d%%", floor(G.heat)), 255, 150, 90, 255)
      elseif (R.o2conc or 0) > 60 and (R.frame % 26) < 13 then graphics.drawText(240, 15, "OXYGEN RICH - FIRE HAZARD", 255, 140, 60, 255)
      elseif o2 < 35 and (R.frame % 30) < 15 then graphics.drawText(240, 15, o2 < 15 and "SUFFOCATING" or "AIR RUNNING OUT", 255, 90, 90, 255) end
      -- Accumulated dose shown on its own, persistent line -- unlike the
      -- live hazard line above (only one at a time, only while it's bad
      -- right now), this is a lasting condition and stays visible as long
      -- as it's non-trivial, in or out of a hot zone.
      if (R.radAccum or 0) > 10 then
        local rc = (R.radAccum > 40) and { 255, 120, 90 } or { 200, 230, 140 }
        graphics.drawText(240, 27, string.format("Radiation dose: %d%%", floor(R.radAccum)), rc[1], rc[2], rc[3], 255)
      end
      if (R.uvAccum or 0) > 20 then
        local uc = (R.uvAccum > 70) and { 255, 150, 90 } or { 255, 220, 140 }
        graphics.drawText(240, 39, string.format("UV exposure: %d%%", floor(R.uvAccum)), uc[1], uc[2], uc[3], 255)
      end
    end end
  local where = depth > 20 and string.format("%dm underground", floor(depth / 4)) or (depth < -20 and string.format("%dm up", floor(-depth / 4)) or "surface")
  do local N = R.need
    if (N.food or 100) < 100 or (N.water or 100) < 100 then
      graphics.fillRect(8, 26, 56, 3, 40, 40, 60, 255); graphics.fillRect(8, 26, floor(N.food / 100 * 56), 3, 210, 160, 70, 255)
      if N.food < 25 or N.water < 25 then graphics.drawText(128, 24, N.water < N.food and "THIRSTY" or "HUNGRY", 255, 150, 80, 255) end
    end end
  -- R.VERSION in the always-on in-game HUD -- was only visible on the title
  -- screen and during the What's-New popup, even though the section comment
  -- above (line ~171) explicitly says "shown on screen always (bottom-left
  -- corner) so anyone watching knows exactly what build is running." Sits
  -- top-right, just above the Deaths counter, dim grey so it doesn't compete
  -- with the brighter HUD readouts.
  graphics.drawText(W - 80, 8, "v" .. R.VERSION, 160, 160, 170, 255)
  -- Round-25 fix: format was "Day %d %s" where %s was always "day" or "night",
  -- so during daytime the HUD read "Day 2 day" -- a clear copy-paste-style
  -- duplication. Drop the redundant day/night word entirely (the day number
  -- is enough info; the sun/moon in the sky already shows night visually).
  graphics.drawText(8, 22, string.format("Day %d%s   x %d   %s   %s%s", R.day or 1, night > 0.2 and " (night)" or "", floor(R.P.x / 4), where, biomeAt(floor(R.P.x)), R.enemies and "   enemies ON" or ""), 220, 220, 220, 255)
  -- Death counter: only renders when >0 so a fresh run is uncluttered, and only after a real
  -- respawn so the inventory-loss "you died" moment is reflected back at the player. Bright
  -- orange makes it pop against the grey status line above; lives just below the always-on
  -- felt-temperature readout so it sits inside the existing HUD band (lines 22-34).
  if (R.deaths or 0) > 0 then
    graphics.drawText(W - 80, 22, string.format("Deaths: %d", R.deaths), 255, 150, 80, 255)
  end
  -- Visual gauges for felt-temp and ambient pressure, top-left HUD band.
  -- Replaces the prior "Feels like X F" text-only line: same numeric info is still
  -- shown, but a colored horizontal bar fills proportionally to the value, so a
  -- glance at the colors answers "am I hot/cold / in pressure danger?" without
  -- having to read and compare a number. Bar at x=24..124 (100px wide), label at
  -- x=128. y=34 = temperature, y=46 = pressure; log tail nudged to y=58 below.
  do local GAUGE_X, GAUGE_W = 24, 100
    -- Temperature gauge: 0..1000 F mapped to a cold->warm->hot color gradient.
    do local tF = ((R.feltTempK or 295) - 273.15) * 9 / 5 + 32
      local frac = math.max(0, math.min(1, tF / 1000))
      local r, g, b
      if tF < 70 then        -- freezing -> neutral white, blue dominant
        local k = math.max(0, math.min(1, (tF + 20) / 90))
        r, g, b = math.floor(80 + 175 * k), math.floor(150 + 105 * k), 255
      elseif tF < 200 then   -- neutral -> warm orange
        local k = (tF - 70) / 130
        r, g, b = 255, math.floor(255 - 75 * k), math.floor(255 - 195 * k)
      else                   -- warm -> hot red
        local k = math.max(0, math.min(1, (tF - 200) / 300))
        r, g, b = 255, math.floor(180 - 130 * k), math.floor(60 - 40 * k)
      end
      -- background track + colored fill
      graphics.fillRect(GAUGE_X, 34, GAUGE_W, 4, 40, 40, 60, 200)
      graphics.fillRect(GAUGE_X, 34, floor(frac * GAUGE_W), 4, r, g, b, 255)
      graphics.drawRect(GAUGE_X, 34, GAUGE_W, 4, 180, 180, 200, 200)
      graphics.drawText(8, 33, "T", 200, 200, 220, 255)
      graphics.drawText(GAUGE_X + GAUGE_W + 6, 33, string.format("%.0fF", tF), r, g, b, 255)
    end
    -- Pressure gauge: sim.pressure returns a cell value (4px cells; pcall because
    -- coordinates can be out of grid range near edges). 0 is the neutral baseline;
    -- negative = vacuum (deep caves, sealed rooms dug open), positive = overpressure
    -- (sealed rooms with fire/lots-of-O2). Color-coded: green safe, yellow caution, red danger.
    do local cx, cy = floor(R.P.x / 4), floor(R.P.y / 4)
      local ok, p = pcall(sim.pressure, cx, cy)
      p = (ok and type(p) == "number") and p or 0
      -- Map -8..+8 to 0..1 fraction; extreme dig creates -8 vacuum, sealed+fire can hit +5..+6.
      local frac = math.max(0, math.min(1, (p + 8) / 16))
      local r, g, b
      local ap = math.abs(p)
      if ap <= 1.5 then       r, g, b = 90, 200, 110       -- green safe
      elseif ap <= 3.5 then   r, g, b = 230, 200, 90       -- yellow caution
      else                    r, g, b = 230, 90, 90        -- red danger
      end
      graphics.fillRect(GAUGE_X, 46, GAUGE_W, 4, 40, 40, 60, 200)
      graphics.fillRect(GAUGE_X, 46, floor(frac * GAUGE_W), 4, r, g, b, 255)
      graphics.drawRect(GAUGE_X, 46, GAUGE_W, 4, 180, 180, 200, 200)
      -- center marker at frac=0.5 (baseline pressure 0) so the player sees deviation
      graphics.fillRect(GAUGE_X + floor(GAUGE_W / 2) - 1, 45, 1, 6, 220, 220, 230, 180)
      graphics.drawText(8, 45, "P", 200, 200, 220, 255)
      graphics.drawText(GAUGE_X + GAUGE_W + 6, 45, string.format("%+d", p), r, g, b, 255)
    end
  end
  for k, m in ipairs(R.log or {}) do local age = (R.frame or 0) - m[2]; local a = math.max(0, math.min(255, 255 - floor(age / 2))); if a > 0 then graphics.drawText(8, 58 + 12*(k-1), m[1], 255, 230, 140, a) end end
  if R.hint then graphics.drawText(260, 8, R.hint, 200, 230, 255, 255) end
  if R.sandbox then graphics.drawText(W - 200, 40, "SANDBOX MODE (Esc menu to turn off)", 255, 200, 80, 255) end
  do local q = R.QUESTS[R.quest]; if q then graphics.fillRect(258, 20, 240, 12, 0, 0, 0, 150); graphics.drawText(262, 22, "GOAL " .. R.quest .. "/" .. #R.QUESTS .. ": " .. q.txt, 255, 220, 120, 255) end end
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
  if R.changesPromptOpen and R.localChanges then
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
  drawHotbar(); if R.minimap then drawMinimap() end; if R.invOpen then drawPanel() end
  graphics.drawText(W - 110, 68, "Esc = menu / controls", 160, 160, 170, 255)
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
  if R.menuOpen then drawMenu() end
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
local SLOW_BURN = 20   -- coal inside a furnace chamber burns this many times slower than in the open
local function updateFurnaces()
  if sim.paused() then return end
  if R.frame % SLOW_BURN == 0 then return end   -- on 1 frame in SLOW_BURN we let the countdown proceed
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
      if y > 4 and y < H - 4 and not sim.partID(x, y) then local p = sim.partCreate(-1, x, y, wt); if p and p >= 0 then sim.partProperty(p, "vy", 2) end end end
  else Wt.next = Wt.next - 1; if Wt.next <= 0 then Wt.rain = true; Wt.left = 900 + floor(math.random() * 900); say("Rain clouds roll in") end end
end
-- Nothing in this game ever removes standing water, so rain just piles up forever --
-- on the ground, and just as visibly on top of any tree canopy it lands on, since
-- WOOD/GRSS block it like solid ground would. Real soil/wood don't hold a puddle
-- indefinitely either, so soak resting water into whatever it's sitting on, at a rate
-- that comfortably loses to a real rainstorm but wins once the rain stops.
local ABSORBENT = { GOO=1, GRSS=1, WOOD=1, SAND=1, CLST=1, ICE=1, SNOW=1 }
local function absorbStandingWater()
  if sim.paused() or R.frame % 6 ~= 0 then return end
  local wt = eid("WATR"); if not wt then return end
  for i = 1, 14 do
    local sx, sy = math.random(2, W - 3), math.random(2, H - 3)
    local p = sim.partID(sx, sy)
    if p and sim.partProperty(p, "type") == wt then
      local vx, vy = sim.partProperty(p, "vx") or 0, sim.partProperty(p, "vy") or 0
      if math.abs(vx) < 0.5 and math.abs(vy) < 0.5 then
        local below = sim.partID(sx, sy + 1)
        local nm = below and nameOf(sim.partProperty(below, "type"))
        if nm and ABSORBENT[nm] and math.random() < 0.2 then sim.partKill(p) end
      end
    end
  end
end
R.absorbStandingWater = absorbStandingWater
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
  R.frame = (R.frame or 0) + 1
  if R.lastHitAt and R.frame - R.lastHitAt > 90 then R.blockHits = {}; R.lastHitAt = nil end
  local ok, err = pcall(flushFill); if not ok then R.lastErr = tostring(err) end
  if R.menuOpen then R.keys = {} end
  ok, err = pcall(movePlayer); if not ok then R.lastErr = tostring(err) end
  -- Bleed on damage: every real damage source sets R.hurt = R.frame already
  -- (fall damage, burns, radiation, hunger/thirst, suffocation) -- one check
  -- here catches all of them instead of hand-editing each call site.
  if R.hurt == R.frame and R.bloodLast ~= R.frame then
    R.bloodLast = R.frame
    local bld = eid("BLD")
    if bld then local px, py = R.P.x - R.cam.x, R.P.y - 6 - R.cam.y
      for i = 1, 4 do local ox, oy = math.random(-2, 2), math.random(-3, 1)
        local p = sim.partID(px + ox, py + oy)
        if not p then local q = sim.partCreate(-1, px + ox, py + oy, bld); if q and q >= 0 then sim.partProperty(q, "vy", -0.5 - math.random()) end end
      end
    end
  end
  if R.wouldPlace() then
    if inZoom(R.mouse.x, R.mouse.y) then local cx, cy = zoomToCanvas(R.mouse.x, R.mouse.y)
      -- One button (LEFT) does whatever the selected slot does -- a tool
      -- uses itself, a block places itself -- instead of a fixed
      -- LMB=use/RMB=place split. Matches native TPT's own single-button
      -- tool convention, per the explicit ask: "I just want to hit left
      -- click and use all my normal build controls."
      local s = selected(); if s and s:find("^tool:") then useTool(cx, cy, true) else placeAt(cx, cy, true) end
    else
      local s = selected(); if s and s:find("^tool:") then useTool(R.mouse.x, R.mouse.y) else placeAt(R.mouse.x, R.mouse.y) end
    end
  end
  local t0 = os.clock(); ok, err = pcall(updateCamera); if not ok then R.lastErr = tostring(err) end; R.shiftMs = (os.clock() - t0) * 1000
  ok, err = pcall(adjustCamOffsets); if not ok then R.lastErr = tostring(err) end
  if not R.zoomLensCleared then pcall(ren.zoomEnabled, false); R.zoomLensCleared = true end   -- one-time: force off any lens left stuck on from the removed Ctrl+zoom feature
  pcall(R.pumpFeedbackHttp)
  pcall(R.pumpUpdateCheck)
  pcall(R.pumpUpdateDownload)
  local okw, errw = pcall(updateWeather); if not okw then R.lastErr = tostring(errw) end
  okw, errw = pcall(absorbStandingWater); if not okw then R.lastErr = tostring(errw) end
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
  if R.sandbox then if R.frame % 30 == 0 then for k, v in pairs(R.inventory) do if v < 500 then R.inventory[k] = 999 end end end; R.hp = 100; R.o2 = 100 end
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
local TITLE_BTN = {
  play = { x = 0, y = 0, w = 150, h = 26 },
  newworld = { x = 0, y = 0, w = 150, h = 26 },
  settings = { x = 0, y = 0, w = 150, h = 26 },
  quit = { x = 0, y = 0, w = 150, h = 26 },
}
local function layoutTitleButtons()
  local cx = floor(W / 2 - 75)
  TITLE_BTN.play.x = cx; TITLE_BTN.play.y = floor(H / 2) - 38
  TITLE_BTN.newworld.x = cx; TITLE_BTN.newworld.y = floor(H / 2) - 6
  TITLE_BTN.settings.x = cx; TITLE_BTN.settings.y = floor(H / 2) + 26
  TITLE_BTN.quit.x = cx; TITLE_BTN.quit.y = floor(H / 2) + 58
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
-- Round 8 visual pass, per Drew's direct feedback that the functional-but-bare V1
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
-- Round 9: Drew wants Settings reachable straight from the title screen with real
-- presentation, not a jump out to the plain Esc/Options list ("we have our settings
-- here too but it's got to be nice nice shit"). Reuses the exact same R.MENU entries
-- (label substring match) instead of a second parallel slider list -- one source of
-- truth, the Esc menu keeps working exactly as before for mid-game use.
R.titleSettingsOpen = R.titleSettingsOpen or false
R.titleCreateOpen = R.titleCreateOpen or false
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
    { TITLE_BTN.settings, "Settings" },
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
  if hitRect(x, y, TITLE_BTN.settings) then R.titleSettingsOpen = true; return true end
  -- No real scriptable full-process-quit exists in TPT Lua -- rather than fake a
  -- broken quit button, this tells the player the real way to close the game.
  if hitRect(x, y, TITLE_BTN.quit) then say("Close the window or Alt+F4 to quit"); return true end
  return true   -- swallow clicks anywhere else on the title screen
end
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
  pcall(R.crumble, x, y, 5)
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
      if wy < -400 or wy > DEPTH then goto skip end
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
R.PLUGINS = { "world", "enemies", "machines", "machines2", "items", "vehicles", "survival", "companion", "save", "ui", "guide" }
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
