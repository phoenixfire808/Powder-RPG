"""Writes knowledge/playbook-additions.json -- 4 new practices covering the 2026-08-26 power/materials
element sets. Same schema as knowledge/playbook.json; does NOT touch playbook.json itself."""
import json

practices = []


def add(**kw):
    practices.append(kw)


# 1. realistic_fission_core -------------------------------------------------
add(
    name="realistic_fission_core",
    level=4,
    topic="containment",
    goal="A UO2/B4C/HF fission core with realistic melting-point margins, contained in a layered STEL/CNCR/LEAD vessel.",
    status="proposed",
    steps=[
        {"do": "Run python scripts/define_power_elements.py once per game session (custom elements are not persistent)."},
        {"blueprint": {"id": "rpv", "module": "rpv_steel_vessel", "at": [0, 0], "params": {"width": 70, "height": 50}}},
        {"blueprint": {"id": "fb", "module": "pwr_fuel_bundle", "at": ["rpv.left+14", "rpv.top+14"], "params": {"pins": 3, "height": 20}}},
        {"blueprint": {"id": "rod", "module": "control_rod_drive_b4c", "at": ["fb.right+4", "rpv.top+10"], "params": {"stroke": 10, "bore": 3}}},
        {"do": "Withdraw the control_rod_drive_b4c PSTN (erase the rod) to raise flux past pwr_fuel_bundle's HF trim rod; watch B4C/HF tmp (captures) and UO2's steady NEUT emission. Re-insert to scram."},
    ],
    verify="Census inside rpv_steel_vessel's inner STEL cavity shows the fuel bundle and rod intact after 300 frames with the LEAD layer outermost and unmelted; B4C/HF tmp (captures) only climbs while the corresponding rod is inserted, and no element in the stack exceeds its own highTemperature.",
    pitfalls=[
        "UO2 emits NEUT continuously regardless of rod position -- there is no chain-reaction runaway in this element set (unlike PLUT/DEUT), so 'criticality' here means neutron economy and clad temperature, not an explosion risk",
        "LEAD must be the outermost, coolest layer of rpv_steel_vessel -- it melts at only 327 C, far below STEL (1500 C) or CNCR (spalls at 1200 C)",
        "STEL is the pressure boundary and must always face the fuel side, never the reverse",
        "This practice was authored and compiled offline (2026-08-26); it has not yet been run live in-sim -- treat the operating_bands as design targets, not measurements",
    ],
    scale_up="Stack multiple pwr_fuel_bundle instances inside one rpv_steel_vessel cavity for a multi-assembly core; feed the vessel's heat into a steam_generator (see electrical_generation_chain) instead of venting it, and add a status_display TSNS ladder on the vessel's STEL face.",
    modules=["pwr_fuel_bundle", "control_rod_drive_b4c", "rpv_steel_vessel"],
    operating_bands={
        "source": "derived from power-elements-2026-08-26.json melting/capture data, not yet run live",
        "uo2_melt_c": 2865,
        "zirc_clad_melt_c": 1852,
        "b4c_melt_c": 2763,
        "hf_melt_c": 2233,
        "lead_melt_c": 327,
        "note": "keep clad and rod temperatures far below these melt points; verify live before trusting exact numbers",
    },
)

