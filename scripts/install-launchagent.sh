#!/bin/bash
# Starts StratIsland at login. Run ./package.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(pwd)/build/StratIsland.app"
[ -d "$APP" ] || { echo "build/StratIsland.app missing — run ./package.sh first"; exit 1; }

PLIST="$HOME/Library/LaunchAgents/com.stratcore.stratisland.plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP_PATH__|$APP|g" scripts/com.stratcore.stratisland.plist > "$PLIST"

launchctl bootout "gui/$(id -u)/com.stratcore.stratisland" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "loaded $PLIST"
echo "stderr goes to /tmp/stratisland.err.log"
