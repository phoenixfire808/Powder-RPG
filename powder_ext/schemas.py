"""Single source of truth for the Powder Bridge extension's MCP tool surface.

This module is the *only* place the 15 `powder_ext` MCP tools are named,
described, and typed. Nothing else in the extension package should hand-roll a
JSON Schema, a description string, or a read-only/mutating classification —
`element_tools.py`, `colony_tools.py`, `selftest.py`, and whatever central
registration `powder_toy_mcp.py` performs read `TOOL_SCHEMAS`,
`TOOL_DESCRIPTIONS`, `TOOL_READONLY`, and `TOOL_ORDER` from here. Keeping the
declarations in one file means the bridge action tables in
`D:/powder-toy/EXTENSION_SPEC.md` (sections 4.1, 4.3-4.6) have exactly one
Python mirror to stay in sync with, instead of one per handler module.

House style, matched to `_legacy_tool_declarations` in
`D:/powder-toy/powder_toy_mcp.py`:
    - every top-level schema is `{"type": "object", "additionalProperties": False}`
    - bounds are explicit `minimum`/`maximum`/`maxLength`/`maxItems`, never left
      implicit
    - closed value sets are `enum`, not free-form strings
    - `required` is listed explicitly, never implied by "no default"
    - no `oneOf`/`allOf`/`anyOf` anywhere in the existing tool declarations
      (verified by grep) and no `type` arrays (e.g. `["string","integer"]`) --
      so `assign_task`'s per-kind `params` is written the same way
      `draw_project`'s `components` items are: a single flat, permissive
      object carrying every documented key from every task kind as an
      *optional* sibling, discriminated at runtime by `kind`, not by JSON
      Schema. See the `_assign_task_params_schema()` docstring below for the
      full reasoning.

This module performs no work at import time -- it only builds dict/tuple
literals. Call `validate()` (from the test harness) to assert the four names
below are internally consistent.
"""

from typing import Any

# ---------------------------------------------------------------------------
# Hard caps mirrored from `PBX.*` in D:/powder-toy/bridge_src/00_util.lua.
# These are the contract; JSON Schema bounds below must not exceed them.
# ---------------------------------------------------------------------------

MAX_WORKERS_PER_COLONY = 400
MAX_COLONIES = 8
MAX_TASKS_PER_COLONY = 16
MAX_BLUEPRINT_CELLS = 4096
MAX_CUSTOM_ELEMENTS = 40

# PBX.SIM_W, PBX.SIM_H = 612, 384 -> valid pixel coordinates are 0..611 / 0..383.
PIXEL_X_MAX = 611
PIXEL_Y_MAX = 383
# PBX.CELL_W, PBX.CELL_H = 153, 96 -> valid cell coordinates are 0..152 / 0..95.
CELL_X_MAX = 152
CELL_Y_MAX = 95
# PBX.SIM_W * PBX.SIM_H = 612 * 384 = 235008 -> NPART slot-count precedent
# (SimulationConfig.h:NPART=XRES*YRES, the same bound bridge_base.lua's
# partsInventory action documents), used as the particleId upper bound.
MAX_PARTICLE_ID = 612 * 384

# Powder Toy engine-wide temperature bounds. EXTENSION_SPEC.md does not restate
# these (they live in the base simulation, not the bridge), but any
# temperature field defineElement/updateElement accepts must stay inside them
# or the bridge's own vNum bound would reject it downstream anyway.
MIN_TEMP = -273.15
MAX_TEMP = 9999.99

ELEMENT_NAME_PATTERN = r"^[A-Z0-9]{1,4}$"
# defineElement's `colour` is documented as `0xRRGGBB` (spec 4.1).
COLOUR_RGB_PATTERN = r"^0[xX][0-9A-Fa-f]{6}$"
# colonyCreate's `colour` seeds the per-particle `dcolour` field, documented in
# spec section 3 as `0xAARRGGBB` -- one more hex pair (alpha) than an element
# colour. Aligning the two colour formats with their respective tables is an
# interpretation call; see the report for the ambiguity note.
COLOUR_ARGB_PATTERN = r"^0[xX][0-9A-Fa-f]{8}$"

ELEMENT_TYPE_ENUM = ["PART", "LIQUID", "SOLID", "GAS", "ENERGY"]
BEHAVIOR_KIND_ENUM = [
    "inert", "glower", "decayer", "emitter", "grower",
    "pheromone", "conductor", "creature",
    # runtime-registered kinds (scripts/lua/power_kinds.lua, 2026-08-26)
    "absorber", "turbine", "teg",
    "photovoltaic", "piezo", "pcm", "reactive",
]
TASK_KIND_ENUM = [
    "gather", "dig", "buildLine", "buildBox", "buildCircle",
    "buildBlueprint", "patrol",
]
BUILD_SOURCE_ENUM = ["store", "spawn"]
PERSON_TRAIT_ENUM = ["builder", "gatherer", "coward", "brave", "lazy"]
WORLD_HAZARD_ENUM = ["fire", "lava", "acid", "void"]


def _pixel_x(description: str = "") -> dict[str, Any]:
    """0..611 pixel-space X coordinate (PBX.vPixel)."""
    schema: dict[str, Any] = {"type": "integer", "minimum": 0, "maximum": PIXEL_X_MAX}
    if description:
        schema["description"] = description
    return schema


def _pixel_y(description: str = "") -> dict[str, Any]:
    """0..383 pixel-space Y coordinate (PBX.vPixel)."""
    schema: dict[str, Any] = {"type": "integer", "minimum": 0, "maximum": PIXEL_Y_MAX}
    if description:
        schema["description"] = description
    return schema


def _pixel_region_schema() -> dict[str, Any]:
    """Inclusive pixel-space rectangle `{x1,y1,x2,y2}` used by gather/dig regions."""
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "x1": _pixel_x(), "y1": _pixel_y(),
            "x2": _pixel_x(), "y2": _pixel_y(),
        },
        "required": ["x1", "y1", "x2", "y2"],
    }


