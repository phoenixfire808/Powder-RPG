"""Persistence layer for custom elements, behaviour kinds, and the stock-element
realism patch -- all of which live only in the running powder.exe process and
vanish on restart.

Owns two MCP tools:

* ``realism_apply`` -- (re)registers the runtime behaviour kinds from
  ``scripts/lua/*_kinds.lua``, re-applies the stock-element realism patch(es)
  from ``knowledge/stock-element-realism-patch*.json``, and (re)defines the
  power-generation element set (``scripts/define_power_elements.py``) and the
  priority-1 materials catalog entries (``scripts/define_materials.py``),
  respecting ``PBX.MAX_CUSTOM_ELEMENTS`` and reporting anything skipped for
  lack of a free slot. ``dry_run=True`` computes the same plan and cap
  accounting using only read-only bridge calls (``listCustomElements``, a
  ``return``-only ``executeLua``) -- it never calls ``defineElement`` /
  ``updateElement`` / ``deleteCustomElement`` and never runs a kinds/patch
  chunk through ``executeLua``.
* ``realism_status`` -- read-only snapshot: which behaviour kinds are
  currently registered on ``PBX.state.behaviors.kinds``, the live custom
  element count against the cap, whether the stock patch is in effect
  (sampled via one stock element/property pair), and catalog/power-set
  coverage totals.

This module reuses the existing, hand-maintained sources of truth instead of
duplicating their data:

* ``scripts/define_power_elements.py`` -- imported for its ``ELEMENTS`` list
  and ``SECTIONS`` map (module-level data only; its ``main()`` is never
  called, so importing it performs no network I/O).
* ``scripts/define_materials.py`` -- imported for ``CATALOG`` (the catalog
  path) and ``to_spec`` (catalog-entry -> ``define_element`` payload).
* ``powder_ext.element_tools.HANDLERS`` -- the same deferred-job-aware
  ``define_element`` / ``update_element`` / ``list_custom_elements`` handlers
  every other caller uses, so this module never talks to the bridge's
  mutable-tools actions directly.

Both ``scripts/`` modules have no ``__init__.py`` (an implicit namespace
package); importing them requires ``D:/powder-toy`` to be on ``sys.path``,
which this module guarantees the same way ``element_tools.py`` does.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Callable

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from powder_bridge.client import (  # noqa: E402
    PowderAPIError,
    PowderClient,
    PowderConnectionError,
)
from powder_ext import element_tools as et  # noqa: E402
from powder_ext.schemas import MAX_CUSTOM_ELEMENTS as _DEFAULT_CAP  # noqa: E402

KNOW_DIR = _PROJECT_ROOT / "knowledge"
LUA_DIR = _PROJECT_ROOT / "scripts" / "lua"
CATALOG_PATH = KNOW_DIR / "materials-catalog.json"

# scripts/lua/*_kinds.lua -- the glob the runbook and the task both name.
# stock_props.lua is a read-only probe, not a kinds file, and is deliberately
# excluded (it matches scripts/lua/*.lua but not *_kinds.lua).
_KIND_FILES: tuple[str, ...] = ("power_kinds.lua", "material_kinds.lua", "chem_kinds.lua")

# Runtime behaviour kinds those three files register (see BEHAVIOR_KIND_ENUM
# in schemas.py). The bridge's own 20_behaviors.lua registers the base set
# (inert/glower/decayer/emitter/grower/pheromone/conductor/creature) at
# startup; those are not re-registered here and are not "missing" if a fresh
# session hasn't run realism_apply yet.
_RUNTIME_KIND_NAMES: tuple[str, ...] = (
    "absorber", "turbine", "teg", "photovoltaic", "piezo", "pcm", "reactive",
)

# Later files win on a per-(element, property) basis, so a -v2 patch can
# override individual entries from the base patch without restating it whole.
_PATCH_FILES: tuple[str, ...] = (
    "stock-element-realism-patch.json",
    "stock-element-realism-patch-v2.json",
)

_SAMPLE_ELEMENT = "METL"
_SAMPLE_PROPERTY = "HighTemperature"

_PROFILES: tuple[str, ...] = ("all", "stock", "power", "materials", "kinds")

_client: PowderClient | None = None


def _get_client() -> PowderClient:
    global _client
    if _client is None:
        _client = PowderClient(host="127.0.0.1", port=9876, timeout=10.0)
    return _client


def _lua_literal(value: Any) -> str:
    """Render a Python JSON-patch value as a Lua literal."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return json.dumps(str(value))


