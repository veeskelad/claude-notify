import AppKit
import SwiftUI
import Translation

// Claude Code's changelog is in English. With the app in Russian its lines are translated on the Mac by
// Apple Translation (macOS 26+): nothing leaves the Mac and no Claude usage is spent. The English → Russian
// pack is downloaded once, from the Radar tab or System Settings → General → Language & Region →
// Translation Languages. Translations are kept by the English line, so a line is translated once.

final class ReleaseTranslator: ObservableObject {
    enum State: Equatable {
        case off            // the app is in English, or macOS is older than 26
        case checking
        case needsDownload  // supported, the pack is not on this Mac yet
        case ready
        case unsupported
    }

    @Published private(set) var state: State = .off
    @Published private(set) var cache: [String: String] = [:]
    private var wanted: [String] = []
    private var running = false
    private static let file = "\(Paths.supportDir)/radar-translations.json"
    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "ru")

    init(enabled: Bool) {
        guard enabled, #available(macOS 26, *) else { return }
        if let data = FileManager.default.contents(atPath: ReleaseTranslator.file),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            cache = saved
        }
        check()
    }

    /// The line in Russian when there is a translation, else as it is.
    func text(_ line: String) -> String { cache[line] ?? line }

    /// Is the pack here? Called at start and after a download.
    func check() {
        guard #available(macOS 26, *) else { return }
        state = .checking
        Task { @MainActor [weak self] in
            let status = await LanguageAvailability().status(from: ReleaseTranslator.source, to: ReleaseTranslator.target)
            guard let self = self else { return }
            switch status {
            case .installed: self.state = .ready; self.run()
            case .supported: self.state = .needsDownload
            default: self.state = .unsupported
            }
        }
    }

    /// The lines the tab shows now; the missing ones get translated in the background.
    func want(_ lines: [String]) {
        wanted = lines
        run()
    }

    private func run() {
        guard #available(macOS 26, *), state == .ready, !running else { return }
        let missing = Array(Set(wanted.filter { cache[$0] == nil }))
        guard !missing.isEmpty else { return }
        running = true
        Task { @MainActor [weak self] in
            var got: [String: String] = [:]
            do {
                let session = TranslationSession(installedSource: ReleaseTranslator.source, target: ReleaseTranslator.target)
                let requests = missing.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                for r in try await session.translations(from: requests) {
                    if let i = r.clientIdentifier.flatMap(Int.init), i < missing.count { got[missing[i]] = r.targetText }
                }
            } catch {
                log("[radar] translation: \(error.localizedDescription)")
            }
            guard let self = self else { return }
            self.running = false
            guard !got.isEmpty else { return }
            self.cache.merge(got) { _, new in new }
            self.save()
            self.run()   // lines asked for while this batch ran
        }
    }

    /// Only the lines still on screen are kept, so the file stays small.
    private func save() {
        let keep = Set(wanted)
        let pruned = cache.filter { keep.contains($0.key) }
        guard let data = try? JSONSerialization.data(withJSONObject: pruned) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: ReleaseTranslator.file), options: .atomic)
    }
}

/// "The updates are in English" with a button that fetches the Russian pack (macOS asks first).
struct TranslationDownloadRow: View {
    @ObservedObject var translator: ReleaseTranslator
    @State private var asked = false

    var body: some View {
        HStack(spacing: 8) {
            Text(asked ? "Если окно загрузки не появилось — Настройки → Основные → Язык и регион → Языки перевода."
                       : "Изменения пока на английском: русский перевод скачивается один раз и работает без интернета.")
                .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if asked {
                Button("Настройки") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
                .buttonStyle(NotchButtonStyle(role: .secondary))
            } else {
                Button("Скачать перевод") { asked = true }
                    .buttonStyle(NotchButtonStyle(role: .secondary))
            }
        }
        .modifier(PrepareTranslation(active: asked, translator: translator))
    }
}

/// translationTask runs only while `active`: prepareTranslation shows the system's download prompt.
private struct PrepareTranslation: ViewModifier {
    let active: Bool
    let translator: ReleaseTranslator

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.translationTask(active ? TranslationSession.Configuration(source: ReleaseTranslator.source,
                                                                            target: ReleaseTranslator.target) : nil) { session in
                do { try await session.prepareTranslation() } catch {
                    log("[radar] translation download: \(error.localizedDescription)")
                }
                await MainActor.run { translator.check() }
            }
        } else {
            content
        }
    }
}
