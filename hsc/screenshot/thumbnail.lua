-- hsc/screenshot/thumbnail.lua — the bottom-right preview, built where it lands.
--
-- 🚨 THE SLIDE IS GONE, AND THAT IS THE PHASE'S WHOLE POINT (E1, measured).  The shipped entrance
-- built the canvas at x = screen width + 12 — fully OFF-SCREEN — and animated it in with a Lua
-- timer at THUMB_SLIDE_DUR/THUMB_SLIDE_FPS, which yields THREE frames; the first on-screen pixel
-- appeared 83 ms after show(), a third of the entire visible budget, and the timer state it needed
-- is where two shipped bugs lived (664d809, e4713ad).  The replacement is one call:
-- `canvas:show(0.12)` — a Core Animation fade on the WINDOW SERVER, 0.02–0.05 ms of main thread,
-- no timer, no globals, no state to get wrong.
--
-- Everything else from those four fix commits is ported here as LITERAL CODE WITH ITS COMMENTS:
-- the dismissal is armed FIRST, every callback addresses its OWN canvas rather than reading a
-- shared handle, the fade is delegated to hs.canvas:hide(seconds), and each timer stops its own
-- handle rather than a field that a newer thumbnail may already have reassigned.
local log     = require("hsc.log")
local clock   = require("hsc.clock")

local M = {}

local cfg = {
  maxW = 320, padding = 16, radius = 10, shadow = 12,
  dismiss = 3, fade = 0.3, entrance = 0.12,
}

-- Module-scope, not global.  A table reachable from package.loaded anchors a canvas or a timer
-- against garbage collection exactly as well as a global does (measured: 50 ticks vs 0 for an
-- unanchored local), so the config needs no feature globals at all (F1 report).
local current      = nil   -- the visible canvas
local dismissTimer = nil
local visTimer     = nil
local screens      = {}    -- cached {full=, frame=} — refreshed by hs.screen.watcher, never per shot
local screenWatcher = nil
local resolver     = nil   -- function(ino) -> current path, injected by the orchestrator

