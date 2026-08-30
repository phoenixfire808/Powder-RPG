# Vision: the tech tree and the survival loop (2026-08-29)

Drew's own framing: "the game is going to be all about energy generation,
we need a tech tree and more research, it's all about oxygen and resource
management, we should have a food and survival system." This document is
the real vision write-up meant to feed the GitHub README's roadmap/vision
section directly, not a bullet list.

**The core finding of this pass: the central loop Drew is describing is
already real and already built.** This isn't a proposal for a system that
doesn't exist -- it's naming and structuring what multiple sessions of work
already assembled, piece by piece, without ever being written down as one
coherent identity. That's the actual gap: legibility, not missing code.

## The core loop, as it actually exists in the codebase today

```
        POWER (turbines, reactors, solar)
           |
           v
    ELECTROLYSIS (O2GENKIT: real WATR -> real OXYG + HYGN, power-hungry)
           |                                  |
           v                                  v
    OXYGEN -> breathing, life support    HYGN (hydrogen byproduct)
     (R.o2, sealed-room mechanics)            |
                                               v
                                    GAS TURBINE / FUEL CELL
                                    (burns HYGN + real OXYG -> POWER + WATR)
                                               |
                                               v
                                    WATR feeds back into electrolysis,
                                    or into farm plots (crops need real
                                    nearby water to grow), or a DESALINATOR
                                    turns brine/seawater into more of it
```

This is a genuinely closed resource loop, verified live in the code (not
inferred): `O2GENKIT` electrolyses water into oxygen + hydrogen
(machines.lua); a gas turbine burns that hydrogen byproduct for power,
explicitly commented as "closes the electrolysis-to-power loop"; a fuel
cell runs the same reaction in reverse (hydrogen + oxygen -> power + water);
a desalinator turns brine into fresh water for the whole chain. Farm plots
(survival.lua) grow real crops gated on real nearby water, and a
FERTILISER item (machines2.lua, made from processed byproducts) boosts
that growth -- meaning the machine/power chain already feeds the food
system, not just the oxygen system. Food and water are real depleting
stats (`R.need.food`/`R.need.water`, tick down over time, drain HP at zero)
that this same loop replenishes.

**The identity, stated plainly: you are not just surviving against a
hostile world -- you are building a small industrial ecosystem that
converts energy into breathable air, drinking water, and food, and the
tech tree is the story of that ecosystem getting bigger, safer, and more
self-sufficient.** That's a real, distinct pitch (closer to a Factorio/
Oxygen Not Included hybrid than a generic survival-craft game), and it's
already true of the current build -- it just hasn't been said out loud.

## The tech tree, as it actually exists (tiers + what gates what)

Crafting stations, in the order the game already gates them:

1. **By hand** -- earliest tools, no station needed.
2. **Workbench** -- basic tool/item crafting.
3. **Furnace** (lit) -- smelting, ore processing.
4. **Anvil** -- metalworking tier. This is where the power chain begins:
   O2GENKIT, gas turbines, and fuel cells are all Anvil recipes, and
   several are explicitly gated on "unlocked at 100W generated" -- i.e. the
   tech tree already has a real power-output gate, not just a
   station-proximity gate. You have to actually be generating power before
   the next tier of power infrastructure unlocks.
5. **Research Bench** -- shipped this session; requires the earlier tiers'
   output as an ingredient, a real gate-on-a-gate.
6. **Advanced Lab** -- shipped this session; requires ZIRC+B4C+GLAS
   (Research Bench's own outputs), the deepest tier that exists right now.

Material progression backing this (from the existing "power elements" work
this project already has): UO2/ZIRC (fuel), GRPH/B4C (moderator/control),
CU/STEL (conductors/structure), CNCR/LEAD (shielding), NAK (coolant),
AERO/TRBN/TEG (turbines/generators), LEDL (indicators) -- a real
fission-reactor-adjacent material set already exists, consistent with an
FSN-2-style fusion plant and a PLUT/DEUT fission plant already having been
built and played with as real, working structures earlier this project.

## Where the tech tree should actually go next (real proposal, not just
"more tiers")

The pattern above (each tier requires the previous tier's OWN output, plus
a real production-rate gate like "100W generated") is the right shape to
keep extending -- it's already proven out twice (Anvil->Research->Advanced
Lab). Concrete next rungs, each gated the same way:

