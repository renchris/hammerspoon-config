-- hsc/screenshot/watcher.lua — a 10 ms directory poll keyed on st_size ALONE.
--
-- WHY A POLL AND NOT A KERNEL WATCHER.  fseventsd on this machine livelocked for about a day
-- (2026-09-07/08): the hs.pathwatcher this replaces delivered minutes late or never, its liveness
-- watchdog re-armed it 35 times in ONE day — each re-arm discarding whatever was queued — and 5 of
-- 13 screenshots produced no event at all.  A stat() of the directory costs 27 µs and asks the
-- KERNEL.  A kqueue helper was then built and BENCHMARKED against this poll (C1, n=35 each) and
-- REJECTED on its own numbers: it saves ~4 ms at p50 and ~7 ms at p99, on a path that already
-- carries Apple's 16 ms PNG write, and it buys that with a permanent-deafness failure mode on
-- directory replacement plus a second unsupervised process on a box where the first one died twice
-- in one day.
--
-- 🚨 THE SIGNATURE IS `st_size` AND NOTHING ELSE — deleting the mtime/ctime terms is the
-- highest-value line in this file.  APFS reports a directory's size as 32 bytes per entry, so a
-- CREATION always moves it (+32) while a same-directory RENAME never does.  The shipped code keyed
-- on "mtime:ctime:size" at the whole-second resolution hs.fs exposes, which means a rename landing
-- in the same wall-clock second as its create changed NOTHING it looked at — and the `HOT_EVERY`
-- rescue only covered the remainder of that second.  Measured: 11/20 phase-locked offsets deferred
-- or lost at the shipped 50 ms poll (~3 % of shots), with one production instance already on disk
-- at 6 026 ms — the worst latency ever measured on this box, and it was OURS, not Apple's
-- (knowledge base §F7, failure mode 14).
-- A size-only signature deliberately IGNORES renames.  That is correct precisely because this
-- design no longer depends on them: it triggers on CREATION, and a creation always moves st_size.
--
-- 🚨 ...WHICH LEAVES EXACTLY ONE HOLE, AND 1b IS THE BACKSTOP FOR IT.  A tick in which one entry is
-- created and another unlinked has Δsize ZERO (measured, n=20) — and with no later trigger the shot
-- is lost outright.  That is not hypothetical: the bench deletes each file two seconds before the
-- next capture in the same directory, and this directory takes non-screenshot traffic (IMG_*.jpg, a
-- .mov from ⌘⇧5).  So an UNCONDITIONAL rescan runs once a second: one listing, 2.4 ms, ~0.24 % of a
-- core, invisible beside the 10 ms poll.
local clock = require("hsc.clock")
local log   = require("hsc.log")

local M = {}
local Watcher = {}
Watcher.__index = Watcher

--- cfg: dir, reconcileMax, backstopS, onCandidate(cand)
function M.new(cfg)
  return setmetatable({
    dir          = cfg.dir,
    reconcileMax = cfg.reconcileMax or 10,
    backstopNs   = (cfg.backstopS or 1.0) * 1e9,
    onCandidate  = cfg.onCandidate or function() end,
    seen         = {},
    lastSize     = -1,
    expect       = -1,
    reconcile    = 0,
    lastBackstopNs = 0,
    dirIno       = nil,
    missing      = false,
    listings     = 0,
    ticks        = 0,
    -- Set at arm() by comparing a real listing against st_size/32.  If the volume does not honour
    -- the invariant, the count predicate is switched off and the reconcile loop runs its full bound
    -- instead — correct either way, just less frugal.  Never assumed; always measured.
    countPredicate = true,
  }, Watcher)
end