# ---------------------------------------------------------------------------
# Shared live-state read (safe in dry_run: listCustomElements and a
# return-only executeLua are both read-only bridge calls).
# ---------------------------------------------------------------------------


def _live_state(client: PowderClient) -> tuple[dict[str, dict[str, Any]], int]:
    listing = et.HANDLERS["list_custom_elements"]({})
    elements = listing.get("elements") if listing.get("ok") else None
    live_map = {
        e.get("name"): e
        for e in (elements or [])
        if isinstance(e, dict) and e.get("name")
    }
    cap = _DEFAULT_CAP
    try:
        res = client.execute_lua("return tostring(PBX.MAX_CUSTOM_ELEMENTS)")
        cap = int(float(res.get("result")))
    except (PowderAPIError, PowderConnectionError, TypeError, ValueError):
        pass
    return live_map, cap


def _load_patch_map() -> tuple[dict[str, dict[str, Any]], list[str], list[str]]:
    """Merge every present patch file into one {ELEMENT: {prop: value}} map.

    Returns (patches, files_used, errors).
    """
    patches: dict[str, dict[str, Any]] = {}
    files_used: list[str] = []
    errors: list[str] = []
    for fname in _PATCH_FILES:
        path = KNOW_DIR / fname
        if not path.is_file():
            continue
        files_used.append(fname)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"{fname}: {type(exc).__name__}: {exc}")
            continue
        if not isinstance(data, dict):
            errors.append(f"{fname}: expected a JSON object of {{ELEMENT: {{prop: value}}}}")
            continue
        # v2 files wrap entries under "patch" (and carry "skipped"/"schema"/"date"); v1 files are flat.
        entries = data.get("patch") if isinstance(data.get("patch"), dict) else data
        for name, props in entries.items():
            if not isinstance(props, dict) or name in ("patch", "skipped"):
                continue
            clean = {k: v for k, v in props.items() if not str(k).startswith("_")}
            if clean:
                patches.setdefault(str(name).strip().upper(), {}).update(clean)
    return patches, files_used, errors


# ---------------------------------------------------------------------------
# realism_apply -- per-profile steps
# ---------------------------------------------------------------------------


def _step_kinds(client: PowderClient, dry_run: bool) -> dict[str, Any]:
    result: dict[str, Any] = {"files": [], "registered": 0, "errors": []}
    for fname in _KIND_FILES:
        path = LUA_DIR / fname
        entry: dict[str, Any] = {"file": fname}
        if not path.is_file():
            entry["ok"] = False
            entry["error"] = "file not found"
            result["errors"].append(f"{fname}: file not found")
            result["files"].append(entry)
            continue
        if dry_run:
            entry["planned"] = True
            result["files"].append(entry)
            continue
        try:
            code = path.read_text(encoding="utf-8")
            res = client.execute_lua(code)
            entry["ok"] = True
            entry["result"] = res.get("result")
            result["registered"] += 1
        except (PowderAPIError, PowderConnectionError, OSError) as exc:
            entry["ok"] = False
            entry["error"] = f"{type(exc).__name__}: {exc}"
            result["errors"].append(f"{fname}: {entry['error']}")
        result["files"].append(entry)
    return result


_STOCK_LUA_PRELUDE: tuple[str, ...] = (
    'local function findId(n)',
    '  local i = elem["DEFAULT_PT_"..n]',
    '  if i then return i end',
    '  for j=0,511 do local ok,nm=pcall(elem.property,j,"Name"); if ok and nm==n then return j end end',
    '  return nil',
    'end',
    'local applied, failed = 0, {}',
    'local function setp(name, key, val)',
    '  local i = findId(name)',
    '  if not i then failed[#failed+1] = name..":"..key..":no_such_element"; return end',
    '  local ok, err = pcall(elem.property, i, key, val)',
    '  if ok then applied = applied + 1 else failed[#failed+1] = name..":"..key..":"..tostring(err) end',
    'end',
)


