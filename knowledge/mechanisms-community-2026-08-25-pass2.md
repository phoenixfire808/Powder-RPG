# Community nuclear/fusion/power builds — second independent read (ANALYST-2 pass 2, 2026-08-25)

A parallel ANALYST-2 instance wrote `mechanisms-community-2026-08-25.md` (738 lines, 21 modules) over the same
38 HIGH-relevance saves while this pass ran; this file is the second, independently derived read. Per-save
coordinates below were taken from `parts.jsonl` / `logic.txt` / `census.txt` directly. The cross-save synthesis
at the end is also appended to the main doc. Modules from this pass: 12 in `knowledge/modules/` (listed at end).

A fact that shapes everything else: **all 67 saves run `ambientHeat=false`** (census line 1). Heat moves only by
particle contact; empty cells are perfect insulators. That is why community WIFI banks sit bare and why every
"coolant loop" is a contact path (PIPE/portal/HEAC), never a radiative one.

---

## RBMK / graphite-channel reactors

### 2001108 — The REAL RBMK1000 (den_koshkin, 1143) — best RBMK in the set
- Fuel: URAN n=796 in exactly 5 channels, 20px pitch, x-pairs (282,289)/(302,309)/(322,329)/(342,349)/(362,369), y=145-224.
  Each channel: GLOW·METL·URAN·METL | 4px rod slot | METL·URAN·METL·GLOW | METL·PIPE·PIPE·METL·METL·PIPE·PIPE·METL
  (PIPE laid 3-on/1-off vertically). → module `rbmk_channel_cell`.
- Moderator: BMTL n=1120 block (236,50)-(415,127) above the channels; rods pass through it.
- Rods: 1px PSTN at x=286,306,326,346,366 y=67-72 pushing a 4px FRME rod with 2px VACU core (284-287,73-103) in a
  TTAN guide; PTCT side bars. → `rbmk_rod_drive`.
- Heat: per-channel PRTO/PRTI quads at y=85-98 (PRTO 282,85 ch32=2937C … PRTI 289,97 ch30). Outer channels run
  hottest, 2937→2837→2737C inward — a deliberately non-uniform power profile. PIPE net n=11050 (47,12)-(604,262):
  rectangular header y=8-24 dropping down both flanks (x≈112-190, x≈380-530) to y≈260.
- Sensors: DTEC(ctype=GLOW) ×6 at (276..372,114) one per channel gap = fuel-activity feedback for auto rods;
  DTEC(WTRV) (292,118), DTEC(DSTW) (299,120); TSNS/PSNS (413-485,368-370)/(250-258,326).
- Control: SCRAM = isolated SWCH×6 column (21,31-36) on shared WIFI → all 5 PSTN; manual = 5-cell SWCH row per
  channel (50-54/62-66/74-78, y=39) inside INSL-jacketed 11×21 cells at x=45/57/69 y=30-50 (→ `rod_control_cell`).
  No VOID/EMP kill switch anywhere. PCLN(DSTW) (186-188,200)/(203-205,200) gates the DSTW loop.
- Walls: CNDTW 184, WALL 334, ENRGY 68, DTECT 38. Flaw: WIFI standing up to 4733C (10,41)/(21,43) with bare faces.

### 22367 — Highpower channel type reactor (den_koshkin, 1329)
- PLUT n=4686 (180,68)-(431,319); no graphite. Unit cell (x275-300,y60-110): PLUT column capped by DMND, VOID gap,
  NSCN-walled tube holding free NEUT (life 450-850) refreshed by one CLNE(NEUT) seed (CLNE census PLUT=162 NEUT=16).
- Reaction = PLUT spontaneous fission under ambient NEUT bombardment; no piston rods (2011-era build).
- WIFI rails n=615 (Tmax 618C) between channels y=48-50 x=232-379. SWCH (525-532,37-38), BTRY (520,57)/(103,124)/(86,169)/(554,297).
- Cooling cosmetic: SPNG n=2419 + WATR pool (20,65)-(51,330). Walls: EWALL 362 + ABSRB 786 shell, CNDTR 2376 backbone.

### 2000001 — RBMK Reactor TEST (stuka, 108)
- URAN 180 + BCOL 180 (279,132)-(328,151) on an NBLE n=76 bed → NBLE-driven, not a lattice.
- PRTI/PRTO quad PRTI (303,118)/(303,168)/(239,317)/(239,337) ↔ PRTO (304,115)/(304,165)/(239,309)/(239,329): portals
  as a vertical heat-riser staircase, 22→132→232→336C. WTRV n=2002 (100-133C) live boiling.
