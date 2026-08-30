"""One-shot authoring script for MODULE-AUTHOR's 2026-08-26 new-elements module batch.
Writes each module JSON to knowledge/modules/<name>.json, sorted keys, indent=1 (matching
the existing fuel_assembly_uo2/steam_turbine_stage/teg_waste_heat style).

Internal part "id"s are prefixed per-module (rpv_, sg_, cond_, teg_, pv_, pzt_, pcm_, nas_,
dewar_, nafire_, mgf_, kiln_, lamp_, gf_, rcb_, spr_, hs_, sic_) so that any two of these
modules can be placed together in one blueprint (e.g. in playbook-additions.json practices)
without a duplicate-id compile error -- ids are a single global namespace once a blueprint
is fully expanded, they are not auto-scoped per module invocation.
"""
import json, os

MODDIR = "D:/powder-toy/knowledge/modules"

MODULES = []


def add(name, description, why, params, parts, anchors_note=None):
    m = {"name": name, "description": description, "why": why, "params": params, "parts": parts}
    if anchors_note:
        m["anchors_note"] = anchors_note
    MODULES.append(m)


# 1. pwr_fuel_bundle -----------------------------------------------------
add(
    "pwr_fuel_bundle",
    "PWR-style fuel bundle: UO2/GRPH/ZIRC pin lattice (as fuel_assembly_uo2) plus two parallel absorber "
    "rod channels, one HF (long-life control) and one B4C (fast shutdown poison), side by side.",
    "UO2 melts 2865 C and is a poor conductor (8 W/mK) so heat must leave through the ZIRC clad (22 W/mK, "
    "melts 1852 C) -- never let cladding itself approach its own melt point. HF absorbs NEUT at 95% chance "
    "per neighbour and survives coolant chemistry for a full core life (melts 2233 C); B4C absorbs at 90% "
    "with a bigger heat kick per capture (4 K vs HF's 3 K) but melts far sooner (2763 C is still high, but "
    "warms faster) -- run HF as the everyday trim rod and reserve B4C for the fast trip. Withdraw either rod "
    "(erase it) to raise flux, reinsert (redraw) to scram.",
    {"pins": 3, "height": 20},
    [
        {"box": "ZIRC", "at": [0, 0], "size": ["pins*6+10", "height+2"]},
        {"erase": True, "at": [2, 1], "size": ["pins*6+6", "height"]},
        {
            "repeat": "pins",
            "at": [2, 1],
            "step": [6, 0],
            "part": {
                "group": [
                    {"box": "UO2", "at": [0, 0], "size": [2, "height"]},
                    {"box": "GRPH", "at": [2, 0], "size": [2, "height"]},
                    {"box": "ZIRC", "at": [4, 0], "size": [1, "height"]},
                ],
                "at": [0, 0],
            },
        },
        {"box": "HF", "at": ["pins*6+3", 1], "size": [2, "height"]},
        {"box": "B4C", "at": ["pins*6+6", 1], "size": [2, "height"]},
    ],
)

# 2. control_rod_drive_b4c ------------------------------------------------
add(
    "control_rod_drive_b4c",
    "PSTN-driven B4C control rod: a piston pushes a boron-carbide rod down an INSL-lined STEL guide "
    "channel into a fuel slot below.",
    "Mechanical rod drives (per RBMK community pattern) encode real withdrawal state in geometry rather than "
    "a flag: the PSTN's own position IS how far the poison is inserted. B4C melts 2763 C and warms 4 K per "
    "neutron capture (heatPerHit) so a fully-inserted rod under high flux will itself heat up -- the STEL "
    "guide (melts 1500 C) and INSL liner keep that heat from bridging into the drive mechanism. Extend the "
    "PSTN (positive stroke) to insert/scram; retract to withdraw and raise reactivity.",
    {"stroke": 10, "bore": 3},
    [
        {"box": "STEL", "at": [0, 0], "size": ["bore+4", "stroke+14"], "id": "rod_guide"},
        {"erase": True, "at": [2, 2], "size": ["bore", "stroke+10"]},
        {"box": "INSL", "at": [2, 2], "size": [1, "stroke+10"]},
        {"box": "INSL", "at": ["bore+1", 2], "size": [1, "stroke+10"]},
        {"box": "PSTN", "at": [3, 3], "size": ["bore-2", 4], "props": {"temp_c": 20}},
        {"box": "B4C", "at": [3, 8], "size": ["bore-2", "stroke"]},
    ],
)

