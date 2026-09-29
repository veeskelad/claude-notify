# Claude Notify

A MacBook notch companion for [Claude Code](https://code.claude.com). When a session that is **not on your screen** asks a question, finishes a plan or needs a permission, it drops out of the notch — and you answer right there, without switching windows. The notch also shows your Claude and Codex usage limits.

- **Answer from the notch** — options with descriptions, "own answer", multi-select, several questions in a row; approve a plan or send it back with feedback; allow or deny a tool
- **Only when you can't see it** — nothing pops up for the session you are looking at (frontmost app, IDE window title, terminal tab); everything shows when you step away
- **Clear context** — project (worktrees as `repo / worktree`), session title (`/rename` or the auto title), what exactly is asked
- **Limits on the notch rim** — a hairline around the notch fills with Claude (left) and Codex (right) usage; point at the notch for numbers and reset times
- **Other apps' counters** — unread badges from the Dock (Telegram, Mail, …) as a short banner and in the notch overview; click to open the app
- **Fallback** — no reaction in 20 s → a native notification with the same options as actions
- **"Done"** — a short banner when a long turn (≥ 1 min) finishes in a session you're not watching
- **Official hooks** — built on Claude Code's `PermissionRequest` hook; the session's own dialog stays, whichever answer comes first wins
- **Zero dependencies** — Swift app built from source, Python 3.9+ stdlib hook

## How It Works

```
Claude Code ── plugin "claude-notify" (hooks) ──► claude-notify-hook.py
                                                     │ Unix socket (0600)
                                                     ▼
                          Claude Notifier.app (LaunchAgent)
                            ├─ is the session on screen?
                            ├─ notch: limits · banner · glass card with answers
                            └─ native notification as a fallback
```

- `PermissionRequest` is the only hook that waits. Claude Code shows its dialog at the same time, so answering in the session works as usual and releases the hook.
- All other hooks run `async` — Claude never waits for them.
- Headless runs (`claude -p`, Agent SDK) are ignored.

## Installation

```bash
git clone https://github.com/veeskelad/claude-notify.git
cd claude-notify
./scripts/install.sh --with-plugin
```

The installer builds `Claude Notifier.app` into `~/.local/share/claude-notify/`, starts it as a LaunchAgent, creates `~/.config/claude-notify/config.json`, and with `--with-plugin` registers this repo as a plugin marketplace and installs the `claude-notify` plugin. Without the flag it prints the two commands:

```bash
claude plugin marketplace add /path/to/claude-notify
claude plugin install claude-notify@claude-notify
```

New Claude Code sessions pick up the hooks; restart running ones.

**Permissions** (System Settings):
- Notifications → Claude Notifier → allow, style *Alerts*
- Privacy & Security → Accessibility → Claude Notifier — lets it read the front IDE window title and the Dock badges. Without it, a frontmost IDE counts as "you are looking" and there are no app counters.

**Keeping Accessibility across reinstalls.** macOS ties the grant to the app's signature. The default ad-hoc signature changes with every build, so after `./install.sh` the switch stays on but no longer applies. A self-signed certificate fixes that once:
1. Keychain Access → Certificate Assistant → Create a Certificate… → name `Claude Notify Local Signing`, Identity Type *Self Signed Root*, Certificate Type *Code Signing*.
2. Run `./install.sh`; it signs with that certificate when it exists (allow `codesign` to use the key if asked).
3. In Accessibility, remove the old Claude Notifier entry with "−" and turn on the new one. Later reinstalls keep it.

### Limits

Codex limits are read from Codex's own session logs (`~/.codex/sessions`), no setup needed.

Claude limits come from the official status line data. Add this to the end of your status line script (the one in `statusLine.command`; needs `jq`):

```bash
# Claude Notify: share rate limits with the notch
rl=$(echo "$input" | jq -c 'select(.rate_limits != null) | {rate_limits, updated_at: (now | floor)}' 2>/dev/null)
if [ -n "$rl" ]; then
  cn_dir="$HOME/Library/Application Support/claude-notify"
  mkdir -p "$cn_dir" 2>/dev/null && printf '%s\n' "$rl" > "$cn_dir/.limits-claude.$$" 2>/dev/null \
    && mv -f "$cn_dir/.limits-claude.$$" "$cn_dir/limits-claude.json" 2>/dev/null || true
fi
```

`$input` is the JSON your script read from stdin. Rate limits are only present for Pro/Max subscribers and appear after the first response in a session.

### Requirements

- macOS 13+ (Liquid Glass on macOS 26, blurred material before)
- Claude Code with plugin hooks (tested on 2.1.284)
- Python 3.9+ on `PATH`
- Xcode Command Line Tools (`xcode-select --install`)

### Uninstall

```bash
./scripts/install.sh --uninstall
```

## Configuration

`~/.config/claude-notify/config.json`:

```json
{
  "sounds": { "question": "Glass", "plan_ready": "Glass", "tool_permission": "Funk", "idle": "Pop", "attention": "Funk", "error": "Basso" },
  "events": { "question": true, "plan_ready": true, "tool_permission": true, "idle": true, "attention": true, "error": true },
  "notch": true,
  "notch_fallback_seconds": 20,
  "done_min_turn_seconds": 60,
  "away_idle_seconds": 120,
  "activate_app": "auto",
  "language": "auto",
  "badges": true,
  "badges_ignore": []
}
```

| Key | Meaning |
|-----|---------|
| `events.question` / `plan_ready` / `tool_permission` | Questions, plans, tool permissions |
| `events.idle` | "Done" after a long turn |
| `events.attention` / `error` | Claude waits on something else (MCP form, sandbox network request) / a turn failed with an API error |
| `sounds.*` | macOS sound name per event, `"none"` for silence |
| `notch` | `false` → native notifications only |
| `notch_fallback_seconds` | Seconds before an unanswered request also becomes a native notification |
| `done_min_turn_seconds` | Shorter turns never produce "Done" |
| `away_idle_seconds` | No keyboard/mouse for this long → every session counts as off screen |
| `activate_app` | `"auto"` (app found per session) or a bundle ID |
| `language` | `"auto"`, `"en"` or `"ru"` |
| `badges` | Show other apps' Dock badge counters (needs Accessibility) |
| `badges_ignore` | App names to leave out, e.g. `["Mail"]` |

v2 keys (`debounce_seconds`, `idle_threshold_seconds`, `permission_threshold_seconds`) are ignored. After changing the config, restart the app:

```bash
launchctl kickstart -k gui/$(id -u)/com.claude-notify.notifier
```

## Troubleshooting

- **Nothing shows up** — `pgrep -fl claude-notifier` should list `-daemon`; check `~/Library/Logs/claude-notify/notifier.log` and `hook.log`.
- **Hook not firing** — `claude plugin list` should show `claude-notify` enabled; restart the session.
- **Cards show for the window you're looking at** — grant Accessibility; `[init] accessibility=false` in the log while the switch is on means the grant belongs to an older build (see *Keeping Accessibility across reinstalls*).
- **Clicking a notification opens the wrong window** — set `activate_app` to your IDE's bundle ID.

## License

[MIT](LICENSE)