- CLNE loops SNOW=18, WATR=142. Two 2×6 SWCH pads (263-264,110-114),(343-344,110-114) under WIFI tmp 33→40 =
  duplicator-rate throttle. PPIP@197-202,57 ctype=WTRV with packed tmp = scripted pressure ramp.

### 2591226 — RBMK-1000 Reactor No. 4 (MaxD, 113)
- URAN n=579 (304,78)-(447,246); COAL n=340 (106,77)-(380,331) as literal graphite. PSTN x=308,324,340 y=148-149 tmp=248.
- PIPE n=7260 (168,102)-(482,258); PRTI band (174-185,76) ↔ PRTO (454/481,68-74) 304-392C. DTEC(WTRV) at
  (475/477/479/481,120) and (167/169,122) = steam-void sensing on the header.
- Water panel = three latch buttons at y=11/19/27, x=50-74: SWCH (62,y) set by WIFI ch16 via PSCN above, reset by
  WIFI ch15 via NSCN below, input WIFI ch17/18/19 → PSCN·PSCN·NSCN·METL·SWCH·METL·PSCN·NSCN·METL·PSCN → output WIFI
  ch3/2/1 (fill/flow/drain). Chain segments sit 1px apart. → `latch_button_unit`. BTRY (17,19),(66,43/55/67).
- PCLN(DSTW) (232,128-130)/(415,128-130) flow sensors; PPIP (272-277,253) drain valve.

### 3209222 — Chernobyl RBMK 1000 cutaway (Madveded, 115)
- URAN 84 + BOYL 84 bundle (237,264)-(285,297) — boiler stand-in. COAL n=2523 (21,36)-(474,108) graphite ABOVE the fuel.
- 6 PSTN x=401..451 step 10, y=41, each in an INSL shaft; rod body bare FRME from y=75 down (no graphite tip modelled).
- PPIP n=6864 (152,199)-(583,365) + PRTI/PRTO at 1001-6301C = exaggerated heat transport; WTRV n=275 live. TTAN 20912 / IRON 9848 shell.

### 370469 — Chernobyl Disaster (NukeEmAll, 160)
- Static diorama: 25 URAN at (487,297)-(507,301), every particle k=10000.0, l=0, one dcolour; logic.txt = one line
  (CLNE SMKE=3 FIRE=2); zero NEUT; BRCK/GLAS shell, SALT/COAL rubble, WATR n=2800 pool. No mechanism — zero-cost visual.

## Uranium / BWR-style plants

### 895042 — Uran reactor (BuysDB, 658)
- URAN n=938 (342,232)-(439,298) as a 16px-pitch lattice IRON·IRON·URAN·URAN·IRON·IRON + 10px QRTZ block with two
  1px coolant gaps round an IRON pair and PUMP cells every 2nd row (cols 7,14); QRTZ separator bands with PRTO/PRTI
  pockets every ~14 rows (y=244-259). → `uran_lattice_cell`.
- No PSTN. Auto-control: 519 HSWC (461,265)-(490,313) bonded to the lattice through IRON fire from conducted heat;
  spark teleported via 6 PRTI/PRTO pairs (349,246)-(484,299) to CLNE(WATR)×4 (467-484,259) = water injection when hot.
- SAFE switch: lone SWCH column x=10 y=146-148 (life 13-14, held) by BTRY@10,152 cuts the HSWC loop; keypad x=122
  y=140-148 = manual buttons. 372 WIFI (-98..7927C) drive an LCRY bar wall. No walls.

### 1186972 — Boiling water reactor BETA (BuysDB, 658)
- URAN n=571 (227,161)-(392,298) alternating fuel/insulator/moderator rods. PSTN n=215: rod columns x=409 (169-173)
  and x=446 (166-172), tmp2 counts 5→3→0 as life flips; FRME rails (444-448,173); VOID retract pocket (407,180)-(472,321).
- DSTW n=5218 loop. Turbine inlet: DTEC(WTRV) (512,171),(512,184) + PSNS@523,178 + the save's only TSNS@504,207 (34C).
- Relief stack: three 5px PPIP(DSTW) columns x=517/527/537 y=323-333 in METL/CNCT/BRCK sleeves with WIFI ch44/ch43
  + PRTI feet, gated by SWCH@562,148/153. → `relief_vent_column`. Walls AIR 57.
