import Foundation

// Messages sent by plugin/scripts/claude-notify-hook.py over the Unix socket.
// Parsing is lenient: unknown or missing fields fall back to empty values.

enum CardKind: String {
    case question, plan, permission, done, attention, error
}

struct QuestionOption: Hashable {
    let label: String
    let description: String
}

struct Question: Hashable {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [QuestionOption]
}

struct Card {
    let kind: CardKind
    let tool: String
    let detail: String
    let command: String
    let text: String
    let plan: String
    let planPath: String
    let questions: [Question]
    let background: Int
    let error: String

    init?(_ d: [String: Any]?) {
        guard let d = d, let kind = CardKind(rawValue: d.str("kind")) else { return nil }
        self.kind = kind
        tool = d.str("tool")
        detail = d.str("detail")
        command = d.str("command")
        text = d.str("text")
        plan = d.str("plan")
        planPath = d.str("planPath")
        background = (d["background"] as? NSNumber)?.intValue ?? 0
        error = d.str("error")
        questions = (d["questions"] as? [[String: Any]] ?? []).map { q in
            Question(
                question: q.str("question"),
                header: q.str("header"),
                multiSelect: (q["multiSelect"] as? Bool) ?? false,
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    QuestionOption(label: $0.str("label"), description: $0.str("description"))
                }
            )
        }
    }

    /// Whether a native notification can carry the whole answer as action buttons.
    var fitsNotificationActions: Bool {
        guard kind == .question else { return true }
        return questions.count == 1 && !questions[0].multiSelect && questions[0].options.count <= 8
    }
}

struct Message {
    let type: String
    let event: String
    let id: String
    let tool: String
    let match: String
    let session: [String: Any]
    let card: Card?

    init?(_ d: [String: Any]) {
        guard (d["v"] as? NSNumber)?.intValue == 1 else { return nil }
        type = d.str("type")
        event = d.str("event")
        id = d.str("id").isEmpty ? UUID().uuidString : d.str("id")
        tool = d.str("tool")
        match = d.str("match")
        session = d["session"] as? [String: Any] ?? [:]
        card = Card(d["card"] as? [String: Any])
    }
}

/// What the user decided; serialized back to the waiting hook.
enum Decision {
    case pass
    case allow
    case deny(String)
    case answer([String: String])

    var json: [String: Any] {
        switch self {
        case .pass: return ["decision": "pass"]
        case .allow: return ["decision": "allow"]
        case .deny(let message): return ["decision": "deny", "message": message]
        case .answer(let answers): return ["decision": "answer", "answers": answers]
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return ""
    }
}
