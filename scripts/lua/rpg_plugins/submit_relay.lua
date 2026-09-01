-- SUPERSEDED (2026-09-0x): @submission landed a complete, BETTER fix for the exact gap this
-- file was written to close -- submitSend() (ui.lua) now dispatches INLINE at the moment of
-- submission (R.submitStampToDiscord if a webhook is configured, else R.buildGithubIssueURL +
-- R.openBrowserURL, a credential-free path that needs no webhook at all) and shows the player
-- an honest sent/opened_browser/delivery_failed status immediately -- strictly better UX than
-- this file's delayed background poll. **DO NOT add "submit_relay" to R.PLUGINS.** Every
-- manifest line is now already handled inline by submitSend() itself, so this file's own
-- dispatch would be a genuine DUPLICATE SEND (a second Discord post / a second GitHub-issue
-- browser tab for the same submission), not a harmless no-op. Left in the repo only as a record
-- of the investigation (see knowledge/rpg-hub.md, 2026-09-0x @multiplayer and @submission
-- entries, for the full account of how two lanes independently converged on the same gap and
-- how the collision was caught before this file was ever registered/loaded). rpg.lua's
-- R.PLUGINS list has no "submit_relay" entry and none should be added.
--
-- Original header follows, describing the file as designed before the collision was found:
--
-- submit_relay.lua - closes the "Y to submit" -> off-disk wiring gap (2026-09-02, @multiplayer).
--
-- ui.lua's Y-key submission flow (submitSend()) already builds a full manifest record and
-- appends it to stamp_submissions/manifest.jsonl -- LOCAL DISK ONLY. rpg.lua's own
-- R.submitStampToDiscord() (added 2026-09-01) was written specifically to get that record off
-- the submitting player's own disk and in front of PhoenixFire808 for anyone who downloads the
-- game -- but nothing anywhere ever called it. A player pressing Y saw "Submitted - thanks!"
-- and the record never left their machine. This plugin is that missing call: it tails the
-- manifest for lines it hasn't dispatched yet and sends each one through whatever transport is
-- actually available.
--
-- CREDENTIAL REALITY, the reason this cannot be a silent best-effort call: a downloaded copy of
-- the game ships with NO feedback_webhook.txt (it is a bearer credential, deliberately excluded
-- from the release zip -- see rpg.lua's own comment above R.FEEDBACK_WEBHOOK). So for most
-- players R.submitStampToDiscord will always report "no webhook configured." Reporting that
-- honestly to the player (R.say, every attempt) is the entire point of this file -- the bug this
-- closes was a false-positive "Submitted" confirmation, and doing nothing when the transport is
-- absent would just move that same false positive one file over.
--
-- FORWARD-COMPATIBLE with whatever credential-free transport @submission lands: if some later
-- plugin defines R.submitDispatch(rec) -> ok[, detail], that is tried FIRST and preferred over
-- the Discord webhook the moment it exists -- this file will not need an edit when that lands.
--
-- Owns: nothing another plugin reads or draws -- R.submitRelay is a status table for a future UI
-- pass (not built here; ui.lua's own submitHistory is untouched). No hotbar/menu/key entries.
-- Does not touch ui.lua or rpg.lua (both owned by other lanes this wave) -- see the R.PLUGINS
-- note at the bottom for the one line this file still needs from whoever owns rpg.lua.

local R = PBX.state.rpg
local TAG = "submit_relay"
local MANIFEST_PATH = "stamp_submissions/manifest.jsonl"
local CURSOR_PATH = "stamp_submissions/.relay_cursor"

local function hook(list, fn)
  for i = #list, 1, -1 do if type(list[i]) == "table" and list[i].tag == TAG then table.remove(list, i) end end
  list[#list + 1] = setmetatable({ tag = TAG }, { __call = function(_, ...) return fn(...) end })
end

-- R.submitRelay survives hot-reload (it lives on the shared R table); the on-disk cursor is what
-- survives an actual process restart, so a fresh boot never re-sends everything already attempted
-- in a prior session. Read once at load, never overwritten by a later hot-reload of this file.
if not R.submitRelay then
  local startCursor = 0
  local f = io.open(CURSOR_PATH, "r")
  if f then startCursor = tonumber(f:read("*l") or "") or 0; f:close() end
  R.submitRelay = { cursor = startCursor, lastResult = nil, history = {} }
end

local function saveCursor(n)
  local f = io.open(CURSOR_PATH, "w")
  if f then f:write(tostring(n)); f:close() end
end

-- Returns every manifest line past R.submitRelay.cursor, and advances the cursor past all of
-- them (an entry is "attempted" the moment we've read it, whether or not it actually sends --
-- this file reports once per entry, it does not retry forever).
local function readNewLines()
  local f = io.open(MANIFEST_PATH, "r")
  if not f then return {} end
  local out, n = {}, 0
  for line in f:lines() do
    n = n + 1
    if n > R.submitRelay.cursor and line ~= "" then out[#out + 1] = line end
  end
  f:close()
  if n ~= R.submitRelay.cursor then R.submitRelay.cursor = n; saveCursor(n) end
  return out
end

-- dispatch(rec) -> sent(bool), detail(string). Never raises -- every branch is pcall-guarded so
-- one bad record can't take the tick hook down (see the caller's own pcall too, belt and braces,
-- matching every other plugin's tick-hook convention in this codebase).
local function dispatch(rec)
  if type(R.submitDispatch) == "function" then
    local ok, sent, detail = pcall(R.submitDispatch, rec)
    if ok then return sent and true or false, detail end
  end
  if type(R.submitStampToDiscord) == "function" then
    local ok, sent, detail = pcall(R.submitStampToDiscord, {
      category = rec.category,
      context = rec.context,
      id = rec.id,
      w = rec.bbox and rec.bbox.w,
      h = rec.bbox and rec.bbox.h,
      elements_str = type(rec.elements) == "table" and table.concat(rec.elements, ",") or "",
      manifest_line = rec._raw,
    })
    if ok then
      if sent then return true, "sent to Discord" end
      return false, tostring(detail or "unknown error")
    end
    return false, tostring(sent)
  end
  return false, "no transport available in this build"
end

local function processNew()
  local lines = readNewLines()
  for _, raw in ipairs(lines) do
    local ok, rec = pcall(json.parse, raw)
    if ok and type(rec) == "table" then
      rec._raw = raw
      local sent, detail = dispatch(rec)
      local entry = { id = rec.id, category = rec.category, sent = sent, detail = detail, frame = R.frame or 0 }
      R.submitRelay.lastResult = entry
      R.submitRelay.history[#R.submitRelay.history + 1] = entry
      if #R.submitRelay.history > 30 then table.remove(R.submitRelay.history, 1) end
      if R.say then
        if sent then
          R.say("Submission " .. tostring(rec.id) .. " sent to PhoenixFire808 (" .. tostring(detail) .. ").")
        else
          R.say("Submission " .. tostring(rec.id) .. " saved locally but NOT sent: " .. tostring(detail))
        end
      end
      if R.tlog then R.tlog(sent and "info" or "warn", "submit_relay", "dispatch", entry) end
    elseif R.tlog then
      R.tlog("error", "submit_relay", "manifest line failed to parse", { raw = raw })
    end
  end
end

-- ~1.3s cadence (frame%90): a manifest write only happens on a deliberate player action (Y ->
-- Enter/drag-release), so there is no need to check every frame -- this is a plain io.open text
-- read, cheap, and only does real work (JSON parse + one HTTP POST) when new lines exist.
hook(R.hooks.tick, function()
  if (R.frame or 0) % 90 ~= 43 then return end
  local ok, err = pcall(processNew)
  if not ok then R.pluginErr = tostring(err) end
end)

-- R.PLUGINS registration needed (rpg.lua isn't this lane's file to edit this wave): append
-- "submit_relay" to the R.PLUGINS list (rpg.lua, after "netlink" or at the end -- order doesn't
-- matter, this file only reads R.hooks/R.say/R.submitStampToDiscord/R.FEEDBACK_WEBHOOK, all of
-- which are set up by core before any plugin runs). Until then, load for testing with
-- R.reloadPlugin("submit_relay") -- same precedent telemetry.lua/icons.lua used.
