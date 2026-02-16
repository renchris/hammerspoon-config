# hammerspoon-config

Hammerspoon configuration for macOS Sequoia. Three features in one `init.lua`:

1. **Dock app shortcuts** — Alt+1-9 launches/focuses pinned Dock apps (auto-updates
   when Dock changes, disables in terminals for tmux Alt+N)
2. **Smart paste** — Cmd+V in terminal apps sends Ctrl+V when clipboard has an image
   (for Claude Code image paste)
3. **Screenshot to clipboard** — Cmd+Shift+3/4 saves file + copies to clipboard +
   shows floating thumbnail + plays Pop sound

## Quick Start

```bash
# One-line install (symlinks init.lua, configures macOS screenshot settings)
~/Development/hammerspoon-config/scripts/install.sh
```

## Screenshot Feature

macOS Sequoia intercepts Cmd+Shift+3/4 at the WindowServer level before any userspace
app. Hammerspoon cannot override these shortcuts via hotkey binding or event taps.

**Architecture**: Native macOS handles the capture. `show-thumbnail` is disabled so
files write to disk instantly. A `hs.pathwatcher` on `~/Screenshots` detects new PNGs
and copies to clipboard + shows a custom floating thumbnail.

| Step | Handler | Latency |
|------|---------|---------|
| 1. Crosshair / capture | macOS native | 0ms (system) |
| 2. File written to ~/Screenshots | macOS native | ~50ms |
| 3. Pathwatcher fires | Hammerspoon FSEvents | ~100ms |
| 4. Clipboard + thumbnail + sound | Hammerspoon | ~150ms |

### Clipboard Format

Both UTIs are written atomically via `hs.pasteboard.writeAllData`:

- `public.tiff` — recognized by native apps (Messages, Notes, Preview)
- `public.png` — recognized by web file inputs and browsers

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
| Alt+Cmd+R | Refresh bindings manually |

Auto-disables in terminal apps (iTerm2, Kitty, Terminal, WezTerm) so tmux Alt+N
window switching works.

## Files

```
├── README.md
├── init.lua              # Hammerspoon config (symlinked to ~/.hammerspoon/)
└── scripts/
    └── install.sh        # Setup: symlink, macOS defaults, launch
```

## Key Implementation Details

- **Pathwatcher must be global** — `local` variables at init.lua top-level get garbage
  collected by Lua's GC, silently destroying the watcher. Canvas and timer variables
  that persist beyond their creating function must also be global.
- **U+202F in filenames** — macOS Sequoia uses NARROW NO-BREAK SPACE (U+202F) between
  the time and AM/PM in screenshot filenames. Lua's `.+` pattern handles this correctly.
- **`writeAllData` not `writeDataForUTI`** — the latter replaces the entire pasteboard
  instead of adding a UTI. Use `writeAllData` to write multiple UTIs atomically.

## Prerequisites

- [Hammerspoon](https://www.hammerspoon.org/) (installed via `brew install --cask hammerspoon`)
- Accessibility permission (System Settings > Privacy & Security > Accessibility)
- `~/Screenshots` directory (created by install script)
