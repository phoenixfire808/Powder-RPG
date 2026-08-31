"""Harvest community STRUCTURE saves (buildings, ruins, terrain features) into
knowledge/saves/, using the ISOLATED lab instance (scripts/lab_instance.py)
instead of the owner's live session.

This is a thin wrapper around scripts/save_research.py's harvest logic: same
census/logic/map4px/map1px capture, same knowledge/saves/<id>/ output, same
index.jsonl -- the only two differences are (1) it talks to the lab bridge
port/token instead of the default 9876, and (2) it drops downloaded .cps
stamps into the LAB ddir's own stamps folder (ddir redirects stamps just like
prefs/autorun -- see scripts/lab_instance.py's module docstring), never into
D:/The-Powder-Toy/build/stamps where the owner's live session reads from.

Usage (lab instance must already be running -- see lab_instance.py --launch):
    python scripts/harvest_structures.py --queries house village castle cabin ... --n 4
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path("D:/powder-toy")
sys.path.insert(0, str(ROOT))

import scripts.save_research as sr  # noqa: E402
from scripts.lab_instance import lab_client, DEFAULT_LAB_DIR  # noqa: E402

# Redirect the stamp drop location to the lab ddir's own stamps folder.
sr.STAMPS = DEFAULT_LAB_DIR / "stamps"
sr.STAMPS.mkdir(parents=True, exist_ok=True)


def main() -> int:
    sr.PowderClient = lambda: lab_client()  # type: ignore[assignment]
    return sr.main()


if __name__ == "__main__":
    sys.exit(main())
