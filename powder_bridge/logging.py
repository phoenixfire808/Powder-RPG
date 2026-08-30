"""Bounded JSONL request logger for Powder Bridge.

Writes one structured event per client request. Tokens, Authorization
headers, token-file contents, and raw request bodies are never logged.
"""

from __future__ import annotations

import contextvars
import json
import os
import re
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

LOG_DIR = Path("D:/powder-toy/logs")
LOG_PATH = LOG_DIR / "powder-bridge-events.jsonl"
MAX_BYTES = 5 * 1024 * 1024
BACKUP_COUNT = 3
_LOCK = threading.Lock()
_CORRELATION_ID: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "powder_correlation_id",
    default=None,
)
_CID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")

_REDACT_KEYS = frozenset(
    {
        "token",
        "authorization",
        "password",
        "secret",
        "cookie",
        "code",
        "lua",
        "raw",
        "body",
        "powder-bridge.token",
        "api_key",
        "api_secret",
        "secret_key",
        "client_secret",
        "api_password",
        "passwd",
        "passphrase",
        "apikey",
        "pwd",
        "private_key",
        "access_key",
        "auth_key",
    }
)


def _is_secret_key(key: Any) -> bool:
    """True for credential keys. Exact aliases plus any *token* name."""
    name = str(key).lower()
    if "token" in name:
        return True
    return name in _REDACT_KEYS or name.replace("-", "_") in _REDACT_KEYS
_SUMMARY_KEYS = (
    "ok",
    "action",
    "error",
    "id",
    "count",
    "partCount",
    "placed",
    "deferred",
    "stepped",
    "killed",
    "loaded",
    "deleted",
    "field",
    "cells",
    "project",
    "succeeded",
    "failed",
    "skipped",
    "partial_mutation",
    "dry_run",
    "schema_version",
    "source_root",
    "module_count",
    "counts",
    "alive",
)


def new_correlation_id() -> str:
    """Return a compact request correlation id."""
    return uuid.uuid4().hex


def sanitize_correlation_id(value: Any) -> str | None:
    """Return a safe cid, or None if the value is missing or unsafe."""
    text = str(value or "").strip()
    if not _CID_RE.fullmatch(text):
        return None
    lowered = text.lower()
    if "token" in lowered or "secret" in lowered or "password" in lowered:
        return None
    return text


def current_correlation_id() -> str | None:
    """Return the cid bound to this task, if any."""
    return _CORRELATION_ID.get()


def bind_correlation_id(correlation_id: str | None = None) -> tuple[str, contextvars.Token[str | None]]:
    """Bind a safe cid to this task and return (cid, reset token)."""
    cid = sanitize_correlation_id(correlation_id) or new_correlation_id()
    return cid, _CORRELATION_ID.set(cid)


def reset_correlation_id(token: contextvars.Token[str | None]) -> None:
    """Restore the previous correlation binding."""
    _CORRELATION_ID.reset(token)


def resolve_correlation_id(value: Any = None) -> str:
    """Prefer the bound MCP cid, then a safe explicit cid, else mint."""
    return current_correlation_id() or sanitize_correlation_id(value) or new_correlation_id()

def _utc_ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


_TOKEN_NEEDLES: tuple[str, ...] | None = None


def _token_needles() -> tuple[str, ...]:
    global _TOKEN_NEEDLES
    if _TOKEN_NEEDLES is not None:
        return _TOKEN_NEEDLES
    found: list[str] = []
    env = os.environ.get("POWDER_BRIDGE_TOKEN")
    if env and len(env) >= 8:
        found.append(env)
    token_path = Path("D:/The-Powder-Toy/build/powder-bridge.token")
    try:
        if token_path.is_file():
            text = token_path.read_text(encoding="utf-8").strip()
            if text and len(text) >= 8:
                found.append(text)
    except OSError:
        pass
    _TOKEN_NEEDLES = tuple(dict.fromkeys(found))
    return _TOKEN_NEEDLES


def _contains_secret(text: str) -> bool:
    if not text:
        return False
    return any(needle and needle in text for needle in _token_needles())


