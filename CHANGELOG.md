# Changelog

Mirrors `R.CHANGELOG` in `scripts/lua/rpg.lua` for recent bumps. See `releases/` for full
release notes.

## v1.15.28

- Blood (@bug): damage spawns vivid red BLD spray over several frames (outward from facing
  direction); BLD colour 0xFF1020.
- Companion (@feature): Enter-chat always runs Aster's command parser even with model driver;
  broad intent fallbacks (mine/gather/craft/light/shaft/quest/bring me); manual tasks block
  scripted follow until chain finishes.
- HUD (@bug): fixed top-left rows (HP / Day / air+food / T+P); survival warmth/events out of
  HP band; version readout bottom-left.
- Trees (@feature): rain routes down trunk (`treeWaterVeinsTick`); trunk WOOD no longer
  instantly absorbs resting rain.
- Liquid settle + env gradients (@feature): resting WATR soaks soil; depth-thinning O2,
  surface OXYG/pressure seeding, H2/GAS rise, CO2 pools, breathing consumes OXYG.

## v1.15.26

- Vehicles (@vehicles): minecart + rail + mine-lift kits on the workbench/anvil tree. Rail kit:
  LMB-drag snapped track (flat / 45° / vertical shaft). Minecart: place on track, V to board,
  D/A drive, S brake/dismount via R.mount/R.ride. Mine lift: vertical shaft cage with
  grid-powered call buttons. V only steals brush-shape when riding or next to a vehicle.
- Ventilation fan (VENTFANKIT): new powered life-support machine - registers into R.scrubbers to
  pull down ambient CO/CO2 near you and pushes real CO2/smoke along its duct. CO2 scrubber
  (SCRUBBERKIT) now also registers into R.scrubbers when powered (was only killing particles,
  not reducing R.gas.co/co2). Recipe unlocks at 10W tier alongside air pump and scrubber.
- survival.lua (@survival pillar 0b): minimal plant/food loop confirmed live — till SOIL (GOO
  recipe), plant SEED on patch with nearby WATR, harvest WHEAT, bake BREAD at furnace,
  right-click any R.FOODS item to eat and refill R.need.food. Idempotent R.eat/R.spawnPlayer
  wrappers (R._survival guard) so hot-reload no longer stacks illness/bed wraps.

## v1.15.25

- Companion (@feature): refreshIndex now reports nearby LAVA/FIRE/ACID to the model index; chat
  templates for 'cut trees', 'dig hole', and 'build house' emit multi-step enqueueChain plans;
  buildRoom refuses to start if the player is inside the rect; digArea/buildRoom speak start +
  halfway milestones.

## v1.15.24

- Old save files no longer crash companion chat after load (missing chatQueue/queue fields are
  merged and defaulted). F12 HUD: Day line has its own background row and no longer overlaps
  the GOAL bar; version readout moved to bottom-left. F13 minimap: 50x30 tiles at 2px, biome
  tinting, player arrow, north marker, coord readout.