def _element_define_fields() -> dict[str, dict]:
    """Property definitions shared by `define_element` and `update_element`
    (spec 4.1 `defineElement`/`updateElement` request tables). Kept in one
    place so the two tools cannot silently drift apart.
    """
    return {
        "name": {
            "type": "string",
            "pattern": ELEMENT_NAME_PATTERN,
            "maxLength": 4,
            "description": "1-4 char A-Z/0-9 identifier for the custom element (no underscore).",
        },
        "group": {
            "type": "string",
            "maxLength": 32,
            "default": "PBX",
            "description": "Element group/category label; defaults to PBX.",
        },
        "description": {"type": "string", "maxLength": 240},
        "colour": {
            "type": "string",
            "pattern": COLOUR_RGB_PATTERN,
            "maxLength": 8,
            "description": "Element colour as 0xRRGGBB.",
        },
        "menuSection": {"type": "string", "maxLength": 32},
        "type": {
            "type": "string",
            "enum": ELEMENT_TYPE_ENUM,
            "description": "Physical category the element behaves as.",
        },
        "properties": {
            "type": "array",
            "items": {"type": "string", "maxLength": 32},
            "maxItems": 16,
            "description": "TPT property flag names to set on the element, e.g. PROP_CONDUCTS.",
        },
        "temperature": {"type": "number", "minimum": MIN_TEMP, "maximum": MAX_TEMP},
        "highTemperature": {"type": "number", "minimum": MIN_TEMP, "maximum": MAX_TEMP},
        "highTemperatureTransition": {
            "type": "string",
            "maxLength": 32,
            "description": "Element name/id to transition into above highTemperature.",
        },
        "lowTemperature": {"type": "number", "minimum": MIN_TEMP, "maximum": MAX_TEMP},
        "lowTemperatureTransition": {
            "type": "string",
            "maxLength": 32,
            "description": "Element name/id to transition into below lowTemperature.",
        },
        "hardness": {"type": "integer", "minimum": 0, "maximum": 100},
        "weight": {"type": "integer", "minimum": 1, "maximum": 100},
        "gravity": {"type": "number", "minimum": -10, "maximum": 10},
        "diffusion": {"type": "number", "minimum": 0, "maximum": 50},
        "flammable": {"type": "integer", "minimum": 0, "maximum": 1000},
        "explosive": {"type": "integer", "minimum": 0, "maximum": 100},
        "heatConduct": {"type": "integer", "minimum": 0, "maximum": 255},
        "behavior": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "kind": {"type": "string", "enum": BEHAVIOR_KIND_ENUM},
                "params": {
                    "type": "object",
                    "maxProperties": 16,
                    "description": "Free-form params passed to PBX.state.behaviors.kinds[kind].make().",
                },
            },
            "required": ["kind"],
        },
    }


def _assign_task_params_schema() -> dict[str, Any]:
    """`assign_task`'s `params` object (spec 4.5 task-kind table).

    Decision on `oneOf`: the seven task kinds each want a different params
    shape, which is exactly the situation JSON Schema's `oneOf` keyed on a
    discriminator is built for. But `_legacy_tool_declarations` in
    `powder_toy_mcp.py` never uses `oneOf`/`allOf`/`anyOf` anywhere (checked
    with grep across the whole file) -- the one existing tool with the same
    problem, `draw_project`, solves it by giving `components` items a `kind`
    enum plus every field any kind might need as an optional sibling, with
    only `kind` required. That is the house convention this file is written
    to match, so `params` below follows the same shape: every key any task
    kind uses is declared once, all optional, `additionalProperties: False`
    at the top so typos are still caught, and the handler in
    `colony_tools.py` is responsible for checking that the keys present match
    `kind`. Consistency with the existing server's convention wins over the
    theoretical precision of a keyed `oneOf`.
    """
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "element": {
                "type": "string",
                "maxLength": 32,
                "description": "Element name or numeric id (PBX.vElem); used by every kind except patrol.",
            },
            "region": _pixel_region_schema(),
            "amount": {"type": "integer", "minimum": 1, "maximum": 100000},
            "x1": _pixel_x(), "y1": _pixel_y(),
            "x2": _pixel_x(), "y2": _pixel_y(),
            "cx": _pixel_x(), "cy": _pixel_y(),
            "radius": {"type": "integer", "minimum": 0, "maximum": 721},
            "filled": {"type": "boolean", "default": False},
            "source": {
                "type": "string",
                "enum": BUILD_SOURCE_ENUM,
                "description": "'store' consumes gathered material, 'spawn' materialises it for free.",
            },
            "cells": {
                "type": "array",
                "maxItems": MAX_BLUEPRINT_CELLS,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "x": _pixel_x(), "y": _pixel_y(),
                        "element": {"type": "string", "maxLength": 32},
                    },
                    "required": ["x", "y", "element"],
                },
                "description": "Flat blueprint cell list for buildBlueprint, up to MAX_BLUEPRINT_CELLS.",
            },
            "points": {
                "type": "array",
                "maxItems": 256,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {"x": _pixel_x(), "y": _pixel_y()},
                    "required": ["x", "y"],
                },
                "description": "Waypoint list for patrol.",
            },
            "loops": {
                "type": "integer",
                "minimum": 0,
                "maximum": 1000,
                "description": "Number of times patrol repeats its waypoint list.",
            },
        },
    }


