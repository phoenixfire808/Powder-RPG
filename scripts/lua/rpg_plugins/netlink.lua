-- netlink.lua — Phase 1 multiplayer transport primitive.
--
-- NOT registered in R.PLUGINS on purpose: this is a library, not an auto-loading plugin.
-- It installs no hooks and does nothing until something calls R.net.connect(). Load with
-- R.reloadPlugin("netlink").
--
-- Encodes the three API constraints proven in knowledge/design-multiplayer-implementation-
-- 2026-08-31.md, each of which cost real debugging time:
--   1. socket.tcp() only works inside a real TICK dispatch (AssertInterfaceEvent gate).
--   2. There is no socket.select in this build. A non-blocking connect() returns
--      nil,"timeout" and never completes on its own — you must re-call connect() until it
--      returns "already connected", which is the success signal.
--   3. receive() takes a BYTE COUNT ONLY. String patterns ("*l"/"*a") raise
--      'bad argument #1 to receive (number expected, got string)'. Read byte-wise.
--
-- Wire format: "<decimal length>\n<json payload>". json is a real global in this engine.

local R = PBX.state.rpg
R.net = R.net or {}

local MAX_READ_PER_TICK = 4096      -- bounds work per frame; sim runs ~36fps under load
local MAX_FRAME = 1024 * 256        -- refuse absurd length headers (untrusted input)

local Link = {}
Link.__index = Link

-- Open a link. Safe to call from tick context only (socket.tcp is interface-event gated).
function R.net.connect(host, port)
  local ok, sock = pcall(socket.tcp)
  if not ok or not sock then return nil, tostring(sock) end
  sock:settimeout(0)
  sock:connect(host, port)          -- returns nil,"timeout"; completion polled in poll()
  return setmetatable({
    sock = sock, host = host, port = port,
    state = "connecting", inbuf = "", outbuf = "", frames = {}, err = nil,
  }, Link)
end

function Link:isOpen() return self.state == "open" end

-- Queue a table for delivery. Actual bytes go out on the next poll().
function Link:send(tbl)
  if self.state == "closed" then return false, "closed" end
  local body = json.stringify(tbl)
  self.outbuf = self.outbuf .. #body .. "\n" .. body
  return true
end

-- Pop the next decoded inbound message, or nil.
function Link:receive()
  return table.remove(self.frames, 1)
end

function Link:close(why)
  if self.sock then pcall(function() self.sock:close() end) end
  self.state, self.err = "closed", why or self.err
end

