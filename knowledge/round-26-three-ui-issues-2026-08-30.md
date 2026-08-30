# Round 26 - Five UI issues, two P0 in flight, three deferred (2026-08-30)

**Track:** roadmap (round 26, design-only spec)
**Files audited:** `scripts/lua/rpg.lua` (HUD band 2595-2675, drawMinimap 2267-2276, drawHotbar 2260, placeAt 1908-1942, key handler 2119-2152, onWheel 2199-2224, cursor preview 2541-2560, brush size hotkeys 2151-2152 / 2217 / 2222)
**Bridge-verified:** PID 37320, port 9877, VER=1.15.10. All line numbers verified against live source.

## TL;DR — re-prioritised per latest user drop

| Fix | Status | Severity | What |
| --- | --- | --- | --- |
| **F15** (wheel / 1px indicator) | **LIVE @bugs** | P0 - in flight | bare wheel = brush size; [ ] fall back; drop cursor preview ticks at brush=0 |
| **F16** (brush shape) | **DEFERRED next round** | HIGH - secondary | F14 below. Today's R.brush = size only. |
| F12 (HUD layout) | DEFERRED to v1.15.14 | HIGH (cosmetic always-on) | Day text bleeds into GOAL bar; multiple readouts stacked with no separation |
| F13 (minimap detail) | DEFERRED to v1.15.14 | MEDIUM | 25×15 tiles, 3 colours, player is same as any tile |
| F14 (brush shape) | DEFERRED to v1.15.14 | HIGH | `R.brush` is a single int 0..4 = SIZE only; no shape picker. Same as F16. |

**This doc is DESIGN-ONLY for F12/F13/F14.** F15 + F16 are already in @bugs's hands; I document them here so the knowledge folder has the full picture but do not re-spec them.

---

## F15 - Wheel / cursor preview (LIVE @bugs)

### Repro from current code

**`scripts/lua/rpg.lua:2213-2224`** (onWheel):
```lua
if R.ctrlHeld then
  local sizes = { 2, 4, 8, 16 }; local cur = 2
  for i, v in ipairs(sizes) do if v == (R.gridSize or 4) then cur = i end end
  R.gridSize = sizes[math.max(1, math.min(#sizes, cur + (d > 0 and 1 or -1)))]
  R.hint = "snap grid " .. R.gridSize .. "px cells"
  return false
end
if R.shiftHeld then
  R.brush = math.max(0, math.min(4, (R.brush or 1) + (d > 0 and 1 or -1)))
  R.hint = "block size " .. (R.grid and ((R.brush + 1) .. " cell" .. (R.brush > 0 and "s" or "")) or ((2 * R.brush + 1) .. "px"))
  return false
end
if R.zoomPending then return end
if inZoom(x, y) then R.brush = math.max(0, math.min(4, (R.brush or 1) + (d > 0 and 1 or -1))); R.hint = "brush " .. (2*R.brush+1) .. "px"; return false end
if R.invOpen then R.craftScroll = math.max(0, math.min(math.max(0, #craftRows() - 8), R.craftScroll - d)); return false end
R.sel = ((R.sel or 1) - 1 - (d > 0 and 1 or -1)) % 10 + 1; return false
```

**Bug 1 (the main user complaint):** BARE wheel (no Shift) currently falls through to `R.sel = ...` (last line) = cycles hotbar slots. User expected bare wheel to scroll their brush size down. `R.shiftHeld` (line 2216) is the ONLY modifier that changes brush size.

