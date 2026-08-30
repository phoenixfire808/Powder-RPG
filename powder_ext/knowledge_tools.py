"""Knowledge base tools: turn the miner/experimenter output into queryable facts
and blueprint lint rules.

Why this exists
----------------
MINER-A/MINER-B are hand-writing element interaction facts into
``knowledge/element-interactions-part{1,2}.json`` and EXPERIMENTER is logging
verified/refuted claims into ``knowledge/experiments-*.jsonl``. Neither file is
useful to a small local model unless something turns them into a queryable
tool (``element_facts``) and something turns them into enforcement
(``blueprint_lint``). This module is that something.

Loading contract
-----------------
Every knowledge file is loaded **lazily** and **tolerantly**: absence is not an
error (the miners/experimenter may not have written it yet), a parse error is
reported but does not raise, and files are re-read whenever their mtime
changes so a long-lived MCP process picks up edits without a restart. See
``_load_json_cached`` / ``_load_jsonl_cached``.

Expected shapes (see D:/powder-toy/knowledge/BLUEPRINT_SPEC.md):
    element-interactions-part1.json / -part2.json ::
        {"elements": {"WATR": {name, state, flags, defaults, props,
                                transitions, reacts, behaviour,
                                builder_notes, ...}, ...},
         "signal_rules": [...]}                      # part2 only
    experiments-*.jsonl (one JSON object per line) ::
        {"id", "claim", "setup", "observed", "verdict", "numbers", "frames"}

Public tools (registered in ``powder_ext/schemas.py``):
    ``element_facts``  read-only; facts for one element, reactions between two
                        elements, or a free-text search, each annotated with
                        source file/path and any matching experiment verdicts.
    ``blueprint_lint``  read-only; compiles a blueprint (via
                        ``blueprint_tools.compile_blueprint``) and runs a
                        knowledge-and-lessons-derived rule set over the
                        resulting primitives' geometry.

``lint_compiled`` is also imported directly by
``blueprint_tools.blueprint_build`` so every build response carries a "lint"
section for free.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any, Callable

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from powder_ext import blueprint_tools as _bp  # noqa: E402

from powder_ext.repo_paths import KNOWLEDGE_DIR, REPO_ROOT

_KNOWLEDGE_DIR = KNOWLEDGE_DIR
_PART1_PATH = _KNOWLEDGE_DIR / "element-interactions-part1.json"
_PART2_PATH = _KNOWLEDGE_DIR / "element-interactions-part2.json"
_EXPERIMENTS_PATH = _KNOWLEDGE_DIR / "experiments-2026-08-25.jsonl"
_BUILD_LESSONS_PATH = _KNOWLEDGE_DIR / "build-lessons.jsonl"
_MATERIALS_CATALOG_PATH = _KNOWLEDGE_DIR / "materials-catalog.json"
_POWER_ELEMENTS_PATH = _KNOWLEDGE_DIR / "power-elements-2026-08-26.json"


# ---------------------------------------------------------------------------
# Lazy, mtime-invalidated file loading
# ---------------------------------------------------------------------------

_CACHE: dict[str, tuple[float, Any]] = {}


def _load_json_cached(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    """Return (data, error). data is None when the file is absent or invalid."""
    if not path.is_file():
        return None, None
    try:
        mtime = path.stat().st_mtime
    except OSError as exc:
        return None, f"{type(exc).__name__}: {exc}"
    key = str(path)
    cached = _CACHE.get(key)
    if cached and cached[0] == mtime:
        return cached[1], None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"{type(exc).__name__}: {exc}"
    _CACHE[key] = (mtime, data)
    return data, None


def _load_jsonl_cached(path: Path) -> tuple[list[dict[str, Any]], str | None]:
    """Return (records, error); malformed individual lines are skipped, not fatal."""
    if not path.is_file():
        return [], None
    try:
        mtime = path.stat().st_mtime
    except OSError as exc:
        return [], f"{type(exc).__name__}: {exc}"
    key = str(path)
    cached = _CACHE.get(key)
    if cached and cached[0] == mtime:
        return cached[1], None
    records: list[dict[str, Any]] = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return [], f"{type(exc).__name__}: {exc}"
    for lineno, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.strip()
        if not stripped:
            continue
        try:
            parsed = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            parsed = dict(parsed)
            parsed["_line"] = lineno
            records.append(parsed)
    _CACHE[key] = (mtime, records)
    return records, None


def _load_elements() -> dict[str, Any]:
    """Merge part1 + part2 ``elements`` maps (part2 wins per-field on conflict)."""
    merged: dict[str, dict[str, Any]] = {}
    sources: dict[str, list[str]] = {}
    signal_rules: list[Any] = []
    part1_data, part1_err = _load_json_cached(_PART1_PATH)
    part2_data, part2_err = _load_json_cached(_PART2_PATH)
    for data, filename in ((part1_data, _PART1_PATH.name), (part2_data, _PART2_PATH.name)):
        if not isinstance(data, dict):
            continue
        elements = data.get("elements")
        if isinstance(elements, dict):
            for key, value in elements.items():
                ident = str(key).strip().upper()
                if not ident:
                    continue
                merged.setdefault(ident, {})
                if isinstance(value, dict):
                    merged[ident].update(value)
                sources.setdefault(ident, []).append(filename)
        rules = data.get("signal_rules")
        if isinstance(rules, list):
            signal_rules.extend(rules)
    return {
        "elements": merged,
        "sources": sources,
        "signal_rules": signal_rules,
        "meta": {
            "part1_loaded": isinstance(part1_data, dict),
            "part2_loaded": isinstance(part2_data, dict),
            "part1_error": part1_err,
            "part2_error": part2_err,
            "part1_path": str(_PART1_PATH),
            "part2_path": str(_PART2_PATH),
        },
    }


def _load_experiments() -> tuple[list[dict[str, Any]], str | None]:
    return _load_jsonl_cached(_EXPERIMENTS_PATH)


def _load_lessons() -> list[dict[str, Any]]:
    records, _err = _load_jsonl_cached(_BUILD_LESSONS_PATH)
    return records


def _load_custom_catalog() -> dict[str, Any]:
    """Merge ``materials-catalog.json``'s ``entries`` list with the bare-list
    ``power-elements-*.json`` into ``ident -> catalog entry``. Each entry carries
    the define_element-shaped facts the lint rules need for custom (non-native)
    elements: ``type`` (SOLID/LIQUID/GAS/PART), ``properties`` (PROP_CONDUCTS,
    PROP_DEADLY, PROP_RADIOACTIVE, ...), ``highTemperature``/
    ``highTemperatureTransition``, ``lowTemperature``/``lowTemperatureTransition``,
    ``temperature`` (spawn temp), ``flammable``, and ``behavior`` ({"kind": ...,
    "params": {...}} -- "reactive" behaviours carry a chem_kinds.lua-style
    ``params.rules`` string, see ``_parse_reactive_rules``).

    Both files are optional (absence is not an error) and re-read whenever their
    mtime changes, same lazy/tolerant contract as ``_load_elements`` above.
    power-elements wins per-ident on conflict (it is the newer reactor-parts set).
    """
    merged: dict[str, dict[str, Any]] = {}
    data1, err1 = _load_json_cached(_MATERIALS_CATALOG_PATH)
    entries1 = data1.get("entries") if isinstance(data1, dict) else None
    if isinstance(entries1, list):
        for entry in entries1:
            if isinstance(entry, dict) and entry.get("name"):
                merged[str(entry["name"]).strip().upper()] = entry
    data2, err2 = _load_json_cached(_POWER_ELEMENTS_PATH)
    if isinstance(data2, list):
        for entry in data2:
            if isinstance(entry, dict) and entry.get("name"):
                merged[str(entry["name"]).strip().upper()] = entry
    return {
        "entries": merged,
        "meta": {
            "materials_catalog_loaded": isinstance(data1, dict),
            "power_elements_loaded": isinstance(data2, list),
            "materials_catalog_error": err1,
            "power_elements_error": err2,
            "materials_catalog_path": str(_MATERIALS_CATALOG_PATH),
            "power_elements_path": str(_POWER_ELEMENTS_PATH),
        },
    }


def _catalog_entry(ident: str) -> dict[str, Any] | None:
    entry = _load_custom_catalog()["entries"].get(ident)
    return entry if isinstance(entry, dict) else None


_REACTIVE_RULE_HEAT_RE = re.compile(r"^HEAT(\d+(?:\.\d+)?)$")


def _parse_reactive_rules(rules_str: Any) -> list[dict[str, Any]]:
    """Parse a chem_kinds.lua ``kinds.reactive`` rules string:
    ``"WITH>SELF_BECOMES,OTHER_BECOMES:dT:chance[:needs][:extra]"`` entries
    separated by ``;``. See scripts/lua/chem_kinds.lua for the authoritative
    grammar this mirrors (WITH may also be ANY / AIR / HEAT<K>).
    """
    out: list[dict[str, Any]] = []
    if not isinstance(rules_str, str) or not rules_str.strip():
        return out
    for rule in rules_str.split(";"):
        rule = rule.strip()
        if not rule or ">" not in rule:
            continue
        with_part, rest = rule.split(">", 1)
        fields = rest.split(":")
        prod = fields[0] if fields else ""
        if "," in prod:
            self_b, other_b = (x.strip().upper() or "SELF" for x in prod.split(",", 1))
        else:
            self_b, other_b = "SELF", "SELF"

        def _num(idx: int) -> float | None:
            if idx < len(fields) and fields[idx].strip():
                try:
                    return float(fields[idx].strip())
                except ValueError:
                    return None
            return None

        dT = _num(1)
        chance = _num(2)
        needs_field = fields[3].strip().upper() if len(fields) > 3 and fields[3].strip() else None
        # needs may be a bare element ("O2") or the "ELEM=BECOMES" DSL extension
        # (2026-08-26, e.g. "O2=NONE") for stoichiometric consumption; the lint
        # rule only geometrically checks for the element's presence, so split
        # off any "=BECOMES" suffix and keep just the element name.
        needs = needs_field.split("=", 1)[0].strip() or None if needs_field else None
        needs_becomes = needs_field.split("=", 1)[1].strip() if needs_field and "=" in needs_field else None
        extra = fields[4].strip().upper() if len(fields) > 4 and fields[4].strip() else None
        with_ident = with_part.strip().upper()
        heat_match = _REACTIVE_RULE_HEAT_RE.match(with_ident)
        heat_k = float(heat_match.group(1)) if heat_match else None
        if heat_match:
            with_ident = "HEAT"
        out.append({
            "with": with_ident, "heat_k": heat_k, "self_becomes": self_b or "SELF",
            "other_becomes": other_b or "SELF", "dT": dT, "chance": chance,
            "needs": needs, "needs_becomes": needs_becomes, "extra": extra,
        })
    return out


# ---------------------------------------------------------------------------
# Text matching helpers
# ---------------------------------------------------------------------------

def _mentions(text: Any, ident: str) -> bool:
    if not isinstance(text, str) or not text or not ident:
        return False
    try:
        pattern = r"(?<![A-Za-z0-9])" + re.escape(ident) + r"(?![A-Za-z0-9])"
        return re.search(pattern, text, re.IGNORECASE) is not None
    except re.error:
        return ident.lower() in text.lower()


def _experiment_matches(record: dict[str, Any], ident: str) -> bool:
    for field in ("claim", "setup", "observed"):
        if _mentions(record.get(field), ident):
            return True
    numbers = record.get("numbers")
    if isinstance(numbers, dict) and any(_mentions(str(k), ident) for k in numbers):
        return True
    elements = record.get("elements")
    if isinstance(elements, list) and any(str(e).strip().upper() == ident for e in elements):
        return True
    return False


def _experiment_summary(record: dict[str, Any]) -> dict[str, Any]:
    line = record.get("_line")
    return {
        "id": record.get("id"),
        "claim": record.get("claim"),
        "verdict": record.get("verdict"),
        "observed": record.get("observed"),
        "setup": record.get("setup"),
        "numbers": record.get("numbers"),
        "frames": record.get("frames"),
        "src": f"{_EXPERIMENTS_PATH.name}#{line}" if line else _EXPERIMENTS_PATH.name,
    }


# ---------------------------------------------------------------------------
# element_facts
# ---------------------------------------------------------------------------

def _single_element_facts(ident: str, knowledge: dict[str, Any], experiments: list[dict[str, Any]]) -> dict[str, Any]:
    data = knowledge["elements"].get(ident)
    srcs = list(knowledge["sources"].get(ident, []))
    exps = [_experiment_summary(r) for r in experiments if _experiment_matches(r, ident)]
    out: dict[str, Any] = {
        "element": ident,
        "known": data is not None,
        "facts": data,
        "src": [{"file": f, "path": f"elements.{ident}"} for f in srcs],
        "experiments": exps,
        "experiment_count": len(exps),
    }
    if data is None:
        out["hint"] = f"no recorded interaction facts for {ident} yet"
    return out


_REACTION_FIELDS = ("reacts", "signals", "transitions", "behaviour", "builder_notes")


def _reaction_facts(a: str, b: str, knowledge: dict[str, Any], experiments: list[dict[str, Any]]) -> dict[str, Any]:
    findings: list[dict[str, Any]] = []
    for ident, other in ((a, b), (b, a)):
        data = knowledge["elements"].get(ident)
        if not isinstance(data, dict):
            continue
        src_files = "+".join(knowledge["sources"].get(ident, ["element-interactions"]))
        for field in _REACTION_FIELDS:
            value = data.get(field)
            if value is None:
                continue
            if isinstance(value, list):
                for entry in value:
                    blob = json.dumps(entry, default=str)
                    if _mentions(blob, other):
                        findings.append({
                            "from": ident, "about": other, "field": field, "entry": entry,
                            "src": {"file": src_files, "path": f"elements.{ident}.{field}"},
                        })
            else:
                blob = value if isinstance(value, str) else json.dumps(value, default=str)
                if _mentions(blob, other):
                    findings.append({
                        "from": ident, "about": other, "field": field, "entry": value,
                        "src": {"file": src_files, "path": f"elements.{ident}.{field}"},
                    })
    for index, rule in enumerate(knowledge.get("signal_rules") or []):
        blob = json.dumps(rule, default=str)
        if _mentions(blob, a) and _mentions(blob, b):
            findings.append({
                "from": "signal_rules", "about": f"{a}+{b}", "entry": rule,
                "src": {"file": _PART2_PATH.name, "path": f"signal_rules[{index}]"},
            })
    exps = [
        _experiment_summary(r) for r in experiments
        if _experiment_matches(r, a) and _experiment_matches(r, b)
    ]
    return {
        "element": a, "with": b,
        "known": bool(findings),
        "reactions": findings,
        "experiments": exps,
        "experiment_count": len(exps),
        "hint": None if findings else f"no recorded reaction between {a} and {b} yet",
    }


def _text_search(query: str, knowledge: dict[str, Any], experiments: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    q = query.lower()
    results: list[dict[str, Any]] = []
    for ident in sorted(knowledge["elements"]):
        data = knowledge["elements"][ident]
        blob = json.dumps({"id": ident, **(data or {})}, default=str).lower()
        if q in blob:
            results.append({
                "element": ident,
                "known": True,
                "facts": data,
                "src": [{"file": f, "path": f"elements.{ident}"} for f in knowledge["sources"].get(ident, [])],
                "experiments": [_experiment_summary(r) for r in experiments if _experiment_matches(r, ident)],
            })
            if len(results) >= limit:
                return results
    for index, rule in enumerate(knowledge.get("signal_rules") or []):
        if q in json.dumps(rule, default=str).lower():
            results.append({"element": None, "signal_rule": rule, "src": {"file": _PART2_PATH.name, "path": f"signal_rules[{index}]"}})
            if len(results) >= limit:
                return results
    for record in experiments:
        blob = json.dumps({k: v for k, v in record.items() if k != "_line"}, default=str).lower()
        if q in blob:
            results.append({"element": None, "experiment": _experiment_summary(record)})
            if len(results) >= limit:
                return results
    return results


def element_facts(arguments: dict[str, Any]) -> dict[str, Any]:
    tool = "element_facts"
    args = arguments or {}
    try:
        limit = int(args.get("limit", 20))
    except (TypeError, ValueError):
        limit = 20
    limit = max(1, min(limit, 200))

    knowledge = _load_elements()
    experiments, exp_err = _load_experiments()
    sources_loaded = {
        "part1_loaded": knowledge["meta"]["part1_loaded"],
        "part2_loaded": knowledge["meta"]["part2_loaded"],
        "experiments_loaded": _EXPERIMENTS_PATH.is_file(),
        "part1_error": knowledge["meta"]["part1_error"],
        "part2_error": knowledge["meta"]["part2_error"],
        "experiments_error": exp_err,
        "element_count": len(knowledge["elements"]),
        "signal_rule_count": len(knowledge.get("signal_rules") or []),
        "experiment_count": len(experiments),
    }

    element_raw = args.get("element")
    with_raw = args.get("with")
    query = " ".join(str(args.get("query") or "").split())

    if not element_raw and not with_raw and not query:
        return {
            "ok": False, "tool": tool,
            "error": "provide at least one of: element, query",
            "sources_loaded": sources_loaded,
        }

    results: list[dict[str, Any]] = []

    if element_raw:
        ident, hint = _bp.resolve_element(element_raw)
        if ident is None:
            return {"ok": False, "tool": tool, "error": hint, "sources_loaded": sources_loaded}
        if with_raw:
            other_ident, other_hint = _bp.resolve_element(with_raw)
            if other_ident is None:
                return {"ok": False, "tool": tool, "error": other_hint, "sources_loaded": sources_loaded}
            results.append(_reaction_facts(ident, other_ident, knowledge, experiments))
        else:
            results.append(_single_element_facts(ident, knowledge, experiments))
    elif query:
        results.extend(_text_search(query, knowledge, experiments, limit))

    results = results[:limit]
    return {
        "ok": True,
        "tool": tool,
        "query": {"element": element_raw, "with": with_raw, "query": query or None, "limit": limit},
        "count": len(results),
        "results": results,
        "sources_loaded": sources_loaded,
    }


# ---------------------------------------------------------------------------
# blueprint_lint rule engine
# ---------------------------------------------------------------------------
# Rules operate on the ABSOLUTE, compiled primitive list from
# blueprint_tools.compile_blueprint -- never on the raw (relative) blueprint
# JSON -- so anchors, modules, repeats and groups have already been resolved
# into concrete pixel geometry. "Adjacent" between two primitives means their
# bounding boxes touch (0px gap) or overlap; see `_bbox` / `_adjacent`.
#
# Every numeric threshold below is either read from the knowledge base when
# present (props.highTemperature / lowTemperature / flammable, flags
# containing "conduct") or falls back to a small, clearly-marked static table
# so the rule still fires usefully before the miners' files exist. Once real
# data lands in element-interactions-part{1,2}.json the knowledge-backed path
# takes over automatically (see _is_conductor / _melts_below / _boiling_point
# / _high_temp_transition).
# ---------------------------------------------------------------------------

_FALLBACK_CONDUCTORS = {
    "METL", "IRON", "COPR", "PSCN", "NSCN", "INST", "BMTL", "BRMT",
    "SWCH", "BTRY", "TUNG", "GOLD", "LRBD", "RFRG", "ETRD",
}

_FALLBACK_MELTABLE = {
    "WOOD", "SAWD", "PLNT", "VINE", "ICE", "SNOW", "WAX", "MWAX",
    "COAL", "OIL", "CLST", "SPNG", "RBDM", "SOAP", "GOO", "SEED",
    "YEST", "FWRK", "FIRW", "GUN", "NITR", "THRM", "DYST", "BOMB",
    "C-4", "C-5", "TNT", "STKM", "FIGH",
}

_CRYOGENIC_ELEMENTS = {"LN2", "LO2", "ICE", "NICE", "N2", "O2", "H2", "FRZW", "FRZZ", "RIME", "LHE", "LH2"}
# Approximate boiling/melting point in Kelvin used only when the knowledge
# base has no props.lowTemperature/highTemperature for the element yet.
_FALLBACK_CRYO_THRESHOLD_K = {
    "LN2": 77.0, "N2": 77.0, "LO2": 90.0, "O2": 90.0, "LHE": 4.2, "LH2": 20.3,
    "ICE": 273.15, "NICE": 273.15, "H2": 20.0,
    "FRZW": 273.15, "FRZZ": 273.15, "RIME": 273.15,
}

_HOT_ELEMENTS = {"PLSM", "LAVA", "FIRE"}

# element -> (highTemperature K, transition target) used only when the
# knowledge base has no props.highTemperature/highTemperatureTransition yet.
_FALLBACK_HIGH_TEMP = {
    "ICE": (273.15, "WATR"),
    "SNOW": (273.15, "WATR"),
    "WATR": (373.15, "WTRV"),
    "DSTW": (373.15, "WTRV"),
    "LN2": (77.0, "N2"),
    "LO2": (90.0, "O2"),
    "GOLD": (1337.0, "LAVA"),
    "WOOD": (383.15, "FIRE"),
}

_CONDUCTOR_ADJACENCY_RULE = "watr_conductor_adjacency"
_HEAT_UNINSULATED_RULE = "heat_source_uninsulated"
_CRYO_NO_COLD_RULE = "cryo_no_cold_temp"
_HOT_MELTABLE_RULE = "hot_adjacent_meltable"
_PUMP_VACU_WALL_RULE = "pump_vacu_no_wall"
_PSCN_LCRY_RULE = "pscn_not_touching_lcry"
_CLNE_CTYPE_RULE = "clne_no_ctype"
_CHANNEL_REUSE_RULE = "channel_reuse"
_CONDUCTIVE_FLOOR_RULE = "conductive_floor_span"
_ABOVE_TRANSITION_RULE = "above_high_temp_transition"
_REACTIVE_HAZARD_RULE = "reactive_hazard"
_FLAMMABLE_HEAT_RULE = "flammable_near_heat"
_DEADLY_GAS_RULE = "deadly_gas_unsealed"
_MOLTEN_TEMP_RULE = "molten_needs_temp"
_MELT_POINT_RULE = "melt_point_exceeded"
_CONDUCTOR_COOLANT_RULE = "conductor_touching_coolant"


def _finding(severity: str, path: str, rule: str, problem: str, fix: str) -> dict[str, Any]:
    return {"severity": severity, "path": path, "rule": rule, "problem": problem, "fix": fix}


def _element_props(ident: str, knowledge: dict[str, Any]) -> dict[str, Any]:
    data = knowledge["elements"].get(ident)
    if isinstance(data, dict) and isinstance(data.get("props"), dict):
        return data["props"]
    return {}


def _element_blob(ident: str, knowledge: dict[str, Any]) -> str:
    """Whole-record text blob, used as a fallback for knowledge written as
    prose rather than structured numeric fields (MINER-B's real
    element-interactions-part2.json documents e.g. "HighTemperature=1887.15
    with no auto-transition" inside a free-text "state"/"transitions" string
    rather than a numeric props.highTemperature key -- this lets that data
    still drive the lint rules instead of only ever hitting the static
    fallback tables below).
    """
    data = knowledge["elements"].get(ident)
    if not isinstance(data, dict):
        return ""
    try:
        return json.dumps(data, default=str)
    except (TypeError, ValueError):
        return ""


_PROSE_HIGH_TEMP_RE = re.compile(r"HighTemperature\s*=\s*(-?\d+(?:\.\d+)?)")
_PROSE_HIGH_TEMP_TRANS_RE = re.compile(r"HighTemperatureTransition\s*=\s*([A-Z][A-Z0-9_-]{1,4})")
_PROSE_LOW_TEMP_RE = re.compile(r"LowTemperature\s*=\s*(-?\d+(?:\.\d+)?)")
_PROSE_FLAMMABLE_RE = re.compile(r"[Ff]lammable\s*[=:]\s*(\d+(?:\.\d+)?)")

# MINER-B's real element-interactions-part2.json encodes a structured
# "transitions": {"high_temp": "PT_LAVA at 1687", "low_temp": "PT_BIZRG at 100K", ...}
# dict for most elements (a handful, e.g. HEAC, instead write a free "note" with no
# PT_ target -- correctly treated as "no transition" below since both a temperature
# AND a target are required for a finding). Try this structured form before falling
# back to the looser "HighTemperature=N" prose regex above.
_TRANS_PT_AT_RE = re.compile(r"PT_([A-Z0-9_]+)\s*at\s*(-?\d+(?:\.\d+)?)\s*K?", re.IGNORECASE)


def _parse_transition_value(value: Any) -> tuple[float, str] | None:
    if not isinstance(value, str):
        return None
    match = _TRANS_PT_AT_RE.search(value)
    if not match:
        return None
    try:
        temp = float(match.group(2))
    except ValueError:
        return None
    return temp, match.group(1).upper()


_NEVER_SHORTS = {"INWR", "INSL", "GLAS", "BRCK", "CNCT", "DMND", "WOOD", "STNE", "TTAN_SLEEVED"}


def _is_conductor(ident: str, knowledge: dict[str, Any]) -> bool:
    if ident in _NEVER_SHORTS:
        return False  # INWR conducts only along itself and cannot bridge neighbours
    data = knowledge["elements"].get(ident)
    if isinstance(data, dict):
        flags = data.get("flags")
        if isinstance(flags, list):
            joined = " ".join(str(f) for f in flags)
        elif isinstance(flags, str):
            joined = flags
        else:
            joined = None
        if joined is not None:
            if "conduct" in joined.lower() and "no conduct" not in joined.lower() and "none" != joined.strip().lower():
                return True
            if joined.strip().lower() in ("", "none", "none special"):
                pass  # inconclusive prose -- fall through to fallback table
            else:
                return False  # knowledge has an opinion (non-empty, no "conduct") and it's "no"
    if ident in _FALLBACK_CONDUCTORS:
        return True
    # Custom (define_element) materials: materials-catalog.json / power-elements
    # mark conductors with a "PROP_CONDUCTS" entry in "properties", or a
    # behavior.kind of "conductor" (CU, STEL, RBAR, S316, AL61, ZIRC, NBTI, ...).
    entry = _catalog_entry(ident)
    if entry is not None:
        props = entry.get("properties")
        if isinstance(props, list) and any(str(p).upper() == "PROP_CONDUCTS" for p in props):
            return True
        behavior = entry.get("behavior")
        if isinstance(behavior, dict) and behavior.get("kind") == "conductor":
            return True
    return False


def _is_meltable(ident: str, knowledge: dict[str, Any]) -> bool:
    props = _element_props(ident, knowledge)
    flam = props.get("flammable")
    if isinstance(flam, (int, float)) and flam > 0:
        return True
    hightemp = props.get("highTemperature")
    if isinstance(hightemp, (int, float)):
        return hightemp < 1200.0
    blob = _element_blob(ident, knowledge)
    match = _PROSE_FLAMMABLE_RE.search(blob)
    if match:
        return float(match.group(1)) > 0
    match = _PROSE_HIGH_TEMP_RE.search(blob)
    if match:
        return float(match.group(1)) < 1200.0
    if props or blob:
        return False  # knowledge has data and no melt/flammable signal fired
    return ident in _FALLBACK_MELTABLE


def _element_transitions(ident: str, knowledge: dict[str, Any]) -> dict[str, Any]:
    data = knowledge["elements"].get(ident)
    if isinstance(data, dict) and isinstance(data.get("transitions"), dict):
        return data["transitions"]
    return {}


def _boiling_point(ident: str, knowledge: dict[str, Any]) -> float | None:
    props = _element_props(ident, knowledge)
    for key in ("lowTemperature", "boiling_point", "boilingPoint"):
        value = props.get(key)
        if isinstance(value, (int, float)):
            return float(value)
    parsed = _parse_transition_value(_element_transitions(ident, knowledge).get("low_temp"))
    if parsed:
        return parsed[0]
    match = _PROSE_LOW_TEMP_RE.search(_element_blob(ident, knowledge))
    if match:
        return float(match.group(1))
    return _FALLBACK_CRYO_THRESHOLD_K.get(ident)


def _high_temp_transition(ident: str, knowledge: dict[str, Any]) -> tuple[float, str] | None:
    props = _element_props(ident, knowledge)
    high = props.get("highTemperature")
    target = props.get("highTemperatureTransition") or props.get("high_temperature_transition")
    if isinstance(high, (int, float)) and isinstance(target, str) and target:
        return float(high), target
    parsed = _parse_transition_value(_element_transitions(ident, knowledge).get("high_temp"))
    if parsed:
        return parsed
    blob = _element_blob(ident, knowledge)
    match_high = _PROSE_HIGH_TEMP_RE.search(blob)
    match_target = _PROSE_HIGH_TEMP_TRANS_RE.search(blob)
    if match_high and match_target and match_target.group(1).upper() not in ("NT", "NONE", "NULL"):
        return float(match_high.group(1)), match_target.group(1).upper()
    return _FALLBACK_HIGH_TEMP.get(ident)


def _bbox(prim: dict[str, Any]) -> tuple[int, int, int, int] | None:
    kind = prim.get("kind")
    if kind in ("box", "set", "wall_box"):
        return prim["x1"], prim["y1"], prim["x2"], prim["y2"]
    if kind == "line":
        return (min(prim["x1"], prim["x2"]), min(prim["y1"], prim["y2"]),
                max(prim["x1"], prim["x2"]), max(prim["y1"], prim["y2"]))
    if kind == "circle":
        r = prim["radius"]
        return prim["cx"] - r, prim["cy"] - r, prim["cx"] + r, prim["cy"] + r
    return None


def _adjacent(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> bool:
    """True if bounding boxes a and b touch (0px gap) or overlap."""
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    return not (ax2 + 1 < bx1 or bx2 + 1 < ax1 or ay2 + 1 < by1 or by2 + 1 < ay1)


def _overlaps(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> bool:
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    return not (ax2 < bx1 or bx2 < ax1 or ay2 < by1 or by2 < ay1)


def _element_prims(compiled: dict[str, Any]) -> list[dict[str, Any]]:
    return [p for p in compiled["primitives"] if p.get("kind") in ("box", "line", "circle") and p.get("element") not in (None, "NONE")]


def _rule_watr_conductor(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    prims = _element_prims(compiled)
    watr = [(p, _bbox(p)) for p in prims if p["element"] == "WATR"]
    conductors = [(p, _bbox(p)) for p in prims if p["element"] != "WATR" and _is_conductor(p["element"], knowledge)]
    seen: set[tuple[str, str]] = set()
    for wp, wbox in watr:
        if wbox is None:
            continue
        for cp, cbox in conductors:
            if cbox is None or not _adjacent(wbox, cbox):
                continue
            key = (wp["path"], cp["path"])
            if key in seen:
                continue
            seen.add(key)
            findings.append(_finding(
                "warning", wp["path"], _CONDUCTOR_ADJACENCY_RULE,
                f"WATR at {wbox} is adjacent to conductor {cp['element']} at {cbox}; WATR conducts sparks and will short it",
                "use DSTW (distilled water) instead of WATR near wires, or add an INSL gap between them",
            ))
    return findings


def _rule_heat_uninsulated(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    prims = _element_prims(compiled)
    insl_boxes = [_bbox(p) for p in prims if p["element"] == "INSL"]
    for p in prims:
        if p["element"] not in ("WIFI", "PRTO", "HEAC"):
            continue
        box = _bbox(p)
        if box is None:
            continue
        x1, y1, x2, y2 = box
        strips = {
            "left": (x1 - 1, y1, x1 - 1, y2),
            "right": (x2 + 1, y1, x2 + 1, y2),
            "top": (x1, y1 - 1, x2, y1 - 1),
            "bottom": (x1, y2 + 1, x2, y2 + 1),
        }
        missing = [side for side, strip in strips.items() if not any(_overlaps(strip, ib) for ib in insl_boxes)]
        if missing:
            findings.append(_finding(
                "critical", p["path"], _HEAT_UNINSULATED_RULE,
                f"{p['element']} at {box} is not INSL-jacketed on side(s): {', '.join(missing)}; "
                f"{p['element']} stands at its channel/set temperature and will cook whatever touches it",
                "wrap it in an INSL box on every side (or use the insulated_box / wifi_node modules, which do this automatically)",
            ))
    return findings


def _rule_cryo_temp(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    set_prims = [p for p in compiled["primitives"] if p.get("kind") == "set"]
    for p in _element_prims(compiled):
        ident = p["element"]
        if ident not in _CRYOGENIC_ELEMENTS:
            continue
        boiling = _boiling_point(ident, knowledge)
        if boiling is None:
            continue
        box = _bbox(p)
        cold_enough = False
        for sp in set_prims:
            if sp.get("element") not in (None, ident):
                continue
            sbox = _bbox(sp)
            if sbox is None or not _overlaps(box, sbox):
                continue
            temp = sp.get("props", {}).get("temp")
            if isinstance(temp, (int, float)) and temp <= boiling + 5.0:
                cold_enough = True
                break
        if not cold_enough:
            findings.append(_finding(
                "warning", p["path"], _CRYO_NO_COLD_RULE,
                f"{ident} at {box} has no accompanying temp/temp_c prop at or below its ~{boiling:.1f}K "
                f"boiling/melting point; particles spawn at ambient (~295K) and will flash-transition away",
                f'add "props": {{"temp": {boiling - 20:.1f}}} (or the equivalent temp_c) to the same box',
            ))
    return findings


def _rule_hot_adjacent_meltable(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    prims = _element_prims(compiled)
    hot = [(p, _bbox(p)) for p in prims if p["element"] in _HOT_ELEMENTS]
    seen: set[tuple[str, str]] = set()
    for hp, hbox in hot:
        if hbox is None:
            continue
        for p in prims:
            if p is hp or not _is_meltable(p["element"], knowledge):
                continue
            box = _bbox(p)
            if box is None or not _adjacent(hbox, box):
                continue
            key = (hp["path"], p["path"])
            if key in seen:
                continue
            seen.add(key)
            findings.append(_finding(
                "critical", hp["path"], _HOT_MELTABLE_RULE,
                f"{hp['element']} at {hbox} is directly adjacent to meltable/flammable {p['element']} at {box}",
                "put an indestructible WALL boundary between them; elements alone rarely survive touching PLSM/LAVA/FIRE",
            ))
    return findings


def _rule_pump_vacu_wall(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    wall_boxes = [_bbox(p) for p in compiled["primitives"] if p.get("kind") == "wall_box"]
    for p in _element_prims(compiled):
        if p["element"] not in ("PUMP", "VACU"):
            continue
        box = _bbox(p)
        if box is None:
            continue
        x1, y1, x2, y2 = box
        strips = {
            "left": (x1 - 1, y1, x1 - 1, y2),
            "right": (x2 + 1, y1, x2 + 1, y2),
            "top": (x1, y1 - 1, x2, y1 - 1),
            "bottom": (x1, y2 + 1, x2, y2 + 1),
        }
        missing = [side for side, strip in strips.items() if not any(_overlaps(strip, wb) for wb in wall_boxes)]
        if missing:
            findings.append(_finding(
                "critical", p["path"], _PUMP_VACU_WALL_RULE,
                f"{p['element']} at {box} is not enclosed by a wall box on side(s): {', '.join(missing)}; "
                "a pressure pump/vacuum with no wall jacket leaks into the open sim instead of building a pressure differential",
                'wrap it in a {"wall": "WALL", ...} box on every side, or use the pressure_chamber module',
            ))
    return findings


def _rule_pscn_lcry(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    prims = _element_prims(compiled)
    pscn_boxes = [_bbox(p) for p in prims if p["element"] == "PSCN"]
    for p in prims:
        if p["element"] != "LCRY":
            continue
        box = _bbox(p)
        if box is None:
            continue
        if not any(_adjacent(box, pb) for pb in pscn_boxes if pb is not None):
            findings.append(_finding(
                "warning", p["path"], _PSCN_LCRY_RULE,
                f"LCRY at {box} has no PSCN touching it directly",
                "add a PSCN pad directly adjacent (0px gap) to the LCRY box; a 1px gap or NSCN feed will not light it (use the lcry_panel module)",
            ))
    return findings


def _rule_clne_ctype(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    set_prims = [p for p in compiled["primitives"] if p.get("kind") == "set"]
    for p in _element_prims(compiled):
        if p["element"] not in ("CLNE", "BCLN", "PCLN"):
            continue
        box = _bbox(p)
        has_ctype = False
        for sp in set_prims:
            if sp.get("element") not in (None, p["element"]):
                continue
            sbox = _bbox(sp)
            if sbox is None or not _overlaps(box, sbox):
                continue
            if "ctype" in sp.get("props", {}):
                has_ctype = True
                break
        if not has_ctype:
            findings.append(_finding(
                "warning", p["path"], _CLNE_CTYPE_RULE,
                f"{p['element']} at {box} has no ctype set; without one it is a blank cloner and does nothing",
                'add "set": {"ctype": "ELEMENT"} over the same box',
            ))
    return findings


def _rule_channel_reuse(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    by_channel: dict[int, dict[str, list[dict[str, Any]]]] = {}
    for p in compiled["primitives"]:
        if p.get("kind") != "set" or p.get("element") not in ("PRTI", "PRTO"):
            continue
        temp = p.get("props", {}).get("temp")
        if not isinstance(temp, (int, float)):
            continue
        raw_channel = (temp - 123.15) / 100.0 + 1.0
        channel = round(raw_channel)
        if abs(raw_channel - channel) > 0.02:
            continue  # temp wasn't set via a channel prop, skip
        by_channel.setdefault(channel, {"PRTI": [], "PRTO": []})[p["element"]].append(p)
    for channel, groups in sorted(by_channel.items()):
        if len(groups["PRTI"]) > 1 or len(groups["PRTO"]) > 1:
            paths = [p["path"] for p in groups["PRTI"] + groups["PRTO"]]
            findings.append(_finding(
                "critical", paths[0], _CHANNEL_REUSE_RULE,
                f"channel {channel} is used by {len(groups['PRTI'])} PRTI region(s) and {len(groups['PRTO'])} PRTO region(s); "
                "a channel is global, so every PRTI on it feeds every PRTO on it -- this looks like two independent portal pairs crosstalking",
                "give each independent portal pair its own channel number",
            ))
    return findings


def _rule_conductive_floor(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    bounds = compiled.get("bounds")
    if not bounds:
        return findings
    total_width = bounds["x2"] - bounds["x1"] + 1
    if total_width <= 0:
        return findings
    for p in _element_prims(compiled):
        if not _is_conductor(p["element"], knowledge):
            continue
        box = _bbox(p)
        if box is None:
            continue
        x1, y1, x2, y2 = box
        width = x2 - x1 + 1
        height = y2 - y1 + 1
        if width <= height:
            continue  # not floor-shaped
        if height > max(4, int(0.15 * width)):
            continue  # too tall to read as a thin floor run
        if width < 120:
            continue  # a short run cannot bridge separate systems; the rule is about plant-scale planes
        pct = 100.0 * width / max(total_width, 306)  # never measure against a build narrower than half the canvas
        if pct > 40.0:
            findings.append(_finding(
                "critical", p["path"], _CONDUCTIVE_FLOOR_RULE,
                f"conductive {p['element']} run at {box} spans {pct:.0f}% of the build's width ({width}px of {total_width}px); "
                "a single long conductive run this wide typically shorts across the whole build",
                "break the run with an INSL gap every ~20px, or use a non-conductive floor element",
            ))
    return findings


def _rule_above_transition(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings = []
    for p in compiled["primitives"]:
        if p.get("kind") != "set":
            continue
        element = p.get("element")
        temp = p.get("props", {}).get("temp")
        if not element or not isinstance(temp, (int, float)):
            continue
        info = _high_temp_transition(element, knowledge)
        if info is None:
            continue
        high, target = info
        if temp > high + 1.0:
            findings.append(_finding(
                "warning", p["path"], _ABOVE_TRANSITION_RULE,
                f"{element} is set to {temp:.1f}K but its HighTemperature transition is ~{high:.1f}K -> {target}; "
                "it will transition immediately instead of staying as placed",
                f"lower the temp below {high:.1f}K, or place {target} directly if that is the intended end state",
            ))
    return findings


def _rule_wall_cell_size(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    """Walls live on a 4x4 cell grid: a wall box smaller than a cell, or not aligned
    to it, still fills whole cells and silently erases every particle in them
    (lesson 2026-08-25: injector/drain pods wiped their own WIFI/PSCN)."""
    findings: list[dict[str, Any]] = []
    for p in compiled.get("primitives", []):
        if p.get("kind") != "wall_box":
            continue
        x1, y1, x2, y2 = p["x1"], p["y1"], p["x2"], p["y2"]
        w, h = x2 - x1 + 1, y2 - y1 + 1
        aligned = x1 % 4 == 0 and y1 % 4 == 0 and (x2 + 1) % 4 == 0 and (y2 + 1) % 4 == 0
        if w < 4 or h < 4 or not aligned:
            cx1, cy1, cx2, cy2 = x1 // 4, y1 // 4, x2 // 4, y2 // 4
            sev = "critical" if (w < 4 or h < 4) else "warning"  # misaligned-but-big: cells bleed 1-3px past the box
            findings.append(_finding(
                sev, p.get("path", "?"), "wall_cell_size",
                f"wall box ({x1},{y1})-({x2},{y2}) is {w}x{h} / not 4px-aligned; it fills cells "
                f"({cx1},{cy1})-({cx2},{cy2}) = pixels ({cx1*4},{cy1*4})-({cx2*4+3},{cy2*4+3}) and erases every particle there",
                "use BRCK for pixel-scale framing; use walls only as 4px-aligned boxes for pressure/particle boundaries",
            ))
    return findings


def _rule_portal_coolant_loop(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    """Community failure mode (research round 2, TPT forum): PRTI/PRTO can hold more than one
    particle per cell, so shuttling liquid coolant through a portal pair double-counts coolant
    mass ('ghost heat') and can silently lose particles. Flag portals touching liquid coolant."""
    findings: list[dict[str, Any]] = []
    prims = _element_prims(compiled)
    coolants = {"DSTW", "WATR", "SLTW", "LN2", "LO2", "LOXY", "OIL", "LAVA"}
    portals = [p for p in prims if p.get("element") in ("PRTI", "PRTO")]
    liquids = [p for p in prims if p.get("element") in coolants]
    for po in portals:
        pb = _bbox(po)
        if pb is None:
            continue
        for lq in liquids:
            lb = _bbox(lq)
            if lb is None:
                continue
            if not (lb[2] < pb[0] - 1 or lb[0] > pb[2] + 1 or lb[3] < pb[1] - 1 or lb[1] > pb[3] + 1):
                findings.append(_finding(
                    "warning", po.get("path", "?"), "portal_coolant_loop",
                    f"{po['element']} at {pb} touches liquid {lq['element']} at {lb}: portal coolant loops double-count coolant mass (ghost heat) and can lose particles",
                    "move heat with PIPE/HEAC or a solid heat bridge; keep portals for gases/energy or for one-shot transfers only",
                ))
                break
    return findings


# ---------------------------------------------------------------------------
# Catalog-driven rules (2026-08-26): materials-catalog.json + power-elements-*.json
# know each custom (define_element) material's type, temperatures, properties
# (PROP_CONDUCTS/PROP_DEADLY/...), behavior kind, and (for "reactive" behaviors)
# the chem_kinds.lua rules string -- see _load_custom_catalog / _parse_reactive_rules.
# ---------------------------------------------------------------------------

_HEAT_SOURCE_ALWAYS = {"FIRE", "LAVA", "PLSM"}
_COOLANT_ELEMENTS = {"WATR", "DSTW", "SLTW", "LN2", "LO2", "LOXY", "OIL", "NAK", "LBE", "FLBE", "LHE", "LH2"}
_FALLBACK_SOLID_BARRIERS = {"BRCK", "STNE", "GLAS", "METL", "TTAN", "DMND", "CNCT", "WOOD", "IRON", "TUNG", "GOLD"}


def _prim_overlapping_temp(prim: dict[str, Any], set_prims: list[dict[str, Any]]) -> float | None:
    """The props.temp of a "set" primitive that overlaps prim's box and applies to
    prim's element (or to any element, i.e. sp["element"] is None)."""
    box = _bbox(prim)
    if box is None:
        return None
    for sp in set_prims:
        if sp.get("element") not in (None, prim.get("element")):
            continue
        sbox = _bbox(sp)
        if sbox is None or not _overlaps(box, sbox):
            continue
        temp = sp.get("props", {}).get("temp")
        if isinstance(temp, (int, float)):
            return float(temp)
    return None


