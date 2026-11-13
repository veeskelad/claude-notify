import AppKit
import SwiftUI

// The System tab (load in detail and the apps behind it) and the compact alert the notch grows
// into when the Mac needs a glance: sustained CPU load, memory pressure, heat, a nearly full disk.

struct SystemTab: View {
    @ObservedObject var system: SystemMonitor
    @State private var byMemory = false

    var body: some View {
        let s = system.stats
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L.t("CPU", "ЦП")).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                    Text(s.sampled ? "\(Int((s.cpu * 100).rounded()))%" : "—")
                        .font(.system(size: 24, weight: .medium)).monospacedDigit().foregroundColor(loadColor(s.cpu))
                    Text(L.t("\(s.cores) cores", "ядер: \(s.cores)")).font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }
                Sparkline(values: s.cpuHistory, color: loadColor(s.cpu))
                    .frame(height: 32)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        stat(L.t("Memory", "Память"),
                             L.t("\(ByteFormat.gigabytes(Double(s.memoryUsed))) of \(ByteFormat.gigabytes(Double(s.memoryTotal), decimals: 0)) GB",
                                 "\(ByteFormat.gigabytes(Double(s.memoryUsed))) из \(ByteFormat.gigabytes(Double(s.memoryTotal), decimals: 0)) ГБ"))
                        stat(L.t("Pressure", "Давление"), s.pressure.label, color: pressureColor(s.pressure))
                    }
                    GridRow {
                        stat(L.t("Swap", "Своп"), ByteFormat.size(s.swapUsed),
                             color: s.swapUsed > 4 * 1_073_741_824 ? usageColor(70) : .white)
                        stat(L.t("Heat", "Нагрев"), s.thermal.label, color: thermalColor(s.thermal))
                    }
                    GridRow {
                        stat(L.t("Disk", "Диск"), L.t("\(ByteFormat.gigabytes(Double(s.diskFree), decimals: 0)) GB free",
                                                      "\(ByteFormat.gigabytes(Double(s.diskFree), decimals: 0)) ГБ своб."),
                             color: s.diskFree < 10 * 1_073_741_824 ? usageColor(70) : .white)
                        stat(L.t("Network", "Сеть"), "↓\(ByteFormat.rate(s.netIn)) ↑\(ByteFormat.rate(s.netOut))")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.vertical, 2).padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    SmallToggle(title: L.t("CPU", "ЦП"), selected: !byMemory) { byMemory = false }
                    SmallToggle(title: L.t("Memory", "Память"), selected: byMemory) { byMemory = true }
                    Spacer(minLength: 4)
                    TabButton(symbol: "waveform.path.ecg.rectangle", selected: false,
                              help: L.t("Activity Monitor", "Мониторинг системы")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                    .scaleEffect(0.85)
                }
                let apps = Array((byMemory ? s.topMemory : s.topCPU).prefix(5))
                if apps.isEmpty {
                    Text(byMemory ? "—" : L.t("Nothing busy", "Никто не грузит"))
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.4)).frame(height: 22)
                }
                ForEach(apps) { app in
                    AppRow(app: app, value: byMemory ? ByteFormat.size(app.memory) : "\(Int(app.cpu.rounded()))%",
                           hot: byMemory ? app.memory > 3 * 1_073_741_824 : app.cpu >= 80)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 196)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(height: 214, alignment: .top)
        .onAppear { system.retain() }
        .onDisappear { system.release() }
    }

    private func stat(_ label: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.45))
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundColor(color).lineLimit(1)
        }
    }
}

func loadColor(_ f: Double) -> Color { f >= 0.9 ? usageColor(90) : (f >= 0.7 ? usageColor(70) : .white) }

func pressureColor(_ p: MemoryPressure) -> Color {
    switch p {
    case .normal: return .white
    case .warning: return usageColor(70)
    case .critical: return usageColor(90)
    }
}

func thermalColor(_ t: ProcessInfo.ThermalState) -> Color {
    switch t {
    case .nominal: return .white
    case .fair: return usageColor(70).opacity(0.8)
    case .serious: return usageColor(70)
    default: return usageColor(90)
    }
}

struct Sparkline: View {
    let values: [Double]   // 0...1, newest last
    let color: Color
    static let capacity = 60

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = w / CGFloat(Sparkline.capacity - 1)
            let start = w - step * CGFloat(max(values.count - 1, 0))
            let points = values.enumerated().map { i, v in
                CGPoint(x: start + CGFloat(i) * step, y: h - CGFloat(min(max(v, 0), 1)) * (h - 2) - 1)
            }
            ZStack {
                Path { p in   // 50% guide
                    p.move(to: CGPoint(x: 0, y: h / 2))
                    p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: h))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SmallToggle: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white.opacity(selected ? 1 : 0.5))
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0)))
        }
        .buttonStyle(.plain)
    }
}

struct AppRow: View {
    let app: AppUsage
    let value: String
    let hot: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(app.path))
                .resizable().frame(width: 16, height: 16)
            Text(app.name).font(.system(size: 12.5)).foregroundColor(.white).lineLimit(1)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundColor(hot ? usageColor(70) : .white.opacity(0.7))
        }
        .frame(height: 20)
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let image = cache[path] { return image }
        let image: NSImage
        if path.hasSuffix(".app") {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        }
        cache[path] = image
        return image
    }
}

// MARK: - Compact alert

extension SystemAlert {
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .thermal: return "thermometer.high"
        case .disk: return "internaldrive"
        }
    }

    var color: Color { critical ? usageColor(90) : usageColor(70) }

    /// "CPU 92%", "Memory is short", "The Mac is hot", "Disk: 6 GB left"
    var title: String {
        switch self {
        case .cpu(let load, _): return L.t("CPU \(Int((load * 100).rounded()))%", "ЦП \(Int((load * 100).rounded()))%")
        case .memory(let p, _): return p == .critical ? L.t("Out of memory", "Память кончается") : L.t("Memory is short", "Памяти мало")
        case .thermal(let t): return t == .critical ? L.t("Overheating", "Перегрев") : L.t("The Mac is hot", "Mac нагрелся")
        case .disk(let free): return L.t("Disk: \(ByteFormat.gigabytes(Double(free), decimals: 0)) GB left",
                                         "Диск: \(ByteFormat.gigabytes(Double(free), decimals: 0)) ГБ")
        }
    }

    /// The app behind it, if known.
    var culprit: String {
        switch self {
        case .cpu(_, let app), .memory(_, let app): return app
        default: return ""
        }
    }
}

struct SystemAlertCompact: View {
    let alert: SystemAlert
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        NotchRow(notchWidth: notchWidth, height: notchHeight) {
            Image(systemName: alert.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(alert.color)
                .symbolRenderingMode(.hierarchical)
        } right: {
            HStack(spacing: 5) {
                Text(alert.title).font(.system(size: 13, weight: .semibold)).foregroundColor(alert.color)
                if !alert.culprit.isEmpty {
                    Text("·").foregroundColor(.white.opacity(0.4))
                    Text(alert.culprit).font(.system(size: 13)).foregroundColor(.white.opacity(0.75))
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
    }
}
