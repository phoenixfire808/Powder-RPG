local sym={BRCK="#",DSTW="~",WATR="w",GOO="g",DMND="D",PIPE="p",NSCN="n",METL="m",INSL="i",SHLD="S",TTAN="T",TUNG="W",GOLD="$",CNCT="c",PLUT="U",URAN="u",LCRY="L",VACU="V",WOOD="o",COAL="C",CLNE="K",PUMP="P",GLAS="G",BMTL="b",PLNT="'",DEUT="d",PRTI="I",PRTO="O",SPNG="s",PSCN="+",VOID="v",HSWC="h",GLOW="*",NTCT="t",PTCT="r",NEUT="N",PPIP="q",INST="=",SWCH="x",PSTN="[",FRME="]",WIFI="@",BTRY="B",DLAY="y",SPRK="z",CRAY="Y",PSNS="&",TSNS="%",ARAY="A",H2="h",LITH="l",LN2="2",WTRV="^",CRYE="e",RIME="f",ICE="_",HEAC="H",COOL="c",PLSM="!",FIRE="!",LAVA="L",PHOT=".",STNE=":",SAND=";",PQRT="Q",BCOL=",",BGLA="`",BRMT="b",INWR="-",SALT="s",FILT="F",PVOD="v",PCLN="Q",QRTZ="q",PBCN="k",IRON="m",DUST="."}
local function map(x1,x2,y1,y2)
 local g={}
 for i in sim.parts() do local x,y=sim.partPosition(i); if x>=x1 and x<=x2 and y>=y1 and y<=y2 then g[y*1000+x]=elem.property(sim.partProperty(i,"type"),"Name") end end
 local L={}
 for y=y1,y2 do local s=string.format("%3d ",y); for x=x1,x2 do local e=g[y*1000+x]; if e then s=s..(sym[e] or "?") else local w=tpt.get_wallmap(math.floor(x/4),math.floor(y/4)); s=s..((w and w~=0) and "|" or " ") end end; L[#L+1]=s end
 return table.concat(L,"\n")
end
local out={}
for _,r in ipairs(REGIONS) do out[#out+1]="== "..r[1].." x"..r[2].."-"..r[3].." y"..r[4].."-"..r[5].."\n"..map(r[2],r[3],r[4],r[5]) end
return table.concat(out,"\n\n")
