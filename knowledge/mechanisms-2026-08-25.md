# Mechanisms behind the 19 modules (2026-08-25)

Source saves: `community-plut-plant-2026-08-25` (save1, 42k particles, stamp
`6a8e21c900`) and `scene-2026-08-25-fusion-test` (save2, 72k particles, stamp
`6a8e2c2c00`). Every module below was cut from an exact pixel window in one of
the two `.parts.jsonl` dumps (coords cited); geometry is real, not invented.
JSON files live in `D:/powder-toy/knowledge/modules/`.

## injector_pod (save2, 247,255)
5x3 block: WIFI receiver -> DLAY timer -> PSCN spark -> PUMP + three PCLN(DSTW).
The WIFI cell sits at a fixed channel temperature; when a controller elsewhere
raises that channel, the DLAY (whose own temperature sets its delay length,
98C observed) fires PSCN into the PUMP and the three powered clones. PCLN only
emits its ctype fluid *while sparked*, so the chamber floods for exactly the
DLAY period then stops unattended — a one-shot remote valve with no moving
parts. Breaks if: PSCN loses contact with the PUMP/PCLN row (1px gap kills
spark propagation, same rule as PSCN->LCRY), or the WIFI channel is shared
with something else and fires unintentionally.

## drain_pod (save2, 342,253)
4x2 mirror-image circuit: BTRY -> PUMP (suction) + WIFI (remote gate) on one
row, PSCN -> NTCT -> VOID -> PSCN on the other. NTCT is the gate: it only
conducts the BTRY's spark past a temperature/state condition, so VOID (which
deletes anything touching it, always) is only "live" transiently instead of
being a permanent hole. Two independent PSCN taps sandwich NTCT so both a
local BTRY and the remote WIFI channel can trigger it. Breaks if: VOID is
placed adjacent to fuel you want to keep during the "off" phase — NTCT gating
reduces exposure but doesn't remove the risk (this is why the source puts a
1px gap of empty/INSL around it, not the fuel itself).

## lcry_lamp_13 (save2, one lamp at 187-199,35-47)
A square LCRY slab lit through a 1px nub: WIFI->PSCN feeds the top nub,
WIFI->NSCN drains the bottom. LCRY only reads PSCN that's in direct contact
(no diagonal, no 1px gap), so the nub is the entire interface — the 13x13
body just makes the result visible from a distance. Two independent channels
(set/reset) let a controller pulse the lamp on and off without touching the
body. Breaks if: the nub loses contact with the body, or channel_set ==
channel_reset (the lamp would flicker or never settle).

## button_pad (save2, one pad at 251-263,45-61)
WIFI channel cell over a PSCN pad drives a 13x13 checkerboard of SWCH/HSWC.
Alternating the two element types every cell means a spark landing anywhere
on the pad always finds a conductive path out (SWCH and HSWC have different
switching behaviour; alternating them makes the pad tolerant of exactly where
it gets hit) — this reproduces the "big reliable button" pattern rather than
a single 1px switch that can be missed. Breaks if: you shrink below a 2x2
checkerboard (loses the alternation) or feed it a channel already in use by
something in the same room.

## lcry_bar_gauge (save2, 176-236,68-140)
BRCK-LCRY-BRCK, 1px LCRY sandwiched in a slot. On its own it's just an always
readable strip; the source's "level gauge" behaviour comes from PSCN taps
placed against sections of the LCRY column from outside the module (not
included here — this module is the slot, the taps are wired in separately per
threshold). Breaks if: BRCK on either side is breached, letting stray PSCN or
heat light the whole column instead of a section.

## wifi_bus_row (save2, console 176-330,28-62 — IMPROVED)
8 WIFI cells on sequential channels, wrapped in one shared INSL jacket. The
source ran 169 bare WIFI blocks (channels 5-54, up to 5100C standing temp)
directly inside a GLAS console and cooked the glass to 922C — a build-lessons
critical finding. This module is the fix the lesson calls for: jacket the
whole bus in INSL before it touches anything that melts. Breaks if: you build
the console shell directly against the jacket's outside face without a gap —
INSL blocks conduction but a touching GLAS wall still radiates/conducts at
the jacket's outer skin temperature over time.

