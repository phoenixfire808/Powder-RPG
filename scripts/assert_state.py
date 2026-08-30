"""Turn a one-off "call this, check that changed" bridge verification into a
reusable, re-runnable regression check, instead of throwaway curl history.

Almost every verification this session (damageCompanion actually lowering
HP, sliders actually cycling their presets, station tables actually
matching) was a hand-typed curl command checked once and never run again.
This runs the same before/action/after shape as a single command.

Usage:
  python assert_state.py BEFORE_EXPR ACTION_STMT AFTER_EXPR EXPECTED_DELTA

  BEFORE_EXPR / AFTER_EXPR: Lua expressions returning a number, evaluated
    via the bridge before and after ACTION_STMT runs.
  ACTION_STMT: a Lua statement (or semicolon-separated statements) executed
    between the two reads -- typically a function call that changes state.
  EXPECTED_DELTA: the number (after - before) must equal, within a small
    float tolerance.

Example (this session's real damageCompanion verification, made reusable):
  python assert_state.py \\
    "PBX.state.rpg.COMP.hp" \\
    "PBX.state.rpg.damageCompanion(10, 0, 0)" \\
    "PBX.state.rpg.COMP.hp" \\
    "-10"
"""
import sys

from _mcp_bridge import call_bridge

TOL = 1e-6


def read_number(expr: str) -> float:
    result = call_bridge(f"return {expr}")
    try:
        return float(result)
    except ValueError:
        raise RuntimeError(f"expression {expr!r} did not return a number, got: {result!r}")


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__)
        return 1
    before_expr, action_stmt, after_expr, expected_delta_s = sys.argv[1:]
    expected_delta = float(expected_delta_s)

    before = read_number(before_expr)
    call_bridge(action_stmt)
    after = read_number(after_expr)
    actual_delta = after - before

    passed = abs(actual_delta - expected_delta) <= TOL
    print(f"before={before} after={after} delta={actual_delta} expected={expected_delta}")
    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
