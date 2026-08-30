# MCP tool capability expansion proposal (2026-08-29)

Ask (Drew): "I want everything really properly implemented in the MCP
tool... we need to automatically determine bugs and conflicts through the
MCP tool, and do anything we need automatically, formulas, testing,
everything." This is a real scope question -- what follows is grounded in
the ACTUAL bug patterns this session hit by hand, not a speculative feature
list.

## The pattern: every real bug found this session was found by one of a
small number of repeatable checks, done manually, one at a time

That's the actual argument for automating them -- not "wouldn't it be nice
to have more tools," but "we already know exactly what checks catch real
bugs here, and we're re-running them by hand every time."

## Proposed checks, each grounded in a real bug this session actually hit

1. **Terrain-fill solidity check.** The STNE regression (an element that
   resolves to a valid id but has `Falldown=1`/not `TYPE_SOLID`, used as
   terrain fill, causing a live collapse) happened because "resolves to a
   valid id" was mistaken for "safe to use as ground." A tool that takes an
   element name and a claimed use ("terrain fill" / "structural") and
   returns `Falldown`/`TYPE_SOLID`/a pass-fail verdict would have caught
   this before it shipped, not after. Trivial to build: it's the exact
   `elem.property` + `bit.band` snippet already used by hand three times
   this session, wrapped as a callable tool instead of copy-pasted curl.

2. **Physics-constant duplication scanner.** Found twice this session by
   hand (gravity slider not applying to the companion's own separate GRAV
   constant; then the identical gap for the move-speed slider and RUN) --
   the ROOT pattern is companion.lua keeping its own copy of constants
   that rpg.lua also defines and multiplies by a slider. A tool that greps
   both files for matching constant names (GRAV/RUN/ACC/JUMP/MAXFALL-shaped
   identifiers) and flags any that exist in both files but where only one
   file references the corresponding `R.*Mul` slider would catch this
   whole class at once, and would have caught the SECOND instance
   automatically instead of needing a human to notice the pattern repeat.

3. **Crafting-tier reachability checker.** Found twice this session (round
   6: a new station missing from ui.lua's hardcoded tab-order list; round
   7: the same two new stations missing from R.ITEMS's placement gate) --
   both were "a new tier was added to R.STATIONS/R.RECIPES but a sibling
   table that also needs an entry per station wasn't updated." A tool that
   walks every table keyed by station name (R.STATIONS, the ui.lua order
   list, R.ITEMS, any recipe `st=` values) and reports any station name
   present in some but not all of them would catch this reliably --
   this is a real, mechanical, checkable invariant, not a fuzzy heuristic.

4. **Forward-reference / call-before-definition checker for Lua.** The
   coordinator's title-screen bug (`drawTitleScreen`/`titleMouseDown`
   called before their own definitions) is a real, common Lua footgun
   (Lua has no hoisting) that's mechanically detectable: for each `local
   function NAME` in a file, check whether `NAME(` appears anywhere earlier
   in the same file at module-load scope (not inside another function body,
   where it's fine since it only runs later). A real static-analysis tool
   over the plugin files, not a full Lua linter -- narrow and cheap.

5. **Structured formula/state assertions ("testing"), not just one-off
   bridge queries.** Almost every verification this session was a
   hand-written curl command checking one value after a hot-reload. A
   `run_test` or `assert_state` style tool that takes a small declarative
   check (call this function, expect this field to change from A to B, or
   expect this invariant to hold across N ticks) would turn each one-off
   bridge query into a reusable, re-runnable regression check instead of
   throwaway shell history -- e.g. "after R.damageCompanion(10,...), C.hp
   should decrease by exactly 10" becomes a saved check, not a one-time
   curl call that nobody re-runs after the next edit touches that code.

## What's explicitly NOT proposed here

A general-purpose bug-finder or an LLM-driven "review this code" tool --
that's not what "automatically determine bugs and conflicts" cashes out to
when grounded in what actually broke this session. Every real bug above was
caught by a SPECIFIC, NARROW, MECHANICAL check once someone thought to run
it. The highest-value MCP expansion is turning those specific checks into
always-available tools, not building a more general analysis engine nobody
has asked for yet.

## Recommended build order

Checks 1 and 3 are the cheapest (a few lines each, no new infrastructure,
directly reuse patterns already proven by hand this session) and would have
caught 3 of the real bugs this session hit. Check 2 is slightly more
involved (needs to parse/compare two files) but still mechanical. Check 4
is the most "real tool" of the four (actual static analysis over Lua
source) and check 5 is the most infrastructure (needs a real assertion
runner, not just a query wrapper) -- recommend building 1 and 3 first,
proving the pattern earns its keep, before investing in 4 and 5.

## What has to be decided before this gets built

1. Does this live inside `powder_toy_mcp.py` itself (new tool entries,
   following its existing `_CAPABILITY_MANIFEST` pattern -- consistent with
   the codebase, but adds surface area to a file whose OWN self-check
   already showed real fragility this session), or as a separate script
   these checks call into? Recommend separate, small, single-purpose
   scripts registered as MCP tools -- keeps powder_toy_mcp.py's own
   manifest-consistency risk from growing with every new check.
2. Should checks 1-3 run automatically (e.g. as part of every hot-reload),
   or stay on-demand tools someone calls deliberately? Automatic is more
   "properly implemented" per Drew's ask, but needs the reload path itself
   to call out to Python, which the current Lua-side hot-reload flag
   mechanism doesn't do today -- real design question, not answered here.
