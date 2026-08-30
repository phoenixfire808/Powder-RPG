#!/usr/bin/env python3
"""
Powder Toy MCP Server
Wraps PowderClient for project control, health, generic action, and typed sim tools.
Run as stdio MCP server.
"""

import ast
import asyncio
import inspect
import json
import math
import os
import psutil
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, TypedDict

# Ensure powder_bridge is importable
sys.path.insert(0, str(Path(__file__).parent))

REPO_ROOT = Path(__file__).resolve().parent
TPT_BUILD_DIR = REPO_ROOT / "build"

from powder_bridge.client import (
    PowderClient,
    PowderAPIError,
    PowderConnectionError,
)
from powder_bridge.logging import (
    LOG_PATH,
    bind_correlation_id,
    current_correlation_id,
    emit,
    log_status,
    new_correlation_id,
    read_events,
    strip_secrets,
    reset_correlation_id,
    summarize_response,
)

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

server = Server("powder-toy-mcp")

# Global client (lazy)
_client: PowderClient | None = None

def get_client() -> PowderClient:
    global _client
    if _client is None:
        _client = PowderClient(host="127.0.0.1", port=9876, timeout=10.0)
def get_client_for(host: str, port: int, token: str, timeout: float = 10.0) -> PowderClient:
    """Construct an ad-hoc PowderClient (bypasses the singleton). Used for cross-bridge calls."""
    return PowderClient(host=host, port=port, token=token, timeout=timeout)
ALLOWED_GENERIC_ACTIONS = {
    "getField",
    "listElements",
    "getSimulationState",
}
PIXEL_XRES = 612
PIXEL_YRES = 384
CELL_XCELLS = 153
CELL_YCELLS = 96
SPATIAL_MAX_REGION_AREA = 12_288
SPATIAL_MAX_SAMPLES = 4_096
SPATIAL_MAX_PARTICLES = 256
SPATIAL_MAX_PARTICLE_IDS = 256
SPATIAL_MAX_RESPONSE_BYTES = 262_144
SPATIAL_MAX_STRIDE = 128
PARTS_INVENTORY_MAX_LIMIT = 256
PARTS_INVENTORY_MAX_SCAN = 4_096
PARTS_INVENTORY_MAX_SLOTS = 235_008
PARTS_INVENTORY_RECORD_FIELDS = ("id", "type", "x", "y", "temp", "life", "vx", "vy")
SPATIAL_AVAILABLE_FIELDS = ("temp", "temperature", "pressure")
SPATIAL_UNSUPPORTED_FIELDS = (
    "velocity_x",
    "velocity_y",
    "fan_velocity_x",
    "fan_velocity_y",
)


DEFAULT_HOUSE_MATERIALS = {
    "foundation": "BRCK",
    "walls": "STNE",
    "frame": "WOOD",
    "roof": "BRCK",
    "glass": "GLAS",
    "smoke": "SMKE",
}


