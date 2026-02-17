-- Dynamic ⌥+number bindings based on Dock pinned app order
-- Auto-updates when Dock changes; disables in terminals for tmux M-1..M-9.

-- Enable IPC for CLI control
hs.ipc.cliInstall()

-- Cleanup on reload (prevent duplicate watchers/timers from hs.reload())
if screenshotWatcher then screenshotWatcher:stop() end
if thumbCanvas then thumbCanvas:delete() end
if thumbDismissTimer then thumbDismissTimer:stop() end
if thumbSlideTimer then thumbSlideTimer:stop() end
if thumbFadeTimer then thumbFadeTimer:stop() end
if dockRebindTimer then dockRebindTimer:stop() end
if screenshotProcessTimer then screenshotProcessTimer:stop() end
if smartPasteTap then smartPasteTap:stop() end
if appWatcher then appWatcher:stop() end
if pathWatcher then pathWatcher:stop() end
if manualRefreshHotkey then manualRefreshHotkey:delete() end
if hotkeys then
    for _, hk in pairs(hotkeys) do hk:delete() end
end

local keys = { "1","2","3","4","5","6","7","8","9","0" }
local dockPlist = os.getenv("HOME") .. "/Library/Preferences/com.apple.dock.plist"

-- Skip items you don't want to bind (edit to taste)
local skipNames = {}
local skipBundleIDs = {}

-- Apps where we want to keep ⌥+digits free so tmux can use M-1..M-9
local terminalApps = {
  Kitty = true, iTerm2 = true, Terminal = true, WezTerm = true
}

hotkeys = {}

local function clearHotkeys()
  for _, hk in pairs(hotkeys) do hk:delete() end
  hotkeys = {}
end

