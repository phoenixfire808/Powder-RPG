# RPG UI atlas — what every screen element looks like and exactly where it is

**Purpose:** so nobody has to interrupt Drew's game to take a screenshot just to find out how something looks.
Anyone who changes a drawn element MUST update its entry here in the same commit. Consult this file first;
only screenshot when you are verifying a change you just made, and never leave a panel open across calls.

TPT's own element-selection menus are hidden while playing (`R.setTptMenus(false)`, 16 menus); the Esc menu has
"TPT element menu on/off" to bring them back for sandbox building, and they are restored when the RPG stops.

Canvas: 612 x 384. Particles can only exist in x 4..607, y 4..379. Panel safe area `R.SAFE` = x 4..608, y 16..360
(TPT's own HUD/toolbar overlap outside it; core hides TPT's fps/pressure readout with `tpt.hud(0)`).
Text is ~6 px per character, 12 px per line. Colours below are r,g,b(,a).

## Always-on HUD (core, `onDraw` in rpg.lua)
| Element | Rect / anchor | Look |
|---|---|---|
| Health + status box | 4,4 → 254,34 (black 170a) | 10 hearts 9x8 starting at x 8, y 8, spacing 12; red 230,50,60; empty hearts outlined 120,60,60; numeric HP at x 130 |
| Oxygen bar | 8,18 → 124,21 | dark track, fill blue 90,170,255; turns red under 30%; label "O2 nn%" at x 128; "LOW OXYGEN" blinks at x 200 |
| Info line | 8,22 | "Day n day/night   x <pos>   <depth>m underground   <biome>   enemies ON" |
| Message log | 8,40 down, 12 px per line, max 5 | amber 255,230,140, fades over ~8 s |
| Hint (right of health) | 260,8 | pale blue one-liner: "+3 Dirt", "chipping...", "out of reach" |
| Goal banner | 258,20 → 498,32 | "GOAL n/15: <text>" amber on black |
| Debug (F1) | 260,20 | world/canvas coords, velocities, particle count, shift ms, last error |
| Hotbar (redesigned 18:22) | centred tray, 10 slots of 30x30 with 3 px gaps, total 327 px, at y = H-38; tray backing 8,9,16(205) with a 70,74,100 border | selected slot has a lighter fill, amber border and an outer amber ring; slot digit top-left; tools 1-5 are drawn glyphs (pick head + handle, axe, sword with crossguard, torch with flame, bucket); blocks 6-0 are a 16x16 material swatch with a black outline and a count badge bottom-right (999+ caps); empty/zero items dim to alpha 70 |
| Hotbar labels | centred above the tray | selected item name in amber on a black strip at y0-22, and a grey usage hint at y0-33 ("hold RIGHT mouse to place    [ ] size 3px") |
| Minimap (M) | 502,4 → 610,66 | black 170a box, 4 px cells per 64 px world tile, blue = above surface, grey = rock, red = near lava, white = player |
| Cursor highlight | at mouse | block selected: translucent fill in the block's colour + white outline over the exact cells (red when out of reach); pick/axe: thin white outline on the target block; kits: 15x13 amber outline. No reach circle, no grid lattice (removed 16:05) |
| Sky | above terrain line | per-4px columns tinted by day phase; sun/moon arc from the horizon, hidden behind terrain; stars at night; drifting clouds; grey when raining |
| Player sprite | at player, 5 px wide, 15 px tall | hair 110,65,30; skin 235,190,150; blue shirt (red flash when hurt); dark trousers; boots amber when Hermes Boots equipped; walk cycle with 4 frames and body bob; held tool drawn at the front hand; miner helmet, cloud puff, rocket flame, hook rope drawn when active |

## Esc menu (core, `drawMenu`) — rebuilt 18:14
Panel 8,18 → 604,358. Title bar 16 px, "POWDER RPG - MENU & CONTROLS" amber, "Esc closes" right-aligned.
- Controls help: two columns (left x 18, right x ~310), each entry = amber label + wrapped text at +54 px, 11 px lines.
  Left: MOVE / TOOLS / BLOCKS / SELECT. Right: BAG / VIEW / ITEMS / WORLD. Text is wrapped to the column width.
- SETTINGS label at 18,156. Buttons: 178x19, 2 columns, 8 px gap, 3 px rows, first at 18,168. Labels are clipped
  to the button width. Order: Resume, Save game (K), Enemies (N), Smart cursor (T), Snap grid (B), Minimap (M),
  HUD (H), Respawn (R), New world (random seed), Visual effects, Sandbox mode.
- STATUS column at x ~398: world/day, deaths (+SANDBOX), pick, sword, accessories/enemies, effects/grid, then
  "GOAL n/15" with the current goal wrapped underneath.

## Bag / inventory (ui.lua)
One shared panel rect (`BPX,BPY,BPW,BPH = 70,40,472,299`, i.e. 70,40 → 542,339) is reused for the BAG panel, the
quest log and (with its own CX,CY,CW,CH) the controls card - bottom edge sits exactly at H-45=339 to stay clear
of the redesigned centred hotbar tray. Opening any of the three sets `R.uiPanelOpen = true` (cleared when all
three are closed) so core hides its cursor highlight; opening also hides the minimap for the panel's duration
(restored on close) and force-closes the Esc menu. Held drag item ("hand") and search focus survive tab switches
but are returned/cleared automatically if the panel closes mid-drag.

