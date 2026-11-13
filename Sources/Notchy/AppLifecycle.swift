import Foundation
import ServiceManagement

// Notchy was called Claude Notify before. The first launch copies its config and state
// (limits, indicator choice) so nothing has to be set up again; the old files stay where they are.
enum Migration {
    static func fromClaudeNotify() {
        let fm = FileManager.default
        let oldConfig = "\(Paths.home)/.config/claude-notify/config.json"
        if !fm.fileExists(atPath: Paths.config), fm.fileExists(atPath: oldConfig) {
            try? fm.createDirectory(atPath: (Paths.config as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            if (try? fm.copyItem(atPath: oldConfig, toPath: Paths.config)) != nil {
                log("[migrate] config copied from claude-notify")
            }
        }
        let oldSupport = "\(Paths.home)/Library/Application Support/claude-notify"
        guard !fm.fileExists(atPath: Paths.supportDir),
              let names = try? fm.contentsOfDirectory(atPath: oldSupport) else { return }
        try? fm.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Sockets and temporary files (".limits-claude.<pid>" from the status line) stay behind.
        let copied = names.filter { !$0.hasSuffix(".sock") && !$0.hasPrefix(".") }.filter {
            (try? fm.copyItem(atPath: "\(oldSupport)/\($0)", toPath: "\(Paths.supportDir)/\($0)")) != nil
        }
        log("[migrate] state copied from claude-notify: \(copied.joined(separator: ", "))")
    }
}

// Starts Notchy at login through SMAppService (macOS 13+), the system's own Login Items list.
// Only the copy in /Applications registers itself, so a build run from elsewhere never takes its place.
enum LoginItem {
    static func sync(enabled: Bool) {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let service = SMAppService.mainApp
        do {
            if enabled && service.status != .enabled {
                try service.register()
                log("[login] registered as login item")
            } else if !enabled && service.status == .enabled {
                try service.unregister()
                log("[login] removed from login items")
            }
        } catch {
            log("[login] \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
