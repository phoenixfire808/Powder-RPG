# Changelog

All notable changes to the Powder RPG build are recorded here, version by version. This
mirrors the in-game changelog (`R.CHANGELOG` in `scripts/lua/rpg.lua`) plus everything shipped
since the last version bump — anything marked **awaiting confirmation** has been verified
against a live test instance but not yet confirmed in a real play session.

## Unreleased (since v1.15.0)

- Seven live-tunable world-engine sliders in the Esc/Options menu: day length, cave frequency,
  ore rarity, gravity, jump height, move speed, and tree spacing — each takes effect
  immediately, no restart.
- Fixed a real desync: the gravity and move-speed sliders only affected the player — the
  companion had her own separate, hardcoded physics constants that never read the new
  multipliers, so a non-default gravity or speed setting would visibly desync her from the
  player. Fixed at the root (she now reads the same shared multipliers at all her physics use
  sites), so any future movement slider covers her automatically too.
- A real V1 title/launch screen: Play/Settings/Quit before world generation, plus "quit to
  menu" from the in-game Esc menu without killing the process or the in-memory world. Got a
  full visual pass after the first version read as too plain: the real world now shows
  through behind the menu once one exists, drifting ember particles for ambient motion, and a
  proper logo/button treatment instead of flat boxes. The title screen's own Settings button
  now opens a matching in-place panel listing all seven sliders, instead of jumping out to a
  different menu.
  *(Fixed same session: a forward-reference bug had the title screen's own draw/click
  handlers calling undefined functions, spamming errors every frame — fixed and confirmed
  with a real screenshot of the rendered title screen.)*
- An Advanced Lab crafting tier past the Research Bench, gated on Research Bench output as an
  ingredient.
- Crafting panel fixes: the station-order list was missing the Research Bench and Advanced
  Lab tiers entirely, so recipes gated on either were craftable in the backend but never drawn
  in the UI at all — fixed, all real recipes are now reachable. Material filter chips now
  wheel-scroll instead of being capped at two rows with no way to see the rest.
- The What's New / changelog popup now has a real draggable scrollbar (grab-and-drag, not
  wheel-only) alongside the existing wheel scroll.
- Fixed a live regression: a fallback for underground rock briefly used a real stock element
  that turns out to be a falling powder rather than a solid, which collapsed generated
  terrain — caught and reverted the same session; the underlying "real static rock" fix is
  still open (see Roadmap).
- Companion combat and world-gen bug hunting continues to turn up real root causes rather than
  guessed fixes — see the in-game changelog below for the full record of what's already
  shipped and confirmed.

## v1.15.0
- New Seed/New World no longer inherits sandbox/creative mode — always starts in real survival now.
- Fixed the What's New popup's bottom text overlapping itself and reading as smushed garbage.
- Ground under topsoil is real Stone now instead of silently defaulting to fired brick.
- Swinging at your companion now actually registers a hit (she already had HP/death, just nothing was calling into it).
- Shift-drag now draws a straight line same as Ctrl-drag; Ctrl+Shift together drags out a box and fills the whole thing on release.
- Crafting panel's material filter no longer eats half the screen before you see a single recipe.
- Day length is now adjustable from the Esc menu (Options > Day length).
- Longer daytime by default, real sunburn from unsheltered daylight, trees now do real photosynthesis (CO2 → O2), tree roots are visible, added a tiered Research Bench.

## v1.14.0
- Real positive atmospheric pressure at the surface now, not just a low-pressure dip where you dig — a genuine differential on both ends, so digging down actually pulls surface air with it.
- Mouse wheel now scrolls the bag's item/recipe lists — no more clicking tiny arrow buttons one line at a time.
- Hover tooltip now also shows real pressure, alongside name and temperature.
- Dig-pressure strength increased so air rushes in noticeably faster.

## v1.13.0
- Replaced the laggy dig-spawns-oxygen hack with the real thing: digging now sets genuine low air pressure at the opened cell, and the sim's own actual air physics pulls surrounding atmosphere in — real negative pressure, not scripted particles, and none of the lag the old version caused.
- Fixed the What's New popup running every version's changes together with no visible separation.

## v1.12.0
- Critical: sealed rooms (a house, a shallow dug-out) were treated as near-vacuum regardless of depth, so stepping into ANY enclosed space could suffocate you almost instantly even right at the surface. Fixed properly — air quality now genuinely depends on depth first; sealing only adds an extra penalty that scales with how deep you are, so it only turns dangerous far underground like it should.
- Blood is no longer walkable — you were able to stand on top of a puddle like solid ground.
- Oxygen that gets physically wedged in tight canopy gaps now periodically releases instead of piling up forever.

## v1.11.0
- Fixed the changelog popup only checking on a brand new world — since fixes now apply instantly without a restart, it could go several versions without ever showing, then dump all of them at once the next time you started a new seed, looking like something broke ("it reset my version"). Now checks right when an update actually applies.