def _build_schemas() -> dict[str, dict]:
    """Construct the JSON Schema for every MCP tool. Kept as one factory
    function (rather than 15 module-level literals) so shared fragments like
    `_element_define_fields()` are computed once per call and cannot drift
    between `define_element` and `update_element`.
    """
    element_fields = _element_define_fields()

    schemas: dict[str, dict] = {}

    schemas["define_element"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": dict(element_fields),
        "required": ["name", "type"],
    }

    schemas["list_custom_elements"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {},
    }

    schemas["update_element"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": dict(element_fields),
        "required": ["name"],
    }

    schemas["delete_custom_element"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {"name": dict(element_fields["name"])},
        "required": ["name"],
    }

    schemas["colony_create"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "name": {"type": "string", "maxLength": 32},
            "nestX": _pixel_x("Pixel-space X of the colony's nest/home point."),
            "nestY": _pixel_y("Pixel-space Y of the colony's nest/home point."),
            "colour": {
                "type": "string",
                "pattern": COLOUR_ARGB_PATTERN,
                "maxLength": 10,
                "description": "Colony tint as 0xAARRGGBB, stored per-worker as dcolour.",
            },
            "pheromoneDecay": {
                "type": "number",
                "minimum": 0,
                "maximum": 1,
                "description": "Fraction of pheromone strength lost per tick.",
            },
        },
        "required": ["name", "nestX", "nestY"],
    }

    schemas["colony_list"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {},
    }

    colony_id_field = {
        "type": "integer",
        "minimum": 1,
        "description": "Colony id returned by colony_create.",
    }

    schemas["colony_status"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {"colonyId": dict(colony_id_field)},
        "required": ["colonyId"],
    }

    schemas["colony_destroy"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "colonyId": dict(colony_id_field),
            "killWorkers": {"type": "boolean", "default": False},
        },
        "required": ["colonyId"],
    }

    schemas["spawn_workers"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "colonyId": dict(colony_id_field),
            "count": {
                "type": "integer",
                "minimum": 1,
                "maximum": MAX_WORKERS_PER_COLONY,
                "description": "Workers to spawn; the colony's total is capped at MAX_WORKERS_PER_COLONY.",
            },
            "x": _pixel_x("Pixel-space X to spawn workers around."),
            "y": _pixel_y("Pixel-space Y to spawn workers around."),
            "spread": {
                "type": "number",
                "minimum": 0,
                "maximum": 100,
                "description": "Random pixel-radius scatter applied around (x, y).",
            },
        },
        "required": ["colonyId", "count", "x", "y", "spread"],
    }

    schemas["kill_workers"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "colonyId": dict(colony_id_field),
            "count": {
                "type": "integer",
                "minimum": 1,
                "maximum": MAX_WORKERS_PER_COLONY,
                "description": "Workers to kill; omit to kill every worker in the colony.",
            },
        },
        "required": ["colonyId"],
    }

    task_id_field = {
        "type": "integer",
        "minimum": 1,
        "description": "Task id returned by assign_task.",
    }

    schemas["assign_task"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "colonyId": dict(colony_id_field),
            "kind": {"type": "string", "enum": TASK_KIND_ENUM},
            "params": _assign_task_params_schema(),
            "priority": {"type": "integer", "minimum": 1, "maximum": 9},
            "workers": {
                "type": "integer",
                "minimum": 1,
                "maximum": MAX_WORKERS_PER_COLONY,
                "description": "Cap on workers assigned to this task; omit to let the colony decide.",
            },
        },
        "required": ["colonyId", "kind", "params"],
    }

    schemas["task_status"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "colonyId": dict(colony_id_field),
            "taskId": dict(task_id_field),
        },
        "required": ["colonyId"],
    }

    schemas["cancel_task"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "colonyId": dict(colony_id_field),
            "taskId": dict(task_id_field),
        },
        "required": ["colonyId", "taskId"],
    }

    schemas["extension_status"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {},
    }

    schemas["extension_self_test"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "deep": {
                "type": "boolean",
                "default": False,
                "description": "Run deeper checks; must still not permanently mutate the sim.",
            },
        },
    }

    schemas["reset_creature_faults"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {},
    }

    schemas["execute_lua"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "code": {
                "type": "string",
                "minLength": 1,
                "description": (
                    "Lua chunk to run in the live bridge interpreter (loadstring+pcall). "
                    "Can define/patch elements and mutate PBX.state.behaviors.kinds; "
                    "cannot add a new 50_tasks.lua task kind (that table is local to a "
                    "module this chunk never sees) -- that still needs a source edit, "
                    "build_autorun.py, and a restart."
                ),
            },
        },
        "required": ["code"],
    }

    schemas["blueprint_build"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "blueprint": {
                "type": "object",
                "description": (
                    "Powder Blueprint v1 object: {name, origin:[x,y], clear_before, parts:[...], then:[{step:N}]}. "
                    "Parts use ONE op key each: box/line/circle/wall/erase/set/module/group/repeat/stamp with "
                    "relative 'at':[x,y] (top-left) and 'size':[w,h]; coordinates may reference earlier ids like "
                    "'core.right+2'. Call blueprint_schema for the full reference and module list."
                ),
            },
            "dry_run": {
                "type": "boolean",
                "default": True,
                "description": "true (default) = compile + validate + preview only; false = draw it.",
            },
            "pause": {
                "type": "boolean",
                "default": True,
                "description": "Pause the simulation before drawing (recommended; leaves it paused unless unpause_after).",
            },
            "unpause_after": {
                "type": "boolean",
                "default": False,
                "description": "Unpause once every primitive succeeded, before running 'then' steps.",
            },
            "features": {"type": "object", "description": "Anchors for hand-drawn objects: find_features().features keyed by id."},
            "features_auto": {"type": "boolean", "default": False, "description": "Run find_features and pre-seed its ids as anchors (e.g. ttan1.right+3)."},
        },
        "required": ["blueprint"],
    }

    schemas["blueprint_schema"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "include_aliases": {"type": "boolean", "default": False, "description": "Include the plain-word -> element/wall alias tables."},
            "include_catalog": {"type": "boolean", "default": False, "description": "Include every valid element and wall identifier."},
            "check_example": {"type": "boolean", "default": False, "description": "Also compile the bundled example and report whether it is valid."},
        },
    }

    schemas["build_practices"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "name": {"type": "string", "maxLength": 64, "description": "Exact practice name."},
            "level": {"type": "integer", "minimum": 0, "maximum": 9, "description": "Only this level (0 = workflow basics ... 5 = full plant)."},
            "max_level": {"type": "integer", "minimum": 0, "maximum": 9, "description": "Everything up to and including this level."},
            "topic": {"type": "string", "enum": ["thermal", "electrical", "containment", "materials", "workflow", "rendering", "performance"]},
            "query": {"type": "string", "maxLength": 120, "description": "Free-text filter over the whole practice."},
            "include_steps": {"type": "boolean", "default": True},
        },
    }

    schemas["realism_apply"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "profile": {
                "type": "string",
                "enum": ["all", "stock", "power", "materials", "kinds"],
                "default": "all",
                "description": "Which realism layer(s) to (re)apply: all, the stock-element patch, the power set, the materials catalog (priority 1), or just the behaviour kinds.",
            },
            "dry_run": {
                "type": "boolean",
                "default": False,
                "description": "Compute the plan and cap accounting using only read-only bridge calls; never define/update/delete an element or run a kinds/patch chunk.",
            },
        },
    }

    schemas["realism_status"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {},
    }

    schemas["world_state"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
                "max_elements": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 64,
                        "default": 24
                },
                "include_grid": {
                        "type": "boolean",
                        "default": False,
                        "description": "Also return the 38x24 occupancy grid (16px cells)."
                }
        }
}

    schemas["next_task"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
                "topic": {
                        "type": "string",
                        "enum": [
                                "thermal",
                                "electrical",
                                "containment",
                                "materials",
                                "workflow",
                                "rendering",
                                "performance"
                        ]
                },
                "max_level": {
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 9
                },
                "max_retries": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 10,
                        "default": 3
                }
        }
}

    schemas["record_attempt"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
                "goal": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 300
                },
                "practice": {
                        "type": "string",
                        "maxLength": 64
                },
                "level": {
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 9
                },
                "model": {
                        "type": "string",
                        "maxLength": 80
                },
                "verdict": {
                        "type": "string",
                        "enum": [
                                "pass",
                                "fail",
                                "partial"
                        ]
                },
                "evidence": {
                        "type": "string",
                        "maxLength": 800
                },
                "errors": {
                        "type": "array",
                        "items": {
                                "type": "string",
                                "maxLength": 300
                        },
                        "maxItems": 32
                },
                "blueprint": {
                        "type": "object"
                },
                "score": {
                        "type": "object",
                        "additionalProperties": False,
                        "description": "Decomposed verifiable-reward vector (round 3 item 3): a single pass|fail|partial verdict alone produces degenerate all-same-score GRPO groups.",
                        "properties": {
                                "compiles": {"type": "boolean"},
                                "lint_critical": {"type": "integer", "minimum": 0},
                                "lint_total": {"type": "integer", "minimum": 0},
                                "verify_pass": {"type": "boolean"}
                        }
                },
                "temperature": {
                        "type": "number",
                        "minimum": 0,
                        "maximum": 2,
                        "description": "Sampling temperature that produced this attempt, so candidates can be grouped for GRPO/RS-DPO."
                },
                "round_no": {
                        "type": "integer",
                        "minimum": 0,
                        "description": "Repair round this attempt settled on (0 = first try, no repair feedback used)."
                },
                "resample_no": {
                        "type": "integer",
                        "minimum": 0,
                        "description": "Blind-resample index this attempt settled on (0 = no resample needed)."
                }
        },
        "required": [
                "goal",
                "verdict"
        ]
}

    schemas["blueprint_grammar"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
                "format": {
                        "type": "string",
                        "enum": [
                                "gbnf",
                                "json_schema",
                                "both"
                        ],
                        "default": "both"
                }
        }
}

    schemas["blueprint_lint"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "blueprint": {
                "type": "object",
                "description": "Powder Blueprint v1 object (same shape blueprint_build accepts). Compiled internally; lint runs over the resulting absolute primitives.",
            },
        },
        "required": ["blueprint"],
    }

    schemas["module_search"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "query": {"type": "string", "minLength": 1, "maxLength": 300, "description": "The build request/goal text to rank builtin+registry modules against."},
            "k": {"type": "integer", "minimum": 1, "maximum": 87, "default": 12, "description": "How many modules to return (plus any explicit names)."},
            "explicit": {"type": "array", "items": {"type": "string", "maxLength": 64}, "maxItems": 20, "description": "Module names to always include regardless of rank (e.g. named directly in the request)."},
            "endpoint": {"type": "string", "maxLength": 200, "default": "http://localhost:11434", "description": "Ollama endpoint for /api/embeddings; falls back to TF-IDF if unreachable."},
            "model": {"type": "string", "maxLength": 80, "default": "nomic-embed-text", "description": "Ollama embedding model (nomic-embed-text or all-minilm both work with zero extra install)."},
        },
        "required": ["query"],
    }

    schemas["find_features"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
                "cell": {
                        "type": "integer",
                        "minimum": 2,
                        "maximum": 16,
                        "default": 4
                }
        }
}

    schemas["run_test"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
                "name": {
                        "type": "string",
                        "maxLength": 80
                },
                "frames": {
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 3000,
                        "default": 60
                },
                "sample_every": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 3000
                },
                "tx_at": {
                        "type": "array",
                        "items": {
                                "type": "integer"
                        },
                        "minItems": 2,
                        "maxItems": 2
                },
                "pulses": {
                        "type": "array",
                        "maxItems": 16,
                        "items": {
                                "type": "object",
                                "properties": {
                                        "channel": {
                                                "type": "integer",
                                                "minimum": 1,
                                                "maximum": 100
                                        },
                                        "at_frame": {
                                                "type": "integer",
                                                "minimum": 0
                                        },
                                        "frames": {
                                                "type": "integer",
                                                "minimum": 1,
                                                "maximum": 200
                                        }
                                },
                                "required": [
                                        "channel"
                                ]
                        }
                },
                "watch": {
                        "type": "array",
                        "maxItems": 16,
                        "items": {
                                "type": "object",
                                "properties": {
                                        "name": {
                                                "type": "string"
                                        },
                                        "region": {
                                                "type": "object"
                                        },
                                        "element": {
                                                "type": "string"
                                        }
                                },
                                "required": [
                                        "region"
                                ]
                        }
                },
                "assertions": {
                        "type": "array",
                        "maxItems": 32,
                        "items": {
                                "type": "object",
                                "properties": {
                                        "name": {
                                                "type": "string"
                                        },
                                        "region": {
                                                "type": "object"
                                        },
                                        "element": {
                                                "type": "string"
                                        },
                                        "metric": {
                                                "type": "string",
                                                "enum": [
                                                        "count",
                                                        "tavg_c",
                                                        "tmax_c",
                                                        "life_sum",
                                                        "pmin",
                                                        "pmax",
                                                        "delta_count"
                                                ]
                                        },
                                        "op": {
                                                "type": "string",
                                                "enum": [
                                                        ">=",
                                                        "<=",
                                                        ">",
                                                        "<",
                                                        "==",
                                                        "!="
                                                ]
                                        },
                                        "value": {
                                                "type": "number"
                                        }
                                },
                                "required": [
                                        "region",
                                        "value"
                                ]
                        }
                },
                "seed": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "minItems": 4,
                        "maxItems": 4,
                        "description": "4-integer sim.randomSeed() state to replay exactly (from a prior run's determinism.seed). Implies capture_hash and calls sim.ensureDeterminism(true) before stepping."
                },
                "capture_hash": {
                        "type": "boolean",
                        "default": False,
                        "description": "Capture sim.hash() before/after the test frames (and the RNG seed used) under the returned 'determinism' object, for reproducibility comparison via replay_hash_check."
                }
        }
}

    schemas["build_stage"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
                "stage": {
                        "type": "object"
                },
                "dry_run": {
                        "type": "boolean",
                        "default": False
                },
                "record": {
                        "type": "boolean",
                        "default": True
                }
        },
        "required": [
                "stage"
        ]
}

    schemas["blueprint_module_save"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "name": {
                "type": "string",
                "pattern": r"^[a-z][a-z0-9_]{1,40}$",
                "maxLength": 41,
                "description": "Lowercase snake_case module id; cannot collide with a builtin module name.",
            },
            "description": {"type": "string", "maxLength": 240},
            "why": {
                "type": "string",
                "maxLength": 400,
                "description": "What lesson or verified build justifies this module existing.",
            },
            "params": {
                "type": "object",
                "maxProperties": 24,
                "description": "{paramName: default} -- default values used both to expand unfilled params and to dry-run-validate this module before it is written.",
            },
            "parts": {
                "type": "array",
                "maxItems": 256,
                "items": {"type": "object"},
                "description": "Blueprint parts template (box/line/circle/wall/set/erase/module/group/repeat/stamp). Any numeric field may be a string arithmetic expression over the declared param names, e.g. \"width-2\".",
            },
            "anchors_note": {
                "type": "string",
                "maxLength": 300,
                "description": "Optional free-text note about anchors this module exposes.",
            },
        },
        "required": ["name", "description", "why", "params", "parts"],
    }

    schemas["run_pipeline"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
                "plan": {
                        "type": "object"
                },
                "start_at": {
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 64,
                        "default": 0
                },
                "dry_run": {
                        "type": "boolean",
                        "default": False
                },
                "stop_on_fail": {
                        "type": "boolean",
                        "default": True
                },
                "record": {
                        "type": "boolean",
                        "default": True
                }
        },
        "required": [
                "plan"
        ]
}

    schemas["element_facts"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "element": {
                "type": "string",
                "maxLength": 32,
                "description": "Element name or plain word (resolved via the same aliasing as blueprint_build).",
            },
            "with": {
                "type": "string",
                "maxLength": 32,
                "description": "A second element; with `element` set, returns reactions between the two (searched both directions).",
            },
            "query": {
                "type": "string",
                "maxLength": 200,
                "description": "Free-text search across every element's facts, signal_rules, and experiment records. Ignored if `element` is set.",
            },
            "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 20},
        },
    }

    particle_id_field = {
        "type": "integer",
        "minimum": 0,
        "maximum": MAX_PARTICLE_ID,
        "description": "Live particle id of one person's torso (see personInspect/spawn_workers).",
    }

    schemas["person_inspect"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {"particleId": dict(particle_id_field)},
        "required": ["particleId"],
    }

    schemas["person_move"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "particleId": dict(particle_id_field),
            "x": _pixel_x(),
            "y": _pixel_y(),
        },
        "required": ["particleId", "x", "y"],
    }

    schemas["person_kill"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "particleId": dict(particle_id_field),
            "cause": {
                "type": "string",
                "minLength": 1,
                "maxLength": 32,
                "description": "Death cause recorded in colonyStatus.deathsByCause; defaults to \"ordered\".",
            },
        },
        "required": ["particleId"],
    }

    schemas["person_set_trait"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "particleId": dict(particle_id_field),
            "trait": {"type": "string", "enum": PERSON_TRAIT_ENUM},
        },
        "required": ["particleId", "trait"],
    }

    schemas["person_feed"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "particleId": dict(particle_id_field),
            "amount": {
                "type": "integer",
                "minimum": 1,
                "maximum": 100000,
                "description": "Energy units added to life, capped at WORKER_LIFE (1500).",
            },
        },
        "required": ["particleId", "amount"],
    }

    schemas["person_recolor"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "particleId": dict(particle_id_field),
            "colour": {
                "type": "string",
                "pattern": COLOUR_ARGB_PATTERN,
                "maxLength": 10,
                "description": "New tint as 0xAARRGGBB, written to the particle's dcolour.",
            },
        },
        "required": ["particleId", "colour"],
    }

    schemas["world_place_hazard"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "x": _pixel_x(),
            "y": _pixel_y(),
            "kind": {"type": "string", "enum": WORLD_HAZARD_ENUM},
        },
        "required": ["x", "y", "kind"],
    }

    schemas["snapshot_fast"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "region": _pixel_region_schema(),
            "element": {
                "type": "string",
                "maxLength": 32,
                "description": "Element name or plain word filter (same resolution as blueprint_build); only applies to the 'detail' rows.",
            },
            "cursor": {
                "type": "integer",
                "minimum": 0,
                "default": 0,
                "description": "Raw particle-slot cursor. Advances by scanned, not by returned-record index -- same contract as parts_inventory.",
            },
            "limit": {"type": "integer", "minimum": 1, "maximum": 256, "default": 128},
            "max_scan": {"type": "integer", "minimum": 1, "maximum": 20000, "default": 4096},
            "fields": {
                "type": "array",
                "items": {"type": "string", "enum": ["detail", "counts"]},
                "maxItems": 2,
                "description": (
                    "'detail' returns the paginated compact per-particle rows; 'counts' returns a "
                    "global per-element summary from sim.elementCount/sim.partCount (O(distinct "
                    "element types), not a full scan). Both run in the same execute_lua call; "
                    "default is both. Pass just ['counts'] to skip the per-particle scan entirely."
                ),
            },
        },
    }

    schemas["screenshot"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "view": {
                "type": "string",
                "enum": ["normal", "heat", "pressure", "velocity"],
                "default": "normal",
                "description": "Render view: sets ren.displayMode/ren.colorMode to the real bit values (never ren.useDisplayPreset, which remaps presets 0-10) then restores the previous mode after capture.",
            },
            "crop": _pixel_region_schema(),
            "label": {
                "type": "string",
                "maxLength": 64,
                "description": "Diff key: screenshots sharing a label are compared to the previous one under that label. Defaults to view.",
            },
        },
    }

    schemas["rpg_status"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "include_fps": {
                "type": "boolean",
                "default": True,
                "description": "Sample R.frame twice (fps_sample_ms apart) to estimate live FPS; adds fps_sample_ms of wall-clock latency when the RPG is active.",
            },
            "fps_sample_ms": {
                "type": "integer",
                "minimum": 100,
                "maximum": 3000,
                "default": 1000,
                "description": "Wall-clock gap between the two R.frame samples used for the FPS estimate.",
            },
        },
    }

    schemas["rpg_search"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "query": {"type": "string", "minLength": 1, "maxLength": 300, "description": "Free-text query ranked (TF-IDF/cosine) against the RPG corpus."},
            "k": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "How many ranked lines to return."},
            "scope": {
                "type": "string",
                "enum": ["code", "docs", "mechanics", "all"],
                "default": "all",
                "description": "code = rpg.lua + rpg_plugins/*.lua + README; docs = hub/roadmap/ideas/research/design markdown; mechanics = build-lessons.jsonl + playbook.json.",
            },
        },
        "required": ["query"],
    }

    schemas["rpg_api"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {},
    }

    schemas["rpg_hub"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "action": {"type": "string", "enum": ["read", "post", "drew"], "description": "read returns the hub; post appends a log line; drew inserts an owner-says line."},
            "text": {"type": "string", "maxLength": 2000, "description": "Required for post/drew: the log line body, or the owner-says quote text."},
            "who": {"type": "string", "maxLength": 32, "default": "mcp", "description": "Attribution tag for post, e.g. mcp or a worker name."},
            "lines": {"type": "integer", "minimum": 1, "maximum": 2000, "description": "For read: return only the last N lines instead of the whole file."},
        },
        "required": ["action"],
    }

    schemas["rpg_reload"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "target": {"type": "string", "enum": ["core", "plugin"], "description": "core reloads rpg.lua itself; plugin reloads one rpg_plugins/<name>.lua via R.reloadPlugin."},
            "name": {
                "type": "string",
                "pattern": r"^[a-z][a-z_]{0,30}$",
                "maxLength": 31,
                "description": "Plugin name (e.g. world, enemies, machines, items, save, ui); required when target=plugin.",
            },
        },
        "required": ["target"],
    }

    schemas["rpg_screenshot"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "panel": {
                "type": "string",
                "enum": ["bag", "menu", "quests"],
                "description": "Open this panel before capturing (state restored afterward); omit to capture the plain view.",
            },
        },
    }

    schemas["rpg_lua"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "code": {
                "type": "string",
                "minLength": 1,
                "maxLength": 20000,
                "description": "Lua snippet run with 'local R = PBX.state.rpg' prepended.",
            },
            "allow_destructive": {
                "type": "boolean",
                "default": False,
                "description": "Required to run a snippet that references clearSim/loadSave/pendingGen.",
            },
        },
        "required": ["code"],
    }

    schemas["replay_hash_check"] = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "run_test": {
                "type": "object",
                "description": "Same argument object run_test accepts; MUST include the 4-integer 'seed' recorded as a prior run's determinism.seed to replay it exactly.",
            },
            "expected_hash": {
                "type": "integer",
                "description": "sim.hash() recorded as determinism.hash_after from the run being replayed.",
            },
        },
        "required": ["run_test", "expected_hash"],
    }

    return schemas


