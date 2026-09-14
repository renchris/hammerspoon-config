# hammerspoon-config

Hammerspoon configuration for macOS Sequoia. `init.lua` is a **loader**; every feature is a
module under `hsc/`:

1. **Screenshot to clipboard** (`hsc/screenshot/`) — Cmd+Shift+3/4 saves a file, copies it to
   the clipboard and shows a floating thumbnail, from the PNG's *hidden temporary name* so
   Apple's Spotlight stall is never on the path
2. **Smart paste** (`hsc/smartpaste.lua`) — Cmd+V in terminal apps sends Ctrl+V when the
   clipboard has an image (for Claude Code image paste)
3. **Dock app shortcuts** (`hsc/dock.lua`) — Alt+1-9,0 launches/focuses pinned Dock apps
   (auto-updates when the Dock changes, disables in terminals for tmux Alt+N)

Modules load and start in that order, each under its own `pcall`, so a module that fails
costs only itself. Shutdown runs the list in reverse from `hs.shutdownCallback`.

## Quick Start

```bash
git clone <repo-url>
cd hammerspoon-config
./scripts/install.sh
```

## Screenshot Feature

macOS Sequoia intercepts Cmd+Shift+3/4 at the WindowServer level before any userspace
app. Hammerspoon cannot override these shortcuts via hotkey binding or event taps.

**Architecture**: native macOS handles the capture. `show-thumbnail` is disabled so files
write to disk instantly. Hammerspoon **polls** `~/Screenshots` — one `stat()` of the directory
every **10 ms** (27 µs each) — and lists it only when the directory's **`st_size` changes**.

**The one idea: the dotfile is the file.** `screencapture` writes a *complete* PNG under a
hidden name, then makes an unconditional Spotlight round trip, and only then renames the file
to its final name. That round trip is unbounded — 13.7 s and 29.4 s have been observed on this
machine, and the "10 s" of folklore is `mds`'s per-message watchdog, not a limit. A watcher
keyed on the *final* name pays all of it. This one is keyed on the hidden name and pays none:

```
..Screenshot X.png-OCez   ImageIO's streaming temp (partial)
 .Screenshot X.png        complete at its first appearance — same inode, same bytes   ← we copy HERE
  Screenshot X.png        the final name, after the Spotlight stall
```

All three names are one inode, and the pipeline holds an **open file handle** from first sight,
so a rename between two polls costs nothing.

| Step | Handler | Latency (measured) |
|------|---------|--------------------|
| 1. Crosshair / capture | macOS native | 0 ms (system) |
| 2. PNG complete under a hidden name | macOS native | 16 ms p50, 162 ms p99 |
| 3. Poll notices the new entry | Hammerspoon `stat` every 10 ms | p50 4.7 ms, p99 11.1 ms |
| 4. Settle to IEND through the open handle | Hammerspoon | 0.17 ms per check |
| 5. Verified PNG-only clipboard write | Hammerspoon | 0.4 ms read + 3–19 ms pasteboard |
| 6. Thumbnail, then the Pop sound | Hammerspoon | ~30–90 ms to actually visible |
| — | Apple's rename to the final name | **off the path**: p90 225 ms, p99 ~10 s |

**Why `st_size` alone, and nothing else.** APFS reports a directory's size as 32 bytes per
entry, so a *creation* always moves it while a same-directory *rename* never does. The previous
signature was `mtime:ctime:size`, and because `hs.fs` exposes whole seconds, a rename landing in
the same wall-clock second as its create changed nothing it looked at — ~3 % of shots at the old
50 ms poll, with one production instance measured at **6 026 ms**, the worst latency ever seen on
this box, and it was ours rather than Apple's. A size-only signature deliberately ignores renames,
which is correct precisely because detection now triggers on *creation*. The one hole it leaves —
a tick in which one entry is created and another unlinked has Δsize zero — is closed by an
unconditional **1 Hz rescan**, and a size change re-lists every tick until the name count
reconciles with `st_size/32` (bounded at 10), because a single listing races Apple's renames.

