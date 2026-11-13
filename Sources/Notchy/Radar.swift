import AppKit
import SwiftUI

// The Radar tab: what's new worth a look.
//
//   Claude Code   the public CHANGELOG (github.com/anthropics/claude-code), newest versions first, marked
//                 against the installed `claude --version`; fetched every 6 h and when the tab opens
//   findings      cards from your own scouts: `radar_command` in the config is run every 30 min and prints
//                 {"items": [{"id", "source", "title", "text", "action", "url", "report", "date", "kind"}]}
//
// A dot on the tab marks entries not seen yet. Nothing personal leaves the Mac: the changelog is a public
// file, the findings command is yours and runs locally.

struct RadarItem: Identifiable, Equatable {
    let id: String
    let source: String
    let title: String
    let text: String
    let action: String      // what the scout needs from you, if anything
    let url: String
    let report: String      // local report file
    let date: String
    let kind: String        // "propose" (your decision), "hold", "probe", "finding"
    let prompt: String      // the task for an agent; empty: built from the fields above
}

struct ClaudeRelease: Identifiable, Equatable {
    let version: String
    let added: [String]
    let fixed: [String]
    var id: String { version }
}

final class RadarStore: ObservableObject {
    @Published private(set) var items: [RadarItem] = []
    @Published private(set) var releases: [ClaudeRelease] = []
    @Published private(set) var installed = ""
    @Published private(set) var unseen = 0
    @Published private(set) var error = ""
    @Published var showClaude = false   // which half of the tab is open
    @Published private(set) var dismissed: Set<String> = Set(RadarStore.load(RadarStore.dismissedFile))

    private let command: String
    private let claudeUpdates: Bool
    private let claudePath: String
    /// Russian for the changelog lines when the app speaks Russian (RadarTranslate.swift).
    let translator: ReleaseTranslator
    private var timer: Timer?
    private var lastFeed = Date.distantPast
    private var lastChangelog = Date.distantPast
    private let queue = DispatchQueue(label: "notchy.radar")
    private static let seenFile = "\(Paths.supportDir)/radar-seen.json"
    private static let dismissedFile = "\(Paths.supportDir)/radar-dismissed.json"
    static let changelogURL = URL(string: "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md")!
    static let changelogPage = URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md")!

    init(command: String, claudeUpdates: Bool, claudePath: String) {
        self.command = command
        self.claudeUpdates = claudeUpdates
        self.claudePath = claudePath
        self.translator = ReleaseTranslator(enabled: claudeUpdates && L.russian)
        guard !command.isEmpty || claudeUpdates else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 60
    }

    var enabled: Bool { !command.isEmpty || claudeUpdates }
    var hasFindings: Bool { !command.isEmpty }
    var hasClaude: Bool { claudeUpdates }

    /// The tab opened: fresh data if it is more than a few minutes old.
    func refreshSoon() {
        if Date().timeIntervalSince(lastFeed) > 5 * 60 { refresh() }
    }

    func refresh() {
        if !command.isEmpty { runFeed() }
        if claudeUpdates && Date().timeIntervalSince(lastChangelog) > 6 * 3600 { fetchChangelog() }
    }

    /// Everything on screen now counts as seen.
    func markSeen() {
        RadarStore.append(keys, to: RadarStore.seenFile)
        updateUnseen()
    }

    var visibleItems: [RadarItem] { items.filter { !dismissed.contains("f:" + $0.id) } }
    var visibleReleases: [ClaudeRelease] { releases.filter { !dismissed.contains("c:" + $0.version) } }
    /// Hidden in the half that is open: what "Bring back" would return.
    var hiddenHere: Int { showClaude ? releases.count - visibleReleases.count : items.count - visibleItems.count }

    func dismiss(_ item: RadarItem) { hide(["f:" + item.id]) }
    func dismiss(_ release: ClaudeRelease) { hide(["c:" + release.version]) }
    func dismissAllHere() {
        hide(showClaude ? visibleReleases.map { "c:" + $0.version } : visibleItems.map { "f:" + $0.id })
    }
    func restoreHere() {
        let here = Set(showClaude ? releases.map { "c:" + $0.version } : items.map { "f:" + $0.id })
        dismissed.subtract(here)
        RadarStore.save(RadarStore.load(RadarStore.dismissedFile).filter { !here.contains($0) }, to: RadarStore.dismissedFile)
        updateUnseen()
    }

    private func hide(_ keys: [String]) {
        dismissed.formUnion(keys)
        RadarStore.append(keys, to: RadarStore.dismissedFile)
        updateUnseen()
    }

