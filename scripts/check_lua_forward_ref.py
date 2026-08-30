"""Check for Lua forward-reference bugs: a name used before its `local
function NAME` definition, with no earlier bare `local NAME` forward
declaration to make it a real upvalue.

Real bug this catches (already fixed by the coordinator, this proves the
checker would have caught it): rpg.lua's `onMouseDown`/`onTick` referenced
`drawTitleScreen`/`titleMouseDown` inside their bodies, but
`local function drawTitleScreen`/`titleMouseDown` were defined LATER in the
file. Lua resolves a bare name's local-vs-global binding at PARSE time, by
textual position, not call time -- a function body compiled before a later
`local function NAME` exists has no local `NAME` in scope yet, so the name
silently compiles as a GLOBAL reference (nil until something assigns to
it), regardless of when the outer function actually runs. That's a
lastingly-nil global, producing "attempt to call a nil value (global
'NAME')" every time the outer function fires. The real fix (confirmed
present in rpg.lua today) is a bare `local drawTitleScreen, titleMouseDown`
forward declaration BEFORE any use, with the real `NAME = function() ...
end` assignment later -- that makes every earlier reference a real upvalue
instead of an accidental global.

Known limitation: line-based, strips `--` line comments only (not `--[[ ]]`
block comments or string contents) -- can false-positive on a name that
only appears inside a block comment or a string literal. Not chasing a full
Lua tokenizer for this; flag and move on if that ever produces noise.

Usage: python check_lua_forward_ref.py [file.lua ...]
       (defaults to rpg.lua and every rpg_plugins/*.lua if no args given)
"""
import re
import sys
from pathlib import Path

DEFAULT_FILES = [Path("D:/powder-toy/scripts/lua/rpg.lua")] + sorted(
    Path("D:/powder-toy/scripts/lua/rpg_plugins").glob("*.lua")
)

FUNC_DEF_RE = re.compile(r"^local\s+function\s+(\w+)\s*\(")
BARE_DECL_RE = re.compile(r"^local\s+((?:\w+\s*,\s*)*\w+)\s*$")


STRING_RE = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')


def strip_comment(line: str) -> str:
    line = STRING_RE.sub('""', line)  # blank quoted strings first -- a "--" or a bare
    idx = line.find("--")             # word inside a string (e.g. changelog text) isn't code
    return line if idx == -1 else line[:idx]


def check_file(path: Path) -> list[str]:
    lines = [strip_comment(l) for l in path.read_text().splitlines()]
    forward_declared: set[str] = set()
    findings = []
    for i, line in enumerate(lines):
        m = BARE_DECL_RE.match(line.strip())
        if m:
            forward_declared.update(n.strip() for n in m.group(1).split(","))
        m = FUNC_DEF_RE.match(line.strip())
        if m:
            name = m.group(1)
            if name in forward_declared:
                continue  # properly forward-declared, this is the safe pattern
            # (?<!\.) excludes NAME reached via dot-access (R.give, t.have, rc.need) --
            # \bNAME\b alone can't tell "the bare global/local NAME" from "some table's
            # .NAME field", since a preceding "." satisfies \b just like whitespace does.
            # (?!\s*=[^=]) excludes NAME as a table-constructor key or assignment target
            # (`have = value`) -- that's a genuinely different thing from a forward
            # reference and was never actually dangerous the way `NAME(...)` is; only a
            # real call/passed-as-value use is the bug class this check exists to find.
            pattern = re.compile(r"(?<!\.)\b" + re.escape(name) + r"\b(?!\s*=[^=])")
            earlier_uses = [j + 1 for j, l in enumerate(lines[:i]) if pattern.search(l)]
            if earlier_uses:
                findings.append(
                    f"{path.name}:{i+1}: `local function {name}` is used at line(s) "
                    f"{earlier_uses} before this definition, with no earlier bare "
                    f"`local {name}` forward declaration -- likely an accidental global"
                )
    return findings


def main() -> int:
    files = [Path(a) for a in sys.argv[1:]] or DEFAULT_FILES
    ok = True
    for f in files:
        findings = check_file(f)
        for msg in findings:
            print(msg)
            ok = False
    if ok:
        print(f"checked {len(files)} file(s), no forward-reference issues found")
    return 0 if ok else 1


def _self_check():
    import tempfile
    broken = "local function A() B() end\nlocal function B() end\n"
    fixed = "local A, B\nlocal function A() B() end\nA = A\nB = function() end\n"
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(broken)
        broken_path = Path(f.name)
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(fixed)
        fixed_path = Path(f.name)
    try:
        assert check_file(broken_path), "broken sample must be flagged"
        assert not check_file(fixed_path), "properly forward-declared sample must NOT be flagged"
        print("self-check passed")
    finally:
        broken_path.unlink()
        fixed_path.unlink()


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
    else:
        sys.exit(main())
