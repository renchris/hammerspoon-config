-- ~/.hammerspoon/init.lua — a LOADER.  Every behaviour lives in a module under hsc/.
--
-- 1. BOOTSTRAP.  This repository is not on package.path: Hammerspoon's setup.lua puts only
--    ~/.hammerspoon there, and ~/.hammerspoon is a real directory in which only init.lua is a
--    symlink into the checkout.  So the first thing that happens is resolving that symlink and
--    putting the checkout on the path.  It degrades correctly when init.lua is NOT a symlink
--    (a direct install), in which case hs.configdir is already the root.
--
-- 2. NO RELOAD GUARD.  The 14 lines of `if screenshotPollTimer then screenshotPollTimer:stop() end`
--    that used to open this file were DEAD CODE: hs.reload() builds a fresh Lua environment, so
--    every global they tested was already nil (F1, measured).  The sanctioned surface is
--    hs.shutdownCallback, which Hammerspoon calls before both a reload and a quit — and which is
--    wired at the bottom of this file to stop each module in reverse order.
--
-- 3. NO FEATURE GLOBALS.  A table reachable from package.loaded anchors a timer or a canvas against
--    garbage collection exactly as well as a global does (measured: 50 ticks vs 0 for an unanchored
--    local).  Every module holds its own state at module scope.
--
-- 4. 🚨 EVERY require AND EVERY start() RUNS UNDER ITS OWN pcall, SCREENSHOT FIRST.  On 2026-09-10
--    12:03:36 a second Hammerspoon instance's config aborted at line 5 — `hs.ipc.cliInstall()` —
--    and took every later feature down with it, including the screenshot pipeline, in silence.  One
--    unguarded line at the top of a config is a single point of failure for everything below it.
--    Order is by importance, so a module that fails costs only itself and the ones after it.
--
-- 5. hs.ipc IS REQUIRED LAST, AFTER THE MODULES ARE RUNNING, AND ONLY UNDER pcall.  A failure means
--    another instance owns the `Hammerspoon` port — worth recording, but the screenshot pipeline
--    does not need IPC and must not die with it.  hs.ipc.cliInstall() is NOT called: both `hs`
--    symlinks on this machine already exist and are Homebrew's.

local ROOT = (hs.fs.symlinkAttributes(hs.configdir .. "/init.lua", "target")
              or (hs.configdir .. "/init.lua")):match("(.*)/")
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

local log = require("hsc.log")
log.start(os.getenv("HOME") .. "/Library/Logs/Hammerspoon/screenshot.log")
log.emit("start", { module = "init", root = ROOT, hs = hs.processInfo.version })

-- The registry.  Order is load order AND start order; shutdown runs it in reverse.
local REGISTRY = {
  { name = "screenshot", path = "hsc.screenshot" },
  { name = "breakglass", path = "hsc.breakglass" },   -- no-tty rescue chooser (⌃⌥⌘⇧B / ⌃⌥⌘⇧C), 2026-10-25
  { name = "smartpaste", path = "hsc.smartpaste" },
  { name = "dock",       path = "hsc.dock" },
  { name = "lockwatch",  path = "hsc.lockwatch" },    -- lockwatch menubar + hb dead-man page
}

local loaded = {}

for _, entry in ipairs(REGISTRY) do
  local ok, mod = pcall(require, entry.path)
  if not ok then
    log.error("require:" .. entry.name, { module = entry.name, msg = tostring(mod) })
  else
    local started, err = pcall(mod.start)
    if not started then
      log.error("start:" .. entry.name, { module = entry.name, msg = tostring(err) })
    else
      loaded[#loaded + 1] = { name = entry.name, mod = mod }
    end
  end
end

-- Single-instance detection WITHOUT a spawn.  hs.processInfo has no parent-pid field and a pgrep at
-- load is exactly the kind of synchronous spawn this rewrite removes, so the signal is the IPC port
-- itself: if another instance already owns it, requiring hs.ipc fails.  A launchd-supervised
-- instance must NOT exit on this (KeepAlive would respawn it into the same condition) — it reports.
local ipcOK, ipcErr = pcall(require, "hs.ipc")
if not ipcOK then
  log.warn("ipc", { msg = "hs.ipc unavailable — another instance may own the port: " .. tostring(ipcErr) })
end

hs.shutdownCallback = function()
  for i = #loaded, 1, -1 do
    pcall(loaded[i].mod.stop)
  end
  log.emit("stop", { module = "init", modules = #loaded })
  log.stop()
end

-- `hs -c 'hs.inspect(hsc())'` — the one entry point the CLI and the bench use.
function hsc(which)
  local out = {}
  for _, e in ipairs(loaded) do
    if not which or which == e.name then
      local ok, s = pcall(e.mod.stats)
      out[e.name] = ok and s or { error = tostring(s) }
    end
  end
  out._ipc = ipcOK
  return out
end

log.emit("start", { module = "init", modules = #loaded, ipc = ipcOK and 1 or 0 })
