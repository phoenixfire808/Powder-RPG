"""MCP tool handlers for custom-element lifecycle actions.

Owns: ``define_element``, ``list_custom_elements``, ``update_element``,
``delete_custom_element`` -> bridge actions ``defineElement``,
``listCustomElements``, ``updateElement``, ``deleteCustomElement``
(see EXTENSION_SPEC.md section 4.1).

Job-polling contract (read this before touching anything below)
-----------------------------------------------------------------
Per EXTENSION_SPEC.md section 2.4, ``defineElement``, ``updateElement`` and
``deleteCustomElement`` mutate live elements (``elements.allocate`` /
``elements.element`` / ``elements.property``), and that is illegal to do
inside the bridge's own HTTP handler -- TPT asserts
(``LuaElements.cpp: AssertMutableToolsEvent``) if a mutable-tools call happens
on the handler thread instead of the simulation thread. So the Lua side defers
the actual work with ``PBX.defer(fn)`` and the HTTP handler returns
*immediately* with::

    {"ok": true, "action": "defineElement", "job": <id>, "status": "pending"}

There is **no synchronous wait** on the Lua side -- blocking the handler
until the job drains would deadlock against the very lock the tick needs to
take. The job only actually runs (and "drains") on the next ``event.TICK``,
and at most 8 jobs drain per tick.

That means *this* module is the only place that can turn "a job was queued"
into "here is what happened" for the model. Each of the three mutating
handlers below calls the bridge, and if the response says
``status == "pending"``, hands the returned ``job`` id to ``_await_job``,
which polls the bridge's built-in ``jobStatus`` action
(``{"action": "jobStatus", "job": <id>}``) until it reports
``status == "done"`` -- then returns one settled result.

Because jobs only drain on TICK, a paused or stalled simulation means the job
may **never** settle. ``_await_job`` is therefore bounded two ways: a total
wall-clock budget (default 3.0s, override per call with ``timeout_s`` in the
tool arguments, clamped to a sane maximum) and a hard cap on the number of
poll iterations, so it can never spin or hang indefinitely. It sleeps briefly
(50ms) between polls rather than busy-waiting. On timeout it returns
``ok: False``, ``status: "pending"``, the ``job`` id and a ``hint`` telling
the caller the simulation may be paused and that the job can be re-checked
later -- it never reports success for a job that has not actually settled.

``_await_job`` takes a plain ``PowderClient`` and a job id and knows nothing
about element-specific payloads, so it is intentionally reusable: the colony
task handlers (owned by a different module, facing the exact same deferred
job protocol for ``colonyCreate``/``colonySpawnWorkers``/task actions etc.)
can do ``from powder_ext.element_tools import _await_job`` rather than
reimplementing this polling loop.

Transport note
--------------
There is no typed ``PowderClient`` method yet for ``defineElement`` /
``listCustomElements`` / ``updateElement`` / ``deleteCustomElement`` /
``jobStatus`` -- every existing typed method (``place_element``,
``get_simulation_state``, etc., see ``D:/powder-toy/powder_bridge/client.py``)
is a thin wrapper that ultimately calls ``PowderClient._post({"action": ...,
...})``. Since these four bridge actions have no dedicated wrapper, this
module calls ``PowderClient._post`` directly -- that *is* the transport every
other tool in this codebase uses; it already handles token injection,
correlation-id assignment, JSON parsing, byte-budget errors, and turns
``ok: false`` responses into ``PowderAPIError``. Nothing about the HTTP/JSON
transport is reinvented here.
"""

from __future__ import annotations

import math
import re
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

# Make the project root importable even if this module is loaded standalone
# (e.g. ad-hoc testing) rather than via powder_toy_mcp.py, which already
# inserts its own directory onto sys.path before importing extension code.
_PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from powder_bridge.client import (  # noqa: E402
    PowderAPIError,
    PowderClient,
    PowderConnectionError,
)

# ---------------------------------------------------------------------------
# Bridge client (mirrors the lazy singleton in powder_toy_mcp.py)
# ---------------------------------------------------------------------------

_client: PowderClient | None = None


def _get_client() -> PowderClient:
    """Return a lazily-constructed shared ``PowderClient`` for this process."""
    global _client
    if _client is None:
        _client = PowderClient(host="127.0.0.1", port=9876, timeout=10.0)
    return _client


