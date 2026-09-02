-- RPG plugin: enemies. Sprite-drawn slimes/zombies/bats + a slime-king boss, own physics via R.solidW,
-- replaces the dead FIGH-based sword with a reach+cooldown hit on our own enemy list. See README.md for the hook API.
local R = PBX.state.rpg
local TAG = "enemies"
local floor = math.floor
-- FIXED 2026-09-02. This used to remove EVERY entry carrying this plugin's tag before appending,
-- which meant a plugin's SECOND hook on a given list silently deleted its FIRST. @audit proved
-- that killed the Replicator Core recovery feature outright -- it was registered, then destroyed
-- by a later registration in the same file, and nobody could see why the feature did nothing.
-- 29 plugins share this helper and several register 7-14 hooks, so an unknown number of features
-- have been quietly dead. The reload cleanup it was trying to do is still needed, so it now
-- happens ONCE per load, across every hook list, before any registration -- and hook() simply
-- appends, so a file can register as many hooks as it likes.
for _, __l in pairs(R.hooks or {}) do
  if type(__l) == "table" then
    for i = #__l, 1, -1 do
      if type(__l[i]) == "table" and __l[i].tag == TAG then table.remove(__l, i) end
    end
  end
end
local function hook(list, fn)
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

-- ================================================================ persistent state (survives reloadPlugin)
R.EN = R.EN or {}                 -- live enemies: {kind,x,y,vx,vy,onGround,hp,maxhp,w,h,dmg,speed,face,hopTimer,touchCd,hurtAt}
R.EN_FX = R.EN_FX or {}           -- floating damage numbers: {x,y,text,r,g,b,born}
R.EN_STATE = R.EN_STATE or {}     -- timers/cooldowns/boss tracking
local ES = R.EN_STATE
local CAP = 16                    -- normal-enemy cap (boss spawns on top of this, rarely)

local KINDS = {
  slime  = { name = "Slime",    hp = 30,  dmg = 6,  w = 5,  h = 6,  speed = 0.9,  colr = { 90, 200, 90 } },
  zombie = { name = "Zombie",   hp = 50,  dmg = 10, w = 3,  h = 10, speed = 0.55, colr = { 110, 150, 90 } },
  bat    = { name = "Cave Bat", hp = 20,  dmg = 5,  w = 3,  h = 4,  speed = 1.1,  colr = { 70, 60, 90 } },
  boss   = { name = "the Slime King", hp = 420, dmg = 18, w = 14, h = 16, speed = 0.9, colr = { 40, 160, 70 } },
}

-- ================================================================ world helpers
local function isNight()
  local phase = ((R.frame or 0) % 14000) / 14000
  local night = math.max(0, math.sin((phase - 0.5) * math.pi * 2))
  return night > 0.2
end
local function clearColumn(wx, y, h)  -- true if (wx,y) up through (wx,y-h+1) is all open
  for i = 0, h - 1 do if R.solidW(wx, y - i) then return false end end
  return true
end
local function playerCenter() return R.P.x, R.P.y - 5 end

-- ================================================================ enemy physics (ground: slime/zombie/boss)
local function boxBlockedE(x, y, e) -- corner check: left/right at box top and at feet row
  return R.solidW(x - e.w, y) or R.solidW(x + e.w, y) or R.solidW(x - e.w, y - e.h) or R.solidW(x + e.w, y - e.h)
end
local function footBlockedE(x, y, e)
  return R.solidW(x - e.w, y) or R.solidW(x, y) or R.solidW(x + e.w, y)
end
local function applyHorizontalMove(e)
  if e.vx == 0 then return end
  local nx = e.x + e.vx
  if boxBlockedE(floor(nx), floor(e.y), e) then e.vx = 0 else e.x = nx end
end
local MAXFALL_E = 4.5
local function applyGravityMove(e)
  e.vy = math.min(MAXFALL_E, e.vy + 0.24)
  local x = floor(e.x)
  if e.vy >= 0 then
    local y = floor(e.y); local step = 0; local landed = false
    while step < e.vy do
      step = step + 1
      if footBlockedE(x, y + step, e) then landed = true; step = step - 1; break end
    end
    e.y = y + step
    if landed then e.vy = 0; e.onGround = true else e.onGround = false end
  else
    local y = floor(e.y); local step = 0; local blocked = false
    while step > e.vy do
      step = step - 1
      if boxBlockedE(x, y + step, e) then blocked = true; step = step + 1; break end
    end
    e.y = y + step
    if blocked then e.vy = 0 end
  end
