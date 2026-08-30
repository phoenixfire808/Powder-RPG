local sym={BRCK="#",DSTW="~",WATR="w",GOO="g",DMND="D",PIPE="p",NSCN="n",METL="m",INSL="i",SHLD="S",TTAN="T",TUNG="W",GOLD="$",CNCT="c",PLUT="U",URAN="u",LCRY="L",VACU="V",WOOD="o",COAL="C",CLNE="K",PUMP="P",GLAS="G",BMTL="b",PLNT="'",DEUT="d",PRTI="I",PRTO="O",SPNG="s",PSCN="+",VOID="v",HSWC="h",GLOW="*",NTCT="t",PTCT="r",NEUT="N",PPIP="q",INST="=",SWCH="x",PSTN="[",FRME="]",WIFI="@",BTRY="B",DLAY="y",SPRK="z",CRAY="Y",PSNS="&",TSNS="%",ARAY="A",H2="h",LITH="l",LN2="2",WTRV="^",CRYE="e",RIME="f",ICE="_",HEAC="H",COOL="c",PLSM="!",FIRE="!",LAVA="L",PHOT=".",STNE=":",SAND=";",PQRT="Q",BCOL=",",BGLA="`",BRMT="b",INWR="-",SALT="s",FILT="F",PVOD="v",PCLN="Q",QRTZ="q",PBCN="k",IRON="m",DUST="."}
local g={}
for i in sim.parts() do local x,y=sim.partPosition(i); g[y*1000+x]=elem.property(sim.partProperty(i,"type"),"Name") end
local mf=io.open("D:/powder-toy/knowledge/scene-2026-08-25-fusion-test.map.txt","w")
mf:write("1px ASCII map, community save 'control-room + TTAN dome + LN2' captured 2026-08-25 (stamp 6a8e2c2c00). Row prefix=y, column0=x0. Legend: ")
local leg={} for k,v in pairs(sym) do leg[#leg+1]=v.."="..k end table.sort(leg) mf:write(table.concat(leg," ").."  |=wall ?=other\n")
for y=0,383 do local s=string.format("%3d ",y); for x=0,611 do local e=g[y*1000+x]; if e then s=s..(sym[e] or "?") else local w=tpt.get_wallmap(math.floor(x/4),math.floor(y/4)); s=s..((w and w~=0) and "|" or " ") end end; mf:write(s.."\n") end
mf:close()
local wn={} for cx=0,152 do for cy=0,95 do local w=tpt.get_wallmap(cx,cy); if w and w~=0 then wn[w]=(wn[w] or 0)+1 end end end
local o={} for k,v in pairs(wn) do o[#o+1]=k.."="..v end table.sort(o)
return "map regenerated; wall ids: "..table.concat(o,",")
