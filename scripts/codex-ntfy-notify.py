#!/usr/bin/env python3
"""Codex CLI notify program: ntfy.sh push (unchanged) + StratIsland socket emit.

Codex allows exactly one `notify` program, and it is the only completion signal Codex
publishes at all — its rollout logs carry no status. Same isolation rule as the Claude
script: the socket write happens last and can never affect the ntfy POST.
"""
import json
import os
import socket
import sys
from urllib.parse import quote
from urllib.request import Request, urlopen

ISLAND_SOCKET = os.path.expanduser(
    "~/Library/Application Support/StratIsland/push.sock"
)


def emit_to_island(payload):
    """Best-effort, never raises, never blocks for long."""
    try:
        if payload.get("type") != "agent-turn-complete":
            return
        msg = json.dumps(
            {
                "cli": "codex",
                "event": "stop",
                "session_id": payload.get("conversation-id")
                or payload.get("conversation_id"),
                "cwd": payload.get("cwd"),
            }
        ) + "\n"
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.15)
        s.connect(ISLAND_SOCKET)
        s.sendall(msg.encode())
        s.close()
    except Exception:
        pass


payload = {}
try:
    payload = json.loads(sys.argv[1])
    topic = os.environ.get("NTFY_TOPIC")

    if topic and payload.get("type") == "agent-turn-complete":
        body = f"Host: {socket.gethostname()}"

        request = Request(
            f"https://ntfy.sh/{quote(topic, safe='')}",
            data=body.encode(),
            method="POST",
            headers={
                "Title": "Codex",
                "Priority": "default",
                "Tags": "white_check_mark",
            },
        )

        with urlopen(request, timeout=15):
            pass
except Exception as error:
    print(f"ntfy notification failed: {error}", file=sys.stderr)

emit_to_island(payload)