def _rule_reactive_hazard(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    """A custom "reactive" element (NA, MG, CAO, CAC2, ...) placed adjacent to one
    of its own trigger elements will fire chem_kinds.lua's reaction the instant the
    sim unpauses; flag it before the build gets drawn."""
    findings: list[dict[str, Any]] = []
    prims = _element_prims(compiled)
    boxed = [(p, _bbox(p)) for p in prims]
    seen: set[tuple[str, str, str]] = set()
    for p, box in boxed:
        if box is None:
            continue
        entry = _catalog_entry(p["element"])
        if entry is None:
            continue
        behavior = entry.get("behavior")
        if not isinstance(behavior, dict) or behavior.get("kind") != "reactive":
            continue
        rules = _parse_reactive_rules((behavior.get("params") or {}).get("rules"))
        for rule in rules:
            trigger = rule["with"]
            if trigger in ("HEAT", "ANY", "AIR"):
                continue  # not a placement-adjacency hazard this rule can see geometrically
            for op, obox in boxed:
                if op is p or obox is None or op["element"] != trigger or not _adjacent(box, obox):
                    continue
                if rule["needs"] and not any(
                    o2["element"] == rule["needs"] and b2 is not None and _adjacent(box, b2)
                    for o2, b2 in boxed
                ):
                    continue
                key = (p["path"], op["path"], trigger)
                if key in seen:
                    continue
                seen.add(key)
                reaction = f"{p['element']}+{trigger}"
                if rule["needs"]:
                    reaction += f" (needs {rule['needs']} nearby)"
                reaction += f" -> self={rule['self_becomes']}, other={rule['other_becomes']}"
                if rule["dT"] is not None:
                    reaction += f", {rule['dT']:+.0f}K"
                if rule["extra"]:
                    reaction += f", spawns {rule['extra']}"
                findings.append(_finding(
                    "warning", p["path"], _REACTIVE_HAZARD_RULE,
                    f"{p['element']} at {box} is adjacent to {trigger} at {obox}; this will react on unpause ({reaction})",
                    f"separate {p['element']} from {trigger} with an inert barrier, or place them touching only if the reaction is the intended trigger",
                ))
                break
    return findings


def _is_flammable_ge100(ident: str, knowledge: dict[str, Any]) -> bool:
    entry = _catalog_entry(ident)
    if entry is not None:
        flam = entry.get("flammable")
        if isinstance(flam, (int, float)):
            return flam >= 100.0
    props = _element_props(ident, knowledge)
    flam = props.get("flammable")
    if isinstance(flam, (int, float)):
        return flam >= 100.0
    match = _PROSE_FLAMMABLE_RE.search(_element_blob(ident, knowledge))
    if match:
        return float(match.group(1)) >= 100.0
    return False


def _rule_flammable_near_heat(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    prims = _element_prims(compiled)
    set_prims = [p for p in compiled["primitives"] if p.get("kind") == "set"]
    heat_sources: list[tuple[dict[str, Any], tuple[int, int, int, int]]] = []
    for p in prims:
        box = _bbox(p)
        if box is None:
            continue
        if p["element"] in _HEAT_SOURCE_ALWAYS:
            heat_sources.append((p, box))
            continue
        temp = _prim_overlapping_temp(p, set_prims)
        if temp is not None and temp >= 600.0:
            heat_sources.append((p, box))
    seen: set[tuple[str, str]] = set()
    for p in prims:
        if not _is_flammable_ge100(p["element"], knowledge):
            continue
        box = _bbox(p)
        if box is None:
            continue
        x1, y1, x2, y2 = box
        expanded = (x1 - 2, y1 - 2, x2 + 2, y2 + 2)
        for hp, hbox in heat_sources:
            if hp is p or not _overlaps(expanded, hbox):
                continue
            key = (p["path"], hp["path"])
            if key in seen:
                continue
            seen.add(key)
            findings.append(_finding(
                "critical", p["path"], _FLAMMABLE_HEAT_RULE,
                f"flammable {p['element']} at {box} is within 2px of heat source {hp['element']} at {hbox}",
                "move the flammable element at least 3px away, or add an INSL/non-flammable barrier between them",
            ))
    return findings


def _is_deadly_or_gas(ident: str) -> bool:
    entry = _catalog_entry(ident)
    if entry is None:
        return False
    props = entry.get("properties")
    if isinstance(props, list) and any(str(p).upper() == "PROP_DEADLY" for p in props):
        return True
    return str(entry.get("type", "")).upper() == "GAS"


def _is_solid_barrier(ident: str, knowledge: dict[str, Any]) -> bool:
    if ident in (None, "NONE"):
        return False
    entry = _catalog_entry(ident)
    if entry is not None:
        return str(entry.get("type", "")).upper() == "SOLID"
    return ident in _FALLBACK_SOLID_BARRIERS


def _rule_deadly_gas_unsealed(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    prims = _element_prims(compiled)
    wall_boxes = [_bbox(p) for p in compiled["primitives"] if p.get("kind") == "wall_box"]
    solid_boxes = [_bbox(p) for p in prims if _is_solid_barrier(p["element"], knowledge)] + wall_boxes
    solid_boxes = [b for b in solid_boxes if b is not None]
    for p in prims:
        if not _is_deadly_or_gas(p["element"]):
            continue
        box = _bbox(p)
        if box is None:
            continue
        x1, y1, x2, y2 = box
        strips = {
            "left": (x1 - 3, y1, x1 - 1, y2),
            "right": (x2 + 1, y1, x2 + 3, y2),
            "top": (x1, y1 - 3, x2, y1 - 1),
            "bottom": (x1, y2 + 1, x2, y2 + 3),
        }
        missing = [side for side, strip in strips.items() if not any(_overlaps(strip, sb) for sb in solid_boxes)]
        if missing:
            findings.append(_finding(
                "warning", p["path"], _DEADLY_GAS_RULE,
                f"{p['element']} at {box} (deadly/gas) is not enclosed by a solid boundary on side(s): {', '.join(missing)}; it will diffuse into the open sim",
                "surround it with a solid box (BRCK/STNE/GLAS/METL/...) or a wall_box on every side within 3px",
            ))
    return findings


def _molten_spawn_threshold(ident: str) -> tuple[float, float] | None:
    """(spawn_temp, freeze_point) for a custom liquid/PART element whose catalog
    spawn temperature is already >=500K (NAS, LBE, FLiBe, ...) -- these freeze
    solid the instant they cool below their lowTemperature transition, so unlike
    a room-temperature element they need an explicit hot temp prop to survive
    being placed at all."""
    entry = _catalog_entry(ident)
    if entry is None:
        return None
    spawn_temp = entry.get("temperature")
    if not isinstance(spawn_temp, (int, float)) or spawn_temp < 500.0:
        return None
    freeze = entry.get("lowTemperature")
    if not isinstance(freeze, (int, float)):
        freeze = spawn_temp
    return float(spawn_temp), float(freeze)


def _rule_molten_needs_temp(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    set_prims = [p for p in compiled["primitives"] if p.get("kind") == "set"]
    for p in _element_prims(compiled):
        ident = p["element"]
        threshold = _molten_spawn_threshold(ident)
        if threshold is None:
            continue
        _spawn_temp, freeze = threshold
        box = _bbox(p)
        if box is None:
            continue
        temp = _prim_overlapping_temp(p, set_prims)
        if temp is not None and temp >= freeze - 5.0:
            continue
        findings.append(_finding(
            "warning", p["path"], _MOLTEN_TEMP_RULE,
            f"{ident} at {box} has no accompanying temp/temp_c prop at or above its ~{freeze:.1f}K freeze point; "
            f"particles spawn at ambient (~295K) and will freeze solid immediately",
            f'add "props": {{"temp": {freeze + 20:.1f}}} (or the equivalent temp_c) to the same box',
        ))
    return findings


def _catalog_high_temp_transition(ident: str) -> tuple[float, str] | None:
    entry = _catalog_entry(ident)
    if entry is None:
        return None
    high = entry.get("highTemperature")
    target = entry.get("highTemperatureTransition")
    if isinstance(high, (int, float)) and isinstance(target, str) and target.strip().upper() not in ("", "NONE", "NT", "NULL"):
        return float(high), target.strip().upper()
    return None


def _rule_melt_point_exceeded(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    """Same shape as above_high_temp_transition but sourced from the materials
    catalog's highTemperature/highTemperatureTransition instead of the miners'
    element-interactions files, so custom (define_element) materials are covered
    even though they never appear in element-interactions-part{1,2}.json."""
    findings: list[dict[str, Any]] = []
    for p in compiled["primitives"]:
        if p.get("kind") != "set":
            continue
        element = p.get("element")
        temp = p.get("props", {}).get("temp")
        if not element or not isinstance(temp, (int, float)):
            continue
        info = _catalog_high_temp_transition(element)
        if info is None:
            continue
        high, target = info
        if temp > high + 1.0:
            findings.append(_finding(
                "warning", p["path"], _MELT_POINT_RULE,
                f"{element} is set to {temp:.1f}K but the materials catalog lists its melt/highTemperature transition at ~{high:.1f}K -> {target}; "
                "it will transition immediately instead of staying as placed",
                f"lower the temp below {high:.1f}K, or place {target} directly if that is the intended end state",
            ))
    return findings


def _rule_conductor_coolant(compiled: dict[str, Any], knowledge: dict[str, Any]) -> list[dict[str, Any]]:
    """Broader sibling of watr_conductor_adjacency: any conductor (native or a
    custom PROP_CONDUCTS material -- CU, STEL, RBAR, S316, AL61, ZIRC, NBTI, ...)
    touching a liquid/cryogenic coolant other than plain WATR (which the older
    rule already covers) can still short the same way."""
    findings: list[dict[str, Any]] = []
    prims = _element_prims(compiled)
    conductors = [(p, _bbox(p)) for p in prims if _is_conductor(p["element"], knowledge)]
    coolants = [(p, _bbox(p)) for p in prims if p["element"] in _COOLANT_ELEMENTS]
    seen: set[tuple[str, str]] = set()
    for cp, cbox in conductors:
        if cbox is None:
            continue
        for lp, lbox in coolants:
            if lp is cp or lbox is None or not _adjacent(cbox, lbox):
                continue
            key = (cp["path"], lp["path"])
            if key in seen:
                continue
            seen.add(key)
            findings.append(_finding(
                "warning", cp["path"], _CONDUCTOR_COOLANT_RULE,
                f"conductor {cp['element']} at {cbox} is adjacent to liquid coolant {lp['element']} at {lbox}; "
                "a conductive coolant run can short across it the same way WATR shorts METL",
                "add an INSL gap, or route the coolant through a non-conductive jacket/pipe",
            ))
    return findings


_LINT_RULES: tuple[Callable[[dict[str, Any], dict[str, Any]], list[dict[str, Any]]], ...] = (
    _rule_watr_conductor,
    _rule_heat_uninsulated,
    _rule_cryo_temp,
    _rule_hot_adjacent_meltable,
    _rule_pump_vacu_wall,
    _rule_pscn_lcry,
    _rule_clne_ctype,
    _rule_channel_reuse,
    _rule_conductive_floor,
    _rule_above_transition,
    _rule_wall_cell_size,
    _rule_portal_coolant_loop,
    _rule_reactive_hazard,
    _rule_flammable_near_heat,
    _rule_deadly_gas_unsealed,
    _rule_molten_needs_temp,
    _rule_melt_point_exceeded,
    _rule_conductor_coolant,
)


def tally_severity(findings: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for finding in findings:
        sev = str(finding.get("severity", "info"))
        counts[sev] = counts.get(sev, 0) + 1
    return counts


def lint_compiled(compiled: dict[str, Any], knowledge: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Run every lint rule over an already-compiled blueprint (see
    blueprint_tools.compile_blueprint). Never raises: an individual rule
    failing (e.g. on unexpected knowledge shapes) is swallowed so one bad
    rule cannot break the rest of the lint pass or blueprint_build itself.
    """
    if knowledge is None:
        knowledge = _load_elements()
    findings: list[dict[str, Any]] = []
    for rule in _LINT_RULES:
        try:
            findings.extend(rule(compiled, knowledge))
        except Exception as exc:  # noqa: BLE001
            findings.append(_finding("info", "lint", f"{rule.__name__}_internal_error", f"{type(exc).__name__}: {exc}", "report this to INTEGRATOR"))
    return findings


def blueprint_lint(arguments: dict[str, Any]) -> dict[str, Any]:
    tool = "blueprint_lint"
    args = arguments or {}
    bp = args.get("blueprint")
    if isinstance(bp, str):
        try:
            bp = json.loads(bp)
        except json.JSONDecodeError as exc:
            return {"ok": False, "tool": tool, "errors": [{"path": "blueprint", "problem": f"blueprint string is not valid JSON: {exc.msg} at char {exc.pos}"}]}
    compiled = _bp.compile_blueprint(bp)
    if not compiled["ok"]:
        return {
            "ok": False, "tool": tool,
            "errors": compiled["errors"],
            "findings": [],
            "finding_count": 0,
            "hint": "fix every entry in errors first; lint runs on the compiled geometry, not the raw blueprint",
        }
    findings = lint_compiled(compiled)
    return {
        "ok": True,
        "tool": tool,
        "errors": [],
        "findings": findings,
        "finding_count": len(findings),
        "counts_by_severity": tally_severity(findings),
        "primitive_count": len(compiled["primitives"]),
        "bounds": compiled["bounds"],
    }


# ---------------------------------------------------------------------------
# HANDLERS registry (same guard pattern as admin_tools / blueprint_tools)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# build_practices: the graded playbook (knowledge/playbook.json)
# ---------------------------------------------------------------------------

_PLAYBOOK_PATH = KNOWLEDGE_DIR / "playbook.json"


def build_practices(arguments: dict[str, Any]) -> dict[str, Any]:
    """Serve graded building practices: small, verified techniques that scale.

    args: level (int, exact), max_level (int), topic (str), name (str), query (str),
          include_steps (bool, default True). Each practice carries steps (blueprint
          fragments / actions), a verify check, pitfalls (lesson titles, resolved to the
          live lessons store when present), scale_up guidance and the modules it uses.
    """
    args = arguments or {}
    data, err = _load_json_cached(_PLAYBOOK_PATH)
    if not data:
        return {"ok": False, "tool": "build_practices", "error": err or "playbook missing", "path": str(_PLAYBOOK_PATH)}
    practices = list(data.get("practices", []))
    name = args.get("name")
    if name:
        practices = [p for p in practices if p.get("name") == name]
    if args.get("level") is not None:
        practices = [p for p in practices if int(p.get("level", -1)) == int(args["level"])]
    if args.get("max_level") is not None:
        practices = [p for p in practices if int(p.get("level", 99)) <= int(args["max_level"])]
    if args.get("topic"):
        practices = [p for p in practices if p.get("topic") == args["topic"]]
    if args.get("query"):
        q = str(args["query"]).lower()
        practices = [p for p in practices if q in json.dumps(p).lower()]
    lessons = {str(l.get("title")): l for l in _load_lessons()}
    out = []
    for p in practices:
        item = dict(p)
        item["pitfall_lessons"] = [
            {"title": t, "severity": lessons[t].get("severity"), "lesson": lessons[t].get("lesson"), "confirmations": lessons[t].get("confirmations")}
            if t in lessons else {"title": t, "missing": True}
            for t in p.get("pitfalls", [])
        ]
        if args.get("include_steps") is False:
            item.pop("steps", None)
        out.append(item)
    out.sort(key=lambda p: (int(p.get("level", 0)), p.get("name", "")))
    return {
        "ok": True, "tool": "build_practices", "count": len(out),
        "how_to_use": data.get("how_to_use"), "levels": sorted({int(p.get("level", 0)) for p in data.get("practices", [])}),
        "practices": out,
    }

_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "element_facts": element_facts,
    "blueprint_lint": blueprint_lint,
    "build_practices": build_practices,
}


def _guarded(tool_name: str, fn: Callable[[dict[str, Any]], dict[str, Any]]) -> Callable[[dict[str, Any]], dict[str, Any]]:
    def wrapper(arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            return fn(arguments if isinstance(arguments, dict) else {})
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "tool": tool_name, "error": "internal_error", "detail": f"{type(exc).__name__}: {exc}"}
    return wrapper


HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    name: _guarded(name, fn) for name, fn in _RAW_HANDLERS.items()
}
