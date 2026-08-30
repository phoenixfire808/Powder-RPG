local counts,bb,tsum,tmax,tmin={}, {}, {}, {}, {}
local n=0
for i in sim.parts() do
  local t=sim.partProperty(i,"type"); local nm=elem.property(t,"Name") or tostring(t)
  local x,y=sim.partPosition(i); local tp=sim.partProperty(i,"temp")
  counts[nm]=(counts[nm] or 0)+1
  local b=bb[nm]; if not b then bb[nm]={x,y,x,y} else if x<b[1] then b[1]=x end; if y<b[2] then b[2]=y end; if x>b[3] then b[3]=x end; if y>b[4] then b[4]=y end end
  tsum[nm]=(tsum[nm] or 0)+tp; if not tmax[nm] or tp>tmax[nm] then tmax[nm]=tp end; if not tmin[nm] or tp<tmin[nm] then tmin[nm]=tp end
  n=n+1
end
local rows={}
for k,v in pairs(counts) do local b=bb[k]; rows[#rows+1]=string.format("%s n=%d box=(%d,%d)-(%d,%d) Tavg=%.0f Tmin=%.0f Tmax=%.0f",k,v,b[1],b[2],b[3],b[4],tsum[k]/v-273.15,tmin[k]-273.15,tmax[k]-273.15) end
table.sort(rows,function(a,b) return tonumber(a:match("n=(%d+)"))>tonumber(b:match("n=(%d+)")) end)
local walls={} for cx=0,152 do for cy=0,95 do local w=tpt.get_wallmap(cx,cy); if w and w~=0 then walls[w]=(walls[w] or 0)+1 end end end
local wr={} for k,v in pairs(walls) do wr[#wr+1]=k..":"..v end
local pmin,pmax,pminc,pmaxc=0,0,"",""
for cx=0,152 do for cy=0,95 do local p=sim.pressure(cx,cy); if p<pmin then pmin=p pminc=cx*4 ..","..cy*4 end; if p>pmax then pmax=p pmaxc=cx*4 ..","..cy*4 end end end
local amin,amax,aminc,amaxc=1e9,-1e9,"",""
for cx=0,152 do for cy=0,95 do local a=sim.ambientHeat and sim.ambientHeat(cx,cy) or 295.15; if a<amin then amin=a aminc=cx*4 ..","..cy*4 end; if a>amax then amax=a amaxc=cx*4 ..","..cy*4 end end end
local extra=""
if sim.gravityMode then extra=extra.." gravMode="..tostring(sim.gravityMode()) end
if sim.ambientHeatSim then extra=extra.." ambientHeat="..tostring(sim.ambientHeatSim()) end
if sim.edgeMode then extra=extra.." edgeMode="..tostring(sim.edgeMode()) end
return "total="..n.." walls{"..table.concat(wr,",").."}"..string.format(" P[%.0f@%s .. %.0f@%s] Air[%.0fC@%s .. %.0fC@%s]",pmin,pminc,pmax,pmaxc,amin-273,aminc,amax-273,amaxc)..extra.."\n"..table.concat(rows,"\n")
