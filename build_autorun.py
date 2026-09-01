"""Assemble <this tree's root>/build/autorun.lua from the base bridge plus the
extension modules in bridge_src/.

IMPORTANT -- this deploys ONLY within the tree this copy of the script lives
in (DEPLOY_TARGETS is built from ROOT = this file's own parent directory).
There are two independent copies of this script, one at D:/powder-toy/ and
one at D:/The-Powder-Toy/, because there are two independent trees with their
own bridge_src/ and build/. Running this script in one tree NEVER touches the
other. D:/The-Powder-Toy is the tree the live game actually loads from and
the only one that is published -- a fix made in bridge_src/ is not live, and
is not shipped, until this script has been run AND its output hand-verified
in BOTH trees. That two-copies-must-both-run fact, undocumented until now,
is exactly what let a source-level fix (PBX.MAX_CUSTOM_ELEMENTS 40->160) ship
to the public with the old value still baked into the deployed autorun.lua:
the source was fixed in both trees, but only one tree's autorun.lua was ever
regenerated. `--verify` (below) is the check that would have caught it.

Why concatenation instead of require/dofile: TPT's Lua sandbox does not
guarantee module loading from the build directory, so the shipped autorun is a
single file. Authors still get one file each; this script joins them.

Why each module is wrapped in loadstring: there is no Lua toolchain on this
machine to syntax-check with, and a compile error anywhere in a single
concatenated file would take down the entire bridge -- including the tools used
to diagnose it. Wrapping each module in its own chunk means a broken module
logs and is skipped while everything else still loads.

Usage:
    python build_autorun.py            # build, verify, deploy
    python build_autorun.py --dry-run  # build and report, write nothing
    python build_autorun.py --restore  # put the pristine base back
    python build_autorun.py --verify   # report staleness/drift, write nothing,
                                        # exit nonzero if the deployed autorun.lua
                                        # does not reflect current bridge_src/
"""

import argparse
import io
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC_DIR = ROOT / "bridge_src"
BASE_SNAPSHOT = SRC_DIR / "_base" / "bridge_base.lua"
DEPLOY_TARGETS = [
    ROOT / "build" / "autorun.lua",
    ROOT / "scripts" / "demo_create_element.lua",
]

# The base bridge's unknown-action fallthrough. Extension actions are consulted
# before it so the base never needs to know what modules exist.
PATCH_ANCHOR = (
    '        else\n'
    '            return jerr("unknown action", \',"action":\' .. jesc(action))\n'
    '        end\n'
)
PATCH_REPLACEMENT = (
    '        else\n'
    '            -- Extension dispatch: modules register into _G.PB_EXT at load time.\n'
    '            local ext = _G.PB_EXT and _G.PB_EXT[action]\n'
    '            if ext then\n'
    '                local ectx = {\n'
    '                    jok = jok, jerr = jerr, jesc = jesc, jnum = jnum,\n'
    '                    resolveElem = resolveElem, resolveWall = resolveWall,\n'
    '                    resolveTool = resolveTool,\n'
    '                }\n'
    '                local eok, eres = pcall(ext, req, ectx)\n'
    '                if eok then return eres end\n'
    '                return jerr("extension error", \',"detail":\' .. jesc(eres))\n'
    '            end\n'
    '            return jerr("unknown action", \',"action":\' .. jesc(action))\n'
    '        end\n'
)


def read(path):
    return io.open(path, encoding="utf-8").read()


def write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def ensure_base_snapshot():
    """Capture the pristine base bridge once, before it is ever overwritten.

    Every later build starts from this snapshot, so builds are idempotent and
    the extension block can never be applied twice.
    """
    if os.path.isfile(BASE_SNAPSHOT):
        return read(BASE_SNAPSHOT), False
    current = read(DEPLOY_TARGETS[0])
    if "_G.PB_EXT" in current:
        raise SystemExit(
            "refusing to snapshot: the deployed autorun already contains extension "
            "code and no pristine base snapshot exists. Restore the original by hand."
        )
    write(BASE_SNAPSHOT, current)
    return current, True


