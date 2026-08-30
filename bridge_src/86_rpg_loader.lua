-- Loads the standalone RPG demo (scripts/lua/rpg.lua, not part of this
-- bridge bundle) into the running game and starts it, so Drew can hand
-- control straight to a friend without typing anything in the console
-- himself. Load-only, no auto-start -- see the bottom of this file for why
-- start is a separate, explicit step.
-- Drew asked to go back to plain sandbox and not work on the RPG right now
-- -- flip this to true (and rebuild) to bring the loader back; false means
-- this whole module does nothing, since even just loading rpg.lua has
-- side effects on the plain sandbox (hides the HUD/menus, registers event
-- handlers) that shouldn't happen when nobody asked for the RPG.
local RPG_ENABLED = true
if RPG_ENABLED then
do
local PBX = _G.PBX
if not PBX then error("86_rpg_loader.lua: PBX foundation missing") end

-- io.open + loadstring, not dofile -- dofile is untested in this fork's
-- sandbox, whereas this exact pattern is already proven working (see
-- bridge_base.lua's executeLua action).
-- Absolute dev path first: something on Drew's machine keeps recreating a
-- stale scripts/lua/rpg.lua next to build/PowderToyRPG.exe (same old file,
-- same old timestamp -- not a fresh write from anything in this session's
-- own workflow, cause not identified), and a relative-path-first order let
-- that stale copy silently shadow every real edit to the dev source for an
-- entire evening even after being deleted once. Checking the absolute path
-- first makes that shadow file inert on Drew's machine regardless of
-- whether it comes back. Relative path second, for a portable copy handed
-- to someone else -- their machine has no D:/powder-toy at all, so this
-- lookup just fails over to their bundled copy exactly as before.
local RPG_PATHS = {
  "../scripts/lua/rpg.lua",
  "scripts/lua/rpg.lua",
  "D:/The-Powder-Toy/scripts/lua/rpg.lua",
  "D:/powder-toy/scripts/lua/rpg.lua",
}
local ok, err = pcall(function()
    local f
    for _, path in ipairs(RPG_PATHS) do
        f = io.open(path, "r")
        if f then break end
    end
    if not f then error("could not open rpg.lua (tried: " .. table.concat(RPG_PATHS, ", ") .. ")") end
    local code = f:read("*a")
    f:close()
    local fn, loadErr = loadstring(code)
    if not fn then error(loadErr) end
    return fn()
end)
if not ok then
    PBX.log("rpg_loader", "failed to load rpg.lua: " .. tostring(err))
else
    PBX.log("rpg_loader", "rpg.lua loaded -- call startRPG() from the console, or it's already been started for tonight below")
    _G.startRPG = function(seed)
        local R = PBX.state.rpg
        if not R then return "rpg.lua didn't load" end
        return R.start(seed)
    end
    _G.stopRPG = function()
        local R = PBX.state.rpg
        if not R then return "rpg.lua didn't load" end
        return R.stop()
    end
    -- Plain, always-available manual unpause -- rpg.lua's own start-up path
    -- already unpauses once world generation finishes (a deferred tick, not
    -- immediate), but if that ever gets stuck (generation errors, or just
    -- runs long), there was no obvious way to unstick it. This works no
    -- matter what state the RPG script itself is in.
    _G.unpauseSim = function() sim.paused(false); return "unpaused" end
    -- Belt-and-suspenders watchdog: force an unpause every tick for the
    -- first 5 seconds after start, in case rpg.lua's own generation-done
    -- unpause never fires for some reason. Self-removes after that window
    -- so it doesn't fight a deliberate pause later in the play session.
    local watchdogTicks = 300
    local watchdogHandler
    watchdogHandler = function()
        watchdogTicks = watchdogTicks - 1
        pcall(sim.paused, false)
        if watchdogTicks <= 0 and event.unregister then
            pcall(event.unregister, event.TICK, watchdogHandler)
        end
    end
    if event and event.register and event.TICK then
        event.register(event.TICK, watchdogHandler)
    end
    _G.startRPG()
end
end
end
