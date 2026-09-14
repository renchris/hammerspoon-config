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

function M.stats()
  return { running = tap ~= nil and tap:isEnabled() or false }
end

return M
