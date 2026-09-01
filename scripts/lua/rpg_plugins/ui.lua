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
  shiftHeld = false, hoverAssignEl = nil, catCollapsed = {}, catalogCollapsed = {}, chainFor = nil, onlyCraftable = false,
  everMined = false, everPlaced = false, everOpenedBag = false, everOpenedQuest = false, everOpenedControls = false,
  submitMode = nil, submitDragging = false, submitDragStart = nil, submitStamp = nil,
  submitContext = "", submitContextFocused = false, submitCatIdx = 1,
  -- discoverability pass (PhoenixFire808, 3x escalating: "super, super important" -> "easily
  -- submit" -> "EXTREMELY PROMINENT"): persistent hotbar-side button, session submission
  -- history so the channel doesn't feel like a void, and one-time contextual nudges.
  submitHistory = {}, submitHistoryOpen = false, everSubmitted = false,
  craftNudgeShown = false, deathNudgeShown = false, lastDeaths = 0,
  submitConfirmAt = nil, submitConfirmText = nil, submitConfirmFailed = false,
}
local U = R.ui
-- R.ui survives hot-reload (it's on the persistent R table), so a field only added to the
-- literal above never appears on an already-live table -- must also migrate it here.
U.catalogCollapsed = U.catalogCollapsed or {}
U.submitHistory = U.submitHistory or {}
if U.submitConfirmFailed == nil then U.submitConfirmFailed = false end
R.uiPanelOpen = U.bagOpen or U.questOpen or U.controlsOpen or false

-- ================================================================ icon draw (defensive against @icons_engine)
-- Every place this file used to draw a flat R.colourOf() swatch now goes through here instead.
-- R.icon.draw(id, x, y, size[, alpha]) is @icons_engine's contract (rpg_plugins/icons.lua, built
-- in parallel this wave) -- when it lands, every one of these call sites lights up as a real
-- procedural icon with ZERO further edits here. Until then (or if a draw call errors), the
-- pcall falls through to the original flat-colour swatch so this file ships and looks correct
-- standalone. Never call graphics.* directly for a material/item swatch anywhere else in this
-- file -- always through drawMatIcon, so the whole UI upgrades in one place.
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
  BSLT  = { nice = "Granite",          desc = "Hard grey rock. Main ingredient for the Workbench-tier Furnace and a strong building block." },
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
  local x, y, w, h = W - 110, 100, 104, 34
  graphics.fillRect(x, y, w, h, 0, 0, 0, 170); graphics.drawRect(x, y, w, h, 120, 124, 150, 200)
  local depth = floor((R.P.y - R.surfaceAt(floor(R.P.x))) / 4)
  local dtxt = depth > 0 and (depth .. "m deep") or (depth < 0 and ((-depth) .. "m up") or "surface")
  graphics.drawText(x + 4, y + 2, dtxt, 190, 200, 255, 255)
  local maxd = math.max(1, floor((R.DEPTH or 1900) / 4)); local frac = math.max(0, math.min(1, depth / maxd))
  graphics.fillRect(x + 4, y + 16, 96, 4, 40, 40, 50, 255); graphics.fillRect(x + 4, y + 16, floor(96 * frac), 4, 220, 160, 60, 255)
  graphics.drawText(x + 4, y + 24, "depth", 140, 150, 165, 200)
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
  { id = "submit", text = "Press Y (or click the flag icon by your hotbar) to submit a build, bug, or idea to PhoenixFire808.", done = function() return U.everSubmitted end },
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
-- the owner, four separate times, on this one panel: "the filter by materials thing takes up
-- half the space", "trying to figure out how to make the next item and it's all confusing",
-- and finally "I would prefer in the crafting menu to be actually broken down into their
-- useful categories". It was grouped by crafting STATION -- which answers "where do I make
-- this", an implementation detail -- instead of "what am I trying to make". Grouped by
-- purpose now; the station still gates crafting and is still shown per row, it is just no
-- longer the organising axis. Categories derived from the real 121-entry recipe list.
local RECIPE_CAT = {
  WORKBENCH="Stations", FURNACE="Stations", ANVIL="Stations", RESEARCH="Stations", ADVLAB="Stations",
  FLASK="Survival Gear", OXYTANK="Survival Gear", DIVEHELMET="Survival Gear", GASMASK="Survival Gear",
  CLIMBGLOVES="Survival Gear", BALLOON="Survival Gear", WARMCOAT="Survival Gear", COOLSUIT="Survival Gear",
  CANTEEN="Survival Gear", JETPACK="Survival Gear", BED="Survival Gear",
  SOIL="Food & Farming", ALGAETANK="Food & Farming", CFISH="Food & Farming", CMSHRM="Food & Farming",
  STEW="Food & Farming", BREAD="Food & Farming", BOILEDWATER="Food & Farming",
  METL="Materials", STEL="Materials", BRCK="Materials", GLAS="Materials", GOLD="Materials", CU="Materials",
  INSL="Materials", TTAN="Materials", PSCN="Materials", ZIRC="Materials", GRPH="Materials", NAK="Materials",
  LEAD="Materials", CNCR="Materials", UO2="Materials", B4C="Materials", TRBN="Materials", TEG="Materials",
  LEDL="Materials", WIFI="Materials", ACID="Materials",
  BOILER="Power", TURBINE="Power", CRANKKIT="Power", WHEELKIT="Power", SOLARKIT="Power", TEGKIT="Power",
  WINDKIT="Power", SOLARFURNACEKIT="Power", WIRECOIL="Power",
  BELLOWSKIT="Life Support", AIRLINEKIT="Life Support", FLAREKIT="Life Support", CRYOKIT="Life Support",
  GASDETECTORKIT="Life Support", ELECTROLYSISKIT="Life Support", LEADSHIELDKIT="Life Support",
  PUMPKIT="Fluids & Processing", CHECKVALVEKIT="Fluids & Processing", PRESSVESSELKIT="Fluids & Processing",
  RESERVOIRKIT="Fluids & Processing", CONDENSERKIT="Fluids & Processing", SUMPKIT="Fluids & Processing",
  EVAPORATORKIT="Fluids & Processing", ACIDSYNTHKIT="Fluids & Processing", FERTMIXERKIT="Fluids & Processing",
  POWDERMILLKIT="Fluids & Processing",
  CONVEYOR="Logistics & Storage", CRATE="Logistics & Storage", SORTERKIT="Logistics & Storage",
  SPLITTERKIT="Logistics & Storage", VACUUMKIT="Logistics & Storage", SILOKIT="Logistics & Storage",
  RAILKIT="Logistics & Storage", MINECARTKIT="Logistics & Storage", HANDCARKIT="Logistics & Storage",
  TRAINSTOPKIT="Logistics & Storage", WAGONKIT="Logistics & Storage", QUARRYKIT="Logistics & Storage",
  LAMPKIT="Building & Utility", DOORKIT="Building & Utility", LIGHTRAILKIT="Building & Utility",
  CAMERAKIT="Building & Utility", SIGNPOSTKIT="Building & Utility", GATEKIT="Building & Utility",
  DECOPANELKIT="Building & Utility",
  GRAVMANIPKIT="Exotic", PORTALKIT="Exotic", MAGACCELKIT="Exotic", WEATHERKIT="Exotic", TPWAND="Exotic",
  DRILL="Tools", MAGNET="Tools",
  MUSKET="Weapons", SHOTGUN="Weapons", GRENADE="Weapons", LIGHTGUN="Weapons", FLAMETH="Weapons",
  WATERGUN="Weapons", ACIDGUN="Weapons", FREEZERAY="Weapons", LASERGUN="Weapons", RAILGUN="Weapons",
  PLASMATORCH="Weapons", NAILGUN="Weapons", BOW="Weapons", BOOMERANG="Weapons", HARPOON="Weapons",
  ARROW="Weapons", C4CHARGE="Weapons", STICKYBOMB="Weapons", CRYOGRENADE="Weapons", DYNAMITE="Weapons",
  SMOKEBOMB="Weapons", LAVABUCKET="Weapons", ["C-4"]="Weapons",
  -- machines.lua:2420-2484 kits never got folded in here (30 kits, caught by a scope audit against
  -- the real recipe list) - fell back to "Materials" via catalogCat()'s default, which for a "power"
  -- or "life support" kit defeats the whole point of grouping by what it's for.
  BATTERYKIT="Power", BREAKERKIT="Power", CAPACITORKIT="Power", FLYWHEELKIT="Power", FUELCELLKIT="Power",
  GASTURBINEKIT="Power", GEOTAPKIT="Power", LIGHTNINGKIT="Power", REACTORKIT="Power", RTGKIT="Power",
  AIRPUMPKIT="Life Support", LIFESUPPORTKIT="Life Support", O2GENKIT="Life Support", SCRUBBERKIT="Life Support",
  VENTFANKIT="Life Support",
  COMPRESSORKIT="Fluids & Processing", CRUSHERKIT="Fluids & Processing", DESALKIT="Fluids & Processing",
  METHANECAPKIT="Fluids & Processing", SAWMILLKIT="Fluids & Processing",
  BLASTFURNACEKIT="Stations", EFURNACE="Stations",
  AUTOCRAFTKIT="Logistics & Storage", ELEVATORKIT="Logistics & Storage", TUNNELERKIT="Logistics & Storage",
  DRILLKIT="Tools",
  GREENHOUSEKIT="Food & Farming", SPRINKLERKIT="Food & Farming",
  TURRETKIT="Weapons", TURRETKIT2="Weapons",
}
local CAT_ORDER = { "Tools", "Weapons", "Survival Gear", "Food & Farming", "Stations", "Materials",
  "Power", "Life Support", "Fluids & Processing", "Logistics & Storage", "Building & Utility",
  "Exotic", "Other" }