local function refreshScreens()
  local list = {}
  for _, s in ipairs(hs.screen.allScreens()) do
    list[#list + 1] = { full = s:fullFrame(), frame = s:frame() }
  end
  screens = list
end

--- The screen the POINTER is on: the selection was just drawn there, so that is where the eye is.
--- mainScreen() is the screen of the FOCUSED WINDOW, which on a multi-display desk can be the other
--- monitor — the thumbnail then appears where nobody is looking.
--- Containment is tested against a CACHED frame table.  hs.mouse.getCurrentScreen() does this same
--- containment inside the Lua wrapper; caching the frames is cleaner, not a latency lever (the real
--- cost was a first-call module load, ~8 µs thereafter — F2 corrected the 20 ms figure).
local function pointerFrame()
  if #screens == 0 then refreshScreens() end
  local p = hs.mouse.absolutePosition()
  if p then
    for _, s in ipairs(screens) do
      local f = s.full
      if p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h then return s.frame end
    end
  end
  local main = hs.screen.mainScreen()
  return main and main:frame() or { x = 0, y = 0, w = 1440, h = 900 }
end

-- Fade-out is delegated to hs.canvas:hide(seconds) instead of a hand-rolled alpha loop, for
-- CORRECTNESS, not brevity. hs.canvas anchors a fading canvas in Hammerspoon's own Lua registry for
-- the duration of the fade and always orders the window out at the end, so the fade cannot be
-- interrupted or abandoned. The loop this replaces held the ONLY reference to a still-VISIBLE canvas
-- inside a stoppable timer closure, and both callers below stop that timer: a click landing during
-- the 300ms fade (mouseCallback → dismiss → stops the fade, then returns early because `current` is
-- already nil) or the next screenshot arriving mid-fade would drop the last reference without ever
-- hiding the window. hs.canvas:delete() is only an alias for :hide() in Hammerspoon 1.1.1 — the
-- window is destroyed solely by Lua __gc — so the stranded canvas stayed fully visible and still
-- clickable (clicking it re-opened the screenshot in Preview) until a GC happened to run. On
-- Hammerspoon's idle ~800KB heap that can be days, which is why it looked permanent.
-- `only` scopes the dismissal to one specific canvas. A thumbnail stays clickable while it fades, so
-- a click landing on a FADING thumbnail must not tear down the NEXT one that has already replaced it
-- — unscoped, that click stopped the successor's timers and hid it barely after it appeared.
local function dismiss(only, id, file)
  if only and only ~= current then return end
  if visTimer then visTimer:stop(); visTimer = nil end
  if dismissTimer then dismissTimer:stop(); dismissTimer = nil end
  if not current then return end
  local c = current
  current = nil
  pcall(function() c:hide(cfg.fade) end)
  if id then log.emit("dismissed", { id = id, file = file }) end
  -- Reclaim earlier thumbnails' windows. Because :delete() only hides, a canvas's NSWindow is
  -- destroyed solely by Lua __gc, and an idle sub-megabyte heap can go days without collecting —
  -- that delay is what made the stranded thumbnail look permanent. Nudging GC here keeps
  -- ordered-out canvases from piling up and bounds any future orphan to seconds. Off the capture
  -- latency path (this runs 3s after the copy) and sub-millisecond on a heap this small.
  collectgarbage("collect")
end

--- Start the module.  `opts.resolve(ino)` returns the CURRENT path for an inode; the click handler
--- calls it at click time, so a thumbnail shown against the hidden name still opens the real file.
function M.start(opts)
  opts = opts or {}
  for k, v in pairs(opts.config or {}) do cfg[k] = v end
  -- Only when one is supplied: benchMode() re-enters start() to flip `dismiss`, and
  -- clearing the resolver there would leave every later thumbnail clicking a stale path.
  if opts.resolve then resolver = opts.resolve end
  refreshScreens()
  if not screenWatcher then
    screenWatcher = hs.screen.watcher.new(refreshScreens)
    screenWatcher:start()
  end
  return true
end

function M.stop()
  if visTimer then visTimer:stop(); visTimer = nil end
  if dismissTimer then dismissTimer:stop(); dismissTimer = nil end
  if current then pcall(function() current:delete() end); current = nil end
  if screenWatcher then screenWatcher:stop(); screenWatcher = nil end
end

--- Show the thumbnail for a shot.  `shot` carries { ino, id, path, file, createdNs }.
--- Called ONLY after a verified clipboard write: the PNG bytes need no decode to reach the
--- pasteboard, and hs.image's decode is ~47 ms for a 2.4 MB capture at 2× (E1 §5) — so decoding
--- first would delay the clipboard by that much on every large shot for no reason.
function M.show(shot, img)
  if not img then return false end

  -- A previous thumbnail that is mid-fade needs no handling here: it is owned by hs.canvas until
  -- its fade completes and it orders itself out. Only the ACTIVE canvas has to be torn down.
  if current then
    if visTimer then visTimer:stop(); visTimer = nil end
    if dismissTimer then dismissTimer:stop(); dismissTimer = nil end
    current:delete()
    current = nil
  end

  local size = img:size()
  local scale = math.min(cfg.maxW / size.w, cfg.maxW / size.h)
  if scale > 1 then scale = 1 end
  local tw, th = math.floor(size.w * scale), math.floor(size.h * scale)
  local cw, ch = tw + cfg.padding * 2, th + cfg.padding * 2

  local screen = pointerFrame()
  -- Built AT its final position. The canvas box carries the shadow's bleed on the right and
  -- bottom, so the visible card still sits 20 pt clear of the screen edges.
  local x = screen.x + screen.w - cw - 20
  local y = screen.y + screen.h - ch - 20

  local c = hs.canvas.new({ x = x, y = y, w = cw + cfg.shadow, h = ch + cfg.shadow })
  c:level("floating")
  c:clickActivating(false)
  c:behaviorAsLabels({ "canJoinAllSpaces" })
  c:appendElements({
    type = "rectangle",
    frame = { x = 0, y = 0, w = cw, h = ch },
    roundedRectRadii = { xRadius = cfg.radius, yRadius = cfg.radius },
    fillColor = { red = 0.15, green = 0.15, blue = 0.15, alpha = 0.95 },
    strokeColor = { white = 1, alpha = 0.15 },
    strokeWidth = 0.5,
    shadow = { offset = { h = 2, w = 2 }, blurRadius = cfg.shadow, color = { black = 1, alpha = 0.5 } },
    action = "strokeAndFill",
  })
  c:appendElements({
    type = "rectangle",
    frame = { x = cfg.padding, y = cfg.padding, w = tw, h = th },
    roundedRectRadii = { xRadius = cfg.radius - 4, yRadius = cfg.radius - 4 },
    action = "clip",
  })
  c:appendElements({
    type = "image",
    frame = { x = cfg.padding, y = cfg.padding, w = tw, h = th },
    image = img,
    imageScaling = "scaleProportionally",
  })
  c:appendElements({ type = "resetClip" })

  current = c
  -- This call's own canvas. Every callback below addresses it explicitly rather than reading the
  -- module handle, so a late callback can only ever act on the thumbnail it belongs to.
  local thisCanvas = c

  -- Arm the dismissal FIRST: nothing below may leave a thumbnail on screen with no scheduled
  -- teardown if it errors.
  dismissTimer = hs.timer.doAfter(cfg.dismiss, function() dismiss(thisCanvas, shot.id, shot.file) end)

  c:mouseCallback(function(_, message)
    if message == "mouseUp" then
      local target = shot.path
      if resolver then target = resolver(shot.ino) or target end
      hs.task.new("/usr/bin/open", nil, { "-a", "Preview", target }):start()
      dismiss(thisCanvas, shot.id, shot.file)
    end
  end)
  c:canvasMouseEvents(true, true)

  c:show(cfg.entrance)
  log.emit("thumb-shown", { id = shot.id, dt = clock.mono() - shot.createdNs,
                            x = x, y = y, w = cw, h = ch, file = shot.file })

  -- 🚨 NO SOUND, AND IT STAYS GONE.  The Pop that used to play here was hs.sound:play() — a
  -- SYNCHRONOUS AudioQueue start on this main thread.  On 2026-10-09 coreaudiod stopped answering
  -- (its client thread was parked in a TCC preflight) and that one call sat through eight 30 s HAL
  -- timeouts: Hammerspoon frozen 264 s, 21:29:42 → 21:34:06, with the screenshot poll, the
  -- smartpaste tap and every hotkey dead.  The thumbnail is the confirmation.  An afplay child is
  -- not a substitute: a fresh audio client per shot is the shape that parked coreaudiod.

  -- `phase=thumb-visible` comes from isOccluded(), which is the ORACLE: it reports whether the
  -- window server is actually presenting this window. isShowing() is NOT one — it returns true for
  -- a canvas ordered in at (4000,4000) with no display under it (F1 addendum §16).
  -- The timer stops its OWN handle rather than the module field, because a newer thumbnail may
  -- already have reassigned that field by the time this one finishes (the 85b003c lesson).
  local started = clock.mono()
  local probe
  probe = hs.timer.doEvery(0.010, function()
    if thisCanvas ~= current then probe:stop(); if visTimer == probe then visTimer = nil end; return end
    local occluded = true
    local ok, res = pcall(function() return thisCanvas:isOccluded() end)
    if ok then occluded = res end
    if not occluded then
      log.emit("thumb-visible", { id = shot.id, dt = clock.mono() - shot.createdNs,
                                  since_shown = clock.mono() - started, file = shot.file })
      probe:stop(); if visTimer == probe then visTimer = nil end
      return
    end
    if (clock.mono() - started) > 2e9 then
      log.warn("thumb-visible-timeout", { msg = "canvas still occluded after 2s", file = shot.file })
      probe:stop(); if visTimer == probe then visTimer = nil end
    end
  end)
  visTimer = probe
  return true
end

function M.stats()
  return { visible = current ~= nil, screens = #screens, sound = false,
           dismiss = cfg.dismiss, entrance = cfg.entrance }
end

return M
