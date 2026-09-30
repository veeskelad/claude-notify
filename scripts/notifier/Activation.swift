import AppKit

// Bring the session to front.
//   IDEs      "open -b <app> <workspace or folder>" focuses the window that has it open (and its
//             fullscreen Space). The path must be the one that window was opened with, else the
//             IDE opens another window; the IDE's own list of open windows tells which it is.
//             A session of the Claude Code extension then gets its own tab through the extension's
//             "<scheme>://anthropic.claude-code/open?session=<id>" link.
//   terminals activated without a path (a path would open a new tab)

enum Activation {
    /// What a click needs; built on the main queue, used off it.
    struct Target {
        let sessionId: String
        let bundleId: String
        let workspaces: [String]    // .code-workspace files containing the session, nearest first
        let folders: [String]       // the project folder, and a worktree's repository
        let inExtension: Bool       // runs in the Claude Code IDE extension
    }

    private static let queue = DispatchQueue(label: "claude-notify.activation")

    static func activate(_ s: SessionState?) {
        guard let s = s, let bundleId = s.hostBundleId else {
            log("[click] no host app for session")
            return
        }
        activate(Target(sessionId: s.id, bundleId: bundleId, workspaces: s.workspaces, folders: s.windowFolders,
                        inExtension: s.entrypoint == "claude-vscode"))
    }

    static func activate(_ target: Target) {
        queue.async { run(target) }
    }

    private static func run(_ t: Target) {
        guard !Visibility.terminalBundleIds.contains(t.bundleId),
              let path = windowPath(t), open(["-b", t.bundleId, path])
        else {
            open(["-b", t.bundleId])
            return
        }
        guard t.inExtension, let scheme = urlScheme(t.bundleId),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleId).first
        else { return }
        // The extension opens a session its window doesn't host as a second copy of it,
        // so the link goes out only once the session's own window is in front.
        let name = displayName(path)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let title = Visibility.focusedWindowTitle(pid: app.processIdentifier), Visibility.title(title, names: [name]) {
                open(["\(scheme)://anthropic.claude-code/open?session=\(t.sessionId)"])
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        log("[click] \(name) window not in front, the session tab is left as is")
    }

    // MARK: Which window

    /// The workspace or folder an open window of the IDE has, so it gets focused, not reopened.
    static func windowPath(_ t: Target) -> String? {
        let open = openWindows(t.bundleId)
        if let ws = t.workspaces.first(where: { open.contains(standard($0)) }) { return ws }
        if let dir = t.folders.first(where: { open.contains(standard($0)) }) { return dir }
        // No saved window list: go by window titles. A same-named workspace nearer to the session
        // is usually a checked-out copy inside a worktree, so the farthest match wins.
        let titles = windowTitles(t.bundleId)
        let byTitle = (t.workspaces + t.folders).filter { p in titles.contains { Visibility.title($0, names: [displayName(p)]) } }
        if let ws = byTitle.last(where: { $0.hasSuffix(".code-workspace") }) ?? byTitle.first { return ws }
        return t.workspaces.first ?? t.folders.first
    }

    /// Workspaces and folders of the IDE's open windows, from its saved window state
    /// (VS Code family: ~/Library/Application Support/<nameShort>/User/globalStorage/storage.json).
    private static func openWindows(_ bundleId: String) -> Set<String> {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
              let product = json(app.appendingPathComponent("Contents/Resources/app/product.json")),
              let name = product["nameShort"] as? String
        else { return [] }
        let storage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(name)/User/globalStorage/storage.json")
        guard let state = json(storage)?["windowsState"] as? [String: Any] else { return [] }
        var windows = state["openedWindows"] as? [[String: Any]] ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        var paths = Set<String>()
        for w in windows {
            let workspace = (w["workspaceIdentifier"] as? [String: Any])?["configURIPath"] as? String
            for uri in [workspace, w["folder"] as? String].compactMap({ $0 }) {
                if let url = URL(string: uri), url.isFileURL { paths.insert(standard(url.path)) }
            }
        }
        return paths
    }

    private static func windowTitles(_ bundleId: String) -> [String] {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                            kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
            return title as? String
        }
    }

    /// The URL scheme the app registered ("vscode", "antigravity-ide", …).
    private static func urlScheme(_ bundleId: String) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
              let types = Bundle(url: app)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        else { return nil }
        return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.first { $0 != "file" }
    }

    /// How a window titles this path: "shop" for …/shop and …/shop.code-workspace.
    private static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".code-workspace") ? (name as NSString).deletingPathExtension : name
    }

    private static func standard(_ path: String) -> String { (path as NSString).resolvingSymlinksInPath }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @discardableResult
    private static func open(_ args: [String]) -> Bool {
        log("[click] open \(args.joined(separator: " "))")
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            log("[click] failed: \(error.localizedDescription)")
            return false
        }
    }
}