    /// Oldest first, trimmed to the last 1000. Files next to the shelf and notes, so a test instance with
    /// NOTCHY_HOME keeps its own.
    private static func load(_ file: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }

    private static func append(_ keys: [String], to file: String) {
        var list = load(file)
        let known = Set(list)
        list += keys.filter { !known.contains($0) }
        save(list, to: file)
    }

    private static func save(_ list: [String], to file: String) {
        let data = try? JSONSerialization.data(withJSONObject: Array(list.suffix(1000)))
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        try? data?.write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    private var keys: [String] { visibleItems.map { "f:" + $0.id } + visibleReleases.map { "c:" + $0.version } }

    // MARK: Tasks for an agent

    /// A finding as a task an agent can pick up: the feed's own prompt, or one built from the card.
    func agentPrompt(_ item: RadarItem) -> String {
        if !item.prompt.isEmpty { return item.prompt }
        var lines = [L.t("A radar finding: \(item.title)", "Находка радара: \(item.title)")]
        if !item.text.isEmpty { lines.append(item.text) }
        if !item.url.isEmpty { lines.append(L.t("Source: ", "Источник: ") + item.url) }
        if !item.report.isEmpty { lines.append(L.t("Report: ", "Отчёт: ") + item.report) }
        if !item.action.isEmpty { lines.append(L.t("Needed from me: ", "От меня нужно: ") + item.action) }
        lines.append(L.t(
            "Check what this changes for our product and the projects next to it (start with CLAUDE.md / AGENTS.md in each). Write it up as instructions for agents: what to update, where, in what order, how to check it and how to roll back. Change nothing before my yes.",
            "Проверь, что это меняет в нашем продукте и смежных проектах (начни с CLAUDE.md / AGENTS.md в каждом). Оформи как инструкцию для агентов: что обновить, где, в каком порядке, как проверить и как откатить. До моего «да» ничего не меняй."))
        return lines.joined(separator: "\n")
    }

    /// A Claude Code release as an update task: what changed since the installed version and what it means here.
    func agentPrompt(_ release: ClaudeRelease) -> String {
        let from = installed.isEmpty ? L.t("the installed version", "установленной версии") : installed
        return L.t(
            """
            Claude Code \(release.version) is out (installed: \(installed.isEmpty ? "unknown" : installed)).
            1. Read the changes from \(from) to \(release.version): \(RadarStore.changelogPage.absoluteString)
            2. List what touches hooks, plugins, skills, settings, MCP and CLI flags used by our product and the projects next to it (CLAUDE.md, AGENTS.md, .claude/, plugin manifests).
            3. For each: what changes, whether we need an edit, the risk.
            4. Write update instructions for agents (what to add to CLAUDE.md / AGENTS.md, what to re-test). Edit nothing before my yes; the CLI itself updates with `claude update`.
            """,
            """
            Вышел Claude Code \(release.version) (установлено: \(installed.isEmpty ? "неизвестно" : installed)).
            1. Прочитай изменения с \(from) до \(release.version): \(RadarStore.changelogPage.absoluteString)
            2. Выпиши, что касается хуков, плагинов, скиллов, настроек, MCP и флагов CLI, которыми пользуются наш продукт и смежные проекты (CLAUDE.md, AGENTS.md, .claude/, манифесты плагинов).
            3. Для каждого пункта: что меняется, нужна ли правка, риск.
            4. Напиши инструкцию для агентов по обновлению (что дописать в CLAUDE.md / AGENTS.md, что перепроверить). До моего «да» ничего не правь; сам CLI обновляется командой `claude update`.
            """)
    }

    private func updateUnseen() {
        let seen = Set(RadarStore.load(RadarStore.seenFile))
        let n = keys.filter { !seen.contains($0) }.count
        if n != unseen { unseen = n }
    }

    // MARK: Findings

    private func runFeed() {
        lastFeed = Date()
        let command = self.command
        queue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                DispatchQueue.main.async { self?.error = error.localizedDescription }
                return
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let parsed = RadarStore.parse(data)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let items = parsed {
                    if items != self.items { self.items = items }
                    self.error = ""
                } else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    self.error = L.t("radar_command failed", "radar_command не сработала") + (msg.isEmpty ? "" : ": " + msg.prefix(120))
                    log("[radar] feed failed (exit \(p.terminationStatus)) \(msg.prefix(200))")
                }
                self.updateUnseen()
            }
        }
    }

    static func parse(_ data: Data) -> [RadarItem]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["items"] as? [[String: Any]] else { return nil }
        return list.prefix(30).compactMap { d in
            let title = d.str("title")
            guard !title.isEmpty else { return nil }
            return RadarItem(id: d.str("id").isEmpty ? title : d.str("id"), source: d.str("source"), title: title,
                             text: d.str("text"), action: d.str("action"), url: d.str("url"), report: d.str("report"),
                             date: d.str("date"), kind: d.str("kind"), prompt: d.str("prompt"))
        }
    }

    // MARK: Claude Code changelog

    private func fetchChangelog() {
        lastChangelog = Date()
        let path = claudePath
        queue.async { [weak self] in
            let version = RadarStore.installedClaude(path)
            DispatchQueue.main.async { self?.installed = version }
        }
        var request = URLRequest(url: RadarStore.changelogURL, timeoutInterval: 20)
        request.setValue("Notchy", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                log("[radar] changelog: \(error?.localizedDescription ?? "no data")")
                DispatchQueue.main.async { self?.lastChangelog = .distantPast }   // try again next round
                return
            }
            let releases = RadarStore.parseChangelog(text, limit: 4)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if releases != self.releases { self.releases = releases }
                self.translator.want(releases.flatMap { $0.added })
                self.updateUnseen()
            }
        }.resume()
    }

    static func parseChangelog(_ text: String, limit: Int) -> [ClaudeRelease] {
        var out: [ClaudeRelease] = []
        var version: String?
        var added: [String] = [], fixed: [String] = []
        func flush() {
            if let v = version { out.append(ClaudeRelease(version: v, added: added, fixed: fixed)) }
            added = []; fixed = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                if out.count >= limit { return out }
                version = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- "), version != nil {
                let item = String(line.dropFirst(2))
                if item.hasPrefix("Fixed") { fixed.append(item) } else { added.append(item) }
            }
        }
        flush()
        return Array(out.prefix(limit))
    }

    private static func installedClaude(_ configured: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [configured, "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let exe = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(separator: " ").first.map(String.init) ?? ""
    }

    /// "2.1.323" > "2.1.319"
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// MARK: - View

struct RadarTab: View {
    @ObservedObject var radar: RadarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if radar.hasFindings {
                    SmallToggle(title: L.t("Findings", "Находки"), selected: !radar.showClaude) { radar.showClaude = false }
                }
                if radar.hasClaude {
                    SmallToggle(title: "Claude Code", selected: radar.showClaude) { radar.showClaude = true }
                }
                Spacer()
                if radar.hiddenHere > 0 {
                    Button(L.t("Bring back \(radar.hiddenHere)", "Вернуть \(radar.hiddenHere)")) { radar.restoreHere() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.5))
                }
                if (radar.showClaude ? radar.visibleReleases.count : radar.visibleItems.count) > 0 {
                    Button(L.t("Clear all", "Очистить все")) { withAnimation(.easeOut(duration: 0.2)) { radar.dismissAllHere() } }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                        .padding(.leading, 6)
                }
                if radar.showClaude && !radar.installed.isEmpty {
                    Text(L.t("installed \(radar.installed)", "установлено \(radar.installed)"))
                        .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.45))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if radar.showClaude { claude } else { findings }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(height: 230, alignment: .top)
        .onAppear {
            if radar.hasClaude != radar.hasFindings { radar.showClaude = radar.hasClaude }   // only one half exists
            if radar.translator.state == .needsDownload { radar.translator.check() }   // downloaded in Settings meanwhile
            radar.refreshSoon()
            radar.markSeen()
        }
    }

    @ViewBuilder
    private var findings: some View {
        if !radar.error.isEmpty {
            Text(radar.error).font(.system(size: 12)).foregroundColor(usageColor(70)).lineLimit(2)
        }
        if radar.visibleItems.isEmpty && radar.error.isEmpty && !radar.items.isEmpty {
            Text(L.t("All cleared. New findings will show up here.", "Всё очищено. Новые находки появятся здесь."))
                .font(.system(size: 12.5)).foregroundColor(.white.opacity(0.45))
        }
        if radar.items.isEmpty && radar.error.isEmpty {
            Text(L.t("No findings. Set radar_command in the config to show your scouts' findings here.",
                     "Находок нет. Чтобы показывать здесь находки своих радаров, задайте radar_command в конфиге."))
                .font(.system(size: 12.5)).foregroundColor(.white.opacity(0.45))
        }
        ForEach(radar.visibleItems) { item in
            FindingCard(item: item, prompt: { radar.agentPrompt(item) },
                        onDismiss: { withAnimation(.easeOut(duration: 0.2)) { radar.dismiss(item) } })
        }
    }

    @ViewBuilder
    private var claude: some View {
        TranslationNotice(translator: radar.translator)
        if radar.releases.isEmpty {
            Text(L.t("Loading the changelog…", "Загружаю список изменений…"))
                .font(.system(size: 12.5)).foregroundColor(.white.opacity(0.45))
        }
        ForEach(radar.visibleReleases) { r in
            ReleaseCard(release: r, notInstalled: !radar.installed.isEmpty && RadarStore.newer(r.version, than: radar.installed),
                        translator: radar.translator, prompt: { radar.agentPrompt(r) },
                        onDismiss: { withAnimation(.easeOut(duration: 0.2)) { radar.dismiss(r) } })
        }
        Button(L.t("Full changelog", "Весь список изменений")) { NSWorkspace.shared.open(RadarStore.changelogPage) }
            .buttonStyle(NotchButtonStyle(role: .secondary))
    }
}