local function parseFrames(self)
  while true do
    local nl = self.inbuf:find("\n", 1, true)
    if not nl then return end
    local len = tonumber(self.inbuf:sub(1, nl - 1))
    if not len or len < 0 or len > MAX_FRAME then
      return self:close("bad frame header")
    end
    if #self.inbuf < nl + len then return end          -- body not fully arrived yet
    local body = self.inbuf:sub(nl + 1, nl + len)
    self.inbuf = self.inbuf:sub(nl + len + 1)
    local ok, msg = pcall(json.parse, body)
    if ok then self.frames[#self.frames + 1] = msg end -- ignore undecodable frames
  end
end

-- Drive the link. Call exactly once per tick, from a real TICK dispatch.
function Link:poll()
  if self.state == "closed" then return end

  if self.state == "connecting" then
    -- No socket.select here: re-calling connect() is how the handshake is polled.
    local ok, err = self.sock:connect(self.host, self.port)
    if ok or err == "already connected" then
      self.state = "open"
    elseif err ~= "timeout" and err ~= "Operation already in progress" then
      return self:close(err)
    else
      return
    end
  end

  if #self.outbuf > 0 then
    local n, err = self.sock:send(self.outbuf)
    if n then
      self.outbuf = self.outbuf:sub(n + 1)
    elseif err ~= "timeout" then
      return self:close(err)
    end
  end

  for _ = 1, MAX_READ_PER_TICK do
    local ch, err, partial = self.sock:receive(1)   -- byte count only, never a pattern
    local got = ch or (partial ~= "" and partial or nil)
    if got then
      self.inbuf = self.inbuf .. got
    elseif err == "closed" then
      parseFrames(self)
      return self:close("peer closed")
    else
      break                                          -- timeout: nothing more this tick
    end
  end

  parseFrames(self)
end

-- ================================================================================
-- ADR-019: LAN model on top of the Phase-1 transport above -- relay client, shared
-- session-code auth, host/guest join flow (title-screen UI), position echo, and
-- chat riding the existing in-game chat. Still owns only this file end to end.
-- Draw/click/key/textinput below are only ever CALLED from rpg.lua's title-screen
-- block once its ~10-line delegation lands (requested from @survival, see
-- decisionLog.md ADR-019 SS1); until then this file loads fine, the tick/chat/draw
-- hooks are already live, but the Multiplayer button itself doesn't exist yet.
-- See knowledge/memory-bank/decisionLog.md ADR-017/018/019 for the full design.
-- ================================================================================

local RELAY_PORT = 9899
local PID_FILE = "../scripts/mp_relay.pid"
local W, H = 612, 384          -- title-screen canvas size, matches rpg.lua's local W,H
local floor = math.floor
local TAG = "netlink"

R.net.S = R.net.S or {
  screen = "menu",   -- menu | host | hosting | join | joining | joinerr | joined
  role = nil, link = nil, helloSent = false,
  code = "", hostIp = "", myLanIp = nil,
  status = "", err = nil, focus = nil,
  peers = 0, remote = nil,   -- remote = {x=,y=,t=frame}
}
local S = R.net.S

-- -------------------------------------------------------------- small helpers
-- Remote chat text is DATA, never code: strip control chars, cap length, and it is
-- only ever handed to R.chatSay -> graphics.drawText (a literal string draw). Never
-- eval'd, never loadstring'd, never reaches os.execute or a file path.
local function sanitizeChat(text)
  if type(text) ~= "string" then return "" end
  text = text:gsub("[%c]", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  return text:sub(1, 200)
end

local function genCode()
  math.randomseed(((R.frame or 0) * 7919 + os.time()) % 2147483647)
  return string.format("%04d", math.random(0, 9999))
end

-- Best-effort LAN IP for the host-address field: connect a throwaway socket
-- outward and read the local address the OS picked for that route. INFERRED to
-- work (getsockname is a registered TCP method), not independently verified this
-- session. Never fatal -- on any failure this just leaves the field for manual
-- entry (ipconfig), which is the explicitly-sanctioned minimum bar (ADR-019 SS2).
local function detectLanIp()
  local ok, sock = pcall(socket.tcp)
  if not ok or not sock then return nil end
  local okc, ip = pcall(function()
    sock:settimeout(0)
    sock:connect("8.8.8.8", 53)
    return sock:getsockname()
  end)
  pcall(function() sock:close() end)
  if okc and type(ip) == "string" and ip ~= "" and ip ~= "0.0.0.0" then return ip end
  return nil
end

-- Detached relay launch, same "start /min ... " + no-PID-tracking-needed pattern
-- already shipped in R.applyUpdate(). Idempotent on the PYTHON side (mp_relay.py
-- exits quietly if RELAY_PORT is already bound), so no Lua-side pre-check needed
-- and no risk of a relay fleet even if "Host" is clicked twice.
local function launchRelay()
  pcall(os.execute, 'start "" /min pythonw ..\\scripts\\mp_relay.py --port ' .. RELAY_PORT)
end

local function stopRelay()
  local f = io.open(PID_FILE, "r")
  if not f then return end
  local pid = f:read("*a"); f:close()
  pid = pid and pid:match("%d+")
  if pid then pcall(os.execute, "taskkill /F /PID " .. pid .. " >nul 2>&1") end
end
R.net.stopRelay = stopRelay   -- exposed for a future Esc-menu "leave session" hook

local function resetToMenu()
  if S.link then S.link:close("user") end
  S.link, S.role, S.helloSent, S.remote = nil, nil, false, nil
  S.screen, S.status, S.err = "menu", "", nil
end

local function startHosting()
  if not R.worldEverGenerated then S.err = "Create a world first"; return end
  if S.code == "" then S.code = genCode() end
  S.myLanIp = detectLanIp()
  launchRelay()
  S.role, S.helloSent = "host", false
  S.link = R.net.connect("127.0.0.1", RELAY_PORT)
  S.screen, S.status, S.peers, S.err = "hosting", "Starting relay...", 0, nil
end

local function startJoining()
  if S.hostIp == "" then S.err = "Enter the host's address"; return end
  S.role, S.helloSent = "guest", false
  S.link = R.net.connect(S.hostIp, RELAY_PORT)
  S.screen, S.status, S.err = "joining", "Connecting...", nil
end

-- -------------------------------------------------------------- inbound frame handling
local function onPeerJoined()
  if S.role == "host" and S.link then
    S.link:send({ kind = "world", seed = R.seed, mode = R.sandbox and "sandbox" or "survival" })
  end
  S.peers, S.status = 1, "Connected"
end

-- Guest side: auto-enter the host's world by seed, same trigger confirmCreateWorld()
-- uses (R.pendingGen is public R state, not a local -- this writes data the way
-- ADR-005 intends plugins to coordinate, it does not touch rpg.lua). Known gap,
-- documented, not fixed here: only the SEED travels, not cave-frequency/ore-rarity
-- tuning the host may have customized on their own Create World screen.
local function onWorldFrame(msg)
  if S.role ~= "guest" then return end
  local seed = tonumber(msg.seed)
  if not seed then return end
  R.pendingGen = seed
  if msg.mode == "sandbox" then R.sandbox = true end
  R.titleScreen, R.titleCreateOpen, R.titleMultiplayerOpen = false, false, false
  if R.releaseMouse then pcall(R.releaseMouse) end
  S.screen, S.status = "joined", "Connected"
end

local function handleFrame(msg)
  if type(msg) ~= "table" then return end
  if msg.kind == "welcome" then
    if S.role == "host" then S.status = "Waiting for a player..." end
  elseif msg.kind == "reject" then
    S.err = "Could not join: " .. tostring(msg.why or "rejected")
    S.screen = "joinerr"
    if S.link then S.link:close("rejected") end
    S.link = nil
  elseif msg.kind == "peer_joined" then
    onPeerJoined()
  elseif msg.kind == "world" then
    onWorldFrame(msg)
  elseif msg.kind == "host_left" then
    -- ADR-019 SS3 failure behaviour: save the guest's own inventory, hand local sim
    -- control back so they aren't frozen, and return to the title screen -- the
    -- guest never held authoritative world state, there is nothing shared to resume.
    if S.link then S.link:close("host_left") end
    S.link, S.remote = nil, nil
    pcall(function() local f = io.open("rpg-save-mp.json", "w")
      if f then f:write(json.stringify({ inventory = R.inventory or {} })); f:close() end end)
    if sim and sim.paused then pcall(sim.paused, false) end
    R.active, R.titleScreen = false, true
    S.screen, S.status, S.err = "menu", "", "Host disconnected -- you're back on your own"
  elseif msg.kind == "pos" then
    if type(msg.x) == "number" and type(msg.y) == "number" then
      S.remote = { x = msg.x, y = msg.y, t = R.frame or 0 }
    end
  elseif msg.kind == "chat" then
    R.chatSay(S.role == "host" and "Guest" or "Host", sanitizeChat(msg.text))
  end
end

-- -------------------------------------------------------------- tagged hooks
local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

-- Drives the link every tick regardless of title-screen state (R.hooks.tick fires
-- unconditionally, VERIFIED: no R.titleScreen gate before runHooks(R.hooks.tick) in
-- rpg.lua's onTick). Sends the session-code hello once open, then a throttled
-- position echo (every 3rd tick) once the world is actually running.
hook(R.hooks.tick, function()
  local link = S.link
  if not link then return end
  link:poll()
  if link.state == "closed" then
    if S.screen == "joining" then S.screen, S.err = "joinerr", "Could not reach host" end
    S.link = nil
    return
  end
  if link:isOpen() and not S.helloSent then
    link:send({ kind = "hello", code = S.code, role = S.role })
    S.helloSent = true
  end
  local msg = link:receive()
  while msg do handleFrame(msg); msg = link:receive() end
  if R.active and link:isOpen() and (R.frame or 0) % 3 == 0 then
    link:send({ kind = "pos", x = R.P.x, y = R.P.y })
  end
end)

-- Outgoing chat rides the EXISTING in-game chat the player already knows (Enter to
-- open, type, Enter to send -- R.chatOpen/R.chatText in rpg.lua). That code already
-- calls runHooks(R.hooks.chat, msg) with the player's own typed text on submit, so
-- no new chat UI is built here at all -- this is the entire outgoing side.
hook(R.hooks.chat, function(msg)
  if S.link and S.link:isOpen() then S.link:send({ kind = "chat", text = sanitizeChat(msg) }) end
end)

-- Remote player marker. R.hooks.draw only fires in real gameplay (never on the
-- title screen, VERIFIED), which is exactly when there's a world to draw it into.
hook(R.hooks.draw, function()
  if not S.remote then return end
  local fx, fy = floor(S.remote.x) - R.cam.x, floor(S.remote.y) - R.cam.y
  if fx > -20 and fx < W + 20 and fy > -20 and fy < H + 20 then
    graphics.fillCircle(fx, fy, 6, 6, 90, 200, 255, 220)
    graphics.drawText(fx - 12, fy - 16, S.role == "host" and "Guest" or "Host", 200, 230, 255, 220)
  end
end)

-- -------------------------------------------------------------- title-screen UI
-- Everything below is called from rpg.lua's title-screen block (pcall-guarded
-- there) once the small ADR-019 SS1 delegation lands. Click-to-open only, no
-- hover triggers anywhere in here, per standing rule.
local function fieldRect(cx, y) return { x = cx - 110, y = y, w = 220, h = 22 } end
local function hit(x, y, r) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end

function R.net.drawTitleScreen()
  local cx = floor(W / 2)
  graphics.fillRect(cx - 140, 60, 280, 300, 10, 12, 18, 230)
  graphics.drawText(cx - 55, 72, "MULTIPLAYER (LAN)", 230, 235, 245, 255)

  if S.screen == "menu" then
    local hostBtn, joinBtn, backBtn = { x=cx-70,y=110,w=140,h=26 }, { x=cx-70,y=146,w=140,h=26 }, { x=cx-70,y=310,w=140,h=26 }
    for _, b in ipairs({ {hostBtn,"Host"}, {joinBtn,"Join"}, {backBtn,"Back"} }) do
      graphics.fillRect(b[1].x, b[1].y, b[1].w, b[1].h, 40, 45, 55, 255)
      graphics.drawText(b[1].x + 10, b[1].y + 6, b[2], 230, 235, 245, 255)
    end
    R.net._menuBtns = { host = hostBtn, join = joinBtn, back = backBtn }
    if not R.worldEverGenerated then graphics.drawText(cx - 90, 180, "Create a world first to host.", 200, 150, 120, 220) end

  elseif S.screen == "host" then
    local codeF = fieldRect(cx, 120)
    graphics.drawText(codeF.x, codeF.y - 14, "Session code (share with your friend):", 200, 205, 215, 220)
    graphics.fillRect(codeF.x, codeF.y, codeF.w, codeF.h, 25, 28, 36, 255)
    graphics.drawText(codeF.x + 8, codeF.y + 5, S.code .. (S.focus == "code" and (((R.frame or 0) % 30 < 15) and "_" or "") or ""), 235, 245, 255, 255)
    R.net._hostFields = { code = codeF }
    local startBtn, backBtn = { x=cx-70,y=170,w=140,h=26 }, { x=cx-70,y=310,w=140,h=26 }
    graphics.fillRect(startBtn.x, startBtn.y, startBtn.w, startBtn.h, 40, 70, 45, 255); graphics.drawText(startBtn.x + 6, startBtn.y + 6, "Start Hosting", 230, 245, 235, 255)
    graphics.fillRect(backBtn.x, backBtn.y, backBtn.w, backBtn.h, 40, 45, 55, 255); graphics.drawText(backBtn.x + 10, backBtn.y + 6, "Back", 230, 235, 245, 255)
    R.net._hostBtns = { start = startBtn, back = backBtn }
    if S.err then graphics.drawText(codeF.x, 200, S.err, 235, 120, 110, 255) end

  elseif S.screen == "hosting" then
    graphics.drawText(cx - 90, 108, "Code: " .. S.code, 235, 245, 255, 255)
    graphics.drawText(cx - 90, 126, "Address: " .. (S.myLanIp or "(see ipconfig)") .. ":" .. RELAY_PORT, 200, 205, 215, 255)
    graphics.drawText(cx - 90, 150, S.status or "", 200, 230, 180, 255)
    local stopBtn = { x=cx-70,y=310,w=140,h=26 }
    graphics.fillRect(stopBtn.x, stopBtn.y, stopBtn.w, stopBtn.h, 70, 40, 40, 255); graphics.drawText(stopBtn.x + 6, stopBtn.y + 6, "Stop Hosting", 245, 230, 230, 255)
    R.net._hostingBtns = { stop = stopBtn }

  elseif S.screen == "join" then
    local ipF, codeF = fieldRect(cx, 118), fieldRect(cx, 160)
    graphics.drawText(ipF.x, ipF.y - 14, "Host address:", 200, 205, 215, 220)
    graphics.fillRect(ipF.x, ipF.y, ipF.w, ipF.h, 25, 28, 36, 255)
    graphics.drawText(ipF.x + 8, ipF.y + 5, S.hostIp .. (S.focus == "ip" and (((R.frame or 0) % 30 < 15) and "_" or "") or ""), 235, 245, 255, 255)
    graphics.drawText(codeF.x, codeF.y - 14, "Session code:", 200, 205, 215, 220)
    graphics.fillRect(codeF.x, codeF.y, codeF.w, codeF.h, 25, 28, 36, 255)
    graphics.drawText(codeF.x + 8, codeF.y + 5, S.code .. (S.focus == "code" and (((R.frame or 0) % 30 < 15) and "_" or "") or ""), 235, 245, 255, 255)
    R.net._joinFields = { ip = ipF, code = codeF }
    local connBtn, backBtn = { x=cx-70,y=210,w=140,h=26 }, { x=cx-70,y=310,w=140,h=26 }
    graphics.fillRect(connBtn.x, connBtn.y, connBtn.w, connBtn.h, 40, 70, 45, 255); graphics.drawText(connBtn.x + 6, connBtn.y + 6, "Connect", 230, 245, 235, 255)
    graphics.fillRect(backBtn.x, backBtn.y, backBtn.w, backBtn.h, 40, 45, 55, 255); graphics.drawText(backBtn.x + 10, backBtn.y + 6, "Back", 230, 235, 245, 255)
    R.net._joinBtns = { connect = connBtn, back = backBtn }
    if S.err then graphics.drawText(ipF.x, 240, S.err, 235, 120, 110, 255) end

  elseif S.screen == "joining" then
    graphics.drawText(cx - 60, 140, S.status or "Connecting...", 200, 230, 180, 255)
    local backBtn = { x=cx-70,y=310,w=140,h=26 }
    graphics.fillRect(backBtn.x, backBtn.y, backBtn.w, backBtn.h, 40, 45, 55, 255); graphics.drawText(backBtn.x + 10, backBtn.y + 6, "Cancel", 230, 235, 245, 255)
    R.net._joiningBtns = { back = backBtn }

  elseif S.screen == "joinerr" then
    graphics.drawText(cx - 90, 130, S.err or "Connection failed", 235, 140, 120, 255)
    local retryBtn, backBtn = { x=cx-70,y=170,w=140,h=26 }, { x=cx-70,y=310,w=140,h=26 }
    graphics.fillRect(retryBtn.x, retryBtn.y, retryBtn.w, retryBtn.h, 40, 70, 45, 255); graphics.drawText(retryBtn.x + 10, retryBtn.y + 6, "Retry", 230, 245, 235, 255)
    graphics.fillRect(backBtn.x, backBtn.y, backBtn.w, backBtn.h, 40, 45, 55, 255); graphics.drawText(backBtn.x + 10, backBtn.y + 6, "Back", 230, 235, 245, 255)
    R.net._errBtns = { retry = retryBtn, back = backBtn }
  end
end

function R.net.titleMouseDown(x, y)
  if S.screen == "menu" then
    local b = R.net._menuBtns or {}
    if hit(x, y, b.host) then S.screen, S.err = "host", nil; if S.code == "" then S.code = genCode() end; return true end
    if hit(x, y, b.join) then S.screen, S.err = "join", nil; return true end
    if hit(x, y, b.back) then R.titleMultiplayerOpen = false; return true end
    return true
  elseif S.screen == "host" then
    local f, b = R.net._hostFields or {}, R.net._hostBtns or {}
    if hit(x, y, f.code) then S.focus = "code"; return true end
    if hit(x, y, b.start) then startHosting(); return true end
    if hit(x, y, b.back) then S.screen, S.focus, S.err = "menu", nil, nil; return true end
    S.focus = nil; return true
  elseif S.screen == "hosting" then
    local b = R.net._hostingBtns or {}
    if hit(x, y, b.stop) then stopRelay(); resetToMenu(); return true end
    return true
  elseif S.screen == "join" then
    local f, b = R.net._joinFields or {}, R.net._joinBtns or {}
    if hit(x, y, f.ip) then S.focus = "ip"; return true end
    if hit(x, y, f.code) then S.focus = "code"; return true end
    if hit(x, y, b.connect) then S.err = nil; startJoining(); return true end
    if hit(x, y, b.back) then S.screen, S.focus, S.err = "menu", nil, nil; return true end
    S.focus = nil; return true
  elseif S.screen == "joining" then
    local b = R.net._joiningBtns or {}
    if hit(x, y, b.back) then resetToMenu(); return true end
    return true
  elseif S.screen == "joinerr" then
    local b = R.net._errBtns or {}
    if hit(x, y, b.retry) then S.screen, S.err = "join", nil; return true end
    if hit(x, y, b.back) then resetToMenu(); return true end
    return true
  end
  return true
end

function R.net.titleKeyDown(key, shift, ctrl, alt)
  if key == 8 then
    if S.focus == "code" then S.code = S.code:sub(1, -2)
    elseif S.focus == "ip" then S.hostIp = S.hostIp:sub(1, -2) end
  elseif key == 27 then
    if S.screen == "menu" then R.titleMultiplayerOpen = false
    else S.screen, S.focus = "menu", nil end
  end
end

function R.net.titleTextInput(text)
  if not S.focus or not text or text == "" then return end
  if S.focus == "code" and #S.code < 8 then S.code = (S.code .. text):gsub("[^%w]", "")
  elseif S.focus == "ip" and #S.hostIp < 64 then S.hostIp = (S.hostIp .. text):gsub("[^%w%.:%-]", "") end
end

-- ================================================================================
-- Version bump: from THIS file only (table.insert on the existing R.VERSION/
-- R.CHANGELOG globals rpg.lua already defines and publishes -- no new top-level
-- local added to rpg.lua, rule 8 untouched, this is a plain field write like any
-- other cross-plugin R.* coordination).
-- ================================================================================
-- MONOTONIC as of 2026-09-01 (@lead). This used to be a bare `R.VERSION = "1.16.0"`.
-- Because plugins load AFTER rpg.lua (R.PLUGINS order), that unconditional write
-- SILENTLY OVERWROTE every version bump made in rpg.lua -- rpg.lua sat at 1.16.1 on
-- disk while the live game reported 1.16.0 and the new What's New entries were
-- invisible in-game. Any future bump would have died the same way. Now it only ever
-- RAISES the version, never lowers it, so both this file and rpg.lua can publish.
do
  local function vnum(v)
    local a, b, c = tostring(v or "0"):match("^(%d+)%.(%d+)%.(%d+)")
    if not a then return -1 end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
  end
  if vnum("1.16.0") > vnum(R.VERSION) then R.VERSION = "1.16.0" end
end
R.CHANGELOG = R.CHANGELOG or {}
-- ORDERED + DEDUPED as of 2026-09-01 (@lead). This used to be a bare
-- `table.insert(R.CHANGELOG, 1, ...)`, which force-jumped this 1.16.0 note to the TOP
-- of the list on every single load -- so once rpg.lua reached 1.16.1, the in-game
-- What's New showed an OLDER version above a newer one, and a re-insert risked
-- duplicating the entry on each reload. Now it inserts in version order and only if
-- it is not already present. What's New is his testing interface: if he cannot read
-- it in order, he cannot tell what is new.
do
  local NOTE = "1.16.0: LAN multiplayer -- Multiplayer button on the title "
    .. "screen, host/join with a shared session code, in-game chat over the link, guest "
    .. "inventory persists across sessions (host owns the world)."
  local function vnum(v)
    local a, b, c = tostring(v or "0"):match("(%d+)%.(%d+)%.(%d+)")
    if not a then return -1 end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
  end
  local mine, dupe = vnum("1.16.0"), false
  for _, e in ipairs(R.CHANGELOG) do
    local s = type(e) == "table" and tostring(e.ver or "") or tostring(e)
    if s == NOTE or (type(e) == "table" and tostring(e.ver or "") == "1.16.0") then dupe = true break end
  end
  if not dupe then
    local at = #R.CHANGELOG + 1
    for i, e in ipairs(R.CHANGELOG) do
      local s = type(e) == "table" and tostring(e.ver or "") or tostring(e)
      if vnum(s) <= mine then at = i break end
    end
    table.insert(R.CHANGELOG, at, NOTE)
  end
end

return true
