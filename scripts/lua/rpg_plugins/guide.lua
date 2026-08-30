-- RPG plugin: guide.lua - the in-game GUIDE / DATABASE. Key L opens/closes it.
-- Three columns: categories (left) -> searchable entry list (middle) -> generated entry page (right).
-- Pages are built live from R's real data (R.RECIPES/R.PICKS/R.SWORDS/R.ITEMS/R.ACCS/R.MINEABLE/R.HARD)
-- plus real TPT element facts via elem.property(). Clicking a highlighted word jumps to that entry
-- (back stack lets you return). Where another plugin doesn't expose a table (creature stats, weapon
-- cooldowns, biome soil types), this file keeps its own small static mirror instead - see the comments
-- next to each one. Owns exactly this file; never touches rpg.lua or another plugin.
local R = PBX.state.rpg
local TAG = "guide"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

-- ================================================================ persistent state (survives reloadPlugin)
local G = R.guide or {}
R.guide = G
G.search = G.search or ""
G.searchFocused = G.searchFocused or false
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

-- ================================================================ static mirrors of data other plugins keep local
-- (guide only reads rpg.lua-level shared tables; these lists are hand-copied from the plugin source since
-- items.lua/machines.lua/enemies.lua don't expose them on R - ask in the hub if that changes)
local WEAPON_CODES = { "MUSKET", "SHOTGUN", "GRENADE", "LIGHTGUN", "TPWAND", "FLAMETH", "WATERGUN", "ACIDGUN", "FREEZERAY", "LASERGUN", "DRILL", "JETPACK" }
local WEAPON_SET = {}; for _, k in ipairs(WEAPON_CODES) do WEAPON_SET[k] = true end
local MACHINE_CODES = { "BOILER", "TURBINE", "WIRECOIL", "LAMPKIT", "DOORKIT", "PUMPKIT", "CONVEYOR", "CRATE" }
local MACHINE_SET = {}; for _, k in ipairs(MACHINE_CODES) do MACHINE_SET[k] = true end
local MACHINE_KIND = { BOILER = "boiler", TURBINE = "turbine", DOORKIT = "door", PUMPKIT = "pump", CONVEYOR = "conveyor", CRATE = "crate" }
local STATION_CODES = { "WORKBENCH", "FURNACE", "ANVIL" }
local STATION_SET = {}; for _, k in ipairs(STATION_CODES) do STATION_SET[k] = true end
local ORE_CODES = { "COAL", "BCOL", "IRON", "CU", "GOLD", "DU", "URAN", "QRTZ", "DMND", "TTAN", "ZIRC", "LEAD" }
local ORE_SET = {}; for _, k in ipairs(ORE_CODES) do ORE_SET[k] = true end

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
  snow   = { label = "Snow / Tundra", grass = "ICE", soil = "ICE", trees = "~25% of surface columns",
             desc = "Ice and snow at the surface with an icy subsoil. Sparse, pine-like trees." },
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
            "T - toggle the smart cursor (auto-targets the nearest diggable block along your aim)" } },
  craft = { label = "Crafting stations", lines = { "by hand -> Workbench -> Furnace (light its coal with the torch) -> Anvil", "Open the bag (E) to see every recipe you can currently afford" } },
  items = { label = "Accessories & chests", lines = { "Chests hidden in caves hold accessories - see the Accessories tab", "X - Magic Mirror teleports you home (once owned)", "G - Grappling Hook (once owned)" } },
  other = { label = "Other keys", lines = { "K save   R respawn   N enemies on/off   M minimap   H HUD", "Esc - menu & controls card   F1 - debug overlay" } },
  uiext = { label = "UI panels (ui.lua)", lines = { "J - quest log", "C - controls card" } },
  guide = { label = "This guide (L)", lines = { "L or Esc - open / close this database", "Click a category, then an entry, then any highlighted word to jump to it",
            "'< back' undoes a jump; click the search box, then type to filter the list" } },
}
local CONTROL_ORDER = { "move", "tools", "blocks", "select", "view", "world", "craft", "items", "other", "uiext", "guide" }

