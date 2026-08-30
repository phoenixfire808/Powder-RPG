"""One-shot migration: apply knowledge/research-material-mapping-2026-08-26.md to the
materials catalogs (density_kgm3/cp_jkgk/heatCapacity fields, Hardness acid-solubility fix,
Explosive flag-value fix, AL61 two-stage thermite rule + new FSLG element, CELL/LIGN
differentiation, CS dT rebalance, and three DSL-extension demo rules).

Run once: python scripts/apply_research_mapping_2026_08_26.py
Idempotent: re-running recomputes the same derived fields from the same source dicts.
"""
import json

CATALOG = "D:/powder-toy/knowledge/materials-catalog.json"
PACKS = "D:/powder-toy/knowledge/materials-catalog-packs.json"

# name -> (density_kgm3, cp_jkgk) -- standard reference/textbook values (Wikipedia / CRC-style),
# same confidence convention as stock-element-realism-patch-v2.json. Room temperature unless the
# element's own operating temperature is cryogenic/molten (matches its catalog entry).
DENSITY_CP = {
    # materials-catalog.json -- building/insulation/ceramics/electronics/fluids/energy/exotic/alkali
    "GRNT": (2700, 790), "BSLT": (3000, 840), "LMST": (2600, 840), "MRBL": (2700, 880),
    "SDST": (2300, 920), "FBRK": (1900, 840), "RCNC": (2400, 880), "ASPH": (2300, 920),
    "GYPS": (800, 1090), "OAK": (750, 2400), "PINE": (500, 1380), "BAMB": (700, 1900),
    "RBAR": (7850, 486), "S316": (8000, 500), "AL61": (2700, 896), "TI64": (4430, 526),
    "WC": (15600, 205), "INC7": (8190, 435), "CIRN": (7200, 460),
    "MWOL": (100, 840), "PUFM": (35, 1400), "CFIB": (1600, 795), "GFIB": (40, 840),
    "KEVL": (1440, 1420), "PTFE": (2200, 1050), "PVC": (1400, 900), "HDPE": (950, 1900),
    "NYLN": (1140, 1670), "SILR": (1200, 1460), "RUBR": (920, 1880),
    "ALUM": (3950, 880), "ZRCA": (5680, 460), "SIC": (3210, 670), "BORO": (2230, 830),
    "FSIL": (2200, 740), "CTIL": (2300, 800),
    "SIPV": (2330, 705), "GERM": (5323, 320), "GAAS": (5320, 330), "PZT": (8060, 350),
    "NBTI": (6000, 380), "GRPN": (2260, 710),
    "FLBE": (1940, 2380), "LHE": (125, 5190), "LH2": (71, 9800), "ARGN": (1.78, 520),
    "H2O2": (1450, 2620), "KERO": (810, 2000), "BDSL": (880, 2000), "ETOH": (789, 2440),
    "GLYC": (1261, 2430), "LBE": (10500, 146),
    "PCMP": (900, 2100), "PCMS": (1460, 1930), "NAS": (1900, 1300),
    "DU": (19100, 116), "THOR": (11700, 118), "BE": (1850, 1825), "HF": (13300, 144),
    "CD": (8650, 230), "BPE": (1650, 1900),
    "PCAR": (1200, 1170), "CORK": (200, 1500), "BRSS": (8500, 380), "BRNZ": (8800, 380),
    "EPDM": (1150, 1490),
    "NA": (970, 1230), "MG": (1740, 1023), "CAO": (3340, 800), "CAC2": (2220, 1000),
    # new element from report S3 (thermite slag) -- blended Al2O3/Fe-oxide estimate, low confidence
    "FSLG": (4200, 700),
    # materials-catalog-packs.json
    "NICK": (8908, 444), "ZINC": (7140, 388), "TIN": (7310, 228), "SLVR": (10490, 235),
    "CHRM": (7190, 449), "COBT": (8900, 421),
    "CS": (1873, 242), "K": (862, 757), "CA": (1550, 647), "WP": (1823, 769), "S": (2070, 710),
    "MGRB": (1740, 1023),
    "NE": (0.9, 1030), "KR": (3.7, 248), "XE": (5.9, 158), "CL2": (3.2, 478), "F2": (1.7, 824),
    "NH3": (0.73, 2094), "CH4": (0.657, 2226), "PROP": (1.88, 1669), "O3": (2.14, 817),
    "KCL": (1984, 690), "CACL": (2150, 750), "LIF": (2640, 1560), "MGO": (3580, 940),
    "CAF2": (3180, 860), "NA2C": (2540, 1090),
    "CNT": (1350, 710), "SOOT": (170, 710), "C60": (1650, 570), "GAN": (6150, 490),
    "CDTE": (5850, 200), "INP": (4810, 310),
    "U235": (19100, 116), "AM241": (13670, 110), "CO60": (8900, 421), "TRIT": (0.27, 4800),
    "B10": (2460, 1026), "CF252": (15100, 180), "RA226": (5500, 94),
    "CELL": (1500, 1340), "LIGN": (1300, 1700), "CHIT": (1400, 1400), "BONE": (1900, 1300),
    "KERA": (1300, 1500), "SUGR": (1587, 1244), "STAR": (1500, 1650), "TLLW": (900, 2000),
    "BEES": (960, 2100),
    "LNE": (1207, 1880), "LAR": (1400, 1078), "LKR": (2413, 485), "LXE": (2942, 200),
    "LCH4": (422.6, 3480), "LF2": (1505, 1500),
}

