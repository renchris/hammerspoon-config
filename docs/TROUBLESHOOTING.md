# Troubleshooting

## Dock shortcuts don't work

**Symptom**: Alt+1-9 does nothing.

**Cause**: Hammerspoon needs Accessibility permission.

**Fix**: System Settings > Privacy & Security > Accessibility > enable Hammerspoon.
If it was already enabled, toggle it off and on.

## Screenshot not copied to clipboard

**Symptom**: Cmd+Shift+3/4 takes a screenshot but clipboard doesn't have the image.

**Cause**: The `screenshotWatcher` (pathwatcher) may have been garbage collected, or
the `~/Screenshots` directory doesn't exist.

**Fix**:
1. Verify the directory: `ls ~/Screenshots`
2. Restart Hammerspoon (menubar icon > Reload Config, or `hs -c "hs.reload()"`)
3. Check console for errors: Hammerspoon > Console

## No thumbnail appears

**Symptom**: Screenshot is copied to clipboard but no floating thumbnail slides in.

**Cause**: The canvas object or its timers may have been garbage collected.

**Fix**: Restart Hammerspoon. The reload cleanup guard ensures all stale objects
are cleaned up before re-initialization.

## Cmd+Shift+3/4 feels slow

**Symptom**: There's a ~150-200ms delay between the screenshot capture and the
clipboard copy / thumbnail.

**Cause**: This is expected. The pipeline is:
1. macOS captures the screenshot (~50ms to write file)
2. FSEvents fires the pathwatcher callback (~100ms)
3. Hammerspoon processes the file (~50ms)

The native macOS thumbnail also has a similar delay — it just hides it with animation.

## Can't remap Cmd+Shift+3/4

**Symptom**: Trying to bind Cmd+Shift+3 or Cmd+Shift+4 in Hammerspoon does nothing.

**Cause**: macOS Sequoia intercepts these shortcuts at the WindowServer level, before
any userspace application (including Hammerspoon's eventtap) can see them. This is an
architectural limitation of macOS, not a Hammerspoon bug.

**Workaround**: The current architecture works around this by letting macOS handle the
capture natively, then watching the filesystem for new screenshots. There is no way to
intercept or modify the capture behavior itself.

## Smart paste doesn't work in terminal

**Symptom**: Cmd+V in iTerm2/Kitty pastes text normally instead of converting to Ctrl+V for image paste.

**Cause**: Either Accessibility permission is missing (eventtap requires it), or your terminal
app is not in the `terminalApps` table in `init.lua`.

**Fix**:
1. Verify Accessibility permission (System Settings > Privacy & Security > Accessibility)
2. Check that your terminal's name matches exactly: iTerm2, Kitty, Terminal, or WezTerm
3. For other terminals, add them to the `terminalApps` table in `init.lua`
