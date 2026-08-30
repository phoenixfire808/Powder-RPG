-- UI plugin: quest log (J), item/recipe tooltips, a real slot-based bag inventory (replaces the native panel via
-- "e"; R.invOpen stays false always), onboarding tips, controls card (C), HUD polish (compass, vignette, furnace
-- indicator, pickup floaters). See knowledge/research-inventory-ux.md for the inventory design rationale.
-- Owns: key "j" (quest log), "c" (controls card), intercepts "e" (own bag panel).
local R = PBX.state.rpg
local TAG = "ui"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local floor = math.floor
local W, H = R.W, R.H

-- ================================================================ persistent state
R.ui = R.ui or {
  bagOpen = false, bagTab = "items", itemsSub = "carried", itemsScroll = 0, questOpen = false, controlsOpen = false,
  filterMat = nil, craftScroll = 0, startTime = os.time(), dismissedTips = {},
  floaters = {}, minimapWas = nil, hand = false, pickedThisPress = false, searchFocused = false, searchText = "",
  shiftHeld = false, hoverAssignEl = nil,
  everMined = false, everPlaced = false, everOpenedBag = false, everOpenedQuest = false, everOpenedControls = false,
}
local U = R.ui
R.uiPanelOpen = U.bagOpen or U.questOpen or U.controlsOpen or false

