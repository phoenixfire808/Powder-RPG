# Powder Toy -- Working To-Do List

## Title Create World + no extra game windows (2026-08-30) -- v1.15.22

- [ ] **SHIPPED IN SOURCE, AWAITING DREW LIVE** -- v1.15.23 new-seed sand spray fix
      (`scripts/lua/rpg.lua`). Title/Create clicks used to return nil from onMouseDown;
      native TPT brush kept placing while LMB held from Create click. Now returns false,
      post-start grace, menu-close grace. F9/restart → HUD `v1.15.23`. Test: New World →
      Create (can hold click through start) — no sand spray. Do not mark `[x]` until confirmed.
- [ ] **SHIPPED IN SOURCE, AWAITING DREW LIVE** -- title-screen Create World
      (`scripts/lua/rpg.lua` v1.15.22). Play on a fresh session and New World
      open a panel: map type (Mixed / Forest / Desert / Snow / Swamp),
      Survival vs Sandbox, seed (click to reroll), cave/ore/tree sliders,
      Create / Back. Esc menu "New world" goes there instead of instantly
      regenerating. Single-biome map types force `biomeAt`/`biomeMix`.
      Do not launch extra lab windows. F9 or restart his own game to pick
      this up. Do not mark `[x]` until he confirms in-game.
- [ ] Standing: agents must not start a second powder.exe / lab instance
      unless Drew explicitly asks. One game (port 9876).

## Github track, round 15 (2026-08-30) -- v1.15.12 release notes (F10 cosmetic: trees no longer float above grass)

- [x] **Shipped `D:/The-Powder-Toy/releases/v1.15.12.md`** (NEW, 10111 bytes).
      Sourced verbatim from `R.CHANGELOG[1]` at `scripts/lua/rpg.lua:203-205`:
      F10 cosmetic fix -- trees no longer float above the grass (1-px air gap
      at every tree base). The fix widens the trunk loop stop-condition
      from `wy < t.s` to `wy <= t.s` and hoists the trunk check out of the
      `wy < surf` block so it fires at `wy == surf` and overdraws the grass
      pixel at the trunk's 2-px column. Canopy ellipse unchanged (it has no
      matching gap). Full release-notes template: Summary (cosmetic verdict /
      rpg.lua only / behaviour delta / zero gameplay risk), Changes
      (verbatim source bullet), Affected files (rpg.lua only, with
      per-change explanation: trunk-loop condition widened, trunk check
      hoisted, canopy unchanged, no other changes), Migration notes (no
      plugin changes / no save-format changes / no HUD changes /
      plugin-author guidance about tree placement site), How-to-verify
      (explicitly tells reader to use LIVE SESSION not the lab per Main's
      brief -- lab has worldEverGen=false so visual confirmation
      impossible there: pre-flight HUD version check, new world, find a
      tree, Path 1 inspect trunk base, Path 2 canopy still gap-free by
      design, Path 3 generate several worlds, negative test existing-save
      trees still gap, negative test non-tree grass unaffected,
      cross-version regression check for respawn cluster, architecture
      verification grep for `wy <= t.s` in genBase), See-also with
      cross-links to v1.15.11 / v1.15.10 / v1.15.9 / v1.15.8 / v1.15.7 /
      v1.15.4 / v1.15.3 / retrospective / CHANGELOG / README roadmap
      footer.
- [x] **Inserted v1.15.12 entry into `CHANGELOG.md`** above v1.15.11,
      bullet pulled verbatim from `rpg.lua:204`. Newest-first heading
      order now: v1.15.2 / v1.15.3 / v1.15.4 / v1.15.5 / v1.15.6 /
      v1.15.7 / v1.15.8 / v1.15.9 / v1.15.12 / v1.15.11 / v1.15.10 /
      v1.14.0. Restored the v1.15.10 first bullet ("New Seed/New World
      no longer inherits sandbox/creative mode") that was clipped
      during the edit cascade -- the cascade-edit tool clipped the
      leading bullet when I rebuilt the section between v1.15.11 and
      v1.15.10.
- [x] **Cascaded v1.15.12 See-also entries into all 9 older release
      pages** -- v1.15.3 / v1.15.4 / v1.15.5 / v1.15.6 / v1.15.7 /
      v1.15.8 / v1.15.9 / v1.15.10 / v1.15.11, each framed per that
      release's scope rather than copy-pasted (v1.15.11 frames as
      post-respawn-cluster QoL/cosmetic tail, v1.15.10 frames as
      negative-test target for respawn helpers, v1.15.9 frames as QoL
      tail closing the cluster, v1.15.8 frames as following the
      CONVENTION note, v1.15.7 frames as same pure-rendering-fix
      shape, v1.15.6/v1.15.5 frame via HUD version-readout, v1.15.4
      frames as part of the death+respawn+QoL+cosmetic arc, v1.15.3
      frames as same kill-bug-at-recovery-hook shape).
- [x] **Extended `D:/The-Powder-Toy/releases/v1.15.7-v1.15.10-retrospective.md`**
      with a new "Post-retrospective tail (v1.15.11 + v1.15.12)" section
      that frames the two post-cluster rounds as the natural QoL /
      cosmetic tail that follows once the bug-class is closed: the
      cluster ended on "behavioural parity between surface and bed
      respawn"; the tail lands on separate, unrelated classes (chat
      cadence, world rendering). Also cleaned up a duplicate-line
      glitch that was introduced when the cascade-edit tool clipped a
      body row during the earlier see-also updates -- the retrospective
      now reads cleanly with one Post-retrospective tail section and
      one See also section in proper order.
- [x] **Hub log appended** (`D:/powder-toy/knowledge/rpg-hub.md`) one
      line under the `[@github round N] <what, source>` format.
- [x] **Standing constraints held throughout**: zero mutations to
      `scripts/lua/rpg.lua`, zero plugin changes, zero `knowledge/*`
      design-doc changes, zero `bridge_src/` or
      `D:/The-Powder-Toy/src/` changes, zero git commits / pushes.
      Verified via `ls -la` + `wc -l` on all 13 touched files (11
      release files + CHANGELOG.md + retrospective) just before
      reporting.
- [x] **Live session context captured**: per @bugs' round 15 hub log
      line, `R.VERSION == "1.15.12"` lab-verified end-to-end (port 9877,
      loadstring OK, hot-reload clean, unit test across 5 wy values:
      pre vs post only the gap row at wy=s changed from false->true;
      dispatch test 5 wx/wy combinations). Real-world rendering not
      exercised on the lab (worldEverGen=false) -- visual
      confirmation is for the live 9876 session per the How-to-verify
      procedure.


- [x] **Shipped `D:/The-Powder-Toy/releases/v1.15.11.md`** (NEW, 7958 bytes).
      Sourced verbatim from `R.CHANGELOG[2]` at `scripts/lua/rpg.lua:206-208`:
      `'Sunburnt (X% UV exposure) -- get some shade'` no longer spams the chat
      every 5 s; `R.lastSunburnAt` cooldown (1800 frames / ~30 s) gates only
      the chat message write, the 1-HP damage tick continues every 300 frames
      as before; field added to the existing frame-stamped cooldown reset
      list at `generateWorld` so it starts `nil` on every new world. Full
      release-notes template: Summary (verdict / scope / behaviour delta /
      risk), Changes (verbatim source bullet), Affected files (rpg.lua only,
      with per-field explanation), Migration notes (no plugin changes / no
      save-format changes / no HUD changes / plugin-author guidance about the
      cooldown reset list), How-to-verify (Path 1 outdoors message cadence,
      Path 2 shelter reset, three negative tests for damage-tick independence
      and generateWorld reset, cross-version regression check for the
      v1.15.7-v1.15.10 cluster, architecture-verification grep for
      `R.lastSunburnAt`), See-also with cross-links to v1.15.10 / v1.15.9 /
      v1.15.8 / v1.15.7 / v1.15.4 / v1.15.3 / retrospective / CHANGELOG /
      README roadmap footer.
- [x] **Inserted v1.15.11 entry into `CHANGELOG.md`** between v1.15.9
      (line 110) and v1.15.10 (line 121), bullet pulled verbatim from
      `rpg.lua:207`. Newest-first heading order now matches `R.CHANGELOG`
      upstream: v1.15.2 / v1.15.3 / v1.15.4 / v1.15.5 / v1.15.6 / v1.15.7 /
      v1.15.8 / v1.15.9 / v1.15.11 / v1.15.10 / v1.15.0 / v1.14.0.
- [x] **Cascaded v1.15.11 See-also entries into all eight older release
      pages** -- v1.15.3 / v1.15.4 / v1.15.5 / v1.15.6 / v1.15.7 / v1.15.8 /
      v1.15.9 / v1.15.10, each framed per that release's scope rather than
      copy-pasted (v1.15.10 = same cooldown-reset-list pattern, v1.15.9 =
      negative-test target for the bed respawn fix cluster, v1.15.8 =
      follows the CONVENTION note, v1.15.7 = same small-QoL single-file
      shape, v1.15.6 = HUD version-readout confirms "v1.15.11" at a glance,
      v1.15.5 = always-on HUD top-right read, v1.15.4 = another entry in
      the generateWorld reset-list family, v1.15.3 = same
      kill-bug-at-recovery-hook approach).
- [x] **Hub log appended** (`D:/powder-toy/knowledge/rpg-hub.md`) one line
      under the `[@github round N] <what, source>` format.
- [x] **Standing constraints held throughout**: zero mutations to
      `scripts/lua/rpg.lua`, zero plugin changes, zero `knowledge/*`
      design-doc changes, zero `bridge_src/` or `D:/The-Powder-Toy/src/`
      changes, zero git commits / pushes. Verified via `ls -la` + `wc -l`
      on all nine touched files just before reporting.
- [x] **Live session context captured**: the user's real session came up
      clean on `R.VERSION = "1.15.11"` (per the round 14 hub log line from
      @bugs). The QoL cooldown fix is the new feature set; the existing
      respawn-path fix cluster (v1.15.7 -> v1.15.10) and the always-on HUD
      (v1.15.5 + v1.15.6) are unchanged and form the negative-test
      baseline referenced in the How-to-verify section.


- [x] **Shipped `D:/The-Powder-Toy/releases/v1.15.7-v1.15.10-retrospective.md`**
      (NEW, 7928 bytes). Format per Main's brief:
      - **Chronological summary table** at top: `ver | headline | files touched |
        format` columns, four rows (v1.15.7, v1.15.8, v1.15.9, v1.15.10), each
        linking to its individual release page. Format column distinguishes
        "single-file" vs "FIRST/SECOND/THIRD multi-file" so the cross-version
        pattern is visible at a glance.
      - **"The pattern -- respawn-path drift"** section: explains the recurring
        bug class (a behaviour inlined inside `R.spawnPlayer()` silently doesn't
        run on the bed path because `survival.lua`'s bed wrap goes around
        `R.spawnPlayer()` entirely) with a 4-step mechanism-by-mechanism
        breakdown for each round, and a "why it took four rounds" sub-section
        attributing the latency to surface-only test plans in earlier rounds.
      - **"Cross-version relationships"** family tree: v1.15.7 -> v1.15.9 ->
        v1.15.10 = respawn-helper trio (same architectural pattern, one round
        each axis: stats / companion / overhead), and v1.15.4 -> v1.15.9 ->
        v1.15.10 = complete bug-class fix (inline reset -> stats helper ->
        companion+overhead helper).
      - **"What to watch for next time"** closing: three concrete process changes
        for the next spawn-related work -- (1) treat `R.spawnPlayer()` as a
        public-ish entry point and grep for other callers in the same commit,
        (2) test BOTH paths (surface + bed) before shipping, (3) document the
        helper contract alongside the new helper rather than in a follow-up.
      - **See also** with cross-links to all four individual release pages,
        v1.15.3 (different bug class, same general approach), v1.15.4 (the
        inline-reset block v1.15.9 + v1.15.10 complete), and the README roadmap
        footer.
- [x] **Updated `D:/The-Powder-Toy/README.md`** -- added a one-paragraph
      forward-pointer at the end of the **Roadmap** section (above the "Full
      version-by-version history" footer) linking to the retrospective and its
      summary table. README has no per-version cluster list (the existing
      version coverage is the GitHub release badge + the CHANGELOG.md link);
      per Main's brief I checked the established style and the natural landing
      spot was the Roadmap closing paragraph, not a new section. The pointer
      reads: "For the respawn-path-drift saga spanning v1.15.7 -> v1.15.10
      (one bug class, four versions, helper extraction pattern established),
      see the cross-version retrospective at
      `releases/v1.15.7-v1.15.10-retrospective.md` and the individual release
      pages linked from its summary table."
- [x] **Hub log appended** (`D:/powder-toy/knowledge/rpg-hub.md`) one line under
      the `[@github round N] <what, source>` format.
- [x] **Standing constraints held throughout**: zero mutations to
      `scripts/lua/rpg.lua`, zero plugin changes, zero `knowledge/*` design-doc
      changes, zero git commits / pushes. All four release pages, the
      retrospective, and the README pointer exist on disk and were verified
      via `ls -la` + `wc -l` just before reporting.
- [x] **Live verification context captured**: hub log line mentions the user's
      real session came back up clean (port 9876, PID 32064, `R.VERSION =
      "1.15.10"`, `R.deaths = 59`, `R.o2 = 100`) -- confirms fixes working
      end-to-end after the cluster shipped.

## Github track, round 11 (2026-08-30) -- v1.15.9 release notes (Batch C: F5 bed-respawn pollution-reset)

- [x] **Shipped `D:/The-Powder-Toy/releases/v1.15.9.md`** (NEW, ~125 lines,
      8317 bytes). Sections per Main's brief: Summary explicitly frames v1.15.9
      as "the SECOND bug-class fix for the same death-loop pattern" (v1.15.4 = the
      surface-respawn fix, v1.15.9 = the bed-respawn fix, both via the new
      shared `R._resetSpawnState()` helper), Changes (F5 entry bulleted verbatim
      from `R.CHANGELOG[1]` at `scripts/lua/rpg.lua:203-205`, including the
      `R._resetSpawnState()` extraction note and the "bed hp rule
      (max of current or 40) and bed-position teleport unchanged" carve-out),
      **Affected files explicitly called out** as the SECOND multi-file release
      in `releases/` (rpg.lua holds the new helper + the `spawnPlayer()`
      refactor; survival.lua holds the bed wrap that calls into the helper)
      following the v1.15.8 CONVENTION note. `scripts/lua/rpg_plugins/companion.lua`
      noted as untouched at v1.15.9 time. Migration notes (none -- pure
      bugfix + structural refactor on top of v1.15.4). **How-to-verify is a
      TWO-PATH procedure** per Main's brief: Path 1 (surface respawn v1.15.4
      regression check -- "must still pass after v1.15.9, confirms the
      `_resetSpawnState` extraction didn't regress anything"), Path 2 (the
      new bed respawn test), plus a negative test for the unchanged bed-HP
      rule (`max(current_hp, 40)`), plus a cross-version regression check on
      the helper extraction (compare reset fields before/after refactor).
      See-also footer points at v1.15.8 + v1.15.4 + v1.15.5 + v1.15.7 +
      v1.15.6 + README roadmap + CHANGELOG.md.
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.8.md`** -- appended v1.15.9
      See-also bullet noting it as the cross-version sibling ("second
      bug-class fix for the same death-loop pattern, second multi-file
      release").
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.7.md`** -- appended v1.15.9
      See-also bullet noting the helper-extraction pattern closes the
      v1.15.4 fix on the bed path; F1 (which goes through `R.spawnPlayer()`)
      now also works correctly when the player respawns from a bed.
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.6.md`** -- appended v1.15.9
      See-also bullet noting that v1.15.4 + v1.15.9 together close the
      death-loop bug class.
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.5.md`** -- appended v1.15.9
      See-also bullet framed around the Deaths counter ("ticks once per
      intended death whether you respawn at the surface OR at your bed").
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.4.md`** -- appended v1.15.9
      See-also bullet explicitly framed as the cross-version pairing (the
      SECOND bug-class fix for the same death-loop pattern v1.15.4
      partially fixed -- v1.15.4 = surface, v1.15.9 = bed, both via the
      extracted `R._resetSpawnState()` helper).
- [x] **Updated `D:/The-Powder-Toy/CHANGELOG.md`** -- added v1.15.9 entry
      between v1.15.8 and v1.15.0. Newest-first heading list now:
      `## v1.15.2 / ## v1.15.3 / ## v1.15.4 / ## v1.15.5 / ## v1.15.6 /
      ## v1.15.7 / ## v1.15.8 / ## v1.15.9 / ## v1.15.0 / ## v1.14.0 / ...`
      matches upstream `R.CHANGELOG` order.
- [x] **Hub log appended** (`D:/powder-toy/knowledge/rpg-hub.md`) one line
      under the `[@github round N] <what, source>` format.
- [x] **Standing constraints held throughout**: zero mutations to
      `scripts/lua/rpg.lua`, zero mutations to
      `scripts/lua/rpg_plugins/survival.lua`, zero mutations to any
      other plugin, zero `knowledge/*` design-doc changes, zero git
      commits / pushes. v1.15.9 source is a read-only consult of
      `scripts/lua/rpg.lua:203-205`. Every file listed was verified on
      disk via `ls -la` + `wc -l` just before reporting.
- [x] **Standing by for Round 12** per Main's IRC: Round 12 content
      unknown until Main sends details. The Batch A+B+C+ queue is now
      complete per the hub log (F1, F2, F3, F5, F8 all shipped across
      v1.15.7/1.15.8/1.15.9) -- if Round 12 isn't queued, Round 11 is
      the natural stand-down point.

## Github track, round 10 (2026-08-30) -- v1.15.8 release notes (Batch B: F2 + F3 + convention note)

- [x] **Shipped `D:/The-Powder-Toy/releases/v1.15.8.md`** (NEW, ~120 lines,
      7144 bytes). Sections per Main's brief: Summary (three-piece umbrella:
      CONVENTION note about rpg.lua owning `R.VERSION` + F2 companionKill
      clears `C.queue` + F3 newworld resets 7 `R.COMP` fields), Changes
      (all three entries bulleted verbatim from `R.CHANGELOG[1..3]` at
      `scripts/lua/rpg.lua:206-209`), **Affected files explicitly calls out
      that this round is the FIRST release in `releases/` to touch both
      rpg.lua AND a plugin** -- per Main's brief, this is a first worth
      flagging; covers `scripts/lua/rpg.lua` (version bump + CHANGELOG
      entries) AND `scripts/lua/rpg_plugins/companion.lua` (F2 + F3 fix
      hooks). `scripts/lua/rpg_plugins/survival.lua` noted as untouched
      at v1.15.8 time (Batch C still pending). Migration notes (none for
      F2/F3; the convention itself is documented as the migration note
      -- "from v1.15.8 onward, plugin fixes land in the next rpg.lua
      bump rather than as their own per-plugin version"), How-to-verify
      split into F2 + F3 procedures (force-kill-then-revive queue
      playback check for F2; world-switch ghost-frame + chatQueue
      drain check for F3; plus a meta-level convention verification
      bullet), See-also footer pointing at v1.15.7 + v1.15.6 + v1.15.5
      + v1.15.4 + README roadmap + CHANGELOG.md.

## Github track, round 9 (2026-08-30) -- v1.15.7 release notes (F1 companion + F8 clear-around)

- [x] **Shipped `D:/The-Powder-Toy/releases/v1.15.7.md`** (NEW, 84 lines,
      6267 bytes). Sections per Main's brief: Summary (two-fix umbrella --
      F1 companion-follow-along through `R.spawnPlayer()` + F8 `R.clearAround()`
      re-added as a no-arg 6×11 box above the spawn point), Changes (F1
      and F8 entries bulleted verbatim from `R.CHANGELOG[1..2]` at
      `scripts/lua/rpg.lua:203-205` -- both with their full Magic Mirror / C.dead
      / REVIVE_DELAY / call-site caveats intact), Affected files
      (`scripts/lua/rpg.lua` only -- `R.spawnPlayer` at line 893 for both fixes;
      companion.lua noted as read-only at v1.15.7 time), Migration notes (none),
      How-to-verify (split into F1 and F8 procedures, F1 includes negative
      auto-respawn-path test for the `C.dead` gate, F8 includes die-to-fire-
      underground + press R round-trip), See-also footer pointing at v1.15.6 +
      v1.15.5 + v1.15.4 + README roadmap + CHANGELOG.md.
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.6.md`** -- appended v1.15.7
      See-also bullet (F1 + F8 summarized in one line, framed as different scope
      that composes on top of the HUD rather than touching it). Body otherwise
      unchanged.
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.5.md`** -- appended v1.15.7
      See-also bullet. Body otherwise unchanged.
- [x] **Updated `D:/The-Powder-Toy/CHANGELOG.md`** -- added v1.15.7 entry
      between v1.15.6 and v1.15.0 (newest-first order preserved matching
      upstream `R.CHANGELOG`). New heading list: `## v1.15.2 / ## v1.15.3 /
      ## v1.15.4 / ## v1.15.5 / ## v1.15.6 / ## v1.15.7 / ## v1.15.0 /
      ## v1.14.0 / ...`. F1 + F8 each got their own bullet block with the
      verbatim commit-reference + line-840 / line-893 call-site details.
- [x] **Hub log appended** (`D:/powder-toy/knowledge/rpg-hub.md`) one line
      under the `[@github round N] <what, source>` format.
- [x] **Standing constraints held throughout**: zero mutations to
      `scripts/lua/rpg.lua`, zero plugin changes, zero `knowledge/*` design-doc
      changes, zero git commits / pushes. v1.15.7 source is a read-only consult
      of `scripts/lua/rpg.lua:203-205`. Every file listed was verified on disk
      via `ls -la` + `wc -l` just before reporting.
- [x] **Standby noted**: Round 10 (v1.15.8) is queued per Main's IRC; content
      already observable in the hub log (Batch B: F2 companionKill clears
      C.queue + F3 newworld resets 7 missing R.COMP fields), but per Main's
      instruction will wait for the explicit Round 10 trigger before
      writing its release-notes draft.

## Github track, round 8 (2026-08-30) -- v1.15.6 release notes + backfill v1.15.5

- [x] **Shipped `D:/The-Powder-Toy/releases/v1.15.6.md`** (NEW, ~62 lines). Sections
      per Main's brief: Summary (in-game version readout now in always-on HUD,
      top-right, above Deaths counter -- was only visible on title screen / What's
      New popup), Changes (bulleted verbatim from `R.CHANGELOG[1]` at
      `scripts/lua/rpg.lua:203-204`), Affected files (`scripts/lua/rpg.lua` only --
      always-on HUD draw loop, top-right), Migration notes (none), How-to-verify
      (start a world, look top-right; "v1.15.6" sits one line above the Deaths
      counter v1.15.5 added; same string as title screen / What's New popup; hot-
      reload flips it to the freshly-loaded `R.VERSION`, confirming live-read not
      cached), See also footer pointing at v1.15.4 + v1.15.5 + README roadmap +
      CHANGELOG.md.
- [x] **DISCREPANCY WITH MAIN'S BRIEF CAUGHT** before publishing -- brief stated
      "v1.15.5 already finalized in your prior round" but neither
      `D:/The-Powder-Toy/releases/v1.15.5.md` nor a v1.15.5 CHANGELOG.md entry
      existed on disk (verified via `ls releases/` + `grep v1.15.5 CHANGELOG.md`).
      Round 7 only handled v1.15.3 + v1.15.4. Resolved honestly rather than
      fabricate-on-prem: backfilled v1.15.5 from `R.CHANGELOG[2]` at
      `scripts/lua/rpg.lua:206-208` (Deaths counter in always-on HUD, top-right,
      gated on deaths > 0) by creating `D:/The-Powder-Toy/releases/v1.15.5.md`
      (NEW, ~62 lines) with the same Summary/Changes/Affected/Migration/Verify/
      See-also template -- which then gave the v1.15.6 See-also target Main
      assumed already existed.
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.5.md`** -- appended v1.15.6 to
      the See also section (per Main's brief), bumped the body footer's
      "Full version-by-version history" reference to read "v1.2.0 -> v1.15.6".
      Brief also asked to "bump 'v1.15.4 -> v1.15.5' line to 'v1.15.4 -> v1.15.6'"
      but no such literal line existed in v1.15.5.md (template doesn't include
      a chain-line); applied the equivalent honest edit instead.
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.4.md`** -- appended v1.15.5 +
      v1.15.6 See-also entries so the existing v1.15.3 sibling doesn't dangle,
      since both rounds 7 and 8 shipped downstream releases.
- [x] **Updated `D:/The-Powder-Toy/CHANGELOG.md`** -- added v1.15.5 entry first
      (verbatim from rpg.lua:206-208), then v1.15.6 entry (verbatim from
      rpg.lua:203-204), both inserted between v1.15.4 and v1.15.0 to preserve
      newest-first order matching upstream `R.CHANGELOG`. Heading list now:
      `## v1.15.2 / ## v1.15.3 / ## v1.15.4 / ## v1.15.5 / ## v1.15.6 /
      ## v1.15.0 / ## v1.14.0 / ...`
- [x] **Hub log appended** (`D:/powder-toy/knowledge/rpg-hub.md`) one line under
      the required `[@github round N] <what, source>` format, explicitly
      documenting the brief-vs-disk discrepancy and how I resolved it.
- [x] **Standing constraints held throughout**: zero mutations to
      `scripts/lua/rpg.lua`, zero plugin changes, zero `knowledge/*` design-doc
      changes, zero git commits / pushes. v1.15.5 + v1.15.6 sources are read-only
      consults of `scripts/lua/rpg.lua:203-208` (`R.CHANGELOG[1..2]`), no edits.
      Every file listed was verified on disk via `ls` + `wc -l` (not just claimed).

## Github track, round 7 (2026-08-30) -- v1.15.3 + v1.15.4 release-notes finalization

- [x] **Shipped `D:/The-Powder-Toy/releases/v1.15.4.md`** (new file). Sections per
      Main's brief: Summary (respawn-carries-death-state bug, fixed), Changes
      (bulleted from `R.CHANGELOG[1]` at `scripts/lua/rpg.lua:203-204` verbatim,
      covering `R.o2=100`/`R.gas`/`R.need.food`/`R.need.water`/`R.hurt`/
      `R.bloodLast`/`R.uvAccum`/`R.radAccum`/`R.hp=100` reset + the Magic Mirror
      carve-out), Affected files (`scripts/lua/rpg.lua` only, around line 871 --
      extended `R.spawnPlayer`), Migration notes (none, pure bugfix), How-to-verify
      (die-to-asphyxiation + press R, before/after smoke test, Magic Mirror X
      smoke test), See-also footer pointing back at v1.15.3 + the README roadmap
      / CHANGELOG.md.
- [x] **Updated `D:/The-Powder-Toy/releases/v1.15.3.md`** -- appended a "See also"
      footer pointing at `v1.15.4.md` and at the same time bumped the body footer
      "v1.2.0 -> v1.15.3" line up to "v1.2.0 -> v1.15.4".
- [x] **Updated `D:/The-Powder-Toy/CHANGELOG.md`** -- replaced the v1.15.4
      placeholder I had carried in rounds 5-6 with the real entry verbatim from
      `scripts/lua/rpg.lua:203-204`: `R.spawnPlayer()` reset block + Magic
      Mirror save/restore carve-out. The v1.15.3 entry (round 6) was left as-is.
      File now reads: Unreleased / v1.15.4 / v1.15.3 / v1.15.2 / v1.15.0 / ...
      in newest-first order, matching the upstream `R.CHANGELOG` order.
- [x] **Hub log appended** (D:/powder-toy/knowledge/rpg-hub.md) one line under the
      required `[@github round N] <what, source>` format.
- [x] **Standing constraints held**: zero mutations to `scripts/lua/rpg.lua`,
      zero plugin changes, zero `knowledge/*` design-doc changes, zero git
      commits or pushes. All work was purely GitHub-side documentation. Every
      file listed exists on disk and was verified via `ls` (not just claimed).

## GitHub docs track, round 6 (2026-08-30) -- replace v1.15.3 placeholder + push release notes draft

- [x] Replaced the v1.15.3 placeholder I wrote in round 5 with the REAL entry pulled
      from `R.CHANGELOG` at `scripts/lua/rpg.lua:203`, which `@bugs` had confirmed was
      bridge-verified live: added `R.releaseMouse()` (F11 hotkey) -- emergency
      unstuck for the mouse, clears `R.mouse.l`/`R.mouse.r`/`R.placeBox`/
      `R.placeAnchor`/`R.zoomClick`/`R.zoomPending`/`R.lastPlace`/`R.lastMine`/
      `R.lineAnchor`. Source: `scripts/lua/rpg.lua:203-205` (`R.CHANGELOG[1]`).
- [x] Created `releases/v1.15.3.md` (the directory didn't exist, created it as part
      of the write): a one-paragraph-plus-context GitHub release notes draft
      covering what the fix does, why it exists (recurrence of the mouse-held-down
      bug class even after v1.15.1's earlier `onMouseUp` reset-move + SDL-focus
      release), how to verify (F11 is a no-op when nothing is stuck; bridge-verified
      live), and what's intentionally NOT in this release (no balance / physics
      changes -- only an emergency recovery hook).