def _apply_property_patch(client: PowderClient, patch: dict[str, dict[str, Any]], dry_run: bool) -> dict[str, Any]:
    """Set arbitrary elem.property key/value pairs on live elements (custom or stock) in one
    executeLua round-trip. Shared by ``_step_stock`` (the JSON realism-patch files) and the
    HeatCapacity post-define pass in ``_step_materials``/``_step_power`` -- HeatCapacity is not a
    defineElement/updateElement schema field (research-material-mapping-2026-08-26.md S0.1), so it
    has to be set this way regardless of which catalog it came from.
    """
    result: dict[str, Any] = {
        "patched_elements": len(patch),
        "patched_props": sum(len(p) for p in patch.values()),
        "errors": [],
    }
    if dry_run or not patch:
        return result

    lines = list(_STOCK_LUA_PRELUDE)
    for name, props in patch.items():
        for key, value in props.items():
            lines.append(f"setp({json.dumps(name)}, {json.dumps(str(key))}, {_lua_literal(value)})")
    lines.append(
        'return string.format("{\\"applied\\":%d,\\"failed\\":%d,\\"failed_list\\":\\"%s\\"}", '
        'applied, #failed, table.concat(failed, "|"))'
    )
    code = "\n".join(lines)
    try:
        res = client.execute_lua(code)
    except (PowderAPIError, PowderConnectionError) as exc:
        result["errors"].append(f"{type(exc).__name__}: {exc}")
        return result

    raw = res.get("result")
    parsed = None
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = None
    if isinstance(parsed, dict):
        result["applied"] = parsed.get("applied")
        result["failed"] = parsed.get("failed")
        failed_list = str(parsed.get("failed_list") or "")
        if failed_list:
            result["errors"].extend(failed_list.split("|"))
    else:
        result["raw_result"] = raw
    return result


def _step_stock(client: PowderClient, dry_run: bool) -> dict[str, Any]:
    patches, files_used, errors = _load_patch_map()
    result = _apply_property_patch(client, patches, dry_run)
    result["files_used"] = files_used
    result["patched_elements"] = len(patches)
    result["patched_props"] = sum(len(p) for p in patches.values())
    result["errors"] = list(errors) + list(result.get("errors") or [])
    return result


def _free_stuck_identifier(client: PowderClient, name: str) -> bool:
    """A kind-based element dropped at boot leaves its TPT identifier allocated; free it so define can succeed."""
    try:
        r = client.execute_lua(
            'local n=%s for j=0,511 do local ok,nm=pcall(elem.property,j,"Name") if ok and nm==n then local ok2=pcall(elements.free,j) return tostring(ok2) end end return "absent"' % json.dumps(name)
        )
        return str(r.get("result")) == "true"
    except (PowderAPIError, PowderConnectionError):
        return False

def _define_with_retry(client: PowderClient, spec: dict) -> dict:
    from powder_ext import element_tools as _et
    res = _et.HANDLERS["define_element"](spec)
    if not res.get("ok") and "already in use" in str(res.get("detail") or res.get("error") or ""):
        if _free_stuck_identifier(client, str(spec.get("name"))):
            res = _et.HANDLERS["define_element"](spec)
            res["freed_stuck_identifier"] = True
    return res



def _step_power(client: PowderClient, dry_run: bool, live_names: set[str], cap: int) -> dict[str, Any]:
    result: dict[str, Any] = {"considered": 0, "defined": 0, "updated": 0, "skipped_cap": [], "errors": []}
    try:
        import scripts.define_power_elements as dpe  # noqa: PLC0415
    except Exception as exc:  # noqa: BLE001
        result["errors"].append(f"import scripts.define_power_elements failed: {type(exc).__name__}: {exc}")
        return result

    result["considered"] = len(dpe.ELEMENTS)
    for e in dpe.ELEMENTS:
        name = e["name"]
        exists = name in live_names
        if not exists and len(live_names) >= cap:
            result["skipped_cap"].append(name)
            continue
        # density_kgm3/cp_jkgk/heatCapacity are documentation/HeatCapacity-pass metadata, not
        # defineElement/updateElement schema fields (S0.1) -- strip them before building the spec.
        spec = {k: v for k, v in e.items() if k not in ("density_kgm3", "cp_jkgk", "heatCapacity")}
        spec.setdefault("group", "POWER")
        spec.setdefault("menuSection", dpe.SECTIONS.get(name, "SOLIDS"))
        spec["timeout_s"] = 6.0
        if dry_run:
            if exists:
                result["updated"] += 1
            else:
                result["defined"] += 1
                live_names.add(name)
            continue
        tool_name = "update_element" if exists else "define_element"
        res = et.HANDLERS[tool_name](spec)
        if bool(res.get("ok")):
            if exists:
                result["updated"] += 1
            else:
                result["defined"] += 1
                live_names.add(name)
        else:
            result["errors"].append({
                "name": name, "tool": tool_name,
                "detail": res.get("error") or res.get("errors"),
            })
    # post-define/update pass: HeatCapacity is not a defineElement/updateElement schema field
    # (S0.1), so every power element that is now live gets it (re-)applied here, every run.
    hc_map = {
        e["name"]: e["heatCapacity"]
        for e in dpe.ELEMENTS
        if "heatCapacity" in e and e["name"] in live_names
    }
    if dry_run:
        result["heat_capacity"] = {"planned": len(hc_map)}
    elif hc_map:
        result["heat_capacity"] = _apply_property_patch(
            client, {n: {"HeatCapacity": v} for n, v in hc_map.items()}, dry_run=False
        )
    return result


