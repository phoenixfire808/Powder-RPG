# Powder Bridge Extension — User Guide

This is the guide for *using* the Powder Bridge extension: the person or
external tooling calling the 15 automation tools, not the person implementing them. If you
want the binding contract between the Lua and Python modules, read
`EXTENSION_SPEC.md` instead — this document assumes that contract already
holds and tells you what it lets you do.

## What this gives you

The Powder Bridge extension lets you define brand-new Powder Toy elements at
runtime — with their own colour, physical properties, temperature behaviour,
and an attached "behaviour kind" like glower/decayer/emitter/conductor — and
spin up colonies of autonomous worker creatures that wander the sandbox,
carry material, and build structures out of blocks you assign them, all
without rebuilding or restarting `powder.exe`. Everything is exposed as scriptable
tools you call the same way you'd call any other tool in this project: you
describe what you want (an element's properties, a colony's nest location, a
task like "build a box of BRCK from (10,10) to (40,30)"), the extension does
the work inside the running simulation, and you poll for progress until it's
done.

## The 15 automation tools

There are four groups. Every example below shows a plausible call and a
plausible response shape; field names come from `EXTENSION_SPEC.md` sections
4 and 5. In practice a response may carry a couple of extra bookkeeping
fields (`tool`, `job`, `status`, `polls`, `correlation_id`) reflecting the
job protocol described in the next section — the fields shown here are the
ones the spec guarantees.

### Element lifecycle

**`define_element`** — create or redefine a custom element. Idempotent on
`name`: calling it again with the same name updates the element in place
instead of allocating a second one.

```json
{
  "tool": "define_element",
  "arguments": {
    "name": "WKR1",
    "group": "PBX",
    "description": "A small worker creature that carries material and builds.",
    "colour": "0xCC8833",
    "menuSection": "PBX",
    "type": "SOLID",
    "properties": ["PROP_LIFE_DEC"],
    "temperature": 296,
    "hardness": 5,
    "weight": 40,
    "gravity": 0,
    "diffusion": 0,
    "flammable": 0,
    "explosive": 0,
    "heatConduct": 0,
    "behavior": { "kind": "creature" }
  }
}
```

```json
{
  "ok": true,
  "tool": "define_element",
  "id": 268,
  "identifier": "PBX_PT_WKR1",
  "created": true
}
```

**`list_custom_elements`** — no arguments. Returns every custom element ever
defined, with its live numeric id, so you can check what already exists
before defining more (and so you don't blow through `MAX_CUSTOM_ELEMENTS`
without noticing).

```json
{ "tool": "list_custom_elements", "arguments": {} }
```

```json
{
  "ok": true,
  "tool": "list_custom_elements",
  "elements": [
    { "name": "WKR1", "id": 268, "type": "SOLID", "behavior": { "kind": "creature" } }
  ]
}
```

**`update_element`** — change a subset of an existing element's fields
in place, keeping its id and name.

```json
{
  "tool": "update_element",
  "arguments": { "name": "WKR1", "colour": "0xAA6622", "weight": 55 }
}
```

```json
{ "ok": true, "tool": "update_element", "id": 268, "changed": ["colour", "weight"] }
```

**`delete_custom_element`** — remove a custom element and free its slot
under `MAX_CUSTOM_ELEMENTS`.

```json
{ "tool": "delete_custom_element", "arguments": { "name": "WKR1" } }
```

```json
{ "ok": true, "tool": "delete_custom_element", "freed": true }
```

### Colony lifecycle

**`colony_create`** — create a new colony with a nest location and tint.

```json
{
  "tool": "colony_create",
  "arguments": { "name": "east-camp", "nestX": 40, "nestY": 20, "colour": "0xFFCC8833", "pheromoneDecay": 0.02 }
}
```

```json
{ "ok": true, "tool": "colony_create", "colonyId": 1 }
```

**`colony_list`** — no arguments. Every active colony with its id.

```json
{ "tool": "colony_list", "arguments": {} }
```

```json
{ "ok": true, "tool": "colony_list", "colonies": [{ "colonyId": 1, "name": "east-camp", "workers": 40 }] }
```

