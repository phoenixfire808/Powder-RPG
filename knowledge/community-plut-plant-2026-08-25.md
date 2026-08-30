# Community PLUT/DEUT power plant — full intake (2026-08-25)

Drew loaded a community save so its techniques could be learned. This is the recreation package.

## Artifacts
- **Stamp `6a8e21c900`** — whole canvas (0,0)-(611,383), pressure included. `load_stamp` at (0,0) restores it exactly.
- `community-plut-plant-2026-08-25.parts.jsonl` — every particle (42,125): type,x,y,life,ctype,tmp,tmp2,temp(K),dcolour; then wall cells [cx,cy,wallType] and pressure cells |p|>1. Replay with create_particle/set_particle_property to rebuild without the stamp.
- `community-plut-plant-2026-08-25.map.txt` — full 1px ASCII map with legend.
- Build-lessons store entries dated 2026-08-25 23:0x (11 lessons) — the generalised techniques.

## Census (42k particles)
BRCK 6523 · DSTW 5790 · GOO 4241 · DMND 4168 · PIPE 3353 · NSCN 3322 · METL 2683 · INSL 2090 · SHLD 1532 · TTAN 1315 · CNCT 1160 · PLUT 1030 · LCRY 660 · WATR 555 · VACU 400 · WOOD 351 · COAL 301 · CLNE 298 (INSL 244, DEUT 42, DSTW 6, NEUT 4, PLUT 2) · PUMP 256 · GLAS 226 · BMTL 176 · PLNT 166 · DEUT 153 · PRTI 145 · IGNC 119 · SPNG 112 · PSCN 109 · VOID 109 · HSWC 101 · GLOW 94 · NTCT 72 · NEUT 58 · URAN 50 · PPIP 48 · INST 47 · SWCH 38 · PSTN 34 · PRTO 24 · WIFI 15 · SHD2-4 34 · DLAY 8 · FRME 6 · BTRY 3 · CRAY 4 · PTCT 3 · ARAY 2 · PSNS 2 · TSNS 1.
Walls: types 1,2,3,5,6,7,8,11,13 (302 cells). Pressure +127 in PUMP columns, −256 in VACU sump. ambientHeat OFF.

