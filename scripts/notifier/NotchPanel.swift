import AppKit
import Combine
import SwiftUI

// A borderless panel glued to the MacBook notch.
//
//   wings     the notch continued sideways, same height and outline: Claude and Codex usage limits
//   banner    a glass pill under the notch: the waiting question / plan / permission, or a
//             short-lived "done" / error; as much text as fits
//   expanded  hover the banner → a large glass card with answer buttons;
//             hover the wings → limits with reset times
//
// Screens without a notch get the same layout at the top centre.

struct NotchItem: Identifiable {
    let id: String
    let sessionId: String
    let headline: String
    let card: Card
}

struct NotchInfo: Identifiable {
    let id = UUID().uuidString
    let sessionId: String
    let headline: String
    let subtitle: String
    let text: String
    let kind: CardKind
}

enum NotchExpansion { case request, limits }

final class NotchModel: ObservableObject {
    @Published var items: [NotchItem] = []
    @Published var info: NotchInfo?
    @Published var expanded: NotchExpansion?
    @Published var selectedId: String?
    @Published var editing = false
    @Published var limits = LimitsSnapshot()
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32

    var onDecision: (String, Decision) -> Void = { _, _ in }
    var onOpen: (String) -> Void = { _ in }
    var onDismiss: (String) -> Void = { _ in }
    var onOpenSession: (String) -> Void = { _ in }
    var onHover: (NotchZone, Bool) -> Void = { _, _ in }
    /// A text field is about to take input: the panel must become key (without activating the app).
    var onWantsKeyboard: () -> Void = {}

    var current: NotchItem? { items.first { $0.id == selectedId } ?? items.first }
    var currentIndex: Int { items.firstIndex { $0.id == current?.id } ?? 0 }
    var isEmpty: Bool { items.isEmpty && info == nil && !limits.hasData }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let i = (currentIndex + delta + items.count) % items.count
        selectedId = items[i].id
    }
}

