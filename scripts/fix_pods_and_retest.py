import sys, json, time, glob
sys.path.insert(0, "D:/powder-toy")
from powder_bridge.client import PowderClient
from powder_ext import blueprint_tools as bt, knowledge_tools as kt

c = PowderClient(); L = lambda s: c.execute_lua(s).get("result")
L("tpt.set_pause(1)")

# ---- 1) patch every registry module: sub-4px wall parts -> BRCK (walls are 4x4 cells) ----
fixed = []
for path in glob.glob("D:/powder-toy/knowledge/modules/*.json"):
    m = json.load(open(path, encoding="utf-8")); changed = False
    for p in m.get("parts", []):
        if "wall" in p:
            w, h = p.get("size", [1, 1])
            if isinstance(w, str) or isinstance(h, str):
                continue  # expression-sized wall (e.g. bore) — leave for the analyst
            if int(w) < 4 or int(h) < 4:
                p["box"] = "BRCK"; p.pop("wall"); changed = True
    if changed:
        m["why"] = m.get("why", "") + " [fix 2026-08-25: sub-4px 'wall' parts replaced by BRCK — walls are 4x4 cells and erase neighbours]"
        json.dump(m, open(path, "w", encoding="utf-8"), indent=1); fixed.append(path.split("\\")[-1].split("/")[-1])
print("modules de-walled:", fixed)

# ---- 2) rewrite injector_pod / drain_pod as jacketed, correct-channel designs ----
inj = {"name": "injector_pod", "description": "WIFI-triggered timed coolant injector (DLAY -> PSCN -> PUMP + 3x PCLN(DSTW)), INSL-jacketed",
 "why": "Community save 5170 pattern, hardened: WIFI in INSL jacket (channel temp boils coolant otherwise), BRCK not wall, PCLN row contacts the chamber below.",
 "source": "save 5170 (247,255)-(251,257); hardened 2026-08-25 after live test", "version": 2,
 "params": {"channel": 5, "delay_c": 98},
 "parts": [
  {"box": "INSL", "at": [0, 0], "size": [7, 3]},
  {"box": "WIFI", "at": [1, 1], "size": [2, 1], "props": {"channel": "channel"}},
  {"box": "PSCN", "at": [3, 1], "size": [1, 1]},
  {"box": "DLAY", "at": [4, 1], "size": [1, 1], "props": {"temp_c": "delay_c"}},
  {"box": "PSCN", "at": [5, 1], "size": [1, 1]},
  {"box": "BRCK", "at": [0, 3], "size": [7, 1]},
  {"box": "PSCN", "at": [5, 3], "size": [1, 1]},
  {"box": "PSCN", "at": [1, 4], "size": [5, 1]},
  {"box": "PUMP", "at": [0, 4], "size": [1, 1]},
  {"box": "BRCK", "at": [6, 4], "size": [1, 1]},
  {"box": "PCLN", "at": [1, 5], "size": [5, 1], "props": {"ctype": "DSTW"}},
  {"box": "BRCK", "at": [0, 5], "size": [1, 1]},
  {"box": "BRCK", "at": [6, 5], "size": [1, 1]}
 ], "verified": False}
drn = {"name": "drain_pod", "description": "WIFI-gated drain: WIFI -> PSCN -> PVOD row that eats liquid only while powered; INSL-jacketed",
 "why": "Community save 5170 drain pod, hardened: PVOD (powered) instead of always-on VOID, WIFI jacketed, BRCK not wall.",
 "source": "save 5170 (342,253); hardened 2026-08-25", "version": 2,
 "params": {"channel": 7},
 "parts": [
  {"box": "PVOD", "at": [1, 0], "size": [5, 1]},
  {"box": "BRCK", "at": [0, 0], "size": [1, 1]}, {"box": "BRCK", "at": [6, 0], "size": [1, 1]},
  {"box": "PSCN", "at": [1, 1], "size": [5, 1]},
  {"box": "BRCK", "at": [0, 1], "size": [1, 1]}, {"box": "BRCK", "at": [6, 1], "size": [1, 1]},
  {"box": "INSL", "at": [0, 2], "size": [7, 3]},
  {"box": "PSCN", "at": [3, 2], "size": [1, 1]},
  {"box": "WIFI", "at": [2, 3], "size": [3, 1], "props": {"channel": "channel"}}
 ], "verified": False}
for m in (inj, drn):
    json.dump(m, open(f"D:/powder-toy/knowledge/modules/{m['name']}.json", "w", encoding="utf-8"), indent=1)
    r = bt.compile_blueprint({"origin": [100, 100], "parts": [{"module": m["name"], "at": [0, 0]}]})
    print(m["name"], "compiles", r["ok"], r["errors"][:1])

# ---- 3) clean the two damaged spots (walls, LAVA, WTRV, SHLD growth) and repair jacket wall ----
for (x1, y1, x2, y2) in [(230, 186, 245, 196), (274, 250, 292, 261)]:
    c.place_wall_box("ERASE", x1=x1, y1=y1, x2=x2, y2=y2)
    L(f'for i in sim.parts() do local x,y=sim.partPosition(i) if x>={x1} and x<={x2} and y>={y1} and y<={y2} then local n=elem.property(sim.partProperty(i,"type"),"Name") if n~="TTAN" then sim.partKill(i) end end end')