-- R.invSlots is the positional/arrangement store for the bag grid (drag-drop, stack splits); R.inventory stays
-- the single authoritative total per the "core is source of truth" rule - a sync pass below reconciles the two
-- every time the bag is drawn. Pushed onto R.PLUGIN_SAVE_KEYS so save.lua persists arrangement generically.
local N_SLOTS = 60
R.invSlots = R.invSlots or {}
for i = 1, N_SLOTS do R.invSlots[i] = R.invSlots[i] or { el = false, n = 0 } end
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
do
  local has = false; for _, k in ipairs(R.PLUGIN_SAVE_KEYS) do if k == "invSlots" then has = true end end
  if not has then R.PLUGIN_SAVE_KEYS[#R.PLUGIN_SAVE_KEYS + 1] = "invSlots" end
end

-- ================================================================ friendly item info
local ITEMDEF = {
  GOO   = { nice = "Dirt",             desc = "Common soft ground. Fired in a furnace it becomes brick." },
  GRNT  = { nice = "Granite",          desc = "Hard grey rock. Main ingredient for the Workbench-tier Furnace and a strong building block." },
  GRSS  = { nice = "Grass",            desc = "Surface grass and leaves. Burns fast; does not spread like a living plant." },
  METL  = { nice = "Iron Bar",         desc = "Smelted from Iron Ore at a lit furnace. The base material for early tools and the Anvil." },
  BCOL  = { nice = "Powdered Coal",    desc = "Loose coal dust. Turns into normal Coal the instant you pick it up." },
  WOOD  = { nice = "Wood",             desc = "Chopped from trees with the axe. Needed for almost every early recipe and for torches." },
  COAL  = { nice = "Coal",             desc = "Black speckled seams a little underground. Furnace fuel and lights torches." },
  IRON  = { nice = "Iron Ore",         desc = "Grey-flecked ore found underground. Smelt 2 at a LIT furnace into 1 Iron Bar." },
  SAND  = { nice = "Sand",             desc = "Found in deserts and underground pockets. Melts into Glass in a furnace." },
  SNOW  = { nice = "Snow",             desc = "Cold ground in snow biomes. Melts near heat." },
  ICE   = { nice = "Ice",              desc = "Frozen water. Melts near heat, refreezes in the cold." },
  PLNT  = { nice = "Plant",            desc = "Living greenery. Chop for a little wood-like material; burns easily." },
  CU    = { nice = "Copper",           desc = "Refined from Gold Ore + Iron Bars at a furnace. Wiring, LEDs, turbines." },
  GOLD  = { nice = "Gold Ore",         desc = "Found deep underground. Refine at a lit furnace for use in electronics." },
  QRTZ  = { nice = "Quartz",           desc = "Clear crystal found in deep rock. Used in advanced circuitry." },
  DU    = { nice = "Depleted Uranium", desc = "Very deep, faintly radioactive ore. Reactor fuel and a titanium ingredient." },
  URAN  = { nice = "Uranium Ore",      desc = "Radioactive ore found very deep. Reactor fuel - handle carefully." },
  STEL  = { nice = "Steel",            desc = "Iron Bars smelted with Coal. Tougher than iron; needed for steel tools." },
  TTAN  = { nice = "Titanium",         desc = "Forged from Steel + Depleted Uranium at the Anvil. Hard, heat resistant." },
  DMND  = { nice = "Diamond",          desc = "The hardest material around. The diamond pick mines anything, even bedrock." },
  WATR  = { nice = "Water",            desc = "Scoop with the bucket (slot 5); right-click to pour it back out." },
  GLAS  = { nice = "Glass",            desc = "Melted Sand. Lets light through; used in several electronics recipes." },
  BRCK  = { nice = "Fired Brick",      desc = "Kiln-baked Dirt. A solid, heat-proof building block." },
  INSL  = { nice = "Insulation",       desc = "Blocks heat and electricity. Good for lining a safe base." },
  PSCN  = { nice = "P-Silicon",        desc = "A one-way spark conductor - the basis of switches and logic circuits." },
  LEDL  = { nice = "LED Lamp",         desc = "Lights up when a spark passes through it." },
  WIFI  = { nice = "Wireless Link",    desc = "Carries a spark to another WIFI block on the same channel - no wires." },
  B4C   = { nice = "Control Rod",      desc = "Boron carbide. Absorbs neutrons - used to control a reactor." },
  TRBN  = { nice = "Turbine Stage",    desc = "Converts pressure or steam into electrical power." },
  TEG   = { nice = "Thermoelectric",   desc = "Generates power from a temperature difference between its sides." },
  UO2   = { nice = "Fuel Pellet",      desc = "Uranium dioxide reactor fuel. Handle with lead shielding." },
  STNE  = { nice = "Stone",            desc = "Basic plain rock." },
  BMTL  = { nice = "Scrap Metal",      desc = "Dropped by defeated enemies. Useful salvage." },
  BRMT  = { nice = "Bronze",           desc = "A copper alloy." },
  CLST  = { nice = "Clay",             desc = "A dense sedimentary rock layer." },
  ZIRC  = { nice = "Zirconium",        desc = "Reactor cladding metal - resists heat and corrosion." },
  LEAD  = { nice = "Lead",             desc = "Heavy metal that blocks radiation." },
  WORKBENCH = { nice = "Workbench",    desc = (R.ITEMS.WORKBENCH and R.ITEMS.WORKBENCH.desc) or "Workbench" },
  FURNACE   = { nice = "Furnace Kit",  desc = (R.ITEMS.FURNACE and R.ITEMS.FURNACE.desc) or "Furnace" },
  ANVIL     = { nice = "Anvil",        desc = (R.ITEMS.ANVIL and R.ITEMS.ANVIL.desc) or "Anvil" },
}
-- merge our friendly names into the shared R.NAMES table (core's R.nice reads it) so every plugin agrees on labels;
-- never override a name the core or another plugin already set.
if type(R.NAMES) == "table" then for k, v in pairs(ITEMDEF) do R.NAMES[k] = R.NAMES[k] or v.nice end end
local function niceName(name)
  if R.nice then return R.nice(name) end
  return (ITEMDEF[name] and ITEMDEF[name].nice) or name
end
local function friendlyDesc(name)
  if ITEMDEF[name] then return ITEMDEF[name].desc end
  local ok, d = pcall(R.descOf, name)
  if ok and d and d ~= "" then return d end
  return "No further information."
end
local TOOL_DESC = {
  pick = "Digs blocks in front of you. Better picks reach further, dig faster and mine harder ores.",
  axe = "Chops wood, plants and grass fast. Not useful on stone or ore.",
  sword = "Melee weapon - hold left mouse near an enemy to swing.",
  torch = "Aim at coal inside a furnace to light it, or click empty ground to place a light (costs 1 wood).",
  bucket = "Left-click water to scoop it up; left-click again to pour it back out.",
}

local function wrapText(s, maxChars)
  local lines, cur = {}, ""
  for word in tostring(s):gmatch("%S+") do
    if #cur == 0 then cur = word
    elseif #cur + 1 + #word <= maxChars then cur = cur .. " " .. word
    else lines[#lines + 1] = cur; cur = word end
  end
  if #cur > 0 then lines[#lines + 1] = cur end
  return lines
end
local function textW(s) return #s * 6 end

local function usedIn(name)
  local out, seen = {}, {}
  for _, rc in ipairs(R.RECIPES) do if rc.need[name] and not seen[rc.txt or rc.out] then seen[rc.txt or rc.out] = true; out[#out + 1] = rc.txt or rc.out end end
  for _, t in ipairs(R.PICKS) do if t.need[name] and not seen[t.name] then seen[t.name] = true; out[#out + 1] = t.name end end
  for _, t in ipairs(R.SWORDS) do if t.need[name] and not seen[t.name] then seen[t.name] = true; out[#out + 1] = t.name end end
  return out
end

local function itemTooltipLines(name)
  local lines = { "x" .. R.inv(name) .. " carried" }
  for _, l in ipairs(wrapText(friendlyDesc(name), 34)) do lines[#lines + 1] = l end
  local uses = usedIn(name)
  if #uses > 0 then for _, l in ipairs(wrapText("Used for: " .. table.concat(uses, ", "), 34)) do lines[#lines + 1] = l end
  else lines[#lines + 1] = "Not used in any known recipe yet." end
  return lines
end
local function toolTooltipLines(key)
  local t = R.TOOLS[key]; local lines = {}
  if t.power then lines[#lines + 1] = "power " .. t.power .. "   reach " .. (t.reach or 0) end
  if t.dmg then lines[#lines + 1] = "damage " .. t.dmg .. "   reach " .. (t.reach or 0) end
  for _, l in ipairs(wrapText(TOOL_DESC[key] or "", 34)) do lines[#lines + 1] = l end
  return lines
end

-- ================================================================ cursor-anchored tooltip box (Terraria style)
local function drawCursorTip(title, lines, w)
  w = w or 210
  local lineH = 12
  local h = 18 + #lines * lineH + 4
  local x = R.mouse.x + 14; if x + w > W - 4 then x = R.mouse.x - 14 - w end
  local y = R.mouse.y - 6; if y + h > H - 45 then y = H - 45 - h end; if y < 4 then y = 4 end
  graphics.fillRect(x, y, w, h, 10, 12, 24, 248); graphics.drawRect(x, y, w, h, 255, 220, 80, 255)
  graphics.drawText(x + 5, y + 4, title, 255, 230, 140, 255)
  for i, l in ipairs(lines) do graphics.drawText(x + 5, y + 4 + 14 + (i - 1) * lineH, l, 210, 210, 220, 255) end
end

-- ================================================================ hover targets: hotbar slots + zoom palette swatches
-- centred tray, 10 slots of 30x30 with 3px gaps, y = H-38 (matches core drawHotbar's SLOT=30,GAP=3,y0=H-SLOT-8)
local HB_SLOT, HB_GAP = 30, 3
local HB_X0 = floor((W - (10 * HB_SLOT + 9 * HB_GAP)) / 2)
local HB_Y0 = H - HB_SLOT - 8
local function hotbarSlotAt(mx, my)
  if my < HB_Y0 or my >= HB_Y0 + HB_SLOT then return nil end
  local slot = floor((mx - HB_X0) / (HB_SLOT + HB_GAP)) + 1
  if slot < 1 or slot > 10 then return nil end
  local sx = HB_X0 + (slot - 1) * (HB_SLOT + HB_GAP)
  if mx < sx or mx >= sx + HB_SLOT then return nil end
  return slot
end
local PAL_Y = H - 56
local function paletteSlotAt(mx, my)
  local ok, en = pcall(ren.zoomEnabled); if not ok or not en then return nil end
  if my < PAL_Y or my >= PAL_Y + 24 then return nil end
  local names = {}; for k, v in pairs(R.inventory or {}) do if v > 0 then names[#names + 1] = k end end; table.sort(names)
  local i = floor((mx - 4) / 26) + 1
  return names[i]
end

-- ================================================================ HUD polish: vignette, compass, furnace indicator, floaters
local function drawVignette()
  local hp = R.hp or 100; if hp >= 30 then return end
  local a = floor((30 - hp) / 30 * 140); local t = 10
  graphics.fillRect(0, 0, W, t, 255, 0, 0, a); graphics.fillRect(0, H - t, W, t, 255, 0, 0, a)
  graphics.fillRect(0, 0, t, H, 255, 0, 0, a); graphics.fillRect(W - t, 0, t, H, 255, 0, 0, a)
end
local function drawCompass()
  local x, y, w, h = 502, 82, 104, 46
  graphics.fillRect(x, y, w, h, 0, 0, 0, 170); graphics.drawRect(x, y, w, h, 120, 124, 150, 200)
  local depth = floor((R.P.y - R.surfaceAt(floor(R.P.x))) / 4)
  local biome = R.biomeAt(floor(R.P.x))
  local phase = ((R.frame or 0) % 14000) / 14000
  local night = math.sin((phase - 0.5) * math.pi * 2) > 0
  graphics.drawText(x + 4, y + 2, "Day " .. (R.day or 1) .. (night and " (night)" or " (day)"), 220, 220, 230, 255)
  graphics.drawText(x + 4, y + 14, "Biome: " .. biome, 190, 220, 180, 255)
  local dtxt = depth > 0 and (depth .. "m deep") or (depth < 0 and ((-depth) .. "m up") or "surface")
  graphics.drawText(x + 4, y + 26, dtxt, 190, 200, 255, 255)
  local maxd = math.max(1, floor((R.DEPTH or 1900) / 4)); local frac = math.max(0, math.min(1, depth / maxd))
  graphics.fillRect(x + 4, y + 38, 96, 4, 40, 40, 50, 255); graphics.fillRect(x + 4, y + 38, floor(96 * frac), 4, 220, 160, 60, 255)
end
local function furnaceLit(st)
  for yy = st.y - 10, st.y - 2 do for xx = st.x + 2, st.x + 11 do
    local p = sim.partID(xx - R.cam.x, yy - R.cam.y)
    if p then local nm = R.nameOf(sim.partProperty(p, "type")); if nm == "FIRE" or nm == "PLSM" or (sim.partProperty(p, "temp") or 0) > 600 then return true end end
  end end
  return false
end
local function nearestFurnace()
  local best, bd
  for _, st in ipairs(R.stations) do if st.kind == "furnace" then
    local d = (st.x - R.P.x) ^ 2 + (st.y - R.P.y) ^ 2
    if d < 70 * 70 and (not bd or d < bd) then best, bd = st, d end
  end end
  return best
end
local function drawFurnaceIndicator()
  local fs = nearestFurnace(); if not fs then return end
  local lit = furnaceLit(fs)
  local fx, fy = fs.x - R.cam.x, fs.y - R.cam.y - 18
  local label = lit and "FURNACE: LIT" or "FURNACE: UNLIT - light it with the torch"
  local col = lit and { 255, 180, 60 } or { 200, 200, 210 }
  graphics.fillRect(fx - 2, fy - 2, textW(label) + 4, 12, 0, 0, 0, 190)
  graphics.drawText(fx, fy, label, col[1], col[2], col[3], 255)
end
local function drawFloaters()
  for i = #U.floaters, 1, -1 do
    local f = U.floaters[i]; local age = (R.frame or 0) - f.born
    if age > 50 then table.remove(U.floaters, i)
    else
      local x, y = f.x - R.cam.x, f.y - R.cam.y - age * 0.4
      local a = math.max(0, 255 - age * 5)
      graphics.drawText(floor(x - #f.text * 3), floor(y), f.text, 140, 255, 160, floor(a))
    end
  end
end

-- ================================================================ onboarding tips (first 60s, dismiss on action)
local TIPS = {
  { id = "move", text = "A/D to move, W to jump (hold longer to jump higher). Space pauses.", done = function() return math.abs(R.P.vx or 0) > 0.3 end },
  { id = "dig", text = "Hold LEFT mouse with the pick (slot 1) to dig toward your cursor.", done = function() return U.everMined end },
  { id = "place", text = "Hold LEFT mouse to place the block in your selected slot (6-0).", done = function() return U.everPlaced end },
  { id = "bag", text = "Press E for your bag, materials list and recipe book.", done = function() return U.everOpenedBag end },
  { id = "quest", text = "Press J anytime for the full quest log.", done = function() return U.everOpenedQuest end },
  { id = "controls", text = "Press C for a controls reference card.", done = function() return U.everOpenedControls end },
}
local function drawOnboardingTips()
  -- Same on/off switch as the Esc-menu controls popup (R.tipsOn, defaults
  -- off) -- this box was the real source of "tips are annoying": it resets
  -- and shows again for a full 60 REAL seconds on every single restart
  -- (os.time() is wall-clock, not sim frame), which during active
  -- dev/testing meant it reappeared almost every time the game reopened.
  if R.tipsOn == false then return end
  if os.time() - (U.startTime or 0) > 60 then return end
  local ok, en = pcall(ren.zoomEnabled); if ok and en then return end
  local active = {}
  for _, t in ipairs(TIPS) do
    if not U.dismissedTips[t.id] then
      if t.done() then U.dismissedTips[t.id] = true else active[#active + 1] = t.text end
    end
  end
  if #active == 0 then return end
  local w = 360; local h = 16 + #active * 13 + 4
  local x = floor((W - w) / 2); local y = (H - 45) - h - 4
  graphics.fillRect(x, y, w, h, 0, 0, 0, 190); graphics.drawRect(x, y, w, h, 120, 200, 255, 210)
  graphics.drawText(x + 6, y + 3, "TIPS", 140, 220, 255, 255)
  for i, txt in ipairs(active) do graphics.drawText(x + 6, y + 3 + 14 + (i - 1) * 13, txt, 220, 230, 240, 255) end
end

-- ================================================================ accessory equip API (core: R.acc=owned, R.accOn(k)
-- =effect live, R.equipAcc(k,bool)=toggle; fall back gracefully if an older core is loaded mid-session)
local function accOwned(k) return R.acc and R.acc[k] end
local function accLive(k)
  if R.accOn then local ok, v = pcall(R.accOn, k); if ok then return v end end
  return accOwned(k) and not (R.accOff and R.accOff[k])
end
local function toggleAcc(k)
  if R.equipAcc then pcall(R.equipAcc, k, not accLive(k))
  elseif R.accOff then R.accOff[k] = accLive(k) or nil; R.say((accLive(k) and "Enabled " or "Disabled ") .. R.ACCS[k].name) end
end

-- ================================================================ bag: shared data helpers
local function invNames() local names = {}; for k, v in pairs(R.inventory or {}) do if v > 0 then names[#names + 1] = k end end; table.sort(names); return names end
local function canAfford(need) for el, n in pairs(need) do if R.inv(el) < n then return false end end; return true end
local function fullCatalog()
  local set = {}
  for k in pairs(R.MINEABLE or {}) do set[k] = true end
  for k in pairs(R.HARD or {}) do set[k] = true end
  for k in pairs(R.ITEMS or {}) do set[k] = true end
  for k in pairs(R.inventory or {}) do set[k] = true end
  local out = {}; for k in pairs(set) do out[#out + 1] = k end; table.sort(out); return out
end
local function allMaterials()
  local set = {}
  for _, rc in ipairs(R.RECIPES) do for el in pairs(rc.need) do set[el] = true end end
  for _, t in ipairs(R.PICKS) do for el in pairs(t.need) do set[el] = true end end
  for _, t in ipairs(R.SWORDS) do for el in pairs(t.need) do set[el] = true end end
  local out = {}; for k in pairs(set) do out[#out + 1] = k end; table.sort(out); return out
end
local function assignHotbar(el, forceSlot)
  local slot = forceSlot
  if not slot then
    slot = (R.sel and R.sel >= 6) and R.sel or 6
    for s = 6, 10 do if R.hotbar[s] == el then slot = s end end
  end
  R.hotbar[slot] = el; R.sel = slot
  R.say(niceName(el) .. " -> slot " .. (slot % 10))
end
local function buildCraftRows(filter)
  local rows = {}
  -- Bug found 2026-08-29: this list never included "research"/"advlab" (both real
  -- tiers past the workbench, shipped this session), so any recipe gated on either
  -- station was structurally unreachable in the crafting UI -- R.craft()/canAfford()
  -- worked fine, the row just never got drawn for the player to click.
  local order = { "hand", "workbench", "furnace", "anvil", "research", "advlab" }
  for _, stk in ipairs(order) do
    local okst, why = R.nearStation(stk)
    local group = {}
    for k, rc in ipairs(R.RECIPES) do if (rc.st or "hand") == stk and (not filter or rc.need[filter]) then
      group[#group + 1] = { kind = "recipe", label = rc.n .. " " .. rc.txt, need = rc.need, ok = okst and canAfford(rc.need), dim = not okst, desc = rc.desc, st = stk, fn = function() R.craft(k) end } end end
    for k, t in ipairs(R.PICKS) do if (t.st or "hand") == stk and (not filter or t.need[filter]) then
      group[#group + 1] = { kind = "pick", label = t.name, need = t.need, ok = okst and canAfford(t.need), dim = not okst, desc = t.desc, st = stk, have = (R.TOOLS.pick.name == t.name), fn = function() R.craftPick(k) end } end end
    for k, t in ipairs(R.SWORDS) do if (t.st or "hand") == stk and (not filter or t.need[filter]) then
      group[#group + 1] = { kind = "sword", label = t.name, need = t.need, ok = okst and canAfford(t.need), dim = not okst, desc = t.desc, st = stk, have = (R.TOOLS.sword.name == t.name), fn = function() R.craftSword(k) end } end end
    if #group > 0 then
      -- "trying to figure out how to make the next item, it's all confusing" -- the
      -- round-6/7 fixes solved recipes being unreachable, not this: within a station,
      -- craftable-right-now recipes were interleaved randomly with ones you can't
      -- afford yet. Sort craftable-now first so "what can I make" is the first thing
      -- you see, not something you have to scan for.
      table.sort(group, function(a, b) return (a.ok and 1 or 0) > (b.ok and 1 or 0) end)
      rows[#rows + 1] = { header = (R.STATIONS[stk] or stk):upper() .. (okst and "" or (" (" .. (why or "not here") .. ")")), okst = okst }
      for _, r in ipairs(group) do rows[#rows + 1] = r end
    end
  end
  return rows
end
local function craftMultiple(row, times)
  for i = 1, times do
    if not canAfford(row.need) then break end
    local okst = R.nearStation(row.st or "hand"); if not okst then break end
    row.fn()
  end
end
local function recipeTooltipLines(r)
  local lines = { "station: " .. (R.STATIONS[r.st] or r.st) }
  local needList = {}; for el, n in pairs(r.need) do needList[#needList + 1] = { el, n } end
  table.sort(needList, function(a, b) return a[1] < b[1] end)
  for _, p in ipairs(needList) do lines[#lines + 1] = niceName(p[1]) .. " (" .. p[1] .. ") x" .. p[2] .. (R.inv(p[1]) < p[2] and (" - have " .. R.inv(p[1])) or "") end
  if r.desc then for _, l in ipairs(wrapText(r.desc, 34)) do lines[#lines + 1] = l end end
  if r.kind == "recipe" then lines[#lines + 1] = "click = craft x1, the x5 button crafts up to 5" end
  return lines
end
-- Still capped at 2 visible rows (with 20-40+ materials this used to wrap unbounded
-- and eat most of the panel -- "takes up half the space, we can only look at three
-- things"), but now wheel-scrollable: U.matChipScroll skips whole rows so every
-- material stays reachable instead of the tail being permanently unshown.
local function forEachMatChip(x0, y0, maxw, cb)
  local mats = allMaterials(); local mx, my = x0, y0
  local visRows = 2; local row = 0
  local maxRowY = y0 + (visRows - 1) * 14
  local scroll = U.matChipScroll or 0
  for _, m in ipairs(mats) do
    local w = 26 + textW(niceName(m)) + textW(m)
    if mx + w > x0 + maxw then mx = x0; my = my + 14; row = row + 1 end
    if row >= scroll and row < scroll + visRows then
      cb(m, mx, my - scroll * 14, w, 12)
    end
    mx = mx + w + 4
  end
  U.matChipRows = row + 1
  if U.matChipRows > visRows then
    graphics.drawText(x0 + maxw - 90, y0 - 12, "wheel: more mats", 150, 150, 160, 255)
  end
  return math.min(my - scroll * 14, maxRowY) + 14
end

-- ================================================================ inventory slots: sync, pickup/drop, sort, search, trash
local function syncInvSlots()
  R.invSlots = R.invSlots or {}   -- defensive: core resets this per-world, don't hard-crash (silently, into R.pluginErr) if it's ever nil again
  local slots = R.invSlots
  local slotTotal = {}
  for _, s in ipairs(slots) do if s.el then slotTotal[s.el] = (slotTotal[s.el] or 0) + s.n end end
  for el, total in pairs(R.inventory or {}) do
    if total and total > 0 then
      local have = slotTotal[el] or 0
      local diff = total - have
      if diff > 0 then
        local placed = false
        for _, s in ipairs(slots) do if s.el == el then s.n = s.n + diff; placed = true; break end end
        if not placed then for _, s in ipairs(slots) do if not s.el then s.el = el; s.n = diff; placed = true; break end end end
        if not placed then slots[#slots + 1] = { el = el, n = diff } end
      elseif diff < 0 then
        local need = -diff
        for i = #slots, 1, -1 do local s = slots[i]
          if s.el == el and need > 0 then local take = math.min(need, s.n); s.n = s.n - take; need = need - take; if s.n <= 0 then s.el = false; s.n = 0 end end
        end
      end
    end
  end
  for _, s in ipairs(slots) do
    if s.el and (not R.inventory[s.el] or R.inventory[s.el] <= 0) then s.el = false; s.n = 0 end
  end
end
local function matchesSearch(el)
  if not U.searchText or U.searchText == "" then return true end
  local q = U.searchText:lower()
  return el:lower():find(q, 1, true) ~= nil or niceName(el):lower():find(q, 1, true) ~= nil
end
local function visibleCarriedSlots()
  local out = {}
  for i, s in ipairs(R.invSlots) do if s.el and matchesSearch(s.el) then out[#out + 1] = i end end
  return out
end
local function sortInventory()
  local items = {}
  for _, s in ipairs(R.invSlots) do if s.el and s.n > 0 then items[#items + 1] = { el = s.el, n = s.n } end end
  table.sort(items, function(a, b) return niceName(a.el) < niceName(b.el) end)
  for _, s in ipairs(R.invSlots) do s.el = false; s.n = 0 end
  for i, it in ipairs(items) do
    if not R.invSlots[i] then R.invSlots[i] = { el = false, n = 0 } end
    R.invSlots[i].el = it.el; R.invSlots[i].n = it.n
  end
  R.say("Inventory sorted")
end
local function quickMoveToHotbar(el)
  local slot
  for s = 6, 10 do if R.hotbar[s] == el then slot = s; break end end
  if not slot then for s = 6, 10 do if not R.hotbar[s] then slot = s; break end end end
  if not slot then slot = (R.sel and R.sel >= 6) and R.sel or 6 end
  assignHotbar(el, slot)
end
local function pickupFrom(idx, button)
  local s = R.invSlots[idx]; if not s or not s.el or s.n <= 0 then return end
  if button == 3 then
    local half = math.ceil(s.n / 2)
    U.hand = { el = s.el, n = half, originIdx = idx }
    s.n = s.n - half; if s.n <= 0 then s.el = false; s.n = 0 end
  else
    U.hand = { el = s.el, n = s.n, originIdx = idx }
    s.el = false; s.n = 0
  end
  U.pickedThisPress = true
end
local function dropHandInto(idx, button)
  if not U.hand then return end
  local s = R.invSlots[idx]; if not s then return end
  if button == 3 then
    if not s.el or s.el == U.hand.el then
      s.el = U.hand.el; s.n = (s.n or 0) + 1; U.hand.n = U.hand.n - 1
      if U.hand.n <= 0 then U.hand = false end
    end
  else
    if not s.el then s.el, s.n = U.hand.el, U.hand.n; U.hand = false
    elseif s.el == U.hand.el then s.n = s.n + U.hand.n; U.hand = false
    else local tmp = { el = s.el, n = s.n }; s.el, s.n = U.hand.el, U.hand.n; U.hand = tmp end
  end
end
local function trashHand(button)
  if not U.hand then return end
  if button == 3 then
    R.inventory[U.hand.el] = math.max(0, (R.inventory[U.hand.el] or 0) - 1)
    U.hand.n = U.hand.n - 1; if U.hand.n <= 0 then U.hand = false end
  else
    R.inventory[U.hand.el] = math.max(0, (R.inventory[U.hand.el] or 0) - U.hand.n)
    U.hand = false
  end
  R.rebuildHotbar()
end

-- ================================================================ panels: geometry + open/close
local BPX, BPY, BPW, BPH = 70, 40, 472, 299   -- bottom = 339 = H-45, clear of the redesigned centred hotbar tray
local function closeAllPanels()
  if (U.bagOpen or U.questOpen or U.controlsOpen) and U.minimapWas ~= nil then R.minimap = U.minimapWas end
  U.minimapWas = nil
  if U.hand then local s = R.invSlots[U.hand.originIdx]; if s and not s.el then s.el, s.n = U.hand.el, U.hand.n end; U.hand = false end
  U.searchFocused = false
  U.bagOpen, U.questOpen, U.controlsOpen = false, false, false
end
local function openPanel(which)
  if not (U.bagOpen or U.questOpen or U.controlsOpen) then U.minimapWas = R.minimap end
  U.bagOpen, U.questOpen, U.controlsOpen = false, false, false
  U[which] = true
  R.menuOpen = false; R.minimap = false
  R.mouse.l = false; R.mouse.r = false
end

-- ================================================================ bag: ITEMS tab (slot inventory, never truncates names)
local ITEMS_X0, ITEMS_Y0, ITEMS_W, ITEMS_ROWH = BPX + 10, BPY + 58, BPW - 20, 14
local ITEMS_BOTTOM_RESERVE = 78   -- equip row + bag tray row + tools/deaths line
local CTRL_Y = BPY + 40
local SEARCH_X, SEARCH_W = ITEMS_X0, 170
local SORT_X, SORT_W = ITEMS_X0 + SEARCH_W + 6, 40
local TRASH_X, TRASH_W = BPX + BPW - 34, 24
local ACC_COLORS = {
  cloud = { 200, 220, 255 }, boots = { 200, 140, 80 }, mirror = { 220, 220, 255 }, hook = { 160, 160, 170 },
  spelunk = { 120, 255, 180 }, helmet = { 255, 220, 120 }, lava = { 255, 120, 60 }, rocket = { 255, 80, 80 }, dpick = { 180, 230, 255 },
}
local function itemsVisibleRows() return math.max(1, floor((BPY + BPH - ITEMS_BOTTOM_RESERVE - ITEMS_Y0) / ITEMS_ROWH)) end
local function drawSlotRow(x, y, w, el, n)
  local r, g, b = R.colourOf(el); local a = n > 0 and 255 or 100
  graphics.fillRect(x, y + 2, 8, 8, r, g, b, a)
  local nm = niceName(el)
  graphics.drawText(x + 11, y, nm, a, a, a == 255 and 235 or 120, 255)
  local codeX = x + 11 + textW(nm) + 6
  local code = "(" .. el .. ")"
  graphics.drawText(codeX, y, code, a == 255 and 150 or 90, a == 255 and 150 or 90, a == 255 and 160 or 100, 255)
  local cx = codeX + textW(code) + 8
  graphics.drawText(cx, y, "x" .. n, a, a, a, 255)
  local inbar; for s = 6, 10 do if R.hotbar[s] == el then inbar = s end end
  if inbar then graphics.drawText(x + w - 22, y, "[" .. (inbar % 10) .. "]", 255, 220, 80, 255) end
  if R.mouse.x >= x and R.mouse.x < x + w and R.mouse.y >= y and R.mouse.y < y + ITEMS_ROWH then return true end
  return false
end
local ACC_BAR_H, ACC_TRAY_H, ACC_GAP = 28, 16, 4
local function accSlotX(x0, w, i) local n = #R.ACC_ORDER; local slotW = floor((w - (n - 1) * 4) / n); return x0 + (i - 1) * (slotW + 4), slotW end
local function accHitAt(x0, y0, w, mx, my)
  -- returns "equip"/"tray", key  if (mx,my) is over that accessory's slot in either row
  local n = #R.ACC_ORDER
  for i, k in ipairs(R.ACC_ORDER) do
    local ax, slotW = accSlotX(x0, w, i)
    if mx >= ax and mx < ax + slotW then
      if my >= y0 and my < y0 + ACC_BAR_H then return "equip", k end
      if my >= y0 + ACC_BAR_H + ACC_GAP and my < y0 + ACC_BAR_H + ACC_GAP + ACC_TRAY_H then return "tray", k end
    end
  end
  return nil
end
local function drawAccessorySlots(x0, y0, w)
  local n = #R.ACC_ORDER
  local dragging = U.hand and U.hand.isAcc
  graphics.drawText(x0, y0 - 12, "EQUIPPED  (drag to/from BAG below, or just click to toggle)", 255, 220, 80, 255)
  if dragging then graphics.drawRect(x0 - 2, y0 - 2, w + 4, ACC_BAR_H + 4, 120, 255, 140, 220) end
  local hoverAcc, hoverWhere
  for i, k in ipairs(R.ACC_ORDER) do
    local x, slotW = accSlotX(x0, w, i)
    local have = accOwned(k); local live = have and accLive(k) and not (dragging and U.hand.key == k)
    graphics.fillRect(x, y0, slotW, ACC_BAR_H, have and (live and 30 or 40) or 18, have and (live and 34 or 24) or 18, have and (live and 50 or 24) or 24, 255)
    graphics.drawRect(x, y0, slotW, ACC_BAR_H, have and (live and 255 or 150) or 80, have and (live and 220 or 90) or 80, have and (live and 80 or 90) or 90, 255)
    if have and live then
      local c = ACC_COLORS[k] or { 200, 200, 200 }
      graphics.fillRect(x + slotW / 2 - 4, y0 + 4, 8, 8, c[1], c[2], c[3], 255)
      graphics.drawText(x + 3, y0 + 16, string.sub(k, 1, math.max(1, floor((slotW - 4) / 6))), 230, 230, 230, 255)
    elseif not have then
      graphics.drawText(x + slotW / 2 - 3, y0 + 9, "?", 90, 90, 100, 255)
    end
    if R.mouse.x >= x and R.mouse.x < x + slotW and R.mouse.y >= y0 and R.mouse.y < y0 + ACC_BAR_H then hoverAcc, hoverWhere = k, "equip" end
  end
  local trayY = y0 + ACC_BAR_H + ACC_GAP
  graphics.drawText(x0, trayY - 10, "BAG (owned, unequipped)", 190, 190, 200, 255)
  if dragging then graphics.drawRect(x0 - 2, trayY - 2, w + 4, ACC_TRAY_H + 4, 120, 220, 255, 220) end
  for i, k in ipairs(R.ACC_ORDER) do
    local x, slotW = accSlotX(x0, w, i)
    local have = accOwned(k); local offHere = have and (not accLive(k) or (dragging and U.hand.key == k))
    graphics.fillRect(x, trayY, slotW, ACC_TRAY_H, offHere and 34 or 16, offHere and 34 or 16, offHere and 40 or 20, 255)
    graphics.drawRect(x, trayY, slotW, ACC_TRAY_H, offHere and 150 or 60, offHere and 150 or 60, offHere and 160 or 66, 255)
    if offHere then
      local c = ACC_COLORS[k] or { 200, 200, 200 }
      graphics.fillRect(x + slotW / 2 - 3, trayY + 4, 6, 6, floor(c[1] * 0.7), floor(c[2] * 0.7), floor(c[3] * 0.7), 255)
    end
    if R.mouse.x >= x and R.mouse.x < x + slotW and R.mouse.y >= trayY and R.mouse.y < trayY + ACC_TRAY_H then hoverAcc, hoverWhere = k, "tray" end
  end
  if hoverAcc and not dragging then
    local a = R.ACCS[hoverAcc]; local have = accOwned(hoverAcc)
    local lines = {}
    for _, l in ipairs(wrapText(a.desc, 34)) do lines[#lines + 1] = l end
    lines[#lines + 1] = have and (accLive(hoverAcc) and "ON - click/drag down to unequip" or "OFF - click/drag up to equip") or ("Not found yet - cave chests, tier " .. a.tier)
    drawCursorTip(a.name, lines)
  end
end
local function drawSearchSortTrash()
  graphics.fillRect(SEARCH_X, CTRL_Y, SEARCH_W, 13, U.searchFocused and 40 or 24, U.searchFocused and 44 or 26, U.searchFocused and 70 or 40, 255)
  graphics.drawRect(SEARCH_X, CTRL_Y, SEARCH_W, 13, U.searchFocused and 255 or 100, U.searchFocused and 220 or 100, U.searchFocused and 80 or 110, 255)
  local shown = (U.searchText ~= "" and U.searchText) or "search..."
  graphics.drawText(SEARCH_X + 4, CTRL_Y + 3, shown .. (U.searchFocused and "_" or ""), U.searchText ~= "" and 230 or 140, U.searchText ~= "" and 230 or 140, 150, 255)
  graphics.fillRect(SORT_X, CTRL_Y, SORT_W, 13, 40, 44, 80, 255); graphics.drawRect(SORT_X, CTRL_Y, SORT_W, 13, 150, 150, 170, 255)
  graphics.drawText(SORT_X + 5, CTRL_Y + 3, "SORT", 220, 220, 230, 255)
  graphics.fillRect(TRASH_X, CTRL_Y, TRASH_W, 13, 60, 26, 26, 255); graphics.drawRect(TRASH_X, CTRL_Y, TRASH_W, 13, 200, 90, 90, 255)
  graphics.drawText(TRASH_X + 3, CTRL_Y + 3, "DEL", 255, 160, 160, 255)
end
local function drawHandCursor()
  if not U.hand then return end
  local x, y = R.mouse.x, R.mouse.y
  if U.hand.isAcc then
    local c = ACC_COLORS[U.hand.key] or { 200, 200, 200 }
    graphics.fillRect(x - 5, y - 5, 10, 10, c[1], c[2], c[3], 255); graphics.drawRect(x - 5, y - 5, 10, 10, 255, 255, 255, 220)
    graphics.drawText(x + 7, y - 4, R.ACCS[U.hand.key].name, 255, 240, 200, 255)
    graphics.drawText(x + 7, y + 8, "drop on EQUIPPED to equip, BAG (or elsewhere) to unequip", 170, 190, 220, 255)
    return
  end
  local r, g, b = R.colourOf(U.hand.el)
  graphics.fillRect(x - 5, y - 5, 10, 10, r, g, b, 255); graphics.drawRect(x - 5, y - 5, 10, 10, 255, 255, 255, 220)
  graphics.drawText(x + 7, y - 4, niceName(U.hand.el) .. " x" .. U.hand.n, 255, 240, 200, 255)
  graphics.drawText(x + 7, y + 8, "L place/merge  R place 1  drop on DEL to delete", 170, 190, 220, 255)
end
local function drawBagItemsTab()
  local sub = { { "CARRIED", "carried" }, { "CATALOG", "catalog" } }
  for i, t in ipairs(sub) do
    local tx = BPX + 10 + (i - 1) * 74
    local active = (U.itemsSub or "carried") == t[2]
    graphics.fillRect(tx, BPY + 24, 68, 13, active and 60 or 24, active and 64 or 26, active and 40 or 40, 255)
    graphics.drawText(tx + 5, BPY + 27, t[1], active and 255 or 170, active and 230 or 170, active and 120 or 180, 255)
  end
  local hoverEl
  U.hoverAssignEl = nil
  if U.itemsSub == "catalog" then
    graphics.drawText(BPX + 160, BPY + 27, "reference list - click an owned row to assign it to your hotbar", 180, 190, 210, 255)
    local list = fullCatalog()
    local rows = itemsVisibleRows()
    U.itemsScroll = math.max(0, math.min(math.max(0, #list - rows), U.itemsScroll or 0))
    for i = 1, rows do
      local el = list[i + U.itemsScroll]; if not el then break end
      local y = ITEMS_Y0 + (i - 1) * ITEMS_ROWH
      if drawSlotRow(ITEMS_X0, y, ITEMS_W, el, R.inv(el)) then hoverEl = el; U.hoverAssignEl = el end
    end
    if #list > rows then
      local upX, upY = BPX + BPW - 42, ITEMS_Y0 - 16
      local dnX, dnY = BPX + BPW - 22, ITEMS_Y0 - 16
      graphics.fillRect(upX, upY, 16, 13, 40, 44, 80, 255); graphics.drawText(upX + 5, upY + 1, "^", 220, 220, 230, 255)
      graphics.fillRect(dnX, dnY, 16, 13, 40, 44, 80, 255); graphics.drawText(dnX + 5, dnY + 1, "v", 220, 220, 230, 255)
      graphics.drawText(BPX + BPW - 130, ITEMS_Y0 - 14, string.format("%d/%d", math.min(#list, U.itemsScroll + rows), #list), 160, 160, 170, 255)
    end
  else
    syncInvSlots()
    drawSearchSortTrash()
    graphics.drawText(BPX + 160, BPY + 27, "click = send to hotbar   R-click/drag = pick up to rearrange", 170, 185, 210, 255)
    local vis = visibleCarriedSlots()
    local rows = itemsVisibleRows()
    U.itemsScroll = math.max(0, math.min(math.max(0, #vis - rows), U.itemsScroll or 0))
    for i = 1, rows do
      local idx = vis[i + U.itemsScroll]; if not idx then break end
      local s = R.invSlots[idx]
      local y = ITEMS_Y0 + (i - 1) * ITEMS_ROWH
      if drawSlotRow(ITEMS_X0, y, ITEMS_W, s.el, s.n) then hoverEl = s.el; U.hoverAssignEl = s.el end
    end
    if #vis > rows then
      local upX, upY = BPX + BPW - 42, ITEMS_Y0 - 16
      local dnX, dnY = BPX + BPW - 22, ITEMS_Y0 - 16
      graphics.fillRect(upX, upY, 16, 13, 40, 44, 80, 255); graphics.drawText(upX + 5, upY + 1, "^", 220, 220, 230, 255)
      graphics.fillRect(dnX, dnY, 16, 13, 40, 44, 80, 255); graphics.drawText(dnX + 5, dnY + 1, "v", 220, 220, 230, 255)
      graphics.drawText(BPX + BPW - 150, ITEMS_Y0 - 14, string.format("%d/%d", math.min(#vis, U.itemsScroll + rows), #vis), 160, 160, 170, 255)
    end
  end
  local accY = BPY + BPH - ITEMS_BOTTOM_RESERVE + 16
  drawAccessorySlots(ITEMS_X0, accY, ITEMS_W)
  graphics.drawText(ITEMS_X0, BPY + BPH - 12, "TOOLS  1:" .. R.TOOLS.pick.name .. "   3:" .. R.TOOLS.sword.name .. "     Deaths " .. (R.deaths or 0) .. "   Day " .. (R.day or 1), 170, 170, 180, 255)
  if hoverEl then drawCursorTip(niceName(hoverEl), itemTooltipLines(hoverEl)) end
end
local function handleBagClickItems(x, y, button)
  do  -- accessories: click toggles instantly; also picks the icon up so it can be dragged to confirm/reverse
    local accY = BPY + BPH - ITEMS_BOTTOM_RESERVE + 16
    local where, k = accHitAt(ITEMS_X0, accY, ITEMS_W, x, y)
    if where then
      if accOwned(k) then
        toggleAcc(k)
        U.hand = { isAcc = true, key = k }
      end
      return
    end
    if y >= accY and y < accY + ACC_BAR_H + ACC_GAP + ACC_TRAY_H then return end
  end
  local sub = { { "CARRIED", "carried" }, { "CATALOG", "catalog" } }
  for i, t in ipairs(sub) do
    local tx = BPX + 10 + (i - 1) * 74
    if x >= tx and x < tx + 68 and y >= BPY + 24 and y < BPY + 37 then U.itemsSub = t[2]; U.itemsScroll = 0; return end
  end
  if U.itemsSub == "catalog" then
    local list = fullCatalog(); local rows = itemsVisibleRows()
    if #list > rows then
      local upX, upY = BPX + BPW - 42, ITEMS_Y0 - 16
      local dnX, dnY = BPX + BPW - 22, ITEMS_Y0 - 16
      if x >= upX and x < upX + 16 and y >= upY and y < upY + 13 then U.itemsScroll = math.max(0, (U.itemsScroll or 0) - 1); return end
      if x >= dnX and x < dnX + 16 and y >= dnY and y < dnY + 13 then U.itemsScroll = math.min(math.max(0, #list - rows), (U.itemsScroll or 0) + 1); return end
    end
    for i = 1, rows do
      local el = list[i + (U.itemsScroll or 0)]; if not el then break end
      local ry = ITEMS_Y0 + (i - 1) * ITEMS_ROWH
      if x >= ITEMS_X0 and x < ITEMS_X0 + ITEMS_W and y >= ry and y < ry + ITEMS_ROWH then
        if R.inv(el) > 0 then assignHotbar(el) end
        return
      end
    end
    return
  end
  -- CARRIED (slot inventory)
  if x >= SEARCH_X and x < SEARCH_X + SEARCH_W and y >= CTRL_Y and y < CTRL_Y + 13 then U.searchFocused = true; return end
  if x >= SORT_X and x < SORT_X + SORT_W and y >= CTRL_Y and y < CTRL_Y + 13 then sortInventory(); U.searchFocused = false; return end
  if x >= TRASH_X and x < TRASH_X + TRASH_W and y >= CTRL_Y and y < CTRL_Y + 13 then if U.hand then trashHand(button) end; U.searchFocused = false; return end
  U.searchFocused = false
  local vis = visibleCarriedSlots(); local rows = itemsVisibleRows()
  if #vis > rows then
    local upX, upY = BPX + BPW - 42, ITEMS_Y0 - 16
    local dnX, dnY = BPX + BPW - 22, ITEMS_Y0 - 16
    if x >= upX and x < upX + 16 and y >= upY and y < upY + 13 then U.itemsScroll = math.max(0, (U.itemsScroll or 0) - 1); return end
    if x >= dnX and x < dnX + 16 and y >= dnY and y < dnY + 13 then U.itemsScroll = math.min(math.max(0, #vis - rows), (U.itemsScroll or 0) + 1); return end
  end
  for i = 1, rows do
    local idx = vis[i + (U.itemsScroll or 0)]; if not idx then break end
    local ry = ITEMS_Y0 + (i - 1) * ITEMS_ROWH
    if x >= ITEMS_X0 and x < ITEMS_X0 + ITEMS_W and y >= ry and y < ry + ITEMS_ROWH then
      local s = R.invSlots[idx]
      if U.shiftHeld and not U.hand and s.el then quickMoveToHotbar(s.el)
      elseif not U.hand then
        -- left-click with an empty hand is the reliable, no-drag path: send it straight to the
        -- selected hotbar slot (or slot 6) - matches the CATALOG tab and req (3). Right-click still
        -- picks up (half-stack) for the advanced drag/split/rearrange system.
        if button == 3 then pickupFrom(idx, button) elseif s.el then assignHotbar(s.el) end
      else dropHandInto(idx, button) end
      return
    end
  end
end

-- ================================================================ bag: RECIPES tab
local function recipeLayoutMetrics()
  local x0, y0 = BPX + 10, BPY + 26
  local chipBottom = forEachMatChip(x0, y0 + 12, BPW - 20, function() end)
  local rowsTop = chipBottom + 16
  local rows = buildCraftRows(U.filterMat)
  local maxRows = math.max(1, floor((BPY + BPH - 40 - rowsTop) / 26))
  return x0, rowsTop, maxRows, rows
end
local X5_W = 26
local function drawBagRecipesTab()
  local x0, y0 = BPX + 10, BPY + 26
  graphics.drawText(x0, y0, "Filter by material - click a chip to toggle:", 255, 220, 80, 255)
  forEachMatChip(x0, y0 + 12, BPW - 20, function(m, mx, my, w, h)
    local sel = (U.filterMat == m); local r, g, b = R.colourOf(m)
    graphics.fillRect(mx, my, w, h, sel and 70 or 26, sel and 74 or 30, sel and 40 or 46, 255)
    graphics.drawRect(mx, my, w, h, sel and 255 or 90, sel and 220 or 90, sel and 80 or 100, 255)
    graphics.fillRect(mx + 2, my + 2, 8, 8, r, g, b, 255)
    local nm = niceName(m)
    graphics.drawText(mx + 12, my + 1, nm, sel and 255 or 190, sel and 230 or 190, sel and 120 or 200, 255)
    graphics.drawText(mx + 12 + textW(nm) + 4, my + 1, m, sel and 170 or 110, sel and 170 or 110, sel and 130 or 120, 255)
  end)
  local x0b, rowsTop, maxRows, rows = recipeLayoutMetrics()
  graphics.drawText(x0, rowsTop - 14, U.filterMat and ("Recipes needing " .. niceName(U.filterMat) .. " - click the chip again to clear") or "All recipes - click a row to craft x1, or the x5 button", 200, 220, 255, 255)
  U.craftScroll = math.max(0, math.min(math.max(0, #rows - maxRows), U.craftScroll))
  local hoverRow
  for i = 1, maxRows do
    local r = rows[i + U.craftScroll]; if not r then break end
    local y = rowsTop + (i - 1) * 26
    if r.header then
      graphics.fillRect(x0 - 2, y, BPW - 24, 13, 40, 44, 80, 255)
      graphics.drawText(x0, y + 1, r.header, r.okst and 255 or 170, r.okst and 220 or 170, r.okst and 80 or 170, 255)
    else
      local rowRight = BPX + BPW - 10 - (r.kind == "recipe" and (X5_W + 4) or 0)
      local hov = R.mouse.x >= x0 and R.mouse.x < rowRight and R.mouse.y >= y and R.mouse.y < y + 24
      if hov then graphics.fillRect(x0 - 2, y - 1, BPW - 24, 24, 60, 64, 100, 255); hoverRow = r end
      local cr, cg, cb = 150, 150, 150
      if r.ok then cr, cg, cb = 140, 255, 140 elseif r.dim then cr, cg, cb = 100, 100, 110 end
      if r.have then cr, cg, cb = 255, 220, 80 end
      graphics.drawText(x0, y + 1, (r.have and "* " or "") .. r.label, cr, cg, cb, 255)
      local ix = x0 + 150
      local needList = {}; for el, n in pairs(r.need) do needList[#needList + 1] = { el, n } end
      table.sort(needList, function(a, b) return a[1] < b[1] end)
      for _, p in ipairs(needList) do
        local el, n = p[1], p[2]; local rr, gg, bb = R.colourOf(el); local have = R.inv(el) >= n
        graphics.fillRect(ix, y + 1, 8, 8, rr, gg, bb, have and 255 or 120)
        local label = n .. " " .. niceName(el)
        graphics.drawText(ix + 10, y, label, have and 200 or 255, have and 200 or 120, have and 210 or 120, 255)
        local codeX = ix + 10 + textW(label) + 4
        graphics.drawText(codeX, y, "(" .. el .. ")", have and 130 or 170, have and 130 or 120, have and 140 or 130, 255)
        ix = codeX + textW("(" .. el .. ")") + 8
      end
      if r.desc then graphics.drawText(x0, y + 13, string.sub(r.desc, 1, 72), 170, 180, 200, 255) end
      if r.kind == "recipe" then
        local bx, by = BPX + BPW - 10 - X5_W, y + 5
        graphics.fillRect(bx, by, X5_W, 14, r.ok and 50 or 34, r.ok and 60 or 34, r.ok and 40 or 40, 255)
        graphics.drawRect(bx, by, X5_W, 14, r.ok and 140 or 90, r.ok and 255 or 90, r.ok and 140 or 100, 255)
        graphics.drawText(bx + 4, by + 2, "x5", r.ok and 220 or 130, r.ok and 255 or 130, r.ok and 220 or 130, 255)
      end
    end
  end
  local upX, upY = BPX + BPW - 42, BPY + BPH - 24
  local dnX, dnY = BPX + BPW - 22, BPY + BPH - 24
  graphics.fillRect(upX, upY, 16, 16, 40, 44, 80, 255); graphics.drawRect(upX, upY, 16, 16, 150, 150, 170, 255); graphics.drawText(upX + 5, upY + 3, "^", 220, 220, 230, 255)
  graphics.fillRect(dnX, dnY, 16, 16, 40, 44, 80, 255); graphics.drawRect(dnX, dnY, 16, 16, 150, 150, 170, 255); graphics.drawText(dnX + 5, dnY + 3, "v", 220, 220, 230, 255)
  graphics.drawText(BPX + 8, BPY + BPH - 22, string.format("%d/%d", math.min(#rows, U.craftScroll + maxRows), #rows), 160, 160, 170, 255)
  if hoverRow then drawCursorTip(hoverRow.label, recipeTooltipLines(hoverRow)) end
end
local function handleBagClickRecipes(x, y)
  local x0, y0 = BPX + 10, BPY + 26
  local clickedMat = false
  forEachMatChip(x0, y0 + 12, BPW - 20, function(m, mx, my, w, h)
    if not clickedMat and x >= mx and x < mx + w and y >= my and y < my + h then
      clickedMat = true; U.filterMat = (U.filterMat == m) and nil or m; U.craftScroll = 0
    end
  end)
  if clickedMat then return end
  local x0b, rowsTop, maxRows, rows = recipeLayoutMetrics()
  local upX, upY = BPX + BPW - 42, BPY + BPH - 24
  local dnX, dnY = BPX + BPW - 22, BPY + BPH - 24
  if x >= upX and x < upX + 16 and y >= upY and y < upY + 16 then U.craftScroll = math.max(0, U.craftScroll - 1); return end
  if x >= dnX and x < dnX + 16 and y >= dnY and y < dnY + 16 then U.craftScroll = math.min(math.max(0, #rows - maxRows), U.craftScroll + 1); return end
  for i = 1, maxRows do
    local r = rows[i + U.craftScroll]; if not r then break end
    local ry = rowsTop + (i - 1) * 26
    if not r.header then
      if r.kind == "recipe" then
        local bx, by = BPX + BPW - 10 - X5_W, ry + 5
        if x >= bx and x < bx + X5_W and y >= by and y < by + 14 then craftMultiple(r, 5); return end
      end
      local rowRight = BPX + BPW - 10 - (r.kind == "recipe" and (X5_W + 4) or 0)
      if x >= x0b and x < rowRight and y >= ry and y < ry + 24 then
        if r.fn then r.fn() end
        return
      end
    end
  end
end

local GUIDE_TAB_X = BPX + 60 + 2 * 70
local function guideAvailable() return type(R.openGuide) == "function" end
local function drawBagPanel()
  graphics.fillRect(BPX, BPY, BPW, BPH, 14, 16, 32, 245); graphics.drawRect(BPX, BPY, BPW, BPH, 255, 220, 80, 255)
  graphics.fillRect(BPX, BPY, BPW, 18, 40, 44, 80, 255)
  graphics.drawText(BPX + 8, BPY + 5, "BAG", 255, 220, 80, 255)
  local tabs = { { "ITEMS", "items" }, { "RECIPES", "recipes" } }
  for i, t in ipairs(tabs) do
    local tx = BPX + 60 + (i - 1) * 70
    local active = (U.bagTab == t[2])
    graphics.fillRect(tx, BPY + 2, 64, 14, active and 70 or 30, active and 74 or 34, active and 120 or 50, 255)
    graphics.drawText(tx + 6, BPY + 5, t[1], active and 255 or 180, active and 230 or 180, active and 120 or 190, 255)
  end
  do  -- GUIDE button: not a real tab, closes the bag and opens guide.lua's own UI
    local avail = guideAvailable()
    graphics.fillRect(GUIDE_TAB_X, BPY + 2, 64, 14, avail and 30 or 20, avail and 34 or 20, avail and 50 or 24, 255)
    graphics.drawText(GUIDE_TAB_X + 4, BPY + 5, "GUIDE(L)", avail and 200 or 100, avail and 220 or 100, avail and 230 or 105, 255)
    if R.mouse.x >= GUIDE_TAB_X and R.mouse.x < GUIDE_TAB_X + 64 and R.mouse.y >= BPY + 2 and R.mouse.y < BPY + 16 and not avail then
      drawCursorTip("Guide", { "Not loaded yet - press L" })
    end
  end
  graphics.drawText(BPX + BPW - 96, BPY + 5, "E / Esc closes", 190, 190, 200, 255)
  if U.bagTab == "items" then drawBagItemsTab() else drawBagRecipesTab() end
end
local function handleBagClick(x, y, button)
  if button ~= 1 and button ~= 3 then return end
  if y >= BPY + 2 and y < BPY + 16 then
    if x >= BPX + 60 and x < BPX + 124 then U.bagTab = "items"; return end
    if x >= BPX + 130 and x < BPX + 194 then U.bagTab = "recipes"; return end
    if x >= GUIDE_TAB_X and x < GUIDE_TAB_X + 64 then
      if guideAvailable() then closeAllPanels(); pcall(R.openGuide) else R.say("Guide not loaded yet - press L") end
      return
    end
    return
  end
  if U.bagTab == "items" then handleBagClickItems(x, y, button)
  elseif button == 1 then handleBagClickRecipes(x, y) end
end

-- ================================================================ quest log (J)
local QUEST_HINTS = {
  wood = "Trees grow on the surface in every biome except desert. Equip the axe (slot 2) and hold left mouse on a trunk or leaves.",
  bench = "Open your bag (E), craft a Workbench for 10 WOOD, put it in a block slot, then hold right mouse to place it.",
  pick = "Stand near your placed Workbench, open the bag's RECIPES tab, and craft the stone pick (6 GRNT + 4 WOOD).",
  coal = "Coal looks like black speckled seams a little underground - dig down from the surface with the pick.",
  furnace = "Craft a Furnace kit at the Workbench (20 GRNT + 5 COAL), place it, then aim the torch (slot 4) at the coal inside to light it.",
  iron = "Iron ore is grey-flecked rock found deeper than coal. Smelt it 2-at-a-time into bars at a LIT furnace.",
  anvil = "Craft an Anvil (8 iron bars) at the Workbench and place it nearby.",
  ironpick = "Stand near both the Workbench and Anvil, then forge the iron pick in RECIPES (5 iron bars + 4 wood).",
  chest = "Chests hide in caves as small brown boxes with a gold latch - dig into open cave systems to find one.",
  deep = "Keep digging or exploring caves - 50m underground is well past the first coal/iron layer.",
  steel = "Smelt steel (2 iron bars + 1 coal) at a lit furnace, then forge the steel pick at the anvil.",
}
local function drawQuestPanel()
  graphics.fillRect(BPX, BPY, BPW, BPH, 14, 16, 32, 245); graphics.drawRect(BPX, BPY, BPW, BPH, 255, 220, 80, 255)
  graphics.fillRect(BPX, BPY, BPW, 18, 40, 44, 80, 255)
  graphics.drawText(BPX + 8, BPY + 5, "QUEST LOG", 255, 220, 80, 255)
  graphics.drawText(BPX + BPW - 96, BPY + 5, "J / Esc closes", 190, 190, 200, 255)
  local y = BPY + 26
  for i, q in ipairs(R.QUESTS) do
    if y > BPY + BPH - 14 then graphics.drawText(BPX + 8, y, "...", 150, 150, 160, 255); break end
    local locked = i > R.quest
    local state, col
    if i < R.quest then state, col = "DONE", { 120, 220, 120 }
    elseif i == R.quest then local ok, d = pcall(q.done); state, col = (ok and d) and "READY!" or "CURRENT", (ok and d) and { 255, 230, 120 } or { 255, 220, 80 }
    else state, col = "LOCKED", { 100, 100, 112 } end
    graphics.drawText(BPX + 8, y, string.format("%d. [%s]", i, state), col[1], col[2], col[3], 255)
    graphics.drawText(BPX + 96, y, q.txt, locked and 120 or 220, locked and 120 or 220, locked and 130 or 230, 255)
    y = y + 13
    if not locked then
      local rw = {}; for el, n in pairs(q.reward or {}) do rw[#rw + 1] = n .. " " .. niceName(el) end; table.sort(rw)
      graphics.drawText(BPX + 96, y, "Reward: " .. table.concat(rw, ", "), 160, 200, 160, 255); y = y + 13
      local hint = QUEST_HINTS[q.id]
      if hint then for _, ln in ipairs(wrapText(hint, 66)) do graphics.drawText(BPX + 96, y, ln, 150, 170, 220, 255); y = y + 12 end end
    end
    y = y + 6
  end
end

-- ================================================================ controls card (C)
local CX, CY, CW, CH = 100, 50, 412, 280
local CONTROLS = {
  "MOVE       A / D walk    W jump (hold longer = higher)    S drop through / sink in water    Space pauses",
  "TOOLS      1 pick  2 axe  3 sword  4 torch  5 bucket - hold LEFT mouse to use",
  "BLOCKS     6-0 = carried materials - hold LEFT mouse to place    [ ] brush size    B snap grid",
  "SELECT     number keys 1-0, or mouse wheel to switch hotbar slot",
  "MENUS      E bag + recipe book     J quest log     C this card     Esc pause menu",
  "BAG        click a slot to send it straight to the selected hotbar slot; R-click/drag to pick up",
  "BAG        SHIFT+click or hover + 6-0 sends an item straight to that hotbar slot; SORT/search/DEL in the bag",
  "VIEW       Z zoom (move, click to lock, Z to close) - inside: 1px precision, wheel = brush size",
  "WORLD      M minimap    N enemies on/off    H toggle HUD    K save    R respawn",
  "ITEMS      chests in caves hold accessories - X mirror-home, G grapple, double jump, rocket boots...",
}
local function drawControlsCard()
  graphics.fillRect(CX, CY, CW, CH, 14, 16, 32, 248); graphics.drawRect(CX, CY, CW, CH, 120, 200, 255, 255)
  graphics.fillRect(CX, CY, CW, 18, 40, 60, 90, 255)
  graphics.drawText(CX + 8, CY + 5, "CONTROLS", 140, 220, 255, 255)
  graphics.drawText(CX + CW - 96, CY + 5, "C / Esc closes", 190, 190, 200, 255)
  for i, line in ipairs(CONTROLS) do graphics.drawText(CX + 10, CY + 28 + (i - 1) * 16, line, 210, 220, 230, 255) end
end

-- ================================================================ crate quick actions (Q/F while a crate panel from
-- machines.lua is open) - machines.lua's own mousedown hook consumes every click unconditionally while R.cratePanel
-- is set (checked: it runs before ours and returns true regardless of click position), so real clickable "quick
-- stack"/"take all" buttons aren't reachable from here; these are keyboard equivalents instead. Purely additive -
-- reads/writes R.cratePanel.items and R.inventory, doesn't touch machines.lua.
local function crateQuickStack()
  local m = R.cratePanel; if not m then return end
  local moved = 0
  for el in pairs(m.items) do
    local have = R.inv(el)
    if have > 0 then m.items[el] = (m.items[el] or 0) + have; R.inventory[el] = 0; moved = moved + have end
  end
  R.rebuildHotbar(); R.say(moved > 0 and ("Quick-stacked " .. moved .. " items into the crate") or "Nothing matching to quick-stack")
end
local function crateTakeAll()
  local m = R.cratePanel; if not m then return end
  local moved = 0
  for el, n in pairs(m.items) do if n > 0 then R.give(el, n); moved = moved + n end end
  m.items = {}
  R.rebuildHotbar(); R.say(moved > 0 and ("Took " .. moved .. " items from the crate") or "Crate is empty")
end

-- ================================================================ hooks
hook(R.hooks.key, function(k, shift, ctrl, alt)
  if type(shift) == "boolean" then U.shiftHeld = shift end

  if U.bagOpen and U.searchFocused then
    if k == "escape" or k == "13" or k == "10" then U.searchFocused = false; return true end
    if k == "8" then U.searchText = U.searchText:sub(1, -2); return true end
    if k == "space" then U.searchText = U.searchText .. " "; return true end
    if type(k) == "string" and #k == 1 and (k:match("%a") or k:match("%d")) then U.searchText = U.searchText .. k; return true end
    return true
  end

  if U.bagOpen and U.hoverAssignEl then
    local d = tonumber(k)
    if d then local slotN = (d == 0) and 10 or d
      if slotN >= 6 then assignHotbar(U.hoverAssignEl, slotN); return true end
    end
  end

  if R.cratePanel then
    if k == "q" then crateQuickStack(); return true end
    if k == "f" then crateTakeAll(); return true end
  end

  if k == "e" then
    if U.bagOpen then closeAllPanels() else openPanel("bagOpen"); U.everOpenedBag = true end
    return true
  end
  if k == "j" then
    if U.questOpen then closeAllPanels() else openPanel("questOpen"); U.everOpenedQuest = true end
    return true
  end
  if k == "c" then
    if U.controlsOpen then closeAllPanels() else openPanel("controlsOpen"); U.everOpenedControls = true end
    return true
  end
  if k == "escape" then
    if U.bagOpen or U.questOpen or U.controlsOpen then closeAllPanels(); return true end
    return
  end
  return
end)

-- core now hooks keyup too (same key names as key) - use it to clear shift promptly instead of the old
-- "goes stale until the next unrelated keydown" workaround.
hook(R.hooks.keyup, function(k)
  if k == "1073742049" or k == "1073742053" then U.shiftHeld = false end
end)

hook(R.hooks.mousedown, function(x, y, button)
  if U.bagOpen then
    if U.hand and not U.hand.isAcc then
      local hs = hotbarSlotAt(x, y)
      if hs and hs >= 6 then assignHotbar(U.hand.el, hs); U.hand = false; return true end
    end
    handleBagClick(x, y, button); return true
  end
  if U.questOpen or U.controlsOpen then return true end
  return
end)
hook(R.hooks.mouseup, function(x, y, button)
  if U.bagOpen and U.hand and U.hand.isAcc then
    local accY = BPY + BPH - ITEMS_BOTTOM_RESERVE + 16
    local where = accHitAt(ITEMS_X0, accY, ITEMS_W, x, y)
    if where == "equip" then if not accLive(U.hand.key) then toggleAcc(U.hand.key) end
    else if accLive(U.hand.key) then toggleAcc(U.hand.key) end end
    U.hand = false
    return true
  end
  if U.bagOpen and U.hand and U.pickedThisPress then
    local rows = itemsVisibleRows()
    if U.itemsSub ~= "catalog" and x >= ITEMS_X0 and x < ITEMS_X0 + ITEMS_W and y >= ITEMS_Y0 and y < ITEMS_Y0 + rows * ITEMS_ROWH then
      local row = floor((y - ITEMS_Y0) / ITEMS_ROWH) + 1
      local vis = visibleCarriedSlots(); local idx = vis[row + (U.itemsScroll or 0)]
      if idx and idx ~= U.hand.originIdx then dropHandInto(idx, button) end
    elseif x >= TRASH_X and x < TRASH_X + TRASH_W and y >= CTRL_Y and y < CTRL_Y + 13 then
      trashHand(button)
    else
      local hs = hotbarSlotAt(x, y)
      if hs and hs >= 6 then assignHotbar(U.hand.el, hs); U.hand = false end
    end
  end
  U.pickedThisPress = false
  if U.bagOpen or U.questOpen or U.controlsOpen then return true end
  return
end)

hook(R.hooks.tick, function()
  R.uiPanelOpen = U.bagOpen or U.questOpen or U.controlsOpen or false
  if U.bagOpen or U.questOpen or U.controlsOpen then R.mouse.l = false; R.mouse.r = false end
  if R.hint and type(R.hint) == "string" and R.hint:sub(1, 7) == "placed " then U.everPlaced = true end
end)

hook(R.hooks.mine, function(el, n)
  U.everMined = true
  if n and n > 0 then
    U.floaters[#U.floaters + 1] = { text = "+" .. n .. " " .. niceName(el), x = R.P.x, y = R.P.y - 14, born = R.frame or 0 }
    if #U.floaters > 10 then table.remove(U.floaters, 1) end
  end
end)

hook(R.hooks.draw, function() drawFloaters() end)

hook(R.hooks.drawHUD, function()
  drawVignette()
  drawCompass()
  drawFurnaceIndicator()
  if U.bagOpen then drawBagPanel(); drawHandCursor()
  elseif U.questOpen then drawQuestPanel()
  elseif U.controlsOpen then drawControlsCard()
  else
    drawOnboardingTips()
    local slot = hotbarSlotAt(R.mouse.x, R.mouse.y)
    if slot then
      local v = R.hotbar[slot]
      if v then
        if v:find("^tool:") then local key = v:sub(6); drawCursorTip((R.TOOLS[key] and R.TOOLS[key].name) or key, toolTooltipLines(key))
        else drawCursorTip(niceName(v), itemTooltipLines(v)) end
      end
    else
      local pel = paletteSlotAt(R.mouse.x, R.mouse.y)
      if pel then drawCursorTip(niceName(pel), itemTooltipLines(pel))
      elseif not R.fine and not R.zoomPending and R.mouse.y > 16 and R.mouse.y < H - 45 then
        -- World hover tooltip: name + real temperature of whatever's under the
        -- cursor, requested as its own always-available readout, not just
        -- something buried in a menu.
        local wp = sim.partID(R.mouse.x, R.mouse.y)
        if wp then
          local nm = R.nameOf(sim.partProperty(wp, "type"))
          local tempK = sim.partProperty(wp, "temp") or 295
          local tempF = (tempK - 273.15) * 9 / 5 + 32
          local ok, pr = pcall(sim.pressure, floor(R.mouse.x / sim.CELL), floor(R.mouse.y / sim.CELL))
          drawCursorTip(niceName(nm), { string.format("%.0f F", tempF), "Pressure: " .. string.format("%.1f", ok and pr or 0) }, 110)
        end
      end
    end
  end
  if R.cratePanel then
    graphics.drawText(190, 56 - 12, "ui.lua: Q = quick-stack matching items into crate, F = take all", 140, 220, 255, 255)
  end
end)
-- Mouse wheel scrolling for the bag panel -- was click-the-tiny-arrow-button only,
-- a real, reported UX complaint ("really lame... do good UI for that").
if R.hooks.wheel then
  hook(R.hooks.wheel, function(x, y, d)
    if not U.bagOpen then return end
    if U.bagTab == "items" then
      local rows = itemsVisibleRows()
      local list = (U.itemsSub == "catalog") and fullCatalog() or visibleCarriedSlots()
      U.itemsScroll = math.max(0, math.min(math.max(0, #list - rows), (U.itemsScroll or 0) - d))
    elseif y >= BPY + 20 and y < BPY + 55 then   -- over the material filter-chip strip
      local maxScroll = math.max(0, (U.matChipRows or 1) - 2)
      U.matChipScroll = math.max(0, math.min(maxScroll, (U.matChipScroll or 0) - d))
    else
      local _, _, maxRows, rows = recipeLayoutMetrics()
      U.craftScroll = math.max(0, math.min(math.max(0, #rows - maxRows), (U.craftScroll or 0) - d))
    end
    return true   -- consume so it never leaks through to hotbar-select while the bag is open
  end)
end