enum NotchZone { case wings, banner, card }

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }  // text fields for "own answer" / plan feedback
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchController {
    let model = NotchModel()
    /// The user hovered or opened a request card: no fallback notification needed.
    var onNoticed: (String) -> Void = { _ in }

    private let panel: NotchPanel
    private let hosting: FirstMouseHostingView<NotchRootView>
    private var subscription: AnyCancellable?
    private var layoutScheduled = false
    private var hovered = Set<NotchZone>()
    private var bannerShownAt = Date.distantPast
    private var collapseWork: DispatchWorkItem?
    private var infoWork: DispatchWorkItem?

    init() {
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true

        hosting = FirstMouseHostingView(rootView: NotchRootView(model: model))
        panel.contentView = hosting

        model.onWantsKeyboard = { [weak self] in self?.panel.makeKey() }
        model.onHover = { [weak self] zone, inside in self?.hover(zone, inside) }
        subscription = model.objectWillChange.sink { [weak self] _ in self?.scheduleLayout() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.updateGeometry()
            self?.scheduleLayout()
        }
        updateGeometry()
    }

    // MARK: Content

    func setItems(_ items: [NotchItem]) {
        model.items = items
        if let selected = model.selectedId, !items.contains(where: { $0.id == selected }) {
            model.selectedId = items.first?.id
        }
        if items.isEmpty {
            if model.expanded == .request { model.expanded = nil }
            model.editing = false
            if panel.isKeyWindow { panel.resignKey() }
        }
    }

    /// Show a new request's banner. The card the user may be reading stays selected.
    func present(_ id: String) {
        if model.expanded != .request { model.selectedId = id }
        bannerShownAt = Date()
    }

    func showInfo(_ info: NotchInfo, seconds: Double) {
        model.info = info
        infoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clearInfo(info.id) }
        infoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func clearInfo(_ id: String) {
        guard model.info?.id == id else { return }
        if hovered.contains(.banner) {
            // Keep it while the pointer is on it; retry shortly.
            showInfo(model.info!, seconds: 2)
        } else {
            model.info = nil
        }
    }

    func setLimits(_ limits: LimitsSnapshot) { model.limits = limits }

    // MARK: Hover

    private func hover(_ zone: NotchZone, _ inside: Bool) {
        if inside { hovered.insert(zone) } else { hovered.remove(zone) }
        collapseWork?.cancel()
        if inside {
            switch zone {
            case .wings:
                if model.expanded == nil && model.limits.hasData { model.expanded = .limits }
            case .banner:
                // Pointer events in the first moments are the banner sliding under the cursor.
                if Date().timeIntervalSince(bannerShownAt) < 0.6 { return }
                if let item = model.current {
                    model.expanded = .request
                    onNoticed(item.id)
                }
            case .card:
                break
            }
            return
        }
        guard hovered.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.hovered.isEmpty, !self.model.editing else { return }
            self.model.expanded = nil
            if self.panel.isKeyWindow { self.panel.resignKey() }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: Layout

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main
    }

    private func updateGeometry() {
        guard let screen = screen else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = max(0, right.minX - left.maxX)
            model.notchHeight = max(screen.safeAreaInsets.top, 24)
        } else {
            model.notchWidth = 0
            model.notchHeight = NSStatusBar.system.thickness
        }
    }

    private func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.layoutScheduled = false
            self?.layout()
        }
    }

    private func layout() {
        guard let screen = screen else { return }
        if model.isEmpty {
            panel.orderOut(nil)
            return
        }
        let size = hosting.fittingSize
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            let state = model.expanded.map { "\($0)" } ?? (model.current != nil || model.info != nil ? "banner" : "wings")
            log("[notch] \(state) items=\(model.items.count) frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(spacing: 6) {
            WingsView(model: model)
                .onHover { model.onHover(.wings, $0) }
            dropdown
        }
        .padding(.bottom, 10)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.current?.id)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.info?.id)
    }

    @ViewBuilder private var dropdown: some View {
        switch model.expanded {
        case .request?:
            if let item = model.current {
                CardView(item: item, model: model)
                    .id(item.id)
                    .padding(18)
                    .frame(width: 540)
                    .glassCard(radius: 26)
                    .onHover { model.onHover(.card, $0) }
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            }
        case .limits?:
            LimitsDetailView(limits: model.limits)
                .padding(16)
                .frame(width: 420)
                .glassCard(radius: 22)
                .onHover { model.onHover(.card, $0) }
                .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
        case nil:
            if let item = model.current {
                BannerView(symbol: Texts.symbol(item.card.kind), color: accent(item.card.kind),
                           headline: item.headline, subtitle: Texts.kindLabel(item.card),
                           text: BannerView.summary(item.card), extra: model.items.count > 1 ? "+\(model.items.count - 1)" : "")
                    .frame(width: 440)
                    .glassCard(radius: 20)
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                    .onContinuousHover { phase in
                        // Expand on real pointer movement only: a banner that pops up under a
                        // resting cursor must not turn into the big card by itself.
                        switch phase {
                        case .active: model.onHover(.banner, true)
                        case .ended: model.onHover(.banner, false)
                        }
                    }
                    .onTapGesture { model.onHover(.banner, true) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let info = model.info {
                BannerView(symbol: Texts.symbol(info.kind), color: accent(info.kind),
                           headline: info.headline, subtitle: info.subtitle, text: info.text, extra: "")
                    .frame(width: 440)
                    .glassCard(radius: 20)
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                    .onHover { model.onHover(.banner, $0) }
                    .onTapGesture { model.onOpenSession(info.sessionId) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Wings (limits)
//
// Nothing can be drawn inside the cutout itself (there are no pixels under the camera), so
// the limits sit in "wings" that continue the notch sideways at exactly its height. The
// outline copies the notch: concave shoulders flowing into the top edge, rounded bottom corners.

struct WingsView: View {
    @ObservedObject var model: NotchModel

    static let wing: CGFloat = 62
    static let shoulder: CGFloat = 6
    static let bottomRadius: CGFloat = 10

    var body: some View {
        let shape = NotchOutline(shoulder: WingsView.shoulder, bottomRadius: WingsView.bottomRadius)
        HStack(spacing: 0) {
            WingLimits(symbol: "sparkle", color: claudeOrange, limits: model.limits.claude)
                .frame(width: WingsView.wing)
            Spacer(minLength: max(model.notchWidth, 24))
            WingLimits(symbol: "chevron.left.forwardslash.chevron.right",
                       color: Color(red: 0.55, green: 0.8, blue: 0.95), limits: model.limits.codex)
                .frame(width: WingsView.wing)
        }
        .padding(.horizontal, WingsView.shoulder)
        .frame(width: max(model.notchWidth, 24) + 2 * (WingsView.wing + WingsView.shoulder), height: model.notchHeight)
        .background(shape.fill(Color.black))
        .contentShape(shape)
    }
}

struct WingLimits: View {
    let symbol: String
    let color: Color
    let limits: ProviderLimits

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(limits.isEmpty ? .white.opacity(0.25) : color)
            if limits.isEmpty {
                Text("—").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.3))
            } else {
                VStack(alignment: .leading, spacing: -2) {
                    ForEach(Array(limits.windows.prefix(2).enumerated()), id: \.offset) { index, w in
                        Text(LimitFormat.percent(w.used))
                            .font(.system(size: index == 0 ? 11 : 9, weight: index == 0 ? .bold : .semibold, design: .rounded))
                            .foregroundColor(usageColor(w.used).opacity(index == 0 ? 1 : 0.6))
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

/// The MacBook notch outline, stretched: small concave shoulders where it meets the top edge
/// of the screen, rounded bottom corners.
struct NotchOutline: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat

    func path(in r: CGRect) -> Path {
        let s = shoulder, b = min(bottomRadius, r.height - s)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + s, y: r.minY + s), control: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + s + b, y: r.maxY), control: CGPoint(x: r.minX + s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - b), control: CGPoint(x: r.maxX - s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.closeSubpath()
        return p
    }
}

func usageColor(_ used: Double) -> Color {
    if used >= 90 { return Color(red: 1, green: 0.35, blue: 0.3) }
    if used >= 70 { return Color(red: 1, green: 0.72, blue: 0.3) }
    return .white
}

struct LimitsDetailView: View {
    let limits: LimitsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Claude", color: claudeOrange, symbol: "sparkle", provider: limits.claude)
            section(limits.codex.plan.isEmpty ? "Codex" : "Codex · \(limits.codex.plan)",
                    color: Color(red: 0.55, green: 0.8, blue: 0.95),
                    symbol: "chevron.left.forwardslash.chevron.right", provider: limits.codex)
        }
    }

    private func section(_ title: String, color: Color, symbol: String, provider: ProviderLimits) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundColor(color)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Text(LimitFormat.updated(provider.updated)).font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
            }
            if provider.isEmpty {
                Text(L.t("No data yet", "Пока нет данных")).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
            }
            ForEach(provider.windows, id: \.self) { w in
                HStack(spacing: 10) {
                    Text(w.label).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                        .frame(width: 52, alignment: .leading)
                    UsageBar(used: w.used, color: color).frame(width: 130, height: 6)
                    Text(LimitFormat.percent(w.used)).font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundColor(usageColor(w.used)).frame(width: 40, alignment: .trailing)
                    Text(LimitFormat.resetIn(w.resetsAt)).font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct UsageBar: View {
    let used: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(used >= 70 ? usageColor(used) : color)
                    .frame(width: max(3, geo.size.width * CGFloat(min(used, 100) / 100)))
            }
        }
    }
}

// MARK: - Banner

struct BannerView: View {
    let symbol: String
    let color: Color
    let headline: String
    let subtitle: String
    let text: String
    let extra: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundColor(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(headline).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Spacer(minLength: 4)
                    if !extra.isEmpty {
                        Text(extra).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.6))
                    }
                }
                Text(subtitle).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func summary(_ card: Card) -> String {
        switch card.kind {
        case .question: return card.questions.first?.question ?? ""
        case .plan: return card.text
        case .permission: return card.detail.isEmpty ? card.command : card.detail
        default: return card.text
        }
    }
}

// MARK: - Shapes and glass

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct GlassCard: ViewModifier {
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)  // glassEffect exists only in the macOS 26 SDK
        if #available(macOS 26.0, *) {
            // Liquid Glass with a dark tint: translucent, but white text stays readable on light windows.
            content.glassEffect(.regular.tint(Color.black.opacity(0.5)), in: shape)
        } else {
            material(content, shape)
        }
        #else
        material(content, shape)
        #endif
    }

    private func material(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background(shape.fill(Color.black.opacity(0.45)))
            .background(VisualEffectBlur().clipShape(shape))
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

extension View {
    func glassCard(radius: CGFloat) -> some View { modifier(GlassCard(radius: radius)) }
}