# 3. rpv_steel_vessel ------------------------------------------------------
add(
    "rpv_steel_vessel",
    "Layered reactor pressure vessel: STEL inner pressure boundary, CNCR biological shield, LEAD gamma "
    "shield on the cool outer face.",
    "Real PWR ordering, outside-in from the hot core: STEL (melts 1500 C, is the pressure boundary and must "
    "face the hottest side), CNCR biological shield (1.5 W/mK, spalls to STNE only above 1200 C -- absorbs "
    "gamma/neutron dose over a large cheap mass), then LEAD gamma shielding last of all because it melts at "
    "only 327 C -- it must never be the layer touching anything hot. Payload (fuel, coolant) goes in the "
    "empty STEL-lined cavity.",
    {"width": 60, "height": 50},
    [
        {"box": "LEAD", "at": [0, 0], "size": ["width", "height"], "hollow": 3, "id": "rpv_gamma"},
        {"box": "CNCR", "at": [3, 3], "size": ["width-6", "height-6"], "hollow": 4, "id": "rpv_shield"},
        {"box": "STEL", "at": [7, 7], "size": ["width-14", "height-14"], "hollow": 3, "id": "rpv_core"},
    ],
)

# 4. steam_generator --------------------------------------------------------
add(
    "steam_generator",
    "Steam generator: a hot NAK (liquid sodium) primary tube running through a STEL shell, boiling a WTRV "
    "secondary side that feeds a TRBN stage.",
    "Sodium-cooled fast reactors move heat from a hot NAK primary loop (operate ~500 C, boils 883 C, "
    "burns in air) across an intact STEL tube wall into an isolated water/steam secondary loop -- the two "
    "fluids must never be allowed to touch (a Na-water reaction is violent and exothermic). WTRV is placed "
    "pre-boiled here at 170 C to feed the TRBN turbine immediately; in a live build, back this with a real "
    "boiler running the 130-180 C band from heat_extraction_loop.",
    {"width": 36, "height": 24},
    [
        {"box": "STEL", "at": [0, 0], "size": ["width", "height"], "hollow": 2, "id": "sg_shell"},
        {"box": "WTRV", "at": [2, 2], "size": ["width-4", "height//2-4"], "props": {"temp_c": 170}, "id": "sg_steam"},
        {"box": "DSTW", "at": [2, "height//2+4"], "size": ["width-4", "height//2-6"], "id": "sg_cond"},
        {"box": "NAK", "at": [2, "height//2-2"], "size": ["width-4", 4], "props": {"temp_c": 500}, "id": "sg_primary"},
        {"box": "TRBN", "at": ["width//2-2", 2], "size": [4, 4], "id": "sg_turb"},
        {"box": "CU", "at": ["sg_turb.right+1", "sg_turb.cy"], "size": [8, 1]},
        {"box": "LEDL", "at": ["sg_shell.right+2", 2], "size": [3, 3]},
    ],
)

# 5. condenser_cu --------------------------------------------------------
add(
    "condenser_cu",
    "Condenser tube bank: parallel CU tubes submerged in a DSTW bath to pull heat out of steam onto a "
    "copper busbar.",
    "CU is the best practical conductor (400 W/mK) short of exotic materials, but melts at 1085 C -- keep "
    "it in the coolant, not the fire. Submerge the bundle in DSTW (never WATR) because the tubes are "
    "conductors and WATR carries sparks; each tube functions exactly like a real shell-and-tube condenser "
    "pass, carrying waste heat (and any induced current) out to a common bus for TEG/LEDL pickup.",
    {"tubes": 4, "height": 20, "gap": 6},
    [
        {"box": "DSTW", "at": [0, 0], "size": ["tubes*gap+4", "height"], "id": "cond_bath"},
        {
            "repeat": "tubes",
            "at": [2, 1],
            "step": ["gap", 0],
            "part": {"line": "CU", "from": [0, 0], "to": [0, "height-2"]},
        },
        {"box": "LEDL", "at": ["cond_bath.right+2", 0], "size": [3, 3]},
    ],
)