- Flaw: one TSNS in the whole plant, turbine-side — no core temperature feedback.

### 1289009 — Uranium Power Plant v1.0 (HowlsChaos, 512)
- URAN n=804 (52,270)-(176,297); PSTN n=102 with ~200px shafts from a FRME housing (51,100)-(177,299).
- Per-column quench unit, 24px pitch from x=44: FILT frame, TSNS ladder (47,234)=1200C,(61,234..250)=1000C with WIFI
  outputs (44,234) ch57 / (64,234..250), LN2 pocket (47-48,265-266) refilled by CLNE(LN2) (47,266) at 71K,
  PCLN(LN2) nozzle (49,282) beside the URAN rod (52-56,270-298), PSTN (54,300). → `ln2_quench_fuel_column`.
- Console: 12-switch pad y=110 x=444-516 fed by a DLAY cascade x=208 y=7/16/22/28; WIFI block ~19 cells all ch99
  (9632C) at (213,11)-(358,25). INWR n=11335 signal bus. Walls FAN 18, DTECT 27.

### 2396223 — Nuclear Fission Power Plant (Nuculus, 1068)
- Fuel is POLO n=2017 (30,236)-(523,353) (no URAN) + DEUT n=1872 (445,222)-(555,305). Start = CRAY(ctype=NEUT, tmp 45,
  2000K) at (497,235),(503,235) on INWR columns in IRON cladding (sibling module `neut_cray_nozzle`).
- Turbine gate y=252-257 x=356-388: HEAC rail over PSNS ladder x=358..382 (thresholds 2/4/6/8/10) + TSNS ladder
  x=360..384 (200/275/375/500/650C), one PSCN/NSCN/SWCH per stage — AND-gated start. → `heat_pressure_turbine_gate`.
- PSTN n=678; top pair (230-233,30) captured at 1727C. CRMC 2765, TUNG 1093, GOLD 810. "Console command" for POLO is out-of-band Lua.

### 2867243 — Controllable Nuclear Power plant WIP (MisterChernobyl, 174)
- URAN n=640 (81,291)-(324,354). PSTN n=264 (290,275)-(320,318) all tmp=9999 (sentinel, not stroke).
- Mirrored manifold: TSNS (170,250)&(441,250)=64C, (167,261)&(444,261)=20C; HEAC (171,250-252)&(440,250-252)=70C;
  6 DTEC(WTRV) (208-403,254-258). PCLN(LN2) at (283,330)/(328,330)/(283,344)/(328,344) bottom quench. Walls FAN 58, AIR 343.

### 1653149 — Nuclear Reactor v1.72 (Sandwichlizard, 171)
- URAN n=288 (159,287)-(187,322); PSTN n=179 with ~165px throw = "very slow".
- TSNS ladder x=314 y=180-194 (2px pitch) 901/751/601/501/401/301/201/151C with WIFI ch19..12 at x=311, in INSL, BRCK
  face to the PIPE riser (318-320). → `tsns_wifi_ladder`. PSNS@169-177,329 = 1/2/3/6/8 by a BOYL/QRTZ pocket.
- CRAY(MERC) (86-100,113) feeds DLAY at (88,119/158/177/196) ~111C. PCLN@264,243-248 alternating CO2×4/LN2×1.

## Deuterium reactors

### 341879 — Deuterium Nuclear Reactor (iggyfigs, 892)
- DEUT (136,245)-(263,315) n=2061, life avg 2721 max 9223, seeded cold (5-11K) by CLNE(DEUT) inside the bed at
  (141-149,247),(247-255,263). Ignition: PCLN(NEUT) @157,332 & @241,332 feeding CLNE(NEUT) @153-154/245-246,321-323 from below.
- DMND shell n=599 (6,170)-(588,368); INSL 4216 (hotspots 9546C); SHLD (40,89)-(493,161); FILT field (63,142)-(554,368)
  n=2268 as a full-floor scrubber. DSTW 240 + WATR 722 via PRTI/PRTO (168-231,216-222).
- Flaw: 97 WIFI up to 9726C bare inside a GLAS console (42,89)-(523,321).

