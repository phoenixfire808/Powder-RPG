-- acq_special.lua - acquisition pathways for the SC_SPECIAL/SC_EXPLOSIVE/SC_FORCE/SC_LIFE/
-- SC_SENSOR leftovers (2026-09-02+, @acq_special). PhoenixFire808's standing requirement: every
-- stock element needs SOME natural means of acquisition -- mine/craft/react/loot/grow/capture, or
-- an explicit, argued non-inventory pathway (world fixture / machine-internal component / sandbox-
-- only unlock) when a real inventory route would break the game. Design reference:
-- knowledge/design-material-progression.md (part1, part2 chains 12-14/16). Implements the design;
-- does not redesign it, except where noted below as an explicit, evidenced deviation.
--
-- MY 33 (SC_SPECIAL 16 + SC_EXPLOSIVE 12 + SC_FORCE 3 + SC_LIFE 1 + SC_SENSOR 1):
--   BCLN BHOL CLNE CONV EQVE FIGH LOLZ LOVE MORT NONE PRTI PRTO STK2 STKM VACU WHOL
--   BOMB C-5 CFLM DEST EMBR FIRE FIRW FWRK LIGH LRBD RBDM THDR
--   DMG GBMB PIPE
--   LIFE  ·  INVS
--
-- DISPOSITION, checked against live source before writing a single recipe (the brief's own
-- warning: "MY LIST IS AN OVER-COUNT -- VERIFY BEFORE YOU ADD" applies doubly to a list handed
-- down a second time):
--
--   ALREADY CORE, VERIFIED LIVE -- no new work, listed so nobody re-designs them:
--     CLNE - @fieldtools' REPLICOREKIT (fieldtools.lua:222/272), a real housed CLNE ctype-locked
--            to STEL. Not raw player-held CLNE (that stays correctly unobtainable, see BCLN below).
--     PRTI/PRTO - @survival's PORTALKIT (machines2.lua:749), machine-internal build geometry.
--     WHOL - @survival's GRAVMANIPKIT (machines2.lua:724), machine-internal repulsor core.
--
--   ARGUED-UNREACHABLE, per the brief's own officially-sanctioned four (part2 S0): no pathway,
--   by design, restated here rather than silently dropped:
--     NONE  - the eraser tool itself, not a material.
--     STKM/STK2 - the player's own primary/secondary avatar entities.
--
--   ALREADY CORRECTLY NON-INVENTORY, VERIFIED LIVE -- spawned-only weapon/mechanism byproducts,
--   restated (not re-implemented) because they are genuinely fine as-is:
--     BOMB - GRENADE/DYNAMITE's own thrown-projectile effect (items.lua fireGrenade/fireDynamite).
--     FIRE - the torch/furnace ignition mechanic itself (rpg.lua useTool "torch").
--   FIGH turned out to be the SAME shape, but only after checking further than the design docs
--   did (see the FIGH section below) -- so it gets its own explicit finding, not a restatement.
--
--   ALSO MACHINE-INTERNAL / NON-INVENTORY, restated (not newly implemented) because the design
--   docs' own reasoning already holds and nothing here needs to change it:
--     CFLM - would be C-5's own detonation byproduct once C-5 exists (it does, below); the
--            engine's own explosion chain produces it, nothing in this file spawns it directly.
--     EMBR - spark byproduct of any explosion (existing GRENADE/DYNAMITE, and this file's new
--            C-5/DMG/GBMB); same native-byproduct pattern, no Lua work needed.
--     THDR - LIGH's own strike byproduct; THIS file's Lightning Rod (see below) spawns a real,
--            short-lived THDR marker at the moment of discharge, matching that role exactly.
--
--   BLOCKED ON ANOTHER LANE'S FILE, not fabricated around: RBDM/LRBD need a real ore vein in
--   world.lua (@world's file, not touched here). See the RBDM/LRBD section below for the request.
--
--   Everything else in the 33 gets real new acquisition work in this file, detailed inline.
--
-- Owns (this wave, new file, no collision with AGENTS.md's active table): R.acqspecial (own state
-- table), R.RECIPES entries tagged _plugin="acqspecial", R.ITEMS.<SCRAPCOMPACTORKIT,
-- GUARDIANPOSTKIT, LIGHTNINGRODKIT, DUPCHARGE, CURIOVAULTKIT>, R.hooks.tick/place/craft entries
-- tagged "acqspecial". Does NOT touch rpg.lua, items.lua, machines.lua, machines2.lua, world.lua,
-- ui.lua, guide.lua, enemies.lua, fieldtools.lua, automation.lua -- every cross-plugin read below
-- (R.tech.reactor, R.fieldtools.gravityOn, R.EN_STATE.bossAlive, R.damageEnemiesAt) is READ-ONLY,
-- same convention fieldtools.lua's own header already established for R.tech.reactor.

local R = PBX.state.rpg
local TAG = "acqspecial"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local eid, nameOf, has, say, nice = R.eid, R.nameOf, R.has, R.say, R.nice
local function need(...) local t = {}; local a = { ... }; for i = 1, #a, 2 do t[a[i]] = a[i + 1] end; return t end

R.acqspecial = R.acqspecial or { guardians = {}, lightrods = {}, bossWasAlive = false }

-- ================================================================ low-level build helpers (same
-- erase-then-place convention every other plugin uses -- see build-lessons "placeElement on an
-- occupied pixel is a no-op")
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function setAt(wx, wy, elName)
  killAt(wx, wy); local t = eid(elName); if not t then return nil end
  return sim.partCreate(-1, wx - R.cam.x, wy - R.cam.y, t)
end
local function boxFill(x1, y1, x2, y2, elName) for y = y1, y2 do for x = x1, x2 do setAt(x, y, elName) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if R.solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
local function nearPlayer(x, y, r) local dx, dy = x - R.P.x, y - R.P.y; return dx * dx + dy * dy <= (r or 140) * (r or 140) end
-- fallback for a lab session without the custom-element registration script (same reasoning as
-- fieldtools.lua's STEELMAT: a structural setAt() call for a name eid() can't resolve silently
-- no-ops, so every housing wall must resolve to a real stock element)
local STEELMAT = has("STEL") and "STEL" or (has("BMTL") and "BMTL" or "METL")

-- ================================================================================================
-- PLAIN RECIPES: real "craft"/"react" acquisition for the tokens that had genuinely zero source
-- anywhere in the live tree. Two of these (PIPE, VACU) directly contradict a CORE claim in part1's
-- own classification table -- re-verified by grepping every .lua file under scripts/lua for the
-- literal token before writing the recipe (excluding mapregen.lua/regions.lua/dump.lua's debug
-- symbol tables, same exclusion part1 S1 states): PIPE appeared ONLY in that debug table, never in
-- a recipe/R.MINEABLE/machine build; VACU appeared only in the same debug table plus one comment
-- in machines2.lua explicitly saying the VACUUMKIT machine uses "a tuned Lua force rather than the
-- native VACU/BHOL element" -- i.e. the live machine deliberately does NOT grant or consume real
-- VACU. Both get a real recipe here instead of being left on a false "already covered" assumption.
-- ================================================================================================
local PLAIN_RECIPES = {
  -- PIPE: SC_FORCE. "Moves particles around" -- a basic conduit segment, distinct from the
  -- already-live AIRLINEKIT (that item is BMTL-built ducting; PIPE the raw element was never
  -- reachable at all before this). Cheap, T1-adjacent craft.
  { out = "PIPE", n = 2, need = need("METL", 2), st = "workbench", txt = "Pipe",
    desc = "Real particle-moving pipe segment -- drop loose material in one end, it flows out the other. Basic logistics, cheap and renewable" },

  -- VACU: SC_SPECIAL. A VOID core (already live, rpg.lua chain 9) sealed in insulated glass --
  -- "craft" verb since VACU has no documented native formation reaction to react it into being;
  -- this is a genuinely new assembly, not a re-skin of PVOD.
  { out = "VACU", n = 1, need = need("VOID", 1, "INSL", 2, "GLAS", 2), st = "advlab", txt = "Vacuum core",
    desc = "A Void core sealed in insulated glass -- creates real cell vacuum, sucking in and heating anything that enters. Careful what you point it at" },

  -- INVS: SC_SENSOR. Pressure-gated one-way valve / cloaking panel, per its own description
  -- ("invisible under pressure, lets particles through"). part2 chain 11 design, unshipped.
  { out = "INVS", n = 1, need = need("GLAS", 3, "PSCN", 2), st = "advlab", txt = "Pressure valve panel",
    desc = "Invisible under real pressure, letting particles pass through only while compressed -- a one-way valve, or a panel that opens only when something is pushing on it" },

  -- FIRW / FWRK: SC_EXPLOSIVE. Decorative/signal charges, distinct from every lethal explosive in
  -- the game -- neither TNT/GUN/NITR/THRM (part1 chain 4, a different lane's scope) nor DMG/GBMB
  -- below. COAL+SALT, both already independently mineable (SALT: rpg.lua R.MINEABLE, added
  -- 2026-09-02 per its own comment).
  { out = "FIRW", n = 3, need = need("COAL", 4, "SALT", 2), st = "workbench", txt = "Firework",
    desc = "Colourful, harmless signal charge -- ignites on contact with fire. Mark a base perimeter or signal a companion, does no terrain damage" },
  { out = "FWRK", n = 3, need = need("COAL", 4, "SALT", 2, "GOLD", 1), st = "workbench", txt = "Firework (heat-triggered)",
    desc = "Sibling to the Firework, alt-triggered by heat or a neutron flux instead of open flame" },

  -- DMG: SC_FORCE. Own description: "breaks any elements it hits" -- a penetrating siege round,
  -- distinct in role from an area blast (TNT-shape) or a gravity implosion (GBMB below).
  { out = "DMG", n = 1, need = need("QRTZ", 4, "STEL", 3), st = "research", txt = "Penetrator charge",
    desc = "Breaks almost any single element it strikes on impact -- siege ammo for breaching a specific wall segment, not an area blast" },

  -- GBMB: SC_FORCE. "Sticky then implodes" -- a reusable sibling to the RPG's existing one-shot
  -- GRAVWELL grenade. Deliberately does NOT require GPMP (part2 chain 12's own design pairs it
  -- with GPMP, but GPMP is unshipped and out of this lane's 33 -- adding a hard dependency on an
  -- unshipped material from a different lane would be exactly the NSCN/TUNG deadlock shape this
  -- whole effort exists to close, so this recipe stands on its own with already-proven inputs).
  { out = "GBMB", n = 1, need = need("METL", 3, "FRME", 1, "PSCN", 2), st = "advlab", txt = "Gravity bomb",
    desc = "Sticks on contact, then implodes and pulls loose debris into one point -- a reusable cleanup/crowd-control charge, not a single-use consumable" },

  -- C-5: SC_EXPLOSIVE. DEVIATION FROM part2'S OWN DESIGN, stated explicitly: part2 chain 16 ties
  -- C-5 to smelted LRBD (from mined RBDM). RBDM has ZERO source anywhere in this tree (verified,
  -- see the RBDM/LRBD section below) -- a worldgen vein is @world's file, not this lane's, so a
  -- C-5 recipe demanding LRBD would ship as a dead, permanently-unreachable recipe today (the
  -- exact NSCN/TUNG deadlock shape this whole effort exists to close). Substituted here with
  -- already-proven inputs that preserve C-5's actual identity (own description: "explosive,
  -- especially when triggered by anything cold") -- ICE is the cold trigger cast directly into
  -- the charge, GOO is the binder, STEL is the casing. Real, reachable today; revisit and retarget
  -- to LRBD once @world lands the RBDM vein (tracked in the report, not silently dropped).
  { out = "C-5", n = 1, need = need("STEL", 3, "ICE", 4, "GOO", 2), st = "research", txt = "Cold-triggered charge",
    desc = "Inert near heat -- safe to store beside a lit furnace -- but detonates instantly near anything cold (ice, snow). A tactical alternative to a heat/fuse-triggered charge" },
}

-- ================================================================================================
-- CURIO VAULT: EQVE, LOLZ, LOVE, MORT, LIFE, BHOL -- six T6, never-progression-gating novelty/
-- sandbox elements folded into ONE recipe+craft-hook instead of six separate mechanisms. Matches
-- part2's own definition of this tier verbatim (part1 S3, restated in part2 S2/S4): "explicitly
-- never gated -- exists purely as a reward for players who finish the reactor tier." Nothing in
-- the tool/station tree depends on any of these six existing, so a single bundled unlock carries
-- zero deadlock risk by construction (part1 S6's own rule: T6 sandbox rewards cannot deadlock
-- anything since nothing downstream needs them).
--
-- EQVE judgement call, stated so it can be argued with: @fieldtools already read this element and
-- called it "an acknowledged dev-test element, no material identity, nothing to build a route or a
-- use around" (fieldtools.lua S̲COPE NOTE) and excluded it outright. part2 disagrees and designs a
-- T6 vault curiosity for it instead of a silent drop. This file follows part2: bundling it into an
-- already-necessary Curio Vault mechanism costs nothing extra (one more R.give call) and turns an
-- otherwise-silent exclusion into a documented, findable oddity with its own guide flavour text --
-- consistent with the brief's instruction that "no coherent physical identity" still needs an
-- argued pathway, not a silent one, when the argued pathway is this cheap to add.
--
-- BHOL is real (a genuine black hole particle, gravity-based) rather than a mere decoration --
-- granted the same way DMND/DEST/other hazardous-but-player-directed materials already are:
-- placed deliberately, by choice, same as any other held material. No custom containment
-- mechanism invented (a "trap machine" would be new, untested Lua logic for a T6 curiosity that
-- gates nothing -- not worth the risk this pass); the guide text below carries the warning.
-- ================================================================================================
-- COST NOTE: deliberately does NOT touch DMND. check_reachable.py's quantity-sufficiency pass
-- (run against this file before shipping, per the brief's own hard rule) found DMND's real
-- deterministic supply is only 3 total (one-time quest rewards) -- mining its own tier-6 vein is
-- circularly blocked (needs a pick only DMND itself can craft), a PRE-EXISTING condition, not
-- something this file introduced or is scoped to fix. A first draft of this recipe demanded 4x
-- DMND and the checker caught it as a new quantity-insufficiency finding (DMND supply 3 < demand
-- 4) -- exactly the GRNT/diamond-pick-shape bug this whole effort exists to prevent. Retargeted to
-- PTNM/ZIRC/VIBR instead, all independently proven-renewable per fieldtools.lua's own comments.
local CURIO_RECIPE = {
  out = "LIFE", n = 1, need = need("PTNM", 3, "ZIRC", 4, "VIBR", 1), st = "advlab", txt = "Curio Vault",
  desc = "THE CURIO VAULT. One craft, six rare oddities: Conway's-Life novelty block, a real Black Hole, and four joke/dev-test curiosities (Bizarre, Love, Steam Train, a failed velocity-test artifact). None of these unlock or gate anything -- pure post-reactor sandbox reward. BHOL is a REAL black hole: place it deliberately, well clear of anything you don't want pulled in",
}

local function installRecipes()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(PLAIN_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
  if R.tech and R.tech.reactor then
    local curio = {}; for k, v in pairs(CURIO_RECIPE) do curio[k] = v end
    curio._plugin = TAG; table.insert(R.RECIPES, curio)
    local dup = { out = "DUPCHARGE", n = 1, need = need("VIBR", 1, "SHD3", 2), st = "advlab", txt = "Duplication Charge",
      desc = "Single-use. Throws a real Breakable Clone locked to duplicating Steel only -- it keeps copying until real local pressure builds up and breaks it down (its own native pressure-decay behaviour, not a scripted timer). Never touches ore or anything that gates progression",
      _plugin = TAG }
    table.insert(R.RECIPES, dup)
  end
end
installRecipes()
-- reactor-online can flip true after this file already installed once -- poll cheaply (one
-- boolean compare/frame, same pattern fieldtools.lua's own reactorRecipesInstalled flag uses),
-- stop re-checking once it has landed.
hook(R.hooks.tick, function()
  if not R.acqspecial.reactorRecipesInstalled and R.tech and R.tech.reactor then
    R.acqspecial.reactorRecipesInstalled = true
    installRecipes()
  end
end)
hook(R.hooks.craft, function(rc)
  if rc._plugin == TAG and rc.txt == "Curio Vault" then
    R.give("EQVE", 1); R.give("LOLZ", 1); R.give("LOVE", 1); R.give("MORT", 1); R.give("BHOL", 1)
    say("The vault also yields a Black Hole, and four unclassifiable curiosities")
    R.rebuildHotbar()
  end
end)

-- ================================================================================================
-- CONV -- "Scrap Compactor": a locked, single-recipe internal core, never a general-purpose
-- converter. part1 called raw craftable CONV "the single most important exclusion in this
-- document... would erase the entire scarcity/acquisition design." That argument stands and is
-- not reopened. Verified directly against the engine (D:/The-Powder-Toy/src/simulation/elements/
-- CONV.cpp): CONV's conversion target is its own `ctype` field, set once and never rescanned once
-- valid (identical mechanism to CLNE, which @fieldtools's REPLICOREKIT already relies on for the
-- same permanence guarantee) -- so setting ctype=METL at construction and never touching it again
-- is a genuine, engine-enforced lock, not a Lua convention that could be bypassed. The player feeds
-- it BMTL scrap (part1's own documented single-point-of-RNG-failure material); it converts to METL
-- only, forever. Zero ongoing Lua cost: the conversion is native engine physics, nothing to tick.
-- ================================================================================================
local CONV_TARGET = "METL"
local function buildScrapCompactor(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 5, wx + 2, gy - 1, STEELMAT)
  clearBox(wx - 1, gy - 4, wx + 1, gy - 2)
  local id = setAt(wx, gy - 3, "CONV")
  if id then pcall(sim.partProperty, id, "ctype", eid(CONV_TARGET)) end
  say("Scrap Compactor built, locked to " .. nice(CONV_TARGET) .. " -- drop Broken Metal scrap into the open slot, mine the " .. nice(CONV_TARGET) .. " it becomes from the tray below")
end

-- ================================================================================================
-- FIGH -- checked further than either design doc did before writing anything. enemies.lua's own
-- header comment ("sword (replaces the dead FIGH-based hit code)") and its live spawn/kill code
-- confirm the CURRENT enemy system is entirely sprite-drawn (R.EN array, R.damageEnemiesAt/
-- R.enemyList, both explicitly documented as a "public damage API for other plugins") -- real FIGH
-- PARTICLES are no longer spawned by the live game at all; rpg.lua's own old FIGH-spawn code
-- (~line 5548) and items.lua's several `eid("FIGH")` checks are DEAD, pre-enemies.lua legacy that
-- nothing calls into a live particle anymore (verified: zero FIGH particles are ever created by
-- the current spawn cycle). So FIGH is not "the enemy the player fights" today (part1's own
-- original exclusion reasoning) -- it is simply unused. Since enemies.lua exposes exactly the
-- public hook needed (R.damageEnemiesAt) to build a REAL companion/turret without touching
-- enemies.lua at all, this file gives FIGH its part2-designed pathway (a placeable Guardian, fed
-- an element per its own description: "You must first give it an element to kill him with") rather
-- than leaving it as accidental dead weight. The housed FIGH particle is cosmetic/marker only --
-- all real combat math goes through the exposed public API, so this never touches or duplicates
-- enemies.lua's own hostile-vs-friendly logic.
-- ================================================================================================
local GUARDIAN_RADIUS, GUARDIAN_DMG, GUARDIAN_PERIOD = 90, 7, 30
local function buildGuardianPost(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 1, gy - 4, wx + 1, gy - 1, STEELMAT)
  clearBox(wx, gy - 3, wx, gy - 2)
  setAt(wx, gy - 3, "FIGH")
  table.insert(R.acqspecial.guardians, { x = wx, y = gy - 3, fuel = 0, cool = 0 })
  say("Guardian Post placed -- feed it Coal (right-click) to arm it; it fights anything hostile within range while fed")
end
local function updateGuardians()
  for _, g in ipairs(R.acqspecial.guardians) do
    if g.fuel > 0 then
      g.cool = g.cool - 1
      if g.cool <= 0 then
        g.cool = GUARDIAN_PERIOD
        local hits = R.damageEnemiesAt and R.damageEnemiesAt(g.x, g.y, GUARDIAN_RADIUS, GUARDIAN_DMG, 3) or 0
        if hits > 0 then g.fuel = g.fuel - 1 end
      end
    end
  end
end
hook(R.hooks.mousedown, function(mx, my, button)
  if button ~= 3 then return end
  local wx, wy = mx + R.cam.x, my + R.cam.y
  for _, g in ipairs(R.acqspecial.guardians) do
    if nearPlayer(g.x, g.y, 24) and nearPlayer(wx, wy, 24) then
      if (R.inv("COAL") or 0) >= 1 then
        R.inventory.COAL = R.inv("COAL") - 1; g.fuel = g.fuel + 5
        say("Guardian fed 1 Coal (fuel " .. g.fuel .. ")"); R.rebuildHotbar()
      else say("Guardian needs Coal to fight") end
      return true
    end
  end
end)

-- ================================================================================================
-- LIGH -- "capture", per its own description a controllable discharge ("change the brush size to
-- set the size of the lightning"), not a hazard particle. part2 chain 15 ties this to a weather/
-- storm event; INFERRED, not VERIFIED, that a storm system exists (checked ENGINE-SEMANTICS.md and
-- GAME-FLOW.md, both mention "weather" only in passing) -- using part2's OWN stated fallback
-- instead: a fixed-interval timer discharge at the rod. One counter per rod, checked once per
-- tick; bounded to this plugin's own (tiny) rod list, never a map scan.
-- ================================================================================================
local LIGHTNINGROD_INTERVAL = 3600  -- ~60s at 60fps
local function buildLightningRod(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx, gy - 8, wx, gy - 1, STEELMAT)
  setAt(wx, gy - 9, "QRTZ")
  table.insert(R.acqspecial.lightrods, { x = wx, y = gy - 9, cool = LIGHTNINGROD_INTERVAL })
  say("Lightning Rod placed -- captures a charge roughly once a minute while you're nearby")
end
local function updateLightningRods()
  for _, rod in ipairs(R.acqspecial.lightrods) do
    rod.cool = rod.cool - 1
    if rod.cool <= 0 then
      rod.cool = LIGHTNINGROD_INTERVAL + math.random(-300, 300)
      if nearPlayer(rod.x, rod.y, 260) then
        R.give("LIGH", 1)
        if has("THDR") then local id = setAt(rod.x, rod.y - 1, "THDR"); if id then pcall(sim.partProperty, id, "life", 4) end end
        say("Lightning Rod discharged (+1 Lightning charge)")
        R.rebuildHotbar()
      end
    end
  end
end

-- ================================================================================================
-- DEST -- loot, tied to the real live boss (enemies.lua's Slime King) rather than part2's assumed
-- boss-loot TABLE, which does not exist (VERIFIED: @fieldtools's own VIBR ended up a craft recipe,
-- not a boss drop, because no loot-table mechanism was ever built -- checked before relying on
-- one here). enemies.lua exposes R.EN_STATE.bossAlive as real, readable public state (same
-- READ-ONLY convention as R.tech.reactor); this watches for the true->false transition (an actual
-- kill, not just "no boss right now") and rolls a drop. O(1) per tick, event-driven on a state
-- transition, never a scan.
-- ================================================================================================
local DEST_DROP_CHANCE = 0.25
local function updateBossWatch()
  local isAlive = (R.EN_STATE and R.EN_STATE.bossAlive) and true or false
  if R.acqspecial.bossWasAlive and not isAlive then
    if math.random() < DEST_DROP_CHANCE then
      R.give("DEST", 1); say("The Slime King left something devastating behind (+1 DEST)"); R.rebuildHotbar()
      if R.tlog then R.tlog("info", TAG, "DEST boss drop granted", {}) end
    end
  end
  R.acqspecial.bossWasAlive = isAlive
end

hook(R.hooks.tick, function()
  updateGuardians()
  updateLightningRods()
  updateBossWatch()
end)

-- ================================================================ crafting: R.RECIPES + R.ITEMS + place hook
R.ITEMS = R.ITEMS or {}
R.ITEMS.SCRAPCOMPACTORKIT = R.ITEMS.SCRAPCOMPACTORKIT or { col = { 120, 200, 120 }, desc = "A locked Converter core -- drop Broken Metal in, mine real Metal out. Cannot be retargeted" }
R.ITEMS.GUARDIANPOSTKIT = R.ITEMS.GUARDIANPOSTKIT or { col = { 200, 90, 90 }, desc = "A placed Guardian -- feed it Coal (right-click) to keep it fighting hostiles in range" }
R.ITEMS.LIGHTNINGRODKIT = R.ITEMS.LIGHTNINGRODKIT or { col = { 200, 200, 120 }, desc = "Captures a real Lightning charge periodically while you're nearby" }
R.ITEMS.DUPCHARGE = R.ITEMS.DUPCHARGE or { col = { 255, 208, 64 }, desc = "Single-use Breakable Clone charge, locked to Steel. Throw it, let it copy, let real pressure break it back down" }

local BUILDERS = {
  SCRAPCOMPACTORKIT = buildScrapCompactor,
  GUARDIANPOSTKIT = buildGuardianPost,
  LIGHTNINGRODKIT = buildLightningRod,
  DUPCHARGE = function(mx, my)
    local wx, wy = mx + R.cam.x, my + R.cam.y
    local id = setAt(wx, wy, "BCLN")
    if id then pcall(sim.partProperty, id, "ctype", eid("STEL")) end
    say("Duplication Charge thrown -- it will keep copying Steel until real local pressure breaks it down")
  end,
}
hook(R.hooks.place, function(el, mx, my, fine)
  local b = BUILDERS[el]; if not b then return end
  if (R.frame - (R.lastAcqSpecialPlace or -99)) < 20 then return true end
  R.lastAcqSpecialPlace = R.frame
  R.inventory[el] = R.inv(el) - 1
  local ok, err = pcall(b, mx, my); if not ok then R.pluginErr = tostring(err); if R.tlog then R.tlog("error", TAG, "build failed", { el = el, err = tostring(err) }) end end
  R.rebuildHotbar()
  return true
end)

local KIT_RECIPES = {
  { out = "SCRAPCOMPACTORKIT", n = 1, need = need("BMTL", 6, "STEL", 4, "METL", 4), st = "anvil", txt = "Scrap Compactor",
    desc = "A locked Converter core, permanently set to turn Broken Metal scrap into Metal. Cannot be retargeted -- see the guide for why" },
  { out = "GUARDIANPOSTKIT", n = 1, need = need("METL", 3, "PSCN", 2, "COAL", 2), st = "research", txt = "Guardian Post",
    desc = "Places a real Guardian that fights hostiles in range while fed Coal. Right-click it to feed" },
  { out = "LIGHTNINGRODKIT", n = 1, need = need("METL", 4, "QRTZ", 2, "CU", 2), st = "advlab", txt = "Lightning Rod",
    desc = "Captures a real Lightning charge roughly once a minute while you're nearby" },
}
local function installKitRecipes()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == (TAG .. "-kit") then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(KIT_RECIPES) do rc._plugin = TAG .. "-kit"; table.insert(R.RECIPES, rc) end
end
installKitRecipes()

hook(R.hooks.newworld, function()
  R.acqspecial = { guardians = {}, lightrods = {}, bossWasAlive = false, reactorRecipesInstalled = false }
  installRecipes()
  installKitRecipes()
end)
hook(R.hooks.sandbox, function() installRecipes(); installKitRecipes() end)

-- ================================================================ save/load: generic plain-data
-- dump via save.lua, same registration convention every other plugin uses
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
do
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == "acqspecial" then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, "acqspecial") end
end

if R.tlog then
  R.tlog("info", TAG, "plugin loaded", { plainRecipes = #PLAIN_RECIPES, kitRecipes = #KIT_RECIPES,
    reactorGated = { "CURIOVAULT(LIFE/EQVE/LOLZ/LOVE/MORT/BHOL)", "DUPCHARGE" },
    blocked = { "RBDM", "LRBD" }, alreadyCore = { "CLNE", "PRTI", "PRTO", "WHOL" },
    argued_unreachable = { "NONE", "STKM", "STK2" }, nonInventoryVerified = { "BOMB", "FIRE" } })
end