## cryo_column_ln2 (save2, 240-244,272-291)
TTAN cap, INSL side jacket, LN2 fill, one CLNE(LN2) breeder cell near the top.
LN2 (actually LNTG under the hood) is deleted outright at 77K with no
byproduct, and spawns near ambient unless created cold — so a static LN2 pour
boils away in under a second. The single CLNE, armed to LN2 by touch and kept
at -202C, continuously reseeds the column: every particle it emits inherits
its own -202C, refilling faster than the column warms. INSL keeps that cold
from bridging into the frame; TTAN caps the top against pressure. Breaks if:
the CLNE itself is allowed to warm above ~63K transition threshold — it stops
seeding correctly ("keep the breeder cell itself cold").

## insl_air_shaft (save2, 316-324,184-300)
BRCK-INSL-[[WALL:AIR core]]-INSL-BRCK cross-section. The WALL:AIR core blocks
particle flow entirely (it's a wall type, not an element) while carrying wires
or sensors through it; INSL on both faces stops the shaft from becoming a
thermal or electrical bridge into whatever it passes through. This exists
because a bare METL floor/slab is air-permeable and leaks pressure transients
into a sealed room — the shaft is the hardened version. Breaks if: you swap
WALL:AIR for an element (elements conduct heat even through a vacuum gap, see
build-lessons "vacuum gaps don't insulate").

## laser_prism_bay (save2, PCLN at 432,97)
PCLN armed to PHOT emits photons only while sparked; a PSCN tap above and an
NSCN tap below are the local trigger contacts (the remote WIFI channel that
ultimately drives PSCN lives elsewhere in the source and isn't part of this
module). An INSL horseshoe — three sides, open toward the beam path — keeps
the 922C photon-carried heat off everything except the shot itself. The GLAS
prism profile is reproduced exactly: 9 steps, apex width 5 growing by 2px per
row-pair, matching the source's staircase diagonal (not a fabricated true
triangle). Breaks if: the horseshoe is closed on the beam-exit side (blocks
the photons) or GLAS gets hot enough to approach ~1000C from repeated shots.

## filt_portal_relay (save2, 434-438,91-95)
5x5 hollow FILT frame holding a PRTO/GLOW/PRTI sandwich. Photons enter through
the FILT (which also sets their colour if decorated — a separate rendering
lesson), land on PRTO (out-channel), the GLOW row is a passthrough marker, and
PRTI (in-channel) re-injects on its own channel elsewhere in the build. This
lets a beam cross the map without a physical light-pipe. Breaks if:
channel_in == channel_out on the same relay (creates a photon short-loop).

## deut_lamp (save2, 394-401,86-96)
INSL box holding a 4px packed DEUT bar frozen to -273C, with a PRTI floor on
its own channel. DEUT has neither PROP_LIFE_DEC nor PROP_LIFE_KILL, so once
life crosses 240 (here: 19464, deliberately overpacked) it glows permanently
without decaying or radiating heat into the INSL box — the one truly
maintenance-free light source (PLSM burns out in seconds, GLOW needs
turbulence). The PRTI floor is how the source drains/reads the block remotely
without opening the box. Breaks if: the DEUT block cools below life-240
equivalent concentration or the INSL seal is broken (a stray spark can arm it
as fuel instead of decoration).

## ppip_valve_chute (save2, 224-300,296-336)
Central PPIP riser (a powered pipe segment / valve, default-closed) between
two TTAN walls, flanked by PVOD drain columns, with a FILT collector strip at
the bottom. PPIP carries fluid only when its valve state is open (toggled by
spark elsewhere); the two PVOD columns give the chute an emergency dump path
independent of the riser. Breaks if: the riser and the PVOD columns share the
same trigger circuit — the source keeps them on separate WIFI channels so a
drain command can't also open the valve.

## inwr_pylon (save2, 36-100,246-306)
X-truss METL tower with one INWR pixel at the apex, tagged with id "top" so a
blueprint can run `{"line":"INWR","from":"p1.top","to":"p2.top"}` between two
instances. INWR conducts SPRK only along its own run, never sideways into a
touching conductor — that's what makes it safe to cross or bury inside METL
structure (the truss itself) without shorting the wire into the tower. Breaks
if: you swap the span wire for METL (shorts into every pylon it touches) or
route INWR through GOO/CNCT expecting it to also act as structure (it's
signal-only, not load-bearing).

