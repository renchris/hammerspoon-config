-- Dynamic ⌥+number bindings based on Dock pinned app order
-- Auto-updates when Dock changes; disables in terminals for tmux M-1..M-9.

-- Enable IPC for CLI control
hs.ipc.cliInstall()

-- Cleanup on reload (prevent duplicate watchers/timers from hs.reload())
if screenshotPollTimer then screenshotPollTimer:stop() end
if thumbCanvas then thumbCanvas:delete() end
if thumbDismissTimer then thumbDismissTimer:stop() end
if thumbSlideTimer then thumbSlideTimer:stop() end
if dockRebindTimer then dockRebindTimer:stop() end
if screenshotTimers then for _, t in pairs(screenshotTimers) do if t then t:stop() end end end
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

-- Screenshot clipboard: notice new PNGs in ~/Screenshots, auto-copy to clipboard.
-- Native Cmd+Shift+3/4 handles capture (Sequoia intercepts before userspace).
-- show-thumbnail is disabled so files save instantly to disk.
-- Detection is a directory POLL (see the "Detection is a POLL" block below), never FSEvents:
-- fseventsd on this machine delivers minutes late or never, and every screenshot it lost was lost
-- in total silence. Dedup is by NAME — an entry is handled once, the first time it is seen — which
-- also retires the old size:mtime identity check: with no event stream there is no metadata-only
-- re-delivery (Preview's quarantine xattr on click) to defend against.

local screenshotDir = os.getenv("HOME") .. "/Screenshots"
thumbCanvas = nil          -- global: prevent GC of visible canvas
thumbDismissTimer = nil    -- global: prevent GC of active timer
thumbSlideTimer = nil      -- global: prevent GC of active timer
screenshotTimers = {}      -- global: per-path settle timers (replaces the single debounce timer)

-- Observability: `hs.logger` for the HS console, PLUS an append-only file log. The console is wiped
-- by every reload, and — measured 2026-09-08 — cannot even be read back over hs.ipc while the
-- machine is loaded (the `hs` CLI aborts on the large reply). A file survives both, and answers
-- "did the 3:46 PM screenshot copy, and how long did it take?" after the fact:
--     tail -f ~/Library/Logs/Hammerspoon/screenshot.log
-- Millisecond timestamps, because the whole pipeline is measured in tens of milliseconds.
-- Truncated at load once it passes SHOT_LOG_MAX (a screenshot is ~2 lines; that is years).
local slog = hs.logger.new("screenshot", "info")
local SHOT_LOG_DIR = os.getenv("HOME") .. "/Library/Logs/Hammerspoon"
local SHOT_LOG     = SHOT_LOG_DIR .. "/screenshot.log"
local SHOT_LOG_MAX = 1024 * 1024
hs.fs.mkdir(SHOT_LOG_DIR)
do
    local a = hs.fs.attributes(SHOT_LOG)
    if a and (a.size or 0) > SHOT_LOG_MAX then os.remove(SHOT_LOG) end
end
local function shotlog(level, fmt, ...)
    local msg = string.format(fmt, ...)
    if level == "w" then slog.w(msg) elseif level == "e" then slog.e(msg) else slog.i(msg) end
    local f = io.open(SHOT_LOG, "a")
    if f then
        local now = hs.timer.secondsSinceEpoch()
        f:write(string.format("%s.%03d %s %s\n", os.date("%Y-%m-%d %H:%M:%S", math.floor(now)),
                              math.floor((now % 1) * 1000), level:upper(), msg))
        f:close()
    end
end

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

    -- The screen the pointer is on: the selection was just drawn there, so that is where the eye is.
    -- mainScreen() is the screen of the FOCUSED WINDOW, which on a multi-display desk can be the
    -- other monitor — the thumbnail then slides in where nobody is looking.
    local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
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
-- Bounded wait, sized for a LOADED machine: macOS renames the finished PNG into place, so the
-- normal case settles on the first poll, but a non-atomic writer (Finder copy, a sync client)
-- under load 200+ can take seconds. Giving up early strands the file: a name is handled once.
local COPY_MAX_S  = 10     -- give up after 10s (never hang the poller; one warning line)
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
        shotlog("i", "copied %s — %d bytes, %.0fx%.0f, settled %.0fms, cc=%d",
               path:match("[^/]+$"), #data, sz.w, sz.h, waited, hs.pasteboard.changeCount())
        local snd = hs.sound.getByName("Pop"); if snd then snd:play() end
        showThumbnail(path, img)  -- thumbnail/sound now appear ONLY after a verified copy
        return "done"
    end
    shotlog("e", "clipboard write failed: %s", path:match("[^/]+$") or path)
    return "gone"
end

-- Per-path settle driver. Each screenshot gets its OWN timer (keyed by path) so rapid successive
-- shots no longer clobber a single shared debounce timer — every one lands independently.
local function settleScreenshot(path, startNs, st)
    -- A Lua error inside a one-shot timer callback kills only this path's settle, but it does so
    -- silently and leaves its slot reserved. Contain it: log, free the slot, move on.
    local ok, status = pcall(settleStep, path, startNs, st)
    if not ok then
        shotlog("e", "settle error on %s: %s", path:match("[^/]+$") or path, tostring(status))
        screenshotTimers[path] = nil
        return
    end
    if status == "done" or status == "gone" then
        screenshotTimers[path] = nil
        return
    end
    if (hs.timer.absoluteTime() - startNs) / 1e9 >= COPY_MAX_S then
        shotlog("w", "gave up after %.1fs waiting for complete PNG: %s", COPY_MAX_S, path:match("[^/]+$") or path)
        screenshotTimers[path] = nil
        return
    end
    screenshotTimers[path] = hs.timer.doAfter(COPY_POLL_S, function() settleScreenshot(path, startNs, st) end)
end

-- Match the FINAL screenshot only. macOS writes a hidden temp first (".Screenshot X.png" on the
-- keyboard path; "..name.png-XXXX" then ".name.png" from the CLI) and atomically renames it to
-- "Screenshot X.png" once the PNG is complete. Anchoring on the basename with ^ excludes every temp
-- spelling, so the final name is the only one ever handled — and it only ever appears complete.
local function isScreenshotFinal(name)
    return name ~= nil and name:match("^Screenshot.+%.png$") ~= nil
end

-- Detection is a POLL — never FSEvents, and never launchd WatchPaths either.
--
-- Measured 2026-09-07/08 on this machine: load average 223 on 10 cores, fseventsd pinned at 100 % of
-- a core for 13 days, fed ~250 FSEvents client registrations an hour by the Claude Code fleet (the
-- fseventsd log is a wall of `fsevent_add_client` lines from claude processes). Under that, the
-- hs.pathwatcher this block replaces delivered events minutes late or not at all:
--   * its liveness watchdog re-armed it 35 times in ONE day ("no event in 120s"), and because a
--     re-arm builds a new stream, each one discarded whatever was still queued;
--   * 5 of the day's 13 screenshots — including all four taken while this was being investigated —
--     never produced even a "detected" line;
--   * a `touch` probe on the same directory was still undelivered after 40 s;
--   * the launchd WatchPaths agent on the same directory did not fire in 20 s either.
-- A stat() of the directory, meanwhile, costs 27 µs and answers immediately, because it asks the
-- kernel and not fseventsd. So: stat the directory every SCAN_POLL_S. Its mtime, ctime and size all
-- change whenever an entry is created, deleted or renamed (APFS reports a directory's size as 32
-- bytes per entry), so a changed signature means "something happened", and only then is the
-- directory listed and diffed against the names already seen (~8 ms for 3,300 entries).
--
-- The signature alone is not sufficient, and the gap is exactly a same-second rename: hs.fs
-- timestamps are whole seconds and a rename moves no entry, so a temp file created and renamed
-- within the SAME second as the previous change leaves mtime, ctime and size all unchanged. While
-- the directory's mtime is still the current second, therefore, keep scanning every other tick —
-- at most ~10 scans (~80 ms of CPU), only in the second something changed, never in the idle state.
-- Worst-case detection latency is one poll interval plus one scan, and there is no queue to lose.
--
-- The poll timer is created with continueOnError = true. hs.timer.doEvery defaults to stopping the
-- timer on the first Lua error in its callback, which would turn any transient fault (a directory
-- that momentarily fails to list) into a silent, permanent loss of detection — the very failure
-- shape this rewrite exists to remove. Errors are logged and the poll goes on.
local SCAN_POLL_S = 0.05   -- one 27 µs stat per tick; detection latency ≤ 50 ms + one scan
local HOT_EVERY   = 2      -- while the change-second is still current, scan every 2nd tick

knownEntries        = {}   -- global: basename -> true for every entry already seen (dedup by name)
screenshotPollTimer = nil  -- global: prevent GC of the poll timer
local dirSig        = nil  -- last observed "mtime:ctime:size" of the directory
local tickCount     = 0
local dirWarned     = false
local scanErrWarned = false

-- List the directory and start a settle for every screenshot not seen before. `markOnly` is the
-- startup pass: everything already present is remembered but NOT copied. Deliberately not
-- retroactive — a screenshot taken before a reload was already handled (or the user has long since
-- retaken it), and overwriting whatever they have since copied would be a worse bug than the one
-- being fixed.
local function scanScreenshotDir(markOnly)
    local found = {}
    local ok, err = pcall(function()
        for name in hs.fs.dir(screenshotDir) do
            if not knownEntries[name] then
                knownEntries[name] = true
                if not markOnly and isScreenshotFinal(name) then found[#found + 1] = name end
            end
        end
    end)
    if not ok then
        if not scanErrWarned then
            shotlog("e", "cannot list %s: %s", screenshotDir, tostring(err))
            scanErrWarned = true
        end
        return
    end
    scanErrWarned = false
    table.sort(found)   -- oldest first when several land in one scan (names embed the time)
    for _, name in ipairs(found) do
        local path = screenshotDir .. "/" .. name
        local attrs = hs.fs.attributes(path)
        if attrs and attrs.mode == "file" and not screenshotTimers[path] then
            shotlog("i", "detected %s (%s bytes, %ds old)", name, tostring(attrs.size),
                   os.time() - (attrs.modification or os.time()))
            local startNs = hs.timer.absoluteTime()
            local st = { size = -1, count = 0 }
            -- Reserve the slot immediately (guards duplicate fires) then settle on the next tick.
            screenshotTimers[path] = hs.timer.doAfter(0, function() settleScreenshot(path, startNs, st) end)
        end
    end
end

local function pollScreenshotDir()
    local a = hs.fs.attributes(screenshotDir)
    if not a or a.mode ~= "directory" then
        if not dirWarned then
            shotlog("w", "%s is missing — screenshots cannot be detected until it exists", screenshotDir)
            dirWarned = true
        end
        return
    end
    dirWarned = false
    tickCount = tickCount + 1
    local sig = string.format("%d:%d:%d", a.modification or 0, a.change or 0, a.size or 0)
    local changed = sig ~= dirSig
    -- Hot: the directory's latest change is in the current second, so a further change in this
    -- same second could not alter the signature. Keep looking until the clock moves on.
    local hot = (a.modification or 0) >= os.time()
    if changed or (hot and tickCount % HOT_EVERY == 0) then
        dirSig = sig
        scanScreenshotDir(false)
    end
end

-- Arm: remember what is already there, drop the retired FSEvents watchdog's canary, start polling.
scanScreenshotDir(true)
os.remove(screenshotDir .. "/.hs-fsevents-canary")
screenshotPollTimer = hs.timer.new(SCAN_POLL_S, function()
    local ok, err = pcall(pollScreenshotDir)
    if not ok then shotlog("e", "poll error: %s", tostring(err)) end
end, true)
screenshotPollTimer:start()
do
    local n = 0
    for _ in pairs(knownEntries) do n = n + 1 end
    shotlog("i", "screenshot poll armed on %s — %d entries known, every %.0f ms", screenshotDir, n, SCAN_POLL_S * 1000)
end
