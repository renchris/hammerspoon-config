-- hsc/apps.lua — the terminal bundle-id table, in ONE place.
--
-- This table is read by two features (the ⌥+digit passthrough for tmux, and the ⌘V→⌃V rewrite that
-- lets Claude Code accept a ⌘⇧4 screenshot from the clipboard), and it used to be written out
-- twice.  Commit 2bf64de fixed the duplication once; a module is what stops it coming back.
--
-- Keyed by BUNDLE ID, never by display name.  The table used to be name-keyed
-- (`Kitty = true, iTerm2 = true, …`) and it silently missed kitty: Hammerspoon reports kitty's name
-- as "kitty" (lowercase, from its CFBundleName), so `terminalApps[front:name()]` evaluated to nil
-- and BOTH behaviours were dead in kitty.  It kept working in iTerm2 for the accidental reason that
-- iTerm2's CFBundleName is exactly "iTerm2".  Ghostty was absent altogether.  Verified live
-- 2026-07-31.  A bundle id is case-exact, stable across renames, and cannot drift with however the
-- vendor capitalises the app.
local M = {}

M.terminals = {
  ["net.kovidgoyal.kitty"]   = true,  -- kitty
  ["com.googlecode.iterm2"]  = true,  -- iTerm2  (bundle on disk is iTerm.app)
  ["com.mitchellh.ghostty"]  = true,  -- Ghostty
  ["com.github.wez.wezterm"] = true,  -- WezTerm
  ["com.apple.Terminal"]     = true,  -- Terminal
}

--- Takes an hs.application OBJECT (not a name), so the decision is made on the bundle id.  Callers
--- that only had a name string pass the app object the API already hands them.
function M.isTerminal(app)
  if not app then return false end
  local ok, id = pcall(function() return app:bundleID() end)
  return ok and id ~= nil and M.terminals[id] == true
end

return M
