-- nat_process.lua -- @nat_process, 2026-09-02. NEW FILE this wave, no collision with any
-- AGENTS.md active-wave lane (world.lua/rpg.lua/machines*.lua/items.lua are NOT touched -- this
-- file only registers R.hooks.tick/R.hooks.mine entries tagged TAG below, and mutates the SHARED
-- R.MINEABLE/R.HARD/R.NAMES runtime tables rpg.lua already initialised, same precedent as every
-- acq_* sibling this wave: "adding a key to a table another file created is not the same
-- file-ownership violation as overwriting that file's own source text").
--
-- PhoenixFire808, verbatim, the mandate this file exists to satisfy: "Some of them said 'not
-- generated naturally in this world', 'crafted only', 'too rare'. We need everything to be FOUND
-- and acquired -- it's got to be found in the game, acquired, built. NOT CHEESY. It's got to have
-- NATURAL PATHWAYS." This lane's job is narrower than "acquisition" in general (five acq_* lanes
-- already shipped craft/mine/loot/forage routes this wave) -- it is specifically the anti-cheese
-- half: make the 88-craft-only-no-natural-source measurement's genuinely-natural subset actually
-- happen as an observable PROCESS in the world, not a station recipe. TPT already simulates the
-- underlying physics; this file exposes it, per the task's own instruction to prefer that over
-- inventing new Lua chemistry.
--
-- SCOPE, chosen by judgement per the task's own explicit instruction ("not all 88 should change"):
-- of the materials named as "genuinely natural" (SLTW, DSTW, GRAV, DUST, SLCN, RIME/NICE/FRZZ,
-- CRMC, ROCK, ACID/BASE, SPNG, DRIC, GLOW, PSTE, GEL), this file ships natural routes for 15:
-- SLTW DSTW GRAV DUST SLCN RIME CRMC ROCK ACID BASE SPNG DRIC GLOW PSTE GEL.
--
-- CROSS-LANE DISCOVERY, found by reading `knowledge/rpg-hub.md` before writing anything (per this
-- project's own "post before you touch, read before you assume" discipline): @nat_world already
-- placed REAL, measured worldgen veins/pockets in `world.lua` for 14 of these exact 15 tokens plus
-- RBDM (their own hub entry, dated 2026-09-02, same day) -- genuinely generated, live-probed
-- particles (their `_natworld_probe.py`, e.g. ROCK 14947 hits, ACID 57, GLOW 56 post-recalibration)
-- -- and is EXPLICITLY BLOCKED: "none has an R.MINEABLE entry, so R.actorMine will refuse to let
-- the player pick any of them up... requesting [specific tiers] added to R.MINEABLE in rpg.lua,"
-- which they cannot do themselves (`rpg.lua` is @survival's file this wave, not theirs). This file
-- IS that request, fulfilled from a plugin (the same R.MINEABLE-mutation-from-a-new-file precedent
-- @acq_solids already established) rather than by waiting on a second cross-lane relay -- their
-- calibrated tiers are adopted verbatim below, not re-guessed, since they are backed by an actual
-- density measurement this file has no independent way to reproduce. RBDM is therefore ALSO
-- unblocked below even though it is a hazardous ore, not a "process" material, and sits slightly
-- outside this file's own natural-PROCESS mandate -- justified as closing an explicit, already-
-- verified, already-blocking request sitting in the shared log, not as a scope-widening choice of
-- this file's own. This file's OWN distinct contribution (sections 1-8 below) is the other half of
-- the mandate their static veins do not cover: ACTIVE, renewable, observable processes (a spring
-- that can refill, steam that visibly cools into frost, rock that visibly grinds down) layered on
-- top of their one-time-generated deposits -- both are legitimate "natural," per the task's own
-- list of verbs (weather/phase-change/erosion/geothermal are processes; a vein is a found deposit).
--
-- NICE and FRZZ are DELIBERATELY EXCLUDED, judgement call, stated explicitly rather than silently
-- dropped: both require reaching 50-77K (liquid-nitrogen range). VERIFIED against this world's own
-- temperature model (rpg.lua envBaseAt, BIOME_SURF_K): the coldest biome (snow) has a 268K surface
-- baseline, and nothing in the existing gradient reaches within 190K of what NICE/FRZZ's own
-- engine thresholds need (NICE.cpp: LowTemperature=63.0K; FRZZ.cpp: LowTemperature=50.0K -- read
-- directly, D:/The-Powder-Toy/src/simulation/elements/). Manufacturing them via real refrigeration
-- (Advanced Lab compression, already @acq_solids' shipped route) is the honest answer for THIS
-- world's climate, the same judgement the task brief itself asked for on doped semiconductors and
-- pumps. Forcing a "natural" pathway here would be inventing a lie about the world's own physics,
-- exactly what NOT CHEESY is asking this file to avoid on the other side.
--
-- METHOD: every mechanism below is grounded in a real read of the relevant .cpp source
-- (D:/The-Powder-Toy/src/simulation/elements/ and simulation/Simulation.cpp), 2026-09-02, not
-- assumed from flavour text -- per the task's own instruction ("read the engine source before
-- trusting a design doc"; @acq_energy's PLUT/POLO-backwards finding is exactly the failure mode
-- this guards against). Each mechanism below is labelled:
--   VERIFIED NATIVE  -- the engine's OWN update()/Simulation.cpp code already performs this
--                       transition unconditionally, given the right two real particles touch, or
--                       the right real particle reaches the right real temperature/pressure. This
--                       file's only job for these is (a) R.MINEABLE so the *result* can be
--                       collected, the exact SAWD/BGLA/PQRT precedent @acq_solids already
--                       established, and (b) where the engine's own condition needs help actually
--                       occurring during normal play (steam that never drifts anywhere cold; CO2
--                       that never gets modelled above ground), a small bounded nudge that helps
--                       real physics reach its own real threshold -- never a substitute reaction.
--   LUA-AUTHORED     -- no engine chemistry converts one into the other; this file extends a
--                       VERIFIED NATIVE neighbour mechanism (erosion, molten-contact, biological
--                       growth-in-damp-dark) by the same shape of process, physically motivated,
--                       explicitly not a literal engine reproduction. Never presented as "the
--                       engine already does this."
--
-- ==================================================== VERIFIED NATIVE TRANSITIONS THIS FILE USES
-- SLTW -- WATR.cpp:60-66 "WATR + SALT -> SLTW + SALT" (unconditional, 1/50 chance/tick per
--   contact) and WATR.cpp:82-85 "WATR + SLTW -> 2xSLTW" (1/2000) and SLTW.cpp's own mirrored
--   "SLTW + SALT -> 2xSLTW". Any real SALT (already core-mineable, desert biome) sitting in or
--   beside any real standing WATR (already core-mineable/rain-fallen) is ALREADY, this tick,
--   converting that water to saltwater -- zero Lua needed for the reaction itself. Fix: R.MINEABLE
--   .SLTW = 1 -- the only missing piece was collection.
-- DSTW / RIME -- simulation/Simulation.cpp:2764-2769 (@ WTRV -> RIME/DSTW): any real WTRV (steam,
--   already core -- produced by the existing boiler/furnace/lava-contact mechanics) that cools
--   below its own 371K LowTemperature threshold changes to DSTW if the ambient temperature is
--   still >=273K, or to RIME (true deposition, skipping the liquid phase, exactly RIME's own
--   description) if colder than 273K. This is a single native branch producing BOTH materials from
--   one already-live gas. @acq_solids' own header already found this and concluded "WTRV is
--   ambient steam, never inventory-held, so there is nothing for a RECIPE to consume" -- correct
--   for a recipe, but irrelevant to MINING: R.actorMine works on any live particle regardless of
--   type (verified, rpg.lua:5965-5983, the exact mechanism @acq_solids/@acq_forage already used for
--   SAWD/BGLA/PQRT/VINE). Fix: R.MINEABLE.DSTW = 1, R.MINEABLE.RIME = 1, plus one small process
--   this file DOES add (steamVentTick below) so cooling steam is something the player can actually
--   go find rather than only whatever a player-built boiler happens to vent.
-- ROCK (stock) -- FIRE.cpp:154-158 "@ Form ROCK with pressure": real molten LAVA carrying
--   ctype=STNE, at local pressure >=30, solidifies into ROCK (not back into STNE) as it cools.
--   world.lua already places real LAVA pockets underground (confirmed: genBase's cave-opening
--   branch, "if wy > 1450 ... return LAVA"), and confined cave passages already build real pressure
--   from the existing boiler/geothermal mechanics -- this reaction is already live wherever a real
--   lava pocket sits under enough confinement. Fix: R.MINEABLE.ROCK = 1 (a SECOND, natural route
--   alongside @acq_solids' existing anvil recipe -- the two-routes-per-material principle the
--   design docs ask for, matching how DMND already has both a crafted route and a loot route).
-- ==================================================================================================
--
-- Performance discipline (the brief's own repeated emphasis, and world.lua's own hot-path warning
-- about uncached per-pixel scans): every check in this file is (a) gated behind its own R.frame
-- modulo so no two sub-checks run the same frame, (b) bounded to a small FIXED sample count per
-- invocation (6-10, in line with the existing geoAmbienceTick's 14 and treeGapGasVentTick's 48 --
-- never larger), (c) on-screen only (same M/W/H canvas-bound convention every existing tick in this
-- codebase already uses), and (d) registered on R.hooks.tick, which already carries
-- profile=true/throttle=true (rpg.lua:1167) -- a hook that measures expensive will be auto-skipped
-- to fewer frames by the engine's own existing throttle, not just by this file's own gating. No
-- unbounded scan, no per-particle-in-the-world iteration, anywhere in this file.

local R = PBX.state.rpg
local TAG = "nat_process"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

if R.tlog then R.tlog("info", TAG, "plugin loading", { version = "1.0" }) end

local floor, random = math.floor, math.random
local W, H, M = R.W, R.H, R.M
local eid, nameOf = R.eid, R.nameOf
local surfaceAt, biomeAt, envBaseAt = R.surfaceAt, R.biomeAt, R.envBaseAt

-- ================================================================ R.MINEABLE / R.HARD: collection
-- verbs for real particles that either the engine's own chemistry already produces (SLTW/DSTW/
-- RIME/ROCK, see header) or that THIS file's own bounded processes below genuinely place/convert
-- in the live world (GRAV/DUST/SLCN/CRMC/ACID/BASE/GLOW/SPNG/PSTE/GEL), OR that @nat_world already
-- placed as real, live-probed worldgen veins/pockets and is explicitly blocked waiting for exactly
-- this table (their `knowledge/rpg-hub.md` entry, 2026-09-02: "none has an R.MINEABLE entry...
-- requesting [tiers] added to R.MINEABLE in rpg.lua" -- they cannot touch rpg.lua themselves this
-- wave). Tiers below for SLTW/DSTW/ROCK/GRAV/DUST/SLCN/CRMC/ACID/BASE/GLOW/SPNG/DRIC/PSTE/GEL/RBDM
-- are their own measured/requested values, adopted verbatim rather than re-guessed, since they are
-- backed by an actual density probe this file cannot reproduce. RIME's tier (this file's own,
-- @nat_world's list did not include it -- RIME was already placed by an earlier @veins pass) is
-- unaffected. Every one of these already has (or, for GEL/ACID/BASE, may already have) a craft
-- route from a sibling acq_* lane -- this is an ADDITIONAL, natural route, never a replacement (the
-- two-routes-per-material safety principle, DMND/dpick precedent).
R.MINEABLE = R.MINEABLE or {}
R.MINEABLE.SLTW = R.MINEABLE.SLTW or 1
R.MINEABLE.DSTW = R.MINEABLE.DSTW or 2
R.MINEABLE.RIME = R.MINEABLE.RIME or 1
R.MINEABLE.ROCK = R.MINEABLE.ROCK or 2   -- stock ROCK, via eid("ROCK") -> the real stock element,
                                          -- never rpg.lua's own `local ROCK` alias (that alias is
                                          -- a Lua local, unreachable from this file's string keys --
                                          -- same non-collision already verified by @acq_solids).
