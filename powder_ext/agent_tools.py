"""Agent-loop tools distilled from building-agent research (2026-08-25).

* ``world_state``  -- compact, accurate world summary for every model turn.
  Factorio Learning Environment found ~98% of agent failures were *state
  tracking*, not code generation; the fix is to hand the model a fresh,
  compact state each step instead of making it remember.
* ``next_task``    -- Voyager-style automatic curriculum over the graded playbook:
  lowest unpassed practice first; a failed attempt is decomposed into that
  practice's individual steps; passes unlock the next level.  Deterministic --
  no LLM in the loop -- so tiny models can be driven by it.
* ``record_attempt`` -- append one (goal, blueprint, verdict, evidence) record
  to knowledge/attempts.jsonl; this is the dataset for later SFT/DPO of a
  small model and the input to ``next_task``.
* ``blueprint_grammar`` -- a GBNF grammar + JSON Schema for Powder Blueprint v1
  so llama.cpp/Ollama can *force* syntactically valid blueprints (grammar-
  constrained decoding) rather than being asked nicely.
* ``module_search`` / ``module_retrieve`` -- rank the 76+ builtin+registry
  modules by relevance to a request (research round 3 item 2: TinyAgent,
  arXiv 2409.00608, shows a retrieval-shortlisted tool list both improves
  accuracy and roughly halves prompt tokens vs. dumping the full list every
  call). Uses Ollama's own ``/api/embeddings`` endpoint when reachable
  (``nomic-embed-text``/``all-minilm`` -- no new dependency, round 3 item 1),
  else a pure-stdlib TF-IDF/cosine fallback so this is always offline-usable.
* ``gate_modules`` / ``missing_elements_for_module`` -- precondition gate
  (round 3 item 5, modeled on arXiv 2608.01050's Wix Helpmate pipeline):
  a *registry* module is "unavailable" when it references an element that is
  neither in the stock catalog nor currently a live custom element
  (``blueprint_tools._custom_elements()``), so the model is told plainly what
  it cannot use right now instead of being offered it and failing later.

All handlers never raise (guarded), talk to the game only through
PowderClient.execute_lua (read-only census for world_state / the live custom
element list), and write only under D:/powder-toy/knowledge/.
"""

from __future__ import annotations

import json
import math
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from powder_bridge.client import PowderAPIError, PowderConnectionError, PowderClient  # noqa: E402

from powder_ext.repo_paths import BUILD_DIR, KNOWLEDGE_DIR

KNOW = KNOWLEDGE_DIR
ATTEMPTS = KNOW / "attempts.jsonl"
PLAYBOOK = KNOW / "playbook.json"

_client: PowderClient | None = None


def _get_client() -> PowderClient:
    global _client
    if _client is None:
        _client = PowderClient()
    return _client


# ---------------------------------------------------------------------------
# world_state
# ---------------------------------------------------------------------------

