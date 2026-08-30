-- Chemistry engine kind for custom elements (2026-08-26).
-- kinds.reactive: params.rules is a string of ';'-separated rules:
--   "WITH>SELF_BECOMES,OTHER_BECOMES:dT:chance[:needs][:extra][:conc=N][:pgas=X]"
--   WITH          neighbour element name that triggers the reaction (or ANY / HEAT<K> / AIR)
--   SELF_BECOMES  what this particle turns into (NONE = deleted, SELF = unchanged)
--   OTHER_BECOMES what the neighbour turns into (NONE = deleted, SELF = unchanged)
--   dT            temperature change applied to both (K, may be negative = endothermic)
--   chance        per-neighbour per-frame probability
--   needs         optional second neighbour element required within 8-neighbourhood (e.g. O2 for combustion)
--   extra         optional element spawned into a free neighbouring cell (e.g. H2, FIRE, SMKE, WTRV)
-- Examples: sodium "WATR>NONE,H2:+600:0.6::FIRE" ; quicklime "WATR>CAOH,NONE:+300:0.4" ; magnesium burn "FIRE>MGO,SELF:+900:0.5:O2:FIRE"
--
-- DSL EXTENSIONS (2026-08-26, research-material-mapping-2026-08-26.md S4). All three are additive
-- and fully backward compatible: every one of the pre-existing rule strings above still parses and
-- behaves identically, because each extension is either a brand-new optional trailing field or a
-- new, previously-unused '=' syntax inside an existing field.
--
--   1. Concentration via `life` -- append ':conc=N' anywhere after the 5th field. On a successful
--      hit, instead of immediately applying SELF_BECOMES, this decrements parts[i].life by N (life
--      starts at whatever DefaultProperties.life the element was given, typically 100 unless touched)
--      and scales this frame's chance by life/100 (a naturally-decaying reaction rate). SELF_BECOMES
--      is only actually applied once life reaches 0; OTHER_BECOMES/extra/pgas still fire every hit.
--      Example: "MG>WTRV,SELF:250:.3::OXYG:conc=20" -- H2O2 takes ~5 MG contacts to fully decompose
--      instead of vanishing on the first one.
--   2. Consumable second reactant -- the `needs` field's grammar extends from NEEDS_ELEM to
--      NEEDS_ELEM[=NEEDS_BECOMES] ('=' was previously illegal/unused inside a field, so this is
--      unambiguous). Omit the '=' and behavior is identical to before (needs only gates presence).
--      With it, the located needs-neighbour is itself transformed (NONE = killed) on a successful
--      hit -- genuine two-consumed-reactant stoichiometry. Example: "FIRE>STNE,SELF:900:.35:O2=NONE:FIRE"
--      (MG combustion) actually kills the O2 neighbour it burns, not just checks it's present.
--   3. Direct pressure yield -- append ':pgas=X' (float, may appear before or after :conc=N; both are
--      scanned for by prefix, not fixed position) anywhere after the 5th field. On a successful hit,
--      adds X directly to sim.pressure at the reacting cell -- for bulk-gas-evolution/overpressure
--      effects that would otherwise require spawning and waiting on many individual `extra` particles.
--      Example: "WATR>CLST,NONE:+60:0.5::GAS::pgas=8" (CaC2 + water) genuinely pressurizes a sealed
--      carbide-lamp/acetylene-generator vessel instead of relying only on spawned GAS particles.
local kinds = PBX.state.behaviors.kinds
local function elemId(name)
  if name == nil then return nil end
  name = string.upper(name)
  local id = elem["DEFAULT_PT_"..name]; if id then return id end
  for j=0,511 do local ok,n=pcall(elem.property,j,"Name"); if ok and n==name then return j end end
  return nil
end
local function occupant(nx, ny) if nx<0 or ny<0 or nx>=612 or ny>=384 then return nil end; local ok,o=pcall(sim.pmap,nx,ny); if ok and o and o~=0 then return o end; local ok2,p=pcall(sim.photons,nx,ny); if ok2 and p and p~=0 then return p end; return nil end
local N8 = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}}