def _step_materials(client: PowderClient, dry_run: bool, live_names: set[str], cap: int) -> dict[str, Any]:
    result: dict[str, Any] = {
        "considered": 0, "already_live": 0, "defined": 0, "skipped_cap": [], "errors": [],
    }
    try:
        import scripts.define_materials as dm  # noqa: PLC0415
    except Exception as exc:  # noqa: BLE001
        result["errors"].append(f"import scripts.define_materials failed: {type(exc).__name__}: {exc}")
        return result

    try:
        cat = json.loads(Path(dm.CATALOG).read_text(encoding="utf-8"))["entries"]
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        result["errors"].append(f"catalog load failed: {type(exc).__name__}: {exc}")
        return result

    todo = sorted(
        (e for e in cat if int(e.get("priority", 9)) <= 1),
        key=lambda e: (int(e.get("priority", 9)), str(e.get("name", ""))),
    )
    result["considered"] = len(todo)
    for e in todo:
        name = e.get("name")
        if not name:
            continue
        if name in live_names:
            result["already_live"] += 1
            continue
        if len(live_names) >= cap:
            result["skipped_cap"].append(name)
            continue
        if dry_run:
            result["defined"] += 1
            live_names.add(name)
            continue
        res = _define_with_retry(client, dm.to_spec(e))
        if bool(res.get("ok")):
            result["defined"] += 1
            live_names.add(name)
        else:
            result["errors"].append({"name": name, "detail": res.get("error") or res.get("errors")})
    # post-define pass: HeatCapacity is not a defineElement schema field (S0.1); apply it to every
    # considered catalog entry that is now live, whether newly defined or already live -- this is
    # also how a previously-live element (defined before this field existed) picks it up.
    hc_map = {
        e["name"]: e["heatCapacity"]
        for e in todo
        if "heatCapacity" in e and e.get("name") in live_names
    }
    if dry_run:
        result["heat_capacity"] = {"planned": len(hc_map)}
    elif hc_map:
        result["heat_capacity"] = _apply_property_patch(
            client, {n: {"HeatCapacity": v} for n, v in hc_map.items()}, dry_run=False
        )
    return result


def _validate_apply_args(arguments: dict[str, Any]) -> tuple[str, bool, list[str]]:
    errors: list[str] = []
    args = arguments if isinstance(arguments, dict) else {}
    profile = args.get("profile", "all")
    if not isinstance(profile, str) or profile not in _PROFILES:
        errors.append(f"profile must be one of {', '.join(_PROFILES)}")
        profile = "all"
    dry_run = args.get("dry_run", False)
    if not isinstance(dry_run, bool):
        errors.append("dry_run must be a boolean")
        dry_run = False
    unknown = sorted(set(args) - {"profile", "dry_run"})
    if unknown:
        errors.append(f"unknown field(s): {', '.join(unknown)}")
    return profile, dry_run, errors


def realism_apply(arguments: dict[str, Any]) -> dict[str, Any]:
    """(Re)apply everything that vanishes on a powder.exe restart.

    ``dry_run=True`` computes the same plan and cap accounting through only
    read-only bridge calls -- no element is defined/updated/deleted and no
    kinds/patch chunk is run through ``executeLua``.
    """
    tool = "realism_apply"
    if not isinstance(arguments, dict) and arguments is not None:
        return {"ok": False, "tool": tool, "errors": ["arguments must be an object"]}
    profile, dry_run, errors = _validate_apply_args(arguments or {})
    if errors:
        return {"ok": False, "tool": tool, "errors": errors}

    client = _get_client()
    live_map, cap = _live_state(client)
    live_names = set(live_map)
    live_before = len(live_names)

    steps: dict[str, Any] = {}
    ok = True

    if profile in ("all", "kinds", "power", "materials"):
        steps["kinds"] = _step_kinds(client, dry_run)
        ok = ok and not steps["kinds"]["errors"]

    if profile in ("all", "stock"):
        steps["stock"] = _step_stock(client, dry_run)
        ok = ok and not steps["stock"]["errors"]

    if profile in ("all", "power"):
        steps["power"] = _step_power(client, dry_run, live_names, cap)
        ok = ok and not steps["power"]["errors"]

    if profile in ("all", "materials"):
        steps["materials"] = _step_materials(client, dry_run, live_names, cap)
        ok = ok and not steps["materials"]["errors"]

    return {
        "ok": ok,
        "tool": tool,
        "profile": profile,
        "dry_run": dry_run,
        "cap": cap,
        "live_before": live_before,
        "live_after_plan": len(live_names),
        "steps": steps,
    }


