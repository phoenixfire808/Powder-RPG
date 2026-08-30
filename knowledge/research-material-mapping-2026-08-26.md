# Research Front 4/5: Material & Chemistry Realism Mapping (2026-08-26)

Scope: read-only research. No game/simulation touched. Sources read: `materials-catalog.json`,
`materials-catalog-packs.json`, `power-elements-2026-08-26.json`, `chemistry-rules.json`,
`scripts/lua/{chem_kinds,power_kinds,material_kinds}.lua`, `stock-element-realism-patch{,-v2}.json`,
`stock-element-props-original.json`, `experiments-2026-08-26.jsonl`, plus **the actual TPT C++ engine
source** (`D:/The-Powder-Toy/src/simulation/**`) because deliverable (1) explicitly requires fitting
against "the TPT source defaults" — you cannot know what a field *does* from JSON alone. That source
dive overturned several assumptions baked into the task brief and the existing catalog; those
corrections are load-bearing for everything below, so they're presented first.

WebSearch budget for this session was already exhausted (200/200, spent by earlier fronts — see
`stock-element-realism-patch-v2.json`'s own note) before this front started, so no new live searches
were possible. All chemistry numbers below are standard textbook/reference values from training
knowledge, cited to the same Wikipedia-style sources the existing files use, and confidence-flagged
exactly like `stock-element-realism-patch-v2.json` already does for its own budget-exhausted entries.
Treat medium-confidence numeric values as "right order of magnitude, spot-check before load-bearing
use," not as verified citations.

---

## 0. Ground-truth engine corrections (read before anything else)

These came from reading `Element.cpp`, `Element.h`, `Simulation.cpp`, `SimulationData.cpp`, and
`ACID.cpp`/`BASE.cpp`/`FIRE.cpp` directly. They change how deliverables (1)-(2) should be read.

### 0.1 TPT already has a specific-heat field — the task's premise is wrong

`Element.h:44`: `float HeatCapacity; // Volumetric heat capacity per one pixel. Must be nonzero. The
default value is 1.0f.` It's a real, settable, serialized struct property (`Element.cpp:92`, same
`StructProperty` table that backs Lua's `elem.property(id, name, value)` — see `LuaElements.cpp:421,
529,558`), and it is the actual denominator in the heat-transfer math:

- Air exchange (`Simulation.cpp:2457-2463`): `alpha = min(0.04, 0.4*hc)`; `temp += alpha*dtemp/hc`.
- Neighbour exchange (`Simulation.cpp:2466-2509`): every neighbour with nonzero `HeatConduct` is
  pulled into a **hc-weighted equilibrium average** — `pt = Σ(temp_j * hc_j) / Σ(hc_j)` — and then
  *every one of the 8 neighbours plus self is snapped to that single averaged temperature in one
  frame* (not a gradual step). `HeatCapacity` is the weight in that average.

None of the ~150 custom elements across the three catalog files set `heatCapacity` — every single one
silently inherits the 1.0 default (confirmed: `grep -r heatCapacity` over the whole knowledge/ tree
returns zero hits inside any catalog entry). That means LHE (real ρc≈0.03 kJ/(m³·K) scale, should
swing temperature almost instantly) and DU (dense, high real volumetric heat capacity, should be
thermally sluggish) currently have **identical thermal inertia**. This is the single highest-value,
best-defined fix available in this whole report — see §1.7.

### 0.2 `Hardness` is not corrosion resistance — it's an ACID/BASE dissolve-probability dial, and the catalog has it backwards for several "corrosion-resistant" entries

`Hardness` is read in exactly three places in the whole engine: `ACID.cpp:87-95`, `BASE.cpp:200-206`,
`CAUS.cpp:76-83` (CAUS is ACID's high-life "caustic" variant). The logic, verified by reading the
actual code:

```
ACID.cpp:87  chance_to_dissolve_per_neighbour_per_frame = Hardness / 1000        // HIGHER Hardness = MORE soluble in acid
ACID.cpp:91  heat_released_on_dissolve = max(0, (60 - Hardness) * 7)            // HIGHER Hardness = LESS heat on dissolve
BASE.cpp:200 only affects targets with 0 < Hardness < 50; chance = (50-Hardness)/1000  // Hardness >= 50 is TOTAL base immunity
```

Cross-checking stock values (`grep Hardness src/simulation/elements/*.cpp`) confirms this is not a
misreading: **DMND=0, GOLD=0, GLAS=0, STNE=1, METL=1, TUNG=1** (i.e. the stock game's hardest, least
reactive materials are set to *near-zero* Hardness — full acid immunity, zero base immunity) while
**RIME=32, WARP=30, GRAV=30, SPNG=31, YEST=31, RSST=50, DUST=30** (soft/fluffy/organic-flavoured
stock elements sit mid-scale). The field name is a false friend; it means "acid solubility index,"
and low values mean *tougher*, not "soft."

The materials catalog gets this backwards for its flagship "chemically inert" entries: **ZRCA=92,
ALUM=90, SIC=90, TI64=90, PTFE=95, S316=80** are all described as "chemically near-inert" / "extremely
inert" / "excellent corrosion resistance," but at Hardness 90-95 the native ACID mechanic gives them
a 9-9.5%/frame dissolve chance — worse than materials the catalog explicitly calls acid-vulnerable
(LMST=10, MRBL=12, at 1-1.2%/frame). They do happen to get full BASE immunity right (≥50), but that
looks like an accident of the same high number, not a considered choice. **There is no single
Hardness value that gives immunity to both ACID and BASE** — the two native mechanics pull in opposite
directions (low Hardness ⇒ acid-proof but base-chews-it at (50-H)/1000; high Hardness ⇒ base-proof but
acid-chews-it at H/1000). Stock GLAS gets true universal acid immunity through a **hardcoded special
case** (`parts_avg(i, r, PT_GLAS) != PT_GLAS` in `ACID.cpp:89`) that only checks for literal
neighbouring GLAS particles — custom elements cannot opt into that check.

Practical recommendation for a truly "acid- and base-inert" material (PTFE, ALUM, ZRCA, BORO, FSIL):
set Hardness to 0-3 (buys full/near-full ACID immunity, the mechanically closer of the two evils since
ACID is the far more commonly-placed stock element in builds) and accept the small residual
BASE-vulnerability (0-5%/frame) as a known, documented limitation rather than pretending it's fixed.
Retain the current 80-95 values only where the *mechanical* wear-hardness flavor text is what matters
and the element is never expected to meet ACID/BASE in a build (e.g. WC as a drill bit).

### 0.3 `Weight` is an ordinal density-rank int with a hard ceiling; `Explosive` is a 2-bit flag, not a magnitude

- **Weight** (`SimulationData.cpp:126`): `if movingType.Weight <= destinationType.Weight: can't
  displace`. It only governs which of two *movable* (LIQUID/GAS/PART) particles sinks below the
  other when they're both present in one cell's fall-check; it does nothing for `TYPE_SOLID` (solids
  don't density-sort). The field is clamped 0-100, which saturates hard: real densities above roughly
  2,900 kg/m³ are simply not distinguishable (see §1.2). This is already implicitly how the project's
  own RBDM patch was derived (`stock-element-realism-patch-v2.json`); §1.2 makes that formula explicit
  and shows it breaks for anything denser than wet sand.

- **Explosive** (`Simulation.cpp:2790`, `FIRE.cpp:304-316`, `PROT.cpp:142`): read only as
  `Explosive & 2` (pressure-triggered: converts to FIRE autonomously above local pressure 2.5) and as
  a truthy/nonzero check gating a small `+0.25*CFDS` pressure kick when a *Flammable* neighbour ignites
  from touching FIRE. **There is no code path anywhere that reads `Explosive` as a graded magnitude.**
  Stock elements only ever use 0, 1, or 2 (`GUNP=1, LRBD=1, RBDM=1, NITR=2, PLEX=2` — every single
  nonzero stock value, confirmed by grep). The catalog's `H2O2=15`, `O3=20`, `SUGR=15`, `STAR=15` are
  functionally just their low two bits: 15&2=2 (pressure-autodetonates), 20&2=0 (does *not*). Concretely:
  - **O3's `explosive:20` does nothing at all.** It also never sets `flammable`, so the FIRE.cpp branch
    (which additionally requires `Flammable>0`) can't fire either. Ozone is currently 100% inert to
    both mechanisms despite the catalog description promising it "can detonate at high concentration."
  - **SUGR and STAR (`explosive:15`, `flammable` set)** get BOTH bits: they ignite-with-pressure-kick
    on flame contact (intended, matches real combustible-dust hazard) **and** autonomously detonate
    into FIRE the instant local pressure exceeds 2.5 with *no ignition source at all* (almost certainly
    not intended — table sugar shouldn't spontaneously detonate from being squeezed).
  - **H2O2 (`explosive:15`, no `flammable` set)** only gets the pressure-autodetonation bit (its
    FIRE.cpp branch is dead since Flammable=0), so its actual native behavior is "explodes if
    pressure ever exceeds 2.5," independent of the custom `MG>WTRV,SELF` decomposition rule. That's a
    plausible flavor (shock-sensitive concentrated peroxide) but was very likely not the intent behind
    picking "15."
  - See §2 for the reaction-table implication and §4 for why detonation velocity/energy genuinely
    cannot be encoded in this field at all.

### 0.4 Heat-conduction *events* fully equilibrate a 3×3 neighbourhood in one frame — this is why thermite quenches

`HeatConduct` (uchar 0-251+) is read as `rng.chance(int(HeatConduct*gel_scale), 250)` —
**probability-per-frame that a conduction event fires at all**, i.e. effectively
`min(HeatConduct,250)/250` (≥250 ≈ always). `HeatConduct=0` is a special case
(`SimulationData::IsHeatInsulator`): a true wall, blocking conduction *and* ambient-air exchange
entirely, not just "very slow."  When the event *does* fire, it is not a small step — it computes the
`HeatCapacity`-weighted mean temperature across self + all 8 neighbours and snaps everyone to it in
that single frame (`Simulation.cpp:2466-2509`, cited above). AL61 (HeatConduct 170, ≈68%/frame) and
stock BRMT (HeatConduct 211 unpatched, ≈84%/frame) both conduct almost every frame, so a freshly-hot
reacted particle's temperature is diluted across ~9 cells before it can raise any *unreacted* neighbour
past its own ignition gate. This is the precise mechanism behind the documented `P13` experiment
result ("TPT heat conduction spreads reaction heat through the whole block within frames; front
quenches unless reactants are thin," `experiments-2026-08-26.jsonl` line 13) and is the load-bearing
fact for §3.

### 0.5 Boiling *is* pressure-sensitive already, but only via a generic (not per-material) linear fudge

`Simulation.cpp:2513-2519`: any `TYPE_LIQUID` element whose `HighTemperatureTransition` target is
`TYPE_GAS` gets `ctemph -= 2.0*pv[cell]` before the threshold check — i.e. positive local pressure
*raises* the effective boiling point by 2 K per pressure unit (matches the real direction: compression
raises boiling point), and the inverse applies to `TYPE_GAS→TYPE_LIQUID` condensation. This is generic,
not hardcoded to WATR, so every reactive liquid in the catalog with a `TYPE_GAS` transition target
already gets it "for free." The real Clausius–Clapeyron slope (`dT/dP ≈ RT²/(ΔH_vap·P)`) differs by an
order of magnitude between substances; TPT's flat ±2 K/pressure-unit is a substance-blind approximation
— fine for gameplay, but not something a formula in §1.6 can meaningfully sharpen without a DSL
extension (see §4).

---

## 1. Property mapping: real quantity → TPT field

### 1.1 Thermal conductivity → `HeatConduct`

Mechanically (§0.4), `HeatConduct` is a quantized 0-251 "probability of a conduction event," not a
literal analog of *k* (W/m·K). Real *k* spans ~6 orders of magnitude (0.01 aerogel → 2,000 W/mK
diamond → 5,000 GRPN); TPT has ~2.4 decades of usable int range (log10(251)≈2.4). No single global
formula reproduces the catalog's own chosen values well — I fit log, sqrt, and log-linear curves
against ~75 `(k, HeatConduct)` pairs harvested directly from the catalog's own inline "k=X W/mK"
descriptions (every `materials-catalog*.json` entry states its real *k*) and all systematically
mis-fit the middle of the range, because the existing patch passes were done by **ordinal, per-material
judgment relative to neighbouring anchors**, not one formula (visible in `stock-element-realism-
patch-v2.json`'s own prose: "closer to X, lower than Y").

Best whole-range single-formula compromise (anchored so AERO/LHE/PUFM≈1 and DMND=255, the two extremes
actually in the catalog):

```
HeatConduct = round(clamp(28 * ln(k_W_per_mK + 1) + 3, 1, 251))
```

Spot check against catalog values (k in W/m·K):

| k | formula | catalog | Δ |
|---|---|---|---|
| 0.02 (AERO) | 4 | 1 | +3 |
| 0.2 (PVC/PTFE) | 8 | 7 | +1 |
| 50 (RBAR-ish) | 113 | 108 | +5 |
| 100 (WC) | 132 | 133 | -1 |
| 200 (BE) | 151 | 187 | -36 |
| 2000 (DMND) | 216 | 255 | -39 |
| 5000 (GRPN) | 242 | 255 (cap) | -13 |

Known weak spot: it **overshoots by ~2× in the 1-10 W/mK band** (k=1 → 22 vs catalog's usual 11-16;
k=6 → 58 vs catalog's ~25-30). Given the int scale is coarse and gameplay differences between
HeatConduct 11 and 22 are marginal (both mean "rarely conducts"), this is acceptable for prospective
use but should be spot-checked by eye for anything landing in that band rather than trusted blindly.
Anchors: use `k` values from a real materials table (Wikipedia "List of thermal conductivities"),
apply the formula, then sanity-check against the nearest existing catalog neighbour before committing.

### 1.2 Density → `Weight` / `Gravity`

`Weight` only matters for `TYPE_LIQUID`/`TYPE_GAS`/`TYPE_PART` (§0.3) — leave `TYPE_SOLID` at 100
regardless of real density; the catalog already does this correctly (GRNT 2700 kg/m³ and BSLT 3000
kg/m³ both sit at Weight 100 with zero differentiation, which is *correct* given solids don't
density-sort, not an oversight).

For movable states, the project's own RBDM fix already implicitly used two anchors: WATR
(1000 kg/m³ → 30) and SAND (2650 kg/m³ → 90). Making that explicit:

```
Weight = round(clamp(30 + (ρ_kg_m3 - 1000) * 60/1650, 1, 100))
```

Validated: Rb (1532 kg/m³) → 49.3, matches the already-shipped patched value of 48 almost exactly.
Li (534 kg/m³) → 13.1 vs the shipped 17 (same ballpark, two-point linear fit residual expected).

**Hard ceiling, and a bug it exposes:** the formula saturates at Weight=100 for anything above
~2,925 kg/m³ — real density differences above that (aluminium 2,700 vs DU 19,100 vs tungsten 19,300)
are simply not representable; they all tie at 100. This isn't hypothetical: **mercury (real 13,534
kg/m³) is denser than LBE, lead-bismuth eutectic (real ~10,500 kg/m³), yet the catalog has MERC
Weight=91 and LBE Weight=100** — backwards. A dropped MERC/LBE mixed pool would sort wrong relative to
reality. Recommend bumping MERC toward 95-97 (it's not itself broken, just under-ranked relative to a
newer liquid that shipped later and correctly claimed the ceiling).

`Gravity` (float, per-element fall-acceleration multiplier, separate from `Weight`) is **not** a
density proxy — it reads more like a viscosity/"does this feel like a heavy liquid" knob
(`Simulation.cpp:2288-3265`). Evidence against fitting it to density: FLBE (real molten-salt density
≈2,000 kg/m³) gets Gravity 0.3 and LBE (real ≈10,500 kg/m³, 5× denser) gets only 0.35 — a 17%
difference for a 5× density gap. Recommend leaving Gravity in the conventional bands already used
(gas 0.1, thin liquid 0.15-0.2, heavy/viscous liquid 0.3-0.5) rather than deriving it from ρ; treat it
as a stability/feel parameter, and use `Weight` as the only rigorous density channel.

### 1.3 Ignition/flash/autoignition → `Flammable` + `HighTemperature`

These map to two genuinely different real quantities and the catalog is already directionally right:

- **`HighTemperature`/`HighTemperatureTransition`** is a deterministic threshold-crossing type-swap
  (`Simulation.cpp:2526-2534`) — this is the correct home for **autoignition temperature** (the real
  physical quantity: spontaneous combustion without an external flame/spark), exactly as the
  `stock-element-realism-patch-v2.json` DESL fix (335K flash-point-shaped value → 543K real
  autoignition midpoint) already did correctly. Use autoignition temperature, not flash point, for
  this field whenever both are documented — they can differ by 100-200K (e.g. diesel: flash ~325K,
  autoignition ~540K).
- **`Flammable`** governs a probabilistic ignition-on-contact-with-fire roll:
  `chance/frame = (Flammable + local_pv*10)/1000` (`FIRE.cpp:305`). This tracks **how eagerly a flame
  spreads into it once a fire source is already touching it**, which correlates inversely with
  **flash point** (the temperature at which vapor is present in flammable concentration) rather than
  combustion energy. Fitting `ln(Flammable)` vs flash-point-in-K against the fluids-pack anchors
  (ETOH 286K→700, KERO 323K→300, BDSL ~415K→150, GLYC ~433K→40) gives a workable log-linear rule of
  thumb:

  ```
  Flammable ≈ round(clamp(exp(6.7 - 0.0195*(T_flash_K - 273)), 0, 1000))
  ```

  Fit quality is only fair (4 anchor points, R² moderate — BDSL sits ~1 e-fold hotter than the trend
  predicts, likely a deliberate "still usable as fuel" gameplay nudge) but is a defensible starting
  heuristic: **each ~35 K of flash-point increase roughly halves `Flammable`.**

### 1.4 Detonation velocity/energy → `Explosive`

**This mapping is not possible as stated** — see §0.3. `Explosive` has no magnitude semantics in the
engine at all; real detonation velocity (TNT ~6,900 m/s, RDX ~8,750 m/s, ANFO ~4,500 m/s) or
detonation energy (TNT ≈4.6 MJ/kg) cannot be encoded in it beyond two independent booleans:

- bit 0 (any odd value): ignites (with a small pressure kick) when a Flammable version of it touches
  FIRE/LIGH — deflagration-class behavior (GUNP/black-powder analogue).
- bit 1 (`&2`): autonomously converts to FIRE once local pressure exceeds 2.5 — shock/impact-sensitive
  high-explosive analogue (NITR/PLEX analogue).

Recommendation: **only ever use 0, 1, 2, or 3.** Map real explosives onto the 2×2 truth table by
sensitivity class, not by energy: primary/shock-sensitive (RDX, PETN, NITR) → 3 (both); confined
deflagrating propellants/low explosives (black powder, ANFO without a booster) → 1 only; something
meant to be pressure-triggered but inert to open flame (rare) → 2 only. **Real yield/violence has to
live somewhere else** — either in `Flammable` (rate of the FIRE.cpp branch) plus the reaction's own
`dT`/`extra` products if it's modeled through the reactive-kind DSL instead of the native flag, or —
better — through a new dedicated "blast" kind that pushes `sim.pressure` directly, scaled to a
documented TNT-equivalent yield (see §4, feature 3). Existing catalog entries to fix under this
corrected model: **O3 (currently fully inert, should probably be 1, tied to giving it a nonzero
`flammable`), SUGR/STAR (currently 15 = bits 0+1 set = spontaneously pressure-detonates, almost
certainly should be 1 only), H2O2 (15 = pressure-bit only since Flammable is unset — plausible but
verify intent, otherwise set to 0 and let the existing `MG>WTRV,SELF` decomposition rule carry all the
peroxide behavior).**

### 1.5 Corrosion resistance → `Hardness`

Covered in full in §0.2. Summary rule of thumb going forward: **decide which acid/base story matters
more for the specific material, then pick 0-3 (acid-proof, base-vulnerable) or ≥50 (base-proof,
acid-vulnerable) — never both, and never use Hardness values in the 80-95 range to mean "very
corrosion resistant," because in the native engine that reads as "very soluble in acid."**

### 1.6 Vapour pressure → boiling transition

Already correctly implemented as a deterministic `HighTemperature`/`HighTemperatureTransition`
threshold plus the generic pressure-sensitivity described in §0.5. No formula is needed beyond citing
the real 1-atm boiling point for the threshold (which the patch files already do meticulously, e.g.
LOXY/LN2/LHE/LH2 all match real cryogenic boiling points to within a few millikelvin-scale rounding).
The one real gap: **TPT's ±2 K/pressure-unit slope is identical for every substance** regardless of
real latent heat, so it cannot distinguish "boils gently under pressure" from "barely shifts under
pressure" substances. Not fixable without a DSL/engine change; not worth one given how rarely
pressure-shifted boiling is gameplay-visible.

### 1.7 Specific heat → `HeatCapacity` (the field already exists — use it)

Contrary to the task brief's premise, no proxy is needed: `HeatCapacity` (float, default 1.0, settable
via the same `elem.property`/`update_element` path as every other field, §0.1) is TPT's literal
specific-heat analogue, expressed as "volumetric heat capacity per pixel" relative to the implicit
default-1.0 material. Since **zero** catalog entries currently set it, every custom element — from
LHE (cryogenic near-vacuum-density liquid) to DU (dense actinide metal) — has identical thermal
inertia today, which is arguably the single biggest unexploited realism gap in the whole catalog and
the cheapest to fix (one new field, no rule/DSL changes, no game-breaking risk since anything untouched
keeps its current default-1.0 behavior).

Recommended formula, normalized so `WATR` (ρ=1000 kg/m³, c=4,186 J/(kg·K), i.e. ρc≈4.186 MJ/(m³·K))
lands near the 1.0 default already implicit for it:

```
HeatCapacity = clamp((ρ_kg_m3 * c_J_per_kgK) / 4.186e6, 0.02, 8.0)
```

Sanity checks: LHE (ρ=125, c≈5,190 J/kgK for liquid He) → ρc≈0.65 MJ/m³K → HeatCapacity≈0.15 (swings
temperature ~7× faster than water, matches cryogen intuition). DU (ρ=19,100, c≈116 J/kgK for uranium)
→ ρc≈2.22 MJ/m³K → HeatCapacity≈0.53 (still swings faster than water per-volume, despite being dense,
because uranium's specific heat is unusually low — a genuinely interesting real effect this field can
now express that nothing else in TPT can). DMND (ρ=3,510, c≈509 J/kgK) → ρc≈1.79 MJ/m³K →
HeatCapacity≈0.43. Clamp bounds (0.02-8.0) exist purely to avoid the `alpha=min(0.04,0.4*hc)` term in
`Simulation.cpp:2459` producing pathological single-frame jumps at very low `hc` or near-zero movement
at very high `hc` — test any material landing outside roughly [0.1, 3] in-sim before shipping it.

---

## 2. Reaction kinetics → `chance`/frame, enthalpy → `dT`

`chance` is a flat per-neighbour-per-frame probability (`chem_kinds.lua:84`, `math.random() < r.chance`)
— it is the right home for **how easily/fast the reaction proceeds once conditions are met** (real
kinetics: activation energy, rate constant), independent of how much heat it releases. `dT` is applied
in full to both participants the instant the roll succeeds (`chem_kinds.lua:93-104`) — the right home
for **the adiabatic temperature jump from one reaction event**.

The catalog's own reaction-doc entries quote real ΔH in wildly inconsistent units — some per mol of a
tiny atom (U, per-mol ΔH looks huge but per-kg is unremarkable), some per mol of a huge organic
molecule (tristearin, MW 891). **Comparing dT across reactions only makes sense once ΔH is normalized
to kJ/kg of the reacting (SELF-side) fuel** — the same normalization that makes NA, TI64, MG, ETOH all
land in believably comparable "how hot does this burn" territory in real life. Doing that normalization
across all ~30 reactive-kind entries in the three catalog files and fitting a single log-linear curve:

```
dT ≈ round(clamp(180 * log10(|ΔH_kJ_per_kg| / 50), 40, 900))
```

| Element | Reaction (SELF-normalized) | \|ΔH\| kJ/kg | Current dT | Formula dT | Verdict |
|---|---|---:|---:|---:|---|
| LMST/MRBL | CaCO₃+2HCl→CaCl₂+H₂O+CO₂ | 170 | 80 | 96 | matches |
| CAO | CaO+H₂O→Ca(OH)₂ | 1,160 | 300 | 246 | matches |
| H2O2 | 2H₂O₂→2H₂O+O₂ | 2,890 | 250 | 317 | matches |
| CL2 | H₂+Cl₂→2HCl | 2,600 | 400 | 309 | matches |
| CAC2 | CaC₂+2H₂O→Ca(OH)₂+C₂H₂ | 1,950 | 60 | 286 | **intentional split** — most of the reaction's "expression" is routed to the `extra:GAS` acetylene spawn instead of heat; document this inline in the source, it isn't self-evident |
| DU | U+O₂→UO₂ | 4,560 | 500 | 353 | matches (slightly hazard-boosted, fine) |
| F2 | 2F₂+2H₂O→4HF+O₂ | 6,850 | 500 | 384 | matches |
| S | S+O₂→SO₂ | 9,250 | 300 | 408 | close, mildly damped for reluctance-to-ignite, fine |
| CA | Ca+2H₂O→Ca(OH)₂+H₂ | 10,340 | 300 | 417 | under formula, intentional (low reactivity vs Na/K per its own description) |
| NA/NAK | 2Na+2H₂O→2NaOH+H₂ | 8,000 | 600/650 | 397 | boosted ~200K above formula — deliberate hazard-salience choice, defensible (Na+water is famously dramatic), not a bug |
| RBAR/CIRN/IRON | 4Fe+3O₂+2H₂O→rust | 7,380 | 3 | 390 | **intentional, but undocumented** — dT deliberately near-zero to represent a vanishingly thin per-event reacted layer; the real "how much energy" lives entirely in `chance` (0.002-0.004) instead. Add a one-line comment; as written it reads like an oversight. |
| CS | 2Cs+2H₂O→2CsOH+H₂ | 1,550 (est., medium conf.) | 900 | 268 | **flag: likely mis-scaled.** Cs has *lower* per-kg energy than K (heavier atom, similar molar ΔH) yet is given a *higher* dT than K. The "most dramatic alkali metal" framing belongs on `chance` (Cs already correctly leads there at 0.9 vs K's 0.6-0.7) — recommend rebalancing CS dT down toward ~350-450 and letting `chance`/`needsHeat` carry the drama. |
| K | 2K+2H₂O→2KOH+H₂ | 5,030 (est., medium conf.) | 800 | 360 | boosted, same direction as Na, acceptable — but see CS row for the *relative* ordering problem |
| WP | P₄+5O₂→P₄O₁₀ | 24,060 | 600/400 | 483 | matches |
| TI64 | Ti+O₂→TiO₂ | 19,700 | 700 | 467 | matches (mildly boosted, fine) |
| MG/MGRB | 2Mg+O₂→2MgO | 24,760 | 900 | 485 | matches — correctly anchors the top of the scale, matches real ~24.7 MJ/kg to the number |
| ETOH | C₂H₅OH+3O₂→2CO₂+3H₂O | 29,700 | 500 | 499 | **excellent match** |
| BDSL | FAME+O₂→CO₂+H₂O | 38,000 | 500 | 519 | matches |
| KERO | C₁₂H₂₆+18.5O₂→12CO₂+13H₂O | 44,200 | 550 | 530 | **excellent match** |
| GLYC | C₃H₈O₃+3.5O₂→3CO₂+4H₂O | 17,990 | 350 | 460 | under formula, intentional (viscosity/low vapor pressure damping, stated explicitly in the source file) |
| NH3 | 4NH₃+3O₂→2N₂+6H₂O | 18,600 (est.) | 200 | 463 | under formula; plausible (narrow 15-28% flammability range justifies damping) but worth a bump toward ~300-350 if NH3 fires should feel more consequential once actually lit |
| CH4 | CH₄+2O₂→CO₂+2H₂O | 55,490 | 700 | 548 | boosted, consistent with PROP (see next row), acceptable "explosive gas" license |
| PROP | C₃H₈+5O₂→3CO₂+4H₂O | 50,340 | 750 | 541 | boosted, same pattern as CH4 — internally consistent, not flagged |
| CELL | (C₆H₁₀O₅)ₙ combustion | 17,280 | 300 | 457 | under formula, plausible (smoldering vs flaming) |
| LIGN | lignin combustion | ~17,000 (same order) | 300 | 457 | **flag: bug, not intentional.** LIGN's rule string is byte-identical to CELL's (`FIRE>NONE,SELF:300:.2:O2:SMKE`) despite LIGN's own description explicitly claiming it "chars rather than flaming as readily as pure cellulose, harder to ignite." No numeric differentiation exists — recommend lowering LIGN's `chance` (e.g. 0.2→0.12) to actually deliver on the stated design intent. |
| SUGR | sucrose combustion | 16,500 | 300 | 453 | under formula, plausible (dust-explosion risk already captured via the `explosive` stat instead) |
| TLLW | tristearin (fat) combustion | 39,600 | 400 | 522 | under formula but directionally correct — highest dT of the CELL/LIGN/SUGR/TLLW organic family, matching it having the highest real per-kg energy, so this family is internally *consistent* once normalized to kJ/kg even though none hit the formula exactly |
| AL61 (thermite) | 2Al+Fe₂O₃→Al₂O₃+2Fe | ~8,900 (per kg Al₂O₃ product, extremely rough) | **see below** | ~395 | **flag: documentation/rule drift bug, not a scaling issue.** `chemistry-rules.json` documents AL61's rule as `BRMT>STNE,IRON:850:.15:FIRE:SMKE`, but the *live* rule in `materials-catalog.json` is `BRMT>STNE,IRON:2500:.8:HEAT400:FIRE` — different dT, chance, gate, and byproduct. The live version matches the `P13` experiment setup exactly, so it's almost certainly the newer, intentionally-revised one; `chemistry-rules.json` was never updated to match. Reconcile the two files so the "chemistry index" doc isn't lying about what's actually loaded. |

Overall: the enthalpy scaling is **more principled than it first looks** — most apparent "outliers"
are defensible, if undocumented, choices to route energy into `chance`, `extra` products, or narrative
hazard-salience rather than raw `dT`. The two genuine bugs worth fixing are the **AL61 doc/rule
drift** and the **LIGN/CELL identical-rule non-differentiation**; the one worth a design conversation
is the **CS/K dT ordering inversion**.

---

## 3. Self-propagating reactions that survive TPT's conduction model

Given §0.4 (a single conduction event fully equilibrates a hot particle with its whole 3×3
neighbourhood), a self-propagating front needs to win a race: **heat must reach the next unreacted
layer's ignition threshold faster than conduction dilutes it below that threshold.** Three
complementary levers, all expressible in the current DSL:

1. **Low-`HeatConduct` products.** The AL61 rule currently converts the reacting cell into stock
   `STNE`/`IRON` (HeatConduct 90/150 post-patch) — reasonable metals/rock, but not deliberately chosen
   to *retain* heat. Real thermite slag (molten Al₂O₃/Fe mixture) has much lower bulk thermal
   diffusivity than either reactant while still hot. Route the product through a **dedicated new
   low-conductivity "slag" element** (HeatConduct ≈10-20, matching real molten-oxide k≈2-5 W/mK via
   §1.1's formula) instead of shared stock STNE/IRON, so a just-reacted cell holds its heat for many
   frames and radiates it forward gradually rather than flash-averaging away in one.
2. **Staged/two-rule propagation using `needs=HEAT<K>` as a preheat gate.** Split "warm the next layer"
   from "consume and combust" into two rules on the same element (semicolon-joined, ≤64 chars each,
   already supported): a cheap, high-chance, small-dT rule that fires on any FIRE/hot-neighbour contact
   and just raises temperature without consuming anything (`SELF`/`SELF` unchanged), building a
   preheated buffer zone ahead of the front — then a second, high-dT combustion rule gated at a
   *higher* `HEAT<K>` threshold that only fires once the preheat has actually done its job. This avoids
   dumping one enormous one-shot dT (which conduction immediately divides by ~9) in favor of many
   smaller, cumulative nudges spread over more frames and more simultaneously-reacting grains.
3. **Moderate, not extreme, per-event `dT`, compensated by high `chance` and thin geometry** — matches
   what the `P13` experiment already tried (an 8×2 fuse) and what the §2 table recommends generally:
   very large one-shot dT values look impressive on paper but are exactly what the
   equilibrium-averaging mechanic punishes hardest.

**Concrete thermite rule to test next**, combining all three (needs a new `FSLG` element, HeatConduct
≈15, otherwise inert/STNE-like):

```
AL61 rules: "FIRE>SELF,SELF:120:.5::FIRE;BRMT>FSLG,IRON:450:.9:HEAT480:FIRE"
```

Rule 1 is the preheat stage (any FIRE contact nudges both AL61 and the ambient warmer without
consuming AL61, cheap and frequent). Rule 2 is the combustion stage: only fires once the AL61 particle
itself has reached 480 K (`needs=HEAT480`, self-gated, exactly the mechanism already validated in
`P13`'s `BRMT>STNE,IRON:2500:.8:HEAT400:FIRE`), converts AL61 into the new low-conductivity `FSLG`
slag (retaining heat) and BRMT into IRON, at a moderate 450 K bump and high 0.9 chance — small enough
per-event that the 3×3 equilibration doesn't erase it, frequent enough that many simultaneous grains
sustain the front. This should be run as a follow-up experiment (`P14`) before trusting it.

---

## 4. What's impossible in the current DSL, and the minimal extension that unlocks the most

Real chemistry the `WITH>SELF,OTHER:dT:chance[:needs][:extra]` grammar (`chem_kinds.lua:1-52`) cannot
express:

- **True two-consumed-reactant stoichiometry.** `needs` only *gates presence* of a second neighbour —
  it is never itself transformed or consumed (`chem_kinds.lua:84`, `hasNeighbour` is a pure boolean
  check). You can already fake unconsumed catalysis cleanly (`H2O2`'s `MG>WTRV,SELF` rule leaves MG as
  `SELF`, i.e. present-but-unchanged — a legitimate catalyst pattern), but you cannot write "A + B (both
  consumed) + C (catalyst, unconsumed) → D" as a single rule.
- **Concentration/depletion.** Every successful hit either fully transforms `SELF` or leaves it
  fully unchanged — there is no partial-consumption state. The native engine already has exactly the
  right primitive for this (`ACID.cpp` uses `parts[i].life` 0-75 as a literal concentration counter,
  degrading it per dissolve and diffusing it between adjacent ACID particles), but `chem_kinds.lua`
  never reads or writes `life` at all.
- **Gas products that build real pressure.** `extra` spawns exactly one particle of a named element
  into one free neighbouring cell (`chem_kinds.lua:96-99`) — a reasonable proxy for small yields, but
  it cannot represent bulk gas evolution pressurizing a sealed vessel without spawning (and then
  simulating the native gas-diffusion physics of) dozens of individual particles per event, which is
  both slow and doesn't actually behave like a pressure spike until those particles have had time to
  push on their surroundings.
- **Reversible/equilibrium chemistry**, and **rate laws with an explicit reaction order** (chance is a
  flat constant, never scaled by a measured local reactant density/count).

**Minimal 3-feature extension** (each a small, backward-compatible addition to `parseRules`/the
per-frame closure in `chem_kinds.lua`, none breaking any of the 34 existing rule strings):

1. **Concentration via `life`.** Add an optional 6th colon field, e.g. `:conc=N`. On a successful hit,
   instead of unconditionally applying `selfB`, decrement `parts[i].life` by `N` (defaulting `life` to
   100 via the element's existing `DefaultProperties.life`, already settable per-element); only apply
   `selfB`'s transform once `life` hits 0. Optionally also scale `chance` by `life/100` for a
   naturally-decaying reaction rate. Unlocks: gradual acid consumption, a fuel tank that depletes over
   many contacts instead of vanishing on the first one, batteries/PCM-style materials that "run down."
   ~10-15 new lines in the existing hit-handling branch.
2. **A consumable second reactant.** Extend the `needs` field's grammar from `NEEDS_ELEM` to
   `NEEDS_ELEM[=NEEDS_BECOMES]` (`=` is currently unused inside a field, so this is unambiguous and
   fully backward-compatible — omit it and behavior is identical to today). `H2>NONE,ACID:400:.5:O2=NONE`
   would mean "only react if O2 is also present, and consume that O2 too" — genuine two-reactant
   stoichiometry, which is currently impossible.
3. **Direct pressure yield on reaction.** Add an optional 7th field, `:pgas=X` (float), that on a
   successful hit adds `X` directly to `sim.pressure` at the reacting cell, scaled to a documented real
   mol-of-gas-per-event figure instead of (or alongside) spawning individual `extra` particles. This is
   the highest-leverage feature for reactor/engine-style builds: a carbide-lamp gas generator, a sealed
   peroxide decomposition chamber, or an ammonia-cracking cell could all deliver a genuine, physically-
   motivated overpressure spike to a sealed vessel without needing to spawn and then wait on dozens of
   GAS particles per frame.

These three map directly onto the three examples the task brief itself flagged (two-reactant+catalyst,
gas products with pressure, concentration via life) — which suggests they're the right three to build,
not just three arbitrary options.

---

## 5. Missing real-world element classes worth adding, prioritized by build usefulness

**Priority 1 — extends existing functional systems already built (reactors, power, chemistry demos):**

- **Hydrazine (N₂H₄) + dinitrogen tetroxide (N₂O₄), hypergolic propellant pair.** N₂H₄: ρ=1,021 kg/m³,
  mp=274.7K, bp=386.7K, ΔH combustion with N₂O₄ ≈ -600 kJ/mol N₂H₄ (self-decomposition alone ≈ -95
  kJ/mol, monopropellant-capable via a catalyst-bed pattern identical to the existing MG-catalyzed
  H2O2 rule). N₂O₄: mp=261.9K, bp=294.3K — liquid only in a ~33K band around room temperature, which
  is a great "handle very carefully" gameplay constraint on its own. Real Apollo/Titan/Shuttle-OMS
  fuel. Build value: a genuinely different, *restartable, no-igniter-needed* engine archetype the
  existing KERO/LOX chain structurally cannot provide (LOX/KERO needs a spark; hypergolics ignite on
  contact).
- **Real high explosives as a 3-tier family: RDX, PETN, ANFO.** Given §1.4's finding that
  detonation-velocity magnitude is inexpressible, the value here is in **ignition-threshold and
  Explosive-bit differentiation**, reusing the exact 3-tier pattern already validated for reactive
  metals (Mg/Ti64/DU). RDX: ρ=1,820 kg/m³, det. vel. 8,750 m/s (context only, not encodable), decomposes
  ~477K, shock-sensitive → `Explosive=3`. PETN: ρ=1,770 kg/m³, mp=414K, the most impact-sensitive common
  military explosive → `Explosive=3`, lower ignition threshold than RDX. ANFO (94/6 ammonium
  nitrate/fuel oil): bulk ρ≈840 kg/m³, det. vel. only ≈4,500 m/s — the low-brisance industrial/mining
  workhorse that famously needs a booster charge → `Explosive=2` only (pressure-sensitive, but give it
  a much higher ignition/gate threshold than RDX/PETN so it can't be set off by a stray flame the way
  they can, the real-world differentiator).
- **Hydrogen sulfide (H₂S).** Sour-gas/refinery hazard gas, ρ≈1.5 kg/m³ (gas phase), highly toxic
  (lower exposure threshold than the existing CL2), flammable, autoignites ≈533K, burns to SO₂+H₂O.
  Directly on-theme for an industrial "plant" build (ties into any oil/gas-processing functional
  system) and complements the existing KERO/OIL fluids pack with a genuine process hazard rather than
  just another fuel.

**Priority 2 — extends existing families, more niche but well-documented:**

- **Liquid bromine (Br₂) and solid iodine (I₂).** The gases pack has Cl₂/F₂ but no liquid/solid
  halogens. Br₂: ρ=3,120 kg/m³, mp=265.8K, bp=332K — the only halogen liquid at STP, a distinctive
  "always at your own body temperature" build element. I₂: ρ=4,930 kg/m³, sublimes directly to violet
  vapor at 457K (no liquid phase at 1 atm) — a striking, well-known sublimation demo, and completes the
  halogen family for a "periodic table corner" showcase.
- **Neodymium magnet material (Nd₂Fe₁₄B).** ρ=7,500 kg/m³, Curie point 583K (loses magnetism above
  that — reuse the exact pattern already implemented for PZT's Curie point). Real strong permanent-
  magnet material; would let generator/motor-rotor builds use an actual magnet element instead of only
  SPRK-driven electromagnetism, directly extending the existing TEG/turbine/photovoltaic power-system
  family.
- **Tantalum (Ta) and rhenium (Re).** Ta: mp=3,290K, k=57 W/mK, exceptional resistance even to most
  hot acids (real chemical-plant lining metal). Re: mp=3,459K, the second-highest-melting metal known,
  also excellent corrosion resistance. Both slot between the catalog's existing HF/W/Ti64 tier and give
  finer-grained choice at the very top of the reactor-cladding/rocket-nozzle material stack (current
  ceiling is WC/TUNG at 3,143-3,695K).

**Priority 3 — lower immediate build leverage, still cheap to add:**

- **Ethane (C₂H₆)**, mp=90K, bp=184.6K — completes an LNG/cryogenic-fuel chain alongside the existing
  LCH4/CH4 pair.
- Simple demo-only compounds (e.g. AgNO₃/silver halides for a photography vignette) — real, citable,
  but no obvious tie-in to an existing functional system, deprioritized until one exists.

---

## Files read (for provenance)

`materials-catalog.json`, `materials-catalog-packs.json`, `power-elements-2026-08-26.json`,
`chemistry-rules.json`, `stock-element-realism-patch.json`, `stock-element-realism-patch-v2.json`,
`stock-element-props-original.json`, `experiments-2026-08-26.jsonl`, `tpt-lua-api-cheatsheet.md`,
`scripts/lua/chem_kinds.lua`, `scripts/lua/power_kinds.lua`, `scripts/lua/material_kinds.lua`, and
(for §0's engine ground-truth, required by the task's own "read the TPT source defaults" instruction)
`D:/The-Powder-Toy/src/simulation/Element.{h,cpp}`, `Simulation.cpp`, `SimulationData.{h,cpp}`,
`elements/{ACID,BASE,CAUS,FIRE,PROT}.cpp`, `lua/LuaElements.cpp`. No game/simulation was launched or
modified; no files other than this deliverable were written.
