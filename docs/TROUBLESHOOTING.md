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
1. Read the pipeline log. Every screenshot leaves one logfmt line per phase, joined by
   `id=` — six hex characters of the file's inode:
   `tail -n 30 ~/Library/Logs/Hammerspoon/screenshot.log`
   - **No `created` line at all**: the poll never saw the file. Check that `~/Screenshots`
     exists, then `hs -c 'return hs.inspect(hsc("screenshot"))'` — `started` must be true
     and `watcher.ticks` must be climbing between two calls. Otherwise reload.
   - **`created` but no `copied`**: look for `phase=lost` with its `reason=` (`settle-timeout`,
     `clipboard`, `unreadable`, `deleted`), or `phase=gone reason=not-png` — the entry was
     something other than a screenshot.
   - **`copied` then `clobbered`**: the write was verified and then another app took the
     clipboard. See "⌘V pastes the wrong thing" below.
   - **Neither `copied` nor `lost`**: the pipeline was not running when the shot was taken.
     That is the one failure the log cannot narrate, and it is why supervision matters.
2. Reload Hammerspoon: `hs -c 'hs.reload()'` (the log gets a fresh `phase=armed` line carrying
   both `entries=` and `expect=`, which must agree — see "The armed line says invariant=BROKEN").
3. Check the console for a Lua error: Hammerspoon > Console. A module that failed to load left
   a `phase=error` line naming itself.

## ⌘V pastes nothing into Claude Code, but the log says `copied`

**Symptom**: the thumbnail appears and the log has a verified `copied` line, but ⌘V in kitty
does nothing. ⌃V typed by hand works. Alt+1-9 Dock shortcuts are dead too.

**Cause**: Secure Event Input. While any app holds it (a focused password field), macOS delivers
no keystroke to any event tap, so smartpaste never sees ⌘V; kitty gets it untouched and pastes the
clipboard's text, which a screenshot does not have. The tap still reports itself enabled, so
every health check reads green. Measured 2026-10-21: the SevenRooms OS iPad app held secure input
from launch for 3 hours.

Since 2026-10-21 the pipeline reports it: a `phase=warn ... holder=<app> pid=<pid>` line after
`copied`, and an on-screen alert naming the app.

**Fix**: press ⌃V instead, or release secure input by leaving the password field or quitting
the holder. To check it by hand:

```bash
hs -c 'return tostring(hs.eventtap.isSecureInputEnabled())'               # true = taps are blind
ioreg -n Root -d 1 -w 0 | grep -o '"kCGSSessionSecureInputPID"=[0-9]*'   # the holder's pid
```

## Screenshots dropped in silence (FSEvents stalled) — fixed 2026-09-08

**Symptom**: some screenshots copy, some don't, with no pattern, and the ones that don't
show no thumbnail either. The old console showed
`FSEvents stream stopped delivering (no event in 120s) — re-arming watcher` every few minutes.

**Cause**: `fseventsd` livelocked. Measured on this machine 2026-09-08: one `fseventsd`
thread spinning at ~98 % user CPU with every other thread idle, delivering nothing — a
Node `fs.watch` on a test directory timed out 3 of 3 times at 30 s while a polling
`fs.watchFile` on the same directory saw the change in 104 ms. Every FSEvents consumer on
the box went blind at once — Hammerspoon's `hs.pathwatcher`, and launchd `WatchPaths` too (a
probe on the same directory did not fire in 20 s). The liveness watchdog made it worse: each
re-arm built a new stream and discarded whatever was still queued, so a slow screenshot
became a lost one. 5 of one day's 13 screenshots never produced a `detected` line. (The
first read of this incident blamed the Claude Code fleet's ~250 FSEvents client
registrations an hour; a follow-up investigation showed those were a symptom, not the cost.)

**Fix, in Hammerspoon**: detection is a 50 ms `stat()` poll of the directory — it asks the
kernel, not `fseventsd` (README § "Why a poll and not FSEvents"). Nothing in `init.lua`
depends on FSEvents for screenshots any more, so a wedged daemon cannot lose a screenshot.