# 2. electrical_generation_chain --------------------------------------------
add(
    name="electrical_generation_chain",
    level=4,
    topic="electrical",
    goal="A full realistic power chain: UO2 fuel assembly -> NAK/steam generator -> CU condenser -> TEG waste-heat panel -> independent SIPV solar leg, all onto one CU bus.",
    status="proposed",
    steps=[
        {"do": "Run python scripts/define_power_elements.py once per game session (custom elements are not persistent)."},
        {"blueprint": {"id": "fa", "module": "fuel_assembly_uo2", "at": [0, 0], "params": {"pins": 3, "height": 20}}},
        {"blueprint": {"id": "sg", "module": "steam_generator", "at": ["fa.right+16", "fa.top"], "params": {"width": 36, "height": 24}}},
        {"blueprint": {"id": "cd", "module": "condenser_cu", "at": ["sg.right+10", "sg.top"], "params": {"tubes": 4, "height": 20, "gap": 6}}},
        {"blueprint": {"id": "tw", "module": "teg_wall_panel", "at": ["sg.left", "sg.bottom+6"], "params": {"count": 4}}},
        {"blueprint": {"id": "pv", "module": "pv_array_sipv", "at": ["tw.right+10", "tw.top"], "params": {"count": 5}}},
        {"do": "Tie every module's CU bus together with a CU/INWR trunk line; each subsystem contributes SPRK independently (TRBN work pulses, TEG waste-heat pulses, SIPV under incident light) onto the shared bus."},
    ],
    verify="Over 300 frames: TRBN tmp (work) in steam_generator rises while its WTRV falls and DSTW appears; condenser_cu's DSTW bath temperature climbs; teg_wall_panel's TEG cells exceed 100 C and pulse SPRK onto their bus; pv_array_sipv produces SPRK only while PHOT is actually incident on it.",
    pitfalls=[
        "NAK is flammable in air (rating 400) -- keep the primary loop sealed inside steam_generator's STEL shell, never vent it to open atmosphere",
        "TRBN needs WTRV specifically, not DSTW/WATR, to do work",
        "TEG stops pulsing once it drops below its onTemp (100 C) -- site teg_wall_panel on a face that stays hot",
        "SIPV produces nothing without incident PHOT -- this leg of the chain is independent of the thermal legs and needs its own light source",
        "This practice was authored and compiled offline (2026-08-26); it has not yet been run live in-sim",
    ],
    scale_up="Series multiple steam_generator/condenser_cu pairs off one fuel_assembly_uo2 for more turbine stages; add nas_battery_rack or pcm_thermal_battery downstream of the CU trunk (see energy_storage_bank) to store the combined output instead of only showing it on LEDL.",
    modules=["fuel_assembly_uo2", "steam_generator", "condenser_cu", "teg_wall_panel", "pv_array_sipv"],
    operating_bands={
        "source": "derived from power-elements-2026-08-26.json + materials-catalog.json, not yet run live",
        "teg_on_temp_c": 100,
        "nak_operating_c": [400, 700],
        "note": "bands are design targets from element data; verify live before trusting exact numbers",
    },
)

# 3. chemical_safety_cell ----------------------------------------------------
add(
    name="chemical_safety_cell",
    level=2,
    topic="safety",
    goal="House genuinely reactive chemistry (NA+water, CAC2+water, MG combustion, CAO slaking) in separated, contained demo cells that do nothing until deliberately triggered.",
    status="proposed",
    steps=[
        {"blueprint": {"id": "na", "module": "sodium_fire_demo", "at": [0, 0], "params": {"width": 20, "height": 20}}},
        {"blueprint": {"id": "cl", "module": "carbide_lamp", "at": ["na.right+10", "na.top"], "params": {"width": 12, "height": 16}}},
        {"blueprint": {"id": "mg", "module": "mg_flare", "at": ["cl.right+10", "na.top"], "params": {"height": 14}}},
        {"blueprint": {"id": "lk", "module": "lime_kiln", "at": ["na.left", "na.bottom+6"], "params": {"width": 20, "height": 16}}},
        {"do": "Keep every hazard cell physically separated by at least one empty column and its own containment shell (FBRK/S316) -- never share a wall between two independent reactive-chemistry demos."},
    ],
    verify="At rest (paused) census shows NA and WATR not yet touching in sodium_fire_demo, CAC2 and its WATR drip separated by an air gap in carbide_lamp, and MG only touching OXYG/FIRE at its own tip in mg_flare -- nothing reacts until a cell is deliberately triggered.",
    pitfalls=[
        "NA+WATR/DSTW is genuinely violent (+600 K, ignites the H2 byproduct) -- never build this with a conductive enclosure or near stored fuel/logic",
        "CAC2+water makes flammable acetylene GAS -- only ignite the vented gas at the nozzle, never inside the sealed chamber",
        "Real magnesium fires cannot be extinguished with water or CO2 (both react with burning Mg) -- keep any fire-suppression element away from mg_flare",
        "CAO+water is a real +300 K exotherm (lime slaking) even though dry CAO is inert -- treat lime_kiln's charge as live the moment water is added",
        "This practice was authored and compiled offline (2026-08-26); it has not yet been run live in-sim",
    ],
    scale_up="One containment cell per reactive chemistry, one shared inert corridor between cells, and a single remote spark/valve trigger per cell (see wire_a_signal) so no two hazard demos can be set off by the same accidental touch.",
    modules=["sodium_fire_demo", "carbide_lamp", "mg_flare", "lime_kiln"],
)

