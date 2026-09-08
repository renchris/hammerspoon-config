# hammerspoon-config

Hammerspoon configuration for macOS Sequoia. Three features in one `init.lua`:

1. **Dock app shortcuts** — Alt+1-9,0 launches/focuses pinned Dock apps (auto-updates
   when Dock changes, disables in terminals for tmux Alt+N)
2. **Smart paste** — Cmd+V in terminal apps sends Ctrl+V when clipboard has an image
   (for Claude Code image paste)
3. **Screenshot to clipboard** — Cmd+Shift+3/4 saves file + copies to clipboard +
   shows floating thumbnail + plays Pop sound

## Quick Start

```bash
git clone <repo-url>
cd hammerspoon-config
./scripts/install.sh
```

## Screenshot Feature

macOS Sequoia intercepts Cmd+Shift+3/4 at the WindowServer level before any userspace
app. Hammerspoon cannot override these shortcuts via hotkey binding or event taps.

**Architecture**: Native macOS handles the capture. `show-thumbnail` is disabled so
files write to disk instantly. Hammerspoon **polls** `~/Screenshots` — one `stat()` of the
directory every 50 ms (27 µs each), and a listing only when the directory's
mtime/ctime/size signature changes — then copies the new PNG to the clipboard and shows a
custom floating thumbnail on the display under the mouse pointer.

| Step | Handler | Latency |
|------|---------|---------|
| 1. Crosshair / capture | macOS native | 0ms (system) |
| 2. File written to ~/Screenshots | macOS native | ~50ms (renamed into place, complete) |
| 3. Poll notices the new entry | Hammerspoon `stat` every 50 ms | ≤ 50 ms + ~8 ms listing |
| 4. Clipboard + thumbnail + sound | Hammerspoon | ~35 ms |

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

### Clipboard Format

Written via `hs.pasteboard.writeAllData` for maximum compatibility:

- `public.png` — always written (web file inputs, browsers)
- `public.tiff` — written if conversion succeeds (native apps: Messages, Notes, Preview)

### Floating Thumbnail

- Slides in from the bottom-right with cubic ease-out (250ms)
- Auto-dismisses after 3 seconds with fade-out (300ms)
- Click to open in Preview
- Rapid screenshots: new thumbnail replaces previous cleanly

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

## Files

```
├── README.md
├── init.lua              # Hammerspoon config (symlinked to ~/.hammerspoon/)
├── .gitignore
├── docs/
│   └── TROUBLESHOOTING.md
└── scripts/
    ├── install.sh        # Setup: symlink, macOS defaults, launch
    └── uninstall.sh      # Teardown: remove symlink, restore defaults
```

## Key Implementation Details

- **Poll timer must be global, and created with `continueOnError`** — `local` variables at
  init.lua top-level get garbage collected by Lua's GC, silently destroying the timer. Canvas
  and timer variables that persist beyond their creating function must also be global.
  `hs.timer.doEvery` stops the timer on the first Lua error in its callback, which would
  turn a transient fault into permanent silent loss of detection — use
  `hs.timer.new(interval, fn, true)` so errors are logged and the poll goes on.
- **Same-second renames** — `hs.fs` timestamps are whole seconds and a rename moves no
  directory entry, so a temp file created and renamed within the same second as the previous
  change leaves the directory's mtime/ctime/size unchanged. While the directory's mtime is
  still the current second the poll keeps listing every other tick (≤ ~10 listings), so
  nothing can slip through the 1 s resolution.
- **Dedup is by name** — every entry is handled once, the first time it is seen. There is no
  event stream, so there is no metadata-only re-delivery to defend against (Preview's
  quarantine xattr on click used to re-trigger the FSEvents path).
- **Not retroactive** — screenshots already present when the config loads are remembered,
  never copied: silently overwriting whatever the user has since copied would be worse.
- **U+202F in filenames** — macOS Sequoia uses NARROW NO-BREAK SPACE (U+202F) between
  the time and AM/PM in screenshot filenames. Lua's `.+` pattern handles this correctly.
- **`writeAllData` not `writeDataForUTI`** — the latter replaces the entire pasteboard
  instead of adding a UTI. Use `writeAllData` to write multiple UTIs atomically.

## Prerequisites

- [Hammerspoon](https://www.hammerspoon.org/) (installed via `brew install --cask hammerspoon`)
- Accessibility permission (System Settings > Privacy & Security > Accessibility)
- `~/Screenshots` directory (created by install script)
