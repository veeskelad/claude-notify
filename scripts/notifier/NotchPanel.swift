import AppKit
import Combine
import SwiftUI

// A borderless panel glued to the MacBook notch.
//
//   rim     a hairline around the notch outline: Claude (left) and Codex (right) usage;
//           a pulsing dot in the middle while a question / plan / permission waits
//   island  one glass surface under the notch that morphs between states:
//             banner  a new request (6 s, then it folds into the dot) or a short "done" / error
//             card    the request with answer buttons (point at the notch or the banner)
//             limits  usage with reset times (point at the notch when nothing waits)
//
// The window never changes size: every transition happens inside SwiftUI, so nothing jumps.
// Transparent parts of the window let clicks through to the apps below.

struct NotchItem: Identifiable {
    let id: String
    let sessionId: String
    let headline: String
    let card: Card
    /// The session is off screen: the item gets a banner and the rim dot. Others only show on hover.
    let announced: Bool
}

struct NotchInfo: Identifiable {
    let id = UUID().uuidString
    let sessionId: String
    let headline: String
    let subtitle: String
    let text: String
    let kind: CardKind
    var icon: NSImage? = nil
    var appURL: URL? = nil
}

enum NotchExpansion { case request, limits }

enum NotchMotion {
    /// One spring for everything, close to the system's own panel animations.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Leaving is quicker than arriving, like system popovers.
    static let exit = Animation.spring(response: 0.15, dampingFraction: 1.0)
    static let fill = Animation.easeInOut(duration: 0.8)
}

final class NotchModel: ObservableObject {
    @Published var items: [NotchItem] = []
    @Published var info: NotchInfo?
    @Published var expanded: NotchExpansion?
    /// A request's banner is out; after a few seconds it folds into the dot on the rim.
    @Published var bannerVisible = false
    @Published var selectedId: String?
    @Published var editing = false
    @Published var limits = LimitsSnapshot()
    @Published var badges: [AppBadge] = []
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32

    var onDecision: (String, Decision) -> Void = { _, _ in }
    var onOpen: (String) -> Void = { _ in }
    var onDismiss: (String) -> Void = { _ in }
    var onOpenSession: (String) -> Void = { _ in }
    var onHover: (NotchZone, Bool) -> Void = { _, _ in }
    /// A text field is about to take input: the panel must become key (without activating the app).
    var onWantsKeyboard: () -> Void = {}

    var current: NotchItem? { items.first { $0.id == selectedId } ?? items.first(where: \.announced) ?? items.first }
    var announced: NotchItem? { items.first(where: \.announced) }
    var currentIndex: Int { items.firstIndex { $0.id == current?.id } ?? 0 }
    var isEmpty: Bool { items.isEmpty && info == nil && !limits.hasData && badges.isEmpty }
    var hasOverview: Bool { limits.hasData || !badges.isEmpty }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let i = (currentIndex + delta + items.count) % items.count
        withAnimation(NotchMotion.spring) { selectedId = items[i].id }
    }
}