/// Copies the task for an agent; says so for a moment.
struct AgentTaskButton: View {
    let prompt: () -> String
    @State private var copied = false

    var body: some View {
        Button(copied ? L.t("Copied", "Скопировано") : L.t("Task for an agent", "Задача агенту")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt(), forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .buttonStyle(NotchButtonStyle(role: .secondary))
        .help(L.t("Copies a ready task: what to update in our product and the projects next to it",
                  "Копирует готовую задачу: что обновить в нашем продукте и смежных проектах"))
    }
}

/// The × in a card's corner.
struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.45))
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.t("Clear", "Убрать"))
    }
}

struct FindingCard: View {
    let item: RadarItem
    let prompt: () -> String
    let onDismiss: () -> Void

    private var badge: (String, Color)? {
        switch item.kind {
        case "propose": return (L.t("your call", "нужно решение"), claudeOrange)
        case "probe": return (L.t("trying it", "проба"), codexBlue)
        case "hold": return (L.t("waiting", "ждёт условия"), .white.opacity(0.5))
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.source).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                if let b = badge {
                    Text(b.0).font(.system(size: 10.5, weight: .semibold)).foregroundColor(b.1)
                }
                Spacer()
                Text(item.date).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
                DismissButton(action: onDismiss)
            }
            Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(2)
            if !item.text.isEmpty {
                Text(item.text).font(.system(size: 12)).foregroundColor(.white.opacity(0.75)).lineLimit(2)
            }
            if !item.action.isEmpty {
                Text(L.t("From you: ", "От тебя: ") + item.action)
                    .font(.system(size: 12)).foregroundColor(claudeOrange.opacity(0.9)).lineLimit(2)
            }
            HStack(spacing: 6) {
                AgentTaskButton(prompt: prompt)
                if let url = URL(string: item.url), !item.url.isEmpty {
                    Button(L.t("Source", "Источник")) { NSWorkspace.shared.open(url) }.buttonStyle(NotchButtonStyle(role: .secondary))
                }
                if !item.report.isEmpty {
                    Button(L.t("Report", "Отчёт")) { NSWorkspace.shared.open(URL(fileURLWithPath: item.report)) }
                        .buttonStyle(NotchButtonStyle(role: .secondary))
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

struct ReleaseCard: View {
    let release: ClaudeRelease
    let notInstalled: Bool
    @ObservedObject var translator: ReleaseTranslator
    let prompt: () -> String
    let onDismiss: () -> Void
    @State private var expanded = false

    var body: some View {
        let shown = expanded ? release.added : Array(release.added.prefix(4))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(release.version).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                if notInstalled {
                    Text(L.t("not installed yet", "ещё не установлено")).font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(claudeOrange)
                }
                Spacer()
                Text(L.t("\(release.added.count) new · \(release.fixed.count) fixes", "нового: \(release.added.count) · исправлений: \(release.fixed.count)"))
                    .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
                DismissButton(action: onDismiss)
            }
            AgentTaskButton(prompt: prompt).padding(.vertical, 2)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text("• " + translator.text(line).replacingOccurrences(of: "`", with: ""))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.8)).lineLimit(expanded ? nil : 2)
            }
            if release.added.count > 4 {
                Button(expanded ? L.t("Less", "Свернуть") : L.t("\(release.added.count - 4) more", "Ещё \(release.added.count - 4)")) {
                    expanded.toggle()
                }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// A dot on the Radar tab while something new waits.
struct RadarDot: View {
    @ObservedObject var radar: RadarStore

    var body: some View {
        if radar.unseen > 0 {
            Circle().fill(claudeOrange).frame(width: 7, height: 7).offset(x: -2, y: 2)
        }
    }
}

/// The download offer, only while the Russian pack is missing.
struct TranslationNotice: View {
    @ObservedObject var translator: ReleaseTranslator

    var body: some View {
        if translator.state == .needsDownload {
            TranslationDownloadRow(translator: translator)
        }
    }
}
