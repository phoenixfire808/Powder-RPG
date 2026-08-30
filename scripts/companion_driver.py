"""Local-model brain for the RPG colonist (scripts/lua/rpg_plugins/companion.lua).

The colonist is fully playable and fully conversational with NO model at all - see companion.lua's
scripted brain (follow/self-defense reflexes) and its `templateReply` chat fallback. This script is an
OPTIONAL layer on top: it polls the game over the bridge, asks a local OpenAI-compatible chat model for
one decision at a time as STRICT JSON, validates it, and calls back into the exact same action surface a
person typing in chat would use (R.companionCmd / R.companionEnqueue / R.colonistSay). If no local model
server is reachable, or the JSON is bad, or the call is slow, this script simply does nothing that tick -
companion.lua's own scripted brain and chat templates keep the colonist useful and (per Drew's explicit
"no unsolicited gifts / only do what he asked" rule) quiet.

Model contract (see knowledge/design-companion-protocol.md for the full schema):
    {"say": "On it - grabbing that iron", "cmd": "mine", "args": {"element": "IRON"}}
    {"say": "Building the wall now",       "plan": [{"cmd": "buildWall", "args": {...}}, {"cmd": "give", "args": {"item": "STNE"}}]}
`say` is optional (<=100 chars); exactly one of `cmd` (a single step) or `plan` (1-6 steps) may be present,
or neither (a pure chat reply with no action). Unknown commands / out-of-range coordinates are rejected.

Usage
-----
    python scripts/companion_driver.py                  # auto-detect LM Studio (1234) or Ollama (11434)
    python scripts/companion_driver.py --lab             # target the lab instance (port 9877) instead of
                                                          # Drew's live game - use this while developing
    python scripts/companion_driver.py --url http://localhost:1234/v1 --model qwen2.5-3b-instruct
    python scripts/companion_driver.py --once            # single decision cycle, for testing/CI

Model setup (not done by this script - it never downloads anything):
    LM Studio: load "Qwen2.5 3B Instruct" (Q4_K_M, ~1.9GB), pin it to the RTX 2070 SUPER (GPU index 1 -
               set CUDA_VISIBLE_DEVICES=1 for the server process, or pick GPU 1 in LM Studio's server
               settings) so the RTX 5060 Ti stays free for the game itself. Start the local server
               (defaults to http://localhost:1234/v1).
    Ollama:    `ollama pull qwen2.5:3b-instruct` (or any small instruct model) and run `ollama serve`
               (defaults to http://localhost:11434). Also pin with CUDA_VISIBLE_DEVICES=1 if you run the
               server yourself rather than the Windows service.
Either way: load the model on demand before running this script, and unload/stop the server when the
colonist doesn't need it - nothing here keeps a model resident in the background.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Any

sys.path.insert(0, "D:/powder-toy")
from powder_bridge.client import PowderClient  # noqa: E402

LAB_TOKEN_PATH = "D:/powder-toy/lab_instance/ddir/powder-bridge.token"
LAB_PORT = 9877

# Commands the model is allowed to issue, and how far its coordinates may be clamped from the player.
# Mirrors STEP.* in companion.lua - keep in sync if that table grows.
ALLOWED_CMDS = {
    "follow", "stay", "say", "goto", "mine", "mineNearest", "chop", "fetch", "place", "craft",
    "give", "take", "fight", "light", "buildWall", "build", "bridge", "stairs",
    "clearTrees", "digArea", "buildRoom", "buildShaft",
}
COORD_KEYS = ("x", "y", "x1", "y1", "x2", "y2")
MAX_COORD_DIST = 320  # clamp: no command may target a point farther than this from the player, in px

SYSTEM_PROMPT = (
    "You are {name}, a colonist companion in a 2D physics survival game (Terraria-like, real particle "
    "physics). You have a body in the world with its own inventory. Reply with EXACTLY one JSON object, "
    "nothing else - no markdown, no commentary outside the JSON.\n"
    'Schema: {{"say": "<=100 chars, in character, optional", '
    '"cmd": "<name>", "args": {{...}}}} for a single step, OR '
    '{{"say": "...", "plan": [{{"cmd":"...","args":{{...}}}}, ...]}} for 1-6 chained steps.\n'
    "Allowed cmd names: " + ", ".join(sorted(ALLOWED_CMDS)) + ".\n"
    "Only ever act on what the player actually asked for or is clearly implied by the conversation - "
    "never invent unsolicited chores, never give items away unasked. Between real requests just {{\"cmd\":"
    ' "follow"}} or reply with "say" only and no cmd. Never invent facts about the world - only use the '
    "state given to you. If you don't know something, say so and offer to go look. Keep `say` short."
)


# --------------------------------------------------------------------------- server auto-detect
def _get_json(url: str, timeout: float = 2.0) -> dict | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception:
        return None


def detect_server(explicit_url: str | None, explicit_model: str | None) -> tuple[str, str] | None:
    """Returns (base_url, model_name) for the first reachable OpenAI-compatible server, or None."""
    if explicit_url:
        model = explicit_model or _first_model_lmstudio(explicit_url) or _first_model_ollama(explicit_url)
        return (explicit_url, model) if model else None
    lm = _get_json("http://localhost:1234/v1/models")
    if lm and lm.get("data"):
        return "http://localhost:1234/v1", explicit_model or lm["data"][0]["id"]
    ol = _get_json("http://localhost:11434/api/tags")
    if ol and ol.get("models"):
        return "http://localhost:11434/v1", explicit_model or ol["models"][0]["name"]
    return None


def _first_model_lmstudio(base: str) -> str | None:
    d = _get_json(base.rstrip("/") + "/models")
    return d["data"][0]["id"] if d and d.get("data") else None


def _first_model_ollama(base: str) -> str | None:
    # base may already be the /v1 form; Ollama's native tags endpoint lives one level up
    root = base.rstrip("/")
    if root.endswith("/v1"):
        root = root[: -len("/v1")]
    d = _get_json(root + "/api/tags")
    return d["models"][0]["name"] if d and d.get("models") else None


# --------------------------------------------------------------------------- chat completion
def ask_model(base_url: str, model: str, system: str, user: str, max_tokens: int = 200) -> str | None:
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "temperature": 0.4,
        "max_tokens": max_tokens,
        "stream": False,
    }).encode("utf-8")
    req = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions", data=body,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20.0) as r:
            data = json.loads(r.read().decode("utf-8"))
        return data["choices"][0]["message"]["content"]
    except Exception as exc:  # noqa: BLE001 - degrade gracefully, never crash the loop
        print(f"[companion_driver] model call failed: {exc}")
        return None


_JSON_OBJ_RE = re.compile(r"\{.*\}", re.DOTALL)


def parse_json_object(text: str) -> dict | None:
    if not text:
        return None
    text = text.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
    try:
        return json.loads(text)
    except Exception:
        m = _JSON_OBJ_RE.search(text)
        if not m:
            return None
        try:
            return json.loads(m.group(0))
        except Exception:
            return None


# --------------------------------------------------------------------------- validation
def clamp_coords(args: dict, px: float, py: float) -> dict:
    out = dict(args)
    for k in COORD_KEYS:
        if k in out and isinstance(out[k], (int, float)):
            lo, hi = (px - MAX_COORD_DIST, px + MAX_COORD_DIST) if k[0] == "x" else (py - MAX_COORD_DIST, py + MAX_COORD_DIST)
            out[k] = max(lo, min(hi, out[k]))
    return out


def validate_step(step: Any, px: float, py: float) -> dict | None:
    if not isinstance(step, dict):
        return None
    cmd = step.get("cmd") or step.get("name")
    if cmd not in ALLOWED_CMDS:
        return None
    args = step.get("args") or {}
    if not isinstance(args, dict):
        args = {}
    return {"name": cmd, "args": clamp_coords(args, px, py)}


def validate_decision(obj: dict, px: float, py: float) -> tuple[str | None, list[dict]]:
    """Returns (say_text_or_None, list_of_validated_steps) - steps may be empty (chat-only reply)."""
    if not isinstance(obj, dict):
        return None, []
    say = obj.get("say")
    say = say.strip()[:100] if isinstance(say, str) and say.strip() else None
    steps: list[dict] = []
    if isinstance(obj.get("plan"), list):
        for raw in obj["plan"][:6]:
            v = validate_step(raw, px, py)
            if v:
                steps.append(v)
    elif obj.get("cmd") is not None:
        v = validate_step(obj, px, py)
        if v:
            steps.append(v)
    return say, steps


# --------------------------------------------------------------------------- bridge glue
def L(c: PowderClient, lua: str) -> Any:
    r = c.execute_lua(lua)
    return r.get("result")


def get_state(c: PowderClient) -> dict | None:
    raw = L(c, "local R=PBX.state.rpg if not R or not R.companionState then return nil end "
               "local ok, j = pcall(function() "
               "  local function enc(v) "
               "    if type(v)=='table' then local parts={} local isArr=(#v>0) "
               "      if isArr then for _,x in ipairs(v) do parts[#parts+1]=enc(x) end return '['..table.concat(parts,',')..']' "
               "      else for k,x in pairs(v) do parts[#parts+1]='\"'..tostring(k)..'\":'..enc(x) end return '{'..table.concat(parts,',')..'}' end "
               "    elseif type(v)=='string' then return '\"'..v:gsub('\\\\','\\\\\\\\'):gsub('\"','\\\\\"')..'\"' "
               "    elseif type(v)=='boolean' or type(v)=='number' then return tostring(v) "
               "    elseif v==nil then return 'null' else return '\"'..tostring(v)..'\"' end "
               "  end return enc(R.companionState()) end) "
               "if not ok then return nil end return j")
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def get_chat_pending(c: PowderClient) -> list[str]:
    raw = L(c, "local R=PBX.state.rpg if not R.companionChatPending then return '' end "
               "local msgs = R.companionChatPending(true) local out={} "
               "for _,m in ipairs(msgs) do out[#out+1]=m.text end return table.concat(out, '\\n---\\n')")
    if not raw:
        return []
    return [s for s in raw.split("\n---\n") if s]


def send_reply(c: PowderClient, text: str) -> None:
    safe = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    L(c, f'local R=PBX.state.rpg if R.colonistSay then R.colonistSay("{safe}") end return true')


def _py_to_lua(v: Any) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if v is None:
        return "nil"
    if isinstance(v, dict):
        return "{" + ",".join(f'["{k}"]={_py_to_lua(val)}' for k, val in v.items()) + "}"
    if isinstance(v, list):
        return "{" + ",".join(_py_to_lua(x) for x in v) + "}"
    return "nil"


def run_plan(c: PowderClient, steps: list[dict]) -> None:
    if not steps:
        return
    lua_steps = "{" + ",".join(
        f'{{name={_py_to_lua(s["name"])}, args={_py_to_lua(s["args"])}}}' for s in steps
    ) + "}"
    L(c, f'local R=PBX.state.rpg if not R.companionEnqueue then return false end '
         f'return tostring(R.companionEnqueue({lua_steps}, "model"))')


def heartbeat(c: PowderClient) -> None:
    L(c, "local R=PBX.state.rpg if R.companionHeartbeat then R.companionHeartbeat() end return true")


def set_mode(c: PowderClient, mode: str) -> None:
    L(c, f'local R=PBX.state.rpg if R.companionSetMode then R.companionSetMode("{mode}") end return true')


# --------------------------------------------------------------------------- main loop
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lab", action="store_true", help="target the lab instance (port 9877) instead of Drew's live game")
    ap.add_argument("--url", default=None, help="OpenAI-compatible base URL, e.g. http://localhost:1234/v1")
    ap.add_argument("--model", default=None, help="model name/id (auto-detected if omitted)")
    ap.add_argument("--chat-interval", type=float, default=0.4, help="how often to poll for chat messages (seconds)")
    ap.add_argument("--decision-interval", type=float, default=3.0, help="how often to make an idle decision (seconds)")
    ap.add_argument("--once", action="store_true", help="run a single decision cycle and exit (for testing)")
    a = ap.parse_args()

    if a.lab:
        token = open(LAB_TOKEN_PATH, encoding="utf-8").read().strip()
        c = PowderClient(port=LAB_PORT, token=token)
    else:
        c = PowderClient()

    server = detect_server(a.url, a.model)
    if not server:
        print("[companion_driver] No local model server found on http://localhost:1234 (LM Studio) or "
              "http://localhost:11434 (Ollama).")
        print("  Install LM Studio (https://lmstudio.ai), load 'Qwen2.5 3B Instruct' (Q4_K_M, ~1.9GB), "
              "pin it to GPU 1 (the RTX 2070 SUPER - CUDA_VISIBLE_DEVICES=1 or the GPU picker in the "
              "server tab), and start its local server. Or run Ollama with "
              "`ollama pull qwen2.5:3b-instruct` and `ollama serve`.")
        print("  The colonist stays fully useful without a model - this script is optional.")
        return 1
    base_url, model = server
    print(f"[companion_driver] using {model} at {base_url}")

    state = get_state(c)
    if not state or not state.get("active"):
        print("[companion_driver] colonist is not active in the target world yet - nothing to drive.")
        return 1

    set_mode(c, "model")
    try:
        last_decision = 0.0
        while True:
            heartbeat(c)
            msgs = get_chat_pending(c)
            state = get_state(c) or state
            px, py = state.get("player", {}).get("x", 0), state.get("player", {}).get("y", 0)
            name = "Aster"

            if msgs:
                user = "Player said: " + " / ".join(msgs) + "\nCurrent state:\n" + json.dumps(state)[:1500]
                raw = ask_model(base_url, model, SYSTEM_PROMPT.format(name=name), user)
                obj = parse_json_object(raw) if raw else None
                say, steps = validate_decision(obj, px, py) if obj else (None, [])
                if say:
                    send_reply(c, say)
                run_plan(c, steps)
            elif time.time() - last_decision > a.decision_interval:
                last_decision = time.time()
                action = (state.get("action") or {}).get("name")
                if action in (None, "follow"):  # only propose something new when genuinely idle
                    user = ("No new message. Current state (only act if something is clearly still "
                            "pending from earlier conversation - otherwise just follow quietly):\n"
                            + json.dumps(state)[:1500])
                    raw = ask_model(base_url, model, SYSTEM_PROMPT.format(name=name), user, max_tokens=120)
                    obj = parse_json_object(raw) if raw else None
                    if obj:
                        say, steps = validate_decision(obj, px, py)
                        if say:
                            send_reply(c, say)
                        run_plan(c, steps)

            if a.once:
                return 0
            time.sleep(a.chat_interval)
    except KeyboardInterrupt:
        pass
    finally:
        set_mode(c, "auto")
        print("[companion_driver] stopped - colonist back on the scripted brain.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