TOOL_SCHEMAS: dict[str, dict] = _build_schemas()


TOOL_DESCRIPTIONS: dict[str, str] = {
    "define_element": (
        "Create or redefine (idempotent by name) a custom TPT element with physical "
        "properties and a behavior; use this to add new matter to the sim."
    ),
    "list_custom_elements": (
        "List every custom element currently registered, with its live numeric id; "
        "use this to check what already exists before defining more."
    ),
    "update_element": (
        "Change one or more fields of an existing custom element in place, keeping "
        "its id and name; use this to tune a definition instead of recreating it."
    ),
    "delete_custom_element": (
        "Remove a custom element by name and free its id slot; use this to clean up "
        "an experiment or make room under MAX_CUSTOM_ELEMENTS."
    ),
    "colony_create": (
        "Create a new ant-colony-style creature colony with a nest point and tint; "
        "use this before spawning workers or assigning tasks."
    ),
    "colony_list": (
        "List every active colony with its id and basic info; use this to find a "
        "colonyId to operate on."
    ),
    "colony_status": (
        "Read one colony's worker count, store contents, task list, nest location, "
        "and pheromone peak; use this to check on a colony's progress."
    ),
    "colony_destroy": (
        "Destroy a colony and optionally kill its workers; use this to tear down an "
        "experiment and free a colony slot under MAX_COLONIES."
    ),
    "spawn_workers": (
        "Spawn worker creatures for a colony at a pixel location with random scatter; "
        "use this to populate a colony before assigning it work."
    ),
    "kill_workers": (
        "Kill some or all of a colony's workers; use this to shrink a colony or clear "
        "it out without destroying the colony itself."
    ),
    "assign_task": (
        "Give a colony a task (gather, dig, build a line/box/circle/blueprint, or "
        "patrol) that its workers will carry out autonomously over subsequent ticks; "
        "use this to direct colony behavior."
    ),
    "task_status": (
        "Read progress (claimed/done/total) for one task or every task in a colony; "
        "use this to poll a task assigned with assign_task."
    ),
    "cancel_task": (
        "Cancel a colony's in-progress task and release its worker claims; use this "
        "to stop work that is no longer wanted."
    ),
    "extension_status": (
        "Read overall extension health: loaded modules, tick index, job queue depth, "
        "and counts of custom elements/colonies/workers; use this as a quick liveness check."
    ),
    "extension_self_test": (
        "Run the extension's built-in self-test checks without permanently mutating "
        "the sim; use this to diagnose whether the bridge extension is working correctly."
    ),
    "reset_creature_faults": (
        "Clear the creature-update fault latch and re-arm the guarded warm-up window "
        "so worker updates that got disabled after repeated faults resume running; "
        "use this after a burst of errors froze the swarm."
    ),
    "execute_lua": (
        "Run one Lua chunk in the live bridge interpreter without restarting powder.exe. "
        "Can define/patch elements and mutate behavior-kind tables for hot capability "
        "additions; cannot register a new 50_tasks.lua task kind string (that requires a "
        "source edit, build_autorun.py, and a restart)."
    ),
    "blueprint_build": (
        "Compile and (optionally) draw a Powder Blueprint v1 JSON: relative coordinates, id anchors "
        "('core.right+2'), plain-word element names with did-you-mean errors, property setting "
        "(tmp channels, ctype, temp_c), and parametric modules distilled from the build-lessons store "
        "(pressure_chamber, portal_pair, clne_liner, wifi_node, insulated_box, shld_pipe_riser, lcry_panel, "
        "tank, deut_cell_mk2, cooling_tower, house). dry_run defaults to true and returns errors with "
        "path+problem+fix so a small model can self-correct; dry_run=false draws with stop-on-first-error."
    ),
    "blueprint_schema": (
        "Read-only reference for Powder Blueprint v1: the language spec text, module catalogue with "
        "params (builtin and registry-saved), a worked example, limits, and optionally alias tables and "
        "the full element/wall lists. Paste the reference into a small model's prompt before asking it "
        "to emit a blueprint."
    ),
    "build_practices": (
        "Graded building playbook: small practices (level 0 workflow loop -> 1 sealed vessel / insulated heat "
        "source / wiring -> 2 valves, remote flood-drain -> 3 pressure chamber, self-healing liner, cryo, displays "
        "-> 4 heat loop, PLUT core -> 5 fusion shot, plant integration). Each returns steps as blueprint fragments "
        "or actions, a verify check, pitfalls resolved against the lessons store, scale_up guidance and the modules "
        "to use. Read level N and pass its verify before composing at level N+1."
    ),
    "realism_apply": (
        "(Re)register everything that vanishes when powder.exe restarts: the runtime behaviour kinds "
        "from scripts/lua/*_kinds.lua, the stock-element realism patch(es) from knowledge/, the power-"
        "generation element set, and the materials catalog priority-1 entries -- respecting "
        "MAX_CUSTOM_ELEMENTS and reporting anything skipped for lack of a free slot. profile scopes the "
        "work to one layer (default all); dry_run computes the same plan/cap accounting via read-only "
        "bridge calls only, never defining, updating, or deleting an element."
    ),
    "realism_status": (
        "Read-only snapshot of the persistence layer: which behaviour kinds are currently registered on "
        "PBX.state.behaviors.kinds, live custom element count against the cap, whether the stock-element "
        "realism patch is in effect (sampled via METL's HighTemperature), and materials-catalog / power-"
        "element-set coverage totals. Use this before realism_apply to see what a fresh session lost."
    ),
    "world_state": (
        "Compact live world summary for a model turn: particle count, pause state, per-element counts/boxes/temps, walls, pressure extremes, hot spots, and the largest EMPTY rectangles to build in. Read-only. Use before every blueprint (state tracking is the #1 agent failure mode)."
    ),
    "next_task": (
        "Automatic curriculum over the graded playbook (Voyager-style, deterministic): returns the lowest unpassed practice as a task; if its last attempt failed, returns the practice decomposed into sub-tasks plus the previous errors. Driven by knowledge/attempts.jsonl (record_attempt)."
    ),
    "record_attempt": (
        "Append one (goal, blueprint, verdict, evidence) record to knowledge/attempts.jsonl. This is the curriculum's memory and the future fine-tuning dataset. File-only; never touches the sim."
    ),
    "blueprint_grammar": (
        "GBNF grammar and JSON Schema for Powder Blueprint v1, for grammar-constrained decoding in llama.cpp / Ollama so a small model cannot emit a malformed blueprint. Shape only: still dry_run + fix errors."
    ),
    "module_search": (
        "Rank the 76+ builtin+registry blueprint modules by relevance to a request (query) instead of dumping the "
        "full list into every prompt. Tries Ollama embeddings (POST /api/embeddings, nomic-embed-text or "
        "all-minilm) first, falls back to a stdlib TF-IDF/cosine ranker with no new dependency when Ollama is "
        "unreachable. `explicit` names are always kept regardless of rank. Read-only, does not touch the sim."
    ),
    "find_features": (
        "Cluster the live canvas into named objects (connected components): id, shape (ring/box/shell/blob), main element, composition, pixel bbox, anchors (left/right/top/bottom/cx/cy), hottest temp. Use ids as blueprint anchors via blueprint_build features_auto=true, e.g. 'ttan1.right+3'."
    ),
    "run_test": (
        "Functional acceptance test on the live sim: optional WIFI channel pulses at frames (temporary transmitter at tx_at, default 600,4), exact frame stepping, watched regions traced, then assertions over regions (count/temps/pressure/life_sum/delta_count). Leaves the sim paused. Never draws."
    ),
    "build_stage": (
        "One pipeline stage with hard gates: compile -> lint (critical must be clean unless stage.require_lint_clean=false) -> full-canvas checkpoint stamp -> build -> run every stage.tests (run_test args) -> record_attempt. Stops at the first failed gate with diagnostics. stage = {name, blueprint, tests:[...], require_lint_clean?}."
    ),
    "run_pipeline": (
        "Execute a staged build plan: {plan:{name, stages:[{name, blueprint, tests, require_lint_clean?}]}, start_at?, dry_run?, stop_on_fail?}. Before each stage find_features is refreshed so blueprints can anchor to earlier stages or hand-drawn objects (ids like ttan1.right+3). Each stage passes compile -> lint -> checkpoint -> build -> tests -> record; stops at the first failed stage with diagnostics and the start_at index to resume from."
    ),
    "blueprint_lint": (
        "Compile a Powder Blueprint v1 JSON and run a knowledge-and-lessons-derived rule set over its "
        "absolute geometry: WATR touching a conductor, WIFI/PRTO/HEAC without an INSL jacket, cryogenic "
        "elements with no cold temp prop, PLSM/LAVA/FIRE next to meltable structure, PUMP/VACU outside a "
        "wall box, PSCN not touching LCRY, CLNE with no ctype, a channel reused by two portal pairs, an "
        "overly wide conductive floor, and elements placed above their own HighTemperature transition. "
        "Findings are advisory (severity + path + rule + problem + fix) and never block; only compile "
        "errors block. blueprint_build already runs this and returns it under \"lint\" -- call this "
        "directly to re-check without redrawing."
    ),
    "blueprint_module_save": (
        "Validate and persist a new parametric blueprint module to knowledge/modules/ -- the "
        "self-improvement loop from a verified build to a reusable, named macro. Expands the given "
        "parts template with its own default params through the real compiler (dry, never draws) and "
        "refuses to write anything that does not compile cleanly. Saved modules appear immediately in "
        "blueprint_schema and are usable via {\"module\": name, ...} with no restart."
    ),
    "element_facts": (
        "Query the accumulated element-interaction knowledge base (MINER-A/MINER-B's "
        "element-interactions-part1/2.json plus EXPERIMENTER's verified/refuted experiment log): facts "
        "for one element, every recorded reaction between two elements (searched both directions), or a "
        "free-text search, each result carrying its source file/path and any matching experiment "
        "verdicts. Missing knowledge files are tolerated (reports \"no data yet\", not an error)."
    ),
    "person_inspect": (
        "Read one person's live state -- life, temp, cargo, FSM state, colony id, "
        "and position; use this to check on a specific worker by particle id."
    ),
    "person_move": (
        "Teleport one person's torso particle to a pixel position; use this to place "
        "a worker precisely, e.g. into a hazard for a controlled test."
    ),
    "person_kill": (
        "Kill one person by particle id via the same corpse-conversion path natural "
        "deaths use, recording an optional cause; use this for a manual, tracked kill."
    ),
    "person_set_trait": (
        "Set a personality trait (builder, gatherer, coward, brave, lazy) on one "
        "person; a \"coward\" trait lowers its effective heat-flee threshold."
    ),
    "person_feed": (
        "Add energy to one person's life, capped at the normal refuelling ceiling; "
        "use this to keep a specific worker alive without a nest trip."
    ),
    "person_recolor": (
        "Recolour one person's tint independent of its colony's default; use this to "
        "visually mark a single worker out from its colony-mates."
    ),
    "world_place_hazard": (
        "Drop one base-TPT hazard element (fire, lava, acid, void) at a pixel "
        "position; use this to test environmental-sensitivity reactions on demand."
    ),
    "snapshot_fast": (
        "Fast paginated particle census: one execute_lua round trip returns a compact per-particle "
        "dump (id,type,x,y,temp,ctype,tmp,life) for an optional pixel region/element filter, paged "
        "by a raw-slot cursor (same cursor/limit/max_scan contract as parts_inventory), plus a "
        "global per-element count summary read from sim.elementCount/sim.partCount -- O(distinct "
        "element types), not a full particle scan. Use fields:['counts'] alone to skip the "
        "per-particle scan entirely when only totals are needed."
    ),
    "screenshot": (
        "Capture a PNG of the live canvas via tpt.screenshot(0,0) in a chosen render view (normal, "
        "heat, pressure, velocity) using the real ren.displayMode/colorMode bit values -- never "
        "ren.useDisplayPreset, which has a documented legacy off-by-one remap for presets 0-10. "
        "Restores the previous render mode before returning. Optionally crops the PNG (Pillow) and "
        "reports a percent-changed-pixels diff against the previous screenshot sharing the same label."
    ),
    "replay_hash_check": (
        "Replay a run_test call with a previously recorded 4-integer seed and confirm sim.hash() "
        "after stepping matches an expected_hash from an earlier determinism capture -- a strictly "
        "stronger regression signal than metric-threshold assertions. Caller is responsible for "
        "restoring the same starting sim state (e.g. a build_stage checkpoint stamp) before "
        "calling, since this only controls the RNG stream and frame stepping, not the starting "
        "particle layout."
    ),
    "rpg_status": (
        "Live Powder RPG game-state snapshot via the bridge: active/paused/seed/frame/day, player "
        "pos/depth/biome/onGround, hp, camera, inventory, hotbar/sel, tools, accessories (acc/accOff), "
        "current quest index+text, stations, machine/enemy counts, per-plugin pluginStatus, "
        "lastErr/pluginErr, weather, particle count, and an optional FPS estimate (samples R.frame "
        "twice, fps_sample_ms apart). Read-only."
    ),
    "rpg_search": (
        "Ranked full-text search (TF-IDF/cosine, no external dependency) over the RPG corpus: rpg.lua, "
        "every scripts/lua/rpg_plugins/*.lua plus its README, the team hub/roadmap/ideas/research/design "
        "docs under knowledge/, and the mechanics KB (build-lessons.jsonl, playbook.json). The index is "
        "built lazily and cached by file mtime so repeated calls are fast. Returns file, line, snippet, "
        "score for the top k matches; scope narrows to code|docs|mechanics|all. Read-only."
    ),
    "rpg_api": (
        "Structured dump of the RPG's scriptable API for agents: R.hooks names (from rpg_plugins/README.md's "
        "hook contract), every function/field hung on R at module scope in rpg.lua (name, kind, line, "
        "one-line context), R.RECIPES/ITEMS/ACCS/QUESTS/STATIONS/NAMES/MINEABLE/HARD read live via "
        "execute_lua (falls back to a static regex/brace parse of rpg.lua's source when the bridge is "
        "unreachable), and every key binding found via 'k == \"...\"' checks across rpg.lua and its "
        "plugins. Read-only."
    ),
    "rpg_hub": (
        "Read or append to the RPG team hub (knowledge/rpg-hub.md). action=read returns the file "
        "(optionally just the last N lines via `lines`); action=post appends '- [HH:MM] <who>: text' "
        "to the Log; action=drew inserts a '- HH:MM \"text\"' line under the owner-says section, just above the "
        "Ownership section, matching the hub's existing convention for relaying the owner's live comments."
    ),
    "rpg_reload": (
        "Hot-reload rpg.lua (target=core: re-executes the file's own source through execute_lua -- safe "
        "because rpg.lua's R.isolated/R.version guard makes it reuse the live R table instead of "
        "resetting it) or one plugin (target=plugin, name=world|enemies|machines|items|save|ui, calls "
        "R.reloadPlugin) without restarting powder.exe. Returns the reload result plus a fresh "
        "pluginStatus/pluginErr/lastErr snapshot so a failed reload is immediately visible."
    ),
    "rpg_screenshot": (
        "Capture a PNG of the live RPG view via tpt.screenshot, optionally opening the bag, menu, or "
        "quest panel first (R.menuOpen for menu; the ui plugin's R.ui.bagOpen/questOpen for bag/quests) "
        "and restoring its prior open/closed state afterward. Returns the PNG path."
    ),
    "rpg_lua": (
        "Run one Lua snippet against the live RPG with 'local R = PBX.state.rpg' prepended, returning "
        "its result. Refuses snippets mentioning clearSim/loadSave/pendingGen unless "
        "allow_destructive=true is passed, since those touch or regenerate the live world the user is "
        "playing in (rpg_plugins/README.md: 'NEVER call sim.clearSim / sim.loadSave / regenerate the "
        "world')."
    ),
}


