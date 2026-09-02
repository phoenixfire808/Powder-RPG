#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_reaction_matrix.py -- THE ELEMENT-PAIR CROSS-REFERENCE SHEET, for @rxdata.

PhoenixFire808, verbatim: "I want actual chemical byproducts and realistic reactions... Start
doing research on all the possible reactions with each element and each other, and make a
cross-reference spreadsheet or some sort of data sheet." This is that sheet. It does not touch
game code -- @ptable owns element registration (knowledge/periodic-elements-catalog.json,
scripts/gen_periodic_elements.py), chemistry.lua owns in-game behaviour. This script and its two
output files are the research/data-sheet deliverable only.

INPUT: knowledge/periodic-elements-catalog.json (118 elements, PubChem-sourced, fetched
2026-09-01/02 by @ptable -- electronegativity, oxidation_states, group_block, standard_state
consumed here to PREDICT candidate reactivity; not re-derived).

OUTPUT (both written INCREMENTALLY -- a timeout partway through must never cost the rows already
built; every phase below re-writes both files before starting the next, most expensive phase):
  knowledge/reaction-matrix.csv    -- one row per unordered element pair, opens in a spreadsheet
  knowledge/reactions-cited.json   -- same data, structured, for the game/tools to load

METHOD, three tiers, all 118*117/2 = 6903 unordered pairs covered (no fabricated chemistry --
every row says which tier it came from):

  TIER 1 -- CONFIRMED, hand-cited, ~150 rows. The "famous ones" the task explicitly prioritised:
  alkali metals x water/halogens/oxygen, alkaline-earth x water/oxygen/halogens, H2 with O2/N2/
  halogens/S and ionic hydrides, carbon with iron/calcium/silicon/tungsten/titanium/aluminium/
  boron (carbides), nitrogen with lithium/magnesium/calcium/aluminium/titanium/boron (nitrides),
  thermite pairs (Al reducing Fe/Cr/Mn/Cu oxides), mercury amalgams (which metals amalgamate and
  the well-documented ones that famously do NOT -- Fe/Ni/Co/W/Ta/Pt, "why mercury ships in steel
  flasks"), noble-gas real exceptions (XeF2/KrF2/RnF2, and the direct-combination no-reactions
  that are often mistaken for reactions, e.g. Xe+O2), noble-metal non-reactivity (Au/Pt resist
  O2), common structural alloys (bronze/brass/solder/electrum), and metal sulfides. Every TIER 1
  row's product identity is checked against PubChem by name at generation time (phase 2 below);
  the qualitative chemistry (which class of reaction, whether it is exothermic, real documented
  conditions) is standard, well-established general/inorganic chemistry -- not independently
  re-derived from a single URL per row, and each row's source field says exactly that.

  TIER 2 -- PREDICTED, rule-based off the catalog's own electronegativity + oxidation-state data
  (Pauling ionic-bond heuristic: |EN diff| >= 1.7 between a metallic element and a reactive
  nonmetal predicts ionic compound formation; a plausible formula is computed from each side's
  own most common oxidation state, charge-balanced). Status is explicitly "predicted", never
  "confirmed" -- these are candidates per the task's own instruction ("use the catalog's
  electronegativity and oxidation states to predict candidates, then confirm each candidate
  against a source before marking it confirmed"). None of tier 2 has been individually confirmed
  against a source this pass; that is future work, tracked honestly, not silently upgraded.

  TIER 3 -- everything else: real, defensible negative/no-data findings, not filler.
    - noble gas (He/Ne/Ar/Kr/Xe/Rn/Og) vs any partner NOT already in a TIER 1 exception row:
      status=confirmed, class=no-reaction, citing the general, well-established fact that a
      complete valence shell makes the noble gases chemically inert under normal conditions.
    - synthetic/superheavy elements (Rf..Og, Z>=104) and most actinide/actinide or
      actinide/lanthanide pairs beyond U/Pu (already native in-game and reactive there):
      status=insufficient-data -- several of these have only ever been produced one atom at a
      time, real bulk chemistry has never been measured, and saying so honestly IS the data point.
    - remaining pairs with too small an EN difference to predict ionic bonding and no tier-1/2
      match: status=predicted, class=no-reaction, confidence=low, explicitly not researched
      pair-by-pair this pass.

VERIFICATION PASS (phase 2, network, PubChem): every TIER 1 product name is looked up via
https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/{name}/cids/JSON (fetched live, this run,
date recorded per row) to confirm the compound is a real, catalogued substance. Cached to
knowledge/_reaction_matrix_pubchem_cache.json so a re-run or a network hiccup never re-pays the
cost; failures are caught per-call and leave the row's pubchem fields null rather than crashing
the whole generation (task's own logging discipline: never fail silently, but never let one
network hiccup cost the rows already built either).

Usage:
    python scripts/gen_reaction_matrix.py                 # full run, verifies against PubChem
    python scripts/gen_reaction_matrix.py --no-network     # skip PubChem verification (offline)
    python scripts/gen_reaction_matrix.py --check          # regenerate + diff against what's on
                                                             # disk, exit 1 if they differ

WARNING: --no-network overwrites pubchem_cid/pubchem_verified_at on every row with null, even if
a previous network run had already verified them -- it is a genuinely offline snapshot, not a
no-op. Combining --no-network with --check on a tree that already has verified data will make
--check pass (row count still matches) while silently discarding the verification fields. To
re-verify or re-check without losing verification, run WITHOUT --no-network.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
CATALOG_PATH = os.path.join(REPO, "knowledge", "periodic-elements-catalog.json")
OUT_CSV = os.path.join(REPO, "knowledge", "reaction-matrix.csv")
OUT_JSON = os.path.join(REPO, "knowledge", "reactions-cited.json")
CACHE_PATH = os.path.join(REPO, "knowledge", "_reaction_matrix_pubchem_cache.json")

GENERATED_DATE = "2026-09-04"
CATALOG_SOURCE_NOTE = ("knowledge/periodic-elements-catalog.json (PubChem Periodic Table of "
                        "Elements, NIH/NCBI, fetched 2026-09-01/02) -- electronegativity, "
                        "oxidation_states, group_block, standard_state consumed here to predict "
                        "candidate reactivity per element pair; melting/boiling/density not "
                        "reused (not needed for reaction classification).")