def _house_components(
    x: int,
    y: int,
    width: int,
    height: int,
    materials: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    """Build a screenshot-readable cottage from non-overlapping material slabs."""
    palette = dict(DEFAULT_HOUSE_MATERIALS)
    if materials:
        palette.update({str(key): value for key, value in materials.items()})

    def sx(value: int) -> int:
        return x + int(round(value * width / 260))

    def sy(value: int) -> int:
        return y + int(round(value * height / 166))

    def box(element: str, x1: int, y1: int, x2: int, y2: int) -> dict[str, Any]:
        return {"kind": "box", "element": element, "x1": sx(x1), "y1": sy(y1), "x2": sx(x2), "y2": sy(y2)}

    components: list[dict[str, Any]] = [
        box(palette["foundation"], -12, 166, 272, 184),
        box(palette["walls"], 0, 0, 260, 53),
        box(palette["walls"], 0, 54, 31, 165),
        box(palette["walls"], 84, 54, 107, 165),
        box(palette["walls"], 153, 54, 175, 165),
        box(palette["walls"], 228, 54, 260, 165),
        box(palette["walls"], 32, 110, 83, 165),
        box(palette["walls"], 176, 110, 227, 165),
    ]

    # Two framed windows: frame first, then the contrasting glass pane.
    for left in (32, 176):
        right = left + 51
        top, bottom = 54, 109
        inner = 6
        components.extend(
            [
                box(palette["frame"], left, top, right, top + inner - 1),
                box(palette["frame"], left, bottom - inner + 1, right, bottom),
                box(palette["frame"], left, top + inner, left + inner - 1, bottom - inner),
                box(palette["frame"], right - inner + 1, top + inner, right, bottom - inner),
                box(palette["glass"], left + inner, top + inner, right - inner, bottom - inner),
            ]
        )

    components.extend(
        [
            box(palette["frame"], 108, 86, 152, 165),
            box(palette["roof"], 198, -60, 218, -22),
        ]
    )
    center = 130
    for index in range(9):
        half_width = 16 + 18 * index
        top = -72 + 8 * index
        components.append(box(palette["roof"], center - half_width, top, center + half_width, top + 7))

    for cx, cy, radius in ((208, -76, 5), (221, -93, 7), (206, -112, 9)):
        components.append(
            {
                "kind": "circle",
                "element": palette["smoke"],
                "cx": sx(cx),
                "cy": sy(cy),
                "radius": max(2, int(round(radius * width / 260))),
            }
        )
    return components


def _validate_components(components: list[dict[str, Any]]) -> list[str]:
    material_catalog = _load_material_catalog()
    native_catalog = _load_native_catalog()
    if not material_catalog.get("ok") or not native_catalog.get("ok"):
        return ["material or native catalog unavailable"]
    allowed_materials = set()
    for material in material_catalog.get("materials", []):
        for key in ("identifier", "lua_short", "lua_default", "name"):
            if material.get(key):
                allowed_materials.add(str(material[key]).upper())
    allowed_walls = set()
    for wall in native_catalog.get("groups", {}).get("walls", []):
        allowed_walls.update({str(wall.get("name", "")).upper(), str(wall.get("identifier", "")).upper()})
    allowed_tools = set()
    for tool in native_catalog.get("groups", {}).get("tools", []):
        allowed_tools.update({str(tool.get("name", "")).upper(), str(tool.get("identifier", "")).upper()})

    errors: list[str] = []
    for index, component in enumerate(components):
        if not isinstance(component, dict):
            errors.append(f"component {index}: must be an object")
            continue
        kind = component.get("kind")
        if kind in {"box", "circle", "line"}:
            element = component.get("element")
            if not isinstance(element, str):
                errors.append(f"component {index}: element must be a catalog identifier string")
            elif element.upper() not in allowed_materials:
                errors.append(f"component {index}: unknown material {element}")
        elif kind in {"wall_box", "wall_line"}:
            wall = component.get("wall")
            if not isinstance(wall, str) or wall.upper() not in allowed_walls:
                errors.append(f"component {index}: unknown wall {wall}")
        elif kind == "tool_box":
            tool = component.get("tool")
            if not isinstance(tool, str) or tool.upper() not in allowed_tools:
                errors.append(f"component {index}: unknown native tool {tool}")
            try:
                strength = float(component.get("strength", 1.0))
                brush = int(component.get("brush", 0))
                rx = int(component.get("rx", 0))
                ry = int(component.get("ry", 0))
                if not math.isfinite(strength) or not 0.0 <= strength <= 10.0:
                    errors.append(f"component {index}: strength must be finite and between 0 and 10")
                if not 0 <= brush <= 2:
                    errors.append(f"component {index}: brush must be 0, 1, or 2")
                if not 0 <= rx <= 100 or not 0 <= ry <= 100:
                    errors.append(f"component {index}: brush radii must be between 0 and 100")
            except (TypeError, ValueError):
                errors.append(f"component {index}: malformed tool parameters")
        else:
            errors.append(f"component {index}: unsupported kind {kind}")
        try:
            if kind == "circle":
                cx, cy, radius = int(component["cx"]), int(component["cy"]), int(component["radius"])
                if radius < 1 or not (radius <= cx < 612 - radius and radius <= cy < 384 - radius):
                    errors.append(f"component {index}: circle outside pixel bounds")
            else:
                x1, y1 = int(component["x1"]), int(component["y1"])
                x2, y2 = int(component["x2"]), int(component["y2"])
                if kind in {"line", "wall_line"}:
                    in_bounds = all(0 <= value < limit for value, limit in ((x1, 612), (x2, 612), (y1, 384), (y2, 384)))
                    if not in_bounds:
                        errors.append(f"component {index}: line endpoint outside pixel bounds")
                elif not (0 <= x1 <= x2 < 612 and 0 <= y1 <= y2 < 384):
                    errors.append(f"component {index}: box outside pixel bounds")
        except (KeyError, TypeError, ValueError):
            errors.append(f"component {index}: malformed {kind} coordinates")
    return errors


def _normalize_components(components: list[dict[str, Any]]) -> list[dict[str, Any]]:
    normalized_components: list[dict[str, Any]] = []
    for component in components:
        normalized = dict(component)
        if normalized["kind"] == "circle":
            normalized.update(
                cx=int(normalized["cx"]),
                cy=int(normalized["cy"]),
                radius=int(normalized["radius"]),
            )
        else:
            normalized.update(
                x1=int(normalized["x1"]),
                y1=int(normalized["y1"]),
                x2=int(normalized["x2"]),
                y2=int(normalized["y2"]),
            )
        if normalized["kind"] == "tool_box":
            normalized.update(
                strength=float(normalized.get("strength", 1.0)),
                brush=int(normalized.get("brush", 0)),
                rx=int(normalized.get("rx", 0)),
                ry=int(normalized.get("ry", 0)),
            )
        normalized_components.append(normalized)
    return normalized_components


def _draw_components(
    client: PowderClient,
    name: str,
    components: list[dict[str, Any]],
    clear_before: bool,
) -> dict[str, Any]:
    if len(components) > 256:
        return {"ok": False, "project": name, "error": "component limit exceeded", "limit": 256}
    validation_errors = _validate_components(components)
    if validation_errors:
        return {"ok": False, "project": name, "error": "plan validation failed", "validation_errors": validation_errors}
    components = _normalize_components(components)
    if clear_before:
        client.clear()
    results: list[dict[str, Any]] = []
    for index, component in enumerate(components):
        try:
            kind = component.get("kind")
            if kind == "box":
                response = client.place_element(
                    component["element"],
                    x1=int(component["x1"]),
                    y1=int(component["y1"]),
                    x2=int(component["x2"]),
                    y2=int(component["y2"]),
                )
            elif kind == "line":
                response = client.place_element_line(
                    component["element"],
                    x1=int(component["x1"]), y1=int(component["y1"]),
                    x2=int(component["x2"]), y2=int(component["y2"]),
                )
            elif kind == "circle":
                response = client.place_circle(
                    component["element"],
                    cx=int(component["cx"]),
                    cy=int(component["cy"]),
                    radius=int(component["radius"]),
                )
            elif kind == "wall_box":
                response = client.place_wall_box(
                    component["wall"],
                    x1=int(component["x1"]),
                    y1=int(component["y1"]),
                    x2=int(component["x2"]),
                    y2=int(component["y2"]),
                )
            elif kind == "wall_line":
                response = client.place_wall_line(
                    component["wall"],
                    x1=int(component["x1"]), y1=int(component["y1"]),
                    x2=int(component["x2"]), y2=int(component["y2"]),
                )
            elif kind == "tool_box":
                response = client.apply_tool_box(
                    component["tool"],
                    x1=int(component["x1"]),
                    y1=int(component["y1"]),
                    x2=int(component["x2"]),
                    y2=int(component["y2"]),
                    strength=float(component.get("strength", 1.0)),
                    brush=int(component.get("brush", 0)),
                    rx=int(component.get("rx", 0)),
                    ry=int(component.get("ry", 0)),
                )
            else:
                raise ValueError(f"unsupported kind {kind}")
            results.append({"index": index, "ok": True, "response": response})
        except Exception as exc:
            results.append({"index": index, "ok": False, "error": f"{type(exc).__name__}: {exc}"})
            break
    succeeded = sum(1 for result in results if result["ok"])
    failed = len(results) - succeeded
    return {
        "ok": failed == 0,
        "project": name,
        "components": len(results),
        "requested_components": len(components),
        "succeeded": succeeded,
        "failed": failed,
        "skipped": len(components) - len(results),
        "partial_mutation": failed > 0 and (clear_before or succeeded > 0),
        "results": results,
    }


def _load_tool_index(query: str | None = None, module: str | None = None) -> dict[str, Any]:
    index_path = REPO_ROOT / "POWDER_TOY_TOOL_INDEX.json"
    if not index_path.is_file():
        return {"ok": False, "error": "tool index missing"}
    data = json.loads(index_path.read_text(encoding="utf-8"))
    records = data.get("modules", [])
    if module:
        records = [record for record in records if module.lower() in record["file"].lower()]
    if query:
        needle = query.lower()
        filtered = []
        for record in records:
            if needle in record["file"].lower():
                filtered.append(record)
                continue
            functions = [name for name in record["functions"] if needle in name.lower()]
            methods = [name for name in record["userdata_methods"] if needle in name.lower()]
            direct = [
                item
                for item in record.get("direct_registrations", [])
                if needle in item["field"].lower() or needle in item["function"].lower()
            ]
            if functions or methods or direct:
                filtered.append({**record, "functions": functions, "userdata_methods": methods, "direct_registrations": direct})
        records = filtered
    return {
        "ok": True,
        "schema_version": data.get("schema_version"),
        "source_root": data.get("source_root"),
        "module_count": len(records),
        "modules": records,
    }


def _rapid_build(client: PowderClient, plan: dict[str, Any]) -> dict[str, Any]:
    name = str(plan.get("name", "rapid_project"))
    components = plan.get("components", [])
    steps = plan.get("steps", [])
    if not isinstance(components, list) or not isinstance(steps, list):
        return {"ok": False, "error": "plan.components and plan.steps must be arrays"}
    if len(components) > 256 or len(steps) > 32:
        return {"ok": False, "error": "plan limits exceeded", "component_limit": 256, "step_limit": 32}
    step_errors = []
    normalized_steps: list[dict[str, int | str]] = []
    for index, action in enumerate(steps):
        try:
            if not isinstance(action, dict) or action.get("op") != "step":
                raise ValueError("only op='step' is supported after drawing")
            count = int(action.get("n", 1))
            if count < 1 or count > 1000:
                raise ValueError("step n must be between 1 and 1000")
            normalized_steps.append({"op": "step", "n": count})
        except (TypeError, ValueError, KeyError) as exc:
            step_errors.append(f"step {index}: {exc}")
    if step_errors:
        return {"ok": False, "project": name, "error": "plan validation failed", "step_errors": step_errors}
    component_errors = _validate_components(components)
    if component_errors:
        return {"ok": False, "project": name, "error": "plan validation failed", "validation_errors": component_errors, "steps": []}
    normalized_components = _normalize_components(components)
    if plan.get("dry_run"):
        return {
            "ok": True,
            "dry_run": True,
            "project": name,
            "components": normalized_components,
            "steps": [{"index": index, **action} for index, action in enumerate(normalized_steps)],
        }
    result = _draw_components(client, name, normalized_components, bool(plan.get("clear_before", False)))
    if not result.get("ok"):
        result["steps"] = []
        return result
    action_results: list[dict[str, Any]] = []
    for index, action in enumerate(normalized_steps):
        try:
            action_results.append({"index": index, "ok": True, "response": client.step(int(action["n"]))})
        except Exception as exc:
            action_results.append({"index": index, "ok": False, "error": f"{type(exc).__name__}: {exc}"})
            break
    result["steps"] = action_results
    result["ok"] = bool(result["ok"]) and all(action["ok"] for action in action_results)
    return result


def _load_material_catalog(query: str | None = None) -> dict[str, Any]:
    catalog_path = REPO_ROOT / "POWDER_TOY_MATERIAL_INDEX.json"
    if not catalog_path.is_file():
        return {"ok": False, "error": "material catalog missing"}
    data = json.loads(catalog_path.read_text(encoding="utf-8"))
    materials = data.get("materials", [])
    if query:
        needle = query.lower()
        searchable = ("identifier", "lua_short", "lua_default", "name", "description", "properties", "menu_section")
        materials = [
            material
            for material in materials
            if any(needle in str(material.get(key, "")).lower() for key in searchable)
        ]
    return {
        "ok": True,
        "source_root": data.get("source_root"),
        "count": len(materials),
        "materials": materials,
    }
def _load_native_catalog(query: str | None = None, kind: str | None = None) -> dict[str, Any]:
    catalog_path = REPO_ROOT / "POWDER_TOY_NATIVE_CATALOG.json"
    if not catalog_path.is_file():
        return {"ok": False, "error": "native catalog missing"}
    data = json.loads(catalog_path.read_text(encoding="utf-8"))
    groups = {
        "tools": data.get("native_tools", []),
        "walls": data.get("walls", []),
        "constants": data.get("constants", []),
    }
    if kind:
        groups = {kind: groups.get(kind, [])} if kind in groups else {}
    if query:
        needle = query.lower()
        groups = {
            group: [item for item in items if needle in json.dumps(item).lower()]
            for group, items in groups.items()
        }
    return {"ok": True, "counts": {group: len(items) for group, items in groups.items()}, "groups": groups}
def _spatial_bounds(domain: str) -> dict[str, dict[str, int]]:
    if domain == "pixel":
        x_size, y_size = PIXEL_XRES, PIXEL_YRES
    else:
        x_size, y_size = CELL_XCELLS, CELL_YCELLS
    return {
        "x": {"min": 0, "max": x_size - 1, "max_exclusive": x_size, "size": x_size},
        "y": {"min": 0, "max": y_size - 1, "max_exclusive": y_size, "size": y_size},
    }


def _strict_spatial_int(value: Any, name: str) -> int:
    if type(value) is not int:
        raise ValueError(f"{name} must be an integer")
    return value


def _spatial_region(arguments: dict[str, Any]) -> tuple[str, dict[str, int]]:
    space = arguments.get("space")
    if space not in {"pixel", "cell"}:
        raise ValueError("space must be exactly pixel or cell")
    bounds = _spatial_bounds(space)
    rectangle_keys = ("x1", "y1", "x2", "y2")
    has_point = "x" in arguments or "y" in arguments
    has_rectangle = any(key in arguments for key in rectangle_keys)
    if has_point and has_rectangle:
        raise ValueError("provide x and y or x1, y1, x2, y2, not both")
    if has_point:
        if "x" not in arguments or "y" not in arguments:
            raise ValueError("x and y are required together")
        x1 = x2 = _strict_spatial_int(arguments["x"], "x")
        y1 = y2 = _strict_spatial_int(arguments["y"], "y")
    elif has_rectangle:
        if not all(key in arguments for key in rectangle_keys):
            raise ValueError("x1, y1, x2, and y2 are required together")
        x1 = _strict_spatial_int(arguments["x1"], "x1")
        y1 = _strict_spatial_int(arguments["y1"], "y1")
        x2 = _strict_spatial_int(arguments["x2"], "x2")
        y2 = _strict_spatial_int(arguments["y2"], "y2")
    else:
        raise ValueError("a point or inclusive rectangle is required")
    if x1 > x2 or y1 > y2:
        raise ValueError("rectangle lower bounds must not exceed upper bounds")
    if not (bounds["x"]["min"] <= x1 <= x2 <= bounds["x"]["max"]):
        raise ValueError(f"x coordinates outside {space} bounds")
    if not (bounds["y"]["min"] <= y1 <= y2 <= bounds["y"]["max"]):
        raise ValueError(f"y coordinates outside {space} bounds")
    width = x2 - x1 + 1
    height = y2 - y1 + 1
    area = width * height
    if area > SPATIAL_MAX_REGION_AREA:
        raise ValueError(f"region area exceeds limit {SPATIAL_MAX_REGION_AREA}")
    return space, {
        "x1": x1,
        "y1": y1,
        "x2": x2,
        "y2": y2,
        "width": width,
        "height": height,
        "area": area,
    }


def _spatial_sample_request(arguments: dict[str, Any]) -> tuple[list[str], int, int]:
    requested = arguments.get("sample_fields", ["temp", "pressure"])
    if not isinstance(requested, list):
        raise ValueError("sample_fields must be an array")
    fields: list[str] = []
    for field in requested:
        if not isinstance(field, str):
            raise ValueError("sample_fields entries must be strings")
        if field not in SPATIAL_AVAILABLE_FIELDS and field not in SPATIAL_UNSUPPORTED_FIELDS:
            raise ValueError(f"unsupported sample field {field}")
        if field not in fields:
            fields.append(field)
    stride = _strict_spatial_int(arguments.get("sample_stride", 4), "sample_stride")
    if stride < 1 or stride > SPATIAL_MAX_STRIDE:
        raise ValueError(f"sample_stride must be between 1 and {SPATIAL_MAX_STRIDE}")
    max_samples = _strict_spatial_int(arguments.get("max_samples", SPATIAL_MAX_SAMPLES), "max_samples")
    if max_samples < 1 or max_samples > SPATIAL_MAX_SAMPLES:
        raise ValueError(f"max_samples must be between 1 and {SPATIAL_MAX_SAMPLES}")
    return fields, stride, max_samples


def _spatial_particle_request(arguments: dict[str, Any]) -> tuple[bool, list[int], int]:
    discover_particles = arguments.get("discover_particles", False)
    if type(discover_particles) is not bool:
        raise ValueError("discover_particles must be a boolean")
    raw_particle_ids = arguments.get("particle_ids", [])
    if not isinstance(raw_particle_ids, list):
        raise ValueError("particle_ids must be an array")
    particle_ids: list[int] = []
    seen_ids: set[int] = set()
    for particle_id in raw_particle_ids:
        if type(particle_id) is not int:
            raise ValueError("particle_ids entries must be integers")
        if particle_id < 0:
            raise ValueError("particle_ids entries must be non-negative")
        if particle_id not in seen_ids:
            seen_ids.add(particle_id)
            particle_ids.append(particle_id)
    if len(particle_ids) > SPATIAL_MAX_PARTICLE_IDS:
        raise ValueError(
            f"particle_ids cannot exceed {SPATIAL_MAX_PARTICLE_IDS} entries"
        )
    max_particles = _strict_spatial_int(
        arguments.get("max_particles", SPATIAL_MAX_PARTICLES),
        "max_particles",
    )
    if max_particles < 1 or max_particles > SPATIAL_MAX_PARTICLES:
        raise ValueError(
            f"max_particles must be between 1 and {SPATIAL_MAX_PARTICLES}"
        )
    return discover_particles, particle_ids, max_particles


def _spatial_response_budget(arguments: dict[str, Any]) -> int:
    max_response_bytes = _strict_spatial_int(
        arguments.get("max_response_bytes", SPATIAL_MAX_RESPONSE_BYTES),
        "max_response_bytes",
    )
    if max_response_bytes < 4096 or max_response_bytes > SPATIAL_MAX_RESPONSE_BYTES:
        raise ValueError(
            "max_response_bytes must be between 4096 and "
            f"{SPATIAL_MAX_RESPONSE_BYTES}"
        )
    return max_response_bytes


def _spatial_points(region: dict[str, int], stride: int, max_samples: int) -> tuple[list[tuple[int, int]], bool]:
    points = [
        (x, y)
        for y in range(region["y1"], region["y2"] + 1, stride)
        for x in range(region["x1"], region["x2"] + 1, stride)
    ]
    return points[:max_samples], len(points) > max_samples


def _spatial_runtime_pid() -> int | None:
    powder_pids = {
        process.get("pid")
        for process in _powder_processes()
        if type(process.get("pid")) is int
    }
    if not powder_pids:
        return None
    owners: set[int] = set()
    try:
        for connection in psutil.net_connections(kind="tcp"):
            address = connection.laddr
            if (
                connection.status == psutil.CONN_LISTEN
                and getattr(address, "port", None) == 9876
                and type(connection.pid) is int
            ):
                owners.add(connection.pid)
    except (psutil.Error, OSError):
        return None
    matches = powder_pids & owners
    return next(iter(matches)) if len(matches) == 1 else None


def _spatial_field_unit(field: str) -> str | None:
    if field in {"temp", "temperature"}:
        return "K"
    if field == "pressure":
        return "simulation_pressure"
    return None
def _spatial_snapshot(arguments: dict[str, Any]) -> dict[str, Any]:
    """Issue exactly one bounded atomic ``spatialSnapshot`` bridge request."""
    started = time.perf_counter()
    correlation_id = current_correlation_id() or new_correlation_id()
    space, region = _spatial_region(arguments)
    fields, stride, max_samples = _spatial_sample_request(arguments)
    if space == "pixel" and "sample_fields" not in arguments:
        fields = []
    allow_truncation = arguments.get("allow_truncation", False)
    if type(allow_truncation) is not bool:
        raise TypeError("allow_truncation must be a boolean")
    discover_particles, particle_ids, max_particles = _spatial_particle_request(arguments)
    max_response_bytes = _spatial_response_budget(arguments)

    try:
        result = get_client().spatial_snapshot(
            space=space,
            x1=region["x1"],
            y1=region["y1"],
            x2=region["x2"],
            y2=region["y2"],
            sample_fields=fields,
            sample_stride=stride,
            max_samples=max_samples,
            discover_particles=discover_particles,
            particle_ids=particle_ids,
            max_particles=max_particles,
            max_response_bytes=max_response_bytes,
            allow_truncation=allow_truncation,
        )
    except PowderAPIError as exc:
        result = exc.response
        if not isinstance(result, dict):
            result = {
                "ok": False,
                "action": "spatialSnapshot",
                "error": exc.error,
                "detail": exc.detail,
            }
    except PowderConnectionError as exc:
        result = {
            "ok": False,
            "action": "spatialSnapshot",
            "error_code": "transport_error",
            "error": str(exc),
            "evidence": {
                "contract": "spatial-evidence/v1",
                "status": "failed",
                "postcondition_ok": False,
                "complete": False,
                "strength": "absent",
                "reason": "transport_error",
            },
        }

    if not isinstance(result, dict):
        raise TypeError("spatialSnapshot returned a non-object response")
    result = dict(result)
    runtime_pid = _spatial_runtime_pid()
    result.setdefault("runtime_pid", runtime_pid)
    result["emitter_pid"] = os.getpid()
    result.setdefault("tool", "spatial_snapshot")
    result["correlation_id"] = correlation_id
    duration_ms = round((time.perf_counter() - started) * 1000.0, 3)
    emit(
        request="spatial_snapshot",
        action="spatialSnapshot",
        correlation_id=correlation_id,
        phase="mcp",
        ok=bool(result.get("ok")),
        error=None if result.get("ok") else str(result.get("error") or "snapshot_failed"),
        duration_ms=duration_ms,
        response_summary=summarize_response(result),
        pid=os.getpid(),
        runtime_pid=runtime_pid,
    )
    return result

def _parts_inventory(arguments: dict[str, Any]) -> dict[str, Any]:
    """Issue one bounded live ``partsInventory`` request and attach evidence."""
    started = time.perf_counter()
    correlation_id = current_correlation_id() or new_correlation_id()
    if not isinstance(arguments, dict):
        raise TypeError("parts_inventory arguments must be an object")
    allowed_keys = {"cursor", "limit", "max_scan", "x1", "y1", "x2", "y2", "type"}
    unknown_keys = set(arguments) - allowed_keys
    if unknown_keys:
        raise ValueError("unknown parts_inventory request key")

    def require_int(value: Any, name: str) -> int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise TypeError(f"{name} must be an integer")
        return value

    cursor = require_int(arguments.get("cursor", 0), "cursor")
    limit = require_int(arguments.get("limit", PARTS_INVENTORY_MAX_LIMIT), "limit")
    max_scan = require_int(arguments.get("max_scan", PARTS_INVENTORY_MAX_SCAN), "max_scan")
    if not 0 <= cursor <= PARTS_INVENTORY_MAX_SLOTS:
        raise ValueError(
            "cursor must be between 0 and "
            f"{PARTS_INVENTORY_MAX_SLOTS}"
        )
    if not 1 <= limit <= PARTS_INVENTORY_MAX_LIMIT:
        raise ValueError(
            f"limit must be between 1 and {PARTS_INVENTORY_MAX_LIMIT}"
        )
    if not 1 <= max_scan <= PARTS_INVENTORY_MAX_SCAN:
        raise ValueError(
            f"max_scan must be between 1 and {PARTS_INVENTORY_MAX_SCAN}"
        )

    region_keys = ("x1", "y1", "x2", "y2")
    region: dict[str, int] | None
    if any(key in arguments for key in region_keys):
        if not all(key in arguments for key in region_keys):
            raise ValueError("x1, y1, x2, and y2 are required together")
        region = {
            key: require_int(arguments[key], key)
            for key in region_keys
        }
        if not (0 <= region["x1"] <= region["x2"] < PIXEL_XRES):
            raise ValueError("x coordinates outside pixel bounds")
        if not (0 <= region["y1"] <= region["y2"] < PIXEL_YRES):
            raise ValueError("y coordinates outside pixel bounds")
    else:
        region = None

    type_filter = arguments.get("type")
    if type_filter is not None:
        type_filter = require_int(type_filter, "type")
        if type_filter < 0:
            raise ValueError("type must be non-negative")
    requested = {
        "cursor": cursor,
        "limit": limit,
        "max_scan": max_scan,
        "region": region,
        "type": type_filter,
    }
    try:
        result = get_client().parts_inventory(
            cursor=cursor,
            limit=limit,
            max_scan=max_scan,
            x1=None if region is None else region["x1"],
            y1=None if region is None else region["y1"],
            x2=None if region is None else region["x2"],
            y2=None if region is None else region["y2"],
            type=type_filter,
        )
    except PowderAPIError as exc:
        result = exc.response
        if not isinstance(result, dict):
            result = {
                "ok": False,
                "action": "partsInventory",
                "error": exc.error,
                "detail": exc.detail,
            }
    except PowderConnectionError as exc:
        result = {
            "ok": False,
            "action": "partsInventory",
            "error_code": "transport_error",
            "error": str(exc),
        }
    if not isinstance(result, dict):
        raise TypeError("partsInventory returned a non-object response")

    cleaned = strip_secrets(result)
    if not isinstance(cleaned, dict):
        cleaned = {}
    result = dict(cleaned)
    records = result.get("records")
    if isinstance(records, list):
        result["records"] = [
            {
                key: record[key]
                for key in PARTS_INVENTORY_RECORD_FIELDS
                if key in record
            }
            for record in records
            if isinstance(record, dict)
        ]
    result.setdefault("action", "partsInventory")
    result.setdefault("schema_version", "parts-inventory/v1")
    result.setdefault("tool", "parts_inventory")
    runtime_pid = _spatial_runtime_pid()
    result.setdefault("runtime_pid", runtime_pid)
    result["emitter_pid"] = os.getpid()
    result["correlation_id"] = correlation_id
    result.setdefault(
        "limits",
        {
            "max_limit": PARTS_INVENTORY_MAX_LIMIT,
            "max_scan": PARTS_INVENTORY_MAX_SCAN,
            "slot_bound": PARTS_INVENTORY_MAX_SLOTS,
        },
    )
    result.setdefault(
        "filters",
        {
            "region": region,
            "type": requested.get("type"),
        },
    )
    result.setdefault(
        "provenance",
        {
            "source_root": "D:/The-Powder-Toy",
            "runtime_deploy": "D:/The-Powder-Toy/build/autorun.lua",
            "mcp_source_root": str(REPO_ROOT),
            "runtime_host": "127.0.0.1",
            "runtime_port": 9876,
            "particle_source": "sim.partExists/partPosition/partProperty",
            "slot_bound_source": "SimulationConfig.h:NPART=XRES*YRES",
            "slot_bound": PARTS_INVENTORY_MAX_SLOTS,
            "pid_source": "runtime_binding_or_unavailable",
            "cursor_source": "raw_particle_slot",
            "part_count_source": "sim.partCount",
        },
    )
    evidence = result.get("evidence")
    if isinstance(evidence, dict):
        evidence = dict(evidence)
        evidence["correlation_id"] = correlation_id
        evidence["snapshot_scope"] = "single_handler_capture"
        evidence["cross_page_consistency"] = "not_guaranteed"
        evidence["invariants"] = {
            "cursor_advances_by_scanned": True,
            "partCount_captured_once": True,
            "live_simulation": True,
        }
        result["evidence"] = evidence
    else:
        response_ok = bool(result.get("ok"))
        done = bool(result.get("done"))
        truncated = bool(result.get("truncated"))
        status = "failed" if not response_ok else "verified" if done and not truncated else "partial"
        result["evidence"] = {
            "contract": "parts-inventory-evidence/v1",
            "status": status,
            "postcondition_ok": response_ok,
            "complete": status == "verified",
            "strength": "bounded_runtime_read",
            "correlation_id": correlation_id,
            "requested": requested,
            "readback": {
                "action": "partsInventory",
                "cursor_next": result.get("cursor_next"),
                "done": result.get("done"),
                "truncated": result.get("truncated"),
                "partCount": result.get("partCount"),
                "matched": result.get("matched"),
                "scanned": result.get("scanned"),
                "returned": result.get("returned"),
            },
            "reason": (
                None
                if response_ok and not truncated
                else "inventory_truncated"
                if response_ok
                else str(result.get("error") or "inventory_failed")
            ),
        }
    duration_ms = round((time.perf_counter() - started) * 1000.0, 3)
    emit(
        request="parts_inventory",
        action="partsInventory",
        correlation_id=correlation_id,
        phase="mcp",
        ok=bool(result.get("ok")),
        error=None if result.get("ok") else str(result.get("error") or "inventory_failed"),
        duration_ms=duration_ms,
        response_summary=summarize_response(result),
        pid=os.getpid(),
        runtime_pid=runtime_pid,
    )
    return result
def _design_intake(arguments: dict[str, Any]) -> dict[str, Any]:
    """Collect bounded read-only design evidence without mutating the simulation.

    Intake deliberately separates checkpoint state, structure (occupancy and
    composition), and dynamics (field/mode samples). Every child read is
    independently bounded so a single unavailable surface becomes a recorded
    limitation rather than aborting the whole intake.
    """
    started = time.perf_counter()
    correlation_id = current_correlation_id()
    errors: list[dict[str, Any]] = []
    limitations: list[str] = [
        "No screenshot or visual-render inspection is performed by this tool.",
        "Spatial and inventory evidence is bounded and may be truncated.",
        "Density/composition recommendations are evidence-based heuristics, not physical guarantees.",
    ]

    def bounded_int(name: str, default: int, lower: int, upper: int) -> int:
        value = arguments.get(name, default)
        if type(value) is not int:
            raise ValueError(f"{name} must be an integer")
        return max(lower, min(upper, value))

    # Fixed checkpoint: capture once before tiled reads, then never mutate.
    checkpoint: dict[str, Any] = {
        "captured_at": time.time(),
        "correlation_id": correlation_id,
        "state": None,
        "modes": None,
    }
    try:
        checkpoint["state"] = get_client().get_simulation_state()
    except Exception as exc:
        errors.append({"stage": "state", "error": _probe_error(exc)})
        limitations.append("Simulation state was unavailable at checkpoint.")
    try:
        checkpoint["modes"] = get_client().get_simulation_modes()
    except Exception as exc:
        errors.append({"stage": "modes", "error": _probe_error(exc)})
        limitations.append("Simulation modes were unavailable at checkpoint.")

    raw_tiles = arguments.get("tiles")
    if raw_tiles is None:
        raw_tiles = []
        tile_width = PIXEL_XRES // 4
        tile_height = PIXEL_YRES // 5
        for row in range(5):
            y1 = row * tile_height
            y2 = PIXEL_YRES - 1 if row == 4 else (row + 1) * tile_height - 1
            for column in range(4):
                x1 = column * tile_width
                x2 = PIXEL_XRES - 1 if column == 3 else (column + 1) * tile_width - 1
                raw_tiles.append({"space": "pixel", "x1": x1, "y1": y1, "x2": x2, "y2": y2})
    if not isinstance(raw_tiles, list):
        return {"ok": False, "tool": "design_intake", "error": "tiles must be an array", "correlation_id": correlation_id}
    max_tiles = bounded_int("max_tiles", 20, 1, 64)
    tiles = raw_tiles[:max_tiles]
    if len(raw_tiles) > max_tiles:
        limitations.append(f"Tile list truncated to {max_tiles} entries.")
    stride = bounded_int("sample_stride", bounded_int("stride", 4, 1, SPATIAL_MAX_STRIDE), 1, SPATIAL_MAX_STRIDE)
    max_samples = bounded_int("max_samples", 1024, 1, SPATIAL_MAX_SAMPLES)
    max_response_bytes = bounded_int("max_response_bytes", SPATIAL_MAX_RESPONSE_BYTES, 4096, SPATIAL_MAX_RESPONSE_BYTES)
    default_sample_fields = arguments.get("sample_fields", ["temp", "pressure"])
    if not isinstance(default_sample_fields, list):
        default_sample_fields = ["temp", "pressure"]
    default_sample_fields = default_sample_fields[:7]
    if "sample_fields" not in arguments:
        limitations.append("Cell tiles sample temp and pressure; pixel tiles omit unsupported field sampling.")
    snapshots: list[dict[str, Any]] = []
    cell_snapshots: list[dict[str, Any]] = []
    inventory_pages: list[dict[str, Any]] = []
    inventory_limit = bounded_int("inventory_limit", 64, 1, PARTS_INVENTORY_MAX_LIMIT)
    inventory_scan = bounded_int("inventory_max_scan", bounded_int("max_scan", 1024, 1, PARTS_INVENTORY_MAX_SCAN), 1, PARTS_INVENTORY_MAX_SCAN)
    max_inventory_pages = bounded_int("max_inventory_pages", 4, 1, 8)

    for index, tile in enumerate(tiles):
        if not isinstance(tile, dict):
            errors.append({"stage": "tile", "index": index, "error": "tile must be an object"})
            continue
        request = dict(tile)
        is_cell_tile = request.get("space") == "cell"
        request.update({
            "sample_stride": stride,
            "sample_fields": request.get("sample_fields", default_sample_fields if is_cell_tile else []),
            "max_samples": max_samples,
            "max_response_bytes": max_response_bytes,
            "allow_truncation": True,
            "discover_particles": bool(arguments.get("discover_particles", True)),
        })
        try:
            snapshot = _spatial_snapshot(request)
            if not isinstance(snapshot, dict) or snapshot.get("ok") is False:
                errors.append({"stage": "spatial_snapshot", "tile_index": index, "error": snapshot.get("error", "snapshot_failed") if isinstance(snapshot, dict) else "invalid_snapshot"})
            else:
                snapshot["tile_index"] = index
                snapshots.append(snapshot)
                if snapshot.get("truncated"):
                    limitations.append(f"Spatial tile {index} was truncated by sampling or response bounds.")
        except Exception as exc:
            errors.append({"stage": "spatial_snapshot", "tile_index": index, "error": _probe_error(exc)})
        if bool(arguments.get("include_inventory", True)):
            cursor = 0
            for page_index in range(max_inventory_pages):
                inv_request = {
                    "cursor": cursor,
                    "limit": inventory_limit,
                    "max_scan": inventory_scan,
                }
                for key in ("x1", "y1", "x2", "y2"):
                    if key in request:
                        inv_request[key] = request[key]
                try:
                    page = _parts_inventory(inv_request)
                    if not isinstance(page, dict) or page.get("ok") is False:
                        errors.append({"stage": "parts_inventory", "tile_index": index, "page_index": page_index, "error": page.get("error", "inventory_failed") if isinstance(page, dict) else "invalid_inventory"})
                        break
                    page["tile_index"] = index
                    page["page_index"] = page_index
                    inventory_pages.append(page)
                    next_cursor = page.get("cursor_next")
                    if page.get("done") or next_cursor is None or next_cursor == cursor:
                        break
                    cursor = int(next_cursor)
                except Exception as exc:
                    errors.append({"stage": "parts_inventory", "tile_index": index, "page_index": page_index, "error": _probe_error(exc)})
                    break
    raw_cell_tiles = arguments.get("cell_tiles")
    if raw_cell_tiles is None:
        raw_cell_tiles = [
            {"space": "cell", "x1": 0, "y1": 0, "x2": CELL_XCELLS // 2 - 1, "y2": CELL_YCELLS // 2 - 1},
            {"space": "cell", "x1": CELL_XCELLS // 2, "y1": 0, "x2": CELL_XCELLS - 1, "y2": CELL_YCELLS // 2 - 1},
            {"space": "cell", "x1": 0, "y1": CELL_YCELLS // 2, "x2": CELL_XCELLS // 2 - 1, "y2": CELL_YCELLS - 1},
            {"space": "cell", "x1": CELL_XCELLS // 2, "y1": CELL_YCELLS // 2, "x2": CELL_XCELLS - 1, "y2": CELL_YCELLS - 1},
        ]
    cell_snapshots: list[dict[str, Any]] = []
    for index, tile in enumerate(raw_cell_tiles[:4] if isinstance(raw_cell_tiles, list) else []):
        if not isinstance(tile, dict):
            errors.append({"stage": "cell_tile", "index": index, "error": "tile must be an object"})
            continue
        request = dict(tile)
        request.update({
            "sample_stride": stride,
            "sample_fields": request.get("sample_fields", default_sample_fields),
            "max_samples": max_samples,
            "max_response_bytes": max_response_bytes,
            "allow_truncation": True,
            "discover_particles": False,
        })
        try:
            snapshot = _spatial_snapshot(request)
            if not isinstance(snapshot, dict) or snapshot.get("ok") is False:
                errors.append({"stage": "cell_spatial_snapshot", "tile_index": index, "error": snapshot.get("error", "snapshot_failed") if isinstance(snapshot, dict) else "invalid_snapshot"})
            else:
                snapshot["tile_index"] = index
                cell_snapshots.append(snapshot)
        except Exception as exc:
            errors.append({"stage": "cell_spatial_snapshot", "tile_index": index, "error": _probe_error(exc)})


    catalog: dict[str, Any] | None = None
    if bool(arguments.get("include_catalog", True)):
        try:
            catalog = _catalog_status(include_runtime=True)
        except Exception as exc:
            errors.append({"stage": "catalog", "error": _probe_error(exc)})
            limitations.append("Source catalog/runtime catalog status was unavailable.")

    returned = sum(len(page.get("records", [])) for page in inventory_pages if isinstance(page, dict))
    state = checkpoint["state"]
    total = state.get("partCount", state.get("part_count")) if isinstance(state, dict) else None
    density = (returned / max(1, len(tiles))) if inventory_pages else None
    rubric = {
        "contract": "design-intake-rubric/v1",
        "composition": {"status": "observed" if inventory_pages else "unavailable", "sampled_particles": returned, "checkpoint_part_count": total},
        "density": {"status": "bounded_heuristic", "per_tile_sample_count": density, "interpretation": "higher counts indicate denser sampled occupancy; empty tiles are not proof of global emptiness"},
        "structure": {"status": "observed" if snapshots else "unavailable", "tile_count": len(snapshots), "separate_from_dynamics": True},
        "dynamics": {"status": "checkpoint_only", "modes_captured": checkpoint["modes"] is not None, "field_samples": sum(len(s.get("samples", [])) for s in cell_snapshots if isinstance(s, dict)), "cell_tiles": len(cell_snapshots)},
        "recommendation": "Use composition/density evidence for layout decisions; validate material semantics and dynamic behavior separately before any mutation.",
    }
    result = {
        "tool": "design_intake",
        "schema_version": "design-intake/v1",
        "correlation_id": correlation_id,
        "checkpoint": checkpoint,
        "state": checkpoint["state"],
        "modes": checkpoint["modes"],
        "catalog": catalog,
        "spatial_snapshots": snapshots,
        "cell_snapshots": cell_snapshots,
        "inventory_pages": inventory_pages,
        "rubric": rubric,
        "errors": errors,
        "limitations": limitations,
        "bounds": {"max_tiles": max_tiles, "max_samples": max_samples, "max_inventory_pages": max_inventory_pages, "inventory_limit": inventory_limit, "inventory_max_scan": inventory_scan},
        "duration_ms": round((time.perf_counter() - started) * 1000.0, 3),
    }
    result["ok"] = not errors
    emit(request="design_intake", action="designIntake", correlation_id=correlation_id, phase="mcp", ok=bool(result["ok"]), error=None if result["ok"] else "intake_failed", duration_ms=result["duration_ms"], response_summary=summarize_response(result), pid=os.getpid(), runtime_pid=_spatial_runtime_pid())
    return result


EXPERIMENT_RUN_MAX_COMPONENTS = 64
EXPERIMENT_RUN_MAX_FRAMES = 120
EXPERIMENT_RUN_MAX_CHECKPOINTS = 3
EXPERIMENT_RUN_SCHEMA_VERSION = "experiment-run/v1"


def _experiment_run(arguments: dict[str, Any]) -> dict[str, Any]:
    """Bounded dry-run/checkpoint orchestrator with explicit commit gate.

    Orchestrates exactly one caller-supplied candidate plan: capture
    checkpoints t0/t1/t2 via existing ``get_simulation_state`` /
    ``get_simulation_modes`` plus one bounded ``design_intake``, step a
    bounded frame count, and route caller-supplied metrics through
    ``_experiment_evaluate`` (returning ``needs_metrics`` when absent).

    Hard caps:
      * components  <= 64
      * frames      <= 120
      * checkpoints <= 3 (t0/t1/t2)

    ``dry_run`` defaults to True; ``commit`` is required to allow any
    mutation. ``dry_run=True`` or ``commit=False`` guarantees zero
    simulation mutation. No rollback, no clear-after, no automatic restore.
    """
    correlation_id = current_correlation_id() or new_correlation_id()
    errors: list[str] = []
    limitations: list[str] = [
        "experiment_run is bounded: components <= 64, frames <= 120, checkpoints <= 3.",
        "experiment_run performs no rollback, no clear-after, and no automatic restore.",
        "Mutation only occurs when commit=True AND dry_run=False; dry_run=True or commit=False is read-only.",
        "Checkpoint capture uses existing get_simulation_state / get_simulation_modes plus one bounded design_intake.",
    ]
    partial_mutation = False

    def _bounded_int(name: str, default: int, lower: int, upper: int) -> int:
        value = arguments.get(name, default)
        if type(value) is not int or isinstance(value, bool):
            raise ValueError(f"{name} must be an integer")
        if value < lower or value > upper:
            raise ValueError(f"{name} must be between {lower} and {upper}")
        return value

    def _coerce_bool(name: str, default: bool) -> bool:
        value = arguments.get(name, default)
        if not isinstance(value, bool):
            raise ValueError(f"{name} must be boolean")
        return value

    dry_run = True
    commit = False
    plan_obj: dict[str, Any] | None = None
    components_raw: list[Any] = []
    steps_raw: list[Any] = []
    plan_name = "experiment_run"
    clear_before = False
    frames_requested = 0
    metrics: dict[str, Any] | None = None

    try:
        dry_run = _coerce_bool("dry_run", True)
        commit = _coerce_bool("commit", False)
        if dry_run and commit:
            limitations.append("commit=True is ignored because dry_run=True; mutation is blocked.")
            commit = False
        checkpoints = _bounded_int(
            "checkpoints", 2, 1, EXPERIMENT_RUN_MAX_CHECKPOINTS
        )
        plan_obj = arguments.get("plan")
        if not isinstance(plan_obj, dict):
            errors.append("plan must be an object")
            plan_obj = {}
        plan_name = str(plan_obj.get("name", "experiment_run"))
        components_raw = plan_obj.get("components", [])
        steps_raw = plan_obj.get("steps", [])
        if not isinstance(components_raw, list):
            errors.append("plan.components must be an array")
            components_raw = []
        if not isinstance(steps_raw, list):
            errors.append("plan.steps must be an array")
            steps_raw = []
        if len(components_raw) > EXPERIMENT_RUN_MAX_COMPONENTS:
            errors.append(
                f"plan.components exceeds limit {EXPERIMENT_RUN_MAX_COMPONENTS}"
            )
            components_raw = components_raw[: EXPERIMENT_RUN_MAX_COMPONENTS]
        normalized_steps: list[dict[str, Any]] = []
        total_frames = 0
        for index, action in enumerate(steps_raw):
            if not isinstance(action, dict) or action.get("op") != "step":
                errors.append(f"step {index}: only op='step' is supported")
                continue
            try:
                count = int(action.get("n", 1))
            except (TypeError, ValueError):
                errors.append(f"step {index}: n must be an integer")
                continue
            if count < 1 or count > EXPERIMENT_RUN_MAX_FRAMES:
                errors.append(
                    f"step {index}: n must be between 1 and {EXPERIMENT_RUN_MAX_FRAMES}"
                )
                continue
            normalized_steps.append({"op": "step", "n": count})
            total_frames += count
        if total_frames > EXPERIMENT_RUN_MAX_FRAMES:
            errors.append(
                f"total frames {total_frames} exceeds limit {EXPERIMENT_RUN_MAX_FRAMES}"
            )
        frames_requested = total_frames
        clear_before_raw = plan_obj.get("clear_before", False)
        if not isinstance(clear_before_raw, bool):
            errors.append("plan.clear_before must be boolean")
            clear_before = False
        else:
            clear_before = clear_before_raw
        metrics = arguments.get("metrics")
        if metrics is not None and not isinstance(metrics, dict):
            errors.append("metrics must be an object with baseline/candidate")
            metrics = None
        if isinstance(metrics, dict):
            if "baseline" not in metrics or "candidate" not in metrics:
                errors.append("metrics must contain baseline and candidate")
                metrics = None
    except ValueError as exc:
        errors.append(str(exc))

    component_errors = _validate_components(components_raw) if components_raw else []
    if component_errors:
        errors.extend(component_errors)
    normalized_components = (
        _normalize_components(components_raw) if components_raw else []
    )

    will_mutate = (not dry_run) and commit and (not errors) and (
        bool(normalized_components) or bool(normalized_steps) or clear_before
    )

    checkpoints_collected: list[dict[str, Any]] = []
    intake_evidence: dict[str, Any] | None = None
    client_errors: list[str] = []
    mutation_record: dict[str, Any] = {
        "executed": False,
        "components_applied": 0,
        "components_failed": 0,
        "steps_executed": 0,
        "steps_failed": 0,
        "step_responses": [],
    }

    def _capture_checkpoint(label: str) -> dict[str, Any]:
        checkpoint: dict[str, Any] = {
            "label": label,
            "captured_at": time.time(),
            "correlation_id": correlation_id,
            "state": None,
            "modes": None,
            "errors": [],
        }
        try:
            checkpoint["state"] = get_client().get_simulation_state()
        except Exception as exc:
            checkpoint["errors"].append({"stage": "state", "error": _probe_error(exc)})
            client_errors.append(f"checkpoint {label} state: {_probe_error(exc)}")
        try:
            checkpoint["modes"] = get_client().get_simulation_modes()
        except Exception as exc:
            checkpoint["errors"].append({"stage": "modes", "error": _probe_error(exc)})
            client_errors.append(f"checkpoint {label} modes: {_probe_error(exc)}")
        return checkpoint

    if not errors:
        checkpoints_collected.append(_capture_checkpoint("t0"))
        if checkpoints >= 2:
            try:
                intake_evidence = _design_intake({})
            except Exception as exc:
                client_errors.append(f"design_intake: {_probe_error(exc)}")
                intake_evidence = {"ok": False, "error": _probe_error(exc)}
            checkpoints_collected[-1]["intake_summary"] = {
                "ok": bool(isinstance(intake_evidence, dict) and intake_evidence.get("ok")),
                "error": (intake_evidence or {}).get("error") if isinstance(intake_evidence, dict) else "intake_failed",
            }

        if will_mutate:
            client = get_client()
            try:
                if clear_before:
                    client.clear()
                mutation_record["executed"] = True
            except Exception as exc:
                client_errors.append(f"clear: {_probe_error(exc)}")
                partial_mutation = True
            applied = 0
            failed = 0
            for index, component in enumerate(normalized_components):
                kind = component.get("kind")
                try:
                    if kind == "box":
                        client.place_element(
                            component["element"],
                            x1=component["x1"], y1=component["y1"],
                            x2=component["x2"], y2=component["y2"],
                        )
                    elif kind == "line":
                        client.place_element_line(
                            component["element"],
                            x1=component["x1"], y1=component["y1"],
                            x2=component["x2"], y2=component["y2"],
                        )
                    elif kind == "wall_line":
                        client.place_wall_line(
                            component["wall"],
                            x1=component["x1"], y1=component["y1"],
                            x2=component["x2"], y2=component["y2"],
                        )
                    elif kind == "wall_box":
                        client.place_wall_box(
                            component["wall"],
                            x1=component["x1"], y1=component["y1"],
                            x2=component["x2"], y2=component["y2"],
                        )
                    elif kind == "tool_box":
                        client.apply_tool_box(
                            component["tool"],
                            x1=component["x1"], y1=component["y1"],
                            x2=component["x2"], y2=component["y2"],
                            strength=float(component.get("strength", 1.0)),
                            brush=int(component.get("brush", 0)),
                            rx=int(component.get("rx", 0)),
                            ry=int(component.get("ry", 0)),
                        )
                    else:
                        raise ValueError(f"unsupported kind {kind!r}")
                    applied += 1
                except Exception as exc:
                    failed += 1
                    client_errors.append(
                        f"component {index} ({kind}): {_probe_error(exc)}"
                    )
                    partial_mutation = True
                    break
            mutation_record["components_applied"] = applied
            mutation_record["components_failed"] = failed
            if checkpoints >= 2:
                checkpoints_collected.append(_capture_checkpoint("t1"))
            steps_executed = 0
            steps_failed = 0
            step_responses: list[dict[str, Any]] = []
            for index, action in enumerate(normalized_steps):
                try:
                    response = client.step(int(action["n"]))
                    step_responses.append({"index": index, "ok": True, "response": response})
                    steps_executed += 1
                except Exception as exc:
                    step_responses.append({"index": index, "ok": False, "error": _probe_error(exc)})
                    steps_failed += 1
                    client_errors.append(f"step {index}: {_probe_error(exc)}")
                    partial_mutation = True
                    break
            mutation_record["steps_executed"] = steps_executed
            mutation_record["steps_failed"] = steps_failed
            mutation_record["step_responses"] = step_responses
            if checkpoints >= 3:
                checkpoints_collected.append(_capture_checkpoint("t2"))
        else:
            if checkpoints >= 2:
                checkpoints_collected.append(_capture_checkpoint("t1"))
            if checkpoints >= 3:
                checkpoints_collected.append(_capture_checkpoint("t2"))

    evaluation: dict[str, Any] | None = None
    needs_metrics = False
    if metrics is not None and not errors:
        evaluation = _experiment_evaluate(metrics)
    else:
        needs_metrics = True

    run_id = f"exp-{int(time.time() * 1000)}-{abs(hash(correlation_id)) % 10000:04d}"
    if client_errors:
        errors.extend(client_errors)

    result = {
        "tool": "experiment_run",
        "schema_version": EXPERIMENT_RUN_SCHEMA_VERSION,
        "run_id": run_id,
        "correlation_id": correlation_id,
        "dry_run": dry_run,
        "commit": commit,
        "committed": will_mutate,
        "partial_mutation": partial_mutation,
        "ok": not errors,
        "errors": errors,
        "limitations": limitations,
        "plan_summary": {
            "name": plan_name,
            "component_count": len(normalized_components),
            "step_count": len(normalized_steps),
            "frames": frames_requested,
            "clear_before": clear_before and will_mutate,
        },
        "bounds": {
            "max_components": EXPERIMENT_RUN_MAX_COMPONENTS,
            "max_frames": EXPERIMENT_RUN_MAX_FRAMES,
            "max_checkpoints": EXPERIMENT_RUN_MAX_CHECKPOINTS,
        },
        "checkpoints": checkpoints_collected,
        "design_intake": intake_evidence,
        "mutation": mutation_record if will_mutate else None,
        "needs_metrics": needs_metrics,
        "evaluation": evaluation,
        "provenance": {
            "method": "bounded-experiment-orchestrator",
            "read_only": not will_mutate,
            "rollback": "none",
            "clear_after": False,
            "mutation_unavailable": False,
        },
    }
    return result


def _experiment_evaluate(arguments: dict[str, Any]) -> dict[str, Any]:
    """Deterministically compare two bounded metric snapshots without live reads."""

    correlation_id = current_correlation_id() or new_correlation_id()
    numeric_fields = (
        "part_count",
        "active_particles",
        "occupied_tiles",
        "temp_mean",
        "temp_max",
        "pressure_mean",
        "pressure_max",
        "frames",
        "motion_delta",
        "phase_delta",
        "visual_readability",
        "expected_transform",
        "containment",
        "trigger",
    )
    count_fields = {"part_count", "active_particles", "occupied_tiles", "frames"}
    bounded_score_fields = {"visual_readability", "expected_transform", "containment", "trigger"}
    activity_fields = ("active_particles", "motion_delta", "phase_delta")
    gate_fields = ("errors", "truncated", "partial_mutation", "safety_ok")
    required_numeric_fields = ("part_count", "occupied_tiles", "frames")
    errors: list[str] = []
    limitations: list[str] = [
        "Scores compare supplied aggregate metrics only; no simulation, screenshot, particle identity, or visual quality readback is performed.",
        "A score is not a safety claim; acceptance requires explicit clean safety and readback gates for both snapshots.",
    ]

    snapshots: dict[str, dict[str, Any]] = {}
    for label in ("baseline", "candidate"):
        raw = arguments.get(label)
        if not isinstance(raw, dict):
            errors.append(f"{label} must be an object")
            snapshots[label] = {}
            continue
        unexpected = sorted(set(raw) - set(numeric_fields) - set(gate_fields))
        if unexpected:
            errors.append(f"{label} contains unsupported fields: {', '.join(unexpected)}")
        cleaned: dict[str, Any] = {}
        for field in numeric_fields:
            if field not in raw:
                continue
            value = raw[field]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
                errors.append(f"{label}.{field} must be a finite number")
                continue
            number = float(value)
            if abs(number) > 1_000_000_000_000:
                errors.append(f"{label}.{field} exceeds the supported bound")
                continue
            if field in count_fields and (number < 0 or not number.is_integer()):
                errors.append(f"{label}.{field} must be a non-negative integer")
                continue
            if field in bounded_score_fields and not 0.0 <= number <= 100.0:
                errors.append(f"{label}.{field} must be from 0 through 100")
                continue
            cleaned[field] = int(number) if field in count_fields else number
        if "errors" in raw:
            value = raw["errors"]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
                errors.append(f"{label}.errors must be a finite number")
            elif float(value) < 0 or not float(value).is_integer() or float(value) > 1_000_000:
                errors.append(f"{label}.errors must be an integer from 0 through 1000000")
            else:
                cleaned["errors"] = int(value)
        for field in ("truncated", "partial_mutation", "safety_ok"):
            if field not in raw:
                continue
            if not isinstance(raw[field], bool):
                errors.append(f"{label}.{field} must be boolean")
                continue
            cleaned[field] = raw[field]
        snapshots[label] = cleaned

    baseline = snapshots["baseline"]
    candidate = snapshots["candidate"]
    required_slots = (*required_numeric_fields, *gate_fields, "activity_evidence")
    observed_required_slots = 0
    for label, snapshot in snapshots.items():
        for field in (*required_numeric_fields, *gate_fields):
            if field in snapshot:
                observed_required_slots += 1
            else:
                errors.append(f"{label}.{field} is required for the minimum evidence profile")
                limitations.append(f"{label} is missing required minimum evidence metric {field}.")
        if any(field in snapshot for field in activity_fields):
            observed_required_slots += 1
        else:
            errors.append(
                f"{label} requires active_particles or motion_delta/phase_delta for the minimum evidence profile"
            )
            limitations.append(f"{label} is missing required activity or phase-change evidence.")

    deltas = {
        field: round(float(candidate[field]) - float(baseline[field]), 6)
        for field in (*numeric_fields, "errors")
        if field in baseline and field in candidate
    }

    def improvement(field: str, *, lower_is_better: bool = False) -> float | None:
        if field not in baseline or field not in candidate:
            return None
        before = float(baseline[field])
        after = float(candidate[field])
        change = (after - before) / max(abs(before), abs(after), 1.0)
        if lower_is_better:
            change = -change
        return max(0.0, min(100.0, 50.0 + 50.0 * change))

    def ratio_improvement(numerator: str, denominator: str) -> float | None:
        required = (numerator, denominator)
        if any(field not in baseline or field not in candidate for field in required):
            return None
        before_denominator = float(baseline[denominator])
        after_denominator = float(candidate[denominator])
        if before_denominator <= 0 or after_denominator <= 0:
            return None
        before = float(baseline[numerator]) / before_denominator
        after = float(candidate[numerator]) / after_denominator
        change = (after - before) / max(abs(before), abs(after), 1e-9)
        return max(0.0, min(100.0, 50.0 + 50.0 * change))

    def lower_spread(maximum: str, mean: str) -> float | None:
        if any(field not in baseline or field not in candidate for field in (maximum, mean)):
            return None
        before = abs(float(baseline[maximum]) - float(baseline[mean]))
        after = abs(float(candidate[maximum]) - float(candidate[mean]))
        change = (before - after) / max(before, after, 1.0)
        return max(0.0, min(100.0, 50.0 + 50.0 * change))

    def supplied_score(field: str) -> float | None:
        if field not in candidate:
            return None
        return max(0.0, min(100.0, float(candidate[field])))

    term_samples: dict[str, list[tuple[str, float | None]]] = {
        "dynamics": [
            ("active_particles", improvement("active_particles")),
            ("active_fraction", ratio_improvement("active_particles", "part_count")),
            ("motion_delta", supplied_score("motion_delta")),
            ("phase_delta", supplied_score("phase_delta")),
            ("expected_transform", supplied_score("expected_transform")),
            ("trigger", supplied_score("trigger")),
        ],
        "readability": [
            ("tile_efficiency", ratio_improvement("occupied_tiles", "part_count")),
            ("visual_readability", supplied_score("visual_readability")),
        ],
        "stability": [
            ("temp_max", improvement("temp_max", lower_is_better=True)),
            ("pressure_max", improvement("pressure_max", lower_is_better=True)),
            ("temperature_spread", lower_spread("temp_max", "temp_mean")),
            ("pressure_spread", lower_spread("pressure_max", "pressure_mean")),
            ("containment", supplied_score("containment")),
        ],
        "composition": [
            ("occupied_tiles", improvement("occupied_tiles")),
        ],
        "budget": [
            ("part_count", improvement("part_count", lower_is_better=True)),
            ("frames", improvement("frames", lower_is_better=True)),
        ],
    }
    weights = {"dynamics": 30.0, "readability": 20.0, "stability": 20.0, "composition": 20.0, "budget": 10.0}
    terms: dict[str, dict[str, Any]] = {}
    weighted_total = 0.0
    available_weight = 0.0
    quality_weighted_total = 0.0
    quality_available_weight = 0.0
    for term, samples in term_samples.items():
        available = [{"metric": metric, "score": round(score, 3)} for metric, score in samples if score is not None]
        term_score = sum(item["score"] for item in available) / len(available) if available else None
        terms[term] = {
            "weight": weights[term],
            "score": None if term_score is None else round(term_score, 3),
            "metrics": available,
        }
        if term_score is not None:
            weighted_total += term_score * weights[term]
            available_weight += weights[term]
            if term != "budget":
                quality_weighted_total += term_score * weights[term]
                quality_available_weight += weights[term]

    hard_gates: dict[str, dict[str, bool]] = {}
    for label, snapshot in snapshots.items():
        minimum_evidence = all(field in snapshot for field in (*required_numeric_fields, *gate_fields))
        minimum_evidence = minimum_evidence and any(field in snapshot for field in activity_fields)
        hard_gates[label] = {
            "safety": snapshot.get("safety_ok") is True
            and snapshot.get("errors") == 0
            and snapshot.get("partial_mutation") is False,
            "readback": snapshot.get("truncated") is False and minimum_evidence,
            "minimum_evidence": minimum_evidence,
        }
    gates_passed = all(all(gates.values()) for gates in hard_gates.values())
    quality_score = (
        quality_weighted_total / quality_available_weight if quality_available_weight else 0.0
    )
    budget_score = terms["budget"]["score"]
    budget_penalty = 0.0 if budget_score is None else max(0.0, 50.0 - float(budget_score)) * weights["budget"] / 100.0
    score = round(max(0.0, quality_score - budget_penalty), 3)
    confidence = round(observed_required_slots / (2 * len(required_slots)), 3)
    activity_transform_delta = max(
        float(deltas.get("active_particles", 0.0)),
        float(candidate.get("motion_delta", 0.0)),
        float(candidate.get("phase_delta", 0.0)),
        float(candidate.get("expected_transform", 0.0)),
    )
    candidate_nonempty = float(candidate.get("part_count", 0.0)) > 0.0
    if available_weight < sum(weights.values()):
        limitations.append("Missing optional comparable metrics were omitted from scoring.")
    if not gates_passed:
        limitations.append("Acceptance is blocked because the complete minimum evidence, safety, or readback gates did not pass.")
    if confidence < 0.75:
        limitations.append("Acceptance is blocked because evidence confidence is below 0.75.")
    if not candidate_nonempty:
        limitations.append("Acceptance is blocked because candidate.part_count must be greater than zero.")
    if activity_transform_delta <= 0.0:
        limitations.append("Acceptance is blocked because candidate activity or transform delta must be greater than zero.")
    if quality_available_weight <= 0.0:
        limitations.append("Acceptance is blocked because budget evidence alone cannot establish quality.")
    accepted = (
        not errors
        and gates_passed
        and confidence >= 0.75
        and candidate_nonempty
        and activity_transform_delta > 0.0
        and quality_available_weight > 0.0
        and score >= 60.0
    )
    result = {
        "schema_version": "experiment-evaluate/v1",
        "ok": not errors,
        "score": score,
        "accepted": accepted,
        "score_breakdown": {
            "hard_gates": hard_gates,
            "terms": terms,
            "available_weight": available_weight,
            "quality_available_weight": quality_available_weight,
            "quality_score_before_budget_penalty": round(quality_score, 3),
            "budget_penalty": round(budget_penalty, 3),
            "acceptance_threshold": 60.0,
        },
        "deltas": deltas,
        "confidence": confidence,
        "errors": errors,
        "limitations": limitations,
        "correlation_id": correlation_id,
        "provenance": {
            "method": "bounded-relative-metric-comparison",
            "weights": weights,
            "budget_policy": "penalty-or-tiebreak-only",
            "read_only": True,
            "supplied_fields": {label: sorted(snapshot) for label, snapshot in snapshots.items()},
        },
    }
    return result

def _persist_experiment_feedback(record: dict[str, Any]) -> tuple[bool, str | None, int]:
    """Append one full-fidelity feedback event and confirm it can be read back."""
    event = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "request": "experiment_feedback",
        "action": "experiment_feedback",
        "correlation_id": str(record.get("correlation_id") or ""),
        "phase": "mcp",
        "ok": True,
        "error": None,
        "duration_ms": 0.0,
        "emitter_pid": os.getpid(),
        "runtime_pid": None,
        "pid": os.getpid(),
        "response_summary": {"experiment_feedback": strip_secrets(record)},
        "catalog_provenance": None,
    }
    line = json.dumps(event, ensure_ascii=True, separators=(",", ":")) + "\n"
    encoded = line.encode("utf-8")
    try:
        with _EXPERIMENT_FEEDBACK_LOCK:
            LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
            with LOG_PATH.open("ab") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            raw = LOG_PATH.read_bytes()
        if not raw.endswith(encoded):
            return False, "feedback write read-back mismatch", 0
        parsed = json.loads(raw[-len(encoded):].decode("utf-8"))
        confirmed = parsed.get("response_summary", {}).get("experiment_feedback")
        if confirmed != record:
            return False, "feedback write read-back content mismatch", 0
        return True, None, len(encoded)
    except (OSError, UnicodeError, json.JSONDecodeError, AttributeError, TypeError) as exc:
        return False, f"feedback persistence failed: {type(exc).__name__}", 0


# ---------------------------------------------------------------------------
# Build-lesson knowledge base.  Every non-obvious thing a build teaches is
# written here so the next caller -- including a smaller model -- reads the
# accumulated operating knowledge instead of rediscovering it by trial.
# ---------------------------------------------------------------------------

_BUILD_LESSONS_PATH = REPO_ROOT / "knowledge/build-lessons.jsonl"
_LESSON_TOPICS = (
    "thermal",
    "electrical",
    "containment",
    "coordinates",
    "rendering",
    "performance",
    "materials",
    "workflow",
)
_LESSON_SEVERITIES = ("critical", "major", "minor")


def _lesson_key(topic: str, title: str) -> str:
    return f"{topic.strip().lower()}::{' '.join(str(title).split()).lower()}"


def _load_build_lessons() -> list[dict[str, Any]]:
    if not _BUILD_LESSONS_PATH.is_file():
        return []
    records: list[dict[str, Any]] = []
    for line in _BUILD_LESSONS_PATH.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            parsed = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and parsed.get("key"):
            records.append(parsed)
    return records


def _write_build_lessons(records: list[dict[str, Any]]) -> int:
    _BUILD_LESSONS_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = "".join(json.dumps(record, sort_keys=True) + "\n" for record in records)
    _BUILD_LESSONS_PATH.write_text(payload, encoding="utf-8")
    return len(payload.encode("utf-8"))


def _record_build_lesson(arguments: dict[str, Any]) -> dict[str, Any]:
    """Append or reconfirm one durable build lesson."""

    topic = str(arguments.get("topic") or "").strip().lower()
    title = " ".join(str(arguments.get("title") or "").split())
    lesson = " ".join(str(arguments.get("lesson") or "").split())
    evidence = " ".join(str(arguments.get("evidence") or "").split())
    severity = str(arguments.get("severity") or "major").strip().lower()
    elements = [
        str(value).strip().upper()[:8]
        for value in (arguments.get("elements") or [])
        if str(value).strip()
    ][:12]

    errors: list[str] = []
    if topic not in _LESSON_TOPICS:
        errors.append(f"topic must be one of {list(_LESSON_TOPICS)}")
    if not 1 <= len(title) <= 120:
        errors.append("title must be 1-120 characters")
    if not 1 <= len(lesson) <= 800:
        errors.append("lesson must be 1-800 characters")
    if len(evidence) > 400:
        errors.append("evidence must be 400 characters or fewer")
    if severity not in _LESSON_SEVERITIES:
        errors.append(f"severity must be one of {list(_LESSON_SEVERITIES)}")
    if errors:
        return {"ok": False, "tool": "record_build_lesson", "errors": errors}

    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    key = _lesson_key(topic, title)
    records = _load_build_lessons()
    existing = next((record for record in records if record.get("key") == key), None)
    if existing is None:
        record = {
            "key": key,
            "topic": topic,
            "title": title,
            "lesson": lesson,
            "evidence": evidence,
            "severity": severity,
            "elements": elements,
            "confirmations": 1,
            "first_seen": now,
            "last_seen": now,
        }
        records.append(record)
        created = True
    else:
        existing["lesson"] = lesson or existing.get("lesson", "")
        if evidence:
            existing["evidence"] = evidence
        existing["severity"] = severity
        if elements:
            existing["elements"] = sorted(set(existing.get("elements", [])) | set(elements))[:12]
        existing["confirmations"] = int(existing.get("confirmations", 1)) + 1
        existing["last_seen"] = now
        record = existing
        created = False

    written = _write_build_lessons(records)
    return {
        "ok": True,
        "tool": "record_build_lesson",
        "created": created,
        "record": record,
        "total_lessons": len(records),
        "bytes_written": written,
        "path": str(_BUILD_LESSONS_PATH),
    }


def _build_lessons(arguments: dict[str, Any]) -> dict[str, Any]:
    """Return accumulated build lessons plus a ready-to-read briefing."""

    topic = str(arguments.get("topic") or "").strip().lower()
    query = " ".join(str(arguments.get("query") or "").split()).lower()
    try:
        limit = int(arguments.get("limit", 40))
    except (TypeError, ValueError):
        limit = 40
    limit = max(1, min(limit, 200))

    records = _load_build_lessons()
    if topic:
        if topic not in _LESSON_TOPICS:
            return {
                "ok": False,
                "tool": "build_lessons",
                "errors": [f"topic must be one of {list(_LESSON_TOPICS)}"],
            }
        records = [record for record in records if record.get("topic") == topic]
    if query:
        records = [
            record
            for record in records
            if query in json.dumps(record, sort_keys=True).lower()
        ]

    order = {name: index for index, name in enumerate(_LESSON_SEVERITIES)}
    records.sort(
        key=lambda record: (
            order.get(str(record.get("severity")), 9),
            -int(record.get("confirmations", 1)),
            str(record.get("topic")),
            str(record.get("title")),
        )
    )
    selected = records[:limit]
    briefing = "\n".join(
        "%d. [%s/%s] %s -- %s"
        % (
            index + 1,
            record.get("topic"),
            record.get("severity"),
            record.get("title"),
            record.get("lesson"),
        )
        for index, record in enumerate(selected)
    )
    return {
        "ok": True,
        "tool": "build_lessons",
        "count": len(selected),
        "total_lessons": len(_load_build_lessons()),
        "topics": list(_LESSON_TOPICS),
        "lessons": selected,
        "briefing": briefing,
        "path": str(_BUILD_LESSONS_PATH),
    }


# ---------------------------------------------------------------------------
# Runtime extension tools (powder_ext/).  Schemas and handlers live in their
# own package so the extension can evolve without touching this file's strict
# manifest contract.  Import is lazy and failure-tolerant: a broken extension
# package must never stop the base server from starting.
# ---------------------------------------------------------------------------

_EXT_CACHE: dict[str, Any] = {}


def _ext_registry() -> dict[str, Any]:
    """Load powder_ext once; on failure, remember the error instead of raising."""

    if _EXT_CACHE:
        return _EXT_CACHE
    try:
        ext_root = Path("D:/powder-toy")
        if str(ext_root) not in sys.path:
            sys.path.insert(0, str(ext_root))
        from powder_ext import schemas as ext_schemas  # noqa: WPS433
        from powder_ext import element_tools, colony_tools, admin_tools, people_tools, blueprint_tools, knowledge_tools, agent_tools, build_tools, realism_tools, rpg_tools  # noqa: WPS433
        handlers: dict[str, Any] = {}
        handlers.update(element_tools.HANDLERS)
        handlers.update(colony_tools.HANDLERS)
        handlers.update(admin_tools.HANDLERS)
        handlers.update(blueprint_tools.HANDLERS)
        handlers.update(agent_tools.HANDLERS)
        handlers.update(build_tools.HANDLERS)
        handlers.update(knowledge_tools.HANDLERS)
        handlers.update(people_tools.PEOPLE_HANDLERS)
        handlers.update(realism_tools.HANDLERS)
        handlers.update(rpg_tools.HANDLERS)
        _EXT_CACHE.update({
            "ok": True,
            "schemas": ext_schemas.TOOL_SCHEMAS,
            "descriptions": ext_schemas.TOOL_DESCRIPTIONS,
            "readonly": ext_schemas.TOOL_READONLY,
            "handlers": handlers,
            "error": None,
        })
    except Exception as exc:  # noqa: BLE001
        _EXT_CACHE.update({
            "ok": False, "schemas": {}, "descriptions": {}, "readonly": {},
            "handlers": {}, "error": f"{type(exc).__name__}: {exc}",
        })
    return _EXT_CACHE


def _ext_schema(name: str) -> dict[str, Any]:
    reg = _ext_registry()
    schema = reg["schemas"].get(name)
    if isinstance(schema, dict):
        return schema
    return {"type": "object", "additionalProperties": False, "properties": {}}


def _ext_description(name: str) -> str:
    reg = _ext_registry()
    desc = reg["descriptions"].get(name)
    if desc:
        return str(desc)
    return f"Extension tool {name} (extension package unavailable: {reg['error']})"


def _dispatch_extension(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    """Route one extension tool call to its powder_ext handler."""

    reg = _ext_registry()
    handler = reg["handlers"].get(name)
    if handler is None:
        return {
            "ok": False,
            "tool": name,
            "error": "extension handler unavailable",
            "detail": reg["error"] or f"no handler registered for {name}",
        }
    try:
        result = handler(arguments or {})
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "tool": name, "error": f"{type(exc).__name__}: {exc}"}
    if not isinstance(result, dict):
        return {"ok": False, "tool": name, "error": "handler returned a non-dict result"}
    result.setdefault("tool", name)
    return result


def _experiment_feedback(arguments: dict[str, Any]) -> dict[str, Any]:
    """Validate bounded feedback; call_tool persists it through the safe logger."""
    correlation_id = current_correlation_id() or new_correlation_id()
    errors: list[str] = []
    allowed = {"run_id", "score", "status", "failure", "feedback", "metadata"}
    unexpected = sorted(set(arguments) - allowed)
    if unexpected:
        errors.append(f"unsupported fields: {', '.join(unexpected)}")

    run_id = arguments.get("run_id")
    if run_id is not None and (not isinstance(run_id, str) or len(run_id) > 80):
        errors.append("run_id must be a string of at most 80 characters")
    score = arguments.get("score")
    if score is not None and (
        isinstance(score, bool)
        or not isinstance(score, (int, float))
        or not math.isfinite(float(score))
        or not 0.0 <= float(score) <= 100.0
    ):
        errors.append("score must be a finite number from 0 through 100")
    status = arguments.get("status")
    if status is not None and (not isinstance(status, str) or status not in {"keep", "discard", "crash", "checks_failed"}):
        errors.append("status must be keep, discard, crash, or checks_failed")
    for field, maximum in (("failure", 240), ("feedback", 1000)):
        value = arguments.get(field)
        if value is not None and (not isinstance(value, str) or len(value) > maximum):
            errors.append(f"{field} must be a string of at most {maximum} characters")
    metadata = arguments.get("metadata", {})
    if metadata is None:
        metadata = {}
    if not isinstance(metadata, dict) or len(metadata) > 16:
        errors.append("metadata must be an object with at most 16 fields")
        metadata = {}
    safe_metadata = strip_secrets(metadata)
    if not isinstance(safe_metadata, dict):
        safe_metadata = {}
    record = {
        "schema_version": "experiment-feedback/v1",
        "run_id": run_id,
        "score": None if score is None else float(score),
        "status": status,
        "failure": arguments.get("failure"),
        "feedback": arguments.get("feedback"),
        "metadata": safe_metadata,
        "correlation_id": correlation_id,
    }
    persisted = False
    persistence_error: str | None = None
    persisted_bytes = 0
    if not errors:
        persisted, persistence_error, persisted_bytes = _persist_experiment_feedback(record)
        if not persisted:
            errors.append(persistence_error or "feedback persistence failed")
    return {
        "schema_version": "experiment-feedback/v1",
        "tool": "experiment_feedback",
        "ok": not errors,
        "persisted": persisted,
        "persistence": "operation_log_direct_append" if persisted else "not_persisted",
        "persisted_bytes": persisted_bytes,
        "errors": errors,
        "record": record if persisted else None,
        "log_record": record if persisted else None,
        "provenance": {"read_only_simulation": True, "redaction": "powder_bridge.logging.strip_secrets"},
        "correlation_id": correlation_id,
    }


def _coordinate_helper(arguments: dict[str, Any]) -> dict[str, Any]:
    started = time.perf_counter()
    domain = arguments.get("domain")
    if domain not in {"pixel", "cell"}:
        return {
            "ok": False,
            "tool": "coordinate_helper",
            "error": "domain must be exactly pixel or cell",
        }
    bounds = _spatial_bounds(domain)
    has_x = "x" in arguments
    has_y = "y" in arguments
    coordinate: dict[str, Any] = {
        "space": domain,
        "x": None,
        "y": None,
        "valid": not has_x and not has_y,
        "bounds": bounds,
    }
    errors: list[str] = []
    if has_x != has_y:
        errors.append("x and y are required together")
    elif has_x:
        try:
            x = _strict_spatial_int(arguments["x"], "x")
            y = _strict_spatial_int(arguments["y"], "y")
            coordinate.update(x=x, y=y)
            coordinate["valid"] = (
                bounds["x"]["min"] <= x <= bounds["x"]["max"]
                and bounds["y"]["min"] <= y <= bounds["y"]["max"]
            )
            if not coordinate["valid"]:
                errors.append(f"coordinate outside {domain} bounds")
        except ValueError as exc:
            errors.append(str(exc))
    material_result: dict[str, Any] | None = None
    requested_material = arguments.get("material")
    if requested_material is not None:
        if not isinstance(requested_material, str) or not requested_material:
            errors.append("material must be a non-empty catalog identifier")
        else:
            catalog = _load_material_catalog()
            catalog_meta = {
                "path": str(_MATERIAL_CATALOG_PATH),
                "source_root": catalog.get("source_root"),
                "schema_version": None,
                "count": catalog.get("count"),
            }
            if not catalog.get("ok"):
                material_result = {
                    "requested": requested_material,
                    "resolved": False,
                    "reason": "material catalog unavailable",
                    "catalog": catalog_meta,
                }
                errors.append("material catalog unavailable")
            else:
                catalog_data = json.loads(_MATERIAL_CATALOG_PATH.read_text(encoding="utf-8"))
                catalog_meta["schema_version"] = catalog_data.get("schema_version")
                needle = requested_material.upper()
                matches = [
                    material
                    for material in catalog.get("materials", [])
                    if any(
                        needle == str(material.get(key, "")).upper()
                        for key in ("identifier", "lua_short", "lua_default", "name")
                    )
                ]
                if len(matches) != 1:
                    material_result = {
                        "requested": requested_material,
                        "resolved": False,
                        "reason": "unknown catalog identifier" if not matches else "ambiguous catalog identifier",
                        "matches": [
                            {
                                key: item.get(key)
                                for key in ("identifier", "lua_short", "lua_default", "name")
                                if item.get(key) is not None
                            }
                            for item in matches[:8]
                        ],
                        "catalog": catalog_meta,
                    }
                    errors.append(material_result["reason"])
                else:
                    match = matches[0]
                    material_result = {
                        "requested": requested_material,
                        "resolved": True,
                        "identifier": match.get("identifier"),
                        "lua_short": match.get("lua_short"),
                        "lua_default": match.get("lua_default"),
                        "name": match.get("name"),
                        "source_file": match.get("source_file"),
                        "catalog": catalog_meta,
                    }
    duration_ms = round((time.perf_counter() - started) * 1000, 3)
    result: dict[str, Any] = {
        "ok": not errors,
        "tool": "coordinate_helper",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "coordinate": coordinate,
        "provenance": {
            "coordinate_source": "D:/The-Powder-Toy/src/SimulationConfig.h",
            "material_source": "source_catalog",
            "catalog_path": str(_MATERIAL_CATALOG_PATH),
        },
        "duration_ms": duration_ms,
    }
    if material_result is not None:
        result["material"] = material_result
    if errors:
        result["errors"] = errors
    return result
def _capability_status() -> dict[str, Any]:
    tool_index = _load_tool_index()
    materials = _load_material_catalog()
    native = _load_native_catalog()
    manifest_check = _capability_manifest_check()
    source_map, source_map_findings = _manifest_source_map()
    tool_raw: dict[str, Any] = {}
    if _TOOL_INDEX_PATH.is_file():
        tool_raw = json.loads(_TOOL_INDEX_PATH.read_text(encoding="utf-8"))
    contract_counts = tool_raw.get("contract_counts") or {}
    records: list[dict[str, Any]] = []
    status_counts: dict[str, int] = {}
    for module in tool_raw.get("modules", []):
        source_file = str(module.get("file") or "")
        module_name = Path(source_file).name
        for contract in module.get("contracts", []):
            export_name = str(contract.get("export_name", ""))
            contract_info = contract.get("contract") or {}
            contract_status = str(contract_info.get("status", "unknown"))
            source_key = _canonical_source_id(source_file, export_name)
            manifest_record = source_map.get(source_key)
            wrapper_tool = manifest_record.get("mcp_name") if manifest_record else None
            declared_status = manifest_record.get("primary_status") if manifest_record else None
            if contract_status == "unknown":
                primary_status = "unknown"
            elif declared_status in _CAPABILITY_STATUSES:
                primary_status = declared_status
            else:
                primary_status = "catalog_only"
            is_wrapped = bool(wrapper_tool and declared_status == "wrapped")
            status_counts[primary_status] = status_counts.get(primary_status, 0) + 1
            records.append({
                "id": f"lua.export:{source_file}:{export_name}",
                "source_key": source_key,
                "primary_status": primary_status,
                "indexed": True,
                "cataloged": True,
                "wrapped": is_wrapped,
                "wrapper_tool": wrapper_tool,
                "runtime_available": None,
                "source_file": source_file,
                "export_name": export_name,
                "cpp_symbol": contract.get("cpp_symbol"),
                "contract_status": contract_status,
            })
    manifest_records = [
        {
            **record,
            "source_exports": list(record["source_exports"]),
        }
        for record in _CAPABILITY_MANIFEST
    ]
    wrapped = sorted(
        record["mcp_name"]
        for record in _CAPABILITY_MANIFEST
        if record["mcp_name"] is not None and record["primary_status"] == "wrapped"
    )
    gated = [
        {
            "id": record["id"],
            "reason": record["runtime_probe"].get("reason", "capability is gated"),
            "source_exports": list(record["source_exports"]),
        }
        for record in _CAPABILITY_MANIFEST
        if record["primary_status"] == "gated"
    ]
    structural_findings = [*source_map_findings, *manifest_check["findings"]]
    manifest_findings = [
        {
            **finding,
            "finding_code": finding.get("code"),
        }
        for finding in structural_findings
    ]
    findings = [
        {
            "finding_code": "RUNTIME_LIST_ELEMENTS_CAPPED",
            "detail": "runtime listElements remains capped at 40",
        },
        {
            "finding_code": "MOUNTED_MCP_MAY_BE_STALE",
            "detail": "restart session to expose latest source tool list",
        },
        *manifest_findings,
    ]
    return {
        "ok": bool(tool_index.get("ok") and materials.get("ok") and native.get("ok") and manifest_check["ok"]),
        "tool": "capability_status",
        "report_type": "powder_toy_capability_completeness",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "runtime": {
            "pids": [item["pid"] for item in _powder_processes()],
            "port": 9876,
            "available": _port_listening(),
            "source_runtime_separated": True,
        },
        "counts": {
            "lua_modules": len(tool_raw.get("modules", [])),
            "lua_exports": contract_counts.get("exports"),
            "lua_source_body_parsed": contract_counts.get("source_body_parsed"),
            "lua_unknown": contract_counts.get("unknown"),
            "materials": materials.get("count"),
            "native_tools": (native.get("counts") or {}).get("tools"),
            "walls": (native.get("counts") or {}).get("walls"),
            "native_constants": (native.get("counts") or {}).get("constants"),
            "manifest_tools": manifest_check["manifest_tool_count"],
            "declared_tools": manifest_check["declaration_tool_count"],
            "dispatch_branches": manifest_check["dispatch_branch_count"],
            "manifest_source_exports": manifest_check["source_export_count"],
            "source_records": len(records),
            "records": len(records),
        },
        "status_counts": status_counts,
        "records": records,
        "manifest_records": manifest_records,
        "wrapped": wrapped,
        "gated": gated,
        "unknown": [
            {"id": "lua_bit/socket_unknown_contracts", "reason": "source signature unresolved"}
        ] if contract_counts.get("unknown") else [],
        "findings": findings,
        "manifest_findings": manifest_findings,
        "provenance": {
            "tool_index": str(_TOOL_INDEX_PATH),
            "material_index": str(_MATERIAL_CATALOG_PATH),
            "native_catalog": str(_NATIVE_CATALOG_PATH),
            "manifest": "in-process declarative capability manifest",
        },
    }



_TOKEN_SIDECAR = Path("D:/The-Powder-Toy/build/powder-bridge.token")
_MATERIAL_CATALOG_PATH = REPO_ROOT / "POWDER_TOY_MATERIAL_INDEX.json"
_TOOL_INDEX_PATH = REPO_ROOT / "POWDER_TOY_TOOL_INDEX.json"
_NATIVE_CATALOG_PATH = REPO_ROOT / "POWDER_TOY_NATIVE_CATALOG.json"
_SECRET_EVENT_KEYS = frozenset({"token", "authorization", "password", "secret"})
_EXPERIMENT_FEEDBACK_LOCK = threading.Lock()


def _check(name: str, ok: bool, detail: str, source: str) -> dict[str, Any]:
    return {"name": name, "ok": bool(ok), "detail": detail, "source": source}


def _powder_processes() -> list[dict[str, Any]]:
    procs: list[dict[str, Any]] = []
    for proc in psutil.process_iter(["pid", "name", "cmdline"]):
        try:
            if "powder" in (proc.info["name"] or "").lower():
                procs.append(
                    {
                        "pid": proc.info["pid"],
                        "name": proc.info["name"],
                        "cmdline": proc.info.get("cmdline"),
                    }
                )
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return procs


def _port_listening(host: str = "127.0.0.1", port: int = 9876) -> bool:
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def _probe_error(exc: Exception) -> str:
    return f"{type(exc).__name__}: {exc}"


def _strip_secret_keys(event: dict[str, Any]) -> dict[str, Any]:
    cleaned = strip_secrets(event)
    if not isinstance(cleaned, dict):
        return {}
    for key in list(cleaned):
        if str(key).lower() in _SECRET_EVENT_KEYS or "token" in str(key).lower():
            cleaned.pop(key, None)
    return cleaned


def _catalog_match_count(items: list[Any], query: str | None) -> int | None:
    if not query:
        return None
    needle = query.lower()
    return sum(1 for item in items if needle in json.dumps(item).lower())


def _catalog_file_meta(path: Path, *, missing: str) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    if not path.is_file():
        return None, {
            "path": str(path),
            "exists": False,
            "schema_version": None,
            "source_root": None,
            "error": missing,
            "runtime_available": None,
        }
    data = json.loads(path.read_text(encoding="utf-8"))
    return data, {
        "path": str(path),
        "exists": True,
        "schema_version": data.get("schema_version"),
        "source_root": data.get("source_root"),
        "runtime_available": None,
    }


def _runtime_diagnostics() -> dict[str, Any]:
    started = time.perf_counter()
    correlation_id = current_correlation_id()
    if correlation_id is None:
        correlation_id, _owned_cid = bind_correlation_id()
    checks: list[dict[str, Any]] = []
    procs = _powder_processes()
    port_open = _port_listening()
    token_present = _TOKEN_SIDECAR.is_file()
    checks.append(_check(
        "token_sidecar_present",
        token_present,
        "token file exists" if token_present else "token file missing",
        str(_TOKEN_SIDECAR),
    ))
    checks.append(_check(
        "port_listening",
        port_open,
        "127.0.0.1:9876",
        "socket",
    ))
    pids = [item["pid"] for item in procs]
    checks.append(_check(
        "powder_process",
        bool(pids),
        f"pid={pids[0]}" if pids else "no powder.exe",
        "psutil",
    ))
    checks.append(_check(
        "single_powder_process",
        len(pids) == 1,
        f"pids={pids}" if pids else "no powder.exe",
        "psutil",
    ))
    list_count = None
    part_count = None
    field_value = None
    try:
        elements = get_client().list_elements()
        list_count = elements.get("count")
        checks.append(_check("bridge_list_elements", True, f"count={list_count}", "listElements"))
    except (PowderAPIError, PowderConnectionError, OSError, ValueError) as exc:
        checks.append(_check("bridge_list_elements", False, _probe_error(exc), "listElements"))
    try:
        state = get_client().get_simulation_state()
        part_count = state.get("partCount")
        if part_count is None and isinstance(state.get("state"), dict):
            part_count = state["state"].get("partCount")
        checks.append(_check("bridge_simulation_state", True, f"partCount={part_count}", "getSimulationState"))
    except (PowderAPIError, PowderConnectionError, OSError, ValueError) as exc:
        checks.append(_check("bridge_simulation_state", False, _probe_error(exc), "getSimulationState"))
    try:
        field = get_client().get_field(field="temp", x=0, y=0)
        field_value = field.get("value")
        checks.append(_check("bridge_get_field_temp", True, f"value={field_value}", "getField"))
    except (PowderAPIError, PowderConnectionError, OSError, ValueError) as exc:
        checks.append(_check("bridge_get_field_temp", False, _probe_error(exc), "getField"))
    checks.append(_check(
        "execute_lua_blocked",
        "executeLua" not in ALLOWED_GENERIC_ACTIONS,
        "not in ALLOWED_GENERIC_ACTIONS",
        "powder_toy_mcp.py",
    ))
    log_info = log_status()
    checks.append(_check(
        "operation_log_readable",
        bool(log_info.get("ok")),
        f"path={log_info.get('log_path')} bytes={log_info.get('bytes')}",
        "log",
    ))
    duration_ms = round((time.perf_counter() - started) * 1000, 3)
    result = {
        "ok": all(item["ok"] for item in checks),
        "tool": "runtime_diagnostics",
        "correlation_id": correlation_id,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "duration_ms": duration_ms,
        "client_pid": os.getpid(),
        "runtime": {
            "pids": pids,
            "port": 9876,
            "port_open": port_open,
            "bridge_alive": all(
                item["ok"]
                for item in checks
                if item["name"] in {"bridge_list_elements", "bridge_simulation_state", "bridge_get_field_temp"}
            ),
            "token_configured": token_present,
        },
        "checks": checks,
    }
    bound_cid = current_correlation_id()
    matched = [event for event in read_events(30) if event.get("correlation_id") == correlation_id]
    result["correlation_roundtrip"] = {
        "correlation_id": correlation_id,
        "bound": bound_cid,
        "matched_events": len(matched),
        "client_events": sum(1 for event in matched if event.get("phase") == "client"),
        "ok": bool(bound_cid == correlation_id) and any(event.get("phase") == "client" for event in matched),
    }
    result["verification_capabilities"] = {
        "identity": ["create_particle", "kill_particle", "change_particle_type", "set_particle_property", "set_simulation_modes", "set_field_region", "clear_sim"],
        "count_delta": ["place_element", "place_element_line"],
        "stamp_catalog": ["save_stamp", "load_stamp", "delete_stamp"],
        "absent": sorted(_ABSENT_READBACK_TOOLS),
        "executeLua": False,
    }
    emit(
        request="runtime_diagnostics",
        action="runtime_diagnostics",
        correlation_id=correlation_id,
        phase="mcp",
        ok=bool(result["ok"]),
        error=None if result["ok"] else "one or more checks failed",
        duration_ms=duration_ms,
        response_summary=summarize_response(result),
        pid=os.getpid(),
    )
    return result


def _catalog_status(query: str | None = None, include_runtime: bool = True) -> dict[str, Any]:
    started = time.perf_counter()
    correlation_id = current_correlation_id()
    if correlation_id is None:
        correlation_id, _owned_cid = bind_correlation_id()
    materials_data, materials = _catalog_file_meta(_MATERIAL_CATALOG_PATH, missing="material catalog missing")
    if materials_data is not None:
        material_rows = materials_data.get("materials", [])
        materials["count"] = materials_data.get("count", len(material_rows))
        match_count = _catalog_match_count(material_rows, query)
        if match_count is not None:
            materials["match_count"] = match_count
    tools_data, tools = _catalog_file_meta(_TOOL_INDEX_PATH, missing="tool index missing")
    if tools_data is not None:
        modules = tools_data.get("modules", [])
        tools["count"] = len(modules)
        tools["contract_counts"] = tools_data.get("contract_counts")
        match_count = _catalog_match_count(modules, query)
        if match_count is not None:
            tools["match_count"] = match_count
    native_data, native = _catalog_file_meta(_NATIVE_CATALOG_PATH, missing="native catalog missing")
    if native_data is not None:
        native["source_root"] = native_data.get("source_root")
        native["counts"] = native_data.get("counts") or {
            "native_tools": len(native_data.get("native_tools", [])),
            "walls": len(native_data.get("walls", [])),
            "constants": len(native_data.get("constants", [])),
        }
        if query:
            native["match_counts"] = {
                "tools": _catalog_match_count(native_data.get("native_tools", []), query),
                "walls": _catalog_match_count(native_data.get("walls", []), query),
                "constants": _catalog_match_count(native_data.get("constants", []), query),

            }
    runtime: dict[str, Any] = {
        "available": None,
        "list_elements_count": None,
        "error": None if include_runtime else "skipped",
    }
    if include_runtime:
        try:
            elements = get_client().list_elements()
            runtime["available"] = True
            runtime["list_elements_count"] = elements.get("count")
        except (PowderAPIError, PowderConnectionError, OSError, ValueError) as exc:
            runtime["available"] = False
            runtime["error"] = _probe_error(exc)
    duration_ms = round((time.perf_counter() - started) * 1000, 3)
    result = {
        "ok": bool(materials.get("exists") and tools.get("exists") and native.get("exists")),
        "tool": "catalog_status",
        "correlation_id": correlation_id,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "duration_ms": duration_ms,
        "catalogs": {
            "materials": materials,
            "tools": tools,
            "native": native,
        },
        "runtime": runtime,
    }
    emit(
        request="catalog_status",
        action="catalog_status",
        correlation_id=correlation_id,
        phase="mcp",
        ok=bool(result["ok"]),
        error=None if result["ok"] else "catalog file missing",
        duration_ms=duration_ms,
        response_summary=summarize_response(result),
        pid=os.getpid(),
        catalog_provenance={
            "materials": {"path": materials.get("path"), "source_root": materials.get("source_root"), "schema_version": materials.get("schema_version"), "count": materials.get("count")},
            "tools": {"path": tools.get("path"), "source_root": tools.get("source_root"), "schema_version": tools.get("schema_version"), "count": tools.get("count")},
            "native": {"path": native.get("path"), "schema_version": native.get("schema_version"), "counts": native.get("counts")},
        },
    )
    return result

def _read_feedback_events(limit: int) -> list[dict[str, Any]]:
    if limit < 1 or not LOG_PATH.is_file():
        return []
    try:
        rows: list[dict[str, Any]] = []
        for raw in LOG_PATH.read_text(encoding="utf-8").splitlines()[-limit:]:
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict) and event.get("action") == "experiment_feedback":
                cleaned = _strip_secret_keys(event)
                if cleaned:
                    rows.append(cleaned)
        return rows
    except (OSError, UnicodeError):
        return []

def _read_operation_log(
    limit: int = 50,
    action: str | None = None,
    correlation_id: str | None = None,
    ok: bool | None = None,
) -> dict[str, Any]:
    bound = max(1, min(int(limit), 200))
    scan = 1000 if (action or correlation_id is not None or ok is not None) else bound
    events = []
    source_events = _read_feedback_events(scan) if action == "experiment_feedback" else read_events(scan)
    for event in source_events:
        cleaned = _strip_secret_keys(event)
        if action and str(cleaned.get("action") or cleaned.get("request") or "") != action:
            continue
        if correlation_id and str(cleaned.get("correlation_id") or "") != correlation_id:
            continue
        if ok is not None and bool(cleaned.get("ok")) != bool(ok):
            continue
        events.append(cleaned)
    events = events[-bound:]
    status = log_status()
    return {
        "correlation_id": current_correlation_id() or new_correlation_id(),
        "ok": True,
        "tool": "read_operation_log",
        "path": status.get("log_path", str(LOG_PATH)),
        "bytes": status.get("bytes", 0),
        "limit": bound,
        "returned": len(events),
        "events": events,
    }



_MUTATION_TOOLS = frozenset({
    "step_sim", "place_element", "place_element_line", "place_wall_line",
    "place_wall_box", "apply_native_tool_box", "place_deco_box", "place_deco_line",
    "place_deco_point", "save_stamp", "load_stamp", "delete_stamp", "create_particle",
    "change_particle_type", "set_particle_property", "kill_particle",
    "set_simulation_modes", "set_custom_gravity", "set_edge_pressure",
    "set_edge_velocity", "set_field_region", "clear_sim", "draw_project",
    "draw_house", "rapid_build", "blueprint_build", "build_stage", "run_test", "run_pipeline",
    "realism_apply", "rpg_hub", "rpg_reload", "rpg_screenshot", "rpg_lua",
})
_ABSENT_READBACK_TOOLS = frozenset({
    "place_wall_line", "place_wall_box", "apply_native_tool_box", "place_deco_box",
    "place_deco_line", "place_deco_point", "set_custom_gravity", "set_edge_pressure",
    "set_edge_velocity", "step_sim",
})


def _evidence(
    requested: dict[str, Any],
    readback: dict[str, Any] | None,
    postcondition_ok: bool,
    *,
    strength: str | None = None,
    reason: str | None = None,
) -> dict[str, Any]:
    ok = bool(postcondition_ok) and readback is not None
    out: dict[str, Any] = {"requested": requested, "readback": readback, "postcondition_ok": ok}
    if strength is not None:
        out["strength"] = strength
    if reason and not ok:
        out["reason"] = reason
    return out


def _attach(
    result: dict[str, Any] | None,
    cid: str,
    evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    env = dict(result or {})
    env.pop("token", None)
    env["correlation_id"] = cid
    if evidence is not None:
        env["evidence"] = evidence
    cleaned = strip_secrets(env)
    if not isinstance(cleaned, dict):
        cleaned = {}
    cleaned["correlation_id"] = cid
    attached = cleaned.get("evidence")
    if evidence is not None:
        if not isinstance(attached, dict):
            attached = {}
            cleaned["evidence"] = attached
        attached["postcondition_ok"] = bool(evidence.get("postcondition_ok"))
    return cleaned


def _requested(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    cleaned = strip_secrets(dict(arguments or {}))
    if not isinstance(cleaned, dict):
        cleaned = {}
    requested: dict[str, Any] = {}
    for key, value in cleaned.items():
        lowered = str(key).lower()
        if lowered in _SECRET_EVENT_KEYS or "token" in lowered:
            continue
        if lowered == "tool":
            requested["deco_tool"] = value
            continue
        requested[str(key)] = value
    requested["tool"] = name
    return requested


def _safe_read(fn: Any) -> tuple[dict[str, Any] | None, str | None]:
    try:
        result = fn()
    except PowderAPIError as exc:
        return {"ok": False, "action": exc.action, "error": exc.error}, None
    except (PowderConnectionError, OSError, ValueError, TypeError, json.JSONDecodeError):
        return None, "transport_error"
    if not isinstance(result, dict):
        return None, "transport_error"
    cleaned = strip_secrets(result)
    if not isinstance(cleaned, dict):
        return None, "transport_error"
    cleaned.pop("token", None)
    return cleaned, None


def _part_count(state: dict[str, Any] | None) -> int | None:
    if not isinstance(state, dict):
        return None
    value = state.get("partCount")
    if value is None and isinstance(state.get("state"), dict):
        value = state["state"].get("partCount")
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _finite_close(observed: Any, requested: Any) -> bool:
    try:
        left = float(observed)
        right = float(requested)
    except (TypeError, ValueError):
        return False
    return math.isfinite(left) and math.isfinite(right) and abs(left - right) <= max(0.05, 0.001 * abs(right))


def _particle_snapshot(readback: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(readback, dict):
        return None
    particle = readback.get("particle")
    if isinstance(particle, dict):
        return particle
    if any(key in readback for key in ("id", "type", "x", "y")):
        return readback
    return None


def _stamp_names(readback: dict[str, Any] | None) -> set[str] | None:
    if not isinstance(readback, dict):
        return None
    items = readback.get("stamps", readback.get("names"))
    if not isinstance(items, list):
        return None
    names: set[str] = set()
    for item in items:
        if isinstance(item, str):
            names.add(item)
        elif isinstance(item, dict) and item.get("name") is not None:
            names.add(str(item["name"]))
    return names


def _build_mutation_evidence(
    name: str,
    arguments: dict[str, Any],
    payload: dict[str, Any],
    before_state: dict[str, Any] | None,
) -> dict[str, Any]:
    requested = _requested(name, arguments)
    if name in _ABSENT_READBACK_TOOLS:
        return _evidence(requested, None, False, strength="absent", reason="no_reader")
    client = get_client()
    if name == "create_particle":
        particle_id = payload.get("id")
        if payload.get("ok") is False or particle_id is None:
            return _evidence(requested, None, False, reason="mismatch")
        readback, err = _safe_read(lambda: client.get_particle(int(particle_id)))
        if err:
            return _evidence(requested, None, False, reason=err)
        particle = _particle_snapshot(readback)
        if not particle:
            return _evidence(requested, readback, False, reason="mismatch")
        try:
            type_ok = int(particle.get("type")) >= 0
        except (TypeError, ValueError):
            type_ok = False
        id_ok = particle.get("id") == particle_id
        modes, _modes_err = _safe_read(client.get_simulation_modes)
        paused = None if not modes else modes.get("paused")
        pos_ok = True
        reason = None
        if paused is True:
            try:
                pos_ok = (
                    abs(float(particle.get("x")) - float(arguments["x"])) <= 0.51
                    and abs(float(particle.get("y")) - float(arguments["y"])) <= 0.51
                )
            except (TypeError, ValueError):
                pos_ok = False
        elif paused is False:
            reason = "unpaused_position_skipped"
        ok = bool(id_ok and type_ok and pos_ok)
        return _evidence(requested, readback, ok, strength="identity", reason=None if ok else (reason or "mismatch"))
    if name == "kill_particle":
        readback, err = _safe_read(lambda: client.get_particle(int(arguments["particle_id"])))
        if err:
            return _evidence(requested, None, False, reason=err)
        error = str((readback or {}).get("error") or "").lower()
        if readback and "unknown particle" in error:
            return _evidence(
                requested,
                {"action": "getParticle", "id": arguments["particle_id"], "error": readback.get("error")},
                True,
                strength="identity",
            )
        return _evidence(requested, readback, False, reason="mismatch")
    if name == "change_particle_type":
        readback, err = _safe_read(lambda: client.get_particle(int(arguments["particle_id"])))
        if err:
            return _evidence(requested, None, False, reason=err)
        particle = _particle_snapshot(readback)
        resolved = payload.get("element")
        if resolved is None or particle is None:
            return _evidence(requested, readback, False, reason="no_resolved_type")
        ok = particle.get("type") == resolved
        return _evidence(requested, readback, ok, strength="identity", reason=None if ok else "mismatch")
    if name == "set_particle_property":
        readback, err = _safe_read(lambda: client.get_particle(int(arguments["particle_id"])))
        if err:
            return _evidence(requested, None, False, reason=err)
        prop = str(arguments.get("property") or "")
        particle = _particle_snapshot(readback) or {}
        if prop not in {"temp", "life", "vx", "vy"} or prop not in particle:
            return _evidence(requested, readback, False, reason="property_not_in_snapshot")
        ok = _finite_close(particle.get(prop), arguments.get("value"))
        return _evidence(requested, readback, ok, strength="identity", reason=None if ok else "mismatch")
    if name in {"place_element", "place_element_line"}:
        after, err = _safe_read(client.get_simulation_state)
        if err or after is None:
            return _evidence(requested, None, False, reason=err or "count_unavailable")
        before_count = _part_count(before_state)
        after_count = _part_count(after)
        readback = {
            "action": "getSimulationState",
            "before": before_count,
            "after": after_count,
            "delta": None if before_count is None or after_count is None else after_count - before_count,
        }
        if before_count is None or after_count is None:
            return _evidence(requested, readback, False, strength="count-delta", reason="count_unavailable")
        ok = after_count > before_count
        return _evidence(requested, readback, ok, strength="count-delta", reason=None if ok else "mismatch")
    if name == "set_simulation_modes":
        readback, err = _safe_read(client.get_simulation_modes)
        if err or not readback:
            return _evidence(requested, None, False, reason=err or "no_reader")
        mapping = {"edge_mode": "edgeMode", "gravity_mode": "gravityMode", "air_mode": "airMode", "paused": "paused"}
        checked = False
        for arg_name, lua_name in mapping.items():
            if arguments.get(arg_name) is None:
                continue
            checked = True
            if readback.get(lua_name) != arguments.get(arg_name):
                return _evidence(requested, readback, False, strength="identity", reason="mismatch")
        return _evidence(requested, readback, checked, strength="identity", reason=None if checked else "mismatch")
    if name == "set_field_region":
        field = str(arguments.get("field") or "").lower()
        if field in {"temp", "temperature", "ambientheat"}:
            normalized = "temp"
        elif field == "pressure":
            normalized = "pressure"
        else:
            return _evidence(requested, None, False, strength="absent", reason="no_reader")
        readback, err = _safe_read(lambda: client.get_field(normalized, x=int(arguments["x1"]), y=int(arguments["y1"])))
        if err or not readback:
            return _evidence(requested, None, False, reason=err or "no_reader")
        ok = _finite_close(readback.get("value"), arguments.get("value"))
        return _evidence(requested, readback, ok, strength="identity", reason=None if ok else "mismatch")
    if name == "clear_sim":
        readback, err = _safe_read(client.get_simulation_state)
        if err or not readback:
            return _evidence(requested, None, False, reason=err or "count_unavailable")
        ok = _part_count(readback) == 0
        return _evidence(requested, readback, ok, strength="identity", reason=None if ok else "mismatch")
    if name in {"save_stamp", "load_stamp", "delete_stamp"}:
        readback, err = _safe_read(client.list_stamps)
        if err or not readback:
            return _evidence(requested, None, False, reason=err or "no_reader")
        names = _stamp_names(readback)
        stamp = payload.get("name") or arguments.get("name")
        if names is None or stamp is None:
            return _evidence(requested, readback, False, strength="stamp-catalog", reason="mismatch")
        present = str(stamp) in names
        ok = (not present) if name == "delete_stamp" else present
        return _evidence(requested, readback, ok, strength="stamp-catalog", reason=None if ok else "mismatch")
    if name in {"draw_project", "draw_house", "rapid_build"}:
        readback, err = _safe_read(client.get_simulation_state)
        if err:
            return _evidence(requested, None, False, reason=err)
        summary = {
            "action": "getSimulationState",
            "partCount": _part_count(readback) if readback else None,
            "succeeded": payload.get("succeeded"),
            "failed": payload.get("failed"),
            "skipped": payload.get("skipped"),
            "partial_mutation": payload.get("partial_mutation"),
        }
        return _evidence(requested, summary, False, strength="absent", reason="no_reader")
    return _evidence(requested, None, False, strength="absent", reason="no_reader")


def _coerce_tool_payload(text: str) -> dict[str, Any]:
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        lowered = text.lower()
        failed = lowered.startswith("tool error:") or lowered.startswith("unknown tool") or "refused" in lowered
        return {"ok": not failed, "message": text}
    if isinstance(parsed, dict):
        return parsed
    return {"ok": True, "result": parsed}


def _finalize_mcp_result(
    name: str,
    arguments: dict[str, Any],
    result: list[TextContent],
    cid: str,
    before_state: dict[str, Any] | None,
) -> list[TextContent]:
    text = result[0].text if result else json.dumps({"ok": False, "error": "empty tool result"})
    payload = _coerce_tool_payload(text)
    evidence = _build_mutation_evidence(name, arguments, payload, before_state) if name in _MUTATION_TOOLS else None
    if evidence is not None and payload.get("ok") is False:
        evidence["postcondition_ok"] = False
        evidence.setdefault("reason", "mismatch")
    return [TextContent(type="text", text=json.dumps(_attach(payload, cid, evidence)))]
# --- Tools ---
async def _legacy_tool_declarations() -> list[Tool]:
    experiment_metrics_schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "part_count": {"type": "integer", "minimum": 0, "maximum": 1000000000000},
            "active_particles": {"type": "integer", "minimum": 0, "maximum": 1000000000000},
            "occupied_tiles": {"type": "integer", "minimum": 0, "maximum": 1000000000000},
            "temp_mean": {"type": "number", "minimum": -1000000000000, "maximum": 1000000000000},
            "temp_max": {"type": "number", "minimum": -1000000000000, "maximum": 1000000000000},
            "pressure_mean": {"type": "number", "minimum": -1000000000000, "maximum": 1000000000000},
            "pressure_max": {"type": "number", "minimum": -1000000000000, "maximum": 1000000000000},
            "errors": {"type": "integer", "minimum": 0, "maximum": 1000000},
            "truncated": {"type": "boolean"},
            "partial_mutation": {"type": "boolean"},
            "safety_ok": {"type": "boolean"},
            "frames": {"type": "integer", "minimum": 0, "maximum": 1000000000000},
            "motion_delta": {"type": "number", "minimum": -1000000000000, "maximum": 1000000000000},
            "phase_delta": {"type": "number", "minimum": -1000000000000, "maximum": 1000000000000},
            "visual_readability": {"type": "number", "minimum": 0, "maximum": 100},
            "expected_transform": {"type": "number", "minimum": 0, "maximum": 100},
            "containment": {"type": "number", "minimum": 0, "maximum": 100},
            "trigger": {"type": "number", "minimum": 0, "maximum": 100},
        },
    }
    return [
        Tool(
            name="launch_powder_toy",
            description="Launch Powder Toy with correct ddir (two-arg form) so autorun and HTTP bridge start. Returns launch output.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="rebuild_powder_toy",
            description=(
                "Regenerate autorun.lua from bridge_src, kill the running build/powder.exe "
                "(never touches powder_play.exe), rebuild it with MSVC via ninja, and relaunch "
                "it detached on success. Replaces the manual vcvars/ninja/taskkill dance. On a "
                "build failure, powder.exe is NOT relaunched and the response carries the "
                "compiler output tail so the failure can be diagnosed."
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="powder_status",
            description="Report running powder.exe PIDs, cmdlines, and whether 9876 is listening.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="health_check",
            description="Flat health: is the HTTP bridge reachable? Calls listElements.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="execute_action",
            description="Read-only bridge query. Allowed actions are getField, listElements, and getSimulationState.",
            inputSchema={
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["getField", "listElements", "getSimulationState"]},
                    "params": {"type": "object"},
                },
                "required": ["action"],
            },
        ),
        # Typed simulation tools
        Tool(
            name="step_sim",
            description="Advance simulation by N frames.",
            inputSchema={
                "type": "object",
                "properties": {"n": {"type": "integer", "default": 1}},
            },
        ),
        Tool(
            name="place_element",
            description="Place element in rectangle (box).",
            inputSchema={
                "type": "object",
                "properties": {
                    "element": {"type": "string"},
                    "x1": {"type": "integer"},
                    "y1": {"type": "integer"},
                    "x2": {"type": "integer"},
                    "y2": {"type": "integer"},
                },
                "required": ["element", "x1", "y1", "x2", "y2"],
            },
        ),
        Tool(
            name="place_element_line",
            description="Place a catalog material along a bounded pixel-space line.",
            inputSchema={
                "type": "object",
                "properties": {
                    "element": {"type": "string"},
                    "x1": {"type": "integer"}, "y1": {"type": "integer"},
                    "x2": {"type": "integer"}, "y2": {"type": "integer"},
                },
                "required": ["element", "x1", "y1", "x2", "y2"],
            },
        ),
        Tool(
            name="place_wall_line",
            description="Place a source-indexed wall along a bounded pixel-space line.",
            inputSchema={
                "type": "object",
                "properties": {
                    "wall": {"type": "string"},
                    "x1": {"type": "integer"}, "y1": {"type": "integer"},
                    "x2": {"type": "integer"}, "y2": {"type": "integer"},
                },
                "required": ["wall", "x1", "y1", "x2", "y2"],
            },
        ),
        Tool(
            name="place_wall_box",
            description="Place a source-indexed wall type in a pixel-space rectangle.",
            inputSchema={
                "type": "object",
                "properties": {
                    "wall": {"type": "string"},
                    "x1": {"type": "integer"},
                    "y1": {"type": "integer"},
                    "x2": {"type": "integer"},
                    "y2": {"type": "integer"},
                },
                "required": ["wall", "x1", "y1", "x2", "y2"],
            },
        ),
        Tool(
            name="apply_native_tool_box",
            description="Apply a source-indexed native editor tool in a pixel-space rectangle.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tool": {"type": "string"},
                    "x1": {"type": "integer"},
                    "y1": {"type": "integer"},
                    "x2": {"type": "integer"},
                    "y2": {"type": "integer"},
                    "strength": {"type": "number", "default": 1.0},
                    "brush": {"type": "integer", "default": 0},
                    "rx": {"type": "integer", "default": 0},
                    "ry": {"type": "integer", "default": 0},
                },
                "required": ["tool", "x1", "y1", "x2", "y2"],
            },
        ),
        Tool(
            name="place_deco_box",
            description="Apply a bounded decoration color/tool to a pixel rectangle.",
            inputSchema={
                "type": "object",
                "properties": {
                    "x1": {"type": "integer"}, "y1": {"type": "integer"},
                    "x2": {"type": "integer"}, "y2": {"type": "integer"},
                    "r": {"type": "integer"}, "g": {"type": "integer"},
                    "b": {"type": "integer"}, "a": {"type": "integer", "default": 255},
                    "tool": {"type": "integer", "default": 0},
                },
                "required": ["x1", "y1", "x2", "y2", "r", "g", "b"],
            },
        ),
        Tool(
            name="place_deco_line",
            description="Apply decoration along a bounded pixel-space line.",
            inputSchema={
                "type": "object",
                "properties": {
                    "x1": {"type": "integer"}, "y1": {"type": "integer"},
                    "x2": {"type": "integer"}, "y2": {"type": "integer"},
                    "r": {"type": "integer"}, "g": {"type": "integer"},
                    "b": {"type": "integer"}, "a": {"type": "integer", "default": 255},
                    "tool": {"type": "integer", "default": 0},
                    "brush": {"type": "integer", "default": 0},
                    "rx": {"type": "integer", "default": 5},
                    "ry": {"type": "integer", "default": 5},
                },
                "required": ["x1", "y1", "x2", "y2", "r", "g", "b"],
            },
        ),
        Tool(
            name="place_deco_point",
            description="Apply a bounded decoration brush point at one pixel-space coordinate.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "x": {"type": "integer", "minimum": 0, "maximum": 611},
                    "y": {"type": "integer", "minimum": 0, "maximum": 383},
                    "r": {"type": "integer", "minimum": 0, "maximum": 255, "default": 255},
                    "g": {"type": "integer", "minimum": 0, "maximum": 255, "default": 255},
                    "b": {"type": "integer", "minimum": 0, "maximum": 255, "default": 255},
                    "a": {"type": "integer", "minimum": 0, "maximum": 255, "default": 255},
                    "tool": {"type": "integer", "minimum": 0, "maximum": 6, "default": 0},
                    "brush": {"type": "integer", "minimum": 0, "default": 0},
                    "rx": {"type": "integer", "minimum": 0, "maximum": 100, "default": 5},
                    "ry": {"type": "integer", "minimum": 0, "maximum": 100, "default": 5},
                },
                "required": ["x", "y"],
            },
        ),
        Tool(
            name="list_stamps",
            description="List saved local stamps.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="save_stamp",
            description="Save a bounded pixel-space stamp.",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer"}, "y": {"type": "integer"},
                    "width": {"type": "integer"}, "height": {"type": "integer"},
                    "include_pressure": {"type": "boolean", "default": True},
                },
                "required": ["x", "y", "width", "height"],
            },
        ),
        Tool(
            name="load_stamp",
            description="Load a named stamp at a pixel position.",
            inputSchema={
                "type": "object",
                "properties": {"name": {"type": "string"}, "x": {"type": "integer", "default": 0}, "y": {"type": "integer", "default": 0}},
                "required": ["name"],
            },
        ),
        Tool(
            name="delete_stamp",
            description="Delete a named stamp.",
            inputSchema={"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
        ),
        Tool(
            name="get_simulation_state",
            description="Get comprehensive sim state snapshot.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="get_particle",
            description="Read a bounded particle snapshot by particle ID.",
            inputSchema={
                "type": "object",
                "properties": {"particle_id": {"type": "integer"}},
                "required": ["particle_id"],
            },
        ),
        Tool(
            name="create_particle",
            description="Create one catalog-identified particle at a pixel coordinate.",
            inputSchema={
                "type": "object",
                "properties": {"element": {"type": "string"}, "x": {"type": "integer"}, "y": {"type": "integer"}},
                "required": ["element", "x", "y"],
            },
        ),
        Tool(
            name="change_particle_type",
            description="Change one existing particle to another catalog element.",
            inputSchema={
                "type": "object",
                "properties": {"particle_id": {"type": "integer"}, "element": {"type": "string"}},
                "required": ["particle_id", "element"],
            },
        ),
        Tool(
            name="set_particle_property",
            description="Set an allowlisted particle property.",
            inputSchema={
                "type": "object",
                "properties": {"particle_id": {"type": "integer"}, "property": {"type": "string"}, "value": {}},
                "required": ["particle_id", "property", "value"],
            },
        ),
        Tool(
            name="kill_particle",
            description="Remove one existing particle by ID.",
            inputSchema={"type": "object", "properties": {"particle_id": {"type": "integer"}}, "required": ["particle_id"]},
        ),
        Tool(
            name="get_simulation_modes",
            description="Read current edge, gravity, air, and paused modes.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="set_simulation_modes",
            description="Set supported edge, gravity, air, and paused modes.",
            inputSchema={
                "type": "object",
                "properties": {
                    "edge_mode": {"type": "integer"},
                    "gravity_mode": {"type": "integer"},
                    "air_mode": {"type": "integer"},
                    "paused": {"type": "boolean"},
                },
            },
        ),
        Tool(
            name="set_custom_gravity",
            description="Set the finite global custom-gravity vector. Use gravity mode CUSTOM for it to affect the simulation.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "gx": {"type": "number", "minimum": -256, "maximum": 256},
                    "gy": {"type": "number", "minimum": -256, "maximum": 256},
                },
                "required": ["gx", "gy"],
            },
        ),
        Tool(
            name="set_edge_pressure",
            description="Set finite boundary pressure within the bridge safe range.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "value": {"type": "number", "minimum": -256, "maximum": 256},
                },
                "required": ["value"],
            },
        ),
        Tool(
            name="set_edge_velocity",
            description="Set the finite boundary-air velocity vector within the bridge safe range.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "vx": {"type": "number", "minimum": -256, "maximum": 256},
                    "vy": {"type": "number", "minimum": -256, "maximum": 256},
                },
                "required": ["vx", "vy"],
            },
        ),
        Tool(
            name="set_field_region",
            description="Set a bounded cell-space field region (temp, pressure, velocity, or fan velocity).",
            inputSchema={
                "type": "object",
                "properties": {
                    "field": {"type": "string"},
                    "x1": {"type": "integer"}, "y1": {"type": "integer"},
                    "x2": {"type": "integer"}, "y2": {"type": "integer"},
                    "value": {"type": "number"},
                },
                "required": ["field", "x1", "y1", "x2", "y2", "value"],
            },
        ),
        Tool(
            name="clear_sim",
            description="Clear the entire simulation.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="draw_project",
            description="Draw a generic material project from authenticated components (box, circle, line, wall_box, wall_line, tool_box). Validates geometry, identifiers, and parameters; reports `partial_mutation`, `succeeded`, `failed`, and `skipped`; stops on first runtime error.",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "clear_before": {"type": "boolean", "default": False},
                    "components": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "kind": {"type": "string", "enum": ["box", "circle", "line", "wall_box", "wall_line", "tool_box"]},
                                "element": {"type": "string"},
                                "wall": {"type": "string"},
                                "tool": {"type": "string"},
                                "x1": {"type": "integer"},
                                "y1": {"type": "integer"},
                                "x2": {"type": "integer"},
                                "y2": {"type": "integer"},
                                "cx": {"type": "integer"},
                                "cy": {"type": "integer"},
                                "radius": {"type": "integer"},
                                "strength": {"type": "number"},
                                "brush": {"type": "integer"},
                                "rx": {"type": "integer"},
                                "ry": {"type": "integer"},
                            },
                            "required": ["kind"],
                        },
                    },
                },
                "required": ["name", "components"],
            },
        ),
        Tool(
            name="draw_house",
            description="Draw a material-aware cottage with BRCK, STNE, WOOD, GLAS, and dynamic SMKE smoke.",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer", "default": 176},
                    "y": {"type": "integer", "default": 154},
                    "width": {"type": "integer", "default": 260},
                    "height": {"type": "integer", "default": 166},
                    "clear_before": {"type": "boolean", "default": False},
                    "materials": {"type": "object"},
                },
            },
        ),
        Tool(
            name="powder_tool_index",
            description="Search the source-backed index of every registered Powder Toy Lua module/function.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "module": {"type": "string"},
                },
            },
        ),
        Tool(
            name="rapid_build",
            description="Execute a validated rapid-build plan (box, circle, line, wall_box, wall_line, tool_box). Preflight, optional dry_run preview, and stop-on-first-error are enforced before any mutation.",
            inputSchema={
                "type": "object",
                "properties": {
                    "plan": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "clear_before": {"type": "boolean", "default": False},
                            "dry_run": {"type": "boolean", "default": False},
                            "components": {"type": "array"},
                            "steps": {"type": "array"},
                        },
                        "required": ["name", "components"],
                    }
                },
                "required": ["plan"],
            },
        ),
        Tool(
            name="material_catalog",
            description="Search the source-backed catalog of built-in Powder Toy element identifiers.",
            inputSchema={
                "type": "object",
                "properties": {"query": {"type": "string"}},
            },
        ),
        Tool(
            name="native_catalog",
            description="Search source-backed native editor tools, wall types, and brush/renderer/interface constants.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "kind": {"type": "string", "enum": ["tools", "walls", "constants"]},
                },
            },
        ),
        Tool(
            name="runtime_diagnostics",
            description="Self-check: machine-readable runtime checks only. No screenshots.",
            inputSchema={"type": "object", "additionalProperties": False, "properties": {}},
        ),
        Tool(
            name="catalog_status",
            description="Source catalog metadata versus runtime availability. Does not dump full catalogs.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "query": {"type": "string"},
                    "include_runtime": {"type": "boolean", "default": True},
                },
            },
        ),
        Tool(
            name="read_operation_log",
            description="Tail or filter the bounded JSONL operation log. Never returns token fields.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 50},
                    "action": {"type": "string"},
                    "correlation_id": {"type": "string"},
                    "ok": {"type": "boolean"},
                },
            },
        ),
        Tool(
            name="get_field",
            description="Read one bounded live simulation field value with correlation metadata.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "field": {"type": "string", "enum": ["temp", "temperature", "pressure"]},
                    "x": {"type": "integer", "minimum": 0, "maximum": 152},
                    "y": {"type": "integer", "minimum": 0, "maximum": 95},
                },
                "required": ["field", "x", "y"],
            },
        ),
        Tool(
            name="spatial_snapshot",
            description="Read a bounded live spatial snapshot. Pixel and cell coordinates are separate; pixel occupancy can be discovered through bounded pmap/photons sampling, while explicit particle IDs remain supported.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "space": {"type": "string", "enum": ["pixel", "cell"]},
                    "x": {"type": "integer"},
                    "y": {"type": "integer"},
                    "x1": {"type": "integer"},
                    "y1": {"type": "integer"},
                    "x2": {"type": "integer"},
                    "y2": {"type": "integer"},
                    "sample_fields": {
                        "type": "array",
                        "items": {"type": "string", "enum": ["temp", "temperature", "pressure"]},
                        "maxItems": 7,
                    },
                    "sample_stride": {"type": "integer", "minimum": 1, "maximum": 128, "default": 4},
                    "max_samples": {"type": "integer", "minimum": 1, "maximum": 4096, "default": 4096},
                    "discover_particles": {"type": "boolean", "default": False, "description": "Discover bounded pmap/photons occupancy in pixel space."},
                    "particle_ids": {"type": "array", "items": {"type": "integer", "minimum": 0}, "maxItems": 256},
                    "max_particles": {"type": "integer", "minimum": 1, "maximum": 256, "default": 256},
                    "max_response_bytes": {"type": "integer", "minimum": 4096, "maximum": 262144, "default": 262144},
                    "allow_truncation": {"type": "boolean", "default": False},
                },
                "required": ["space"],
            },
        ),
        Tool(
            name="parts_inventory",
            description="Read a bounded live partsInventory page. The cursor is a raw particle-slot cursor; holes count toward max_scan. Optional x1/y1/x2/y2 bounds are inclusive pixel coordinates, and type is a source-backed numeric element ID filter.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "cursor": {"type": "integer", "minimum": 0, "maximum": PARTS_INVENTORY_MAX_SLOTS, "default": 0},
                    "limit": {"type": "integer", "minimum": 1, "maximum": PARTS_INVENTORY_MAX_LIMIT, "default": PARTS_INVENTORY_MAX_LIMIT},
                    "max_scan": {"type": "integer", "minimum": 1, "maximum": PARTS_INVENTORY_MAX_SCAN, "default": PARTS_INVENTORY_MAX_SCAN},
                    "x1": {"type": "integer", "minimum": 0, "maximum": PIXEL_XRES - 1},
                    "y1": {"type": "integer", "minimum": 0, "maximum": PIXEL_YRES - 1},
                    "x2": {"type": "integer", "minimum": 0, "maximum": PIXEL_XRES - 1},
                    "y2": {"type": "integer", "minimum": 0, "maximum": PIXEL_YRES - 1},
                    "type": {"type": "integer", "minimum": 0},
                },
            },
        ),
        Tool(
            name="design_intake",
            description="Read-only bounded design intake: capture checkpoint state, modes, catalog provenance, tile snapshots, inventory evidence, rubric recommendations, errors, and explicit limitations.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "tiles": {
                        "type": "array",
                        "maxItems": 64,
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "properties": {
                                "name": {"type": "string", "maxLength": 80},
                                "x1": {"type": "integer", "minimum": 0, "maximum": PIXEL_XRES - 1},
                                "y1": {"type": "integer", "minimum": 0, "maximum": PIXEL_YRES - 1},
                                "x2": {"type": "integer", "minimum": 0, "maximum": PIXEL_XRES - 1},
                                "y2": {"type": "integer", "minimum": 0, "maximum": PIXEL_YRES - 1},
                                "space": {"type": "string", "enum": ["pixel", "cell"], "default": "pixel"},
                                "sample_fields": {
                                    "type": "array",
                                    "maxItems": 7,
                                    "items": {"type": "string", "enum": ["temp", "temperature", "pressure"]},
                                },
                                "discover_particles": {"type": "boolean", "default": False},
                            },
                            "required": ["x1", "y1", "x2", "y2"],
                        },
                    },
                    "max_tiles": {"type": "integer", "minimum": 1, "maximum": 64, "default": 16},
                    "sample_stride": {"type": "integer", "minimum": 1, "maximum": 128, "default": 4},
                    "max_samples": {"type": "integer", "minimum": 1, "maximum": 4096, "default": 1024},
                    "sample_fields": {
                        "type": "array",
                        "maxItems": 7,
                        "items": {"type": "string", "enum": ["temp", "temperature", "pressure"]},
                    },
                    "inventory_limit": {"type": "integer", "minimum": 1, "maximum": PARTS_INVENTORY_MAX_LIMIT, "default": 256},
                    "max_scan": {"type": "integer", "minimum": 1, "maximum": PARTS_INVENTORY_MAX_SCAN, "default": 4096},
                    "include_catalog": {"type": "boolean", "default": True},
                    "include_inventory": {"type": "boolean", "default": True},
                },
            },
        ),
        Tool(
            name="experiment_evaluate",
            description="Read-only deterministic comparison of bounded baseline/candidate metrics with hard safety/readback gates and weighted dynamics, readability, stability, composition, and budget scoring.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "baseline": experiment_metrics_schema,
                    "candidate": experiment_metrics_schema,
                },
                "required": ["baseline", "candidate"],
            },
        ),
        Tool(
            name="experiment_run",
            description="Bounded experiment orchestrator: captures t0/t1/t2 checkpoints via existing get_simulation_state / get_simulation_modes plus one bounded design_intake, optionally applies one caller-supplied candidate plan, steps bounded frames, and routes caller-supplied metrics through experiment_evaluate (returns needs_metrics when metrics are absent). dry_run defaults to true; commit must be true for any mutation. Hard caps: components <= 64, frames <= 120, checkpoints <= 3.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "plan": {
                        "type": "object",
                        "additionalProperties": False,
                        "properties": {
                            "name": {"type": "string", "maxLength": 80},
                            "components": {
                                "type": "array",
                                "maxItems": 64,
                                "items": {"type": "object"},
                            },
                            "steps": {
                                "type": "array",
                                "maxItems": 16,
                                "items": {
                                    "type": "object",
                                    "additionalProperties": False,
                                    "properties": {
                                        "op": {"type": "string", "enum": ["step"]},
                                        "n": {"type": "integer", "minimum": 1, "maximum": 120},
                                    },
                                    "required": ["op", "n"],
                                },
                            },
                            "clear_before": {"type": "boolean", "default": False},
                        },
                        "required": ["components", "steps"],
                    },
                    "commit": {"type": "boolean", "default": False},
                    "dry_run": {"type": "boolean", "default": True},
                    "checkpoints": {"type": "integer", "minimum": 1, "maximum": 3, "default": 2},
                    "metrics": {
                        "type": "object",
                        "additionalProperties": False,
                        "properties": {
                            "baseline": experiment_metrics_schema,
                            "candidate": experiment_metrics_schema,
                        },
                    },
                },
                "required": ["plan"],
            },
        ),
        Tool(
            name="experiment_feedback",
            description="Read-only bounded experiment feedback; records one redacted JSONL event through the existing operation logger.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "run_id": {"type": "string", "maxLength": 80},
                    "score": {"type": "number", "minimum": 0, "maximum": 100},
                    "status": {"type": "string", "enum": ["keep", "discard", "crash", "checks_failed"]},
                    "failure": {"type": "string", "maxLength": 240},
                    "feedback": {"type": "string", "maxLength": 1000},
                    "metadata": {"type": "object", "maxProperties": 16},
                },
            },
        ),
        Tool(
            name="coordinate_helper",
            description="Validate a named pixel or cell coordinate and resolve an exact material catalog identifier without filename or alias guessing.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "domain": {"type": "string", "enum": ["pixel", "cell"]},
                    "x": {"type": "integer"},
                    "y": {"type": "integer"},
                    "material": {"type": "string"},
                },
                "required": ["domain"],
            },
        ),
        Tool(
            name="record_build_lesson",
            description="Persist one durable lesson learned while building, so later sessions and smaller models inherit it. Reconfirms and counts an identical topic+title instead of duplicating it.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "topic": {"type": "string", "enum": list(_LESSON_TOPICS)},
                    "title": {"type": "string", "minLength": 1, "maxLength": 120},
                    "lesson": {"type": "string", "minLength": 1, "maxLength": 800},
                    "evidence": {"type": "string", "maxLength": 400},
                    "severity": {"type": "string", "enum": list(_LESSON_SEVERITIES)},
                    "elements": {
                        "type": "array",
                        "maxItems": 12,
                        "items": {"type": "string", "maxLength": 8},
                    },
                },
                "required": ["topic", "title", "lesson"],
            },
        ),
        Tool(
            name="build_lessons",
            description="Read accumulated build lessons before designing or drawing. Returns a ranked briefing of what previous builds proved about thermal limits, containment, electrical isolation, coordinates, rendering, and performance.",
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "topic": {"type": "string", "enum": list(_LESSON_TOPICS)},
                    "query": {"type": "string", "maxLength": 120},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 200},
                },
            },
        ),
        Tool(
            name="define_element",
            description=_ext_description("define_element"),
            inputSchema=_ext_schema("define_element"),
        ),
        Tool(
            name="list_custom_elements",
            description=_ext_description("list_custom_elements"),
            inputSchema=_ext_schema("list_custom_elements"),
        ),
        Tool(
            name="update_element",
            description=_ext_description("update_element"),
            inputSchema=_ext_schema("update_element"),
        ),
        Tool(
            name="delete_custom_element",
            description=_ext_description("delete_custom_element"),
            inputSchema=_ext_schema("delete_custom_element"),
        ),
        Tool(
            name="colony_create",
            description=_ext_description("colony_create"),
            inputSchema=_ext_schema("colony_create"),
        ),
        Tool(
            name="colony_list",
            description=_ext_description("colony_list"),
            inputSchema=_ext_schema("colony_list"),
        ),
        Tool(
            name="colony_status",
            description=_ext_description("colony_status"),
            inputSchema=_ext_schema("colony_status"),
        ),
        Tool(
            name="colony_destroy",
            description=_ext_description("colony_destroy"),
            inputSchema=_ext_schema("colony_destroy"),
        ),
        Tool(
            name="spawn_workers",
            description=_ext_description("spawn_workers"),
            inputSchema=_ext_schema("spawn_workers"),
        ),
        Tool(
            name="kill_workers",
            description=_ext_description("kill_workers"),
            inputSchema=_ext_schema("kill_workers"),
        ),
        Tool(
            name="assign_task",
            description=_ext_description("assign_task"),
            inputSchema=_ext_schema("assign_task"),
        ),
        Tool(
            name="task_status",
            description=_ext_description("task_status"),
            inputSchema=_ext_schema("task_status"),
        ),
        Tool(
            name="cancel_task",
            description=_ext_description("cancel_task"),
            inputSchema=_ext_schema("cancel_task"),
        ),
        Tool(
            name="extension_status",
            description=_ext_description("extension_status"),
            inputSchema=_ext_schema("extension_status"),
        ),
        Tool(
            name="extension_self_test",
            description=_ext_description("extension_self_test"),
            inputSchema=_ext_schema("extension_self_test"),
        ),
        Tool(
            name="reset_creature_faults",
            description=_ext_description("reset_creature_faults"),
            inputSchema=_ext_schema("reset_creature_faults"),
        ),
        Tool(
            name="execute_lua",
            description=_ext_description("execute_lua"),
            inputSchema=_ext_schema("execute_lua"),
        ),
        Tool(
            name="blueprint_build",
            description=_ext_description("blueprint_build"),
            inputSchema=_ext_schema("blueprint_build"),
        ),
        Tool(
            name="blueprint_schema",
            description=_ext_description("blueprint_schema"),
            inputSchema=_ext_schema("blueprint_schema"),
        ),
        Tool(
            name="build_practices",
            description=_ext_description("build_practices"),
            inputSchema=_ext_schema("build_practices"),
        ),
        Tool(
            name="realism_apply",
            description=_ext_description("realism_apply"),
            inputSchema=_ext_schema("realism_apply"),
        ),
        Tool(
            name="realism_status",
            description=_ext_description("realism_status"),
            inputSchema=_ext_schema("realism_status"),
        ),
        Tool(
            name="world_state",
            description=_ext_description("world_state"),
            inputSchema=_ext_schema("world_state"),
        ),
        Tool(
            name="next_task",
            description=_ext_description("next_task"),
            inputSchema=_ext_schema("next_task"),
        ),
        Tool(
            name="record_attempt",
            description=_ext_description("record_attempt"),
            inputSchema=_ext_schema("record_attempt"),
        ),
        Tool(
            name="blueprint_grammar",
            description=_ext_description("blueprint_grammar"),
            inputSchema=_ext_schema("blueprint_grammar"),
        ),
        Tool(
            name="module_search",
            description=_ext_description("module_search"),
            inputSchema=_ext_schema("module_search"),
        ),
        Tool(
            name="find_features",
            description=_ext_description("find_features"),
            inputSchema=_ext_schema("find_features"),
        ),
        Tool(
            name="run_test",
            description=_ext_description("run_test"),
            inputSchema=_ext_schema("run_test"),
        ),
        Tool(
            name="build_stage",
            description=_ext_description("build_stage"),
            inputSchema=_ext_schema("build_stage"),
        ),
        Tool(
            name="run_pipeline",
            description=_ext_description("run_pipeline"),
            inputSchema=_ext_schema("run_pipeline"),
        ),
        Tool(
            name="blueprint_lint",
            description=_ext_description("blueprint_lint"),
            inputSchema=_ext_schema("blueprint_lint"),
        ),
        Tool(
            name="blueprint_module_save",
            description=_ext_description("blueprint_module_save"),
            inputSchema=_ext_schema("blueprint_module_save"),
        ),
        Tool(
            name="element_facts",
            description=_ext_description("element_facts"),
            inputSchema=_ext_schema("element_facts"),
        ),
        Tool(
            name="person_inspect",
            description=_ext_description("person_inspect"),
            inputSchema=_ext_schema("person_inspect"),
        ),
        Tool(
            name="person_move",
            description=_ext_description("person_move"),
            inputSchema=_ext_schema("person_move"),
        ),
        Tool(
            name="person_kill",
            description=_ext_description("person_kill"),
            inputSchema=_ext_schema("person_kill"),
        ),
        Tool(
            name="person_set_trait",
            description=_ext_description("person_set_trait"),
            inputSchema=_ext_schema("person_set_trait"),
        ),
        Tool(
            name="person_feed",
            description=_ext_description("person_feed"),
            inputSchema=_ext_schema("person_feed"),
        ),
        Tool(
            name="person_recolor",
            description=_ext_description("person_recolor"),
            inputSchema=_ext_schema("person_recolor"),
        ),
        Tool(
            name="world_place_hazard",
            description=_ext_description("world_place_hazard"),
            inputSchema=_ext_schema("world_place_hazard"),
        ),
        Tool(
            name="snapshot_fast",
            description=_ext_description("snapshot_fast"),
            inputSchema=_ext_schema("snapshot_fast"),
        ),
        Tool(
            name="screenshot",
            description=_ext_description("screenshot"),
            inputSchema=_ext_schema("screenshot"),
        ),
        Tool(
            name="replay_hash_check",
            description=_ext_description("replay_hash_check"),
            inputSchema=_ext_schema("replay_hash_check"),
        ),
        Tool(
            name="rpg_status",
            description=_ext_description("rpg_status"),
            inputSchema=_ext_schema("rpg_status"),
        ),
        Tool(
            name="rpg_search",
            description=_ext_description("rpg_search"),
            inputSchema=_ext_schema("rpg_search"),
        ),
        Tool(
            name="rpg_api",
            description=_ext_description("rpg_api"),
            inputSchema=_ext_schema("rpg_api"),
        ),
        Tool(
            name="rpg_hub",
            description=_ext_description("rpg_hub"),
            inputSchema=_ext_schema("rpg_hub"),
        ),
        Tool(
            name="rpg_reload",
            description=_ext_description("rpg_reload"),
            inputSchema=_ext_schema("rpg_reload"),
        ),
        Tool(
            name="rpg_screenshot",
            description=_ext_description("rpg_screenshot"),
            inputSchema=_ext_schema("rpg_screenshot"),
        ),
        Tool(
            name="rpg_lua",
            description=_ext_description("rpg_lua"),
            inputSchema=_ext_schema("rpg_lua"),
        ),
        Tool(
            name="run_lua_test",
            description=(
                "Execute a Lua test script against the live TPT bridge, optionally after "
                "stepping the simulation. Returns structured JSON. Use the real TPT Lua API: "
                "sim.partCreate(-1, x, y, eid), sim.partID(x,y), sim.partProperty(p,\"type\"), "
                "sim.partProperty(p,\"temp\"), elem[\"DEFAULT_PT_LAVA\"] for element ids, "
                "elem.property(id, \"Name\") for lookup. The script MUST return a table or "
                "print JSON -- both are captured. bridge='lab' (port 9877) or 'user' (port 9876)."
            ),
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "script": {"type": "string", "description": "Lua source to execute. Last expression value or print() output is returned."},
                    "step_frames": {"type": "integer", "default": 0, "minimum": 0, "maximum": 600},
                    "bridge": {"type": "string", "enum": ["lab", "user"], "default": "lab"},
                },
                "required": ["script"],
            },
        ),
        Tool(
            name="inspect_grid",
            description=(
                "Dump every particle inside a bounded canvas pixel rectangle as a JSON "
                "array. Each entry: {x, y, type, name, temp, life, vx, vy, ctype}. Use this "
                "instead of guessing what's in a region after a Lua edit. Coordinates are "
                "pixel coordinates on the live canvas (0..611 x 0..383), NOT world coords. "
                "Empty cells are omitted. Bounded to 10k entries to keep responses sane."
            ),
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "x1": {"type": "integer", "minimum": 0, "maximum": 611},
                    "y1": {"type": "integer", "minimum": 0, "maximum": 383},
                    "x2": {"type": "integer", "minimum": 0, "maximum": 611},
                    "y2": {"type": "integer", "minimum": 0, "maximum": 383},
                    "bridge": {"type": "string", "enum": ["lab", "user"], "default": "lab"},
                },
                "required": ["x1", "y1", "x2", "y2"],
            },
        ),
        Tool(
            name="build_and_trace",
            description=(
                "Configure meson with AddressSanitizer + UndefinedBehaviorSanitizer, "
                "rebuild powder.exe, run a smoke test, and capture the ASan/UBSan stack "
                "trace on any crash. Returns { ok, build_log_tail, test_stdout, test_stderr, "
                "crash, sanitizer_findings }. Use this when a Lua fix needs C++ validation "
                "or when a runtime crash leaves no Lua-level trace."
            ),
            inputSchema={
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "build_dir": {"type": "string", "default": "build-asan"},
                    "sanitize": {"type": "string", "enum": ["address,undefined", "address", "undefined", "none"], "default": "address,undefined"},
                    "smoke_seconds": {"type": "number", "default": 5.0, "minimum": 0.5, "maximum": 60.0},
                },
            },
        ),
        Tool(
            name="capability_status",
            description="Report source-indexed, wrapped, gated, unknown, and runtime capability status with provenance.",
            inputSchema={"type": "object", "additionalProperties": False, "properties": {}},
        ),
    ]