local CATS = {
  { id = "materials", label = "Materials" },
  { id = "ores", label = "Ores & Depths" },
  { id = "tools", label = "Tools" },
  { id = "stations", label = "Stations & Processes" },
  { id = "machines", label = "Machines" },
  { id = "weapons", label = "Weapons & Gadgets" },
  { id = "accessories", label = "Accessories" },
  { id = "creatures", label = "Creatures" },
  { id = "biomes", label = "Biomes" },
  { id = "controls", label = "Controls" },
}
local NOSORT = { tools = true, stations = true, creatures = true, biomes = true, controls = true }

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
  if WEAPON_SET[code] then return "weapons" end
  if MACHINE_SET[code] then return "machines" end
  if STATION_SET[code] then return "stations" end
  if ORE_SET[code] then return "ores" end
  return "materials"
end
-- true when (catId, id) is a real inventory-able code R.grantItem can act on (a hotbar block-slot item,
-- not a tool/accessory/creature/biome/control which don't live in R.inventory)
local function isTakeable(catId, id)
  if not id then return false end
  if catId == "materials" or catId == "ores" or catId == "machines" or catId == "weapons" then return true end
  if catId == "stations" and id ~= "hand" then return true end
  return false
end

-- ================================================================ entry lists per category
local function collectMatCodes()
  local set = {}
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
  if catId == "materials" or catId == "ores" then
    local set = collectMatCodes()
    for k in pairs(set) do
      local isOre = ORE_SET[k] and true or false
      if (catId == "ores") == isOre and not STATION_SET[k] and not WEAPON_SET[k] and not MACHINE_SET[k] then
        if R.eid(k) or R.NAMES[k] then out[#out + 1] = { id = k, label = R.nice(k) } end
      end
    end
    if catId == "ores" then
      for _, k in ipairs(ORE_CODES) do
        local exists = false; for _, e in ipairs(out) do if e.id == k then exists = true end end
        if not exists and (R.eid(k) or R.MINEABLE[k]) then out[#out + 1] = { id = k, label = R.nice(k) } end
      end
    end
  elseif catId == "tools" then
    for i, t in ipairs(R.PICKS or {}) do out[#out + 1] = { id = "PICK:" .. i, label = t.name } end
    for i, t in ipairs(R.SWORDS or {}) do out[#out + 1] = { id = "SWORD:" .. i, label = t.name } end
    out[#out + 1] = { id = "TORCH", label = (R.TOOLS.torch and R.TOOLS.torch.name) or "torch" }
    out[#out + 1] = { id = "BUCKET", label = (R.TOOLS.bucket and R.TOOLS.bucket.name) or "bucket" }
  elseif catId == "stations" then
    out[#out + 1] = { id = "hand", label = "By hand" }
    for _, k in ipairs(STATION_CODES) do out[#out + 1] = { id = k, label = R.nice(k) } end
  elseif catId == "machines" then
    local seen = {}
    for _, k in ipairs(MACHINE_CODES) do if R.ITEMS[k] and not seen[k] then out[#out + 1] = { id = k, label = R.nice(k) }; seen[k] = true end end
    -- MACHINE_CODES above is a small hand-copied list that goes stale every time a
    -- plugin adds a new craftable kit -- exactly what happened to AIRLINEKIT/
    -- AIRPUMPKIT/ALGAETANK (real, craftable, just never added to this list). Any
    -- recipe output with a real R.ITEMS entry (raw materials never get one -- only
    -- placeable kits/structures do) that isn't already a station/weapon/ore shows up
    -- here automatically now, from any plugin, present or future.
    for _, rc in ipairs(R.RECIPES or {}) do
      local k = rc.out
      if k and R.ITEMS[k] and not seen[k] and not STATION_SET[k] and not WEAPON_SET[k] and not ORE_SET[k] then
        out[#out + 1] = { id = k, label = R.nice(k) }; seen[k] = true
      end
    end
  elseif catId == "weapons" then
    for _, k in ipairs(WEAPON_CODES) do if R.ITEMS[k] then out[#out + 1] = { id = k, label = R.nice(k) } end end
  elseif catId == "accessories" then
    for _, k in ipairs(R.ACC_ORDER or {}) do if R.ACCS[k] then out[#out + 1] = { id = k, label = R.ACCS[k].name } end end
  elseif catId == "creatures" then
    for _, k in ipairs(CREATURE_ORDER) do out[#out + 1] = { id = k, label = CREATURES[k].name } end
  elseif catId == "biomes" then
    for _, k in ipairs(BIOME_ORDER) do out[#out + 1] = { id = k, label = BIOMES[k].label } end
  elseif catId == "controls" then
    for _, k in ipairs(CONTROL_ORDER) do out[#out + 1] = { id = k, label = CONTROLS[k].label } end
  end
  if not NOSORT[catId] then table.sort(out, function(a, b) return a.label < b.label end) end
  return out
end

local function getEntries()
  if not G.cat then return {} end
  local list = buildEntries(G.cat)
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
    if hiTr and hiTr >= 0 then local nm = R.nameOf(hiTr); seg[#seg + 1] = T(" -> becomes ", VALCOL); seg[#seg + 1] = LK(R.nice(nm), classify(nm), nm) end
    addLine(lines, seg)
  end
  if loT and loT > -1 then
    local seg = { T(string.format("Changes below %.0fK (%.0fC)", loT, loT - 273.15), VALCOL) }
    if loTr and loTr >= 0 then local nm = R.nameOf(loTr); seg[#seg + 1] = T(" -> becomes ", VALCOL); seg[#seg + 1] = LK(R.nice(nm), classify(nm), nm) end
    addLine(lines, seg)
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

-- ================================================================ page builders
local function pageMaterialOrOre(id, catId)
  local lines = {}
  addLine(lines, { T(R.nice(id), TITLECOL), T("  [" .. id .. "]", DIMCOL) })
  local d = R.descOf(id)
  if d ~= "" then for _, s in ipairs(wrapText(d, 48)) do addLine(lines, T(s, DESCCOL)) end end
  addLine(lines, T("You have: " .. R.inv(id), VALCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("PROPERTIES", HEADCOL))
  elemFactsLines(id, lines)
  mineInfoLines(id, lines)
  if catId == "ores" or R.MINEABLE[id] or id == "WATR" or id == "LAVA" then locationLines(id, lines) end
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
  local kindLower = id:lower(); local count = 0
  for _, st in ipairs(R.stations or {}) do if st.kind == kindLower then count = count + 1 end end
  addLine(lines, T("Placed in this world: " .. count, VALCOL))
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
local function pageItemCode(id)
  local lines = {}
  addLine(lines, { T(R.nice(id), TITLECOL), T("  [" .. id .. "]", DIMCOL) })
  local d = R.descOf(id); if d ~= "" then for _, s in ipairs(wrapText(d, 48)) do addLine(lines, T(s, DESCCOL)) end end
  addLine(lines, T("You have: " .. R.inv(id), VALCOL))
  addLine(lines, T("", VALCOL)); addLine(lines, T("CRAFTING", HEADCOL))
  local any = false
  for _, rc in ipairs(R.RECIPES or {}) do if rc.out == id then any = true
    addLine(lines, { T("At " .. (R.STATIONS[rc.st] or rc.st) .. ": ", VALCOL), table.unpack(needSeg(rc.need)) }) end end
  if not any then addLine(lines, T("(no recipe found - crafting plugin may not be loaded)", DIMCOL)) end
  local kind = MACHINE_KIND[id]
  if kind then
    local count = 0; for _, m in ipairs(R.machines or {}) do if m.kind == kind then count = count + 1 end end
    addLine(lines, T("", VALCOL)); addLine(lines, T("Placed in this world: " .. count, VALCOL))
  end
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
local function pageControl(id)
  local c = CONTROLS[id]; local lines = {}
  addLine(lines, T(c.label, TITLECOL))
  for _, l in ipairs(c.lines) do addLine(lines, T(l, VALCOL)) end
  return lines
end
local function buildPage(catId, id)
  if not id then return { { T("Nothing matches your search.", DIMCOL) } } end
  if catId == "materials" or catId == "ores" then return pageMaterialOrOre(id, catId) end
  if catId == "tools" then
    if id == "TORCH" then return pageSimpleTool("Torch") end
    if id == "BUCKET" then return pageSimpleTool("Bucket") end
    local kind, idx = id:match("^(%a+):(%d+)$"); idx = tonumber(idx)
    if kind == "PICK" then return pagePick(idx) end
    if kind == "SWORD" then return pageSword(idx) end
  end
  if catId == "stations" then return pageStation(id) end
  if catId == "machines" or catId == "weapons" then return pageItemCode(id) end
  if catId == "accessories" then return pageAccessory(id) end
  if catId == "creatures" then return pageCreature(id) end
  if catId == "biomes" then return pageBiome(id) end
  if catId == "controls" then return pageControl(id) end
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
--   R.openGuide()                       - open, resuming wherever it was left (or Materials/first entry if never opened)
--   R.openGuide("weapons")               - open and jump to a category (its first entry)
--   R.openGuide({ cat = "materials", id = "GOO" }) - open and jump to one specific entry
--   R.closeGuide()                       - close and reset transient UI state (search focus, drag)
-- the caller is responsible for closing its own panel first (e.g. ui.lua closes its bag before calling this)
function R.openGuide(entryOrNil)
  R.guideOpen = true
  G.searchFocused = false
  G.drag, G.dragMeta = nil, nil
  if type(entryOrNil) == "table" then
    local catId = entryOrNil.cat or G.cat or "materials"
    G.search = ""
    navigate(catId, entryOrNil.id, false)
  elseif type(entryOrNil) == "string" then
    G.search = ""
    local es = buildEntries(entryOrNil)
    navigate(entryOrNil, es[1] and es[1].id, false)
  elseif not G.cat then
    local es = buildEntries("materials")
    navigate("materials", es[1] and es[1].id, false)
  end
end
function R.closeGuide()
  R.guideOpen = false
  G.searchFocused = false
  G.drag, G.dragMeta = nil, nil
end
local function entryLabel(catId, id)
  if not catId or not id then return "" end
  for _, e in ipairs(buildEntries(catId)) do if e.id == id then return e.label end end
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
  if hitRect(B.help, x, y) then G.help = not G.help; return true end
  if hitRect(B.search, x, y) then G.searchFocused = true; return true end
  if hitRect(B.back, x, y) and #G.back > 0 then popBack(); return true end
  if hitRect(B.take, x, y) then takeItem(G.cat, G.id); return true end
  if G.listBar and hitRect(G.listBar.track, x, y) then G.listScroll = scrollbarSeek(G.listBar, y); G.drag, G.dragMeta = "list", G.listBar; return true end
  if G.pageBar and hitRect(G.pageBar.track, x, y) then G.pageScroll = scrollbarSeek(G.pageBar, y); G.drag, G.dragMeta = "page", G.pageBar; return true end
  for i, r in ipairs(G.catRects or {}) do
    if hitRect(r, x, y) then
      local catInfo = CATS[i]
      G.search = ""; G.searchFocused = false; G.listScroll = 0
      local es = buildEntries(catInfo.id)
      if es[1] then navigate(catInfo.id, es[1].id, false) else G.cat = catInfo.id; G.id = nil; G.pageScroll = 0 end
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
    if G.drag == "list" then G.listScroll = v elseif G.drag == "page" then G.pageScroll = v end
  end
end)
if R.hooks.wheel then   -- self-wires in automatically once core exposes a wheel hook (checked at (re)load time)
  hook(R.hooks.wheel, function(x, y, d)
    if not R.guideOpen then return end
    if x >= COL3X and x < COL3X + COL3W then G.pageScroll = math.max(0, G.pageScroll - d)
    elseif x >= COL2X and x < COL2X + COL2W then G.listScroll = math.max(0, G.listScroll - d) end
    return true   -- consume regardless of column so wheel never leaks through to hotbar-select while the panel is open
  end)
end
hook(R.hooks.newworld, function()
  R.closeGuide(); G.locCache = {}; G.biomeCache = nil; G.back = {}
end)

-- ================================================================ draw
hook(R.hooks.drawHUD, function()
  if not R.guideOpen then
    graphics.drawText(R.W - 96, 80, "L: Guide (?)", 150, 150, 165, 200)
    return
  end
  R.uiPanelOpen = true
  G.links, G.listRects, G.catRects, G.btn = {}, {}, {}, {}
  local B = G.btn
  local mx, my = R.mouse.x, R.mouse.y
  graphics.fillRect(GX, GY, GW, GH, 12, 14, 28, 248)
  graphics.drawRect(GX, GY, GW, GH, 255, 220, 80, 255)
  graphics.fillRect(GX, GY, GW, 15, 40, 44, 80, 255)
  graphics.drawText(GX + 5, GY + 4, "GUIDE / DATABASE", 255, 220, 80, 255)
  graphics.drawText(GX + 118, GY + 4, "materials, recipes & mechanics - L or Esc closes", 170, 170, 185, 255)
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

  -- COL1: categories (click + hover highlight)
  for i, cinfo in ipairs(CATS) do
    local y = BY + (i - 1) * 14
    local r = { COL1X, y, COL1X + COL1W, y + 13 }
    local sel = (G.cat == cinfo.id)
    local hov = (not sel) and hitRect(r, mx, my)
    local bg = sel and { 60, 64, 100 } or (hov and { 42, 46, 74 } or { 20, 22, 34 })
    graphics.fillRect(r[1], r[2], COL1W, 13, bg[1], bg[2], bg[3], 255)
    graphics.drawText(COL1X + 3, y + 3, cinfo.label, sel and 255 or (hov and 235 or 200), sel and 220 or (hov and 225 or 200), sel and 80 or (hov and 150 or 210), 255)
    G.catRects[i] = r
  end

  -- COL2: search box (blinking cursor while focused) + entry list + drag scrollbar
  B.search = { COL2X, BY, COL2X + COL2W, BY + 12 }
  graphics.fillRect(COL2X, BY, COL2W, 12, G.searchFocused and 40 or 24, G.searchFocused and 44 or 26, G.searchFocused and 70 or 40, 255)
  graphics.drawRect(COL2X, BY, COL2W, 12, G.searchFocused and 255 or 100, G.searchFocused and 220 or 100, G.searchFocused and 80 or 110, 255)
  local cursor = (G.searchFocused and (math.floor((R.frame or 0) / 20) % 2 == 0)) and "|" or ""
  local shown = (G.search ~= "" and G.search) or ((not G.searchFocused) and "search..." or "")
  graphics.drawText(COL2X + 3, BY + 2, shown .. cursor, G.search ~= "" and 230 or 140, G.search ~= "" and 230 or 140, 150, 255)

  local entries = getEntries()
  local listY0 = BY + 15
  local rowH = 11
  local listAreaW = COL2W - SBW - 2
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
      graphics.drawText(COL2X + 2, y + 1, e.label:sub(1, 22), sel and 255 or (hov and 230 or 205), sel and 220 or (hov and 225 or 205), sel and 120 or (hov and 160 or 215), 255)
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
  local visLines = math.max(1, math.floor((BOT - pageY0) / lineH))
  G.pageScroll = math.max(0, math.min(G.pageScroll, math.max(0, #pageLines - visLines)))
  for i = 1, visLines do
    local ln = pageLines[i + G.pageScroll]
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
  G.pageBar = drawScrollbar(COL3X + pageAreaW + 2, pageY0, BOT - pageY0, #pageLines, visLines, G.pageScroll, "page")
end)