TOOL_READONLY: dict[str, bool] = {
    "define_element": False,
    "list_custom_elements": True,
    "update_element": False,
    "delete_custom_element": False,
    "colony_create": False,
    "colony_list": True,
    "colony_status": True,
    "colony_destroy": False,
    "spawn_workers": False,
    "kill_workers": False,
    "assign_task": False,
    "task_status": True,
    "cancel_task": False,
    "extension_status": True,
    "extension_self_test": True,
    "reset_creature_faults": False,
    "execute_lua": False,
    "blueprint_build": False,
    "blueprint_schema": True,
    "build_practices": True,
    "realism_apply": False,
    "realism_status": True,
    "world_state": True,
    "next_task": True,
    "record_attempt": False,
    "blueprint_grammar": True,
    "module_search": True,
    "find_features": True,
    "run_test": False,
    "build_stage": False,
    "run_pipeline": False,
    "blueprint_lint": True,
    "blueprint_module_save": False,
    "element_facts": True,
    "person_inspect": True,
    "person_move": False,
    "person_kill": False,
    "person_set_trait": False,
    "person_feed": False,
    "person_recolor": False,
    "world_place_hazard": False,
    "snapshot_fast": True,
    "screenshot": True,
    "replay_hash_check": False,
    "rpg_status": True,
    "rpg_search": True,
    "rpg_api": True,
    "rpg_hub": False,
    "rpg_reload": False,
    "rpg_screenshot": False,
    "rpg_lua": False,
}


