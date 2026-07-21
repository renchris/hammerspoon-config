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

## Thumbnail never goes away

**Symptom**: The floating thumbnail stays in the bottom-right corner indefinitely.
Clicking it opens the screenshot in Preview but does not dismiss it. Only restarting
Hammerspoon or the Mac clears it.

**Cause** (fixed in the current config): the fade-out used to be a hand-rolled `hs.timer`
alpha loop that held the *only* Lua reference to a still-visible canvas inside the timer's
closure. Clicking the thumbnail during its 300ms fade — or the next screenshot landing in
that window — stopped the timer and dropped that reference without ever hiding the canvas.
In Hammerspoon 1.1.1 `hs.canvas:delete()` is merely an alias for `:hide()` (the destroy path
is commented out upstream), so a canvas window is destroyed *solely* by Lua garbage
collection. On Hammerspoon's idle sub-megabyte heap a GC can be days away, so the stranded
canvas stayed fully opaque and still clickable — indistinguishable from a permanent leak.

**Fix**: the fade is delegated to `hs.canvas:hide(seconds)`. Hammerspoon anchors a fading
canvas in its own Lua registry for the duration and always orders the window out at the end,
so no interruption can strand it. `dismissThumbnail` also nudges `collectgarbage` so
ordered-out canvas windows cannot pile up.

**Clearing a stuck thumbnail on an older config** — no restart required:

```bash
hs -c 'collectgarbage("collect")'   # collects the orphaned canvas immediately
hs -c 'hs.reload()'                 # or rebuild the Lua state
```

**Diagnosing**: Hammerspoon's canvas windows are invisible to `hs.window`, so ask the window
server. A ghost appears as `layer=3` + `onscreen=true` while every Lua global is `nil`:

```bash
hs -c 'return tostring(thumbCanvas)'    # nil, yet a thumbnail is on screen => orphan
```

## Clicking a thumbnail replaces the clipboard with an old screenshot

**Symptom**: clicking the thumbnail opens the screenshot in Preview, and a moment later
the Pop sound replays, a second thumbnail slides in, and the clipboard now holds an older
screenshot instead of what you had copied.

**Cause** (fixed in the current config): `hs.pathwatcher` watches with file-level FSEvents
flags, so a *metadata-only* change re-delivers the path. Opening a screenshot makes Preview
write a `com.apple.quarantine` xattr to it, which re-triggered the watcher. The old dedup
remembered only the single most recent path, so once any other screenshot had copied in
between, the stale re-delivery sailed through and was copied again in full.

**Fix**: the dedup is keyed on file identity (`size:mtime`) recorded at copy time. An xattr
write changes neither, so an unchanged file is ignored; only genuine content changes
re-trigger a copy.

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