## Layout (pixel coords)
```
y52-130  x68-150   Two cooling towers (BRCK shells, DMND base braces, wall lip y120, DSTW basin y124-130)
y74-132  x158-335  Generator hall: METL X-brace scaffold, BRCK sheds with NTCT thermostat rows (y110,127), GLAS+SWCH lamp domes at (272,77) & (372,77), ARAY pair at (232-238,103) with PSCN pads
y55-130  x477-546  Village: BMTL/CNCT/WOOD/GLAS houses on GOO ground, PLNT row y124-132, PCLN at (530,63), WIFI ch-6/8 (heated 314-578 C)
y132-136 x68-560   INSL deck — thermal floor separating surface from plant
y150-300 x160-200  West logic bay: PSTN column x166 y151-168 + FRME, INSL-boxed circuit y169-177 (BTRY@160,170; DLAY 162,171 / 168,173; PTCT 165,175; WIFI ch-5 @168,176), TSNS @176,131 + WIFI ch-5 @173,131 on the deck
y176-212 x226-290  Fuel head: NSCN mound around a TTAN-walled, INSL-lined PLUT bed (U rows y180-204, x232-284)
y213-223 x226-290  Manifold: METL/NSCN header; PRTO ch-3 pads at x239 y220-223 (feed in); PRTI @277 y220-223; PIPE stubs to the east (x276-290)
y224-227           TTAN/METL plenum plate
y228-239 x226-290  Ignition throat: DMND funnel, NEUT + CLNE(NEUT/DEUT) seeds at (254-259,230-233), PRTO ch-1 @277 y228-231 (cryo), WIFI ch-3 + PSCN at (277,237-238)
y240-243           wall row (pressure boundary)
y244-275 x232-283  Reaction chamber: PUMP columns x232-235 & x280-283 (4px, wall-jacketed); DMND liners x243 & x272 with CLNE(DEUT) breeder cells every 5 rows (y245,250,...,275) at x240-242 / x273-275; free DEUT + NEUT in the middle x246-269; URAN row y237-239
y276-279           wall row
y280-303 x232-283  VACU sump (checkerboard VACU, wall-separated inner box y284-291, ladder of VACU rows y297-301); control pocket x244-247 y283-287 (PTCT, NSCN, METL, PSCN, BTRY@244,286, SPRK) and PSNS@269,286
y304-309           wall + NSCN floor
y150-340 x276-356  Two SHLD-sheathed PIPE risers (SppS / SSppppSS) carrying coolant north-south
y208-290 x405-447  LCRY status wall: INST bus x394 (238 C), SWCH enable @396-397, HSWC pixels at x414-417, DLAY @404,216 / 397,265, WIFI ch-4 @417,268 & 444,266, CRAY(METL)@438-440,263
y295-302 x422-442  IGNC pad + DMND under the panel (alarm/flash)
y156-182 x444-498  Intake box: COAL shell, PIPE, SPNG, VACU pockets, PRTI ch-3 cluster (446-465,163-165) — sends whatever it collects to the manifold PRTO ch-3
y280-342 x296-362  Control bay: PRTO ch-7 @325 y288-291, PSTN row y297 x305-317 + FRME, TTAN ram, PSNS@320,307, BTRY@318,300, WIFI ch-50/60 @313,295/299 & 318,308 (4727-5727 C!), DLAY@317,301, PRTO ch-6 @307-310,330, PRTO ch-50/60 pads at x320 & x351 y337-340 (bottom outlets), GLOW markers
y200-330 x88-100   BRCK standpipe with WATR column
y288-330 x104-320  DSTW cooling pool; PIPE bundle 12 rows y315-326 x188-320 with PPIP valves @188-190,315 (ctype DSTW); CLNE(INSL) liner rows y313 & y328 x100-215 between INSL rows
```

## How it works (as read from state; not yet re-tested by us)
1. PLUT bed on top is the neutron source; NSCN mound = non-conducting ballast/heat mass around it (NSCN never carries SPRK to PSCN, so the bed can't be sparked from the case).
2. Neutrons drop through the DMND throat into the chamber; CLNE(DEUT) cells along the DMND liners keep re-breeding DEUT so the fuel never runs out (DEUT avg life 27, max 1000).
3. PUMP columns hold the chamber at +127 pressure (DEUT reaction and NEUT release scale with pressure); VACU sump below at −256 pulls the exhaust/heat down through the wall grid and keeps the chamber from over-pressurising.
4. Heat leaves through the SHLD pipe risers and the PRTI/PRTO channels: ch-3 = intake box → manifold; ch-1 = cryo return (−146 C); ch-7 = control bay; ch-6 = bottom drain; ch-50/60 = super-hot diagnostic pair at the bottom outlets.
5. DSTW pool + 12-row PIPE bundle is the condenser; PPIP valves on the west end; CLNE(INSL) liners self-heal the bundle's insulation.
6. Logic: three BTRY (west bay, chamber pocket, control bay) drive DLAY timers → PSTN rams (west x166 and control y297) and WIFI channels 3/4/5/6/8/50/60; TSNS on the deck and two PSNS report to the LCRY wall via INST/HSWC.
7. Surface: village deck sits on the INSL floor but is heat-soaked to 106 C through METL girders and WIFI ch-8 — a flaw worth fixing in a rebuild (close the INSL around the girders).

## Recreate
`load_stamp 6a8e21c900 at (0,0)` — or, from scratch, follow the layout table top-down: walls first for the pressure boxes (rows y240-243, 276-279, 304-307 and the PUMP/VACU jackets), then DMND/TTAN/NSCN structure, then PUMP/VACU fills, then fuel (PLUT bed, DEUT, CLNE seeds — arm CLNE by touch), then pipes/portals (set tmp channels as listed), then logic, then decoration. Pause throughout; DEUT and NEUT are live the moment the sim runs.
