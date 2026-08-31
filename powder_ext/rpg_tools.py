"""RPG development tools -- rapid, constant indexing/work surface for the
Powder RPG (rpg.lua + scripts/lua/rpg_plugins/*), per the owner's 15:24 hub ask
("we need an MCP tool so we can rapidly, constantly index and work on this --
access to everything, all the information and core mechanics").

* ``rpg_status``      -- live game-state snapshot via ``PowderClient().execute_lua``:
  active/seed/frame/day, player pos/depth/biome, hp, camera, inventory,
  hotbar/sel, tools, accessories, current quest, station/machine/enemy counts,
  per-plugin pluginStatus, lastErr/pluginErr, particle count, and an optional
  FPS estimate (samples ``R.frame`` twice, ``fps_sample_ms`` apart).
* ``rpg_search``      -- ranked full-text search (TF-IDF/cosine, same technique
  as ``agent_tools.module_search``) over rpg.lua, every plugin + its README,
  the team hub/roadmap/ideas/research/design docs, and the mechanics KB
  (build-lessons.jsonl, playbook.json). Index built lazily, cached by mtime.
* ``rpg_api``         -- structured dump of the scriptable API: hook names,
  every function/field hung on ``R`` at module scope (parsed from rpg.lua's
  source, with line + one-line context), the game's data tables read live via
  execute_lua (falls back to a static source parse when the bridge is
  unreachable), and every key binding found via ``k == "..."`` checks.
* ``rpg_hub``         -- read or append to knowledge/rpg-hub.md (the team's
  shared append-only log), including inserting an owner-says line.
* ``rpg_reload``      -- hot-reload rpg.lua or one plugin without restarting
  powder.exe (mirrors ``scripts/rpg.py start`` / ``R.reloadPlugin``).
* ``rpg_screenshot``  -- capture the live RPG view, optionally opening the
  bag/menu/quest panel first and restoring it afterward.
* ``rpg_lua``         -- run one Lua snippet against the live RPG with
  ``local R = PBX.state.rpg`` prepended; refuses destructive calls
  (clearSim/loadSave/pendingGen) unless explicitly allowed.

All handlers never raise (guarded by ``HANDLERS`` below), talk to the game
only through ``PowderClient.execute_lua``, and never call sim.clearSim /
sim.loadSave / regenerate the world themselves -- per rpg_plugins/README.md's
"NEVER call sim.clearSim / sim.loadSave" rule, the live sim belongs to
whoever is playing it.
"""

from __future__ import annotations

import json
import math
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from powder_bridge.client import PowderAPIError, PowderConnectionError, PowderClient  # noqa: E402

from powder_ext.repo_paths import BUILD_DIR, KNOWLEDGE_DIR, REPO_ROOT

ROOT = REPO_ROOT
KNOW = ROOT / "knowledge"
LUA_DIR = ROOT / "scripts" / "lua"
RPG_LUA_PATH = LUA_DIR / "rpg.lua"
PLUGIN_DIR = LUA_DIR / "rpg_plugins"
HUB_PATH = KNOW / "rpg-hub.md"
# same ddir tpt.screenshot() writes into for the owner's live session (see
# build_tools.screenshot's SCREENSHOT_DDIR -- kept as a separate constant here
# so this module has no import-order dependency on build_tools).
SCREENSHOT_DDIR = BUILD_DIR

_client: PowderClient | None = None


def _get_client() -> PowderClient:
    global _client
    if _client is None:
        _client = PowderClient()
    return _client


def _lua(code: str) -> Any:
    return _get_client().execute_lua(code).get("result")


