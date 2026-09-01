"""pass@k / pass^k harness for the blueprint driver (research roadmap item 3;
extended 2026-08-26 with round 3 items 2/4: structural dedup + Wilson intervals,
plus a training-ready SFT/RFT dataset export).

Runs N independent samples of a model on a fixed task set (offline compile+lint
verdicts by default; --live adds build_stage tests on the sim) and reports
pass@1, pass@k (any of k passes) and pass^k (all k pass) per task and overall.

Round 3 additions:
  * samples are deduplicated by *structure* (canonical JSON of `parts`,
    ignoring per-part `id`s) before counting -- arXiv 2308.01825 (the RFT
    paper) explicitly dedups this way rather than keep-first/keep-best, to
    avoid overrepresenting whatever the caller converges on first; a duplicate
    is still logged to attempts.jsonl for audit but excluded from the pass@k
    counts and from attempts-sft.jsonl.
  * each task's pass@1 carries a 95% Wilson score interval (a practical
    Beta-Binomial approximation) alongside the point estimate.
  * every deduplicated sample is also appended to knowledge/attempts-sft.jsonl
    as {prompt, completion, verdict, verifier_feedback} -- directly usable as
    an SFT (filter to verdict=="pass") or RFT (same, plus temperature/round_no
    grouping already in attempts.jsonl) training file.
  * every sample also carries the decomposed score + sampling metadata that
    scripts/blueprint_agent.py's build_and_log now logs (round 3 item 3).
  * --tasks accepts an optional "expected" block per task (see
    knowledge/tasks-basic.json) -- {"elements": {"WATR": 1}, "min_primitives": N}
    -- checked informationally against the compiled preview; it does not
    affect the pass/fail verdict (that stays compile+critical-lint clean),
    only an "expected_check" diagnostic on each row.

  python scripts/passk_harness.py --model qwen2.5:1.5b --k 5 --tasks knowledge/tasks-basic.json
  python scripts/passk_harness.py --model qwen2.5:1.5b --k 3 --no-constrain   # A/B the grammar
"""
import argparse
import json
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, "D:/powder-toy")
from powder_ext import blueprint_tools as bt, agent_tools as at  # noqa: E402
sys.path.insert(0, "D:/powder-toy/scripts")
import blueprint_agent as agent  # noqa: E402

ATTEMPTS_SFT = Path("D:/powder-toy/knowledge/attempts-sft.jsonl")

DEFAULT_TASKS = [
    {"name": "tank", "request": "a sealed glass tank half full of distilled water, 30x20, at origin 200,150"},
    {"name": "heater", "request": "an insulated heater block (HEAC at 800 C inside INSL) next to a small water tank"},
    {"name": "wifi_lamp", "request": "a WIFI node on channel 5 whose PSCN pad touches an LCRY lamp"},
    {"name": "pressure", "request": "a wall-boxed pressure chamber using the pressure_chamber module at 150,120"},
    {"name": "cryo", "request": "a cryo_column_ln2 module with an INSL-lined outlet channel below it"},
    {"name": "flood", "request": "a TTAN vessel 40x30 with an injector_pod on channel 6 in its top wall and a drain_pod on channel 7 in its bottom wall"},
]


# ---------------------------------------------------------------------------
# structural dedup (round 3 item 4 / arXiv 2308.01825)
# ---------------------------------------------------------------------------

def _strip_ids(node):
    """Recursively drop per-part `id` keys (names/anchors) so two blueprints
    that differ only in id labels hash the same; every other field (element,
    params, coordinates, module choice) is kept, since those are exactly the
    structural differences the RFT paper wants preserved.
    """
    if isinstance(node, dict):
        return {k: _strip_ids(v) for k, v in sorted(node.items()) if k != "id"}
    if isinstance(node, list):
        return [_strip_ids(v) for v in node]
    return node


def canonical_signature(bp: dict | None) -> str | None:
    """Canonical JSON of a blueprint's `parts`, ignoring per-part ids -- the
    structural key samples are deduplicated on. None when `bp` has no usable
    `parts` (e.g. the caller never produced valid JSON).
    """
    if not isinstance(bp, dict) or not isinstance(bp.get("parts"), list):
        return None
    return json.dumps(_strip_ids(bp["parts"]), sort_keys=True, separators=(",", ":"))


# ---------------------------------------------------------------------------
# Wilson score interval (round 3 item 4): a practical, dependency-free
# approximation to the Beta-Binomial credible interval requested by round 2's
# item 3 / round 3's research note.
# ---------------------------------------------------------------------------

