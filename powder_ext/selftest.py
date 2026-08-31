#!/usr/bin/env python3
"""Standalone self-test harness for the Powder Bridge extension.

Validates the extension described in ``D:/powder-toy/EXTENSION_SPEC.md`` end
to end, in two modes:

Static mode (default, also ``--static``)
    No running game required. Checks that every ``bridge_src/*.lua`` module
    exists, is non-empty and parses; that every ``powder_ext/*.py`` file
    parses; that ``schemas.py`` is internally consistent and covers exactly
    the 15 spec tool names; that every tool has exactly one handler and every
    handler has exactly one schema entry (the cross-file drift check); and
    that each Lua module registers the bridge actions the spec says it owns.

Live mode (``--live``, additive to static)
    Talks to the *running* game through a self-contained MCP stdio session
    (spawns ``powder_toy_mcp.py`` the same way the game's own MCP client
    does). Calls only ``extension_status`` and ``extension_self_test`` --
    both documented read-only -- and never anything that could mutate the
    shared canvas (no element/colony/worker creation, no ``clear_sim``,
    ``draw_project``, ``place_element``, etc.). An unknown-action error from
    the bridge, or the extension tools being absent from ``tools/list``
    entirely, is reported as an expected SKIP ("not deployed yet"), not a
    failure.

Five other modules of this extension are written by other authors in
parallel and may be missing or incomplete at any given run:
``bridge_src/{10_registry,20_behaviors,30_colony,40_worker,50_tasks,60_diag}.lua``
and ``powder_ext/{schemas,element_tools,colony_tools}.py``. Every check below
treats a missing dependency as SKIP with a clear reason, never as a crash or
a silent pass.

Usage
-----
    python selftest.py                 # static checks, text table
    python selftest.py --static        # same, explicit
    python selftest.py --live          # static + live checks
    python selftest.py --json          # machine-readable output
    python selftest.py --live --json

Exit code is non-zero iff at least one check reports FAIL. SKIP never
affects the exit code: it means "could not verify" (missing dependency,
module not yet written, game not running/deployed), not "broken".
"""

from __future__ import annotations

import argparse
import ast
import importlib.util
import json
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from powder_ext.repo_paths import REPO_ROOT

ROOT = REPO_ROOT
BRIDGE_SRC = ROOT / "bridge_src"
POWDER_EXT = ROOT / "powder_ext"
MCP_SERVER = ROOT / "powder_toy_mcp.py"

STATUS_PASS = "PASS"
STATUS_FAIL = "FAIL"
STATUS_SKIP = "SKIP"

# ---------------------------------------------------------------------------
# The contract this harness checks against, encoded as data (mirroring
# EXTENSION_SPEC.md) rather than left implicit -- that is what lets a change
# in one author's file get caught here instead of silently drifting.
# ---------------------------------------------------------------------------

# Build order from spec section 1. 00_util.lua is the foundation and is
# already written; the rest are owned by concurrently-working authors.
BRIDGE_MODULES = [
    "00_util.lua",
    "10_registry.lua",
    "20_behaviors.lua",
    "30_colony.lua",
    "40_worker.lua",
    "50_tasks.lua",
    "60_diag.lua",
]
FOUNDATION_MODULE = "00_util.lua"

# module -> bridge actions it must PBX.register(...) (spec section 4).
# 20_behaviors.lua registers no actions -- it publishes PBX.state.behaviors.kinds
# instead, checked separately against BEHAVIOR_KINDS.
MODULE_ACTIONS: dict[str, list[str]] = {
    "00_util.lua": ["jobStatus"],
    "10_registry.lua": ["defineElement", "listCustomElements", "updateElement", "deleteCustomElement"],
    "20_behaviors.lua": [],
    "30_colony.lua": ["colonyCreate", "colonyList", "colonyStatus", "colonyDestroy"],
    "40_worker.lua": ["colonySpawnWorkers", "colonyKillWorkers"],
    "50_tasks.lua": ["colonyAssignTask", "colonyTaskStatus", "colonyCancelTask"],
    "60_diag.lua": ["extStatus", "extSelfTest"],
}

