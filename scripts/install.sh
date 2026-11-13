#!/usr/bin/env bash
# Notchy — installer
#
# Builds Notchy.app (scripts/build-app.sh), puts it in /Applications and starts it. The app adds
# itself to Login Items. With --with-plugin it also registers the Claude Code plugin whose hooks
# feed the Claude module. An install of Claude Notify (the old name) is removed on the way: its
# LaunchAgent, app and plugin. Its config and state are copied by Notchy itself on first launch.
#
#   ./install.sh                # build, install, start
#   ./install.sh --with-plugin  # same + add the marketplace and install the plugin
#   ./install.sh --uninstall    # quit and remove the app and its state (config is kept)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/Applications/Notchy.app"
CONFIG_DIR="$HOME/.config/notchy"
LOG_DIR="$HOME/Library/Logs/Notchy"
SUPPORT_DIR="$HOME/Library/Application Support/Notchy"
GUI_DOMAIN="gui/$(id -u)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
log_err()  { echo -e "  ${RED}✗${NC} $1"; }

quit_notchy() {
    osascript -e 'tell application id "com.notchy.app" to quit' &>/dev/null || true
    pkill -f "Notchy.app/Contents/MacOS/Notchy" 2>/dev/null || true
}

# Claude Notify (v3 and older): LaunchAgent, app in ~/.local/share, plugin.
remove_claude_notify() {
    local label plist
    for label in com.claude-notify.notifier com.claude-notify.watcher; do
        plist="$HOME/Library/LaunchAgents/$label.plist"
        launchctl bootout "$GUI_DOMAIN/$label" &>/dev/null && log_ok "Stopped $label" || true
        [[ -f "$plist" ]] && rm "$plist" && log_ok "Removed $plist"
    done
    pkill -f "Claude Notifier.app/Contents/MacOS/claude-notifier" 2>/dev/null || true
    if [[ -d "$HOME/.local/share/claude-notify" ]]; then
        rm -rf "$HOME/.local/share/claude-notify"
        log_ok "Removed the Claude Notify app (~/.local/share/claude-notify)"
    fi
    if command -v claude &>/dev/null && claude plugin list 2>/dev/null | grep -q 'claude-notify@claude-notify'; then
        claude plugin uninstall claude-notify@claude-notify &>/dev/null && log_ok "Removed plugin claude-notify"
        claude plugin marketplace remove claude-notify &>/dev/null || true
    fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
    echo -e "\n${BOLD}Uninstalling Notchy...${NC}\n"
    quit_notchy
    [[ -d "$APP_DIR" ]] && rm -rf "$APP_DIR" && log_ok "Removed $APP_DIR"
    rm -rf "$SUPPORT_DIR"
    echo -e "\nConfig kept at: $CONFIG_DIR"
    echo "Remove the Claude Code plugin with:"
    echo "  claude plugin uninstall notchy@notchy && claude plugin marketplace remove notchy"
    exit 0
fi

WITH_PLUGIN=false
[[ "${1:-}" == "--with-plugin" ]] && WITH_PLUGIN=true

echo -e "\n${BOLD}Notchy — installation${NC}\n"

[[ "$(uname)" == "Darwin" ]] || { log_err "macOS only."; exit 1; }
PYTHON3=$(command -v python3 2>/dev/null || true)
if [[ -z "$PYTHON3" ]] || ! "$PYTHON3" -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
    log_err "python3 3.9+ is required on PATH (the Claude Code hook runs it)."
    exit 1
fi
command -v swift &>/dev/null || { log_err "swift not found. Install Xcode or the Command Line Tools: xcode-select --install"; exit 1; }

echo -e "${BOLD}Building...${NC}"
BUILT="$(bash "$PROJECT_DIR/scripts/build-app.sh" | tail -1)"
log_ok "Built $BUILT"

echo -e "\n${BOLD}Installing...${NC}"
remove_claude_notify
quit_notchy
sleep 1
mkdir -p "$LOG_DIR"
[[ -d "$APP_DIR" ]] && rm -rf "$APP_DIR"
ditto "$BUILT" "$APP_DIR"
log_ok "Installed $APP_DIR"

if [[ ! -f "$CONFIG_DIR/config.json" && ! -f "$HOME/.config/claude-notify/config.json" ]]; then
    mkdir -p "$CONFIG_DIR"
    cp "$PROJECT_DIR/config.example.json" "$CONFIG_DIR/config.json"
    log_ok "Config created: $CONFIG_DIR/config.json"
fi

open -a "$APP_DIR"
sleep 3
if pgrep -f "Notchy.app/Contents/MacOS/Notchy" &>/dev/null; then
    log_ok "Notchy is running (it adds itself to Login Items)"
else
    log_warn "Notchy may not have started. Check $LOG_DIR/notchy.log"
fi

echo -e "\n${BOLD}Claude Code plugin...${NC}"
if $WITH_PLUGIN; then
    claude plugin marketplace add "$PROJECT_DIR" && log_ok "Marketplace added: $PROJECT_DIR"
    claude plugin install notchy@notchy && log_ok "Plugin installed (new sessions pick it up)"
else
    echo "  Register the hooks (once):"
    echo "    claude plugin marketplace add \"$PROJECT_DIR\""
    echo "    claude plugin install notchy@notchy"
fi

echo -e "\n  App:     $APP_DIR\n  Config:  $CONFIG_DIR/config.json\n  Logs:    $LOG_DIR/\n"
echo -e "  ${YELLOW}Permissions${NC} (Notchy is a new app for macOS, grant them once):"
echo "  - System Settings → Notifications → Notchy: allow, style Alerts"
echo "  - System Settings → Privacy & Security → Accessibility → Notchy"
echo ""