### 428137 — Deuterium Fission Reactor (Diocruel, 170)
- DEUT (101,213)-(258,267) n=1002 avg 1632 max 8447. CLNE(NEUT) pairs at (136-137,139-140, y261-262) and (219-220,222-223)
  at both ends of the bed; CLNE(DEUT) liner (122-130,214). DSTW n=7472 via PRTI/PRTO (117-142,65-67),(127-232,158-162), 430→630C.
- DMND 943, GLAS/BMTL shell, INSL max 69C. FILT bank (148,140)-(578,371) cold. Flaw: SWCH grid at -273C baseline.

### 1468603 — Deuterium Reactor v1.3 (ivel236, 569)
- DEUT (297,250)-(338,256), 34 particles all l=65535 in TTAN (249,272)-(386,326); no NEUT at rest = single-pulse design.
  → `deut_pellet_saturated`. CRAY(INSL/COAL) binary readout (151,6)-(173,70) via PSTN@5-26,20; TSNS bar (14-17,12-17) 1602→1100C.

### 1566348 — Deuterium Reactor 2 (hermankronfeld, 252)
- Factory (130,215)-(260,310): DEUT 546, CFLM 237, CLST 203, IRON 470, PPIP 119; DTEC bank @141,223/149,231/179,248/
  179,257 (WATR), @179,252 (DEUT), @178,261 (GLOW) gates auto on/off.
- Core (260,220)-(400,330): TTAN (262,244)-(397,283), TSNS ladder (328,244)=0C,(335,244)=40C,(342,244)=80C,
  (263,282)/(343,282)=177C,(263,284)=401C. No CLNE(NEUT/DEUT) at all — heat+pressure ignition.
- Fuel burn: factory DEUT l=5411 at 0K vs core DEUT (255-260,300) l=53-54 at 102C.

### 5170 — PWR nuclear power plant (321boom, 2675, tagged "notfusion")
- 4 DEUT at (396-399,87) l=19464, zero NEUT. Pure sequencing: PRTI@396-399,93/PRTO@435-437,92 → DLAY@378,92-94 →
  PRTI@257,330/PRTO@257,328; SWCH banks (251-323,47-49); 169 WIFI (266-5194C) light LCRY (167,33)-(428,137).
  INSL box (153,76)-(570,336), TTAN dome ~(280,212)-(330,248), DSTW 3076, LN2 @240-244,274-291.

### 1448557 — Rocket + nuclear engine (925)
- DEUT (96,84)-(355,147) n=1135 avg 8271 in TTAN (96,103)-(357,161), INSL jacket (93,77)-(118,162)+mirror. Primer
  (96,84)-(118,98): PLUT@100-111,97-98, LAVA@101-110,92 (3457C), FRAY@101/110,90, IRON/OIL/PSCN/NITR. Propellant stage
  IGNC+BCOL+C-5+TNT (96,167)-(355,266). Sync: PPIP(DEUT) (108/348,135-136) + PRTI@108/348,138 + PRTO@105-106/344-347,142.

## Other fission / thermite

### 78400 — Realistic Nuclear Reactor Core (2732)
- PLUT 1030 + URAN 50 + DEUT 153 in (237-277,181-275); CLNE liner n=298; SHLD (104,147)-(356,342); TTAN vessel
  n=1315 (117,131)-(350,336). Sequence: TSNS@176,131 over PSTN x=166 y=151-171 (rod withdrawal = "raise temp");
  PSTN (314-326,297) = water valve admitting WATR n=521; PSNS@(269,286),(320,307); DLAY chain (162,171),(168,173),
  (348,135-137),(404,216),(397,265),(317,301); HSWC block (414-417,214-262) = "hold RED". GOO blanket (213,58)-(557,142);
  PIPE n=3353 to NSCN/PSCN turbine housing (481-546,55-130). Flaw: VACU n=400 under the cell (232,280)-(283,303).

### 257313 — Realistic Nuclear Reactor mk.2 (ven1x, 1483)
- PLUT n=192 (56,195)-(79,203), NEUT (45,220)-(51,223), CLNE ctypes COAL=201 WATR=71 PLUT=24 NEUT=12. Core box
  (40-90,185-305): DMND 463, WTRV 231, INVS 96, PIPE 28, PUMP 24. SHLD n=18587 sheathes PIPE n=2939 (ctype DSTW).
  DLAY n=1 @237,52 + BTRY SWCH (232,54-57) single-shot ignition. Flaw: VOID n=346 (Tmax 4369K) beside the cell.