**Header/tabs** (y 42→56, inside the panel): title "BAG" at 78,45. Four tab buttons, each 64 wide: ITEMS 130→194,
RECIPES 200→264, GUIDE(L) 270→334 (not a real tab - closes the panel and calls `R.openGuide()`, or shows greyed
with a "press L" tooltip if guide.lua isn't loaded). "E / Esc closes" right-aligned at BPX+BPW-96.

**ITEMS tab - CARRIED/CATALOG sub-tabs** at 80,64→148,77 and 154,64→222,77 (68 wide each).
- Search/Sort/Trash row (CARRIED only), y 80→93: search box 80,80→250,93 (170 wide, amber border when focused,
  shows typed text + "_" cursor); SORT button 256,80→296,93; DEL trash slot 508,80→532,93 (red).
- Slot list: full-width rows at x 80, starting y 98, row height 14, one row per occupied `R.invSlots` index
  (CARRIED, search-filtered) or per catalog element (CATALOG, read-only reference incl. every `R.ITEMS` pseudo-item
  from other plugins). Row = 8x8 colour swatch, name, dim "(CODE)" secondary label, "xN" count, "[slot]" badge
  in gold if that element is on the hotbar. Visible row count = floor((339 - 78 - 98) / 14) = 11, same reserve
  for both sub-tabs (the accessory rows + footer line below are always drawn regardless of which one is active);
  ^/v scroll buttons + "n/total" counter appear top-right (y 82) when the list overflows.
- **Click model (fixed 19:42 - was the "can't put it on my hotbar" bug)**: plain left-click on a CARRIED row with
  an empty hand is the reliable no-drag path - it sends the item straight to the selected hotbar slot (or slot 6
  if none is selected), same as CATALOG's always-worked click-to-assign. Shift+click (or hovering + a 6-0 key)
  auto-picks the best hotbar slot instead of the currently-selected one. Right-click (or drag) picks up a
  half-stack for the advanced path - drop it on another row (place/merge/swap), the DEL slot (delete), or any
  hotbar slot; a hotbar drop works both as a continuous drag-release *and* as a separate second click (both are
  hit-tested in `mousedown` now, not only in `mouseup` gated on the same press), and always clears the held
  hand afterward - it used to succeed silently while leaving the item stuck to the cursor forever.
- Equipment (drawn under both sub-tabs; only interactive from CARRIED), 2 rows starting at y = 277, full
  item-list width, 9 equal slots
  (≈46 wide, 4px gap) for `R.ACC_ORDER`: EQUIPPED row 277→305 (28 tall, label at 265), BAG/unequipped tray
  309→325 (16 tall, label at 299) - drag between the two rows to equip/unequip (or just click, which toggles
  immediately and still lets you drag to confirm/reverse); dragging highlights the valid-drop row border (green
  for EQUIPPED, blue for BAG). Locked (never-found) slots show a dim "?" in both rows.
- Footer line "TOOLS ... Deaths ... Day ..." at y = BPY+BPH-12 = 327.

**RECIPES tab**: material-filter chips wrap-flowing from 80,66 (row step 14, chip height 12, click to toggle a
filter); rows start 16px below the last chip row, each 26 tall - header rows (station name, e.g. "WORKBENCH")
are 13 tall inside that same step; a recipe row (not pick/sword) gets an "x5" batch-craft button, 26 wide, at
the panel's right edge (532-26=506); anywhere else on the row = craft x1. ^/v scroll + "n/total" bottom-right.

**Tooltip box** (`drawCursorTip`, used everywhere - hotbar, zoom palette, bag rows, recipe rows, accessory
slots): anchored 14px right of the cursor (flips to 14px left if it would run off the right edge at W-4), width
210 by default; header line in amber, body lines at 12px each; vertically clamped to y 4..(H-45-height) so it
never dips under the hotbar tray.

**Hand/drag cursor**: while holding a stack or an accessory, a 10x10 swatch is drawn at the mouse position with
its name/count and a one-line instruction below-right; material drags accept L-click (place/merge/swap) or
R-click (place one) on any bag row, the DEL slot, or a hotbar slot (assigns it there without spending the stack).

## Guide / database (guide.lua, key L or the GUIDE button)
Three columns inside `R.SAFE`: category tabs (Materials, Ores & Depths, Tools, Stations & Processes, Machines,
Weapons & Gadgets, Accessories, Creatures, Biomes, Controls) | searchable entry list with scrollbar | generated
entry page with clickable cross-links, BACK button and breadcrumb. Wheel scrolls the column under the cursor.
Public API for other plugins: `R.openGuide()` (resume where left off), `R.openGuide("weapons")` (jump to a
category), `R.openGuide({cat=..., id=...})` (jump to one entry); `R.closeGuide()`. Callers close their own
panel first - guide.lua doesn't do that for them.

**TAKE button** (added 18:30 per Drew - "put it in my hotbar" from the guide): a bright green 44x12 button at
the top-right of the page header row (COL3X+COL3W-44 → COL3X+COL3W, y = BY → BY+12), shown only when the open
page is a real inventory-able code - Materials, Ores & Depths, Machines, Weapons & Gadgets, or a Stations &
Processes item other than "By hand" (`isTakeable(cat,id)` - excludes Tools/Accessories/Creatures/Biomes/Controls,
none of which live in `R.inventory`/hotbar slots 6-0). The breadcrumb text shortens to make room for it
(`crumbMax` shrinks by 48px worth of chars) and swaps to a one-line contextual hint - "Sandbox mode: TAKE puts
any material in your hotbar (999, free slot)" or, outside sandbox, "TAKE: only works for materials you already
own" - while the button is hovered. Clicking it (or double-clicking the same entry's row in the middle list
within ~20 frames) calls core's `R.grantItem(id)` and then `R.closeGuide()` so the hotbar change is immediately
visible. The same "Sandbox mode: TAKE puts any material in your hotbar." line is also always present as the
last line of the "?" help tooltip (which grew from 58 to 76px tall to fit it) so the mechanic is discoverable
without needing to land on a takeable page first.

## Zoom / detail mode (core)
When TPT's zoom window is locked open: a label under the window reads "DETAIL: left dig / right place Npx,
wheel = size"; a palette strip of everything in the bag is drawn above the hotbar (24x24 swatches, 26 px apart,
click to select); the cell under the cursor is outlined in yellow.

## Machines (machines.lua)

