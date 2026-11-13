import AppKit
import SwiftUI

// The panel that opens from the notch, and the small states the notch grows into.
//
//   panel     a row level with the notch (tabs on the left, settings on the right),
//             then the tab: Home = Claude on the left, the Mac at a glance on the right;
//             System = load in detail (SystemViews.swift). Nothing the menu bar already shows.
//   compact   the notch a little wider, an icon on each side (Claude at work: ✋ waiting ⟳ working ✓ done)
//   banner    two lines: icon and label level with the notch, the message under it
//
// Everything is drawn in one black shape that continues the cutout, so it reads as the notch
// itself growing rather than a window under it.

enum PanelTab: String, CaseIterable {
    case home, notes, system

    var symbol: String {
        switch self {
        case .home: return "house"
        case .notes: return "checklist"
        case .system: return "cpu"
        }
    }

    var title: String {
        switch self {
        case .home: return L.t("Home", "Главная")
        case .notes: return L.t("Notes and tasks", "Заметки и задачи")
        case .system: return L.t("System", "Система")
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

/// The panel's width: the same as the request card, so the notch keeps one size when it opens.
let panelWidth: CGFloat = 540

struct PanelView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var system: SystemMonitor

    var body: some View {
        VStack(spacing: 0) {
            NotchRow(notchWidth: model.notchWidth, height: model.notchHeight) {
                HStack(spacing: 4) {
                    ForEach(PanelTab.allCases, id: \.self) { tab in
                        TabButton(symbol: tab.symbol, selected: model.tab == tab, help: tab.title) { model.tab = tab }
                    }
                }
            } right: {
                HStack(spacing: 10) {
                    TabButton(symbol: "gearshape", selected: false, help: L.t("Settings", "Настройки")) {
                        model.onOpenSettings()
                    }
                }
            }
            .padding(.horizontal, 12)

            switch model.tab {
            case .home: HomeView(model: model, system: system)
            case .notes: NotesTab(model: model, notes: model.notes)
            case .system: SystemTab(system: system)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(selected || hovering ? 1 : 0.6))
                .frame(width: 32, height: 24)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : (hovering ? 0.08 : 0))))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Home
//
// Nothing the menu bar already shows (time, battery): Claude on the left, the Mac on the right.

struct HomeView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var system: SystemMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if model.claudeEnabled {
                ClaudeColumn(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.horizontal, 16)
            }
            SystemColumn(system: system) { model.tab = .system }
                .frame(width: model.claudeEnabled ? 200 : nil)
                .frame(maxWidth: model.claudeEnabled ? nil : .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(height: 150, alignment: .top)
    }
}

struct ColumnHeader: View {
    let title: String
    var trailing = ""
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            if action != nil {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.3))
            }
            Spacer(minLength: 4)
            Text(trailing).font(.system(size: 11)).foregroundColor(.white.opacity(0.4)).lineLimit(1)
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

/// Label, bar, value: the line both columns are made of.
struct MeterRow: View {
    let label: String
    var fraction: Double?
    var color: Color = .white
    let value: String
    var trailing: String = ""
    var labelWidth: CGFloat = 58

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                .frame(width: labelWidth, alignment: .leading).lineLimit(1)
            if let f = fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule().fill(color).frame(width: max(3, geo.size.width * CGFloat(min(max(f, 0), 1))))
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity)
                }
                .frame(minWidth: 40)
            } else {
                Spacer(minLength: 0)
            }
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundColor(.white)
                .lineLimit(1).fixedSize()
            if !trailing.isEmpty {
                Text(trailing).font(.system(size: 11.5)).monospacedDigit().foregroundColor(.white.opacity(0.5))
                    .lineLimit(1).fixedSize()
            }
        }
        .frame(height: 18)
    }
}

/// Claude's usage, Codex's under it when it is on. Sessions are not listed: the notch speaks
/// up for the ones that need an answer.
struct ClaudeColumn: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let claude = Array(model.limits.claude.windows.prefix(2))
        let codex = model.codexEnabled ? model.limits.codex.windows.first : nil
        VStack(alignment: .leading, spacing: 5) {
            ColumnHeader(title: "Claude", trailing: LimitFormat.updated(model.limits.claude.updated))
            if claude.isEmpty && codex == nil {
                Text(L.t("No usage data yet", "Пока нет данных о лимитах"))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.5)).frame(height: 18)
            }
            ForEach(claude, id: \.self) { w in
                MeterRow(label: w.label, fraction: w.used / 100, color: w.used >= 70 ? usageColor(w.used) : .white,
                         value: LimitFormat.percent(w.used), trailing: LimitFormat.resetShort(w.resetsAt))
            }
            if let w = codex {
                MeterRow(label: "Codex", fraction: w.used / 100, color: w.used >= 70 ? usageColor(w.used) : codexBlue,
                         value: LimitFormat.percent(w.used), trailing: LimitFormat.resetShort(w.resetsAt))
            }
        }
    }
}

/// The Mac at a glance; the header opens the System tab.
struct SystemColumn: View {
    @ObservedObject var system: SystemMonitor
    let open: () -> Void

    var body: some View {
        let s = system.stats
        VStack(alignment: .leading, spacing: 5) {
            ColumnHeader(title: L.t("System", "Система"), trailing: system.alert?.title ?? "", action: open)
            MeterRow(label: L.t("CPU", "ЦП"), fraction: s.cpu, color: loadColor(s.cpu),
                     value: s.sampled ? "\(Int((s.cpu * 100).rounded()))%" : "—", labelWidth: 52)
            let mem = s.memoryTotal > 0 ? Double(s.memoryUsed) / Double(s.memoryTotal) : 0
            MeterRow(label: L.t("Memory", "Память"), fraction: mem, color: pressureColor(s.pressure),
                     value: L.t("\(ByteFormat.gigabytes(Double(s.memoryUsed)))/\(ByteFormat.gigabytes(Double(s.memoryTotal), decimals: 0)) GB",
                                "\(ByteFormat.gigabytes(Double(s.memoryUsed)))/\(ByteFormat.gigabytes(Double(s.memoryTotal), decimals: 0)) ГБ"),
                     labelWidth: 52)
            let used = s.diskTotal > 0 ? 1 - Double(s.diskFree) / Double(s.diskTotal) : 0
            MeterRow(label: L.t("Disk", "Диск"), fraction: used,
                     color: s.diskFree < 10 * 1_073_741_824 ? usageColor(70) : .white,
                     value: L.t("\(ByteFormat.gigabytes(Double(s.diskFree), decimals: 0)) GB", "\(ByteFormat.gigabytes(Double(s.diskFree), decimals: 0)) ГБ"),
                     labelWidth: 52)
            if let app = s.topCPU.first, app.cpu >= 20 {
                HStack(spacing: 6) {
                    Image(nsImage: AppIcons.icon(app.path)).resizable().frame(width: 14, height: 14)
                    Text(app.name).font(.system(size: 12)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Int(app.cpu.rounded()))%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundColor(app.cpu >= 80 ? usageColor(70) : .white.opacity(0.7))
                }
                .frame(height: 18)
            } else {
                MeterRow(label: L.t("Network", "Сеть"), value: "↓ \(ByteFormat.rate(s.netIn))", labelWidth: 52)
            }
        }
        .onAppear { system.retain() }
        .onDisappear { system.release() }
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
