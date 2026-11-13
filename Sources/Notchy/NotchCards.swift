import AppKit
import SwiftUI

// Cards shown in the expanded notch: a question with answer options, a plan to
// approve or send back, a tool permission. Answers go back through NotchModel.

let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

func accent(_ kind: CardKind) -> Color {
    switch kind {
    case .question: return claudeOrange
    case .plan: return Color(red: 0.45, green: 0.66, blue: 1.0)
    case .permission: return Color(red: 1.0, green: 0.78, blue: 0.3)
    case .done: return .green
    case .attention: return .yellow
    case .error: return .red
    }
}

struct CardView: View {
    let item: NotchItem
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch item.card.kind {
            case .question: QuestionView(item: item, model: model)
            case .plan: PlanView(item: item, model: model)
            default: PermissionView(item: item, model: model)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: Texts.symbol(item.card.kind))
                .font(.system(size: 18))
                .foregroundColor(accent(item.card.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(Texts.kindLabel(item.card))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.items.count > 1 {
                IconButton(symbol: "chevron.left") { model.step(-1) }
                Text("\(model.currentIndex + 1)/\(model.items.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                IconButton(symbol: "chevron.right") { model.step(1) }
            }
            IconButton(symbol: "arrow.up.forward.app", help: L.t("Open session", "Открыть сессию")) { model.onOpen(item.id) }
            IconButton(symbol: "xmark", help: L.t("Hide (answer in the session)", "Скрыть (ответить в сессии)")) { model.onDismiss(item.id) }
        }
    }
}

struct QuestionView: View {
    let item: NotchItem
    @ObservedObject var model: NotchModel
    @State private var step = 0
    @State private var answers: [String: String] = [:]
    @State private var selected: Set<String> = []
    @State private var custom = ""
    @State private var typing = false
    @FocusState private var focused: Bool

    private var questions: [Question] { item.card.questions }

    var body: some View {
        if questions.isEmpty {
            Text(L.t("Claude asked a question", "Claude задал вопрос")).foregroundColor(.white)
        } else {
            let q = questions[min(step, questions.count - 1)]
            VStack(alignment: .leading, spacing: 8) {
                if questions.count > 1 {
                    Text(L.t("Question \(step + 1) of \(questions.count)", "Вопрос \(step + 1) из \(questions.count)") + (q.header.isEmpty ? "" : " · \(q.header)"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                Text(q.question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(q.options.enumerated()), id: \.offset) { index, option in
                    OptionButton(index: index + 1, option: option,
                                 selected: q.multiSelect && selected.contains(option.label)) {
                        choose(q, option.label)
                    }
                }
                if typing {
                    HStack(spacing: 8) {
                        TextField(L.t("Your answer", "Свой ответ"), text: $custom)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focused)
                            .onSubmit { submitCustom(q) }
                        Button(L.t("Send", "Отправить")) { submitCustom(q) }
                            .buttonStyle(NotchButtonStyle(role: .primary))
                            .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                }
                HStack(spacing: 8) {
                    if !typing {
                        Button(L.t("Own answer…", "Свой ответ…")) {
                            model.onWantsKeyboard()
                            typing = true
                            DispatchQueue.main.async { focused = true }
                        }
                        .buttonStyle(NotchButtonStyle(role: .secondary))
                    }
                    Spacer()
                    if q.multiSelect {
                        Button(step + 1 < questions.count ? L.t("Next", "Далее") : L.t("Answer", "Ответить")) {
                            let labels = q.options.map(\.label).filter { selected.contains($0) }
                            record(q, labels.joined(separator: ", "))
                        }
                        .buttonStyle(NotchButtonStyle(role: .primary))
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .onChange(of: focused) { model.editing = $0 }
        }
    }

    private func choose(_ q: Question, _ label: String) {
        if q.multiSelect {
            if selected.contains(label) { selected.remove(label) } else { selected.insert(label) }
        } else {
            record(q, label)
        }
    }

    private func submitCustom(_ q: Question) {
        let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        record(q, text)
    }

    private func record(_ q: Question, _ value: String) {
        answers[q.question] = value
        selected = []
        custom = ""
        typing = false
        focused = false
        if step + 1 < questions.count {
            step += 1
        } else {
            model.editing = false
            model.onDecision(item.id, .answer(answers))
        }
    }
}

struct PlanView: View {
    let item: NotchItem
    @ObservedObject var model: NotchModel
    @State private var revising = false
    @State private var feedback = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PlanView.render(item.card.plan))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(16)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
            if revising {
                TextField(L.t("What should change", "Что изменить в плане"), text: $feedback)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(sendFeedback)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
            }
            HStack(spacing: 8) {
                Button(L.t("Approve", "Одобрить")) { model.onDecision(item.id, .allow) }
                    .buttonStyle(NotchButtonStyle(role: .primary))
                Button(revising ? L.t("Send", "Отправить") : L.t("Keep planning…", "Доработать…")) {
                    if revising {
                        sendFeedback()
                    } else {
                        model.onWantsKeyboard()
                        revising = true
                        DispatchQueue.main.async { focused = true }
                    }
                }
                .buttonStyle(NotchButtonStyle(role: .secondary))
                Spacer()
                if !item.card.planPath.isEmpty {
                    Button(L.t("Open plan", "Открыть план")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: item.card.planPath))
                    }
                    .buttonStyle(NotchButtonStyle(role: .secondary))
                }
            }
        }
        .onChange(of: focused) { model.editing = $0 }
    }

    private func sendFeedback() {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        model.editing = false
        model.onDecision(item.id, .deny(text.isEmpty ? L.t("Keep planning.", "Доработай план.") : text))
    }

    /// Markdown plan -> inline-styled text; headings lose their hashes, line breaks stay.
    static func render(_ plan: String) -> AttributedString {
        let stripped = plan.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: stripped, options: options)) ?? AttributedString(stripped)
    }
}

struct PermissionView: View {
    let item: NotchItem
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.card.detail.isEmpty {
                Text(item.card.detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.card.command.isEmpty {
                Text(item.card.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            }
            HStack(spacing: 8) {
                Button(L.t("Allow", "Разрешить")) { model.onDecision(item.id, .allow) }
                    .buttonStyle(NotchButtonStyle(role: .primary))
                Button(L.t("Deny", "Запретить")) {
                    model.onDecision(item.id, .deny(L.t("The user denied this action.", "Пользователь запретил это действие.")))
                }
                .buttonStyle(NotchButtonStyle(role: .destructive))
                Spacer()
            }
        }
    }
}

struct OptionButton: View {
    let index: Int
    let option: QuestionOption
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(selected ? .black : .white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(selected ? claudeOrange : Color.white.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovering || selected ? 0.17 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(hovering ? 1 : 0.6))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.15 : 0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct NotchButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, destructive }
    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(role == .primary ? .black : .white)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
    }

    private var fill: Color {
        switch role {
        case .primary: return .white
        case .secondary: return Color.white.opacity(0.14)
        case .destructive: return Color.red.opacity(0.75)
        }
    }
}
