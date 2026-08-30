"""Check whether a TPT element is safe to use as terrain/structural fill.

Resolving to a valid element id proves nothing about whether it behaves like
solid ground -- this session's STNE regression (a falling powder used as
bedrock, collapsing a live world) happened exactly because that distinction
got skipped. This is that check, made reusable instead of hand-rolled via
curl each time.

Usage: python check_terrain_solid.py NAME [NAME ...]
"""
import json
import sys

from _mcp_bridge import call_bridge

LUA_TEMPLATE = """
local function id(name)
  local i = elem['DEFAULT_PT_'..name]
  if i then return i end
  for j = 0, 511 do
    local ok, n = pcall(elem.property, j, 'Name')
    if ok and n == name then return j end
  end
  return nil
end
local e = id(%s)
if not e then return 'no_such_element' end
local ok1, fd = pcall(elem.property, e, 'Falldown')
local ok2, props = pcall(elem.property, e, 'Properties')
local solid = ok2 and bit.band(props, elem.TYPE_SOLID) ~= 0
return (fd == 0 and solid) and 'SAFE' or ('UNSAFE falldown='..tostring(fd)..' solid='..tostring(solid))
"""


def check(name: str) -> str:
    try:
        return call_bridge(LUA_TEMPLATE % json.dumps(name))
    except RuntimeError as e:
        return f"ERROR: {e}"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    ok = True
    for name in sys.argv[1:]:
        verdict = check(name)
        print(f"{name}: {verdict}")
        if not verdict.startswith("SAFE"):
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) == 1:
        # ponytail: no args -> run the known-answer self-check instead of just printing usage
        print("self-check (no args given): STNE must be UNSAFE, BSLT must be SAFE")
        stne, bslt = check("STNE"), check("BSLT")
        print(f"STNE: {stne}")
        print(f"BSLT: {bslt}")
        assert not stne.startswith("SAFE"), "STNE is a known falling powder, this should never say SAFE"
        assert bslt.startswith("SAFE"), "BSLT is known solid basalt, this should say SAFE"
        print("self-check passed")
        sys.exit(0)
    sys.exit(main())
