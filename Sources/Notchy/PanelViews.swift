import AppKit
import SwiftUI

// The panel that opens from the notch, and the small states the notch grows into.
//
//   panel     a row level with the notch (tabs on the left, status on the right), then the tab:
//             Home = clock on the left, a switchable widget on the right (System, Claude, Codex)
//   compact   the notch a little wider, an icon on each side (Claude at work: ✋ waiting ⟳ working ✓ done)
//   banner    two lines: icon and label level with the notch, the message under it
//
// Everything is drawn in one black shape that continues the cutout, so it reads as the notch
// itself growing rather than a window under it.

enum PanelTab: String, CaseIterable {
    case home
    var symbol: String { "house" }
}

enum PanelWidget: String, CaseIterable {
    case system, claude, codex

    var symbol: String {
        switch self {
        case .system: return "gauge.with.dots.needle.33percent"
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var title: String {
        switch self {
        case .system: return L.t("System", "Система")
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// One Claude Code session in the Claude widget.
struct ClaudeSessionRow: Identifiable, Equatable {
    enum State: Equatable {
        case waiting(CardKind)
        case working(since: Date, tool: String)
        case done(at: Date)
    }
    let id: String
    let name: String
    let state: State
}

/// Counts for the compact Claude state: requests waiting, sessions at work, finished lately.
struct ClaudeActivity: Equatable {
    var waiting = 0
    var working = 0
    var done = 0
    var isEmpty: Bool { waiting == 0 && working == 0 }
}

// MARK: - Shape

/// The notch grown downwards: flush with the top of the screen, small concave "ears" where it
/// meets the menu bar (like the hardware cutout), round corners at the bottom.
struct NotchShape: Shape {
    var ear: CGFloat = 6
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let e = min(ear, r.width / 4)
        let b = min(bottomRadius, (r.height - e) / 2, (r.width - 2 * e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + b, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - b), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// A row level with the notch: content left and right of the cutout, nothing under the camera.
struct NotchRow<Left: View, Right: View>: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) { left; Spacer(minLength: 0) }.frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            HStack(spacing: 0) { Spacer(minLength: 0); right }.frame(maxWidth: .infinity)
        }
        .frame(height: height)
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var system: SystemMonitor

    var body: some View {
        VStack(spacing: 0) {
            NotchRow(notchWidth: model.notchWidth, height: model.notchHeight) {
                HStack(spacing: 6) {
                    ForEach(PanelTab.allCases, id: \.self) { tab in
                        TabButton(symbol: tab.symbol, selected: model.tab == tab) { model.tab = tab }
                    }
                }
            } right: {
                HStack(spacing: 12) {
                    if model.claudeEnabled && !model.activity.isEmpty {
                        ClaudeCounts(activity: model.activity, showWaiting: false)
                    }
                    if let battery = system.battery { BatteryLabel(battery: battery) }
                    TabButton(symbol: "gearshape", selected: false, help: L.t("Settings", "Настройки")) {
                        model.onOpenSettings()
                    }
                }
            }
            .padding(.horizontal, 14)

            switch model.tab {
            case .home: HomeView(model: model, system: system)
            }
        }
    }
}

struct TabButton: View {
    let symbol: String
    let selected: Bool
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(selected || hovering ? 1 : 0.6))
                .frame(width: 34, height: 24)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : (hovering ? 0.08 : 0))))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct BatteryLabel: View {
    let battery: BatteryState

    private var symbol: String {
        if battery.charging { return "battery.100percent.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(battery.percent)%").font(.system(size: 13, weight: .medium)).monospacedDigit()
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundColor(battery.charging ? .green : (battery.percent <= 10 ? .red : .white))
        }
        .foregroundColor(.white.opacity(0.75))
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var system: SystemMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ClockView()
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.vertical, 2)
            WidgetArea(model: model, system: system)
                .frame(width: 300)
                .padding(.leading, 20)
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .frame(height: 150, alignment: .top)
    }
}

struct ClockView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(ClockView.date(context.date))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                Text(ClockView.time(context.date))
                    .font(.system(size: 48, weight: .regular))
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
        }
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.russian ? "ru_RU" : "en_US")
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let s = f.string(from: d)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