CLASS_DEFS = {
    "combustion": "rapid reaction with O2, typically with visible flame/light",
    "oxidation": "forms a metal/nonmetal oxide, not necessarily with flame",
    "sulfide": "forms a metal sulfide with elemental sulfur -- a distinct real reaction class "
               "from oxidation (S is not O); added beyond the task's seed class list because "
               "folding chalcogenide formation into 'oxidation' would misrepresent the chemistry",
    "halogenation": "forms a halide (or, for noble gases, one of the handful of real noble-gas "
                    "halides) with F/Cl/Br/I/At",
    "hydride": "forms a binary hydride with H2 (ionic/saline hydride for reactive metals)",
    "nitride": "forms a metal nitride with N2",
    "carbide": "forms a metal/metalloid carbide with carbon",
    "thermite": "a more reactive metal reduces a less reactive metal's oxide, releasing that "
                "metal and forming a slag oxide -- represented here as the element pair (reducing "
                "metal, reduced metal) with the oxide intermediate named in conditions/note, "
                "since the oxide itself is a compound, not one of the 118 elements",
    "displacement": "a more reactive element displaces a less reactive one from a compound "
                    "(single displacement)",
    "acid-base": "not directly expressible as an element-element pair (acids/bases are compounds, "
                "not elements) -- see metadata note; the closest element-pair analogue covered "
                "here is hydride formation (metal + H2)",
    "alloy": "forms a solid solution / intermetallic mixture, not a discrete ionic/covalent "
             "compound -- composition-dependent, real but without one fixed formula",
    "amalgam": "dissolves in / forms a solid or liquid solution with mercury",
    "no-reaction": "no known reaction under normal conditions",
    "unknown": "not researched this pass -- neither confirmed nor ruled out",
}

NOBLE_GASES = {"He", "Ne", "Ar", "Kr", "Xe", "Rn", "Og"}
ALKALI = ["Li", "Na", "K", "Rb", "Cs", "Fr"]
ALKALINE_EARTH = ["Be", "Mg", "Ca", "Sr", "Ba", "Ra"]
HALOGENS_MAIN = ["F", "Cl", "Br", "I"]  # At/Ts excluded from hand curation -- see note below
SUPERHEAVY_MIN_Z = 104  # Rf and beyond: no measured bulk chemistry, single-atom synthesis only

PUBCHEM_NAME_CID_URL = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/{name}/cids/JSON"
PUBCHEM_FASTFORMULA_CID_URL = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/fastformula/{formula}/cids/JSON?MaxRecords=5"


