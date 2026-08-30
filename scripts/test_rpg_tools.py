"""Offline unit tests for powder_ext/rpg_tools.py (the rpg_* MCP tools).

Every test is offline: PowderClient/execute_lua is always mocked via
``rt._get_client`` (a fake client with a configurable ``execute_lua``), so no
test starts, connects to, or requires the live Powder Toy game. rpg_search
and the static-parse path of rpg_api do read the real repo files
(scripts/lua/rpg.lua, scripts/lua/rpg_plugins/*, knowledge/*) -- that is
local disk I/O, not a game connection, and is what makes those two tools
useful in the first place.

  python scripts/test_rpg_tools.py
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
for p in (str(ROOT), str(ROOT / "scripts")):
    if p not in sys.path:
        sys.path.insert(0, p)

from powder_bridge.client import PowderAPIError, PowderConnectionError  # noqa: E402
from powder_ext import rpg_tools as rt  # noqa: E402


class _FakeClient:
    """Stand-in for PowderClient: execute_lua returns canned {"result": ...}
    dicts (or raises) from a queue, and records every code string it was
    called with so tests can assert on what Lua was actually sent.
    """

    def __init__(self, results: list[Any] | None = None) -> None:
        self._queue = list(results or [])
        self.calls: list[str] = []

    def execute_lua(self, code: str) -> dict:
        self.calls.append(code)
        if not self._queue:
            raise AssertionError("execute_lua called more times than results were queued")
        item = self._queue.pop(0)
        if isinstance(item, Exception):
            raise item
        return {"result": item}


def _patch_client(fake: _FakeClient):
    return mock.patch.object(rt, "_get_client", return_value=fake)


class RpgSearchTests(unittest.TestCase):
    """Pure file-based TF-IDF search; no bridge involved at all."""

    def test_empty_query_rejected(self) -> None:
        result = rt.HANDLERS["rpg_search"]({"query": "  "})
        self.assertFalse(result["ok"])

    def test_bad_scope_rejected(self) -> None:
        result = rt.HANDLERS["rpg_search"]({"query": "hook", "scope": "nonsense"})
        self.assertFalse(result["ok"])

    def test_finds_hits_in_rpg_lua(self) -> None:
        result = rt.HANDLERS["rpg_search"]({"query": "grappling hook accessory", "k": 5, "scope": "code"})
        self.assertTrue(result["ok"])
        self.assertGreater(result["count"], 0)
        for row in result["results"]:
            self.assertIn("file", row)
            self.assertIn("line", row)
            self.assertIn("snippet", row)
            self.assertIn("score", row)
            self.assertTrue(row["file"].lower().endswith((".lua", ".md")))

    def test_scope_code_excludes_docs_and_mechanics(self) -> None:
        result = rt.HANDLERS["rpg_search"]({"query": "the a of and", "k": 20, "scope": "code"})
        self.assertTrue(result["ok"])
        for row in result["results"]:
            self.assertTrue(row["file"].endswith(".lua") or row["file"].endswith("README.md"))

    def test_scope_mechanics_only_hits_knowledge_data_files(self) -> None:
        result = rt.HANDLERS["rpg_search"]({"query": "the a of and", "k": 20, "scope": "mechanics"})
        self.assertTrue(result["ok"])
        for row in result["results"]:
            self.assertTrue(row["file"].endswith("build-lessons.jsonl") or row["file"].endswith("playbook.json"))

    def test_results_sorted_by_descending_score(self) -> None:
        result = rt.HANDLERS["rpg_search"]({"query": "accessory equip toggle inventory", "k": 15})
        scores = [row["score"] for row in result["results"]]
        self.assertEqual(scores, sorted(scores, reverse=True))

    def test_k_is_respected(self) -> None:
        result = rt.HANDLERS["rpg_search"]({"query": "the", "k": 3, "scope": "code"})
        self.assertLessEqual(len(result["results"]), 3)

    def test_repeated_call_uses_mtime_cache_not_a_reread(self) -> None:
        """First call populates the mtime-keyed cache; a second call with no
        file changes must not re-read any file from disk.
        """
        rt._SEARCH_INDEX_CACHE["mtimes"].clear()
        rt._SEARCH_INDEX_CACHE["lines"].clear()
        first = rt.HANDLERS["rpg_search"]({"query": "hook", "k": 5})
        self.assertTrue(first["ok"])
        self.assertTrue(rt._SEARCH_INDEX_CACHE["mtimes"], "index cache should be populated after the first call")
        with mock.patch("pathlib.Path.read_text", side_effect=AssertionError("should not re-read unchanged files")):
            second = rt.HANDLERS["rpg_search"]({"query": "hook", "k": 5})
        self.assertTrue(second["ok"])
        self.assertEqual(first["count"], second["count"])


class RpgApiTests(unittest.TestCase):
    """Hook/helper/key-binding parsing is pure source parsing; the data
    tables fall back to a static parse when the bridge is unreachable.
    """

    def test_hooks_parsed_from_rpg_lua(self) -> None:
        with _patch_client(_FakeClient([PowderConnectionError("no game")])):
            result = rt.HANDLERS["rpg_api"]({})
        self.assertTrue(result["ok"])
        self.assertIn("tick", result["hooks"])
        self.assertIn("draw", result["hooks"])
        self.assertIn("key", result["hooks"])

    def test_helpers_include_documented_readme_helpers(self) -> None:
        with _patch_client(_FakeClient([PowderConnectionError("no game")])):
            result = rt.HANDLERS["rpg_api"]({})
        names = {h["name"] for h in result["helpers"]}
        # a sample from rpg_plugins/README.md's "Helpers on R" list
        for expected in ("eid", "nameOf", "has", "say", "give", "surfaceAt", "reloadPlugin"):
            self.assertIn(expected, names, f"expected helper {expected!r} in {sorted(names)}")

    def test_key_bindings_found_across_core_and_plugins(self) -> None:
        with _patch_client(_FakeClient([PowderConnectionError("no game")])):
            result = rt.HANDLERS["rpg_api"]({})
        keys = {b["key"] for b in result["key_bindings"]}
        self.assertIn("e", keys)  # bag toggle
        self.assertIn("escape", keys)

    def test_static_fallback_when_bridge_unreachable(self) -> None:
        with _patch_client(_FakeClient([PowderConnectionError("no game")])):
            result = rt.HANDLERS["rpg_api"]({})
        self.assertEqual(result["tables_source"], "static")
        self.assertIsInstance(result["tables"]["NAMES"], dict)
        self.assertIn("GOO", result["tables"]["NAMES"])
        self.assertIsInstance(result["tables"]["RECIPES"], dict)
        self.assertIn("raw_source", result["tables"]["RECIPES"])

    def test_live_path_used_when_bridge_responds(self) -> None:
        live_payload = json.dumps({
            "ok": True,
            "RECIPES": [{"out": "WORKBENCH", "n": 1}],
            "ITEMS": {}, "ACCS": {}, "QUESTS": [], "STATIONS": {},
            "NAMES": {"GOO": "Dirt"}, "MINEABLE": {"GOO": 1}, "HARD": {"GOO": 1},
        })
        with _patch_client(_FakeClient([live_payload])):
            result = rt.HANDLERS["rpg_api"]({})
        self.assertEqual(result["tables_source"], "live")
        self.assertEqual(result["tables"]["RECIPES"], [{"out": "WORKBENCH", "n": 1}])

    def test_never_raises_when_rpg_lua_unreadable(self) -> None:
        with mock.patch.object(rt, "RPG_LUA_PATH", Path("D:/does/not/exist.lua")):
            result = rt.HANDLERS["rpg_api"]({})
        self.assertFalse(result["ok"])
        self.assertIn("error", result)


class RpgStatusTests(unittest.TestCase):
    def test_reports_rpg_not_loaded(self) -> None:
        with _patch_client(_FakeClient(['{"ok":false,"error":"rpg not loaded"}'])):
            result = rt.HANDLERS["rpg_status"]({"include_fps": False})
        self.assertFalse(result["ok"])

    def test_basic_fields_pass_through(self) -> None:
        payload = json.dumps({
            "ok": True, "active": True, "paused": False, "seed": 7, "frame": 100, "day": 1, "deaths": 0,
            "player": {"x": 10.0, "y": 20.0, "depth_m": 0, "biome": "forest", "onGround": True, "face": 1},
            "hp": 100, "camera": {"x": 0, "y": 0}, "inventory": {}, "hotbar": [], "sel": 1, "tools": {},
            "acc": {}, "accOff": {}, "quest": {"index": 1, "text": "chop wood"}, "stations": [],
            "machines_count": 0, "enemies_count": 0, "pluginStatus": {}, "lastErr": "", "pluginErr": "",
            "weather": {}, "particles": 0,
        })
        with _patch_client(_FakeClient([payload])):
            result = rt.HANDLERS["rpg_status"]({"include_fps": False})
        self.assertTrue(result["ok"])
        self.assertEqual(result["seed"], 7)
        self.assertEqual(result["quest"]["text"], "chop wood")
        self.assertIsNone(result["fps"])

    def test_fps_estimated_from_two_frame_samples(self) -> None:
        payload = json.dumps({
            "ok": True, "active": True, "paused": False, "seed": 7, "frame": 1000, "day": 1, "deaths": 0,
            "player": {"x": 0, "y": 0, "depth_m": 0, "biome": "forest", "onGround": True, "face": 1},
            "hp": 100, "camera": {"x": 0, "y": 0}, "inventory": {}, "hotbar": [], "sel": 1, "tools": {},
            "acc": {}, "accOff": {}, "quest": {"index": 1, "text": ""}, "stations": [],
            "machines_count": 0, "enemies_count": 0, "pluginStatus": {}, "lastErr": "", "pluginErr": "",
            "weather": {}, "particles": 0,
        })
        fake = _FakeClient([payload, "1030"])
        with _patch_client(fake), mock.patch.object(rt.time, "sleep", return_value=None), \
             mock.patch.object(rt.time, "perf_counter", side_effect=[0.0, 1.0]):
            result = rt.HANDLERS["rpg_status"]({"include_fps": True, "fps_sample_ms": 500})
        self.assertTrue(result["ok"])
        self.assertEqual(result["fps"], 30.0)
        self.assertEqual(len(fake.calls), 2)

    def test_bad_json_from_bridge_is_reported_not_raised(self) -> None:
        with _patch_client(_FakeClient(["not json at all"])):
            result = rt.HANDLERS["rpg_status"]({"include_fps": False})
        self.assertFalse(result["ok"])
        self.assertIn("error", result)

    def test_connection_error_reported_not_raised(self) -> None:
        with _patch_client(_FakeClient([PowderConnectionError("down")])):
            result = rt.HANDLERS["rpg_status"]({"include_fps": False})
        self.assertFalse(result["ok"])


class RpgHubTests(unittest.TestCase):
    HUB_TEXT = (
        "# RPG team hub\n\n"
        "## Drew says (live comments, newest last)\n"
        "- 12:00 \"first drew comment\"\n\n"
        "## Ownership\n"
        "- stuff\n\n"
        "## Log\n"
        "- [12:01] lead: did a thing\n"
    )

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.hub_path = Path(self._tmpdir.name) / "rpg-hub.md"
        self.hub_path.write_text(self.HUB_TEXT, encoding="utf-8")
        self._patch = mock.patch.object(rt, "HUB_PATH", self.hub_path)
        self._patch.start()

    def tearDown(self) -> None:
        self._patch.stop()
        self._tmpdir.cleanup()

    def test_bad_action_rejected(self) -> None:
        result = rt.HANDLERS["rpg_hub"]({"action": "delete"})
        self.assertFalse(result["ok"])

    def test_missing_hub_file_reported(self) -> None:
        with mock.patch.object(rt, "HUB_PATH", Path("D:/does/not/exist-hub.md")):
            result = rt.HANDLERS["rpg_hub"]({"action": "read"})
        self.assertFalse(result["ok"])

    def test_read_returns_full_text(self) -> None:
        result = rt.HANDLERS["rpg_hub"]({"action": "read"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["text"], self.HUB_TEXT)
        self.assertEqual(result["total_lines"], len(self.HUB_TEXT.splitlines()))

    def test_read_tail_lines(self) -> None:
        result = rt.HANDLERS["rpg_hub"]({"action": "read", "lines": 1})
        self.assertTrue(result["ok"])
        self.assertEqual(result["text"], "- [12:01] lead: did a thing")

    def test_post_requires_text(self) -> None:
        result = rt.HANDLERS["rpg_hub"]({"action": "post"})
        self.assertFalse(result["ok"])

    def test_post_appends_formatted_line(self) -> None:
        result = rt.HANDLERS["rpg_hub"]({"action": "post", "who": "mcp", "text": "hello world"})
        self.assertTrue(result["ok"])
        content = self.hub_path.read_text(encoding="utf-8")
        self.assertTrue(content.endswith("mcp: hello world\n"))
        self.assertRegex(content.splitlines()[-1], r"^- \[\d\d:\d\d\] mcp: hello world$")

    def test_post_defaults_who_to_mcp(self) -> None:
        result = rt.HANDLERS["rpg_hub"]({"action": "post", "text": "no who given"})
        self.assertIn(": no who given", result["appended"])
        self.assertIn("mcp:", result["appended"])

    def test_drew_inserts_before_ownership_section(self) -> None:
        result = rt.HANDLERS["rpg_hub"]({"action": "drew", "text": "a new drew comment"})
        self.assertTrue(result["ok"])
        content = self.hub_path.read_text(encoding="utf-8")
        lines = content.splitlines()
        ownership_idx = next(i for i, line in enumerate(lines) if line.startswith("## Ownership"))
        # exactly one blank line separates the new bullet from "## Ownership",
        # matching the hub's existing convention (see the real file's last
        # Drew bullet -> blank line -> "## Ownership").
        self.assertEqual(lines[ownership_idx - 1], "")
        self.assertRegex(lines[ownership_idx - 2], r'^- \d\d:\d\d "a new drew comment"$')
        # the pre-existing Drew comment must still be present, untouched
        self.assertIn('- 12:00 "first drew comment"', content)

    def test_drew_errors_when_ownership_marker_missing(self) -> None:
        self.hub_path.write_text("# hub\nno ownership marker here\n", encoding="utf-8")
        result = rt.HANDLERS["rpg_hub"]({"action": "drew", "text": "x"})
        self.assertFalse(result["ok"])


class RpgReloadTests(unittest.TestCase):
    def test_bad_target_rejected(self) -> None:
        result = rt.HANDLERS["rpg_reload"]({"target": "everything"})
        self.assertFalse(result["ok"])

    def test_core_reload_sends_file_contents(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            lua_path = Path(tmp) / "rpg.lua"
            lua_path.write_text("-- fake rpg.lua\nreturn 'ok'\n", encoding="utf-8")
            fake = _FakeClient(["rpg.lua v4 loaded", '{"ok":true,"pluginStatus":{},"pluginErr":"","lastErr":""}'])
            with mock.patch.object(rt, "RPG_LUA_PATH", lua_path), _patch_client(fake):
                result = rt.HANDLERS["rpg_reload"]({"target": "core"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["result"], "rpg.lua v4 loaded")
        self.assertEqual(fake.calls[0], "-- fake rpg.lua\nreturn 'ok'\n")

    def test_plugin_name_validated(self) -> None:
        for bad_name in ("World", "world; sim.clearSim()", "../world", "", "1world"):
            result = rt.HANDLERS["rpg_reload"]({"target": "plugin", "name": bad_name})
            self.assertFalse(result["ok"], f"expected rejection for {bad_name!r}")

    def test_plugin_reload_calls_reloadPlugin_with_quoted_name(self) -> None:
        fake = _FakeClient(["ok", '{"ok":true,"pluginStatus":{"world":"ok"},"pluginErr":"","lastErr":""}'])
        with _patch_client(fake):
            result = rt.HANDLERS["rpg_reload"]({"target": "plugin", "name": "world"})
        self.assertTrue(result["ok"])
        self.assertIn('R.reloadPlugin("world")', fake.calls[0])

    def test_connection_error_reported(self) -> None:
        with _patch_client(_FakeClient([PowderConnectionError("down")])):
            result = rt.HANDLERS["rpg_reload"]({"target": "plugin", "name": "world"})
        self.assertFalse(result["ok"])


class RpgScreenshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._patch = mock.patch.object(rt, "SCREENSHOT_DDIR", Path(self._tmpdir.name))
        self._patch.start()

    def tearDown(self) -> None:
        self._patch.stop()
        self._tmpdir.cleanup()

    def _make_file(self, name: str) -> None:
        (Path(self._tmpdir.name) / name).write_bytes(b"\x89PNG\r\n")

    def test_bad_panel_rejected(self) -> None:
        result = rt.HANDLERS["rpg_screenshot"]({"panel": "nope"})
        self.assertFalse(result["ok"])

    def test_capture_without_panel(self) -> None:
        self._make_file("shot.png")
        fake = _FakeClient(["shot.png"])
        with _patch_client(fake):
            result = rt.HANDLERS["rpg_screenshot"]({})
        self.assertTrue(result["ok"])
        self.assertTrue(result["path"].endswith("shot.png"))
        self.assertEqual(len(fake.calls), 1)  # only the screenshot call, no panel toggle

    def test_capture_with_panel_opens_and_restores(self) -> None:
        self._make_file("bagshot.png")
        # open returns previous value "false", then the screenshot filename, then the restore call
        fake = _FakeClient(["false", "bagshot.png", "ok"])
        with _patch_client(fake):
            result = rt.HANDLERS["rpg_screenshot"]({"panel": "bag"})
        self.assertTrue(result["ok"])
        self.assertEqual(len(fake.calls), 3)
        self.assertIn("R.ui.bagOpen = true", fake.calls[0])
        self.assertIn("R.ui.bagOpen = false", fake.calls[2])  # restored to the previous (false) value

    def test_restore_still_happens_when_screenshot_call_fails(self) -> None:
        fake = _FakeClient(["false", PowderConnectionError("boom"), "ok"])
        with _patch_client(fake):
            result = rt.HANDLERS["rpg_screenshot"]({"panel": "menu"})
        self.assertFalse(result["ok"])
        self.assertEqual(len(fake.calls), 3)  # open, failed capture, restore (still ran)
        self.assertIn("R.menuOpen = false", fake.calls[2])

    def test_missing_rpg_reported(self) -> None:
        fake = _FakeClient(["no-rpg"])
        with _patch_client(fake):
            result = rt.HANDLERS["rpg_screenshot"]({"panel": "quests"})
        self.assertFalse(result["ok"])

    def test_file_never_appearing_is_reported_not_hung(self) -> None:
        fake = _FakeClient(["never-written.png"])
        with _patch_client(fake), mock.patch.object(rt.time, "sleep", return_value=None):
            result = rt.HANDLERS["rpg_screenshot"]({})
        self.assertFalse(result["ok"])
        self.assertIn("not found", result["error"])


class RpgLuaTests(unittest.TestCase):
    def test_empty_code_rejected(self) -> None:
        result = rt.HANDLERS["rpg_lua"]({"code": "   "})
        self.assertFalse(result["ok"])

    def test_destructive_snippet_refused_by_default(self) -> None:
        for snippet in ("sim.clearSim()", "R.load(nil, true) -- loadSave", "R.pendingGen = 5"):
            result = rt.HANDLERS["rpg_lua"]({"code": snippet})
            self.assertFalse(result["ok"], f"expected refusal for {snippet!r}")
            self.assertIn("matched", result)

    def test_destructive_snippet_allowed_when_flagged(self) -> None:
        fake = _FakeClient(["done"])
        with _patch_client(fake):
            result = rt.HANDLERS["rpg_lua"]({"code": "sim.clearSim()", "allow_destructive": True})
        self.assertTrue(result["ok"])

    def test_benign_code_prepends_r_alias(self) -> None:
        fake = _FakeClient(["42"])
        with _patch_client(fake):
            result = rt.HANDLERS["rpg_lua"]({"code": "return tostring(R.hp)"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["result"], "42")
        self.assertTrue(fake.calls[0].startswith("local R = PBX.state.rpg\n"))

    def test_connection_error_reported_not_raised(self) -> None:
        with _patch_client(_FakeClient([PowderConnectionError("down")])):
            result = rt.HANDLERS["rpg_lua"]({"code": "return 1"})
        self.assertFalse(result["ok"])


class HandlersNeverRaiseTests(unittest.TestCase):
    """Every handler is wrapped by _guarded; garbage input must come back as
    {"ok": False, ...}, never an exception, matching every other tool module.
    """

    def test_garbage_arguments_never_raise(self) -> None:
        for name, handler in rt.HANDLERS.items():
            with self.subTest(tool=name):
                result = handler(None)  # type: ignore[arg-type]
                self.assertIsInstance(result, dict)
                self.assertIn("ok", result)
                result2 = handler({"totally": "unexpected", "shape": 123})
                self.assertIsInstance(result2, dict)


if __name__ == "__main__":
    unittest.main(verbosity=2)