# 6. teg_wall_panel --------------------------------------------------------
add(
    "teg_wall_panel",
    "Tiled thermoelectric generator panel: a row of TEG cells sharing one CU collector bus, with an LEDL "
    "status lamp.",
    "A single TEG only pulses SPRK every 20 frames once above 100 C, shedding 2 K per pulse -- tiling many "
    "cells onto one shared CU bus multiplies the output the way a real Bi2Te3 module array does. TEG itself "
    "transitions to BMTL above 585 C, so mount the panel on a wall that runs hot (condenser shell, reactor "
    "bio-shield outer face) but well under that ceiling -- this is a waste-heat scavenger, not a primary "
    "power source.",
    {"count": 4},
    [
        {
            "repeat": "count",
            "at": [0, 0],
            "step": [5, 0],
            "part": {"box": "TEG", "at": [0, 0], "size": [4, 4]},
        },
        {"box": "CU", "at": [0, 4], "size": ["count*5-1", 1], "id": "teg_bus"},
        {"box": "LEDL", "at": ["teg_bus.right+2", 0], "size": [3, 3]},
    ],
)

# 7. pv_array_sipv --------------------------------------------------------
add(
    "pv_array_sipv",
    "Photovoltaic array: a row of SIPV cells on a common CU busbar with an LEDL status lamp.",
    "SIPV models real monocrystalline-silicon PV: ~88% of incident PHOT hits convert to a 3-unit SPRK pulse "
    "(perSpark), matching the ~22% panel-level efficiency once averaged over a realistic photon flux, and it "
    "shrugs off heat to 1414 C melt. The array only produces anything when PHOT (from an ARAY/LCRY source or "
    "outdoor light) actually lands on the cells -- point a light source at this panel, don't bury it in an "
    "enclosure. Only HF etches SIPV in reality, so it is otherwise chemically safe to mount anywhere.",
    {"count": 5},
    [
        {
            "repeat": "count",
            "at": [0, 0],
            "step": [5, 0],
            "part": {"box": "SIPV", "at": [0, 0], "size": [4, 4]},
        },
        {"box": "CU", "at": [0, 4], "size": ["count*5-1", 1], "id": "pv_bus"},
        {"box": "LEDL", "at": ["pv_bus.right+2", 0], "size": [3, 3]},
    ],
)

# 8. piezo_floor_pzt --------------------------------------------------------
add(
    "piezo_floor_pzt",
    "Piezoelectric floor: a row of PZT tiles wired to a common CU bus, converting footstep/impact pressure "
    "into SPRK pulses.",
    "PZT's piezo behaviour fires when mechanical stress exceeds its threshold (5.0), pulsing every 2 frames "
    "while stressed -- wire a walkway or hatch of these tiles into a CU bus to harvest foot traffic or "
    "impacts as a real energy-harvesting floor. Curie point is only 360 C (transitions to BMTL) so this is a "
    "cool-running mechanical sensor/harvester, not something to put anywhere near a hot process.",
    {"tiles": 5},
    [
        {
            "repeat": "tiles",
            "at": [0, 0],
            "step": [5, 0],
            "part": {"box": "PZT", "at": [0, 0], "size": [4, 3]},
        },
        {"box": "CU", "at": [0, 3], "size": ["tiles*5-1", 1], "id": "pzt_bus"},
        {"box": "LEDL", "at": ["pzt_bus.right+2", -1], "size": [3, 3]},
    ],
)

# 9. pcm_thermal_battery --------------------------------------------------------
add(
    "pcm_thermal_battery",
    "Phase-change thermal battery: a PCMP core wrapped in an AERO insulation jacket.",
    "PCMP melts at 58 C absorbing ~200 kJ/kg of latent heat and releases the same heat back when it "
    "re-freezes, holding a nearly constant temperature the whole time -- exactly a real paraffin-wax thermal "
    "buffer. AERO (0.02 W/mK, the best insulator available) keeps that stored latent heat from leaking out "
    "before it is needed. Keep the whole assembly well under PCMP's 250 C decomposition point (it goes to "
    "SMKE above that, losing the charge for good) and away from open flame (PCMP is itself flammable).",
    {"width": 20, "height": 16},
    [
        {"box": "AERO", "at": [0, 0], "size": ["width", "height"], "hollow": 2, "id": "pcm_jacket"},
        {"box": "PCMP", "at": [2, 2], "size": ["width-4", "height-4"], "id": "pcm_core"},
    ],
)

