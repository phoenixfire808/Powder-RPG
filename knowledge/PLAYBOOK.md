# Powder Toy Building Playbook

Practices are ordered by level. Do level N practices until every 'verify' passes before composing them at level N+1. Each step is a blueprint fragment (see BLUEPRINT_SPEC.md) or an action. 'status' says how far the practice is trusted: verified = reproduced live by us, observed = seen working in community saves and explained from source, proposed = derived from source facts only. Practices may list 'variants': alternative implementations lifted from community saves (cite the save id); use the base steps first, then a variant when its trade-off fits.

Served by `build_practices`; curriculum by `next_task`; source `knowledge/playbook.json`.

## L0 · checkpoint_verify_loop  (workflow, verified)

**Goal:** Never lose a build and never trust a placement response.

**Steps**
1. Pause the simulation before drawing anything (blueprint_build does this: pause=true).
2. Save a full-canvas stamp before every test run (save_stamp x=0 y=0 width=611 height=383).
3. Draw with blueprint_build dry_run=true first; fix every error; then dry_run=false.
4. Verify by census, not by ok:true — count the elements you expect in the box you drew (spatial_snapshot/execute_lua).
5. Record what you learned with record_build_lesson before moving on.

**Verify:** Census of your region lists exactly the elements and counts you intended; stamp id exists in list_stamps.

**Pitfalls (lessons):** Verify by capturing and running, not by reading back the draw result; Placing over occupied pixels silently fails — erase before fill (blueprint 'box' does this by default); Simulation runs live/unpaused by default -- wall-clock tool latency silently advances real frames

**Scale up:** Same loop at every size. At >30k particles keep stamps of each section separately so a failed test only rewinds one section.

## L1 · sealed_vessel  (containment, verified)

**Goal:** A box that holds a liquid or gas with zero leaks.

**Steps**
1. `{"id": "v", "box": "TTAN", "at": [0, 0], "size": [30, 20], "hollow": 2}`
2. `{"box": "DSTW", "at": ["v.left+2", "v.top+10"], "size": [26, 8]}`
3. Unpause for 120 frames (set_pause 0, sleep 2.5 s, set_pause 1).

**Verify:** Census outside the vessel box shows 0 DSTW; inside count unchanged (±0).

**Pitfalls (lessons):** Bottom vent gap drains liquid fuel under ambient gravity; Draw elements before placing walls; Wall types differ visually and some animate

**Scale up:** Any pipe or valve entering a vessel must pass through the shell flush and be collared (GLAS/TTAN) — leaks always start at penetrations. Prefer wall types (WALL) as the pressure boundary when the contents will be pressurised (see pressure_chamber).

**Modules:** `tank`, `dome_vessel`

## L1 · insulated_heat_source  (thermal, verified)

**Goal:** Place a hot element (WIFI, HEAC, PRTO, laser) without cooking its surroundings.

**Steps**
1. `{"module": "wifi_node", "at": [0, 0], "params": {"channel": 5}}`
2. Read the WIFI temperature: channel N sits at 73.15+100*(N-1) K permanently. Channel 5 = ~500 K; channel 40 = 4000 K.
3. Put anything above 600 K inside a 2px INSL jacket; run blueprint_lint and clear every heat_source_uninsulated finding.

**Verify:** After 300 frames the pixel just outside the INSL jacket is within 5 K of ambient (get_field temp).

**Pitfalls (lessons):** WIFI blocks are standing heat sources at channel temperature — INSL-jacket every one; WIFI/PRTI/PRTO channel is derived from temperature, not tmp — set temp = 73.15 + 100*(N-1); Unjacketed WIFI bank inside a GLAS console heat-soaks the glass to 922C (melt edge) — jacket or move the bus; Vacuum gaps don't insulate (air grid conducts); DMND-contained molten LITH works as a liquid breeder module

**Scale up:** Group all WIFI of a plant into one jacketed bus (wifi_bus_row) with INWR stubs out; keep channels <= 8 near anything flammable; reserve high channels for portals that must be hot anyway.

**Modules:** `wifi_node`, `insulated_box`, `wifi_bus_row`

## L1 · wire_a_signal  (electrical, observed)

**Goal:** Send a spark from a button to a target without shorting anything on the way.

