import AppKit
import ApplicationServices

// "Is this session on screen right now?" Decides whether to show anything at all.
//
// Not visible when the screen is locked, the user has been idle for a while, or the
// session's host app is not frontmost. When the host app IS frontmost:
//   IDEs      a segment of the focused window title must name the project (needs Accessibility)
//   iTerm2 /  the selected tab's tty must be the session's tty (AppleScript, needs Automation)
//   Terminal
//   others    frontmost host counts as visible
// When a check can't be made (no permission, script error) the frontmost host counts as
// visible. Two Claude tabs inside one IDE window can't be told apart: counted as visible.

final class Visibility {
    private let config: Config
    private var ttyCache: [String: (tty: String?, at: Date)] = [:]

    init(config: Config) { self.config = config }

    static let terminalBundleIds: Set<String> = [
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "io.alacritty",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
    ]

    /// Ask for Accessibility once; without it the IDE check falls back to "frontmost = visible".
    static func requestAccessibilityOnce() {
        log("[init] accessibility=\(AXIsProcessTrusted())")
        let key = "askedAccessibility"
        guard !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Testing aid: `open -a … --env CLAUDE_NOTIFY_FORCE_OFFSCREEN=1 --args -daemon` treats every session as off screen.
    static let forceOffscreen = ProcessInfo.processInfo.environment["CLAUDE_NOTIFY_FORCE_OFFSCREEN"] == "1"

    var userIsAway: Bool {
        if Visibility.screenLocked { return true }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return idle >= config.awayIdleSeconds
    }

    static var screenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func isVisible(_ s: SessionState) -> Bool {
        if Visibility.forceOffscreen || userIsAway { return false }
        guard let host = s.hostBundleId,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == host
        else { return false }

        switch host {
        case "com.googlecode.iterm2":
            guard !s.tty.isEmpty, let current = selectedTTY(app: host, script: Visibility.itermScript) else { return true }
            return current.hasSuffix(s.tty)
        case "com.apple.Terminal":
            guard !s.tty.isEmpty, let current = selectedTTY(app: host, script: Visibility.terminalScript) else { return true }
            return current.hasSuffix(s.tty)
        default:
            if Visibility.terminalBundleIds.contains(host) { return true }
            guard let title = Visibility.focusedWindowTitle(pid: front.processIdentifier) else { return true }
            return Visibility.title(title, names: s.windowTitleKeys)
        }
    }

    /// VS Code-family titles are segments joined by " — " / " - ", one of them the root
    /// folder or workspace ("my-app (Workspace)"). Match whole segments, not substrings,
    /// so a session in "app" is not "seen" in a window titled "myapp-backend".
    static func title(_ title: String, names: [String]) -> Bool {
        let wanted = Set(names.map { $0.lowercased() })
        let segments = title.components(separatedBy: CharacterSet(charactersIn: "—–")).flatMap { $0.components(separatedBy: " - ") }
        for raw in segments {
            var seg = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if seg.hasPrefix("● ") { seg.removeFirst(2) }
            if let paren = seg.range(of: " (", options: .backwards), seg.hasSuffix(")") {
                seg = String(seg[..<paren.lowerBound])   // "my-app (workspace)" → "my-app"
            }
            if wanted.contains(seg) { return true }
        }
        return false
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window, CFGetTypeID(win) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    // MARK: Terminal tabs

    private static let itermScript = """
        tell application id "com.googlecode.iterm2" to tell current session of current window to get tty
        """
    private static let terminalScript = """
        tell application id "com.apple.Terminal" to get tty of selected tab of front window
        """

    /// tty of the selected terminal tab. AppleScript is slow and may be denied (Automation),
    /// so answers are cached for a second and failures for half a minute.
    private func selectedTTY(app: String, script: String) -> String? {
        if let cached = ttyCache[app] {
            let ttl: TimeInterval = cached.tty == nil ? 30 : 1
            if Date().timeIntervalSince(cached.at) < ttl { return cached.tty }
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
        if result == nil, let error = error {
            log("[visibility] \(app) tty: \(error[NSAppleScript.errorMessage] ?? error)")
        }
        ttyCache[app] = (result, Date())
        return result
    }
}
