"""Prepare (and optionally launch) a SECOND, isolated powder.exe instance so
experiments never collide with the owner's live session.

Background (knowledge/research-tooling-2026-08-26.md, section (a) and change
#2/#3): `ddir:DIRECTORY` chdir's powder.exe into DIRECTORY before anything
else runs, so prefs/stamps/autorun.lua/powder-bridge.token are all read from
DIRECTORY instead of the default `D:/The-Powder-Toy/build`. That is enough to
run a second, fully isolated instance side by side with the owner's -- as long as
it also gets its own bridge port and token, since `bridge_src/_base/
bridge_base.lua` used to hardcode port 9876. It now reads
`POWDER_BRIDGE_PORT` from the environment first (falling back to 9876 so
the owner's normal launch is unaffected), which is the only change this script
depends on.

`powder_bridge.client.PowderClient` already supports a distinct host/port/
token per instance (`PowderClient(port=..., token=...)`), so the Python side
needed no changes at all -- see `lab_client()` below.

IMPORTANT process-launch quirk (see launch_powder.ps1's own comment): TPT
parses argv with SplitBy(':') BEFORE SplitBy('='), so a colon-form
`ddir:D:\\The-Powder-Toy\\build` breaks on the drive-letter colon (it becomes
key='ddir=D' value='\\The-Powder-Toy\\build'). The working two-arg form is
`powder.exe ddir <DIR>` (two separate argv entries), which is what `launch()`
below uses. The process's *working directory* must stay
`D:/The-Powder-Toy/build` (where the DLLs live) even though `ddir` points
elsewhere -- also matched from launch_powder.ps1.

What this script does NOT do: it never touches the owner's deployed autorun.lua,
prefs, or token (`build_autorun.build(dry_run=True)` only returns the
assembled text; nothing under `D:/The-Powder-Toy/build` is written), and it
never launches anything unless `--launch` is passed explicitly.

Usage
-----
    # 1. one-time (or whenever bridge_src/ changes): assemble the lab ddir
    #    (autorun.lua + a fresh random token + a blank prefs file) without
    #    touching the owner's session or starting any process:
    python scripts/lab_instance.py --setup

    # 2. inspect what would launch, still without starting anything:
    python scripts/lab_instance.py --setup --print-launch-command

    # 3. actually start the second instance (NOT done by this task on
    #    purpose -- run this yourself when you want a lab session):
    python scripts/lab_instance.py --setup --launch

    # 4. from Python, once the lab instance is running, talk to it exactly
    #    like the normal PowderClient:
    #    from scripts.lab_instance import lab_client
    #    lab = lab_client()               # reads port + token from the meta file
    #    lab.is_alive()

Everything defaults to a lab ddir at D:/powder-toy/lab_instance/ddir and port
9877; override with --dir/--port. Re-running --setup is idempotent except for
the token, which is regenerated every time (pass --keep-token to reuse the
existing one, e.g. so a long-running lab client doesn't need reconnecting).
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path("D:/powder-toy")
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import build_autorun  # noqa: E402  (D:/powder-toy/build_autorun.py)
from powder_bridge.client import PowderClient  # noqa: E402

DEFAULT_LAB_DIR = ROOT / "lab_instance" / "ddir"
DEFAULT_PORT = 9877
EXE_DIR = Path("D:/The-Powder-Toy/build")
TEMPLATE_PREF = ROOT / "ddir-empty" / "powder.pref"
META_FILENAME = "lab_instance_meta.json"
TOKEN_FILENAME = "powder-bridge.token"
AUTORUN_FILENAME = "autorun.lua"

# `disable-network` (report section (a)): a lab instance never needs to hit
# powdertoy.co.uk, and this keeps it from ever touching the owner's online saves.
DEFAULT_EXTRA_ARGS: tuple[str, ...] = ("disable-network", "scale:1")


def _meta_path(lab_dir: Path) -> Path:
    return lab_dir / META_FILENAME


def prepare(
    lab_dir: Path = DEFAULT_LAB_DIR,
    port: int = DEFAULT_PORT,
    *,
    keep_token: bool = False,
) -> dict[str, Any]:
    """Assemble a lab ddir: autorun.lua, a fresh token, and a blank prefs file.

    Never touches anything under D:/The-Powder-Toy/build. Safe to call
    repeatedly -- each call re-assembles autorun.lua from the current
    bridge_src/ (so a lab instance always runs the latest extension code) and
    by default rotates the token (pass keep_token=True to reuse one already
    on disk, e.g. across repeated --setup calls for the same running lab
    instance).
    """
    lab_dir = Path(lab_dir)
    lab_dir.mkdir(parents=True, exist_ok=True)

    if TEMPLATE_PREF.is_file():
        shutil.copyfile(TEMPLATE_PREF, lab_dir / "powder.pref")

    # dry_run=True only returns the assembled autorun.lua text -- it never
    # writes to build_autorun.DEPLOY_TARGETS (the owner's deployed autorun.lua),
    # so this cannot affect the owner's live session.
    autorun_text = build_autorun.build(dry_run=True)
    (lab_dir / AUTORUN_FILENAME).write_text(autorun_text, encoding="utf-8", newline="\n")

    token_path = lab_dir / TOKEN_FILENAME
    if keep_token and token_path.is_file():
        token = token_path.read_text(encoding="utf-8").strip()
    else:
        token = secrets.token_urlsafe(32)
        token_path.write_text(token, encoding="utf-8")

    meta = {
        "ddir": str(lab_dir),
        "port": int(port),
        "token_path": str(token_path),
        "exe_dir": str(EXE_DIR),
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    _meta_path(lab_dir).write_text(json.dumps(meta, indent=1), encoding="utf-8")
    return meta


def launch_command(lab_dir: Path = DEFAULT_LAB_DIR, extra_args: tuple[str, ...] = DEFAULT_EXTRA_ARGS) -> list[str]:
    """The exact argv that will be spawned -- two-arg ddir form (see module docstring)."""
    return [str(EXE_DIR / "powder.exe"), "ddir", str(lab_dir), *extra_args]


def launch(
    lab_dir: Path = DEFAULT_LAB_DIR,
    port: int = DEFAULT_PORT,
    *,
    extra_args: tuple[str, ...] = DEFAULT_EXTRA_ARGS,
) -> subprocess.Popen:
    """Start the second powder.exe. Call prepare() first (or pass a lab_dir
    that already has an autorun.lua + token from a prior prepare() call).

    The working directory is EXE_DIR (D:/The-Powder-Toy/build), matching
    launch_powder.ps1's own comment that the DLLs must be resolved from
    there; `ddir` alone is what redirects data-file reads to lab_dir.
    POWDER_BRIDGE_PORT is set only in the child's environment, so the owner's own
    session (already running, already loaded into memory) is unaffected.
    """
    if not (Path(lab_dir) / TOKEN_FILENAME).is_file():
        raise SystemExit(f"no token in {lab_dir} -- run prepare()/--setup first")
    env = dict(os.environ)
    env["POWDER_BRIDGE_PORT"] = str(port)
    return subprocess.Popen(
        launch_command(lab_dir, extra_args),
        cwd=str(EXE_DIR),
        env=env,
    )


def lab_client(
    lab_dir: Path = DEFAULT_LAB_DIR,
    port: int | None = None,
    *,
    host: str = "127.0.0.1",
    timeout: float = 10.0,
) -> PowderClient:
    """Build a PowderClient pointed at the lab instance's port/token.

    Reads the token straight from the lab ddir (falls back to the port
    recorded in lab_instance_meta.json when port is not given); does not
    require the lab instance to already be running.
    """
    lab_dir = Path(lab_dir)
    token_path = lab_dir / TOKEN_FILENAME
    if not token_path.is_file():
        raise SystemExit(f"no token in {lab_dir} -- run prepare()/--setup first")
    token = token_path.read_text(encoding="utf-8").strip()
    if port is None:
        meta_path = _meta_path(lab_dir)
        if meta_path.is_file():
            port = int(json.loads(meta_path.read_text(encoding="utf-8")).get("port", DEFAULT_PORT))
        else:
            port = DEFAULT_PORT
    return PowderClient(host=host, port=port, token=token, timeout=timeout)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=str(DEFAULT_LAB_DIR), help="Lab ddir (default: %(default)s)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="Lab bridge port (default: %(default)s)")
    ap.add_argument("--setup", action="store_true", help="Assemble autorun.lua + token + prefs in --dir")
    ap.add_argument("--keep-token", action="store_true", help="Reuse an existing token instead of rotating it")
    ap.add_argument("--print-launch-command", action="store_true", help="Print the argv that --launch would run, then exit")
    ap.add_argument(
        "--launch", action="store_true",
        help="Actually start the second powder.exe (requires --setup to have run at least once for --dir)",
    )
    args = ap.parse_args()

    lab_dir = Path(args.dir)

    if not args.setup and not args.launch and not args.print_launch_command:
        ap.print_help()
        return 0

    if args.setup:
        meta = prepare(lab_dir, args.port, keep_token=args.keep_token)
        print(f"prepared lab ddir -> {meta['ddir']}")
        print(f"  autorun.lua from bridge_src/ (dry_run assembly, nothing deployed to the owner's session)")
        print(f"  token       -> {meta['token_path']}")
        print(f"  port        -> {meta['port']} (set via POWDER_BRIDGE_PORT at launch time)")

    if args.print_launch_command:
        print(" ".join(launch_command(lab_dir)))
        print(f"  (cwd={EXE_DIR}, env POWDER_BRIDGE_PORT={args.port})")

    if args.launch:
        proc = launch(lab_dir, args.port)
        print(f"LAUNCHED_PID={proc.pid}")
        print(f"connect with: PowderClient(port={args.port}, token=open(r'{lab_dir / TOKEN_FILENAME}').read().strip())")
        print(f"  or: from scripts.lab_instance import lab_client; lab_client(r'{lab_dir}', {args.port})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
