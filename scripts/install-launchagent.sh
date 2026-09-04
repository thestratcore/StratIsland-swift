#!/bin/bash
# Starts NotchIsland at login. Run ./package.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(pwd)/build/NotchIsland.app"
[ -d "$APP" ] || { echo "build/NotchIsland.app missing — run ./package.sh first"; exit 1; }

PLIST="$HOME/Library/LaunchAgents/com.stratcore.notchisland.plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP_PATH__|$APP|g" scripts/com.stratcore.notchisland.plist > "$PLIST"

launchctl bootout "gui/$(id -u)/com.stratcore.notchisland" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "loaded $PLIST"
echo "stderr goes to /tmp/notchisland.err.log"
