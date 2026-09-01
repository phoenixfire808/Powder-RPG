-- RPG plugin: companion / colonist. A second, fully-simulated sprite with its own gravity/run/jump/
-- step-up/collision (via R.solidW), its own small inventory and HP, and a distinct look + name tag.
--
-- MODEL (the player 20:42-20:43): the PLAYER is the main character (core owns it). The COLONIST is a
-- permanent second character this file owns: present from the very first frame of a new world (never a
-- summon/craft), revives near the player a short while after dying instead of disappearing, narrates
-- proactively about real world state, and answers the player's Enter-chat messages (core's R.chatSay /
-- R.chatPending / R.hooks.chat) using real state.
--
-- companion.lua v1.15.34 — digArea/buildRoom start+halfway chat milestones live on R.COMP (not C.action)
-- fields) so re-issued digArea cmds / action-table replacement cannot spam "Starting to dig that out."
--
-- BRAIN ARCHITECTURE (the player 20:26-20:34, via lead): the SCRIPTED brain below is the executor and the
-- reflexes - pathing, following, step-up, hazard avoidance, self-defense, continuing the current task -
-- and it runs every tick regardless of whether any model is involved, so the colonist is fully playable
-- and fully conversational (via text templates) with NO model running. scripts/companion_driver.py is an
-- OPTIONAL local-model layer (Qwen2.5 3B via LM Studio/Ollama) that only ever proposes a high-level
-- command + a line of dialogue every couple of seconds via R.companionCmd/R.chatSay; a stale-heartbeat
-- watchdog here automatically hands control back to the scripted brain if the driver stalls or dies, and
-- the same self-defense/hazard/teleport-home overrides can interrupt ANY command regardless of source.
-- See knowledge/design-companion-protocol.md for the exact JSON schema and
-- knowledge/design-multiplayer.md for how a second human could drive this same action layer later.
local R = PBX.state.rpg
local TAG = "companion"
local floor, abs, min, max, sqrt, random = math.floor, math.abs, math.min, math.max, math.sqrt, math.random
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