def safe_long_bracket(src):
    """Pick a long-bracket level whose closing delimiter does not occur in src."""
    for level in range(0, 12):
        eq = "=" * level
        if ("]%s]" % eq) not in src and ("[%s[" % eq) not in src:
            return "[%s[" % eq, "]%s]" % eq
    raise SystemExit("could not find a safe long-bracket level")


def wrap_module(name, src):
    """Emit one module as an isolated chunk that cannot break its neighbours."""
    open_b, close_b = safe_long_bracket(src)
    # A leading newline immediately after a long bracket is skipped by Lua, so
    # add one to keep the source's first line intact.
    return (
        "-- ==== bridge_src/%s ====\n"
        "do\n"
        "    local __src = %s\n%s\n%s\n"
        "    local __chunk, __err = loadstring(__src, %s)\n"
        "    if __chunk then\n"
        "        local __ok, __e = pcall(__chunk)\n"
        "        if not __ok then\n"
        "            local f = io.open('autorun-runtime.log', 'a')\n"
        "            if f then f:write('[loader] RUNTIME ERROR in %s: ' .. tostring(__e) .. '\\n'); f:close() end\n"
        "        end\n"
        "    else\n"
        "        local f = io.open('autorun-runtime.log', 'a')\n"
        "        if f then f:write('[loader] SYNTAX ERROR in %s: ' .. tostring(__err) .. '\\n'); f:close() end\n"
        "    end\n"
        "end\n\n"
        % (name, open_b, src, close_b, lua_quote(name), name, name)
    )


