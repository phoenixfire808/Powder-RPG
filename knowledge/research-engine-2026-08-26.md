# Engine Research — Heat, Air, Gravity, Transitions, Lua Hooks (2026-08-26)

Source: `D:/The-Powder-Toy/src` (local checkout). All citations are `file:line` against that
checkout. WebSearch quota was exhausted this session (200/200 used earlier in the day) before
I could pull TPT wiki/forum corroboration — every claim below is sourced directly from the
engine, not from memory of the wiki. If independent corroboration is wanted later, re-run the
two queries "Powder Toy heat conduction algorithm wiki" and "Powder Toy elements.property Update
UPDATE_BEFORE UPDATE_REPLACE" once the search budget resets.

## 0. Headline finding: this *is* why the thermite front quenched (P13)

`knowledge/experiments-2026-08-26.jsonl` P13 (AL61 thermite over BRMT, `heatConduct: 170` per
`knowledge/materials-catalog.json:327`) died after ~18px with the note "TPT heat conduction
spreads reaction heat through the whole block within frames."

The mechanism is exact and structural, not a tuning accident:

- `Simulation.cpp:2452` — heat transfer for a particle only runs on frames where
  `rng.chance(int(elements[t].HeatConduct*gel_scale), 250)` succeeds. `HeatConduct` is stored as
  `unsigned char` (0–255) but the roll is out of **250**, so any value ≥250 conducts essentially
  every frame, and AL61's 170 conducts **68% of frames**.
- When that per-frame coin-flip succeeds, the particle does **not** take one small step toward
  equilibrium — `Simulation.cpp:2466-2509` computes a single heat-capacity-weighted **equilibrium
  temperature across itself and all 8 neighbours simultaneously** (`c_heat += temp*hc` for each
  of the 8 `surround` slots plus self, then `pt = c_heat/hc_total` is written back to all 9
  cells at once, `Simulation.cpp:2503-2509`). It also exchanges with the ambient-air heat grid in
  the same branch (`Simulation.cpp:2455-2464`).
- So "conduction" in TPT is stochastic **instant full-mixing with an 8-neighbour Moore
  neighbourhood + the air cell**, gated by a per-frame Bernoulli trial. A packed block of AL61 at
  HeatConduct=170 will, most frames, flash-average every burning pixel with its cool neighbours
  and the air above/below it, diluting the localized heat pulse a self-propagating front needs
  far faster than physical diffusion would. This is independent of your Lua `reactive` kind logic
  in `scripts/lua/chem_kinds.lua` — the native `TransitionPhase` conduction step runs on *every*
  particle with `HeatConduct>0` regardless of whether it also has a custom Lua `Update`, and it
  runs during the *same* per-particle pass, right before `Update` is invoked (`Simulation.cpp:2379`
  → `2390`).
- The one real escape hatch: `SimulationData::IsHeatInsulator` (`SimulationData.cpp:338-341`)
  returns true (skips *all* native conduction, ambient and neighbour) when
  `elements[t].HeatConduct == 0`. Setting `HeatConduct=0` on a reactive element does not make it
  a perfect insulator physically, it makes the *native code path* leave its temperature alone —
  freeing you to drive a custom, gradual, physically-scaled diffusion step from Lua instead (see
  §7 recommendation R1).

## 1. Heat conduction — exact algorithm, flags, capacity role

Full call site: `SimulationImpl::TransitionPhase`, `Simulation.cpp:2451-2509` (gate) through
`:2727` (transitions applied). Order within one particle's frame, in `UpdateParticles`
(`Simulation.cpp:2340-2410`):
1. Particle deposits momentum into the air-velocity cell (`AirLoss`/`AirDrag`, `:2344-2345`).
2. `HotAir` adds to the pressure cell (`:2347-2358`).
3. `GetNeighbourhood` computes the 8 Moore neighbours + `surround_space` (count of empty
   neighbour cells) + `nt` (count of neighbours whose type differs from self) (`:2265-2293`,
   `:2280-2286`).
4. Velocity integration: `Loss`, `Advection`, `Diffusion` (`:2362-2377`).
5. `TransitionPhase` — heat conduction + high/low pressure/temperature transitions
   (`:2379`, body `:2414-2727+`).
6. Native or Lua `Update` (`:2390-2396`).
7. `MovementPhase` (`:2410`).

Heat-conduction gate and body, `Simulation.cpp:2452-2509`:
```
if (t && !sd.IsHeatInsulator(parts[i]) && rng.chance(int(elements[t].HeatConduct*gel_scale), 250))
{
    // ambient-air exchange (skipped if PROP_NOAMBHEAT)
    auto dtemp = hv[y/CELL][x/CELL] - parts[i].temp;
    auto hc = sd.HeatCapacityOf(parts[i]);
    auto alpha = std::min(0.04f, 0.4f * hc);           // capped rate, NOT full equilibrium
    parts[i].temp += alpha*dtemp / hc;
    hv[y/CELL][x/CELL] -= alpha*dtemp;

    // neighbour exchange: full weighted-average equilibrium, all 8 + self, same frame
    for (j in 0..7) { hc_total += HeatCapacityOf(neighbour_j); c_heat += temp_j*hc_j; }
    hc_total += HeatCapacityOf(self); c_heat += temp*hc;
    pt = c_heat / hc_total;
    self.temp = pt; for (j in 0..7) neighbour_j.temp = pt;
}
```
Key facts:
- **Ambient-air exchange is rate-limited** (`alpha ≤ 0.04`, self-throttled by `0.4*hc`) — this
  part *is* a proper gradual diffusion equation, comment at `Simulation.cpp:2461` even flags that
  it ignores the air cell containing `CELL²=16` "air pixels" worth of heat capacity.
