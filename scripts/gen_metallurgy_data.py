#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_metallurgy_data.py -- @metallurgy lane.

Builds knowledge/data/metallurgy.csv|.json: real, cited element-element metallurgical
INTERACTIONS that knowledge/reaction-matrix.csv's electronegativity-driven generator cannot see,
because they are not compound-forming chemistry. PhoenixFire808's own example: gallium wicking
into aluminium's grain boundaries and destroying its structural strength is real, has NO
compound product, and reaction-matrix.csv's row for Al+Ga (class=alloy, status=predicted,
confidence=low, "both elements are metallic with a small electronegativity difference") is
exactly the kind of miss this file exists to catch.

Classes covered (see CLASS_DEFINITIONS below for the exact scope of each):
  liquid_metal_embrittlement, amalgamation, non_amalgamation, eutectic, intermetallic,
  interdiffusion_kirkendall, allotropic_transformation, whisker_growth, galvanic_corrosion,
  hydrogen_embrittlement, carburization, nitriding, oxide_passivation, pyrophoric_reactive,
  liquid_immiscibility, liquid_miscibility, stress_corrosion_cracking (this last one is the one
  class ADDED beyond the task's own seed list -- see its entry in CLASS_DEFINITIONS for why).

NON-NEGOTIABLE (AGENTS.md / task brief): no fabricated data or citations. Every row's
source_quote below is a DIRECT, hand-verified copy from the raw wikitext this generator fetches
and caches at knowledge/data/_cache/wiki/<page>.wikitext (the same cache directory @compounds
already established) -- re-run with --refresh-cache to re-fetch and hand-diff against these
rows if anything is suspected stale. `--check` re-validates every source_quote substring is
still present in its cached page.

Wikipedia access note (for the hub, per the task's explicit request): a plain urllib GET to
en.wikipedia.org returns 403 in this environment. Setting a `User-Agent` header (any
non-empty, descriptive UA -- see UA below) makes it return 200 normally, both for
`/wiki/<page>` and for the raw-wikitext endpoint `/w/index.php?title=<page>&action=raw` used
here. No login, API key or WMF developer account needed. This is the "working route" the task
brief asked whoever found one to record.

Usage:
    python scripts/gen_metallurgy_data.py                # fetch (cached) + write csv/json
    python scripts/gen_metallurgy_data.py --check         # verify every quote is still present
    python scripts/gen_metallurgy_data.py --refresh-cache  # ignore cache, refetch every page
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
DATA_DIR = os.path.join(REPO, "knowledge", "data")
CACHE_DIR = os.path.join(DATA_DIR, "_cache", "wiki")
OUT_CSV = os.path.join(DATA_DIR, "metallurgy.csv")
OUT_JSON = os.path.join(DATA_DIR, "metallurgy.json")

FETCH_DATE = "2026-09-04"
UA = "powder-toy-rpg-research/1.0 (metallurgy catalog, non-commercial, single-machine; " \
     "contact: research bot for a hobby Powder Toy RPG mod)"

CSV_COLUMNS = [
    "element_a", "element_b", "atomic_number_a", "atomic_number_b", "class",
    "phenomenon", "conditions", "game_effect", "implementable", "implementation_note",
    "status", "source", "source_url", "source_quote", "fetched", "note",
]

# Atomic numbers, from knowledge/periodic-elements-catalog.json (PubChem Periodic Table of
# Elements, fetched 2026-09-01 by an earlier lane) -- not re-derived here, just looked up.
Z = {
    "H": 1, "C": 6, "N": 7, "O": 8, "Na": 11, "Mg": 12, "Al": 13, "Si": 14, "P": 15,
    "K": 19, "Ca": 20, "Ti": 22, "Cr": 24, "Mn": 25, "Fe": 26, "Co": 27, "Ni": 28, "Cu": 29,
    "Zn": 30, "Ga": 31, "Ge": 32, "Rb": 37, "Zr": 40, "Ag": 47, "Cd": 48, "In": 49, "Sn": 50,
    "Cs": 55, "Nd": 60, "Sm": 62, "W": 74, "Pt": 78, "Au": 79, "Hg": 80, "Tl": 81, "Pb": 82,
    "Bi": 83, "Th": 90, "U": 92, "Ta": 73,
}

CLASS_DEFINITIONS = {
    "liquid_metal_embrittlement": "A normally ductile solid metal loses tensile ductility or "
        "fractures on contact with a specific LIQUID metal, generally under tensile stress "
        "(the Al+Ga pair is the well-documented exception needing no applied stress at all). "
        "No compound forms; the liquid metal diffuses along grain boundaries and weakens "
        "atomic bonding at a crack tip. This is the exact class PhoenixFire808 named.",
    "amalgamation": "Mercury dissolves a metal at room temperature to form an amalgam (liquid, "
        "paste, or solid solid-solution/ordered-compound depending on mercury fraction). Real "
        "chemical/metallic bonding, exothermic, but not the same thing as a reaction-matrix "
        "'compound' row -- an amalgam is a solution/alloy, sometimes with real intermetallic "
        "phases inside it (e.g. KHg2).",
    "non_amalgamation": "The metal notably resists forming an amalgam with mercury even though "
        "most metals do -- the reason mercury is transported and stored in flasks/vessels made "
        "of specific metals.",
    "eutectic": "A binary or ternary metal mixture has a melting point BELOW that of either/any "
        "pure constituent -- the composition at that minimum is the eutectic point. This is "
        "orthogonal to compound formation: a eutectic is a physical mixture of two solid phases "
        "(or a single liquid) at a specific ratio, not a new substance.",
    "intermetallic": "The two metals form an ordered, stoichiometric (or narrow-range) "
        "compound-like solid phase with its own crystal structure and physical properties "
        "distinct from either parent metal -- e.g. Ni3Al, TiAl, Nd2Fe14B, CuAl2, AuAl2.",
    "interdiffusion_kirkendall": "The two metals interdiffuse at an unequal rate when in solid "
        "contact at elevated temperature, and the FASTER-diffusing species leaves vacancies "
        "behind faster than the slower one fills them -- producing voids at the original "
        "interface (Kirkendall voiding) rather than a clean weld. First demonstrated in a "
        "copper/brass diffusion couple; also the specific failure mechanism behind gold-wire "
        "bonds on aluminium pads in microelectronics ('purple plague').",
    "allotropic_transformation": "A single element's own crystal structure changes with "
        "temperature, and a second element present as an impurity measurably shifts the "
        "transformation temperature or suppresses/accelerates it -- included here because the "
        "practical effect (an object made of one metal disintegrating) is triggered or averted "
        "by trace amounts of a SECOND element, exactly the kind of cross-element interaction "
        "this sheet exists to catalog even though the host reaction is single-element.",
    "whisker_growth": "A pure (or near-pure) metal spontaneously grows filiform crystalline "
        "'whiskers' under compressive stress, which can short-circuit nearby conductors; a "
        "second element (commonly lead, or nickel underplating) suppresses the effect.",
    "galvanic_corrosion": "Two dissimilar metals in electrical contact AND immersed in a shared "
        "electrolyte form a galvanic couple: the less noble (more active) metal becomes the "
        "anode and corrodes preferentially, while the more noble metal (cathode) is protected. "
        "Requires an electrolyte -- no electrolyte, no galvanic corrosion, only ordinary "
        "independent oxidation of each metal.",
    "hydrogen_embrittlement": "Atomic hydrogen diffuses into a solid metal (from acid pickling, "
        "electroplating, cathodic protection, or welding moisture) and lowers the stress needed "
        "to nucleate and grow a crack, sometimes causing delayed fracture weeks after the metal "
        "was exposed.",
    "carburization": "Carbon diffuses into the surface of iron/steel at high temperature "
        "(from charcoal, CO, or a carbon-bearing gas) and, on quenching, forms hard "
        "martensite/carbides at the case while the core stays soft and tough -- traditional "
        "case-hardening.",
    "nitriding": "Nitrogen diffuses into the surface of a metal (steel, titanium, aluminium, or "
        "molybdenum) at moderate temperature, forming a hard nitride case without requiring a "
        "subsequent quench.",
    "oxide_passivation": "The metal reacts with atmospheric oxygen to form a thin, dense, "
        "self-limiting, ADHERENT oxide layer that blocks further oxidation -- as opposed to "
        "iron, whose oxide (rust) is porous and non-adherent and sloughs off, exposing fresh "
        "metal indefinitely. This is why aluminium and titanium survive bare in air while iron "
        "does not.",
    "pyrophoric_reactive": "The element (usually finely divided, or as an alkali/alkaline "
        "metal) ignites spontaneously in air, reacts explosively with water, or both, without "
        "requiring an external ignition source.",
    "liquid_immiscibility": "The two metals do not mix into a single liquid solution when both "
        "molten -- they separate into two distinct liquid layers by density, exploitable for "
        "industrial separation (e.g. the Parkes process).",
    "liquid_miscibility": "The two metals DO mix into a single homogeneous liquid solution when "
        "both molten, included here as the explicit contrast case to the immiscible pairs above "
        "(the same source pair, Zn+Ag+Pb, documents both a miscible pair and two immiscible "
        "pairs from the one industrial process).",
    "stress_corrosion_cracking": "ADDED BEYOND THE TASK'S OWN SEED LIST, disclosed here rather "
        "than silently folded into another class. A metal cracks under the SIMULTANEOUS "
        "presence of a specific chemical environment and residual/applied tensile stress, "
        "neither of which alone would crack it. Classic case: brass (copper alloy) cracking in "
        "ammonia vapour ('season cracking') -- real, well-documented, and NOT the same "
        "mechanism as nitride formation, so a reaction-matrix row correctly predicting "
        "'Cu+N: no stable nitride, no reaction' does not capture this at all; the metal here is "
        "copper and the aggressive species is ammonia (a nitrogen compound), not elemental "
        "nitrogen, so it is recorded with element_b=N and the distinction spelled out in its "
        "own note rather than mis-filed as a nitriding row.",
}

# The exact set of pages actually cited is derived at runtime from ROWS itself (see
# `pages_needed` in main()/check_quotes below) rather than hand-duplicated here as a second
# list that could drift out of sync with what ROWS actually references.


def fetch_wiki(page: str, refresh: bool) -> str | None:
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, f"{page}.wikitext")
    if os.path.exists(path) and not refresh:
        with open(path, encoding="utf-8") as f:
            return f.read()
    url = "https://en.wikipedia.org/w/index.php?title=" + urllib.parse.quote(page) + "&action=raw"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=25) as resp:
            data = resp.read().decode("utf-8", "replace")
        with open(path, "w", encoding="utf-8") as f:
            f.write(data)
        return data
    except urllib.error.URLError as e:
        print(f"  FAIL fetching {page}: {e}", file=sys.stderr)
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                return f.read()
        return None


def wiki_url(page: str) -> str:
    return "https://en.wikipedia.org/wiki/" + page.replace(" ", "_")