local function pinnedApps()
  -- Use Python to read plist (handles binary data that can't convert to JSON)
  local cmd = [[python3 -c "
import plistlib
import json
import sys

try:
    with open(']] .. dockPlist .. [[', 'rb') as f:
        plist = plistlib.load(f)

    apps = []
    for item in plist.get('persistent-apps', []):
        td = item.get('tile-data', {})
        name = td.get('file-label')
        bid = td.get('bundle-identifier')
        fd = td.get('file-data', {})
        path = fd.get('_CFURLString', '')

        apps.append({'name': name, 'bundleID': bid, 'path': path})

    print(json.dumps(apps))
except Exception as e:
    print('[]', file=sys.stderr)
    sys.exit(1)
"]]

  local output, status = hs.execute(cmd)
  if not status or not output then return {} end

  local ok, data = pcall(hs.json.decode, output)
  if not ok or not data then return {} end

  local out = {}
  for _, app in ipairs(data) do
    local name = app.name
    local bid = app.bundleID
    local path = app.path

    if path and path:match("^file://") then
      path = path:gsub("^file://", "")
    end

    if name and not skipNames[name] and not (bid and skipBundleIDs[bid]) then
      table.insert(out, { name = name, bundleID = bid, path = path })
    end
  end

  -- Finder is always first on the Dock but not in persistent-apps plist
  -- Insert it manually at the beginning
  table.insert(out, 1, {
    name = "Finder",
    bundleID = "com.apple.finder",
    path = "/System/Library/CoreServices/Finder.app"
  })

  return out
end

local function launch(app)
  -- Prefer bundle id; fallback to path; then name
  if app.bundleID and hs.application.launchOrFocusByBundleID(app.bundleID) then return end
  if app.path and hs.application.launchOrFocus(app.path) then return end
  if app.name then hs.application.launchOrFocus(app.name) end
end

local function setHotkeysEnabled(enabled)
  for _, hk in pairs(hotkeys) do
    if enabled then hk:enable() else hk:disable() end
  end
end

local function isTerminalApp(name)
  return terminalApps[name] == true
end

local function rebind()
  clearHotkeys()
  local apps = pinnedApps()

  -- Debug logging
  print(string.format("Found %d pinned apps (after filtering)", #apps))

  local boundCount = 0
  for i, key in ipairs(keys) do
    local app = apps[i]
    if not app then break end
    hotkeys[key] = hs.hotkey.new({ "alt" }, key, function() launch(app) end)
    hotkeys[key]:enable()
    print(string.format("  ⌥+%s → %s", key, app.name))
    boundCount = boundCount + 1
  end

  -- Respect current frontmost app for terminal exclusion
  local front = hs.application.frontmostApplication()
  if front and isTerminalApp(front:name()) then
    setHotkeysEnabled(false)
  end

  hs.alert.show(string.format("Bound %d app shortcuts", boundCount), 0.8)
end

-- Watch Dock plist changes and rebind
pathWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/Library/Preferences", function(files)
  for _, f in ipairs(files) do
    if f:match("com%.apple%.dock%.plist$") then
      if dockRebindTimer then dockRebindTimer:stop() end
      dockRebindTimer = hs.timer.doAfter(0.5, rebind) -- slight delay so macOS finishes writing
      break
    end
  end
end)
pathWatcher:start()

-- Disable ⌥+digits in terminals, enable elsewhere
appWatcher = hs.application.watcher.new(function(appName, event)
  if event == hs.application.watcher.activated then
    setHotkeysEnabled(not isTerminalApp(appName))
  end
end)
appWatcher:start()

-- Manual refresh: ⌥+⌘+R
manualRefreshHotkey = hs.hotkey.bind({ "alt", "cmd" }, "R", rebind)

-- Initial bind
rebind()

-- Smart paste: Cmd+V sends Ctrl+V for images in terminals, Cmd+V otherwise
-- Reuses terminalApps table from Dock bindings above

local function clipboardHasImage()
    local types = hs.pasteboard.contentTypes()
    if not types then return false end
    for _, t in ipairs(types) do
        if t == "public.png" or t == "public.jpeg" or t == "public.tiff" then
            return true
        end
    end
    return false
end

-- Smart paste: Cmd+V → Ctrl+V for images in terminal apps (for Claude Code)
-- Must stop/restart tap around posting to avoid state corruption
local smartPasteTap
smartPasteTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local flags = event:getFlags()
    local keyCode = event:getKeyCode()

    -- Only intercept Cmd+V keyDown in terminal apps with image on clipboard
    if keyCode ~= 9 then return false end  -- 9 = 'V' key
    if not flags.cmd or flags.shift or flags.alt or flags.ctrl then return false end

    local front = hs.application.frontmostApplication()
    if not (front and terminalApps[front:name()] and clipboardHasImage()) then
        return false
    end

    -- Convert Cmd+V to Ctrl+V for Claude Code image paste
    smartPasteTap:stop()
    pcall(function()
        hs.eventtap.event.newKeyEvent({"ctrl"}, "v", true):post()
        hs.eventtap.event.newKeyEvent({"ctrl"}, "v", false):post()
    end)
    smartPasteTap:start()
    return true
end)
smartPasteTap:start()

-- Screenshot clipboard: watch ~/Screenshots for new PNGs, auto-copy to clipboard.
-- Native Cmd+Shift+3/4 handles capture (Sequoia intercepts before userspace).
-- show-thumbnail is disabled so files save instantly to disk.

local screenshotDir = os.getenv("HOME") .. "/Screenshots"
thumbCanvas = nil          -- global: prevent GC of visible canvas
thumbDismissTimer = nil    -- global: prevent GC of active timer
thumbSlideTimer = nil      -- global: prevent GC of active timer
thumbFadeTimer = nil       -- global: prevent GC of fade-out timer
lastProcessed = nil        -- global: dedup across watcher callbacks

local THUMB_MAX_W     = 320
local THUMB_PADDING   = 16
local THUMB_RADIUS    = 10
local THUMB_SHADOW    = 12
local THUMB_DISMISS   = 3
local THUMB_FADE      = 0.3
local THUMB_SLIDE_DUR = 0.25
local THUMB_SLIDE_FPS = 15

local function dismissThumbnail()
    if thumbSlideTimer then thumbSlideTimer:stop(); thumbSlideTimer = nil end
    if thumbDismissTimer then thumbDismissTimer:stop(); thumbDismissTimer = nil end
    if thumbFadeTimer then thumbFadeTimer:stop(); thumbFadeTimer = nil end
    if not thumbCanvas then return end
    local c = thumbCanvas
    thumbCanvas = nil
    local steps = math.max(1, math.floor(THUMB_FADE * 30))
    local step = 0
    thumbFadeTimer = hs.timer.doEvery(THUMB_FADE / steps, function()
        step = step + 1
        if step >= steps then
            pcall(function() c:delete() end)
            if thumbFadeTimer then thumbFadeTimer:stop(); thumbFadeTimer = nil end
            return
        end
        pcall(function() c:alpha(1 - step / steps) end)
    end)
end

local function showThumbnail(path, img)
    -- Stop any in-progress fade from a previous dismissal (must be before thumbCanvas check
    -- because dismissThumbnail nils thumbCanvas while fade timer still runs)
    if thumbFadeTimer then thumbFadeTimer:stop(); thumbFadeTimer = nil end
    if thumbCanvas then
        if thumbSlideTimer then thumbSlideTimer:stop(); thumbSlideTimer = nil end
        if thumbDismissTimer then thumbDismissTimer:stop(); thumbDismissTimer = nil end
        thumbCanvas:delete()
        thumbCanvas = nil
    end

    local imgSize = img:size()
    local scale = math.min(THUMB_MAX_W / imgSize.w, THUMB_MAX_W / imgSize.h)
    if scale > 1 then scale = 1 end
    local tw = math.floor(imgSize.w * scale)
    local th = math.floor(imgSize.h * scale)
    local cw = tw + THUMB_PADDING * 2
    local ch = th + THUMB_PADDING * 2

    local screen = hs.screen.mainScreen():frame()
    local finalX = screen.x + screen.w - cw - 20
    local finalY = screen.y + screen.h - ch - 20
    local startX = screen.x + screen.w + THUMB_SHADOW

    thumbCanvas = hs.canvas.new({ x = startX, y = finalY, w = cw + THUMB_SHADOW, h = ch + THUMB_SHADOW })
    thumbCanvas:level("floating")
    thumbCanvas:clickActivating(false)
    thumbCanvas:behaviorAsLabels({ "canJoinAllSpaces" })

    thumbCanvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = cw, h = ch },
        roundedRectRadii = { xRadius = THUMB_RADIUS, yRadius = THUMB_RADIUS },
        fillColor = { red = 0.15, green = 0.15, blue = 0.15, alpha = 0.95 },
        strokeColor = { white = 1, alpha = 0.15 },
        strokeWidth = 0.5,
        shadow = {
            offset = { h = 2, w = 2 },
            blurRadius = THUMB_SHADOW,
            color = { black = 1, alpha = 0.5 },
        },
        action = "strokeAndFill",
    })
    thumbCanvas:appendElements({
        type = "rectangle",
        frame = { x = THUMB_PADDING, y = THUMB_PADDING, w = tw, h = th },
        roundedRectRadii = { xRadius = THUMB_RADIUS - 4, yRadius = THUMB_RADIUS - 4 },
        action = "clip",
    })
    thumbCanvas:appendElements({
        type = "image",
        frame = { x = THUMB_PADDING, y = THUMB_PADDING, w = tw, h = th },
        image = img,
        imageScaling = "scaleProportionally",
    })
    thumbCanvas:appendElements({ type = "resetClip" })

    thumbCanvas:show()

    thumbCanvas:mouseCallback(function(_, message, id, x, y)
        if message == "mouseUp" then
            hs.task.new("/usr/bin/open", nil, {"-a", "Preview", path}):start()
            dismissThumbnail()
        end
    end)
    thumbCanvas:canvasMouseEvents(true, true)

    local slideSteps = math.max(1, math.floor(THUMB_SLIDE_DUR * THUMB_SLIDE_FPS))
    local slideStep = 0
    local dist = startX - finalX
    local thisCanvas = thumbCanvas  -- capture ref to avoid stale global access
    thumbSlideTimer = hs.timer.doEvery(THUMB_SLIDE_DUR / slideSteps, function()
        slideStep = slideStep + 1
        if slideStep >= slideSteps then
            if thisCanvas == thumbCanvas then  -- still the active canvas
                thisCanvas:topLeft({ x = finalX, y = finalY })
            end
            if thumbSlideTimer then thumbSlideTimer:stop(); thumbSlideTimer = nil end
            return
        end
        if thisCanvas ~= thumbCanvas then  -- canvas was replaced
            if thumbSlideTimer then thumbSlideTimer:stop(); thumbSlideTimer = nil end
            return
        end
        local t = slideStep / slideSteps
        local ease = 1 - (1 - t) ^ 3
        thisCanvas:topLeft({ x = startX - dist * ease, y = finalY })
    end)

    thumbDismissTimer = hs.timer.doAfter(THUMB_DISMISS, dismissThumbnail)
