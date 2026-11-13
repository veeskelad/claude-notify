import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// Small everyday tools in the panel:
//
//   timer      start from Home (5 / 10 / 25 min or your own); while it runs the resting notch shows
//              the countdown, at the end a sound and a banner
//   clipboard  the last copied texts, a click puts one back; kept in memory only, and what password
//              managers mark as concealed or transient is never recorded
//   shelf      files dropped on the notch wait there to be dragged out again or sent by AirDrop

// MARK: - Timer

let timerOrange = Color(red: 1.0, green: 0.62, blue: 0.2)

/// An SF Symbol drawn already coloured: the tint is part of the image, so it holds wherever the
/// view is rendered (a SwiftUI tint on some symbols came out white).
struct TintedSymbol: View {
    let name: String
    let size: CGFloat
    let color: NSColor

    var body: some View {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            Image(nsImage: image)
        }
    }
}

final class TimerStore: ObservableObject {
    @Published private(set) var endsAt: Date?
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var remaining: TimeInterval = 0
    /// Called on the main queue when a timer runs out, with its length.
    var onFinished: (TimeInterval) -> Void = { _ in }
    private var ticker: Timer?

    var running: Bool { endsAt != nil }

    func start(minutes: Double) {
        total = minutes * 60
        endsAt = Date().addingTimeInterval(total)
        tick()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        log("[timer] start \(Int(minutes)) min")
    }

    func add(minutes: Double) {
        guard let end = endsAt else { return start(minutes: minutes) }
        endsAt = end.addingTimeInterval(minutes * 60)
        total += minutes * 60
        tick()
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        endsAt = nil
        remaining = 0
    }

    private func tick() {
        guard let end = endsAt else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            let length = total
            stop()
            log("[timer] done")
            onFinished(length)
            return
        }
        let shown = left.rounded(.up)
        if shown != remaining { remaining = shown }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The timer line under Claude on Home: presets when idle, the countdown and controls when running.
struct TimerRow: View {
    @ObservedObject var timer: TimerStore
    @State private var custom = ""
    @FocusState private var editing: Bool
    var onWantsKeyboard: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            TintedSymbol(name: "timer", size: 12, color: timer.running ? NSColor(timerOrange) : NSColor(white: 1, alpha: 0.6))
            if timer.running {
                Text(TimerStore.clock(timer.remaining)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundColor(.white)
                Spacer(minLength: 4)
                Button("+1") { timer.add(minutes: 1) }.buttonStyle(NotchButtonStyle(role: .secondary))
                Button(L.t("Stop", "Стоп")) { timer.stop() }.buttonStyle(NotchButtonStyle(role: .secondary))
            } else {
                Text(L.t("Timer", "Таймер")).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                Spacer(minLength: 4)
                ForEach([5, 10, 25], id: \.self) { m in
                    Button("\(m)") { timer.start(minutes: Double(m)) }.buttonStyle(NotchButtonStyle(role: .secondary))
                }
                TextField(L.t("min", "мин"), text: $custom)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .frame(width: 34, height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .focused($editing)
                    .onChange(of: editing) { if $0 { onWantsKeyboard() } }
                    .onSubmit {
                        if let m = Double(custom.replacingOccurrences(of: ",", with: ".")), m > 0, m <= 24 * 60 {
                            timer.start(minutes: m)
                        }
                        custom = ""
                    }
            }
        }
        .frame(height: 26)
    }
}

// MARK: - Clipboard

struct ClipItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let at: Date
}

final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    var enabled = true { didSet { if !enabled { items = [] } } }
    private var lastChange = NSPasteboard.general.changeCount
    private var poll: Timer?
    private static let limit = 30
    /// Markers apps put on things that must not be remembered (nspasteboard.org).
    private static let skip: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                            "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]

    init() {
        poll = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.check() }
        poll?.tolerance = 0.25
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard enabled else { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ClipboardStore.skip), let text = pb.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100_000 else { return }
        items.removeAll { $0.text == text }
        items.insert(ClipItem(text: text, at: Date()), at: 0)
        if items.count > ClipboardStore.limit { items = Array(items.prefix(ClipboardStore.limit)) }
    }

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        lastChange = pb.changeCount
        items.removeAll { $0.id == item.id }
        items.insert(ClipItem(text: item.text, at: Date()), at: 0)
    }

    func clear() { items = [] }

    /// Screenshots of test instances: made-up items instead of the real clipboard.
    func inject(_ texts: [String]) {
        enabled = false
        items = texts.map { ClipItem(text: $0, at: Date()) }
    }
}

struct ClipboardTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var clipboard: ClipboardStore

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("Recently copied", "Недавно скопировано"))
                    .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                Spacer()
                if !clipboard.items.isEmpty {
                    Button(L.t("Clear", "Очистить")) { clipboard.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                }
            }
            if clipboard.items.isEmpty {
                Text(clipboard.enabled ? L.t("Copy some text: it shows up here", "Скопируйте текст — он появится здесь")
                                       : L.t("Clipboard history is off in Settings", "История буфера выключена в настройках"))
                    .font(.system(size: 12.5)).foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(clipboard.items) { item in
                            ClipCard(item: item) {
                                clipboard.copy(item)
                                model.onClose()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(height: 170, alignment: .top)
    }
}

struct ClipCard: View {
    let item: ClipItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.13 : 0.07)))
        }
        .buttonStyle(.plain)
        .help(L.t("Copy again", "Скопировать снова"))
        .onHover { hovering = $0 }
    }
}

// MARK: - Shelf

final class ShelfStore: ObservableObject {
    @Published private(set) var files: [URL] = []
    private static let file = "\(Paths.supportDir)/shelf.json"

