-- RPG plugin: guide.lua - the in-game GUIDE / DATABASE. Key L opens/closes it.
-- Three columns: categories (left) -> searchable entry list (middle) -> generated entry page (right).
-- Pages are built live from R's real data (R.RECIPES/R.PICKS/R.SWORDS/R.ITEMS/R.ACCS/R.MINEABLE/R.HARD)
-- plus real TPT element facts via elem.property(). Clicking a highlighted word jumps to that entry
-- (back stack lets you return). Where another plugin doesn't expose a table (creature stats, weapon
-- cooldowns, biome soil types), this file keeps its own small static mirror instead - see the comments
-- next to each one. Owns exactly this file; never touches rpg.lua or another plugin.
local R = PBX.state.rpg
local TAG = "guide"
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

-- ================================================================ icon draw (defensive against @icons_engine,
-- same contract/fallback as ui.lua's own drawMatIcon -- duplicated rather than shared across plugin files
-- since there is no cross-plugin require() in this loader, only the shared R table).
local function drawMatIcon(code, x, y, size, alpha)
  alpha = alpha or 255
  if R.icon and R.icon.draw then
    local ok = pcall(R.icon.draw, code, x, y, size, alpha)
    if ok then return end
  end
  local r, g, b = R.colourOf(code)
  graphics.fillRect(x, y, size, size, r, g, b, alpha)
  graphics.drawRect(x, y, size, size, 0, 0, 0, math.min(alpha, 150))
end

-- ================================================================ persistent state (survives reloadPlugin)
local G = R.guide or {}
R.guide = G
G.search = G.search or ""
G.searchFocused = G.searchFocused or false
G.catScroll = G.catScroll or 0
G.listScroll = G.listScroll or 0
G.pageScroll = G.pageScroll or 0
G.back = G.back or {}
G.help = G.help or false
G.cat = G.cat or nil
G.id = G.id or nil
G.locCache = G.locCache or {}
G.biomeCache = G.biomeCache or nil
G.drag = nil       -- "list" or "page" while dragging that column's scrollbar thumb (not persisted across reload)
G.dragMeta = nil
G.lastClickCat, G.lastClickId, G.lastClickT = nil, nil, nil   -- double-click detection on list rows (TAKE shortcut)