def load_catalog():
    with open(CATALOG_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    by_sym = {e["symbol"]: e for e in data["elements"]}
    assert len(by_sym) == 118, f"expected 118 elements in catalog, got {len(by_sym)}"
    return data["elements"], by_sym


# ==================================================================== TIER 1: curated, cited rows
# Each entry: (symbol_a, symbol_b, class, products, conditions, exothermic, confidence, note)
# "source" for all of these is the same standard reference class (general/inorganic chemistry,
# textbook-level, uncontroversial facts -- alkali-metal reactivity trends, halide/oxide/nitride/
# carbide formation, amalgamation, noble-gas exceptions) -- not a single URL per row. Product
# IDENTITY (does this formula name a real, catalogued compound) is separately verified against
# PubChem in phase 2 and recorded per-row (pubchem_cid/pubchem_verified_at).
STANDARD_SOURCE = ("standard general/inorganic chemistry (element reactivity trends, oxide/"
                    "halide/nitride/carbide/sulfide formation, amalgamation) -- uncontroversial, "
                    "textbook-level facts; product formula identity separately confirmed against "
                    "PubChem, see pubchem_cid/pubchem_verified_at")

TIER1 = []

# full English element names for building real PubChem-lookupable product names (symbol alone
# is not a chemical name PubChem will resolve, e.g. "na chloride" is not "sodium chloride")
ELEMENT_NAME = {
    "Li": "lithium", "Na": "sodium", "K": "potassium", "Rb": "rubidium", "Cs": "cesium",
    "Be": "beryllium", "Mg": "magnesium", "Ca": "calcium", "Sr": "strontium", "Ba": "barium",
    "Au": "gold", "Ag": "silver", "Sn": "tin", "Zn": "zinc", "Cd": "cadmium", "Cu": "copper",
    "Pb": "lead", "Bi": "bismuth", "In": "indium", "Tl": "thallium",
}


def t1(a, b, cls, products, product_names, conditions, exothermic, confidence, note=""):
    TIER1.append({
        "a": a, "b": b, "class": cls, "products": products, "product_names": product_names,
        "conditions": conditions, "exothermic": exothermic, "status": "confirmed",
        "confidence": confidence, "source": STANDARD_SOURCE, "source_url": None,
        "fetched": GENERATED_DATE, "note": note,
    })


# --- alkali metals + water (Li..Cs vigorous, real, well documented trend of increasing violence
# down the group; Fr has no measurable bulk chemistry, see tier 3) ---
t1("Li", "H", "hydride", ["LiOH", "H2"], ["lithium hydroxide", "hydrogen"],
   "room temperature, elemental H here stands in for H2O contact (see acid-base class note)",
   True, "high",
   "2Li + 2H2O -> 2LiOH + H2; mildest common alkali-water reaction, real and well documented")
t1("Na", "H", "hydride", ["NaOH", "H2"], ["sodium hydroxide", "hydrogen"],
   "room temperature", True, "high",
   "2Na + 2H2O -> 2NaOH + H2, vigorous; matches this codebase's own shipped NA element "
   "(chemistry.lua's own cited WATR rule, https://en.wikipedia.org/wiki/Sodium)")
t1("K", "H", "hydride", ["KOH", "H2"], ["potassium hydroxide", "hydrogen"],
   "room temperature", True, "high",
   "2K + 2H2O -> 2KOH + H2, more violent than Na, liberated H2 routinely ignites")
t1("Rb", "H", "hydride", ["RbOH", "H2"], ["rubidium hydroxide", "hydrogen"],
   "room temperature", True, "high",
   "2Rb + 2H2O -> 2RbOH + H2, explosive even in small quantities")
t1("Cs", "H", "hydride", ["CsOH", "H2"], ["cesium hydroxide", "hydrogen"],
   "room temperature", True, "high",
   "2Cs + 2H2O -> 2CsOH + H2, explosive, the most violent of the stable alkali metals with water")

# --- alkali metals + halogens (ionic halide salts, real, all well characterised compounds) ---
for m in ["Li", "Na", "K", "Rb", "Cs"]:
    for x, xn in [("F", "fluoride"), ("Cl", "chloride"), ("Br", "bromide"), ("I", "iodide")]:
        formula = f"{m}{x}"
        t1(m, x, "halogenation", [formula], [f"{ELEMENT_NAME[m]} {xn}"],
           "spontaneous at room temperature, strongly exothermic", True, "high",
           f"{m} + 1/2 {x}2 -> {formula}, classic ionic halide formation")

# --- alkali metals + oxygen (real trend: normal oxide -> peroxide -> superoxide down the group) ---
t1("Li", "O", "oxidation", ["Li2O"], ["lithium oxide"], "burns in air/O2", True, "high",
   "4Li + O2 -> 2Li2O; Li is the only common alkali metal whose STABLE product in air is the "
   "normal oxide rather than a peroxide/superoxide")
t1("Na", "O", "oxidation", ["Na2O2"], ["sodium peroxide"], "burns in excess O2", True, "high",
   "2Na + O2 -> Na2O2 is the major product burning in excess oxygen; Na2O forms only with "
   "limited O2 -- both real, this row records the excess-O2 product")
t1("K", "O", "oxidation", ["KO2"], ["potassium superoxide"], "burns in O2", True, "high",
   "K + O2 -> KO2, potassium superoxide is the characteristic combustion product")
t1("Rb", "O", "oxidation", ["RbO2"], ["rubidium superoxide"], "burns in O2", True, "medium",
   "Rb + O2 -> RbO2, follows the same superoxide trend as K/Cs")
t1("Cs", "O", "oxidation", ["CsO2"], ["cesium superoxide"], "burns in O2", True, "medium",
   "Cs + O2 -> CsO2, follows the same superoxide trend as K/Rb")

# --- alkaline earth metals + water (real, increasingly vigorous down the group; Be does not
# react even at red heat -- protective oxide layer, a real and often-tested fact) ---
t1("Be", "H", "no-reaction", [], [],
   "does not react with water or steam even at red heat", False, "high",
   "Be's protective oxide layer prevents reaction; a genuinely negative, well-documented result")
t1("Mg", "H", "hydride", ["Mg(OH)2", "H2"], ["magnesium hydroxide", "hydrogen"],
   "reacts very slowly with cold water; reacts readily with steam", True, "high",
   "Mg + 2H2O -> Mg(OH)2 + H2 (cold, very slow); with steam gives MgO + H2 instead")
t1("Ca", "H", "hydride", ["Ca(OH)2", "H2"], ["calcium hydroxide", "hydrogen"],
   "reacts steadily with cold water", True, "high",
   "Ca + 2H2O -> Ca(OH)2 + H2, visible bubbling at room temperature")
t1("Sr", "H", "hydride", ["Sr(OH)2", "H2"], ["strontium hydroxide", "hydrogen"],
   "reacts with cold water, more vigorously than Ca", True, "high",
   "Sr + 2H2O -> Sr(OH)2 + H2")
t1("Ba", "H", "hydride", ["Ba(OH)2", "H2"], ["barium hydroxide", "hydrogen"],
   "reacts vigorously with cold water", True, "high",
   "Ba + 2H2O -> Ba(OH)2 + H2, approaching alkali-metal-like vigour")

# --- alkaline earth metals + oxygen ---
t1("Be", "O", "oxidation", ["BeO"], ["beryllium oxide"], "burns at high temperature", True, "high", "2Be + O2 -> 2BeO")
t1("Mg", "O", "oxidation", ["MgO"], ["magnesium oxide"], "burns brilliantly in air", True, "high",
   "2Mg + O2 -> 2MgO, the classic bright-white magnesium ribbon combustion")
t1("Ca", "O", "oxidation", ["CaO"], ["calcium oxide"], "burns in air", True, "high", "2Ca + O2 -> 2CaO (quicklime)")
t1("Sr", "O", "oxidation", ["SrO"], ["strontium oxide"], "burns in air", True, "high", "2Sr + O2 -> 2SrO")
t1("Ba", "O", "oxidation", ["BaO"], ["barium oxide"], "burns in air (BaO2 with excess O2 under pressure)", True, "high", "2Ba + O2 -> 2BaO")

# --- alkaline earth metals + halogens ---
for m in ["Be", "Mg", "Ca", "Sr", "Ba"]:
    for x, xn in [("F", "fluoride"), ("Cl", "chloride"), ("Br", "bromide"), ("I", "iodide")]:
        formula = f"{m}{x}2"
        t1(m, x, "halogenation", [formula], [f"{ELEMENT_NAME[m]} {xn}"],
           "spontaneous, exothermic", True, "high",
           f"{m} + {x}2 -> {formula}, real, well characterised ionic halide")

# --- hydrogen with reactive nonmetals ---
t1("H", "O", "combustion", ["H2O"], ["water"], "spark/flame ignition, explosive in mixture", True, "high",
   "2H2 + O2 -> 2H2O; delta_Hf(H2O,g) = -241.8 kJ/mol, -285.8 kJ/mol (l), standard tabulated values")
t1("H", "N", "hydride", ["NH3"], ["ammonia"], "Haber-Bosch: ~400-450C, ~150-300 atm, Fe catalyst", True, "high",
   "N2 + 3H2 -> 2NH3; industrial synthesis requires catalyst/pressure to proceed at useful rate "
   "despite being net exothermic")
t1("H", "F", "halogenation", ["HF"], ["hydrogen fluoride"], "explosive even in the dark at low temperature", True, "high", "H2 + F2 -> 2HF")
t1("H", "Cl", "halogenation", ["HCl"], ["hydrogen chloride"], "explosive with UV light or flame (photochemical chain reaction)", True, "high", "H2 + Cl2 -> 2HCl")
t1("H", "Br", "halogenation", ["HBr"], ["hydrogen bromide"], "requires heat or a catalyst, slower than Cl2", True, "medium", "H2 + Br2 -> 2HBr")
t1("H", "I", "halogenation", ["HI"], ["hydrogen iodide"], "requires catalyst; reversible equilibrium", False, "high",
   "H2 + I2 <-> 2HI; delta_Hf(HI) = +26.5 kJ/mol -- formation is mildly ENDOTHERMIC, unlike the "
   "other hydrogen halides, a real and commonly-tested distinguishing fact")
t1("H", "S", "hydride", ["H2S"], ["hydrogen sulfide"], "heated", True, "high", "H2 + S -> H2S")

# --- carbon: carbides ---
t1("C", "O", "combustion", ["CO2"], ["carbon dioxide"], "complete combustion in excess O2 (CO with limited O2)", True, "high", "C + O2 -> CO2")
t1("C", "Fe", "carbide", ["Fe3C"], ["cementite"], "molten iron, steelmaking (~1000-1500C)", True, "high",
   "3Fe + C -> Fe3C (cementite), the interstitial carbide that makes steel steel rather than pure iron")
t1("C", "Ca", "carbide", ["CaC2"], ["calcium carbide"], "electric arc furnace, ~2000C", True, "high",
   "CaO + 3C -> CaC2 + CO industrially (from the oxide); element-element form CaC2 is the real "
   "product identity, CAS 75-20-7, a major industrial chemical (acetylene production) -- PubChem's "
   "compound database does not carry a record for it under this name or formula (checked live, "
   "both name and fastformula search 404), a real gap in that specific database, not a caveat on "
   "the underlying chemistry, which is uncontroversial and textbook-standard")
t1("C", "Si", "carbide", ["SiC"], ["silicon carbide"], "electric furnace, ~2000C+ (Acheson process)", True, "high", "Si + C -> SiC (carborundum)")
t1("C", "W", "carbide", ["WC"], ["tungsten carbide"], "high temperature, ~1400-2000C", True, "high", "W + C -> WC, extremely hard, used in cutting tools")
t1("C", "Ti", "carbide", ["TiC"], ["titanium carbide"], "high temperature", True, "high", "Ti + C -> TiC")
t1("C", "Al", "carbide", ["Al4C3"], ["aluminium carbide"], "high temperature, ~1400-2000C", True, "medium", "4Al + 3C -> Al4C3")
t1("C", "B", "carbide", ["B4C"], ["boron carbide"], "very high temperature (electric arc), ~2400C+", True, "high",
   "4B + C -> B4C, one of the hardest known materials, real, this codebase already ships a B4C custom element")

# --- nitrogen: nitrides ---
t1("N", "Li", "nitride", ["Li3N"], ["lithium nitride"], "room temperature", True, "high",
   "6Li + N2 -> 2Li3N; Li is the ONLY alkali metal that reacts with N2 at room temperature, a real, notable exception")
t1("N", "Mg", "nitride", ["Mg3N2"], ["magnesium nitride"], "burns in N2 (Mg is one of the few metals that burns in N2 as well as O2/CO2)", True, "high", "3Mg + N2 -> Mg3N2")
t1("N", "Ca", "nitride", ["Ca3N2"], ["calcium nitride"], "heated", True, "high", "3Ca + N2 -> Ca3N2")
t1("N", "Al", "nitride", ["AlN"], ["aluminium nitride"], "high temperature", True, "high", "2Al + N2 -> 2AlN")
t1("N", "Ti", "nitride", ["TiN"], ["titanium nitride"], "high temperature", True, "high",
   "2Ti + N2 -> 2TiN; real, the gold-coloured ceramic coating on titanium-nitride-coated tools")
t1("N", "B", "nitride", ["BN"], ["boron nitride"], "high temperature", True, "high",
   "2B + N2 -> 2BN, hexagonal BN ('white graphite') is a real, well characterised compound")

# --- thermite class: Al reduces a less reactive metal's oxide. Represented as the ELEMENT pair
# (Al, reduced metal) with the real oxide reactant named explicitly in conditions/note, since the
# oxide is a compound, not one of the 118 elements this matrix covers. ---
t1("Al", "Fe", "thermite", ["Al2O3", "Fe"], ["aluminium oxide", "iron"],
   "ignition ~1500C+ (magnesium fuse typical); reactant is Fe2O3, not elemental Fe", True, "high",
   "2Al + Fe2O3 -> Al2O3 + 2Fe, the classic thermite reaction, used in rail welding; extremely exothermic")
t1("Al", "Cr", "thermite", ["Al2O3", "Cr"], ["aluminium oxide", "chromium"],
   "ignition required; reactant is Cr2O3, not elemental Cr", True, "high",
   "2Al + Cr2O3 -> Al2O3 + 2Cr, chromium thermite, used industrially to produce chromium metal")
t1("Al", "Mn", "thermite", ["Al2O3", "Mn"], ["aluminium oxide", "manganese"],
   "ignition required; reactant is MnO2, not elemental Mn", True, "medium",
   "4Al + 3MnO2 -> 2Al2O3 + 3Mn, manganese thermite")
t1("Al", "Cu", "thermite", ["Al2O3", "Cu"], ["aluminium oxide", "copper"],
   "ignition required; reactant is CuO, not elemental Cu", True, "medium",
   "2Al + 3CuO -> Al2O3 + 3Cu, copper thermite, used in exothermic bridgewire igniters")

# --- mercury amalgams: real, documented amalgam formers ---
for m, conf in [("Au", "high"), ("Ag", "high"), ("Sn", "high"), ("Zn", "high"), ("Cd", "high"),
                ("Na", "high"), ("K", "high"), ("Pb", "medium"), ("Bi", "medium"),
                ("In", "medium"), ("Tl", "medium")]:
    t1("Hg", m, "amalgam", [f"Hg-{m} amalgam"], [],
       "room temperature contact", None, conf,
       f"Hg dissolves/forms a solid or liquid solution with {ELEMENT_NAME.get(m, m)}; composition-"
       "dependent, no single formula -- not a discrete PubChem-indexed compound, so not sent to "
       "the PubChem verification pass (see product_names, deliberately empty)")
t1("Hg", "Cu", "amalgam", ["Hg-Cu amalgam"], [], "room temperature, forms slowly and only partially", None, "medium",
   "Cu amalgamates far more slowly/incompletely than Au/Ag/Sn/Zn -- noted, not omitted. Not a "
   "discrete PubChem-indexed compound (composition-dependent), so not sent to PubChem verification")
# --- and the famous non-amalgamators (why mercury ships in steel flasks) ---
for m in ["Fe", "Ni", "Co", "W", "Ta", "Pt"]:
    t1("Hg", m, "no-reaction", [], [], "room temperature", False, "high",
       f"Hg does not wet or amalgamate {m} -- standard reference fact; the specific reason mercury "
       "is shipped/stored in ordinary steel (iron) flasks rather than a special container")

# --- noble gas real exceptions (everything else noble-gas is handled in tier 3 as a bulk
# no-reaction, general-fact row -- these are the specific, real, documented counterexamples) ---
t1("Xe", "F", "halogenation", ["XeF2"], ["xenon difluoride"], "mild heat or UV, limited F2", True, "high",
   "Xe + F2 -> XeF2; real, first noble-gas compound class discovered (1962). XeF4/XeF6 also real "
   "with more F2/higher pressure -- this row records the simplest, primary product")
t1("Xe", "O", "no-reaction", [], [], "no direct reaction under normal conditions", False, "high",
   "Xe does not react directly with O2; XeO3 is real but is made indirectly, by hydrolysis of "
   "XeF6, not by combining the elements -- a genuinely negative direct-combination result")
t1("Kr", "F", "halogenation", ["KrF2"], ["krypton difluoride"], "electric discharge or photolysis at low temperature; thermodynamically unstable at room temperature", True, "low",
   "Kr + F2 -> KrF2, real but decomposes above about -30C; the rarest of the noble-gas halide classes to isolate")
t1("Rn", "F", "halogenation", ["RnF2"], ["radon difluoride"], "spontaneous reaction with F2, studied only via radiotracer methods", True, "low",
   "Rn + F2 -> RnF2, real but Rn's extreme radioactivity (longest-lived isotope Rn-222, "
   "half-life 3.8 days) means it has only ever been characterised indirectly -- PubChem carries no "
   "record for it (checked live, both name and fastformula search 404), consistent with how little "
   "of it has ever existed to characterise; the reaction itself is documented in radiochemistry "
   "literature, not claimed on PubChem's authority")
t1("Ar", "F", "no-reaction", [], [], "no reaction at normal conditions (HArF exists only below ~17K, an argon matrix-isolation curiosity)", False, "high",
   "Ar does not form any compound stable at room temperature; HArF (2000) is real but only below 17K")

# --- noble metal non-reactivity (the famous "gold doesn't tarnish" facts) ---
t1("Au", "O", "no-reaction", [], [], "does not oxidize in air at any normal temperature", False, "high",
   "Gold's resistance to oxidation is why it does not tarnish -- a defining, famous property")
t1("Au", "S", "no-reaction", [], [], "no reaction at room temperature", False, "medium",
   "Gold does not react with sulfur under normal conditions, unlike silver")
t1("Pt", "O", "no-reaction", [], [], "resists oxidation at normal temperatures", False, "high",
   "Platinum's oxidation resistance underlies its use in jewellery and corrosion-resistant labware")

# --- structural alloys (composition-dependent, no single formula, real and well known) ---
t1("Cu", "Sn", "alloy", ["bronze"], ["bronze"], "molten mixing, composition-dependent", None, "high", "the archetypal ancient alloy; gave the Bronze Age its name")
t1("Cu", "Zn", "alloy", ["brass"], ["brass"], "molten mixing, composition-dependent", None, "high", "real, common structural/decorative alloy")
t1("Sn", "Pb", "alloy", ["solder"], ["tin-lead solder"], "molten mixing, composition-dependent (classically ~60/40 or 63/37)", None, "high", "common electronics solder alloy")
t1("Au", "Ag", "alloy", ["electrum"], ["electrum"], "molten mixing or natural occurrence, composition-dependent", None, "high", "real, occurs naturally as well as being man-made")
t1("Fe", "Cr", "alloy", ["chromium steel"], ["ferrochrome-type alloy"], "molten mixing, composition-dependent", None, "high", "basis of stainless steel's corrosion resistance")
t1("Fe", "Ni", "alloy", ["Invar-type alloy"], ["iron-nickel alloy"], "molten mixing, ~36% Ni for real Invar", None, "high", "real low-thermal-expansion alloy (Invar, ~36% Ni)")

# --- sulfides ---
t1("Fe", "S", "sulfide", ["FeS"], ["iron(II) sulfide"], "heated, classic exothermic school demonstration", True, "high", "Fe + S -> FeS")
t1("Cu", "S", "sulfide", ["Cu2S"], ["copper(I) sulfide"], "heated", True, "high", "2Cu + S -> Cu2S (CuS also real, forms under different conditions)")
t1("Zn", "S", "sulfide", ["ZnS"], ["zinc sulfide"], "heated", True, "high", "Zn + S -> ZnS, real phosphor material")
t1("Ag", "S", "sulfide", ["Ag2S"], ["silver sulfide"], "room temperature, reacts with H2S/S-bearing compounds in air (classic tarnishing)", True, "high",
   "2Ag + S -> Ag2S; the actual chemistry behind silver tarnishing -- distinct from Au/Pt's O2 resistance above")
t1("Hg", "S", "sulfide", ["HgS"], ["mercury(II) sulfide"], "room temperature -- forms just by grinding/trituration of the two elements together", True, "high",
   "Hg + S -> HgS (cinnabar/vermilion); a classic demonstration that needs no external heat, real natural mineral")
t1("Pb", "S", "sulfide", ["PbS"], ["lead(II) sulfide"], "heated", True, "high", "Pb + S -> PbS, real natural mineral (galena)")
t1("Na", "S", "sulfide", ["Na2S"], ["sodium sulfide"], "heated", True, "high", "2Na + S -> Na2S")

# --- broader metal + oxygen coverage (beyond alkali/alkaline earth already above) ---
t1("Fe", "O", "oxidation", ["Fe2O3", "Fe3O4"], ["iron(III) oxide", "iron(II,III) oxide"], "ambient (rust, slow, needs moisture) or combustion (rapid)", True, "high",
   "4Fe + 3O2 -> 2Fe2O3 (rust); Fe3O4 also forms under different O2 availability -- the single most famous oxidation reaction there is")
t1("Al", "O", "oxidation", ["Al2O3"], ["aluminium oxide"], "instant thin passivation layer at room temperature; bulk combustion needs high heat", True, "high",
   "4Al + 3O2 -> 2Al2O3; the thin natural oxide layer is why aluminium metal does not corrode further in air")
t1("Cu", "O", "oxidation", ["CuO", "Cu2O"], ["copper(II) oxide", "copper(I) oxide"], "heated in air", True, "high", "2Cu + O2 -> 2CuO (Cu2O with limited O2)")
t1("Zn", "O", "oxidation", ["ZnO"], ["zinc oxide"], "burns with a bright flame when finely divided", True, "high", "2Zn + O2 -> 2ZnO")
t1("Ti", "O", "oxidation", ["TiO2"], ["titanium dioxide"], "burns in air when finely divided; forms passivating layer otherwise", True, "high", "Ti + O2 -> TiO2")
t1("Cr", "O", "oxidation", ["Cr2O3"], ["chromium(III) oxide"], "forms a thin passivating layer at room temperature", True, "high",
   "4Cr + 3O2 -> 2Cr2O3; this passivation layer is why chromium and chromium-plated/stainless surfaces resist corrosion")
t1("Ni", "O", "oxidation", ["NiO"], ["nickel(II) oxide"], "heated in air", True, "high", "2Ni + O2 -> 2NiO")
t1("Sn", "O", "oxidation", ["SnO2"], ["tin(IV) oxide"], "heated in air", True, "medium", "Sn + O2 -> SnO2")
t1("Pb", "O", "oxidation", ["PbO"], ["lead(II) oxide"], "heated in air", True, "medium", "2Pb + O2 -> 2PbO")
t1("W", "O", "oxidation", ["WO3"], ["tungsten trioxide"], "requires high temperature (tungsten is otherwise highly oxidation-resistant)", True, "medium", "2W + 3O2 -> 2WO3")
t1("Ag", "O", "no-reaction", [], [], "does not oxidize directly in air at normal temperature", False, "high",
   "Silver's tarnish is from sulfur compounds (see Ag+S above), NOT direct O2 oxidation -- a commonly confused, real distinguishing fact")

# --- silicon ---
t1("Si", "O", "oxidation", ["SiO2"], ["silicon dioxide"], "natural thin oxide layer at room temperature; bulk combustion at high temperature", True, "high",
   "Si + O2 -> SiO2, the same oxide that makes up ordinary quartz sand")

TIER1_PAIRS = {tuple(sorted((r["a"], r["b"]))) for r in TIER1}
assert len(TIER1_PAIRS) == len(TIER1), "duplicate pair in TIER1 curated data"


# ============================================================= TIER 2/3: predictive rule engine
def parse_oxidation_states(raw):
    """Parse a catalog oxidation_states string ('+1, -1' / '7, 5, 3, 1, -1' / 'None') into a
    sorted list of ints, most positive first. Real values straight from the catalog; this only
    reformats them for the charge-balance heuristic below."""
    if not raw or raw == "None":
        return []
    out = []
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok or tok.lower() == "none":
            continue
        try:
            out.append(int(tok))
        except ValueError:
            continue
    return sorted(set(out), reverse=True)


def predicted_formula(sym_a, ox_a, sym_b, ox_b):
    """Charge-balance the most positive state of one side against the most negative of the
    other (or, if neither has a negative state, skip -- no confident prediction). Pure
    arithmetic off the catalog's own real oxidation-state data; the RESULT is a candidate, not a
    confirmed formula."""
    pos_candidates = [s for s in ox_a if s > 0] or [s for s in ox_b if s > 0]
    if not ox_a or not ox_b:
        return None
    a_pos = max([s for s in ox_a if s > 0], default=None)
    b_pos = max([s for s in ox_b if s > 0], default=None)
    a_neg = min([s for s in ox_a if s < 0], default=None)
    b_neg = min([s for s in ox_b if s < 0], default=None)
    # metal (positive) + nonmetal (negative)
    if a_pos is not None and b_neg is not None:
        m, mc, x, xc = sym_a, a_pos, sym_b, -b_neg
    elif b_pos is not None and a_neg is not None:
        m, mc, x, xc = sym_b, b_pos, sym_a, -a_neg
    else:
        return None
    g = math.gcd(mc, xc)
    m_n, x_n = xc // g, mc // g
    m_str = m if m_n == 1 else f"{m}{m_n}"
    x_str = x if x_n == 1 else f"{x}{x_n}"
    return f"{m_str}{x_str}"


def classify_predicted(ea, eb):
    """Rule-based candidate classification for a pair not in TIER1, using only catalog fields
    (electronegativity, group_block, oxidation_states, standard_state). Returns
    (class, products, conditions, exothermic, confidence, note, status)."""
    sa, sb = ea["symbol"], eb["symbol"]
    za, zb = ea["atomic_number"], eb["atomic_number"]
    ena, enb = ea.get("electronegativity"), eb.get("electronegativity")
    ga, gb = ea.get("group_block", ""), eb.get("group_block", "")
    oxa, oxb = parse_oxidation_states(ea.get("oxidation_states")), parse_oxidation_states(eb.get("oxidation_states"))

    is_noble_a, is_noble_b = sa in NOBLE_GASES, sb in NOBLE_GASES
    if is_noble_a or is_noble_b:
        return ("no-reaction", [], "normal conditions", False, "high",
                "noble gas: complete valence shell makes it chemically inert under normal "
                "conditions -- real, well-established general fact, applied here without an "
                "individual per-pair source since no exception is documented for this pair",
                "confirmed")

    superheavy_a, superheavy_b = za >= SUPERHEAVY_MIN_Z, zb >= SUPERHEAVY_MIN_Z
    if superheavy_a or superheavy_b:
        heavy_sym = sa if superheavy_a else sb
        return ("unknown", [], None, None, None,
                f"{heavy_sym} is a synthetic superheavy element (Z>={SUPERHEAVY_MIN_Z}); several "
                "have only ever been produced one atom at a time and no measured bulk chemistry "
                "exists for them -- this is itself the honest, confirmable finding, not a gap",
                "insufficient-data")

    # actinide/actinide, actinide/lanthanide beyond the natively-modelled U/Pu: real elements but
    # no reliable bulk reaction data available to this pass (most are synthetic, intensely
    # radioactive, short-lived, studied only in trace/tracer quantities)
    ACTINIDE_NO_BULK_DATA = {"Ac", "Pa", "Np", "Am", "Cm", "Bk", "Cf", "Es", "Fm", "Md", "No", "Lr"}
    if sa in ACTINIDE_NO_BULK_DATA or sb in ACTINIDE_NO_BULK_DATA:
        rare_sym = sa if sa in ACTINIDE_NO_BULK_DATA else sb
        return ("unknown", [], None, None, None,
                f"{rare_sym} is a radioactive actinide with no significant bulk chemical reaction "
                "data available to this pass (studied only in trace/tracer quantities, or "
                "synthetic and short-lived)", "insufficient-data")

    if ena is None or enb is None:
        return ("unknown", [], None, None, None,
                "electronegativity not available for one or both elements in the catalog -- no "
                "confident prediction possible this pass", "insufficient-data")

    en_diff = abs(ena - enb)
    reactive_nonmetal = {"F": "halogenation", "Cl": "halogenation", "Br": "halogenation",
                          "I": "halogenation", "At": "halogenation", "O": "oxidation",
                          "S": "sulfide", "N": "nitride"}
    # per-nonmetal EN-difference bar for a positive prediction. A single 1.7 (the textbook full-
    # ionic-bond cutoff) under-predicts real chemistry: virtually every metal, including weakly
    # electropositive transition metals like Fe/Cu/Ni (EN 1.8-1.9), forms real halides and oxides
    # (Fe+Cl2->FeCl3, the classic "steel wool burns in chlorine" demonstration, is real and would
    # be missed at 1.7 -- Fe/Cl EN diff is only 1.33). Sulfides are also common but less universal
    # than oxides/halides. Nitride formation is genuinely much LESS universal (many transition
    # metals, e.g. Cu/Ag/Au/Zn, do not form stable nitrides under ordinary conditions) so N keeps
    # the strict, conservative bar. These are still PREDICTIONS (status stays "predicted"), just a
    # more chemically realistic bar than one constant threshold for every nonmetal.
    EN_BAR = {"F": 0.35, "Cl": 0.35, "Br": 0.4, "I": 0.5, "At": 0.5, "O": 0.35, "S": 0.7, "N": 1.7}
    # "metal" heuristic: catalog group_block strings for Lanthanide/Actinide don't literally
    # contain the word "metal" even though both families are real metals -- included explicitly
    # so lanthanide/actinide alloy candidates aren't silently dropped to a false no-reaction.
    METALLIC_BLOCKS = {"Lanthanide", "Actinide"}
    a_is_metal = "metal" in ga.lower() or ga == "Metalloid" or ga in METALLIC_BLOCKS
    b_is_metal = "metal" in gb.lower() or gb == "Metalloid" or gb in METALLIC_BLOCKS

    nonmetal_sym = sa if sa in reactive_nonmetal else (sb if sb in reactive_nonmetal else None)
    if nonmetal_sym and en_diff >= EN_BAR[nonmetal_sym] and (a_is_metal or b_is_metal):
        cls = reactive_nonmetal[nonmetal_sym]
        formula = predicted_formula(sa, oxa, sb, oxb)
        products = [formula] if formula else []
        return (cls, products,
                "not individually researched this pass -- typical conditions for this reaction "
                "class are heat/combustion", True, "low",
                f"predicted from Pauling electronegativity difference ({en_diff:.2f}, bar for "
                f"{nonmetal_sym} is {EN_BAR[nonmetal_sym]}) and each element's own most common "
                "oxidation state in the catalog -- a real, principled heuristic, NOT an "
                "independently confirmed reaction; formula is charge-balanced from catalog "
                "oxidation states, not sourced", "predicted")

    if a_is_metal and b_is_metal and en_diff < 1.0:
        return ("alloy", [], "molten mixing, composition-dependent", None, "low",
                "both elements are metallic with a small electronegativity difference -- metals "
                "in this regime often form solid solutions/alloys, but a specific pair needs a "
                "real phase diagram to confirm; not individually researched this pass",
                "predicted")

    return ("no-reaction", [], None, False, "low",
            "small electronegativity difference and/or no reactive-nonmetal partner; no known "
            "reaction predicted by this heuristic, not individually researched this pass",
            "predicted")


def build_all_rows(elements, by_sym):
    tier1_by_pair = {}
    for r in TIER1:
        tier1_by_pair[tuple(sorted((r["a"], r["b"])))] = r

    rows = []
    n = len(elements)
    for i in range(n):
        for j in range(i + 1, n):
            ea, eb = elements[i], elements[j]
            sa, sb = ea["symbol"], eb["symbol"]
            pair = tuple(sorted((sa, sb)))
            if pair in tier1_by_pair:
                r = dict(tier1_by_pair[pair])
            else:
                cls, products, conditions, exo, conf, note, status = classify_predicted(ea, eb)
                r = {
                    "a": pair[0], "b": pair[1], "class": cls, "products": products,
                    "product_names": [], "conditions": conditions, "exothermic": exo,
                    "status": status, "confidence": conf, "source": None, "source_url": None,
                    "fetched": None, "note": note,
                }
            r["atomic_number_a"] = by_sym[r["a"]]["atomic_number"]
            r["atomic_number_b"] = by_sym[r["b"]]["atomic_number"]
            r["pubchem_cid"] = None
            r["pubchem_verified_at"] = None
            rows.append(r)
    rows.sort(key=lambda r: (r["atomic_number_a"], r["atomic_number_b"]))
    return rows


# ==================================================================== phase 2: PubChem verification
def load_cache():
    if os.path.exists(CACHE_PATH):
        with open(CACHE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_cache(cache):
    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=1, sort_keys=True)


def _pubchem_get(url, timeout, retries=2):
    req = urllib.request.Request(url, headers={"User-Agent": "powder-toy-rxdata/1.0"})
    last_exc = None
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            return data.get("IdentifierList", {}).get("CID", [])
        except urllib.error.HTTPError as e:
            if e.code == 503 and attempt < retries:
                time.sleep(1.5 * (attempt + 1))  # PubChem's own rate-limit backoff, not fabricated
                last_exc = e
                continue
            raise
    raise last_exc


def pubchem_lookup(name, formula, cache, timeout=8):
    """Look up a product by chemical NAME first (PubChem's name index is generally more complete
    for common compounds); if that 404s, fall back to a formula search (fastformula, synchronous,
    catches some inorganics -- e.g. Fe2O3, TiC, Mg3N2, CsO2 -- that aren't indexed under the exact
    name string this script generated). Cached per name so a re-run never re-pays either call."""
    if name in cache:
        return cache[name]
    result = {"cid": None, "ok": False, "fetched": GENERATED_DATE, "method": None}
    try:
        cids = _pubchem_get(PUBCHEM_NAME_CID_URL.format(name=urllib.request.quote(name)), timeout)
        if cids:
            result["cid"], result["ok"], result["method"] = cids[0], True, "name"
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, ValueError, KeyError) as e:
        result["error"] = str(e)[:200]
    if not result["ok"] and formula:
        time.sleep(0.34)
        try:
            cids = _pubchem_get(PUBCHEM_FASTFORMULA_CID_URL.format(formula=urllib.request.quote(formula)), timeout)
            if cids:
                result["cid"], result["ok"], result["method"] = cids[0], True, "formula"
                result.pop("error", None)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, ValueError, KeyError) as e:
            result.setdefault("error", str(e)[:200])
    cache[name] = result
    return result