_WORLD_LUA = r'''
local MAXEL = %d
local counts,bb,tsum,tmax = {},{},{},{}
local n = 0
for i in sim.parts() do
  local t = sim.partProperty(i,"type"); local nm = elem.property(t,"Name") or tostring(t)
  local x,y = sim.partPosition(i); local tp = sim.partProperty(i,"temp")
  counts[nm] = (counts[nm] or 0) + 1
  local b = bb[nm]; if not b then bb[nm] = {x,y,x,y} else
    if x<b[1] then b[1]=x end; if y<b[2] then b[2]=y end; if x>b[3] then b[3]=x end; if y>b[4] then b[4]=y end end
  tsum[nm] = (tsum[nm] or 0) + tp; if not tmax[nm] or tp > tmax[nm] then tmax[nm] = tp end
  n = n + 1
end
local rows = {}
for k,v in pairs(counts) do local b = bb[k]
  rows[#rows+1] = {k, v, b[1], b[2], b[3], b[4], math.floor(tsum[k]/v - 273.15 + 0.5), math.floor(tmax[k] - 273.15 + 0.5)} end
table.sort(rows, function(a,b) return a[2] > b[2] end)
local out = {}
for i = 1, math.min(#rows, MAXEL) do local r = rows[i]
  out[#out+1] = string.format('{"el":"%%s","n":%%d,"box":[%%d,%%d,%%d,%%d],"tavg":%%d,"tmax":%%d}', r[1],r[2],r[3],r[4],r[5],r[6],r[7],r[8]) end
-- walls
local walls = {}; local wn = 0
for cx = 0,152 do for cy = 0,95 do local w = tpt.get_wallmap(cx,cy); if w and w ~= 0 then wn = wn + 1; walls[w] = (walls[w] or 0) + 1 end end end
local wr = {}; for k,v in pairs(walls) do wr[#wr+1] = string.format('"%%d":%%d', k, v) end
-- pressure extremes
local pmin,pmax,pminc,pmaxc = 0,0,"0,0","0,0"
for cx = 0,152 do for cy = 0,95 do local p = sim.pressure(cx,cy)
  if p < pmin then pmin = p; pminc = (cx*4)..","..(cy*4) end
  if p > pmax then pmax = p; pmaxc = (cx*4)..","..(cy*4) end end end
-- occupancy grid at 16px for empty-rectangle search (38x24)
local occ = {}
for i in sim.parts() do local x,y = sim.partPosition(i); occ[math.floor(y/16)*40 + math.floor(x/16)] = true end
for cx = 0,152 do for cy = 0,95 do if tpt.get_wallmap(cx,cy) ~= 0 then occ[math.floor(cy/4)*40 + math.floor(cx/4)] = true end end end
local grid = {}
for gy = 0,23 do local s = ""; for gx = 0,37 do s = s .. (occ[gy*40+gx] and "#" or ".") end; grid[#grid+1] = s end
local paused = tpt.set_pause()
return '{"parts":'..n..',"paused":'..tostring(paused == 1)..',"elements":['..table.concat(out,",")..'],"walls":{'..table.concat(wr,",")..'},"wall_cells":'..wn..
  ',"pressure":{"min":'..string.format("%%.0f",pmin)..',"min_at":['..pminc..'],"max":'..string.format("%%.0f",pmax)..',"max_at":['..pmaxc..']},"grid16":["'..table.concat(grid,'","')..'"]}'
'''

_WALL_NAMES = {1: "CNDTW", 2: "EWALL", 3: "DTECT", 4: "STRM", 5: "FAN", 6: "LIQD", 7: "ABSRB", 8: "WALL", 9: "AIR", 10: "POWDR",
               11: "CNDTR", 12: "EHOLE", 13: "GAS", 14: "GRVTY", 15: "ENRGY", 16: "NOAIR", 17: "ERASEA", 18: "STASIS"}


def _empty_rects(grid: list[str], min_w: int = 4, min_h: int = 3, limit: int = 6) -> list[dict[str, int]]:
    """Largest empty rectangles on the 16px grid (greedy), as pixel boxes."""
    H, W = len(grid), len(grid[0]) if grid else 0
    free = [[c == "." for c in row] for row in grid]
    rects: list[tuple[int, int, int, int, int]] = []
    for y in range(H):
        for x in range(W):
            if not free[y][x]:
                continue
            # grow the widest rectangle of maximal height starting here (simple, good enough)
            w = 0
            while x + w < W and free[y][x + w]:
                w += 1
            best = None
            for ww in range(w, min_w - 1, -1):
                h = 0
                while y + h < H and all(free[y + h][x:x + ww]):
                    h += 1
                if h >= min_h and (best is None or ww * h > best[0]):
                    best = (ww * h, ww, h)
            if best:
                rects.append((best[0], x, y, best[1], best[2]))
    rects.sort(reverse=True)
    out: list[dict[str, int]] = []
    used: list[tuple[int, int, int, int]] = []
    for area, x, y, w, h in rects:
        box = (x, y, x + w - 1, y + h - 1)
        if any(not (box[2] < u[0] or box[0] > u[2] or box[3] < u[1] or box[1] > u[3]) for u in used):
            continue
        used.append(box)
        out.append({"x": x * 16, "y": y * 16, "width": w * 16, "height": h * 16})
        if len(out) >= limit:
            break
    return out