### 212604 — Nuclear Reactor (lucas, 1251)
- Real fuel DEUT n=1048 (112,315)-(303,367); URAN n=95 decorative. CLNE ctypes NEUT=24 DEUT=228 PLSM=27 PHOT=28.
  "Automatic start" SWCH@434,16 + block (340-343,23-26). DSTW inner (320,295)-(468,344) + WATR outer loop; GOO skin;
  PRTO/PRTI (208-283,308-319)→(387-399,344-345); LDTC@302,376 ctype=FIRE alarm. INWR n=1462 bus.

### 254630 — Nuclear Power Plant 2 (scratcher, 317)
- Zero fissile particles at rest. PCLN grid (249-352,264-289) ctypes PLUT=52 DEUT=32 NEUT=6 interleaved
  (PCLN@256,276 PLUT; @348,276 DEUT; @257,267 NEUT) in a METL/PUMP frame with PRTI rows below. → `pcln_fuel_breeder_grid`.
  SWCH 2209 / HSWC 1856; master row (5-16,32). THRM shell (232,264)-(377,289) at -273K inert.

### 199128 — Fully Manual Nucluar PWR (Hellome, 1147)
- DEUT n=241 (140,247)-(207,263) bred by PCLN(DEUT) (163-229,229-299); CLNE ctypes DEUT=116 CFLM=72 PHOT=46 BRCK=336
  VOID=30. 394 SWCH in dozens of clusters, 81 WIFI on ~20 channels each at its own standing temp (642-2722C) — parallel
  unlinked subsystems, 22 element types in the core box. Built-in C-4 35 + THRM 85 charge at (240-243,194-226).
  PUMP n=2993 (16,252)-(583,367) + DSTW (313,232)-(520,254); VOID n=3214 sink. Walls WALL 3850, DTECT 150.

### 214245 — Advanced Thermite Reactor (JA, 589)
- THRM n=2261 (400,228)-(596,326) at 22C unburned; CLNE n=586 with ctype THRM on 477 (+PLSM 60, VOID 75) =
  breed-and-burn with plasma/void exhaust. Soft stop = WIFI hold columns ch19 (x=471,y=16/20/24) & ch21 (x=498) plus an
  up-counter ch27→29 at x=460; hard stop = independent line x=509 (ch0) / x=516 counting 11→9. FILT 15853 + LCRY 14566
  = logo. URAN strip (100,351)-(367,356) decorative. Wall POWDR 6.

### 259948 — Reactor. (Vou, 375)
- URAN n=360 (285,201)-(320,230) at 7992-9998K — captured critical. NBLE n=499 (268,196)-(335,259) medium. INST n=624
  8252K rail (283,129)-(456,350); DSTW (248,207)-(355,227); VENT (248,196)-(355,199). Three PRTI/PRTO pairs at
  x=287/303/319 (y≈233/236) + three at x=452 y=306/326/346 = staged relay. ABSRB ×2 at the hottest point.

## Fusion

### 23905 — Nuclear fusor (Mur, 1239)
- Nested DMND cage (92,40)-(414,371) converging on ~(247,216); LN2 (542, -217C) interleaved IN the lattice + VACU field
  (126,110)-(561,311) = cryopump, not coolant. No fuel at capture; 52 inert NEUT (187-191,211-221); CLNE armed NONE.
  SWCH (564-580,317-359), WIFI (554,349)/(574,362) off. Walls WALL 6384, CNDTR 92 feeding the PSCN/NSCN HV grid (297-582,26-349).

### 144665 — FR-02 (Photonics, 176)
- Spent torch PLSM 13 (5438K) + CFLM 8 at (27-92,43-55); CLNE ctype DEUT=84 = fuel consumed. Panel: 20 WIFI
  (494-602,64-182) ascending tmp 3→22 (130→2018C) telemetry bus; PRTO/PRTI (59-83,221-224)→(129-140,265); no DLAY.

### 1732752 — Infinite fushion reactor (emcaaa, 175)
- GPMP ring (202,71)-(440,309) n=3096 round a VOID 1784 + DMND 1750 core pinned ~9990K. Injector pylons at
  (226-243,97-112) and mirror (403-412): CRAY(ELEC, tmp 5, 495K) on one INST line, CRAY(DEUT, tmp 50, 0K) on another,
  on DMND lances. → `fusion_injector_pylon`. PSTN row y=64-65 x=269-373; DLAY (517-537,32-52). No walls.

