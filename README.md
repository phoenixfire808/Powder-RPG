Powder Toy RPG & Realism Fork
==========================

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
- [New physics & elements](#new-physics--elements)
- [Colony AI sandbox](#colony-ai-sandbox)
- [Sandbox quality-of-life](#sandbox-quality-of-life)
- [Getting the update while you play](#getting-the-update-while-you-play)
- [Roadmap](#roadmap)
- [Running from source](#running-from-source)
- [Credit & license](#credit--license)

Powder RPG
===========================================================================
A continuous, ~1900px-deep side-scrolling world built entirely out of the sandbox's own
particles — every block you stand on, mine, or die to is a real simulated element.

- **Auto-following camera with manual offset** — the camera tracks your character on its
  own; the arrow keys nudge a look-ahead offset in any direction without ever taking over
  the follow behavior, so you can scout what's above, below, or to either side without
  losing your place.
- **Breathable atmosphere** — oxygen is a real, visible particle drifting through the world
  at a density tied to depth (thin and sparse deep underground, abundant near the surface).
  Run out and you take damage; an air-bladder accessory keeps you breathing underground or
  underwater.
- **Fallout-style radiation** — uranium and plutonium don't just hurt you while you're
  standing next to them. Ground near live radioactive material gets contaminated and stays
  that way, decaying slowly over real time, and your character accumulates a long-term dose
  that keeps doing damage even after you've walked away. Lead blocks the buildup.
- **Day/night cycle and weather** — a full day/night cycle with rain that can strike
  lightning, and a toggleable enemy spawner that sends stick-figure attackers your way.
- **Full crafting progression** — workbench, furnace, and anvil crafting stations; ores
  smelt into bars, bars forge into picks, axes, and swords across wood → stone → iron →
  steel tiers, each with its own damage/mining-power stats and an always-visible
  description (no hovering required to see what anything does).
- **A 14-step guided quest chain** — from "chop 10 wood" through smelting, forging, biome
  exploration, and a 50m depth milestone, up to steel tools and diamond rewards, so a new
  player always has a next goal instead of an empty sandbox.
- **Persistent saves**, a chat/log feed, and a minimap.
- **Built-in bug reporting** — press F8 in-game to send a bug report or suggestion straight
  to the dev's Discord, with automatic context (seed, day, frame) attached, no alt-tabbing
  or GitHub account required.
- **Self-updating** — the game checks this repo's releases on startup. If you're behind, it
  shows a changelog dialog listing everything you've missed across every skipped release
  (not just the latest one) and lets you install with one keypress; it downloads, swaps its
  own files out, and relaunches on its own.

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

Roadmap
===========================================================================
- [ ] **Item quality system** — crafted tools rolling a quality tier that affects their
      stats, not just their tier.
- [ ] **Behavior-kind persistence** — a few of the power/reactor elements (turbine,
      thermoelectric, reactive concrete) are defined through custom behavior kinds that
      aren't yet re-registered on restart, so they currently only work in a live dev
      session rather than a fresh launch — everything else in the elements table above
      survives a restart intact.
- [ ] More biomes and quest content past the current 14-step starter chain.

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
