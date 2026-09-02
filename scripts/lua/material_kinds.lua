-- Behaviour kinds for the realistic materials catalog (2026-08-26): photovoltaic, piezo, pcm.
local kinds = PBX.state.behaviors.kinds
local function pget(params, k, spec) local v = params and params[k]; if v == nil then return spec.default end; return v end
local function elemId(name) local id = elem["DEFAULT_PT_"..name]; if id then return id end; for j=0,(2 ^ ((sim and sim.PMAPBITS) or 9)) - 1 do local ok,n=pcall(elem.property,j,"Name"); if ok and n==name then return j end end; return nil end
local function occupant(nx, ny) if nx<0 or ny<0 or nx>=612 or ny>=384 then return nil end; local ok,o=pcall(sim.pmap,nx,ny); if ok and o and o~=0 then return o end; local ok2,p=pcall(sim.photons,nx,ny); if ok2 and p and p~=0 then return p end; return nil end
local N8 = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}}
local sprk = elemId("SPRK")
local function conductorSet() local t = {}; for _,n in ipairs({"PSCN","NSCN","METL","INWR","INST","CU","STEL","ALU","SS16","GRFN"}) do local id = elemId(n); if id then t[id] = true end end; return t end
local function sparkNeighbours(x, y, conductors)
  for _,d in ipairs(N8) do
    local o = occupant(x+d[1], y+d[2])
    if o then local ty = sim.partProperty(o,"type"); if conductors[ty] and sim.partProperty(o,"life") == 0 then sim.partProperty(o,"ctype", ty); sim.partProperty(o,"type", sprk); sim.partProperty(o,"life", 4) end end
  end
end

-- photovoltaic: absorbs adjacent PHOT with `chance`; every `perSpark` photons absorbed -> one SPRK pulse into touching conductors.
kinds.photovoltaic = {
  params = { chance = {type="num", min=0, max=1, default=0.8}, perSpark = {type="int", min=1, max=100, default=3}, heat = {type="num", min=0, max=50, default=0.5} },
  make = function(params)
    local chance = pget(params,"chance",kinds.photovoltaic.params.chance); local per = pget(params,"perSpark",kinds.photovoltaic.params.perSpark); local heat = pget(params,"heat",kinds.photovoltaic.params.heat)
    local phot = elemId("PHOT"); local conductors = conductorSet()
    return function(i, x, y, ss, nt)
      local got = 0
      for _,d in ipairs(N8) do local o = occupant(x+d[1], y+d[2]); if o and sim.partProperty(o,"type") == phot and math.random() < chance then sim.partKill(o); got = got + 1 end end
      if got > 0 then
        sim.partProperty(i,"temp", sim.partProperty(i,"temp") + heat*got)
        local acc = (sim.partProperty(i,"tmp") or 0) + got; sim.partProperty(i,"tmp2", (sim.partProperty(i,"tmp2") or 0) + got)
        if acc >= per then acc = acc - per; sparkNeighbours(x, y, conductors) end
        sim.partProperty(i,"tmp", acc)
      end
      return false
    end
  end,
}

-- piezo: when local pressure magnitude exceeds `threshold`, emit one SPRK pulse per `period` frames (tmp2 = pulses).
kinds.piezo = {
  params = { threshold = {type="num", min=0, max=256, default=4}, period = {type="int", min=1, max=1000, default=2} },
  make = function(params)
    local thr = pget(params,"threshold",kinds.piezo.params.threshold); local period = pget(params,"period",kinds.piezo.params.period)
    local conductors = conductorSet()
    return function(i, x, y, ss, nt)
      local p = sim.pressure(math.floor(x/4), math.floor(y/4))
      if math.abs(p) < thr then return false end
      local life = (sim.partProperty(i,"life") or 0) + 1
      if life < period then sim.partProperty(i,"life", life); return false end
      sim.partProperty(i,"life", 0); sim.partProperty(i,"tmp2", (sim.partProperty(i,"tmp2") or 0) + 1)
      sparkNeighbours(x, y, conductors)
      return false
    end
  end,
}

-- pcm: phase-change heat buffer. Above meltK it soaks heat (stores up to `latent` K-units in tmp, holding its temp at meltK);
-- below meltK it releases stored heat back (temp held at meltK until tmp is empty). Approximates latent heat.
kinds.pcm = {
  params = { meltK = {type="num", min=100, max=2000, default=331.15}, latent = {type="int", min=1, max=100000, default=2000}, rate = {type="num", min=0.1, max=50, default=4} },
  make = function(params)
    local meltK = pget(params,"meltK",kinds.pcm.params.meltK); local latent = pget(params,"latent",kinds.pcm.params.latent); local rate = pget(params,"rate",kinds.pcm.params.rate)
    return function(i, x, y, ss, nt)
      local t = sim.partProperty(i,"temp"); local stored = sim.partProperty(i,"tmp") or 0
      if t > meltK and stored < latent then
        local take = math.min(rate, t - meltK, latent - stored); sim.partProperty(i,"temp", t - take); sim.partProperty(i,"tmp", stored + take)
      elseif t < meltK and stored > 0 then
        local give = math.min(rate, meltK - t, stored); sim.partProperty(i,"temp", t + give); sim.partProperty(i,"tmp", stored - give)
      end
      return false
    end
  end,
}
return "kinds registered: photovoltaic, piezo, pcm"
