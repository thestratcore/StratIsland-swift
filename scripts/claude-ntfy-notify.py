#!/usr/bin/env python3
"""Claude Code hook: ntfy.sh push (unchanged behaviour) + StratIsland socket emit.

The ntfy POST runs first and is completely unaffected by the socket write below: the emit
is wrapped in its own bare except with a short non-blocking timeout, so a dead app, a
stale socket file, or a bug here can never cost you a phone notification.
"""
import json
import os
import socket
import ssl
import sys
from urllib.parse import quote
from urllib.request import Request, urlopen

try:
    import certifi

    _SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL_CONTEXT = None

ISLAND_SOCKET = os.path.expanduser(
    "~/Library/Application Support/StratIsland/push.sock"
)


def emit_to_island(payload):
    """Best-effort, never raises, never blocks for long."""
    try:
        event = {"Stop": "stop", "Notification": "notification"}.get(
            payload.get("hook_event_name")
        )
        if not event:
            return
        msg = json.dumps(
            {
                "cli": "claude",
                "event": event,
                "session_id": payload.get("session_id"),
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
    payload = json.load(sys.stdin)
    topic = os.environ.get("NTFY_TOPIC")

    if topic and payload.get("hook_event_name") == "Stop":
        body = f"Host: {socket.gethostname()}"

        request = Request(
            f"https://ntfy.sh/{quote(topic, safe='')}",
            data=body.encode(),
            method="POST",
            headers={
                "Title": "Claude",
                "Priority": "default",
                "Tags": "white_check_mark",
            },
        )

        with urlopen(request, timeout=15, context=_SSL_CONTEXT):
            pass
except Exception as error:
    print(f"ntfy notification failed: {error}", file=sys.stderr)

emit_to_island(payload)
