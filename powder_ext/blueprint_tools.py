"""Blueprint compiler: a tiny declarative JSON build language for small models.

Why this exists
---------------
``rapid_build`` / ``draw_project`` already accept box/line/wall primitives, but
they demand absolute pixel maths, exact catalog identifiers, and knowledge of
element quirks (WIFI channels live in ``tmp``, CLNE must be armed with a
``ctype``, PRTI/PRTO pair by ``tmp``, a PUMP needs a wall jacket...).  Small
local models get all of that wrong.  This module moves the hard part into
deterministic Python:

* **relative coordinates** -- every part is placed from a blueprint ``origin``;
  parts may carry an ``id`` and later parts may reference its anchors
  (``"core.right+2"``) instead of doing arithmetic;
* **forgiving names** -- ``"water"``, ``"Brick"``, ``"watr"`` all resolve to the
  catalog identifier, and unknown names come back with a *did-you-mean* fix;
* **property setting** -- a ``set`` op writes ``tmp``/``ctype``/``temp``/``life``
  over a region in one bulk Lua pass, so channels and cloner ctypes are plain
  JSON fields;
* **modules** -- parametric macros distilled from the build-lessons store
  (pressure chambers, portal pairs, self-healing liners, status panels, the owner's
  DEUT cell) that expand to primitives and expose named anchors;
* **dry_run by default** -- the compiled plan (absolute primitives, count,
  bounds, warnings) comes back *before* anything touches the sim, so a model
  can be shown what it is about to do.

Public tools (registered in ``powder_ext/schemas.py``):

``blueprint_schema``  read-only; returns the language reference, module
                      catalogue, aliases and a worked example -- paste it into
                      the local model's system prompt.
``blueprint_build``   compile + validate, and unless ``dry_run`` is false only
                      report.  Execution goes through the same ``PowderClient``
                      calls every other tool uses, stops on first error, and
                      reports ``succeeded``/``failed``/``skipped``.

Transport: ``PowderClient`` typed methods for placement, ``executeLua`` for the
bulk property pass (mirrors ``admin_tools.execute_lua``).
"""

from __future__ import annotations

import difflib
import json
import re
import sys
from pathlib import Path
from typing import Any, Callable

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from powder_bridge.client import PowderAPIError, PowderConnectionError, PowderClient  # noqa: E402
from powder_bridge.logging import resolve_correlation_id  # noqa: E402

PIXEL_W, PIXEL_H = 612, 384
MAX_PARTS = 512          # parts in the *source* blueprint (after module expansion: MAX_PRIMS)
MAX_PRIMS = 2048         # compiled primitives
MAX_STEPS = 32
MAX_STEP_FRAMES = 2000
MAX_EXPANSION_DEPTH = 6

from powder_ext.repo_paths import KNOWLEDGE_DIR, REPO_ROOT

_MATERIAL_INDEX = REPO_ROOT / "POWDER_TOY_MATERIAL_INDEX.json"
_NATIVE_CATALOG = REPO_ROOT / "POWDER_TOY_NATIVE_CATALOG.json"

_client: PowderClient | None = None


def _get_client() -> PowderClient:
    global _client
    if _client is None:
        _client = PowderClient()
    return _client


# ---------------------------------------------------------------------------
# Name resolution (elements + walls) with friendly aliases
# ---------------------------------------------------------------------------

# Human words a small model is likely to emit -> catalog identifier.
ELEMENT_ALIASES: dict[str, str] = {
    "water": "WATR", "distilled": "DSTW", "distilled water": "DSTW", "brick": "BRCK",
    "metal": "METL", "steel": "METL", "wood": "WOOD", "glass": "GLAS", "stone": "STNE",
    "sand": "SAND", "dirt": "GOO", "ground": "GOO", "grass": "PLNT", "plant": "PLNT",
    "diamond": "DMND", "titanium": "TTAN", "tungsten": "TUNG", "gold": "GOLD",
    "insulation": "INSL", "insulator": "INSL", "fire": "FIRE", "lava": "LAVA",
    "oil": "OIL", "coal": "COAL", "smoke": "SMKE", "steam": "WTRV", "ice": "ICE",
    "snow": "SNOW", "acid": "ACID", "salt": "SALT", "concrete": "CNCT", "clay": "CLST",
    "vacuum": "VACU", "pump": "PUMP", "void": "VOID", "clone": "CLNE", "cloner": "CLNE",
    "wire": "METL", "battery": "BTRY", "switch": "SWCH", "wifi": "WIFI", "lamp": "LCRY",
    "lcd": "LCRY", "sponge": "SPNG", "pipe": "PIPE", "valve": "PPIP", "portal in": "PRTI",
    "portal out": "PRTO", "shield": "SHLD", "piston": "PSTN", "frame": "FRME",
    "plutonium": "PLUT", "uranium": "URAN", "deuterium": "DEUT", "neutron": "NEUT",
    "neutrons": "NEUT", "hydrogen": "H2", "nitrogen": "N2", "oxygen": "O2", "lithium": "LITH",
    "heater": "HEAC", "cooler": "COOL", "thermometer": "TSNS", "pressure sensor": "PSNS",
    "delay": "DLAY", "spark": "SPRK", "laser": "ARAY", "ray": "ARAY", "photon": "PHOT",
    "light": "PHOT", "glow": "GLOW", "filter": "FILT", "bomb": "BOMB", "c4": "C4", "tnt": "TNT",
    "gunpowder": "GUN", "nitro": "NITR", "thermite": "THRM", "plasma": "PLSM",
    "nsilicon": "NSCN", "psilicon": "PSCN", "inst": "INST", "instant wire": "INST",
    "heat switch": "HSWC", "brick wall": "BRCK", "goo": "GOO", "gel": "GEL", "soap": "SOAP",
    "rubber": "RBDM", "bmetal": "BMTL", "broken metal": "BMTL", "iron": "IRON", "copper": "COPR",
    "spawner": "CLNE", "eraser": "NONE", "empty": "NONE", "air": "NONE", "nothing": "NONE",
}

WALL_ALIASES: dict[str, str] = {
    "wall": "WALL", "solid": "WALL", "solid wall": "WALL", "air": "AIR", "airwall": "AIR",
    "erase": "ERASE", "none": "ERASE", "fan": "FAN", "liquid": "LIQD", "liquid wall": "LIQD",
    "powder": "POWDR", "gas": "GAS", "energy": "ENRGY", "detector": "DTECT", "detect": "DTECT",
    "stream": "STRM", "gravity": "GRVTY", "gravity wall": "GRVTY", "conductor": "CNDTR",
    "blocking": "WALL", "allow air": "AIR", "allowliquid": "LIQD",
    "eholes": "EHOLE", "e-hole": "EHOLE", "eh": "EHOLE",
}

_CATALOG_CACHE: dict[str, Any] = {}


def _catalogs() -> dict[str, Any]:
    """Load element and wall identifier sets once (plus human-name maps)."""
    if _CATALOG_CACHE:
        return _CATALOG_CACHE
    elements: set[str] = set()
    element_names: dict[str, str] = {}
    walls: set[str] = set()
    wall_names: dict[str, str] = {}
    try:
        data = json.loads(_MATERIAL_INDEX.read_text(encoding="utf-8"))
        for material in data.get("materials", []):
            ident = None
            for key in ("lua_short", "identifier", "lua_default"):
                value = material.get(key)
                if value:
                    ident = str(value).upper()
                    break
            if not ident:
                continue
            # lua identifiers look like DEFAULT_PT_WATR / elem.DEFAULT_PT_WATR
            short = ident.split("DEFAULT_PT_")[-1].split(".")[-1]
            elements.add(short)
            for key in ("name", "description"):
                value = material.get(key)
                if value:
                    element_names.setdefault(str(value).strip().lower(), short)
    except Exception as exc:  # noqa: BLE001
        _CATALOG_CACHE["error"] = f"material catalog: {type(exc).__name__}: {exc}"
    try:
        data = json.loads(_NATIVE_CATALOG.read_text(encoding="utf-8"))
        for wall in data.get("walls", []):
            ident = str(wall.get("identifier") or wall.get("name") or "").upper()
            short = ident.split("DEFAULT_WL_")[-1].split(".")[-1]
            if short:
                walls.add(short)
                if wall.get("name"):
                    wall_names.setdefault(str(wall["name"]).strip().lower(), short)
                if wall.get("description"):
                    wall_names.setdefault(str(wall["description"]).strip().lower(), short)
    except Exception as exc:  # noqa: BLE001
        _CATALOG_CACHE["error"] = f"native catalog: {type(exc).__name__}: {exc}"
    _CATALOG_CACHE.update({
        "elements": elements, "element_names": element_names,
        "walls": walls, "wall_names": wall_names,
    })
    return _CATALOG_CACHE


_CUSTOM_CACHE: dict[str, Any] = {"at": 0.0, "names": set()}


