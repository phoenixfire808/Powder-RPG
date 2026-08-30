# Current progress — 2026-08-30 ~15:00 (audit)

## This Cursor / Claude Code session (what you actually asked for)

| Topic | Status |
|-------|--------|
| Retrieve Claude Code Powder Toy context | Done — sessions under `C:\Users\Drew\.claude\`, hub/TODO synced |
| In-game brush ≠ menu brush | **In source v1.15.20** (`pullNativeBrush`, Tab, `[`/`]`/wheel). **Awaiting your in-game confirm** |
| Stuck brush after leaving menus | **In source v1.15.21** (`_clickArmed`, `wouldPlace`, `releaseMouse` on menu transitions). **Awaiting your confirm** |
| No extra "lab" game windows | **Standing rule** in `CLAUDE.md` + hub. MCP `agent_start` / lab launch work **cancelled** |
| Map type + options at spawn menu | **In source v1.15.22** Create World panel. **Awaiting your confirm** |
| MCP tools for MiniMax / less guesswork | **Not shipped** this session (cancelled when you said no lab windows) |

## On disk now (`scripts/lua/rpg.lua`)

`R.VERSION = "1.15.23"` — **new-seed sand spray fix**: title/inactive clicks now return `false` (block native TPT brush), post-start placement grace, menu-close grace.

**Your live game** only picks this up after **F9** or restart. Check top-right HUD: should read `v1.15.23` when loaded.

## v1.15.23 (2026-08-30) — new seed particle spray

- **Root cause (VERIFIED in C++ + Lua)**: `onMouseDown` returned `nil` on title screen; TPT only blocks native brush when Lua returns `false`. Create/Play click armed native placement; held LMB kept spraying sand after world start. Title embers are HUD-only — not the bug.
- **Fix**: title/inactive `return false`; `onMouseUp` resets state even when inactive; `releaseMouse` + `_placeGraceUntil` on Create/Resume/generateWorld; menu-close grace in `setMenuOpen`.

## Shipped + lab/agent verified (not your eyes yet)

- v1.15.12 — tree grass gap (genBase)
- v1.15.14 — "Day N day" HUD typo
- v1.15.15–16 — wheel brush size, molten place temps
- v1.15.17 — molten `setMoltenTemp`
- v1.15.18 — brush shape (V key)
- MCP: `run_lua_test`, `inspect_grid`, `build_and_trace` (lab port tests)
- GitHub/docs rounds — release notes v1.15.7–1.15.12 etc.
- Roadmap audits — respawn retrospective, round-26 UI spec, save-load drift **documented** (`next-bug-class-2026-08-30.md`)

## In source, needs YOU (do not mark TODO `[x]` until confirmed)

1. **v1.15.22** — Create World (map type, survival/sandbox, seed, cave/ore/tree)
2. **v1.15.21** — menu-close particle spam (`_clickArmed`)
3. **v1.15.20** — in-game brush matches TPT menu
4. Long tail of older **"FEATURE APPLIED, AWAITING CONFIRMATION"** items (title hover, sliders, crafting UI, etc.) — code may already be live; you never signed off

## Real bugs found, fix NOT implemented yet

- **Save-load plugin drift** — old saves can leave `R.COMP.chatQueue` nil → crash on companion chat poll. Doc + recommendation in `knowledge/next-bug-class-2026-08-30.md`. **@bugs lane, not done.**

## Deferred (spec exists, not current priority)

- F12 — HUD Day line vs GOAL bar overlap
- F13 — minimap readability
- F11 — zoom box drag
- Sound effects — no audio engine (honest blocker)
- Community stamp submission UI — proposal only

## Process / hygiene

- **One game** — port 9876. Agents must not launch `lab_instance` unless you ask.
- TODO.md is **append-only** and huge; top section + bottom "Cursor pickup" section track this session.
- `knowledge/rpg-hub.md` has Drew says + log through v1.15.22 entry.

## Your next step (one pass)

1. F9 or restart Powder Toy once.
2. HUD shows `v1.15.22`.
3. Esc → Quit to menu → **New World** → try Desert + Survival + Create.
4. Play a minute: leave Esc menu — no particle spray; Tab/`[`/`]` brush in-game.

Report what fails; we fix that lane only.
