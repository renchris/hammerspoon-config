-- hsc/screenshot — ⌘⇧4 capture → clipboard → thumbnail, with the dotfile as the file.
--
-- THE ONE IDEA.  `screencapture` writes a COMPLETE PNG under a hidden name, then calls
-- MDItemCreate/MDItemSetAttributes — an unconditional, unguarded Spotlight round trip with no
-- branch to take (B2, disassembly at 0x1000192b4) — and only THEN renames the file to its final
-- name.  That stall is UNBOUNDED: 13.7 s and 29.4 s observed, and the "10 s" in the folklore is
-- mds's per-message watchdog, not a bound.  A watcher keyed on the final name pays all of it; a
-- watcher keyed on the hidden name pays none of it.  Everything else here follows from that.
--
-- THE ORDER OF OPERATIONS IS ITSELF A DESIGN DECISION, measured end to end:
--     poll (10 ms, st_size only) → open the handle at first sight → settle to IEND through the
--     handle → read the bytes → VERIFIED PNG-only pasteboard write → record the inode as copied →
--     decode → thumbnail.
-- The clipboard is reached BEFORE any hs.image decode, because the PNG bytes need no decode to be
-- pasteable and the decode is ~47 ms for a 2.4 MB capture at 2× (E1 §5) — decoding first delayed
-- every large shot's ⌘V for nothing.  The inode is recorded as copied only AFTER the write is
-- verified, because recording it at detection would make the final name look like a duplicate and
-- silently drop the shot (hostile review item 1).
local clock     = require("hsc.clock")
local log       = require("hsc.log")
local watcher   = require("hsc.screenshot.watcher")
local settle    = require("hsc.screenshot.settle")
local clipboard = require("hsc.screenshot.clipboard")
local thumbnail = require("hsc.screenshot.thumbnail")

local M = {}

local cfg = {
  dir            = os.getenv("HOME") .. "/Screenshots",
  pollS          = 0.010,   -- the base timer: stat the directory every tick, i.e. the 10 ms poll
  settleS        = 0.005,   -- the settle timer, alive only while a shot is pending — see below
  backstopS      = 1.0,     -- the net-zero-tick backstop; one listing/s, 2.4 ms, ~0.24 % of a core
  reconcileMax   = 10,      -- bound on the re-list loop after a size change
  creationWindow = 30,      -- a candidate must have been created within this many seconds
  retroWindow    = 15,      -- at arm, copy anything this fresh that has no `copied` record yet
  settleCapS     = 30,      -- the stall is unbounded; 30 s is a give-up, not a model of Apple
  strandedAfterS = 30,      -- un-hide a dotfile screencapture abandoned mid-stall
  clobberAfterS  = 0.3,     -- re-check changeCount: did another app take the clipboard from us?
  copiedTTLS     = 120,     -- how long an inode stays in the dedup table
  tiff           = os.getenv("SCREENSHOT_TIFF") == "true",
}

local state = {
  timer = nil, settleTimer = nil, w = nil, started = false,
  pending = {},          -- ino -> candidate
  copied  = {},          -- ino -> { path, file, t }  (dedup, recorded on VERIFIED copy only)
  counts  = { created = 0, copied = 0, lost = 0, gone = 0, renamed = 0, notpng = 0 },
  startedNs = 0,
}

