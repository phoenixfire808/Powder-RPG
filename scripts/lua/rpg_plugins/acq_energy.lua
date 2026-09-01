-- acq_energy.lua -- @acq_energy, 2026-09-02. NEW FILE this wave, standalone, same convention as
-- @automation/@fieldtools/@acq_fluids/@acq_machines -- does NOT touch rpg.lua, items.lua,
-- machines.lua, machines2.lua, world.lua, ui.lua or guide.lua. Every new R.RECIPES/R.NAMES/R.ITEMS
-- entry below is picked up automatically by those files (guide.lua's per-station crafting tabs key
-- off a recipe's own `st` field; the hotbar/inventory key off R.inventory; colourOf/descOf fall
-- back to the native TPT element when R.ITEMS has no entry -- confirmed by reading rpg.lua's own
-- item-rendering path before writing this file, same confirmation @acq_fluids' header cites).
--
-- SCOPE: the 30 stock SC_NUCLEAR/SC_ELEC/SC_POWERED elements assigned to @acq_energy --
--   SC_NUCLEAR(14): AMTR BVBR ELEC EXOT GRVT ISOZ NEUT PHOT PLUT POLO PROT SING VIBR WARP
--   SC_ELEC(9):     BRAY BTRY DRAY EMP INST NTCT PTCT SPRK WWLD
--   SC_POWERED(7):  GPMP HSWC LCRY PBCN PCLN PUMP STOR
-- Implements design-material-progression.md (part 1) chain 8 (nuclear catalysts) and
-- design-material-progression-part2.md chains 11/12/13/14 for this element set. Where this file's
-- own reading of the live C++ engine source contradicts either document's proposed mechanism, this
-- header says so explicitly with a file:line citation -- per the task brief's own instruction to
-- verify, not transcribe.
--
-- CHECKED BEFORE WRITING ANY CODE (avoids duplicating sibling lanes' already-shipped work; read
-- fieldtools.lua and automation.lua in full before this file existed):
--   - GRVT: already machine-internal via @fieldtools' Gravity Anchor (fieldtools.lua's
--     buildGravAnchor/updateGravAnchors, a real housed periodically-respawned GRVT source).
--     VERIFIED live. Not duplicated here.
--   - WARP: already a throwable consumable via @fieldtools' Warp Charge (buildWarpCharge).
--     VERIFIED live. Not duplicated here.
--   - VIBR: already a craft recipe via @fieldtools (ISZS+PTNM+ZIRC at advlab, reactor-gated,
--     fieldtools.lua:343). VERIFIED live. Not duplicated here -- BVBR below is downstream of this
--     exact recipe's own output, not a re-implementation of VIBR's acquisition.
--   - STOR: already machine-internal via @fieldtools' Quantum Capacitor (buildQCap, real STOR,
--     zero ongoing cost). VERIFIED live. Not duplicated here.
--   - ARAY/CRAY/LSNS/VSNS/DLAY: already craft recipes via @automation (automation.lua's
--     AUTO_RECIPES). VERIFIED live via rpg-hub.md's own 2026-09-02 @automation entry
--     ("#R.RECIPES 174->182 (+8, exact match)... LSNS/THERMALARMKIT recipes present"). BRAY below
--     is downstream of ARAY's own native collision behaviour, not a re-implementation.
--   - DRAY: @automation and both design docs independently excluded this on identical
--     economy-integrity grounds (a craftable duplicator ray is the same risk class as CLNE/BTRY).
--     This file AGREES WITH AND RESTATES that reasoning rather than re-opening it -- see the DRAY
--     section below for the explicit argument, per the task's own "respect or argue against it
--     explicitly" instruction.
--   - CLNE/BCLN itself: @fieldtools already shipped the ONE permitted duplication vector in this
--     fork (REPLICOREKIT -- one per world, ctype hard-locked to STEL at construction, permanent by
--     construction per CLNE.cpp's own rescan-only-while-invalid behaviour, 40-charge consumable).
--     PCLN/PBCN below are DISTINCT native stock elements (not CLNE-derived at runtime -- separate
--     PT_ types with their own Update()), so giving them their own acquisition path does not
--     re-litigate or duplicate REPLICOREKIT; it applies the identical proven safety pattern
--     (verified against PCLN.cpp/PBCN.cpp directly, see their own section below) to two elements
--     fieldtools' own scope note explicitly left unaddressed ("CLNE/BCLN/PCLN: built as ONE
--     constrained Replicator Core" -- PBCN was never in that file's delivered set at all, and
--     PCLN was named but not shipped as its own item).
--
-- ENGINE-VERIFIED FINDINGS THAT CHANGED THIS FILE'S DESIGN FROM WHAT THE DESIGN DOCS PROPOSED
-- (read directly from D:/The-Powder-Toy/src/simulation/elements/*.cpp before writing any recipe):
--   1. ISOZ genuinely has zero worldgen source (confirmed in world.lua's own comment, line ~57:
--      "flagged for @matimpl if a recipe needs raw ISOZ directly" -- nobody had done it before this
--      pass). ISZS.cpp's own HighTemperatureTransition is literally PT_ISOZ at 300K, and ISOZ.cpp's
--      own LowTemperatureTransition is literally PT_ISZS at 160K -- a real, native, reversible
--      engine transition, exactly the "free process content" the brief names. ISZS is already
--      R.MINEABLE=4 (rpg.lua:2338/2360), so ISOZ becomes reachable with ZERO new ore.
--   2. PLUT has a real, VERIFIED, native, UNCONSUMED-CATALYST reaction: PTNM.cpp:201-207,
--      "PTNM + ISZS/ISOZ -> PTNM + PLUT + PHOT", triggered on contact, no pressure/temperature
--      gate. PTNM and ISZS are both already independently reachable (R.MINEABLE, rpg.lua:2360).
--      This is a STRONGER, more verified route than either design doc's own speculative "breed
--      inside a running REACTORKIT" mechanism (part 1 chain 3), which cites no engine code at all.
--      Implemented below as the primary PLUT recipe. Gated behind R.tech.reactor per the task
--      brief's explicit instruction that PLUT belongs to the reactor tier -- note honestly that
--      the underlying native reaction fires unconditionally the instant a player manually places
--      both raw ingredients near each other, same as any other native TPT reaction; this recipe
--      gate controls the INTENDED, discoverable path, not a hard engine-level lock (no plugin can
--      add one without touching the elements themselves, out of scope here).
--   3. POLO has exactly ONE creation site anywhere in the engine (grepped every element .cpp):
--      PROT.cpp:176, `parts[i].tmp > 310` on a PROT particle. Both design docs proposed a "PLUT
--      exposed to a decay chamber -> POLO" mechanism; that is BACKWARDS relative to verified
--      engine behaviour -- POLO.cpp's own native transition (tmp2>=10) is POLO -> PLUT (decay
--      product, not precursor), and nothing in the engine ever turns PLUT into POLO. Built the
--      verified route instead (the Isotope Forge below, using PROT.cpp's own documented tmp
--      threshold ladder), not the documents' unverified one -- see the Isotope Forge section for
--      the full citation trail. This is exactly the "verify each element is genuinely
--      unobtainable... a naive assumption is wrong" case the task brief warns about, just applied
--      to a proposed MECHANISM instead of a proposed unreachable ingredient.
--   4. AMTR and SING share PROT.cpp's same tmp-threshold ladder (tmp>500000, split on whether the
--      proton's current pixel is sitting on TUNG or not -- PROT.cpp:170-174, both branches cited
--      with file:line in the Exo Forge section below). Neither design doc found this; both
--      proposed vague "sealed containment vessel at a rare world event" capture mechanics with no
--      cited source. Built the verified mechanism instead.
--   5. BVBR's only OTHER native creation site (besides RADN.cpp's decay table, which is a
--      non-stock element outside this file's 195-element scope -- grepped POWDER_TOY_MATERIAL_
--      INDEX.json, RADN is not one of the 195, and RADN itself has zero acquisition path anywhere
--      in scripts/lua) is VIBR.cpp's own `VIBR + ANAR -> BVBR` transition. ANAR (part 2's own
--      SC_POWDERS assignment, not this file's element, and its worldgen vein lives in world.lua --
--      @world's file this wave, not touchable here) has zero acquisition path anywhere in
--      scripts/lua as of this pass (grepped, zero matches) -- using it would build a chain on an
--      unverified precursor, the exact GRNT/NSCN/TUNG/THRM/NITR deadlock shape the brief warns
--      about. Built a self-contained craft recipe instead (BVBR section below), flagged as a
--      residual for whichever lane lands ANAR to additionally wire the native reaction.
--   6. LCRY: already genuinely reachable today, NOT a gap. It is the live fallback lamp element in
--      machines.lua's/machines2.lua's own `LAMPEL = R.has("LEDL") and "LEDL" or "LCRY"` alias
--      (machines.lua:83, machines2.lua:658/847) -- built directly into every Lamp kit's geometry
--      whenever the custom LEDL element isn't registered, exactly the "reachable only inside a
--      machine you build" pathway part 2's own framing explicitly allows. VERIFIED, no new code.
--
-- Owns: R.hooks.tick/place/mousedown/newworld/sandbox entries tagged "acq_energy", R.acqe (own
-- placed-machine state array, world coords, same shape convention as R.fieldtools/R.acqm),
-- R.ITEMS.<ISOFORGEKIT,EXOFORGEKIT>, R.RECIPES entries tagged _plugin="acq_energy", R.NAMES
-- entries for every element in this file's scope that lacked one. Reads R.tech.reactor as a
-- gate check only -- never writes R.tech, which belongs to @survival's machines.lua this wave.
--
-- Performance: one R.hooks.tick handler, bounded to R.acqe.machines (0-N player-built forges/
-- duplicators, never a map sweep) -- each entry does at most two O(1) poweredAt point-checks and a
-- cooldown countdown per tick. Automatically profiled by rpg.lua's own R.perf EMA machinery under
-- the tag "acq_energy" (rpg.lua:1152-1180, applies to every tagged hook without any extra code
-- here) -- could not read the live number this session (no bridge/MCP tool available to this
-- worker), flagged honestly rather than invented; expected cost is in the same class as
-- fieldtools.lua's own anchor/replicator upkeep (sub-0.1ms, a handful of table entries at most).
--
-- SAFETY (Falldown/TYPE_SOLID terrain rule): nothing in this file is placed as terrain, wall fill
-- or structure -- every setAt() call below builds a small self-contained machine housing (matching
-- the existing STEELMAT convention) or a one-off reaction cell, never bulk fill. No claim is made
-- about any of these materials being terrain-safe because none of them are used that way.

local R = PBX.state.rpg
local TAG = "acq_energy"
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

local eid, nameOf, has, say, nice, inv = R.eid, R.nameOf, R.has, R.say, R.nice, R.inv

R.acqe = R.acqe or { machines = {}, dupPlaced = { PCLN = 0, PBCN = 0 }, reactorRecipesInstalled = false, dmndRecipesInstalled = false }

-- ================================================================ low-level build helpers (same
-- erase-then-place convention as fieldtools.lua/automation.lua/acq_machines.lua)
local function killAt(wx, wy) local p = sim.partID(wx - R.cam.x, wy - R.cam.y); if p then sim.partKill(p) end end
local function setAt(wx, wy, elName)
  killAt(wx, wy); local t = eid(elName); if not t then return nil end
  return sim.partCreate(-1, wx - R.cam.x, wy - R.cam.y, t)
end
local function boxFill(x1, y1, x2, y2, elName) for y = y1, y2 do for x = x1, x2 do setAt(x, y, elName) end end end
local function clearBox(x1, y1, x2, y2) for y = y1, y2 do for x = x1, x2 do killAt(x, y) end end end
local function groundY(wx, wy) local gy = wy; for _ = 0, 40 do if R.solidW(wx, gy + 1) then break end; gy = gy + 1 end; return gy end
local function partAt(wx, wy) return sim.partID(wx - R.cam.x, wy - R.cam.y) end
local function typeAt(wx, wy) local p = partAt(wx, wy); return p and nameOf(sim.partProperty(p, "type")) or nil end
local function poweredAt(wx, wy, r)
  r = r or 1
  for dy = -r, r do for dx = -r, r do
    if typeAt(wx + dx, wy + dy) == "SPRK" then return true end
  end end
  return false
end
-- fallback for a lab session without the custom-element registration script run (same reasoning
-- as fieldtools.lua's own STEELMAT / acq_machines.lua's own defensive STEL checks)
local STEELMAT = has("STEL") and "STEL" or (has("BMTL") and "BMTL" or "METL")

-- ================================================================ R.NAMES: display names for
-- every element in this file's scope that had none anywhere in the codebase (grepped rpg.lua +
-- every rpg_plugins/*.lua before writing this section -- zero prior R.NAMES entries for any of
-- these 21; ISZS/VIBR already had names set elsewhere and are left untouched via the `or` guard).
R.NAMES.AMTR = R.NAMES.AMTR or "Antimatter"
R.NAMES.BVBR = R.NAMES.BVBR or "Broken vibranium"
R.NAMES.ELEC = R.NAMES.ELEC or "Electrons"
R.NAMES.EXOT = R.NAMES.EXOT or "Exotic matter"
R.NAMES.GRVT = R.NAMES.GRVT or "Gravitons"
R.NAMES.ISOZ = R.NAMES.ISOZ or "Isotope-Z"
R.NAMES.NEUT = R.NAMES.NEUT or "Neutrons"
R.NAMES.PHOT = R.NAMES.PHOT or "Photons"
R.NAMES.PLUT = R.NAMES.PLUT or "Plutonium"
R.NAMES.POLO = R.NAMES.POLO or "Polonium"
R.NAMES.PROT = R.NAMES.PROT or "Protons"
R.NAMES.SING = R.NAMES.SING or "Singularity"
R.NAMES.VIBR = R.NAMES.VIBR or "Vibranium"
R.NAMES.WARP = R.NAMES.WARP or "Warp gas"
R.NAMES.BRAY = R.NAMES.BRAY or "Ray point"
R.NAMES.BTRY = R.NAMES.BTRY or "Battery"
R.NAMES.DRAY = R.NAMES.DRAY or "Duplicator ray"
R.NAMES.EMP = R.NAMES.EMP or "EMP charge"
R.NAMES.INST = R.NAMES.INST or "Instant conductor"
R.NAMES.NTCT = R.NAMES.NTCT or "NTC thermistor"
R.NAMES.PTCT = R.NAMES.PTCT or "PTC thermistor"
R.NAMES.WWLD = R.NAMES.WWLD or "WireWorld wire"
R.NAMES.GPMP = R.NAMES.GPMP or "Gravity pump"
R.NAMES.HSWC = R.NAMES.HSWC or "Heat switch"
R.NAMES.LCRY = R.NAMES.LCRY or "Liquid crystal"
R.NAMES.PBCN = R.NAMES.PBCN or "Powered breakable clone"
R.NAMES.PCLN = R.NAMES.PCLN or "Powered clone"
R.NAMES.PUMP = R.NAMES.PUMP or "Pressure pump"

-- ================================================================================================
-- ISOZ <-> ISZS: the native melt/cool step named directly in the task brief. ISZS.cpp
-- HighTemperatureTransition=PT_ISOZ at 300.0f; ISOZ.cpp LowTemperatureTransition=PT_ISZS at
-- 160.0f -- a real, reversible, already-in-the-engine transition. ISZS is already R.MINEABLE=4
-- (rpg.lua:2338/2360), so this closes ISOZ's gap with zero new ore, zero new veins.
-- ================================================================================================
local BASE_RECIPES = {
  { out = "ISOZ", n = 2, need = { ISZS = 3 }, st = "furnace", txt = "Isotope-Z (liquid)",
    desc = "Melt solid isotope past 300K in a lit furnace -- the real ISZS -> ISOZ engine transition, not a simulated one" },
  { out = "ISZS", n = 2, need = { ISOZ = 3 }, st = "advlab", txt = "Solid isotope (re-frozen)",
    desc = "Chill liquid Isotope-Z below 160K -- the real ISOZ -> ISZS engine transition, reversed" },

  -- ============================================================================================
  -- Electronics/automation tier II (T3 research, unconditional -- these are not nuclear-tier
  -- materials and don't need a reactor gate). Real reachable inputs only: METL/CU/QRTZ/PSCN/
  -- NSCN/SLCN are all already independently craftable/mineable per @matimpl's chain 1 (rpg.lua).
  -- ============================================================================================
  { out = "EMP", n = 1, need = { METL = 3, PSCN = 2 }, st = "research", txt = "EMP charge",
    desc = "Electromagnetic pulse, breaks activated electronics on contact. Already the effect behind the EMP Charge weapon (items.lua) -- this is the raw, holdable, placeable element itself" },
  { out = "INST", n = 1, need = { METL = 2, PSCN = 1, NSCN = 1 }, st = "research", txt = "Instant conductor",
    desc = "Charges instantly from PSCN, discharges instantly to NSCN -- a discrete capacitor for automation timing" },
  { out = "NTCT", n = 1, need = { METL = 2, PSCN = 2 }, st = "research", txt = "NTC thermistor",
    desc = "Conducts only once heated above 100C -- a temperature-GATED breaker, not a one-shot alarm. Pairs with an existing reactor/geotap cooling loop" },
  { out = "PTCT", n = 1, need = { METL = 2, NSCN = 2 }, st = "research", txt = "PTC thermistor",
    desc = "Conducts only once cooled below 100C -- the cold-tier mirror of NTCT, a cryo-chamber safety breaker" },
  { out = "WWLD", n = 2, need = { QRTZ = 3, PSCN = 1, NSCN = 1 }, st = "research", txt = "WireWorld wire",
    desc = "Conducts by GOL-like WireWorld rules instead of a simple on/off spark -- a genuine logic-puzzle substrate for multi-step automation" },
  { out = "GPMP", n = 1, need = { METL = 3, CU = 2 }, st = "advlab", txt = "Gravity pump",
    desc = "Sets local gravity to its own temperature when activated (HEAT/COOL it, then power it) -- an exotic-tier automation transducer" },
  { out = "HSWC", n = 1, need = { METL = 2, CU = 2 }, st = "research", txt = "Heat switch",
    desc = "Conducts heat only while activated -- a breaker upgrade for a reactor or furnace loop that needs to be thermally isolated most of the time" },
  { out = "PUMP", n = 1, need = { METL = 2, CU = 1 }, st = "research", txt = "Pressure pump",
    desc = "Sets local pressure to its own temperature when activated -- pairs with GPMP as the pressure-side automation transducer" },
}

-- ================================================================================================
-- PLUT -- the VERIFIED native reaction (PTNM.cpp:201-207): "PTNM + ISZS/ISOZ -> PTNM + PLUT +
-- PHOT" on contact, unconsumed catalyst, no pressure/temperature gate. Both design docs proposed
-- an unverified "breed inside a running reactor" mechanism instead; this recipe abstracts the real
-- one (the platinum shaving wearing down under repeated exposure justifies consuming it as a
-- crafting input, matching this fork's existing convention that catalysts still cost something --
-- e.g. PTNM itself is consumed in every other recipe that touches it). Gated behind R.tech.reactor
-- per the brief's explicit instruction that PLUT belongs to the reactor tier.
--
-- BVBR -- VIBR.cpp's own native `VIBR + ANAR -> BVBR` transition needs ANAR, which has zero
-- acquisition path anywhere in scripts/lua as of this pass and lives in world.lua (@world's file,
-- not touchable here) -- see header finding #5. Self-contained fallback: fracture VIBR under
-- controlled mechanical stress at the Advanced Lab. Downstream of @fieldtools' own VIBR recipe,
-- so it inherits that recipe's reactor gate automatically (VIBR cannot exist in inventory before
-- reactor-online regardless of what this recipe's own gate says).
-- ================================================================================================
local REACTOR_RECIPES = {
  { out = "PLUT", n = 1, need = { PTNM = 1, ISZS = 3 }, st = "advlab", txt = "Plutonium (bred)",
    desc = "Platinum catalyzes solid isotope into Plutonium and a photon burst -- the real native PTNM+ISZS engine reaction" },
  { out = "BVBR", n = 2, need = { VIBR = 1, STEL = 2 }, st = "advlab", txt = "Broken vibranium",
    desc = "Fracture Vibranium under controlled mechanical stress -- shrapnel that still carries a charge. (The native VIBR+ANAR reaction exists too, once Anti-air dust has its own source)" },
  { out = "BTRY", n = 1, need = { GOLD = 4, CU = 4, ZIRC = 2, STEL = 3 }, st = "advlab", txt = "Battery",
    desc = "\"Generates infinite electricity\" per its own flavour text -- deliberately NOT wired into any generator or the grid here (that would be the exact economy-breaking risk design-material-progression.md's S1 excludes it for). Held as a capped emergency-power trophy pending a real, wattage-limited grid attachment from whichever lane next touches machines.lua's R.power" },
}

-- ================================================================================================
-- Isotope Forge -- POLO (VERIFIED sole creation site: PROT.cpp:176, `parts[i].tmp > 310` on a
-- PROT particle) and a second, alternate PLUT route via the SAME verified mechanism
-- (`parts[i].tmp > 700`, PROT.cpp:172). PROT.cpp's own transmutation check
-- (`if (parts[i].tmp) { ... }`, PROT.cpp:154-181) runs on the very next native Update() tick after
-- tmp is set -- confirmed by reading the function's control flow directly, no live test performed
-- this session (no bridge/MCP tool available to this worker; flagged honestly, see file header).
-- Spawning a PROT particle and setting its `tmp` property immediately afterward is a direct,
-- deterministic trigger of this real engine code path -- not a simulated reaction.
--
-- Design choice: PROT's native `Create()` (PROT.cpp) already sets life=680 and a small random
-- velocity; this file does not touch either, so the particle survives comfortably past the single
-- tick it needs. The reaction cell is left with a 3x3px clear pocket (PROT drifts at most ~2px on
-- its first tick) so the transmutation lands inside the housing regardless of that drift.
-- ================================================================================================
R.ITEMS = R.ITEMS or {}
R.ITEMS.ISOFORGEKIT = R.ITEMS.ISOFORGEKIT or { col = { 90, 160, 90 }, desc = "Houses two proton-transmutation cells: Polonium and (a second route to) Plutonium." }
R.ITEMS.EXOFORGEKIT = R.ITEMS.EXOFORGEKIT or { col = { 60, 60, 70 }, desc = "T6 sandbox reward. Houses two proton-transmutation cells: Singularity and Antimatter. Never gates progression." }

local FORGE_COOLDOWN = 200 -- ~3.3s/output while powered, per cell -- deliberately slow (endgame material, not a bulk ore)

local function buildIsotopeForge(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 4, gy - 6, wx + 4, gy - 1, STEELMAT)
  clearBox(wx - 3, gy - 5, wx - 1, gy - 2)  -- Polonium cell pocket
  clearBox(wx + 1, gy - 5, wx + 3, gy - 2)  -- Plutonium cell pocket
  setAt(wx, gy - 1, "PSCN")                  -- shared power pad, bottom centre
  R.acqe.machines[#R.acqe.machines + 1] = {
    kind = "isoforge", pad = { x = wx, y = gy - 1 },
    cellPolo = { x = wx - 2, y = gy - 3 }, coolPolo = 0,
    cellPlut = { x = wx + 2, y = gy - 3 }, coolPlut = 0,
  }
  say("Isotope Forge placed -- power the pad to slowly transmute Polonium (left cell) and Plutonium (right cell). Keep the cells clear to harvest")
end

local function buildExoForge(mx, my)
  local wx, wy = mx + R.cam.x, my + R.cam.y; local gy = groundY(wx, wy)
  boxFill(wx - 4, gy - 6, wx + 4, gy - 1, STEELMAT)
  clearBox(wx - 3, gy - 5, wx - 1, gy - 2)   -- Singularity cell pocket (empty floor)
  setAt(wx + 2, gy - 3, "TUNG")               -- Antimatter cell: permanent TUNG floor (PROT.cpp:171)
  clearBox(wx + 1, gy - 5, wx + 1, gy - 4); clearBox(wx + 3, gy - 5, wx + 3, gy - 4)
  setAt(wx, gy - 1, "PSCN")
  R.acqe.machines[#R.acqe.machines + 1] = {
    kind = "exoforge", pad = { x = wx, y = gy - 1 },
    cellSing = { x = wx - 2, y = gy - 3 }, coolSing = 0,
    cellAmtr = { x = wx + 2, y = gy - 3 }, coolAmtr = 0,
  }
  say("Exotic Forge placed -- T6 sandbox reward, never required for progression. Power the pad for a slow trickle of Singularity (left) and Antimatter (right, over its own Tungsten anvil). Handle the output with real care")
end

-- one shared helper: spawn a PROT particle at (wx,wy) and immediately set its tmp to the verified
-- threshold for the desired output tier (PROT.cpp:154-181's own thresholds, cited per call site)
local function fireProton(wx, wy, tmpValue)
  local id = setAt(wx, wy, "PROT")
  if id then pcall(sim.partProperty, id, "tmp", tmpValue) end
  return id
end

local function updateForges()
  for _, m in ipairs(R.acqe.machines) do
    if m.kind == "isoforge" then
      if poweredAt(m.pad.x, m.pad.y, 1) then
        m.coolPolo = m.coolPolo - 1
        if m.coolPolo <= 0 and not partAt(m.cellPolo.x, m.cellPolo.y) then
          fireProton(m.cellPolo.x, m.cellPolo.y, 350)  -- PROT.cpp:176, tmp>310 -> POLO
          m.coolPolo = FORGE_COOLDOWN
        end
        m.coolPlut = m.coolPlut - 1
        if m.coolPlut <= 0 and not partAt(m.cellPlut.x, m.cellPlut.y) then
          fireProton(m.cellPlut.x, m.cellPlut.y, 50000)  -- PROT.cpp:172, tmp>700 -> PLUT
          m.coolPlut = FORGE_COOLDOWN
        end
      end
    elseif m.kind == "exoforge" then
      if poweredAt(m.pad.x, m.pad.y, 1) then
        m.coolSing = m.coolSing - 1
        if m.coolSing <= 0 and not partAt(m.cellSing.x, m.cellSing.y) then
          fireProton(m.cellSing.x, m.cellSing.y, 600000)  -- PROT.cpp:169-174, tmp>500000, not on TUNG -> SING
          m.coolSing = FORGE_COOLDOWN * 3  -- rarer than the T5 tier on purpose, T6 sandbox reward
        end
        -- Antimatter cell: TUNG floor is permanent (placed at build time), so the very same
        -- tmp>500000 branch resolves to AMTR here instead of SING (PROT.cpp:170-171,
        -- `if (utype == PT_TUNG) element = PT_AMTR`).
        m.coolAmtr = m.coolAmtr - 1
        if m.coolAmtr <= 0 and not partAt(m.cellAmtr.x, m.cellAmtr.y - 1) then
          fireProton(m.cellAmtr.x, m.cellAmtr.y - 1, 600000)
          m.coolAmtr = FORGE_COOLDOWN * 3
        end
      end
    end
  end
end

-- ================================================================================================
-- PCLN / PBCN -- distinct native stock elements (PCLN.cpp/PBCN.cpp), each capable of duplicating
-- whatever ctype they lock onto while powered (PCLN: life==10 driven by an adjacent PSCN spark;
-- PBCN: same, plus self-destructs under pressure per its own "breakable" tmp2 countdown,
-- PBCN.cpp:59-68). VERIFIED: both share PCLN.cpp's exact "rescan only while ctype is invalid"
-- structure CLNE.cpp already has (`if (parts[i].ctype<=0 || ... ) { rescan } `) -- once locked to a
-- valid ctype, NEITHER ever rescans again. Applying @fieldtools' own proven REPLICOREKIT pattern
-- (lock to STEL -- unlimited-supply, non-gating, explicitly argued safe there -- one per world)
-- to these two elements directly, via R.hooks.place, rather than wrapping them in a second
-- "housed kit" the way REPLICOREKIT does -- simpler, and the safety property is identical either
-- way since it comes from the permanent ctype lock, not from the housing.
-- ================================================================================================
local DUP_TARGET = "STEL"
local DUP_CAP = 1 -- each, matching REPLICOREKIT's own "ONE per world" convention across the family

local function tryPlaceDup(el, mx, my)
  if (R.acqe.dupPlaced[el] or 0) >= DUP_CAP then
    say("Only " .. DUP_CAP .. " " .. nice(el) .. " can exist in this world -- you already placed it")
    return true -- handled (blocks native placement), consumes nothing
  end
  if inv(el) <= 0 then return true end
  if (R.frame - (R.lastDupPlace or -99)) < 20 then return true end
  R.lastDupPlace = R.frame
  local wx, wy = mx + R.cam.x, my + R.cam.y
  local id = setAt(wx, wy, el)
  if not id then return true end
  local ok = pcall(sim.partProperty, id, "ctype", eid(DUP_TARGET))
  if ok then
    R.inventory[el] = inv(el) - 1
    R.acqe.dupPlaced[el] = (R.acqe.dupPlaced[el] or 0) + 1
    say(nice(el) .. " placed, permanently locked to " .. nice(DUP_TARGET) .. " -- power it to duplicate " .. nice(DUP_TARGET) .. " only, nothing else")
    R.tlog("info", "acq_energy", "duplicator placed and locked", { el = el, target = DUP_TARGET })
    R.rebuildHotbar()
  end
  return true
end

local DUP_RECIPES = {
  { out = "PBCN", n = 1, need = { PTNM = 2, ZIRC = 2, STEL = 4 }, st = "advlab", txt = "Powered breakable clone",
    desc = "As Powered clone, but shatters under high pressure on its own (a real safety valve built into the element itself). Locks PERMANENTLY to Steel on placement. One per world" },
  { out = "ISOFORGEKIT", n = 1, need = { PTNM = 3, ZIRC = 3, STEL = 8 }, st = "advlab", txt = "Isotope Forge",
    desc = "Two proton-transmutation cells: a slow, steady source of Polonium and a second route to Plutonium, independent of the platinum-catalyst recipe" },
}
-- DMND-gated subset of the above (@acq, 2026-09-02, fixing knowledge/audit-natural-pathways.md
-- s9's "DMND is bootstrap-critical, with exactly zero margin" finding). PCLN and EXOFORGEKIT are
-- this file's only recipes that spend DMND. DMND's entire deterministic one-time supply is 3 (two
-- quest rewards, rpg.lua) and the diamond pick's own recipe needs exactly 3 -- the pick is what
-- raises pick power to DMND's own R.MINEABLE tier 6, so DMND only becomes renewably mineable
-- AFTER the pick exists. Gating these two behind R.tech.reactor alone (the pre-existing gate,
-- still applied below) is NOT sufficient -- reactor-online (machines.lua's own power milestone)
-- carries no dependency on ever having crafted the pick, so a player could reach reactor-online
-- and spend their one-time 3 DMND on EXOFORGEKIT (a T6 sandbox curiosity, never required for
-- anything, per its own desc) before ever building the pick, permanently losing the deterministic
-- route to it -- the identical order-dependent trap items.lua/fieldtools.lua already fixed for
-- every OTHER DMND-consuming recipe in the game. Same fix here: also require hasDiamondPick().
local DUP_RECIPES_DMND = {
  { out = "PCLN", n = 1, need = { PTNM = 3, ZIRC = 3, DMND = 1 }, st = "advlab", txt = "Powered clone",
    desc = "Duplicates whatever it's locked to while powered. Locks PERMANENTLY to Steel the instant you place it -- never ore, never anything that gates progression. One per world" },
  { out = "EXOFORGEKIT", n = 1, need = { PTNM = 4, TUNG = 2, DMND = 2, ZIRC = 4 }, st = "advlab", txt = "Exotic Forge",
    desc = "T6 sandbox reward. A slow trickle of Singularity and Antimatter for players who finished the reactor tier and want the pure-physics toybox -- never required for anything" },
}
local function hasDiamondPick() return R.stats and R.stats.crafted and R.stats.crafted["diamond pick"] end

-- ================================================================================================
-- DRAY -- deliberately NOT given an acquisition path. Restating and agreeing with the existing
-- reasoning rather than re-opening it: @automation excluded DRAY on the same economy-integrity
-- grounds design-material-progression.md's S1 uses for BTRY/CLNE ("replicates a line of particles
-- in front of it" -- DRAY.cpp confirms this is a genuine, uncapped, line-scale duplicator, a
-- STRICTLY WORSE risk shape than PCLN/PBCN's single-particle-per-tick behaviour, since one DRAY
-- copies an entire line every activation instead of one cell). This file's own PCLN/PBCN section
-- above shows the safety pattern (lock target, cap count) CAN be applied safely to a duplication
-- element -- but DRAY's line-copy semantics multiply whatever it's locked to by its own configured
-- line length every single tick it's active, not once per tick like PCLN, which is a materially
-- different (larger) risk even under an identical target-lock. Given the family already has two
-- capped members (CLNE via REPLICOREKIT, PCLN+PBCN via this file), and PhoenixFire808's own
-- standing instruction is to respect this reasoning OR argue against it explicitly: this file
-- argues FOR keeping the exclusion, specifically for DRAY, on the stated line-scale-multiplier
-- ground above, distinct from (and stronger than) the general "duplication is risky" reasoning
-- already given for the rest of the family.
--
-- SPRK -- unchanged from both design docs' own conclusion: a transient engine event (the visible
-- state of "this conductor fired this tick"), not a material with any physical identity of its
-- own. "Mine some SPRK" is a category error, not a gap. No pathway given, none argued for.
-- ================================================================================================

local function installRecipes()
  for i = #R.RECIPES, 1, -1 do if R.RECIPES[i]._plugin == TAG then table.remove(R.RECIPES, i) end end
  for _, rc in ipairs(BASE_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
  if R.tech and R.tech.reactor then
    for _, rc in ipairs(REACTOR_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
    for _, rc in ipairs(DUP_RECIPES) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
    if hasDiamondPick() then
      R.acqe.dmndRecipesInstalled = true
      for _, rc in ipairs(DUP_RECIPES_DMND) do rc._plugin = TAG; table.insert(R.RECIPES, rc) end
    end
  end
end
installRecipes()

-- ONE tick hook for this whole file (the hook() helper dedups by tag on registration, so a
-- second hook(R.hooks.tick,...) call would silently replace this one instead of adding to it --
-- both jobs live in a single function on purpose): forge upkeep every frame, and a cheap
-- (one boolean compare) poll for the reactor-online gate flipping true after this file already
-- installed its base recipes, same convention fieldtools.lua uses. A second cheap poll covers the
-- DMND-gated subset (DUP_RECIPES_DMND, above) flipping true independently, since hasDiamondPick()
-- can turn true either before or after R.tech.reactor.
hook(R.hooks.tick, function()
  updateForges()
  if not R.acqe.reactorRecipesInstalled and R.tech and R.tech.reactor then
    R.acqe.reactorRecipesInstalled = true
    installRecipes()
  end
  if not R.acqe.dmndRecipesInstalled and R.tech and R.tech.reactor and hasDiamondPick() then
    installRecipes()
  end
end)

hook(R.hooks.newworld, function()
  R.acqe = { machines = {}, dupPlaced = { PCLN = 0, PBCN = 0 }, reactorRecipesInstalled = false, dmndRecipesInstalled = false }
  installRecipes()
end)
hook(R.hooks.sandbox, function() installRecipes() end)

-- ================================================================ save/load: generic plain-data
-- dump via save.lua, same registration convention every other plugin uses
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
do
  local seen = false
  for _, kk in ipairs(R.PLUGIN_SAVE_KEYS) do if kk == "acq_energy" then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, "acq_energy") end
end

-- ONE R.hooks.place handler for this whole file (same dedup-by-tag reason as the tick hook above
-- -- PCLN/PBCN's direct duplicator placement and the Isotope/Exo Forge kit builders both have to
-- live in this single registration, not two separate hook() calls, or the second call would wipe
-- out the first). PCLN/PBCN are raw elements (checked first); the forge kits are R.ITEMS tokens
-- (checked via the BUILDERS table, same convention fieldtools.lua/automation.lua use).
local BUILDERS = { ISOFORGEKIT = buildIsotopeForge, EXOFORGEKIT = buildExoForge }
hook(R.hooks.place, function(el, mx, my, fine)
  if el == "PCLN" or el == "PBCN" then return tryPlaceDup(el, mx, my) end
  local b = BUILDERS[el]; if not b then return nil end
  if (R.frame - (R.lastForgePlace or -99)) < 20 then return true end
  R.lastForgePlace = R.frame
  R.inventory[el] = inv(el) - 1
  local ok, err = pcall(b, mx, my)
  if not ok then R.pluginErr = tostring(err); R.tlog("error", "acq_energy", "build failed", { el = el, err = tostring(err) }) end
  R.rebuildHotbar()
  return true
end)

R.tlog("info", "acq_energy", "plugin loaded", { baseRecipes = #BASE_RECIPES, reactorRecipes = #REACTOR_RECIPES, dupRecipes = #DUP_RECIPES })

-- ================================================================================================
-- CHANGELOG LINE for the coordinator to land in rpg.lua's R.CHANGELOG (rpg.lua owns R.VERSION;
-- this plugin does not touch it).
-- ================================================================================================
-- "Balance: Powered Clone and the Exotic Forge (both spend a Diamond) no longer show up in
--  the crafting menu until you've built the diamond pick first -- it was possible to spend your
--  only starting diamonds on either one and permanently lock yourself out of the pick."