- **Neighbour exchange is not rate-limited** — it's a full instantaneous average, weighted only by
  `HeatCapacity`, every time the Bernoulli gate fires. `HeatCapacity` (float, default 1.0,
  `Element.h:44`) changes *how much a particle resists being averaged*, not *how fast* it
  approaches equilibrium — a thermal-mass trick (very high `HeatCapacity` on a "heat sink" element
  makes it barely move when mixed with a hot neighbour) works, but doesn't slow the *speed* of
  contact conduction, only the *magnitude* of temperature change per event.
- `IsHeatInsulator` (`SimulationData.cpp:338-341`): true if `HeatConduct==0`, or the particle is an
  `HSWC` not in state `life==10`, or a `PIPE`/`PPIP` without `PFLAG_CAN_CONDUCT` in `tmp`. Also
  used by `Air::ApproximateBlockAirMaps` (`Air.cpp:544`) to decide ambient-heat blocking for
  freshly-pasted stamps.
- `HeatCapacityOf` (`SimulationData.cpp:343-349`): sums `PIPE`/`PPIP`'s own capacity plus their
  carried `ctype`'s capacity — the only element where two capacities combine.
- Special-case heat-conduction blockers, hard-coded pairs that never conduct regardless of
  `HeatConduct` (`Simulation.cpp:2482-2489`): FILT vs BRAY/BIZR/BIZRG/PHOT, ELEC vs DEUT, HSWC vs
  FILT when `tmp==1`.
- `PROP_NOAMBHEAT` (`ElementDefs.h:32`) opts a type out of the ambient-air branch only; neighbour
  conduction still applies.
- Liquid convective heat swap (separate from conduction): `TYPE_LIQUID` particles swap temperature
  with the neighbour they're about to flow into along the gravity vector, once per frame, before
  the conduction gate (`Simulation.cpp:2429-2449`) — this is why liquids "layer" temperature by
  buoyancy faster than solids conduct it.
- Boiling/freezing point pressure-shift: liquids/gases get `ctemph`/`ctempl` shifted by
  `±2.0f*pv[cell]` before the transition thresholds are checked (`Simulation.cpp:2513-2519`) — a
  real, if small, "boiling point drops at low pressure" effect already in the base engine.

### Levers available for slow/realistic conduction
1. **Lower `HeatConduct` towards the low end of 0–250** to reduce trigger frequency (matches your
   `stock-element-realism-patch*.json` pattern — e.g. `WOOD:12`, `CNCT:30` already do this). But
   remember: when it *does* trigger, it's still a full 8-neighbour mix, so low `HeatConduct` gives
   you *rare but total* resets, which for a propagating front is a worse failure mode than *frequent
   but small* steps.
2. **`HeatConduct=0` + custom Lua diffusion** (native conduction fully off via `IsHeatInsulator`,
   §7 R1) — the only way to get an actual small-step diffusion equation, because you control the
   step size directly (`temp += k*(neighbour.temp-temp)` per neighbour, once per frame, no
   Bernoulli all-or-nothing jump).
3. **`HeatCapacity`** as thermal mass: cheap way to make a "heatsink" material barely change
   temperature per mixing event without touching `HeatConduct` (e.g. a thick METL jacket around a
   reactor).
