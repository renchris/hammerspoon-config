-- hsc/breakglass.lua — break-glass when no terminal can start a shell (incident 2026-10-25).
--
-- WHY HAMMERSPOON.  On 2026-10-25 one poisoned devfs node made every zsh and /usr/bin/login hang in
-- ttyname() → devname() → lstat, so no terminal could open.  Hammerspoon stayed alive throughout
-- (12:28–13:11, its own log): it is a launchd job with no controlling tty, so a child it starts with
-- hs.task never reaches ttyname().  Everything here is hs.task, asynchronous — never hs.execute,
-- os.execute, io.popen or hs.osascript, which are synchronous with no timeout (dock.lua) and would
-- hang the one tool still alive.  Scripts run as `/bin/bash <script>`: a #! exec leaks kalloc.
--
-- ⌃⌥⌘⇧C runs a capture with no UI.  ⌃⌥⌘⇧B opens the chooser.  A destructive item asks again in a
-- second chooser rather than hs.dialog.blockAlert, which is modal and stalls the screenshot poll.
-- There are no Freeze/Thaw items: SIGSTOP cannot release a kernel wait (DESIGN.md §11), and a third
-- SIGSTOP actor would need a second ledger.
local log = require("hsc.log")

local M = {}

local HOME     = os.getenv("HOME")
local SCRIPT   = HOME .. "/.claude/scripts/break-glass/rescue.sh"
local ROOT     = HOME .. "/.claude/autonomy/break-glass"
local LW       = HOME .. "/.claude/autonomy/lockwatch"
local PAGE     = HOME .. "/.claude/autonomy/pages/break-glass-selftest.page"
local PREP     = HOME .. "/.claude/scripts/alarm-reboot-prep.sh"
local PROFILE  = HOME .. "/Library/Application Support/iTerm2/DynamicProfiles/break-glass-rescue.json"
local DEADLINE = { capture = 90, unpoison = 90, brownout = 15, selftest = 150 }
local HYPER    = { "ctrl", "alt", "cmd", "shift" }
local WEEK     = 7 * 24 * 3600
local ENV      = { HOME = HOME, PATH = "/usr/bin:/bin:/usr/sbin:/sbin", PAGER = "cat", LC_ALL = "C" }

local running, deadlineTimer, keys, weekly, chooser, confirm = nil, nil, {}, nil, nil, nil

local function alert(msg, secs) hs.alert.show(msg, { textSize = 15 }, hs.screen.mainScreen(), secs or 12) end

local function readJSON(path)
  local fh = io.open(path)
  if not fh then return nil end
  local body = fh:read("a"); fh:close()
  local ok, t = pcall(hs.json.decode, body)
  return ok and type(t) == "table" and t or nil
end

local function exists(path) return hs.fs.attributes(path) ~= nil end

local function lastBegin()                 -- the progress file's last BEGIN, not output age (lesson 5)
  local newest
  local ok, iter, dobj = pcall(hs.fs.dir, ROOT .. "/kits")       -- hs.fs.dir raises on a missing dir
  if not ok or not iter then return "?" end
  for f in iter, dobj do
    if f:match("^%d") and (not newest or f > newest) then newest = f end
  end
  if not newest then return "?" end
  local fh = io.open(ROOT .. "/kits/" .. newest .. "/progress")
  if not fh then return "?" end
  local line
  for l in fh:lines() do if l:match(" BEGIN ") then line = l end end
  fh:close()
  return (line or "?"):gsub("^%d+ BEGIN ", "")
end