def lua_quote(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def module_files():
    if not os.path.isdir(SRC_DIR):
        return []
    names = [
        n for n in os.listdir(SRC_DIR)
        if n.endswith(".lua") and re.match(r"^\d\d_", n)
    ]
    names.sort()
    return names


# Optional extra sys.path entries holding a `lupa` build, for machines where it
# is not installed into site-packages. Separated like PATH. Empty by default:
# lua51_compile() already treats "no compiler available" as a first-class
# outcome (verified=False), so leaving this unset is not an error. Previously a
# hardcoded absolute scratchpad path, which had gone stale and never resolved.
LUA_COMPILER_LIBS = [p for p in os.environ.get("POWDER_LUA_LIBS", "").split(os.pathsep) if p]


def lua51_compile(name, src):
    """Compile src with a real Lua 5.1 parser when lupa is importable.

    Returns (verified, error). verified is False when no compiler is available,
    which is distinct from a compile failure -- the caller must not treat
    "could not check" as "checked OK".
    """
    for lib in LUA_COMPILER_LIBS:
        if os.path.isdir(lib) and lib not in sys.path:
            sys.path.insert(0, lib)
    try:
        from lupa import lua51
    except Exception:
        return False, None
    rt = lua51.LuaRuntime()
    # loadstring compiles without executing, which is exactly what we want:
    # these modules call sim.* and event.* that only exist inside TPT.
    loader = rt.eval("function(src, name) local f, e = loadstring(src, name); return f ~= nil, e end")
    ok, err = loader(src, "=" + name)
    return True, (None if ok else str(err))


def structural_check(name, src):
    """Syntax check each module before it is deployed.

    Prefers a real Lua 5.1 compile via lupa. Falls back to a cheap structural
    heuristic that catches Lua 5.2+ syntax and unbalanced block keywords; that
    fallback cannot prove the file compiles, so its OK is labelled unverified.
    """
    problems = []
    verified, err = lua51_compile(name, src)
    if verified:
        return [err] if err else [], True
    # Strip strings and comments before ANY syntax check, not just the keyword
    # count below. A string literal legitimately containing "::" (e.g. a
    # `reactive` rule spec like "...GAS::pgas=8..." in 07_materials_seed.lua)
    # or a comment merely naming a banned construct (10_registry.lua's own
    # "no goto, no `//`, no bitwise operators" reminder) is not a USE of
    # either -- checking the raw source here previously produced false
    # positives on both files that blocked a real deploy. Single
    # left-to-right pass: stripping double-quoted strings first would let a
    # quote inside a single-quoted string swallow real code.
    stripped = re.sub(
        r"--\[(=*)\[.*?\]\1\]"          # long comment
        r"|--[^\n]*"                    # line comment
        r"|\[(=*)\[.*?\]\2\]"           # long string
        r'|"(?:\\.|[^"\\\n])*"'         # double-quoted string
        r"|'(?:\\.|[^'\\\n])*'",        # single-quoted string
        " ", src, flags=re.S,
    )

    if re.search(r"(^|\s)goto(\s|$)", stripped):
        problems.append("uses 'goto' (Lua 5.2+, unsupported)")
    if re.search(r"[^/]//[^/]", stripped):
        problems.append("uses '//' (integer division, Lua 5.3+)")
    if "::" in stripped and re.search(r"::\w+::", stripped):
        problems.append("uses label syntax (Lua 5.2+)")

    # Re-use the same comment/string-stripped text for the keyword-balance
    # count below, for the identical reason: the word "end" inside a message
    # must not be counted as a block terminator.
    # 'for'/'while' are always followed by their own 'do', and 'elseif' does
    # not match \bif\b, so these three openers pair one-to-one with 'end'.
    opens = len(re.findall(r"\b(function|do|if)\b", stripped))
    ends = len(re.findall(r"\bend\b", stripped))
    # A one-line 'if ... then ... end' still balances, so a mismatch is a real signal.
    if opens != ends:
        problems.append("block keyword imbalance: %d open vs %d end" % (opens, ends))
    return problems, False


MAX_CUSTOM_ELEMENTS_RE = re.compile(r"PBX\.MAX_CUSTOM_ELEMENTS\s*=\s*(\d+)")


def _extract_max_custom_elements(text):
    m = MAX_CUSTOM_ELEMENTS_RE.search(text)
    return int(m.group(1)) if m else None


def verify_deployed():
    """Report whether the currently-DEPLOYED autorun.lua (before any rebuild)
    actually reflects the current bridge_src/ source, in this tree only.

    This is the check that would have caught tonight's incident: source can be
    fixed (bridge_src/00_util.lua raised 40->160) while the deployed artifact
    silently keeps shipping the old number, because nobody re-ran this script
    after the source change. Two things are checked, both generic rather than
    hardcoded to the one constant that actually bit us:

      1. Every module file present in bridge_src/ has a matching
         "-- ==== bridge_src/<name> ====" marker in the deployed output. A
         module added to source (like bridge_src/21_extra_kinds.lua was) but
         never folded into a rebuild is otherwise invisible: the game boots,
         logs nothing about it, and simply behaves as if the module does not
         exist.
      2. PBX.MAX_CUSTOM_ELEMENTS in bridge_src/00_util.lua matches the value
         actually embedded in the deployed file -- named explicitly because
         it is the one that shipped wrong, and a single-line regex check costs
         nothing to keep even though check #1 would also have caught the
         missing-module half of that same incident (21_extra_kinds.lua).

    Returns a list of problem strings; empty means the deployed file matches
    source. Never writes anything.
    """
    problems = []
    target = Path(DEPLOY_TARGETS[0])
    if not target.is_file():
        return ["%s does not exist -- never deployed" % target]
    deployed = read(target)

    names = module_files()
    missing = [n for n in names if ("bridge_src/%s" % n) not in deployed]
    if missing:
        problems.append(
            "deployed %s is missing %d bridge_src module(s) present on disk: %s "
            "(source was added/changed but this script was never re-run since)"
            % (target, len(missing), ", ".join(missing))
        )

    util_path = SRC_DIR / "00_util.lua"
    if util_path.is_file():
        src_cap = _extract_max_custom_elements(read(util_path))
        deployed_cap = _extract_max_custom_elements(deployed)
        if src_cap is not None and deployed_cap is not None and src_cap != deployed_cap:
            problems.append(
                "PBX.MAX_CUSTOM_ELEMENTS is %s in bridge_src/00_util.lua but %s in "
                "the deployed %s -- deployed artifact is stale"
                % (src_cap, deployed_cap, target)
            )

    return problems


def report_verify(label, problems):
    if not problems:
        print("%s: deployed autorun.lua matches current bridge_src/ -- no staleness detected" % label)
        return
    print("\n%s: DEPLOYED AUTORUN.LUA IS STALE" % label)
    for p in problems:
        print("  - %s" % p)


def build(dry_run=False):
    pre_problems = verify_deployed()
    report_verify("pre-build check", pre_problems)

    base, snapped = ensure_base_snapshot()
    if snapped:
        print("snapshotted pristine base -> %s" % BASE_SNAPSHOT)

    if PATCH_ANCHOR not in base:
        raise SystemExit("patch anchor not found in base bridge; the base has changed shape")
    patched = base.replace(PATCH_ANCHOR, PATCH_REPLACEMENT, 1)
    # The base truncates the runtime log at startup, which runs AFTER the
    # extension modules have already written their load lines.  Append instead;
    # the loader header below marks each session's start.
    patched = patched.replace('io.open("autorun-runtime.log", "w")', 'io.open("autorun-runtime.log", "a")', 1)

    names = module_files()
    if not names:
        print("WARNING: no modules found in %s" % SRC_DIR)

    header = (
        "-- ===================================================================\n"
        "-- GENERATED FILE -- do not edit.\n"
        "-- Built by D:/powder-toy/build_autorun.py from bridge_src/.\n"
        "-- Base bridge: bridge_src/_base/bridge_base.lua\n"
        "-- Each module below is loaded in its own chunk so a broken module\n"
        "-- logs to autorun-runtime.log and is skipped rather than taking the\n"
        "-- whole bridge down with it.\n"
        "-- ===================================================================\n\n"
    )

    blocks = [header]
    report = []
    for name in names:
        src = read(SRC_DIR / name)
        problems, verified = structural_check(name, src)
        report.append((name, len(src), problems, verified))
        blocks.append(wrap_module(name, src))

    blocks.append(patched)
    output = "".join(blocks)

    print("\n%-22s %8s  %s" % ("module", "bytes", "syntax check"))
    print("-" * 64)
    for name, size, problems, verified in report:
        if problems:
            status = "; ".join(problems)
        else:
            status = "compiled OK (Lua 5.1)" if verified else "ok (heuristic only, unverified)"
        print("%-22s %8d  %s" % (name, size, status))
    print("-" * 64)
    print("base %d bytes + %d modules -> %d bytes" % (len(base), len(names), len(output)))

    blocking = [(n, p) for n, _, p, _ in report if p]
    if blocking:
        print("\nSTRUCTURAL PROBLEMS FOUND:")
        for n, p in blocking:
            print("  %s: %s" % (n, "; ".join(p)))
        if not dry_run:
            raise SystemExit("refusing to deploy with structural problems; fix or use --dry-run")

    if dry_run:
        print("\n--dry-run: nothing written")
        return output

    for target in DEPLOY_TARGETS:
        target = Path(target)
        prev = Path(str(target) + ".prev")
        if target.is_file() and not prev.is_file():
            shutil.copyfile(target, prev)
        write(target, output)
        print("deployed -> %s" % target)
    print("\nRestart the game for this to take effect, then check "
          "build/autorun-runtime.log for [loader] lines.")
    return output


def restore():
    if not os.path.isfile(BASE_SNAPSHOT):
        raise SystemExit("no base snapshot to restore from")
    base = read(BASE_SNAPSHOT)
    for target in DEPLOY_TARGETS:
        write(target, base)
        print("restored -> %s" % target)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--restore", action="store_true")
    ap.add_argument("--verify", action="store_true",
                     help="report staleness of the deployed autorun.lua vs bridge_src/ and exit; write nothing")
    args = ap.parse_args()
    if args.verify:
        problems = verify_deployed()
        report_verify(str(Path(DEPLOY_TARGETS[0])), problems)
        return 1 if problems else 0
    if args.restore:
        restore()
        return 0
    build(dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