# ---------------------------------------------------------------------------
# Deferred-job polling (reusable -- see module docstring)
# ---------------------------------------------------------------------------

_DEFAULT_JOB_BUDGET_S = 3.0
_MAX_JOB_BUDGET_S = 10.0          # hard ceiling even if a caller asks for more
_JOB_POLL_INTERVAL_S = 0.05       # 50ms between polls; short, not spinning
_JOB_HARD_POLL_CAP = 500          # absolute safety net regardless of budget math


def _await_job(
    client: PowderClient,
    job_id: Any,
    budget_s: float = _DEFAULT_JOB_BUDGET_S,
) -> dict[str, Any]:
    """Poll ``jobStatus`` for ``job_id`` until it settles or the budget runs out.

    Returns a single settled dict, never raises, and never blocks indefinitely:

    * ``status == "done"``: ``{"ok": <succeeded>, "status": "done", "job": ...,
      "value": ..., "detail": ..., "polls": <n>}``.
    * budget/poll cap exhausted while still pending: ``{"ok": False,
      "status": "pending", "job": ..., "polls": <n>, "hint": "..."}`` -- this
      is NOT reported as success, because the job may simply be waiting on a
      paused simulation to tick.
    * a transport/API error while polling: ``{"ok": False, "status": "error",
      "job": ..., "error": ..., "detail": ...}``.

    Bounded two independent ways -- wall-clock budget and poll-count cap --
    derived from each other so neither one alone can make this loop run
    longer than ``budget_s`` (clamped to ``_MAX_JOB_BUDGET_S``) actually
    allows, no matter what budget a caller passes in.
    """
    budget_s = max(0.0, min(float(budget_s), _MAX_JOB_BUDGET_S))
    deadline = time.monotonic() + budget_s
    max_polls = min(_JOB_HARD_POLL_CAP, int(budget_s / _JOB_POLL_INTERVAL_S) + 2)

    polls = 0
    while True:
        polls += 1
        try:
            poll_response = client._post({"action": "jobStatus", "job": job_id})
        except PowderAPIError as exc:
            response_payload = exc.response if isinstance(exc.response, dict) else {}
            return {
                "ok": False,
                "status": "error",
                "job": job_id,
                "error": exc.error,
                "detail": exc.detail,
                "polls": polls,
                "correlation_id": response_payload.get("correlation_id"),
            }
        except PowderConnectionError as exc:
            return {
                "ok": False,
                "status": "error",
                "job": job_id,
                "error": "transport_error",
                "detail": str(exc),
                "polls": polls,
            }

        if not isinstance(poll_response, dict):
            return {
                "ok": False,
                "status": "error",
                "job": job_id,
                "error": "transport_error",
                "detail": "jobStatus returned a non-object response",
                "polls": polls,
            }

        status = poll_response.get("status")
        if status == "done":
            succeeded = poll_response.get("succeeded")
            ok = bool(succeeded) if succeeded is not None else bool(poll_response.get("ok", True))
            return {
                "ok": ok,
                "status": "done",
                "job": job_id,
                "value": poll_response.get("value"),
                "detail": poll_response.get("detail"),
                "polls": polls,
                "correlation_id": poll_response.get("correlation_id"),
            }

        if time.monotonic() >= deadline or polls >= max_polls:
            return {
                "ok": False,
                "status": "pending",
                "job": job_id,
                "polls": polls,
                "correlation_id": poll_response.get("correlation_id"),
                "hint": (
                    f"Job did not settle within the poll budget ({budget_s:.1f}s, "
                    f"{polls} polls). Jobs only drain on the simulation TICK, so a "
                    "paused or stalled simulation can leave this pending "
                    f"indefinitely. Check whether the simulation is paused, then "
                    f"re-check by calling jobStatus with job={job_id!r}, or retry "
                    "the original call."
                ),
            }

        time.sleep(_JOB_POLL_INTERVAL_S)


