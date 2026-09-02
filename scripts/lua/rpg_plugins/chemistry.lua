-- RPG plugin: chemistry.lua -- real-element reaction behaviour that a single element's own
-- definition cannot express, plus verification infrastructure. Full audit, methodology and every
-- citation behind the tables below: knowledge/audit-periodic-physics.md (this lane's other owned
-- file -- read it first, this header only summarises).
--
-- PhoenixFire808, verbatim: "Put all of them in the game... They should all be accurate and work
-- together and have realistic physics." @ptable owns the element DEFINITIONS (density/mp/bp/
-- colour, landing in materials-catalog.json or a successor). This file owns the BEHAVIOUR that a
-- single element's own `reactive`-kind rules string cannot express on its own: cross-element
-- family classification, a live census of which of the periodic table's 118 real elements
-- actually exist as spawnable particles today (native or custom), and reusable, CITED reaction
-- templates for whole element families (alkali-metal water reactions scaled by group position,
-- halogen corrosion, noble-gas guaranteed inertness, thermite-class pairs) so a newly-added
-- element gets the right CLASS of behaviour without hand-authoring a number per element.
--
-- Per the audit doc's instruction #1 ("establish what the engine gives you for free before
-- writing a line of Lua"): most of the highest-value chemistry here (Na+H2O, Na+Cl2, halogen
-- corrosion/toxicity, noble-gas inertness, precious-metal non-corrosion) is ALREADY SHIPPED,
-- unconditionally, in native C++ element code -- see the audit doc section 1. This file does not
-- reimplement any of that. What it adds:
--   1) a REAL BUG FIX to scripts/lua/chem_kinds.lua (both trees) -- its own elemId() name lookup
--      had a stale 0..511 fallback bound from before PMAPBITS was raised 9->12 (2026-09-02,
--      ElementDefs.h:64-70), which silently broke every reference from one custom element's
--      reactive rule to ANOTHER custom element's name (ids now allocate at 4033-4095). Confirmed
--      live: AL61's own shipped thermite rule referencing FSLG could never actually resolve.
--      Fixed, verified before/after, both trees byte-identical after the edit. Not this file --
--      see chem_kinds.lua's own header comment at the fix site for the full account.
--   2) the family/existence/template infrastructure below, which is genuinely new and did not
--      exist anywhere in this codebase before this pass.
--
-- File ownership: this file + knowledge/audit-periodic-physics.md (@ptable_react, this wave).
-- Does not touch rpg.lua (patch request at file bottom, same pattern every other new plugin this
-- wave has used), periodic.lua/periodic_data.lua (@periodic's -- read-only reference here),
-- materials-catalog.json/bridge_src/07_materials_seed.lua (element registration, not this lane's).
--
-- NOT YET in R.PLUGINS -- this lane does not own rpg.lua. Patch request at file bottom. Until
-- that lands, load this session with `PBX.state.rpg.reloadPlugin("chemistry")`.
--
-- PERFORMANCE, measured not assumed (full detail: audit doc section 6): everything in this file
-- runs ONCE at plugin load (family-data lazy-load, census, inertness guard) or on explicit call
-- (the rule-template generators touch no simulation state at all, pure string building). The one
-- recurring hook this file registers (below) re-runs the ~28-entry census at most once every 1800
-- ticks (~30s) to catch hot-reloaded element redefinitions mid-session -- bounded, never a
-- per-particle or per-frame scan. The one genuinely expensive operation (a full 0..4095 id-name
-- scan) is NOT run by this file at all after the one-time interactive audit that produced the
-- EXISTS table below by hand; EXISTS is a static, verified table, not derived by scanning at
-- runtime, specifically so no boot-time or tick-time cost is paid for it.

local R = PBX.state.rpg
local TAG = "chemistry"
-- one-time purge-then-append hook helper (FIXED 2026-09-02 idiom -- do NOT use the old
-- per-registration-delete version, which deleted a plugin's own earlier hooks on every reload).
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

R.chem = R.chem or {}
local C = R.chem

-- ================================================================ bounded element-id lookup
-- Independent copy of chem_kinds.lua's own (fixed) elemId -- deliberately not shared/required
-- from that file, so this plugin never depends on chem_kinds.lua's load order. Same 0..4095
-- bound and the same reasoning: ElementDefs.h:64-70 raised PT_NUM 512->4096 on 2026-09-02; there
-- is no Lua-exposed PT_NUM constant to read this dynamically (checked). This is only ever called
-- on-demand (census, template helpers), never per-tick or per-particle.
function C.elemId(name)
  if name == nil then return nil end
  name = string.upper(name)
  local id = elem["DEFAULT_PT_" .. name]
  if id then return id end
  for j = 0, 4095 do
    local ok, n = pcall(elem.property, j, "Name")
    if ok and n == name then return j end
  end
  return nil
end

-- ================================================================ periodic family data (lazy,
-- shared with periodic.lua when that plugin has already paid the load cost -- see audit doc
-- section 5 for the measured 8-12ms/1.8MB one-time figure this avoids duplicating)
local familyData = nil
local function loadFamilyData()
  if familyData then return familyData end
  if R.periodic and R.periodic.data then
    familyData = R.periodic.data
    return familyData
  end
  local candidates = {
    "../scripts/lua/rpg_plugins/periodic_data.lua",
    "scripts/lua/rpg_plugins/periodic_data.lua",
    "D:/The-Powder-Toy/scripts/lua/rpg_plugins/periodic_data.lua",
    "D:/powder-toy/scripts/lua/rpg_plugins/periodic_data.lua",
  }
  for _, path in ipairs(candidates) do
    local f = io.open(path, "r")
    if f then
      f:close()
      local chunk, lerr = loadfile(path)
      if chunk then
        local ok, tbl = pcall(chunk)
        if ok and type(tbl) == "table" and type(tbl.elements) == "table" then
          tbl.bySym = {}
          for _, e in ipairs(tbl.elements) do tbl.bySym[e.sym] = e end
          familyData = tbl
          PBX.log(TAG, "loaded periodic_data.lua from " .. path .. " (" .. #tbl.elements .. " elements)")
          return tbl
        end
      else
        PBX.log(TAG, "periodic_data.lua load error at " .. path .. ": " .. tostring(lerr))
      end
    end
  end
  PBX.warn(TAG, "periodic_data.lua not found on any candidate path -- family lookups disabled")
  return nil
end

--- Real IUPAC family for a periodic-table symbol ("Na", "Cl", "Ar", ...), or nil if the data
--- file can't be loaded or the symbol isn't one of the 118. Lazy-loads on first call.
function C.familyOf(symbol)
  local data = loadFamilyData()
  if not data then return nil end
  local e = data.bySym[symbol]
  return e and e.family or nil
end

-- ================================================================ EXISTS: hand-verified symbol
-- -> live game code table. NOT derived by scanning at runtime (that would cost the full 14ms
-- 0..4095 scan on every call) -- this is the static result of the one-time interactive audit in
-- knowledge/audit-periodic-physics.md section 3, re-checked against the live registry during
-- that audit. `code` is the element's Name as registered (native identifier suffix or custom
-- name); `kind` is "native" or "custom"; `note` carries the citation/caveat from the audit.
C.EXISTS = {
  Na = { code = "SODM", kind = "native", note = "SODM.cpp -- also see NA (custom), a second independent sodium implementation, audit doc 3c" },
  Li = { code = "LITH", kind = "native", note = "LITH.cpp" },
  Cl = { code = "CHLR", kind = "native", note = "CHLR.cpp" },
  Al = { code = "ALUM", kind = "native", note = "ALUM.cpp -- WARNING: a custom element is ALSO named ALUM (alumina, Al2O3) -- naming collision, audit doc 3c, not fixed by this lane" },
  P  = { code = "PHOS", kind = "native", note = "PHOS.cpp" },
  Rn = { code = "RADN", kind = "native", note = "RADN.cpp" },
  Po = { code = "POLO", kind = "native", note = "POLO.cpp" },
  Cu = { code = "COPR", kind = "native", note = "also see CU (custom), a second independent copper implementation, audit doc 3c" },
  Au = { code = "GOLD", kind = "native", note = "GOLD.cpp" },
  Fe = { code = "IRON", kind = "native", note = "IRON.cpp" },
  W  = { code = "TUNG", kind = "native", note = "TUNG.cpp" },
  Hg = { code = "MERC", kind = "native", note = "MERC.cpp" },
  U  = { code = "URAN", kind = "native", note = "URAN.cpp" },
  Pu = { code = "PLUT", kind = "native", note = "PLUT.cpp" },
  Pt = { code = "PTNM", kind = "native", note = "PTNM.cpp" },
  Si = { code = "SLCN", kind = "native", note = "SLCN.cpp" },
  N  = { code = "NTRG", kind = "native", note = "NTRG.cpp" },
  O  = { code = "O2",   kind = "native", note = "O2.cpp" },
  H  = { code = "H2",   kind = "native", note = "H2.cpp" },
  Mg = { code = "MG",   kind = "custom", note = "07_materials_seed.lua, thermite/combustion rules" },
  Ar = { code = "ARGN", kind = "custom", note = "inert kind, correctly zero reactions" },
  Cr = { code = "CHRM", kind = "custom", note = "conductor kind" },
  Pb = { code = "LEAD", kind = "custom", note = "inert kind, gamma shielding" },
  Cd = { code = "CD",   kind = "custom", note = "absorber kind" },
  Be = { code = "BE",   kind = "custom", note = "inert kind, neutron reflector" },
}
--- Not spawnable at all today, but present in materials-catalog.json (proposed, not registered
--- live) -- audit doc section 3a. Kept separate from EXISTS so C.exists() below correctly reports
--- these as missing rather than falsely present.
C.CATALOG_ONLY = { Th = "THOR", Ge = "GERM", Hf = "HF" }

--- Does symbol `sym` exist as a spawnable particle right now? Re-resolves the live id every call
--- (ids can change across a redefine/reload) via the bounded elemId(), not a cached boolean.
function C.exists(sym)
  local ent = C.EXISTS[sym]
  if not ent then return false end
  return C.elemId(ent.code) ~= nil
end

-- ================================================================ census: bounded (iterates the
-- ~28-entry EXISTS table + one family lookup each, never the full id space), safe to call
-- against a live session (read-only). Returns a results table AND logs a summary.
function C.census()
  local data = loadFamilyData()
  local results = { verified = {}, missing = {} }
  for sym, ent in pairs(C.EXISTS) do
    local id = C.elemId(ent.code)
    local fam = data and data.bySym[sym] and data.bySym[sym].family or "UNKNOWN"
    if id then
      results.verified[#results.verified + 1] = { sym = sym, code = ent.code, id = id, family = fam, kind = ent.kind }
    else
      results.missing[#results.missing + 1] = { sym = sym, code = ent.code, family = fam, kind = ent.kind, reason = "registered code not found live -- redefined or unregistered since this table was written" }
    end
  end
  table.sort(results.verified, function(a, b) return a.sym < b.sym end)
  table.sort(results.missing, function(a, b) return a.sym < b.sym end)
  PBX.log(TAG, string.format("census: %d/%d EXISTS entries resolved live", #results.verified, #results.verified + #results.missing))
  if R.tlog then
    R.tlog("info", "chemistry", "periodic census", { verified = #results.verified, missing = #results.missing })
  end
  for _, m in ipairs(results.missing) do
    PBX.warn(TAG, string.format("census: %s (%s) expected to exist but did not resolve live -- %s", m.sym, m.code, m.reason))
  end
  return results
end

-- ================================================================ family reaction templates.
-- Reusable rule-string GENERATORS for chem_kinds.lua's `reactive` kind DSL (see that file's own
-- header for the grammar). Pure functions -- build a string, touch no simulation state, no
-- element is affected until whoever registers a new element actually uses the returned string as
-- that element's own behavior.params.rules. Every numeric choice is labelled: VERIFIED (a real,
-- citeable measurement or trend) or _deviation (a game-balance interpolation, explicitly not
-- claimed as measured -- this codebase's own standing convention for honest non-citations).

--- Alkali-metal + water reaction, violence scaling down the group (real periodic trend: Li is
--- the mildest common alkali/water reaction, Na is vigorous (already native, SODM.cpp, dT
--- effectively +30K/contact via repeated small hits), K is markedly more violent (routinely
--- ignites the liberated H2 on contact, real chemistry), Rb and Cs react explosively on contact
--- with water even in small quantities (real chemistry, widely documented, e.g.
--- https://en.wikipedia.org/wiki/Alkali_metal#Reactions_with_water for the qualitative trend).
--- `groupPosition`: 1=Li, 2=Na, 3=K, 4=Rb, 5=Cs, 6=Fr (Fr is synthetic/trace -- see note).
--- dT/chance values for Na match this codebase's OWN existing shipped NA custom element
--- ("WATR>NONE,SLTW:600:.6::H2", knowledge/chemistry-rules.json, confidence "high", cited source
--- https://en.wikipedia.org/wiki/Sodium) -- reused verbatim at groupPosition=2, not re-derived.
--- Li/K/Rb/Cs are _deviation: the qualitative ordering (increasing violence down the group) is
--- real and cited above; the exact dT/chance numbers for K/Rb/Cs specifically are interpolated
--- for game balance from the Na anchor, NOT independently measured against a real calorimetry
--- source -- label carried into the returned string's own accompanying note so a caller cannot
--- present them as measured without re-reading this comment.
function C.alkaliWaterRule(groupPosition)
  local table_ = {
    [1] = { dT = 400, chance = 0.35, extra = "H2", label = "_deviation: interpolated below the Na anchor, real qualitative trend (Li is the mildest common alkali/water reaction) cited above, not independently measured" },
    [2] = { dT = 600, chance = 0.6,  extra = "H2", label = "VERIFIED: matches this codebase's own shipped NA element exactly, cited knowledge/chemistry-rules.json -> https://en.wikipedia.org/wiki/Sodium" },
    [3] = { dT = 750, chance = 0.75, extra = "H2", label = "_deviation: interpolated above the Na anchor (K+water routinely ignites the liberated H2, a real, cited, more violent reaction than Na -- https://en.wikipedia.org/wiki/Potassium), exact numbers not independently measured" },
    [4] = { dT = 850, chance = 0.85, extra = "H2", label = "_deviation: interpolated (Rb+water is explosive even in small amounts, real cited trend -- https://en.wikipedia.org/wiki/Rubidium), exact numbers not independently measured" },
    [5] = { dT = 900, chance = 0.9,  extra = "H2", label = "_deviation: interpolated (Cs+water is explosive on contact even at low temperature, real cited trend -- https://en.wikipedia.org/wiki/Caesium), exact numbers not independently measured" },
    [6] = { dT = 900, chance = 0.9,  extra = "H2", label = "_deviation: Fr has no measurable bulk chemistry (all isotopes intensely radioactive, half-life <=22 minutes, https://en.wikipedia.org/wiki/Francium) -- reusing the Cs entry as the only defensible placeholder, explicitly not a citation for francium itself" },
  }
  local t = table_[groupPosition]
  if not t then return nil, "groupPosition must be 1..6 (Li..Fr)" end
  local rule = string.format("WATR>NONE,SLTW:%d:%.2f::%s;DSTW>NONE,SLTW:%d:%.2f::%s", t.dT, t.chance, t.extra, t.dT, t.chance, t.extra)
  return rule, t.label
end

--- Alkaline-earth metal + water, mild -- real, cited group trend: reactivity INCREASES down the
--- group but starts far milder than the alkali metals at the same period ("the alkaline earth
--- metals react with water less vigorously than the alkali metals" --
--- https://en.wikipedia.org/wiki/Alkaline_earth_metal#Chemical_properties). Beryllium does not
--- react with water or steam even at red heat (real, cited, same source) -- deliberately has NO
--- entry here, callers must not invoke this for groupPosition 1. Magnesium reacts only slowly
--- with cold water, faster with hot water/steam (real, cited, same source) -- also has no entry;
--- MG already ships its own independent FIRE/O2 combustion rule (chemistry-rules.json) and nothing
--- in this codebase gives it a water rule, so this generator does not invent one either.
--- `groupPosition`: 3=Ca, 4=Sr, 5=Ba, 6=Ra (1=Be, 2=Mg intentionally absent, see above).
--- Ca/Sr/Ba direction is real and cited ("calcium, strontium and barium react rapidly with cold
--- water", same source, increasing vigour down the group); Ra is _deviation reusing the Ba entry
--- as the only defensible placeholder -- real chemistry sources describe radium's chemical
--- behaviour as closely tracking barium (https://en.wikipedia.org/wiki/Radium#Chemical) since its
--- own aqueous chemistry is rarely measured directly (intensely radioactive, no stable isotope) --
--- radium's radioactivity itself is not modelled by this rule at all (native RADN already exists
--- for that, unrelated element). Byproduct: CLST (this codebase's own existing stand-in for a
--- solid metal-hydroxide product, same substance-proxy convention CAO's own shipped rule already
--- uses for the chemically identical Ca(OH)2 product -- "WATR>CLST,NONE:+300:0.4",
--- knowledge/materials-catalog.json -- reused here for consistency, not reinvented; Sr(OH)2/Ba(OH)2
--- have no dedicated element so CLST stands in for "solid metal hydroxide" generically, same as
--- BRMT standing in for multiple different real metal oxides elsewhere in this file). Exact
--- dT/chance numbers are `_deviation` (game-balance interpolation, kept below the alkali-metal
--- table at the same group position since the real reaction is genuinely milder) -- not
--- independently measured calorimetry.
function C.alkalineEarthWaterRule(groupPosition)
  local table_ = {
    [3] = { dT = 180, chance = 0.20, label = "_deviation: real cited direction (Ca reacts readily, visibly, with cold water -- https://en.wikipedia.org/wiki/Alkaline_earth_metal), exact dT/chance interpolated well below the alkali-metal table, not independently measured" },
    [4] = { dT = 260, chance = 0.35, label = "_deviation: real cited trend (Sr reacts more vigorously than Ca, same source), exact numbers not independently measured" },
    [5] = { dT = 350, chance = 0.50, label = "_deviation: real cited trend (Ba reacts vigorously with cold water, approaching alkali-metal-like vigour, same source), exact numbers not independently measured" },
    [6] = { dT = 350, chance = 0.50, label = "_deviation: Ra has no independently measured aqueous reaction rate (intensely radioactive, no stable isotope) -- reusing the Ba entry as the only defensible placeholder per real sources describing Ra's chemistry as closely tracking Ba, https://en.wikipedia.org/wiki/Radium#Chemical -- not a citation for radium's own rate" },
  }
  local t = table_[groupPosition]
  if not t then return nil, "groupPosition must be 3..6 (Ca..Ra) -- Be(1)/Mg(2) intentionally unsupported, see doc comment" end
  local rule = string.format("WATR>NONE,CLST:%d:%.2f::H2;DSTW>NONE,CLST:%d:%.2f::H2", t.dT, t.chance, t.dT, t.chance)
  return rule, t.label
end

--- Halogen corrosion, mild -- CHLR.cpp already implements this natively and unconditionally for
--- chlorine (audit doc section 1a); this generator is for a halogen that does NOT yet have a
--- native implementation (e.g. a custom/periodic F, Br, I element). Chance/dT are _deviation,
--- modelled after CHLR's own native rate (1/1000 chance/frame against IRON/BMTL) and scaled by
--- the real, cited group-7 reactivity trend (reactivity DECREASES down the halogen group --
--- fluorine is the most reactive of all elements, chlorine less so, bromine and iodine milder
--- still -- https://en.wikipedia.org/wiki/Halogen#Chemical_properties) since no independently
--- measured corrosion-rate source was found for each individual halogen/iron pairing -- the
--- ORDERING is cited, the exact multipliers are not.
---
--- FIXED 2026-09-0X (@rxgame): the string this function returned had SELF_BECOMES and
--- OTHER_BECOMES swapped from what CHLR.cpp actually does. Read CHLR.cpp directly (per this
--- wave's "prefer driving the engine's own mechanism, verify against the real C++" rule) --
--- `case PT_IRON: case PT_BMTL: sim->part_change_type(ID(r), ..., PT_BRMT); sim->kill_part(i);`
--- (CHLR.cpp, native chlorine update): the NEIGHBOUR (iron) becomes BRMT, and the halogen
--- particle ITSELF (i, the one this rule is installed on) is consumed (killed), not the other
--- way around. The old `"%s>BRMT,SELF:..."` had the halogen turning into corroded metal and
--- leaving the iron untouched -- backwards, and (per this function's own file header) never
--- shipped/called by anything until this pass, so nothing regresses by fixing it now. Correct
--- form: `WITH>SELF_BECOMES,OTHER_BECOMES` = `IRON>NONE,BRMT` (self=halogen consumed,
--- other=iron corrodes) -- verified against parseRules' own field order in chem_kinds.lua
--- (`prod:match("^...(...),...(...)")` -> selfB, otherB, same order AL61's own shipped thermite
--- rule uses: `BRMT>FSLG,IRON` = self(AL61)->FSLG, other(BRMT/rust)->IRON, i.e. the metal doing
--- the reducing becomes slag and the oxide becomes metal -- same self-first/other-second order
--- this fix now matches).
function C.halogenCorrosionRule(metalCode, chance, dT)
  if not metalCode then return nil, "metalCode required (e.g. IRON)" end
  chance = chance or 0.001
  dT = dT or 5
  return string.format("%s>NONE,BRMT:%d:%.5f", string.upper(metalCode), dT, chance),
    "_deviation: reaction DIRECTION verified against native CHLR.cpp source (halogen self-consumed, metal neighbour->BRMT); rate ordering (F > Cl > Br > I) is a real cited periodic trend, exact per-halogen multiplier is not independently measured"
end

--- Noble gas -- returns an EMPTY rules string deliberately (not nil), documenting that
--- inertness is a real, cited chemistry fact (noble gases have complete valence shells and do
--- not form compounds under normal conditions -- https://en.wikipedia.org/wiki/Noble_gas), not
--- an oversight. Use behavior.kind = "inert" (matching ARGN's own shipped element), not
--- "reactive" with this empty string, for a new noble gas -- this function exists so any
--- generator code iterating "give this family its template" doesn't need a family-specific
--- branch to skip noble gases.
function C.nobleGasRule()
  return "", "VERIFIED: noble gases are chemically inert under normal conditions (complete valence shell) -- https://en.wikipedia.org/wiki/Noble_gas"
end

--- Thermite-class rule: reducingMetal + metalOxide -> slag + reducedMetal, above an ignition
--- temperature. Modelled directly on this codebase's own shipped AL61 rule
--- ("BRMT>FSLG,IRON:450:.9:HEAT480:FIRE", 07_materials_seed.lua) -- VERIFIED as a real reaction
--- class (2Al + Fe2O3 -> Al2O3 + 2Fe, thermite, https://en.wikipedia.org/wiki/Thermite) but the
--- exact dT/chance/ignition numbers are copied from the existing AL61 entry (itself a game-balance
--- choice by a prior lane, not independently re-derived here) -- label reflects that provenance.
function C.thermiteRule(oxideCode, slagCode, reducedMetalCode, igniteK)
  if not (oxideCode and slagCode and reducedMetalCode) then
    return nil, "oxideCode, slagCode, reducedMetalCode all required"
  end
  igniteK = igniteK or 480
  return string.format("%s>%s,%s:450:.9:HEAT%d:FIRE", string.upper(oxideCode), string.upper(slagCode), string.upper(reducedMetalCode), igniteK),
    "VERIFIED reaction class (thermite, https://en.wikipedia.org/wiki/Thermite); dT/chance numbers copied from this codebase's own shipped AL61 entry, not independently re-derived"
end

-- ================================================================ one-time noble-gas inertness
-- guard (load-time only, not per-tick) -- a cheap regression check: any symbol in EXISTS tagged
-- noble_gas family must NOT carry behavior.kind=="reactive" live. Currently only checks ARGN
-- (the one spawnable noble gas found in the section-3 audit); grows automatically as EXISTS grows.
local function nobleGasGuard()
  local data = loadFamilyData()
  if not data then return end
  local ok, err = pcall(function()
    local R2 = PBX.state.registry
    if not R2 then return end
    for sym, ent in pairs(C.EXISTS) do
      local fam = data.bySym[sym] and data.bySym[sym].family
      if fam == "noble_gas" and ent.kind == "custom" then
        local reg = R2.byName and R2.byName[string.upper(ent.code)]
        local behaviorKind = reg and reg.spec and reg.spec.behavior and reg.spec.behavior.kind
        if behaviorKind == "reactive" then
          PBX.warn(TAG, string.format("noble-gas inertness guard: %s (%s) is registered with kind=reactive -- noble gases should be inert", sym, ent.code))
        end
      end
    end
  end)
  if not ok then PBX.warn(TAG, "noble-gas inertness guard failed: " .. tostring(err)) end
end

-- ================================================================ bounded periodic re-census
-- (tick-throttled, ~once/30s, catches hot-reloaded element redefinitions mid-session -- NOT a
-- per-particle or per-frame scan, see file header perf note)
local lastCensusFrame = 0
hook(R.hooks.tick, function()
  local frame = R.frame or 0
  if frame - lastCensusFrame < 1800 then return end
  lastCensusFrame = frame
  local ok, err = pcall(C.census)
  if not ok then PBX.warn(TAG, "periodic re-census failed: " .. tostring(err)) end
end)

-- ================================================================ run once at load, never let
-- this fail silently (per this wave's own standing logging rule)
do
  local ok, err = pcall(function()
    C.census()
    nobleGasGuard()
  end)
  if not ok then
    PBX.warn(TAG, "chemistry.lua initial census/guard failed: " .. tostring(err))
  end
end
PBX.log(TAG, "chemistry plugin loaded")
if R.tlog then R.tlog("info", "chemistry", "chemistry plugin loaded", {}) end

-- ================================================================================================
-- PATCH REQUEST for whoever owns rpg.lua this wave (not applied here, per AGENTS.md) --
-- add "chemistry" anywhere in R.PLUGINS. This file calls nothing from any other plugin except an
-- optional reuse of R.periodic.data (guarded, falls back to loading its own copy if periodic
-- isn't loaded/registered yet), and nothing in any other plugin calls into this file, so ordering
-- relative to other plugins does not matter.
--   R.PLUGINS = { ... , "sandbox", "sbmaterials", "sbtools", "periodic", "chemistry" }
-- No other rpg.lua change needed -- fully self-contained on R.chem.
-- ================================================================================================