local function buildCraftRows(filter)
  local byCat, stOk = {}, {}
  for _, stk in ipairs({ "hand", "workbench", "furnace", "anvil", "research", "advlab" }) do
    stOk[stk] = R.nearStation(stk)
  end
  local function mk(kind, label, need, stk, desc, have, fn, outid)
    if filter and not need[filter] then return end
    local okst = stOk[stk]
    local ok = okst and canAfford(need)
    -- "what can I make next" is his most repeated version of the complaint, so this
    -- toggle hides everything you cannot craft right now rather than making him scan.
    if U.onlyCraftable and not ok then return end
    local cat = RECIPE_CAT[outid or ""] or (kind == "pick" and "Tools") or (kind == "sword" and "Weapons") or "Other"
    byCat[cat] = byCat[cat] or {}
    local t = byCat[cat]
    t[#t + 1] = { kind = kind, label = label, need = need, ok = ok, dim = not okst, desc = desc,
      st = stk, have = have, fn = fn, gate = (not okst) and (R.STATIONS[stk] or stk) or nil, out = outid }
  end
  for k, rc in ipairs(R.RECIPES) do
    mk("recipe", rc.n .. " " .. rc.txt, rc.need, rc.st or "hand", rc.desc, nil, function() R.craft(k) end, rc.out)
  end
  for k, t in ipairs(R.PICKS) do
    mk("pick", t.name, t.need, t.st or "hand", t.desc, (R.TOOLS.pick.name == t.name), function() R.craftPick(k) end, nil)
  end
  for k, t in ipairs(R.SWORDS) do
    mk("sword", t.name, t.need, t.st or "hand", t.desc, (R.TOOLS.sword.name == t.name), function() R.craftSword(k) end, nil)
  end
  -- "we want drop-down menus, and a really easy to navigate tree for functional stuff
  -- like oxygen generation". Two parts: categories collapse so the panel opens compact
  -- instead of as one long wall, and any recipe you cannot make yet can expand its
  -- PREREQUISITE CHAIN in place. The chain is derived from the recipe data itself
  -- (need tables + station gates), not hand-authored, so it cannot drift from reality.
  local outIdx = {}
  for k, rc in ipairs(R.RECIPES) do if rc.out and not outIdx[rc.out] then outIdx[rc.out] = k end end
  local function addChain(need, depth, seen, acc)
    if depth > 3 then return end
    local list = {}
    for el, n in pairs(need) do list[#list + 1] = { el, n } end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    for _, pr in ipairs(list) do
      local el, n = pr[1], pr[2]
      local have = R.inv(el)
      if have < n then
        local k = outIdx[el]
        local rc = k and R.RECIPES[k]
        local stk = rc and (rc.st or "hand")
        local okst = stk and stOk[stk]
        local craftable = rc and okst and canAfford(rc.need) or false
        local status
        if not rc then status = "gather " .. (n - have) .. " more"
        elseif not okst then status = "needs " .. (R.STATIONS[stk] or stk)
        elseif craftable then status = "craftable now - click to make it"
        else status = "make its parts first" end
        acc[#acc + 1] = { chain = true, depth = depth, ok = craftable,
          label = string.format("%d/%d %s", have, n, niceName(el)), status = status,
          fn = craftable and function() R.craft(k) end or nil }
        if rc and not seen[el] then
          seen[el] = true
          addChain(rc.need, depth + 1, seen, acc)
        end
      end
    end
  end
  local rows = {}
  for _, cat in ipairs(CAT_ORDER) do
    local group = byCat[cat]
    if group and #group > 0 then
      table.sort(group, function(a, b) return (a.ok and 1 or 0) > (b.ok and 1 or 0) end)
      local n = 0
      for _, g in ipairs(group) do if g.ok then n = n + 1 end end
      -- default collapsed: he asked for the panel to be straightforward, and 121 recipes
      -- expanded at once is the wall of text he has complained about five times.
      if U.catCollapsed[cat] == nil then U.catCollapsed[cat] = true end
      local shut = U.catCollapsed[cat]
      rows[#rows + 1] = { header = (shut and "[+] " or "[-] ") .. cat:upper() .. "   " .. n .. " of " .. #group .. " craftable now",
        cat = cat, okst = n > 0 }
      if not shut then
        for _, r in ipairs(group) do
          rows[#rows + 1] = r
          if U.chainFor == r.label then
            addChain(r.need, 1, {}, rows)
          end
        end
      end
    end
  end
  return rows
end
-- one shared walk so the draw pass and the click pass can never disagree about which
-- row is at which y -- rows are variable height now (chain rows are half-height).
local function rowHeight(r) return r.chain and 13 or (r.header and 15 or 26) end
local function visibleRecipeRows(rowsTop, rows, bottom)
  local out, y = {}, rowsTop
  for i = (U.craftScroll or 0) + 1, #rows do
    local r = rows[i]
    local h = rowHeight(r)
    if y + h > bottom then break end
    out[#out + 1] = { r = r, y = y, h = h }
    y = y + h
  end
  return out
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
  -- Layout only -- no drawing here. This function is also called from the CLICK handler
  -- (handleBagClickRecipes -> recipeLayoutMetrics) to work out row positions, and a
  -- graphics call outside a draw event raises "this functionality is restricted to
  -- graphics events". The overflow hint is drawn by the draw-path caller instead.
  U.matChipOverflow = U.matChipRows > visRows
  return math.min(my - scroll * 14, maxRowY) + 14
end

-- ================================================================ inventory slots: sync, pickup/drop, sort, search, trash
local function syncInvSlots()
  R.invSlots = R.invSlots or {}   -- defensive: core resets this per-world, don't hard-crash (silently, into R.pluginErr) if it's ever nil again
  -- The bag grid is a FIXED 60 cells (N_SLOTS) and invSlotAtGridPos hands back any slot in
  -- 1..60, but the reconciliation below only ever APPENDS slots as items appear. The one-time
  -- pre-fill at load (line ~31) does not survive a new world, because core resets
  -- R.invSlots = {} on regen and nothing re-pads it -- so with 3 items carried the draw asked
  -- for slots 4..60 and indexed nil ("attempt to index local 's'"). Pad here instead: this
  -- runs every draw, so the fixed-size invariant the grid already assumes is now actually
  -- guaranteed for every consumer (draw, hover, click-to-drop, sort, trash) rather than
  -- guarded one read site at a time.
  for i = 1, N_SLOTS do R.invSlots[i] = R.invSlots[i] or { el = false, n = 0 } end
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
  local merged = {}
  for _, s in ipairs(R.invSlots) do
    if s.el and s.n > 0 then merged[s.el] = (merged[s.el] or 0) + s.n end
  end
  local items = {}
  for el, n in pairs(merged) do items[#items + 1] = { el = el, n = n } end
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
  U.bagOpen, U.questOpen, U.controlsOpen, U.submitHistoryOpen = false, false, false, false
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
local GRID_COLS, CELL, GAP = 10, 28, 2
local function invGridRowH() return CELL + GAP end
local function invGridTotalRows() return math.ceil(N_SLOTS / GRID_COLS) end
local function invGridVisibleRows() return math.max(1, floor((BPY + BPH - ITEMS_BOTTOM_RESERVE - ITEMS_Y0) / invGridRowH())) end
local function invCellOrigin(col, visRow)
  return ITEMS_X0 + col * (CELL + GAP), ITEMS_Y0 + visRow * invGridRowH()
end
local function invSlotAtGridPos(gridRow, col)
  local slot = gridRow * GRID_COLS + col + 1
  if slot < 1 or slot > N_SLOTS then return nil end
  return slot
end
local function invCellAt(mx, my)
  local rowH = invGridRowH()
  local visRows = invGridVisibleRows()
  if mx < ITEMS_X0 or my < ITEMS_Y0 or my >= ITEMS_Y0 + visRows * rowH then return nil end
  local visRow = floor((my - ITEMS_Y0) / rowH)
  local gridRow = (U.itemsScroll or 0) + visRow
  if gridRow >= invGridTotalRows() then return nil end
  local col = floor((mx - ITEMS_X0) / (CELL + GAP))
  if col < 0 or col >= GRID_COLS then return nil end
  local cx, cy = invCellOrigin(col, visRow)
  if mx < cx or mx >= cx + CELL or my < cy or my >= cy + CELL then return nil end
  return invSlotAtGridPos(gridRow, col)
end
local function drawInvCell(x, y, el, n, hover)
  local fr, fg, fb = hover and 55 or 22, hover and 60 or 24, hover and 90 or 32
  graphics.fillRect(x, y, CELL, CELL, fr, fg, fb, 255)
  graphics.drawRect(x, y, CELL, CELL, hover and 255 or 90, hover and 220 or 90, hover and 80 or 100, 255)
  if el and n and n > 0 then
    drawMatIcon(el, x + 3, y + 3, CELL - 6)
    if n > 1 then
      local txt = tostring(n)
      local tw = textW(txt)
      local bw, bh = tw + 4, 11
      local bx, by = x + CELL - bw - 1, y + CELL - bh - 1
      graphics.fillRect(bx, by, bw, bh, 18, 18, 28, 230)
      graphics.drawRect(bx, by, bw, bh, 100, 100, 120, 255)
      graphics.drawText(bx + 2, by + 1, txt, 255, 255, 255, 255)
    end
    local inbar
    for s = 6, 10 do if R.hotbar[s] == el then inbar = s end end
    if inbar then graphics.drawText(x + 2, y + 1, "[" .. (inbar % 10) .. "]", 255, 220, 80, 255) end
  end
end
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
  local a = n > 0 and 255 or 100
  drawMatIcon(el, x, y + 1, 11, a)
  local nm = niceName(el)
  graphics.drawText(x + 14, y, nm, a, a, a == 255 and 235 or 120, 255)
  local codeX = x + 14 + textW(nm) + 6
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
  drawMatIcon(U.hand.el, x - 5, y - 5, 10); graphics.drawRect(x - 5, y - 5, 10, 10, 255, 255, 255, 220)
  graphics.drawText(x + 7, y - 4, niceName(U.hand.el) .. " x" .. U.hand.n, 255, 240, 200, 255)
  graphics.drawText(x + 7, y + 8, "L place/merge  R place 1  drop on DEL to delete", 170, 190, 220, 255)
end
-- CATALOG sub-tab: raised six times now ("broken down into their useful categories" applied to
-- the reference list too, not just the crafting panel above) -- it was a flat alphabetical dump
-- of every known code with a scrollbar, no grouping at all, the most literal match to "the
-- catalog" in the ask. Reuses RECIPE_CAT so a code's category can never drift between the
-- crafting panel and this list; raw gathered materials/ores that aren't a recipe output (WOOD,
-- ore blocks, ...) fall into "Materials" too -- same "what do I use this for" bucket as the
-- processed materials already grouped there. drawSlotRow's "Name (CODE)" stays untouched --
-- decided, not clutter (decisionLog.md, 2026-08-31 Wood/WOOD).
local function catalogCat(code) return RECIPE_CAT[code] or "Materials" end
local function buildCatalogRows()
  local byCat = {}
  for _, el in ipairs(fullCatalog()) do
    local cat = catalogCat(el)
    byCat[cat] = byCat[cat] or {}
    local t = byCat[cat]; t[#t + 1] = el
  end
  local rows = {}
  for _, cat in ipairs(CAT_ORDER) do
    local group = byCat[cat]
    if group and #group > 0 then
      local owned = 0
      for _, el in ipairs(group) do if R.inv(el) > 0 then owned = owned + 1 end end
      if U.catalogCollapsed[cat] == nil then U.catalogCollapsed[cat] = true end
      local shut = U.catalogCollapsed[cat]
      rows[#rows + 1] = { header = true, cat = cat,
        label = (shut and "[+] " or "[-] ") .. cat:upper() .. "   " .. owned .. " of " .. #group .. " owned" }
      if not shut then
        for _, el in ipairs(group) do rows[#rows + 1] = { el = el } end
      end
    end
  end
  return rows
end
local function catalogRowHeight(r) return r.header and 15 or ITEMS_ROWH end
-- same shared draw/click walk pattern as the recipe panel's visibleRecipeRows, so a click can
-- never land on a different row than the one drawn under the cursor.
local function visibleCatalogRows(rowsTop, rows, bottom)
  local out, y = {}, rowsTop
  for i = (U.itemsScroll or 0) + 1, #rows do
    local r = rows[i]
    local h = catalogRowHeight(r)
    if y + h > bottom then break end
    out[#out + 1] = { r = r, y = y, h = h }
    y = y + h
  end
  return out
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
    graphics.drawText(BPX + 160, BPY + 27, "grouped by what it's for - click a category, or an owned row to assign it", 180, 190, 210, 255)
    local rows = buildCatalogRows()
    local bottom = BPY + BPH - ITEMS_BOTTOM_RESERVE
    U.itemsScroll = math.max(0, math.min(math.max(0, #rows - 1), U.itemsScroll or 0))
    for _, vis in ipairs(visibleCatalogRows(ITEMS_Y0, rows, bottom)) do
      local r, y = vis.r, vis.y
      if r.header then
        local hh = R.mouse.x >= ITEMS_X0 - 2 and R.mouse.x < ITEMS_X0 + ITEMS_W and R.mouse.y >= y and R.mouse.y < y + 13
        graphics.fillRect(ITEMS_X0 - 2, y, ITEMS_W, 13, hh and 58 or 40, hh and 62 or 44, hh and 96 or 80, 255)
        graphics.drawText(ITEMS_X0, y + 1, r.label, 220, 225, 235, 255)
      elseif drawSlotRow(ITEMS_X0, y, ITEMS_W, r.el, R.inv(r.el)) then
        hoverEl = r.el; U.hoverAssignEl = r.el
      end
    end
    local upX, upY = BPX + BPW - 42, ITEMS_Y0 - 16
    local dnX, dnY = BPX + BPW - 22, ITEMS_Y0 - 16
    graphics.fillRect(upX, upY, 16, 13, 40, 44, 80, 255); graphics.drawText(upX + 5, upY + 1, "^", 220, 220, 230, 255)
    graphics.fillRect(dnX, dnY, 16, 13, 40, 44, 80, 255); graphics.drawText(dnX + 5, dnY + 1, "v", 220, 220, 230, 255)
    graphics.drawText(BPX + BPW - 150, ITEMS_Y0 - 14, string.format("%d/%d rows", math.min(#rows, (U.itemsScroll or 0) + 1), #rows), 160, 160, 170, 255)
  else
    syncInvSlots()
    drawSearchSortTrash()
    graphics.drawText(BPX + 160, BPY + 27, "L-click pick/place   shift+L = hotbar   R-click split   drag to move", 170, 185, 210, 255)
    local totalRows = invGridTotalRows()
    local visRows = invGridVisibleRows()
    U.itemsScroll = math.max(0, math.min(math.max(0, totalRows - visRows), U.itemsScroll or 0))
    local hoverSlot = invCellAt(R.mouse.x, R.mouse.y)
    for vr = 0, visRows - 1 do
      local gridRow = (U.itemsScroll or 0) + vr
      if gridRow >= totalRows then break end
      for col = 0, GRID_COLS - 1 do
        local slot = invSlotAtGridPos(gridRow, col)
        if slot then
          local cx, cy = invCellOrigin(col, vr)
          local s = R.invSlots[slot]
          local showEl, showN = false, 0
          if s.el and s.n > 0 and matchesSearch(s.el) then showEl, showN = s.el, s.n end
          -- Empty cells must highlight too: while holding an item you need to see WHERE it can
          -- drop. The old `and showEl` meant only occupied cells ever lit up, so the advertised
          -- "drag to move" had no target feedback at all on the empty slots you actually aim for.
          local hov = hoverSlot == slot
          drawInvCell(cx, cy, showEl, showN, hov)
          if hov then hoverEl = showEl; U.hoverAssignEl = showEl end
        end
      end
    end
    if totalRows > visRows then
      local upX, upY = BPX + BPW - 42, ITEMS_Y0 - 16
      local dnX, dnY = BPX + BPW - 22, ITEMS_Y0 - 16
      graphics.fillRect(upX, upY, 16, 13, 40, 44, 80, 255); graphics.drawText(upX + 5, upY + 1, "^", 220, 220, 230, 255)
      graphics.fillRect(dnX, dnY, 16, 13, 40, 44, 80, 255); graphics.drawText(dnX + 5, dnY + 1, "v", 220, 220, 230, 255)
      graphics.drawText(BPX + BPW - 150, ITEMS_Y0 - 14, string.format("%d/%d", math.min(totalRows, (U.itemsScroll or 0) + visRows), totalRows), 160, 160, 170, 255)
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
    local rows = buildCatalogRows()
    local bottom = BPY + BPH - ITEMS_BOTTOM_RESERVE
    local upX, upY = BPX + BPW - 42, ITEMS_Y0 - 16
    local dnX, dnY = BPX + BPW - 22, ITEMS_Y0 - 16
    if x >= upX and x < upX + 16 and y >= upY and y < upY + 13 then U.itemsScroll = math.max(0, (U.itemsScroll or 0) - 1); return end
    if x >= dnX and x < dnX + 16 and y >= dnY and y < dnY + 13 then U.itemsScroll = math.min(math.max(0, #rows - 1), (U.itemsScroll or 0) + 1); return end
    -- same shared walk the draw pass uses, so a click can never land on a different row
    -- than the one drawn under the cursor.
    for _, vis in ipairs(visibleCatalogRows(ITEMS_Y0, rows, bottom)) do
      local r, ry = vis.r, vis.y
      if r.header then
        if x >= ITEMS_X0 - 2 and x < ITEMS_X0 + ITEMS_W and y >= ry and y < ry + 13 then
          U.catalogCollapsed[r.cat] = not U.catalogCollapsed[r.cat]; U.itemsScroll = 0; return
        end
      elseif x >= ITEMS_X0 and x < ITEMS_X0 + ITEMS_W and y >= ry and y < ry + ITEMS_ROWH then
        if R.inv(r.el) > 0 then assignHotbar(r.el) end
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
  local totalRows = invGridTotalRows()
  local visRows = invGridVisibleRows()
  if totalRows > visRows then
    local upX, upY = BPX + BPW - 42, ITEMS_Y0 - 16
    local dnX, dnY = BPX + BPW - 22, ITEMS_Y0 - 16
    if x >= upX and x < upX + 16 and y >= upY and y < upY + 13 then U.itemsScroll = math.max(0, (U.itemsScroll or 0) - 1); return end
    if x >= dnX and x < dnX + 16 and y >= dnY and y < dnY + 13 then U.itemsScroll = math.min(math.max(0, totalRows - visRows), (U.itemsScroll or 0) + 1); return end
  end
  local idx = invCellAt(x, y)
  if idx then
    local s = R.invSlots[idx]
    if U.shiftHeld and not U.hand and s and s.el and matchesSearch(s.el) then quickMoveToHotbar(s.el)
    elseif U.hand and not U.hand.isAcc then dropHandInto(idx, button)
    elseif not U.hand and s and s.el and matchesSearch(s.el) then pickupFrom(idx, button) end
    return
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
  if U.matChipOverflow then graphics.drawText(x0 + (BPW - 20) - 90, y0, "wheel: more mats", 150, 150, 160, 255) end
  forEachMatChip(x0, y0 + 12, BPW - 20, function(m, mx, my, w, h)
    local sel = (U.filterMat == m)
    graphics.fillRect(mx, my, w, h, sel and 70 or 26, sel and 74 or 30, sel and 40 or 46, 255)
    graphics.drawRect(mx, my, w, h, sel and 255 or 90, sel and 220 or 90, sel and 80 or 100, 255)
    drawMatIcon(m, mx + 2, my + 2, 8)
    local nm = niceName(m)
    graphics.drawText(mx + 12, my + 1, nm, sel and 255 or 190, sel and 230 or 190, sel and 120 or 200, 255)
    graphics.drawText(mx + 12 + textW(nm) + 4, my + 1, m, sel and 170 or 110, sel and 170 or 110, sel and 130 or 120, 255)
  end)
  local x0b, rowsTop, maxRows, rows = recipeLayoutMetrics()
  graphics.drawText(x0, rowsTop - 14, U.filterMat and ("Recipes needing " .. niceName(U.filterMat) .. " - click the chip again to clear") or "All recipes - click a row to craft x1, or the x5 button", 200, 220, 255, 255)
  do
    local bx, bw = BPX + BPW - 132, 122
    graphics.fillRect(bx, rowsTop - 16, bw, 13, U.onlyCraftable and 40 or 26, U.onlyCraftable and 70 or 30, U.onlyCraftable and 44 or 46, 255)
    graphics.drawRect(bx, rowsTop - 16, bw, 13, U.onlyCraftable and 140 or 90, U.onlyCraftable and 255 or 90, U.onlyCraftable and 140 or 100, 255)
    graphics.drawText(bx + 5, rowsTop - 14, U.onlyCraftable and "showing: CRAFTABLE NOW" or "show: craftable now",
      U.onlyCraftable and 200 or 180, U.onlyCraftable and 255 or 190, U.onlyCraftable and 200 or 200, 255)
  end
  U.craftScroll = math.max(0, math.min(math.max(0, #rows - 1), U.craftScroll))
  local hoverRow
  for _, vis in ipairs(visibleRecipeRows(rowsTop, rows, BPY + BPH - 40)) do
    local r, y = vis.r, vis.y
    if r.header then
      local hh = R.mouse.x >= x0 - 2 and R.mouse.x < BPX + BPW - 22 and R.mouse.y >= y and R.mouse.y < y + 13
      graphics.fillRect(x0 - 2, y, BPW - 24, 13, hh and 58 or 40, hh and 62 or 44, hh and 96 or 80, 255)
      graphics.drawText(x0, y + 1, r.header, r.okst and 255 or 170, r.okst and 220 or 170, r.okst and 80 or 170, 255)
    elseif r.chain then
      -- prerequisite chain node: indented, half height, says what is blocking it
      local ix = x0 + 10 + r.depth * 14
      local hv = R.mouse.x >= x0 and R.mouse.x < BPX + BPW - 14 and R.mouse.y >= y and R.mouse.y < y + 12
      if hv and r.fn then graphics.fillRect(x0 - 2, y - 1, BPW - 24, 13, 50, 70, 55, 255) end
      graphics.drawText(ix - 8, y, "|_", 90, 100, 120, 255)
      graphics.drawText(ix + 6, y, r.label, r.ok and 150 or 210, r.ok and 255 or 200, r.ok and 150 or 150, 255)
      graphics.drawText(ix + 6 + textW(r.label) + 8, y, r.status, r.ok and 140 or 170, r.ok and 220 or 160, r.ok and 140 or 110, 255)
    else
      local rowRight = BPX + BPW - 10 - (r.kind == "recipe" and (X5_W + 4) or 0)
      local hov = R.mouse.x >= x0 and R.mouse.x < rowRight and R.mouse.y >= y and R.mouse.y < y + 24
      if hov then graphics.fillRect(x0 - 2, y - 1, BPW - 24, 24, 60, 64, 100, 255); hoverRow = r end
      local cr, cg, cb = 150, 150, 150
      if r.ok then cr, cg, cb = 140, 255, 140 elseif r.dim then cr, cg, cb = 100, 100, 110 end
      if r.have then cr, cg, cb = 255, 220, 80 end
      -- output icon leads the row -- "a recipe you can read at a glance" means seeing WHAT it
      -- makes before reading the name text at all. Only real material/item outputs (r.out) get
      -- one; picks/swords (r.out nil) keep the plain text-only row.
      local textX0 = x0
      if r.out then drawMatIcon(r.out, x0, y, 12, r.ok and 255 or 150); textX0 = x0 + 15 end
      graphics.drawText(textX0, y + 1, (r.have and "* " or "") .. r.label, cr, cg, cb, 255)
      -- ingredient icons start 15px further right when the row has a leading output icon, so a
      -- long label ("5 Reinforced Steel Bar") drawn from the now-indented textX0 can't run into them
      local ix = x0 + (r.out and 165 or 150)
      local needList = {}; for el, n in pairs(r.need) do needList[#needList + 1] = { el, n } end
      table.sort(needList, function(a, b) return a[1] < b[1] end)
      for _, p in ipairs(needList) do
        local el, n = p[1], p[2]; local have = R.inv(el) >= n
        drawMatIcon(el, ix, y + 1, 8, have and 255 or 120)
        -- Missing ingredients showed only the amount required, so "what do I still need
        -- for this" meant leaving the panel to go count your inventory. Show the shortfall
        -- inline as have/need ("2/6 Wood") when short, and just the requirement ("6 Wood")
        -- once satisfied -- so scanning the list answers "what can I make next" on its own.
        local label = have and (n .. " " .. niceName(el)) or (R.inv(el) .. "/" .. n .. " " .. niceName(el))
        graphics.drawText(ix + 10, y, label, have and 200 or 255, have and 200 or 120, have and 210 or 120, 255)
        local codeX = ix + 10 + textW(label) + 4
        graphics.drawText(codeX, y, "(" .. el .. ")", have and 130 or 170, have and 130 or 120, have and 140 or 130, 255)
        ix = codeX + textW("(" .. el .. ")") + 8
      end
      -- Station moved off the header when grouping went category-first, so it has to be
      -- visible per row -- a recipe you cannot make until you build an Advanced Lab must say so.
      local sub = r.desc
      if r.gate then sub = "needs " .. r.gate .. (sub and (" - " .. sub) or "") end
      if sub then graphics.drawText(x0, y + 13, string.sub(sub, 1, 72), r.gate and 215 or 170, r.gate and 165 or 180, r.gate and 90 or 200, 255) end
      if r.kind == "recipe" then
        local bx, by = BPX + BPW - 10 - X5_W, y + 5
        graphics.fillRect(bx, by, X5_W, 14, r.ok and 50 or 34, r.ok and 60 or 34, r.ok and 40 or 40, 255)
        graphics.drawRect(bx, by, X5_W, 14, r.ok and 140 or 90, r.ok and 255 or 90, r.ok and 140 or 100, 255)
        graphics.drawText(bx + 4, by + 2, "x5", r.ok and 220 or 130, r.ok and 255 or 130, r.ok and 220 or 130, 255)
      end
      -- "how do I actually get to X" -- only offered on things you cannot make yet,
      -- because that is the only time the question arises.
      if not r.ok then
        local ex, ey = x0 + 128, y + 1
        local open = (U.chainFor == r.label)
        graphics.fillRect(ex, ey, 16, 11, open and 60 or 34, open and 70 or 38, open and 50 or 48, 255)
        graphics.drawRect(ex, ey, 16, 11, open and 150 or 95, open and 230 or 95, open and 150 or 105, 255)
        graphics.drawText(ex + 4, ey + 1, open and "v" or "?", open and 200 or 170, open and 255 or 175, open and 200 or 180, 255)
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
  if x >= BPX + BPW - 132 and x < BPX + BPW - 10 and y >= rowsTop - 16 and y < rowsTop - 3 then
    U.onlyCraftable = not U.onlyCraftable; U.craftScroll = 0; return
  end
  local upX, upY = BPX + BPW - 42, BPY + BPH - 24
  local dnX, dnY = BPX + BPW - 22, BPY + BPH - 24
  if x >= upX and x < upX + 16 and y >= upY and y < upY + 16 then U.craftScroll = math.max(0, U.craftScroll - 1); return end
  if x >= dnX and x < dnX + 16 and y >= dnY and y < dnY + 16 then U.craftScroll = math.min(math.max(0, #rows - maxRows), U.craftScroll + 1); return end
  -- same shared walk the draw pass uses, so a click can never land on a different row
  -- than the one drawn under the cursor.
  for _, vis in ipairs(visibleRecipeRows(rowsTop, rows, BPY + BPH - 40)) do
    local r, ry = vis.r, vis.y
    if r.header then
      if x >= x0b - 2 and x < BPX + BPW - 22 and y >= ry and y < ry + 13 then
        U.catCollapsed[r.cat] = not U.catCollapsed[r.cat]; U.craftScroll = 0; return
      end
    elseif r.chain then
      if r.fn and x >= x0b and x < BPX + BPW - 14 and y >= ry and y < ry + 12 then r.fn(); return end
    else
      if r.kind == "recipe" then
        local bx, by = BPX + BPW - 10 - X5_W, ry + 5
        if x >= bx and x < bx + X5_W and y >= by and y < by + 14 then craftMultiple(r, 5); return end
      end
      if not r.ok and x >= x0b + 128 and x < x0b + 144 and y >= ry + 1 and y < ry + 12 then
        U.chainFor = (U.chainFor == r.label) and nil or r.label; return
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
-- GRNT was a phantom token (never placed by worldgen, no source anywhere) retargeted to the
-- real material BSLT ('Granite') in ADR-020 -- these two hint strings hardcoded the old code
-- and quantities and, being hand-copied prose, silently went stale ("go gather GRNT" for a
-- material that could never exist -- the exact deadlock ADR-020 fixed, reintroduced by the UI
-- text alone). Fixed by reading the live need= tables so a future recipe rebalance can't
-- rot this again the same way -- same principle as the v1.15.98 guide rework deleting its two
-- hand-copied classification lists in favour of driving off real R data.
local function needText(need)
  local parts = {}
  for el, n in pairs(need) do parts[#parts + 1] = { el, n } end
  table.sort(parts, function(a, b) return a[1] < b[1] end)
  local out = {}
  for _, p in ipairs(parts) do out[#out + 1] = p[2] .. " " .. niceName(p[1]) end
  return table.concat(out, " + ")
end
local function findPickNeed(pickName)
  for _, t in ipairs(R.PICKS) do if t.name == pickName then return t.need end end
  return nil
end
local function findRecipeNeed(outId)
  for _, rc in ipairs(R.RECIPES) do if rc.out == outId then return rc.need end end
  return nil
end
local STONE_PICK_NEED = findPickNeed("stone pick") or { WOOD = 4 }
local FURNACE_NEED = findRecipeNeed("FURNACE") or { COAL = 5 }
local QUEST_HINTS = {
  wood = "Trees grow on the surface in every biome except desert. Equip the axe (slot 2) and hold left mouse on a trunk or leaves.",
  bench = "Open your bag (E), craft a Workbench for 10 WOOD, put it in a block slot, then hold right mouse to place it.",
  pick = "Stand near your placed Workbench, open the bag's RECIPES tab, and craft the stone pick (" .. needText(STONE_PICK_NEED) .. ").",
  coal = "Coal looks like black speckled seams a little underground - dig down from the surface with the pick.",
  furnace = "Craft a Furnace kit at the Workbench (" .. needText(FURNACE_NEED) .. "), place it, then aim the torch (slot 4) at the coal inside to light it.",
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
  "BAG        L-click a slot to pick up; L-click again to place/merge; R-click splits one at a time",
  "BAG        SHIFT+click moves stack to hotbar; hover + 6-0 assigns; SORT/search/DEL trash slot",
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

-- ================================================================ community stamp submissions (Y)
-- PhoenixFire808, verbatim: "I think it's super, super important to have a mechanic where people can
-- select and basically make a stamp, and then easily submit that for like a SUGGESTION or like
-- a BUG FIX or like an ITEM THAT THEY WANT ADDED... That way the community can help build it."
-- Writer contract is @tooling's, decisionLog.md ADR-022 (the @tooling entry, two exist this
-- session, disambiguated by lane prefix) - this side owns only: drag-select a region ->
-- sim.saveStamp() (must run inside a real interface event - these mousedown/mouseup hooks
-- already are one, unlike a bridge-side pcall) -> type context -> pick category -> append one
-- JSON line to stamp_submissions/manifest.jsonl. Nothing here ever reads that file back or
-- loads a stamp - review/incorporation is a human plus @tooling's separate rpg_submissions_*
-- tools, unchanged.
--
-- SUBMISSION_CATEGORIES is @tooling's (powder_ext/rpg_tools.py) source of truth, kept here as
-- ONE list constant so the picker never needs a second edit when it changes (it already did
-- once this session: 7 categories -> 9, bug/suggestion added).
local SUBMIT_CATEGORIES = { "machine", "plant", "cave", "terrain", "building", "item", "bug", "suggestion", "other" }
-- Mirrors @tooling's _STAMPLESS_CATEGORIES exactly. Every OTHER category is silently DROPPED
-- server-side without a real on-disk .stm (_validate_submission) - the picker must never offer
-- them with no stamp attached, or the submission looks like it worked and is quietly discarded.
local SUBMIT_STAMPLESS = { bug = true, suggestion = true }

local function newStamplessId()
  -- Contract: for a stampless bug/suggestion, id only needs to satisfy ^[0-9a-fA-F]{1,16}$ -
  -- it is never resolved as a real stamp filename for these two categories, so it only needs to
  -- not collide with this player's OWN other submissions this session, not be globally unique.
  return string.format("%06x%06x", (R.frame or 0) % 0xFFFFFF, math.random(0, 0xFFFFFF))
end

local function jsonStr(s)
  s = tostring(s or "")
  s = s:gsub('[\\"]', { ["\\"] = "\\\\", ['"'] = '\\"' })
  return '"' .. s .. '"'
end

-- Bounded sample, not a full-region pixel walk - a large drag could otherwise be tens of
-- thousands of sim.partID calls inside one interface-event tick. The contract only needs
-- "distinct element codes present", not a full census, and @tooling's reader already
-- dedups/sorts elements on its own side regardless of what order/completeness this sends.
local function scanElements(x, y, w, h)
  local seen, out = {}, {}
  local stride = math.max(1, math.floor(math.max(w, h) / 40))
  for sy = y, y + h - 1, stride do
    for sx = x, x + w - 1, stride do
      local p = sim.partID(sx, sy)
      if p then
        local nm = R.nameOf and R.nameOf(sim.partProperty(p, "type"))
        if nm and not seen[nm] then seen[nm] = true; out[#out + 1] = nm end
      end
    end
  end
  table.sort(out)
  return out
end

local function submitReset()
  U.submitMode = nil
  U.submitDragging = false
  U.submitDragStart = nil
  U.submitStamp = nil
  U.submitContext = ""
  U.submitContextFocused = false
  U.submitCatIdx = 1
end

local function submitBeginSelect(source)
  closeAllPanels()
  submitReset()
  U.submitMode = "selecting"
  if R.tlog then R.tlog("info", "submit", "mode entered: selecting", { source = source or "?", frame = R.frame }) end
  R.say("Submission: drag a region and release, or press ENTER for a bug/suggestion with no region. Esc cancels.")
end

local function submitFinishDrag(x1, y1, x2, y2)
  if R.tlog then R.tlog("info", "submit", "drag end", { x1 = x1, y1 = y1, x2 = x2, y2 = y2, frame = R.frame }) end
  local sx, sy = math.min(x1, x2), math.min(y1, y2)
  local w, h = math.abs(x2 - x1), math.abs(y2 - y1)
  if w < 2 or h < 2 then
    if R.tlog then R.tlog("warn", "submit", "selection too small", { w = w, h = h, frame = R.frame }) end
    R.say("Submission: selection too small, try again (Esc to cancel)")
    return
  end
  local maxx, maxy = (sim.XRES or 612) - 1, (sim.YRES or 384) - 1
  sx = math.max(0, math.min(sx, maxx)); sy = math.max(0, math.min(sy, maxy))
  w = math.min(w, maxx - sx + 1); h = math.min(h, maxy - sy + 1)
  -- includePressure is read engine-side with luaL_optint(L, 5, 1) -- it wants a NUMBER.
  -- Passing `true` here threw "bad argument #5 ... number expected, got boolean", which is
  -- exactly the failure PhoenixFire808 hit trying to submit. Pass 1, not true.
  if R.tlog then R.tlog("info", "submit", "calling sim.saveStamp", { sx = sx, sy = sy, w = w, h = h, arg5 = 1, frame = R.frame }) end
  local ok, id = pcall(sim.saveStamp, sx, sy, w, h, 1)
  if R.tlog then R.tlog(ok and "info" or "error", "submit", "sim.saveStamp returned", { ok = ok, id = tostring(id), frame = R.frame }) end
  if not ok or not id or id == "" then
    R.say("Submission: could not save that region (" .. tostring(id) .. ") - try a smaller box")
    U.submitMode = "selecting"
    return
  end
  local okScan, elements = pcall(scanElements, sx, sy, w, h)
  if not okScan then
    if R.tlog then R.tlog("error", "submit", "scanElements failed", { err = tostring(elements), frame = R.frame }) end
    elements = {}
  end
  U.submitStamp = { id = id, w = w, h = h, elements = elements }
  U.submitMode = "form"
  U.submitCatIdx = 1  -- a real stamp is valid for any category, including bug/suggestion
  if R.tlog then R.tlog("info", "submit", "form opened (stamped)", { id = id, w = w, h = h, elements = #elements, frame = R.frame }) end
end

local function submitGoStampless()
  U.submitStamp = nil
  U.submitMode = "form"
  if R.tlog then R.tlog("info", "submit", "form opened (stampless)", { frame = R.frame }) end
  -- IMPORTANT: index into submitAvailableCats()'s FILTERED list (only valid once submitStamp is
  -- nil, set above), not into the full 9-entry SUBMIT_CATEGORIES - drawSubmitPanel/submitSend
  -- both index U.submitCatIdx against the filtered list, so this must match or the chip that
  -- looks selected silently drifts from the one that actually submits. With no stamp,
  -- submitAvailableCats() returns ONLY the stampless-eligible categories, so index 1 is always
  -- correct here - no search needed, unlike the stamped case which offers all 9 in order.
  U.submitCatIdx = 1
end

local function submitAvailableCats()
  if U.submitStamp then return SUBMIT_CATEGORIES end
  local out = {}
  for _, c in ipairs(SUBMIT_CATEGORIES) do if SUBMIT_STAMPLESS[c] then out[#out + 1] = c end end
  return out
end

local function submitSend()
  local cats = submitAvailableCats()
  local cat = cats[U.submitCatIdx] or cats[1]
  if R.tlog then R.tlog("info", "submit", "submitSend called", { cat = tostring(cat), stamped = U.submitStamp ~= nil, frame = R.frame }) end
  if not cat then
    if R.tlog then R.tlog("error", "submit", "no category selected", { frame = R.frame }) end
    R.say("Submission: no category selected"); return
  end
  local id = U.submitStamp and U.submitStamp.id or newStamplessId()
  local w = U.submitStamp and U.submitStamp.w or 0
  local h = U.submitStamp and U.submitStamp.h or 0
  local elements = U.submitStamp and U.submitStamp.elements or {}
  local elStr = {}
  for _, e in ipairs(elements) do elStr[#elStr + 1] = jsonStr(e) end
  local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- exact key order/shape from ADR-022 (@tooling); never the real player name, per standing rule.
  local line = "{" ..
    '"id":' .. jsonStr(id) .. "," ..
    '"category":' .. jsonStr(cat) .. "," ..
    '"context":' .. jsonStr(U.submitContext) .. "," ..
    '"ts":' .. jsonStr(ts) .. "," ..
    '"source":"rpg-player",' ..
    '"bbox":{"w":' .. tostring(w) .. ',"h":' .. tostring(h) .. "}," ..
    '"elements":[' .. table.concat(elStr, ",") .. "]," ..
    '"status":"pending"' ..
  "}"
  if R.tlog then R.tlog("info", "submit", "opening manifest", { path = "stamp_submissions/manifest.jsonl", frame = R.frame }) end
  local f, err = io.open("stamp_submissions/manifest.jsonl", "a")
  if not f then
    if R.tlog then R.tlog("error", "submit", "manifest open failed", { err = tostring(err), frame = R.frame }) end
    R.say("Submission failed to save: " .. tostring(err))
    return
  end
  f:write(line .. "\n")
  f:close()
  if R.tlog then R.tlog("info", "submit", "manifest write ok", { bytes = #line + 1, id = id, cat = cat, frame = R.frame }) end
  -- Session-local receipt: the chat log (R.log, 5 entries, fades ~14s) is easy to miss and
  -- gives no lasting record, so a submission that landed felt identical to one that silently
  -- didn't -- PhoenixFire808's own words were "EASILY submit", and a mechanic nobody can tell
  -- worked is not easy, it's suspect. U.submitHistory + the confirm banner below are this
  -- receipt; drawSubmitHistoryPanel (below) is the "view your own past submissions" reader.
  --
  -- DELIVERY (2026-09-02, @submission): the local manifest write above was previously the
  -- WHOLE story for a downloaded copy -- it never left this player's own disk, yet the banner
  -- below unconditionally said "Submitted - thanks! PhoenixFire808 reviews every one", which is
  -- false for every player who isn't running his dev machine. Two real delivery paths now run,
  -- in priority order, and the banner/history status reflect whichever one actually happened,
  -- never a blanket claim of success:
  --  1. R.FEEDBACK_WEBHOOK configured (his own dev machine, or anyone who deliberately drops in
  --     their own feedback_webhook.txt) -> posts straight to Discord via R.submitStampToDiscord.
  --  2. otherwise (every normal downloaded copy) -> opens a pre-filled GitHub "New issue" page
  --     on his public repo in the default browser via R.openBrowserURL/R.buildGithubIssueURL --
  --     zero secret shipped, needs the player's own GitHub account, still needs their own click
  --     of "Submit new issue" to actually send (a browser opening is not itself a delivery).
  local status, deliverMsg
  if R.FEEDBACK_WEBHOOK and R.FEEDBACK_WEBHOOK ~= "" and R.submitStampToDiscord then
    local elStr2 = table.concat(elements, ", ")
    local okSend, errSend = R.submitStampToDiscord({ category = cat, context = U.submitContext, id = id, w = w, h = h, elements_str = elStr2, manifest_line = line })
    if okSend then status, deliverMsg = "sent", "Sent to PhoenixFire808's Discord - thanks!"
    else status, deliverMsg = "delivery_failed", "Saved locally, but could not reach Discord (" .. tostring(errSend) .. ")." end
  elseif R.buildGithubIssueURL and R.openBrowserURL then
    local title = "[" .. cat .. "] " .. ((U.submitContext ~= "" and U.submitContext) or ("Stamp submission " .. id)):sub(1, 70)
    local bodyParts = { "Category: " .. cat }
    if U.submitContext ~= "" then bodyParts[#bodyParts + 1] = U.submitContext end
    if w > 0 then
      bodyParts[#bodyParts + 1] = "Selection: " .. w .. "x" .. h .. (#elements > 0 and ("\nElements: " .. table.concat(elements, ", ")) or "")
      bodyParts[#bodyParts + 1] = "A real stamp of this region was saved on this player's own machine (id " .. id .. "). To attach it, open the game's Stamps folder, find the file for that id, and drag it into this box before submitting."
    end
    bodyParts[#bodyParts + 1] = "```json\n" .. line .. "\n```"
    local okOpen, errOpen = R.openBrowserURL(R.buildGithubIssueURL(title, table.concat(bodyParts, "\n\n"), cat))
    if okOpen then status, deliverMsg = "opened_browser", "Saved locally, and a GitHub issue draft just opened - click Submit issue in your browser to actually send it."
    else status, deliverMsg = "delivery_failed", "Saved locally only - could not open your browser (" .. tostring(errOpen) .. "). Copy stamp_submissions/manifest.jsonl (id " .. id .. ") and send it yourself." end
  else
    status, deliverMsg = "delivery_failed", "Saved locally only - no delivery path available on this build."
  end
  if R.tlog then R.tlog(status == "delivery_failed" and "warn" or "info", "submit", "delivery attempt", { status = status, id = id, cat = cat, frame = R.frame }) end
  U.submitHistory[#U.submitHistory + 1] = { id = id, category = cat, context = U.submitContext, frame = R.frame or 0, status = status }
  if #U.submitHistory > 30 then table.remove(U.submitHistory, 1) end
  U.everSubmitted = true
  U.submitConfirmAt = R.frame or 0
  U.submitConfirmText = deliverMsg
  U.submitConfirmFailed = (status == "delivery_failed")
  if R.tlog then R.tlog("info", "submit", "confirmation shown", { id = id, cat = cat, status = status, frame = R.frame }) end
  R.say(deliverMsg)
  submitReset()
end

local function drawSubmitDragBox()
  if not (U.submitMode == "selecting" and U.submitDragging and U.submitDragStart) then return end
  local x1, y1 = U.submitDragStart.x, U.submitDragStart.y
  local x2, y2 = R.mouse.x, R.mouse.y
  local x, y = math.min(x1, x2), math.min(y1, y2)
  local w, h = math.abs(x2 - x1), math.abs(y2 - y1)
  graphics.drawRect(x, y, w, h, 255, 220, 80, 255)
end

local function drawSubmitHint()
  if U.submitMode ~= "selecting" then return end
  graphics.drawText(8, H - 34, "SUBMIT: drag a region and release - ENTER = no region (bug/suggestion) - Esc cancels", 255, 220, 80, 255)
end

-- shared draw/click layout, same reasoning as the crafting panel's visibleRecipeRows: a click
-- must never be able to land on a control other than the one actually drawn under the cursor.
local SUBX, SUBY, SUBW, SUBH = 90, 60, 432, 220
local function submitLayout()
  local y = SUBY + 26
  y = y + (U.submitStamp and 30 or 16)
  y = y + 12          -- "what is this?" label
  local contextBoxY = y
  y = y + 24           -- box + gap
  y = y + 12           -- "Category:" label
  local catRowY0 = y
  return contextBoxY, catRowY0
end
local function submitCatChipsWalk(y0, cb)
  local cats = submitAvailableCats()
  local cx, y = SUBX + 10, y0
  for i, c in ipairs(cats) do
    local cw = 8 + textW(c)
    if cx + cw > SUBX + SUBW - 10 then cx = SUBX + 10; y = y + 18 end
    cb(i, c, cx, y, cw, 14)
    cx = cx + cw + 4
  end
  return y + 18
end
local function drawSubmitPanel()
  if U.submitMode ~= "form" then return end
  graphics.fillRect(SUBX, SUBY, SUBW, SUBH, 14, 16, 32, 250); graphics.drawRect(SUBX, SUBY, SUBW, SUBH, 255, 220, 80, 255)
  graphics.fillRect(SUBX, SUBY, SUBW, 18, 60, 50, 20, 255)
  graphics.drawText(SUBX + 8, SUBY + 5, "SUBMIT TO PHOENIXFIRE808", 255, 220, 80, 255)
  graphics.drawText(SUBX + SUBW - 96, SUBY + 5, "Esc cancels", 190, 190, 200, 255)
  local y = SUBY + 26
  if U.submitStamp then
    graphics.drawText(SUBX + 10, y, string.format("Region saved: %dx%d px, id %s", U.submitStamp.w, U.submitStamp.h, U.submitStamp.id), 180, 220, 180, 255)
    if #U.submitStamp.elements > 0 then
      graphics.drawText(SUBX + 10, y + 13, ("Contains: " .. table.concat(U.submitStamp.elements, ", ")):sub(1, 76), 160, 180, 210, 255)
    end
  else
    graphics.drawText(SUBX + 10, y, "No region attached - only Bug and Suggestion can submit without one.", 220, 180, 120, 255)
  end
  local contextBoxY, catRowY0 = submitLayout()
  graphics.drawText(SUBX + 10, contextBoxY - 12, "What is this? (click to type, Enter to confirm)", 200, 220, 255, 255)
  graphics.fillRect(SUBX + 10, contextBoxY, SUBW - 20, 15, U.submitContextFocused and 40 or 24, U.submitContextFocused and 44 or 26, U.submitContextFocused and 70 or 40, 255)
  graphics.drawRect(SUBX + 10, contextBoxY, SUBW - 20, 15, U.submitContextFocused and 255 or 100, U.submitContextFocused and 220 or 100, U.submitContextFocused and 80 or 110, 255)
  local shown = (U.submitContext ~= "" and U.submitContext) or "click here and type..."
  graphics.drawText(SUBX + 14, contextBoxY + 4, shown .. (U.submitContextFocused and "_" or ""), U.submitContext ~= "" and 230 or 140, U.submitContext ~= "" and 230 or 140, 150, 255)
  graphics.drawText(SUBX + 10, catRowY0 - 12, "Category:", 200, 220, 255, 255)
  local chipsBottom = submitCatChipsWalk(catRowY0, function(i, c, cx, cy, cw, ch)
    local sel = (U.submitCatIdx == i)
    graphics.fillRect(cx, cy, cw, ch, sel and 70 or 26, sel and 74 or 30, sel and 40 or 46, 255)
    graphics.drawRect(cx, cy, cw, ch, sel and 255 or 90, sel and 220 or 90, sel and 80 or 100, 255)
    graphics.drawText(cx + 4, cy + 3, c, sel and 255 or 190, sel and 230 or 190, sel and 120 or 200, 255)
  end)
  local cats = submitAvailableCats()
  local canSend = U.submitContext ~= "" and #cats > 0
  local btnY = chipsBottom + 6
  graphics.fillRect(SUBX + 10, btnY, 90, 18, canSend and 40 or 30, canSend and 90 or 34, canSend and 40 or 34, 255)
  graphics.drawRect(SUBX + 10, btnY, 90, 18, canSend and 140 or 90, canSend and 255 or 90, canSend and 140 or 100, 255)
  graphics.drawText(SUBX + 24, btnY + 4, "SUBMIT", canSend and 200 or 130, canSend and 255 or 130, canSend and 200 or 130, 255)
  if not canSend then graphics.drawText(SUBX + 110, btnY + 4, "type a description first", 200, 150, 150, 255) end
end
local function handleSubmitPanelClick(x, y)
  if U.submitMode ~= "form" then return end
  local contextBoxY, catRowY0 = submitLayout()
  if x >= SUBX + 10 and x < SUBX + SUBW - 10 and y >= contextBoxY and y < contextBoxY + 15 then
    U.submitContextFocused = true; return
  end
  U.submitContextFocused = false
  local clickedCat = false
  local chipsBottom = submitCatChipsWalk(catRowY0, function(i, c, cx, cy, cw, ch)
    if not clickedCat and x >= cx and x < cx + cw and y >= cy and y < cy + ch then clickedCat = true; U.submitCatIdx = i end
  end)
  if clickedCat then
    if R.tlog then R.tlog("info", "submit", "category selected", { idx = U.submitCatIdx, cat = tostring((submitAvailableCats())[U.submitCatIdx]), frame = R.frame }) end
    return
  end
  local cats = submitAvailableCats()
  local btnY = chipsBottom + 6
  if x >= SUBX + 10 and x < SUBX + 100 and y >= btnY and y < btnY + 18 then
    if U.submitContext ~= "" and #cats > 0 then submitSend() end
  end
end

-- ================================================================ persistent submit affordance (HUD)
-- PhoenixFire808 escalated this three times ("super, super important" -> "easily submit" ->
-- "EXTREMELY PROMINENT") because Y-only + one guide line meant a player who never opens the
-- guide never learns this exists. Drawn via R.drawHotbarOverlay (rpg.lua, added for exactly this:
-- drawHotbar() opens with an opaque fill across the tray and runs AFTER every plugin drawHUD
-- hook, so this is the only hook that can put a persistent icon right where the player is
-- already looking without being painted over). Sits just outside the tray's own footprint so it
-- never overlaps the fill/border drawHotbar() paints, and never blocks a hotbar slot click.
local SUBMIT_BTN_W = 34
local function submitBtnRect()
  return HB_X0 + 10 * (HB_SLOT + HB_GAP) - HB_GAP + 13, HB_Y0, SUBMIT_BTN_W, HB_SLOT
end
local function submitHistLabel() return #U.submitHistory .. " sent" end
local function submitHistBtnRect()
  local bx, by = submitBtnRect()
  return bx, by - 12, textW(submitHistLabel()), 11
end
local function drawSubmitButton()
  if U.submitMode or U.bagOpen or U.questOpen or U.controlsOpen or R.guideOpen or R.menuOpen or R.titleScreen then return end
  local bx, by, bw, bh = submitBtnRect()
  local hov = R.mouse.x >= bx and R.mouse.x < bx + bw and R.mouse.y >= by and R.mouse.y < by + bh
  graphics.fillRect(bx, by, bw, bh, hov and 40 or 20, hov and 38 or 18, hov and 20 or 14, 235)
  graphics.drawRect(bx, by, bw, bh, hov and 255 or 200, hov and 220 or 170, hov and 80 or 60, 255)
  -- small flag-on-pole glyph, same gold as the rest of the submit UI (255,220,80 family)
  local cx = bx + floor(bw / 2)
  graphics.fillRect(cx - 1, by + 4, 2, 14, 200, 150, 90, 255)
  graphics.fillRect(cx, by + 4, 9, 6, 255, 210, 70, 255)
  graphics.drawText(bx + 3, by + bh - 10, "Y", hov and 255 or 190, hov and 230 or 190, hov and 120 or 90, 255)
  if #U.submitHistory > 0 then
    graphics.drawText(bx, by - 11, submitHistLabel(), 190, 200, 215, 220)
  end
  if hov then drawCursorTip("Submit something", { "Share a build, report a bug, or suggest an idea.", "Click here or press Y any time - takes a few seconds." }) end
end
-- Block-slot (6-0) hotbar icons -- core's own drawHotbar() (rpg.lua) draws a flat R.colourOf()
-- swatch for these slots because that file predates icons entirely and is @survival's this wave,
-- not this lane's to edit. R.drawHotbarOverlay runs AFTER drawHotbar() paints the tray (see the
-- comment above submitBtnRect), so repainting the exact same 16x16 region here with drawMatIcon
-- is how this lane upgrades the hotbar without touching rpg.lua at all: identical fallback look
-- today (same colour+outline), a real icon the instant icons.lua lands. The count badge is
-- redrawn on top afterward since its bottom-right corner overlaps that 16x16 box.
local function drawHotbarIcons()
  for slot = 6, 10 do
    local x = HB_X0 + (slot - 1) * (HB_SLOT + HB_GAP)
    local v = R.hotbar[slot]
    if v and not v:find("^tool:") then
      local a = R.inv(v) > 0 and 255 or 70
      drawMatIcon(v, x + 7, HB_Y0 + 6, 16, a)
      local n = R.inv(v); local txt = n > 999 and "999+" or tostring(n)
      graphics.fillRect(x + HB_SLOT - 4 - #txt * 6, HB_Y0 + HB_SLOT - 10, #txt * 6 + 3, 9, 0, 0, 0, 190)
      graphics.drawText(x + HB_SLOT - 2 - #txt * 6, HB_Y0 + HB_SLOT - 9, txt, 255, 255, 255, a)
    end
  end
end
R.drawHotbarOverlay = function() drawHotbarIcons(); drawSubmitButton() end

-- Confirmation feedback: R.say() alone lands in the 5-entry chat log that fades in ~14s and can
-- get pushed out by the next unrelated message, so a successful submission looked identical to
-- a silently-dropped one. This is a second, unmissable, self-timed banner top-center.
local function drawSubmitConfirmBanner()
  if not U.submitConfirmAt then return end
  local age = (R.frame or 0) - U.submitConfirmAt
  -- Failure stays up longer (240f/~4s vs 150f/~2.5s) -- a silent no-op is exactly the bug this
  -- banner exists to prevent, so a failed delivery must not be easier to miss than a success.
  local failed = U.submitConfirmFailed
  local dur = failed and 240 or 150
  if age < 0 or age > dur then U.submitConfirmAt = nil; return end
  local fadeAt = dur - 50
  local a = age < fadeAt and 255 or floor(255 * (1 - (age - fadeAt) / 50))
  local text = U.submitConfirmText or "Submitted!"
  local w = 16 + textW(text)
  local x = floor((W - w) / 2)
  local bg = failed and { 60, 22, 18 } or { 20, 50, 24 }
  local border = failed and { 255, 120, 90 } or { 140, 255, 140 }
  local fg = failed and { 255, 200, 180 } or { 200, 255, 200 }
  graphics.fillRect(x, 40, w, 16, bg[1], bg[2], bg[3], floor(a * 0.9))
  graphics.drawRect(x, 40, w, 16, border[1], border[2], border[3], a)
  graphics.drawText(x + 8, 44, text, fg[1], fg[2], fg[3], a)
end

-- "View your own past submissions": re-reads the same manifest.jsonl this file appends to
-- (append-only, so the LATEST line for an id is its current status) and merges status onto this
-- session's own U.submitHistory. Never trusts the file for anything but status - id/category/
-- context/time are the values this client itself sent, so a malformed or half-written line from
-- another process can't corrupt what's shown. Best-effort/pcall: a missing or unreadable file
-- must never break the HUD.
local function refreshSubmitHistoryStatuses()
  local ok = pcall(function()
    local f = io.open("stamp_submissions/manifest.jsonl", "r")
    if not f then return end
    local latest = {}
    for l in f:lines() do
      local lid = l:match('"id":"([^"]*)"')
      local st = l:match('"status":"([^"]*)"')
      if lid and st then latest[lid] = st end
    end
    f:close()
    for _, h in ipairs(U.submitHistory) do h.status = latest[h.id] or h.status end
  end)
  if not ok then R.say("Couldn't refresh submission status (file busy?) - showing last known") end
end
local HISTX, HISTY, HISTW, HISTH = 140, 70, 332, 200
local function drawSubmitHistoryPanel()
  graphics.fillRect(HISTX, HISTY, HISTW, HISTH, 14, 16, 32, 250); graphics.drawRect(HISTX, HISTY, HISTW, HISTH, 255, 220, 80, 255)
  graphics.fillRect(HISTX, HISTY, HISTW, 18, 60, 50, 20, 255)
  graphics.drawText(HISTX + 8, HISTY + 5, "YOUR SUBMISSIONS THIS SESSION", 255, 220, 80, 255)
  graphics.drawText(HISTX + HISTW - 96, HISTY + 5, "Esc closes", 190, 190, 200, 255)
  local n = #U.submitHistory
  if n == 0 then
    graphics.drawText(HISTX + 10, HISTY + 30, "Nothing sent yet - press Y anywhere to submit your first one.", 200, 200, 210, 255)
    return
  end
  local y = HISTY + 26
  for i = n, math.max(1, n - 11), -1 do
    local h = U.submitHistory[i]
    local age = math.max(0, floor(((R.frame or 0) - (h.frame or 0)) / 36))
    local st = h.status or "pending"
    local sc = (st == "incorporated" and { 140, 255, 140 }) or (st == "rejected" and { 255, 140, 140 })
             or (st == "reviewed" and { 200, 200, 255 })
             or (st == "sent" and { 140, 255, 140 })            -- reached Discord for real (opt-in webhook build)
             or (st == "opened_browser" and { 200, 200, 255 })  -- GitHub draft opened, still needs the player's own click
             or (st == "delivery_failed" and { 255, 120, 90 })  -- saved locally only, nothing else worked
             or { 200, 180, 120 }
    graphics.drawText(HISTX + 10, y, string.format("[%s] %s", h.category, (h.context or ""):sub(1, 38)), 220, 220, 230, 255)
    graphics.drawText(HISTX + HISTW - 92, y, st .. "  " .. age .. "s ago", sc[1], sc[2], sc[3], 255)
    y = y + 14
  end
end

-- ================================================================ hooks
hook(R.hooks.key, function(k, shift, ctrl, alt)
  if type(shift) == "boolean" then U.shiftHeld = shift end

  if U.submitMode == "form" and U.submitContextFocused then
    if k == "escape" or k == "13" or k == "10" then U.submitContextFocused = false; return true end
    if k == "8" then U.submitContext = U.submitContext:sub(1, -2); return true end
    if k == "space" then U.submitContext = U.submitContext .. " "; return true end
    if type(k) == "string" and #k == 1 and (k:match("%a") or k:match("%d")) and #U.submitContext < 500 then U.submitContext = U.submitContext .. k; return true end
    return true
  end
  if U.submitMode == "selecting" then
    if k == "escape" then submitReset(); R.say("Submission cancelled"); return true end
    if k == "13" or k == "10" then
      if R.tlog then R.tlog("info", "submit", "ENTER pressed (stampless)", { frame = R.frame }) end
      submitGoStampless(); return true
    end
    return true
  end
  if U.submitMode == "form" then
    if k == "escape" then submitReset(); R.say("Submission cancelled"); return true end
    return true
  end
  if U.submitHistoryOpen then
    if k == "escape" then U.submitHistoryOpen = false end
    return true
  end

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
  -- PhoenixFire808: "super, super important... EASILY submit" - one key, reachable from normal play, no
  -- menu-hunting, same muscle-memory tier as L for the guide. a/w/s/d are movement and every
  -- other free single letter was already taken by another plugin (checked: grepped every
  -- `k == "x"` across rpg.lua and every rpg_plugins/*.lua file) - y and i were the only two
  -- left; y is bound here.
  if k == "y" and not (U.bagOpen or U.questOpen or U.controlsOpen or U.submitHistoryOpen) then
    if R.tlog then R.tlog("info", "submit", "Y pressed", { frame = R.frame }) end
    submitBeginSelect("y-key"); return true
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
  if U.submitMode == "selecting" then
    U.submitDragging = true
    U.submitDragStart = { x = x, y = y }
    if R.tlog then R.tlog("info", "submit", "drag start", { x = x, y = y, frame = R.frame }) end
    return true
  end
  if U.submitMode == "form" then
    handleSubmitPanelClick(x, y); return true
  end
  if U.submitHistoryOpen then
    if not (x >= HISTX and x < HISTX + HISTW and y >= HISTY and y < HISTY + HISTH) then U.submitHistoryOpen = false end
    return true
  end
  if not (U.bagOpen or U.questOpen or U.controlsOpen) then
    local bx, by, bw, bh = submitBtnRect()
    if x >= bx and x < bx + bw and y >= by and y < by + bh then submitBeginSelect("hud-button"); return true end
    if #U.submitHistory > 0 then
      local hx, hy, hw, hh = submitHistBtnRect()
      if x >= hx and x < hx + hw and y >= hy and y < hy + hh then
        U.submitHistoryOpen = true; refreshSubmitHistoryStatuses(); return true
      end
    end
  end
  if U.bagOpen then
    if U.hand and not U.hand.isAcc then
      local hs = hotbarSlotAt(x, y)
      if hs and hs >= 6 then assignHotbar(U.hand.el, hs); U.hand = false; return true end
    end
    handleBagClick(x, y, button); return true
  end
  if U.questOpen or U.controlsOpen then return true end
  -- Mouse hotbar select: clicking a slot during normal play (no panel open)
  -- selects it, same effect as pressing its number key or scrolling the
  -- wheel to it. Returning true here stops core's onMouseDown from ever
  -- setting R.mouse.l/r for this click, so a click on the tray can never
  -- also mine/place in the world underneath it. Guarded on R.menuOpen/
  -- R.invOpen so a click meant for the Esc menu or the (currently dead,
  -- but not this lane's to assume permanently so) legacy E-panel can't be
  -- stolen by a coincidental hotbar-shaped hit.
  if not R.menuOpen and not R.invOpen then
    local hs = hotbarSlotAt(x, y)
    if hs then R.sel = hs; return true end
  end
  return
end)
hook(R.hooks.mouseup, function(x, y, button)
  if U.submitMode == "selecting" and U.submitDragging then
    U.submitDragging = false
    local start = U.submitDragStart
    submitFinishDrag(start and start.x or x, start and start.y or y, x, y)
    return true
  end
  if U.submitMode == "form" then return true end
  if U.bagOpen and U.hand and U.hand.isAcc then
    local accY = BPY + BPH - ITEMS_BOTTOM_RESERVE + 16
    local where = accHitAt(ITEMS_X0, accY, ITEMS_W, x, y)
    if where == "equip" then if not accLive(U.hand.key) then toggleAcc(U.hand.key) end
    else if accLive(U.hand.key) then toggleAcc(U.hand.key) end end
    U.hand = false
    return true
  end
  if U.bagOpen and U.hand and U.pickedThisPress then
    local dropped = false
    if U.itemsSub ~= "catalog" then
      local idx = invCellAt(x, y)
      if idx and idx ~= U.hand.originIdx then dropHandInto(idx, button); dropped = true end
    end
    if not dropped then
      if x >= TRASH_X and x < TRASH_X + TRASH_W and y >= CTRL_Y and y < CTRL_Y + 13 then
        trashHand(button)
      else
        local hs = hotbarSlotAt(x, y)
        if hs and hs >= 6 then assignHotbar(U.hand.el, hs); U.hand = false end
      end
    end
  end
  U.pickedThisPress = false
  if U.bagOpen or U.questOpen or U.controlsOpen then return true end
  return
end)

hook(R.hooks.tick, function()
  R.uiPanelOpen = U.bagOpen or U.questOpen or U.controlsOpen or (U.submitMode ~= nil) or U.submitHistoryOpen or false
  if U.bagOpen or U.questOpen or U.controlsOpen or U.submitMode == "form" or U.submitHistoryOpen then R.mouse.l = false; R.mouse.r = false end
  if R.hint and type(R.hint) == "string" and R.hint:sub(1, 7) == "placed " then U.everPlaced = true end
  -- Second one-time contextual invitation: the player's first death. Gated on U.deathNudgeShown
  -- so it fires exactly once ever (per R.ui, survives hot-reload) regardless of how many more
  -- times they die after.
  local deaths = R.deaths or 0
  if deaths > (U.lastDeaths or 0) then
    U.lastDeaths = deaths
    if not U.deathNudgeShown then U.deathNudgeShown = true; R.say("If that death felt like a bug, press Y to report it.") end
  end
end)

hook(R.hooks.mine, function(el, n)
  U.everMined = true
  if n and n > 0 then
    U.floaters[#U.floaters + 1] = { text = "+" .. n .. " " .. niceName(el), x = R.P.x, y = R.P.y - 14, born = R.frame or 0 }
    if #U.floaters > 10 then table.remove(U.floaters, 1) end
  end
end)

-- Contextual invitation, one-time only (PhoenixFire808: prominence "must never nag" wasn't his
-- word but is the constraint everywhere else in this pass) - the first thing you craft is a
-- natural, positive moment to mention the submit flow exists. Never repeats after this.
hook(R.hooks.craft, function(rc)
  if U.craftNudgeShown or not rc then return end
  U.craftNudgeShown = true
  R.say("Nice - if that's worth sharing, press Y to submit it to PhoenixFire808.")
end)

hook(R.hooks.draw, function() drawFloaters() end)

-- Gold absorption pulse on each OXYG particle the breathing code consumes. the owner has died
-- underground twice tonight to breathing bugs and has said for weeks that oxygen is opaque --
-- he can see bubbles but cannot tell whether they are doing anything. This makes an invisible
-- mechanic legible: the flash lands the frame the particle is eaten, so it reads as caused by
-- his own breathing rather than as ambient decoration.
-- CONTRACT (@systems owns the write side, posted to rpg-hub): R.breathFX is an array of
-- { x=, y=, at= }, capped at 24, where x/y are WORLD coordinates and `at` is R.frame at the
-- moment the OXYG particle was consumed. This draw path subtracts R.cam itself and drains
-- entries once they age out.
local function drawO2Pulses()
  local list = R.breathFX
  if not list or #list == 0 then return end
  local now, cam = R.frame or 0, R.cam
  while #list > 24 do table.remove(list, 1) end
  for i = #list, 1, -1 do
    local pu = list[i]
    local age = now - (pu.at or now)
    if age > 16 or age < 0 then
      table.remove(list, i)
    else
      local sx, sy = (pu.x or 0) - cam.x, (pu.y or 0) - cam.y
      if sx > -8 and sx < W + 8 and sy > -8 and sy < H + 8 then
        local t = age / 16
        local a = floor(255 * (1 - t))
        local rad = 1 + floor(t * 5)
        -- dark backing ring first so the gold stays legible against the bright surface sky
        -- as well as the dark underground palette (he plays in both).
        graphics.drawRect(sx - rad - 1, sy - rad - 1, rad * 2 + 3, rad * 2 + 3, 30, 20, 0, floor(a * 0.45))
        graphics.drawRect(sx - rad, sy - rad, rad * 2 + 1, rad * 2 + 1, 255, 205, 70, a)
        if age < 5 then graphics.fillRect(sx - 1, sy - 1, 3, 3, 255, 240, 150, a) end
      end
    end
  end
end
hook(R.hooks.drawHUD, function()
  drawVignette()
  drawCompass()
  drawFurnaceIndicator()
  drawO2Pulses()
  drawSubmitDragBox()
  drawSubmitHint()
  drawSubmitConfirmBanner()
  -- R.drawQuickBar (SANDBOX / TPT / GUIDE quick toggles) was fully written in rpg.lua --
  -- layout, draw, hover, and a wired click handler at rpg.lua:2801 -- but NOTHING ever
  -- called the draw half, so the buttons were clickable and completely invisible. Same
  -- defined-but-never-wired class as drawMenu/wrap. the owner asked for a one-click sandbox
  -- toggle on the main HUD; it already existed, it just never rendered.
  if R.drawQuickBar then local qok, qerr = pcall(R.drawQuickBar); if not qok then R._qbErr = tostring(qerr) end end
  if U.bagOpen then drawBagPanel(); drawHandCursor()
  elseif U.questOpen then drawQuestPanel()
  elseif U.controlsOpen then drawControlsCard()
  elseif U.submitMode == "form" then drawSubmitPanel()
  elseif U.submitHistoryOpen then drawSubmitHistoryPanel()
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
        -- World hover: single-pixel when placing blocks; 7x7 gas sample when exploring.
        local sel = (R.hotbar or {})[R.sel or 1]
        local placing = sel and not sel:find("^tool:") and not R.ITEMS[sel]
        local mx, my = R.mouse.x, R.mouse.y
        local rad = placing and 0 or 3
        local wp, nm, oxy, co2, bad = sim.partID(mx, my), nil, 0, 0, 0
        if wp then nm = R.nameOf(sim.partProperty(wp, "type")) end
        if rad > 0 then
          for dy = -rad, rad do for dx = -rad, rad do
            local pr = sim.partID(mx + dx, my + dy)
            if pr then
              local nn = R.nameOf(sim.partProperty(pr, "type"))
              if nn == "OXYG" then oxy = oxy + 1
              elseif nn == "CO2" then co2 = co2 + 1
              elseif nn == "SMKE" or nn == "CO" then bad = bad + 1 end
              if dx == 0 and dy == 0 then wp, nm = pr, nn end
            end
          end end
          if not wp then
            for dy = -rad, rad do
              for dx = -rad, rad do
                local pr = sim.partID(mx + dx, my + dy)
                if pr then wp = pr; nm = R.nameOf(sim.partProperty(pr, "type")); break end
              end
              if wp then break end
            end
          end
        end
        if wp or (rad > 0 and (oxy > 0 or co2 > 0 or bad > 0)) then
          local tempK = wp and (sim.partProperty(wp, "temp") or 295) or 295
          local kToF = function(k) return (k - 273.15) * 9 / 5 + 32 end
          local tempF = kToF(tempK)
          local ok, pr = pcall(sim.pressure, floor(mx / sim.CELL), floor(my / sim.CELL))
          pr = (ok and type(pr) == "number") and pr or 0
          local env = R.env
          local lines
          if env then
            lines = {
              string.format("T %.0f-%.0fF (here %.0fF)", kToF(env.tempMin or tempK), kToF(env.tempMax or tempK), tempF),
              string.format("P %+d..%+d (here %+d)", floor((env.pressMin or 0) + 0.5), floor((env.pressMax or 0) + 0.5), floor(pr + 0.5)),
            }
          else
            lines = { string.format("%.0f F", tempF), string.format("P %+d", floor(pr + 0.5)) }
          end
          if rad > 0 and (oxy > 0 or co2 > 0 or bad > 0) then
            local total = oxy + co2 + bad
            lines[#lines + 1] = string.format("O2 zone %d%% (%d OXYG / %d cells)", floor(oxy / total * 100), oxy, total)
            if co2 > 0 then lines[#lines + 1] = string.format("CO2 %d cells in 7x7", co2) end
            if bad > 0 then lines[#lines + 1] = string.format("smoke/toxic %d cells", bad) end
          end
          -- the owner: "whenever we hover our mouse over an in-game object or structure or tree,
          -- we want to be able to get more information about what that is". The tooltip
          -- understood particles but not THINGS -- a tree read as "Wood, 71F" instead of
          -- saying it is a tree you chop. Recognise composite objects and lead with identity
          -- plus what you actually do with it, then fall through to the material readout.
          -- STRICTLY PASSIVE: this only ever draws text. It never captures a click, never
          -- opens a panel and never needs dismissing -- his standing rule is that hover may
          -- inform but must never take over the mouse.
          local objTitle, objLines
          do
            local wx, wy = mx + R.cam.x, my + R.cam.y
            local function near(ox, oy, rr)
              local dx, dy = (ox or 1e9) - wx, (oy or 1e9) - wy
              return dx * dx + dy * dy <= rr * rr
            end
            local C = R.COMP
            if C and C.active and not C.dead and near(C.x, (C.y or 0) - 4, 10) then
              objTitle = C.name or "Aster"
              objLines = { "Your companion", string.format("HP %d/%d", floor(C.hp or 0), floor(C.maxhp or 1)),
                           "Press Enter to talk to her" }
            end
            if not objTitle and R.EN then
              for _, e in ipairs(R.EN) do
                if not e.dead and near(e.x, (e.y or 0) - (e.h or 8) / 2, math.max(7, (e.w or 4) + 5)) then
                  objTitle = e.name or e.kind or "Enemy"
                  objLines = { "Hostile", string.format("HP %d/%d", floor(e.hp or 0), floor(e.maxhp or 1)),
                               "Attack with the sword (slot 3)" }
                  break
                end
              end
            end
            if not objTitle and R.machines then
              for _, m in ipairs(R.machines) do
                if m.x and m.y and near(m.x, m.y, 14) then
                  objTitle = (tostring(m.kind or "machine"):gsub("^%l", string.upper))
                  objLines = { "Machine", "Right-click it for inputs, outputs and what it needs next" }
                  break
                end
              end
            end
            if not objTitle and (nm == "WOOD" or nm == "GRSS" or nm == "PLNT") then
              objTitle = (nm == "WOOD") and "Tree trunk" or "Tree leaves"
              objLines = { "Chop with the axe (slot 2) for Wood",
                           "Cut the trunk through and the whole tree comes down" }
            end
            if not objTitle and nm and R.MINEABLE and R.MINEABLE[nm] and R.MINEABLE[nm] > 1 then
              local need = R.MINEABLE[nm]
              local have = (R.TOOLS and R.TOOLS.pick and R.TOOLS.pick.power) or 1
              objTitle = niceName(nm)
              objLines = { have >= need and "Your pick can mine this"
                           or ("Needs a stronger pick - tier " .. need .. ", yours is tier " .. have) }
            end
          end
          local title = objTitle or (nm and niceName(nm)) or (oxy > 0 and "Oxygen" or (co2 > 0 and "Carbon dioxide" or "Air"))
          if objLines then
            local merged = {}
            for _, l in ipairs(objLines) do merged[#merged + 1] = l end
            for _, l in ipairs(lines) do merged[#merged + 1] = l end
            lines = merged
          end
          drawCursorTip(title, lines, (objLines or env) and 168 or 110)
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
      local maxScroll
      if U.itemsSub == "catalog" then maxScroll = math.max(0, #buildCatalogRows() - 1)
      else maxScroll = math.max(0, #visibleCarriedSlots() - itemsVisibleRows()) end
      U.itemsScroll = math.max(0, math.min(maxScroll, (U.itemsScroll or 0) - d))
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
