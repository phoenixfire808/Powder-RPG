# Geological accuracy research (2026-08-29)

Ask (Drew): "the ground right underneath the topsoil is just made out of
brick, that's not accurate, I want the whole terrain to be geologically
accurate." A same-session fix already swapped the fallback from BRCK to
STNE (a real rock, better than brick) but that was a stopgap substitution,
not the "real" layered, biome-varied stack Drew actually asked for. This is
the real research pass.

## Real-world geology (the actual layer stack, not invented)

A real weathering profile, standard soil-science terminology
([geography.as.uky.edu overview](https://geography.as.uky.edu/sites/default/files/SoilWeatheredRock.pdf),
[Saprolite - Wikipedia](https://en.wikipedia.org/wiki/Saprolite)):

1. **Topsoil (A horizon)** -- organic-rich surface layer, where plants root.
2. **Subsoil (B horizon)** -- denser, more compact, leached minerals from
   above accumulate here.
3. **Regolith / saprolite (C horizon)** -- chemically weathered rock, the
   transition zone; saprolite specifically is "deep weathering of the
   bedrock surface... the least weathered material, lying just above the
   solid, unbroken bedrock."
4. **Bedrock** -- unweathered rock. Real bedrock composition genuinely
   varies by region/formation: granite and basalt (igneous, common in
   mountainous/continental or volcanic areas), sandstone and limestone
   (sedimentary, common in desert/basin/former-seabed areas). This is WHY
   real terrain isn't one uniform rock everywhere -- the actual geological
   ask is "bedrock type should track biome/formation," not just "use a
   better generic rock."

This directly explains the original (buggy) code's intent: it was reaching
for `"GRNT"` (granite) as the default bedrock -- granite genuinely IS the
classic real-world answer for generic continental bedrock. The bug was that
GRNT was never actually registered as a real element in this fork (see
TODO.md's geological-accuracy fix note), not that granite was the wrong
choice conceptually.

## What Terraria does (closest genre precedent, for contrast)

Terraria's depth model is Surface -> Underground (dirt-with-stone-patches)
-> Caverns (its biggest layer, biome-varied: ice, jungle, desert
underground variants) -> Underworld (hellstone/lava at the very bottom)
([Layers - Terraria Wiki](https://terraria.wiki.gg/wiki/Layers)). This is a
good precedent for "biome-varied underground" as a concept, but Terraria's
own layer names/materials are fantastical (Underworld/hellstone), not
real-world accurate -- useful for the STRUCTURE (depth bands, biome
variation carries underground) but not for the material choices themselves,
since Drew's ask is specifically for real accuracy, not Terraria's look.

## What's actually available in THIS engine right now (checked live, not
assumed)

Queried the running lab instance directly for real rock-type elements:
`STNE` (generic Stone, id 5) and `BSLT` (real Basalt, id 503) both exist and
are usable today. `GRNT` (granite), sandstone, limestone, and shale do NOT
exist as elements in this fork -- building a fully accurate "granite in
mountains, sandstone in deserts, basalt near volcanoes" stack would need 1-2
new custom elements (following the same `elements.allocate` pattern already
used for GRSS/BLD this session), not just picking existing names.

## CORRECTION 2026-08-29, after this doc first shipped: STNE is NOT safe
terrain fill

The V1 below originally recommended STNE as universal bedrock. That was
wrong and caused a real regression: STNE is a genuine falling powder in
this engine (`Falldown=1`, not `TYPE_SOLID`), not a static wall material --
verified live via `elem.property(STNE_id,'Falldown')` and
`bit.band(elem.property(STNE_id,'Properties'), elem.TYPE_SOLID)`. Using it
as subsoil/bedrock fill caused a live session's terrain to collapse on
generation (reverted by the bugs track). The lesson generalizes: resolving
to a valid element id proves NOTHING about whether it behaves like solid
ground -- always check both Falldown==0 AND TYPE_SOLID before using
anything as terrain fill, not just that has()/id() returns non-nil.
Re-checked BSLT and BRCK the same way before trusting either this time:
`BSLT: Falldown=0, solid=true` (genuinely safe) and, notably,
`BRCK: Falldown=0, solid=true` too -- brick was never physically broken as
terrain, it was only ever an aesthetic complaint, not a structural one.

## Recommended V1 cut (corrected)

Real depth bands using real terminology, built from what already exists,
no new elements required:
1. **Topsoil** -- existing per-biome soil (already correct, unchanged).
2. **Subsoil/regolith band** (roughly the next 15-30 depth units below
   topsoil) -- could stay as the biome soil material a bit longer/denser
   before transitioning, or introduce a distinct "packed dirt" look reusing
   an existing element -- minor, cosmetic, low priority.
3. **Bedrock** -- BSLT (real basalt, verified Falldown=0/solid) as the
   default fallback -- genuinely solid, genuinely real igneous rock, zero
   new-element cost. BRCK is a safe fallback-of-the-fallback if BSLT is ever
   unavailable (also verified solid), which at least keeps the "aesthetic
   complaint, not a collapse risk" framing honest even in that case. STNE
   should NOT be used as terrain fill anywhere in this stack.

**Explicitly OUT of V1** (needs new custom elements, bigger lift): real
granite (the conceptually-correct original intent, still not registered as
an element in this fork -- if added, MUST be verified Falldown=0/TYPE_SOLID
before use, don't assume from the name), real sandstone under deserts, real
limestone/shale variation, a true saprolite transition-texture layer. Flag
as a real V2 if Drew wants the full biome-accurate rock palette -- each new
element follows the same `elements.allocate("RPG","NAME")` pattern already
used for GRSS/BLD, but every single one needs its own Falldown/TYPE_SOLID
check before it's trusted as structural fill, per the correction above.

## What has to be decided before more code

1. Is BSLT-everywhere enough for now, or does Drew want real granite (a new
   verified-solid custom element) as the primary bedrock look instead,
   since that was the original conceptual intent?
2. Does the subsoil/regolith transition band need its own visual identity,
   or is direct topsoil -> bedrock acceptable?