def _custom_elements() -> set[str]:
    """Names of live custom elements (define_element), cached 20 s; empty set if the game is unreachable."""
    import time as _t
    if _t.time() - _CUSTOM_CACHE["at"] < 20:
        return _CUSTOM_CACHE["names"]
    names: set[str] = set()
    ids: dict[str, int] = {}
    try:
        from powder_ext import element_tools as _et
        res = _et.HANDLERS["list_custom_elements"]({})
        for e in (res.get("elements") or []):
            if isinstance(e, dict) and e.get("name"):
                nm = str(e["name"]).upper(); names.add(nm)
                for k in ("id", "elementId", "element_id", "typeId"):
                    if isinstance(e.get(k), int):
                        ids[nm] = int(e[k]); break
    except Exception:  # noqa: BLE001
        pass
    _CUSTOM_CACHE.update({"at": _t.time(), "names": names, "ids": ids})
    return names


def _bridge_element(name: str) -> Any:
    """Element identifier to send to the bridge: catalog names pass through; custom elements go as numeric id."""
    if name in _custom_elements():
        eid = _CUSTOM_CACHE.get("ids", {}).get(name)
        if eid is not None:
            return eid
    return name


_STOCK_LIVE: dict[str, bool] = {}


def _live_stock_element(name: str) -> bool:
    """Catalog gaps (e.g. O2, N2, H2 short names): ask the running game whether elem.DEFAULT_PT_<name> exists."""
    if name in _STOCK_LIVE:
        return _STOCK_LIVE[name]
    ok = False
    if name.isalnum() and 1 <= len(name) <= 4:
        try:
            r = _get_client().execute_lua(f'return tostring(elem.DEFAULT_PT_{name} ~= nil)')
            ok = str(r.get("result")) == "true"
        except Exception:  # noqa: BLE001
            ok = False
    _STOCK_LIVE[name] = ok
    return ok


def resolve_element(raw: Any) -> tuple[str | None, str | None]:
    """Return (identifier, fix_hint). identifier is None when unresolved."""
    if not isinstance(raw, str) or not raw.strip():
        return None, "element must be a non-empty string like \"BRCK\" or \"water\""
    cats = _catalogs()
    text = raw.strip()
    upper = text.upper()
    if upper in cats["elements"] or upper == "NONE":
        return upper, None
    if upper in _custom_elements():
        return upper, None
    _CUSTOM_CACHE["at"] = 0.0  # miss: refresh once in case the element was just defined
    if upper in _custom_elements():
        return upper, None
    if _live_stock_element(upper):
        return upper, None
    lower = text.lower()
    if lower in ELEMENT_ALIASES:
        return ELEMENT_ALIASES[lower], None
    if lower in cats["element_names"]:
        return cats["element_names"][lower], None
    candidates = difflib.get_close_matches(upper, sorted(cats["elements"]), n=3, cutoff=0.6)
    candidates += [ELEMENT_ALIASES[k] for k in difflib.get_close_matches(lower, list(ELEMENT_ALIASES), n=2, cutoff=0.75)]
    hint = f"unknown element '{raw}'"
    if candidates:
        hint += "; did you mean " + " / ".join(dict.fromkeys(candidates)) + "?"
    return None, hint


def resolve_wall(raw: Any) -> tuple[str | None, str | None]:
    if not isinstance(raw, str) or not raw.strip():
        return None, "wall must be a string like \"WALL\" or \"air\""
    cats = _catalogs()
    text = raw.strip()
    upper = text.upper()
    if upper in cats["walls"]:
        return upper, None
    lower = text.lower()
    if lower in WALL_ALIASES and WALL_ALIASES[lower] in cats["walls"]:
        return WALL_ALIASES[lower], None
    if lower in cats["wall_names"]:
        return cats["wall_names"][lower], None
    candidates = difflib.get_close_matches(upper, sorted(cats["walls"]), n=3, cutoff=0.5)
    hint = f"unknown wall '{raw}'"
    if candidates:
        hint += "; did you mean " + " / ".join(candidates) + "?"
    else:
        hint += f"; known walls: {', '.join(sorted(cats['walls']))[:300]}"
    return None, hint


# ---------------------------------------------------------------------------
# Coordinate expressions and anchors
# ---------------------------------------------------------------------------

class CompileError(Exception):
    def __init__(self, path: str, problem: str, fix: str | None = None) -> None:
        super().__init__(problem)
        self.path = path
        self.problem = problem
        self.fix = fix

    def as_dict(self) -> dict[str, Any]:
        out = {"path": self.path, "problem": self.problem}
        if self.fix:
            out["fix"] = self.fix
        return out


Anchors = dict[str, int]   # left,right,top,bottom,cx,cy,width,height


def _anchors(x1: int, y1: int, x2: int, y2: int) -> Anchors:
    return {
        "left": x1, "right": x2, "top": y1, "bottom": y2,
        "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2,
        "width": x2 - x1 + 1, "height": y2 - y1 + 1,
    }


def _eval_coord(value: Any, ids: dict[str, Anchors], path: str, axis: str, origin: int = 0) -> int:
    """Number (relative to origin), or absolute "id.anchor", "id.anchor+3", "id.anchor-2"."""
    if isinstance(value, bool):
        raise CompileError(path, f"{axis} must be an integer, not a boolean")
    if isinstance(value, (int, float)):
        return int(round(value)) + origin
    if isinstance(value, str):
        expr = value.replace(" ", "")
        offset = 0
        for sign in ("+", "-"):
            if sign in expr[1:]:
                head, tail = expr.rsplit(sign, 1)
                if tail.lstrip("-").isdigit():
                    expr, offset = head, int(sign + tail)
                    break
        if "." not in expr:
            raise CompileError(path, f"{axis} reference '{value}' must look like \"id.anchor\" or \"id.anchor+N\"",
                               "anchors: left right top bottom cx cy")
        ref, anchor = expr.split(".", 1)
        if ref not in ids:
            known = ", ".join(sorted(ids)) or "(none defined yet)"
            raise CompileError(path, f"{axis} references unknown id '{ref}'",
                               f"give an earlier part \"id\": \"{ref}\" or use one of: {known}")
        if anchor not in ids[ref]:
            raise CompileError(path, f"unknown anchor '{anchor}' on '{ref}'", "anchors: left right top bottom cx cy width height")
        return ids[ref][anchor] + offset
    raise CompileError(path, f"{axis} must be an integer or an \"id.anchor\" string")


def _pair(value: Any, ids: dict[str, Anchors], path: str, what: str, ox: int = 0, oy: int = 0) -> tuple[int, int]:
    """Resolve [x, y] to ABSOLUTE pixels: numbers are offset by the origin, "id.anchor" strings are absolute."""
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        raise CompileError(path, f"{what} must be a 2-item array [x, y]", f"example: \"{what}\": [10, 20]")
    return _eval_coord(value[0], ids, path, f"{what}[0]", ox), _eval_coord(value[1], ids, path, f"{what}[1]", oy)


def _size(value: Any, path: str) -> tuple[int, int]:
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        raise CompileError(path, "size must be [width, height]", "example: \"size\": [20, 8]")
    try:
        w, h = int(value[0]), int(value[1])
    except (TypeError, ValueError):
        raise CompileError(path, "size values must be integers") from None
    if w < 1 or h < 1:
        raise CompileError(path, "size values must be >= 1")
    return w, h


# ---------------------------------------------------------------------------
# Compiled primitive representation
# ---------------------------------------------------------------------------
# Each primitive is a dict with "kind" in:
#   box(element,x1,y1,x2,y2) line(element,...) circle(element,cx,cy,radius)
#   wall_box(wall,...) set(x1,y1,x2,y2,props,element?) stamp(name,x,y)


def _check_bounds(kind: str, x1: int, y1: int, x2: int, y2: int, path: str) -> None:
    if x1 > x2 or y1 > y2:
        raise CompileError(path, f"{kind} has negative size after resolving ({x1},{y1})-({x2},{y2})")
    if not (0 <= x1 and x2 < PIXEL_W and 0 <= y1 and y2 < PIXEL_H):
        raise CompileError(
            path, f"{kind} at ({x1},{y1})-({x2},{y2}) is outside the 612x384 canvas (x 0-611, y 0-383)",
            "move the origin or shrink the part",
        )


# ---------------------------------------------------------------------------
# Module library -- parametric macros distilled from the build-lessons store.
# Each returns (parts, anchor_override or None) in *local* coordinates where
# (0,0) is the module's "at".  Parts are ordinary blueprint parts, so modules
# may nest other modules.
# ---------------------------------------------------------------------------

def _p(v: dict[str, Any], key: str, default: Any) -> Any:
    return v.get(key, default) if isinstance(v, dict) else default


