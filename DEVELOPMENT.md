# Powder RPG — Standing Engineering Protocol

This file is read automatically at the start of every session in this project. It is the
permanent, mandatory operating protocol for all work here — not a suggestion.

## Never start from zero
Before acting, read `knowledge/TODO.md` (append-only, never delete entries, never mark `[x]`
unless the owner has personally confirmed something live) and `knowledge/rpg-hub.md` (live
coordination log). Check what's already been tried and what's already known before
re-deriving or re-guessing.

## Process management: MCP tool first, always
Starting/restarting the game process on the owner's machine has caused real damage this session —
a wrong process name led to a false conclusion, a cleanup pass disconnected the session's own
MCP tools, and an ad-hoc tooling instance launch caused a port collision that closed
the owner's actual live game. **Before launching, checking, or killing any game process, check
whether the `mcp__powder-toy__*` tools are reachable and use them.** Raw bash/PowerShell
process management (tasklist, background launches, manual PID tracking) is a last resort for
when the MCP tool is genuinely unreachable, never the default. If the MCP tool is down, that
is itself a problem to actively fix (see the roadmap track), not something to route around
silently. Do not launch a second Powder Toy window, a "lab" instance, or any extra `powder.exe`
unless the owner has explicitly asked for that in this message. Extra windows are annoying
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
- Never experiment on the owner's own live/played game session — use a separate launched instance.
- Screenshots and structured state reads (bridge queries, spatial snapshots) are expected and
  encouraged for verification — the owner explicitly wants this, it is not overstepping.
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

## Work tracks
Work is organised into a small, fixed set of parallel tracks — bug fixes, feature
implementation, roadmap/infrastructure, and documentation. A track keeps its own context across
passes rather than starting from scratch each time. Each track owns an explicit set of files, and
two tracks never write the same file in the same pass — that rule exists because concurrent
writes have silently destroyed work in this repository more than once.

## Other standing rules
- Never put the owner's real name in anything public-facing (commits, README, code comments).
- Keep working through the TODO.md list in order of what's live/urgent; don't context-switch
  away from an in-progress task just because a new message arrives — log it and continue.
- Longer-form rationale and history live in the project's own working notes; this file is the
  fast-reference version specific to this repository.

## Verify it LANDED. A lane saying "done" is not evidence.

This has cost real time repeatedly, and every instance looked fine in a report:

- `icons.lua` shipped inside a public zip but `"icons"` was never in `R.PLUGINS`. It never loaded
  for anyone. My verifying grep matched the filename and reported success.
- The colony system was "removed" — the docs were updated, the code removal was handed to a lane,
  and it still loads on every boot (`restored 4 colonies from disk`).
- `Tools` and `Submit` buttons were wired to flags (`R.sbToolsRequested`, `R.sbSubmitRequested`)
  that nothing anywhere read. Dead clicks, silently.
- The Replicator Core recovery was registered and then destroyed by a later `hook()` call in the
  same file. The feature existed, was reported complete, and never ran.
- A C++ molten-naming "fix" was placed in unreachable code inside an already-matched branch.
- `R.drawInventory` was called; the function does not exist.
- Several lanes ended with "patch request filed in the hub for the owning lane" — those are NOT
  landed until someone applies them, and some never were.

**The rule:** a change is not done until it has been observed working in the state the player will
actually be in. Specifically:

1. **Registered?** New plugin → confirm it is in `R.PLUGINS` by reading the list back FROM DISK,
   not by grepping for the filename (the filename appears in the file itself).
2. **Loaded?** Confirm `R.pluginStatus[name] == "ok"` and `R.pluginErr` nil on a live reload.
3. **Reachable?** Confirm the code path actually executes — a hook that is registered can still be
   deleted by a later registration; a button can be wired to a flag nobody reads.
4. **On a fresh install?** The dev machine masks bugs. Hot-reloading hid the load-order bug that
   made every downloaded world brick. The persisted element snapshot overrides the checked-in seed,
   so the dev machine can be broken while the shipped build is fine — and vice versa.
5. **Handoffs are not completions.** If a lane files a patch request, it is an open item until the
   owner lands it AND the four checks above pass. Track it; do not close it on the report.

Corollary: when reporting to him, say what was OBSERVED, not what was implemented. "Registered and
verified loading with 0 errors" is a claim. "I wrote the code" is not.

## Do not ask. Do it.

He has said this directly and more than once: *"Don't ask me, make it happen."* *"I'm sick of
telling you shit."* Asking permission for routine work is not caution, it is offloading the job
back onto him.

**Never ask before:**
- Restarting or relaunching his game to land a change. Save state first if it exists, then do it,
  then tell him it is back up.
- Rebuilding the engine, regenerating `autorun.lua`, or redeploying.
- Spawning lanes, committing, tagging, pushing, or cutting a release.
- Choosing between two reasonable implementations. Pick the better one, state which and why.

**Only escalate when it is genuinely his call:**
- Destroying work that cannot be recreated.
- A product/design decision with no correct answer (e.g. which of two colliding element names wins).
- Something that costs money or leaks a secret.

**And do the whole thing.** When he says "all of them", partial delivery with a note explaining the
scope cut is a failure, not a status update. If the full job is large, do it in full anyway — spawn
the work, keep going, and report when it is done, not when it is a third done.

