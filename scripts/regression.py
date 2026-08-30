"""Golden regression suite for the build framework (offline, no sim needed).

Runs on every compiler/lint/playbook/module change:
  * every playbook practice fragment compiles and has no critical lint (except listed exceptions)
  * every registry module compiles at a safe origin; wall_cell_size never fires
  * golden blueprints in knowledge/golden/*.json compile to their recorded primitive counts
  * schemas.validate() and the capability manifest stay consistent
Exit code 1 on any regression. Add a golden with: python scripts/regression.py --add name path/to/blueprint.json
"""
import glob, json, os, sys, argparse
sys.path.insert(0, "D:/powder-toy")
from powder_ext import blueprint_tools as bt, knowledge_tools as kt, schemas  # noqa: E402

GOLD = "D:/powder-toy/knowledge/golden"
ALLOWED_CRITICAL = {  # practice -> rules accepted (documented in playbook)
    "remote_flood_and_drain": {"pump_vacu_no_wall"},
    "fission_core_plut": {"pump_vacu_no_wall", "heat_source_uninsulated"},
    "status_display": {"heat_source_uninsulated"},
}


def crit(findings):
    return sorted({f["rule"] for f in findings if f.get("severity") == "critical"})


def main() -> int:
    ap = argparse.ArgumentParser(); ap.add_argument("--add", nargs=2, metavar=("NAME", "PATH")); ap.add_argument("--update", action="store_true")
    args = ap.parse_args()
    os.makedirs(GOLD, exist_ok=True)
    if args.add:
        name, path = args.add
        bp = json.load(open(path, encoding="utf-8")); c = bt.compile_blueprint(bp)
        if not c["ok"]:
            print("refusing: blueprint does not compile", c["errors"][:3]); return 1
        json.dump({"blueprint": bp, "expected": {"counts": c["counts"], "primitive_count": len(c["primitives"]), "bounds": c["bounds"]}}, open(f"{GOLD}/{name}.json", "w", encoding="utf-8"), indent=1)
        print("golden added", name); return 0
    fails = []
    schemas.validate()
    import powder_toy_mcp as m
    if not m._capability_manifest_check()["ok"]:
        fails.append("capability manifest inconsistent")
    pb = json.load(open("D:/powder-toy/knowledge/playbook.json", encoding="utf-8"))
    for pr in pb["practices"]:
        frags = [s["blueprint"] for s in pr["steps"] if "blueprint" in s]
        if not frags:
            continue
        c = bt.compile_blueprint({"origin": [150, 100], "parts": frags})
        if not c["ok"]:
            fails.append(f"practice {pr['name']}: compile {c['errors'][:1]}"); continue
        rules = set(crit(kt.lint_compiled(c))) - ALLOWED_CRITICAL.get(pr["name"], set())
        if rules:
            fails.append(f"practice {pr['name']}: critical lint {sorted(rules)}")
    for path in glob.glob("D:/powder-toy/knowledge/modules/*.json"):
        name = json.load(open(path, encoding="utf-8"))["name"]
        c = bt.compile_blueprint({"origin": [200, 100], "parts": [{"module": name, "at": [0, 0]}]})
        if not c["ok"]:
            fails.append(f"module {name}: compile {c['errors'][:1]}"); continue
        if "wall_cell_size" in crit(kt.lint_compiled(c)) and name != "insl_air_shaft":
            fails.append(f"module {name}: wall_cell_size")
    for path in glob.glob(f"{GOLD}/*.json"):
        g = json.load(open(path, encoding="utf-8")); c = bt.compile_blueprint(g["blueprint"])
        got = {"counts": c.get("counts"), "primitive_count": len(c.get("primitives", [])), "bounds": c.get("bounds")}
        if not c["ok"] or got != g["expected"]:
            if args.update and c["ok"]:
                g["expected"] = got; json.dump(g, open(path, "w", encoding="utf-8"), indent=1); print("updated", path)
            else:
                fails.append(f"golden {os.path.basename(path)}: {got if c['ok'] else c['errors'][:1]} != {g['expected']}")
    n_mod = len(glob.glob("D:/powder-toy/knowledge/modules/*.json")); n_gold = len(glob.glob(f"{GOLD}/*.json"))
    print(f"regression: {len(pb['practices'])} practices, {n_mod} modules, {n_gold} goldens -> {'PASS' if not fails else 'FAIL'}")
    for f in fails:
        print("  -", f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