def mod_insulated_box(p: dict[str, Any]) -> list[dict[str, Any]]:
    """Element fill wrapped in an INSL jacket (lesson: jacket every heat source)."""
    w, h = int(_p(p, "width", 12)), int(_p(p, "height", 12))
    t = int(_p(p, "jacket", 2))
    fill = _p(p, "element", "NONE")
    parts = [{"box": _p(p, "jacket_element", "INSL"), "at": [0, 0], "size": [w + 2 * t, h + 2 * t]}]
    if fill and str(fill).upper() != "NONE":
        parts.append({"box": fill, "at": [t, t], "size": [w, h]})
    else:
        parts.append({"erase": True, "at": [t, t], "size": [w, h]})
    props = _p(p, "props", None)
    if isinstance(props, dict) and props:
        parts.append({"set": props, "at": [t, t], "size": [w, h]})
    return parts


def mod_wifi_node(p: dict[str, Any]) -> list[dict[str, Any]]:
    """WIFI block on a channel, INSL-jacketed, with a PSCN pad on one side."""
    ch = int(_p(p, "channel", 1))
    size = int(_p(p, "size", 3))
    side = str(_p(p, "pad_side", "right"))
    parts = [
        {"box": "INSL", "at": [0, 0], "size": [size + 2, size + 2]},
        {"box": "WIFI", "at": [1, 1], "size": [size, size]},
        {"set": {"channel": ch}, "at": [1, 1], "size": [size, size], "element": "WIFI"},
    ]
    pad = str(_p(p, "pad", "PSCN"))
    if side == "right":
        parts.append({"box": pad, "at": [size + 2, 1], "size": [2, size]})
    elif side == "left":
        parts.append({"box": pad, "at": [-2, 1], "size": [2, size]})
    elif side == "top":
        parts.append({"box": pad, "at": [1, -2], "size": [size, 2]})
    else:
        parts.append({"box": pad, "at": [1, size + 2], "size": [size, 2]})
    return parts


def mod_portal_pair(p: dict[str, Any]) -> list[dict[str, Any]]:
    """PRTI pad at (0,0) and PRTO pad at `to`, both on the same channel."""
    ch = int(_p(p, "channel", 1))
    size = int(_p(p, "size", 4))
    to = _p(p, "to", [40, 0])
    parts = [
        {"box": "PRTI", "at": [0, 0], "size": [size, size]},
        {"set": {"channel": ch}, "at": [0, 0], "size": [size, size], "element": "PRTI"},
        {"box": "PRTO", "at": to, "size": [size, size]},
        {"set": {"channel": ch}, "at": to, "size": [size, size], "element": "PRTO"},
    ]
    return parts


def mod_clne_liner(p: dict[str, Any]) -> list[dict[str, Any]]:
    """Self-healing liner: CLNE armed to `element` (default INSL) with INSL caps."""
    length = int(_p(p, "length", 40))
    vertical = bool(_p(p, "vertical", False))
    element = _p(p, "element", "INSL")
    if vertical:
        parts = [
            {"box": "INSL", "at": [0, 0], "size": [1, length + 2]},
            {"box": "CLNE", "at": [0, 1], "size": [1, length]},
            {"set": {"ctype": element, "temp": 295.15}, "at": [0, 1], "size": [1, length], "element": "CLNE"},
        ]
    else:
        parts = [
            {"box": "INSL", "at": [0, 0], "size": [length + 2, 1]},
            {"box": "CLNE", "at": [1, 0], "size": [length, 1]},
            {"set": {"ctype": element, "temp": 295.15}, "at": [1, 0], "size": [length, 1], "element": "CLNE"},
        ]
    return parts


def mod_pressure_chamber(p: dict[str, Any]) -> list[dict[str, Any]]:
    """Wall-boxed chamber with PUMP columns each side and a VACU sump below.

    Observed in the community PLUT plant: PUMP pins the chamber positive,
    VACU keeps the sump negative, wall grid stops the air exchange.
    """
    w, h = int(_p(p, "width", 40)), int(_p(p, "height", 32))
    sump = int(_p(p, "sump_height", 16))
    col = int(_p(p, "pump_width", 4))
    fill = _p(p, "fill", None)
    wall = _p(p, "wall", "WALL")
    inner_w = w + 2 * (col + 4)
    total_h = 4 + h + 4 + sump + 4
    parts: list[dict[str, Any]] = [
        # outer wall frame (hollow)
        {"wall": wall, "at": [0, 0], "size": [inner_w + 8, 4]},
        {"wall": wall, "at": [0, 4 + h], "size": [inner_w + 8, 4]},
        {"wall": wall, "at": [0, total_h - 4], "size": [inner_w + 8, 4]},
        {"wall": wall, "at": [0, 0], "size": [4, total_h]},
        {"wall": wall, "at": [inner_w + 4, 0], "size": [4, total_h]},
        # pump jackets + columns
        {"wall": wall, "at": [4 + col, 4], "size": [4, h]},
        {"wall": wall, "at": [4 + col + 4 + w, 4], "size": [4, h]},
        {"box": "PUMP", "at": [4, 4], "size": [col, h]},
        {"box": "PUMP", "at": [4 + col + 4 + w + 4, 4], "size": [col, h]},
        {"set": {"temp": float(_p(p, "pump_temp", 400.0))}, "at": [4, 4], "size": [inner_w, h], "element": "PUMP"},
        # sump
        {"box": "VACU", "at": [4, 4 + h + 4], "size": [inner_w, sump]},
    ]
    if fill:
        parts.append({"box": fill, "at": [4 + col + 4, 4], "size": [w, h]})
    return parts


def mod_shld_pipe_riser(p: dict[str, Any]) -> list[dict[str, Any]]:
    """PIPE run sheathed 1px in SHLD each side (SppS cross-section)."""
    length = int(_p(p, "length", 60))
    bore = int(_p(p, "bore", 2))
    vertical = bool(_p(p, "vertical", True))
    if vertical:
        return [
            {"box": "SHLD", "at": [0, 0], "size": [bore + 2, length]},
            {"box": "PIPE", "at": [1, 0], "size": [bore, length]},
        ]
    return [
        {"box": "SHLD", "at": [0, 0], "size": [length, bore + 2]},
        {"box": "PIPE", "at": [0, 1], "size": [length, bore]},
    ]


def mod_lcry_panel(p: dict[str, Any]) -> list[dict[str, Any]]:
    """LCRY indicator slab lit by a PSCN feed pad touching it directly (1px gap kills it)."""
    w, h = int(_p(p, "width", 12)), int(_p(p, "height", 8))
    return [
        {"box": "LCRY", "at": [0, 0], "size": [w, h]},
        {"box": "PSCN", "at": [-2, 0], "size": [2, h]},
    ]


def mod_tank(p: dict[str, Any]) -> list[dict[str, Any]]:
    """GLAS (or given shell) tank with a liquid fill, open or sealed top."""
    w, h = int(_p(p, "width", 30)), int(_p(p, "height", 20))
    shell = _p(p, "shell", "GLAS")
    liquid = _p(p, "liquid", "WATR")
    level = float(_p(p, "level", 0.7))
    sealed = bool(_p(p, "sealed", True))
    parts = [{"box": shell, "at": [0, 0], "size": [w, h]}]
    parts.append({"erase": True, "at": [1, 1], "size": [w - 2, h - 2]})
    fill_h = max(1, int((h - 2) * level))
    parts.append({"box": liquid, "at": [1, h - 1 - fill_h], "size": [w - 2, fill_h]})
    if not sealed:
        parts.append({"erase": True, "at": [1, 0], "size": [w - 2, 1]})
    return parts