**`scripts/lua/rpg.lua:2541-2560`** (cursor preview):
```lua
elseif s and not s:find("^tool:") and not R.ITEMS[s] then local r = R.brush or 1; local cr, cg, cb = colourOf(s)
  local g = R.gridSize or 4
  ...
  local x1, y1, x2, y2 = mx - r, my - r, mx + r, my + r
  ...
  if okr then graphics.fillRect(x1, y1, ww, hh, cr, cg, cb, 90); graphics.drawRect(x1, y1, ww, hh, 255, 255, 255, 210)
  else graphics.fillRect(x1, y1, ww, hh, 255, 60, 60, 50); graphics.drawRect(x1, y1, ww, hh, 255, 90, 90, 180) end
  -- corner ticks so even a 1-cell brush is unmistakable, plus a size label
  local tc = okr and 255 or 150
  graphics.fillRect(x1 - 1, y1 - 1, 3, 1, tc, tc, tc, 230); graphics.fillRect(x1 - 1, y1 - 1, 1, 3, tc, tc, tc, 230)
  graphics.fillRect(x2 - 1, y1 - 1, 3, 1, tc, tc, tc, 230); graphics.fillRect(x2 + 1, y1 - 1, 1, 3, tc, tc, tc, 230)
  graphics.fillRect(x1 - 1, y2 + 1, 3, 1, tc, tc, tc, 230); graphics.fillRect(x1 - 1, y2 - 1, 1, 3, tc, tc, tc, 230)
  graphics.fillRect(x2 - 1, y2 + 1, 3, 1, tc, tc, tc, 230); graphics.fillRect(x2 + 1, y2 - 1, 1, 3, tc, tc, tc, 230)
  local lbl = (R.grid or R.ctrlHeld) and ((r + 1) .. "x" .. (r + 1) .. " cells @" .. g .. "px") or (ww .. "px")
  graphics.drawText(x1, y2 + 4, lbl, 235, 235, 245, 190)
```

**Bug 2 (the indicator-is-bigger-than-the-pixel complaint):** When `R.brush == 0`, `r = 0`, `x1 = mx, y1 = my, x2 = mx, y2 = my, ww = hh = 1` — the actual pixel indicator is 1×1. BUT the corner ticks extend 1px out on each side (lines 2554-2557) making the visual footprint 3×3. The label (line 2558-2559) adds `1px` text BELOW the cursor at `y2 + 4`. So a "single pixel" cursor preview is actually a 3×3 mark + a 3-char text label below — bigger than the thing it's previewing.

### @bugs's fix (P0 - their lane, not mine to design)

F15 is **already in @bugs's hands** per the latest Main steering. I just document the source-code context here so the knowledge folder is complete:

1. **Reorder onWheel:** make bare wheel change brush size (shift out, bare in). Move the existing `R.shiftHeld` brush block to be the default-no-modifier branch. Move `R.sel` cycle behind an explicit `R.ctrlHeld` modifier (so the user can still cycle hotbar slots when they want). `[` `]` keys (line 2151-2152) stay as the secondary size control.
2. **Drop cursor preview ticks+label at brush=0:** wrap lines 2553-2559 in `if (R.brush or 1) > 0 then ... end`. At brush=0, the cursor preview becomes just the 1×1 fillRect+drawRect at lines 2550-2551 — same size as the actual pixel.

**Bridge-verification:** hot-reload rpg.lua; bare-wheel a few times via the bridge (set `R.brush = 2`, call `onWheel(mx, my, 1)` directly, confirm `R.brush == 3` not `R.sel = ...`); set `R.brush = 0`, take screenshot, confirm no ticks+label below the cursor.

**Risk:** MEDIUM. Wheel rebinding changes muscle memory for `R.sel` cycling. Mitigated by routing the old behavior behind Ctrl. At brush=0 cursor preview drop, no risk — purely additive rendering removal.

**This round just notes F15; @bugs owns the implementation.**

---

## F16 - Brush shape selector (DEFERRED next round, same scope as my F14 below)

**Note from Main's latest steering:** F16 = brush SHAPE (circle / line / single-pixel selector). Today's `R.brush = size only`. This is the same scope as the F14 section below.

**Defer to next round:** when @bugs finishes F15, they should design F16 from scratch in their lane. My F14 design below (V key, 3 shapes) is ONE option for F16; @bugs may choose differently.

---

## F12 - HUD layout (DEFERRED to v1.15.14)

### Repro from current code

`scripts/lua/rpg.lua:2613` (Day text, drawn at `y=22`):
```lua
graphics.drawText(8, 22, string.format("Day %d%s   x %d   %s   %s%s", R.day or 1, night > 0.2 and " (night)" or "", floor(R.P.x / 4), where, biomeAt(floor(R.P.x)), R.enemies and "   enemies ON" or ""), 220, 220, 220, 255)
```