-- ---------------------------------------------------------------------------------------------
-- Path resolution by inode.  E1 §7: strip the leading dot(s) and make ONE inode check — never scan
-- the directory.  A screenshot's three names differ only by that prefix, so this resolves any of
-- them to whichever one exists right now.
-- ---------------------------------------------------------------------------------------------
-- Apple's three names differ from each other by a LEADING DOT and, for the streaming temp, by a
-- trailing "-XXXX" mkstemp suffix:
--     ..Screenshot X.png-OCez   →   .Screenshot X.png   →   Screenshot X.png
-- E1 §7's rule was "strip the leading dot(s) and make one inode check", which resolves the second
-- hop but NOT the first — measured on the first bench capture, where the candidate was caught under
-- the streaming name and the thumbnail was then silently skipped because no stripped form existed.
-- So the transform drops the suffix as well.  Still ≤ 3 stats and never a directory scan.
local function candidateNames(base)
  local out, seen = {}, {}
  local function add(n)
    if n and n ~= "" and not seen[n] then seen[n] = true; out[#out + 1] = n end
  end
  add(base)
  local undotted = base:gsub("^%.+", "")
  add(undotted)
  add((undotted:gsub("(%.%a+)%-%w+$", "%1")))
  add((base:gsub("(%.%a+)%-%w+$", "%1")))
  return out
end

local function resolvePath(ino, hint)
  local rec = state.copied[ino] or state.pending[ino]
  local tried = {}
  -- Built explicitly: a table constructor with a nil first element leaves index 1 empty and ipairs
  -- would stop immediately, silently skipping the recorded path whenever no hint was passed.
  local roots = {}
  if hint then roots[#roots + 1] = hint end
  if rec and rec.path then roots[#roots + 1] = rec.path end
  for _, p in ipairs(roots) do
    if p and not tried[p] then
      tried[p] = true
      local dir, base = p:match("(.*)/([^/]+)$")
      if dir and base then
        for _, name in ipairs(candidateNames(base)) do
          local cand = dir .. "/" .. name
          local a = hs.fs.attributes(cand)
          if a and a.ino == ino then return cand end
        end
      end
    end
  end
  return nil
end
M.resolve = function(ino) return resolvePath(ino) end

-- ---------------------------------------------------------------------------------------------
-- Stranded dotfile: screencapture was killed between the PNG and the rename, so the user's archive
-- holds a hidden file forever.  We already have the bytes; give the file its name back.  The
-- liveness test is an hs.task — NEVER hs.execute, which is io.popen + read('*a') + close(), a
-- synchronous fork/exec/waitpid WITH NO TIMEOUT AT ALL (F2: median 43 ms, worst case unbounded —
-- a hung /usr/bin/python3 hangs Hammerspoon's main thread forever).
-- ---------------------------------------------------------------------------------------------
local function armStrandedCheck(ino, id)
  hs.timer.doAfter(cfg.strandedAfterS, function()
    local p = resolvePath(ino)
    if not p then return end
    local dir, base = p:match("(.*)/([^/]+)$")
    if not base or not base:match("^%.") then return end   -- already renamed by Apple; nothing to do
    hs.task.new("/usr/bin/pgrep", function(rc)
      if rc == 0 then return end                            -- screencapture still alive; let it finish
      -- Never give a name to a file that is not a finished PNG: screencapture can also die
      -- during the STREAMING phase, and un-hiding that would put a truncated image in the user's
      -- archive.  Off the hot path by 30 s, so a fresh open costs nothing.
      local fh = io.open(p, "rb")
      if not fh then return end
      local probe = { fh = fh, size = 0, isPng = false }
      local status = settle.step(probe)
      fh:close()
      if status ~= "complete" then
        log.warn("stranded", { id = id, msg = "incomplete png left behind; not renaming", file = base })
        return
      end
      local final = dir .. "/" .. base:gsub("^%.+", ""):gsub("(%.%a+)%-%w+$", "%1")
      if hs.fs.attributes(final) then return end
      local ok = os.rename(p, final)
      log.emit("stranded", { id = id, renamed = ok and 1 or 0, file = final:match("[^/]+$") })
    end, { "-x", "screencapture" }):start()
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------------------------
local function release(rec, phase, extra)
  if rec.fh then pcall(function() rec.fh:close() end); rec.fh = nil end
  state.pending[rec.ino] = nil
  if phase then
    local f = extra or {}
    f.id, f.dt, f.file = rec.id, clock.mono() - rec.createdNs, rec.file
    log.emit(phase, f)
    state.counts[phase] = (state.counts[phase] or 0) + 1
  end
end

local function onCandidate(c)
  local ino = c.attrs.ino

  -- The same inode under a new name is a RENAME, not a new shot.  Because the settle reads through
  -- an open handle, a rename between polls costs nothing: re-point the path and move on.
  local known = state.copied[ino] or state.pending[ino]
  if known then
    if known.path ~= c.path then
      known.path, known.file = c.path, c.name
      state.counts.renamed = state.counts.renamed + 1
      log.emit("renamed", { id = log.id(ino), file = c.name })
    end
    return
  end

  -- The creation window is what makes name-matching unnecessary: a Finder duplicate of an old
  -- screenshot ("Screenshot … copy.png") and a sync client's churn are both old, and would
  -- otherwise hijack the clipboard (hostile review item 7).
  local age = os.time() - (c.attrs.creation or 0)
  if age < 0 then age = 0 end
  if age > cfg.creationWindow then return end

  -- Open the handle IMMEDIATELY and keep it: the single-dot name is visible for ≥ 50 ms in only
  -- 18 % of shots.  ENOENT here means the name moved under us between the listing and the open —
  -- the next listing finds the same inode under its new name, which is a miss of one tick, never a
  -- lost shot.
  local fh = io.open(c.path, "rb")
  if not fh then return end

  local rec = {
    ino = ino, id = log.id(ino), path = c.path, file = c.name, fh = fh,
    createdNs = clock.mono(),          -- hs.fs truncates to whole seconds; THIS is the timestamp
    seq = clipboard.nextSeq(),
    size = 0, isPng = false, settlingLogged = false,
  }
  state.pending[ino] = rec
  -- Something is pending, so the 5 ms settle timer runs until settleTick empties the table.
  if state.settleTimer and not state.settleTimer:running() then state.settleTimer:start() end
  state.counts.created = state.counts.created + 1
  log.emit("created", { id = rec.id, size = c.attrs.size or 0, retro = c.retro, file = c.name })
end

-- ---------------------------------------------------------------------------------------------
-- Completion
-- ---------------------------------------------------------------------------------------------
local function finish(rec)
  log.emit("capture-complete", { id = rec.id, dt = clock.mono() - rec.createdNs,
                                 bytes = rec.size, file = rec.file })

  local tRead = clock.mono()
  local data = settle.readAll(rec)
  if not data then
    release(rec, "lost", { reason = "unreadable" })
    return
  end
  local tWrite = clock.mono()

  local ok, info = clipboard.write(data, rec.seq)
  local tDone = clock.mono()
  if not ok then
    log.error("clipboard", { id = rec.id, msg = "write not verified", cc = info.cc,
                             readback = info.readback, file = rec.file })
    release(rec, "lost", { reason = "clipboard" })
    return
  end

  -- Recorded HERE — on a verified copy — and nowhere earlier.
  state.copied[rec.ino] = { path = rec.path, file = rec.file, t = clock.mono() }
  state.counts.copied = state.counts.copied + 1
  log.emit("copied", { id = rec.id, dt = clock.mono() - rec.createdNs, bytes = #data,
                       cc = info.cc, seq = rec.seq, retried = info.retried,
                       read_ns = tWrite - tRead, write_ns = tDone - tWrite,
                       pb_write_ns = info.w_ns, pb_verify_ns = info.v_ns, file = rec.file })
  clipboard.watchForClobber(info.cc, rec.id, rec.file, cfg.clobberAfterS)

  -- Only now does anything decode the image — and it decodes the bytes we just PROVED are on the
  -- pasteboard, not a path.  A capture is renamed twice while we hold it, so at this instant the
  -- name we caught it under may already be gone; reading the board back removes that dependency
  -- entirely and costs one transfer we were going to pay to hs.image anyway.  The CLICK target is
  -- still a path, but it is resolved by inode at click time, seconds later, when the final name
  -- certainly exists.
  local path = resolvePath(rec.ino, rec.path) or rec.path
  local img = hs.pasteboard.readImage()
  if not img then img = hs.image.imageFromPath(path) end
  local shown = false
  if img then
    shown = thumbnail.show({ ino = rec.ino, id = rec.id, path = path, file = rec.file,
                             createdNs = rec.createdNs }, img)
    if cfg.tiff then clipboard.writeTiffLater(data, img) end
  end
  if not shown then
    log.warn("thumb", { id = rec.id, msg = "no thumbnail (image could not be decoded)", file = rec.file })
  end

  armStrandedCheck(rec.ino, rec.id)
  release(rec, nil)
end

local function settleTick()
  local done = nil
  for ino, rec in pairs(state.pending) do
    local status = settle.step(rec)
    if status == "complete" then
      done = done or {}
      done[#done + 1] = rec
    elseif status == "notpng" then
      state.counts.notpng = state.counts.notpng + 1   -- a distinct key from `gone`, not a duplicate
      release(rec, "gone", { reason = "not-png" })
    elseif status == "gone" then
      release(rec, "gone", { reason = "handle" })
    else
      if not rec.settlingLogged and clock.sSince(rec.createdNs) > 0.05 then
        rec.settlingLogged = true
        log.emit("settling", { id = rec.id, dt = clock.mono() - rec.createdNs,
                               bytes = rec.size, file = rec.file })
      end
      -- 🚨 `lost` is a POSITIVE RECORD.  A shot that simply stops being mentioned is invisible to
      -- the 7-day acceptance; a deadline that emits a line is falsifiable.
      if clock.sSince(rec.createdNs) >= cfg.settleCapS then
        -- `release` counts the phase it logs, so nothing increments state.counts.lost here.
        local reason = resolvePath(ino) and "settle-timeout" or "deleted"
        release(rec, "lost", { reason = reason, bytes = rec.size })
        armStrandedCheck(ino, rec.id)
      end
    end
  end
  if done then
    -- Ascending write sequence, so when two shots settle in the same tick the LATER capture is the
    -- one left on the clipboard (F1 acceptance L3).
    table.sort(done, function(a, b) return a.seq < b.seq end)
    for _, rec in ipairs(done) do finish(rec) end
  end
  -- Every release happens above, so this is the one place the table can become empty: idle
  -- again, back to the 10 ms base timer alone.
  if next(state.pending) == nil and state.settleTimer then state.settleTimer:stop() end
end

local function pruneCopied()
  local now = clock.mono()
  local ttl = cfg.copiedTTLS * 1e9
  for ino, rec in pairs(state.copied) do
    if (now - rec.t) > ttl then state.copied[ino] = nil end
  end
end

-- ---------------------------------------------------------------------------------------------
-- Arm / start / stop
-- ---------------------------------------------------------------------------------------------

--- Inodes a PREVIOUS instance already copied, read back from the log's tail.  Bounded retroactivity
--- must not re-copy a shot the dead instance had already put on the clipboard.
local function recentlyCopiedIds()
  local ids = {}
  local st = log.stats()
  if not st.path then return ids end
  local fh = io.open(st.path, "rb")
  if not fh then return ids end
  local size = fh:seek("end")
  fh:seek("set", math.max(0, size - 64 * 1024))
  local tail = fh:read("*a") or ""
  fh:close()
  for line in tail:gmatch("[^\n]+") do
    if line:find("phase=copied", 1, true) then
      local id = line:match("id=(%x+)")
      if id then ids[id] = true end
    end
  end
  return ids
end

--- ⌘⇧5 and the floating thumbnail are live modalities on this box (`video = 1` in the defaults), and
--- their writer is `screencaptureui`, not `/usr/sbin/screencapture`.  Turning `show-thumbnail` on
--- adds a SECOND, user-paced move that this module's settle assumptions have never been validated
--- against, and `target` anything but `file` means no file is written at all.  So: read them, and
--- WARN rather than pretend (completeness critic item 7).  Asynchronous, at start, off every path.
local function checkCaptureDefaults()
  hs.task.new("/usr/bin/defaults", function(rc, out)
    if rc ~= 0 or not out then return end
    local thumb  = out:match('"?show%-thumbnail"?%s*=%s*([^;]+);')
    local target = out:match('"?target"?%s*=%s*([^;]+);')
    thumb  = thumb  and thumb:gsub("%s", "")  or "unset"
    target = target and target:gsub("%s", "") or "unset"
    if thumb ~= "0" and thumb ~= "unset" then
      log.warn("defaults", { msg = "show-thumbnail is on; screencaptureui adds a user-paced second move",
                             ["show-thumbnail"] = thumb })
    end
    if target ~= "file" and target ~= "unset" then
      log.warn("defaults", { msg = "capture target is not a file; no file means no thumbnail",
                             target = target })
    end
  end, { "read", "com.apple.screencapture" }):start()
end

--- Warm the lazy modules ONCE, at load.  hs.mouse/hs.screen/hs.canvas are otherwise first
--- touched inside the settle path, so the FIRST screenshot after every Hammerspoon launch pays
--- ~20–40 ms of module loading on the user's latency path — and this box relaunches often (F2 §9).
--- ...and `hs.pasteboard` belongs on that list, which the bench proved rather than assumed: over
--- three consecutive 10-sample runs the FIRST capture was the slowest every time (30.9 / 31.0 ms
--- against a 26.1 ms worst case for the other nine), because `hs` loads an extension on first
--- ACCESS and the copy path's first touch of hs.pasteboard was paying for it on the user's
--- latency. Reading `changeCount` and `contentTypes` costs microseconds and writes nothing.
local function warmModules()
  pcall(function()
    hs.mouse.absolutePosition()
    hs.screen.allScreens()
    local c = hs.canvas.new({ x = 0, y = 0, w = 1, h = 1 })
    if c then c:delete() end
    hs.image.imageFromName("NSApplicationIcon")
    hs.pasteboard.changeCount()
    hs.pasteboard.contentTypes()
    hs.task.new("/usr/bin/true", nil):start()
  end)
end

function M.start(userCfg)
  if state.started then return true end
  for k, v in pairs(userCfg or {}) do cfg[k] = v end
  state.startedNs = clock.mono()

  warmModules()
  thumbnail.start({ resolve = M.resolve })

  -- continueOnError = true.  hs.timer.new defaults to STOPPING the timer on the first Lua error in
  -- its callback, which would turn a transient fault into a silent, permanent loss of detection —
  -- the exact failure shape this rewrite exists to remove.
  -- 🚨 TWO RATES, TWO TIMERS.  Detection wants a 10 ms directory stat — that is the interval C1
  -- benchmarked (first-name detection p50 4.705 / p90 10.011 / p99 11.050 ms, 35/35 caught) and
  -- the one the whole design is costed against.  The SETTLE wants to be faster than that, because
  -- once a candidate is open the only question left is "has IEND landed yet", and every tick of
  -- interval T adds T/2 on average and T at worst to the answer — measurably, on a path whose
  -- total budget is 30 ms.  An lseek plus an 8-byte read is ~0.17 ms, so running it at 5 ms while
  -- something is pending costs nothing and halves that term.  But a 5 ms timer that runs while
  -- NOTHING is pending is 200 wakeups/s to answer a question nobody asked: the settle timer is
  -- created stopped, started by onCandidate, and stopped by settleTick when the table empties
  -- (DESIGN load-root-cause-2026-10-17 X22: 200 → 100 idle wakeups/s).  Created before the arm,
  -- because the retro pass can put a shot in the table before the base timer exists.
  state.settleTimer = hs.timer.new(cfg.settleS, function()
    local ok, err = pcall(settleTick)
    if not ok then log.error("settle", { msg = tostring(err) }) end
  end, true)

  state.w = watcher.new({
    dir = cfg.dir, reconcileMax = cfg.reconcileMax, backstopS = cfg.backstopS,
    onCandidate = onCandidate,
  })
  state.w:arm(cfg.retroWindow, recentlyCopiedIds())

  -- The base timer: the 10 ms directory stat, continueOnError for the reason above.
  state.timer = hs.timer.new(cfg.pollS, function()
    local ok, err = pcall(function()
      -- Settle FIRST, discovery second.  The watcher may re-list (2.4 ms for this directory, and
      -- up to the reconcile bound after a size change), and a candidate that finished during the
      -- previous interval would otherwise wait behind that listing for no reason: the bytes it
      -- needs are already on disk.  Ordering is free and the term is not.
      if next(state.pending) ~= nil then settleTick() end
      if state.w then state.w:tick() end
    end)
    if not ok then log.error("tick", { msg = tostring(err) }) end
  end, true)
  state.timer:start()

  -- Once a minute is plenty for a 120 s TTL, and it keeps the 10 ms tick free of housekeeping.
  state.pruneTimer = hs.timer.doEvery(60, function() pcall(pruneCopied) end)

  checkCaptureDefaults()
  state.started = true
  log.emit("start", { module = "screenshot", poll_ms = cfg.pollS * 1000,
                      settle_ms = cfg.settleS * 1000,
                      backstop_s = cfg.backstopS, cap_s = cfg.settleCapS, dir = cfg.dir })
  return true
end

function M.stop()
  if state.timer then state.timer:stop(); state.timer = nil end
  if state.settleTimer then state.settleTimer:stop(); state.settleTimer = nil end
  if state.pruneTimer then state.pruneTimer:stop(); state.pruneTimer = nil end
  for _, rec in pairs(state.pending) do
    if rec.fh then pcall(function() rec.fh:close() end) end
  end
  state.pending = {}
  thumbnail.stop()
  state.w = nil
  if state.started then log.emit("stop", { module = "screenshot" }) end
  state.started = false
end

--- Bench mode: a short dismissal.  `analyze.py` records the mode and never compares
--- percentiles across modes.
function M.benchMode(on)
  thumbnail.start({ config = { dismiss = on and 0.4 or 3 } })
  return on and "bench" or "normal"
end

--- Drop a name from the watcher's mirror so it can be considered again (bench helper).
function M.forget(name) if state.w then state.w:forget(name) end end

function M.stats()
  local pending, copied = 0, 0
  for _ in pairs(state.pending) do pending = pending + 1 end
  for _ in pairs(state.copied) do copied = copied + 1 end
  return {
    started = state.started,
    uptime_s = state.started and clock.sSince(state.startedNs) or 0,
    pending = pending, copied_tracked = copied,
    counts = state.counts,
    -- The sequence of the last VERIFIED clipboard write.  Exposed so acceptance claim L3 — when
    -- two shots settle in one scan the LATER capture wins the clipboard — is checkable from
    -- outside the process rather than only inferable from the log.
    last_copied_seq = clipboard.lastWrittenSeq(),
    watcher = state.w and state.w:stats() or nil,
    thumbnail = thumbnail.stats(),
    log = log.stats(),
    config = { poll_ms = cfg.pollS * 1000, settle_ms = cfg.settleS * 1000,
               backstop_s = cfg.backstopS, cap_s = cfg.settleCapS,
               creation_window_s = cfg.creationWindow, retro_s = cfg.retroWindow, tiff = cfg.tiff },
  }
end

return M