**Steps**
1. `{"id": "b", "box": "BTRY", "at": [0, 0], "size": [2, 2]}`
2. `{"line": "INWR", "from": ["b.right+1", "b.cy"], "to": ["b.right+40", "b.cy"]}`
3. `{"box": "PSCN", "at": ["b.right+41", "b.cy-1"], "size": [2, 3]}`
4. `{"box": "LCRY", "at": ["b.right+43", "b.cy-2"], "size": [6, 5]}`
5. Spark rules as measured live (2026-08-25 rigs): a 3-cell PSCN/NSCN chain lit in BOTH directions at frame 1 (the textbook 'NSCN never sparks PSCN' asymmetry did not reproduce in that rig - treat it as unconfirmed); INST floods its whole body in 1 frame; INWR side-touching METL DID pass the spark in the rig, so do not rely on INWR as insulation from adjacent conductors - keep a 1px gap or INSL; SWCH gates when toggled; LCRY lights only on direct PSCN contact (confirmed).

**Verify:** Within 10 frames of the battery being placed the LCRY reads lit (its temp/ctype changes) — census shows SPRK particles along the INWR and none on neighbouring METL.

**Pitfalls (lessons):** A conductive floor or plane shorts the whole build; PSCN must touch LCRY directly; 1px gap silently kills lamp panels; INWR (insulated wire) for buried and overhead signal runs — no INSL sheath needed, crossing-safe; Structure gates must count SPRK by ctype — spark traffic masks conductive structure

**Scale up:** One bus, many channels: convert long INWR runs into a WIFI channel per function; label channels in a table before building (channel_reuse lint catches collisions).

**Modules:** `lcry_panel`, `lcry_lamp_13`, `button_pad`, `inwr_pylon`

## L2 · tank_with_valve  (containment, verified)

**Goal:** A tank whose outlet can be opened and closed reliably.

**Steps**
1. Build sealed_vessel with the outlet pipe (PIPE, 3px) entering the tank floor flush; extend the pipe 6px INTO the tank interior and collar it with GLAS.
2. Close = replace 3 rows of the drain pipe with a TTAN plug (physical valve). Open = replace the plug rows with PIPE; the pipe re-initialises in ~60 frames.
3. Do NOT rely on PPIP pause flags for a valve that must survive rebuilds — pipe re-init wipes them.

**Verify:** Closed: tank level constant over 300 frames (count DSTW inside). Open: level falls and the same count appears downstream.

**Pitfalls (lessons):** Bottom vent gap drains liquid fuel under ambient gravity; Unpausing releases stored dynamics: valve every gravity line and expect DEUT concentration

**Scale up:** Every gravity-fed line in a plant gets a plug valve; keep all valves CLOSED before unpause; open one at a time and watch the downstream census. For fuel (DEUT) gauge by sum of life, not particle count.

**Modules:** `tank`, `ppip_valve_chute`, `dstw_reservoir_manifold`

## L2 · remote_flood_and_drain  (electrical, observed)

**Goal:** Fill or empty any chamber from a control room with one WIFI pulse each.

**Steps**
1. `{"id": "c", "box": "TTAN", "at": [0, 0], "size": [40, 30], "hollow": 2}`
2. `{"module": "injector_pod", "at": ["c.left+4", "c.top-3"], "params": {"channel": 6, "delay_c": 98}}`
3. `{"module": "drain_pod", "at": ["c.left+20", "c.bottom+1"], "params": {"channel": 7}}`
4. Pulse channel 6 from a wifi_node+PSCN button; the DLAY holds the PCLN(DSTW) cloners on for delay_c frames, then they stop by themselves.

**Verify:** After the pulse, DSTW count inside 'c' rises for ~98 frames then plateaus; after pulsing channel 7 it falls to 0.

**Pitfalls (lessons):** WIFI-triggered injector pod (DLAY->PUMP+PCLN(DSTW)) and drain pod (BTRY->PVOD) = remote flood/drain for any chamber; Use DSTW, not WATR, for coolant that touches conductors or logic; PUMP columns + VACU sump form a pressure pair that drives a walled fission core

**Scale up:** One pod pair per chamber, unique channel pair per chamber, all buttons on one console (button_pad + lcry_lamp_13 per chamber for state).

**Modules:** `injector_pod`, `drain_pod`, `button_pad`, `lcry_lamp_13`

