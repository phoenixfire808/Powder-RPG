# Ragdoll physics + gore/dismemberment research (2026-08-29)

Ask (Drew, concrete reference given): "Happy Wheels" style -- real
ragdoll/joint physics driving movement, not a static sprite, bigger
player/companion, real gore/dismemberment (limbs tear off, decapitation).

## The standard, well-established technique (not invented here)

Verlet integration + distance ("stick") constraints. This is the actual
technique Happy Wheels and most 2D ragdoll games use, going back to Thomas
Jakobsen's paper for Hitman: Codename 47 (one of the first games with real
ragdoll physics), also used in Source engine ragdolls. Overview:
[Tuts+ verlet ragdoll tutorial](https://gamedevelopment.tutsplus.com/tutorials/simulate-tearable-cloth-and-ragdolls-with-simple-verlet-integration--gamedev-519),
background on the method: [Game Dev Mechanics: Verlet Integration](https://moonjump.com/game-dev-mechanics-verlet-integration-how-it-works/).

**How it works, concretely:**
- The body is a small set of point masses (head, chest, pelvis, 2x upper
  arm, 2x forearm, 2x thigh, 2x shin -- ~11 points for a simple skeleton).
  Each point stores current position + previous position (Verlet needs no
  explicit velocity -- velocity is implicit as `pos - prevPos`, which is
  simpler to reason about than a spring/force system).
- Points are connected by distance constraints ("sticks"): each stick
  remembers its rest length and pulls its two points back toward that
  distance every physics step. A few iterations of constraint relaxation
  per frame (4-8 is typical) is enough to look convincingly rigid.
- Rigid areas (chest/pelvis/head) get MORE sticks between them (a small
  triangle/quad of constraints, not just one), so they don't fold; loose
  areas (elbows, knees) get exactly one stick so they swing freely -- this
  single knob (how many constraints per joint) is what tunes "floppy" vs
  "stiff" per body part, referenced directly in the tutorial above.
- Collision with the world: each point mass does the exact same solidW-style
  collision check the player already does today, just once per point instead
  of once for the whole player box. Reuses existing collision code, not new.

## Dismemberment (the part Drew specifically wants and generic ragdoll
tutorials don't cover -- this part IS specific reasoning, not copied)

Standard technique used by Happy Wheels and similar games: dismemberment is
just a CONDITIONAL CONSTRAINT BREAK, nothing more exotic.
- Each stick constraint gets a `breakForce` (how much it can be stretched
  beyond its rest length before failing).
- Every physics step, after relaxing constraints, check how far each stick
  is from its rest length. If a hit/impact (fall damage, an enemy attack,
  an explosion) pushes two connected points further apart than
  `breakForce` allows, that ONE stick is simply removed from the constraint
  list for the rest of the ragdoll's life.
- Once a stick is gone, the two sides are no longer connected -- the limb
  drifts away under its own existing Verlet motion (it's still simulated,
  just no longer pulled back). This IS the "limb tears off" effect, and it
  costs nothing extra: no special-case code path, just "this constraint no
  longer exists."
- Decapitation is the neck stick breaking; it's the same mechanism as any
  other joint, not a special case.
- Blood/gore particles (already exist this session -- BLD element) spawn at
  the break point when a stick fails, reusing existing infrastructure.

## What this actually requires from THIS engine specifically

- The player is currently a single sprite driven by one position + velocity
  (P.x/P.y/P.vx/P.vy in rpg.lua). Ragdoll mode needs ~11 independent point
  masses instead, each doing its own collision check against solidW. This
  is a real, substantial rewrite of player movement, not a bolt-on --
  normal walking/running would need to EITHER (a) stay as the current
  simple sprite model with ragdoll only kicking in on death/heavy impact
  (recommended -- see below), or (b) become fully ragdoll-driven at all
  times (much more expensive, likely too slow/floppy-looking for normal
  platforming control, and fighting against precise player control is
  a known problem with always-on ragdoll movement in other games).
- Companion.lua would need the identical treatment separately (it already
  duplicates the player's whole physics constant set per the gravity/speed
  desync bug found this session -- a ragdoll system should NOT be built
  twice; if this goes ahead, it's the moment to unify player/companion
  physics into one shared module instead of copy-pasting a second time).

## Recommended V1 cut

**Ragdoll ONLY on death/heavy impact, not full-time movement control.**
Normal walking/running/jumping stays exactly as it is today (the current
sprite+velocity model already works and feels responsive -- there's real
risk in replacing it wholesale). On death (or optionally a hard fall/heavy
hit), spawn an ~11-point Verlet ragdoll at the player's current pose,
disable normal movement control, let physics take over, and let sticks
break under sufficient force for gore. Respawn resets back to normal sprite
control. This gets the "Happy Wheels" money-shot (dramatic physical death)
without touching the movement feel Drew hasn't complained about.

**Explicitly OUT of V1:** full-time ragdoll-driven walking (real risk of
making basic movement feel bad, and a much bigger rewrite), a proper
skeletal/inverse-kinematics rig, organs as separate simulated bodies
(spawn as particle effects/decals at death instead -- much cheaper, same
visual payoff for "full of organs").

## What has to be decided before code starts

1. Confirm the V1 cut above (death-only ragdoll) is actually what Drew
   wants, versus always-on ragdoll movement -- these are very different
   scopes and the ask ("driving movement, not just a static sprite") could
   be read either way.
2. Bigger player/companion sprite size -- unrelated to ragdoll itself, a
   separate, much smaller, already-scoped visual change that shouldn't
   block on this.
