# Realism persistence runbook

Three things live only in the running `powder.exe` process and are lost on
every restart, because nothing before now wrote them to disk:

1. **Runtime behaviour kinds** -- `absorber`, `turbine`, `teg`,
   `photovoltaic`, `piezo`, `pcm`, `reactive`, registered ad hoc into
   `PBX.state.behaviors.kinds` by running `scripts/lua/power_kinds.lua`,
   `material_kinds.lua`, `chem_kinds.lua` through `executeLua`. This table is
   a plain in-memory Lua table with function values in it -- there is nothing
   here that could be serialized to `PBX.save`'s JSON persistence even if a
   module tried to.
2. **The stock-element realism patch** -- `knowledge/stock-element-realism-
   patch.json` (and `-v2.json`, applied on top, later file wins per
   `(element, property)` pair) -- direct `elem.property(id, key, val)` calls
   against the C++ element table. Pure in-memory engine state; a restart puts
   every stock element back to upstream TPT defaults.
3. Indirectly, **custom elements that use one of the kinds in (1)**.
   `bridge_src/10_registry.lua` *does* persist every custom element's spec to
   `pbx-custom-elements.json` next to `powder.exe` and *does* try to recreate
   each one from that file on load -- but that recreate can run before
   anything has re-registered the element's `behavior.kind`, so an element
   built with `absorber`/`turbine`/etc. can be dropped as "unrecreatable" on
   the very first tick after a restart, even though its element name, colour,
   and physical properties would have survived fine on their own. Nothing is
   permanently lost when this happens -- the spec still lives in
   `scripts/define_power_elements.py`'s `ELEMENTS` list and
   `knowledge/materials-catalog.json` -- but it does mean `realism_apply`
   needs to run again to redefine it.

`powder_ext/realism_tools.py` (`realism_apply` / `realism_status`) and
`scripts/realism_watch.py` exist to make re-establishing all three
mechanical rather than something Drew has to remember and do by hand.

## Status: what's live right now

MCP tool (read-only, safe to call any time):

```
realism_status {}
```

Same thing from a shell, without going through the MCP server:

```powershell
python -c "import sys,json; sys.path.insert(0,'D:/powder-toy'); from powder_ext import realism_tools as rt; print(json.dumps(rt.realism_status({}), indent=1))"
```

Reports, per top-level key:

* `kinds.registered` / `kinds.missing_runtime` -- everything currently on
  `PBX.state.behaviors.kinds`, and which of the seven runtime kinds
  (`absorber`, `turbine`, `teg`, `photovoltaic`, `piezo`, `pcm`, `reactive`)
  are absent.
* `custom_elements.live` / `.cap` / `.free` -- against
  `PBX.MAX_CUSTOM_ELEMENTS` (40 as of 2026-08-26).
* `stock_patch.in_effect` -- sampled by comparing `METL`'s live
  `HighTemperature` against the patch's expected value (within 0.05 K).
  `stock_patch.files` lists which patch file(s) were actually found on disk.
* `materials_catalog.by_priority` -- `{total, live}` per catalog priority
  tier (1/2/3).
* `power_elements` -- `{total, live}` against
  `scripts/define_power_elements.py`'s 13-element set.

## Apply: re-establish everything

MCP tool:

```
realism_apply {"profile": "all", "dry_run": false}
```

`profile` scopes the work:

| profile     | what it does                                                          |
|-------------|------------------------------------------------------------------------|
| `all`       | kinds -> stock patch -> power set -> materials catalog, in that order |
| `kinds`     | just (re)runs `scripts/lua/*_kinds.lua` through `executeLua`          |
| `stock`     | just re-applies the stock-element patch file(s)                       |
| `power`     | kinds, then define/update the 13-element power set                   |
| `materials` | kinds, then define the materials-catalog priority-1 entries          |

`dry_run: true` computes the exact same plan and cap accounting through
**read-only bridge calls only** (`listCustomElements`, a `return`-only
`executeLua`) -- it never calls `defineElement` / `updateElement` /
`deleteCustomElement` and never runs a kinds-registration or patch chunk
through `executeLua`. Always dry-run first against a live session you care
about; the result's `steps.*.skipped_cap` list tells you what would be left
out for lack of a free element slot (`custom_elements` cap is 40) before you
commit to it for real.

`power` and `materials` share one running "already-reserved" slot count for
the duration of one `realism_apply` call, so if you run `profile: "all"` with
few free slots, `power` elements get first claim and `materials` reports the
rest as `skipped_cap` -- this mirrors `scripts/define_materials.py`'s own
cap-slicing logic, just applied across both element sets in the same call
instead of only within one script's run.

Equivalent shell form (bypasses the MCP server, talks to the bridge
directly -- useful when debugging the extension itself):

```powershell
python -c "import sys,json; sys.path.insert(0,'D:/powder-toy'); from powder_ext import realism_tools as rt; print(json.dumps(rt.realism_apply({'profile':'all','dry_run':False}), indent=1))"
```

## Revert: put stock elements back to upstream defaults

There is no `realism_revert` tool (not asked for, and restarting the game
already does this for free -- see below). To undo the stock patch on a
*running* session without restarting, replay
`knowledge/stock-element-props-original.json` (the pristine snapshot
`scripts/lua/stock_props.lua` captured before the patch ever existed) the
same way `realism_apply`'s `stock` step applies the patch, just swapping the
source values: each entry is `{"n": NAME, "hi": HighTemperature, "hiT":
HighTemperatureTransition (numeric id, -1 = none), "lo": LowTemperature,
"loT": LowTemperatureTransition, "hc": HeatConduct, "fl": Flammable, "hard":
Hardness, "w": Weight}`. There is deliberately no one-line tool call for this
-- it is rare enough (undo without restarting) that hand-building the
`executeLua` chunk from that file when actually needed is safer than
maintaining a second, lightly-tested mutation path next to `realism_apply`.

