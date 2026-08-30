"""SAFETY-LINT regression test for the knowledge-driven blueprint_lint rules
(2026-08-26): every new rule added for custom (define_element) materials --
reactive_hazard, flammable_near_heat, deadly_gas_unsealed, molten_needs_temp,
melt_point_exceeded, conductor_touching_coolant -- fires on a small fixture
that is known to trip it, and the pre-existing rule set still fires on the
older knowledge/fixtures/lint_fixture_blueprint.json.

Custom elements (NA, MG, GRNT, NAS, NBTI, ...) only resolve against a *live*
running game (blueprint_tools.resolve_element asks the game for
define_element materials), so the new-rule fixtures below are stored as
already-*compiled* primitive lists (see each fixtures/lint_fixture_*.json's
"compiled" key) and fed straight to knowledge_tools.lint_compiled -- this
script needs no live game and no sim to run.

Exit code 1 on any regression, same convention as scripts/regression.py.
"""
import glob
import json
import os
import sys

sys.path.insert(0, "D:/powder-toy")
from powder_ext import blueprint_tools as bt, knowledge_tools as kt  # noqa: E402

FIXTURES = "D:/powder-toy/knowledge/fixtures"

# rule -> fixture file whose "compiled" primitives must trip it
NEW_RULE_FIXTURES = {
    "reactive_hazard": "lint_fixture_reactive_hazard.json",
    "flammable_near_heat": "lint_fixture_flammable_near_heat.json",
    "deadly_gas_unsealed": "lint_fixture_deadly_gas_unsealed.json",
    "molten_needs_temp": "lint_fixture_molten_needs_temp.json",
    "melt_point_exceeded": "lint_fixture_melt_point_exceeded.json",
    "conductor_touching_coolant": "lint_fixture_conductor_touching_coolant.json",
}

# rules the pre-existing knowledge/fixtures/lint_fixture_blueprint.json must
# still trip (a subset -- conductor_touching_coolant now also fires on it,
# which is fine, this is a floor not an exact-match)
EXISTING_RULES_EXPECTED = {
    "watr_conductor_adjacency", "heat_source_uninsulated", "cryo_no_cold_temp",
    "pump_vacu_no_wall", "pscn_not_touching_lcry", "clne_no_ctype",
    "channel_reuse", "above_high_temp_transition",
}


def rule_names(findings):
    return {f["rule"] for f in findings}


def load_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return json.load(fh)


def main() -> int:
    fails = []

    # 1. every new rule fires on its dedicated fixture
    for rule, fname in NEW_RULE_FIXTURES.items():
        fixture = load_fixture(fname)
        compiled = fixture["compiled"]
        found = rule_names(kt.lint_compiled(compiled))
        if rule not in found:
            fails.append(f"{fname}: expected rule '{rule}' not in findings {sorted(found)}")
        elif fixture.get("rule") != rule:
            fails.append(f"{fname}: fixture 'rule' field ({fixture.get('rule')!r}) does not match table entry {rule!r}")

    # 2. reactive_hazard's "needs" clause actually gates the finding: MG+FIRE+O2
    #    fires, MG+FIRE alone (no O2 neighbour) does not.
    needs_fixture = load_fixture("lint_fixture_reactive_hazard_needs.json")
    with_o2 = rule_names(kt.lint_compiled(needs_fixture["compiled"]))
    if "reactive_hazard" not in with_o2:
        fails.append("lint_fixture_reactive_hazard_needs.json: MG+FIRE+O2 should trip reactive_hazard")
    without_o2 = rule_names(kt.lint_compiled(needs_fixture["compiled_no_o2"]))
    if "reactive_hazard" in without_o2:
        fails.append("lint_fixture_reactive_hazard_needs.json: MG+FIRE with no O2 neighbour should NOT trip reactive_hazard (needs clause not respected)")

    # 3. conductor_touching_coolant is distinct from watr_conductor_adjacency:
    #    NBTI+LHE (not WATR) must NOT also show up as watr_conductor_adjacency.
    coolant_fixture = load_fixture("lint_fixture_conductor_touching_coolant.json")
    coolant_found = rule_names(kt.lint_compiled(coolant_fixture["compiled"]))
    if "watr_conductor_adjacency" in coolant_found:
        fails.append("lint_fixture_conductor_touching_coolant.json: NBTI+LHE unexpectedly also tripped watr_conductor_adjacency")

    # 4. molten_needs_temp: giving NAS a hot-enough temp prop clears the warning
    #    (mirrors cryo_no_cold_temp's own sanity check).
    nas_ok = {
        "ok": True,
        "bounds": {"x1": 0, "y1": 0, "x2": 3, "y2": 3},
        "primitives": [
            {"kind": "box", "path": "parts[0]", "element": "NAS", "x1": 0, "y1": 0, "x2": 3, "y2": 3},
            {"kind": "set", "path": "parts[1]", "element": "NAS", "x1": 0, "y1": 0, "x2": 3, "y2": 3, "props": {"temp": 620.0}},
        ],
    }
    if "molten_needs_temp" in rule_names(kt.lint_compiled(nas_ok)):
        fails.append("NAS at 620K (above its ~573.15K freeze point) should NOT trip molten_needs_temp")

    # 5. melt_point_exceeded: GRNT set below its highTemperature should NOT fire.
    grnt_ok = {
        "ok": True,
        "bounds": {"x1": 0, "y1": 0, "x2": 3, "y2": 3},
        "primitives": [
            {"kind": "set", "path": "parts[0]", "element": "GRNT", "x1": 0, "y1": 0, "x2": 3, "y2": 3, "props": {"temp": 500.0}},
        ],
    }
    if "melt_point_exceeded" in rule_names(kt.lint_compiled(grnt_ok)):
        fails.append("GRNT at 500K (below its ~1523.15K highTemperature) should NOT trip melt_point_exceeded")

    # 6. pre-existing fixture blueprint still trips its rules (compiles via the
    #    real blueprint compiler -- every element in it is a native/stock id).
    bp = json.load(open(os.path.join(FIXTURES, "lint_fixture_blueprint.json"), encoding="utf-8"))
    compiled = bt.compile_blueprint(bp)
    if not compiled["ok"]:
        fails.append(f"lint_fixture_blueprint.json failed to compile: {compiled['errors'][:3]}")
    else:
        found = rule_names(kt.lint_compiled(compiled))
        missing = EXISTING_RULES_EXPECTED - found
        if missing:
            fails.append(f"lint_fixture_blueprint.json: missing previously-tripped rules {sorted(missing)} (found {sorted(found)})")

    # 7. every fixture file under knowledge/fixtures is at least valid JSON
    #    (catches typos in new fixtures beyond the ones explicitly checked above).
    for path in glob.glob(f"{FIXTURES}/*.json"):
        try:
            json.load(open(path, encoding="utf-8"))
        except json.JSONDecodeError as exc:
            fails.append(f"{os.path.basename(path)}: invalid JSON: {exc}")

    print(f"test_lint: {len(NEW_RULE_FIXTURES)} new rules, {len(EXISTING_RULES_EXPECTED)} pre-existing rules checked -> {'PASS' if not fails else 'FAIL'}")
    for f in fails:
        print("  -", f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
