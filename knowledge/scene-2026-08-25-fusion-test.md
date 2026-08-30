# Community save #2 — GLAS control room + TTAN dome + LN2 cryo (captured 2026-08-25)

Loaded by Drew for study. 72,023 particles. **Stamp `6a8e2c2c00`** = whole canvas, `load_stamp` at (0,0).
Companion files: `scene-2026-08-25-fusion-test.parts.jsonl` (every particle + walls + pressure), `.map.txt` (1px ASCII, full legend).
Lessons recorded from it: #65–#71 in `build-lessons.jsonl`. Reusable modules are being extracted to `knowledge/modules/` and explained in `mechanisms-2026-08-25.md`.

## Census (top)
GLAS 15570 · STNE 11591 · BRCK 10534 · CNCT 7440 · SAND 4526 · METL 4474 · INSL 3997 · DSTW 3076 · LCRY 1740 · PQRT 1450 · TTAN 1426 · BCOL 715 · BGLA 673 · HSWC 639 · SWCH 638 · WATR 590 · VACU 576 · PIPE 409 · BRMT 338 · INWR 270 · WOOD 240 · PPIP 208 · WIFI 169 (ch 5–54, 2000–5200 °C) · PSCN 138 · NSCN 110 · LN2 87 (−202 °C) · SALT 61 · FILT 52 · PVOD 44 · PCLN 31 (DSTW×36 incl. CLNE, PHOT×1) · VOID 22 · PUMP 21 · GLOW 18 · BTRY 16 · SPRK 16 · SPNG 15 · PHOT 15 (922 °C) · ARAY 14 · DLAY 13 (all 98 °C → 98-frame delay) · PRTI 11 · PRTO 7 · CLNE 7 (LN2×1) · DEUT 4 (life 19464, −273 °C).
Walls: AIR 190, FAN 133, ENRGY 73, ABSRB 58, GAS 32, CNDTR 19, DTECT 16, EWALL 4, WALL 1. Pressure ≈ 0 everywhere. ambientHeat off, gravity normal.

## Layout (pixel coords, y grows down)
```
CONTROL ROOM (GLAS shell x176-330 y24-140)
  y28-50  x176-232   4 big LCRY lamps 13x13: WIFI+PSCN at top edge (y32, ch 24/25/26/51) lights it; WIFI+NSCN at bottom (y50) resets it
  y45-62  x252-330   4 SWCH/HSWC checkerboard button pads 13x13; each column headed WIFI (y45) / PSCN|NSCN (y46) / HSWC (y47)
                      -> pressing a column sparks its WIFI channel (5,6,9,28,27,54,53,41,42,48,45,44,38...) = the remote-control bus
  y68-140 x176-236   1px LCRY bars in BRCK slots ("#L#") = level/status gauges, 4 columns x 3 banks
  y104-136 x272-300  INSL-jacketed WATR tank (fresh-water store for the console side)
  x232-238 y79-103   ARAY pair with PSCN pads (photon/spark ray signalling)
LASER BAY (x390-462 y84-110)
  396-399,87  packed DEUT 4px, life 19464, -273C in an INSL box; PRTI row under it (y93) -> light source relayed by portal
  434-438,91-95  FILT 5x5 frame: PRTO row / GLOW row / PRTI row = colour-filter + teleport relay cell
  432,97      PCLN ctype PHOT (922C) = laser emitter, powered by NSCN/METL/WIFI stack at 442-458 y106-109
  440-460,88-108  right-triangle GLAS prism; refracted PHOT dots fan out to the right
  x426-429 y84-110  ENRGY wall column (passes photons/neutrons only)
VACU BANK x492-539 y55-66 (576 VACU at 92C) = pressure sink for the laser bay
INSL SHAFT x316-324 y184-300  BRCK-INSL-[AIR-wall core 3px]-INSL-BRCK: air-permeable, particle-tight, insulated duct from control level to reactor level
REACTOR HALL
  x222-300 y211-345  BRCK outer dome + TTAN inner dome (2-3px), TTAN floor y326-343 with CNCT footing; interior EMPTY except a METL emblem/rocket figure at 254-262 y245-262 and a METL deck y251/253
  y255-257 pods at x247 & x284 (inside dome), y251-253 at x338,374,410,446 (logic row), y281-283 at x235 & x260 (LN2 bay):
     INJECTOR POD  "@#y## / + P n / Q Q Q" = WIFI, BRCK, DLAY(98C), BRCK / PSCN, PUMP, NSCN / PCLN(DSTW) x3
                    -> WIFI pulse -> DLAY holds 98 frames -> PSCN powers PUMP + three DSTW cloners = timed coolant flood
     DRAIN POD     "BP @ / +tv+" = BTRY, PUMP, WIFI / PSCN, NTCT, PVOD, PSCN -> powered void eats liquid while gated = timed drain
  x240-244 y272-291  LN2 column, INSL-lined, TTAN cap (y272-279), CLNE(LN2) at 242,275 = infinite -202C cryogen; INSL Tmin -78C at the liner
  x244-260 y296-312  PPIP valve stack (tmp encodes stored element) feeding the bottom chute
BOTTOM BAY (x224-300 y296-336)
  x252-266 y312-330  walled 4px chute flanked by PPIP ("q") + PVOD ("v") columns; PRTO pair at 256/259,316 (ch3) and 257/258,328 (ch4)
  y324-333 x258-268  FILT frame with WIFI/PSCN/HSWC/PRTO/GLOW/PRTI = collector/relay cell (mirror of the laser-bay cell)
  y326-340 x224-300  TTAN floor + CNCT footing; TTAN pillars every 12px
WEST PYLONS x36-100 y246-306  two METL X-truss towers; INWR ("-") catenary wires between them and down into the ground = insulated power/signal lines
RIGHT BUNKERS x476-560 y212-300  hollow BRCK boxes with 1px INSL lining (cold stores); WOOD store x340-364 y288-308
RESERVOIR x480-600 y302-330  DSTW pool with PIPE manifold (409 PIPE) feeding the pods; PUMP x177-465 y252-315 (21)
TERRAIN y307-375  STNE/CNCT/SAND/PQRT/BCOL/BGLA/BRMT/SALT layers; buried INWR runs y127-307; FAN walls (133) and GAS walls (32) as vents/ducts in the ground
```

