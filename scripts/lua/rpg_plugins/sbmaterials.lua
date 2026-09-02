-- Sandbox material picker (@variants, new file, owns itself). NOT YET in R.PLUGINS -- rpg.lua
-- is @survival-owned this wave (AGENTS.md), so the one-line registration
-- (`"sbmaterials"`, appended after `"sandbox"` in the R.PLUGINS literal, rpg.lua's own
-- `R.PLUGINS = { ... }` line -- see knowledge/rpg-hub.md for the exact current line number and
-- before/after text) is a
-- patch request posted to knowledge/rpg-hub.md, not landed here. Until it lands this file loads
-- (compiles clean) but its hooks never fire -- same documented-inert convention sandbox.lua
-- itself uses while waiting on its own hook-list patch.
--
-- THE ASK (PhoenixFire808, verbatim): "That's pretty much the whole purpose of the sandbox mode
-- -- we can take time to make stamps, test out limitations with the character, different tools,
-- mining resources... I want all of that wired completely into the Powder Toy." Named complaint:
-- picking LAVA from TPT's own menu gives ctype-less lava that cools back to plain stone -- "the
-- lava is still turning back into stone." He wants to pick "Molten Steel" directly.
--
-- WHY NOT NEW ELEMENTS: PBX.MAX_CUSTOM_ELEMENTS is 160, 64 already used registering 64 molten +
-- 64 powdered variants is not possible (and would not scale to the stock materials either).
-- Instead this places REAL particles with the correct type+ctype -- sim.partCreate then
-- sim.partProperty(id,"ctype",...) -- exactly what the engine itself does when something melts.
--
-- VERIFIED (read src/simulation/elements/LAVA.cpp, PWCR.cpp and Simulation.cpp directly, not
-- assumed -- this is the "verify that claim yourself" instruction):
--  - PWCR.cpp: Create() sets parts[i].ctype = v (the tagged element). Its LowTemperature/
--    HighTemperatureTransition are ITL/ST placeholders that force Simulation.cpp's generic
--    transition gate into PWCR's special case (comment: "uses the REAL tagged element's own
--    melting point"), so "Powdered X" melts at X's real melting point for ANY valid ctype
--    element, not a hand-picked allowlist.
--  - LAVA.cpp: Create() (used for the vanilla LAVA menu item too) only pre-warms parts[i].temp
--    from ctype's own HighTemperature if that element's HighTemperatureTransition==PT_LAVA --
--    otherwise it keeps LAVA's own ~1798K default. Either way the particle is genuinely molten.
--  - Simulation.cpp:2769-2810 (the LAVA cooling branch, t==PT_LAVA under LowTemperatureTransition
--    ==ST): if ctype is a valid enabled element, cooling resolves the target via ctype -- using
--    that element's OWN melting point when its HighTemperatureTransition==PT_LAVA (t=THRM/TUNG/
--    VIBR/BVBR/CRMC/HEAC all get named special cases), and a generic 973K freeze point otherwise
--    ("freezing point for lava with any other... ctype"). ctype==PT_LAVA itself is explicitly
--    excluded from this branch (falls through to plain generic Lava->STNE), so picking "Molten
--    Lava" on the Lava entry is inert, not broken -- confirmed by source read, not left as a
--    guess. Every other valid ctype resolidifies into the REAL material, generically, always.
--  - Simulation.cpp:2841 (`if (t==PT_ICEI || t==PT_LAVA || t==PT_SNOW) parts[i].ctype = parts[i]
--    .type` right after part_change_type) is the general "type melts into a state-carrier and
--    keeps its own identity in ctype" mechanism the task brief cites at Simulation.cpp:2896 in
--    an older line-numbered copy of this same function -- same mechanism, current line differs.
-- CONCLUSION: `sim.partCreate(-1,x,y,LAVA_ID)` + `sim.partProperty(id,"ctype",STEL_ID)` IS
-- molten steel in every way that matters -- named "Molten Steel" by R.typeLabel (already shipped
-- by @survival, do not re-implement), and solidifies back into real STEL on cooling. Same for
-- PWCR + any ctype -> "Powdered X", melts back into real molten X at X's real melting point.
--
-- SCOPE: this file is ONLY the "spawnable variants" third of his three asks (variants / mining+
-- tools in sandbox / full material audit) -- the other two are explicitly other lanes' work per
-- the coordinator's own task split; not duplicated or widened here.
--
-- ACCESSIBILITY (his hand is broken, verbatim: "we don't want to have to push function hotkeys
-- ... I want button options for stuff"): every control here is a real on-screen button, hit-
-- tested from a real mouse-down hook. No keyboard path exists or is required for anything in
-- this file. Big-enough click targets (44-48px wide, 14-20px tall), matching the sandbox
-- toolkit's and the accessibility action bar's own established button sizes.

local R = PBX.state.rpg
local TAG = "sbmaterials"
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
-- Same defensive lazy-create as sandbox.lua, in case this loads before the R.hooks patch lands.
for _, name in ipairs({ "sandboxMouseDown", "sandboxMouseUp", "sandboxMouseMove", "sandboxDrawHUD", "sandboxTick" }) do
  R.hooks[name] = R.hooks[name] or {}
end

local floor, ceil, max = math.floor, math.ceil, math.max
local W, H = R.W or 612, R.H or 384
local SAFE = R.SAFE or { x = 4, y = 16, w = 604, h = 344 }

-- ================================================================ material universe
-- Group 1: the 64 custom RPG elements, hand-transcribed from scripts/pbx-custom-elements.json
-- (the build tool's own source of truth for what got registered -- not re-derived by scanning
-- 0..511 at load time, since that scan can race the registry's own replay-on-a-later-tick, see
-- rpg.lua's idcache self-heal comment). A name that stops resolving (renamed/removed upstream)
-- is skipped and logged, never silently hidden without a trace -- see ensureIndex() below.
local CUSTOM64 = {
  { n = "AERO", g = "POWER" }, { n = "AL61", g = "MATL" }, { n = "ALUM", g = "MATL" },
  { n = "AM24", g = "PBX" }, { n = "ANT", g = "PBX", noVariants = true },   -- creature, no melting/powder physics defined
  { n = "ARGN", g = "MATL" }, { n = "ASPH", g = "MATL" }, { n = "B4C", g = "POWER" },
  { n = "BAMB", g = "MATL" }, { n = "BE", g = "MATL" }, { n = "BONE", g = "MATL" },
  { n = "BORO", g = "MATL" }, { n = "BRSS", g = "MATL" }, { n = "BSLT", g = "MATL" },
  { n = "C60", g = "MATL" }, { n = "CAC2", g = "MATL" }, { n = "CACL", g = "MATL" },
  { n = "CAF2", g = "MATL" }, { n = "CAO", g = "MATL" }, { n = "CD", g = "MATL" },
  { n = "CF25", g = "PBX" }, { n = "CFIB", g = "MATL" }, { n = "CHIT", g = "MATL" },
  { n = "CHRM", g = "MATL" }, { n = "CNCR", g = "POWER" }, { n = "CNT", g = "MATL" },
  { n = "CO60", g = "MATL" }, { n = "COBT", g = "MATL" }, { n = "CORK", g = "MATL" },
  { n = "CROX", g = "PBX" }, { n = "CRPS", g = "PBX" }, { n = "CRYE", g = "PBX" },
  { n = "CTIL", g = "MATL" }, { n = "CU", g = "POWER" }, { n = "DU", g = "MATL" },
  { n = "EPDM", g = "MATL" }, { n = "FBRK", g = "MATL" }, { n = "FSLG", g = "MATL" },
  { n = "GRNT", g = "MATL" }, { n = "GRPH", g = "POWER" }, { n = "HDPE", g = "MATL" },
  { n = "LEAD", g = "POWER" }, { n = "LEDL", g = "POWER" }, { n = "LH2", g = "MATL" },
  { n = "LHE", g = "MATL" }, { n = "MG", g = "MATL" }, { n = "MWOL", g = "MATL" },
  { n = "NA", g = "MATL" }, { n = "NAK", g = "POWER" }, { n = "NAS", g = "MATL" },
  { n = "NBTI", g = "MATL" }, { n = "PCMP", g = "MATL" }, { n = "PTFE", g = "MATL" },
  { n = "PZT", g = "MATL" }, { n = "RBAR", g = "MATL" }, { n = "RCNC", g = "MATL" },
  { n = "S316", g = "MATL" }, { n = "SIC", g = "MATL" }, { n = "SIPV", g = "MATL" },
  { n = "STEL", g = "POWER" }, { n = "TEG", g = "POWER" }, { n = "TRBN", g = "POWER" },
  { n = "UO2", g = "POWER" }, { n = "ZIRC", g = "POWER" },
}
-- Group 2: "the stock ones worth having" -- every real, placeable material R.NAMES (rpg.lua's
-- OWN curated readable-name table, the single existing source for "materials worth showing a
-- player") already names, minus the 64 above (no duplicate group) and minus the 5 structure-kit
-- entries in R.ITEMS (WORKBENCH/FURNACE/ANVIL/RESEARCH/ADVLAB -- those are built stations, not
-- raw placeable particles; placing them here would silently no-op). Reusing R.NAMES instead of
-- hand-curating a second list keeps one source of truth per AGENTS.md/CLAUDE.md's own rule.
local STOCK = {
  "GOO", "GRSS", "PLNT", "WOOD", "SAND", "ICE", "SNOW", "CLST", "COAL", "BCOL", "IRON", "METL",
  "GOLD", "URAN", "DMND", "QRTZ", "TTAN", "BRCK", "GLAS", "INSL", "WATR", "DSTW", "LAVA", "BRMT",
  "BMTL", "PSCN", "NSCN", "TUNG", "WIFI", "STNE", "OIL", "FIRE", "GLOW", "SLCN", "SWCH", "INWR",
  "TESC", "ETRD", "GUN", "TNT", "FUSE", "IGNC", "FSEP", "TRON", "THRM", "NITR", "PSTN", "FRME",
  "ACEL", "DCEL", "FRAY", "RPEL", "PPIP", "SHLD", "SHD2", "SHD3", "SHD4", "DTEC", "LDTC", "PSNS",
  "TSNS", "SPNG", "VOID", "PVOD", "VENT",
}
-- REAL CATEGORIES (2026-09-02). The live element scan added ~330 elements and dropped every one
-- of them into a single "Stock" bucket, which made the panel unusable -- "everything should be
-- sorted out into their usable categories like how we had before."
-- Elements are now filed by what they actually ARE: the real chemical families for the periodic
-- table (from the source dataset's own GroupBlock), and the engine's own MenuSection for
-- everything else, so nothing lands in a catch-all.
local GROUP_KEYS = {
  "MATL", "POWER", "PBX",
  "ALKALI", "ALKEARTH", "TRANSIT", "POSTTRAN", "METALLOID",
  "NONMETAL", "HALOGEN", "NOBLE", "LANTH", "ACTINIDE", "ISOTOPE",
  "SOLID", "LIQUID", "GAS", "POWDER", "ELEC", "EXPLOSIVE", "FORCE", "SENSOR", "TOOL", "OTHER",
}
local GROUP_LABELS = {
  MATL = "Materials", POWER = "Power/Elec", PBX = "Special",
  ALKALI = "Alkali metals", ALKEARTH = "Alkaline earth", TRANSIT = "Transition metals",
  POSTTRAN = "Post-transition", METALLOID = "Metalloids", NONMETAL = "Nonmetals",
  HALOGEN = "Halogens", NOBLE = "Noble gases", LANTH = "Lanthanides", ACTINIDE = "Actinides",
  ISOTOPE = "Isotopes",
  SOLID = "Solids", LIQUID = "Liquids", GAS = "Gases", POWDER = "Powders",
  ELEC = "Electronics", EXPLOSIVE = "Explosives", FORCE = "Force", SENSOR = "Sensors",
  TOOL = "Tools", OTHER = "Other",
}
-- engine MenuSection id -> our category, for everything that is not a periodic element
local SECTION_GROUP = {
  [0] = "TOOL", [1] = "ELEC", [2] = "POWDER", [3] = "SOLID", [4] = "LIQUID",
  [5] = "GAS", [6] = "EXPLOSIVE", [7] = "OTHER", [8] = "SOLID", [9] = "FORCE",
  [10] = "OTHER", [11] = "SENSOR", [12] = "OTHER",
}

R.sbm = R.sbm or { panelOpen = false, group = 1, page = 1, painter = nil, painting = false, mx = 0, my = 0, tick = 0 }
local S = R.sbm

local function lavaId() if S.lavaId == nil then S.lavaId = R.eid("LAVA") or false end; return S.lavaId or nil end
local function pwcrId() if S.pwcrId == nil then S.pwcrId = R.eid("PWCR") or false end; return S.pwcrId or nil end

-- Built lazily (never at file-load time -- custom elements replay onto a LATER tick after this
-- file first runs, see rpg.lua's own idcache self-heal comment) and rebuilt every time the panel
-- is opened (cheap: ~130 elem.property lookups, not a per-frame cost) rather than memoized
-- forever, so a session where the picker is opened before every custom element has replayed in
-- self-heals on the next open instead of caching a permanent wrong answer.
local function ensureIndex(force)
  if S.index and not force then return S.index end
  local groups = {}
  for _, k in ipairs(GROUP_KEYS) do groups[k] = {} end
  local missing = {}
  local function addAll(list, forcedGroup)
    for _, e in ipairs(list) do
      local code = forcedGroup and e or e.n
      local grp = forcedGroup or e.g
      local t = R.eid(code)
      if t then
        -- Guard added 2026-09-02: I widened GROUP_KEYS from 4 to 24 real categories, but the two
        -- hand-written lists still carry their original group names. Any name that is no longer a
        -- key made this `table.insert(nil, ...)` and killed the whole index build -- which is
        -- exactly why the Material Picker rendered an empty panel. Found live by @instruments.
        if not groups[grp] then groups[grp] = groups.OTHER or {} end
        table.insert(groups[grp], { code = code, base = t, noVariants = (not forcedGroup) and e.noVariants or false, label = R.typeLabel(t, 0) })
      else
        missing[#missing + 1] = code
      end
    end
  end
  addAll(CUSTOM64, nil)
  addAll(STOCK, "STOCK")
  -- EVERYTHING ELSE, discovered from the LIVE element table (added 2026-09-02). Reported:
  -- "it's supposed to include all of the elements and materials and it seems like it's missing a
  -- shit ton of stuff." It was: the two lists above are hand-written, and the stock one is bounded
  -- by R.NAMES, which holds only 49 entries -- so roughly 113 of 259+ elements were shown, and the
  -- 118 periodic elements now being added would never have appeared at all.
  -- Scanning the real table means the panel is complete by construction and stays complete as
  -- elements are added, instead of needing someone to remember to edit a list.
  -- Scans the full engine id space: PMAPBITS was raised to 12 on 2026-09-02, so PT_NUM is 4096.
  do
    local seen = {}
    for _, g in ipairs(GROUP_KEYS) do
      for _, e in ipairs(groups[g]) do seen[e.code] = true end
    end
    local extra = 0
    for id = 0, 4095 do
      local ok, nm = pcall(elem.property, id, "Name")
      if ok and nm and nm ~= "" and not seen[nm] then
        -- MenuVisible == 0 means the engine itself hides it (tools, internal helpers); skip those
        -- rather than filling the panel with things that cannot meaningfully be placed.
        local okv, vis = pcall(elem.property, id, "MenuVisible")
        if okv and vis == 1 then
          seen[nm] = true
          extra = extra + 1
          -- file it by real category: periodic family if we know one, else the engine's own
          -- MenuSection, so nothing ends up in a catch-all bucket
          local grp = (_G.PBX_ELEM_FAMILY and _G.PBX_ELEM_FAMILY[nm]) or nil
          if not grp or not groups[grp] then
            local oks, sec = pcall(elem.property, id, "MenuSection")
            grp = (oks and SECTION_GROUP[sec]) or "OTHER"
          end
          if not groups[grp] then grp = "OTHER" end
          table.insert(groups[grp], { code = nm, base = id, noVariants = false, label = R.typeLabel(id, 0) })
        end
      end
    end
    if R.tlog then R.tlog("info", TAG, "live element scan added missing materials", { added = extra }) end
    if PBX and PBX.log then PBX.log(TAG, "material panel: live scan added " .. extra .. " elements the hand-written lists missed") end
  end
  for _, g in ipairs(GROUP_KEYS) do table.sort(groups[g], function(a, b) return a.label < b.label end) end
  S.index = groups
  if R.tlog then
    R.tlog("info", TAG, "material index built", { matl = #groups.MATL, power = #groups.POWER, pbx = #groups.PBX, stock = #groups.STOCK, missing = #missing })
    if #missing > 0 then R.tlog("debug", TAG, "some names did not resolve this session (skipped, not shown)", { codes = table.concat(missing, ",") }) end
  end
  return groups
end

local function currentList() return ensureIndex()[GROUP_KEYS[S.group]] or {} end
local ROWS = 8
local function pageCount() return max(1, ceil(#currentList() / ROWS)) end
local function clampPage() local pc = pageCount(); if S.page > pc then S.page = pc end; if S.page < 1 then S.page = 1 end end

-- ================================================================ painter selection + placement
local function selectPainter(entry, form)
  local painter
  if form == "molten" then
    local lid = lavaId(); if not lid then R.say("Molten unavailable (LAVA element missing this session)"); return end
    painter = { type = lid, ctype = entry.base, form = form, code = entry.code, label = R.typeLabel(lid, entry.base) }
  elseif form == "powdered" then
    local pid = pwcrId(); if not pid then R.say("Powdered unavailable (PWCR element missing this session)"); return end
    painter = { type = pid, ctype = entry.base, form = form, code = entry.code, label = R.typeLabel(pid, entry.base) }
  else
    painter = { type = entry.base, ctype = 0, form = "solid", code = entry.code, label = entry.label }
  end
  S.painter = painter
  R.say("Painting: " .. painter.label .. " (click Stop to use the native tool)")
  if R.tlog then R.tlog("info", TAG, "painter selected", { code = entry.code, form = form, type = painter.type, ctype = painter.ctype, label = painter.label }) end
end

-- Kill-then-create mirrors sandbox.lua's own runSample() pattern exactly (same file family,
-- same reason: sim.partCreate at an already-occupied pixel does not reliably replace it).
--
-- BUG FIXED (@meltfix, empirically reproduced against a real 4th-tree custom element (CU,
-- id 4061) and a real high-melting custom (TTAN, HighTemperature=1941K) in an isolated lab
-- instance, D:/powder-toy/lab_meltfix): this call used to omit `v`, sim.partCreate's optional
-- 5th argument. src/simulation/elements/LAVA.cpp's own create(sim, i, x, y, t, v) ONLY pre-warms
-- parts[i].temp from `v`'s (the tagged element's) own HighTemperature -- reading `v`, never the
-- particle's ctype field, because ctype is not set yet at Create() time; this file's own header
-- comment (above) correctly describes that pre-warm mechanism but wrongly assumed the LATER,
-- separate `sim.partProperty(id,"ctype",...)` call below would feed it -- it can't, Create() has
-- already returned by the time that runs. Result: every "Molten X" for an X whose real melting
-- point sits above LAVA's plain ~1795K default (confirmed live: TTAN 1941K, and this affects a
-- large fraction of the periodic-table metals -- W, Ta, Os, Ir, Re, Mo, Nb, Hf, Cr, V, Zr, Ti,
-- Rh, Ru, Pt and more all melt above 1795K) spawned ALREADY BELOW its own ctype's solidify
-- threshold, so Simulation.cpp's generic LAVA-cooling branch (t==PT_LAVA, ctype valid, ctype's
-- own HighTemperatureTransition==PT_LAVA) resolidified it back to solid X on the very next tick,
-- before a player could ever see it molten -- indistinguishable, at a glance, from "it just turned
-- to stone" (PhoenixFire808's literal complaint). Passing ctype through as `v` lets LAVA.cpp's own
-- create() do the pre-warm it was always meant to do; the ctype-tagging call below is still needed
-- separately (LAVA's create() never touches ctype, only temp -- confirmed by direct source read).
local function placeOne(x, y, painter)
  x, y = floor(x), floor(y)
  if x < 0 or y < 0 or x >= W or y >= H then return 0 end
  local okid, existing = pcall(sim.partID, x, y)
  if okid and existing then pcall(sim.partKill, existing) end
  local v = (painter.ctype and painter.ctype > 0) and painter.ctype or -1
  local ok, id = pcall(sim.partCreate, -1, x, y, painter.type, v)
  if not ok or not id or id < 0 then return 0 end
  if painter.ctype and painter.ctype > 0 then pcall(sim.partProperty, id, "ctype", painter.ctype) end
  return 1
end

-- Only called from sandboxMouseDown/sandboxMouseMove (both real input-handler dispatches, i.e.
-- interface events) -- tpt.brushx/brushy/brushID are "restricted to interface events" per
-- compat.lua:699 (same discipline sandbox.lua's own header documents and this file follows).
local function paintAt(cx, cy)
  local painter = S.painter; if not painter then return end
  local okx, bx = pcall(function() return tpt.brushx end)
  local oky, by = pcall(function() return tpt.brushy end)
  local okb, shape = pcall(function() return tpt.brushID end)
  local rx = (okx and type(bx) == "number") and bx or 4
  local ry = (oky and type(by) == "number") and by or 4
  shape = (okb and type(shape) == "number") and shape or 0
  local placed = 0
  if shape == 1 then   -- square/rectangle brush: full box, matches native square brush exactly
    for dy = -ry, ry do for dx = -rx, rx do placed = placed + placeOne(cx + dx, cy + dy, painter) end end
  else
    -- circle/ellipse (also the fallback for triangle/pentagon/hexagon/bitmap brushes -- an
    -- honest, documented approximation, not an attempt to replicate every native brush shape)
    local rx2, ry2 = max(rx, 0.5), max(ry, 0.5)
    for dy = -ry, ry do for dx = -rx, rx do
      if (dx * dx) / (rx2 * rx2) + (dy * dy) / (ry2 * ry2) <= 1.0 then placed = placed + placeOne(cx + dx, cy + dy, painter) end
    end end
  end
  return placed, rx, ry
end

-- ================================================================ layout (mouse-only, big click targets -- see file header)
local PW, PH = 300, 250
local PX, PY = SAFE.x + SAFE.w - PW, SAFE.y + SAFE.h - PH
local TW, TH = 84, 14
local TX, TY = PX + PW - TW, PY - TH - 2
local PAD, NAME_W, BTN_W, BTN_GAP, ROW_H = 6, 132, 48, 4, 20
local function btn(x, y, w, h, label) return { x = x, y = y, w = w, h = h, label = label } end
local function hit(bt, x, y) return bt and x >= bt.x and x < bt.x + bt.w and y >= bt.y and y < bt.y + bt.h end
local function inRect(x0, y0, w, h, x, y) return x >= x0 and x < x0 + w and y >= y0 and y < y0 + h end

local function layoutPanel()
  local L = {}
  L.close = btn(PX + PW - 6 - 44, PY + 4, 44, 14, "CLOSE")
  L.stop = btn(L.close.x - 4 - 56, PY + 4, 56, 14, "STOP")
  L.tabs = {}
  local tw = floor((PW - 12 - 3 * 4) / 4)
  local tx = PX + PAD
  for i, key in ipairs(GROUP_KEYS) do
    L.tabs[i] = btn(tx, PY + 22, tw, 14, GROUP_LABELS[key])
    tx = tx + tw + 4
  end
  L.rows = {}
  local list = currentList()
  local startIdx = (S.page - 1) * ROWS
  for r = 1, ROWS do
    local idx = startIdx + r
    local e = list[idx]
    if not e then break end
    local y = PY + 40 + (r - 1) * ROW_H
    local bx = PX + PAD + NAME_W + 4
    L.rows[r] = {
      entry = e, y = y,
      solid = btn(bx, y, BTN_W, ROW_H - 4, "Solid"),
      molten = btn(bx + BTN_W + BTN_GAP, y, BTN_W, ROW_H - 4, "Molten"),
      powdered = btn(bx + (BTN_W + BTN_GAP) * 2, y, BTN_W, ROW_H - 4, "Pwdr"),
    }
  end
  L.prev = btn(PX + PAD, PY + 204, 44, 14, "< Prev")
  L.next = btn(PX + PW - PAD - 44, PY + 204, 44, 14, "Next >")
  return L
end

local function handlePanelClick(x, y)
  local L = layoutPanel()
  if hit(L.close, x, y) then S.panelOpen = false; return end
  if hit(L.stop, x, y) then S.painter = nil; R.say("Painter off -- native tool active"); if R.tlog then R.tlog("info", TAG, "painter stopped", {}) end; return end
  for i, t in ipairs(L.tabs) do if hit(t, x, y) then S.group = i; S.page = 1; return end end
  if hit(L.prev, x, y) then S.page = S.page - 1; clampPage(); return end
  if hit(L.next, x, y) then S.page = S.page + 1; clampPage(); return end
  for _, row in ipairs(L.rows) do
    if hit(row.solid, x, y) then selectPainter(row.entry, "solid"); return end
    if not row.entry.noVariants then
      if hit(row.molten, x, y) then selectPainter(row.entry, "molten"); return end
      if hit(row.powdered, x, y) then selectPainter(row.entry, "powdered"); return end
    end
  end
end

-- ================================================================ tick: cache the (interface-event-only) brush readout for the draw hook
hook(R.hooks.sandboxTick, function()
  S.tick = S.tick + 1
  local okx, bx = pcall(function() return tpt.brushx end)
  local oky, by = pcall(function() return tpt.brushy end)
  local okb, shape = pcall(function() return tpt.brushID end)
  if okx and type(bx) == "number" then S.brushRx = bx end
  if oky and type(by) == "number" then S.brushRy = by end
  if okb and type(shape) == "number" then S.brushShape = shape end
end)

-- ================================================================ mouse
hook(R.hooks.sandboxMouseDown, function(x, y, button)
  if hit({ x = TX, y = TY, w = TW, h = TH }, x, y) and button == 1 then
    S.panelOpen = not S.panelOpen
    if S.panelOpen then ensureIndex(true); clampPage() end
    return true
  end
  if S.panelOpen and inRect(PX, PY, PW, PH, x, y) then
    if button == 1 then handlePanelClick(x, y) end
    return true   -- swallow any button inside the panel, matching sandbox.lua's own toolkit-panel convention
  end
  if button ~= 1 then return end
  if S.painter then
    S.painting = true
    local placed, rx, ry = paintAt(x, y)
    if R.tlog then R.tlog("debug", TAG, "paint stroke start", { code = S.painter.code, form = S.painter.form, type = S.painter.type, ctype = S.painter.ctype, x = x, y = y, brushRx = rx, brushRy = ry, placed = placed }) end
    return true
  end
  return
end)
hook(R.hooks.sandboxMouseUp, function(x, y, button) if button == 1 then S.painting = false end end)
hook(R.hooks.sandboxMouseMove, function(x, y, dx, dy)
  S.mx, S.my = x, y
  if S.painting and S.painter then
    local placed = paintAt(x, y)
    -- throttled trace (every ~15th move event) -- a full per-pixel-per-move log would flood
    -- autorun-runtime.log on a long drag; the stroke-start log above already has the full detail
    if R.tlog and S.tick % 15 == 0 then R.tlog("debug", TAG, "paint drag", { code = S.painter.code, x = x, y = y, placed = placed }) end
  end
end)

-- ================================================================ draw
local function drawBtn(bt, active, disabled)
  local bg = disabled and { 20, 20, 24 } or (active and { 30, 70, 34 } or { 26, 30, 46 })
  local border = disabled and { 70, 70, 80 } or (active and { 140, 255, 140 } or { 110, 120, 150 })
  graphics.fillRect(bt.x, bt.y, bt.w, bt.h, bg[1], bg[2], bg[3], 235)
  graphics.drawRect(bt.x, bt.y, bt.w, bt.h, border[1], border[2], border[3], 255)
  graphics.drawText(bt.x + 3, bt.y + floor((bt.h - 7) / 2), bt.label, disabled and 110 or 220, disabled and 110 or 225, disabled and 120 or 235, 255)
end

local function drawPanel()
  graphics.fillRect(PX, PY, PW, PH, 8, 10, 20, 230); graphics.drawRect(PX, PY, PW, PH, 120, 200, 255, 220)
  graphics.drawText(PX + 6, PY + 4, "MATERIAL PICKER", 160, 220, 255, 255)
  local L = layoutPanel()
  drawBtn(L.stop, S.painter ~= nil); drawBtn(L.close)
  for i, t in ipairs(L.tabs) do drawBtn(t, S.group == i) end
  for _, row in ipairs(L.rows) do
    local sel = S.painter and S.painter.code == row.entry.code
    graphics.drawText(PX + PAD, row.y + 3, row.entry.label, sel and 255 or 210, sel and 240 or 210, sel and 170 or 220, 255)
    drawBtn(row.solid, sel and S.painter.form == "solid")
    if row.entry.noVariants then
      drawBtn(row.molten, false, true); drawBtn(row.powdered, false, true)
    else
      drawBtn(row.molten, sel and S.painter.form == "molten")
      drawBtn(row.powdered, sel and S.painter.form == "powdered")
    end
  end
  drawBtn(L.prev); drawBtn(L.next)
  graphics.drawText(PX + PAD + 50, PY + 206, string.format("Page %d/%d", S.page, pageCount()), 190, 190, 205, 220)
  local statusY = PY + 222
  local paintTxt = S.painter and ("Painting: " .. S.painter.label) or "Painting: OFF (native tool)"
  graphics.drawText(PX + PAD, statusY, paintTxt, S.painter and 200 or 150, S.painter and 255 or 150, S.painter and 200 or 165, 255)
  graphics.drawText(PX + PAD, statusY + 12, string.format("Brush r%dx%d  shape %d", S.brushRx or 0, S.brushRy or 0, S.brushShape or 0), 160, 160, 175, 200)
end

hook(R.hooks.sandboxDrawHUD, function()
  drawBtn({ x = TX, y = TY, w = TW, h = TH, label = "Materials" }, S.panelOpen)
  if not S.panelOpen then
    local paintTxt = S.painter and ("Painting: " .. S.painter.label) or "Painting: OFF"
    graphics.drawText(TX + TW - #paintTxt * 4, TY - 12, paintTxt, S.painter and 200 or 150, S.painter and 255 or 150, S.painter and 200 or 165, 220)
  else
    drawPanel()
  end
end)

if R.tlog then R.tlog("info", TAG, "plugin loaded", { custom = #CUSTOM64, stock = #STOCK }) end