## v1.10.0
- Fixed ambient oxygen getting visibly stuck between tree branches — it was spawning up at canopy height, where real solid leaves physically trap gas particles; now stays down near the ground where it can actually move.
- Standing in real water now directly quenches thirst over time — a Canteen is still the real upgrade (carry water, boil dirty water), but just being in a lake now actually does something.

## v1.9.0
- Digging now visibly pulls oxygen into the new opening immediately, instead of waiting on slow ambient diffusion to eventually wander over.
- Fixed the real cause of "I keep placing machines and they disappear": the core-integrity check could misfire on a single-tick false read right as the core scrolled back into view — now requires a few consecutive misses before actually tearing a machine down.

## v1.8.0
- Temperature is now Fahrenheit everywhere (was Celsius), and the hover tooltip is sized to fit instead of running way too long.
- New: a persistent "Feels like X°F" readout, top-left, showing the real temperature right around your character — not just on hover.

## v1.7.0
- New: hover your mouse over any real material in the world to see its name and exact temperature.
- New: taking damage now draws real blood (fall damage, burns, radiation, hunger/thirst, suffocation all trigger it).

## v1.6.0
- Mouse controls settled: ONE button (LEFT click) now does whatever your selected slot does — places a block, or uses a tool/weapon/sword — instead of a fixed two-button split. Matches native TPT's own single-button tool convention.
- Trees: found and fixed the real remaining cause of leftover floating canopies after chopping (confirmed live: a single realistic axe swing could hollow out a gap wide enough to break the earlier fix). Widened the connectivity search further and removed a size cap that was silently refusing to clean up any canopy bigger than 5 cells — which is all of them.

## v1.5.0
- Tried swapping mouse buttons (left=place/right=use) — reverted back to LEFT=use tool/RIGHT=place after live testing showed it felt wrong. Mouse-button scheme was still an open question at this point.
- Oxygen: reverted the "must wait for real air to diffuse down a shaft" change — it caused sudden suffocation right after digging an obviously open, connected hole. Depth-based air is back to simple and reliable; the visible ambient oxygen particles are unaffected.

## v1.4.0
- Critical: crafting anything (workbench included) never actually showed up in the bag's CARRIED tab — opening it crashed a plugin silently every single time on a freshly generated world (a reset field was set to nil instead of an empty table), leaving the tab permanently empty no matter what you'd made. This could genuinely block progress — fixed.
- Esc menu now has "View full changelog" so you can pull up the whole history any time, not just the once-per-version popup on launch.
- Ctrl+V now pastes into the chat/feedback text boxes via the real OS clipboard.

## v1.3.0
- Critical: every plugin (machines, survival, items, ui, guide, enemies, vehicles, companion, save, world) was only ever loading on the original dev machine — fixed a hardcoded absolute-path bug that made them silently fail as "absent" for anyone else running a downloaded copy.
- Guide: machine/kit items (airline kit, air pump, algae tank, and any future ones) now show up automatically instead of needing to be hand-added to a list that kept going stale.
- Oxygen: being in an obviously open, shallow dug-out space no longer misreads as "sealed" just because the one exact column checked still had rock in it — was causing sudden false suffocation right after digging a shallow hole.
- Pausing (Space) now actually stops the world clock — rain, torches, furnaces, day/night, and enemy spawns all freeze too, not just your character.
- Removed the Ctrl+Up/Down zoom attempt — it reused the wrong native tool, didn't work as "zoom in on my character," and could get stuck on; a real version needs an actual engine change.

## v1.2.0
- Trees: chopping no longer leaves floating trunk/canopy chunks that never despawn (a chop-created gap was breaking the felling flood-fill).
- Oxygen: now a real surface reservoir that diffuses down through dug shafts via the sim's own gas physics, instead of spawning randomly at any depth; detection no longer requires standing exactly on a sparse grid point.
- Oxygen: breathing now exhales real CO2 next to you, not just consuming O2 into nothing.
- Rain: standing water now soaks into ground/wood/grass over time instead of pooling forever, including on top of trees.
- Caves: reworked tunnel generation so passages wind and branch instead of reading as straight shafts; deeper topsoil layer before caves start.
- Space is the native TPT pause key — no longer double-bound to jump (W only); movement freezes while paused instead of quietly continuing.
- Chat/feedback text boxes now use real OS text input, so dictation/speech-to-text works in them.
- H2 and natural gas now rise and can pool at cave ceilings, matching real gas density (CO2 already sank correctly).
- Ctrl+Up/Down zooms in/out on your character using the native zoom lens.
- Version numbers are now plain semantic versions (e.g. 1.2.0) instead of a date string.
- The controls-on-join popup defaults off now (still toggleable from the Esc menu).
