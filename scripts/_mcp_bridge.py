"""Shared HTTP-bridge call helper for the check_*.py diagnostic scripts.

Factored out once check_terrain_solid.py, check_station_reachable.py, and
this round's assert_state.py all needed the identical curl-equivalent
boilerplate -- rung 2 of the ladder, reuse instead of a 4th copy-paste.
"""
import json
import urllib.request
from pathlib import Path

BRIDGE_URL = "http://127.0.0.1:9876/"
TOKEN_PATH = Path("D:/The-Powder-Toy/build/powder-bridge.token")


def call_bridge(lua_code: str, timeout: float = 8) -> str:
    """Run `lua_code` via the game's executeLua bridge action, return its result string.
    Raises RuntimeError with the bridge's own error message on failure."""
    token = TOKEN_PATH.read_text().strip()
    body = json.dumps({"action": "executeLua", "token": token, "code": lua_code}).encode()
    req = urllib.request.Request(BRIDGE_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        result = json.loads(resp.read())
    if not result.get("ok"):
        raise RuntimeError(result.get("error"))
    return result["result"]
