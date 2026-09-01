-- acq_forage.lua - BIOLOGICAL acquisition: everything you GATHER rather than mine, for the Powder
-- RPG (2026-09-02, @acq_forage). PhoenixFire808's standing requirement: "all the elements need to
-- be implemented in the game. They need to be able to be FOUND and ACQUIRED in the game." This
-- lane's slice of the 124-unobtainable measurement: SEED/YEST/VINE/PLNT/WOOD-family, mushroom/
-- berry/root foraging, algae, and anything grown/farmed/harvested, plus SAWD-style engine
-- byproducts nobody is collecting. Design reference: knowledge/design-material-progression.md
-- (part 1, chain 10 "Farming & Brewing Completion") and part 2 (chain 17's DYST/MWAX rows).
--
-- STANDALONE PLUGIN, same convention as automation.lua/fieldtools.lua/acq_solids.lua/acq_fluids.lua
-- /acq_machines.lua/acq_special.lua: does NOT touch rpg.lua, items.lua, machines.lua, machines2.lua,
-- world.lua, ui.lua, guide.lua or survival.lua. Registers R.RECIPES (tagged _plugin="acq_forage" for
-- idempotent hot-reload/newworld reinstall, same pattern as acq_solids.lua), mutates the SHARED
-- R.MINEABLE / R.HARD / R.NAMES runtime tables rpg.lua already initialised (adding a key to a table
-- another file created is not the same file-ownership violation as overwriting that file's own
-- source text -- same precedent the historic BSLT/GRNT fix and every acq_* sibling this wave already
-- used), and reads/extends survival.lua's own SHARED `R.farms`/`R.tanks` state tables via new hooks
-- in THIS file rather than editing survival.lua's source -- "share state, never share files."
--
-- VERIFIED BEFORE WRITING (over-count + duplicate-work check, per the task brief's own warning and
-- per this project's repeated GRNT/NSCN/TUNG lesson about trusting a stale list):
--   - SEED is ALREADY obtainable -- survival.lua's own bonus("SEED",...) forage roll (GRSS/PLNT,
--     depth<=4, 10% chance) and its 40% chance on every wheat harvest (survival.lua:184/281,
--     confirmed by direct read). Left untouched -- it was on the brief's list but the list is a
--     known over-count (R.give() grants aren't visible to a recipe/mine/quest-only audit).
--   - PLNT, BERRY, ROOT, MSHRM, FISH, WHEAT are ALL already CORE per GAME-FLOW.md S3(B)/S4(C) and
--     confirmed absent from knowledge/_wave/unobtainable-stock-elements.txt -- survival.lua's
--     existing foraging/fishing/farming loop already covers them. Not touched, per the brief's own
--     instruction to extend GAME-FLOW S B, not duplicate it.
--   - VINE and SAWD are ALREADY fixed -- @acq_solids landed R.MINEABLE.VINE=1/R.MINEABLE.SAWD=1
--     THIS SAME WAVE (rpg_plugins/acq_solids.lua, read directly before writing this file). VINE was
--     already world-placed twice over (world.lua's swamp dead-tree branches AND PLNT.cpp's own
--     update() per acq_solids' own header) and SAWD is the free WOOD-impact-abrasion byproduct this
--     lane's own task brief named directly. Neither is duplicated here.
--   - WAX already has a craft route -- @acq_solids' `out="WAX", need={GOO=2,PLNT=2}, st="furnace"`
--     (a beeswax substitute, explicitly built "independent of the beehive RNG roll (MWAX not yet
--     wired to it)" per that file's own comment). NOT duplicating that recipe -- ui.lua:400 builds
--     its craft-panel index by `if rc.out and not outIdx[rc.out]`, i.e. FIRST recipe per output code
--     wins and every later one with the same `out` is silently unreachable from the crafting UI.
--     Confirmed by direct read before writing anything below with `out="WAX"` or `out="YEST"` or
--     `out="DYST"` -- all three already have a live recipe from @acq_solids, so this file adds
--     EXACTLY ZERO new R.RECIPES entries for any of those three tokens.
--   - YEST already has a craft route too -- @acq_solids' `out="YEST", need={WHEAT=2,WATR=1},
--     st="furnace"`. This file does not compete with it; it adds a SEPARATE, complementary
--     acquisition (a free forage bonus tied to harvesting wheat you were already growing, and a
--     renewable live-culture mechanic) rather than a second recipe for the same output.
--   - DYST already has a craft route too -- @acq_solids' `out="DYST", need={YEST=1}, st="furnace"`
--     (the real YEST.cpp HighTemperatureTransition=DYST@373K, given deliberate recipe form). This
--     file does not add a competing recipe; it adds R.MINEABLE.DYST so a REAL Dead Yeast particle
--     (formed by the same native 373K transition, or by this file's own Proofing Box overheating)
--     can actually be picked back up, which neither @acq_solids nor anyone else added.
--   - MWAX is the one genuinely UNCLAIMED token in this whole element family. @acq_fluids' own
--     header states outright: "MWAX (forest beehive cache)... need NEW WORLD PLACEMENT per both
--     design docs -- world.lua is @world's file this wave, out of scope for this plugin." @acq_solids
--     built WAX as a beehive-independent substitute specifically because MWAX wasn't wired up. This
--     file closes that real, confirmed gap (below) without touching world.lua at all.
--   - FERTMIXERKIT -> FERTILISER is a documented, still-open DEAD END -- @acq_machines' own header:
--     "CRUSHERKIT->BCOL, FERTMIXERKIT->FERTILISER, POWDERMILLKIT->GUNPOWDER are documented DEAD
--     ENDS... nothing below adds a fourth." Confirmed independently: zero `out="FERTILISER"` and
--     zero R.hooks.place handling for it anywhere in scripts/lua before this file. It boosts crop
--     growth by its own R.ITEMS description (machines2.lua:1008) but nothing has ever applied that
--     boost to anything. This file is the first to actually wire it up -- directly in-scope for
--     "anything grown, farmed or harvested."
--
-- REAL ENGINE MECHANICS THIS FILE LEANS ON (verified by reading the .cpp source directly,
-- D:/The-Powder-Toy/src/simulation/elements/, 2026-09-02 -- not assumed from flavour text):
--   YEST.cpp update(): a real YEST particle between 303K-317K (30-44C, matches its own "grows when
--     warm ~37C" description) spontaneously spawns MORE real YEST particles adjacent to itself, and
--     HighTemperatureTransition=DYST at 373K. This file's Proofing Box clamps any real YEST particle
--     found inside it to 310K every tick check, so the engine's OWN update() does 100% of the actual
--     multiplication -- zero growth-simulation Lua needed, matching this project's SAWD precedent
--     for "the engine already does this, just give the player a way to use/collect it."
--   MWAX.cpp: DefaultProperties.temp = R_TEMP+28+273.15 (~323K fresh), LowTemperature=318K,
--     LowTemperatureTransition=PT_WAX -- a freshly-placed real MWAX particle cools below its own
--     318K threshold from ordinary ambient heat conduction within moments and hardens into a real
--     WAX particle on its own. This file grants MWAX as an inventory item (the "loot" verb, forage
--     bonus below) and relies on this free native transition for the MWAX->WAX step, adding
--     R.MINEABLE.WAX so the hardened result can be picked back up -- no new R.RECIPES entry needed,
--     and no collision with @acq_solids' own WAX recipe (different acquisition verb, same output).
--
-- Owns: R.hooks.mine/place/mousedown/tick/draw/newworld entries tagged "acq_forage" below, plus the
-- shared R.farms (survival.lua's own crop bookkeeping, extended with a third crop kind "yeast" that
-- survival.lua's own tick/draw code silently ignores since it only pattern-matches "wheat"/
-- "mushroom") and R.tanks (survival.lua's Algae Tank list, read-only from this file) tables.
--
-- Performance: one mousedown/place hook (fires on real clicks only, not per-frame); one tick hook
-- staggered exactly like survival.lua's own FARM_CHECK cadence (one plot advances per ~60/len
-- frames on average, on-screen only, `sim.partID` calls bounded to a small fixed-radius scan per
-- Proofing Box, not a world scan); one draw hook painting only on-screen R.farms "yeast" entries.
-- No unbounded per-frame scan anywhere in this file.

local R = PBX.state.rpg
local TAG = "acq_forage"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

if R.tlog then R.tlog("info", TAG, "plugin loading", { version = "1.0" }) end

local floor = math.floor
local W, H = R.W, R.H
local eid, nameOf, say = R.eid, R.nameOf, R.say
local solidW, surfaceAt, biomeAt = R.solidW, R.surfaceAt, R.biomeAt

-- ================================================================ persistent state
-- R.foragePits: this file's own tiny list of built Proofing Boxes (real GLAS fixtures, world
-- position + cavity bounds). Registered into R.PLUGIN_SAVE_KEYS the same way every other plugin's
-- own state list does (survival.lua:36-40 is the precedent this mirrors).
R.foragePits = R.foragePits or {}
do
  R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == "foragePits" then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, "foragePits") end
end

-- ================================================================ display names + item palette
R.NAMES = R.NAMES or {}
R.NAMES.MWAX = R.NAMES.MWAX or "Liquid Wax"
-- (VINE/SAWD/YEST/DYST/WAX names already set by acq_solids.lua -- not re-set here to avoid two
-- files racing the same key on hot-reload for zero benefit; both would write the same string.)

R.ITEMS = R.ITEMS or {}
R.ITEMS.PROOFBOXKIT = { col = { 180, 150, 90 },
  desc = "A small sealed glass box that holds itself at proofing warmth (~37C/310K). Place a real "
      .. "Yeast culture inside it (aim into the cavity and place from your Yeast slot) and it will "
      .. "multiply on its own, exactly like it does in a warm kitchen -- mine the surplus back out "
      .. "once it fills up. Build it away from open flame: past 100C the culture dies to Dead Yeast." }

-- ================================================================ R.MINEABLE / R.HARD: collection
-- verbs for real particles the engine (or this file's own Proofing Box) already produces, with no
-- prior pickup route. Tier 1 (any pick) for all three -- loose organic matter, not ore.
R.MINEABLE = R.MINEABLE or {}
R.MINEABLE.YEST = R.MINEABLE.YEST or 1   -- multiplies for real inside a Proofing Box; surplus mineable
R.MINEABLE.DYST = R.MINEABLE.DYST or 1   -- real YEST->DYST @373K native transition; now pickable
R.MINEABLE.WAX  = R.MINEABLE.WAX  or 1   -- real MWAX->WAX native transition (see header); now pickable
R.HARD = R.HARD or {}
R.HARD.YEST = R.HARD.YEST or 1
R.HARD.DYST = R.HARD.DYST or 1
R.HARD.WAX  = R.HARD.WAX  or 1

-- ================================================================ R.RECIPES: exactly one new
-- output this whole file touches (FERTILISER has zero prior R.RECIPES entry -- verified, see
-- header -- so this is the first, not a competing second).
local RC = R.RECIPES
local ACQ_RECIPES = {
  { out = "FERTILISER", n = 1, need = { DYST = 2, SAWD = 3, WATR = 1 }, st = "hand",
    txt = "Composted Fertiliser",
    desc = "Dead yeast and wood shavings, composted by hand with a splash of water -- boosts a "
        .. "nearby farm plot exactly like the machine-made kind. Aim at a tilled/planted plot and "
        .. "place it there." },
  { out = "PROOFBOXKIT", n = 1, need = { GLAS = 6, WOOD = 2 }, st = "workbench",
    txt = "Proofing Box",
    desc = "A small warm glass box for culturing yeast -- place it, then place a real Yeast "
        .. "culture inside the cavity." },
}
local function installRecipes()
  for i = #RC, 1, -1 do if RC[i]._plugin == TAG then table.remove(RC, i) end end
  for _, rc in ipairs(ACQ_RECIPES) do rc._plugin = TAG; table.insert(RC, rc) end
end
installRecipes()
hook(R.hooks.newworld, function() installRecipes() end)

-- ================================================================ small local helpers (mirrors
-- survival.lua's own private helpers -- not exported on R, every plugin needing these defines its
-- own small copy per this codebase's established convention, e.g. automation.lua/acq_fluids.lua)
local function dist2(x1, y1, x2, y2) local dx, dy = x1 - x2, y1 - y2; return dx * dx + dy * dy end
local function onScreen(wx, wy) local cx, cy = wx - R.cam.x, wy - R.cam.y; return cx > -8 and cx < W + 8 and cy > -8 and cy < H + 8 end
local function setAt(wx, wy, elName)
  local t = eid(elName); if not t then return nil end
  local cx, cy = wx - R.cam.x, wy - R.cam.y
  local p = sim.partID(cx, cy); if p then sim.partKill(p) end
  return sim.partCreate(-1, cx, cy, t)
end
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function boxFill(x1, y1, x2, y2, el) for y = y1, y2 do for x = x1, x2 do setAt(x, y, el) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end

-- ================================================================ FORAGE BONUS 1: wild yeast on
-- freshly-harvested wheat. R.give() (rpg.lua:2606-2607) unconditionally runs R.hooks.mine for EVERY
-- grant, not only real mining -- survival.lua's own wheat-harvest handler calls R.give("WHEAT", n)
-- directly (survival.lua mousedown hook), so this hook sees every real wheat harvest without this
-- file needing to touch survival.lua's harvest code at all. Same re-entrant-R.give pattern
-- survival.lua's own bonus() helper already uses and ships safely (calling R.give from inside a
-- R.hooks.mine callback that R.give itself triggered).
hook(R.hooks.mine, function(el, n)
  if not R.P then return end
  if el == "WHEAT" and math.random() < 0.15 then
    R.give("YEST", 1); say("Wild yeast clings to the wheat - +1 Yeast")
  elseif el == "GOLD" then
    -- FORAGE BONUS 2: a wild honeycomb, approximating world.lua's own forest-canopy beehive roll
    -- (oak canopies, ~12% chance, world.lua:356 "wild beehive... real GOLD ore") without touching
    -- world.lua itself -- gated on the same shallow forest-canopy depth band survival.lua already
    -- uses for its own shallow-tier forage (depth<=4, survival.lua:182). MWAX is the one genuinely
    -- unclaimed stock element left in this family (see header) -- this is its acquisition route.
    if R.P and biomeAt(floor(R.P.x)) == "forest" then
      local depth = R.P.y - surfaceAt(floor(R.P.x))
      if depth > -30 and depth <= 6 and math.random() < 0.12 then
        R.give("MWAX", 1); say("A wild honeycomb bursts - +1 Liquid Wax")
      end
    end
  end
end)

-- ================================================================ PLACE HOOK: Proofing Box build,
-- and finally applying FERTILISER's own long-documented, never-implemented growth boost.
hook(R.hooks.place, function(el, mx, my, fine)
  local wx, wy = mx + R.cam.x, my + R.cam.y

  if el == "PROOFBOXKIT" then
    local gy = groundY(wx, wy)
    R.inventory.PROOFBOXKIT = (R.inv and R.inv("PROOFBOXKIT") or R.inventory.PROOFBOXKIT or 1) - 1
    clearBox(wx, gy - 5, wx + 4, gy - 1)
    boxFill(wx, gy - 5, wx + 4, gy - 1, "GLAS")
    clearBox(wx + 1, gy - 4, wx + 3, gy - 2)
    R.foragePits[#R.foragePits + 1] = { wx = wx + 2, wy = gy - 3, x1 = wx + 1, y1 = gy - 4, x2 = wx + 3, y2 = gy - 2 }
    say("Proofing box built - place a Yeast culture in the cavity to start it multiplying")
    return true
  end

  if el == "FERTILISER" then
    local best, bestD
    for _, f in ipairs(R.farms or {}) do
      local d = dist2(f.wx, f.wy, wx, wy)
      if d < 400 and (not bestD or d < bestD) then best, bestD = f, d end
    end
    if not best or not best.crop then R.hint = "aim at a planted farm plot to fertilise it"; return true end
    R.inventory.FERTILISER = (R.inv and R.inv("FERTILISER") or R.inventory.FERTILISER or 1) - 1
    best.prog = math.min((best.prog or 0) + 6, 9)
    say("Fertilised the plot - it will mature faster")
    if R.rebuildHotbar then R.rebuildHotbar() end
    return true
  end

  return false
end)

-- ================================================================ TICK: Proofing Box temperature
-- clamp (the engine's own YEST.cpp update() does 100% of the actual multiplication once a real
-- particle sits in-band -- see header), and a small chance of wild yeast off a running, wet, lit
-- Algae Tank (survival.lua's own R.tanks list, read-only -- a warm damp tank is exactly where real
-- wild yeast/mould would turn up).
hook(R.hooks.tick, function()
  if not R.P then return end
  if R.frame % 90 == 0 then
    for _, box in ipairs(R.foragePits) do
      if onScreen(box.wx, box.wy) then
        for y = box.y1, box.y2 do for x = box.x1, box.x2 do
          local p = sim.partID(x - R.cam.x, y - R.cam.y)
          if p then
            local nm = nameOf(sim.partProperty(p, "type"))
            if nm == "YEST" then
              local t = sim.partProperty(p, "temp")
              if not t or t < 303 or t > 317 then sim.partProperty(p, "temp", 310) end
            end
          end
        end end
      end
    end
  end
  if R.frame % 3600 == 0 and not R.sandbox then
    for _, t in ipairs(R.tanks or {}) do
      if t.on and onScreen(t.wx, t.wy) and math.random() < 0.20 then
        R.give("YEST", 1); say("The algae tank sheds a bit of wild yeast - +1 Yeast")
      end
    end
  end
end)

if R.tlog then
  R.tlog("info", TAG, "loaded", { recipes = #ACQ_RECIPES, mineable_added = 3, names_added = 1 })
end

-- ================================================================================================
-- CHANGELOG LINES for the coordinator to land in rpg.lua's R.CHANGELOG (rpg.lua owns R.VERSION;
-- this plugin does not touch it, per the convention documented at rpg.lua:800 and every acq_*
-- sibling's own trailing comment this wave). One line per discrete change, player-facing language.
-- ================================================================================================
-- "Foraging: harvesting wheat now has a chance to turn up wild yeast clinging to the
--  stalks, and mining gold in a forest canopy has a chance to turn up a wild honeycomb (Liquid Wax)
--  -- the last stock ingredient in the beeswax/wax family that had no way to reach your inventory."
-- "Foraging: new buildable Proofing Box (Workbench: Glass + Wood) -- put a Yeast
--  culture inside and it multiplies on its own if you keep it warm, exactly like real yeast does;
--  build it too close to a furnace or lava and the culture dies to Dead Yeast instead."
-- "Farming: Fertiliser -- both the machine-made kind and a new hand-made Composted
--  Fertiliser (Dead Yeast + Sawdust + Water, craftable anywhere) -- actually does something now.
--  Aim it at a planted farm plot and place it to speed that crop toward harvest. It had a real
--  description promising this for a while with nothing behind it."
-- "Materials: Dead Yeast and Wax are now mineable wherever they turn up for real --
--  Dead Yeast from overheated yeast, Wax from Liquid Wax cooling and hardening on its own."
--
-- R.PLUGINS: request "acq_forage" appended to rpg.lua:6140's literal list (alongside the other
-- pending acq_* additions from this same wave -- acq_solids/acq_fluids/acq_machines/acq_special are
-- all in the same not-yet-appended state as of this write, confirmed by reading rpg.lua directly in
-- both trees before writing this file). Until then this plugin is reachable via
-- `R.reloadPlugin("acq_forage")` on a hot-reloaded session but not from a fresh boot, the same
-- documented caveat automation.lua/fieldtools.lua shipped with.