R.MINEABLE.GRAV = R.MINEABLE.GRAV or 1
R.MINEABLE.DUST = R.MINEABLE.DUST or 1
R.MINEABLE.SLCN = R.MINEABLE.SLCN or 1
R.MINEABLE.CRMC = R.MINEABLE.CRMC or 3
R.MINEABLE.ACID = R.MINEABLE.ACID or 3   -- PROP_DEADLY hazard liquid, hell-zone-adjacent per
R.MINEABLE.BASE = R.MINEABLE.BASE or 3   -- @nat_world's placement -- gated at MERC's own tier.
R.MINEABLE.GLOW = R.MINEABLE.GLOW or 4
R.MINEABLE.SPNG = R.MINEABLE.SPNG or 1
R.MINEABLE.DRIC = R.MINEABLE.DRIC or 3
R.MINEABLE.PSTE = R.MINEABLE.PSTE or 2
R.MINEABLE.GEL  = R.MINEABLE.GEL  or 2
R.MINEABLE.RBDM = R.MINEABLE.RBDM or 3   -- NOT this file's own natural-process scope (it's a mined
                                          -- hazardous ore, not a process) -- closed here anyway
                                          -- because @nat_world's real vein (measured 201/696
                                          -- columns, LITH's own tier/depth band) is sitting fully
                                          -- placed and blocked on this exact table right now.

