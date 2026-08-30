Powder Toy RPG & Realism Fork
==========================

[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/phoenixfire808/The-Powder-Toy?label=latest%20build&color=orange)](https://github.com/phoenixfire808/The-Powder-Toy/releases/latest)
[![Changelog](https://img.shields.io/badge/changelog-full%20history-brightgreen.svg)](CHANGELOG.md)

A fork of [The Powder Toy](https://powdertoy.co.uk/) — the classic falling-sand physics
sandbox — with three things layered on top of the stock engine: a full survival RPG built
entirely on the simulation, ~60 new elements covering real chemistry, nuclear physics and
electronics, and an AI colony sandbox that MCP tooling can drive directly. Everything below
is running code in this repository, not a design doc.

**[Download the latest build](https://github.com/phoenixfire808/The-Powder-Toy/releases/latest)**
— unzip, run `Play.bat`, you're in.

Table of contents
---------------------------------------------------------------------------
- [Powder RPG](#powder-rpg)
- [Life support & machines](#life-support--machines)
- [New physics & elements](#new-physics--elements)
- [Colony AI sandbox](#colony-ai-sandbox)
- [Sandbox quality-of-life](#sandbox-quality-of-life)
- [Getting the update while you play](#getting-the-update-while-you-play)
- [Where this is going](#where-this-is-going)
- [Roadmap](#roadmap)
- [Running from source](#running-from-source)
- [Credit & license](#credit--license)

Powder RPG
===========================================================================
A continuous, side-scrolling world built entirely out of the sandbox's own particles —
every block you stand on, mine, or die to is a real simulated element, and every survival
system runs on the engine's actual physics rather than a scripted approximation of it.

- **A real atmosphere, not a meter.** Digging opens a genuine low-pressure pocket that the
  sim's own air physics fills from above; the surface holds a real, permanent positive
  pressure baseline pushing back down. Oxygen is a real, visible particle whose density
  scales with depth — thin and sparse far underground, abundant at the surface — and
  breathing consumes it and exhales real CO2 next to you. Sealed rooms only get dangerous
  once they're genuinely deep, not the instant you close a door at ground level.
- **Survival needs**: hunger and thirst drain over time and do real damage at zero; a
  Canteen lets you carry and boil water, and simply standing in a real lake quenches thirst
  directly. Taking damage (falls, burns, radiation, hunger, suffocation) draws real blood
  that isn't walkable, so you can't casually stand on your own puddle.
- **A permanent AI companion** — not a summonable pet: she's present from the moment a new
  world generates, pathfinds and fights alongside you with her own HP and death/revive
  cycle, narrates what she sees in the world, and answers you in a chat box.
- **Fallout-style radiation** — uranium and plutonium contaminate the ground around them,
  which decays slowly over real time, and your character accumulates a long-term dose that
  keeps doing damage even after you've walked away. Lead blocks the buildup.
- **Day/night cycle and weather**, with an adjustable day length, rain that can strike
  lightning, and a toggleable enemy spawner that sends stick-figure attackers your way.
- **Deep crafting progression** — workbench, furnace, and anvil crafting stations feed into
  a Research Bench and an Advanced Lab past that, gated behind real material costs; ores
  smelt into bars, bars forge into tools across wood → stone → iron → steel tiers, each with
  its own damage/mining-power stats and an always-visible description.
- **Native drawing tools in survival** — Shift-drag draws a straight line and Ctrl+Shift
  drags out and fills a whole box from your own inventory, the same gestures the sandbox's
  own tools use, now working against what you've actually mined and carry.
- **A live-tunable world engine** — day length, cave frequency, ore rarity, gravity, jump
  height, and move speed are all real sliders in the Esc/Options menu, not fixed constants,
  so the feel of the world is something you dial in rather than accept.
- **A real title screen** — Play/Settings/Quit before world generation, with "quit to menu"
  reachable mid-game without killing the process or losing your in-memory world.
- **A 14-step guided quest chain** — from "chop 10 wood" through smelting, forging, biome
  exploration, and a 50m depth milestone, up to steel tools and diamond rewards, so a new
  player always has a next goal instead of an empty sandbox.
- **Persistent saves**, a chat/log feed, and a minimap.
- **Built-in bug reporting** — press F8 in-game to send a bug report or suggestion straight
  to the dev's Discord, with automatic context (seed, day, frame) attached, no alt-tabbing
  or GitHub account required.
- **Self-updating** — the game checks this repo's releases on startup. If you're behind, it
  shows a changelog dialog — now with a real scrollbar you can drag, not just the mouse
  wheel — listing everything you've missed across every skipped release, and lets you
  install with one keypress; it downloads, swaps its own files out, and relaunches on its
  own.

Life support & machines
===========================================================================
Underneath the survival layer is a real energy/life-support progression: descending
requires sustaining yourself with machines that chain into each other, not just better gear.

- **Real atmosphere engineering** — bellows, air lines, compressors, and life-support panels
  that report whether a room is genuinely sealed or open to sky, all reading and feeding the
  same pressure/oxygen physics the player breathes.
- **A full energy tree** — solar, wind, geothermal, fuel cells, and electrolysis, plus
  boilers and turbines running on real steam physics (measured live: water climbs through a
  real 373K phase change, boils dry on schedule with the fuel that's lit under it, and a
  piped connection to a turbine produces real, measurable output).
- **Chemistry, fluids, and logistics machines** — electrolysis cells, acid synthesis, sorters
  and splitters, silos and quarries, all built from real reagents and real particle behavior
  rather than abstract recipes.
- **Hazard atmosphere** — carbon monoxide from fire in a sealed room, CO2 from smelting,
  explosive methane from swamp/oil pockets, and depth radiation all demand real mitigation
  (scrubbers, ventilation, lead shielding) instead of just better armor.

New physics & elements
===========================================================================
Roughly 60 new elements on top of the ~180 stock ones, several backed by real physical
constants rather than arbitrary game numbers.

**Antimatter & magnetism showcase** — a from-scratch physics demo (inspired by
[Veritasium's antimatter video](https://www.youtube.com/watch?v=fp7GetAY-1I)) with four
live bays: antimatter production, magnetic containment, an annihilation chain reaction, and
a shielded-vs-unshielded comparison. `AMTR` annihilates on contact, releasing its full mass
as heat, light, and a shockwave — unless it's inside a live `MGNT` electromagnetic field.

**Real rare-earth magnetism** — `GADO` (gadolinium) is a genuine permanent ferromagnet
below its real Curie point (~20°C) and loses magnetism above it; `FEFL` (iron filings) is
light enough to actually be pulled and clumped by a magnetic field, unlike a solid iron bar;
`LUTE` (lutetium) rounds out the set as the densest, hardest rare earth.

**Everything else**, grouped by what it's for:

| Category | Elements |
|---|---|
| Reactive chemistry | Chlorine, sodium, phosphorus, acetylene, nitrogen/liquid nitrogen, ammonia paths, graphite oxidation |
| Nuclear & radiation | Promethium, radon, quark-gluon plasma, radiation-shielding fabric (Demron) |
| Electronics & power | Customizable wire, LEDs, lithium-ion batteries, thermostats, tmp/ctype/gravity sensors, digital signs, powered converters, turbines |
| Materials processing | Generic gas/liquid/powder/cast-solid forms so any material can boil, melt, pulverize, or cast |
| Structural & defensive | Load-bearing structure blocks that collapse without support, defence foam, indestructible elemental walls, rubber |
| Creatures & robots | A bee that pollinates and defends its hive, a robot pet that follows and fights alongside you |
| Weapons & mechanisms | Guided missiles, powered projectiles, custom explosives, mechanical wheels |

Colony AI sandbox
===========================================================================
Underneath the RPG is a second, independent system: a small AI colony you can build and
watch run itself, and that outside tooling (Claude, via MCP) can drive directly.

- **Worker ants** are real particles of a custom creature element — no scripted teleporting,
  every step is a hand-simulated move into a cell already proven empty.
- **Pheromone-guided pathing and a shared colony record** (nest location, tint color,
  delivered-material store) so an arbitrary number of workers cooperate without stepping on
  each other.
- **Blueprint task assignment** — hand the colony a build shape once; it's compiled into
  flat coordinate arrays so hundreds of workers can consult it every frame without ever
  rescanning or reallocating.
- **Direct per-worker control** exposed over HTTP: inspect, move, kill, recolor, retrait, or
  feed any single ant by id from outside the game entirely.

Sandbox quality-of-life
===========================================================================
- **Sandbox / RPG-menu toggle** — flip the native element menu, HUD, and toolbar on or off
  from one place, so the RPG's own input handling never fights the classic sandbox tools
  underneath it.
- **Favorites wheel** and **custom brush shapes** for faster building.
- A local, loopback-only HTTP bridge (`net.listen`) that exposes safe, read-only and
  queued-mutation actions for external tooling — the same bridge this whole feature list was
  verified through.

Getting the update while you play
===========================================================================
The version you're running is always shown bottom-left. When a newer build exists, a
changelog window lists exactly what changed in every release you've missed — press **U** to
install immediately (it restarts on its own in a few seconds), or **Esc** to keep playing
and update later; the reminder stays on screen either way.

Where this is going
===========================================================================
The pillar this project is built around: **a survival RPG where the physics is real, not
simulated-looking.** Every system above — atmosphere, fire, radiation, energy — is meant to
behave the way the underlying particle sim actually computes it, not a game-design
approximation layered on top. That constraint is deliberate and won't loosen as the game
grows; a new mechanic has to be a real consequence of real physics before it ships.

The near-term arc is depth: descending should require *sustaining yourself*, not just better
gear. The life-support and energy-machine systems above are the first real expression of
that — a base that goes deep needs power, air, and cooling chained together and visibly
working, not decoration. Expect that arc to keep extending: more machine tiers, more reasons
the surface and the depths feel like genuinely different places to survive in, and a world
engine that's tunable enough (see the sliders above) that "how this game feels" is something
players can actually shape rather than something fixed by us.

Roadmap
===========================================================================
- [ ] **Underground generation, done properly** — the current cave/tunnel noise is getting a
      real research pass (real cave systems, vein-based ore distribution) rather than another
      quick tuning patch.
- [ ] **Native shape-drawing tools, fully wired into survival** — Shift-drag/Ctrl+Shift
      already work; extending full native brush-shape/size reading into every placement
      tool is still open.
- [ ] **A real static rock element** for subsoil — the ground below topsoil currently falls
      back to a fired-brick-flavored filler; a dedicated, verified-solid rock material is the
      honest fix, not another substitution.
- [ ] **Multiplayer** — co-op building alongside the existing survival gameplay. A real
      architecture decision (client/host state sync vs. dedicated server authority), not a
      bolt-on; scoped but not started.
- [ ] **A physics-driven character overhaul** — ragdoll/joint movement and real
      gore/dismemberment, in the spirit of the atmosphere/energy work above: a genuine
      physics feature, not a sprite swap.
- [ ] **Item quality system** — crafted tools rolling a quality tier that affects their
      stats, not just their tier.
- [ ] **Behavior-kind persistence** — a few of the power/reactor elements (turbine,
      thermoelectric, reactive concrete) are defined through custom behavior kinds that
      aren't yet re-registered on restart, so they currently only work in a live dev
      session rather than a fresh launch — everything else in the elements table above
      survives a restart intact.
- [ ] More biomes and quest content past the current 14-step starter chain.

Full version-by-version history lives in [CHANGELOG.md](CHANGELOG.md).

Running from source
===========================================================================
Standard Powder Toy build (Meson + Ninja); see the
[_Powder Toy Development Help_ wiki page](https://powdertoy.co.uk/Wiki/W/Main_Page.html) for
toolchain setup. The RPG and colony-sandbox layers are pure Lua (`scripts/lua/`,
autorun-compiled from `bridge_src/`) and need no rebuild — only the new elements above
require a native rebuild.

Credit & license
===========================================================================
Built on [The Powder Toy](https://powdertoy.co.uk/) by Stanislaw K Skowronek and the TPT
team — see [powdertoy.co.uk](https://powdertoy.co.uk/) and the
[official forum](https://powdertoy.co.uk/Discussions/Categories/Index.html) for the
original game, online saves, and the wider community. Distributed, like the original,
under the [GNU General Public License v3](LICENSE).
