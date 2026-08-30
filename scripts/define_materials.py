"""Define custom elements from knowledge/materials-catalog.json (and power-elements json).

  python scripts/define_materials.py                 # define priority-1 entries up to the live cap
  python scripts/define_materials.py --priority 2    # include priority <= 2
  python scripts/define_materials.py --only GRNT SS16
  python scripts/define_materials.py --list          # show catalog vs live status
  python scripts/define_materials.py --swap OLD NEW  # delete OLD custom element, define NEW (slot reuse)
  python scripts/define_materials.py --pack gases --evict KERO LHE LH2 ...   # swap a whole pack in
Always (re)registers the behaviour kinds first (power_kinds.lua + material_kinds.lua) — they vanish on restart.
"""
import sys, json, argparse
sys.path.insert(0, "D:/powder-toy")
from powder_bridge.client import PowderClient
from powder_ext import element_tools as et

CATALOG = "D:/powder-toy/knowledge/materials-catalog.json"
PACKS = "D:/powder-toy/knowledge/materials-catalog-packs.json"
POWER = "D:/powder-toy/knowledge/power-elements-2026-08-26.json"
SECTION_BY_CAT = {"building": "SOLIDS", "insulation": "SOLIDS", "composite": "SOLIDS", "ceramic": "SOLIDS", "glass": "SOLIDS", "metal": "SOLIDS", "alloy": "SOLIDS",
                  "electronics": "ELEC", "semiconductor": "ELEC", "superconductor": "ELEC", "fluid": "LIQUID", "fuel": "LIQUID", "cryogen": "LIQUID", "gas": "GAS",
                  "storage": "POWERED", "nuclear": "NUCLEAR", "exotic": "NUCLEAR", "powder": "POWDERS"}
FIELDS = {"name", "group", "description", "colour", "menuSection", "type", "properties", "temperature", "highTemperature", "highTemperatureTransition",
          "lowTemperature", "lowTemperatureTransition", "hardness", "weight", "gravity", "diffusion", "flammable", "explosive", "heatConduct", "behavior"}


def register_kinds(c: PowderClient) -> None:
    for f in ("power_kinds.lua", "material_kinds.lua", "chem_kinds.lua"):
        r = c.execute_lua(open(f"D:/powder-toy/scripts/lua/{f}", encoding="utf-8").read())
        print(f, "->", r.get("result"))


def apply_heat_capacity(c: PowderClient, hc_map: dict[str, float]) -> dict:
    """Set HeatCapacity on already-live elements via elem.property (not a defineElement/
    updateElement schema field -- see research-material-mapping-2026-08-26.md S0.1/S1.7).
    Safe to call for elements that are not (yet) live: they just report ':missing'.
    """
    if not hc_map:
        return {"applied": 0, "failed": 0}
    lines = [
        'local function findId(n)',
        '  local i = elem["DEFAULT_PT_"..n]',
        '  if i then return i end',
        '  for j=0,511 do local ok,nm=pcall(elem.property,j,"Name"); if ok and nm==n then return j end end',
        '  return nil',
        'end',
        'local applied, failed = 0, {}',
    ]
    for name, val in hc_map.items():
        lines.append(
            f'do local i=findId({json.dumps(name)}); '
            f'if i then local ok=pcall(elem.property,i,"HeatCapacity",{val!r}); '
            f'if ok then applied=applied+1 else failed[#failed+1]={json.dumps(name)} end '
            f'else failed[#failed+1]={json.dumps(name)}..":missing" end end'
        )
    lines.append('return string.format("%d,%d,%s", applied, #failed, table.concat(failed, "|"))')
    res = c.execute_lua("\n".join(lines))
    raw = str(res.get("result") or "")
    parts = raw.split(",", 2)
    return {"applied": parts[0] if parts else None, "failed": parts[1] if len(parts) > 1 else None, "raw": raw}


def live() -> dict[str, dict]:
    res = et.HANDLERS["list_custom_elements"]({})
    return {e["name"]: e for e in (res.get("elements") or []) if isinstance(e, dict)}


