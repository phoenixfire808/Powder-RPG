# Colonist model protocol

The colonist (`scripts/lua/rpg_plugins/companion.lua` + `scripts/companion_driver.py`) is fully playable
and fully conversational with **no model at all** - the scripted brain (follow/self-defense reflexes) and
`templateReply`'s chat fallback cover that. A local model is an optional layer that only ever proposes
*what* to do and *what to say*; the Lua side always decides *how* (pathing, physics, safety).

## Architecture

```
player intent (Enter-chat)  ─┐
world/self state ────────────┼─▶ companion_driver.py ─▶ Qwen2.5 3B (LM Studio/Ollama) ─▶ strict JSON
current goal/quest ──────────┘                                                              │
                                                                                             ▼
                                                                                    validate + clamp
                                                                                             │
                                                                                             ▼
                                                                          R.companionCmd / R.companionEnqueue
                                                                                             │
                                                                                             ▼
                                                                    STEP.* primitives (companion.lua) - the
                                                                    ONLY place that touches physics/pathing
```

## Reading state: `R.companionState()`

Called from Lua directly (`PBX.state.rpg.companionState()`); the Python driver's `get_state()` fetches it
as JSON over the bridge. Kept small on purpose (well under a KB):

```json
{
  "active": true, "dead": false, "hp": 60, "maxhp": 60,
  "x": 120, "y": 340, "depth": 12, "biome": "forest",
  "inv": [{"item": "WOOD", "n": 4}],
  "action": {"name": "follow", "status": "running", "from": "scripted"},
  "player": {"x": 116, "y": 340, "hp": 100, "o2": 92, "hurtRecently": false},
  "quest": "Craft a wood pick by hand (E > craft)",
  "nearby": [{"el": "STNE", "n": 12}, {"el": "COAL", "n": 3}],
  "chat": [{"who": "You", "text": "follow me"}],
  "day": 3, "frame": 88210
}
```

`R.companionIndex()` (also folded into the state above where relevant) additionally exposes
`resources` (nearby ore + rough direction), `stations`/`machines`, `questMissing`/`questRecipe` (concrete
ingredient shortfall for the current quest, when it maps to a real recipe), `o2`/`gas`, `recentMine`/
`recentCraft` (what the player just did). This is the colonist's "index of the environment" - read-only,
refreshed every ~4s, never guessed at.

For deeper factual questions ("what does a turbine need", "how do I stop the CO"), core's actor/knowledge
tables are the source of truth and must never be invented from: `R.RECIPES`, `R.NAMES`/`R.nice`,
`R.MINEABLE`/`R.HARD`, `R.ACCS`, `R.STATIONS`, `R.QUESTS`, `R.biomeInfo`/`R.depthInfo`, `R.gas`. `R.CAPS`
lists the actor framework's own verb set (`senseRect`/`senseNearest`/`senseColumn`/`senseSelf`,
`actorMine`/`actorPlace`/`actorFill`/`actorClear`/`actorCraft`/`actorGive`/`actorLight`) - feed it to the
model as its available tool list if you want it reasoning about the world in those terms directly.

## The model contract

**Exactly one JSON object, nothing else:**

```json
{"say": "On it - grabbing that iron", "cmd": "mine", "args": {"element": "IRON"}}
```
or a short plan (1-6 steps, executed in order, stops on the first failure):
```json
{"say": "Building the wall now",
 "plan": [
   {"cmd": "buildWall", "args": {"x1": 100, "y1": 320, "x2": 100, "y2": 340, "material": "STNE"}},
   {"cmd": "give", "args": {"item": "STNE"}}
 ]}
```
or a pure chat reply with no action at all (just omit `cmd`/`plan`).

Rules the driver enforces before anything reaches the game (`companion_driver.py: validate_decision`):
- `say` is optional, truncated to 100 chars.
- `cmd` must be one of `ALLOWED_CMDS` (mirrors `STEP.*` in companion.lua) - anything else is dropped.
- Every `x`/`y`/`x1`/`y1`/`x2`/`y2` argument is clamped to within 320px of the player's current position -
  the model cannot send the colonist to the other side of the world by mistake.
- A `plan` is capped at 6 steps.
- Malformed JSON, an unreachable model, or a timeout all mean the driver does **nothing** that cycle - the
  scripted brain and (if the player just spoke) the template fallback are what the player actually sees.

## Command set (`STEP.*` in companion.lua)

`follow`, `stay`, `say{text}`, `goto{x,y}`, `mine{x,y}` / `mineNearest{element}`, `chop{element?}`,
`fetch{item,n}` (mine until `n` collected), `place{element,x,y}`, `craft{recipe}`, `give{item,n?}` (n
omitted = give everything of that item), `take{item,n?}`, `fight{}` (nearest threat), `light{x,y}`,
`buildWall`/`build{x1,y1,x2,y2,material}`, `bridge{x1,x2,y,material}`, `stairs{x,y,w,h,dir,material}`,
`clearTrees{x1,y1,x2,y2}`, `digArea{x1,y1,x2,y2,keepWalls?}`,
`buildRoom{x,y,w,h,material,door?,floor?,torches?}`, `buildShaft{x,y,depth,torchEvery?}`.

Every primitive routes through core's shared actor framework (`R.actorMine`/`actorPlace`/`actorFill`/
`actorClear`/`actorCraft`/`actorGive`/`actorLight`) so it respects real pick tiers, credits the colonist's
own inventory, and never overwrites something already there. Locomotion is `R.findPath` (A*, walk/step-up/
jump/drop, optional dig) with a stuck-escalation ladder (repath-with-dig -> jump -> dig straight up) so the
colonist cannot get permanently trapped.

## Non-negotiable behaviour rules (Drew, 21:12/21:16)

1. **Only do what he asked.** No self-directed mining, no unsolicited gifts, no wandering off. Between
   real requests the colonist follows and stays quiet - this applies to the scripted brain too, not just
   the model.
2. **He can be asked anything about the game**, answered from the real tables above - never invented. If
   the answer isn't knowable from state, he says so and offers to go look.
3. **No canned chatter.** The model speaks; when it's unavailable or stalls (a heartbeat watchdog in
   companion.lua reverts `C.mode` to `"auto"` after ~10s of silence from the driver), the colonist stays
   useful and quiet rather than falling back to a wall of scripted flavor text.

## Running it

```
python scripts/companion_driver.py --lab      # develop against the lab instance (port 9877)
python scripts/companion_driver.py            # Drew's live game, once the model side is proven in the lab
```

Auto-detects LM Studio (`http://localhost:1234/v1`) or Ollama (`http://localhost:11434`); never downloads
a model itself. If neither is reachable it prints what to install and exits - the colonist is unaffected,
since none of this is required for him to work.
