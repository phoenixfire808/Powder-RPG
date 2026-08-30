"""MCP handlers for per-person control (people-pbx-plan.md Phase 4).

Bridge actions: personInspect, personMove, personKill, personSetTrait,
personFeed, personRecolor, worldPlaceHazard (``bridge_src/70_people.lua``).

Async job polling contract is identical to ``colony_tools.py`` (see that
module's module docstring): ``personMove``/``personKill``/``personFeed``/
``personRecolor``/``worldPlaceHazard`` mutate a particle and so answer with a
pending job that ``_settle`` polls to settlement. ``personInspect`` is a pure
read and ``personSetTrait`` only writes an in-memory Lua table (not a sim
particle), so both resolve synchronously -- no job to poll.

``_call_bridge``/``_settle``/``_budget_from`` are reused from
``colony_tools.py`` rather than duplicated, per this repo's central-utilities
rule (two implementations of the same bridge-call/poll plumbing is a bug even
when both work).
"""

from __future__ import annotations

from typing import Any, Callable

from powder_ext.colony_tools import _budget_from, _call_bridge, _settle

_ALLOWED_TRAITS = {"builder", "gatherer", "coward", "brave", "lazy"}
_ALLOWED_HAZARDS = {"fire", "lava", "acid", "void"}
_COLOUR_RE_PREFIX = ("0x", "0X")


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _errors_result(tool: str, errors: list[str]) -> dict[str, Any]:
    return {"ok": False, "tool": tool, "errors": errors}


def _require_particle_id(args: dict[str, Any]) -> tuple[Any, str | None]:
    if "particleId" not in args or args["particleId"] is None:
        return None, "missing required parameter: particleId"
    value = args["particleId"]
    if not _is_int(value) or value < 0:
        return None, "particleId must be a non-negative integer"
    return value, None


def _require_pixel(args: dict[str, Any], errors: list[str]) -> tuple[Any, Any]:
    x = args.get("x")
    y = args.get("y")
    for key, value in (("x", x), ("y", y)):
        if value is None:
            errors.append(f"missing required parameter: {key}")
        elif not _is_int(value):
            errors.append(f"{key} must be an integer")
    return x, y


def person_inspect(arguments: dict[str, Any]) -> dict[str, Any]:
    """`personInspect` -- synchronous read-only."""
    tool = "person_inspect"
    args = arguments or {}
    particle_id, err = _require_particle_id(args)
    if err:
        return _errors_result(tool, [err])

    result = _call_bridge("personInspect", {"particleId": particle_id})
    result.setdefault("tool", tool)
    return result


def person_move(arguments: dict[str, Any]) -> dict[str, Any]:
    """`personMove` -- async. Moves one particle to a pixel position."""
    tool = "person_move"
    args = arguments or {}
    errors: list[str] = []

    particle_id, err = _require_particle_id(args)
    if err:
        errors.append(err)
    x, y = _require_pixel(args, errors)
    if errors:
        return _errors_result(tool, errors)

    result = _settle(_call_bridge("personMove", {"particleId": particle_id, "x": x, "y": y}), _budget_from(args))
    result.setdefault("tool", tool)
    return result


def person_kill(arguments: dict[str, Any]) -> dict[str, Any]:
    """`personKill` -- async. `cause` optional (bridge defaults to "ordered")."""
    tool = "person_kill"
    args = arguments or {}
    errors: list[str] = []

    particle_id, err = _require_particle_id(args)
    if err:
        errors.append(err)
    params: dict[str, Any] = {"particleId": particle_id}
    if "cause" in args and args["cause"] is not None:
        cause = args["cause"]
        if not isinstance(cause, str) or not (1 <= len(cause) <= 32):
            errors.append("cause must be a string of 1-32 characters")
        else:
            params["cause"] = cause
    if errors:
        return _errors_result(tool, errors)

    result = _settle(_call_bridge("personKill", params), _budget_from(args))
    result.setdefault("tool", tool)
    return result