def _call_deferred_action(
    tool: str,
    action: str,
    payload: dict[str, Any],
    budget_s: float,
) -> dict[str, Any]:
    """Send a bridge action expected to defer to a job, then poll it to settlement.

    Always returns a plain dict with at least ``ok`` and ``tool``; never raises.
    """
    client = _get_client()
    try:
        response = client._post({"action": action, **payload})
    except PowderAPIError as exc:
        response_payload = exc.response if isinstance(exc.response, dict) else {}
        return {
            "ok": False,
            "tool": tool,
            "action": action,
            "error": exc.error,
            "detail": exc.detail,
            "correlation_id": response_payload.get("correlation_id"),
        }
    except PowderConnectionError as exc:
        return {
            "ok": False,
            "tool": tool,
            "action": action,
            "error": "transport_error",
            "detail": str(exc),
        }
    except Exception as exc:  # a handler must never raise
        return {
            "ok": False,
            "tool": tool,
            "action": action,
            "error": "unexpected_error",
            "detail": f"{type(exc).__name__}: {exc}",
        }

    if not isinstance(response, dict):
        return {
            "ok": False,
            "tool": tool,
            "action": action,
            "error": "transport_error",
            "detail": "bridge returned a non-object response",
        }

    correlation_id = response.get("correlation_id")

    if response.get("status") == "pending" and "job" in response:
        settled = _await_job(client, response["job"], budget_s=budget_s)
        result: dict[str, Any] = dict(settled)
        result["tool"] = tool
        result["action"] = action
        if correlation_id is not None and not result.get("correlation_id"):
            result["correlation_id"] = correlation_id
        return result

    # Defensive: if a future bridge revision ever settles one of these
    # synchronously (e.g. a true no-op), pass it through rather than assuming
    # every response must carry a job.
    result = dict(response)
    result.setdefault("ok", True)
    result["tool"] = tool
    result.setdefault("action", action)
    return result


# ---------------------------------------------------------------------------
# schemas.py is owned by another author and may not exist yet -- guard it.
# ---------------------------------------------------------------------------


def _tool_description(tool: str) -> str | None:
    """Best-effort lookup of a tool's one-line description from schemas.py.

    Guarded because ``powder_ext/schemas.py`` is being written concurrently;
    if it is missing or broken this quietly returns ``None`` instead of
    breaking this module's import or any handler.
    """
    try:
        from powder_ext.schemas import TOOL_DESCRIPTIONS
    except Exception:
        return None
    if not isinstance(TOOL_DESCRIPTIONS, dict):
        return None
    return TOOL_DESCRIPTIONS.get(tool)


# ---------------------------------------------------------------------------
# Local argument validation (fail fast, before ever hitting the bridge)
# ---------------------------------------------------------------------------

_NAME_RE = re.compile(r"^[A-Z0-9]{1,4}$")
_ELEMENT_TYPES = ("PART", "LIQUID", "SOLID", "GAS", "ENERGY")
_KNOWN_BEHAVIOR_KINDS = frozenset(
    {"inert", "glower", "decayer", "emitter", "grower", "pheromone", "conductor", "creature",
     "absorber", "turbine", "teg", "photovoltaic", "piezo", "pcm", "reactive"}  # last three: runtime kinds from scripts/lua/power_kinds.lua
)

_MAX_DESCRIPTION_LEN = 500
_MAX_MENU_SECTION_LEN = 64
_MAX_GROUP_LEN = 16
_MAX_PROPERTIES = 16
_MAX_PROPERTY_NAME_LEN = 32
_MAX_BEHAVIOR_PARAMS = 32
_MAX_TRANSITION_NAME_LEN = 32

_COLOUR_MIN, _COLOUR_MAX = 0, 0xFFFFFF
_TEMP_MIN, _TEMP_MAX = -273.15, 100_000.0
_HARDNESS_MIN, _HARDNESS_MAX = 0, 100
_WEIGHT_MIN, _WEIGHT_MAX = -1_000, 1_000
_GRAVITY_MIN, _GRAVITY_MAX = -100.0, 100.0
_DIFFUSION_MIN, _DIFFUSION_MAX = 0.0, 100.0
_FLAMMABLE_MIN, _FLAMMABLE_MAX = 0, 1_000
_EXPLOSIVE_MIN, _EXPLOSIVE_MAX = 0, 1_000
_HEATCONDUCT_MIN, _HEATCONDUCT_MAX = 0, 255