### 2317325 — Tokamak Fusion Reactor V2.0 (252)
- GLAS torus (4,144)-(407,354) + FRME coil (14,101)-(546,288); real confinement = GRVTY wall (id 14) 296 cells at the
  core. Zero H2/DEUT/NBLE. PPIP net (84,175)-(544,296) at 7601-7906K by PUMP 1162; WATR n=812 beside it never >310K —
  the missing boil stage. 20 WIFI (266-482,142-203) 1842-5542C; TSNS/PSNS (288-315,146-159); DLAY (21-360,299-328).

### 2730526 — Tokamak in TPT (107)
- HEAC ring (163,196)-(424,326) + DSTW (165,151)-(422,201) round a CRMC/IRON/TTAN toroid. FRAY = 96 px central clump
  (262-325,206-269) max 473K — no confinement role. STOR 237 at 9999K + ARAY 238 = PSTN/DTEC(BRAY)/CONV-triggered flash.
  Zero H2/CO2. Walls FAN 8, NOAIR 6.

### 2919792 — Tokamak MkII
- TTAN torus (49,122)-(383,339); FRAY 32 px (291-320,163-192) max 343K cosmetic; 4 DEUT at (263-269,247) 5K frozen;
  LDTC ctype HYGN (280,176) / NBLE (280,179) = intended ignition. DLAY chain (16-68,288-377) life to 26 timing the
  SWCH pad (11-93,307-312). Walls NOAIR 3.

## Fuel prep / devices / containment

### 69268 — Deuterium compressor (Mur, 267)
- DMND shell (252,44)-(549,327). Seed DEUT (280,72)-(331,123) n=1612 every particle l=10; CLNE lattice interleaved
  y=72-100. Six identical 20px stages from y=132 (270-361 wide): DMND 560, LIFE 160, CFLM 142, VOID 40, CLNE 38 each —
  LIFE cells + VOID vents throttle, CFLM separates stages. All CLNE ctype NONE at rest (unarmed capture).

### 527612 — Deuterium synthesis plant (BuysDB, 281)
- BOYL (176,153)-(242,244) ∩ GLOW (225,147)-(284,262) cell fed CO2 by PIPE (49,4)-(572,376). Cell (220,145)-(290,215):
  METL 770, PIPE 627, WATR 362, BUBW 119, CO2 28, first DEUT 14 (l=10-24). OXYG (45-189,212-333) separate vent loop.
  DEUT piped to x=517 pools at l avg 428 max 2074 — make/store separated 250+px.

### 37968 — Water purifier (684)
- DMND boiler (40,70)-(362,379) to 9726C; steam trap (192,82)-(275,103) = PCLN 484 ctype INSL + INSL 88 + VOID 51 +
  NSCN/PSCN; PUMP (95,207)-(167,243) to a condenser (478,90)-(510,132) with LCRY 232, VOID 146, CLNE 128, LN2 98.
  Zero live water: CLNE bank spawns SLTW=466 (+PLSM 184, CFLM 92, NICE 70, C-4 54, INSL 18) on demand.

### 789902 — Neutron engine 1.13 (162)
- LOXY (40,33)-(135,71) n=2598 -193C → PRTI (42-53,77) → PRTO (197-270,197-214) into a sealed DMND capsule
  (135,165)-(372,246) (18px at y=164, ~90px at y=200-208, closed at y=248). Inside NEUT (149,185)-(275,226), FIRE
  (203-245,186-209), ACEL (192,184)-(275,227); CLNE ctypes FIRE=8 LOXY=210 NEUT=500 DEUT=234. Pusher-plate, not a jet.

### 2223794 — Implosion device (190)
- TTAN 1696 + TNT 3656 ring y=136-248 in ~12 wedges; QRTZ buffer; PLUT pit (292,178)-(324,210) n=4340. 12 DLAY ring
  round (308,194) at 122-336C = per-position delay compensation; DEUT 3×3 (307-309,194-196) l=65535 initiator over INWR n=534.

### 2808681 — Criticality experiment (199)
- PLUT (283,168)-(332,216) n=1879 between METL/ROCK/IRON hemispheres (y=68-108 / 164-252). Gap held by 3 PSTN
  (278/307/336,67-68) tmp=99999 tmp2=79. DTEC(NEUT) (397,182-187) → LCRY 12 + SPRK 2 + BTRY 1 at (467-470,220-225). Max temp 303K.