**Boiler physics, rewritten for real 19:58 (Drew: "I actually want to see the steam... it all needs to work
for real"):** the old round-vessel boiler had a real bug - its decorative ring geometry left an actual gap of
solid wall material between the coal bed and the water charge, so nothing ever conducted. Rebuilt as ONE
continuous rectangular chamber (grate -> 2-row coal bed -> water, each row touching the next with zero gap) so
TPT's own heat engine and WATR's real 373K HighTemperature transition do all the work - nothing here creates or
fakes a steam particle. Ignition is a real sustained ember (a FIRE particle re-created every 6 frames at a fixed
point, exactly like the player's own placeable torch item in core/rpg.lua's `updateTorches` - COAL in this
session has `Flammable=0` and `HighTemperature=10000`, a deliberate realism-patch choice, so it never
self-ignites or burns on its own; a continuously-refreshed real heat source pinned to the bed is the only
physically honest way to sustain it). Fuel is real: `m.fuel` ticks down every frame while lit and is sized from
the actual COAL particle count in the bed at light-time (`TICKS_PER_COAL = 900` ticks/cell), so a bigger bed
genuinely burns longer, and running dry stops the ember and visibly clears the (now ash) bed. `R.setFast(false)`
switches real air/pressure simulation on for as long as any boiler/turbine/reactor/blast-furnace/gas-turbine
exists (`syncFastMode`), and back off the moment none do.

**Verified live in the LAB INSTANCE (port 9877), not the main game, by reading real particles back:**
- An isolated METL(1200K)+WATR(295K) contact pair equalised to the exact average (747.5K) within one sample and
  the WATR was gone (evaporated) one sample later - confirms direct-contact heat conduction and the real 373K
  phase change both work in this session.
- The lab instance has NO custom power elements defined at all (`STEL`/`CU`/etc. all `nil` - only the main game
  ran `define_power_elements.py`). The boiler's shell used `STEL` exclusively, so in the lab it silently built
  no walls whatsoever (`setAt` no-ops on an undefined element) and the water drained away untouched - this was
  the actual root cause, not a heat-conduction bug. Fixed with the same `R.has(name) and name or "METL"` fallback
  pattern `WMAT`/`LAMPEL` already used, as a new `VMAT` local, so the boiler (and anything else that adopts the
  pattern) degrades gracefully with only stock elements. Flagging for whoever owns lab_instance: real parity
  with the main game's custom element set would remove this whole class of false negative for future testers.
- With `VMAT` fixed: built a fresh boiler, lit it for real (the panel's Light-firebox button, which now counts
  real coal and sets `m.fuel`), and sampled the chamber every ~2s for a minute+. Water temperature climbed from
  295K to a fluctuating 330-450K band, repeatedly crossing 373K; real `WTRV` particles appeared (1-3 at a time)
  every time it did. Total water charge (50 cells) fully boiled away over roughly 10 minutes, in step with the
  fuel countdown (a 20-coal bed also lasts ~10 minutes at `TICKS_PER_COAL=900`) - a real boiler that needs
  re-filling and re-lighting, not an infinite one.
- Piped a real connecting duct (hand-laid METL, matching what a player does by hand) from the boiler's vent
  mouth to a turbine's intake and continued sampling: the turbine's real hit counter (`m.hits`, the same
  WTRV->WATR conversion count that drives its wattage) incremented from 0 to 1 the moment real steam reached
  it - the full chain boiler -> real steam -> piped -> turbine -> watts is confirmed physical end to end.
- Known gap: the un-piped gap between a boiler's vent and a turbine placed nearby is NOT auto-connected - a
  player (or a future automation pass) must lay a real pipe between them, same as the original turbine's own
  "pipe steam into the intake" instruction has always implied.

Every machine is a real particle structure (not a sprite) - shapes below are built with `ring(cx,cy,r,el,thick)` /
`disk(cx,cy,r,el)` / `clearDisk` (circle helpers) plus `boxFill`/`clearBox`. Coordinates are world px, `gy` = the
ground row under the click point, `wx,wy` = click point in world coords. Rewritten 17:38 per Drew: "the turbine
looks like just a block" - every generator/consumer now reads as a distinct shape, not a box.

**Interaction (19:34/19:37/19:38 — machines must read as clickable, not decoration):**
- Proximity affordance: every machine with an `MBOX` entry (all of them except pure-decoration cells) gets a
  pulsing amber rectangle outline (`graphics.drawRect`, alpha oscillates 140-230 via `sin(frame*0.06)`) drawn
  around its visual centre once the player is within its interaction radius + 22px, plus a floating
  `[right-click] <Name>` label above it. `MBOX[kind] = {dx,dy,r}` (offset from `m.x,m.y` to the shape's centre
  + radius) or the string `"ring"` for the round generators (turbine/wheel/flywheel), which instead use their
  own `cx,cy,r` fields.
- Right-click on a machine (hit-test via `machineAt(worldX,worldY)`, same MBOX data) opens `R.machinePanel = m`
  and sets `R.uiPanelOpen = true`; right-click again (or a click outside the panel isn't needed - clicks inside
  the panel are swallowed) closes it. Crate keeps its own pre-existing dedicated panel (`R.cratePanel`) - the
  generic panel skips crates entirely so the two never collide.
- Panel (drawHUD, rect 190,40 → 426,216, amber border, same visual language as the crate panel): title bar with
  the machine name (left) and a coloured state word (right - green RUNNING/HOLDING CHARGE, amber
  IDLE/STOPPED/EMPTY, red STARVED/BLOCKED/UNLIT/NO WATER/TRIPPED); an INPUTS section (live values - "Coal bed:
  unlit", "Power 0W avail / 15W needed", "Charge: 40/80"); an OUTPUTS section (live values - "Power: 12W",
  "Turns wood into charcoal"); a NEXT line in amber that is always present and always imperative ("Light the
  coal bed with the button below", "Wire it to a generator with copper/iron wire", "Working - no action
  needed"); then a row of real clickable buttons (raised rect, lighter fill + brighter text on hover via a live
  `R.mouse` hit-test, disabled buttons render dim and `R.say` their reason instead of acting). Every gen/load
  machine gets a universal Start/Stop button (`m.disabled`, respected by `gridPowered`/`recomputePower` so a
  stopped machine truly does nothing); the boiler additionally gets Light firebox (raises real temp on the fire
  cell) and Fill water (spawns a real WATR charge, disabled unless the bucket - slot 5 - is equipped); a tripped
  breaker gets Reset. `inspect(m)` (the function computing all of the above) is read-only by contract - it must
  never call `genWatts` live or mutate sim state, since it can run every single frame while hovered/open; every
  generator's live wattage is read from `m.lastWatts`, a cache `recomputePower` already writes once per 15-frame
  cycle for every gen-role machine (this cache is also what the on-machine gauge bars read now, replacing an
  earlier live-genWatts call that was silently burning real fuel from gas turbines/fuel cells just by rendering
  their gauge - fixed 19:41).
- Verified live end-to-end (not just code-reviewed): built a boiler, simulated a real right-click on it via the
  bridge, confirmed `R.machinePanel`/`R.uiPanelOpen` flipped, screenshotted the panel showing real INPUTS ("Coal
  bed: unlit", "Water charge: present") and the correct NEXT line, then clicked both buttons via the bridge and
  confirmed the real particle state changed (fire cell temp 297K -> 700K, a real WATR particle appeared in the
  vessel) before cleaning up.
- Known gaps, deferred: full physical rescale ("a boiler should feel like 3-4 player-heights", Drew 19:37 point
  4) not done this pass - shipping 1+2 (proximity + panel) first per Drew's own instruction; visible pipe-flow
  animation (fluid moving through pipes, not just the machine's own moving part) is only partial (steam
  puffs/flame flicker exist, a generic "fluid pulses along any pipe" effect does not yet).

**Shared overlays (draw hook, all kinds with a grid role):**
- Power dot: 2px filled circle at the machine's wire terminal (its `output`/`pad`/`core` field). Generators: green
  `90,255,90` while their grid's `gen>0`, else red `90,60,60`. Consumers: green while `poweredAt` (real adjacent
  SPRK) AND the grid has enough supply, else red. Storage: green while `stored>0`.
- Name label: amber `255,230,150` text 2px left / 24px above the machine, drawn only when the player is within
  160px AND the label's y would land above the hotbar tray (`y-24 < H-42`) - never drawn into the tray.
- Output/charge gauge: 20x3px bar 18px above the machine (drawn only within 160px of the player): amber
  `250,210,90` fill for generators (scaled to a per-kind max: crank 6, wheel 30, solar 16, teg 20, turbine 60,
  reactor 120), blue `120,220,255` fill for storage (fraction of `cap`). Track is dark `30,30,40`.
- Power grid HUD panel: 8,278 → 218,332 (sits just above the hotbar tray), dark box with a light-blue border.
  Shows the grid nearest the player (only while within 240px of one of its members): "gen NW  load NW" line, a
  20x8 stored/cap bar (amber fill), and "stored n/cap  STABLE" (green) or "BROWNOUT" (red) underneath.

| Machine | Shape (materials) | Size | Animated overlay |
|---|---|---|---|
| Boiler (BOILER) | BRCK firebox with a BRMT (bronze) grate row and a COAL bed on top of it; a round STEL ring vessel (2px wall) sits on the firebox roof, hollow inside, with a 9px-tall GLAS sight-glass strip on its left face showing a real WATR charge; a hollow METL chimney flue (1px wide) runs from the vessel's open top up through a wider METL cap - the bucket pours down this flue; a real hollow METL pipe runs off the vessel's right shoulder as the steam takeoff | firebox 14x5, vessel r=8 (~18 wide), chimney 6 tall, pipe 6 long | Flame glyph "^" flickers amber over the firebox while something >600K/FIRE sits in it; steam puff "o" rises from the takeoff pipe mouth every 20 frames while venting |
| Turbine (TURBINE) | Round STEL ring housing (r=7, 2px wall) on a STEL pedestal shaft down to the ground; METL rotor hub (r=2) at the ring's centre with 4 METL blade nubs at r-4 (the real steam-hit targets); METL intake nozzle pipe punched through the left wall, METL exhaust nozzle punched through the right wall; PSCN output stud on the pedestal base | ring ~18 wide x 18 tall + pedestal, nozzles +4px each side | 4 lines radiate from the hub and rotate every draw frame at `spinSpeed` (0 to 0.6 rad/frame, scaled from real steam-hit count that recompute cycle) - stationary blades = unpowered, visibly spinning = generating |
| Door (DOORKIT) | METL frame post; a 2-wide x 6-tall METL slab; PSCN control pad beside it | 2x6 slab | none (blocks vanish/reappear on power, no tween) |
| Water pump (PUMPKIT) | Small round STEL body (r=3) with a METL impeller-hub dot at centre, PSCN pad on top; real hollow METL pipe runs left to an open intake mouth (with a METL catch-ledge) and right to an open outlet mouth (same ledge) | body r=3, pipes 6px each side | none yet (impeller dot doesn't spin - candidate for a future pass) |
| Conveyor (CONVEYOR) | Straight strip of BMTL blocks, 8 long | 8x1 | none |
| Crate (CRATE) | Small hollow WOOD box | 4x4 | none (right-click panel, see below) |
| Lamp (LAMPKIT) | Single LEDL (or LCRY) cell - now tracked as a machine (`kind="lamp"`, `core`=its own cell) so it gets a power dot | 1x1 | glows via its own real element behaviour when lit |
| Hand crank (CRANKKIT) | WOOD post, hollow, PSCN handle stud on top | 5x6 | short white line at the handle rotates while the player holds F within 24px (`m.turning`) |
| Water wheel (WHEELKIT) | WOOD ring (r=6, real spoked-wheel silhouette) on a METL axle-mount frame down to the ground, METL axle hub at centre, PSCN stud at the base | r=6 (~14 wide) + mount | 6 lines radiate from the hub and rotate at `spinSpeed` scaled from the real average speed of adjacent WATR particles sampled at 6 points around the rim |
| Solar panel (SOLARKIT) | Stepped-diagonal PSCN backing under a GLAS face, reading as a tilted panel; METL mounting leg; CU stud at the high corner | 7 wide, 6 tall | none (tilt is static); gauge reads the real day/night sun-angle formula and needs open sky above the panel (checked 30px up) |
| Thermoelectric generator (TEGKIT) | CNCR housing block with 2 real TEG element cells exposed on top (must touch something hot - lava/fire); CU output stud | 4x4 | none scripted - the TEG element's own behaviour (power_kinds.lua) pulses real SPRK once >373K; gauge reads its live temperature |
| Battery bank (BATTERYKIT) | STEL case, hollow, with one internal STEL divider wall (visible cell split); CU terminal (left) and PSCN terminal (right, the wire pad) on top | 8x5 | charge gauge (blue) shows `stored/cap` |
| Capacitor (CAPACITORKIT) | Small GLAS block (3 wide) with a CU stud on top | 3x4 | charge gauge (blue), tiny cap (40) so it visibly swings fast |
| Electric furnace (EFURNACE) | Hollow STEL box, PSCN pad on top | 6x6 | none (smelts silently from the bag while powered) |
| Ore crusher (CRUSHERKIT) | STEL hopper funnel (narrows downward) on top with a PSCN pad on its rim; two METL roller disks (r=2, touching) below the hopper throat; STEL body/frame beneath; a small STEL output chute off to the side | 11 wide, 9 tall | none (rollers don't spin yet - candidate for a future pass) |
| Autocrafter (AUTOCRAFTKIT) | Hollow STEL box, PSCN pad on top | 7x7 | none (works on a nearby crate's contents while powered) |
| Defence turret / Mk2 (TURRETKIT / TURRETKIT2) | STEL base block with a raised STEL barrel post and a PSCN pad on top | 3x7 | none yet (fires via `R.damageEnemiesAt`, no muzzle flash overlay) |
| Mining drill (DRILLKIT) | Hollow-free STEL box, PSCN pad on the side it mines toward | 4x4 | none (mines silently one MINEABLE-tier hit at a time while powered) |
| Fission reactor (REACTORKIT) | Three-bay complex, ~33 wide x 20 tall. **Part A (fuel lattice)**: CNCR shell with a LEAD roof cap (shielding kept on the coolest, outermost face); 4 alternating columns of ZIRC-clad UO2 fuel rods and solid B4C control rods; a GRPH moderator floor under the lattice; a NAK coolant bath filling the chamber below the floor; a TEG tapped through the west wall with a CU stud (waste-heat scavenger). **Part B (boiler)**: CNCR shell sharing a single STEL heat-exchange wall with the NAK bath (real particle-to-particle heat conduction does the work); a WATR charge; a steam vent breach. **Part C (turbine)**: a small STEL ring housing (r=4) across the vent holding 3 real TRBN elements (genuine `tmp` work-counter, not scripted) and a CU output stud | see above | Part C's hub gets the same 3-line rotating-blade overlay as the standalone turbine, scaled from real TRBN `tmp` deltas; `m.online`/`m.sparkedEver` flip once it's actually producing |

**Oxygen chain round 2 (20:38, "we really need mechanics to harvest oxygen"):** core shipped the early-game
entry point itself (an Air Bladder/`FLASK` item, craft-by-hand, auto-feeds the player below 45% air, `R.flask`
reserve). Machines.lua's job was the production chain above it:
- **Bellows** (`BELLOWSKIT`, hand tier, no power): WOOD box + a short duct stub. Hold F within 24px to hand-pump
  - refills `R.flask` at 6/frame (real bladder-fill state, same variable core's own passive fill uses, just much
    faster) and pushes real `OXYG` particles along the duct via `vx`. Registers a `R.o2Sources` entry only while
    actually being pumped (matches "manual, not automatic").
- **Air line** (`AIRLINEKIT`, workbench): drag-placed exactly like `WIRECOIL` (same bresenham continuous-line
  code, reused as `placeAirline`), laying real `BMTL` duct segments. Every tick, `syncO2Sources` walks the
  segment list from the source end and stops at the first missing particle - a mined-out or exploded segment
  really does cut the air off beyond that point (`m.intact`) - and registers one real oxygen source every 6
  intact segments along the run, not just a single point at the end.
- **Compressor** (`COMPRESSORKIT`, anvil, 10W, unlocked at the same milestone as the electric furnace): round
  STEL/METL body with a real air intake breach. Powered, standing close with a bladder or an equipped `OXYTANK`
  (@items' existing Oxygen Tank, `R.itemsO2Charge`), it consumes one real `OXYG` particle at its intake and
  credits +40 tank charge / +20 bladder charge - genuinely fed by whatever supplies real OXYG nearby (an
  electrolyser or an air line), not a free top-up.
- Every life-support machine's panel (airpump/o2gen/scrubber/compressor) now shows a real "Room: sealed / open
  to sky" line (`roomSealed`, the same vertical-probe check core's own breathability calc uses) plus its real
  O2 l/s rate, and bellows/air-line get their own dedicated INPUTS/OUTPUTS/NEXT text (bladders owned + pumping
  state; segments intact + where it's cut).
- Verified live in the lab (port 9877): built all three, held F near the bellows for 1.5s and watched `R.flask`
  rise from 0 to 35 in real time; laid an 11-segment air line and confirmed `m.intact==11` and exactly 1
  `R.o2Sources` entry registered (floor(11/6)); compressor code-reviewed against the identical, already-verified
  o2gen intake pattern but not individually fed a live OXYG particle in this pass - flagged, not claimed proven.
- Deferred (not started this pass, logged not dropped): the full "sealed room reads as safe" HUD summary (today
  it's per-machine, not a whole-room verdict) and a shallow-dig auto-duct from the bellows.

**Second wave (18:36-19:05, "way way way more machines" - life support/processing/power/logistics/utility):**
15 more kinds shipped with the same standard (real structure, grid role where applicable, MBOX interaction
entry, atlas-worthy but full per-machine rows deferred to the two hub commit posts for space - see
`git log --grep "second wave"` or the 19:05 hub entries for exact shapes/materials): air pump, oxygen generator
(electrolysis), CO2 scrubber, greenhouse (passive), sawmill, desalinator, blast furnace, RTG (always-on, UO2/
B4C/TEG line, no grid dependency), flywheel (storage, spins faster with more charge), breaker (kills its own
bridge cell on overload, real conductor break), item elevator (vertical vx-injection like the conveyor), tunneler
(a drill that advances forward each successful hit), sprinkler (real fire suppression), lightning rod (rain-
gated), gas turbine (burns real HYGN/OIL/GAS). All have `MBOX` entries so the interaction system above covers
them for free.

Verified live 2026-08-26: every shape above was built via a direct `R.hooks.place` call and its particle grid was
sampled immediately after (same script, before the camera could scroll it out of the live sim) - turbine ring/hub/
4 blades, boiler dome+grate+glass, crusher hopper/rollers, battery case+divider, capacitor glass+stud, wheel
rim+hub+axle, and the reactor's alternating UO2/B4C lattice + NAK bath + mini turbine ring all matched their
intended layout exactly. Rotation/animation logic was code-reviewed but not confirmed against a real steam flow
(`graphics.*` calls only work inside a real draw event, not a synthetic bridge call, so the spin can't be unit-tested
- watch for stationary blades on a machine that should be producing as the one thing still worth a live screenshot
check next time anyone is nearby one under real load).

## Machines2 (machines2.lua) - second machine track: chemistry/fluids/logistics/exotic/comfort, own `R.machines2`
Separate from `R.machines` (owned by machines.lua) so there is zero collision risk between the two files' kind
strings or bookkeeping. Power convention differs deliberately from `R.power.grids`: a machines2 machine just checks
for a real live SPRK sitting on/adjacent to its own pad every tick (`poweredAt`, same idea `R.power.grids` itself
is built on) - so anything wired into the same physical wire network machines.lua runs is actually live here too,
with no code coupling to that file. Interaction: same look as machines.lua's panel (never open at the same time -
only one machine can be targeted at once) - near-only "[right-click] Name" prompt within 70px, right-click opens a
panel at 190,40->426,170 with a coloured NAME header, one "State: ..." line, and a wrapped imperative NEXT line;
right-click again (or on empty space) closes it. `MBOX2[kind] = {dx,dy,r}` drives both the hint and the hit-test.

**Stage 1 - Chemistry (shipped 2026-08-26):** all five verified live in the lab (port 9877): built via a direct
`R.hooks.place` call, particle grid sampled immediately after, then the actual reaction seeded (real reagent
particle + a real spark converted in place on the pad, exactly how the native spark tool works) and re-sampled to
confirm the output particle actually appears. Two real bugs were caught and fixed this way, not just read back:
(1) `R.eid()` silently no-ops `setAt` for any material name it can't resolve - a session that hasn't run
`scripts/define_power_elements.py` (true of the lab at time of writing) has no custom STEL/CU/CNCR, so every
structural use of those three now resolves through `STEELMAT`/`WMAT`/`CNCRMAT` fallback locals (real BMTL/METL/STNE)
exactly like machines.lua's own `WMAT`/`LAMPEL` pattern; (2) the electrolysis cell's gas vents were built out of
conductive METL sharing the same live spark as the electrodes - the real HYGN ignited/vanished and the real CAUS
corroded away the instant either was created touching it, so both vent pipes are real GLAS (non-conductive,
acid/spark-safe lab tubing) instead.

- **Electrolysis Cell** (`ELECTROLYSISKIT`, anvil, tier 10W) - a BMTL/steel tank (7x6) with an open brine well,
  two METL electrode rods dipped into it either side of the well column, a GLAS sight strip on the front wall, and
  two GLAS vent tubes venting up and out to either side. Pour real SLTW into the well, wire the PSCN pad (front-
  right) to a live grid: every ~40 frames it kills one SLTW in the well and creates real HYGN out the left vent +
  real CAUS (acts like ACID) out the right vent - genuine chlor-alkali electrolysis, distinct from machines.lua's
  O2GEN (which electrolyses fresh WATR for life support, not brine for gas synthesis). MBOX2 `{3,-5,9}`.
- **Acid Synthesizer** (`ACIDSYNTHKIT`, anvil, tier 10W, no power needed) - a BRCK firebox with a real COAL bed
  (light with the torch) under a QRTZ-lined retort (open charge slot, GLAS sight strip), a QRTZ drip nozzle (not
  metal - real ACID corrodes metal) feeding a GLAS-walled basin. Drop real SALT + real WATR into the retort's two
  open cells; once the bed is real FIRE, every ~60 frames it consumes both and drips real ACID into the basin.
  MBOX2 `{3,-6,10}`.
- **Salt Evaporator** (`EVAPORATORKIT`, workbench, tier 10W, passive/no power) - a BRCK firebox with a real COAL
  bed under a shallow concrete pan (raised end lips so crystals don't scatter off the sides). Light the bed, pour
  real SLTW into the pan: any SLTW cell over 373K is killed and replaced with real SALT, venting a real WTRV puff
  upward - genuine per-particle evaporation, same "real heat threshold transmutes the particle" idiom as the blast
  furnace's DU->URAN. MBOX2 `{2,-4,8}`.
- **Fertiliser Mixer** (`FERTMIXERKIT`, workbench, tier 10W) - a WOOD housing with an open top hopper over two
  METL grinding roller disks (PSCN stud shaft), WOOD chute below. Wire the side pad; while powered it vacuums up
  any real PLNT or STNE sitting in the hopper (roller graphic sweeps while running) and every 2 of each gives one
  Fertiliser (`R.ITEMS.FERTILISER`, pseudo item, col `{110,80,50}`). MBOX2 `{3,-4,9}`.
- **Gunpowder Mill** (`POWDERMILLKIT`, anvil, tier 10W) - a METL ring drum with an open top charge slot and a PSCN
  grinding stud inside, PSCN pad on the housing side. Wire it; while powered the drum visibly spins (draw-hook
  overlay) and every real COAL dropped in the slot is ground down, 2 COAL -> 1 Gunpowder (`R.ITEMS.GUNPOWDER`,
  pseudo item, col `{60,60,65}`, a crafting reagent for future ammo). MBOX2 `{0,-5,8}`.

**Stage 2 - Fluids (shipped 2026-08-26):** per Drew's 21:20 "stop deep-testing, ship volume, I'll test it myself"
note - each confirmed with a lean lab check (plugin reloads with `pluginStatus.machines2 == "ok"` and no
`pluginErr`, every recipe appears in `R.RECIPES` with a real desc, materials resolve through the `STEELMAT`/`WMAT`/
`CNCRMAT` fallbacks) plus one quick placement smoke test per kit, not the full seed-a-reaction-and-read-it-back
pass stage 1 got. That smoke test still caught two real bugs worth recording: `sim.pressure(x,y)` is indexed in
4px PRESSURE CELLS, not pixels, and throws a hard Lua error outside its own grid range (not a safe-nil like
`sim.partID`) - every call now goes through a `readPressure(wx,wy)` wrapper that converts + bounds-checks first.

- **Check Valve** (`CHECKVALVEKIT`, workbench, base tier, no power) - a short steel block with a horizontal
  channel through the middle and a PSCN flap marker. Real liquid/gas flowing with the valve's built-in direction
  (set from the player's facing at build time) passes untouched; anything with velocity against that direction has
  its `vx` zeroed every tick - a genuine one-way gate, not a flag. MBOX2 `{2,0,6}`.
- **Pressure Vessel** (`PRESSVESSELKIT`, anvil, base tier) - a sealed steel ring shell (r=4) with a hollow interior
  and a PSCN inlet nub at the base. Every tick it reads the REAL pressure field at its own interior cell
  (`readPressure`); past 6.0 it genuinely ruptures once - kills a real section of its own shell and vents real
  FIRE through the breach. One-shot; rebuild it after a rupture. MBOX2 `{0,-4,9}`.
- **Reservoir Tank** (`RESERVOIRKIT`, anvil, base tier, passive) - a tall steel box (5 wide, 8 tall) with an open
  interior liquid column (open top intake, open bottom spigot) and a GLAS sight strip on the side wall, clear of
  the column. The panel's State line reports a real fill percentage from counting occupied cells in the column.
  MBOX2 `{0,-5,8}`.
- **Steam Condenser** (`CONDENSERKIT`, anvil, base tier, passive) - a steel housing with an open-top intake
  chamber and a sealed internal FRZW cold-coil reservoir. Real WTRV poured into the intake is actively chilled 25K
  per tick; once genuinely below 373K it's converted in place to real WATR (same "real threshold transmutes the
  particle" idiom as the salt evaporator, run in reverse), which then falls under real gravity to the spigot
  below. MBOX2 `{0,-5,9}`.
- **Drainage Sump** (`SUMPKIT`, anvil, base tier) - a sunken METL pit (open top, collects real flood WATR) with a
  power pad and an outlet spout leading up and out. Powered, once 3+ real WATR cells pool in the pit it ejects one
  per cycle out the spout with real outward velocity - the same vx-injection idiom the conveyor/elevator already
  use. MBOX2 `{0,-2,8}`.

**Stage 3 - Logistics (shipped 2026-08-26):** lean-check pass (loads clean, recipes present, materials resolved,
one placement smoke test per kit) - the smoke test caught a real bug: the Silo's table only carried `y1`/`y2`
(its liquid-column bounds), not a plain `x`/`y` centre, and the shared proximity-hint code (`nearPlayer(m.x,m.y)`)
crashed the instant a second machine was on screen with it. Every machine's table now visibly carries a plain
`x`/`y` regardless of what other bounds it also needs - worth grepping for on any future addition.

- **Sorter** (`SORTERKIT`, workbench, base tier, no power) - a steel block T-junction: a straight-through lane on
  the left, a side chute on the right, PSCN sensor stud at the junction. Any real ore-tier particle (IRON/GOLD/CU/
  DU/QRTZ/DMND/URAN) reaching the sensor is teleported into the chute (`sim.partPosition`) and given a little
  downward push; everything else just falls straight through untouched. MBOX2 `{0,-2,7}`.
- **Splitter** (`SPLITTERKIT`, workbench, base tier, no power) - a steel block with one top intake and two bottom
  lanes. Alternates every real particle that arrives between the left and right lane, one at a time (`m.toggle`),
  real sequencing rather than randomness. MBOX2 `{0,-2,7}`.
- **Vacuum Collector** (`VACUUMKIT`, anvil, base tier) - a small METL/WMAT ring housing (r=3) with a PSCN core
  stud and a PSCN power pad. Powered, every tick it nudges the velocity of any real loose powder within 24px
  toward the core (genuine attraction, not teleport) and bags whatever reaches the core. Deliberately NOT the
  native VACU/BHOL element - that one also generates real heat and is much harder to keep contained at a small,
  predictable radius, not worth the risk on Drew's world after today's stack-overflow incident. Pulsing ring draw
  overlay while powered. MBOX2 `{0,0,9}`.
- **Silo** (`SILOKIT`, anvil, base tier, passive) - a tall METL box (5 wide, 10 tall) with an open interior column
  (open top and bottom) and a 5-lamp LEDL/LCRY indicator column on the side (unlit decoration for now - lighting
  it from real fill % is a natural follow-up). Panel's State line reports real fill % from the column. MBOX2
  `{0,-6,8}`.
- **Quarry** (`QUARRYKIT`, anvil, base tier) - a METL housing with a PSCN pad, no visible shaft until it starts
  digging. Powered, it automatically mines a real 5-wide column straight down beneath itself one real hit at a
  time (same `R.MINEABLE`/`R.HARD` hit-count idiom as the drill/tunneler), giving ore to the bag and tracking
  real depth. A small draw-hook marker line shows the current dig front while powered. MBOX2 `{0,-3,8}`.

**Stage 4 - Exotic/Physics Toys (shipped 2026-08-26):** lean-check pass. This pass's own code-review (not the lab)
caught a real bug worth remembering: `hook()` de-dupes by tag PER LIST, so registering `R.hooks.newworld` a
SECOND time anywhere else in the file silently deletes the first registration - this file had done exactly that
(one `newworld` hook resetting `R.machines2`, a second one later just reinstalling recipes), so the `R.machines2`
wipe-on-new-world had never actually been firing. Consolidated into the one `newworld` hook next to
`installRecipes2()`; confirmed via `R.hooks.newworld` only carries one `machines2`-tagged entry now.

- **Gravity Manipulator** (`GRAVMANIPKIT`, anvil, base tier, passive) - a small steel housing with an open
  column and the real native `WHOL` identifier sunk into the floor (in this build it resolves to the vent-style
  "creates pressure, pushes particles away" element - deliberately not the destructive SING/negative-pressure
  element). Loose material dropped into the open column above it gets pushed/lifted by real pressure. MBOX2
  `{0,-3,7}`.
- **Portal** (`PORTALKIT`, anvil, base tier, craft gives 2) - places a real PRTI/PRTO end, alternating IN then OUT
  each time the kit is used, channel-matched via a shared `temp` value (300+channel) exactly like WIFI's channel
  convention. Real material dropped into the IN end appears at its linked OUT end. `R.portalChannel`/
  `R.portalPending` track the in-progress pairing and reset on new world. MBOX2 `{0,-1,5}`.
- **Magnetic Accelerator** (`MAGACCELKIT`, anvil, base tier) - an 8-long alternating PSCN/NSCN rail barrel with a
  PSCN pad behind the breech. Powered, any real particle sitting in the breech gets one strong velocity boost
  (`vx = dir*9`) down the barrel on a cooldown - a genuine linear-rail cargo launcher. MBOX2 `{4,-1,8}`.
- **Cryo Chamber** (`CRYOKIT`, anvil, base tier) - a sealed steel housing around a real FRZW cold-coil core.
  Powered, it registers `{x,y,rate=30,range=70}` into the real shared `R.coolers` registry every cycle (rebuilt
  from scratch each tick, same idiom as `R.o2Sources` - an unpowered/destroyed chamber's cooling disappears
  immediately). MBOX2 `{0,-4,8}`.
- **Weather Machine** (`WEATHERKIT`, anvil, base tier) - a steel ring antenna mast with a PSCN tip and power pad.
  Powered, it forces `R.weather.rain = true` for as long as any one stays powered - feeds any nearby lightning
  rod's existing rain-gated bonus power directly, zero coupling to machines.lua needed since `R.weather` is core
  shared state. MBOX2 `{0,-5,8}`.

**Stage 5 - Comfort/QoL (shipped 2026-08-26):** lean-check pass, all clean first try.

- **Lighting Rail** (`LIGHTRAILKIT`, workbench, base tier) - one conductive METL/WMAT beam (7 wide) carrying three
  real LEDL/LCRY lamps. One spark anywhere on the beam lights all three - real conduction across the whole
  fixture, not a per-lamp flag. Different from @machines' single `LAMPKIT` (one lamp, own wiring point). MBOX2
  `{3,0,8}`.
- **Security Camera** (`CAMERAKIT`, workbench, base tier) - a small WMAT housing with a GLAS lens and a PSCN pad.
  Powered, every tick it scans a real 120px radius via `R.enemyList()` and sounds a repeating alarm (`R.say`) the
  instant a real hostile is in range - genuine detection against live enemy state, not a timer. MBOX2 `{0,0,6}`.
- **Signpost** (`SIGNPOSTKIT`, hand tier, craft gives 2) - a real WOOD post with a small sign head. Purely
  informational: right-click shows a random flavour message from a small pool in its panel's NEXT line, no world-
  space floating text. MBOX2 `{0,-2,6}`.
- **Proximity Gate** (`GATEKIT`, anvil, base tier) - a real 4-tall METL bar column. No wiring at all - it senses
  the player directly (`nearPlayer`, 26px) and raises (kills the bar cells) when they approach, lowers (rebuilds
  them) when they leave. Mechanically distinct from @machines' powered switch-`DOORKIT`. MBOX2 `{0,-2,6}`.
- **Decorative Panel** (`DECOPANELKIT`, workbench, base tier, passive) - a small framed WMAT/GLAS wall panel for
  base interiors. Purely aesthetic, no tick logic. MBOX2 `{0,-1,5}`.

## Survival (survival.lua) - plants/farming/food/cooking/temperature/events
All new elements below are drawn overlays or small real particle builds, never a full new custom element type.

**Farm plots (`R.farms`, world coords)** - place a **Tilled Soil** item (workbench-tier from Dirt, `SOIL` recipe
by hand) on open solid ground to create an empty plot (drawn as a 5x1 dark-brown line at the plot's feet).
Right-click **Seeds** (foraged, see below) onto an empty plot within ~10px to plant Wheat; right-click a
**Mushroom Spore** directly onto any dark, solid, no-open-sky underground spot to plant a mushroom plot (no
tilling needed). Both grow through stages 0-3, checked every 60 frames (staggered per-plot so it stays cheap),
real-condition gated: Wheat needs a real `WATR` particle within 20px (checked via `sim.partID`, so growth only
progresses while the tile is on-screen/loaded - it stalls, doesn't regress, when you're elsewhere); Mushroom
needs the *absence* of any real FIRE/PLSM/LAVA/LEDL/LCRY/GLOW within 30px. Drawn per stage: Wheat is a coloured
stalk that grows taller and greener-to-gold (dark green -> green -> yellow-green -> gold with a small head at
stage 3); Mushroom is a pale stalk that gains a red cap at stage 2-3. Left/right-click a mature (stage 3) plot
within reach to harvest: Wheat gives 2-3 Wheat + a 40% chance of a Seed back and resets to stage 0 (replants
itself in place); Mushroom gives 2-3 Mushrooms and removes the plot (needs a fresh Spore).

**Foraging** (mine hook, no new UI): chopping surface `GRSS`/`PLNT` (depth <= 1m) has a 10% chance of Seeds and
a 12% chance of Berries; underground `GRSS`/`PLNT` has a 6% chance of Spore and 10% chance of wild Mushroom;
shallow `GOO` (dirt) has a 6% chance of a Root Vegetable; chopping `WOOD` has a 10% chance of a Sapling. Standing
within 10px of a real body of water has a 20% chance every 4s of a Raw Fish ("A fish jumps into your hands").
Plant a Sapling on solid ground and after 3600 frames (~4.3 real min at 14000 frames/day) it becomes a real small
tree (a WOOD trunk 16-24px tall topped with a GRSS canopy blob), then the bookkeeping entry is removed.

**Algae Tank** (`ALGAETANK`, workbench, `R.tanks`) - a small hollow GLAS tank (7 wide x 9 tall) with a real WATR
charge inside, built where clicked (ground-following like a station). Every 90 frames it checks for a real WATR
particle still inside (5px) and a real light source - FIRE/PLSM/LAVA/LEDL/LCRY/GLOW - within 40px; when both
hold it registers/updates a live entry in the shared `R.o2Sources` list (rate 22, range 90) and pulses a faint
green tint every other 10 frames; when either condition fails the entry is removed (O2 production stops, no
particle change). Deliberately distinct from `@machines`' `GREENHOUSEKIT` (daylight, real plants, no power) -
this is the deep-base answer that works lit only by a torch/lamp, in total darkness, no power needed either.

**Bed** (`BED`, by hand from Wood, `R.beds`) - a small WOOD frame with a CLST "blanket" block on top (8 wide x
3 tall). Left/right-click within reach at night (the same day/night sine phase core's HUD uses, `night > 0.15`)
to sleep: fast-forwards `R.frame` to the next day boundary (so core's own "Day N" message and weather/torch
timers all advance correctly), heals 20 HP, tops up food by 5, and sets `R.bedRespawn` so dying afterwards
respawns at the bed instead of world spawn (core's `R.spawnPlayer` is wrapped, not edited, to add this).

**Canteen** (`CANTEEN`, workbench) - right-click real `WATR` to fill 1 Clean Water; right-click `DSTW`/`SLTW` to
fill 1 Dirty Water (aiming at neither gives a hint, no charge used). The canteen itself is never consumed.

**Cooking** (furnace-tier `R.RECIPES`, same lit-furnace gate as every other smelt recipe): Cooked Fish, Roasted
Mushroom, Hearty Stew (Berry+Root+Fish, the best meal in the game), Bread (2 Wheat), Boiled Water (purifies
Dirty Water). Raw Berry/Root/Mushroom/Fish and Dirty Water have an 5-20% illness chance on eating (`R.eat` is
wrapped, not edited) that sets a ~1200-frame "SICK" status (drawn at 200,8 in amber-green next to the hint line)
draining 1 HP every 90 frames until it clears; cooked/clean versions never make you sick. Right-clicking any
`R.FOODS` item (raw or cooked) from the hotbar eats/drinks it instead of trying to place it.

**Temperature**: core's `R.gas.heat` already covers the hot side (deep zones, heat waves). Survival owns the
cold side as a new `R.warmth` meter (0-100, HUD bar at 8,30->64,33 in pale blue, only drawn when < 60, "COLD"
label at 68,28 when < 25): drains 1.4/s in the snow biome (surface or underground - covers "deep ice caves") with
no real light source within 40px, 0 drain elsewhere or near any FIRE/PLSM/LAVA/LEDL/LCRY/GLOW; **Insulated Coat**
(workbench, `INSL`+`WOOD`) halves the drain. HP drains 1 every 60 frames at 0 warmth. **Cooling Wrap** (workbench,
`INSL`+`CU`) is the heat-side counterpart, halving `R.gas.heat` gain from the Heat Wave event and desert/deep
zones (does not touch core's own heat-damage thresholds, only the rate my own systems add).

**Events** (`R.sEvent`, one at a time): a banner at 258,34->498,46 (black box, amber "INCOMING: <NAME>" while
warning, blinks off every ~8 frames; solid orange-red "<NAME>" once active) shown above the goal banner. Roll
chance scales with day count and current depth, checked every 600 frames, one event at a time, disabled entirely
in Sandbox mode. Nine events: **Rainstorm** (forces core's real `R.weather.rain` on for a while - real WATR falls
and floods any open tunnel on its own, no special flood code needed), **Cave-in** (`R.crumble` at a point near/
above the player - real collapse, scales with day count), **Gas Pocket** (finds real nearby GAS/OIL and ignites
it - a real methane blowout), **Meteor Shower** (night + open sky only; spawns a real hot STNE chunk with
downward velocity from the top of the screen every ~100 frames for the duration), **Blizzard** (snow biome only;
heavy warmth drain + a chance per real nearby WATR particle to freeze into ICE), **Heat Wave** (desert or deep
zone; adds to `R.gas.heat` and drains thirst faster, halved by Cooling Wrap), **Aquifer Breach** (near the water-
table depth band; bursts a cluster of real WATR out of the wall ahead of the player), **Migration** (temporarily
flips `R.enemies` on if it was off - a stand-in until `@enemies` exposes a direct spawn API, restores the prior
state when the event ends), **Quiet Night** (rare, night only, no warning: small food/water top-up every few
seconds, no negative events roll while it's active).

## Vehicles (vehicles.lua) — added 2026-08-26, Drew 19:08 "underground trains and ways to navigate the
subterranean, tied into the building system"
Rails are a real placeable material (`R.railSegs`, a persisted graph of straight world-coord segments; visuals
are real particles - a bright `BMTL` line with `METL` cross-tie sleepers every 4px - but every vehicle's physics
reads the segment list, not particles, so a train stays on-rail hundreds of px off-screen). Select the Rail kit,
hold RIGHT mouse and drag: the direction snaps to the nearest of 8 compass angles (flat, both 45-degree slopes,
straight up/down) from the point you started the drag, and extends as you keep dragging. Every wheeled vehicle
shares one physics core (`advanceOnRail`): each tick it re-finds the nearest rail point (preferring whichever
candidate best continues its current heading, so junctions hand off cleanly), snaps onto it, applies gravity along
the rail's own slope (`speed += 0.045 * dir.y`), 0.994/tick friction, a 2-7px-tall clearance check against
`R.solidW` ahead (a real overhang or un-cleared bump stops it dead, same as a real train needs a graded, cleared
roadbed), and derails (a small spark burst, screen shake, HP loss if ridden, message) the instant no rail is found
within tolerance - i.e. driving off the end of the track. `R.vehicles` (world coords) holds every live instance;
dead ones are swept out of the list the same tick they die.

**Controls**: `V` boards the nearest vehicle within 26px (or climbs out of the current one - `S` also dismounts,
same as any other `R.mount`); `D` drives/accelerates, `A` slows or reverses, `S` brakes; `P` toggles a mounted
locomotive's auto-route.

| Vehicle | Look | Powered by | Notes |
|---|---|---|---|
| Minecart | small brown `METL`/wood-toned body, 2 spoked wheels that spin with speed, a fan of dim headlight rays drawn ahead when underground and moving | none - momentum + slope gravity only | cheapest vehicle (workbench), classic manual ride |
| Handcar | same wheeled-body draw as the minecart, tan colouring | player-pumped: each **fresh** `D` press (not held) gives one speed kick | no coal/grid needed at all |
| Locomotive | dark grey wheeled body, a small `BRCK` firebox with a `COAL` bed that glows amber when lit, a `METL` chimney, a `CU` roof stud (power dot green when lit-or-powered) | a lit coal firebox (torch it, exactly like the furnace) **or** a live grid spark at the roof stud | `P` toggles a 2-stop auto-route (nearest 2 `R.trainStops` to the loco); tows up to 3 cargo wagons |
| Cargo wagon | smaller brown wheeled body; a tan cargo-block glyph appears on top when it's holding anything | none (towed) | auto-couples to any locomotive within 24px of the train's tail; left-click while holding a material loads up to 20 units aboard; auto-dumps its hold into any Storage Crate within 30px whenever the train's auto-route stops it |
| Train stop | a small `WOOD` post with a `PSCN` cap, built on the rail | none | purely a waypoint marker for loco auto-route; needs 2+ on one line |
| Mine lift | a hanging `METL`-strut cage on a visible cable line running up to the shaft top, 3 rung lines; a small button block (green when the shaft's `CU` stud has live power, else red) at both the top and bottom of the shaft | a live grid spark at the shaft's power stud | placed on a pre-laid **vertical** rail segment (auto-detects the shaft's full top/bottom extent); click a button to send it there with an accelerate/decelerate curve; loses power mid-trip and it free-falls to the bottom instead - the risk that makes keeping it wired matter |
| Drill train | dark blocky body, 2 wheels, a rotating 3-spoke drill bit at the nose, its own small lit firebox | lit firebox or grid power | rides its own single-column tunnel: hold D/A to bore forward through anything at or under its pick-tier-4 hardness (same `R.MINEABLE`/`R.HARD` rules as a steel pick), crediting every block to the player's bag and laying a flat rail segment behind it in real time (the segment's endpoint is mutated in place, not re-pushed every tick) |

**Recipes**: Rail kit (workbench, cheap, 10 per craft), Minecart/Handcar/Train stop (workbench), Cargo wagon
(anvil), Locomotive/Mine lift/Drill train (anvil, steel-tier materials - the latter three are additionally queued
behind `R.tech.unlock10` if the machines power grid is present, installed lazily the moment that milestone fires
so a fresh save without any power tech still sees them appear once earned).

**Known limits** (documented rather than hidden): the on-rail obstruction check means a dead-flat rail laid across
uneven surface terrain can end up a couple px under a rise and stop the train - lay track along cleared/tunnelled
ground, the same real constraint a real railbed has. The elevator cage does not itself collision-check against
`R.solidW` (it rides its own shaft coordinates directly) - build the shaft through open space. Wagons do not run
independent rail physics; each one servos to a point recorded in the locomotive's own position trail (`v.trail`,
capped at 2000 samples) offset by 15px per wagon, so they trace the loco's exact path through curves/slopes
without needing their own collision pass. **Never store a live reference from one vehicle table back to another**
(e.g. a wagon pointing at its locomotive) - `save.lua`'s generic `R.PLUGIN_SAVE_KEYS` dump is a plain recursive
JSON walk with no cycle detection, and a two-way reference stack-overflows every save; wagon coupling is tracked
with a plain `true` flag for exactly this reason (a real bug hit and fixed live during this feature's own testing,
see the hub for 2026-08-26 vehicles entries).

## Effects and materials
Render pipeline: BASC + FIRE + GLOW + BLUR + EFFE with DISPLAY_EFFE (fire, steam, sparks and hot material glow).
Bullet tracer colours are overridden by core: BMTL bright yellow FFF060, BRMT orange FF9030 (restored on stop).
Friendly names come from `R.NAMES` / `R.nice(el)` — Dirt, Granite, Grass, Coal dust, Iron ore, Iron bar, etc.