At 6px-per-char (TPT default for `graphics.drawText`), the longest realistic format is roughly `Day 137 (night)   x 1234   87m underground   desert   enemies ON` = ~63 chars × 6px = **378px wide**, starting at x=8, ending at x=386.

`scripts/lua/rpg.lua:2676` (GOAL bar, drawn at `x=258, y=20, w=240, h=12`):
```lua
do local q = R.QUESTS[R.quest]; if q then graphics.fillRect(258, 20, 240, 12, 0, 0, 0, 150); graphics.drawText(262, 22, "GOAL " .. R.quest .. "/" .. #R.QUESTS .. ": " .. q.txt, 255, 220, 120, 255) end end
```

GOAL bar covers x=258..498, y=20..32. **Overlap: Day text (when fully populated) ends at x=386, GOAL starts at x=258 — collision from x=258 to x=386, every frame the user has a quest AND is far from spawn.**

Other HUD band elements (`scripts/lua/rpg.lua:2595-2675`):
- Oxygen bar: y=8, x=8..124 (only when o2<100 or co2>25)
- Food/water bar: y=26..29 (only when below 100)
- T gauge: y=33..37, x=24..124 + label at x=128 + value at x=130 (always-on)
- P gauge: y=45..49, x=24..124 + label at x=128 + value at x=130 (always-on)
- Log tail: y=58, y=70, y=82... (per message, fading)
- Sandbox banner: y=40, x=W-200 (right side)
- Deaths counter: y=22, x=W-80 (right side)
- Version readout: y=8, x=W-80 (right side)

**Visual problem:** Day text (y=22) is sandwiched between oxygen (y=8) and T gauge (y=33). It also has no background fillRect, so it bleeds over the GOAL bar (which DOES have a fillRect 0,0,0,150 bg). When the user has a quest AND day/night is "night" AND they have "enemies ON", the format string pushes the text into the GOAL bar.

### Concrete proposed shape

**Three-row top-left band with bg fillRect behind each row:**

```
y=4..16  -> [O2 bar | T gauge | log title slot]   -- bg: fillRect(4,4, W/2-8, 12, 0,0,0,140)
y=18..30 -> [Day text on its OWN row, bg filled]   -- bg: fillRect(4,18, W/2-8, 12, 0,0,0,140)
y=32..50 -> [Food/water + need text]               -- bg: fillRect(4,32, W/2-8, 18, 0,0,0,140)
y=52..76 -> [Log tail: 2 rows, fading]             -- existing y=58 + y=70, but new bg group
```

**Move GOAL bar to top-right corner** (replacing version readout position; move version to bottom-left as a small fixed readout). New GOAL box: `x = W-300, y = 4, w = 296, h = 12` — clear of Day text entirely.

**Day text simplification:** drop "enemies ON" suffix (it clutters and is a separate toggle the user already knows about via `n` key). Keep day number, night marker, x coord, where, biome. New format: `"Day %d%s   x %d   %s   %s"` — ~35 chars max, ends around x=220. Fits in the dedicated row.

**Per-row bg fillRect pattern** (the key insight from round-26 user feedback: "multiple readouts stacked with no separation"):
```lua
-- Row 1 (gauge row, y=4-16): drawn bg first, then oxygen/T/P on top
graphics.fillRect(4, 4, 250, 12, 0, 0, 0, 140)
-- existing oxygen + T gauge + P gauge rendered with adjusted y values
```

**TPT text rendering is non-transparent background by default** — adding a `fillRect` BEHIND each text line groups the readouts visually and stops them bleeding into the canvas/sky background. This is the cheap fix the user is asking for.

### Where the change goes

- `rpg.lua:2595-2675` (HUD band): refactor y coords; add `graphics.fillRect` calls behind each group of readouts.
- `rpg.lua:2676` (GOAL bar): move from `x=258, y=20` to `x=W-300, y=4`.
- `rpg.lua:2608` (version readout): move from `y=8, x=W-80` to `y=H-12, x=4` (bottom-left, tiny grey).
- `rpg.lua:2613` (Day text): drop `enemies ON` suffix, keep on dedicated y=20-30 row.
- `rpg.lua:2675` (sandbox banner): move to y=H-28 (bottom-left, above version).

