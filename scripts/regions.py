import sys, json
sys.path.insert(0, 'D:/powder-toy')
from powder_bridge.client import PowderClient
c = PowderClient()
T = "D:/powder-toy/scripts/lua/"
lua = open(T + "regions.lua", encoding="utf-8").read()
groups = {
 "A": [["reactor dome + LN2 cryo", 222, 346, 204, 346], ["laser bay PHOT/FILT/PCLN + DEUT lamp", 390, 462, 84, 110]],
 "B": [["LCRY digit displays + keypad", 176, 330, 28, 62], ["control logic row DLAY/BTRY/PSCN", 336, 478, 246, 262]],
 "C": [["INSL shaft + reactor top logic", 300, 400, 250, 300], ["west machine METL", 36, 100, 246, 306]],
 "D": [["WIFI bus (top-left)", 158, 240, 28, 52], ["bottom tank/pipe/valve bay", 224, 300, 292, 340]],
}
which = sys.argv[1] if len(sys.argv) > 1 else "A"
code = "local REGIONS=" + json.dumps(groups[which]).replace("[", "{").replace("]", "}") + "\n" + lua
print(c.execute_lua(code)['result'])