4. **`PROP_NOAMBHEAT`** to decouple a material from ambient air temperature entirely (useful for
   vacuum-packed reactive layers where you don't want the surrounding air cell diluting the front).
5. Ambient heat sim can be switched off globally (`aheat_enable`, `Simulation.h:112`,
   checked at `Simulation.cpp:2455` and `Simulation.cpp:3736`) — with it off, `legacy_enable`'s
   `Element::legacyUpdate` path runs instead (`Simulation.cpp:2398-2399`), which uses the older
   `Meltable`/pressure-based mechanics in element `Update`s such as `FIRE.cpp:326-403`, not the
   HeatConduct system at all. Not recommended for you (loses the whole realism model) but explains
   why "heat sim off" saves behave completely differently.

## 2. Pressure / air model

Grid: pressure/velocity/ambient-heat live on a **coarse cell grid**, `CELL=4` px per cell
(`SimulationConfig.h:11`), so the sim is `XCELLS×YCELLS = 153×96` cells over `XRES×YRES =
612×384` px (`SimulationConfig.h:12-19`), i.e. **16 particle-pixels per pressure/air cell**. Any
lint threshold expressed "per pixel" needs to account for this 16:1 area ratio — a single hot/
pressurized particle does not get its own cell; it shares one with up to 15 others.

`Air::update_air` (`Air.cpp:260-497`), run once per frame **before** particle updates
(`Simulation.cpp:3732-3733`, inside `BeforeSim`):
- Edge damping every frame: pressure `Mix(edgePressure, pv, 0.8)`, velocity `Mix(edgeVelocity,
  v, 0.9)` on the two outermost cell rings (`Air.cpp:270-299`).
- Pressure update from velocity divergence: `dp = (vx[x-1]-vx[x+1]) + (vy[y-1]-vy[y+1])`, then
  `pv = Mix(edgePressure, pv, AIR_PLOSS=0.9999) + dp*AIR_TSTEPP(0.3)*0.5` (`Air.cpp:317-327`) —
  pressure barely decays on its own (0.01%/frame) away from edges; it only changes from velocity
  divergence (things pushing air together/apart) or explicit element/tool writes.
- Velocity update from pressure gradient: `vx += (pv[x-1]-pv[x+1])*AIR_TSTEPV(0.4)*0.5`, damped by
  `AIR_VLOSS=0.999` (`Air.cpp:329-346`).
- 3×3 Gaussian blur (`kernel`, built in `make_kernel`, `Air.cpp:8-27`, weights
  `exp(-2(i²+j²))`) smooths vx/vy/pv every frame, with a long-range "advect from upstream" term
  (`advDistanceMult=0.7`, `AIR_VADV=0.3`) that walks up to the velocity magnitude in cells,
  stopping at walls, to pull values from further away when velocity is large (`Air.cpp:348-439`).
  Same structure repeated for ambient heat in `update_airh` (`Air.cpp:79-253`).
- Caps: `MAX_PRESSURE = 256.0f`, `MIN_PRESSURE = -256.0f` (`ElementDefs.h:10-11`). Ambient heat
  capped to `[MIN_TEMP=0, MAX_TEMP=9999]`
  (`ElementDefs.h:5-6`, applied `Air.cpp:186-187`).
- Convection (buoyancy) has two modes (`Air.cpp:196-240`): legacy (pre-99.0, gradient-based) and
  the default `AIRC_BOUSSINESQ` — `weight = (hv[cell]-ambientAirTemp)/10000, capped at 0.01`,
  applied along the (possibly Newtonian) gravity vector. This is a real, if crude, hot-air-rises
  model already built in.
- Walls: `bmap_blockair` zeroes velocity at wall faces and prevents the cell from receiving the
  blur/advect contributions (`Air.cpp:301-315`, `:359-361`); `bmap_blockairh` (bit `0x8`) does the
  same for the ambient-heat grid and is also set by `WL_GRAV` cells (gravity walls) and by TTAN/
  RSSS/insulating particles filling a cell (`Air.cpp:516-551`, `Simulation.cpp:3781-3782`).
- `airMode` (`AIR_ON/PRESSUREOFF/VELOCITYOFF/OFF/NOUPDATE`) zeroes `dp`/`dx`/`dy` selectively
  right before they're written back (`Air.cpp:467-486`) — this is what your
  `set_simulation_modes`/`get_simulation_modes` MCP tools are almost certainly toggling.

**Flammable/Explosive, numerically** (`Element.h:36-37`, both plain `int`):
- `Flammable` is used as the *ignition probability numerator out of 1000*, boosted by local
  pressure: `rng.chance(int(Flammable + pv[cell]*10.0f), 1000)` (`FIRE.cpp:305`, mirrored in
  `LIGH.cpp:96`) — so pressurizing a flammable atmosphere measurably raises its ignition chance
  (10 pressure units ≈ +100/1000 ≈ same as 100 `Flammable` points).
- Fire/spark ignition by contact only fires into a neighbour if **that neighbour has an empty
  (`surround_space`) cell nearby, OR the neighbour is `Explosive`** (`FIRE.cpp:304`,
  `LIGH.cpp:96`): `(surround_space || elements[rt].Explosive) && elements[rt].Flammable && ...`.
  **This means a fully-packed block of a non-explosive Flammable material cannot ignite its own
  interior by contact spread through FIRE's native mechanism** — only its exposed/porous surface
  can catch. This is a second, independent reason (besides §0) that dense reactive blocks behave
  differently from thin/porous ones, and is highly relevant to any combustion-needs-O2 stock
  patch you write (a packed coal seam won't "breathe" fire through itself without added gaps or a
  custom Lua ignition path that ignores `surround_space`).
- `Explosive` is a small bitmask/enum by convention (not documented as a bitmask but used as one):
  `0` = not explosive; `1` (GUNP/RBDM/LRBD) = bypasses the `surround_space` gate above, i.e.
  ignites throughout a packed block by heat/spark contact, no self-detonation from pressure; `2`
  (NITR/PLEX) = same bypass **plus** self-detonates into `FIRE` when local cell pressure exceeds
  `2.5` (`Simulation.cpp:2790`, gated on `Explosive&2`). `PROT.cpp:142` also checks
  `Flammable||Explosive||utype==PT_BANG` generically for "is this dangerous to eat/touch".
- Explosions raise local pressure directly: successful ignition adds `0.25f*CFDS` to the cell's
  pressure (`FIRE.cpp:316`, `Simulation.cpp:2796`) — `CFDS = 4.0/CELL = 1.0` at the shipped
  `CELL=4` (`SimulationConfig.h:33`), so each ignition event is a `+0.25` pressure bump, not
  scaled by how much material burned.
- Generic `HighPressureTransition`/`LowPressureTransition` fire per-particle whenever the *cell's*
  pressure crosses the element's threshold (`Simulation.cpp:2803-2832`) — this is the mechanism
  BMTL↔BRMT, and general solid/liquid/gas pressure transitions use; there is no generic "pressure
  crushes/kills any particle" rule beyond what each element's own threshold does (killing only
  happens if the configured transition target is `NONE`, `Simulation.cpp:2837-2841`).