**`colony_status`** — one colony's full picture: worker/alive counts, what
they're carrying, the material store, active tasks, nest location, and
pheromone peak. This is the tool you poll repeatedly while watching a
colony work.

```json
{ "tool": "colony_status", "arguments": { "colonyId": 1 } }
```

```json
{
  "ok": true,
  "tool": "colony_status",
  "workers": 40,
  "alive": 39,
  "carrying": 6,
  "store": { "BRCK": 120 },
  "tasks": [{ "taskId": 3, "kind": "buildBox", "done": 44, "total": 120 }],
  "nest": { "x": 40, "y": 20 },
  "pheromonePeak": 0.87
}
```

**`colony_destroy`** — tear down a colony, optionally killing its workers,
freeing a slot under `MAX_COLONIES`.

```json
{ "tool": "colony_destroy", "arguments": { "colonyId": 1, "killWorkers": true } }
```

```json
{ "ok": true, "tool": "colony_destroy", "destroyed": true }
```

### Workers

**`spawn_workers`** — populate a colony with worker creatures at a pixel
location, with random scatter.

```json
{
  "tool": "spawn_workers",
  "arguments": { "colonyId": 1, "count": 40, "x": 40, "y": 20, "spread": 8 }
}
```

```json
{ "ok": true, "tool": "spawn_workers", "spawned": 40, "total": 40 }
```

**`kill_workers`** — shrink a colony or clear it out without destroying the
colony record itself. Omit `count` to kill every worker.

```json
{ "tool": "kill_workers", "arguments": { "colonyId": 1, "count": 10 } }
```

```json
{ "ok": true, "tool": "kill_workers", "killed": 10 }
```

### Tasks

**`assign_task`** — give a colony's workers autonomous work. `kind` is one
of `gather`, `dig`, `buildLine`, `buildBox`, `buildCircle`, `buildBlueprint`,
`patrol`, and each kind has its own `params` shape (see the worked example
below and spec section 4.5 for the full table).

```json
{
  "tool": "assign_task",
  "arguments": {
    "colonyId": 1,
    "kind": "buildBox",
    "params": { "element": "BRCK", "x1": 10, "y1": 60, "x2": 90, "y2": 100, "filled": false, "source": "spawn" },
    "priority": 5
  }
}
```

```json
{ "ok": true, "tool": "assign_task", "taskId": 3 }
```

**`task_status`** — poll one task (`taskId`) or every task in a colony
(omit it) for `progress`/`claimed`/`done`/`total`.

```json
{ "tool": "task_status", "arguments": { "colonyId": 1, "taskId": 3 } }
```

```json
{
  "ok": true,
  "tool": "task_status",
  "tasks": [{ "taskId": 3, "progress": 0.55, "claimed": 12, "done": 66, "total": 120 }]
}
```

**`cancel_task`** — stop an in-progress task and release its workers'
claims on any blueprint cells they'd staked out.

```json
{ "tool": "cancel_task", "arguments": { "colonyId": 1, "taskId": 3 } }
```

```json
{ "ok": true, "tool": "cancel_task", "cancelled": true }
```

### Diagnostics

**`extension_status`** — no arguments. A liveness check: which bridge
modules loaded, their versions and error counts, the current tick index,
job queue depth, and how many custom elements/colonies/workers exist right
now.

```json
{ "tool": "extension_status", "arguments": {} }
```

```json
{
  "ok": true,
  "tool": "extension_status",
  "modules": [
    { "name": "registry", "version": "1.0.0", "actions": 4, "errors": 0 },
    { "name": "colony", "version": "1.0.0", "actions": 4, "errors": 0 }
  ],
  "tickIndex": 184213,
  "jobQueue": 0,
  "hasTmp34": true,
  "customElementCount": 1,
  "colonyCount": 1,
  "workerCount": 40
}
```

**`extension_self_test`** — runs the bridge's own built-in checks
(`deep: true` runs deeper ones) without permanently mutating the sim. Good
for "is the extension actually working" before you start building.