**Bridge-verification approach:** render via bridge call to `graphics.screenshot()` after hot-reload; visually compare against pre-fix screenshot. Lab 9877 has the live canvas; `rpg_screenshot` MCP tool gives PNG. **Quantitative check:** the current overlap region (x=258..386, y=20..32) should be ALL Day text or ALL GOAL bg after fix, never both.

### Risk vs F1-F10 / v1.15.7-v1.15.12

- **LOW.** Pure cosmetic repositioning. No state, no logic, no helper extractions.
- v1.15.7-v1.15.12 helpers (`R._resetSpawnState`, `R._teleportCompanionAndClear`) untouched.
- v1.15.4-v1.15.12 readouts (o2, gas, hunger, thirst, T, P) still drawn at the same x range; only y positions shift + bg fillRect added.
- One edge case: the version readout move to bottom-left means it could collide with the chat input box (y=H-46..H-32 area). Mitigation: only draw version if `not (R.chatOpen or R.feedbackOpen)`.

---

## F13 - Minimap has no detail (DEFERRED to v1.15.14)

### Repro from current code

`scripts/lua/rpg.lua:2267-2276`:
```lua
local function drawMinimap()
  local mx, my = W - 110, 4; local sz = 4
  graphics.fillRect(mx-2, my-2, 108, 62, 0, 0, 0, 170)
  local ctx, cty = floor((R.P.x) / TS), floor((R.P.y) / TS)
  for k, t in pairs(R.tiles) do if t.sx1 then
    local dx, dy = t.tx - ctx, t.ty - cty; if dx >= -12 and dx <= 12 and dy >= -6 and dy <= 6 then
      local wy = t.ty * TS; local col = wy < surfaceAt(t.tx * TS) and {90, 140, 220} or (wy > 1450 and {200, 80, 40} or {120, 110, 100})
      graphics.fillRect(mx + 50 + dx*sz, my + 26 + dy*sz, sz, sz, col[1], col[2], col[3], 255) end end end
  graphics.fillRect(mx + 50, my + 26, sz, sz, 255, 255, 255, 255)
end
```

**Verified defects:**
1. **Player marker is 4×4 white square — same size as every other tile, no distinction.**
2. **Window is 25×15 tiles, 4px each = 100×60px.** Smaller than a thumbnail. At sz=4, the user can't see anything below 16px screen-space.
3. **Only 3 colours total:** blue=sky (`{90,140,220}`), orange=hell (`{200,80,40}`), grey=everything-else (`{120,110,100}`). No biome distinction, no cave entrance distinction, no chest/distinctive-feature marker.
4. **No labels:** no world coords on the minimap, no north marker, no legend, no "you are here" annotation.
5. **Hotkey toggle exists** (`m` at line 2129) — `R.minimap = not R.minimap` — so the user CAN turn it off entirely, but there's no way to make it MORE detailed.

**Note:** the user's exact words: "the map doesn't even work. Like it doesn't even like show details or anything." That's a complaint that the existing implementation is unreadable, not that it's missing entirely. So the fix is "make it readable" not "make it bigger and add 10 features".

### Concrete proposed shape

**Keep 100×60 frame, but triple the visible tile count via 2px-per-tile rendering (50×30 tiles visible) and use the per-tile `ctype`/`tmp`/`ex` data that's ALREADY in `R.tiles` to add distinguishing marks.**

**Changes:**
1. **Smaller per-tile size:** `sz = 2` instead of 4. Now 50×30 tiles visible. Each tile is a single colour, but the colour set expands.
2. **Per-tile colour from `R.tiles[k].ex` (the rare-cell list already saved by save.lua:5):** if a tile has any element other than air in its seen rect, use the AVERAGE colour of the first few ex entries; otherwise the existing 3-color fallback. This makes chests/biomes actually distinguishable.
3. **Player marker:** change from `graphics.fillRect(mx+50, my+26, sz, sz, 255,255,255)` to an **arrow shape** (5px-tall triangle pointing UP) at center. Distinguishable at a glance.
4. **North marker:** add a single `N` glyph at `mx+sz*25, my-2` (top edge of minimap). Small grey.
5. **Coordinate readout:** below the minimap, `graphics.drawText(mx, my+62, "x=" .. floor(R.P.x/4) .. "  z=" .. floor(R.P.y/4) .. "  " .. R.tilesSeen .. " tiles", 180, 180, 200, 140)`.
6. **Legend:** bottom-right corner of the minimap, a 3-pixel micro-legend (3 small squares: blue/sky, orange/hell, grey/cave, white/player).