def world_state(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    max_elements = int(args.get("max_elements", 24))
    client = _get_client()
    try:
        raw = client.execute_lua(_WORLD_LUA % max_elements).get("result")
        data = json.loads(str(raw))
    except (PowderAPIError, PowderConnectionError) as exc:
        return {"ok": False, "tool": "world_state", "error": f"{type(exc).__name__}: {exc}"}
    except json.JSONDecodeError as exc:
        return {"ok": False, "tool": "world_state", "error": f"bad census json: {exc}"}
    data["walls"] = {_WALL_NAMES.get(int(k), k): v for k, v in data.get("walls", {}).items()}
    hot = [e for e in data["elements"] if e["tmax"] >= 500]
    data["hot_spots"] = [{"el": e["el"], "tmax": e["tmax"], "box": e["box"]} for e in hot][:8]
    data["empty_rects"] = _empty_rects(data.get("grid16", []))
    # one-paragraph text the model can read directly
    top = ", ".join(f"{e['el']}x{e['n']}@({e['box'][0]},{e['box'][1]})-({e['box'][2]},{e['box'][3]})" for e in data["elements"][:10])
    text = (f"{data['parts']} particles, {'paused' if data['paused'] else 'RUNNING'}; top: {top}. "
            f"Walls: {data['walls'] or 'none'}. Pressure {data['pressure']['min']}..{data['pressure']['max']}. "
            f"Hot: {', '.join(h['el']+'@'+str(h['tmax'])+'C' for h in data['hot_spots']) or 'none'}. "
            f"Empty areas: {', '.join(f'({r['x']},{r['y']}) {r['width']}x{r['height']}' for r in data['empty_rects'][:4]) or 'none'}.")
    if not args.get("include_grid", False):
        data.pop("grid16", None)
    return {"ok": True, "tool": "world_state", "summary": text, **data}


# ---------------------------------------------------------------------------
# attempts log + curriculum
# ---------------------------------------------------------------------------

def _load_attempts() -> list[dict[str, Any]]:
    if not ATTEMPTS.is_file():
        return []
    out = []
    for line in ATTEMPTS.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def _decomposed_score(raw: Any) -> dict[str, Any] | None:
    """Normalize the optional `score` argument into a small verifiable-reward
    vector (research round 3 item 3: VeriGate arXiv 2605.30451 -- a single
    pass|fail|partial bit produces degenerate all-same-score GRPO groups;
    Unsloth's GRPO guide independently recommends "a list of smaller
    verifiable rewards, not one all-consuming reward"). `verdict` remains the
    single enum every existing reader (`next_task`) keys off of; this is a
    strictly additive breakdown alongside it, None when not supplied.
    """
    if not isinstance(raw, dict):
        return None
    return {
        "compiles": bool(raw["compiles"]) if "compiles" in raw else None,
        "lint_critical": int(raw["lint_critical"]) if isinstance(raw.get("lint_critical"), (int, float)) and not isinstance(raw.get("lint_critical"), bool) else None,
        "lint_total": int(raw["lint_total"]) if isinstance(raw.get("lint_total"), (int, float)) and not isinstance(raw.get("lint_total"), bool) else None,
        "verify_pass": bool(raw["verify_pass"]) if "verify_pass" in raw else None,
    }


def _opt_number(raw: Any, cast: Callable[[Any], Any]) -> Any:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    try:
        return cast(raw)
    except (TypeError, ValueError):
        return None


def record_attempt(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    goal = args.get("goal")
    verdict = args.get("verdict")
    if not isinstance(goal, str) or not goal.strip():
        return {"ok": False, "tool": "record_attempt", "errors": ["goal must be a non-empty string"]}
    if verdict not in ("pass", "fail", "partial"):
        return {"ok": False, "tool": "record_attempt", "errors": ["verdict must be pass|fail|partial"]}
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "goal": goal.strip(),
        "practice": args.get("practice"),
        "level": args.get("level"),
        "model": args.get("model"),
        "verdict": verdict,
        "evidence": str(args.get("evidence", ""))[:800],
        "errors": args.get("errors") if isinstance(args.get("errors"), list) else [],
        "blueprint": args.get("blueprint") if isinstance(args.get("blueprint"), dict) else None,
        # round 3 item 3: decomposed reward + sampling metadata, so multiple
        # candidates for the same goal can later be grouped into GRPO-style
        # groups or RS-DPO-style pairs. All optional/None when not supplied,
        # so every existing caller keeps working unchanged.
        "score": _decomposed_score(args.get("score")),
        "temperature": _opt_number(args.get("temperature"), float),
        "round_no": _opt_number(args.get("round_no"), int),
        "resample_no": _opt_number(args.get("resample_no"), int),
    }
    ATTEMPTS.parent.mkdir(parents=True, exist_ok=True)
    with ATTEMPTS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    return {"ok": True, "tool": "record_attempt", "path": str(ATTEMPTS), "total": len(_load_attempts())}


def next_task(arguments: dict[str, Any]) -> dict[str, Any]:
    """Voyager-style curriculum, deterministic.

    Rules: practices are attempted in (level, name) order.  A practice is
    'passed' when its latest attempt is pass.  If the latest attempt at the
    current practice failed, return its steps as sub-tasks (decomposition) and
    the errors from that attempt; after `max_retries` consecutive fails, skip
    it and flag it for a human.  Optional `topic` restricts the curriculum.
    """
    args = arguments or {}
    try:
        pb = json.loads(PLAYBOOK.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {"ok": False, "tool": "next_task", "error": f"playbook unreadable: {exc}"}
    practices = sorted(pb.get("practices", []), key=lambda p: (int(p.get("level", 0)), p.get("name", "")))
    if args.get("topic"):
        practices = [p for p in practices if p.get("topic") == args["topic"]]
    if args.get("max_level") is not None:
        practices = [p for p in practices if int(p.get("level", 0)) <= int(args["max_level"])]
    max_retries = int(args.get("max_retries", 3))
    attempts = _load_attempts()
    by_practice: dict[str, list[dict[str, Any]]] = {}
    for a in attempts:
        if a.get("practice"):
            by_practice.setdefault(a["practice"], []).append(a)
    progress = []
    chosen = None
    for p in practices:
        hist = by_practice.get(p["name"], [])
        latest = hist[-1] if hist else None
        fails = 0
        for a in reversed(hist):
            if a.get("verdict") == "pass":
                break
            fails += 1
        state = "passed" if latest and latest.get("verdict") == "pass" else ("stuck" if fails >= max_retries else ("failing" if fails else "untried"))
        progress.append({"name": p["name"], "level": p["level"], "state": state, "attempts": len(hist)})
        if chosen is None and state in ("untried", "failing"):
            chosen = (p, latest, fails)
    if chosen is None:
        return {"ok": True, "tool": "next_task", "done": True, "message": "every practice in scope is passed or stuck; raise max_level or review stuck ones", "progress": progress}
    p, latest, fails = chosen
    task: dict[str, Any] = {
        "practice": p["name"], "level": p["level"], "topic": p["topic"], "goal": p["goal"],
        "status_tag": p.get("status"), "verify": p["verify"], "modules": p.get("modules", []),
        "attempt_number": fails + 1,
    }
    if latest and latest.get("verdict") != "pass":
        task["mode"] = "retry_decomposed"
        task["previous_errors"] = latest.get("errors", [])[:8]
        task["previous_evidence"] = latest.get("evidence")
        task["sub_tasks"] = [
            {"step": i + 1, **({"blueprint": s["blueprint"]} if "blueprint" in s else {"do": s["do"]})}
            for i, s in enumerate(p["steps"])
        ]
        task["instruction"] = ("Do ONE sub-task at a time: build it, run the verify for that sub-task, and only then continue. "
                               "Fix the previous_errors first.")
    else:
        task["mode"] = "fresh"
        task["steps"] = p["steps"]
        task["instruction"] = "Build the practice as one blueprint (dry_run first), then run its verify and record_attempt with the evidence."
    task["pitfalls"] = p.get("pitfalls", [])
    return {"ok": True, "tool": "next_task", "task": task, "progress": progress}


# ---------------------------------------------------------------------------
# module_search / module_retrieve -- retrieval-shortlisted module list
# (research round 3 item 2, unblocked by item 1: Ollama already serves
# embedding models over the same HTTP API this project already calls for
# chat, so there is no new dependency). Falls back to a pure-stdlib TF-IDF
# cosine ranker when Ollama/the requested embedding model is unreachable --
# this fallback path is what makes the whole thing offline-testable.
# ---------------------------------------------------------------------------

DEFAULT_EMBED_MODEL = "nomic-embed-text"
_TOKEN_RE = re.compile(r"[a-z0-9_]+")


def _tokenize(text: str) -> list[str]:
    return _TOKEN_RE.findall(text.lower())


def _module_corpus() -> dict[str, str]:
    """name -> a short text blob (why/description/param names) for every
    builtin and knowledge/modules/*.json registry module -- the thing both
    the embedding call and the TF-IDF fallback rank against.
    """
    from powder_ext import blueprint_tools as bt
    corpus: dict[str, str] = {}
    for name, info in bt.MODULES.items():
        params = " ".join(str(k) for k in (info.get("params") or {}).keys())
        corpus[name] = f"{name} {info.get('why', '')} {params}"
    for name, mdef in bt._json_module_registry().items():
        params = " ".join(str(k) for k in (mdef.get("params") or {}).keys())
        why = mdef.get("why") or mdef.get("description") or ""
        corpus[name] = f"{name} {why} {mdef.get('description', '')} {params}"
    return corpus


def _tfidf_rank(query: str, corpus: dict[str, str], k: int) -> list[tuple[str, float]]:
    """Pure-stdlib TF-IDF + cosine similarity ranking; deterministic, no deps."""
    doc_tokens = {name: _tokenize(text) for name, text in corpus.items()}
    n_docs = len(doc_tokens) or 1
    doc_freq: dict[str, int] = {}
    for toks in doc_tokens.values():
        for t in set(toks):
            doc_freq[t] = doc_freq.get(t, 0) + 1

    def idf(term: str) -> float:
        return math.log((n_docs + 1) / (doc_freq.get(term, 0) + 1)) + 1.0

    q_tf: dict[str, int] = {}
    for t in _tokenize(query):
        q_tf[t] = q_tf.get(t, 0) + 1
    q_vec = {t: tf * idf(t) for t, tf in q_tf.items()}
    q_norm = math.sqrt(sum(w * w for w in q_vec.values())) or 1.0

    scored: list[tuple[str, float]] = []
    for name, toks in doc_tokens.items():
        d_tf: dict[str, int] = {}
        for t in toks:
            d_tf[t] = d_tf.get(t, 0) + 1
        dot = 0.0
        d_sq = 0.0
        for t, tf in d_tf.items():
            w = tf * idf(t)
            d_sq += w * w
            if t in q_vec:
                dot += w * q_vec[t]
        d_norm = math.sqrt(d_sq) or 1.0
        scored.append((name, dot / (q_norm * d_norm) if dot else 0.0))
    scored.sort(key=lambda pair: (-pair[1], pair[0]))
    return scored[:max(k, 0)] if k else scored


def _ollama_embed(endpoint: str, model: str, text: str, timeout: float = 3.0) -> list[float] | None:
    """POST {endpoint}/api/embeddings; None (never raises) on any failure --
    unreachable Ollama, wrong model name, bad response shape, timeout.
    """
    body = json.dumps({"model": model, "prompt": text}).encode("utf-8")
    req = urllib.request.Request(
        endpoint.rstrip("/") + "/api/embeddings", data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            data = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None
    emb = data.get("embedding") if isinstance(data, dict) else None
    if isinstance(emb, list) and emb and all(isinstance(v, (int, float)) for v in emb):
        return [float(v) for v in emb]
    return None


def _cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


_EMBED_CACHE: dict[tuple[str, str], list[float]] = {}


def _embed_rank(query: str, corpus: dict[str, str], k: int, endpoint: str, model: str) -> list[tuple[str, float]] | None:
    """None means "embeddings unavailable, caller should fall back" -- never raises."""
    q_vec = _ollama_embed(endpoint, model, query)
    if q_vec is None:
        return None
    scored: list[tuple[str, float]] = []
    for name, text in corpus.items():
        cache_key = (model, text)
        vec = _EMBED_CACHE.get(cache_key)
        if vec is None:
            vec = _ollama_embed(endpoint, model, text)
            if vec is None:
                return None  # embedding service died partway through; fall back entirely
            _EMBED_CACHE[cache_key] = vec
        scored.append((name, _cosine(q_vec, vec)))
    scored.sort(key=lambda pair: (-pair[1], pair[0]))
    return scored[:k]


def module_retrieve(
    query: str,
    k: int = 12,
    explicit: list[str] | None = None,
    endpoint: str = "http://localhost:11434",
    model: str = DEFAULT_EMBED_MODEL,
) -> dict[str, Any]:
    """Rank builtin+registry modules by relevance to `query`; always keep
    `explicit` names (e.g. modules the request names by exact word) regardless
    of rank. Tries Ollama embeddings first, falls back to TF-IDF -- see
    `_embed_rank`/`_tfidf_rank`. Never raises.
    """
    from powder_ext import blueprint_tools as bt
    corpus = _module_corpus()
    k = max(1, int(k or 1))
    explicit_names = [e for e in (explicit or []) if isinstance(e, str) and e in corpus]
    method = "tfidf"
    ranked: list[tuple[str, float]] | None = None
    query_text = query or ""
    if query_text.strip():
        ranked = _embed_rank(query_text, corpus, k, endpoint, model)
        if ranked is not None:
            method = "embeddings"
    if ranked is None:
        ranked = _tfidf_rank(query_text, corpus, k)
    ordered: list[str] = list(explicit_names)
    for name, _score in ranked:
        if name not in ordered:
            ordered.append(name)
    scores = dict(ranked)
    ordered = ordered[:max(k, len(explicit_names))]
    modules: list[dict[str, Any]] = []
    for name in ordered:
        info = bt.MODULES.get(name)
        if info is not None:
            modules.append({"name": name, "params": info["params"], "why": info["why"], "source": "builtin", "score": scores.get(name), "explicit": name in explicit_names})
        else:
            mdef = bt._json_module_registry().get(name, {})
            modules.append({
                "name": name, "params": mdef.get("params", {}), "why": mdef.get("why") or mdef.get("description", ""),
                "source": "registry", "score": scores.get(name), "explicit": name in explicit_names,
            })
    return {
        "ok": True, "tool": "module_retrieve", "query": query_text, "k": k, "method": method,
        "total_modules": len(corpus), "count": len(modules), "modules": modules,
    }


def module_search(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    query = str(args.get("query") or "").strip()
    if not query:
        return {"ok": False, "tool": "module_search", "errors": ["query must be a non-empty string"]}
    explicit = args.get("explicit")
    return module_retrieve(
        query,
        k=int(args.get("k", 12) or 12),
        explicit=explicit if isinstance(explicit, list) else None,
        endpoint=str(args.get("endpoint") or "http://localhost:11434"),
        model=str(args.get("model") or DEFAULT_EMBED_MODEL),
    )


# ---------------------------------------------------------------------------
# gate_modules -- deterministic precondition/executability filter (research
# round 3 item 5, modeled on arXiv 2608.01050's Wix Helpmate pipeline: a
# semantic-match shortlist followed by a deterministic executability gate
# against live state removed 59.4% of remaining candidates and the model
# would otherwise have picked a blocked skill 7.8% of the time with no gate).
# Only *registry* (JSON) modules can reference a not-yet-defined custom
# element; builtin modules are Python functions over the stock catalog only
# and are always considered available.
# ---------------------------------------------------------------------------

_ELEMENT_REF_KEYS = ("box", "line", "circle", "wall", "element", "ctype")
_ELEMENT_ID_RE = re.compile(r"^[A-Z][A-Z0-9]{1,7}$")


def _collect_element_refs(node: Any, out: set[str]) -> None:
    if isinstance(node, dict):
        for key, val in node.items():
            if key in _ELEMENT_REF_KEYS and isinstance(val, str):
                out.add(val.strip().upper())
            else:
                _collect_element_refs(val, out)
    elif isinstance(node, list):
        for item in node:
            _collect_element_refs(item, out)


def missing_elements_for_module(name: str) -> list[str]:
    """Element identifiers a registry module references that are neither in
    the stock catalog/wall table nor currently a live custom element. Empty
    for builtin modules (always available) and unknown names.
    """
    from powder_ext import blueprint_tools as bt
    module_def = bt._json_module_registry().get(name)
    if module_def is None:
        return []
    refs: set[str] = set()
    _collect_element_refs(module_def.get("parts"), refs)
    cats = bt._catalogs()
    live_custom = bt._custom_elements()
    missing = []
    for ref in sorted(refs):
        if not ref or ref == "NONE" or not _ELEMENT_ID_RE.match(ref):
            continue
        if ref in cats.get("elements", set()) or ref in cats.get("walls", set()):
            continue
        if ref in live_custom:
            continue
        missing.append(ref)
    return missing


def gate_modules(names: list[str]) -> dict[str, Any]:
    """Split `names` into available vs. unavailable-right-now (missing custom
    elements), per `missing_elements_for_module`. Never raises -- if the live
    custom-element list is unreachable, `_custom_elements()` returns an empty
    set and registry modules needing a not-yet-native element are (correctly,
    conservatively) reported unavailable.
    """
    available: list[str] = []
    unavailable: dict[str, list[str]] = {}
    for name in names:
        missing = missing_elements_for_module(name)
        if missing:
            unavailable[name] = missing
        else:
            available.append(name)
    return {"available": available, "unavailable": unavailable}


# ---------------------------------------------------------------------------
# grammar for constrained decoding
# ---------------------------------------------------------------------------

BLUEPRINT_GBNF = r'''
root      ::= ws "{" ws "\"name\"" ws ":" ws string ws "," ws "\"origin\"" ws ":" ws pair ws ("," ws "\"clear_before\"" ws ":" ws bool ws)? "," ws "\"parts\"" ws ":" ws parts ws ("," ws "\"then\"" ws ":" ws thens ws)? "}" ws
parts     ::= "[" ws (part (ws "," ws part)*)? ws "]"
part      ::= box | line | circle | wall | erase | set | module | repeat | group
idopt     ::= ("\"id\"" ws ":" ws string ws "," ws)?
box       ::= "{" ws idopt "\"box\"" ws ":" ws string ws "," ws "\"at\"" ws ":" ws coord ws "," ws "\"size\"" ws ":" ws pair ws ("," ws "\"hollow\"" ws ":" ws int ws)? ("," ws "\"replace\"" ws ":" ws bool ws)? ("," ws "\"props\"" ws ":" ws props ws)? "}"
line      ::= "{" ws idopt "\"line\"" ws ":" ws string ws "," ws "\"from\"" ws ":" ws coord ws "," ws "\"to\"" ws ":" ws coord ws "}"
circle    ::= "{" ws idopt "\"circle\"" ws ":" ws string ws "," ws "\"at\"" ws ":" ws coord ws "," ws "\"r\"" ws ":" ws int ws "}"
wall      ::= "{" ws idopt "\"wall\"" ws ":" ws string ws "," ws "\"at\"" ws ":" ws coord ws "," ws "\"size\"" ws ":" ws pair ws "}"
erase     ::= "{" ws "\"erase\"" ws ":" ws "true" ws "," ws "\"at\"" ws ":" ws coord ws "," ws "\"size\"" ws ":" ws pair ws "}"
set       ::= "{" ws "\"set\"" ws ":" ws props ws "," ws "\"at\"" ws ":" ws coord ws "," ws "\"size\"" ws ":" ws pair ws ("," ws "\"element\"" ws ":" ws string ws)? "}"
module    ::= "{" ws idopt "\"module\"" ws ":" ws string ws "," ws "\"at\"" ws ":" ws coord ws ("," ws "\"params\"" ws ":" ws params ws)? "}"
repeat    ::= "{" ws idopt "\"repeat\"" ws ":" ws int ws "," ws "\"at\"" ws ":" ws coord ws "," ws "\"step\"" ws ":" ws pair ws "," ws "\"part\"" ws ":" ws part ws "}"
group     ::= "{" ws idopt "\"group\"" ws ":" ws parts ws "," ws "\"at\"" ws ":" ws coord ws "}"
thens     ::= "[" ws ("{" ws "\"step\"" ws ":" ws int ws "}" (ws "," ws "{" ws "\"step\"" ws ":" ws int ws "}")*)? ws "]"
props     ::= "{" ws (prop (ws "," ws prop)*)? ws "}"
prop      ::= ("\"channel\"" | "\"tmp\"" | "\"tmp2\"" | "\"life\"") ws ":" ws int | "\"ctype\"" ws ":" ws string | ("\"temp\"" | "\"temp_c\"") ws ":" ws number
params    ::= "{" ws (param (ws "," ws param)*)? ws "}"
param     ::= string ws ":" ws (number | string | bool)
coord     ::= "[" ws cval ws "," ws cval ws "]"
cval      ::= int | anchor
anchor    ::= "\"" [a-zA-Z_][a-zA-Z0-9_]* "." ("left" | "right" | "top" | "bottom" | "cx" | "cy") ([+-] [0-9]+)? "\""
pair      ::= "[" ws int ws "," ws int ws "]"
int       ::= "-"? [0-9]+
number    ::= "-"? [0-9]+ ("." [0-9]+)?
bool      ::= "true" | "false"
string    ::= "\"" [^"\\]* "\""
ws        ::= [ \t\n]*
'''

BLUEPRINT_JSON_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "name": {"type": "string"},
        "origin": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
        "clear_before": {"type": "boolean"},
        "parts": {"type": "array", "items": {"type": "object"}},
        "then": {"type": "array", "items": {"type": "object", "properties": {"step": {"type": "integer"}}, "required": ["step"]}},
    },
    "required": ["name", "origin", "parts"],
}


def blueprint_grammar(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    fmt = args.get("format", "both")
    out: dict[str, Any] = {"ok": True, "tool": "blueprint_grammar", "version": 1}
    if fmt in ("gbnf", "both"):
        out["gbnf"] = BLUEPRINT_GBNF.strip() + "\n"
    if fmt in ("json_schema", "both"):
        out["json_schema"] = BLUEPRINT_JSON_SCHEMA
    out["usage"] = {
        "ollama": "POST /api/chat with \"format\": <json_schema> (Ollama >= 0.5 structured outputs) or /api/generate with the same",
        "llama.cpp": "POST /completion with \"grammar\": <gbnf>, or /v1/chat/completions with response_format json_schema",
        "note": "grammar guarantees shape, not semantics: still run blueprint_build dry_run and feed errors back",
    }
    return out


# ---------------------------------------------------------------------------
# registry
# ---------------------------------------------------------------------------

_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "world_state": world_state,
    "next_task": next_task,
    "record_attempt": record_attempt,
    "blueprint_grammar": blueprint_grammar,
    "module_search": module_search,
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
