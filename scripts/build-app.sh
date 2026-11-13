#!/usr/bin/env bash
# Builds Notchy.app into .build/app/ (SwiftPM release build + Info.plist + signature).
# Prints the bundle path on the last line. Used by install.sh; safe to run alone.
#
#   NOTCHY_SIGN_IDENTITY   certificate to sign with (default: "Notchy Local Signing" if present,
#                          otherwise ad-hoc). A certificate keeps the Accessibility grant across builds.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.notchy.app"
OUT_DIR="$PROJECT_DIR/.build/app"
APP="$OUT_DIR/Notchy.app"
cd "$PROJECT_DIR"

# Command Line Tools alone ship two identical SwiftBridging modulemaps and the compiler stops with
# "redefinition of module". A VFS overlay hides the duplicate; full Xcode does not need it.
EXTRA=()
CLT_SWIFT="/Library/Developer/CommandLineTools/usr/include/swift"
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]] \
   && [[ -f "$CLT_SWIFT/module.modulemap" && -f "$CLT_SWIFT/bridging.modulemap" ]]; then
    mkdir -p .build
    cat > .build/vfs.yaml <<VFSEOF
{"version": 0, "case-sensitive": false, "roots": [{"name": "$CLT_SWIFT", "type": "directory", "contents": [
  {"name": "bridging", "type": "file", "external-contents": "$CLT_SWIFT/bridging"},
  {"name": "bridging.modulemap", "type": "file", "external-contents": "$CLT_SWIFT/bridging.modulemap"},
  {"name": "module.modulemap", "type": "file", "external-contents": "$CLT_SWIFT/bridging.modulemap"}]}]}
VFSEOF
    EXTRA=(-Xswiftc -Xfrontend -Xswiftc -vfsoverlay -Xswiftc -Xfrontend -Xswiftc "$PROJECT_DIR/.build/vfs.yaml")
fi

swift build -c release ${EXTRA[@]+"${EXTRA[@]}"} >&2
BIN="$(swift build -c release --show-bin-path)/Notchy"

# Assembled in place: every file of the bundle is written on each build, nothing is left over.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchy"
cp App/Info.plist "$APP/Contents/Info.plist"
if [[ -f App/Notchy.icns ]]; then cp App/Notchy.icns "$APP/Contents/Resources/"; fi

IDENTITY="${NOTCHY_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # "Claude Notify Local Signing": the certificate made for this app under its old name.
    for name in "Notchy Local Signing" "Claude Notify Local Signing"; do
        if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$name\""; then IDENTITY="$name"; break; fi
    done
fi
if [[ -n "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >&2
    echo "signed with \"$IDENTITY\"" >&2
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >&2
    echo "signed ad-hoc: Accessibility has to be granted again after every rebuild" >&2
fi
echo "$APP"
