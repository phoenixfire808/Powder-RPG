# Real Plant Engineering Research (research front 3/5, 2026-08-26)

Goal: make our reactor/plant modules and PLAYBOOK.md practices match real engineering numbers,
materials, and failure modes. Five parallel research passes (PWR/BWR; CANDU/RBMK; sodium-fast/molten-
salt; tokamak+gas-turbine+Rankine; PV-battery+hydrogen+geothermal) pulled citation-backed numbers,
mostly via WebFetch against Wikipedia/World Nuclear Association/ITER.org/manufacturer pages (WebSearch
quota was exhausted early in three of the five passes, so those relied on direct URL fetches — gaps
are flagged inline rather than guessed). Cross-referenced against our actual inventory:
`knowledge/power-elements-2026-08-26.json` (UO2, ZIRC, GRPH, B4C, CU, STEL, CNCR, LEAD, NAK, AERO,
TRBN, TEG, LEDL), `knowledge/materials-catalog.json` + `-packs.json` (FLBE, LBE, NA, THOR, BE, CD,
B10, U235, TRIT, CF252, CO60, AM241, RA226, NBTI, SIC, ZRCA, GAAS, LH2, LHE, PCMP, PCMS, NAS, PZT,
S316, TI64, INC7, WC, RBAR, and the building-material set), and existing `knowledge/modules/*.json`
(rpv_steel_vessel, pwr_fuel_bundle, control_rod_drive_b4c, fuel_assembly_uo2, steam_generator,
condenser_cu, steam_turbine_stage, teg_waste_heat/teg_wall_panel, nas_battery_rack, cryo_dewar_lhe,
pv_array_sipv, sodium_fire_demo, rbmk_channel_cell, rbmk_rod_drive). No files other than this one were
written; the game was not touched.

**How to read each section:** real numbers with citation -> element mapping (real material/component ->
game element, with melt-point cross-check against our actual data) -> module layout recommendation
(built from existing modules where possible) -> failure modes with an observable signature suitable for
`run_test`/census assertions. A consolidated `operating_bands` JSON block (playbook-schema) is at the
end.

---

## 1. PWR (Pressurized Water Reactor — Westinghouse 4-loop / AP1000-class)