### Where the change goes

- `rpg.lua:2267-2276` (drawMinimap body): rewrite the loop body to use sz=2 and add the player arrow + N marker + coord readout + legend.
- **Optional follow-on:** add a `V` hotkey (F16's shape cycle could double as minimap "view detail level" — high / med / low) but that's outside F13's scope.
- **No plugin changes needed.** drawMinimap is core rpg.lua only.

### Bridge-verification approach

1. Hot-reload rpg.lua after the edit.
2. Bridge call: `graphics.screenshot()` → PNG.
3. Visual check: minimap should show MORE tiles (50×30 vs old 25×15), player marker should be an arrow not a square.
4. Negative test: turn minimap off via `m`, screenshot, confirm gone. Turn back on.
5. Quantitative: count distinct colours visible in the minimap region (should be >3, not 3).

### Risk vs F1-F10 / v1.15.7-v1.15.12

- **LOW.** drawMinimap is called once per frame; rendering cost roughly doubles (50×30=1500 vs 25×15=375 cells). Negligible CPU.
- No state changes; no helper invocations; no save/load; no respawn path; no companion.
- One interaction risk: if user has `R.minimap = false` (turned off), they keep it off — no regression for them.

---

## F14 / F16 - Brush shape (DEFERRED to v1.15.14; @bugs may own F16 next round)

### Repro from current code

`scripts/lua/rpg.lua:1917` (placeAt radius):
```lua
local r = fine and (R.brush or 0) or (R.brush or 1)
```

`scripts/lua/rpg.lua:1933-1937` (placeAt box calc):
```lua
local x1, y1, x2, y2 = mx - r, my - r, mx + r, my + r
if R.grid or R.ctrlHeld then
  local gx = floor((mx + R.cam.x) / g) * g - R.cam.x; local gy = floor((my + R.cam.y) / g) * g - R.cam.y
  x1, y1, x2, y2 = gx - g*r, gy - g*r, gx + g*r + g - 1, gy + g*r + g - 1
end
```

`scripts/lua/rpg.lua:1938-1940` (placeAt fill loop):
```lua
for y = y1, y2 do for x = x1, x2 do
  local inPlayer = x >= px + BOXL - 1 and x <= px + BOXR + 1 and y >= py + BOXT - 1 and y <= py
  if inv(el) > 0 and not sim.partID(x, y) and not inPlayer then local n = sim.partCreate(-1, x, y, t); if n and n >= 0 then R.inventory[el] = inv(el) - 1; placed = placed + 1 end end end end
```

**Verified:** `for y = y1, y2 do for x = x1, x2 do` is a SQUARE loop. The bounds `(mx-r, my-r, mx+r, my+r)` always make a square. There is NO shape picker anywhere in the codebase. `R.brush` is a single int 0..4.

**Verified hotkey usage** (line 2151-2152):
```lua
if k == "[" then R.brush = math.max(0, (R.brush or 1) - 1); say("place brush " .. (2*R.brush+1) .. "px"); return false end
if k == "]" then R.brush = math.min(4, (R.brush or 1) + 1); say("place brush " .. (2*R.brush+1) .. "px"); return false end
```

After F15 lands, `[` `]` become SECONDARY for size. F14/F16 is independent of F15.

**Available single-letter hotkeys** (verified via grep on the key handler at rpg.lua:2119+): `v`, `y`, `j`, `l`, `o`, `p` are unused at the top level (the `a d w s` block is movement; `e b h k m n r t u x z` are taken; `c` and `f` are reserved for player action/cursor; `q` is eyedropper; `g` is hook-grapple; `i` is unused but reserved for inventory/i-marker).

**`V` is the cleanest choice** for shape cycle: one keystroke, cycle 3-4 shapes, easy to remember (close to `[` `]` size pattern visually).

### Concrete proposed shape

**Three shapes, cycled via `V`:**
1. **square** (current behavior — `for y = y1, y2 do for x = x1, x2 do`)
2. **circle** — replace the inner loop with a distance check `if (x-mx)^2 + (y-my)^2 <= r*r then place end`
3. **single-pixel** — `placeAt(mx, my)` only, regardless of `R.brush`

**Storage:** `R.brushShape` = "square" | "circle" | "single". Default "square".

**Hotkey:** `V` cycles to next shape, say `"brush: " .. R.brushShape` so the user gets feedback.

**Display:** in the hotbar hint at line 2260, append `"  V shape"`:
```lua
sub = "hold LEFT mouse to place    SHIFT+wheel = size    V = shape: " .. (R.brushShape or "square")
```

**Help line** at line 2392 (BLOCKS help):
```lua
"BLOCKS   slots 6-0 = materials you carry -> hold LEFT mouse to place   [ ] brush size   V brush shape   B snap grid (4px cells)"
```

### Where the change goes

- `rpg.lua:1917` (placeAt): add shape dispatch — `if R.brushShape == "single" then singlePixel(mx, my) elseif R.brushShape == "circle" then circle(mx, my, r) else square(mx, my, r) end`. Implement `circle` as the loop-with-distance-check helper.
- `rpg.lua:1938` (the fill loop): no change for square; add circle branch.
- `rpg.lua:2151-2152` area (key handler): add `if k == "v" then ... end` after the `[` `]` size lines.
- `rpg.lua:2260` (drawHotbar hint): append shape info to sub string.
- `rpg.lua:2392` (help line): add `V brush shape` token.

**No save/load changes needed.** R.brushShape is per-session; doesn't need to persist.

### Bridge-verification approach

1. Hot-reload rpg.lua.
2. Bridge: set `R.brush = 2, R.brushShape = "circle"`. Call `placeAt` directly with a known empty region. `sim.parts()` around the click → should be a circular disc.
3. Same for `R.brushShape = "single"` → exactly 1 particle at the click.
4. Same for default "square" → square fill.
5. Key handler test: simulate `k = "v"` (via `R.hotReloadRequested` or direct call to the handler) and verify `R.brushShape` cycles.
6. Negative test: `R.brush = 0` (1px), `R.brushShape = "circle"` → still 1px (radius=0 → single pixel regardless of shape). Confirms no edge case.

### Risk vs F1-F10 / v1.15.7-v1.15.12

- **LOW.** Pure additive: new state, new branch, new hotkey.
- v1.15.7-v1.15.12 spawn helpers untouched.
- v1.15.4-v1.15.12 logic (`buildStation`, `commitBox`) use `selected()` and `R.ITEMS` checks before reaching the loop — they're unaffected by shape.
- Existing `R.brush = 0..4` semantics preserved: still controls radius.
- **One small UX risk:** users who have `V` bound to something in their muscle memory. Mitigation: only intercept V inside the RPG key handler (which is already the case — line 2119 is the RPG key handler, runs before any native pass-through).

---

## Decision

- **F15 (wheel + cursor preview):** @bugs is live on it. This doc just records the source context so the knowledge folder has the full round-26 picture.
- **F16 (brush shape = my F14):** @bugs will own it next round; this doc is a candidate spec for them to use or redesign.
- **F12 + F13 + F14 → v1.15.14.** When @bugs finishes F15 (and any F16 they pick up), the next round packages F12+F13+F14 (or F14 alone if F16 takes it) into a single version bump.

**No new checker built** for any of these — all UX fixes, not invariant violations.

## Verification

- Bridge: PID 37320, port 9877, VER=1.15.10. All line numbers verified against live source.
- Live bridge confirmed: `R.minimap` toggles via `m` (line 2129), `R.brush` cycles via `[` `]` (line 2151-2152), `R.shiftHeld` recognised in placeAt (line 1920) and onWheel (line 2216), `R.brush` re-used in cursor preview at line 2541 with `r = R.brush or 1` and at line 2546 with `x1, y1, x2, y2 = mx - r, ...`.
- Companion.lua untouched (verified — no HUD drawing from companion).
- Survival.lua untouched for these fixes.
- Save.lua untouched for these fixes.
- No source changes from this round (design-only); zero mutations to scripts/lua/rpg.lua or plugins from round 26.