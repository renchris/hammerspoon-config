#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew is required. Install from https://brew.sh"
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HS_DIR="$HOME/.hammerspoon"

echo "=== Hammerspoon Config Install ==="
echo ""

# 1. Check Hammerspoon is installed
echo "[1/7] Checking Hammerspoon..."
if ! [ -d "/Applications/Hammerspoon.app" ] && ! brew list --cask hammerspoon &>/dev/null; then
    echo "  Hammerspoon not found. Installing via Homebrew..."
    brew install --cask hammerspoon
else
    echo "  Hammerspoon found."
fi

# 2. Ensure ~/.hammerspoon exists
echo "[2/7] Ensuring ~/.hammerspoon directory..."
mkdir -p "$HS_DIR"
echo "  Ready."

# 3. Symlink init.lua (skip backup if already pointing to repo)
echo "[3/7] Symlinking init.lua..."
if [ -L "$HS_DIR/init.lua" ]; then
    CURRENT_TARGET="$(readlink "$HS_DIR/init.lua")"
    if [ "$CURRENT_TARGET" = "$REPO_DIR/init.lua" ]; then
        echo "  Symlink already points to repo — skipping backup."
    else
        BACKUP="$HS_DIR/init.lua.backup.$(date +%Y%m%d%H%M%S)"
        cp -P "$HS_DIR/init.lua" "$BACKUP"
        echo "  Backed up existing symlink to $BACKUP"
    fi
elif [ -f "$HS_DIR/init.lua" ]; then
    BACKUP="$HS_DIR/init.lua.backup.$(date +%Y%m%d%H%M%S)"
    cp "$HS_DIR/init.lua" "$BACKUP"
    echo "  Backed up existing init.lua to $BACKUP"
fi
ln -sf "$REPO_DIR/init.lua" "$HS_DIR/init.lua"
echo "  $HS_DIR/init.lua -> $REPO_DIR/init.lua"

# 4. Ensure ~/Screenshots directory exists
echo "[4/7] Ensuring ~/Screenshots directory..."
mkdir -p "$HOME/Screenshots"
echo "  Ready."

# 5. Set macOS screenshot location to ~/Screenshots
echo "[5/7] Configuring macOS screenshot settings..."
defaults write com.apple.screencapture location "$HOME/Screenshots"
echo "  Screenshot location: ~/Screenshots"

# 6. Disable native thumbnail (files save instantly, so the directory poll sees them at once)
echo "[6/7] Disabling native screenshot thumbnail..."
defaults write com.apple.screencapture show-thumbnail -bool false
echo "  Native thumbnail disabled (Hammerspoon provides custom thumbnail)"

# 7. Supervise Hammerspoon under launchd — the only launcher from here on. Under KeepAlive a quit
#    is a restart, so this no longer quits-then-opens: a first install hands the running instance
#    over to launchd; an already-supervised one just reloads its config in place (same process).
echo "[7/7] Supervising Hammerspoon (launchd KeepAlive)..."
WAS_SUPERVISED=0
launchctl print "gui/$(id -u)/org.hammerspoon.Hammerspoon.keepalive" >/dev/null 2>&1 && WAS_SUPERVISED=1
bash "$REPO_DIR/scripts/supervise.sh" install
if [ "$WAS_SUPERVISED" = 1 ]; then
    # Deferred so the IPC reply returns before the reload tears the port down. Bounded by hs's own
    # -t, never an external timeout: killing the client mid-reply crashes Hammerspoon (see
    # supervise.sh hs_eval).
    if hs -t 4 -c 'hs.timer.doAfter(0.1, hs.reload)' >/dev/null 2>&1; then
        echo "  Config reloaded."
    else
        echo "  WARNING: hs -c did not answer; reload from the Hammerspoon menu (Reload Config)."
    fi
fi

echo ""
echo "IMPORTANT: Hammerspoon needs Accessibility permission."
echo "  System Settings > Privacy & Security > Accessibility > Hammerspoon (enable)"
echo ""
echo "=== Install complete ==="
echo "Features:"
echo "  - Alt+1-9,0: Launch pinned Dock apps"
echo "  - Cmd+V in terminals: Auto Ctrl+V for image paste (Claude Code)"
echo "  - Cmd+Shift+3/4: Screenshot -> file + clipboard + floating thumbnail"
echo "  - Alt+Cmd+R: Refresh Dock app bindings"
