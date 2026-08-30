"""MCP handlers for the ant-colony bridge actions (EXTENSION_SPEC.md 4.3-4.6).

Job polling contract
---------------------
Per EXTENSION_SPEC.md section 2.4, any bridge action that has to touch many
particles cannot run inside the HTTP handler (TPT asserts on mutable-tools
events there). Such actions answer immediately with

    {"ok": true, "job": <id>, "status": "pending"}

and the real work only settles on a later simulation TICK. The caller is
responsible for polling the bridge's built-in ``jobStatus`` action

    {"action": "jobStatus", "job": <id>}
    -> {"status": "pending"}                                   while queued
    -> {"status": "done", "succeeded": bool, "value": ..., "detail": ...}  once settled

This module polls with a bounded wall-clock budget (default 3.0s, overridable
per call via an optional ``job_budget_s`` argument, clamped to [0.1, 10.0])
and a bounded poll count, sleeping ~50ms between attempts. If the job has not
settled inside the budget, the handler returns ``ok: False``,
``status: "pending"``, the original ``job`` id, and a ``hint`` that the
simulation may be paused. A handler NEVER claims success on a timeout and
NEVER blocks indefinitely.

Which tools are async (i.e. may return a pending job that needs polling):
``spawn_workers`` and ``kill_workers`` always are (EXTENSION_SPEC.md 4.4).
``colony_destroy`` only is when ``killWorkers`` is true -- destroying the
bookkeeping record alone touches no particles, killing the workers does.
``extension_self_test`` is "partially" async: the shallow checks return
inline, but a ``deep`` self-test may hand back a job id for the
particle-level check, which is polled the same way as any other job. A
self-test legitimately reporting individual not-yet-settled checks inside its
``checks`` array is NOT treated as a failure here -- only a transport/API
error, or the poll budget expiring while waiting on a top-level job, is.

``element_tools.py`` (a concurrent module under active development) is
writing a reusable ``_await_job(job_id, budget_s)`` poller for this same
protocol. This module prefers that shared implementation when importable
(so every module in this package polls identically) and falls back to its
own equivalent poller, ``_poll_job_fallback``, otherwise. The import is done
lazily inside ``_poll_job`` so this module keeps importing cleanly even
while ``element_tools.py`` is unfinished or has a bug.

Per-``assign_task``-kind required ``params`` (EXTENSION_SPEC.md section 4.5)
------------------------------------------------------------------------------
    gather         -> element, region {x1,y1,x2,y2}
    dig            -> region {x1,y1,x2,y2}            (element optional)
    buildLine      -> element, x1, y1, x2, y2
    buildBox       -> element, x1, y1, x2, y2          (filled optional)
    buildCircle    -> element, cx, cy, radius
    buildBlueprint -> cells (<= 4096 entries; over-cap is REJECTED, never
                      silently truncated, and the error names the actual count)
    patrol         -> points

A future reader will most likely trip on two things: (1) "async" here means
"the bridge answered with a job id that must be polled", not literally
Python ``asyncio`` -- these handlers are plain synchronous functions that
block (briefly, boundedly) on ``time.sleep``; and (2) every ``assign_task``
``kind`` has its own distinct required-params shape -- see the table above
and ``_TASK_REQUIRED_PARAMS`` -- there is no single shared schema.
"""

from __future__ import annotations

import time
from typing import Any, Callable

from powder_bridge.client import PowderClient, PowderAPIError, PowderConnectionError
from powder_bridge.logging import resolve_correlation_id

# ---------------------------------------------------------------------------
# Bridge client plumbing
#
# The real symbol existing MCP tools use is `powder_bridge.client.PowderClient`
# -- specifically its internal `_post(payload)` method, which does the token
# injection, correlation-id stamping, and PowderAPIError/PowderConnectionError
# raising documented in client.py. There is no typed public wrapper method on
# PowderClient for any colony/task/diag action (those are brand new bridge
# actions -- see EXTENSION_SPEC.md 4.3-4.6), so this module calls `_post`
# directly with a raw action payload. This mirrors the exact pattern already
# used by `powder_toy_mcp.py`'s own `execute_action` dispatch branch for
# actions without a typed wrapper (`resp = c._post(payload)`), so no new
# transport is being invented here.
# ---------------------------------------------------------------------------