TOOL_ORDER: tuple[str, ...] = (
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
)


def validate() -> None:
    """Assert TOOL_SCHEMAS/TOOL_DESCRIPTIONS/TOOL_READONLY/TOOL_ORDER agree.

    Checks (all via assert, meant to be run by the test harness, not at
    import time):
      - the three dicts share exactly the same key set
      - TOOL_ORDER is a permutation of that same key set with no duplicates
      - every schema is `{"type": "object", "additionalProperties": False}`
        at its top level
    """
    schema_keys = set(TOOL_SCHEMAS)
    desc_keys = set(TOOL_DESCRIPTIONS)
    readonly_keys = set(TOOL_READONLY)

    assert schema_keys == desc_keys, (
        f"TOOL_SCHEMAS/TOOL_DESCRIPTIONS key mismatch: "
        f"{schema_keys ^ desc_keys}"
    )
    assert schema_keys == readonly_keys, (
        f"TOOL_SCHEMAS/TOOL_READONLY key mismatch: "
        f"{schema_keys ^ readonly_keys}"
    )

    assert len(TOOL_ORDER) == len(set(TOOL_ORDER)), "TOOL_ORDER contains duplicates"
    assert set(TOOL_ORDER) == schema_keys, (
        f"TOOL_ORDER does not cover exactly the tool set: {set(TOOL_ORDER) ^ schema_keys}"
    )

    for name, schema in TOOL_SCHEMAS.items():
        assert schema.get("type") == "object", f"{name}: schema type must be 'object'"
        assert schema.get("additionalProperties") is False, (
            f"{name}: schema must set additionalProperties: False"
        )
        assert isinstance(TOOL_DESCRIPTIONS[name], str) and TOOL_DESCRIPTIONS[name], (
            f"{name}: description must be a non-empty string"
        )
        assert isinstance(TOOL_READONLY[name], bool), f"{name}: TOOL_READONLY must be bool"
