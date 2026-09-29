import AppKit

// Bring the session's app to front.
//   IDEs      "open -b <app> <workspace or folder>" switches to the right window and fullscreen Space
//   terminals activated without a path (a path would open a new tab)

enum Activation {
    static func activate(_ s: SessionState?) {
        guard let s = s, let bundleId = s.hostBundleId else {
            log("[click] no host app for session")
            return
        }
        activate(bundleId: bundleId, path: s.openPath.isEmpty ? s.projectDir : s.openPath)
    }

    static func activate(bundleId: String, path: String) {
        let isTerminal = Visibility.terminalBundleIds.contains(bundleId)
        if !path.isEmpty && !isTerminal && run(["-b", bundleId, path]) { return }
        _ = run(["-b", bundleId])
    }

    @discardableResult
    private static func run(_ args: [String]) -> Bool {
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