--- List the directory once.  Returns the entry count as `hs.fs.dir` yields it — INCLUDING "." and
--- "..", because that is the count that equals st_size/32 (measured on this volume: 3423 names
--- against 109536/32 = 3423; python's os.listdir gives 3421, which is where the plan's original
--- "size/32 − 2" predicate came from and why it could never have terminated here).
function Watcher:scan(markOnly, retroWindow, skipIds)
  local present, count, fresh = {}, 0, {}
  local ok, err = pcall(function()
    for name in hs.fs.dir(self.dir) do
      count = count + 1
      present[name] = true
      if not self.seen[name] then
        self.seen[name] = true
        if name ~= "." and name ~= ".." then fresh[#fresh + 1] = name end
      end
    end
  end)
  if not ok then
    log.error("listing", { msg = tostring(err), dir = self.dir })
    return -1
  end
  self.listings = self.listings + 1

  -- `seen` is a MIRROR of the listing, never an accumulator.  The shipped table was add-only
  -- forever, so a screenshot restored from the Trash under a burned name was never copied and never
  -- logged — an entry that vanished could never be considered again (F1).
  for name in pairs(self.seen) do
    if not present[name] then self.seen[name] = nil end
  end

  if #fresh == 0 then return count end
  -- At arm with no retroactive window there is nothing to stat: every name is being remembered,
  -- not considered.  This matters because the arm pass sees EVERY entry as fresh — 3 425 of them
  -- on this volume — and a full inode pass is 18 ms per thousand.
  if markOnly and (not retroWindow or retroWindow <= 0) then return count end

  -- Stat ONLY the names absent from `seen`.  A full inode pass over this directory is 18.0 ms
  -- (n=5) against 2.4 ms for the listing alone — up to ~180 ms of main thread per shot if the
  -- reconcile loop ran its bound, against this phase's own "zero main-thread blocks > 100 ms".
  local cands = {}
  for _, name in ipairs(fresh) do
    local path = self.dir .. "/" .. name
    local at = hs.fs.attributes(path)
    if at and at.mode == "file" then
      cands[#cands + 1] = { name = name, path = path, attrs = at }
    end
  end

  -- Ordered by CREATION TIME, not by name.  `table.sort(found)` on names — what shipped — is wrong
  -- on 67 % of days, because the generated filename carries a non-zero-padded 12-hour hour, so
  -- "Screenshot … at 9.41.50 AM.png" sorts AFTER "… at 10.02.11 AM.png".  hs.fs truncates creation
  -- to whole seconds, so same-second ties fall back to the name: arbitrary, but stable, and the
  -- clipboard's own write sequence (see clipboard.nextSeq) is what actually decides the winner.
  table.sort(cands, function(x, y)
    local cx, cy = x.attrs.creation or 0, y.attrs.creation or 0
    if cx ~= cy then return cx < cy end
    return x.name < y.name
  end)

  if markOnly then
    -- BOUNDED RETROACTIVITY at arm: anything created in the last `retroWindow` seconds that has no
    -- `copied` record in the log is still fed through, because a shot taken during Hammerspoon's
    -- 1–2 s start would otherwise be marked "known" and never copied (hostile review item 4).
    -- Never anything older: overwriting a clipboard the user has since filled themselves would be
    -- a worse bug than the one this fixes.
    local now = os.time()
    for _, c in ipairs(cands) do
      local age = now - (c.attrs.creation or 0)
      if age >= 0 and age <= retroWindow and not (skipIds or {})[log.id(c.attrs.ino)] then
        c.retro = age
        self.onCandidate(c)
      end
    end
    return count
  end

  for _, c in ipairs(cands) do self.onCandidate(c) end
  return count
end

--- Remember everything already present without copying it, and report BOTH numbers so the st_size
--- invariant is measured on the real volume rather than assumed.
function Watcher:arm(retroWindow, skipIds)
  local a = hs.fs.attributes(self.dir)
  if not a or a.mode ~= "directory" then
    self.missing = true
    log.warn("dir-missing", { dir = self.dir, msg = "screenshots cannot be detected until it exists" })
    return false
  end
  self.dirIno = a.ino
  self.lastSize = a.size or 0
  self.expect = self.lastSize / 32
  -- 🚨 ONE STAT DECIDES WHETHER 3 425 OF THEM ARE NEEDED.  A file created inside the retroactive
  -- window must have changed the DIRECTORY's mtime inside that same window, so if the directory
  -- has not been touched recently, nothing can be retroactively copyable and the whole inode pass
  -- is skipped.  Measured WITH the pass, on 3 425 entries: 424 ms from the init `start` line to
  -- the `armed` line, all of it statting files nobody was going to consider.  And it degrades in
  -- the right direction — the case where the stat pass DOES run is a restart shortly after a
  -- shot, which is exactly the case bounded retroactivity exists for.
  local retro = retroWindow or 0
  if retro > 0 and (os.time() - (a.modification or 0)) > retro then retro = 0 end
  local count = self:scan(true, retro, skipIds)
  self.countPredicate = (count == self.expect)
  self.lastBackstopNs = clock.mono()
  log.emit("armed", {
    dir = self.dir, entries = count, expect = self.expect,
    invariant = self.countPredicate and "holds" or "BROKEN",
    size = self.lastSize,
  })
  if not self.countPredicate then
    log.warn("invariant", { msg = "entry count != st_size/32; reconcile runs its full bound",
                            entries = count, expect = self.expect })
  end
  return true
end

--- One poll tick.  Returns the number of listings performed this tick (0 or 1).
function Watcher:tick()
  self.ticks = self.ticks + 1
  local a = hs.fs.attributes(self.dir)
  if not a or a.mode ~= "directory" then
    if not self.missing then
      self.missing = true
      log.warn("dir-missing", { dir = self.dir, msg = "screenshots cannot be detected until it exists" })
    end
    return 0
  end
  if self.missing then
    self.missing = false
    self.seen = {}
    self:arm(0, nil)
    return 1
  end
  -- A REPLACED directory (new inode) is a different directory wearing the same path: everything in
  -- `seen` describes a tree that no longer exists.
  if self.dirIno and a.ino ~= self.dirIno then
    log.warn("dir-replaced", { dir = self.dir, msg = "inode changed; re-arming" })
    self.seen = {}
    self:arm(0, nil)
    return 1
  end

  local size = a.size or 0
  if size ~= self.lastSize then
    self.lastSize = size
    self.expect = size / 32
    -- A size change says the entry COUNT moved; it does not say the listing will agree yet.  A
    -- listing races Apple's two renames (an entry mid-rename is missed in ~20 % of listings), so
    -- re-list every tick until the name count reconciles with st_size/32, bounded at reconcileMax.
    self.reconcile = self.reconcileMax
  end

  local now = clock.mono()
  local backstop = (now - self.lastBackstopNs) >= self.backstopNs
  if self.reconcile <= 0 and not backstop then return 0 end
  if backstop then self.lastBackstopNs = now end

  local count = self:scan(false)
  if self.reconcile > 0 then
    self.reconcile = self.reconcile - 1
    if self.countPredicate and count == self.expect then self.reconcile = 0 end
  end
  return 1
end

--- Drop a name from the mirror so it can be considered again.  Used by the bench.
function Watcher:forget(name) self.seen[name] = nil end

function Watcher:stats()
  local n = 0
  for _ in pairs(self.seen) do n = n + 1 end
  return { dir = self.dir, seen = n, expect = self.expect, size = self.lastSize,
           listings = self.listings, ticks = self.ticks, reconcile = self.reconcile,
           invariant = self.countPredicate, missing = self.missing }
end

return M