struct WidgetArea: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var system: SystemMonitor

    private var widgets: [PanelWidget] {
        PanelWidget.allCases.filter { w in
            switch w {
            case .system: return true
            case .claude: return model.claudeEnabled
            case .codex: return model.claudeEnabled && !model.limits.codex.isEmpty
            }
        }
    }

    var body: some View {
        let list = widgets
        let current = list.contains(model.widget) ? model.widget : (list.first ?? .system)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(list, id: \.self) { w in
                    TabButton(symbol: w.symbol, selected: w == current, help: w.title) { model.widget = w }
                        .scaleEffect(0.85)
                }
                Spacer(minLength: 4)
                Text(title(current))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }
            switch current {
            case .system: SystemWidget(system: system)
            case .claude: ClaudeWidget(model: model)
            case .codex: CodexWidget(provider: model.limits.codex)
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ w: PanelWidget) -> String {
        if w == .claude, model.sessions.count > 2 {
            return L.t("\(model.sessions.count - 2) more", "Ещё \(model.sessions.count - 2)")
        }
        if w == .codex, !model.limits.codex.plan.isEmpty { return "Codex · \(model.limits.codex.plan)" }
        return w.title
    }
}

/// Label, bar, value: the line every widget is made of.
struct MeterRow: View {
    let label: String
    var fraction: Double?
    var color: Color = .white
    let value: String
    var trailing: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                .frame(width: 70, alignment: .leading).lineLimit(1)
            if let f = fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule().fill(color).frame(width: max(3, geo.size.width * CGFloat(min(max(f, 0), 1))))
                    }
                }
                .frame(width: 100, height: 5)
            }
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundColor(.white)
                .lineLimit(1)
            if !trailing.isEmpty {
                Text(trailing).font(.system(size: 12)).monospacedDigit().foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(height: 18)
    }
}

struct SystemWidget: View {
    @ObservedObject var system: SystemMonitor

    var body: some View {
        let s = system.stats
        VStack(alignment: .leading, spacing: 6) {
            MeterRow(label: L.t("CPU", "ЦП"), fraction: s.cpu, color: meterColor(s.cpu),
                     value: s.sampled ? "\(Int((s.cpu * 100).rounded()))%" : "—")
            let mem = s.memoryTotal > 0 ? Double(s.memoryUsed) / Double(s.memoryTotal) : 0
            MeterRow(label: L.t("Memory", "Память"), fraction: mem, color: meterColor(mem),
                     value: L.t("\(ByteFormat.gigabytes(Double(s.memoryUsed))) of \(ByteFormat.gigabytes(Double(s.memoryTotal), decimals: 0)) GB",
                                "\(ByteFormat.gigabytes(Double(s.memoryUsed))) из \(ByteFormat.gigabytes(Double(s.memoryTotal), decimals: 0)) ГБ"))
            let used = s.diskTotal > 0 ? 1 - Double(s.diskFree) / Double(s.diskTotal) : 0
            MeterRow(label: L.t("Disk", "Диск"), fraction: used, color: meterColor(used),
                     value: L.t("\(ByteFormat.gigabytes(Double(s.diskFree), decimals: 0)) GB free",
                                "\(ByteFormat.gigabytes(Double(s.diskFree), decimals: 0)) ГБ своб."))
            MeterRow(label: L.t("Network", "Сеть"), value: "↓ \(ByteFormat.rate(s.netIn))",
                     trailing: "↑ \(ByteFormat.rate(s.netOut))")
        }
        .onAppear { system.retain() }
        .onDisappear { system.release() }
    }

    private func meterColor(_ f: Double) -> Color { f >= 0.95 ? usageColor(90) : (f >= 0.88 ? usageColor(70) : .white) }
}

struct ClaudeWidget: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let windows = Array(model.limits.claude.windows.prefix(2))
            if windows.isEmpty {
                Text(L.t("No usage data yet", "Пока нет данных о лимитах"))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.5)).frame(height: 18)
            }
            ForEach(windows, id: \.self) { w in
                MeterRow(label: w.label, fraction: w.used / 100, color: w.used >= 70 ? usageColor(w.used) : .white,
                         value: LimitFormat.percent(w.used), trailing: LimitFormat.resetShort(w.resetsAt))
            }
            ForEach(model.sessions.prefix(2)) { row in
                SessionLine(row: row) { model.onOpenSession(row.id) }
            }
            if model.sessions.isEmpty {
                Text(L.t("No Claude Code sessions", "Сессий Claude Code нет"))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.4)).frame(height: 22)
            }
        }
    }
}

