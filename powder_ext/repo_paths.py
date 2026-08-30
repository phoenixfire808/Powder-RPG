"""Repo-root paths — single source for MCP / powder_ext (portable clone)."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
KNOWLEDGE_DIR = REPO_ROOT / "knowledge"
BUILD_DIR = REPO_ROOT / "build"
SCRIPTS_DIR = REPO_ROOT / "scripts"
BRIDGE_SRC_DIR = REPO_ROOT / "bridge_src"
