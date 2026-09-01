"""Drive a small local model (Ollama / OpenAI-compatible) to build in Powder Toy.

Research-derived loop (2026-08-25, extended 2026-08-26 -- round 3):
  * world_state before EVERY model turn (state tracking is the #1 failure mode)
  * grammar/schema-constrained decoding so the caller cannot emit malformed JSON
  * compile -> lint -> errors fed back verbatim, up to --rounds
  * every attempt logged with record_attempt (dataset + curriculum memory,
    now with a decomposed score + temperature/round_no/resample_no)
  * --curriculum: let next_task pick practices from the playbook in order,
    decomposing failures into sub-tasks (Voyager-style automatic curriculum)
  * system_prompt() retrieval-shortlists the module list (module_retrieve:
    Ollama embeddings when reachable, else stdlib TF-IDF) to the top --modules-k
    plus any module named directly in the request, instead of dumping all
    76+ modules into every call (arXiv 2409.00608, TinyAgent); modules whose
    required custom elements are not currently live are listed as
    unavailable rather than offered (arXiv 2608.01050-style precondition gate)

Usage:
  python scripts/blueprint_agent.py "a glass tank of water with a heater" --model qwen2.5:1.5b
  python scripts/blueprint_agent.py --curriculum --model qwen2.5:1.5b --max-level 2
  python scripts/blueprint_agent.py --file my.json          # compile+build a file, no model
Endpoints: --endpoint http://localhost:11434 (Ollama native, uses "format": json_schema)
           --openai   OpenAI-compatible /v1/chat/completions (LM Studio, llama.cpp server)
           --gbnf     send the GBNF grammar (llama.cpp /completion style servers)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from powder_ext import blueprint_tools as bt  # noqa: E402
from powder_ext import agent_tools as at  # noqa: E402
from powder_ext import knowledge_tools as kt  # noqa: E402


def _explicit_modules_in_text(text: str, names: list[str]) -> list[str]:
    """Module names the request mentions verbatim (whole word) -- always kept
    regardless of retrieval rank.
    """
    lower = text.lower()
    return [n for n in names if re.search(r"\b" + re.escape(n.lower()) + r"\b", lower)]


def system_prompt(request: str = "", modules_k: int = 12) -> str:
    """Build the system prompt. `request` (round 3 item 2) is used to
    retrieval-shortlist the module list via `at.module_retrieve` to the top
    `modules_k` most relevant modules plus any module named directly in the
    request, instead of dumping the full 76+-module registry into every call.
    Modules whose required custom elements are not currently live are listed
    separately as unavailable (round 3 item 5 precondition gate) rather than
    silently offered.
    """
    schema = bt.blueprint_schema({})
    all_names = list(schema["modules"].keys())
    if request.strip():
        explicit = _explicit_modules_in_text(request, all_names)
        retrieved = at.module_retrieve(request, k=modules_k, explicit=explicit)
        chosen = [m["name"] for m in retrieved.get("modules", [])] if retrieved.get("ok") else all_names[:modules_k]
    else:
        chosen = all_names[:modules_k]
    gate = at.gate_modules(chosen)
    available = [n for n in chosen if n in gate["available"]]
    mods = "\n".join(f"  - {n}: params {json.dumps(schema['modules'][n]['params'])}  # {schema['modules'][n]['why']}" for n in available if n in schema["modules"])
    unavailable_note = ""
    if gate["unavailable"]:
        items = "; ".join(f"{n} (needs undefined element(s) {', '.join(miss)})" for n, miss in gate["unavailable"].items())
        unavailable_note = "\nUnavailable right now -- do NOT use these, their custom elements are not defined yet: " + items + "\n"
    return ("You control a Powder Toy simulation by writing ONE JSON object in the Powder Blueprint v1 format.\n"
            "Output ONLY the JSON object.\n\n" + schema["reference"] +
            "\nModules ({\"module\": NAME, \"at\": [x,y], \"params\": {...}}):\n" + mods + unavailable_note +
            "\n\nExample:\n" + json.dumps(schema["example"]) + "\n")


def extract_json(text: str) -> dict | None:
    text = text.strip()
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if fence:
        text = fence.group(1)
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i + 1])
                except json.JSONDecodeError:
                    break
    try:
        return json.loads(text[start:])
    except json.JSONDecodeError:
        return None


def chat(endpoint: str, model: str, messages: list[dict], openai: bool, temperature: float, gbnf: str | None, schema: dict | None) -> str:
    if openai:
        url = endpoint.rstrip("/") + "/v1/chat/completions"
        body: dict = {"model": model, "messages": messages, "temperature": temperature}
        if schema is not None:
            body["response_format"] = {"type": "json_schema", "json_schema": {"name": "blueprint", "schema": schema}}
        if gbnf:
            body["grammar"] = gbnf  # llama.cpp server extension; ignored elsewhere
    else:
        url = endpoint.rstrip("/") + "/api/chat"
        body = {"model": model, "messages": messages, "stream": False,
                "format": schema if schema is not None else "json",
                "options": {"temperature": temperature, "num_ctx": 8192}}
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data["choices"][0]["message"]["content"] if openai else data["message"]["content"]


def world_line() -> str:
    w = at.HANDLERS["world_state"]({})
    return w.get("summary", f"(world_state unavailable: {w.get('error')})")


def solve(request: str, args, practice: dict | None = None) -> tuple[dict | None, dict | None, list[str], dict]:
    """Ask the caller for a blueprint, loop compile/lint errors back.
    Returns (blueprint, last_result, errors, meta) where meta = {"round_no", "resample_no"}
    records which round/resample the returned candidate actually settled on
    (round 3 item 3: sampling metadata for future GRPO-style grouping).
    """
    gram = at.HANDLERS["blueprint_grammar"]({"format": "both"})
    schema = gram["json_schema"] if args.constrain else None
    gbnf = gram["gbnf"] if (args.gbnf and args.constrain) else None
    messages = [{"role": "system", "content": system_prompt(request, modules_k=int(getattr(args, "modules_k", 12) or 12))}]
    meta: dict[str, int] = {"round_no": 0, "resample_no": 0}
    user = f"WORLD STATE NOW: {world_line()}\n\nBuild this: {request}"
    if practice:
        user += ("\nThis is playbook practice '" + practice["practice"] + "' (level " + str(practice["level"]) + ").\n"
                 "Verify condition you must satisfy: " + practice["verify"] + "\nPitfalls: " + "; ".join(practice.get("pitfalls", [])[:4]))
        if practice.get("sub_tasks"):
            user += "\nDo ONLY sub-task " + json.dumps(practice["sub_tasks"][0]) + " now."
    if args.origin:
        user += f"\nUse \"origin\": [{args.origin}]."
    user += "\nKeep it under 40 parts. Respond with the JSON object only."
    messages.append({"role": "user", "content": user})
    bp = None
    result = None
    errors: list[str] = []
    for round_no in range(args.rounds + 1):
        meta["round_no"] = round_no
        print(f"--- round {round_no}: asking {args.model} ...", file=sys.stderr)
        try:
            reply = chat(args.endpoint, args.model, messages, args.openai, args.temperature, gbnf, schema)
        except Exception as exc:  # noqa: BLE001
            errors = [f"model call failed: {exc}"]
            print("    " + errors[0], file=sys.stderr)
            return None, None, errors, meta
        bp = extract_json(reply)
        if bp is None:
            feedback = "That was not a JSON object. Reply with ONLY the blueprint JSON object."
            errors = ["no JSON in reply"]
        else:
            if args.origin and "origin" not in bp:
                bp["origin"] = [int(v) for v in args.origin.split(",")]
            result = bt.blueprint_build({"blueprint": bp, "dry_run": True})
            crit = [f for f in result.get("lint", {}).get("findings", []) if f.get("severity") == "critical"]
            if result["ok"] and not crit:
                print(f"    compiles clean, lint clean: {result['primitive_count']} primitives, bounds {result['bounds']}", file=sys.stderr)
                return bp, result, [], meta
            errs = result["errors"][:8]
            errors = [e["problem"] for e in errs] + [f"lint {f['rule']}: {f['problem']}" for f in crit[:4]]
            print(f"    {len(result['errors'])} error(s), {len(crit)} critical lint: " + "; ".join(errors[:3]), file=sys.stderr)
            # localized repair (counterexample-guided): show only the failing parts and their errors
            import re as _re
            bad_idx = sorted({int(m_.group(1)) for e in errs + crit for m_ in [_re.match(r"parts\[(\d+)\]", str(e.get("path", "")))] if m_})
            failing_parts = {i: bp.get("parts", [])[i] for i in bad_idx if i < len(bp.get("parts", []))}
            feedback = ("Only these parts are wrong; fix them (keep every other part exactly as it was) and resend the WHOLE JSON object:\n"
                        + json.dumps({"failing_parts": failing_parts, "errors": errs + [{"path": f["path"], "problem": f["problem"], "fix": f["fix"]} for f in crit[:4]]}, indent=1)
                        + f"\n\nWORLD STATE NOW: {world_line()}")
        messages.append({"role": "assistant", "content": reply})
        messages.append({"role": "user", "content": feedback})
    # blind resample: fresh prompt, no failure history (arXiv 2607.26117: feedback hurts sub-7B models)
    for k in range(int(getattr(args, "resample", 0) or 0)):
        meta["resample_no"] = k + 1
        print(f"--- blind resample {k+1}", file=sys.stderr)
        fresh = [messages[0], messages[1]]
        try:
            reply = chat(args.endpoint, args.model, fresh, args.openai, max(args.temperature, 0.5), gbnf, schema)
        except Exception as exc:  # noqa: BLE001
            break
        cand = extract_json(reply)
        if cand is None:
            continue
        res2 = bt.blueprint_build({"blueprint": cand, "dry_run": True})
        crit2 = [f for f in res2.get("lint", {}).get("findings", []) if f.get("severity") == "critical"]
        if res2["ok"] and not crit2:
            return cand, res2, [], meta
    return bp, result, errors, meta


def _score_from_result(result: dict | None, verify_pass: bool) -> dict:
    lint = (result or {}).get("lint", {}) or {}
    return {
        "compiles": bool(result and result.get("ok")),
        "lint_critical": int((lint.get("counts_by_severity") or {}).get("critical", 0)),
        "lint_total": int(lint.get("count", 0)),
        "verify_pass": verify_pass,
    }


def build_and_log(bp: dict | None, result: dict | None, errors: list[str], goal: str, args, practice: dict | None, meta: dict | None = None) -> bool:
    ok = False
    evidence = ""
    if bp is not None and result is not None and result.get("ok") and not args.dry_run:
        final = bt.blueprint_build({"blueprint": bp, "dry_run": False})
        ok = bool(final.get("ok"))
        evidence = f"built {final.get('succeeded')}/{final.get('succeeded', 0) + final.get('failed', 0)} primitives; lint {final.get('lint', {}).get('counts_by_severity')}"
        print(json.dumps({k: final.get(k) for k in ("ok", "succeeded", "failed", "skipped", "left_paused")}, default=str))
    elif bp is not None and result is not None and result.get("ok"):
        ok = True
        evidence = "dry-run compile clean (not drawn)"
    meta = meta or {}
    at.HANDLERS["record_attempt"]({
        "goal": goal, "practice": practice["practice"] if practice else None, "level": practice["level"] if practice else None,
        "model": args.model, "verdict": "pass" if ok else "fail", "evidence": evidence, "errors": errors[:16], "blueprint": bp,
        "score": _score_from_result(result, ok), "temperature": getattr(args, "temperature", None),
        "round_no": meta.get("round_no"), "resample_no": meta.get("resample_no"),
    })
    if args.save and bp is not None:
        Path(args.save).write_text(json.dumps(bp, indent=1), encoding="utf-8")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("request", nargs="?")
    ap.add_argument("--file")
    ap.add_argument("--curriculum", action="store_true", help="let next_task choose practices from the playbook")
    ap.add_argument("--max-level", type=int, default=2)
    ap.add_argument("--tasks", type=int, default=3, help="curriculum: how many tasks to attempt this run")
    ap.add_argument("--model", default="qwen2.5:1.5b")
    ap.add_argument("--endpoint", default="http://localhost:11434")
    ap.add_argument("--openai", action="store_true")
    ap.add_argument("--gbnf", action="store_true", help="also send the GBNF grammar (llama.cpp servers)")
    ap.add_argument("--no-constrain", dest="constrain", action="store_false", help="disable schema-constrained decoding")
    ap.add_argument("--rounds", type=int, default=2, help="feedback-repair rounds (research: 2 captures most gain for small models)")
    ap.add_argument("--resample", type=int, default=1, help="after the repair rounds, blind-resample this many times (no error feedback) -- beats feedback repair below 7B")
    ap.add_argument("--temperature", type=float, default=0.2)
    ap.add_argument("--modules-k", type=int, default=12, help="retrieval-shortlist the module list to this many (plus any named directly) instead of all 76+ (round 3 item 2)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--origin")
    ap.add_argument("--save")
    args = ap.parse_args()

    if args.file:
        bp = json.loads(Path(args.file).read_text(encoding="utf-8"))
        result = bt.blueprint_build({"blueprint": bp, "dry_run": True})
        print(json.dumps({k: result[k] for k in ("ok", "errors", "counts", "bounds")}, indent=1))
        if result["ok"] and not args.dry_run:
            final = bt.blueprint_build({"blueprint": bp, "dry_run": False})
            print(json.dumps({k: final.get(k) for k in ("ok", "succeeded", "failed", "skipped")}, indent=1, default=str))
        return 0 if result["ok"] else 1

    if args.curriculum:
        for _ in range(args.tasks):
            nt = at.HANDLERS["next_task"]({"max_level": args.max_level})
            if nt.get("done"):
                print("curriculum complete for max_level", args.max_level); break
            task = nt["task"]
            goal = task["goal"]
            print(f"=== practice {task['practice']} (L{task['level']}, attempt {task['attempt_number']}, {task['mode']}) ===", file=sys.stderr)
            bp, result, errors, meta = solve(goal, args, practice=task)
            ok = build_and_log(bp, result, errors, goal, args, task, meta)
            print(f"    -> {'PASS' if ok else 'FAIL'}", file=sys.stderr)
        return 0

    if not args.request:
        ap.error("give a request, --file, or --curriculum")
    bp, result, errors, meta = solve(args.request, args)
    if bp is not None:
        print(json.dumps(bp, indent=1))
    ok = build_and_log(bp, result, errors, args.request, args, None, meta)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
