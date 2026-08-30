local path="D:/powder-toy/knowledge/SCENE_TAG.parts.jsonl"
local f=io.open(path,"w")
f:write('{"meta":{"canvas":[612,384],"date":"2026-08-25","tag":"SCENE_TAG","fields":"t x y l(life) c(ctype) m(tmp) m2(tmp2) k(temp K) d(dcolour)"}}\n')
local n=0
for i in sim.parts() do
  local t=sim.partProperty(i,"type"); local x,y=sim.partPosition(i)
  local ct=sim.partProperty(i,"ctype"); local okc,nmc=pcall(elem.property,ct,"Name"); local ctn=(okc and nmc) or ct
  f:write(string.format('{"t":"%s","x":%d,"y":%d,"l":%d,"c":"%s","m":%d,"m2":%d,"k":%.1f,"d":%d}\n', elem.property(t,"Name"),x,y,sim.partProperty(i,"life"),tostring(ctn),sim.partProperty(i,"tmp"),sim.partProperty(i,"tmp2"),sim.partProperty(i,"temp"),sim.partProperty(i,"dcolour")))
  n=n+1
end
f:write('{"walls":[') local first=true
for cx=0,152 do for cy=0,95 do local w=tpt.get_wallmap(cx,cy); if w and w~=0 then f:write((first and "" or ",")..string.format("[%d,%d,%d]",cx,cy,w)); first=false end end end
f:write(']}\n{"pressure":[') first=true
for cx=0,152 do for cy=0,95 do local p=sim.pressure(cx,cy); if math.abs(p)>1 then f:write((first and "" or ",")..string.format("[%d,%d,%.0f]",cx,cy,p)); first=false end end end
f:write(']}\n') f:close()
local sym={BRCK="#",DSTW="~",WATR="w",GOO="g",DMND="D",PIPE="p",NSCN="n",METL="m",INSL="i",SHLD="S",TTAN="T",TUNG="W",GOLD="$",CNCT="c",PLUT="U",URAN="u",LCRY="L",VACU="V",WOOD="o",COAL="C",CLNE="K",PUMP="P",GLAS="G",BMTL="b",PLNT="'",DEUT="d",PRTI="I",PRTO="O",SPNG="s",PSCN="+",VOID="v",HSWC="h",GLOW="*",NTCT="t",PTCT="r",NEUT="N",PPIP="q",INST="=",SWCH="x",PSTN="[",FRME="]",WIFI="@",BTRY="B",DLAY="y",SPRK="z",CRAY="Y",PSNS="&",TSNS="%",ARAY="A",H2="h",LITH="l",LN2="2",WTRV="^",CRYE="e",RIME="f",ICE="_",HEAC="H",COOL="c",PLSM="!",FIRE="!",LAVA="L",PHOT="."}
local g={}
for i in sim.parts() do local x,y=sim.partPosition(i); g[y*1000+x]=elem.property(sim.partProperty(i,"type"),"Name") end
local mf=io.open("D:/powder-toy/knowledge/SCENE_TAG.map.txt","w")
mf:write("1px ASCII map SCENE_TAG 2026-08-25. Row prefix=y, column0=x0. Legend: ")
local leg={} for k,v in pairs(sym) do leg[#leg+1]=v.."="..k end table.sort(leg) mf:write(table.concat(leg," ").."  |=wall ?=other\n")
for y=0,383 do local s=string.format("%3d ",y); for x=0,611 do local e=g[y*1000+x]; if e then s=s..(sym[e] or "?") else local w=tpt.get_wallmap(math.floor(x/4),math.floor(y/4)); s=s..((w and w~=0) and "|" or " ") end end; mf:write(s.."\n") end
mf:close()
local grid={}
for cy=0,95 do grid[cy]={} for cx=0,152 do grid[cy][cx]={} end end
for i in sim.parts() do local x,y=sim.partPosition(i); local cx,cy=math.floor(x/4),math.floor(y/4); local nm=elem.property(sim.partProperty(i,"type"),"Name"); local gg=grid[cy][cx]; gg[nm]=(gg[nm] or 0)+1 end
local lines={}
for cy=0,95 do local s=string.format("%3d ",cy*4)
 for cx=0,152 do local gg=grid[cy][cx]; local best,bn=nil,0; for k,v in pairs(gg) do if v>bn then best,bn=k,v end end
  local w=tpt.get_wallmap(cx,cy)
  if best then s=s..(sym[best] or "?") elseif w and w~=0 then s=s.."|" else s=s.." " end end
 lines[#lines+1]=s end
return "wrote "..n.." particles\n"..table.concat(lines,"\n")