-- ================================================================ persistent state (survives reloadPlugin)
R.COMP = R.COMP or {
  active = false, x = 0, y = 0, vx = 0, vy = 0, onGround = false, coyote = 0, face = 1, anim = 0,
  hp = 60, maxhp = 60, dead = false, deadAt = nil,
  name = "Aster",
  inv = {},                 -- colonist's own small inventory: element/item -> count
  mode = "auto",             -- "auto" (scripted brain drives it) | "manual" (only explicit C.cmd calls) | "model" (driver is live)
  action = nil,              -- current task: {name, args, status="running"|"success"|"fail", start, from="scripted"|"model"|"manual"}
  override = nil,            -- transient safety override (e.g. self-defense); resumes `action` after
  sayMsg = nil, sayAt = nil,
  hurtAt = nil,
  lastMineHelpAt = 0,
  lastAutoGiveAt = 0,
  lastHeartbeat = nil,
  needsPlace = false,        -- set on newworld; positioned onto the fresh player on the next tick (R.P
                              -- isn't repositioned yet at the moment R.hooks.newworld itself fires)
  queue = {},                -- multi-step task chain: list of {name,args} run after the current action succeeds
  chatQueue = {},            -- {text,at} messages waiting for companion_driver.py while mode=="model"
  dismissed = false,         -- true after player dismisses; blocks auto-spawn until follow/recall
  index = nil,               -- refreshed ~every 2s by refreshIndex(): the colonist's world-knowledge summary
}
local C = R.COMP
function R._applyCompanionDefaults()
  local c = R.COMP
  if type(c) ~= "table" then c = {}; R.COMP = c end
  if c.active == nil then c.active = false end
  c.x = c.x or 0; c.y = c.y or 0; c.vx = c.vx or 0; c.vy = c.vy or 0
  c.onGround = c.onGround or false; c.coyote = c.coyote or 0; c.face = c.face or 1; c.anim = c.anim or 0
  c.hp = c.hp or 60; c.maxhp = c.maxhp or 60
  if c.dead == nil then c.dead = false end
  c.name = c.name or "Aster"
  c.inv = c.inv or {}
  c.mode = c.mode or "auto"
  c.queue = c.queue or {}
  c.chatQueue = c.chatQueue or {}
  if c.dismissed == nil then c.dismissed = false end
  c.lastMineHelpAt = c.lastMineHelpAt or 0
  c.lastAutoGiveAt = c.lastAutoGiveAt or 0
  if c.needsPlace == nil then c.needsPlace = false end
end
R.PLUGIN_SAVE_KEYS = R.PLUGIN_SAVE_KEYS or {}
do
  local seen = false
  for _, k in ipairs(R.PLUGIN_SAVE_KEYS) do if k == "COMP" then seen = true end end
  if not seen then table.insert(R.PLUGIN_SAVE_KEYS, "COMP") end
end

-- ================================================================ constants
local GRAV, RUN, ACC, JUMP, MAXFALL = 0.24, 1.3, 0.3, -2.75, 4.5
local CBOXL, CBOXR, CBOXT = -2, 1, -9      -- colonist is a touch shorter than the player (h=9 vs 10)
local FOLLOW_GAP = 16                       -- how far behind the player it likes to stand
local TELEPORT_DIST = 600                   -- hard rule: never left more than this far behind
local MELEE_REACH, MELEE_DMG, MELEE_CD = 18, 9, 22
local MINE_REACH, MINE_CD = 20, 10
local POWER = 1                             -- colonist's effective tool tier (== a basic wood pick)
-- Outer hard fail, well past navigateTo's own repath/jump/dig-up ladder (which escalates at
-- NAV_STUCK*1/*2/*3 = 90/180/270 frames, so this must stay comfortably above 270).
-- MEASURED 2026-08-30 on the live game, do NOT trust the old "~8s" note that assumed 60fps:
-- the real tick rate under the owner's actual load is ~36.5 fps (146 frames observed over 4.0s at
-- ~100k particles), so 480 frames is really ~13.1s, and a chain step that stalls, takes its one
-- allowed re-plan, then stalls again is ~26s of standing still. Not a loop (the re-plan is hard-
-- capped at 1 by C._chainReplans, verified by trace), but longer than it reads in code.
-- Left at 480 deliberately: lowering it is a feel/tuning call for the owner, and dropping toward 300
-- would leave the dig-up escalation almost no window (300-270 = 30 frames) to actually work.
local STUCK_FRAMES = 480
local REVIVE_DELAY = 300                    -- ~5s: dies, then reappears at the player rather than vanishing
local MODEL_TIMEOUT = 600                   -- ~10s with no companion_driver.py heartbeat => fall back to auto
local NARRATE_GAP, NARRATE_GAP_URGENT = 1500, 300  -- ~25s / ~5s between unprompted lines (the player: "20-40s unless urgent")
local HAZ = { LAVA = 1, FIRE = 1, ACID = 1, CAUS = 1, PLSM = 1 }

-- ================================================================ small helpers
local function cInv(item) return (C.inv[item] or 0) end
local function cGiveSelf(item, n) C.inv[item] = cInv(item) + n end
local function cTakeSelf(item, n) C.inv[item] = max(0, cInv(item) - n) end
-- the colonist as an actor for core's shared actor framework (R.actorMine/Place/Fill/Clear/Craft/Give/Light,
-- R.senseRect/senseNearest/senseColumn/senseSelf - the player 21:12: "use these instead of hand-rolling behaviour")
local function colonistActor() return { x = C.x, y = C.y, inv = C.inv, tools = { pick = { power = 1 }, axe = { power = 1 } } } end
local function isNightC() local phase = ((R.frame or 0) % 14000) / 14000; return max(0, math.sin((phase - 0.5) * math.pi * 2)) > 0.2 end

-- speech: sayC = something the colonist says right now, always (reaction to a command/chat, or an
-- action's own flavor text - not rate-limited, these are already inherently sparse). narrate = the
-- PROACTIVE line generator (world-state commentary) - hard rate-limited and never repeats itself twice
-- in a row, per the player's "one line every ~20-40s unless something urgent" ask.
local function sayC(msg)
  -- route through core's R.colonistSay when present (single source of truth for the chat log + bubble,
  -- per the 20:52 stopgap) - falls back to doing it ourselves so this stays correct even if reloaded
  -- before core picks up R.colonistSay.
  if R.colonistSay then R.colonistSay(msg); return end
  C.sayMsg = msg; C.sayAt = R.frame
  R.chatSay(C.name or "Aster", msg)
end
local NAR = { lastAt = -999999, lastLine = nil }
local function narrate(msg, urgent)
  local gap = urgent and NARRATE_GAP_URGENT or NARRATE_GAP
  if R.frame - NAR.lastAt < gap then return false end
  if msg == NAR.lastLine then return false end
  NAR.lastAt = R.frame; NAR.lastLine = msg
  sayC(msg)
  return true
end

-- ================================================================ physics (own box, own collision via R.solidW)
local function boxBlockedC(x, y)
  for yy = y + CBOXT, y - 1 do for xx = x + CBOXL, x + CBOXR do if R.solidW(xx, yy) then return true end end end
  return false
end
local function footBlockedC(x, y)
  for xx = x + CBOXL, x + CBOXR do if R.solidW(xx, y) then return true end end
  return false
end
local function hazardAheadC(x, y, dir)
  local xx = x + dir * (CBOXR + 2)
  local cam = R.cam
  for _, yy in ipairs({ y - 5, y - 1 }) do
    local p = sim.partID(xx - cam.x, yy - cam.y)
    if p then local nm = R.nameOf(sim.partProperty(p, "type")); if HAZ[nm] then return true end end
  end
  return false
end
local function stepPhysics(wantDx, wantJump)
  local x, y = floor(C.x), floor(C.y)
  C.vx = C.vx + max(-ACC, min(ACC, wantDx - C.vx))
  if wantDx == 0 then C.vx = C.vx * (C.onGround and 0.5 or 0.9); if abs(C.vx) < 0.05 then C.vx = 0 end end
  C.vy = min(MAXFALL, C.vy + GRAV * (R.gravMul or 1))
  if wantJump and (C.onGround or C.coyote > 0) then C.vy = JUMP * (R.jumpMul or 1); C.onGround = false; C.coyote = 0 end
  if boxBlockedC(x, y) then for up = 1, 10 do if not boxBlockedC(x, y - up) then y = y - up; break end end end
  local fx = C.x + C.vx; local dir = (fx > C.x) and 1 or -1
  while floor(fx) ~= x do
    local tx = x + dir
    if not boxBlockedC(tx, y) then x = tx
    else
      local stepped = false
      for up = 1, 4 do if not boxBlockedC(tx, y - up) then x = tx; y = y - up; stepped = true; break end end
      if not stepped then C.vx = 0; fx = x; break end
    end
  end
  C.x = (floor(fx) == x) and fx or x
  local fy = y + C.vy; local vdir = (fy > y) and 1 or -1; local landed = false
  while floor(fy) ~= y do
    local ty = y + vdir
    if vdir > 0 then if footBlockedC(x, ty) then landed = true; fy = y; break end
    else if boxBlockedC(x, ty) then C.vy = 0; fy = y; break end end
    y = ty
  end
  C.y = (floor(fy) == y) and fy or y
  C.onGround = footBlockedC(x, y + 1) or landed
  if C.onGround then C.coyote = 6 else C.coyote = max(0, C.coyote - 1) end
  if abs(C.vx) > 0.2 and C.onGround then C.anim = (C.anim or 0) + 1 end
end

-- moveToward: one tick of pathing progress. Returns arrived(bool), arrivedX(bool).
-- Never walks into a sampled hazard (lava/fire/acid/plasma) one step ahead - waits/re-routes instead.
local function moveToward(tx, ty, tolx, toly)
  tolx = tolx or 4; toly = toly or 10
  local dx = tx - C.x
  local arrivedX = abs(dx) <= tolx
  local wantDx = 0
  if not arrivedX then
    local dir = (dx > 0) and 1 or -1
    if not hazardAheadC(floor(C.x), floor(C.y), dir) then wantDx = dir * RUN * (R.runMul or 1)
    else C.face = dir end -- hazard ahead: hold position rather than walk into it
  end
  if wantDx ~= 0 then C.face = (wantDx > 0) and 1 or -1 end
  local wantJump = false
  if wantDx ~= 0 then
    local aheadX = floor(C.x) + (wantDx > 0 and 3 or -3)
    if boxBlockedC(aheadX, floor(C.y) - 5) and (ty < C.y - 6 or C.onGround) then wantJump = true end
  end
  stepPhysics(wantDx, wantJump)
  local arrivedY = abs(C.y - ty) <= toly
  return arrivedX and arrivedY, arrivedX
end

-- stuck detection shared by every "goto-ish" action
local function progressCheck(a)
  if not a._pgX or abs(C.x - a._pgX) > 3 then a._pgX = C.x; a._pgFrame = R.frame end
  return (R.frame - (a._pgFrame or R.frame)) < STUCK_FRAMES
end

-- ================================================================ mining: R.actorMine (core's shared actor
-- framework, the player 21:12: "use these instead of hand-rolling behaviour") - respects real pick tier, credits
-- the colonist's OWN inventory (a.inv, since colonistActor() is not isPlayer), and triggers crumble/tree-fell
-- exactly like the player's own mining. Returns (item-or-false, wasBlockedByTier).
local function tryMineAt(mx, my, opts)
  local ok, result = R.actorMine(colonistActor(), mx, my, opts)
  if ok then return result, false end
  return false, result == "needs a better pick" or (type(result) == "string" and result:find("better pick") ~= nil)
end

-- ================================================================ navigation (the player 21:01: "he should
-- intelligently navigate his way out"). Rides core's shared R.findPath A* (walk/step-up/jump/drop, optional
-- dig) instead of pure local stepping, with an escalation ladder when progress genuinely stalls:
-- 1) repath allowing digging, 2) try a jump toward the target, 3) dig straight up as a last resort (the
-- classic "buried alive" case) - each stage resets the stuck timer so it isn't retried every single frame.
local NAV_REPATH_GAP, NAV_STUCK, NAV_ARRIVE = 90, 90, 8
-- NOTE: this must NOT touch _navX/_navY/_navFrame/_navEsc - those track genuine positional stuck-ness and
-- have to survive a path running out (a live target's path is exhausted/recomputed constantly), or the
-- stuck timer keeps getting wiped to zero every time and the jump/dig escalation ladder never fires. A real
-- 21:20 lab bug: the colonist stood dead still failing to reach a target for 8+ seconds with zero escalation
-- because this used to reset those fields too.
local function navReset(a) a.path = nil; a.pathIdx = nil; a._pathTX, a._pathTY, a._pathAt = nil, nil, nil end
local function navigateTo(a, tx, ty, tol)
  tol = tol or NAV_ARRIVE
  local dx, dy = tx - C.x, ty - C.y
  if dx * dx + dy * dy <= tol * tol then return true end
  if not a._navX or abs(C.x - a._navX) > 3 or abs(C.y - (a._navY or C.y)) > 3 then
    a._navX, a._navY, a._navFrame, a._navEsc = C.x, C.y, R.frame, 0
  end
  local stuckFor = R.frame - (a._navFrame or R.frame)
  -- Perf (21:2x, the player: "super laggy" - companion was 6.3ms/tick): R.findPath is a real A* search, so this
  -- must run ONCE per goal, not on a timer. Only repath when the target actually moved a meaningful amount
  -- or the path ran out - never a periodic "just in case" recompute.
  local stale = (not a.path) or abs((a._pathTX or 1e9) - tx) > 20 or abs((a._pathTY or 1e9) - ty) > 20
  if stale then
    local ok, path = pcall(R.findPath, floor(C.x), floor(C.y), floor(tx), floor(ty), { dig = (stuckFor > NAV_STUCK), maxNodes = 900 })
    a.path = ok and path or nil; a.pathIdx = 1; a._pathTX, a._pathTY, a._pathAt = tx, ty, R.frame
  end
  if stuckFor > NAV_STUCK * 3 then                 -- escalation 3: dig straight up (buried-alive last resort)
    tryMineAt(floor(C.x), floor(C.y) - 6); a._navFrame = R.frame; return false
  elseif stuckFor > NAV_STUCK * 2 then              -- escalation 2: a bare jump toward the target
    stepPhysics((tx > C.x) and RUN * (R.runMul or 1) or -RUN * (R.runMul or 1), true); a._navFrame = R.frame; return false
  end
  local path = a.path
  if not path or #path == 0 then moveToward(tx, ty, tol, tol); return false end
  local wp = path[a.pathIdx]
  if not wp then navReset(a); return false end
  if wp.dig and (R.frame - (a._digAt or -99)) >= MINE_CD then a._digAt = R.frame; tryMineAt(wp.x, wp.y) end
  moveToward(wp.x, wp.y, 6, 8)
  if (C.x - wp.x) ^ 2 + (C.y - wp.y) ^ 2 <= 8 * 8 then a.pathIdx = a.pathIdx + 1 end
  return false
end

-- CHEAP chase (the player 21:2x, "super laggy" - companion measured 6.3ms/tick, budget is ~1.0ms): plain direct
-- stepping every tick (near-free), with a real R.findPath A* search only as a RARE escalation once genuinely
-- stuck - never on a timer, never on ordinary target drift. Used by follow (the default, always-running
-- state) and fight's approach phase, the two chase loops that would otherwise run constantly.
local function cheapChase(a, tx, ty, tolx, toly)
  if not a._navX or abs(C.x - a._navX) > 3 or abs(C.y - (a._navY or C.y)) > 3 then
    a._navX, a._navY, a._navFrame = C.x, C.y, R.frame
  end
  local stuckFor = R.frame - (a._navFrame or R.frame)
  if a.path then
    local wp = a.path[a.pathIdx]
    if not wp then a.path = nil
    else
      if wp.dig and (R.frame - (a._digAt or -99)) >= MINE_CD then a._digAt = R.frame; tryMineAt(wp.x, wp.y) end
      moveToward(wp.x, wp.y, 6, 8)
      if (C.x - wp.x) ^ 2 + (C.y - wp.y) ^ 2 <= 64 then a.pathIdx = a.pathIdx + 1 end
      return
    end
  end
  if stuckFor > NAV_STUCK * 3 then tryMineAt(floor(C.x), floor(C.y) - 6); a._navFrame = R.frame; return end
  if stuckFor > NAV_STUCK * 2 then stepPhysics((tx > C.x) and RUN * (R.runMul or 1) or -RUN * (R.runMul or 1), true); a._navFrame = R.frame; return end
  if stuckFor > NAV_STUCK then
    local ok, path = pcall(R.findPath, floor(C.x), floor(C.y), floor(tx), floor(ty), { dig = true, maxNodes = 900 })
    if ok and path then a.path = path; a.pathIdx = 1 end
    a._navFrame = R.frame -- don't hammer findPath every tick while still stuck - retry after another NAV_STUCK
    return
  end
  moveToward(tx, ty, tolx, toly)
end

local function findNearest(matchFn, maxR)
  maxR = maxR or 170
  local cx, cy = C.x, C.y
  local best, bestD = nil, maxR * maxR
  local cam = R.cam
  for wy = cy - maxR, cy + maxR, 4 do
    local sy = wy - cam.y
    if sy >= R.M and sy < R.H - R.M then
      for wx = cx - maxR, cx + maxR, 4 do
        local sx = wx - cam.x
        if sx >= R.M and sx < R.W - R.M then
          local p = sim.partID(sx, sy)
          if p then
            local nm = R.nameOf(sim.partProperty(p, "type"))
            if matchFn(nm) then
              local d = (wx - cx) * (wx - cx) + (wy - cy) * (wy - cy)
              if d < bestD then bestD = d; best = { x = wx, y = wy, el = nm } end
            end
          end
        end
      end
    end
  end
  return best
end

local function findFightTarget(range)
  if not R.enemyList then return nil end
  local best, bestD = nil, (range or 260) * (range or 260)
  for _, e in ipairs(R.enemyList()) do
    if not e.dead then
      local d = (e.x - C.x) * (e.x - C.x) + (e.y - C.y) * (e.y - C.y)
      if d < bestD then bestD = d; best = e end
    end
  end
  return best
end

local function playerInRect(x1, y1, x2, y2)
  if not R.P then return false end
  local px, py = floor(R.P.x), floor(R.P.y)
  local xa, ya = min(x1, x2), min(y1, y2)
  local xb, yb = max(x1, x2), max(y1, y2)
  return px >= xa and px <= xb and py >= ya and py <= yb
end
local function viewRect(marginX, marginY)
  marginX = marginX or 80; marginY = marginY or 60
  local px, py = floor(R.P.x), floor(R.P.y)
  return { x1 = px - marginX, y1 = py - marginY, x2 = px + marginX, y2 = py + marginY }
end
local function houseSite(w, h)
  w = w or 10; h = h or 8
  local px, py = floor(R.P.x), floor(R.P.y)
  local face = R.P.face or 1
  local x = px + face * (w + 4)
  local y = py - h + 1
  if playerInRect(x, y, x + w - 1, y + h - 1) then x = px - face * (w + 4) end
  return x, y, w, h
end

-- ================================================================ command STEP handlers
-- Every handler: STEP.<name>(a) -> "running" | "success" | "fail", detail
-- `a` is the action table: {name, args, status, start, from, ...scratch fields}
local STEP = {}

STEP.stay = function(a) return "success" end
STEP.say = function(a) sayC(tostring(a.args and a.args.text or "...")); return "success" end

STEP.follow = function(a)
  local px, py = R.P.x, R.P.y
  local tx = px - (R.P.face or 1) * FOLLOW_GAP
  if abs(C.x - px) < 6 then tx = C.x end -- don't jitter when basically caught up
  cheapChase(a, tx, py, 8, 40)
  return "running" -- follow is a standing mode, not a one-shot task
end

STEP.goto_ = function(a)
  if not progressCheck(a) then return "fail", "stuck" end
  if navigateTo(a, a.args.x, a.args.y, a.args.tol or 8) then return "success" end
  return "running"
end

STEP.mine = function(a)
  if not progressCheck(a) then return "fail", "stuck" end
  local args = a.args or {}
  local tx, ty = args.x, args.y
  if not tx and args.element then
    if not a._target then a._target = findNearest(function(nm) return nm == args.element end) end
    if not a._target then return "fail", "none nearby" end
    tx, ty = a._target.x, a._target.y
  end
  if not tx then return "fail", "no target" end
  local arrived = navigateTo(a, tx, ty, MINE_REACH)
  if not arrived then return "running" end
  if (R.frame - (a._lastHit or -99)) < MINE_CD then return "running" end
  a._lastHit = R.frame
  local got, blocked = tryMineAt(tx, ty, { axe = args.axe })
  if got then return "success", got end
  if blocked then return "fail", "too hard" end
  a._misses = (a._misses or 0) + 1
  if a._misses > 40 then return "fail", "nothing there" end
  return "running"
end
STEP.mineNearest = STEP.mine -- alias: {element=...} already routes through the same handler

STEP.chop = function(a)
  local args = a.args or {}
  args.axe = true
  if not args.element and not args.x then args.element = "WOOD" end
  a.args = args
  return STEP.mine(a)
end

STEP.fetch = function(a) -- {item=, n=}: keep mining the nearest source of `item` until n collected
  local args = a.args or {}
  local item = args.item; local want = args.n or 1
  if cInv(item) >= want then return "success" end
  a.args = { element = item }
  local st, detail = STEP.mine(a)
  a.args = args
  if st == "success" then a._target = nil; if cInv(item) >= want then return "success" end; return "running" end
  if st == "fail" then return "fail", detail end
  return "running"
end

STEP.place = function(a)
  local args = a.args or {}
  if cInv(args.element) < 1 then return "fail", "none in inventory" end
  if not progressCheck(a) then return "fail", "stuck" end
  local arrived = navigateTo(a, args.x, args.y, 14)
  if not arrived then return "running" end
  local ok, why = R.actorPlace(colonistActor(), args.element, args.x, args.y)
  if ok then return "success" end
  return "fail", why
end

STEP.buildWall = function(a)
  local args = a.args or {}
  local x1, y1, x2, y2, el = args.x1, args.y1, args.x2, args.y2, args.element
  if not (x1 and y1 and x2 and y2 and el) then return "fail", "bad args" end
  if not a._cells then
    a._cells = {}
    local dx, dy = x2 - x1, y2 - y1; local steps = max(1, floor(max(abs(dx), abs(dy))))
    for i = 0, steps do a._cells[#a._cells + 1] = { x = floor(x1 + dx * i / steps + 0.5), y = floor(y1 + dy * i / steps + 0.5) } end
    a._i = 1
  end
  if a._i > #a._cells then return "success" end
  local cell = a._cells[a._i]
  if cInv(el) < 1 then return "fail", "ran out of " .. R.nice(el) end
  if not progressCheck(a) then return "fail", "stuck" end
  local arrived = navigateTo(a, cell.x, cell.y, 14)
  if not arrived then return "running" end
  local ok, why = R.actorPlace(colonistActor(), el, cell.x, cell.y)
  if not ok and why and why:find("^no ") then return "fail", why end -- out of material: stop the wall, report why
  -- any other reason (occupied, player standing there) just means skip this cell - never overwrite, never fail on it
  a._i = a._i + 1
  return "running"
end
STEP.build = STEP.buildWall -- model-facing alias, same {element,x1,y1,x2,y2} shape

STEP.craft = function(a) -- R.actorCraft can top up a small shortfall from the player's own stock too
  local args = a.args or {}
  local ok, result = R.actorCraft(colonistActor(), args.recipe)
  if ok then return "success", result end
  return "fail", result
end

STEP.give = function(a) -- colonist -> player, from the colonist's own inventory. n omitted = give all of it.
  local args = a.args or {}
  local ok, result = R.actorGive(colonistActor(), R.playerActor(), args.item, args.n)
  if ok then return "success", result end
  return "fail", result
end

STEP.take = function(a) -- player -> colonist (explicit command only; never done silently)
  local args = a.args or {}
  local ok, result = R.actorGive(R.playerActor(), colonistActor(), args.item, args.n)
  if ok then return "success", result end
  return "fail", result
end

STEP.fight = function(a)
  if not R.damageEnemiesAt or not R.enemyList then return "fail", "no enemies loaded" end
  a.target = a.target or findFightTarget(260)
  if not a.target or a.target.dead then return "success" end
  local d = sqrt((a.target.x - C.x) ^ 2 + (a.target.y - C.y) ^ 2)
  if d > 340 then return "success", "target fled" end
  if d > MELEE_REACH then
    if not progressCheck(a) then return "success", "couldn't reach it" end -- e.g. a flier over open air: give up cleanly
    cheapChase(a, a.target.x, a.target.y, MELEE_REACH - 4, 14); return "running"
  end
  if (R.frame - (a._lastHit or -99)) >= MELEE_CD then
    a._lastHit = R.frame
    R.damageEnemiesAt(C.x, C.y - 4, MELEE_REACH, MELEE_DMG, 1.5)
  end
  return "running"
end

STEP.light = function(a)
  local args = a.args or {}
  if not progressCheck(a) then return "fail", "stuck" end
  local arrived = navigateTo(a, args.x, args.y, 14)
  if not arrived then return "running" end
  local ok, why = R.actorLight(colonistActor(), args.x, args.y)
  if ok then return "success" end
  return "fail", why
end

-- ================================================================ AREA / BUILD TASKS (design-companion-core.md
-- §4): parametric, not prefab - the caller (or a chat handler) supplies a rect/spec, this code generates the
-- actual cell-by-cell work. This is what makes "cut all these trees" / "dig me a big hole" / "build me a
-- house" possible instead of a single-point primitive.
STEP.clearTrees = function(a)
  local args = a.args or {}
  local x1, y1 = min(args.x1, args.x2), min(args.y1, args.y2)
  local x2, y2 = max(args.x1, args.x2), max(args.y1, args.y2)
  a._got = a._got or 0
  if not progressCheck(a) then return "success", a._got end -- ran long enough without progress: report what we got, not a hard fail
  local target = findNearest(function(nm) return nm == "WOOD" or nm == "PLNT" end, 240)
  if target and target.x >= x1 and target.x <= x2 and target.y >= y1 and target.y <= y2 then
    local arrived = navigateTo(a, target.x, target.y, MINE_REACH)
    if not arrived then return "running" end
    if (R.frame - (a._lastHit or -99)) < MINE_CD then return "running" end
    a._lastHit = R.frame
    local got = tryMineAt(target.x, target.y, { axe = true })
    if got then a._got = a._got + 1; a._pgFrame = R.frame end
    return "running"
  end
  return "success", a._got
end

STEP.digArea = function(a)
  local args = a.args or {}
  if not a._cells then
    local x1, y1 = min(args.x1, args.x2), min(args.y1, args.y2)
    local x2, y2 = max(args.x1, args.x2), max(args.y1, args.y2)
    local cells = {}
    for y = y1, y2, 3 do for x = x1, x2, 3 do
      if not (args.keepWalls and (x <= x1 + 2 or x >= x2 - 2 or y <= y1 + 2 or y >= y2 - 2)) then
        cells[#cells + 1] = { x = x, y = y }
      end
    end end
    table.sort(cells, function(p, q) return p.y < q.y end) -- top-down, so spoil never buries the next cell
    a._cells = cells; a._i = 1; a._hitCount = 0
  end
  if a._i > #a._cells then C._digAreaStartSaid, C._digAreaHalfSaid = nil, nil; return "success", a._hitCount end
  if not C._digAreaStartSaid then C._digAreaStartSaid = true; sayC("Starting to dig that out.") end
  if not C._digAreaHalfSaid and a._i > #a._cells / 2 then C._digAreaHalfSaid = true; sayC("Halfway through digging that out.") end
  local cell = a._cells[a._i]
  if not progressCheck(a) then C._digAreaStartSaid, C._digAreaHalfSaid = nil, nil; return "fail", "stuck" end
  local arrived = navigateTo(a, cell.x, cell.y, MINE_REACH)
  if not arrived then return "running" end
  if (R.frame - (a._lastHit or -99)) < MINE_CD then return "running" end
  a._lastHit = R.frame
  local got = tryMineAt(cell.x, cell.y)
  if got then a._hitCount = a._hitCount + 1 end
  a._i = a._i + 1 -- move on regardless (an already-air cell just gets skipped, not stalled on forever)
  a._pgFrame = R.frame
  return "running"
end

local function roomCells(args)
  local x, y, w, h = args.x, args.y, args.w or 10, args.h or 8
  local doorX = args.door and (x + floor(w / 2)) or nil
  local cells = {}
  for yy = y, y + h - 1 do
    cells[#cells + 1] = { x = x, y = yy }
    cells[#cells + 1] = { x = x + w - 1, y = yy }
  end
  for xx = x, x + w - 1 do
    cells[#cells + 1] = { x = xx, y = y } -- roof/ceiling row
    if args.floor ~= false and xx ~= doorX then cells[#cells + 1] = { x = xx, y = y + h - 1 } end -- floor row, minus door gap
  end
  table.sort(cells, function(p, q) return p.y > q.y end) -- bottom-up: never seal the player in mid-build
  return cells, doorX
end
STEP.buildRoom = function(a)
  local args = a.args or {}
  local mat = args.material or "STNE"
  if not a._cells then
    local x, y, w, h = args.x, args.y, args.w or 10, args.h or 8
    local px, py = floor(R.P.x), floor(R.P.y)
    if px >= x and px <= x + w - 1 and py >= y and py <= y + h - 1 then
      return "fail", "you're standing in the build area — move aside first"
    end
    local cells, doorX = roomCells(args)
    local have = (R.inv(mat) or 0) + cInv(mat)
    if have < #cells then return "fail", "need " .. (#cells - have) .. " more " .. R.nice(mat) end
    a._cells = cells; a._doorX = doorX; a._i = 1; a._placed = 0
  end
  if a._i > #a._cells then
    local wantTorches = args.torches or 0
    if (a._torchN or 0) < wantTorches then
      a._torchN = a._torchN or 0
      local spacing = max(2, floor((args.w - 2) / max(1, wantTorches)))
      local tx, ty = args.x + 1 + a._torchN * spacing, args.y + 1
      pcall(R.actorLight, colonistActor(), tx, ty) -- best-effort; missing wood or a full spot just skips this one
      a._torchN = a._torchN + 1
      return "running"
    end
    C._buildRoomStartSaid, C._buildRoomHalfSaid = nil, nil
    return "success", a._placed
  end
  if not C._buildRoomStartSaid then C._buildRoomStartSaid = true; sayC("Framing up the room.") end
  if not C._buildRoomHalfSaid and a._i > #a._cells / 2 then C._buildRoomHalfSaid = true; sayC("Halfway through the walls.") end
  local cell = a._cells[a._i]
  if not progressCheck(a) then C._buildRoomStartSaid, C._buildRoomHalfSaid = nil, nil; return "fail", "stuck" end
  if cInv(mat) < 1 then return "fail", "ran out of " .. R.nice(mat) end
  local arrived = navigateTo(a, cell.x, cell.y, 14)
  if not arrived then return "running" end
  local ok, why = R.actorPlace(colonistActor(), mat, cell.x, cell.y)
  if ok then a._placed = a._placed + 1
  elseif why and why:find("^no ") then return "fail", why end -- otherwise (occupied/player there): skip, never overwrite
  a._i = a._i + 1
  a._pgFrame = R.frame
  return "running"
end

STEP.buildShaft = function(a) -- a proper mine entrance: a narrow vertical dig with torches every N px
  local args = a.args or {}
  a._y = a._y or args.y
  local targetY = args.y + (args.depth or 100)
  if a._y >= targetY then return "success" end
  if not progressCheck(a) then return "fail", "stuck" end
  local arrived = navigateTo(a, args.x, a._y, 10)
  if not arrived then return "running" end
  if (R.frame - (a._lastHit or -99)) < MINE_CD then return "running" end
  a._lastHit = R.frame
  tryMineAt(args.x - 1, a._y); tryMineAt(args.x + 1, a._y)
  local every = args.torchEvery or 40
  if every > 0 and (a._y - args.y) % every < 3 then pcall(R.actorLight, colonistActor(), args.x + 3, a._y) end
  a._y = a._y + 3
  a._pgFrame = R.frame
  return "running"
end

STEP.bridge = function(a) -- a horizontal buildWall by another name
  local args = a.args or {}
  a.args = { x1 = args.x1, y1 = args.y, x2 = args.x2, y2 = args.y, element = args.material }
  return STEP.buildWall(a)
end

STEP.stairs = function(a)
  local args = a.args or {}
  local mat = args.material or "STNE"
  if not a._cells then
    local cells = {}; local dir = args.dir or 1; local w, h = args.w or 8, args.h or 8
    for i = 0, w - 1 do cells[#cells + 1] = { x = args.x + dir * i, y = args.y + floor(i * h / w) } end
    a._cells = cells; a._i = 1
  end
  if a._i > #a._cells then return "success" end
  local cell = a._cells[a._i]
  if cInv(mat) < 1 then return "fail", "ran out of " .. R.nice(mat) end
  if not progressCheck(a) then return "fail", "stuck" end
  local arrived = navigateTo(a, cell.x, cell.y, 14)
  if not arrived then return "running" end
  local ok, why = R.actorPlace(colonistActor(), mat, cell.x, cell.y)
  if not ok and why and why:find("^no ") then return "fail", why end
  a._i = a._i + 1
  a._pgFrame = R.frame
  return "running"
end

-- ================================================================ world index (the player 20:48: "he should have
-- an index of everything in the current environment and what we have"). Refreshed roughly every 2s, cheap
-- to compute, read-only for every consumer: the scripted brain, the chat templates below, and the compact
-- JSON state handed to the local model driver.
local lastMinedByPlayer, lastCraftedByPlayer = nil, nil
hook(R.hooks.mine, function(el, n)
  local ORE = { COAL = 1, IRON = 1, GOLD = 1, CU = 1, GRNT = 1, WOOD = 1, QRTZ = 1, DU = 1, URAN = 1, GOO = 1 }
  if ORE[el] then lastMinedByPlayer = { el = el, at = R.frame } end
end)
hook(R.hooks.craft, function(rc) lastCraftedByPlayer = { out = rc.out, at = R.frame } end)

-- Perf (21:2x): was sweeping the whole ~600x380 canvas every 120 frames - a real spike. Now a small box
-- around the player, coarser step, and a longer interval (the player's own guidance: "at most every 2s" - this
-- is 4s, deliberately conservative since it's not on anything time-critical).
local function refreshIndex()
  if not C.active or R.frame % 240 ~= 0 then return end
  local idx = {}
  local counts = {}
  local px, py = floor(R.P.x - R.cam.x), floor(R.P.y - R.cam.y)
  local x0, x1 = max(R.M, px - 120), min(R.W - R.M - 1, px + 120)
  local y0, y1 = max(R.M, py - 100), min(R.H - R.M - 1, py + 100)
  for sy = y0, y1, 8 do for sx = x0, x1, 8 do
    local p = sim.partID(sx, sy)
    if p then
      local nm = R.nameOf(sim.partProperty(p, "type"))
      if nm == "LAVA" or nm == "FIRE" or nm == "ACID" or nm == "PLSM" then
        local wx = sx + R.cam.x
        local dir = (wx > R.P.x + 24) and "east" or (wx < R.P.x - 24 and "west" or "nearby")
        local e = counts[nm]; if not e then e = { n = 0, dirs = {} }; counts[nm] = e end
        e.n = e.n + 1; e.dirs[dir] = (e.dirs[dir] or 0) + 1
      elseif R.MINEABLE[nm] then
        local wx = sx + R.cam.x
        local dx = wx - R.P.x
        local dir = (abs(dx) < 24) and "right here" or (dx > 0 and "east of us" or "west of us")
        local e = counts[nm]; if not e then e = { n = 0, dirs = {} }; counts[nm] = e end
        e.n = e.n + 1; e.dirs[dir] = (e.dirs[dir] or 0) + 1
      end
    end
  end end
  local resources = {}
  idx.hazards = {}
  for nm, info in pairs(counts) do
    if nm == "LAVA" or nm == "FIRE" or nm == "ACID" or nm == "PLSM" then
      local bestDir, bestN = "nearby", 0
      for d, n in pairs(info.dirs) do if n > bestN then bestN = n; bestDir = d end end
      idx.hazards[#idx.hazards + 1] = { el = nm, n = info.n, dir = bestDir }
    else
      local bestDir, bestN = "nearby", 0
      for d, n in pairs(info.dirs) do if n > bestN then bestN = n; bestDir = d end end
      resources[#resources + 1] = { el = nm, n = info.n, dir = bestDir }
    end
  end
  table.sort(resources, function(a, b) return a.n > b.n end)
  table.sort(idx.hazards, function(a, b) return a.n > b.n end)
  idx.resources = resources

  idx.stations = {}
  for _, st in ipairs(R.stations or {}) do idx.stations[#idx.stations + 1] = { kind = st.kind, x = st.x, y = st.y } end
  idx.machines = {}
  if R.machines then for _, m in ipairs(R.machines) do idx.machines[#idx.machines + 1] = { kind = m.kind, disabled = m.disabled } end end

  local q = R.QUESTS and R.QUESTS[R.quest]
  idx.questTxt = q and q.txt or nil
  idx.questMissing, idx.questRecipe = nil, nil
  if q then
    for _, r in ipairs(R.RECIPES or {}) do
      if r.txt and q.txt and q.txt:lower():find(r.txt:lower(), 1, true) then
        local missing = {}
        for item, n in pairs(r.need or {}) do
          local have = (R.inv(item) or 0) + cInv(item)
          if have < n then missing[#missing + 1] = { item = item, need = n - have } end
        end
        idx.questMissing = missing; idx.questRecipe = r.out
        break
      end
    end
  end

  idx.o2 = R.o2; idx.gas = R.gas
  idx.biome = R.biomeAt and R.biomeAt(floor(R.P.x)) or nil
  idx.depth = floor(R.P.y - R.surfaceAt(floor(R.P.x)))
  idx.recentMine = lastMinedByPlayer
  idx.recentCraft = lastCraftedByPlayer
  C.index = idx
end
local function dirFor(el)
  local idx = C.index
  if not idx or not idx.resources then return nil end
  for _, r in ipairs(idx.resources) do if r.el == el then return r.dir end end
  return nil
end
function R.companionIndex() return C.index end

-- ================================================================ C.cmd: the public action API
-- C.cmd(name, args, from) replaces the current action outright (so every command is interruptible by
-- construction - there is only ever one live action) and returns true/false, reason.
-- `from` is "manual" (hub/tests/chat replies), "model" (companion_driver.py), or "scripted" (this file).
local C_cmd
local function resetAreaMilestones(name)
  -- Milestone flags live on R.COMP so a fresh C.action table (re-issued digArea while already digging)
  -- cannot re-fire start/halfway chat; only clear when leaving that task or starting a new one after idle.
  if name == "digArea" then
    if not (C.action and C.action.name == "digArea" and C.action.status == "running") then
      C._digAreaStartSaid, C._digAreaHalfSaid = nil, nil
    end
  else
    C._digAreaStartSaid, C._digAreaHalfSaid = nil, nil
  end
  if name == "buildRoom" then
    if not (C.action and C.action.name == "buildRoom" and C.action.status == "running") then
      C._buildRoomStartSaid, C._buildRoomHalfSaid = nil, nil
    end
  else
    C._buildRoomStartSaid, C._buildRoomHalfSaid = nil, nil
  end
end
-- `meta` (internal only, 4th arg): { inChain=true } marks the action as part of a chain so a later
-- failure is eligible for one re-plan attempt (see attemptChainReplan below); { replan=true } consumes
-- that chain's single re-plan credit. External callers (chat, model driver, hub) never pass this.
C_cmd = function(name, args, from, meta)
  if not C.active or C.dead then return false, "colonist not active" end
  local key = (name == "goto") and "goto_" or name
  if not STEP[key] then return false, "unknown command: " .. tostring(name) end
  resetAreaMilestones(name)
  C.action = { name = name, args = args or {}, status = "running", start = R.frame, from = from or "manual",
    inChain = meta and meta.inChain or false }
  if meta and meta.replan then C._chainReplans = (C._chainReplans or 0) + 1 end
  return true
end
C.cmd = C_cmd
R.companionCmd = C_cmd
-- enqueueChain: run a list of {name,args} in order, one at a time, only advancing when the previous step
-- reports "success" (a "fail" anywhere drops the rest of the chain and reports why). This is how multi-step
-- asks ("gather -> return -> craft") get chained from either the chat templates or the caller driver.
function C.enqueueChain(steps, from)
  if not steps or #steps == 0 then return false end
  C.queue = {}
  for i = 2, #steps do C.queue[#C.queue + 1] = steps[i] end
  local first = steps[1]
  C._chainReplans = 0
  return C_cmd(first.name, first.args, from or "manual", { inChain = true })
end
R.companionEnqueue = C.enqueueChain
-- Chain re-plan on fail (companion-redesign-gap-2026-08-30.md #2): a chain used to drop entirely on the
-- first failed step. Now, a step that fails inside a chain gets exactly ONE reason-aware re-plan attempt
-- per chain (C._chainReplans caps it) before falling back to the old drop-cleanly behaviour:
--  - "stuck" (progressCheck timeout): just retry the identical step fresh - a real STUCK_FRAMES timeout
--    on a moving target (player relocated, path briefly blocked) is often transient.
--  - a material shortage ("ran out of X" / "need N more X" / "none in inventory" - place/buildWall/
--    buildRoom/stairs all report one of these shapes): insert a `fetch` for the missing item ahead of a
--    retry of the same failed step, so "build me a house" that runs out of stone goes and mines more
--    stone instead of just giving up with the walls half built.
-- Any other failure reason (no target, too hard, target fled, unknown command, ...) has no plausible
-- automatic re-plan and still drops the chain exactly as before.
local function attemptChainReplan(a, detail)
  if not a.inChain or (C._chainReplans or 0) >= 1 then return false end
  if not detail or type(detail) ~= "string" then return false end
  if detail == "stuck" then
    C_cmd(a.name, a.args, a.from, { inChain = true, replan = true })
    sayC("Let me try that again.")
    return true
  end
  local shortage = detail == "none in inventory" or detail:find("^ran out of ") or detail:find("^need %d+ more ")
  if shortage then
    local item = a.args and (a.args.material or a.args.element)
    if item then
      local n = tonumber(detail:match("need (%d+) more")) or 8
      table.insert(C.queue, 1, { name = a.name, args = a.args })
      C_cmd("fetch", { item = item, n = n }, a.from, { inChain = true, replan = true })
      sayC("Out of " .. R.nice(item) .. " - grabbing more first.")
      return true
    end
  end
  return false
end
function R.companionHeartbeat() C.lastHeartbeat = R.frame; return true end
-- companion_driver.py's fast chat-polling entry point: separate from core's R.chatPending so a slow model
-- never races core's own ~0.5s fallback (see the drain-on-send in the R.hooks.chat handler below, and the
-- local timeout watchdog in the tick handler that answers from templates if the caller takes too long).
function R.companionChatPending(consume)
  local out = {}
  for i, m in ipairs(C.chatQueue) do out[i] = { text = m.text, at = m.at } end
  if consume ~= false then C.chatQueue = {} end
  return out
end
function R.companionSetMode(m) if m == "auto" or m == "manual" or m == "model" then C.mode = m; return true end; return false end
function R.companionDismiss()
  C.active = false; C.dismissed = true; C.action = nil; C.override = nil; C.queue = {}
  C.chatQueue = {}; C.mode = "manual"; C.sayMsg = nil; C.sayAt = nil
  return true
end
function R.companionRecall()
  if C.dead then return false, "dead" end
  C.dismissed = false; C.active = true
  C.action = { name = "follow", args = {}, status = "running", start = R.frame or 0, from = "manual" }
  C.mode = "auto"
  return true
end
-- Swinging at the companion used to do nothing at all -- she had a full hp/death system
-- (enemy touch damage, health bar, R.companionKill respawn) but nothing ever called into it
-- from the player's own attacks. This is that missing hook, same shape as enemy damage.
function R.damageCompanion(dmg, fromx, fromy)
  if not C.active or C.dead then return false end
  C.hp = max(0, C.hp - dmg); C.hurtAt = R.frame
  local sign = (C.x - (fromx or C.x) >= 0) and 1 or -1
  C.vx = sign * 1.6; C.vy = -1.8
  if C.hp <= 0 then R.companionKill() end
  return true
end
function R.companionKill() -- test hook: verify death/respawn without waiting for a real enemy
  if not C.active or C.dead then return false end
  C.dead = true; C.deadAt = R.frame; C.action = nil; C.override = nil; C.queue = {}   -- F2: clear queued chain too; would otherwise replay step-by-step after revival
  R.say((C.name or "Aster") .. " is down!")
  return true
end

-- ================================================================ chat: answer the player's Enter-messages
-- Template + broad-intent fallback so the colonist is conversational with NO model loaded. When
-- companion_driver.py is live (mode=="model" + fresh heartbeat) chat is also queued for the driver, but
-- player commands always execute immediately via R.companionHandleChat.
local EL_WORDS = { iron = "IRON", coal = "COAL", gold = "GOLD", copper = "CU", wood = "WOOD", stone = "STNE",
  rock = "STNE", clay = "CLST", quartz = "QRTZ", sand = "SAND", ice = "ICE", titanium = "TTAN",
  uranium = "URAN", diamond = "DMND", steel = "STEL" }
local MANUAL_TASK_NAMES = {
  mine = 1, mineNearest = 1, chop = 1, fetch = 1, place = 1, buildWall = 1, build = 1, craft = 1,
  give = 1, take = 1, light = 1, clearTrees = 1, digArea = 1, buildRoom = 1, buildShaft = 1,
  bridge = 1, stairs = 1, fight = 1,
}
local function isManualTaskName(name)
  return name == "goto" or MANUAL_TASK_NAMES[name] ~= nil
end
local function parseElement(msg)
  local m = (msg or ""):lower()
  for word, el in pairs(EL_WORDS) do if m:find(word, 1, true) then return el end end
  return nil
end
local function parseCount(msg, default)
  return tonumber((msg or ""):match("(%d+)")) or default or 1
end
local function modelDriverLive()
  return C.mode == "model" and (R.frame - (C.lastHeartbeat or -999999)) <= MODEL_TIMEOUT
end
local function chatSetsManualMode(msg, acted)
  if not acted then return false end
  local m = (msg or ""):lower()
  if m:find("follow") then return false end
  if m:find("stay") or m:find("wait here") then return false end
  if m:find("come here") or m:find("come to me") or m == "come" then return false end
  if m:find("doing") or m:find("status") or m:find("what's up") or m:find("whats up") then return false end
  return true
end
function manualTaskActive()
  if C.queue and #C.queue > 0 then return true end
  local a = C.action
  if not a or a.status ~= "running" then return false end
  if a.name == "follow" or a.name == "stay" then return false end
  return a.from == "manual" or isManualTaskName(a.name)
end
local function templateReply(msg)
  local m = (msg or ""):lower()
  if m:find("follow") or m:find("come back") or m:find("recall") then
    R.companionRecall(); return "On my way!", true
  end
  if m:find("go away") or m:find("dismiss") or m:find("leave me") or m:find("get lost")
      or m:find("stop following") or m == "bye" then
    R.companionDismiss(); return "Okay — I'll stay out of your way.", true
  end
  if m:find("stay") or m:find("wait here") then C_cmd("stay", {}, "manual"); return "Staying put.", true end
  if m:find("come here") or m:find("come to me") or m == "come" then
    C_cmd("goto", { x = floor(R.P.x), y = floor(R.P.y) }, "manual"); return "Coming!", true
  end
  if (m:find("cut") or m:find("chop") or m:find("clear")) and (m:find("tree") or m:find("trees") or m:find("wood")) then
    C.enqueueChain({
      { name = "clearTrees", args = viewRect(100, 80) },
      { name = "give", args = { item = "WOOD" } },
    }, "manual")
    return "On it — clearing the trees nearby.", true
  end
  if m:find("dig") and (m:find("hole") or m:find("pit") or m:find("big")) then
    C.enqueueChain({ { name = "digArea", args = viewRect(40, 30) } }, "manual")
    return "Digging that out for you.", true
  end
  if m:find("build") and (m:find("house") or m:find("room") or m:find("shelter")) then
    local x, y, w, h = houseSite(10, 8)
    if playerInRect(x, y, x + w - 1, y + h - 1) then
      return "Need a bit more space — move so I'm not building where you're standing.", false
    end
    C.enqueueChain({
      { name = "buildRoom", args = { x = x, y = y, w = w, h = h, material = "STNE", door = true, torches = 2 } },
    }, "manual")
    return "I'll put up a room with walls, floor, and a door.", true
  end
  for word, el in pairs(EL_WORDS) do
    if m:find(word, 1, true) and (m:find("mine") or m:find("get") or m:find("fetch") or m:find("grab") or m:find("dig")) then
      C_cmd("mineNearest", { element = el }, "manual"); return "Sure, grabbing some " .. R.nice(el) .. ".", true
    end
  end
  if m:find("build") and m:find("wall") then
    local el; for word, e in pairs(EL_WORDS) do if m:find(word, 1, true) then el = e; break end end
    el = el or (next(C.inv))
    if el and cInv(el) > 0 then
      local x0, y0 = floor(C.x), floor(C.y); local n = min(cInv(el), 6)
      C_cmd("buildWall", { x1 = x0, y1 = y0, x2 = x0 + (C.face or 1) * n, y2 = y0, element = el }, "manual")
      return "On it - walling up with " .. R.nice(el) .. ".", true
    end
    return "I don't have any blocks for that yet - hand me some or tell me to fetch some.", false
  end
  if m:find("fight") or m:find("attack") or m:find("kill") then C_cmd("fight", {}, "manual"); return "Going in!", true end
  if m:find("doing") or m:find("status") or m:find("what's up") or m:find("whats up") then
    local a = C.action
    if not a then return "Just keeping an eye on things.", false end
    if a.name == "follow" then return "Following you.", false end
    if a.name == "fight" then return "Fighting off a threat!", false end
    if a.name == "mine" or a.name == "mineNearest" or a.name == "chop" or a.name == "fetch" then
      return "Digging up some " .. R.nice((a.args and a.args.element) or "resources") .. ".", false
    end
    return "Working on it (" .. a.name .. ").", false
  end
  if m:find("air") or m:find("oxygen") or m:find("breath") then
    local o2 = R.o2 or 100
    if o2 > 70 then return "Air's good here.", false end
    if o2 > 40 then return "Air's a bit thin - could use some ventilation.", false end
    return "Air's dangerously thin down here!", false
  end
  if m:find("next") or m:find("goal") or m:find("need") then
    local q = R.QUESTS and R.QUESTS[R.quest]
    if q then return "Next up: " .. q.txt, false end
    return "No pressing goal right now - explore, or tell me what to do.", false
  end
  return nil, false
end
local function companionFallbackIntent(msg)
  local m = (msg or ""):lower()
  local el, n = parseElement(m), parseCount(m, 1)
  if m:find("bring") or m:find("give me") or m:find("hand me") or m:find("get me") or m:find("fetch me") then
    if el then
      C.enqueueChain({
        { name = "fetch", args = { item = el, n = n } },
        { name = "give", args = { item = el, n = n } },
      }, "manual")
      return "I'll bring you " .. n .. " " .. R.nice(el) .. ".", true
    end
  end
  if m:find("mine") or m:find("gather") or m:find("collect") or (m:find("get") and not m:find("get me")) or m:find("grab") then
    if el then
      C_cmd("mineNearest", { element = el }, "manual")
      return "Mining " .. R.nice(el) .. ".", true
    end
    local r = C.index and C.index.resources and C.index.resources[1]
    if r then
      C_cmd("mineNearest", { element = r.el }, "manual")
      return "I'll grab some " .. R.nice(r.el) .. " nearby.", true
    end
  end
  if m:find("tree") or m:find("trees") or (m:find("wood") and (m:find("cut") or m:find("chop") or m:find("clear") or m:find("gather"))) then
    C.enqueueChain({
      { name = "clearTrees", args = viewRect(100, 80) },
      { name = "give", args = { item = "WOOD" } },
    }, "manual")
    return "Clearing trees nearby.", true
  end
  if m:find("craft") or m:find("make") or m:find("build") then
    for _, rc in ipairs(R.RECIPES or {}) do
      local label = (rc.txt or rc.out or ""):lower()
      if label ~= "" and (m:find(label, 1, true) or m:find((rc.out or ""):lower(), 1, true)) then
        C_cmd("craft", { recipe = rc.txt or rc.out }, "manual")
        return "Crafting " .. (rc.txt or R.nice(rc.out)) .. ".", true
      end
    end
    if el then
      for _, rc in ipairs(R.RECIPES or {}) do
        if rc.out == el then
          C_cmd("craft", { recipe = rc.txt or rc.out }, "manual")
          return "Making " .. R.nice(el) .. ".", true
        end
      end
    end
  end
  if m:find("light") or m:find("torch") then
    local px, py = floor(R.P.x), floor(R.P.y)
    C_cmd("light", { x = px + (R.P.face or 1) * 8, y = py - 4 }, "manual")
    return "Placing a torch.", true
  end
  if m:find("shaft") or (m:find("dig") and (m:find("down") or m:find("shaft"))) then
    local px, py = floor(R.P.x), floor(R.P.y)
    C.enqueueChain({ { name = "buildShaft", args = { x = px, y = py, depth = parseCount(m, 80), torchEvery = 40 } } }, "manual")
    return "Digging a shaft down.", true
  end
  if m:find("bridge") then
    local px, py = floor(R.P.x), floor(R.P.y); local span = parseCount(m, 12)
    C_cmd("bridge", { x1 = px - span, x2 = px + span, y = py, material = el or "STNE" }, "manual")
    return "Building a bridge.", true
  end
  if m:find("stair") or m:find("steps") then
    local px, py = floor(R.P.x), floor(R.P.y); local run = parseCount(m, 8)
    C_cmd("stairs", { x = px, y = py, w = run, h = run, dir = (R.P.face or 1), material = el or "STNE" }, "manual")
    return "Building stairs.", true
  end
  if m:find("quest") and (m:find("help") or m:find("what") or m:find("need") or m:find("do")) then
    local idx = C.index
    if idx and idx.questTxt then
      if idx.questMissing and #idx.questMissing > 0 then
        local parts = {}
        for _, miss in ipairs(idx.questMissing) do parts[#parts + 1] = (miss.need or 1) .. " " .. R.nice(miss.item) end
        return "For the quest we still need: " .. table.concat(parts, ", ") .. ".", false
      end
      return "Quest: " .. idx.questTxt, false
    end
    return "No active quest right now.", false
  end
  return nil, false
end
function R.companionHandleChat(msg)
  local reply, acted = templateReply(msg)
  if not acted then
    local fReply, fActed = companionFallbackIntent(msg)
    if fActed then reply, acted = fReply, true
    elseif fReply then reply = fReply end
  end
  if chatSetsManualMode(msg, acted) then C.mode = "manual" end
  return reply or "Got it.", acted
end
hook(R.hooks.chat, function(msg)
  if not C.active or C.dead then return end
  if modelDriverLive() then C.chatQueue[#C.chatQueue + 1] = { text = msg, at = R.frame } end
  local ok, reply = pcall(R.companionHandleChat, msg)
  if ok and reply then sayC(reply) end
end)

-- ================================================================ default SCRIPTED brain (no model needed)
-- Only proposes a new `action` when idle (nil) or already following - never yanks a real in-progress
-- manual/model task. Everything here calls the exact same C.cmd/STEP surface a model or a person would use.
-- (lastMinedByPlayer/lastCraftedByPlayer are declared up in the world-index section, above.)
-- the player 21:12/21:16 (non-negotiable): "ONLY DO WHAT HE ASKED. No self-directed mining, no unsolicited
-- gifts, no wandering off. Between tasks he follows and stays quiet." So this is now deliberately thin:
-- the only things it ever starts on its own are a defensive engagement (a "being attacked" reflex, not
-- self-directed work) and following when there's nothing else going on. Mining, fetching, building, and
-- lighting only ever happen because a real command (chat/model/hub) asked for them.
local function idleOrFollowing(a) return a == nil or a.name == "follow" or a.status ~= "running" end
local function scriptedBrainTick()
  if manualTaskActive() then return end
  if C.mode ~= "auto" then return end
  if R.frame % 20 ~= 0 then return end -- throttle: decisions don't need to be per-frame
  local a = C.action
  if not idleOrFollowing(a) then return end -- something (manual/model/current task) already owns the wheel

  if findFightTarget(90) then C_cmd("fight", {}, "scripted"); return end
  if not a or a.name ~= "follow" then C_cmd("follow", {}, "scripted") end
end

-- ================================================================ no scripted flavor-narration by design
-- (the player 21:06, design-companion-core.md §5): "no templated chatter - the caller speaks, and when it is
-- unavailable he stays useful and QUIET." An earlier version of this file had the scripted brain narrate
-- biome/depth/night/quest/ore-sighting flavor lines on its own; that is now deliberately removed. All of
-- that context still lives in C.index/R.companionState() for the caller to comment on if and when it wants
-- to - the scripted layer itself only ever speaks for a concrete reflex (self-defense, teleport-home) or a
-- concrete task outcome (a plan step's own progress/success/failure report), never as ambient color.

-- ================================================================ safety overrides (can interrupt ANY action,
-- model-issued or not)
-- NOTE: there is deliberately no autonomous delivery/give behaviour here. the player 21:12/21:16 (non-negotiable,
-- supersedes design-companion-core.md §3's pack-full/quest-need auto-triggers): "ONLY DO WHAT HE ASKED...
-- no unsolicited gifts." `give` only ever runs as an explicit step in a chain the player/model asked for
-- (a chat command, or the last step of a model-issued plan) - see STEP.give / C.enqueueChain above.

local function checkTeleportHome()
  local dx, dy = C.x - R.P.x, C.y - R.P.y
  if dx * dx + dy * dy > TELEPORT_DIST * TELEPORT_DIST then
    C.x = R.P.x - (R.P.face or 1) * 10; C.y = R.P.y; C.vx, C.vy = 0, 0
    C.action = { name = "follow", args = {}, status = "running", start = R.frame, from = "scripted" }
    narrate("Whoa, lost you for a second - catching up!", true)
  end
end
local function checkSelfDefense()
  if not R.enemyList then return end
  for _, e in ipairs(R.enemyList()) do
    if not e.dead then
      local dx, dy = e.x - C.x, e.y - C.y
      if abs(dx) <= (e.w or 4) + CBOXR + 2 and abs(dy) <= (e.h or 8) + 6 then
        if not e.compTouchCd or e.compTouchCd <= R.frame then
          C.hp = max(0, C.hp - (e.dmg or 5)); C.hurtAt = R.frame; e.compTouchCd = R.frame + 30
        end
        if not (C.override and C.override.name == "fight" and C.override.target == e) then
          C.override = { name = "fight", args = {}, target = e, status = "running", start = R.frame, from = "scripted" }
        end
        return
      end
    end
  end
end
local function checkModelWatchdog()
  if C.mode == "model" and (R.frame - (C.lastHeartbeat or -999999)) > MODEL_TIMEOUT then
    C.mode = "auto"
    sayC("(driver's quiet - I've got this myself)")
  end
end

-- ================================================================ life/death
local function reviveNear()
  C.dead = false; C.hp = C.maxhp; C.x = R.P.x - (R.P.face or 1) * 12; C.y = R.P.y; C.vx, C.vy = 0, 0
  C.action = { name = "follow", args = {}, status = "running", start = R.frame, from = "scripted" }
  C._hits = {}
  sayC("Back on my feet!")
end

-- ================================================================ perf telemetry (@perf)
-- He asked directly: "get back stats about how fast the game is running and what could be lagging."
-- Extends the existing R.perf EMA machinery (rpg.lua:1000-1034, tag->ms/skip, already driving the
-- adaptive throttler) rather than replacing it -- this module only ADDS: real measured frame period
-- (never a requested step count -- knowledge/PERF-REPORT.md records 500 requested frames producing
-- about 3 real ones), a distribution (median/p95/worst, not just a mean -- the spikes are the lag),
-- particle count BY TYPE, live air-sim state (both the R.fast flag and the real sim.airMode()), and
-- which hooks are currently throttled. Both an in-game panel (toggle key "i") and an append-only log
-- file (perf-log.jsonl, written into the game's own ddir -- same relative-path convention as
-- feedback.txt/rpg-save.json -- so it opens with any text editor, no agent required).
--
-- COST DISCIPLINE: a full sim.parts() type tally measured 13-24ms live against both the lab and his
-- real session (knowledge/PERF-REPORT.md, 2026-09-01 @perf section) -- close to or above the entire
-- 16.7ms frame budget by itself. Running that every frame would BE the lag it exists to diagnose, so
-- it is throttled to once every PERFHUD_COMPOSITION_FRAMES real ticks; the frame-period sample and
-- log write are cheap (a handful of table writes) and run every tick / every PERFHUD_LOG_FRAMES ticks
-- respectively. This module's own per-tick cost is measured and shown in the panel (R.PERFHUD.selfMs)
-- so "is the telemetry itself a cost" is answered with a live number, not a promise.
local PERFHUD_LOG_PATH = "perf-log.jsonl"
local PERFHUD_BUF_MAX = 240              -- ring buffer of real tick-to-tick os.clock() deltas, ms
local PERFHUD_STATS_FRAMES = 60          -- recompute median/p95/worst this often (real ticks)
local PERFHUD_COMPOSITION_FRAMES = 1200  -- full particle-type tally this often -- see cost note above
local PERFHUD_LOG_FRAMES = 300           -- append one log line this often

R.PERFHUD = R.PERFHUD or {
  on = false,                   -- panel toggle (key "i")
  buf = {},                     -- ring buffer of real frame deltas (ms), oldest first
  lastClock = nil,
  stats = nil,                  -- {n,mean,median,p95,worst,best}, refreshed every PERFHUD_STATS_FRAMES
  lastStatsAt = 0,
  composition = nil,            -- {total,top={{name,n,pct}},atFrame,tookTicks}, refreshed every PERFHUD_COMPOSITION_FRAMES
  lastCompositionAt = -PERFHUD_COMPOSITION_FRAMES,  -- so the first tick starts a scan, not after a full wait
  scan = nil,                    -- in-progress incremental sim.parts() scan: {f,s,var,counts,total,startedAt}, see perfScanStep
  lastLogAt = -PERFHUD_LOG_FRAMES,
  selfMs = 0,                   -- EMA of this module's own per-tick cost
}

local function perfStatsOf(buf)
  local n = #buf
  if n < 2 then return { n = n, mean = 0, median = 0, p95 = 0, worst = 0, best = 0 } end
  local sorted = {}
  for i = 1, n do sorted[i] = buf[i] end
  table.sort(sorted)
  local sum = 0; for i = 1, n do sum = sum + sorted[i] end
  return {
    n = n, mean = sum / n,
    median = sorted[floor(n * 0.5) + 1] or sorted[n],
    p95 = sorted[math.ceil(n * 0.95)] or sorted[n],
    worst = sorted[n], best = sorted[1],
  }
end

-- minimal JSON string escaping, matching ui.lua's jsonStr convention (our own values are plugin
-- tags/element names -- no exotic chars in practice, but this stays correct if that ever changes).
local function perfJsonStr(s)
  s = tostring(s):gsub('[\\"]', "\\%0"):gsub("\n", "\\n")
  return '"' .. s .. '"'
end

-- INCREMENTAL by design, not a single blocking pass: a straight-through `for i in sim.parts() do`
-- tally measured 13-24ms for ~80-112k live particles (knowledge/PERF-REPORT.md, 2026-09-01 @perf
-- section) called stand-alone over the bridge -- and calling that SAME blocking scan from inside a
-- real tick hook produced a live, reproduced "Script not responding" freeze on the lab instance
-- (frame counter stuck, bridge connection resets) when it landed in the same tick as fresh terrain
-- streaming after a teleport into unexplored ground. Root cause not fully isolated (a second, calmer
-- attempt did not reproduce it), but the mechanism is plausible and the fix is cheap: `sim.parts()`
-- returns a real (f, s, var) Lua iterator triple, steppable by hand (verified live), so the scan is
-- spread across many ticks at a small bounded cost per tick instead of one large blocking call ever
-- entering a single tick's Lua budget. This is the actual fix, not just a lower-frequency guess.
local function perfScanStart()
  local f, s, var = sim.parts()
  R.PERFHUD.scan = { f = f, s = s, var = var, counts = {}, total = 0, startedAt = R.frame or 0 }
end

local PERFHUD_SCAN_CHUNK = 2000   -- particles visited per tick while a scan is in progress (~0.4ms/tick at the measured per-particle cost)

local function perfScanStep(PH)
  local sc = PH.scan
  if not sc then return end
  for _ = 1, PERFHUD_SCAN_CHUNK do
    local id = sc.f(sc.s, sc.var)
    if id == nil then
      local list = {}
      for nm, c in pairs(sc.counts) do list[#list + 1] = { nm, c } end
      table.sort(list, function(a, b) return a[2] > b[2] end)
      local top = {}
      for i = 1, min(6, #list) do top[i] = { name = list[i][1], n = list[i][2], pct = sc.total > 0 and (100 * list[i][2] / sc.total) or 0 } end
      PH.composition = { total = sc.total, top = top, atFrame = R.frame or 0, tookTicks = (R.frame or 0) - sc.startedAt }
      PH.scan = nil
      return
    end
    sc.var = id
    local nm = R.nameOf(sim.partProperty(id, "type")) or "?"
    sc.counts[nm] = (sc.counts[nm] or 0) + 1
    sc.total = sc.total + 1
  end
end

local function perfThrottledTags()
  local out = {}
  for tag, rec in pairs(R.perf or {}) do if (rec.skip or 1) > 1 then out[#out + 1] = tag .. "(1/" .. rec.skip .. ")" end end
  table.sort(out)
  return out
end

local function perfWriteLog(PH)
  local f = io.open(PERFHUD_LOG_PATH, "a")
  if not f then return end
  local st = PH.stats or perfStatsOf(PH.buf)
  local topStr = {}
  if PH.composition then
    for _, e in ipairs(PH.composition.top) do
      topStr[#topStr + 1] = string.format('{"name":%s,"n":%d,"pct":%.1f}', perfJsonStr(e.name), e.n, e.pct)
    end
  end
  local hookStr = {}
  for tag, rec in pairs(R.perf or {}) do
    hookStr[#hookStr + 1] = string.format('{"tag":%s,"ms":%.3f,"skip":%d}', perfJsonStr(tag), rec.ms, rec.skip or 1)
  end
  local throttledStr = {}
  for _, t in ipairs(perfThrottledTags()) do throttledStr[#throttledStr + 1] = perfJsonStr(t) end
  local okAir, air = pcall(sim.airMode)   -- real engine value; legal here -- this runs inside a genuine tick event
  local line = "{" ..
    '"ts":' .. perfJsonStr(os.date("!%Y-%m-%dT%H:%M:%SZ")) .. "," ..
    '"frame":' .. tostring(R.frame or 0) .. "," ..
    '"fps":' .. string.format("%.1f", st.mean > 0 and (1000 / st.mean) or 0) .. "," ..
    '"frameMs":{"mean":' .. string.format("%.2f", st.mean) .. ',"median":' .. string.format("%.2f", st.median) ..
      ',"p95":' .. string.format("%.2f", st.p95) .. ',"worst":' .. string.format("%.2f", st.worst) .. ',"n":' .. st.n .. "}," ..
    '"parts":' .. tostring(sim.partCount()) .. "," ..
    '"partsTop":[' .. table.concat(topStr, ",") .. "]," ..
    '"airFast":' .. tostring(R.fast == true) .. ',"airModeReal":' .. tostring(okAir and air or "null") .. "," ..
    '"hooks":[' .. table.concat(hookStr, ",") .. "]," ..
    '"throttled":[' .. table.concat(throttledStr, ",") .. "]," ..
    '"telemetrySelfMs":' .. string.format("%.4f", PH.selfMs) ..
  "}"
  f:write(line .. "\n")
  f:close()
end

local function drawPerfPanel()
  local PH = R.PERFHUD
  local st = PH.stats or perfStatsOf(PH.buf)
  local x, y = R.W - 210, 4
  local lines = {}
  lines[#lines + 1] = string.format("PERF (i to hide)  frame %d", R.frame or 0)
  lines[#lines + 1] = string.format("fps %.1f  ms mean %.1f med %.1f", st.mean > 0 and 1000 / st.mean or 0, st.mean, st.median)
  lines[#lines + 1] = string.format("p95 %.1f  worst %.1f  best %.1f", st.p95, st.worst, st.best)
  local okAir, air = pcall(sim.airMode)
  lines[#lines + 1] = string.format("parts %d   air: R.fast=%s real=%s", sim.partCount(), tostring(R.fast == true), okAir and tostring(air) or "?")
  local rows = {}
  for tag, rec in pairs(R.perf or {}) do rows[#rows + 1] = { tag, rec.ms, rec.skip or 1 } end
  table.sort(rows, function(a, b) return a[2] > b[2] end)
  for i = 1, min(4, #rows) do
    local r = rows[i]
    lines[#lines + 1] = string.format("  %-10s %6.2fms%s", r[1], r[2], r[3] > 1 and (" skip" .. r[3]) or "")
  end
  if PH.composition then
    lines[#lines + 1] = string.format("parts by type (@f%d):", PH.composition.atFrame)
    for i = 1, min(4, #PH.composition.top) do
      local e = PH.composition.top[i]
      lines[#lines + 1] = string.format("  %-8s %6d (%.0f%%)", e.name, e.n, e.pct)
    end
  end
  lines[#lines + 1] = string.format("telemetry cost: %.3fms/tick", PH.selfMs)
  local h = 10 + #lines * 11
  graphics.fillRect(x - 4, y - 2, 208, h, 10, 12, 16, 190)
  graphics.drawRect(x - 4, y - 2, 208, h, 90, 160, 200, 160)
  for i, ln in ipairs(lines) do graphics.drawText(x, y + (i - 1) * 11, ln, 190, 230, 210, 255) end
end

-- ================================================================ tick
hook(R.hooks.tick, function()
  do
    local okPH, errPH = pcall(function()
      local PH = R.PERFHUD
      local t0 = os.clock()
      if PH.lastClock then
        local dt = (t0 - PH.lastClock) * 1000
        if dt >= 0 and dt < 5000 then   -- guard against hot-reload/pause gaps corrupting the buffer
          local buf = PH.buf
          buf[#buf + 1] = dt
          if #buf > PERFHUD_BUF_MAX then table.remove(buf, 1) end
        end
      end
      PH.lastClock = t0
      local frame = R.frame or 0
      if frame - PH.lastStatsAt >= PERFHUD_STATS_FRAMES then PH.lastStatsAt = frame; PH.stats = perfStatsOf(PH.buf) end
      if not PH.scan and frame - PH.lastCompositionAt >= PERFHUD_COMPOSITION_FRAMES then PH.lastCompositionAt = frame; perfScanStart() end
      if PH.scan then perfScanStep(PH) end
      if frame - PH.lastLogAt >= PERFHUD_LOG_FRAMES then PH.lastLogAt = frame; perfWriteLog(PH) end
      PH.selfMs = PH.selfMs * 0.9 + (os.clock() - t0) * 1000 * 0.1
    end)
    if not okPH then R.lastErr = "companion.lua perfhud tick: " .. tostring(errPH) end
  end
  if C.needsPlace then
    C.x = (R.P and R.P.x or 0) - (R.P and R.P.face or 1) * 12; C.y = (R.P and R.P.y or 100); C.vx, C.vy = 0, 0
    C.needsPlace = false
  end
  if not C.active then return end
  if C.dead then
    if C.deadAt and R.frame - C.deadAt > REVIVE_DELAY then reviveNear() end
    return
  end
  checkTeleportHome()
  checkSelfDefense()
  checkModelWatchdog()
  refreshIndex()

  if C.override then
    local st = STEP[C.override.name](C.override)
    if st ~= "running" then C.override = nil end
  else
    local a = C.action
    if a and a.status == "running" then
      local st, detail = STEP[(a.name == "goto") and "goto_" or a.name](a)
      a.status = st; a.detail = detail
      if not a._advanced and st ~= "running" then
        a._advanced = true -- only ever act on a terminal status once, even though it stays terminal for several ticks
        if st == "success" and C.queue and #C.queue > 0 then
          local nxt = table.remove(C.queue, 1)
          C_cmd(nxt.name, nxt.args, a.from, { inChain = true })
        elseif st == "fail" then
          if not attemptChainReplan(a, detail) then
            if C.queue and #C.queue > 0 then C.queue = {} end -- chain re-plan exhausted (or n/a): drop cleanly
            if a.from == "scripted" then C.action = nil end -- let the scripted brain retry with a fresh pick
          end
        end
      end
    end
  end
  if C.mode == "manual" and not manualTaskActive() then C.mode = "auto" end
  scriptedBrainTick()

  if C.hp <= 0 and not C.dead then R.companionKill() end
  if C.sayMsg and R.frame - (C.sayAt or 0) > 150 then C.sayMsg = nil end
end)

-- present from the very first frame of a new world - never a summon/craft (the player 20:42)
hook(R.hooks.newworld, function()
  C.hp = C.maxhp; C.inv = {}; C.action = { name = "follow", args = {}, status = "running", start = R.frame, from = "scripted" }
  C.override = nil; C._hits = {}; C.dead = false; C.mode = "auto"; C.active = true; C.queue = {}
  C.dismissed = false
  C.needsPlace = true -- R.P isn't at its fresh spawn point yet when this hook fires; positioned next tick
  -- F3: 7 fields the original newworld reset missed. Ghost-frame (single 16ms
  -- visual artifact at the previous world's last position): C.x/y/vx/vy.
  -- chatQueue leak across worlds: chat messages queued in the prior world
  -- drain into the new one if not cleared. sayMsg/sayAt: stale chat bubble.
  C.x = 0; C.y = 0; C.vx = 0; C.vy = 0; C.chatQueue = {}; C.sayMsg = nil; C.sayAt = nil
end)
hook(R.hooks.sandbox, function() cGiveSelf("WOOD", 20) end)

-- ================================================================ draw (world space, before the player sprite)
local function drawCompanion()
  if not C.active or C.dead then return end
  local x, y = floor(C.x) - R.cam.x, floor(C.y) - R.cam.y
  if x < -20 or x > R.W + 20 or y < -20 or y > R.H + 20 then return end
  local hurt = C.hurtAt and (R.frame - C.hurtAt) < 12
  local skin = { 235, 190, 150 }; local shirt = hurt and { 255, 120, 60 } or { 90, 200, 140 }; local pants = { 60, 70, 60 }; local hair = { 200, 140, 40 }
  local f = C.face
  local moving = C.onGround and abs(C.vx) > 0.2
  local cyc = moving and floor(((C.anim or 0) / 3) % 4) or 0
  local legA = ({ 0, 1, 0, -1 })[cyc + 1]
  local bob = (cyc == 1 or cyc == 3) and 1 or 0
  local by = y - bob
  local function R_(xx, yy, w, h, c, a) graphics.fillRect(xx, yy, w, h, c[1], c[2], c[3], a or 255) end
  if not C.onGround then R_(x - 2, by - 4, 2, 3, pants); R_(x + 1, by - 5, 2, 3, pants)
  else R_(x - 2 + legA, by - 4, 2, 3, pants); R_(x + 1 - legA, by - 4, 2, 3, pants) end
  R_(x - 2, by - 8, 5, 4, shirt)
  R_(x - 2, by - 12, 5, 4, skin); R_(x - 2, by - 13, 5, 2, hair); R_(x + (f > 0 and -2 or 2), by - 11, 1, 2, hair)
  R_(x + (f > 0 and 1 or -1), by - 10, 1, 1, { 25, 25, 45 })
  if C.hp < C.maxhp then
    local bw = 14
    graphics.fillRect(x - 7, by - 18, bw, 2, 30, 10, 10, 200)
    graphics.fillRect(x - 7, by - 18, max(0, floor(bw * C.hp / C.maxhp)), 2, 90, 210, 120, 255)
  end
  -- Nameplate had no width cap: "Aster" is short so nothing looked wrong, but the name
  -- is player-settable and this draws centered on the colonist, so a long one ran off
  -- both sides over the world. Clamp to NAME_MAX chars with a "..." tail, same shape as
  -- the other draw-time clamps in this UI (guide.lua's e.label:sub(1, 22), ui.lua's
  -- "..." overflow line). Kept as plain locals inside drawCompanion -- no new global,
  -- nothing to forward-declare, so this cannot become another drawMenu/wrap nil-global.
  local NAME_MAX = 16
  local nm = C.name or "Aster"
  if #nm > NAME_MAX then nm = nm:sub(1, NAME_MAX - 3) .. "..." end
  graphics.drawText(x - #nm * 2, by - 24, nm, 200, 240, 210, 200)
  if C.sayMsg and R.frame - (C.sayAt or 0) < 150 then
    local msg = C.sayMsg; local w = #msg * 4 + 6
    graphics.fillRect(x - floor(w / 2), by - 38, w, 11, 20, 24, 22, 210)
    graphics.drawRect(x - floor(w / 2), by - 38, w, 11, 200, 230, 210, 200)
    graphics.drawText(x - floor(w / 2) + 3, by - 36, msg, 230, 245, 235, 255)
  end
end
hook(R.hooks.draw, function() local ok, err = pcall(drawCompanion); if not ok then R.lastErr = "companion.lua draw: " .. tostring(err) end end)
hook(R.hooks.key, function(k) if k == "i" and not R.chatOpen then R.PERFHUD.on = not R.PERFHUD.on; return true end end)
hook(R.hooks.drawHUD, function() if R.PERFHUD.on then local ok, err = pcall(drawPerfPanel); if not ok then R.lastErr = "companion.lua perfhud draw: " .. tostring(err) end end end)

-- ================================================================ compact state for the local-model driver
-- Kept small on purpose (a few hundred tokens once JSON-encoded) - see knowledge/design-companion-protocol.md.
function R.companionState()
  if not C.active then return { active = false } end
  local nearby = {}
  do
    local counts = {}
    local cam = R.cam
    for oy = -40, 40, 8 do for ox = -48, 48, 8 do
      local sx, sy = floor(C.x) + ox - cam.x, floor(C.y) + oy - cam.y
      if sx >= R.M and sx < R.W - R.M and sy >= R.M and sy < R.H - R.M then
        local p = sim.partID(sx, sy)
        if p then local nm = R.nameOf(sim.partProperty(p, "type")); counts[nm] = (counts[nm] or 0) + 1 end
      end
    end end
    local list = {}; for nm, n in pairs(counts) do list[#list + 1] = { nm, n } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    for i = 1, min(6, #list) do nearby[#nearby + 1] = { el = list[i][1], n = list[i][2] } end
  end
  local invList = {}; for k, v in pairs(C.inv) do if v > 0 then invList[#invList + 1] = { item = k, n = v } end end
  local depth = floor((C.y - R.surfaceAt(floor(C.x))) / 4)
  local chat = {}; do local n = #(R.chatLog or {}); for i = max(1, n - 5) , n do local m = R.chatLog[i]; if m then chat[#chat + 1] = { who = m.who, text = m.text } end end end
  return {
    active = true, dead = C.dead, hp = C.hp, maxhp = C.maxhp,
    x = floor(C.x), y = floor(C.y), depth = depth,
    biome = R.biomeAt and R.biomeAt(floor(C.x)) or nil,
    inv = invList,
    action = C.action and { name = C.action.name, status = C.action.status, from = C.action.from } or nil,
    player = { x = floor(R.P.x), y = floor(R.P.y), hp = R.hp, o2 = R.o2, hurtRecently = (R.hurt and (R.frame - R.hurt) < 60) or false },
    quest = (R.QUESTS and R.QUESTS[R.quest] and R.QUESTS[R.quest].txt) or nil,
    nearby = nearby, chat = chat,
    day = R.day, frame = R.frame,
  }
end
function R.companionStatus() return C.action and C.action.status or "idle" end

-- ================================================================ ensure the colonist exists even when this
-- file is (re)loaded into an already-running world (lab dev-loop, or added mid-session) - idempotent: only
-- fires once, since C.active persists across reloads via the R.COMP-survives pattern at the top of the file.
if R.active and R.P and not C.active and not C.dead and not C.dismissed then
  C.x = R.P.x - (R.P.face or 1) * 12; C.y = R.P.y; C.vx, C.vy = 0, 0
  C.active = true; C.action = { name = "follow", args = {}, status = "running", start = R.frame or 0, from = "scripted" }
end