**Fix, for the daemon** (everything else on the Mac that watches files): restart it.
`sudo launchctl kickstart -k system/com.apple.fseventsd` is refused under System Integrity
Protection (error 150); a plain signal is not, and launchd respawns the daemon. Delivery came
back in 35 ms after this, and the CPU fell from ~100 % to ~1 %:

```bash
ps -o pid=,%cpu= -p "$(pgrep -x fseventsd)"      # ~100% with nothing being delivered = livelocked
sudo kill -TERM "$(pgrep -x fseventsd)"          # launchd respawns it; one extra Spotlight/Time Machine scan at most
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
as a fallback when it is not.

**RETIRED 2026-09-13.** The agent, its plist and `~/bin/screenshot-to-clipboard.sh` are gone
(claude-infrastructure `chore(launchd): retire com.chrisren.screenshot-clipboard`; its
`launchd/fleet.manifest` row reads `retired`). Hammerspoon is now supervised by launchd (see
"Hammerspoon is supervised by launchd" below), so the fallback's window shrank to the ~0.6 s
restart — and inside that window it was harmful: it deferred to any Hammerspoon *pid* (a zombie
whose config never loaded, on 2026-09-10), its 10 s launchd throttle × 10 s recency guard dropped
every shot Apple stalled, and it could land an older PNG over a newer shot (plan Phase 6). If
this symptom ever returns, a second clipboard writer is back — find it:

```bash
bash scripts/supervise.sh status | grep fallback_agent               # must read: fallback_agent=absent
launchctl print "gui/$(id -u)/com.chrisren.screenshot-clipboard"   # must fail: "Could not find service"
ls ~/Library/LaunchAgents | grep -i -e screenshot -e clipboard      # must print nothing
```

It can come back: claude-infrastructure's deployer runs `install.sh` from the newest green tree,
and any tree older than the retirement still declares the agent `run` and re-bootstraps it; the
newer `install.sh` never boots a retired label out again. `status` turns NOT-HEALTHY and prints
the one-line removal when that happens.

Dictation tools (VoiceInk, Wispr Flow) also write the clipboard around a dictation.

## No thumbnail appears

**Symptom**: Screenshot is copied to clipboard but no floating thumbnail slides in.

**Cause**: with more than one display, first check the other screen — the thumbnail appears on
the display under the **mouse pointer** (where the selection was just drawn), not on the display
holding the focused window.

**Fix**: the log settles it without guessing. A `copied` line followed by `thumb-shown` and
`thumb-visible` means the window server is presenting it somewhere:

```bash
grep -a 'phase=thumb' ~/Library/Logs/Hammerspoon/screenshot.log | tail -5
```

- `thumb-shown` carries `x=` `y=` `w=` `h=` — the canvas's actual frame. Compare it with
  `hs -c 'return hs.inspect(hs.screen.allScreens())'`.
- `thumb-shown` with no `thumb-visible` means `hs.canvas:isOccluded()` never went false: the
  canvas is ordered in but off every display, or covered. (`isShowing()` is not an oracle for
  this — it returns true for a canvas parked at 4000,4000.)
- `warn … msg=no_thumbnail_(image_could_not_be_decoded)` means the copy succeeded and the decode
  did not — the clipboard still has the image.
- No `copied` line at all: this is the previous section, not a thumbnail problem.

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
server — and ask it *geometrically*, because `kCGWindowIsOnscreen` means "ordered in", not "on a
display": a canvas at (4000,4000) reports `onscreen=true`. The bench's prober already does this:

```bash
printf 'probe\nquit\n' | bench/winprobe
# {"visible":true,"frac":1.0,"n":1,"bounds":[1356,703,352,276]}  -- a thumbnail is really up
# {"visible":false,"frac":0,"n":0,"bounds":[]}                   -- nothing is up
```

`n` is how many `layer=3` Hammerspoon windows exist; more than one after the dismissal has run
is an orphan. `hs -c 'return hs.inspect(hsc("screenshot").screenshot.thumbnail)'` reports whether the
module thinks one is visible, which is the other half of the answer.

## Clicking a thumbnail replaces the clipboard with an old screenshot

**Symptom**: clicking the thumbnail opens the screenshot in Preview, and a moment later
the Pop sound replays, a second thumbnail slides in, and the clipboard now holds an older
screenshot instead of what you had copied.

**Cause** (fixed in the current config): `hs.pathwatcher` watches with file-level FSEvents
flags, so a *metadata-only* change re-delivers the path. Opening a screenshot makes Preview
write a `com.apple.quarantine` xattr to it, which re-triggered the watcher. The old dedup
remembered only the single most recent path, so once any other screenshot had copied in
between, the stale re-delivery sailed through and was copied again in full.

**Fix (2026-09-08)**: the dedup was keyed on file identity (`size:mtime`) recorded at copy time.
An xattr write changes neither, so an unchanged file was ignored.

**Fix (current)**: there is no event stream at all — detection is a poll — and the dedup is keyed
on the **inode**, recorded on the *verified copy* and never at detection. A second appearance of
a known inode is treated as what it is, a rename: the recorded path is re-pointed and nothing is
copied again. Recording the inode at detection instead would make the final name look like a
duplicate of the hidden one and drop the shot silently, which is why the order matters.

## Cmd+Shift+3/4 feels slow

**Symptom**: seconds pass between the capture and the clipboard or thumbnail.

**Cause, before 2026-09-13**: Apple. `screencapture` writes a complete PNG under a hidden name,
then makes an unconditional Spotlight round trip (`MDItemCreate` → `MDItemSetAttributes`), and
only *then* renames the file to its final name. The old matcher waited for that final name, so it
inherited the whole stall: p90 225 ms, p99 about 10 s, with 13.7 s and 29.4 s observed. No
preference, directory exclusion or flag removes it — the call is unguarded straight-line code
with no branch to take.

**Cause, after 2026-09-13**: nothing should. The pipeline copies from the hidden name, so the
stall is off the path entirely; `phase=renamed` routinely lands *seconds after* `phase=copied`,
which is the design working. What remains is 10 ms of poll, a few hundred microseconds of read,
and 3–19 ms of pasteboard.

**Diagnosing**: the `copied` line carries its own breakdown.

```bash
grep -a 'phase=copied' ~/Library/Logs/Hammerspoon/screenshot.log | tail -5
#   dt=           ns from first sight to a verified clipboard
#   read_ns=      reading the PNG through the open handle
#   pb_write_ns=  hs.pasteboard.writeAllData on the general board
#   pb_verify_ns= reading it back to prove the bytes landed
```

A large `pb_write_ns` is the machine's own clipboard observers being notified: the same write to
a *private* pasteboard is 0.43 ms for 351 KB, against 3–19 ms on the general board.

**If it is still slow**, the remaining suspect is a main-thread stall, and a stall is never made
up: CFRunLoopTimer coalesces missed fires rather than catching up, so detection inside a stall of
duration *D* costs `D + one scan`. Nothing is lost; it is purely latency. Compare `watcher.ticks`
across two seconds — it should climb by about 100 per second:

```bash
hs -c 'return hsc("screenshot").screenshot.watcher.ticks'; sleep 1
hs -c 'return hsc("screenshot").screenshot.watcher.ticks'
```

## ⌘V pastes the wrong thing after a screenshot

**Symptom**: the log says `copied`, but ⌘V pastes text, or an older image.

**Cause**: another application wrote the clipboard after we did. This box runs at least one
dictation tool that snapshots and restores the pasteboard around its own work, and a clipboard
manager will do the same.

**Fix**: the pipeline re-checks `changeCount` 300 ms after its verified write and logs
`phase=clobbered` with both counts when it moved and we did not move it. So the question is
answerable rather than mysterious:

```bash
grep -a 'phase=clobbered' ~/Library/Logs/Hammerspoon/screenshot.log | tail -5
```

There is no fix inside this config — whoever wrote last wins — but the line names the failure
instead of letting the 7-day acceptance score it a success.

## A hidden `.Screenshot …` file is left in ~/Screenshots

**Symptom**: `ls -a ~/Screenshots` shows entries starting with a dot, or with a `-XXXX` suffix.

**Cause**: `screencapture` was killed between finishing the PNG and renaming it — the window
where it sits inside Apple's Spotlight call, which can last tens of seconds.

**Fix**: the pipeline un-hides it itself, 30 s after first sight, once no `screencapture` process
is alive and only if the file is a *complete* PNG (an incomplete one is left alone rather than
given a name it does not deserve). Look for `phase=stranded`. A dotfile older than that with no
`stranded` line was created while the pipeline was not running; rename it by hand.

## The armed line says `invariant=BROKEN`

**Symptom**: `phase=armed … entries=3423 expect=3421 invariant=BROKEN`.

**Cause**: the reconcile loop terminates early when the directory's name count agrees with
`st_size/32`. On this volume they agree exactly — `hs.fs.dir` yields `.` and `..`, which is why
the count matches `size/32` and not `size/32 − 2` as POSIX `listdir` would. A filesystem that
reports directory sizes differently breaks that equality.

**Fix**: nothing to do. The watcher detects this at arm, says so, and falls back to running the
reconcile loop for its full 10-tick bound after every size change. Correct either way, just less
frugal: about 24 ms of extra listing per size change instead of one.

## `phase=error … ipc.lua:81: ipc port is no longer valid` / `stack overflow`

**Symptom**: a burst of `phase=error` lines whose message points at
`hs/ipc.lua:81`, `hs/_coresetup.lua:26` or `hs/logger.lua:189`, clustered around reloads.

**Cause**: `hs.ipc` REPLACES the global `print`, and its replacement RAISES when the IPC port is
stale — which is what happens while Hammerspoon is tearing down for a reload with a `hs -c`
connection in flight. Some extension internally prints, the replacement raises, formatting that
error prints again, and the recursion is the stack overflow. Measured 2026-09-13: 42 such lines
across a session of heavy `hs -c` use, **all of them inside reload windows and none during a
14-minute unattended bench**, with zero screenshots lost in either.

**Fix**: nothing to do, and the lines are the design working rather than failing. Two guards make
this a log entry instead of an outage: the poll's callback runs inside a `pcall` and the timer is
created with `continueOnError`, so the error is recorded and the next tick proceeds; and nothing in
this config calls `print` or `hs.logger` at all, so the pipeline never *originates* one. The same
mechanism, unguarded, is how the config died on 2026-09-10 at 12:03:36 — `EXC_BREAKPOINT` inside
hs.ipc's logger, taking every feature with it.

If you see these lines with NO reload nearby, that is different and worth reading: check
`hs -c 'return hsc()._ipc'`, which is false when another instance owns the port.

🚨 **Never wrap `hs -c` in `timeout`.** The lines above are survivable; the crash that follows them
is not. On 2026-09-13 at 21:01:43 the live instance died of `EXC_BREAKPOINT` in
`CFMessagePortSendRequest` ← `libipc ipc_sendMessage` — Hammerspoon replying to a CLI client's
message port after the client had gone — and what makes a client go away mid-reply is exactly
`timeout N hs -c …`, which that session had been running dozens of times to syntax-check Lua.
launchd re-forked it and the watcher re-armed in 0.7 s, so the cost was small; before supervision
the identical crash meant hours dead.

**Use `hs -t <seconds>` instead** — the CLI's own client-side bound, which tears the port down
cleanly. Every `hs` call in `scripts/screenshot-bench.sh` uses it (`-t 10` for a reload, `-t 5` for
a stats read); `scripts/supervise.sh` and `scripts/install.sh` were changed the same way
(`1aa6720`) after this was found.

## The bench refuses to run

**Symptom**: `ABORT: operator present (idle 12s < 180s required)`, or
`ABORT: multi-item pasteboard; refusing to run`.

**Cause**: both are deliberate. The bench captures the live desk and owns the general pasteboard
for the duration, so it will not start while somebody is using the machine; and a multi-item
clipboard cannot be restored faithfully (only the first item survives a round trip), so it
refuses to touch one rather than destroy it.

**Fix**: leave the machine alone for three minutes, or copy something ordinary first. `--quick N`
uses the same gate on purpose. If `swiftc` is missing, install the Command Line Tools — the
prober is the bench's only native dependency.

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

**Cause**: either Accessibility permission is missing (eventtap requires it), or your terminal's
**bundle id** is not in `hsc/apps.lua`.

**Fix**:
1. Verify Accessibility permission (System Settings > Privacy & Security > Accessibility).
2. Get the bundle id — never the display name:
   `hs -c 'return hs.application.frontmostApplication():bundleID()'`
3. Add it to `M.terminals` in `hsc/apps.lua`. The table was name-keyed until 2026-07-31 and
   silently missed kitty, whose `CFBundleName` is lowercase `kitty`; both features that read it
   were dead there while working in iTerm2 by the accident of its name matching exactly.

Note that the tap **self-heals**: `libeventtap.m` re-enables on both
`kCGEventTapDisabledByTimeout` and `…ByUserInput`, so a long main-thread stall drops events
during it but never leaves the tap permanently dead.

## Hammerspoon is supervised by launchd (since 2026-09-13)

**What changed**: Hammerspoon is no longer a Login Item. The user agent
`org.hammerspoon.Hammerspoon.keepalive` (`launchd/…keepalive.plist`, installed by
`scripts/supervise.sh install`) starts it at login and restarts it the moment it dies — measured
**respawn 49 ms** after a SIGTERM and the screenshot watcher re-armed **565 ms** after the kill.
Before this, a fleet script SIGTERMed it on 2026-09-09 and nothing restarted it for 5.4 h.
Sparkle's auto-update is off (`SUAutomaticallyUpdate=0`), so only launchd ever starts it.

**Is it healthy?** `bash scripts/supervise.sh status` — one fact per line, `verdict=supervised`
and exit 0 only when: the job is loaded from the repo's plist, exactly one Hammerspoon runs and it
is launchd's, the watcher logged an `armed` line since that process started, the Login Item is
gone, and Sparkle auto-update is off. It reads the **log heartbeat, never just a pid** — on
2026-09-10 a live-looking pid was a zombie whose config never loaded.

**Prove the restart works**: `bash scripts/supervise.sh --prove` (kills it on purpose; prints
`respawn N ms` and the detector downtime; exit 0 = pass, N < 2000).

**Symptoms and fixes**:
- *Quitting from the menu bar does nothing* — correct: under KeepAlive a quit is a restart. To
  stop it for real: `bash scripts/supervise.sh uninstall` (restores the Login Item and Sparkle
  setting exactly as they were before install and relaunches it unsupervised; `--no-launch` leaves
  it stopped).
- *Two Hammerspoon processes* (`pgrep -x Hammerspoon | wc -l` > 1) — something launched one outside
  launchd (the Login Item re-added, a manual binary exec). `status` names it; quit the one that is not
  `job_pid`. 🚨 Never run `/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon` directly, not
  even with `--version` — it ignores argv and starts a second instance.
- *It relaunches every ~10 s* — a start-up crash loop (launchd's default throttle). `status` shows
  `launchd_runs` climbing with a young `age_s`; read `launchd_last_exit_code` /
  `launchd_last_terminating_signal`, then Hammerspoon > Console or the crash report.
- *Updating Hammerspoon* — use the Hammerspoon menu (Check for Updates). Afterwards run `status`:
  it must still say one instance.
- *A permission looks lost* — `install` asserts Accessibility, Screen Recording and `hs.eventtap`
  on the launchd-started instance **before** it removes the Login Item, and rolls back if any is
  missing; grants are keyed to the signed bundle, so the launch path does not change them.