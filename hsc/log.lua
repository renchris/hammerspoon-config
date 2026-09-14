-- hsc/log.lua — the pipeline's only output surface: one logfmt line per lifecycle phase.
--
-- WHY A FILE AND NOT THE CONSOLE.  Hammerspoon's console is wiped by every reload and — measured
-- 2026-09-08 — cannot even be read back over hs.ipc while the machine is loaded (the `hs` CLI
-- aborts on the large reply).  A file survives both and answers "did the 3:46 PM screenshot copy,
-- and how long did it take?" after the fact.  It is also the bench's ONLY instrument: Phase 5b
-- parses these lines, so the format is a contract, not a convenience.
--
-- 🚨 WHY NOTHING HERE CALLS print() OR hs.logger.  hs.ipc REPLACES the global `print` with a
-- version that raises when the IPC port is stale, and hs.logger prints through it.  On 2026-09-10
-- 12:03:36 that is exactly how the live instance died — EXC_BREAKPOINT inside hs.ipc's logger —
-- taking the whole config with it (knowledge base §F1b).  A logger that can kill the process it is
-- observing is not an observer.  This module writes bytes to a file descriptor and nothing else.
--
-- FORMAT (logfmt; keys in a fixed order so a parser can be dumb):
--     ts=<ISO8601 local, ms> mono=<ns> phase=<word> [id=<hex6>] [dt=<ns since created>] \
--         [k=v ...] [file=<basename>]
-- `mono` is verbatim nanoseconds from the same clock Python's time.monotonic_ns() reads, so the
-- bench subtracts without an offset.  `id` is six hex characters of the INODE, which is the only
-- identifier that survives Apple's two renames — it is what joins `created` (logged against a
-- hidden name) to `copied` (logged against whatever name the file wears by then).
-- `file=` is ALWAYS LAST and ALWAYS BARE, because screenshot basenames contain spaces: a parser
-- splits the first N fields on whitespace and takes the remainder of the line as the filename.
local clock = require("hsc.clock")

local M = {}

-- A CLOSED vocabulary.  An unknown phase is a bug in the caller, and is logged as one rather than
-- silently widening the contract the bench parses.
local PHASES = {
  armed = true,              -- the watcher is live and what it already knows about
  start = true, stop = true, -- module lifecycle
  created = true,            -- a new directory entry was seen for the first time (hidden name)
  detected = true,           -- ...and its first 8 bytes are the PNG signature
  settling = true,           -- waiting for IEND
  ["capture-complete"] = true, -- IEND present: the PNG is whole on disk
  copied = true,             -- pasteboard write VERIFIED (changeCount moved + bytes read back)
  ["thumb-shown"] = true,    -- canvas:show() returned
  ["thumb-visible"] = true,  -- isOccluded() says the window server is actually presenting it
  dismissed = true,
  renamed = true,            -- same inode, new name
  gone = true,               -- the inode lost its last directory entry before completing
  stranded = true,           -- a dotfile we un-hid ourselves after screencapture died mid-stall
  clobbered = true,          -- somebody else wrote the pasteboard after our verified write
  lost = true,               -- 🚨 a POSITIVE record of failure — the deadline expired
  warn = true, error = true,
}

local state = {
  path = nil, fh = nil, bytes = 0, max = 1024 * 1024,
  lastErr = {},   -- message key -> monotonic ns, for the 1/s rate limit
  counts = {},    -- phase -> n, for stats()
}

local function openFile()
  local fh = io.open(state.path, "a")
  if not fh then return false end
  fh:setvbuf("line")          -- a crash must not eat the last line
  state.fh = fh
  local a = hs.fs.attributes(state.path)
  state.bytes = (a and a.size) or 0
  return true
end

--- Rotate ON WRITE, never only at load.  A load-time truncation cannot bound a log that grows
--- during a long uptime, and this box's uptime is measured in days (hostile review item 10).
local function rotateIfNeeded()
  if state.bytes < state.max then return end
  if state.fh then state.fh:close(); state.fh = nil end
  os.remove(state.path .. ".1")
  os.rename(state.path, state.path .. ".1")
  state.bytes = 0
  openFile()
end

--- Start logging to `path`.  Idempotent; safe to call when already started.
function M.start(path)
  if state.fh and state.path == path then return true end
  M.stop()
  state.path = path
  hs.fs.mkdir(path:match("(.*)/") or ".")
  return openFile()
end

--- Close the handle.  Safe when never started.
function M.stop()
  if state.fh then state.fh:close(); state.fh = nil end
end

-- Keys that get a fixed position; everything else is emitted in sorted order between `dt` and
-- `file` so two runs of the same code produce byte-identical field ordering.
local FIRST = { id = true, dt = true }

--- Emit one line.  `fields` is a plain table; `id`, `dt` and `file` get their reserved positions.
function M.emit(phase, fields)
  fields = fields or {}
  if not PHASES[phase] then
    local bad = phase
    phase = "error"
    fields = { msg = "unknown-phase:" .. tostring(bad) }
  end
  state.counts[phase] = (state.counts[phase] or 0) + 1

  local parts = {
    "ts=" .. clock.stamp(),
    "mono=" .. string.format("%d", math.floor(clock.mono())),
    "phase=" .. phase,
  }
  if fields.id then parts[#parts + 1] = "id=" .. fields.id end
  if fields.dt then parts[#parts + 1] = string.format("dt=%d", math.floor(fields.dt)) end

  local extra = {}
  for k, v in pairs(fields) do
    if k ~= "file" and not FIRST[k] then extra[#extra + 1] = k end
  end
  table.sort(extra)
  for _, k in ipairs(extra) do
    local v = fields[k]
    if type(v) == "number" then
      v = (v % 1 == 0) and string.format("%d", math.floor(v)) or string.format("%.3f", v)
    else
      v = tostring(v):gsub("[%s=]", "_")   -- only `file` may carry spaces, and it is last
    end
    parts[#parts + 1] = k .. "=" .. v
  end
  if fields.file then parts[#parts + 1] = "file=" .. tostring(fields.file) end

  local line = table.concat(parts, " ") .. "\n"
  if not state.fh then return end
  rotateIfNeeded()
  if not state.fh then return end
  state.fh:write(line)
  state.bytes = state.bytes + #line
end

--- warn/error with a 1-per-second rate limit per `key`, so a stuck condition cannot fill the disk
--- at 100 Hz.  A suppressed line is counted, never silently dropped.
local function limited(phase, key, fields)
  local now = clock.mono()
  local last = state.lastErr[key]
  if last and (now - last) < 1e9 then
    state.counts[phase .. "-suppressed"] = (state.counts[phase .. "-suppressed"] or 0) + 1
    return
  end
  state.lastErr[key] = now
  M.emit(phase, fields)
end

function M.warn(key, fields)  limited("warn",  key, fields) end
function M.error(key, fields) limited("error", key, fields) end

--- Six hex characters of an inode — the join key across Apple's two renames.
function M.id(ino) return string.format("%06x", (tonumber(ino) or 0) % 0x1000000) end

function M.stats()
  local c = {}
  for k, v in pairs(state.counts) do c[k] = v end
  return { path = state.path, open = state.fh ~= nil, bytes = state.bytes, counts = c }
end

return M