end

local function processScreenshot(path)
    local img = hs.image.imageFromPath(path)
    if not img then return end
    if lastProcessed == path then return end
    lastProcessed = path

    -- Copy to clipboard: PNG (web file inputs) + TIFF (native apps) if available
    local pngFile = io.open(path, "rb")
    if not pngFile then return end
    local pngData = pngFile:read("*a")
    pngFile:close()
    if not pngData or #pngData == 0 then return end

    local clipData = { ["public.png"] = pngData }

    local tempPath = "/tmp/hs_screenshot_" .. tostring(os.clock()):gsub("%.", "") .. ".tiff"
    if img:saveToFile(tempPath, "tiff") then
        local tiffFile = io.open(tempPath, "rb")
        if tiffFile then
            clipData["public.tiff"] = tiffFile:read("*a")
            tiffFile:close()
        end
    end
    os.remove(tempPath)

    hs.pasteboard.clearContents()
    hs.pasteboard.writeAllData(clipData)

    local snd = hs.sound.getByName("Pop")
    if snd then snd:play() end

    showThumbnail(path, img)
end

screenshotWatcher = hs.pathwatcher.new(screenshotDir, function(files)
    for _, path in ipairs(files) do
        if path:match("Screenshot.+%.png$") then
            local attrs = hs.fs.attributes(path)
            if attrs and attrs.mode == "file" then
                if screenshotProcessTimer then screenshotProcessTimer:stop() end
                screenshotProcessTimer = hs.timer.doAfter(0.1, function() processScreenshot(path) end)
            end
        end
    end
end)
screenshotWatcher:start()