## 3. Newtonian gravity + gravity walls

Two independent systems, both feeding into `Simulation::GetGravityField` (`Simulation.cpp:2088-
2125`), called for every moving particle each frame at `Simulation.cpp:2360`/`:2288-2291`:
- `gravityMode` (VERTICAL/OFF/RADIAL/CUSTOM) sets the base per-particle field from the element's
  own `Gravity` float — vertical is just `(0, Gravity)`; radial is `Gravity*(d/(0.01-|d|))` toward
  screen centre; custom uses `customGravityX/Y` (your `set_custom_gravity` MCP tool almost
  certainly writes these).
- **Newtonian term** is added on top if the element's `NewtonianGravity` float is nonzero:
  `pGrav += NewtonianGravity * gravOut.forceX/Y[cell]` (`Simulation.cpp:2120-2124`). Critically,
  **`gravOut` is *not* a live N-body sum of every particle's mass** — it's a per-cell scalar field
  computed once per frame by 2-D FFT convolution of a `mass` grid against a `1/r²`-ish kernel
  (`gravity/Fft.cpp:75-134`, kernel built `:156-177` as `scaleFactor*d/|d|³` with
  `scaleFactor = -M_GRAV/(NCELL*4)`, `M_GRAV = 0.667` — literally G scaled for the sim,
  `SimulationConfig.h:8`). The convolution runs on a background thread
  (`gravity/Fft.cpp:186-206`) and is double-buffered: `Gravity::Exchange`
  (`gravity/Fft.cpp:209-241`) only re-dispatches when the mass/mask grids actually changed
  (`memcmp`), and always hands back the *previous* completed result while a new one computes — so
  Newtonian gravity is **one frame stale** relative to the mass sources under sustained change.
- **Only specific elements deposit mass** into `gravIn.mass` — this is not automatic per-particle
  mass accumulation. Writers found: `GRVT.cpp:72` (`0.2*tmp`), `NBHL.cpp:52/56` (black hole,
  positive), `NWHL.cpp:52/56` (white hole, negative), `GPMP.cpp:66` (gravity pump,
  `0.2*(temp-273.15)`), `GBMB.cpp:74/78` (gravity bomb, ±20/±80 one-shot), and the `PGRV`/`NGRV`
  sim-tools (`simtools/PGRV.cpp:16`, `NGRV.cpp:16`, `±strength*5`). `gravIn.mass` is cleared to 0
  every frame in `BeforeSim` (`Simulation.cpp:3741-3744`) *before* `UpdateParticles` runs those
  elements' `Update` functions, so the field only reflects whatever "graviton" elements are
  present *this* frame — ordinary matter with `NewtonianGravity>0` (if you ever set that on a
  stock element) will be *pulled by* the field but does not itself *source* it unless it also
  writes `gravIn.mass`.
- **Gravity walls** (`WL_GRAV`): a wall cell type that (a) is excluded from the Newtonian mask
  build-out via flood fill from the map edges (`Simulation.cpp:3690-3723`, `check()` treats
  `WL_GRAV` as a barrier so mass "leaks" don't cross it — used to make isolated pockets with their
  own local gravity), and (b) always blocks ambient heat (`bmap_blockairh ... || bmap==WL_GRAV`,
  `Simulation.cpp:3782`, `Air.cpp:521`). It does **not** block plain air pressure/velocity by
  itself (only `WL_WALL`/`WL_WALLELEC`/`WL_BLOCKAIR`/unpowered `WL_EWALL` block air,
  `Simulation.cpp:3781`).

## 4. Transitions — evaluation order and what "→ LAVA" does to `ctype`

All four transition kinds (`HighTemperature[Transition]`, `LowTemperature[...]`,
`HighPressure[...]`, `LowPressure[...]`) are plain per-element fields checked every frame inside
`TransitionPhase` for *every* non-insulated particle whose conduction gate fired this frame
(temperature transitions, `Simulation.cpp:2526-2674`) or unconditionally for pressure
(`:2799-2832`, not gated by the `HeatConduct` roll). `NT` (`TransitionConstants.h`, effectively
"no transition") vs `ST` ("special", meaning "run element-specific hardcoded logic instead of a
plain type swap") are the two sentinel transition targets — `ST` is what LAVA, ICEI/SNOW, WTRV,
SLTW, BRMT, CRMC, RIME all use to get bespoke behaviour (`Simulation.cpp:2529-2606`).

When something's `HighTemperatureTransition` resolves to `PT_LAVA` (the plain, non-`ST` case,
`:2533`) or through the `ST` branches that explicitly set `t=PT_LAVA` (BRMT, CRMC, generic `ST`
solids), the type-change block at `:2676-2725` runs:
- `parts[i].ctype = parts[i].type` is set **before** the type is actually changed
  (`:2678`, checked for `t==PT_ICEI||PT_LAVA||PT_SNOW`) — i.e. **`ctype` remembers what the
  particle *was* before melting**, which is exactly how molten metal "remembers" it should
  solidify back into METL/IRON/etc. (see `FIRE.cpp:99-160` for how `LAVA.ctype` then drives ore
  differentiation using local pressure/temperature).