-- ================================================================ geometry (canvas 612x384)
-- core publishes R.SAFE = the rectangle every plugin panel must stay inside (it excludes the top HP/hint/
-- goal strip and the bottom hotbar, which both draw AFTER plugin drawHUD hooks and would paint over us).
-- R.SAFE's declared top (y=16) is still crossed by the fixed GOAL banner core draws at y 20-32 regardless
-- of R.SAFE (it's positioned independently, after plugin hooks run), so start further down than SAFE.y alone
-- would suggest, and stop short of the hotbar (H-28=356) rather than trusting SAFE.h's full extent to y=360.
local SAFE = R.SAFE or { x = 4, y = 16, w = 604, h = 344 }
local GX, GY, GW, GH = SAFE.x + 2, math.max(SAFE.y + 2, 34), SAFE.w - 4, 320
local BY = GY + 16
local BOT = GY + GH - 4
local COL1X, COL1W = GX + 4, 134
local COL2X, COL2W = COL1X + COL1W + 4, 140
local COL3X = COL2X + COL2W + 4
local COL3W = GX + GW - 4 - COL3X
local SBW = 5 -- scrollbar track width

-- ================================================================ live classification of every craftable code
-- REPLACES the old hand-copied WEAPON_CODES / MACHINE_CODES / STATION_CODES lists (2026-08-31). Those had gone
-- badly stale: they named 12 weapons and 8 machines while R.ITEMS now holds 121 entries and R.RECIPES 174, so
-- roughly a hundred craftables all fell through into "Machines" as one flat undifferentiated dump. That is
-- exactly the reported complaint ("machines and everything needs to get broken down significantly further").
--
-- Everything below is DERIVED from live tables and rebuilt whenever the recipe count changes, so kits added by
-- any plugin - present or future - appear in the right place with no list to maintain here. Signals, strongest
-- first, all exact except where noted:
--   R.STATIONS[code:lower()]       -> crafting station                  (exact: core's own station table)
--   recipe._tag == "terraweapons"  -> terrain-altering weapon           (exact: published by terraweapons.lua)
--   desc "worn passively"          -> wearable / armor                  (exact: the phrase every passive-gear
--                                                                        item's own description opens with)
--   recipe._tag == "items"         -> weapon / gadget                   (exact: published by items.lua)
--   VEHICLE_SET                    -> vehicle                           (the ONE hand-listed set left: vehicles.lua
--                                                                        publishes no _tag yet. Hub request posted;
--                                                                        delete this table once it tags its recipes.)
--   otherwise, has a recipe        -> placeable machine, bucketed by the station that builds it (exact: rc.st)
--
-- Machines are split by build station rather than by guessed function on purpose: rc.st is present on 174/174
-- recipes and is never inferred, and "what can I build at the bench I have now" is the question a player is
-- actually asking. A keyword classifier over descriptions was tried first and rejected - nearly every machine's
-- description contains the word "powered", which collapsed 34 unrelated kits into one bogus "power" bucket.
local VEHICLE_SET = { BIKEKIT = 1, DOZERKIT = 1, HAULERKIT = 1, MINECARTKIT = 1, HANDCARKIT = 1, LOCOKIT = 1,
                      WAGONKIT = 1, LIFTKIT = 1, DRILLTRAINKIT = 1, RAILKIT = 1, TRAINSTOPKIT = 1, ELEVATORKIT = 1 }
local ORE_CODES = { "COAL", "BCOL", "IRON", "CU", "GOLD", "DU", "URAN", "QRTZ", "DMND", "TTAN", "ZIRC", "LEAD" }
local ORE_SET = {}; for _, k in ipairs(ORE_CODES) do ORE_SET[k] = true end
local MACH_CAT = { workbench = "m_workbench", furnace = "m_furnace", anvil = "m_anvil",
                   research = "m_research", advlab = "m_advlab" }
local function isMachineCat(c)
  return c == "m_workbench" or c == "m_furnace" or c == "m_anvil"
      or c == "m_research" or c == "m_advlab" or c == "m_other"
end

-- ================================================================ live material-section grouping (material browser)
-- The design contract (knowledge/design-material-progression.md) groups all 195 stock elements by their
-- real engine menu_section (SC_ELEC, SC_EXPLOSIVE, ...). That field is read live here through
-- elem.property(id, "MenuSection") -- exactly the same call elemFactsLines() below already makes for
-- Temperature/Hardness/etc, and the same field demo_create_element.lua itself stamps onto every custom
-- RPG element (CU/STEL/BSLT/ZIRC/...) via applyBand(), so nothing in this game's material set is missing
-- one. The numeric ids are the engine's own enum (src/simulation/MenuSection.h, not exposed to Lua by
-- name) -- a stable 12-row ENUM MAPPING, not a per-material list, so it can never go stale as new
-- materials land: a material sorts itself into the right bucket the moment its element exists, with
-- nothing to maintain here.
local SC_SECTION = {
  [1]  = { id = "mat_elec",      label = "Mat: Electronics" },
  [2]  = { id = "mat_powered",   label = "Mat: Powered" },
  [3]  = { id = "mat_sensor",    label = "Mat: Sensors" },
  [4]  = { id = "mat_force",     label = "Mat: Force & Motion" },
  [5]  = { id = "mat_explosive", label = "Mat: Explosives" },
  [6]  = { id = "mat_gas",       label = "Mat: Gases" },
  [7]  = { id = "mat_liquid",    label = "Mat: Liquids" },
  [8]  = { id = "mat_powders",   label = "Mat: Powders" },
  [9]  = { id = "mat_solids",    label = "Mat: Solids/Metals" },
  [10] = { id = "mat_nuclear",   label = "Mat: Nuclear/Exotic" },
  [11] = { id = "mat_special",   label = "Mat: Special" },
  [12] = { id = "mat_life",      label = "Mat: Life" },
}
local MAT_SECTION_CATS = {}
for _, v in pairs(SC_SECTION) do MAT_SECTION_CATS[v.id] = true end
local collectMatCodes   -- forward-declared; assigned below in "entry lists per category" - classMap() needs it
local SECTION_ID_CACHE = {}
-- One native elem.property call per code, ever (memoised) - a live element's MenuSection never changes
-- mid-session, so there is no per-frame cost here after the first lookup of each code.
local function sectionOf(code)
  local v = SECTION_ID_CACHE[code]
  if v ~= nil then return v or nil end
  local tid = R.eid and R.eid(code)
  local result
  if tid then
    local ok, sec = pcall(elem.property, tid, "MenuSection")
    if ok and sec and SC_SECTION[sec] then result = SC_SECTION[sec].id end
  end
  SECTION_ID_CACHE[code] = result or false
  return result
end
local function isHideableCat(c) return isMachineCat(c) or MAT_SECTION_CATS[c] end

-- cached because getEntries() runs from the draw hook every frame; rebuilding it per frame would be a
-- 121 x 174 scan. Keyed on the recipe count so a plugin registering new recipes invalidates it by itself.
local CC = nil
local function classMap()
  local n = #(R.RECIPES or {})
  if CC and CC.n == n then return CC end
  local cat, rec = {}, {}
  for _, rc in ipairs(R.RECIPES or {}) do if rc.out then rec[rc.out] = rc end end
  for code, it in pairs(R.ITEMS or {}) do
    local rc = rec[code]
    local desc = ((it and it.desc) or ""):lower()
    local c
    if R.STATIONS and R.STATIONS[code:lower()] then c = "stations"
    elseif rc and rc._tag == "terraweapons" then c = "terrain"
    elseif desc:find("worn passively", 1, true) then c = "wearables"
    elseif VEHICLE_SET[code] then c = "vehicles"
    elseif rc and rc._tag == "items" then c = "weapons"
    elseif rc then c = MACH_CAT[rc.st or ""] or "m_other" end
    if c then cat[code] = c end
  end
  -- raw/mined/refined materials that aren't themselves a craftable/placeable - grouped by the design
  -- doc's own SC_* menu-section (sectionOf above), falling back to "ores" (the existing progression
  -- highlight, see ORE_SET) or the flat "materials" catch-all only for codes with no real backing
  -- element at all (foraged foods, quest-only tokens).
  for code in pairs(collectMatCodes()) do
    if not cat[code] then
      cat[code] = ORE_SET[code] and "ores" or (sectionOf(code) or "materials")
    end
  end
  local cnt = {}
  for _, c in pairs(cat) do cnt[c] = (cnt[c] or 0) + 1 end
  CC = { n = n, cat = cat, rec = rec, cnt = cnt }
  return CC
end
local function catOf(code) return classMap().cat[code] end
local function recipeOf(code) return classMap().rec[code] end

-- enemies.lua's KINDS table is local; mirrored here from its source (2026-08-26). If it drifts, the live
-- HP/dmg/count still come from R.enemyList() where possible - only the flavour text is static.
local CREATURES = {
  slime  = { name = "Slime", hp = 30, dmg = 6, w = 5, h = 6, speed = 0.9,
             behavior = "Hops slowly toward you, day and night, on the surface or underground. The weakest enemy - a good first target for a new weapon." },
  zombie = { name = "Zombie", hp = 50, dmg = 10, w = 3, h = 10, speed = 0.55,
             behavior = "Walks along the ground toward you. Only spawns at night, on the surface." },
  bat    = { name = "Cave Bat", hp = 20, dmg = 5, w = 3, h = 4, speed = 1.1,
             behavior = "Flies freely with no gravity. Found underground in caves, day or night." },
  boss   = { name = "the Slime King", hp = 420, dmg = 18, w = 14, h = 16, speed = 0.9,
             behavior = "A rare boss. Spawns after you survive a full night with enemies (key N) turned on. Drops a rare accessory when defeated." },
}
local CREATURE_ORDER = { "slime", "zombie", "bat", "boss" }

-- biomeAt()'s soil/grass/tree table lives inside rpg.lua core (local BIOME), mirrored here.
local BIOMES = {
  forest = { label = "Forest", grass = "GRSS", soil = "GOO", trees = "~50% of surface columns",
             desc = "The default biome - chunk 0 is always forest, so it's where every new world spawns you. Grass-topped dirt with roughly one tree every other column." },
  swamp  = { label = "Swamp", grass = "GRSS", soil = "GOO", trees = "~35% of surface columns",
             desc = "Same soil as forest but fewer, denser trees and shallow standing pools of water at the surface." },
  desert = { label = "Desert", grass = "SAND", soil = "SAND", trees = "none",
             desc = "Sand dunes capping solid rock all the way down, so the sand can't avalanche away. No trees grow here." },
  -- surface cover corrected 2026-09-02 (@guide, verified against world.lua's own soilMaterial()):
  -- the top pixel (d==0) is SNOW (has("SNOW") and "SNOW" or "ICE"), ICE is the SUBSOIL beneath it,
  -- not the surface cover -- was previously listed as ICE/ICE, which named the wrong one as "grass".
  snow   = { label = "Snow / Tundra", grass = "SNOW", soil = "ICE", trees = "~25% of surface columns",
             desc = "Snow at the surface over an icy subsoil. Sparse, pine-like trees." },
}
local BIOME_ORDER = { "forest", "swamp", "desert", "snow" }

-- replicated from rpg.lua core's HELP array + the key claims other plugins posted in the hub, since HELP is local.
local CONTROLS = {
  move  = { label = "Movement", lines = { "A / D - run left / right", "W - jump (hold longer = higher)", "S - fast-fall, or sink while swimming", "Space - pause (native TPT)" } },
  tools = { label = "Tools (slots 1-5)", lines = { "Hold LEFT mouse to use the selected tool", "1 Pick   2 Axe   3 Sword   4 Torch   5 Bucket",
            "Picks: wood (by hand) < stone (workbench) < iron / steel / diamond (anvil)" } },
  blocks = { label = "Blocks (slots 6-0)", lines = { "Hold LEFT mouse to place the selected block", "[ and ] - shrink / grow the placement brush", "B - toggle the 4px snap grid" } },
  select = { label = "Selecting items", lines = { "Number keys 1-0, or the mouse wheel", "E - bag & crafting panel (ui.lua)" } },
  view  = { label = "Zoom / detail view", lines = { "Z - open the native TPT zoom: move, click to lock it in place, Z again to close",
            "Inside the zoom window: 1px-precise dig/place, wheel resizes the brush, a palette of your bag sits below it" } },
  world = { label = "World & mining", lines = { "Walk or dig in any direction - the world scrolls endlessly, nothing is pre-built",
            "T - toggle the smart cursor (auto-targets the nearest diggable block along your aim)",
            "Buildings are generated as you explore - see the Structures tab for every one,",
            "how big it really is next to you, and which of them have working doors" } },
  craft = { label = "Crafting stations", lines = { "by hand -> Workbench -> Furnace (light its coal with the torch) -> Anvil", "Open the bag (E) to see every recipe you can currently afford" } },
  items = { label = "Accessories & chests", lines = { "Chests hidden in caves hold accessories - see the Accessories tab", "X - Magic Mirror teleports you home (once owned)", "G - Grappling Hook (once owned)" } },
  other = { label = "Other keys", lines = { "K save   R respawn   N enemies on/off   M minimap   H HUD", "Esc - menu & controls card   F1 - debug overlay" } },
  uiext = { label = "UI panels (ui.lua)", lines = { "J - quest log", "C - controls card",
            "Y - submit something to PhoenixFire808: drag a region for a machine/plant/cave/etc, or press Enter with no region for a quick bug report or suggestion" } },
  guide = { label = "This guide (L)", lines = { "L, the GUIDE quick-button (top-right, always on screen), or the E-bag's GUIDE tab all open this - Esc or the X in the corner closes it", "Click a category, then an entry, then any highlighted word to jump to it",
            "'< back' and every list/page scroll (drag the bar, or the mouse wheel) are all click/wheel-only - nothing in here requires a key" } },
  -- Two DIFFERENT things share the word "sandbox" in this game (verified live, rpg.lua, 2026-09-02)
  -- and mixing them up is an easy mistake: R.sandbox is an Esc-menu toggle inside a normal run
  -- (unlimited materials, no danger); R.sandboxMode is a completely separate plain-Powder-Toy build
  -- mode reached from the title screen's own "Sandbox" button, with no RPG running at all. Every
  -- action below has a real on-screen mouse control - PhoenixFire808 does not want function-key-only
  -- controls ("my hand is broken"), and every one of these was checked against the live source, not
  -- assumed - the one honest exception (F6) is named as a gap, not hidden.
  sandbox = { label = "Sandbox mode (two different things)", lines = {
            "SURVIVAL SANDBOX (inside a normal run): Esc menu, click 'Sandbox mode' to switch it on -",
            "no damage, free crafting, and this guide's TAKE button gives unlimited stock. Click it",
            "again to switch off (any leftover free stacks are cleared automatically).",
            "",
            "BUILD SANDBOX (title screen 'Sandbox' button): a blank, plain Powder Toy canvas, no RPG",
            "running. Your real save is untouched - it autosaves before you enter, and leaving keeps",
            "whatever you built to come back to. On-screen buttons, top-left: Character (spawns a",
            "walkable test body so you can try what you just built - click again to remove it),",
            "Report (bug/suggestion box), Menu (back to the title screen). Top-right: a small",
            "button starts a stamp submission to PhoenixFire808, with a history button once you've",
            "sent one - same feature as the Y key/flag icon outside sandbox.",
            "Known gap, not hidden: the dev toolkit (pause/step/world-sampler) only opens with the",
            "F6 key right now - its on-screen button is not wired up yet (reported, not this file's",
            "fix - guide.lua only documents, it doesn't own rpg.lua/sandbox.lua).",
  } },
}
local CONTROL_ORDER = { "move", "tools", "blocks", "select", "view", "world", "craft", "items", "other", "uiext", "guide", "sandbox" }

-- Machines are five entries rather than one because a single "Machines" row was hiding ~90 kits behind it.
-- They read in build order (workbench -> furnace -> anvil -> research -> advanced lab), so the column doubles
-- as a progression ladder: everything you can build right now is in the rows above the bench you have.
local CATS = {
  -- Deliberately CATS[1] (PhoenixFire808, escalating 3x: "super, super important" -> "easily
  -- submit" -> "EXTREMELY PROMINENT"). Was one bullet buried three clicks deep (Controls ->
  -- UI panels (ui.lua) -> read the whole card) - now the very first thing anyone sees opening
  -- the guide at all, category label carries the keybind so even a glance at the list teaches it.
  { id = "submit", label = "Submit to PhoenixFire808 (Y)" },
  { id = "progression", label = "Progression" },
  { id = "materials", label = "Materials" },
  { id = "ores", label = "Ores & Depths" },
  -- Material browser: every raw/refined material bucketed by its real engine menu_section (see
  -- SC_SECTION/sectionOf above) - the design doc's own categorisation, read live off elem.property so
  -- new materials/veins any lane adds sort themselves with nothing to update here.
  { id = "mat_elec", label = "Mat: Electronics" },
  { id = "mat_powered", label = "Mat: Powered" },
  { id = "mat_sensor", label = "Mat: Sensors" },
  { id = "mat_force", label = "Mat: Force & Motion" },
  { id = "mat_explosive", label = "Mat: Explosives" },
  { id = "mat_gas", label = "Mat: Gases" },
  { id = "mat_liquid", label = "Mat: Liquids" },
  { id = "mat_powders", label = "Mat: Powders" },
  { id = "mat_solids", label = "Mat: Solids/Metals" },
  { id = "mat_nuclear", label = "Mat: Nuclear/Exotic" },
  { id = "mat_special", label = "Mat: Special" },
  { id = "mat_life", label = "Mat: Life" },
  { id = "tools", label = "Tools" },
  { id = "stations", label = "Stations & Processes" },
  { id = "m_workbench", label = "Machines: Workbench" },
  { id = "m_furnace", label = "Machines: Furnace" },
  { id = "m_anvil", label = "Machines: Anvil" },
  { id = "m_research", label = "Machines: Research" },
  { id = "m_advlab", label = "Machines: Adv. Lab" },
  { id = "m_other", label = "Machines: Other" },
  { id = "vehicles", label = "Vehicles" },
  { id = "weapons", label = "Weapons & Gadgets" },
  { id = "terrain", label = "Terrain Weapons" },
  { id = "wearables", label = "Wearables & Armor" },
  { id = "accessories", label = "Accessories" },
  { id = "creatures", label = "Creatures" },
  { id = "biomes", label = "Biomes" },
  { id = "structures", label = "Structures" },
  { id = "controls", label = "Controls" },
}
local NOSORT = { tools = true, stations = true, creatures = true, biomes = true, controls = true }
-- A machine tier legitimately empties out when every kit built there is claimed by a more specific category
-- (the Furnace's only two kits are the Magma Lance and Cryo Former, both terrain weapons; Research builds the
-- Advanced Lab, two weapons and an armour plate). Showing three dead rows would be noise, so machine tiers are
-- listed only when they actually hold something. Every other category always has entries, so nothing else is
-- filtered - which also keeps this off the expensive buildEntries path and on the cached count instead.
local function visibleCats()
  local cnt = classMap().cnt
  local out = {}
  for _, c in ipairs(CATS) do
    if (not isHideableCat(c.id)) or (cnt[c.id] or 0) > 0 then out[#out + 1] = c end
  end
  return out
end

-- ================================================================ colours
local TITLECOL, HEADCOL, LABELCOL, VALCOL, DESCCOL, DIMCOL, LINKCOL =
  {255, 220, 80}, {140, 200, 255}, {190, 190, 200}, {210, 210, 220}, {200, 200, 180}, {130, 130, 140}, {120, 220, 255}

-- ================================================================ bitwise AND (for TPT's Properties bitmask)
local band
if bit and bit.band then band = bit.band
elseif bit32 and bit32.band then band = bit32.band
else band = function(a, b) local r, p = 0, 1
    a, b = math.floor(a), math.floor(b)
    while a > 0 or b > 0 do if a % 2 == 1 and b % 2 == 1 then r = r + p end; a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2 end
    return r end
end

-- ================================================================ small text/line helpers
local function T(text, col) return { t = tostring(text), c = col or VALCOL } end
local function LK(text, cat, id) return { t = tostring(text), c = LINKCOL, link = { cat = cat, id = id } } end
local function addLine(lines, seg) if seg.t then lines[#lines + 1] = { seg } else lines[#lines + 1] = seg end end
local function wrapText(s, maxChars)
  s = s or ""; local out = {}
  for para in (s .. "\n"):gmatch("(.-)\n") do
    if para == "" then out[#out + 1] = "" else
      local line = ""
      for word in para:gmatch("%S+") do
        if #line == 0 then line = word
        elseif #line + 1 + #word <= maxChars then line = line .. " " .. word
        else out[#out + 1] = line; line = word end
      end
      out[#out + 1] = line
    end
  end
  return out
end
local function hitRect(r, x, y) return r and x >= r[1] and x < r[3] and y >= r[2] and y < r[4] end

-- ================================================================ classify a raw code -> which category it links to
local function classify(code)
  if R.ACCS and R.ACCS[code] then return "accessories" end
  local c = catOf(code)   -- live: every craftable bucket AND, now, every SC_*/ores material bucket too
  if c then return c end
  return "materials"      -- last resort: a code with no real backing element and no recipe/mine entry
end
-- true when (catId, id) is a real inventory-able code R.grantItem can act on (a hotbar block-slot item,
-- not a tool/accessory/creature/biome/control which don't live in R.inventory)
local function isTakeable(catId, id)
  if not id then return false end
  if catId == "materials" or catId == "ores" or catId == "weapons"
     or catId == "terrain" or catId == "wearables" or catId == "vehicles" then return true end
  if MAT_SECTION_CATS[catId] then return true end
  if isMachineCat(catId) then return true end
  if catId == "stations" and id ~= "hand" then return true end
  return false
end

-- ================================================================ live acquisition index (2026-09-02, @acq_discover)
-- PhoenixFire808: "all the elements need to be FOUND and ACQUIRED" - the material browser only ever listed a
-- material if some OTHER table already referenced its code (R.NAMES/R.MINEABLE/R.HARD/a recipe/a pick/a sword).
-- Anything nobody had wired up yet - most of the 124 measured-unobtainable stock elements - was invisible
-- rather than shown as "not yet obtainable", which is dishonest (an empty search result reads as "doesn't
-- exist", not "exists, nothing gives it to you yet"). allElementCodes() below fixes that at the source: it
-- asks the live engine what elements actually exist THIS session (0..PT_NUM-1, exactly the same 0..511 scan
-- rpg.lua's own id() helper already uses to resolve a name to a type id - PT_NUM=512 per
-- src/simulation/ElementDefs.h), so every real element - stock or RPG-custom - is guaranteed to be findable
-- and browsable even if nothing anywhere gives it to the player. Never a hand-typed 195-name list.
local ALL_ELEM_CACHE = nil
local function allElementCodes()
  if ALL_ELEM_CACHE then return ALL_ELEM_CACHE end
  local set = {}
  for tid = 0, (2 ^ ((sim and sim.PMAPBITS) or 9)) - 1 do
    local ok, nm = pcall(elem.property, tid, "Name")
    if ok and type(nm) == "string" and nm ~= "" then set[nm] = true end
  end
  ALL_ELEM_CACHE = set
  return set
end

-- The over-count warning in this task's brief: a naive audit counting only R.MINEABLE/recipe-outputs/quest
-- rewards misses two real acquisition paths that exist ONLY as literal Lua source in other lanes' plugin
-- files, never on a shared R.* table - a machine/enemy/forage `R.give("CODE", n)` grant, and R.actorMine's
-- mining-remap ("mine BCOL, receive COAL" - rpg.lua/vehicles.lua both have `(nm == "BCOL") and "COAL" or nm`).
-- scanAcquisitionSources() closes that gap the same way this project's own check_reachable.py does it on the
-- Python side (per @gates' 2026-09-02 hub post): read the REAL source text of every plugin R.PLUGINS lists
-- plus rpg.lua itself, once, and pattern-match the two shapes directly - never a hand-copied duplicate of
-- what those files grant. Only literal string arguments are found this way (`R.give("WOOD", n)`); a dynamic
-- grant (`R.give(nm, 1)`) can't be resolved statically and is a stated, honest limitation, not silently
-- claimed as covered - those codes still surface correctly via R.MINEABLE/R.RECIPES/R.QUESTS instead.
local function openSourceFile(relPath)
  local candidates = {
    "../scripts/lua/" .. relPath, "scripts/lua/" .. relPath,
    "D:/The-Powder-Toy/scripts/lua/" .. relPath, "D:/powder-toy/scripts/lua/" .. relPath,
  }
  for _, p in ipairs(candidates) do local f = io.open(p, "r"); if f then return f end end
  return nil
end
local ACQSRC_CACHE = nil
local function scanAcquisitionSources()
  if ACQSRC_CACHE then return ACQSRC_CACHE end
  local grants, mineRemap = {}, {}
  local files = { "rpg.lua" }
  for _, name in ipairs(R.PLUGINS or {}) do
    if name ~= "guide" then files[#files + 1] = "rpg_plugins/" .. name .. ".lua" end
  end
  for _, rel in ipairs(files) do
    local f = openSourceFile(rel)
    if f then
      local text = f:read("*a") or ""; f:close()
      for code in text:gmatch('[%.%s]give%(%s*"([%u%d_%-]+)"') do
        grants[code] = grants[code] or {}
        grants[code][rel] = true
      end
      for from, to in text:gmatch('%(nm%s*==%s*"(%u+)"%)%s*and%s*"(%u+)"%s*or%s*nm') do
        mineRemap[from] = to
      end
    end
  end
  ACQSRC_CACHE = { grants = grants, mineRemap = mineRemap }
  return ACQSRC_CACHE
end
-- true if any R.QUESTS entry's one-time reward hands out this code - reads the live table directly
-- (reward keys are already-resolved runtime values, e.g. the ROCK alias resolves to the real BSLT/BRCK
-- string by the time this reads it), not a text scan.
local function isQuestReward(id)
  for _, q in ipairs(R.QUESTS or {}) do if q.reward and q.reward[id] then return true end end
  return false
end
-- Built once, invalidated on the same recipe-count trigger every other cache in this file uses - never
-- re-derived per frame or per row. Every acquisition fact a material page or an entry-list row needs
-- (verb summary, plain obtainable/not flag, mine-remap target, which files grant it) lives here.
local ACQ_CACHE = nil
local function buildAcquisitionIndex()
  local n = #(R.RECIPES or {})
  if ACQ_CACHE and ACQ_CACHE.n == n then return ACQ_CACHE end
  local src = scanAcquisitionSources()
  local craftOut = {}
  for _, rc in ipairs(R.RECIPES or {}) do craftOut[rc.out] = true end
  local idx = {}
  for code in pairs(allElementCodes()) do
    local verbs = {}
    local remapTo = src.mineRemap[code]
    if R.MINEABLE[code] then
      verbs[#verbs + 1] = remapTo and ("mine (yields " .. R.nice(remapTo) .. ")") or "mine"
    end
    if craftOut[code] then verbs[#verbs + 1] = "craft" end
    if R.FOODS and R.FOODS[code] then verbs[#verbs + 1] = "forage/grow" end
    if isQuestReward(code) then verbs[#verbs + 1] = "quest reward" end
    if src.grants[code] then verbs[#verbs + 1] = "found/granted" end
    idx[code] = {
      verbs = verbs,
      summary = (#verbs > 0) and table.concat(verbs, ", ") or "not currently obtainable",
      obtainable = #verbs > 0,
      remapTo = remapTo,
      grantFiles = src.grants[code],
    }
  end
  ACQ_CACHE = { n = n, idx = idx }
  return ACQ_CACHE
end
local function acqInfo(id) return buildAcquisitionIndex().idx[id] end

-- ================================================================ entry lists per category
collectMatCodes = function()
  local set = {}
  for k in pairs(allElementCodes()) do set[k] = true end   -- every real element this session, obtainable or not
  for k in pairs(R.NAMES or {}) do set[k] = true end
  for k in pairs(R.MINEABLE or {}) do set[k] = true end
  for k in pairs(R.HARD or {}) do set[k] = true end
  for _, rc in ipairs(R.RECIPES or {}) do
    set[rc.out] = true
    for k in pairs(rc.need or {}) do set[k] = true end
  end
  for _, t in ipairs(R.PICKS or {}) do for k in pairs(t.need or {}) do set[k] = true end end
  for _, t in ipairs(R.SWORDS or {}) do for k in pairs(t.need or {}) do set[k] = true end end
  return set
end

local function buildEntries(catId)
  local out = {}
  if catId == "materials" or catId == "ores" or MAT_SECTION_CATS[catId] then
    local set = collectMatCodes()
    local cm = classMap()
    for k in pairs(set) do
      -- classMap() already resolved every material code to exactly one bucket (its own craftable
      -- category, "ores", an SC_* section, or the flat "materials" catch-all) - just filter on it.
      if cm.cat[k] == catId then
        if R.eid(k) or R.NAMES[k] then
          local a = acqInfo(k)
          out[#out + 1] = { id = k, label = R.nice(k), obtainable = a and a.obtainable or false }
        end
      end
    end
    if catId == "ores" then
      for _, k in ipairs(ORE_CODES) do
        local exists = false; for _, e in ipairs(out) do if e.id == k then exists = true end end
        if not exists and (R.eid(k) or R.MINEABLE[k]) then
          local a = acqInfo(k)
          out[#out + 1] = { id = k, label = R.nice(k), obtainable = a and a.obtainable or false }
        end
      end
    end
  elseif catId == "tools" then
    for i, t in ipairs(R.PICKS or {}) do out[#out + 1] = { id = "PICK:" .. i, label = t.name } end
    for i, t in ipairs(R.SWORDS or {}) do out[#out + 1] = { id = "SWORD:" .. i, label = t.name } end
    out[#out + 1] = { id = "TORCH", label = (R.TOOLS.torch and R.TOOLS.torch.name) or "torch" }
    out[#out + 1] = { id = "BUCKET", label = (R.TOOLS.bucket and R.TOOLS.bucket.name) or "bucket" }
  elseif catId == "stations" then
    -- built from core's own R.STATIONS rather than a copied list, so Research Bench and Advanced Lab
    -- (added later by other lanes) show up without this file being touched.
    out[#out + 1] = { id = "hand", label = "By hand" }
    local sts = {}
    for k in pairs(R.STATIONS or {}) do if k ~= "hand" then sts[#sts + 1] = k end end
    table.sort(sts)
    for _, k in ipairs(sts) do
      local code = k:upper()
      out[#out + 1] = { id = R.ITEMS[code] and code or k, label = R.STATIONS[k] or R.nice(code) }
    end
  elseif isMachineCat(catId) or catId == "weapons" or catId == "terrain"
      or catId == "wearables" or catId == "vehicles" then
    -- one shared branch: every craftable category is just "which codes classMap() put in this bucket".
    for code in pairs(R.ITEMS or {}) do
      if catOf(code) == catId then out[#out + 1] = { id = code, label = R.nice(code) } end
    end
  elseif catId == "accessories" then
    for _, k in ipairs(R.ACC_ORDER or {}) do if R.ACCS[k] then out[#out + 1] = { id = k, label = R.ACCS[k].name } end end
  elseif catId == "creatures" then
    for _, k in ipairs(CREATURE_ORDER) do out[#out + 1] = { id = k, label = CREATURES[k].name } end
  elseif catId == "biomes" then
    for _, k in ipairs(BIOME_ORDER) do out[#out + 1] = { id = k, label = BIOMES[k].label } end
  elseif catId == "structures" then
    -- Read straight off world.lua's live R.structDefs rather than a copied list here, so this page
    -- reports what ACTUALLY parsed this session. A structure whose JSON failed to load is missing
    -- from the list, which is the fastest way to see that from inside the game.
    for _, cat in ipairs({ "surface", "underground", "deep", "detail" }) do
      for _, d in ipairs((R.structDefs or {})[cat] or {}) do
        out[#out + 1] = { id = d.id, label = (d.id:gsub("_", " ")) }
      end
    end
  elseif catId == "controls" then
    for _, k in ipairs(CONTROL_ORDER) do out[#out + 1] = { id = k, label = CONTROLS[k].label } end
  elseif catId == "submit" then
    out[#out + 1] = { id = "how", label = "How it works" }
  elseif catId == "progression" then
    out[#out + 1] = { id = "overview", label = "Your progress" }
  end
  if not NOSORT[catId] then table.sort(out, function(a, b) return a.label < b.label end) end
  return out
end

-- Cached the same way classMap() is (keyed on the recipe count) - getEntries() runs from the draw hook
-- every frame, and buildEntries() for a material-heavy category was re-scanning R.NAMES/R.RECIPES/
-- R.PICKS/R.SWORDS from scratch on EVERY frame the guide stayed open. Never rebuild per frame - only on
-- the same recipe-count-changed trigger the rest of this rework already uses.
local ENT_CACHE = {}
local function cachedEntries(catId)
  local n = #(R.RECIPES or {})
  local c = ENT_CACHE[catId]
  if c and c.n == n then return c.list end
  local list = buildEntries(catId)
  ENT_CACHE[catId] = { n = n, list = list }
  return list
end
local function getEntries()
  if not G.cat then return {} end
  local list = cachedEntries(G.cat)
  if G.search ~= "" then
    local q = G.search:lower(); local filtered = {}
    for _, e in ipairs(list) do if e.label:lower():find(q, 1, true) or e.id:lower():find(q, 1, true) then filtered[#filtered + 1] = e end end
    list = filtered
  end
  return list
end

-- ================================================================ expensive-but-cached world sampling
local function sampleLocation(code)
  local c = G.locCache[code]; if c then return c end
  local DEPTH = R.DEPTH or 1900
  local xs = { 40, 700, 1400, -700 }
  local minD, maxD, count, biomeCounts = nil, nil, 0, {}
  for _, xo in ipairs(xs) do
    local surf = R.surfaceAt(xo)
    for wy = 4, DEPTH - 1, 6 do
      local ok, el = pcall(R.gen, xo, wy)
      if ok and el == code then
        count = count + 1
        local d = wy - surf
        if d > 0 then if not minD or d < minD then minD = d end; if not maxD or d > maxD then maxD = d end end
        local b = R.biomeAt(xo); biomeCounts[b] = (biomeCounts[b] or 0) + 1
      end
    end
  end
  local result
  if count == 0 or not minD then result = { found = false }
  else
    local bestB, bestN = nil, -1
    for b, n in pairs(biomeCounts) do if n > bestN then bestB, bestN = b, n end end
    result = { found = true, minDepth = minD, maxDepth = maxD, biome = bestB }
  end
  G.locCache[code] = result; return result
end
local function biomeChunks(biomeId)
  if not G.biomeCache then
    local map = {}
    for c = -8, 24 do local wx = c * 612 + 300; local b = R.biomeAt(wx); map[b] = map[b] or {}; table.insert(map[b], c) end
    G.biomeCache = map
  end
  return G.biomeCache[biomeId] or {}
end
local function liveCount(kind)
  local ok, list = pcall(R.enemyList); if not ok or not list then return nil end
  local n = 0; for _, e in ipairs(list) do if e.kind == kind and not e.dead then n = n + 1 end end
  return n
end

-- ================================================================ shared page sections
local function elemFactsLines(id, lines)
  local tid = R.eid(id)
  if not tid then addLine(lines, T("(not a real element in this session)", DIMCOL)); return end
  local function pf(field) local ok, v = pcall(elem.property, tid, field); if ok then return v end; return nil end
  local temp, hiT, hiTr, loT, loTr = pf("Temperature"), pf("HighTemperature"), pf("HighTemperatureTransition"), pf("LowTemperature"), pf("LowTemperatureTransition")
  local flam, expl, hard, hc, meltable = pf("Flammable"), pf("Explosive"), pf("Hardness"), pf("HeatConduct"), pf("Meltable")
  local fd, props = pf("Falldown"), pf("Properties") or 0
  local function hasBit(b) return b and band(props, b) ~= 0 end
  local state = "unknown"
  if hasBit(elem.TYPE_LIQUID) then state = "liquid"
  elseif hasBit(elem.TYPE_GAS) then state = "gas"
  elseif hasBit(elem.TYPE_SOLID) then state = "solid (static, doesn't fall)"
  elseif hasBit(elem.TYPE_PART) then state = (fd and fd > 0) and "powder (falls under gravity)" or "particle"
  elseif hasBit(elem.TYPE_ENERGY) then state = "energy (spark / light / heat)" end
  addLine(lines, T("State: " .. state, VALCOL))
  if temp then addLine(lines, T(string.format("Default temperature: %.0fK (%.0fC)", temp, temp - 273.15), VALCOL)) end
  if hiT and hiT < 9999 then
    local seg = { T(string.format("Melts / ignites at %.0fK (%.0fC)", hiT, hiT - 273.15), VALCOL) }
    local meltsToLava = false
    if hiTr and hiTr >= 0 then
      local nm = R.nameOf(hiTr); meltsToLava = (nm == "LAVA")
      seg[#seg + 1] = T(" -> becomes ", VALCOL); seg[#seg + 1] = LK(R.nice(nm), classify(nm), nm)
    end
    addLine(lines, seg)
    -- Melt/solidify (2026-09-02, verified against knowledge/audit-v1175.md's live TEG/STEL/NA
    -- round-trip test): the engine remembers WHICH real material melted (ctype), so this is
    -- genuine molten metal, not inert lava - it resolidifies back into the exact same material
    -- when it cools, not generic rock. This is a real engine behaviour (Simulation.cpp captures
    -- ctype=type on any HighTemperatureTransition==LAVA), not something this game scripts itself.
    if meltsToLava then
      addLine(lines, T("Real molten " .. R.nice(id) .. " - cools back into " .. R.nice(id) .. " itself, not stone.", { 255, 180, 120 }))
    end
  end
  if loT and loT > -1 then
    local seg = { T(string.format("Changes below %.0fK (%.0fC)", loT, loT - 273.15), VALCOL) }
    if loTr and loTr >= 0 then local nm = R.nameOf(loTr); seg[#seg + 1] = T(" -> becomes ", VALCOL); seg[#seg + 1] = LK(R.nice(nm), classify(nm), nm) end
    addLine(lines, seg)
  end
  if id == "LAVA" then
    addLine(lines, T("Real molten metal (heated past its own melting point) keeps its own identity", { 200, 200, 180 }))
    addLine(lines, T("and resolidifies back into that exact metal, not the default cooling above -", { 200, 200, 180 }))
    addLine(lines, T("that default only applies to lava with no captured source material.", { 200, 200, 180 }))
  end
  if flam and flam > 0 then addLine(lines, T("Flammable: yes (rating " .. flam .. ")", { 255, 160, 120 })) end
  if expl and expl > 0 then addLine(lines, T("Explosive: yes (rating " .. expl .. ")", { 255, 120, 120 })) end
  if hard then addLine(lines, T("Hardness (acid resistance): " .. hard, VALCOL)) end
  if hc then addLine(lines, T(string.format("Heat conductivity: %.0f", hc), VALCOL)) end
  if meltable and meltable ~= 0 then addLine(lines, T("Meltable under the right conditions (heat/pressure interaction).", VALCOL)) end
end
local function mineInfoLines(id, lines)
  local tier = R.MINEABLE[id]; if not tier then return end
  addLine(lines, T("", VALCOL)); addLine(lines, T("MINING", HEADCOL))
  local remapTo = scanAcquisitionSources().mineRemap[id]
  if remapTo then
    addLine(lines, { T("Mining this actually yields ", { 255, 200, 120 }), LK(R.nice(remapTo), classify(remapTo), remapTo), T(" in your inventory, not " .. R.nice(id) .. " itself.", { 255, 200, 120 }) })
  end
  addLine(lines, T("Tier " .. tier .. ".  " .. (R.HARD[id] or "?") .. " hits at a pick matching this tier exactly.", VALCOL))
  local full, can = {}, {}
  for i, t in ipairs(R.PICKS or {}) do
    if t.power >= tier then full[#full + 1] = { i, t } elseif t.power >= tier - 1 then can[#can + 1] = { i, t } end
  end
  local function segList(prefix, arr)
    if #arr == 0 then return nil end
    local seg = { T(prefix, VALCOL) }
    for j, pt in ipairs(arr) do if j > 1 then seg[#seg + 1] = T(", ", VALCOL) end; seg[#seg + 1] = LK(pt[2].name, "tools", "PICK:" .. pt[1]) end
    return seg
  end
  local s1, s2 = segList("Full speed: ", full), segList("Can mine slowly: ", can)
  if s1 then addLine(lines, s1) end
  if s2 then addLine(lines, s2) end
  if not s1 and not s2 then addLine(lines, T("No pick in this world can mine it yet.", DIMCOL)) end
end
local function locationLines(id, lines)
  addLine(lines, T("", VALCOL)); addLine(lines, T("WHERE FOUND", HEADCOL))
  local loc = sampleLocation(id)
  if not loc.found then addLine(lines, T("Not generated naturally in this world (crafted only, or too rare to sample).", DIMCOL))
  else
    addLine(lines, T(string.format("Depth: %d-%dm underground", math.floor(loc.minDepth / 4), math.floor(loc.maxDepth / 4)), VALCOL))
    if loc.biome then addLine(lines, { T("Most common in: ", VALCOL), LK(BIOMES[loc.biome] and BIOMES[loc.biome].label or loc.biome, "biomes", loc.biome) }) end
  end
end
local function usedInLines(id, lines)
  addLine(lines, T("", VALCOL)); addLine(lines, T("USED IN", HEADCOL))
  local any = false
  for _, rc in ipairs(R.RECIPES or {}) do if rc.need and rc.need[id] then any = true
    addLine(lines, { T(rc.need[id] .. "x -> ", VALCOL), LK(R.nice(rc.txt or rc.out), classify(rc.out), rc.out), T("  (" .. (R.STATIONS[rc.st] or rc.st or "hand") .. ")", DIMCOL) }) end end
  for i, t in ipairs(R.PICKS or {}) do if t.need[id] then any = true
    addLine(lines, { T(t.need[id] .. "x -> ", VALCOL), LK(t.name, "tools", "PICK:" .. i), T("  (" .. (R.STATIONS[t.st] or t.st) .. ")", DIMCOL) }) end end
  for i, t in ipairs(R.SWORDS or {}) do if t.need[id] then any = true
    addLine(lines, { T(t.need[id] .. "x -> ", VALCOL), LK(t.name, "tools", "SWORD:" .. i), T("  (" .. (R.STATIONS[t.st] or t.st) .. ")", DIMCOL) }) end end
  -- Weapon ammo consumption (KINETIC_AMMO/w.alts) lives entirely inside items.lua, local to that file - not
  -- something this page can see without items.lua exposing it, and hand-copying it here is exactly the
  -- hardcoded-list antipattern that buried ~90 craftables before v1.15.98. Self-wires the moment items.lua
  -- (or any plugin) publishes R.AMMO_CONSUMERS[code] = { {weapon=code, cost=n, continuous=bool}, ... } -
  -- same defensive "if the table exists, use it" pattern this file already uses for R.hooks.wheel below.
  -- Exact spec requested from @acq_discover, routed by the coordinator, 2026-09-02.
  if R.AMMO_CONSUMERS and R.AMMO_CONSUMERS[id] then
    for _, c in ipairs(R.AMMO_CONSUMERS[id]) do
      any = true
      local per = (c.cost or 1) .. "x " .. (c.continuous and "every few shots (while firing)" or "per shot")
      addLine(lines, { T(per .. " -> ", VALCOL), LK(R.nice(c.weapon), classify(c.weapon), c.weapon), T("  (ammo)", DIMCOL) })
    end
  end
  if not any then addLine(lines, T("Not used in any known recipe.", DIMCOL)) end
end
local function producedByLines(id, lines)
  addLine(lines, T("", VALCOL)); addLine(lines, T("PRODUCED BY", HEADCOL))
  local any = false
  for _, rc in ipairs(R.RECIPES or {}) do if rc.out == id then any = true
    local seg = { T("Craft " .. rc.n .. "x at " .. (R.STATIONS[rc.st] or rc.st) .. ": ", VALCOL) }
    local first = true
    for k, n in pairs(rc.need) do if not first then seg[#seg + 1] = T(", ", VALCOL) end; first = false; seg[#seg + 1] = LK(n .. "x " .. R.nice(k), classify(k), k) end
    addLine(lines, seg)
  end end
  if R.MINEABLE[id] then any = true; addLine(lines, T("Mined directly from terrain (see MINING / WHERE FOUND above).", VALCOL)) end
  if not any then addLine(lines, T("Not produced by any known recipe or mining.", DIMCOL)) end
end
local function needSeg(need)
  local seg = {}; local first = true
  for k, n in pairs(need) do if not first then seg[#seg + 1] = T(", ", VALCOL) end; first = false; seg[#seg + 1] = LK(n .. "x " .. R.nice(k), classify(k), k) end
  return seg
end
local function stationUsers(stKey, lines)
  addLine(lines, T("", VALCOL)); addLine(lines, T("MADE HERE", HEADCOL))
  local any = false
  for _, rc in ipairs(R.RECIPES or {}) do if (rc.st or "hand") == stKey then any = true; addLine(lines, { LK(R.nice(rc.txt or rc.out), classify(rc.out), rc.out) }) end end
  for i, t in ipairs(R.PICKS or {}) do if (t.st or "hand") == stKey then any = true; addLine(lines, { LK(t.name, "tools", "PICK:" .. i) }) end end
  for i, t in ipairs(R.SWORDS or {}) do if (t.st or "hand") == stKey then any = true; addLine(lines, { LK(t.name, "tools", "SWORD:" .. i) }) end end
  if not any then addLine(lines, T("Nothing craftable here yet.", DIMCOL)) end
end
-- how many of a given station kind (workbench/furnace/anvil/research/advlab) are placed in this world -
-- shared by the station page, the item/machine page's "you have a bench" line, and the progression page.
local function stationBuiltCount(kind)
  local n = 0
  for _, st in ipairs(R.stations or {}) do if st.kind == kind then n = n + 1 end end
  return n
end

-- ================================================================ page builders
-- "How to get it" verb summary (mine/craft/forage/quest reward/found-granted) - read live off the cached
-- acquisition index built above (R.MINEABLE/R.RECIPES/R.FOODS/R.QUESTS plus a real source-text scan for
-- literal R.give("CODE",n) grants and the actorMine remap edge) - never a hand-written per-material list.
local function grantedByLines(id, lines)
  local a = acqInfo(id)
  if not a or not a.grantFiles then return end
  addLine(lines, T("", VALCOL)); addLine(lines, T("FOUND / GRANTED", HEADCOL))
  local names = {}
  for rel in pairs(a.grantFiles) do names[#names + 1] = rel end
  table.sort(names)
  for _, rel in ipairs(names) do
    local label = rel:match("rpg_plugins/(%a+)%.lua") or rel:gsub("%.lua$", "")
    addLine(lines, T("- " .. label .. " (a machine, creature drop, foraging or event hands this out)", VALCOL))
  end
end
local function pageMaterialOrOre(id, catId)
  local lines = {}
  addLine(lines, { T(R.nice(id), TITLECOL), T("  [" .. id .. "]", DIMCOL) })
  local d = R.descOf(id)
  if d ~= "" then for _, s in ipairs(wrapText(d, 48)) do addLine(lines, T(s, DESCCOL)) end end
  local a = acqInfo(id) or { summary = "not currently obtainable", obtainable = false }
  addLine(lines, { T("How to get it: ", LABELCOL), T(a.summary, a.obtainable and { 140, 255, 140 } or { 255, 150, 90 }) })
  if not a.obtainable then
    addLine(lines, T("This element exists in the game but nothing currently gives it to the player.", { 255, 150, 90 }))
  end
  addLine(lines, T("You have: " .. R.inv(id), VALCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("PROPERTIES", HEADCOL))
  elemFactsLines(id, lines)
  mineInfoLines(id, lines)
  if catId == "ores" or R.MINEABLE[id] or id == "WATR" or id == "LAVA" then locationLines(id, lines) end
  grantedByLines(id, lines)
  usedInLines(id, lines)
  producedByLines(id, lines)
  return lines
end
local function pagePick(idx)
  local t = R.PICKS[idx]; local lines = {}
  addLine(lines, T(t.name, TITLECOL))
  for _, s in ipairs(wrapText(t.desc, 48)) do addLine(lines, T(s, DESCCOL)) end
  addLine(lines, T("", VALCOL))
  addLine(lines, T(string.format("Power %d   Reach %dpx   Speed %d (lower = faster)", t.power, t.reach, t.speed), VALCOL))
  local cur = R.TOOLS.pick.name == t.name
  addLine(lines, T(cur and "Currently equipped." or "Not currently equipped.", cur and { 140, 255, 140 } or DIMCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("CRAFTING", HEADCOL))
  addLine(lines, { T("At " .. (R.STATIONS[t.st] or t.st) .. ": ", VALCOL), table.unpack(needSeg(t.need)) })
  addLine(lines, T("", VALCOL)); addLine(lines, T("CAN MINE", HEADCOL))
  local names = {}
  for nm, tier in pairs(R.MINEABLE or {}) do if t.power >= tier then names[#names + 1] = { nm, tier } end end
  table.sort(names, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end; return a[1] < b[1] end)
  if #names == 0 then addLine(lines, T("nothing yet", DIMCOL)) else
    local seg = {}
    for i, e in ipairs(names) do if i > 1 then seg[#seg + 1] = T(", ", VALCOL) end; seg[#seg + 1] = LK(R.nice(e[1]), classify(e[1]), e[1]) end
    addLine(lines, seg)
  end
  return lines
end
local function pageSword(idx)
  local t = R.SWORDS[idx]; local lines = {}
  addLine(lines, T(t.name, TITLECOL))
  for _, s in ipairs(wrapText(t.desc, 48)) do addLine(lines, T(s, DESCCOL)) end
  addLine(lines, T("", VALCOL)); addLine(lines, T("Damage " .. t.dmg .. " per hit", VALCOL))
  local cur = R.TOOLS.sword.name == t.name
  addLine(lines, T(cur and "Currently equipped." or "Not currently equipped.", cur and { 140, 255, 140 } or DIMCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("CRAFTING", HEADCOL))
  addLine(lines, { T("At " .. (R.STATIONS[t.st] or t.st) .. ": ", VALCOL), table.unpack(needSeg(t.need)) })
  return lines
end
local function pageSimpleTool(label)
  local lines = {}
  if label == "Torch" then
    addLine(lines, T(R.TOOLS.torch and R.TOOLS.torch.name or "Torch", TITLECOL))
    addLine(lines, T("Reach: " .. (R.TOOLS.torch and R.TOOLS.torch.reach or "?") .. "px", VALCOL))
    addLine(lines, T("Uses 1 Wood per use. Aim at a lit furnace's coal to light it (needs sustained contact), or click empty ground to plant a standing torch - a real burning stick.", DESCCOL))
  else
    addLine(lines, T(R.TOOLS.bucket and R.TOOLS.bucket.name or "Bucket", TITLECOL))
    addLine(lines, T("Reach: " .. (R.TOOLS.bucket and R.TOOLS.bucket.reach or "?") .. "px", VALCOL))
    addLine(lines, T("Left-click water to scoop it into your inventory; left-click again to pour real water back out.", DESCCOL))
  end
  return lines
end
local function pageStation(id)
  local lines = {}
  if id == "hand" then
    addLine(lines, T("By hand", TITLECOL))
    addLine(lines, T("No station needed - craft it directly from the recipe list.", DESCCOL))
    stationUsers("hand", lines)
    return lines
  end
  addLine(lines, { T(R.nice(id), TITLECOL), T("  [" .. id .. "]", DIMCOL) })
  local d = R.descOf(id); if d ~= "" then for _, s in ipairs(wrapText(d, 48)) do addLine(lines, T(s, DESCCOL)) end end
  local kindLower = id:lower()
  addLine(lines, T("Placed in this world: " .. stationBuiltCount(kindLower), VALCOL))
  if id == "FURNACE" then
    addLine(lines, T("", VALCOL))
    addLine(lines, T("Counts as lit when real fire, plasma, or anything hotter than 600K sits in its coal chamber - light the coal bed with the torch (slot 4). It slow-burns the coal (1/20th speed) so a full load lasts a long time.", DESCCOL))
  end
  addLine(lines, T("", VALCOL)); addLine(lines, T("CRAFTING", HEADCOL))
  local found = false
  for _, rc in ipairs(R.RECIPES or {}) do if rc.out == id then found = true; addLine(lines, needSeg(rc.need)) end end
  if not found then addLine(lines, T("(no recipe found)", DIMCOL)) end
  stationUsers(kindLower, lines)
  return lines
end
-- how many of this kit are actually standing in the world right now. Machine tables key on a short "kind"
-- string rather than the item code (BOILER -> "boiler", O2GENKIT -> "o2gen"), so strip the KIT suffix and
-- match case-insensitively across both machine registries. Returns nil when nothing is placed AND the kind
-- was never seen, so the page can stay quiet rather than asserting a confident "0".
local function placedCount(id)
  local kind = id:lower():gsub("kit$", "")
  local n, seen = 0, false
  for _, tbl in ipairs({ R.machines, R.machines2, R.stations }) do
    for _, m in ipairs(tbl or {}) do
      if m.kind then
        seen = true
        if m.kind == kind or m.kind == id:lower() then n = n + 1 end
      end
    end
  end
  return n, seen
end
local function pageItemCode(id, catId)
  local lines = {}
  addLine(lines, { T(R.nice(id), TITLECOL), T("  [" .. id .. "]", DIMCOL) })
  local d = R.descOf(id)
  if d ~= "" then for _, s in ipairs(wrapText(d, 48)) do addLine(lines, T(s, DESCCOL)) end end
  addLine(lines, T("You have: " .. R.inv(id), VALCOL))

  -- CRAFTING: station, cost, yield, and whether that station actually exists in this world yet
  addLine(lines, T("", VALCOL)); addLine(lines, T("CRAFTING", HEADCOL))
  local rc = recipeOf(id)
  if rc then
    local stKey = rc.st or "hand"
    local seg = { T("At " .. (R.STATIONS[stKey] or stKey) .. ": ", VALCOL) }
    for _, s in ipairs(needSeg(rc.need or {})) do seg[#seg + 1] = s end
    addLine(lines, seg)
    if (rc.n or 1) > 1 then addLine(lines, T("Yields " .. rc.n .. " per craft.", VALCOL)) end
    if stKey ~= "hand" then
      local built = stationBuiltCount(stKey)
      addLine(lines, T(built > 0 and ("You have " .. built .. " " .. (R.STATIONS[stKey] or stKey) .. " placed.")
                                  or ("You have no " .. (R.STATIONS[stKey] or stKey) .. " placed yet."),
                       built > 0 and { 140, 255, 140 } or DIMCOL))
    end
  else
    addLine(lines, T("(no recipe found - the plugin that registers it may not be loaded)", DIMCOL))
  end

  -- IN THIS WORLD: live placed count, machines only
  if isMachineCat(catId) or catId == "vehicles" then
    local n, seen = placedCount(id)
    if seen then
      addLine(lines, T("", VALCOL)); addLine(lines, T("IN THIS WORLD", HEADCOL))
      addLine(lines, T("Placed: " .. n, n > 0 and { 140, 255, 140 } or DIMCOL))
      if n > 0 then addLine(lines, T("Right-click one in the world for its live inputs, outputs and next action.", DESCCOL)) end
    end
  end
  if catId == "wearables" then
    addLine(lines, T("", VALCOL)); addLine(lines, T("HOW IT WORKS", HEADCOL))
    addLine(lines, T("Passive - simply carrying it is enough. No slot to equip, nothing to select.", DESCCOL))
  end
  -- v1.15.108 fixes (survival lane) with no guide-visible desc change of their own - noted by hand here
  -- per DEVELOPMENT.md rule 6, since the underlying desc text lives in a file this wave doesn't route through guide.lua.
  if id == "OXYTANK" then
    addLine(lines, T("", VALCOL)); addLine(lines, T("HOW IT WORKS", HEADCOL))
    addLine(lines, T("Refills all the way to full (100) whenever there's genuine breathable OXYG in your breath radius - it no longer stalls part-way.", DESCCOL))
  elseif id == "VENTFANKIT" then
    addLine(lines, T("", VALCOL)); addLine(lines, T("HOW IT WORKS", HEADCOL))
    addLine(lines, T("Actually destroys the CO2/SMKE it pulls in now, not just nudges it along its duct - a vent fan built before this fix looked like it worked and did nothing.", DESCCOL))
  end

  usedInLines(id, lines)   -- shared section: every recipe that consumes this code
  return lines
end
local function pageAccessory(id)
  local a = R.ACCS[id]; local lines = {}
  addLine(lines, T(a.name, TITLECOL))
  for _, s in ipairs(wrapText(a.desc, 48)) do addLine(lines, T(s, DESCCOL)) end
  addLine(lines, T("", VALCOL)); addLine(lines, T("Tier " .. a.tier, VALCOL))
  local owned = R.accOwned and R.accOwned[id]
  addLine(lines, T("Owned: " .. (owned and "yes" or "no"), owned and { 140, 255, 140 } or DIMCOL))
  if owned then addLine(lines, T("Equipped: " .. (R.accOn(id) and "yes" or "no"), R.accOn(id) and { 140, 255, 140 } or DIMCOL)) end
  addLine(lines, T("", VALCOL))
  addLine(lines, T("Found in cave chests - deeper chests weight toward higher-tier accessories. Finding a duplicate gives 5 Gold instead.", DESCCOL))
  return lines
end
local function pageCreature(id)
  local c = CREATURES[id]; local lines = {}
  addLine(lines, T(c.name, TITLECOL))
  for _, s in ipairs(wrapText(c.behavior, 48)) do addLine(lines, T(s, DESCCOL)) end
  addLine(lines, T("", VALCOL))
  addLine(lines, T(string.format("HP %d   Contact damage %d   Size %dx%d   Speed %.2f", c.hp, c.dmg, c.w, c.h, c.speed), VALCOL))
  local n = liveCount(id)
  if n then addLine(lines, T("Currently alive in this world: " .. n, { 140, 255, 140 }))
  else addLine(lines, T("(enemies.lua not loaded this session - no live count)", DIMCOL)) end
  return lines
end
local function pageBiome(id)
  local b = BIOMES[id]; local lines = {}
  addLine(lines, T(b.label, TITLECOL))
  for _, s in ipairs(wrapText(b.desc, 48)) do addLine(lines, T(s, DESCCOL)) end
  addLine(lines, T("", VALCOL))
  addLine(lines, { T("Surface cover: ", LABELCOL), LK(R.nice(b.grass), classify(b.grass), b.grass) })
  addLine(lines, { T("Subsoil: ", LABELCOL), LK(R.nice(b.soil), classify(b.soil), b.soil) })
  addLine(lines, T("Trees: " .. b.trees, VALCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("EXAMPLE LOCATIONS", HEADCOL))
  local chunks = biomeChunks(id)
  if #chunks == 0 then addLine(lines, T("(none sampled nearby - biomes repeat every 612px, keep exploring)", DIMCOL))
  else
    local s = {}; for i = 1, math.min(5, #chunks) do s[#s + 1] = (chunks[i] * 612) .. "-" .. (chunks[i] * 612 + 612) end
    addLine(lines, T("world x ~ " .. table.concat(s, ", "), VALCOL))
  end
  return lines
end
local function pageStructure(id)
  local lines, d = {}, nil
  for _, pool in pairs(R.structDefs or {}) do
    for _, def in ipairs(pool) do if def.id == id then d = def end end
  end
  if not d then addLine(lines, T("(structure library not loaded this session)", DIMCOL)); return lines end
  addLine(lines, T((d.id:gsub("_", " ")), TITLECOL))
  for _, s in ipairs(wrapText(d.description, 48)) do addLine(lines, T(s, DESCCOL)) end
  addLine(lines, T("", VALCOL))
  local sc = d._sc or 1
  addLine(lines, { T("Category: ", LABELCOL), T(d.category, VALCOL) })
  addLine(lines, { T("Grid: ", LABELCOL), T(d.width .. "x" .. d.height .. " cells at " .. sc .. "px/cell", VALCOL) })
  -- Sizes are stated in WORLD PIXELS against the real player box, because grid cells hid exactly
  -- this: 15x17 "px" was 15x17 CELLS, and the cabin that read as fine on paper was unenterable.
  addLine(lines, { T("World size: ", LABELCOL),
                   T(d.width * sc .. "x" .. d.height * sc .. "px  (you are 4x10px)", VALCOL) })
  addLine(lines, { T("Biomes: ", LABELCOL), T(table.concat(d.biomes or {}, ", "), VALCOL) })
  if d.depth_band then
    addLine(lines, { T("Depth band: ", LABELCOL), T(d.depth_band.min .. " to " .. d.depth_band.max .. "px", VALCOL) })
  end
  addLine(lines, { T("Rarity: ", LABELCOL), T(tostring(d.rarity or "?"), VALCOL) })
  addLine(lines, T("", VALCOL)); addLine(lines, T("DOORS", HEADCOL))
  local nd = 0
  for _, o in ipairs(d.objects or {}) do
    if o.kind == "door" then
      nd = nd + 1
      addLine(lines, T(("%d) opening %dx%dpx  %s"):format(nd, (o.w or 1) * sc, (o.h or 1) * sc,
        o.pad_gx and "- has a control pad" or "- no pad, inert until you wire one"), VALCOL))
    end
  end
  if nd == 0 then addLine(lines, T("none - open terrain, not a sealed building", DIMCOL))
  else
    addLine(lines, T("A worldgen door is a REAL door machine, not a hole in a wall.", DESCCOL))
    addLine(lines, T("Spark its pad from a powered grid and the slab lifts; let the", DESCCOL))
    addLine(lines, T("spark fade and it drops back and seals the opening.", DESCCOL))
  end
  addLine(lines, T("", VALCOL)); addLine(lines, T("IN THIS WORLD", HEADCOL))
  local live = 0
  for _, m in ipairs(R.machines or {}) do if m.src then live = live + 1 end end
  addLine(lines, T("worldgen machines instantiated so far: " .. live, live > 0 and { 140, 255, 140 } or DIMCOL))
  addLine(lines, T("(counts every structure you have explored, not just this one -", DESCCOL))
  addLine(lines, T("they are created the first time worldgen accepts a placement)", DESCCOL))
  return lines
end
local function pageControl(id)
  local c = CONTROLS[id]; local lines = {}
  addLine(lines, T(c.label, TITLECOL))
  for _, l in ipairs(c.lines) do addLine(lines, T(l, VALCOL)) end
  return lines
end
local function pageSubmit()
  local lines = {}
  addLine(lines, T("Submit to PhoenixFire808", TITLECOL))
  for _, s in ipairs(wrapText("Found a good build, a bug, or an idea? Send it in - PhoenixFire808 reviews every submission personally, and the best ones get built into the game.", 48)) do addLine(lines, T(s, DESCCOL)) end
  addLine(lines, T("", VALCOL)); addLine(lines, T("THE FAST WAY", HEADCOL))
  addLine(lines, T("1. Press Y anywhere in the world (or click the flag icon by your hotbar).", VALCOL))
  addLine(lines, T("2. Drag a box around what you want to show, and release.", VALCOL))
  addLine(lines, T("3. Type a short description.", VALCOL))
  addLine(lines, T("4. Pick a category and click SUBMIT (or press Enter). A few seconds, done.", VALCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("NO BUILD TO SHOW?", HEADCOL))
  addLine(lines, T("Press Y, then Enter with no drag - that's a quick bug report or", VALCOL))
  addLine(lines, T("suggestion with no region needed.", VALCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("CATEGORIES", HEADCOL))
  addLine(lines, T("machine, plant, cave, terrain, building, item, bug, suggestion, other", VALCOL))
  addLine(lines, T("(only bug and suggestion can skip the drag)", DIMCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("ALWAYS THERE", HEADCOL))
  addLine(lines, T("A small flag icon sits just right of your hotbar, always on screen - click it", VALCOL))
  addLine(lines, T("any time to start a submission, same as pressing Y. Once you've sent one, a", VALCOL))
  addLine(lines, T("small link above it opens everything you've submitted this session.", VALCOL))
  return lines
end
-- Design doc's own T0-T6 tier ladder (knowledge/design-material-progression.md S3), mirrored here as
-- flavour text only - same "small static mirror" pattern as CONTROLS/CREATURES/BIOMES above (the tier
-- NAMES and one-line "why" are prose, not live data). Whether each row is REACHED is computed live below
-- from R.stations placed counts and R.tech.reactor, never hand-set.
local TIER_LADDER = {
  { id = "T0", name = "Hand", verb = "GATHER",
    why = "Chop, dig and forage with nothing built yet." },
  { id = "T1", name = "Workbench", station = "workbench", verb = "WIRE",
    why = "Assemble kits and basic circuits from wood and ore." },
  { id = "T2", name = "Furnace + Anvil", station = "anvil", station2 = "furnace", verb = "SMELT & BLAST",
    why = "Refine ore into bars and steel, and demolish terrain on purpose." },
  { id = "T3", name = "Research Bench", station = "research", verb = "SYNTHESIZE & SENSE",
    why = "Semiconductors, sensors and automation triggers." },
  { id = "T4", name = "Advanced Lab", station = "advlab", verb = "REFINE EXOTIC MATTER",
    why = "Cryogenics and vacuum-safe exotic-matter handling." },
  { id = "T5", name = "Reactor Online", tech = "reactor", verb = "TRANSMUTE",
    why = "Breed and harvest true nuclear fuel-cycle byproducts." },
  { id = "T6", name = "Post-Completion", tech = "reactor", verb = "WIELD EXOTIC PHYSICS",
    why = "Pure sandbox reward - never required to finish the game." },
}
local function tierReached(tier)
  if tier.tech then return R.tech and R.tech[tier.tech] == true end
  if not tier.station then return true end
  return stationBuiltCount(tier.station) > 0 and (not tier.station2 or stationBuiltCount(tier.station2) > 0)
end
local function pageProgression()
  local lines = {}
  addLine(lines, T("Your Progression", TITLECOL))
  for _, s in ipairs(wrapText("Where you actually are on the design doc's own tier ladder, and what to build next.", 48)) do addLine(lines, T(s, DESCCOL)) end
  addLine(lines, T("", VALCOL))
  addLine(lines, { T("Mining power now: ", LABELCOL), T(tostring(R.TOOLS.pick.power) .. "  (" .. R.TOOLS.pick.name .. ")", VALCOL) })
  addLine(lines, { T("Peak power ever generated: ", LABELCOL), T(math.floor(R.tech and R.tech.peakW or 0) .. "W", VALCOL) })
  addLine(lines, T("", VALCOL)); addLine(lines, T("TIER LADDER", HEADCOL))
  -- Longest CONTIGUOUS reached prefix, not "last tier reached anywhere" - sandbox forces
  -- R.tech.reactor true with zero stations physically placed, which would otherwise let T5/T6
  -- (both tech="reactor") read as "current" while T1 (Workbench) is still unbuilt. Stopping at
  -- the first gap is also the more honest reading in real survival play: a furnace-tier bypass
  -- recipe lets ZIRC/GRPH skip Research/Advanced Lab, so tech.reactor can go true before either
  -- station is ever placed - this page should say so, not silently skip ahead.
  local curIdx = 1
  for i, tier in ipairs(TIER_LADDER) do
    if tierReached(tier) then curIdx = i else break end
  end
  for i, tier in ipairs(TIER_LADDER) do
    local reached = tierReached(tier)
    local isCur = (i == curIdx)
    local mark = isCur and "-> " or (reached and "x  " or "   ")
    local col = isCur and { 140, 255, 140 } or (reached and VALCOL or DIMCOL)
    addLine(lines, T(mark .. tier.id .. "  " .. tier.name .. "  -  " .. tier.verb, col))
    for _, s in ipairs(wrapText(tier.why, 44)) do addLine(lines, T("      " .. s, DESCCOL)) end
  end
  addLine(lines, T("", VALCOL)); addLine(lines, T("NEXT STEP", HEADCOL))
  local nextTier = TIER_LADDER[curIdx + 1]
  if not nextTier then
    addLine(lines, T("You've reached every tier the design doc defines - T6 is pure sandbox reward from here.", VALCOL))
  else
    for _, s in ipairs(wrapText(nextTier.id .. ": " .. nextTier.name .. " - " .. nextTier.why, 48)) do addLine(lines, T(s, VALCOL)) end
    if nextTier.id == "T2" then
      addLine(lines, { T("Build: ", VALCOL), LK(R.STATIONS.furnace or "Furnace kit", "stations", "FURNACE"), T("  and  ", VALCOL), LK(R.STATIONS.anvil or "Anvil", "stations", "ANVIL") })
    elseif nextTier.station then
      local code = nextTier.station:upper()
      if R.ITEMS and R.ITEMS[code] then
        addLine(lines, { T("Build: ", VALCOL), LK(R.STATIONS[nextTier.station] or R.nice(code), "stations", code) })
      end
    elseif nextTier.tech == "reactor" then
      addLine(lines, T("Build: reach 100W of live grid generation, then build the Fission Reactor at the anvil.", VALCOL))
    end
  end
  addLine(lines, T("", VALCOL)); addLine(lines, T("TECH MILESTONES", HEADCOL))
  local t = R.tech or {}
  addLine(lines, T((t.unlock10 and "x  " or "   ") .. "10W generated - Electric Furnace + Battery Bank unlocked", t.unlock10 and { 140, 255, 140 } or DIMCOL))
  addLine(lines, T((t.unlock100 and "x  " or "   ") .. "100W generated - Crusher, Autocrafter, Capacitor, Turret, Drill + Reactor kit unlocked", t.unlock100 and { 140, 255, 140 } or DIMCOL))
  addLine(lines, T((t.reactor and "x  " or "   ") .. "Reactor online - Heavy Turret, RTG, Shield tier 4 unlocked", t.reactor and { 140, 255, 140 } or DIMCOL))
  return lines
end
local function buildPage(catId, id)
  if not id then return { { T("Nothing matches your search.", DIMCOL) } } end
  if catId == "progression" then return pageProgression() end
  if catId == "materials" or catId == "ores" or MAT_SECTION_CATS[catId] then return pageMaterialOrOre(id, catId) end
  if catId == "tools" then
    if id == "TORCH" then return pageSimpleTool("Torch") end
    if id == "BUCKET" then return pageSimpleTool("Bucket") end
    local kind, idx = id:match("^(%a+):(%d+)$"); idx = tonumber(idx)
    if kind == "PICK" then return pagePick(idx) end
    if kind == "SWORD" then return pageSword(idx) end
  end
  if catId == "stations" then return pageStation(id) end
  if isMachineCat(catId) or catId == "weapons" or catId == "terrain"
     or catId == "wearables" or catId == "vehicles" then return pageItemCode(id, catId) end
  if catId == "accessories" then return pageAccessory(id) end
  if catId == "creatures" then return pageCreature(id) end
  if catId == "biomes" then return pageBiome(id) end
  if catId == "structures" then return pageStructure(id) end
  if catId == "controls" then return pageControl(id) end
  if catId == "submit" then return pageSubmit() end
  return { { T("(no data)", DIMCOL) } }
end

-- ================================================================ navigation
local function navigate(catId, id, pushBack)
  if pushBack and G.cat and G.id then
    G.back[#G.back + 1] = { cat = G.cat, id = G.id }
    if #G.back > 40 then table.remove(G.back, 1) end
  end
  G.cat, G.id, G.pageScroll = catId, id, 0
end
local function popBack()
  local b = table.remove(G.back); if b then G.cat, G.id, G.pageScroll = b.cat, b.id, 0 end
end
-- TAKE: hands the item to the player via core's R.grantItem (sandbox: stocks 999 + selects a free hotbar
-- slot; outside sandbox: only works for materials already owned, and R.grantItem itself reports why not),
-- then closes the guide so the player immediately sees their hotbar/selection change.
local function takeItem(catId, id)
  if not isTakeable(catId, id) then return end
  if type(R.grantItem) ~= "function" then
    if R.say then R.say("grantItem is not available this session") end
    return
  end
  local ok, err = pcall(R.grantItem, id)
  if not ok and R.say then R.say("TAKE failed: " .. tostring(err)) end
  R.closeGuide()
end
-- public API so other plugins (the bag/E-menu) can open/close the guide cleanly:
--   R.openGuide()                       - open, resuming wherever it was left (or the guide's own
--                                          first category - CATS[1] - if never opened this session)
--   R.openGuide("weapons")               - open and jump to a category (its first entry)
--   R.openGuide({ cat = "materials", id = "GOO" }) - open and jump to one specific entry
--   R.closeGuide()                       - close and reset transient UI state (search focus, drag)
-- the caller is responsible for closing its own panel first (e.g. ui.lua closes its bag before calling this)
-- "or 'materials'" below is a last-resort fallback only (visibleCats() is never empty in practice) -
-- the REAL default is CATS[1], not a hardcoded string, so putting "submit" at CATS[1] (PhoenixFire808's
-- 3x-escalated prominence ask) makes it the actual first thing shown on a never-opened guide, not just
-- first in a list you'd still have to click into.
function R.openGuide(entryOrNil)
  R.guideOpen = true
  G.searchFocused = false
  G.drag, G.dragMeta = nil, nil
  if type(entryOrNil) == "table" then
    local catId = entryOrNil.cat or G.cat or (visibleCats()[1] and visibleCats()[1].id) or "materials"
    G.search = ""
    navigate(catId, entryOrNil.id, false)
  elseif type(entryOrNil) == "string" then
    G.search = ""
    local es = cachedEntries(entryOrNil)
    navigate(entryOrNil, es[1] and es[1].id, false)
  elseif not G.cat then
    local firstCat = (visibleCats()[1] and visibleCats()[1].id) or "materials"
    local es = cachedEntries(firstCat)
    navigate(firstCat, es[1] and es[1].id, false)
  end
end
function R.closeGuide()
  R.guideOpen = false
  G.searchFocused = false
  G.drag, G.dragMeta = nil, nil
end
local function entryLabel(catId, id)
  if not catId or not id then return "" end
  for _, e in ipairs(cachedEntries(catId)) do if e.id == id then return e.label end end
  return tostring(id)
end

-- ================================================================ scrollbars (click-to-seek + drag; see tick hook below)
local function drawScrollbar(x, y, h, total, vis, scroll, dragKey)
  if total <= vis then return nil end
  local maxScroll = math.max(0, total - vis)
  local thumbH = math.max(10, math.floor(h * vis / total))
  local avail = h - thumbH
  local thumbY = y + ((maxScroll > 0) and math.floor(avail * scroll / maxScroll) or 0)
  graphics.fillRect(x, y, SBW, h, 22, 22, 34, 220); graphics.drawRect(x, y, SBW, h, 60, 60, 80, 200)
  local dragging = (G.drag == dragKey)
  graphics.fillRect(x, thumbY, SBW, thumbH, dragging and 255 or 150, dragging and 220 or 150, dragging and 80 or 175, 255)
  return { track = { x, y, x + SBW, y + h }, thumbH = thumbH, maxScroll = maxScroll }
end
local function scrollbarSeek(bar, my)
  local avail = (bar.track[4] - bar.track[2]) - bar.thumbH
  local rel = my - bar.track[2] - bar.thumbH / 2
  local frac = (avail > 0) and (rel / avail) or 0
  frac = math.max(0, math.min(1, frac))
  return math.floor(frac * bar.maxScroll + 0.5)
end

-- ================================================================ input
hook(R.hooks.key, function(k, shift, ctrl, alt)
  if not R.guideOpen then
    if k == "l" then R.openGuide(); return true end
    return
  end
  if k == "1073741899" then G.pageScroll = math.max(0, G.pageScroll - 10); return true end  -- Page Up
  if k == "1073741902" then G.pageScroll = G.pageScroll + 10; return true end               -- Page Down
  if G.searchFocused then
    if k == "escape" or k == "13" or k == "10" then G.searchFocused = false; return true end
    if k == "8" then G.search = G.search:sub(1, -2)
    elseif k == "space" then G.search = G.search .. " "
    elseif type(k) == "string" and #k == 1 and k:match("[%a%d]") then G.search = G.search .. k end
    local es = getEntries(); local found = false
    for _, e in ipairs(es) do if e.id == G.id then found = true; break end end
    if not found then G.id = es[1] and es[1].id; G.pageScroll = 0 end
    return true
  end
  if k == "l" or k == "escape" then R.closeGuide(); return true end
  return true
end)
hook(R.hooks.mousedown, function(x, y, button)
  if not R.guideOpen then return end
  local B = G.btn or {}
  -- Accessibility (PhoenixFire808, direct: "I hate having to push buttons on my keyboard. My
  -- hand is broken."): closing this panel used to be key-only (L or Esc, both checked in the
  -- key hook above) with no mouse path at all - every other navigation action here already had
  -- one (categories/entries/links are clickable rows, both scrollbars drag, wheel scrolls), this
  -- was the one real gap. B.close is a plain on-screen X, drawn next to the ? help button.
  if hitRect(B.close, x, y) then R.closeGuide(); return true end
  if hitRect(B.help, x, y) then G.help = not G.help; return true end
  -- Search-clear (B.searchClear): a one-click way to empty the search box instead of holding
  -- Backspace - checked before B.search itself so a click on the X inside the box clears rather
  -- than just refocusing it.
  if B.searchClear and hitRect(B.searchClear, x, y) then G.search = ""; G.searchFocused = true; return true end
  if hitRect(B.search, x, y) then G.searchFocused = true; return true end
  if hitRect(B.back, x, y) and #G.back > 0 then popBack(); return true end
  if hitRect(B.take, x, y) then takeItem(G.cat, G.id); return true end
  if G.catBar and hitRect(G.catBar.track, x, y) then G.catScroll = scrollbarSeek(G.catBar, y); G.drag, G.dragMeta = "cat", G.catBar; return true end
  if G.listBar and hitRect(G.listBar.track, x, y) then G.listScroll = scrollbarSeek(G.listBar, y); G.drag, G.dragMeta = "list", G.listBar; return true end
  if G.pageBar and hitRect(G.pageBar.track, x, y) then G.pageScroll = scrollbarSeek(G.pageBar, y); G.drag, G.dragMeta = "page", G.pageBar; return true end
  for _, r in ipairs(G.catRects or {}) do
    if hitRect(r, x, y) and r.id then
      G.search = ""; G.searchFocused = false; G.listScroll = 0
      local es = cachedEntries(r.id)
      if es[1] then navigate(r.id, es[1].id, false) else G.cat = r.id; G.id = nil; G.pageScroll = 0 end
      return true
    end
  end
  for _, r in ipairs(G.listRects or {}) do
    if hitRect(r, x, y) then
      local now = R.frame or 0
      local isDouble = (G.lastClickCat == r.cat and G.lastClickId == r.id and (now - (G.lastClickT or -999)) < 20)
      navigate(r.cat, r.id, true)
      if isDouble and isTakeable(r.cat, r.id) then
        takeItem(r.cat, r.id); G.lastClickCat, G.lastClickId, G.lastClickT = nil, nil, nil
      else
        G.lastClickCat, G.lastClickId, G.lastClickT = r.cat, r.id, now
      end
      return true
    end
  end
  for _, r in ipairs(G.links or {}) do if hitRect(r, x, y) then navigate(r.cat, r.id, true); return true end end
  G.searchFocused = false
  return true
end)
hook(R.hooks.mouseup, function() G.drag, G.dragMeta = nil, nil end)
hook(R.hooks.tick, function()
  if R.guideOpen then R.uiPanelOpen = true end   -- OR'd every frame; ui.lua sets its own state before this runs (loads earlier)
  if R.guideOpen and G.drag and G.dragMeta then
    local v = scrollbarSeek(G.dragMeta, R.mouse.y)
    if G.drag == "list" then G.listScroll = v elseif G.drag == "page" then G.pageScroll = v elseif G.drag == "cat" then G.catScroll = v end
  end
end)
if R.hooks.wheel then   -- self-wires in automatically once core exposes a wheel hook (checked at (re)load time)
  hook(R.hooks.wheel, function(x, y, d)
    if not R.guideOpen then return end
    if x >= COL3X and x < COL3X + COL3W then G.pageScroll = math.max(0, G.pageScroll - d)
    elseif x >= COL2X and x < COL2X + COL2W then G.listScroll = math.max(0, G.listScroll - d)
    elseif x >= COL1X and x < COL1X + COL1W then G.catScroll = math.max(0, G.catScroll - d) end
    return true   -- consume regardless of column so wheel never leaks through to hotbar-select while the panel is open
  end)
end
hook(R.hooks.newworld, function()
  R.closeGuide(); G.locCache = {}; G.biomeCache = nil; G.back = {}
end)

-- ================================================================ draw
hook(R.hooks.drawHUD, function()
  if not R.guideOpen then return end
  R.uiPanelOpen = true
  G.links, G.listRects, G.catRects, G.btn = {}, {}, {}, {}
  local B = G.btn
  local mx, my = R.mouse.x, R.mouse.y
  graphics.fillRect(GX, GY, GW, GH, 12, 14, 28, 248)
  graphics.drawRect(GX, GY, GW, GH, 255, 220, 80, 255)
  graphics.fillRect(GX, GY, GW, 15, 40, 44, 80, 255)
  graphics.drawText(GX + 5, GY + 4, "GUIDE / DATABASE", 255, 220, 80, 255)
  graphics.drawText(GX + 118, GY + 4, "materials, recipes & mechanics - click X, L or Esc closes", 170, 170, 185, 255)
  -- Close (X), mouse-reachable equivalent of the L/Esc keys - see the accessibility comment on
  -- B.close's click handler above. Drawn left of ? so the two read as one small button cluster.
  B.close = { GX + GW - 30, GY + 2, GX + GW - 18, GY + 13 }
  local closeHover = hitRect(B.close, mx, my)
  graphics.fillRect(B.close[1], B.close[2], 12, 11, closeHover and 150 or 60, closeHover and 60 or 40, closeHover and 60 or 44, 255)
  graphics.drawText(B.close[1] + 3, B.close[2] + 2, "X", 255, 210, 210, 255)
  B.help = { GX + GW - 15, GY + 2, GX + GW - 3, GY + 13 }
  local helpHover = hitRect(B.help, mx, my)
  local hc = (G.help or helpHover)
  graphics.fillRect(B.help[1], B.help[2], 12, 11, hc and 90 or 40, hc and 90 or 44, hc and 60 or 80, 255)
  graphics.drawText(B.help[1] + 3, B.help[2] + 2, "?", 255, 230, 140, 255)
  if G.help then
    graphics.fillRect(GX + GW - 214, GY + 16, 210, 76, 0, 0, 0, 235); graphics.drawRect(GX + GW - 214, GY + 16, 210, 76, 120, 124, 170, 255)
    graphics.drawText(GX + GW - 210, GY + 20, "Click a category, then an entry.", 220, 220, 230, 255)
    graphics.drawText(GX + GW - 210, GY + 32, "Click any highlighted word to jump", 220, 220, 230, 255)
    graphics.drawText(GX + GW - 210, GY + 44, "there - BACK undoes it. Drag a bar,", 220, 220, 230, 255)
    graphics.drawText(GX + GW - 210, GY + 56, "or PgUp/PgDn, to scroll the page.", 220, 220, 230, 255)
    graphics.drawText(GX + GW - 210, GY + 68, "Sandbox mode: TAKE puts any", 200, 255, 200, 255)
    graphics.drawText(GX + GW - 210, GY + 78, "material in your hotbar.", 200, 255, 200, 255)
  end

  -- COL1: categories (click + hover highlight), scrollable now that the material-browser sections
  -- (SC_* menu-section split, see MAT_SECTION_CATS above) pushed the category count past one screen.
  local cats = visibleCats()
  local catAreaW = COL1W - SBW - 2
  local catVisRows = math.max(1, math.floor((BOT - BY) / 14))
  G.catScroll = math.max(0, math.min(G.catScroll, math.max(0, #cats - catVisRows)))
  for i = 1, catVisRows do
    local cinfo = cats[i + G.catScroll]
    if cinfo then
      local y = BY + (i - 1) * 14
      local r = { COL1X, y, COL1X + catAreaW, y + 13, id = cinfo.id }   -- id travels on the rect: the click handler
      local sel = (G.cat == cinfo.id)
      local hov = (not sel) and hitRect(r, mx, my)
      local bg = sel and { 60, 64, 100 } or (hov and { 42, 46, 74 } or { 20, 22, 34 })
      graphics.fillRect(r[1], r[2], catAreaW, 13, bg[1], bg[2], bg[3], 255)
      graphics.drawText(COL1X + 3, y + 3, cinfo.label, sel and 255 or (hov and 235 or 200), sel and 220 or (hov and 225 or 200), sel and 80 or (hov and 150 or 210), 255)
      G.catRects[#G.catRects + 1] = r
    end
  end
  G.catBar = drawScrollbar(COL1X + catAreaW + 2, BY, BOT - BY, #cats, catVisRows, G.catScroll, "cat")

  -- COL2: search box (blinking cursor while focused) + entry list + drag scrollbar
  B.search = { COL2X, BY, COL2X + COL2W, BY + 12 }
  graphics.fillRect(COL2X, BY, COL2W, 12, G.searchFocused and 40 or 24, G.searchFocused and 44 or 26, G.searchFocused and 70 or 40, 255)
  graphics.drawRect(COL2X, BY, COL2W, 12, G.searchFocused and 255 or 100, G.searchFocused and 220 or 100, G.searchFocused and 80 or 110, 255)
  local cursor = (G.searchFocused and (math.floor((R.frame or 0) / 20) % 2 == 0)) and "|" or ""
  local shown = (G.search ~= "" and G.search) or ((not G.searchFocused) and "search..." or "")
  graphics.drawText(COL2X + 3, BY + 2, shown .. cursor, G.search ~= "" and 230 or 140, G.search ~= "" and 230 or 140, 150, 255)
  -- Search-clear X: filtering by category/list clicks never needs the keyboard at all, but typing
  -- a search query does (there is no mouse-only text entry) - this at least makes UNDOING that
  -- typing a single click instead of holding Backspace, same accessibility ask as B.close above.
  if G.search ~= "" then
    B.searchClear = { COL2X + COL2W - 10, BY, COL2X + COL2W, BY + 12 }
    local clrHover = hitRect(B.searchClear, mx, my)
    graphics.drawText(B.searchClear[1] + 2, BY + 2, "x", clrHover and 255 or 200, clrHover and 160 or 140, clrHover and 160 or 140, 255)
  else
    B.searchClear = nil
  end

  local entries = getEntries()
  local listY0 = BY + 15
  local rowH = 12
  local listAreaW = COL2W - SBW - 2
  -- true for every category whose entries are real R.colourOf()-resolvable codes (materials/ores/
  -- SC_* material tabs/machines/weapons/terrain/wearables/vehicles/stations) -- the same code-shaped
  -- set isTakeable() recognises, minus its nil-id early-out (which would always fail here since we're
  -- asking about the CATEGORY, not one row's id).
  local iconable = G.cat ~= nil and (MAT_SECTION_CATS[G.cat] or isMachineCat(G.cat) or G.cat == "materials" or G.cat == "ores"
    or G.cat == "weapons" or G.cat == "terrain" or G.cat == "wearables" or G.cat == "vehicles" or G.cat == "stations")
  local textX0 = iconable and (COL2X + 12) or (COL2X + 2)
  local visRows = math.max(1, math.floor((BOT - listY0) / rowH))
  G.listScroll = math.max(0, math.min(G.listScroll, math.max(0, #entries - visRows)))
  for i = 1, visRows do
    local e = entries[i + G.listScroll]
    if e then
      local y = listY0 + (i - 1) * rowH
      local r = { COL2X, y, COL2X + listAreaW, y + rowH }
      local sel = (e.id == G.id)
      local hov = (not sel) and hitRect(r, mx, my)
      if sel then graphics.fillRect(COL2X, y, listAreaW, rowH, 55, 58, 95, 255)
      elseif hov then graphics.fillRect(COL2X, y, listAreaW, rowH, 32, 34, 54, 255) end
      -- e.obtainable is only set for material/ore entries (buildEntries, precomputed from the cached
      -- acquisition index - never a per-row recompute); nil for every other category, which draws as before.
      local label = e.label:sub(1, iconable and 19 or 22)
      local r_, g_, b_
      if e.obtainable == false then
        label = label .. " (?)"
        r_, g_, b_ = sel and 255 or (hov and 235 or 200), sel and 150 or (hov and 130 or 110), sel and 100 or (hov and 90 or 80)
      else
        r_, g_, b_ = sel and 255 or (hov and 230 or 205), sel and 220 or (hov and 225 or 205), sel and 120 or (hov and 160 or 215)
      end
      if iconable and e.id then drawMatIcon(e.id, COL2X + 1, y + 1, 9, e.obtainable == false and 130 or 255) end
      graphics.drawText(textX0, y + 1, label, r_, g_, b_, 255)
      G.listRects[#G.listRects + 1] = { COL2X, y, COL2X + listAreaW, y + rowH, cat = G.cat, id = e.id }
    end
  end
  if #entries == 0 then graphics.drawText(COL2X + 2, listY0 + 1, "(no matches)", DIMCOL[1], DIMCOL[2], DIMCOL[3], 255) end
  G.listBar = drawScrollbar(COL2X + listAreaW + 2, listY0, BOT - listY0, #entries, visRows, G.listScroll, "list")

  -- COL3: BACK button (always visible, dimmed when empty) + breadcrumb, then the page + drag scrollbar
  B.back = { COL3X, BY, COL3X + 46, BY + 12 }
  local backEnabled = #G.back > 0
  local backHover = backEnabled and hitRect(B.back, mx, my)
  graphics.fillRect(B.back[1], B.back[2], 46, 12, backHover and 80 or 50, backHover and 60 or 40, backHover and 30 or 30, backEnabled and 255 or 110)
  graphics.drawText(B.back[1] + 3, B.back[2] + 2, "< BACK", backEnabled and 255 or 100, backEnabled and 210 or 100, backEnabled and 140 or 100, 255)
  local takeable = isTakeable(G.cat, G.id)
  local takeHover = false
  if takeable then
    B.take = { COL3X + COL3W - 44, BY, COL3X + COL3W, BY + 12 }
    takeHover = hitRect(B.take, mx, my)
    graphics.fillRect(B.take[1], B.take[2], 44, 12, takeHover and 70 or 35, takeHover and 190 or 130, takeHover and 90 or 60, 255)
    graphics.drawRect(B.take[1], B.take[2], 44, 12, 150, 255, 150, 255)
    graphics.drawText(B.take[1] + 8, B.take[2] + 2, "TAKE", 235, 255, 235, 255)
  else
    B.take = nil
  end
  local crumbCat = nil; for _, c in ipairs(CATS) do if c.id == G.cat then crumbCat = c.label end end
  local crumbMax = math.max(1, math.floor((COL3W - 54 - (takeable and 48 or 0)) / 6))
  if takeHover then
    -- swap the breadcrumb slot for a contextual hint while the TAKE button is hovered - Sandbox mode:
    -- TAKE puts any material in your hotbar; outside sandbox it only works for materials you already own.
    local hint = R.sandbox and "Sandbox mode: TAKE puts any material in your hotbar (999, free slot)" or "TAKE: only works for materials you already own"
    graphics.drawText(COL3X + 50, BY + 2, hint:sub(1, crumbMax), 235, 255, 200, 255)
  else
    local crumb = (crumbCat or "") .. (G.id and (" > " .. entryLabel(G.cat, G.id)) or "")
    graphics.drawText(COL3X + 50, BY + 2, crumb:sub(1, crumbMax), 180, 180, 195, 255)
  end

  local ok, pageLines = pcall(buildPage, G.cat, G.id)
  if not ok then pageLines = { { T("(error building this page: " .. tostring(pageLines) .. ")", { 255, 120, 120 }) } } end
  local pageY0 = BY + 15
  local lineH = 12
  local pageAreaW = COL3W - SBW - 2
  -- Larger detail-page icon (PhoenixFire808: "everything has to look super good", item 2 of this
  -- lane's brief -- "a larger icon on detail pages"). Same code-shaped category set as the entry
  -- list's own `iconable` check above. Every page* builder's first line is always the title
  -- (`R.nice(id)` + dim `[CODE]`, verified by reading pageMaterialOrOre/pageItemCode/pageStation) --
  -- drawn here beside the icon instead of through the generic per-line loop below, which then
  -- starts from line 2 (skipFirst) so nothing double-draws.
  local iconCode = nil
  if G.id and G.cat and (MAT_SECTION_CATS[G.cat] or isMachineCat(G.cat) or G.cat == "materials" or G.cat == "ores"
     or G.cat == "weapons" or G.cat == "terrain" or G.cat == "wearables" or G.cat == "vehicles"
     or (G.cat == "stations" and G.id ~= "hand")) then
    iconCode = G.id
  end
  local skipFirst = 0
  if iconCode then
    local ICONSZ = 26
    drawMatIcon(iconCode, COL3X, pageY0, ICONSZ)
    local titleLine = pageLines[1]
    if titleLine then
      local cx = COL3X + ICONSZ + 6
      local ty = pageY0 + math.floor((ICONSZ - 9) / 2)
      for _, seg in ipairs(titleLine) do
        local w = #seg.t * 6
        local col = seg.c or VALCOL
        graphics.drawText(cx, ty, seg.t, col[1], col[2], col[3], 255)
        cx = cx + w
      end
      skipFirst = 1
    end
    pageY0 = pageY0 + ICONSZ + 4
  end
  local visLines = math.max(1, math.floor((BOT - pageY0) / lineH))
  G.pageScroll = math.max(0, math.min(G.pageScroll, math.max(0, #pageLines - skipFirst - visLines)))
  for i = 1, visLines do
    local ln = pageLines[i + G.pageScroll + skipFirst]
    if ln then
      local y = pageY0 + (i - 1) * lineH
      local cx = COL3X
      for _, seg in ipairs(ln) do
        local w = #seg.t * 6
        local col = seg.c or VALCOL
        local hoverLink = seg.link and hitRect({ cx, y - 1, cx + w, y + 10 }, mx, my)
        if hoverLink then col = { 210, 245, 255 } end
        graphics.drawText(cx, y, seg.t, col[1], col[2], col[3], 255)
        if hoverLink then graphics.drawLine(cx, y + 9, cx + w, y + 9, col[1], col[2], col[3], 220) end
        if seg.link then G.links[#G.links + 1] = { cx, y - 1, cx + w, y + 10, cat = seg.link.cat, id = seg.link.id } end
        cx = cx + w
      end
    end
  end
  G.pageBar = drawScrollbar(COL3X + pageAreaW + 2, pageY0, BOT - pageY0, #pageLines - skipFirst, visLines, G.pageScroll, "page")
end)