@server.list_tools()
async def list_tools() -> list[Tool]:
    """Materialize the legacy schemas in manifest order."""

    check = _capability_manifest_check()
    if not check["ok"]:
        raise RuntimeError(f"capability manifest inconsistent: {check['findings']}")
    declarations = {tool.name: tool for tool in await _legacy_tool_declarations()}
    return [
        declarations[record["mcp_name"]]
        for record in _CAPABILITY_MANIFEST
        if record["mcp_name"] is not None
    ]
class CapabilityManifestRecord(TypedDict):
    """Declarative metadata for one MCP or source capability."""

    id: str
    mcp_name: str | None
    source_exports: tuple[str, ...]
    primary_status: str
    dispatch_key: str | None
    tool_factory: str | None
    tool_factory_ref: str | None
    schema_factory: str | None
    runtime_probe: dict[str, Any]


_CAPABILITY_STATUSES = frozenset({"wrapped", "gated", "catalog_only", "unknown"})


def _canonical_source_id(module_file: str, export_name: str) -> str:
    """Normalize an indexed module/export to a stable source identity."""

    normalized = module_file.replace("\\", "/")
    marker = "/src/lua/"
    position = normalized.lower().rfind(marker)
    relative = normalized[position + len(marker):] if position >= 0 else Path(normalized).name
    return f"lua/{relative}::{export_name}"