**Why a poll and not FSEvents.** Detection used to be an `hs.pathwatcher` (FSEvents). On
2026-09-07 this machine's `fseventsd` was found pinned at ~100 % of a core and delivering
nothing: the liveness watchdog re-armed the stream 35 times in one day, every re-arm discarded
what was queued, and 5 of the day's 13 screenshots never even reached the "detected" log line.
A `touch` probe was still undelivered after 40 s, and a launchd `WatchPaths` agent on the same
directory did not fire in 20 s. A follow-up investigation (claude-infrastructure,
`docs/research/fseventsd-churn-2026-09-08.md`) showed the daemon was **livelocked** — one thread
spinning in user space for about a day — not overloaded by its clients, and that restarting it
(`sudo kill -TERM <pid>`; `launchctl kickstart` is refused under SIP) restored delivery in 35 ms.
A `stat()` asks the kernel, not `fseventsd`, and answers immediately whether or not the daemon
is healthy — so the poll has a hard latency bound and nothing to lose. It stays.

### Clipboard Format — PNG only

One flavour, `public.png`, written with `hs.pasteboard.writeAllData` and **verified**: the write
counts only if `changeCount` advanced *and* `readDataForUTI("public.png")` returns the same byte
length. A UTI merely being advertised is not proof, because the pasteboard server advertises
translations it can synthesise.

TIFF is not written, and does not need to be. The pasteboard server hands a valid TIFF to any
legacy reader on demand — verified from a separate AppKit process, even after the writer has
exited — while encoding one ourselves cost 55 ms of a 60 ms copy. `screencapture -c`, Apple's own
Control-held capture, likewise writes exactly one flavour, PNG. Claude Code's clipboard reader
asks `NSPasteboard` for `public.png` first and never asks for TIFF.

`SCREENSHOT_TIFF=true` re-enables a delayed second write for the day a consumer proves it needs
one. There is no explicit `clearContents()`: `writeAllData` clears the board itself, and the extra
call was a second `changeCount` bump that woke every pasteboard observer on an empty board.

### Floating Thumbnail

- Built **at its final position** in the bottom-right and faded in with `hs.canvas:show(0.12)`
  — a Core Animation fade on the window server, 0.02–0.05 ms of main thread, no timer
- Appears on the display under the **mouse pointer** (where the selection was drawn), not on the
  display holding the focused window
- Auto-dismisses after 3 seconds with a 300 ms fade
- Click opens the file in Preview, resolving the path **by inode at click time**
- Rapid screenshots: a new thumbnail replaces the previous one cleanly

The slide-in was deleted rather than tuned. `THUMB_SLIDE_DUR/THUMB_SLIDE_FPS` yielded three
frames, the canvas started fully off-screen, and the first on-screen pixel appeared 83 ms after
`show()` — a third of the visible budget — for animation state that had already produced two
shipped bugs.

### macOS Settings Applied by Install

```bash
# Screenshot location
defaults write com.apple.screencapture location ~/Screenshots

# Disable native thumbnail (required for instant file save)
defaults write com.apple.screencapture show-thumbnail -bool false
```

## Dock App Shortcuts

| Shortcut | Action |
|----------|--------|
| Alt+1 | Finder (always first) |
| Alt+2-9 | Pinned Dock apps in order |
| Alt+0 | 10th pinned Dock app |
| Alt+Cmd+R | Refresh bindings manually |

Auto-disables in terminal apps (iTerm2, Kitty, Terminal, WezTerm) so tmux Alt+N
window switching works.

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the symlink, re-enables native screenshot thumbnail, resets screenshot
location to Desktop, and stops Hammerspoon. Restores your backup init.lua if one exists.

## The log

Every phase of every screenshot leaves one logfmt line. This is the pipeline's only output
surface — nothing calls `print` or `hs.logger`, because `hs.ipc` replaces the global `print`
with a version that raises on a stale port, and that is exactly how the config died on
2026-09-10 at 12:03:36.

```bash
tail -f ~/Library/Logs/Hammerspoon/screenshot.log
```

