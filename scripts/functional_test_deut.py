"""Functional test of the owner's DEUT reactor upgrade (2026-08-25). Runs the sim in
short unpause windows (bridge step(n) is broken until restart) and measures."""
import sys, time, json
sys.path.insert(0, "D:/powder-toy")
from powder_bridge.client import PowderClient

c = PowderClient()
L = lambda code: c.execute_lua(code).get("result")

def run(seconds):
    L("tpt.set_pause(0)"); time.sleep(seconds); L("tpt.set_pause(1)")

MEASURE = r'''
local function box(x1,y1,x2,y2,name)
  local n,tsum,tmax=0,0,-1e9
  for i in sim.parts() do local x,y=sim.partPosition(i)
    if x>=x1 and x<=x2 and y>=y1 and y<=y2 then local nm=elem.property(sim.partProperty(i,"type"),"Name")
      if nm==name then n=n+1 local t=sim.partProperty(i,"temp") tsum=tsum+t if t>tmax then tmax=t end end end end
  return n,(n>0 and tsum/n-273.15 or 0),tmax-273.15
end
local o={}
local n,ta,tm=box(228,192,290,254,"DSTW") o[#o+1]=string.format("jacket DSTW n=%d Tavg=%.1f Tmax=%.1f",n,ta,tm)
local n2=0 for i in sim.parts() do local x,y=sim.partPosition(i) local nm=elem.property(sim.partProperty(i,"type"),"Name") if nm=="DSTW" and not (x>=228 and x<=290 and y>=192 and y<=254) and not (x>=205 and x<=344 and y>=294 and y<=321) and not (x>=236 and x<=283 and y>=258 and y<=293) then n2=n2+1 end end
o[#o+1]="DSTW outside jacket/reservoir/risers="..n2
local dn,dl,dmax=0,0,0 for i in sim.parts() do if sim.partProperty(i,"type")==elem.DEFAULT_PT_DEUT then dn=dn+1 local l=sim.partProperty(i,"life") dl=dl+l if l>dmax then dmax=l end end end
o[#o+1]=string.format("DEUT n=%d sumlife=%d max=%d",dn,dl,dmax)
local nn=0 for i in sim.parts() do if sim.partProperty(i,"type")==elem.DEFAULT_PT_NEUT then nn=nn+1 end end o[#o+1]="NEUT="..nn
local n,ta,tm=box(239,203,279,243,"TTAN") o[#o+1]=string.format("vessel TTAN n=%d Tmax=%.0f",n,tm)
local n,ta,tm=box(225,189,293,257,"TTAN") o[#o+1]=string.format("jacket TTAN n=%d",n)
local lit=0 for i in sim.parts() do local x,y=sim.partPosition(i) if x>=304 and x<=318 and y>=197 and y<=219 and sim.partProperty(i,"type")==elem.DEFAULT_PT_LCRY and sim.partProperty(i,"life")>0 then lit=lit+1 end end o[#o+1]="lamp lit px="..lit
local cn=0 for i in sim.parts() do if sim.partProperty(i,"type")==elem.DEFAULT_PT_CLNE then cn=cn+1 end end o[#o+1]="CLNE="..cn
return table.concat(o," | ")
'''

def pulse(channel, x, y):
    # temporary transmitter: WIFI on `channel` with a PSCN neighbour that we spark for one frame
    L(f'''local w=sim.partCreate(-1,{x},{y},elem.DEFAULT_PT_WIFI) sim.partProperty(w,"temp",{73.15+100*(channel-1)+50})
local p=sim.partCreate(-1,{x+1},{y},elem.DEFAULT_PT_PSCN) sim.partProperty(p,"type",elem.DEFAULT_PT_SPRK) sim.partProperty(p,"ctype",elem.DEFAULT_PT_PSCN) sim.partProperty(p,"life",4) _G.PBX_TX={{w,p}}''')
    run(0.15)
    L('for _,i in ipairs(_G.PBX_TX or {}) do sim.partKill(i) end _G.PBX_TX=nil')

log = []
def m(tag):
    r = L(MEASURE); print(tag, "|", r, flush=True); log.append((tag, r))

L("tpt.set_pause(1)")
m("t0 paused")
run(3.0); m("after ~150 frames idle")
run(3.0); m("after ~300 frames idle")
pulse(6, 400, 60); m("ch6 pulsed (inject)")
run(1.0); m("+50f")
run(2.0); m("+150f")
pulse(7, 400, 60); m("ch7 pulsed (drain)")
run(2.0); m("+100f")
run(2.0); m("+200f")
pulse(10, 400, 60); m("ch10 pulsed (NEUT trigger)")
for k in range(4):
    run(1.0); m(f"+{50*(k+1)}f after trigger")
json.dump(log, open("D:/powder-toy/knowledge/drew-deut-reactor-2026-08-25.test.json", "w"), indent=1)