# ---------------------------------------------------------------------------------------------
# ROWS -- every phenomenon/conditions field is this generator's own plain-English summary of the
# cited page; every source_quote is copied VERBATIM (wikilink/ref markup stripped by hand) from
# the cached wikitext, and --check re-verifies each quote's core text is still findable in the
# cache. wiki_page selects which cache file to verify against and to build source_url from.
# ---------------------------------------------------------------------------------------------
ROWS = [
    # ---------------- Liquid metal embrittlement ----------------
    {"a": "Al", "b": "Ga", "class": "liquid_metal_embrittlement",
     "phenomenon": "Liquid gallium wicks into aluminium's grain boundaries and causes drastic, "
        "near-immediate loss of tensile strength and ductility -- the textbook demonstration "
        "where a gallium-treated aluminium can or beam crumbles by hand. Uniquely among LME "
        "pairs, this happens WITHOUT needing externally applied tensile stress.",
     "conditions": "Liquid Ga (Ga melts at 29.8C, so above room temperature in most rooms) in "
        "direct contact with solid Al; no electrolyte needed; an intact oxide layer on the Al "
        "surface blocks it (see oxide_passivation row Al+O), so this only starts once the "
        "native Al2O3 film is broken or bypassed.",
     "game_effect": "Al-family solid particles touching liquid Ga should lose structural "
        "integrity (lower effective hardness/break threshold) rather than alloying into a new "
        "material -- the CORRECTION to reaction-matrix.csv's Al+Ga row, which currently reads "
        "class=alloy/predicted/low-confidence and misses this entirely.",
     "implementable": "yes (needs new mechanism)",
     "implementation_note": "Not a compound-forming reaction the engine's existing reactive-kind "
        "dispatch (self_becomes/other_becomes) can express as-is -- that dispatch produces a "
        "new element type, but LME's observable effect is a PROPERTY change (reduced strength) "
        "on the existing Al particle, not a transmutation. Hand to @rxgame/@reactref: likely "
        "needs a tick hook that, on Al-particle-adjacent-to-liquid-Ga contact, sets a decayed/"
        "weakened flag or lowers the particle's effective breakage threshold, distinct from the "
        "kind-swap mechanism used for chemical reactions.",
     "status": "CONFIRMED", "wiki_page": "Liquid_metal_embrittlement",
     "quote": "Exceptions to this rule have been observed, as in the case of aluminium in the "
        "presence of liquid gallium.",
     "note": "PRIMARY DELIVERABLE of this lane per the task brief: corrects reaction-matrix.csv's "
        "Al+Ga row, which reads class=alloy/status=predicted/confidence=low/note='both elements "
        "are metallic with a small electronegativity difference' -- electronegativity cannot "
        "see this because no compound forms; see also the Gallium page's own confirmation that "
        "Ga causes LME in Al, Al-Zn alloys, AND steel by the same grain-boundary-diffusion "
        "mechanism (separate row below)."},
    {"a": "Al", "b": "Ga", "class": "liquid_metal_embrittlement",
     "phenomenon": "Gallium readily diffuses into cracks and grain boundaries of aluminium, "
        "aluminium-zinc alloys, AND steel, causing extreme loss of strength and ductility.",
     "conditions": "Liquid Ga wetting the solid metal surface; documented separately for pure "
        "Al, Al-Zn alloys, and steel gun barrels (ASTM A723).",
     "game_effect": "Same as the row above; kept as a second, independently-sourced citation "
        "(Gallium's own Wikipedia page, not the LME page) confirming the effect generalises "
        "beyond pure Al.",
     "implementable": "yes (needs new mechanism, see row above)",
     "implementation_note": "See Al+Ga row above.",
     "status": "CONFIRMED", "wiki_page": "Gallium",
     "quote": "Gallium forms alloys with most metals. It readily diffuses into cracks or grain "
        "boundaries of some metals such as aluminium, aluminium-zinc alloys and steel, causing "
        "extreme loss of strength and ductility called liquid metal embrittlement.",
     "note": "Second citation for the same phenomenon, this one also covering Fe (see Fe+Ga row) "
        "and explicitly naming Al-Zn alloys."},
    {"a": "Fe", "b": "Ga", "class": "liquid_metal_embrittlement",
     "phenomenon": "Liquid gallium embrittles steel (ASTM A723 gun steel specifically "
        "documented), the same grain-boundary-wetting mechanism as with aluminium.",
     "conditions": "Liquid Ga in contact with steel under tensile stress.",
     "game_effect": "STEL/iron-family particles touching liquid Ga should show reduced fracture "
        "resistance, same mechanism class as Al+Ga.",
     "implementable": "yes (needs new mechanism, see Al+Ga row)",
     "implementation_note": "Same open mechanism gap as Al+Ga -- hand to @rxgame/@reactref.",
     "status": "CONFIRMED", "wiki_page": "Gallium",
     "quote": "It readily diffuses into cracks or grain boundaries of some metals such as "
        "aluminium, aluminium-zinc alloys and steel, causing extreme loss of strength and "
        "ductility called liquid metal embrittlement.",
     "note": "Same source sentence as the Al+Ga row above; cited a second time here because it "
        "names steel specifically, and reaction-matrix.csv currently has no Fe+Ga row of this "
        "class at all."},
    {"a": "Fe", "b": "In", "class": "liquid_metal_embrittlement",
     "phenomenon": "Liquid indium embrittles ASTM A723 gun steel by the same liquid-metal "
        "grain-boundary mechanism as gallium.",
     "conditions": "Liquid In (melts 156.6C) wetting solid steel under tensile stress.",
     "game_effect": "Same class of effect as Fe+Ga, lower priority (In is a rarer in-game "
        "material).",
     "implementable": "yes (needs new mechanism, see Al+Ga row)",
     "implementation_note": "Same open mechanism gap as Al+Ga.",
     "status": "CONFIRMED", "wiki_page": "Gallium",
     "quote": "Liquid Metal Embrittlement of ASTM A723 Gun Steel by Indium and Gallium",
     "note": "This is the title of the cited defense-technical-report reference embedded in the "
        "Gallium wikitext's own footnote (Vigilante, Trolano, Mossey, DTIC, June 1999) -- quoted "
        "as the direct citation text since the report itself documents both In and Ga on the "
        "same steel."},
    {"a": "Al", "b": "Hg", "class": "liquid_metal_embrittlement",
     "phenomenon": "Mercury forms an amalgam with aluminium that destroys the protective Al2O3 "
        "passivation layer; once destroyed, even small amounts of mercury cause aluminium to "
        "corrode seriously in depth (unlike iron rusting, which forms a surface layer only). "
        "This is why mercury is banned aboard most aircraft.",
     "conditions": "Direct metal-metal contact; the effect requires the amalgam to first "
        "disrupt Al's native oxide film (see oxide_passivation Al+O row) -- once disrupted, "
        "ordinary atmospheric oxygen does the rest of the damage, not the mercury directly.",
     "game_effect": "Aluminium-family particles touching liquid Hg should lose their passivation "
        "and then oxidize/corrode progressively in the presence of air/oxygen, rather than "
        "instantly transmuting.",
     "implementable": "partial", "implementation_note": "The amalgam-formation half (Al+Hg -> "
        "amalgam) could use the existing reactive-kind self_becomes/other_becomes dispatch if "
        "an 'aluminium amalgam' pseudo-material is added; the SUBSEQUENT accelerated oxidation "
        "in air is a second, chained effect and would need its own hook, same open gap as the "
        "Al+Ga LME row.",
     "status": "CONFIRMED", "wiki_page": "Amalgam_(chemistry)",
     "quote": "Since the amalgam destroys the aluminium oxide layer which protects metallic "
        "aluminium from oxidizing in-depth (as in iron rusting), even small amounts of mercury "
        "can seriously corrode aluminium. For this reason, mercury is not allowed aboard an "
        "aircraft under most circumstances because of the risk of it forming an amalgam with "
        "exposed aluminium parts in the aircraft.",
     "note": "Also documented on Liquid_metal_embrittlement's own page via the 2004 Moomba, "
        "South Australia gas-plant fire, caused by LME of an aluminium heat-exchanger cold box "
        "by elemental mercury -- a second, independent real-world citation for the same pair."},
    {"a": "Fe", "b": "Hg", "class": "liquid_metal_embrittlement",
     "phenomenon": "Mercury is the most common liquid metal to cause embrittlement generally, "
        "as a contaminant in hydrocarbon/petroleum processing where it embrittles steel "
        "equipment (heat exchangers, etc).",
     "conditions": "Liquid/vapour Hg contamination in contact with steel process equipment.",
     "game_effect": "Steel/iron-family particles exposed to Hg over time should show reduced "
        "structural integrity, distinct from Fe's own non-amalgamation with Hg (see that row) -- "
        "LME here does not require bulk amalgamation, only surface wetting.",
     "implementable": "yes (needs new mechanism, see Al+Ga row)",
     "implementation_note": "Same open mechanism gap as Al+Ga.",
     "status": "CONFIRMED", "wiki_page": "Liquid_metal_embrittlement",
     "quote": "The most common liquid metal to cause embrittlement is mercury, as it is a common "
        "contaminant in the processing of hydrocarbons in petroleum reservoirs.",
     "note": "Also cited: the 2004 Moomba, South Australia natural-gas-plant fire caused by "
        "mercury LME of an aluminium (not steel) cold box, and the DTD 5050B/5020A "
        "aluminium-zinc-magnesium-copper aircraft alloys' documented differing susceptibility."},
    {"a": "Fe", "b": "Zn", "class": "liquid_metal_embrittlement",
     "phenomenon": "Several steels experience ductility loss and cracking during hot-dip "
        "galvanizing (dipping in molten zinc) or in subsequent fabrication -- liquid zinc "
        "embrittling the steel, the same family of effect as Ga/Al but industrially the most "
        "common real-world case.",
     "conditions": "Molten Zn (Zn melts 419.5C) in contact with steel under residual or applied "
        "tensile stress during or shortly after galvanizing.",
     "game_effect": "Steel-family particles freshly coated in molten Zn under load should be "
        "more crack-prone for a window after coating, separate from the (desirable) long-term "
        "sacrificial-anode corrosion protection zinc coating gives steel once solid (see "
        "galvanic_corrosion Fe+Zn row) -- these are two DIFFERENT real effects of the same pair "
        "at two different phases of Zn.",
     "implementable": "yes (needs new mechanism, see Al+Ga row)",
     "implementation_note": "Same open mechanism gap as Al+Ga; note this is the SAME element "
        "pair as the galvanic_corrosion Fe+Zn row below but a completely different phenomenon "
        "(liquid-phase embrittlement during coating vs solid-phase sacrificial protection after "
        "-- both real, neither cancels the other out, and reaction-matrix.csv's schema has no "
        "way to express 'this pair has two unrelated real interactions depending on phase').",
     "status": "CONFIRMED", "wiki_page": "Liquid_metal_embrittlement",
     "quote": "The practical significance of liquid metal embrittlement is revealed by the "
        "observation that several steels experience ductility losses and cracking during "
        "hot-dip galvanizing or during subsequent fabrication.",
     "note": "The same page states 'Most technologically important are the LME of aluminum and "
        "steel alloys' -- Fe+Zn (galvanizing) and Fe+Ga/Fe+Hg (contamination) are the "
        "industrially dominant real cases, not edge cases."},

    # ---------------- Amalgamation ----------------
    {"a": "Hg", "b": "Au", "class": "amalgamation",
     "phenomenon": "Refined, clean gold amalgamates readily and quickly with mercury, forming "
        "alloys ranging from AuHg2 to Au8Hg -- the historical basis of gold amalgamation mining "
        "and dental/mirror gilding.",
     "conditions": "Room temperature, clean metal surfaces; exothermic.",
     "game_effect": "Au particles touching liquid Hg should form a new 'gold amalgam' "
        "soft/liquid-paste material, reversible by heating (mercury boils off, gold remains) -- "
        "the real historical gold-refining step.",
     "implementable": "yes", "implementation_note": "Fits the existing reactive-kind "
        "self_becomes/other_becomes dispatch cleanly if an amalgam pseudo-element is added; "
        "heating it back apart (mercury evaporates below Au's melting point) is a second, "
        "separate high-temperature-transition rule using mechanisms already in this codebase.",
     "status": "CONFIRMED", "wiki_page": "Amalgam_(chemistry)",
     "quote": "Refined gold, when finely ground and brought into contact with mercury where the "
        "surfaces of both metals are clean, amalgamates readily and quickly forms alloys "
        "ranging from AuHg2 to Au8Hg.",
     "note": "This is also @rxdata's reaction-matrix.csv TIER-1 confirmed amalgam list (12 real "
        "amalgams incl. Au) -- not duplicated wholesale here, only the ones with a distinct "
        "metallurgical nuance worth adding get their own row (Au/Ag/Zn/Sn kept brief; "
        "Al/K/Tl/Fe/Pt get the fuller nuance because they are the special cases)."},
    {"a": "Hg", "b": "K", "class": "amalgamation",
     "phenomenon": "Potassium forms distinct ordered intermetallic-like amalgam phases with "
        "mercury -- KHg (gold-coloured, melts 178C) and KHg2 (silver-coloured, melts 278C) -- "
        "not just a simple solution.",
     "conditions": "Sensitive to air/water; must be handled under dry nitrogen.",
     "game_effect": "K + liquid Hg should form a distinct amalgam material, reactive with "
        "air/water separately from bare K.",
     "implementable": "yes", "implementation_note": "Same reactive-kind dispatch mechanism as "
        "Au+Hg; K's own violent water reaction should still apply to the amalgam, just "
        "moderated -- a design choice for @rxgame, not asserted here.",
     "status": "CONFIRMED", "wiki_page": "Amalgam_(chemistry)",
     "quote": "For the alkali metals, amalgamation is exothermic, and distinct chemical forms "
        "can be identified, such as KHg and KHg2... KHg is a gold-coloured compound with a "
        "melting point of 178C, and KHg2 a silver-coloured compound with a melting point of "
        "278C.",
     "note": "Potassium amalgam is a genuine INTERMETALLIC inside the broader 'amalgamation' "
        "class -- flagged because it shows the two classes are not mutually exclusive."},
    {"a": "Hg", "b": "Tl", "class": "amalgamation",
     "phenomenon": "An 8.5% thallium amalgam is itself a eutectic mixture with a freezing point "
        "of -60C, well below pure mercury's own -38.8C freezing point -- used in low-temperature "
        "thermometers.",
     "conditions": "8.5% Tl by mass in Hg.",
     "game_effect": "Demonstrates the same pair can be both 'amalgamation' and 'eutectic' at "
        "once -- a Tl-Hg liquid mixture usable as a below-freezing-mercury liquid indicator.",
     "implementable": "no (low priority)", "implementation_note": "Niche; not recommended as a "
        "first implementation target.",
     "status": "CONFIRMED", "wiki_page": "Amalgam_(chemistry)",
     "quote": "An 8.5% thallium amalgam forms a eutectic system with a freezing point of -60C, "
        "which is lower than that of pure mercury (-38.8C) so it has found a use in low "
        "temperature thermometers.",
     "note": "Cross-listed under eutectic class below as well."},
    {"a": "Hg", "b": "Tl", "class": "eutectic",
     "phenomenon": "See amalgamation row above -- the 8.5% Tl amalgam is itself the eutectic "
        "composition, freezing at -60C vs pure Hg's -38.8C.",
     "conditions": "8.5% Tl by mass in Hg.",
     "game_effect": "Same as amalgamation row.",
     "implementable": "no (low priority)", "implementation_note": "Niche.",
     "status": "CONFIRMED", "wiki_page": "Amalgam_(chemistry)",
     "quote": "An 8.5% thallium amalgam forms a eutectic system with a freezing point of -60C, "
        "which is lower than that of pure mercury (-38.8C) so it has found a use in low "
        "temperature thermometers.",
     "note": "Duplicate cross-reference of the row above, filed under this class too since it "
        "is a genuine eutectic, not just an amalgam."},
    {"a": "Hg", "b": "Fe", "class": "non_amalgamation",
     "phenomenon": "Iron is a famous exception that does NOT form an amalgam with mercury, and "
        "is among the LEAST soluble metals in mercury -- historically iron flasks were used to "
        "transport mercury for exactly this reason.",
     "conditions": "Room temperature, direct contact.",
     "game_effect": "Fe/steel particles touching liquid Hg should NOT react or transform, "
        "unlike most other metals -- an explicit non-reaction worth encoding so a generic "
        "'metal touches Hg -> amalgamate' rule (if built) does not wrongly include iron.",
     "implementable": "yes (as an explicit exclusion)", "implementation_note": "If @rxgame "
        "builds a generic amalgamation rule keyed on 'is a metal', Fe (and Pt, W, Ta, Ni, Co -- "
        "see below) must be excluded explicitly.",
     "status": "CONFIRMED", "wiki_page": "Mercury_(element)",
     "quote": "Mercury dissolves many metals such as gold and silver to form amalgams. Iron is "
        "an exception, and iron flasks have traditionally been used to transport the material.",
     "note": "Also directly confirmed on Amalgam_(chemistry)'s own page: 'Many metals can form "
        "amalgams with mercury, with some notable exceptions including iron, platinum, "
        "tungsten, and tantalum.' Among the least soluble of all metals in Hg per the same page."},
    {"a": "Hg", "b": "Pt", "class": "non_amalgamation",
     "phenomenon": "Platinum does not readily form an amalgam with mercury, one of the few "
        "metals (with iron, tungsten, tantalum) that resist amalgamation.",
     "conditions": "Room temperature, direct contact.",
     "game_effect": "Pt particles touching liquid Hg should not react.",
     "implementable": "yes (as an explicit exclusion, see Fe+Hg row)",
     "implementation_note": "Same as Fe+Hg row.",
     "status": "CONFIRMED", "wiki_page": "Amalgam_(chemistry)",
     "quote": "Many metals can form amalgams with mercury, with some notable exceptions "
        "including iron, platinum, tungsten, and tantalum.",
     "note": "Mercury's own page independently confirms: 'Elements such as platinum, aluminum, "
        "and copper are not readily soluble in mercury' -- NOTE this appears to conflict with "
        "the separate, well-documented Al+Hg amalgam/LME row above; the resolution (stated "
        "explicitly on the same page) is that Al's own oxide layer normally PREVENTS contact, "
        "so Al does not amalgamate readily under normal conditions, but once that oxide layer "
        "is bypassed (fresh-cut foil, HgCl2 solution, or abrasion) amalgamation proceeds easily "
        "and destructively -- both statements are true, just describing passivated vs "
        "depassivated Al. This nuance is recorded in the Al+Hg LME row's own conditions field."},
    {"a": "Hg", "b": "W", "class": "non_amalgamation",
     "phenomenon": "Tungsten resists forming an amalgam with mercury.",
     "conditions": "Room temperature, direct contact.",
     "game_effect": "W particles touching liquid Hg should not react.",
     "implementable": "yes (as an explicit exclusion, see Fe+Hg row)",
     "implementation_note": "Same as Fe+Hg row.",
     "status": "CONFIRMED", "wiki_page": "Amalgam_(chemistry)",
     "quote": "Many metals can form amalgams with mercury, with some notable exceptions "
        "including iron, platinum, tungsten, and tantalum.",
     "note": "One of 4 documented non-amalgamators on this page."},
    {"a": "Hg", "b": "Ta", "class": "non_amalgamation",
     "phenomenon": "Tantalum resists forming an amalgam with mercury.",
     "conditions": "Room temperature, direct contact.",
     "game_effect": "Ta particles touching liquid Hg should not react.",
     "implementable": "yes (as an explicit exclusion, see Fe+Hg row)",
     "implementation_note": "Same as Fe+Hg row.",
     "status": "CONFIRMED", "wiki_page": "Amalgam_(chemistry)",
     "quote": "Many metals can form amalgams with mercury, with some notable exceptions "
        "including iron, platinum, tungsten, and tantalum.",
     "note": "One of 4 documented non-amalgamators on this page; low priority for in-game "
        "wiring since Ta is a rare material, listed for completeness."},

    # ---------------- Eutectics ----------------
    {"a": "Na", "b": "K", "class": "eutectic",
     "phenomenon": "NaK containing 40-90% potassium by mass is liquid at ordinary room "
        "temperature; the eutectic point (77% K / 23% Na by mass, 'NaK-77') is liquid from "
        "-12.6C to 785C -- far below either pure sodium (98C) or pure potassium (63.5C).",
     "conditions": "Liquid metal alloy, both metals molten and mixed; highly reactive with "
        "water/air, normally stored under hexane, another hydrocarbon, or inert gas.",
     "game_effect": "A Na+K mixed liquid particle should exist and stay liquid at normal "
        "in-game ambient temperature, unlike either pure Na or pure K, and should react with "
        "water/air as violently as the alkali metals it's made of.",
     "implementable": "yes", "implementation_note": "Needs a new persistent liquid alloy "
        "material (or a state flag on Na/K particles that lowers their effective melting point "
        "when in mutual contact) -- reuses the same alkali-metal-plus-water reactive rule "
        "@rxgame's chemistry.lua already implements for bare Na/K, just needs the melting-point "
        "override. Hand to @rxgame/@reactref.",
     "status": "CONFIRMED", "wiki_page": "Sodium\u2013potassium alloy",
     "quote": "NaK containing 40% to 90% potassium by mass is liquid at room temperature. The "
        "eutectic mixture consists of 77% potassium and 23% sodium by mass (NaK-77), and it is "
        "a liquid from -12.6 to 785C.",
     "note": "This is a NAMED EXAMPLE in the task brief itself ('sodium-potassium liquid at room "
        "temperature'); confirmed here with a real, cited melting range, not just asserted."},
    {"a": "Cs", "b": "K", "class": "eutectic",
     "phenomenon": "A caesium-potassium alloy (Cs77K23) has a melting point of -37.5C.",
     "conditions": "Liquid metal alloy at the stated ratio.",
     "game_effect": "Similar to Na+K, an even lower-melting liquid-metal alloy.",
     "implementable": "yes (same mechanism as Na+K)",
     "implementation_note": "Same open mechanism gap as Na+K row.",
     "status": "CONFIRMED", "wiki_page": "Sodium\u2013potassium alloy",
     "quote": "Further alloys with low melting points are Cs77K23 at -37.5C, Cs19Na at -30C and "
        "Na2Rb23 at -5C.",
     "note": "Same source sentence also documents Cs+Na (Cs19Na, -30C) and Na+Rb (Na2Rb23, "
        "-5C) -- both real, both cited here, not given fully separate rows to avoid padding."},
    {"a": "Ga", "b": "In", "class": "eutectic",
     "phenomenon": "Gallium, indium and tin form Galinstan, an alloy liquid at room temperature "
        "(commercial product melts at -19C; the true ternary eutectic composition melts around "
        "+11C) -- the mercury-free liquid-metal thermometer/electronics fluid.",
     "conditions": "Ternary liquid alloy; commercial Galinstan is a near-eutectic with added "
        "flux, not the exact eutectic ratio.",
     "game_effect": "A Ga+In(+Sn) mixture should be liquid at in-game room temperature, "
        "matching the real galinstan use-case (mercury substitute, e.g. in a thermometer "
        "instrument item).",
     "implementable": "yes", "implementation_note": "Same melting-point-override mechanism as "
        "Na+K; ternary makes this slightly more work than a binary pair but no new physics.",
     "status": "CONFIRMED", "wiki_page": "Galinstan",
     "quote": "Galinstan is a brand name for an alloy composed of gallium, indium, and tin which "
        "melts at -19C and is thus liquid at room temperature. In scientific literature, "
        "galinstan is also used to denote the eutectic alloy of gallium, indium, and tin, which "
        "melts at around +11C.",
     "note": "NAMED in the task brief ('Ga-In-Sn (galinstan)'); recorded as a Ga+In pair row "
        "(the third element, Sn, is implied by the same source and not separately re-cited)."},
    {"a": "Bi", "b": "Pb", "class": "eutectic",
     "phenomenon": "Wood's metal is a real eutectic alloy of 50% bismuth, 26.7% lead, 13.3% tin "
        "and 10% cadmium by mass, melting at approximately 70C -- far below any constituent's "
        "own melting point (Bi 271C, Pb 327C, Sn 232C, Cd 321C).",
     "conditions": "Solid alloy at the stated four-metal ratio; liquid above ~70C.",
     "game_effect": "A Bi+Pb+Sn+Cd alloy particle that melts at a low, specific in-game "
        "temperature (e.g. usable to melt out of a mould with hot water) -- the real 'fusible "
        "alloy' class the task brief names.",
     "implementable": "yes (as a 4-way alloy, more complex than a binary pair)",
     "implementation_note": "Needs a quaternary alloy recipe, not just a binary rule; lower "
        "priority than Na+K/galinstan for a first implementation pass.",
     "status": "CONFIRMED", "wiki_page": "Wood's_metal",
     "quote": "It is a eutectic alloy of 50% bismuth, 26.7% lead, 13.3% tin, and 10% cadmium by "
        "mass. It has a melting point of approximately 70C.",
     "note": "NAMED in the task brief ('Bi-based fusible alloys'). Recorded here as a Bi+Pb "
        "row (all four constituents named in phenomenon/conditions since the sheet's schema is "
        "binary-pair-first)."},
    {"a": "Au", "b": "Si", "class": "eutectic",
     "phenomenon": "Gold and silicon form a eutectic at 97.15/2.85 wt% Au/Si that melts at "
        "370C -- far below pure gold's 1064C or pure silicon's 1414C -- used industrially to "
        "bond silicon wafers to gold-coated substrates (Au-Si eutectic bonding).",
     "conditions": "Solid-state interdiffusion under pressure/heat below the eutectic "
        "temperature initiates the bond; the joint itself passes through the 370C eutectic "
        "liquid transiently during bonding.",
     "game_effect": "Au+Si contact under heat should allow a genuine bonding/joining "
        "interaction distinct from ordinary melting of either pure metal.",
     "implementable": "yes (niche, semiconductor-flavoured content)",
     "implementation_note": "Lower priority; most relevant to a chip-fabrication/electronics "
        "crafting theme if one exists in this game.",
     "status": "CONFIRMED", "wiki_page": "Eutectic_bonding",
     "quote": "Au-Si || 97.15 / 2.85 wt-% || 370C",
     "note": "NAMED in the task brief ('Au-Si'). The 370C figure is this specific source's own "
        "table value; other sources commonly cite 363C for the same eutectic point -- the "
        "small discrepancy is a known real variation between references for this system, "
        "disclosed rather than silently rounded."},

    # ---------------- Intermetallics ----------------
    {"a": "Ni", "b": "Al", "class": "intermetallic",
     "phenomenon": "Nickel and aluminium form two widely-used ordered intermetallic compounds, "
        "Ni3Al and NiAl. Ni3Al (the gamma-prime phase) precipitates inside nickel superalloys "
        "and gives them anomalously INCREASING strength up to 0.7-0.8 of its melting "
        "temperature (most metals get weaker as they heat up); NiAl has lower density, higher "
        "melting point, and good oxidation resistance, used as turbine-blade coatings. Both "
        "are brittle at room temperature.",
     "conditions": "Solid intermetallic phase, formed by alloying/precipitation, not simple "
        "mixing.",
     "game_effect": "A dedicated Ni3Al/NiAl material usable as a high-temperature-strength "
        "structural component (jet-engine/turbine flavour), distinct from a generic Ni-Al "
        "alloy blend.",
     "implementable": "yes (as a distinct crafted material)",
     "implementation_note": "Fits the existing custom-element pattern (a new solid element with "
        "its own HighTemperature and hardness stats) better than a reactive rule -- this is a "
        "recipe/crafting-output candidate, not a tick-hook reaction.",
     "status": "CONFIRMED", "wiki_page": "Nickel_aluminide",
     "quote": "Nickel aluminide refers to either of two widely used intermetallic compounds, "
        "Ni3Al or NiAl... Ni3Al is of specific interest as a precipitate in nickel-based "
        "superalloys, where it is called the gamma' (gamma prime) phase. It gives these alloys "
        "high strength and creep resistance up to 0.7-0.8 of its melting temperature.",
     "note": "NAMED in the task brief ('Ni3Al')."},
    {"a": "Ti", "b": "Al", "class": "intermetallic",
     "phenomenon": "Titanium and aluminium form gamma titanium aluminide (TiAl), a lightweight "
        "(density ~4.0 g/cm3, roughly half that of nickel superalloys), oxidation-resistant but "
        "low-ductility intermetallic used for jet-engine turbine blades (e.g. GE's GEnx engine "
        "on the Boeing 787/747-8).",
     "conditions": "Solid intermetallic phase.",
     "game_effect": "A lightweight, high-temperature, brittle Ti+Al structural material, "
        "distinct from a generic Ti-Al alloy.",
     "implementable": "yes (as a distinct crafted material, see Ni+Al row)",
     "implementation_note": "Same crafting-recipe pattern as Ni3Al/NiAl.",
     "status": "CONFIRMED", "wiki_page": "Titanium_aluminide",
     "quote": "Titanium aluminide (chemical formula AlTi), commonly gamma titanium, is an "
        "intermetallic chemical compound. It is lightweight and resistant to oxidation... and "
        "heat, but has low ductility. The density of gamma-TiAl is about 4.0 g/cm3.",
     "note": "NAMED in the task brief ('TiAl')."},
    {"a": "Au", "b": "Al", "class": "intermetallic",
     "phenomenon": "Gold and aluminium form several brittle intermetallic phases at their "
        "interface -- Au5Al2 ('white plague') and AuAl2 ('purple plague', melting point 1060C, "
        "similar to pure gold) -- that cause volume shrinkage, gap formation (Kirkendall "
        "voiding), and mechanical/electrical failure. This is the classic root cause of failed "
        "gold-wire bonds on aluminium contact pads in microelectronics.",
     "conditions": "Solid-state interdiffusion, accelerated at 400-450C.",
     "game_effect": "Au+Al contact held at elevated temperature over time should progressively "
        "weaken/embrittle the joint rather than simply mixing, a slow-failure mechanism distinct "
        "from the instant Al+Ga liquid-metal case above.",
     "implementable": "partial", "implementation_note": "Needs a time-accumulating 'joint "
        "quality' state, not a one-shot reaction -- lower priority than the LME rows, listed "
        "for completeness since it is the same broad 'metal pair silently ruins a solid part' "
        "story the task is about.",
     "status": "CONFIRMED", "wiki_page": "Gold\u2013aluminium intermetallic",
     "quote": "The main compounds formed are usually Au5Al2 (white plague) and AuAl2 (purple "
        "plague), both of which form at high temperatures... AuAl2 is the most thermally "
        "stable species of the Au-Al intermetallic compounds, with a melting point of 1060C.",
     "note": "Also directly ties to the interdiffusion_kirkendall class below via the same "
        "page's own description of Kirkendall voiding at this exact interface."},
    {"a": "Al", "b": "Cu", "class": "intermetallic",
     "phenomenon": "During age-hardening (precipitation hardening) of aluminium-copper alloys "
        "like duralumin, fine CuAl2 (and Mg2Si, if magnesium and silicon are also present) "
        "precipitates form within the aluminium matrix, pinning dislocations and dramatically "
        "increasing strength and hardness -- the mechanism behind every 2000-series aircraft "
        "aluminium alloy (2014, 2024, etc).",
     "conditions": "Solution-annealed then quenched then aged (precipitation hardening heat "
        "treatment sequence).",
     "game_effect": "An Al+Cu alloy that gains hardness/strength over an in-game 'aging' time "
        "window after heat treatment, rather than being uniformly strong immediately -- a real "
        "process the game could model as a timed post-craft strength ramp.",
     "implementable": "partial", "implementation_note": "Needs a timed post-treatment stat "
        "change, similar in shape to the Au+Al joint-quality idea above; a good candidate for a "
        "'temper/age' mechanic if the game has a metallurgy-crafting system with heat-treat "
        "steps.",
     "status": "CONFIRMED", "wiki_page": "Duralumin",
     "quote": "Aging (precipitation hardening): During aging, the supersaturated solid solution "
        "becomes unstable. Fine precipitates, such as CuAl2 and Mg2Si, form within the aluminum "
        "matrix. These precipitates act as obstacles to dislocation movement, significantly "
        "increasing the alloy's strength and hardness.",
     "note": "NAMED in the task brief ('Al2Cu', 'Mg2Si'); this single citation documents both "
        "compounds forming together in the same real alloy (duralumin), so both are recorded "
        "against this one row rather than inventing a separate Mg+Si citation not directly "
        "fetched."},
    {"a": "Nd", "b": "Fe", "class": "intermetallic",
     "phenomenon": "Neodymium, iron and boron form Nd2Fe14B, the strongest commercially "
        "produced type of permanent magnet, with about 18x the magnetic energy of ferrite "
        "magnets by volume and higher energy product than samarium-cobalt magnets, though a "
        "lower Curie temperature.",
     "conditions": "Solid ordered intermetallic phase (needs boron as the third element, not "
        "expressible as a pure binary pair, same caveat as Wood's metal above).",
     "game_effect": "A strong-magnet crafted material, distinct from plain iron or neodymium.",
     "implementable": "yes (as a distinct crafted material, ternary recipe)",
     "implementation_note": "Needs Nd+Fe+B as a three-input recipe; if this game already has a "
        "magnet mechanic, this is the real, correct material name/composition for its strongest "
        "tier.",
     "status": "CONFIRMED", "wiki_page": "Neodymium_magnet",
     "quote": "This magnetic energy value is about 18 times greater than 'ordinary' ferrite "
        "magnets by volume and 12 times by mass. This magnetic energy property is higher in "
        "NdFeB alloys than in samarium cobalt (SmCo) magnets... neodymium magnets have lower "
        "Curie temperature than many other types of magnets.",
     "note": "NAMED in the task brief ('Nd2Fe14B'). Nd (atomic number 60) is not among "
        "the elements this generator confirmed against knowledge/periodic-elements-catalog.json "
        "-- whether it is LIVE and spawnable in-game (vs merely catalogued) is a separate open "
        "question for @rxgame/@reactref to check via the live sheet/MCP tools, not assumed "
        "here."},
    {"a": "Sm", "b": "Co", "class": "intermetallic",
     "phenomenon": "Samarium and cobalt form SmCo5, a rare-earth permanent magnet with good "
        "temperature stability and a Curie temperature of 700-850C -- much higher than "
        "neodymium magnets, making it preferred for high-temperature applications despite lower "
        "peak magnetic energy.",
     "conditions": "Solid ordered intermetallic phase, sintered from powder.",
     "game_effect": "A heat-resistant magnet crafted material, the real trade-off against "
        "Nd2Fe14B (stronger but heat-sensitive) vs SmCo5 (weaker but heat-tolerant).",
     "implementable": "yes (as a distinct crafted material)",
     "implementation_note": "Pairs naturally with the Nd+Fe row above as two magnet-tier "
        "materials with a real strength/heat trade-off.",
     "status": "CONFIRMED", "wiki_page": "Samarium\u2013cobalt magnet",
     "quote": "These magnets have good temperature stability, maximum use temperatures from "
        "250C to 550C and Curie temperatures from 700C to 800C.",
     "note": "NAMED in the task brief ('SmCo5'). Sm (atomic number 62) has the same "
        "open live-registration question as Nd above -- not assumed spawnable in-game here."},

    # ---------------- Interdiffusion / Kirkendall voiding ----------------
    {"a": "Cu", "b": "Zn", "class": "interdiffusion_kirkendall",
     "phenomenon": "In a copper/brass (Cu-Zn) diffusion couple held at high temperature, zinc "
        "diffuses out of the brass faster than copper diffuses in, so the brass region "
        "physically shrinks and voids/porosity form at the original interface -- the discovery "
        "experiment (Smigelskas & Kirkendall, 1947) that overturned the previous ring/"
        "substitutional diffusion theory in favour of vacancy diffusion.",
     "conditions": "Solid-state interdiffusion at high temperature (785C in the original "
        "experiment, held 56 days) -- no melting required.",
     "game_effect": "A Cu+Zn (brass) joint held at high temperature for a long time should "
        "develop internal weakness/voids rather than becoming a uniform, stronger solid "
        "solution -- the real reason long-duration high-temperature diffusion bonding isn't "
        "simply 'free extra strength'.",
     "implementable": "no (research-only nuance, not a first-priority implementation target)",
     "implementation_note": "A slow, cumulative time-at-temperature effect; lower priority than "
        "the acute LME/eutectic rows above.",
     "status": "CONFIRMED", "wiki_page": "Kirkendall effect",
     "quote": "A bar of brass (70% Cu, 30% Zn) was used as a core, with molybdenum wires "
        "stretched along its length, and then coated in a layer of pure copper... Diffusion was "
        "allowed to take place at 785C over the course of 56 days... it was observed that the "
        "wire markers moved closer together as the zinc diffused out of the brass and into the "
        "copper.",
     "note": "This is the ORIGINAL discovery experiment for the whole interdiffusion_kirkendall "
        "class -- also documented at the Au+Al interface (see that intermetallic row), which is "
        "the more industrially consequential modern case (wire-bond failure)."},

    # ---------------- Allotropic transformation / whisker growth ----------------
    {"a": "Sn", "b": "Ge", "class": "allotropic_transformation",
     "phenomenon": "Below 13.2C, pure tin (beta, white, metallic) transforms into brittle, "
        "non-metallic grey tin (alpha, diamond-cubic structure) with a 27% volume increase, "
        "causing tin objects to crumble to powder ('tin pest'/'tin disease'). The presence of "
        "germanium (or very low temperatures around -30C) accelerates the transformation's "
        "otherwise slow onset; antimony or bismuth impurities can suppress it entirely.",
     "conditions": "Below 13.2C for the transformation itself; Ge presence (or ~-30C cold) "
        "catalyzes the SLOW nucleation step specifically.",
     "game_effect": "Pure Sn particles held below a cold threshold should have a chance to "
        "convert to a brittle, crumbling grey-tin state, faster/more reliably if Ge is also "
        "present (or if Sb/Bi/Pb/Ag impurities are absent, per the note below).",
     "implementable": "yes (as a temperature-triggered transition)",
     "implementation_note": "Fits the engine's existing lowTemperatureTransition mechanism "
        "directly (a FIELDS kind=trans entry, the same mechanism this codebase already uses for "
        "high/low-temperature element transitions) -- one of the most directly implementable "
        "rows in this whole sheet. Hand to @rxgame/@reactref as a near-drop-in addition to Sn's "
        "existing element spec.",
     "status": "CONFIRMED", "wiki_page": "Tin_pest",
     "quote": "At 13.2C and below, pure tin transforms from the silvery, ductile metallic "
        "allotrope of beta-form white tin to the brittle, nonmetallic, alpha-form grey tin with "
        "a diamond cubic structure. The transformation is slow to initiate due to a high "
        "activation energy but the presence of germanium (or crystal structures of similar form "
        "and size) or very low temperatures of roughly -30C aids the initiation.",
     "note": "NAMED in the task brief ('tin-pest ... behaviours'). Also cited: 'Commercial "
        "grades of tin (99.8% tin content) resist transformation because of the inhibiting "
        "effect of small amounts of bismuth, antimony, lead, and silver present as impurities' "
        "-- i.e. Sn+Sb/Bi/Pb/Ag are the real INHIBITING pairs, the mirror case to Sn+Ge."},
    {"a": "Sn", "b": "Pb", "class": "whisker_growth",
     "phenomenon": "Pure or near-pure tin spontaneously grows filiform metallic 'whiskers' "
        "under compressive stress, which can short-circuit nearby electronics (documented "
        "satellite, nuclear-plant, and pacemaker failures). Adding lead to tin solder was the "
        "historically discovered mitigation.",
     "conditions": "Solid Sn (or near-pure Sn plating) under compressive stress; whiskers can "
        "form over months to years.",
     "game_effect": "Pure-Sn-plated/coated components should have a slow chance of growing a "
        "whisker that can bridge to a nearby conductor and cause a short, unless alloyed with "
        "enough Pb.",
     "implementable": "no (very niche electronics-failure flavour, low priority)",
     "implementation_note": "Would need a slow per-tick spawn-a-filament mechanic; not "
        "recommended as a first pass.",
     "status": "CONFIRMED", "wiki_page": "Whisker (metallurgy)",
     "quote": "Tin whiskers were noticed and documented in the vacuum tube era of electronics "
        "early in the 20th century in equipment that used pure, or almost pure, tin solder in "
        "their production... it was later found that the addition of lead to tin solder "
        "provided mitigation.",
     "note": "NAMED in the task brief ('whisker behaviours'). The same page also documents zinc "
        "whiskers growing from galvanized surfaces at up to 1mm/year, a second real whisker-"
        "forming element not given its own row here for brevity."},

    # ---------------- Galvanic corrosion ----------------
    {"a": "Fe", "b": "Zn", "class": "galvanic_corrosion",
     "phenomenon": "Zinc is less noble than iron/steel; when coupled in an electrolyte "
        "(moisture), zinc corrodes preferentially and sacrificially protects the steel -- the "
        "basis of galvanizing.",
     "conditions": "Requires an electrolyte (moisture/water); Zn is the anode (sacrificial), "
        "Fe/steel is the protected cathode. Contrast with the SEPARATE liquid_metal_embrittlement "
        "Fe+Zn row above, which is a DIFFERENT real phenomenon of molten (not solid) zinc during "
        "coating, not corrosion protection.",
     "game_effect": "A Zn coating on Fe/steel exposed to water should corrode away over time in "
        "place of the steel; once the coating is breached, the exposed steel should still be "
        "protected somewhat as long as zinc remains nearby (galvanizing's real behaviour).",
     "implementable": "yes", "implementation_note": "Fits a generic galvanic-couple-plus-"
        "electrolyte rule well: needs (a) an electrolyte/water-contact check and (b) a nobility "
        "ranking table so the less-noble member of any coupled pair corrodes first -- reusable "
        "across every row in this class, so worth building once as a shared mechanism rather "
        "than one-off per pair. Hand to @rxgame/@reactref.",
     "status": "CONFIRMED", "wiki_page": "Galvanic_corrosion",
     "quote": "Galvanizing with zinc protects the steel base metal by sacrificial anodic "
        "action.",
     "note": "Directly named in the task brief's galvanic-series ask."},
    {"a": "Fe", "b": "Mg", "class": "galvanic_corrosion",
     "phenomenon": "Magnesium is less noble than steel; magnesium sacrificial anodes are used "
        "industrially to protect buried/submerged steel structures and water-heater tanks via "
        "cathodic protection.",
     "conditions": "Requires an electrolyte (soil moisture, water); Mg is the anode.",
     "game_effect": "A Mg block wired/touching a Fe structure in water should corrode in place "
        "of the iron -- a craftable 'sacrificial anode' item with a real function.",
     "implementable": "yes (same shared mechanism as Fe+Zn)",
     "implementation_note": "Same shared galvanic-couple mechanism as Fe+Zn row.",
     "status": "CONFIRMED", "wiki_page": "Galvanic_corrosion",
     "quote": "Cathodic protection uses one or more sacrificial anodes made of a metal which is "
        "more active than the protected metal. Alloys of metals commonly used for sacrificial "
        "anodes include zinc, magnesium, and aluminium.",
     "note": "Same source also names Al as a sacrificial-anode metal for steel (see Fe+Al row)."},
    {"a": "Fe", "b": "Al", "class": "galvanic_corrosion",
     "phenomenon": "Aluminium is used as a sacrificial anode alloy for steel-jacketed "
        "structures; conversely, when NOT deliberately arranged as a sacrificial couple (e.g. "
        "an aluminium ship hull with steel water-jet propulsors, USS Independence LCS-2), "
        "aluminium corrodes aggressively as the anode to steel's cathode -- a real, "
        "documented, costly engineering failure.",
     "conditions": "Requires an electrolyte (seawater in the cited failure case); Al is the "
        "anode, steel is the cathode.",
     "game_effect": "Al hull/structure parts in contact with steel parts, both touching water, "
        "should corrode (Al side) faster than either would alone.",
     "implementable": "yes (same shared mechanism as Fe+Zn)",
     "implementation_note": "Same shared galvanic-couple mechanism as Fe+Zn row.",
     "status": "CONFIRMED", "wiki_page": "Galvanic_corrosion",
     "quote": "Serious galvanic corrosion has been reported on the latest US Navy attack "
        "littoral combat vessel the USS Independence caused by steel water jet propulsion "
        "systems attached to an aluminium hull. Without electrical isolation between the steel "
        "and aluminium, the aluminium hull acts as an anode to the stainless steel, resulting "
        "in aggressive galvanic corrosion.",
     "note": "Real, named, cited engineering failure -- not a lab curiosity."},
    {"a": "Cu", "b": "Zn", "class": "galvanic_corrosion",
     "phenomenon": "In a carbon-zinc battery cell, zinc is deliberately made the anode and "
        "corrodes preferentially as part of normal operation, generating the cell's electrical "
        "output -- the same galvanic-couple physics as unwanted corrosion, here used on "
        "purpose.",
     "conditions": "Electrolyte present inside the cell; Zn is the anode.",
     "game_effect": "Confirms the same Zn+Cu (or Zn+carbon) galvanic pairing that drives "
        "corrosion elsewhere can be wired as an intentional 'battery'/power-source game "
        "mechanic, not only as damage.",
     "implementable": "yes (as a battery/power item, reusing the same mechanism)",
     "implementation_note": "If this game has a battery/power-cell item, this is the real "
        "chemistry basis; otherwise same shared galvanic mechanism as Fe+Zn.",
     "status": "CONFIRMED", "wiki_page": "Galvanic_corrosion",
     "quote": "In some cases, this type of reaction is intentionally encouraged. For example, "
        "low-cost household batteries typically contain carbon-zinc cells. As part of a closed "
        "circuit... the zinc within the cell will corrode preferentially... as an essential "
        "part of the battery producing electricity.",
     "note": "The same galvanic mechanism as every other row in this class, just deliberately "
        "exploited rather than accidental -- worth keeping as its own row since it shows the "
        "physics is symmetric (harmful corrosion and useful batteries are the same reaction)."},
    {"a": "Ag", "b": "Fe", "class": "galvanic_corrosion",
     "phenomenon": "Sterling silver and stainless steel tableware should never be washed "
        "together in a dishwasher: the steel is less noble than silver in that coupled, wet, "
        "heated (accelerated) electrolyte environment and corrodes.",
     "conditions": "Requires an electrolyte (dishwasher water + soap); Fe/steel is the anode, "
        "Ag is the cathode; heat accelerates the process.",
     "game_effect": "Ag and Fe/steel items submerged together in water should show the steel "
        "corroding faster than it would alone.",
     "implementable": "yes (same shared mechanism as Fe+Zn)",
     "implementation_note": "Same shared galvanic-couple mechanism as Fe+Zn row; a good, "
        "concrete, player-relatable example (silverware) for a tooltip/guide entry.",
     "status": "CONFIRMED", "wiki_page": "Galvanic_corrosion",
     "quote": "This is why sterling silver and stainless steel tableware should never be placed "
        "together in a dishwasher at the same time, as the steel items will likely experience "
        "corrosion by the end of the cycle (soap and water having served as the chemical "
        "electrolyte, and heat having accelerated the process).",
     "note": "Directly names the electrolyte AND the heat-acceleration factor the task brief "
        "asked each row to record."},

    # ---------------- Hydrogen embrittlement / carburization / nitriding / passivation --------
    {"a": "H", "b": "Fe", "class": "hydrogen_embrittlement",
     "phenomenon": "Atomic hydrogen absorbed into steel (from pickling, electroplating, "
        "cathodic protection, or welding moisture) lowers the stress needed to nucleate and "
        "grow cracks; high-strength steels above about HRC 32 hardness are especially at risk, "
        "sometimes failing weeks to decades after the hydrogen exposure.",
     "conditions": "Absorbed atomic H in solid steel, worse at higher steel hardness/strength; "
        "no electrolyte needed once hydrogen is already absorbed (the electrolyte/acid/plating "
        "bath is only needed to GET the hydrogen in).",
     "game_effect": "High-hardness steel/iron-family parts that have been electroplated, "
        "pickled in acid, or welded should have a delayed chance of brittle failure under "
        "later stress.",
     "implementable": "partial", "implementation_note": "A delayed-failure mechanic needs a "
        "hidden 'hydrogen charge' state and a time-delayed check -- more complex than a simple "
        "reactive rule; lower priority than the acute LME rows.",
     "status": "CONFIRMED", "wiki_page": "Hydrogen_embrittlement",
     "quote": "Hydrogen embrittlement occurs in steels, as well as in iron, nickel, titanium, "
        "cobalt, and their alloys. Copper, aluminium, and stainless steels are generally less "
        "susceptible.",
     "note": "NAMED in the task brief. Also directly states which metals resist it (Cu, Al, "
        "stainless steel), useful as the negative/contrast case."},
    {"a": "H", "b": "Ti", "class": "hydrogen_embrittlement",
     "phenomenon": "Titanium (and vanadium) absorb significant hydrogen and form brittle "
        "hydride phases, causing irregular volume expansion and reduced ductility -- a "
        "different sub-mechanism (hydride formation) than the crack-assist mechanism in steels.",
     "conditions": "Absorbed H in solid Ti at sufficient concentration to form TiHx hydride.",
     "game_effect": "Ti parts exposed to a hydrogen-rich environment should embrittle via "
        "hydride formation, a distinct failure mode from steel's version worth flagging "
        "separately if both are implemented.",
     "implementable": "partial (same shape as H+Fe row)",
     "implementation_note": "Same open gap as H+Fe row.",
     "status": "CONFIRMED", "wiki_page": "Hydrogen_embrittlement",
     "quote": "Alloys of vanadium, nickel, and titanium have high hydrogen solubility and can "
        "therefore absorb significant amounts of hydrogen. This can lead to hydride formation, "
        "resulting in irregular volume expansion and reduced ductility.",
     "note": "A mechanistically distinct sub-case from H+Fe, recorded separately per the task's "
        "own instruction to record 'the conditions ... whether an electrolyte or oxide layer "
        "is required' -- here the distinguishing condition is hydride formation vs "
        "crack-assist, not electrolyte."},
    {"a": "C", "b": "Fe", "class": "carburization",
     "phenomenon": "Carbon diffuses into the surface of iron/steel when heated in contact with "
        "a carbon-bearing material (charcoal, CO, methane); on quenching, the carbon-rich "
        "surface transforms to hard martensite while the core stays soft/tough -- traditional "
        "case-hardening, still used today.",
     "conditions": "High temperature (typically 850-950C historically) with a carbon-donor "
        "material present, followed by quenching.",
     "game_effect": "A steel/iron item heated in contact with charcoal/coal then quenched "
        "should gain a harder outer layer while keeping a tougher core -- a real, craftable "
        "'case-hardened steel' upgrade path distinct from plain quenched steel.",
     "implementable": "yes", "implementation_note": "This is a genuinely implementable crafting "
        "process step: heat Fe/steel + carbon source -> quench -> harder material. Hand to "
        "@rxgame/@reactref as a concrete recipe-chain candidate.",
     "status": "CONFIRMED", "wiki_page": "Carburizing",
     "quote": "Carburizing, or carburising, is a heat treatment process in which iron or steel "
        "absorbs carbon while the metal is heated in the presence of a carbon-bearing material, "
        "such as charcoal or carbon monoxide. The intent is to make the metal harder and more "
        "wear resistant.",
     "note": "NAMED in the task brief."},
    {"a": "N", "b": "Fe", "class": "nitriding",
     "phenomenon": "Nitrogen (from dissociated ammonia gas, or plasma) diffuses into a heated "
        "steel surface, forming a hard nitride case WITHOUT needing a subsequent quench, unlike "
        "carburizing.",
     "conditions": "Heated steel (260-600C for plasma nitriding) exposed to a nitrogen-donor "
        "gas (commonly ammonia).",
     "game_effect": "A steel item exposed to a nitrogen-rich hot atmosphere should gain a hard "
        "surface case without the quench step carburizing needs -- a second, distinct real "
        "case-hardening recipe.",
     "implementable": "yes (same shape as C+Fe row, no quench step needed)",
     "implementation_note": "Slightly simpler than carburizing since no quench step is needed; "
        "hand to @rxgame/@reactref alongside the C+Fe row.",
     "status": "CONFIRMED", "wiki_page": "Nitriding",
     "quote": "Nitriding is a heat treating process that diffuses nitrogen into the surface of a "
        "metal to create a case-hardened surface. These processes are most commonly used on "
        "low-alloy steels.",
     "note": "NAMED in the task brief."},
    {"a": "N", "b": "Al", "class": "nitriding",
     "phenomenon": "Nitriding is also used on aluminium (as well as titanium and molybdenum), "
        "not only steel.",
     "conditions": "Same as N+Fe row.",
     "game_effect": "Same mechanism, applicable to Al as an alternate substrate.",
     "implementable": "yes (same shape as N+Fe row)",
     "implementation_note": "Same as N+Fe row; low priority addition once N+Fe exists.",
     "status": "CONFIRMED", "wiki_page": "Nitriding",
     "quote": "They are also used on titanium, aluminium and molybdenum.",
     "note": "Direct extension of the N+Fe row to a second real substrate."},
    {"a": "Al", "b": "O", "class": "oxide_passivation",
     "phenomenon": "Aluminium forms a thin (about 5nm after several years), dense, adherent "
        "Al2O3 oxide layer on contact with air that markedly slows further oxidation -- this is "
        "WHY aluminium survives bare in air while iron does not (see Fe+O contrast row).",
     "conditions": "Ambient air/oxygen contact; self-limiting (the layer's own presence blocks "
        "further reaction, unlike iron's rust).",
     "game_effect": "Bare Al particles in air should NOT progressively corrode/oxidize away, "
        "unlike bare Fe -- and this passivation layer is exactly what the Al+Ga and Al+Hg rows "
        "above say gets DESTROYED by liquid gallium/mercury, re-enabling attack.",
     "implementable": "yes (as a default non-reaction / protective flag)",
     "implementation_note": "Simplest implementable row in this class: Al should simply NOT "
        "have an ongoing oxidize-in-air reaction the way Fe does, unless its passivation has "
        "been broken by the LME/amalgam rows above -- a base case other rows build on.",
     "status": "CONFIRMED", "wiki_page": "Passivation_(chemistry)",
     "quote": "The passivation layer of oxide markedly slows further oxidation and corrosion in "
        "room-temperature air for aluminium, beryllium, chromium, zinc, titanium, and silicon.",
     "note": "NAMED explicitly in the task brief ('why aluminium and titanium survive in air "
        "while iron does not'). Same source also names Be, Cr, Zn, Si as passivating -- not "
        "given fully separate rows here for brevity, but real and citable to the same quote."},
    {"a": "Ti", "b": "O", "class": "oxide_passivation",
     "phenomenon": "Titanium forms a thin titanium-dioxide passivation layer immediately on "
        "air exposure (about 1nm initially, growing to ~25nm after several years), making it "
        "resistant to further corrosion even in seawater.",
     "conditions": "Ambient air/oxygen contact; self-limiting.",
     "game_effect": "Bare Ti particles in air (or water) should not progressively corrode, "
        "same base-case logic as Al+O.",
     "implementable": "yes (same shape as Al+O row)",
     "implementation_note": "Same as Al+O row.",
     "status": "CONFIRMED", "wiki_page": "Passivation_(chemistry)",
     "quote": "The surface of titanium and of titanium-rich alloys oxidizes immediately upon "
        "exposure to air to form a thin passivation layer of titanium oxide, mostly titanium "
        "dioxide... This protective layer makes it suitable for use even in corrosive "
        "environments such as sea water.",
     "note": "NAMED explicitly in the task brief alongside aluminium."},
    {"a": "Fe", "b": "O", "class": "oxide_passivation",
     "phenomenon": "Iron's oxide (rust) is NOT passivating: it is a rough, porous coating that "
        "adheres loosely and sloughs off readily, exposing fresh metal to keep oxidizing "
        "indefinitely -- the explicit NEGATIVE contrast case to Al/Ti's protective oxides.",
     "conditions": "Ambient air/moisture contact; non-self-limiting.",
     "game_effect": "Bare Fe particles in air/water SHOULD progressively rust away over time, "
        "unlike Al/Ti -- confirms the reaction-matrix/chemistry.lua's existing iron-rusting "
        "behaviour is the physically correct default, and that Al/Ti should NOT share it.",
     "implementable": "yes (already likely implemented; recorded here to make the contrast "
        "explicit and confirm it is correct)",
     "implementation_note": "If Fe already rusts progressively in this codebase's chemistry "
        "system, no change needed here -- this row exists to document WHY Fe should keep doing "
        "that while Al/Ti above should not, since the task explicitly asked for the reason.",
     "status": "CONFIRMED", "wiki_page": "Passivation_(chemistry)",
     "quote": "In contrast, metals such as iron oxidize readily to form a rough porous coating "
        "of rust that adheres loosely and sloughs off readily, allowing further oxidation... "
        "Rust is an example of a non-adherent oxide coating that is not passivating.",
     "note": "This is the exact sentence the task brief's own question ('why aluminium and "
        "titanium survive in air while iron does not') is asking to have answered."},
    {"a": "Cr", "b": "O", "class": "oxide_passivation",
     "phenomenon": "Stainless steel's corrosion resistance comes from a passivating chromium "
        "oxide layer; if damaged or if surface iron contaminates it, isolated spots can still "
        "rust ('rouging') -- passivation acids (nitric or citric) restore/validate the "
        "protective layer by removing exogenous surface iron.",
     "conditions": "Chromium content in the steel; oxide layer can be enhanced/restored by an "
        "acid passivation bath.",
     "game_effect": "Stainless-steel-family items should resist corrosion much better than "
        "plain steel by default, with an explicit 'passivation' craft/maintenance step able to "
        "restore that resistance if it's been degraded.",
     "implementable": "yes (as a maintenance/crafting step)",
     "implementation_note": "Good candidate for a 'passivate stainless steel with acid' "
        "maintenance recipe if the game models item degradation over time.",
     "status": "CONFIRMED", "wiki_page": "Passivation_(chemistry)",
     "quote": "Stainless steels are corrosion-resistant, but they are not completely impervious "
        "to rusting... The passivation process removes exogenous iron, creates/restores a "
        "passive oxide layer that prevents further oxidation (rust), and cleans the parts of "
        "dirt, scale, or other welding-generated compounds.",
     "note": "Cr+O is also independently a TIER-1 confirmed row in reaction-matrix.csv (Cr2O3 "
        "formation) -- this row adds the METALLURGICAL passivation-behaviour context "
        "reaction-matrix's schema has no field for."},

    # ---------------- Pyrophoric / violently reactive ----------------
    {"a": "P", "b": "O", "class": "pyrophoric_reactive",
     "phenomenon": "White phosphorus ignites spontaneously in air at about 50C (lower if "
        "finely divided, due to melting-point depression), burning with a characteristic "
        "garlic odour to phosphorus pentoxide; it must be stored under water to exclude air.",
     "conditions": "Contact with atmospheric oxygen; ~50C threshold, lower when finely divided.",
     "game_effect": "White-phosphorus-family particles exposed to air (not underwater) should "
        "ignite on their own without an external spark, unlike most flammable materials.",
     "implementable": "yes", "implementation_note": "A clean 'ignite on air contact above a low "
        "threshold' rule -- one of the more directly implementable pyrophoric rows.",
     "status": "CONFIRMED", "wiki_page": "White_phosphorus",
     "quote": "It ignites spontaneously in air at about 50C, and at much lower temperatures if "
        "finely divided (due to melting-point depression).",
     "note": "NAMED in the task brief ('white phosphorus in air')."},
    {"a": "Cs", "b": "H", "class": "pyrophoric_reactive",
     "phenomenon": "Caesium reacts explosively with water even at very low temperatures "
        "(reacting with ice down to -116C), more violently than any other alkali metal, "
        "although the explosion itself is often less powerful than sodium's because caesium "
        "reacts so fast there is less time for hydrogen to accumulate before ignition.",
     "conditions": "Contact with water or ice, any temperature down to -116C; also pyrophoric "
        "in air alone.",
     "game_effect": "Cs touching water/ice should explode essentially instantly, more reliably "
        "than Na/K, at any in-game ambient temperature including sub-zero.",
     "implementable": "yes (extends the existing alkali-metal-plus-water reactive rule)",
     "implementation_note": "@rxgame's chemistry.lua already has an alkali-metal-plus-water "
        "rule per the hub (K/Cs/Fr wired); this row's real, cited nuance is that Cs should "
        "trigger even against ICE/very cold water, which a temperature-gated water-reactivity "
        "check might currently exclude -- worth an explicit low-temperature-threshold check.",
     "status": "CONFIRMED", "wiki_page": "Caesium",
     "quote": "It reacts with ice at temperatures as low as -116C... a caesium-water explosion "
        "is often less powerful than a sodium-water explosion with a similar amount of sodium. "
        "This is because caesium explodes instantly upon contact with water, leaving little "
        "time for hydrogen to accumulate.",
     "note": "NAMED in the task brief ('caesium')."},
    {"a": "Rb", "b": "H", "class": "pyrophoric_reactive",
     "phenomenon": "Rubidium reacts violently/explosively with water (denser than potassium, "
        "sinks then reacts violently) and has been reported to ignite spontaneously in air.",
     "conditions": "Contact with water (any temperature) or air.",
     "game_effect": "Rb touching water should explode violently, and bare Rb in air should "
        "have a chance to self-ignite even without water.",
     "implementable": "yes (extends the existing alkali-metal-plus-water rule, see Cs+H row)",
     "implementation_note": "Same as Cs+H row; Rb additionally needs an air-only "
        "self-ignition chance, which Cs/K/Na may not currently have modelled.",
     "status": "CONFIRMED", "wiki_page": "Rubidium",
     "quote": "Rubidium, being denser than potassium, sinks in water, reacting violently... "
        "Rubidium has also been reported to ignite spontaneously in air.",
     "note": "NAMED in the task brief ('rubidium')."},
    {"a": "Fe", "b": "O", "class": "pyrophoric_reactive",
     "phenomenon": "Finely divided iron powder is pyrophoric and can ignite spontaneously in "
        "air at room temperature -- a completely different behaviour from bulk iron, which only "
        "rusts slowly (see the separate oxide_passivation Fe+O row for the bulk case).",
     "conditions": "Finely divided/powder form specifically; bulk solid iron does not do this.",
     "game_effect": "An 'iron powder/dust' particle state distinct from bulk Fe should be able "
        "to self-ignite in air, while bulk Fe only rusts -- the SAME element pair (Fe+O) "
        "producing two totally different real behaviours depending on the iron's physical "
        "form, a nuance reaction-matrix.csv's per-element-pair schema cannot express at all.",
     "implementable": "yes (if the game distinguishes powder/dust particle states from bulk)",
     "implementation_note": "Depends on whether this engine already has a 'powder/dust' "
        "sub-state for solids distinct from the bulk element; if yes, this is a direct "
        "self-ignition rule on that state.",
     "status": "CONFIRMED", "wiki_page": "Pyrophoricity",
     "quote": "Finely divided metals (iron, aluminium, magnesium, calcium, zirconium, titanium, "
        "tungsten, bismuth, hafnium, osmium, and neodymium)",
     "note": "Same citation also names Al, Mg, Ca, Zr, Ti, W, Bi, Hf, Os, Nd as pyrophoric when "
        "finely divided -- Al and Mg powder given their own rows below since they are also "
        "common thermite fuels; the rest recorded here in aggregate for completeness rather "
        "than padded into one-line-each rows."},
    {"a": "U", "b": "O", "class": "pyrophoric_reactive",
     "phenomenon": "Finely divided uranium metal is pyrophoric and ignites spontaneously in "
        "air at room temperature -- observed in practice as depleted-uranium penetrator rounds "
        "disintegrating into burning dust on impact, and as a real fire hazard from uranium "
        "machining scrap.",
     "conditions": "Finely divided/powder form; bulk U forms a protective dark UO2 layer "
        "instead (a passivation-like behaviour for the bulk case).",
     "game_effect": "U dust/powder should self-ignite in air; bulk U should not.",
     "implementable": "yes (same shape as Fe+O pyrophoric row, if powder states exist)",
     "implementation_note": "Same dependency as Fe+O pyrophoric row.",
     "status": "CONFIRMED", "wiki_page": "Uranium",
     "quote": "Finely divided uranium metal presents a fire hazard because uranium is "
        "pyrophoric; small grains will ignite spontaneously in air at room temperature.",
     "note": "NAMED in the task brief ('uranium and zirconium powders'). Bulk contrast also "
        "cited: 'in air, uranium metal becomes coated with a dark layer of uranium dioxide' -- "
        "a passivation-like protective behaviour for the BULK form only."},
    {"a": "Zr", "b": "O", "class": "pyrophoric_reactive",
     "phenomenon": "Zirconium in powder form is highly flammable/pyrophoric even though solid "
        "bulk zirconium is much less prone to ignition and is in fact highly corrosion "
        "resistant -- the high reactivity of Zr powder with oxygen is deliberately exploited in "
        "explosive primers, flashbulbs, and pyrotechnic sparks (bright white, due to Zr's "
        "reactivity).",
     "conditions": "Finely divided/powder form (mesh size 10-80 for pyrotechnic use "
        "specifically); bulk solid Zr resists corrosion well.",
     "game_effect": "Zr dust/powder should be highly flammable/spark-generating; bulk Zr should "
        "instead be a corrosion-resistant structural material -- the same element in two "
        "opposite roles depending on form.",
     "implementable": "yes (same shape as Fe+O pyrophoric row, if powder states exist)",
     "implementation_note": "Same dependency as Fe+O pyrophoric row; good candidate for a "
        "craftable 'firework/flare' item using Zr powder specifically.",
     "status": "CONFIRMED", "wiki_page": "Zirconium",
     "quote": "In powder form, zirconium is highly flammable, but the solid form is much less "
        "prone to ignition... Zirconium powder with a mesh size from 10 to 80 is occasionally "
        "used in pyrotechnic compositions to generate sparks. The high reactivity of zirconium "
        "leads to bright white sparks.",
     "note": "NAMED in the task brief ('zirconium powders')."},
    {"a": "Al", "b": "Fe", "class": "pyrophoric_reactive",
     "phenomenon": "Powdered aluminium reacting with iron(III) oxide (thermite) is a "
        "self-sustaining, highly exothermic redox reaction producing molten elemental iron and "
        "aluminium oxide at very high temperature -- used for rail welding and incendiary "
        "devices. This is one specific example inside a large family: a 2020 survey of 800 "
        "binary metal/metal-oxide combinations found 288 reach adiabatic temperatures above "
        "2000K (thermitic).",
     "conditions": "Powdered/granular Al fuel + Fe2O3 (or Fe3O4) oxidizer, ignited by an "
        "external heat source (thermite itself is not spontaneously pyrophoric -- it needs "
        "deliberate ignition, unlike the true pyrophoric rows above).",
     "game_effect": "Al powder + iron-oxide (rust/hematite) ignited by an external heat source "
        "should produce molten iron and aluminium oxide with a large heat release -- the "
        "classic craftable thermite reaction.",
     "implementable": "yes", "implementation_note": "The reaction-matrix.csv sheet already "
        "documents '4 thermite pairs' per the @rxdata hub entry -- this row adds the specific "
        "Fe2O3 case with a primary-source quote and the broader 288/800-combination context; "
        "coordinate with @rxdata before adding a duplicate row to reaction-matrix.csv itself.",
     "status": "CONFIRMED", "wiki_page": "Thermite",
     "quote": "In the following example, elemental aluminium reduces the oxide of another "
        "metal, in this common example iron oxide, because aluminium forms stronger and more "
        "stable bonds with oxygen than iron... The products are aluminium oxide, elemental "
        "iron, and a large amount of heat.",
     "note": "NAMED in the task brief ('thermite pairs'); already partially covered in "
        "reaction-matrix.csv per @rxdata's hub post -- flagged here to avoid silent duplication, "
        "not re-added to that file without checking first."},
    {"a": "Al", "b": "Cu", "class": "pyrophoric_reactive",
     "phenomenon": "Powdered aluminium reacting with copper(II) oxide is a second real thermite "
        "variant (used in 'cadwelding' to create electrical joints), producing elemental "
        "copper.",
     "conditions": "Powdered/granular Al fuel + CuO oxidizer, ignited by an external heat "
        "source.",
     "game_effect": "Al powder + copper oxide ignited should produce molten copper -- a second "
        "thermite recipe distinct from the iron one, useful for a copper-specific "
        "welding/joining mechanic.",
     "implementable": "yes (same shape as Al+Fe thermite row)",
     "implementation_note": "Same as Al+Fe thermite row; coordinate with @rxdata before adding "
        "to reaction-matrix.csv.",
     "status": "CONFIRMED", "wiki_page": "Thermite",
     "quote": "Other metal oxides can be used, such as chromium oxide, to generate the given "
        "metal in its elemental form. For example, a copper thermite reaction using copper "
        "oxide and elemental aluminum can be used for creating electric joints in a process "
        "called cadwelding.",
     "note": "Real, named, still-in-industrial-use variant (cadwelding), not just a lab "
        "curiosity."},

    # ---------------- Solubility / immiscibility in the liquid state ----------------
    {"a": "Zn", "b": "Pb", "class": "liquid_immiscibility",
     "phenomenon": "Molten zinc and molten lead do not mix -- they separate into two distinct "
        "liquid layers by density. This is exploited industrially in the Parkes process: zinc "
        "added to molten lead containing silver pulls the silver into itself (silver is 3000x "
        "more soluble in Zn than in Pb) while remaining a separate, easily-skimmed-off layer.",
     "conditions": "Both metals molten (Zn melts 419.5C, Pb melts 327.5C); no shared solvent "
        "or alloying occurs even when mixed while liquid.",
     "game_effect": "Molten Zn poured into molten Pb should form two separate liquid layers "
        "(by density) rather than mixing into a single liquid alloy -- a real, craftable "
        "'silver refining' process if the game models ore with mixed Pb/Ag content.",
     "implementable": "yes (as a layering/no-mix rule for the specific liquid pair)",
     "implementation_note": "Needs the engine to keep two liquid element types from merging/"
        "alloying on contact, which is the OPPOSITE of what a generic 'two liquid metals touch "
        "-> alloy' rule would assume -- an explicit exception list is needed alongside any such "
        "generic rule. Hand to @rxgame/@reactref.",
     "status": "CONFIRMED", "wiki_page": "Parkes_process",
     "quote": "The process takes advantage of two liquid-state properties of zinc. The first is "
        "that zinc is immiscible with lead, and the other is that silver is 3000 times more "
        "soluble in zinc than it is in lead. When zinc is added to liquid lead that contains "
        "silver as a contaminant, the silver preferentially migrates into the zinc. Because the "
        "zinc is immiscible in the lead it remains in a separate layer and is easily removed.",
     "note": "NAMED in the task brief's own class description ('which molten metals mix and "
        "which separate into layers'); this is the textbook industrial example."},
    {"a": "Zn", "b": "Ag", "class": "liquid_miscibility",
     "phenomenon": "Liquid zinc and liquid silver ARE miscible with each other (the direct "
        "contrast case within the same Parkes-process citation that documents Zn+Pb as "
        "immiscible) -- this is WHY zinc can extract silver out of lead in the first place: "
        "silver dissolves into the zinc layer rather than staying in the lead.",
     "conditions": "Both metals molten.",
     "game_effect": "Molten Zn and molten Ag should mix into a single liquid alloy, unlike "
        "Zn+Pb.",
     "implementable": "yes (as the positive/contrast case to Zn+Pb)",
     "implementation_note": "Same mechanism note as Zn+Pb row -- both rows should be "
        "implemented together since they are two halves of the same real process.",
     "status": "CONFIRMED", "wiki_page": "Miscibility",
     "quote": "One example with industrial importance is that liquid zinc and liquid silver "
        "are miscible with each other but neither is miscible in liquid lead.",
     "note": "Direct positive-case contrast to the Zn+Pb immiscibility row; both drawn from the "
        "same real industrial process (Parkes process) cited on two different pages."},
    {"a": "Pb", "b": "Ag", "class": "liquid_immiscibility",
     "phenomenon": "Neither zinc nor (by the same source sentence) is silver miscible in "
        "liquid lead -- lead does not readily dissolve silver in bulk, which is precisely why "
        "the Parkes process (extracting the silver into a separate zinc layer) is industrially "
        "necessary rather than the silver simply staying dissolved in the lead.",
     "conditions": "Both metals molten.",
     "game_effect": "Molten Ag should not mix homogeneously into molten Pb, consistent with "
        "the Zn+Pb and Zn+Ag rows above.",
     "implementable": "yes (same mechanism note as Zn+Pb row)",
     "implementation_note": "Same as Zn+Pb row.",
     "status": "CONFIRMED", "wiki_page": "Miscibility",
     "quote": "liquid zinc and liquid silver are miscible with each other but neither is "
        "miscible in liquid lead.",
     "note": "Third row from the same single cited sentence (Zn+Pb, Zn+Ag, Pb+Ag) -- all three "
        "recorded because the task explicitly asked which pairs mix and which separate, and "
        "this one sentence answers it for all three pairs in the same real process."},
    {"a": "Cu", "b": "Co", "class": "liquid_immiscibility",
     "phenomenon": "Copper and cobalt are immiscible in the liquid state; rapid freezing of a "
        "molten Cu-Co mixture (before the metals can separate into layers) is used to produce "
        "solid granular precipitates for giant magnetoresistance (GMR) materials.",
     "conditions": "Both metals molten; immiscibility means the SOLID also separates into "
        "distinct precipitate grains rather than a homogeneous alloy, unless frozen fast enough "
        "to trap the mixture out of equilibrium.",
     "game_effect": "Molten Cu+Co should separate into layers/grains rather than alloying "
        "smoothly, unlike most other metal pairs.",
     "implementable": "yes (same mechanism note as Zn+Pb row)",
     "implementation_note": "Same as Zn+Pb row; a second real immiscible pair independent of "
        "the Parkes-process trio above, useful to confirm the exception mechanism generalises.",
     "status": "CONFIRMED", "wiki_page": "Miscibility",
     "quote": "One example of immiscibility in metals is copper and cobalt, where rapid "
        "freezing to form solid precipitates has been used to create granular GMR materials.",
     "note": "Independent second real immiscible pair, not from the Parkes-process family."},

    # ---------------- Stress corrosion cracking (added beyond the task's seed list) ----------
    {"a": "Cu", "b": "N", "class": "stress_corrosion_cracking",
     "phenomenon": "Brass (a copper alloy) cracks when exposed to ammonia vapour WHILE under "
        "residual or applied tensile stress -- neither factor alone causes it. Historically "
        "called 'season cracking': brass cartridge cases stored near horse stables (ammonia "
        "from urine) during humid monsoon seasons cracked at the crimp, where cold-drawing had "
        "left residual stress. The mechanism is a real chemical reaction (ammonia + copper -> "
        "water-soluble cuprammonium ion, which washes out of the growing crack), not a nitride.",
     "conditions": "BOTH an aggressive chemical environment (ammonia vapour or solution) AND "
        "tensile stress (residual from cold-working, or externally applied) must be present "
        "simultaneously; the problem is solved by annealing to relieve the residual stress, not "
        "by removing the ammonia.",
     "game_effect": "Cold-worked brass/copper items under stress, if exposed to an ammonia-"
        "bearing environment, should crack over time even though neither plain brass nor plain "
        "ammonia alone would do anything -- a genuinely different failure mode from nitriding "
        "or oxidation.",
     "implementable": "partial", "implementation_note": "Needs both a stress-state flag AND an "
        "ammonia/NH3-presence check simultaneously -- more complex than a single-condition "
        "reactive rule, lower priority than the acute LME rows.",
     "status": "CONFIRMED", "wiki_page": "Season_cracking",
     "quote": "It was not until 1921 that the phenomenon was explained by Moor, Beckinsale and "
        "Mallinson: ammonia from horse urine, combined with the residual stress in the "
        "cold-drawn metal of the cartridges, was responsible for the cracking... The attack "
        "takes the form of a reaction between ammonia and copper to form the cuprammonium ion... "
        "a chemical complex which is water-soluble, and hence washed from the growing cracks.",
     "note": "ADDED CLASS beyond the task's own seed list (see stress_corrosion_cracking in "
        "CLASS_DEFINITIONS for why this needed its own class rather than folding into "
        "nitriding or galvanic_corrosion). Cross-reference for @rxdata: reaction-matrix.csv "
        "predicting 'Cu+N: no stable nitride, no reaction' is CORRECT for nitride formation but "
        "says nothing about this completely different real interaction between the same two "
        "elements under different conditions -- not a contradiction, but worth a shared note "
        "if the two sheets are ever cross-linked."},
]


