"""Tests for plugin/scripts/claude-notify-hook.py.  Run: python3 -m unittest discover -s tests"""

import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOOK_PATH = ROOT / "plugin" / "scripts" / "claude-notify-hook.py"

spec = importlib.util.spec_from_file_location("claude_notify_hook", HOOK_PATH)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

ASK_INPUT = {
    "questions": [{
        "question": "Where should the web app live?",
        "header": "Domain",
        "multiSelect": False,
        "options": [
            {"label": "app.example.com (Recommended)", "description": "Next to the docs site"},
            {"label": "web.example.com", "description": "Named after the repo"},
        ],
    }]
}


def permission_input(tool, tool_input, **extra):
    data = {
        "session_id": "s1",
        "transcript_path": "",
        "cwd": "/Users/me/Work/Projects/shop",
        "permission_mode": "bypassPermissions",
        "hook_event_name": "PermissionRequest",
        "tool_name": tool,
        "tool_input": tool_input,
    }
    data.update(extra)
    return data


class ProjectLabelTest(unittest.TestCase):
    def test_plain_project(self):
        self.assertEqual(hook.project_label("/Users/me/Work/Projects/shop"), "shop")

    def test_claude_worktree(self):
        self.assertEqual(hook.project_label("/Users/me/Work/api/.claude/worktrees/fix-login"),
                         "api / fix-login")

    def test_sibling_worktrees_dir(self):
        self.assertEqual(hook.project_label("/Users/me/Work/web-worktrees/TICKET-12-fix"), "web / TICKET-12-fix")

    def test_home(self):
        self.assertEqual(hook.project_label(str(Path.home())), "~")


class SessionTitleTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir)

    def transcript(self, entries, filler_bytes=0):
        path = os.path.join(self.dir, "t.jsonl")
        with open(path, "w") as f:
            for e in entries:
                if e == "FILLER":
                    f.write(json.dumps({"type": "assistant", "pad": "x" * filler_bytes}) + "\n")
                else:
                    f.write(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n")
        return path

    def test_custom_title_wins_over_newer_ai_title(self):
        path = self.transcript([
            {"type": "custom-title", "customTitle": "Promo video"},
            {"type": "ai-title", "aiTitle": "Auto title"},
        ])
        self.assertEqual(hook.session_title(path), "Promo video")

    def test_latest_ai_title(self):
        path = self.transcript([
            {"type": "ai-title", "aiTitle": "Old"},
            {"type": "ai-title", "aiTitle": "New"},
        ])
        self.assertEqual(hook.session_title(path), "New")

    def test_only_tail_is_read(self):
        path = self.transcript([
            {"type": "custom-title", "customTitle": "Far at the start"},
            "FILLER",
            {"type": "ai-title", "aiTitle": "In the tail"},
        ], filler_bytes=hook.TITLE_TAIL_BYTES + 10)
        self.assertEqual(hook.session_title(path), "In the tail")

    def test_missing_file(self):
        self.assertEqual(hook.session_title(os.path.join(self.dir, "none.jsonl")), "")


class WorkspaceFilesTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp()).resolve()
        self.repo = self.root / "shop"
        self.repo.mkdir()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_workspace_inside_the_project(self):
        ws = self.repo / "shop.code-workspace"
        ws.write_text('{"folders": [{"path": "."}]}')
        self.assertEqual(hook.find_workspace_files(str(self.repo)), [str(ws)])

    def test_worktree_uses_the_repository_workspace(self):
        ws = self.repo / "shop.code-workspace"
        ws.write_text('{"folders": [{"path": "."}]}')
        worktree = self.repo / ".claude" / "worktrees" / "fix-login"
        worktree.mkdir(parents=True)
        self.assertEqual(hook.find_workspace_files(str(worktree)), [str(ws)])

    def test_parent_workspace_with_comments_and_trailing_commas(self):
        (self.root / "api").mkdir()
        ws = self.root / "site.code-workspace"
        ws.write_text('// team setup\n{"folders": [{"path": "shop"}, {"path": "api"},], /* no settings */}')
        self.assertEqual(hook.find_workspace_files(str(self.root / "api")), [str(ws)])

    def test_workspace_of_another_folder_is_ignored(self):
        (self.root / "other.code-workspace").write_text('{"folders": [{"path": "other"}]}')
        self.assertEqual(hook.find_workspace_files(str(self.repo)), [])

    def test_nearest_first(self):
        near = self.repo / "shop.code-workspace"
        near.write_text('{"folders": [{"path": "."}]}')
        far = self.root / "all.code-workspace"
        far.write_text('{"folders": [{"path": "shop"}]}')
        self.assertEqual(hook.find_workspace_files(str(self.repo)), [str(near), str(far)])