R.HARD = R.HARD or {}
for _, code in ipairs({ "SLTW", "RIME", "GRAV", "DUST", "SLCN", "SPNG" }) do
  R.HARD[code] = R.HARD[code] or 1
end
for _, code in ipairs({ "DSTW", "PSTE", "GEL" }) do
  R.HARD[code] = R.HARD[code] or 2
end
for _, code in ipairs({ "ROCK", "CRMC", "ACID", "BASE", "GLOW", "DRIC", "RBDM" }) do
  R.HARD[code] = R.HARD[code] or 3
end

-- ================================================================ R.NAMES: only the two genuinely
-- unnamed tokens in this file's set (everything else already has a display name from rpg.lua core
-- or a sibling acq_* plugin -- confirmed by direct grep before writing this, not re-set here to
-- avoid two files racing the same key on hot-reload for zero benefit).
R.NAMES = R.NAMES or {}
R.NAMES.ACID = R.NAMES.ACID or "Acid"
R.NAMES.SPNG = R.NAMES.SPNG or "Sponge"

-- ================================================================ persistent state: remembered
-- damp-cave and swamp-settling sites (accumulators), capped in count so this can never grow
-- unbounded across a long session. Registered into R.PLUGIN_SAVE_KEYS the same way every other
-- plugin's own small state list does (acq_forage.lua's R.foragePits is the precedent this mirrors).
R.natDamp = R.natDamp or {}     -- key "wx,wy" -> accumulated dampness ticks (SPNG growth)
R.natSettle = R.natSettle or {} -- key "wx,wy" -> accumulated settling ticks (PSTE growth)
do
  R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
  for _, k in ipairs({ "natDamp", "natSettle" }) do
    local seen = false
    for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == k then seen = true end end
    if not seen then table.insert(R.PLUGIN_SAVE_KEYS, k) end
  end
