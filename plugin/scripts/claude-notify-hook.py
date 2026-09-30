#!/usr/bin/env python3
"""
Claude Notify hook: forwards Claude Code hook events to Claude Notifier.app.

One script handles every event registered in ../hooks/hooks.json:

  PermissionRequest   blocking: waits for the user's answer from the notch or a
                      notification and turns it into a hook decision
  everything else     fire-and-forget (registered with "async": true)

The hook converts Claude Code's schema into small neutral messages; the app
decides whether the session is on screen and what to show. If the app is not
running, the hook exits silently and Claude Code shows its own dialog.

Python 3.9+, stdlib only.
"""

import json
import os
import re
import socket
import sys
import time
import uuid
from pathlib import Path

SOCKET_PATH = Path.home() / "Library" / "Application Support" / "claude-notify" / "notifier.sock"
LOG_FILE = Path.home() / "Library" / "Logs" / "claude-notify" / "hook.log"
LOG_MAX_BYTES = 1024 * 1024
TITLE_TAIL_BYTES = 256 * 1024
CONNECT_TIMEOUT = 0.5
# The app went away while a request waited (update, crash): how long to wait for it to come
# back and how many times to send the request again.
RECONNECT_SECONDS = 30
RESEND_LIMIT = 5
PLAN_MAX_CHARS = 20000
TEXT_MAX_CHARS = 600
WORKSPACE_SEARCH_LEVELS = 5   # project dir and 4 levels up: covers <repo>/.claude/worktrees/<name>

# Notification types that mean "Claude is blocked on you" (idle_prompt is covered by Stop)
ATTENTION_TYPES = {"permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"}


# ============================================================================
# Helpers
# ============================================================================

def log(msg: str):
    """Append to hook.log, truncating it when it grows past LOG_MAX_BYTES."""
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > LOG_MAX_BYTES:
            LOG_FILE.write_text("")
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def clean_text(text: str, limit: int = TEXT_MAX_CHARS) -> str:
    """Remove markdown formatting for a compact one-paragraph preview."""
    text = re.sub(r'```.*?```', ' ', text or "", flags=re.DOTALL)
    text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)
    text = re.sub(r'`(.+?)`', r'\1', text)
    text = re.sub(r'\[(.+?)\]\(.+?\)', r'\1', text)
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*[-*]\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'\s+', ' ', text).strip()
    if len(text) > limit:
        text = text[:limit - 1].rstrip() + "…"
    return text


def project_label(project_dir: str) -> str:
    """Human-readable project name; worktrees show as 'repo / worktree'."""
    if not project_dir:
        return ""
    p = Path(project_dir)
    parts = p.parts
    # <repo>/.claude/worktrees/<name>
    if len(parts) >= 4 and parts[-3] == ".claude" and parts[-2] == "worktrees":
        return f"{parts[-4]} / {parts[-1]}"
    # <repo>-worktrees/<name>
    if len(parts) >= 2 and parts[-2].endswith("-worktrees") and len(parts[-2]) > len("-worktrees"):
        return f"{parts[-2][:-len('-worktrees')]} / {parts[-1]}"
    if p == Path.home():
        return "~"
    return p.name or project_dir


def session_title(transcript_path: str) -> str:
    """Latest session title from the transcript tail: custom > ai-generated > agent name.

    Claude Code re-emits title entries often, so the last one sits near the end
    of the file even for transcripts of hundreds of megabytes.
    """
    if not transcript_path:
        return ""
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TITLE_TAIL_BYTES))
            tail = f.read().decode("utf-8", errors="replace")
    except OSError:
        return ""

    found = {}
    for line in reversed(tail.splitlines()):
        for kind, key in (("custom-title", "customTitle"), ("ai-title", "aiTitle"), ("agent-name", "agentName")):
            if kind in found or f'"type":"{kind}"' not in line:
                continue
            try:
                value = json.loads(line).get(key, "")
            except ValueError:
                continue
            if value:
                found[kind] = value
        if "custom-title" in found:
            break
    return found.get("custom-title") or found.get("ai-title") or found.get("agent-name") or ""


def workspace_folders(ws: Path) -> list:
    """Resolved folders of a .code-workspace file (JSON that may have comments and trailing commas)."""
    try:
        text = ws.read_text()
    except OSError:
        return []
    try:
        data = json.loads(text)
    except ValueError:
        text = re.sub(r'("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/', lambda m: m.group(1) or "", text, flags=re.S)
        text = re.sub(r",(\s*[}\]])", r"\1", text)
        try:
            data = json.loads(text)
        except ValueError:
            return []
    folders = []
    for folder in data.get("folders", []) if isinstance(data, dict) else []:
        path = folder.get("path") if isinstance(folder, dict) else None
        if isinstance(path, str):
            folders.append((ws.parent / os.path.expanduser(path)).resolve())
    return folders


