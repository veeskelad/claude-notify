import Foundation

// Wording shared by the notch and system notifications.

enum Texts {
    static func kindLabel(_ card: Card) -> String {
        switch card.kind {
        case .question:
            if card.questions.count > 1 { return L.t("\(card.questions.count) questions", "Вопросов: \(card.questions.count)") }
            let header = card.questions.first?.header ?? ""
            return header.isEmpty ? L.t("Question", "Вопрос") : L.t("Question · \(header)", "Вопрос · \(header)")
        case .plan: return L.t("Plan ready for review", "План готов к одобрению")
        case .permission: return L.t("Permission · \(toolName(card.tool))", "Разрешение · \(toolName(card.tool))")
        case .done: return L.t("Done", "Готово")
        case .attention: return L.t("Needs your attention", "Нужно ваше внимание")
        case .error: return card.error.isEmpty ? L.t("Error", "Ошибка") : L.t("Error · \(card.error)", "Ошибка · \(card.error)")
        }
    }

    static func symbol(_ kind: CardKind) -> String {
        switch kind {
        case .question: return "questionmark.bubble.fill"
        case .plan: return "list.bullet.clipboard.fill"
        case .permission: return "lock.shield.fill"
        case .done: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.bubble.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    static func toolName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.components(separatedBy: "__")
        return parts.count > 1 ? "MCP \(parts[1])" : "MCP"
    }

    /// Notification body: the gist of what Claude wants.
    static func body(_ card: Card) -> String {
        switch card.kind {
        case .question:
            guard let q = card.questions.first else { return L.t("Claude asked a question", "Claude задал вопрос") }
            var lines = [q.question]
            if card.questions.count == 1 {
                lines += q.options.enumerated().map { "\($0.offset + 1)) \($0.element.label)" }
            } else {
                lines.append(L.t("+\(card.questions.count - 1) more", "и ещё \(card.questions.count - 1)"))
            }
            return lines.joined(separator: "\n")
        case .plan:
            return card.text.isEmpty ? L.t("Plan ready for approval", "План ждёт одобрения") : card.text
        case .permission:
            var lines: [String] = []
            if !card.detail.isEmpty { lines.append(card.detail) }
            if !card.command.isEmpty { lines.append("$ " + card.command) }
            return lines.isEmpty ? card.tool : lines.joined(separator: "\n")
        case .done:
            return card.text.isEmpty ? L.t("Claude finished", "Claude закончил") : card.text
        case .attention, .error:
            return card.text
        }
    }
}
