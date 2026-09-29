import AppKit
import ApplicationServices

// Unread counters of other apps, read from their Dock badges through Accessibility.
// macOS does not expose other apps' notification texts, but it does expose the badge
// ("3", "12", "•") the Dock shows on each app icon.

struct AppBadge: Identifiable, Equatable {
    let id: String          // app path
    let name: String
    let label: String       // badge text as the Dock shows it
    let url: URL?

    var count: Int? { Int(label.filter(\.isNumber)) }

    var icon: NSImage {
        guard let url = url else { return NSImage(named: NSImage.applicationIconName) ?? NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func == (a: AppBadge, b: AppBadge) -> Bool { a.id == b.id && a.label == b.label }
}

final class BadgeWatcher {
    /// All current badges, and the ones that appeared or grew since the last poll.
    var onChange: (([AppBadge], [AppBadge]) -> Void)?

    private var timer: Timer?
    private var last: [String: AppBadge] = [:]
    private var warned = false
    private var primed = false   // badges present at launch are not "new"
    private let ignore: Set<String>

    init(ignore: [String]) { self.ignore = Set(ignore.map { $0.lowercased() }) }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard AXIsProcessTrusted() else {
            if !warned { log("[badges] no Accessibility permission, Dock badges off"); warned = true }
            return
        }
        let current = BadgeWatcher.readDock().filter {
            !ignore.contains($0.name.lowercased()) && !ignore.contains(($0.url?.lastPathComponent ?? "").lowercased())
        }
        var grown: [AppBadge] = []
        for badge in current {
            if let before = last[badge.id] {
                if let now = badge.count, let was = before.count, now > was { grown.append(badge) }
                else if before.label != badge.label && badge.count == nil { grown.append(badge) }
            } else if primed {
                grown.append(badge)
            }
        }
        let changed = !primed || current.count != last.count || current.contains { last[$0.id] != $0 }
        last = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        primed = true
        if changed { onChange?(current, grown) }
    }

    /// Dock → AXList → dock items; an item with a badge has a non-empty AXStatusLabel.
    static func readDock() -> [AppBadge] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var badges: [AppBadge] = []
        for list in children(of: app) where string(list, kAXRoleAttribute) == "AXList" {
            for item in children(of: list) {
                guard let label = string(item, "AXStatusLabel"), !label.isEmpty else { continue }
                let name = string(item, kAXTitleAttribute) ?? "?"
                var url: URL?
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, "AXURL" as CFString, &value) == .success {
                    url = value as? URL
                }
                badges.append(AppBadge(id: url?.path ?? name, name: name, label: label, url: url))
            }
        }
        return badges
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
