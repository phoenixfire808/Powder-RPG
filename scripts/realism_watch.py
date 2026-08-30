"""Poll the live Powder Bridge for a fresh powder.exe session and re-apply the
realism persistence layer (behaviour kinds + stock patch + power set +
materials catalog) automatically. See knowledge/REALISM_RUNBOOK.md.

A "fresh session" is detected two independent ways, either is sufficient:

  1. bridge_src/90_realism_boot.lua persists a boot counter to
     pbx-realism_boot.json once per restart (read here via PBX.load through
     executeLua); when it differs from the last value this watcher saw, the
     game restarted.
  2. list_custom_elements reports 0 live custom elements while the materials
     catalog has priority-1 entries that should exist -- covers a session
     where the marker file itself did not survive (e.g. the build directory
     was cleaned, or 90_realism_boot.lua has not been deployed yet).

Every poll is read-only (executeLua running a `return`-only PBX.load, and
listCustomElements). Only when a fresh session is detected does this script
call powder_ext.realism_tools.realism_apply, which is the one thing here that
can mutate the live sim (unless --dry-run is passed, in which case
realism_apply itself never mutates either -- see its own docstring).

State (last-seen boot_count / custom_count) persists to a small JSON file
(default logs/realism_watch_state.json) so restarting this watcher does not
re-trigger a redundant apply.

Usage:
    python scripts/realism_watch.py                  # run forever, poll every 10s, apply for real
    python scripts/realism_watch.py --interval 5      # custom poll interval
    python scripts/realism_watch.py --once            # one check-and-maybe-apply pass, then exit
    python scripts/realism_watch.py --dry-run         # never mutates; logs what realism_apply WOULD do
    python scripts/realism_watch.py --profile power   # only re-apply one realism_apply profile
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, "D:/powder-toy")

from powder_bridge.client import PowderAPIError, PowderClient, PowderConnectionError  # noqa: E402
from powder_ext import realism_tools  # noqa: E402

DEFAULT_STATE_PATH = Path("D:/powder-toy/logs/realism_watch_state.json")

# Read-only: PBX.load never mutates, and the trailing `return` is the only
# side effect of this executeLua call.
_MARKER_LUA = (
    'local t = PBX.load("realism_boot") '
    'if type(t) == "table" and t.boot_count then return tostring(t.boot_count) end '
    'return ""'
)


def _log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {msg}", flush=True)


def _load_state(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=1, sort_keys=True), encoding="utf-8")


def poll(client: PowderClient) -> dict[str, Any]:
    """One read-only snapshot: boot marker + live custom element count.

    Never raises: an unreachable bridge (game not running / mid-restart)
    comes back as ``{"reachable": False, ...}`` so the caller just skips a
    cycle instead of crashing the loop.
    """
    out: dict[str, Any] = {"boot_count": None, "custom_count": None, "reachable": False}
    try:
        res = client.execute_lua(_MARKER_LUA)
    except (PowderAPIError, PowderConnectionError):
        return out
    out["reachable"] = True
    raw = res.get("result")
    if isinstance(raw, str) and raw.strip().isdigit():
        out["boot_count"] = int(raw)
    try:
        listing = client._post({"action": "listCustomElements"})
        elements = listing.get("elements")
        if isinstance(elements, list):
            out["custom_count"] = len(elements)
    except (PowderAPIError, PowderConnectionError):
        pass
    return out


def _catalog_expects_entries() -> bool:
    try:
        cat = json.loads(realism_tools.CATALOG_PATH.read_text(encoding="utf-8"))["entries"]
    except (OSError, json.JSONDecodeError, KeyError):
        return False
    return any(int(e.get("priority", 9)) <= 1 for e in cat)


def check_once(
    client: PowderClient,
    state: dict[str, Any],
    *,
    profile: str,
    dry_run: bool,
) -> dict[str, Any]:
    """Poll once, apply if a fresh session was detected, and return updated state."""
    snapshot = poll(client)
    if not snapshot["reachable"]:
        _log("bridge unreachable; skipping this cycle")
        return state

    is_first_run = "last_boot_count" not in state and "last_custom_count" not in state
    last_boot_count = state.get("last_boot_count")
    marker_changed = (
        not is_first_run
        and snapshot["boot_count"] is not None
        and snapshot["boot_count"] != last_boot_count
    )
    zero_but_expected = (
        not is_first_run
        and snapshot["custom_count"] == 0
        and _catalog_expects_entries()
    )

    if is_first_run:
        _log(
            f"first run: seeding state (boot_count={snapshot['boot_count']}, "
            f"custom_count={snapshot['custom_count']}); not applying"
        )
    elif marker_changed or zero_but_expected:
        reason = (
            "boot marker changed"
            if marker_changed
            else "custom element count is 0 while the catalog expects entries"
        )
        _log(f"fresh session detected ({reason}); calling realism_apply(profile={profile!r}, dry_run={dry_run})")
        result = realism_tools.realism_apply({"profile": profile, "dry_run": dry_run})
        step_summary = {
            name: {k: v for k, v in step.items() if k != "files" and k != "raw_result"}
            for name, step in (result.get("steps") or {}).items()
            if isinstance(step, dict)
        }
        state["last_apply"] = {
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "reason": reason,
            "dry_run": dry_run,
            "ok": result.get("ok"),
            "steps": step_summary,
        }
        _log(f"realism_apply ok={result.get('ok')} steps={step_summary}")
    else:
        _log(f"no change (boot_count={snapshot['boot_count']}, custom_count={snapshot['custom_count']})")

    if snapshot["boot_count"] is not None:
        state["last_boot_count"] = snapshot["boot_count"]
    state["last_custom_count"] = snapshot["custom_count"]
    state["last_checked"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return state


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--interval", type=float, default=10.0, help="poll interval in seconds (default 10)")
    ap.add_argument("--once", action="store_true", help="run a single check-and-maybe-apply pass, then exit")
    ap.add_argument("--dry-run", action="store_true", help="never mutate; pass dry_run=True to realism_apply")
    ap.add_argument("--profile", default="all", choices=["all", "stock", "power", "materials", "kinds"])
    ap.add_argument("--state-file", default=str(DEFAULT_STATE_PATH))
    args = ap.parse_args(argv)

    state_path = Path(args.state_file)
    client = PowderClient()
    state = _load_state(state_path)
    _log(
        f"realism_watch starting: interval={args.interval}s profile={args.profile} "
        f"dry_run={args.dry_run} state={state_path}"
    )

    try:
        while True:
            state = check_once(client, state, profile=args.profile, dry_run=args.dry_run)
            _save_state(state_path, state)
            if args.once:
                break
            time.sleep(args.interval)
    except KeyboardInterrupt:
        _log("stopped by user")
    return 0


if __name__ == "__main__":
    sys.exit(main())