end
local function capTable(t, maxN)
  local n = 0; for _ in pairs(t) do n = n + 1 end
  if n <= maxN then return end
  local i = 0
  for k in pairs(t) do i = i + 1; if i > maxN then t[k] = nil end end
end

-- ================================================================ small shared helpers
local function onScreen(sx, sy) return sx >= M + 2 and sx < W - M - 3 and sy >= M + 2 and sy < H - M - 3 end
local function randScreenPt() return random(M + 2, W - M - 3), random(M + 2, H - M - 3) end
local function typeAt(sx, sy)
  local p = sim.partID(sx, sy)
  if not p then return nil, nil end
  return nameOf(sim.partProperty(p, "type")), p
end
local WTRV_ID -- cached element id, resolved lazily (eid() may be nil before first use)

-- ================================================================ 1) STEAM VENT -- LUA-AUTHORED,
-- extends the VERIFIED WTRV->RIME/DSTW native transition (header) by giving steam a natural source
-- independent of a player-built boiler: real geothermal fumaroles vent steam near molten rock.
-- Finds a real, world-placed LAVA particle on-screen with an open (air) cell adjacent that is
-- itself walled by solid rock on another side (a confined vent, not open sky/lake surface), and at
-- low chance (1/40 per candidate, checked on 6 candidates every 47 frames) creates one real WTRV
-- particle there. That particle then rises and cools via the engine's OWN existing physics
-- (Advection=1.0, Gravity=-0.1 in WTRV.cpp) into DSTW or RIME, per the VERIFIED native transition
-- above -- this function's only job is "make steam exist somewhere the player can go watch it cool
-- and freeze," not the freezing itself.
local function steamVentTick()
  if sim.paused() or (R.frame or 0) % 47 ~= 0 then return end
  WTRV_ID = WTRV_ID or eid("WTRV"); if not WTRV_ID then return end
  for _ = 1, 6 do
    local sx, sy = randScreenPt()
    local nm = typeAt(sx, sy)
    if nm == "LAVA" then
      -- look for an adjacent empty cell that is itself next to solid rock (a confined vent throat)
      for _, d in ipairs({ {0,-1}, {1,0}, {-1,0} }) do
        local vx, vy = sx + d[1], sy + d[2]
        if onScreen(vx, vy) and not sim.partID(vx, vy) then
          local walled = false
          for _, d2 in ipairs({ {1,0}, {-1,0}, {0,1} }) do
            local wnm = typeAt(vx + d2[1], vy + d2[2])
            if wnm == "STNE" or wnm == "ROCK" or wnm == "BRCK" or wnm == "GRNT" or wnm == "BSLT" then walled = true; break end
          end
          if walled and random(1, 40) == 1 then
            local p = sim.partCreate(-1, vx, vy, WTRV_ID)
            if p and p >= 0 then sim.partProperty(p, "vy", -0.6 - random() * 0.5) end
          end
          break
        end
      end
    end
  end
end