# Note: numeric bounds above are conservative client-side guards meant to
# catch obviously-wrong values (wrong type, wildly out of range) fast and
# with a clear message. The bridge's own PBX.vInt/vNum calls (00_util.lua,
# EXTENSION_SPEC.md section 2.3) are the authoritative range check; we are
# not attempting to replicate their exact per-field bounds here.


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _err(tool: str, errors: list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {"ok": False, "tool": tool, "errors": list(errors)}
    description = _tool_description(tool)
    if description:
        result["tool_description"] = description
    return result


def _validate_name(value: Any, errors: list[str]) -> str | None:
    if not isinstance(value, str):
        errors.append("name must be a string")
        return None
    candidate = value.strip().upper()
    if not _NAME_RE.match(candidate):
        errors.append("name must be 1-4 characters, A-Z0-9 only, no underscores")
        return None
    return candidate


def _check_number(
    args: dict[str, Any], key: str, errors: list[str], lo: float, hi: float, out: dict[str, Any]
) -> None:
    if key not in args:
        return
    value = args[key]
    if not _is_number(value):
        errors.append(f"{key} must be a finite number")
        return
    if not (lo <= value <= hi):
        errors.append(f"{key} must be between {lo} and {hi}")
        return
    out[key] = value


def _check_string(
    args: dict[str, Any], key: str, errors: list[str], out: dict[str, Any], max_len: int
) -> None:
    if key not in args:
        return
    value = args[key]
    if not isinstance(value, str) or len(value) > max_len:
        errors.append(f"{key} must be a string of at most {max_len} characters")
        return
    out[key] = value


def _check_transition(args: dict[str, Any], key: str, errors: list[str], out: dict[str, Any]) -> None:
    if key not in args:
        return
    value = args[key]
    if value is None:
        out[key] = None
        return
    if not isinstance(value, str) or not (1 <= len(value) <= _MAX_TRANSITION_NAME_LEN):
        errors.append(f"{key} must be an element name string, or null for no transition")
        return
    out[key] = value.strip().upper()


def _check_colour(args: dict[str, Any], key: str, errors: list[str], out: dict[str, Any]) -> None:
    if key not in args:
        return
    value = args[key]
    if isinstance(value, bool):
        errors.append(f"{key} must be an integer 0..0xFFFFFF or a 6-digit hex RRGGBB string")
        return
    if isinstance(value, int):
        colour = value
    elif isinstance(value, str):
        text = value.strip()
        if text.lower().startswith("0x"):
            text = text[2:]
        elif text.startswith("#"):
            text = text[1:]
        if not re.fullmatch(r"[0-9A-Fa-f]{6}", text):
            errors.append(f"{key} string must be 6 hex digits (RRGGBB), optionally prefixed 0x or #")
            return
        colour = int(text, 16)
    else:
        errors.append(f"{key} must be an integer 0..0xFFFFFF or a 6-digit hex RRGGBB string")
        return
    if not (_COLOUR_MIN <= colour <= _COLOUR_MAX):
        errors.append(f"{key} out of range 0..0xFFFFFF")
        return
    out[key] = colour


def _check_type(args: dict[str, Any], errors: list[str], out: dict[str, Any]) -> None:
    if "type" not in args:
        return
    value = args["type"]
    if not isinstance(value, str) or value.strip().upper() not in _ELEMENT_TYPES:
        errors.append(f"type must be one of {', '.join(_ELEMENT_TYPES)}")
        return
    out["type"] = value.strip().upper()


def _check_properties(args: dict[str, Any], errors: list[str], out: dict[str, Any]) -> None:
    if "properties" not in args:
        return
    value = args["properties"]
    if not isinstance(value, list) or len(value) > _MAX_PROPERTIES:
        errors.append(f"properties must be an array of at most {_MAX_PROPERTIES} flag names")
        return
    cleaned: list[str] = []
    ok = True
    for index, item in enumerate(value):
        if not isinstance(item, str) or not (1 <= len(item) <= _MAX_PROPERTY_NAME_LEN):
            errors.append(f"properties[{index}] must be a short flag-name string")
            ok = False
            continue
        cleaned.append(item.strip().upper())
    if ok:
        out["properties"] = cleaned


def _check_behavior(args: dict[str, Any], errors: list[str], out: dict[str, Any]) -> None:
    if "behavior" not in args:
        return
    value = args["behavior"]
    if not isinstance(value, dict):
        errors.append("behavior must be an object with 'kind' and optional 'params'")
        return
    kind = value.get("kind")
    if not isinstance(kind, str) or not kind.strip():
        errors.append("behavior.kind must be a non-empty string")
        return
    normalized_kind = kind.strip().lower()
    if normalized_kind not in _KNOWN_BEHAVIOR_KINDS:
        errors.append(
            "behavior.kind must be one of "
            f"{', '.join(sorted(_KNOWN_BEHAVIOR_KINDS))} (per 20_behaviors.lua)"
        )
        return
    params = value.get("params", {})
    if not isinstance(params, dict) or len(params) > _MAX_BEHAVIOR_PARAMS:
        errors.append(f"behavior.params must be an object with at most {_MAX_BEHAVIOR_PARAMS} entries")
        return
    for param_key, param_value in params.items():
        if not isinstance(param_key, str):
            errors.append("behavior.params keys must be strings")
            return
        if not (_is_number(param_value) or isinstance(param_value, (str, bool)) or param_value is None):
            errors.append(f"behavior.params[{param_key}] must be a number, string, bool, or null")
            return
    out["behavior"] = {"kind": normalized_kind, "params": dict(params)}


def _check_group(args: dict[str, Any], errors: list[str], out: dict[str, Any], *, default_if_absent: str | None) -> None:
    if "group" in args:
        value = args["group"]
        if not isinstance(value, str) or not (1 <= len(value) <= _MAX_GROUP_LEN):
            errors.append(f"group must be a string of 1-{_MAX_GROUP_LEN} characters")
            return
        out["group"] = value.strip().upper()
    elif default_if_absent is not None:
        out["group"] = default_if_absent


_DEFINE_FIELD_KEYS = {
    "name", "group", "description", "colour", "menuSection", "type",
    "properties", "temperature", "highTemperature", "highTemperatureTransition",
    "lowTemperature", "lowTemperatureTransition", "hardness", "weight",
    "gravity", "diffusion", "flammable", "explosive", "heatConduct", "behavior",
    "timeout_s",  # our own job-poll budget override; stripped before hitting the bridge
}


def _validate_define_fields(
    args: dict[str, Any], errors: list[str], *, default_group: str | None
) -> dict[str, Any]:
    """Validate the fields shared by ``define_element`` and ``update_element``.

    Returns only the fields that were both present and valid (``define``
    injects the ``group`` default when absent; ``update`` never invents a
    default so it only ever changes what was actually supplied).
    """
    out: dict[str, Any] = {}
    _check_group(args, errors, out, default_if_absent=default_group)
    _check_string(args, "description", errors, out, _MAX_DESCRIPTION_LEN)
    _check_colour(args, "colour", errors, out)
    _check_string(args, "menuSection", errors, out, _MAX_MENU_SECTION_LEN)
    _check_type(args, errors, out)
    _check_properties(args, errors, out)
    for key in ("temperature", "highTemperature", "lowTemperature"):
        _check_number(args, key, errors, _TEMP_MIN, _TEMP_MAX, out)
    _check_transition(args, "highTemperatureTransition", errors, out)
    _check_transition(args, "lowTemperatureTransition", errors, out)
    _check_number(args, "hardness", errors, _HARDNESS_MIN, _HARDNESS_MAX, out)
    _check_number(args, "weight", errors, _WEIGHT_MIN, _WEIGHT_MAX, out)
    _check_number(args, "gravity", errors, _GRAVITY_MIN, _GRAVITY_MAX, out)
    _check_number(args, "diffusion", errors, _DIFFUSION_MIN, _DIFFUSION_MAX, out)
    _check_number(args, "flammable", errors, _FLAMMABLE_MIN, _FLAMMABLE_MAX, out)
    _check_number(args, "explosive", errors, _EXPLOSIVE_MIN, _EXPLOSIVE_MAX, out)
    _check_number(args, "heatConduct", errors, _HEATCONDUCT_MIN, _HEATCONDUCT_MAX, out)
    _check_behavior(args, errors, out)

    unknown = sorted(set(args) - _DEFINE_FIELD_KEYS)
    if unknown:
        errors.append(f"unknown field(s): {', '.join(unknown)}")

    return out


def _validate_timeout(args: dict[str, Any], errors: list[str]) -> float:
    if "timeout_s" not in args:
        return _DEFAULT_JOB_BUDGET_S
    value = args["timeout_s"]
    if not _is_number(value) or value <= 0:
        errors.append("timeout_s must be a positive finite number of seconds")
        return _DEFAULT_JOB_BUDGET_S
    return min(float(value), _MAX_JOB_BUDGET_S)


# ---------------------------------------------------------------------------
# Public handlers
# ---------------------------------------------------------------------------


def _handle_define_element(arguments: dict[str, Any]) -> dict[str, Any]:
    """Create (or, if the name already exists, in-place update) a custom element."""
    tool = "define_element"
    if not isinstance(arguments, dict):
        return _err(tool, ["arguments must be an object"])
    errors: list[str] = []
    name = _validate_name(arguments.get("name"), errors)
    budget_s = _validate_timeout(arguments, errors)
    fields = _validate_define_fields(arguments, errors, default_group="PBX")
    if errors:
        return _err(tool, errors)
    payload = dict(fields)
    payload["name"] = name
    return _call_deferred_action(tool, "defineElement", payload, budget_s)


def _handle_update_element(arguments: dict[str, Any]) -> dict[str, Any]:
    """Change a subset of fields on an existing custom element."""
    tool = "update_element"
    if not isinstance(arguments, dict):
        return _err(tool, ["arguments must be an object"])
    errors: list[str] = []
    name = _validate_name(arguments.get("name"), errors)
    budget_s = _validate_timeout(arguments, errors)
    fields = _validate_define_fields(arguments, errors, default_group=None)
    if not errors and not fields:
        errors.append("update_element requires at least one field to change besides name")
    if errors:
        return _err(tool, errors)
    payload = dict(fields)
    payload["name"] = name
    return _call_deferred_action(tool, "updateElement", payload, budget_s)


def _handle_delete_custom_element(arguments: dict[str, Any]) -> dict[str, Any]:
    """Free a previously-defined custom element."""
    tool = "delete_custom_element"
    if not isinstance(arguments, dict):
        return _err(tool, ["arguments must be an object"])
    errors: list[str] = []
    name = _validate_name(arguments.get("name"), errors)
    budget_s = _validate_timeout(arguments, errors)
    unknown = sorted(set(arguments) - {"name", "timeout_s"})
    if unknown:
        errors.append(f"unknown field(s): {', '.join(unknown)}")
    if errors:
        return _err(tool, errors)
    return _call_deferred_action(tool, "deleteCustomElement", {"name": name}, budget_s)


def _handle_list_custom_elements(arguments: dict[str, Any]) -> dict[str, Any]:
    """List all currently registered custom elements. Synchronous -- no job to poll."""
    tool = "list_custom_elements"
    if arguments is not None and not isinstance(arguments, dict):
        return _err(tool, ["arguments must be an object"])
    # No fields are required or recognized for this tool; extra keys are
    # ignored rather than rejected, since a stray empty-object call pattern
    # from the model shouldn't be treated as a hard error here.

    client = _get_client()
    try:
        response = client._post({"action": "listCustomElements"})
    except PowderAPIError as exc:
        response_payload = exc.response if isinstance(exc.response, dict) else {}
        return {
            "ok": False,
            "tool": tool,
            "error": exc.error,
            "detail": exc.detail,
            "correlation_id": response_payload.get("correlation_id"),
        }
    except PowderConnectionError as exc:
        return {"ok": False, "tool": tool, "error": "transport_error", "detail": str(exc)}
    except Exception as exc:  # a handler must never raise
        return {"ok": False, "tool": tool, "error": "unexpected_error", "detail": f"{type(exc).__name__}: {exc}"}

    if not isinstance(response, dict):
        return {
            "ok": False,
            "tool": tool,
            "error": "transport_error",
            "detail": "bridge returned a non-object response",
        }

    result = dict(response)
    result.setdefault("ok", True)
    result["tool"] = tool
    return result


HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "define_element": _handle_define_element,
    "list_custom_elements": _handle_list_custom_elements,
    "update_element": _handle_update_element,
    "delete_custom_element": _handle_delete_custom_element,
}