def _canonical_manifest_source_id(source_export: str) -> str:
    normalized = source_export.replace("\\", "/")
    return normalized if normalized.startswith("lua/") else f"lua/{normalized}"


def _manifest_tool(
    name: str,
    *,
    source_exports: tuple[str, ...] = (),
    primary_status: str = "wrapped",
    probe_kind: str = "bridge_adapter",
    read_only: bool = False,
) -> CapabilityManifestRecord:
    return {
        "id": f"mcp.tool:{name}",
        "mcp_name": name,
        "source_exports": tuple(_canonical_manifest_source_id(value) for value in source_exports),
        "primary_status": primary_status,
        "dispatch_key": name,
        "tool_factory": f"list_tools::{name}",
        "tool_factory_ref": f"list_tools::{name}",
        "schema_factory": "legacy Tool declaration",
        "runtime_probe": {"kind": probe_kind, "read_only": read_only},
    }


def _manifest_source(
    identifier: str,
    *,
    source_exports: tuple[str, ...],
    primary_status: str,
    reason: str,
) -> CapabilityManifestRecord:
    return {
        "id": identifier,
        "mcp_name": None,
        "source_exports": tuple(_canonical_manifest_source_id(value) for value in source_exports),
        "primary_status": primary_status,
        "dispatch_key": None,
        "tool_factory": None,
        "tool_factory_ref": None,
        "schema_factory": None,
        "runtime_probe": {"kind": "source_catalog", "read_only": True, "reason": reason},
    }