**Variant — PVOD drain** (proposed, save 5170 alternate build; drain_pod v2): PVOD deletes only while its own spark is live, so there is no permanently armed VOID to leave exposed if the gate fails open. NOTE: PVOD-while-powered did not reproduce in the 2026-08-25 live rig (experiment #4) - verify before relying on it; NTCT+VOID is the unconditional fallback.

## L3 · pressure_chamber  (containment, observed)

**Goal:** Hold a region at a chosen pressure without it blowing out.

**Steps**
1. `{"module": "pressure_chamber", "at": [0, 0], "params": {"width": 40, "height": 32, "sump_height": 16}}`
2. Walls (wall type WALL) are the pressure boundary — particles are not. PUMP columns raise the interior (+127 measured in save 78400), VACU sump below holds the exhaust negative (-256).
3. Measure with get_field pressure at the chamber centre every 60 frames until it is stable.

**Verify:** Centre pressure stable within ±5 for 120 frames; pressure outside the wall box stays within ±2 of ambient.

**Pitfalls (lessons):** set_field_region takes CELL coordinates, not pixels; Air temperature fields survive particle quenches and re-flash rebuilds on unpause; H2 fusion requires particle temp AND cell pressure simultaneously

**Scale up:** For a reactor core use the chamber as the fuel bed (fill param) and put the breeder_liner along the DMND walls; the sump doubles as the neutron/heat exhaust path.

**Modules:** `pressure_chamber`, `breeder_liner`, `dmnd_throat`

**Variant — embedded pump lattice** (observed, saves 1186972, 895042): Single PUMP/VACU pixels embedded in a solid QRTZ/INSL lattice spacer every 4-20 rows pressurise many small already-solid cells without a wall frame per cell. Use for fuel lattices; the wall-boxed chamber stays the choice for one open volume.

## L3 · self_healing_liner  (materials, observed)

**Goal:** A self-breeding wall: a barrier (or fuel column) that regrows after damage.

**Steps**
1. `{"module": "clne_liner", "at": [0, 0], "params": {"length": 40}}`
2. The CLNE is armed with INSL by the compiler (ctype prop) and kept cold; cap both ends with solid INSL so it cannot creep.
3. Test: erase a 5px gap in the INSL above the liner, run 60 frames.

**Verify:** The gap is refilled with INSL within 60 frames; CLNE count unchanged.

**Pitfalls (lessons):** CLNE with ctype INSL makes a self-healing insulation liner; CLNE learns ctype on touch then emits it forever; CLNE armed to NEUT ctype triggers real full-pile DEUT chain reaction fast

**Scale up:** Same trick gives infinite coolant (CLNE ctype DSTW), infinite cryogen (cryo_column_ln2) and self-breeding fuel (breeder_liner) — but a CLNE armed to NEUT or a hot CLNE is a bomb: keep every cloner cold and away from the reaction zone.

**Modules:** `clne_liner`, `cryo_column_ln2`, `breeder_liner`

**Variant — self-breeding fuel wall** (observed, save 214245 thrm_breeder_wall): A 477-particle CLNE(THRM) column re-breeds thermite continuously - the CLNE-liner pattern works for any breedable fuel, not only INSL/DEUT. Same cautions: keep the cloner cold and away from the reaction zone.

## L3 · cryogenic_supply  (thermal, observed)

**Goal:** Keep a cryogen alive and deliver it where it is needed.

**Steps**
1. `{"module": "cryo_column_ln2", "at": [0, 0], "params": {}}`
2. Every cryogen you place must carry props temp_c below its boiling point (LN2: -196 C); the compiler will not do it for you (cryo_no_cold_temp lint).
3. Route it through INSL-lined channels or an insl_air_shaft; never through METL.

**Verify:** LN2 count inside the column is constant over 300 frames; INSL liner outer face within 20 K of ambient.

**Pitfalls (lessons):** Cryogenic liquids spawn at ambient temperature; LN2 is LNTG and dies by deletion at 77K; Infinite cryogen reservoir: INSL-lined TTAN-capped LN2 column with one cold CLNE(LN2) at the core

**Scale up:** Feed magnets/condensers with HEAC lines from the reservoir (FSN-2 cryoplant pattern: ICE reservoir at 60 K + HEAC cryoline); valve the line like tank_with_valve.

**Modules:** `cryo_column_ln2`, `insl_air_shaft`

**Variant — on-demand quench nozzle** (observed, save 1289009 ln2_quench_fuel_column): Small LN2 pocket topped up by CLNE(LN2) at rest; a PCLN(LN2) nozzle fires onto the fuel rod only when a TSNS threshold ladder trips - emergency quench instead of continuous cooling.

## L3 · status_display  (rendering, observed)

**Goal:** Show plant state on a panel that a human (or a screenshot) can read.

**Steps**
1. `{"module": "lcry_lamp_13", "at": [0, 0], "params": {"channel": 24}}`
2. `{"module": "lcry_bar_gauge", "at": [20, 0], "params": {}}`
3. Drive each lamp from a sensor: TSNS (temp threshold in its temp) or PSNS (pressure) -> PSCN -> WIFI on the lamp's channel.

**Verify:** Heating the TSNS above its threshold lights the lamp within 10 frames; cooling clears it via the reset channel.

**Pitfalls (lessons):** Control console pattern: SWCH/HSWC button pads per WIFI channel, 13x13 LCRY lamps set/reset by two channels; PSCN must touch LCRY directly; 1px gap silently kills lamp panels; Decoration only lands where particles already exist; Deco alpha 255 fully replaces an element colour

**Scale up:** One lamp per functional system (fuel, coolant, pressure, cryo, fault); put the console in GLAS but keep the WIFI bus jacketed behind it.

**Modules:** `lcry_lamp_13`, `lcry_bar_gauge`, `button_pad`, `lcry_panel`

**Variant — seeded GLOW field** (observed, saves 2591226, 2001108): Scatter GLOW through the core; each GLOW learns a different ctype by touch (60+ ctypes in 2591226), giving a live what-touches-what map of the whole core for far fewer particles than a gauge per point.

## L4 · heat_extraction_loop  (thermal, observed)

**Goal:** Move heat from a hot core to a condenser and back, continuously.

**Steps**
1. `{"module": "shld_pipe_riser", "at": [0, 0], "params": {"length": 60}}`
2. `{"module": "dstw_reservoir_manifold", "at": [10, 60], "params": {}}`
3. Coolant is DSTW (non-conductive). Pipe runs are PIPE sheathed in SHLD (self-repairing). Put a clne_liner under the pipe bundle. Condense in a TTAN box at low temperature; return by gravity or PUMP.
4. Alternative for distance: a portal_pair (PRTI at the core, PRTO at the condenser) — remember the portal pads sit at channel temperature.

**Verify:** Core temperature (TSNS at the core) falls and the condenser temperature rises over 600 frames; DSTW count in the loop constant (no leaks, no boiling losses).

**Operating bands:** `{"source": "TPT forum Thread=27188 'MONR reactor manual' via research round 2", "boiler_c": {"min": 130, "max": 180, "note": "below 130 boils inefficiently, above 180 overheats"}, "coolant_container_c": {"optimal": [70, 80], "warn_at": 90}, "verify_bands": ["boiler region tavg 130-180 C", "coolant reservoir tavg 70-80 C, never >=90 C", "no PRTI/PRTO in the liquid loop (ghost heat)"]}`

**Pitfalls (lessons):** Sheathe long PIPE runs in SHLD; SHLD self-repairs and its growth stages are normal; PRTI/PRTO channel pairs teleport coolant and heat; portal temp equals channel state; Fusion power train runs steam-dominant: condense-flash-recirculate with a condenser duty cycle; An INSL deck does not stop a METL/GOO surface deck from heat-soaking to one temperature

**Scale up:** Two independent loops per core (one can be valved off while the other runs); a condenser duty cycle (see FSN-2 lesson) instead of continuous flow; steam turbine hall downstream.

**Modules:** `shld_pipe_riser`, `dstw_reservoir_manifold`, `portal_pair`, `clne_liner`, `cooling_tower`

## L4 · fission_core_plut  (containment, observed)

**Goal:** A PLUT/DEUT core that runs steadily instead of detonating.

**Steps**
1. `{"module": "nscn_fuel_head", "at": [0, 0], "params": {}}`
2. `{"module": "dmnd_throat", "at": [0, 36], "params": {}}`
3. `{"module": "pressure_chamber", "at": [-8, 52], "params": {"width": 40, "height": 32, "fill": "DEUT"}}`
4. Order: walls of the pressure boxes first, then DMND/TTAN/NSCN structure, then PUMP/VACU fills, then fuel (PLUT bed, DEUT), then CLNE seeds armed by touch, then pipes/portals, then logic. Keep paused throughout.
5. Meter the trigger: one small NEUT source (CRAY ctype NEUT fired for <=10 frames) — never a CLNE armed to NEUT touching the pile.

**Verify:** DEUT sum-of-life rises slowly (breeding) and NEUT count stays < 100 over 600 frames; DMND hotspot < 1500 C; no PLUT outside the bed.

**Operating bands:** `{"source": "TPT forum Thread=27188 'MONR reactor manual' (author-written operating numbers) via research round 2", "core_temp_c": {"hold": 500, "trip": 1064, "note": "1064 C triggers automatic neutron-poison injection in the source design"}, "control_rods": {"levels": "0 idle .. 4 fully inserted", "shutdown": "hold rods fully inserted 40 s (~2000 frames) before idling"}, "safe_shutdown": {"temp_c_below": 160, "pressure_below": 5}, "verify_bands": ["core TSNS 400-600 C during run", "no reading above 1064 C without poison injection firing", "after shutdown: core <160 C and |pressure| <5"]}`

**Pitfalls (lessons):** NEUT+DEUT fusion trigger = DeutExplosion chain reaction; DEUT reactor yield control: meter the trigger, derate the bed, never rain+boost a full charge; PLUT spontaneous fission under pressure + NEUT interactions; DEUT life=concentration, maxlife formula; Packed DEUT is the stable non-destructive light source

**Scale up:** Add remote_flood_and_drain pods to the chamber, heat_extraction_loop on the sump, status_display on TSNS/PSNS — that is the whole community save 78400.

**Modules:** `nscn_fuel_head`, `dmnd_throat`, `breeder_liner`, `pressure_chamber`, `injector_pod`, `drain_pod`

**Variant — zero-inventory idle core** (observed, save 254630 (x247-268,y276-291)): No resident PLUT/DEUT/NEUT at rest: the charge is a PCLN grid armed to fuel that only synthesises fissile material while the console sparks it, and drains back out through a PRTI floor when power is cut. Preferred cold-start/idle state; keep a resident pile only for the hot demo.

## L5 · fusion_shot  (thermal, verified)

**Goal:** Ignite H2/DEUT fusion on purpose and survive it.

**Steps**
1. Vessel: TTAN structure and blanket (never TUNG — shatters on every shot); DMND rings inside; LITH breeder in double-DMND pods; WATR coolant ring outside; METL cryostat outside that.
2. Fuel: H2 at ~45% checkerboard density plus a DEUT pool in the annulus.
3. Shot recipe (FSN-2, proven): sector cells pressure 70 via set_field_region (CELL coords), fuel flashed to 4000 K, then unpause. Ignition is a race between the 1/5 roll and the thermal+pressure quench.
4. Only NBLE-sourced plasma self-sustains; PLSM melts every structural element and burns out — it is not a light source.

**Verify:** Plasma appears within 60 frames and the TTAN vessel census is unchanged after 600 frames (no TTAN loss, no fuel outside the vessel).

**Pitfalls (lessons):** H2 fusion requires particle temp AND cell pressure simultaneously; Fusion ignition is a race between the 1/5 roll and thermal+pressure quench; TUNG blanket shatters on every fusion shot; use TTAN structure + vacuum-insulated LITH pods; PLSM melts every structural element; Only NBLE-sourced plasma is self-sustaining; Controlled vs runaway fusion shot intensities in a TTAN vessel

**Scale up:** Full plant = FSN-2 registry: 8 GOLD coils at 20 K on a cryoplant, fuel depot with plug valves, heat pipe to a boiler, turbine hall, control room with 3 channel lamps. Master stamp 6a8ced9300.

**Modules:** `dome_vessel`, `cryo_column_ln2`, `portal_pair`, `cooling_tower`

## L5 · plant_integration  (workflow, observed)

**Goal:** Assemble many practices into one plant without the interactions killing it.

**Steps**
1. Budget: large solid fills dominate particle count — hollow every shell, use wall types for pressure boundaries, target < 60k particles.
2. Allocate WIFI channels in a table first (one per function, low numbers near fuel/flammables); run blueprint_lint on the whole plan and clear criticals.
3. Build in this order: walls -> structure -> fills -> fuel -> cloners -> pipes/portals -> logic -> decoration; stamp after each stage.
4. Commission one system at a time with all valves closed: cryo, then coolant loop, then logic/lamps, then fuel, then the first metered shot.
5. After every change: census + one lesson.

**Verify:** Each subsystem's own verify passes in situ (not just in isolation) and the whole-plant census is stable for 1000 frames with valves closed.

**Pitfalls (lessons):** Large solid fills dominate particle count; Instrument-bay wiring and hardening rules from Torus One commissioning; Rewind ring + registered cleanup + restore discipline; Audit before delete: whitelist sweeps must log offending types first

**Scale up:** This is the top level; scale by cloning proven sections as stamps, not by drawing new ones.

## L3 · generate_power  (electrical, verified)

**Goal:** Turn heat into a usable electrical signal with realistic parts: UO2/B4C fuel assembly -> steam -> TRBN turbine -> CU busbar -> LEDL, plus a TEG on waste heat.

**Steps**
1. Run python scripts/define_power_elements.py once per game session (custom elements are not persistent).
2. `{"id": "fa", "module": "fuel_assembly_uo2", "at": [0, 0], "params": {"pins": 3, "height": 20}}`
3. `{"id": "ts", "module": "steam_turbine_stage", "at": ["fa.right+20", "fa.top"], "params": {"width": 24, "height": 16}}`
4. `{"box": "WTRV", "at": ["ts.left+2", "ts.top+2"], "size": [20, 12], "props": {"temp_c": 150}}`
5. `{"module": "teg_waste_heat", "at": ["fa.left", "fa.bottom+4"], "params": {"length": 10}}`
6. Withdraw the B4C rod (erase it) to raise NEUT flux; re-insert to scram. Watch B4C tmp (captures) and TRBN tmp (work).

**Verify:** Over 120 frames: TRBN tmp (work) rises, WTRV in the chest falls and DSTW appears, B4C tmp rises while UO2 is uncovered, and SPRK appears on the CU bars (sample every 5 frames).

**Operating bands:** `{"source": "live tests P1-P3 2026-08-26", "trbn_work_per_120f": ">=20 with a full steam chest", "teg_on_temp_c": 100}`

**Pitfalls (lessons):** Power element set verified: UO2->NEUT, B4C absorbs, TRBN steam->work->SPRK, TEG heat->SPRK; bridge needs custom ids; Use DSTW, not WATR, for coolant that touches conductors or logic; WIFI touching coolant boils it; high-channel WIFI melts TTAN — INSL-ring pods before embedding them; check param names

**Scale up:** Series turbine stages on one steam chest; a boiler between the assembly and the chest (heat_extraction_loop bands 130-180 C); AERO lagging on every hot line; LEDL panels instead of hot LCRY/WIFI for status.

**Modules:** `fuel_assembly_uo2`, `steam_turbine_stage`, `teg_waste_heat`, `clne_liner`

## L4 · realistic_fission_core  (containment, proposed)

**Goal:** A UO2/B4C/HF fission core with realistic melting-point margins, contained in a layered STEL/CNCR/LEAD vessel.

**Steps**
1. Run python scripts/define_power_elements.py once per game session (custom elements are not persistent).
2. `{"id": "rpv", "module": "rpv_steel_vessel", "at": [0, 0], "params": {"width": 70, "height": 50}}`
3. `{"id": "fb", "module": "pwr_fuel_bundle", "at": ["rpv.left+14", "rpv.top+14"], "params": {"pins": 3, "height": 20}}`
4. `{"id": "rod", "module": "control_rod_drive_b4c", "at": ["fb.right+4", "rpv.top+10"], "params": {"stroke": 10, "bore": 3}}`
5. Withdraw the control_rod_drive_b4c PSTN (erase the rod) to raise flux past pwr_fuel_bundle's HF trim rod; watch B4C/HF tmp (captures) and UO2's steady NEUT emission. Re-insert to scram.

**Verify:** Census inside rpv_steel_vessel's inner STEL cavity shows the fuel bundle and rod intact after 300 frames with the LEAD layer outermost and unmelted; B4C/HF tmp (captures) only climbs while the corresponding rod is inserted, and no element in the stack exceeds its own highTemperature.

**Operating bands:** `{"source": "derived from power-elements-2026-08-26.json melting/capture data, not yet run live", "uo2_melt_c": 2865, "zirc_clad_melt_c": 1852, "b4c_melt_c": 2763, "hf_melt_c": 2233, "lead_melt_c": 327, "note": "keep clad and rod temperatures far below these melt points; verify live before trusting exact numbers"}`

**Pitfalls (lessons):** UO2 emits NEUT continuously regardless of rod position -- there is no chain-reaction runaway in this element set (unlike PLUT/DEUT), so 'criticality' here means neutron economy and clad temperature, not an explosion risk; LEAD must be the outermost, coolest layer of rpv_steel_vessel -- it melts at only 327 C, far below STEL (1500 C) or CNCR (spalls at 1200 C); STEL is the pressure boundary and must always face the fuel side, never the reverse; This practice was authored and compiled offline (2026-08-26); it has not yet been run live in-sim -- treat the operating_bands as design targets, not measurements

**Scale up:** Stack multiple pwr_fuel_bundle instances inside one rpv_steel_vessel cavity for a multi-assembly core; feed the vessel's heat into a steam_generator (see electrical_generation_chain) instead of venting it, and add a status_display TSNS ladder on the vessel's STEL face.

**Modules:** `pwr_fuel_bundle`, `control_rod_drive_b4c`, `rpv_steel_vessel`

## L4 · electrical_generation_chain  (electrical, proposed)

**Goal:** A full realistic power chain: UO2 fuel assembly -> NAK/steam generator -> CU condenser -> TEG waste-heat panel -> independent SIPV solar leg, all onto one CU bus.

**Steps**
1. Run python scripts/define_power_elements.py once per game session (custom elements are not persistent).
2. `{"id": "fa", "module": "fuel_assembly_uo2", "at": [0, 0], "params": {"pins": 3, "height": 20}}`
3. `{"id": "sg", "module": "steam_generator", "at": ["fa.right+16", "fa.top"], "params": {"width": 36, "height": 24}}`
4. `{"id": "cd", "module": "condenser_cu", "at": ["sg.right+10", "sg.top"], "params": {"tubes": 4, "height": 20, "gap": 6}}`
5. `{"id": "tw", "module": "teg_wall_panel", "at": ["sg.left", "sg.bottom+6"], "params": {"count": 4}}`
6. `{"id": "pv", "module": "pv_array_sipv", "at": ["tw.right+10", "tw.top"], "params": {"count": 5}}`
7. Tie every module's CU bus together with a CU/INWR trunk line; each subsystem contributes SPRK independently (TRBN work pulses, TEG waste-heat pulses, SIPV under incident light) onto the shared bus.

**Verify:** Over 300 frames: TRBN tmp (work) in steam_generator rises while its WTRV falls and DSTW appears; condenser_cu's DSTW bath temperature climbs; teg_wall_panel's TEG cells exceed 100 C and pulse SPRK onto their bus; pv_array_sipv produces SPRK only while PHOT is actually incident on it.

**Operating bands:** `{"source": "derived from power-elements-2026-08-26.json + materials-catalog.json, not yet run live", "teg_on_temp_c": 100, "nak_operating_c": [400, 700], "note": "bands are design targets from element data; verify live before trusting exact numbers"}`

**Pitfalls (lessons):** NAK is flammable in air (rating 400) -- keep the primary loop sealed inside steam_generator's STEL shell, never vent it to open atmosphere; TRBN needs WTRV specifically, not DSTW/WATR, to do work; TEG stops pulsing once it drops below its onTemp (100 C) -- site teg_wall_panel on a face that stays hot; SIPV produces nothing without incident PHOT -- this leg of the chain is independent of the thermal legs and needs its own light source; This practice was authored and compiled offline (2026-08-26); it has not yet been run live in-sim

**Scale up:** Series multiple steam_generator/condenser_cu pairs off one fuel_assembly_uo2 for more turbine stages; add nas_battery_rack or pcm_thermal_battery downstream of the CU trunk (see energy_storage_bank) to store the combined output instead of only showing it on LEDL.

**Modules:** `fuel_assembly_uo2`, `steam_generator`, `condenser_cu`, `teg_wall_panel`, `pv_array_sipv`

## L2 · chemical_safety_cell  (safety, proposed)

**Goal:** House genuinely reactive chemistry (NA+water, CAC2+water, MG combustion, CAO slaking) in separated, contained demo cells that do nothing until deliberately triggered.

**Steps**
1. `{"id": "na", "module": "sodium_fire_demo", "at": [0, 0], "params": {"width": 20, "height": 20}}`
2. `{"id": "cl", "module": "carbide_lamp", "at": ["na.right+10", "na.top"], "params": {"width": 12, "height": 16}}`
3. `{"id": "mg", "module": "mg_flare", "at": ["cl.right+10", "na.top"], "params": {"height": 14}}`
4. `{"id": "lk", "module": "lime_kiln", "at": ["na.left", "na.bottom+6"], "params": {"width": 20, "height": 16}}`
5. Keep every hazard cell physically separated by at least one empty column and its own containment shell (FBRK/S316) -- never share a wall between two independent reactive-chemistry demos.

**Verify:** At rest (paused) census shows NA and WATR not yet touching in sodium_fire_demo, CAC2 and its WATR drip separated by an air gap in carbide_lamp, and MG only touching OXYG/FIRE at its own tip in mg_flare -- nothing reacts until a cell is deliberately triggered.

**Pitfalls (lessons):** NA+WATR/DSTW is genuinely violent (+600 K, ignites the H2 byproduct) -- never build this with a conductive enclosure or near stored fuel/logic; CAC2+water makes flammable acetylene GAS -- only ignite the vented gas at the nozzle, never inside the sealed chamber; Real magnesium fires cannot be extinguished with water or CO2 (both react with burning Mg) -- keep any fire-suppression element away from mg_flare; CAO+water is a real +300 K exotherm (lime slaking) even though dry CAO is inert -- treat lime_kiln's charge as live the moment water is added; This practice was authored and compiled offline (2026-08-26); it has not yet been run live in-sim

**Scale up:** One containment cell per reactive chemistry, one shared inert corridor between cells, and a single remote spark/valve trigger per cell (see wire_a_signal) so no two hazard demos can be set off by the same accidental touch.

**Modules:** `sodium_fire_demo`, `carbide_lamp`, `mg_flare`, `lime_kiln`

## L3 · energy_storage_bank  (thermal, proposed)

**Goal:** Three independent energy-storage mechanisms side by side: a PCM thermal buffer, a molten NAS battery rack, and a superconducting-magnet LHE dewar.

**Steps**
1. `{"id": "pcm", "module": "pcm_thermal_battery", "at": [0, 0], "params": {"width": 20, "height": 16}}`
2. `{"id": "nas", "module": "nas_battery_rack", "at": ["pcm.right+10", 0], "params": {"width": 24, "height": 20}}`
3. `{"id": "cd", "module": "cryo_dewar_lhe", "at": ["nas.right+10", 0], "params": {"width": 30, "height": 26}}`
4. Route any surplus CU-bus power from electrical_generation_chain into nas_battery_rack to keep it above 300 C; route TEG/condenser waste heat into pcm_thermal_battery instead of venting it; keep cryo_dewar_lhe on its own insulated shaft, isolated from both hot subsystems.

**Verify:** Over 300 frames: pcm_thermal_battery's PCMP core holds within a few K of 58 C while heat is added or removed; nas_battery_rack's NAS core stays above 300 C without external heating once initialized at 320 C; cryo_dewar_lhe's LHE bath stays at -269 C with the NBTI coil particle count unchanged.

**Pitfalls (lessons):** PCMP above its 250 C decomposition point turns to SMKE and the buffer's charge is lost for good -- never let waste heat routed into pcm_thermal_battery exceed that; NAS below ~300 C freezes solid to SALT and stops functioning -- nas_battery_rack's AERO liner only slows the cool-down, it does not stop it, so a real build needs a standing trickle heater; Cryogenic liquids spawn at ambient temperature unless given an explicit cold props -- cryo_dewar_lhe's LHE bath must keep its temp_c: -269 prop or it flashes to NBLE immediately; This practice was authored and compiled offline (2026-08-26); it has not yet been run live in-sim

**Scale up:** Size nas_battery_rack to the CU-bus load from electrical_generation_chain; add a status_display TSNS ladder on each of the three modules so an operator can see which store is charged without opening the cabinet.

**Modules:** `pcm_thermal_battery`, `nas_battery_rack`, `cryo_dewar_lhe`