# name -> new Hardness (report S0.2/S1.5: HIGH Hardness = MORE acid-soluble. Inert/corrosion-
# resistant materials need LOW hardness (0-5) for acid immunity; acid-VULNERABLE materials
# (carbonates, easily-rusted metals) need HIGH hardness so ACID.cpp actually dissolves them.
# Only entries whose own description makes an explicit corrosion/acid claim are touched; wear-
# hardness-only entries (WC, CNT, DMND-like) are left as pure mechanical-hardness flavor per S0.2.
HARDNESS_FIX_CATALOG = {
    "GRNT": 15,    # "acid-resistant except HF" (was 75)
    "LMST": 80,    # "classic acid-vulnerable masonry stone" (was 10 -- backwards)
    "MRBL": 92,    # "very low acid resistance" / eaten by acid rain, > LMST (was 12 -- backwards)
    "SDST": 15,    # "good acid resistance" (was 65)
    "FBRK": 20,    # "decent acid resistance" (was 60)
    "ASPH": 55,    # "low acid resistance to solvents" (was 45)
    "OAK": 20,     # "unusually acid/rot resistant" (was 55)
    "RBAR": 70,    # "rusts easily (low corrosion resistance)" (was 25 -- backwards)
    "S316": 5,     # "excellent chloride/acid resistance" (was 80 -- backwards)
    "TI64": 3,     # "among the best corrosion resistance of any structural metal" (was 90 -- backwards)
    "INC7": 10,    # "stays strong and corrosion-resistant" (was 85 -- backwards)
    "CIRN": 70,    # "corrodes and cracks" / rusts (was 20 -- backwards)
    "PTFE": 2,     # report explicit: PTFE/ALUM/ZRCA/BORO/FSIL -> 0-3 (was 95 -- backwards)
    "PVC": 10,     # "good acid resistance" (was 70)
    "HDPE": 3,     # "outstanding chemical resistance" (was 85 -- backwards)
    "SILR": 15,    # "good chemical/UV resistance" (was 60)
    "ALUM": 2,     # report explicit (was 90 -- backwards)
    "ZRCA": 2,     # report explicit (was 92 -- backwards)
    "SIC": 3,      # report explicit flagged list (was 90 -- backwards)
    "BORO": 3,     # report explicit (was 80 -- backwards)
    "FSIL": 3,     # report explicit (was 85 -- backwards)
    "CTIL": 15,    # "resists most household acids" (was 82)
    "SIPV": 5,     # "attacked only by HF" (was 70 -- backwards)
    "GERM": 40,    # "moderate acid resistance" (was 50)
    "GRPN": 2,     # "essentially chemically inert" (was 90 -- backwards)
    "HF": 5,       # "excellent corrosion resistance" (was 85 -- backwards; hafnium, not hydrofluoric acid)
    "BRNZ": 30,    # "harder and MORE corrosion-resistant than brass" -> lower than BRSS (was 55)
    "EPDM": 10,    # "outstanding weathering/ozone/chemical resistance...far better than natural rubber" (was 65 -- backwards)
}
HARDNESS_FIX_PACKS = {
    "NICK": 15,    # "corrosion-resistant" (was 55 -- backwards)
    "ZINC": 60,    # sacrificial anode -- corrodes preferentially to protect steel (was 25 -- backwards)
    "CHRM": 5,     # "forms stainless steel's passive oxide" (was 85 -- backwards)
}