-- run(mode, args, done, env) — one rescue.sh run at a time; the deadline alert names the stuck step
local function run(mode, args, done, env)
  if running and running:isRunning() then alert("break-glass: " .. mode .. " refused — a run is still live"); return end
  if not exists(SCRIPT) then alert("break-glass: " .. SCRIPT .. " is missing (migration 0081 not run?)"); return end
  alert("break-glass: " .. mode .. " started", 3)
  local argv = { SCRIPT, mode }
  for _, a in ipairs(args or {}) do argv[#argv + 1] = a end
  running = hs.task.new("/bin/bash", function(rc, out, _)
    if deadlineTimer then deadlineTimer:stop(); deadlineTimer = nil end
    local summary = ((out or ""):gsub("%s+$", "")):sub(-600)
    alert("break-glass " .. mode .. " rc=" .. tostring(rc) .. "\n" .. summary, 20)
    if done then done(rc, summary) end
  end, argv)
  local e = {}
  for k, v in pairs(ENV) do e[k] = v end
  for k, v in pairs(env or {}) do e[k] = v end
  running:setEnvironment(e)
  if not running:start() then alert("break-glass: hs.task failed to start /bin/bash"); return end
  deadlineTimer = hs.timer.doAfter(DEADLINE[mode] or 90, function()
    if running and running:isRunning() then
      running:terminate()
      alert("break-glass " .. mode .. " TIMED OUT in step: " .. lastBegin(), 30)
    end
  end)
end

local function spawn(path, args, done)      -- fire-and-forget helper, still async
  local t = hs.task.new(path, done, args)
  t:setEnvironment(ENV)
  t:start()
end

-- What lockwatch knows: the cure target and the verdict (state.json, DESIGN.md §5).
local function verdict()
  local s = readJSON(LW .. "/state.json") or {}
  local u = type(s.unpoison) == "table" and s.unpoison or {}
  local cap = type(s.capture) == "table" and s.capture or {}
  return {
    verdict = s.verdict, level = s.level, pgid = u.pgid, leader = u.leader or u.pgid, lstart = u.lstart,
    holder = u.holder, diag = cap.last_dir and (cap.last_dir .. "/diagnosis.json") or nil,
    devfs = type(s.verdict) == "string" and s.verdict:match("^devfs") ~= nil,
  }
end

local function ask(question, yes, onYes)    -- a second chooser as the confirm: non-modal
  confirm = hs.chooser.new(function(c) if c and c.id == "yes" then onYes() end end)
  confirm:choices({
    { text = "Cancel", subText = question, id = "no" },
    { text = yes, subText = question, id = "yes" },
  })
  confirm:show()
end

local function killKitty()
  spawn("/usr/bin/pkill", { "-TERM", "-x", "kitty" })
  hs.timer.doAfter(10, function() spawn("/usr/bin/pkill", { "-KILL", "-x", "kitty" }) end)
  alert("kitty: TERM sent, KILL in 10 s. Resume sessions with /resume-sessions.", 15)
end

local ITEMS = {
  { text = "Capture kit (safe, read-only)", subText = "rescue.sh capture → ~/.claude/autonomy/break-glass/kits", id = "capture" },
  { text = "Unpoison (cure a poisoned /dev node)", subText = "kills the exiting pty session tree lockwatch names, after re-verifying it", id = "unpoison" },
  { text = "Brownout hold 60 min", subText = "refuse new fleet spawns for an hour (by=operator)", id = "brownout" },
  { text = "Open Rescue terminal (iTerm2 profile 'Rescue')", subText = "bash without login or zsh", id = "iterm" },
  { text = "Kernel stacks: spindump (asks admin password)", subText = "GUI password prompt; no tty needed", id = "spindump" },
  { text = "Restart guidance", subText = "writes the files-only roster, then: Apple menu › Restart", id = "restart" },
  { text = "Kill kitty (TERM, then KILL after 10 s) — ends every pane", subText = "last rung before a restart", id = "killkitty" },
  { text = "Run self-test now", subText = "capture + a refused unpoison against a throwaway process", id = "selftest" },
}

local function choose(item)
  if not item then return end
  local id = item.id
  if id == "capture" or id == "selftest" then
    run(id)
  elseif id == "brownout" then
    run("brownout", { "60" })
  elseif id == "unpoison" then
    local v = verdict()
    if not v.pgid or not v.lstart then
      alert("Unpoison: lockwatch names no target (state.json unpoison.pgid/lstart empty).\n" ..
            "Run Capture, or the Rescue terminal: lwstate, then unpoison <pgid> <lstart>.", 20)
      return
    end
    ask(string.format("kill the session tree of leader %s (pgid %s, started %s)%s — verdict %s",
                      tostring(v.leader), tostring(v.pgid), tostring(v.lstart),
                      v.holder and (", holder " .. tostring(v.holder)) or "", tostring(v.verdict or "?")),
        "Unpoison now", function()
          run("unpoison", { tostring(v.pgid), tostring(v.lstart) }, nil,
              v.diag and exists(v.diag) and { RESCUE_DIAGNOSIS = v.diag } or nil)
        end)
  elseif id == "iterm" then
    -- OpenNoWindowsAtStartup=1, so launching iTerm2 never spawns a login-shell window first.
    if not exists(PROFILE) then alert("Rescue profile missing: " .. PROFILE .. " (migration 0081)"); return end
    spawn("/usr/bin/osascript", { "-e", 'tell application "iTerm2" to create window with profile "Rescue"' })
  elseif id == "spindump" then
    local out = ROOT .. "/kits/spindump-" .. os.date("%Y%m%dT%H%M%S") .. ".txt"
    hs.fs.mkdir(ROOT); hs.fs.mkdir(ROOT .. "/kits")
    spawn("/usr/bin/osascript", { "-e",
      'do shell script "/usr/sbin/spindump -noTarget 5 10 -timelimit 90 -o ' .. out .. '" with administrator privileges' })
  elseif id == "restart" then
    local f = io.open(PREP)
    local body = f and f:read("a") or ""
    if f then f:close() end
    if body:find("files%-only") then spawn("/bin/bash", { PREP, "--files-only" }) end
    alert("Restart: use Apple menu › Restart — it writes the shutdown_stall stackshot.\n" ..
          "Never the power button.  " ..
          (body:find("files%-only") and "Files-only roster: written in the background." or "(no files-only roster on this build)"), 30)
  elseif id == "killkitty" then
    local v = verdict()
    local q = "every kitty pane closes; sessions come back through /resume-sessions"
    if v.devfs then
      q = "VERDICT " .. tostring(v.verdict) .. ": Unpoison FIRST. Killing kitty makes expect panes re-exec zsh " ..
          "into the same wait (RCA §3); if Unpoison fails, use Apple menu › Restart"
    end
    ask(q, "Kill kitty anyway", killKitty)
  end
end

local function writePage(text)
  local fh = io.open(PAGE, "w"); if fh then fh:write(text .. "\n"); fh:close() end
end

local function weeklyCheck()               -- hourly tick, acts at most once a week, only when idle
  local last = hs.settings.get("breakglass.selftest.at") or 0
  if os.time() - last < WEEK or hs.host.idleTime() < 600 then return end
  run("selftest", nil, function(rc, summary)
    hs.settings.set("breakglass.selftest.at", os.time())
    if rc ~= 0 or not summary:match("^selftest pass") then writePage("break-glass selftest FAILED: " .. summary)
    else os.remove(PAGE) end
  end)
end

function M.show() if chooser then chooser:show() end end

function M.start()
  chooser = hs.chooser.new(choose):choices(ITEMS)
  keys[#keys + 1] = hs.hotkey.bind(HYPER, "B", function() chooser:show() end)      -- menu
  keys[#keys + 1] = hs.hotkey.bind(HYPER, "C", function() run("capture") end)      -- no-UI capture
  weekly = hs.timer.doEvery(3600, weeklyCheck)
  if not exists(SCRIPT) then
    log.warn("breakglass", { msg = "rescue.sh not installed at " .. SCRIPT .. " (claude-infrastructure migration 0081)" })
  end
end

function M.stop()
  for _, k in ipairs(keys) do k:delete() end
  keys = {}
  if weekly then weekly:stop(); weekly = nil end
  if deadlineTimer then deadlineTimer:stop(); deadlineTimer = nil end
end

function M.stats()
  return { hotkeys = #keys, running = running and running:isRunning() or false,
           script = exists(SCRIPT), profile = exists(PROFILE),
           selftest_at = hs.settings.get("breakglass.selftest.at") or 0 }
end

return M