```
ts=2026-09-13T20:44:45.535-0500 mono=1409790687653375 phase=created  id=fec54f size=196608 file=..Screenshot 2026-09-13 at 8.44.44 PM.png-NKr8
ts=2026-09-13T20:44:45.566-0500 mono=1409790719272666 phase=capture-complete id=fec54f dt=31614916 bytes=486665 file=..Screenshot …-NKr8
ts=2026-09-13T20:44:45.575-0500 mono=1409790728334458 phase=copied   id=fec54f dt=40681666 bytes=486665 cc=714 seq=3 file=..Screenshot …-NKr8
ts=2026-09-13T20:44:45.690-0500 mono=1409790843227041 phase=thumb-visible id=fec54f dt=155585416 file=..Screenshot …-NKr8
ts=2026-09-13T20:44:46.161-0500 mono=1409791313835291 phase=renamed  id=fec54f file=Screenshot 2026-09-13 at 8.44.44 PM.png
```

- `id` is six hex characters of the **inode** — the only identifier that survives both renames,
  and what joins a `created` line under a hidden name to its `copied` line.
- `mono` is verbatim nanoseconds from `hs.timer.absoluteTime()`, which is the same clock as
  `mach_absolute_time()` and Python's `time.monotonic_ns()` with no offset. File timestamps are
  useless for this: `hs.fs` truncates all four to whole seconds.
- `phase=lost` is emitted by a deadline timer, so a failure is a **positive record** rather than
  an absence. The closed vocabulary is `armed · start · stop · created · detected · settling ·
  capture-complete · copied · thumb-shown · thumb-visible · dismissed · renamed · gone ·
  stranded · clobbered · lost · warn · error`.
- The file rotates at 1 MB **on write** (not at load), and the handle is kept open.

`hs -c 'return hs.inspect(hsc())'` prints every module's live stats.

## The bench

```bash
bash scripts/screenshot-bench.sh --quick 10     # smoke run
bash scripts/screenshot-bench.sh 300            # acceptance run + its document
```

It points `~/.hammerspoon/init.lua` at this checkout for the duration and restores it on any
exit path, recording both steps in the log. It refuses to start unless the machine has been idle
for 180 s, aborts before the next capture on any pointer movement, snapshots and restores the
general pasteboard (refusing a multi-item board outright), and deletes each file only after its
verdict — by moving it out of the watched directory first, because a create and an unlink inside
one poll tick cancel in `st_size`.

`bench/analyze.py` prints `INSUFFICIENT-N` below 209 samples: the failure this pipeline exists to
remove happens on about 1.1 % of shots, so that is the N needed for even 90 % odds of observing
one. It says so again when no ≥ 1 s Apple stall occurred at all.

**`screencapture -R` is not the keyboard path.** It reproduces the file writes byte for byte and
in sequence — the same single `CGImageDestinationCreateWithURL` call site serves both — but there
is no crosshair, drag or mouse-up, so every bench number is `capture-spawn → …`, never
`hotkey → …`. The keyboard path is proven by real use: each real shot leaves a `copied` line
naming its hidden-name lifecycle.

## Files

```
├── README.md
├── init.lua                    # LOADER: package.path bootstrap, registry, shutdownCallback
├── hsc/
│   ├── clock.lua               # monotonic vs wall clock, kept apart on purpose
│   ├── log.lua                 # logfmt, closed phase vocabulary, rotation on write
│   ├── apps.lua                # the terminal bundle-id table, shared by dock + smartpaste
│   ├── dock.lua                # ⌥+digit bindings (hs.plist.read, no spawn)
│   ├── smartpaste.lua          # ⌘V → ⌃V for images in terminals
│   └── screenshot/
│       ├── init.lua            # orchestration, dedup by inode, arm/start/stop/stats
│       ├── watcher.lua         # 10 ms poll on st_size, reconcile loop, 1 Hz backstop
│       ├── settle.lua          # IEND through an open handle
│       ├── clipboard.lua       # verified PNG-only write, clobber watch
│       └── thumbnail.lua       # canvas at its final position, isOccluded() oracle
├── bench/
│   ├── run.py                  # the acceptance driver
│   ├── winprobe.swift          # window/pointer/idle/pasteboard helper (a falsifier, not a clock)
│   └── analyze.py              # percentiles, verdict, INSUFFICIENT-N
├── docs/
│   ├── TROUBLESHOOTING.md
│   ├── plans/SCREENSHOT_PIPELINE_100P.md
│   └── research/screenshot-pipeline-2026-09-10.md
└── scripts/
    ├── install.sh              # Setup: symlink, macOS defaults, launch
    ├── uninstall.sh            # Teardown: remove symlink, restore defaults
    └── screenshot-bench.sh     # the one command that proves the pipeline
```