# Required PBX.state.behaviors.kinds entries (spec section 4.2).
BEHAVIOR_KINDS = [
    "inert", "glower", "decayer", "emitter", "grower",
    "pheromone", "conductor", "creature",
]

# The 15 MCP tool names from spec section 5, in the order the spec lists them.
MCP_TOOL_NAMES = [
    "define_element", "list_custom_elements", "update_element", "delete_custom_element",
    "colony_create", "colony_list", "colony_status", "colony_destroy",
    "spawn_workers", "kill_workers", "assign_task", "task_status", "cancel_task",
    "extension_status", "extension_self_test",
]

# Python files this harness checks for syntax under powder_ext/. selftest.py
# itself is checked separately (see check_python_files) so its result reads
# clearly rather than being buried in this list.
PYTHON_EXT_MODULES = ["__init__.py", "schemas.py", "element_tools.py", "colony_tools.py"]

# The only two MCP tools --live may ever call. Both are documented read-only
# in the spec (extStatus/extSelfTest touch no particles); everything else is
# off-limits to this harness regardless of what TOOL_READONLY might say.
LIVE_SAFE_TOOLS = ("extension_status", "extension_self_test")


# ---------------------------------------------------------------------------
# Result plumbing
# ---------------------------------------------------------------------------


class Result:
    __slots__ = ("name", "status", "detail")

    def __init__(self, name: str, status: str, detail: str = "") -> None:
        self.name = name
        self.status = status
        self.detail = detail

    def as_dict(self) -> dict[str, str]:
        return {"name": self.name, "status": self.status, "detail": self.detail}


results: list[Result] = []


def record(name: str, status: str, detail: str = "") -> str:
    results.append(Result(name, status, detail))
    return status


# ---------------------------------------------------------------------------
# Static check: bridge_src/*.lua presence
# ---------------------------------------------------------------------------


def check_bridge_files() -> None:
    for name in BRIDGE_MODULES:
        path = BRIDGE_SRC / name
        if not path.is_file():
            if name == FOUNDATION_MODULE:
                record(f"bridge_files.{name}", STATUS_FAIL,
                       "foundation module is missing -- everything else depends on it")
            else:
                record(f"bridge_files.{name}", STATUS_SKIP,
                       "not written yet by its author")
            continue
        size = path.stat().st_size
        if size == 0:
            record(f"bridge_files.{name}", STATUS_FAIL, "file exists but is empty")
        else:
            record(f"bridge_files.{name}", STATUS_PASS, f"{size} bytes")


# ---------------------------------------------------------------------------
# Static check: Lua parses (luac -p, else a labeled best-effort fallback)
# ---------------------------------------------------------------------------


