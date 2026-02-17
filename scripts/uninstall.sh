#!/usr/bin/env bash
set -euo pipefail

HS_DIR="$HOME/.hammerspoon"

echo "=== Hammerspoon Config Uninstall ==="
echo ""

# 1. Remove symlink
echo "[1/4] Removing init.lua symlink..."
if [ -L "$HS_DIR/init.lua" ]; then
    rm "$HS_DIR/init.lua"
    echo "  Symlink removed."

    # Restore backup if one exists
    LATEST_BACKUP="$(ls -t "$HS_DIR"/init.lua.backup.* 2>/dev/null | head -1 || true)"
    if [ -n "$LATEST_BACKUP" ]; then
        if cp "$LATEST_BACKUP" "$HS_DIR/init.lua"; then
            echo "  Restored backup: $(basename "$LATEST_BACKUP")"
        else
            echo "  WARNING: Failed to restore backup. Restore manually:"
            echo "    cp $LATEST_BACKUP $HS_DIR/init.lua"
        fi
    fi
elif [ -f "$HS_DIR/init.lua" ]; then
    echo "  init.lua exists but is a regular file (not our symlink) — leaving it alone."
else
    echo "  No init.lua found — skipping."
fi

# 2. Re-enable native screenshot thumbnail
echo "[2/4] Re-enabling native screenshot thumbnail..."
defaults write com.apple.screencapture show-thumbnail -bool true
echo "  Native thumbnail enabled."

# 3. Reset screenshot location to default (Desktop)
echo "[3/4] Resetting screenshot location to default..."
defaults delete com.apple.screencapture location 2>/dev/null || true
echo "  Screenshot location reset to Desktop."

# 4. Stop Hammerspoon
echo "[4/4] Stopping Hammerspoon..."
if pgrep -q Hammerspoon; then
    osascript -e 'tell application "Hammerspoon" to quit' 2>/dev/null
    sleep 2
    if pgrep -q Hammerspoon; then
        echo "  Hammerspoon didn't quit gracefully. Force-killing..."
        pkill Hammerspoon 2>/dev/null || true
        sleep 1
    fi
    if pgrep -q Hammerspoon; then
        echo "  WARNING: Hammerspoon still running. Kill manually: kill $(pgrep -d ' ' Hammerspoon)"
    else
        echo "  Hammerspoon stopped."
    fi
else
    echo "  Hammerspoon not running."
fi

echo ""
echo "=== Uninstall complete ==="
echo "Hammerspoon is still installed. To remove it entirely:"
echo "  brew uninstall --cask hammerspoon"
