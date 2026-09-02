"""MCP tools for the cited material/physics data sheets under knowledge/data/.

Why this exists: the project accumulated real, sourced spreadsheets (periodic elements,
3,383 nuclides, electromagnetics, compounds, decay chains, reactions) and every worker was
re-reading and re-deriving them from disk, or worse, re-fetching data somebody had already
sourced. This exposes them as queryable tools so the data is looked up once and used
everywhere, and so a value can always be traced back to its citation.

Design rules this follows, from the project's own standing constraints:
  * Read-only. These tools never mutate a sheet; generation is the job of the scripts that
    build them.
  * Every row carries its source. `sheet_get` returns the citation alongside the values, so
    a caller can never quote a number without being able to say where it came from.
  * A missing sheet is reported as missing, not as an empty result. Silent empty answers are
    this project's signature failure mode.
"""

from __future__ import annotations

import csv
import json
import os
from typing import Any, Callable

# knowledge/ is gitignored and local; resolve relative to this file so both trees work.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_DATA_DIRS = [
    os.path.join(_ROOT, "knowledge", "data"),
    os.path.join(_ROOT, "knowledge"),
]

_MAX_ROWS = 200  # a query that would return more is asked to narrow instead of flooding the caller


# Curated sheets only. knowledge/ is also full of one-off audit artifacts and scratch JSON;
# exposing those as "data sheets" would bury the real ones and invite someone to cite a
# throwaway file as a source. Anything in knowledge/data/ is curated by construction; from
# knowledge/ itself only these named sheets are surfaced.
_CURATED_TOP_LEVEL = {
    "periodic-elements-catalog",
    "reaction-matrix",
    "materials-catalog",
    "power-elements-2026-08-26",
}


def _sheet_paths() -> dict[str, str]:
    """Map bare sheet name -> path. knowledge/data/ is all curated; knowledge/ is whitelisted."""
    found: dict[str, str] = {}
    data_dir = _DATA_DIRS[0]
    if os.path.isdir(data_dir):
        for fn in sorted(os.listdir(data_dir)):
            if fn.lower().endswith((".csv", ".json")):
                found.setdefault(os.path.splitext(fn)[0], os.path.join(data_dir, fn))
    top = _DATA_DIRS[1]
    if os.path.isdir(top):
        for fn in sorted(os.listdir(top)):
            name = os.path.splitext(fn)[0]
            if name in _CURATED_TOP_LEVEL and fn.lower().endswith((".csv", ".json")):
                found.setdefault(name, os.path.join(top, fn))
    return found


def _load(path: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Return (rows, meta). Meta carries schema/source/count when the file provides them."""
    if path.lower().endswith(".json"):
        with open(path, encoding="utf-8") as fh:
            blob = json.load(fh)
        if isinstance(blob, list):
            return blob, {}
        for key in ("rows", "elements", "reactions", "data", "entries"):
            if isinstance(blob.get(key), list):
                meta = {k: v for k, v in blob.items() if k != key}
                return blob[key], meta
        return [blob], {}
    with open(path, encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh)), {}


def sheet_list(_args: dict[str, Any]) -> dict[str, Any]:
    """Every data sheet available, with row counts and size."""
    out = []
    for name, path in sorted(_sheet_paths().items()):
        try:
            rows, meta = _load(path)
            out.append({
                "sheet": name,
                "path": path,
                "rows": len(rows),
                "columns": sorted(rows[0].keys()) if rows and isinstance(rows[0], dict) else [],
                "schema": meta.get("schema"),
                "source": meta.get("source") or meta.get("sources"),
                "bytes": os.path.getsize(path),
            })
        except Exception as exc:  # a broken sheet is reported, never silently skipped
            out.append({"sheet": name, "path": path, "error": f"{type(exc).__name__}: {exc}"})
    return {"ok": True, "count": len(out), "sheets": out}


def sheet_get(args: dict[str, Any]) -> dict[str, Any]:
    """Query one sheet. Filter by exact column match and/or free-text, project columns."""
    name = (args.get("sheet") or "").strip()
    paths = _sheet_paths()
    if name not in paths:
        return {"ok": False, "error": f"unknown sheet {name!r}",
                "available": sorted(paths.keys())}
    rows, meta = _load(paths[name])

    where = args.get("where") or {}
    if where:
        def match(r: dict[str, Any]) -> bool:
            for k, v in where.items():
                if str(r.get(k, "")).strip().lower() != str(v).strip().lower():
                    return False
            return True
        rows = [r for r in rows if match(r)]

    q = (args.get("query") or "").strip().lower()
    if q:
        rows = [r for r in rows if any(q in str(v).lower() for v in r.values())]

    cols = args.get("columns")
    if cols:
        rows = [{c: r.get(c) for c in cols} for r in rows]

    limit = int(args.get("limit") or 50)
    total = len(rows)
    truncated = total > min(limit, _MAX_ROWS)
    rows = rows[: min(limit, _MAX_ROWS)]
    return {"ok": True, "sheet": name, "matched": total, "returned": len(rows),
            "truncated": truncated, "meta": meta, "rows": rows}


def sheet_lookup(args: dict[str, Any]) -> dict[str, Any]:
    """Everything known about one element/material/nuclide, across every sheet at once.

    This is the tool most callers actually want: give it "Fe" or "U-235" or "steel" and it
    returns every matching row from every sheet, each with its own citation, so a single
    lookup answers "what do we actually know about this, and who says so".
    """
    term = (args.get("term") or "").strip()
    if not term:
        return {"ok": False, "error": "term is required"}
    t = term.lower()
    hits: dict[str, list[dict[str, Any]]] = {}
    for name, path in sorted(_sheet_paths().items()):
        try:
            rows, _meta = _load(path)
        except Exception:
            continue
        keyed = []
        for r in rows:
            if not isinstance(r, dict):
                continue   # some sheets store positional arrays; they are not term-addressable
            for k in ("symbol", "nuclide", "name", "element", "material", "code", "formula", "a", "b"):
                if str(r.get(k, "")).strip().lower() == t:
                    keyed.append(r)
                    break
        if keyed:
            hits[name] = keyed[:20]
    return {"ok": True, "term": term, "sheets_matched": len(hits), "results": hits}


SCHEMAS: dict[str, dict] = {
    "sheet_list": {
        "type": "object", "additionalProperties": False, "properties": {},
    },
    "sheet_get": {
        "type": "object", "additionalProperties": False,
        "properties": {
            "sheet": {"type": "string"},
            "where": {"type": "object"},
            "query": {"type": "string"},
            "columns": {"type": "array", "items": {"type": "string"}},
            "limit": {"type": "integer"},
        },
        "required": ["sheet"],
    },
    "sheet_lookup": {
        "type": "object", "additionalProperties": False,
        "properties": {"term": {"type": "string"}},
        "required": ["term"],
    },
}

DESCRIPTIONS: dict[str, str] = {
    "sheet_list": "List every cited data sheet (periodic elements, nuclides, electromagnetics, "
                  "compounds, decay chains, reactions) with row counts, columns and source.",
    "sheet_get": "Query one data sheet: filter by exact column values and/or free text, project "
                 "columns, limit rows. Returns the sheet's citation metadata alongside the rows.",
    "sheet_lookup": "Everything known about one element, nuclide, compound or material across "
                    "every sheet at once, each result carrying its own source. Use this before "
                    "re-deriving or re-fetching any physical value.",
}

READONLY: dict[str, bool] = {"sheet_list": True, "sheet_get": True, "sheet_lookup": True}

HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "sheet_list": sheet_list,
    "sheet_get": sheet_get,
    "sheet_lookup": sheet_lookup,
}