- Material-specific `ctype` touch-ups fire right after `part_change_type` succeeds
  (`:2713-2723`): BRMT→BMTL, SAND→GLAS, BGLA→GLAS, PQRT→QRTZ, LITH(if `tmp2>3`)→GLAS, and life is
  reseeded to `rng.between(240,359)`.
- The reverse (`LowTemperatureTransition==ST` on `PT_LAVA`, `:2619-2669`) reads `ctype` back to
  decide what to solidify into, with per-`ctype` freezing-point overrides (THRM, VIBR/BVBR, TUNG,
  CRMC, PLUT get bespoke thresholds instead of the generic 973 K "everything else" cutoff).
- `part_change_type` can refuse the change (e.g. target is STKM and one already exists) and kill
  the particle instead — callers must check its return (`:2710-2711`) — worth remembering if you
  add stock `Update` hooks that call it directly (§5).

## 5. Replacing/augmenting stock `Update` from Lua — the real mechanism

`elements.property(id, "Update", fn, mode)` in `LuaElements.cpp:546-618` works on **any** id that
`SimulationData::IsElementOrNone` accepts — that includes every built-in element, not just
custom ones (`:552-555`). The dispatcher installed is `luaUpdateWrapper`
(`LuaElements.cpp:82-130`), which is what `elements[id].Update` gets pointed at
(`:610`/`:616`/`:438`/`:444` — the element-table form at line ~433 supports the same 3 modes but
via `elements.element(id, {...})`).

`mode` argument (integer, default 0) selects `customElements[id].updateMode`:
- `0`/omitted → `UPDATE_AFTER`: **native builtin `Update` runs first** (`LuaElements.cpp:92-98`),
  then your Lua function runs (`:99-121`). If the builtin returns nonzero (its own `MovementPhase`
  should be skipped), the wrapper returns 1 immediately and your Lua never runs that frame.
- `2` → `UPDATE_BEFORE`: your **Lua function runs first**, then the native builtin runs after it
  (`:122-128`) — read the code path order carefully: despite the name, in source order the Lua
  call happens before the `updateMode==UPDATE_BEFORE` builtin call, i.e. "BEFORE" describes native
  running before the *movement* phase, with Lua now running before *it*.
- `1` → `UPDATE_REPLACE`: neither `UPDATE_AFTER` nor `UPDATE_BEFORE` guard matches, so the builtin
  `Update` is **never called** — your Lua function fully replaces the stock element's per-frame
  logic (movement/physics from `MovementPhase` still runs afterward unless your Lua returns
  truthy, since that's a separate, unconditional step, `Simulation.cpp:2410`).
- Passing `false` for the third argument uninstalls your hook and restores
  `builtinElements[id].Update` (`:612-617`).

This is the safe way to add rusting/O2-gated combustion/acid-on-carbonate chemistry to a *stock*
element without losing its native movement, graphics, or the heat-conduction/transition machinery
in §1/§4 (those run in `TransitionPhase`, independent of `Update`, regardless of which mode you
pick) — use mode `0` (default, run after) so your chemistry sees the native element's own
transition/graphics-relevant state changes first, or mode `2` if your chemistry needs to run
before the native reaction check that frame (e.g. consuming a reactant before native code decides
whether to ignite). Use mode `1` only if you intend to fully own the element's frame logic (rare
for a stock element you still want falling/flowing/graphics to work normally, since those are
mostly separate — `MovementPhase`/`Graphics` are untouched by `Update` mode, so replace mode is
actually fairly safe even for stock elements).

**Cost per particle per frame**, mode-independent once installed: one `lua_rawgeti` (registry
fetch) + `tpt_lua_pcall` with 5 pushed args and up to 1 return value
(`LuaElements.cpp:102-114`). This runs for *every live particle of that type, every frame it is
updated* (`UpdateParticles` iterates `parts.active`, `Simulation.cpp:2295-2300`) — there is no
built-in throttling; if you hook a common stock element (e.g. `WATR`), every water particle pays
one Lua call/frame. Prefer hooking your own low-population custom elements, or gate expensive
logic behind `sim.partProperty(i,"tmp2")`-style cheap counters inside the Lua function itself, the
same pattern already used in `chem_kinds.lua`'s `reactive` kind.

## 6. Frame timing — event/hook order

Traced call chain (`gui/game/GameController.cpp:899-932` `Update()`, and
`gui/game/GameModel.cpp:1687-1730` `UpdateUpTo/BeforeSim/AfterSim`):

1. `GameController::Update()` calls `gameModel->UpdateUpTo(NPART)` if the sim is running
   (`GameController.cpp:924-928`).
2. `GameModel::BeforeSim()`: fires Lua `BEFORESIM` event **first**
   (`GameModel.cpp:1720`), **then** calls native `sim->BeforeSim(true)`
   (`:1722`) — which runs `air->update_air()` (`Simulation.cpp:3732-3733`),
   `air->update_airh()` if `aheat_enable` (`:3736-3737`), dispatches Newtonian gravity
   (`:3739`), and updates wall/emap/block-air state (`:3772-3784`). **So `BEFORESIM` fires before
   this frame's air/pressure/gravity have been advanced** — a Lua `BEFORESIM` hook sees last
   frame's air state, not this frame's.