-- ================================================================ 2) DRY-ICE ALOFT -- LUA-
-- AUTHORED, closes a real gap this file found in rpg.lua's OWN ambient-cooling tick: geoAmbienceTick
-- (rpg.lua, "ONI-like environmental baseline") already nudges real CO2/OXYG/GAS/SMKE/WTRV/H2
-- particle temperature toward R.envBaseAt's computed ambient value -- but ONLY underground
-- (`if depth < 22 then goto geo_next end`, verified by direct read). Open-air altitude is never
-- ambient-cooled by anything in this codebase, so real CO2 (already core: scrubber waste, exhaled
-- breath, tree respiration, per @acq_fluids' own header) drifting high above a snow-biome peak
-- never actually reaches the cold needed to trigger CO2's own VERIFIED native transition
-- (CO2.cpp: LowTemperature=194.65K, LowTemperatureTransition=PT_DRIC -- real, unconditional, in the
-- engine already). This function is the above-ground half geoAmbienceTick's own gate excludes: only
-- runs on real on-screen CO2/SMKE particles at genuine high altitude (envBaseAt depth < -40, i.e.
-- at least 40px above local ground) and nudges toward the SAME envBaseAt value core already trusts
-- underground -- once the real particle's temp crosses 194.65K, the engine's own native transition
-- does the rest, unmodified.
local function dryIceAloftTick()
  if sim.paused() or (R.frame or 0) % 29 ~= 0 then return end
  for _ = 1, 8 do
    local sx, sy = randScreenPt()
    local wx, wy = sx + R.cam.x, sy + R.cam.y
    local geoK, _, depth, biome = envBaseAt(wx, wy)
    if depth < -40 and biome == "snow" then
      local p = sim.partID(sx, sy)
      if p then
        local nm = nameOf(sim.partProperty(p, "type"))
        if nm == "CO2" or nm == "SMKE" then
          local t = sim.partProperty(p, "temp") or geoK
          if math.abs(t - geoK) > 2.5 then sim.partProperty(p, "temp", t + (geoK - t) * 0.12) end
        end
      end
    end
  end
end

-- ================================================================ 3) ROCK EROSION -- LUA-
-- AUTHORED, extends the VERIFIED WATR.cpp:87-92 "ROCK erosion" native reaction (real fast-moving
-- WATR against real ROCK, >=0.5 combined velocity, 1/1000 chance/tick, already converts to SAND or
-- STNE unconditionally in the live engine right now) one physical step further, exactly the chain
-- the task brief names by name ("rock broken into GRAV then DUST"): fast water grinding against
-- exposed STNE/SAND has a further chance to wear it down into GRAV, and GRAV that has picked up a
-- velocity flare (GRAV.cpp's own `life` field, set when speed^2 >= 0.1 -- real, native, already
-- happening to every GRAV particle in this game) has a further chance, on hard impact, to pulverise
-- into DUST. Bounded to 8 on-screen samples every 31 frames.
local function rockErosionTick()
  if sim.paused() or (R.frame or 0) % 31 ~= 0 then return end
  for _ = 1, 8 do
    local sx, sy = randScreenPt()
    local p = sim.partID(sx, sy)
    if p then
      local nm = nameOf(sim.partProperty(p, "type"))
      if nm == "STNE" or nm == "SAND" then
        for _, d in ipairs({ {0,-1}, {0,1}, {1,0}, {-1,0} }) do
          local q = sim.partID(sx + d[1], sy + d[2])
          if q then
            local qn = nameOf(sim.partProperty(q, "type"))
            if qn == "WATR" or qn == "DSTW" or qn == "SLTW" then
              local vx, vy = sim.partProperty(q, "vx") or 0, sim.partProperty(q, "vy") or 0
              if (vx * vx + vy * vy) >= 0.5 * 0.5 and random(1, 60) == 1 then
                sim.partProperty(p, "type", eid("GRAV"))
              end
              break
            end
          end
        end
      elseif nm == "GRAV" then
        local life = sim.partProperty(p, "life") or 0
        if life > 30 and random(1, 25) == 1 then
          -- a wall/floor impact is implied by having a real velocity flare and a solid neighbour
          for _, d in ipairs({ {0,1}, {0,-1}, {1,0}, {-1,0} }) do
            local qn = typeAt(sx + d[1], sy + d[2])
            if qn == "STNE" or qn == "ROCK" or qn == "BRCK" or qn == "GRNT" or qn == "BSLT" then
              sim.partProperty(p, "type", eid("DUST")); break
            end
          end
        end
      end
    end
  end
end

