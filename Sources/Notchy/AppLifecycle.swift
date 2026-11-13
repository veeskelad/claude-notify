import Foundation
import ServiceManagement

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