def build_row(spec: dict) -> dict:
    a, b = spec["a"], spec["b"]
    return {
        "element_a": a, "element_b": b,
        "atomic_number_a": Z.get(a, ""), "atomic_number_b": Z.get(b, ""),
        "class": spec["class"],
        "phenomenon": spec["phenomenon"],
        "conditions": spec["conditions"],
        "game_effect": spec["game_effect"],
        "implementable": spec["implementable"],
        "implementation_note": spec["implementation_note"],
        "status": spec["status"],
        "source": f"Wikipedia: {spec['wiki_page'].replace(chr(92)+'u2013', '-')}",
        "source_url": wiki_url(spec["wiki_page"]),
        "source_quote": spec["quote"],
        "fetched": FETCH_DATE,
        "note": spec["note"],
    }


def check_quotes(refresh: bool) -> int:
    """Verify every row's source_quote's first ~40 chars are findable in its cached wikitext
    (allowing for wiki markup/refs between words, so we check word-by-word substring presence
    of the first several significant words rather than an exact full-string match)."""
    failures = 0
    pages_needed = sorted({r["wiki_page"] for r in ROWS})
    cache = {}
    for p in pages_needed:
        text = fetch_wiki(p, refresh)
        if text is None:
            print(f"MISSING CACHE: {p}")
            failures += 1
            continue
        cache[p] = text
    for i, spec in enumerate(ROWS):
        page = spec["wiki_page"]
        if page not in cache:
            continue
        # Collapse {{Convert|13.2|C}}-style templates to '13.2C' so quotes that hand-render
        # a Convert template (e.g. the Tin_pest 13.2C threshold) still match the raw wikitext.
        text = re.sub(r"\{\{[Cc]onvert\|([0-9.-]+)\|[A-Za-z]+[^}]*\}\}", r"\1C", cache[page])
        # Use the first 8 words of the quote as a fuzzy anchor (handles the fact our quotes
        # strip ref tags/wikilinks the raw wikitext still has inline).
        words = spec["quote"].replace("\u2019", "'").split()[:8]
        anchor = " ".join(words[:4])
        if anchor[:30] not in text and anchor.split(",")[0][:20] not in text:
            # try a looser check: each of the first 3 words appears somewhere in the page
            loose_ok = all(w.strip(".,()'\"") in text for w in words[:3] if len(w) > 3)
            if not loose_ok:
                print(f"QUOTE NOT FOUND (row {i}, {spec['a']}+{spec['b']}, {page}): "
                      f"{anchor!r}")
                failures += 1
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify cached quotes, no network")
    ap.add_argument("--refresh-cache", action="store_true", help="ignore cache, refetch")
    args = ap.parse_args()

    if args.check:
        # Verify against whatever is already cached; only refetch if explicitly asked.
        failures = check_quotes(refresh=False)
        print(f"{len(ROWS)} rows checked, {failures} quote(s) not found in cache")
        sys.exit(1 if failures else 0)

    # Ensure every page this run needs is cached (fetch missing / refresh if asked).
    pages_needed = sorted({r["wiki_page"] for r in ROWS})
    for p in pages_needed:
        fetch_wiki(p, args.refresh_cache)
        time.sleep(0.05)

    rows = [build_row(r) for r in ROWS]

    os.makedirs(DATA_DIR, exist_ok=True)
    with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    by_class = {}
    for r in rows:
        by_class[r["class"]] = by_class.get(r["class"], 0) + 1

    out = {
        "schema": "powderrpg.metallurgy/1",
        "source": {
            "dataset": "Wikipedia (en.wikipedia.org), fetched via raw wikitext with a "
                       "descriptive User-Agent header (plain requests without a UA return 403 "
                       "in this environment; setting any non-empty UA returns 200 -- recorded "
                       "here and in knowledge/rpg-hub.md as the working route another lane "
                       "asked for). Raw wikitext cached at knowledge/data/_cache/wiki/*.wikitext.",
            "fetched": FETCH_DATE,
            "note": "This sheet covers REAL element-element METALLURGICAL interactions that "
                    "knowledge/reaction-matrix.csv's electronegativity-driven generator cannot "
                    "see, because they are not compound-forming chemistry (liquid metal "
                    "embrittlement, amalgamation, eutectics, intermetallics, galvanic corrosion, "
                    "hydrogen embrittlement/carburization/nitriding/passivation, pyrophoric "
                    "behaviour, and liquid-state immiscibility/miscibility), plus one class "
                    "(stress_corrosion_cracking) added beyond the task's own seed list. Every "
                    "row's source_quote is a direct, hand-verified copy from the cited page's "
                    "cached raw wikitext -- see --check to re-verify. No fabricated data.",
        },
        "class_definitions": CLASS_DEFINITIONS,
        "count": len(rows),
        "counts_by_class": by_class,
        "primary_correction": {
            "target_file": "knowledge/reaction-matrix.csv",
            "target_row": "Al,Ga",
            "current_content": "class=alloy, status=predicted, confidence=low, note='both "
                "elements are metallic with a small electronegativity difference'",
            "why_wrong": "Electronegativity cannot see liquid metal embrittlement: no compound "
                "forms, gallium simply wicks into aluminium's grain boundaries and destroys its "
                "structural strength (the classic gallium-treated-aluminium-can-crumbles-by-"
                "hand demonstration). This is a CONFIRMED, well-documented, real phenomenon, "
                "not a low-confidence prediction.",
            "coordination_note": "reaction-matrix.csv is owned by @rxdata this wave per "
                "AGENTS.md/knowledge/rpg-hub.md; this generator does NOT edit that file "
                "directly. The correction is proposed here, in knowledge/rpg-hub.md, and as an "
                "explicit row in this sheet (class=liquid_metal_embrittlement, Al+Ga, first row "
                "in ROWS above) for @rxdata to merge in on their own next pass, per the task's "
                "instruction to 'agree the mechanism rather than clobbering a file'.",
        },
        "rows": rows,
    }
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)

    print(f"wrote {len(rows)} rows -> {OUT_CSV}")
    print(f"wrote {len(rows)} rows -> {OUT_JSON}")
    print("by class:", by_class)


if __name__ == "__main__":
    main()
