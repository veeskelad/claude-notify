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
  - Idle session (no writes)  -> "waiting for input" (debounced)

Config: ~/.config/claude-notify/config.json (optional, sensible defaults)
"""

import json
import os
import re
import subprocess
import sys
import threading
import time
from collections import defaultdict
from pathlib import Path

# ============================================================================
# Configuration
# ============================================================================

CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"
DEBOUNCE_DIR = Path("/tmp/claude-notifier")
SCRIPT_DIR = Path(__file__).parent

DEFAULT_CONFIG = {
    "sounds": {
        "question": "Glass",
        "plan_ready": "Glass",
        "idle": "Pop",
    },
    "debounce_seconds": {
        "question": 0,
        "plan_ready": 0,
        "idle": 60,
    },
    "events": {
        "question": True,
        "plan_ready": True,
        "idle": True,
    },
    "idle_threshold_seconds": 8,
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
    except Exception as e:
        log(f"Config load error: {e}, using defaults")

    return config


CONFIG = load_config()

DEBOUNCE = {
    "question": CONFIG["debounce_seconds"]["question"],
    "plan_ready": CONFIG["debounce_seconds"]["plan_ready"],
    "idle": CONFIG["debounce_seconds"]["idle"],
}

IDLE_THRESHOLD = CONFIG["idle_threshold_seconds"]


NOTIFIER = SCRIPT_DIR.parent / "Claude Notifier.app" / "Contents" / "MacOS" / "terminal-notifier"

# ============================================================================
# State tracking
# ============================================================================

file_offsets: dict[str, int] = {}
last_notify: dict[str, float] = defaultdict(float)

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

def send_notification(project: str, message: str, event_type: str,
                      title: str, sound: str, cwd: str = ""):
    """Send macOS notification via Claude Notifier.app."""
    if not CONFIG["events"].get(event_type, True):
        return

    config_sound = CONFIG["sounds"].get(event_type, sound)

    def _send():
        try:
            subprocess.run(
                [str(NOTIFIER),
                 "-title", title,
                 "-subtitle", project,
                 "-message", message[:300],
                 "-sound", config_sound],
                timeout=10, capture_output=True,
            )
        except Exception as e:
            log(f"ERROR notification: {e}")

    t = threading.Thread(target=_send, daemon=True)
    t.start()
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

        if entry.get("type") != "assistant":
            continue

        content = entry.get("message", {}).get("content", [])
        cwd = entry.get("cwd", "")

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
