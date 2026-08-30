local out={}
local function info(name,fields,maxn)
  local t=elem["DEFAULT_PT_"..name]; if not t then return end
  local c=0
  for i in sim.parts() do if sim.partProperty(i,"type")==t then
    local x,y=sim.partPosition(i); local s=name.."@"..x..","..y
    for _,f in ipairs(fields) do local v=sim.partProperty(i,f); if f=="ctype" then local okp,nm=pcall(elem.property,v,"Name"); v=(okp and nm) or v elseif f=="temp" then v=string.format("%.0fC",v-273.15) end; s=s.." "..f.."="..tostring(v) end
    out[#out+1]=s; c=c+1; if c>=maxn then break end end end
end
info("WIFI",{"temp","tmp"},20) info("PRTO",{"temp","tmp"},12) info("PRTI",{"temp","tmp"},12)
info("PSTN",{"temp","tmp","tmp2","life"},6) info("SWCH",{"life","temp"},12) info("DLAY",{"temp","life"},10)
info("BTRY",{},6) info("TSNS",{"temp","tmp","tmp2"},6) info("PSNS",{"temp","tmp","tmp2"},6) info("ARAY",{},6)
info("CRAY",{"ctype","tmp"},8) info("PPIP",{"ctype","tmp"},6) info("HEAC",{"temp"},6) info("COOL",{"temp"},6)
info("GRAV",{},4) info("FILT",{"ctype","tmp"},6) info("CONV",{"ctype","tmp"},6) info("DTEC",{"ctype","tmp"},6)
info("LDTC",{"ctype","tmp"},6) info("PCLN",{"ctype","temp"},6) info("EMP",{},2) info("LIGH",{},2)
local cc={}; for i in sim.parts() do local t=sim.partProperty(i,"type") if t==elem.DEFAULT_PT_CLNE or t==elem.DEFAULT_PT_PCLN or t==elem.DEFAULT_PT_BCLN then local okp,ct=pcall(elem.property,sim.partProperty(i,"ctype"),"Name"); ct=(okp and ct) or "?"; cc[ct]=(cc[ct] or 0)+1 end end
local s="CLNE-family ctypes:" for k,v in pairs(cc) do s=s.." "..k.."="..v end out[#out+1]=s
local dl,dn,dmax=0,0,0
for i in sim.parts() do if sim.partProperty(i,"type")==elem.DEFAULT_PT_DEUT then local l=sim.partProperty(i,"life"); dl=dl+l; dn=dn+1; if l>dmax then dmax=l end end end
out[#out+1]=string.format("DEUT n=%d sum life=%d avg=%.0f max=%d",dn,dl,dl/math.max(dn,1),dmax)
return table.concat(out,"\n")
