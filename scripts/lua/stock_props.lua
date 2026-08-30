local names = {"METL","GOLD","TUNG","TTAN","IRON","GLAS","BRCK","CNCT","STNE","WOOD","COAL","SALT","LITH","MERC","ICE","WATR","OIL","DESL","BMTL","BRMT","QRTZ","PLNT","WAX","PLUT","URAN","INSL","DMND","SAND","CLST","BGLA","BCOL","PQRT","SLTW","SNOW","GEL","RBDM","NBLE","H2","O2","N2","CO2"}
local out = {}
for _, n in ipairs(names) do
  local id = elem["DEFAULT_PT_" .. n]
  if id then
    local function p(k) local ok, v = pcall(elem.property, id, k); if ok then return tostring(v) end; return "?" end
    out[#out + 1] = string.format('{"n":"%s","id":%d,"hi":%s,"hiT":%s,"lo":%s,"loT":%s,"hc":%s,"fl":%s,"hard":%s,"w":%s}',
      n, id, p("HighTemperature"), p("HighTemperatureTransition"), p("LowTemperature"), p("LowTemperatureTransition"), p("HeatConduct"), p("Flammable"), p("Hardness"), p("Weight"))
  end
end
return "[" .. table.concat(out, ",") .. "]"
