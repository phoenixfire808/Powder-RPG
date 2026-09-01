-- acq_fluids.lua -- @acq_fluids, 2026-09-02. NEW FILE this wave, no collision with any
-- AGENTS.md active-wave lane. Owns: R.hooks.place/mousedown entries tagged TAG below,
-- R.RECIPES entries tagged _plugin="acq_fluids", the one new R.ITEMS.CHEMCAN kit item, and
-- R.NAMES entries for the stock elements this file makes reachable. Does NOT touch rpg.lua,
-- items.lua, machines.lua, machines2.lua, world.lua, ui.lua or guide.lua -- every one of those
-- already picks up new R.RECIPES/R.ITEMS/R.NAMES entries automatically (guide.lua's crafting
-- tabs key off `st`, the hotbar keys off R.inventory, colourOf/descOf fall back to the native
-- TPT element when R.ITEMS has no entry -- confirmed by reading rpg.lua:48-91 before writing
-- this file), so zero edits to any other lane's file were needed to ship this.
--
-- SCOPE: the 33 stock SC_LIQUID/SC_GAS elements assigned to @acq_fluids (BASE BIZR BUBW DESL
-- FRZW GEL GLOW LAVA LN2 LOXY MWAX OIL PSTE RFGL RSST SLTW SOAP VIRS WATR / BIZG BOYL CAUS CO2
-- FOG GAS HYGN NBLE OXYG PLSM RFRG SMKE VRSG WTRV). Implements design-material-progression.md
-- (part 1) chains 1/2 and design-material-progression-part2.md chains 15/17 for this element
-- set. Does not redesign anything in either document.
--
-- VERIFIED BEFORE WRITING ANYTHING (2026-09-02, grep of every .lua under scripts/lua, both
-- `out="TOKEN"` and `give("TOKEN"` for all 33 tokens, cross-checked against R.MINEABLE and
-- R.QUESTS reward tables):
--   - WATR and LAVA are ALREADY genuinely obtainable (rpg.lua's own Bucket scoops real WATR;
--     items.lua's LAVABUCKET scoops real LAVA with the Lava Charm) -- the brief's own "over-
--     count" warning applies to both. NEITHER gets a new recipe here; adding one would be the
--     exact "duplicate acquisition path is clutter" case the brief warned against.
--   - The other 31 tokens had zero R.MINEABLE entry, zero recipe `out=`, zero quest reward, and
--     zero `give("TOKEN"` call anywhere in scripts/lua -- genuinely unobtainable, not merely
--     under-counted. (SLTW is *consumed*, in survival.lua's canteen fill, never granted.)
--   - Verified genuinely-live REAL PARTICLE sources already spawned by OTHER lanes' existing,
--     already-shipped mechanics (none of this file's doing -- cited so nobody "fixes" these
--     spawns thinking they're dead code):
--       OXYG  -- natural cave-air breathing spawn, rpg.lua:1964-1981 (depth<50) and O2GENKIT
--       CO2   -- player exhale, rpg.lua:2103; tree respiration, rpg.lua:2107-2135
--       SMKE  -- TPT's own native FIRE->SMKE transition (free engine reaction, no code needed)
--       WTRV  -- TPT's own native WATR HighTemperatureTransition (free engine reaction)
--       HYGN  -- O2GENKIT electrolysis byproduct, machines.lua:1801-1802 (build-gated, T3+)
--       CAUS  -- ELECTROLYSISKIT byproduct, machines2.lua:135-140 (build-gated, T3+)
--       OIL   -- swamp-biome cave pools, world.lua:846-848 (has("OIL") and r>0.62)
--       GAS   -- swamp-biome cave pockets, world.lua:846-848 (has("GAS") and r>0.40)
--       PLSM  -- PLASMATORCH muzzle, items.lua:266 (craftable weapon, already live)
--     Every one of these particles already exists in the running game; this file's only new
--     work is giving the player a way to CAPTURE one into R.inventory, the same "extract it"
--     verb the brief names, mirroring the Bucket/LAVABUCKET precedent exactly.
--   - FRZZ and RIME (part 1's own precursors for FRZW/FOG) do not exist ANYWHERE in
--     scripts/lua yet -- grepped, zero matches, not even a comment. FRZW/FOG are NOT built here;
--     building on an unverified precursor would be exactly the deadlock shape the brief warns
--     about (GRNT/NSCN/TUNG/THRM/NITR). Flagged as a residual for whichever lane adds those two
--     veins/reactions (world.lua/@world), not silently skipped.
--   - MWAX (forest beehive cache), BIZR (loot), VIRS/VRSG/BIZG (world-fixture hazard pockets),
--     BOYL/NBLE (capture-site pockets) all need NEW WORLD PLACEMENT per both design docs --
--     world.lua is @world's file this wave (AGENTS.md), out of scope for this plugin. SOAP (the
--     virus-family countermeasure part 2 designs for VIRS/VRSG/VRSS) IS implemented below since
--     it needs no world placement at all, just existing mineable/capturable inputs.
--
-- Performance: the one new mechanic (Chem Canister capture) runs ONLY inside R.hooks.mousedown,
-- itself only invoked once per real click (rpg.lua:3283, not per-frame) -- a single 5x5-cell
-- sim.partID scan (<=25 lookups) per click. No R.hooks.tick handler in this file at all: zero
-- added per-frame cost.

local R = PBX.state.rpg
local TAG = "acq_fluids"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

if R.tlog then R.tlog("info", TAG, "plugin loading", { version = "1.0" }) end

-- ================================================================ display names
-- (colourOf/descOf already fall back to the native TPT element for anything not in R.ITEMS --
-- rpg.lua:48-54,88 -- so these are the only entries this file needs for stock elements.)
R.NAMES = R.NAMES or {}
R.NAMES.SLTW = R.NAMES.SLTW or "Saltwater"
R.NAMES.BASE = R.NAMES.BASE or "Base"
R.NAMES.BUBW = R.NAMES.BUBW or "Soda water"
R.NAMES.GEL  = R.NAMES.GEL  or "Gel"
R.NAMES.PSTE = R.NAMES.PSTE or "Paste"
R.NAMES.SOAP = R.NAMES.SOAP or "Soap"
R.NAMES.DESL = R.NAMES.DESL or "Diesel"
R.NAMES.LOXY = R.NAMES.LOXY or "Liquid oxygen"
R.NAMES.LN2  = R.NAMES.LN2  or "Liquid nitrogen"
R.NAMES.RFRG = R.NAMES.RFRG or "Refrigerant gas"
R.NAMES.RFGL = R.NAMES.RFGL or "Liquid refrigerant"
R.NAMES.GLOW = R.NAMES.GLOW or "Glow sand"
R.NAMES.RSST = R.NAMES.RSST or "Resist"
R.NAMES.CHEMCAN = R.NAMES.CHEMCAN or "Chem Canister"

-- ================================================================ Chem Canister: the "extract
-- it" verb applied to gases/liquids the same way the Bucket already applies it to WATR and the
-- Lava Bucket applies it to LAVA. Aim at a real particle of a supported kind and click: kills up
-- to a small radius of matching particles and gives them to your inventory. Every supported kind
-- is a real particle ALREADY spawned by some other, already-live mechanic (cited in the header) --
-- this file adds no new particle sources, only a way to collect existing ones.
local CAPTURABLE = {
  OXYG = true, CO2 = true, SMKE = true, WTRV = true, HYGN = true, CAUS = true,
  OIL = true, GAS = true, PLSM = true,
}
R.ITEMS.CHEMCAN = { col = { 140, 200, 190 },
  desc = "A sealed glass-and-iron canister. Aim it at real Oxygen, CO2, Smoke, Steam, Hydrogen, "
    .. "Caustic gas, Oil, natural Gas or Plasma and hold LEFT mouse -- it captures nearby real "
    .. "particles of whatever you're aiming at straight into your inventory. Only works on those "
    .. "nine; it will not pick up terrain." }

local function chemCanUse(mx, my)
  local p = sim.partID(mx, my)
  if not p then R.hint = "Chem Canister: aim at a real gas or liquid pocket"; return end
  local nm = R.nameOf(sim.partProperty(p, "type"))
  if not nm or not CAPTURABLE[nm] then
    R.hint = "Chem Canister: can't capture " .. (nm and R.nice(nm) or "that")
    return
  end
  -- PLSM runs at ~4000K in this build (rpg.lua's own MOLTEN_TEMPS) -- same hazard shape as
  -- scooping raw LAVA, so it uses the same existing Lava Charm gate rather than a new accessory.
  if nm == "PLSM" and not R.accOn("lava") then
    R.hp = math.max(0, R.hp - 8); R.hurt = R.frame
    R.hint = "Too hot to draw in plasma without the Lava Charm!"
    return
  end
  local n = 0
  for y = my - 2, my + 2 do for x = mx - 2, mx + 2 do
    local q = sim.partID(x, y)
    if q and R.nameOf(sim.partProperty(q, "type")) == nm then sim.partKill(q); n = n + 1 end
  end end
  if n > 0 then
    -- Literal per-token R.give("X", n) calls, not R.give(nm, n) with a variable, on purpose:
    -- scripts/check_reachable.py's grant parser only matches a literal string first argument
    -- (GIVE_RE = R\.give\(\s*"([A-Z...)", check_reachable.py:456) -- a variable call is exactly
    -- as reachable at runtime but invisible to that static gate, which would then misreport
    -- CAUS/CO2/OIL/OXYG/PLSM/etc as unreachable (verified: it did, before this rewrite). Writing
    -- out the 9 branches makes the SAME real capture mechanism visible to the automated check
    -- instead of asking a human to remember it's a false negative every time the gate runs.
    if     nm == "OXYG" then R.give("OXYG", n)
    elseif nm == "CO2"  then R.give("CO2", n)
    elseif nm == "SMKE" then R.give("SMKE", n)
    elseif nm == "WTRV" then R.give("WTRV", n)
    elseif nm == "HYGN" then R.give("HYGN", n)
    elseif nm == "CAUS" then R.give("CAUS", n)
    elseif nm == "OIL"  then R.give("OIL", n)
    elseif nm == "GAS"  then R.give("GAS", n)
    elseif nm == "PLSM" then R.give("PLSM", n)
    end
    R.rebuildHotbar()
    R.hint = "Captured " .. n .. " " .. R.nice(nm)
    if R.tlog then R.tlog("debug", TAG, "chemcan capture", { el = nm, n = n }) end
  else
    R.hint = "Chem Canister: nothing there to capture"
  end
end

hook(R.hooks.place, function(el)
  if el == "CHEMCAN" then
    R.hint = "Chem Canister: hold LEFT mouse on real gas/liquid to capture it"
    return true  -- swallow: this is a reusable tool, not a block to place
  end
end)

hook(R.hooks.mousedown, function(x, y, button)
  if button ~= 1 or R.invOpen or R.menuOpen or R.tptMenus then return end
  local sel = R.hotbar and R.hotbar[R.sel or 1]
  if sel == "CHEMCAN" then chemCanUse(x, y) end
  return false  -- never swallow: core still needs to set R.mouse.l
end)

-- ================================================================ recipes
-- Every `need` below is either already-mineable (SALT, GOO, IRON, SAND, CU, QRTZ), already-
-- craftable baseline (WATR via Bucket, GLAS, METL), or captured through the Chem Canister above
-- (OXYG/CO2/CAUS/OIL) -- no recipe here depends on an unverified precursor.
local RECIPES = {
  -- the tool itself: cheap, workbench-tier, so every other recipe in this file is reachable
  -- from a genuine T1 starting point, not gated behind something this file also introduces
  { out = "CHEMCAN", n = 1, need = { GLAS = 2, METL = 2 }, st = "workbench", txt = "Chem Canister",
    desc = "Sealed glass-and-iron canister -- aim and hold LEFT mouse on real Oxygen, CO2, Smoke, "
      .. "Steam, Hydrogen, Caustic gas, Oil, Gas or Plasma to capture it into your inventory." },

  -- react: SALT (already mineable, ADDED 2026-09-02 per design-material-progression.md chain 4)
  -- dissolved into WATR -- the most natural "extract it from water" verb in the whole set.
  { out = "SLTW", n = 3, need = { WATR = 4, SALT = 1 }, st = "workbench", txt = "Saltwater",
    desc = "Salt dissolved in real water. Conducts, resists freezing -- feeds the Desalinator and marks brine ground." },

  -- react: CAUS (Chem Canister, ELECTROLYSISKIT byproduct) + IRON, matches design-material-
  -- progression.md chain 1 exactly: gives the corrosion mechanic (IRON already rusts with salt)
  -- a real countermeasure material.
  { out = "BASE", n = 2, need = { CAUS = 3, IRON = 2 }, st = "furnace", txt = "Base",
    desc = "Caustic gas neutralized against iron. Halts corrosion on a rusting conductor and neutralizes acid on contact." },

  -- react: CO2 (Chem Canister, already a scrubber-target oversupply per design docs) + WATR --
  -- pure sink-to-more-sinks per the design docs' own reasoning, zero new scarcity risk.
  { out = "BUBW", n = 2, need = { WATR = 3, CO2 = 1 }, st = "workbench", txt = "Soda water",
    desc = "Water carbonated with captured CO2. Slowly releases its gas back out -- a farming/brewing curiosity." },

  -- craft: GOO (mineable) + WATR, paired recipes per design-material-progression-part2.md
  -- chain 17 (GEL/PSTE alt-config pair).
  { out = "GEL", n = 1, need = { GOO = 2, WATR = 2 }, st = "research", txt = "Gel",
    desc = "A colloid mixed thicker with water than paste. Absorbs water -- shock-absorbing armour padding reagent." },
  { out = "PSTE", n = 1, need = { GOO = 2, WATR = 1 }, st = "research", txt = "Paste",
    desc = "A colloid mixed drier than gel. Hardens under pressure -- flexible sealant reagent." },

  -- craft: the actual player-facing virus/hazard countermeasure design-material-progression-
  -- part2.md chain 15 designs -- own in-engine description states outright "cures virus".
  { out = "SOAP", n = 2, need = { WATR = 3, CLST = 1, OIL = 1 }, st = "workbench", txt = "Soap",
    desc = "Real saponification -- water, clay and oil. Washes off deco colour and cures virus contamination on contact." },

  -- craft: refine captured OIL at the research bench into a cleaner-burning generator fuel.
  { out = "DESL", n = 1, need = { OIL = 3 }, st = "research", txt = "Diesel",
    desc = "Oil refined into diesel. Explodes under high pressure/temperature -- an alternate generator fuel." },

  -- craft: cryogenics tier, design-material-progression.md chain 2. LOXY compresses captured
  -- OXYG; LN2 is gated purely on Advanced Lab tier + a cheap cryo-flask container, matching the
  -- design doc's own reasoning ("gate on station tier, not a consumable -- ambient air is
  -- infinite"); RFRG/RFGL chain off LOXY, matching the doc's compress-then-liquefy shape.
  { out = "LOXY", n = 1, need = { OXYG = 4, GLAS = 1 }, st = "advlab", txt = "Liquid oxygen",
    desc = "Captured oxygen compressed and chilled below 90K. Hotter-burning cutting oxidizer than air alone." },
  { out = "LN2", n = 1, need = { GLAS = 2 }, st = "advlab", txt = "Liquid nitrogen",
    desc = "Ambient air compressed and chilled below 77K in a cryo-flask. Disappears on contact with anything warmer." },
  { out = "RFRG", n = 1, need = { LOXY = 2, GLAS = 1 }, st = "advlab", txt = "Refrigerant gas",
    desc = "Liquid oxygen re-expanded through a cold coil. Liquefies under pressure -- feeds a cold-storage loop." },
  { out = "RFGL", n = 1, need = { RFRG = 2 }, st = "advlab", txt = "Liquid refrigerant",
    desc = "Refrigerant gas compressed back to a liquid -- safe bulk cold storage for a Cryo chamber." },

  -- react: SAND heated in a lit furnace short of full melt -- a distinct token from the existing
  -- GLAS recipe, matches GLOW's own "glows under pressure" description and closes the gap noted
  -- in design-material-progression-part2.md chain 17 (GLOW already used live by the Miner's Lamp
  -- Helm, items.lua:1269, with no stated source until now).
  { out = "GLOW", n = 2, need = { SAND = 6 }, st = "furnace", txt = "Glow sand",
    desc = "Sand heated just short of a full melt -- glows instead of turning to glass. Feeds the Miner's Lamp Helm." },

  -- craft: photonics-tier component, design-material-progression-part2.md chain 17.
  { out = "RSST", n = 1, need = { CU = 2, QRTZ = 2 }, st = "advlab", txt = "Resist",
    desc = "Copper and quartz tuned into a photon-reactive component. Solidifies on contact with light." },
}
for _, rc in ipairs(RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end

if R.tlog then
  R.tlog("info", TAG, "plugin loaded", { recipes = #RECIPES, capturable = 9 })
end
