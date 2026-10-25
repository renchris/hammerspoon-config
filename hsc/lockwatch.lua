-- hsc/lockwatch.lua — the lockwatch menubar and the dead-man page (incident 2026-10-25, DESIGN.md C5).
--
-- lockprobe (claude-infrastructure scripts/lockwatch/) writes two files: state.json (atomic rename,
-- every 5 s) and hb (one pwrite per 2 s tick).  This module READS them every 15 s with io.open and
-- hs.fs.attributes — no fork, no hs.task on the timer — and shows OK / WATCH / DIAG / ESC / STALE
-- plus the band read-back (band_pri).
--
-- DEAD-MAN PAGE.  If hb was seen fresh this run and then goes stale for more than 120 s, outside a
-- 2-minute post-wake grace, one Pushover page goes out through hs.http.asyncPost with the same
-- credential lr-page uses (~/.config/lr-page/pushover.env, 0600).  It keys on hb ONLY: the sentinel's
-- own row went over 120 s 40 times on 10-25 before onset, so its age is never read.  It re-arms only
-- after hb is fresh again.  A box where lockprobe never ran (no hb ever seen fresh) never pages.
-- No hs.notify for pages lr-page already posts.
local log = require("hsc.log")

local M = {}

local HOME   = os.getenv("HOME")
local LW     = HOME .. "/.claude/autonomy/lockwatch"
local CREDS  = HOME .. "/.config/lr-page/pushover.env"
local TICK_S, FRESH_S, DEAD_S, WAKE_GRACE_S = 15, 10, 120, 120
local LEVELS = { [0] = "OK", [1] = "WATCH", [2] = "DIAG", [3] = "ESC" }

local bar, timer, wake = nil, nil, nil
local seenFresh, paged, lastWake, last = false, false, 0, {}

local function readJSON(path)
  local fh = io.open(path)
  if not fh then return nil end
  local body = fh:read("a"); fh:close()
  local ok, t = pcall(hs.json.decode, body)
  return ok and type(t) == "table" and t or nil
end

local function creds()
  local a = hs.fs.attributes(CREDS)
  if not a or a.permissions ~= "rw-------" then return nil end
  local fh = io.open(CREDS)
  if not fh then return nil end
  local c = {}
  for line in fh:lines() do
    local k, v = line:gsub("^export ", ""):match("^([%w_]+)=(.*)$")
    if k then c[k] = v:gsub("^[\"']", ""):gsub("[\"']$", "") end
  end
  fh:close()
  if c.PUSHOVER_TOKEN and c.PUSHOVER_USER then return c end
  return nil
end

local function page(title, message)
  local c = creds()
  if not c then
    log.warn("lockwatch", { msg = "dead-man page NOT sent: no 0600 " .. CREDS .. " (DESIGN.md H5)" })
    return
  end
  local body = hs.http.encodeForQuery({ token = c.PUSHOVER_TOKEN, user = c.PUSHOVER_USER,
                                        title = title, message = message, priority = "1" })
  hs.http.asyncPost("https://api.pushover.net/1/messages.json", body,
    { ["Content-Type"] = "application/x-www-form-urlencoded" }, function(status, _, _)
      if status ~= 200 then log.warn("lockwatch", { msg = "dead-man page POST returned " .. tostring(status) }) end
    end)
end

local function render(title, lines)
  if not bar then return end
  bar:setTitle(title)
  local menu = {}
  for _, l in ipairs(lines) do menu[#menu + 1] = { title = l, disabled = true } end
  menu[#menu + 1] = { title = "-" }
  menu[#menu + 1] = { title = "Break-glass…", fn = function()
    local ok, bg = pcall(require, "hsc.breakglass")
    if ok and bg.show then bg.show() end
  end }
  bar:setMenu(menu)
end

local function tick()
  local now = os.time()
  local a = hs.fs.attributes(LW .. "/hb")
  local age = a and (now - (a.modification or 0)) or nil
  local s = readJSON(LW .. "/state.json") or {}
  local band = s.band_pri and (" " .. tostring(s.band_pri)) or ""
  if age and age <= FRESH_S then seenFresh, paged = true, false end

  local title
  if not age then title = "LW –"
  elseif age > FRESH_S then title = "LW STALE"
  else title = "LW " .. (LEVELS[tonumber(s.level) or 0] or "?") end
  local c = type(s.canary) == "table" and s.canary or {}
  render(title .. band, {
    "level " .. tostring(s.level or "?") .. "  verdict " .. tostring(s.verdict or "-"),
    "hb age " .. (age and (age .. " s") or "none") .. "  kitty_rc " .. tostring(s.kitty_rc or "?"),
    "canary zsh " .. tostring(c.zsh_ms or "?") .. " ms  walk " .. tostring(c.walk_ms or "?") ..
      " ms  stuck " .. tostring(c.stuck_s or 0) .. " s",
  })

  if age and age > DEAD_S and seenFresh and not paged and now - lastWake > WAKE_GRACE_S then
    paged = true
    page("lockwatch DEAD", string.format("lockprobe hb is %d s old (state level %s, verdict %s). " ..
      "Break-glass: ctrl-alt-cmd-shift-B. Never the power button: Apple menu > Restart.",
      age, tostring(s.level or "?"), tostring(s.verdict or "-")))
    log.warn("lockwatch", { msg = "dead-man page sent, hb age " .. age .. " s" })
  end
  last = { age = age, level = s.level, title = title }
end

function M.start()
  bar = hs.menubar.new()
  wake = hs.caffeinate.watcher.new(function(ev)
    if ev == hs.caffeinate.watcher.systemDidWake or ev == hs.caffeinate.watcher.screensDidWake then
      lastWake = os.time()
    end
  end):start()
  lastWake = os.time()                        -- a reload counts as a wake: no page in the first 2 min
  timer = hs.timer.doEvery(TICK_S, function()
    local ok, err = pcall(tick)
    if not ok then log.warn("lockwatch", { msg = "tick: " .. tostring(err) }) end
  end)
  pcall(tick)
end

function M.stop()
  if timer then timer:stop(); timer = nil end
  if wake then wake:stop(); wake = nil end
  if bar then bar:delete(); bar = nil end
end

function M.stats() return { seen_fresh = seenFresh, paged = paged, last = last } end

return M