# 10. nas_battery_rack --------------------------------------------------------
add(
    "nas_battery_rack",
    "Sodium-sulfur battery rack: a molten NAS core held hot in an AERO liner inside a STEL cabinet.",
    "NAS only works liquid, in a narrow 300-350 C band -- below ~300 C it freezes solid to SALT and stops "
    "functioning, and its sodium content boils at 883 C if things run away. Real grid NaS battery packs are "
    "heated cabinets for exactly this reason: the STEL outer cabinet gives physical/structural containment, "
    "the AERO liner keeps the pack in its molten window with minimum standing heater load. Treat any breach "
    "of this rack as a sodium-fire hazard (see sodium_fire_demo) -- NAS installations have had real "
    "thermal-runaway fires.",
    {"width": 24, "height": 20},
    [
        {"box": "STEL", "at": [0, 0], "size": ["width", "height"], "hollow": 2, "id": "nas_cabinet"},
        {"box": "AERO", "at": [2, 2], "size": ["width-4", "height-4"], "hollow": 2, "id": "nas_liner"},
        {"box": "NAS", "at": [4, 4], "size": ["width-8", "height-8"], "props": {"temp_c": 320}, "id": "nas_cell"},
    ],
)

# 11. cryo_dewar_lhe --------------------------------------------------------
add(
    "cryo_dewar_lhe",
    "Liquid-helium dewar: MWOL outer jacket, AERO liner, an LHE bath at 4 K with an NBTI coil submerged "
    "in it.",
    "LHE boils at just 4.2 K and (like every cryogen in this framework) spawns at room temperature unless "
    "given an explicit cold props -- the bath here is placed at -269 C. NBTI only superconducts below its "
    "own critical temperature (Tc = 9.3 K), so the coil must stay fully immersed in the LHE pool at all "
    "times; a warm leak through the MWOL/AERO insulation boils the whole reservoir off in a few hundred "
    "frames and the coil goes resistive (modeled here simply as a normal conductor). Never route the coil "
    "or bath through bare METL -- use the AERO/MWOL jacket for every penetration.",
    {"width": 30, "height": 26},
    [
        {"box": "MWOL", "at": [0, 0], "size": ["width", "height"], "hollow": 3, "id": "dewar_shell"},
        {"box": "AERO", "at": [3, 3], "size": ["width-6", "height-6"], "hollow": 2, "id": "dewar_liner"},
        {"box": "LHE", "at": [5, 5], "size": ["width-10", "height-10"], "props": {"temp_c": -269}, "id": "dewar_bath"},
        {"box": "NBTI", "at": [7, 7], "size": ["width-14", "height-14"], "hollow": 1, "id": "dewar_coil"},
    ],
)

# 12. sodium_fire_demo --------------------------------------------------------
add(
    "sodium_fire_demo",
    "Sodium-water safety demo cell: an FBRK-walled pit holding a WATR pool with an NA charge suspended "
    "above it on a shelf gap, ready to drop.",
    "Sodium metal (melts 98 C) reacts violently with water: NA+WATR/DSTW releases ~600 K of heat and H2 gas "
    "that then ignites -- a real and historically documented hazard at sodium-cooled reactor sites. This is "
    "a HAZARD DEMO, not a toy: the FBRK containment (acid/heat resistant, a decent insulator) keeps the fire "
    "and blast local. The NA block sits on a dry shelf above the pool at rest; unpausing lets gravity drop it "
    "in. Never build this with a conductive (METL) enclosure, and never site it near stored fuel or logic.",
    {"width": 20, "height": 20},
    [
        {"box": "FBRK", "at": [0, 0], "size": ["width", "height"], "hollow": 2, "id": "nafire_cell"},
        {"box": "WATR", "at": [2, "height-6"], "size": ["width-4", 4], "id": "nafire_pool"},
        {"box": "NA", "at": ["width//2-2", 2], "size": [4, 4], "id": "nafire_charge"},
    ],
)

