# Multiplayer architecture research (2026-08-29)

Ask (Drew, reinforced): "build with each other" -- co-op building AND the
existing RPG survival gameplay together, not a separate creative-only mode.
companion.lua's header has referenced a `design-multiplayer.md` doc since
the companion protocol was built ("how a second human could drive this same
action layer later") -- that file never actually existed until now. This is
real research, not another "needs design" flag.

## Why this is genuinely hard here, specifically

This engine is ONE continuous TPT particle simulation (up to hundreds of
thousands of live cells: sand, water, gas, fire, all interacting). Real
multiplayer for a falling-sand/pixel-physics sim has a well-known hard
problem that doesn't exist for tile-based or entity-based games: the
simulation is chaotic and iteration-order-dependent. Two machines running
the "same" physics step on the same data can diverge within a few ticks from
float rounding and update-order differences alone -- classic peer-to-peer
lockstep (each client simulates locally, only inputs are network) does NOT
work for this class of sim without exhaustive, expensive determinism
engineering (fixed-point math, fixed update order, etc, and even then it's
fragile). This is not a guess -- it's *why* real precedent below avoids it.

## Real prior art (the two closest analogs, actually researched, not assumed)

**Noita Together** (community mod for Noita, the closest real commercial
analog to this engine -- also a from-scratch falling-sand physics game):
deliberately did NOT attempt shared-simulation multiplayer. Each player
keeps their own separate world/dimension; players can see each other and
share some resources, but nobody edits the same live sand simulation.
[Noita Together wiki](https://noita.wiki.gg/wiki/Mod:Noita_Together) /
[GitHub](https://github.com/Noita-Together/noita-together). This is the
"easy, ships today" end of the spectrum -- but it does NOT satisfy Drew's
ask, since it's not really shared building or shared survival, just shared
presence.

**Noita Entangled Worlds** (the mod that DOES attempt real world sync): the
README confirms it syncs "pixels of the grid world" along with players,
items, and enemies, and its install docs mention a "Proxy" component,
implying one relay/authority point rather than pure peer-to-peer.
[GitHub](https://github.com/IntQuant/noita_entangled_worlds). Public
technical writeups on the exact conflict-resolution algorithm aren't
published, but the shape (a proxy + syncing pixel deltas) matches the
standard, well-understood answer to this class of problem: **host-
authoritative simulation, clients as thin views**.

## Recommended approach for this codebase

Host-authoritative, not peer-to-peer, not full lockstep:

1. One machine (the host) runs the REAL simulation, exactly as it does
   today -- zero changes to sim/physics code.
2. Other players connect as clients. A client sends only INPUT (movement,
   tool use, block placement intent) to the host, never simulates physics
   itself.
3. The host applies inputs through the existing player-action code
   (movePlayer/useTool/placeAt already exist and already work -- a second
   player is just a second instance of the same P-like state table, driven
   by network input instead of local mouse/keyboard).
4. The host streams back only what changed (a bounded region around each
   client's camera, not the whole world) -- this is the same "windowed"
   approach the existing tile-cache/shiftCam system already uses for
   scrolling, which is a real, reusable precedent already in this codebase
   (rung 2 of the ladder: don't invent a new windowing scheme, the camera
   system already has one).
5. This is genuinely the same shape as companion.lua's existing action-layer
   design (R.companionCmd et al already separate "decide what to do" from
   "execute the action") -- a second human's inputs can drive the exact same
   actor-command interface a second companion or a Python driver already
   uses. That's real, existing, reusable infrastructure, not a new system.

## What's explicitly OUT of scope for any V1

- Client-side prediction/rollback (needed for low-latency responsiveness,
  but is its own substantial project on top of the host-authoritative base
  above -- V1 accepts host-latency lag on remote inputs).
- More than 2 players (host + 1 remote) -- validate the architecture at the
  smallest real case first.
- Persistent dedicated server (host is just whichever player started the
  world, matching how Noita Together/Entangled Worlds both work).

## What has to be decided before ANY code starts

1. Transport: LAN-only (simplest, no NAT/relay problem) vs internet play
   (needs a relay/proxy, real infra work). Recommend LAN-only for V1 given
   the "Proxy" complexity even Entangled Worlds needed for internet play.
2. Does a remote client run its own copy of the game binary (almost
   certainly yes -- there's no thin-client version of this engine) --
   meaning the "client" here is really "a second full TPT instance that
   defers its own physics to network state," which is a bigger client-side
   change than it sounds like at first (need to confirm the local sim
   doesn't fight the host's incoming state).
3. Whether Drew wants this LAN-only friends-and-family feature or something
   closer to a public server browser -- completely different infra scope.
