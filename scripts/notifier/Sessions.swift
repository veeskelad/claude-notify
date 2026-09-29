import AppKit
import Darwin

// Known Claude Code sessions, keyed by session_id, filled from hook messages.

final class SessionState {
    let id: String
    var project = ""
    var projectDir = ""
    var cwd = ""
    var title = ""
    var openPath = ""
    var pid: pid_t = 0
    var bundleHint = ""
    var hostBundleId: String?
    var tty = ""
    var turnStart: Date?
    var lastSeen = Date()

    init(id: String) { self.id = id }

    /// "my-app · Refactor auth"
    var headline: String {
        let name = project.isEmpty ? "Claude Code" : project
        return title.isEmpty ? name : "\(name) · \(title)"
    }

    /// Names an IDE window of this session shows as its root: the project folder, the
    /// .code-workspace name, and for worktrees the repository they belong to.
    var windowTitleKeys: [String] {
        var keys: [String] = []
        func add(_ name: String) {
            if !name.isEmpty && !keys.contains(name) { keys.append(name) }
        }
        for path in [projectDir, openPath] where !path.isEmpty {
            var name = (path as NSString).lastPathComponent
            if name.hasSuffix(".code-workspace") { name = (name as NSString).deletingPathExtension }
            add(name)
        }
        let parts = (projectDir as NSString).pathComponents
        if let i = parts.lastIndex(of: ".claude"), i > 0, i + 1 < parts.count, parts[i + 1] == "worktrees" {
            add(parts[i - 1])                                   // <repo>/.claude/worktrees/<name>
        } else if parts.count >= 2, parts[parts.count - 2].hasSuffix("-worktrees") {
            add(String(parts[parts.count - 2].dropLast("-worktrees".count)))   // <repo>-worktrees/<name>
        }
        return keys
    }
}

final class SessionRegistry {
    private(set) var sessions: [String: SessionState] = [:]
    private let config: Config

    init(config: Config) { self.config = config }

    @discardableResult
    func update(_ d: [String: Any]) -> SessionState? {
        let id = d.str("id")
        guard !id.isEmpty else { return nil }
        let s = sessions[id] ?? SessionState(id: id)
        sessions[id] = s
        func set(_ key: String, _ apply: (String) -> Void) {
            let v = d.str(key)
            if !v.isEmpty { apply(v) }
        }
        set("project") { s.project = $0 }
        set("projectDir") { s.projectDir = $0 }
        set("cwd") { s.cwd = $0 }
        set("title") { s.title = $0 }
        set("openPath") { s.openPath = $0 }
        set("bundleHint") { s.bundleHint = $0 }
        if let pid = (d["pid"] as? NSNumber)?.int32Value, pid > 1, pid != s.pid {
            s.pid = pid
            s.hostBundleId = nil
        }
        s.lastSeen = Date()
        if s.hostBundleId == nil { resolveHost(s) }
        pruneStale()
        return s
    }

    func remove(_ id: String) { sessions.removeValue(forKey: id) }

    // MARK: Host app detection
    //
    // The hook's parent is the claude process. Walk its ancestors until one is a
    // regular GUI app (the IDE or terminal hosting the session). Sessions inside
    // tmux/screen end at launchd, so fall back to __CFBundleIdentifier that the
    // terminal app exported, then to the configured app.

    private func resolveHost(_ s: SessionState) {
        if config.activateApp != "auto" {
            s.hostBundleId = config.activateApp
            return
        }
        if s.pid > 1 {
            s.tty = ProcInfo.ttyName(s.pid) ?? ""
            var p = s.pid
            for _ in 0..<24 {
                if let app = NSRunningApplication(processIdentifier: p),
                   app.activationPolicy == .regular, let bundle = app.bundleIdentifier {
                    s.hostBundleId = bundle
                    log("[session] \(s.project) → \(bundle) (pid \(s.pid), tty \(s.tty.isEmpty ? "-" : s.tty))")
                    return
                }
                guard let parent = ProcInfo.parentPid(p), parent > 1 else { break }
                p = parent
            }
        }
        if !s.bundleHint.isEmpty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleHint).isEmpty {
            s.hostBundleId = s.bundleHint
            log("[session] \(s.project) → \(s.bundleHint) (env hint)")
        }
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        sessions = sessions.filter { $0.value.lastSeen > cutoff }
    }
}

enum ProcInfo {
    private static func info(_ pid: pid_t) -> kinfo_proc? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        return kp
    }

    static func parentPid(_ pid: pid_t) -> pid_t? { info(pid)?.kp_eproc.e_ppid }

    static func ttyName(_ pid: pid_t) -> String? {
        guard let dev = info(pid)?.kp_eproc.e_tdev, dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return String(cString: name)
    }
}