## dstw_reservoir_manifold (save2, 480-600,302-330)
Hollow BRCK basin, INSL floor liner, DSTW fill, N horizontal PIPE(DSTW)
offtakes. The whole loop is DSTW rather than WATR specifically because WATR
conducts SPRK and would short any conductor the manifold pipes cross; DSTW
does the same cooling job without that risk. Breaks if: an offtake pipe is
re-armed to a conductive ctype, or WATR is mixed in upstream and reaches the
manifold.

## dome_vessel (save2, 222-300,211-345)
Hollow BRCK shell with a TTAN band near the top and a CNCT floor cap. This is
a materials-safety module more than a shape: BRCK, CNCT and GLAS are the only
verified non-conductive structural elements (TTAN, METL, BMTL all carry
PROP_CONDUCTS), so capping the floor in CNCT instead of TTAN/METL is what
stops a stray BTRY inside the dome from shorting the whole vessel. Breaks if:
the floor cap is swapped for TTAN/METL to "match" the dome band above it —
that's the exact mistake the build-lessons entry warns about.

## nscn_fuel_head (save1, 226-176 to 290-212)
INSL-lined TTAN case holding a PLUT bed, sitting inside a thick NSCN mound.
PLUT is the neutron source (spontaneous fission under pressure); NSCN is
chosen as the ballast specifically because NSCN never passes SPRK to PSCN, so
nothing outside the mound can spark the bed into an unplanned reaction — only
the seeded DEUT/CLNE(NEUT) underneath it (see dmnd_throat) can start the
chain. Breaks if: NSCN is swapped for any PROP_CONDUCTS element (METL, BMTL,
PSCN) as ballast — that reopens the external spark path.

## dmnd_throat (save1, 226-290,228-239)
TTAN plenum plate over a DMND funnel between two METL shoulder blocks, sitting
on a URAN liner, with a PRTI/PRTO cryo pair (channel 1) either side and a
WIFI/PSCN tap firing a CLNE(NEUT) seed into the throat. Neutrons drop from the
fuel head above through the DMND funnel (DMND passes neutrons, shapes the
flow) into the chamber below; the cryo portal pair moves coolant in on one
side and back out the other without a physical pipe run across the throat.
Breaks if: the CLNE(NEUT) seed fires continuously instead of pulsed (chain
reaction runs away, per build-lessons DEUT yield-control entry).

## breeder_liner (save1, 232-283,244-275, one side)
PUMP pressure column beside a DMND liner band, with a CLNE(DEUT) breeder cell
every 5 rows using the native `repeat` op (so `height`/`period` genuinely
rescale the seed spacing, unlike the fixed-count modules above). CLNE learns
DEUT by touch once, then emits a low-life DEUT particle every tick forever,
so the fuel column never depletes even as the reaction consumes it. Meant to
be placed twice, mirrored, flanking pressure_chamber's fill region — it adds
the self-breeding wall pressure_chamber doesn't provide. Breaks if: the CLNE
row is placed touching the reaction's hottest cells directly (it can catch
fire/melt like any exposed CLNE) rather than behind the DMND liner face.

## village_house_bmtl (save1, 477-546,55-130, one house)
BMTL header band, CNCT walls, GOO ground plinth, GLAS window, WOOD roof (two
diagonal lines rather than the stepped roof of the generic `house` module, so
it stays valid at any width/height). Distinguished from the existing `house`
builtin (BRCK/WOOD) by its wall material: CNCT, chosen because it's
non-conductive, matching the same electrical-safety lesson as dome_vessel.
Breaks if: BMTL is used for the full wall height instead of just the header —
BMTL conducts and melts at 1273K, fine as a thin decorative band but not as
structure near any heat source.

---

## Design principles observed