def _lua_str(s: str) -> str:
    """Quote a short, already-validated identifier as a Lua string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


# ---------------------------------------------------------------------------
# shared Lua -> JSON helpers, prepended to any script that needs to dump an
# arbitrary R.* table back to Python. jsonstr does real JSON string escaping
# (not Lua's %q, which emits literal embedded newlines that break json.loads).
# ---------------------------------------------------------------------------
_LUA_JSON_HELPERS = r'''
local function jsonstr(s)
  s = tostring(s)
  s = s:gsub('[\\"\n\r\t]', function(c)
    if c == '\\' then return '\\\\'
    elseif c == '"' then return '\\"'
    elseif c == '\n' then return '\\n'
    elseif c == '\r' then return '\\r'
    elseif c == '\t' then return '\\t'
    end
  end)
  return '"' .. s .. '"'
end
local function ser(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "string" then return jsonstr(v) end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return tostring(v)
  end
  if t == "boolean" then return tostring(v) end
  if t == "function" or t == "nil" or depth > 8 then return "null" end
  if t == "table" then
    local n, isArr = 0, true
    for k in pairs(v) do n = n + 1; if type(k) ~= "number" then isArr = false end end
    if isArr and n > 0 then
      local m = 0; for _ in ipairs(v) do m = m + 1 end
      if m == n then
        local parts = {}
        for i = 1, n do parts[#parts + 1] = ser(v[i], depth + 1) end
        return "[" .. table.concat(parts, ",") .. "]"
      end
    end
    local parts = {}
    for k, val in pairs(v) do
      if type(val) ~= "function" then parts[#parts + 1] = jsonstr(tostring(k)) .. ":" .. ser(val, depth + 1) end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end
local function tlen(t) local n = 0; if t then for _ in pairs(t) do n = n + 1 end end; return n end
'''


# ---------------------------------------------------------------------------
# rpg_status
# ---------------------------------------------------------------------------

_STATUS_LUA = _LUA_JSON_HELPERS + r'''
local R = PBX.state.rpg
if not R then return '{"ok":false,"error":"rpg not loaded"}' end
local px = (R.P and R.P.x) or 0
local py = (R.P and R.P.y) or 0
local depth_m, biome = 0, "?"
if R.surfaceAt then local ok, surf = pcall(R.surfaceAt, math.floor(px)); if ok then depth_m = math.floor((py - surf) / 4) end end
if R.biomeAt then local ok, b = pcall(R.biomeAt, math.floor(px)); if ok then biome = b end end
local enemies = 0
if R.enemyList then
  local ok, list = pcall(R.enemyList)
  if ok and list then for _, e in ipairs(list) do if not e.dead then enemies = enemies + 1 end end end
else
  enemies = tlen(R.EN)
end
local stationsArr = {}
for _, st in ipairs(R.stations or {}) do stationsArr[#stationsArr + 1] = { kind = st.kind, x = st.x, y = st.y } end
local q = R.QUESTS and R.QUESTS[R.quest or 0]
local pausedRaw = tpt.set_pause()
local out = {}
out[#out + 1] = '"ok":true'
out[#out + 1] = '"active":' .. tostring(R.active == true)
out[#out + 1] = '"paused":' .. tostring(pausedRaw == 1)
out[#out + 1] = '"seed":' .. tostring(R.seed or 0)
out[#out + 1] = '"frame":' .. tostring(R.frame or 0)
out[#out + 1] = '"day":' .. tostring(R.day or 1)
out[#out + 1] = '"deaths":' .. tostring(R.deaths or 0)
out[#out + 1] = '"player":{"x":' .. tostring(px) .. ',"y":' .. tostring(py) .. ',"depth_m":' .. tostring(depth_m) ..
  ',"biome":' .. jsonstr(biome) .. ',"onGround":' .. tostring(R.P and R.P.onGround == true) ..
  ',"face":' .. tostring(R.P and R.P.face or 1) .. '}'
out[#out + 1] = '"hp":' .. tostring(R.hp or 0)
out[#out + 1] = '"camera":{"x":' .. tostring(R.cam and R.cam.x or 0) .. ',"y":' .. tostring(R.cam and R.cam.y or 0) .. '}'
out[#out + 1] = '"inventory":' .. ser(R.inventory or {})
out[#out + 1] = '"hotbar":' .. ser(R.hotbar or {})
out[#out + 1] = '"sel":' .. tostring(R.sel or 1)
out[#out + 1] = '"tools":' .. ser(R.TOOLS or {})
out[#out + 1] = '"acc":' .. ser(R.acc or {})
out[#out + 1] = '"accOff":' .. ser(R.accOff or {})
out[#out + 1] = '"quest":{"index":' .. tostring(R.quest or 0) .. ',"text":' .. jsonstr(q and q.txt or "") .. '}'
out[#out + 1] = '"stations":' .. ser(stationsArr)
out[#out + 1] = '"machines_count":' .. tostring(tlen(R.machines))
out[#out + 1] = '"enemies_count":' .. tostring(enemies)
out[#out + 1] = '"pluginStatus":' .. ser(R.pluginStatus or {})
out[#out + 1] = '"lastErr":' .. jsonstr(R.lastErr or "")
out[#out + 1] = '"pluginErr":' .. jsonstr(R.pluginErr or "")
out[#out + 1] = '"weather":' .. ser(R.weather or {})
out[#out + 1] = '"particles":' .. tostring(sim.partCount())
return "{" .. table.concat(out, ",") .. "}"
'''

_FRAME_ONLY_LUA = 'local R = PBX.state.rpg return tostring(R and R.frame or -1)'


def rpg_status(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    include_fps = bool(args.get("include_fps", True))
    sample_ms = int(args.get("fps_sample_ms", 1000) or 1000)
    sample_ms = max(100, min(3000, sample_ms))
    try:
        raw = _lua(_STATUS_LUA)
    except (PowderAPIError, PowderConnectionError) as exc:
        return {"ok": False, "tool": "rpg_status", "error": f"{type(exc).__name__}: {exc}"}
    try:
        data = json.loads(str(raw))
    except json.JSONDecodeError as exc:
        return {"ok": False, "tool": "rpg_status", "error": f"bad status json: {exc}", "raw": str(raw)[:500]}
    if not isinstance(data, dict) or data.get("ok") is False:
        return {"ok": False, "tool": "rpg_status", "error": (data or {}).get("error", "rpg not loaded")}
    fps = None
    if include_fps and data.get("active"):
        frame_before = data.get("frame")
        t0 = time.perf_counter()
        time.sleep(sample_ms / 1000.0)
        frame_after = None
        try:
            frame_after = int(str(_lua(_FRAME_ONLY_LUA)))
        except (PowderAPIError, PowderConnectionError, TypeError, ValueError):
            frame_after = None
        dt = time.perf_counter() - t0
        if isinstance(frame_before, int) and frame_after is not None and frame_after >= frame_before and dt > 0:
            fps = round((frame_after - frame_before) / dt, 2)
    data["fps"] = fps
    data["ok"] = True
    data["tool"] = "rpg_status"
    return data


# ---------------------------------------------------------------------------
# rpg_search -- lazy, mtime-cached TF-IDF index over the RPG corpus
# ---------------------------------------------------------------------------

_SEARCH_TOKEN_RE = re.compile(r"[a-z0-9_]+")


def _search_tokenize(text: str) -> list[str]:
    return _SEARCH_TOKEN_RE.findall(text.lower())


def _search_corpus_files() -> list[tuple[Path, str]]:
    """(path, scope_tag) pairs for every file rpg_search indexes."""
    files: list[tuple[Path, str]] = [(RPG_LUA_PATH, "code")]
    if PLUGIN_DIR.is_dir():
        for path in sorted(PLUGIN_DIR.glob("*.lua")):
            files.append((path, "code"))
        readme = PLUGIN_DIR / "README.md"
        if readme.is_file():
            files.append((readme, "code"))
    for name in (
        "rpg-hub.md",
        "rpg-roadmap.md",
        "rpg-ideas.md",
        "research-worldgen-2026-08-26.md",
        "research-inventory-ux.md",
    ):
        path = KNOW / name
        if path.is_file():
            files.append((path, "docs"))
    if KNOW.is_dir():
        for path in sorted(KNOW.glob("design-rpg-*.md")):
            files.append((path, "docs"))
    for name in ("build-lessons.jsonl", "playbook.json"):
        path = KNOW / name
        if path.is_file():
            files.append((path, "mechanics"))
    return files


_SEARCH_INDEX_CACHE: dict[str, Any] = {"mtimes": {}, "lines": {}}


def _refresh_search_index() -> None:
    """Rebuild only the files whose mtime changed since the last call."""
    cache = _SEARCH_INDEX_CACHE
    current = _search_corpus_files()
    current_keys = {str(path) for path, _ in current}
    for stale_key in set(cache["mtimes"]) - current_keys:
        cache["mtimes"].pop(stale_key, None)
        cache["lines"].pop(stale_key, None)
    for path, _scope in current:
        key = str(path)
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if cache["mtimes"].get(key) == mtime:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        indexed: list[tuple[int, list[str], str]] = []
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if not stripped:
                continue
            tokens = _search_tokenize(stripped)
            if tokens:
                indexed.append((lineno, tokens, stripped))
        cache["lines"][key] = indexed
        cache["mtimes"][key] = mtime


def _search_rank(query: str, scope: str, k: int) -> list[dict[str, Any]]:
    _refresh_search_index()
    scope_keys = {str(path) for path, tag in _search_corpus_files() if scope == "all" or tag == scope}
    corpus: list[tuple[str, int, list[str], str]] = []
    for key, indexed in _SEARCH_INDEX_CACHE["lines"].items():
        if key not in scope_keys:
            continue
        for lineno, tokens, raw in indexed:
            corpus.append((key, lineno, tokens, raw))
    n_docs = len(corpus) or 1
    doc_freq: dict[str, int] = {}
    for _, _, tokens, _ in corpus:
        for term in set(tokens):
            doc_freq[term] = doc_freq.get(term, 0) + 1

    def idf(term: str) -> float:
        return math.log((n_docs + 1) / (doc_freq.get(term, 0) + 1)) + 1.0

    q_tokens = _search_tokenize(query)
    if not q_tokens:
        return []
    q_tf: dict[str, int] = {}
    for term in q_tokens:
        q_tf[term] = q_tf.get(term, 0) + 1
    q_vec = {term: tf * idf(term) for term, tf in q_tf.items()}
    q_norm = math.sqrt(sum(w * w for w in q_vec.values())) or 1.0

    scored: list[tuple[float, str, int, str]] = []
    for key, lineno, tokens, raw in corpus:
        d_tf: dict[str, int] = {}
        for term in tokens:
            d_tf[term] = d_tf.get(term, 0) + 1
        dot = 0.0
        d_sq = 0.0
        for term, tf in d_tf.items():
            w = tf * idf(term)
            d_sq += w * w
            if term in q_vec:
                dot += w * q_vec[term]
        if dot <= 0.0:
            continue
        d_norm = math.sqrt(d_sq) or 1.0
        scored.append((dot / (q_norm * d_norm), key, lineno, raw))
    scored.sort(key=lambda item: -item[0])
    return [
        {"file": key, "line": lineno, "snippet": raw[:240], "score": round(score, 4)}
        for score, key, lineno, raw in scored[:k]
    ]


def rpg_search(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    query = str(args.get("query") or "").strip()
    if not query:
        return {"ok": False, "tool": "rpg_search", "error": "query must be a non-empty string"}
    k = int(args.get("k", 10) or 10)
    k = max(1, min(50, k))
    scope = args.get("scope") or "all"
    if scope not in ("code", "docs", "mechanics", "all"):
        return {"ok": False, "tool": "rpg_search", "error": "scope must be code|docs|mechanics|all"}
    results = _search_rank(query, scope, k)
    return {"ok": True, "tool": "rpg_search", "query": query, "scope": scope, "count": len(results), "results": results}


# ---------------------------------------------------------------------------
# rpg_api -- hooks, R-scope helpers, data tables (live or static-fallback), key bindings
# ---------------------------------------------------------------------------

_HOOK_KEY_RE = re.compile(r"(\w+)\s*=\s*\{\}")
_FUNC_DEF_RE = re.compile(r"^function\s+R\.(\w+)\s*\(", re.MULTILINE)
_MULTI_ASSIGN_RE = re.compile(r"^((?:R\.\w+\s*,\s*)*R\.\w+)\s*=(?!=)", re.MULTILINE)
_RDOT_RE = re.compile(r"R\.(\w+)")
_KEY_CHECK_RE = re.compile(r'k\s*==\s*"([^"]+)"')
_FLAT_ENTRY_RE = re.compile(r'(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?)')

_FLAT_TABLE_NAMES = ("NAMES", "HARD", "MINEABLE", "STATIONS")
_NESTED_TABLE_NAMES = ("RECIPES", "ITEMS", "ACCS", "QUESTS")
_ALL_TABLE_NAMES = _NESTED_TABLE_NAMES + _FLAT_TABLE_NAMES

_API_LUA = _LUA_JSON_HELPERS + r'''
local R = PBX.state.rpg
if not R then return '{"ok":false,"error":"rpg not loaded"}' end
local out = {}
out[#out + 1] = '"ok":true'
''' + "\n".join(
    f"out[#out + 1] = '\"{name}\":' .. ser(R.{name})"
    for name in _ALL_TABLE_NAMES
) + r'''
return "{" .. table.concat(out, ",") .. "}"
'''


def _line_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _parse_hooks(source: str) -> list[str]:
    """R.hooks is declared as one flat single-line table (`R.hooks = { tick =
    {}, draw = {}, ... }`); a naive `\\{([^}]*)\\}` capture can't cross the
    nested empty-table braces, so this scans the whole line instead.
    """
    for line in source.splitlines():
        if line.strip().startswith("R.hooks = {") or line.strip().startswith("R.hooks="):
            return _HOOK_KEY_RE.findall(line)
    return []


def _parse_helpers(source: str) -> list[dict[str, Any]]:
    lines = source.splitlines()
    helpers: dict[str, dict[str, Any]] = {}
    for match in _FUNC_DEF_RE.finditer(source):
        name = match.group(1)
        line = _line_for_offset(source, match.start())
        helpers[name] = {"name": name, "kind": "function", "line": line, "context": lines[line - 1].strip()[:200]}
    for match in _MULTI_ASSIGN_RE.finditer(source):
        line = _line_for_offset(source, match.start())
        context = lines[line - 1].strip()[:200]
        for name in _RDOT_RE.findall(match.group(1)):
            if name not in helpers:
                helpers[name] = {"name": name, "kind": "field", "line": line, "context": context}
    return sorted(helpers.values(), key=lambda h: h["line"])


def _parse_key_bindings() -> list[dict[str, Any]]:
    bindings: list[dict[str, Any]] = []
    files = [RPG_LUA_PATH]
    if PLUGIN_DIR.is_dir():
        files.extend(sorted(PLUGIN_DIR.glob("*.lua")))
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for match in _KEY_CHECK_RE.finditer(text):
            bindings.append({"key": match.group(1), "file": str(path), "line": _line_for_offset(text, match.start())})
    return bindings


def _static_flat_table(source: str, name: str) -> dict[str, Any]:
    match = re.search(rf"R\.{name}\s*=\s*\{{(.*?)\}}", source, re.DOTALL)
    if not match:
        return {}
    out: dict[str, Any] = {}
    for entry in _FLAT_ENTRY_RE.finditer(match.group(1)):
        key, value = entry.group(1), entry.group(2)
        if value.startswith('"'):
            out[key] = value[1:-1]
        else:
            out[key] = float(value) if "." in value else int(value)
    return out


def _static_nested_block(source: str, name: str) -> str | None:
    """Brace-counted extraction of `R.<name> = { ... }` for tables too nested
    for a regex (RECIPES/ITEMS/ACCS/QUESTS) -- returned as raw source text so
    a fallback caller can still read the real definition.
    """
    idx = source.find(f"R.{name} =")
    if idx == -1:
        return None
    brace = source.find("{", idx)
    if brace == -1:
        return None
    depth = 0
    for pos in range(brace, len(source)):
        char = source[pos]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[idx:pos + 1]
    return None


def rpg_api(arguments: dict[str, Any]) -> dict[str, Any]:
    try:
        source = RPG_LUA_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        return {"ok": False, "tool": "rpg_api", "error": f"cannot read rpg.lua: {exc}"}

    tables: dict[str, Any] = {}
    tables_source = "static"
    try:
        raw = _lua(_API_LUA)
        data = json.loads(str(raw))
        if not isinstance(data, dict) or data.get("ok") is False:
            raise RuntimeError((data or {}).get("error", "rpg not loaded") if isinstance(data, dict) else "bad response")
        for name in _ALL_TABLE_NAMES:
            tables[name] = data.get(name)
        tables_source = "live"
    except (PowderAPIError, PowderConnectionError, json.JSONDecodeError, RuntimeError):
        for name in _FLAT_TABLE_NAMES:
            tables[name] = _static_flat_table(source, name)
        for name in _NESTED_TABLE_NAMES:
            block = _static_nested_block(source, name)
            tables[name] = {"raw_source": block} if block else None

    return {
        "ok": True,
        "tool": "rpg_api",
        "tables_source": tables_source,
        "hooks": _parse_hooks(source),
        "helpers": _parse_helpers(source),
        "key_bindings": _parse_key_bindings(),
        "tables": tables,
    }


# ---------------------------------------------------------------------------
# rpg_hub -- read/append the team hub
# ---------------------------------------------------------------------------

def rpg_hub(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    action = args.get("action")
    if action not in ("read", "post", "drew"):
        return {"ok": False, "tool": "rpg_hub", "error": "action must be read|post|drew"}
    if not HUB_PATH.is_file():
        return {"ok": False, "tool": "rpg_hub", "error": f"hub file missing: {HUB_PATH}"}

    if action == "read":
        text = HUB_PATH.read_text(encoding="utf-8")
        all_lines = text.splitlines()
        lines_arg = args.get("lines")
        if isinstance(lines_arg, int) and lines_arg > 0:
            text = "\n".join(all_lines[-lines_arg:])
        return {"ok": True, "tool": "rpg_hub", "action": "read", "path": str(HUB_PATH), "total_lines": len(all_lines), "text": text}

    text_arg = args.get("text")
    if not isinstance(text_arg, str) or not text_arg.strip():
        return {"ok": False, "tool": "rpg_hub", "error": "text is required for post/drew"}
    text_arg = text_arg.strip()
    ts = time.strftime("%H:%M")
    content = HUB_PATH.read_text(encoding="utf-8")

    if action == "post":
        who = str(args.get("who") or "mcp").strip() or "mcp"
        line = f"- [{ts}] {who}: {text_arg}"
        if not content.endswith("\n"):
            content += "\n"
        content += line + "\n"
        HUB_PATH.write_text(content, encoding="utf-8")
        return {"ok": True, "tool": "rpg_hub", "action": "post", "appended": line}

    # action == "drew": insert under the owner-says section, just above "## Ownership"
    marker = "## Ownership"
    idx = content.find(marker)
    if idx == -1:
        return {"ok": False, "tool": "rpg_hub", "error": "## Ownership section not found; hub structure changed"}
    line = f'- {ts} "{text_arg}"'
    before = content[:idx].rstrip("\n")
    after = content[idx:]
    new_content = before + "\n" + line + "\n\n" + after
    HUB_PATH.write_text(new_content, encoding="utf-8")
    return {"ok": True, "tool": "rpg_hub", "action": "drew", "inserted": line}


# ---------------------------------------------------------------------------
# rpg_reload -- hot-reload core or one plugin
# ---------------------------------------------------------------------------

_PLUGIN_NAME_RE = re.compile(r"^[a-z][a-z_]{0,30}$")

_STATUS_SNAPSHOT_LUA = _LUA_JSON_HELPERS + r'''
local R = PBX.state.rpg
if not R then return '{"ok":false,"error":"rpg not loaded"}' end
return '{"ok":true,"pluginStatus":' .. ser(R.pluginStatus or {}) .. ',"pluginErr":' .. jsonstr(R.pluginErr or "") ..
  ',"lastErr":' .. jsonstr(R.lastErr or "") .. '}'
'''


def _status_snapshot() -> dict[str, Any]:
    try:
        raw = _lua(_STATUS_SNAPSHOT_LUA)
        data = json.loads(str(raw))
        return data if isinstance(data, dict) else {"ok": False, "error": "bad snapshot response"}
    except (PowderAPIError, PowderConnectionError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}


def rpg_reload(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    target = args.get("target")
    if target not in ("core", "plugin"):
        return {"ok": False, "tool": "rpg_reload", "error": "target must be core|plugin"}
    client = _get_client()

    if target == "core":
        try:
            source = RPG_LUA_PATH.read_text(encoding="utf-8")
        except OSError as exc:
            return {"ok": False, "tool": "rpg_reload", "target": "core", "error": f"cannot read rpg.lua: {exc}"}
        try:
            result = client.execute_lua(source).get("result")
        except (PowderAPIError, PowderConnectionError) as exc:
            return {"ok": False, "tool": "rpg_reload", "target": "core", "error": f"{type(exc).__name__}: {exc}"}
        snapshot = _status_snapshot()
        return {"ok": True, "tool": "rpg_reload", "target": "core", "result": str(result), **snapshot}

    name = args.get("name")
    if not isinstance(name, str) or not _PLUGIN_NAME_RE.match(name):
        return {"ok": False, "tool": "rpg_reload", "error": "name must be a lowercase plugin identifier (e.g. world, enemies, machines, items, save, ui)"}
    code = f'local R = PBX.state.rpg\nif not R then return "rpg not loaded" end\nreturn R.reloadPlugin({_lua_str(name)})'
    try:
        result = client.execute_lua(code).get("result")
    except (PowderAPIError, PowderConnectionError) as exc:
        return {"ok": False, "tool": "rpg_reload", "target": "plugin", "name": name, "error": f"{type(exc).__name__}: {exc}"}
    snapshot = _status_snapshot()
    return {"ok": True, "tool": "rpg_reload", "target": "plugin", "name": name, "result": str(result), **snapshot}


# ---------------------------------------------------------------------------
# rpg_screenshot
# ---------------------------------------------------------------------------

# panel -> (Lua table holding the flag, flag name); "core" means PBX.state.rpg
# itself, "ui" means PBX.state.rpg.ui (set by rpg_plugins/ui.lua).
_PANEL_FLAGS: dict[str, tuple[str, str]] = {
    "bag": ("ui", "bagOpen"),
    "menu": ("core", "menuOpen"),
    "quests": ("ui", "questOpen"),
}


def rpg_screenshot(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    panel = args.get("panel")
    if panel is not None and panel not in _PANEL_FLAGS:
        return {"ok": False, "tool": "rpg_screenshot", "error": f"panel must be one of {sorted(_PANEL_FLAGS)} or omitted"}
    client = _get_client()
    opened = False
    prev_value = False
    if panel is not None:
        kind, flag = _PANEL_FLAGS[panel]
        if kind == "core":
            open_code = f'local R = PBX.state.rpg\nif not R then return "no-rpg" end\nlocal prev = R.{flag}\nR.{flag} = true\nreturn tostring(prev == true)'
        else:
            open_code = f'local R = PBX.state.rpg\nif not R or not R.ui then return "no-rpg" end\nlocal prev = R.ui.{flag}\nR.ui.{flag} = true\nreturn tostring(prev == true)'
        try:
            prev_raw = str(client.execute_lua(open_code).get("result"))
        except (PowderAPIError, PowderConnectionError) as exc:
            return {"ok": False, "tool": "rpg_screenshot", "error": f"{type(exc).__name__}: {exc}"}
        if prev_raw == "no-rpg":
            return {"ok": False, "tool": "rpg_screenshot", "error": "rpg.lua / ui plugin not loaded"}
        opened = True
        prev_value = prev_raw == "true"

    filename = ""
    error: str | None = None
    try:
        filename = str(client.execute_lua('return tostring(tpt.screenshot(0,0) or "")').get("result") or "")
    except (PowderAPIError, PowderConnectionError) as exc:
        error = f"{type(exc).__name__}: {exc}"
    finally:
        if opened:
            kind, flag = _PANEL_FLAGS[panel]
            restore = "true" if prev_value else "false"
            if kind == "core":
                restore_code = f'local R = PBX.state.rpg\nif R then R.{flag} = {restore} end\nreturn "ok"'
            else:
                restore_code = f'local R = PBX.state.rpg\nif R and R.ui then R.ui.{flag} = {restore} end\nreturn "ok"'
            try:
                client.execute_lua(restore_code)
            except (PowderAPIError, PowderConnectionError):
                pass

    if error is not None:
        return {"ok": False, "tool": "rpg_screenshot", "error": error}
    if not filename:
        return {"ok": False, "tool": "rpg_screenshot", "error": "tpt.screenshot returned no filename"}
    path = SCREENSHOT_DDIR / filename
    for _ in range(20):
        if path.is_file():
            break
        time.sleep(0.05)
    if not path.is_file():
        return {"ok": False, "tool": "rpg_screenshot", "error": f"screenshot file not found: {path}"}
    return {"ok": True, "tool": "rpg_screenshot", "panel": panel, "path": str(path)}


# ---------------------------------------------------------------------------
# rpg_lua -- run an arbitrary snippet, guarded against destructive calls
# ---------------------------------------------------------------------------

_DESTRUCTIVE_MARKERS = ("clearsim", "loadsave", "pendinggen")


def rpg_lua(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    code = args.get("code")
    if not isinstance(code, str) or not code.strip():
        return {"ok": False, "tool": "rpg_lua", "error": "code must be a non-empty string"}
    allow_destructive = bool(args.get("allow_destructive", False))
    lowered = code.lower()
    hit = [marker for marker in _DESTRUCTIVE_MARKERS if marker in lowered]
    if hit and not allow_destructive:
        return {
            "ok": False,
            "tool": "rpg_lua",
            "error": f"refused: snippet references {hit}; pass allow_destructive=true to override",
            "matched": hit,
        }
    full_code = "local R = PBX.state.rpg\n" + code
    try:
        result = _get_client().execute_lua(full_code).get("result")
    except (PowderAPIError, PowderConnectionError) as exc:
        return {"ok": False, "tool": "rpg_lua", "error": f"{type(exc).__name__}: {exc}"}
    return {"ok": True, "tool": "rpg_lua", "result": result}


# ---------------------------------------------------------------------------
# registry
# ---------------------------------------------------------------------------

_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "rpg_status": rpg_status,
    "rpg_search": rpg_search,
    "rpg_api": rpg_api,
    "rpg_hub": rpg_hub,
    "rpg_reload": rpg_reload,
    "rpg_screenshot": rpg_screenshot,
    "rpg_lua": rpg_lua,
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