def wilson_interval(c: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """95% (default z=1.96) Wilson score interval for c successes out of n trials."""
    if n <= 0:
        return (0.0, 1.0)
    phat = c / n
    denom = 1.0 + z * z / n
    center = phat + z * z / (2 * n)
    margin = z * math.sqrt(phat * (1 - phat) / n + z * z / (4 * n * n))
    lo = (center - margin) / denom
    hi = (center + margin) / denom
    return (max(0.0, lo), min(1.0, hi))


# ---------------------------------------------------------------------------
# optional expected-element check (round 3 item 5's companion: golden tasks
# in knowledge/tasks-basic.json). Informational only -- never changes ok/pass.
# ---------------------------------------------------------------------------

def element_counts_from_preview(res: dict | None) -> dict[str, int]:
    counts: dict[str, int] = {}
    for prim in (res or {}).get("preview", []) or []:
        el = prim.get("element")
        if isinstance(el, str) and el.upper() != "NONE":
            counts[el.upper()] = counts.get(el.upper(), 0) + 1
    return counts


def check_expected(res: dict | None, expected: dict | None) -> dict:
    if not isinstance(expected, dict):
        return {"checked": False}
    counts = element_counts_from_preview(res)
    problems = []
    for el, min_n in (expected.get("elements") or {}).items():
        got = counts.get(str(el).upper(), 0)
        if got < int(min_n):
            problems.append(f"expected >= {min_n} {el}, found {got}")
    min_prims = expected.get("min_primitives")
    if min_prims is not None and int((res or {}).get("primitive_count", 0)) < int(min_prims):
        problems.append(f"expected >= {min_prims} primitives, found {(res or {}).get('primitive_count', 0)}")
    return {"checked": True, "ok": not problems, "problems": problems, "element_counts": counts}


# ---------------------------------------------------------------------------
# attempts-sft.jsonl writer (round 3 item 2)
# ---------------------------------------------------------------------------

def append_sft_row(prompt: str, bp: dict | None, verdict: str, verifier_feedback: list[str]) -> None:
    row = {
        "prompt": prompt,
        "completion": json.dumps(bp) if isinstance(bp, dict) else None,
        "verdict": verdict,
        "verifier_feedback": list(verifier_feedback or [])[:16],
    }
    ATTEMPTS_SFT.parent.mkdir(parents=True, exist_ok=True)
    with ATTEMPTS_SFT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="qwen2.5:1.5b"); ap.add_argument("--endpoint", default="http://localhost:11434")
    ap.add_argument("--openai", action="store_true"); ap.add_argument("--k", type=int, default=3)
    ap.add_argument("--tasks"); ap.add_argument("--rounds", type=int, default=2); ap.add_argument("--resample", type=int, default=0)
    ap.add_argument("--no-constrain", dest="constrain", action="store_false"); ap.add_argument("--gbnf", action="store_true")
    ap.add_argument("--modules-k", type=int, default=12, help="retrieval-shortlist the module list to this many per sample (round 3 item 2)")
    ap.add_argument("--temperature", type=float, default=0.4); ap.add_argument("--origin"); ap.add_argument("--dry-run", action="store_true", default=True)
    ap.add_argument("--out", default="D:/powder-toy/knowledge/passk-results.jsonl")
    args = ap.parse_args()
    args.save = None
    tasks = json.loads(Path(args.tasks).read_text(encoding="utf-8")) if args.tasks else DEFAULT_TASKS
    rows = []
    for t in tasks:
        seen_sigs: set[str] = set()
        passes: list[bool] = []  # deduplicated-by-structure only
        dup_count = 0
        expected_checks: list[dict] = []
        for i in range(args.k):
            t0 = time.time()
            bp, res, errs, meta = agent.solve(t["request"], args)
            crit = [f for f in (res or {}).get("lint", {}).get("findings", []) if f.get("severity") == "critical"]
            ok = bool(bp and res and res.get("ok") and not crit)
            sig = canonical_signature(bp)
            is_dup = sig is not None and sig in seen_sigs
            if sig is not None:
                seen_sigs.add(sig)
            score = agent._score_from_result(res, ok)
            at.HANDLERS["record_attempt"]({
                "goal": t["request"], "practice": t.get("practice"), "model": args.model, "verdict": "pass" if ok else "fail",
                "evidence": f"passk sample {i+1}/{args.k} constrain={args.constrain} rounds={args.rounds} resample={args.resample} dup={is_dup} {time.time()-t0:.0f}s",
                "errors": errs[:8], "blueprint": bp,
                "score": score, "temperature": args.temperature, "round_no": meta.get("round_no"), "resample_no": meta.get("resample_no"),
            })
            if is_dup:
                dup_count += 1
                print(f"{t['name']} sample {i+1}: DUP (structurally identical to an earlier sample, excluded from counts)", file=sys.stderr)
            else:
                passes.append(ok)
                append_sft_row(t["request"], bp, "pass" if ok else "fail", errs)
                if t.get("expected") is not None:
                    expected_checks.append(check_expected(res, t.get("expected")))
                print(f"{t['name']} sample {i+1}: {'PASS' if ok else 'FAIL'} ({time.time()-t0:.0f}s)", file=sys.stderr)
        n = len(passes); c = sum(passes)
        lo, hi = wilson_interval(c, n)
        row = {
            "task": t["name"], "k": args.k, "unique": n, "duplicates": dup_count, "passes": c,
            "pass@1": (c / n) if n else 0.0, "pass@1_ci95": [lo, hi],
            "pass@k": 1.0 if c else 0.0, "pass^k": 1.0 if (n and c == n) else 0.0,
        }
        if expected_checks:
            row["expected_checks_ok"] = sum(1 for e in expected_checks if e.get("ok"))
            row["expected_checks_total"] = len(expected_checks)
        rows.append(row)
    total_c = sum(r["passes"] for r in rows)
    total_n = sum(r["unique"] for r in rows)
    pooled_lo, pooled_hi = wilson_interval(total_c, total_n)
    summary = {
        "model": args.model, "constrain": args.constrain, "rounds": args.rounds, "resample": args.resample, "k": args.k,
        "pass@1": sum(r["pass@1"] for r in rows) / len(rows) if rows else 0.0,
        "pass@k": sum(r["pass@k"] for r in rows) / len(rows) if rows else 0.0,
        "pass^k": sum(r["pass^k"] for r in rows) / len(rows) if rows else 0.0,
        "pooled_pass@1_ci95": [pooled_lo, pooled_hi],
        "tasks": rows, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sft_dataset": str(ATTEMPTS_SFT),
    }
    with open(args.out, "a", encoding="utf-8") as f:
        f.write(json.dumps(summary) + "\n")
    print(json.dumps(summary, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
