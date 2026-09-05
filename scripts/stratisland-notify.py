#!/usr/bin/env python3
"""Reports a CLI event to StratIsland over its Unix socket.

One script serves both CLIs because they deliver an event differently and neither one
carries anything StratIsland needs to interpret:

  Claude Code  hook       JSON on stdin, with `hook_event_name`
  Codex CLI    notify     JSON as argv[1], with `type`

The `Notification` event is the point of the whole thing. In `~/.claude/sessions/<pid>.json`
a session waiting for your permission and a session that has finished both read as `idle`,
so "you are the bottleneck" cannot be derived from files at all. For Codex, `notify` is the
only completion signal it publishes.

Failure is always silent and always fast. A hook that blocks delays the CLI it is attached
to, and a hook that raises writes noise into someone's terminal, so a dead app, a stale
socket, or a malformed payload all end the same way: exit 0, having done nothing.

Install with scripts/install-hooks.sh; run with --self-test to check the socket by hand.
"""
import json
import os
import socket
import sys

SOCKET = os.path.expanduser("~/Library/Application Support/StratIsland/push.sock")
TIMEOUT = 0.15


def send(event):
    """Best effort. Never raises, never blocks for long."""
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(TIMEOUT)
        connection.connect(SOCKET)
        connection.sendall((json.dumps(event) + "\n").encode())
        connection.close()
        return True
    except Exception:
        return False


def claude_event(payload):
    event = {"Stop": "stop", "Notification": "notification"}.get(
        payload.get("hook_event_name")
    )
    if not event:
        return None
    return {
        "cli": "claude",
        "event": event,
        "session_id": payload.get("session_id"),
        "cwd": payload.get("cwd"),
    }


def codex_event(payload):
    if payload.get("type") != "agent-turn-complete":
        return None
    return {
        "cli": "codex",
        "event": "stop",
        # Codex has spelled this both ways across versions.
        "session_id": payload.get("conversation-id") or payload.get("conversation_id"),
        "cwd": payload.get("cwd"),
    }


def main(argv):
    if "--self-test" in argv:
        ok = send({"cli": "claude", "event": "stop", "session_id": None, "cwd": os.getcwd()})
        print(f"socket {SOCKET}: {'reachable' if ok else 'NOT reachable'}")
        return 0 if ok else 1

    try:
        if len(argv) > 1:
            # Codex passes its payload as an argument.
            event = codex_event(json.loads(argv[1]))
        else:
            event = claude_event(json.load(sys.stdin))
    except Exception:
        return 0

    if event:
        send(event)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