## Key Implementation Details

- **No feature globals, and no reload guard.** The 14 lines of `if screenshotPollTimer then …`
  that used to open `init.lua` were dead code: `hs.reload()` builds a fresh Lua environment, so
  every global they tested was already nil. A table reachable from `package.loaded` anchors a
  timer against garbage collection exactly as well as a global does (measured: 50 ticks vs 0 for
  an unanchored local), so every module holds its own state at module scope and
  `hs.shutdownCallback` stops them in reverse order.
- **Every `require` and every `start()` under its own `pcall`, screenshot first.** On 2026-09-10
  at 12:03:36 a second instance's config aborted at line 5 — `hs.ipc.cliInstall()` — and took
  every later feature down with it, in silence. `hs.ipc` is now required *last*, after the modules
  are running, and only under `pcall`: a failure means another instance owns the port, which is
  worth recording but must not kill a pipeline that does not need IPC.
- **The poll timer is created with `continueOnError`.** `hs.timer` otherwise stops on the first
  Lua error in its callback, turning a transient fault into permanent silent loss of detection.
- **Dedup is by inode, recorded on the *verified copy* and never at detection.** Recording it at
  detection would make the final name look like a duplicate of the hidden one and silently drop
  the shot. The `seen` name table is a *mirror* of the listing rather than an add-only
  accumulator, so a screenshot restored from the Trash is reconsidered instead of burned forever.
- **Bounded retroactivity: 15 s at arm.** Screenshots older than that are remembered and never
  copied — overwriting what the user has since copied would be worse — but a shot taken during
  Hammerspoon's own 1–2 s start is still picked up, unless the log already shows it copied.
- **IEND only, never size-stability.** ImageIO writes the streaming temp in 16 KB chunks and the
  size plateaus between them, so "stable for 150 ms" is a corruption path. A complete PNG ends
  with the IEND chunk and nothing else is evidence. The check reads eight bytes, not the file.
- **Nothing synchronous on a timer callback.** No `hs.execute`, `os.execute`, `io.popen` or
  `hs.osascript` anywhere — `hs.execute` is `io.popen` + `read('*a')` + `close()`, a fork/exec/
  waitpid with no timeout at all, median 43 ms and worst case unbounded. `hs.task` only.
- **The lazy modules are warmed at load.** `hs.mouse`, `hs.screen`, `hs.sound` and `hs.canvas`
  are otherwise first touched inside the settle path, so the first screenshot after every launch
  paid 20–40 ms of module loading on the user's latency path.
- **A stall is never made up.** A 351 ms block across a repeating timer produced seven missed
  fires collapsed into one — CFRunLoopTimer coalesces and does not catch up. Detection latency
  inside a stall of duration *D* is `D + one scan`; nothing is lost, which is why the bench's
  stall test asserts on latency rather than on loss.
- **U+202F in filenames** — macOS Sequoia uses NARROW NO-BREAK SPACE between the time and AM/PM.
  Nothing here matches on names any more (a candidate is a PNG created inside a 30 s window), so
  this is now a fact about the archive rather than a constraint on the code.
- **`writeAllData` not `writeDataForUTI`** — the latter replaces the entire pasteboard instead of
  adding a UTI.

## Prerequisites

- [Hammerspoon](https://www.hammerspoon.org/) (installed via `brew install --cask hammerspoon`)
- Accessibility permission (System Settings > Privacy & Security > Accessibility)
- `~/Screenshots` directory (created by install script)
