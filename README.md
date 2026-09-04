# NotchIsland

A Dynamic Island for the Mac notch, showing the live state of Claude Code and Codex CLI
sessions. Hover to expand, click a session to jump to the Terminal tab that owns it.

![compact and expanded states](docs/island.png)

## What it shows

Each Claude Code session — interactive **and** background jobs, as peers — and each Codex
CLI session gets a pill. State is the only thing colour encodes; CLI identity is a glyph
(`✳` Claude, `◇` Codex).

| State | Colour | Meaning |
|---|---|---|
| `NEEDS YOU` | amber | blocked on a permission prompt or a question — *you* are the bottleneck |
| `DONE` | green | finished since you last looked |
| `WORKING` | blue | agent is running a turn |
| `IDLE` | grey | alive, waiting |
| `EXITED` | dim | gone; drops into **Recent** after a few seconds |

The left flank carries the single most urgent session; the right flank carries state dots
for the rest (`+N` past four). The expanded panel adds project, live action text, elapsed
time, token count, and any running subagents.

## Requirements

- A Mac with a notch (the geometry is derived from `NSScreen.auxiliaryTop*Area`; on a
  machine without one the island simply never appears)
- macOS 14+, Swift 6
- Terminal.app — the click-to-focus path uses its AppleScript `tty of tab`

## Install

```sh
./package.sh                     # builds build/NotchIsland.app
./scripts/install-hooks.sh       # wires both CLIs into the app (backs up what it touches)
./scripts/install-launchagent.sh # optional: start at login
open build/NotchIsland.app
```

Two one-time permission prompts appear on first use: **Automation** (to focus a Terminal
tab) the first time you click a session.

## How it gets its data

**Claude Code** publishes a genuinely rich feed, and it is the primary source:

- `~/.claude/sessions/<pid>.json` — identity, `kind`, `status`
- `~/.claude/jobs/<jobId>/state.json` — `detail`, `fan[]`, `tokens`

Both are watched with FSEvents, so the app costs nothing while nothing is happening, and
it picks up sessions that were already running before it launched.

**Codex** publishes nothing comparable — its rollout logs are write-only with no status
field and no index. So Codex support is deliberately coarse: process presence for
existence, rollout file mtime for activity, and its `notify` hook for completion. Codex
sessions carry no detail line. Parsing the rollout JSONL for one would work but the format
is undocumented and would break on the next release.

**Push hooks** cover what files cannot. A `Notification` hook is what makes `NEEDS YOU`
possible at all: in the session file, "waiting for your permission" and "finished" both
read as `idle`. Both hook scripts write one line of JSON to a Unix socket at
`~/Library/Application Support/NotchIsland/push.sock`.

### The ntfy scripts are safe

`install-hooks.sh` replaces `~/.local/bin/{claude,codex}-ntfy-notify.py` (backing up the
originals). The ntfy.sh POST is unchanged and runs **first**; the socket write happens
after it, non-blocking, wrapped in its own bare `except`. A dead app, a stale socket, or a
bug in the emit can never cost you a phone notification. Verify any time with:

```sh
pkill -f NotchIsland
rm -f ~/Library/Application\ Support/NotchIsland/push.sock
echo '{"hook_event_name":"Stop"}' | python3 ~/.local/bin/claude-ntfy-notify.py; echo $?
```

## Design notes

- **Nothing is drawn inside the cutout.** It is a physical hole with no pixels. The island
  is two flanks in the menu bar plus a panel that drops below.
- **108 pt flanks.** OCR A is monospaced and wide; at 80 pt the session name clipped to
  `OBS…`. 108 pt fits ~10 characters and still leaves ~680 pt of menu bar free on each
  side — and menus grow from the left edge while status items grow from the right, so the
  strip beside the notch is the last real estate either claims.
- **OCR A for structure, SF Mono for prose.** Names, states, counts and timings are OCR A.
  The `detail` line is a sentence written for a human and is unreadable in OCR A at 10 pt.
- **The pulse runs on CoreAnimation, not SwiftUI.** A `repeatForever` SwiftUI animation
  cost ~6% CPU continuously whenever a session was working. A `CABasicAnimation` on the
  layer runs on the render server: idle cost is now 0.0–0.5%.
- **Read-only.** No interrupt or kill controls. This surface sits under the cursor's path
  to the menu bar and a misclick would cost an agent run.
- **Built-in display only.** No synthetic notch on external monitors — a notch-shaped
  black blob on a screen with no notch reads as a bug, not a feature.

## Known limits

- **Unverified:** whether Claude reports `busy` or `idle` while a permission prompt is on
  screen. `NEEDS YOU` is therefore cleared only on positive evidence that the session moved
  on (a `Stop` push, a changed action, or a not-working → working transition), with a
  15-minute safety expiry. If the state ever looks sticky, that is the code to revisit —
  `SessionStore.isUnblocked`.
- With several Codex processes at once, rollout activity is credited to the most recently
  started one; there is no way to attribute a rollout file to a specific process.
- Debug: `NOTCHISLAND_DEBUG_EXPANDED=1` pins the panel open.
