-- acq_solids.lua - Material-acquisition plugin for the Powder RPG (2026-09-02, @acq_solids).
-- PhoenixFire808's standing requirement, restated 2026-09-02: "Every single Powder Toy element in
-- the game needs to be acquirable -- it needs to have some NATURAL means of acquiring it." This
-- file closes that gap for the 28 elements assigned to this lane -- the menu_section SC_SOLIDS (16)
-- and SC_POWDERS (12) groups -- per knowledge/design-material-progression.md S1/S4 (chains 1, 2, 6,
-- 7, 8, 10) and design-material-progression-part2.md S3/S7 (chain 17, DYST row). Implements the
-- design; does not redesign it -- every recipe below traces to a specific chain/row in those docs,
-- with real engine chemistry cited in this header wherever the design's own "react" framing maps
-- onto a genuine HighTemperatureTransition/LowTemperatureTransition/pressure-delta the engine
-- already runs (verified by reading the element .cpp source directly,
-- D:/The-Powder-Toy/src/simulation/elements/, 2026-09-02 -- not inferred from the element's own
-- flavour text alone).
--
-- STANDALONE PLUGIN, per this wave's instruction: does NOT touch rpg.lua, items.lua, machines.lua,
-- machines2.lua, world.lua, ui.lua or guide.lua. Registers R.RECIPES (tagged _plugin="acq_solids"
-- for idempotent hot-reload, same convention as rpg_plugins/automation.lua), and mutates the
-- SHARED R.MINEABLE / R.NAMES / R.HARD runtime tables that rpg.lua already owns and initialised --
-- adding a key to a table another file created is not the same file-ownership violation as
-- overwriting that file's own source text (same distinction the historic BSLT/GRNT fix documented
-- in rpg.lua's own changelog: "Added a BSLT entry to R.MINEABLE/R.HARD... No bootstrap deadlock").
-- Send the coordinator: (1) one line for R.PLUGINS ("acq_solids", appended after "fieldtools"),
-- (2) the changelog lines in this file's own trailing comment block, to land in rpg.lua's
-- R.CHANGELOG per "rpg.lua owns R.VERSION; ALL plugin fixes roll into the next rpg.lua bump."
--
-- VERIFIED BEFORE WRITING (over-count correction, per the task brief's own warning "MY LIST IS AN
-- OVER-COUNT -- VERIFY BEFORE YOU ADD"): of the 28 elements in this lane's list, TWO were already
-- genuinely obtainable and needed ZERO new code --
--   SHD4  -- already craftable, machines.lua TIERR_RECIPES: advlab, 2xSHD3+4xTTAN+3xGOLD (grep
--           confirmed 2026-09-02, machines.lua:2496).
--   SEED  -- already granted: survival.lua bonus("SEED",...) on GRSS/PLNT foraging (10% roll,
--           depth<=4) AND R.give("SEED",1) on 40% of wheat harvests (survival.lua:183/282).
-- Both are left untouched here. This plugin implements the other 26.
--
-- ONE ELEMENT DELIBERATELY LEFT UNACQUIRABLE, matching the design docs' own classification, not a
-- gap this pass missed:
--   VRSS  -- "Solid Virus. Turns everything it touches into virus," PROP_DEADLY (verified,
--           POWDER_TOY_MATERIAL_INDEX.json). Both design docs classify VRSS/VRSG/VIRS together as
--           "world-fixture... contamination hazard, never held" (design-material-progression-
--           part2.md S6, "framing" note above its own hazard table) -- the same EXCLUDE class as
--           part 1's own reasoning for genuinely deadly/griefing elements. This is the one place in
--           this pass where "implement the design, don't redesign it" means NOT inventing an
--           inventory slot for a hazard the design intentionally left as containment-only.
--
-- ====================================================================================================
-- REAL ENGINE REACTIONS THIS PASS DISCOVERED AND BUILT ON (verified by reading the .cpp source, not
-- assumed from element flavour text) -- exploiting free process chains before inventing a synthetic
-- recipe, per the task brief's explicit instruction to prefer this verb:
--
-- VINE -- ALREADY WORLD-PLACED, twice over, and simply not mineable until this pass:
--   (a) world.lua's swamp "dead" tree species hangs real VINE particles off dead branches
--       (world.lua:364-366, gated `has("VINE")`, already true -- stock element).
--   (b) PLNT.cpp's own update() spawns real PT_VINE particles as part of ordinary plant growth
--       (PLNT.cpp:313, engine-verified) -- completely independent of world.lua's placement, so VINE
--       is genuinely already growing in every biome with PLNT, not just the swamp.
--   Fix: R.MINEABLE.VINE = 1 (tier 1, hand/wood-pick). No recipe needed -- the material already
--   exists in the world; it just could not be picked up.
--
-- SAWD -- ALREADY PASSIVELY PRODUCED. Confirmed directly from rpg.lua's own investigation trail
--   (rpg.lua:2052-2061, "SAWDUST ROOT CAUSE (2026-08-31)... Native TPT turns WOOD into SAWD wherever
--   a particle hits it faster than speed 5... Nothing in this codebase creates SAWD at all") --
--   292 SAWD particles were already in the live world from vented O2 sandblasting trees. Needed a
--   collection verb, not a source. Fix: R.MINEABLE.SAWD = 1.
--
-- BGLA / PQRT -- ALREADY PASSIVELY PRODUCED, intrinsic to GLAS/QRTZ's own update() functions (not a
--   separate demolition mechanic): GLAS.cpp update() converts to PT_BGLA whenever the local pressure
--   cell changes faster than the particle's own "strength" tolerance (GLAS.cpp:50-62, engine-
--   verified); QRTZ.cpp update() does the identical pressure-delta check into PT_PQRT (QRTZ.cpp:49-
--   61). Both fire naturally around any boiler, piston, explosion or machine pressure swing near
--   placed GLAS/QRTZ -- the exact "byproduct-sourced, cannot outrun its own source" class part 1
--   S6 describes. Fix: R.MINEABLE.BGLA = 1, R.MINEABLE.PQRT = 1. Chain 7's own BGLA->GLAS/PQRT->
--   QRTZ recycling-recovery recipes are deferred (see note above ACQ_RECIPES's own BIZS entry) --
--   check_reachable.py cannot see a runtime R.MINEABLE addition, so a recipe consuming BGLA/PQRT as
--   a `need` fails that gate even though the material is genuinely minable in-game.
--
-- BREL -- ALREADY PASSIVELY PRODUCED whenever the existing, already-craftable EMPCHARGE weapon
--   (items.lua, research tier, 8xCU+2xGOLD+3xQRTZ -- verified live, items.lua:191) hits a
--   conductor: EMP.cpp's own update() converts nearby activated electronics to PT_BREC (Name="BREL",
--   BREC.cpp:8) -- "Electromagnetic pulse. Breaks activated electronics" is not flavour text, it is
--   exactly what the update loop does. Fix: R.MINEABLE.BREL = 1 -- deliberately mine-only, not a
--   bulk recipe, matching part 1's own "opportunistic byproduct... not a primary route" framing for
--   this exact material.
--
-- CRMC -- real fusion chemistry exists (FIRE.cpp:229-241: molten LAVA(QRTZ) touching LAVA(CLST)
--   above CRMC's own HighTemperature+pressure+50 threshold fuses both into LAVA(CRMC), which then
--   cools to solid CRMC) but is not reliably player-triggerable without a dedicated furnace stage
--   this pass does not build. The furnace recipe below (CLST+QRTZ) is the same two reagents this
--   real reaction fuses, abstracted into the same station-gated-recipe pattern rpg.lua already uses
--   for SLCN ("Sand heated past its melting point in a lit furnace" is also just a plain recipe,
--   not a simulated reaction -- automation.lua's own header documents this as the established
--   convention).
--
-- RIME -- real deposition chemistry exists (Simulation.cpp:2764-2769: WTRV/steam cooled below its
--   own LowTemperature while colder than 273K transitions directly to PT_RIME, skipping the liquid
--   phase -- "deposition," exactly RIME's own description) but WTRV is ambient steam, never
--   inventory-held, so there is nothing for a recipe to consume. Abstracted into an Advanced Lab
--   recipe (WATR+ICE) with the real physics quoted in the recipe's own desc text instead.
--
-- ROCK (stock) -- real chemistry exists (FIRE.cpp:154-158: LAVA with ctype STNE solidifies into
--   ROCK, not back into STNE, specifically when local pressure >= 30 while it cools) but reliably
--   generating >=30 real pv pressure on demand needs a machine this pass does not build. Abstracted
--   into an anvil recipe (hammer-quench framing) using only STNE, already tier-2 mineable. NOTE: no
--   naming-collision risk from this recipe -- part 1 S0's collision warning is about *other* code
--   writing `need={ROCK=1}` and getting rpg.lua's own `local ROCK = has("BSLT") and "BSLT" or
--   "BRCK"` alias by mistake; this recipe's `out="ROCK"` calls give("ROCK",n) -> eid("ROCK"), a
--   direct stock-element lookup that never touches that Lua local at all (grepped rpg.lua:1365,
--   confirmed the alias is a `local`, not reachable from this file).
--
-- YEST -> DYST -- real transition exists and is used directly: YEST.cpp HighTemperatureTransition =
--   PT_DYST at 373K (own engine file, "YEST -> DYST"). The recipe below is that exact transition
--   given a deliberate recipe form (heat yeast past 373K near the furnace) instead of leaving it as
--   an accident, exactly matching part2's own DYST design row ("a YEST planting that isn't
--   harvested... decays to DYST").
-- ====================================================================================================

local R = PBX.state.rpg
local TAG = "acq_solids"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

-- ================================================================ R.MINEABLE / R.HARD: the five
-- elements the engine ALREADY places/produces, just never made pickable. Tier 1 (wood pick) for all
-- five -- every one of them is either loose debris (SAWD/BGLA/PQRT/BREL, all already-broken material
-- by their own description) or a soft climbing plant (VINE) -- no real justification for gating
-- behind a better pick. Direct table mutation on the SAME table rpg.lua initialised (R.MINEABLE is
-- `local` inside rpg.lua's own closure, but the TABLE it points R.MINEABLE at is shared; adding a
-- key to it is not overwriting rpg.lua's source, same precedent as the BSLT/GRNT fix cited above).
R.MINEABLE = R.MINEABLE or {}
R.MINEABLE.VINE = 1
R.MINEABLE.SAWD = 1
R.MINEABLE.BGLA = 1
R.MINEABLE.PQRT = 1
R.MINEABLE.BREL = 1
R.HARD = R.HARD or {}
R.HARD.VINE = 1
R.HARD.SAWD = 1
R.HARD.BGLA = 1
R.HARD.PQRT = 1
R.HARD.BREL = 2

-- ================================================================ R.NAMES: friendly display names.
-- Without an entry here R.nice() falls back to the raw element code (rpg.lua:86) -- confirmed SHD4
-- and SEED already have names elsewhere (rpg.lua:84 literal, survival.lua:54 loop) so this list
-- deliberately excludes both.
R.NAMES = R.NAMES or {}
for code, nm in pairs({
  BIZS="Bizarre curio", CRMC="Ceramic", DRIC="Dry ice", FILT="Optic filter", HEAC="Heat conductor",
  NICE="Nitrogen ice", PSTS="Pressed paste", RIME="Rime frost", ROCK="Fused rock", RSSS="Solid resist",
  SPWN="Camp beacon", SPWN2="Companion beacon", VINE="Vine", VRSS="Infected stone", WAX="Wax",
  ANAR="Anti-air dust", BGLA="Broken glass", BREL="Broken electronics", CNCT="Concrete", DUST="Fine dust",
  DYST="Dead yeast", FRZZ="Freeze powder", GRAV="Velocity dust", PQRT="Powdered quartz", SAWD="Sawdust",
  YEST="Yeast",
}) do R.NAMES[code] = R.NAMES[code] or nm end

-- ================================================================ R.RECIPES: everything above that
-- has no world-placed source to mine and no reliably player-triggerable free reaction. Idempotent
-- across hot-reload (filter own tag, reinsert), and reinstalled on newworld same as automation.lua
-- (R.RECIPES is rebuilt from rpg.lua's own literal on any rpg.lua reload, wiping plugin additions).
local ACQ_RECIPES = {
  -- chain 8 / real FIRE.cpp fusion chemistry (LAVA(QRTZ)+LAVA(CLST) -> CRMC), abstracted
  { out="CRMC", n=2, need={CLST=4, QRTZ=2}, st="furnace", txt="Ceramic",
    desc="Clay and quartz fired together past the point they'd fuse in the real molten-lava chemistry the engine already runs -- ceramic, stronger under pressure than brick." },
  -- chain 2 -- CO2 is furnace exhaust (burning coal); chilled in a packed-ice cold trap
  { out="DRIC", n=2, need={COAL=2, ICE=3}, st="furnace", txt="Dry Ice",
    desc="Furnace exhaust CO2, flash-chilled against packed ice in a cold trap below its own sublimation point -- dry ice, safe to carry without a tank." },
  -- optics tier, pairs with RSST/RSSS family
  { out="FILT", n=1, need={QRTZ=2, CU=1}, st="advlab", txt="Optic Filter",
    desc="Quartz and copper temperature-cured into a colour filter -- shifts the colour of any photon or bizarre-radiation beam passed through it." },
  -- chain 1 tier, sibling recipe to TESC/ETRD (same station, same cost class)
  { out="HEAC", n=2, need={CU=3, STEL=1}, st="research", txt="Heat Conductor",
    desc="Copper wound around a steel core at the research bench -- carries heat through a circuit far faster than bare wire, the same real HEAC-near-pipe conduction the engine already runs." },
  -- chain 2 -- packed ice/snow chilled far below freezing at the Advanced Lab's cryo coil
  { out="NICE", n=2, need={ICE=4, SNOW=2}, st="advlab", txt="Nitrogen Ice",
    desc="Ice and snow chilled far past freezing in the Advanced Lab's cryo coil -- solid nitrogen ice, stable enough to carry without a tank. Melts back to LN2 at the slightest warmth." },
  -- chain 2 -- downstream of NICE, deliberately no separate source so it can't outrun it
  { out="FRZZ", n=1, need={NICE=1, SNOW=3}, st="advlab", txt="Freeze Powder",
    desc="Nitrogen ice ground fine and mixed with packed snow -- an unstable freezing powder that keeps spreading its own cold into anything it touches, including regular water." },
  -- chain 17 -- independent of the not-yet-live PSTE economy, same colloid-under-pressure identity
  { out="PSTS", n=1, need={GOO=3, CLST=2}, st="research", txt="Pressed Paste",
    desc="Dirt and clay compressed into a firm colloidal solid at the research bench -- the same real pressure-cure PSTE itself undergoes, built directly instead of waiting on a separate liquid-paste economy." },
  -- real Simulation.cpp WTRV-below-273K deposition chemistry, abstracted (WTRV itself never held)
  { out="RIME", n=2, need={WATR=2, ICE=2}, st="advlab", txt="Rime Frost",
    desc="Water flash-boiled to steam then chilled far below freezing in the cryo coil -- deposits straight to solid rime, skipping the liquid phase entirely, exactly like real steam does when it cools too fast to condense." },
  -- real FIRE.cpp LAVA(STNE)+pressure>=30 -> ROCK chemistry, abstracted (no ROCK-alias collision, see header)
  { out="ROCK", n=1, need={STNE=6}, st="anvil", txt="Fused Rock",
    desc="Stone re-melted and hammer-quenched under sustained pressure at the anvil -- the same real molten-stone-under-pressure transition the engine already runs, done on purpose instead of by accident." },
  -- chain 17 -- independent of the not-yet-live RSST economy, same photon-cured identity
  { out="RSSS", n=1, need={CU=2, QRTZ=2}, st="advlab", txt="Solid Resist",
    desc="Copper and quartz fused into a pressure-blocking, electricity-insulating solid at the Advanced Lab -- the same resist chemistry RSST itself cures into under photon exposure, built directly." },
  -- part2 chain -- literal STKM spawn-point marker, repurposed as a real placed camp beacon
  { out="SPWN", n=1, need={WOOD=4, CLST=2}, st="workbench", txt="Camp Beacon",
    desc="A stickman spawn-point marker, framed and placed as a camp waypoint -- exactly the engine's own real spawn-point behaviour, given a player-facing purpose." },
  { out="SPWN2", n=1, need={WOOD=6, CLST=3, GOLD=1}, st="workbench", txt="Companion Beacon",
    desc="A second spawn-point marker for a placed companion waypoint -- pricier than the player's own camp beacon, same real engine marker underneath." },
  -- chain 10 -- independent of the beehive RNG roll (MWAX not yet wired to it), self-contained
  { out="WAX", n=2, need={GOO=2, PLNT=2}, st="furnace", txt="Beeswax (Rendered)",
    desc="Dirt-bound plant resins rendered down over low, steady heat -- a working substitute for true beehive wax that doesn't depend on finding a wild hive first." },
  -- part2 chain 17
  { out="ANAR", n=2, need={CLST=3, COAL=1}, st="research", txt="Anti-air Dust",
    desc="Clay dust treated with a cold-burning reagent at the research bench -- defies gravity and burns cold instead of hot, a niche jetpack/balloon fuel upgrade." },
  -- part2 chain 17 -- real concrete: aggregate + water, cured. Deliberately not proposed as terrain
  -- fill (falldown=1, fails the ADR-003 solid-terrain rule) -- see the element's own description.
  { out="CNCT", n=3, need={STNE=3, WATR=1}, st="workbench", txt="Concrete",
    desc="Crushed stone mixed with water and left to cure -- real concrete. Stacks on itself or on Rock but crumbles under pressure, so it's decorative, not structural fill." },
  { out="DUST", n=3, need={STNE=2}, st="anvil", txt="Fine Dust",
    desc="Stone ground fine at the anvil -- very light, flammable mining tailings, finally worth collecting instead of losing to the wind." },
  -- real YEST.cpp HighTemperatureTransition=DYST@373K, given a deliberate recipe form
  { out="DYST", n=1, need={YEST=1}, st="furnace", txt="Dead Yeast",
    desc="Yeast left too long near real furnace heat overcooks past 373K into dead yeast -- the same transition the engine already runs on YEST, just given a deliberate recipe instead of an accident." },
  { out="GRAV", n=2, need={QRTZ=2}, st="research", txt="Velocity Dust",
    desc="Quartz sheared at high velocity on a spinning-blade attachment -- a very light dust that visibly changes colour with its own speed, useful as an automation read-out." },
  { out="YEST", n=2, need={WHEAT=2, WATR=1}, st="furnace", txt="Yeast",
    desc="Wheat and water left to proof near steady furnace warmth (its own real ~37C growth condition) -- yeast, the farming tier's first quality ingredient." },
  -- T6 sandbox-cosmetic curio per part2's own classification -- never gates progression
  { out="BIZS", n=1, need={GOLD=3, QRTZ=3, DMND=1}, st="advlab", txt="Bizarre Curio",
    desc="An inert cabinet curiosity assembled from precision off-cuts -- no known scientific use, purely a collector's trophy for players who've cleared the tech tree." },
  -- NOTE: chain 7's own BGLA->GLAS / PQRT->QRTZ recycling-recovery recipes were deliberately left
  -- OUT of this list. scripts/check_reachable.py's own parse_mineable() only reads rpg.lua's single
  -- literal R.MINEABLE table (documented in its source, not a bug) -- it cannot see the R.MINEABLE.
  -- BGLA/PQRT additions this file makes at runtime (they are real and correct in-game, VERIFIED by
  -- GLAS.cpp/QRTZ.cpp's own pressure-delta update() code, see header), so a recipe consuming BGLA or
  -- PQRT as a `need` reads as demand against an input the static checker cannot prove reachable and
  -- fails the gate. Ran the checker, saw exactly that FAIL, removed both recipes rather than ship
  -- past a gate this task explicitly says to run and paste. BGLA/PQRT remain obtainable (mineable)
  -- either way; only the optional remelt-back-to-GLAS/QRTZ bonus loop is deferred.
}
local function installRecipes()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(ACQ_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
end
installRecipes()
hook(R.hooks.newworld, function() installRecipes() end)

if R.tlog then
  R.tlog("info", TAG, "loaded", { recipes = #ACQ_RECIPES, mineable_added = 5, names_added = 26 })
end

-- ================================================================================================
-- CHANGELOG LINES for the coordinator to land in rpg.lua's R.CHANGELOG (rpg.lua owns R.VERSION;
-- this plugin does not touch it, per convention documented at rpg.lua:800). One line per discrete
-- change, player-facing language, per CLAUDE.md's "every little micro change" rule.
-- ================================================================================================
-- "Material acquisition (@acq_solids): Vine, Sawdust, Broken Glass and Powdered Quartz were already
--  appearing in the world on their own (vines from ordinary plant growth, sawdust/broken glass/
--  powdered quartz from the game's own physics) but couldn't be picked up -- all four are now
--  mineable with the starting pick."
-- "Material acquisition (@acq_solids): Broken Electronics is now mineable -- it's what the existing
--  EMP Charge weapon already leaves behind when it hits your own wiring."
-- "Material acquisition (@acq_solids): 18 new craftable materials that had no acquisition path --
--  Ceramic and Dry Ice at the furnace; Nitrogen Ice, Freeze Powder, Rime Frost and Solid Resist and
--  Optic Filter at the Advanced Lab; Heat Conductor, Pressed Paste, Anti-air Dust and Velocity Dust
--  at the Research Bench; Fused Rock and Fine Dust at the Anvil; Concrete, Camp Beacon, Companion
--  Beacon, Beeswax, Yeast and Dead Yeast at the Workbench/Furnace. A rare Bizarre Curio is craftable
--  at the Advanced Lab as a late-game collector trophy."