3. `sim->UpdateParticles(0, NPART)` (`GameModel.cpp:1698`) — the full per-particle pass from §1,
   which *does* see this frame's freshly-updated air/pressure/gravity (computed in step 2), and
   invokes any installed Lua `Update` hooks inline, per particle (§5).
4. `GameModel::AfterSim()`: native `sim->AfterSim()` first, then Lua `AFTERSIM` fires
   (`GameModel.cpp:1727-1729`) — this is the correct hook if a script needs to read fully-settled
   per-frame state (temperatures, pressures, transitions all applied).
5. Separately, once per `GameController::Tick()` (a different function, called once per rendered
   frame same as `Update()`), the generic `TICK` event fires **last**, after menus/debug-draw
   housekeeping (`GameController.cpp:738-765`, `commandInterface->OnTick()` at `:765`; event name
   wiring `LuaEvent.cpp:62-68`).

Practical implication for `chem_kinds.lua`: reactions installed via `elements.property(id,
"Update", fn)` run *inside* step 3, interleaved with native heat-conduction/transitions per
particle — they are not a separate global pass, and see per-particle order effects (a particle
processed earlier in the `parts` array this frame may already reflect this frame's reaction when a
later particle's neighbour-check runs). If you need a strictly "look at last frame, decide, commit
all at once" simulation step (to avoid order-dependent chains), do the decision-making in a
`TICK`/`AFTERSIM` handler that snapshots state and applies changes on the next `BEFORESIM`, rather
than in the per-particle `Update` hook.

## 7. Under-used per-element properties — meanings from source, mapped to realism

All fields are on `Element` (`Element.h:26-46`) and all are Lua-settable via
`elements.property`/`elements.element` (full list: `Element.cpp:57-103`).

| Field | Real usage found in source | Realism mapping |
|---|---|---|
| `Advection` | Fraction of the cell's air velocity added to the particle's own velocity every frame (`Simulation.cpp:2369-2370`) | How strongly a material is carried by wind/convection — near 0 for solids, ~0.3–0.9 for gas/smoke/fire. Already used correctly by stock (FIRE=0.9). |
| `AirDrag` | Fraction of the *particle's* velocity fed back into the air-velocity cell (`:2344-2345`) | The reverse coupling — how much a moving object stirs the air. Almost unused on solids; could give a falling dense powder a wake. |
| `AirLoss` | Decay multiplier applied to the air-velocity cell before the particle adds its own drag term (`:2344-2345`) | Local air viscosity/damping around that particle type — e.g. a porous material could have a lower `AirLoss` to represent airflow resistance. |
| `Loss` | Multiplies the particle's *own* velocity every frame (unless it's an unmovable SPNG) (`:2363-2367`) | Kinetic friction/drag on the particle itself — already used for viscosity-like tuning (ACID=0.95, FIRE=0.20). |
| `Collision` | Multiplier applied to velocity components when a move attempt is blocked/bounced (multiple sites, `:3116-3340`) | Restitution/bounce coefficient — negative values (GRVT=-0.99) invert velocity (elastic bounce); 0 (most powders) = dead-stop friction on collision. |
| `Diffusion` | Adds `Diffusion*(2*rand-1)` random jitter to vx/vy every frame (`:2373-2377`) | Brownian motion / thermal agitation for gases — already used for gas-like elements; could scale with temperature for a more physical "hotter gas diffuses faster" if you hook `Update`. |
| `HotAir` | Adds directly to the cell's pressure every frame, with special-cased extra boost for GAS/NBLE (`:2347-2358`) | Rate of gas generation/expansion — a decomposition or boiling reaction could ramp a particle's effective `HotAir` via a custom property rather than a fixed constant. |
| `Falldown` | Movement-class switch: `0` = doesn't fall (checked at `:3102`), `1` = powder-style (checked via `elements[...].Falldown>1` branches at `:3186`/`:3236`), `2` = liquid-style, enabling sideways flow/leveling and the `water_equal_test` (`:719-753`, `:3132`) | Solid vs. powder vs. liquid movement archetype — already the backbone of stock behaviour; a custom element's `Falldown` choice determines whether it piles (1) or levels (2). |
| `Weight` | Determines `can_move[moving][destination]` in `SimulationData::init_can_move` (`SimulationData.cpp:121-127`): a particle can only displace another whose `Weight` is *strictly less* (`movingType.Weight <= destinationType.Weight` ⇒ blocked/bounce, not swap) | Buoyancy/density ordering for burial and floating — e.g. want molten metal to sink through sand but not through stone: tune relative `Weight`, not `Gravity`. Also used directly in STKM push physics (`STKM.cpp:530`). |
| `Hardness` | **Two independent, near-opposite usages**, both only in acid/base chemistry: (a) `ACID.cpp:87/91` — dissolve chance is `rng.chance(Hardness, 1000)` directly, i.e. **higher `Hardness` ⇒ acid dissolves it faster/hotter**; (b) `BASE.cpp:200-201` — corrosion chance is `rng.chance(50-Hardness, 1000)` for `0<Hardness<50`, i.e. **higher `Hardness` ⇒ more resistant to BASE**. There is no generic "structural toughness" use of `Hardness` outside these two elements. | Despite the name, `Hardness` in the shipped engine is really "acid solubility" (direct) vs. "base resistance" (inverse), not mechanical hardness. For your carbonate/acid chemistry patch, set `Hardness` per-material to match real solubility in acid (limestone/marble high, glass/PTFE-analog low) rather than mechanical hardness, and expect the BASE relationship to need a *different*, inverted scale if you also want realistic base attack. |
| `Meltable` | Only consumed by the **legacy** (`legacy_enable`) fire code path: `rng.chance(Meltable*max(1,(int)pv[cell]), 1000)` melts the neighbour into LAVA with `ctype=self` (`FIRE.cpp:346-369`) | Irrelevant unless you run with heat sim off; with `aheat_enable` on (your setup) the real melting path is `HighTemperature`/`HighTemperatureTransition`, and `Meltable` is dead weight — don't bother tuning it for your realism patches. |