def person_set_trait(arguments: dict[str, Any]) -> dict[str, Any]:
    """`personSetTrait` -- synchronous (in-memory table write, not a sim mutation)."""
    tool = "person_set_trait"
    args = arguments or {}
    errors: list[str] = []

    particle_id, err = _require_particle_id(args)
    if err:
        errors.append(err)
    trait = args.get("trait")
    if not isinstance(trait, str) or trait not in _ALLOWED_TRAITS:
        errors.append(f"trait must be one of {sorted(_ALLOWED_TRAITS)}")
    if errors:
        return _errors_result(tool, errors)

    result = _call_bridge("personSetTrait", {"particleId": particle_id, "trait": trait})
    result.setdefault("tool", tool)
    return result


def person_feed(arguments: dict[str, Any]) -> dict[str, Any]:
    """`personFeed` -- async. `amount` is added to `life`, capped at WORKER_LIFE."""
    tool = "person_feed"
    args = arguments or {}
    errors: list[str] = []

    particle_id, err = _require_particle_id(args)
    if err:
        errors.append(err)
    amount = args.get("amount")
    if not _is_int(amount) or not (1 <= amount <= 100000):
        errors.append("amount must be an integer between 1 and 100000")
    if errors:
        return _errors_result(tool, errors)

    result = _settle(_call_bridge("personFeed", {"particleId": particle_id, "amount": amount}), _budget_from(args))
    result.setdefault("tool", tool)
    return result


def person_recolor(arguments: dict[str, Any]) -> dict[str, Any]:
    """`personRecolor` -- async. `colour` is 0xAARRGGBB, written to `dcolour`."""
    tool = "person_recolor"
    args = arguments or {}
    errors: list[str] = []

    particle_id, err = _require_particle_id(args)
    if err:
        errors.append(err)
    colour = args.get("colour")
    if (
        not isinstance(colour, str)
        or len(colour) != 10
        or not colour.startswith(_COLOUR_RE_PREFIX)
        or not all(c in "0123456789abcdefABCDEF" for c in colour[2:])
    ):
        errors.append("colour must be an 0xAARRGGBB string (10 characters)")
    if errors:
        return _errors_result(tool, errors)

    result = _settle(
        _call_bridge("personRecolor", {"particleId": particle_id, "colour": colour}), _budget_from(args)
    )
    result.setdefault("tool", tool)
    return result


def world_place_hazard(arguments: dict[str, Any]) -> dict[str, Any]:
    """`worldPlaceHazard` -- async. Drops one base-TPT hazard element at (x, y)."""
    tool = "world_place_hazard"
    args = arguments or {}
    errors: list[str] = []

    x, y = _require_pixel(args, errors)
    kind = args.get("kind")
    if not isinstance(kind, str) or kind not in _ALLOWED_HAZARDS:
        errors.append(f"kind must be one of {sorted(_ALLOWED_HAZARDS)}")
    if errors:
        return _errors_result(tool, errors)

    result = _settle(_call_bridge("worldPlaceHazard", {"x": x, "y": y, "kind": kind}), _budget_from(args))
    result.setdefault("tool", tool)
    return result


# ---------------------------------------------------------------------------
# HANDLERS registry -- named PEOPLE_RAW_HANDLERS/PEOPLE_HANDLERS to avoid
# colliding with colony_tools's module-level names on import.
# ---------------------------------------------------------------------------

PEOPLE_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "person_inspect": person_inspect,
    "person_move": person_move,
    "person_kill": person_kill,
    "person_set_trait": person_set_trait,
    "person_feed": person_feed,
    "person_recolor": person_recolor,
    "world_place_hazard": world_place_hazard,
}


def _guarded(tool_name: str, fn: Callable[[dict[str, Any]], dict[str, Any]]) -> Callable[[dict[str, Any]], dict[str, Any]]:
    """Wrap a handler so it truly never raises, even on a bug in this file."""

    def wrapper(arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            return fn(arguments if isinstance(arguments, dict) else {})
        except Exception as exc:  # last-resort safety net
            return {
                "ok": False,
                "tool": tool_name,
                "error": "internal_error",
                "detail": f"{type(exc).__name__}: {exc}",
            }

    return wrapper


PEOPLE_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    name: _guarded(name, fn) for name, fn in PEOPLE_RAW_HANDLERS.items()
}