    init() {
        guard let data = FileManager.default.contents(atPath: ShelfStore.file),
              let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else { return }
        files = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        let new = urls.filter { u in !files.contains { $0.path == u.path } }
        guard !new.isEmpty else { return }
        files.append(contentsOf: new)
        save()
        log("[shelf] +\(new.count), \(files.count) on the shelf")
    }

    func remove(_ url: URL) {
        files.removeAll { $0.path == url.path }
        save()
    }

    func clear() {
        files = []
        save()
    }

    /// Files moved or deleted elsewhere leave the shelf.
    func prune() {
        let alive = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if alive.count != files.count {
            files = alive
            save()
        }
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: files.map(\.path)) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: ShelfStore.file, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

struct ShelfTab: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                guard !shelf.files.isEmpty else { return }
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: shelf.files)
            } label: {
                VStack(spacing: 8) {
                    TintedSymbol(name: "dot.radiowaves.left.and.right", size: 22,
                                 color: NSColor(red: 0.25, green: 0.6, blue: 1, alpha: 1))
                    Text("AirDrop").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.white)
                }
                .frame(width: 112, height: 112)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
                .opacity(shelf.files.isEmpty ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .help(L.t("Send everything on the shelf by AirDrop", "Отправить всё с полки по AirDrop"))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.t("Files: \(shelf.files.count)", "Файлов: \(shelf.files.count)"))
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                    Spacer()
                    if !shelf.files.isEmpty {
                        Button(L.t("Clear", "Очистить")) { shelf.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                    }
                }
                if shelf.files.isEmpty {
                    Text(L.t("Drag files onto the notch to keep them here", "Перетащите файлы на чёлку — они полежат здесь"))
                        .font(.system(size: 12.5)).foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shelf.files, id: \.self) { url in
                                ShelfItem(url: url, remove: { shelf.remove(url) })
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(height: 150, alignment: .top)
        .onAppear { shelf.prune() }
    }
}

struct ShelfItem: View {
    let url: URL
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            FilePreview(url: url, size: 52)
            Text(url.lastPathComponent).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.85))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 84)
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovering ? 0.08 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(L.t("Take off the shelf", "Убрать с полки"))
            }
        }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() } preview: {
            FilePreview(url: url, size: 64)
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button(L.t("Open", "Открыть")) { NSWorkspace.shared.open(url) }
            Button(L.t("Show in Finder", "Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(L.t("Take off the shelf", "Убрать с полки"), action: remove)
        }
        .help(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }
}

/// What the file looks like (Quick Look: photos, PDFs, videos, documents), its icon until that is ready
/// or when there is none.
struct FilePreview: View {
    let url: URL
    let size: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let t = thumbnail {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        }
        .frame(width: size, height: size)
        .onAppear(perform: load)
    }

    private func load() {
        guard thumbnail == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep = rep else { return }
            DispatchQueue.main.async { thumbnail = rep.nsImage }
        }
    }
}

// MARK: - Drop zones

enum DropSide { case shelf, convert }

/// While a drag is over the notch: the left half keeps files on the shelf, the right half converts images.
struct DropZones: View {
    let side: DropSide
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 8) {
                zone(.shelf, symbol: "tray.and.arrow.down", title: L.t("To the shelf", "На полку"))
                zone(.convert, symbol: "photo.on.rectangle.angled", title: L.t("Convert", "Конвертировать"))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private func zone(_ s: DropSide, symbol: String, title: String) -> some View {
        let on = s == side
        return VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            Text(title).font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundColor(.white.opacity(on ? 1 : 0.5))
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(on ? 0.6 : 0.15), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(on ? 0.1 : 0.03))))
    }
}

/// Tracks where the drag is so the right zone lights up, and hands the files over on drop.
struct NotchDropDelegate: DropDelegate {
    let model: NotchModel
    let midX: CGFloat

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        model.dropTargeted = true
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // An open Shelf or Converter tab takes the drop whole; otherwise the halves decide.
        let side: DropSide
        if model.expanded == .panel && model.tab == .shelf {
            side = .shelf
        } else if model.expanded == .panel && model.tab == .convert {
            side = .convert
        } else {
            side = info.location.x < midX ? .shelf : .convert
        }
        if model.dropSide != side { model.dropSide = side }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { model.dropTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        let side = model.dropSide
        model.dropTargeted = false
        model.onDropFiles(info.itemProviders(for: [.fileURL]), side)
        return true
    }
}

struct ShelfBadge: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        if !shelf.files.isEmpty {
            Text("\(shelf.files.count)")
                .font(.system(size: 9, weight: .bold)).monospacedDigit()
                .foregroundColor(.black)
                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                .background(Capsule().fill(Color.white))
                .offset(x: 2, y: -3)
        }
    }
}

/// The timer while it runs and the panel is closed: icon on the left, countdown on the right.
struct TimerCompact: View {
    @ObservedObject var timer: TimerStore
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        NotchRow(notchWidth: notchWidth, height: notchHeight) {
            TintedSymbol(name: "timer", size: 14, color: NSColor(timerOrange))
        } right: {
            Text(TimerStore.clock(timer.remaining)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
    }
}

/// The Converter tab: drop images on it or choose them.
struct ConvertTab: View {
    @ObservedObject var model: NotchModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 24, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Text(L.t("Drop images here: HEIC, JPG, PNG, TIFF", "Перетащите сюда картинки: HEIC, JPG, PNG, TIFF"))
                .font(.system(size: 12.5)).foregroundColor(.white.opacity(0.6))
            Button(L.t("Choose files…", "Выбрать файлы…")) { model.onPickImages() }
                .buttonStyle(NotchButtonStyle(role: .primary))
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(height: 160, alignment: .top)
    }
}