```json
{ "tool": "extension_self_test", "arguments": { "deep": false } }
```

```json
{
  "ok": true,
  "tool": "extension_self_test",
  "checks": [
    { "name": "registry.actions_registered", "ok": true, "detail": "4/4" },
    { "name": "colony.pheromone_grid_allocated", "ok": true, "detail": "153x96" }
  ]
}
```

## The asynchronous job model

Some of these calls have to touch a lot of particles — allocating a new
element, spawning 40 workers, killing them, laying down a blueprint of
building material. TPT will not let that kind of work run on the same
thread that answers your HTTP request (`AssertMutableToolsEvent` — see
spec section 2.4), so the bridge queues it instead and only actually runs it
on the *next simulation tick*. The tool you called then has to wait for that
tick to happen and the job to finish before it can answer you.

In the common case this is invisible: the Python side of the extension
polls the bridge's internal job status a few times, a few tick durations
pass (milliseconds to low seconds of wall-clock time), and you get back one
normal, settled response — exactly the shapes shown above. You do not
normally need to know a job was ever involved.

**The one thing that will trip you up**: jobs only drain while
`event.TICK` is firing, which only happens while the simulation is
*running*. If the simulation is paused — or the tick pump has stalled for
some other reason — a job you queued sits forever, and the tool call that's
waiting on it will look like it's hanging (in practice it eventually times
out and comes back with something like `{"ok": false, "status": "pending",
"job": 7, "hint": "job did not settle... the simulation may be paused"}`
rather than hanging forever, but from your side it reads as "this call is
suspiciously slow and then fails oddly").

If you see that shape of response:

1. Check `extension_status.tickIndex` twice, a moment apart. If it isn't
   increasing, the simulation is paused (or the tick pump is dead) and
   nothing queued will ever complete until that's fixed.
2. Once ticks are flowing again, simply retry the original call (or, for
   `define_element`, calling it again with the same `name` is safe — it's
   idempotent).

Everything else about these tools behaves like a normal synchronous call;
this is the only place "async" surfaces at the automation layer.

## End-to-end walkthrough

A complete run: define a worker element, stand up a colony with a nest,
spawn 40 workers, tell them to build a box, and watch it finish.

**1. Define the worker element.**

```json
{
  "tool": "define_element",
  "arguments": {
    "name": "WKR1",
    "description": "Colony worker creature.",
    "colour": "0xCC8833",
    "type": "SOLID",
    "behavior": { "kind": "creature" }
  }
}
```
```json
{ "ok": true, "tool": "define_element", "id": 268, "identifier": "PBX_PT_WKR1", "created": true }
```

**2. Create the colony with a nest.**

```json
{
  "tool": "colony_create",
  "arguments": { "name": "east-camp", "nestX": 40, "nestY": 20, "colour": "0xFFCC8833", "pheromoneDecay": 0.02 }
}
```
```json
{ "ok": true, "tool": "colony_create", "colonyId": 1 }
```

**3. Spawn 40 workers at the nest.**

```json
{ "tool": "spawn_workers", "arguments": { "colonyId": 1, "count": 40, "x": 40, "y": 20, "spread": 8 } }
```
```json
{ "ok": true, "tool": "spawn_workers", "spawned": 40, "total": 40 }
```

**4. Assign a `buildBox` task.**

```json
{
  "tool": "assign_task",
  "arguments": {
    "colonyId": 1,
    "kind": "buildBox",
    "params": { "element": "BRCK", "x1": 10, "y1": 60, "x2": 90, "y2": 100, "filled": false, "source": "spawn" },
    "priority": 5
  }
}
```
```json
{ "ok": true, "tool": "assign_task", "taskId": 3 }
```

**5. Poll `task_status` until it's done.**

```json
{ "tool": "task_status", "arguments": { "colonyId": 1, "taskId": 3 } }
```
```json
{ "ok": true, "tool": "task_status", "tasks": [{ "taskId": 3, "progress": 0.31, "claimed": 9, "done": 37, "total": 120 }] }
```