# One source of truth for tool registration, dispatch keys, source mappings,
# status, schema provenance, and runtime probe policy.  Indexed source keys use
# ``lua/<path-under-src/lua>::export`` so repeated names in different modules
# cannot collide.  Synthetic bridge/policy records intentionally have no source key.
_BASE_CAPABILITY_MANIFEST: tuple[CapabilityManifestRecord, ...] = (
    _manifest_tool("launch_powder_toy"),
    _manifest_tool("rebuild_powder_toy", probe_kind="subprocess", read_only=False),
    _manifest_tool("powder_status"),
    _manifest_tool("health_check"),
    _manifest_tool("execute_action"),
    _manifest_tool("step_sim", source_exports=("LuaSimulation.cpp::step",), primary_status="wrapped"),
    _manifest_tool("place_element", source_exports=("LuaSimulation.cpp::createBox",), primary_status="wrapped"),
    _manifest_tool("place_element_line", source_exports=("LuaSimulation.cpp::createLine",), primary_status="wrapped"),
    _manifest_tool("place_wall_line", source_exports=("LuaSimulation.cpp::createWallLine",), primary_status="wrapped"),
    _manifest_tool("place_wall_box", source_exports=("LuaSimulation.cpp::createWallBox",), primary_status="wrapped"),
    _manifest_tool("apply_native_tool_box", primary_status="wrapped"),
    _manifest_tool("place_deco_box", source_exports=("LuaSimulation.cpp::decoBox",), primary_status="wrapped"),
    _manifest_tool("place_deco_line", source_exports=("LuaSimulation.cpp::decoLine",), primary_status="wrapped"),
    _manifest_tool("place_deco_point", source_exports=("LuaSimulation.cpp::decoBrush",), primary_status="wrapped"),
    _manifest_tool("list_stamps"),
    _manifest_tool("save_stamp"),
    _manifest_tool("load_stamp"),
    _manifest_tool("delete_stamp"),
    _manifest_tool("get_simulation_state"),
    _manifest_tool("get_particle", primary_status="wrapped"),
    _manifest_tool("create_particle", source_exports=("LuaSimulation.cpp::partCreate",), primary_status="wrapped"),
    _manifest_tool("change_particle_type", source_exports=("LuaSimulation.cpp::partChangeType",), primary_status="wrapped"),
    _manifest_tool("set_particle_property", primary_status="wrapped"),
    _manifest_tool("kill_particle", source_exports=("LuaSimulation.cpp::partKill",), primary_status="wrapped"),
    _manifest_tool("get_simulation_modes", primary_status="wrapped"),
    _manifest_tool("set_simulation_modes", primary_status="wrapped"),
    _manifest_tool("set_custom_gravity", source_exports=("LuaSimulation.cpp::customGravity",), primary_status="wrapped"),
    _manifest_tool("set_edge_pressure", source_exports=("LuaSimulation.cpp::edgePressure",), primary_status="wrapped"),
    _manifest_tool("set_edge_velocity", source_exports=("LuaSimulation.cpp::edgeVelocity",), primary_status="wrapped"),
    _manifest_tool("set_field_region", primary_status="wrapped"),
    _manifest_tool("clear_sim", primary_status="wrapped"),
    _manifest_tool("draw_project"),
    _manifest_tool("draw_house"),
    _manifest_tool("powder_tool_index"),
    _manifest_tool("rapid_build"),
    _manifest_tool("material_catalog"),
    _manifest_tool("native_catalog"),
    _manifest_tool("runtime_diagnostics", primary_status="wrapped", probe_kind="local", read_only=True),
    _manifest_tool("catalog_status", primary_status="wrapped", probe_kind="local", read_only=True),
    _manifest_tool("read_operation_log", primary_status="wrapped", probe_kind="local", read_only=True),
    _manifest_tool(
        "get_field",
        source_exports=("LuaSimulation.cpp::getTemp", "LuaSimulation.cpp::getPressure"),
        primary_status="wrapped",
        probe_kind="bounded_read",
        read_only=True,
    ),
    _manifest_tool(
        "spatial_snapshot",
        source_exports=("LuaSimulation.cpp::pmap", "LuaSimulation.cpp::photons"),
        primary_status="wrapped",
        probe_kind="bounded_read",
        read_only=True,
    ),
    _manifest_tool(
        "parts_inventory",
        source_exports=(
            "LuaSimulation.cpp::partCount",
            "LuaSimulation.cpp::partExists",
            "LuaSimulation.cpp::partPosition",
            "LuaSimulation.cpp::partProperty",
        ),
        primary_status="wrapped",
        probe_kind="bounded_read",
        read_only=True,
    ),
    _manifest_tool(
        "experiment_feedback",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "record_build_lesson",
        primary_status="wrapped",
        probe_kind="local",
        read_only=False,
    ),
    _manifest_tool(
        "build_lessons",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "define_element",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "list_custom_elements",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "update_element",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "delete_custom_element",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "colony_create",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "colony_list",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "colony_status",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "colony_destroy",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "spawn_workers",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "kill_workers",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "assign_task",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "task_status",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "cancel_task",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "extension_status",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "extension_self_test",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "reset_creature_faults",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "execute_lua",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "blueprint_build",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "blueprint_schema",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "build_practices",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "realism_apply",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "realism_status",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "world_state",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "next_task",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "record_attempt",
        primary_status="wrapped",
        probe_kind="local",
        read_only=False,
    ),
    _manifest_tool(
        "blueprint_grammar",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "module_search",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "find_features",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "run_test",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "build_stage",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "run_pipeline",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "blueprint_lint",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "blueprint_module_save",
        primary_status="wrapped",
        probe_kind="local",
        read_only=False,
    ),
    _manifest_tool(
        "element_facts",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "person_inspect",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "person_move",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "person_kill",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "person_set_trait",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "person_feed",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "person_recolor",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "world_place_hazard",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "design_intake",
        primary_status="wrapped",
        probe_kind="bounded_read",
        read_only=True,
    ),
    _manifest_tool(
        "experiment_evaluate",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "experiment_run",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool("coordinate_helper", primary_status="wrapped", probe_kind="bounded_catalog_read", read_only=True),
    _manifest_tool("capability_status", primary_status="wrapped", probe_kind="manifest_read", read_only=True),
    _manifest_tool(
        "snapshot_fast",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "screenshot",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "replay_hash_check",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "rpg_status",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "rpg_search",
        primary_status="wrapped",
        probe_kind="local",
        read_only=True,
    ),
    _manifest_tool(
        "rpg_api",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "rpg_hub",
        primary_status="wrapped",
        probe_kind="local",
        read_only=False,
    ),
    _manifest_tool(
        "rpg_reload",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "rpg_screenshot",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "rpg_lua",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "run_lua_test",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=False,
    ),
    _manifest_tool(
        "inspect_grid",
        primary_status="wrapped",
        probe_kind="bridge_adapter",
        read_only=True,
    ),
    _manifest_tool(
        "build_and_trace",
        primary_status="wrapped",
        probe_kind="subprocess",
        read_only=False,
    ),
    _manifest_source(
        "lua.gated.partNeighbors",
        source_exports=("LuaSimulation.cpp::partNeighbors",),
        primary_status="gated",
        reason="no bounded MCP wrapper",
    ),
    _manifest_source(
        "lua.gated.floodParts",
        source_exports=("LuaSimulation.cpp::floodParts",),
        primary_status="gated",
        reason="unbounded mutation surface",
    ),
    _manifest_source(
        "lua.gated.historyRestore",
        source_exports=("LuaSimulation.cpp::historyRestore",),
        primary_status="gated",
        reason="main-thread/history gated",
    ),
    _manifest_source(
        "policy.gated.executeLua",
        source_exports=(),
        primary_status="gated",
        reason="MCP generic allowlist blocked; not an indexed source export",
    ),
    _manifest_source(
        "policy.gated.filesystem",
        source_exports=(),
        primary_status="gated",
        reason="filesystem surface security gated",
    ),
    _manifest_source(
        "policy.gated.http",
        source_exports=(),
        primary_status="gated",
        reason="http surface security gated",
    ),
    _manifest_source(
        "policy.gated.socket",
        source_exports=(),
        primary_status="gated",
        reason="socket surface security gated",
    ),
    _manifest_source(
        "policy.gated.ui",
        source_exports=(),
        primary_status="gated",
        reason="ui surface security gated",
    ),
)
def _indexed_source_manifest_records() -> tuple[CapabilityManifestRecord, ...]:
    """Own every indexed contract not explicitly wrapped or gated."""

    index_path = REPO_ROOT / "POWDER_TOY_TOOL_INDEX.json"
    if not index_path.is_file():
        return ()
    try:
        data = json.loads(index_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ()
    explicit = {
        source_export
        for record in _BASE_CAPABILITY_MANIFEST
        for source_export in record["source_exports"]
    }
    generated: list[CapabilityManifestRecord] = []
    for module in data.get("modules", []):
        source_file = str(module.get("file") or "")
        for contract in module.get("contracts", []):
            export_name = str(contract.get("export_name") or "")
            source_id = _canonical_source_id(source_file, export_name)
            if source_id in explicit:
                continue
            contract_status = str((contract.get("contract") or {}).get("status", "unknown"))
            status = "unknown" if contract_status == "unknown" else "catalog_only"
            generated.append(
                _manifest_source(
                    f"source.{source_id}",
                    source_exports=(source_id,),
                    primary_status=status,
                    reason="indexed source contract has no bounded MCP wrapper",
                )
            )
    return tuple(generated)


_CAPABILITY_MANIFEST: tuple[CapabilityManifestRecord, ...] = (
    *_BASE_CAPABILITY_MANIFEST,
    *_indexed_source_manifest_records(),
)
CAPABILITY_MANIFEST = _CAPABILITY_MANIFEST


def _manifest_source_map() -> tuple[dict[str, CapabilityManifestRecord], list[dict[str, Any]]]:
    mapping: dict[str, CapabilityManifestRecord] = {}
    findings: list[dict[str, Any]] = []
    for record in _CAPABILITY_MANIFEST:
        for source_export in record["source_exports"]:
            if source_export in mapping:
                findings.append({
                    "code": "SOURCE_EXPORT_DUPLICATE_MANIFEST",
                    "detail": source_export,
                })
            else:
                mapping[source_export] = record
    return mapping, findings


def _names_from_function(function: Callable[..., Any], *, keyword: str | None = None) -> set[str]:
    """Extract literal names from a code-owned function for drift reporting."""

    try:
        tree = ast.parse(inspect.getsource(function))
    except (OSError, TypeError, SyntaxError):
        return set()
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Tool":
            if keyword is None:
                continue
            for item in node.keywords:
                if item.arg == keyword and isinstance(item.value, ast.Constant) and isinstance(item.value.value, str):
                    names.add(item.value.value)
        elif isinstance(node, ast.Compare) and isinstance(node.left, ast.Name) and node.left.id == "name":
            for item in node.comparators:
                if isinstance(item, ast.Constant) and isinstance(item.value, str):
                    names.add(item.value)
                elif isinstance(item, (ast.Set, ast.Tuple, ast.List)):
                    names.update(
                        value.value
                        for value in item.elts
                        if isinstance(value, ast.Constant) and isinstance(value.value, str)
                    )
    return names


def _capability_manifest_check() -> dict[str, Any]:
    """Return stable findings for manifest/declaration/dispatch drift."""

    findings: list[dict[str, Any]] = []
    manifest_ids: set[str] = set()
    manifest_names: list[str] = []
    dispatch_keys: list[str] = []
    source_map, source_findings = _manifest_source_map()
    findings.extend(source_findings)
    tool_index = _load_tool_index()
    indexed_ids: list[str] = []
    if not tool_index.get("ok"):
        findings.append({"code": "SOURCE_INDEX_UNAVAILABLE", "detail": str(tool_index.get("error", "tool index unavailable"))})
    else:
        for module in tool_index.get("modules", []):
            source_file = str(module.get("file") or "")
            for contract in module.get("contracts", []):
                indexed_ids.append(
                    _canonical_source_id(source_file, str(contract.get("export_name") or ""))
                )
        indexed_set = set(indexed_ids)
        for source_id in sorted(set(indexed_ids)):
            if source_id not in source_map:
                findings.append({
                    "code": "SOURCE_EXPORT_UNMAPPED",
                    "detail": f"indexed contract has no manifest owner: {source_id}",
                })
        for source_id in sorted(set(source_map) - indexed_set):
            findings.append({
                "code": "SOURCE_EXPORT_REF_UNKNOWN",
                "detail": f"manifest source reference is not indexed: {source_id}",
            })
        for source_id in sorted({source_id for source_id in indexed_ids if indexed_ids.count(source_id) > 1}):
            findings.append({
                "code": "SOURCE_EXPORT_REF_AMBIGUOUS",
                "detail": f"indexed source reference is duplicated: {source_id}",
            })
    for record in _CAPABILITY_MANIFEST:
        identifier = record.get("id")
        status = record.get("primary_status")
        if not identifier:
            findings.append({"code": "CAPABILITY_MANIFEST_ID_MISSING", "detail": repr(identifier)})
        elif identifier in manifest_ids:
            findings.append({"code": "CAPABILITY_MANIFEST_ID_DUPLICATE", "detail": identifier})
        else:
            manifest_ids.add(identifier)
        if status not in _CAPABILITY_STATUSES:
            findings.append({"code": "SOURCE_EXPORT_UNCLASSIFIED", "detail": f"{identifier}: {status!r}"})
        if record.get("mcp_name") is None:
            if record.get("dispatch_key") is not None or record.get("tool_factory") is not None:
                findings.append({"code": "SOURCE_RECORD_HAS_MCP_REGISTRATION", "detail": str(identifier)})
            continue
        name = record["mcp_name"]
        manifest_names.append(name)
        key = record.get("dispatch_key")
        if not key:
            findings.append({"code": "MCP_TOOL_DISPATCH_MISSING", "detail": name})
        else:
            dispatch_keys.append(key)
        if (
            not record.get("tool_factory")
            or record.get("tool_factory_ref") != record.get("tool_factory")
            or not record.get("schema_factory")
        ):
            findings.append({"code": "MCP_TOOL_FACTORY_MISSING", "detail": name})
    for value in sorted({value for value in manifest_names if manifest_names.count(value) > 1}):
        findings.append({"code": "MCP_TOOL_MANIFEST_DUPLICATE", "detail": value})
    for value in sorted({value for value in dispatch_keys if dispatch_keys.count(value) > 1}):
        findings.append({"code": "MCP_DISPATCH_KEY_DUPLICATE", "detail": value})
    declared_names = _names_from_function(_legacy_tool_declarations, keyword="name")
    for value in sorted(declared_names - set(manifest_names)):
        findings.append({"code": "MCP_TOOL_MISSING_MANIFEST", "detail": value})
    for value in sorted(set(manifest_names) - declared_names):
        findings.append({"code": "MCP_MANIFEST_ORPHAN_DECLARATION", "detail": value})
    dispatch_names = _names_from_function(_dispatch_tool_legacy)
    for value in sorted(dispatch_names - set(manifest_names)):
        findings.append({"code": "MCP_DISPATCH_ORPHAN_BRANCH", "detail": value})
    for value in sorted(set(manifest_names) - dispatch_names):
        findings.append({"code": "MCP_DISPATCH_MISSING_BRANCH", "detail": value})
    for source_export, record in source_map.items():
        if record.get("primary_status") not in _CAPABILITY_STATUSES:
            findings.append({"code": "SOURCE_EXPORT_UNCLASSIFIED", "detail": source_export})
    return {
        "ok": not findings,
        "findings": findings,
        "manifest_tool_count": len(manifest_names),
        "declaration_tool_count": len(declared_names),
        "dispatch_branch_count": len(dispatch_names),
        "source_export_count": len(source_map),
    }

async def _dispatch_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    """Route a tool invocation to its handler."""
    if name != "capability_status":
        manifest_check = _capability_manifest_check()
        manifest_names = {
            record["mcp_name"]
            for record in _CAPABILITY_MANIFEST
            if record["mcp_name"] is not None
        }
        if not manifest_check["ok"]:
            findings = [
                {**finding, "finding_code": finding.get("code")}
                for finding in manifest_check["findings"]
            ]
            return [TextContent(type="text", text=json.dumps({
                "ok": False,
                "error": "capability manifest inconsistent",
                "findings": findings,
            }))]
        if name not in manifest_names:
            return [TextContent(type="text", text=f"unknown tool: {name}")]
    try:
        if name == "run_lua_test":
            return [TextContent(type="text", text=json.dumps(await _run_lua_test(arguments)))]
        if name == "inspect_grid":
            return [TextContent(type="text", text=json.dumps(await _inspect_grid(arguments)))]
        if name == "build_and_trace":
            return [TextContent(type="text", text=json.dumps(await _build_and_trace(arguments)))]
        return await _dispatch_tool_legacy(name, arguments)
    except Exception as e:
        return [TextContent(type="text", text=f"dispatch error: {type(e).__name__}: {e}")]
async def _run_lua_test(arguments: dict[str, Any]) -> dict[str, Any]:
    """Execute a Lua script against the live bridge and return its result as JSON.

    Uses the real TPT Lua API (sim.partCreate, sim.partProperty, elem.property).
    The Lua script must return a table or call print(json.encode({...})) -- both are captured.
    step_frames=0 means no stepping (just inspect state); >0 advances the sim that many
    frames after the script runs (useful for letting physics settle).
    """
    bridge = (arguments.get("bridge") or "lab").lower()
    if bridge == "user":
        host, port = "127.0.0.1", 9876
    else:
        host, port = "127.0.0.1", 9877
    try:
        token_path = (
            Path("D:/The-Powder-Toy/build/powder-bridge.token")
            if bridge == "user"
            else REPO_ROOT / "lab_instance/ddir/powder-bridge.token"
        )
        token = token_path.read_text(encoding="utf-8").strip() if token_path.is_file() else ""
        if not token:
            return {"ok": False, "error": f"bridge token missing at {token_path}"}
        client = get_client_for(host, port, token)
        script = arguments.get("script") or ""
        if not script.strip():
            return {"ok": False, "error": "empty script"}
        # TPT's bridge tostring()s Lua tables as 'table: 0x...' which is useless -- we
        # need to JSON-encode the result ourselves before returning. json module is a
        # placeholder in this build (empty table, no encode method), so do it inline.
        # Limited types: number, string, boolean, nil, array table, dict table.
        encoder = (
            "local function _enc(v, s)\n"
            "s = s or {}\n"
            "if v == nil then return 'null' end\n"
            "local t = type(v)\n"
            "if t == 'number' then return tostring(v) end\n"
            "if t == 'boolean' then return v and 'true' or 'false' end\n"
            "if t == 'string' then return '\"' .. v:gsub('\\\\\\\\', '\\\\\\\\\\\\\\\\'):gsub('\"', '\\\\\\\\\"'):gsub('\\\\n', '\\\\\\\\n') .. '\"' end\n"
            "if t == 'table' then\n"
            "if s[v] then return '\"<cycle>\"' end\n"
            "s[v] = true\n"
            "local is_arr, n = true, 0\n"
            "for k, _ in pairs(v) do n = n + 1; if type(k) ~= 'number' then is_arr = false end end\n"
            "local parts = {}\n"
            "if is_arr and n > 0 then\n"
            "for i = 1, n do parts[#parts + 1] = _enc(v[i], s) end\n"
            "return '[' .. table.concat(parts, ',') .. ']'\n"
            "else\n"
            "local keys = {}; for k, _ in pairs(v) do keys[#keys + 1] = k end\n"
            "table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)\n"
            "for _, k in ipairs(keys) do parts[#parts + 1] = '\"' .. tostring(k) .. '\":' .. _enc(v[k], s) end\n"
            "return '{' .. table.concat(parts, ',') .. '}'\n"
            "end\n"
            "end\n"
            "return '\"' .. tostring(v) .. '\"'\n"
            "end\n"
            "local _ok, _ret = pcall(function()\n"
            + script
            + "\nend)\n"
            "if not _ok then return '\"' .. tostring(_ret) .. '\"' end\n"
            "if type(_ret) == 'table' then return _enc(_ret) end\n"
            "if type(_ret) == 'string' then return _ret end\n"
        )
        wrapped = encoder
        resp = client.execute_lua(wrapped)
        raw_result = resp.get("result") if isinstance(resp, dict) else resp
        # The wrapper returns a JSON-encoded string. Parse it back so callers get real JSON.
        result: Any
        try:
            result = json.loads(raw_result) if isinstance(raw_result, str) else raw_result
        except (ValueError, TypeError):
            result = raw_result
        step_frames = int(arguments.get("step_frames") or 0)
        if step_frames > 0:
            step_resp = client.step(step_frames)
            return {"ok": True, "result": result, "stepped": step_frames, "step_response": step_resp}
        return {"ok": True, "result": result, "stepped": 0}
    except Exception as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}


async def _inspect_grid(arguments: dict[str, Any]) -> dict[str, Any]:
    """Dump every particle inside a bounded pixel rectangle as JSON.

    Reads from sim.partID for each cell in the bounded rect and reports type+name+temp.
    Bounded to 10k entries (silent truncation with a 'truncated' flag if exceeded).
    """
    bridge = (arguments.get("bridge") or "lab").lower()
    x1 = max(0, min(611, int(arguments.get("x1") or 0)))
    y1 = max(0, min(383, int(arguments.get("y1") or 0)))
    x2 = max(0, min(611, int(arguments.get("x2") or 0)))
    y2 = max(0, min(383, int(arguments.get("y2") or 0)))
    if x2 < x1: x1, x2 = x2, x1
    if y2 < y1: y1, y2 = y2, y1
    width, height = x2 - x1 + 1, y2 - y1 + 1
    if width * height > 100000:
        return {"ok": False, "error": "bounding box too large; limit to 100k pixels"}
    try:
        token_path = (
            Path("D:/The-Powder-Toy/build/powder-bridge.token")
            if bridge == "user"
            else REPO_ROOT / "lab_instance/ddir/powder-bridge.token"
        )
        token = token_path.read_text(encoding="utf-8").strip() if token_path.is_file() else ""
        if not token:
            return {"ok": False, "error": f"bridge token missing at {token_path}"}
        client = get_client_for("127.0.0.1", 9876 if bridge == "user" else 9877, token)
        # Build Lua that scans the rect, then JSON-encodes the result via the inline encoder.
        # The inline encoder is the same _enc() we use in _run_lua_test -- duplicated here
        # for self-containment since each Lua call must stand alone (no module caching).
        enc = (
            "local function _enc(v, s)\n"
            "s = s or {}\n"
            "if v == nil then return 'null' end\n"
            "local t = type(v)\n"
            "if t == 'number' then return tostring(v) end\n"
            "if t == 'boolean' then return v and 'true' or 'false' end\n"
            "if t == 'string' then return '\"' .. v:gsub('\\\\\\\\', '\\\\\\\\\\\\\\\\'):gsub('\"', '\\\\\\\\\"'):gsub('\\\\n', '\\\\\\\\n') .. '\"' end\n"
            "if t == 'table' then\n"
            "if s[v] then return '\"<cycle>\"' end\n"
            "s[v] = true\n"
            "local is_arr, n = true, 0\n"
            "for k, _ in pairs(v) do n = n + 1; if type(k) ~= 'number' then is_arr = false end end\n"
            "local parts = {}\n"
            "if is_arr and n > 0 then\n"
            "for i = 1, n do parts[#parts + 1] = _enc(v[i], s) end\n"
            "return '[' .. table.concat(parts, ',') .. ']'\n"
            "else\n"
            "local keys = {}; for k, _ in pairs(v) do keys[#keys + 1] = k end\n"
            "table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)\n"
            "for _, k in ipairs(keys) do parts[#parts + 1] = '\"' .. tostring(k) .. '\":' .. _enc(v[k], s) end\n"
            "return '{' .. table.concat(parts, ',') .. '}'\n"
            "end\n"
            "end\n"
            "return '\"' .. tostring(v) .. '\"'\n"
            "end\n"
        )
        scan_lua = (
            f"local out = {{}}\n"
            f"for y = {y1}, {y2} do for x = {x1}, {x2} do\n"
            f"  local p = sim.partID(x, y)\n"
            f"  if p then\n"
            f"    local t = sim.partProperty(p, 'type')\n"
            f"    local ok, n = pcall(elem.property, t, 'Name')\n"
            f"    out[#out+1] = {{ x = x, y = y, type = t, name = ok and n or tostring(t), temp = sim.partProperty(p, 'temp'), life = sim.partProperty(p, 'life'), vx = sim.partProperty(p, 'vx'), vy = sim.partProperty(p, 'vy') }}\n"
            f"  end\n"
            f"end end\n"
            f"return _enc(out)\n"
        )
        resp = client.execute_lua(enc + scan_lua)
        raw = resp.get("result") if isinstance(resp, dict) else resp
        try:
            particles = json.loads(raw) if isinstance(raw, str) else (raw or [])
        except (ValueError, TypeError):
            particles = []
        truncated = False
        if isinstance(particles, list) and len(particles) > 10000:
            particles = particles[:10000]
            truncated = True
        return {
            "ok": True,
            "region": {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "width": width, "height": height},
            "particle_count": len(particles) if isinstance(particles, list) else 0,
            "particles": particles or [],
            "truncated": truncated,
            "bridge": bridge,
        }
    except Exception as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}