1. **Jacket every standing heat source.** WIFI/PRTI/PRTO sit permanently at
   their channel's temperature (channel N = 73.15+100*(N-1) K), not just while
   firing. The unjacketed 169-cell WIFI bus in the source console cooked its
   own GLAS shell to 922C — always wrap WIFI in INSL (wifi_bus_row, deut_lamp,
   cryo_column_ln2's cap all do this).

2. **Non-conductive structure list is short: BRCK, CNCT, GLAS.** TTAN, METL,
   BMTL, PSCN, NSCN, NBLE, INST all carry PROP_CONDUCTS. Pick the floor/shell
   material by this list, not by "looks solid" (dome_vessel, village_house_bmtl,
   nscn_fuel_head's NSCN-not-METL ballast).

3. **DSTW, not WATR, near anything conductive or logical.** Same cooling
   behaviour, no spark conduction (dstw_reservoir_manifold, injector_pod,
   ppip_valve_chute).

4. **PSCN must touch its target directly — no diagonal, no 1px gap.** This
   silently kills lamp panels, button pads and injector pods alike; when
   something "isn't lighting", check adjacency before anything else
   (lcry_lamp_13, button_pad).

5. **CLNE learns its ctype once by touch, then emits forever.** Use it as a
   controllable seed/breeder (arm it, then keep it cold or hot as needed) —
   it's the mechanism behind self-healing liners, infinite cryogen columns and
   self-breeding fuel walls alike (cryo_column_ln2, breeder_liner).

6. **NTCT/PVOD/VOID gating turns a permanent hazard into a remote-controlled
   one.** Raw VOID always deletes; gating it behind NTCT (a
   temperature/state-conditional conductor) means it's only "live" when
   something upstream sparks it (drain_pod).

7. **WIFI channel pulses, not permanent switches, drive one-shot actions.**
   PCLN/powered clones only emit while sparked; pairing a WIFI receiver with a
   DLAY timer gives a bounded-duration action (flood for N frames, then stop)
   with no moving parts and no need to re-poll state (injector_pod).

8. **A checkerboard of two related elements beats a single switch pixel.**
   Alternating SWCH/HSWC over an area makes the control tolerant of exactly
   where it's hit or wired into, at the cost of more particles (button_pad).

9. **Packed DEUT (life >= 240, frozen) is the only genuinely maintenance-free
   light source.** PLSM decays in seconds; GLOW needs turbulence; DEUT with
   neither PROP_LIFE_DEC nor PROP_LIFE_KILL just sits there glowing
   (deut_lamp).

10. **Vacuum gaps do not insulate — the air/ambient grid still conducts heat
    across empty cells.** Use INSL (HeatConduct=0), not empty space, to
    actually block a thermal bridge (insl_air_shaft, cryo_column_ln2).

11. **WALL:AIR (a wall type) blocks particles while staying an "empty" cell
    for wiring/sensor runs** — different from an element, and different from
    a vacuum gap; use it specifically for instrument shafts through hot zones
    (insl_air_shaft).

12. **INWR crosses conductive structure safely; METL/regular wire does not.**
    Route any signal that must pass through or beside structure on INWR, and
    reserve METL for local busbars only, tagging its endpoints with `"id"` so
    two pylon instances can be joined by a plain `line` part afterward
    (inwr_pylon).

13. **Portal pairs (PRTI/PRTO) move heat, coolant or photons across the map
    without physical routing — but the portal itself sits at its channel's
    temperature/state, so treat it like any other WIFI-adjacent hazard and
    jacket or isolate it** (dmnd_throat's cryo pair, filt_portal_relay).

14. **When a module's true shape is a diagonal (a triangular prism, a
    staircase), reproduce the exact step pattern from the data rather than
    approximating with a rectangle** — laser_prism_bay's 9-step GLAS profile
    (apex 5px, +2px per row-pair) came directly off the source, not from
    guessing "right triangle".

15. **Static-part-count JSON modules can't truly loop** — only the blueprint
    compiler's native `repeat` op (used in breeder_liner and
    dstw_reservoir_manifold) rescales with a param count. A hand-authored
    checkerboard or multi-slot bus (button_pad's 13x13, wifi_bus_row's 8
    slots) is baked at a fixed size; say so in the module's description
    rather than implying it resizes freely.

16. **Keep module params numeric-only.** A registry loader that evaluates
    "numeric fields as arithmetic expressions over params" cannot also accept
    a string param standing in for an element/ctype name inside a `box`/`ctype`
    field. Every module here bakes its material choices as literals in
    `parts` and only exposes width/height/channel/temp/life-type knobs — this
    was a real compatibility fix made mid-session after the integrator's
    contract came in, not a design guess.