struct SessionLine: View {
    let row: ClaudeSessionRow
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    Image(systemName: "asterisk")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(color)
                    Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(status(context.date)).font(.system(size: 12)).monospacedDigit()
                        .foregroundColor(.white.opacity(0.55)).lineLimit(1)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 0.8 : 1)
        .onHover { hovering = $0 }
    }

    private var color: Color {
        switch row.state {
        case .waiting(let kind): return accent(kind)
        case .working: return claudeOrange
        case .done: return .white.opacity(0.5)
        }
    }

    private func status(_ now: Date) -> String {
        switch row.state {
        case .waiting(let kind):
            switch kind {
            case .question: return L.t("Asks", "Спрашивает")
            case .plan: return L.t("Plan ready", "План готов")
            default: return L.t("Needs permission", "Ждёт разрешения")
            }
        case .working(let since, let tool):
            let s = max(0, Int(now.timeIntervalSince(since)))
            let clock = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                  : String(format: "%d:%02d", s / 60, s % 60)
            return "\(ToolVerb.verb(tool)) · \(clock)"
        case .done(let at):
            let m = Int(now.timeIntervalSince(at) / 60)
            return m < 1 ? L.t("Done · just now", "Готово · только что")
                         : L.t("Done · \(m) min ago", "Готово · \(m) мин. назад")
        }
    }
}

enum ToolVerb {
    static func verb(_ tool: String) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return L.t("Editing", "Правит")
        case "Bash", "BashOutput": return L.t("Running", "Выполняет")
        case "Read", "Grep", "Glob", "LS": return L.t("Reading", "Читает")
        case "WebFetch", "WebSearch": return L.t("Searching", "Ищет")
        case "Task", "Agent": return L.t("Delegating", "Ведёт агентов")
        case "": return L.t("Thinking", "Думает")
        default: return L.t("Working", "Работает")
        }
    }
}

struct CodexWidget: View {
    let provider: ProviderLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(provider.windows.prefix(3), id: \.self) { w in
                MeterRow(label: w.label, fraction: w.used / 100, color: w.used >= 70 ? usageColor(w.used) : codexBlue,
                         value: LimitFormat.percent(w.used), trailing: LimitFormat.resetShort(w.resetsAt))
            }
            Text(LimitFormat.updated(provider.updated)).font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
        }
    }
}

// MARK: - Compact and banner

struct ClaudeCounts: View {
    let activity: ClaudeActivity
    var showWaiting = true

    var body: some View {
        HStack(spacing: 10) {
            if showWaiting && activity.waiting > 0 {
                count("hand.raised.fill", activity.waiting, claudeOrange)
            }
            if activity.working > 0 { count("arrow.triangle.2.circlepath", activity.working, .white.opacity(0.75)) }
            if activity.done > 0 { count("checkmark", activity.done, .green) }
        }
    }

    private func count(_ symbol: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text("\(n)").font(.system(size: 14, weight: .medium)).monospacedDigit()
        }
        .foregroundColor(color)
    }
}

/// Claude's asterisk; turns slowly while a session works.
struct ClaudeMark: View {
    var spinning: Bool
    var color: Color = claudeOrange
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(color)
            .rotationEffect(.degrees(angle))
            .onAppear { spin() }
            .onChange(of: spinning) { _ in spin() }
    }

    private func spin() {
        if spinning {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { angle = 0 }
        }
    }
}

/// Two lines: icon and label level with the notch, the message under it (new request, done, error).
struct NotchBanner: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let symbol: String
    let color: Color
    let label: String
    let headline: String
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            NotchRow(notchWidth: notchWidth, height: notchHeight) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundColor(color)
            } right: {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
            }
            .padding(.horizontal, 16)
            HStack(spacing: 6) {
                Text(headline).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                if !text.isEmpty {
                    Text("·").foregroundColor(.white.opacity(0.4))
                    Text(text).font(.system(size: 13)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 30)
            .padding(.bottom, 4)
        }
    }
}
