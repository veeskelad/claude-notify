# Claude Notify

Native macOS notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Get notified when Claude asks a question, finishes a plan, or waits for input — even when the terminal/IDE is in the background.

## Features

- **Native macOS notifications** with sounds via Claude Notifier.app (downloaded automatically)
- **Works in IDE** — monitors JSONL transcripts directly, bypassing [known hook limitations](https://github.com/anthropics/claude-code/issues/8985) in IDE environments
- **Zero dependencies** — Python 3.9+ stdlib only, no pip packages
- **Configurable** — sounds, debounce intervals, event toggles via JSON config

## How It Works

```
~/.local/share/claude-notify/
  ├── claude-watcher.py          ← LaunchAgent daemon
  └── Claude Notifier.app        ← native notification sender

claude-watcher.py polls ~/.claude/projects/**/*.jsonl every 2s
  → Detects: AskUserQuestion, ExitPlanMode tool uses
  → Sends notification via Claude Notifier.app
```

## Installation

```bash
git clone https://github.com/veeskelad/claude-notify.git
cd claude-notify
./scripts/install.sh
```

The installer will:
1. Download Claude Notifier.app (from GitHub Releases)
2. Install watcher and app to `~/.local/share/claude-notify/`
3. Create default config at `~/.config/claude-notify/config.json`
4. Install and start a LaunchAgent (auto-starts on login)
5. Send a test notification

After install, the cloned repo can be safely moved or deleted.

**After install**, grant notification permissions:
> System Settings → Notifications → Claude Notifier → Allow Notifications → Alerts

### Requirements

- macOS (Apple Silicon)
- Python 3.9+
- curl (for downloading Claude Notifier.app)

### Uninstall

```bash
./scripts/install.sh --uninstall
```

## Events

| Event | Trigger | Default Sound | Default Debounce |
|-------|---------|---------------|------------------|
| `question` | Claude asks a question (`AskUserQuestion`) | Glass | 0s (immediate) |
| `plan_ready` | Plan ready for review (`ExitPlanMode`) | Glass | 0s (immediate) |
| `idle` | Session idle after assistant message | Pop | 60s |

## Configuration

Edit `~/.config/claude-notify/config.json`:

```json
{
  "sounds": {
    "question": "Glass",
    "plan_ready": "Glass",
    "idle": "Pop"
  },
  "debounce_seconds": {
    "question": 0,
    "plan_ready": 0,
    "idle": 60
  },
  "events": {
    "question": true,
    "plan_ready": true,
    "idle": true
  },
  "idle_threshold_seconds": 8
}
```

Set any event to `false` to disable it. Available macOS sounds: `Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`.

After changing config, restart the watcher:

```bash
launchctl unload ~/Library/LaunchAgents/com.claude-notify.watcher.plist
launchctl load ~/Library/LaunchAgents/com.claude-notify.watcher.plist
```

## Supported Environments

| Environment | Status |
|-------------|--------|
| VS Code | Yes |
| Cursor | Yes |
| iTerm2 | Yes |
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
- LaunchAgent stdout: `/tmp/claude-notifier/launchd-stdout.log`
- LaunchAgent stderr: `/tmp/claude-notifier/launchd-stderr.log`

## License

[MIT](LICENSE)