- **Reactor tier** (gated on Advanced Lab + a real power-output threshold
  higher than 100W, e.g. 500W): unlocks the fission-plant-scale
  UO2/ZIRC/GRPH/B4C chain as a real buildable structure with its own recipes,
  not just a hand-placed demo -- turns the existing FSN-2/PLUT precedent
  into a real progression rung instead of a one-off build.
  Fleshed out (2026-08-30, round 13): checked `power-elements-2026-08-26.json`
  directly -- the 4 core reactor materials already exist with real physical
  properties, not placeholders. UO2 genuinely emits real NEUT particles
  (spontaneous fission, `PROP_RADIOACTIVE`, melts at 2865 C); ZIRC is a real
  neutron-transparent conductor (cladding, melts 1852 C); GRPH is a real
  high-conductivity neutron moderator (melts/sublimes ~3600 C); B4C is a
  real neutron absorber for control rods (melts 2763 C, warms per capture).
  This is a genuinely simulated reactor (real neutron economy: moderation,
  absorption, fission heat), not a themed reskin -- which is exactly why
  it's worth a real progression tier rather than staying a one-off sandbox
  demo. Concrete recipe chain proposal, following this codebase's existing
  "needs the previous tier's own output" pattern: a Fuel Rod (UO2 + ZIRC
  cladding), a Moderator Block (GRPH), a Control Rod (B4C + a metal
  actuator, e.g. STEL), each craftable at the Advanced Lab; a Reactor Core
  structure (built from these three plus CNCR for shielding, matching
  CNCR's existing real role as radiation shielding in this project) that
  actually runs the real neutron-economy simulation already proven out in
  the FSN-2/PLUT precedent builds, wired to the existing turbine/power-grid
  system as its output instead of a bespoke one-off wiring job. The real
  design work already exists (knowledge/community-plut-plant-2026-08-25.md,
  drew-deut-reactor-2026-08-25.blueprint.json) -- this tier is packaging
  proven physics into a repeatable player-facing recipe chain, not
  inventing new reactor physics.
- **Life-support scaling**: right now O2/food/water are managed per-player
  in the open world. A real next step is a "sealed base" concept -- a
  designated enclosed area where life support machines maintain O2/food/
  water automatically for time spent there, making the base-building loop
  matter mechanically (not just cosmetically), and giving late-game power
  generation an actual sink beyond "more power for its own sake."
  Directly answers "resource management" as an ask, not just "more
  factory."
  Fleshed out (2026-08-30, round 14): checked how "sealed" is actually
  detected today, twice -- machines.lua's `roomSealed(wx,wy)` (a cheap
  multi-sample vertical ray-cast checking for open sky above one point) and
  rpg.lua's own player-breathing sealed check (the same shape: a handful of
  directional ray samples, not a flood-fill). Both are proven cheap enough
  to run every tick already. This is the right technique to extend, not
  replace with something expensive: a "sealed base" doesn't need a real
  bounded-region flood-fill (which risks exactly the O(area) lag mistake
  already learned the hard way earlier this session with the oxygen-spawn
  bug) -- it needs the SAME multi-ray heuristic, sampled at a life-support
  machine's location plus a few surrounding points, to answer "is this
  installation actually enclosed" cheaply. Concrete proposal: a life-
  support controller machine (new, or an extension of the existing O2GEN/
  airpump role table in machines.lua) that runs the roomSealed-style check
  periodically (not every tick) at its own position and a small ring
  around it, and while sealed, slowly tops up a persistent "base O2/food/
  water" pool the player draws from while inside -- reusing the existing
  `R.o2`/`R.need.food`/`R.need.water` fields and their existing regen
  logic, not new stat systems.
- **Automation/logistics tier**: pipes/conveyors moving WATR/HYGN/OXYG/
  ore between machines without the player manually carrying it.
  Fleshed out (2026-08-30, round 14): checked machines.lua directly before
  proposing anything new, per the ladder -- a real `CONVEYOR` machine
  already exists (`buildConveyor`, pushes solid/powder materials along a
  belt). The actual gap is narrower than "build a logistics tier from
  scratch": solids already have automation, FLUIDS/GASES (WATR/HYGN/OXYG)
  don't -- existing "pipes" (e.g. the boiler's steam takeoff pipe) are
  fixed structural channels built as part of one specific machine, not a
  general player-placeable pipe connecting arbitrary machines. Concrete
  proposal: a placeable pipe segment (visually similar to the existing
  conveyor's belt-segment pattern) that, once connected between two
  machines with matching fluid ports (e.g. an O2GENKIT's HYGN output and a
  turbine's fuel input), moves a bounded amount of that fluid per tick --
  same shape as the conveyor's existing per-tick solid-pushing logic,
  generalized to liquids/gases instead of a new mechanism. This is what
  actually completes the closed energy/oxygen/water loop described above
  into something a player can build ONCE and leave running automatically,
  instead of manually re-carrying water/hydrogen between machines forever.

## Where food/survival fits (already real, here's how it should be framed)

Food and water are not a separate bolted-on survival-mode timer -- they're
the OTHER output of the same energy/water loop that produces oxygen. A
player who builds out the power->electrolysis->turbine loop is also, by
construction, securing their water supply (feeds crops) and unlocking
FERTILISER for faster food production. The vision-doc framing for GitHub:
"survival mechanics and the industrial tech tree are the same system,
viewed from two angles" -- that's true today, in the actual shipped code,
and is a stronger pitch than describing them as two separate features.

## What this document is NOT

Not a claim that everything is finished -- the reactor tier, sealed-base
life support, and automation/logistics above are real proposals, not
shipped features. It's also not a replacement for the existing narrower
docs (design-multiplayer-2026-08-29.md, design-ragdoll-gore-2026-08-29.md,
design-geology-2026-08-29.md) -- those stay focused on their own systems;
this one is the connective narrative across the systems that already tie
together for real.
