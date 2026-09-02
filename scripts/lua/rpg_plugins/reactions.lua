-- RPG plugin: reactions.lua -- wires CONFIRMED, cited reactions onto the periodic elements that
-- 08_periodic_seed.lua registered with no explicit behaviour. Live-verified this pass (own lab
-- instance, port 9891, own token): EVERY one of that file's 88 add()'d entries omits `behavior`
-- entirely, and 10_registry.lua's own validateSpec (bridge_src/10_registry.lua:558,
-- `wanted = { kind = "inert", params = {} }` when no behavior is given/inherited) defaults that
-- to kind="inert" -- confirmed live: K/CA/F/BR/I/AT/SR/BA/RA/CS/FR/HE all read
-- `ent.spec.behavior.kind == "inert"` on a fresh boot. "inert" installs a real Update closure
-- (20_behaviors.lua's own kinds.inert.make, `return false` every call) so `ent.hasUpdate` is
-- already true for all of them -- hasUpdate alone is NOT a safe "already reactive" check for
-- this element family; this file checks `ent.spec.behavior.kind` instead.
--
-- MECHANISM, chosen to avoid two different risks:
--   1) bridge_src/08_periodic_seed.lua is GENERATED ("Do not hand-edit", own header) and owned by
--      the element-DEFINITIONS lane, not this one -- not edited here, per this wave's file split
--      (behaviour is this file's job, definitions are not).
--   2) A second, independent per-tick particle scanner (like thermo.lua's own, which that file's
--      own header measures and justifies for latent heat, a genuinely different problem shape)
--      would duplicate chem_kinds.lua's already-proven, already-shipped `reactive` kind for no
--      reason -- per this wave's "prefer driving the engine's own mechanism" instruction.
-- Instead: this file calls `PBX.state.behaviors.kinds.reactive.make(rules)` (the exact function
-- 10_registry.lua's own applySpec calls for every other reactive custom element, e.g. NA, AL61)
-- to build the identical, already-tested Update closure, then installs it with
-- `elements.property(id, "Update", fn)` -- the same call registry's own applySpec makes
-- (bridge_src/10_registry.lua:663-668). Nothing here reimplements the reactive DSL, the
-- neighbour scan, or the parser; it only decides WHICH already-existing element gets WHICH
-- already-cited rule string, reusing chemistry.lua's own generator functions for the numbers.
--
-- Runs once, deferred to this plugin's first tick (matching 10_registry.lua's own convention of
-- only ever calling elements.property from inside a mutable-tools event, never at top-level
-- plugin load) -- installing at plugin load time was NOT tested and is deliberately avoided.
-- Idempotent per boot, like every other plugin in this codebase (chemistry.lua/thermo.lua) --
-- does not persist to pbx-custom-elements.json, re-applies itself fresh every boot the same way
-- 08_periodic_seed.lua itself does, so nothing here depends on write-through persistence.
--
-- Every numeric reaction rule used below is chemistry.lua's own (this lane's other file) --
-- CITED/`_deviation`-labelled there, not re-derived here. This file only decides placement. Full
-- citations: chemistry.lua's own C.alkaliWaterRule/C.alkalineEarthWaterRule/C.halogenCorrosionRule
-- doc comments, and knowledge/audit-periodic-physics.md.
--
-- @rxdata's knowledge/reactions-cited.json (the wider cross-reference sheet) had not landed on
-- disk as of this pass (checked: file does not exist) -- this file ships only the reactions it can
-- independently cite through chemistry.lua's own generators (same citation bar: a real source +
-- fetch-traceable claim, or explicitly marked _deviation for the non-measured numbers). If/when
-- reactions-cited.json lands, extend PLAN below from it rather than duplicating this file's own
-- table -- left as an explicit follow-up, not done blind against a file that does not exist yet.
--
-- File ownership: this lane owns chemistry.lua and this file. Does not touch
-- bridge_src/08_periodic_seed.lua, rpg.lua ("chemistry"/"thermo" already both landed in
-- R.PLUGINS, rpg.lua:6952 -- "reactions" patch request at file bottom, same pattern), or any
-- other plugin.

local R = PBX.state.rpg
local TAG = "reactions"
-- one-time purge-then-append hook helper (FIXED 2026-09-02 idiom, matches chemistry.lua/thermo.lua)
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

