"""Define the realistic power-generation element set (2026-08-26).

Real-world numbers mapped to TPT: melting points -> highTemperature (K) transitions, thermal
conductivity -> heatConduct (0-255, CU=251 reference for ~400 W/mK), electrical conductivity
-> PROP_CONDUCTS, neutron transparency -> PROP_NEUTPENETRATE, custom Lua behaviours
(absorber / turbine / teg from scripts/lua/power_kinds.lua) for the physics TPT lacks.
Run: python scripts/define_power_elements.py [--only NAME ...]
"""
import sys, json, argparse
sys.path.insert(0, "D:/powder-toy")
from powder_bridge.client import PowderClient
from powder_ext import element_tools as et

K = lambda c: round(c + 273.15, 2)
SECTIONS = {'UO2': 'NUCLEAR', 'ZIRC': 'SOLIDS', 'GRPH': 'SOLIDS', 'B4C': 'NUCLEAR', 'CU': 'ELEC', 'STEL': 'SOLIDS', 'CNCR': 'SOLIDS', 'LEAD': 'SOLIDS', 'NAK': 'LIQUID', 'AERO': 'SOLIDS', 'TRBN': 'POWERED', 'TEG': 'POWERED', 'LEDL': 'POWERED'}
ELEMENTS = [
 dict(name="UO2", description="Uranium dioxide fuel pellet: slow spontaneous fission (NEUT emitter), melts 2865 C, poor heat conductor (8 W/mK). Clad it in ZIRC.",
      density_kgm3=10970, cp_jkgk=235, heatCapacity=0.616,
      colour="0x2B2B30", type="SOLID", properties=["PROP_NEUTPENETRATE", "PROP_RADIOACTIVE"], temperature=K(20), highTemperature=K(2865), highTemperatureTransition="LAVA",
      hardness=90, weight=100, heatConduct=30, behavior={"kind": "emitter", "params": {"emits": "NEUT", "interval": 120, "count": 1, "temperature": 0, "speed": 0}}),
 dict(name="ZIRC", description="Zircaloy-4 cladding: neutron-transparent, conducts heat (22 W/mK) and electricity, melts 1852 C.",
      density_kgm3=6560, cp_jkgk=285, heatCapacity=0.447,
      colour="0xB4BCC4", type="SOLID", properties=["PROP_NEUTPENETRATE", "PROP_CONDUCTS"], temperature=K(20), highTemperature=K(1852), highTemperatureTransition="LAVA",
      hardness=60, weight=100, heatConduct=60, behavior={"kind": "inert"}),
 dict(name="GRPH", description="Nuclear graphite moderator: neutron-transparent, very high thermal conductivity (~120 W/mK), sublimes ~3600 C.",
      density_kgm3=1800, cp_jkgk=710, heatCapacity=0.305,
      colour="0x3C3C3C", type="SOLID", properties=["PROP_NEUTPENETRATE"], temperature=K(20), highTemperature=K(3600), highTemperatureTransition="SMKE",
      hardness=50, weight=100, heatConduct=140, behavior={"kind": "inert"}),
 dict(name="B4C", description="Boron carbide control rod / neutron poison: absorbs NEUT (90%/frame per neighbour), warms 4 K per capture, melts 2763 C.",
      density_kgm3=2520, cp_jkgk=950, heatCapacity=0.572,
      colour="0x1C1C2E", type="SOLID", properties=[], temperature=K(20), highTemperature=K(2763), highTemperatureTransition="LAVA",
      hardness=85, weight=100, heatConduct=40, behavior={"kind": "absorber", "params": {"absorbs": "NEUT", "chance": 0.9, "heatPerHit": 4}}),
 dict(name="CU", description="Copper busbar: best practical conductor, 400 W/mK, melts 1085 C. Use for generator output lines.",
      density_kgm3=8960, cp_jkgk=385, heatCapacity=0.824,
      colour="0xC87A3A", type="SOLID", properties=["PROP_CONDUCTS"], temperature=K(20), highTemperature=K(1085), highTemperatureTransition="LAVA",
      hardness=30, weight=100, heatConduct=251, behavior={"kind": "conductor", "params": {"delay": 0}}),
 dict(name="STEL", description="SA-508 reactor pressure-vessel steel: conducts, 40 W/mK, melts 1500 C, hardness 80.",
      density_kgm3=7850, cp_jkgk=486, heatCapacity=0.911,
      colour="0x8A9098", type="SOLID", properties=["PROP_CONDUCTS"], temperature=K(20), highTemperature=K(1500), highTemperatureTransition="LAVA",
      hardness=80, weight=100, heatConduct=100, behavior={"kind": "conductor", "params": {"delay": 0}}),
 dict(name="CNCR", description="Heavy shielding concrete: non-conductive, 1.5 W/mK, spalls to STNE above 1200 C, hardness 95.",
      density_kgm3=2400, cp_jkgk=880, heatCapacity=0.505,
      colour="0x9C9A8E", type="SOLID", properties=[], temperature=K(20), highTemperature=K(1200), highTemperatureTransition="STNE",
      hardness=95, weight=100, heatConduct=12, behavior={"kind": "inert"}),
 dict(name="LEAD", description="Lead gamma shielding: heavy, 35 W/mK, melts 327 C - keep it off the hot side.",
      density_kgm3=11340, cp_jkgk=130, heatCapacity=0.352,
      colour="0x5A5A6A", type="SOLID", properties=[], temperature=K(20), highTemperature=K(327), highTemperatureTransition="LAVA",
      hardness=40, weight=100, heatConduct=90, behavior={"kind": "inert"}),
 dict(name="NAK", description="Liquid sodium coolant (fast-reactor primary loop): excellent heat carrier (140 W/mK), boils 883 C, burns in air (flammable).",
      density_kgm3=900, cp_jkgk=1380, heatCapacity=0.297,
      colour="0xD9DCE6", type="LIQUID", properties=[], temperature=K(120), highTemperature=K(883), highTemperatureTransition="SMKE", lowTemperature=K(98), lowTemperatureTransition="SALT",
      hardness=0, weight=25, gravity=0.3, diffusion=0, flammable=400, heatConduct=220, behavior={"kind": "inert"}),
 dict(name="AERO", description="Silica aerogel insulation: 0.02 W/mK (best insulator), fragile, decomposes above 1200 C. Power-saving lagging for pipes and tanks.",
      density_kgm3=150, cp_jkgk=840, heatCapacity=0.030,
      colour="0xE4F0FA", type="SOLID", properties=[], temperature=K(20), highTemperature=K(1200), highTemperatureTransition="NONE",
      hardness=5, weight=100, heatConduct=1, behavior={"kind": "inert"}),
 dict(name="TRBN", description="Steam turbine stage: condenses adjacent WTRV to DSTW (25%/frame) and sparks touching conductors per unit of work; tmp = cumulative work. Steel body, melts 1400 C.",
      density_kgm3=7850, cp_jkgk=486, heatCapacity=0.911,
      colour="0x6E7E90", type="SOLID", properties=["PROP_CONDUCTS"], temperature=K(20), highTemperature=K(1400), highTemperatureTransition="LAVA",
      hardness=70, weight=100, heatConduct=100, behavior={"kind": "turbine", "params": {"input": "WTRV", "output": "DSTW", "chance": 0.25, "cool": 60}}),
 dict(name="TEG", description="Thermoelectric generator (Bi2Te3): above 100 C it pulses SPRK into touching conductors every 20 frames, shedding 2 K per pulse. Waste-heat recovery / power saving.",
      density_kgm3=7700, cp_jkgk=154, heatCapacity=0.283,
      colour="0x3FAA6A", type="SOLID", properties=["PROP_CONDUCTS"], temperature=K(20), highTemperature=K(585), highTemperatureTransition="BMTL",
      hardness=40, weight=100, heatConduct=80, behavior={"kind": "teg", "params": {"onTemp": K(100), "period": 20, "drop": 2}}),
 dict(name="LEDL", description="LED indicator: low-power glow lamp (glower period 30), no heat, for status panels instead of hot LCRY/WIFI.",
      density_kgm3=1200, cp_jkgk=1200, heatCapacity=0.344,
      colour="0xFFE066", type="SOLID", properties=[], temperature=K(20), highTemperature=K(300), highTemperatureTransition="BMTL",
      hardness=20, weight=100, heatConduct=20, behavior={"kind": "glower", "params": {"period": 30, "minLife": 0, "maxLife": 100}}),
]