def find_workspace_files(project_dir: str) -> list:
    """.code-workspace files whose folders contain project_dir, nearest first. They may sit in
    project_dir itself or above it, so <repo>/<repo>.code-workspace also covers
    <repo>/.claude/worktrees/<name>. The app opens the one whose IDE window is open."""
    if not project_dir:
        return []
    try:
        target = Path(project_dir).resolve()
    except OSError:
        return []
    home = Path.home().resolve()
    found = []
    for directory in [target, *target.parents][:WORKSPACE_SEARCH_LEVELS]:
        if directory == home or directory == directory.parent:
            break
        try:
            candidates = sorted(directory.glob("*.code-workspace"))
        except OSError:
            continue
        for ws in candidates:
            if any(folder == target or folder in target.parents for folder in workspace_folders(ws)):
                found.append(str(ws))
    return found


def relative_path(path: str, base: str) -> str:
    try:
        return str(Path(path).relative_to(base))
    except ValueError:
        return Path(path).name


def tool_detail(tool_name: str, tool_input: dict, project_dir: str) -> dict:
    """What a permission card shows for a tool call."""
    inp = tool_input if isinstance(tool_input, dict) else {}
    if tool_name == "Bash":
        return {"detail": inp.get("description", ""), "command": (inp.get("command") or "")[:2000]}
    if tool_name in ("Edit", "Write", "MultiEdit", "Read"):
        fp = inp.get("file_path", "")
        return {"detail": relative_path(fp, project_dir) if fp else tool_name}
    if tool_name == "NotebookEdit":
        fp = inp.get("notebook_path", "")
        return {"detail": relative_path(fp, project_dir) if fp else "notebook"}
    if tool_name.startswith("mcp__"):
        parts = tool_name.split("__")
        server = parts[1] if len(parts) > 1 else ""
        method = parts[2] if len(parts) > 2 else ""
        return {"detail": f"{server}: {method}" if method else server}
    if tool_name == "WebFetch":
        return {"detail": inp.get("url", "")}
    if tool_name == "WebSearch":
        return {"detail": inp.get("query", "")}
    if tool_name in ("Agent", "Task"):
        return {"detail": inp.get("description", "")}
    compact = json.dumps(inp, ensure_ascii=False)
    return {"detail": compact[:300]}


def match_key(tool_name: str, tool_input) -> str:
    """Identifies one tool call across PermissionRequest and PostToolUse.

    PermissionRequest has no tool_use_id, so parallel calls of the same tool are
    told apart by their command or file. AskUserQuestion/ExitPlanMode inputs change
    between the two events (answers, injected plan), so they match by name only.
    """
    inp = tool_input if isinstance(tool_input, dict) else {}
    target = inp.get("command") or inp.get("file_path") or inp.get("notebook_path") or inp.get("url") or ""
    if tool_name in ("AskUserQuestion", "ExitPlanMode") or not target:
        return tool_name
    return f"{tool_name}:{target}"


def sanitize_questions(questions) -> list:
    """Keep only the fields the UI needs, in a predictable shape."""
    result = []
    for q in questions if isinstance(questions, list) else []:
        if not isinstance(q, dict) or not q.get("question"):
            continue
        options = []
        for o in q.get("options") or []:
            if isinstance(o, dict) and o.get("label"):
                options.append({"label": str(o["label"]), "description": str(o.get("description") or "")})
        result.append({
            "question": str(q["question"]),
            "header": str(q.get("header") or ""),
            "multiSelect": bool(q.get("multiSelect")),
            "options": options,
        })
    return result


# ============================================================================
# Message building (pure: tested in tests/test_hook.py)
# ============================================================================

def session_info(data: dict, env: dict, with_title: bool) -> dict:
    project_dir = env.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or ""
    info = {
        "id": data.get("session_id", ""),
        "project": project_label(project_dir),
        "projectDir": project_dir,
        "cwd": data.get("cwd", ""),
        # The app reads it to see whether a waiting request was answered in the session itself.
        "transcript": data.get("transcript_path", ""),
        # The hook's parent is the claude process; the app walks up from it to the host app.
        "pid": os.getppid(),
        # Exported by the GUI app that started the terminal: the fallback inside tmux/screen.
        "bundleHint": env.get("__CFBundleIdentifier", ""),
        # "claude-vscode" when the session runs in the IDE extension: it can open that session's tab.
        "entrypoint": env.get("CLAUDE_CODE_ENTRYPOINT", ""),
    }
    if data.get("agent_id"):
        info["agentId"] = data["agent_id"]
    if with_title:
        info["title"] = session_title(data.get("transcript_path", ""))
        workspaces = find_workspace_files(project_dir)
        info["openPath"] = workspaces[0] if workspaces else project_dir
        info["workspaces"] = workspaces
    return info


def permission_card(data: dict, project_dir: str) -> dict:
    tool = data.get("tool_name", "")
    inp = data.get("tool_input") or {}
    if tool == "AskUserQuestion":
        return {"kind": "question", "tool": tool, "questions": sanitize_questions(inp.get("questions"))}
    if tool == "ExitPlanMode":
        plan = inp.get("plan") or ""
        return {"kind": "plan", "tool": tool, "plan": plan[:PLAN_MAX_CHARS],
                "planPath": inp.get("planFilePath", ""), "text": clean_text(plan, 300)}
    card = {"kind": "permission", "tool": tool}
    card.update(tool_detail(tool, inp, project_dir))
    return card


