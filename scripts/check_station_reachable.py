"""Check that every crafting station is reachable end-to-end.

Two real bugs this session were the same shape: a new station (research,
advlab) got added to R.STATIONS but a SIBLING table that also needs an
entry per station wasn't updated -- round 6 was ui.lua's hardcoded tab
order (recipes for that station were never drawn/clickable), round 7 was
R.ITEMS (the station kit was uncraftable-and-placeable: it vanished from
inventory with nothing appearing). This checks the two live, queryable
invariants: every non-"hand" station has an R.ITEMS placement entry, and
every station is used by at least one real recipe.

(The ui.lua hardcoded order list from round 6 isn't checked here -- it's a
local variable inside a function, not exposed on R, so it can't be queried
live without editing ui.lua itself. Out of scope for a read-only checker.)

Usage: python check_station_reachable.py
"""
import sys

from _mcp_bridge import call_bridge

LUA = """
local r = PBX.state.rpg
local stations, items, usedByRecipe = {}, {}, {}
for k in pairs(r.STATIONS) do stations[#stations+1] = k end
for k in pairs(r.ITEMS) do items[k] = true end
for _, rec in ipairs(r.RECIPES) do if rec.st then usedByRecipe[rec.st] = true end end
local out = {}
for _, s in ipairs(stations) do
  local hasItem = (s == "hand") or items[s:upper()] or false
  local hasRecipe = usedByRecipe[s] or false
  out[#out+1] = s .. ":item=" .. tostring(hasItem) .. ",recipe=" .. tostring(hasRecipe)
end
return table.concat(out, " ")
"""


def query() -> str:
    return call_bridge(LUA)


def main() -> int:
    ok = True
    for entry in query().split():
        station, flags = entry.split(":")
        has_item = "item=true" in flags
        has_recipe = "recipe=true" in flags
        status = "OK" if (has_item and has_recipe) else "UNREACHABLE"
        print(f"{station}: {status} ({flags})")
        if status == "UNREACHABLE":
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