# 4. energy_storage_bank ------------------------------------------------------
add(
    name="energy_storage_bank",
    level=3,
    topic="thermal",
    goal="Three independent energy-storage mechanisms side by side: a PCM thermal buffer, a molten NAS battery rack, and a superconducting-magnet LHE dewar.",
    status="proposed",
    steps=[
        {"blueprint": {"id": "pcm", "module": "pcm_thermal_battery", "at": [0, 0], "params": {"width": 20, "height": 16}}},
        {"blueprint": {"id": "nas", "module": "nas_battery_rack", "at": ["pcm.right+10", 0], "params": {"width": 24, "height": 20}}},
        {"blueprint": {"id": "cd", "module": "cryo_dewar_lhe", "at": ["nas.right+10", 0], "params": {"width": 30, "height": 26}}},
        {"do": "Route any surplus CU-bus power from electrical_generation_chain into nas_battery_rack to keep it above 300 C; route TEG/condenser waste heat into pcm_thermal_battery instead of venting it; keep cryo_dewar_lhe on its own insulated shaft, isolated from both hot subsystems."},
    ],
    verify="Over 300 frames: pcm_thermal_battery's PCMP core holds within a few K of 58 C while heat is added or removed; nas_battery_rack's NAS core stays above 300 C without external heating once initialized at 320 C; cryo_dewar_lhe's LHE bath stays at -269 C with the NBTI coil particle count unchanged.",
    pitfalls=[
        "PCMP above its 250 C decomposition point turns to SMKE and the buffer's charge is lost for good -- never let waste heat routed into pcm_thermal_battery exceed that",
        "NAS below ~300 C freezes solid to SALT and stops functioning -- nas_battery_rack's AERO liner only slows the cool-down, it does not stop it, so a real build needs a standing trickle heater",
        "Cryogenic liquids spawn at ambient temperature unless given an explicit cold props -- cryo_dewar_lhe's LHE bath must keep its temp_c: -269 prop or it flashes to NBLE immediately",
        "This practice was authored and compiled offline (2026-08-26); it has not yet been run live in-sim",
    ],
    scale_up="Size nas_battery_rack to the CU-bus load from electrical_generation_chain; add a status_display TSNS ladder on each of the three modules so an operator can see which store is charged without opening the cabinet.",
    modules=["pcm_thermal_battery", "nas_battery_rack", "cryo_dewar_lhe"],
)

out = {
    "schema": 1,
    "title": "Powder Toy building playbook additions \u2014 2026-08-26 power/materials element set",
    "how_to_use": (
        "Addendum to knowledge/playbook.json (that file is left untouched). Same schema and grading: 'status' "
        "proposed means derived from source element data and compiled offline only, not yet reproduced live in "
        "the running game. Practices reference the 20 new registry modules authored alongside this file for the "
        "UO2/ZIRC/GRPH/B4C/CU/STEL/CNCR/LEAD/NAK/AERO/TRBN/TEG/LEDL power-element set and the live-tier "
        "materials-catalog.json entries (GRNT FBRK RCNC RBAR S316 AL61 MWOL SIC SIPV PZT NBTI LHE LH2 KERO "
        "PCMP NAS DU HF NA MG CAO CAC2)."
    ),
    "practices": practices,
}

with open("D:/powder-toy/knowledge/playbook-additions.json", "w", encoding="utf-8") as f:
    json.dump(out, f, indent=1, sort_keys=False)
print("wrote playbook-additions.json with", len(practices), "practices")