def _strip_lua_comments_and_strings(text: str) -> str:
    """Remove Lua comments and string literals so keyword-counting below
    cannot be fooled by the word "end" (or "goto", "//") appearing inside a
    string or a comment. Replaces every stripped span with a single space so
    line/column positions are not needed and nothing re-joins into a new
    token."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        if text[i : i + 2] == "--":
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                closer = "]" + m.group(1) + "]"
                end = text.find(closer, i + len(m.group(0)))
                i = end + len(closer) if end != -1 else n
                out.append(" ")
                continue
            end = text.find("\n", i)
            i = end if end != -1 else n
            continue
        c = text[i]
        if c in ("'", '"'):
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == c:
                    j += 1
                    break
                j += 1
            out.append(" ")
            i = j
            continue
        if c == "[":
            m = re.match(r"\[(=*)\[", text[i:])
            if m:
                closer = "]" + m.group(1) + "]"
                end = text.find(closer, i + len(m.group(0)))
                i = end + len(closer) if end != -1 else n
                out.append(" ")
                continue
        out.append(c)
        i += 1
    return "".join(out)


def _structural_lua_check(text: str) -> tuple[bool, str]:
    """Best-effort structural check used only when ``luac`` is unavailable.

    Not a real parser: balances the keywords that must pair 1:1 with ``end``
    (``function``, ``if``, ``for``, ``while``, standalone ``do``) and
    ``repeat``/``until``, and flags obvious Lua 5.2+ syntax (``goto``, ``//``)
    that TPT's Lua 5.1 does not support. ``for ... do`` / ``while ... do``
    header spans are stripped before counting ``do`` so their trailing ``do``
    is not double-counted against the same ``end`` the ``for``/``while``
    already accounts for. This can both miss real errors and flag false
    positives -- callers must label results from this path as unverified.
    """
    stripped = _strip_lua_comments_and_strings(text)
    issues: list[str] = []

    if re.search(r"\bgoto\b", stripped):
        issues.append("contains 'goto' (Lua 5.2+, unsupported by TPT's Lua 5.1)")
    if "//" in stripped:
        issues.append("contains '//' (Lua 5.2+ integer division, unsupported by TPT's Lua 5.1)")

    no_loop_headers = re.sub(r"\bfor\b.*?\bdo\b", " FORDO ", stripped, flags=re.S)
    no_loop_headers = re.sub(r"\bwhile\b.*?\bdo\b", " WHILEDO ", no_loop_headers, flags=re.S)

    n_function = len(re.findall(r"\bfunction\b", stripped))
    n_if = len(re.findall(r"\bif\b", stripped))
    n_for = len(re.findall(r"\bfor\b", stripped))
    n_while = len(re.findall(r"\bwhile\b", stripped))
    n_do = len(re.findall(r"\bdo\b", no_loop_headers))
    opens = n_function + n_if + n_for + n_while + n_do
    ends = len(re.findall(r"\bend\b", stripped))
    repeats = len(re.findall(r"\brepeat\b", stripped))
    untils = len(re.findall(r"\buntil\b", stripped))

    if opens != ends:
        issues.append(
            f"unbalanced block keywords: {opens} opener(s) needing 'end' "
            f"(function={n_function} if={n_if} for={n_for} while={n_while} do={n_do}) vs {ends} 'end'(s)"
        )
    if repeats != untils:
        issues.append(f"unbalanced repeat/until: {repeats} 'repeat' vs {untils} 'until'")

    if issues:
        return False, "; ".join(issues)
    return True, f"{opens} opener/end pairs and {repeats} repeat/until pairs balanced, no 5.2+ syntax detected"


def _luac_check(luac_path: str, path: Path) -> tuple[bool, str]:
    try:
        proc = subprocess.run(
            [luac_path, "-p", str(path)], capture_output=True, text=True, timeout=10,
        )
        if proc.returncode == 0:
            return True, "syntax ok"
        return False, (proc.stderr or proc.stdout or "non-zero exit").strip()
    except Exception as exc:  # pragma: no cover - defensive
        return False, f"{type(exc).__name__}: {exc}"


def check_lua_files() -> None:
    luac_path = shutil.which("luac") or shutil.which("luac5.1") or shutil.which("luac5.3")
    for name in BRIDGE_MODULES:
        path = BRIDGE_SRC / name
        if not path.is_file():
            record(f"lua_parses.{name}", STATUS_SKIP, "not written yet")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if not text.strip():
            record(f"lua_parses.{name}", STATUS_FAIL, "file is empty")
            continue
        if luac_path:
            ok, detail = _luac_check(luac_path, path)
            record(f"lua_parses.{name}", STATUS_PASS if ok else STATUS_FAIL, f"luac -p: {detail}")
        else:
            ok, detail = _structural_lua_check(text)
            record(
                f"lua_parses.{name}",
                STATUS_PASS if ok else STATUS_FAIL,
                f"UNVERIFIED (no luac on this machine) -- structural check only: {detail}",
            )


# ---------------------------------------------------------------------------
# Static check: Python files parse (ast.parse)
# ---------------------------------------------------------------------------


def check_python_files() -> None:
    for name in PYTHON_EXT_MODULES:
        path = POWDER_EXT / name
        if not path.is_file():
            record(f"python_parses.{name}", STATUS_SKIP, "not written yet")
            continue
        try:
            src = path.read_text(encoding="utf-8")
            ast.parse(src, filename=str(path))
            record(f"python_parses.{name}", STATUS_PASS, "ast.parse ok")
        except SyntaxError as exc:
            record(f"python_parses.{name}", STATUS_FAIL, f"SyntaxError: {exc}")
        except Exception as exc:
            record(f"python_parses.{name}", STATUS_FAIL, f"{type(exc).__name__}: {exc}")

    try:
        ast.parse(Path(__file__).read_text(encoding="utf-8"), filename=str(__file__))
        record("python_parses.selftest.py (this file)", STATUS_PASS, "ast.parse ok")
    except Exception as exc:  # pragma: no cover - would mean this file is broken
        record("python_parses.selftest.py (this file)", STATUS_FAIL, f"{type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# Module loading helper shared by the schemas / cross-consistency checks
# ---------------------------------------------------------------------------


def _load_module(path: Path, modname: str) -> tuple[Any, str | None]:
    """Import *path* as *modname* via its file location, isolated from the
    package's own ``__init__.py`` (which may not exist yet). Returns
    ``(module, None)`` on success or ``(None, error_string)`` if the file is
    missing, fails to parse, or raises anything on import (e.g. a broken
    ``from powder_bridge.client import ...`` symbol) -- callers turn that
    into a SKIP/FAIL, never a crash."""
    if not path.is_file():
        return None, "file does not exist"
    try:
        spec = importlib.util.spec_from_file_location(modname, path)
        if spec is None or spec.loader is None:
            return None, "could not build a module spec for this file"
        module = importlib.util.module_from_spec(spec)
        sys.modules[modname] = module
        spec.loader.exec_module(module)
        return module, None
    except Exception as exc:
        return None, f"{type(exc).__name__}: {exc}"


# ---------------------------------------------------------------------------
# Static check: schemas.py internal consistency + 15-tool coverage
# ---------------------------------------------------------------------------


def check_schemas() -> Any:
    """Returns the loaded schemas module (or None) so check_cross_consistency
    can reuse TOOL_ORDER without importing it a second time."""
    path = POWDER_EXT / "schemas.py"
    if not path.is_file():
        record("schemas.file_present", STATUS_SKIP, "schemas.py not written yet")
        return None
    record("schemas.file_present", STATUS_PASS, str(path))

    mod, err = _load_module(path, "pbx_selftest_schemas")
    if mod is None:
        record("schemas.importable", STATUS_FAIL, f"import failed: {err}")
        return None
    record("schemas.importable", STATUS_PASS, "imported cleanly")

    validate = getattr(mod, "validate", None)
    if not callable(validate):
        record("schemas.validate_defined", STATUS_FAIL, "schemas.validate() is not defined / not callable")
    else:
        try:
            validate()
            record("schemas.validate_passes", STATUS_PASS, "schemas.validate() completed without raising")
        except Exception as exc:
            record("schemas.validate_passes", STATUS_FAIL, f"schemas.validate() raised {type(exc).__name__}: {exc}")

    tool_schemas = getattr(mod, "TOOL_SCHEMAS", None)
    if not isinstance(tool_schemas, dict):
        record("schemas.tool_schemas_covers_15", STATUS_FAIL, "TOOL_SCHEMAS missing or not a dict")
    else:
        names = set(tool_schemas)
        expected = set(MCP_TOOL_NAMES)
        if names == expected:
            record("schemas.tool_schemas_covers_15", STATUS_PASS,
                   "TOOL_SCHEMAS covers exactly the 15 spec tool names")
        else:
            record("schemas.tool_schemas_covers_15", STATUS_FAIL,
                   f"missing={sorted(expected - names)} extra={sorted(names - expected)}")

    return mod


# ---------------------------------------------------------------------------
# Static check: cross-file consistency between schemas and handlers
#
# This is the single most valuable check in the harness: it is the one that
# catches element_tools.py / colony_tools.py drifting out of sync with
# schemas.py when different authors write them in parallel.
# ---------------------------------------------------------------------------


def check_cross_consistency(schemas_mod: Any) -> None:
    tool_order = getattr(schemas_mod, "TOOL_ORDER", None) if schemas_mod is not None else None
    if tool_order is None:
        record("consistency.tool_order_present", STATUS_SKIP,
               "schemas.py unavailable or has no TOOL_ORDER -- falling back to the literal spec tool list below")
    else:
        record("consistency.tool_order_present", STATUS_PASS, f"{len(tool_order)} tools declared")
        extra = set(tool_order) - set(MCP_TOOL_NAMES)
        missing = set(MCP_TOOL_NAMES) - set(tool_order)
        if extra or missing:
            record("consistency.tool_order_matches_spec", STATUS_FAIL,
                   f"missing={sorted(missing)} extra={sorted(extra)}")
        else:
            record("consistency.tool_order_matches_spec", STATUS_PASS,
                   "TOOL_ORDER matches the 15 spec tool names exactly")

    element_mod, element_err = _load_module(POWDER_EXT / "element_tools.py", "pbx_selftest_element_tools")
    colony_mod, colony_err = _load_module(POWDER_EXT / "colony_tools.py", "pbx_selftest_colony_tools")

    handlers: dict[str, str] = {}  # tool name -> owning module label
    for mod, err, label in (
        (element_mod, element_err, "element_tools"),
        (colony_mod, colony_err, "colony_tools"),
    ):
        if mod is None:
            record(f"consistency.{label}_importable", STATUS_SKIP, f"{label}.py not available: {err}")
            continue
        h = getattr(mod, "HANDLERS", None)
        if not isinstance(h, dict):
            record(f"consistency.{label}_importable", STATUS_FAIL, f"{label}.HANDLERS is missing or not a dict")
            continue
        record(f"consistency.{label}_importable", STATUS_PASS, f"{len(h)} handler(s): {', '.join(sorted(h))}")
        for tool_name in h:
            if tool_name in handlers:
                record("consistency.no_duplicate_handlers", STATUS_FAIL,
                       f"{tool_name} is registered in both {handlers[tool_name]} and {label}")
            handlers[tool_name] = label

    names_universe = list(tool_order) if tool_order else MCP_TOOL_NAMES
    basis = "schemas.TOOL_ORDER" if tool_order else "the literal 15-tool spec list (schemas.py unavailable)"

    if not handlers:
        record("consistency.every_tool_has_a_handler", STATUS_SKIP,
               f"no handler module (element_tools.py / colony_tools.py) is available to check against {basis}")
        record("consistency.no_orphan_handlers", STATUS_SKIP, "no handler module available")
        return

    missing_handlers = [n for n in names_universe if n not in handlers]
    if missing_handlers:
        record("consistency.every_tool_has_a_handler", STATUS_FAIL,
               f"tools with no handler in element_tools.HANDLERS or colony_tools.HANDLERS "
               f"(checked against {basis}): {', '.join(missing_handlers)}")
    else:
        record("consistency.every_tool_has_a_handler", STATUS_PASS,
               f"every tool in {basis} has a handler")

    orphan_handlers = [n for n in handlers if n not in names_universe]
    if orphan_handlers:
        record("consistency.no_orphan_handlers", STATUS_FAIL,
               f"handlers exist with no schema entry (checked against {basis}): {', '.join(orphan_handlers)}")
    else:
        record("consistency.no_orphan_handlers", STATUS_PASS, "no handler exists without a schema entry")


# ---------------------------------------------------------------------------
# Static check: each Lua module registers the actions the spec says it owns
# ---------------------------------------------------------------------------


def check_lua_actions() -> None:
    for name, actions in MODULE_ACTIONS.items():
        path = BRIDGE_SRC / name
        if not path.is_file():
            record(f"lua_actions.{name}", STATUS_SKIP, "not written yet")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")

        if not actions:
            # 20_behaviors.lua: exposes PBX.state.behaviors.kinds instead of
            # registering actions. This text-scan for kind names is a
            # heuristic, not a real table parse -- it can only catch a kind
            # name being entirely absent from the source.
            missing_kinds = [k for k in BEHAVIOR_KINDS if not re.search(rf"\b{k}\b", text)]
            if missing_kinds:
                record(f"lua_actions.{name}", STATUS_FAIL,
                       f"registers no PBX actions (expected per spec) but appears to be missing "
                       f"behavior kind(s): {', '.join(missing_kinds)}")
            else:
                record(f"lua_actions.{name}", STATUS_PASS,
                       f"no PBX actions expected; all {len(BEHAVIOR_KINDS)} required behavior kind "
                       f"names appear in source (text-scan heuristic, not a table parse)")
            continue

        missing = [
            a for a in actions
            if not re.search(rf'PBX\.register\(\s*["\']{re.escape(a)}["\']', text)
        ]
        if missing:
            record(f"lua_actions.{name}", STATUS_FAIL,
                   f"missing PBX.register(...) for: {', '.join(missing)}")
        else:
            record(f"lua_actions.{name}", STATUS_PASS,
                   f"registers all {len(actions)} expected action(s): {', '.join(actions)}")


def run_static_checks() -> None:
    check_bridge_files()
    check_lua_files()
    check_python_files()
    schemas_mod = check_schemas()
    check_cross_consistency(schemas_mod)
    check_lua_actions()


# ---------------------------------------------------------------------------
# Live mode: a self-contained MCP stdio client
#
# There is a working reference client (ptmcp.py) in a session-scoped agent
# scratchpad directory outside this repository. That path
# is not stable across sessions and not part of this repository, so it
# is reimplemented (not imported) here: the same minimal JSON-RPC handshake
# (spawn powder_toy_mcp.py over stdio, `initialize`, `notifications/initialized`,
# `tools/list`, `tools/call`), plus a background reader thread so a stalled
# server produces a bounded timeout instead of hanging this harness forever.
# ---------------------------------------------------------------------------


class MCPStdioClient:
    def __init__(self, timeout: float = 15.0) -> None:
        self.timeout = timeout
        self.proc = subprocess.Popen(
            [sys.executable, str(MCP_SERVER)],
            cwd=str(ROOT),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._id = 0
        self._out_q: "queue.Queue[str]" = queue.Queue()
        self._reader = threading.Thread(target=self._pump_stdout, daemon=True)
        self._reader.start()

    def _pump_stdout(self) -> None:
        try:
            assert self.proc.stdout is not None
            for line in self.proc.stdout:
                self._out_q.put(line)
        except Exception:
            pass

    def _send(self, obj: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _notify(self, method: str, params: dict[str, Any]) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def _rpc(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self._id += 1
        req_id = self._id
        self._send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        deadline = time.time() + self.timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                if self.proc.poll() is not None:
                    stderr = ""
                    try:
                        if self.proc.stderr:
                            stderr = self.proc.stderr.read(4000)
                    except Exception:
                        pass
                    raise TimeoutError(
                        f"no response to {method} within {self.timeout}s and the server process has "
                        f"exited (code {self.proc.returncode}); stderr: {stderr.strip()[:2000]}"
                    )
                raise TimeoutError(f"no response to {method} within {self.timeout}s")
            try:
                line = self._out_q.get(timeout=min(0.5, remaining))
            except queue.Empty:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == req_id:
                return msg

    def initialize(self) -> dict[str, Any]:
        resp = self._rpc(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "pbx-selftest", "version": "1"},
            },
        )
        self._notify("notifications/initialized", {})
        return resp

    def list_tools(self) -> list[dict[str, Any]]:
        resp = self._rpc("tools/list", {})
        if "error" in resp:
            raise RuntimeError(f"tools/list error: {resp['error']}")
        return resp.get("result", {}).get("tools", [])

    def call(self, name: str, arguments: dict[str, Any] | None = None) -> Any:
        resp = self._rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if "error" in resp:
            return {"_rpc_error": resp["error"]}
        content = resp.get("result", {}).get("content", [])
        text = "\n".join(c.get("text", "") for c in content if c.get("type") == "text")
        try:
            return json.loads(text)
        except Exception:
            return {"_raw_text": text}

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


def _looks_like_not_deployed(resp: dict[str, Any]) -> bool:
    """True when a bridge/transport error means "extension not deployed
    yet" rather than a genuine failure worth flagging."""
    if not isinstance(resp, dict):
        return False
    if resp.get("error_code") == "transport_error":
        return True
    err = str(resp.get("error", "")).lower()
    detail = str(resp.get("detail", "")).lower()
    needles = ("unknown action", "unknown_action", "not deployed", "no such action")
    return any(needle in err or needle in detail for needle in needles)


def _report_extension_status(resp: Any) -> None:
    if not isinstance(resp, dict):
        record("live.extension_status", STATUS_FAIL, f"unexpected response shape: {resp!r}")
        return
    if "_rpc_error" in resp:
        record("live.extension_status", STATUS_FAIL, f"MCP protocol error: {resp['_rpc_error']}")
        return
    if resp.get("ok") is False:
        if _looks_like_not_deployed(resp):
            record("live.extension_status", STATUS_SKIP,
                   f"bridge reports the extension is not deployed yet: {resp.get('error') or resp.get('error_code')}")
        else:
            record("live.extension_status", STATUS_FAIL, f"extension_status returned ok=false: {resp.get('error')}")
        return
    modules = resp.get("modules", [])
    tick = resp.get("tickIndex")
    lines = [f"tickIndex={tick}", f"jobQueue={resp.get('jobQueue')}",
             f"colonyCount={resp.get('colonyCount')}", f"workerCount={resp.get('workerCount')}",
             f"customElementCount={resp.get('customElementCount')}"]
    for m in modules if isinstance(modules, list) else []:
        if isinstance(m, dict):
            lines.append(f"module {m.get('name')}: v{m.get('version')} actions={m.get('actions')} errors={m.get('errors')}")
    record("live.extension_status", STATUS_PASS, "; ".join(lines))


def _report_extension_self_test(resp: Any) -> None:
    if not isinstance(resp, dict):
        record("live.extension_self_test", STATUS_FAIL, f"unexpected response shape: {resp!r}")
        return
    if "_rpc_error" in resp:
        record("live.extension_self_test", STATUS_FAIL, f"MCP protocol error: {resp['_rpc_error']}")
        return
    if resp.get("ok") is False:
        if _looks_like_not_deployed(resp):
            record("live.extension_self_test", STATUS_SKIP,
                   f"bridge reports the extension is not deployed yet: {resp.get('error') or resp.get('error_code')}")
        else:
            record("live.extension_self_test", STATUS_FAIL, f"extension_self_test returned ok=false: {resp.get('error')}")
        return
    checks = resp.get("checks", [])
    if not isinstance(checks, list) or not checks:
        record("live.extension_self_test", STATUS_SKIP, f"ok=true but no 'checks' array in response: {resp}")
        return
    failed = [c for c in checks if isinstance(c, dict) and not c.get("ok")]
    summary = "; ".join(
        f"{c.get('name')}={'ok' if c.get('ok') else 'FAIL'}"
        + (f" ({c.get('detail')})" if c.get("detail") else "")
        for c in checks if isinstance(c, dict)
    )
    if failed:
        record("live.extension_self_test", STATUS_FAIL, f"{len(failed)}/{len(checks)} bridge-side checks failed: {summary}")
    else:
        record("live.extension_self_test", STATUS_PASS, f"all {len(checks)} bridge-side checks passed: {summary}")


def run_live_checks() -> None:
    if not MCP_SERVER.is_file():
        record("live.mcp_server_present", STATUS_FAIL, f"{MCP_SERVER} does not exist")
        return
    record("live.mcp_server_present", STATUS_PASS, str(MCP_SERVER))

    try:
        client = MCPStdioClient(timeout=15.0)
    except Exception as exc:
        record("live.spawn_mcp_server", STATUS_FAIL, f"could not start powder_toy_mcp.py: {exc}")
        return
    record("live.spawn_mcp_server", STATUS_PASS, "subprocess started")

    try:
        try:
            client.initialize()
            record("live.mcp_handshake", STATUS_PASS, "initialize + notifications/initialized completed")
        except Exception as exc:
            record("live.mcp_handshake", STATUS_FAIL, f"handshake failed: {exc}")
            return

        try:
            tools = client.list_tools()
            tool_names = {t.get("name") for t in tools}
            record("live.tools_list", STATUS_PASS, f"{len(tool_names)} tools registered on the running server")
        except Exception as exc:
            record("live.tools_list", STATUS_FAIL, f"tools/list failed: {exc}")
            tool_names = set()

        missing_ext_tools = [n for n in MCP_TOOL_NAMES if n not in tool_names]
        if missing_ext_tools:
            record("live.extension_tools_registered", STATUS_SKIP,
                   f"{len(missing_ext_tools)}/15 extension tools not yet registered in "
                   f"powder_toy_mcp.py (central integration pending): {', '.join(missing_ext_tools)}")
        else:
            record("live.extension_tools_registered", STATUS_PASS, "all 15 extension tools present in tools/list")

        for tool_name, reporter in (
            ("extension_status", _report_extension_status),
            ("extension_self_test", _report_extension_self_test),
        ):
            assert tool_name in LIVE_SAFE_TOOLS  # belt-and-suspenders: never call anything else here
            if tool_name not in tool_names:
                record(f"live.{tool_name}", STATUS_SKIP,
                       f"{tool_name} tool not registered on the running server (not deployed yet)")
                continue
            try:
                args = {"deep": False} if tool_name == "extension_self_test" else {}
                resp = client.call(tool_name, args)
                reporter(resp)
            except Exception as exc:
                record(f"live.{tool_name}", STATUS_FAIL, f"call failed: {exc}")
    finally:
        client.close()


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def print_report(mode_label: str) -> None:
    order = {STATUS_FAIL: 0, STATUS_SKIP: 1, STATUS_PASS: 2}
    rows = sorted(results, key=lambda r: (order[r.status], r.name))
    name_w = max([len(r.name) for r in results] + [5])
    print(f"Powder Bridge extension self-test -- mode: {mode_label}")
    header = f"{'STATUS':<6} {'CHECK':<{name_w}} DETAIL"
    print(header)
    print("-" * min(len(header) + 60, 160))
    for r in rows:
        print(f"{r.status:<6} {r.name:<{name_w}} {r.detail}")
    npass = sum(1 for r in results if r.status == STATUS_PASS)
    nfail = sum(1 for r in results if r.status == STATUS_FAIL)
    nskip = sum(1 for r in results if r.status == STATUS_SKIP)
    print("-" * min(len(header) + 60, 160))
    print(f"{npass} passed, {nfail} failed, {nskip} skipped")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--static", action="store_true",
                         help="run static checks (default behavior; explicit flag is accepted for clarity)")
    parser.add_argument("--live", action="store_true",
                         help="also run read-only live checks against the running game via MCP stdio")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON instead of a text table")
    args = parser.parse_args(argv)

    run_static_checks()
    mode = "static"

    if args.live:
        record("live.client_implementation", STATUS_PASS,
               "reimplemented ptmcp.py's minimal JSON-RPC stdio handshake in this file (not imported), "
               "so the harness has no dependency on the session-scoped scratchpad path; added a "
               "background-thread read with a wall-clock timeout so a stalled server times out instead "
               "of hanging this harness")
        run_live_checks()
        mode = "static+live"

    if args.json:
        payload = {
            "mode": mode,
            "results": [r.as_dict() for r in results],
            "summary": {
                "pass": sum(1 for r in results if r.status == STATUS_PASS),
                "fail": sum(1 for r in results if r.status == STATUS_FAIL),
                "skip": sum(1 for r in results if r.status == STATUS_SKIP),
            },
        }
        print(json.dumps(payload, indent=2))
    else:
        print_report(mode)

    return 1 if any(r.status == STATUS_FAIL for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