# Explosive: engine only reads bits 0 (deflagrate-on-flame) and 1 (&2, autodetonate above pv 2.5).
# Valid values are 0/1/2/3 only (report S0.3/S1.4/S2 AL61 row).
EXPLOSIVE_FIX_CATALOG = {
    "H2O2": 0,   # was 15 (=3 effective); no Flammable set so bit0 was dead anyway; let the
                 # MG>WTRV,SELF decomposition rule carry all the peroxide behavior (report S1.4).
}
EXPLOSIVE_FIX_PACKS = {
    "O3": 1,     # was 20 (=0 effective, did nothing); real ozone hazard is deflagration-class, not
                 # shock-detonation, so bit0 only. Paired with a new small `flammable` below.
    "SUGR": 1,   # was 15 (=3 effective = spontaneously pressure-detonates); keep deflagration-on-
                 # flame only (combustible-dust hazard is real, spontaneous detonation is not).
    "STAR": 1,   # was 15, same bug as SUGR.
}
FLAMMABLE_ADD_PACKS = {"O3": 50}  # give O3 a nonzero Flammable so its Explosive&1 bit isn't dead too.


def hc(density: float, cp: float) -> float:
    return round(max(0.02, min(8.0, density * cp / 4.186e6)), 3)


def annotate(entries: list[dict], hardness_fix: dict, explosive_fix: dict, flammable_add: dict, label: str) -> None:
    missing = [e["name"] for e in entries if e["name"] not in DENSITY_CP]
    if missing:
        raise SystemExit(f"{label}: missing density/cp data for {missing}")
    for e in entries:
        d, c = DENSITY_CP[e["name"]]
        e["density_kgm3"] = d
        e["cp_jkgk"] = c
        e["heatCapacity"] = hc(d, c)
        if e["name"] in hardness_fix:
            e["hardness"] = hardness_fix[e["name"]]
        if e["name"] in explosive_fix:
            val = explosive_fix[e["name"]]
            if val == 0:
                e.pop("explosive", None)
            else:
                e["explosive"] = val
        if e["name"] in flammable_add:
            e["flammable"] = flammable_add[e["name"]]