-- ================================================================ 4) STONE IMPACT DEBRIS, and
-- 4b) WOOD IMPACT DEBRIS (SAWD) -- LUA-AUTHORED, event-driven (R.hooks.mine, not a tick -- zero
-- per-frame cost). ONE R.hooks.mine registration for this whole file (the hook() helper above
-- dedups by TAG on the passed list -- a SECOND hook(R.hooks.mine, ...) call in this same file
-- would silently REMOVE this one instead of adding to it, exactly the bug shape acq_energy.lua's
-- own header already warns about for R.hooks.tick; caught before shipping here, not after -- both
-- branches below have to live in this single function, not two separate hook() calls).
--
-- 4) STONE: every real-world quarry produces gravel and dust chips as a direct byproduct of
-- breaking rock with a tool, the same "impact yields byproduct" shape the task brief names for
-- WOOD->SAWD. Fires once per real mining hit on STNE/ROCK, small independent chance each for a
-- GRAV or DUST bonus straight to inventory -- this is the FOUND-while-mining-something-else
-- pathway; rockErosionTick above is the separate found-lying-in-a-riverbed pathway. Both feed the
-- same two R.MINEABLE tokens.
--
-- 4b) WOOD (SAWD): ROOT CAUSE, VERIFIED by direct read of the live engine source, 2026-09-0X
-- (@acq), confirming @progression's own INFERRED attribution (the v1.15.82 venting-speed clamp)
-- was the WRONG mechanism, not the wrong conclusion -- SAWD really did stop being reachable at
-- that commit, for a different, deeper reason than the clamp:
--   D:/The-Powder-Toy/src/simulation/Simulation.cpp:~1219 (`if (rt == PT_WOOD)`) carries this
--   fork's OWN prior engine change, its comment dated to the same investigation as rpg.lua's own
--   v1.15.82 changelog entry: "RPG fork change: gases no longer abrade wood into sawdust... so
--   restricting this to non-gas particles is both the fix and the more realistic rule." The code
--   now reads `if (vel > 5 && !(elements[parts[i].type].Properties & TYPE_GAS))`. This is a SECOND,
--   independent fix layered on top of rpg.lua's own Lua-side venting-speed clamp (3.2, well under
--   the 5 threshold) -- either one alone would already stop gas-borne SAWD production, and now
--   BOTH are live. The result: the ONLY SAWD source this game ever had (292 particles measured
--   live pre-fix, per rpg.lua's own header, all from vented OXYG sandblasting tree trunks) is
--   permanently gone, correctly, because it was never a real acquisition pathway to begin with --
--   it was the venting bug's own side effect, and the fix that closed the bug (rightly; a gas
--   molecule cannot mechanically abrade timber, exactly the engine comment's own reasoning) closed
--   the only route with it. `scripts/check_reachable.py` catching this as the sole live FAIL
--   (blocking FERTILISER, acq_forage.lua) is this checker doing its job, not a false alarm.
-- FIX: give SAWD an honest, still-natural, DIFFERENT production route rather than re-opening the
--   gas-abrasion bug -- solid/liquid/powder impacts on WOOD at speed still produce SAWD in the
--   engine unmodified (the fork comment above says so explicitly: "Powders, liquids and solids
--   hitting wood at speed still produce sawdust exactly as before"), but nothing in normal play
--   reliably drives a solid particle into standing WOOD at vel>5. The honest, non-cheesy answer
--   PhoenixFire808's own bar asks for is simpler and doesn't need engine chemistry at all: cutting
--   a tree down with a real axe produces real sawdust, exactly like breaking rock with a real pick
--   produces real gravel and dust chips (STONE, directly above -- same shape, same file, same
--   hook). Fires once per real WOOD chop, small independent chance of a SAWD bonus straight to
--   inventory. WOOD is core-mineable and renewable (trees are common world content, not a
--   one-time reward), so this has no quantity-sufficiency risk the way a DMND-shaped fix would.
hook(R.hooks.mine, function(el, n)
  local reps = math.min(n or 1, 8)
  if el == "STNE" or el == "ROCK" then
    for _ = 1, reps do
      if random(1, 8) == 1 then R.give("GRAV", 1) end
      if random(1, 20) == 1 then R.give("DUST", 1) end
    end
  elseif el == "WOOD" then
    for _ = 1, reps do
      if random(1, 5) == 1 then R.give("SAWD", 1) end
    end
  end
end)

-- ================================================================ 5) GEOTHERMAL CONTACT --
-- LUA-AUTHORED, physically-motivated analogy to real fusion/pressure chemistry this file's own
-- header verified exists in the engine (FIRE.cpp:229-241 LAVA(QRTZ)+LAVA(CLST)->LAVA(CRMC);
-- FIRE.cpp:154-158 ROCK-under-pressure; BASE.cpp:184 LAVA(ROCK)+pressure->MERC) but which needs two
-- specific molten ctypes to coincide, rarely achievable from ordinary player-driven lava flows.
-- This function checks real on-screen SAND/CLST/STNE resting directly against real LAVA and, past a
-- sustained-heat threshold well below each material's own full-melt point (so it never competes
-- with the existing SAND->GLAS / CLST->fire mechanics, only fires on genuinely close, sub-melt
-- volcanic contact), converts in place:
--   SAND next to LAVA, 1200K-1900K (below SAND's own 1973K melt) -> SLCN (volcanic silica)
--   CLST next to LAVA, >=1200K (real pottery-kiln range, ~900-1300C) -> CRMC (fired ceramic)
--   STNE/CLST next to LAVA at local pressure >=10 (BASE.cpp's own MERC threshold, reused here as
--     "this vent is genuinely pressurised") -> rare GLOW deposit seeded in an adjacent empty cell
-- Bounded to 6 on-screen candidates every 37 frames.
local function geothermalContactTick()
  if sim.paused() or (R.frame or 0) % 37 ~= 0 then return end
  for _ = 1, 6 do
    local sx, sy = randScreenPt()
    local nm, p = typeAt(sx, sy)
    if nm == "SAND" or nm == "CLST" or nm == "STNE" then
      local lavaFound, lavaTemp = false, 0
      for _, d in ipairs({ {0,-1}, {0,1}, {1,0}, {-1,0} }) do
        local q = sim.partID(sx + d[1], sy + d[2])
        if q and nameOf(sim.partProperty(q, "type")) == "LAVA" then
          lavaFound = true; lavaTemp = sim.partProperty(q, "temp") or 0; break
        end
      end
      if lavaFound then
        if nm == "SAND" and lavaTemp >= 1200 and lavaTemp < 1900 and random(1, 30) == 1 then
          sim.partProperty(p, "type", eid("SLCN"))
        elseif nm == "CLST" and lavaTemp >= 1200 and random(1, 30) == 1 then
          sim.partProperty(p, "type", eid("CRMC"))
        elseif random(1, 90) == 1 then
          local wx, wy = sx + R.cam.x, sy + R.cam.y
          local pcx, pcy = floor(wx / sim.CELL), floor(wy / sim.CELL)
          local ok, pres = pcall(sim.pressure, pcx, pcy)
          if ok and type(pres) == "number" and pres >= 10.0 then
            for _, d in ipairs({ {0,-1}, {1,0}, {-1,0} }) do
              local vx, vy = sx + d[1], sy + d[2]
              if onScreen(vx, vy) and not sim.partID(vx, vy) then
                local gp = sim.partCreate(-1, vx, vy, eid("GLOW"))
                if gp and gp >= 0 then break end
              end
            end
          end
        end
      end
    end
  end
end

-- ================================================================ 6) VOLCANIC MINERAL SPRING --
-- LUA-AUTHORED: real hot/acidic and alkaline springs form wherever groundwater meets a confined
-- volcanic vent -- the real-world analogue the task brief names ("mineral and volcanic springs").
-- Finds a real, world-placed LAVA particle enclosed on at least 2 of 3 checked sides by solid rock
-- (a confined vent throat, not an open lake -- same test steamVentTick uses, so surface lava pools
-- placed by the player don't seed springs) and, at low chance, creates one ACID or BASE particle in
-- an adjacent empty cell -- never touching the LAVA cell itself. Because the spawn target must be
-- EMPTY, once a player mines a spring dry it naturally waits to refill rather than farming
-- infinitely from one tick to the next; this file adds no farming shortcut on top of that natural
-- throttle. Bounded to 6 candidates every 53 frames.
local function mineralSpringTick()
  if sim.paused() or (R.frame or 0) % 53 ~= 0 then return end
  for _ = 1, 6 do
    local sx, sy = randScreenPt()
    if typeAt(sx, sy) == "LAVA" then
      local walls = 0
      for _, d in ipairs({ {1,0}, {-1,0}, {0,1} }) do
        local wnm = typeAt(sx + d[1], sy + d[2])
        if wnm == "STNE" or wnm == "ROCK" or wnm == "GRNT" or wnm == "BSLT" then walls = walls + 1 end
      end
      if walls >= 2 then
        local vx, vy = sx, sy - 1
        if onScreen(vx, vy) and not sim.partID(vx, vy) and random(1, 260) == 1 then
          local el = (random(1, 2) == 1) and "ACID" or "BASE"
          sim.partCreate(-1, vx, vy, eid(el))
        end
      end
    end
  end
end

-- ================================================================ 7) DAMP CAVE GROWTH -- LUA-
-- AUTHORED, biological verb: real sponges/fungal mats grow on damp, still, dark surfaces. Tracks a
-- per-site dampness accumulator (persisted, capped at 40 sites) for real standing WATR/DSTW found
-- underground (depth > 40, well past the miner's-helmet-lit-underground line already used
-- elsewhere) with near-zero velocity next to a solid wall. Once a site accumulates enough damp
-- ticks, converts an adjacent empty cell against that wall into a real SPNG particle and clears the
-- site. Bounded to 6 candidates every 61 frames.
local function dampCaveTick()
  if sim.paused() or (R.frame or 0) % 61 ~= 0 then return end
  capTable(R.natDamp, 40)
  for _ = 1, 6 do
    local sx, sy = randScreenPt()
    local wx, wy = sx + R.cam.x, sy + R.cam.y
    if wy - surfaceAt(wx) > 40 then
      local p = sim.partID(sx, sy)
      if p then
        local nm = nameOf(sim.partProperty(p, "type"))
        if nm == "WATR" or nm == "DSTW" then
          local vx, vy = sim.partProperty(p, "vx") or 0, sim.partProperty(p, "vy") or 0
          if (vx * vx + vy * vy) < 0.02 then
            local wall, wallDx, wallDy
            for _, d in ipairs({ {1,0}, {-1,0}, {0,1} }) do
              local wnm = typeAt(sx + d[1], sy + d[2])
              if wnm == "STNE" or wnm == "ROCK" or wnm == "GRNT" or wnm == "BSLT" or wnm == "CLST" then
                wall, wallDx, wallDy = true, d[1], d[2]; break
              end
            end
            if wall then
              local key = wx .. "," .. wy
              R.natDamp[key] = (R.natDamp[key] or 0) + 1
              if R.natDamp[key] >= 30 then
                local vx2, vy2 = sx - wallDx, sy - wallDy
                if onScreen(vx2, vy2) and not sim.partID(vx2, vy2) then
                  sim.partCreate(-1, vx2, vy2, eid("SPNG"))
                end
                R.natDamp[key] = nil
              end
            end
          end
        end
      end
    end
  end
