-- hsc/dock.lua — ⌥+1..0 launches the Dock's pinned apps, in Dock order, disabled in terminals.
--
-- 🚨 THE PYTHON SPAWN IS GONE, AND THE REASON IS ITS TAIL, NOT ITS MEAN.  The shipped code read
-- com.apple.dock.plist by shelling out to `python3 -c "import plistlib …"` through hs.execute.
-- F2's audit corrected the cost story twice over: the rebind runs ≈2×/day (com.apple.dock.plist was
-- written twice in 24 h), not continuously, so its MEAN cost was never this pipeline's problem —
-- but hs.execute is io.popen + read('*a') + close(), a synchronous fork/exec/waitpid WITH NO
-- TIMEOUT AT ALL, median 43 ms and worst case UNBOUNDED.  A hung /usr/bin/python3 — or an
-- Xcode-CLT shim that blocks on a GUI dialog — hangs Hammerspoon's main thread forever, and with it
-- the screenshot poll.  hs.plist.read is in-process: 1.88–2.02 ms, no fork, no timeout to miss.
--
-- Nothing on a timer callback in this config may call hs.execute, os.execute, io.popen or
-- hs.osascript — nor hs.sound, whose play() is a synchronous call into coreaudiod (264 s frozen on
-- 2026-10-09).  hs.task (asynchronous) is the only sanctioned way to reach another process.
local apps = require("hsc.apps")
local log  = require("hsc.log")

local M = {}

local KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }
local DOCK_PLIST = os.getenv("HOME") .. "/Library/Preferences/com.apple.dock.plist"
local PREF_DIR   = os.getenv("HOME") .. "/Library/Preferences"

local hotkeys       = {}
local pathWatcher   = nil
local appWatcher    = nil
local rebindTimer   = nil
local manualHotkey  = nil
local lastBound     = 0

local skipNames, skipBundleIDs = {}, {}

local function pinnedApps()
  local ok, plist = pcall(hs.plist.read, DOCK_PLIST)
  if not ok or type(plist) ~= "table" then
    log.warn("dock", { msg = "cannot read com.apple.dock.plist; ⌥+digit shortcuts unavailable" })
    return {}
  end

  local out = {}
  for _, item in ipairs(plist["persistent-apps"] or {}) do
    local td   = item["tile-data"] or {}
    local name = td["file-label"]
    local bid  = td["bundle-identifier"]
    local path = (td["file-data"] or {})["_CFURLString"]
    if type(path) == "string" then
      path = path:gsub("^file://", "")
      path = path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end
    if name and not skipNames[name] and not (bid and skipBundleIDs[bid]) then
      out[#out + 1] = { name = name, bundleID = bid, path = path }
    end
  end

  -- Finder is always first on the Dock but is not in persistent-apps.
  table.insert(out, 1, { name = "Finder", bundleID = "com.apple.finder",
                         path = "/System/Library/CoreServices/Finder.app" })
  return out
end

local function launch(app)
  if app.bundleID and hs.application.launchOrFocusByBundleID(app.bundleID) then return end
  if app.path and hs.application.launchOrFocus(app.path) then return end
  if app.name then hs.application.launchOrFocus(app.name) end
end

local function clearHotkeys()
  for _, hk in pairs(hotkeys) do hk:delete() end
  hotkeys = {}
end

local function setEnabled(enabled)
  for _, hk in pairs(hotkeys) do
    if enabled then hk:enable() else hk:disable() end
  end
end

local function rebind()
  clearHotkeys()
  local list = pinnedApps()
  local bound = 0
  for i, key in ipairs(KEYS) do
    local app = list[i]
    if not app then break end
    hotkeys[key] = hs.hotkey.new({ "alt" }, key, function() launch(app) end)
    hotkeys[key]:enable()
    bound = bound + 1
  end
  lastBound = bound

  local front = hs.application.frontmostApplication()
  if apps.isTerminal(front) then setEnabled(false) end

  -- Cosmetic only, and shortened from 0.8 s: the alert is a confirmation, not a status display.
  hs.alert.show(string.format("Bound %d app shortcuts", bound), 0.4)
end

function M.start()
  -- The Dock plist is written by the Dock, not by us, so a path watcher is the right instrument
  -- here: it is not on any latency path, and a missed event costs a stale binding until the next
  -- write or a manual ⌥⌘R.  The 0.5 s coalescing delay lets macOS finish writing.
  pathWatcher = hs.pathwatcher.new(PREF_DIR, function(files)
    for _, f in ipairs(files) do
      if f:match("com%.apple%.dock%.plist$") then
        if rebindTimer then rebindTimer:stop() end
        rebindTimer = hs.timer.doAfter(0.5, function()
          local ok, err = pcall(rebind)
          if not ok then log.error("dock", { msg = tostring(err) }) end
        end)
        break
      end
    end
  end)
  pathWatcher:start()

  -- The watcher's THIRD argument is the hs.application object; take the id from it rather than
  -- re-deriving one from appName, which is the name lookup hsc/apps exists to remove.
  appWatcher = hs.application.watcher.new(function(_, event, appObject)
    if event == hs.application.watcher.activated then
      setEnabled(not apps.isTerminal(appObject))
    end
  end)
  appWatcher:start()

  manualHotkey = hs.hotkey.bind({ "alt", "cmd" }, "R", rebind)
  rebind()
  log.emit("start", { module = "dock", bound = lastBound })
  return true
end

function M.stop()
  if rebindTimer then rebindTimer:stop(); rebindTimer = nil end
  if pathWatcher then pathWatcher:stop(); pathWatcher = nil end
  if appWatcher then appWatcher:stop(); appWatcher = nil end
  if manualHotkey then manualHotkey:delete(); manualHotkey = nil end
  clearHotkeys()
  log.emit("stop", { module = "dock" })
end

function M.stats()
  local n = 0
  for _ in pairs(hotkeys) do n = n + 1 end
  return { bound = n, watching = pathWatcher ~= nil, plist = DOCK_PLIST }
end

return M