## How it works (read from state; verification by the EXPERIMENTER worker is in experiments-2026-08-25.jsonl)
1. **Control bus.** Every button column on the console owns a WIFI channel; the WIFI bank (169 blocks) is the multiplexer. Channel = temperature band, so channels 24–54 run at 2400–5300 °C *inside a glass console* — the GLAS is at 922 °C, one hot channel from melting. (Lesson #67.)
2. **Remote flood/drain.** Each chamber has an injector pod (WIFI→DLAY→PSCN→PUMP+3×PCLN(DSTW)) and a drain pod (BTRY→PSCN→NTCT→PVOD, WIFI-gated). One pulse floods for DLAY = temp−273 = 98 frames, one pulse drains. (Lesson #65.)
3. **Cryo.** The LN2 column is a self-refilling −202 °C reservoir: one CLNE that touched LN2 cold, INSL liner, TTAN cap, output through an INSL-lined air-wall channel. (Lesson #68.)
4. **Wiring.** Long runs are INWR (insulated wire) — through ground, across METL, as catenaries — so nothing shorts. METL is only used as local busbar. (Lesson #66.)
5. **Light.** Packed DEUT (life 19464) at −273 °C is the lamp; PCLN(PHOT) is a switchable laser; the GLAS prism demonstrates refraction; FILT/PRTO/GLOW/PRTI cells recolour and teleport photons. ENRGY walls confine energy particles to the bay. (Lesson #71.)
6. **Vessel.** The dome is BRCK outside / TTAN inside with a TTAN floor and CNCT footing; nothing is inside it yet — it is a containment shell awaiting a core, serviced by the pods and the LN2 feed.
7. **Air handling.** AIR walls (190 cells) form particle-tight, air-permeable cores in the shaft and chute; FAN walls (133) in the ground are vents; ABSRB walls (58) soak stray pressure.

## Flaws worth not copying
- Bare WIFI in GLAS (922 °C glass).
- WATR (conductive) tank next to the console logic — should be DSTW.
- DLAY at 98 °C is a 98-frame delay; the DLAY blocks are unjacketed so their temperature (and therefore the delay) drifts with neighbours.

## Recreate
`load_stamp 6a8e2c2c00` at (0,0), or assemble from the modules in `knowledge/modules/` (injector_pod, drain_pod, lcry_lamp, button_pad, cryo_column_ln2, insl_air_shaft, laser_prism_bay, filt_portal_relay, deut_lamp, ppip_valve_chute, inwr_pylon, dome_vessel …) once the ANALYST worker lands them.
