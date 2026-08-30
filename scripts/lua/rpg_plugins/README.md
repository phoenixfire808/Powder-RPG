# RPG plugin API (rpg.lua v4)

Each plugin is one Lua file in this folder, loaded at the end of rpg.lua (names in `R.PLUGINS`: world, enemies, machines, save, ui).
`R = PBX.state.rpg` is the game state. Reload one plugin live with `PBX.state.rpg.reloadPlugin("name")` via execute_lua
(result string is "ok" or the error). Hooks are appended to lists, so a plugin MUST remove its own previous hooks on reload.
Pattern:

    local R = PBX.state.rpg
    local TAG = "enemies"
    local function hook(list, fn)
      for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
      list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
    end
    hook(R.hooks.tick, function() ... end)

Hooks (`R.hooks.<name>`; runHooks does pcall(f, ...), errors go to `R.pluginErr`; a truthy return stops the chain):
- `tick()` every frame after the player and camera update
- `draw()` before the player sprite (world effects; canvas coords = world - R.cam.x/y)
- `drawHUD()` after the HUD (panels, labels)
- `key(k, shift, ctrl, alt)` return true to consume; k is a lowercase char, "space", "escape", "f1"
- `keyup(k)` on key release (same k names)
- `wheel(x, y, d)` mouse wheel, return true to consume; `mousemove(x, y, dx, dy)` cursor moved
- `mousedown(x, y, button)` / `mouseup(x, y, button)` return true to consume (button 1 left, 3 right)
- `place(el, mx, my, fine)` return true if the plugin placed this inventory item itself (mx,my canvas)
- `mine(el, n)` after items are given; `craft(recipe)` after a craft
- `sandbox()` fired when sandbox mode is switched on: give/unlock everything your plugin owns (R.sandbox is true while active)
- `newworld()` fired when the player starts a new world: reset every table your plugin keeps (enemies, machines, slots...)
- `gen(wx, wy)` return an element name to override world generation at a cell, "" for air, nil to keep base terrain

Helpers on R: `eid(name)`, `nameOf(type)`, `has(name)`, `colourOf(name)`, `descOf(name)`, `say(msg)`, `inv(el)`, `give(el, n)`,
`gen(wx, wy)`, `surfaceAt(wx)`, `biomeAt(wx)`, `solidW(wx, wy)`, `useTool(mx, my, fine)`, `smartTarget(mx, my, reach, only, power)`,
`buildStation(kind, mx, my)`, `nearStation(kind)`, `rebuildHotbar()`, `zoomToCanvas(x, y)`, `inZoom(x, y)`, `reloadPlugin(name)`.
State: `R.P` (player: x,y world coords of the feet; vx,vy; onGround; face), `R.cam` (canvas origin in world coords), `R.frame`,
`R.hp`, `R.inventory` (element/item name -> count), `R.hotbar`/`R.sel`, `R.stations` ({kind,x,y}), `R.torches`, `R.RECIPES`
(append `{out, n, need, st, txt, desc}`; st = hand|workbench|furnace|anvil or a new kind you register in `R.STATIONS`),
`R.ITEMS` (pseudo items: name -> `{col={r,g,b}, desc}`), `R.QUESTS`/`R.quest`/`R.stats`, `R.acc` (accessories), `R.weather`,
`R.tiles` (off-screen particle store keyed per 64px tile), `R.chests`, `R.MINEABLE` (tier) / `R.HARD` (hits), `R.DEPTH`,
`R.W/R.H/R.M` (canvas 612x384, 4px dead border), `R.uiPanelOpen` (set true while your panel is open: core hides the cursor highlight), `R.keys` (held movement keys), `R.mouse` {x,y,l,r}, `R.menuOpen`, `R.invOpen`.

Engine rules: particles only exist at x in [4,607], y in [4,379]; after `sim.partPosition` moves, `partCreate` into vacated cells
fails until the next frame; the camera moves every other frame by up to 4px (`R.cam` changes) - store world coords, not canvas.
NEVER call sim.clearSim / sim.loadSave / regenerate the world / restart the game: the user is playing live in this sim.
Test by loading rpg.lua (or your plugin via reloadPlugin) with the bridge and checking `R.pluginStatus`, `R.pluginErr`, `R.lastErr`.