def build_message(data: dict, env: dict):
    """Hook input -> message for the app, or None when there is nothing to send."""
    event = data.get("hook_event_name", "")
    # Headless runs (claude -p, Agent SDK scripts) have nobody to answer: a waiting
    # PermissionRequest would stall the automation, and "done" alerts would be noise.
    if env.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk-"):
        return None
    base = {"v": 1, "id": str(uuid.uuid4()), "event": event, "ts": time.time()}

    if event in ("SessionStart", "SessionEnd", "UserPromptSubmit"):
        base.update(type="session", session=session_info(data, env, with_title=event == "SessionStart"))
        return base

    if event == "PermissionRequest":
        session = session_info(data, env, with_title=True)
        base.update(type="request", wait=True, session=session,
                    match=match_key(data.get("tool_name", ""), data.get("tool_input")),
                    card=permission_card(data, session["projectDir"]))
        return base

    if event in ("PostToolUse", "PostToolUseFailure"):
        base.update(type="resolve", tool=data.get("tool_name", ""),
                    match=match_key(data.get("tool_name", ""), data.get("tool_input")),
                    session=session_info(data, env, with_title=False))
        return base

    if event == "Stop":
        if data.get("agent_id"):
            return None
        base.update(type="notify", session=session_info(data, env, with_title=True),
                    card={"kind": "done", "text": clean_text(data.get("last_assistant_message", "")),
                          "background": len(data.get("background_tasks") or [])})
        return base

    if event == "StopFailure":
        text = data.get("last_assistant_message") or data.get("error_details") or data.get("error", "")
        base.update(type="notify", session=session_info(data, env, with_title=True),
                    card={"kind": "error", "error": data.get("error", ""), "text": clean_text(text)})
        return base

    if event == "Notification":
        ntype = data.get("notification_type", "")
        if ntype not in ATTENTION_TYPES:
            return None
        base.update(type="notify", session=session_info(data, env, with_title=True),
                    card={"kind": "attention", "notificationType": ntype,
                          "text": clean_text(data.get("message", ""))})
        return base

    return None


def decision_output(data: dict, reply: dict):
    """App reply -> hook stdout JSON for PermissionRequest, or None to fall through."""
    if not isinstance(reply, dict):
        return None
    decision = reply.get("decision")
    tool = data.get("tool_name", "")
    inp = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}

    if decision == "answer" and tool == "AskUserQuestion":
        answers = reply.get("answers")
        if not isinstance(answers, dict) or not answers:
            return None
        updated = dict(inp)
        updated["answers"] = {str(k): str(v) for k, v in answers.items()}
        body = {"behavior": "allow", "updatedInput": updated}
    elif decision == "allow":
        body = {"behavior": "allow"}
        if tool == "ExitPlanMode":
            body["updatedInput"] = dict(inp)
    elif decision == "deny":
        body = {"behavior": "deny", "message": reply.get("message") or "Denied by the user from Claude Notify"}
    else:
        return None
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": body}}


# ============================================================================
# Transport
# ============================================================================

def connect() -> socket.socket:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(CONNECT_TIMEOUT)
    sock.connect(str(SOCKET_PATH))
    return sock


def send(message: dict):
    with connect() as sock:
        sock.sendall((json.dumps(message, ensure_ascii=False) + "\n").encode())


def exchange(sock: socket.socket, message: dict):
    """Send the request and wait for the reply line; None if the app hung up without one."""
    with sock:
        sock.sendall((json.dumps(message, ensure_ascii=False) + "\n").encode())
        sock.settimeout(None)
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                return None
            buf += chunk
    line = buf.split(b"\n", 1)[0]
    return json.loads(line) if line else {}


def reconnect(deadline: float):
    while time.monotonic() < deadline:
        time.sleep(0.5)
        try:
            return connect()
        except OSError:
            continue
    return None


def request(message: dict) -> dict:
    """Send and block until the app answers; Claude Code's hook timeout bounds the wait.

    No app at the first attempt means "not installed or not running": give up at once. If the app
    goes away while the request waits (restart after an update, crash), send it again once the app
    is back, so the question doesn't vanish from the notch. Claude shows its own dialog meanwhile.
    """
    sock = connect()
    for _ in range(RESEND_LIMIT + 1):
        reply = exchange(sock, message)
        if reply is not None:
            return reply
        sock = reconnect(time.monotonic() + RECONNECT_SECONDS)
        if sock is None:
            break
        log(f"notifier restarted, request {message.get('id', '')[:8]} sent again")
    return {}


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    try:
        message = build_message(data, dict(os.environ))
        if message is None:
            return 0
        if message.get("wait"):
            reply = request(message)
            out = decision_output(data, reply)
            log(f"{message['event']} | {data.get('tool_name', '')} | {reply.get('decision', 'none')}")
            if out:
                print(json.dumps(out, ensure_ascii=False))
        else:
            send(message)
    except (ConnectionRefusedError, FileNotFoundError, socket.timeout):
        log(f"notifier not reachable ({data.get('hook_event_name', '')})")
    except Exception as e:
        log(f"ERROR {data.get('hook_event_name', '')}: {e!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
