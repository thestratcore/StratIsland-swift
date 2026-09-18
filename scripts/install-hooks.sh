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
NOTIFY_LINE="notify = [\"python3\", \"$SCRIPT\"]"
if [ -f "$CODEX_CONFIG" ]; then
  cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak-$STAMP"
  if ! python3 - "$CODEX_CONFIG" "$SCRIPT" "$FORCE" <<'PY'
import json, os, re, sys, tempfile, tomllib
path, script, force = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(path, "rb") as fh:
    raw = fh.read()
try:
    parsed = tomllib.loads(raw.decode())
except Exception as exc:
    print(f"ERROR: invalid TOML; refusing to edit: {exc}")
    raise SystemExit(1)
text = raw.decode()
lines = text.splitlines(keepends=True)
root_end = next((i for i, line in enumerate(lines) if re.match(r"^\s*\[", line)), len(lines))
root = "".join(lines[:root_end])
matches = list(re.finditer(r"(?m)^[ \t]*notify[ \t]*=.*(?:\n|$)", root))
line = f'notify = ["python3", {json.dumps(script)}]\n'
if matches:
    existing = matches[0].group(0)
    if "stratisland-notify.py" in existing:
        print("notify already points at stratisland-notify.py")
        raise SystemExit(0)
    if not force:
        print("WARNING: root notify already exists; use --force to replace it")
        raise SystemExit(1)
    root = root[:matches[0].start()] + line + root[matches[0].end():]
else:
    root = line + root
candidate = root + "".join(lines[root_end:])
try:
    validated = tomllib.loads(candidate)
except Exception as exc:
    print(f"ERROR: generated TOML is invalid: {exc}")
    raise SystemExit(1)
if validated.get("notify") != ["python3", script]:
    print("ERROR: notify was not written at the TOML root")
    raise SystemExit(1)
mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(prefix=".stratisland-", dir=os.path.dirname(path) or ".")
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w") as fh: fh.write(candidate)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print("updated root notify (backed up by caller)")
PY
  then
    cp "$CODEX_CONFIG.bak-$STAMP" "$CODEX_CONFIG"
    if [ "$FORCE" = "1" ]; then exit 1; fi
    echo "Codex notify was not changed."
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