_client: PowderClient | None = None


def _get_client() -> PowderClient:
    """Lazily construct the module-local PowderClient singleton."""
    global _client
    if _client is None:
        _client = PowderClient(host="127.0.0.1", port=9876, timeout=10.0)
    return _client


def _call_bridge(action: str, params: dict[str, Any]) -> dict[str, Any]:
    """POST one bridge action and normalize every outcome into a plain dict.

    Never raises. A ``PowderAPIError`` (bridge said ``ok: false``) becomes
    that response dict with ``ok``/``action``/``error``/``detail`` filled in.
    A ``PowderConnectionError`` (transport failure) becomes
    ``{"ok": False, "error": "transport_error", "detail": str(exc)}``. Any
    other unexpected exception is caught the same way rather than escaping.
    The correlation id is always attached, whether or not the bridge replied.
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


# ---------------------------------------------------------------------------
# Async job polling
# ---------------------------------------------------------------------------

DEFAULT_JOB_BUDGET_S = 3.0
_MIN_JOB_BUDGET_S = 0.1
_MAX_JOB_BUDGET_S = 10.0
_POLL_INTERVAL_S = 0.05  # ~50ms, within the spec's 40-60ms band
_POLL_MAX_ATTEMPTS = 200  # safety net; the wall-clock deadline is the real bound


def _budget_from(args: dict[str, Any]) -> float:
    """Read an optional per-call ``job_budget_s`` override, clamped to a sane range."""
    value = args.get("job_budget_s", DEFAULT_JOB_BUDGET_S)
    try:
        value = float(value)
    except (TypeError, ValueError):
        return DEFAULT_JOB_BUDGET_S
    if not (_MIN_JOB_BUDGET_S <= value <= _MAX_JOB_BUDGET_S):
        return DEFAULT_JOB_BUDGET_S
    return value


def _poll_job_fallback(job_id: Any, budget_s: float) -> dict[str, Any]:
    """Poll ``jobStatus`` until settled or the wall-clock budget runs out.

    Used only when ``element_tools._await_job`` cannot be imported or fails.
    Never blocks past ``budget_s`` wall-clock seconds and never claims a job
    succeeded that never actually settled.
    """
    deadline = time.monotonic() + max(0.0, budget_s)
    attempts = 0
    last: dict[str, Any] = {}
    while time.monotonic() < deadline and attempts < _POLL_MAX_ATTEMPTS:
        attempts += 1
        last = _call_bridge("jobStatus", {"job": job_id})
        if last.get("ok") is False:
            # transport/API failure while polling -- surface it directly,
            # do not keep retrying against a bridge that is erroring.
            return last
        if last.get("status") == "done":
            return last
        time.sleep(_POLL_INTERVAL_S)
    return {
        "ok": False,
        "job": job_id,
        "status": "pending",
        "hint": "job did not settle within the poll budget; the simulation may be paused",
        "correlation_id": last.get("correlation_id", resolve_correlation_id()),
    }


def _poll_job(job_id: Any, budget_s: float) -> dict[str, Any]:
    """Poll a bridge job to settlement.

    Prefers ``element_tools._await_job(job_id, budget_s)`` -- a concurrently
    authored, reusable poller for the same protocol -- so every module in
    this package polls identically. Imported lazily so this module keeps
    importing cleanly whether or not ``element_tools.py`` exists yet or is
    still broken. Falls back to ``_poll_job_fallback`` if the import fails,
    the call raises, or it doesn't return a dict.
    """
    try:
        from powder_ext.element_tools import _await_job as _shared_await_job  # type: ignore
    except Exception:
        _shared_await_job = None  # type: ignore[assignment]

    if _shared_await_job is not None:
        try:
            settled = _shared_await_job(job_id, budget_s)
        except Exception:
            settled = None
        if isinstance(settled, dict):
            settled.setdefault("job", job_id)
            settled.setdefault("correlation_id", resolve_correlation_id())
            return settled

    return _poll_job_fallback(job_id, budget_s)


def _flatten_job_value(settled: dict[str, Any]) -> dict[str, Any]:
    """Merge a settled job's ``value`` payload up to the top level.

    ``jobStatus`` reports ``{"status": "done", "succeeded": bool,
    "value": {...}, "detail": ...}``; callers of this module want the
    deferred function's actual result fields (e.g. ``spawned``, ``total``)
    directly on the returned dict, not nested one level down. A job that
    settled but did not succeed is reported as ``ok: False`` here -- the
    HTTP round-trip to ``jobStatus`` succeeding is not the same as the
    deferred work itself succeeding.
    """
    if not isinstance(settled, dict) or settled.get("status") != "done":
        return settled
    merged = dict(settled)
    value = merged.get("value")
    if isinstance(value, dict):
        for key, val in value.items():
            merged.setdefault(key, val)
    succeeded = bool(merged.get("succeeded"))
    if not succeeded:
        merged["ok"] = False
        merged.setdefault("error", merged.get("detail") or "job did not succeed")
    else:
        merged.setdefault("ok", True)
    return merged


def _settle(initial: dict[str, Any], budget_s: float) -> dict[str, Any]:
    """If ``initial`` is a pending-job response, poll it to settlement.

    Anything else (an outright rejection, or a response that already
    resolved synchronously) is passed through untouched -- there is nothing
    to poll.
    """
    if not isinstance(initial, dict):
        return initial
    if initial.get("ok") is not True:
        return initial
    if initial.get("status") != "pending" or "job" not in initial:
        return initial
    settled = _poll_job(initial["job"], budget_s)
    return _flatten_job_value(settled)


# ---------------------------------------------------------------------------
# Shared argument validation helpers
# ---------------------------------------------------------------------------

COLONY_MAX_WORKERS = 400  # MAX_WORKERS_PER_COLONY, EXTENSION_SPEC.md 2.3
MAX_BLUEPRINT_CELLS = 4096  # MAX_BLUEPRINT_CELLS, EXTENSION_SPEC.md 2.3


def _errors_result(tool: str, errors: list[str]) -> dict[str, Any]:
    return {"ok": False, "tool": tool, "errors": errors}


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _require_colony_id(args: dict[str, Any]) -> tuple[Any, str | None]:
    if "colonyId" not in args or args["colonyId"] is None:
        return None, "missing required parameter: colonyId"
    value = args["colonyId"]
    if not _is_int(value):
        return None, "colonyId must be an integer"
    return value, None


def _validate_region(region: Any, label: str = "region") -> list[str]:
    if not isinstance(region, dict):
        return [f"{label} must be an object with x1, y1, x2, y2"]
    missing = [k for k in ("x1", "y1", "x2", "y2") if k not in region or region[k] is None]
    if missing:
        return [f"{label} missing: {', '.join(missing)}"]
    bad = [k for k in ("x1", "y1", "x2", "y2") if not _is_int(region[k])]
    if bad:
        return [f"{label} field(s) must be integers: {', '.join(bad)}"]
    return []


# kind -> required top-level `params` keys (EXTENSION_SPEC.md 4.5)
_TASK_REQUIRED_PARAMS: dict[str, tuple[str, ...]] = {
    "gather": ("element", "region"),
    "dig": ("region",),
    "buildLine": ("element", "x1", "y1", "x2", "y2"),
    "buildBox": ("element", "x1", "y1", "x2", "y2"),
    "buildCircle": ("element", "cx", "cy", "radius"),
    "buildBlueprint": ("cells",),
    "patrol": ("points",),
}


def _validate_task_params(kind: str, params: dict[str, Any]) -> list[str]:
    """Validate `params` for one `assign_task` `kind`, naming the missing/bad field.

    Only the required top-level keys are checked first; if any are missing
    we stop there rather than piling on confusing secondary errors about
    fields that were never provided.
    """
    required = _TASK_REQUIRED_PARAMS.get(kind)
    if required is None:
        return [f"unknown task kind: {kind}"]

    missing = [name for name in required if name not in params or params[name] is None]
    if missing:
        return [f"{kind} requires '{name}'" for name in missing]

    errors: list[str] = []
    if kind == "gather":
        errors.extend(_validate_region(params.get("region")))
        if not isinstance(params.get("element"), str) or not params["element"]:
            errors.append("gather requires 'element' to be a non-empty string")
    elif kind == "dig":
        errors.extend(_validate_region(params.get("region")))
        if "element" in params and params["element"] is not None and not isinstance(params["element"], str):
            errors.append("dig 'element' must be a string when provided")
    elif kind in ("buildLine", "buildBox"):
        if not isinstance(params.get("element"), str) or not params["element"]:
            errors.append(f"{kind} requires 'element' to be a non-empty string")
        for coord in ("x1", "y1", "x2", "y2"):
            if not _is_int(params.get(coord)):
                errors.append(f"{kind} requires '{coord}' to be an integer")
        if kind == "buildBox" and "filled" in params and params["filled"] is not None:
            if not isinstance(params["filled"], bool):
                errors.append("buildBox 'filled' must be a boolean")
    elif kind == "buildCircle":
        if not isinstance(params.get("element"), str) or not params["element"]:
            errors.append("buildCircle requires 'element' to be a non-empty string")
        for coord in ("cx", "cy"):
            if not _is_int(params.get(coord)):
                errors.append(f"buildCircle requires '{coord}' to be an integer")
        radius = params.get("radius")
        if not _is_int(radius):
            errors.append("buildCircle requires 'radius' to be an integer")
        elif radius < 1:
            errors.append("buildCircle 'radius' must be >= 1")
    elif kind == "buildBlueprint":
        cells = params.get("cells")
        if not isinstance(cells, list):
            errors.append("buildBlueprint 'cells' must be an array")
        elif not cells:
            errors.append("buildBlueprint 'cells' must not be empty")
        elif len(cells) > MAX_BLUEPRINT_CELLS:
            # Reject outright -- never silently truncate -- and name the actual count.
            errors.append(
                f"buildBlueprint 'cells' has {len(cells)} entries, exceeding the cap of "
                f"{MAX_BLUEPRINT_CELLS}; split into multiple tasks instead of truncating"
            )
        else:
            for index, cell in enumerate(cells):
                if not isinstance(cell, dict) or not {"x", "y", "element"} <= set(cell):
                    errors.append(f"buildBlueprint cells[{index}] must be an object with x, y, element")
                    break
    elif kind == "patrol":
        points = params.get("points")
        if not isinstance(points, list):
            errors.append("patrol 'points' must be an array")
        elif not points:
            errors.append("patrol 'points' must not be empty")
        else:
            for index, point in enumerate(points):
                if not isinstance(point, dict) or not {"x", "y"} <= set(point):
                    errors.append(f"patrol points[{index}] must be an object with x, y")
                    break
    return errors


def _colony_summary(result: dict[str, Any]) -> dict[str, Any]:
    """Compact, at-a-glance view of a `colonyStatus` payload for polling loops."""
    workers = result.get("workers")
    alive = result.get("alive")
    summary: dict[str, Any] = {
        "workers": workers,
        "alive": alive,
        "carrying": result.get("carrying"),
    }
    if isinstance(workers, (int, float)) and workers and isinstance(alive, (int, float)):
        summary["alive_pct"] = round(100.0 * float(alive) / float(workers), 1)
    tasks = result.get("tasks")
    if isinstance(tasks, list):
        summary["task_count"] = len(tasks)
        progress: list[dict[str, Any]] = []
        blocked: list[dict[str, Any]] = []
        for task in tasks:
            if not isinstance(task, dict):
                continue
            done, total = task.get("done"), task.get("total")
            if isinstance(done, (int, float)) and isinstance(total, (int, float)) and total:
                progress.append({
                    "taskId": task.get("taskId"),
                    "progress": f"{done}/{total}",
                    "pct": round(100.0 * float(done) / float(total), 1),
                })
            reason = task.get("blocked")
            if reason:
                blocked.append({"taskId": task.get("taskId"), "reason": reason})
        if progress:
            summary["progress"] = progress
        if blocked:
            summary["blocked"] = blocked
    return summary


def _task_summary(tasks: Any) -> dict[str, Any]:
    """Compact, at-a-glance view of a `colonyTaskStatus` payload for polling loops."""
    if not isinstance(tasks, list):
        return {"task_count": 0}
    entries: list[dict[str, Any]] = []
    for task in tasks:
        if not isinstance(task, dict):
            continue
        entry: dict[str, Any] = {"taskId": task.get("taskId"), "claimed": task.get("claimed")}
        done, total = task.get("done"), task.get("total")
        if isinstance(done, (int, float)) and isinstance(total, (int, float)) and total:
            entry["progress"] = f"{done}/{total}"
            entry["pct"] = round(100.0 * float(done) / float(total), 1)
        reason = task.get("blocked")
        if reason:
            entry["blocked"] = reason  # surfaced prominently, not buried
        entries.append(entry)
    return {"task_count": len(entries), "tasks": entries}


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------


def colony_create(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonyCreate` -- create a colony. Synchronous, no job polling."""
    tool = "colony_create"
    args = arguments or {}
    errors: list[str] = []

    name = args.get("name")
    if not isinstance(name, str) or not name:
        errors.append("missing required parameter: name")
    for key in ("nestX", "nestY"):
        if key not in args or args[key] is None:
            errors.append(f"missing required parameter: {key}")
        elif not _is_int(args[key]):
            errors.append(f"{key} must be an integer")
    if "pheromoneDecay" in args and args["pheromoneDecay"] is not None:
        decay = args["pheromoneDecay"]
        if not isinstance(decay, (int, float)) or isinstance(decay, bool) or not (0 <= decay <= 1):
            errors.append("pheromoneDecay must be a number between 0 and 1")
    if errors:
        return _errors_result(tool, errors)

    params: dict[str, Any] = {"name": name, "nestX": args["nestX"], "nestY": args["nestY"]}
    if "colour" in args and args["colour"] is not None:
        params["colour"] = args["colour"]
    if "pheromoneDecay" in args and args["pheromoneDecay"] is not None:
        params["pheromoneDecay"] = args["pheromoneDecay"]

    result = _call_bridge("colonyCreate", params)
    result.setdefault("tool", tool)
    return result