# 13. mg_flare --------------------------------------------------------
add(
    "mg_flare",
    "Magnesium flare: an MG rod in an OXYG atmosphere with a small FIRE igniter touching its tip.",
    "Magnesium will not casually ignite (needs real heat input) but once past ~630 C it burns at ~3100 C, "
    "consuming its own OXYG neighbours per the reactive rule and producing STNE ash and PROP_HOT_GLOW white "
    "light -- the classic flare/thermite-starter reaction, and the reason this needs a dedicated OXYG pocket "
    "rather than relying on ambient air. Real magnesium fires cannot be put out with water (it reacts with "
    "burning Mg to make more hydrogen) or CO2 -- keep any suppression system away from this module.",
    {"height": 14},
    [
        {"box": "OXYG", "at": [3, 0], "size": [6, "height"], "id": "mgf_o2"},
        {"box": "MG", "at": [0, "height-10"], "size": [3, 10], "id": "mgf_rod"},
        {"box": "FIRE", "at": [0, "height-12"], "size": [2, 2], "id": "mgf_igniter"},
    ],
)

# 14. lime_kiln --------------------------------------------------------
add(
    "lime_kiln",
    "Lime kiln vessel: an FBRK shell holding a CAO (quicklime) charge, ready for field slaking.",
    "FBRK (fired clay brick, vitrifies ~1150 C) is a real historic kiln-shell material with a comfortable "
    "margin under CAO's own 2613 C melt point. The CAO charge here represents the finished quicklime product "
    "of a real kiln (limestone calcination itself needs LMST, not in the live element set) -- add WATR or "
    "DSTW to trigger the genuine exothermic slaking reaction (+300 K, converts to CLST hydrated lime). Do "
    "the water-add step in a ventilated/open cell: real quicklime slaking is vigorous and the vessel heats "
    "fast.",
    {"width": 20, "height": 16},
    [
        {"box": "FBRK", "at": [0, 0], "size": ["width", "height"], "hollow": 2, "id": "kiln_shell"},
        {"box": "CAO", "at": [2, 2], "size": ["width-4", "height-4"], "id": "kiln_charge"},
    ],
)

# 15. carbide_lamp --------------------------------------------------------
add(
    "carbide_lamp",
    "Carbide lamp: an S316 housing with a CAC2 charge at the bottom, a WATR drip reservoir above it (air "
    "gap, not touching at rest), and a lit FIRE nozzle at the top vent.",
    "This reproduces the real carbide-lamp reaction: calcium carbide plus water releases flammable acetylene "
    "GAS (mildly exothermic, +60 C) while the solid CAC2 itself is inert until wetted (melts 2160 C, no "
    "hazard on its own). The drip reservoir is placed with a gap above the charge so the module compiles at "
    "rest without reacting -- open the valve (route WATR down onto the CAC2) only when ready to light the "
    "vented gas at the nozzle; never ignite gas inside the sealed carbide chamber itself.",
    {"width": 12, "height": 16},
    [
        {"box": "S316", "at": [0, 0], "size": ["width", "height"], "hollow": 2, "id": "lamp_body"},
        {"box": "WATR", "at": [2, 2], "size": ["width-4", 3], "id": "lamp_drip"},
        {"box": "CAC2", "at": [2, "height-6"], "size": ["width-4", 4], "id": "lamp_charge"},
        {"box": "FIRE", "at": ["width//2-1", 0], "size": [2, 2], "id": "lamp_flame"},
    ],
)

# 16. granite_foundation --------------------------------------------------------
add(
    "granite_foundation",
    "Granite foundation: a wide GRNT slab with supporting GRNT piers.",
    "GRNT (density 2700 kg/m3, k=2.8 W/mK, begins melting ~1215-1260 C, resists every acid except HF) is a "
    "non-conductive, high-mass footing -- unlike RCNC it carries no electrical path, so it is the safe "
    "generic choice for a foundation slab sitting directly under conductive plant (STEL frames, CU busbars) "
    "without ever creating a floor-wide short (see the conductive_floor_span lint rule).",
    {"width": 40, "height": 18, "piers": 3},
    [
        {"box": "GRNT", "at": [0, 0], "size": ["width", "height//3"], "id": "gf_slab"},
        {
            "repeat": "piers",
            "at": [2, "height//3"],
            "step": ["(width-8)//2", 0],
            "part": {"box": "GRNT", "at": [0, 0], "size": [4, "height*2//3"]},
        },
    ],
)

