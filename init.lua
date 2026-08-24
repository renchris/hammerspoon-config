-- Dynamic ⌥+number bindings based on Dock pinned app order
-- Auto-updates when Dock changes; disables in terminals for tmux M-1..M-9.

-- Enable IPC for CLI control
hs.ipc.cliInstall()

-- Cleanup on reload (prevent duplicate watchers/timers from hs.reload())
if screenshotWatcher then screenshotWatcher:stop() end
if thumbCanvas then thumbCanvas:delete() end
if thumbDismissTimer then thumbDismissTimer:stop() end
if thumbSlideTimer then thumbSlideTimer:stop() end
if dockRebindTimer then dockRebindTimer:stop() end
if screenshotProcessTimer then screenshotProcessTimer:stop() end
if screenshotTimers then for _, t in pairs(screenshotTimers) do if t then t:stop() end end end
if caffeinateWatcher then caffeinateWatcher:stop() end
if fsWatchdogTimer then fsWatchdogTimer:stop() end
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

-- Terminal apps — keyed by BUNDLE ID, never by display name.
--
-- This table used to be name-keyed (`Kitty = true, iTerm2 = true, …`) and it silently missed kitty:
-- Hammerspoon reports kitty's name as "kitty" (lowercase, from its CFBundleName), so the lookup
-- `terminalApps[front:name()]` evaluated to nil and BOTH behaviours that depend on this table were
-- dead in kitty — the ⌥+digits passthrough for tmux, and the ⌘V→⌃V rewrite that lets Claude Code
-- accept a ⌘⇧4 screenshot from the clipboard. It kept working in iTerm2 for the accidental reason
-- that iTerm2's CFBundleName is exactly "iTerm2", so its key matched. Verified live 2026-07-31:
--   terminalApps["kitty"] = nil        (hs.application.find("kitty"):name() == "kitty")
-- Ghostty was absent altogether, so it never worked there either.
--
-- Bundle ids are case-exact, stable across renames, and — unlike a display name — cannot drift with
-- however the vendor capitalises the app. Same lesson as the AppleScript `application id` fix: an
-- app is identified by its id, and a name lookup is a silent miss waiting to happen.
local terminalBundleIDs = {
  ["net.kovidgoyal.kitty"]   = true,  -- kitty
  ["com.googlecode.iterm2"]  = true,  -- iTerm2  (bundle on disk is iTerm.app)
  ["com.mitchellh.ghostty"]  = true,  -- Ghostty
  ["com.github.wez.wezterm"] = true,  -- WezTerm
  ["com.apple.Terminal"]     = true,  -- Terminal
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
  if not status or not output then
    print("WARNING: python3 not found or plist read failed — Dock shortcuts unavailable")
    return {}
  end

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

-- Takes an hs.application OBJECT (not a name), so the decision is made on the bundle id. Callers
-- that only had a name string now pass the app object the API already hands them.
local function isTerminalApp(app)
  if not app then return false end
  local ok, id = pcall(function() return app:bundleID() end)
  return ok and id ~= nil and terminalBundleIDs[id] == true
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
  if isTerminalApp(front) then
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
-- The watcher's THIRD argument is the hs.application object; take the id from it rather than
-- re-deriving one from appName, which is the name lookup this fix exists to remove.
appWatcher = hs.application.watcher.new(function(appName, event, appObject)
  if event == hs.application.watcher.activated then
    setHotkeysEnabled(not isTerminalApp(appObject))
  end
end)
appWatcher:start()

-- Manual refresh: ⌥+⌘+R
manualRefreshHotkey = hs.hotkey.bind({ "alt", "cmd" }, "R", rebind)

-- Initial bind
rebind()

-- Smart paste: Cmd+V sends Ctrl+V for images in terminals, Cmd+V otherwise
-- Reuses the terminalBundleIDs table + isTerminalApp() from the Dock bindings above

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
    if not (isTerminalApp(front) and clipboardHasImage()) then
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
-- Dedup keyed on file IDENTITY (size:mtime), not just "the last path we copied". FSEvents watches
-- with file-level flags, so a metadata-only change re-delivers the path: opening a screenshot from
-- the thumbnail makes Preview write a com.apple.quarantine xattr, which used to sail past the
-- single-slot check whenever another screenshot had copied in between — silently re-copying an OLD
-- screenshot over the clipboard, replaying the sound and popping a second thumbnail. Size and mtime
-- are untouched by an xattr write, so an unchanged file is now ignored.
processedShots = {}        -- global: path -> "size:mtime" recorded ONLY after a verified copy
processedCount = 0         -- global: entry count, so the table can be bounded
screenshotTimers = {}      -- global: per-path settle timers (replaces the single debounce timer)

local PROCESSED_MAX = 500  -- bound the table; screenshots per Hammerspoon session are far fewer

local function shotStamp(attrs)
    return string.format("%d:%d", attrs.size or 0, attrs.modification or 0)
end

-- Observability: `hs.logger` so future clipboard regressions are visible in the HS console.
local slog = hs.logger.new("screenshot", "info")

local THUMB_MAX_W     = 320
local THUMB_PADDING   = 16
local THUMB_RADIUS    = 10
local THUMB_SHADOW    = 12
local THUMB_DISMISS   = 3
local THUMB_FADE      = 0.3
local THUMB_SLIDE_DUR = 0.25
local THUMB_SLIDE_FPS = 15

-- Fade-out is delegated to hs.canvas:hide(seconds) instead of a hand-rolled alpha loop, for
-- CORRECTNESS, not brevity. hs.canvas anchors a fading canvas in Hammerspoon's own Lua registry for
-- the duration of the fade and always orders the window out at the end, so the fade cannot be
-- interrupted or abandoned. The loop this replaces held the ONLY reference to a still-VISIBLE canvas
-- inside a stoppable timer closure, and both callers below stop that timer: a click landing during
-- the 300ms fade (mouseCallback → dismissThumbnail → stops the fade, then returns early because
-- thumbCanvas is already nil) or the next screenshot arriving mid-fade would drop the last reference
-- without ever hiding the window. hs.canvas:delete() is only an alias for :hide() in Hammerspoon
-- 1.1.1 — the window is destroyed solely by Lua __gc — so the stranded canvas stayed fully visible
-- and still clickable (clicking it re-opened the screenshot in Preview) until a GC happened to run.
-- On Hammerspoon's idle ~800KB heap that can be days, which is why it looked permanent.
-- `only` scopes the dismissal to one specific canvas. A thumbnail stays clickable while it fades, so
-- a click landing on a FADING thumbnail must not tear down the NEXT one that has already replaced it
-- — unscoped, that click stopped the successor's timers and hid it barely after it appeared.
local function dismissThumbnail(only)
    if only and only ~= thumbCanvas then return end
    if thumbSlideTimer then thumbSlideTimer:stop(); thumbSlideTimer = nil end
    if thumbDismissTimer then thumbDismissTimer:stop(); thumbDismissTimer = nil end
    if not thumbCanvas then return end
    local c = thumbCanvas
    thumbCanvas = nil
    pcall(function() c:hide(THUMB_FADE) end)
    -- Reclaim earlier thumbnails' windows. Because :delete() only hides, a canvas's NSWindow is
    -- destroyed solely by Lua __gc, and an idle sub-megabyte heap can go days without collecting —
    -- that delay is what made the stranded thumbnail look permanent. Nudging GC here keeps
    -- ordered-out canvases from piling up and bounds any future orphan to seconds. Off the capture
    -- latency path (this runs 3s after the copy) and sub-millisecond on a heap this small.
    collectgarbage("collect")
end

local function showThumbnail(path, img)
    -- A previous thumbnail that is mid-fade needs no handling here: it is owned by hs.canvas until
    -- its fade completes and it orders itself out. Only the ACTIVE canvas has to be torn down.
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

    -- This call's own canvas. Every callback below addresses it explicitly rather than reading the
    -- global, so a late callback can only ever act on the thumbnail it belongs to.
    local thisCanvas = thumbCanvas

    -- Arm the dismissal FIRST: nothing below may leave a thumbnail on screen with no scheduled
    -- teardown if it errors.
    thumbDismissTimer = hs.timer.doAfter(THUMB_DISMISS, function() dismissThumbnail(thisCanvas) end)

    thumbCanvas:mouseCallback(function(_, message, id, x, y)
        if message == "mouseUp" then
            hs.task.new("/usr/bin/open", nil, {"-a", "Preview", path}):start()
            dismissThumbnail(thisCanvas)
        end
    end)
    thumbCanvas:canvasMouseEvents(true, true)

    local slideSteps = math.max(1, math.floor(THUMB_SLIDE_DUR * THUMB_SLIDE_FPS))
    local slideStep = 0
    local dist = startX - finalX
    -- Forward-declared so the closure stops its OWN handle: the global may already have been
    -- reassigned to a newer thumbnail's timer by the time this one finishes.
    local slideTimer
    slideTimer = hs.timer.doEvery(THUMB_SLIDE_DUR / slideSteps, function()
        slideStep = slideStep + 1
        local done = slideStep >= slideSteps
        if done or thisCanvas ~= thumbCanvas then  -- finished, or the canvas was replaced
            if done and thisCanvas == thumbCanvas then
                thisCanvas:topLeft({ x = finalX, y = finalY })
            end
            slideTimer:stop()
            if thumbSlideTimer == slideTimer then thumbSlideTimer = nil end
            return
        end
        local t = slideStep / slideSteps
        local ease = 1 - (1 - t) ^ 3
        thisCanvas:topLeft({ x = startX - dist * ease, y = finalY })
    end)
    thumbSlideTimer = slideTimer
end

-- Reliability tuning for the settle loop.
local COPY_POLL_S = 0.05   -- re-check the file every 50ms while it's still being written
local COPY_MAX_S  = 1.5    -- bounded wait: give up after ~1.5s (never hang the watcher)
-- A complete PNG always ends with the IEND chunk: "IEND" + CRC 0xAE426082. This is the
-- authoritative "the writer is done" signal — imageFromPath alone is NOT (it decodes a
-- header-only 1%-written file and reports full dimensions, which is exactly the stale-copy bug).
local PNG_IEND = "\73\69\78\68\174\66\96\130"
local TIFF_SCRATCH = "hs_screenshot_tiff_scratch"  -- private pasteboard for building a compact TIFF

-- Write PNG (authoritative on-disk bytes) + TIFF (native apps) to the pasteboard, then VERIFY
-- the write actually took (changeCount advanced AND an image UTI is present). Returns true iff verified.
local function copyToClipboard(path, pngData, img)
    local clip = { ["public.png"] = pngData }

    -- TIFF for legacy native apps. NSImage:saveToFile("tiff") emits a 16-bit, 2x-scaled ~247MB blob
    -- (~700ms + a bloated pasteboard) — that disk round-trip was the whole latency problem. Instead
    -- materialize NSImage's own compact 8-bit TIFFRepresentation (~30MB, ~20ms) on a PRIVATE scratch
    -- pasteboard, so the user's real clipboard is never perturbed by intermediate state.
    if hs.pasteboard.writeObjects(img, TIFF_SCRATCH) then
        local tiff = hs.pasteboard.readDataForUTI(TIFF_SCRATCH, "public.tiff")
        if tiff and #tiff > 0 then clip["public.tiff"] = tiff end
    end

    local before = hs.pasteboard.changeCount()
    hs.pasteboard.clearContents()
    local ok = hs.pasteboard.writeAllData(clip)
    if (not ok) or hs.pasteboard.changeCount() <= before or not clipboardHasImage() then
        -- One retry: clear + rewrite before declaring failure.
        hs.pasteboard.clearContents()
        hs.pasteboard.writeAllData(clip)
    end
    return clipboardHasImage()
end

-- One settle iteration. Returns "done" (copied+verified), "gone" (file vanished / hard fail),
-- or "wait" (still being written — poll again). `st` carries size-stability state across polls.
local function settleStep(path, startNs, st)
    local attrs = hs.fs.attributes(path)
    if not attrs or attrs.mode ~= "file" then return "gone" end

    local size = attrs.size or 0
    if size > 0 and size == st.size then st.count = st.count + 1 else st.count = 0 end
    st.size = size
    if size == 0 then return "wait" end

    local f = io.open(path, "rb")
    if not f then return "wait" end
    local data = f:read("*a"); f:close()
    if not data or #data == 0 then return "wait" end

    -- Complete iff the PNG is terminated (IEND) OR the size has been stable ~150ms (fallback for
    -- any non-IEND edge case, so we never wait the full 1.5s on a genuinely-finished file).
    local complete = (#data >= 8 and data:sub(-8) == PNG_IEND) or st.count >= 3
    if not complete then return "wait" end

    local img = hs.image.imageFromPath(path)
    if not img then return "wait" end

    if copyToClipboard(path, data, img) then
        local waited = (hs.timer.absoluteTime() - startNs) / 1e6
        local sz = img:size()
        slog.f("copied %s — %d bytes, %.0fx%.0f, settled %.0fms, cc=%d",
               path:match("[^/]+$"), #data, sz.w, sz.h, waited, hs.pasteboard.changeCount())
        local snd = hs.sound.getByName("Pop"); if snd then snd:play() end
        showThumbnail(path, img)  -- thumbnail/sound now appear ONLY after a verified copy
        return "done"
    end
    slog.ef("clipboard write failed: %s", path:match("[^/]+$") or path)
    return "gone"
end

-- Per-path settle driver. Each screenshot gets its OWN timer (keyed by path) so rapid successive
-- shots no longer clobber a single shared debounce timer — every one lands independently.
local function settleScreenshot(path, startNs, st)
    local status = settleStep(path, startNs, st)
    if status == "done" then
        -- Dedup marker set ONLY after a verified-complete copy, stamped with the identity the file
        -- had when we copied it, so only a genuine content change re-triggers.
        local a = hs.fs.attributes(path)
        if a then
            if processedShots[path] == nil then processedCount = processedCount + 1 end
            processedShots[path] = shotStamp(a)
            if processedCount > PROCESSED_MAX then processedShots = {}; processedCount = 0 end
        end
        screenshotTimers[path] = nil
        return
    end
    if status == "gone" then
        screenshotTimers[path] = nil
        return
    end
    if (hs.timer.absoluteTime() - startNs) / 1e9 >= COPY_MAX_S then
        slog.wf("gave up after %.1fs waiting for complete PNG: %s", COPY_MAX_S, path:match("[^/]+$") or path)
        screenshotTimers[path] = nil
        return
    end
    screenshotTimers[path] = hs.timer.doAfter(COPY_POLL_S, function() settleScreenshot(path, startNs, st) end)
end

-- Match the FINAL screenshot only. macOS writes "~/Screenshots/.Screenshot X.png" (hidden temp)
-- then atomically renames it to "Screenshot X.png". Anchoring on the basename with ^ excludes the
-- incremental dotfile, so we never process a half-written temp.
local function isScreenshotFinal(path)
    local name = path:match("[^/]+$")
    return name ~= nil and name:match("^Screenshot.+%.png$") ~= nil
end

-- Named so the watchdog below can re-arm a FRESH watcher with the same behaviour. Re-arming must
-- build a NEW object: see armScreenshotWatcher for why stop()/start() is not a remedy.
local function onScreenshotEvent(files)
    -- Stamp EVERY delivery, before any filtering. This is the only evidence that the FSEvents
    -- stream is still alive: the watcher object stays non-nil forever whether or not the stream
    -- is delivering, so liveness cannot be read off our own state (see the watchdog below).
    fsLastEventNs = hs.timer.absoluteTime()
    for _, path in ipairs(files) do
        if isScreenshotFinal(path) and not screenshotTimers[path] then
            local attrs = hs.fs.attributes(path)
            if attrs and attrs.mode == "file" and processedShots[path] ~= shotStamp(attrs) then
                slog.f("detected %s (%s bytes)", path:match("[^/]+$"), tostring(attrs.size))
                local startNs = hs.timer.absoluteTime()
                local st = { size = -1, count = 0 }
                -- Reserve the slot immediately (guards duplicate fires) then settle on the next tick.
                screenshotTimers[path] = hs.timer.doAfter(0, function() settleScreenshot(path, startNs, st) end)
            end
        end
    end
end

-- Re-arm by REPLACING the object, never by stop()/start().
--
-- Measured 2026-08-23, and this is the whole reason the old self-heal below never worked: once this
-- stream stopped delivering, `screenshotWatcher:stop(); screenshotWatcher:start()` did NOT bring it
-- back. The watchdog re-armed it that way three times in a row and every subsequent screenshot was
-- still dropped, with no "detected" line. In the same seconds, on the SAME directory, a freshly
-- constructed `hs.pathwatcher.new(...)` received events immediately — so FSEvents itself was
-- healthy and the fault was the dead object refusing to re-register. Restarting a corpse is not a
-- remedy; only a new watcher is.
local function armScreenshotWatcher()
    if screenshotWatcher then pcall(function() screenshotWatcher:stop() end) end
    screenshotWatcher = hs.pathwatcher.new(screenshotDir, onScreenshotEvent)
    screenshotWatcher:start()
    fsLastEventNs = hs.timer.absoluteTime()   -- clean baseline for the fresh stream
end

armScreenshotWatcher()

-- FSEvents streams can silently stop delivering after sleep/wake — a known cause of screenshots
-- "randomly" not copying until a reload. Restart the watcher on wake / unlock to self-heal.
caffeinateWatcher = hs.caffeinate.watcher.new(function(evt)
    local w = hs.caffeinate.watcher
    if evt == w.systemDidWake or evt == w.screensDidUnlock or evt == w.sessionDidBecomeActive then
        armScreenshotWatcher()   -- was stop()/start(), which provably does not re-arm a dead stream
        slog.i("re-armed screenshot watcher after wake/unlock")
    end
end)
caffeinateWatcher:start()

-- FSEvents liveness watchdog — the stream can also die while the machine stays AWAKE.
--
-- The caffeinate watcher above heals the one cause we knew about (sleep/wake/unlock). It is not
-- sufficient: measured 2026-08-23 on a machine at load ~32 with fseventsd pegged at 100% CPU, this
-- stream had silently stopped delivering with no sleep event involved. The failure is invisible
-- from the inside — `screenshotWatcher` was still a live object, `screenshotTimers` was empty, and
-- `processedCount` read 296 from earlier successes. Two consecutive screenshots (4.0 MB, then
-- 483 KB) copied into the folder produced NOT EVEN a "detected" line: the callback never ran, so
-- every screenshot was dropped in total silence. A stop()/start() fixed it instantly and the next
-- file copied in 35 ms — which also proves the drop was never a latency or load problem. The copy
-- path is fast even on a loaded box; the stream was simply gone.
--
-- So liveness must be PROVEN, never inferred: make an event happen, then confirm it arrives.
-- The canary is deliberately named so it does NOT match isScreenshotFinal() — it exercises the
-- exact same stream without ever entering the screenshot path or touching the clipboard.
--
-- Deliberately NOT retroactive: on detecting a dead stream we restart and log, but do not sweep up
-- screenshots taken while it was down. By the time a 60s probe notices, the user has already
-- retaken the shot, and silently overwriting whatever they have since copied would be a worse bug
-- than the one being fixed.
-- 🚨 GRACE IS SIZED TO THE DELIVERY BAND, NOT TO THE COPY PATH. This distinction is the whole
-- reason the first cut of this watchdog was wrong, and getting it wrong makes the watchdog a CAUSE
-- of the bug it is meant to fix. Measured 2026-08-23 on the loaded box: the copy path itself is
-- 35 ms, but FSEvents took 8.9 SECONDS to deliver the event that starts it — fseventsd was pegged
-- at 100% of a core by this machine's own file churn (35 Claude sessions, 179 worktrees), and a
-- saturated fseventsd inflates delivery latency for every client on the system. A 4s grace
-- therefore fired on a perfectly ALIVE stream: it re-armed three times in a row, and because
-- re-arming builds a new stream it discards whatever was still in flight — turning a slow
-- screenshot into a genuinely lost one.
--
-- So: grace must exceed the worst delivery latency, not the median. 120s is far above the 8.9s
-- observed under heavy load while still catching a truly dead stream within ~7 minutes, which is
-- the right timescale for a failure that is rare and persistent rather than transient.
local FSWD_INTERVAL = 300  -- probe every 5 min; a dead stream is a rare, persistent condition
local FSWD_GRACE    = 120  -- an event this old still counts as delivered (band is ~9s, not ~35ms)
local fswdCanary = screenshotDir .. "/.hs-fsevents-canary"
fsLastEventNs = fsLastEventNs or hs.timer.absoluteTime()
fsWatchdogRestarts = fsWatchdogRestarts or 0

fsWatchdogTimer = hs.timer.doEvery(FSWD_INTERVAL, function()
    if not screenshotWatcher then return end
    local probeNs = hs.timer.absoluteTime()
    local f = io.open(fswdCanary, "w")
    if not f then return end          -- can't probe (folder gone/unwritable) ⇒ assert nothing
    f:write(tostring(probeNs)); f:close()

    hs.timer.doAfter(FSWD_GRACE, function()
        -- Alive iff an event landed at or after the probe write. Restarting on a false negative is
        -- cheap (a stop/start costs nothing and loses nothing); missing a real death is not.
        if fsLastEventNs and fsLastEventNs >= probeNs then return end
        fsWatchdogRestarts = fsWatchdogRestarts + 1
        slog.wf("FSEvents stream stopped delivering (no event in %ds) — re-arming watcher (re-arm #%d)",
                FSWD_GRACE, fsWatchdogRestarts)
        pcall(armScreenshotWatcher)   -- replaces the object; stop()/start() does not work here
    end)
end)
