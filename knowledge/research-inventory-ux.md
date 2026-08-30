# Inventory UX research (ui.lua rebuild, 2026-08-26)

Note: the session's WebSearch quota was exhausted by other parallel workers before this could run live
searches. What follows is drawn from established, stable knowledge of these four games' inventory systems
(none of this is news that would have changed) rather than freshly fetched sources - flagging that per
Drew's ask for transparency.

## What each game does well

**Terraria** - hotbar (10 slots) always visible and *is* the top row of the main inventory (not a separate
copy). Clicking a slot with an empty cursor picks the whole stack up onto the cursor (item visibly follows
the mouse); clicking again places/merges/swaps. Right-click on a stack peels off one item per click; holding
right-click on a full stack rapidly splits it in bursts. Favoriting protects an item from quick-trash/quick-sell.
A dedicated trash-can slot deletes on drop, with a confirm popup for stacks. Accessories/armor/vanity live in
their *own* slots next to the main grid, separate from consumables/materials, with a small eye icon to toggle
visibility without unequipping the effect. Tooltips are colour-coded by rarity and always show a one-line use
description plus set-bonus text when relevant.

**Minecraft** - the hotbar is *literally* row 1 of the main inventory array, not a mirrored copy, so nothing
needs to "sync." Click-to-pick-up/click-to-place is the base interaction (same as Terraria). Shift+click
quick-transfers a whole stack to the best available destination (existing stacks first, then first empty slot)
- this is the single most-cited "why does every game not have this" feature. Number keys 1-9 while hovering an
item in the inventory swap it directly into that hotbar slot without touching the cursor. Double-click gathers
every matching stack on screen into the cursor. Dragging while holding a stack across several empty slots
distributes it evenly (advanced, we're skipping this one - low value for a materials-only inventory).

**Stardew Valley** - hotbar is the visible bottom row of the same backpack grid (again: one array, not two).
A single "organize" button sorts + auto-consolidates partial stacks. Tooltips are short and practical: name,
a one-line description of what it's *for*, sell price. Trash is a drag-to-trash-can icon in the menu chrome.

**Factorio** - the standout idea is the type-to-search item filter overlay: start typing and the list narrows
live, no separate search box to click into first (we can't fully match this since letter keys are already
bound to movement/tools, so ours needs an explicit "focus the search box" click first, noted as a deliberate
deviation). Shift-click and ctrl-click both do bulk transfers (half vs. whole stack) between player inventory
and any nearby container/machine. Hovering a partial recipe shows exact missing-ingredient counts inline
rather than making the player do the subtraction.

## Design adopted for ui.lua's bag panel

- **One inventory, slot-based**: `R.invSlots` (array of `{el, n}`) is the arrangement/position store;
  `R.inventory[el]` stays the single authoritative total (per the "core stays source of truth" requirement).
  A reconciliation pass absorbs any external gain/loss (mining, crafting, quest rewards, other plugins writing
  `R.inventory` directly) into the existing stack for that element (or a fresh slot) every frame the panel is
  open, so the two never drift.
- **Hotbar slots 6-0 are real drop targets** at their actual on-screen position (native-drawn, but hit-tested
  by ui.lua) - dragging a bag slot onto one assigns that element there, matching "slots mirror R.hotbar."
  Terraria/Minecraft make the hotbar *literally* the same storage; we can't do that here because R.hotbar
  entries are just a *pointer* to an inventory item name (unlimited draw from R.inventory), not a separate
  stack - so "sync" means keeping the drop-to-assign gesture, not merging the data structures.
- **Hybrid pick-click / press-drag-release**: mousedown on an occupied slot with an empty cursor picks it up
  (Terraria/Minecraft style); if the mouse released on a *different* slot in the same press, that's a real
  drag-and-drop (release = drop there); if released back on the origin, it stays "held" for a follow-up click
  (covers users who click-click instead of drag). Right-click picks up half (rounds up to the held stack) and
  places one at a time - both games' convention.
- **Shift-click** quick-moves a bag stack to the hotbar (first slot already holding that element, else first
  empty 6-0 slot) - the single highest-value Minecraft feature, directly answering "not clicking a ton."
- **Number-key hover-assign**: hovering a row/slot and pressing 6-0 assigns it to that hotbar slot instantly,
  porting Minecraft's number-key swap.
- **Sort button**: consolidates + alphabetizes `R.invSlots`, Stardew-style.
- **Search box**: click to focus, then type to filter the visible list by name or code (Factorio's live-filter
  idea, adapted since letters are otherwise movement/tool keys - focus is required first).
- **Trash slot**: drop a held stack on it to delete permanently from `R.inventory`; small and out of the way,
  like Terraria's trash can, no confirm dialog (matches this game's existing "no confirm" tone elsewhere, e.g.
  crafting).
- **Equipment panel**: separate row of `R.ACC_ORDER` slots, now backed by the new `R.accOwned`/`R.acc`/
  `R.equipAcc` split - click an owned-but-unequipped accessory in the bag to equip it (Terraria-style separate
  equip slots), click an equipped slot to unequip back to the bag.
- **Recipe book beside it**: unchanged tab, adding "craft x1 / x5" buttons per row (a common modern QoL on top
  of the classic single-craft click, avoiding five separate clicks for a batch).

Known deliberate gaps vs. the AAA references above, given the engine's plugin hook surface (only
`mousedown`/`mouseup`/`key`/`keyup`, no drag-move hook - see README): Minecraft's "drag to distribute across
empty slots" is skipped as low value here; Factorio's type-anywhere search isn't possible without stealing
every letter key from movement, so ours requires clicking the search box first. (Update: shift-tracking
originally relied on the `shift` flag riding in on the next keydown and could go briefly stale after release
with no follow-up keypress; core added `R.hooks.keyup` on request, so shift is now cleared the instant either
shift key's own keycode is released - that staleness risk is resolved.)
