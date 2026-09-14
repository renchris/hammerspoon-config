-- hsc/clock.lua — the one place that knows which clock answers which question.
--
-- Two clocks, and confusing them is a measurement bug rather than a crash, which is why they live
-- behind named functions:
--
--   * MONOTONIC (hs.timer.absoluteTime, nanoseconds).  This IS mach_absolute_time, and it is the
--     same clock Python's time.monotonic_ns() reads with no offset (measured 2026-09-10), so the
--     bench can subtract our `mono=` field from its own timestamps directly.  Every duration in
--     this config is computed from it.
--   * WALL (hs.timer.secondsSinceEpoch).  Human-readable only.  Never subtract two of these.
--
-- 🚨 File timestamps are NOT a third option.  hs.fs.attributes truncates all four of a file's
-- timestamps to WHOLE SECONDS (python reads 1789059550.804981 where Hammerspoon reads 1789059550 —
-- knowledge base §F7, F1 addendum §17).  A "created" instant therefore has to be stamped by the
-- poll's own absoluteTime() at first sight; the file cannot tell us when it was born with any
-- useful resolution.
local M = {}

--- Monotonic nanoseconds.  Immune to clock changes; the basis of every measured interval here.
function M.mono() return hs.timer.absoluteTime() end

--- Milliseconds elapsed since a monotonic reading.
function M.msSince(ns) return (hs.timer.absoluteTime() - ns) / 1e6 end

--- Seconds elapsed since a monotonic reading.
function M.sSince(ns) return (hs.timer.absoluteTime() - ns) / 1e9 end

--- Wall-clock seconds since the epoch (fractional).
function M.wall() return hs.timer.secondsSinceEpoch() end

--- ISO-8601 local timestamp with milliseconds, e.g. 2026-09-13T20:31:02.481-0500.
function M.stamp(secs)
  secs = secs or M.wall()
  local whole = math.floor(secs)
  return string.format("%s.%03d%s", os.date("%Y-%m-%dT%H:%M:%S", whole),
                       math.floor((secs - whole) * 1000), os.date("%z", whole))
end

return M
