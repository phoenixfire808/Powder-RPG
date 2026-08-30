"""Check for physics constants duplicated between rpg.lua and companion.lua
where only one side applies the shared R.*Mul slider multiplier.

Real bug pattern this session hit twice: companion.lua keeps its own copy
of physics constants (GRAV, RUN, JUMP, ...) instead of referencing rpg.lua's
copy. When a world-engine slider (R.gravMul, R.runMul) was added to scale
one of these, rpg.lua's own usages were updated but companion.lua's weren't
-- found by hand for GRAV, then again for RUN, before JUMP was checked and
confirmed to already be correct (companion.lua:124 does apply R.jumpMul).
This is a static, source-only check -- no running game needed.

Usage: python check_physics_constant_dup.py
"""
import re
import sys
from pathlib import Path

RPG_LUA = Path("D:/powder-toy/scripts/lua/rpg.lua")
COMPANION_LUA = Path("D:/powder-toy/scripts/lua/rpg_plugins/companion.lua")

DECL_RE = re.compile(r"^local\s+((?:[A-Z][A-Z0-9]*\s*,\s*)*[A-Z][A-Z0-9]*)\s*=\s*[-\d.]", re.MULTILINE)
MUL_RE = re.compile(r"R\.\w*Mul\b")


def declared_names(text: str) -> set[str]:
    names = set()
    for m in DECL_RE.finditer(text):
        names.update(n.strip() for n in m.group(1).split(","))
    return names


def usage_lines(text: str, name: str) -> list[str]:
    pattern = re.compile(r"\b" + re.escape(name) + r"\b")
    return [line for line in text.splitlines() if pattern.search(line) and not line.strip().startswith("local " + name)]


def applies_mul(lines: list[str]) -> bool:
    return any(MUL_RE.search(line) for line in lines)


def main() -> int:
    rpg_text = RPG_LUA.read_text()
    comp_text = COMPANION_LUA.read_text()
    shared = declared_names(rpg_text) & declared_names(comp_text)
    ok = True
    for name in sorted(shared):
        rpg_lines = usage_lines(rpg_text, name)
        comp_lines = usage_lines(comp_text, name)
        rpg_has_mul = applies_mul(rpg_lines)
        comp_has_mul = applies_mul(comp_lines)
        if rpg_has_mul and not comp_has_mul:
            print(f"{name}: DESYNC -- rpg.lua applies an R.*Mul slider to this constant, companion.lua's copy does not")
            ok = False
        else:
            print(f"{name}: ok (rpg_mul={rpg_has_mul}, companion_mul={comp_has_mul})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
