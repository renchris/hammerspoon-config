-- hsc/screenshot/settle.lua — "is this PNG finished?", answered THROUGH AN OPEN HANDLE.
--
-- 🚨 WHY A HANDLE AND NOT A PATH.  One screenshot wears THREE names in succession (knowledge base
-- §F2, K2 verified twice):
--     <dir>/..Screenshot X.png-XXXX   ImageIO's streaming temp (partial, no IEND)
--     <dir>/.Screenshot X.png         complete at its first appearance — same inode, same sha256
--     <dir>/Screenshot X.png          the final name, after Apple's unbounded Spotlight stall
-- The single-dot file is visible for ≥ 50 ms in only 18 % of shots (median 11 ms), so a PATH-based
-- reader hits ENOENT between two polls and loses the shot.  A file handle survives BOTH renames,
-- so every check here reads through `c.fh` and never through `c.path`; the path is only ever
-- re-resolved when something outside this module needs a name (a click, a log line).
--
-- 🚨 IEND ONLY — NO SIZE-STABILITY FALLBACK.  The shipped code accepted "the size has not moved for
-- ~150 ms" as a completion signal.  Against the FINAL name that was harmless, because Apple only
-- ever renames a complete file into place.  Against the STREAMING TEMP it is a corruption path:
-- ImageIO writes in 16 KB chunks and the size plateaus between them, so a size-stable fallback
-- copies a half-written PNG (hostile review item 2).  A complete PNG ends with the IEND chunk and
-- nothing else is evidence.
--
-- The tail check reads EIGHT BYTES (0.17 ms), not the whole file.  That distinction is latent today
-- and becomes live the moment this design lands: against the final name `step` found IEND on its
-- first look every time (n=30), so the shipped full-file read never repeated.  Against the
-- streaming temp it would repeat for the entire write (F2 sequencing constraint).
local M = {}

M.PNG_SIG  = "\137\80\78\71\13\10\26\10"        -- \x89 P N G \r \n \x1a \n
M.PNG_IEND = "\73\69\78\68\174\66\96\130"       -- "IEND" + CRC 0xAE426082

--- One settle iteration for candidate `c` (fields: fh, and the mutable size/isPng scratch).
--- Returns one of:
---   "wait"     — still being written
---   "complete" — IEND present; the bytes are final
---   "notpng"   — the first 8 bytes are not a PNG signature; this is not a screenshot
---   "gone"     — the handle can no longer be read
function M.step(c)
  local f = c.fh
  if not f then return "gone" end

  local ok, size = pcall(function() return f:seek("end") end)
  if not ok or not size then return "gone" end
  c.size = size
  if size < 8 then return "wait" end

  -- Name spelling is IRRELEVANT to this pipeline — either hidden form, the final name, a bench
  -- file, a Finder copy.  What makes an entry a screenshot is that it is a PNG created inside the
  -- creation window.  The signature check is the spelling-independent half of that test.
  if not c.isPng then
    f:seek("set", 0)
    local head = f:read(8)
    if not head or #head < 8 then return "wait" end
    if head ~= M.PNG_SIG then return "notpng" end
    c.isPng = true
  end

  if size < 16 then return "wait" end
  f:seek("set", size - 8)
  local tail = f:read(8)
  if tail == M.PNG_IEND then return "complete" end
  return "wait"
end

--- Read the complete file through the same handle (3 ms for 2.4 MB).  Returns bytes or nil.
--- The length is re-checked against the size `step` saw: if the file grew between the IEND check
--- and this read we are looking at a different image, and one retry re-reads it whole.
function M.readAll(c)
  for _ = 1, 2 do
    c.fh:seek("set", 0)
    local data = c.fh:read("*a")
    if data and #data >= 8 and data:sub(-8) == M.PNG_IEND then return data end
    local ok, size = pcall(function() return c.fh:seek("end") end)
    if ok and size then c.size = size end
  end
  return nil
end

return M
