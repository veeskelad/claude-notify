import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// A borderless window glued to the MacBook notch. The notch itself grows into one black shape:
//
//   compact  a little wider than the cutout while Claude works (✋ waiting ⟳ working ✓ done)
//   banner   two lines: a new request (6 s, then it folds back) or a short "done" / error
//   card     the request with answer buttons (point at the notch or the banner)
//   panel    tabs and widgets (PanelViews.swift): point at the notch when nothing waits
//   rim      with the notch at rest, a hairline around its outline: Claude (left) and Codex
//            (right) usage, and a pulsing dot while a request waits
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
}

enum NotchExpansion { case request, panel, convert }

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
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32
    /// The rim (limits hairline and the waiting-request dot) is off: quiet hours or by hand.
    /// The cutout still answers the pointer, so the limits card and its eye button stay reachable.
    @Published var indicatorsHidden = false
    @Published var tab: PanelTab = .home
    /// The Mac needs a glance (SystemMonitor.alert); `alertSeen` is the key of the one already looked at.
    @Published var systemAlert: SystemAlert?
    @Published var alertSeen: String?
    /// The Claude module (cards, rim, widget, compact state); off in Settings → the notch is a plain panel.
    @Published var claudeEnabled = true
    @Published var sessions: [ClaudeSessionRow] = []
    @Published var activity = ClaudeActivity()
    /// The notch widens while Claude works (counts). Off by default: at rest the notch keeps its size.
    @Published var claudeCompact = false
    /// Codex usage on: the rim is split, Claude left and Codex right. Off: Claude runs all the way round.
    @Published var codexEnabled = true
    /// Images dropped on the notch for conversion (Converter.swift); a drag is over the notch.
    @Published var convert: ConvertJob?
    let notes = NotesStore()
    @Published var dropTargeted = false
    @Published var dropSide: DropSide = .shelf
    /// A timer runs (Tools.swift): the resting notch shows its countdown.
    @Published var timerRunning = false
    let timer = TimerStore()
    let clipboard = ClipboardStore()
    let shelf = ShelfStore()

    var onDecision: (String, Decision) -> Void = { _, _ in }
    var onOpen: (String) -> Void = { _ in }
    var onDismiss: (String) -> Void = { _ in }
    var onOpenSession: (String) -> Void = { _ in }
    var onHover: (NotchZone, Bool) -> Void = { _, _ in }
    var onToggleIndicators: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onDropFiles: ([NSItemProvider], DropSide) -> Void = { _, _ in }
    var onPickImages: () -> Void = {}
    var onSavedToNotes: (Bool) -> Void = { _ in }
    /// Fold the panel now (after copying a clipboard item, so the user can paste).
    var onClose: () -> Void = {}
    var onConvert: (ImageFormat) -> Void = { _ in }
    var onConvertClose: () -> Void = {}
    /// A text field is about to take input: the panel must become key (without activating the app).
    var onWantsKeyboard: () -> Void = {}

    var current: NotchItem? { items.first { $0.id == selectedId } ?? items.first(where: \.announced) ?? items.first }
    var announced: NotchItem? { items.first(where: \.announced) }
    var currentIndex: Int { items.firstIndex { $0.id == current?.id } ?? 0 }

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
    let system: SystemMonitor
    /// The user hovered or opened a request card: no fallback notification needed.
    var onNoticed: (String) -> Void = { _ in }
    /// The panel is about to open: a chance to bring the limits up to date.
    var onShowLimits: () -> Void = {}

    /// How long a request's banner stays out before folding into the rim dot.
    static let bannerSeconds: Double = 6
    /// Room for the largest card; the window keeps this size for good.
    static let islandRoom = CGSize(width: 640, height: 540)

    private let panel: NotchPanel
    private let hosting: FirstMouseHostingView<NotchRootView>
    private var visibility: AnyCancellable?
    private var alertWatch: AnyCancellable?
    private var timerWatch: AnyCancellable?
    private var hovered = Set<NotchZone>()
    private var bannerShownAt = Date.distantPast
    private var collapseWork: DispatchWorkItem?
    private var infoWork: DispatchWorkItem?
    private var bannerWork: DispatchWorkItem?

    init(system: SystemMonitor) {
        self.system = system
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

        hosting = FirstMouseHostingView(rootView: NotchRootView(model: model, system: system))
        alertWatch = system.$alert.receive(on: DispatchQueue.main).sink { [weak self] alert in
            guard let self = self else { return }
            withAnimation(NotchMotion.spring) {
                self.model.systemAlert = alert
                if alert == nil { self.model.alertSeen = nil }   // the next time it is news again
            }
        }
        // The controller sizes the window itself. Without this, every animation frame also recomputed the
        // hosting view's min/max size and constraints (most of the cost of an animating notch).
        hosting.sizingOptions = []
        panel.contentView = hosting

        model.onWantsKeyboard = { [weak self] in self?.panel.makeKey() }
        model.onDropFiles = { [weak self] providers, side in self?.dropped(providers, side) }
        model.onPickImages = { [weak self] in self?.pickImages() }
        model.onSavedToNotes = { [weak self] ok in
            self?.showInfo(NotchInfo(sessionId: "", headline: ok ? L.t("Saved to Notes", "Сохранено в «Заметки»")
                                                                 : L.t("Notes refused", "«Заметки» не приняли"),
                                     subtitle: L.t("Notes", "Заметки"),
                                     text: ok ? "" : L.t("Allow Notchy in Settings → Privacy → Automation", "Разрешите Notchy: Настройки → Конфиденциальность → Автоматизация"),
                                     kind: ok ? .done : .attention), seconds: 4)
        }
        model.onClose = { [weak self] in
            guard let self = self else { return }
            withAnimation(NotchMotion.exit) { self.model.expanded = nil }
            if self.panel.isKeyWindow { self.panel.resignKey() }
        }
        timerWatch = model.timer.$endsAt.receive(on: DispatchQueue.main).sink { [weak self] end in
            withAnimation(NotchMotion.spring) { self?.model.timerRunning = end != nil }
        }
        model.timer.onFinished = { [weak self] length in
            guard let self = self else { return }
            NSSound(named: NSSound.Name("Glass"))?.play()
            self.showInfo(NotchInfo(sessionId: "", headline: L.t("Timer", "Таймер"),
                                    subtitle: L.t("Time is up", "Время вышло"),
                                    text: L.duration(length), kind: .done), seconds: 10)
        }
        model.onConvert = { [weak self] format in self?.convert(to: format) }
        model.onConvertClose = { [weak self] in self?.closeConvert() }
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
        if model.expanded == .panel {
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

    /// Dev aid: the window's content as a PNG, without screen-recording permission.
    func snapshot(to path: String) {
        let view = hosting
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        log("[debug] snapshot \(path)")
    }

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

    func setIndicatorsHidden(_ hidden: Bool) {
        withAnimation(NotchMotion.fill) { model.indicatorsHidden = hidden }
    }

    func setLimits(_ limits: LimitsSnapshot) {
        withAnimation(NotchMotion.fill) { model.limits = limits }
    }

    // MARK: Converter

    private func dropped(_ providers: [NSItemProvider], _ side: DropSide) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            switch side {
            case .convert: self.accept(urls)
            case .shelf: self.shelve(urls)
            }
        }
    }

    /// Files dropped on the shelf half: they wait in the Shelf tab, which opens to show them.
    private func shelve(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        model.shelf.add(urls)
        animate {
            model.tab = .shelf
            model.expanded = .panel
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.model.expanded == .panel, self.hovered.isEmpty else { return }
            withAnimation(NotchMotion.exit) { self.model.expanded = nil }
        }
    }

    /// The Converter tab's "Choose files…".
    private func pickImages() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.allowedContentTypes = [.image]
        open.prompt = L.t("Convert", "Конвертировать")
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard response == .OK, let self = self else { return }
            self.accept(open.urls)
        }
    }

    /// Files dropped on the notch (or handed over by a debug message).
    func accept(_ urls: [URL]) {
        let images = urls.filter(ImageConverter.isImage).sorted { $0.lastPathComponent < $1.lastPathComponent }
        log("[convert] dropped \(urls.count), images \(images.count)")
        guard !images.isEmpty else {
            showInfo(NotchInfo(sessionId: "", headline: L.t("Not images", "Это не картинки"),
                               subtitle: L.t("Converter", "Конвертер"),
                               text: L.t("Drop JPG, PNG, HEIC, WebP or TIFF", "Нужны JPG, PNG, HEIC, WebP или TIFF"),
                               kind: .attention), seconds: 3)
            return
        }
        animate {
            model.convert = ConvertJob(files: images)
            model.expanded = .convert
        }
        collapseIfAway(after: 10)
    }

    func convert(to format: ImageFormat) {
        guard let job = model.convert, job.state == .ready else { return }
        animate { model.convert?.state = .working(format) }
        let files = job.files
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var made: [URL] = []
            var failed = 0
            for url in files {
                do {
                    made.append(try ImageConverter.convert(url, to: format))
                } catch {
                    failed += 1
                    log("[convert] \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            log("[convert] \(made.count) → \(format.label), failed \(failed)")
            DispatchQueue.main.async {
                guard let self = self, self.model.convert?.files == files else { return }
                self.animate { self.model.convert?.state = .done(format, made, failed: failed) }
                self.collapseIfAway(after: 6)
            }
        }
    }

    private func closeConvert() {
        withAnimation(NotchMotion.exit) {
            model.convert = nil
            if model.expanded == .convert { model.expanded = nil }
        }
    }

    /// Dropped and walked away: the converter folds up unless the pointer is on it or work runs.
    private func collapseIfAway(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.model.expanded == .convert, self.hovered.isEmpty else { return }
            if case .working? = self.model.convert?.state { return }
            self.closeConvert()
        }
    }

    // MARK: Hover

    private func hover(_ zone: NotchZone, _ inside: Bool) {
        let changed = inside ? hovered.insert(zone).inserted : hovered.remove(zone) != nil
        guard changed else { return }
        collapseWork?.cancel()
        if inside {
            switch zone {
            case .notch:
                expandFromNotch()
            case .banner:
                // Pointer events in the first moments are the banner sliding under the cursor.
                guard Date().timeIntervalSince(bannerShownAt) > 0.6, let item = model.current,
                      model.expanded == nil, model.bannerVisible else { return }
                log("[hover] banner → card")
                animate { model.expanded = .request; model.bannerVisible = false }
                onNoticed(item.id)
            case .card:
                // The compact state is the notch too.
                if model.expanded == nil { expandFromNotch() }
            }
            return
        }
        guard hovered.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.hovered.isEmpty, !self.model.editing else { return }
            if case .working? = self.model.convert?.state { return }
            withAnimation(NotchMotion.exit) {
                if self.model.expanded == .convert { self.model.convert = nil }
                self.model.expanded = nil
            }
            if self.panel.isKeyWindow { self.panel.resignKey() }
        }
        collapseWork = work
        // A brief slip of the pointer off the shape is forgiven.
        let delay = model.expanded == .request ? 0.15 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Pointing at the notch: a waiting question first, otherwise the panel.
    private func expandFromNotch() {
        if let item = model.current {
            if model.expanded != .request {
                log("[hover] notch → card")
                animate { model.expanded = .request; model.bannerVisible = false }
            }
            onNoticed(item.id)
        } else if model.expanded == nil {
            onShowLimits()
            animate {
                if let a = model.systemAlert, a.widensNotch, a.key != model.alertSeen {
                    model.tab = .system
                    model.alertSeen = a.key
                }
                model.expanded = .panel
            }
        }
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
        var frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - height,
                           width: size.width, height: height)
        // Test instances taking screenshots: render off screen, out of the user's way.
        if Visibility.forceOffscreen && ProcessInfo.processInfo.environment["NOTCHY_HIDDEN_WINDOW"] == "1" {
            frame.origin.x = screen.frame.minX - size.width - 4000
        }
        panel.setFrame(frame, display: true)
        log("[notch] panel \(Int(frame.width))x\(Int(frame.height)), notch \(Int(model.notchWidth))x\(Int(model.notchHeight))")
        updateVisibility()
    }

    private func updateVisibility() {
        // Always there: the cutout is the way into the panel.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    let system: SystemMonitor

    var body: some View {
        ZStack(alignment: .top) {
            IslandView(model: model, system: system)
            NotchRimView(model: model)
                .onHover { model.onHover(.notch, $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [UTType.fileURL], delegate: NotchDropDelegate(model: model, midX: NotchController.islandRoom.width / 2))
        .environment(\.colorScheme, .dark)
    }
}

enum IslandMode: Equatable { case hidden, compact, alert, timer, banner, info, card, panel, drop, convert }

extension NotchModel {
    var mode: IslandMode {
        switch expanded {
        case .request?: if current != nil { return .card }
        case .panel?: if !dropTargeted || tab == .shelf || tab == .convert { return .panel }
        case .convert?: if convert != nil && !dropTargeted { return .convert }
        case nil: break
        }
        if dropTargeted { return .drop }
        if announced != nil && bannerVisible { return .banner }
        if info != nil { return .info }
        if let a = systemAlert, a.widensNotch, a.key != alertSeen { return .alert }
        if timerRunning { return .timer }
        if claudeCompact && claudeEnabled && !indicatorsHidden && !activity.isEmpty { return .compact }
        return .hidden
    }
}

/// The notch grown into one black shape that morphs between states instead of swapping views,
/// so size changes animate as one continuous outline.
struct IslandView: View {
    @ObservedObject var model: NotchModel
    let system: SystemMonitor

    private var notch: CGFloat { model.notchWidth > 0 ? model.notchWidth : 180 }

    private func width(_ mode: IslandMode) -> CGFloat {
        switch mode {
        case .hidden: return notch + 12
        case .compact:
            let kinds = [model.activity.waiting, model.activity.working, model.activity.done].filter { $0 > 0 }.count
            return notch + 2 * CGFloat(40 + 34 * max(1, kinds))
        case .alert: return notch + 2 * 150
        case .drop: return max(notch + 260, 460)
        case .timer: return notch + 2 * 64
        case .convert: return panelWidth
        case .banner, .info: return max(notch + 220, 440)
        case .card, .panel: return panelWidth
        }
    }

    private func radius(_ mode: IslandMode) -> CGFloat {
        switch mode {
        case .hidden: return 8
        case .compact, .alert, .timer: return 12
        case .drop: return 20
        case .convert: return 30
        case .banner, .info: return 20
        case .card, .panel: return 30
        }
    }

    var body: some View {
        let mode = model.mode
        let shape = NotchShape(ear: 6, bottomRadius: radius(mode))
        ZStack(alignment: .top) {
            switch mode {
            case .panel:
                PanelView(model: model, system: system)
                    .transition(islandContent)
            case .card:
                if let item = model.current {
                    VStack(spacing: 0) {
                        NotchRow(notchWidth: notch, height: model.notchHeight) {
                            ClaudeMark(spinning: model.activity.working > 0)
                        } right: {
                            EmptyView()   // the card's own header says how many wait
                        }
                        .padding(.horizontal, 20)
                        CardView(item: item, model: model)
                            .id(item.id)
                            .padding(.horizontal, 22)
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                    }
                    .transition(islandContent)
                }
            case .banner:
                if let item = model.announced {
                    NotchBanner(notchWidth: notch, notchHeight: model.notchHeight,
                                symbol: Texts.symbol(item.card.kind), color: accent(item.card.kind),
                                label: Texts.kindLabel(item.card) + (model.items.count > 1 ? " · +\(model.items.count - 1)" : ""),
                                headline: item.headline, text: cardSummary(item.card))
                        .contentShape(Rectangle())
                        .onTapGesture { model.onHover(.banner, true) }
                        .transition(islandContent)
                }
            case .info:
                if let info = model.info {
                    NotchBanner(notchWidth: notch, notchHeight: model.notchHeight,
                                symbol: Texts.symbol(info.kind), color: accent(info.kind),
                                label: info.subtitle, headline: info.headline, text: info.text)
                        .contentShape(Rectangle())
                        .onTapGesture { model.onOpenSession(info.sessionId) }
                        .transition(islandContent)
                }
            case .drop:
                DropZones(side: model.dropSide, notchWidth: notch, notchHeight: model.notchHeight)
                    .transition(islandContent)
            case .timer:
                TimerCompact(timer: model.timer, notchWidth: notch, notchHeight: model.notchHeight)
                    .transition(islandContent)
            case .convert:
                if let job = model.convert {
                    ConvertView(model: model, job: job)
                        .transition(islandContent)
                }
            case .alert:
                if let a = model.systemAlert {
                    SystemAlertCompact(alert: a, notchWidth: notch, notchHeight: model.notchHeight)
                        .transition(islandContent)
                }
            case .compact:
                NotchRow(notchWidth: notch, height: model.notchHeight) {
                    ClaudeMark(spinning: model.activity.working > 0)
                } right: {
                    ClaudeCounts(activity: model.activity)
                }
                .padding(.horizontal, 20)
                .transition(islandContent)
            case .hidden:
                Color.clear.frame(height: model.notchHeight)
            }
        }
        .frame(width: width(mode), alignment: .top)
        .background(shape.fill(Color.black).opacity(mode == .hidden ? 0 : 1))
        // Text lives only on the black: while the shape grows, whatever is outside it stays hidden.
        .clipShape(shape)
        .contentShape(shape)
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

/// Content of the black shape: appears once the shape has mostly opened, leaves at once.
let islandContent = AnyTransition.asymmetric(
    insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
    removal: .opacity.animation(.easeIn(duration: 0.08)))

/// The one line a banner shows for a request.
func cardSummary(_ card: Card) -> String {
    switch card.kind {
    case .question: return card.questions.first?.question ?? ""
    case .plan: return card.text
    case .permission: return card.detail.isEmpty ? card.command : card.detail
    default: return card.text
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
            if !model.indicatorsHidden && model.claudeEnabled && model.mode == .hidden {
                if model.codexEnabled {
                    rim(left: true, window: claude, color: claudeOrange)
                    rim(left: false, window: codex, color: codexBlue)
                } else {
                    fullRim(window: claude, color: claudeOrange)
                }
            }
        }
        .frame(width: notch + 2 * margin, height: model.notchHeight + margin)
        .overlay(alignment: .bottom) {
            // A waiting question / plan / permission: a pulsing dot in the gap between the halves.
            if let kind = model.announced?.card.kind, model.mode == .hidden, !model.indicatorsHidden {
                PendingDot(color: accent(kind))
                    .offset(y: 3)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
    }

    /// Codex off: one line from the top left, round the bottom, up to the top right.
    @ViewBuilder
    private func fullRim(window: LimitWindow?, color: Color) -> some View {
        let shape = RimFull(inset: NotchRimView.line / 2, corner: NotchRimView.corner)
        let style = StrokeStyle(lineWidth: NotchRimView.line, lineCap: .round)
        shape.stroke(Color.white.opacity(window == nil ? 0.06 : 0.16), style: style)
        if let w = window {
            shape.trim(from: 0, to: CGFloat(max(0.01, min(w.used, 100) / 100)))
                .stroke(w.used >= 90 ? usageColor(w.used) : color, style: style)
                .shadow(color: color.opacity(0.6), radius: 2)
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
            .shadow(color: color.opacity(0.9), radius: 3)
            .opacity(pulse ? 1 : 0.55)
            .onAppear {
                // A few pulses to catch the eye, then a steady dot: a pulse that never ends redraws the
                // window every frame for as long as the request waits (~7% CPU).
                withAnimation(.easeInOut(duration: 0.9).repeatCount(5, autoreverses: true)) { pulse = true }
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

/// The whole notch outline as one line: down the left side, along the bottom, up the right side.
struct RimFull: Shape {
    let inset: CGFloat
    let corner: CGFloat

    func path(in r: CGRect) -> Path {
        let l = r.minX + inset, rt = r.maxX - inset, bottom = r.maxY - inset
        var p = Path()
        p.move(to: CGPoint(x: l, y: r.minY))
        p.addLine(to: CGPoint(x: l, y: bottom - corner))
        p.addQuadCurve(to: CGPoint(x: l + corner, y: bottom), control: CGPoint(x: l, y: bottom))
        p.addLine(to: CGPoint(x: rt - corner, y: bottom))
        p.addQuadCurve(to: CGPoint(x: rt, y: bottom - corner), control: CGPoint(x: rt, y: bottom))
        p.addLine(to: CGPoint(x: rt, y: r.minY))
        return p
    }
}

func usageColor(_ used: Double) -> Color {
    if used >= 90 { return Color(red: 1, green: 0.35, blue: 0.3) }
    if used >= 70 { return Color(red: 1, green: 0.72, blue: 0.3) }
    return .white
}
