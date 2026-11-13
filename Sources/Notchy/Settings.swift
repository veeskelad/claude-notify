import AppKit
import SwiftUI

// Settings window (the gear in the panel). Each switch is written to config.json right away and
// applied without a restart; keys the window does not show stay as they are in the file.

enum ConfigFile {
    static func set(_ key: String, _ value: Any) {
        var json: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: Paths.config),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = existing
        }
        json[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: (Paths.config as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if !FileManager.default.createFile(atPath: Paths.config, contents: data) {
            log("[settings] could not write \(Paths.config)")
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var claude: Bool { didSet { if claude != oldValue { coordinator?.setClaudeEnabled(claude) } } }
    @Published var indicators: Bool { didSet { if indicators != oldValue { coordinator?.setIndicatorsHidden(!indicators) } } }
    @Published var openAtLogin: Bool { didSet { if openAtLogin != oldValue { coordinator?.setOpenAtLogin(openAtLogin) } } }
    @Published var systemAlerts: Bool { didSet { if systemAlerts != oldValue { coordinator?.setSystemAlerts(systemAlerts) } } }
    @Published var codex: Bool { didSet { if codex != oldValue { coordinator?.setCodexLimits(codex) } } }
    @Published var clipboard: Bool { didSet { if clipboard != oldValue { coordinator?.setClipboardHistory(clipboard) } } }
    weak var coordinator: Coordinator?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        claude = coordinator.claudeEnabled
        indicators = !coordinator.indicatorsHidden
        openAtLogin = coordinator.currentConfig.openAtLogin
        systemAlerts = coordinator.currentConfig.systemAlerts
        codex = coordinator.currentConfig.codexLimits
        clipboard = coordinator.currentConfig.clipboardHistory
    }

    /// The indicators may have changed meanwhile (eye command, quiet hours).
    func reload() {
        guard let c = coordinator else { return }
        if indicators != !c.indicatorsHidden { indicators = !c.indicatorsHidden }
    }
}

final class SettingsWindow {
    private weak var coordinator: Coordinator?
    private var window: NSWindow?
    private var model: SettingsModel?

    init(coordinator: Coordinator) { self.coordinator = coordinator }

    func show() {
        guard let coordinator = coordinator else { return }
        if window == nil {
            let model = SettingsModel(coordinator: coordinator)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L.t("Notchy Settings", "Настройки Notchy")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
            self.model = model
        }
        model?.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section(L.t("General", "Общие")) {
                Toggle(L.t("Open at login", "Открывать при входе в систему"), isOn: $model.openAtLogin)
                Toggle(isOn: $model.clipboard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Clipboard history", "История буфера обмена"))
                        Text(L.t("The last 30 copied texts, in memory only; passwords from password managers are skipped",
                                 "Последние 30 скопированных текстов, только в памяти; пароли из менеджеров паролей не сохраняются"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $model.systemAlerts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Load alerts", "Предупреждения о нагрузке"))
                        Text(L.t("The notch widens when CPU stays busy, memory runs short, the Mac gets hot or the disk fills up",
                                 "Чёлка расширяется, если ЦП долго загружен, мало памяти, Mac перегревается или кончается диск"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Section("Claude Code") {
                Toggle(isOn: $model.claude) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Claude module", "Модуль Claude"))
                        Text(L.t("Questions, plans and permissions in the notch, usage limits, session status",
                                 "Вопросы, планы и разрешения в чёлке, лимиты, статус сессий"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $model.codex) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Codex usage", "Лимиты Codex"))
                        Text(L.t("Off: the line around the notch is all Claude", "Выключено — обводка вокруг выреза целиком для Claude"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .disabled(!model.claude)
                Toggle(isOn: $model.indicators) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Indicators at the notch", "Индикаторы у выреза"))
                        Text(L.t("The usage line and the request dot around the notch; quiet_hours hides them on a schedule",
                                 "Обводка лимитов и точка запроса у выреза; quiet_hours прячет их по расписанию"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .disabled(!model.claude)
            }
            Section {
                HStack {
                    Button(L.t("Open config.json", "Открыть config.json")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.config))
                    }
                    Button(L.t("Logs", "Логи")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logDir))
                    }
                    Spacer()
                    Text("Notchy \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
