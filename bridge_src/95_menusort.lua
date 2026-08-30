-- ===========================================================================
-- 95_menusort.lua -- assigns Tool::MenuSort bands to elements so the native
-- subcategory-chip menu (GameView.cpp/GameModel.cpp, SubCategory.h) has
-- something to filter. Runs once per boot, after 10_registry.lua has
-- recreated any persisted elements, using the same "scan 0-511 for a custom
-- element's live id by name" pattern chem_kinds.lua already uses -- this file
-- has no dependency on the HTTP bridge (LuaSocket::Process), only on the
-- elements table, so it works even while that code path is stubbed out.
--
-- Bands below MUST match src/gui/game/SubCategory.h exactly (same numeric
-- ranges per section) or the native filter will show nothing for a chip.
--
-- One unified numeric band per theme per section, 10/20/30/... -- stock and
-- custom tables both feed the SAME band number when they're the same theme
-- (e.g. stock METL/TUNG and custom CU both land on ELEC band 10,
-- "Conductors & Insulators"). There used to be a second range (100+)
-- reserved purely so custom elements couldn't collide with stock ones, but
-- collision was never actually possible -- MenuSort is just an int per
-- tool -- so all that range bought was a near-duplicate chip next to every
-- stock chip that had a custom counterpart ("Inert & Cold" beside "Noble &
-- Inert", "Fissile Fuel" beside "Fuel", etc). Gone now.
--
-- An element only shows under the section named in its live MenuSection
-- property, which is a SEPARATE property from Type/MenuSort and is not set
-- automatically -- a handful of elements built directly in bridge_src (not
-- through the materials-catalog pipeline) never got one set at creation and
-- were invisible in every chip as a result. applyBand() below force-sets
-- MenuSection for every custom group (2nd item of its `entry` pair), so this
-- file is now the single source of truth for where each custom element
-- lives, not just how it's subdivided once there.
-- ===========================================================================

local function elemId(name)
	local id = elem["DEFAULT_PT_" .. name]
	if id then return id end
	for j = 0, 511 do
		local ok, n = pcall(elem.property, j, "Name")
		if ok and n == name then return j end
	end
	return nil
end

-- `section`, when given, force-sets the native MenuSection too (not just
-- MenuSort). Needed for elements created outside the materials-catalog
-- pipeline (e.g. AM24/CF25/ANT/CRPS/CRYE, built directly in bridge_src) --
-- those never got a MenuSection at creation, so without this they're a live,
-- placeable particle that's simply unreachable from every menu chip.
local function applyBand(names, sort, section)
	local applied, missing = 0, 0
	for _, name in ipairs(names) do
		local id = elemId(name)
		if id then
			if section then pcall(elements.property, id, "MenuSection", section) end
			local ok = pcall(elements.property, id, "MenuSort", sort)
			if ok then applied = applied + 1 else missing = missing + 1 end
		else
			missing = missing + 1
		end
	end
	return applied, missing
end

-- ===========================================================================
-- Custom elements, grouped by native section. Each band number matches the
-- stock table below for the same theme (see SubCategory.h).
-- ===========================================================================

local SOLIDS = {
	[10] = { "NICK", "ZINC", "TIN", "SLVR", "CHRM", "COBT", "CNT", "GRPN", "GAN", "INP",
	         "GERM", "S316", "WC", "INC7", "TI64", "AL61", "CIRN", "RBAR", "BRSS", "BRNZ",
	         "FSLG" },                                                                        -- Metals
	[20] = { "NA", "MG", "MGRB", "WP", "CS", "K", "CA" },                                     -- Alkali Metals
	[30] = { "CACL", "CAF2", "LIF", "KCL", "NA2C", "MGO", "SIC", "BORO", "FSIL",
	         "CTIL", "ZRCA", "GRNT", "BSLT", "FBRK", "GYPS", "SDST", "ASPH", "RCNC" },        -- Minerals, Ceramics & Glass
	-- (Nuclear-specific materials -- U235/UO2/ZIRC/B4C/CD/HF/BPE/CO60/AM24/CF25/RA26/THOR/BE/
	-- LEAD/DU/STEL/CNCR -- live exclusively under the NUCLEAR group below, same convention
	-- stock TPT uses: fissile/radioactive/reactor-specific material gets its own SC_NUCLEAR
	-- tab regardless of TYPE_SOLID. STEL is "SA-508 reactor pressure-vessel steel", CNCR is
	-- "Heavy shielding concrete" -- generic-sounding names, purpose-built nuclear items. RCNC
	-- ("Reinforced concrete", no reactor-specific purpose) is the genuinely generic one and
	-- stays here. ALUM/GRPH/RUBR used to be custom Lua elements listed in this file too, but
	-- got replaced by native compiled versions ported from the cracker1000 mod -- see
	-- STOCK_SOLIDS below; a custom and a native element can't share one Name.)
	[50] = { "BONE", "CHIT", "LIGN", "KERA", "BEES", "TLLW", "ADCM", "MSCN", "CROX" },        -- Organic & Life
	[80] = { "NITS", "NITI" },                                                                -- Novel Mechanics
	[90] = { "OAK", "PINE", "BAMB", "KEVL", "CFIB", "GFIB", "PUFM", "MWOL", "PTFE", "HDPE",
	         "PVC", "NYLN", "SILR", "EPDM", "PCAR", "CORK", "C60", "AERO" },                  -- Timber & Polymers
}

local LIQUID = {
	[20] = { "ETOH", "KERO", "GLYC", "BDSL", "H2O2", "NTGL", "HYPA", "HYPB" },      -- Fuels, Oils & Solvents
	[30] = { "AQRG", "AQAU", "CUSO" },                                             -- Acids & Corrosives
	[40] = { "LH2", "LHE", "LNE", "LAR", "LKR", "LXE", "LCH4", "LF2" },            -- Cryogenic
	[60] = { "NAK", "NAS", "LBE", "FLBE" },                                        -- Reactor Coolants
}

local GAS = {
	[10] = { "CH4", "NH3", "PROP" },              -- Combustible & Fuel
	[20] = { "O3", "CL2", "F2", "TRIT" },         -- Toxic & Reactive
	[30] = { "ARGN", "NE", "KR", "XE", "HE3" },   -- Noble & Inert
}

local POWDERS = {
	[30] = { "CAC2", "CAO", "SOOT" },                            -- Explosive & Reactive
	[40] = { "LMST", "MRBL", "SUGR", "STAR", "B10", "CELL" },    -- Organic Dust
}

-- SC_NUCLEAR -- also force-sets native MenuSection (see applyBand below),
-- since AM24/CF25 in particular were created with no MenuSection at all and
-- were previously unreachable from any menu chip.
local NUCLEAR = {
	[10] = { "U235", "UO2", "DU" },                                              -- Fuel
	[50] = { "B4C", "CD", "HF", "BPE", "ZIRC", "BE", "LEAD", "STEL", "CNCR" }, -- Control & Shielding
	[60] = { "CO60", "AM24", "CF25", "RA26", "THOR" },                           -- Sources
}

local POWERED = {
	[30] = { "TRBN", "TEG", "SIPV", "GAAS", "CDTE", "PZT" },  -- Generators
	[40] = { "PCMP", "PCMS", "LEDL" },                        -- Sensors & Converters
}

local ELEC = {
	[10] = { "CU" },     -- Conductors & Insulators
	[50] = { "NBTI" },   -- Superconductors & Electronics
}

-- SC_LIFE -- legacy colony-system pieces, not chemistry, but still elements,
-- so still get a place in the ladder per "sort everything". ANT/CRPS/CRYE
-- were created directly in 30_colony.lua/40_worker.lua with no MenuSection
-- at all, so they were unreachable from any menu chip until this file
-- started force-setting MenuSection alongside MenuSort (see applyBand).
local LIFE = {
	[20] = { "ANT", "CRPS", "CRYE" },   -- Colony System
}

-- ===========================================================================
-- Stock/base-game elements, grouped by what they actually do (pulled from
-- each element's real Description in src/simulation/elements). Same band
-- numbers as the custom tables above for shared themes.
-- ===========================================================================

-- Ported-from-mod elements are tagged with a trailing "-- mod" comment on
-- their own so a future audit can tell them apart from base-game stock.
local STOCK_SOLIDS = {
	[10] = { "BMTL", "GOLD", "IRON", "PTNM", "TTAN", "ALUM" },                  -- Metals (ALUM -- mod)
	[20] = { "SODM" },                                                         -- Alkali Metals (mod)
	[30] = { "GLAS", "QRTZ", "BRCK", "CRMC", "ROCK", "COAL", "GRPH" },         -- Minerals, Ceramics & Glass (GRPH -- mod)
	[40] = { "ICE", "NICE", "RIME", "DRIC" },                                  -- Ice & Cold
	[50] = { "PLNT", "VINE", "WOOD", "WAX", "SPNG" },                          -- Organic & Life
	[60] = { "SHLD", "SHD2", "SHD3", "SHD4", "FILT", "SPWN", "SPWN2", "HEAC", "RSSS",
	         "DMRN", "STRC" },                                                -- Structural & Signal (DMRN/STRC -- mod)
	[70] = { "GOO", "BIZS", "VRSS", "PSTS" },                                  -- Reactive & Bizarre
}

local STOCK_LIQUID = {
	[10] = { "WATR", "DSTW", "SLTW", "FRZW", "BUBW" },                         -- Water & Variants
	[20] = { "OIL", "DESL", "MWAX", "FUEL" },                                  -- Fuels, Oils & Solvents (FUEL -- mod)
	[30] = { "ACID", "BASE", "BIZR", "RSST" },                                 -- Acids & Corrosives
	[40] = { "LN2", "LOXY" },                                                  -- Cryogenic
	[50] = { "GEL", "GLOW", "PSTE", "RFGL", "SOAP", "VIRS", "LAVA", "MERC",
	         "CLRC", "RUBR" },                                                -- Special & Utility (CLRC/RUBR -- mod)
	[60] = { "CLNT" },                                                        -- Reactor Coolants (mod)
}

local STOCK_GAS = {
	[10] = { "GAS", "HYGN", "OXYG", "ACTY" },                                  -- Combustible & Fuel (ACTY -- mod)
	[20] = { "CAUS", "VRSG", "BIZG", "RFRG", "Cl" },                           -- Toxic & Reactive (Cl -- mod)
	[30] = { "NBLE", "CO2", "NTRG" },                                          -- Noble & Inert (NTRG -- mod)
	[40] = { "FOG", "SMKE", "WTRV", "PLSM", "BOYL", "CLUD", "DFOM", "QGP" },   -- Vapors & Effects (CLUD/DFOM/QGP -- mod)
}

local STOCK_POWDERS = {
	[10] = { "SAND", "STNE", "PQRT", "SLCN", "SALT", "CLST", "CNCT", "CMNT" },  -- Minerals & Sand (CMNT -- mod)
	[20] = { "BCOL", "BGLA", "BREL", "BRMT", "SNOW" },                         -- Broken & Debris
	[30] = { "PHOS" },                                                        -- Explosive & Reactive (mod)
	[40] = { "SAWD", "SEED", "YEST", "DYST" },                                 -- Organic Dust
	[50] = { "ANAR", "GRAV", "DUST", "FRZZ" },                                 -- Special Effects
}

local STOCK_NUCLEAR = {
	[10] = { "URAN", "PLUT", "DEUT" },                                         -- Fuel
	[20] = { "POLO", "ISOZ", "ISZS", "RADN" },                                 -- Radioactive Decay (RADN -- mod)
	[30] = { "NEUT", "PROT", "ELEC", "PHOT", "UV" },                           -- Particles (UV -- mod)
	[40] = { "AMTR", "EXOT", "GRVT", "SING", "VIBR", "WARP", "BVBR" },         -- Exotic Physics
	[60] = { "PRMT" },                                                        -- Sources (mod)
}

local STOCK_POWERED = {
	[10] = { "PPIP", "PUMP", "GPMP", "STOR", "PVOD" },                         -- Pipes & Storage
	[20] = { "DLAY", "HSWC", "LCRY", "PBCN", "PCLN", "DIGS", "LED", "PCON",
	         "PINV", "PPTI", "PPTO", "TIMC" },                                -- Switches & Signals (mod: DIGS/LED/PCON/PINV/PPTI/PPTO/TIMC)
	[40] = { "AMBE" },                                                        -- Sensors & Converters (mod)
}

local STOCK_ELEC = {
	[10] = { "METL", "TUNG", "INST", "INWR", "INSL", "COPR", "CWIR" },        -- Conductors & Insulators (COPR/CWIR -- mod)
	[20] = { "PSCN", "NSCN", "NTCT", "PTCT", "SWCH", "WWLD", "FNTC", "FPTC" }, -- Silicon & Logic (FNTC/FPTC -- mod)
	[30] = { "SPRK", "BTRY", "WIFI", "TESC", "ETRD", "EMP", "LBTR" },         -- Signal & Power (LBTR -- mod)
	[40] = { "ARAY", "BRAY", "CRAY", "DRAY" },                                -- Rays & Special
}

local STOCK_LIFE = {
	[10] = { "LIFE" },                                                         -- Cellular Automata
}

local STOCK_EXPLOSIVE = {
	[10] = { "BOMB", "DEST", "TNT", "NITR", "C-4", "CEXP" },                  -- Primary Explosives (CEXP -- mod)
	[20] = { "FUSE", "FSEP", "IGNC", "GUN", "THRM" },                         -- Slow Burn & Fuses
	[30] = { "FIRE", "EMBR", "CFLM", "C-5", "LITH", "RBDM", "LRBD",
	         "ALMP", "BFLM", "NAPM" },                                       -- Fire & Heat (ALMP/BFLM/NAPM -- mod)
	[40] = { "LIGH", "THDR", "FIRW", "FWRK" },                                -- Electric & Light
}

local STOCK_FORCE = {
	[10] = { "PSTN", "PIPE", "FRME", "PROJ", "WHEL" },                         -- Movers (PROJ/WHEL -- mod)
	[20] = { "ACEL", "DCEL", "FRAY", "RPEL", "EMGT" },                         -- Fields (EMGT -- mod)
	[30] = { "DMG", "GBMB", "MISL" },                                          -- Destructive (MISL -- mod)
	[40] = { "THMO", "ECLR", "TURB" },                                        -- Mechanisms & Signal (mod)
}

local STOCK_SENSOR = {
	[10] = { "DTEC", "LDTC" },                                                 -- Detectors
	[20] = { "PSNS", "TSNS", "VSNS", "LSNS", "CSNS", "TMPS" },                 -- Property Sensors (CSNS/TMPS -- mod)
	[30] = { "INVS" },                                                        -- Optical
}

local STOCK_SPECIAL = {
	[10] = { "CLNE", "BCLN", "CONV" },                                         -- Duplication & Conversion
	[20] = { "PRTI", "PRTO", "VOID", "VACU", "VENT", "BHOL", "WHOL" },        -- Portals & Voids
	[30] = { "STKM", "STK2", "FIGH", "TRON", "BEE", "PET" },                  -- Stickmen & AI (BEE/PET -- mod)
	[40] = { "DMND", "LOLZ", "LOVE", "MORT", "NONE", "EQVE",
	         "BALL", "ELEX", "SUN", "WALL" },                                -- Novelty & Meta (BALL/ELEX/SUN/WALL -- mod)
}

-- 10_registry.lua restores persisted elements through PBX.defer, drained a
-- few per tick (see 00_util.lua's job queue) -- they don't all exist yet at
-- module-load time. Wait a few seconds of ticks before assigning MenuSort so
-- everything persisted has actually been recreated first, then run once and
-- disable this hook (self-removal isn't exposed, so just guard with a flag).
-- SC_* numeric ids, from src/simulation/MenuSection.h (not exposed to Lua).
local SC_ELEC, SC_POWERED, SC_GAS, SC_LIQUID = 1, 2, 6, 7
local SC_POWDERS, SC_SOLIDS, SC_NUCLEAR, SC_LIFE = 8, 9, 10, 12

local applied = false
PBX.onTick("menusort_apply", function()
	if applied then return end
	applied = true
	local totalApplied, totalMissing = 0, 0
	for _, entry in ipairs({
		{ SOLIDS, SC_SOLIDS }, { LIQUID, SC_LIQUID }, { GAS, SC_GAS },
		{ POWDERS, SC_POWDERS }, { NUCLEAR, SC_NUCLEAR }, { POWERED, SC_POWERED },
		{ ELEC, SC_ELEC }, { LIFE, SC_LIFE },
		{ STOCK_SOLIDS }, { STOCK_LIQUID }, { STOCK_GAS }, { STOCK_POWDERS },
		{ STOCK_NUCLEAR }, { STOCK_POWERED }, { STOCK_ELEC }, { STOCK_LIFE },
		{ STOCK_EXPLOSIVE }, { STOCK_FORCE }, { STOCK_SENSOR }, { STOCK_SPECIAL },
	}) do
		local group, section = entry[1], entry[2]
		for sort, names in pairs(group) do
			local a, m = applyBand(names, sort, section)
			totalApplied = totalApplied + a
			totalMissing = totalMissing + m
		end
	end
	PBX.log("menusort", string.format("applied MenuSort to %d elements (%d not currently live)", totalApplied, totalMissing))
end, 180)
