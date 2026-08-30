# Colonist core: audit and redesign

Audit of `scripts/lua/rpg_plugins/companion.lua` after Drew's 21:06 feedback: "he's just spamming, handing me
random shit… analyse this whole logic, his whole core and how he should work… empower the local model to act
intelligently based on what I want — cut all these trees, dig me a big hole, build me a really cool house —
dynamically, not pre-made stuff."

## 1. What is actually wrong today

| Problem | Where | Why it feels bad |
|---|---|---|
| **Item spam** | `scriptedBrainTick`: within 30px and every 60 frames it iterates `C.inv` and does `give` + `sayC("Here's your X.")` for the first item found | Fires every ~1.6s, one line each, for anything he happens to hold. This is the "spamming random shit". |
| **One-shot commands only** | `C_cmd(name, args)` sets a single `C.action`; `C.enqueueChain` exists but nothing builds real plans | He cannot carry out anything that takes more than one primitive, so "cut all these trees" is impossible. |
| **No spatial tasks** | every command targets a point or a nearest-match | No concept of an *area* ("this patch of forest", "a 20x14 hole here", "a house there"). |
| **No construction** | `place` puts one block | "Build me a house" has nothing to call. |
| **Templated speech** | `templateReply` answers chat | Drew explicitly does not want canned lines; the model must speak. |
| **Reactive-only brain** | throttled if/else ladder | No goal memory, no re-planning, no reporting. |

## 2. The core he should have

```
player intent (chat)  ─┐
world/self state ──────┼─▶ BRAIN (3B model, ~1 call/2-4s) ─▶ PLAN (ordered steps, JSON)
current goal/quest ────┘                                        │
                                                                ▼
                                                     TASK QUEUE (C.plan)
                                                                │
                                            ┌───────────────────┼────────────────────┐
                                            ▼                   ▼                    ▼
                                     PRIMITIVES          AREA TASKS            BUILD TASKS
                                 goto/mine/chop/place   clearTrees(area)     buildRoom(spec)
                                 craft/give/light/fight  digArea(area)        buildShaft(spec)
                                            └───────────────────┬────────────────────┘
                                                                ▼
                                                    LOCOMOTION (R.findPath A*)
                                                    + stuck recovery (repath→jump→dig)
                                                                ▼
                                                         REFLEXES (always on)
                                              danger, drowning, falling, being hit, low air
```

**Rules**
- The **model** decides *what* and *why*, and speaks. The **scripted layer** decides *how* and guarantees the body
  never gets stuck. Reflexes can interrupt anything; a plan resumes afterwards.
- Every plan step reports `running / done / failed(reason)`. On failure the brain re-plans once with the reason
  in context, then tells the player plainly if it still cannot.
- One short spoken line per meaningful event (plan accepted, milestone, blocked, finished). Never per tick.

## 3. Fixes to the giving behaviour

Replace the auto-give loop with a **delivery rule**:
- Hand over only when: the player asked; **or** the player is short of a material the *current goal or a craft they
  just attempted* needs; **or** his pack is over ~80% full and the player is within a few tiles.
- Batch everything owed into **one** delivery with **one** line ("Brought you 24 granite and 9 coal").
- Cooldown measured in minutes, not seconds; never repeat a delivery line for the same item within that window.
- Silent by default while he is simply working nearby.

## 4. Area and build tasks (what makes "do what I want" possible)

Parametric, not prefab. The model supplies parameters; the code generates the work.

- `clearTrees{ x1, y1, x2, y2 }` — find trunk bases in the rect, fell each in turn (core `R.fellFrom` / chop),
  haul the wood, report count. "Cut all these trees" = this with the player's view rect.
- `digArea{ x1, y1, x2, y2, keepWalls=bool }` — mine every cell in the rect in a sensible order (top-down,
  nearest-first), skipping blocks above his pick tier, dumping spoil, reporting progress by percentage.
  "Dig me a big hole" = this.
- `buildRoom{ x, y, w, h, material, door=side, floor=bool, roof="flat|peak", windows=n, torches=n, bed=bool }`
  — generate the wall/floor/roof cell list, clear the interior, place from inventory (ask for what is missing),
  and light it. "Build me a really cool house" = one or more of these, composed: the brain picks size, material,
  and features from what is available, and can chain rooms, a doorway, and a chimney.
- `buildShaft{ x, y, depth, ladder=bool, torchEvery=n }` — a proper mine entrance.
- `wall{ x1, y1, x2, y2, material }`, `bridge{ x1, x2, y, material }`, `stairs{ x, y, w, h, dir }`.

Each build task must: validate materials first (and say what is missing), place blocks in a stable order
(bottom-up for walls), never seal the player in, and stop cleanly when interrupted.

## 5. Model contract

One JSON object per decision:

```json
{"say": "On it - clearing the trees along the ridge",
 "plan": [
   {"cmd": "clearTrees", "args": {"x1": -120, "y1": 40, "x2": 60, "y2": 120}},
   {"cmd": "give", "args": {"item": "WOOD"}}
 ]}
```

- `say` ≤ 100 chars, in character, never invented facts.
- `plan` is 1–6 steps; unknown commands or out-of-range coordinates are rejected and re-asked once.
- Context given to the model: colonist state, player state, inventory both sides, `C.index` (nearby ore with
  directions, structures, hazards), current quest and what it still needs, the last few chat lines, and the
  outcome of the previous plan.
- If the model is unavailable, the scripted layer keeps him useful and *quiet* — following, defending, and
  finishing the current plan — not chatting.

## 6. Acceptance tests (lab instance)

1. Stand still with him holding 5 item types for 60s → **zero** unsolicited gives, **zero** chat lines.
2. "cut all these trees" with 4 trees on screen → all 4 fall, wood delivered in one batch, one summary line.
3. "dig me a big hole here" → a rectangular pit appears, progress reported once or twice, no spam.
4. "build me a house" with materials → a room with walls, floor, roof, a door gap, and torches; missing
   materials are named up front.
5. Drop him in a sealed pit → out within a few seconds using `R.findPath` with dig enabled.
6. Kill the model server mid-plan → he finishes the current plan and stays quiet; no template chatter.