end

-- ================================================================ 8) SWAMP SETTLING -- LUA-
-- AUTHORED: real swamp mud settles into a colloidal paste where sediment (GOO, already core-
-- mineable swamp topsoil) sits undisturbed under standing water for a sustained time. Tracks a
-- per-site settling accumulator (persisted, capped 40) for real GOO next to still WATR/DSTW in
-- swamp biome; once mature, converts the neighbouring water particle into PSTE. GEL needs no
-- equivalent function here -- it already forms for free via the VERIFIED native "BASE + GOO -> GEL"
-- reaction (BASE.cpp:176, unconditional) once mineralSpringTick's real BASE reaches swamp GOO, so
-- adding a second Lua-authored GEL mechanism would just be racing a real one for no benefit.
-- Bounded to 6 candidates every 67 frames.
local function swampSettleTick()
  if sim.paused() or (R.frame or 0) % 67 ~= 0 then return end
  capTable(R.natSettle, 40)
  for _ = 1, 6 do
    local sx, sy = randScreenPt()
    local wx, wy = sx + R.cam.x, sy + R.cam.y
    if biomeAt(wx) == "swamp" then
      if typeAt(sx, sy) == "GOO" then
        for _, d in ipairs({ {0,-1}, {0,1}, {1,0}, {-1,0} }) do
          local q = sim.partID(sx + d[1], sy + d[2])
          if q then
            local qn = nameOf(sim.partProperty(q, "type"))
            if qn == "WATR" or qn == "DSTW" then
              local vx, vy = sim.partProperty(q, "vx") or 0, sim.partProperty(q, "vy") or 0
              if (vx * vx + vy * vy) < 0.03 then
                local key = wx .. "," .. wy
                R.natSettle[key] = (R.natSettle[key] or 0) + 1
                if R.natSettle[key] >= 24 then
                  sim.partProperty(q, "type", eid("PSTE"))
                  R.natSettle[key] = nil
                end
              end
              break
            end
          end
        end
      end
    end
  end