R.reactions = R.reactions or {}
local X = R.reactions

-- ================================================================ install plan: live periodic-
-- element symbol -> which chemistry.lua generator builds its rule, and with what arguments.
-- Every entry here is a REAL, spawnable, currently-inert element (verified live, this pass, own
-- lab instance) about to get a REAL, cited reaction for the first time.
local PLAN = {
  -- Alkali metals: real, well-documented, increasingly violent water reactions down the group
  -- (https://en.wikipedia.org/wiki/Alkali_metal#Reactions_with_water). Li and Na are already
  -- native (LITH.cpp, SODM.cpp) and deliberately not touched here -- this file only wires
  -- elements that were actually verified inert.
  K  = { gen = "alkaliWaterRule", args = { 3 } },
  CS = { gen = "alkaliWaterRule", args = { 5 } },
  FR = { gen = "alkaliWaterRule", args = { 6 } }, -- chemistry.lua's own doc: reuses Cs's numbers,
                                                    -- Fr has no measurable bulk chemistry (all
                                                    -- isotopes radioactive, half-life <=22min)

  -- Alkaline earth metals: real, cited, milder-than-alkali water reactions (see
  -- chemistry.lua's C.alkalineEarthWaterRule doc comment for the full citation). Be/Mg
  -- intentionally excluded (real: Be does not react with water/steam even red-hot; Mg reacts
  -- only slowly with cold water and already ships its own independent FIRE/O2 combustion rule).
  CA = { gen = "alkalineEarthWaterRule", args = { 3 } },
  SR = { gen = "alkalineEarthWaterRule", args = { 4 } },
  BA = { gen = "alkalineEarthWaterRule", args = { 5 } },
  RA = { gen = "alkalineEarthWaterRule", args = { 6 } },

  -- Halogens: real, cited corrosion of iron. Direction verified against native CHLR.cpp this
  -- pass (chemistry.lua's C.halogenCorrosionRule doc comment records the fix). Reactivity
  -- decreases down the group -- F > Cl > Br > I, real cited trend
  -- (https://en.wikipedia.org/wiki/Halogen#Chemical_properties); Cl is already native (CHLR.cpp).
  -- Exact per-halogen chance is `_deviation` (ordering is cited, magnitude is not measured for
  -- this specific game mechanic) -- scaled around CHLR's own native 1/1000 rate.
  F  = { gen = "halogenCorrosionRule", args = { "IRON", 0.004, 5 } },   -- most reactive element there is
  BR = { gen = "halogenCorrosionRule", args = { "IRON", 0.0004, 5 } },  -- milder than Cl
  I  = { gen = "halogenCorrosionRule", args = { "IRON", 0.00015, 5 } }, -- mildest of the reactive halogens
  -- At (astatine) deliberately NOT installed: no source describes its bulk chemistry with iron --
  -- it has never existed in weighable quantity (longest-lived isotope At-210, half-life 8.1h,
  -- https://en.wikipedia.org/wiki/Astatine, "its bulk properties are not known with certainty and
  -- are mostly estimated or extrapolated") -- shipping a number here would be fabrication, not a
  -- citation. Recorded UNCONFIRMED below, not silently dropped.
}

--- Noble gases: real, cited, CONFIRMED inert (complete valence shell, no compounds under normal
--- conditions -- https://en.wikipedia.org/wiki/Noble_gas). The CORRECT implementation is the
--- ABSENCE of a reactive Update -- already their live state (kind="inert", verified above) and
--- deliberately left alone by this file. Listed so the verification report below counts them as
--- checked-and-correctly-inert rather than silently unchecked. Rn is already native (RADN.cpp,
--- radioactive decay chain, unrelated to chemical reactivity) and not listed again here.
local CONFIRMED_INERT = { "HE", "NE", "AR", "KR", "XE", "OG" }

--- Astatine: the one element this pass explicitly could NOT confirm a reaction for. Recorded so
--- `X.report()` shows it as a real, disclosed gap rather than something nobody looked at.
local UNCONFIRMED = { AT = "no source describes bulk At/Fe chemistry -- At has never existed in weighable quantity (longest isotope At-210, half-life 8.1h)" }

-- ================================================================ install (deferred to first
-- tick, per this file's header -- elements.property must run inside a mutable-tools event, and
-- registering it from plugin top-level load was not tested).
--
-- FIXED live, this pass (own lab instance, second boot): a fresh boot's periodic-element
-- registration is itself chunked across many ticks (10_registry.lua's own queueSpecList/defer
-- batching -- confirmed live: at frame 3 on a fresh boot only 5 of this plan's 10 symbols had a
-- live id yet, the other 5 read `ent == nil`). The first version of this function ran exactly
-- once (a single global `installed` latch) and treated "not registered yet" the same as "done" --
-- on a fresh boot it would have silently and PERMANENTLY skipped installing behaviour on
-- whichever symbols hadn't finished registering by that one attempt, for the rest of the session.
-- Reproduced live before fixing (see knowledge/rpg-hub.md, this lane's entry, for the exact
-- installed=5/skipped_missing=5 read). Fixed: per-symbol pending set, retried every tick until
-- each symbol resolves (installed / correctly-skipped / failed) or hits RETRY_LIMIT_TICKS, so a
-- slow-to-register element still gets its reaction once it exists, while a genuinely-never-
-- appearing name eventually stops being retried instead of costing a lookup forever.
local RETRY_LIMIT_TICKS = 3600 -- ~60s of tick-hook calls -- generous relative to the few-second
                                -- registration window measured live, bounded so a permanently
                                -- missing element (e.g. this plan referencing a symbol that was
                                -- renamed/removed) cannot retry forever.
local pending = {}
for sym in pairs(PLAN) do pending[sym] = 0 end -- value = attempt count
local results = { installed = {}, skipped_not_inert = {}, skipped_missing = {}, failed = {} }
X.lastInstallResult = results

local function tryInstallOne(sym)
  local C = R.chem
  if not C then return false end -- chemistry.lua not loaded yet -- retry
  local reg = PBX.state.registry
  local kindsTbl = PBX.state.behaviors and PBX.state.behaviors.kinds
  local reactiveDef = kindsTbl and kindsTbl.reactive
  if not reactiveDef then return false end -- behaviour kinds not published yet -- retry

  local plan = PLAN[sym]
  local ent = reg and reg.byName and reg.byName[sym]
  if not ent or ent.id == nil or not elements.exists(ent.id) then
    return false -- not registered yet (or this boot never will) -- caller decides whether to keep retrying
  end
  if not (ent.spec and ent.spec.behavior and ent.spec.behavior.kind == "inert") then
    -- something else (another lane, a player, a hot-reload) already customised this element's
    -- behaviour since this file last looked -- never clobber it. Resolved either way.
    results.skipped_not_inert[#results.skipped_not_inert + 1] =
      { sym = sym, kind = ent.spec and ent.spec.behavior and ent.spec.behavior.kind or "?" }
    return true
  end

  local genFn = C[plan.gen]
  if type(genFn) ~= "function" then
    results.failed[#results.failed + 1] = { sym = sym, error = "chemistry.lua has no generator " .. tostring(plan.gen) }
    return true
  end
  local ok, rule, label = pcall(genFn, table.unpack(plan.args))
  if not ok then
    results.failed[#results.failed + 1] = { sym = sym, error = "generator raised: " .. tostring(rule) }
    return true
  elseif not rule then
    results.failed[#results.failed + 1] = { sym = sym, error = tostring(label) }
    return true
  end
  local fnOk, fn = pcall(reactiveDef.make, { rules = rule })
  if not fnOk or type(fn) ~= "function" then
    results.failed[#results.failed + 1] = { sym = sym, error = "reactive.make failed: " .. tostring(fn) }
    return true
  end
  local setOk, setErr = pcall(elements.property, ent.id, "Update", fn)
  if not setOk then
    results.failed[#results.failed + 1] = { sym = sym, error = "elements.property Update failed: " .. tostring(setErr) }
    return true
  end
  -- keep the registry's own bookkeeping honest, in-memory only (not persisted -- see file
  -- header, this reinstalls itself fresh every boot the same way the seed file does) so a
  -- same-session read of ent.spec.behavior.kind reports reality.
  ent.spec.behavior = { kind = "reactive", params = { rules = rule } }
  ent.hasUpdate = true
  results.installed[#results.installed + 1] = { sym = sym, id = ent.id, rule = rule, label = label }
  PBX.log(TAG, string.format("installed reactive behaviour on %s (id %d): %s", sym, ent.id, rule))
  return true
end

local reportedDone = false
hook(R.hooks.tick, function()
  if next(pending) == nil then
    if not reportedDone then
      reportedDone = true
      X.installedAtFrame = R.frame
      local msg = string.format(
        "periodic reaction install COMPLETE: %d installed, %d skipped(not-inert), %d skipped(missing/gave up), %d failed",
        #results.installed, #results.skipped_not_inert, #results.skipped_missing, #results.failed)
      PBX.log(TAG, msg)
      if R.tlog then
        R.tlog("info", "reactions", "periodic reaction install complete", {
          installed = #results.installed, skipped_not_inert = #results.skipped_not_inert,
          skipped_missing = #results.skipped_missing, failed = #results.failed,
        })
      end
      for _, f in ipairs(results.failed) do
        PBX.warn(TAG, string.format("install failed for %s: %s", f.sym, f.error))
      end
    end
    return
  end
  for sym in pairs(pending) do
    local ok, resolved = pcall(tryInstallOne, sym)
    if not ok then
      PBX.warn(TAG, string.format("tryInstallOne(%s) raised: %s", sym, tostring(resolved)))
      results.failed[#results.failed + 1] = { sym = sym, error = "raised: " .. tostring(resolved) }
      pending[sym] = nil
    elseif resolved then
      pending[sym] = nil
    else
      pending[sym] = pending[sym] + 1
      if pending[sym] > RETRY_LIMIT_TICKS then
        results.skipped_missing[#results.skipped_missing + 1] = sym
        PBX.warn(TAG, string.format("%s never registered live after %d tick-hook attempts -- giving up", sym, RETRY_LIMIT_TICKS))
        pending[sym] = nil
      end
    end
  end
end)

--- Verification/report helper -- bounded (iterates PLAN + CONFIRMED_INERT + UNCONFIRMED, ~26
--- entries total, never a full id-space scan), safe to call against a live session read-only.
function X.report()
  local reg = PBX.state.registry
  local lines = {}
  lines[#lines + 1] = string.format("reactions.lua: install pass has%s run (frame %s), %d symbol(s) still pending",
    reportedDone and "" or " NOT yet", tostring(X.installedAtFrame), (function() local n=0; for _ in pairs(pending) do n=n+1 end; return n end)())
  if X.lastInstallResult then
    local r = X.lastInstallResult
    lines[#lines + 1] = string.format("  installed=%d skipped_not_inert=%d skipped_missing=%d failed=%d",
      #r.installed, #r.skipped_not_inert, #r.skipped_missing, #r.failed)
    for _, e in ipairs(r.installed) do
      lines[#lines + 1] = "  + " .. e.sym .. " (id " .. tostring(e.id) .. "): " .. e.rule
    end
    for _, e in ipairs(r.failed) do
      lines[#lines + 1] = "  ! FAILED " .. e.sym .. ": " .. e.error
    end
  end
  lines[#lines + 1] = "confirmed-inert (verified absence of reaction, by design, cited): " .. table.concat(CONFIRMED_INERT, ", ")
  for sym, why in pairs(UNCONFIRMED) do
    lines[#lines + 1] = "UNCONFIRMED, not shipped: " .. sym .. " -- " .. why
  end
  local text = table.concat(lines, "\n")
  PBX.log(TAG, "report:\n" .. text)
  return text
end

PBX.log(TAG, "reactions plugin loaded")
if R.tlog then R.tlog("info", "reactions", "reactions plugin loaded", {}) end

-- ================================================================================================
-- PATCH REQUEST for whoever owns rpg.lua this wave (not applied here, per AGENTS.md) --
-- add "reactions" anywhere in R.PLUGINS AFTER "chemistry" (this file reads R.chem at its first
-- tick, tolerates chemistry.lua not being loaded yet by retrying, but there's no reason to rely
-- on that retry path when a fixed order is free). Until landed, load with
-- PBX.state.rpg.reloadPlugin("reactions") (same convention every other new plugin this wave used).
--   R.PLUGINS = { ... , "chemistry", "reactions", "drawperf" }
-- ================================================================================================
