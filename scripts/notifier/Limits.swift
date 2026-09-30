import Foundation

// Usage limits for the notch wings.
//   Claude  the account's limits from Claude Code itself (SDK control request `get_usage`),
//           asked whenever a session is active; also the status line's `rate_limits`, written to
//           ~/Library/Application Support/claude-notify/limits-claude.json (see README, "Limits").
//   Codex   the account's limits from Codex's own app server (`codex app-server`,
//           `account/rateLimits/read`: current for the whole account, whatever device used it);
//           without it, the latest `token_count` event in ~/.codex/sessions/**/rollout-*.jsonl.
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
    private let probes: [String: AccountProbe]
    private var live: [String: ProviderLimits] = [:]
    private var askedAt: [String: Date] = [:]

    init(codexPath: String, claudePath: String) {
        var probes: [String: AccountProbe] = [:]
        probes["codex"] = AccountProbe.codex(path: codexPath)
        probes["claude"] = AccountProbe.claude(path: claudePath)
        self.probes = probes
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// The limits are about to be shown: bring them up to date if they are more than a minute old.
    func refreshSoon() {
        ask("claude", ifOlderThan: 60)
        ask("codex", ifOlderThan: 60)
    }

    /// Some Claude Code session (terminal or IDE) did something: its usage may have moved.
    func claudeActive() { ask("claude", ifOlderThan: 120) }

    func refresh() {
        // Claude has no background poll: it changes only when some session works (claudeActive).
        ask("codex", ifOlderThan: 300)
        var next = snapshot
        next.claude = LimitsStore.newer(live["claude"], readClaude()) ?? ProviderLimits()
        next.codex = LimitsStore.newer(live["codex"], readCodex()) ?? next.codex
        next.claude.windows = LimitsStore.expire(next.claude.windows)
        next.codex.windows = LimitsStore.expire(next.codex.windows)
        if next != snapshot {
            snapshot = next
            onChange?(next)
        }
    }

    private func ask(_ name: String, ifOlderThan seconds: TimeInterval) {
        guard let probe = probes[name] else { return }
        if let asked = askedAt[name], Date().timeIntervalSince(asked) < seconds { return }
        askedAt[name] = Date()
        probe.fetch { [weak self] limits in
            guard let self = self, let limits = limits else { return }
            if limits.windows != self.live[name]?.windows {
                log("[limits] \(name) \(limits.plan): " + limits.windows.map { "\($0.label) \(LimitFormat.percent($0.used))" }.joined(separator: ", "))
            }
            self.live[name] = limits
            self.refresh()
        }
    }

    private static func newer(_ a: ProviderLimits?, _ b: ProviderLimits?) -> ProviderLimits? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        return (a.updated ?? .distantPast) >= (b.updated ?? .distantPast) ? a : b
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

/// Asks a CLI for the account's current limits the way its own apps do: Codex through
/// `codex app-server` (`account/rateLimits/read`), Claude Code through its SDK control
/// protocol (`get_usage`). The CLI keeps its sign-in to itself; one short-lived process per
/// question, JSON lines both ways.
final class AccountProbe {
    let name: String
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let requests: [[String: Any]]
    private let isReply: ([String: Any]) -> Bool
    private let parse: ([String: Any]) -> ProviderLimits?
    private let queue: DispatchQueue
    private var running = false          // main queue
    private var warned = false

    private init(name: String, executable: String, arguments: [String], environment: [String: String] = [:],
                 requests: [[String: Any]], isReply: @escaping ([String: Any]) -> Bool,
                 parse: @escaping ([String: Any]) -> ProviderLimits?) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.requests = requests
        self.isReply = isReply
        self.parse = parse
        queue = DispatchQueue(label: "claude-notify.limits.\(name)")
    }

    private static func find(_ configured: String, _ candidates: [String]) -> String? {
        let list = configured.isEmpty ? candidates : [(configured as NSString).expandingTildeInPath]
        return list.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func codex(path: String) -> AccountProbe? {
        let home = Paths.home
        guard let exe = find(path, ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                                    "\(home)/.npm-global/bin/codex"]) else { return nil }
        return AccountProbe(
            name: "codex", executable: exe, arguments: ["app-server"],
            requests: [
                ["method": "initialize", "id": 0,
                 "params": ["clientInfo": ["name": "claude-notify", "title": "Claude Notify", "version": "3"]]],
                ["method": "initialized"],
                ["method": "account/rateLimits/read", "id": 1],
            ],
            isReply: { ($0["id"] as? NSNumber)?.intValue == 1 },
            parse: { reply in
                guard let snapshot = (reply["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return nil }
                var result = ProviderLimits()
                for key in ["primary", "secondary"] {
                    guard let w = snapshot[key] as? [String: Any],
                          let used = (w["usedPercent"] as? NSNumber)?.doubleValue,
                          let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue else { continue }
                    let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    result.windows.append(LimitWindow(minutes: minutes, used: used, resetsAt: reset))
                }
                result.plan = snapshot.str("planType")
                return result
            })
    }

    /// Headless, without the user's hooks, MCP servers or a saved session: nothing but the question.
    static func claude(path: String) -> AccountProbe? {
        let home = Paths.home
        guard let exe = find(path, ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude",
                                    "\(home)/.claude/local/claude"]) else { return nil }
        return AccountProbe(
            name: "claude", executable: exe,
            arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--no-session-persistence", "--strict-mcp-config", "--settings", "{\"disableAllHooks\": true}"],
            environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"],
            requests: [["type": "control_request", "request_id": "claude-notify-usage", "request": ["subtype": "get_usage"]]],
            isReply: { ($0["type"] as? String) == "control_response" },
            parse: { reply in
                guard let usage = (reply["response"] as? [String: Any])?["response"] as? [String: Any],
                      let rl = usage["rate_limits"] as? [String: Any] else { return nil }
                var result = ProviderLimits()
                for (key, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
                    guard let w = rl[key] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
                    result.windows.append(LimitWindow(minutes: minutes, used: used, resetsAt: AccountProbe.date(w["resets_at"])))
                }
                result.plan = usage.str("subscription_type")
                return result
            })
    }

    /// "2026-09-30T11:10:00.456835+00:00": ISO 8601 with microseconds, which ISO8601DateFormatter can't read.
    private static func date(_ value: Any?) -> Date? {
        guard var text = value as? String else { return nil }
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            text.removeSubrange(dot..<zone)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Calls back on the main queue; nil when the CLI can't tell (signed out, API key, error).
    func fetch(_ done: @escaping (ProviderLimits?) -> Void) {
        guard !running else { return }
        running = true
        queue.async {
            var result = self.ask().flatMap(self.parse)
            if result?.isEmpty ?? true { result = nil } else {
                result?.windows.sort { $0.minutes < $1.minutes }
                result?.updated = Date()
            }
            DispatchQueue.main.async {
                self.running = false
                if result == nil && !self.warned { log("[limits] \(self.name) gave no rate limits"); self.warned = true }
                if result != nil { self.warned = false }
                done(result)
            }
        }
    }

    private func ask() -> [String: Any]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        // npm launchers are node scripts: launchd's PATH has neither node nor Homebrew.
        var env = ProcessInfo.processInfo.environment
        let dir = (executable as NSString).deletingLastPathComponent
        env["PATH"] = [dir, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env.merge(environment) { _, new in new }
        proc.environment = env
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        defer { if proc.isRunning { proc.terminate() } }

        for request in requests {
            guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            input.fileHandleForWriting.write(data + Data("\n".utf8))
        }
        // Read lines until the reply arrives; a watchdog ends a hung process.
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let reply = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], isReply(reply) {
                    return reply
                }
            }
        }
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