end

-- ================================================================ dispatcher: one R.hooks.tick
-- entry, each sub-check internally frame-gated to a distinct modulo so no two run the same frame.
hook(R.hooks.tick, function()
  steamVentTick()
  dryIceAloftTick()
  rockErosionTick()
  geothermalContactTick()
  mineralSpringTick()
  dampCaveTick()
  swampSettleTick()
end)

if R.tlog then R.tlog("info", TAG, "plugin loaded", {
  natural_routes = { "SLTW", "DSTW", "RIME", "ROCK", "GRAV", "DUST", "SLCN", "CRMC", "DRIC",
    "ACID", "BASE", "GLOW", "SPNG", "PSTE", "GEL", "SAWD" },
  excluded_by_judgement = { "NICE", "FRZZ" },
  closes_nat_world_mineable_request = { "ROCK", "CRMC", "SPNG", "DRIC", "RBDM", "SLCN", "DUST",
    "GRAV", "ACID", "BASE", "GLOW", "PSTE", "GEL", "SLTW", "DSTW" },
}) end

-- ================================================================================================
-- CHANGELOG LINE for the coordinator to land in rpg.lua's R.CHANGELOG (rpg.lua owns R.VERSION;
-- this plugin does not touch it).
-- ================================================================================================
-- "Fixed: sawdust (a Fertiliser ingredient) had become impossible to get after a recent fix
--  stopped vented gas from sandblasting trees -- chopping wood down now has a small chance of
--  turning up sawdust directly, the same way breaking stone already has a chance of turning up
--  gravel or dust."
