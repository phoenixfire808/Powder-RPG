"""Offline unit tests for the research-round-3 additions (2026-08-26):

  * powder_ext/agent_tools.py: module_retrieve/module_search (Ollama embeddings
    with a stdlib TF-IDF fallback), gate_modules/missing_elements_for_module
    (precondition gate), record_attempt's decomposed score + sampling metadata.
  * scripts/passk_harness.py: structural-signature dedup, the Wilson interval,
    the optional expected-element check, and the attempts-sft.jsonl writer.
  * knowledge/tasks-basic.json: the golden-task file shape.

Every test is offline: the Ollama HTTP call is mocked (never touches a real
socket), and the live-custom-element / catalog calls used by the precondition
gate are monkeypatched to fixed fixtures so results do not depend on whether
Powder Toy happens to be running. No test starts, connects to, or requires
the game.

  python scripts/test_agent_tools.py
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
for p in (str(ROOT), str(ROOT / "scripts")):
    if p not in sys.path:
        sys.path.insert(0, p)

from powder_ext import agent_tools as at  # noqa: E402
from powder_ext import blueprint_tools as bt  # noqa: E402
import passk_harness as pk  # noqa: E402


class ModuleRetrieveFallbackTests(unittest.TestCase):
    """No Ollama reachable -> module_retrieve/module_search must still work via TF-IDF."""

    def test_tfidf_fallback_when_ollama_unreachable(self) -> None:
        with mock.patch("urllib.request.urlopen", side_effect=OSError("connection refused")):
            result = at.module_retrieve("a sealed pressure chamber with a wall boundary", k=5)
        self.assertTrue(result["ok"])
        self.assertEqual(result["method"], "tfidf")
        self.assertEqual(result["count"], 5)
        names = [m["name"] for m in result["modules"]]
        # pressure_chamber's own "why"/params text is the closest lexical match
        self.assertIn("pressure_chamber", names)

    def test_explicit_names_always_kept(self) -> None:
        with mock.patch("urllib.request.urlopen", side_effect=OSError("connection refused")):
            result = at.module_retrieve("wifi lamp signal", k=2, explicit=["pressure_chamber"])
        names = [m["name"] for m in result["modules"]]
        self.assertIn("pressure_chamber", names)
        self.assertTrue(any(m["explicit"] for m in result["modules"] if m["name"] == "pressure_chamber"))

    def test_unknown_explicit_name_is_ignored_not_erroring(self) -> None:
        with mock.patch("urllib.request.urlopen", side_effect=OSError("connection refused")):
            result = at.module_retrieve("anything", k=3, explicit=["not_a_real_module"])
        self.assertTrue(result["ok"])
        self.assertNotIn("not_a_real_module", [m["name"] for m in result["modules"]])

    def test_module_search_handler_rejects_empty_query(self) -> None:
        result = at.HANDLERS["module_search"]({"query": ""})
        self.assertFalse(result["ok"])

    def test_module_search_handler_offline(self) -> None:
        with mock.patch("urllib.request.urlopen", side_effect=OSError("connection refused")):
            result = at.HANDLERS["module_search"]({"query": "insulated heat source", "k": 4})
        self.assertTrue(result["ok"])
        self.assertEqual(result["tool"], "module_retrieve")
        self.assertLessEqual(len(result["modules"]), 4)

    def test_ranking_prefers_lexically_relevant_module_over_full_dump(self) -> None:
        """The whole point of retrieval-shortlisting: top-k should be much
        smaller than the full registry, and it should actually change with
        the query rather than being a fixed prefix.
        """
        with mock.patch("urllib.request.urlopen", side_effect=OSError("connection refused")):
            r1 = at.module_retrieve("a cryo dewar of liquid helium with insulation", k=3)
            r2 = at.module_retrieve("a wifi node lighting an lcry lamp", k=3)
        names1 = [m["name"] for m in r1["modules"]]
        names2 = [m["name"] for m in r2["modules"]]
        self.assertNotEqual(names1, names2)
        self.assertGreater(r1["total_modules"], 20)  # the registry really is large


class ModuleRetrieveEmbeddingTests(unittest.TestCase):
    """A mocked Ollama /api/embeddings success should be preferred (method=="embeddings")."""

    def test_embedding_path_used_when_ollama_responds(self) -> None:
        def fake_urlopen(req, timeout=3.0):  # noqa: ARG001
            body = json.loads(req.data.decode("utf-8"))
            text = body["prompt"]
            # a toy 3-dim embedding: closer to "tank"-ish text on dim 0
            vec = [1.0, 0.0, 0.0] if "tank" in text.lower() or "water" in text.lower() or "seal" in text.lower() else [0.0, 1.0, 0.0]
            payload = json.dumps({"embedding": vec}).encode("utf-8")

            class _Resp:
                def __enter__(self):
                    return self

                def __exit__(self, *a):
                    return False

                def read(self):
                    return payload

            return _Resp()

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = at.module_retrieve("a sealed water tank", k=3)
        self.assertEqual(result["method"], "embeddings")
        self.assertTrue(result["ok"])

    def test_falls_back_when_embedding_response_is_malformed(self) -> None:
        def fake_urlopen(req, timeout=3.0):  # noqa: ARG001
            payload = json.dumps({"nope": "not an embedding"}).encode("utf-8")

            class _Resp:
                def __enter__(self):
                    return self

                def __exit__(self, *a):
                    return False

                def read(self):
                    return payload

            return _Resp()

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = at.module_retrieve("anything at all", k=3)
        self.assertEqual(result["method"], "tfidf")
        self.assertTrue(result["ok"])


class GateModulesTests(unittest.TestCase):
    """Precondition gate: a registry module referencing a not-yet-defined
    custom element must be reported unavailable; builtins are always available.
    """

    FAKE_REGISTRY = {
        "needs_custom": {
            "name": "needs_custom", "why": "test fixture", "params": {},
            "parts": [{"box": "ZZZZ", "at": [0, 0], "size": [1, 1]}],
        },
        "stock_only": {
            "name": "stock_only", "why": "test fixture", "params": {},
            "parts": [{"box": "WATR", "at": [0, 0], "size": [1, 1]}],
        },
    }
    FAKE_CATALOGS = {"elements": {"WATR", "BRCK", "METL"}, "walls": {"WALL", "AIR"}}

    def test_missing_when_element_not_native_and_not_live(self) -> None:
        with mock.patch.object(bt, "_json_module_registry", return_value=self.FAKE_REGISTRY), \
             mock.patch.object(bt, "_catalogs", return_value=self.FAKE_CATALOGS), \
             mock.patch.object(bt, "_custom_elements", return_value=set()):
            missing = at.missing_elements_for_module("needs_custom")
            self.assertEqual(missing, ["ZZZZ"])
            self.assertEqual(at.missing_elements_for_module("stock_only"), [])

    def test_available_once_custom_element_is_live(self) -> None:
        with mock.patch.object(bt, "_json_module_registry", return_value=self.FAKE_REGISTRY), \
             mock.patch.object(bt, "_catalogs", return_value=self.FAKE_CATALOGS), \
             mock.patch.object(bt, "_custom_elements", return_value={"ZZZZ"}):
            self.assertEqual(at.missing_elements_for_module("needs_custom"), [])

    def test_builtin_modules_always_available(self) -> None:
        with mock.patch.object(bt, "_json_module_registry", return_value=self.FAKE_REGISTRY), \
             mock.patch.object(bt, "_catalogs", return_value=self.FAKE_CATALOGS), \
             mock.patch.object(bt, "_custom_elements", return_value=set()):
            self.assertEqual(at.missing_elements_for_module("pressure_chamber"), [])

    def test_gate_modules_splits_available_and_unavailable(self) -> None:
        with mock.patch.object(bt, "_json_module_registry", return_value=self.FAKE_REGISTRY), \
             mock.patch.object(bt, "_catalogs", return_value=self.FAKE_CATALOGS), \
             mock.patch.object(bt, "_custom_elements", return_value=set()):
            gate = at.gate_modules(["needs_custom", "stock_only", "tank"])
        self.assertEqual(sorted(gate["available"]), ["stock_only", "tank"])
        self.assertEqual(gate["unavailable"], {"needs_custom": ["ZZZZ"]})

    def test_gate_modules_never_raises_when_live_state_unreachable(self) -> None:
        """_custom_elements() returning empty (game unreachable) must degrade
        to "conservatively unavailable", never an exception.
        """
        with mock.patch.object(bt, "_json_module_registry", return_value=self.FAKE_REGISTRY), \
             mock.patch.object(bt, "_catalogs", return_value=self.FAKE_CATALOGS), \
             mock.patch.object(bt, "_custom_elements", return_value=set()):
            gate = at.gate_modules(["needs_custom"])
        self.assertIn("needs_custom", gate["unavailable"])


class RecordAttemptScoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._patch = mock.patch.object(at, "ATTEMPTS", Path(self._tmpdir.name) / "attempts.jsonl")
        self._patch.start()

    def tearDown(self) -> None:
        self._patch.stop()
        self._tmpdir.cleanup()

    def test_score_and_sampling_metadata_round_trip(self) -> None:
        res = at.HANDLERS["record_attempt"]({
            "goal": "test goal", "verdict": "pass", "model": "qwen2.5:1.5b",
            "score": {"compiles": True, "lint_critical": 0, "lint_total": 2, "verify_pass": True},
            "temperature": 0.4, "round_no": 1, "resample_no": 0,
        })
        self.assertTrue(res["ok"])
        rec = json.loads(at.ATTEMPTS.read_text(encoding="utf-8").splitlines()[-1])
        self.assertEqual(rec["score"], {"compiles": True, "lint_critical": 0, "lint_total": 2, "verify_pass": True})
        self.assertEqual(rec["temperature"], 0.4)
        self.assertEqual(rec["round_no"], 1)
        self.assertEqual(rec["resample_no"], 0)

    def test_missing_score_and_metadata_default_to_none(self) -> None:
        """Old-style calls (no score/temperature/round_no/resample_no) must
        keep working exactly as before -- purely additive change.
        """
        res = at.HANDLERS["record_attempt"]({"goal": "legacy call", "verdict": "fail"})
        self.assertTrue(res["ok"])
        rec = json.loads(at.ATTEMPTS.read_text(encoding="utf-8").splitlines()[-1])
        self.assertIsNone(rec["score"])
        self.assertIsNone(rec["temperature"])
        self.assertIsNone(rec["round_no"])
        self.assertIsNone(rec["resample_no"])

    def test_malformed_score_is_dropped_not_erroring(self) -> None:
        res = at.HANDLERS["record_attempt"]({"goal": "bad score", "verdict": "fail", "score": "not a dict"})
        self.assertTrue(res["ok"])
        rec = json.loads(at.ATTEMPTS.read_text(encoding="utf-8").splitlines()[-1])
        self.assertIsNone(rec["score"])


class PassKDedupTests(unittest.TestCase):
    def test_canonical_signature_ignores_ids_but_not_values(self) -> None:
        bp_a = {"name": "a", "origin": [0, 0], "parts": [{"id": "x", "box": "WATR", "at": [0, 0], "size": [2, 2]}]}
        bp_b = {"name": "b", "origin": [0, 0], "parts": [{"id": "y", "box": "WATR", "at": [0, 0], "size": [2, 2]}]}
        bp_c = {"name": "c", "origin": [0, 0], "parts": [{"id": "y", "box": "WATR", "at": [1, 0], "size": [2, 2]}]}
        self.assertEqual(pk.canonical_signature(bp_a), pk.canonical_signature(bp_b))
        self.assertNotEqual(pk.canonical_signature(bp_a), pk.canonical_signature(bp_c))

    def test_canonical_signature_none_for_bad_input(self) -> None:
        self.assertIsNone(pk.canonical_signature(None))
        self.assertIsNone(pk.canonical_signature({"name": "no parts"}))

    def test_wilson_interval_bounds_and_monotonicity(self) -> None:
        lo0, hi0 = pk.wilson_interval(0, 0)
        self.assertEqual((lo0, hi0), (0.0, 1.0))
        lo_all, hi_all = pk.wilson_interval(5, 5)
        self.assertGreater(hi_all, lo_all)
        self.assertLessEqual(hi_all, 1.0)
        lo_none, hi_none = pk.wilson_interval(0, 5)
        self.assertGreaterEqual(lo_none, 0.0)
        # more trials at a fixed success rate should narrow the interval
        lo_small, hi_small = pk.wilson_interval(1, 2)
        lo_big, hi_big = pk.wilson_interval(50, 100)
        self.assertLess(hi_big - lo_big, hi_small - lo_small)

    def test_check_expected_flags_missing_elements(self) -> None:
        res = {"preview": [{"element": "WATR"}], "primitive_count": 1}
        out = pk.check_expected(res, {"elements": {"WATR": 2}})
        self.assertFalse(out["ok"])
        self.assertTrue(out["problems"])

    def test_check_expected_no_expected_block(self) -> None:
        self.assertEqual(pk.check_expected({}, None), {"checked": False})

    def test_append_sft_row_writes_expected_shape(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sft_path = Path(tmp) / "attempts-sft.jsonl"
            with mock.patch.object(pk, "ATTEMPTS_SFT", sft_path):
                pk.append_sft_row("build a tank", {"name": "t", "origin": [0, 0], "parts": []}, "pass", ["ok"])
            rows = [json.loads(line) for line in sft_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(set(row.keys()), {"prompt", "completion", "verdict", "verifier_feedback"})
        self.assertEqual(row["prompt"], "build a tank")
        self.assertEqual(json.loads(row["completion"]), {"name": "t", "origin": [0, 0], "parts": []})
        self.assertEqual(row["verdict"], "pass")


class GoldenTasksFileTests(unittest.TestCase):
    def test_tasks_basic_has_ten_tasks_with_expected_blocks(self) -> None:
        path = ROOT / "knowledge" / "tasks-basic.json"
        self.assertTrue(path.is_file(), f"missing {path}")
        tasks = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(len(tasks), 10)
        names = set()
        for t in tasks:
            self.assertIn("name", t)
            self.assertIn("request", t)
            self.assertIsInstance(t["request"], str)
            self.assertTrue(t["request"].strip())
            names.add(t["name"])
            self.assertIn("expected", t, f"{t['name']} should carry an expected-element block")
        self.assertEqual(len(names), 10, "task names must be unique")


if __name__ == "__main__":
    unittest.main(verbosity=2)
