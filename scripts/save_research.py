"""Harvest community saves from the Powder Toy server into the knowledge base.

For each save: load it into the running game (sim.loadSave), wait for the
particle count to settle, pause, then capture census / logic probe / 4px map /
1px map / full particle dump into D:/powder-toy/knowledge/saves/<id>/.
The Browse metadata (name, author, score, description) is stored alongside.

Usage:
  python scripts/save_research.py --query "nuclear reactor" --n 10
  python scripts/save_research.py --ids 78400 5170 2001108
  python scripts/save_research.py --queries "fusion reactor" "rbmk" "power plant" --n 6

Talks to the game through powder_bridge.client (the MCP is not needed).
Never touches saves already harvested unless --force.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path("D:/powder-toy")
sys.path.insert(0, str(ROOT))
from powder_bridge.client import PowderClient  # noqa: E402

KNOW = ROOT / "knowledge" / "saves"
STAMPS = Path("D:/The-Powder-Toy/build/stamps")
TMP = ROOT / "scripts" / "lua"
LEGEND_EXTRA = (',STNE=":",SAND=";",IRON="M",THRM="t",GUN="!",FWRK="!",TNT="!",["C-5"]="!",WAX="x",VENT="^",DTEC="&",'
                'URAN="u",INST="=",PSNS="&",TSNS="%",PLUT="U",DEUT="d",H2="h",LN2="2",LITH="l",NBLE="n",O2="o",CO2="c",'
                'GPMP="g",WWLD="W",FRAY="R",BHOL="B",PLSM="!",FIRE="!",LAVA="L",EXOT="e",NEUT="N",PROT="p",FUSE="f",'
                'QRTZ="q",SALT="s",BGLA="`",BRMT="b",BCOL=",",PQRT="Q",COAL="C",OIL="~",DESL="~",GEL="j",SNOW="*",ICE="_"}')


def browse(query: str, page: int = 0) -> list[dict]:
    url = "https://powdertoy.co.uk/Browse.json?Search_Query=" + urllib.parse.quote(query) + f"&PageNum={page}"
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.loads(r.read().decode("utf-8"))
    return data.get("Saves", [])


def view(save_id: int) -> dict:
    try:
        with urllib.request.urlopen(f"https://powdertoy.co.uk/Browse/View.json?ID={save_id}", timeout=30) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc)}


def lua(client: PowderClient, code: str) -> str:
    return str(client.execute_lua(code).get("result"))


def wait_settle(client: PowderClient, timeout: float = 12.0) -> tuple[int, bool]:
    last = -1
    stable = 0
    t0 = time.time()
    while time.time() - t0 < timeout:
        n = client.get_simulation_state()["partCount"]
        if n == last:
            stable += 1
            if stable >= 2 and n > 0:
                return n, True
        else:
            stable = 0
        last = n
        time.sleep(1.0)
    return last, False


def harvest(client: PowderClient, save: dict, force: bool = False) -> dict:
    sid = int(save["ID"])
    out = KNOW / str(sid)
    if out.exists() and not force and (out / "census.txt").exists():
        return {"id": sid, "skipped": True}
    out.mkdir(parents=True, exist_ok=True)
    meta = dict(save)
    meta["view"] = view(sid)
    t0 = time.time()
    if not save.get("_already_loaded"):
        # Deterministic path: fetch the .cps from the static server, drop it in the
        # game's stamps folder, clear, and load it as a stamp (no in-game networking,
        # no dialogs -- sim.loadSave hung the bridge for 10 minutes).
        stm = STAMPS / f"s{sid}.stm"
        if not stm.exists() or stm.stat().st_size < 64:
            try:
                with urllib.request.urlopen(f"https://static.powdertoy.co.uk/{sid}.cps", timeout=60) as r:
                    stm.write_bytes(r.read())
            except Exception as exc:  # noqa: BLE001
                meta["load_error"] = f"download: {exc}"
                (out / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
                return {"id": sid, "error": meta["load_error"]}
        lua(client, "tpt.set_pause(1)")
        client.clear()
        res = lua(client, f"local ok,err=pcall(sim.loadStamp,'s{sid}',0,0) return tostring(ok)..' '..tostring(err)")
        if not res.startswith("true"):
            meta["load_error"] = res
            (out / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
            return {"id": sid, "error": res}
    n, settled = wait_settle(client)
    lua(client, "tpt.set_pause(1)")
    time.sleep(0.5)
    meta.update({"partCount": n, "settled": settled, "load_seconds": round(time.time() - t0, 1), "captured": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    census = lua(client, (TMP / "census.lua").read_text(encoding="utf-8"))
    (out / "census.txt").write_text(census, encoding="utf-8")
    logic = lua(client, (TMP / "logic.lua").read_text(encoding="utf-8"))
    (out / "logic.txt").write_text(logic, encoding="utf-8")
    dump = (TMP / "dump.lua").read_text(encoding="utf-8")
    dump = dump.replace("D:/powder-toy/knowledge/SCENE_TAG.parts.jsonl", str(out / "parts.jsonl").replace("\\", "/"))
    dump = dump.replace("D:/powder-toy/knowledge/SCENE_TAG.map.txt", str(out / "map1px.txt").replace("\\", "/"))
    dump = dump.replace("SCENE_TAG", f"save-{sid}").replace('PHOT="."}', 'PHOT="."' + LEGEND_EXTRA)
    map4 = lua(client, dump)
    (out / "map4px.txt").write_text(map4, encoding="utf-8")
    (out / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
    first = census.splitlines()[0] if census else ""
    return {"id": sid, "name": save.get("Name"), "parts": n, "settled": settled, "head": first[:120]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--query")
    ap.add_argument("--queries", nargs="*")
    ap.add_argument("--ids", nargs="*", type=int)
    ap.add_argument("--n", type=int, default=8, help="saves per query")
    ap.add_argument("--pages", type=int, default=1)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--min-score", type=int, default=0)
    ap.add_argument("--current", type=int, help="capture the save already on the canvas as this id (no load)")
    args = ap.parse_args()
    client = PowderClient()
    KNOW.mkdir(parents=True, exist_ok=True)
    targets: list[dict] = []
    seen: set[int] = set()
    queries = list(args.queries or []) + ([args.query] if args.query else [])
    for q in queries:
        got = 0
        for page in range(args.pages):
            for s in browse(q, page):
                if int(s["ID"]) in seen or int(s.get("Score", 0)) < args.min_score:
                    continue
                s["query"] = q
                targets.append(s)
                seen.add(int(s["ID"]))
                got += 1
                if got >= args.n:
                    break
            if got >= args.n:
                break
    if args.current:
        targets.append({"ID": args.current, "Name": f"id-{args.current}", "query": "current", "_already_loaded": True})
        seen.add(args.current)
    for sid in args.ids or []:
        if sid not in seen:
            targets.append({"ID": sid, "Name": f"id-{sid}", "query": "ids"})
            seen.add(sid)
    print(f"harvesting {len(targets)} saves", flush=True)
    index_path = KNOW / "index.jsonl"
    for i, s in enumerate(targets):
        try:
            r = harvest(client, s, force=args.force)
        except Exception as exc:  # noqa: BLE001
            r = {"id": s.get("ID"), "error": f"{type(exc).__name__}: {exc}"}
        r["name"] = s.get("Name")
        r["query"] = s.get("query")
        print(f"[{i+1}/{len(targets)}] {json.dumps(r)}", flush=True)
        if not r.get("skipped"):
            with index_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(r) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