To remove one or more custom elements entirely, use the existing
`delete_custom_element` tool (or `scripts/define_materials.py --swap OLD
NEW` to reuse a slot).

## Watcher: automatic re-apply on a fresh session

`scripts/realism_watch.py` polls the bridge every `--interval` seconds
(default 10) and calls `realism_apply` when it detects a fresh session,
via either signal:

1. `bridge_src/90_realism_boot.lua`'s persisted boot counter
   (`pbx-realism_boot.json` in the build directory, read through
   `PBX.load`/`executeLua`) differs from the last value the watcher saw.
2. `list_custom_elements` reports 0 while `materials-catalog.json` has
   priority-1 entries that should exist.

Every poll is read-only; only a detected fresh session triggers a mutating
`realism_apply` call (or a `dry_run` one, if `--dry-run` was passed to the
watcher itself). The **first** run of the watcher against any given state
file only seeds its baseline (`last_boot_count` / `last_custom_count`) and
never applies -- this avoids re-running `realism_apply` every time the
watcher process itself is restarted against an already-current session.

```powershell
# run forever, poll every 10s, apply for real on a fresh session
python D:/powder-toy/scripts/realism_watch.py

# one check-and-maybe-apply pass, then exit -- good for cron/Task Scheduler
python D:/powder-toy/scripts/realism_watch.py --once

# never mutates; logs what realism_apply WOULD do
python D:/powder-toy/scripts/realism_watch.py --dry-run

# custom interval / profile / state file
python D:/powder-toy/scripts/realism_watch.py --interval 5 --profile power
python D:/powder-toy/scripts/realism_watch.py --state-file D:/powder-toy/logs/realism_watch_state.json
```

State persists to `logs/realism_watch_state.json` by default (`last_boot_
count`, `last_custom_count`, `last_checked`, and a `last_apply` record with
the reason and per-step summary from the most recent triggered apply). An
unreachable bridge (game not running, or mid-restart) is logged and skipped,
not treated as an error -- the loop just tries again next interval.

Run it detached the same way other long-lived helpers in this project run,
e.g.:

```powershell
Start-Process -WindowStyle Hidden python -ArgumentList "D:/powder-toy/scripts/realism_watch.py" -RedirectStandardOutput "D:/powder-toy/logs/realism_watch.log" -RedirectStandardError "D:/powder-toy/logs/realism_watch.err.log"
```

## Restart procedure (when Drew is ready to deploy `90_realism_boot.lua`)

**Not done by this change.** `bridge_src/90_realism_boot.lua` was added to
the source tree and verified to compile (Lua 5.1, via `build_autorun.py`'s
own `lua51_compile` check) and to be picked up by
`build_autorun.py`'s `module_files()` glob (`^\d\d_` prefix, sorts after
`70_people.lua`) -- but it is **not** in the live `autorun.lua` yet, because
deploying it requires a restart and Drew's session is live. When ready:

1. `python D:/powder-toy/build_autorun.py --dry-run` -- confirm the report
   shows `90_realism_boot.lua` with a clean syntax check and no structural
   problems before touching anything live.
2. `python D:/powder-toy/build_autorun.py` -- rebuilds and deploys
   `D:/The-Powder-Toy/build/autorun.lua` (and the `scripts/demo_create_
   element.lua` mirror). Existing custom elements and the module's own
   registry (`pbx-custom-elements.json`, `pbx-colonies.json`,
   `pbx-tasks.json`) are untouched by this step -- it only rewrites the Lua
   source, not the JSON state files next to it.
3. Restart `powder.exe`.
4. Check `D:/The-Powder-Toy/build/autorun-runtime.log` for a
   `[realism_boot] realism_boot 1.0.0 loaded` line and, one tick later,
   `[realism_boot] boot marker written: boot_count=N ...`. Also expect
   `[registry] dropped unrecreatable element ...` lines for any custom-kind
   element that got dropped before its kind was re-registered -- see the
   known-gap note below; this is expected and self-heals on the next
   `realism_apply`.
5. Call `realism_status` to confirm what actually survived
   (`kinds.registered` will likely be back to just the 8 base kinds;
   `custom_elements.live` will likely be lower than before the restart).
6. Call `realism_apply {"profile": "all"}` once by hand (or just start the
   watcher, which will detect the new `boot_count` within one `--interval`
   and do this for you), then `realism_status` again to confirm
   `kinds.missing_runtime` is empty, `stock_patch.in_effect` is `true`, and
   `power_elements.live` / `materials_catalog.by_priority` are back to their
   pre-restart totals (mind the 40-element cap -- see `skipped_cap` in the
   `realism_apply` result if not).
7. Start (or leave running) `scripts/realism_watch.py` so the next restart
   is handled without a manual step 6.

### Known gap, by design

`90_realism_boot.lua` only *signals* a fresh session -- it does not itself
fix the ordering problem in point 3 above (a custom-kind element can be
dropped by `10_registry.lua`'s restore-on-load before anything has
re-registered its kind). Actually closing that gap would mean moving
`*_kinds.lua`'s registration into `bridge_src` itself, ahead of
`10_registry.lua` in load order -- a bridge source/semantics change that was
explicitly out of scope for this change (see the task constraints: no edits
to bridge source *semantics*, no `build_autorun.py` run, no restart). The
accepted trade-off is a window of up to one watcher `--interval` (default
10s) after a restart where a custom-kind element may be temporarily missing
before `realism_apply` redefines it -- never permanent, since every such
element's spec is durably recorded outside the running process (`scripts/
define_power_elements.py`, `knowledge/materials-catalog.json`).
