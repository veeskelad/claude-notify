#!/usr/bin/env python3
"""Notes and tasks in the Notchy notch panel, for Claude Code sessions.

    notes.py list                     the note and the tasks, numbered
    notes.py add "text" ["text" ...]  new tasks (marked as added by Claude)
    notes.py done N [N ...]           mark tasks done (numbers from `list`)
    notes.py undone N [N ...]
    notes.py remove N [N ...]
    notes.py note "text"              append a line to the note
    notes.py note --replace "text"    replace the whole note

The file is ~/Library/Application Support/Notchy/notes.json, shared with the panel. After a
change the running app is told over its socket, so the panel shows it at once. Python 3.9+,
standard library only.
"""
import fcntl
import json
import os
import socket
import sys
import tempfile
import time
import uuid
from pathlib import Path

SUPPORT = Path.home() / "Library" / "Application Support" / "Notchy"
FILE = SUPPORT / "notes.json"
LOCK = SUPPORT / ".notes.lock"
SOCKET = SUPPORT / "notchy.sock"


def load():
    try:
        data = json.loads(FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    data.setdefault("note", "")
    data.setdefault("tasks", [])
    return data


def save(data):
    SUPPORT.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=SUPPORT, prefix=".notes.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp, FILE)


def ping(added=""):
    """Tell the running app to reload; silent and quick when it isn't running."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(str(SOCKET))
        msg = {"v": 1, "type": "notes", "session": {}}
        if added:
            msg["added"] = added
        s.sendall((json.dumps(msg, ensure_ascii=False) + "\n").encode())
        s.close()
    except OSError:
        pass


def numbers(args, tasks):
    out = []
    for a in args:
        try:
            n = int(a)
        except ValueError:
            sys.exit(f"not a task number: {a}")
        if not 1 <= n <= len(tasks):
            sys.exit(f"no task {n} (there are {len(tasks)})")
        out.append(n - 1)
    return out


def show(data):
    note = data["note"].strip()
    print("Note:" if note else "Note: (empty)")
    if note:
        for line in note.splitlines():
            print("  " + line)
    tasks = data["tasks"]
    print(f"Tasks ({sum(1 for t in tasks if not t.get('done'))} open):" if tasks else "Tasks: (none)")
    for i, t in enumerate(tasks, 1):
        mark = "x" if t.get("done") else " "
        by = " (claude)" if t.get("by") == "claude" else ""
        print(f"  {i}. [{mark}] {t.get('text', '')}{by}")


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return
    cmd, args = argv[0], argv[1:]
    SUPPORT.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = load()
        if cmd == "list":
            show(data)
            return
        added = ""
        if cmd == "add":
            texts = [a.strip() for a in args if a.strip()]
            if not texts:
                sys.exit('usage: notes.py add "text"')
            now = time.time()
            for text in reversed(texts):
                data["tasks"].insert(0, {"id": str(uuid.uuid4()).upper(), "text": text, "done": False,
                                         "by": "claude", "created": now})
            added = texts[0] if len(texts) == 1 else f"{texts[0]} (+{len(texts) - 1})"
        elif cmd in ("done", "undone"):
            for i in numbers(args, data["tasks"]):
                data["tasks"][i]["done"] = cmd == "done"
        elif cmd == "remove":
            for i in sorted(numbers(args, data["tasks"]), reverse=True):
                del data["tasks"][i]
        elif cmd == "note":
            if args[:1] == ["--replace"]:
                data["note"] = " ".join(args[1:]).strip()
            else:
                line = " ".join(args).strip()
                if not line:
                    sys.exit('usage: notes.py note "text"')
                data["note"] = (data["note"].rstrip() + "\n" + line).strip() if data["note"].strip() else line
        else:
            sys.exit(f"unknown command: {cmd} (try --help)")
        save(data)
    ping(added)
    show(data)


if __name__ == "__main__":
    main(sys.argv[1:])
