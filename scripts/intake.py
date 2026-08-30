import sys, json
sys.path.insert(0, 'D:/powder-toy')
from powder_bridge.client import PowderClient

c = PowderClient()
T = "D:/powder-toy/scripts/lua/"
tag = sys.argv[1] if len(sys.argv) > 1 else "scene-2026-08-25"
print("STATE", c.get_simulation_state()['partCount'])
print(c.execute_lua(open(T + "census.lua", encoding="utf-8").read())['result'])
print("=====LOGIC")
print(c.execute_lua(open(T + "logic.lua", encoding="utf-8").read())['result'])
print("=====STAMP", c._post({"action": "saveStamp", "x": 0, "y": 0, "width": 611, "height": 383}))
print("=====MAP")
print(c.execute_lua(open(T + "dump.lua", encoding="utf-8").read().replace("SCENE_TAG", tag))['result'])