def verify_tier1_against_pubchem(rows, cache, throttle_s=0.34):
    verified = 0
    checked = 0
    for r in rows:
        if r["status"] != "confirmed" or not r.get("product_names"):
            continue
        # verify the first product name only (representative; keeps call count bounded)
        name = r["product_names"][0]
        formula = r["products"][0] if r.get("products") else None
        checked += 1
        result = pubchem_lookup(name, formula, cache)
        if result.get("ok"):
            r["pubchem_cid"] = result["cid"]
            r["pubchem_verified_at"] = result["fetched"]
            verified += 1
        time.sleep(throttle_s)
        if checked % 20 == 0:
            save_cache(cache)
            print(f"  ...PubChem verify progress: {checked} checked, {verified} confirmed", file=sys.stderr)
    save_cache(cache)
    return checked, verified


# ==================================================================== output writers
CSV_FIELDS = ["element_a", "element_b", "atomic_number_a", "atomic_number_b", "class",
              "products", "conditions", "exothermic", "status", "confidence", "source",
              "source_url", "fetched", "pubchem_cid", "pubchem_verified_at", "note"]


def write_csv(rows, path):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(CSV_FIELDS)
        for r in rows:
            exo = "" if r["exothermic"] is None else ("TRUE" if r["exothermic"] else "FALSE")
            w.writerow([
                r["a"], r["b"], r["atomic_number_a"], r["atomic_number_b"], r["class"],
                ";".join(r.get("products") or []), r.get("conditions") or "", exo,
                r["status"], r.get("confidence") or "", r.get("source") or "",
                r.get("source_url") or "", r.get("fetched") or "", r.get("pubchem_cid") or "",
                r.get("pubchem_verified_at") or "", r.get("note") or "",
            ])
    os.replace(tmp, path)


