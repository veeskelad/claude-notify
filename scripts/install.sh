#!/usr/bin/env bash
# Claude Notify — Installer
#
# Builds Claude Notifier.app from Swift sources into ~/.local/share/claude-notify/,
# starts it as a LaunchAgent and, with --with-plugin, registers the Claude Code
# plugin whose hooks feed it. After install the cloned repo can be moved, but
# the plugin marketplace points at it: re-add it after a move.
#
# Usage:
#   ./install.sh                # build, install, start
#   ./install.sh --with-plugin  # same + add the marketplace and install the plugin
#   ./install.sh --uninstall    # stop and remove everything (config is kept)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="$HOME/.local/share/claude-notify"
APP_DIR="$INSTALL_DIR/Claude Notifier.app"
NOTIFIER="$APP_DIR/Contents/MacOS/claude-notifier"
NOTIFIER_SRC_DIR="$SCRIPT_DIR/notifier"
BUNDLE_ID="com.claude-mac-notify.notifier"   # never change: notification permission is tied to it
AGENT_LABEL="com.claude-notify.notifier"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
OLD_WATCHER_LABEL="com.claude-notify.watcher"   # v2
OLD_WATCHER_PLIST="$HOME/Library/LaunchAgents/${OLD_WATCHER_LABEL}.plist"
CONFIG_DIR="$HOME/.config/claude-notify"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_DIR="$HOME/Library/Logs/claude-notify"
SUPPORT_DIR="$HOME/Library/Application Support/claude-notify"
GUI_DOMAIN="gui/$(id -u)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
log_err()  { echo -e "  ${RED}✗${NC} $1"; }

stop_agent() {
    local label="$1" plist="$2"
    if launchctl print "$GUI_DOMAIN/$label" &>/dev/null; then
        launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
        log_ok "Stopped $label"
    fi
    if [[ -f "$plist" ]]; then
        rm "$plist"
        log_ok "Removed $plist"
    fi
}

stop_notifier() {
    pkill -f "Claude Notifier.app/Contents/MacOS/claude-notifier" 2>/dev/null && log_ok "Stopped running notifier" || true
}

# ============================================================================
# Uninstall
# ============================================================================

if [[ "${1:-}" == "--uninstall" ]]; then
    echo ""
    echo -e "${BOLD}Uninstalling Claude Notify...${NC}"
    echo ""
    stop_agent "$AGENT_LABEL" "$AGENT_PLIST"
    stop_agent "$OLD_WATCHER_LABEL" "$OLD_WATCHER_PLIST"
    stop_notifier
    rm -rf "$INSTALL_DIR" "$SUPPORT_DIR"
    log_ok "Removed $INSTALL_DIR"
    echo ""
    echo "Config kept at: $CONFIG_DIR (remove with: rm -rf $CONFIG_DIR)"
    echo "Remove the Claude Code plugin with:"
    echo "  claude plugin uninstall claude-notify@claude-notify"
    echo "  claude plugin marketplace remove claude-notify"
    echo ""
    exit 0
fi

