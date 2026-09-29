import Foundation

// Usage limits for the notch wings.
//   Claude  ~/Library/Application Support/claude-notify/limits-claude.json, written by the
//           status line from its official `rate_limits` field (see README, "Limits").
//   Codex   the latest `token_count` event with `rate_limits` in ~/.codex/sessions/**/rollout-*.jsonl.
// Windows are labelled by their length, not by position: on some plans Codex's
// "primary" window is the weekly one.

struct LimitWindow: Hashable {
    let minutes: Int
    let used: Double          // 0...100
    let resetsAt: Date?

    var label: String {
        switch minutes {
        case 300: return L.t("5 h", "5 ч")
        case 10080: return L.t("Week", "Неделя")
        case let m where m % 1440 == 0: return L.t("\(m / 1440) d", "\(m / 1440) д")
        default: return L.t("\(max(1, minutes / 60)) h", "\(max(1, minutes / 60)) ч")
        }
    }
}

struct ProviderLimits: Equatable {
    var windows: [LimitWindow] = []
    var updated: Date?
    var plan = ""

    var isEmpty: Bool { windows.isEmpty }
}

struct LimitsSnapshot: Equatable {
    var claude = ProviderLimits()
    var codex = ProviderLimits()
    var hasData: Bool { !claude.isEmpty || !codex.isEmpty }
}

final class LimitsStore {
    var onChange: ((LimitsSnapshot) -> Void)?
    private(set) var snapshot = LimitsSnapshot()
    private var timer: Timer?

    private let claudeFile = "\(Paths.supportDir)/limits-claude.json"
    private let codexRoot = "\(Paths.home)/.codex/sessions"

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        var next = snapshot
        next.claude = readClaude() ?? ProviderLimits()
        next.codex = readCodex() ?? next.codex
        next.claude.windows = LimitsStore.expire(next.claude.windows)
        next.codex.windows = LimitsStore.expire(next.codex.windows)
        if next != snapshot {
            snapshot = next
            onChange?(next)
        }
    }

    /// A window whose reset time has passed starts over at zero.
    private static func expire(_ windows: [LimitWindow]) -> [LimitWindow] {
        let now = Date()
        return windows.map { w in
            if let reset = w.resetsAt, reset < now { return LimitWindow(minutes: w.minutes, used: 0, resetsAt: nil) }
            return w
        }
    }

    // MARK: Claude

    private func readClaude() -> ProviderLimits? {
        guard let data = FileManager.default.contents(atPath: claudeFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rl = json["rate_limits"] as? [String: Any]
        else { return nil }
        var result = ProviderLimits()
        for (key, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
            guard let w = rl[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            result.windows.append(LimitWindow(minutes: minutes, used: used, resetsAt: reset))
        }
        if let ts = (json["updated_at"] as? NSNumber)?.doubleValue { result.updated = Date(timeIntervalSince1970: ts) }
        return result.isEmpty ? nil : result
    }

    // MARK: Codex

    private func readCodex() -> ProviderLimits? {
        for file in recentRollouts(limit: 6) {
            if let limits = lastRateLimits(in: file) { return limits }
        }
        return nil
    }

    /// Newest rollout files from the last two weeks of day folders (sessions/YYYY/MM/DD).
    private func recentRollouts(limit: Int) -> [String] {
        let fm = FileManager.default
        let calendar = Calendar(identifier: .gregorian)
        var files: [(path: String, date: Date)] = []
        for back in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/%04d/%02d/%02d", codexRoot, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = "\(dir)/\(name)"
                if let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                    files.append((path, mtime))
                }
            }
            if files.count >= limit * 2 { break }
        }
        return files.sorted { $0.date > $1.date }.prefix(limit).map(\.path)
    }

    private func lastRateLimits(in path: String) -> ProviderLimits? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        let tail: UInt64 = 1024 * 1024
        handle.seek(toFileOffset: size > tail ? size - tail : 0)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any]
            else { continue }
            var result = ProviderLimits()
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue,
                      let minutes = (w["window_minutes"] as? NSNumber)?.intValue else { continue }
                let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                result.windows.append(LimitWindow(minutes: minutes, used: used, resetsAt: reset))
            }
            guard !result.isEmpty else { continue }
            result.windows.sort { $0.minutes < $1.minutes }
            result.plan = rl.str("plan_type")
            if let ts = entry["timestamp"] as? String { result.updated = ISO8601DateFormatter.fractional.date(from: ts) }
            return result
        }
        return nil
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

enum LimitFormat {
    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// "in 35 min", "in 3 d 11 h"
    static func resetIn(_ date: Date?) -> String {
        guard let date = date else { return L.t("reset", "сброшен") }
        let s = max(0, date.timeIntervalSinceNow)
        let m = Int(s / 60)
        if m < 60 { return L.t("resets in \(m) min", "сброс через \(m) мин") }
        let h = m / 60
        if h < 24 { return L.t("resets in \(h) h \(m % 60) min", "сброс через \(h) ч \(m % 60) мин") }
        return L.t("resets in \(h / 24) d \(h % 24) h", "сброс через \(h / 24) д \(h % 24) ч")
    }

    static func updated(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let m = Int(-date.timeIntervalSinceNow / 60)
        if m < 1 { return L.t("updated just now", "обновлено только что") }
        if m < 60 { return L.t("updated \(m) min ago", "обновлено \(m) мин назад") }
        if m < 48 * 60 { return L.t("updated \(m / 60) h ago", "обновлено \(m / 60) ч назад") }
        return L.t("updated \(m / 1440) d ago", "обновлено \(m / 1440) д назад")
    }
}