class BuildMessageTest(unittest.TestCase):
    ENV = {"CLAUDE_CODE_ENTRYPOINT": "claude-vscode", "__CFBundleIdentifier": "com.microsoft.VSCode"}

    def test_question_request(self):
        msg = hook.build_message(permission_input("AskUserQuestion", ASK_INPUT), self.ENV)
        self.assertEqual(msg["type"], "request")
        self.assertTrue(msg["wait"])
        self.assertEqual(msg["match"], "AskUserQuestion")
        card = msg["card"]
        self.assertEqual(card["kind"], "question")
        self.assertEqual(card["questions"][0]["options"][1]["label"], "web.example.com")
        self.assertEqual(msg["session"]["project"], "shop")
        self.assertEqual(msg["session"]["bundleHint"], "com.microsoft.VSCode")

    def test_plan_request(self):
        data = permission_input("ExitPlanMode", {"plan": "## Steps\n1. **Do** X", "planFilePath": "/p.md"})
        card = hook.build_message(data, self.ENV)["card"]
        self.assertEqual(card["kind"], "plan")
        self.assertEqual(card["planPath"], "/p.md")
        self.assertEqual(card["text"], "Steps 1. Do X")

    def test_bash_permission(self):
        data = permission_input("Bash", {"command": "rm -rf build", "description": "Clean build"})
        msg = hook.build_message(data, self.ENV)
        self.assertEqual(msg["card"], {"kind": "permission", "tool": "Bash", "detail": "Clean build", "command": "rm -rf build"})
        self.assertEqual(msg["match"], "Bash:rm -rf build")

    def test_mcp_permission(self):
        card = hook.build_message(permission_input("mcp__telegram__send_message", {}), self.ENV)["card"]
        self.assertEqual(card["detail"], "telegram: send_message")

    def test_resolve_matches_request(self):
        data = permission_input("Bash", {"command": "make"})
        request = hook.build_message(data, self.ENV)
        data.update(hook_event_name="PostToolUse", tool_response={})
        resolve = hook.build_message(data, self.ENV)
        self.assertEqual(resolve["type"], "resolve")
        self.assertEqual(resolve["match"], request["match"])

    def test_headless_sessions_are_ignored(self):
        env = {"CLAUDE_CODE_ENTRYPOINT": "sdk-py"}
        self.assertIsNone(hook.build_message(permission_input("AskUserQuestion", ASK_INPUT), env))

    def test_idle_prompt_is_ignored(self):
        data = {"hook_event_name": "Notification", "notification_type": "idle_prompt", "session_id": "s1"}
        self.assertIsNone(hook.build_message(data, self.ENV))

    def test_permission_prompt_is_attention(self):
        data = {"hook_event_name": "Notification", "notification_type": "permission_prompt",
                "message": "Claude needs your permission", "session_id": "s1", "cwd": "/x/Proj"}
        msg = hook.build_message(data, self.ENV)
        self.assertEqual(msg["card"]["kind"], "attention")

    def test_stop(self):
        data = {"hook_event_name": "Stop", "session_id": "s1", "cwd": "/x/Proj",
                "last_assistant_message": "**Done.** Tests `pass`.", "background_tasks": [{"id": "t"}]}
        card = hook.build_message(data, self.ENV)["card"]
        self.assertEqual(card, {"kind": "done", "text": "Done. Tests pass.", "background": 1})

    def test_subagent_stop_is_ignored(self):
        data = {"hook_event_name": "Stop", "session_id": "s1", "agent_id": "a1"}
        self.assertIsNone(hook.build_message(data, self.ENV))

    def test_prompt_submit_is_session_message(self):
        msg = hook.build_message({"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/x/P"}, self.ENV)
        self.assertEqual(msg["type"], "session")
        self.assertNotIn("title", msg["session"])