def to_spec(e: dict) -> dict:
    spec = {k: v for k, v in e.items() if k in FIELDS}
    spec.setdefault("group", "MATL")
    sec = e.get("menuSection") or SECTION_BY_CAT.get(str(e.get("category", "")).lower().split("/")[0], "SOLIDS")
    spec["menuSection"] = sec
    if spec.get("type") == "GAS":
        spec["menuSection"] = "GAS"
    if spec.get("type") == "LIQUID":
        spec["menuSection"] = "LIQUID"
    if spec.get("type") == "PART":
        spec["menuSection"] = "POWDERS"
    spec["timeout_s"] = 6.0
    return spec


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--priority", type=int, default=1); ap.add_argument("--only", nargs="*"); ap.add_argument("--list", action="store_true")
    ap.add_argument("--swap", nargs=2, metavar=("OLD", "NEW")); ap.add_argument("--pack", help="define a whole pack from materials-catalog-packs.json"); ap.add_argument("--evict", nargs="*", help="custom elements to delete first to make room"); ap.add_argument("--catalog", default=CATALOG); ap.add_argument("--max", type=int, default=999)
    args = ap.parse_args()
    c = PowderClient()
    register_kinds(c)
    try:
        cat = json.load(open(args.catalog, encoding="utf-8"))["entries"]
    except FileNotFoundError:
        print("catalog not found:", args.catalog); return 1
    packs: dict = {}
    try:
        pk = json.load(open(PACKS, encoding="utf-8")); packs = pk.get("packs", {})
        known = {e["name"] for e in cat}
        cat += [e for e in pk.get("entries", []) if e["name"] not in known]
    except FileNotFoundError:
        pass
    if args.pack:
        if args.pack not in packs:
            print("unknown pack; available:", sorted(packs)); return 1
        args.only = list(packs[args.pack])
        if args.evict:
            curl = live()
            for old in args.evict:
                if old in curl:
                    print("delete", old, et.HANDLERS["delete_custom_element"]({"name": old, "timeout_s": 6.0}).get("ok"))
    cur = live()
    cap = c.execute_lua("return tostring(PBX.MAX_CUSTOM_ELEMENTS)").get("result")
    if args.list:
        for e in sorted(cat, key=lambda e: (e.get("priority", 9), e["name"])):
            print(f"{'LIVE ' if e['name'] in cur else '     '} p{e.get('priority','?')} {e['name']:<4} {e.get('category','')[:12]:<12} {e.get('description','')[:90]}")
        print(f"live custom: {len(cur)} / cap {cap}"); return 0
    if args.swap:
        old, new = args.swap
        if old in cur:
            print("delete", old, et.HANDLERS["delete_custom_element"]({"name": old, "timeout_s": 6.0}).get("ok"))
        args.only = [new]; cur = live()
    todo = [e for e in cat if (args.only and e["name"] in args.only) or (not args.only and int(e.get("priority", 9)) <= args.priority)]
    todo = [e for e in todo if e["name"] not in cur][: args.max]
    free = int(cap) - len(cur)
    if len(todo) > free:
        print(f"WARNING: {len(todo)} to define but only {free} free slots (cap {cap}); defining the first {free} by priority")
        todo = sorted(todo, key=lambda e: int(e.get("priority", 9)))[:free]
    ok_all = True
    for e in todo:
        res = et.HANDLERS["define_element"](to_spec(e))
        ok = bool(res.get("ok")); ok_all &= ok
        print(f"{e['name']:<4} {'OK ' if ok else 'ERR'} {res.get('status') or ''} {str(res.get('error') or res.get('errors') or '')[:140]}", flush=True)
    # post-define pass: HeatCapacity is not a defineElement/updateElement schema field (see
    # research-material-mapping-2026-08-26.md S0.1), so it is set separately here, for every
    # entry considered this run that is now live -- this re-applies on --swap/--pack too.
    live_now = live()
    hc_map = {e["name"]: e["heatCapacity"] for e in todo if "heatCapacity" in e and e["name"] in live_now}
    if hc_map:
        print("heatCapacity:", apply_heat_capacity(c, hc_map))
    print(f"live custom now: {len(live_now)} / cap {cap}")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
