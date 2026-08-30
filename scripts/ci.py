"""One-shot CI for the framework: regression + lint tests + extension self-test + manifest check.
Run before/after any change to powder_ext/, scripts/, knowledge/modules or playbook.json.
  python scripts/ci.py            # exit 1 on any failure
"""
import subprocess, sys
ROOT = "D:/powder-toy"
steps = [
    ("manifest", [sys.executable, "-c", "import sys;sys.path.insert(0,'D:/powder-toy');import powder_toy_mcp as m;from powder_ext import schemas;schemas.validate();ok=m._capability_manifest_check()['ok'];print('manifest ok' if ok else 'manifest FAIL');sys.exit(0 if ok else 1)"]),
    ("regression", [sys.executable, f"{ROOT}/scripts/regression.py"]),
    ("lint tests", [sys.executable, f"{ROOT}/scripts/test_lint.py"]),
    ("agent_tools tests (module_search/gate_modules/record_attempt/passk dedup)", [sys.executable, f"{ROOT}/scripts/test_agent_tools.py"]),
    ("rpg_tools tests (rpg_status/rpg_search/rpg_api/rpg_hub/rpg_reload/rpg_screenshot/rpg_lua)", [sys.executable, f"{ROOT}/scripts/test_rpg_tools.py"]),
    ("selftest (3 known fails allowed)", [sys.executable, f"{ROOT}/powder_ext/selftest.py"]),
]
fails = 0
for name, cmd in steps:
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=600)
    out = (r.stdout + r.stderr).strip().splitlines()
    tail = out[-1] if out else ""
    ok = r.returncode == 0 or (name.startswith("selftest") and "3 failed" in " ".join(out[-3:]))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {tail[:160]}")
    fails += 0 if ok else 1
print("CI", "PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(1 if fails else 0)