local function parseRules(str)
  local rules = {}
  for rule in string.gmatch(str or "", "[^;]+") do
    local with, rest = rule:match("^%s*([%w_<>]+)%s*>(.*)$")
    if with then
      local f = {}
      do  -- split on ':' keeping empty fields (gmatch("[^:]*") yields spurious empties)
        local start = 1
        while true do
          local sep = string.find(rest, ":", start, true)
          if not sep then f[#f+1] = string.sub(rest, start); break end
          f[#f+1] = string.sub(rest, start, sep - 1); start = sep + 1
        end
      end
      local prod = f[1] or ""; local selfB, otherB = prod:match("^%s*([%w_]+)%s*,%s*([%w_]+)%s*$")
      local r = { with = string.upper(with), selfB = string.upper(selfB or "SELF"), otherB = string.upper(otherB or "SELF"),
                  dT = tonumber(f[2]) or 0, chance = tonumber(f[3]) or 0.2, needs = (f[4] and f[4] ~= "" and string.upper(f[4])) or nil, extra = (f[5] and f[5] ~= "" and string.upper(f[5])) or nil }
      local heatK = r.with:match("^HEAT(%d+)$"); if heatK then r.heatK = tonumber(heatK); r.with = "HEAT" end
      r.withId = (r.with ~= "ANY" and r.with ~= "HEAT" and r.with ~= "AIR") and elemId(r.with) or nil
      r.selfId = (r.selfB ~= "SELF" and r.selfB ~= "NONE") and elemId(r.selfB) or nil
      r.otherId = (r.otherB ~= "SELF" and r.otherB ~= "NONE") and elemId(r.otherB) or nil
      -- needs: HEAT<K> self-temperature gate, or ELEM, or ELEM=BECOMES (extension 2)
      local needsHeat = r.needs and r.needs:match("^HEAT(%d+)$")
      r.needsHeatK = needsHeat and tonumber(needsHeat) or nil
      if r.needs and not needsHeat then
        local ne, nb = r.needs:match("^([%w_]+)=([%w_]+)$")
        if ne then
          r.needsId = elemId(ne)
          r.needsBecomes = string.upper(nb)
          r.needsBecomesId = (r.needsBecomes ~= "NONE" and r.needsBecomes ~= "SELF") and elemId(r.needsBecomes) or nil
        else
          r.needsId = elemId(r.needs)
        end
      end
      r.extraId = r.extra and elemId(r.extra) or nil
      -- extensions 1 & 3: scan any trailing fields (position-independent) for conc=/pgas=
      for idx = 6, #f do
        local field = f[idx]
        if field and field ~= "" then
          local concN = field:match("^conc=([%d%.]+)$")
          local pgasX = field:match("^pgas=(%-?[%d%.]+)$")
          if concN then r.conc = tonumber(concN) end
          if pgasX then r.pgas = tonumber(pgasX) end
        end
      end
      rules[#rules+1] = r
    end
  end
  return rules
end

local function hasNeighbour(x, y, id)
  for _,d in ipairs(N8) do local o = occupant(x+d[1], y+d[2]); if o and sim.partProperty(o,"type") == id then return true end end
  return false
end
local function findNeighbour(x, y, id)
  for _,d in ipairs(N8) do local o = occupant(x+d[1], y+d[2]); if o and sim.partProperty(o,"type") == id then return o end end
  return nil
end
local function freeCell(x, y)
  for _,d in ipairs(N8) do local nx, ny = x+d[1], y+d[2]; if nx>=0 and ny>=0 and nx<612 and ny<384 and not occupant(nx, ny) then return nx, ny end end
  return nil
end

-- Extension 3: add pgas directly to the reacting cell's pressure. Best-effort/pcall-guarded since
-- sim.pressure's exact coordinate scaling isn't part of this file's contract; a failure here must
-- never break the rest of the reaction.
local function addPressure(x, y, amount)
  if not amount then return end
  local ok, cur = pcall(sim.pressure, x, y)
  if ok and cur then pcall(sim.pressure, x, y, cur + amount) end
end

-- Extension 2: consume/transform the located needs-neighbour (no-op unless r.needsBecomes is set).
local function consumeNeeds(x, y, r)
  if not (r.needsId and r.needsBecomes) then return end
  local nb = findNeighbour(x, y, r.needsId)
  if not nb then return end
  if r.needsBecomes == "NONE" then sim.partKill(nb)
  elseif r.needsBecomesId then sim.partProperty(nb, "type", r.needsBecomesId) end
  -- r.needsBecomes == "SELF" (or unresolved) leaves the neighbour unchanged, same as omitting '='.
end

kinds.reactive = {
  params = { rules = {type="string", min=0, max=2000, default=""} },
  make = function(params)
    local rules = parseRules(params and params.rules)
    local r_extra_done = false
    return function(i, x, y, ss, nt)
      local myT = sim.partProperty(i,"temp")
      for _,r in ipairs(rules) do
        if r.with == "HEAT" then
          if myT >= (r.heatK or 1e9) and math.random() < r.chance then
            if r.extraId then local fx, fy = freeCell(x, y); if fx then local n = sim.partCreate(-1, fx, fy, r.extraId); if n and n >= 0 then sim.partProperty(n,"temp", myT + r.dT) end end end
            addPressure(x, y, r.pgas)
            sim.partProperty(i,"temp", myT + r.dT)
            if r.conc then
              local life = (sim.partProperty(i,"life") or 100) - r.conc
              sim.partProperty(i,"life", math.max(0, life))
              if life > 0 then return false end
            end
            if r.selfB == "NONE" then sim.partKill(i); return true elseif r.selfId then sim.partProperty(i,"type", r.selfId); return false end
          end
        else
          local effChance = r.chance
          if r.conc then effChance = r.chance * ((sim.partProperty(i,"life") or 100) / 100) end
          for _,d in ipairs(N8) do
            local o = occupant(x+d[1], y+d[2])
            local hit = false
            if r.with == "AIR" then hit = (o == nil)
            elseif r.with == "ANY" then hit = (o ~= nil)
            elseif o and r.withId then hit = (sim.partProperty(o,"type") == r.withId) end
            if hit and math.random() < effChance and (not r.needsId or hasNeighbour(x, y, r.needsId)) and (not r.needsHeatK or myT >= r.needsHeatK) then
              local ot = o and sim.partProperty(o,"temp") or myT
              local ox_, oy_ = x+d[1], y+d[2]
              local otherFreed = false
              if o then
                if r.otherB == "NONE" and r.extraId and not freeCell(x, y) then
                  -- no free cell: turn the consumed neighbour straight into the product (kill+create in one frame fails)
                  sim.partProperty(o,"type", r.extraId); sim.partProperty(o,"temp", myT + r.dT); r_extra_done = true
                elseif r.otherB == "NONE" then sim.partKill(o); otherFreed = true
                elseif r.otherId then sim.partProperty(o,"type", r.otherId); sim.partProperty(o,"temp", ot + r.dT)
                else sim.partProperty(o,"temp", ot + r.dT) end
              end
              if r.extraId and not r_extra_done then
                local fx, fy = freeCell(x, y)
                if fx then local n = sim.partCreate(-1, fx, fy, r.extraId); if n and n >= 0 then sim.partProperty(n,"temp", myT + r.dT) end end
              end
              r_extra_done = false
              consumeNeeds(x, y, r)
              addPressure(x, y, r.pgas)
              sim.partProperty(i,"tmp2", (sim.partProperty(i,"tmp2") or 0) + 1)
              if r.conc then
                local life = (sim.partProperty(i,"life") or 100) - r.conc
                sim.partProperty(i,"life", math.max(0, life))
                if life > 0 then sim.partProperty(i,"temp", myT + r.dT); return false end
              end
              if r.selfB == "NONE" then sim.partKill(i); return true
              elseif r.selfId then sim.partProperty(i,"type", r.selfId); sim.partProperty(i,"temp", myT + r.dT); return false
              else sim.partProperty(i,"temp", myT + r.dT) end
              return false
            end
          end
        end
      end
      return false
    end
  end,
}
return "kinds registered: reactive"
