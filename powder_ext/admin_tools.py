"""MCP handlers for live extension administration (hot-patch primitive).

Mirrors colony_tools.py's `_call_bridge`/`_guarded`/`_RAW_HANDLERS`/`HANDLERS`
pattern exactly, but this module owns exactly one action: `executeLua`, the
`loadstring(code)` + `pcall` escape hatch already implemented in
_base/bridge_base.lua:941-948 with no MCP wrapper until now.

Real boundary (see bridge_src/40_worker.lua's own header note on Lua 5.1
closures, and EXTENSION_SPEC.md): a chunk run through `executeLua` can define
or patch elements, register new behavior kinds on
`PBX.state.behaviors.kinds` (a plain table published by 20_behaviors.lua),
and run arbitrary one-off world mutations -- but it CANNOT add a new task
`kind` string, because 50_tasks.lua's `KINDS` table and the function that
validates against it are `local` inside that module's closure, unreachable
from a separately-loaded `loadstring` chunk. New task kinds still require a
bridge_src/50_tasks.lua edit, `python build_autorun.py`, and a powder.exe
restart.
"""

from __future__ import annotations

from typing import Any, Callable

from powder_bridge.client import PowderAPIError, PowderConnectionError, PowderClient
from powder_bridge.logging import resolve_correlation_id

_client: PowderClient | None = None


def _get_client() -> PowderClient:
    """Lazily construct the module-local PowderClient singleton."""
    global _client
    if _client is None:
        _client = PowderClient()
    return _client


def _call_bridge(action: str, params: dict[str, Any]) -> dict[str, Any]:
    """POST one bridge action and normalize every outcome into a plain dict.

    Identical contract to colony_tools._call_bridge: never raises, always
    attaches a correlation id.
    """
    client = _get_client()
    cid = resolve_correlation_id()
    payload = dict(params)
    payload["action"] = action
    payload.setdefault("correlation_id", cid)
    try:
        result = client._post(payload)
    except PowderAPIError as exc:
        result = dict(exc.response) if isinstance(exc.response, dict) else {}
        result.setdefault("ok", False)
        result.setdefault("action", exc.action or action)
        result.setdefault("error", exc.error)
        if exc.detail and "detail" not in result:
            result["detail"] = exc.detail
        result.setdefault("correlation_id", cid)
        return result
    except PowderConnectionError as exc:
        return {
            "ok": False,
            "action": action,
            "error": "transport_error",
            "detail": str(exc),
            "correlation_id": cid,
        }
    except Exception as exc:  # defensive: a handler must never raise
        return {
            "ok": False,
            "action": action,
            "error": type(exc).__name__,
            "detail": str(exc),
            "correlation_id": cid,
        }
    if not isinstance(result, dict):
        return {
            "ok": False,
            "action": action,
            "error": "invalid_response",
            "detail": "bridge returned a non-object body",
            "correlation_id": cid,
        }
    result.setdefault("correlation_id", cid)
    return result


def execute_lua(arguments: dict[str, Any]) -> dict[str, Any]:
    """`executeLua` -- run one Lua chunk in the live bridge interpreter.

    Synchronous: `_base/bridge_base.lua`'s `executeLua` branch runs the
    `loadstring`+`pcall` inline on the socket thread and returns the result
    immediately, no job polling. Can define/patch elements, mutate
    `PBX.state.behaviors.kinds`, and run one-off world edits; cannot add a
    new `50_tasks.lua` task `kind` (that table is `local` to a module this
    chunk never sees) -- that still needs a source edit + build_autorun.py
    + restart.
    """
    tool = "execute_lua"
    args = arguments or {}
    code = args.get("code")
    if not isinstance(code, str) or not code.strip():
        return {"ok": False, "tool": tool, "errors": ["code must be a non-empty string"]}

    result = _call_bridge("executeLua", {"code": code})
    result.setdefault("tool", tool)
    return result


# ---------------------------------------------------------------------------
# HANDLERS registry
# ---------------------------------------------------------------------------

_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "execute_lua": execute_lua,
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


HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    name: _guarded(name, fn) for name, fn in _RAW_HANDLERS.items()
}