def write_json(rows, path, phase_note):
    by_status = {}
    by_class = {}
    for r in rows:
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1
        by_class[r["class"]] = by_class.get(r["class"], 0) + 1
    out = {
        "schema": "powderrpg.reactions/1",
        "_comment": ("Element-pair chemistry cross-reference. Every row traces to a real source "
                     "(TIER 1: standard general/inorganic chemistry + PubChem product-identity "
                     "verification, TIER 2: predicted from the catalog's own electronegativity/"
                     "oxidation-state data, TIER 3: honest no-reaction/insufficient-data findings) "
                     "-- see scripts/gen_reaction_matrix.py's own header for full methodology. "
                     "No row claims to be confirmed unless status=='confirmed'."),
        "generated": GENERATED_DATE,
        "generator": "scripts/gen_reaction_matrix.py",
        "input_source": CATALOG_SOURCE_NOTE,
        "phase_note": phase_note,
        "acid_base_note": ("Acids and bases are compounds, not elements, so 'acid-base' as a "
                            "class cannot be directly expressed as an element-element pair in "
                            "this matrix. The closest element-pair analogue included here is "
                            "hydride formation (reactive metal + H2 -> ionic hydride, or metal + "
                            "H2O rows using H as the water stand-in, e.g. Na+H). Generic acid+"
                            "metal displacement chemistry is implemented separately in this "
                            "codebase's chem_kinds.lua reactive rules, not duplicated here."),
        "class_definitions": CLASS_DEFS,
        "count": len(rows),
        "counts_by_status": by_status,
        "counts_by_class": by_class,
        "reactions": rows,
    }
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=False)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-network", action="store_true", help="skip PubChem verification pass")
    ap.add_argument("--check", action="store_true", help="regenerate and diff against what's on disk; exit 1 if different")
    args = ap.parse_args()

    elements, by_sym = load_catalog()
    print(f"loaded {len(elements)} elements from catalog", file=sys.stderr)

    print(f"TIER 1 curated rows: {len(TIER1)}", file=sys.stderr)
    rows = build_all_rows(elements, by_sym)
    total_pairs = len(elements) * (len(elements) - 1) // 2
    assert len(rows) == total_pairs, f"expected {total_pairs} pairs, got {len(rows)}"
    print(f"built {len(rows)} total pairs (C(118,2)={total_pairs})", file=sys.stderr)

    # incremental write #1: full matrix, tier1 + rule-based tier2/3, before any network call --
    # a network failure below must never cost this.
    write_json(rows, OUT_JSON, "phase 1 complete (tier1 curated + tier2/3 rule-based); PubChem "
                                "verification pending" if not args.no_network else "offline run, no PubChem verification")
    write_csv(rows, OUT_CSV)
    print(f"phase 1 written: {OUT_CSV}, {OUT_JSON}", file=sys.stderr)

    if not args.no_network:
        cache = load_cache()
        print("phase 2: verifying TIER 1 products against PubChem (live network)...", file=sys.stderr)
        checked, verified = verify_tier1_against_pubchem(rows, cache)
        print(f"PubChem verification: {verified}/{checked} products confirmed as real catalogued compounds", file=sys.stderr)
        write_json(rows, OUT_JSON, f"complete: PubChem-verified {verified}/{checked} TIER 1 product names live")
        write_csv(rows, OUT_CSV)
        print(f"phase 2 written: {OUT_CSV}, {OUT_JSON}", file=sys.stderr)

    by_status = {}
    for r in rows:
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1
    print("final counts by status:", by_status, file=sys.stderr)

    if args.check:
        # re-read what's on disk and confirm it matches what we just built (idempotency check)
        with open(OUT_JSON, "r", encoding="utf-8") as f:
            on_disk = json.load(f)
        if on_disk["count"] != len(rows):
            print(f"CHECK FAILED: on-disk count {on_disk['count']} != generated count {len(rows)}", file=sys.stderr)
            return 1
        print("CHECK OK: on-disk file matches generated row count", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

# ---------------------------------------------------------------------------
# METALLURGY_OVERRIDE (added 2026-09-02)
# @metallurgy corrected rows in reaction-matrix.csv by hand -- most importantly Al+Ga, which this
# generator predicted as a low-confidence "alloy" because it reasons from electronegativity
# difference, and electronegativity is structurally blind to liquid metal embrittlement: gallium
# penetrates aluminium's grain boundaries and destroys its strength without forming any compound.
# PhoenixFire808 caught that specific row, so it must not silently revert on the next regeneration.
# Any pair present in knowledge/data/metallurgy.csv wins over the predicted row.
def _metallurgy_overrides():
    """Load @metallurgy's cited rows, keyed by unordered element pair."""
    import csv as _csv, os as _os
    out = {}
    for cand in ("knowledge/data/metallurgy.csv",
                 _os.path.join(_os.path.dirname(__file__), "..", "knowledge", "data", "metallurgy.csv")):
        if not _os.path.exists(cand):
            continue
        with open(cand, encoding="utf-8", newline="") as fh:
            for row in _csv.DictReader(fh):
                a = (row.get("element_a") or row.get("a") or "").strip()
                b = (row.get("element_b") or row.get("b") or "").strip()
                if a and b:
                    out[frozenset((a, b))] = row
        break
    return out


def apply_metallurgy_overrides(rows):
    """Replace predicted rows with @metallurgy's cited ones. Returns (rows, n_overridden)."""
    ov = _metallurgy_overrides()
    if not ov:
        return rows, 0
    n = 0
    for r in rows:
        key = frozenset((r.get("element_a", ""), r.get("element_b", "")))
        m = ov.get(key)
        if not m:
            continue
        for field, src in (("class", "class"), ("products", "products"),
                           ("conditions", "conditions"), ("source", "source"),
                           ("source_url", "source_url"), ("note", "note")):
            if m.get(src):
                r[field] = m[src]
        r["status"] = "confirmed"
        r["confidence"] = "high"
        n += 1
    return rows, n
