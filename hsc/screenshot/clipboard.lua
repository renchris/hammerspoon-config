-- hsc/screenshot/clipboard.lua — put the PNG on the general pasteboard and PROVE it landed.
--
-- PNG ONLY, and the reasons are measured rather than stylistic:
--
--  * Claude Code's clipboard reader asks NSPasteboard for `public.png` FIRST (its embedded Rust
--    napi module, identical in 2.1.114 and 2.1.260); the osascript «class PNGf» route is only its
--    fallback.  TIFF is never asked for (knowledge base §F5, K5 stands 88 %/85 %).
--  * The pasteboard SERVER synthesises TIFF on demand for legacy readers: a board holding only
--    public.png advertises public.tiff and hands back a valid TIFF even after the writer exited
--    (D2, verified from a separate AppKit process).  Encoding one ourselves cost 55 ms of a 60 ms
--    copy and bought nothing.
--  * `screencapture -c` — Apple's own Control-held capture — writes EXACTLY ONE FLAVOR, PNG, from
--    a single PasteboardPutItemFlavor call site (B2, disassembly).  PNG-only is the ecosystem
--    default here, not a deviation.
--
-- 🚨 NO EXPLICIT clearContents().  hs.pasteboard.writeAllData clears the board itself, so the
-- extra call is a SECOND changeCount bump that wakes every pasteboard poller on a momentarily
-- EMPTY board (D2; the shipped code did this on every screenshot).
--
-- 🚨 VERIFICATION IS BYTES, NOT PRESENCE.  "a PNG UTI is advertised" is not proof the write took —
-- the server advertises translations, so that test passes over a stale board.  The write is
-- verified iff changeCount ADVANCED and readDataForUTI("public.png") returns the SAME BYTE LENGTH
-- we wrote (F1 acceptance L2).
local log = require("hsc.log")

local M = {}

local seq = 0            -- monotonic write sequence; see M.nextSeq
local lastWritten = 0    -- seq of the last verified write

--- A monotonically increasing sequence number, handed to a candidate when it is first seen.
--- Completions inside one tick are copied in ASCENDING sequence, so when two shots settle in the
--- same scan the LATER capture is the one left on the clipboard (F1 acceptance L3).  The shipped
--- code ordered by `table.sort(found)` on NAMES, which is wrong on 67 % of days because the
--- generated filename uses a non-zero-padded 12-hour hour ("at 9.41.50 AM" sorts after
--- "at 10.02.11 AM").
function M.nextSeq() seq = seq + 1; return seq end

function M.lastWrittenSeq() return lastWritten end

--- Write `bytes` as public.png and verify.  Returns ok, info.
--- One retry: a single transient failure must not cost the shot, and two failures are a real fault.
function M.write(bytes, writeSeq)
  local function attempt()
    local before = hs.pasteboard.changeCount()
    local ok = hs.pasteboard.writeAllData(nil, { ["public.png"] = bytes })
    local after = hs.pasteboard.changeCount()
    if not ok or after <= before then return false, after, 0 end
    local back = hs.pasteboard.readDataForUTI(nil, "public.png")
    local n = back and #back or 0
    return n == #bytes, after, n
  end

  local ok, cc, n = attempt()
  local retried = 0
  if not ok then
    retried = 1
    ok, cc, n = attempt()
  end
  if ok and writeSeq then lastWritten = writeSeq end
  return ok, { cc = cc, readback = n, retried = retried }
end

--- Optional second write carrying a TIFF flavour, for the day a consumer proves it needs one.
--- Off by default (SCREENSHOT_TIFF=true turns it on).  Deliberately DELAYED so it can never sit on
--- the clipboard's critical path, and built on a UNIQUE scratch pasteboard that is deleted — the
--- shipped code used a fixed-name scratch board and never removed it.
function M.writeTiffLater(bytes, img, delay)
  hs.timer.doAfter(delay or 0.06, function()
    local okAll, err = pcall(function()
      local scratch = hs.pasteboard.uniquePasteboard()
      local tiff
      if hs.pasteboard.writeObjects(img, scratch) then
        tiff = hs.pasteboard.readDataForUTI(scratch, "public.tiff")
      end
      hs.pasteboard.deletePasteboard(scratch)
      if tiff and #tiff > 0 then
        hs.pasteboard.writeAllData(nil, { ["public.png"] = bytes, ["public.tiff"] = tiff })
      end
    end)
    if not okAll then log.error("tiff", { msg = tostring(err) }) end
  end)
end

--- Re-read changeCount `delay` seconds after our verified write.  If it moved and we did not move
--- it, ANOTHER APP OWNS THE CLIPBOARD NOW and the user's ⌘V will not paste this screenshot.
--- Without this the 7-day acceptance scores a clobbered shot as a success — and a second clipboard
--- writer is live on this box right now (VoiceInk, completeness critic item 9).  One timer, ~5 µs.
function M.watchForClobber(cc, id, file, delay)
  hs.timer.doAfter(delay or 0.3, function()
    local now = hs.pasteboard.changeCount()
    if now ~= cc then
      log.emit("clobbered", { id = id, cc = now, ours = cc, file = file })
    end
  end)
end

return M
