-- fieldtools.lua - the endgame physics-manipulation tier (2026-09-0X, @fieldtools).
-- NEW FILE this wave -- no collision with any AGENTS.md active-wave lane. Owns: R.hooks.tick/
-- draw/place/mousedown/newworld/sandbox entries tagged "fieldtools", R.RECIPES entries tagged
-- _plugin="fieldtools", R.ITEMS entries this file adds, R.fieldtools (own state table, saved via
-- R.PLUGIN_SAVE_KEYS same as every other plugin). READS R.tech.reactor as a gate check only --
-- never writes R.tech, which belongs to @survival's machines.lua this wave. Does not touch
-- rpg.lua, machines.lua, machines2.lua, world.lua, ui.lua, guide.lua, automation.lua or
-- telemetry.lua. New R.RECIPES entries carry a real `st` (station) so guide.lua's existing
-- per-station crafting tab picks them up automatically -- the same zero-guide-edit pattern
-- @matimpl's own chain 1/4/5/6/9 recipes already used in rpg.lua (see design-material-
-- progression.md), reconfirmed by reading guide.lua's recipe listing before relying on it.
--
-- SCOPE NOTE, read before extending this file: the brief named ACEL, DCEL, GRVT/PGRV/NGRV, EQVE,
-- WARP, PRTI/PRTO, VIBR/BVBR, FRME/PSTN, STOR, CLNE/BCLN/PCLN as the target element set.
--   - PRTI/PRTO: OUT OF SCOPE HERE ON PURPOSE. @survival's machines2.lua already ships a real,
--     working Portal Pair (PORTALKIT, channel-matched PRTI/PRTO -- confirmed by reading
--     machines2.lua:729-756 before writing this file) plus a Gravity Manipulator (WHOL-based
--     repulsor, GRAVMANIPKIT) and a Magnetic Accelerator (PSCN/NSCN rail launcher, MAGACCELKIT).
--     Shipping a second "Portal" item under a different recipe would confuse players with two
--     unrelated things doing the same job in the same game. This file's own report flags that
--     the live PORTALKIT has no range/power/throughput limit (the brief's own ask for portals) as
--     a follow-up for @survival to consider in their file, not duplicated here.
--   - PGRV/NGRV named in the brief DO NOT EXIST in this fork's compiled element table -- verified
--     by grep of D:/The-Powder-Toy/src/simulation/elements/ (only GRVT.cpp and the unrelated
--     GRAV.cpp exist) and of POWDER_TOY_MATERIAL_INDEX.json (no PGRV/NGRV entries at all). GRVT's
--     own native `tmp` field (-100..100) already carries the attract/repel sign directly
--     (src/simulation/elements/GRVT.cpp: `sim->gravIn.mass[cell] = 0.2f * parts[i].tmp` every
--     tick it's alive) -- that IS this build's positive/negative gravity, exposed below via the
--     Gravity Anchor's attract/repel toggle, not two separate elements.
--   - EQVE ("a failed shared velocity test") is excluded on purpose, same call
--     design-material-progression.md already made: an acknowledged dev-test element with no
--     coherent physical identity and nothing to build an acquisition route or a use around.
--   - CLNE/BCLN/PCLN: built as ONE constrained "Replicator Core", not raw CLNE handed to the
--     player to plant anywhere. See the REPLICOREKIT section below for why unrestricted cloning
--     was rejected and what the constrained version actually enforces.
--   - Presses/crushers (FRME/PSTN theme #3 from the brief) are NOT shipped this pass -- a
--     mechanically honest crusher needs the pressure-transition behaviour GLAS/QRTZ already use
--     elsewhere (machines2's own PRESSVESSELKIT), and re-deriving that from a piston contact
--     within this budget risked shipping an unverified claim. The Piston Door/Lift below is the
--     one FRME/PSTN mechanism actually verified against source (PSTN.cpp's own extend/retract
--     scan and the FRME-drag branch of MoveStack) before being built.

local R = PBX.state.rpg
local TAG = "fieldtools"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

R.fieldtools = R.fieldtools or { machines = {}, gravityOn = false, replicatorBuilt = false }

-- ================================================================ low-level build helpers (same
-- erase-then-place convention as machines2.lua -- see build-lessons "placeElement on an occupied
-- pixel is a no-op")
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function setAt(wx, wy, elName)
  killAt(wx, wy); local t = R.eid(elName); if not t then return nil end
  return sim.partCreate(-1, wx - R.cam.x, wy - R.cam.y, t)
end
local function boxFill(x1, y1, x2, y2, elName) for y = y1, y2 do for x = x1, x2 do setAt(x, y, elName) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if R.solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
local function nearPlayer(x, y, r) local dx, dy = x - R.P.x, y - R.P.y; return dx * dx + dy * dy <= (r or 140) * (r or 140) end
local function partAt(wx, wy) return sim.partID(wx - R.cam.x, wy - R.cam.y) end
local function typeAt(wx, wy) local p = partAt(wx, wy); return p and R.nameOf(sim.partProperty(p, "type")) or nil end
-- powered = a real spark sitting on/adjacent to a pad this frame (same real physics @machines'
-- R.power.grids is itself built on -- see machines2.lua's own poweredAt, reused verbatim here)
local function poweredAt(wx, wy, r)
  r = r or 1
  for dy = -r, r do for dx = -r, r do
    if typeAt(wx + dx, wy + dy) == "SPRK" then return true end
  end end
  return false
end
local function nice(n) return (R.nice and R.nice(n)) or n end
-- fallback for a lab session that hasn't run the custom-element registration script (same
-- reasoning as machines2.lua's own WMAT/STEELMAT: a structural setAt() call for a name R.eid()
-- can't resolve silently no-ops, so every housing wall must resolve to a real stock element)
local STEELMAT = R.has("STEL") and "STEL" or (R.has("BMTL") and "BMTL" or "METL")

-- ================================================================ Gravity Anchor: a housed,
-- periodically-refreshed GRVT source. GRVT (Gravitons) is TYPE_ENERGY with PROP_LIFE_DEC -- it
-- decays in ~4-7s by design (GRVT.cpp `create()`: life = 250 + rng(0,199) frames), so a real
-- gravity SOURCE has to keep respawning it, not place it once. That respawn is the only per-frame
-- cost this file adds for this machine, and it is bounded to the anchor list (never a map sweep):
-- one sim.partCreate per anchor per ~90-frame cooldown, checked only when a real spark powers its
-- pad. Newtonian gravity itself (sim.newtonianGravity) is a GLOBAL toggle -- flips real N-body-
-- style gravity on for the whole world, not just near the anchor -- so it is only ever flipped
-- ONCE, guarded by R.fieldtools.gravityOn, on the first anchor a player deliberately places (a
-- real interface-event context: this runs inside R.hooks.place, which fires from the same
-- TickEvent dispatch bridge_base.lua's own onTick comment documents as carrying
-- eventTraitInterface), with a loud one-time R.say warning. It is never toggled from inside a
-- silent per-frame hook.
local function buildGravAnchor(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 5, wx + 2, gy, STEELMAT)
  clearBox(wx - 1, gy - 4, wx + 1, gy - 1)
  setAt(wx - 2, gy - 2, "PSCN")   -- power pad
  local core = { x = wx, y = gy - 2, kind = "gravanchor", pad = { x = wx - 2, y = gy - 2 }, mode = "attract", cool = 0 }
  table.insert(R.fieldtools.machines, core)
  if not R.fieldtools.gravityOn then
    local ok = pcall(sim.newtonianGravity, true)
    if ok then
      R.fieldtools.gravityOn = true
      R.say("WARNING: real Newtonian gravity is now active across the WHOLE map -- loose material everywhere drifts toward mass sources, not just downward. This does not turn off.")
      R.tlog("warn", "fieldtools", "newtonianGravity(true) enabled on first Gravity Anchor build", { x = wx, y = wy })
    else
      R.tlog("error", "fieldtools", "sim.newtonianGravity(true) call failed", { x = wx, y = wy })
    end
  end
  R.say("Gravity Anchor placed (attract mode) -- right-click it to switch attract/repel. Power the pad to activate")
end
local function updateGravAnchors()
  for _, m in ipairs(R.fieldtools.machines) do if m.kind == "gravanchor" then
    if poweredAt(m.pad.x, m.pad.y, 1) then
      m.cool = (m.cool or 0) - 1
      if m.cool <= 0 then
        local id = setAt(m.x, m.y, "GRVT")
        if id then pcall(sim.partProperty, id, "tmp", m.mode == "attract" and 80 or -80) end
        m.cool = 90
      end
    else
      m.cool = 0
    end
  end end
end

-- ================================================================ Accelerator / Decelerator
-- Rail: pure native physics once placed (ACEL/DCEL affect TYPE_PART|LIQUID|GAS|ENERGY neighbours
-- every tick via their own C++ Update -- verified in ACEL.cpp before relying on it), so this adds
-- ZERO ongoing Lua tick cost. Loose ore (a powder, TYPE_PART) sliding across the strip speeds up
-- or slows down; a real contactless conveyor upgrade over the existing PIPE/CONVEYOR logistics.
local function buildRail(mx, my, elName)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  local dir = (R.P.face and R.P.face >= 0) and 1 or -1
  for i = 0, 6 do setAt(wx + dir * i, gy, elName) end
  R.say((elName == "ACEL" and "Accelerator" or "Decelerator") .. " rail placed -- loose material crossing it "
    .. (elName == "ACEL" and "speeds up" or "slows down"))
end

-- ================================================================ Piston Door/Lift: real PSTN
-- extend/retract, verified against PSTN.cpp before building this geometry -- PSTN scans its 4
-- orthogonal neighbours (radius 1-2) for a fresh SPRK (life==3): ctype PSCN extends, anything else
-- retracts, and pushing an adjoining FRME drags along whatever else rests on that FRME (the same
-- native mechanism stock TPT piston-lift saves use). Built as a vertical shaft so the same
-- structure works as either a door (FRME blocks the doorway) or a lift (stand on the FRME, ride it
-- up) depending how the player uses it -- documented honestly as both, not two separate unverified
-- claims.
local function buildPistonDoor(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 9, wx - 2, gy, STEELMAT)
  boxFill(wx + 2, gy - 9, wx + 2, gy, STEELMAT)
  clearBox(wx - 1, gy - 9, wx + 1, gy)
  setAt(wx, gy - 9, "PSTN")
  setAt(wx, gy - 8, "FRME")
  setAt(wx - 1, gy - 9, "PSCN")   -- spark this to extend (push the FRME down -- closes the doorway)
  setAt(wx + 1, gy - 9, "NSCN")  -- spark this to retract (pull the FRME back up -- opens it)
  R.say("Piston door/lift placed -- spark the PSCN pad (left) to close, the NSCN pad (right) to open. Stand on the frame to ride it as a lift")
end

-- ================================================================ Quantum Capacitor: real STOR,
-- captures one non-solid particle within its own radius-2 scan (verified in STOR.cpp) and holds it
-- indefinitely until a fresh PSCN spark releases it. Genuinely useful for moving one hazardous or
-- precious particle (a VIBR unit, molten ore, a reagent) a short distance without it reacting in
-- transit. Zero ongoing Lua cost -- native element behaviour, nothing to tick.
local function buildQCap(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 1, gy - 3, wx + 1, gy - 1, STEELMAT)
  clearBox(wx, gy - 2, wx, gy - 2)
  setAt(wx, gy - 2, "STOR")
  setAt(wx - 1, gy - 3, "PSCN")   -- spark to release whatever it's holding
  R.say("Quantum Capacitor placed -- drop one loose particle on it to capture; spark the pad to release")
end

-- ================================================================ Warp Charge: a throwable
-- consumable, not a persistent machine. Spawns a small native WARP-gas cluster at the target; WARP
-- itself does the work (randomly trades position with non-WARP/STKM/DMND/CLNE neighbours every
-- tick it's alive, verified in WARP.cpp) and self-destructs via its own PROP_LIFE_KILL life timer
-- (~1.2-2.7s, WARP.cpp's own create()) -- so this file's cost is exactly one burst of ~13
-- sim.partCreate calls on throw, then nothing: no tick hook, no ongoing cost at all.
local function buildWarpCharge(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y
  for dx = -2, 2 do for dy = -2, 2 do if dx * dx + dy * dy <= 5 then setAt(wx + dx, wy + dy, "WARP") end end end
  R.say("Warp charge thrown -- nearby loose material is being scrambled, dig through it while it settles")
end

-- ================================================================ Replicator Core: the final
-- unlock, and the one item in this file that needed real thought before shipping at all.
--
-- Why not raw CLNE handed to the player: CLNE duplicates whatever FIRST touches it, forever, and
-- that lock is permanent once set (verified in CLNE.cpp: the rescan-neighbours branch only runs
-- while ctype is 0/invalid; the instant it's valid it falls into the else-branch and never rescans
-- again). A player who touches raw CLNE with DMND, ZIRC or any other scarce/gating material gets
-- an infinite source of it -- exactly the "erase the entire scarcity design" failure
-- design-material-progression.md already flagged for CONV/CLNE and refused to design around.
--
-- The constrained version this file ships instead:
--   1. ONE per world, hard-capped (R.fieldtools.replicatorBuilt) -- refuses a second build.
--   2. Its housed CLNE's ctype is set ONCE, by this code, to STEL -- and because of the CLNE.cpp
--      behaviour above, that lock is PERMANENT and un-hijackable: there is no code path in the
--      real engine that ever rescans a CLNE's neighbours once ctype is valid, so no periodic
--      Lua re-check is even needed to enforce the whitelist (a genuinely free correctness
--      guarantee, not a corner cut for time). STEL is already an unlimited-supply, non-gating
--      build material (furnace-craftable at scale) -- duplicating it saves time on megaprojects,
--      it does not unlock anything a patient player couldn't already have.
--   3. Consumable: it ships with 40 operating "charges", spent one per ~10s of confirmed powered
--      operation (a single O(1) counter check on a 1-item list every 600 frames -- bounded,
--      event-driven, not a sweep). At 0 charges the housed CLNE is killed (burned out); feeding it
--      one more crafted VIBR (right-click while it's burned out) rebuilds the CLNE and resets the
--      counter. This matches the brief's own fallback instruction almost exactly: "extremely
--      expensive, ideally limited or consumable."
local REPLICORE_TARGET = "STEL"
local REPLICORE_CHARGES = 40
local function buildReplicore(mx, my)
  if R.fieldtools.replicatorBuilt then
    R.say("Only one Replicator Core can exist in this world -- you already built it")
    return
  end
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 2, gy - 5, wx + 2, gy - 1, STEELMAT)
  clearBox(wx - 1, gy - 4, wx + 1, gy - 2)
  local id = setAt(wx, gy - 3, "CLNE")
  if id then pcall(sim.partProperty, id, "ctype", R.eid(REPLICORE_TARGET)) end
  setAt(wx, gy - 1, "PSCN")     -- power pad, bottom centre (also the output vent -- keep clear to harvest)
  R.fieldtools.replicatorBuilt = true
  table.insert(R.fieldtools.machines, { kind = "replicator", x = wx, y = gy - 3, pad = { x = wx, y = gy - 1 },
    charges = REPLICORE_CHARGES, burnedOut = false, tick = 0 })
  R.say("Replicator Core online, locked to " .. nice(REPLICORE_TARGET) .. " -- " .. REPLICORE_CHARGES
    .. " charges. Power the pad, keep the vent below it clear to harvest. Right-click with a Vibranium in hand to recharge once it burns out")
end
local function updateReplicators()
  for _, m in ipairs(R.fieldtools.machines) do if m.kind == "replicator" and not m.burnedOut then
    if poweredAt(m.pad.x, m.pad.y, 1) then
      m.tick = (m.tick or 0) + 1
      if m.tick >= 600 then
        m.tick = 0
        m.charges = (m.charges or 0) - 1
        if m.charges <= 0 then
          local core = partAt(m.x, m.y)
          if core and typeAt(m.x, m.y) == "CLNE" then sim.partKill(core) end
          m.burnedOut = true
          R.say("Replicator Core burned out -- bring a Vibranium and right-click it to recharge")
          R.tlog("info", "fieldtools", "replicator core burned out", { x = m.x, y = m.y })
        end
      end
    end
  end end
end

-- ================================================================ tick/mousedown: bounded to
-- this file's own machine list ONLY (never a map-wide sweep -- see DEVELOPMENT.md's live-lag
-- complaint). Anchor/replicator upkeep run every tick but each iterates at most a handful of
-- entries (one Gravity Anchor spawn attempt per ~90 frames, one Replicator charge check per 600);
-- rails/doors/capacitor/warp charge add no tick cost at all (documented per-section above).
hook(R.hooks.tick, function()
  updateGravAnchors()
  updateReplicators()
end)

hook(R.hooks.mousedown, function(mx, my, button)
  if button ~= 3 then return end
  local wx, wy = mx + R.cam.x, my + R.cam.y
  for _, m in ipairs(R.fieldtools.machines) do
    if m.kind == "gravanchor" and nearPlayer(m.x, m.y, 24) and nearPlayer(wx, wy, 24) then
      m.mode = (m.mode == "attract") and "repel" or "attract"
      R.say("Gravity Anchor set to " .. m.mode)
      return true
    end
    if m.kind == "replicator" and m.burnedOut and nearPlayer(m.x, m.y, 24) and nearPlayer(wx, wy, 24) then
      if (R.inv("VIBR") or 0) >= 1 then
        R.inventory.VIBR = R.inv("VIBR") - 1
        local id = setAt(m.x, m.y, "CLNE")
        if id then pcall(sim.partProperty, id, "ctype", R.eid(REPLICORE_TARGET)) end
        m.burnedOut = false; m.charges = REPLICORE_CHARGES; m.tick = 0
        R.say("Replicator Core recharged (" .. REPLICORE_CHARGES .. " charges)")
        R.rebuildHotbar()
      else
        R.say("Needs 1 Vibranium to recharge")
      end
      return true
    end
  end
end)

-- ================================================================ crafting: R.RECIPES + R.ITEMS + place hook
R.ITEMS = R.ITEMS or {}
R.ITEMS.GRAVCORE = R.ITEMS.GRAVCORE or { col = { 20, 230, 120 }, desc = "Unstable graviton charge. Feeds a Gravity Anchor." }
R.ITEMS.WARPCHG = R.ITEMS.WARPCHG or { col = { 16, 16, 16 }, desc = "A contained warp bubble. Throw it to scramble nearby loose material." }

local BUILDERS = {
  GRAVANCHORKIT = buildGravAnchor,
  ACCELRAILKIT = function(mx, my) buildRail(mx, my, "ACEL") end,
  DECELRAILKIT = function(mx, my) buildRail(mx, my, "DCEL") end,
  PSTNDOORKIT = buildPistonDoor,
  QCAPKIT = buildQCap,
  WARPCHG = buildWarpCharge,
  REPLICOREKIT = buildReplicore,
}
hook(R.hooks.place, function(el, mx, my, fine)
  local b = BUILDERS[el]; if not b then return end
  if (R.frame - (R.lastFieldPlace or -99)) < 20 then return true end
  R.lastFieldPlace = R.frame
  R.inventory[el] = R.inv(el) - 1
  local ok, err = pcall(b, mx, my); if not ok then R.pluginErr = tostring(err); R.tlog("error", "fieldtools", "build failed", { el = el, err = tostring(err) }) end
  R.rebuildHotbar()
  return true
end)

local function need(...) local t = {}; local a = { ... }; for i = 1, #a, 2 do t[a[i]] = a[i + 1] end; return t end

-- Advanced Lab tier -- no reactor requirement, every input already independently mineable/
-- craftable per rpg.lua's own R.MINEABLE (PTNM/ZIRC/TTAN/DMND all confirmed live, 2026-09-0X --
-- PTNM tier 4, mineable with a steel pick, not gated behind the diamond pick itself) or
-- craftable at a station reachable before this tier (ACEL/DCEL/PSTN/FRME all already craftable
-- at rpg.lua's own research-bench "chain 5", METL/STEL/CU/QRTZ baseline). No recipe here demands
-- more than 4 of any single rare input, avoiding the GRNT/NSCN/TUNG/THRM/NITR quantity-deadlock
-- shape (every input is renewably minable, not a one-time reward, so there is no fixed pool to
-- run short against).
local ADVLAB_RECIPES = {
  { out = "GRAVCORE", n = 2, need = need("PTNM", 2, "ZIRC", 2, "DMND", 1), st = "advlab", txt = "Graviton charge",
    desc = "Unstable graviton material. Feeds a Gravity Anchor -- exposes the engine's real Newtonian gravity" },
  { out = "GRAVANCHORKIT", n = 1, need = need("GRAVCORE", 4, "STEL", 6, "ZIRC", 2), st = "advlab", txt = "Gravity Anchor",
    desc = "Housed graviton source, attract/repel toggle -- ore lifting, hazard control, real gravity wells" },
  { out = "WARPCHG", n = 1, need = need("PTNM", 1, "TTAN", 2, "DMND", 1), st = "advlab", txt = "Warp charge",
    desc = "Thrown, it scrambles nearby loose material via real spatial displacement -- fast exposure of buried ore" },
  { out = "ACCELRAILKIT", n = 1, need = need("ACEL", 2, "METL", 4), st = "research", txt = "Accelerator rail",
    desc = "A real ACEL strip -- loose material crossing it speeds up, a contactless conveyor upgrade" },
  { out = "DECELRAILKIT", n = 1, need = need("DCEL", 2, "METL", 4), st = "research", txt = "Decelerator rail",
    desc = "A real DCEL strip -- loose material crossing it slows down, pairs with the Accelerator rail" },
  { out = "PSTNDOORKIT", n = 1, need = need("PSTN", 2, "FRME", 2, "STEL", 2), st = "research", txt = "Piston door/lift",
    desc = "Real PSCN-extend/NSCN-retract piston mechanism -- build it as a door slab or ride the frame as a lift" },
  { out = "QCAPKIT", n = 1, need = need("STEL", 3, "QRTZ", 2, "CU", 1), st = "research", txt = "Quantum capacitor",
    desc = "Real STOR -- captures one loose particle, releases it when sparked. Move a hazardous material safely" },
}

-- Reactor-online tier -- gated behind R.tech.reactor (read-only check, same pattern machines.lua's
-- own TIERR_RECIPES and machines2.lua's file-header comment both already use: "READS R.tech to
-- gate its own recipe tiers", never writes it). VIBR closes its own acquisition gap (it had zero
-- source anywhere in this fork before this pass -- confirmed by grep) with a craft route built
-- from inputs already independently reachable well before reactor-online, so the recipe becomes
-- available the moment the gate opens rather than deadlocking on its own missing precursor.
local REACTOR_RECIPES = {
  { out = "VIBR", n = 1, need = need("ISZS", 3, "PTNM", 2, "ZIRC", 2), st = "advlab", txt = "Vibranium",
    desc = "Stores energy and releases it violently. Reactor-grade catalysts make this stable enough to handle" },
  -- DMND reduced 4 -> 3 on 2026-09-02 (@lead). scripts/check_acquirable.py flagged this as
  -- quantity-insufficient: DMND's deterministic supply is exactly 3 (two quest rewards), so a
  -- cost of 4 made the game's FINAL UNLOCK reachable only via a probabilistic chest drop.
  -- That is the identical shape as the historic diamond-pick bug (also 4-needed vs 3-supplied,
  -- fixed earlier tonight) and the GRNT deadlock (16 available vs 20 required) -- a recipe whose
  -- inputs exist but never in sufficient quantity. Boolean reachability misses this class
  -- entirely, which is why the quantity pass exists. ZIRC raised 4 -> 5 to keep the total cost
  -- roughly intact, since ZIRC is renewably mineable and DMND is not.
  { out = "REPLICOREKIT", n = 1, need = need("VIBR", 2, "DMND", 3, "PTNM", 3, "ZIRC", 5), st = "advlab", txt = "Replicator Core",
    desc = "THE FINAL UNLOCK. One per world. A real, leashed CLNE locked to duplicating Steel only -- never ore, never anything that gates progression. Consumable: burns out after sustained use, recharge with Vibranium" },
}

local function installRecipes()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(ADVLAB_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
  if R.tech and R.tech.reactor then
    for _, rc in ipairs(REACTOR_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
  end
end
installRecipes()
-- reactor-online can flip true after this file already installed once (same tick-driven gate as
-- machines.lua's own checkMilestones) -- poll cheaply, bounded to a single boolean compare/frame,
-- until the gate opens, then stop (never re-runs installRecipes after the reactor tier lands).
hook(R.hooks.tick, function()
  if not R.fieldtools.reactorRecipesInstalled and R.tech and R.tech.reactor then
    R.fieldtools.reactorRecipesInstalled = true
    installRecipes()
  end
end)

hook(R.hooks.newworld, function()
  R.fieldtools = { machines = {}, gravityOn = false, replicatorBuilt = false, reactorRecipesInstalled = false }
  installRecipes()
end)
hook(R.hooks.sandbox, function() installRecipes() end)

-- ================================================================ save/load: generic plain-data
-- dump via save.lua, same registration convention every other plugin uses
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
do
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == "fieldtools" then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, "fieldtools") end
end

R.tlog("info", "fieldtools", "plugin loaded", { advlabRecipes = #ADVLAB_RECIPES, reactorRecipes = #REACTOR_RECIPES })