def colony_list(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonyList` -- list all colonies. Synchronous, no arguments."""
    tool = "colony_list"
    result = _call_bridge("colonyList", {})
    result.setdefault("tool", tool)
    return result


def colony_status(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonyStatus` -- read one colony's status. Synchronous.

    Adds a compact `summary` (alive %, per-task done/total + pct, and any
    `blocked` reasons surfaced prominently) since this is a tool a model will
    poll repeatedly while watching the ants work.
    """
    tool = "colony_status"
    args = arguments or {}
    colony_id, err = _require_colony_id(args)
    if err:
        return _errors_result(tool, [err])

    result = _call_bridge("colonyStatus", {"colonyId": colony_id})
    result.setdefault("tool", tool)
    if result.get("ok"):
        result["summary"] = _colony_summary(result)
    return result


def colony_destroy(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonyDestroy` -- destroy a colony. Async only when `killWorkers` is true."""
    tool = "colony_destroy"
    args = arguments or {}
    errors: list[str] = []

    colony_id, err = _require_colony_id(args)
    if err:
        errors.append(err)
    kill_workers_flag = args.get("killWorkers", False)
    if not isinstance(kill_workers_flag, bool):
        errors.append("killWorkers must be a boolean")
    if errors:
        return _errors_result(tool, errors)

    result = _call_bridge("colonyDestroy", {"colonyId": colony_id, "killWorkers": kill_workers_flag})
    if kill_workers_flag:
        result = _settle(result, _budget_from(args))
    result.setdefault("tool", tool)
    return result


def spawn_workers(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonySpawnWorkers` -- async.

    `count` is validated locally against the colony-wide cap of
    `COLONY_MAX_WORKERS` (400) before the bridge is ever called. The bridge
    additionally enforces the *colony's current* remaining headroom under
    that cap, so a request can still come back partially satisfied -- the
    response always states `requested` alongside whatever `spawned` the
    bridge reports, plus `fully_satisfied`.
    """
    tool = "spawn_workers"
    args = arguments or {}
    errors: list[str] = []

    colony_id, err = _require_colony_id(args)
    if err:
        errors.append(err)
    count = args.get("count")
    if not _is_int(count):
        errors.append("count must be an integer")
    elif not (1 <= count <= COLONY_MAX_WORKERS):
        errors.append(f"count must be between 1 and {COLONY_MAX_WORKERS} (colony-wide worker cap)")
    for key in ("x", "y"):
        if key not in args or args[key] is None:
            errors.append(f"missing required parameter: {key}")
        elif not _is_int(args[key]):
            errors.append(f"{key} must be an integer")
    if "spread" in args and args["spread"] is not None and not isinstance(args["spread"], (int, float)):
        errors.append("spread must be a number")
    if errors:
        return _errors_result(tool, errors)

    params: dict[str, Any] = {"colonyId": colony_id, "count": count, "x": args["x"], "y": args["y"]}
    if "spread" in args and args["spread"] is not None:
        params["spread"] = args["spread"]

    result = _settle(_call_bridge("colonySpawnWorkers", params), _budget_from(args))
    result.setdefault("tool", tool)
    result.setdefault("requested", count)
    spawned = result.get("spawned")
    if isinstance(spawned, (int, float)):
        result["fully_satisfied"] = (spawned == count)
        if spawned < count:
            result.setdefault(
                "hint",
                "colony-wide worker cap or remaining headroom reduced the spawn count below what was requested",
            )
    return result


def kill_workers(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonyKillWorkers` -- async. `count` omitted means kill all."""
    tool = "kill_workers"
    args = arguments or {}
    errors: list[str] = []

    colony_id, err = _require_colony_id(args)
    if err:
        errors.append(err)
    params: dict[str, Any] = {"colonyId": colony_id}
    requested_count: int | None = None
    if "count" in args and args["count"] is not None:
        count = args["count"]
        if not _is_int(count) or count < 1:
            errors.append("count must be a positive integer")
        else:
            requested_count = count
            params["count"] = count
    if errors:
        return _errors_result(tool, errors)

    result = _settle(_call_bridge("colonyKillWorkers", params), _budget_from(args))
    result.setdefault("tool", tool)
    if requested_count is not None:
        result.setdefault("requested", requested_count)
    return result


def assign_task(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonyAssignTask` -- synchronous.

    `kind` drives which `params` fields are required; see the module
    docstring and `_TASK_REQUIRED_PARAMS`. A missing or malformed param is
    rejected by name here, before the request ever reaches the Lua side.
    """
    tool = "assign_task"
    args = arguments or {}
    errors: list[str] = []

    colony_id, err = _require_colony_id(args)
    if err:
        errors.append(err)

    kind = args.get("kind")
    if not isinstance(kind, str) or not kind:
        errors.append("missing required parameter: kind")
        kind = None

    params = args.get("params")
    if not isinstance(params, dict):
        errors.append("params must be an object")
        params = {}

    if kind is not None:
        errors.extend(_validate_task_params(kind, params))

    priority = args.get("priority", 5)
    if not _is_int(priority) or not (1 <= priority <= 9):
        errors.append("priority must be an integer between 1 and 9")

    workers_cap = args.get("workers")
    if workers_cap is not None and (not _is_int(workers_cap) or workers_cap < 1):
        errors.append("workers must be a positive integer")

    if errors:
        return _errors_result(tool, errors)

    bridge_params: dict[str, Any] = {
        "colonyId": colony_id,
        "kind": kind,
        "params": params,
        "priority": priority,
    }
    if workers_cap is not None:
        bridge_params["workers"] = workers_cap

    result = _call_bridge("colonyAssignTask", bridge_params)
    result.setdefault("tool", tool)
    return result


def task_status(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonyTaskStatus` -- synchronous. `taskId` omitted lists all tasks.

    Adds a compact `summary` (done/total + pct per task, `blocked` reason
    surfaced prominently) for the same polling-loop reason as `colony_status`.
    """
    tool = "task_status"
    args = arguments or {}
    errors: list[str] = []

    colony_id, err = _require_colony_id(args)
    if err:
        errors.append(err)
    params: dict[str, Any] = {"colonyId": colony_id}
    if "taskId" in args and args["taskId"] is not None:
        task_id = args["taskId"]
        if not _is_int(task_id):
            errors.append("taskId must be an integer")
        else:
            params["taskId"] = task_id
    if errors:
        return _errors_result(tool, errors)

    result = _call_bridge("colonyTaskStatus", params)
    result.setdefault("tool", tool)
    if result.get("ok"):
        result["summary"] = _task_summary(result.get("tasks"))
    return result


def cancel_task(arguments: dict[str, Any]) -> dict[str, Any]:
    """`colonyCancelTask` -- synchronous."""
    tool = "cancel_task"
    args = arguments or {}
    errors: list[str] = []

    colony_id, err = _require_colony_id(args)
    if err:
        errors.append(err)
    task_id = args.get("taskId")
    if task_id is None:
        errors.append("missing required parameter: taskId")
    elif not _is_int(task_id):
        errors.append("taskId must be an integer")
    if errors:
        return _errors_result(tool, errors)

    result = _call_bridge("colonyCancelTask", {"colonyId": colony_id, "taskId": task_id})
    result.setdefault("tool", tool)
    return result


def extension_status(arguments: dict[str, Any]) -> dict[str, Any]:
    """`extStatus` -- synchronous, no arguments."""
    tool = "extension_status"
    result = _call_bridge("extStatus", {})
    result.setdefault("tool", tool)
    return result


def reset_creature_faults(arguments: dict[str, Any]) -> dict[str, Any]:
    """`workerResetFaults` -- synchronous, no arguments.

    Clears the creature-update fault latch (40_worker.lua's countFault/
    disabled guard) and re-arms the WARMUP_GUARD window, so a fault that
    tripped FAULT_LIMIT stops silently disabling all worker updates.
    """
    tool = "reset_creature_faults"
    result = _call_bridge("workerResetFaults", {})
    result.setdefault("tool", tool)
    return result


def extension_self_test(arguments: dict[str, Any]) -> dict[str, Any]:
    """`extSelfTest` -- passes `deep` through; polls a job id if one comes back.

    A `deep` self-test may return a job id for its particle-level check;
    that is polled exactly like any other async job. The self-test's own
    `checks` array is passed through untouched -- an individual check
    legitimately reporting a not-yet-settled state is not reinterpreted as
    an overall failure here, only a transport/API error or an expired poll
    budget is.
    """
    tool = "extension_self_test"
    args = arguments or {}
    deep = args.get("deep", False)
    if not isinstance(deep, bool):
        return _errors_result(tool, ["deep must be a boolean"])

    result = _call_bridge("extSelfTest", {"deep": deep})
    if result.get("ok") is True and result.get("status") == "pending" and "job" in result:
        result = _flatten_job_value(_poll_job(result["job"], _budget_from(args)))
    result.setdefault("tool", tool)
    return result


# ---------------------------------------------------------------------------
# HANDLERS registry
# ---------------------------------------------------------------------------

_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "colony_create": colony_create,
    "colony_list": colony_list,
    "colony_status": colony_status,
    "colony_destroy": colony_destroy,
    "spawn_workers": spawn_workers,
    "kill_workers": kill_workers,
    "assign_task": assign_task,
    "task_status": task_status,
    "cancel_task": cancel_task,
    "extension_status": extension_status,
    "extension_self_test": extension_self_test,
    "reset_creature_faults": reset_creature_faults,
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