end
local function physicsStep(e) applyHorizontalMove(e); applyGravityMove(e) end

-- ================================================================ AI
local function aiHopper(e, detectRange, hopSpeed, hopVy, idleChance)
  if e.onGround then
    e.hopTimer = (e.hopTimer or 0) - 1
    if e.hopTimer <= 0 then
      local dx = R.P.x - e.x
      local dir
      if math.abs(dx) < detectRange then dir = (dx > 0) and 1 or -1
      elseif math.random() < idleChance then dir = (math.random() < 0.5) and -1 or 1 end
      if dir then e.vy = hopVy; e.vx = dir * hopSpeed; e.face = dir end
      e.hopTimer = 40 + math.random(0, 30)
    else
      e.vx = e.vx * 0.85; if math.abs(e.vx) < 0.05 then e.vx = 0 end
    end
  end
  physicsStep(e)
end
local function aiSlime(e) aiHopper(e, 260, 0.9, -1.7, 0.5) end
local function aiBoss(e) aiHopper(e, 340, 1.2, -2.4, 0.8) end
local function aiZombie(e)
  local dx = R.P.x - e.x
  if math.abs(dx) < 320 then
    e.vx = (dx > 0 and 1 or -1) * e.speed; e.face = (dx > 0 and 1 or -1)
  else
    e.wanderT = (e.wanderT or 0) - 1
    if e.wanderT <= 0 then e.vx = ((math.random() < 0.5) and -1 or 1) * e.speed * 0.5; e.wanderT = 60 + math.random(0, 60) end
  end
  physicsStep(e)
end
local function aiBat(e)
  local px, py = R.P.x, R.P.y - 8
  local dx, dy = px - e.x, py - e.y
  local d = math.sqrt(dx * dx + dy * dy)
  local tx, ty
  if d > 1 and d < 220 then tx, ty = dx / d, dy / d; e.face = (tx >= 0) and 1 or -1
  else
    e.wanderT = (e.wanderT or 0) - 1
    if e.wanderT <= 0 or not e.wdx then e.wdx = (math.random() - 0.5); e.wdy = (math.random() - 0.5) * 0.6; e.wanderT = 50 + math.random(0, 40) end
    tx, ty = e.wdx, e.wdy; e.face = (tx >= 0) and 1 or -1
  end
  local speed = e.speed
  local nx, ny = e.x + tx * speed, e.y + ty * speed
  if not R.solidW(floor(nx), floor(e.y)) then e.x = nx else e.wdx = -(e.wdx or 0.5) end
  if not R.solidW(floor(e.x), floor(ny)) then e.y = ny else e.wdy = -(e.wdy or 0.3) end
end
local AI = { slime = aiSlime, zombie = aiZombie, bat = aiBat, boss = aiBoss }