def redact(value: Any, *, depth: int = 0) -> Any:
    """Return a copy with secrets stripped. Never raises."""
    if depth > 4:
        return "[truncated]"
    if isinstance(value, Mapping):
        out: dict[str, Any] = {}
        for key, item in value.items():
            name = str(key).lower()
            if name in _REDACT_KEYS or "token" in name:
                continue
            else:
                out[str(key)] = redact(item, depth=depth + 1)
        return out
    if isinstance(value, (list, tuple)):
        return [redact(item, depth=depth + 1) for item in value[:16]]
    if isinstance(value, str):
        if _contains_secret(value):
            return None
        if len(value) > 240:
            return value[:240] + "..."
        return value
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return str(type(value).__name__)


def strip_secrets(value: Any) -> Any:
    """Return a full-shape copy with secret keys and token values removed.

    Walks every dict and list with no depth, list-length, or string cap.
    Bounded ``redact()`` remains for log summaries only. Never raises.
    """
    try:
        return _strip_secrets(value)
    except Exception:
        return None


def _strip_secrets(value: Any) -> Any:
    if isinstance(value, Mapping):
        out: dict[str, Any] = {}
        for key, item in value.items():
            name = str(key).lower()
            if name in _REDACT_KEYS or "token" in name:
                continue
            out[str(key)] = _strip_secrets(item)
        return out
    if isinstance(value, (list, tuple)):
        return [_strip_secrets(item) for item in value]
    if isinstance(value, str):
        if _contains_secret(value):
            return None
        return value
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return str(type(value).__name__)


def summarize_response(result: Mapping[str, Any] | None) -> dict[str, Any]:
    """Keep a short, token-free response summary."""
    if not result:
        return {}
    summary: dict[str, Any] = {}
    for key in _SUMMARY_KEYS:
        if key in result:
            summary[key] = redact(result[key])
    return summary


def _rotate_unlocked(path: Path) -> None:
    if not path.is_file() or path.stat().st_size < MAX_BYTES:
        return
    oldest = Path(f"{path}.{BACKUP_COUNT}")
    if oldest.is_file():
        oldest.unlink()
    for index in range(BACKUP_COUNT, 1, -1):
        src = Path(f"{path}.{index - 1}")
        dst = Path(f"{path}.{index}")
        if src.is_file():
            src.replace(dst)
    path.replace(Path(f"{path}.1"))


def emit(
    *,
    request: str,
    action: str,
    correlation_id: str,
    phase: str,
    ok: bool,
    error: str | None,
    duration_ms: float,
    response_summary: Mapping[str, Any] | None = None,
    pid: int | None = None,
    runtime_pid: int | None = None,
    catalog_provenance: Mapping[str, Any] | None = None,
) -> None:
    """Append one structured event. Failures are swallowed so callers stay live."""
    emitter_pid = int(pid) if pid is not None else os.getpid()
    event = {
        "ts": _utc_ts(),
        "request": str(request or ""),
        "action": str(action or ""),
        "correlation_id": resolve_correlation_id(correlation_id),
        "phase": str(phase or "client"),
        "ok": bool(ok),
        "error": None if error is None or _contains_secret(str(error)) else str(error)[:240],
        "duration_ms": round(float(duration_ms), 3),
        "emitter_pid": emitter_pid,
        "runtime_pid": int(runtime_pid) if runtime_pid is not None else None,
        "pid": emitter_pid,
        "response_summary": redact(dict(response_summary or {})),
        "catalog_provenance": redact(dict(catalog_provenance)) if catalog_provenance else None,
    }
    line = json.dumps(event, ensure_ascii=True, separators=(",", ":")) + "\n"
    try:
        with _LOCK:
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            _rotate_unlocked(LOG_PATH)
            with LOG_PATH.open("a", encoding="utf-8") as handle:
                handle.write(line)
    except OSError:
        return


def read_events(limit: int = 50) -> list[dict[str, Any]]:
    """Read the newest JSONL events. Empty list if the log is missing."""
    if limit < 1:
        return []
    if not LOG_PATH.is_file():
        return []
    try:
        text = LOG_PATH.read_text(encoding="utf-8")
    except OSError:
        return []
    rows: list[dict[str, Any]] = []
    for raw in text.splitlines()[-limit:]:
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            rows.append(redact(parsed))
    return rows


def log_status() -> dict[str, Any]:
    """Machine-readable logger diagnostics. No secrets."""
    size = LOG_PATH.stat().st_size if LOG_PATH.is_file() else 0
    return {
        "ok": True,
        "log_path": str(LOG_PATH),
        "bytes": size,
        "max_bytes": MAX_BYTES,
        "backup_count": BACKUP_COUNT,
        "readable": LOG_PATH.is_file(),
        "recent_count": len(read_events(20)),
    }
