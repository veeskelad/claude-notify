import AppKit

// Whether the rim (limits hairline and the waiting-request dot) is drawn.
//
//   quiet hours   `quiet_hours` in the config ("23:00-07:00") hides the rim on a schedule
//   by hand       the eye button in the limits card, or `claude-notifier -indicators hide|show|toggle|auto`
//                 (e.g. from a Shortcuts automation on the Sleep Focus)
//
// A choice made by hand wins until the schedule next flips (start or end of quiet hours), then the
// schedule takes over again; `auto` hands control back at once. The choice survives restarts.

struct QuietHours: Equatable {
    let start: Int   // minutes after midnight
    let end: Int

    /// "23:00-07:00", "1:30–6:00"; nil for empty or malformed text.
    init?(_ text: String) {
        let parts = text.replacingOccurrences(of: "–", with: "-").split(separator: "-")
        guard parts.count == 2, let s = QuietHours.minutes(parts[0]), let e = QuietHours.minutes(parts[1]), s != e
        else { return nil }
        start = s
        end = e
    }

    private static func minutes(_ text: Substring) -> Int? {
        let hm = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]), (0..<24).contains(h), (0..<60).contains(m)
        else { return nil }
        return h * 60 + m
    }

    /// Ranges may run past midnight: 23:00-07:00 covers 23:30 and 06:59.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }
}

final class IndicatorsState {
    /// Called on the main queue whenever the effective state changes.
    var onChange: (Bool) -> Void = { _ in }
    private(set) var hidden = false

    private let quiet: QuietHours?
    private var manual: Bool?          // nil: follow the schedule
    private var manualQuiet = false    // the schedule's state when the manual choice was made
    private var timer: Timer?
    private static let file = "\(Paths.supportDir)/indicators.json"

    init(quietHours: String) {
        quiet = QuietHours(quietHours)
        if !quietHours.isEmpty && quiet == nil { log("[indicators] quiet_hours \"\(quietHours)\" not understood, ignored") }
        load()
        hidden = effective(Date())
        if quiet != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.update() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.update() }
        log("[indicators] hidden=\(hidden) manual=\(manual.map(String.init) ?? "-") quiet=\(quietHours.isEmpty ? "-" : quietHours)")
    }

    /// "hide", "show", "toggle" or "auto".
    func apply(_ command: String) {
        let quietNow = quiet?.contains(Date()) ?? false
        switch command {
        case "hide": manual = true
        case "show": manual = false
        case "toggle": manual = !hidden
        case "auto": manual = nil
        default:
            log("[indicators] unknown command \(command)")
            return
        }
        manualQuiet = quietNow
        save()
        log("[indicators] \(command)")
        update()
    }

    private func effective(_ now: Date) -> Bool {
        let quietNow = quiet?.contains(now) ?? false
        if let m = manual {
            if quiet == nil || quietNow == manualQuiet { return m }
            // The schedule flipped since the manual choice: it is in charge again.
            manual = nil
            save()
            log("[indicators] schedule took over")
        }
        return quietNow
    }

    private func update() {
        let value = effective(Date())
        guard value != hidden else { return }
        hidden = value
        log("[indicators] hidden=\(value)")
        onChange(value)
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: IndicatorsState.file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        manual = json["manual"] as? Bool
        manualQuiet = json["manual_quiet"] as? Bool ?? false
    }

    private func save() {
        var json: [String: Any] = ["manual_quiet": manualQuiet]
        if let m = manual { json["manual"] = m }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: IndicatorsState.file, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

/// `claude-notifier -indicators <command>`: hand the command to the running app and exit.
/// Runs before NSApplication starts, so no notification prompt or Dock icon.
func sendIndicatorsCommand(_ command: String) -> Never {
    guard ["hide", "show", "toggle", "auto"].contains(command) else {
        fputs("Usage: claude-notifier -indicators hide|show|toggle|auto\n", stderr)
        exit(2)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(1) }
    var addr = IPCServer.address(Paths.socket)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        fputs("Claude Notifier is not running\n", stderr)
        exit(1)
    }
    let line = "{\"v\":1,\"type\":\"indicators\",\"command\":\"\(command)\"}\n"
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
    exit(0)
}