### 2054452 — Antimatter containment unit (196)
- AMTR (261,170)-(363,262) n=1332 in a SPRK/PSCN/NSCN charge ladder + FRAY arc; the AMTR box itself contains FRAY 78,
  SPRK 55, PSCN 35, METL 1 — wiring runs through the antimatter (the "OSHA violation").

---

## Cross-save synthesis (pass 2)

### Patterns that recur (count = saves showing it)

1. **Fuel-activity sensing by DTEC armed to a witness ctype** — GLOW beside URAN (2001108), WTRV at the turbine inlet
   (1186972, 2591226, 2867243), DEUT/WATR/GLOW level monitors (1566348), BRAY (2730526), NEUT (2808681). **7 saves.**
2. **Staged threshold ladders (TSNS/PSNS rows, threshold in temp)** — 2396223, 1653149, 1289009, 1566348, 1468603,
   2317325. **6 saves.** Two put PSNS and TSNS on one row to AND-gate heat with pressure (2396223, 1653149).
3. **Portal pairs as the heat/coolant transport, not pipes** — 2001108 (per-channel outlets), 2000001 (riser staircase),
   2591226, 895042 (6 pairs), 428137, 341879, 212604, 257313, 259948 (staged relay), 789902, 5170, 144665. **12 saves.**
   Portal temps double as the channel-power readout (2001108: 2937→2837→2737C outer→inner).
4. **PSTN-driven FRME control rods** — 2001108, 2591226, 3209222, 1186972, 1289009, 2867243, 1653149, 78400. **8 saves.**
   No save erases fuel to shut down; SCRAM = insertion. PSTN.tmp is a sentinel (9999 / 99999) in 2867243 and 2808681.
5. **Clone-family fuel breeding (CLNE/PCLN with fissile ctype)** — 254630, 199128, 212604, 341879, 428137, 257313,
   22367, 214245 (THRM), 69268, 37968 (feedstock). **10 saves.** Fuel count at rest can be zero.
6. **Cryogen quench / cryopump from CLNE(LN2) or PCLN(LN2)** — 1289009, 2867243, 1653149 (CO2+LN2), 23905 (in-lattice),
   428137 (cold FILT), 5170. **6 saves.**
7. **Standing-hot WIFI banks as heat/status sources, bare-faced** — 2001108 (4733C), 341879 (9726C in GLAS), 5170 (169
   cells), 895042 (372), 1289009 (ch99 block 9632C), 199128, 254630. **7 saves.** Survivable only because ambientHeat=false.
8. **DLAY temperature as the timer** — 2223794 (12-point ring 122-336C), 78400 (chain life 0-8), 1653149 (~111C cascade),
   1289009 (boot cascade), 2317325, 2919792, 5170. **7 saves.**
9. **Sealed DMND / TTAN capsule around the hot zone** — DMND: 341879, 428137, 69268, 37968, 789902, 1732752, 23905;
   TTAN: 78400, 1468603, 1566348, 1448557, 2396223, 2919792. **13 saves.**
10. **Full-floor FILT field under the reactor** — 341879, 428137, 1289009, 214245 (logo), 144665. **5 saves.**

### Best implementation of each pattern