Call it again a few seconds later (the simulation must be running — see
above); repeat until you see `"done": 120, "total": 120"`. If `colony_status`
shows a `blocked` reason on this task instead of rising progress, see
Troubleshooting below.

## Hard caps

These are enforced by the bridge (`00_util.lua`) and cannot be exceeded by
any tool, no matter what you pass:

| cap | value | hit when |
|---|---|---|
| workers per colony | 400 | `spawn_workers` returns fewer than requested (`spawned < count`); the response still reports what it actually managed |
| colonies | 8 | `colony_create` fails rather than silently reusing a slot |
| tasks per colony | 16 | `assign_task` fails; cancel or let an existing task finish first |
| blueprint cells | 4096 | `assign_task` with `kind: "buildBlueprint"` is rejected outright — cells are never silently truncated — split into multiple tasks instead |
| custom elements | 24 | `define_element` fails; `delete_custom_element` an unused one first |

## Troubleshooting

**Nothing happens after I call a tool.** The simulation is very likely
paused, or its tick pump has stalled. Call `extension_status` twice a
moment apart and compare `tickIndex` — if it isn't moving, nothing queued
(spawns, kills, element definitions, blueprint placements) will ever
complete until the simulation is running again. This is the single most
common cause of "the extension looks broken."

**Workers exist but are sitting idle.** Check `colony_status` or
`task_status` for that colony. Workers idle (state `0 IDLE`, spec section
3) either have no task assigned at all, or their task is `blocked` — most
commonly a `gather` task blocked because its region has none of the target
element left, or a `source: "store"` build task blocked because the
colony's material store is empty for that element. Either assign a task,
switch a build task to `source: "spawn"` if you don't need gathered
material specifically, or point a `gather` task at a region that actually
has the element.

**A build task's progress has stalled, not finished.** Workers claim a
blueprint cell before working it (`tmp4`, spec section 3) so two workers
never fight over the same cell; if a worker dies mid-claim (starved,
crushed, etc.) that cell's claim can go stale. The bridge sweeps for stale
claims (an owning particle that no longer exists) every 60 ticks and
releases them, so a genuinely stalled task should resume progress within
about a second of simulated time once ticks are flowing — if it doesn't,
suspect the simulation is paused (see above) rather than a permanently
stuck claim.

**`define_element` (or `update_element`) fails.** Check, in order: `name`
is 1-4 characters, `A-Z0-9` only, no underscore; `MAX_CUSTOM_ELEMENTS` (24)
hasn't been reached — call `list_custom_elements` to check and
`delete_custom_element` to free a slot; every string in `properties` is a
real TPT property flag name (e.g. `PROP_CONDUCTS`, not a made-up one); and
`behavior.kind` is one of the eight registered kinds (`inert`, `glower`,
`decayer`, `emitter`, `grower`, `pheromone`, `conductor`, `creature`) — an
unknown kind name is rejected rather than silently falling back to `inert`.

## Adding a new behaviour kind

Behaviours live in `bridge_src/20_behaviors.lua`, which publishes
`PBX.state.behaviors.kinds` — a table mapping a kind name to
`{ params = {name = {type, min, max, default}}, make = function(params)
return updateFn end }`. `10_registry.lua` looks up
`PBX.state.behaviors.kinds[kind].make(params)` when `define_element` runs
and installs the returned function as the element's `Update` via
`elements.property(id, "Update", fn)`.

To add a ninth kind: add an entry to that `kinds` table following the same
shape as the eight required ones (`inert`, `glower`, `decayer`, `emitter`,
`grower`, `pheromone`, `conductor`, `creature`), declare its tunable
`params` with type/min/max/default so `define_element`'s `behavior.params`
can validate against them, and return an `updateFn` with the same signature
TPT expects for an element's `Update` property. No other module needs to
change — `define_element` already resolves `behavior.kind` generically
through this table, so a new kind becomes usable immediately once it's
registered here. Wrap the body of your `updateFn` in `PBX.guard(module, fn)`
(see `00_util.lua`) so a bug in your new behaviour can't escape into TPT's
per-particle Update loop and stall the simulation.
