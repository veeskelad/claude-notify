# Claude Notify

Native macOS notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Get notified when Claude asks a question, finishes a plan, or waits for input — even when the terminal/IDE is in the background.

## Features

- **Native macOS notifications** with sounds via Claude Notifier.app (built from Swift source)
- **Works in IDE** — monitors JSONL transcripts directly, bypassing [known hook limitations](https://github.com/anthropics/claude-code/issues/8985) in IDE environments
- **Click to activate** — clicking notification switches to your IDE/terminal (supports fullscreen Spaces)
- **Zero dependencies** — Python 3.9+ stdlib only, no pip packages
- **Configurable** — sounds, debounce intervals, event toggles via JSON config

## How It Works

```
~/.local/share/claude-notify/
  ├── claude-watcher.py          ← LaunchAgent daemon
  └── Claude Notifier.app        ← native notification sender

claude-watcher.py polls ~/.claude/projects/**/*.jsonl every 2s
  → Detects: questions, plan approvals, tool permissions, idle sessions
  → IPC: JSON lines → /tmp/claude-notifier/inbox
  → Claude Notifier.app daemon reads inbox → macOS Notification Center
  → Click notification → activates IDE/terminal via osascript
```

## Installation

```bash
git clone https://github.com/veeskelad/claude-notify.git
cd claude-notify
./scripts/install.sh
```

The installer will:
1. Build Claude Notifier.app from Swift source
2. Install watcher and app to `~/.local/share/claude-notify/`
3. Create default config at `~/.config/claude-notify/config.json`
4. Install and start a LaunchAgent (auto-starts on login)
5. Send a test notification

After install, the cloned repo can be safely moved or deleted.

**After install**, grant notification permissions:
> System Settings → Notifications → Claude Notifier → Allow Notifications → Alerts

### Requirements

- macOS 13+ (Ventura or later)
- Python 3.9+
- Xcode Command Line Tools (`xcode-select --install`)

### Uninstall

```bash
./scripts/install.sh --uninstall
```

## Events

| Event | Trigger | Default Sound | Default Debounce |
|-------|---------|---------------|------------------|
| `question` | Claude asks a question (`AskUserQuestion`) | Glass | 0s (immediate) |
| `plan_ready` | Plan ready for review (`ExitPlanMode`) | Glass | 0s (immediate) |
| `tool_permission` | Tool waiting for user approval (Bash, MCP, Edit, etc.) | Funk | 0s (immediate) |
| `idle` | Claude finished responding, waiting for input | Pop | 30s |

## Configuration

Edit `~/.config/claude-notify/config.json`:

```json
{
  "sounds": {
    "question": "Glass",
    "plan_ready": "Glass",
    "idle": "Pop",
    "tool_permission": "Funk"
  },
  "debounce_seconds": {
    "question": 0,
    "plan_ready": 0,
    "idle": 60,
    "tool_permission": 0
  },
  "events": {
    "question": true,
    "plan_ready": true,
    "idle": true,
    "tool_permission": true
  },
  "idle_threshold_seconds": 30,
  "permission_threshold_seconds": 5,
  "activate_app": "auto"
}
```

| Key | Description |
|-----|-------------|
| `sounds.*` | macOS sound name per event (`Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`) |
| `debounce_seconds.*` | Minimum interval between notifications of the same type per session |
| `events.*` | Set to `false` to disable an event type |
| `idle_threshold_seconds` | How long a session must be idle before notifying (default: 30) |
| `permission_threshold_seconds` | How long a tool must wait for approval before notifying (default: 5) |
| `activate_app` | `"auto"` to detect IDE/terminal, or a bundle ID like `"com.apple.Terminal"` |

After changing config, restart the watcher:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.claude-notify.watcher.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-notify.watcher.plist
```

## Supported Environments

| Environment | Status |
|-------------|--------|
| VS Code | Yes |
| Cursor | Yes |
| Antigravity | Yes |
| Zed | Yes |
| JetBrains IDEs | Yes |
| Sublime Text | Yes |
| iTerm2 | Yes |
| Kitty | Yes |
| WezTerm | Yes |
| Alacritty | Yes |
| Terminal.app | Yes (fallback) |

## Troubleshooting

**No notifications appearing?**
- Check permissions: System Settings → Notifications → Claude Notifier
- Set alert style to "Alerts" (not "Banners") for action buttons
- Check logs: `cat /tmp/claude-notifier/watcher.log`

**Watcher not running?**
```bash
launchctl list | grep claude-notify
# If not listed, reinstall:
./scripts/install.sh
```

**Check installed files:**
```bash
ls ~/.local/share/claude-notify/
```

**Logs location:**
- Watcher log: `/tmp/claude-notifier/watcher.log`
- Notifier log: `/tmp/claude-notifier/notifier.log`
- LaunchAgent stdout: `/tmp/claude-notifier/launchd-stdout.log`
- LaunchAgent stderr: `/tmp/claude-notifier/launchd-stderr.log`

## License

[MIT](LICENSE)