## Finish the whole thing. Every category, every element, 100%.

Stated directly and more than once: *"Whenever I ask you to do something, do it all the way till
the end, for every category and every element, until it's absolutely 100% completed and there's
nothing left to do."*

**Partial delivery is a failure, not a status update.** These all happened and all were wrong:
- Asked for all 118 elements; a lane delivered 7 and called the rest "out of scope".
- Asked for all reactions; 10 got wired while 929 confirmed rows sat unused in a spreadsheet.
- Asked for all nuclides; 50 were registered out of 3,383 with the split decided unilaterally.
- Asked for every material in the categories tab; a curated list of ~113 shipped while 457 existed.

**The standard:**
1. **Enumerate the full set first.** State the real denominator out loud — 118 elements, 3,383
   nuclides, 6,903 pairs, 457 live elements — then work against it. Never start without knowing
   how many there are.
2. **Batch and keep going.** If it is large, do it in family or alphabetical batches and continue
   until the count is met. Do not stop at a milestone and write a scope note.
3. **Report the fraction, always.** "10 of 929 wired" is honest. "Reactions are working" is not.
4. **A gap must be named, counted, and owned** — never left implicit. If something genuinely
   cannot be done, say exactly what and why, with the count.
5. **Ship the spreadsheet too.** Data work is not finished until it exists as a queryable sheet,
   not only as behaviour in code.

Scope cuts are HIS decision, never the lane's and never mine.

## Hot-reload. Do not launch a game unless you genuinely must.

Stated directly: *"We need to stop opening up a bunch of games and shit. We should have hot
reload."* At one point tonight FIVE game instances were running at once — four lab instances plus
his. That is his CPU, his frame rate, and windows appearing over what he is doing.

**Hot-reload covers almost everything.** Use it first, every time:
- `rpg_reload {target="plugin", name="<x>"}` — one plugin, instantly.
- `rpg_reload {target="core"}` — `rpg.lua` plus every plugin.
- Changes to `scripts/lua/**` NEVER need a restart. That is the majority of all work.

**A restart is only genuinely required for:**
- `bridge_src/**` changes, because they are compiled into `build/autorun.lua` at boot.
- C++ engine changes, which additionally need his game closed to link.

**Before launching a lab instance, ask whether a read-only bridge call would answer the question.**
Most verification is a query, not an experiment: element properties, plugin status, hook counts,
registry contents and live measurements are all readable from his running session with zero risk.

**If you do launch one:**
- Reuse a single instance for the whole task; do not launch per test.
- **Kill it the moment you are done** and confirm with `tasklist` — orphans have accumulated all
  night and every one costs him performance.
- Absolute `--dir`, own port, own token, `disable-network`.
- **NEVER in the foreground** — a windowed app never returns and it has destroyed five lanes'
  entire budgets today.

## Wikipedia works — you just need a User-Agent (VERIFIED 2026-09-02, @metallurgy)

A plain `urllib` GET to Wikipedia returns **403 Forbidden**. Adding **any descriptive
`User-Agent` header returns 200**. This blocked several data lanes tonight and was wrongly
recorded as "Wikipedia is unavailable from this environment" — it is not, it just refuses
anonymous default-agent requests.

    req = urllib.request.Request(url, headers={"User-Agent": "PowderRPG-research/1.0"})

Working sources confirmed from this environment:
  * **PubChem REST** — `https://pubchem.ncbi.nlm.nih.gov/rest/pug/...` — no header needed.
    `.../periodictable/JSON` returns all 118 elements in ONE request with melting point,
    boiling point, density, standard state, CPK colour, electronegativity, ionization energy,
    electron affinity, atomic radius, oxidation states and group block.
  * **Wikipedia** — with a User-Agent header, including raw wikitext for infobox extraction.
Cache what you fetch (`knowledge/data/_cache/`) and quote the source text so a later `--check`
can mechanically re-verify the claim still appears in the cached source.

## Push updates constantly. Do not sit on work.

Stated repeatedly and ignored repeatedly: *"We want to be pushing the updates as much as possible."*
Work sat unshipped for hours while dozens of fixes piled up locally. That is a failure on its own,
independent of whether the fixes were good.

**The rule:**
1. **Ship after every meaningful fix**, not at the end of a session. If a bug is fixed and verified,
   it goes out.
2. **Never wait for a batch to feel "big enough."** Six small releases beat one large one: each is
   easier to diagnose if it breaks, and he can play the fix immediately.
3. **Bump the version every time.** `R.VERSION` in `rpg.lua`, both trees.
4. **The full ship is: commit -> tag -> push -> build the zip -> create the GitHub release with a
   `Version: X.Y.Z` line in the body -> upload the asset.** The `Version:` line is not optional --
   the in-game updater parses it and silently ignores any release without it.
5. **Release notes are player-facing.** Say what changed and why it mattered, in plain language.
   Name the bugs honestly, including ones we caused.
6. **Never ask permission to release.** Just do it and report the URL.

If a release cannot go out (broken build, failing gate), say so explicitly with the reason -- do not
let it silently not happen, which is what kept happening.