WITH_PLUGIN=false
[[ "${1:-}" == "--with-plugin" ]] && WITH_PLUGIN=true

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Claude Notify — Installation${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ============================================================================
# Pre-flight checks
# ============================================================================

if [[ "$(uname)" != "Darwin" ]]; then
    log_err "This tool only works on macOS."
    exit 1
fi

PYTHON3=$(command -v python3 2>/dev/null || true)
if [[ -z "$PYTHON3" ]] || ! "$PYTHON3" -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
    log_err "python3 3.9+ is required on PATH (the Claude Code hook runs it)."
    exit 1
fi
log_ok "Python: $PYTHON3 ($("$PYTHON3" --version 2>&1 | awk '{print $2}'))"

if ! command -v swiftc &>/dev/null; then
    log_err "swiftc not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi
log_ok "Swift: $(swiftc --version 2>&1 | head -1)"

# ============================================================================
# Step 1: Build Claude Notifier.app
# ============================================================================

echo ""
echo -e "${BOLD}Building Claude Notifier.app...${NC}"

BUILD_DIR=$(mktemp -d /tmp/claude-notify-build-XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

# Workaround for the CLT SwiftBridging module conflict (macOS 15+): two identical
# modulemaps exist in CLT; a VFS overlay hides the duplicate.
VFS_ARGS=()
CLT_SWIFT="/Library/Developer/CommandLineTools/usr/include/swift"
if [[ -f "$CLT_SWIFT/module.modulemap" ]] && [[ -f "$CLT_SWIFT/bridging.modulemap" ]]; then
    cat > "$BUILD_DIR/vfs.yaml" <<VFSEOF
{
  "version": 0,
  "case-sensitive": false,
  "roots": [
    {
      "name": "$CLT_SWIFT",
      "type": "directory",
      "contents": [
        {"name": "bridging", "type": "file", "external-contents": "$CLT_SWIFT/bridging"},
        {"name": "bridging.modulemap", "type": "file", "external-contents": "$CLT_SWIFT/bridging.modulemap"},
        {"name": "module.modulemap", "type": "file", "external-contents": "$CLT_SWIFT/bridging.modulemap"}
      ]
    }
  ]
}
VFSEOF
    VFS_ARGS=(-Xfrontend -vfsoverlay -Xfrontend "$BUILD_DIR/vfs.yaml")
fi

BUILD_APP="$BUILD_DIR/Claude Notifier.app"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"

if swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$BUILD_DIR/cache" \
    ${VFS_ARGS[@]+"${VFS_ARGS[@]}"} \
    -o "$BUILD_APP/Contents/MacOS/claude-notifier" \
    "$NOTIFIER_SRC_DIR"/*.swift; then
    log_ok "Swift binary compiled"
else
    log_err "Swift compilation failed"
    exit 1
fi

cp "$NOTIFIER_SRC_DIR/Info.plist" "$BUILD_APP/Contents/Info.plist"
codesign --force --sign - --identifier "$BUNDLE_ID" "$BUILD_APP" 2>/dev/null
log_ok "App bundle signed ($BUNDLE_ID)"

# ============================================================================
# Step 2: Stop v2 watcher and the running notifier, install the new app
# ============================================================================

echo ""
echo -e "${BOLD}Installing...${NC}"

stop_agent "$OLD_WATCHER_LABEL" "$OLD_WATCHER_PLIST"
rm -f "$INSTALL_DIR/claude-watcher.py"
stop_agent "$AGENT_LABEL" "$AGENT_PLIST"
stop_notifier

mkdir -p "$INSTALL_DIR" "$LOG_DIR"
rm -rf "$APP_DIR"
cp -R "$BUILD_APP" "$APP_DIR"
log_ok "Installed: $APP_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
    log_ok "Config exists: $CONFIG_FILE"
else
    mkdir -p "$CONFIG_DIR"
    cp "$PROJECT_DIR/config.example.json" "$CONFIG_FILE"
    log_ok "Config created: $CONFIG_FILE"
fi

# ============================================================================
# Step 3: LaunchAgent
# ============================================================================
# The app must be launched through Launch Services (`open -a`), otherwise clicks
# from Notification Center never reach it. `open -W` waits for the app to exit,
# so KeepAlive restarts it after a crash.

cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-W</string>
        <string>-a</string>
        <string>${APP_DIR}</string>
        <string>--args</string>
        <string>-daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchd.log</string>
</dict>
</plist>
EOF

# Right after a bootout launchd may still be tearing the old job down: retry.
for attempt in 1 2 3 4 5; do
    launchctl bootstrap "$GUI_DOMAIN" "$AGENT_PLIST" 2>/dev/null && break
    sleep 1
done
sleep 3
if pgrep -f "Claude Notifier.app/Contents/MacOS/claude-notifier -daemon" &>/dev/null; then
    log_ok "Notifier is running ($AGENT_LABEL)"
else
    log_warn "Notifier may not have started. Check $LOG_DIR/"
fi

# ============================================================================
# Step 4: Claude Code plugin
# ============================================================================

echo ""
echo -e "${BOLD}Claude Code plugin...${NC}"
if $WITH_PLUGIN; then
    claude plugin marketplace add "$PROJECT_DIR" && log_ok "Marketplace added: $PROJECT_DIR"
    claude plugin install claude-notify@claude-notify && log_ok "Plugin installed (new sessions pick it up)"
else
    echo "  Register the hooks (once):"
    echo "    claude plugin marketplace add \"$PROJECT_DIR\""
    echo "    claude plugin install claude-notify@claude-notify"
fi

# ============================================================================
# Step 5: Test notification
# ============================================================================

"$NOTIFIER" -title "Claude Notify" -message "Notifications are working!" -sound "Glass" &>/dev/null &
disown
log_ok "Test notification sent"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Installation Complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  App:     $APP_DIR"
echo "  Config:  $CONFIG_FILE"
echo "  Logs:    $LOG_DIR/"
echo ""
echo -e "  ${YELLOW}Permissions:${NC}"
echo "  - System Settings → Notifications → Claude Notifier: allow, style Alerts"
echo "  - System Settings → Privacy & Security → Accessibility → Claude Notifier"
echo "    (lets it tell which IDE window is in front; without it a frontmost IDE counts as 'looking')"
echo ""
echo "  Uninstall: $0 --uninstall"
echo ""
