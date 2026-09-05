#!/bin/bash
# Wires Claude Code and Codex CLI into StratIsland. Idempotent, and backs up everything it
# touches before changing it.
#
#   1. installs scripts/stratisland-notify.py into ~/.local/bin
#   2. adds a `Notification` hook to ~/.claude/settings.json
#   3. sets `notify` in ~/.codex/config.toml
#   4. checks the socket end to end and reports what actually arrived
#
# The Notification hook is what makes the `NEEDS YOU` state possible at all: in the session
# status file, "waiting for your permission" and "finished" both read as idle. Codex allows
# exactly one `notify` program, and it is the only completion signal Codex publishes, so an
# existing entry is never overwritten without --force.
set -euo pipefail
cd "$(dirname "$0")"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

STAMP="$(date +%Y%m%d-%H%M%S)"
BIN="$HOME/.local/bin"
SCRIPT="$BIN/stratisland-notify.py"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_CONFIG="$HOME/.codex/config.toml"

mkdir -p "$BIN"

# 1. the notify script
if [ -f "$SCRIPT" ]; then
  cp "$SCRIPT" "$SCRIPT.bak-$STAMP"
  echo "backed up $SCRIPT -> stratisland-notify.py.bak-$STAMP"
fi
cp stratisland-notify.py "$SCRIPT"
chmod +x "$SCRIPT"
echo "installed $SCRIPT"

# 2. Claude: the Notification hook
if [ -f "$CLAUDE_SETTINGS" ]; then
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak-$STAMP"
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as fh:
    cfg = json.load(fh)

command = "python3 ~/.local/bin/stratisland-notify.py"
hooks = cfg.setdefault("hooks", {})
changed = False

# Stop is what clears a blocked session; Notification is what sets one.
for event in ("Notification", "Stop"):
    entries = hooks.setdefault(event, [])
    present = any(
        h.get("command") == command
        for entry in entries
        for h in entry.get("hooks", [])
    )
    if present:
        print(f"{event} hook already present")
        continue
    entries.append({"hooks": [{"type": "command", "command": command, "timeout": 15}]})
    print(f"added {event} hook")
    changed = True

if changed:
    with open(path, "w") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
PY
  echo "backed up $CLAUDE_SETTINGS -> settings.json.bak-$STAMP"
else
  echo "WARNING: $CLAUDE_SETTINGS not found; skipped the Claude hooks"
fi

# 3. Codex: the single notify program
NOTIFY_LINE='notify = ["python3", "~/.local/bin/stratisland-notify.py"]'
if [ -f "$CODEX_CONFIG" ]; then
  EXISTING="$(grep -n '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG" || true)"
  if [ -z "$EXISTING" ]; then
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak-$STAMP"
    printf '%s\n' "$NOTIFY_LINE" >> "$CODEX_CONFIG"
    echo "added notify to $CODEX_CONFIG (backed up)"
  elif printf '%s' "$EXISTING" | grep -q "stratisland-notify.py"; then
    echo "notify already points at stratisland-notify.py"
  elif [ "$FORCE" = "1" ]; then
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak-$STAMP"
    python3 - "$CODEX_CONFIG" "$NOTIFY_LINE" <<'PY'
import re, sys

path, line = sys.argv[1], sys.argv[2]
with open(path) as fh:
    text = fh.read()
text = re.sub(r'(?m)^[ \t]*notify[ \t]*=.*$', line, text, count=1)
with open(path, 'w') as fh:
    fh.write(text)
PY
    echo "replaced notify in $CODEX_CONFIG (backed up)"
  else
    echo "WARNING: $CODEX_CONFIG already sets notify:"
    printf '  %s\n' "$EXISTING"
    echo "  Codex allows only one notify program. Re-run with --force to replace it,"
    echo "  or call stratisland-notify.py from your own program. Codex completion will"
    echo "  not reach StratIsland until one of those is done."
  fi
else
  echo "WARNING: $CODEX_CONFIG not found; skipped the Codex notify program"
fi

# 4. prove it works, rather than assuming
echo
if python3 "$SCRIPT" --self-test; then
  echo "Done. Restart any running session for the new hooks to take effect."
else
  echo "Done, but StratIsland did not answer on its socket. Start the app and re-run:"
  echo "  python3 $SCRIPT --self-test"
fi
