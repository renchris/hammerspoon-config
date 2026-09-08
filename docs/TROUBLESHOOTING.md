# Troubleshooting

## Dock shortcuts don't work

**Symptom**: Alt+1-9 does nothing.

**Cause**: Hammerspoon needs Accessibility permission.

**Fix**: System Settings > Privacy & Security > Accessibility > enable Hammerspoon.
If it was already enabled, toggle it off and on.

## Screenshot not copied to clipboard

**Symptom**: Cmd+Shift+3/4 takes a screenshot but clipboard doesn't have the image.

**Cause**: Until 2026-09-08 the usual cause was FSEvents — see "Screenshots dropped in
silence" below. Detection is now a directory poll, so what remains is mundane:
`~/Screenshots` missing, Hammerspoon not running, or the config failed to load.

**Fix**:
1. Read the pipeline log — every screenshot leaves a `detected` and a `copied` line:
   `tail -n 20 ~/Library/Logs/Hammerspoon/screenshot.log`
   - No `detected` line: the poll never saw the file. Check `ls ~/Screenshots` exists and
     `hs -c 'return screenshotPollTimer:running()'` prints `true`; otherwise reload.
   - `detected` but no `copied`: a `W`/`E` line on the next row says why (gave up waiting
     for a complete PNG, clipboard write failed).
2. Reload Hammerspoon: `hs -c 'hs.reload()'` (the log gets a fresh `poll armed` line).
3. Check the console for a Lua error: Hammerspoon > Console.

## Screenshots dropped in silence (FSEvents stalled) — fixed 2026-09-08

**Symptom**: some screenshots copy, some don't, with no pattern, and the ones that don't
show no thumbnail either. The old console showed
`FSEvents stream stopped delivering (no event in 120s) — re-arming watcher` every few minutes.

**Cause**: `fseventsd` saturated. Measured on this machine: load average 223 on 10 cores,
`fseventsd` at 100 % of a core for 13 days, fed ~250 `fsevent_add_client` registrations an
hour by Claude Code sessions. Every FSEvents consumer on the box is delayed by minutes —
Hammerspoon's `hs.pathwatcher`, and launchd `WatchPaths` too (a probe on the same directory
did not fire in 20 s). The liveness watchdog made it worse: each re-arm built a new stream
and discarded whatever was still queued, so a slow screenshot became a lost one. 5 of one
day's 13 screenshots never produced a `detected` line.

**Fix**: detection is a 50 ms `stat()` poll of the directory — it asks the kernel, not
`fseventsd` (README § "Why a poll and not FSEvents"). Nothing in `init.lua` depends on
FSEvents for screenshots any more. To see whether `fseventsd` is still saturated, and who
is feeding it:

```bash
ps -o %cpu= -p "$(pgrep -x fseventsd)"
log show --last 1h --predicate 'process == "fseventsd" AND eventMessage CONTAINS "add_client"' \
  --style compact | grep -oE 'pid [0-9]+' | sort | uniq -c | sort -rn | head
```

## Clipboard flips to an OLDER screenshot a moment later

**Symptom**: right after a screenshot the clipboard holds the right image, then a second or
two later it holds an earlier screenshot; or a paste yields PNG-only data.

**Cause**: a second, uncoordinated clipboard writer. claude-infrastructure installs a
launchd `WatchPaths` agent, `com.chrisren.screenshot-clipboard`
(`~/bin/screenshot-to-clipboard.sh`), which copies the newest PNG in `~/Screenshots` to the
clipboard — after a 0.5 s sleep plus an `osascript` that takes seconds under load, PNG only,
over whatever Hammerspoon already wrote. Two shots inside that window end with the older one
on the clipboard.

**Fix** (2026-09-08): the agent exits immediately when Hammerspoon is running and acts only
as a fallback when it is not. Verify:

```bash
grep -n 'pgrep -xq Hammerspoon' ~/bin/screenshot-to-clipboard.sh   # the deferral line
launchctl print "gui/$(id -u)/com.chrisren.screenshot-clipboard" | grep -E 'state|runs'
```

## No thumbnail appears

**Symptom**: Screenshot is copied to clipboard but no floating thumbnail slides in.

**Cause**: The canvas object or its timers may have been garbage collected. With more than
one display, first check the other screen: the thumbnail slides in on the display under the
mouse pointer (where the selection was just drawn), not on the display holding the focused
window.

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

**Symptom**: There's a ~100ms delay between the screenshot capture and the
clipboard copy / thumbnail.

**Cause**: This is expected. The pipeline is:
1. macOS captures the screenshot and renames the finished PNG into `~/Screenshots` (~50ms)
2. The 50 ms directory poll notices the new entry (≤ 50 ms + ~8 ms listing)
3. Hammerspoon reads, copies, verifies (~25 ms measured; `settled Nms` in the log)

The native macOS thumbnail also has a similar delay — it just hides it with animation.

Under heavy load the long pole is macOS's own `screencapture` process, not Hammerspoon:
measured 2026-09-08 at load average 223, `screencapture` took anywhere from 0.3 s to 10 s
to produce the file, while the poll-to-clipboard part stayed under 100 ms. An in-process
`hs.screen:snapshot()` took 33–86 ms on the same box, so a Hammerspoon-native capture would
remove that tail — but it would also replace the system crosshair UI (magnifier, space for
window mode), so it has not been done.

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