class DecisionOutputTest(unittest.TestCase):
    def test_answer_keeps_questions_and_adds_answers(self):
        data = permission_input("AskUserQuestion", ASK_INPUT)
        out = hook.decision_output(data, {"decision": "answer", "answers": {"Where should the web app live?": "web.example.com"}})
        decision = out["hookSpecificOutput"]["decision"]
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "PermissionRequest")
        self.assertEqual(decision["behavior"], "allow")
        self.assertEqual(decision["updatedInput"]["questions"], ASK_INPUT["questions"])
        self.assertEqual(decision["updatedInput"]["answers"], {"Where should the web app live?": "web.example.com"})

    def test_plan_allow_echoes_input(self):
        data = permission_input("ExitPlanMode", {"plan": "p", "planFilePath": "/p.md"})
        decision = hook.decision_output(data, {"decision": "allow"})["hookSpecificOutput"]["decision"]
        self.assertEqual(decision, {"behavior": "allow", "updatedInput": {"plan": "p", "planFilePath": "/p.md"}})

    def test_bash_allow_has_no_updated_input(self):
        data = permission_input("Bash", {"command": "ls"})
        decision = hook.decision_output(data, {"decision": "allow"})["hookSpecificOutput"]["decision"]
        self.assertEqual(decision, {"behavior": "allow"})

    def test_deny_carries_message(self):
        data = permission_input("ExitPlanMode", {"plan": "p"})
        decision = hook.decision_output(data, {"decision": "deny", "message": "Add a rollback step"})["hookSpecificOutput"]["decision"]
        self.assertEqual(decision, {"behavior": "deny", "message": "Add a rollback step"})

    def test_pass_and_garbage_fall_through(self):
        data = permission_input("Bash", {"command": "ls"})
        self.assertIsNone(hook.decision_output(data, {"decision": "pass"}))
        self.assertIsNone(hook.decision_output(data, {}))
        self.assertIsNone(hook.decision_output(data, {"decision": "answer", "answers": {"q": "a"}}))


class TransportTest(unittest.TestCase):
    """Runs the hook as Claude Code would, with HOME pointing to a temp dir."""

    def setUp(self):
        # Short path: Unix socket paths are limited to 104 bytes on macOS.
        self.home = tempfile.mkdtemp(dir="/tmp")
        self.sock_path = Path(self.home) / "Library" / "Application Support" / "claude-notify" / "notifier.sock"

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def run_hook(self, data):
        env = dict(os.environ, HOME=self.home, CLAUDE_CODE_ENTRYPOINT="cli")
        return subprocess.run([sys.executable, str(HOOK_PATH)], input=json.dumps(data),
                              capture_output=True, text=True, env=env, timeout=10)

    def test_app_not_running_falls_through_fast(self):
        start = time.monotonic()
        result = self.run_hook(permission_input("AskUserQuestion", ASK_INPUT))
        self.assertLess(time.monotonic() - start, 1.5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_round_trip_answer(self):
        self.sock_path.parent.mkdir(parents=True)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.sock_path))
        server.listen(1)
        received = {}

        def serve():
            conn, _ = server.accept()
            buf = b""
            while b"\n" not in buf:
                buf += conn.recv(65536)
            received.update(json.loads(buf.split(b"\n")[0]))
            reply = {"decision": "answer", "answers": {"Where should the web app live?": "web.example.com"}}
            conn.sendall((json.dumps(reply) + "\n").encode())
            conn.close()

        thread = threading.Thread(target=serve)
        thread.start()
        result = self.run_hook(permission_input("AskUserQuestion", ASK_INPUT))
        thread.join(5)
        server.close()

        self.assertEqual(received["type"], "request")
        out = json.loads(result.stdout)
        self.assertEqual(out["hookSpecificOutput"]["decision"]["updatedInput"]["answers"],
                         {"Where should the web app live?": "web.example.com"})

    def test_request_survives_app_restart(self):
        self.sock_path.parent.mkdir(parents=True)
        ids = []

        def read(conn):
            buf = b""
            while b"\n" not in buf:
                buf += conn.recv(65536)
            ids.append(json.loads(buf.split(b"\n")[0])["id"])

        def serve():
            first = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            first.bind(str(self.sock_path))
            first.listen(1)
            conn, _ = first.accept()
            read(conn)
            conn.close()                      # the app quits without answering
            first.close()
            self.sock_path.unlink()
            time.sleep(1)                     # ... and comes back a moment later
            second = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            second.bind(str(self.sock_path))
            second.listen(1)
            conn, _ = second.accept()
            read(conn)
            conn.sendall(b'{"decision": "allow"}\n')
            conn.close()
            second.close()

        thread = threading.Thread(target=serve)
        thread.start()
        time.sleep(0.2)                       # let the first listener come up
        result = self.run_hook(permission_input("Bash", {"command": "make test"}))
        thread.join(5)

        self.assertEqual(len(ids), 2)
        self.assertEqual(ids[0], ids[1])      # same request, so the app treats it as one card
        out = json.loads(result.stdout)
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "allow")


if __name__ == "__main__":
    unittest.main()
