import AppKit
import UserNotifications

// Notchy.app
//
//   Notchy                                  run the notch (a plain launch: Finder, login item, `open -a Notchy`)
//   Notchy -message TEXT [-title T] [-subtitle S] [-sound NAME]
//                                           post one notification and exit (installer self-test)
//   Notchy -indicators hide|show|toggle|auto
//                                           hide or show the notch rim in the running app and exit

struct OneShot {
    var title = "Notchy"
    var subtitle = ""
    var message = ""
    var sound = "default"
}

func parseArgs() -> (oneShot: OneShot, daemon: Bool) {
    var shot = OneShot()
    var daemon = true   // any launch without -message runs the notch; -daemon is still accepted
    let argv = CommandLine.arguments
    var i = 1
    func next() -> String? {
        i += 1
        return i < argv.count ? argv[i] : nil
    }
    while i < argv.count {
        switch argv[i] {
        case "-daemon": daemon = true
        case "-title": shot.title = next() ?? shot.title
        case "-subtitle": shot.subtitle = next() ?? ""
        case "-message": shot.message = next() ?? ""; daemon = false
        case "-sound": shot.sound = next() ?? "default"
        case "-indicators": sendIndicatorsCommand(next() ?? "")
        case "-help", "--help":
            print("""
            Notchy
            Notchy -message TEXT [-title T] [-subtitle S] [-sound NAME]
            Notchy -indicators hide|show|toggle|auto
            """)
            exit(0)
        default: break
        }
        i += 1
    }
    return (shot, daemon)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let oneShot: OneShot
    private let daemon: Bool
    private let notifications = SystemNotifications()
    private var server: IPCServer?
    private var legacyServer: IPCServer?
    private var coordinator: Coordinator?

    init(oneShot: OneShot, daemon: Bool) {
        self.oneShot = oneShot
        self.daemon = daemon
    }

    /// Notchy has no menu bar of its own, but key equivalents travel through the main menu: without an
    /// Edit menu, Cmd+A / C / V / X / Z do nothing in the panel's text fields.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.t("Quit Notchy", "Завершить Notchy"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: L.t("Edit", "Правка"))
        edit.addItem(withTitle: L.t("Undo", "Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L.t("Redo", "Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L.t("Cut", "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L.t("Copy", "Скопировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L.t("Paste", "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L.t("Select All", "Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if daemon { installEditMenu() }
        if daemon { Migration.fromClaudeNotify() }
        if daemon && IPCServer.isAnotherInstanceRunning(path: Paths.socket) {
            log("[init] another instance is running, exiting")
            NSApp.terminate(nil)
            return
        }

        // The panel does not wait for the notification permission: notifications are only one of
        // its outputs, and the first-run prompt may sit unanswered for a while.
        if daemon { startPanel() }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                // The permission prompt needs a regular app for a moment.
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            DispatchQueue.main.async { self.notifications.setup(self.authorized) }
        }
    }

    private func authorized(_ granted: Bool) {
        NSApp.setActivationPolicy(.accessory)
        log("[init] notifications authorized=\(granted) daemon=\(daemon)")
        if !daemon { postOneShot() }
    }

    private func startPanel() {
        let config = Config.load()
        let coordinator = Coordinator(config: config, notifications: notifications)
        let server = IPCServer(path: Paths.socket)
        server.onMessage = { json, connection in coordinator.handle(json, connection) }
        do {
            try server.start()
        } catch {
            log("[init] socket failed: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        self.coordinator = coordinator
        self.server = server
        startLegacySocket(coordinator)
        log("[init] panel started")
        Visibility.requestAccessibilityOnce()
        LoginItem.sync(enabled: config.openAtLogin)
    }

    /// Claude Code sessions started before the switch keep the old plugin's hook, which talks to
    /// Claude Notify's socket. Answer there too, unless the old app itself still runs.
    private func startLegacySocket(_ coordinator: Coordinator) {
        let dir = "\(Paths.home)/Library/Application Support/claude-notify"
        let path = "\(dir)/notifier.sock"
        guard FileManager.default.fileExists(atPath: dir), !IPCServer.isAnotherInstanceRunning(path: path) else { return }
        let legacy = IPCServer(path: path)
        legacy.onMessage = { json, connection in coordinator.handle(json, connection) }
        do {
            try legacy.start()
            legacyServer = legacy
            log("[init] also listening on the Claude Notify socket")
        } catch {
            log("[init] legacy socket failed: \(error.localizedDescription)")
        }
    }

    private func postOneShot() {
        let content = UNMutableNotificationContent()
        content.title = oneShot.title
        content.subtitle = oneShot.subtitle
        content.body = oneShot.message
        content.sound = oneShot.sound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(oneShot.sound))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
        }
    }
}

let (oneShot, daemon) = parseArgs()

let app = NSApplication.shared
let delegate = AppDelegate(oneShot: oneShot, daemon: daemon)
app.delegate = delegate
app.run()