# stray WTRV/LAVA/SHLD growth anywhere in the jacket
print("stray killed:", L('local k=0 for i in sim.parts() do local n=elem.property(sim.partProperty(i,"type"),"Name") if n=="WTRV" or n=="LAVA" or n=="SHD2" or n=="SHD3" or n=="SHD4" then sim.partKill(i) k=k+1 end end return k'))
# restore jacket walls at those spots and refill coolant
repair = {"origin": [0, 0], "parts": [
  {"box": "TTAN", "at": [225, 189], "size": [69, 3], "replace": False},
  {"box": "TTAN", "at": [225, 255], "size": [69, 3], "replace": False},
  {"box": "DSTW", "at": [228, 192], "size": [63, 63], "replace": False, "props": {"temp_c": 10}},
]}
print("repair", bt.blueprint_build({"blueprint": repair, "dry_run": False})["ok"])

# ---- 4) place hardened pods + fix lamp channel ----
place = {"origin": [0, 0], "parts": [
  {"id": "inj", "module": "injector_pod", "at": [246, 186], "params": {"channel": 6, "delay_c": 98}},
  {"id": "drn", "module": "drain_pod", "at": [270, 254], "params": {"channel": 7}},
  {"set": {"channel": 6}, "at": [304, 196], "size": [3, 3], "element": "WIFI"},
  {"set": {"channel": 7}, "at": [304, 216], "size": [3, 3], "element": "WIFI"},
]}
r = bt.blueprint_build({"blueprint": place, "dry_run": False})
print("place ok", r["ok"], r.get("failed"), [f["rule"] for f in r.get("lint", {}).get("findings", []) if f["severity"] == "critical"])
print("pod pixels:", L('local o={} for y=186,192 do local s="" for x=246,252 do local i=sim.partID(x,y) s=s..(i and elem.property(sim.partProperty(i,"type"),"Name"):sub(1,1) or ".") end o[#o+1]=y..":"..s end return table.concat(o," ")'))
print("drain pixels:", L('local o={} for y=254,258 do local s="" for x=270,276 do local i=sim.partID(x,y) s=s..(i and elem.property(sim.partProperty(i,"type"),"Name"):sub(1,1) or ".") end o[#o+1]=y..":"..s end return table.concat(o," ")'))

# ---- 5) signal trace ----
def px(x, y):
    return L(f'local i=sim.partID({x},{y}) if not i then return "empty" end return elem.property(sim.partProperty(i,"type"),"Name").."/"..sim.partProperty(i,"life")')
def count_dstw():
    return L('local n=0 for i in sim.parts() do local x,y=sim.partPosition(i) if x>=228 and x<=290 and y>=192 and y<=254 and sim.partProperty(i,"type")==elem.DEFAULT_PT_DSTW then n=n+1 end end return n')
def lamp_lit():
    return L('local n=0 for i in sim.parts() do local x,y=sim.partPosition(i) if x>=304 and x<=318 and y>=197 and y<=219 and sim.partProperty(i,"type")==elem.DEFAULT_PT_LCRY and sim.partProperty(i,"life")>0 then n=n+1 end end return n')
def tx(channel):
    L(f'local w=sim.partCreate(-1,400,60,elem.DEFAULT_PT_WIFI) sim.partProperty(w,"temp",{73.15+100*(channel-1)+50}) local p=sim.partCreate(-1,401,60,elem.DEFAULT_PT_PSCN) local b=sim.partCreate(-1,402,60,elem.DEFAULT_PT_BTRY) _G.PBX_TX={{w,p,b}}')
def untx():
    L('for _,i in ipairs(_G.PBX_TX or {}) do sim.partKill(i) end _G.PBX_TX=nil')
def frame(): L('tpt.set_pause(0) tpt.set_pause(1)')
print("baseline DSTW", count_dstw(), "lamp", lamp_lit())
tx(6)
for f in range(8):
    frame(); print(f"ch6 f{f+1}: podWIFI {px(247,187)} podPSCN {px(249,187)} DLAY {px(250,187)} PSCN {px(251,187)} feed {px(251,189)} row {px(251,190)} PUMP {px(246,190)} PCLN {px(247,191)} lampWIFI {px(305,198)} lampPSCN {px(305,199)} lit {lamp_lit()} DSTW {count_dstw()}")
untx()
L("tpt.set_pause(0)"); time.sleep(2.0); L("tpt.set_pause(1)")
print("after 100f free: DSTW", count_dstw(), "lamp", lamp_lit())
tx(7)
for f in range(6):
    frame(); print(f"ch7 f{f+1}: drnWIFI {px(272,257)} drnPSCN {px(273,256)} PSCNrow {px(271,255)} PVOD {px(271,254)} DSTW {count_dstw()}")
L("tpt.set_pause(0)"); time.sleep(2.0); L("tpt.set_pause(1)")
print("after 100f draining: DSTW", count_dstw())
untx()
print("walls now:", L('local n=0 for cx=0,152 do for cy=0,95 do if tpt.get_wallmap(cx,cy)~=0 then n=n+1 end end end return n'))