-- ================================================================ damage / death / fx
local function spawnDmgNum(x, y, text, r, g, b)
  local FX = R.EN_FX
  FX[#FX + 1] = { x = x, y = y, text = text, r = r, g = g, b = b, born = R.frame }
  if #FX > 40 then table.remove(FX, 1) end
end
local function killEnemy(e)
  e.dead = true
  R.say(KINDS[e.kind].name .. " defeated!")
  if e.kind == "slime" then
    if math.random() < 0.5 then R.give("GOO", 1 + floor(math.random() * 2)) end
  elseif e.kind == "zombie" then
    R.give("BMTL", 1 + floor(math.random() * 2))
    if math.random() < 0.3 then R.give("WOOD", 2) end
  elseif e.kind == "bat" then
    if math.random() < 0.35 then R.give("COAL", 1) end
  elseif e.kind == "boss" then
    R.give("GOLD", 10); R.give("STEL", 5)
    local pool = {}
    for _, k in ipairs(R.ACC_ORDER) do if not R.acc[k] then pool[#pool + 1] = k end end
    R.giveAcc(pool[1 + floor(math.random() * #pool)] or "hook")
    ES.bossAlive = false
    R.say("The Slime King has fallen - a treasure appears!")
  end
end
local function damageEnemy(e, dmg, fromx, fromy, kb)
  e.hp = e.hp - dmg
  e.hurtAt = R.frame
  local sign = (e.x - fromx >= 0) and 1 or -1
  kb = kb or (e.kind == "bat" and 2.2 or 1.8)
  e.vx = sign * kb
  e.vy = -math.min(3.5, math.max(1.2, kb))
  spawnDmgNum(e.x, e.y - (e.h or 8), tostring(dmg), 255, 255, 255)
  if e.hp <= 0 then killEnemy(e) end
end

-- ================================================================ public damage API for other plugins (e.g. items.lua guns)
-- R.damageEnemiesAt(x, y, radius, dmg, knockback): world coords; hits every live enemy within radius, applies
-- knockback away from (x,y) (default ~1.8px/frame like the sword), spawns a floating damage number, kills+drops as usual.
-- Returns the number of enemies hit. R.enemyList(): the live enemy array (read-only by convention) -
-- each entry is {kind, x, y, vx, vy, hp, maxhp, w, h, dmg, dead, ...} in world coords; skip entries where e.dead is true.
function R.damageEnemiesAt(x, y, radius, dmg, knockback)
  local hits = 0
  for _, e in ipairs(R.EN) do
    if not e.dead then
      local dx, dy = e.x - x, e.y - y
      if dx * dx + dy * dy <= radius * radius then damageEnemy(e, dmg, x, y, knockback); hits = hits + 1 end
    end
  end
  return hits
end
function R.enemyList() return R.EN end

-- ================================================================ sword (replaces the dead FIGH-based hit code)
local function trySwordAttack()
  if R.menuOpen or R.invOpen then return end
  local sel = R.hotbar and R.hotbar[R.sel or 1]
  if sel ~= "tool:sword" then return end
  local tool = R.TOOLS.sword; if not tool then return end
  if (R.frame - (ES.lastSwing or -99)) < (tool.speed or 12) then return end
  ES.lastSwing = R.frame
  local px, py = playerCenter()
  local reach = tool.reach or 34
  ES.swing = { x = px, y = py, face = R.P.face or 1, frame = R.frame }
  local hits = 0
  for _, e in ipairs(R.EN) do
    if not e.dead then
      local dx, dy = e.x - px, e.y - py
      if dx * dx + dy * dy <= reach * reach then damageEnemy(e, tool.dmg or 15, px, py); hits = hits + 1 end
    end
  end
  if R.damageCompanion and R.COMP and R.COMP.active and not R.COMP.dead then
    local dx, dy = R.COMP.x - px, R.COMP.y - py
    if dx * dx + dy * dy <= reach * reach then R.damageCompanion(tool.dmg or 15, px, py); hits = hits + 1 end
  end
  R.hint = hits > 0 and ("hit x" .. hits) or "swing"
end

-- ================================================================ contact damage on the player
local function checkPlayerContact(e)
  if ES.touchCd and false then end -- (per-enemy cooldown stored on e, see below)
  if e.touchCd and e.touchCd > R.frame then return end
  local px, py = playerCenter()
  local dx, dy = e.x - px, e.y - py
  local rx, ry = (e.w or 4) + 3, (e.h or 8) + 5
  if math.abs(dx) <= rx and math.abs(dy) <= ry then
    R.hp = math.max(0, R.hp - e.dmg); R.hurt = R.frame; R._bloodEligible = true
    local sign = (px >= e.x) and 1 or -1
    R.P.vx = sign * 1.6; R.P.vy = -1.8
    e.touchCd = R.frame + 30
  end
end

-- ================================================================ spawning
local function spawnEnemy(kind, wx, wy)
  local k = KINDS[kind]
  -- R.difficultyMul (Options menu slider): one choke point scales every enemy's
  -- hp/dmg at spawn time -- cheaper and safer than touching the 8+ scattered
  -- R.hp = math.max(0, R.hp - dmg) call sites across rpg.lua that would need
  -- individually to scale player-side damage instead.
  local dm = R.difficultyMul or 1
  local hp = k.hp * dm
  local e = { kind = kind, x = wx + 0.0, y = wy + 0.0, vx = 0, vy = 0, onGround = false,
              hp = hp, maxhp = hp, w = k.w, h = k.h, dmg = k.dmg * dm, speed = k.speed,
              face = 1, touchCd = 0, born = R.frame, hopTimer = math.random(0, 30) }
  R.EN[#R.EN + 1] = e
  return e
end
R.spawnEnemy = spawnEnemy   -- exposed like buildStation/craft/etc, matches this codebase's convention
local function trySpawnSlime()
  local dir = (math.random() < 0.5) and -1 or 1
  local wx = floor(R.P.x) + dir * (180 + math.random(0, 280))
  local depth = R.P.y - R.surfaceAt(floor(R.P.x))
  local wy
  if depth > 40 and math.random() < 0.6 then
    local by = floor(R.P.y) + math.random(-40, 40); local found
    for dy = 0, 30 do if R.solidW(wx, by + dy + 1) and not R.solidW(wx, by + dy) then found = by + dy; break end end
    if not found then return false end
    wy = found
  else
    wy = R.surfaceAt(wx) - 1
  end
  if math.abs(wx - floor(R.P.x)) < 40 then return false end
  if not clearColumn(wx, wy, 6) then return false end
  spawnEnemy("slime", wx, wy); return true
end
local function trySpawnZombie()
  if not isNight() then return false end
  local dir = (math.random() < 0.5) and -1 or 1
  local wx = floor(R.P.x) + dir * (160 + math.random(0, 300))
  local wy = R.surfaceAt(wx) - 1
  if math.abs(wx - floor(R.P.x)) < 40 then return false end
  if not clearColumn(wx, wy, 10) then return false end
  spawnEnemy("zombie", wx, wy); return true
end
local function trySpawnBat()
  local depth = R.P.y - R.surfaceAt(floor(R.P.x))
  if depth < 30 then return false end
  local wx = floor(R.P.x) + math.random(-260, 260)
  local wy = floor(R.P.y) + math.random(-120, 120)
  if math.abs(wx - floor(R.P.x)) < 30 and math.abs(wy - floor(R.P.y)) < 30 then return false end
  if R.solidW(wx, wy) then return false end
  if wy < R.surfaceAt(wx) + 15 then return false end
  spawnEnemy("bat", wx, wy); return true
end
local function spawnBoss()
  local wx = floor(R.P.x) + ((math.random() < 0.5) and -1 or 1) * (220 + math.random(0, 150))
  local wy = R.surfaceAt(wx) - 1
  for _ = 1, 8 do
    if clearColumn(wx, wy, 16) then break end
    wx = wx + ((math.random() < 0.5) and -20 or 20); wy = R.surfaceAt(wx) - 1
  end
  spawnEnemy("boss", wx, wy)
  ES.bossAlive = true
  R.say("The Slime King rises!")
end

-- ================================================================ tick
hook(R.hooks.tick, function()
  local _t0 = os.clock()
  -- sword: continuous while held (mousedown hook below covers the initial click)
  if R.mouse and R.mouse.l then trySwordAttack() end

  -- spawning (gated on the N-key toggle; existing enemies keep acting either way)
  if R.enemies and #R.EN < CAP then
    ES.nextSpawn = ES.nextSpawn or R.frame
    if R.frame >= ES.nextSpawn then
      ES.nextSpawn = R.frame + 180 + math.random(0, 180)
      local roll = math.random()
      if roll < 0.45 then trySpawnSlime()
      elseif roll < 0.75 then trySpawnZombie()
      else trySpawnBat() end
    end
  end

  -- boss: after a night survived with enemies on
  ES.lastDay = ES.lastDay or R.day
  if R.day ~= ES.lastDay then
    if R.enemies and not ES.bossAlive then
      ES.nightsSinceBoss = (ES.nightsSinceBoss or 0) + 1
      if ES.nightsSinceBoss >= 2 or math.random() < 0.4 then spawnBoss(); ES.nightsSinceBoss = 0 end
    end
    ES.lastDay = R.day
  end

  -- per-enemy AI / physics / contact / cull
  local px, py = R.P.x, R.P.y
  for _, e in ipairs(R.EN) do
    if not e.dead then
      local ai = AI[e.kind]; if ai then ai(e) end
      checkPlayerContact(e)
      if (e.x - px) * (e.x - px) + (e.y - py) * (e.y - py) > 800 * 800 then
        e.cull = true
        if e.kind == "boss" then ES.bossAlive = false end
      end
    end
  end
  for i = #R.EN, 1, -1 do local e = R.EN[i]; if e.dead or e.cull then table.remove(R.EN, i) end end
  ES.tickMs = (os.clock() - _t0) * 1000
end)

-- ================================================================ mousedown: immediate swing feedback on click
hook(R.hooks.mousedown, function(x, y, button)
  if button == 1 then trySwordAttack() end
end)

-- ================================================================ draw (world space, before the player sprite)
local function drawEnemy(e)
  local x, y = floor(e.x) - R.cam.x, floor(e.y) - R.cam.y
  if x < -40 or x > R.W + 40 or y < -40 or y > R.H + 40 then return end
  local hurt = e.hurtAt and (R.frame - e.hurtAt) < 8
  local col = KINDS[e.kind].colr
  local cr, cg, cb = col[1], col[2], col[3]
  if hurt then cr, cg, cb = 255, 90, 90 end
  local w, h = e.w, e.h
  if e.kind == "bat" then
    graphics.fillCircle(x, y - floor(h / 2), w + 1, w, cr, cg, cb, 255)
    local wing = ((floor((R.frame or 0) / 4) % 2) == 0) and 2 or -1
    graphics.fillRect(x - w - 2, y - floor(h / 2) + wing, 3, 2, cr, cg, cb, 220)
    graphics.fillRect(x + w - 1, y - floor(h / 2) + wing, 3, 2, cr, cg, cb, 220)
  elseif e.kind == "slime" or e.kind == "boss" then
    local squash = (e.onGround and math.abs(e.vx or 0) < 0.1) and 1 or 0
    graphics.fillCircle(x, y - floor(h / 2) + squash, w, floor(h / 2), cr, cg, cb, 255)
    graphics.fillRect(x - 2, y - h + 2, 1, 1, 20, 20, 20, 255); graphics.fillRect(x + 1, y - h + 2, 1, 1, 20, 20, 20, 255)
    if e.kind == "boss" then graphics.drawRect(x - w - 1, y - h - 4, 2 * w + 2, 3, 255, 220, 80, 255) end
  else -- zombie
    graphics.fillRect(x - w, y - h, 2 * w, h, cr, cg, cb, 255)
    graphics.fillRect(x - 1, y - h + 2, 2, 2, 20, 20, 20, 255)
  end
  if e.hp < e.maxhp then
    local bw = math.max(10, w * 2 + 4)
    graphics.fillRect(x - floor(bw / 2), y - h - 6, bw, 3, 40, 10, 10, 220)
    graphics.fillRect(x - floor(bw / 2), y - h - 6, math.max(0, floor(bw * e.hp / e.maxhp)), 3, 220, 40, 50, 255)
  end
end
hook(R.hooks.draw, function()
  for _, e in ipairs(R.EN) do if not e.dead then drawEnemy(e) end end
  if ES.swing and R.frame - ES.swing.frame < 8 then
    local sw = ES.swing
    local x, y = sw.x - R.cam.x, sw.y - R.cam.y
    local prog = (R.frame - sw.frame) / 8
    local reach = (R.TOOLS.sword and R.TOOLS.sword.reach or 34) * 0.75
    local ang = sw.face * (prog - 0.5) * 2.2
    local ax, ay = x + math.cos(ang) * reach * sw.face, y + math.sin(ang) * reach * 0.5
    graphics.drawLine(x, y, ax, ay, 255, 255, 255, floor(220 * (1 - prog)))
  end
  for i = #R.EN_FX, 1, -1 do
    local fx = R.EN_FX[i]; local age = R.frame - fx.born
    if age > 40 then table.remove(R.EN_FX, i)
    else
      local x, y = fx.x - R.cam.x, fx.y - R.cam.y - floor(age * 0.4)
      graphics.drawText(x - 2, y, fx.text, fx.r, fx.g, fx.b, math.max(0, 255 - age * 6))
    end
  end
end)

-- ================================================================ HUD: boss health bar
hook(R.hooks.drawHUD, function()
  for _, e in ipairs(R.EN) do
    if e.kind == "boss" and not e.dead then
      local w = 300; local x0 = floor((R.W - w) / 2)
      graphics.fillRect(x0, 30, w, 10, 0, 0, 0, 200); graphics.drawRect(x0, 30, w, 10, 255, 220, 80, 255)
      graphics.fillRect(x0 + 1, 31, math.max(0, floor((w - 2) * e.hp / e.maxhp)), 8, 200, 40, 60, 255)
      graphics.drawText(x0 + 4, 32, "Slime King", 255, 240, 200, 255)
      break
    end
  end
end)
