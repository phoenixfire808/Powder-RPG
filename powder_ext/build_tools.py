"""Build-anything layer: canvas features, functional tests, staged pipelines.

* ``find_features``  -- cluster the live canvas into named objects (connected
  components on a coarse grid) with bbox, composition, centroid and hollow
  interior, so plans can anchor to things a human drew by hand
  (``"at": ["ring1.right+3", "ring1.cy"]``).
* ``run_test``       -- functional acceptance test: optional WIFI channel pulses
  at given frames, exact frame stepping (microstep: unpause+pause = 1 frame,
  verified live), then assertions over regions (element counts, temps,
  pressure) and a per-frame trace of watched cells.  Never draws.
* ``build_stage``    -- one pipeline stage: stamp, blueprint_build (dry then
  real), lint, run_test, record_attempt; stops and reports on the first failed
  gate so the planner can fix that stage only.

Plans are plain JSON (see BLUEPRINT_SPEC.md 'Pipelines'): a list of stages,
each {name, blueprint, tests, features_required?}.  The planner (a big model or
a human) writes the plan; this module makes the verification non-optional.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any, Callable

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from powder_bridge.client import PowderAPIError, PowderConnectionError, PowderClient  # noqa: E402

from powder_ext.repo_paths import BUILD_DIR, KNOWLEDGE_DIR

KNOW = KNOWLEDGE_DIR
_client: PowderClient | None = None


def _get_client() -> PowderClient:
    global _client
    if _client is None:
        _client = PowderClient()
    return _client


def _lua(code: str) -> Any:
    return _get_client().execute_lua(code).get("result")


# ---------------------------------------------------------------------------
# find_features
# ---------------------------------------------------------------------------

_FEATURES_LUA = r'''
local CELL = %d
local W, H = math.ceil(612/CELL), math.ceil(384/CELL)
local occ, comp = {}, {}
for i in sim.parts() do
  local x,y = sim.partPosition(i); local k = math.floor(y/CELL)*W + math.floor(x/CELL)
  local nm = elem.property(sim.partProperty(i,"type"),"Name")
  local c = occ[k]; if not c then c = {n=0, el={}, tmax=-1e9}; occ[k] = c end
  c.n = c.n + 1; c.el[nm] = (c.el[nm] or 0) + 1
  local t = sim.partProperty(i,"temp"); if t > c.tmax then c.tmax = t end
end
-- connected components (4-neighbour) over occupied cells
local label = {}; local nlab = 0; local comps = {}
for k,_ in pairs(occ) do
  if not label[k] then
    nlab = nlab + 1; local stack = {k}; label[k] = nlab
    local cc = {cells = {}, n = 0, el = {}, x1 = 1e9, y1 = 1e9, x2 = -1, y2 = -1, tmax = -1e9}
    while #stack > 0 do
      local cur = table.remove(stack); local cx, cy = cur %% W, math.floor(cur / W)
      local c = occ[cur]; cc.n = cc.n + c.n
      for e,v in pairs(c.el) do cc.el[e] = (cc.el[e] or 0) + v end
      if c.tmax > cc.tmax then cc.tmax = c.tmax end
      if cx < cc.x1 then cc.x1 = cx end; if cy < cc.y1 then cc.y1 = cy end
      if cx > cc.x2 then cc.x2 = cx end; if cy > cc.y2 then cc.y2 = cy end
      cc.cells[#cc.cells+1] = cur
      for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
        local nx, ny = cx + d[1], cy + d[2]
        if nx >= 0 and nx < W and ny >= 0 and ny < H then
          local nk = ny*W + nx
          if occ[nk] and not label[nk] then label[nk] = nlab; stack[#stack+1] = nk end
        end
      end
    end
    comps[#comps+1] = cc
  end
end
table.sort(comps, function(a,b) return a.n > b.n end)
local out = {}
for i = 1, math.min(#comps, 24) do
  local cc = comps[i]
  -- exact pixel bbox inside the coarse bbox
  local px1, py1, px2, py2 = 1e9, 1e9, -1, -1
  for j in sim.parts() do local x,y = sim.partPosition(j)
    local cx, cy = math.floor(x/CELL), math.floor(y/CELL)
    if cx >= cc.x1 and cx <= cc.x2 and cy >= cc.y1 and cy <= cc.y2 and label[cy*W+cx] == label[cc.cells[1]] then
      if x < px1 then px1 = x end; if y < py1 then py1 = y end; if x > px2 then px2 = x end; if y > py2 then py2 = y end end end
  local els = {}
  for e,v in pairs(cc.el) do els[#els+1] = {e, v} end
  table.sort(els, function(a,b) return a[2] > b[2] end)
  local es = {}
  for j = 1, math.min(#els, 6) do es[#es+1] = string.format('"%%s":%%d', els[j][1], els[j][2]) end
  local area = (px2-px1+1)*(py2-py1+1)
  out[#out+1] = string.format('{"n":%%d,"box":[%%d,%%d,%%d,%%d],"fill":%%.2f,"tmax":%%d,"elements":{%%s},"cells":%%d}',
    cc.n, px1, py1, px2, py2, cc.n/math.max(area,1), math.floor(cc.tmax-273.15+0.5), table.concat(es,","), #cc.cells)
end
return "[" .. table.concat(out, ",") .. "]"
'''


_SNAPSHOT_LUA = r'''
local doCounts, doDetail = %s, %s
local cursor, limit, maxScan = %d, %d, %d
local hasRegion = %s
local rx1, ry1, rx2, ry2 = %d, %d, %d, %d
local typeFilter = %s
local out = {}
if doCounts then
  local seen, parts = {}, {}
  for k, v in pairs(elements) do
    if type(v) == "number" and v >= 0 and v <= 4095 and not seen[v] then
      seen[v] = true
      local ok, n = pcall(sim.elementCount, v)
      if ok and n and n > 0 then
        local nameOk, nm = pcall(elem.property, v, "Name")
        parts[#parts + 1] = v .. "," .. n .. "," .. (nameOk and tostring(nm) or "?")
      end
    end
  end
  out[1] = "TOTALS:" .. sim.partCount() .. "|" .. table.concat(parts, ";")
else
  out[1] = "TOTALS:" .. sim.partCount() .. "|"
end
if doDetail then
  local xres, yres = sim.XRES, sim.YRES
  local slotBound = xres * yres
  local rows = {}
  local scanned, matched, returned = 0, 0, 0
  local nextCursor = cursor
  while nextCursor < slotBound and scanned < maxScan do
    local id = nextCursor
    scanned = scanned + 1
    nextCursor = id + 1
    if sim.partExists(id) then
      local t = sim.partProperty(id, "type")
      if (typeFilter == nil or t == typeFilter) then
        local x, y = sim.partPosition(id)
        if (not hasRegion) or (x >= rx1 and x <= rx2 and y >= ry1 and y <= ry2) then
          matched = matched + 1
          if returned < limit then
            local temp = sim.partProperty(id, "temp")
            local ctype = sim.partProperty(id, "ctype") or 0
            local tmp = sim.partProperty(id, "tmp") or 0
            local life = sim.partProperty(id, "life") or 0
            rows[#rows + 1] = id .. "," .. t .. "," .. x .. "," .. y .. "," ..
              string.format("%%.1f", temp) .. "," .. ctype .. "," .. tmp .. "," .. life
            returned = returned + 1
            if returned >= limit then break end
          end
        end
      end
    end
  end
  local done = (nextCursor >= slotBound) and 1 or 0
  out[2] = "ROWS:" .. cursor .. "," .. nextCursor .. "," .. scanned .. "," .. matched .. "," .. returned .. "," .. done
  out[3] = table.concat(rows, "\n")
end
return table.concat(out, "\n")
'''

_SNAPSHOT_MAX_LIMIT = 256
_SNAPSHOT_MAX_SCAN = 20000


def snapshot_fast(arguments: dict[str, Any]) -> dict[str, Any]:
    """{region?:{x1,y1,x2,y2}, element?:str, cursor?:int(default 0), limit?:int(<=256, default 128),
        max_scan?:int(<=20000, default 4096), fields?:["detail","counts"] (default both; ["counts"]
        alone skips the per-particle scan entirely)}

    One execute_lua round trip returns a compact delimited particle dump
    (id,type,x,y,temp,ctype,tmp,life per row), paginated with the same raw-slot
    cursor/limit/max_scan contract as the bridge's partsInventory action, plus a
    global per-element count summary read from sim.elementCount/sim.partCount --
    O(distinct element types), not a full sim.parts() scan -- for the headline
    totals `world_state`/`run_test` pay a full scan for today.
    """
    args = arguments or {}
    fields = args.get("fields")
    if fields is None:
        fields = ["detail", "counts"]
    elif isinstance(fields, str):
        fields = [fields]
    want_counts = "counts" in fields
    want_detail = "detail" in fields
    if not want_counts and not want_detail:
        want_detail = True
    cursor = max(0, int(args.get("cursor", 0)))
    limit = max(1, min(int(args.get("limit", 128)), _SNAPSHOT_MAX_LIMIT))
    max_scan = max(1, min(int(args.get("max_scan", 4096)), _SNAPSHOT_MAX_SCAN))
    region = args.get("region")
    has_region = isinstance(region, dict) and bool(region)
    rx1 = int(region["x1"]) if has_region else 0
    ry1 = int(region["y1"]) if has_region else 0
    rx2 = int(region["x2"]) if has_region else 611
    ry2 = int(region["y2"]) if has_region else 383
    element = args.get("element")
    if element:
        ename = str(element).upper().replace('"', "")
        type_filter_expr = "(elements[%s] or elements[%s])" % (
            json.dumps(ename), json.dumps("DEFAULT_PT_" + ename),
        )
    else:
        type_filter_expr = "nil"
    code = _SNAPSHOT_LUA % (
        "true" if want_counts else "false",
        "true" if want_detail else "false",
        cursor, limit, max_scan,
        "true" if has_region else "false",
        rx1, ry1, rx2, ry2,
        type_filter_expr,
    )
    t0 = time.perf_counter()
    try:
        raw = str(_lua(code) or "")
    except (PowderAPIError, PowderConnectionError) as exc:
        return {"ok": False, "tool": "snapshot_fast", "error": f"{type(exc).__name__}: {exc}"}
    elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 2)
    lines = raw.split("\n")
    if not lines or not lines[0].startswith("TOTALS:"):
        return {"ok": False, "tool": "snapshot_fast", "error": "malformed response (no TOTALS line)", "raw_head": raw[:200]}
    part_count_str, _, elems_str = lines[0][len("TOTALS:"):].partition("|")
    try:
        total_part_count = int(float(part_count_str))
    except ValueError:
        total_part_count = 0
    element_summary: list[dict[str, Any]] = []
    if elems_str:
        for chunk in elems_str.split(";"):
            if not chunk:
                continue
            pieces = chunk.split(",", 2)
            if len(pieces) != 3:
                continue
            eid, cnt, nm = pieces
            try:
                element_summary.append({"id": int(eid), "name": nm, "count": int(cnt)})
            except ValueError:
                continue
    element_summary.sort(key=lambda e: -e["count"])
    result: dict[str, Any] = {
        "ok": True, "tool": "snapshot_fast",
        "total_particles": total_part_count,
        "elapsed_ms": elapsed_ms,
    }
    if want_counts:
        result["elements"] = element_summary
    if want_detail:
        rows: list[dict[str, Any]] = []
        meta = {"cursor": cursor, "cursor_next": cursor, "scanned": 0, "matched": 0, "returned": 0, "done": True}
        if len(lines) > 1 and lines[1].startswith("ROWS:"):
            meta_parts = lines[1][len("ROWS:"):].split(",")
            if len(meta_parts) == 6:
                c0, cn, sc, mt, rt, dn = meta_parts
                meta = {
                    "cursor": int(c0), "cursor_next": int(cn), "scanned": int(sc),
                    "matched": int(mt), "returned": int(rt), "done": dn == "1",
                }
            row_lines = lines[2:2 + meta["returned"]] if len(lines) > 2 else []
            for line in row_lines:
                if not line:
                    continue
                cols = line.split(",")
                if len(cols) != 8:
                    continue
                pid, ptype, x, y, temp, ctype, tmp, life = cols
                try:
                    rows.append({
                        "id": int(pid), "type": int(ptype), "x": int(x), "y": int(y),
                        "temp": float(temp), "ctype": int(float(ctype)), "tmp": int(float(tmp)),
                        "life": int(float(life)),
                    })
                except ValueError:
                    continue
        result.update(meta)
        result["rows"] = rows
    return result


def find_features(arguments: dict[str, Any]) -> dict[str, Any]:
    args = arguments or {}
    cell = int(args.get("cell", 4))
    try:
        comps = json.loads(str(_lua(_FEATURES_LUA % cell)))
    except (PowderAPIError, PowderConnectionError, json.JSONDecodeError) as exc:
        return {"ok": False, "tool": "find_features", "error": f"{type(exc).__name__}: {exc}"}
    feats = []
    counter: dict[str, int] = {}
    for c in comps:
        x1, y1, x2, y2 = c["box"]
        w, h = x2 - x1 + 1, y2 - y1 + 1
        main = max(c["elements"], key=c["elements"].get) if c["elements"] else "?"
        shape = "ring" if (c["fill"] < 0.6 and abs(w - h) <= max(4, 0.2 * max(w, h))) else ("box" if c["fill"] > 0.85 else ("shell" if c["fill"] < 0.6 else "blob"))
        base = main.lower()
        counter[base] = counter.get(base, 0) + 1
        fid = f"{base}{counter[base]}"
        feats.append({
            "id": fid, "shape": shape, "main": main, "elements": c["elements"], "particles": c["n"],
            "box": {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "width": w, "height": h},
            "anchors": {"left": x1, "right": x2, "top": y1, "bottom": y2, "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2},
            "fill": c["fill"], "tmax_c": c["tmax"],
            "describe": f"{fid}: {shape} of {main} ({c['n']} particles, {w}x{h} at ({x1},{y1}), fill {c['fill']:.0%}, hottest {c['tmax']} C)",
        })
    return {"ok": True, "tool": "find_features", "count": len(feats), "features": feats,
            "usage": "reference a feature in a blueprint as \"<id>.right+3\" via blueprint_build's `features` argument, or copy its anchors"}


# ---------------------------------------------------------------------------
# run_test
# ---------------------------------------------------------------------------

_COUNT_LUA = r'''
local x1,y1,x2,y2 = %d,%d,%d,%d
local want = %s
local n, tsum, tmax, lsum = 0, 0, -1e9, 0
for i in sim.parts() do local x,y = sim.partPosition(i)
  if x>=x1 and x<=x2 and y>=y1 and y<=y2 then
    local nm = elem.property(sim.partProperty(i,"type"),"Name")
    if want == nil or nm == want then n = n + 1; local t = sim.partProperty(i,"temp"); tsum = tsum + t; if t > tmax then tmax = t end; lsum = lsum + sim.partProperty(i,"life") end
  end end
local pmax, pmin = -1e9, 1e9
for cx = math.floor(x1/4), math.floor(x2/4) do for cy = math.floor(y1/4), math.floor(y2/4) do local p = sim.pressure(cx,cy); if p > pmax then pmax = p end; if p < pmin then pmin = p end end end
return string.format('{"count":%%d,"tavg_c":%%.1f,"tmax_c":%%.1f,"life_sum":%%d,"pmin":%%.1f,"pmax":%%.1f}', n, (n>0 and tsum/n-273.15 or 0), (n>0 and tmax-273.15 or 0), lsum, pmin, pmax)
'''


def _measure(region: dict[str, Any], element: str | None) -> dict[str, Any]:
    want = "nil" if not element else json.dumps(str(element).upper())
    return json.loads(str(_lua(_COUNT_LUA % (int(region["x1"]), int(region["y1"]), int(region["x2"]), int(region["y2"]), want))))


def _frame(n: int = 1) -> None:
    # exact stepping via the queued-frames counter (sim.frameRender), verified live 2026-08-25
    _get_client().step_sim(max(1, int(n)))


def _pulse(channel: int, frames: int, x: int, y: int) -> None:
    temp = 73.15 + 100.0 * (int(channel) - 1) + 50.0
    _lua(f'local w=sim.partCreate(-1,{x},{y},elem.DEFAULT_PT_WIFI) sim.partProperty(w,"temp",{temp}) '
         f'local p=sim.partCreate(-1,{x+1},{y},elem.DEFAULT_PT_PSCN) local b=sim.partCreate(-1,{x+2},{y},elem.DEFAULT_PT_BTRY) _G.PBX_TX={{w,p,b}}')
    _frame(max(1, int(frames)))
    _lua('for _,i in ipairs(_G.PBX_TX or {}) do sim.partKill(i) end _G.PBX_TX=nil')


_OPS: dict[str, Callable[[float, float], bool]] = {
    ">=": lambda a, b: a >= b, "<=": lambda a, b: a <= b, ">": lambda a, b: a > b, "<": lambda a, b: a < b,
    "==": lambda a, b: abs(a - b) < 1e-6, "!=": lambda a, b: abs(a - b) >= 1e-6,
}


def run_test(arguments: dict[str, Any]) -> dict[str, Any]:
    """{name?, frames, pulses?:[{channel, at_frame?, frames?}], watch?:[{name, region, element?}],
        assertions:[{name, region:{x1,y1,x2,y2}, element?, metric: count|tavg_c|tmax_c|life_sum|pmin|pmax|delta_count, op, value}],
        tx_at?: [x,y] (where the temporary WIFI transmitter is placed; must be empty), sample_every?: int,
        seed?: [a,b,c,d] (4-integer sim.randomSeed() state to replay exactly; implies capture_hash),
        capture_hash?: bool (capture sim.hash() before/after under the returned 'determinism' object)}"""
    args = arguments or {}
    frames = int(args.get("frames", 60))
    if frames < 0 or frames > 3000:
        return {"ok": False, "tool": "run_test", "error": "frames must be 0..3000"}
    pulses = sorted((dict(p) for p in args.get("pulses", []) or []), key=lambda p: int(p.get("at_frame", 0)))
    watch = args.get("watch", []) or []
    assertions = args.get("assertions", []) or []
    tx = args.get("tx_at", [600, 4])
    sample_every = max(1, int(args.get("sample_every", max(1, frames // 10 or 1))))
    seed_arg = args.get("seed")
    capture_hash = bool(args.get("capture_hash", False)) or seed_arg is not None
    if seed_arg is not None and not (isinstance(seed_arg, (list, tuple)) and len(seed_arg) == 4):
        return {"ok": False, "tool": "run_test", "error": "seed must be a 4-integer array from a prior run's determinism.seed"}
    try:
        was_paused = str(_lua("return tostring(tpt.set_pause())"))
        _lua("tpt.set_pause(1)")
        determinism: dict[str, Any] | None = None
        if capture_hash:
            _lua("sim.ensureDeterminism(true)")
            if seed_arg is not None:
                seed_ints = [int(v) for v in seed_arg]
                _lua("sim.randomSeed(%d,%d,%d,%d)" % tuple(seed_ints))
            else:
                got = str(_lua('local a,b,c,d = sim.randomSeed() return a..","..b..","..c..","..d'))
                seed_ints = [int(v) for v in got.split(",")]
            hash_before = int(str(_lua("return tostring(sim.hash())")))
            determinism = {"seed": seed_ints, "hash_before": hash_before}
        baseline = {a.get("name", f"a{i}"): _measure(a["region"], a.get("element")) for i, a in enumerate(assertions)}
        trace: list[dict[str, Any]] = []
        violations: dict[str, list[dict[str, Any]]] = {}
        f = 0
        pi = 0
        while f < frames or pi < len(pulses):
            if pi < len(pulses) and int(pulses[pi].get("at_frame", 0)) <= f:
                p = pulses[pi]; pi += 1
                _pulse(int(p["channel"]), int(p.get("frames", 4)), int(tx[0]), int(tx[1]))
                f += int(p.get("frames", 4))
                trace.append({"frame": f, "event": f"pulsed channel {p['channel']}"})
                continue
            step = min(sample_every, frames - f) if f < frames else 0
            if step <= 0:
                break
            _frame(step); f += step
            row: dict[str, Any] = {"frame": f}
            for w in watch:
                row[w.get("name", "w")] = _measure(w["region"], w.get("element"))
            # temporal assertions: evaluate 'always' assertions at every sample so transient violations are caught
            for i, a in enumerate(assertions):
                if a.get("when") == "always":
                    name = a.get("name", f"a{i}"); mm = _measure(a["region"], a.get("element"))
                    metric = a.get("metric", "count")
                    val = mm["count"] - baseline[name]["count"] if metric == "delta_count" else mm.get(metric)
                    op = _OPS.get(a.get("op", ">="))
                    if op and val is not None and not op(float(val), float(a["value"])):
                        violations.setdefault(name, []).append({"frame": f, "value": val})
            trace.append(row)
        if determinism is not None:
            determinism["hash_after"] = int(str(_lua("return tostring(sim.hash())")))
        results = []
        all_ok = True
        for i, a in enumerate(assertions):
            name = a.get("name", f"a{i}")
            m = _measure(a["region"], a.get("element"))
            metric = a.get("metric", "count")
            val = m["count"] - baseline[name]["count"] if metric == "delta_count" else m.get(metric)
            op = _OPS.get(a.get("op", ">="))
            passed = bool(op(float(val), float(a["value"]))) if op and val is not None else False
            if a.get("when") == "always" and violations.get(name):
                passed = False
            all_ok &= passed
            results.append({"name": name, "metric": metric, "value": val, "op": a.get("op", ">="), "expected": a["value"], "pass": passed, "baseline": baseline[name], "now": m, "violations": violations.get(name, [])[:10]})
        if was_paused == "0" and args.get("restore_pause", True):
            pass  # leave paused: safer; caller may unpause explicitly
        out: dict[str, Any] = {"ok": all_ok, "tool": "run_test", "name": args.get("name"), "frames_run": f, "assertions": results, "trace": trace[-40:], "left_paused": True}
        if determinism is not None:
            out["determinism"] = determinism
        return out
    except (PowderAPIError, PowderConnectionError) as exc:
        return {"ok": False, "tool": "run_test", "error": f"{type(exc).__name__}: {exc}"}


def replay_hash_check(arguments: dict[str, Any]) -> dict[str, Any]:
    """{run_test: <run_test arguments, MUST include "seed":[a,b,c,d] from a prior determinism capture>,
        expected_hash: int}

    Replays a run_test call with a previously recorded seed and checks whether
    sim.hash() after stepping matches expected_hash -- a strictly stronger
    regression signal than metric-threshold assertions alone (two different
    particle-level outcomes can share the same aggregate temperature average).
    The caller is responsible for restoring the same starting sim state (e.g.
    the checkpoint stamp build_stage records) before calling this: run_test
    only controls the RNG stream and frame stepping, not the particle layout
    the run starts from.
    """
    args = arguments or {}
    test_args = dict(args.get("run_test") or {})
    expected_hash = args.get("expected_hash")
    if expected_hash is None:
        return {"ok": False, "tool": "replay_hash_check", "error": "expected_hash is required"}
    seed = test_args.get("seed")
    if not (isinstance(seed, (list, tuple)) and len(seed) == 4):
        return {"ok": False, "tool": "replay_hash_check", "error": "run_test.seed must be the 4-integer seed from a prior determinism capture"}
    test_args["capture_hash"] = True
    result = run_test(test_args)
    determinism = result.get("determinism") or {}
    hash_after = determinism.get("hash_after")
    match = hash_after is not None and int(hash_after) == int(expected_hash)
    return {
        "ok": bool(result.get("ok")) and match,
        "tool": "replay_hash_check",
        "match": match,
        "hash_before": determinism.get("hash_before"),
        "hash_after": hash_after,
        "expected_hash": expected_hash,
        "run_test_result": result,
    }


# ---------------------------------------------------------------------------
# screenshot
# ---------------------------------------------------------------------------

try:
    from PIL import Image  # noqa: E402
    import numpy as np  # noqa: E402
    _HAVE_IMAGING = True
except Exception:  # noqa: BLE001
    _HAVE_IMAGING = False

# The live game's ddir (see scripts/lab_instance.py for a second, isolated
# instance with its own ddir/port); tpt.screenshot() writes into whatever
# directory is current at startup, which for Drew's session is this one.
SCREENSHOT_DDIR = BUILD_DIR
_SCREENSHOT_STATE = KNOW / "screenshot_labels.json"

# Real ren.displayMode/ren.colorMode bit values (ElementGraphics.h), not
# ren.useDisplayPreset -- its own source comment calls the preset-index remap
# for values 0-10 "legacy nonsense", so scripted callers set the bits directly.
_RENDER_MODES: dict[str, tuple[int, int]] = {
    "normal": (0, 0),
    "heat": (8, 1),       # DISPLAY_AIRH, COLOUR_HEAT
    "pressure": (2, 0),   # DISPLAY_AIRP
    "velocity": (4, 0),   # DISPLAY_AIRV
}


def _load_screenshot_state() -> dict[str, str]:
    try:
        return json.loads(_SCREENSHOT_STATE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_screenshot_state(state: dict[str, str]) -> None:
    _SCREENSHOT_STATE.parent.mkdir(parents=True, exist_ok=True)
    _SCREENSHOT_STATE.write_text(json.dumps(state), encoding="utf-8")


def screenshot(arguments: dict[str, Any]) -> dict[str, Any]:
    """{view?: normal|heat|pressure|velocity (default normal), crop?:{x1,y1,x2,y2}, label?:str}

    Captures one PNG via tpt.screenshot(0,0) in the chosen render view, using
    the real ren.displayMode/colorMode bit values (never ren.useDisplayPreset),
    restores the previous render mode, and reports a percent-changed-pixels
    diff against the previous screenshot sharing the same label (skipped if
    Pillow/numpy are unavailable, sizes differ, or there is no prior one).
    """
    args = arguments or {}
    view = str(args.get("view", "normal"))
    if view not in _RENDER_MODES:
        return {"ok": False, "tool": "screenshot", "error": f"unknown view {view!r}, expected one of {sorted(_RENDER_MODES)}"}
    label = str(args.get("label") or view)
    crop = args.get("crop")
    display_mode, color_mode = _RENDER_MODES[view]
    t0 = time.perf_counter()
    try:
        prev_raw = str(_lua('return tostring(ren.displayMode())..","..tostring(ren.colorMode())'))
        prev_display_s, prev_color_s = prev_raw.split(",")
        prev_display, prev_color = int(prev_display_s), int(prev_color_s)
        _lua(f"ren.displayMode({display_mode}); ren.colorMode({color_mode})")
        try:
            filename = str(_lua('return tostring(tpt.screenshot(0,0) or "")') or "")
        finally:
            _lua(f"ren.displayMode({prev_display}); ren.colorMode({prev_color})")
    except (PowderAPIError, PowderConnectionError) as exc:
        return {"ok": False, "tool": "screenshot", "error": f"{type(exc).__name__}: {exc}"}
    if not filename:
        return {"ok": False, "tool": "screenshot", "error": "tpt.screenshot returned no filename"}
    path = SCREENSHOT_DDIR / filename
    for _ in range(20):
        if path.is_file():
            break
        time.sleep(0.05)
    if not path.is_file():
        return {"ok": False, "tool": "screenshot", "error": f"screenshot file not found: {path}"}
    result: dict[str, Any] = {
        "ok": True, "tool": "screenshot", "view": view, "label": label,
        "path": str(path), "crop_path": None,
        "restored_mode": {"displayMode": prev_display, "colorMode": prev_color},
    }
    if crop and _HAVE_IMAGING:
        try:
            x1, y1, x2, y2 = int(crop["x1"]), int(crop["y1"]), int(crop["x2"]), int(crop["y2"])
            img = Image.open(path)
            cropped = img.crop((x1, y1, x2 + 1, y2 + 1))
            crop_path = path.with_name(path.stem + ".crop.png")
            cropped.save(crop_path)
            result["crop_path"] = str(crop_path)
        except Exception as exc:  # noqa: BLE001
            result["crop_error"] = f"{type(exc).__name__}: {exc}"
    elif crop and not _HAVE_IMAGING:
        result["crop_skipped"] = "Pillow not installed"
    state = _load_screenshot_state()
    prev_path_str = state.get(label)
    if not _HAVE_IMAGING:
        result["diff"] = {"skipped": "Pillow/numpy not installed"}
    elif not prev_path_str or not Path(prev_path_str).is_file():
        result["diff"] = {"skipped": "no previous screenshot for this label"}
    else:
        try:
            a = np.asarray(Image.open(prev_path_str).convert("RGB"), dtype=np.int16)
            b = np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)
            if a.shape != b.shape:
                result["diff"] = {"skipped": "previous screenshot has a different size", "prev_path": prev_path_str}
            else:
                changed = np.any(np.abs(a - b) > 8, axis=-1)
                result["diff"] = {"changed_pct": round(float(changed.mean() * 100.0), 3), "prev_path": prev_path_str}
        except Exception as exc:  # noqa: BLE001
            result["diff"] = {"skipped": f"{type(exc).__name__}: {exc}"}
    state[label] = str(path)
    _save_screenshot_state(state)
    result["elapsed_ms"] = round((time.perf_counter() - t0) * 1000.0, 2)
    return result


# ---------------------------------------------------------------------------
# build_stage
# ---------------------------------------------------------------------------

def build_stage(arguments: dict[str, Any]) -> dict[str, Any]:
    """{stage:{name, blueprint, tests:[run_test args...], require_lint_clean?:bool}, dry_run?:bool, record?:bool}"""
    from powder_ext import blueprint_tools as bt  # local import to avoid cycles
    from powder_ext import agent_tools as at
    args = arguments or {}
    stage = args.get("stage") or {}
    name = str(stage.get("name", "stage"))
    bp = stage.get("blueprint")
    if not isinstance(bp, dict):
        return {"ok": False, "tool": "build_stage", "error": "stage.blueprint must be an object"}
    report: dict[str, Any] = {"ok": False, "tool": "build_stage", "stage": name, "gates": []}
    # gate 1: compile + lint (dry)
    dry = bt.blueprint_build({"blueprint": bp, "dry_run": True})
    crit = [f for f in dry.get("lint", {}).get("findings", []) if f.get("severity") == "critical"]
    report["gates"].append({"gate": "compile", "pass": bool(dry.get("ok")), "errors": dry.get("errors", [])[:8]})
    report["gates"].append({"gate": "lint", "pass": not crit or not stage.get("require_lint_clean", True), "critical": [{"rule": f["rule"], "path": f["path"], "fix": f["fix"]} for f in crit[:8]]})
    if not dry.get("ok") or (crit and stage.get("require_lint_clean", True)):
        report["failed_gate"] = "compile" if not dry.get("ok") else "lint"
        return report
    if args.get("dry_run", False):
        report["ok"] = True; report["dry_run"] = True; report["bounds"] = dry.get("bounds"); return report
    # gate 2: checkpoint
    try:
        st = _get_client()._post({"action": "saveStamp", "x": 0, "y": 0, "width": 611, "height": 383})
        report["checkpoint_stamp"] = st.get("name")
    except (PowderAPIError, PowderConnectionError) as exc:
        report["gates"].append({"gate": "checkpoint", "pass": False, "error": str(exc)}); report["failed_gate"] = "checkpoint"; return report
    report["gates"].append({"gate": "checkpoint", "pass": True})
    # gate 3: build
    real = bt.blueprint_build({"blueprint": bp, "dry_run": False, "pause": True})
    report["gates"].append({"gate": "build", "pass": bool(real.get("ok")), "succeeded": real.get("succeeded"), "failed": real.get("failed"), "results": [r for r in real.get("results", []) if not r.get("ok")][:5]})
    if not real.get("ok"):
        report["failed_gate"] = "build"; return report
    # gate 4: tests
    tests_out = []
    tests_ok = True
    for t in stage.get("tests", []) or []:
        r = run_test(t)
        tests_out.append({"name": t.get("name"), "pass": bool(r.get("ok")), "assertions": r.get("assertions"), "error": r.get("error"), "frames_run": r.get("frames_run")})
        tests_ok &= bool(r.get("ok"))
    report["gates"].append({"gate": "tests", "pass": tests_ok, "tests": tests_out})
    report["ok"] = tests_ok
    if not tests_ok:
        report["failed_gate"] = "tests"
    if args.get("record", True):
        at.HANDLERS["record_attempt"]({"goal": f"stage:{name}", "verdict": "pass" if tests_ok else "fail",
                                       "evidence": json.dumps([{"t": t["name"], "pass": t["pass"]} for t in tests_out])[:800],
                                       "errors": [f"{t['name']}: {a['name']} {a['metric']}={a['value']} {a['op']} {a['expected']}" for t in tests_out for a in (t.get("assertions") or []) if not a.get("pass")][:16],
                                       "blueprint": bp})
    return report


def run_pipeline(arguments: dict[str, Any]) -> dict[str, Any]:
    """{plan:{name, stages:[stage...]}, start_at?:int, dry_run?:bool, stop_on_fail?:bool(default true)}
    Executes stages in order through build_stage. Before each stage, find_features is refreshed so the
    stage blueprint may anchor to objects built by earlier stages or drawn by hand (features_auto)."""
    from powder_ext import blueprint_tools as bt
    args = arguments or {}
    plan = args.get("plan") or {}
    stages = plan.get("stages") or []
    if not isinstance(stages, list) or not stages:
        return {"ok": False, "tool": "run_pipeline", "error": "plan.stages must be a non-empty array"}
    start = int(args.get("start_at", 0))
    out: list[dict[str, Any]] = []
    ok_all = True
    for idx, st in enumerate(stages):
        if idx < start:
            out.append({"index": idx, "stage": st.get("name"), "skipped": True}); continue
        ff = find_features({})
        feats = {f["id"]: f for f in ff.get("features", [])} if ff.get("ok") else {}
        bp = dict(st.get("blueprint") or {})
        # pre-resolve feature anchors by compiling with features (build_stage uses blueprint_build; pass them through)
        comp = bt.compile_blueprint(bp, feats)
        if not comp["ok"]:
            rep = {"ok": False, "tool": "build_stage", "stage": st.get("name"), "failed_gate": "compile", "gates": [{"gate": "compile", "pass": False, "errors": comp["errors"][:8]}], "features_seen": list(feats)[:12]}
        else:
            # bake resolved absolute primitives? simpler: hand build_stage the same blueprint + features via a wrapper
            st2 = dict(st); st2["blueprint"] = bp
            rep = _build_stage_with_features(st2, feats, dry_run=bool(args.get("dry_run", False)), record=bool(args.get("record", True)))
        rep["index"] = idx
        out.append(rep)
        if not rep.get("ok"):
            ok_all = False
            if args.get("stop_on_fail", True):
                break
    return {"ok": ok_all, "tool": "run_pipeline", "plan": plan.get("name"), "stages_run": len([r for r in out if not r.get("skipped")]), "results": out,
            "next_action": None if ok_all else "fix the first failed stage (see failed_gate + diagnostics) and re-run with start_at=<its index>"}


def _build_stage_with_features(stage: dict[str, Any], feats: dict[str, Any], dry_run: bool, record: bool) -> dict[str, Any]:
    """build_stage variant that passes feature anchors into blueprint_build."""
    from powder_ext import blueprint_tools as bt
    from powder_ext import agent_tools as at
    name = str(stage.get("name", "stage")); bp = stage["blueprint"]
    report: dict[str, Any] = {"ok": False, "tool": "build_stage", "stage": name, "gates": [], "features_used": [k for k in feats if k in json.dumps(bp)]}
    dry = bt.blueprint_build({"blueprint": bp, "dry_run": True, "features": feats})
    crit = [f for f in dry.get("lint", {}).get("findings", []) if f.get("severity") == "critical"]
    report["gates"].append({"gate": "compile", "pass": bool(dry.get("ok")), "errors": dry.get("errors", [])[:8]})
    report["gates"].append({"gate": "lint", "pass": not crit or not stage.get("require_lint_clean", True), "critical": [{"rule": f["rule"], "path": f["path"], "fix": f["fix"]} for f in crit[:8]]})
    if not dry.get("ok") or (crit and stage.get("require_lint_clean", True)):
        report["failed_gate"] = "compile" if not dry.get("ok") else "lint"; return report
    if dry_run:
        report["ok"] = True; report["dry_run"] = True; report["bounds"] = dry.get("bounds"); return report
    try:
        stmp = _get_client()._post({"action": "saveStamp", "x": 0, "y": 0, "width": 611, "height": 383}); report["checkpoint_stamp"] = stmp.get("name")
    except (PowderAPIError, PowderConnectionError) as exc:
        report["gates"].append({"gate": "checkpoint", "pass": False, "error": str(exc)}); report["failed_gate"] = "checkpoint"; return report
    report["gates"].append({"gate": "checkpoint", "pass": True})
    real = bt.blueprint_build({"blueprint": bp, "dry_run": False, "pause": True, "features": feats})
    report["gates"].append({"gate": "build", "pass": bool(real.get("ok")), "succeeded": real.get("succeeded"), "failed": real.get("failed"), "results": [r for r in real.get("results", []) if not r.get("ok")][:5]})
    if not real.get("ok"):
        report["failed_gate"] = "build"; return report
    tests_out = []; tests_ok = True
    for t in stage.get("tests", []) or []:
        r = run_test(t)
        tests_out.append({"name": t.get("name"), "pass": bool(r.get("ok")), "assertions": r.get("assertions"), "error": r.get("error"), "frames_run": r.get("frames_run")})
        tests_ok &= bool(r.get("ok"))
    report["gates"].append({"gate": "tests", "pass": tests_ok, "tests": tests_out})
    report["ok"] = tests_ok
    if not tests_ok:
        report["failed_gate"] = "tests"
    if record:
        at.HANDLERS["record_attempt"]({"goal": f"stage:{name}", "verdict": "pass" if tests_ok else "fail",
                                       "evidence": json.dumps([{"t": t["name"], "pass": t["pass"]} for t in tests_out])[:800],
                                       "errors": [f"{t['name']}: {a['name']} {a['metric']}={a['value']} {a['op']} {a['expected']}" for t in tests_out for a in (t.get("assertions") or []) if not a.get("pass")][:16],
                                       "blueprint": bp})
    return report


_RAW_HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "find_features": find_features,
    "run_pipeline": run_pipeline,
    "run_test": run_test,
    "build_stage": build_stage,
    "snapshot_fast": snapshot_fast,
    "screenshot": screenshot,
    "replay_hash_check": replay_hash_check,
}


def _guarded(tool_name: str, fn: Callable[[dict[str, Any]], dict[str, Any]]) -> Callable[[dict[str, Any]], dict[str, Any]]:
    def wrapper(arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            return fn(arguments if isinstance(arguments, dict) else {})
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "tool": tool_name, "error": "internal_error", "detail": f"{type(exc).__name__}: {exc}"}
    return wrapper


HANDLERS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {name: _guarded(name, fn) for name, fn in _RAW_HANDLERS.items()}
