#!/usr/bin/env bash
# Claude Notify — Installer
#
# Downloads Claude Notifier.app, creates config, generates LaunchAgent plist,
# starts watcher.
#
# Usage:
#   ./install.sh              # Install and start
#   ./install.sh --uninstall  # Stop and remove LaunchAgent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_LABEL="com.claude-notify.watcher"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
CONFIG_DIR="$HOME/.config/claude-notify"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_DIR="/tmp/claude-notifier"
APP_DIR="$PROJECT_DIR/Claude Notifier.app"
NOTIFIER="$APP_DIR/Contents/MacOS/terminal-notifier"

# Release info
RELEASE_VERSION="1.0.0"
RELEASE_URL="https://github.com/veeskelad/claude-notify/releases/download/v${RELEASE_VERSION}/Claude-Notifier.zip"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
log_err()  { echo -e "  ${RED}✗${NC} $1"; }

# ============================================================================
# Uninstall
# ============================================================================

if [[ "${1:-}" == "--uninstall" ]]; then
    echo ""
    echo -e "${BOLD}Uninstalling Claude Notify...${NC}"
    echo ""

    if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        log_ok "Watcher stopped"
    fi

    if [[ -f "$PLIST_PATH" ]]; then
        rm "$PLIST_PATH"
        log_ok "LaunchAgent removed: $PLIST_PATH"
    else
        log_warn "LaunchAgent not found (already removed?)"
    fi

    echo ""
    echo "Config and scripts are kept. To remove completely:"
    echo "  rm -rf $CONFIG_DIR"
    echo "  rm -rf $PROJECT_DIR"
    echo ""
    exit 0
fi

# ============================================================================
# Banner
# ============================================================================

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Claude Notify — Installation${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ============================================================================
# Pre-flight checks
# ============================================================================

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    log_err "This tool only works on macOS."
    exit 1
fi

# Check Python 3.9+
PYTHON3=$(command -v python3 2>/dev/null || true)
if [[ -z "$PYTHON3" ]]; then
    log_err "python3 not found. Install Python 3.9+ first."
    exit 1
fi

PY_VERSION=$($PYTHON3 --version 2>&1 | awk '{print $2}')
PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)

if [[ "$PY_MAJOR" -lt 3 ]] || { [[ "$PY_MAJOR" -eq 3 ]] && [[ "$PY_MINOR" -lt 9 ]]; }; then
    log_err "Python 3.9+ required, found $PY_VERSION"
    exit 1
fi
log_ok "Python: $PYTHON3 ($PY_VERSION)"

# Check curl
if ! command -v curl &>/dev/null; then
    log_err "curl not found (required to download Claude Notifier.app)."
    exit 1
fi

# ============================================================================
# Step 1: Download Claude Notifier.app (if not exists)
# ============================================================================

echo ""
echo -e "${BOLD}Claude Notifier.app...${NC}"

if [[ -x "$NOTIFIER" ]]; then
    log_ok "Claude Notifier.app already exists"
else
    TMPDIR=$(mktemp -d)

    if curl -fsSL -o "$TMPDIR/notifier.zip" "$RELEASE_URL" 2>/dev/null; then
        unzip -qo "$TMPDIR/notifier.zip" -d "$PROJECT_DIR"

        if [[ -x "$NOTIFIER" ]]; then
            log_ok "Claude Notifier.app v${RELEASE_VERSION} downloaded"
        else
            log_err "Could not find notifier binary in downloaded archive"
            log_err "Download manually: $RELEASE_URL"
            rm -rf "$TMPDIR"
            exit 1
        fi
    else
        log_err "Download failed. Check your internet connection."
        log_err "URL: $RELEASE_URL"
        rm -rf "$TMPDIR"
        exit 1
    fi

    rm -rf "$TMPDIR"
fi

# ============================================================================
# Step 2: Create config (if not exists)
# ============================================================================

echo ""
echo -e "${BOLD}Configuration...${NC}"

if [[ -f "$CONFIG_FILE" ]]; then
    log_ok "Config exists: $CONFIG_FILE"
else
    mkdir -p "$CONFIG_DIR"
    cp "$PROJECT_DIR/config.example.json" "$CONFIG_FILE"
    log_ok "Config created: $CONFIG_FILE"
fi

# ============================================================================
# Step 3: Make watcher executable
# ============================================================================

chmod +x "$SCRIPT_DIR/claude-watcher.py"
log_ok "claude-watcher.py is executable"

# ============================================================================
# Step 4: Generate LaunchAgent plist
# ============================================================================

echo ""
echo -e "${BOLD}Setting up LaunchAgent...${NC}"

mkdir -p "$LOG_DIR"

# Stop existing instance if running
if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    log_ok "Stopped previous instance"
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON3}</string>
        <string>${SCRIPT_DIR}/claude-watcher.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchd-stderr.log</string>
    <key>ThrottleInterval</key>
    <integer>5</integer>
</dict>
</plist>
EOF

log_ok "LaunchAgent plist created"

# ============================================================================
# Step 5: Start watcher
# ============================================================================

echo ""
echo -e "${BOLD}Starting watcher...${NC}"

launchctl load "$PLIST_PATH"
sleep 2

if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
    log_ok "Watcher is running"
else
    log_warn "Watcher may not have started. Check logs: $LOG_DIR/"
fi

# ============================================================================
# Step 6: Test notification
# ============================================================================

echo ""
echo -e "${BOLD}Test notification...${NC}"

"$NOTIFIER" \
    -title "Claude Notify" \
    -message "Notifications are working!" \
    -sound "Glass" &>/dev/null &
log_ok "Test notification sent"

# ============================================================================
# Done
# ============================================================================

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Installation Complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Watcher runs as LaunchAgent (auto-starts on login)"
echo "  Config:  $CONFIG_FILE"
echo "  Logs:    $LOG_DIR/"
echo ""
echo -e "  ${YELLOW}Important:${NC} Grant notification permissions!"
echo "  System Settings -> Notifications -> Claude Notifier"
echo "  Enable: Allow Notifications, Alerts style"
echo ""
echo "  To uninstall: $0 --uninstall"
echo ""