Other properties you already use correctly and don't need remapping: `Gravity`/`NewtonianGravity`
(§3), `HeatConduct`/`HeatCapacity` (§1), `Flammable`/`Explosive` (§2), `LowPressure`/
`HighPressure`/`LowTemperature`/`HighTemperature` + their `*Transition` pairs (§4).

## 8. Limits

- **`PT_NUM = 1 << PMAPBITS`, `PMAPBITS = 9`** (`ElementDefs.h:64-82`) ⇒ **512**, not 256. The
  "256 element cap" you'd planned around is stale for this checkout — the pmap packs `id<<9 |
  type`, so up to 512 distinct element type IDs are representable simultaneously (stock elements
  occupy roughly the first ~200-something; check `native_catalog`/`material_catalog` MCP output
  for the live count in your build rather than assuming). Re-verify against whatever binary you
  actually run, since this is a compile-time constant that could differ if the shipped `.exe`
  predates this source checkout.
- **`NPART = XRES*YRES = 612*384 = 235008`** (`SimulationConfig.h:13-20`) — hard cap on
  simultaneous particles (one pmap slot per pixel).
- **`CELL = 4`**, **`XCELLS×YCELLS = 153×96 = 14688`** pressure/air/gravity cells
  (`SimulationConfig.h:11-17`) — relevant divisor for any "per-cell" lint threshold.
- **Lua `Update` cost**: one `pcall` (5 args, ≤1 return) per particle of a hooked type per frame,
  no engine-level batching or throttling (§5) — budget accordingly if you hook a populous stock
  element rather than a sparse custom one.
- Newtonian gravity field is computed by a **single background thread** doing one FFT pair per
  dispatch, reused across frames until the mass/mask grids change (`gravity/Fft.cpp:186-241`) —
  cheap unless you're constantly repainting `GRVT`/`NBHL`/`NWHL` mass every frame, in which case
  it recomputes every frame and is one thread's worth of 2×153×2×96-ish real-to-complex 2-D FFTs
  (`blocks = CELLS*2`, `gravity/Fft.cpp:16-19`).

---

## 9. Prioritised concrete changes (10), mapped to files, with expected realism gain

1. **[High] Give the `reactive` Lua kind its own gradual heat-diffusion step and force
   `HeatConduct=0` on any element using it.** File: `scripts/lua/chem_kinds.lua` (add a
   `thermal_step` helper called once per particle inside `kinds.reactive.make`'s returned
   function: `temp += k*(neighbour.temp-temp)` over the 8 neighbours, k on the order of
   0.01–0.05/frame, tunable per rule set) + `scripts/define_materials.py` (default
   `heatConduct: 0` for any material whose `behavior.kind == "reactive"`, forcing authors to opt
   in explicitly if they want native conduction instead). **Gain: directly fixes the P13 quench —
   this is the root cause identified in §0/§1.**
2. **[High] Add a `heatConduct`/`heatCapacity` realism table to `define_materials.py` keyed by
   real thermal-conductivity buckets** (e.g. metals 100–250, ceramics/rock 20–90, wood/organics
   5–20, insulators 0–5) instead of leaving custom elements to inherit whatever base template's
   default, and cross-check every existing custom material in `knowledge/materials-catalog.json`
   against real k-values (AL61 at 170 is roughly right for pure aluminium's *relative* rank but
   still causes §0's problem for a thin reactive layer — split "structural AL sheet" from
   "thermite powder AL" into two different `HeatConduct` regimes). **Gain: makes every future
   custom element's thermal behaviour predictable instead of accidental.**
3. **[High] Add a lint rule to `knowledge_tools.py`'s `lint_compiled`** that flags any material
   with `behavior.kind in {"reactive","pcm"}` and `heatConduct > ~30` (or unset, since the
   compiler likely defaults it) with a warning citing this doc's §0/§1, plus a second rule
   flagging self-propagating-reaction blueprints (multiple adjacent "reactive" cells) that are
   fully packed (no porosity/no `Explosive` flag) per §2's `surround_space` finding — recommend a
   1-in-3 or checkerboard porosity pattern, or setting the material's `Explosive` to `1` if it
   should burn through solid contact. File: `powder_ext/knowledge_tools.py` (near existing
   `lint_compiled` at line 1364). **Gain: catches "thermite won't propagate" class bugs before a
   sim run, not after 200 frames of observation.**
4. **[Medium] Model real acid/carbonate chemistry using `Hardness` per its *actual*, inverted-for-
   BASE semantics (§7 table)**, not a naive "hardness=toughness" mapping: set `Hardness` high for
   carbonates (should dissolve fast in ACID) and consider that using the *stock* `ACID` element
   for this automatically gets you the `Hardness`-driven dissolve-with-heat-release behaviour
   (`ACID.cpp:87-108`, already produces heat: `newtemp = (60-Hardness)*7`) for free, with zero new
   Lua code — cheaper than writing a custom `reactive` rule for every carbonate. File:
   `scripts/define_materials.py` (set carbonate `Hardness` values) +
   `knowledge/chemistry-rules.json` (document the mapping so it isn't re-derived from scratch).
   **Gain: real CO2-release/heat-of-reaction behaviour reusing tested native code instead of a
   parallel Lua reimplementation.**
5. **[Medium] Add O2-gated combustion to stock flammables via `elements.property(id, "Update",
   fn, 0)` (mode 0 = run after native)** rather than only building new custom "reactive" elements
   — e.g. hook `PT_COAL`/`PT_WOOD`/`PT_OIL` so their native `Flammable` ignition (still handled by
   FIRE/LIGH's contact code, §2) is followed by an O2-neighbour check that snuffs the fire (sets
   `life=0` or reverts to unburnt) if no `O2`/`AIR` (`surround_space`) neighbour is present this
   frame, matching your project's "combustion needing O2" goal without reimplementing ignition.
   File: `scripts/lua/chem_kinds.lua` (new small `kinds.o2_gate` or extend `reactive`'s `needs`
   field to accept `AIR` meaning "any empty neighbour", which the parser already partially
   supports per the `r.with == "AIR"` check at `chem_kinds.lua`'s occupant-hit logic — extend to
   also gate `needs`). **Gain: stock elements gain real gas-starvation behaviour cheaply, and it
   composes with the native FIRE contact-spread rules from §2 instead of fighting them.**
6. **[Medium] Use `Explosive` bit semantics precisely (§2) rather than a generic "explosive: true"
   flag** in `define_materials.py`: expose `explosiveMode: 0|1|2` (0=none, 1=burns-through-packed-
   solid no pressure self-detonation, 2=also self-detonates above 2.5 cell pressure like NITR/
   PLEX). Currently unclear whether the schema distinguishes these. **Gain: correctly
   differentiates "burns readily even packed" materials (thermite mixtures, black powder analogs)
   from "genuinely shock-sensitive" ones (high explosives), which is exactly the distinction
   needed for realistic energetic-materials builds.**
7. **[Medium] Add a pressure-based lint threshold to `knowledge_tools.py` using the real numeric
   scale from §2**: `MAX_PRESSURE=256`, edge-decay `AIR_PLOSS=0.9999`/frame (negligible natural
   decay), ignition-relevant pressure ~2.5 (Explosive&2 self-detonation) to ~10+ (meaningfully
   boosts Flammable ignition chance via `+pv*10`). Flag any pressure-chamber blueprint targeting
   pressures under ~1 as "won't measurably affect Flammable/Explosive thresholds" and over 256 as
   "will be silently clamped, no effect beyond the cap." File: `powder_ext/knowledge_tools.py`.
   **Gain: replaces guessed pressure targets with numbers traceable to `Air.cpp`/`Simulation.cpp`.**
8. **[Low] Document the `BEFORESIM`/`AFTERSIM`/`TICK` ordering (§6) in
   `knowledge/tpt-lua-api-cheatsheet.md`**, specifically: `BEFORESIM` sees *stale* (last-frame) air
   data, `AFTERSIM` sees fully-settled current-frame data, `TICK` fires last and once per rendered
   frame regardless of sim pause state. Any future Lua hook that reads pressure/temperature fields
   to make a decision should use `AFTERSIM`, not `BEFORESIM` or `TICK`, to avoid off-by-one-frame
   bugs. **Gain: prevents a class of subtle timing bugs in future Lua tooling (e.g. a controller
   script that reads a sensor and acts on it).**
9. **[Low] Exploit the native `LAVA.ctype` remembers-original-material mechanic (§4)** instead of
   custom tmp/tmp2 bookkeeping when adding new meltable stock materials — set only
   `HighTemperatureTransition = LAVA` and `HighTemperature`, and the engine automatically preserves
   `ctype` through melt and reads it back on solidify (`Simulation.cpp:2678`, `:2619-2669`),
   including per-`ctype` freezing-point overrides you can extend by adding your new material to
   the `elif` chain if it needs a nonstandard freezing point (or, cheaper, use `elements.property`
   on `PT_LAVA`'s `Update` in `UPDATE_AFTER` mode to add per-ctype extensions without touching
   engine source). File: `scripts/define_materials.py` / a small stock-`Update` hook alongside
   `chem_kinds.lua`. **Gain: fewer custom state fields, reuses tested native ore-differentiation
   logic from `FIRE.cpp:99-160`.**
10. **[Low] Correct the working assumption of "256 max elements" everywhere it appears** (PLAYBOOK,
    define_materials.py comments, any capacity-planning notes) to **512** per §8, and add a
    live check (`native_catalog`/`material_catalog` MCP call) to confirm the actual running
    binary's `PT_NUM`/available custom-ID headroom rather than hard-coding either number, since
    it's a compile-time constant that could legitimately differ between the source checkout and
    whatever binary is actually launched. **Gain: avoids leaving usable element ID space
    unplanned-for, or conversely designing around a ceiling that doesn't exist in the running
    binary.**
