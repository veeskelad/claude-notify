#!/usr/bin/env bash
# Claude Notify — Installer
#
# Builds Claude Notifier.app from Swift source and installs watcher
# to ~/.local/share/claude-notify/.
# Creates config, generates LaunchAgent plist, starts watcher.
# After install, the cloned repo can be safely moved or deleted.
#
# Usage:
#   ./install.sh              # Install and start
#   ./install.sh --uninstall  # Stop and remove everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="$HOME/.local/share/claude-notify"
PLIST_LABEL="com.claude-notify.watcher"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
CONFIG_DIR="$HOME/.config/claude-notify"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_DIR="/tmp/claude-notifier"
APP_DIR="$INSTALL_DIR/Claude Notifier.app"
NOTIFIER="$APP_DIR/Contents/MacOS/claude-notifier"
WATCHER="$INSTALL_DIR/claude-watcher.py"
NOTIFIER_SRC="$SCRIPT_DIR/notifier/main.swift"
NOTIFIER_PLIST="$SCRIPT_DIR/notifier/Info.plist"
BUNDLE_ID="com.claude-mac-notify.notifier"

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

    # Kill any running notifier processes
    pkill -f "Claude Notifier.app" 2>/dev/null && log_ok "Killed notifier processes" || true

    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        log_ok "Installation removed: $INSTALL_DIR"
    fi

    echo ""
    echo "Config is kept at: $CONFIG_DIR"
    echo "To remove config too: rm -rf $CONFIG_DIR"
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

# Check swiftc (Xcode CLI tools)
if ! command -v swiftc &>/dev/null; then
    log_err "swiftc not found. Install Xcode Command Line Tools:"
    log_err "  xcode-select --install"
    exit 1
fi
log_ok "Swift: $(swiftc --version 2>&1 | head -1)"

# ============================================================================
# Step 1: Build Claude Notifier.app from Swift source
# ============================================================================

echo ""
echo -e "${BOLD}Building Claude Notifier.app...${NC}"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# Workaround for CLT SwiftBridging module conflict (macOS 15+)
# Two identical modulemap files exist in CLT; VFS overlay hides the duplicate.
VFS_OVERLAY=""
CLT_SWIFT="/Library/Developer/CommandLineTools/usr/include/swift"
if [[ -f "$CLT_SWIFT/module.modulemap" ]] && [[ -f "$CLT_SWIFT/bridging.modulemap" ]]; then
    VFS_FILE=$(mktemp /tmp/vfs-overlay-XXXXXX.yaml)
    cat > "$VFS_FILE" <<VFSEOF
{
  "version": 0,
  "case-sensitive": false,
  "roots": [
    {
      "name": "$CLT_SWIFT",
      "type": "directory",
      "contents": [
        {
          "name": "bridging",
          "type": "file",
          "external-contents": "$CLT_SWIFT/bridging"
        },
        {
          "name": "bridging.modulemap",
          "type": "file",
          "external-contents": "$CLT_SWIFT/bridging.modulemap"
        },
        {
          "name": "module.modulemap",
          "type": "file",
          "external-contents": "$CLT_SWIFT/bridging.modulemap"
        }
      ]
    }
  ]
}
VFSEOF
    VFS_OVERLAY="-Xfrontend -vfsoverlay -Xfrontend $VFS_FILE"
fi

SWIFTC_CACHE=$(mktemp -d /tmp/swift-cache-XXXXXX)

if swiftc -O -o "$APP_DIR/Contents/MacOS/claude-notifier" \
    -module-cache-path "$SWIFTC_CACHE" \
    $VFS_OVERLAY \
    "$NOTIFIER_SRC" 2>/dev/null; then
    log_ok "Swift binary compiled"
else
    log_err "Swift compilation failed. Try: swiftc $NOTIFIER_SRC"
    rm -rf "$SWIFTC_CACHE" "$VFS_FILE" 2>/dev/null
    exit 1
fi

rm -rf "$SWIFTC_CACHE" "$VFS_FILE" 2>/dev/null

# Install Info.plist and sign the bundle
cp "$NOTIFIER_PLIST" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR" 2>/dev/null
log_ok "App bundle signed ($BUNDLE_ID)"

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
# Step 3: Install watcher script
# ============================================================================

echo ""
echo -e "${BOLD}Installing watcher...${NC}"

cp "$SCRIPT_DIR/claude-watcher.py" "$WATCHER"
chmod +x "$WATCHER"
log_ok "Watcher installed: $WATCHER"

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
        <string>${WATCHER}</string>
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
disown
log_ok "Test notification sent (click to dismiss)"

# ============================================================================
# Done
# ============================================================================

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Installation Complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Installed to: $INSTALL_DIR"
echo "  Config:       $CONFIG_FILE"
echo "  Logs:         $LOG_DIR/"
echo ""
echo "  Watcher runs as LaunchAgent (auto-starts on login)"
echo "  The cloned repo can now be safely moved or deleted."
echo ""
echo -e "  ${YELLOW}Important:${NC} Grant notification permissions!"
echo "  System Settings -> Notifications -> Claude Notifier"
echo "  Enable: Allow Notifications, Alerts style"
echo ""
echo "  To uninstall: $0 --uninstall"
echo ""
