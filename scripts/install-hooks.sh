#!/bin/bash
# Wires the two CLIs into NotchIsland. Idempotent, and backs up everything it touches.
#
#   1. installs the patched notify scripts into ~/.local/bin (originals backed up)
#   2. adds a `Notification` hook to ~/.claude/settings.json (the Stop hook is left alone)
#
# The Notification hook is what makes the `needsInput` state possible at all: in the
# session status file, "waiting for your permission" and "finished" both read as idle.
set -euo pipefail
cd "$(dirname "$0")"

STAMP="$(date +%Y%m%d-%H%M%S)"
BIN="$HOME/.local/bin"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$BIN"

for f in claude-ntfy-notify.py codex-ntfy-notify.py; do
  if [ -f "$BIN/$f" ]; then
    cp "$BIN/$f" "$BIN/$f.bak-$STAMP"
    echo "backed up $BIN/$f -> $f.bak-$STAMP"
  fi
  cp "$f" "$BIN/$f"
  chmod +x "$BIN/$f"
  echo "installed $BIN/$f"
done

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-$STAMP"
  echo "backed up $SETTINGS -> settings.json.bak-$STAMP"
  python3 - "$SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as fh:
    cfg = json.load(fh)

hooks = cfg.setdefault("hooks", {})
entries = hooks.setdefault("Notification", [])
command = "python3 ~/.local/bin/claude-ntfy-notify.py"

already = any(
    h.get("command") == command
    for entry in entries
    for h in entry.get("hooks", [])
)
if already:
    print("Notification hook already present — nothing to do")
else:
    entries.append({"hooks": [{"type": "command", "command": command, "timeout": 15}]})
    with open(path, "w") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
    print("added Notification hook to settings.json")
PY
else
  echo "WARNING: $SETTINGS not found; skipped the Notification hook"
fi

echo
echo "Done. Restart any running Claude session for the new hook to take effect."
