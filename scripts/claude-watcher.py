#!/usr/bin/env python3
"""
Claude Code Session Watcher — polling-based daemon
Monitors JSONL transcripts for ALL Claude Code sessions (terminal + IDE).
Sends macOS notifications via Claude Notifier.app when Claude needs user attention.

Usage:
  ./claude-watcher.py              # Run in foreground
  ./claude-watcher.py --daemon     # Run in background (daemonize)

Detected events:
  - AskUserQuestion tool use  -> immediate notification
  - ExitPlanMode tool use     -> "plan ready for review"
  - Tool permission pending   -> "waiting for user approval" (Bash, MCP, Edit, etc.)
  - Idle session (no writes)  -> "waiting for input" (debounced)

Config: ~/.config/claude-notify/config.json (optional, sensible defaults)
"""

import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

# ============================================================================
# Configuration
# ============================================================================

CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"
DEBOUNCE_DIR = Path("/tmp/claude-notifier")
INSTALL_DIR = Path.home() / ".local" / "share" / "claude-notify"

DEFAULT_CONFIG = {
    "sounds": {
        "question": "Glass",
        "plan_ready": "Glass",
        "idle": "Pop",
        "tool_permission": "Funk",
    },
    "debounce_seconds": {
        "question": 0,
        "plan_ready": 0,
        "idle": 60,
        "tool_permission": 0,
    },
    "events": {
        "question": True,
        "plan_ready": True,
        "idle": True,
        "tool_permission": True,
    },
    "idle_threshold_seconds": 30,
    "permission_threshold_seconds": 5,
}


def load_config() -> dict:
    """Load user config from ~/.config/claude-notify/config.json, merge with defaults."""
    config_file = Path.home() / ".config" / "claude-notify" / "config.json"

    config = json.loads(json.dumps(DEFAULT_CONFIG))  # deep copy

    if not config_file.exists():
        return config

    try:
        with open(config_file) as f:
            user = json.load(f)
        for section in ("sounds", "debounce_seconds", "events"):
            if section in user and isinstance(user[section], dict):
                config[section].update(user[section])
        if "idle_threshold_seconds" in user:
            config["idle_threshold_seconds"] = int(user["idle_threshold_seconds"])
        if "permission_threshold_seconds" in user:
            config["permission_threshold_seconds"] = int(user["permission_threshold_seconds"])
    except Exception as e:
        log(f"Config load error: {e}, using defaults")

    return config


CONFIG = load_config()

DEBOUNCE = {
    "question": CONFIG["debounce_seconds"]["question"],
    "plan_ready": CONFIG["debounce_seconds"]["plan_ready"],
    "idle": CONFIG["debounce_seconds"]["idle"],
    "tool_permission": CONFIG["debounce_seconds"]["tool_permission"],
}

IDLE_THRESHOLD = CONFIG["idle_threshold_seconds"]


NOTIFIER = INSTALL_DIR / "Claude Notifier.app" / "Contents" / "MacOS" / "claude-notifier"

# ============================================================================
# State tracking
# ============================================================================

file_offsets: dict[str, int] = {}
last_notify: dict[str, float] = defaultdict(float)

# Tools that don't need permission tracking (already handled or always auto-approved)
SKIP_TOOLS = {"AskUserQuestion", "ExitPlanMode", "TodoWrite", "Read", "Grep",
              "Glob", "EnterPlanMode", "ToolSearch",
              "Task", "TaskOutput", "TaskStop", "SendMessage",
              "TeamCreate", "TeamDelete", "Skill"}

# Pending tool_use awaiting tool_result: session_id -> {tool_use_id, tool_name, ...}
pending_tools: dict[str, dict] = {}

# Last known permission mode per session (from JSONL "permissionMode" field)
session_permissions: dict[str, str] = {}

# Idle tracking: filepath -> {"last_change": float, "notified": bool, "assistant_done": bool}
# assistant_done = True when last assistant message had no tool_use (Claude finished its turn)
session_idle_state: dict[str, dict] = {}

