#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HS_DIR="$HOME/.hammerspoon"

echo "=== Hammerspoon Config Install ==="

# 1. Check Hammerspoon is installed
if ! [ -d "/Applications/Hammerspoon.app" ] && ! brew list --cask hammerspoon &>/dev/null; then
    echo "Hammerspoon not found. Installing via Homebrew..."
    brew install --cask hammerspoon
fi

# 2. Ensure ~/.hammerspoon exists
mkdir -p "$HS_DIR"

# 3. Back up existing init.lua
if [ -f "$HS_DIR/init.lua" ]; then
    BACKUP="$HS_DIR/init.lua.backup.$(date +%Y%m%d%H%M%S)"
    cp "$HS_DIR/init.lua" "$BACKUP"
    echo "Backed up existing init.lua to $BACKUP"
fi

# 4. Symlink init.lua (edits in either location stay in sync)
ln -sf "$REPO_DIR/init.lua" "$HS_DIR/init.lua"
echo "Symlinked $HS_DIR/init.lua -> $REPO_DIR/init.lua"

# 5. Ensure ~/Screenshots directory exists
mkdir -p "$HOME/Screenshots"

# 6. Set macOS screenshot location to ~/Screenshots
defaults write com.apple.screencapture location "$HOME/Screenshots"
echo "Screenshot location: ~/Screenshots"

# 7. Disable native thumbnail (files save instantly for pathwatcher)
defaults write com.apple.screencapture show-thumbnail -bool false
echo "Native thumbnail disabled (Hammerspoon provides custom thumbnail)"

# 8. Grant Accessibility permission reminder
echo ""
echo "IMPORTANT: Hammerspoon needs Accessibility permission."
echo "  System Settings > Privacy & Security > Accessibility > Hammerspoon (enable)"
echo ""

# 9. Reload or launch Hammerspoon
if pgrep -q Hammerspoon; then
    echo "Restarting Hammerspoon..."
    osascript -e 'tell application "Hammerspoon" to quit' 2>/dev/null
    sleep 2
fi
open -a Hammerspoon
sleep 3
echo "Hammerspoon launched."

echo ""
echo "=== Install complete ==="
echo "Features:"
echo "  - Alt+1-9: Launch pinned Dock apps"
echo "  - Cmd+V in terminals: Auto Ctrl+V for image paste (Claude Code)"
echo "  - Cmd+Shift+3/4: Screenshot -> file + clipboard + floating thumbnail"
echo "  - Alt+Cmd+R: Refresh Dock app bindings"