| pattern | save | coords / module |
|---|---|---|
| Fuel channel unit cell (tileable) | 2001108 | x280-299 y145-224, pitch 20 → `rbmk_channel_cell` |
| Rod drive + SCRAM topology | 2001108 | PSTN (286,67-72), FRME (284-287,73-103); SWCH column (21,31-36) → `rbmk_rod_drive`, `rod_control_cell` |
| Fuel-activity sensor | 2001108 | DTEC(GLOW) (276..372,114) beside GLOW strips x=280/291 |
| Heat+pressure AND gate | 2396223 | (356-388,252-257) → `heat_pressure_turbine_gate` |
| Monotonic TSNS→WIFI ladder | 1653149 | (310-315,179-195) → `tsns_wifi_ladder` |
| Water/valve latch buttons | 2591226 | (50-74,10-33) ×3 → `latch_button_unit` |
| LN2 emergency quench per fuel column | 1289009 | (44-67,224-300) → `ln2_quench_fuel_column` |
| Rod-free thermal auto-cooling | 895042 | HSWC (461,265)-(490,313) → portals → CLNE(WATR) (467-484,259) |
| URAN moderator lattice | 895042 | (342-357,232-243) pitch 16 → `uran_lattice_cell` |
| Fuel-on-demand grid (mixed ctypes) | 254630 | (247-268,276-291) → `pcln_fuel_breeder_grid` |
| Relief valve | 1186972 | (517-525,323-335) ×3 → `relief_vent_column` |
| Neutron ignition probe | 2396223 | (495-499,230-235) → sibling `neut_cray_nozzle` |
| Fusion fuel/spark injector | 1732752 | (226-243,97-112) → `fusion_injector_pylon` |
| Primed max-life DEUT block | 1468603 / 2223794 | (297-338,250-256) / (307-309,194-196) → `deut_pellet_saturated` |
| Cold self-seeding DEUT bed + bottom NEUT injectors | 341879 | CLNE(DEUT) (141-149,247); PCLN(NEUT) @157/241,332 |
| Staged portal heat relay | 259948 | PRTI/PRTO x=287/303/319 (y≈233-236) → x=452 y=306/326/346 |
| Multi-point synchronised trigger | 2223794 | 12 DLAY ring round (308,194), 122-336C |

### Mistakes seen

- Bare WIFI inside meltables: 341879 (97 WIFI to 9726C in a GLAS console), 2001108 (4733C beside METL). Only ambientHeat=false saves them.
- No core-temperature feedback: 1186972 has one TSNS, turbine-side. 2867243 WIFI near LN2 nozzles read -224C (chill bleeding into channel blocks).
- VOID/VACU next to fuel as a "vent": 257313 VOID (Tmax 4369K) beside PLUT; 78400 VACU under the cell; 199128 VOID n=3214.
- Frozen logic: 428137 SWCH grid at -273C; 1566348 factory DEUT at 0K.
- Decorative fuel/fields: 212604 URAN smear, 214245 URAN strip, 5170 four static DEUT, 2730526/2919792 FRAY "magnets".
- Stages admitted missing: 2317325 no boil loop (WATR ≤310K beside 7906K PPIP); 2396223 needs an out-of-band console command to keep POLO solid.
- Wiring through the contained material: 2054452 PSCN/SPRK inside the AMTR volume.
- Over-complication without interlocks: 199128 (394 SWCH, ~20 unlinked WIFI channels, a C-4/THRM charge inside the fuel).

### Ideas for FSN-3

1. Rod feedback from **DTEC(GLOW) witness strips** along the fuel (2001108) and **DTEC(WTRV)** at the turbine inlet — cheap and threshold-free.
2. Turbine start as the **2396223 AND gate** (PSNS + TSNS ladders on one row under a HEAC rail).
3. **2001108 SCRAM topology**: one isolated SWCH column on a dedicated WIFI channel driving every rod PSTN; per-rod manual cells on their own channels; never a VOID kill switch.
4. **LN2 quench nozzle per fuel column** (1289009) fed by a CLNE(LN2) pocket at -202C, fired by the top ladder step.
5. **Portal outlets per channel** to a shared collector (2001108) instead of one long PIPE; read the portal temps as the power profile.
6. Keep a **fuel-on-demand PCLN grid** (254630) as the cold-start / refuel path so the plant can idle with zero fissile load.
7. FSN runs ambientHeat ON, unlike every community save: every copied bank needs the INSL jackets the sources skip. The pass-2 extractor's jacket pass fills empty faces; conductor-touching faces stay open by necessity.
8. Fusion demo: confine with a **GRVTY wall box or GPMP ring**, feed with **CRAY(DEUT)/CRAY(ELEC) pylons** (1732752); FRAY is set dressing.

### Modules written in pass 2 (knowledge/modules/, all compile ok, `verified: true`)

rbmk_channel_cell (param height), rbmk_rod_drive, rod_control_cell, latch_button_unit, heat_pressure_turbine_gate,
tsns_wifi_ladder, fusion_injector_pylon, uran_lattice_cell (param height), pcln_fuel_breeder_grid, relief_vent_column,
deut_pellet_saturated (params width,height), ln2_quench_fuel_column. `cray_neut_igniter` was written then removed as an
exact duplicate of the sibling `neut_cray_nozzle`. Remaining lint criticals (documented per file in `why`): sensor/WIFI
faces that must touch a conductor, PUMP cells inside a lattice by design, PRTI rows sharing one channel as in the source.