# Known apps for click-to-activate (priority order: IDEs first, then terminals)
KNOWN_APPS = [
    "com.google.antigravity",           # Antigravity (VS Code fork)
    "com.todesktop.230313mzl4w4u92",    # Cursor
    "com.microsoft.VSCode",             # VS Code
    "com.microsoft.VSCodeInsiders",     # VS Code Insiders
    "dev.zed.Zed",                      # Zed
    "com.jetbrains.intellij",           # IntelliJ IDEA
    "com.jetbrains.pycharm",            # PyCharm
    "com.jetbrains.WebStorm",           # WebStorm
    "com.sublimetext.4",                # Sublime Text
    "com.googlecode.iterm2",            # iTerm2
    "net.kovidgoyal.kitty",             # Kitty
    "co.zeit.hyper",                    # Hyper
    "com.github.wez.wezterm",          # WezTerm
    "io.alacritty",                     # Alacritty
    "com.apple.Terminal",               # Terminal.app (fallback)
]

# Home directory parts for dynamic prefix stripping
_HOME_PARTS = str(Path.home()).strip("/").split("/")


def project_name_from_path(jsonl_path: str) -> str:
    """Extract human-readable project name from JSONL path.

    Path format: ~/.claude/projects/-Users-name-Work-myproject/SESSION.jsonl
    The directory name encodes the absolute path with dashes.
    """
    parent = Path(jsonl_path).parent.name
    if parent == "subagents":
        parent = Path(jsonl_path).parent.parent.parent.name

    decoded = parent.lstrip("-")

    # Dynamically strip the home directory prefix
    # e.g. "Users-name" from "/Users/name" -> remove "Users-name-" prefix
    home_prefix = "-".join(_HOME_PARTS) + "-"
    if decoded.startswith(home_prefix):
        decoded = decoded[len(home_prefix):]

    # Also strip common work directory prefixes dynamically
    for subdir in ("Work-Projects-", "Work-", "Projects-", "Developer-"):
        if decoded.startswith(subdir):
            decoded = decoded[len(subdir):]
            break

    # Collapse multiple dashes into separator, clean up
    decoded = re.sub(r'-{2,}', '/', decoded)
    decoded = decoded.strip("-/")

    if not decoded or decoded in _HOME_PARTS:
        return "~home"

    return decoded[:40]


def should_notify(session_id: str, event_type: str) -> bool:
    """Check debounce — should we send this notification?"""
    key = f"{session_id}:{event_type}"
    debounce_secs = DEBOUNCE.get(event_type, 30)
    if debounce_secs == 0:
        return True
    now = time.time()
    if now - last_notify[key] < debounce_secs:
        return False
    last_notify[key] = now
    return True


# ============================================================================
# Notifications
# ============================================================================

_cached_app: tuple[str, float] = ("", 0.0)
_cached_frontmost: tuple[bool, float] = (False, 0.0)


def is_ide_frontmost() -> bool:
    """Check if the IDE is the frontmost app (cached 3s). No Automation permission needed."""
    global _cached_frontmost
    now = time.time()
    if now - _cached_frontmost[1] < 3:
        return _cached_frontmost[0]
    try:
        r = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to get bundle identifier '
             'of first process whose frontmost is true'],
            capture_output=True, text=True, timeout=3)
        if r.returncode == 0:
            frontmost_id = r.stdout.strip()
            result = frontmost_id in KNOWN_APPS
            _cached_frontmost = (result, now)
            return result
    except Exception:
        pass
    _cached_frontmost = (False, now)
    return False


def detect_app() -> str:
    """Auto-detect which IDE/terminal is running (cached 60s)."""
    global _cached_app
    now = time.time()
    if _cached_app[0] and now - _cached_app[1] < 60:
        return _cached_app[0]
    try:
        r = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to get bundle identifier '
             'of every process whose background only is false'],
            capture_output=True, text=True, timeout=3)
        if r.returncode == 0:
            running = r.stdout.strip()
            for bundle_id in KNOWN_APPS:
                if bundle_id in running:
                    _cached_app = (bundle_id, now)
                    return bundle_id
    except Exception:
        pass
    return "com.apple.Terminal"