# 17. rc_bunker --------------------------------------------------------
add(
    "rc_bunker",
    "Reinforced-concrete bunker: an RCNC shell with a literal RBAR mesh layer embedded at wall mid-depth.",
    "RCNC already models rebar-in-concrete conduction (PROP_CONDUCTS, k=1.7 W/mK) implicitly; this module "
    "makes the rebar layer an explicit RBAR sheet sandwiched inside the RCNC wall so it reads correctly as a "
    "real conductive path for channel/lint checks and can be tapped electrically. RCNC spalls at only 300 C "
    "(the rebar corrodes/expands under fire load) -- far below plain CNCR's 1200 C -- so use CNCR, not this "
    "module, for reactor biological shielding; use rc_bunker for ordinary blast/structural walls.",
    {"width": 30, "height": 24},
    [
        {"box": "RCNC", "at": [0, 0], "size": ["width", "height"], "hollow": 4, "id": "rcb_shell"},
        {"box": "RBAR", "at": [2, 2], "size": ["width-4", "height-4"], "hollow": 1, "id": "rcb_mesh"},
    ],
)

# 18. stainless_pipe_rack --------------------------------------------------------
add(
    "stainless_pipe_rack",
    "Stainless pipe rack: parallel S316 tube runs between two S316 support posts.",
    "316 stainless resists chlorides and acids far better than plain STEL or RBAR thanks to its "
    "molybdenum alloying -- use this rack for coolant, brine, or acid-service pipe runs in marine or "
    "chemical-process cells where ordinary steel would corrode away. It still only melts around 1400 C, so "
    "it is not a substitute for reactor-grade STEL inside a high-flux core.",
    {"length": 30, "rows": 4},
    [
        {"box": "S316", "at": [0, 0], "size": [2, "rows*4"], "id": "spr_post_left"},
        {"box": "S316", "at": ["length-2", 0], "size": [2, "rows*4"], "id": "spr_post_right"},
        {
            "repeat": "rows",
            "at": [2, 1],
            "step": [0, 4],
            "part": {"box": "S316", "at": [0, 0], "size": ["length-4", 2]},
        },
    ],
)

# 19. al_heat_sink --------------------------------------------------------
add(
    "al_heat_sink",
    "Aluminium heat sink: an AL61 base plate with an array of AL61 cooling fins.",
    "6061-T6 aluminium conducts at 167 W/mK (far ahead of any steel in this catalog) but melts at only "
    "582-652 C -- excellent for shedding waste heat off a warm surface (a TEG panel backing, a condenser "
    "shell) but never mount it directly on anything that can exceed roughly 500 C or the fins slump and "
    "melt. Its self-passivating oxide layer gives it moderate, not excellent, corrosion resistance -- prefer "
    "S316 in a chloride/acid environment.",
    {"width": 24, "fins": 5, "fin_height": 10},
    [
        {"box": "AL61", "at": [0, 0], "size": ["width", 2], "id": "hs_base"},
        {
            "repeat": "fins",
            "at": [1, 2],
            "step": ["(width-2)//fins", 0],
            "part": {"box": "AL61", "at": [0, 0], "size": [2, "fin_height"]},
        },
    ],
)

# 20. sic_crucible --------------------------------------------------------
add(
    "sic_crucible",
    "Silicon-carbide crucible: an SIC vessel holding an AL61 metal charge ready to be melted.",
    "SiC sublimes/decomposes only around 2700 C, comfortably above the melting point of any metal charge "
    "you would put in it, and conducts heat fast and evenly (120 W/mK) into the melt; its PROP_CONDUCTS also "
    "reflects SiC's real use as a wide-bandgap power-semiconductor material outside of crucible service. "
    "Pair this with a jacketed HEAC/WIFI element beneath (see the insulated_heat_source practice) to actually "
    "melt the charge -- do not let AERO or other insulation touch the outside if the heating method needs "
    "direct thermal contact with the crucible wall.",
    {"width": 16, "height": 14},
    [
        {"box": "SIC", "at": [0, 0], "size": ["width", "height"], "hollow": 2, "id": "sic_vessel"},
        {"box": "AL61", "at": [2, "height-6"], "size": ["width-4", 4], "id": "sic_charge"},
    ],
)

# --------------------------------------------------------------------------
os.makedirs(MODDIR, exist_ok=True)
for m in MODULES:
    path = os.path.join(MODDIR, f"{m['name']}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=1, sort_keys=True)
    print("wrote", path)
print(f"total {len(MODULES)} modules")
