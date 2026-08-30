-- Extra behaviour kinds for the realistic power-generation element set (2026-08-26).
-- Registered live into PBX.state.behaviors.kinds via execute_lua; contract mirrors 20_behaviors.lua:
-- kinds[name] = { params = SPEC, make = function(params) return function(i,x,y,ss,nt) ... return bool end end }
local kinds = PBX.state.behaviors.kinds
local function pget(params, k, spec) local v = params and params[k]; if v == nil then return spec.default end; return v end
local function elemId(name) local id = elem["DEFAULT_PT_"..name]; if id then return id end; for j=0,511 do local ok,n=pcall(elem.property,j,"Name"); if ok and n==name then return j end end; return nil end
local function occupant(nx, ny) if nx<0 or ny<0 or nx>=612 or ny>=384 then return nil end; local ok,o=pcall(sim.pmap,nx,ny); if not ok or not o or o==0 then local ok2,p=pcall(sim.photons,nx,ny); if ok2 and p and p~=0 then return p end; return nil end; return o end
local N8 = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}}

-- absorber: eats a given energy element (default NEUT) in the 8-neighbourhood with probability `chance`,
-- gaining `heatPerHit` K per absorption (B4C control rods, boron shielding, poison injection).
kinds.absorber = {
  params = { absorbs = {type="string", min=0, max=32, default="NEUT"}, chance = {type="num", min=0, max=1, default=0.9}, heatPerHit = {type="num", min=0, max=100, default=4} },
  make = function(params)
    local target = elemId(string.upper(tostring(pget(params,"absorbs",kinds.absorber.params.absorbs))))
    local chance = pget(params,"chance",kinds.absorber.params.chance); local heat = pget(params,"heatPerHit",kinds.absorber.params.heatPerHit)
    return function(i, x, y, ss, nt)
      if not target then return false end
      local hits = 0
      for _,d in ipairs(N8) do
        local o = occupant(x+d[1], y+d[2])
        if o and sim.partProperty(o,"type") == target and math.random() < chance then sim.partKill(o); hits = hits + 1 end
      end
      if hits > 0 then sim.partProperty(i,"temp", sim.partProperty(i,"temp") + heat*hits); sim.partProperty(i,"tmp", (sim.partProperty(i,"tmp") or 0) + hits) end
      return false
    end
  end,
}

-- turbine: converts adjacent `input` (steam) into `output` (condensate) with `chance` per neighbour per frame
-- and, for every conversion, sparks adjacent conductors (PSCN/NSCN/METL/INWR/INST) = mechanical->electrical.
kinds.turbine = {
  params = { input = {type="string", min=0, max=32, default="WTRV"}, output = {type="string", min=0, max=32, default="DSTW"}, chance = {type="num", min=0, max=1, default=0.25}, cool = {type="num", min=0, max=500, default=60} },
  make = function(params)
    local inp = elemId(string.upper(tostring(pget(params,"input",kinds.turbine.params.input))))
    local outp = elemId(string.upper(tostring(pget(params,"output",kinds.turbine.params.output))))
    local chance = pget(params,"chance",kinds.turbine.params.chance); local cool = pget(params,"cool",kinds.turbine.params.cool)
    local sprk = elemId("SPRK"); local conductors = {}
    for _,n in ipairs({"PSCN","NSCN","METL","INWR","INST","CU","STEL"}) do local id = elemId(n); if id then conductors[id] = true end end
    return function(i, x, y, ss, nt)
      if not inp or not outp then return false end
      local work = 0
      for _,d in ipairs(N8) do
        local o = occupant(x+d[1], y+d[2])
        if o and sim.partProperty(o,"type") == inp and math.random() < chance then
          sim.partProperty(o,"type", outp); sim.partProperty(o,"temp", math.max(273.15+20, sim.partProperty(o,"temp") - cool)); work = work + 1
        end
      end
      if work > 0 then
        sim.partProperty(i,"tmp", (sim.partProperty(i,"tmp") or 0) + work)  -- tmp = cumulative work counter (readable output)
        for _,d in ipairs(N8) do
          local o = occupant(x+d[1], y+d[2])
          if o then local t = sim.partProperty(o,"type"); if conductors[t] and sim.partProperty(o,"life") == 0 then sim.partProperty(o,"ctype", t); sim.partProperty(o,"type", sprk); sim.partProperty(o,"life", 4) end end
        end
      end
      return false
    end
  end,
}

-- teg: thermoelectric generator. When its own temperature exceeds `onTemp` (K) it sparks adjacent conductors
-- every `period` frames and sheds `drop` K per pulse (Seebeck conversion of a temperature difference).
kinds.teg = {
  params = { onTemp = {type="num", min=0, max=9999, default=373.15}, period = {type="int", min=1, max=1000, default=20}, drop = {type="num", min=0, max=100, default=2} },
  make = function(params)
    local onT = pget(params,"onTemp",kinds.teg.params.onTemp); local period = pget(params,"period",kinds.teg.params.period); local drop = pget(params,"drop",kinds.teg.params.drop)
    local sprk = elemId("SPRK"); local conductors = {}
    for _,n in ipairs({"PSCN","NSCN","METL","INWR","INST","CU","STEL"}) do local id = elemId(n); if id then conductors[id] = true end end
    return function(i, x, y, ss, nt)
      local t = sim.partProperty(i,"temp")
      if t < onT then return false end
      local life = (sim.partProperty(i,"life") or 0) + 1
      if life < period then sim.partProperty(i,"life", life); return false end
      sim.partProperty(i,"life", 0); sim.partProperty(i,"temp", t - drop)
      for _,d in ipairs(N8) do
        local o = occupant(x+d[1], y+d[2])
        if o then local ty = sim.partProperty(o,"type"); if conductors[ty] and sim.partProperty(o,"life") == 0 then sim.partProperty(o,"ctype", ty); sim.partProperty(o,"type", sprk); sim.partProperty(o,"life", 4) end end
      end
      return false
    end
  end,
}
return "kinds registered: absorber, turbine, teg"