# ---------------------------------------------------------------------------
# realism_status
# ---------------------------------------------------------------------------


def realism_status(arguments: dict[str, Any]) -> dict[str, Any]:
    """Read-only snapshot of everything realism_apply keeps alive."""
    tool = "realism_status"
    if arguments is not None and not isinstance(arguments, dict):
        return {"ok": False, "tool": tool, "errors": ["arguments must be an object"]}

    client = _get_client()
    out: dict[str, Any] = {"ok": True, "tool": tool}
    soft_errors: list[str] = []

    # -- behaviour kinds -----------------------------------------------
    present: list[str] = []
    try:
        res = client.execute_lua(
            "local t={} for k,_ in pairs(PBX.state.behaviors.kinds) do t[#t+1]=tostring(k) end "
            "table.sort(t) return table.concat(t, ',')"
        )
        raw = res.get("result") or ""
        present = [k for k in str(raw).split(",") if k]
    except (PowderAPIError, PowderConnectionError) as exc:
        soft_errors.append(f"kinds query failed: {type(exc).__name__}: {exc}")
    expected_runtime = sorted(_RUNTIME_KIND_NAMES)
    out["kinds"] = {
        "registered": present,
        "expected_runtime": expected_runtime,
        "missing_runtime": [k for k in expected_runtime if k not in present],
    }

    # -- custom element count / cap -------------------------------------
    live_map, cap = _live_state(client)
    out["custom_elements"] = {
        "live": len(live_map),
        "cap": cap,
        "free": max(0, cap - len(live_map)),
    }

    # -- stock patch in effect? ------------------------------------------
    patches, files_used, patch_errors = _load_patch_map()
    soft_errors.extend(patch_errors)
    expected_value = (patches.get(_SAMPLE_ELEMENT) or {}).get(_SAMPLE_PROPERTY)
    live_value: float | None = None
    try:
        res = client.execute_lua(
            f'return tostring(elem.property(elem.DEFAULT_PT_{_SAMPLE_ELEMENT}, "{_SAMPLE_PROPERTY}"))'
        )
        live_value = float(res.get("result"))
    except (PowderAPIError, PowderConnectionError, TypeError, ValueError) as exc:
        soft_errors.append(f"stock sample query failed: {type(exc).__name__}: {exc}")
    in_effect = (
        isinstance(expected_value, (int, float))
        and live_value is not None
        and abs(live_value - float(expected_value)) < 0.05
    )
    out["stock_patch"] = {
        "files": files_used,
        "sample_element": _SAMPLE_ELEMENT,
        "sample_property": _SAMPLE_PROPERTY,
        "expected": expected_value,
        "live": live_value,
        "in_effect": bool(in_effect),
    }

    # -- materials catalog totals -----------------------------------------
    live_names = set(live_map)
    try:
        cat = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))["entries"]
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        cat = []
        soft_errors.append(f"catalog load failed: {type(exc).__name__}: {exc}")
    by_priority: dict[str, dict[str, int]] = {}
    for e in cat:
        p = str(int(e.get("priority", 9)))
        bucket = by_priority.setdefault(p, {"total": 0, "live": 0})
        bucket["total"] += 1
        if e.get("name") in live_names:
            bucket["live"] += 1
    out["materials_catalog"] = {"total": len(cat), "by_priority": by_priority}

    # -- power element set coverage ----------------------------------------
    try:
        import scripts.define_power_elements as dpe  # noqa: PLC0415
        power_names = {e["name"] for e in dpe.ELEMENTS}
    except Exception as exc:  # noqa: BLE001
        power_names = set()
        soft_errors.append(f"power element list unavailable: {type(exc).__name__}: {exc}")
    out["power_elements"] = {
        "total": len(power_names),
        "live": len(power_names & live_names),
    }

    if soft_errors:
        out["errors"] = soft_errors
    return out


# ---------------------------------------------------------------------------
# HANDLERS registry
# ---------------------------------------------------------------------------


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


_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "realism_apply": realism_apply,
    "realism_status": realism_status,
}

HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    name: _guarded(name, fn) for name, fn in _RAW_HANDLERS.items()
}