def main() -> None:
    cat = json.load(open(CATALOG, encoding="utf-8"))
    packs = json.load(open(PACKS, encoding="utf-8"))

    annotate(cat["entries"], HARDNESS_FIX_CATALOG, EXPLOSIVE_FIX_CATALOG, {}, "materials-catalog.json")
    annotate(packs["entries"], HARDNESS_FIX_PACKS, EXPLOSIVE_FIX_PACKS, FLAMMABLE_ADD_PACKS, "materials-catalog-packs.json")

    by_name_cat = {e["name"]: e for e in cat["entries"]}
    by_name_packs = {e["name"]: e for e in packs["entries"]}

    # --- AL61 two-stage thermite rule (report S3/S4) + reconcile doc drift -----------------
    al61 = by_name_cat["AL61"]
    al61["behavior"] = {"kind": "reactive", "params": {
        "rules": "FIRE>SELF,SELF:120:.5::FIRE;BRMT>FSLG,IRON:450:.9:HEAT480:FIRE"
    }}
    al61["description"] = (
        "Aluminium 6061-T6: density 2700 kg/m3, k=167 W/mK, melts 582-652C. Light structural alloy, "
        "self-passivating oxide layer. Thermite rule (2026-08-26 two-stage, report S3): a FIRE fuse "
        "preheats AL61 without consuming it (120K/hit, 50% chance, rekindles a forward FIRE), then once "
        "AL61 itself reaches 480K it converts touching BRMT to IRON and itself to FSLG slag -- a "
        "low-conductivity product chosen to retain reaction heat (see FSLG) instead of flash-averaging "
        "away into stock STNE/IRON in one conduction frame."
    )

    # --- FSLG: new low-conductivity thermite-slag product (report S3) ---------------------
    if "FSLG" not in by_name_cat:
        cat["entries"].append({
            "name": "FSLG", "category": "building", "priority": 1,
            "description": "Thermite slag (solidified Al2O3/Fe-oxide mixture): k~3 W/mK (low, matches "
                            "real molten-oxide slag thermal diffusivity), density ~4200 kg/m3 (blended "
                            "estimate, low confidence). Deliberately low HeatConduct so a just-reacted "
                            "AL61/BRMT cell holds its heat for many frames instead of flash-averaging "
                            "away across its 3x3 neighbourhood in a single conduction event (report S0.4/S3).",
            "use": "Thermite reaction product (AL61 two-stage rule); inert afterwards.",
            "source": "https://en.wikipedia.org/wiki/Thermite",
            "colour": "0x4A3A34", "type": "SOLID", "properties": [],
            "temperature": 293.15, "highTemperature": 2073.15, "highTemperatureTransition": "LAVA",
            "hardness": 3, "weight": 100, "heatConduct": 15,
            "behavior": {"kind": "inert"},
        })
        by_name_cat["FSLG"] = cat["entries"][-1]
        d, c = DENSITY_CP["FSLG"]
        by_name_cat["FSLG"]["density_kgm3"] = d
        by_name_cat["FSLG"]["cp_jkgk"] = c
        by_name_cat["FSLG"]["heatCapacity"] = hc(d, c)

    # --- MG: consumable-second-reactant DSL extension demo (needs O2=NONE) ----------------
    mg = by_name_cat["MG"]
    mg["behavior"]["params"]["rules"] = "FIRE>STNE,SELF:900:.35:O2=NONE:FIRE;PLSM>STNE,SELF:900:.5::FIRE"
    mg["description"] += " (2026-08-26: FIRE-branch now actually consumes a real O2 neighbour via the needs=ELEM=BECOMES DSL extension, true stoichiometric O2 consumption instead of a presence-only gate.)"

    # --- H2O2: concentration-via-life DSL extension demo -----------------------------------
    h2o2 = by_name_cat["H2O2"]
    h2o2["behavior"]["params"]["rules"] = "MG>WTRV,SELF:250:.3::OXYG:conc=20"
    h2o2["description"] += " (2026-08-26: MG-catalyzed decomposition now uses conc=20 -- each MG contact drains 20 life before H2O2 actually converts to WTRV, i.e. it takes ~5 contacts to fully decompose instead of vanishing on the first hit.)"

    # --- CAC2: direct-pressure-yield DSL extension demo (carbide gas generator) ------------
    cac2 = by_name_cat["CAC2"]
    cac2["behavior"]["params"]["rules"] = "WATR>CLST,NONE:+60:0.5::GAS::pgas=8;DSTW>CLST,NONE:+60:0.5::GAS::pgas=8"
    cac2["description"] += " (2026-08-26: each reaction event now also adds pgas=8 directly to sim.pressure at the cell, modeling real bulk acetylene evolution pressurizing a sealed carbide-lamp/generator vessel, on top of the existing extra:GAS particle spawn.)"

    # --- LIGN: fix identical-rule-to-CELL bug (report S2) ----------------------------------
    lign = by_name_packs["LIGN"]
    lign["behavior"]["params"]["rules"] = "FIRE>NONE,SELF:300:.12:O2:SMKE"
    lign["description"] += " (2026-08-26: chance lowered 0.2->0.12 vs CELL's 0.2 to actually deliver the 'harder to ignite than pure cellulose' claim -- the two rules were previously byte-identical, a bug.)"

    # --- CS: dT ordering fix vs K (report S2) ----------------------------------------------
    cs = by_name_packs["CS"]
    cs["behavior"]["params"]["rules"] = "WATR>NONE,H2:400:.9;DSTW>NONE,H2:400:.9;AIR>NONE,SELF:200:.05"
    cs["description"] += " (2026-08-26: dT rebalanced 900->400, below K's 800 -- Cs has lower per-kg reaction energy than K despite being more kinetically dramatic; drama now lives in `chance` (0.9 vs K's 0.6-0.7) instead of an inflated dT.)"

    for rule_owner in (al61, mg, h2o2, cac2, lign, cs, by_name_cat["FSLG"]):
        for rule in rule_owner.get("behavior", {}).get("params", {}).get("rules", "").split(";"):
            if len(rule) > 64:
                raise SystemExit(f"rule too long ({len(rule)} chars): {rule}")

    json.dump(cat, open(CATALOG, "w", encoding="utf-8"), indent=1)
    json.dump(packs, open(PACKS, "w", encoding="utf-8"), indent=1)
    print("materials-catalog.json entries:", len(cat["entries"]))
    print("materials-catalog-packs.json entries:", len(packs["entries"]))
    print("OK")


if __name__ == "__main__":
    main()