# Metadata-only keys carried on each ELEMENTS dict for documentation/HeatCapacity purposes that are
# NOT defineElement/updateElement schema fields (heatCapacity in particular -- see
# research-material-mapping-2026-08-26.md S0.1 -- must be set post-define via elem.property).
_METADATA_KEYS = {"density_kgm3", "cp_jkgk", "heatCapacity"}


def apply_heat_capacity(c: PowderClient, hc_map: dict[str, float]) -> dict:
    """Set HeatCapacity on already-live elements via elem.property (not a schema field)."""
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


def main() -> int:
    ap = argparse.ArgumentParser(); ap.add_argument("--only", nargs="*"); ap.add_argument("--update", action="store_true")
    args = ap.parse_args()
    c = PowderClient()
    r = c.execute_lua(open("D:/powder-toy/scripts/lua/power_kinds.lua", encoding="utf-8").read())
    print("kinds:", r.get("result"))
    existing = {e.get("name") for e in (et.HANDLERS["list_custom_elements"]({}).get("elements") or [])}
    out = []
    considered = []
    for e in ELEMENTS:
        if args.only and e["name"] not in args.only:
            continue
        considered.append(e)
        spec = {k: v for k, v in e.items() if k not in _METADATA_KEYS}
        spec.setdefault("group", "POWER"); spec.setdefault("menuSection", SECTIONS.get(e["name"], "SOLIDS"))
        spec["timeout_s"] = 6.0
        tool = "update_element" if (e["name"] in existing or args.update) else "define_element"
        res = et.HANDLERS[tool](spec)
        out.append((e["name"], tool, res.get("ok"), res.get("status"), (res.get("error") or res.get("errors") or "")))
        print(e["name"], tool, res.get("ok"), res.get("status"), str(res.get("error") or res.get("errors") or "")[:160], flush=True)
    # post-define/update pass: HeatCapacity is not a schema field, applied separately every run.
    live_now = {e.get("name") for e in (et.HANDLERS["list_custom_elements"]({}).get("elements") or [])}
    hc_map = {e["name"]: e["heatCapacity"] for e in considered if "heatCapacity" in e and e["name"] in live_now}
    if hc_map:
        print("heatCapacity:", apply_heat_capacity(c, hc_map))
    json.dump(ELEMENTS, open("D:/powder-toy/knowledge/power-elements-2026-08-26.json", "w", encoding="utf-8"), indent=1)
    return 0 if all(o[2] for o in out) else 1


if __name__ == "__main__":
    sys.exit(main())