async def _build_and_trace(arguments: dict[str, Any]) -> dict[str, Any]:
    """Configure meson with ASan/UBSan, rebuild powder.exe, run smoke test, capture trace.

    Returns a structured response with build log tail, test stdout/stderr, and any
    ASan/UBSan findings. Designed to surface C++ memory bugs that Lua-level
    verification cannot catch (out-of-bounds reads, use-after-free, UB).
    """
    build_dir = (arguments.get("build_dir") or "build-asan").strip()
    sanitize = (arguments.get("sanitize") or "address,undefined").strip()
    smoke_seconds = float(arguments.get("smoke_seconds") or 5.0)
    base_dir = TPT_BUILD_DIR / build_dir
    powder_src = Path("D:/The-Powder-Toy")
    out = {"ok": False, "build_dir": str(base_dir), "sanitize": sanitize}
    try:
        # 1. meson setup with sanitizer
        setup = subprocess.run(
            ["meson", "setup", str(base_dir), str(powder_src), f"-Db_sanitize={sanitize}", "--buildtype=debugoptimized"],
            cwd="D:/The-Powder-Toy",
            capture_output=True,
            text=True,
            timeout=120,
        )
        out["setup_stdout_tail"] = setup.stdout[-2000:] if setup.stdout else ""
        out["setup_stderr_tail"] = setup.stderr[-2000:] if setup.stderr else ""
        if setup.returncode != 0:
            out["error"] = f"meson setup failed (rc={setup.returncode})"
            return out
        # 2. meson compile
        compile_proc = subprocess.run(
            ["meson", "compile", "-C", str(base_dir), "powder.exe"],
            cwd="D:/The-Powder-Toy",
            capture_output=True,
            text=True,
            timeout=600,
        )
        out["build_log_tail"] = compile_proc.stderr[-3000:] if compile_proc.stderr else ""
        if compile_proc.returncode != 0:
            out["error"] = f"build failed (rc={compile_proc.returncode})"
            return out
        out["built"] = True
        # 3. run smoke test
        exe = base_dir / "powder.exe"
        if not exe.is_file():
            out["error"] = "powder.exe not found after build"
            return out
        smoke = subprocess.run(
            [str(exe)],
            cwd=str(powder_src),
            capture_output=True,
            text=True,
            timeout=int(smoke_seconds) + 5,
        )
        out["test_stdout"] = (smoke.stdout or "")[-2000:]
        out["test_stderr"] = (smoke.stderr or "")[-3000:]
        out["test_returncode"] = smoke.returncode
        # parse ASan/UBSan findings
        findings = []
        for line in (smoke.stderr or "").splitlines():
            if "ERROR: AddressSanitizer" in line or "runtime error:" in line:
                findings.append(line.strip())
        out["sanitizer_findings"] = findings[-50:]
        out["ok"] = smoke.returncode == 0 and len(findings) == 0
        out["crash"] = smoke.returncode != 0 and not findings
        return out
    except subprocess.TimeoutExpired as exc:
        out["error"] = f"timeout: {exc}"
        return out