**Real numbers.** Coolant inlet **~275 C**, outlet **~315 C**, average core **~325 C**, pressurizer
**345 C**, primary pressure **~155 bar (15.5 MPa)** (https://en.wikipedia.org/wiki/Pressurized_water_reactor,
https://world-nuclear.org/information-library/nuclear-fuel-cycle/nuclear-power-reactors/nuclear-power-reactors).
UO2 melts **2865 C** (https://en.wikipedia.org/wiki/Uranium_dioxide) — matches our UO2 element's
`highTemperature` exactly (3138.15 K = 2865 C). Enrichment **3.5-5.0%**
(world-nuclear.org, above). Zircaloy cladding oxidizes rapidly above **1500 K (1230 C)**
(https://en.wikipedia.org/wiki/Zirconium_alloy) — our ZIRC melts at 1852 C, so the real oxidation limit
sits well below our melt point; treat 1230 C as the "safe" ceiling, not 1852 C. Fuel rod ~1 cm diameter,
179-264 rods/assembly in 14x14 to 17x17 arrays, ~4 m active length; 150-250 assemblies/core, 18-24 month
refuel cycle, ~1/3 core replaced each cycle (https://en.wikipedia.org/wiki/Fuel_rod, world-nuclear.org
above). Control rods Ag-In-Cd (80/15/5), ~20 rods/assembly, boron dissolved in coolant for slow trim
(https://en.wikipedia.org/wiki/Control_rod). Scram insertion **~2 s for 90% reduction**, some modern
designs <1 s (same source). Steam generator secondary: feedwater in **220 C**, saturated steam out
**275 C / 6.2 MPa** (https://en.wikipedia.org/wiki/Steam_generator_(nuclear_power)) — matches our
`heat_extraction_loop` boiler band (130-180 C) being conservative/low by comparison; our
`steam_generator` module's WTRV is set at 170 C, closer to the low end. HP turbine inlet **6 MPa /
275.6 C, quality ~0.995**; condenser **0.008 MPa abs, ~41.5 C, exhaust quality ~90%**
(https://www.nuclear-power.com/nuclear-power-plant/turbine-generator/). Thermal efficiency **33-37%**
(world-nuclear.org). AP1000: **1117 MWe net**, passive core cooling **72 hours** without AC power
(station blackout coping time) (https://en.wikipedia.org/wiki/AP1000). RPV steel wall up to **~30 cm**;
containment concrete **>=1 m**, design pressure **275-550 kPa**
(https://world-nuclear.org/information-library/safety-and-security/safety-of-plants/safety-of-nuclear-power-reactors,
https://en.wikipedia.org/wiki/Containment_building). Decay heat: **~5-7%** at trip, **~1-1.5%** at 1 hr,
**~0.4-0.5%** at 1 day, **~0.2%** at 1 week (https://en.wikipedia.org/wiki/Decay_heat). ECCS/LOCA limit
per 10 CFR 50.46: peak cladding temp **<=1204 C (2200 F)**, max local oxidation **<=17%**, max H2
generation **<=1%** of theoretical (https://en.wikipedia.org/wiki/Boiling_water_reactor_safety_systems,
same clause binds PWR). Real LOCA data point: TMI-2 (1979) melted **~45% of the core (62 t)** after loss
of forced cooling (https://world-nuclear.org/information-library/safety-and-security/safety-of-plants/three-mile-island-accident).

**Element mapping.** UO2->UO2 (melt matches exactly), ZIRC->ZIRC (clad; treat 1230 C as the real trip
point, not the 1852 C melt), GRPH->GRPH (moderator gap, though PWR moderator is really borated light
water — DSTW with a `ctype`/temp tag is the closer analogue than GRPH, which belongs to RBMK/CANDU),
B4C or CD->control rod (real Ag-In-Cd has no direct element; B4C is the nearer stand-in already used;
CD (melts 321 C, absorber chance 0.92) is available for a lower-melting, faster-responding alternate
rod), STEL->RPV pressure boundary, CNCR->biological shield, LEAD->outer gamma shield (already the exact
layout of `rpv_steel_vessel`), NAK is wrong for PWR primary (that's sodium, use DSTW at 275-315 C
instead), WTRV/DSTW->secondary steam/condensate, TRBN->turbine work, CU->generator bus.

**Module layout recommendation.** `pwr_fuel_bundle` + `control_rod_drive_b4c` inside `rpv_steel_vessel`
(already built, see `realistic_fission_core` L4 practice) is structurally correct. Two changes to bring
it closer to real numbers: (1) fill the vessel's STEL cavity with DSTW at `props.temp_c: 275-315` instead
of leaving it empty, so the loop actually models the 275/315 in/out split; (2) feed that DSTW into
`steam_generator` with its `sg_primary` NAK swapped for DSTW at the same temp (PWR's primary is water,
not sodium — NAK belongs to the SFR/steam_generator combination, not PWR). Geometry ratio: real RPV wall
(STEL) : biological shield (CNCR) : gamma shield (LEAD) thickness is roughly 1 : 3-4 : thin outer skin —
`rpv_steel_vessel`'s hollow values (3/4/3 px) already approximate this ordering; keep it.

**Failure modes to simulate.**
- **Large-break LOCA**: erase a section of the primary DSTW boundary (simulate a pipe break) with pumps
  still running. Signature: DSTW count in the vessel core falls toward 0 within ~120 frames, UO2 tmp
  (captures) climbs past the ZIRC 1230 C analogue before any B4C/CD insertion; assert core dry-out
  (DSTW count < 10% of nominal) precedes ZIRC exceeding 1230 C by some margin, mirroring the real
  10CFR50.46 clad-temp criterion.
- **Station blackout**: kill all PUMP/WIFI power to the vessel and injector pods, leave the core sealed.
  Signature: core temp should decay on the real decay-heat curve shape (fast initial drop in heat
  generation rate, not a cliff) — assert TSNS readings fall by roughly an order of magnitude over the
  first simulated "hour" (arbitrary frame-to-time mapping) rather than instantly, and that an unpowered
  core does NOT reach ZIRC melt (1852 C) within the AP1000's 72-hour passive-cooling-equivalent frame
  budget if a passive DSTW gravity-drain reserve is present.
- **Control-rod ejection** (rapid, uncontrolled withdrawal, historically a PWR-specific accident class):
  fully erase B4C/CD instantaneously rather than gradually. Signature: NEUT/UO2 flux count spikes within
  a handful of frames; assert the spike is detected by a TSNS ladder and a scram (B4C re-insertion)
  trigger fires before UO2 tmp exceeds its melt point.

---

## 2. BWR (Boiling Water Reactor — GE BWR/4-6 class)

**Real numbers.** Core/steam-dome pressure **~75 atm (7.6 MPa)**, coolant boils in-core at **~285 C**
(https://en.wikipedia.org/wiki/Boiling_water_reactor, world-nuclear.org above). Recirculation flow
**~45,000,000 kg/h**, steam flow **~6,500,000 kg/h**, core-average void fraction **~40%**, core-exit
steam quality **~12-15%** (same sources). Fuel: UO2, 3.5-5.0% enrichment; assemblies 74-100 rods (modern
bundles 91/92/96), He backfill ~3 atm; up to ~800 assemblies/core, ~140 short tons U loading
(https://en.wikipedia.org/wiki/Boiling_water_reactor, https://en.wikipedia.org/wiki/Fuel_rod,
world-nuclear.org). Linear heat rate limit **~13 kW/ft (43 kW/m)**
(https://en.wikipedia.org/wiki/Boiling_water_reactor). Control: B4C blades inserted from BELOW the core
(inverted vs. PWR's top entry), flow-rate is a secondary control knob
(https://en.wikipedia.org/wiki/Boiling_water_reactor). RPS trips: high neutron flux (APRM), high RPV
pressure, low water level, MSIV closure >10%
(https://en.wikipedia.org/wiki/Boiling_water_reactor_safety_systems). ECCS: HPCI ~19,000 L/min (~10 s
spin-up), RCIC ~2,000 L/min (~30 s start), LPCS up to 48,000 L/min, LPCI up to 150,000 L/min (same
source). ADS triggers on Low-Low-Low level, **105 s timer**, depressurizes below ~32 atm to admit
low-pressure injection (same source). Same 10 CFR 50.46 cladding limit (1204 C) as PWR. Thermal
efficiency **33-37%**. Real station-blackout data (Fukushima Daiichi, MAAP analysis): Unit 1 core damage
at **~3 h 9 min** after SBO (isolation condenser only, lost early), Unit 3 **~43 h 8 min**, Unit 2
**~76 h 6 min** (both had steam-driven RCIC/HPCI running longer)
(https://world-nuclear.org/information-library/safety-and-security/safety-of-plants/fukushima-daiichi-accident)
— the ~25x spread between units is entirely down to whether steam-turbine-driven injection (no AC
power needed) kept running.

**Element mapping.** Same UO2/ZIRC/B4C/STEL/CNCR/LEAD set as PWR, but coolant is boiling in-vessel
directly — model with WTRV/DSTW mixed region rather than a separate steam generator (BWR has no
secondary loop; the core itself makes the steam that drives the turbine). TRBN sits directly downstream
of the vessel, not behind a heat-exchanger module.

**Module layout recommendation.** Reuse `rpv_steel_vessel` + `fuel_assembly_uo2`/`pwr_fuel_bundle`, but
skip `steam_generator` — connect the vessel's internal DSTW/WTRV mix straight to `steam_turbine_stage`,
matching BWR's single-loop design. Insert B4C from the *bottom* of the fuel bundle (flip
`control_rod_drive_b4c`'s orientation) to reflect real BWR bottom-entry rods; this is also a testable
design difference from PWR's top-entry `control_rod_drive_b4c`.
Add an `injector_pod`-based ADS analogue: a WIFI-triggered pod that vents WTRV pressure (drain to a
sump) once a PSNS sensor crosses the high-pressure trip, timed with a DLAY set to emulate the 105 s
ADS timer.

**Failure modes to simulate.**
- **Loss of feedwater / low water level scram**: drain DSTW/WTRV from the vessel while fuel keeps
  emitting NEUT. Signature: a low-level PSNS/TSNS-equivalent sensor should trip B4C insertion within a
  few frames of the level crossing threshold, exactly like the real "low reactor water level" RPS trip.
- **Station blackout with/without steam-driven injection**: compare two runs — one where an
  `injector_pod` keeps injecting DSTW using only a steam-turbine-driven pump analogue (no WIFI/PUMP
  power needed), one where all injection stops immediately. Signature: core temp in the powered-pump
  run should stay below ZIRC's 1230 C oxidation-equivalent far longer (mirroring the Fukushima Unit
  1 vs Unit 2/3 spread) than the fully-blacked-out run.
- **ADS logic**: verify the vent pod fires only after the Low-Low-Low signature AND the DLAY timer
  elapses, not instantly — a premature vent should be flagged as a lint-style failure.

---

## 3. CANDU (pressurized heavy-water reactor)

**Real numbers.** Heavy water (D2O) is both moderator (low-pressure calandria) and coolant (separate
pressurized heat-transport loop) (https://en.wikipedia.org/wiki/CANDU_reactor). CANDU-6 primary
heat-transport pressure **10.3 MPa**, outlet coolant **312 C** (inlet not confirmed via an accessible
source this pass — commonly cited ~266 C but unverified here, so do not treat that number as sourced).
Natural-uranium UO2 fuel, **0.72% U-235, no enrichment** (same source) — this is the single biggest
real-engineering difference from PWR/BWR/RBMK, all of which need enriched fuel. 37-element bundle
(CANFLEX = 43-element), ~50 cm long, ~10 cm diameter, loaded online via a fueling machine, ~12-13
bundles/channel; CANDU-6 has 380 channels, CANDU-9 has 600, Bruce has 480 channels x 13 bundles
(https://en.wikipedia.org/wiki/CANDU_reactor, https://en.wikipedia.org/wiki/Bruce_Nuclear_Generating_Station).
Calandria tube ~7 m long, ~13 cm diameter (https://en.wikipedia.org/wiki/Point_Lepreau_Nuclear_Generating_Station).
Dual, independent shutdown systems: **SDS1** — cadmium/absorber rods held up by electromagnets, drop by
gravity on any trip signal or loss of power (fail-safe by design); **SDS2** — high-pressure injection of
gadolinium nitrate solution directly into the moderator, entirely separate mechanism from SDS1
(https://en.wikipedia.org/wiki/CANDU_reactor) — exact insertion/injection times in seconds were not
found in an accessible source this pass. Void coefficient small and positive but self-limiting; no
numeric value confirmed (https://en.wikipedia.org/wiki/Void_coefficient) — do not assume it behaves like
RBMK's much larger positive coefficient below. Power: CANDU-6 net **626 MWe** (676 MWe gross), Point
Lepreau 2064 MWth/660 MWe net (~32% thermal efficiency), Darlington (CANDU 850) 2776 MWth/878 MWe net
(~31.6%) (https://en.wikipedia.org/wiki/CANDU_reactor, https://en.wikipedia.org/wiki/Point_Lepreau_Nuclear_Generating_Station,
https://en.wikipedia.org/wiki/Darlington_Nuclear_Generating_Station). Pickering/Bruce sites add a shared
"Vacuum Building" for steam suppression during a large primary leak (https://en.wikipedia.org/wiki/CANDU_reactor).

**Element mapping.** No distinct D2O element exists in our inventory — the closest analogue is DSTW
(non-conductive water) tagged with `props.temp_c` at CANDU's real 312 C outlet, used for BOTH the
calandria moderator pool AND, in a separate sealed loop, the primary heat-transport coolant; this is a
genuine gap worth flagging rather than papering over (see below). Fuel: natural-uranium UO2 has no
distinct low-enrichment element from our fission set — reuse UO2 but treat its steady NEUT emission as
representing a much lower flux per unit mass than the enriched PWR case (there's no natural way to
derate the emitter's `interval` param per-instance without a custom element edit). Control: CD (melts
321 C, matches "cadmium" absorber almost exactly) is the correct SDS1 rod material, closer than B4C.
STEL for calandria/pressure-tube structure; TTAN or STEL for the vacuum-building shell.

**Module layout recommendation (new module needed — `candu_calandria`, not yet built).** A large
low-pressure DSTW pool (the calandria, at moderator temp) containing many horizontal `pwr_fuel_bundle`-
style channels, each channel itself a pressurized sub-tube (small STEL-walled cylinder) carrying hotter
DSTW at 312 C past the fuel — i.e. two nested, separately-tracked DSTW temperatures in one module,
which is a real structural feature (calandria vs. pressure-tube) our current single-vessel
`rpv_steel_vessel` pattern doesn't capture. Two independent CD-rod-drop shutdown heads (SDS1) into the
calandria pool, plus a WIFI-triggered PCLN(some poison ctype) injector as the SDS2 analogue, sitting
outside the fuel channels rather than inside them (SDS2 poisons the moderator, not the fuel itself).

**Failure modes to simulate.**
- **Loss of coolant with intact moderator**: drain the pressure-tube DSTW but leave the calandria pool
  full. Signature: fuel channel temp should rise toward ZIRC-equivalent limits, but the moderator pool
  (separate DSTW body) should stay near its own baseline temp, demonstrating the CANDU-specific
  "moderator as passive heat sink" property that most other reactor types lack.
- **Dual shutdown failure**: with both SDS1 (CD rods) and SDS2 (poison injector) disabled, run a
  positive-reactivity transient. Signature: since neither shutdown path exists, NEUT/UO2 emission should
  climb unchecked — this is the correct "worst case" signature to contrast against a single-SDS success
  case, honoring the real design intent that either system alone is sufficient.

---

## 4. RBMK (graphite-moderated, light-water-cooled — Chernobyl-class RBMK-1000)

**Real numbers.** Graphite moderator blocks around individual zirconium-alloy pressure tubes carrying
boiling light water; channel pressure **6.9 MPa**, inlet **265-270 C**, outlet **284 C**
(https://en.wikipedia.org/wiki/RBMK). Coolant flow **46,000-48,000 m3/h**, steam flow at full power
**5,440-5,600 t/h** (same source). Core: **1661 fuel channels + 211 control-rod channels** (Gen-2/
Chernobyl-class; Gen-1 was 1693+170), diameter **~11.8-12 m**, height **~7 m**, channel pitch **25 cm**,
graphite mass **~1700 t**, fuel loading **~192 t**
(https://en.wikipedia.org/wiki/RBMK, https://world-nuclear.org/information-library/safety-and-security/safety-of-plants/chernobyl-accident).
Fuel: enriched UO2 at **2% U-235** (raised from 1.8% pre-accident), rod OD 13.6 mm, active length 3.4 m,
18 rods + 1 carrier rod/assembly, 114.7 kg U/assembly (https://en.wikipedia.org/wiki/RBMK). **Control rod
design flaw**: boron carbide absorber PLUS a 4.5 m graphite "displacer" tip and a 1.25 m water-filled
telescoping section below it; insertion speed ~0.4 m/s, full insertion **18-21 s**
(https://en.wikipedia.org/wiki/RBMK). **Positive scram effect**: because withdrawn rods parked their
graphite displacer tips in the lower channel (displacing absorbing water), the first seconds of a scram
push moderating graphite further down before the absorbing boron carbide arrives, transiently *raising*
reactivity in the lower core — known internally since 1983, never corrected before Chernobyl
(https://en.wikipedia.org/wiki/RBMK, https://en.wikipedia.org/wiki/Chernobyl_disaster). Void coefficient
strongly positive: **4.7 beta_eff before the accident, reduced to 0.7 beta_eff afterward**
(https://en.wikipedia.org/wiki/Void_coefficient) — an order-of-magnitude design change post-accident.
**Chernobyl AZ-5 timeline** (26 Apr 1986): AZ-5 pressed **01:23:40**; power spike begins within seconds;
output exceeds 530 MW within **3 s**, peaks near **30,000 MWth (~10x nominal)**; first explosion follows
within seconds of AZ-5; second, larger explosion (~225 t TNT equivalent) **2-3 s** after the first
(https://en.wikipedia.org/wiki/Chernobyl_disaster). Power: RBMK-1000 = 3200 MWth/1000 MWe, thermal
efficiency **31.25%** (https://en.wikipedia.org/wiki/RBMK). Containment: NO full Western-style dome —
only an upper biological shield disc (~3 m x 17 m, ~2000 t), lower biological shield, an annular water
tank, and localized pressure-suppression pools per channel group — a partial-containment design that was
a key factor in the scale of the release (https://en.wikipedia.org/wiki/RBMK, world-nuclear.org above).

**Element mapping.** Our existing `rbmk_channel_cell`/`rbmk_rod_drive` modules use URAN/METL/GLOW/PIPE
(the built-in Powder Toy elements), NOT our custom power-elements set (UO2/ZIRC/GRPH/B4C) — this is a
real inconsistency worth closing: a more realistic RBMK channel should use GRPH for the moderator block
(matches "graphite moderator", sublimes 3600 C in-game vs. real graphite ~3600-3900 C — good match),
UO2/ZIRC for the fuel channel (instead of URAN/METL), and a B4C-plus-GRPH-displacer rod for
`rbmk_rod_drive` to actually model the positive-scram flaw geometrically (a rod whose lower few px are
GRPH, not B4C, that only becomes solid absorber after it has traveled a few px downward — the game
equivalent of the real displacer-tip design).

**Module layout recommendation.** Extend `rbmk_channel_cell` (20 px pitch, verified, pulled pixel-exact
from a community save) by swapping its URAN pins for UO2-in-ZIRC-in-GRPH concentric layout (like
`fuel_assembly_uo2`'s pin cross-section) while keeping the 20 px channel pitch and PIPE riser layout as-
is — those are structurally sound. For `rbmk_rod_drive`, add a GRPH segment at the bottom few px of the
B4C rod body so that when the PSTN/FRME rod is *withdrawn*, that GRPH segment sits in the active channel
(mirroring the real displacer); insertion should then briefly increase local NEUT flux (a real GRPH
segment passing through before the B4C catches up) before suppressing it — directly testable.

**Failure modes to simulate.**
- **Positive-scram control-rod-ejection analogue**: trigger `rbmk_rod_drive` insertion from a fully-
  withdrawn state and sample NEUT/flux census every frame for the first 21 "seconds" (frame-scaled).
  Signature: a brief flux increase in the first few frames (from the GRPH displacer entering) followed
  by a sustained decrease once B4C arrives — asserting the transient exists is itself the useful test,
  since a build that shows monotonic flux decrease from frame 1 has NOT reproduced the real flaw.
- **Positive void feedback runaway**: boil a channel's coolant (WTRV fraction rising) while flux is
  already elevated, with no negative feedback. Signature: flux and boil fraction should mutually
  reinforce (rising flux -> more boiling -> higher void -> even more flux) rather than self-limit,
  distinguishing RBMK's coefficient sign from CANDU's near-self-limiting one above.
- **Loss of containment**: since RBMK has no full dome, model core breach venting directly to the ambient
  cell rather than to a bounded containment volume. Signature: pressure/particle census outside the
  plant boundary should rise measurably (unlike a PWR/BWR test where a containment wall box should hold
  it), reflecting the real design gap.

---

## 5. Sodium-cooled Fast Reactor (SFR — EBR-II / Phenix / BN-800 / PRISM-class)

**Real numbers.** Primary sodium loop **~400 C in / ~525-550 C out** (BN-600 525-550 C; BN-800 primary
outlet 547 C, secondary loop 505 C, steam 470 C; Phenix outlet 560 C)
(https://world-nuclear.org/information-library/current-and-future-generation/fast-neutron-reactors,
https://en.wikipedia.org/wiki/Sodium-cooled_fast_reactor). Sodium melts **98 C**, boils **883 C**
(https://en.wikipedia.org/wiki/Sodium) — our NAK element boils at exactly 883 C (highTemperature
1156.15 K), a good match; operating 400-550 C leaves **330-480 C of margin** below boiling at
near-atmospheric pressure, which is the entire point of the design (contrast PWR's 155 bar to stay
liquid at 315 C). Secondary sodium loop physically isolates the radioactive primary sodium from the
water/steam side via an intermediate heat exchanger specifically because Na+H2O is violently exothermic,
releasing caustic NaOH and flammable H2
(https://en.wikipedia.org/wiki/Sodium-cooled_fast_reactor, https://en.wikipedia.org/wiki/Sodium) — this
is why real SFRs and our `steam_generator` module both keep NAK and WTRV/DSTW in separate, wall-
isolated volumes. Fuel: MOX (Phenix/BN-800) or U-Pu-Zr metal fuel (EBR-II/PRISM/Natrium), cladding
316SS or HT9 steel (https://en.wikipedia.org/wiki/Sodium-cooled_fast_reactor). Control rods B4C
(https://world-nuclear.org/information-library/current-and-future-generation/fast-neutron-reactors).
Sodium void coefficient CAN be positive in large cores — a recognized Gen-IV safety concern, driving
newer designs (ASTRID) to engineer it negative (same source). **Passive shutdown demonstrated live**:
EBR-II's 1986 test stopped secondary coolant flow at full power with no operator/rod action — thermal
expansion of fuel/coolant/structure alone shut the reactor down (https://en.wikipedia.org/wiki/EBR-II).
**RVACS** (Reactor Vessel Auxiliary Cooling System) — natural-circulation air cooling around the vessel,
"passive and therefore always operates," used in PRISM-class designs
(https://en.wikipedia.org/wiki/PRISM_(reactor)). Power levels: EBR-II 62.5 MWt/20 MWe, Phenix 590 MWth,
Superphenix 3000 MWth (largest SFR built), BN-800 2100 MWth/789 MWe net, PRISM 311 MWe/module. Sodium
autoignites in air at **~290 C**; water-based extinguishers make sodium fires WORSE — use Met-L-X/dry
sand/inert gas (https://en.wikipedia.org/wiki/Sodium). **Monju incident (8 Dec 1995)**: a secondary-loop
thermowell failure ruptured a sodium pipe; the leak reacted with air reaching "several hundred C,"
warped steel structures, ~3 t of sodium solidified; rated INES Level 1
(https://en.wikipedia.org/wiki/Monju_Nuclear_Power_Plant). EBR-I's 1955 partial meltdown was a *separate*
mechanism — thermal bowing of fuel/support plates gave unexpected positive reactivity, not a sodium fire
(https://en.wikipedia.org/wiki/EBR-I).

**Element mapping.** NAK is exactly right for both primary and secondary sodium loops (883 C boil point
matches real sodium precisely); use `props.temp_c` 400-550 for the primary and slightly cooler for the
secondary per the BN-800 numbers above. NA (melts 98 C, the `sodium_fire_demo` element) is the correct
choice specifically for a deliberate sodium-fire hazard demo, not for the working primary loop — keep
that distinction (NAK for the intact loop, NA for a breach/spill scenario). B4C for control rods, S316
(from materials-catalog, melts ~1400 C) for cladding rather than plain STEL, matching real 316SS clad.
LBE (lead-bismuth eutectic, melts 123.5 C / boils 1670 C) is available in our catalog as an alternate
liquid-metal coolant if a lead-cooled fast reactor variant is ever wanted instead of sodium.

**Module layout recommendation.** `steam_generator` already models the correct topology (NAK primary
tube through a STEL shell, isolated from a WTRV/DSTW secondary) — the fix from the PWR section above
(don't reuse NAK for PWR) cuts the other way here: this module is correctly SFR-specific and should stay
that way. Add an `rvacs_shroud` module (not yet built): a passive air gap around `rpv_steel_vessel`'s
STEL shell open to ambient at top and bottom (natural convection chimney), with no PUMP/WIFI power
requirement — the test is precisely that it needs none. Pair `sodium_fire_demo` next to (not inside) any
SFR primary loop build as the deliberate breach-test cell, per the existing `chemical_safety_cell`
practice's isolation rule.

**Failure modes to simulate.**
- **Sodium fire (loop breach)**: erase a section of the NAK-carrying pipe wall so NAK contacts open air
  (OXYG/ambient) rather than WATR (that's the `sodium_fire_demo` reaction; a bare-air leak is the more
  common real event). Signature: leaked NAK temp should climb well past ambient within a handful of
  frames purely from air exposure, and any water line routed nearby must show zero contact — assert the
  test fails loudly if NAK ever touches WATR/DSTW in the same build.
- **Passive decay heat removal (RVACS) success case**: cut all PUMP/WIFI power to a hot core sitting in
  an `rvacs_shroud`. Signature: core temp should fall over time from natural convection alone (mirroring
  the EBR-II 1986 demonstration) — a build that requires ANY active pump to avoid runaway heat has not
  reproduced the real passive-safety case.
- **Sodium-water reaction at the steam generator boundary**: deliberately breach the STEL wall between
  `sg_primary` (NAK) and `sg_steam`/`sg_cond` (WTRV/DSTW) in `steam_generator`. Signature: at the breach
  point, expect a rapid local temp spike and gas evolution consistent with the NAK reactive rule
  (`WATR>NONE,SLTW:650:.7::H2`) — H2 should appear in the census, which is itself the assertable failure
  signature (H2 count > 0 immediately downstream of the breach).

---

## 6. Molten-Salt Reactor (MSR — ORNL MSRE / Kairos KP-FHR / ThorCon-class)

**Real numbers.** FLiBe (2LiF-BeF2, ~66:34 mol%) melts **459 C**, boils **1430 C**
(https://world-nuclear.org/information-library/current-and-future-generation/molten-salt-reactors) —
our FLBE element's lowTemperature/highTemperature (732.15 K / 1673.15 K = 459 C / 1400 C) is an exact
match on the melting point and very close on boiling. MSRE's specific coolant-salt blend had a melting
temp of 434 C and ran with coolant-salt inlet/outlet **635 C / 663 C**
(https://en.wikipedia.org/wiki/Molten_Salt_Reactor_Experiment). Typical/target operating temperature
**650-700 C** across MSRE/MSBR/Kairos designs (same source, world-nuclear.org above). **Freeze plug**:
an air-cooled frozen-salt section kept solid by a fan; loss of cooling or overheat melts the plug and
fuel salt drains BY GRAVITY into passively-cooled, criticality-safe dump tanks — used for both routine
shutdown and passive safety response (https://en.wikipedia.org/wiki/Molten_Salt_Reactor_Experiment,
https://en.wikipedia.org/wiki/Molten-salt_reactor) — exact drain time in seconds was not found in an
accessible source this pass. Fuel: liquid-fuel MSRE dissolved UF4 directly in the fuel salt (7LiF-BeF2-
ZrF4-UF4); solid-fuel variant (Kairos) instead floats TRISO pebbles in separate FLiBe coolant
(https://en.wikipedia.org/wiki/Molten_Salt_Reactor_Experiment,
https://en.wikipedia.org/wiki/Kairos_Power). Pressure near-atmospheric for both variants, vs. PWR's
~150 atm — "stability at low pressure permits less robust reactor vessels"
(https://en.wikipedia.org/wiki/Molten-salt_reactor). **Strong negative temperature/void coefficient**:
demonstrated live at MSRE — pulling control rods at full power leveled reactor power at 9 MWt with NO
operator action, purely from thermal expansion of fuel salt out of the core
(https://en.wikipedia.org/wiki/Molten_Salt_Reactor_Experiment,
world-nuclear.org above) — this is the polar opposite of RBMK's positive void coefficient above; worth
building both as contrasting test cases. Structural material: Hastelloy-N, a low-chromium Ni-Cr-Mo-Si
alloy developed at ORNL specifically for fluoride-salt compatibility to ~700 C (same source) — we have
no Hastelloy-N element; INC7 (Inconel 718, melts 1300 C, retains strength/corrosion resistance red-hot)
from materials-catalog is the closest available stand-in. Power levels: MSRE 8 MWt experimental (ran
1965-1969, 11,555 equivalent full-power hours); Kairos KP-FHR 320 MWt/140 MWe target, thermal efficiency
target **~45%** (vs ~33% typical LWR) specifically because of the higher outlet temperature
(https://en.wikipedia.org/wiki/Molten-salt_reactor).

**Element mapping.** FLBE for both fuel-salt and coolant-salt loops (melting point match is exact);
INC7 for Hastelloy-N-equivalent piping/vessel walls (no exact substitute exists, flag this as a gap);
control rods same B4C convention as other designs, though MSRE's own rods were a custom flexible design
rated for 649 C ambient — B4C's 2763 C melt gives enormous margin here, which is realistic (the rod
material was never the limiting factor in a salt reactor).

**Module layout recommendation (new module needed — `msr_freeze_plug_loop`, not yet built).** A small
FLBE-filled channel section that is intentionally kept below 459 C (i.e., frozen — could be represented
as a temporarily-SALT-transitioned or explicitly cold-clamped FLBE segment) between the main FLBE loop
and a lower, larger empty INC7-lined dump-tank cavity; the "valve" is literally temperature, not a
mechanical plug — heating that one segment above 459 C should let gravity drain the loop above it into
the tank. This directly reuses the geometry idea from `tank_with_valve` (physical plug replaced by
element state, not by an erase/place swap) but the trigger is thermal rather than mechanical.

**Failure modes to simulate.**
- **Freeze-plug passive drain (success case)**: heat the freeze-plug segment past 459 C deliberately (or
  let an unmanaged overheat do it) and verify the loop drains into the dump tank under gravity alone,
  with no PUMP/WIFI action. Signature: FLBE count in the main loop should fall to ~0 within some bounded
  frame count once the plug segment's temp crosses 459 C, and FLBE reappears in the dump-tank census in
  the same window — a build that needs a pump to complete the drain has not modeled the real passive
  mechanism.
- **Negative-feedback self-stabilization**: withdraw B4C rods fully at "full power" (comparable NEUT
  emitter density to the PWR bands) and do NOT re-insert them. Signature: NEUT/flux census should plateau
  on its own (the salt's thermal expansion pushing fuel out of the active region) rather than diverging —
  contrast directly against the RBMK "positive void feedback runaway" test above, which should NOT
  plateau under the same no-intervention condition.
- **Dump-tank criticality safety**: after a drain event, verify the dump tank's FLBE geometry (shape/
  spacing) keeps it visibly sub-critical — i.e., NEUT emission in the tank should be lower than in the
  original core geometry for the same total UO2/fissile-salt inventory, reflecting the real "geometrically
  safe" dump-tank design requirement.

---

## 7. Tokamak (ITER-class fusion)

**Real numbers.** Plasma core target **150,000,000 C (~15 keV)**, plasma volume **830-840 m3** (largest
of any tokamak), major radius **6.2 m**
(https://www.iter.org/factsfigures, https://en.wikipedia.org/wiki/ITER). Toroidal field on-axis **5.3 T**,
peak field at the toroidal-field coils **11.8 T**, poloidal field up to **6 T**, central-solenoid peak
field **13.5 T** (https://en.wikipedia.org/wiki/ITER,
https://en.wikipedia.org/wiki/Niobium%E2%80%93tin). Central solenoid: **18 m tall, ~1000 t**, withstands
**60 MN** of force; 18 D-shaped **Nb3Sn** toroidal-field coils, ~310 t each, 41 GJ stored energy;
poloidal/correction coils use **NbTi** instead (https://www.iter.org/factsfigures,
https://en.wikipedia.org/wiki/ITER) — Nb3Sn's higher critical temperature (18.3 K) and critical field
(up to 30 T) is why it's used where field is highest, with NbTi (our NBTI element, Tc 9.3 K) reserved for
lower-field coils. Magnet operating temperature **~4.2-4.5 K** via liquid helium, with an 80 K liquid-
nitrogen outer thermal shield (https://en.wikipedia.org/wiki/ITER) — our LHE bath at -269 C (4.15 K) in
`cryo_dewar_lhe` is essentially exact. Vacuum vessel: double-walled stainless steel, 19.4 m external
diameter, ~8000 t (https://en.wikipedia.org/wiki/ITER, https://www.iter.org/factsfigures). **First wall
and divertor material**: ITER decided in 2023 to use TUNGSTEN for both the initial first wall (a change
from the original beryllium plan) and all divertor targets (54 cassettes, ~8 t each)
(https://en.wikipedia.org/wiki/ITER); tungsten melts **3422 C**, the highest of any metal, chosen for
heat resistance, low tritium retention, and erosion resistance under intense plasma heat flux
(https://en.wikipedia.org/wiki/Tungsten); beryllium (our BE element, melts 1287 C, `PROP_NEUTPENETRATE`)
was the historical first-wall choice for its low atomic number/low plasma contamination
(https://en.wikipedia.org/wiki/Beryllium). Q factor target **>=10** (momentary), fusion power **500 MWth
from 50 MWth/320 MWe input heating**, pulse/burn duration target **400-600 s**
(https://www.iter.org/factsfigures, https://en.wikipedia.org/wiki/ITER). Fuel deuterium-tritium; tritium
breeding via lithium-6/7 ceramic-pebble test blanket modules (https://en.wikipedia.org/wiki/ITER). Total
machine mass **23,000 t**, ~1,000,000 components (https://www.iter.org/factsfigures). Disruption/quench
exact ITER-specific timescales were NOT confirmed via an accessible source this pass; general fusion/
magnet literature places a disruption thermal quench around ~1 ms and current quench tens of ms, and
superconducting-magnet quench propagation on the order of seconds, but flag these as generic, not
ITER-verified, numbers (https://en.wikipedia.org/wiki/Quench_(magnetism), general, not ITER-specific).

**Element mapping.** NBTI for the correction/poloidal coils (Tc 9.3 K matches real NbTi exactly, and our
element models it as an excellent normal-state conductor rather than a true superconductor — good enough
for a "the coil works below its bath temp" test); LHE bath at -269 C for the cryostat (matches real
~4.2 K almost exactly); WC (tungsten carbide, decomposes ~2870-3143 C in-game) as the nearest available
stand-in for pure tungsten divertor/first-wall material — we have no pure-W element, which is a real gap
given ITER's actual first-wall choice; BE (melts 1287 C) remains available and historically accurate for
a "Gen-1 ITER-style" first wall if a lower-melting, lower-Z variant build is wanted for contrast; STEL or
S316 for the double-walled vacuum vessel shell (real ITER vessel is stainless steel, matching S316's
melt point ~1400 C better than plain STEL's 1500 C, both close).

**Module layout recommendation.** Build on `dome_vessel`/`cryo_column_ln2`/`cryo_dewar_lhe` (per the
existing L5 `fusion_shot` practice, which already notes "8 GOLD coils at 20 K on a cryoplant" from
FSN-2). Swap GOLD for NBTI coils bathed in LHE at -269 C to match the real Nb-Ti/liquid-helium pairing
instead of gold (gold has no superconducting relevance — this is worth correcting). Line the inner face
of the vessel with WC (or BE, for the historical variant) rather than TTAN/DMND alone, since the existing
`fusion_shot` practice already knows TUNG (the base-game element) shatters on every shot — WC is a
carbide, not pure tungsten, so test whether it holds up better before trusting it as the ITER-divertor
analogue. Geometry ratio: keep the vacuum vessel wall thin relative to the plasma cavity (ITER's vessel
wall is a small fraction of its 6.2 m major radius) — a thin STEL/S316 shell around a large low-density
interior, not a thick one.

**Failure modes to simulate.**
- **Plasma disruption**: rapidly kill plasma confinement (e.g., breach the vessel or drop a containment
  field) while the core is at flash temperature. Signature: a very fast, localized heat/pressure spike at
  the wall contact point within a handful of frames — assert the WC/BE liner point of contact reaches a
  measurably higher temp than the rest of the vessel within that short window, modeling the real
  localized heat-flux concentration of a disruption event (exact ms-scale timing not sourced this pass,
  so assert relative/ordinal behavior — "wall contact point heats fastest" — rather than a specific frame
  count).
- **Magnet quench**: force an NBTI coil segment above some threshold (representing loss of LHE
  submersion, e.g. draining the dewar). Signature: once NBTI is no longer bathed in the -269 C LHE pool,
  treat it as "gone resistive" — our element models it as a plain conductor regardless, so the testable
  signature is procedural: verify the coil is NEVER built without being fully submerged in LHE at rest
  (a `blueprint_lint`-style check), since the real failure mode there is losing cryogenic immersion, not
  a property the NBTI element itself models.
- **Loss of vacuum**: breach the double-walled vessel to ambient. Signature: pressure inside the vessel
  cavity (get_field) should rise from near-zero toward ambient within the breach's local radius, and any
  plasma-equivalent hot element inside should quench (temperature/pressure conditions for sustaining it,
  per the existing H2-fusion "requires particle temp AND cell pressure simultaneously" pitfall, should
  stop being met) — assert plasma-equivalent particles disappear once cavity pressure crosses back toward
  ambient.

---

## 8. Industrial Gas Turbine (Brayton cycle — GE 7HA/9HA / Siemens SGT-HL class)

**Real numbers.** H-class turbine inlet/firing temperature up to **1540 C (2800 F)** (GE 9HA); general
modern industrial units commonly cited **900-1400 C**
(https://en.wikipedia.org/wiki/Gas_turbine, https://en.wikipedia.org/wiki/Combined_cycle_power_plant).
Combined-cycle exhaust entering the HRSG **450-650 C** (same source). GE 7HA family: **290-430 MW**
output depending on model, simple-cycle efficiency **42.0-43.3%**, combined-cycle efficiency **63-64%
net** (best cited: Siemens SGT5-9000HL 2024 at **64.18%**)
(https://www.gevernova.com/gas-power/products/gas-turbines/7ha,
https://en.wikipedia.org/wiki/Gas_turbine). Startup: **10-21 minutes** to full load depending on model,
ramp rate **55-75 MW/min** (https://www.gevernova.com/gas-power/products/gas-turbines/7ha). Blade
materials: nickel-based superalloys with gamma-prime strengthening for creep resistance, single-crystal
alloys to eliminate grain-boundary creep, thermal barrier coatings (stabilized zirconia) reducing blade
metal temp by up to **200 C** below gas-path temp, newest designs adding ceramic-matrix composites
(https://en.wikipedia.org/wiki/Gas_turbine). Compressor pressure ratio for modern H-class units
(commonly cited ~20-23:1) was NOT confirmed via an accessible source this pass — flag as unsourced if
used.

**Element mapping.** No dedicated Brayton-cycle (open-air) turbine element exists in our inventory —
TRBN is explicitly a steam turbine (`input: WTRV, output: DSTW`), which only models the Rankine, not the
Brayton, half of a combined-cycle plant. This is a real gap: a gas turbine's working fluid is hot
compressed air/combustion gas, not steam, and TRBN cannot represent that without a custom element (a
`GTRB` behavior consuming a hot-air/FIRE-adjacent input rather than WTRV would be needed to model this
faithfully — flagging as a recommended future custom element rather than forcing TRBN to do double duty).
INC7 (Inconel 718, melts 1300 C) or the base-game DMND/TTAN are the closest available blade-material
stand-ins for a nickel-superalloy hot section — none of our materials individually reach the real
1540 C firing temperature while staying solid, which is itself realistic (real turbine blades survive
firing temperatures ABOVE their alloy's melting point only because of active film cooling and thermal
barrier coatings, a mechanism we don't yet model).

**Module layout recommendation.** Until a dedicated Brayton-cycle element exists, model a combined-cycle
plant as two clearly separate stages already partially present in our set: (1) a hot INC7-lined "firing"
chamber whose exhaust heat is captured only via `teg_waste_heat`/`teg_wall_panel` panels (waste-heat
recovery, not direct shaft work — an honest way to represent "we can't model the turbine's own shaft
work yet") feeding (2) a real `steam_generator` + `steam_turbine_stage` HRSG/Rankine bottoming cycle,
which we CAN model faithfully. This keeps the plant honest about what is and isn't simulated rather than
mislabeling TRBN as doing Brayton-cycle work.

**Failure modes to simulate.**
- **Blade overtemperature / creep failure**: run the firing chamber above the thermal-barrier-coated
  alloy's real service ceiling for an extended period. Signature: since no dedicated element exists,
  represent this as INC7 (melts 1300 C) approaching its melt point under sustained firing-chamber temp —
  assert the build fails (INC7 outside its 1300 C margin) whenever firing-chamber temp is set to the
  real 1540 C without any cooling/insulation layer, which is the correct qualitative result even
  though the quantitative melting-vs-firing-temp gap in reality is closed by active cooling we don't
  model.
- **HRSG/bottoming-cycle loss**: sever the link between the firing chamber's waste-heat panels and the
  downstream `steam_generator`. Signature: combined-cycle efficiency (proxied by total SPRK/TRBN work
  output) should drop toward the ~42% simple-cycle figure rather than the ~63-64% combined-cycle figure,
  a directly assertable before/after census comparison.

---

## 9. Steam Rankine Cycle (subcritical / supercritical / ultra-supercritical)

**Real numbers.** Subcritical steam: up to **221.2 bar / 374 C**
(https://en.wikipedia.org/wiki/Supercritical_steam_generator). Supercritical: above **22 MPa / 374 C**,
typical modern range **538-566 C at ~24.1 MPa**, thermal efficiency **~40%**
(https://en.wikipedia.org/wiki/Supercritical_steam_generator, https://en.wikipedia.org/wiki/Rankine_cycle).
Ultra-supercritical: up to **340 bar (5000 psi)**, up to **600 C** per the Rankine-cycle article,
thermal efficiency **~42%** in the same source (note: some industry sources cite USC efficiency as
high as 45-47%, not independently confirmed this pass — treat 42% as the sourced floor, not a ceiling).
Advanced ultra-supercritical (A-USC) targets **above 700 C**
(https://en.wikipedia.org/wiki/Supercritical_steam_generator). Feedwater pump power draw only **1-3%**
of turbine output in a regenerative cycle (https://en.wikipedia.org/wiki/Rankine_cycle). Deaerator
removes dissolved oxygen down to **<=7 ppb by weight** plus CO2, by heating feedwater near boiling with
low-pressure steam scrubbing, preventing boiler/piping corrosion
(https://en.wikipedia.org/wiki/Deaerator). Condenser vacuum/temperature numeric values were NOT
confirmed via an accessible source this pass for the generic Rankine article (the PWR-specific figure
from Section 1 — 0.008 MPa abs / ~41.5 C — is the best sourced condenser data point available and is a
reasonable stand-in for a generic Rankine bottoming cycle).

**Element mapping.** WTRV/DSTW/TRBN is already our correct generic Rankine-cycle element set — this
section validates the numbers already embedded in `steam_generator`/`steam_turbine_stage` rather than
proposing new elements. Our `heat_extraction_loop` operating band (boiler 130-180 C) and
`steam_generator`'s 170 C WTRV are both far below even subcritical steam conditions (374 C) — this is a
deliberate simplification for game stability, not a modeling error, but worth flagging explicitly: real
utility-scale steam plants run 3-4x hotter than our current boiler band.

**Module layout recommendation.** No new module needed; the existing chain (`steam_generator` ->
`condenser_cu` -> `teg_wall_panel`) already mirrors a real subcritical Rankine plant's feedwater-heater/
deaerator-adjacent topology reasonably well at LEDL-status-panel fidelity. If a "high-temperature realism"
variant is wanted, raise `sg_steam`'s `props.temp_c` toward 374-566 C (subcritical-to-supercritical) and
verify TRBN/DSTW behavior still holds at that temperature rather than assuming it scales linearly from
the current 170 C tests.

**Failure modes to simulate.**
- **Loss of condenser vacuum**: raise the `cond_bath` DSTW temperature in `condenser_cu` toward
  saturation instead of keeping it cool. Signature: TRBN's `cool: 60` recovery parameter should show
  reduced net "work" accumulation per unit steam consumed as the condenser bath warms, a directly
  assertable degradation in `trbn_work_per_120f` (currently banded >=20 with a full steam chest) as
  condenser temp rises — this is the correct qualitative signature for "backpressure rising, efficiency
  falling" even without modeling exact thermodynamic backpressure.
- **Boiler tube rupture**: breach the STEL wall between `sg_primary` and `sg_steam` in `steam_generator`
  (same mechanism as the SFR sodium-water breach test, but here both sides are water/steam so the
  hazard is pressure/scalding rather than a chemical reaction). Signature: WTRV should appear on the
  wrong side of the breach within a few frames, and the pressure differential across the former wall
  should collapse toward zero — assert both.

---

## 10. PV + Battery Microgrid

**Real numbers.** Commercial crystalline-silicon module efficiency up to **~24.5%** (2025 best
commercial), typical multicrystalline commercial cells **14-19%**; lab-record cell efficiency **47.6%**
(concentrator multi-junction) (https://en.wikipedia.org/wiki/Solar_cell_efficiency). Temperature
coefficient of efficiency **~-0.45%/C** per degree rise (same source; consistent with the commonly cited
industry range of -0.3 to -0.4%/C). STC reference conditions: **25 C cell temp, 1000 W/m2, AM1.5**
(https://en.wikipedia.org/wiki/Solar_panel). Li-ion nominal voltage **3.6-3.7 V** (LiCoO2-class);
LFP nominal **3.2 V**, working range 3.0-3.3 V, max charge 3.60-3.65 V
(https://en.wikipedia.org/wiki/Lithium-ion_battery, https://en.wikipedia.org/wiki/LiFePO4_battery).
Recommended Li-ion charge temperature **5-45 C**; above 45 C degrades performance, below 0 C needs
reduced current (https://en.wikipedia.org/wiki/Lithium-ion_battery). Li-ion thermal runaway: exothermic
electrode-solvent reactions begin around **~70 C internal cell temp**, runaway peak temperatures exceed
**500 C** (same source) — note this 70 C "onset of exothermic reactions" figure is lower than the
commonly cited ~150-200 C "trigger" range seen in battery-safety literature; both numbers describe real
but different stages of the same failure progression. NAS battery must stay **300-350 C molten**; below
~250 C the solid beta-alumina electrolyte stops conducting Na+ well, below 200 C it fails to wet and the
cell won't operate at all (https://en.wikipedia.org/wiki/Sodium%E2%80%93sulfur_battery) — matches our
NAS element's behavior exactly (freezes to SALT below its low-temperature threshold). **Historical NaS
thermal-runaway incident**: NGK 2000 kW system fire at a Mitsubishi Materials plant, Tsukuba, Japan,
21 Sept 2011; NGK's post-incident fix added per-module fuses/fewer cells per module specifically to stop
thermal propagation between cells (same source) — directly relevant to our `nas_battery_rack`'s "treat
any breach as a sodium-fire hazard" pitfall.

**Element mapping.** SIPV (our element models ~88% photon-to-spark conversion, tuned to represent
~22% panel-level efficiency after averaging over realistic photon flux) matches commercial silicon PV
well; GAAS (28% `chance` in its `photovoltaic` behavior, melts 1238 C) is the correct higher-efficiency,
higher-temperature-tolerant stand-in for space-grade GaAs PV specifically, not a generic "better solar
panel" — use it where the fiction calls for a satellite/high-radiation panel, not as a strict upgrade.
NAS for grid-scale molten battery storage (temperature band matches real NaS almost exactly). No
dedicated Li-ion element currently exists in our catalog; this is a real gap given how central Li-ion is
to actual grid/microgrid storage today — PCMP/PCMS (phase-change thermal buffers) and NAS cover thermal
and molten-salt storage respectively, but nothing in our inventory currently represents a room-temperature
electrochemical cell with a runaway threshold near 70-150 C.

**Module layout recommendation.** `pv_array_sipv` + `nas_battery_rack` (both already built, per the
existing `energy_storage_bank` practice) form a correct microgrid pair. Add a `PHOT` source that varies
with a day/night or weather cycle if realism about intermittency is wanted (currently the array only
notes it "needs incident PHOT," with no temporal variability built in). Until a Li-ion element exists,
represent a Li-ion rack conservatively as a lower-temperature-margin analogue: a STEL or AL61-cased box
holding a placeholder conductor element kept explicitly below 45 C by design, with an explicit lint rule
that anything inside must never see WIFI/HEAC direct contact (mirroring the real charge-temperature
ceiling) — flagged as a recommended future custom element (`LION`) rather than a real mapping today.

**Failure modes to simulate.**
- **NaS thermal-runaway propagation**: breach one cell of a segmented `nas_battery_rack` (multiple small
  NAS cells rather than one large block, mirroring NGK's post-2011 per-module fusing) and check whether
  heat/reaction propagates to neighboring cells. Signature: with fuses/gaps (STEL/INSL breaks between
  segments) present, neighboring NAS cells should stay within their 300-350 C band; without them, a
  breach should visibly heat/ignite adjacent cells — this directly tests the real NGK fix.
- **Grid-forming inverter loss / islanding failure**: cut the CU-bus link between `pv_array_sipv` and the
  rest of a plant's WIFI/LEDL status network. Signature: downstream LEDL/status panels should go dark
  (no SPRK) within a small number of frames once the shared bus is severed, and the PV array itself
  should keep producing SPRK locally — demonstrating "islanding" (the array output stranding itself)
  rather than silently continuing to feed a disconnected grid.

---

## 11. Hydrogen Electrolysis + Fuel Cell

**Real numbers.** PEM electrolyzer operating temperature **60-80 C**, efficiency **~80% HHV** currently
(projected 82-86% by 2030, theoretical max ~94%), commercial systems need **~53 kWh/kg H2**
(https://en.wikipedia.org/wiki/Electrolysis_of_water). Alkaline electrolyzer **60-90 C**, 25-40 wt%
KOH/NaOH electrolyte, nickel catalysts, efficiency **~70%** (same source). PEM fuel cell operating
temperature **50-100 C** typical, theoretical max efficiency ~83%, practical **50-60%** due to
activation/ohmic/mass-transport losses; higher-temp PBI-membrane variants reach up to **220 C**
(https://en.wikipedia.org/wiki/Proton-exchange_membrane_fuel_cell). Compressed H2 storage **350 bar
and 700 bar** standard for Type IV composite tanks, 700 bar most common as of 2020
(https://en.wikipedia.org/wiki/Hydrogen_storage). Liquid H2 boils at **20.27 K / -252.88 C**
(https://en.wikipedia.org/wiki/Hydrogen_storage, https://en.wikipedia.org/wiki/Hydrogen) — matches our
LH2 element exactly (highTemperature 20.28 K). H2 flammability range in air **4-75% by volume**, in pure
O2 4-94%, DETONABLE range **18.3-59%** (much wider than gasoline's 1.4-7.6%)
(https://en.wikipedia.org/wiki/Hydrogen_safety). Autoignition temperature **500 C**
(https://en.wikipedia.org/wiki/Hydrogen). Minimum ignition energy **0.02 mJ**, roughly 1/10th that of a
gasoline-air mixture — one of the lowest of any substance (https://en.wikipedia.org/wiki/Hydrogen_safety).
In an enclosed space, an ignited H2 leak "will most likely lead to an explosion, not a mere flame,"
because turbulence readily escalates deflagration to detonation (same source).

**Element mapping.** LH2 for cryogenic storage (exact temperature match). No dedicated compressed-gas-
tank element or PEM-stack behavior element exists in our catalog — HYGN (the base-game hydrogen gas
element, referenced by NAK's own reactive rule byproduct) is presumably the working gas once LH2
vaporizes or an electrolyzer produces it, but we have no elements modeling the electrolysis/fuel-cell
CONVERSION step itself (water+power->H2+O2, or H2+O2->power+water) — this is a genuine gap. TEG's
`onTemp: 373.15` (100 C) behavior is coincidentally close to a PEM fuel cell's 50-100 C operating band
and could be repurposed/relabeled as a rough fuel-cell stand-in if no custom element is built, but this
is a stretch, not a real mapping — flag any such use as approximate.

**Module layout recommendation (new module needed — no `h2_electrolyzer_stack` or `h2_fuel_cell_stack`
exists today).** Until custom elements exist, the closest honest approximation is: an
`injector_pod`-style WIFI-triggered unit that converts DSTW+power into a small burst of HYGN(-equivalent)
gas at the electrolyzer's 60-80 C band, feeding a sealed LH2 or compressed-gas storage cell (a small
TTAN- or STEL-walled tank with an explicit high pressure via `set_field_region`, per `pressure_chamber`,
representing the real 350-700 bar tank), which then feeds a TEG-adjacent "fuel cell" panel run at 50-
100 C that sparks CU on contact — again, an approximation pending real elements.

**Failure modes to simulate.**
- **Hydrogen leak + ignition in an enclosed space (deflagration-to-detonation)**: vent HYGN into a sealed
  chamber (mirroring the pressure_chamber module) up to a concentration within the 18.3-59% detonable
  band, then introduce any spark source. Signature: given H2's ~0.02 mJ minimum ignition energy, ANY
  stray SPRK/PSCN contact near the vented gas should ignite it — assert that a sealed HYGN-filled chamber
  with an unintended conductor penetration is flagged as a critical lint finding (echoing the existing
  "conductive floor shorts the whole build" pitfall, but for a flammable-gas chamber specifically) rather
  than only checked after the fact.
- **Storage tank overpressure**: raise pressure in the compressed-H2 tank analogue toward and past its
  structural (TTAN/STEL) limit. Signature: wall census should show the tank boundary failing (particles
  escaping the box) once modeled pressure exceeds what a `pressure_chamber`-style wall can hold, and any
  escaping HYGN should be checked against the flammability range immediately, not just at final rest.

---

## 12. Geothermal Power Plant

**Real numbers.** Dry-steam plants need reservoir steam **>=150 C**; flash-steam plants need
**>=180 C** fluid, usually higher; binary-cycle (ORC) plants are viable down to **57 C**
(https://en.wikipedia.org/wiki/Geothermal_power). Well depth typically up to **~3 km** (resource models
consider up to 10 km); geothermal gradient away from plate boundaries **~25-30 C/km** (same source).
Thermal efficiency is LOW relative to combustion/fission plants: overall geothermal stations **~7-10%**,
binary-cycle plants **~10-13%** (same source) — this is a real, fundamental consequence of the low
source temperature (Carnot-limited), not an engineering shortfall. Induced seismicity: the Basel,
Switzerland enhanced-geothermal project caused **>10,000 seismic events, up to magnitude 3.4**, during
injection trials, leading to project suspension (same source). H2S hazard (relevant to geothermal
off-gas): NIOSH REL-Ceiling **10 ppm**, OSHA PEL-Ceiling **20 ppm**, peak limit 50 ppm, IDLH **100 ppm**,
olfactory-nerve paralysis 100-150 ppm, pulmonary-edema risk 320-530 ppm, LC50 (5 min) ~800 ppm
(https://en.wikipedia.org/wiki/Hydrogen_sulfide).

**Element mapping.** No dedicated geothermal-specific element exists (nor should one — geothermal is
really just a Rankine or binary-ORC cycle with an unusually cool, naturally-sourced heat input rather
than a combustion/fission source). WTRV/DSTW + TRBN for a flash-steam plant works directly, run at the
lower end of our existing `heat_extraction_loop` boiler band (130-180 C matches the real 150-180 C flash/
dry-steam threshold almost exactly — this is the one system in this whole document where our existing
game band and the real number line up almost by coincidence). For a binary/ORC plant (57 C+ resources),
PCMP or PCMS (both real phase-change materials with 32-58 C melt points) are surprisingly good stand-ins
for a low-temperature working-fluid loop, since ORC plants specifically use a fluid with a low boiling
point rather than water.

**Module layout recommendation.** No new module strictly required. A `geothermal_binary_orc` layout can
be assembled from existing pieces: a DSTW "reservoir" body held at 57-180 C (using the existing
`dstw_reservoir_manifold`) feeding a PCMP- or PCMS-lined heat exchanger (rather than boiling DSTW to
WTRV directly, which is the flash-steam path) that transfers heat to a *second*, separate low-boiling-
point loop driving `steam_turbine_stage`'s TRBN — modeling the real binary-cycle principle of never
letting the geothermal brine itself touch the turbine.

**Failure modes to simulate.**
- **H2S off-gas leak**: vent a small marker quantity of a toxic/gas element alongside the WTRV output
  (geothermal steam always carries trace H2S in reality) into an occupied area. Signature: any Person/
  bystander proxy in the vented area should register a hazard condition within the H2S concentration
  band above (this is more a `person_inspect`/hazard-detection test than a materials test, but the
  observable signature — hazard flag trips at low concentration, well before any visible fire/explosion
  — is what distinguishes H2S from the flammable-gas failure modes elsewhere in this document).
- **Induced seismicity from reinjection**: increase reinjection PUMP pressure into the "reservoir" DSTW
  body beyond a modeled threshold. Signature: treat this as a pressure-field test — assert that
  `get_field pressure` readings in the surrounding rock/ground analogue exceed a defined safe band once
  reinjection pressure is pushed too high, giving an assertable proxy for "the plant is now at risk of
  triggering felt seismic events," mirroring the real Basel case where injection pressure and event
  count/magnitude were directly correlated.

---

## Consolidated operating_bands (JSON, knowledge-ready)

Playbook-schema `operating_bands` objects for each system above, ready to attach to a corresponding
PLAYBOOK.md practice (existing or new). All bands marked `"status": "proposed"` — none have been run
live in-sim as of this pass; treat as design targets per this repo's existing convention (see
`realistic_fission_core` and `electrical_generation_chain` practices, which use the same disclaimer).

```json
{
  "realistic_pwr_core": {
    "source": "en.wikipedia.org/wiki/Pressurized_water_reactor, world-nuclear.org nuclear-power-reactors, en.wikipedia.org/wiki/Uranium_dioxide, en.wikipedia.org/wiki/Zirconium_alloy, en.wikipedia.org/wiki/Boiling_water_reactor_safety_systems (10 CFR 50.46) -- research pass 2026-08-26",
    "status": "proposed",
    "coolant_inlet_c": 275,
    "coolant_outlet_c": 315,
    "primary_pressure_mpa": 15.5,
    "uo2_melt_c": 2865,
    "zirc_oxidation_limit_c": 1230,
    "zirc_melt_c": 1852,
    "scram_insertion_s": 2,
    "eccs_clad_temp_limit_c": 1204,
    "decay_heat_fraction": {"at_trip": 0.06, "at_1hr": 0.012, "at_1day": 0.0045, "at_1week": 0.002},
    "verify_bands": [
      "core DSTW temp 275-315 C during steady run",
      "ZIRC clad stays below 1230 C except in a deliberate LOCA test",
      "B4C/CD scram reaches full insertion within a small, bounded frame count after trip",
      "unpowered core after station blackout follows a decaying (not flat or runaway) TSNS curve"
    ]
  },
  "realistic_bwr_core": {
    "source": "en.wikipedia.org/wiki/Boiling_water_reactor, en.wikipedia.org/wiki/Boiling_water_reactor_safety_systems, world-nuclear.org/.../fukushima-daiichi-accident -- research pass 2026-08-26",
    "status": "proposed",
    "core_pressure_mpa": 7.6,
    "coolant_boil_c": 285,
    "void_fraction_avg": 0.40,
    "exit_steam_quality": 0.135,
    "ads_timer_s": 105,
    "eccs_clad_temp_limit_c": 1204,
    "sbo_core_damage_hours_with_steam_injection": [3.15, 76.1],
    "verify_bands": [
      "in-vessel WTRV/DSTW mix boils near 285 C at nominal power",
      "low-water-level sensor trips B4C insertion before ZIRC reaches 1230 C",
      "ADS vent pod fires only after both the low-low-low signature AND its DLAY timer elapse",
      "a build with steam-driven injection survives station blackout far longer than one without"
    ]
  },
  "candu_core": {
    "source": "en.wikipedia.org/wiki/CANDU_reactor, en.wikipedia.org/wiki/Point_Lepreau_Nuclear_Generating_Station, en.wikipedia.org/wiki/Bruce_Nuclear_Generating_Station, en.wikipedia.org/wiki/Void_coefficient -- research pass 2026-08-26",
    "status": "proposed",
    "pht_pressure_mpa": 10.3,
    "pht_outlet_c": 312,
    "fuel_enrichment_pct": 0.72,
    "bundle_elements": 37,
    "channels_candu6": 380,
    "thermal_efficiency_pct": 32,
    "note": "PHT inlet temp, exact lattice pitch, and SDS1/SDS2 insertion timing were not confirmed via an accessible source this pass -- do not treat unlisted CANDU numbers as sourced",
    "verify_bands": [
      "calandria (moderator) DSTW pool stays near its own baseline temp even when the pressure-tube DSTW is drained (LOCA-with-intact-moderator test)",
      "with both SDS1 (CD rod drop) and SDS2 (poison injection) disabled, a positive-reactivity transient is NOT self-limiting -- contrast against either system alone stopping it"
    ]
  },
  "rbmk_core": {
    "source": "en.wikipedia.org/wiki/RBMK, en.wikipedia.org/wiki/Chernobyl_disaster, en.wikipedia.org/wiki/Void_coefficient, world-nuclear.org/.../chernobyl-accident -- research pass 2026-08-26",
    "status": "proposed",
    "channel_pressure_mpa": 6.9,
    "coolant_inlet_c": 267,
    "coolant_outlet_c": 284,
    "fuel_enrichment_pct": 2.0,
    "control_rod_insertion_s": [18, 21],
    "void_coefficient_beta_eff_pre_accident": 4.7,
    "void_coefficient_beta_eff_post_accident": 0.7,
    "thermal_efficiency_pct": 31.25,
    "verify_bands": [
      "rbmk_rod_drive insertion from full withdrawal shows a brief flux INCREASE in the first few frames (graphite displacer effect) before flux falls -- monotonic decrease from frame 1 means the positive-scram flaw was not reproduced",
      "boiling coolant with elevated flux shows flux and void fraction reinforcing each other rather than self-limiting (positive void coefficient), unlike the CANDU/MSR contrast cases",
      "a core breach vents measurably to the ambient cell rather than being held by a bounded containment box, reflecting RBMK's lack of a full containment dome"
    ]
  },
  "sfr_core": {
    "source": "en.wikipedia.org/wiki/Sodium-cooled_fast_reactor, en.wikipedia.org/wiki/Sodium, en.wikipedia.org/wiki/EBR-II, en.wikipedia.org/wiki/PRISM_(reactor), en.wikipedia.org/wiki/Monju_Nuclear_Power_Plant, world-nuclear.org/.../fast-neutron-reactors -- research pass 2026-08-26",
    "status": "proposed",
    "primary_inlet_c": 400,
    "primary_outlet_c": [525, 550],
    "sodium_melt_c": 98,
    "sodium_boil_c": 883,
    "sodium_autoignition_air_c": 290,
    "operating_pressure": "near-atmospheric",
    "verify_bands": [
      "NAK primary loop stays 400-550 C, at least 330 C below its 883 C boil point, at near-atmospheric pressure",
      "NAK never contacts WATR/DSTW anywhere in the same build (sodium-water reaction hazard) -- assert zero contact frames",
      "a core in an rvacs_shroud with all PUMP/WIFI power cut still cools over time from natural convection alone (passive RVACS success case)",
      "a deliberate NAK-to-air breach shows rapid local temp rise consistent with sodium autoignition near 290 C"
    ]
  },
  "msr_core": {
    "source": "en.wikipedia.org/wiki/Molten_Salt_Reactor_Experiment, en.wikipedia.org/wiki/Molten-salt_reactor, world-nuclear.org/.../molten-salt-reactors, en.wikipedia.org/wiki/Kairos_Power -- research pass 2026-08-26",
    "status": "proposed",
    "flibe_melt_c": 459,
    "flibe_boil_c": 1430,
    "operating_c": [650, 700],
    "operating_pressure": "near-atmospheric",
    "thermal_efficiency_pct_target": 45,
    "verify_bands": [
      "FLBE loop runs 650-700 C, well above its 459 C melt point and well below its 1430 C boil point",
      "withdrawing all B4C rods at full power causes flux to plateau on its own (negative temperature coefficient) rather than diverge -- the opposite of the RBMK positive-void test",
      "heating the freeze-plug FLBE segment past 459 C drains the loop into the dump tank under gravity alone within a bounded frame count, with zero PUMP/WIFI involvement",
      "post-drain dump-tank NEUT emission is lower than the original core's for the same total fissile inventory (geometrically-safe dump tank)"
    ]
  },
  "tokamak_shot": {
    "source": "iter.org/factsfigures, en.wikipedia.org/wiki/ITER, en.wikipedia.org/wiki/Niobium-tin, en.wikipedia.org/wiki/Tungsten, en.wikipedia.org/wiki/Beryllium -- research pass 2026-08-26",
    "status": "proposed",
    "plasma_core_c": 150000000,
    "toroidal_field_t": 5.3,
    "magnet_bath_k": 4.2,
    "nbti_critical_temp_k": 9.3,
    "first_wall_material_2023plus": "tungsten",
    "first_wall_melt_c": 3422,
    "pulse_duration_s": [400, 600],
    "note": "ITER-specific disruption thermal-quench and magnet-quench-propagation timescales were not confirmed via an accessible source this pass; only generic (non-ITER) quench-physics figures exist and should not be cited as ITER numbers",
    "verify_bands": [
      "NBTI coil is never built (even at rest) without being fully submerged in an LHE bath at or below -269 C -- lint-check this rather than relying on the element to model resistive transition",
      "breaching the vacuum vessel raises cavity pressure measurably within the breach's local radius, and any plasma-equivalent hot element quenches once the H2-fusion temp+pressure condition is no longer jointly met",
      "the WC/BE liner point of contact during a simulated disruption heats measurably faster than the rest of the vessel (localized heat-flux concentration), even without an exact ms timing"
    ]
  },
  "gas_turbine_brayton": {
    "source": "en.wikipedia.org/wiki/Gas_turbine, gevernova.com/gas-power/products/gas-turbines/7ha, en.wikipedia.org/wiki/Combined_cycle_power_plant -- research pass 2026-08-26",
    "status": "proposed",
    "firing_temp_c": 1540,
    "exhaust_temp_c": [450, 650],
    "simple_cycle_efficiency_pct": [42, 43.3],
    "combined_cycle_efficiency_pct": [63, 64.18],
    "startup_minutes": [10, 21],
    "note": "no dedicated Brayton-cycle (hot-air) turbine element exists in our inventory yet -- TRBN only models the Rankine/steam half; treat any Brayton-cycle build as waste-heat-panel + steam-bottoming-cycle only until a GTRB-style custom element is built",
    "verify_bands": [
      "severing the firing-chamber waste-heat link to the downstream steam_generator drops total measured work output toward the ~42% simple-cycle band rather than the ~63% combined-cycle band",
      "INC7 firing-chamber lining approaches its 1300 C melt margin when run at the real 1540 C firing temperature with no cooling/insulation layer present"
    ]
  },
  "steam_rankine_cycle": {
    "source": "en.wikipedia.org/wiki/Supercritical_steam_generator, en.wikipedia.org/wiki/Rankine_cycle, en.wikipedia.org/wiki/Deaerator, nuclear-power.com/nuclear-power-plant/turbine-generator -- research pass 2026-08-26",
    "status": "proposed",
    "subcritical_max_c": 374,
    "supercritical_c": [538, 566],
    "ultra_supercritical_c": 600,
    "condenser_c_pwr_reference": 41.5,
    "condenser_pressure_mpa_abs_pwr_reference": 0.008,
    "note": "our current heat_extraction_loop/steam_generator bands (130-180 C boiler) run 3-4x cooler than real utility subcritical steam -- a deliberate game-stability simplification, not an error; flag before assuming it scales",
    "verify_bands": [
      "raising condenser_cu's bath temperature toward saturation measurably reduces trbn_work_per_120f versus the existing >=20 band with a cool bath",
      "a boiler-tube breach in steam_generator shows WTRV appearing on the wrong side of the former wall and the pressure differential across it collapsing toward zero within a few frames"
    ]
  },
  "pv_battery_microgrid": {
    "source": "en.wikipedia.org/wiki/Solar_cell_efficiency, en.wikipedia.org/wiki/Lithium-ion_battery, en.wikipedia.org/wiki/Sodium-sulfur_battery -- research pass 2026-08-26",
    "status": "proposed",
    "si_pv_efficiency_pct": [14, 24.5],
    "pv_temp_coefficient_pct_per_c": -0.45,
    "li_ion_charge_range_c": [5, 45],
    "li_ion_exothermic_onset_c": 70,
    "li_ion_runaway_peak_c": 500,
    "nas_operating_c": [300, 350],
    "note": "no Li-ion element exists in our catalog yet -- NAS (300-350 C molten) and PCMP/PCMS (32-58 C phase change) cover thermal/molten storage but not a room-temperature electrochemical cell with a ~70-150 C runaway threshold",
    "verify_bands": [
      "a segmented nas_battery_rack with STEL/INSL breaks between cells contains a single-cell breach without heating neighboring cells; an unsegmented rack does not",
      "severing the CU-bus link between pv_array_sipv and the rest of the plant causes downstream LEDL/status panels to go dark within a small frame count while the array itself keeps producing SPRK locally (islanding signature)"
    ]
  },
  "hydrogen_electrolysis_fuel_cell": {
    "source": "en.wikipedia.org/wiki/Electrolysis_of_water, en.wikipedia.org/wiki/Proton-exchange_membrane_fuel_cell, en.wikipedia.org/wiki/Hydrogen_storage, en.wikipedia.org/wiki/Hydrogen_safety -- research pass 2026-08-26",
    "status": "proposed",
    "pem_electrolyzer_c": [60, 80],
    "pem_fuel_cell_c": [50, 100],
    "storage_pressure_bar": [350, 700],
    "lh2_boil_c": -252.88,
    "flammability_range_pct_vol": [4, 75],
    "detonable_range_pct_vol": [18.3, 59],
    "autoignition_c": 500,
    "min_ignition_energy_mj": 0.02,
    "note": "no electrolyzer or fuel-cell conversion element exists in our catalog yet -- LH2 storage temperature matches exactly, but the water<->H2 conversion step itself has no dedicated element",
    "verify_bands": [
      "a sealed HYGN-filled chamber with any conductor penetration is flagged as a critical lint finding before it is ever unpaused, given H2's 0.02 mJ minimum ignition energy",
      "compressed-H2 tank wall census shows containment failing (particles escaping) once modeled pressure exceeds what the wall type can hold, and escaping HYGN concentration is checked against the 18.3-59% detonable band immediately"
    ]
  },
  "geothermal_plant": {
    "source": "en.wikipedia.org/wiki/Geothermal_power, en.wikipedia.org/wiki/Hydrogen_sulfide -- research pass 2026-08-26",
    "status": "proposed",
    "dry_steam_min_c": 150,
    "flash_steam_min_c": 180,
    "binary_orc_min_c": 57,
    "thermal_efficiency_pct": [7, 13],
    "h2s_idlh_ppm": 100,
    "basel_induced_seismicity_events": 10000,
    "basel_max_magnitude": 3.4,
    "note": "our existing heat_extraction_loop boiler band (130-180 C) coincidentally matches the real 150-180 C flash/dry-steam threshold well -- the one system in this document where no band change is needed",
    "verify_bands": [
      "a binary/ORC loop never lets the geothermal DSTW reservoir body directly contact the TRBN turbine -- a second, separate low-boiling-point loop (PCMP/PCMS-mediated) must sit between them",
      "reinjection PUMP pressure pushed past a defined safe band raises surrounding get_field pressure readings measurably, giving an assertable proxy for induced-seismicity risk"
    ]
  }
}
```