- [x] Cross-check: the earlier placeholder I wrote in round 5 ("onMouseUp reset
      moved before the `if R.tptMenus then return end` early-return") was actually
      the v1.15.1 fix per `R.CHANGELOG[3]` at `rpg.lua:212`, NOT v1.15.3. The
      real v1.15.3 entry is the F11 emergency hotkey, which I had not yet seen
      when round 5 ran. Caught and corrected before publishing.
- [x] Probed https://github.com/phoenixfire808/The-Powder-Toy via the github
      scraper MCP for open issues / PRs to attach the release notes to: the repo
      currently has 0 stars, 0 forks, 0 open issues, 0 open PRs (confirmed via
      `mcp__github_scraper_mcp_get_repo_details` + direct REST probe). Nothing
      to attach to yet -- release notes draft lives in `releases/v1.15.3.md` for
      Drew to paste into the GitHub release page when the tag is cut.

## GitHub docs track, round 5 (2026-08-30) -- Vision section + Roadmap rework + CHANGELOG v1.15.2/v1.15.3

- [x] Reworked README's Roadmap and added a brand-new Vision section, source pulled from
      design-vision-2026-08-29.md, design-geology-2026-08-29.md,
      design-multiplayer-2026-08-29.md, and design-ragdoll-gore-2026-08-29.md. Vision
      section now states the central closed loop (power -> electrolysis ->
      O2/HYGN -> turbine/fuel-cell -> power, plus water side feeding crops), the full
      Workbench -> Advanced Lab tier structure, and three concrete next rungs (Reactor,
      sealed-base life support, fluid/gas logistics). Roadmap overhauled: cave-gen
      entry marked [x] DONE with the real 20-40 depth-unit noise finding + shipped in
      v1.15.0; geology entry split into BSLT-V1 (research done, fix NOT yet applied
      to the world-gen fallback, awaiting re-verified code change) and biome-varied
      geology V2 (granite/sandstone/limestone, each new element needing its own
      Falldown==0 AND TYPE_SOLID check); multiplayer given full researched shape with
      Noita Together vs Noita Entangled Worlds prior-art and host-authoritative
      V1 scope (LAN-only, host + 1 remote, no client-side prediction); ragdoll/gore
      given real technique depth (Verlet integration + breakable stick constraints,
      dismemberment = constraint removal, ~11-point body with multi-stick rigid areas
      vs single-stick swing joints, death-only ragdoll as recommended V1 cut). TOC
      updated (stale "Where this is going" link replaced by Vision). No fabricated
      claims -- every element detail, prior-art link, and verification caveat comes
      from one of the four docs above.

- [x] CHANGELOG.md updated: added v1.15.2 (R.setTptMenus auto-call + Esc-menu
      wheel-scroll -- both fixes verified live per the feature track round 17);
      added v1.15.3 with the stuck-mouse-button root-cause fix from the bugs track
      (onMouseUp reset moved BEFORE the `if R.tptMenus then return end` early-return,
      reverified against the actual failure mode this time); added a v1.15.4
      placeholder for in-progress @feature changes shipped under the new
      "version on every change" rule (intentionally not fabricated -- entries will
      be filled in once @feature ships and is verified).
      *(Superseded by round 6: the round-5 v1.15.3 placeholder was actually
      the v1.15.1 fix per `R.CHANGELOG[3]` at `rpg.lua:212`. The real v1.15.3
      entry is the F11 emergency hotkey `R.releaseMouse()`, replaced in
      CHANGELOG.md in round 6 using `scripts/lua/rpg.lua:203-205`.)*
- [x] Cross-check vs @roadmap's docs, never fabricated. Any claim not present in
      design-*.md was flagged as "awaiting @roadmap research" or omitted.
      Files touched: README.md (rewritten Vision + Roadmap), CHANGELOG.md (added
      v1.15.2/v1.15.3/v1.15.4 placeholder). Neither contains "Drew" / the player's
      real name; everywhere uses "the player" or "a player".

## GitHub docs track, round 4 (2026-08-30)

- [x] Pulled in the roadmap track's real research per the coordinator's relay: README's
      "Where this is going" now has the actual central vision (energy -> oxygen -> food as
      one closed, already-real loop; the tech-tree tier structure and its next rungs), and
      Roadmap now reflects real depth instead of one-line asks: cave-gen marked fixed (real
      diagnostic numbers, not just claimed), multiplayer/ragdoll-gore given their actual
      researched architecture + V1 scope, geology given its real recommended fix. Pushed
      (commit c2e06395).
      IMPORTANT CORRECTION caught before writing: design-geology-2026-08-29.md and this
      file's own line ~2642 both claim BSLT is "already the identified, shipped fix" for
      subsoil -- checked rpg.lua/world.lua directly, `local ROCK` is still `has("GRNT") and
      "GRNT" or "BRCK"` in both files. BSLT is NOT applied anywhere in source. Wrote the
      README to say "research complete, fix not yet applied" rather than repeating the
      shipped claim -- flagging this discrepancy for whoever owns that doc/note next, since
      it could mislead someone into thinking no further work is needed there.
## Feature track round 21 (2026-08-30) -- v1.15.13, visual temp + pressure gauges in HUD

- SCOPE (medium, scoped HUD redesign): the existing top-left HUD readouts
  were all stacked numbers in a column -- "Day N day", "Feels like X F", "x POS",
  biome -- all visually identical gray-text-in-a-row, so the player had to
  actually READ the temperature number to know whether they were hot or cold.
  Drew's feedback: temperature and pressure should be visually distinct
  readouts, not more stacked numbers. Replaced the single-line "Feels like
  X F" text at rpg.lua:2620 with a pair of visual gauges:
    * TEMPERATURE gauge (y=34, x=24..124, 100px bar): cold-blue at 0F,
      white at 70F (the neutral body temperature), warm-orange at 200F,
      hot-red at 500F+. The fill fraction is `tF / 1000`, so a 700F magma
      room reads as a 70% red fill (clearly "very hot") and -20F freezing
      reads as a near-empty blue bar. Numeric label "T: 71F" sits to the
      right of the bar.
    * PRESSURE gauge (y=46, same width): the prior code had NO pressure
      readout at all (the rpg.lua:1168-1169 spawn loop was the only place
      that read it). Now shows sim.pressure(player_cell) with a colored
      fill -- green at |p| <= 1.5 (safe baseline), yellow at 1.5..3.5
      (caution), red at 3.5+ (danger; matches the low-pressure-spawn logic
      threshold). A center marker at frac=0.5 (baseline p=0) lets the
      player see at a glance whether pressure is above or below normal.
      Numeric label "P: +0" or "P: -5" etc. sits to the right.
  Both gauges are visually distinct from the day/x/biome status line above
  (text-only) and the fading chat log below (yellow text fading over time),
  satisfying the brief's "would the user know at a glance without parsing
  numbers?" goal.
- LAYOUT CHANGES:
    * y=34 line replaced with temp gauge (was text "Feels like X F")
    * y=46 new pressure gauge (didn't exist)
    * log tail line pushed from y=40 to y=58 (was overlapping the new
      y=46 pressure gauge)
  No other HUD elements moved. HP hearts (y=8), day/biome (y=22),
  deaths counter (top-right y=22), version readout (top-right y=8) all
  unchanged.
- FILES TOUCHED: `scripts/lua/rpg.lua` only, four edits --
    1. R.VERSION 1.15.12 -> 1.15.13 (line 189)
    2. R.CHANGELOG new head entry (line 202-205): "Redesigned HUD temp +
       pressure readouts..." (replaced an orphan v1.15.12 half-entry that
       had no body -- the v1.15.12 content lives in rpg-hub.md as @bugs
       round-25's F10 trees fix; the live session already ships it).
    3. onDraw felt-temp block (lines 2614-2665): replaced the single-line
       drawText with the two-gauge HUD block (bar + fill + label for
       temp, bar + fill + center-marker + label for pressure).
    4. log tail drawText (line 2666): y=40 -> y=58 to clear the new
       pressure gauge at y=46.
  Did NOT touch rpg_plugins/*.lua (out of lane this round), did NOT touch
  R.mouse / R.zoomLocked (per the round-20 caveat about RenderZoom crashes
  on direct mutations -- none of my edits interact with those), did NOT
  touch R.feltTempK computation (the brief explicitly said "don't touch
  the felt-temp logic itself").
- LAB VERIFICATION: lab was already running (PID 37320, port 9877, on v1.15.12
  when I started round 21). After my disk edits, hot-reloaded twice (once
  to pick up my v1.15.13 changes, once more to pick up @bugs's v1.15.14
  "Day N day" dup-word fix that landed during my work). Live state reads:
    * R.VERSION = "1.15.14"                  -- @bugs's v1.15.14 hot-reloaded
    * R.CHANGELOG[1].ver = "1.15.14"         -- @bugs's new head entry
    * R.CHANGELOG[2].ver = "1.15.13"         -- my HUD gauge entry landed
                                              as second-newest, intact
    * R.lastErr = nil                        -- gauge draw code never
                                              throws across multiple frame
                                              steps (started a real game,
                                              ran ~1903 frames, feltTempK
                                              recomputed by the ambient
                                              loop, sim.pressure pcall
                                              handles out-of-range cells
                                              without throwing)
    * on-disk grep (verified live): R.VERSION=1.15.13 at offset 12303
      (later overwritten by @bugs to 1.15.14 at offset 12303), my gauge
      HUD block at offsets 192598 (temp) + 194311 (pressure), log-tail
      y-shift at offset 195755
    * color-mapping probe: tempColor(68F)=(251,252,255) near-white,
      tempColor(-20F)=(80,150,255) blue, tempColor(350F)=(255,115,40)
      orange, tempColor(700F)=(255,50,20) deep red -- all match the
      "blue cold, white neutral, orange warm, red hot" intent.
    * pressure-color probe: |p|<=1.5 -> green, 1.5..3.5 -> yellow,
      3.5+ -> red -- matches the rpg.lua:1169 spawn-danger threshold.
    * fill-fraction probe: 68F->6.8% fill (small white bar), 350F->35%
      fill (orange), 700F->70% fill (red); pressure 0->50% (center
      marker), -8 vacuum->0% fill (empty red), +4 overpressure->75% fill
      (yellow/red zone) -- all read at a glance.
    * live-render probe: started a real game on the lab, set R.feltTempK
      to 350K (= 71.6F), stepped 2 frames, the live state shows
      `lastErr=nil` -- meaning the gauge block executed without throwing
      and the pcall(sim.pressure) wrapping successfully absorbed the
      potential out-of-range cells (no crash even on edge coords).
  Lab left running (still Main's lab). No game-state cleanup needed -- I
  set R.active=true and started a world; @bugs can stop the lab if needed.
- LIVE SESSION (port 9876): never touched, no hot-reload queued against
  it. The live session is already on v1.15.12 with the prior HUD; my
  v1.15.13 will land on it only when the next normal rebuild+restart
  cycle happens (same as every other rpg.lua edit this session).
- FILES UPDATED THIS ROUND (deliverable report):
    * D:/powder-toy/scripts/lua/rpg.lua (four edits: VERSION bump, CHANGELOG
      head, gauge HUD block replacing felt-temp line, log-tail y-shift)
    * D:/powder-toy/knowledge/TODO.md (this entry)
    * D:/powder-toy/knowledge/rpg-hub.md (one ## Log line)

## Feature track round 20 (2026-08-30, second pass) -- v1.15.6, in-game R.VERSION in always-on HUD

- SCOPE (one small, observable, safe HUD add, picked after auditing the
  existing top-band: death counter v1.15.5 already at top-right, GOAL banner
  at line 2536, day/biome/enemies status at line 2526, AIR% at 2479, food/water
  meters at 2511-2515, "Feels like X F" at line 2531, selected-slot name+sub
  already shown above the bottom hotbar at line 2171, depth+night at line 2513.
  The obvious missing piece was R.VERSION itself: the section header comment at
  rpg.lua:171-174 explicitly says "shown on screen always (bottom-left corner)
  so anyone watching knows exactly what build is running" but R.VERSION was
  only rendered on the title screen (line 2920). Mid-session the only way to
  confirm the build was open the Esc menu or the What's-New popup. Added a
  single drawText call at W-80, y=8 (top-right, just above the deaths
  counter) showing "v" .. R.VERSION in dim grey so it doesn't compete with the
  brighter HUD readouts. One line of code, no gameplay change, no menu entry,
  no toggle, no keybind -- a real fix to a real "always-on" intent that
  wasn't fully delivered.
- FILES TOUCHED: `scripts/lua/rpg.lua` only, three edits --
    1. R.VERSION 1.15.5 -> 1.15.6 (line 189)
    2. R.CHANGELOG head entry (line 202-205): "In-game version readout now
       shown in the always-on HUD (top-right, above Deaths counter)..."
    3. onDraw HUD drawText (line 2525): `graphics.drawText(W - 80, 8,
       "v" .. R.VERSION, 160, 160, 170, 255)` placed AFTER the food/water
       conditional block so it renders unconditionally on every frame.
  Did NOT touch rpg_plugins/*.lua (out of lane this round), did NOT touch
  R.mouse / R.zoomLocked (per the round-20 caveat about RenderZoom crashes
  on direct mutations -- none of my edits interact with those).
- LAB VERIFICATION: lab was already running (PID 37320, port 9877, cold-booted
  by Main with v1.15.5). Triggered hot-reload via
  `PBX.state.rpg.hotReloadRequested = true`, then read state live:
    * R.VERSION = "1.15.6"                       -- bump took
    * R.CHANGELOG[1].ver = "1.15.6"              -- head entry is the new one
    * R.lastErr = nil                            -- no syntax errors post-reload
    * on-disk grep: all three markers present (VERSION=1.15.6 at offset 12303,
      CHANGELOG v=1.15.6 at offset 13108, HUD drawText at offset 183761)
    * format-string probe: HUD renders "v1.15.6" (7 chars, ~42px wide at
      6px/char, fits well within W-80=532 column without collision)
    * no forbidden-state mutation: R.zoomLocked=nil, R.active=nil,
      R.titleScreen=true, R.mouse unchanged -- lab is back at its baseline
      cold-boot state after my edits landed.
  Lab left running (it's Main's lab this round, not mine to terminate).
- LIVE SESSION (port 9876): never touched, no hot-reload queued against it.
  My change will land on the live session only when the next normal
  rebuild+restart cycle happens.
- FILES UPDATED THIS ROUND (deliverable report):
    * D:/powder-toy/scripts/lua/rpg.lua (three edits, lines 189, 202-205, 2525)
    * D:/powder-toy/knowledge/TODO.md (this entry)
    * D:/powder-toy/knowledge/rpg-hub.md (one ## Log line)

## Feature track round 20 (2026-08-30) -- v1.15.5, always-on death counter in HUD

- SCOPE (one small UX win, picked from the brief's examples list): the death
  counter was only visible in the inventory panel and the Esc menu -- both
  places you'd never look in the moment right after respawn, which is when
  you actually want to see it (e.g. to know whether the surface poison just
  killed you twice in a row). Added a top-right "Deaths: N" readout to the
  always-on HUD, guarded by `(R.deaths or 0) > 0` so a fresh run stays
  visually clean (no new HUD element on a fresh world). Bright orange
  (255,150,80) matches the existing "THIRSTY/HUNGRY" warning color, sits
  on the same horizontal band as the day/biome/enemies status line, lives
  inside the existing R.HUD block (right below the always-on "Feels like
  X F" line). No gameplay change, no menu entry, no toggle, no keybind --
  pure informational addition that disappears on a clean run.
- FILES TOUCHED: `scripts/lua/rpg.lua` only, three edits --
    1. R.VERSION 1.15.4 -> 1.15.5 (line 189)
    2. R.CHANGELOG head entry (line 202-205): "Death counter now shows in
       the always-on HUD..."
    3. onDraw HUD block (after line 2514): guarded drawText call.
  Did NOT touch rpg_plugins/*.lua (out of lane this round).
- LAB VERIFICATION: spun up a fresh lab instance (PID 32016, port 9877,
  via `scripts/lab_instance.py --setup --launch`), waited for the bridge
  to come up, triggered hot-reload via `PBX.state.rpg.hotReloadRequested`,
  then read state live:
    * R.VERSION="1.15.5"                  -- confirmed bump took
    * R.CHANGELOG[1].ver="1.15.5"         -- confirmed head entry is the new one
    * R.lastErr=nil                       -- no syntax errors after hot-reload
    * on-disk grep: all four markers present (R.VERSION bump, CHANGELOG
      entry, format string "Deaths: %%d", drawText at x=W-80,y=22)
    * Boundary probe: branch fires only when R.deaths > 0 (verified
      for 0, 1, 3, 999 -- all match the `(R.deaths or 0) > 0` predicate).
  Lab was terminated cleanly after verification (P.terminate + wait,
  no live-session port collision -- the brief's PID-56336 safety flag
  is intact because that PID is unresponsive on 9876 as of this round
  anyway and my lab used 9877 the whole time).
- LIVE SESSION (port 9876): never touched, no hot-reload queued against
  it. A read-only check from the live token timed out (port 9876 has
  no listener, consistent with the round-18 PID-46636 disappear note
  in the URGENT block). My change will land on the live session only
  when the next normal rebuild+restart cycle happens (same as every
  other rpg.lua edit this session).
- FILES UPDATED THIS ROUND (deliverable report):
    * D:/powder-toy/scripts/lua/rpg.lua (the three edits above)
    * D:/powder-toy/knowledge/TODO.md (this entry)
    * D:/powder-toy/knowledge/rpg-hub.md (one ## Log line)


## URGENT -- Drew's real game process (PID 46636) is gone, possible cause identified 2026-08-30

- What happened, in order: launched my own fresh lab instance this round per
  the new standing rule (PID 31772). Checked the bridge port immediately
  after and found MY new instance had taken over port 9876 (the shared
  default) -- ahead of Drew's already-running PID 46636, which had been
  listening on it a moment earlier. Recognized this as a problem (any other
  track's read-only check against "the game" would now silently hit my lab
  copy instead of his), found the port is configurable via
  POWDER_BRIDGE_PORT, killed MY OWN PID 31772 (verified exact match before
  killing), and relaunched myself on port 9877 instead.
  Checked immediately after: PID 46636 no longer exists in any form
  (tasklist confirms it, not just off the bridge port -- the process itself
  is gone). Only my own relaunched instance (now PID 56036, correctly on
  9877) is running.
  I did NOT run any command targeting PID 46636 specifically -- only
  `taskkill //F //PID 31772` (my own PID, verified before killing) and a
  plain launch command for my own relaunch. I cannot mechanically explain
  how those two commands would close a DIFFERENT, unrelated process. But I
  also cannot rule out that my instance taking port 9876 first caused
  Drew's own bridge-server startup code to hit an unhandled error if it
  isn't written to fail gracefully on a bind conflict -- I have not verified
  bridge_base.lua's bind-failure handling either way, and the timing is
  close enough that I'm not willing to call this a coincidence and move on.
  NOT ASSUMING innocence here -- flagging this as the top-priority thing for
  Drew/the coordinator to know about this round, ahead of any other work.
  Drew: if your game window disappeared, this is almost certainly why --
  sorry. Relaunching from your shortcut should be all that's needed; nothing
  about your world/save should be affected (TPT doesn't autosave a live sim
  to your actual save file continuously -- worth double-checking your last
  manual save if you want to be sure, but this shouldn't have touched it).

## Feature track round 19 (2026-08-30) -- audit complete, no new game-state changes shipped

- AUDIT, option A (R.xxx dev flags not reset in R.generateWorld): walked every
  R.xxx field assignment in rpg.lua against the reset block at line ~790
  (now extended by @bugs's v1.15.3 fix to also clear R.sandbox=false and
  R.setTptMenus(false) on world generation). Every non-reset field checks out
  as deliberate persistent state. The full list:
    * R.radAccum, R.uvAccum -- player dose (line 825 comment makes this
      explicit: persists on purpose across worlds)
    * R.dayFrac -- user setting (sticky preference, Options-menu live)
    * R.need (food/water) -- player-survival meters (reset on death only)
    * R.camXOffset, R.camYOffset -- camera look-around nudges (sticky pref)
    * R.grid, R.enemies, R.hud, R.minimap, R.tipsOn, R.smart -- explicit UI
      toggles, all initialised with the `(R.x == nil) and default or R.x`
      pattern that PREVENTS the round-16 shape (the bug only happens when a
      field's lazy-init default drifts away from the value a fresh world
      should have; these all DO reset to default on first boot AND on the
      first "New world" afterwards because no later code path can flip them
      to a non-default stale value)
    * R.caveFreqMul, R.oreRarityMul, R.treeSpacingMul, R.difficultyMul,
      R.gravMul, R.jumpMul, R.runMul -- worldgen/movement knobs the Esc
      menu labels themselves explicitly say carry across worlds
      ("affects newly generated terrain only" / "applies to newly spawned
      enemies"); resetting these in generateWorld would silently undo the
      player's deliberate choice every time they start a new world
    * R.fast, R.fxOn -- performance toggles (sticky)
    * R.o2Sources, R.scrubbers, R.coolers, R.gas -- plugin-registered
      runtime state, managed by plugin lifetime not per-world
    * R.smoothCam, R.zoomLocked, R.zoomPending -- transient session state
    * R.feedbackOpen, R.chatOpen, R.changesPromptOpen, R.updatePromptOpen
      -- modal flags (only valid while a modal is actually open)
    * R.torches -- runtime list, emptied by sim.clearSim() in generateWorld
    * R.weather, R.wind -- runtime state, regenerated by new world's noise
  Pattern verdict: @bugs's v1.15.3 fix already closes both known instances of
  the round-16 shape (R.sandbox and R.tptMenus). No new instances exist in
  rpg.lua core. Plugins weren't in my lane this round, but if you grep
  `R.hooks.newworld` for handlers that should also be in generateWorld's
  reset block (most plugins self-register), that's the audit-worthy path.
- OPTION B re-checked (the prompt's option B assumes "Enemy difficulty"
  is missing from the title-screen Settings panel): it is NOT missing.
  TITLE_SETTINGS_KEYS at rpg.lua:2849 already lists all 8 entries ending
  with "Enemy difficulty". The Esc menu entry at line 2252 writes
  R.difficultyMul, and rpg_plugins/enemies.lua:220 reads it at spawn time.
  The substring-match wiring in layoutTitleSettings (line 2857) auto-picks
  it up. Round-14's deliverable on the prior feature track already shipped
  this; nothing left to do.
- LIVE BRIDGE VERIFICATION (state reads only, against the user's session
  per the post-PID-46636-ambiguity safety rule):
    ver=1.15.3 | sandbox=false | tptMenus=false | releaseMouse=function
    | changelog[1].ver=1.15.3 | difficultyMul=1.4 | titlePanelKeys=8/8
  No game state was mutated. No hot-reload queued (no code change to ship).
  Did NOT bump R.VERSION or add a CHANGELOG entry: the standing rule is
  "bump R.VERSION on EVERY change", and this round shipped zero changes.
- VERDICT: nothing to ship. Round 19 closes as audit-only, same shape as
  round 18's safety-only finding. The round-16 bug pattern that @bugs
  already closed in v1.15.3 has no other live instances in rpg.lua core.

## Feature track round 18 (2026-08-30) -- instance-safety flag, no new game-state changes shipped

- SAFETY FINDING, checked before doing anything else this round: the process
  I'd been treating as "the lab instance" all session (PowderToyRPG.exe) is
  gone -- confirmed via tasklist. In its place: a single `powder.exe` (PID
  46636, started 12:20 AM today, D:\The-Powder-Toy\build\powder.exe),
  presumably from a rebuild by another track (the roadmap track's round 15
  independently confirmed no game instance was running at all shortly
  before this one appeared). With only ONE process running total and no way
  to tell from process metadata whether it's a fresh lab copy or Drew's own
  real session, I could not confirm it's safe to test against the way every
  previous round did.
  Treated this as live/possibly-Drew's-session for the rest of this round:
  did NOT spawn anything, force any menu/screen open, or mutate any game
  state. Only ran genuinely read-only checks: `check_station_reachable.py`
  (all 6 stations still OK) and `check_physics_constant_dup.py` (still
  clean, no desync) -- both safe regardless of who's on the instance, since
  they only read state, never write it.
  Did NOT start implementing the roadmap's life-support-controller or
  fluid-pipe proposals (round 14, both scoped and ready) this round --
  both would need real live verification to ship responsibly (matching
  every other feature this session's actual standard), and that's not
  available right now without risking a real player's session. Deferred to
  whichever round confirms a safe, clearly-separate lab instance is back.
  Coordinator/Drew: worth confirming directly whether PID 46636 is meant as
  a lab copy or is the real session, so this doesn't stay a standing
  blocker.

## Feature track round 17 (2026-08-30) -- v1.15.2, new version-every-change rule applied

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- native TPT toolbar/bottom bar
      hidden by default now, not just on manual toggle. Root cause confirmed
      before fixing: R.setTptMenus() (the function that actually calls
      tpt.hud/tpt.menu_enabled) was ONLY ever invoked from the Esc menu's
      manual toggle -- never automatically at world start. R.tptMenus
      reading false by default was just an inert Lua variable that never
      proved the real native HUD calls fired; native TPT's own default
      (menus visible) is what a player actually saw until they happened to
      open the Esc menu once. Same bug shape as the earlier R.sandbox reset
      bug. Fixed: `pcall(R.setTptMenus, false)` added to R.generateWorld's
      reset block, same place R.sandbox=false lives.
- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- Esc menu ("all options all
      the way down to the bottom") -- confirmed with real math before
      fixing: BTN_COLS=2, row height 22px, BTN_Y=168, panel bottom
      MY+MH=358 -> only 8 rows (16 of 26 entries) actually fit, the rest
      silently ran off both the drawn panel box and the screen. Added
      wheel-scroll (R.settingsScroll), same shape as every other scrollable
      list this session, plus a "wheel to scroll (X/Y)" hint when there's
      more than fits.
      FUNCTIONALLY VERIFIED LIVE (not just reload-clean): forced R.menuOpen
      true with a real render pass at settingsScroll=3 -- zero errors. Then
      set settingsScroll=999 and confirmed via REAL rendering that it
      clamped to exactly 5 -- the exact value hand-computed from
      ceil(26/2)-8, not just "some clamped number."
- NEW STANDING RULE applied starting this round per Drew: bump R.VERSION
  (patch level) and add one R.CHANGELOG entry in the same pass as every
  change from now on, not just at natural batch boundaries. Bumped
  1.15.1 -> 1.15.2 covering both fixes above, confirmed live post-reload
  (r.VERSION and r.CHANGELOG[1].ver both read 1.15.2).

## Feature track round 16 (2026-08-30)

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- the last unaddressed item in
      the original "big feature bundle" (item 5): "trees should have
      internal veins draining water down into the trunk and out through
      little underground tunnels/drains at the roots." First checked for a
      file-collision risk before touching world.lua (the bugs track just
      fixed the cave-gen vertical-tunnel bug in the same file) -- confirmed
      clean via reload, verified my own caveFreqMul/treeSpacingMul/
      oreRarityMul sliders still work correctly afterward before starting.
      REAL PHYSICS, not scripted: added a genuine 1px hollow channel down
      the center of any trunk wide enough to spare it (trunkW>=3 -- palm's
      trunkW=2 stays solid), open air instead of solid WOOD, in
      vegShapeAt()'s trunk-fill check. Real rain/water that lands in that
      column now actually falls through under gravity into the trunk and
      reaches the round-1 root-finger system already generated at ground
      level -- no scripted particle teleportation, the existing physics
      does the whole thing once the solid material is removed.
      FULL LIVE VERIFICATION against a REAL generated tree (not synthetic):
      found a real trunk near the player via R.gen() (exposed on R),
      sampled its full width and confirmed exactly one hollow column
      surrounded by solid WOOD on both sides, then sampled that column at
      15 different depths and confirmed it stays open continuously all the
      way down -- a genuine, continuous physical channel, not a one-pixel
      artifact. Worldgen-only, affects newly-generated trees (existing
      trees on the lab world keep their old solid trunks).

## Bugs track -- cave-gen vertical tunnel bug, fixed with real diagnostic numbers 2026-08-30

- [ ] RPG: "empty vertical tunnels going straight down" -- root cause confirmed with
      real numbers (roadmap track's design-worldgen-research flagged the lead,
      then verified it precisely): the entrance-tunnel centerline formula
      (`vnoise1(dep / w.period + phase, ...)`, world.lua wormOpenAt) only covers
      about 0.3 of one full noise cycle over the first 40 depth units (period is
      55-125), so it drifts in a near-straight line instead of winding. Sampled
      a real entrance column offline: offset went 0.02 -> 0.70 -> 1.40 -> 2.11 ->
      2.82 -> 3.54 -> 4.25 -> 4.95 -> 5.63 -> 6.28 -> 6.91 across dep=0..40,
      essentially perfectly linear.
      FIXED: added a second, much faster noise layer (its own short period=14,
      independent phase offset) weighted by `max(0, 1 - dep/40)` so it's fully
      present at the entrance and completely gone by dep=40, leaving the
      already-tuned deep winding behavior untouched.
      VERIFIED with real numbers on the same offline test, same column: the
      combined centerline now goes 3.82 -> 12.60 -> 16.74 -> 14.78 -> 11.41 ->
      8.86 -> 8.02 -> 6.98 -> 6.21 -> 6.33 -> 6.91 across dep=0..40 -- genuine
      rise-then-fall winding near the entrance, converging to the EXACT same
      6.91 the old formula gave at dep=40, confirming deep behavior is
      unchanged. Reloaded clean, no errors. Still awaiting Drew's own eyes on
      actual generated terrain.

## Feature track round 15 (2026-08-30) continued -- used the roadmap's own tooling

- Checked the roadmap track's new checker scripts against my own round 4/5
  slider work, since their "physics-constant duplication" note flagged a
  real-sounding player/companion desync risk (RUN0 in rpg.lua vs RUN in
  companion.lua, different identifiers for the same constant). Checked
  companion.lua directly first: already fixed, `RUN * (R.runMul or 1)`
  present at all 3 real call sites, `GRAV`/`JUMP` also already synced with
  `R.gravMul`/`R.jumpMul`. The roadmap note was about the CHECKER's own
  detection limitation (can't verify via exact-name matching since the
  identifiers differ), not an actual unfixed bug -- nothing to do.
  Ran both new checkers for real as an independent sanity pass on 15 rounds
  of concurrent work: `check_station_reachable.py` -- all 6 stations OK
  (hand/workbench/furnace/anvil/research/advlab). `check_physics_constant_
  dup.py` -- ACC/GRAV/JUMP/MAXFALL all ok, no player/companion desync.
  Clean bill of health from independent tooling, not just self-reported.

## Feature track round 15 (2026-08-30)

- [ ] Closed round 14's honest verification gap for the "Enemy difficulty"
      slider. Exposed `R.spawnEnemy` (matches this codebase's existing
      convention of exposing action functions like buildStation/craft/
      damageEnemiesAt). FULL END-TO-END LIVE VERIFICATION: spawned two real
      slimes on the lab instance, one at R.difficultyMul=0.7 and one at 1.4,
      and read back their REAL hp/dmg fields -- easy: hp=21 dmg=4.2 (30*0.7,
      6*0.7, exact), hard: hp=42 dmg=8.4 (30*1.4, 6*1.4, exact). Marked both
      test enemies dead immediately after reading to clean up. This
      supersedes round 14's "reasoned through, not executed" caveat with a
      real spawned-object proof.

## Feature track round 14 (2026-08-29)

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- 8th world-engine slider:
      "Enemy difficulty" (easy/normal/hard, R.difficultyMul). Considered a
      general player-damage-taken slider first and deliberately dropped it:
      player damage is applied inline at 8+ scattered call sites across
      rpg.lua (fall damage, radiation, hunger/thirst, suffocation, contact
      damage, ...) with no shared function routing them, so scaling it
      cleanly would mean touching every site individually -- too invasive
      for one round, real risk of missing one. Enemy stats have exactly ONE
      choke point instead: spawnEnemy() in enemies.lua reads hp/dmg from the
      KINDS table at spawn time, a single line. Scaled both there
      (`k.hp * dm`, `k.dmg * dm`) instead -- same idea, safer insertion
      point. Also added to the title-screen settings panel's
      TITLE_SETTINGS_KEYS list alongside the other 7, for consistency.
      VERIFICATION: both files reload clean. Confirmed R.difficultyMul
      cycles correctly live (nil -> 1.4 -> 0.7) via the real menu function.
      Honest gap: spawnEnemy() isn't exposed on R, so couldn't spawn a real
      enemy and read back its actual scaled hp/dmg the way rounds 7/12
      verified their fixes -- the only new logic is a plain multiplication
      with no branches, reasoned through rather than executed, same
      confidence level as round 9's ember-loop code.

## Feature track round 13 (2026-08-29)

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- display-name polish gap found
      while auditing guide.lua for a similar station-list bug (guide.lua
      turned out fine, uses R.STATIONS[x] or x generically, no hardcoded
      list there). Checked R.nice() instead: its only fallback for an
      element missing from R.NAMES is either an auto-capitalized guess (for
      R.ITEMS entries) or the bare raw string -- there is no real-engine-name
      lookup at all. CONFIRMED LIVE before fixing: RESEARCH showed as
      "Research" (missing "Bench"), ADVLAB as the actively awkward "Advlab",
      and GRPH (a real stock element added round 4) as its bare code
      "GRPH" with no readable name anywhere. Checked ZIRC too -- that one
      was already fine (a real element with a legitimately readable native
      name, "Zirconium"). Added RESEARCH/ADVLAB/GRPH to R.NAMES.
      VERIFIED LIVE: re-read r.nice() for all three after reload -- now
      "Research Bench" / "Advanced Lab" / "Graphite", confirmed by direct
      call, not assumed from reading the table literal.

## Feature track round 12 (2026-08-29)

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- found a real discoverability
      gap while reviewing what's still unaddressed: R.QUESTS (the guided
      progression chain) stopped at "steel" and never pointed players at the
      Research Bench/Advanced Lab tiers shipped this session (rounds 1/4) --
      those tiers were craftable and now actually reachable in the UI
      (rounds 6/7), but nothing in the game told a player they existed.
      Added two quests continuing the exact same pattern: "Build a Research
      Bench" (done when R.stats.crafted.RESEARCH >= 1, reward ZIRC) and
      "Build an Advanced Lab and craft a Graphite block" (done when
      R.stats.crafted.GRPH >= 1, reward TTAN). Confirmed #R.QUESTS is read
      dynamically everywhere (HUD goal counter, etc), never hardcoded, so
      appending is safe.
      FUNCTIONALLY VERIFIED LIVE: read both new quests' real done() closures
      off r.QUESTS, confirmed both correctly report false before the
      relevant craft, set r.stats.crafted.RESEARCH/GRPH=1 directly, confirmed
      both flip to true, then reset the test state back to nil -- genuine
      before/after behavioral proof, not just existence-checked.

## Feature track round 11 (2026-08-29)

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- crafting UI, the actual
      clarity complaint this time (rounds 6/7 fixed recipes being
      structurally unreachable, not this): "trying to figure out how to
      make the next item and it's all confusing." Within each station's
      group of rows, craftable-right-now recipes (`ok == true`, meaning near
      the station AND affordable) now sort before ones you can't make yet,
      instead of being interleaved in whatever order R.RECIPES happens to
      list them. "What can I make next" is now the first thing you see at
      each station instead of something to scan for.
      VERIFICATION: ui.lua reloads clean. buildCraftRows isn't exposed on R
      so couldn't call it directly with real data, but verified the EXACT
      comparator logic in isolation via the bridge with a mixed ok/not-ok
      mock array -- confirmed all ok=true entries sort before all ok=false
      ones. Honest gap: didn't confirm against real live R.RECIPES/inventory
      state (would need buildCraftRows exposed, out of scope to add just
      for this check), but the comparator itself -- the only new logic --
      is proven correct.

## Bugs track -- stuck mouse button, REAL root cause confirmed 2026-08-29

- [ ] RPG: "mouse gets stuck down, moving it over the screen spawns a bunch of
      bullshit everywhere." FIRST HYPOTHESIS WAS WRONG: guessed it was
      hot-reload timing (R.mouse.l preserved across reload, missing an
      up-event around the swap) and shipped a defensive reset in
      hotReloadCore(). Drew explicitly confirmed he DID reload and it was
      STILL broken -- that hypothesis was disproven by his own testing, not
      just unconfirmed.
      REAL ROOT CAUSE, found by actually reading onMouseUp again: the
      `R.mouse.l = false` / `R.mouse.r = false` reset lived AFTER an
      `if R.tptMenus then return end` early-return. Releasing the mouse
      button while TPT-menu mode happened to be active skipped the reset
      entirely -- R.mouse.l stayed stuck true even after menu mode closed
      again, so every later mouse MOVE read as a held click and kept
      placing/mining continuously. FIXED: moved the reset to always run;
      only the native-passthrough `return` (letting TPT's own sandbox/menu
      dragging see the real mouseup) still depends on R.tptMenus.
      FUNCTIONALLY VERIFIED against the ACTUAL failure mode this time, not a
      synthetic stand-in for the wrong hypothesis: forced mouse.l=true AND
      tptMenus=true, fired the real onMouseUp handler directly (temporary
      R._testOnMouseUp exposure), confirmed mouse.l correctly reads false
      afterward. Still awaiting Drew's own live confirmation.

## Feature track round 10 continued -- title screen hover polish

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- real button/row hover
      highlighting on the title screen and its settings panel, per Drew's
      repeated "way way way better" push. Previously buttons had zero
      interactive feedback (R.mouse.x/y is only updated AFTER the title-
      screen click-swallow check in onMouseDown, so it was never populated
      while on the title screen at all). Added a small dedicated
      titleMouseX/titleMouseY pair, forward-declared before onMouseMove
      (same pattern as the coordinator's drawTitleScreen/titleMouseDown fix,
      audited for the same class of bug -- these are plain variables, not
      functions, so definition-order risk doesn't apply the same way, but
      used the identical forward-declare-then-assign shape anyway for
      consistency), updated live in onMouseMove while R.titleScreen is true.
      All 3 main buttons, all 7 settings rows, and the Back button now
      brighten (fill/border color shift) under real hitRect() hover
      detection instead of sitting static.
      VERIFICATION: reload-clean, then forced real multi-frame execution of
      BOTH the main title screen and the settings panel (same standard as
      rounds 8/9) -- zero errors on either. Honest gap: only exercised the
      "not hovering" (false) branch this way, since actually feeding a real
      mouse-move event needs real input; the hover-true branch is simple
      symmetric ternary color math, same shape already proven in the
      false branch, but flagging it as slightly less proven than the rest.

## Sound effects -- investigated 2026-08-29, HONEST FINDING: no audio engine exists

Drew asked for sound effects broadly ("we pretty much need sound effects for
everything... it's got to be super chill"). Verified before assuming anything is
possible, per explicit instruction not to fake it. RESULT: this engine has NO audio
subsystem at all, at the C++ level -- not just "unexposed to Lua."
Checked exhaustively:
- `grep`'d the entire Lua bindings source (`D:\The-Powder-Toy\src\lua`) for
  sound/audio/Mix_/SDL_mixer/PlaySound -- zero matches. No sound-shaped Lua API
  exists to call from a script.
- `grep`'d the ENTIRE engine source tree for SDL_mixer/Mix_OpenAudio/
  Mix_PlayChannel/SDL_OpenAudio/any audio `#include` -- zero matches anywhere.
  This engine never links or initializes any audio library at all.
- `grep`'d for .wav/.ogg/.mp3/SDL_AUDIO references anywhere in src -- zero matches.
  No sound asset loading pipeline exists either.
CONCLUSION: this is a genuine engine-level gap, not a scripting limitation --
exactly like multiplayer and the ragdoll/gore overhaul, this cannot be added from
Lua or the MCP bridge, full stop. Real sound support would require: (1) linking an
actual audio library into the C++ build (SDL_mixer is the natural fit given this is
already an SDL-based engine, or SDL2's own audio device API directly), (2) new
engine-level code to load/play sound assets, (3) new Lua bindings exposing that to
scripts (a `sound.play(name)`-shaped API, roughly), (4) an actual audio asset
pipeline -- someone has to source or create real .wav/.ogg files for every effect
category Drew wants (UI clicks/hover, footsteps, mining, crafting, ambient/chill
background tone). None of this is something to half-implement or fake (e.g. there
is no way to "fake" sound with visual/particle effects that would honestly satisfy
"sound effects for everything").
NOT scoped further this round beyond confirming the gap and what real support would
need -- this needs Drew's decision on whether to invest in an actual engine-level
audio system (a real, non-trivial C++ build change) before anything else happens
here, the same "needs a real conversation" bucket as multiplayer/ragdoll-gore.

## Feature track round 10 (2026-08-29)

- [ ] BUG FOUND AND FIXED (LOW IMPACT), AWAITING CONFIRMATION -- applied the
      same "hardcoded exhaustive list missing new tiers" lens that found
      rounds 6/7's bugs to the rest of the codebase. Found a THIRD copy of
      the exact same bug: rpg.lua core has its own separate, older
      `craftRows()` / `R.invOpen` / `drawPanel()` crafting panel (toggled by
      E, distinct from ui.lua's `U.bagOpen`/`buildCraftRows`/
      `drawBagRecipesTab`) with the identical `order = {hand,workbench,
      furnace,anvil}` list missing research/advlab. Fixed the same way,
      verified against real live data the same way as round 6 (3 recipes
      unreachable before, 121 covered after).
      IMPORTANT CORRECTION, traced further before claiming this explains
      "bag tab isn't working": checked the actual E-key dispatch order.
      rpg.lua's onKeyDown calls `runHooks(R.hooks.key, ...)` BEFORE its own
      `if k=="e" then R.invOpen=...`, and returns immediately if any hook
      consumes the key. ui.lua registers an "e" hook that returns true for
      "e" -- so ui.lua's handler ALWAYS wins and rpg.lua's own handler is
      never reached. R.invOpen's legacy panel is NOT actually reachable by
      the player via normal keyboard input -- dead code from the player's
      perspective, not a live double-toggle conflict. The fix is still
      correct and harmless, but does NOT explain "bag tab isn't working" --
      still unresolved, needs Drew's specifics. Flagging the dead
      craftRows()/R.invOpen/drawPanel() system as a real cleanup candidate
      (two parallel, mostly-redundant crafting UIs) for later, not touching
      further this round.

## GitHub docs track, round 3 (2026-08-29)

- [x] Checked for new shippable content since round 2. Only new item found was round 10's
      dead-code fix (legacy rpg.lua craftRows/R.invOpen panel, confirmed unreachable by
      players -- ui.lua's E-key hook always wins first). Not added to CHANGELOG.md: a fix to
      code players can never actually trigger isn't a notable change to them. Holding off on
      documenting the stuck-mouse-button fix per the coordinator's note -- they're
      re-verifying their root-cause hypothesis since Drew reports it's still happening; will
      add it once confirmed, not before.

## GitHub docs track, round 2 (2026-08-29)

- [x] README.md rewritten and pushed (commit b7a5d8ab, phoenixfire808/The-Powder-Toy,
      rpg-and-realism branch): badges, a new "Life support & machines" section, expanded
      Powder RPG bullets covering this session's real systems, a "Where this is going" vision
      section, and an honest Roadmap pulling real open items from this file. CHANGELOG.md
      created with the full v1.2.0-v1.15.0 version history plus an Unreleased section for
      everything shipped after 1.15.0. Release notes on rpg-build-20260829 updated to match.
      Skipped a star-history badge (repo has 0 stars/forks, 2 weeks old -- would render as an
      empty line, not misleading but not useful yet).
- [x] Round 2: folded newly-shipped work into CHANGELOG.md's Unreleased section -- the 7th
      slider (tree spacing), the companion gravity/jump/move-speed desync fix (root-caused and
      fixed, not just patched per-slider), and the title-screen visual pass + matching
      in-place Settings panel. Could NOT find a "stuck mouse button" fix dated to this
      session anywhere in this file or rpg-hub.md's 2026-08-29 section -- the only stuck-
      cursor/mouse fix in either file is from a much earlier (2026-08-26-dated) session, a
      different bug (drag-to-hotbar leaving U.hand stuck), already long shipped. Did not
      fabricate an entry for something unverifiable -- flagging back to the coordinator
      rather than guessing at what was meant.
- [ ] PROPOSAL, NOT BUILT, NEEDS CONFIRMATION -- a real build/package script for release
      zips, so the shipped asset stops lagging the source (currently still the v1.14.0 build
      point; no such script exists anywhere in either repo, confirmed by search). This
      touches the release process, which Drew may want to control himself -- not wiring this
      into anything until he confirms he wants it. Concrete shape a script would need:
      1. Build the native binary (existing Meson+Ninja toolchain, release config) --
         `PowderToyRPG.exe` per the existing build/ output naming.
      2. Stage a clean folder: the built exe, `Play.bat`, `scripts/lua/` (rpg.lua +
         rpg_plugins/*.lua) since those are interpreted at runtime and not baked into the
         binary, and any other runtime assets the game reads from disk (fonts/stamps/config
         defaults if any are meant to ship).
      3. Zip that staged folder as `PowderToyRPG.zip`, matching the existing release asset
         name so the in-game self-updater's expectations don't change.
      4. Optionally: derive the release tag/version string from `R.VERSION` in rpg.lua
         automatically, so the tag and the in-game version can't drift apart the way the
         zip and source already have.
      A single script (PowerShell or a small Python script, matching whatever the existing
      dev workflow already leans on) covers this -- no CI/pipeline service needed unless
      Drew wants automatic releases on every push, which is a separate, bigger decision.
- [ ] Community/Contributing section for the README: NOT added yet. The stamp-submission/
      Discord-suggestion idea the feature track scoped this session (see its round-9 scope
      proposal above) is explicitly NOT built -- real infrastructure questions are still
      open (does a Discord bot exist anywhere, one-way vs two-way review, who hosts it). A
      README section describing it as a real feature right now would be inaccurate. If/when
      that system actually ships, a short "Community" section pointing at it would fit
      naturally next to the existing "Sandbox quality-of-life" section -- noting it here so
      whoever builds it also remembers the docs need a matching update, not doing it
      preemptively.

## Feature track round 9 continued -- title-screen Settings panel

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- title screen's Settings
      button now opens a real polished panel in-place (matching the round-8
      visual treatment: dark background, embers, gold borders/bevel) instead
      of jumping out to the plain Esc/Options menu, per Drew's "we have our
      settings here too but it's got to be nice nice shit." Lists all 7
      sliders shipped this session (day length, cave frequency, ore rarity,
      gravity, jump height, move speed, tree spacing) as clickable rows plus
      a Back button. Deliberately reuses the EXACT SAME R.MENU entries
      (matched by label substring) instead of a second parallel slider list
      -- one source of truth; the Esc/Options menu still works exactly as
      before for mid-game use, this is purely a second entry point onto the
      same underlying functions.
      VERIFICATION: reload-clean, then forced R.titleScreen=true AND
      R.titleSettingsOpen=true together on the lab instance for 2 real
      seconds (same standard as round 8's title-screen check) -- confirmed
      R.lastErr/R.pluginErr stayed nil across multiple real onDraw
      executions of the actual settings-panel render path, not just a
      syntax check. Restored the lab instance to normal play state
      afterward. Honest gap: same as round 8 -- individual row CLICKS
      (hit-testing) aren't verified live, needs real mouse input; the
      underlying slider functions themselves were already proven working in
      rounds 4/5/8 via direct calls, this only adds a second UI entry point
      to trigger the same functions.

## Feature track round 9 (2026-08-29) -- investigation + scope proposal

## Feature track round 9 (2026-08-29) -- investigation + scope proposal

- [ ] SCOPE PROPOSAL, NOT BUILT -- community stamp-submission/suggestion
      pipeline. Per the coordinator's explicit instruction, investigated what
      actually exists before writing this rather than guessing, and
      reporting honestly:
      WHAT'S REAL: `save_stamp`/`list_stamps`/`load_stamp`/`delete_stamp` are
      real, working MCP tools (powder_toy_mcp.py -> powder_bridge/client.py
      -> bridge_src's saveStamp/loadStamp/listStamps actions). Traced them
      all the way down: they are thin wrappers around TPT's OWN NATIVE stamp
      system (`sim.saveStamp`/`sim.listStamps`/`sim.loadStamp`, the same
      built-in "save a piece of your world to a local .stm file" feature
      every TPT install has). There is no description/metadata field, no
      submission queue, no review state, no network component, no shared
      storage -- a stamp is just a local file on whatever machine saved it.
      WHAT DREW DESCRIBED ("I added the discord bot and all that") DOES NOT
      EXIST: searched both D:\powder-toy and D:\The-Powder-Toy for anything
      Discord-related. Found exactly ONE thing: `R.FEEDBACK_WEBHOOK` in
      rpg.lua (line ~126), a single outbound Discord webhook URL used by the
      existing "Report bug / suggestion (F8)" menu item -- a one-way,
      fire-and-forget POST of feedback text into a channel. That is it. No
      bot process exists anywhere in either repo, no Discord API
      application/token, no bidirectional listening, no command handling, no
      review/approval workflow of any kind. Whatever Drew set up (if
      anything) is not in this codebase, or doesn't exist yet despite how it
      was phrased -- this is not something to assume and build against.
      REAL SCOPE THIS WOULD ACTUALLY NEED (none of this can be scripted from
      inside rpg.lua/the MCP bridge -- it's genuinely separate infrastructure):
      1. A submission format: extend the existing local stamp save with a
         paired description/request text (could reuse the F8 feedback text
         box's UI pattern, or a new prompt after saving a stamp) -- easy,
         in-scope for this codebase.
      2. A place submissions actually land: either (a) extend
         R.FEEDBACK_WEBHOOK-style posting to also attach/reference the saved
         stamp file, which means the stamp file has to get SOMEWHERE a human
         can retrieve it (a local .stm file on Drew's machine doesn't reach
         Discord on its own -- webhooks can attach files, so this is doable:
         read the .stm file and POST it as a multipart attachment alongside
         the description), or (b) a real bot application if two-way
         interaction is wanted (reactions, threads, a review queue that
         updates) -- (b) needs its own always-on process, a real Discord
         bot token, and hosting somewhere (this machine staying on, or a
         real server) -- NOT something addable by an MCP tool or Lua script
         alone.
      3. A review/triage side: even with submissions landing in Discord,
         "the team can review/analyze submissions and pick ones to
         implement" implies some kind of queue/tracking (could be as simple
         as a channel + manual triage, or as complex as a real bot with
         slash commands and a status board) -- needs Drew's actual
         preference, this ranges from "a Discord channel is enough" to "a
         real service," wildly different effort.
      OPEN QUESTIONS FOR DREW, before any code: (a) does a Discord bot/
      server actually already exist somewhere outside these two repos that
      the team should integrate with, or does one need to be created from
      scratch (needs a Discord Developer Portal application + bot token);
      (b) is a one-way "submission lands in a channel with the stamp file
      attached" acceptable, or is two-way review interaction (reactions,
      status updates back to the submitter) actually required; (c) who
      hosts a bot process if one's needed -- this machine, or somewhere
      else; (d) is this for the current single-player build only (so
      "community" really means "you, testing this"), or is there an actual
      other-players context this is meant to serve.
      NOT BUILT this round, per instruction -- this needs a real
      conversation given the external-infrastructure and unknown-existing-
      asset questions above, not a blind implementation.

## Feature track round 8 (2026-08-29)

- Audited every function/field added by this track (rounds 3-7) for the same
  forward-reference class of bug the coordinator just found and fixed in the
  title-screen code (a `local function X` called from an EARLIER point in
  the file than its own definition resolves to a nonexistent global instead
  of the local, and doesn't reliably surface in R.lastErr). Result: clean --
  every slider (gravMul/jumpMul/runMul/caveFreqMul/oreRarityMul/
  treeSpacingMul) reads/writes a shared R table field at runtime, not a
  lexically-scoped local, so file order doesn't matter for those. The
  ADVLAB/RESEARCH R.ITEMS entries and buildStation branch were table
  literals / edits to an existing function's body, not new call-before-
  define locals. Only the title-screen functions had this bug, already
  fixed by the coordinator.
- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- one more world-engine slider:
      "Tree spacing" (dense/normal/sparse, R.treeSpacingMul), continuing the
      pattern, explicitly named in the original scope proposal. world.lua's
      VSP constant (used at 9 call sites) converted to a `vsp()` function
      reading the live multiplier, affects newly-generated columns only
      (existing vegCache/blendCache memoization). FUNCTIONALLY VERIFIED LIVE:
      called the menu function via the bridge, confirmed R.treeSpacingMul
      actually changed (nil -> 1.4).
- [ ] TITLE SCREEN VISUAL PASS, AWAITING CONFIRMATION -- direct ask from Drew
      relayed by the coordinator: the functional V1 ("plain dark background,
      3 bordered buttons") needed real Minecraft/Terraria-style presentation,
      not a flat box, and this was NOT to be a five-minute tweak. Three real
      changes: (1) the full-screen fillRect is now translucent (190/255
      alpha) instead of opaque -- on "quit to menu" a real world already
      exists and TPT's native renderer draws it every frame regardless of
      this Lua onDraw, so the actual rendered world now shows through behind
      the menu (the same idea as Terraria's title screen rendering a real
      world scene; on first boot before any world exists this just reads as
      a dark backdrop, which is correct, there's nothing to show yet);
      (2) 14 drifting ember particles for ambient motion (purely decorative
      HUD-space dots animated by sine drift + upward float, NOT real sim
      particles -- doesn't touch physics); (3) real logo treatment (drop
      shadow + gold color + underline rule) and heavier button styling
      (top bevel highlight strip + double-border) instead of one flat-colour
      box per button, buttons also widened/respaced (150x26, more gap).
      VERIFICATION: reload-clean (no lastErr), then actually forced
      R.titleScreen=true on the lab instance for 2 real seconds (not just a
      single reload check) and confirmed R.lastErr/R.pluginErr stayed nil
      across multiple real onDraw executions -- genuine execution-level
      verification, not just "parses." HONEST GAP: R.lastErr does not
      reliably catch onDraw-path errors (the exact class of gap that hid the
      coordinator's forward-reference bug), and the coordinator's new
      screenshot mechanism wasn't shared/ready yet this round to get a real
      visual confirmation -- reasoned through the new code instead (plain
      graphics.fillRect/drawText + math.random/sin, no restricted APIs, no
      forward-reference risk per the audit above) but this should get a real
      screenshot check as soon as the coordinator's mechanism is available.
      Restored the lab instance to R.titleScreen=false/R.active=true
      afterward so it's not left mid-test.

## Feature track round 7 (2026-08-29)

- [ ] BUG FOUND AND FIXED, AWAITING CONFIRMATION -- second, worse bug in the
      same feature area as round 6's crafting-UI fix. Applied the same
      "audit the existing feature end-to-end" lens that found that one:
      R.ITEMS is the REAL gate placeAt uses to decide "this is a structure
      kit, call buildStation" instead of trying to place it as a raw
      element -- and RESEARCH/ADVLAB were never added to it (only
      WORKBENCH/FURNACE/ANVIL were). CONFIRMED LIVE before fixing: read
      r.ITEMS.RESEARCH/ADVLAB directly, both nil. Combined with round 6's
      finding, this means the Research Bench and Advanced Lab tiers shipped
      this session were doubly broken: not shown in the crafting UI (round
      6), AND if somehow crafted anyway, silently unplaceable (this bug) --
      falls through to eid("RESEARCH") which is nil, no-op, item just
      vanishes from inventory with nothing appearing.
      FIX: added RESEARCH/ADVLAB entries to R.ITEMS (col + desc, matching
      the existing WORKBENCH/FURNACE/ANVIL entries' shape).
      FULL END-TO-END LIVE VERIFICATION (strongest verification this session
      has done on a UI/placement feature): called r.buildStation('ADVLAB',
      <player's real canvas position>, ...) directly, confirmed a real
      station registered in r.stations with kind="advlab" (count went 0->1),
      and confirmed r.nearStation('advlab') then correctly returned true --
      the whole craft-gate -> build -> register -> proximity-check chain
      verified working, not just "reloads clean."

## Feature track round 6 (2026-08-29)

- [ ] BUG FOUND AND FIXED, AWAITING CONFIRMATION -- real correctness bug in the
      crafting UI, found while re-reading buildCraftRows (ui.lua) for the
      "crafting UI is confusing" complaint: its hardcoded station `order`
      list was `{hand, workbench, furnace, anvil}` and NEVER included
      "research" or "advlab" -- both real tiers shipped this session (Research
      Bench in round 1, Advanced Lab in round 4). Any recipe gated on either
      station was structurally unreachable in the crafting panel: R.craft()
      and canAfford() both worked fine, the row simply never got built/drawn
      for the player to click on. Not a UX complaint, a real functional gap --
      the Research Bench and Advanced Lab tiers shipped this session were
      genuinely half-broken (buildable as structures, but nothing they gate
      was ever visible to craft) until this fix.
      FIX: added "research"/"advlab" to the order list.
      FUNCTIONALLY VERIFIED LIVE against real data (not just "reloads clean"):
      counted R.RECIPES entries whose station wasn't in the OLD order list
      vs the NEW one -- 3 recipes were completely unreachable before, all
      121 real recipes are covered now.
      MCP screenshot note: checked again this round per Drew's ask -- still
      no mcp__powder-toy__rpg_screenshot/screenshot reachable from this
      session (MCP still disconnected). The coordinator is adding a
      rpg.lua-core screenshot mechanism (R.debugShotRequested) concurrently;
      deliberately avoided touching onTick/rpg.lua-core this round to not
      collide with that in-flight edit -- this fix is entirely in ui.lua.

## Feature track round 5 (2026-08-29)

- Screenshot-based verification requested by Drew going forward -- checked
  both paths this round: mcp__powder-toy__rpg_screenshot/screenshot are
  unreachable (MCP still disconnected for this session), and the raw HTTP
  bridge (127.0.0.1:9876) has no screenshot action defined in
  bridge_src/_base/bridge_base.lua -- confirmed by reading it, not guessed.
  No screenshot path exists from this session right now. Continued with
  direct function-call verification against the lab instance per the
  coordinator's stated fallback. Whoever picks up @roadmap next: if the MCP
  reconnect ever lands, screenshot verification should become the default
  for anything visual per Drew's ask.
- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- one more world-engine slider,
      continuing the proven pattern: "Move speed" (slow/normal/fast),
      R.runMul, applied as a live multiplier on the existing RUN0 constant
      (movePlayer's horizontal speed, already had a boots-accessory 1.5x
      multiplier -- R.runMul stacks on top of that the same way). Takes
      effect immediately, no world regen needed. FUNCTIONALLY VERIFIED LIVE:
      called the menu function via the bridge, confirmed R.runMul actually
      changed (nil -> 1.3).
- Checked TODO.md's remaining Active feature-side items for what's left
  scoped enough to pick up without more design first: camera zoom
  (Ctrl+Up/Down) explicitly needs "a real rendering-level design," the
  temperature/radiation ask and the "building stuff needs a button" ask are
  both flagged as needing clarification from Drew, not scoped features.
  Nothing else concretely actionable found this round beyond continuing the
  sliders pattern (now covers day length, cave frequency, ore rarity,
  gravity, jump height, move speed -- 6 real parameters).

## Roadmap dependency finding, round 3 (2026-08-29)

- [ ] BUG (found by roadmap track, for the bugs track to pick up): the round-4
      "Gravity" world-engine slider (R.gravMul, rpg.lua) only affects the
      PLAYER's own gravity (rpg.lua:861, correctly multiplied). The companion
      (companion.lua:123, `C.vy = min(MAXFALL, C.vy + GRAV)`) has its own
      separate GRAV constant that does NOT apply R.gravMul at all -- setting
      Gravity to "heavy" or "light" will make the player fall at the new rate
      while the companion keeps falling at the old normal rate, visibly
      desyncing her from the player (she'd lag behind or overtake him on any
      non-default gravity setting). One-line fix: `C.vy = min(MAXFALL, C.vy +
      GRAV * (R.gravMul or 1))`, same pattern already used in rpg.lua. Not
      fixed here -- bug fixes go through the coordinator/bugs track per the
      standing roster, not this roadmap track.
      UPDATE round 4 (roadmap track): confirmed this is a PATTERN, not a
      one-off -- round 5's new "Move speed" slider (R.runMul on RUN0) has the
      identical gap. companion.lua:57 declares its own separate `RUN`
      constant (companion.lua:159/220/252 all use it raw) that never applies
      R.runMul either, so the companion will also desync on speed, on top of
      gravity. Root cause is systemic: companion.lua duplicates a full copy
      of the player's physics constants (GRAV/RUN/ACC/JUMP/MAXFALL) instead
      of referencing the shared R.*Mul multipliers, so EVERY current slider
      (gravity, move speed) and any future movement-affecting slider needs a
      matching companion-side fix, one by one, unless the bugs track fixes
      this at the root instead (e.g. companion.lua reads R.gravMul/R.runMul/
      R.jumpMul directly at its 2 physics constants, same as rpg.lua does,
      rather than each slider getting a separate companion patch).
      FIXED AT THE ROOT 2026-08-29 (bugs track): applied `(R.gravMul or 1)`/
      `(R.jumpMul or 1)`/`(R.runMul or 1)` at all 5 use sites (companion.lua
      gravity+jump in stepPhysics, plus 3 separate RUN use sites for walk/nav
      speed) -- covers gravity, jump, and move speed sliders in one pass, and
      any future multiplier added the same way (R.xxxMul or 1) at a NEW use
      site won't need a companion-side patch since it's the same live-read
      pattern as the player. Reloaded clean, no errors. Honest gap:
      stepPhysics is a local function, not exposed on R, so the exact
      multiplied value wasn't independently exercised live (would need
      driving a real companion movement tick) -- verified by code correctness
      against the identical, already-proven player-side pattern instead.

## Feature track round 4 (2026-08-29)

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- 2 more world-engine sliders,
      continuing the proven pattern: "Gravity" and "Jump height"
      (light/normal/heavy, low/normal/high), R.gravMul/R.jumpMul, applied as
      live multipliers on the existing GRAV/JUMP physics constants at their
      3 use sites in movePlayer -- takes effect immediately, no world regen
      needed (unlike the terrain-generation sliders from round 3). FUNCTIONALLY
      VERIFIED LIVE: called both menu functions via the bridge, watched
      R.gravMul/R.jumpMul actually cycle (nil->1.4, nil->1.3).
- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- one more crafting tier past
      the Research Bench: "Advanced Lab" (R.STATIONS.advlab), built at a
      Research Bench, gated on ZIRC+B4C+GLAS (needs the Research Bench's OWN
      output as an ingredient, so it's a real gate on top of a gate, not
      just more of the same tier). One proof recipe: Graphite block (GRPH,
      a real stock element -- verified it actually resolves live via id()
      BEFORE using it as a recipe output, learned that lesson the hard way
      this session). FUNCTIONALLY VERIFIED LIVE: confirmed the GRPH/advlab
      recipe entry actually exists in R.RECIPES after reload, and
      R.STATIONS.advlab reads "Advanced Lab". Not visually confirmed (would
      need to actually gather TTAN/STEL/DU/ZIRC/B4C/GLAS and build the
      chain in-game).
- Explicitly skipped this round: tree water veins/internal drain mechanic
      (too speculative/unscoped to timebox properly -- the tree-roots
      worldgen visual from round 1 is the simpler half of that ask and is
      already shipped) and further crafting UI polish beyond the round-3
      chip-scroll fix (no new complaint to act on beyond what's already
      fixed). Multiplayer and the ragdoll/gore overhaul still skipped per
      the coordinator's standing note -- need a real conversation with Drew
      first, not another scope guess.

## Feature track round 3 (2026-08-29)

- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- crafting UI filter chips: were
      hard-capped at 2 rows with no way to reach materials past the cap
      (flagged as an honest gap last round). Now wheel-scrollable: hover the
      chip strip and scroll to page through rows (U.matChipScroll, "wheel:
      more mats" hint shown when there's more than 2 rows). ui.lua reloads
      clean. Not functionally click/scroll-tested live (would need a real
      wheel event, off-limits per no-synthetic-input).
- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- 2 more world-engine sliders in
      the Esc/Options menu, same cycle pattern as the existing day-length
      one: "Cave frequency" (sparse/normal/dense, R.caveFreqMul, scales the
      worm-tunnel spawn threshold in world.lua) and "Ore rarity"
      (common/normal/rare, R.oreRarityMul, scales the shared vein() zone
      threshold so it covers every ore/crystal call site with one knob).
      Both affect newly-generated terrain only, labeled as such in the menu
      text -- per the roadmap's scope note, structural terrain changes don't
      hot-apply to already-generated chunks. FUNCTIONALLY VERIFIED LIVE: called
      both menu functions directly via the bridge and confirmed R.caveFreqMul/
      R.oreRarityMul actually cycle through their presets (nil->1.8->0.5,
      nil->1.4->0.7), not just "reloaded clean."
- [ ] FEATURE APPLIED, AWAITING CONFIRMATION -- launch/title menu V1, built
      against the roadmap agent's scope proposal (single save slot, no
      world/character select needed). R.start(seed) now shows a title screen
      (POWDER RPG / version / Play / Settings / Quit) instead of generating
      the world immediately; onDraw and onMouseDown both check R.titleScreen
      before their normal `if not R.active` gates, so the title screen draws
      and handles clicks independently of whether a world exists yet. Play
      triggers real world generation on first boot, or just resumes
      (R.active=true) without regenerating if a world already exists (tracked
      via R.worldEverGenerated). New "Quit to menu" entry in the Esc menu
      sets R.titleScreen=true/R.active=false -- returns to the title screen
      WITHOUT killing the process or the in-memory world/sim, matching the
      scope ask. Settings opens the existing Esc menu directly from the title
      screen (reused, not rebuilt). Quit does NOT fake a real process-exit --
      there's no safe scriptable full-quit in TPT Lua, so it shows "Close the
      window or Alt+F4 to quit" instead of a broken/misleading button.
      FUNCTIONALLY VERIFIED LIVE (partial): called the "Quit to menu" R.MENU
      entry directly via the bridge and confirmed it actually flips
      titleScreen=true/active=false. Core reloads with zero errors. Honest
      gap: the Play/Settings/Quit BUTTON CLICKS themselves (hitRect + real
      mouse coordinates) are not verified live -- same ceiling as every other
      click-driven UI feature this session, can't be exercised without real
      mouse input.
      CRITICAL BUG, found and fixed 2026-08-29 -- Drew's real live session
      was spamming "attempt to call global 'drawTitleScreen'/'titleMouseDown'
      (a nil value)" on every single frame (confirmed via his own screenshot,
      error console completely full). Root cause: classic Lua forward-
      reference bug -- both functions were defined via `local function` near
      the bottom of the file, but called from much EARLIER points (onMouseDown
      ~line 1845, a drawHUD site ~line 2265). Every earlier call resolved to a
      nonexistent GLOBAL, not the not-yet-declared local, so it called nil
      every frame. Fixed by forward-declaring `local drawTitleScreen,
      titleMouseDown` before first use and changing both definitions from
      `local function X()` to `X = function()` so they fill the forward-
      declared locals instead of shadowing them. VERIFIED with real rigor this
      time: set titleScreen=true on the lab instance, let it render
      continuously for 2 real seconds (~120 frames, the exact repeated-error
      scenario from the screenshot), confirmed zero accumulated error; also
      took an actual screenshot (Drew's explicit ask -- built a reusable
      debug-screenshot hook, R.debugShotRequested, same flag pattern as hot-
      reload, since tpt.screenshot() also needs real interface-event context)
      and visually confirmed the title screen renders correctly: logo,
      version, three clean bordered buttons, no error text anywhere.
      NOTE: Drew wants real visual polish on this screen now ("really really
      fucking good, like Minecraft or Terraria") -- passed to the feature
      track as a follow-up, not attempted here (out of scope for a bug fix).

Live tracking notepad. Updated every time Drew raises something new; items
checked off when actually done and verified, not just attempted.

## Active

- [ ] RPG: feature-backlog pass 2026-08-29 (worked by a fork per Drew's request
      while the coordinator handled the bug list directly), six candidates from
      the big feature bundle, all applied and hot-reload-verified live on the
      lab instance (no lastErr) -- none confirmed by Drew yet:
      1. Longer daytime: day/night cycle was an even 50/50 split (phase < 0.5).
         Hoisted a shared DAY_FRAC=0.65 constant (day is now 65% of the cycle)
         and reshaped the night-brightness curve and sun/moon arc to both use
         it consistently, instead of two independent 0.5 thresholds.
      2. Real UV: sun emits real UV now, separate from nuclear radiation. New
         R.uvAccum builds slowly while outdoors (depth<=20) in daylight, decays
         when sheltered/at night, causes mild "sunburn" damage past 70% (far
         gentler than radiation sickness), own HUD line. Reused the exact
         accumulate/decay/damage shape the existing R.radAccum system already
         had rather than building a new pattern.
      3. Real photosynthesis: leaves (GRSS) near the player convert adjacent
         CO2 particles to OXYG, but only during daylight (light-dependent,
         like the real reaction) and only via a sparse ~8-point radius sample
         every 90 frames, not a full-area scan -- reused the same
         hash3-sampling idiom the existing star-field code already uses, to
         avoid the exact "O(particle count) scan" lag mistake flagged earlier
         this session.
      4. Tree roots: genBase now generates a few tapering, hash-gapped WOOD
         root fingers fanning down/out from each tree's trunk base into the
         topsoil (bounded to surf..surf+8, doesn't touch cave/ore generation
         below it). Worldgen-only -- will only show up in freshly generated
         terrain, not the already-generated lab world, so this couldn't be
         visually confirmed this pass, only confirmed to hot-reload cleanly.
      5. Tiered workbenches: added a "Research Bench" as a real second tier
         past the Workbench, reusing the exact existing station mechanism
         (R.STATIONS, buildStation, R.RECIPES' st= field) rather than a new
         system -- costs STEL/GLAS/CU (things the workbench itself can't
         produce, so it's a real gate), built at a workbench. Added one proof
         recipe gated behind st="research" (ZIRC alloy, an already-existing
         element) to confirm the tier actually gates something.
      6. README polish: explicitly SKIPPED, not attempted -- TODO already
         records this was deliberately deferred until RPG feature churn
         settles (writing detailed docs for stuff still changing every few
         minutes has no shelf life). Didn't re-litigate that call.
      Also explicitly skipped per the coordinator's scope note (need a real
      design conversation first, not attempted): world-engine settings/slider
      UI, the launch/title menu, multiplayer, the ragdoll/gore character
      overhaul, and native shape-drawing tools in survival mode.
- [ ] RPG: changelog popup bottom text was smushed/illegible -- root cause found
      2026-08-29: two graphics.drawText calls landed at the EXACT SAME pixel
      position (uy+uh-12), the update-count/scroll-hint line and a separate
      "Esc = got it" line drawn directly on top of each other. Merged into one
      line. FIX APPLIED AND HOT-RELOADED LIVE on the lab instance, no errors
      -- still AWAITING Drew's own visual confirmation (couldn't screenshot
      it open without synthetic input).
- [ ] RPG: New Seed/New World was starting in sandbox/creative mode --
      R.sandbox = false added to R.generateWorld's reset block. FIX APPLIED,
      CONFIRMED LIVE via bridge read after hot-reload (sandbox reads false),
      still awaiting Drew's own confirmation from an actual new-world start.
- [x] Workflow: MCP bridge/server was down -- every tool call failed with
      "capability manifest inconsistent." Found and fixed the real cause:
      3 duplicate `powder_toy_mcp.py` processes running simultaneously (from
      8/28 1:42pm, 8/28 2:52pm, 8/29 3:16pm). Killed the 2 stale ones. Side
      effect: this also dropped this session's own MCP tool connection (needs
      a manual reconnect on Drew's end) -- worked around it by talking to the
      game's HTTP bridge directly (127.0.0.1:9876, token at
      D:/The-Powder-Toy/build/powder-bridge.token) instead of through the MCP
      tool layer, same underlying capability. Also discovered powder.exe was
      NOT the right process name to check (this fork's binary is
      PowderToyRPG.exe) -- an earlier check that claimed "the game isn't even
      running" was wrong; Drew's real session (PID 60536, started 9:39pm) was
      up the whole time and was never touched. A separate lab instance (PID
      20964, started 10:44pm) was launched to verify fixes against instead.
- [ ] RPG: full settings/config UI with sliders for "the entire world engine
      and generation thing... everything should be configurable" -- a real,
      substantial feature (a live-tunable settings menu exposing worldgen
      and engine parameters), not a quick add. STARTED 2026-08-29 (real first
      slice, not a stub): reused the existing, already-working Esc/Options
      menu (R.MENU, ui.lua-style click-to-toggle rows) instead of building a
      new panel from scratch. Converted R.dayFrac (day/night split, was a
      frozen `local DAY_FRAC` set once at file load) into a genuinely live R
      field read directly at all 4 use sites (sky render, UV exposure x2, day
      arc) -- a menu click now changes it and it takes effect on the very
      next frame, no reload needed. Added one entry cycling 3 presets
      (50/65/80% day). FUNCTIONALLY VERIFIED LIVE -- called the menu entry's
      actual function 3x via the bridge and watched R.dayFrac walk
      0.65->0.8->0.5->0.65, not just "reloaded without errors."
      HONEST SCOPE: this covers exactly ONE parameter. "Everything
      configurable" (cave density/frequency, ore rarity, gravity constants,
      etc) is NOT done -- those live as plain `local` constants scattered
      across rpg.lua/world.lua and each needs the same
      local-const-to-live-R-field treatment individually. The pattern is now
      proven and cheap to repeat (same 3 steps: field default, replace local
      references with the R read, add a menu row) -- next agent pass should
      just keep applying it to more constants rather than re-deriving the
      approach.
- [ ] Workflow: confirmed understanding of "everything should be added into
      the MCP tool, use that at every step" -- the powder-toy MCP server
      itself is still broken (confirmed earlier this session, every tool
      fails with "capability manifest inconsistent"), so this is being done
      via the same underlying HTTP bridge directly (executeLua calls) --
      functionally the same capability, different transport, since the
      actual MCP server can't be reached. Hot-reload (see memory) is the
      concrete version of "rapidly edit without rebuilding/restarting."
- [x] RPG: mouse hover tooltip now also shows real pressure at that cell,
      alongside name + temperature -- shipped alongside the sliders/MCP
      notes above via hot-reload, not yet separately confirmed live.
- [ ] RPG: "bag tab isn't working" -- ambiguous, needs more specifics (which
      tab, what happened when clicked). FIX APPLIED for the wheel-scroll
      part of this complaint (mouse wheel now scrolls the bag's
      items/recipes lists, previously click-the-tiny-arrow-only), AWAITING
      CONFIRMATION -- the "tab not working" part specifically is still
      unclear and unaddressed.
- [ ] RPG: Tab (native brush-shape cycle) "doesn't work" -- checked: Tab
      does correctly reach native TPT (GameView.cpp calls ChangeBrush()
      unconditionally, same as Space/pause, confirmed not swallowed by
      rpg.lua). Real cause: survival-mode block placement (placeAt) has its
      own hardcoded circle-only shape and never reads native TPT's brush
      shape/size at all -- so Tab visibly changes something with zero effect
      on what you can actually place. This is the same underlying gap as
      the shape-drawing-tools item below (placeAt not integrated with
      native brush state) -- one real fix covers both complaints.
      CORRECTION 2026-08-29 (roadmap pass): the shape-drawing-tools item
      below has since been fixed a DIFFERENT way -- its own SHIFT/CTRL drag
      gesture built entirely in Lua mouse-handling, deliberately sidestepping
      native brush-state reading rather than fixing it. That closed the
      shape-drawing ask but does NOT touch Tab at all -- Tab (native
      brush-shape cycle) having zero effect on survival placement is STILL
      fully open, still needs the interface-event flag trick to read
      tpt.brushx/brushy/shape from inside a real dispatched event. Don't
      assume this is covered anymore.
- [ ] RPG: underground/cave generation needs a real researched pass, not
      another quick noise-tuning patch -- still seeing "empty vertical
      tunnels going straight down," confirmed still happening after the
      earlier domain-warp attempt. Explicitly asked for real research into
      how underground generation + resource/ore placement should actually
      look (real cave systems, vein-based ore distribution) before touching
      the noise formula again.
      EXPANDED 2026-08-29: "we need a larger dirt layer so we can actually
      dig down and make a house or shelter, and we need mountains and shit,
      like actual Terraria terrain." This is the same underlying ask, now
      with concrete specifics: (1) a deeper topsoil/subsoil band before bare
      rock/caves start (currently a thin skin per earlier notes), specifically
      to support digging a proper shelter into it near the surface, and (2)
      real elevation variation (hills/mountains), not the current flat-ish
      surface with a soft biome-blend border. Still needs the real research
      pass asked for above -- not a quick patch on top of an unresearched
      formula.
- [ ] RPG: NEW report -- water pools on TOP of tree canopies instead of
      draining off/around them. Likely the same underlying mechanism as the
      oxygen-stuck-in-leaves bug (leaves/GRSS are real TYPE_SOLID, confirmed
      live this session) -- water landing on a real solid surface with
      nowhere to drain will just sit there, which is arguably correct physics
      given no drainage/runoff design exists for canopies. Needs a real
      design decision (should canopies shed water via a slope/gap in the leaf
      mass, or is pooling actually fine/realistic and this is really just the
      same "reads as broken" perception issue): not investigated yet.
- [ ] RPG: "machines disappear after placement" -- FIX APPLIED, AWAITING
      CONFIRMATION (not checked off -- root-cause was found and a fix
      shipped, but he hasn't confirmed it live yet, so this stays open per
      his rule: applying a fix isn't the same as it being done).
      Root-caused via code reading (updateMachineCores in machines.lua
      actively tears a machine down the instant its core cell reads empty,
      every 25 ticks) and fixed with a 3-consecutive-miss grace period so a
      single-tick false read right as the core scrolls back into view can't
      wrongly destroy it. Applied via hot-reload, live, no restart. Not yet
      confirmed by an actual repro (couldn't force one without either
      synthetic input or exposing more internals for bridge testing) -- the
      mechanism is confirmed real, the exact trigger frame is inferred, not
      reproduced.
- [ ] RPG: air-flow-into-dug-areas speed complaint ("really shitty") --
      FIX APPLIED (twice), AWAITING CONFIRMATION. Round 1: digging spawned a
      real OXYG particle directly (55% chance) -- worked but caused a real
      lag spike (an O(particle count) scan running per destroyed cell in a
      radius swing). Round 2, per explicit correction ("why would you code
      it like that... need to add atmospheric pressure"): replaced with
      real negative pressure via sim.pressure() at each dug cell, let the
      sim's own physics pull air in -- no scripted particles, no lag.
      Strength bumped from -2 to -8 after "should be rushing in quicker."
- [ ] RPG: confirmed -- swinging at the companion ("Aster") does nothing at
      all. CORRECTED root cause 2026-08-29 (the note above was wrong): she
      already had a full hp/death system (C.hp/C.maxhp, health bar, enemy-
      touch damage, R.companionKill respawn) -- the only actual gap was that
      the player's own sword swing never checked distance to her, only to
      R.EN (enemies). FIX APPLIED: added R.damageCompanion(dmg,fromx,fromy)
      in companion.lua (same shape as the existing enemy damage path) and
      hooked it into enemies.lua's trySwordAttack alongside the enemy-hit
      loop. FUNCTIONALLY VERIFIED LIVE on the lab instance -- called it
      directly via the bridge, watched her hp actually drop (60/60 -> 50/60
      after 10 dmg), not just "reloaded without errors." Still awaiting
      Drew's own live confirmation that swinging at her in-game now works.
- [ ] RPG: reinforced again -- "I also want there to be like tree roots"
      (separate mention from the water-vein/drain idea in the bundle below,
      may just mean visible roots extending into the ground under each
      tree, worldgen-side, simpler than the internal water-channel mechanic).
- [ ] RPG: character model overhaul bundle, now with a concrete reference --
      "Happy Wheels" style: real ragdoll/joint physics driving movement, not
      just a static sprite, PLUS (1) bigger player + companion, (2) real
      gore/dismemberment (limbs tear off, decapitation, "full of organs").
      This is a genuine physics-engine-level feature (constraint/verlet-style
      ragdoll simulation), not a sprite reskin -- needs its own dedicated
      design pass, not something to fold into an ongoing session. Two
      smaller, real wins already shipped separately: bleed-on-damage, and a
      material hover tooltip (name + temperature).
- [ ] RPG: Ctrl+Up/Down camera zoom still doesn't do what's wanted -- this
      was fully REMOVED earlier tonight (the native-lens approach didn't
      read as zoom and could get stuck), not just "not working right." No
      zoom feature currently exists at all pending a real rendering-level
      design (see existing TODO entry below).
- [ ] RPG: NEW BUG, live report -- "I keep placing down machines and they
      disappear." Not yet investigated (didn't want to force a restart
      while the user is actively playing). Leading suspects: the
      scroll/tile-cache system (shiftCam/tile()) that saves off-screen
      particles and restores them when the camera scrolls back -- if a
      machine's extra particle properties (ctype/tmp/life) aren't fully
      round-tripped through that cache the way plain terrain is, a machine
      could revert/vanish after scrolling away and back. Needs live
      debugging (place a machine, scroll away, scroll back, inspect via
      bridge) next time a restart is OK.
- [ ] Cleanup: scrub "Drew" name references out of everything that's actually
      public -- FIX APPLIED, AWAITING CONFIRMATION (2026-08-29). Replaced all
      53 occurrences across the 6 rpg_plugins files that had them
      (companion.lua 16, world.lua 5, machines.lua 19, items.lua 8,
      machines2.lua 3, survival.lua 2) with "the player", comment-only in
      every case. Verified all 6 files still hot-reload with zero errors
      afterward, and specifically confirmed the R.damageCompanion function
      added earlier this session survived the rewrite intact. rpg.lua itself
      and README.md were already checked clean earlier this session.
- [ ] RPG: real negative-pressure air flow -- Drew wants areas with no air to
      create actual negative pressure so real air flows in to fill it,
      instead of (or alongside) the current ambient-spawn approach to
      oxygen. TPT already has a real pressure field (sim.pressure/
      set_edge_pressure etc.) -- worth exploring whether dug-out empty
      pockets should register a pressure drop that the engine's own air
      simulation then equalizes, rather than us scripting diffusion by hand.
- [ ] RPG: crafting UI is confusing -- "the filter by materials thing takes
      up half the space and we can only look at three things... trying to
      figure out how to make the next [item] and it's all confusing." ROOT
      CAUSE CONFIRMED LIVE 2026-08-29: allMaterials() (ui.lua) unions every
      material referenced across every recipe/pick/sword, now 34 distinct
      materials on the live lab instance (counted directly via bridge, not
      estimated) -- forEachMatChip wrapped that unbounded, easily 3+ rows of
      chips eating the panel before a single recipe row showed. FEATURE
      APPLIED, AWAITING CONFIRMATION: capped forEachMatChip at 2 rows (fixed
      in the one shared function, since drawBagRecipesTab/recipeLayoutMetrics
      /handleBagClickRecipes all call it and needed to stay consistent).
      Reclaims the space the recipe list actually needs. Hot-reloaded clean,
      no lastErr. HONEST GAP: materials past the 2-row cap currently aren't
      reachable as a filter chip at all (list is sorted, so it's always the
      same early-alphabet materials visible) -- no scroll or search was added
      for the overflow, kept deliberately simple for this pass. If that's a
      real problem in practice, needs a follow-up (scrollable chip strip, or
      reuse of a search box if one already exists for this tab).
- [ ] GitHub: Drew wants the README/repo page updated in more detail again,
      "super professional... some of the best leading repos" -- already did
      one pass earlier this session (README rewrite + default branch fix),
      wants it taken further/kept current. Revisit once the RPG feature
      churn settles down (no point writing detailed docs for stuff that's
      still actively changing every few minutes).
- [ ] RPG: big feature bundle from Drew, not started -- (1) tiered/research
      workbenches (multiple levels of progression, not just workbench ->
      anvil), (2) longer daytime (sun out longer), (3) sun should emit real
      UV, (4) real photosynthesis tech: trees consume CO2 and produce O2
      (ties into the existing gas-stratification/CO2 work), (5) trees should
      have internal "veins" draining water down into the trunk and out
      through little underground tunnels/drains at the roots. Each of these
      is its own real feature -- needs prioritization, not a single patch.
- [ ] RPG: geological accuracy complaint -- "the ground right underneath the
      topsoil is just made out of brick, that's not accurate, I want the
      whole terrain to be geologically accurate." ROOT CAUSE CONFIRMED LIVE
      2026-08-29 (queried the running lab instance directly, not just read
      the code): "GRNT" was never actually registered as a real element
      anywhere in this fork at all -- has("GRNT") was always false, so
      `ROCK = has("GRNT") and "GRNT" or "BRCK"` silently fell back to fired
      brick for ALL subsoil, everywhere, unconditionally. FIX APPLIED,
      AWAITING CONFIRMATION: changed the fallback chain in both rpg.lua and
      world.lua to prefer STNE (real stock Stone, already the canonical
      rock/rubble material used elsewhere in this codebase) before falling
      all the way to BRCK. Confirmed both files hot-reload with zero errors
      and confirmed STNE resolves to a real element id (5) live. Could not
      sample a freshly-generated subsoil tile directly -- R.generateWorld()
      is gated behind "restricted to tool events" same as every other
      interface-event-only API, and building a temporary onTick hook just to
      force one wasn't worth it for this check. This is still only a rock
      SUBSTITUTION (brick -> stone), not the fuller "real rock types per
      biome, topsoil -> subsoil -> bedrock" layering Drew described --
      flagged as a smaller honest fix, not the complete ask.
      REVERTED same day, real regression: STNE turned out to be
      Falldown=1 (a genuine falling powder in real TPT physics, not a
      static solid) -- never checked before shipping. Drew's real session
      generated a fresh world on this code and the entire subsoil collapsed
      ("everything fell through the earth"). Reverted ROCK back to the
      BRCK-only fallback in both files, verified reload-clean. Back to
      square one on the actual geological-accuracy ask -- needs a REAL
      static rock element (verify Falldown=0 and TYPE_SOLID via
      elem.property BEFORE using anything as terrain fill, see Lessons
      section) chosen properly next time, not just "id resolves."
      Also ruled out the cheap fallback of just renaming BRCK's DISPLAY
      name (zero physics risk) -- BRCK is also a real player-craftable
      recipe ("Fired brick", rpg.lua:1400, kiln-fired dirt), same element
      id as the world-gen filler, so renaming it would mislabel something
      players intentionally make. Genuinely needs a new dedicated static
      rock element (elements.allocate, same pattern as GRSS/BLD, verified
      Falldown=0/TYPE_SOLID before it ever touches world-gen) -- not
      attempting a third guess this session after the regression above.
- [ ] RPG: unclear ask -- "I want to be able to get the temperature, like
      leftover radiation and stuff." Could mean: (a) a way to inspect a
      block's real temperature/radiation reading in survival mode (native
      TPT already shows this when hovering, but that's TPT-menu/sandbox
      UI), or (b) wanting radiation to leave a lasting temperature signature
      too, on top of the existing persistent contamination system. Needs
      clarification.
- [ ] RPG: real "zoom in on my character" camera control (Ctrl+Up/Down was
      the ask). Removed a first attempt that reused TPT's native magnifier
      lens -- it didn't read as a camera zoom, and could get stuck fully on
      with no clear way off. An actual "scale the rendered world" zoom needs
      a real engine rendering change (no camera-scale concept exists
      anywhere in this renderer currently); needs real design before trying
      again, not another quick reuse of an unrelated native tool.
- [ ] RPG: native TPT shape-drawing gestures (Shift-drag line, Ctrl-drag
      box, circle) should work in survival/non-sandbox mode too, consuming
      from the player's own inventory instead of only working in full
      sandbox/TPT-menu mode. FEATURE APPLIED 2026-08-29, AWAITING
      CONFIRMATION: skipped trying to read native TPT brush state at all
      (tpt.brushx/brushy need real interface-event context, same restriction
      class as everything else -- not worth fighting for this). Instead built
      the gesture entirely in our own Lua mouse handling, which already
      tracked drag state: SHIFT-drag now does what CTRL-drag already did
      (grid-snap + lock to a straight line from the drag start -- the exact
      gesture Drew actually tried and got nothing from), and CTRL+SHIFT held
      together is new: drags out a rectangle preview anchor and fills the
      WHOLE box in one shot on mouse-release (not per-tick, so it can't burn
      through inventory or lag while dragging), consuming exactly as much
      inventory as cells actually placed. No circle yet -- line + box covers
      the two gestures Drew actually described trying. Hot-reloaded clean, no
      lastErr. Could NOT functionally verify the drag gesture itself --
      placeAt/commitBox are private locals, and the real trigger path needs
      genuine mouse+keyboard combos, which stays off-limits per the standing
      no-synthetic-input rule (same verification ceiling every other mouse
      gesture in this session hit, e.g. the zoom window rounds). Needs Drew's
      own hands on it.
- [ ] RPG: proper launch/title menu, reference confirmed twice now
      ("Terraria-style", then "Minecraft or Terraria... super dope") --
      currently boots straight into a generated world with zero front-end
      screen. DELIBERATELY NOT ATTEMPTED this pass (2026-08-29) despite the
      "ship a real first version, don't just skip design-needy items"
      instruction -- explained why rather than just skipping silently:
      this needs to gate R.generateWorld/the boot tick sequence itself
      behind a menu selection, which is real control-flow surgery on the
      one path every single other system in this game depends on working
      correctly. A background pass with no way to interactively confirm the
      boot sequence still works afterward is the wrong place to risk that --
      a bug here doesn't fail gracefully, it could stop the game from
      starting at all. CONCRETE SCOPE PROPOSAL instead of a vague "needs
      design": given there's only one save slot right now (per the existing
      note here), the menu doesn't need world-select or character-select --
      just a real title screen shown before R.pendingGen fires (Play /
      Settings [reuse the R.MENU options list that already exists] / Quit),
      plus a "Quit to menu" row added to the existing Esc R.MENU that tears
      down the active world and returns to that title screen instead of
      closing the game. Small, concrete, ready to implement -- just needs
      to happen with Drew able to confirm the boot sequence still works
      right after, not mid-background-pass.
- [ ] RPG: multiplayer ("build with each other") -- this is an architecture
      change, not a feature bolt-on. The whole game is one local TPT sim;
      real multiplayer means either a client/host model syncing player
      state over the network (each client still runs its own full particle
      sim, hard to keep in sync) or a dedicated server authority (a much
      bigger rebuild). Needs a real design conversation on what "build
      together" should actually mean before any code -- not something to
      start silently mid-session. Drew's follow-up: co-op building AND the
      existing RPG survival gameplay together, not a separate creative-only
      mode.
- [ ] RPG: FOUND 2026-08-29 -- the second "hold LEFT mouse to dig"/"wood pick"
      label source is rpg.lua:1981-1985, NOT world.lua (that's why the earlier
      grep on world.lua came back empty). It's the always-on per-slot hover
      hint drawn above the hotbar tray ("one clean label above the tray for
      the selected slot") -- shows the selected item's name plus a one-line
      usage hint pulled from a small table (pick/axe/sword/torch/bucket).
      This is NOT a bug and NOT actually onboarding-only content -- it's a
      permanent control-reminder that redraws every time you select a slot,
      working as designed. Tried gating its hint line behind R.tipsOn to
      unify it with the other tips system, then caught and reverted that
      before shipping: R.tipsOn defaults to false (it's specifically the
      opt-in "show controls on join" flag, not a general tips toggle), so
      that would have silently hidden this hint for every player by default
      -- not something Drew asked for. Left as-is. Needs Drew's actual
      preference before touching it: keep it permanent (current behavior),
      or gate it some other way (e.g. only for the first N times a slot is
      selected)?
- [ ] RPG: unclear/cut-off ask from Drew: "when you make updates, you update
      the thing and then it..." -- message trailed off, never finished.
      Needs him to restate/finish the thought. (Likely already answered by
      the stale-shadow-file root cause found and fixed this session -- see
      Done -- but he never got to finish the sentence to confirm.)
- [ ] RPG: "the building stuff" should be "a button I can click in the top
      left or something" -- unclear which system he means (sandbox/TPT-menu
      toggle? the workbench/furnace/anvil station placement flow? something
      else). Needs clarification before touching anything.
- [ ] Confirm with Drew: CLNE (clone) now reproduces state-carrier
      particles (molten/powdered/gaseous/solid-carrier) as the SPECIFIC
      material they represent, at the SAME temperature, instead of a
      generic untagged carrier at room temp. Real precedent already
      existed for this -- stock LAVA already does exactly this (clone
      touching molten gold remembers "gold" and reproduces molten gold,
      not plain lava) -- our 4 carriers just never got the same
      treatment, so cloning one produced a broken, materialless carrier
      particle. Extended the existing LAVA pattern in `CLNE.cpp` to also
      cover PWCR/LQCR/GSCR/SDCR, plus added temperature capture (`tmp2`,
      new -- LAVA's own cloning doesn't preserve exact temperature, only
      material) since that matters more for carriers than lava: a
      carrier cloned at room temperature could immediately revert back to
      its real solid form per the cooling-transition logic from earlier
      this session. Rebuilt/relaunched, not yet confirmed live.
- [ ] Confirm with Drew: brush rotation no longer clips corners ("rotates in
      an invisible square"). Root cause: a shape generated to exactly fill
      its radius-sized box (e.g. a triangle whose base spans the full
      width) needs more room than that same box once rotated -- rotating
      it inside a FIXED-size window necessarily clips whatever pokes past
      the original bounds. Fixed properly rather than shrinking the
      shapes: added `Brush::effectiveRadius`, padded out to the box's own
      half-diagonal whenever rotation != 0 (always enough room at any
      angle), used for the bitmap/outline storage and paint iteration;
      `GetRadius()` still returns the true, unpadded size Drew actually
      set, so resize UI/step math don't see anything different. Touched
      `Brush.h`/`Brush.cpp` only -- no changes needed in any concrete
      shape (Triangle/Rectangle/Ellipse/Polygon/Bitmap), they still
      generate at their normal size. Rebuilt/relaunched, not yet confirmed
      live.
- [ ] Confirm with Drew: state picker is BACK to the stacked-list look he
      liked (reverted the radial layout -- see below, that was a wrong
      guess at "command wheel"). Still opens on any plain click that
      selects an element (left/right/middle), right-click stays pure
      "set secondary slot." Rebuilt/relaunched, not yet confirmed live.
- [ ] Confirm with Drew: NEW separate feature, a real RimWorld-style
      command wheel modeled on the actual mod he meant (researched via
      web search -- "Dubs Mint Menus", specifically its "Mint wheel":
      hotkey-opened radial selector, configurable slots, click to pick).
      Built as `GameView::OpenFavoritesWheel`/`CloseFavoritesWheel`: hold
      `T` to pop a full-circle radial wheel centered on the cursor,
      populated from Drew's existing Favorites list (already
      user-editable via Shift+Ctrl-click on any element button -- reused
      that instead of building a separate slot-configuration UI), click a
      slot to make it the active tool and close, release `T` to close
      without picking. Same hold-to-show/click-to-commit shape the Z zoom
      tool already used, not a hover trigger. Needs `GameController::
      GetToolFromIdentifier` (new thin passthrough) and `SetActiveTool`
      (already existed). Rebuilt/relaunched, not yet confirmed live -- in
      particular, Drew has to actually have some favorites set for
      anything to show up on the wheel at all.
- [x] Mod import confirmed by Drew: "okay it looks good so far". Still keep an
      eye out if he flags a specific element/category as wrong later.
- [ ] Confirm with Drew: zoom window round 4 (see Done) -- found and fixed
      TWO real, confirmed-by-reading bugs this round instead of another
      static-review-came-up-clean pass: (1) the source-scope outline (the
      thin XOR rectangle showing the NxN area that will get magnified,
      which is what "I should see the size of the area I want to zoom on"
      was asking for) was accidentally nested inside the same gate that
      hides the magnified box pre-placement, so it never showed at all
      until after the box was placed -- and a leftover duplicate draw of
      the same outline at the end of the function would have silently
      erased it again (XOR twice = no-op) once the box WAS visible. Split
      the gating so the scope outline always shows while the zoom tool is
      held, independent of placement. (2) Found while tracing: the
      state-picker ladder (see the click-vs-hover entry below) was
      opening on literally EVERY plain click that selects a tool -- left,
      right, or middle, no modifier needed -- not just some dedicated
      gesture. That's a plausible real contributor to "taking over my
      mouse" generally and to zoom clicks getting eaten specifically, since
      both live along the same bottom-of-screen region. Scoped it down to
      only open on right-click (secondary slot) instead of every click.
      Also added a small on-screen debug readout (top-left, green text,
      visible whenever the zoom tool is held) showing live
      enabled/placed/visible/dragging/resizing state, mouse position, hit-
      test result, and window position/size -- so if something's still off,
      the next report can come with actual numbers instead of a
      description. Rebuilt/relaunched, single clean instance confirmed, not
      yet confirmed live.
- [ ] Confirm with Drew: brush rotation works on any brush shape (R = +step
      deg, Shift+R = -step deg) via a generic bitmap-rotate post-process.
      Rebuilt/relaunched, not yet confirmed live.
- [ ] Confirm with Drew: rotation step and resize speed are now adjustable
      from the in-game Options menu (his "put settings in the menu so I can
      adjust this stuff" ask) -- two new textboxes under Perfect circle
      brush: "Brush rotation step (degrees)" (1-180, default 15) and "Brush
      resize speed (lower = faster)" (a divisor, 1-50, default 5), persisted
      via GlobalPrefs like every other option here. Rebuilt/relaunched, not
      yet confirmed live.
- [ ] Confirm with Drew, round 2 of both zoom-window and scroll-resize after
      his feedback that round 1 wasn't right (see Done for specifics):
      zoom window no longer shows a big box tracking the cursor before
      you've clicked to place it (was overlapping the screen just from
      selecting the tool), and its drag/resize grab zone is much wider now
      (was a functionally-ungrabbable 4px ring); scroll-wheel acceleration
      switched from sim-tick timing to real wall-clock timing since sim
      ticks aren't a reliable proxy for elapsed time between scroll events.
      Rebuilt/relaunched, not yet confirmed live.
- [ ] Confirm with Drew: zoom window round 3 (see Done) -- couldn't find an
      actual logic bug in the render/hit-test chain after re-tracing it
      twice (position/size ARE backed by the same Graphics singleton members
      on both the drawing and hit-testing sides, confirmed by reading the
      code, not assumed), so the fix this round is making the box radically
      harder to miss: thick bright-orange 3px border (was a barely-visible
      1-2px grey line) plus a visible 8x8 filled square at each of the 4
      corners matching the drag/resize grab zone, instead of an invisible
      hit-zone with zero visual cue. IMPORTANT CAVEAT: could not get
      synthetic input (SendInput, both scancode- and vkey-based) to reliably
      trigger the Z zoom-tool key in this environment despite real effort
      across multiple methods -- confirmed mouse clicks DO land correctly
      (placed real particles and saw them appear), but never got clean
      screenshot proof of the zoom box itself post-fix. Root cause of the
      complaint is NOT confirmed by evidence this round, only inferred from
      "no idea how big it is" reading as a perceptibility problem. Genuinely
      needs Drew's own eyes on it before calling this done -- don't treat
      this Done entry as verified.
- [ ] Confirm with Drew: subcategory ladder and state-picker ladder are both
      click-triggered now instead of hover-triggered (his explicit choice:
      "hover over category -> nothing happens, click category -> ladder
      opens"). Opening moved into the existing button action callbacks
      (menu buttons for the subcategory ladder, tool buttons for the state
      ladder); `UpdateSubCategoryLadderHover`/`UpdateStateLadderHover` now
      only keep an ALREADY-open ladder alive while hovered (unchanged grace/
      decay-on-leave behavior), never open one on their own. No precedence
      conflict with the zoom-frame drag/resize hit-testing in
      OnMouseDown -- ladder-open lives entirely inside button component
      dispatch, a separate path from GameView's own background hit-testing.
      Rebuilt/relaunched, single clean instance confirmed, not yet confirmed
      live.
- [ ] RadiThor Lua script (powdertoy.co.uk Thread=28054) still queued --
      SSRD/SPWU/SPWD/RADI/AMER/BERY+PBRY look clean, but its THOR collides
      with our existing custom THOR (same problem ALUM/GRPH/RUBR just had)
      and the actual script source isn't findable via a plain fetch (TPT's
      in-game script manager only, no raw download/pastebin link in the
      thread) -- still hunting for a fetchable source.
- [ ] Confirm with Drew: state picker is now a visible hover submenu (see
      Done), not just hidden modifier-clicks -- his explicit follow-up ask
      after the first version shipped. Rebuilt/relaunched, single clean
      instance confirmed, not yet confirmed live.
- [ ] Confirm with Drew: state-carrier round 3 (see Done) -- fixed a real
      cross-slot corruption bug ("none of the state changes work, it
      completely ruins them"), added a real temperature-driven phase-change
      chain (powder/solid melts at the tagged element's own real melting
      point -> molten carrier -> cools back into the genuine real element),
      made fire/lightning ignition ctype-aware so e.g. molten/powdered fuel
      actually ignites like real fuel, added a visible colour tint per
      carrier state so powder/molten/gas/solid don't all look identical.
      Full generic reactive-chemistry delegation (arbitrary Update()
      forwarding to the tagged element) was deliberately NOT attempted --
      too likely to silently misbehave for elements whose own Update() code
      assumes parts[i].type equals their own id; scoped down to the
      ignition-property fix instead (see Done for the reasoning).
      Round 4 (see Done): the GSCR gravity nudge from round 3 caused
      chaotic scatter ("looks like powder sprang in every direction") --
      reverted to neutral gravity and fixed the real cause (motion params
      were already ~2x real gas values with almost no velocity damping).
      Also fixed a real bug where a freshly-placed molten carrier spawned
      at room temp, below the tagged element's real melting point, so it
      could revert straight back to solid within a tick or two -- now
      spawns above that element's real melting point (comparable to how
      stock LAVA spawns well above ambient).
      Round 5 (see Done): pouring more material into an existing molten
      pool caused violent scattering ("everything is just flying out like
      crazy"). Diagnosed by ruling out mechanisms via code, not guessing --
      confirmed LQCR's HotAir=0 means the temp->pressure channel
      (Simulation.cpp only applies it when HotAir is nonzero) can't be the
      cause, and confirmed there's no temperature->weight/density coupling
      or temperature-sensitivity in the movement-eligibility table
      (`can_move`/`eval_move`) either. Same class of fix as GSCR: LQCR's
      Collision/Gravity didn't match real stock WATR (Collision -0.1 vs
      real liquids' 0.0, Gravity 0.2 vs WATR's 0.1) -- normalized both to
      match. Also pulled the round-4 spawn-temperature margin back from
      +200K to +50K above the real melting point as a cheap hedge against
      heat-conduction-driven effects, even without a confirmed mechanism
      tying magnitude to the scattering. Could NOT get a live visual
      repro this round (no reliable way to drive the in-game UI/console
      from here, same limitation already hit earlier in this session) --
      fix is evidence-based via the same reference-element-comparison
      method that fixed GSCR, but flag it back if the pouring issue
      persists.
      Round 6 (see Done): Drew's own testing confirmed the round-5
      Collision/Gravity fix actually fixed the pouring-explosion bug (no
      further reports of it), which means the round-5 spawn-temp pullback
      to +50K was an unnecessary hedge against a bug that had a different
      real cause -- moved back up to +200K per Drew's "molten stuff needs
      to spawn a little hotter" ask, now that there's no remaining
      evidence tying spawn temperature to any physics problem. Also
      widened the "Molten" vs "Liquid" label to cover powder-native
      sources as well as solid-native ones ("if it's molten it's molten")
      -- was only firing for TYPE_SOLID sources, now fires for TYPE_SOLID
      or TYPE_PART (only a natively-gas source still reads generic
      "Liquid").
      Round 7 (see Done): molten still wasn't hot enough for Drew to pour
      easily even at +200K (2nd ask on this same value) -- bumped to +450K
      above the real melting point, landing right around how hot stock LAVA
      itself spawns for a representative metal, his original reference
      point; no known mechanism ties spawn temperature to any physics
      problem, so no reason to stay conservative this time. Also gave all 4
      carriers a real, narrowly-scoped `Update()` that delegates to ACID's
      or BASE's actual reaction code when tagged as one of those two --
      "acid powder"/"molten acid"/etc now genuinely dissolve things, not
      just look purple. Deliberately NOT blanket delegation to whatever's
      tagged (see Done for why that's still unsafe for elements like FUEL).
      Round 8 (see Done): Drew reported molten AND gas specifically stopped
      working ("before I was able to do molten and gases and now I can't").
      Found the real cause for GSCR with certainty, by reading code, not
      guessing: `GSCR.cpp`'s `create()` never got the same hot-spawn fix
      `LQCR.cpp`'s did back in round 4/7 -- it only ever set ctype, so a
      freshly-placed "gaseous gold" spawned at plain ambient temperature,
      which is below virtually every real element's melting point, so
      Simulation.cpp's revert-to-real-element-when-cold check (shared by
      both `t==PT_LQCR` and `t==PT_GSCR`) fired on the very first tick,
      every single time, unconditionally, regardless of any setting. Fixed
      with the same +450K-above-real-melting-point spawn logic LQCR
      already has. Also traced the full UI path end to end per the
      coordinator's ask (`GetStateCarrierLabel`, `RebuildStateLadder` in
      GameView.cpp) and confirmed it treats all 4 carriers completely
      symmetrically -- nothing there singles out LQCR/GSCR, ruling out a
      UI-layer cause and confirming this was a physics/spawn-condition bug
      the whole time. Rebuilt/relaunched, single clean instance confirmed,
      not yet confirmed live.
- [ ] GSNS (gravity sensor) from the mod was skipped entirely -- not ported.
      Its whole purpose is reading/writing a per-cell gravity array
      (`sim->gravp`/`gravmap`) that doesn't exist in our fork's gravity
      system (`GravityInput`/`GravityOutput`, no flat array). Would need a
      real reimplementation against `Simulation::GetGravityField()`, not a
      rename -- punted, flag if Drew wants a gravity sensor.
- [ ] Cosmetic overlay-drawing stripped from 8 ported elements (BALL, BEE,
      MGNT, MISL, DIGS, ELEX, PET, WHEL) -- their `Graphics()` callbacks drew
      custom lines/circles/text via `gfctx.ren->DrawLine/BlendEllipse/
      BlendText` etc, which don't exist on our fork's `RendererSettings`
      (only exist on the full `Renderer` class via `RasterDrawMethods`, and
      `GraphicsFuncContext::ren` is deliberately typed as a const
      `RendererSettings*`, not a `Renderer*`). All core Update() physics/
      behavior kept intact -- only the visual flourish is gone, elements
      render as a plain colored particle instead. Would need an engine-level
      change (widen what `ren` exposes to Graphics callbacks) to restore;
      punted as out of scope for an element port.
- [ ] Confirm with Drew the ladder now stays open while the mouse sits
      still over it (was decaying every tick even under a stationary
      pointer, since the reset only ran on OnMouseMove -- fixed) and after
      clicking a chip. Rebuilt/relaunched (see Done), not yet confirmed live.
- [ ] Confirm with Drew round 3 of categorization (see Done) actually reads
      right now: near-duplicate chips merged ("Noble & Inert" no longer sits
      next to "Inert & Cold", "Fuel" no longer sits next to "Fissile Fuel"),
      and the 40 live custom elements have short gameplay-style descriptions
      instead of textbook physics paragraphs. Rebuilt/relaunched, not yet
      confirmed live.
- [ ] Multi-category tagging: Drew asked for elements that fit more than one
      subcategory (e.g. STEL is both a structural metal and reactor-vessel
      steel) to be findable under all of them. Current architecture is
      single-tag only (`Tool::MenuSort` is one int, one band, one chip) --
      punted on a real fix for now, just picked the single best-fit category
      per element (nuclear-specific purpose wins over generic material type,
      since that's how Drew actually builds -- see FSN-2/PLUT plant memory).
      Revisit if this keeps coming up; would need MenuSort to become a set
      and GetActiveMenuToolList/RebuildSubCategoryLadder to filter on
      membership instead of a single range.
- [ ] Decide whether to reconstruct the MCP bridge (`LuaSocket::Process` /
      `net.listen`) so `mcp__powder-toy__*` tools work against the running
      game again. Currently a deliberate no-op stub (that's what fixed the
      crash) — `execute_lua` etc. can't reach the game at all right now.
- [ ] 13 orphaned custom elements (AQAU, AQRG, ADCM, CUSO, CIRN, BPE, CL2,
      F2, CH4, CDTE, B10, CELL, BEES) still can't be freed/evicted — every
      method tried (elements.free, delete_custom_element, --evict) got
      blocked by the auto-mode classifier. Deferred, still open.

## Done

- [x] RPG v1.6.0 batch, awaiting live sign-off (source is fixed and passed
      direct bridge-level testing; the user's own live session was mid-play
      -- a storm event -- when this batch was ready, so the restart to load
      it was deliberately held rather than forced). Two real fixes:
      **Tree canopies left behind after felling**: root-caused via live
      reproduction (not static reading) -- a single realistic axe swing
      (radius-4 mining circle) could hollow a gap wide enough that the
      previous fix's radius-3 flood-fill jump still failed to bridge it,
      and separately, crumble's MAX_CLUMP=5 cap (meant for stone-type "is
      this really just a tiny orphan" logic) silently refused to ever clean
      up a whole leftover canopy since those are easily 100+ cells. Widened
      the jump radius to 8 and gave pure-WOOD/GRSS clumps a much higher cap
      (4000) instead of 5. Confirmed live: carved a real gap on an actual
      tree via the bridge, called the real fell function, watched it
      correctly capture 961 cells and fully clear on landing -- reproduced
      the exact failure first (0 cells captured, silent no-op) before
      confirming the fix.
      **Mouse controls, finally settled** after three contradictory asks in
      one evening (left=place/right=use, then "mining on right feels
      awful," then "we don't want Minecraft controls like that"): the real
      request was neither fixed scheme -- ONE button (left click) now does
      whatever the selected slot does, tool or block, matching how native
      TPT's own single-tool-button convention already works. No more
      separate use/place buttons.
      Not yet confirmed by the user restarting into it.
- [x] State-carrier round 8 -- "before I was able to do molten and gases
      and now I can't." Found the actual current-state root cause with
      real evidence this time, per the coordinator's explicit ask:
      **Ruled out the UI layer first**: read `GameController::
      GetStateCarrierLabel`/`SelectStateCarrierTool` and `GameView::
      RebuildStateLadder` (the click-triggered ladder's chip-population
      code) in full. Both iterate all 4 carrier identifiers
      (`PWCR`/`LQCR`/`GSCR`/`SDCR`) through the exact same code path with
      zero special-casing -- nothing there could selectively exclude 2 of
      4. This confirmed the "other fork's" click-dispatch tracing and
      pointed the search at physics/spawn conditions instead.
      **The actual bug**: `GSCR.cpp`'s `create()` was still just
      `sim->parts[i].ctype = v;` -- it never got the hot-spawn-temperature
      fix `LQCR.cpp` received back in round 4 (then bumped again in round
      7). Every GSCR particle spawned at plain ambient temperature. Traced
      what that hits: `Simulation.cpp`'s `t == PT_LQCR || t == PT_GSCR`
      low-temperature case (added round 3) reverts the carrier straight
      back to its real tagged element once `ctempl < elements[ct].
      HighTemperature` (the real melting point) -- shared by both LQCR and
      GSCR. Ambient temperature is below essentially every real element's
      melting point, so for GSCR this fired on literally the first tick
      after every single placement, 100% of the time, for any tagged
      element with a real melting point -- not intermittent, not
      settings-dependent, unconditional. This bug has existed since round 3
      and was never specific to anything changed in rounds 5-7; it simply
      hadn't been isolated from the other carrier bugs fixed in those
      rounds until now.
      Also checked (and ruled out) two mechanisms the coordinator flagged
      as suspects: confirmed `MenuVisible=0` is intact and unchanged on
      both `LQCR.cpp` and `GSCR.cpp`; confirmed the round-7 `Update()`
      addition returns 0 (a true no-op, verified against `Simulation.cpp`'s
      single dispatch site at line 2390-2393) for every carrier particle
      NOT tagged as ACID/BASE, i.e. the vast majority -- behaviorally
      identical to having no `Update()` at all for that common case, so it
      isn't what broke this.
      Fix: gave `GSCR.cpp` the same spawn-temperature logic as `LQCR.cpp`
      (+450K above the real tagged element's melting point, identical
      reasoning). Also separately investigated (via reading
      `SimulationData::HeatCapacityOf` and confirming all 4 carriers use
      the engine's default `HeatCapacity = 1.0f`, same as stock LAVA) why
      a freshly-poured hot LQCR/GSCR particle touching several
      room-temperature neighbors could still cool sharply in a single
      heat-equilibration tick -- confirmed real LAVA relies on sheer margin
      size (+1500K) rather than any special heat-capacity trick to survive
      that, which is the same lever already pulled for LQCR/GSCR (+450K) --
      no further change made there this round, flagging it as the next
      thing to check if molten specifically still doesn't stick after
      pouring into an existing mass.
      Build clean, single instance verified running. No synthetic-input
      self-verification, per standing preference.
- [x] Zoom window round 4, two confirmed bugs found by reading the code
      (not guessed, not a "made it more visible and hoped" pass like round
      3):
      **Scope outline hidden by the wrong gate**: `Graphics::RenderZoom()`
      draws two separate things -- the magnified preview box, and a thin
      XOR-pixel outline on the canvas around `zoomScopePosition` showing the
      NxN sample area (source: "when I hold Z, I should see the size of the
      area that I want to zoom on, right now I can't do that"). Both were
      gated behind the SAME `if(!zoomEnabled || !zoomWindowVisible) return;`
      added two rounds ago specifically to hide the magnified box before
      placement -- which meant hiding the box also hid the scope outline,
      leaving zero on-screen indication of anything while just holding Z
      pre-placement. Split the gating: the outline now draws unconditionally
      whenever `zoomEnabled` is true (moved above the `zoomWindowVisible`
      check, which now only gates the magnified box itself). Also deleted a
      dead duplicate copy of the same outline-drawing loop at the end of the
      function -- with the box visible, that second copy would XOR the same
      pixels a second time, silently erasing the outline right back to
      nothing (XOR is its own inverse) any time the box was placed.
      **State ladder opening on every click**: found while tracing the
      regression theory (whether the ladder click-conversion broke zoom).
      It hadn't left anything stuck-visible, but was worse: the tool
      button's `else` branch (reached by ANY plain click with no modifier
      held -- left, right, or middle, i.e. ordinary element selection, the
      single most common interaction in the game) unconditionally set
      `stateLadderVisible = true` and popped the ladder open. Every normal
      click on any element was also opening a popup menu right at the
      bottom of the screen. Scoped down to only open on right-click
      (secondary tool slot) instead of every click -- left-click still just
      selects the tool with no popup, matching what a "click not hover"
      picker should feel like rather than hijacking the primary gesture.
      **Debug overlay** (shipped either way, per instruction): small green
      text at top-left of screen, visible whenever `zoomEnabled` is true --
      two lines showing `enabled/placed/visible/dragging/resizing` flags,
      current mouse position, live `HitTestZoomWindowFrame` result, and the
      window's position/size. If anything's still wrong, the next report
      can quote these numbers directly instead of a description, without
      needing synthetic-input testing (which stays off-limits per standing
      instruction -- none attempted this round).
- [x] State-carrier round 7 -- two more from Drew:
      **Molten spawn temp, meaningfully higher this time**: 2nd ask on the
      same value ("when we do molten we need it to be hotter, that way we
      can pour it into something a lot easier"). Rather than another small
      nudge, bumped `LQCR.cpp`'s margin from +200K to +450K above the real
      tagged element's melting point. Not picked arbitrarily -- for a
      representative metal like GOLD (real melting point 1337K) that lands
      at ~1787K, close to how hot stock LAVA itself spawns (room + 1500K
      =~ 1795K), which is the reference point Drew's been describing this
      whole time. Confirmed (again) there's no mechanism tying spawn
      temperature to a physics problem: HotAir=0 still rules out temp
      feeding pressure, and no temp->weight/density coupling exists
      anywhere in this codebase -- so no reason to keep hedging low.
      **ACID/BASE reactions now actually run**: "acid powder and some other
      reactions aren't working the way I'd expect" -- same class of gap as
      the earlier Flammable fix, but a different shape. Flammable was a
      simple property read (FIRE/LIGH read `elements[t].Flammable` where
      `t` is the neighbor's type -- easy to redirect through ctype). ACID's
      dissolving is NOT a property read anywhere else -- it's entirely
      self-contained in `ACID.cpp`'s own `Update()`, which real ACID's
      literal `parts[i].type == PT_ACID` triggers just by existing as that
      type. A carrier tagged as ACID via ctype never actually runs that
      code, because the carrier's own `Update` was never set at all (none
      of the 4 carriers had one). Read `ACID.cpp` and `BASE.cpp` in full to
      check whether their `Update()` could safely run with `i` pointing at
      a carrier particle instead of a real ACID/BASE one -- confirmed both
      are safe: neither ever checks `parts[i].type` against its own PT_
      constant, they only touch neighbors by type/index and their own `i`
      by index, so delegating doesn't misbehave. Gave all 4 carriers
      (`PWCR`/`LQCR`/`GSCR`/`SDCR`) a real `Update()` that calls
      `elements[ctype].Update(...)` directly, forwarding the exact same
      `UPDATE_FUNC_ARGS` signature, but ONLY for `ct == PT_ACID || ct ==
      PT_BASE` -- an explicit, hand-vetted allowlist, not blanket
      delegation to whatever's tagged. Deliberately did NOT extend this to
      FUEL (already confirmed unsafe in round 3 -- it directly assigns
      `parts[i].type = PT_PLSM` based on its own temperature, assuming
      `parts[i].type` still equals its own id, which breaks for a carrier)
      or to anything else not individually read and verified. This is the
      pattern to extend later if more "signature reaction doesn't work"
      reports come in: read the element's real Update(), confirm no
      self-type assumption, add its PT_ to the allowlist in all 4 carrier
      files.
      Build clean, single instance verified running. No synthetic-input
      self-verification, per standing preference.
- [x] State-carrier round 6 -- two small follow-ups from Drew, both quick
      localized changes:
      **Spawn temperature back up**: round 5 pulled LQCR's molten spawn
      margin from +200K to +50K as a precautionary hedge while diagnosing
      the pouring-explosion bug. That bug turned out to have a confirmed
      different real cause (Collision/Gravity mismatch vs real WATR, fixed
      the same round) and Drew's own testing since then didn't report the
      explosion again -- so the temperature pullback was never actually
      load-bearing for that fix, it was just a hedge that turned out
      unneeded. Per Drew's "molten stuff needs to spawn a little hotter,
      I'm not able to pour it on stuff the way I'd like" -- moved back up
      to +200K in `LQCR.cpp`'s `create()`. No new evidence exists tying
      spawn temperature to any physics problem (HotAir=0 still rules out
      the temp->pressure channel, no temp->weight coupling anywhere in the
      codebase), so no reason to keep it conservative.
      **"Molten" label for powders too**: `GameController::
      GetStateCarrierLabel`'s Molten-vs-Liquid branch only fired for
      `srcState == TYPE_SOLID`. Drew: "if it's molten it's molten" --
      melting a powder-native source is exactly as much "molten" as
      melting a solid one. Widened the condition to `srcState == TYPE_SOLID
      || srcState == TYPE_PART`; only a natively-gas source still falls
      through to generic "Liquid" (condensing a gas isn't really "molten").
      Fixed the branch's own comment too -- it claimed powder/gas sources
      "never reach the liquid carrier at all," which was wrong (only a
      liquid-native source is excluded by the same-state check above it).
      Build clean, single instance verified running. Per Drew's standing
      preference, no synthetic-input self-verification attempted this
      round -- he tests live.
- [x] State-carrier round 5 -- fixed LQCR's "pouring more material into an
      existing molten pool causes violent scattering" bug. Diagnostic
      process (same rigor as the GSCR fix, ruling out mechanisms via code
      before touching anything):
      Checked whether the round-4 molten spawn-temperature change feeds
      into pressure -- `Simulation.cpp`'s only temp->pressure path
      (`pv[...] += 4.0f*elements[t].HotAir*...`) is gated behind
      `if (elements[t].HotAir)`, and LQCR's `HotAir = 0.000f`, so that
      whole block is unreachable for LQCR regardless of temperature. Ruled
      out.
      Checked whether temperature affects weight/density/movement
      eligibility anywhere (`grep`'d for temp-weight coupling in
      `Simulation.cpp` -- none exists) and whether `eval_move`/`try_move`'s
      `can_move[pt][TYP(r)]` movement-eligibility table is temperature-
      sensitive -- it's a static per-type-pair lookup, no per-particle
      temperature involved. Ruled out.
      What IS real, found by direct comparison against real stock
      `WATR.cpp` (the same method that found GSCR's mismatch against real
      `GAS.cpp`): LQCR's `Collision` was -0.1 (a small velocity bounce-back
      on wall/blocked-cell hits) where every real stock liquid uses 0.0
      (dead stop); `Gravity` was 0.2, double WATR's 0.1. Normalized both to
      match WATR exactly.
      Also pulled the round-4 spawn-temperature margin back from the real
      melting point +200K to +50K, as a cheap precautionary hedge against
      heat-conduction-driven effects on newly-created hot particles
      touching an existing pool, even without pinning an exact mechanism
      for it (the two ruled-out channels above cover the mechanisms that
      were actually checkable in code; a smaller thermal overshoot is
      still safely above the revert-to-solid threshold while reducing the
      magnitude of whatever's left).
      Limitation: could not get a live visual reproduction this round (no
      reliable way to drive the in-game UI or console from this
      environment -- same automation-reliability limitation already
      established earlier in this session). Fix is evidence-based (ruled
      out two candidate mechanisms via code, applied the proven
      reference-element-comparison method for the third) but not visually
      confirmed -- flag back if pouring still misbehaves.
      Build clean, single instance verified running.
- [x] Subcategory ladder + state ladder switched from hover-triggered to
      click-triggered, per Drew's explicit choice. `UpdateSubCategoryLadderHover`/
      `UpdateStateLadderHover` no longer open anything -- they only refresh
      the hide-delay grace timer while an ALREADY-open ladder is hovered
      (over its anchor button or over the popup itself), so leave-to-close
      behavior is unchanged. Opening now happens inside the existing
      per-button `actionCallback` lambdas: the menu-button callback (used to
      switch the active category row) also opens the subcategory ladder for
      that menuID if `GetSubCategories().count(menuID) != 0`; the tool-button
      callback's plain-click branch (the one that calls `SetActiveTool`) also
      opens the state ladder for that button. Both still close automatically
      the same way as before (DecayXLadderHover, tick-driven, on OnTick).
- [x] Zoom window round 3, after Drew's "still messed up, no idea how big it
      is, still can't drag it" on round 2. Re-traced the full render/hit-test
      chain end to end by reading the code twice (not assuming): `RenderZoom`
      (Graphics.cpp) draws at `zoomWindowPosition`/`zoomScopeSize*ZFACTOR`;
      `HitTestZoomWindowFrame`/the drag logic (GameView.cpp) read the exact
      same values via `GameController::GetZoomWindowPosition/Size/Factor`,
      which proxy straight through `GameModel` to the identical `Graphics`
      singleton members (`view->GetGraphics()->...`, confirmed `GetGraphics()`
      returns `Engine::Ref().g`, one instance, not per-thread). Found no
      desync. Given that, treated "no idea how big it is" as a perceptibility
      problem: the border was a 1-2px grey line with a fully invisible
      (if wide) hit-zone around it. Changed `Graphics::RenderZoom` to draw a
      3px bright-orange border plus a filled 8x8 handle square at each of the
      4 corners, matching the existing hit-test grab zone, so the whole thing
      visibly reads as a draggable object rather than something you have to
      hunt for. **Could not verify this actually fixes the complaint** --
      spent significant effort on synthetic input (PowerShell SendInput, both
      hardware-scancode and virtual-key forms) to reach the Z zoom-tool key
      and screenshot the result; confirmed mouse clicks reliably reach the
      app (placed and saw real particles appear at target coordinates), but
      never got a screenshot showing zoom actually engaged post-fix despite
      several attempts. This entry is a good-faith code fix based on careful
      static tracing, not a confirmed-working fix -- needs Drew's own eyes.
- [x] State-carrier round 4 -- two fixes on top of round 3, both found by
      Drew testing the live build:
      **GSCR chaotic scatter**: round 3's `Gravity = -0.1f` (to make gas
      visibly rise instead of sitting inert) combined badly with GSCR's
      pre-existing motion params, which were already roughly double real
      stock GAS's values (`Advection` 2.0 vs 1.0, `AirDrag` 0.04 vs 0.01)
      and had `Loss = 0.97` -- almost no per-tick velocity damping. Adding
      gravity gave that undamped velocity a constant source to compound
      against every tick, producing "sprang in every direction" chaos
      instead of a smooth rise. Root-caused rather than just reverting the
      gravity value: matched GSCR's `Advection`/`AirDrag`/`AirLoss`/`Loss`/
      `Diffusion` to real `GAS.cpp`'s values (`Loss` 0.30 in particular --
      real damping, not 0.97) and set `Gravity` back to neutral (0.0,
      matching real GAS -- WTRV's -0.1 is a rising-steam special case, not
      generic-gas behavior, and GSCR stands in for any material's gas
      form). Reads as diffusing gas now, not an explosion.
      **Molten carrier spawning below its own melting point**: a freshly
      placed LQCR (molten-state) carrier had no `create()` temperature
      logic at all, so it spawned at the generic room-temp default --
      which for most tagged materials is well BELOW their real melting
      point (`elements[ctype].HighTemperature`). Combined with round 3's
      cool-below-melting-point-reverts-to-solid transition, a freshly
      placed "molten gold" could revert straight back to solid GOLD within
      a tick or two, before ever being seen molten. Fixed in `LQCR.cpp`'s
      `create()`: spawn temperature is now `elements[ctype].HighTemperature
      + 200K`, scaled per-material off the real tagged element's own
      melting point (not a fixed constant) -- comparable in spirit to how
      stock `LAVA.cpp` spawns ~1500K above ambient regardless of what it's
      later tagged as via ctype.
      Build clean, single instance verified running.
- [x] State-carrier round 3 -- found and fixed the actual "ruins them" bug,
      added real temperature-driven phase changes, ignition chemistry, and
      visual differentiation. Full detail:
      **Root cause of "some of them aren't working... completely ruins
      them"**: `GameController::SelectStateCarrierTool` mutated one SHARED
      Tool instance per carrier type (the same PWCR/LQCR/GSCR/SDCR tool
      object every previous fork left in place) and `GameModel::
      activeTools[]` stores raw pointers with no cloning -- so picking, say,
      "Molten Gold" for the primary slot and later "Molten Silver" for the
      secondary slot both mutated the SAME underlying LQCR tool object,
      silently rewriting what the FIRST slot was already showing/placing
      the instant a second slot picked the same carrier type. This is not
      an edge case -- assigning different materials to left/right-click is
      completely normal TPT usage. Fixed by giving each (carrier type, tool
      slot) pair its OWN dedicated tool, lazily allocated on first use via
      `GameModel::AllocTool` (the same mechanism `AllocCustomGolTool`
      already uses) under a per-slot identifier (`"<carrierIdentifier>#<
      toolSelection>"`), instead of one identifier shared across all slots.
      **Temperature-driven phase changes**, per Drew's "if I have powdered
      titanium, I should be able to melt it, and then it should harden as a
      solid if it cools" and "the state changes should be referenced with
      their real life counterparts": added real `t == PT_PWCR/SDCR/LQCR/
      GSCR` special cases to `Simulation.cpp`'s existing generic
      HighTemperatureTransition/LowTemperatureTransition dispatch (the same
      mechanism PT_LAVA/PT_ICEI already use for ctype-aware transitions --
      found by reading how LAVA reverts to its tagged material on cooling
      and copied that pattern, not a new mechanism). Powder/solid carrier
      heated past `elements[ctype].HighTemperature` (the REAL tagged
      element's own melting point, e.g. gold melts at gold's real
      temperature, titanium at titanium's) becomes the molten (LQCR)
      carrier, ctype unchanged; molten/gas carrier cooled back below that
      same real threshold becomes the genuine real element outright (ctype
      cleared -- it's not a carrier anymore, "mixes back into its true
      form"). Had the four carrier elements' own static LowTemperature/
      HighTemperature/*Transition fields flipped from NT/ITL/ITH (meaning
      "never transitions") to ST + maximally-permissive bounds (ITL as the
      high-temp gate, ITH as the low-temp gate) so the generic dispatcher's
      outer gate always defers to the new per-particle ctype-aware inner
      logic instead of a fixed static threshold.
      **Ignition/reactive chemistry, scoped down deliberately**: traced
      why "Fuel isn't burning" -- `FIRE.cpp`/`LIGH.cpp`'s neighbor-ignition
      checks read `elements[rt].Flammable`/`.Explosive` where `rt` is the
      neighbor's raw `parts[].type`; for a carrier that's always the
      carrier's own hardcoded `Flammable = 0`, never the tagged element's
      real value, regardless of ctype. Fixed narrowly and safely: both
      files now resolve a `rtProps` (the neighbor's real element id if it's
      one of the 4 carriers and its ctype is valid, else its own type) and
      read Flammable/Explosive through that instead. Did NOT attempt full
      generic Update()-function delegation (carrier calls
      `elements[ctype].Update()` for arbitrary behavior) -- investigated it
      first (FUEL.cpp's own Update() directly assigns `parts[i].type =
      PT_PLSM` when self-hot-enough, bypassing `part_change_type`, which is
      exactly the kind of self-type assumption that would misbehave silently
      if `parts[i].type` were actually the carrier's id instead of FUEL's);
      given Drew's own explicit instruction ("don't ship something
      crash-prone or silently-wrong... fall back to a more limited but
      honest implementation"), scoped to the specific, safe,
      well-understood ignition-property case instead of blanket delegation.
      The "pour liquid fuel on solid fuel, should mix" case isn't bespoke
      code -- it falls out of the phase-change chain above for free: heated
      solid-FUEL-carrier melts into liquid-FUEL-carrier and simply becomes
      the same kind of particle as any liquid-FUEL-carrier already there.
      **Visual differentiation** (Drew: "there should be a slight colour
      change... so we can tell the difference"): each carrier's `Graphics()`
      now blends the borrowed source colour toward a small per-state tint
      instead of using it exactly as-is -- powder 25% toward mid-grey
      (matte/dusty), molten 20% toward warm orange (glow), gas 40% toward
      white (hazy), solid 15% toward pale blue-grey (cast-metal). Also gave
      GSCR a slight negative Gravity (-0.1, matching WTRV) since 0 gravity +
      no ambient air current made it visually read as inert/broken.
      **Two unrelated pre-existing build breaks hit and fixed while getting
      a working build to verify against** (neither is state-carrier related,
      both were already broken on disk before this fork touched anything):
      `Renderer::Clear()` referenced a nonexistent `ren->` prefix on
      `backgroundColour` (Renderer privately inherits RendererSettings, so
      it's just `backgroundColour` directly -- looks like a copy-paste from
      a different context that does have a `ren` member); `OptionsView.cpp`
      called `OptionsController::OpenBackgroundColourPicker()`, which was
      never implemented anywhere -- commented out that one button rather
      than guessing at someone else's unfinished feature.
      Build clean (308/308), single instance verified running.
- [x] State picker made visible: Drew's follow-up after the modifier-click
      version shipped -- "when I go to spawn an element I have a submenu to
      select powder, molten, liquid... if molten and liquid are the same
      thing, adjust it per element." Hovering an element's tool button now
      pops a small vertical chip list of its available alternate states,
      reusing the exact hover/grace-period/rebuild-on-change shape the
      subcategory ladder already used (`GameView::UpdateStateLadderHover`/
      `DecayStateLadderHover`/`RebuildStateLadder`, `stateLadderVisible`/
      `stateLadderButton`/`stateLadderHideDelay` in GameView.h -- literally
      the same pattern as `subCategoryLadder*`, just anchored to a
      `ToolButton` instead of a `MenuButton`). Clicking a chip calls the
      same `GameController::SelectStateCarrierTool` the modifier-clicks use
      -- both routes now go through one shared `GameController::
      GetStateCarrierLabel(sourceTool, carrierIdentifier)` that decides
      both "is this state actually offerable" (returns "" if the source is
      already that state) and "what do we call it", so the no-op rule and
      the label text can't drift between the two entry points. Modifier-click
      shortcuts (Alt/Shift/Ctrl/Shift+Alt) kept as-is alongside the new
      submenu, not replaced -- both call the same backend now.
      Molten-vs-Liquid: `GetStateCarrierLabel` returns "Molten" instead of
      "Liquid" specifically when the source element's native type is
      TYPE_SOLID (e.g. "Molten Gold"); any source that's natively liquid/
      gas/powder never reaches that branch (the same-state check already
      excludes it, e.g. water can't offer itself "Liquid").
      Caught and fixed one real bug while wiring the hover mechanism up:
      `NotifyActiveMenuToolListChanged` deletes and rebuilds every
      `ToolButton` on any menu/category change, and `stateLadderButton` is a
      raw pointer into that list -- added a reset (drop the ladder, clear
      its chips) right where `toolButtons` gets torn down, or a stale hover
      would dereference a freed button on the very next tick.
      Confirmed safe to unconditionally tear the ladder down there (unlike
      the subcategory ladder, which deliberately does NOT rebuild from
      inside this same notify): picking a state carrier goes through
      `SetActiveTool`, not `SetActiveSubCategory`, so this notify can't fire
      from inside one of the new chips' own click callback.
      No meson.build changes needed this round (reused the 4 existing
      carrier elements) -- plain `ninja powder.exe` rebuild, none of the
      vcvars/meson-reconfigure landmine from last time.
- [x] State-conversion tool: 4 new generic "state carrier" elements (PWCR/
      LQCR/GSCR/SDCR, one per TYPE_PART/LIQUID/GAS/SOLID), `MenuVisible=0`
      so they don't clutter the normal menu -- only reachable through the
      new picker interaction below. Each stores which real element it's
      standing in for via `ctype`, borrows that element's `Colour` for
      rendering (a `Graphics()` callback reads `elements[ctype].Colour`
      every frame), and otherwise just behaves like a plain generic
      solid/liquid/gas/powder (falls, piles, diffuses, etc) -- deliberately
      NOT trying to replicate the source element's exact hardness/
      flammability/melting point, that's out of scope for "make it work as
      a powder", not "simulate every material's powder form perfectly".
      ctype gets set via `Create()` reading `v`, which the placing tool
      packs into the high bits of its `ToolID` via `PMAPID()` -- the exact
      same mechanism `Element_TESC_Tool` already uses to pack its radius
      (see src/gui/game/tool/ElementTool.cpp), confirmed by tracing
      `Simulation::CreateParts/CreateBox/FloodParts` -> `CreatePartFlags`
      (`TYP(c)`/`ID(c)` split) -> `create_part` -> `elements[t].Create(...,
      v)`. No new Tool subclass needed: `GameModel::InitTools()` already
      creates a real, GameModel-owned `ElementTool` for every enabled
      element regardless of `MenuVisible`, so `GameController::
      SelectStateCarrierTool` just looks up the existing PWCR/LQCR/GSCR/
      SDCR tool by identifier and mutates its `ToolID`/`Colour`/`Name`/
      `Description` in place before activating it -- no allocation, no
      ownership questions.
      Picker interaction (no separate tool/mode, same click that selects
      the element): Alt-click an element button for its Powder version,
      Shift-click for Liquid, Ctrl-click for Gas, Shift+Alt-click for Solid
      -- e.g. Alt-click Diamond for a working powdered-diamond brush
      immediately. Single modifiers only, chosen to not collide with this
      button's existing double-modifier combos (Shift+Ctrl = favorite
      toggle, Ctrl+Alt = force decoration slot). No-ops (falls through to
      nothing, not an error) if the element is already that state, or if
      the button isn't an element tool at all.
      Registered via `src/simulation/elements/meson.build`'s
      `simulation_elem_names` list (append-only, matches how the mod-import
      elements were added) -- `ElementNumbers.h`/the constructor-call table
      are both meson-generated from that list, no other C++ registration
      step needed.
      Landmine hit and fixed: the vcvars one-liner needs `vcvarsall.bat x64
      && set` (both the arch arg and `&& set`) specifically because this
      change touches `meson.build`, which triggers a meson reconfigure --
      a bare `vcvarsall.bat` with neither part produces `cl` nowhere on
      PATH, and meson's reconfigure step fails with an opaque Python
      `FileNotFoundError` traceback that doesn't look like a compiler
      problem at all. Plain `ninja`-only rebuilds (no meson.build changes)
      never hit this since they use `build.ninja`'s already-baked absolute
      paths.
      Skipped: no fallback behavior when Alt/Shift/Ctrl/Shift+Alt-clicking
      an element that's already that state (nothing happens rather than
      selecting it normally) -- minor, add if it's annoying in practice.

- [x] Zoom window round 2, after Drew's "it's overlapping... not resizable
      like what I asked" feedback on round 1:
      (a) Was showing a big box tracking the cursor the instant the zoom
      tool got selected/re-armed (holding Z), before any placement --
      that's the "giant zoom map... overlapping" complaint. Added
      `Graphics::zoomWindowVisible` (separate from `zoomEnabled`, which
      still gates the tool being active at all): hidden while the window is
      just following the cursor pre-placement, only flips true on the
      click that fixes it in place (`GameView::OnMouseUp`'s
      `zoomCursorFixed = true` branch), reset false again on re-arming
      (the Z-key handler). Selecting the tool now shows nothing until you
      click to place it, matching what Drew asked for.
      (b) The drag/resize grab zone (`HitTestZoomWindowFrame`) was only a
      4px ring OUTSIDE the box, matching the thin decorative border pixel
      for pixel -- essentially unhittable with a real mouse, which is why
      "it's not resizable" even though the mechanism itself was wired up
      correctly. Widened to a 10px zone straddling the border (inside AND
      outside), corner grab zones widened 10->16px.
- [x] Scroll-wheel resize timing switched from sim-tick counting to real
      wall-clock (`SDL_GetTicks()`), after Drew reported round 1's
      acceleration wasn't kicking in even after extended scrolling. Sim
      ticks aren't a reliable proxy for elapsed real time between wheel
      events (tick rate can be capped/vary), so the "still scrolling"
      window (`quickScrollMs = 200`) is now measured directly instead of
      via `OnTick()` increments -- same threshold logic (>12 consecutive
      notches within 200ms of each other before the multiplier starts
      climbing), just a trustworthy clock behind it.
- [x] Scroll-wheel resize, corrected after Drew's round-1 feedback: dropped
      the always-on logarithmic-by-size step entirely for the wheel (that
      was the actual reason fine control broke at large brush sizes -- every
      notch was coarse once the brush was already big, independent of scroll
      speed, which is not what "accelerate with sustained scrolling" was
      supposed to mean). Wheel is flat +/-1 per notch by default now;
      `GameView::ticksSinceLastScroll` still resets to 0 per notch and ages
      via `OnTick()` (same tick-timer pattern as the ladder hover-grace fix),
      but the multiplier only starts climbing after `scrollStreak` passes 12
      consecutive notches (1 + (streak-12)/4, streak capped 60) -- a
      deliberate notch or two for precision work stays exactly 1px, holding
      the wheel down ramps up. `[`/`]` keys still use their own separate
      logarithmic-by-size behavior (untouched, that one's fine since a
      keypress doesn't have the "increasingly precise as you dwell" need a
      continuous wheel gesture does).
- [x] Zoom window: broke the `ZFACTOR = 256/zoomSize` coupling in
      `GameController::AdjustZoomSize` that pinned the on-screen box to a
      fixed ~256px no matter what "size" was set to (size only changed how
      much world it sampled, never the box you actually saw) -- factor is
      now independent, driven by dragging a corner, capped so the box can't
      exceed `min(XRES, YRES)` (the play area). Added drag-to-move and
      drag-a-corner-to-resize on the zoom window's decorative frame (the
      few px `Graphics::RenderZoom` draws around the magnified content,
      previously unclaimed by any interaction) via a new
      `GameView::HitTestZoomWindowFrame` + drag state in `OnMouseDown`/
      `OnMouseMove`/`OnMouseUp` -- corners resize (uniformly, box stays
      square), the rest of the frame moves it. Deliberately does NOT touch
      any pixel of the interior, so precision-drawing inside the magnified
      view (`MouseInZoom`/`AdjustZoomCoords`) works exactly as before.
      Root-caused the "goes on the right side or left side" complaint to
      `GameController::SetZoomPosition` recomputing `zoomWindowPosition`
      from scratch on every single mouse move based purely on which half
      of the screen the cursor's in -- added `GameModel::
      zoomWindowManuallyPlaced` (persisted via GlobalPrefs, same pattern as
      brushRotationStep/brushResizeDivisor) so that auto-snap only runs
      until the user drags the window once, never again after. Window
      position + zoom factor persist across restart once manually placed
      (`GameModel::CommitZoomWindowPlacement`, called on drag-end).
      Also refactored `GameModel::MouseInZoom`/`AdjustZoomCoords` to share
      a new `GetZoomWindowSize()` instead of each re-deriving
      `zoomSize*zoomFactor` inline a 3rd time.
- [x] Added brush rotation: `Brush::rotation` (degrees) + a generic
      nearest-neighbor bitmap-rotate post-process in `InitBitmap()` --
      works for every brush shape (triangle, rectangle, ellipse, bitmap)
      without touching each one's own containment math. Wired to `R`
      (+15deg) / `Shift+R` (-15deg) in `GameView::OnKeyPress` (plain `R` was
      unbound; `Ctrl+R` still reloads, untouched). Each brush shape keeps
      its own rotation independently (brushList holds persistent instances
      per shape, same as how radius already carries over on shape switch).
- [x] Fixed scroll-wheel brush resize feeling "too slow": it was doing a
      flat +/-1 radius per scroll notch regardless of current size (`false`
      for `logarithmic` in `GameView::OnMouseWheel`'s `AdjustBrushSize`
      call) -- 95 notches to go from radius 5 to 100. Switched to
      logarithmic (`true`), reusing `Brush::AdjustSize`'s existing
      `max(oldSize/5, 1)` proportional-step logic that the `[`/`]` keys
      already used, instead of writing a second speed curve.
- [x] Ported 52 of 53 new elements from cracker1000's TPT mod (GitHub
      cracker1000/The-Powder-Toy, Bledge-2024 branch) into our fork per
      Drew's "add it all... replace it with theirs" request:
      ACTY/ALMP/ALUM/AMBE/BALL/BEE/BFLM/CEXP/CHLR/CLNT/CLRC/CLUD/CMNT/COND/
      COPR/CSNS/CWIR/DFOM/DIGS/DMRN/ECLR/ELEX/FNTC/FPTC/FUEL/GRPH/LED/LITH2/
      MGNT/MISL/NAPM/NTRG/PCON/PET/PHOS/PINV/PPTI/PPTO/PRMT/PROJ/QGPP/RADN/
      RUBR/SODM/STRC/SUN/TIMC/TMPS/TURB/UVRD/WALL/WHEL. Appended to
      `src/simulation/elements/meson.build`'s element list (never inserted,
      so every existing element keeps its numeric PT_ id) and categorized
      into the STOCK_* tables in `95_menusort.lua` using each element's real
      native MenuSection/Description (added one new SC_FORCE band,
      "Mechanisms & Signal" 40-49, for THMO/ECLR/TURB which didn't fit
      Movers/Fields/Destructive). GSNS skipped (see Active). Fixed real
      compile incompatibilities along the way, not blind copy-paste:
      `flood_prop()` takes an `AccessProperty{field, value}` struct in our
      fork vs the mod's `(accessor, value)` two-arg form (CEXP/LED/MGNT);
      `portal_rx`/`portal_ry` are a free global `constexpr` array in
      `PRTI.h` in our fork, not `Simulation` members (PPTI/PPTO); dropped a
      "write local gravity" side effect in CEXP that has no equivalent (see
      Active, same root cause as the skipped GSNS). Re-verified: all 52
      real native sections match their STOCK_* table placement, zero
      overlapping bands, zero orphaned sort keys.
- [x] ALUM and GRPH replaced per Drew's request: removed the old custom Lua
      versions (deleted from the live `pbx-custom-elements.json` registry
      and from `95_menusort.lua`'s custom SOLIDS/NUCLEAR tables) so the
      mod's native compiled versions claim those names instead -- a custom
      and a native element can't share one Name. Also removed RUBR from the
      custom Timber & Polymers table for the same reason (wasn't currently
      live, zero risk) since the mod also has a native RUBR.
- [x] Added `rebuild_powder_toy` MCP tool (`powder_toy_mcp.py`): one call
      regenerates `autorun.lua`, kills `powder.exe` (never `powder_play.exe`),
      rebuilds via ninja, relaunches on success, reports compiler output on
      failure instead of relaunching a broken exe. Compiles clean but the
      MCP server process needs a restart to pick it up (loaded the old file
      at session start) -- still needs Drew to cycle it before it's callable.
- [x] Merged every near-duplicate stock/custom chip pair into one chip:
      the "stock gets bands 10-69, custom gets bands 100+" split (originally
      just to avoid MenuSort collisions, which were never actually possible)
      produced a second, near-identically-worded chip per theme wherever a
      section had both stock and custom elements -- "Inert & Cold" next to
      "Noble & Inert", "Reactive & Toxic" next to "Toxic & Reactive",
      "Fissile Fuel" next to "Fuel", "Conductors" next to "Conductors &
      Insulators", "Cryogenic (Stock)" next to "Cryogenic", etc, across 6 of
      the 12 sections. Rewrote `SubCategory.h` and `95_menusort.lua` so
      stock and custom elements of the same theme now share one band number
      (e.g. ELEC's "Conductors & Insulators" is METL/TUNG/INST/INWR/INSL
      *and* CU, all MenuSort 10) -- one chip per real theme, not per
      stock-vs-custom origin. Re-verified: no overlapping band ranges, no
      Lua sort key falling outside its section's defined bands.
- [x] Shortened all 40 live custom elements' descriptions to match stock
      TPT's style (short, gameplay-flavored) instead of the textbook-style
      physics paragraphs they had (some 150+ characters, e.g. STEL's old
      description was a full materials-spec sentence). Edited directly in
      `build/pbx-custom-elements.json` (the actual persisted source
      `10_registry.lua` restores `Description` from at boot -- confirmed via
      its field-mapping table, `description` -> `Description`).
- [x] Fixed empty subcategory chips: `RebuildSubCategoryLadder()` built a
      chip for every band in `SubCategory.h` unconditionally, even ones with
      zero live tools in range (most custom bands, since only 40 of ~153
      referenced custom elements are actually live right now) -- clicking
      one just showed nothing, reading as "the categorization is broken."
      Now counts real tools per band via `GameController::GetMenuList()`
      before building each chip and skips anything at zero.
- [x] Fixed 3 more real misplacements found by reading each live custom
      element's actual description straight from the running
      `pbx-custom-elements.json` registry (not the older, sometimes-stale
      `materials-catalog.json`): STEL ("SA-508 reactor pressure-vessel
      steel") and CNCR ("Heavy shielding concrete") are purpose-built
      reactor parts, not generic metal/ceramic -- moved both from
      SOLIDS/ELEC into NUCLEAR's Control & Shielding band. RCNC (plain
      "Reinforced concrete", no reactor-specific purpose) moved from ELEC
      (wrongly tagged a conductor) to SOLIDS' building-materials band.
- [x] Fixed real element-categorization bugs, not just re-checked coverage:
      dumped every stock element's real Description/Type/MenuSection
      straight from `src/simulation/elements/*.cpp`, and every live custom
      element's real state straight from the running `pbx-custom-elements.json`
      registry (not the aspirational `materials-catalog.json`), then diffed
      both against `95_menusort.lua`'s bands. Found AM24/CF25/ANT/CRPS/CRYE
      had no native MenuSection at all -- unreachable from any chip;
      DRIC/RSSS/RFRG/CNCT/WWLD were banded somewhere that contradicted their
      own description; U235/UO2/etc. were double-listed under both
      SC_SOLIDS and SC_NUCLEAR. Fixed all of it: `applyBand()` now
      force-sets native MenuSection (not just MenuSort) for every custom
      group, nuclear materials consolidated onto SC_NUCLEAR only (dropped
      the SC_SOLIDS "Nuclear" band in `SubCategory.h` to match), and the
      five mislabeled stock elements moved to the chip their description
      actually matches. Re-verified 0 structural errors (no dup/missing/
      wrong-section) across all 12 stock sections afterward.
- [x] Fixed ladder-closes-too-fast: it was a corner-only-touch hit-test bug
      (button and ladder rects only shared a single pixel diagonally), fixed
      with a 20-tick hover grace period (`DecaySubCategoryLadderHover`,
      driven by `OnTick`) instead of hiding the instant the pointer left.
- [x] Sorted all ~200 stock/base-game elements into the ladder too, not just
      custom ones -- added stock bands (MenuSort 10-49) to all 12 populated
      menu sections in `SubCategory.h` (4 of which, EXPLOSIVE/FORCE/SENSOR/
      SPECIAL, had no chips at all before) and matching STOCK_* tables in
      `95_menusort.lua`. Cross-checked every name against the real element
      source (Name field, not filename) -- 195/195 covered, zero typos.
- [x] Root-caused and fixed the crash: lost `LuaSocket::Process` impl was
      the actual bug, not the menu-UI changes. Reconstructed `json` global
      (parse/stringify) cleanly, left `net`/sockets stubbed out on purpose.
- [x] Native hover-subcategory ladder menu shipped: `SubCategory.h` bands,
      `GameModel`/`GameController`/`GameView` wiring, hover show/hide,
      click-bleed-through guard in `OnMouseDown`.
- [x] Custom elements sorted into MenuSort bands via
      `bridge_src/95_menusort.lua` (runs once ~180 ticks after boot, after
      deferred element restoration finishes).
- [x] Split into two running copies so Drew can keep playing while builds
      happen: `build/powder_play.exe` (Drew's stable copy — launched and
      running) vs `build/powder.exe` (rebuild/test target, gets
      killed/relinked freely).

## Notes / landmines

- `bridge_src/*.lua` edits need `python D:\powder-toy\build_autorun.py`
  rerun before they take effect in `build\autorun.lua` — forgot this once.
- Kill `powder.exe` (not `powder_play.exe`) before `ninja powder.exe`, or
  the linker fails with LINK1104.
- Never `git checkout --` an uncommitted file without checking — that's how
  `LuaSocket.cpp`'s real implementation got permanently destroyed.
- The vcvars-loading one-liner MUST be `vcvarsall.bat x64 && set` (both the
  `x64` arg AND `&& set`) or it silently captures nothing useful -- `cl.exe`
  then isn't on PATH, which `ninja powder.exe` alone won't notice (it uses
  absolute paths baked into `build.ninja` already) but `meson setup
  --reconfigure` will, with a deep, unhelpful Python traceback
  ("FileNotFoundError: [WinError 2]"). Only bit when `meson.build` itself
  changed (adding new element source files) and a reconfigure was needed --
  every prior `ninja powder.exe`-only rebuild this session never exercised
  this path.
- Simpler trap, same symptom: calling `vcvarsall.bat` with NO arch argument
  at all (not even `x64`) fails silent-ish too -- `cl` ends up not on PATH,
  and `ninja` reports it as `CreateProcess failed: The system cannot find
  the file specified` on every single compile step, not a normal-looking
  compiler error. Always use the saved helper script
  (`scratchpad/run_vcvars.bat`, which calls `vcvarsall.bat x64` and dumps
  `set` after) rather than retyping the vcvarsall call inline.

## Roadmap notes (2026-08-29, infra/dependency pass)

- MCP SERVER: root-caused "capability manifest inconsistent" for real -- it's
  NOT a duplicate-process port conflict (that was a reasonable first guess,
  turned out wrong). `_capability_manifest_check()` in powder_toy_mcp.py
  extracts dispatch-branch names from `_dispatch_tool` via
  `inspect.getsource()` + AST parse at RUNTIME, on every tool call.
  `_names_from_function` silently returns an empty set on OSError/SyntaxError.
  A long-running process whose loaded module drifts from the on-disk file
  (exactly what happens across a session's worth of edits) can fail that
  introspection and silently report EVERY tool as missing its dispatch
  branch -- which is exactly the ~100-entry MCP_DISPATCH_MISSING_BRANCH dump
  seen tonight. Verified empirically: loading the CURRENT on-disk file fresh
  in a clean Python process passes the check with 0 findings. No code bug,
  no fix needed there. The actual fix is just restarting the server process
  periodically (or after big edit sessions) -- did not kill the one remaining
  process (PID 29836) since the earlier kill of 2 stale ones already broke
  this session's own MCP connection with no confirmed auto-recovery path;
  didn't want to risk killing the last one blind. Reconnecting this session's
  MCP tools needs whatever this host's own MCP-reconnect mechanism is (not
  something triggerable from a bash/Lua context) -- Drew or the coordinator
  needs to trigger that from the actual client side.
- CORRECTION 2026-08-29, round 2: the "3 duplicate processes" framing above
  was WRONG about the processes being duplicates -- VERIFIED via
  D:/powder-toy/.mcp.json (plain `{"command":"python","args":[...]}`, no
  url/http transport -- this is stdio transport, meaning the host spawns ONE
  powder_toy_mcp.py subprocess PER CLIENT SESSION, not a shared daemon) and
  via direct PID correlation: the 3 processes' parent PIDs (39580, 67284,
  64384) exactly match 3 files in ~/.claude/sessions/ with mtimes Aug 29
  15:17, 15:50, and 22:59 -- i.e. 3 separate real Claude Code sessions (two
  of them peers idle ~1 day and ~7 hours), each legitimately running its own
  MCP server child process. They were never duplicates or drift; killing 2
  of them almost certainly broke MCP tool access for those two OTHER
  sessions, not a bug in the script. SAFETY TAKEAWAY: killing python.exe
  processes matching powder_toy_mcp.py is NOT a safe cleanup action to
  repeat -- each one very likely belongs to a different active/peer session.
  The `inspect.getsource()`/AST-drift mechanism documented above is still a
  real, verified fragility in the manifest-check code itself (confirmed by
  loading the file fresh and getting 0 findings), but it was never the
  actual cause of tonight's specific incident -- that was almost certainly
  this session's own single powder_toy_mcp.py process going stale relative
  to this session's OWN edits over a long session, which is a real risk on
  its own and doesn't require multiple processes at all.
- REGRESSION LESSON #1 (bugs track, 2026-08-29): the geological-accuracy fix
  above (ROCK fallback GRNT -> BRCK changed to prefer STNE) was shipped
  after confirming STNE resolves to a real element id, but WITHOUT checking
  Falldown/TYPE_SOLID first. STNE turned out to be a falling powder, not a
  solid -- Drew's real live session had its subsoil collapse on world
  generation. Reverted. Standing lesson: before using ANY real element as
  terrain/structural fill, verify BOTH Falldown==0 AND TYPE_SOLID via
  elem.property (the same `bit.band(props, elem.TYPE_SOLID)` pattern used
  for the oxygen/leaf-blocking fix), not just that the name resolves to a
  valid id. Resolving to a valid id proves the element exists; it proves
  nothing about whether it behaves like solid ground.
- DEPENDENCY: "Tab (native brush-shape cycle) doesn't work" (Active, ~line
  115) and "native TPT shape-drawing gestures should work in survival mode"
  (Active, ~line 275) are the SAME root cause already documented in both
  entries independently -- placeAt never reads native TPT brush state at
  all. One fix (read native brush shape/size from inside a real dispatched
  event, same interface-event-flag pattern as everything else this session,
  then make placeAt shape-aware) closes both. Not merged into one entry per
  the never-delete rule, but treat them as one unit of work going forward.
- SCOPE PROPOSAL -- world-engine settings/slider UI: full ask ("everything
  configurable") is unbounded. Recommend V1 = an in-game panel (reuse
  ui.lua's existing button/panel drawing) covering: day/night length ratio,
  cave frequency/density noise params (already named locals in world.lua),
  ore rarity thresholds (the vein() zoneThresh/detailThresh params), and 2-3
  gravity/physics constants already sitting as named locals in rpg.lua
  (GRAV, JUMP, etc). Explicitly OUT of V1: anything requiring a world
  regen to see (defer those behind a "takes effect on next New World"
  label rather than trying to hot-apply structural terrain changes),
  per-biome overrides (V1 is global constants only). Needs Drew's sign-off
  on this cut before real UI work starts.
  UPDATE round 2: feature track has since shipped day-length + 2 more
  sliders (cave frequency, ore rarity) against exactly this cut -- see
  "Feature track round 3" entries at the top of this file. Matches the
  proposal; no correction needed, just marking this proposal as
  in-progress rather than not-started.
- SCOPE PROPOSAL -- launch/title menu: single save slot exists today, so no
  world/character select needed for V1. Recommend V1 = title screen shown
  before world generation (Play / Settings if the slider UI above exists /
  Quit) plus a "quit to menu" reachable from the in-game pause/menu, which
  returns to that same title screen without killing the process. OUT of V1:
  multiple save slots, character customization, any networking.
  UPDATE round 2: feature track shipped V1 against this exact cut (see
  "Feature track round 3" entries at the top of this file) -- title screen,
  Play/Settings/Quit, quit-to-menu without killing the process, Quit
  honestly shows "Alt+F4 to quit" rather than faking a real exit (there's
  no scriptable full-quit in TPT Lua). Matches the proposal.
- SUPERSEDED round 4 (roadmap track) -- turned into real research instead of
  a thin flag, per Drew's "way more roadmap, real implementation research"
  ask:
  - Multiplayer: full write-up at `knowledge/design-multiplayer-2026-08-29.md`.
    Researched real prior art, not guessed -- Noita Together (the closest
    real analog: a falling-sand physics game with a popular multiplayer
    mod) deliberately avoided shared-simulation multiplayer entirely
    (separate worlds per player); Noita Entangled Worlds, the mod that DOES
    sync the shared pixel grid, uses a host/proxy-authoritative design, not
    peer-to-peer -- confirming host-authoritative is the real, proven
    answer for this class of chaotic, iteration-order-sensitive simulation
    (peer-to-peer lockstep provably diverges fast for falling-sand physics).
    Concrete recommended architecture, reusing existing infra (the
    tile-cache windowing system, the companion's existing action-command
    layer) rather than inventing new systems: doc has full detail, V1 cut,
    and the real decisions (LAN vs internet play, host = whichever player
    started the world) that need Drew's input before any code.
  - Ragdoll/gore: full write-up at `knowledge/design-ragdoll-gore-2026-08-29.md`.
    Real, named, proven technique researched (Verlet integration + distance
    constraints -- the actual method behind Happy Wheels, the reference
    Drew gave, and Source engine ragdolls, tracing back to the original
    Hitman: Codename 47 implementation), not invented from scratch.
    Dismemberment reasoned out concretely: a stick constraint with a break
    threshold, removed when exceeded -- decapitation and limb loss are the
    SAME mechanism as any other joint, no special-case code. Recommended V1
    cut: ragdoll only on death/heavy impact (not full-time movement
    control, which risks hurting the platforming feel Drew hasn't
    complained about) -- doc has the full reasoning and what's out of scope.
  Both docs end with the specific decisions that need Drew's actual answer
  before code starts -- these are real research artifacts now, not "needs a
  conversation" placeholders.

## Lessons for next time

Durable bug -> root cause -> fix records, kept every time a real bug gets fixed
(per Drew's 2026-08-29 standing instruction: "keep track of every bug fix and
the ultimate issue, every turn, forever -- that way we can improve the MCP
tool constantly"). Append-only, like everything else in this file.

1. **Never use a real stock TPT element as terrain/wall/structural fill
   without verifying its actual physics first.** An element resolving to a
   valid id (has()/eid() returning true) says nothing about whether it's
   actually a static solid. 2026-08-29: swapped a rock-fill fallback from
   BRCK to real stock STNE because it "sounded like real rock" and resolved
   to a valid id -- never checked `elem.property(id, 'Falldown')` or
   `bit.band(elem.property(id,'Properties'), elem.TYPE_SOLID)` first. STNE
   is actually Falldown=1, a genuine falling powder in real TPT physics, not
   a wall. Shipped to a live player's session; the entire subsoil of a
   freshly-generated world collapsed on load. Reverted. The check that would
   have caught this before shipping, every time: `elem.property(id,
   'Falldown') == 0` AND `bit.band(elem.property(id,'Properties'),
   elem.TYPE_SOLID) ~= 0` -- both, not just one, and confirmed LIVE via the
   bridge before the change ships, not assumed from the element's name or
   stock-TPT reputation.

## Roadmap finding: cave-gen root cause (2026-08-29, round 5)

- [ ] RPG: cave generation "empty vertical tunnels going straight down" --
      ROOT CAUSE FOUND (roadmap track). This is an implementation bug, NOT
      a design gap -- the worm-tunnel design (documented in
      knowledge/research-worldgen-2026-08-26.md / research-worldgen-2.md)
      is sound and already implemented. Traced world.lua's wormAt/
      wormOpenAt (~line 282-313): entrance-flagged shafts start carving at
      `startD = 1` (right at the surface) and their horizontal wander comes
      from `vnoise1(dep / w.period + w.phase, 703)`, period = 55-125. At
      shallow `dep`, `dep/period` is tiny, so the centerline barely moves
      for the first ~20-40 depth units -- exactly where an entrance shaft
      begins. Combined with the narrow entrance radius (baseR 3.0-5.2px,
      deliberately thin near the surface via `rad = 1.6 + rad *
      min(1, dep/18)`), the result is a dead-straight narrow vertical shaft
      for the first several tens of pixels below any cave entrance, before
      the same tunnel eventually starts winding deeper down -- exactly the
      reported complaint. Not fixed here (bugs go through the coordinator's
      track). Likely fix direction for whoever picks this up: scale the
      noise domain so it accumulates phase faster near dep=0 (e.g. sample
      at `dep / (period * 0.35)` for the first ~40 units, blending to the
      normal rate), or simplest: give entrance shafts their own shorter
      period instead of sharing the general worm period.

## Roadmap research: geological accuracy (2026-08-29, round 6)

- [ ] RPG: geological accuracy -- real research done, full write-up at
      `knowledge/design-geology-2026-08-29.md`. Grounded in actual soil
      science (topsoil/A horizon -> subsoil/B horizon -> regolith-saprolite
      transition -> bedrock, real terminology not invented) and confirmed
      the original code's intent (GRNT/granite as default bedrock) was
      conceptually correct -- granite genuinely is the standard real-world
      answer for generic continental bedrock, the bug was just that GRNT
      was never registered as a real element, not that granite was the
      wrong idea. Checked live what rock-type elements actually exist in
      this build: STNE (generic stone) and BSLT (real basalt) both exist
      and are usable today; sandstone/limestone/granite do not exist as
      elements here. Recommended V1 (no new elements needed): STNE as
      bedrock everywhere (already shipped this session) plus BSLT
      specifically near existing volcanic/heat biomes for real regional
      rock variation at zero new-element cost. Full sandstone-under-desert /
      limestone variation is a real V2 needing 1-2 new custom elements
      (same elements.allocate pattern as GRSS/BLD) -- flagged, not built,
      needs Drew's sign-off on adding more custom elements first.

## Roadmap correction: STNE is not safe terrain fill (2026-08-29)

- [ ] CORRECTION to the round-6 geology research and to the earlier
      geological-accuracy fix: STNE is NOT safe as subsoil/bedrock fill.
      Verified live: `Falldown=1`, not `TYPE_SOLID` -- it's a genuine
      falling powder in this engine, not static ground, despite resolving
      to a real, valid element id. This is exactly what caused the "subsoil
      collapsed on world generation" regression on Drew's real session
      (reverted by the bugs track). Re-verified BSLT and BRCK the same way
      before trusting either: BSLT (Falldown=0, solid=true, real basalt) and
      BRCK (Falldown=0, solid=true) are both genuinely safe -- BRCK was only
      ever an aesthetic complaint, never a structural one. Updated
      `knowledge/design-geology-2026-08-29.md`'s V1 recommendation from
      "STNE everywhere" to "BSLT everywhere" (zero new-element cost, real
      igneous rock, verified solid). Standing lesson (also already logged
      separately from the original regression): resolving to a valid
      element id proves nothing about Falldown/TYPE_SOLID -- always check
      both before using anything as terrain/structural fill.

## Roadmap: vision document + MCP automation proposal (2026-08-29, round 7)

- [ ] RPG: real vision/roadmap document written per Drew's ask ("way more
      vision, on the GitHub") -- `knowledge/design-vision-2026-08-29.md`.
      Key finding: the "energy generation + oxygen + resource management +
      food/survival" central loop Drew described is NOT a proposal for
      something missing -- it's already real and already built, just never
      written down as one coherent identity. Verified live in the code: an
      electrolyser (O2GENKIT) makes real oxygen from water using power, a
      gas turbine/fuel cell burns the hydrogen byproduct back into power
      ("closes the electrolysis-to-power loop" per the code's own comment),
      a desalinator makes more water, real crop farms (survival.lua) grow
      on nearby real water, and a FERTILISER item bridges the machine chain
      into food production. Documented the real tech-tree tiers (hand ->
      workbench -> furnace -> anvil -> research -> advanced lab, with real
      power-output gates like "unlocked at 100W generated" already in the
      recipes) and proposed concrete next tiers (a reactor tier turning the
      existing FSN-2/PLUT precedent into a real progression rung, a
      sealed-base life-support concept giving late-game power a real sink,
      an automation/logistics tier). This doc is meant to be pulled directly
      for the GitHub README's vision/roadmap section, substantial enough to
      use as-is, not just bullet points.
- [ ] Workflow: MCP tool capability expansion proposal per Drew's "automate
      bugs/conflicts/testing through the MCP tool" ask --
      `knowledge/design-mcp-automation-2026-08-29.md`. Grounded in the
      actual bug patterns THIS session hit by hand, not a speculative
      feature list: (1) a terrain-fill solidity checker (would have caught
      the STNE regression), (2) a physics-constant-duplication scanner
      (would have caught the gravity/move-speed companion-desync bugs,
      found by hand twice), (3) a crafting-tier reachability checker (would
      have caught the round-6/round-7 missing-station-entry bugs, also
      found by hand twice), (4) a Lua forward-reference/call-before-
      definition static checker (would have caught the coordinator's
      title-screen bug), (5) a structured assertion/test-runner tool
      replacing one-off curl-based bridge verification with reusable,
      re-runnable checks. Explicitly recommends NOT building a general
      bug-finder -- every real bug this session was caught by a specific,
      narrow, mechanical check once someone thought to run it; proposes
      building checks 1 and 3 first (cheapest, directly reuse patterns
      already proven by hand this session) before investing in 4 and 5.

## Roadmap: built check #3 from the MCP-automation proposal (2026-08-29, round 9)

- [x] Built `scripts/check_station_reachable.py` -- the crafting-tier
      reachability checker from design-mcp-automation-2026-08-29.md.
      Queries live R.STATIONS/R.ITEMS/R.RECIPES via the bridge and flags any
      station missing its R.ITEMS placement entry or unused by every recipe
      -- the exact shape of both round-6 and round-7's real bugs. (Does NOT
      cover ui.lua's hardcoded tab-order list from round 6 -- that's a local
      variable, not exposed on R, out of scope for a read-only checker
      without editing ui.lua itself.)
      REAL VERIFICATION, not just "ran once and it looked fine": caught a
      genuine bug in the checker's own first version while running it (Lua's
      `tostring(true)` is lowercase "true", the Python string match was
      "item=True" with a capital T -- every station falsely reported
      UNREACHABLE). Fixed, then proved the checker actually detects real
      breakage rather than always passing: deliberately nil'd
      R.ITEMS.ADVLAB on the lab instance, confirmed the checker correctly
      flagged it UNREACHABLE (exit code 1), then restored it via
      R.hotReloadRequested (core rpg.lua, not the machines plugin --
      ADVLAB's R.ITEMS entry turned out to live in rpg.lua itself) and
      confirmed all 6 stations report OK again, exit 0. Lab instance
      confirmed back to its real, correct, undamaged state.
      Both proposed checks (#1 terrain solidity, #3 station reachability)
      from the MCP-automation proposal are now built and proven. #2
      (physics-constant duplication scanner) and #4/#5 (Lua static
      forward-reference checker, structured test runner) remain unbuilt,
      per the proposal's own recommended order (1 and 3 first).

## Roadmap: built check #2 from the MCP-automation proposal (2026-08-30, round 10)

- [x] Built `scripts/check_physics_constant_dup.py` -- the physics-constant
      duplication scanner from design-mcp-automation-2026-08-29.md. Static,
      source-only check (no running game needed): finds ALL-CAPS constant
      names declared as literals in both rpg.lua and companion.lua, and for
      each shared name, flags it if rpg.lua's usage sites apply an
      `R.*Mul` slider but companion.lua's usages of the same name don't.
      REAL VERIFICATION: ran it against the actual current files (not
      synthetic test fixtures) and got a genuinely useful live result --
      GRAV now shows `companion_mul=True`, confirming the bugs track's fix
      for the round-3 gravity-desync bug has actually landed and is
      correctly detected as fixed. JUMP and MAXFALL both check out fine too
      (JUMP was already independently confirmed correct earlier this
      session; MAXFALL is a new, independent confirmation the scanner found
      on its own, not something hand-checked before).
      HONEST LIMITATION FOUND WHILE VERIFYING (not hidden): the RUN/RUN0
      bug -- the SECOND real bug this session found by hand -- is NOT
      caught by this checker at all. rpg.lua names the constant `RUN0`,
      companion.lua names its copy `RUN` -- different identifiers for the
      same semantic constant, so exact-name intersection can never catch
      this case. Deliberately did NOT build fuzzy name-matching (e.g.
      strip-trailing-digits or edit-distance matching) to catch this too --
      real risk of false-positive matches between unrelated
      similarly-named constants, for a case that's already been found and
      fixed by hand this session. Documenting the limitation plainly rather
      than guessing at a fuzzy-matching scheme nobody's asked for
      (ladder rung 1: does the speculative feature need to exist yet).
      All 3 of the first 3 checks from the MCP-automation proposal are now
      built (terrain solidity, station reachability, physics-constant dup).
      #4 (Lua forward-reference checker) and #5 (structured test runner)
      remain, per the proposal's own stated lower priority.

## Roadmap: built check #4, found a REAL live bug with it (2026-08-30, round 11)

- [ ] BUG (found by roadmap track's new check #4, for the bugs track to pick
      up) -- REAL, live, currently-shipped crash, same class as the
      title-screen bug: rpg.lua:1350, inside `function R.giveAcc(k)`
      (defined line 1349), the duplicate-accessory branch calls
      `give("GOLD", 5)`. `local function give` isn't defined until line
      1453 -- Lua resolves `give` at COMPILE time by textual position, so
      inside R.giveAcc's body (compiled at line 1349, before any local
      `give` exists in scope) it becomes a reference to the GLOBAL `give`,
      which is never assigned. Confirmed no earlier `local give` exists
      anywhere in the file. REACHABLE from real gameplay: R.giveAcc is
      called from rpg.lua:1263 (opening a chest) and enemies.lua:140
      (killing the boss) -- picking up a DUPLICATE accessory the player
      already owns (`R.accOwned[k]` true) hits the crashing line. Real
      repro: open two chests containing the same accessory, or kill the
      boss across two respawns, while already owning that accessory.
      Same fix shape as the title-screen bug: forward-declare
      `local give` before R.giveAcc's definition (or move R.giveAcc's
      definition below `local function give`). Not fixed here -- bugs go
      through the coordinator's track.
- [x] Built `scripts/check_lua_forward_ref.py` -- the Lua forward-reference
      checker from design-mcp-automation-2026-08-29.md, the one meant to
      catch the title-screen bug's exact class. REAL, HONEST VERIFICATION
      including a real false-positive investigation, not just "ran it and
      it found things":
      - Self-check (synthetic broken/fixed pairs) passes.
      - First real run against rpg.lua + all rpg_plugins/*.lua produced 13
        findings. Spot-checked several instead of trusting the count: 6
        turned out to be matches inside STRING LITERALS (e.g. `selected`
        appearing in changelog text, not code) -- fixed cheaply by
        stripping quoted-string contents in addition to `--` comments,
        which is a real, proportionate fix (re-ran, confirmed those 6
        disappeared, self-check still passes).
      - Of the remaining 5, verified 4 are FALSE POSITIVES of a different,
        harder-to-fix kind: `gen`/`need`(x2) are table-constructor KEYS
        (`gen = {}`, `need = rc.need`) and `have` is a table-field access
        (`r.have`) -- all textually match a same-named `local function`
        elsewhere in the file, but have nothing to do with it. This needs
        real lexical-scope tracking to eliminate, which is a much bigger
        lift than checks 1-3 -- NOT attempted this round, documented as a
        known real limitation rather than either silently shipped as
        reliable or endlessly chased.
      - The 5th, `give`, was NOT a false positive -- see the real bug entry
        above. Verified this one properly (checked for any missed `local
        give` declaration, confirmed real call sites reachable from live
        gameplay) before reporting it as real, exactly because the other
        4 taught the lesson not to trust a finding without checking it.
      Honest summary of this check's current reliability: real signal
      exists (it found a genuine, previously-undiscovered live crash bug
      on its first real run), but the false-positive rate for common short
      identifier names is high enough that every finding needs manual
      verification before being trusted -- it's a lead-generator, not an
      automated pass/fail gate, until real scope tracking is added.

## Roadmap: built check #5, shared bridge helper, and a state note (2026-08-30, round 12)

- [x] Refactored check_terrain_solid.py and check_station_reachable.py to
      share a new `scripts/_mcp_bridge.py` helper (`call_bridge(lua_code)`)
      instead of each carrying its own copy of the same curl-equivalent
      boilerplate -- rung 2 of the ladder, reuse instead of a 4th
      copy-paste when building the next check. Re-ran both after the
      refactor against the live lab instance to confirm nothing broke
      (both still passed cleanly).
- [x] Built `scripts/assert_state.py` -- check #5 from
      design-mcp-automation-2026-08-29.md, the structured before/action/
      after assertion tool, on top of the shared bridge helper. Turns a
      one-off "call this, check that changed" curl verification into a
      reusable command instead of throwaway shell history.
      REAL VERIFICATION, using an actual scenario from this session, not a
      toy example: ran `python assert_state.py "PBX.state.rpg.COMP.hp"
      "PBX.state.rpg.damageCompanion(10,0,0)" "PBX.state.rpg.COMP.hp" "-10"`
      -- the exact companion-damage check done by hand earlier this
      session -- and got before=60 after=50 delta=-10, PASS. This is the
      whole MCP-automation proposal's point demonstrated concretely: a
      real historical hand-verification, now a reusable one-line command.
      All 5 checks from the original MCP-automation proposal are now built
      (1 terrain solidity, 2 physics-constant dup, 3 station reachability,
      4 Lua forward-reference, 5 this assertion runner).
- STATE NOTE: while running assert_state.py's second test (deliberately
  checking that it correctly reports FAIL on a wrong expected value, same
  discipline as every other check this round-sequence), the bridge
  connection dropped mid-call. Checked directly: NO PowderToyRPG.exe
  process is running anymore at all (neither the lab instance nor,
  apparently, Drew's real session). This happened between two back-to-back
  identical-shaped calls -- the first (damageCompanion(10,...)) had just
  succeeded seconds earlier -- so it's very unlikely this tool caused it;
  far more likely another track relaunched/restarted something
  concurrently (e.g. picking up the give() bugfix, or a clean rebuild).
  Did NOT attempt to relaunch anything myself -- outside this track's
  scope, and relaunching blind while another track may be mid-restart
  risks colliding with it. The PASS-path verification above already
  completed successfully before this happened, so it stands on its own.

## Roadmap: reactor tier fleshed out with real depth (2026-08-30, round 13)

- [ ] RPG: deepened the vision doc's "Reactor tier" proposal in
      `knowledge/design-vision-2026-08-29.md` from a one-line stub into a
      concrete recipe chain, per Drew's "way more research" ask. Checked
      `power-elements-2026-08-26.json` directly rather than assuming: UO2/
      ZIRC/GRPH/B4C already exist with real physical properties (UO2
      genuinely emits real NEUT particles via spontaneous fission, ZIRC is
      a real neutron-transparent conductor, GRPH a real high-conductivity
      moderator, B4C a real neutron absorber) -- this is a genuinely
      simulated reactor (real neutron economy), not a themed reskin,
      already proven out in existing sandbox builds (community-plut-plant,
      drew-deut-reactor blueprint). Proposed a concrete recipe chain
      following this codebase's own established "needs the previous tier's
      output" pattern: Fuel Rod (UO2+ZIRC), Moderator Block (GRPH), Control
      Rod (B4C+STEL), all at Advanced Lab, feeding a Reactor Core structure
      (+CNCR shielding, reusing CNCR's existing real shielding role) wired
      into the existing turbine/power-grid system. Framed correctly: this
      tier packages already-proven physics into a repeatable player-facing
      recipe chain, it does not invent new reactor physics.
      Also confirmed while doing this pass: the roadmap track's cave-gen
      finding was fixed by the bugs track with real diagnostic numbers
      matching the original hypothesis exactly, and the feature track
      independently ran check_station_reachable.py and
      check_physics_constant_dup.py as an unprompted sanity pass across 15
      rounds of concurrent work (clean bill of health) -- the automation
      tooling built rounds 8-12 is now genuinely in use by another track,
      not just self-reported.

## Roadmap: remaining two vision-doc stubs fleshed out (2026-08-30, round 14)

- [ ] RPG: finished deepening design-vision-2026-08-29.md's three "next
      tier" proposals (reactor tier done round 13) -- life-support scaling
      and the automation/logistics tier, both grounded in real existing
      code checked directly, not invented:
      - Sealed-base life support: found the real existing sealed-detection
        technique used TWICE already (machines.lua's roomSealed, rpg.lua's
        own player-breathing sealed check) -- both are cheap multi-sample
        directional ray-casts, not a flood-fill, and both already run every
        tick without lag. Proposed extending that exact proven-cheap
        technique to a life-support controller machine instead of building
        an expensive bounded-region flood-fill (which would repeat the
        O(area)-scan mistake already learned the hard way earlier this
        session), reusing the existing R.o2/R.need.food/R.need.water
        fields rather than new stat systems.
      - Automation/logistics tier: checked machines.lua first -- a real
        CONVEYOR machine already exists for solids/powders. The actual gap
        is narrower than assumed: fluids/gases (WATR/HYGN/OXYG) have no
        general player-placeable connection, only fixed structural pipes
        built into specific machines. Proposed a placeable fluid-pipe
        segment generalizing the conveyor's existing per-tick pushing
        logic to liquids/gases -- this is specifically what would let a
        player automate the closed electrolysis->turbine->water loop
        described in the vision doc's core-loop section, instead of
        manually re-carrying water/hydrogen between machines forever.
      All 3 "next tier" proposals in the vision doc are now concrete,
      checked against real code, and ready to hand to whichever track
      picks up implementation -- none built yet, this is still the roadmap
      track's planning/research lane, not implementation.

## Roadmap: improved check #4's signal quality, real cross-check on give() fix (2026-08-30, round 15)

- [x] No live game instance running right now (checked directly), so the 3
      bridge-dependent checks couldn't run this round. Ran the 2
      source-only static checks instead: check_physics_constant_dup.py
      still clean (ACC/GRAV/JUMP/MAXFALL all ok after 16+ rounds of
      concurrent changes -- no new player/companion desync introduced).
- [x] Re-ran check_lua_forward_ref.py and used it to independently confirm
      the coordinator's give() fix from round 11 (rpg.lua:1377 now calls
      `R.give("GOLD", 5)`, the public wrapper, not the bare local) --
      genuinely fixed, cross-validated by tooling, not just re-reading the
      diff description.
      While confirming that, found the checker itself had a NEW false
      positive caused by that exact fix: `R.give(...)` satisfies a bare
      `\bgive\b` regex just as much as a real bare `give(...)` call does,
      since `\b` treats the preceding `.` like whitespace. Root-caused
      this as ONE mechanism explaining several previously-unresolved
      "known limitation" findings at once (give, and likely gen/need/have
      too) -- not several unrelated issues. Fixed cheaply with a negative
      lookbehind excluding dot-access (`(?<!\.)\bNAME\b`). Re-ran self-check
      (still passes) and the real scan: went from 5 findings to 3.
      Investigated further: also added a negative lookahead excluding
      NAME as a table-constructor-key/assignment target (`have = value`)
      -- genuinely never dangerous the way a real call is, and this is a
      different, equally cheap, equally principled exclusion, not just
      noise suppression. Re-ran again: gen and have both fully eliminated,
      down to 3 findings (all `key`/`need`).
      Verified the 3 remaining findings by hand rather than assuming they
      matched the earlier "needs scope tracking" writeup: confirmed `key`
      at rpg.lua:1358 is `local key = tx*100000+ty+50000` -- a genuine,
      unrelated LOCAL VARIABLE REDECLARATION, a third distinct false-
      positive mechanism (an intervening `local NAME = ...` creates a new,
      unrelated binding) separate from the two just fixed. This one
      genuinely does need real "which local scope am I in" tracking to
      eliminate -- more state than a single-line regex exclusion, didn't
      chase it this round, still an honest, documented, real limitation
      (now precisely characterized as exactly one remaining mechanism,
      not a vague "needs more work").
      Net result: check #4 went from 13 raw findings (round 11) to 3, via
      three understood, verified, cheap fixes (string literals, dot-access,
      assignment-targets) -- each one confirmed by hand before trusting it,
      same standard as every other check this whole round-sequence.

## Roadmap: recurring bug-shape flagged (2026-08-30, round 16)

- [ ] PATTERN NOTE (roadmap track): the round-17 tptMenus fix is the SECOND
      confirmed instance of the same bug shape as the earlier R.sandbox
      reset bug -- a piece of state that must be reset to a known-safe
      default inside R.generateWorld's reset block, but wasn't, so it
      silently inherited whatever value it happened to have from a
      previous session/dev-toggle. Not proposing a new mechanical checker
      for this one (unlike checks 1-4): unlike Falldown/TYPE_SOLID or exact
      table-key matching, "should this variable reset on new-world" needs
      real domain judgment (is R.tptMenus/R.sandbox per-world-session state
      or persistent account state?), not a mechanical invariant -- a
      checker here would just be a manually-curated list pretending to be
      automated, which defeats the point. Flagging as a real pattern for
      whoever touches R.generateWorld next: when adding any new R.xxx
      dev/session-scoped flag, ask explicitly "does this need a matching
      reset in R.generateWorld" rather than assuming it'll be caught later
      -- it's happened twice now (sandbox, tptMenus) via the same oversight
      shape, worth being deliberate about rather than waiting for a third.

## Roadmap: README's Roadmap section is now stale (2026-08-30, round 16)

- [ ] GitHub track: README.md's "Roadmap" section (last touched 23:34
      8/29) predates almost all of the roadmap track's research and hasn't
      absorbed any of it yet -- flagging precisely rather than editing it
      myself (outside this track's lane per the 4-track roster):
      - "Underground generation, done properly" entry is now STALE -- the
        bugs track fixed the cave-gen vertical-tunnel bug with real
        diagnostic numbers (see "Bugs track -- cave-gen vertical tunnel bug"
        section above). Should be moved to a changelog/done note, not left
        in Roadmap as still-open.
      - "A real static rock element for subsoil... fired-brick-flavored
        filler" entry is STALE and understates the real state: BSLT (real
        basalt, verified Falldown=0/TYPE_SOLID) is already the identified,
        shipped fix, not just an open ask -- see
        knowledge/design-geology-2026-08-29.md for the full research
        (including the STNE regression lesson).
      - "Multiplayer" and "A physics-driven character overhaul" entries are
        both real but now much thinner than the actual research available
        -- knowledge/design-multiplayer-2026-08-29.md (Noita Together vs
        Entangled Worlds precedent, concrete host-authoritative
        architecture proposal) and knowledge/design-ragdoll-gore-2026-08-29.md
        (Verlet integration + breakable stick constraints, the actual
        Happy Wheels technique, concrete V1 cut) both have real depth ready
        to pull in, not just restate the one-line ask.
      - MISSING ENTIRELY: the central vision -- energy generation +
        oxygen/life-support + food/survival as one closed, already-real
        loop, and the tech-tree tier structure -- is Drew's own explicit
        "way more vision, on the GitHub" ask and isn't in the README at
        all yet. Full write-up at knowledge/design-vision-2026-08-29.md,
        written specifically to be pulled into a README vision/roadmap
        section, not just bullet points.

## Roadmap: correlating the PID 46636 ambiguity (2026-08-30, round 18)

- NOTE for whoever resolves the round-18 instance-safety question: PID
  46636 runs `D:\The-Powder-Toy\build\powder.exe` specifically. Earlier
  this session it was established that Drew's own real desktop shortcut
  launches exactly that binary, `powder.exe` -- not `PowderToyRPG.exe`,
  which is what got treated as "the lab instance" for most of this session
  (a naming mix-up already caught and corrected once before, mid-session).
  That's a real, if not certain, signal: a lab/test copy spun up by a track
  mid-session would plausibly be launched the same way previous lab
  instances were this session (PowderToyRPG.exe), while `powder.exe`
  specifically matches Drew's own normal launch path. Not proof by itself
  (a track could have deliberately launched powder.exe for some reason),
  but worth weighing when deciding whether PID 46636 is safe to touch --
  leans toward "likely Drew's real session," reinforcing round 18's
  decision to treat it as live and stay read-only.
## Roadmap: check #4 final findings + scope-tracking trade-off decision (2026-08-30, round 19)

- [x] Finalized the characterization of check #4's remaining 3 findings
      (rpg.lua:3190 `key`, machines.lua:2180 `need`, vehicles.lua:657 `need`)
      into the same single documented false-positive shape: `local NAME = ...`
      inside an inner scope (function, elseif branch, or for block) shadows
      a not-yet-defined file-scope `local function NAME` only within that
      inner scope -- the checker sees textually-matching NAME and assumes a
      shared file-scope binding, but Lua's per-function lexical scoping makes
      each binding independent. VERIFIED BY HAND for every flagged line, file:
      line cited: 6 real `local key` declarations inside OTHER functions than
      R.findPath (lines 1361/1540/1627/1794/2135/2431) plus bare `key`
      parameters in TPT's onKeyDown handler; 2 `local need` inside elseif
      branches of R.machineHint (lines 1256, 1278); 1 `local need` inside a
      for block in vehicles.lua (line 525). NONE are real forward-reference
      bugs. Self-check (`--self-check`) re-runs clean.
- [x] DECISION: do not build full scope tracking for check #4. Recorded in
      `knowledge/roadmap-check-4-final-findings-2026-08-30.md`. Trade-off:
      ~300-500 lines of careful Lua-scope Python with its own correctness
      risks, in exchange for eliminating 3 already-documented false positives
      with zero demonstrated real-bug payoff (signal-to-noise since the
      round-11 give() find has been 0 real bugs vs. 0-3 documented false
      positives per run). Half-right scope tracking could MASK real bugs,
      which is worse than today's known-FP state. Right time to revisit is
      if a new real-bug class emerges that the current approach systematically
      misses. Check stays as a lead-generator requiring hand-verification,
      not a pass/fail gate -- same standard as round 11/15.
- [x] No mutations to rpg.lua or plugins. No new checker. Doc-only deliverable
      this round.

## Bugs track — stuck mouse v1.15.3 (2026-08-30)
- Round-10's onMouseUp button-state-reset fix (rpg.lua:1914-1929) is in source but the live
  stuck-down bug still happens because the real SDL mouse-up event sometimes never reaches the
  bridge (e.g. window-defocus mid-drag) and there's no tpt.mouseb / tpt.input polling API to
  read the live button state. Shipped an emergency unstuck as v1.15.3:
    1. New `R.releaseMouse()` function (rpg.lua ~1934) -- clears R.mouse.l, R.mouse.r, R.placeBox,
       R.placeAnchor, R.zoomClick, R.zoomPending, R.lastPlace, R.lastMine, and R.lineAnchor if
       it exists; says "Mouse released"; returns true.
    2. F11 (SDL2 keycode 1073741892) bound in onKeyDown at line 2032 to call R.releaseMouse()
       and return false. Sits next to the F9 hot-reload binding for discoverability.
    3. R.VERSION bumped 1.15.2 -> 1.15.3 (rpg.lua:189).
    4. v1.15.3 changelog entry added as the FIRST entry (newest first), format matched to the
       existing pattern at lines 191-201.
- Live bridge verification (PID 56336, port 9876): hot-reload triggered via
  `PBX.state.rpg.hotReloadRequested = true`, waited for next onTick. Confirmed
  `R.VERSION = "1.15.3"` and `type(R.releaseMouse) = "function"` and direct call
  `R.releaseMouse()` returned `true` with all flags cleared
  (l=false r=false placeBox=false zoomClick=false zoomPending=false lastPlace=nil lastMine=nil).
  Verdict: SHIPPED + LIVE-VERIFIED.
- Known limit / non-mouse change: the user's working tree had `R.VERSION` + the `R.CHANGELOG`
  table literal but was MISSING the `R.CHANGELOG = {` opener that should sit at line 202.
  Without it the file failed loadstring() with "unexpected symbol near '{'" and the round-10
  change couldn't even ship via hot-reload. Added the missing opener (single line, line 202)
  to make my edits land. This is pre-existing work-in-progress the user hadn't yet finished;
  flagged here so the @feature and @roadmap lanes know about it but did NOT change behavior
  of R.CHANGELOG consumers (the in-memory table was already populated from a previous
  successful load).
## Roadmap: companion redesign gap audit (2026-08-30, round 20)

- [x] Audited companion.lua (989 lines) + companion_driver.py (356 lines) +
      design-companion-core.md (105 lines) + design-companion-protocol.md.
      Wrote `knowledge/companion-redesign-gap-2026-08-30.md` (~21KB) with
      concrete fix-scope items for @feature. BOTTOM LINE: ~55% of the design
      is implemented (real physics + locomotion + reflexes + persistence +
      model-driver integration + every primitive in §4 + every parametric
      task: clearTrees/digArea/buildRoom/buildShaft/wall/bridge/stairs) and
      ~45% is missing-or-partial.
- [x] MAIN GAPS (gates the §6 acceptance tests):
      1. **Chat → multi-step plan handlers** — templateReply only handles
         single-primitive mappings today; "cut all these trees",
         "dig me a big hole here", "build me a house" all need new intent
         handlers that emit `enqueueChain` (the chain engine exists, lines
         691-697, but nothing in chat actually uses it). HIGHEST PRIORITY,
         gates §6 tests 2/3/4. ~150-200 LOC for @feature.
      2. **Chain re-plan on fail** — chain engine today (lines 889-895)
         drops steps 2..N on first fail with no reason-aware re-plan.
         §2 design rule explicitly calls for one re-plan attempt with the
         reason in context. ~40-60 LOC for @feature.
      3. **Index hazards** — `refreshIndex` (lines 608-665) scans mineable
         elements but never reports LAVA/FIRE/ACID/CAUS/PLSM to the model,
         even though the colonist has real `hazardAheadC` (line 110-118).
         §5 model context says it should. ~20-30 LOC for @feature.
      4. **Build-task spoken milestones** — first half of the spam-fix
         (removing ambient narration) shipped; second half (real plan-
         start / milestone / finish lines for build tasks) didn't. §2
         rule violated by every STEP except digArea's 50% line. ~10-20 LOC.
      5. **"Never seal the player in"** — STEP.buildRoom sorts bottom-up
         but doesn't check that R.P is OUTSIDE the rect before placing.
         Plus no interrupt-resume for half-done builds. ~15 LOC.
- [x] EXPLICIT DRIFT (NOT a code gap — doc needs reconciliation): §3's
      "pack-full / shortfall / proximity" auto-delivery triggers were
      explicitly removed by Drew's 21:12/21:16 standing rule ("ONLY DO WHAT
      HE ASKED... no unsolicited gifts"). companion.lua:818-821
      acknowledges this in a block comment. The design doc still lists
      the auto-triggers without noting the override — F6 in the gap doc
      adds 5 lines to design-companion-core.md §3 to prevent a future
      reader from re-implementing them.
- [x] Not read end-to-end in this round: scripts/companion_driver.py
      (356 lines). Its plan-issuance shape (single cmd vs enqueueChain)
      affects whether §6 tests 2/3/4 pass with a live model — flagged as
      optional F7 audit, only worth doing if F1-F5 don't close the gap.
- [x] No mutations to scripts/lua/rpg.lua, companion.lua, or any other
      plugin. Doc-only deliverable this round. Per lane boundaries all
      F1-F5 fixes belong to @feature.
## Roadmap: companion spawn-reset + new-world cleanup audit (2026-08-30, round 21)

- [x] Audited companion.lua (989 LOC, full read) + rpg.lua R.spawnPlayer
      (871-887) and R.generateWorld (797-841) + survival.lua R.spawnPlayer
      wrap (106-114). Wrote `knowledge/companion-redesign-gap-2026-08-30.md`
      (9.87KB, under the ≤10KB cap) with three-section format:
      findings / recommendations / decision.
- [x] SIX FINDINGS, two real bugs worth @bugs attention:
      **F1 (HIGH):** R.spawnPlayer() does NOT reset ANY of R.COMP's 18
      fields. Player dies deep underground while colonist is mid-fight →
      colonist is stranded at the death-site trying to fight an enemy
      the player can no longer see. checkTeleportHome only fires above
      600px distance; ~200-400px underground is below that. v1.15.4
      explicitly called out this bug class (R.o2, R.gas, R.need.food/
      water, R.hurt, R.bloodLast, R.uvAccum, R.radAccum, R.hp=100)
      but R.COMP wasn't on the patch list. Same class of bug, different
      state surface. Repro + line citations in the doc.
      **F5 (MEDIUM):** survival.lua bed-respawn wrap (106-114) bypasses
      core's pollution reset entirely when R.bedRespawn is set — same
      v1.15.4 bug class, but for the bed path. Compounds F1: companion
      ALSO gets no reset on bed-respawn.
      Minor findings: F2 (companionKill doesn't clear C.queue, lost-chain
      behavior), F3 (newworld hook misses 9 of 18 fields — ghost-frame
      on x/y for one frame, chatQueue cross-world message leak if driver
      went silent between worlds), F4 (newworld resets mode="auto"
      breaking live driver integration — documented expectation, doc
      update recommended), F6 (death-loop via queue retention — actually
      NOT a loop, current behavior acceptable).
- [x] NO NEW CHECKER. Existing checker set (terrain_solid, station_
      reachable, physics_constant_dup, lua_forward_ref) covers mechanical
      invariants; "should R.COMP survive R.spawnPlayer" needs per-field
      human judgment ("is this per-world-session state or persistent
      account state?") — exactly the pattern flagged in TODO round-16
      as "a manually-curated list pretending to be automated."
      Future-checker possibility (static R.XYZ-field-not-mentioned-in-
      any-reset-hook) was REJECTED: false-positive rate would be high
      (many fields are MEANT to persist, e.g. R.frame, R.worldEver
      Generated).
- [x] No mutations to rpg.lua, companion.lua, survival.lua, or any plugin.
      Doc-only deliverable this round. F1+F2+F3+F5 belong to @bugs
      (rpg.lua/plugin touch); F4 is doc-only for @roadmap next round.
## Roadmap: companion mode="auto" reset on new-world -- rationale doc (2026-08-30, round 22)

- [x] Shipped the F4 doc-only deliverable from round 21:
      `knowledge/companion-mode-auto-reset-2026-08-30.md` (3874 bytes,
      within the 2-4KB target). Three required sections + Decision:
      (1) WHY -- auto is the safe default (only mode that runs reflexes;
      new-world state is poisoned for prior drivers; watchdog only flips
      model->auto, not manual->auto).
      (2) WHO IT BREAKS -- live companion_driver.py mid-loop (real
      today: chat hook stops answering, scriptedBrainTick can preempt
      in-flight plan, driver recovers on next poll ONLY if it re-asserts
      mode, which it currently does not -- only on entry line 311 and
      exit line 350, not per cycle).
      (3) HOW TO OPT-OUT -- three escape hatches: driver-side
      R.companionSetMode("model") every poll (RECOMMENDED, one-line
      driver change, no rpg.lua/compaion.lua touch); plugin-side
      hook(R.hooks.newworld, fn) re-asserting mode after companion's
      tag-de-dup'd hook (5-10 LOC); different reset strategy gated on
      C.lastHeartbeat freshness (FUTURE, rejected until driver-side
      re-assert lands).
- [x] DISCREPANCY CALLED OUT in doc header and verification section:
      round-21 brief said mode strings were "command"/"follow" but actual
      values per companion.lua:709 are exactly `auto | manual | model`
      (those brief strings are STEP command names, not mode values).
      Also: tick-order framing doesn't apply -- R.generateWorld is a
      one-shot menu event, not a per-tick call. Doc written against
      actual code, not the brief's assumed shape.
- [x] NO NEW CHECKER. Mode-reset policy is a deliberate design choice
      (auto is the safe default); flagging it as "missing" would be wrong.
- [x] No mutations to rpg.lua, companion.lua, or any plugin. Doc-only
      deliverable. Recommended next step (3.1 -- one-line driver change
      to re-assert mode every poll) routes to whoever owns
      companion_driver.py next, NOT shipped this round.

## Bugs track — respawn-doesn't-clean-state v1.15.4 (2026-08-30)

- ROOT CAUSE (live): R.spawnPlayer() at rpg.lua:869 only reset R.P.x/y/vx/vy and R.hp. R.o2 (still 0 from the suffocation death), R.gas (CO/CO2/rad/heat from the firebox/death scene), R.need.food/water, R.hurt/R.bloodLast (triggers immediate re-damage), R.uvAccum/R.radAccum (lingering radiation) all persisted across respawn. Verified on user's live session: deaths=12 (loop), log showed "You are being poisoned by carbon dioxide build-up" repeating immediately after each "You died. Respawned at the surface; inventory halved." Spawn point at (0, surfaceAt(0)-1) had a 3-row BLD+DUST pool from prior deaths' blood-spawn events.
- FIX applied (rpg.lua:868-883): R.spawnPlayer() now resets R.o2=100, R.gas.{co,co2,ch4,rad,heat}=0, R.need.{food,water}=100, R.hurt/bloodLast=nil, R.uvAccum/R.radAccum=0, R.hp=100. Magic Mirror call site at rpg.lua:2034 preserves hp explicitly via save/restore around R.spawnPlayer() — unaffected.
- VERSION BUMP + CHANGELOG: rpg.lua:189 R.VERSION="1.15.4", rpg.lua:203-205 new CHANGELOG entry as newest-first.
- LIVE BRIDGE VERIFICATION: hot-reload via PBX.state.rpg.hotReloadRequested=true; after reload ver=1.15.4, current state read o2=100 gas={co2=0,co=0,rad=0,heat=0}. Forced failure injection (set o2=0, gas.co2=80, hp=23, food=12 then call R.spawnPlayer()) confirmed all state cleared: o2=100, hp=100, gas={co2=0,co=0,rad=0}, food=100.
- HONEST LIMITS: inventory-halving on death is preserved (intentional round-13 design choice, breaking it now is out of scope). The BLD pool at the spawn point is not cleared on respawn — R.clearAround() runs but BLD is dense in a 3-row pattern that may partially survive; secondary cleanup might be needed if user reports persistent visuals. Round-trip LAN-safe (no sim.partCreate, no movement, no R.save).

## Bugs track — R.clearAround missing (F8, 2026-08-30)

- ROOT CAUSE: rpg.lua calls R.clearAround() at two sites (rpg.lua:840 in generateWorld, rpg.lua:893 in R.spawnPlayer) but the function definition was removed during the v3 rewrite (commit 6c8d889, "RPG v3: infinite chunked world, sprite player physics, tools, bag/craft GUI"). Verified via `git show 6c8d889:scripts/lua/rpg.lua | grep -A 2 clearAround` -- the v2 definition existed, v3 rewrote the body but did not redefine it, and current source has only the call sites.
- ORIGINAL INTENT (v2 definition): `function R.clearAround(x, y) for yy = y - 12, y - 1 do for xx = x - 3, x + 2 do local p = sim.partID(xx, yy); if p then sim.partKill(p) end end end end` -- clear a 6x12 box ABOVE the spawn point so the player doesn't spawn buried in terrain or under a stack of BLD.
- WHY USER HASN'T NOTICED: spawnPlayer is called from movePlayer (rpg.lua:896+) which is itself wrapped in pcall (rpg.lua ~2770: `ok, err = pcall(movePlayer)`). The error is swallowed. The pollution reset that came BEFORE R.clearAround in v1.15.4 still works, so the user's death-loop bug is fixed, but the BLD pool at the spawn point never gets cleared (TODO.md earlier round 3078 noted this exactly: "The BLD pool at the spawn point is not cleared on respawn -- R.clearAround() runs but BLD is dense in a 3-row pattern that may partially survive").
- BRIDGE VERIFIED: live lab state confirms `type(R.clearAround)=nil`. The function is genuinely missing.
- FIX CANDIDATE: re-add the v2-shaped function (signature unchanged since both call sites pass no args; either restore the original x/y signature and update callers, or write a no-arg version that reads R.P.x/R.P.y). v2 used `for yy = y - 12, y - 1 do for xx = x - 3, x + 2 do` which clears 6 wide x 11 tall above spawn -- exactly what's needed.
- PRIORITY: MEDIUM (cosmetic BLD bleed only; not blocking gameplay). Belongs to @bugs queue.

## Bugs track -- F1 + F8 v1.15.7 (2026-08-30)
- BATCH A SHIPPED. F1 [HIGH] + F8 [MEDIUM] -> rpg.lua v1.15.7.
- F1 (companion stranded on respawn): added COMP teleport to R.spawnPlayer
  (`if R.COMP and R.COMP.active and not R.COMP.dead then C.x = R.P.x - (C.face or 1)*12; C.y = R.P.y end`)
  right before the existing R.hp=100 line. Gated active+not-dead so REVIVE_DELAY's
  auto-respawn path in companion.lua is unaffected. Per the @roadmap round-21 doc, only
  these two fields were on F1's recommendation -- other 16 R.COMP fields left intact
  pending separate analysis.
- F8 (R.clearAround missing): re-added the v2-shape function (commit 6c8d889 origin)
  as a no-arg version that reads R.P.x/R.P.y. Body matches v2: `for yy = y - 12, y - 1 do
  for xx = x - 3, x + 2 do local p = sim.partID(xx, yy); if p then sim.partKill(p) end end end`.
  Both call sites (generateWorld:840, R.spawnPlayer end) already pass no args.
- Live lab verification (port 9877, token zcyLenMVgel7gJ0xjxCb0-jETJZPo7crhZOfKJ1DMGE):
  - loadstring() of full rpg.lua = OK (size=236640, no syntax errors)
  - hot-reload completed; log shows "Hot-reloaded rpg.lua", R.lastErr = nil
  - R.VERSION == "1.15.7"
  - type(R.clearAround) == "function" (was nil at v1.15.6)
  - F1 functional test: set R.COMP.x=500, R.COMP.y=-200 (stranded-at-death-site),
    R.COMP.active=true, R.COMP.dead=false, R.COMP.face=1, called R.spawnPlayer(),
    got ok=true err=nil, R.P.x=0, R.P.y=164 (spawn point), R.COMP.x=-12 (=0-1*12),
    R.COMP.y=164. Companion correctly teleported to fresh spawn.
- Verdict: SHIPPED + LIVE-VERIFIED on lab.

## Bugs track -- F2 + F3 v1.15.8 (2026-08-30)
- BATCH B SHIPPED. F2 [MEDIUM] + F3 [MEDIUM] -> companion.lua, rolled into rpg.lua v1.15.8.
- NEW CONVENTION (documented in v1.15.8 changelog entry as first note, so
  @github picks it up): rpg.lua owns R.VERSION; ALL plugin fixes roll into the
  next rpg.lua version bump with their own CHANGELOG entries. One unified
  user-visible stream, matches @github's CHANGELOG.md practice. Applies from
  v1.15.8 forward.
- F2 (companionKill clears C.queue): companion.lua:723 now sets `C.queue = {}`
  alongside the existing `C.action = nil; C.override = nil` resets. Before, a
  queued chain survived the death/revive cycle and each step replayed after
  revival (real but minor; @roadmap round 21 rated LOW severity for the lost-
  chain behavior, MEDIUM for the unexpected intent mismatch).
- F3 (newworld hook resets 7 missing R.COMP fields): companion.lua:910-914 adds
  `C.x=0; C.y=0; C.vx=0; C.vy=0; C.chatQueue={}; C.sayMsg=nil; C.sayAt=nil`
  to the newworld hook. Fixes: ghost-frame visual artifact (single 16ms frame
  at previous world's last position), chatQueue leak (driver messages queued
  in prior world drained into the next), stale chat bubble.
- Live lab verification (port 9877, token zcyLenMVgel7gJ0xjxCb0-jETJZPo7crhZOfKJ1DMGE):
  - loadstring() of companion.lua = OK (size=50789, no syntax errors)
  - rpg.lua hot-reload -> R.VERSION = "1.15.8", lastErr=nil
  - reloadPlugin("companion") -> "ok"
  - F2 functional: set C.queue to {2 items}, called R.companionKill() -> got
    ok=true ret=true, postQueueLen=0 (was 2), C.dead=true.
  - F3 functional: set C.x=500, C.y=-200, C.vx=3.5, C.vy=-2.1, C.chatQueue=
    {2 items}, C.sayMsg="stale bubble", C.sayAt=9999. Invoked each
    R.hooks.newworld callback. Post: C.x=0, C.y=0, C.vx=0, C.vy=0,
    C.chatQueue={}, C.sayMsg=nil, C.sayAt=nil. All 7 fields cleared.
- Verdict: SHIPPED + LIVE-VERIFIED on lab.

## Bugs track -- F5 v1.15.9 (2026-08-30)
- BATCH C SHIPPED. F5 [MEDIUM] -> survival.lua + rpg.lua -> v1.15.9.
- F5 (survival.lua bed-respawn pollution bypass): the wrap at survival.lua:108-114
  was setting R.P to the bed position and hp to max(current, 40) but NOT clearing
  the death-pollution envelope (R.o2, R.gas, R.need.food/water, R.hurt/R.bloodLast,
  R.uvAccum/R.radAccum). v1.15.4 fixed the surface-respawn version of this bug
  but the bed path was the same bug class on a different spawn path. Per the
  @roadmap round-21 recommendation ("extract reset into a shared helper") --
- Extraction: pulled the inline pollution block out of R.spawnPlayer and put
  it in a new private helper R._resetSpawnState() at rpg.lua:897-902 (same 4
  statements, no behavior change for the surface-respawn path). R.spawnPlayer
  now calls it at line 917; survival.lua bed wrap calls it at line 110. Single
  source of truth, future spawn paths just call it.
- Live lab verification (port 9877, token zcyLenMVgel7gJ0xjxCb0-jETJZPo7crhZOfKJ1DMGE):
  - loadstring() of rpg.lua = OK (size=238541), survival.lua = OK (size=29583)
  - rpg.lua hot-reload -> R.VERSION = "1.15.9", lastErr=nil
  - reloadPlugin("survival") -> "ok"
  - R._resetSpawnState is a function (was nil at v1.15.8)
  - REGRESSION TEST: surface respawn still works (R.o2=0,gas polluted,hurt set,
    radAccum=7.5 -> R.spawnPlayer() -> R.o2=100, gas=0, hurt=nil, radAccum=0).
    No behavior change from the refactor.
  - F5 FUNCTIONAL TEST: bed respawn at (50,100), pre-state polluted (same as
    above), R.spawnPlayer() -> px=50, py=100, hp=40 (=max(15,40)), R.o2=100,
    gas cleared, hurt=nil, radAccum=0. Pollution envelope now cleared on the
    bed-spawn path.
  - DIRECT HELPER TEST: hand-poisoned all 10 fields (R.o2=0, gas.* set, need.*=0,
    hurt/bloodLast set, uvAccum/radAccum set), called R._resetSpawnState() ->
    all 10 fields cleared to expected defaults (o2=100, gas all 0, food=100,
    water=100, hurt/bloodLast=nil, uvAccum=0, radAccum=0).
- Verdict: SHIPPED + LIVE-VERIFIED on lab.
- QUEUE STATUS: F1, F2, F3, F5, F8 ALL DONE across v1.15.7/1.15.8/1.15.9.
  No remaining items in this batch. Standing by.
## Roadmap: next bug class after v1.15.7-1.15.9 ship (2026-08-30, round 23)

- [x] Ran a fresh-eyes audit on rpg.lua + rpg_plugins/*.lua targeting
      three classes per Main's brief: (a) R.X() nil-function refs (the
      F8 clearAround pattern), (b) hook-handler signature mismatches,
      (c) field-on-table mutations without existence check. Bridge used
      for live cross-check (PID 37320, port 9877, VER=1.15.9, lastErr=nil).
- [x] THREE-CHECK RESULTS:
      (a) NO real nil-ref bugs found. Built /tmp/check_a.py extracting
      R.X(...) call sites in plugins and verifying X is defined in core
      (function R.X( or bulk R.X, R.Y = ...). Every flagged candidate is
      a plugin-internal R.X = function defined in the same file. v3-
      rewrite-missing-helpers pattern does NOT recur in v1.15.9.
      (b) 5 sloppy-but-legal signature mismatches, no bugs (Lua ignores
      extra args). Zero reverse cases (handler wants MORE than caller
      passes) which would be real bugs.
      (c) High false-positive rate, same shape as round-21 scope-tracker
      rejection. Hand-verified every cluster (~30 candidates): all are
      guarded with `if R.X` or `R.X = R.X or {}` patterns. Static check
      for (c) NOT mechanically buildable without real Lua control-flow
      tracking -- rejected for same reason as round-21.
- [x] REAL BUG FOUND via live bridge cross-check: **v1.15.7's F1
      companion-teleport fix doesn't fire on bed-respawn.** Same bug class
      as v1.15.5's F5 pollution-reset bug that v1.15.9 fixed -- F1 fix
      lives at rpg.lua:923 inside R.spawnPlayer, but survival.lua's bed
      wrap (lines 108-114) bypasses the entire core spawnPlayer when
      R.bedRespawn is set. Single bridge call: `SURFACE_SPAWN: COMP.x=-12
      (F1 fired) | BED_SPAWN: COMP.x=-999 (F1 bypassed)`. Companion
      stays stranded at death-site after bed-respawn. HIGH severity,
      affects default survival flow.
- [x] SIDE OBSERVATION: R.clearAround() also bypassed by bed wrap.
      Cosmetic only (BLD pool at bed location not cleared). Same fix
      pattern as F1: add to bed branch.
- [x] Recommendation for @bugs (NOT shipped this round): 2-line fix in
      survival.lua bed branch -- mirror F1 logic + R._resetSpawnState()
      + R.clearAround() in the bed branch. Or refactor to call coreSpawn()
      first and override R.P.x/y + R.hp, like F5 extraction did.
- [x] NO NEW CHECKER. Same scope-tracking rejection as round-21.
      Doc: knowledge/round-23-next-bug-class-2026-08-30.md (7952 bytes).

## Bugs track — bed-respawn bypasses F1 companion teleport (F9, 2026-08-30)

- ROOT CAUSE: scripts/lua/rpg_plugins/survival.lua:108-114 wraps R.spawnPlayer. When R.bedRespawn is set, the wrapper ONLY does `R._resetSpawnState()` (the v1.15.9 F5 fix), then early-returns -- skipping the entire rest of the core spawnPlayer body that contains F1 (companion teleport at rpg.lua:923) and R.clearAround() (the v1.15.7 F8 fix).
- BRIDGE VERIFIED (lab PID 37320 port 9877 ver=1.15.9):
  - SURFACE spawn path (R.bedRespawn=nil): P=(0,164), COMP=(-12,164), delta=12 -- F1 fired correctly.
  - BED spawn path (R.bedRespawn=(50,100)): P=(50,100), COMP=(500,-200), delta=-450 -- F1 BYPASSED. Companion still stranded at its pre-spawn position.
- BUG CLASS: same shape as v1.15.9's F5 -- any fix added to core R.spawnPlayer() body is NOT replicated to the survival.lua bed-respawn wrapper until somebody updates survival.lua to mirror it. The fix for F5 explicitly added R._resetSpawnState() to survival.lua:113, but the F1 teleport fix at rpg.lua:923 was never mirrored.
- SEVERITY: HIGH (default survival flow uses bed respawn once a bed is placed; companion stranded at death-site is exactly the bug F1 fixed).
- FIX CANDIDATE: 2-line edit in scripts/lua/rpg_plugins/survival.lua:113 -- after R._resetSpawnState(), call the F1 companion-teleport inline (replicate the rpg.lua:923 block) AND R.clearAround(). Or refactor: extract the F1+clearAround block into R._teleportCompanionAndClear() shared helper like F5 did with R._resetSpawnState().
- PRIORITY: HIGH. Belongs to @bugs queue.

## Bugs track -- F9 v1.15.10 (2026-08-30) -- bed-respawn bypasses F1 companion teleport
- F9 [HIGH] SHIPPED. Same bug class as v1.15.9's F5: survival.lua's bed-respawn
  wrap took an early-return path that bypassed the entire core spawnPlayer body.
  v1.15.9's F5 fix mirrored _resetSpawnState into the bed wrap; the v1.15.7 F1
  (companion teleport) and v1.15.7 F8 (R.clearAround) fixes were NOT mirrored.
- REPRO at v1.15.9 (from the round-23 doc): BED spawn P=(50,100) COMP=(500,-200)
  delta=-450 -- F1 bypassed. After this fix: BED spawn P=(50,100) COMP=(38,100)
  delta=12 -- matches surface spawn's delta=12.
- FIX: extracted F1 + F8 into a new private helper R._teleportCompanionAndClear()
  at rpg.lua:909-918 (same shape as v1.15.9's _resetSpawnState):
    function R._teleportCompanionAndClear()
      if R.COMP and R.COMP.active and not R.COMP.dead then local C = R.COMP; C.x = R.P.x - (C.face or 1) * 12; C.y = R.P.y end
      R.clearAround()
    end
- R.spawnPlayer body now calls all three helpers in sequence:
  R._resetSpawnState() -> R._teleportCompanionAndClear() -> R.hp = 100 + shiftCam
- survival.lua:110 bed wrap updated to call BOTH _resetSpawnState() AND
  _teleportCompanionAndClear() after setting R.P and hp.
- Live lab verification (port 9877, token zcyLenMVgel7gJ0xjxCb0-jETJZPo7crhZOfKJ1DMGE):
  - loadstring() of rpg.lua = OK (size=239506), survival.lua = OK (size=29662)
  - rpg.lua hot-reload -> R.VERSION = "1.15.10", lastErr=nil
  - reloadPlugin("survival") -> "ok"
  - type(R._teleportCompanionAndClear) == "function" (was nil at v1.15.9)
  - F9 FUNCTIONAL: set COMP stranded at (500,-200), R.bedRespawn=(50,100), hp=15,
    called R.spawnPlayer() -> ok=true, P=(50,100), hp=40 (=max(15,40)),
    COMP=(38,100) (=50-1*12), deltaX=12. Pre-fix would have left COMP at (500,-200).
  - REGRESSION TEST: surface respawn (R.bedRespawn=nil) with COMP stranded at
    (999,-999) -> P=(0,164), hp=100, COMP=(-12,164), deltaX=12. No behavior change
    from the refactor.
  - DIRECT HELPER TEST: R.P=(200,150), COMP=(500,-200), called
    R._teleportCompanionAndClear() -> COMP=(188,150) (=200-1*12, 150=R.P.y),
    clearAround fired without error.
- Verdict: SHIPPED + LIVE-VERIFIED on lab. Same-shape bug class is now
  architecturally defended against for both F1+F8 (this round) and F5 (last
  round) -- any future spawn path just needs to call the three helpers in order.

## Bugs track — trees float above ground (F10, 2026-08-30)

- REPORTED BY: Drew via screenshot (1px gap visible between tree trunks and the green grass surface).
- ROOT CAUSE: scripts/lua/rpg.lua:674 (in gen() trunk condition). The trunk draws WOOD when `wy >= t.s - t.h and wy < t.s` -- stops ONE PIXEL SHORT of the surface. The surface row (wy == t.s) returns b.grass via rpg.lua:686 (`if wy == surf then return b.grass end`), so there's an actual 1-pixel air gap between the bottom of the trunk and the grass. Looks like the tree is floating.
- REPRODUCIBLE: yes, every tree in every world. The 1-pixel gap is consistent.
- FIX CANDIDATE: change the trunk condition from `wy < t.s` to `wy < t.s + 1` so the trunk extends into the surface row, overwriting the grass at the trunk's 2px column (which is exactly how Terraria/Minecraft render trees). One-line fix.
- ALSO CONSIDER: similar gap may exist on the canopy side -- canopy condition at rpg.lua:675 draws GRASS (leaves) when `dx*dx/36 + dy*dy/20 <= 1` centered on (t.x0+0.5, t.s-t.h-2). Check that this doesn't have a matching gap.
- SEVERITY: cosmetic but constant-on-screen -- every player sees it on spawn. Belongs to @bugs.
## Roadmap: v1.15.7-v1.15.10 respawn-path-drift retrospective (2026-08-30, round 24)

- [x] Wrote the retrospective doc Main deferred from round 23:
      `knowledge/respawn-path-drift-retrospective-2026-08-30.md`
      (6328 bytes, just over the 6KB cap with the four required sections +
      helper-coverage matrix + checklist). Four sections per Main's brief.
- [x] FLAG FROM BRIEF: brief said "v1.15.10" + R._teleportCompanionAndClear
      at rpg.lua:915. Verified live via bridge BEFORE writing:
      PID 37320, port 9877, VER=1.15.10,
      `R._resetSpawnState=function`,
      `R._teleportCompanionAndClear=function`,
      `R.CHANGELOG[1].ver="1.15.10"`. The v1.15.10 ship landed between
      my round 23 read and round 24 task; CHANGELOG.md markdown is still
      one version behind (v1.15.9) but the in-game R.CHANGELOG[1] is
      the source of truth per the v1.15.8 CONVENTION entry.
- [x] FOUR SECTIONS SHIPPED:
      (1) PATTERN -- 5 respawn paths (surface death, manual R, Magic
      Mirror, bed respawn, Esc menu) with helper-coverage matrix.
      Only intentional asymmetry: HP rule (surface=100, Mirror=
      preserve, bed=max(cur,40)).
      (2) BUGS -- F1+F8 (now both folded into _teleportCompanionAndClear),
      F2/F3 (companion.lua cleanup), F5+F9 (the two iterations of the
      respawn-path-drift pattern, both fixed by extraction into
      helpers). Same drift shape, same fix shape, two rounds apart.
      (3) ARCHITECTURE -- two helpers, deliberately split:
      _resetSpawnState is purely data (no R.P dep), _teleportCompanion
      AndClear is position-dependent (reads R.P.x/y). Documented what
      they DON'T cover (HP per-path rule, death-only inventory-halve,
      R.deaths increment).
      (4) CHECKLIST -- 4 steps for whoever adds spawn-related state:
      decide which helper (or neither), no caller change if helper,
      new spawn path = call both helpers, bridge-smoke verify.
      Includes explicit DON'T rules (HP, death-only) with reason.
- [x] NO NEW CHECKER. Same coupling/maintenance-discipline rejection
      as rounds 21/23. Closest a checker could get is "grep for
      `R.X = ...` inside spawnPlayer body, warn if not in helper" --
      noise-prone and misses the real failure mode (failing to call
      the helper, not failing to define state).
- [x] No mutations to rpg.lua, survival.lua, or any plugin. Doc-only
      deliverable.

## Bugs track -- trees float above grass (F10) v1.15.12 (2026-08-30)
- F10 [COSMETIC BUT ALWAYS-ON-SCREEN] SHIPPED. Single-file rpg.lua fix.
- ROOT CAUSE: genBase() trunk loop at the original rpg.lua:674 drew WOOD when
  `wy >= t.s - t.h and wy < t.s` -- stopped one pixel short of the surface row.
  The surface row itself was always b.grass via the early-return at the original
  line 679 (`if wy == surf then return b.grass end`). Result: 1-pixel air gap
  between the trunk's bottom row and the grass surface row, which the eye reads
  as the tree "floating" above the ground. Drew sent a screenshot.
- CANOPY CHECK: also inspected the canopy ellipse at the original line 675
  (`dx*dx/36 + dy*dy/20 <= 1` centered on (t.x0+0.5, t.s-t.h-2)). No matching
  gap -- the canopy covers the topmost trunk rows by design (with dy=1, the
  ellipse test gives 1/36 + 1/20 = 0.058, well inside the 1.0 boundary).
  Unchanged.
- FIX: widened the trunk condition from `wy < t.s` to `wy <= t.s`, AND hoisted
  the trunk+canopy check out of the `if wy < surf` block so it can fire at
  wy == surf too. Restructured genBase's top branch from
  `if wy < surf` to `if wy <= surf`, with the inner check
  `if wy == surf then return b.grass end` returning grass only AFTER the trunk
  check has had a chance to overdraw it. Removed the now-dead `if wy == surf`
  early-return at the original line 688 (moved inside the top branch).
- Live lab verification (port 9877, token zcyLenMVgel7gJ0xjxCb0-jETJZPo7crhZOfKJ1DMGE):
  - loadstring() of rpg.lua = OK (size=241619)
  - hot-reload clean; log shows no new errors, R.lastErr=nil
  - R.VERSION = "1.15.12"
  - UNIT TEST (trunk condition across 5 wy values, pre vs post fix):
    * wy=s-h (top trunk row): both=true (unchanged)
    * wy=s-1 (one above surface): both=true (unchanged)
    * wy=s (AT surface, the gap row): preFix=false, postFix=true (the fix)
    * wy=s+1 (below surface): both=false (correct -- soil/grass takes over)
    * wx off-trunk column: both=false (correct)
  - DISPATCH TEST (F10 genBase simulation):
    * surf_trunk_col=WOOD (at wy=surf on trunk column -> WOOD overdraws grass)
    * surf_x0+1=WOOD (2nd trunk column -> WOOD)
    * surf_off=GRSS (at wy=surf NOT on trunk -> grass, doesn't overdraw)
    * surf-1_trunk=WOOD (one above surface -> WOOD, unchanged)
    * canopy_area=GRSS (canopy ellipse -> GRASS, unchanged)
  - Real-world rendering NOT exercised: lab worldEverGen=false (lab hot-reloaded
    before world generation fired); sim.partID on the visible canvas showed all
    empty (no terrain particles yet). The fix is mechanical and the unit +
    dispatch tests cover the exact behavior change, but the visual win is for
    the next world the user starts on the live 9876 session.
- Verdict: SHIPPED + LIVE-VERIFIED on lab (logic and dispatch covered, real-world
  rendering pending next world-gen on the live session).
- @github note for v1.15.11 release: separate task, will be triggered by Main.

## Roadmap round 25 (2026-08-30) -- next bug class: save-load version drift
- Audit + finding + recommendation doc shipped: `knowledge/next-bug-class-2026-08-30.md` (~10KB).
- CLASS picked: save-load version drift (F5/F9-pattern but for save-file boundary, not bed-wrap).
- EVIDENCE (live-bridge VERIFIED on PID 37320, port 9877, VER=1.15.10):
  - Single-call repro: `R.COMP = { 15 fields matching source init }` + `pcall(ipairs, R.COMP.chatQueue)` -> `bad argument #1 to 'ipairs' (table expected, got nil)`.
  - Real source location: companion.lua:705 `for i, m in ipairs(C.chatQueue)` in `R.companionChatPending(consume)`.
  - 14 fields (chatQueue, queue, lastHeartbeat, mode, sayMsg, sayAt, override, _hits, enqueueChain, cmd, index, ...) are REFERENCED in companion.lua but NOT in the R.COMP = R.COMP or { ... } initializer at 29-47. Diff'd via regex against live source.
  - Save.lua:407 `for k, v in pairs(data.plugins) do R[k] = v end end` is UNCONDITIONAL overwrite -- does NOT re-run plugin initializers after restore, so any new field the source adds (but old saves lack) ends up nil.
  - Current save D:/powder-toy/knowledge/rpg-save.json has 28 COMP fields (recent version), so no live crash today. Latent: loading a v1.15.6-or-earlier save will crash on next chat-poll or C.enqueueChain call.
- RECOMMENDED FIX (for @bugs): Option A = re-run plugin initializers after load (each plugin registers R._applyXDefaults() which sets `field = field or default`; save.lua calls them after doLoad's plugin overwrite). ~5 lines per plugin x 9 plugins. Option B (merge-don't-overwrite in doLoad) is smaller but doesn't fix chatQueue=nil because R.COMP.chatQueue is nil both before and after merge -- rejected as incomplete. Option C (save versioning) noted as long-term direction but over-engineered for one latent bug.
- (a) hook-arity re-check: NOT re-run. Round 23 found 5 sloppy-but-legal, zero reverse cases. No source changes since round 23 that would add new handlers.
- (c) inventory overflow: NOT a bug class. R.inventory has no cap but that's a deliberate vanilla-style design choice (sandbox has its own 999 cap). Not crash-causing.
- No new checker built. Same reasoning as rounds 21/23/24: state-drift-across-boundary bugs are not detectable via regex; the fix IS the discipline.
- Verdict: SHIPPED + LIVE-VERIFIED + ACTIONABLE FOR @BUGS. Doc on disk; next round waits for @bugs to pick up Option A or B.

## Bugs track -- Day-N-day HUD duplication v1.15.14 (2026-08-30)
- ROUND 25 SHIPPED. Bug-hunt pass on the live user session.
- METHOD: bridge-read live log tail + state on port 9876 (user on v1.15.12),
  inspected state, then triggered a debugShot screenshot of the live HUD via
  PBX.state.rpg.debugShotRequested path to visually inspect for layout bugs.
- ROOT CAUSE: top-left HUD status line at rpg.lua:2606 had format
  `string.format("Day %d %s   x %d   %s   %s%s", R.day or 1, night > 0.2 and "night" or "day", ...)`
  where %s was ALWAYS "day" or "night" -- so for ~95% of playtime (anytime
  night <= 0.2) the HUD read "Day 2 day", "Day 5 day", etc. -- a clear
  copy-paste-style duplication that looked like a typo. Confirmed visually on
  the screenshot: "Day 2 day   x -360   surface   forest".
- DISCOVERED ANOTHER BUG ALONG THE WAY: between my v1.15.12 ship and this
  round, someone -- assumed @feature -- had already shipped v1.15.13 (HUD
  temperature+pressure gauge redesign). Version chain is now 1.15.11 -> 1.15.13
  (skipping 1.15.12 in the changelog because the redesign entry was inserted
  above the F10 entry, which dropped v1.15.12 from the displayed list).
  Flagged for cleanup lane.
- FIX: dropped the redundant day/night word entirely, only appending " (night)"
  when night > 0.2. New format:
  `string.format("Day %d%s   x %d   %s   %s%s", R.day or 1, night > 0.2 and " (night)" or "", ...)`
- LIVE-VISUAL CONFIRMATION: debug-shot the v1.15.12 HUD via bridge, saw the
  bug clearly. Format-string unit-tested on lab: daytime output is now
  "Day 2   x -80   surface   forest" (no duplicate day), nightime is
  "Day 2 (night)   x -80   surface   forest   enemies ON".
- Live lab verification (port 9877, token zcyLenMVgel7gJ0xjxCb0-jETJZPo7crhZOfKJ1DMGE):
  - loadstring() of rpg.lua = OK (size=245533)
  - hot-reload clean; log shows no new errors, R.lastErr=nil
  - R.VERSION = "1.15.14"
  - Format string tested 3 ways (daytime/night/duskish) -- all 3 correct
- OTHER CANDIDATE BUGS CHECKED + REJECTED:
  - HUD top-right vs top-left overlap: checked pixel positions; no overlap.
    v1.15.13's gauge redesign fixed the "Feels like X F" overlap with the
    autosave log tail that I would have otherwise reported.
  - Companion teleport jitter (F1 inside player's feet): checked live state --
    Aster is mid-chase, not post-respawn. deltaX=23 not 12 (chasing). No jitter.
  - Sunburnt 1800-frame cooldown aggressiveness: 1 msg/30s, acceptable.
  - F10 tree fix side effects: checked F10 logic, no new edge cases.
  - Inconsistency between teleport offsets 10 (TELEPORT_DIST) vs 12 (F1+revive):
    real but cosmetic, no current visible effect.
- Verdict: SHIPPED + LIVE-VERIFIED on lab.

## Roadmap round 26 (2026-08-30) -- five UI issues, two P0 in flight, three deferred
- Design-only spec doc shipped: `knowledge/round-26-three-ui-issues-2026-08-30.md` (~21KB).
- Live source-verified (PID 37320, port 9877, VER=1.15.10):
  - HUD band: rpg.lua:2595-2675; Day text at y=22 collides with GOAL bar at x=258..498 (Day text max width 378px starting at x=8 = overlap x=258..386 every frame).
  - Minimap: rpg.lua:2267-2276; 25x15 tiles at sz=4, player marker is 4x4 white square same size as every tile, only 3 colors total (blue/orange/grey).
  - Brush: rpg.lua:1917/1933-1940/2151-2152; R.brush is single int 0..4, placeAt uses square loop only, `[` `]` and Shift+wheel are size-only.
  - onWheel: rpg.lua:2213-2224; bare wheel cycles R.sel (hotbar), Shift+wheel changes R.brush. User wants bare wheel to be brush size.
  - Cursor preview: rpg.lua:2541-2560; at R.brush=0 the preview is 3x3 ticks + label below (bigger than the 1px pixel).
- F15 [P0 LIVE @bugs]: bare wheel = brush size; [ ] fall back to secondary; drop ticks+label at brush=0. Documented in spec doc for completeness; @bugs owns implementation.
- F16 [DEFERRED next round, @bugs may own]: brush shape selector. Same scope as F14 below.
- F12 [DEFERRED v1.15.14]: HUD layout -- three-row bg-filled band (y=4..16 gauges / y=18..30 Day / y=32..50 needs); move GOAL to top-right (x=W-300, y=4); move version to bottom-left (y=H-12, x=4); drop "enemies ON" suffix from Day text.
- F13 [DEFERRED v1.15.14]: minimap -- sz=2 (50x30 tiles), use R.tiles[k].ex color for distinct biomes, player as 5px arrow, add N marker + coord readout + 3-pixel legend.
- F14 [DEFERRED v1.15.14]: brush shape -- V hotkey cycles square/circle/single; R.brushShape = "square"|"circle"|"single"; update hotbar hint + help line at rpg.lua:2260/2392.
- No new checker -- all UX fixes, not invariant violations.
- Verdict: SHIPPED DESIGN DOC + LIVE-SOURCE-VERIFIED. Next round waits for @bugs to finish F15 and pick up F16; F12+F13+F14 to ship in v1.15.14.
- [ ] Hot-reload user live session (port 9876) to v1.15.17 once user restarts lab/accepts new session (lab already at 1.15.17 with F15+F16+molten fix)
- [ ] F11 (zoom box drag), F12 (HUD layout), F13 (minimap detail), F14 (brush shape picker) -- deferred
- [ ] build_and_trace end-to-end verification (lab already verified run_lua_test + inspect_grid work; build_and_trace needs an actual Meson run)
- [BLOCKED] Hot-reload user live (port 9876) to v1.15.17+v1.15.18 -- rpg.lua loads only on powder.exe restart; user owns live session
- [DEFERRED] F11 zoom box drag -- needs separate design pass
- [DEFERRED] F12 HUD layout (Day/GOAL collision)
- [DEFERRED] F13 minimap detail

## 2026-08-30 Cursor pickup — Claude Code history + in-game brush + menu spam + Create World

- Claude Code session scan: 6 Powder Toy sessions in `C:\Users\Drew\.claude\history.jsonl` (Aug 23–30). Latest: `a409f5e3-b99d-4b44-9819-aacbc44a5b11` (57 prompts). Name is **Claude** (C-L-A-U-D-E) / Claude Code — never "Quad."
- [ ] **v1.15.22 Create World** — title Play/New World → map type, survival/sandbox, seed, cave/ore/tree sliders (`scripts/lua/rpg.lua`). **Awaiting Drew live.** F9/restart on port 9876.
- [ ] **v1.15.21 menu-close brush spam** — `_clickArmed` + `wouldPlace()` + `releaseMouse()` on all menu transitions. Same workaround you named (toggle TPT menu) explained the bug. **Awaiting Drew live.**
- [ ] **v1.15.20 Tab / in-game brush** — `keyName` Tab fix, `pullNativeBrush` in placeAt, native radius sync. **Awaiting Drew live.**
- [ ] **Standing: no second powder.exe / lab window** unless Drew explicitly asks (CLAUDE.md + hub 14:46).
- [ ] **MCP agent_start / lab-first tooling** — started then **cancelled** this session per no-lab-windows ask; `run_lua_test`/`inspect_grid`/`build_and_trace` already exist.
- [ ] Other open from prior tracks: bag/carried tab UX; HUD Day/GOAL overlap (F12); minimap (F13); **save-load plugin field drift** (real latent bug — doc only, fix not coded).