async def _dispatch_tool_legacy(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    """Original dispatch chain (preserved verbatim minus reformatting)."""
    if name != "capability_status":
        manifest_check = _capability_manifest_check()
        manifest_names = {
            record["mcp_name"]
            for record in _CAPABILITY_MANIFEST
            if record["mcp_name"] is not None
        }
        if not manifest_check["ok"]:
            findings = [
                {**finding, "finding_code": finding.get("code")}
                for finding in manifest_check["findings"]
            ]
            return [TextContent(type="text", text=json.dumps({
                "ok": False,
                "error": "capability manifest inconsistent",
                "findings": findings,
            }))]
        if name not in manifest_names:
            return [TextContent(type="text", text=f"unknown tool: {name}")]
    try:
        if name == "launch_powder_toy":
            if _port_listening():
                return [TextContent(type="text", text=json.dumps({
                    "ok": True,
                    "launched": False,
                    "reason": "port already listening",
                }))]
            token_path = Path("D:/The-Powder-Toy/build/powder-bridge.token")
            if not token_path.is_file():
                return [TextContent(type="text", text="launch refused: missing powder-bridge.token")]
            proc = subprocess.Popen(
                ["cmd.exe", "/c", str(REPO_ROOT / "launch_powder_detached.cmd")],
                cwd="D:/The-Powder-Toy/build",
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return [
                TextContent(
                    type="text",
                    text=f"Powder Toy launch requested (launcher PID {proc.pid}); query powder_status for readiness.",
                )
            ]

        elif name == "rebuild_powder_toy":
            build_dir = TPT_BUILD_DIR
            vcvars_bat = (
                r'"C:\Program Files\Microsoft Visual Studio\2022\Community'
                r'\VC\Auxiliary\Build\vcvarsall.bat"'
            )

            autorun = subprocess.run(
                [sys.executable, str(REPO_ROOT / "build_autorun.py")],
                capture_output=True, text=True, timeout=60,
            )
            if autorun.returncode != 0:
                return [TextContent(type="text", text=json.dumps({
                    "ok": False, "stage": "build_autorun",
                    "output_tail": (autorun.stdout + autorun.stderr)[-4000:],
                }))]

            killed_pids = []
            for p in psutil.process_iter(["pid", "name"]):
                try:
                    if (p.info["name"] or "").lower() == "powder.exe":
                        p.kill()
                        killed_pids.append(p.info["pid"])
                except Exception:
                    pass
            if killed_pids:
                time.sleep(1)  # let the linker's output file free up

            build_cmd = f'{vcvars_bat} x64 >nul 2>&1 && cd /d {build_dir} && ninja powder.exe'
            build = subprocess.run(
                ["cmd.exe", "/c", build_cmd],
                capture_output=True, text=True, timeout=280,
            )
            build_ok = build.returncode == 0 and "FAILED" not in build.stdout
            if not build_ok:
                return [TextContent(type="text", text=json.dumps({
                    "ok": False, "stage": "ninja", "returncode": build.returncode,
                    "killed_pids": killed_pids,
                    "output_tail": (build.stdout + build.stderr)[-4000:],
                }))]

            DETACHED_PROCESS = 0x00000008
            CREATE_NEW_PROCESS_GROUP = 0x00000200
            proc = subprocess.Popen(
                [str(build_dir / "powder.exe")],
                cwd=str(build_dir),
                creationflags=DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
                close_fds=True,
            )
            time.sleep(1.5)
            return [TextContent(type="text", text=json.dumps({
                "ok": True,
                "killed_pids": killed_pids,
                "relaunched_pid": proc.pid,
                "still_running_after_1.5s": proc.poll() is None,
                "build_output_tail": build.stdout[-1500:],
            }))]

        elif name == "powder_status":

            procs = []
            for p in psutil.process_iter(["pid", "name", "cmdline"]):
                try:
                    if "powder" in (p.info["name"] or "").lower():
                        procs.append(
                            {
                                "pid": p.info["pid"],
                                "name": p.info["name"],
                                "cmdline": p.info.get("cmdline"),
                            }
                        )
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue


            # Check port

            port_open = False
            try:
                with socket.create_connection(("127.0.0.1", 9876), timeout=1):
                    port_open = True
            except Exception:
                pass

            status = {"powder_processes": procs, "port_9876_listening": port_open}
            return [TextContent(type="text", text=json.dumps(status, indent=2))]

        elif name == "health_check":
            c = get_client()
            try:
                alive = c.is_alive()
                return [TextContent(type="text", text=json.dumps({"alive": alive}))]
            except Exception as e:
                return [TextContent(type="text", text=json.dumps({"alive": False, "error": str(e)}))]

        elif name == "get_field":
            result = get_client().get_field(
                arguments["field"],
                x=arguments["x"],
                y=arguments["y"],
            )
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "spatial_snapshot":
            try:
                result = _spatial_snapshot(arguments)
            except (TypeError, ValueError) as exc:
                result = {
                    "ok": False,
                    "tool": "spatial_snapshot",
                    "error_code": "invalid_request",
                    "error": str(exc),
                    "limits": {
                        "max_region_area": SPATIAL_MAX_REGION_AREA,
                        "max_samples": SPATIAL_MAX_SAMPLES,
                        "max_particles": SPATIAL_MAX_PARTICLES,
                        "max_particle_ids": SPATIAL_MAX_PARTICLE_IDS,
                        "max_stride": SPATIAL_MAX_STRIDE,
                    },
                    "evidence": {
                        "contract": "spatial-evidence/v1",
                        "status": "failed",
                        "postcondition_ok": False,
                        "complete": False,
                        "strength": "absent",
                        "reason": "invalid_request",
                    },
                }
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "parts_inventory":
            try:
                result = _parts_inventory(arguments)
            except (TypeError, ValueError) as exc:
                result = {
                    "ok": False,
                    "action": "partsInventory",
                    "tool": "parts_inventory",
                    "schema_version": "parts-inventory/v1",
                    "error_code": "invalid_request",
                    "error": str(exc),
                    "limits": {
                        "max_limit": PARTS_INVENTORY_MAX_LIMIT,
                        "max_scan": PARTS_INVENTORY_MAX_SCAN,
                        "slot_bound": PARTS_INVENTORY_MAX_SLOTS,
                    },
                    "provenance": {
                        "source_root": "D:/The-Powder-Toy",
                        "runtime_deploy": "D:/The-Powder-Toy/build/autorun.lua",
                        "mcp_source_root": str(REPO_ROOT),
                        "particle_source": "sim.partExists/partPosition/partProperty",
                        "slot_bound_source": "SimulationConfig.h:NPART=XRES*YRES",
                        "slot_bound": PARTS_INVENTORY_MAX_SLOTS,
                        "pid_source": "runtime_binding_or_unavailable",
                        "cursor_source": "raw_particle_slot",
                        "part_count_source": "sim.partCount",
                    },
                    "evidence": {
                        "contract": "parts-inventory-evidence/v1",
                        "correlation_id": current_correlation_id(),
                        "status": "failed",
                        "postcondition_ok": False,
                        "complete": False,
                        "strength": "absent",
                        "reason": "invalid_request",
                    },
                }
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "design_intake":
            try:
                result = _design_intake(arguments)
            except (TypeError, ValueError, KeyError) as exc:
                result = {
                    "ok": False,
                    "tool": "design_intake",
                    "error_code": "invalid_request",
                    "error": str(exc),
                    "errors": [str(exc)],
                    "limitations": ["design intake request failed validation; no mutation was attempted"],
                    "rubric": {},
                    "checkpoint": None,
                    "spatial_snapshots": [],
                    "inventory_pages": [],
                    "catalog": None,
                    "state": None,
                    "modes": None,
                }
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "coordinate_helper":
            result = _coordinate_helper(arguments)
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "execute_action":
            c = get_client()
            action = arguments.get("action")
            params = arguments.get("params", {})
            if not isinstance(action, str) or action not in ALLOWED_GENERIC_ACTIONS:
                return [TextContent(type="text", text=json.dumps({"ok": False, "error": "action not allowed"}))]
            if not isinstance(params, dict):
                return [TextContent(type="text", text=json.dumps({"ok": False, "error": "params must be an object"}))]
            reserved = {"action", "token", "correlation_id"} & set(params)
            if reserved:
                return [TextContent(type="text", text=json.dumps({"ok": False, "error": "reserved parameter"}))]
            try:
                if action == "getField":
                    if set(params) - {"field", "x", "y"} or not {"field", "x", "y"} <= set(params):
                        return [TextContent(type="text", text=json.dumps({"ok": False, "error": "getField requires exactly field, x, y parameters"}))]
                    resp = c.get_field(
                        params["field"],
                        x=params["x"],
                        y=params["y"],
                    )
                else:
                    payload = dict(params)
                    payload["action"] = action
                    resp = c._post(payload)
                return [TextContent(type="text", text=json.dumps(resp))]
            except (PowderAPIError, PowderConnectionError) as e:
                return [TextContent(type="text", text=json.dumps({"ok": False, "error": str(e)}))]

        elif name == "step_sim":
            c = get_client()
            n = arguments.get("n", 1)
            resp = c.step(n)
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "place_element":
            c = get_client()
            resp = c.place_element(
                element=arguments["element"],
                x1=arguments["x1"],
                y1=arguments["y1"],
                x2=arguments["x2"],
                y2=arguments["y2"],
            )
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "place_element_line":
            resp = get_client().place_element_line(
                arguments["element"],
                x1=arguments["x1"], y1=arguments["y1"],
                x2=arguments["x2"], y2=arguments["y2"],
            )
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "place_wall_line":
            resp = get_client().place_wall_line(
                arguments["wall"],
                x1=arguments["x1"], y1=arguments["y1"],
                x2=arguments["x2"], y2=arguments["y2"],
            )
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "place_wall_box":
            c = get_client()
            resp = c.place_wall_box(
                arguments["wall"],
                x1=arguments["x1"],
                y1=arguments["y1"],
                x2=arguments["x2"],
                y2=arguments["y2"],
            )
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "apply_native_tool_box":
            c = get_client()
            resp = c.apply_tool_box(
                arguments["tool"],
                x1=arguments["x1"],
                y1=arguments["y1"],
                x2=arguments["x2"],
                y2=arguments["y2"],
                strength=arguments.get("strength", 1.0),
                brush=arguments.get("brush", 0),
                rx=arguments.get("rx", 0),
                ry=arguments.get("ry", 0),
            )
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "get_simulation_state":
            c = get_client()
            resp = c.get_simulation_state()
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "place_deco_box":
            c = get_client()
            resp = c.place_deco_box(
                x1=arguments["x1"], y1=arguments["y1"],
                x2=arguments["x2"], y2=arguments["y2"],
                r=arguments["r"], g=arguments["g"], b=arguments["b"],
                a=arguments.get("a", 255), tool=arguments.get("tool", 0),
            )
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "place_deco_line":
            resp = get_client().place_deco_line(
                x1=arguments["x1"], y1=arguments["y1"],
                x2=arguments["x2"], y2=arguments["y2"],
                r=arguments["r"], g=arguments["g"], b=arguments["b"],
                a=arguments.get("a", 255), tool=arguments.get("tool", 0),
                brush=arguments.get("brush", 0),
                rx=arguments.get("rx", 5), ry=arguments.get("ry", 5),
            )
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "place_deco_point":
            client = get_client()
            resp = client.place_deco_point(
                x=arguments["x"], y=arguments["y"],
                r=arguments.get("r", 255), g=arguments.get("g", 255),
                b=arguments.get("b", 255), a=arguments.get("a", 255),
                tool=arguments.get("tool", 0), brush=arguments.get("brush", 0),
                rx=arguments.get("rx", 5), ry=arguments.get("ry", 5),
            )
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "list_stamps":
            return [TextContent(type="text", text=json.dumps(get_client().list_stamps()))]

        elif name == "save_stamp":
            resp = get_client().save_stamp(
                x=arguments["x"], y=arguments["y"],
                width=arguments["width"], height=arguments["height"],
                include_pressure=arguments.get("include_pressure", True),
            )
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "load_stamp":
            resp = get_client().load_stamp(arguments["name"], x=arguments.get("x", 0), y=arguments.get("y", 0))
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "delete_stamp":
            return [TextContent(type="text", text=json.dumps(get_client().delete_stamp(arguments["name"])))]
        elif name == "get_particle":
            c = get_client()
            resp = c.get_particle(int(arguments["particle_id"]))
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "create_particle":
            resp = get_client().create_particle(arguments["element"], x=arguments["x"], y=arguments["y"])
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "change_particle_type":
            resp = get_client().change_particle_type(arguments["particle_id"], arguments["element"])
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "set_particle_property":
            resp = get_client().set_particle_property(
                arguments["particle_id"], arguments["property"], arguments["value"]
            )
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "kill_particle":
            resp = get_client().kill_particle(arguments["particle_id"])
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "get_simulation_modes":
            c = get_client()
            resp = c.get_simulation_modes()
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "set_simulation_modes":
            c = get_client()
            resp = c.set_simulation_modes(
                edge_mode=arguments.get("edge_mode"),
                gravity_mode=arguments.get("gravity_mode"),
                air_mode=arguments.get("air_mode"),
                paused=arguments.get("paused"),
            )
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "set_custom_gravity":
            client = get_client()
            resp = client.set_custom_gravity(gx=arguments["gx"], gy=arguments["gy"])
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "set_edge_pressure":
            client = get_client()
            resp = client.set_edge_pressure(value=arguments["value"])
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "set_edge_velocity":
            client = get_client()
            resp = client.set_edge_velocity(vx=arguments["vx"], vy=arguments["vy"])
            return [TextContent(type="text", text=json.dumps(resp))]

        elif name == "set_field_region":
            c = get_client()
            resp = c.set_field_region(
                arguments["field"],
                x1=arguments["x1"], y1=arguments["y1"],
                x2=arguments["x2"], y2=arguments["y2"],
                value=arguments["value"],
            )
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "clear_sim":
            c = get_client()
            resp = c.clear()
            return [TextContent(type="text", text=json.dumps(resp))]
        elif name == "draw_project":
            c = get_client()
            project_name = str(arguments.get("name", "project"))
            components = arguments.get("components", [])
            if not isinstance(components, list):
                return [TextContent(type="text", text=json.dumps({"ok": False, "error": "components must be an array"}))]
            result = _draw_components(
                c,
                project_name,
                components,
                bool(arguments.get("clear_before", False)),
            )
            return [TextContent(type="text", text=json.dumps(result))]

        elif name == "draw_house":
            c = get_client()
            x = int(arguments.get("x", 176))
            y = int(arguments.get("y", 154))
            width = int(arguments.get("width", 260))
            height = int(arguments.get("height", 166))
            if width < 200 or height < 120 or width > 500 or height > 300:
                return [TextContent(type="text", text=json.dumps({"ok": False, "error": "house dimensions out of range"}))]
            components = _house_components(
                x,
                y,
                width,
                height,
                arguments.get("materials"),
            )
            result = _draw_components(
                c,
                "house",
                components,
                bool(arguments.get("clear_before", False)),
            )
            return [TextContent(type="text", text=json.dumps(result))]

        elif name == "powder_tool_index":
            result = _load_tool_index(
                query=arguments.get("query"),
                module=arguments.get("module"),
            )
            return [TextContent(type="text", text=json.dumps(result))]

        elif name == "rapid_build":
            plan = arguments.get("plan")
            if not isinstance(plan, dict):
                return [TextContent(type="text", text=json.dumps({"ok": False, "error": "plan must be an object"}))]
            result = _rapid_build(get_client(), plan)
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "material_catalog":
            result = _load_material_catalog(arguments.get("query"))
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "native_catalog":
            result = _load_native_catalog(
                query=arguments.get("query"),
                kind=arguments.get("kind"),
            )
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "runtime_diagnostics":
            return [TextContent(type="text", text=json.dumps(_runtime_diagnostics()))]
        elif name == "catalog_status":
            include_runtime = arguments.get("include_runtime", True)
            result = _catalog_status(
                query=arguments.get("query"),
                include_runtime=bool(include_runtime),
            )
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "read_operation_log":
            result = _read_operation_log(
                limit=int(arguments.get("limit", 50)),
                action=arguments.get("action"),
                correlation_id=arguments.get("correlation_id"),
                ok=arguments.get("ok"),
            )
            return [TextContent(type="text", text=json.dumps(result))]
        elif name == "experiment_feedback":
            return [TextContent(type="text", text=json.dumps(_experiment_feedback(arguments)))]
        elif name == "record_build_lesson":
            return [TextContent(type="text", text=json.dumps(_record_build_lesson(arguments)))]
        elif name == "build_lessons":
            return [TextContent(type="text", text=json.dumps(_build_lessons(arguments)))]
        elif name in (
            "define_element",
            "list_custom_elements",
            "update_element",
            "delete_custom_element",
            "colony_create",
            "colony_list",
            "colony_status",
            "colony_destroy",
            "spawn_workers",
            "kill_workers",
            "assign_task",
            "task_status",
            "cancel_task",
            "extension_status",
            "extension_self_test",
            "reset_creature_faults",
            "execute_lua",
            "blueprint_build",
            "blueprint_schema",
            "build_practices",
            "realism_apply",
            "realism_status",
            "world_state",
            "next_task",
            "record_attempt",
            "blueprint_grammar",
            "module_search",
            "find_features",
            "run_test",
            "build_stage",
            "run_pipeline",
            "blueprint_lint",
            "blueprint_module_save",
            "element_facts",
            "person_inspect",
            "person_move",
            "person_kill",
            "person_set_trait",
            "person_feed",
            "person_recolor",
            "world_place_hazard",
            "snapshot_fast",
            "screenshot",
            "replay_hash_check",
            "rpg_status",
            "rpg_search",
            "rpg_api",
            "rpg_hub",
            "rpg_reload",
            "rpg_screenshot",
            "rpg_lua",
        ):
            return [TextContent(type="text", text=json.dumps(_dispatch_extension(name, arguments), default=str))]
        elif name == "run_lua_test":
            return [TextContent(type="text", text=json.dumps(_run_lua_test(arguments)))]
        elif name == "inspect_grid":
            return [TextContent(type="text", text=json.dumps(_inspect_grid(arguments)))]
        elif name == "build_and_trace":
            return [TextContent(type="text", text=json.dumps(_build_and_trace(arguments)))]
        elif name == "experiment_run":
            return [TextContent(type="text", text=json.dumps(_experiment_run(arguments)))]
        elif name == "experiment_evaluate":
            return [TextContent(type="text", text=json.dumps(_experiment_evaluate(arguments)))]
        elif name == "capability_status":
            return [TextContent(type="text", text=json.dumps(_capability_status()))]
        else:
            return [TextContent(type="text", text=f"unknown tool: {name}")]

    except Exception as e:
        return [TextContent(type="text", text=f"tool error: {type(e).__name__}: {e}")]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    cid, token = bind_correlation_id()
    started = time.perf_counter()
    error: str | None = None
    ok = False
    before_state: dict[str, Any] | None = None
    payload: dict[str, Any] = {}
    try:
        args = arguments or {}
        if name in {"place_element", "place_element_line"}:
            before_state, _before_err = _safe_read(get_client().get_simulation_state)
        dispatched = await _dispatch_tool(name, args)
        finalized = _finalize_mcp_result(name, args, dispatched, cid, before_state)
        payload = _coerce_tool_payload(finalized[0].text)
        ok = payload.get("ok") is not False
        if not ok:
            error = str(payload.get("error") or payload.get("message") or "tool_failed")
        return finalized
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
        evidence = None
        if name in _MUTATION_TOOLS:
            evidence = _evidence(_requested(name, arguments or {}), None, False, reason="transport_error")
        return [TextContent(type="text", text=json.dumps(_attach({"ok": False, "error": error}, cid, evidence)))]
    finally:
        if not (
            name == "experiment_feedback"
            and payload.get("persisted") is True
        ):
            emit(
                request=name,
                action=name,
                correlation_id=cid,
                phase="mcp",
                ok=False if error else ok,
                error=error,
                duration_ms=(time.perf_counter() - started) * 1000.0,
                response_summary=(
                    payload.get("log_record")
                    if name == "experiment_feedback" and isinstance(payload.get("log_record"), dict)
                    else {"ok": False if error else ok, "error": error}
                ),
            )
        reset_correlation_id(token)

async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )

if __name__ == "__main__":
    # ponytail: force the numpy-backed powder_ext import to happen single-threaded,
    # before stdio_server()'s worker threads exist - a lazy import racing those
    # threads deadlocks on Windows' DLL loader lock (native extension init on one
    # thread vs. blocking I/O on another).
    _ext_registry()
    asyncio.run(main())