def mod_deut_cell_mk2(p: dict[str, Any]) -> list[dict[str, Any]]:
    """the owner's field-proven self-recharging deuterium battery (see memory fsn2-plant-registry).

    Pure DMND 4px hull, 7x7 pocket, one cold CLNE(DEUT) breeder in a corner,
    one CRAY(NEUT) trigger in the ceiling, fed by a jacketed WIFI on `channel`.
    """
    ch = int(_p(p, "channel", 10))
    hull = 4
    pocket = int(_p(p, "pocket", 7))
    outer = pocket + 2 * hull
    parts = [
        {"box": "DMND", "at": [0, 0], "size": [outer, outer]},
        {"erase": True, "at": [hull, hull], "size": [pocket, pocket]},
        {"box": "CLNE", "at": [hull, hull + pocket - 1], "size": [1, 1]},
        {"set": {"ctype": "DEUT", "temp": 295.15}, "at": [hull, hull + pocket - 1], "size": [1, 1], "element": "CLNE"},
        {"box": "CRAY", "at": [hull + pocket // 2, hull - 1], "size": [1, 1]},
        {"set": {"ctype": "NEUT", "tmp": 1}, "at": [hull + pocket // 2, hull - 1], "size": [1, 1], "element": "CRAY"},
        {"box": "INSL", "at": [hull + pocket // 2 - 2, -5], "size": [5, 5]},
        {"box": "WIFI", "at": [hull + pocket // 2 - 1, -4], "size": [3, 3]},
        {"set": {"channel": ch}, "at": [hull + pocket // 2 - 1, -4], "size": [3, 3], "element": "WIFI"},
        {"box": "PSCN", "at": [hull + pocket // 2, -1], "size": [1, 1]},
    ]
    return parts


def mod_cooling_tower(p: dict[str, Any]) -> list[dict[str, Any]]:
    """Hollow BRCK tower with a DMND base band over a DSTW basin (visual)."""
    w, h = int(_p(p, "width", 40)), int(_p(p, "height", 70))
    basin = int(_p(p, "basin", 8))
    parts = [
        {"box": "BRCK", "at": [0, 0], "size": [w, h]},
        {"erase": True, "at": [3, 3], "size": [w - 6, h - 3]},
        {"box": "DMND", "at": [0, h - basin - 6], "size": [3, 6]},
        {"box": "DMND", "at": [w - 3, h - basin - 6], "size": [3, 6]},
        {"box": "BRCK", "at": [0, h], "size": [w, 2]},
        {"box": "DSTW", "at": [3, h - basin], "size": [w - 6, basin]},
    ]
    return parts


def mod_house(p: dict[str, Any]) -> list[dict[str, Any]]:
    """Small cottage: BRCK walls, WOOD roof, GLAS window, open door."""
    w, h = int(_p(p, "width", 24)), int(_p(p, "height", 16))
    parts = [
        {"box": _p(p, "wall_element", "BRCK"), "at": [0, 0], "size": [w, h]},
        {"erase": True, "at": [2, 2], "size": [w - 4, h - 2]},
        {"box": "GLAS", "at": [4, 4], "size": [5, 4]},
        {"erase": True, "at": [w - 8, h - 8], "size": [4, 8]},
    ]
    roof = _p(p, "roof_element", "WOOD")
    for i in range(h // 2):
        parts.append({"line": roof, "from": [i, -1 - i], "to": [w - 1 - i, -1 - i]})
    return parts


MODULES: dict[str, dict[str, Any]] = {
    "insulated_box": {"fn": mod_insulated_box, "params": {"element": "fill element (NONE=empty)", "width": 12, "height": 12, "jacket": 2, "props": "optional {tmp,ctype,temp,life} applied to the fill"}, "why": "WIFI/HEAC/PRTO stand at channel temperature - jacket every heat source"},
    "wifi_node": {"fn": mod_wifi_node, "params": {"channel": 1, "size": 3, "pad": "PSCN", "pad_side": "right|left|top|bottom"}, "why": "WIFI channel is a temperature band (compiler sets it); INSL jacket; PSCN pad to spark it"},
    "portal_pair": {"fn": mod_portal_pair, "params": {"channel": 1, "size": 4, "to": "[dx,dy] of the PRTO relative to the PRTI"}, "why": "PRTI channel N feeds every PRTO channel N (channel = temperature band)"},
    "clne_liner": {"fn": mod_clne_liner, "params": {"element": "INSL", "length": 40, "vertical": False}, "why": "CLNE armed to INSL regrows the barrier after damage"},
    "pressure_chamber": {"fn": mod_pressure_chamber, "params": {"width": 40, "height": 32, "sump_height": 16, "pump_width": 4, "fill": "optional element inside", "wall": "WALL"}, "why": "PUMP columns + VACU sump pressure pair inside a wall grid"},
    "shld_pipe_riser": {"fn": mod_shld_pipe_riser, "params": {"length": 60, "bore": 2, "vertical": True}, "why": "SHLD sheath self-repairs and insulates the pipe"},
    "lcry_panel": {"fn": mod_lcry_panel, "params": {"width": 12, "height": 8}, "why": "PSCN must touch LCRY directly"},
    "tank": {"fn": mod_tank, "params": {"width": 30, "height": 20, "shell": "GLAS", "liquid": "WATR", "level": 0.7, "sealed": True}, "why": "sealed shells; liquids leak through any gap"},
    "deut_cell_mk2": {"fn": mod_deut_cell_mk2, "params": {"channel": 10, "pocket": 7}, "why": "the owner's proven DEUT battery: DMND hull, cold CLNE(DEUT), CRAY(NEUT) trigger via WIFI"},
    "cooling_tower": {"fn": mod_cooling_tower, "params": {"width": 40, "height": 70, "basin": 8}, "why": "visual tower, DMND base band, DSTW basin"},
    "house": {"fn": mod_house, "params": {"width": 24, "height": 16, "wall_element": "BRCK", "roof_element": "WOOD"}, "why": "simple cottage"},
}


# ---------------------------------------------------------------------------
# Module registry -- extra parametric modules loaded from JSON files at call
# time (ANALYST writes them once a design proves out, or blueprint_module_save
# writes them after validating a build). Format per file:
#   {"name": str, "description": str, "why": str, "params": {"k": default, ...},
#    "anchors_note": str?, "parts": [...blueprint parts, where any numeric
#    field may be a STRING arithmetic expression over the param names...]}
# This is the self-improvement loop: a verified build -> a reusable module,
# with no server restart needed (the directory is re-scanned every call).
# ---------------------------------------------------------------------------

_MODULES_DIR = KNOWLEDGE_DIR / "modules"


class _ExprSyntaxError(Exception):
    pass


_EXPR_TOKEN_RE = re.compile(r"(\d+)|([A-Za-z_][A-Za-z0-9_]*)|(//|[+\-*/()])")


def _tokenize_expr(expr: str) -> list[tuple[str, Any]]:
    tokens: list[tuple[str, Any]] = []
    pos = 0
    length = len(expr)
    while pos < length:
        ch = expr[pos]
        if ch.isspace():
            pos += 1
            continue
        match = _EXPR_TOKEN_RE.match(expr, pos)
        if not match or match.start() != pos:
            raise _ExprSyntaxError(f"unexpected character '{ch}' at {pos}")
        pos = match.end()
        if match.group(1) is not None:
            tokens.append(("NUM", int(match.group(1))))
        elif match.group(2) is not None:
            tokens.append(("NAME", match.group(2)))
        else:
            tokens.append(("OP", match.group(3)))
    return tokens


class _ExprParser:
    """Recursive-descent parser/evaluator for `+ - * / // ( )` over int/float
    literals and whitelisted parameter names. No eval()/exec() anywhere.
    """

    def __init__(self, tokens: list[tuple[str, Any]], params: dict[str, Any]) -> None:
        self.tokens = tokens
        self.pos = 0
        self.params = params

    def _peek(self) -> tuple[str, Any] | None:
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def _advance(self) -> tuple[str, Any] | None:
        tok = self._peek()
        self.pos += 1
        return tok

    def parse(self) -> Any:
        value = self._expr()
        if self._peek() is not None:
            raise _ExprSyntaxError("unexpected trailing tokens")
        return value

    def _expr(self) -> Any:
        value = self._term()
        while True:
            tok = self._peek()
            if tok and tok[0] == "OP" and tok[1] in ("+", "-"):
                self._advance()
                rhs = self._term()
                value = value + rhs if tok[1] == "+" else value - rhs
            else:
                return value

    def _term(self) -> Any:
        value = self._factor()
        while True:
            tok = self._peek()
            if tok and tok[0] == "OP" and tok[1] in ("*", "/", "//"):
                self._advance()
                rhs = self._factor()
                if tok[1] == "*":
                    value = value * rhs
                elif rhs == 0:
                    raise _ExprSyntaxError("division by zero")
                elif tok[1] == "//":
                    value = value // rhs
                else:
                    value = value / rhs
            else:
                return value

    def _factor(self) -> Any:
        tok = self._advance()
        if tok is None:
            raise _ExprSyntaxError("unexpected end of expression")
        kind, val = tok
        if kind == "NUM":
            return val
        if kind == "NAME":
            if val not in self.params:
                raise _ExprSyntaxError(f"unknown name '{val}'")
            return self.params[val]
        if kind == "OP" and val == "(":
            inner = self._expr()
            closing = self._advance()
            if closing != ("OP", ")"):
                raise _ExprSyntaxError("missing closing parenthesis")
            return inner
        if kind == "OP" and val == "-":
            return -self._factor()
        raise _ExprSyntaxError(f"unexpected token {tok}")


def safe_eval_expr(expr: str, params: dict[str, Any]) -> int | float | None:
    """Evaluate a tiny arithmetic expression: ints, `+ - * / //`, parentheses,
    and identifiers resolved ONLY from numeric entries of `params`. No
    eval()/exec()/compile(). Returns None (never raises) when `expr` is not a
    valid expression of this form -- callers should then leave the string
    untouched, since it is probably something else entirely (an anchor
    reference like "id.right+2", an element name, a hex colour, ...).
    """
    if not isinstance(expr, str) or not expr.strip():
        return None
    numeric_params = {k: v for k, v in params.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
    try:
        tokens = _tokenize_expr(expr)
        if not tokens:
            return None
        value = _ExprParser(tokens, numeric_params).parse()
    except (_ExprSyntaxError, ZeroDivisionError):
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def _expand_expr_value(value: Any, params: dict[str, Any]) -> Any:
    """Recursively substitute string expressions with their evaluated numbers
    throughout a module's `parts` template. Any string that safe_eval_expr
    cannot parse as pure arithmetic over `params` is left exactly as-is (this
    is what lets element names, ctype values, and anchor references like
    "core.right+2" pass through untouched with no special-casing needed).
    """
    if isinstance(value, str):
        result = safe_eval_expr(value, params)
        if result is None:
            return value
        return int(round(result)) if isinstance(result, float) else result
    if isinstance(value, list):
        return [_expand_expr_value(item, params) for item in value]
    if isinstance(value, dict):
        return {key: _expand_expr_value(item, params) for key, item in value.items()}
    return value


def _expand_json_module(module_def: dict[str, Any], given_params: dict[str, Any]) -> list[dict[str, Any]]:
    defaults = module_def.get("params") if isinstance(module_def.get("params"), dict) else {}
    merged: dict[str, Any] = dict(defaults)
    if isinstance(given_params, dict):
        merged.update(given_params)
    parts_template = module_def.get("parts")
    if not isinstance(parts_template, list):
        raise ValueError(f"module '{module_def.get('name')}' has no parts array")
    return [_expand_expr_value(part, merged) for part in parts_template]


def _json_module_registry() -> dict[str, dict[str, Any]]:
    """Scan knowledge/modules/*.json fresh on every call -- ANALYST (or
    blueprint_module_save) may add files while this process is running, and
    there is no invalidation signal other than "just re-glob it" for a
    handful of small JSON files.
    """
    registry: dict[str, dict[str, Any]] = {}
    if not _MODULES_DIR.is_dir():
        return registry
    for path in sorted(_MODULES_DIR.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(data, dict):
            continue
        name = data.get("name")
        if not isinstance(name, str) or not name.strip() or not isinstance(data.get("parts"), list):
            continue
        registry[name.strip()] = {**data, "_file": path.name}
    return registry


def _resolve_module(name: str) -> dict[str, Any] | None:
    """Uniform lookup across builtin MODULES and the JSON registry, returning
    {"fn": callable(params)->parts, "params": {...}, "why": str, "source": ...}.
    """
    builtin = MODULES.get(name)
    if builtin is not None:
        return {**builtin, "source": "builtin"}
    module_def = _json_module_registry().get(name)
    if module_def is None:
        return None

    def _fn(params: dict[str, Any], _def: dict[str, Any] = module_def) -> list[dict[str, Any]]:
        return _expand_json_module(_def, params if isinstance(params, dict) else {})

    return {
        "fn": _fn,
        "params": module_def.get("params", {}) if isinstance(module_def.get("params"), dict) else {},
        "why": module_def.get("why") or module_def.get("description", ""),
        "source": "registry",
        "anchors_note": module_def.get("anchors_note"),
    }


def _all_module_names() -> list[str]:
    names = set(MODULES)
    names.update(_json_module_registry())
    return sorted(names)


# ---------------------------------------------------------------------------
# Compiler
# ---------------------------------------------------------------------------

OP_KEYS = ("box", "line", "circle", "wall", "set", "erase", "module", "group", "repeat", "stamp")


def _op_of(part: dict[str, Any], path: str) -> str:
    present = [k for k in OP_KEYS if k in part]
    if len(present) != 1:
        raise CompileError(
            path, f"a part needs exactly one operation key, found {present or 'none'}",
            "use one of: " + ", ".join(OP_KEYS),
        )
    return present[0]


class Compiler:
    def __init__(self) -> None:
        self.prims: list[dict[str, Any]] = []
        self.ids: dict[str, Anchors] = {}
        self.warnings: list[str] = []
        self.errors: list[CompileError] = []

    # -- helpers -----------------------------------------------------------
    def _emit(self, prim: dict[str, Any], path: str) -> None:
        if len(self.prims) >= MAX_PRIMS:
            raise CompileError(path, f"blueprint expands to more than {MAX_PRIMS} primitives", "split it into several blueprints")
        prim["path"] = path
        self.prims.append(prim)

    def _register(self, part: dict[str, Any], x1: int, y1: int, x2: int, y2: int, path: str) -> None:
        pid = part.get("id")
        if pid is None:
            return
        if not isinstance(pid, str) or not pid or "." in pid:
            raise CompileError(path, "id must be a short string without dots")
        if pid in self.ids:
            raise CompileError(path, f"duplicate id '{pid}'")
        self.ids[pid] = _anchors(x1, y1, x2, y2)

    # -- main --------------------------------------------------------------
    def compile_parts(self, parts: Any, ox: int, oy: int, path: str, depth: int) -> tuple[int, int, int, int] | None:
        if depth > MAX_EXPANSION_DEPTH:
            raise CompileError(path, "modules nested too deep")
        if not isinstance(parts, list):
            raise CompileError(path, "parts must be an array of part objects")
        if depth == 0 and len(parts) > MAX_PARTS:
            raise CompileError(path, f"too many parts ({len(parts)} > {MAX_PARTS})")
        bounds: list[int] | None = None
        for index, part in enumerate(parts):
            ppath = f"{path}[{index}]"
            try:
                box = self.compile_part(part, ox, oy, ppath, depth)
            except CompileError as exc:
                self.errors.append(exc)
                continue
            if box:
                if bounds is None:
                    bounds = list(box)
                else:
                    bounds = [min(bounds[0], box[0]), min(bounds[1], box[1]), max(bounds[2], box[2]), max(bounds[3], box[3])]
        return tuple(bounds) if bounds else None  # type: ignore[return-value]

    def compile_part(self, part: Any, ox: int, oy: int, path: str, depth: int) -> tuple[int, int, int, int] | None:
        if not isinstance(part, dict):
            raise CompileError(path, "part must be an object")
        op = _op_of(part, path)

        if op in ("box", "wall", "set", "erase"):
            x, y = _pair(part.get("at"), self.ids, path, "at", ox, oy)
            w, h = _size(part.get("size", [1, 1]), path)
            x2, y2 = x + w - 1, y + h - 1
            _check_bounds(op, x, y, x2, y2, path)
            if op == "box":
                element, hint = resolve_element(part["box"])
                if element is None:
                    raise CompileError(f"{path}.box", hint or "bad element")
                hollow = part.get("hollow")
                if hollow:
                    t = int(hollow)
                    if t * 2 >= min(w, h):
                        raise CompileError(path, "hollow thickness too large for the box size")
                    self._emit({"kind": "box", "element": element, "x1": x, "y1": y, "x2": x2, "y2": y + t - 1}, path)
                    self._emit({"kind": "box", "element": element, "x1": x, "y1": y2 - t + 1, "x2": x2, "y2": y2}, path)
                    self._emit({"kind": "box", "element": element, "x1": x, "y1": y, "x2": x + t - 1, "y2": y2}, path)
                    self._emit({"kind": "box", "element": element, "x1": x2 - t + 1, "y1": y, "x2": x2, "y2": y2}, path)
                else:
                    # TPT never places over an occupied pixel, so a box replaces by default
                    # (lesson: "jacket then fill" silently loses the fill). "replace": false layers instead.
                    if element != "NONE" and part.get("replace", True):
                        self._emit({"kind": "box", "element": "NONE", "x1": x, "y1": y, "x2": x2, "y2": y2}, path)
                    self._emit({"kind": "box", "element": element, "x1": x, "y1": y, "x2": x2, "y2": y2}, path)
                props = part.get("props")
                if isinstance(props, dict) and props:
                    self._emit({"kind": "set", "x1": x, "y1": y, "x2": x2, "y2": y2, "element": element, "props": self._props(props, f"{path}.props")}, path)
            elif op == "wall":
                wall, hint = resolve_wall(part["wall"])
                if wall is None:
                    raise CompileError(f"{path}.wall", hint or "bad wall")
                self._emit({"kind": "wall_box", "wall": wall, "x1": x, "y1": y, "x2": x2, "y2": y2}, path)
            elif op == "erase":
                self._emit({"kind": "box", "element": "NONE", "x1": x, "y1": y, "x2": x2, "y2": y2}, path)
            else:  # set
                props = part["set"]
                if not isinstance(props, dict) or not props:
                    raise CompileError(f"{path}.set", "set must be an object like {\"tmp\": 3}")
                element = None
                if part.get("element") is not None:
                    element, hint = resolve_element(part["element"])
                    if element is None:
                        raise CompileError(f"{path}.element", hint or "bad element")
                self._emit({"kind": "set", "x1": x, "y1": y, "x2": x2, "y2": y2, "element": element, "props": self._props(props, f"{path}.set")}, path)
            self._register(part, x, y, x2, y2, path)
            return x, y, x2, y2

        if op == "line":
            element, hint = resolve_element(part["line"])
            if element is None:
                raise CompileError(f"{path}.line", hint or "bad element")
            fx, fy = _pair(part.get("from"), self.ids, path, "from", ox, oy)
            tx, ty = _pair(part.get("to"), self.ids, path, "to", ox, oy)
            for (px, py) in ((fx, fy), (tx, ty)):
                if not (0 <= px < PIXEL_W and 0 <= py < PIXEL_H):
                    raise CompileError(path, f"line endpoint ({px},{py}) outside canvas")
            self._emit({"kind": "line", "element": element, "x1": fx, "y1": fy, "x2": tx, "y2": ty}, path)
            box = (min(fx, tx), min(fy, ty), max(fx, tx), max(fy, ty))
            self._register(part, *box, path)
            return box

        if op == "circle":
            element, hint = resolve_element(part["circle"])
            if element is None:
                raise CompileError(f"{path}.circle", hint or "bad element")
            cx, cy = _pair(part.get("at"), self.ids, path, "at", ox, oy)
            try:
                r = int(part.get("r", part.get("radius", 4)))
            except (TypeError, ValueError):
                raise CompileError(path, "r must be an integer radius") from None
            if r < 1 or not (r <= cx < PIXEL_W - r and r <= cy < PIXEL_H - r):
                raise CompileError(path, f"circle centre ({cx},{cy}) r={r} outside canvas")
            self._emit({"kind": "circle", "element": element, "cx": cx, "cy": cy, "radius": r}, path)
            box = (cx - r, cy - r, cx + r, cy + r)
            self._register(part, *box, path)
            return box

        if op == "stamp":
            name = part["stamp"]
            if not isinstance(name, str) or not name:
                raise CompileError(path, "stamp must be a stamp id string like \"6a8e21c900\"")
            x, y = _pair(part.get("at", [0, 0]), self.ids, path, "at", ox, oy)
            if not (0 <= x < PIXEL_W and 0 <= y < PIXEL_H):
                raise CompileError(path, f"stamp position ({x},{y}) outside canvas")
            self._emit({"kind": "stamp", "name": name, "x": x, "y": y}, path)
            return None

        if op == "group":
            x, y = _pair(part.get("at", [0, 0]), self.ids, path, "at", ox, oy)
            box = self.compile_parts(part["group"], x, y, f"{path}.group", depth + 1)
            if box:
                self._register(part, *box, path)
            return box

        if op == "repeat":
            try:
                n = int(part["repeat"])
            except (TypeError, ValueError):
                raise CompileError(path, "repeat must be an integer count") from None
            if n < 1 or n > 256:
                raise CompileError(path, "repeat count must be 1..256")
            dx, dy = _pair(part.get("step", [0, 0]), {}, path, "step")
            x, y = _pair(part.get("at", [0, 0]), self.ids, path, "at", ox, oy)
            inner = part.get("part") or part.get("parts")
            if inner is None:
                raise CompileError(path, "repeat needs \"part\" (one part) or \"parts\" (array)")
            inner_list = inner if isinstance(inner, list) else [inner]
            bounds = None
            for i in range(n):
                box = self.compile_parts(inner_list, x + dx * i, y + dy * i, f"{path}.repeat#{i}", depth + 1)
                if box:
                    bounds = box if bounds is None else (min(bounds[0], box[0]), min(bounds[1], box[1]), max(bounds[2], box[2]), max(bounds[3], box[3]))
            if bounds:
                self._register(part, *bounds, path)
            return bounds

        if op == "module":
            name = part["module"]
            modinfo = _resolve_module(name) if isinstance(name, str) else None
            if modinfo is None:
                names = _all_module_names()
                close = difflib.get_close_matches(str(name), names, n=3, cutoff=0.4)
                hint = ("did you mean " + " / ".join(close) + "? " if close else "") + "available: " + ", ".join(names)
                raise CompileError(f"{path}.module", f"unknown module '{name}'", hint)
            params = part.get("params", {})
            if not isinstance(params, dict):
                raise CompileError(f"{path}.params", "params must be an object")
            x, y = _pair(part.get("at", [0, 0]), self.ids, path, "at", ox, oy)
            try:
                expanded = modinfo["fn"](params)
            except (TypeError, ValueError) as exc:
                raise CompileError(f"{path}.params", f"bad params for {name}: {exc}", json.dumps(modinfo["params"])) from None
            box = self.compile_parts(expanded, x, y, f"{path}.module:{name}", depth + 1)
            if box:
                self._register(part, *box, path)
            return box

        raise CompileError(path, f"unsupported operation {op}")

    def _props(self, props: dict[str, Any], path: str) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for key, value in props.items():
            if key == "temp_c":
                try:
                    out["temp"] = float(value) + 273.15
                except (TypeError, ValueError):
                    raise CompileError(path, "temp_c must be a number") from None
            elif key in ("temp",):
                try:
                    out["temp"] = float(value)
                except (TypeError, ValueError):
                    raise CompileError(path, "temp must be a number (Kelvin); use temp_c for Celsius") from None
                if out["temp"] < 0 or out["temp"] > 9999.99 + 273.15:
                    raise CompileError(path, "temp out of range (0..10273 K)")
            elif key == "channel":
                # WIFI / PRTI / PRTO channel is DERIVED from temperature in TPT:
                # channel = floor((temp - 73.15) / 100) + 1, so we set the band's midpoint.
                try:
                    ch = int(value)
                except (TypeError, ValueError):
                    raise CompileError(path, "channel must be an integer 1..100") from None
                if not 1 <= ch <= 100:
                    raise CompileError(path, "channel must be 1..100")
                out["temp"] = 73.15 + 100.0 * (ch - 1) + 50.0
            elif key in ("tmp", "tmp2", "life", "tmp3", "tmp4"):
                try:
                    out[key] = int(value)
                except (TypeError, ValueError):
                    raise CompileError(path, f"{key} must be an integer") from None
            elif key == "ctype":
                element, hint = resolve_element(value)
                if element is None:
                    raise CompileError(f"{path}.ctype", hint or "bad ctype")
                out["ctype"] = element
            elif key == "dcolour" or key == "dcolor":
                try:
                    out["dcolour"] = int(str(value), 0)
                except (TypeError, ValueError):
                    raise CompileError(path, "dcolour must be an integer or 0xAARRGGBB string") from None
            else:
                raise CompileError(path, f"unknown property '{key}'", "allowed: channel tmp tmp2 life ctype temp temp_c dcolour")
        return out


def compile_blueprint(bp: dict[str, Any], features: dict[str, Any] | None = None) -> dict[str, Any]:
    comp = Compiler()
    # pre-seed anchors from live canvas features (find_features) so parts can reference hand-drawn objects
    if isinstance(features, dict):
        for fid, f in features.items():
            a = f.get("anchors") if isinstance(f, dict) else None
            if isinstance(a, dict) and all(k in a for k in ("left", "right", "top", "bottom")):
                comp.ids[str(fid)] = _anchors(int(a["left"]), int(a["top"]), int(a["right"]), int(a["bottom"]))
    errors: list[dict[str, Any]] = []
    if not isinstance(bp, dict):
        return {"ok": False, "errors": [{"path": "blueprint", "problem": "blueprint must be an object"}]}
    try:
        ox, oy = _pair(bp.get("origin", [0, 0]), {}, "blueprint.origin", "origin")
    except CompileError as exc:
        return {"ok": False, "errors": [exc.as_dict()]}
    parts = bp.get("parts")
    if parts is None:
        return {"ok": False, "errors": [{"path": "blueprint.parts", "problem": "parts array is required", "fix": "\"parts\": [{\"box\": \"BRCK\", \"at\": [0,0], \"size\": [10,10]}]"}]}
    bounds = None
    try:
        bounds = comp.compile_parts(parts, ox, oy, "parts", 0)
    except CompileError as exc:
        comp.errors.append(exc)
    errors.extend(e.as_dict() for e in comp.errors)

    steps: list[dict[str, int]] = []
    then = bp.get("then", [])
    if not isinstance(then, list):
        errors.append({"path": "blueprint.then", "problem": "then must be an array", "fix": "\"then\": [{\"step\": 60}]"})
    else:
        if len(then) > MAX_STEPS:
            errors.append({"path": "blueprint.then", "problem": f"more than {MAX_STEPS} steps"})
        for index, action in enumerate(then):
            if isinstance(action, dict) and "step" in action:
                try:
                    n = int(action["step"])
                except (TypeError, ValueError):
                    errors.append({"path": f"then[{index}]", "problem": "step must be an integer"})
                    continue
                if not 1 <= n <= MAX_STEP_FRAMES:
                    errors.append({"path": f"then[{index}]", "problem": f"step must be 1..{MAX_STEP_FRAMES}"})
                    continue
                steps.append({"step": n})
            else:
                errors.append({"path": f"then[{index}]", "problem": "only {\"step\": N} actions are supported"})
    counts: dict[str, int] = {}
    for prim in comp.prims:
        counts[prim["kind"]] = counts.get(prim["kind"], 0) + 1
    return {
        "ok": not errors,
        "errors": errors,
        "warnings": comp.warnings,
        "primitives": comp.prims,
        "steps": steps,
        "counts": counts,
        "bounds": {"x1": bounds[0], "y1": bounds[1], "x2": bounds[2], "y2": bounds[3]} if bounds else None,
        "ids": comp.ids,
    }


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

_LUA_SET = r"""
local X1,Y1,X2,Y2 = %d,%d,%d,%d
local FILTER = %s
local PROPS = %s
local function elemId(name)
  if type(name)=="number" then return name end
  local id = elem["DEFAULT_PT_"..name]
  if id then return id end
  for i=0,511 do local ok,n = pcall(elem.property,i,"Name"); if ok and n==name then return i end end
  return nil
end
local ft = nil
if FILTER then ft = elemId(FILTER); if not ft then return {ok=false,error="filter element not found: "..FILTER} end end
if PROPS.ctype and type(PROPS.ctype)=="string" then
  local c = elemId(PROPS.ctype); if not c then return {ok=false,error="ctype element not found: "..PROPS.ctype} end
  PROPS.ctype = c
end
local n = 0
for i in sim.parts() do
  local x,y = sim.partPosition(i)
  if x>=X1 and x<=X2 and y>=Y1 and y<=Y2 and (ft==nil or sim.partProperty(i,"type")==ft) then
    for k,v in pairs(PROPS) do sim.partProperty(i,k,v) end
    n = n + 1
  end
end
return "set:"..n
"""


def _lua_literal(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value)
    if value is None:
        return "nil"
    if isinstance(value, dict):
        return "{" + ",".join(f"[{json.dumps(k)}]={_lua_literal(v)}" for k, v in value.items()) + "}"
    raise TypeError(f"cannot encode {type(value).__name__}")


def _run_prim(client: PowderClient, prim: dict[str, Any]) -> dict[str, Any]:
    kind = prim["kind"]
    if kind == "box":
        return client.place_element(_bridge_element(prim["element"]), x1=prim["x1"], y1=prim["y1"], x2=prim["x2"], y2=prim["y2"])
    if kind == "line":
        return client.place_element_line(_bridge_element(prim["element"]), x1=prim["x1"], y1=prim["y1"], x2=prim["x2"], y2=prim["y2"])
    if kind == "circle":
        return client.place_element(_bridge_element(prim["element"]), x1=prim["cx"], y1=prim["cy"], x2=prim["cx"], y2=prim["cy"], method="circle", radius=prim["radius"])
    if kind == "wall_box":
        return client.place_wall_box(prim["wall"], x1=prim["x1"], y1=prim["y1"], x2=prim["x2"], y2=prim["y2"])
    if kind == "stamp":
        return client.load_stamp(prim["name"], x=prim["x"], y=prim["y"])
    if kind == "set":
        code = _LUA_SET % (
            prim["x1"], prim["y1"], prim["x2"], prim["y2"],
            _lua_literal(prim.get("element")), _lua_literal(prim["props"]),
        )
        result = client.execute_lua(code)
        text = str(result.get("result", "")) if isinstance(result, dict) else ""
        if isinstance(result, dict) and isinstance(result.get("result"), dict) and result["result"].get("ok") is False:
            raise PowderAPIError("executeLua", str(result["result"].get("error")), None)  # type: ignore[arg-type]
        return {"ok": True, "action": "set", "detail": text}
    raise ValueError(f"unsupported primitive {kind}")


def blueprint_build(arguments: dict[str, Any]) -> dict[str, Any]:
    tool = "blueprint_build"
    args = arguments or {}
    bp = args.get("blueprint")
    if isinstance(bp, str):
        try:
            bp = json.loads(bp)
        except json.JSONDecodeError as exc:
            return {"ok": False, "tool": tool, "errors": [{"path": "blueprint", "problem": f"blueprint string is not valid JSON: {exc.msg} at char {exc.pos}"}]}
    feats = args.get("features")
    if args.get("features_auto") or feats is True or feats == "auto":
        try:
            from powder_ext import build_tools as _btl
            ff = _btl.HANDLERS["find_features"]({})
            feats = {f["id"]: f for f in ff.get("features", [])} if ff.get("ok") else None
        except Exception:  # noqa: BLE001
            feats = None
    compiled = compile_blueprint(bp, feats if isinstance(feats, dict) else None)
    name = str(bp.get("name", "blueprint")) if isinstance(bp, dict) else "blueprint"
    dry_run = bool(args.get("dry_run", True))
    preview = [
        {k: v for k, v in prim.items() if k != "props"} | ({"props": prim["props"]} if "props" in prim else {})
        for prim in compiled["primitives"][:64]
    ]
    lint: dict[str, Any] = {"findings": [], "count": 0}
    if compiled["ok"]:
        try:
            from powder_ext.knowledge_tools import lint_compiled, tally_severity  # noqa: WPS433
            findings = lint_compiled(compiled)
            lint = {"findings": findings, "count": len(findings), "counts_by_severity": tally_severity(findings)}
        except Exception as exc:  # noqa: BLE001 -- lint must never block a build
            lint = {"findings": [], "count": 0, "error": f"{type(exc).__name__}: {exc}"}
    else:
        lint["skipped"] = "compile_errors_present"
    base = {
        "ok": compiled["ok"],
        "tool": tool,
        "name": name,
        "dry_run": dry_run,
        "errors": compiled["errors"],
        "warnings": compiled["warnings"],
        "counts": compiled["counts"],
        "primitive_count": len(compiled["primitives"]),
        "bounds": compiled["bounds"],
        "ids": compiled["ids"],
        "steps": compiled["steps"],
        "preview": preview,
        "preview_truncated": len(compiled["primitives"]) > 64,
        "lint": lint,
    }
    if not compiled["ok"]:
        base["hint"] = "fix every entry in errors (each has path + problem + fix) and resend; nothing was drawn"
        return base
    if dry_run:
        base["hint"] = "looks valid; resend with dry_run=false to draw it"
        return base

    client = _get_client()
    cid = resolve_correlation_id()
    results: list[dict[str, Any]] = []
    paused = False
    try:
        if bool(args.get("pause", True)):
            client.execute_lua("tpt.set_pause(1)")
            paused = True
        if bool(bp.get("clear_before", False)):
            client.clear()
        for index, prim in enumerate(compiled["primitives"]):
            try:
                response = _run_prim(client, prim)
                results.append({"index": index, "path": prim["path"], "kind": prim["kind"], "ok": True, "detail": response.get("detail") or response.get("placed")})
            except (PowderAPIError, PowderConnectionError, ValueError, TypeError) as exc:
                results.append({"index": index, "path": prim["path"], "kind": prim["kind"], "ok": False, "error": f"{type(exc).__name__}: {exc}"})
                break
        succeeded = sum(1 for r in results if r["ok"])
        failed = len(results) - succeeded
        step_results: list[dict[str, Any]] = []
        if failed == 0:
            if bool(args.get("unpause_after", False)) and paused:
                client.execute_lua("tpt.set_pause(0)")
                paused = False
            for index, action in enumerate(compiled["steps"]):
                try:
                    client.step(int(action["step"]))
                    step_results.append({"index": index, "ok": True, "frames": action["step"]})
                except (PowderAPIError, PowderConnectionError) as exc:
                    step_results.append({"index": index, "ok": False, "error": f"{type(exc).__name__}: {exc}"})
                    break
        base.update({
            "ok": failed == 0 and all(s["ok"] for s in step_results),
            "succeeded": succeeded,
            "failed": failed,
            "skipped": len(compiled["primitives"]) - len(results),
            "partial_mutation": failed > 0 and succeeded > 0,
            "results": [r for r in results if not r["ok"]] or results[-3:],
            "step_results": step_results,
            "left_paused": paused,
            "correlation_id": cid,
        })
        return base
    except Exception as exc:  # noqa: BLE001
        base.update({"ok": False, "error": f"{type(exc).__name__}: {exc}", "left_paused": paused, "correlation_id": cid})
        return base


# ---------------------------------------------------------------------------
# Schema / reference for the small model's prompt
# ---------------------------------------------------------------------------

EXAMPLE_BLUEPRINT: dict[str, Any] = {
    "name": "mini reactor demo",
    "origin": [200, 150],
    "clear_before": False,
    "parts": [
        {"id": "vessel", "box": "TTAN", "at": [0, 0], "size": [60, 40], "hollow": 3},
        {"box": "water", "at": ["vessel.left+3", "vessel.top+3"], "size": [54, 34]},
        {"id": "heater", "module": "insulated_box", "at": ["vessel.right+4", "vessel.top"],
         "params": {"element": "HEAC", "width": 6, "height": 6, "props": {"temp_c": 800}}},
        {"module": "wifi_node", "at": ["heater.right+2", "heater.top"], "params": {"channel": 7}},
        {"repeat": 4, "at": ["vessel.left", "vessel.bottom+6"], "step": [16, 0],
         "part": {"box": "brick", "at": [0, 0], "size": [12, 4]}},
        {"wall": "air", "at": ["vessel.left-6", "vessel.top-6"], "size": [4, 52]},
    ],
    "then": [{"step": 60}],
}

REFERENCE_TEXT = """POWDER BLUEPRINT v1 -- write ONE JSON object, nothing else.
Canvas is 612x384 pixels, x grows right (0-611), y grows DOWN (0-383). origin shifts every part.
Top level: {"name": str, "origin": [x,y], "clear_before": bool, "parts": [...], "then": [{"step": N}]}
Each part has exactly ONE operation key plus placement keys:
  {"box": ELEMENT, "at": [x,y], "size": [w,h], "hollow": t?, "props": {...}?, "id": str?, "replace": false?}
        -- a box clears its region first (so later boxes can sit inside earlier ones); "replace": false layers on top
  {"line": ELEMENT, "from": [x,y], "to": [x,y]}
  {"circle": ELEMENT, "at": [cx,cy], "r": radius}
  {"wall": WALLTYPE, "at": [x,y], "size": [w,h]}            -- walls block air/particles; use "wall" for pressure boxes
  {"erase": true, "at": [x,y], "size": [w,h]}               -- clear a region
  {"set": {"channel": 3, "ctype": "DEUT", "temp_c": 25, "life": 100}, "at": [x,y], "size": [w,h], "element": ELEMENT?}
  {"module": NAME, "at": [x,y], "params": {...}}            -- expands a proven design (list below)
  {"group": [parts...], "at": [x,y]}                        -- offset a sub-list
  {"repeat": N, "at": [x,y], "step": [dx,dy], "part": {...}}  -- copies
  {"stamp": "6a8e21c900", "at": [x,y]}                      -- load a saved stamp
Coordinates: "at" is the TOP-LEFT corner, size is [width,height] in pixels. Any coordinate may be a
reference to an earlier part's id: "vessel.right+2", "vessel.bottom", "core.cx" (anchors: left right top bottom cx cy).
Element names: 4-letter catalog ids (BRCK METL WATR DSTW DMND TTAN INSL WIFI PRTI PRTO CLNE DEUT PLUT PUMP VACU ...)
or plain words (water, brick, metal, glass, insulation, diamond...). Unknown names come back with a did-you-mean.
Properties (via "props" or "set"): channel (WIFI/PRTI/PRTO channel 1-100; it is really a temperature band, so the
compiler sets temp for you -- never set tmp for a channel), ctype (what CLNE/CRAY/PIPE carries),
temp (Kelvin) or temp_c (Celsius), life, tmp2, dcolour.
Rules that save you from failure (from the build-lessons store):
  * dry_run is ON by default: first call returns errors/preview, then resend with dry_run=false.
  * WIFI/PRTI/PRTO channel N means temperature 73+100*(N-1) K, so channel 30 is a 3000 K heat source:
    use low channels (1-8) near anything flammable and always INSL-jacket them (wifi_node does this).
  * Use DSTW (distilled) not WATR near wires; WATR conducts sparks.
  * Cryogenic liquids spawn at room temperature: add "props": {"temp_c": -200}.
  * PSCN must touch LCRY directly to light it. NSCN will not pass a spark to PSCN.
  * A conductive floor shorts the whole build; break long METL runs with INSL.
  * Pressure boxes need WALL (walls), not particles, as the boundary.
  * Keep it small first: a valid 10-part blueprint beats an invalid 100-part one.
"""


def blueprint_schema(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    modules = {
        name: {"params": info["params"], "why": info["why"], "source": "builtin"}
        for name, info in MODULES.items()
    }
    for name, module_def in _json_module_registry().items():
        modules[name] = {
            "params": module_def.get("params", {}),
            "why": module_def.get("why") or module_def.get("description", ""),
            "source": "registry",
            "anchors_note": module_def.get("anchors_note"),
            "file": module_def.get("_file"),
        }
    out: dict[str, Any] = {
        "ok": True,
        "tool": "blueprint_schema",
        "version": 1,
        "reference": REFERENCE_TEXT,
        "modules": modules,
        "example": EXAMPLE_BLUEPRINT,
        "limits": {"parts": MAX_PARTS, "primitives": MAX_PRIMS, "steps": MAX_STEPS, "frames_per_step": MAX_STEP_FRAMES},
    }
    if args.get("include_aliases"):
        out["element_aliases"] = ELEMENT_ALIASES
        out["wall_aliases"] = WALL_ALIASES
    if args.get("include_catalog"):
        cats = _catalogs()
        out["elements"] = sorted(cats["elements"])
        out["walls"] = sorted(cats["walls"])
    if args.get("check_example"):
        out["example_compiles"] = compile_blueprint(EXAMPLE_BLUEPRINT)["ok"]
    return out


# ---------------------------------------------------------------------------
# blueprint_module_save -- the self-improvement loop: verified build -> module.
# Mutating but file-only: never touches the live sim, only knowledge/modules/.
# ---------------------------------------------------------------------------

_MODULE_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,40}$")


def blueprint_module_save(arguments: dict[str, Any]) -> dict[str, Any]:
    tool = "blueprint_module_save"
    args = arguments or {}
    name = args.get("name")
    description = " ".join(str(args.get("description") or "").split())
    why = " ".join(str(args.get("why") or "").split())
    params = args.get("params")
    parts = args.get("parts")
    anchors_note = args.get("anchors_note")

    errors: list[dict[str, Any]] = []
    if not isinstance(name, str) or not _MODULE_NAME_RE.match(name):
        errors.append({"path": "name", "problem": "name must be lowercase snake_case, 2-41 chars, starting with a letter", "fix": "example: \"cold_trap\""})
    elif name in MODULES:
        errors.append({"path": "name", "problem": f"'{name}' is a builtin module name and cannot be overridden", "fix": "pick a different name"})
    if not description:
        errors.append({"path": "description", "problem": "description is required"})
    if not why:
        errors.append({"path": "why", "problem": "why is required -- what lesson or verified build justifies this module?"})
    if params is None:
        params = {}
    if not isinstance(params, dict):
        errors.append({"path": "params", "problem": "params must be an object of {name: default}"})
        params = {}
    if not isinstance(parts, list) or not parts:
        errors.append({"path": "parts", "problem": "parts must be a non-empty array of blueprint parts"})
    if errors:
        return {"ok": False, "tool": tool, "errors": errors}

    module_def: dict[str, Any] = {"name": name, "description": description, "why": why, "params": params, "parts": parts}
    near: list = []
    if isinstance(anchors_note, str) and anchors_note.strip():
        module_def["anchors_note"] = anchors_note.strip()

    try:
        expanded = _expand_json_module(module_def, {})
    except (ValueError, TypeError) as exc:
        return {"ok": False, "tool": tool, "errors": [{"path": "parts", "problem": f"could not expand parts with default params: {exc}"}]}

    # duplicate gate (skill-library literature: near-duplicate accumulation): refuse an exact geometric
    # duplicate of an existing registry module unless force=true; report near-duplicates (same element multiset).
    def _sig(parts_list: list) -> tuple:
        return tuple(sorted(json.dumps(p_, sort_keys=True) for p_ in parts_list))
    def _multiset(parts_list: list) -> tuple:
        return tuple(sorted(str(p_.get("box") or p_.get("line") or p_.get("circle") or p_.get("module") or "wall").upper() for p_ in parts_list if isinstance(p_, dict)))
    my_sig, my_ms = _sig(expanded), _multiset(expanded)
    dupes, near = [], []
    for other_name, other in _json_module_registry().items():
        if other_name == name:
            continue
        try:
            other_parts = _expand_json_module(other, dict(other.get("params", {})))
        except Exception:  # noqa: BLE001
            continue
        if _sig(other_parts) == my_sig:
            dupes.append(other_name)
        elif _multiset(other_parts) == my_ms:
            near.append(other_name)
    if dupes and not args.get("force"):
        return {"ok": False, "tool": tool, "errors": [{"path": "parts", "problem": f"exact duplicate of existing module(s): {dupes}", "fix": "use the existing module, or pass force=true with a why that explains the difference"}], "near_duplicates": near}
    dry_bp = {"name": f"module-dry-run:{name}", "origin": [0, 0], "parts": expanded}
    compiled = compile_blueprint(dry_bp)
    if not compiled["ok"]:
        return {
            "ok": False, "tool": tool,
            "errors": compiled["errors"],
            "hint": "the module's parts do not compile cleanly with its own default params; fix and resend (nothing was written)",
        }

    _MODULES_DIR.mkdir(parents=True, exist_ok=True)
    file_path = _MODULES_DIR / f"{name}.json"
    overwritten = file_path.is_file()
    file_path.write_text(json.dumps(module_def, indent=2, sort_keys=True), encoding="utf-8")

    return {
        "ok": True,
        "tool": tool,
        "name": name,
        "overwritten": overwritten,
        "path": str(file_path),
        "primitive_count": len(compiled["primitives"]),
        "bounds": compiled["bounds"],
        "hint": f'module "{name}" is now usable as {{"module": "{name}", "at": [x,y], "params": {{...}}}} and appears in blueprint_schema',
    }


# ---------------------------------------------------------------------------
# HANDLERS registry (same guard pattern as admin_tools)
# ---------------------------------------------------------------------------

_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "blueprint_build": blueprint_build,
    "blueprint_schema": blueprint_schema,
    "blueprint_module_save": blueprint_module_save,
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
