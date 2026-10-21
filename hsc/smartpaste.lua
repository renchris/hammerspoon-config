-- hsc/smartpaste.lua — ⌘V sends ⌃V for images in terminals, so Claude Code accepts a screenshot.
--
-- Claude Code's TUI takes an image paste on ⌃V; every other app on this desk takes ⌘V.  The tap
-- rewrites one into the other, and only when all three conditions hold: the key is ⌘V exactly, the
-- front app is a terminal (by BUNDLE ID — see hsc/apps), and the clipboard actually carries an
-- image.  Anything else falls straight through.
--
-- The tap must stop itself around the synthetic event or it re-enters its own callback.
--
-- Measured note (F2, and it corrects an earlier assumption in the knowledge base): this tap
-- SELF-HEALS.  libeventtap.m re-enables on both kCGEventTapDisabledByTimeout and
-- …ByUserInput, so a long main-thread stall drops events DURING it but does not leave the tap dead.
-- Hostile review item 6 was half wrong.
local apps = require("hsc.apps")
local log  = require("hsc.log")

local M = {}
local tap = nil

local function clipboardHasImage()
  local types = hs.pasteboard.contentTypes()
  if not types then return false end
  for _, t in ipairs(types) do
    if t == "public.png" or t == "public.jpeg" or t == "public.tiff" then return true end
  end
  return false
end

function M.start()
  if tap then return true end
  tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    local flags = event:getFlags()
    if event:getKeyCode() ~= 9 then return false end              -- 9 = 'V'
    if not flags.cmd or flags.shift or flags.alt or flags.ctrl then return false end

    local front = hs.application.frontmostApplication()
    if not (apps.isTerminal(front) and clipboardHasImage()) then return false end

    tap:stop()
    pcall(function()
      hs.eventtap.event.newKeyEvent({ "ctrl" }, "v", true):post()
      hs.eventtap.event.newKeyEvent({ "ctrl" }, "v", false):post()
    end)
    tap:start()
    return true
  end)
  tap:start()
  log.emit("start", { module = "smartpaste" })
  return true
end

function M.stop()
  if tap then tap:stop(); tap = nil; log.emit("stop", { module = "smartpaste" }) end
end

-- 🚨 SECURE EVENT INPUT BLINDS THIS TAP, and nothing about the tap shows it.  While any app holds
-- Secure Event Input (a focused password field), macOS delivers no keystroke to ANY event tap, so
-- ⌘V reaches kitty untouched, kitty pastes the clipboard's text (there is none) and the screenshot
-- silently goes nowhere — while the tap still reports itself enabled.  Measured 2026-10-21: the
-- SevenRooms OS iPad app held it from launch for 3 h; every pipeline log line read healthy.  ⌃V
-- typed by hand still works — that is Claude Code's own binding, no tap involved.  So the screenshot
-- module calls this after each verified copy, and the condition announces itself instead of costing
-- an investigation.  The holder's pid comes from IOConsoleUsers via an ASYNC hs.task (ioreg, ~26 ms),
-- spawned only when the in-process check already says secure input is on.
--
-- 🚨 THE grep RUNS INSIDE THE TASK, not in Lua.  `ioreg -n Root -d 1` prints ~87 KB, and an hs.task
-- with no streaming callback does not drain stdout until exit: past the 64 KB pipe buffer ioreg
-- blocks on write and the callback never fires (measured: two ioreg processes parked in state S).
-- Filtered, the output is one ~40-byte line.  `probe` holds the task so a stuck one is never
-- duplicated, and the 2 s timer kills it so a hang cannot silence every later warning.
local probe = nil

function M.warnIfBlind(id)
  if not tap or not hs.eventtap.isSecureInputEnabled() then return false end
  if probe then return true end
  probe = hs.task.new("/bin/sh", function(_, out)
    probe = nil
    local pid = tonumber((out or ""):match('"kCGSSessionSecureInputPID"=(%d+)'))
    local app = pid and hs.application.applicationForPID(pid)
    local name = app and app:name() or "another app"
    log.warn("secure-input", { id = id, msg = "secure input on; ⌘V rewrite is blind", pid = pid or 0,
                               holder = name })
    hs.alert.show(string.format("⌘V can't paste this screenshot: %s holds Secure Input.\n"
                                .. "Press ⌃V in Claude Code, or quit %s.", name, name), 4)
  end, { "-c", [[/usr/sbin/ioreg -n Root -d 1 -w 0 | /usr/bin/grep -o '"kCGSSessionSecureInputPID"=[0-9]*']] })
  probe:start()
  local mine = probe
  hs.timer.doAfter(2, function()
    if probe == mine then probe:terminate(); probe = nil end
  end)
  return true
end

function M.stats()
  return { running = tap ~= nil and tap:isEnabled() or false,
           secure_input = hs.eventtap.isSecureInputEnabled() }
end

return M
