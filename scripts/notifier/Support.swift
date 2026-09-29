import Foundation

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let supportDir = "\(home)/Library/Application Support/claude-notify"
    static let socket = "\(supportDir)/notifier.sock"
    static let logDir = "\(home)/Library/Logs/claude-notify"
    static let log = "\(logDir)/notifier.log"
    static let config = "\(home)/.config/claude-notify/config.json"
}

// MARK: - Logging

private let logQueue = DispatchQueue(label: "claude-notify.log")
private let logMaxBytes: UInt64 = 1024 * 1024

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    logQueue.async {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Paths.logDir, withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: Paths.log),
           let size = attrs[.size] as? UInt64, size > logMaxBytes {
            try? "".write(toFile: Paths.log, atomically: true, encoding: .utf8)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: Paths.log) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            fm.createFile(atPath: Paths.log, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

// MARK: - Configuration
//
// ~/.config/claude-notify/config.json. Keys from v2 (sounds.*, events.* with
// question / plan_ready / idle / tool_permission) keep their meaning; v2 timing
// keys (debounce_seconds, idle_threshold_seconds, permission_threshold_seconds)
// are ignored because events now come from Claude Code hooks.

struct Config {
    var sounds: [String: String] = [
        "question": "Glass",
        "plan_ready": "Glass",
        "tool_permission": "Funk",
        "idle": "Pop",
        "attention": "Funk",
        "error": "Basso",
    ]
    var events: [String: Bool] = [
        "question": true,
        "plan_ready": true,
        "tool_permission": true,
        "idle": true,
        "attention": true,
        "error": true,
    ]
    var notch = true
    var notchFallbackSeconds: Double = 20
    var doneMinTurnSeconds: Double = 60
    var awayIdleSeconds: Double = 120
    var activateApp = "auto"
    var language = "auto"

    static func load() -> Config {
        var config = Config()
        guard let data = FileManager.default.contents(atPath: Paths.config),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return config }

        if let sounds = json["sounds"] as? [String: Any] {
            for (k, v) in sounds { if let s = v as? String { config.sounds[k] = s } }
        }
        if let events = json["events"] as? [String: Any] {
            for (k, v) in events { if let b = v as? Bool { config.events[k] = b } }
        }
        if let b = json["notch"] as? Bool { config.notch = b }
        if let n = json["notch_fallback_seconds"] as? NSNumber { config.notchFallbackSeconds = n.doubleValue }
        if let n = json["done_min_turn_seconds"] as? NSNumber { config.doneMinTurnSeconds = n.doubleValue }
        if let n = json["away_idle_seconds"] as? NSNumber { config.awayIdleSeconds = n.doubleValue }
        if let s = json["activate_app"] as? String { config.activateApp = s }
        if let s = json["language"] as? String { config.language = s }
        return config
    }

    /// Config key used for sounds and event toggles, by card kind.
    static func eventKey(for kind: CardKind) -> String {
        switch kind {
        case .question: return "question"
        case .plan: return "plan_ready"
        case .permission: return "tool_permission"
        case .done: return "idle"
        case .attention: return "attention"
        case .error: return "error"
        }
    }

    func enabled(_ kind: CardKind) -> Bool { events[Config.eventKey(for: kind)] ?? true }
    func sound(_ kind: CardKind) -> String { sounds[Config.eventKey(for: kind)] ?? "default" }
}

// MARK: - Localization (Russian or English, by system language unless configured)

enum L {
    static var russian: Bool = {
        let cfg = Config.load().language
        if cfg == "ru" { return true }
        if cfg == "en" { return false }
        return Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
    }()

    static func t(_ en: String, _ ru: String) -> String { russian ? ru : en }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return t("\(s) s", "\(s) с") }
        let m = s / 60
        if m < 60 { return t("\(m) min", "\(m) мин") }
        return t("\(m / 60) h \(m % 60) min", "\(m / 60) ч \(m % 60) мин")
    }
}
