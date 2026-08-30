# Powder RPG — Standing Engineering Protocol

This file is read automatically at the start of every session in this project. It is the
permanent, mandatory operating protocol for all work here — not a suggestion.

## Never start from zero
Before acting, read `knowledge/TODO.md` (append-only, never delete entries, never mark `[x]`
unless Drew has personally confirmed something live) and `knowledge/rpg-hub.md` (live
coordination log). Check what's already been tried and what's already known before
re-deriving or re-guessing.

## Process management: MCP tool first, always
Starting/restarting the game process on Drew's machine has caused real damage this session —
a wrong process name led to a false conclusion, a cleanup pass disconnected the session's own
MCP tools, and a background agent's ad-hoc instance launch caused a port collision that closed
Drew's actual live game. **Before launching, checking, or killing any game process, check
whether the `mcp__powder-toy__*` tools are reachable and use them.** Raw bash/PowerShell
process management (tasklist, background launches, manual PID tracking) is a last resort for
when the MCP tool is genuinely unreachable, never the default. If the MCP tool is down, that
is itself a problem to actively fix (see the roadmap track), not something to route around
silently. Do not launch a second Powder Toy window, a "lab" instance, or any extra `powder.exe`
unless Drew has explicitly asked for that in this message. Extra windows are annoying
and have closed his real game before. Work against the one game he already has open
(port 9876). If you need a process, use the `mcp__powder-toy__*` tools — never
`scripts/lab_instance.py --launch`, never an improvised second launch of the same
binary his shortcut uses.

## Verify by execution, not inference
Never claim code works, a test passed, or a bug is fixed without having actually run it and
observed the result. Label claims explicitly: **VERIFIED** (actually executed/observed),
**INFERRED** (reasoned but not executed), or **UNKNOWN**. A wrapper's exit code is not proof
— read the actual command output (a `ninja | tail` reporting exit 0 while the real compile
failed is a real trap that happened in this project; always check the underlying tool's own
result, not a pipe's).

## Testing rules for this project specifically
- Never send synthetic mouse/keyboard input to any window, ever.
- Never experiment on Drew's own live/played game session — use a separate launched instance.
- Screenshots and structured state reads (bridge queries, spatial snapshots) are expected and
  encouraged for verification — Drew explicitly wants this, it is not overstepping.
- Prefer hot-reload (`R.hotReloadRequested` via the bridge) over a full restart wherever
  possible — faster and preserves state. See TODO.md/memory for the exact pattern.
- The HTTP bridge lives at `127.0.0.1:9876`, token at `D:/The-Powder-Toy/build/powder-bridge.token`.

## Use failure as memory
When a fix doesn't resolve a reported bug, don't just try a different guess in the same
function. Record what was tried, what the evidence showed, and — if the same function has
now had two separate proven-correct fixes that still don't resolve the report — seriously
consider the real cause is in a different layer entirely (native engine vs. Lua, a different
subsystem) rather than continuing to search the same 15 lines.

## Communication standard
When reporting a fix, fully articulate the specific evidence witnessed (what was called, what
value came back, what process it ran against) — not a bare "verified" or "fixed" claim. When
making a change, state what's being changed, why it addresses the actual cause, and why it
won't break anything else that touches the same code.

## Agent roster (background tracks)
The standing roster is fixed at whatever Drew has explicitly named (as of 2026-08-29: bug
fixes done directly, one feature-implementation agent, one roadmap/infrastructure agent, one
GitHub-docs agent). When a track finishes a pass, resume the SAME agent via SendMessage —
never spawn a fresh one for an existing track. Only add a new track when Drew explicitly asks.

## Other standing rules
- Never put Drew's real name in anything public-facing (commits, README, code comments).
- Keep working through the TODO.md list in order of what's live/urgent; don't context-switch
  away from an in-progress task just because a new message arrives — log it and continue.
- Full detail and rationale for all of the above lives in Claude's cross-session memory; this
  file is the fast-reference version specific to this project.