enum NotchZone { case notch, banner, card }

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

    /// How long a request's banner stays out before folding into the rim dot.
    static let bannerSeconds: Double = 6
    /// Room for the largest card; the window keeps this size for good.
    static let islandRoom = CGSize(width: 600, height: 540)

    private let panel: NotchPanel
    private let hosting: FirstMouseHostingView<NotchRootView>
    private var visibility: AnyCancellable?
    private var hovered = Set<NotchZone>()
    private var bannerShownAt = Date.distantPast
    private var collapseWork: DispatchWorkItem?
    private var infoWork: DispatchWorkItem?
    private var bannerWork: DispatchWorkItem?

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
        // Only showing/hiding the window depends on content; its frame depends on the screen alone.
        visibility = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.placePanel() }
        placePanel()
    }

    private func animate(_ changes: () -> Void) { withAnimation(NotchMotion.spring, changes) }

    // MARK: Content

    func setItems(_ items: [NotchItem]) {
        let ids = items.map(\.id)
        let key = { (list: [NotchItem]) in list.map { "\($0.id):\($0.announced)" } }
        guard key(items) != key(model.items) else { return }   // evaluate() calls this every second
        animate {
            model.items = items
            if let selected = model.selectedId, !ids.contains(selected) { model.selectedId = ids.first }
            if !items.contains(where: \.announced) { model.bannerVisible = false }
            if items.isEmpty {
                if model.expanded == .request { model.expanded = nil }
                model.editing = false
            }
        }
        if items.isEmpty, panel.isKeyWindow { panel.resignKey() }
    }

    /// Show a new request's banner for a few seconds; then only the rim dot marks it.
    /// The card the user may be reading stays selected.
    func present(_ id: String) {
        bannerShownAt = Date()
        if model.expanded == .limits {
            // The user is pointing at the notch right now: show the question itself.
            animate {
                model.selectedId = id
                model.expanded = .request
            }
            onNoticed(id)
            return
        }
        animate {
            if model.expanded != .request { model.selectedId = id }
            model.bannerVisible = true
        }
        scheduleBannerFold(after: NotchController.bannerSeconds)
    }

    /// Open a request's card (from a notification click).
    func openRequest(_ id: String) {
        animate {
            model.selectedId = id
            model.expanded = .request
            model.bannerVisible = false
        }
    }

    /// Dev aid for screenshots (see Coordinator's "debug" message).
    func setExpanded(_ expansion: NotchExpansion?) { animate { model.expanded = expansion } }

    private func scheduleBannerFold(after seconds: Double) {
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.hovered.contains(.banner) {
                self.scheduleBannerFold(after: 2)   // not while the pointer is on it
            } else {
                self.animate { self.model.bannerVisible = false }
            }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func showInfo(_ info: NotchInfo, seconds: Double) {
        animate { model.info = info }
        infoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clearInfo(info.id) }
        infoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func clearInfo(_ id: String) {
        guard let info = model.info, info.id == id else { return }
        if hovered.contains(.banner) {
            showInfo(info, seconds: 2)   // keep it while the pointer is on it
        } else {
            animate { model.info = nil }
        }
    }

    func setLimits(_ limits: LimitsSnapshot) {
        withAnimation(NotchMotion.fill) { model.limits = limits }
    }

    func setBadges(_ badges: [AppBadge]) { animate { model.badges = badges } }

    /// A Dock counter appeared or grew: a short banner with the app's icon.
    func showBadge(_ badge: AppBadge) {
        let text = badge.count.map { L.t("\($0) unread", "Непрочитанных: \($0)") } ?? L.t("New activity", "Есть новое")
        showInfo(NotchInfo(sessionId: "", headline: badge.name, subtitle: L.t("Notifications", "Уведомления"),
                           text: text, kind: .attention, icon: badge.icon, appURL: badge.url), seconds: 5)
    }

    // MARK: Hover

    private func hover(_ zone: NotchZone, _ inside: Bool) {
        let changed = inside ? hovered.insert(zone).inserted : hovered.remove(zone) != nil
        guard changed else { return }
        collapseWork?.cancel()
        if inside {
            switch zone {
            case .notch:
                // Pointing at the notch: a waiting question first, otherwise the limits.
                if let item = model.current {
                    if model.expanded != .request {
                        log("[hover] notch → card")
                        animate { model.expanded = .request; model.bannerVisible = false }
                    }
                    onNoticed(item.id)
                } else if model.expanded == nil && model.hasOverview {
                    animate { model.expanded = .limits }
                }
            case .banner:
                // Pointer events in the first moments are the banner sliding under the cursor.
                guard Date().timeIntervalSince(bannerShownAt) > 0.6, let item = model.current,
                      model.expanded == nil, model.bannerVisible else { return }
                log("[hover] banner → card")
                animate { model.expanded = .request; model.bannerVisible = false }
                onNoticed(item.id)
            case .card:
                break
            }
            return
        }
        guard hovered.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.hovered.isEmpty, !self.model.editing else { return }
            withAnimation(NotchMotion.exit) { self.model.expanded = nil }
            if self.panel.isKeyWindow { self.panel.resignKey() }
        }
        collapseWork = work
        // The overview goes at once (the pause only bridges notch → panel); a card with buttons
        // forgives a brief slip of the pointer.
        let delay = model.expanded == .request ? 0.15 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Window

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main
    }

    private func placePanel() {
        guard let screen = screen else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = max(0, right.minX - left.maxX)
            model.notchHeight = max(screen.safeAreaInsets.top, 24)
        } else {
            model.notchWidth = 0
            model.notchHeight = NSStatusBar.system.thickness
        }
        let size = NotchController.islandRoom
        let height = model.notchHeight + size.height
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - height,
                           width: size.width, height: height)
        panel.setFrame(frame, display: true)
        log("[notch] panel \(Int(frame.width))x\(Int(frame.height)), notch \(Int(model.notchWidth))x\(Int(model.notchHeight))")
        updateVisibility()
    }

    private func updateVisibility() {
        if model.isEmpty {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(spacing: 6) {
            NotchRimView(model: model)
                .onHover { model.onHover(.notch, $0) }
            IslandView(model: model)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

enum IslandMode: Equatable { case hidden, banner, info, card, limits }

/// One glass surface that morphs between banner, card and limits instead of swapping views,
/// so size changes animate as one continuous shape.
struct IslandView: View {
    @ObservedObject var model: NotchModel

    private var mode: IslandMode {
        switch model.expanded {
        case .request?: if model.current != nil { return .card }
        case .limits?: return .limits
        case nil: break
        }
        if model.announced != nil && model.bannerVisible { return .banner }
        if model.info != nil { return .info }
        return .hidden
    }

    var body: some View {
        let mode = self.mode
        let radius: CGFloat = mode == .card ? 26 : (mode == .limits ? 22 : 20)
        let width: CGFloat = mode == .card ? 540 : (mode == .limits ? 420 : 440)
        ZStack(alignment: .top) {
            switch mode {
            case .card:
                if let item = model.current {
                    CardView(item: item, model: model)
                        .id(item.id)
                        .padding(18)
                        .transition(.opacity)
                }
            case .limits:
                OverviewView(model: model)
                    .padding(16)
                    .transition(.opacity)
            case .banner:
                if let item = model.announced {
                    BannerView(symbol: Texts.symbol(item.card.kind), color: accent(item.card.kind),
                               headline: item.headline, subtitle: Texts.kindLabel(item.card),
                               text: BannerView.summary(item.card),
                               extra: model.items.count > 1 ? "+\(model.items.count - 1)" : "")
                        .contentShape(Rectangle())
                        .onTapGesture { model.onHover(.banner, true) }
                        .transition(.opacity)
                }
            case .info:
                if let info = model.info {
                    BannerView(symbol: Texts.symbol(info.kind), color: accent(info.kind),
                               headline: info.headline, subtitle: info.subtitle, text: info.text, extra: "",
                               icon: info.icon)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let url = info.appURL { NSWorkspace.shared.open(url) } else { model.onOpenSession(info.sessionId) }
                        }
                        .transition(.opacity)
                }
            case .hidden:
                Color.clear.frame(height: 56)
            }
        }
        .frame(width: width, alignment: .top)
        .glassCard(radius: radius)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // Hidden: tucked up into the notch, small and transparent; it grows out of it.
        .scaleEffect(mode == .hidden ? 0.6 : 1, anchor: .top)
        .offset(y: mode == .hidden ? -24 : 0)
        .opacity(mode == .hidden ? 0 : 1)
        .allowsHitTesting(mode != .hidden)
        .onContinuousHover { phase in
            // Expand on real pointer movement only: a banner that slides under a resting
            // cursor must not turn into the big card by itself.
            switch phase {
            case .active: model.onHover(mode == .banner || mode == .info ? .banner : .card, true)
            case .ended:
                model.onHover(.banner, false)
                model.onHover(.card, false)
            }
        }
    }
}

// MARK: - Rim (limits)
//
// Nothing can be drawn inside the cutout (there are no pixels under the camera), so at rest
// the notch stays untouched except for a hairline running around its outline: the left half
// fills with Claude's 5-hour usage, the right half with Codex's shortest window, both from
// the top edge down towards the middle. The cutout itself is an invisible hover target;
// pointing at it drops the limits card.

struct NotchRimView: View {
    @ObservedObject var model: NotchModel

    /// Negative: most of the line sits under the edge of the cutout (no pixels there), so
    /// what shows is a hairline of about 0.8 pt running flush along the notch, like a lit edge.
    static let gap: CGFloat = -0.6
    static let line: CGFloat = 1.4
    static let corner: CGFloat = 9

    var body: some View {
        let notch = model.notchWidth > 0 ? model.notchWidth : 140
        let margin = NotchRimView.gap + NotchRimView.line
        let claude = model.limits.claude.windows.first
        let codex = model.limits.codex.windows.first
        ZStack {
            // Hover target over the cutout; nearly transparent so it still receives the pointer.
            Rectangle().fill(Color.black.opacity(0.01))
            rim(left: true, window: claude, color: claudeOrange)
            rim(left: false, window: codex, color: codexBlue)
        }
        .frame(width: notch + 2 * margin, height: model.notchHeight + margin)
        .overlay(alignment: .bottom) {
            // A waiting question / plan / permission: a pulsing dot in the gap between the halves.
            if let kind = model.announced?.card.kind, !model.bannerVisible, model.expanded != .request {
                PendingDot(color: accent(kind))
                    .offset(y: 3)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func rim(left: Bool, window: LimitWindow?, color: Color) -> some View {
        let half = RimHalf(left: left, inset: NotchRimView.line / 2, corner: NotchRimView.corner)
        let style = StrokeStyle(lineWidth: NotchRimView.line, lineCap: .round)
        half.stroke(Color.white.opacity(window == nil ? 0.06 : 0.16), style: style)
        if let w = window {
            half.trim(from: 0, to: CGFloat(max(0.02, min(w.used, 100) / 100)))
                .stroke(w.used >= 90 ? usageColor(w.used) : color, style: style)
                .shadow(color: color.opacity(0.6), radius: 2)
        }
    }
}

/// Half of the notch outline: from the top edge down one side, around the bottom corner,
/// along the bottom to the middle.
let codexBlue = Color(red: 0.55, green: 0.82, blue: 1.0)

struct PendingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.9), radius: pulse ? 5 : 1)
            .opacity(pulse ? 1 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

struct RimHalf: Shape {
    let left: Bool
    let inset: CGFloat
    let corner: CGFloat

    func path(in r: CGRect) -> Path {
        let x = left ? r.minX + inset : r.maxX - inset
        let dir: CGFloat = left ? 1 : -1
        let bottom = r.maxY - inset
        var p = Path()
        p.move(to: CGPoint(x: x, y: r.minY))
        p.addLine(to: CGPoint(x: x, y: bottom - corner))
        p.addQuadCurve(to: CGPoint(x: x + dir * corner, y: bottom), control: CGPoint(x: x, y: bottom))
        p.addLine(to: CGPoint(x: r.midX - dir * 4, y: bottom))
        return p
    }
}

func usageColor(_ used: Double) -> Color {
    if used >= 90 { return Color(red: 1, green: 0.35, blue: 0.3) }
    if used >= 70 { return Color(red: 1, green: 0.72, blue: 0.3) }
    return .white
}

/// What pointing at the notch shows when nothing waits: usage limits and other apps' counters.
struct OverviewView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.limits.hasData { LimitsDetailView(limits: model.limits) }
            if !model.badges.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bell.badge.fill").font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.8))
                        Text(L.t("Notifications", "Уведомления")).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    }
                    HStack(spacing: 12) {
                        ForEach(model.badges.prefix(9)) { badge in BadgeIcon(badge: badge) }
                    }
                }
            }
        }
    }
}

struct BadgeIcon: View {
    let badge: AppBadge
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = badge.url { NSWorkspace.shared.open(url) }
        } label: {
            Image(nsImage: badge.icon)
                .resizable()
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    Text(badge.label)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 6, y: -5)
                }
                .scaleEffect(hovering ? 1.12 : 1)
                .animation(NotchMotion.spring, value: hovering)
        }
        .buttonStyle(.plain)
        .help(badge.name)
        .onHover { hovering = $0 }
    }
}

struct LimitsDetailView: View {
    let limits: LimitsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Claude", color: claudeOrange, symbol: "sparkle", provider: limits.claude)
            section(limits.codex.plan.isEmpty ? "Codex" : "Codex · \(limits.codex.plan)",
                    color: codexBlue,
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
    var icon: NSImage? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if let icon = icon {
                Image(nsImage: icon).resizable().frame(width: 30, height: 30)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundColor(color)
                    .padding(.top, 1)
            }
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