INBOX_FILE = DEBOUNCE_DIR / "inbox"
APP_DIR = INSTALL_DIR / "Claude Notifier.app"

def _ensure_daemon():
    """Ensure the notifier daemon is running.

    Launched via 'open -a' so macOS registers it with Launch Services —
    required for Notification Center click callbacks to work.
    """
    try:
        r = subprocess.run(["pgrep", "-f", "claude-notifier.*-daemon"],
                           capture_output=True, text=True, timeout=2)
        if r.returncode == 0 and r.stdout.strip():
            return  # already running
    except Exception:
        pass

    try:
        subprocess.Popen(
            ["open", "-a", str(APP_DIR), "--args", "-daemon"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("Notifier daemon started via 'open -a'")
    except Exception as e:
        log(f"ERROR starting notifier daemon: {e}")


def send_notification(project: str, message: str, event_type: str,
                      title: str, sound: str, cwd: str = ""):
    """Send macOS notification via Claude Notifier.app daemon.

    Appends a JSON line to the inbox file. The daemon (launched via
    'open -a' for proper Launch Services registration) watches this
    file and posts notifications. Click callbacks work from both
    banners and Notification Center.
    """
    if not CONFIG["events"].get(event_type, True):
        return

    config_sound = CONFIG["sounds"].get(event_type, sound)
    app = CONFIG.get("activate_app", "auto")
    if app == "auto":
        app = detect_app()

    _ensure_daemon()

    payload = json.dumps({
        "title": title,
        "subtitle": project,
        "message": message[:300],
        "sound": config_sound,
        "activate": app,
        "cwd": cwd,
    }) + "\n"

    try:
        with open(INBOX_FILE, "a") as f:
            f.write(payload)
    except Exception as e:
        log(f"ERROR writing inbox: {e}")
        return

    log(f"NOTIFY | {event_type} | {project} | {message[:60]}")


# ============================================================================
# Text processing
# ============================================================================

def clean_text(text: str) -> str:
    """Remove markdown formatting for clean notification text."""
    text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)
    text = re.sub(r'`(.+?)`', r'\1', text)
    text = re.sub(r'\[(.+?)\]\(.+?\)', r'\1', text)
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'^[-*]\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'\n{2,}', ' ', text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text[:200]


def log(msg: str):
    """Append to debug log."""
    ts = time.strftime("%H:%M:%S")
    try:
        with open(DEBOUNCE_DIR / "watcher.log", "a") as f:
            f.write(f"[{ts}] {msg}\n")
    except Exception:
        pass


# ============================================================================
# JSONL processing
# ============================================================================

def process_new_lines(filepath: str, new_lines: list[str]):
    """Analyze new JSONL lines for events that need notification."""
    project = project_name_from_path(filepath)
    session_id = Path(filepath).stem

    for line in new_lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        entry_type = entry.get("type")

        # Track permission mode and clear pending tools when tool_result arrives
        if entry_type == "user":
            perm_mode = entry.get("permissionMode", "")
            if perm_mode:
                session_permissions[session_id] = perm_mode

            content = entry.get("message", {}).get("content", [])
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    result_id = block.get("tool_use_id", "")
                    if session_id in pending_tools and pending_tools[session_id].get("tool_use_id") == result_id:
                        log(f"TOOL RESULT | {project} | {pending_tools[session_id]['tool_name']} | cleared")
                        del pending_tools[session_id]
            continue

        if entry_type != "assistant":
            # User message = Claude is processing, not idle
            if entry_type == "user":
                if filepath in session_idle_state:
                    session_idle_state[filepath]["assistant_done"] = False
            continue

        content = entry.get("message", {}).get("content", [])
        cwd = entry.get("cwd", "")

        # Track whether this assistant entry is text-only (no tool_use)
        has_tool_use = any(
            isinstance(b, dict) and b.get("type") == "tool_use"
            for b in content
        )
        if filepath in session_idle_state:
            session_idle_state[filepath]["assistant_done"] = not has_tool_use
            if cwd:
                session_idle_state[filepath]["cwd"] = cwd

        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue

            tool_name = block.get("name", "")

            if tool_name == "AskUserQuestion":
                questions = block.get("input", {}).get("questions", [])
                q_text = ""
                if questions:
                    q_text = clean_text(questions[0].get("question", ""))
                if should_notify(session_id, "question"):
                    send_notification(
                        project,
                        q_text or "Claude asked a question",
                        "question",
                        "Claude Code — Question",
                        "Glass",
                        cwd,
                    )
                return

            if tool_name == "ExitPlanMode":
                if should_notify(session_id, "plan_ready"):
                    send_notification(
                        project,
                        "Plan ready for approval",
                        "plan_ready",
                        "Claude Code — Plan Ready",
                        "Glass",
                        cwd,
                    )
                return

            # Track tools that may need permission approval
            if tool_name not in SKIP_TOOLS:
                tool_use_id = block.get("id", "")
                inp = block.get("input", {})
                if tool_name == "Bash":
                    detail = inp.get("description", "") or inp.get("command", "")[:100]
                elif tool_name.startswith("mcp__"):
                    parts = tool_name.split("__")
                    provider = parts[1] if len(parts) > 1 else ""
                    method = parts[-1] if len(parts) > 2 else provider
                    detail = f"{provider}: {method}" if provider != method else provider
                elif tool_name in ("Write", "Edit"):
                    fp = inp.get("file_path", "")
                    detail = Path(fp).name if fp else tool_name
                elif tool_name == "NotebookEdit":
                    fp = inp.get("notebook_path", "")
                    detail = Path(fp).name if fp else "notebook"
                else:
                    detail = tool_name

                pending_tools[session_id] = {
                    "tool_use_id": tool_use_id,
                    "tool_name": tool_name,
                    "detail": detail,
                    "project": project,
                    "cwd": cwd,
                    "filepath": filepath,
                    "detected_at": time.time(),
                }


def check_pending_tools():
    """Notify if a tool_use has been pending too long (likely waiting for user permission)."""
    threshold = CONFIG.get("permission_threshold_seconds", 5)
    now = time.time()

    for session_id in list(pending_tools.keys()):
        info = pending_tools[session_id]
        if now - info["detected_at"] < threshold:
            continue

        # Skip if session is in auto-approve mode
        perm = session_permissions.get(session_id, "default")
        tool = info["tool_name"]
        if perm == "bypassPermissions":
            log(f"SKIP (bypass) | {info['project']} | {tool}")
            del pending_tools[session_id]
            continue
        if perm == "acceptEdits" and tool in ("Edit", "Write", "NotebookEdit"):
            log(f"SKIP (acceptEdits) | {info['project']} | {tool}")
            del pending_tools[session_id]
            continue

        # Check if file has grown since last poll (tool is executing, not waiting)
        try:
            current_size = os.path.getsize(info["filepath"])
            if current_size > file_offsets.get(info["filepath"], 0):
                del pending_tools[session_id]
                continue
        except OSError:
            del pending_tools[session_id]
            continue

        tool = info["tool_name"]
        if tool == "Bash":
            title = "Claude Code — Bash Permission"
        elif tool.startswith("mcp__"):
            title = "Claude Code — MCP Permission"
        else:
            title = f"Claude Code — {tool} Permission"

        if should_notify(session_id, "tool_permission"):
            send_notification(info["project"], info["detail"],
                              "tool_permission", title, "Funk", info["cwd"])

        del pending_tools[session_id]


# ============================================================================
# File scanning & polling
# ============================================================================

def scan_jsonl_files() -> dict[str, str]:
    """Find active JSONL files (modified in last 2 hours)."""
    result = {}
    cutoff = time.time() - 7200

    if not CLAUDE_PROJECTS.exists():
        return result

    for jsonl in CLAUDE_PROJECTS.rglob("*.jsonl"):
        if "subagents" in str(jsonl):
            continue
        try:
            if jsonl.stat().st_mtime > cutoff:
                result[str(jsonl)] = str(jsonl)
        except OSError:
            continue

    return result


def poll_files():
    """Poll JSONL files for new content."""
    files = scan_jsonl_files()

    for filepath in files:
        try:
            size = os.path.getsize(filepath)
        except OSError:
            continue

        prev_size = file_offsets.get(filepath, 0)

        if prev_size == 0:
            file_offsets[filepath] = size
            continue

        if size > prev_size:
            # Reset idle tracking on file activity
            session_idle_state[filepath] = {"last_change": time.time(), "notified": False, "assistant_done": False}

            try:
                with open(filepath, "r") as f:
                    f.seek(prev_size)
                    new_content = f.read(size - prev_size)
                    new_lines = new_content.strip().split("\n")
                    real_lines = [l for l in new_lines
                                  if '"type":"progress"' not in l and l.strip()]
                    if real_lines:
                        log(f"FILE CHANGE | {project_name_from_path(filepath)} "
                            f"| +{size - prev_size}b | {len(real_lines)} lines")
                    process_new_lines(filepath, new_lines)
            except Exception as e:
                log(f"ERROR reading {filepath}: {e}")

            file_offsets[filepath] = size
        elif size < prev_size:
            file_offsets[filepath] = size

    check_pending_tools()
    check_idle_sessions()


def check_idle_sessions():
    """Notify if a session has been idle (no file growth) for IDLE_THRESHOLD seconds."""
    now = time.time()
    for filepath, state in list(session_idle_state.items()):
        if state["notified"]:
            continue
        session_id = Path(filepath).stem
        # Don't send idle if there are pending tools (tool_permission handles that)
        if session_id in pending_tools:
            continue
        # Only fire idle when assistant has finished (text-only response, no tool_use)
        if not state.get("assistant_done", False):
            continue
        # Skip all idle notifications when IDE is in focus (user is actively working)
        if is_ide_frontmost():
            continue
        elapsed = now - state["last_change"]
        if elapsed >= IDLE_THRESHOLD:
            project = project_name_from_path(filepath)
            cwd = state.get("cwd", "")
            if should_notify(session_id, "idle"):
                send_notification(
                    project, "Session is waiting for input",
                    "idle", "Claude Code — Waiting", "Pop",
                    cwd)
            state["notified"] = True


# ============================================================================
# Main
# ============================================================================

def main():
    """Main loop — poll files every 2 seconds."""
    DEBOUNCE_DIR.mkdir(parents=True, exist_ok=True)
    log("Watcher started")
    notifier_status = f"notifier: {NOTIFIER}" if NOTIFIER.exists() else "notifier: Claude Notifier.app not found"
    log(notifier_status)
    print(f"Claude Code Watcher started. Monitoring: {CLAUDE_PROJECTS}")
    print(notifier_status)
    print(f"Log: {DEBOUNCE_DIR / 'watcher.log'}")
    print("Press Ctrl+C to stop.")

    poll_files()
    log(f"Tracking {len(file_offsets)} JSONL files")

    try:
        while True:
            poll_files()
            time.sleep(2)
    except KeyboardInterrupt:
        log("Watcher stopped")
        print("\nStopped.")


if __name__ == "__main__":
    if "--daemon" in sys.argv:
        pid = os.fork()
        if pid > 0:
            print(f"Watcher daemon started (PID: {pid})")
            print(f"Log: {DEBOUNCE_DIR / 'watcher.log'}")
            print(f"Stop: kill {pid}")
            sys.exit(0)
        os.setsid()
        sys.stdin = open(os.devnull, "r")
        sys.stdout = open(os.devnull, "w")
        sys.stderr = open(os.devnull, "w")
        main()
    else:
        main()
